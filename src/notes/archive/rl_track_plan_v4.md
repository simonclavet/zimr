> **ARCHIVED Oct 31 2026 - superseded by `src/notes/rl_track_plan.md` (v5).** Kept verbatim and not
> maintained: fundamentals, the night's preparation, the balance, the time hierarchy, and EfficientTDMPC read in full,
> with every number they measured.

# rl_track_plan.md - v4 (Sep 27, 2026, evening): SuperTrack on the 10-second dance - fundamentals, the bench, the night

v4 replaces v3 (archived as `src/notes/archive/rl_track_plan_v3.md` - every step's full design and measurement up to
Sep 27, the MimicKit table, Phase R's workflow study). v2 and v1 are archived beside it; `rl_track_journal.md` is the
dated history; `supertrack_comparison.md` tables the paper, an unofficial implementation and ours. What v4 changes:
the finished work is summarised (§4), and what remains is ordered by what everything else stands on - the action path,
then a BENCH that turns every remaining choice into a measured A/B (v3 had no such tool before its last step), then
the recipe decisions, the world model's form, scale, the kit's parity, a gate, and the night.

---

## THE PLAN (Oct 25, rewritten): three learners in the lab, judged honestly, then the night runs

**The goal (Simon, Oct 24-25).** An intuitive lab for starting training runs, watching them, judging and comparing
them on the dance-tracking task, choosing between PPO, SuperTrack and EfficientTDMPC - all three on the GPU - and,
soon, the best EfficientTDMPC run overnight on Windows. Later: a single-page demo that plays a trained policy.

### 1. Principles (each one decided, with its reason)

1. **What learners share is thin; everything else is each learner's own** (Simon, Oct 25: "very different algos
   must work without limiting each other - no framework forcing all parts to share rigid interfaces").
   Shared, and only this: the run file's envelope (`GenoRun`: the motion, the controls, one learner of a union);
   the policy file, for watching and judging (`GenoPolicy`); the measurements (`judge.csv`, `status.zon`); the
   judge's `robot_track.Actor` (a context pointer and a function). Each learner's own: its settings (a struct that
   mirrors its own options, checked at compile time), its training loop (its own function in the trainer, reached
   by one `switch`), its state file, its log's columns. No learner interface, no vtable, no common base.
2. **The policy file is the common denominator, never the only way to act.** It lets the lab watch and the judge
   judge any learner's run one way. A learner whose best acting is not a network - EfficientTDMPC's planner - keeps
   its own actor beside it, which the lab and the judge run through `Actor`.
3. **One honest measure.** The judge (`robot_track.judge`): fixed starts a second apart, the mean action, no help
   (no assist, no grace, no shoves), nothing random; every measure with its standard error; the servo alone on the
   same starts as the baseline; checked against controls before trusted (zero weights are the servo, a judgement
   repeats exactly, a policy at its limit is judged otherwise). Training's own numbers are not comparable across
   learners or early in a run (the root assist flatters them: 17.1 s trained vs 1.51 s judged).
4. **A controller's design is its learner's.** The task is the motion with Geno's failure rule, physics and servo;
   the decision interval, the filter and the action scale belong to the learner and travel with its policy.
5. **Small, verified turns.** One step per turn; its check the narrowest test root that compiles what it touched
   (`zbuild test-fast -Dfast-root=src/robot_lab.zig`, or `src/robot_tests.zig` for files it imports), the style
   gate (`zbuild lint-check`), the build of what changed - the trainer and the lab for Windows when touched; no run
   past 5 minutes; a control for every check that could pass vacuously; a scripted headless capture for what the
   lab shows. Record in the plan and the journal, snapshot, end.
6. **Course-quality code and tutorial.** Names that say what they hold; comments that teach the algorithm; memory
   stated wherever a function takes two allocators; the robot-mocap tutorial kept current, without testing details.

### 2. What exists (Oct 25)

- **The run format** (`robot_lab.zig`): `GenoRun` = `task` (the motion) + `learner` (`ppo` / `supertrack` /
  `efficient_tdmpc`, each its own settings) + `controls` (save, checkpoint, judge, stop). `problem()` names any
  setting out of range by its path. The older `PpoRun` reads as a PPO run (`fromPpoRun`, `toPpoRun`).
- **The trainer** (`tools/geno_trainer.zig`): reads `GenoRun`; trains PPO (other learners refused by name); writes
  `weights`, `policy`, checkpoints by batch and by minute, `log.csv`, `status.zon`, `judge.csv` every
  `judge_minutes`; checks its first policy file plays as it acts (exit 2 otherwise); resumes from the folder.
- **The policy file**, version 2 (`GenoPolicy`, `PolicyFile`): widths and layers (tanh / linear), an optional frozen
  `zrl.ObsNormalizer`, the action limit, scale and filter; `extern struct` headers; refused by name when damaged.
- **Showing and judging** (`robot_lab.zig`): `PolicyDecider` (one decision for the show and the judge),
  `PolicyShow`, `PolicyJudgeActor`, `judgePolicy`; `robot_track.Judgement` with standard errors; `JudgeLog`.
- **The lab** (`examples/geno_lab`): lists runs, plots training's curves, shows each run's newest judgement beside
  the servo's, watches any run's policy file (a click on the curves picks the checkpoint nearest that minute),
  reloads the newest policy; its new-run form is PPO's.
- **SuperTrack** trains on the GPU in the `geno_train` page (`robot_track_resident.Resident`); its run settings
  are `SuperTrackLearner`, mirroring the GPU learner's options.
- **EfficientTDMPC** runs on the CPU (`robot_bmpc.Bmpc(T)`, its `Trainer`) and passes the cartpole gate.

### 3. The road

Each step: **goal - design - code - known answers - checks - turns.** Estimated 25-35 turns in all.

#### Phase A - SuperTrack in the lab (5-7 turns)

**Status (Oct 25):** A1 done - `exportState` / `stateProblem` / `importState` / `waitForReadback` in
`robot_track_resident.zig`, its known answers in `robot_track_resident_tests.zig` (re-saved bytes identical, the
same action bit for bit, `options.policy_rate` named, the flipped-bit control). A2a done: the policy file's version 3 - `ObservationKind`,
`PolicyObservation` (DReCon's, or SuperTrack's features with the clip's frozen `robot_latent.Normalizer`), the
policy's own `decimation` (the show and the judge take it from the policy; their settings no longer carry one), the
`ObservationHeader` and the features block, version 2 read as DReCon every 2 steps, refusals by name. A2b done: one
definition of SuperTrack's features (`robot_track_resident.supertrackFeaturesInto`, used by the learner and the lab's
decider), `robot_policy.everyActuatedJoint`, `Resident.policyParts` and `robot_lab.policyOfSuperTrack`; every player
zeroes a non-finite action. Known answers: the file's policy is the kit's policy output bit for bit, the mirror's to
2e-8 over 600 steps on the learner's fleet, the controller passes it unchanged, zero weights are judged as the servo.
A3a done: `geno_trainer` trains a SuperTrack run
(`runSuperTrack`, `trainSuperTrack`: rounds, its state file, its policy, `lab.SuperTrackLog`, status, resume refusing
a state of other shape or options by name); `SuperTrackLearner` gains the fleet's `characters` and `replay_steps`;
`lab.superTrackTrainingTask` is the page's and the trainer's one task; `Compute.discardReadback` keeps a resumed
mirror from taking a pre-upload copy. Checked: 2.4 minutes on lavapipe over three starts, rounds and update counts
continuous; the Windows build. A3b (trainer) done: policy checkpoints by minute, judging
into `judge.csv` on every learner's judge, the policy self-check after each start's first save; `waitForReadback`
waits for a readback that exists (a resumed run's first round dispatches nothing). Checked on lavapipe: a fresh run
and its resume, judged 3 times, 2 checkpoints, self-check passed both starts. A3c done: `RunCurve` reads any learner's log by its
header's column names (`Columns.ofHeader`), the window in that learner's lines (8 batches, 128 rounds). A3 is
complete. A4a done: each run's line names its learner and its unit
(batch, round), its watch reads the whole `run.zon` once; the new-run form edits a whole `GenoRun` - the learner
chosen first (radio buttons, `GenoLearner.summary`), then its settings, the task and the controls; EfficientTDMPC is
refused until it trains (`GenoLearner.isTrainable`). Checked headless: a SuperTrack run listed, judged, curved and
watched; the form with each learner. A4b done: a SuperTrack run started from the form trains (the
lab's own trainer, on lavapipe), a PPO and two SuperTrack runs listed side by side with their judgements; the PPO and
SuperTrack runs' servo lines in judge.csv are byte-identical; a new run is named by its learner and motion; the UI
writes a float too small for three decimals in its shortest digits (0.0003, not 0.000). PHASE A IS COMPLETE.

**Status (Oct 25), phase B:** B1a done - the CPU agent's environment contract has episodes that end: `step` returns a
`StepOutcome` (reward, and `EpisodeEnding`: continues / terminated / truncated); the trainer stores terminated and
truncated rows apart and resets on either, its length L still truncating. Known answers: a stand-in fall terminates
every second step beside a steady environment truncated at L; every bmpc test passes. OPEN DECISION (Simon), restudied Oct 25 with
the paper's v5: the paper's value target (App. D, eq. 14: y(z) = R(z,a) + gamma mean_i Vbar(f_i(z,a))) and planner
(eq. 7) contain no termination term - BMPC has none - and our CPU agent is that: `LatentValueTargets` is model-based
(the policy's action at the stored latent), so no stored flag can reach it. Two good choices: (1) THE AFTERMATH - a
lost reference does not end the episode; the character lives on for a short aftermath (about a second) and is then
cut (truncated). Geno's reward is gravity-gated (lying keeps 2-6%), so the data itself prices a fall; no new part,
paper-faithful, and the aftermath lengthened is the reset-free gym of the north star (M8). (2) A TERMINATION HEAD -
the TD-MPC2 family's own episodic extension (Puppeteer: BCE on the latent, targets cut at terminals, a soft
cumulative cut in planning; bmpc-jax: a continue head, hard in the planner, soft in targets). Recommended (1); (2)
kept as a bench arm if (1) learns falls too slowly. Next: that decision, then B1b - the dance environment (`TrackEnvironment`). Carried to A3: on a GPU,
the first `syncMirror` after an import may take a readback copied BEFORE the upload and put the seeded weights back
in the mirror for a round - the trainer's resume waits for a readback that postdates the import (or skips the first
round's sync) before acting.

**A1. The GPU learner saves and resumes its state.** *Goal:* a SuperTrack run survives a stop and a restart.
*Design:* a state file of its own (`supertrack_state`): an `extern struct` header (magic, version, the options it
was trained with, the counters - world and policy updates, exposure, failures - and the random stream's state),
then both networks' parameters and Adam's first and second moments (the kit's buffers, read back after the last
update), then the clip normaliser's means and spreads. The replay is not kept (decided Oct 24): a resumed run
refills it before its first update. *Code:* `Resident(M).exportState(arena) ![]u8`, `importState(bytes) !void` in
`robot_track_resident.zig`. *Known answers* (on the kit's CPU twin, in `robot_track_resident_tests.zig`): a learner
trained some rounds, exported, imported into a fresh learner - the same parameters and moments bit for bit, the same
policy action on the same features (`policyRow`), the same counters; a file of other options refused by name;
CONTROL: one byte of the parameters changed, the action differs. *Checks:* `-Dfast-root=src/robot_tests.zig`
(filtered), the gate. *Turns:* 1-2.

**A2. The policy file's version 3: an observation of its own, a decision interval.** *Goal:* a SuperTrack policy
plays in the lab and the judge exactly as it trained. *Design:* the header gains `observation: ObservationKind`
(`drecon` - DReCon's observation through `robot_policy.observeFrom`; `supertrack_features` - the character's state
and the reference one frame ahead, each in the root's frame, normalised by the clip's frozen normaliser, `(x - mean) /
spread` in f32, no clamp) and `decimation`. The feature normaliser is its own block (means and spreads, f32). A
SuperTrack policy acts on every actuated joint at every physics step, unfiltered (`filter_beta` 1) and unclamped (an
infinite limit; non-finite actions zeroed, as the learner does). Its first layer reads `[goal | state]` as one dense
layer in input order - the GPU's own order. `PolicyDecider` builds the observation its policy names; the show's and
the judge's interval comes from the policy. A version-2 file reads as `drecon` with interval 2. *Code:*
`robot_lab.zig` (`ObservationKind`, `FeatureNormalizer`, `PolicyFile` v3, `PolicyDecider`), `policyOfSuperTrack`
(from the learner's mirror and normaliser). *Known answers:* PPO's bit-for-bit tests unchanged (a v3 file of PPO's
policy acts as PPO); a SuperTrack policy made from a learner on the CPU twin acts as the kit's own forward pass bit
for bit, and within rounding of `policyRow` (the CPU mirror interleaves the two blocks); its show and the learner's
own acting give the same actions over 600 steps on one seed; the judge's zero-weights control holds for the new
kind. *Turns:* 2.

**A3. The trainer's SuperTrack path.** *Goal:* `geno_trainer --run=` trains a SuperTrack run. *Design:*
`runSuperTrack` beside PPO's `runTraining`, reached from the same `switch` in `main`; it builds the fleet as the
page does (Geno's task with a window's grace, the SuperTrack action scale), measures the clip normaliser, creates
the GPU learner on Vulkan, and loops rounds (collect, then the world's and the policy's updates) until the controls
say stop; it saves its state (A1), its policy (A2), checkpoints by minute, its status, its own log, judgements
(`judgePolicy` on the SuperTrack kind), and checks its first policy file acts as the learner does. Its log is its
own - rounds, minutes, steps watched, failures, the world's and the policy's losses - and `RunCurve` learns to read
any log by its header's column names, the curves needing only minutes, steps watched and failures (principle 1:
PPO's batch counters are not forced on SuperTrack). *Known answers:* the trainer's first rounds equal a direct
`Resident` loop with the same seed (counters, then the policy's actions); start, stop, resume (the replay refilled);
judge.csv's servo line identical to a PPO run's on the same clip; a CONTROL policy shifted as written fails the
self-check (exit 2). *Checks:* a 2-minute run on lavapipe, its resume, the Windows build. *Turns:* 2.

**A4. The lab shows SuperTrack's runs.** *Goal:* a SuperTrack run is listed, watched and judged like PPO's.
*Design:* each run's line names its learner; the curves read each learner's log by column name; the watch plays the
v3 policy; the new-run form chooses the learner first (three buttons with a line each), then that learner's settings
(`ui.editStruct` on its struct), checked by `GenoRun.problem()` before the trainer starts. *Known answers:* headless,
a PPO and a SuperTrack run side by side - both listed with their learners, both judged, each watched; a new
SuperTrack run started from the form trains. *Turns:* 1-2.

#### Phase B - EfficientTDMPC in the lab, on the CPU first (8-10 turns; made precise Oct 25)

The CPU agent (`robot_bmpc.Bmpc(T)`) exists and passes the cartpole gate at gate widths; Oct 4 decided no CPU
LEARNING runs (matmul-bound: the gate's 1650 updates took 3 minutes even at gate widths, and mastery needs tens of
thousands at the paper's). So phase B is plumbing and known answers - the
dance as the agent's environment, its state file, its policy file, its trainer path, the lab - every file and every
format the GPU learner of phase C will reuse unchanged, and every answer phase C is held to. A CPU run on the dance is
expected to show finite, falling losses and a judged policy, NOT to learn the dance; the night run that should learn it
is phase C's.

**What fixes the design (Simon, Oct 25): THE AFTERMATH.** A lost reference does not end the episode: the character
lives on through an aftermath - its fall, under the gravity-gated reward (lying keeps 2-6%) - and the episode is then
CUT (truncated), as the clip's end and the step cap are. The agent keeps the paper's equations exactly: no termination
term anywhere (App. D, eq. 14; eq. 7), and none is needed, because the data itself shows what a fall is worth.

**What TD-MPC2's code taught (studied Oct 25, `tdmpc2-main`, the April 2025 release with `episodic`):**
  1. Termination is either modelled or refused. A non-episodic TD-MPC2 raises on the first terminated step
     (`online_trainer.py`: "Termination detected but you are not in episodic mode"); episodic mode adds a termination
     head (BCE on the rolled-out latents), cuts TD targets at stored terminals, and in planning accumulates a HARD
     termination (`> 0.5`, clipped at 1) that zeroes every later reward and the bootstrap. Ours models none, so ours
     REFUSES a terminated step too (B1c) - a silently mis-valued fall is worse than an error.
  2. The discount comes from the episode's length: gamma = clip((L/5 - 1) / (L/5), 0.95, 0.995) - our `discountFor`,
     the same rule. The dance's L is in DECISIONS: 600 physics steps / 2 = 300, so gamma = 0.983.
  3. Seeding: max(1000, 5 L) frames of random actions, then a burst of that many updates - our `Schedule.bmpc`.
  4. The planner warm-starts from the last plan shifted one step, from zero where an episode begins - ours does
     (`first_steps`); the trainer's `first_steps` after a cut is what restarts it.
  5. Two more MPPI iterations from 20 action dimensions - ours (`Config.iterationsFor`); DReCon's actuated subset on
     Geno is ten ball joints, 30 dimensions, so the acting planner runs 8.
  6. Its buffer adds whole episodes when they end; EfficientTDMPC's "data freshness" inserts every step - ours does,
     and our windows cross an episode's end masked (`finished`), so TD-MPC2's `rho` note for episodic tasks (raise it,
     since terminals sit at the end of every sequence) does not apply.
  `bpmpc-main` (also supplied) is a differentiable QP-MPC library in JAX, not BMPC: noted for later MPC work - its
  slow/fast parameter split mirrors the kit's per-run and per-dispatch uniforms, and its straight-through dynamics (true
  simulator forward, nominal model backward) is SuperTrack's arrangement; nothing in phase B changes for it.

**B1b. The fleet's aftermath** (1 turn) - DONE Oct 25: `Fleet.Options.aftermath_steps`, `End.aftermath`,
`in_aftermath` (the step just taken, its last included), `TrackEnv` maps it to a cut and counts `Outcome.aftermath_steps`;
the whole robot family's tests pass unchanged; the known answer is in `robot_ppo_track_tests.zig`. *Goal:* a lost character lives on before its episode ends. *Design:*
`robot_track.Fleet.Options.aftermath_steps: u32 = 0`. When the failure rule fires: the step is the FAILURE (counted
once, `failures[env]` set, `failed` += 1) and the character enters its aftermath - no restart; for the next
`aftermath_steps` physics steps it is simulated and rewarded as usual (`in_aftermath[env]` true, never a second
failure); then the episode ends with a new `End.aftermath`, its state captured in `terminal` as every end is. A cap or
the clip's end during the aftermath ends it as itself. Zero keeps today's behaviour exactly - the judge, PPO and
SuperTrack keep 0. `TrackEnv` maps `End.aftermath` to a `.cut` (the observation it ended in written to `terminal`), and
its `Outcome` gains `aftermath_steps` - held steps spent in an aftermath - so a learner's exposure counts time AT RISK
only (an aftermath step is after the failure; counting it would flatter the time to failure). *Known answers:* every
existing fleet, PPO, SuperTrack and judge test unchanged at 0 (bit for bit); the servo alone with an aftermath of 60:
a lost character runs on 60 steps, its failure counted once, at the loss; its reward over the aftermath falls below 0.1
(the gate); its 61st step is a restart; CONTROL: at 0 it restarts at once. *Checks:* `test-fast` filtered on the fleet,
the track env, PPO's show and the judge; lint. *Code:* `robot_track.zig`, `robot_track_env.zig`.

**B1c. The dance as the agent's environment** (1-2 turns) - FIRST HALF DONE Oct 25: `robot_bmpc_dance.zig`'s
`TrackCharacter` (one character behind the agent's contract; starts from the trainer's reset stream; counts steps at
risk and failures); the trainer refuses a terminated step; known answers on Geno - losses cut after their aftermath
with the true ended-in state, the control refused, the same seeds the same rows. SECOND HALF DONE Oct 25:
`TdmpcLearner` gains the fleet (characters 8, aftermath 60, episodes 600 steps = 300 decisions, replay 100k, one
update a decision) and resolves the agent's config against the preset (`agentConfig`, `schedule`); `tdmpcProblem`
refuses an aftermath shorter than the acting planner's reach; `robot_bmpc_dance.trainerFor`; a learning test on Geno
(world-model loss 0.98 -> 0.40 over 301 updates, every loss finite). MEASURED (ReleaseSafe test build, this CPU, 2
characters): at latent 32 / hidden 64 with the preset's planner (512 candidates x 8 rounds x 6 decisions x 4 heads) a
frame costs 5.9 s acting and 8.1 s with its updates - about 100 times slower than real time per character; at the
paper's widths the run was killed for memory. So CPU runs on the dance need a planner shrunk far below the paper's,
and B2c's smoke runs will name one; the GPU (phase C) is where EfficientTDMPC trains the dance. *Goal:* `Bmpc(f32).Trainer` trains on Geno. *Design:*
  - `TrackCharacter` (in `robot_track_env.zig`, beside `TrackEnv`): ONE character, a `TrackEnv` of one environment on a
    fleet of its own (seed + index), behind the agent's contract. `reset(rng, observation)` writes the current
    observation - the fleet restarts a character itself at every end, and its own seeded stream chooses where, so the
    trainer's reset stream is not used (said in the doc). `step(action, observation)`: one `decide`; the reward is the
    decision's (the mean over its held steps, up to the end); a `.cut` writes the TRUE successor - the observation it
    ended in, `observeTerminal` - and returns `.truncated`; otherwise the next observation and `.continues`. A `.stop`
    cannot happen (the aftermath and `clip_end = .bootstrap` turn every end into a cut): asserted.
  - The trainer refuses a terminated step (lesson 1): `error.TerminationNotModelled`, naming the cure - an aftermath,
    then a cut. B1a's falling stand-in test becomes that refusal's test; the terminated column and `EpisodeEnding
    .terminated` stay, for the day a termination head is measured against the aftermath (the bench arm).
  - `TdmpcLearner` gains the run's fleet: `characters: u32 = 8`, `aftermath_steps: u32 = 60` (one second),
    `max_episode_steps: u32 = 600` (L = 300 decisions), `replay_steps: u32 = 100_000` (per character, as BMPC's 1M
    over its one environment, scaled), `update_to_data: u32 = 1`; `problem()` checks each (an aftermath shorter than
    the planner's horizon in physics steps is refused: the model would never see where a fall leads within a plan).
    The pessimism default for the dance is the paper's early-termination value, beta = 10: a fall is still a
    catastrophe the model is least trained on, which is what Figure 5's tasks have in common; beta 0 is an A/B for the
    bench, not the default.
  - Observation: DReCon's, raw - no normaliser, as TD-MPC2 and BMPC take observations (the encoder's first layer
    normalises its pre-activations). A frozen normaliser (measured on the servo's warm-up, as PPO's) is the fallback
    if the encoder's loss misbehaves - measured, not assumed.
  *Known answers:* at gate widths (latent 32, hidden 64, 4 characters, a short schedule): a few hundred decisions on the
  dance - every loss finite and the world model's falling; the same seeds the same run bit for bit; a lost character's
  rows - the loss, the aftermath's gated rewards, the last row truncated with the TRUE ended-in observation, the next
  decision a first step; CONTROL: an aftermath of 0 cuts at the loss itself (the aftermath does something); a
  terminated stand-in refused. MEASURED, for B2c's expectations: decisions a second on this CPU at gate widths and at
  the paper's (one update a decision). *Code:* `robot_track_env.zig`, `robot_bmpc.zig` (the refusal), `robot_lab.zig`
  (the settings). *Tutorials:* robot-mocap (the aftermath: what a fall teaches without a termination head; the
  character's contract) and zimrrl (9.x: the refusal and why TD-MPC2 refuses too).

**B2a. Its state file** (1-2 turns) - DONE Oct 26 (one turn was cut off mid-way; its edits were found on
disk, compiled and tested in the next): `exportState`/`stateProblem`/`importState` on `Bmpc(T).Trainer`, the
configuration kept as ZON and compared by path, `ReplayBuffer.holdsWindow` gating updates during the refill; four
tests pass (round trip, refusals, CONTROL, refill). *Design:* `Bmpc(T).Trainer.exportState` / `stateProblem` / `importState`, as A1:
the header (magic, the shape - observation and action widths, the networks' parameter counts -, every `Config` and
`Schedule` field as saved options, the counters: frame, update index, episodes per environment), then every network's
parameters (encoder, every dynamics head, reward, policy, values, TARGET values), both optimisers' moments and step
counts, and the running scale's state (`RunningScale`, the policy loss's normaliser). The random streams are
counter-based (`Rng.split` by frame, environment, update), so the seed and the counters ARE their state - nothing else
to save. The replay is not kept (decided Oct 24): a resumed trainer acts with the planner (no second seeding) and
makes no update until every ring can supply a window (`horizon` rows) - the refill. *Known answers:* export, import into
a fresh trainer, export again - the same bytes; the same planner decision and policy action on the same observation;
a file of other options refused by the setting's path; numbers checked (finite, second moments not negative); CONTROL:
a flipped exponent bit acts otherwise. *Code:* `robot_bmpc.zig`.

**B2b. Its policy file: version 4** (1-2 turns) - FIRST HALF DONE Oct 26: `PolicyActivation` gains
`layer_norm_mish` and `layer_norm_simnorm`, a normed layer holds the norm's gain and bias after W and b, its epsilon
and group as the layer's settings; the player's norm and activation ARE zimrnum's (`layerNormRows`, `zm.mish`,
`simNormRows`) - equal to the graph's to the bit on the same pre-activations, the whole layer to rounding. VERSION 4 DONE Oct 26:
each layer header carries the SimNorm group and the norm's epsilon (`LayerHeaderBefore4` reads versions 2 and 3);
settings that cannot be refused as `PolicyNormInvalid`; a normed policy reads back and acts the same, bit for bit.
Then (Simon, Oct 26: "we really don't care about
old version compatibility for now - we are still at version 0"): the policy file reads its own version only (the
version-2 and version-3 readers, `decodeKnowingVersion2Interval` and the lab's run-interval plumbing removed), and
`GenoRun.parse` no longer converts an older `PpoRun` text. `PpoRun` remains only as the parameters the trainer's PPO
path takes (`GenoRun.toPpoRun`); folding that path onto `GenoRun` directly is a later cleanup. B2b DONE Oct 26:
`policyOfTdmpc` writes the agent's encoder, its policy's hidden layers and the head's mean half through tanh
(`normedPolicyLayer` converts each normed layer, one definition for the file and its tests); played from the file,
the agent's mean actions to 2.2e-7 with means spread to 0.99; CONTROL: one encoder weight changed moves the action.
NEXT: phase C, from C1. *Design:* the agent's deployed policy is its encoder then its policy
head's mean: encoder `NormedDense(obs -> 256, Mish)`, `NormedDense(256 -> 512, SimNorm 8)`; policy `NormedDense(512 ->
512, Mish)` x 2, then the head's MEAN half `Dense(512 -> A)`, through tanh (`TanhMeanGaussian`'s mean). `PolicyActivation`
grows `layer_norm_mish` and `layer_norm_simnorm`, each defined once in zimrmath/zimrnum and used by the agent and the
player alike; such a layer holds W, b, then the norm's gain and bias. `LayerHeader` gains the SimNorm group and the
norm's epsilon - a layout change, so version 4 (versions 2 and 3 still read). Observation `drecon`, decimation and
filter the learner's, limit 1. *Known answers:* the file's mean action is the agent policy's mean (`TanhMeanGaussian`
on the graph) to rounding - the graph's matmul sums with Neumaier compensation, the player plainly, so a few parts in a
million (bit for bit is phase C's: the GPU kit sums plainly, as the player does); PPO's and SuperTrack's files read and
act as before; a damaged group or epsilon refused. *Code:* `robot_lab.zig`, `zimrmath.zig` (mish exists; LayerNorm
and SimNorm scalar forms beside it if missing).

**THE ORDER FROM HERE (Simon, Oct 26: "do things in the most logical order").** B1c measured the CPU agent at about 3 s a
decision with the preset's planner, so a CPU trainer path and a CPU planner in the lab would be built for runs nobody
makes. The order is therefore: finish B2b (the agent's policy as a file) - then phase C (the GPU agent: C1 the kit's
operations, C2 its update, C3 its planner, C4 the cartpole gate) - then B2c and B3 built ONCE, for the GPU learner
(B2c becomes C5's trainer path; the lab's planner view acts through the GPU planner). The state file (B2a) and the
policy file (B2b) are the formats both learners share, which is why they come first.

**B2c. The trainer's EfficientTDMPC path** (2 turns) - after phase C, for the GPU learner (see the order above). *Design:* `runTdmpcCpu` beside PPO's and SuperTrack's, reached
from the same `switch`; no GPU needed (the CPU agent), so it runs on any machine. Its files: `tdmpc_state`, `policy`
(v4), `log.csv` with its own columns - `update, training_minutes, steps_watched, failures, frames, world_loss,
policy_loss` - one line per 50 frames; `RunCurve` learns `update` (a window of 10 lines: 8 characters x 50 frames x 2
physics steps = 800 steps a line, about two minutes of character-time over 10), `status.zon`, `judge.csv` (the same
judge, so the same servo line), `policy_m<minute>` checkpoints, and the first policy file of every start read back and
played by the lab's decider against the agent's own mean action (to rounding) or the run fails. *Known answers:* a
2-minute run and its resume (frames and updates continuous, the refill before the first update); judge.csv's servo
line byte-identical to PPO's and SuperTrack's. *Code:* `tools/geno_trainer.zig`, `robot_lab.zig` (`TdmpcLog`).

**B3. The lab: EfficientTDMPC's runs, and its planner** (1-2 turns). *Design:* listed, judged and watched as the others
(the v4 file plays through the same decider); the watch gains "policy / planner" - the planner acting through the
agent's own actor (its state file loaded on the CPU, the planner in evaluation mode: the mean plan, no noise), default
off (decided Oct 24); a planner actor for the judge too (`Actor`), so a run can be judged both ways. *Known answers:*
headless, a PPO, a SuperTrack and an EfficientTDMPC run side by side, each judged; the planner's decision on a state
equals the trainer's planner's on the same state and seed (bit for bit: the same code). *Code:*
`examples/geno_lab/geno_lab.zig`, `robot_lab.zig`.

#### Phase C - EfficientTDMPC on the GPU (10-14 turns)

**C1. The kit's missing operations** (L6): NormedDense forward and backward, SimNorm, the two-hot cross-entropy (101
bins on [-10, 10]), each with its CPU twin from the same source. *Known answers:* values and gradients against
zimrnum's graph and the CPU agent's own. *Turns:* 3-4.

*C1 made precise (Oct 26, after surveying the kit).* The kit is `src/gpu/zn_mlp.zig`: flat buffers (params, grads,
Adam's moments, acts, dacts) addressed by host offsets, one dispatch per layer operation, one thread per output
element; its kernels run on the device and, unchanged, on the CPU twin (`compute_host.Compute(M).initCpu()`), and
`gpu_learn_tests.zig` proves each against zimrnum's graph step for step (G1, SAC, PPO, SuperTrack). What it lacks for
EfficientTDMPC, and how each piece fits it:
  - THE NORMED LAYER IS THREE STEPS, each its own kernel: the kit's `dense_fwd` with `Act.linear` (the
    pre-activations p), then `norm_fwd` - ONE THREAD PER ROW, since a row's mean and spread need all of it - writing
    the normalised row n, its inverse spread (one per row, for the backward) and s = n x gain + norm_bias, then the
    activation: `mish_fwd` per element, or `simnorm_fwd` per GROUP. Backward the other way: `mish_bwd` (Mish's slope
    from the stored s - the kit's `act_bwd` takes derivatives from the OUTPUT, which Mish cannot give back),
    `simnorm_bwd` per group (the softmax's Jacobian from the stored output), `norm_bwd` per row (the standard layer
    norm backward from n and the inverse spread), the gain's and norm bias's gradients as column sums (as
    `dense_bwd_w` sums b's), then the kit's `dense_bwd_x` / `dense_bwd_w`.
  - THE NORM'S ARITHMETIC DEFINED ONCE. The policy player normalises with zimrnum's `layerNormRows` (compensated sums
    for the mean and the variance). The kernel must compute the same numbers, or the GPU agent's policy and its file
    differ. So the row statistics - mean and inverse spread, with their compensated sums - become one function over
    a comptime row accessor, used by zimrnum's `layerNormRows` (and through it the player) and by `norm_fwd` (the
    kit module then imports zimrnum, as `zn_binary` already does: `wants_zimrnum`). Mish is `zm.mish` and its slope
    `zm.mishSlope` everywhere already; SimNorm's group softmax becomes one function the same way.
  - THE TWO-HOT LOSS. `twohot_fwd` per row: the target symlog'd, spread over its two nearest of the 101 bins, the
    loss -sum(target x log softmax(logits)); `twohot_bwd`: softmax(logits) - target. The decode (a head's prediction,
    symexp of the expected bin value) a third kernel. All from zimrrl's own definitions (`symlog`, the bins), as
    `zrl_binary` calls zimrrl.
  *Progress:* C1a's first half DONE Oct 26 - the row statistics written once in zimrmath (`CompensatedSum` moved there,
zimrnum re-exporting it; `layerNormRowStatistics`/`layerNormValue`, `softmaxGroupStatistics`/`softmaxGroupValue`
over a comptime row accessor, `requireRowAccess`), zimrnum's `layerNormRows` and `simNormRows` through them, their
bits unchanged (zimrnum's layer-norm and SimNorm tests, the player's bit-for-bit test, all pass). C1a DONE Oct 26:
`norm_fwd` (one thread per row, through `zm.layerNormRowStatistics` over an `ActsRow` accessor; keeps n and each
row's inverse spread), `mish_fwd`, `simnorm_fwd`; the uniform gains `norm_epsilon` and `simnorm_group` (two padding
words); on the CPU twin, on the graph's own pre-activations, the graph's output to the bit, the normalised rows and
inverse spreads zimrmath's; from the input, the whole layer to 2.4e-7 (Mish) and 6e-8 (SimNorm). The pages that build
their pipeline table from the kit's whole kernel list (cartpole_duel, track_train, getup_train, geno_train) now share
`zn_mlp_entries` instead of four copies of it; their WGSL builds. C1b DONE Oct 26: the backward's row
arithmetic in zimrmath (`layerNormGradientCouplings`/`layerNormInputGradient`, `softmaxGroupGradientDot`/
`softmaxGroupInputGradient`, each checked by central differences), zimrnum's `layerNormRowsBackward` and
`simNormRowsGrad` through them (the backward's normalised values now the forward's to the bit - it had divided by the
spread where the forward multiplies by its inverse), and four kernels: `mish_bwd`, `simnorm_bwd`, `norm_params_bwd`
(column sums, `accumulate`), `norm_bwd`. Every gradient of a normed layer against the graph's to 9e-8; the largest
weight gradient against the kit's own central difference to 4e-5 (Mish) and 4e-4 (SimNorm) relative. C1c's FIRST HALF
DONE Oct 26: one softmax for zimr - `zm.softmaxGroupStatistics` now compensated, and `zimrnum.softmaxRows` and the
cross-entropies' log-sum-exp (`rowLogSumExp`) through it (they had been three: compensated with `>`, plain with
`@max`, plain with `@max`); the two-hot's arithmetic in zimrmath (`symlog`/`symexp`, `binSpacing`, `binPosition`,
`gridPosition`, `gridShares`), zimrnum's `CategoricalScalar` and `addPointMassToGrid` through it. zimrnum's, zimrrl's,
zimrmath's and the robot family's tests pass. C1c DONE Oct 26: `twohot_fwd`, `twohot_bwd`,
`twohot_decode` (one thread per row, the target's two bins found where needed, `TwoHotAxis`, a new 16-byte uniform
block: low, high, axis, divisor); on the CPU twin each row's loss, the batch's gradient and the decoded values equal
zimrnum's `softCrossEntropyRows`, `softCrossEntropyRowsGrad` and `CategoricalScalar.decode` to the bit, targets
inside bins, on one and past both ends. C1d DONE Oct 26 (one turn cut off
after writing it; found on disk, run in the next): `vk-host-test`'s kit check runs the normed layer forward and
backward (Mish and SimNorm) and the two-hot loss, gradient and decode on lavapipe (llvmpipe, Vulkan 1.4) and on the
CPU twin from the same data and compares every value: largest relative gap 2.2e-7, no validation errors or warnings;
CONTROL: one gain changed on the twin alone - gap 1.3e-2, refused. PHASE C1 IS COMPLETE. NEXT: C2, the agent's
update on the GPU.
*Steps:* C1a the shared row statistics and `norm_fwd` with Mish and SimNorm forward - known answer: a NormedDense
  forward on the CPU twin against zimrnum's graph, the norm and activation BIT FOR BIT on the same pre-activations,
  the whole layer to rounding; C1b the backward kernels - known answer: every gradient (input, weight, bias, gain,
  norm bias) against the graph's, to rounding, and a finite-difference check of one; C1c the two-hot loss and decode -
  known answer: zimrrl's loss and gradient on the same logits; C1d all of them on lavapipe, the device the trainer
  runs on - the CPU twin's numbers again, to the conformance table's tolerances.
**C2. Its update on the GPU** (L7): the encoder, the dynamics ensemble's latent rollout, the consistency, reward and
value losses, the policy's loss (KL to the target policy, the scaled entropy), Adam, the targets' Polyak. *Known
answers:* agreement with the CPU agent's update at reduced widths over the first steps, both converging. *Turns:* 4-5.
*Made precise Oct 26:* in three pieces, each with its own known answer against the CPU agent's update on the SAME
replay window (`Bmpc(f32).Learner`, reduced widths, the window uploaded as the kit's acts): C2a the encoder and the
dynamics heads unrolled over the window, with the consistency loss; C2b the reward and value heads on every head's
latents, with their two-hot losses and the model's backward and Adam; C2c the policy's loss and its update, and the
targets' Polyak. *C2a's FIRST HALF DONE Oct 26:* `robot_bmpc_kit.zig` - `KitLayout` (offsets counted
before any buffer exists), `KitNetwork(M)` (a zimrnum `Mlp` on the kit: each layer's parameters in zimrnum's tensor
order, the kit's module a type parameter as `robot_latent_kit`'s is), and its `Application` (one batch through it, its
own activation regions; `forward` with an input stride, `backward` over the first rows only, `accumulate` for a
network applied at several steps) - an encoder-shaped and a head-shaped network against zimrnum's graph: output,
every tensor's gradient, the input's, to 1e-5 (the input's to 1e-10). C2a DONE Oct 26: `KitRollout(M)` - the window's
observations encoded in one pass, every head rolled through wide rows [z | a] joined by `place_columns`, the
consistency's backward through time (`mse_bwd` now weighted by `loss_weight`, default 1 bit for bit; `lat_take` for
the next step's road; `take_columns` for the first head's share of z_0's gradient) and the encoder over step 0's rows.
Against `LatentRollout` on the same window (4 windows, 3 steps, 2 heads): the consistency to every digit
(1.6130576e-2), every encoder and head gradient to 2.4e-8 (gradients up to 2.8e-2); CONTROL: without the gradient
through time the test fails. On lavapipe: with C2's other pieces, in one host check (T20). C2b DONE Oct 26:
`KitWorldModel(M)` - the reward head on every dynamics head's wide row [z_t | a_t], each value head on its z columns
through the same stride, their two-hot losses (`twohot_bwd` now weighted by `loss_weight` too, default 1 bit for
bit), every head application a READER of its latent (`KitRollout.addLatentReader`) whose gradient the backward through
time adds, and BMPC's total 20 x consistency + 0.1 x reward + 0.1 x value. Against `WorldModelLoss` on the same
window (2 dynamics heads, 2 value heads): the total to every digit (0.8622778), all 9503 gradients to 4.8e-7
(gradients up to 0.57); CONTROL: without the readers' gradients the test fails. NOT YET: value dropout (BMPC's 1%
on a value head's first layer) - the known answer turns it off; the kit's dropout comes with C2c or C5.
C2c's FIRST HALF DONE Oct 26:
the world model's update on the kit - `grad_square_partials` and `clip_factor` (one clip of the global norm, the
chunks' compensated sums), `adam_clipped` (Adam's arithmetic now one `adamStep` shared with `adam`), the encoder at
0.3 x the rate, and `polyak` on zimrmath's `polyakFollow` (the increment form, endpoints exact - zimrnum's
`polyakUpdate` now calls it too, so host and kit follow to the same bits; the kit's had been the two-term form).
Against the CPU agent's clipGradNorm, two Adams and polyakUpdate over two updates (the clip set to 0.5 so it
engages): the norms equal (4.763688), every parameter and target within 1.8e-7. The world-model tests now share a
`WorldModelFixture`. C2c's policy half, FIRST PIECE DONE Oct 26: `policy_distill_bwd` - the
distillation loss's gradient at the policy network's raw outputs in closed form (the TanhMeanGaussian head, the KL
toward the planner's Gaussian averaged over dimensions and over the scale, the entropy bonus), each row's divergence
and entropy written beside it; against zimrrl's `PolicyDistillationLoss` at a fixed scale (3 steps x 5 latents, 4
actions): the total to 3.1599422, every policy gradient within 8.3e-7 (gradients up to 3.6). The running scale
DONE Oct 26: `policy_divergence` (the distillation's per-row divergence alone - one `distillRow` shared with
`policy_distill_bwd`) and `running_scale_update` (one thread: an insertion sort of the first step's divergences, the
5th and 95th percentiles by zimrmath's `quantileOfSorted`, the scale moved by `runningScaleStep` - both now zimrnum's
`quantileSorted` and `RunningScale.update` too - kept in acts, its reciprocal beside it); against `RunningScale(f32)`
over three batches, the floor engaged in one, the scale to the bit. C2c DONE Oct 26: `KitPolicyLearner(M)` - the policy applied to every dynamics
head's rolled latents at every step, read in place in the rollout's wide rows through their stride; the first step's
divergences, the running scale moved by them, every row's gradient and the policy's backward (its gradients summed
over steps and heads), its own clip and Adam (epsilon 1e-5) - nothing read back. Against the CPU agent's
`PolicyLearner.update` (its steps 3-4, on the CPU world model's own rolled latents) over two updates, the clip engaged:
the scale equal (1.2542592, 1.4936603), the norms to 2e-7, the gradients to 3e-7 of the largest, every parameter to
1.2e-7. NEXT: C2d.
*Review and dedupe (Oct 26, second pass):* `KitLayout.requireFitsKit(M)` checks every buffer against its real
capacity (acts 2^21, the others 2^18), used by `KitMlp` and the world model's tests - `KitMlp` had checked acts
against the smaller size and the world model nothing; `KitWorldModel.init` asserts its networks lie in the order the
clip assumes. Adam's bias corrections had been formed five ways across the kit's hosts (exp-log with the betas
hardcoded, `zm.pow`, `powInt`); now `zn.adamCorrectionMultipliers`, `powInt` as zimrnum's own Adam forms them, in
every host but `robot_latent_kit` (whose running product matches its own CPU reference to half an ulp). zimrnum's
GPU-backend row kernels (`layernorm_rows`, `softmax_rows`, `log_sum_exp_rows`) had their own plain-sum loops; they
now call zimrmath's row statistics like the host, added to `zn_unary`'s audit of branch-free `zm` calls.
*Dedupe (Oct 26):* `kit_mlp.zig` already held "an ordinary MLP on the kit" (`KitMlp`, used by `robot_world`), its
own hand-made layout of one network beside `robot_bmpc_kit`'s `KitNetwork`. The generic part - `KitLayout`, the layer
kinds (now with `dense_tanh` and `dense_relu`, the activation fused into `dense_fwd`), `KitNetwork` and its
`Application` (with `forwardRows` for a short batch) - moved to `kit_mlp.zig`, and `KitMlp` is now one `KitNetwork`
and one application of it, its API and its tests unchanged; `robot_bmpc_kit.zig` keeps only the rollout and the world
model. Still laid out by hand, candidates for `KitNetwork` when next touched: `robot_gym`'s `GpuPpoOn` and `GpuSacOn`
(tanh networks, `kitLayer`). SuperTrack's `robot_latent_kit` and `robot_supertrack` run on fused kernels - a different
layout for speed, joined by T15 if SuperTrack moves to normed layers. *Folded in (T20):* each piece's known answer runs twice - on the CPU twin against the CPU agent, and
on lavapipe against the CPU twin (as `vk-host-test`'s kit check does for single kernels) - so a whole update, not
only its kernels, is held to the device.
**C2d. The rest of the world model's update** (added Oct 26, reviewing the plan: the CPU learner's `learn` does
three things C2a-C2c's known answers set aside, each needed before the GPU learner trains as the CPU one does):
  1. THE VALUE TARGETS ON THE KIT (`zimrrl.LatentValueTargets`): target = R(z, a) + gamma x (1 / heads) x sum over
     dynamics heads of V_target(f_i(z, a)), with z each stored step's TRUE latent and a the policy's draw there.
     The true latents are already on the kit - the rollout's encoder pass holds the latents of o_0 .. o_H - so the
     target is the policy (and its draw), the reward head on [z | a], each dynamics head one step ahead, the target
     value heads averaged: networks the kit already runs. The policy's noise is the CPU agent's counter-based `Rng`
     for the known answer, uploaded; drawn on the device by the kit's hash noise once the known answer holds.
  2. FINISHED WINDOWS (`LatentRollout.setFinished`): a window that runs past its episode's end counts for nothing
     after it - the consistency's mean taken over the windows still counting at each step, the reward and value
     target rows zeroed. On the kit, a per-step column of counting windows read by `mse_bwd` and the two-hot
     kernels, and the step's mean factor.
  3. VALUE-HEAD DROPOUT (BMPC's 1% of a value head's first layer, fresh masks every update): a mask region per value
     application, applied after the first layer's activation and in its backward; uploaded from the CPU agent's
     masks for the known answer.
*Known answer:* one whole `WorldModelLearner.learn` against the kit's on one sampled replay batch - windows that
cross an episode's end, dropout on - every parameter after the update, to rounding. *Turns:* 2-3.
*Progress:* 1. DONE Oct 26 - `KitValueTargets(M)`: the true latents read from the rollout's encoder pass (its first H
blocks), `policy_draw` (zimrmath's `tanhMeanGaussianDraw`, now zimrrl's head's draw too; the policy head's arithmetic
one `policyHead` in the kit, shared with the distillation), the reward head, every dynamics head and every target
value head on the wide rows, `value_target_combine` in the host's order - into the world model's value targets.
Against `LatentValueTargets.compute` (2 dynamics heads, 2 target heads, the CPU agent's counter-based noise
uploaded): every stored step's target within 4.2e-7 (absolute: a decode's rounding is its bins' size); CONTROL: one
noise value changed - fails. 2. DONE Oct 26 - finished windows:
`zn_mlp.RowMask` and three uniform words (the mask's kind, its column, the step's mean factor), read by `mse_bwd`
(the gradient times the row's flag and the factor), the two-hot kernels (the row's two shares times its flag, as the
host multiplies its target row) and the distillation (the row's weight times it); `KitRollout.writeFinished` writes
the counting column and the factors (window_count / still counting, 0 when none) from a replay batch's flags -
every flag 1 and factor 1 by default, bit for bit as before. Against `LatentRollout.setFinished` (two of four windows
finished, at steps 1 and 2): the total 0.7794130 and every gradient to rounding; CONTROL: the flags left off the kit
- the unmasked 0.8622778, refused. 3. DONE Oct 26 - value-head dropout: `KitLayer.dropout` (a normed layer's own
rate), `kit_mlp.Dropout` per application (`applicationDropping`; the world model's value heads `.on` by
`LossOptions.value_dropout`, everything else off), a mask region per dropout layer, `mask_values` after the linear part
and `mask_gradients` in the backward, the masks drawn on the host by zimrnum's now-public `fillDropoutMask` from the
generator split as `WorldModelLoss` and `Mlp.apply` split it (dynamics head, step, value head, then the layer -
the layer's split found when the first run's gradients came out 2% off); a mask of ones is no dropout, bit for bit.
Against a `WorldModelLoss` with a generator (25% dropout for the test): every gradient to rounding. C2d's KNOWN ANSWER DONE
Oct 26 - C2 IS COMPLETE: the CPU agent's own f32 `WorldModelLearner` - a replay of four short episodes, one `sample`,
one `learn` - against `KitWorldModel` + `KitValueTargets` on the same batch (laid out as `loadWindows` does, the
flags, the targets' noise and the dropout masks from the learner's own generator): 6 of the 12 stored rows finished,
12 dropout masks, every one of the 14751 parameters of the nine networks within 3.7e-9, the value targets of every
counting row within 2e-6. Found on the way: `resampleDropout` draws a node's mask from the update generator split by
the node's index alone, where `Mlp.apply` splits by the layer as well - `kit_mlp.DropoutGenerator` now names whose
generator a mask is drawn from (the network's or the dropout layer's). NEXT: C3, the planner on the GPU.

**C3. Its planner on the GPU** (L8) - in four pieces, as C2 was (Oct 26): C3a the scores, C3b the policy's own
plans, C3c one MPPI iteration (sample, elites, refit), C3d the whole decision (iterations, the warm start, the chosen
elite and its first action) against the CPU actor's decisions. C3a DONE Oct 26: `KitPlanScorer(M)` - each state
encoded once, its latent broadcast to every candidate's wide row (`broadcast_rows`), every candidate rolled under
every dynamics head with ONE application per network reused at every step (a score needs no backward) and two wide
rows per head alternating, the reward head at every step, every value head at the depths the objective weighs, and
`plan_score_combine` (one thread per candidate, the host scorer's order of arithmetic) - against
`LatentPlanScorer.score` for both objectives with a pessimism of 0.7: every score within 2e-6, every variance within
1e-4 of itself. C3b DONE Oct 26: `KitPolicyPlans(M)` - for every state its policy plans,
rolled through a pair of alternating wide rows (the policy reads the latent columns, `policy_draw` writes beside them,
the FIRST dynamics head steps them, as the CPU actor plans), each step's actions carried into the first rows of each
state's block of the scorer's candidates (`copy_row_blocks`); the scorer's own observations and encoder pass. Against
`LatentPolicyPlans.fill` (2 states x 3 plans among 6 candidates, 3 steps, reanalyze's spread [-2, 1], the same
counter-based noise uploaded): every action within 1e-6, every other candidate row untouched; CONTROL: one noise value
changed - refused. NOTE for C5: production sizes (hundreds of candidates per character, 512-wide networks) need acts
far beyond 2^21 floats - the planner's buffers, or the kit's, grow then. C3c DONE Oct 26: `KitMppi(M)` -
each state's Gaussian in acts; `mppi_sample` (one thread per value, into the scorer's candidate actions, the policy's
rows left alone), `mppi_elites` (one thread per state, no sort and no marks: each pick the largest (score, candidate)
pair strictly below the last, which is the host's stable sort read from the end), `mppi_refit` (one thread per step
and dimension, two passes as the host); `zm.rankableScore` now the one definition. Against `Mppi.sample` + `refit`
(2 states x 8 candidates, 2 the policy's, 3 elites; scores with a NaN, both infinities, a tie and a three-way tie):
the candidates within 1e-6, the elites exactly, weights within 1e-7, means and spreads within 1e-6. FOUND A BUG IN
THE CPU PLANNER on the way: `rankableScore` mapped +inf to `zm.highest`, which is infinity for a float, not the largest
finite value its doc promised - an infinite best score made every weight exp(inf - inf) = NaN and broke the refit;
now `floatMax`, with a test. C3d DONE Oct 26 - C3 IS COMPLETE: `KitPlanner(M).decide` - the policy's plans,
the warm start (`mppi_begin`: one thread per state and dimension walking up the steps, so the shift is in place), the
rounds (each round's noise its own block of acts), the choice (`mppi_choose`: the drawn elite's first action and the
first step's spread, a flag rather than a `break` in the draw's loop) and the exploration (`mppi_explore`), the
Gaussians kept in acts between decisions. Against the CPU agent's own `Actor.act` (2 states, 2 policy plans among 8
candidates, 2 rounds, 3 elites, both dynamics and value heads, exploring), over a cold decision then a warm one:
every target, first spread and explored action within 1e-6, every chosen elite exactly - the floor and the clamps
engaged. NEXT: C4, the cartpole gate.

 MPPI's candidates under every head, the multi-horizon mean, the ensemble's
score and pessimism. *Known answers:* the CPU actor's decisions on the same states. *Turns:* 2-3.
*Folded in (T11, "few planners, many actors"):* the planner's batch is the characters that PLAN; a run setting
`planning_characters` (default: all of them - the paper's agent) lets the rest act on the policy with exploration
noise, as SuperTrack's characters do, so a run on a slower GPU trades search for throughput explicitly instead of
running at a fraction of real time. Reanalyze keeps every stored state's targets fresh either way. Known answer: at
the default, the same decisions as without the setting; with fewer planners, those characters' actions are the
policy's, bit for bit.
**C4. The cartpole gate on the GPU** (L9): the GPU agent reaches the CPU gate's 0.333 in minutes, the kit run
optimised on its CPU twin. The 0.333 is the CPU agent's LEARNING level at the gate's budget (Oct 4: 0.333 up trained
against 0.153 random); the CPU gate's own bar of 0.9 - mastery - has never passed, needing BMPC's tens of thousands of
updates. (An Oct 26 note here wrongly called 0.333 an earlier gate's number; corrected.) In three pieces (Oct 26): C4a the learner, C4b reanalyze, C4c the
trainer's frame loop and the gate's run. C4a DONE Oct 26: `KitLearner(M)` - the CPU `Learner.update` on the kit: the
batch sampled by the CPU learner's own call, laid out as `loadWindows` does with the policy's targets from the rows
(spreads as logarithms), uploaded REGION BY REGION (each kit piece now has an `upload...` beside each `write...`,
since the rest of acts holds what the device keeps - the running scale, the planner's Gaussians), the world model's
update, the policy's unless pretraining; counters (Adam's steps, the real updates), so used through a pointer;
reanalyze refused at `init` until C4b. Against the CPU agent's own `Learner` (reanalyze off) over three updates -
pretraining, then two whole: every parameter of every network within 3.6e-7, the policy moving one and two Adam steps,
the running scale 1 -> 1.172 -> 1.328 on both. C4b DONE Oct 26: reanalyze in `KitLearner` - a second `KitPlanner` over
the batch's H x R stored states (the reanalyzing planner's settings, the policy's plans at exploration's spread),
deciding from scratch and evaluated before the world model learns; the targets read back (asserting the readback
reflects every dispatch - the one place an update waits for the device) into the batch's rows and the replay's
(`writeBack`). `KitPlanner.writeDecisionInputs` / `uploadDecisionInputs` now draw and send a decision's inputs as the
CPU actor's `act` does (the decision test uses them too); test helpers `KitLearnerSetup` and `learnerTestReplay` shared.
Against the CPU learner with reanalyze on every real update (2 of 4 windows, 8 candidates, pessimism 0.5), each side
its own replay copy, over three updates: every parameter within 8.8e-7, every stored row of the two replays within
6e-8, 36 then 48 values rewritten. C4c DONE Oct 26 - C4 IS COMPLETE: `KitTrainer(M, Environment)` - the CPU
trainer's frame loop with the CPU trainer's streams (act, step on the host, store with the planner's targets, advance,
the schedule's updates); `placeAgentNetworks` / `writeAgentParams`; FORWARD-ONLY applications (no gradient regions;
the planners and the value targets; a backward refused); the activation gradients' buffer sized on its own
(`dacts_len` 2^20, the parameters' buffers unchanged); reanalyze planned in CHUNKS of stored states (each state's
search its own, its noise by its own number - the reanalyze test now plans in two chunks and still equals the CPU's one
decision). The gate (`zig build bmpc-cartpole -Dtest-filter="kit cartpole gate"`, built ReleaseFast - 170 s, against
360 s ReleaseSafe, numerically identical): 0.425 up trained on the kit, 0.153 random - PASSED at the CPU level.
Measured beside it, the CPU agent at this budget: 0.518 (seed 7; 0.513 in f32), 0.295 (seed 11), 0.408 (seed 23) - the
kit inside the CPU's own range. The uncertainty signals' first record (`KitPlanner.readSignals`, one evaluated
episode, its pole falling): the score 6.24 -> 1.82, the heads' disagreement x10 near 60 degrees, the value head's width
1.04 -> 0.36, the first layer's inverse spread 79 -> 6 (the sharpest), the latent's entropy flat (1.6-1.7 of 2.08).
NEXT: C5, the GPU learner in the trainer. *Turns:* 3.
*Folded in:* the first GPU value that trains is where the agent's own uncertainty signals are first READ, so C4
also prints them along one evaluated episode - the reward and value heads' two-hot widths (T19), the encoder
SimNorm's mean group entropy (T13), its first layer's inverse spreads (T17), the dynamics heads' disagreement
(pessimism's own) - all values the forward pass already computes. No claim yet: a record of what each looks like
on a task the agent masters, for D2's view to compare the dance against.
**C5. The GPU learner in the trainer** (L10): the same state file and policy file as the CPU learner's, so a run can
move between them; `runTdmpcGpu`. *Known answers:* a CPU run's state resumed on the GPU continues; losses finite and
falling; judged. *Turns:* 1-2.

#### THE NEXT TEN TURNS (decided Oct 26, Simon: "try the ideas that make a real difference first; test little; be
confident theoretically")

THE REASONING. The north star is a character that tracks the dance at SuperTrack's quality and comes back from big
perturbations. Recovery needs three things, and they depend on each other in one order:
  1. DATA - perturbations and their consequences. No learner learns recovery from states it never visits: today the
     gym has no pushes, and SuperTrack resets at the failure rule, so its model has never seen a fall and nothing after
     one reaches its policy.
  2. CREDIT past the window. SuperTrack's pathwise gradient sees 32 frames: a step that first raises the tracking error
     and then saves the balance looks worse than a lean that falls just after the window. A learned value of the
     future cost at the window's end gives that step its due - SVG(H), MAAC and Dreamer's actor, all of which work.
  3. DISCOVERY of strategies a local gradient cannot reach (stepping, kneeling, getting up). Search does that: MPPI
     against the model, with an exact cost and the value's tail, on the few states where tracking is in danger, its
     answers distilled into the policy.
So the turns build R5.3's recommended design ("SuperTrack with a pessimistic value tail and a sparse planning
teacher"; R5.4's P1, P2, P5), with phase H's H1 (= P1) and H2 (= P5's planner) folded in, and EfficientTDMPC's kit
pieces - the two-hot heads, MPPI's kernels - reused inside SuperTrack's learner rather than run as a learner of their
own first. SuperTrack's GPU kernels live in `zn_mlp`, the kit's own module, so its learner and a `KitNetwork` critic
share one pipe and one set of buffers; `st_policy_bwd` runs each window backward one thread per row, so the value's
gradient enters as the state adjoint at the window's end, zero today.

HOW MUCH TESTING. One or two checks a turn, only where an error would be silent: a new term set to zero gives the old
learner bit for bit, and a gradient by central differences where a sign or a scale could hide. Behaviour is judged by
the night runs, not by tests.

  N1  PUSHES AND THE RECOVERY PROBE (D4, promoted). A push schedule for the fleet - an impulse on the pelvis of a size
      drawn from bands, at random phases, its rate a run setting - used in training and, seeded and graded, in the
      judge's recovery probe: per learner, recovery rate and time to recover against push size. Checks: a push of
      zero is the plain step; the velocity change is impulse / mass. Then the probe's baseline for the current
      SuperTrack policy - the number the next nine turns are judged against.
      DONE Oct 26: `robot_track.Pushes` (the fleet's one push - `Fleet.push`, a velocity change of the whole body in a
      uniform horizontal direction - on a schedule or at random moments at a rate, speeds from a range; the old shove
      folded in), `robot_track.probeRecovery` (per band: a second's settle, one push, a three-second watch; survived
      when the failure rule does not fire, tracking back when the reward's running mean regains 0.9 of its level, with
      the time), `lab.probePolicy` and `lab.RecoveryLog` (`recovery.csv`), SuperTrack's `pushes` run setting, and the
      night trainer probing at every judgement (the servo first) for PPO and SuperTrack. The servo alone on a walk
      loses most starts within the settle - only a trained policy's numbers say anything - so the BASELINE is the
      first night's: Simon's current SuperTrack policy, probed. Not yet: pushes in PPO's `TrackEnv` (a setting to add
      when PPO is compared), and EfficientTDMPC's lab learner.
  N2  SUPERTRACK WITHOUT RESETS (T1 + T3, M8). A population in one fleet: a share of characters keep going past the
      failure rule (an aftermath of a few seconds, or to the episode's end), the rest reset as today. The world model
      trains on every window - how a body falls is knowledge; the policy's pathwise loss only on windows that start
      before a loss - through a fall the tracking gradients saturate to noise. Check: an aftermath of 0 gives today's
      trainer, row for row.
      DONE Oct 26: the replay's per-row `after_loss` flag (recorded while the character's aftermath runs); the fleet's
      `aftermath_share` (the first round(share x envs) characters live on, the rest reset); `WindowStart` - the
      sampler draws as before and redraws a window that may not start where it fell, so with no aftermath the two
      rules draw the very same windows; SuperTrack's GPU learner drawing its world-model windows from anywhere and its
      policy windows before a loss; the lab's `aftermath_steps` / `aftermath_share` run settings, to the night
      trainer's fleet. Checked (the servo alone, losses certain): only the living-on half flags rows, no before-loss
      window starts on one, and with no aftermath nothing is flagged and both rules give the same windows.
  N3  THE FAILURE BARRIER (T2). SuperTrack's per-step cost gains softplus(margin / width) on the failure rule's three
      margins - the head's height error against 0.25 m, the root's distance against 1 m, its angle against 1.57 rad.
      The rule is a function of the state; the barrier turns its cliff into a slope the pathwise gradient feels
      before the fall, and the value learns it too. Check: the slope at a margin by central differences.
      DONE Oct 26: `zm.smoothHinge` / `smoothHingeSlope` (width x softplus((v - margin) / width), on zimrmath's own
      softplus and sigmoid); `lat_barrier_bwd` - one thread a row, added after each rolled step's tracking term in
      `LatentKit.policyBackward` - on the head's height error (0.25 m) and the tilt, 1 - cos(up, up_ref) (margin 1,
      90 degrees), both read from the rolled features un-normalised; `FailureBarrier` (weight 0: today's loss), a GPU
      learner option kept in its state file (magic ZSTSTAT2) and the lab's SuperTrack setting. TWO of the rule's
      three margins: the root's distance from the reference's is not in SuperTrack's features (each root's own frame),
      so it cannot be read from what the world model rolls. Checked: every column's gradient against central
      differences of the host's value on rows either side of both margins (2e-4), the other columns zero. Also fixed: a
      latent-kit fit test whose premise C4c's larger gradient buffer had changed (now eight times the rows overflows).
  N4  THE CRITIC (P1, first half). C(features of s, reference context) - the discounted future COST, SuperTrack's own
      per-step cost (N3 included), so the tail and the window add up to one objective. An ensemble of two-hot heads
      on the kit (`KitNetwork`, the kit's two-hot kernels, Adam, Polyak 0.01), its input SuperTrack's features of the
      state and the next few reference frames' (R5.6's open question, settled here: 4 frames, 0.1 s apart), trained by
      TD on real windows: target = c(s_t) + gamma x C_target(s_(t+1)). Reset-free data, so no terminals: a fall is
      a costly state, not an end. Check: the TD target on a hand-made transition.
      In two pieces (Oct 26). N4a DONE: `LatentCritic(M)` in `robot_latent_kit` - two-hot heads (EfficientTDMPC's
      spec: two mish layers, 101 bins, last layer zero) with target copies, on [goal | state]; its targets from a
      gathered window batch: `place_columns` lays every real step 1 .. W-1 and the step after it side by side (the
      states and goals lie in consecutive blocks, so one call carries all steps), the new kernel `lat_tracking_cost`
      gives each transition's cost (the mean squared distance + the barrier - the barrier's measures now one inline
      function shared with `lat_barrier_bwd`), the target heads decode, and EfficientTDMPC's `value_target_combine`
      gives cost + gamma x their mean (gamma 1 - 1/90). Found on the way: `kit_mlp`'s tests imported the kernel file by
      path, which collides with the headless trainer's `zn_mlp` module once SuperTrack's learner reaches `kit_mlp`; the
      tests now live in `kit_mlp_tests.zig`. Checked: on a hand-made batch with known target heads, every cost and
      target equals the hand computation, and every input row holds the goal beside the state.
      N4b DONE Oct 27: `LatentCritic.update` - targets, each online head's two-hot gradient back through it, the
      global-norm clip and Adam over the online heads (placed before the target heads, one contiguous range), Polyak
      (0.01); its settings an extern `CriticOptions`; SuperTrack's GPU learner builds it after its data when
      `train_critic` is set and updates it in every world-model round on the windows that round gathered; the lab's
      `train_critic` / `critic` run settings. Checked: one update moves every head's prediction toward its target, on
      the target's side; with the critic on, six rounds give six critic updates and 97% of its weights moved, all
      finite. NOT YET: the critic in the learner's state file (a resumed run starts its critic afresh) - with N5.
  N5  THE VALUE TAIL (P1, second half; H1). SuperTrack's policy loss gains gamma^W x C(s_W): the critic's input
      gradient, through the features' backward, becomes `st_policy_bwd`'s adjoint at the window's end. The tail's
      weight ramps up from 0 over the first updates, because an untrained critic's slope is noise. Checks: a zero
      critic gives today's gradients bit for bit; the tail's gradient by central differences on a short window.
      DONE Oct 27: `LatentCritic.Tail` - the online heads applied once more to the policy rollout's last state; its
      gradient back through each head's decoded value (the new kernel `twohot_value_bwd`: v'(m) p_j (x_j - m), with
      `zm.symexpSlope`), the head's backward to its input, and the state half ADDED into the last state's gradient
      (`lat_take`) - called in `LatentKit.policyBackward` right after the last step's tracking and barrier terms;
      `forwardValues` for watching its size. The learner's `value_tail` (its full weight, 0 for off) and
      `value_tail_ramp_updates` (a linear ramp from 0); the lab's settings. The critic now in the state file (magic
      ZSTSTAT3): its parameters and moments saved straight after the two networks', its update count among the
      counters, its size among the shape. Checked: a critic as it starts (zero last layer) adds exactly nothing, to the
      bit; the tail's gradient in every state feature against central differences of its value by the kit's own
      forward (within 0.5%); a trained critic comes back from the state file weight for weight.
  N6  PESSIMISM, AND THE FIRST NIGHT (P2, E1). The tail reads the ensemble's mean + beta x sigma of the cost, paying for
      what the heads dispute (check: beta = 0 is N5 bit for bit). Then Simon's night on Windows: today's SuperTrack
      against SuperTrack with N1-N6, the same budget, judged by the judge's precision and the probe's recovery. The
      decision point: recovery up, precision kept?
  N7  THE TRACKING PLANNER (P5's planner; H2). MPPI on the kit - C3's kernels as they are - scoring candidates with
      SuperTrack's own world model (`st_world_fwd` over candidate rows), the exact cost and the critic's pessimistic
      tail; SuperTrack's policy, rolled through its model, as the search's own candidates. Search finds the strategies
      a gradient cannot, against an objective that is exact where EfficientTDMPC's reward head is learned. Check: one
      candidate's score against the CPU model's on the same actions.
  N8  THE SPARSE TEACHER (P5 + T9 + T11 + T42). Flags pick a few characters a frame to act on the planner - the
      barrier's value (N3) and the encoder-free twin of T42, the first layer's inverse spread of SuperTrack's own
      policy: exploration that searches, only where it is needed. Their states and the planner's first actions are
      stored; SuperTrack's policy loss gains an L2 toward the planner's action on flagged states (the policy is
      deterministic, so no KL). Checks: no flagged state is N6's loss bit for bit; the planned share stays within
      its budget.
  N9  THE SECOND NIGHT. N8 against N6's run: the probe's recovery rate, the judge's precision, the share planned.
  N10 REVIEW AND THE TUTORIALS. A code review of N1-N8; the tutorials (robot-mocap: pushes, SuperTrack without resets,
      the barrier, the critic and its tail, the tracking planner, the teacher; zimrrl: the value tail's idea - SVG(H)
      - and pessimism); and the next ten turns, decided from the two nights' numbers.

RISKS, said before building. The critic's slope is untrained - the same reason MPPI uses scores alone (9.8) - and the
tail climbs it: the ramp, the ensemble's pessimism and the critic's layer norms are the mitigations, and Dreamer's
actor is the evidence that a value's gradient through a learned model carries. The reset-free share may slow
tracking early (PHC's forgetting: 59.4% -> 42.5% when mixed naively); the population keeps a resetting share, and N6's
night measures it. Pushes too large too early teach only falling: the bands start small.

DEFERRED, with the reason. C5 - EfficientTDMPC's GPU learner in the lab, with its state and policy files: its pieces are
built and checked (C2-C4); as a learner of its own it is not on the recovery path now. D1-D3, the lab's views: D2's
signal view after N6, once there is a value worth watching. Phase G, the flow actor: after the nights, if the recoveries
found lack variety (one way back where several exist), FPO on the PPO path first (G3). T5-T7, the learned hazard and
the blend: T42's free signal first (N8), a learned head only if it falls short.

#### THE NEXT TWENTY TURNS - ONE SYSTEM FOR THE FIRST NIGHT (decided Oct 27, Simon: "the first test should contain
everything that has a chance of working: the flow policy, SuperTrack with value, EfficientTDMPC planning recoveries -
all together in one complete system")

This replaces the rest of the ten turns above (N6 - N10 are folded in: N6's pessimism is S1, N7 - N8's planner and
teacher are P1 - P4, the nights are the end of this plan) and gathers phase G and R5.3 into one design.

THE DESIGN: ONE MODEL, ONE CRITIC, ONE COST, ONE ACTOR, THREE TEACHERS.

  one cost      c(s) = the tracking distance + the failure barrier (built: N3, `lat_tracking_cost`). The window's loss,
                the critic's targets, the planner's score and FPO's reward (-c) are all this one number, so every
                part pulls toward the same thing.
  one model     SuperTrack's world model (built), trained on every window - falls and their aftermaths included (N2).
                It gives the pathwise gradients AND the planner's rollouts. EfficientTDMPC's latent world model is not
                trained beside it: a second model would be a second, inconsistent view of the same physics; its
                planner machinery is what is taken (below). (If SuperTrack's model proves unreliable after falls - the
                T44 measure, logged from S5 - EfficientTDMPC's latent ensemble, built and checked in phase C, is the
                fallback scorer.)
  one critic    C(goal, state), the discounted cost-to-go (built: N4, N5), pessimistic (mean + beta x sigma over its
                heads). It serves four parts: the policy's value tail (N5), the planner's horizon, FPO's baseline,
                and - through its heads' disagreement - a hazard flag.
  one actor     A FLOW POLICY: a velocity network v([goal | state | x_t | time features]) integrated by K Euler steps
                from noise x_0 to the action x_1. Deterministic given its noise, so it has a gradient; several ways
                back where a Gaussian has one (FPO's evidence: under-determined tracking, 54% against 30%). It acts with
                PERSISTENT noise - one noise per character, drifting slowly (an Ornstein-Uhlenbeck process in noise
                space), so a character commits to the way back it began (T32) - and the same flow, sampled with M
                different noises, gives the planner M different ways back to start its search from (T33's idea, a
                multimodal prior for the search).
  three teachers, each a correction added to the same flow target:
    1. SUPERTRACK'S PATHWISE GRADIENT, through FlowDPG: the window rolled with the flow through the world model, its
       backward gives every action's total gradient dL/da (tracking, barrier, value tail - all of the window's
       future); FlowDPG turns it into a better action a* = a^ - alpha (|u| / |g|) g and the velocity is regressed
       toward it (with the plain flow matching anchor and the consistency term). This is SuperTrack's own learning
       signal, applied to a flow.
    2. EFFICIENTTDMPC'S PLANNER, distilled: on flagged states, MPPI over SuperTrack's model - candidates from the
       flow's samples and Gaussian perturbations of the previous plan, scored by the exact cost plus the pessimistic
       critic at the horizon, refitted by C3's elite kernels - and the flagged characters ACT on the plan
       (exploration that searches, T9). The plan's actions are stored and the flow matched to them (behaviour
       cloning by flow matching, which keeps the different ways back different instead of averaging them).
    3. FPO ON REAL RETURNS: on the last round's real transitions (on-policy - collected with the current flow and
       its recorded noise), the advantage from the critic, FPO's ratio from each action's flow matching loss, the
       clipped surrogate. Model-free credit, which still holds where the model is wrong.
  the gym       Pushes (N1), a population that lives on after a loss (N2), the dance, the judge and the recovery
                probe (N1) - the night's numbers.

WHY THESE PIECES FIT. Each teacher covers another's blind spot: the pathwise gradient is precise but local and trusts
the model; the planner searches globally but only where flagged and only through the model; FPO trusts nothing but
real returns, and is slow. The flow is the one place all three can write, as additive corrections to one target
(FlowDPG's observation). The critic and the cost are shared, so no two parts disagree about what is good.

HOW MUCH TESTING. As before: one or two checks a turn, where an error would be silent - a new term at weight zero
gives the old update bit for bit; a gradient by central differences; the kit against a CPU reference where one exists.

THE TURNS.
  S1  PESSIMISM, AND THE CRITIC IN THE LOGS. The tail reads the heads' mean + beta x sigma (beta a setting); the
      planner will read the same. SuperTrack's log gains the tail's size, the critic's mean and its heads'
      disagreement. Check: beta = 0 is N5 bit for bit.
      DONE Oct 27 (pessimism): `zn_mlp.ensemble_tail_weights` - each head's weight per row in P = m + beta s, (1/H)
      (1 + beta (C_h - m) / s); the row mask's new `weight_column` (its helper `rowWeight`, a counting flag or a
      weight alike) carries it into `twohot_value_bwd`; the tail's `pessimism`, the learner's and the lab's
      `value_tail_pessimism`. At beta = 0 the tail takes N5's path, unchanged. Checked: the pessimistic gradient
      against central differences of mean + beta x spread (within 0.5%, one feature's turning over against the
      plain mean's); every kit suite and lavapipe as before. THE CRITIC IN THE LOGS moves to S2: SuperTrack's log
      holds only the host's counters today, and the device's numbers (the tail, the planned share, each teacher's
      size) need one readback path, designed once there.
  F1  THE FLOW POLICY IN zimrrl - the CPU reference, one definition: `FlowPolicy(T)` on zimrnum's networks - the
      velocity on [condition | x_t | time features (a few sines and cosines of t)], the path x_t = (1 - t) x_0 + t a,
      the Euler sampler, the conditional flow matching loss |v - (a - x_0)|^2, FlowDPG's target (a^, the adaptive
      shift, the consistency term). Checks: the sampler exact on a constant field; FlowDPG's target by hand.
      DONE Oct 27: `zimrrl.FlowPolicy(T)` in R04 - the velocity an `Mlp` on [condition | x | time features], the
      time as sin/cos(pi f t) for f = 1, 2, 4 (half a cycle at the lowest, so no two times alike), a noise scale (a
      zero-initialised velocity starts the policy as "no correction, plus noise of s"), `sample` (K Euler steps on the
      graph, differentiable through all of them), `pathPointsAndVelocities`, `flowMatchingLoss` (on the graph, for
      the kit's checks to come), `flowDpgTargets` - with FlowDPG's consistency term found to be, on the straight
      path, (1 - t)^2 times the flow matching term, so the loss is two terms: the target's and the anchor. Checked:
      the sampler exact on a constant field (0.125 a step); the loss and FlowDPG's targets by hand. zimrrl tutorial
      5.5.
  F2  THE FLOW ON THE KIT: the velocity network a `KitNetwork`, one application per Euler step on wide rows
      [condition | x_t | time features]; kernels for the time features, the Euler step, the flow matching gradient
      and FlowDPG's target. Check: the kit against F1 to rounding, on the CPU twin and lavapipe.
      DONE Oct 27: `kit_mlp.KitFlow(M)` - the velocity a `KitNetwork` from the flow's own `Mlp`; a `Sampler` (one
      block of wide rows and one forward-only application per Euler step, the last step writing the action wherever
      its reader wants it) and a `Trainer` (one application forward and backward); the kernels `flow_time_features`
      (one time for every row, or each row's own), `flow_euler_step`, `flow_path_points`, `flow_dpg_bwd` (the plain
      flow matching gradient is `mse_bwd`); `KitNetwork.inputWidth`. Checked: on the CPU twin, the sampler's actions
      equal zimrrl's exactly, and the flow matching and FlowDPG gradients of every weight equal the graph's autodiff
      (within 1e-5, gradients of about 0.5); on lavapipe, the four kernels join the kit's comparison with its CPU twin
      (largest relative gap 2.2e-7, unchanged).
  F3  SUPERTRACK'S ROLLOUT WITH THE FLOW: in `LatentKit`, the policy's turn at each step becomes K Euler steps from
      that step's noise (hashed per update, row and step, as the exploration noise is now). Check: the rollout's
      actions equal F1's sampler's for the same noise and weights.
      DONE Oct 27: `robot_latent_kit.FlowActor(M)` (a `KitFlow` and its sampler over the rollout's rows) and
      `LatentKit.flow_actor`: when set, `policyStep` becomes `flowPolicyStep` - the wide row's [goal | state] copied
      into every block (new kernel `copy_columns`, strided to strided), the base noise sigma x the step's hashed
      noise (new kernel `flow_base_noise`, the very numbers `lat_act`'s exploration adds), the sample writing the
      action straight into the wide row's action columns; a flow needs the kit's action scale at 1 (the learner's
      fleet applies the one scale). Checked: a zero-velocity flow acts and rolls exactly as a zero Gaussian policy
      with the same exploration, every action and state to the bit; a moving flow's actions equal zimrrl's sampler's
      for each step's condition and noise (within 3e-8; the actions 0.08 off the noise); on lavapipe both new kernels
      equal their CPU twin.
  F4  TEACHER 1 - THE PATHWISE GRADIENT THROUGH FLOWDPG: the world model's backward already computes each action's
      gradient (what `lat_act_bwd` consumes); it becomes FlowDPG's g at that step, the flow's regression its update,
      Adam on the flow's parameters. Checks: FlowDPG's target on the kit from a planted gradient, by hand; with
      alpha = 0 the update is plain flow matching onto the rollout's own actions.
      DONE Oct 27: `FlowActor` gains its trainer over every (step, row), a `Teacher` (alpha, a step floor, lambda,
      the optimiser's settings), the clip's regions and `optimizerStep`; the flow's turn keeps its action packed per
      step (where the Gaussian policy keeps its raw output, so `lat_act_bwd`'s prices read it alike) and copies it
      into the wide row; `policyBackward` keeps each step's action gradient (new kernel
      `copy_columns_from_gradients`: dacts to acts) and leaves the policy's own input gradient out - the open-loop
      gradient, said in the code; after the loop the training rows are laid out from the rollout (condition, action,
      the step's base noise again, a time from the new kernel `flow_draw_times`) and FlowDPG's gradient taken;
      `policyTrainStep` takes the flow's step. FOUND BY THE CHECK: FlowDPG's step, scaled by the flow's own motion,
      is zero for a flow that starts at rest - and so is its anchor - so it could never begin to learn; the step is
      now scaled by max(|v^|, floor), the floor by default the noise's typical length sigma sqrt(action width), in
      zimrrl's reference, the kernel, the kit and the teacher (zimrrl's test gains a row at rest). Checked: a
      zero-velocity flow keeps, for step 0, the zero Gaussian policy's raw-output gradient exactly; every training
      row holds the rollout's own condition, action and noise; one train step moves the flow's last layer (27 of its
      251 weights, as a zero last layer passes no gradient back); lavapipe 3.1e-7 with the two new kernels compared.
  F5  ACTING WITH THE FLOW: the mirror's CPU sampler (K Euler steps from the mirrored velocity), persistent noise per
      character (the Ornstein-Uhlenbeck drift, slower while flagged), recorded with each step; the policy file's
      flow kind (velocity, K, time features, noise rule) and the lab player's sampler. Checks: the CPU sampler
      against the kit's; the noise process's stationary variance 1, by hand.
      DONE Oct 27 (the pieces): `KitNetwork.forwardHost` - any kit network on the host as the kernels compute it
      (the bias first and the inputs in order, zimrmath's row statistics for the norm, the same Mish and SimNorm),
      `widestOutput`; `KitFlow.sampleHost` - the K Euler steps on the host; `zn.SliceRow` made public (the host's
      accessor for zimrmath's row functions); zimrrl's `ouCorrelation` / `ouStep` - persistent noise, an
      Ornstein-Uhlenbeck process of stationary variance 1. Checked: the host sampler gives the kit's actions to the
      bit (gap 0); the noise keeps a unit spread and a step-to-step correlation of rho over 40,000 steps. MOVED TO F6:
      the learner acting with them (a mirror of the flow's weights, each character's drifting noise, judging at zero
      noise) and the policy file's flow kind - with the actor setting, the judge, the probe and the state file.
  F6  THE FLOW IN THE NIGHT TRAINER: the actor a run setting (`mlp` or `flow`), the judge and probe with the flow
      (judged at its persistent noise, and at zero noise - its typical action), the flow in the state file.
      Check: a run resumes bit for bit.
      In two pieces (Oct 27). F6a DONE: the learner - `robot_latent_kit.PolicyActor` and the extern `FlowSettings`
      (shape, sampler, FlowDPG's teacher, the noise's correlation time) as options; `buildExtras` - one layout for the
      critic and the flow actor, the flow's velocity drawn by zimrrl's `FlowPolicy` (zero last layer, noise scale
      sigma), its parameters straight after the critic's; the flow's mirror (the buffer's length, the flow's range
      filled) refreshed with the policy's; acting - each character's noise one OU step a frame (`zrl.ouStep`), times
      sigma, as the flow's start, the host sampler from the mirror; judging at zero noise, nothing drawn; the state
      file (magic ZSTSTAT4) - the flow's parameter count in the shape, its weights and moments in the saved range,
      each character's noise as a sixth section; the lab's `actor` / `flow` settings. FOUND BY THE CHECK: the
      readback window still stopped before the flow's weights, so the file could not be written - widened. Checked:
      with a flow acting and learning, a saved learner resumed writes back the very same bytes and chooses the very
      same action; the learner's, latent and lab suites pass. F6b, PART DONE IN THE REVIEW OF OCT 27 (it was a bug
      once the flow could run): the night trainer judges and probes a flow run through the learner's own actor
      (`ProbedController`: the servo, a policy file, or a learner's actor) and writes no Gaussian policy file, no
      checkpoint and no play check for it. LEFT: the run's preset (with S2).
  P1  THE TRACKING PLANNER'S SCORER: candidates rolled through SuperTrack's world model on the kit (rows = flagged
      states x candidates, H steps), each step's cost, the pessimistic critic at the horizon. Check: one candidate's
      score against the CPU world model's (`robot_latent`) on the same actions.
      DONE Oct 27: `robot_latent_kit.TrackingScorer(M)` - a second `LatentKit` of the training kit's world-model shape
      (so the same weights: a kit's weights start at the buffer's start), its activations and gradients placed after
      everything else (`LatentKit.placedAt`, its offsets listed as activation, gradient or shared, a field in none of
      the lists refused at compile time - proved by a planted field); rows [state][candidate], H steps; the rollout
      the kit's own `forwardRecorded`; each step's cost `lat_tracking_cost` with the training kit's barrier settings;
      the critic's tail at the plan's end (`Tail.forwardValues`); the new kernel `tracking_plan_scores` (minus the
      steps' costs and the pessimistic tail); `writeInputs` for host staging. Checked at the real sizes (291 / 70 /
      35), 2 states x 3 candidates x 4 steps: every score equals the CPU model's (`latent.stepWith`) rolled and charged
      the same way - gap 0.
  P2  THE TRACKING PLANNER'S SEARCH: candidates from M flow samples and from Gaussian perturbations of the previous
      plan; MPPI rounds on C3's elite, refit and choice kernels; the warm start; re-planning every few steps,
      warm-started, so a character keeps its way back. Check: on a planted cost whose best action is known, the
      search finds it.
      In two pieces (Oct 27). P2a DONE: `bmpc_kit.SearchShape` - what an MPPI search is over (states, candidates,
      horizon, action width, where the candidates' actions lie, step by step, and their scores) - so `KitMppi` takes
      a shape, not EfficientTDMPC's scorer (`KitPlanScorer.searchShape`, `TrackingScorer.searchShape`): one search,
      two scorers; the tracking scorer's packed candidate actions, copied step by step into its wide rows;
      `TrackingPlanner(M)` - begin, rounds of hashed noise / sample / score / refit, a hashed draw to choose, the
      targets; the hashed-number kernels renamed for every use (`hashed_noise`, `hashed_uniforms`). FOUND BY THE
      CHECK: the scorer first read its candidates' actions candidate by candidate while MPPI writes them step by step
      - the search steered by plans it never sampled (it settled at a third below doing nothing, its first action 0.47
      off); fixed, it finds the hidden plan. Checked: goals set to where a hidden plan leads, so it costs 0 - the plan
      settled on costs 6.6e-5 against doing nothing's 0.076, its first action within 0.013 of the hidden plan's.
      NOTED FOR P3: MPPI weighs elites by exp(temperature x (score - best)), TD-MPC2's rule for value-scale scores;
      SuperTrack's per-step costs are hundredths, so the weights are nearly flat and the search sharpens by its elites
      alone (as CEM). A temperature relative to the elites' own score spread would make it scale-free.
      P2b DONE: `TrackingPlanner.FlowPlans` - a placed world-model kit whose rollout is the flow acting
      (`FlowActor.actingOnly`: the learner's flow, a sampler of its own, no learning part - `learningPart` names the
      mistake of asking one for it); `decide` rolls the plans from their own seed and copies each step's into every
      state's first candidates (through `SearchShape.candidateActionAt`), which the search leaves alone;
      `writeInputs` stages the plans' goal columns as SuperTrack's gather does (the goal after each step);
      `LatentKit.actsWithPolicy` (a flow actor is a policy). FOUND BY THE CHECK: a kit without a Gaussian policy did
      not count its packed actions in its extent, so a flow given to it wrote them past its end, into the next
      reservation - the kit now counts every actor's actions. Checked: a flow blind to its goals, the goals set to
      where its first plan leads - that plan is placed (the host's, to 1e-5), scores best and about zero, and is the
      first elite. THE RE-PLANNING SCHEDULE moves to P3, where flags decide which characters plan and when.
  P3  THE FLAGS AND THE BUDGET: a character is flagged by the barrier's cost past a share of its margin, the critic's
      heads' disagreement, or living on after a loss (the get-up); at most a budget of characters plan per frame,
      held for a second once flagged (hysteresis). Check: with no flag the fleet acts exactly as without a planner.
      In two pieces (Oct 27). P3a DONE - what has no fleet in it: `zn_mlp.MppiTemperature` (absolute, TD-MPC2's
      rule and EfficientTDMPC's default; or relative to the elites' own spread, the worst elite weighing
      exp(-temperature) of the best in any units) in `mppi_elites` and `KitMppi.Options.temperature_mode`; the failure
      barrier as shared definitions - `barrierMeasuresOf` generic over a row accessor (the kernels' `ActsRow`, the
      host's slices) and `barrierHinges` - the tracking cost now through them; `robot_track_resident.planningHazard`
      (the barrier's unweighted value for a character's state against its goal) and `PlanningFlags` (start at a
      hazard threshold when a slot is free, most endangered first; keep until calm below a lower threshold for a run
      of steps; decide on starting and every few steps). Checked: relative weights equal for scores and scores x 100,
      the worst elite at exp(-2) of the best, the absolute rule differing (the control); the flags follow their worked
      table step for step; the host's hazard equals the kernels' barrier value (the tracking cost with and without the
      barrier). P3b NEXT: the planner in the learner - the hazards from each character's state, its slots as the
      planner's states, staging from the fleet and the clip's table, warm flags, acting from a plan between decisions.
      The critic's disagreement and the aftermath can join the hazard there.
      P3b-i DONE: the hazard redefined as a fraction of the barrier's margins - max(|head height error| / head margin,
      tilt / tilt margin), 0 on the reference, 1 where the failure rule fires - because the barrier's hinged value
      stays near zero until a fall is under way (found reading the margins: a hinge of 0.5 is a head half a metre past
      its margin); `PlanningSettings` (enabled, the flags', the search's sizes) in the learner's options and the lab's;
      every character's hazard computed as it acts (`characterHazard`), the flags run between steps (only while
      exploring), decisions counted; planning requires the task's head body. Checked: the barrier's measures read on
      the host as the kernels read them, the hazard by hand (a metre low against 0.25: 4); calm, nobody flagged;
      pushed sideways at 4 m/s, a character is flagged and decides - after 55 steps (0.9 s), at hazard 0.501: late,
      the argument for adding the hazard's slope (T59) in P3b-ii. P3b-ii-a DONE: ONE DECISION CLOCK - all planning
      characters decide together (every few steps, and at once when one starts), because the search warm-starts each
      plan moved forward by the steps since it was decided, and only a shared clock makes that number right for every
      slot (`PlanningFlags.steps_since_decision`, its worked table updated); `mppi_begin` shifts by
      `mppi_warm_shift` steps (default 1: EfficientTDMPC unchanged), `KitMppi.begin` and `TrackingPlanner.decide`
      take the plans' age; `plan_gather` - a planner kit's rows from each state's start and the resident reference
      table, in `lat_gather`'s conventions, held at the clip's last row - and `TrackingPlanner.gather` /
      `stateInputsAt`. Checked: the flags' new table; the warm start's worked rows (shift 1, 2, cold); every candidate
      row's start, references and goals equal the host's to the bit, rows past the clip held. P3b-ii-b NEXT: the
      learner's decisions - its planner, its slots' inputs uploaded, warm flags - the mailbox that brings the chosen
      plans back with the parameters' readback, acting from them, and the hazard's slope.
      REVIEWED (Oct 27): the flags' contract said to read the clock before a step for the plans' age - but `step`
      increments it before deciding and resets it after, so the true age was invisible and the read value one short
      (a decision every step would have warm-started by zero steps); `step` now RETURNS the plan age with each
      decision, the clock rests at zero while nobody plans, and the table checks the ages. Also: one definition of a
      normalised feature for both gathers (`normalisedFeature`); planning refuses barrier margins of zero (the hazard
      divides by them); the planner's kernels - the shifted warm start, the relative elites, the gather - joined
      lavapipe's comparison with the CPU twin (largest gap unchanged, 3.1e-7).
      P3b-ii-b1 DONE: the planner in the learner (`buildPlanner`: a slot per flagged character, the learner's world
      model, the critic's pessimistic tail, the flow's plans when the flow acts, elites relative to their spread);
      `planDecision` on every decision - each planning character's current state and its table rows uploaded to its
      slot, warm flags where the same character held the slot at the last decision, the gather, the search warm-shifted
      by the returned plan age, the mailbox; `plan_mailbox` - each slot's CHOSEN candidate's whole plan (not the mean,
      which averages ways back) into the parameter buffer after the parameters, stamped with the decision's step plus
      one (0: none yet), read back every frame, never saved (`readback_end` beyond `params_end`). FOUND: the readback's
      end was set only with extras - a learner without them read back nothing (the resume test caught it); and the
      default search (8 x 64 x 8) did not fit the kit's buffers - the layout refused it by its numbers - so the defaults
      are now 2 slots x 16 candidates x 4 steps; the planner's real size belongs to K1. Checked: a pushed character's
      decision leaves the chosen candidate's plan in its slot of the mailbox, bit for bit, stamped. P3b-ii-b2 NEXT:
      acting from the mailbox, and the hazard's slope.
      P3b-ii-b2 DONE: acting from the mailbox - the host's copy refreshed from the newest readback at every acting
      step (`refreshMailbox`); a planning character acts from its slot's plan when the plan is its own (decided at or
      after the step it took the slot: `slot_owner_since`) and reaches the present step (index = acting steps - (stamp
      - 1), below the horizon), so a plan arriving frames late is joined where it has got to; otherwise the policy.
      The hazard's slope: `projectedHazard` - hazard + lookahead x max(0, rise per step), a falling hazard read as it
      is - `PlanningSettings.lookahead_steps` (10). FOUND: the tests' clip is a get-up, and the servo-only characters
      fall from the first step (hazards climbing 0.03 -> 0.49 in ten steps); the old flags test passed by 0.01, and
      with the projection those real falls are caught at step 4 - so the tests no longer assume calm starts (the flags
      test reads hazards unprojected, the planning tests give every character a slot, the lookahead test measures from
      a push at the first step). Checked: the projection's rows by hand; three steps in a row a pushed character's
      action is exactly its plan's step at the stamp's index; the same push is flagged sooner projected than not.
      The tutorial's planning material is now one section (11.13), with the pieces, the life of a decision as a
      timeline, and acting from a late plan worked through; the learner's file opens its planning code with the same
      overview.
      REVIEWED (Oct 27), three bugs the CPU twin could not show: (1) a judged step - the policy alone - could act from
      a plan a character's slot still held: plans are now acted on only while exploring; (2) the projection read each
      character's previous hazard as 0 at the start and as the old episode's after a restart, inventing rises (11 x
      a first hazard): the previous hazard is now known only within an episode (`previous_hazard_known`, cleared by
      the fleet's `dones`); (3) several decisions in one frame would overwrite each other's uploaded inputs before any
      ran (a GPU receives every upload of a frame before its work): at most one decision per acting call - a decision
      due after one is made waits, pending (`PlanningFlags.decision_pending`, `may_decide`), the clock counting on so
      it reports the true age; `decisions_made` counted. Checked: the deferral by hand; the first step's projected
      hazards are the hazards; eight steps in one call decide at most once; a judged step is the policy's action, not
      the plan. Also: the tests' comments no longer claim the policy starts at zero (it starts small, not zero).
  P4  TEACHER 2 - THE PLANNER DISTILLED: flagged characters act on the plan; their rows store the plan's action and
      a flag; the flow's loss gains flow matching onto those actions. Check: with no flagged row the term is zero,
      bit for bit.
      In two pieces (Oct 27). P4a DONE - the rule on the kit: `KitFlow.flowMatchingGradient` and `flowDpgGradient`
      take a weight and a mode (`ParameterGradients`: write over, or add to what another teacher left), so teachers
      combine as one writes, the others add, one optimiser step follows. Checked, from a flow at rest by flow matching
      alone: one plan (0.4, -0.3) is reproduced from any noise, every sample within 0.05; two plans for one situation,
      0.6 and -0.6, are both kept and not averaged - FOUND: with four Euler steps 76% of the samples land near a plan
      and 10% between (the paths to two modes bend; four straight steps cut across), with eight 94% and 1.5% - so the
      learner's flow actor now defaults to eight steps (`FlowSettings.euler_steps`), and zimrrl's `FlowPolicy`
      explains the trade. THE FLOW ACTOR'S STEPS: FIVE to start (Simon, Oct 27: every ingredient present at a small
      budget for the first night; numbers raised or lowered night by night). P4b DONE - teacher 2 in the learner, its
      examples staged on the host rather than marked in the replay (the host holds exactly what is needed when a
      character acts from its plan): each such step kept as [goal | state | the plan's action] in a ring
      (`distill_examples`, 512); each round a batch (`distill_rows`, 32) drawn with replacement and uploaded once,
      before the round's recording opens; `FlowActor.Distillation` - every policy update copies the batch's conditions
      into its trainer's wide rows, hashes each row's noise (at sigma) and flow time, and ADDS `distill_weight` (0.5) x
      the flow matching gradient to FlowDPG's, before the one optimiser step; no batch until some character has acted
      from a plan. Checked: on the kit, no batch and a batch at weight 0 leave the flow's weights identical to the bit,
      weight 1 moves them; in the learner, a step taken from a plan is kept as exactly its condition and the plan's
      action, and a round trains with the batch, the weights finite. NOT YET: the examples ring is not in the state
      file - a resumed run starts its examples over.
  Q1  TEACHER 3 - FPO: the last round's real transitions, their recorded noise, the old flow matching losses kept
      at collection; the advantage from the critic (one-step TD: -c - gamma C' + C); FPO's ratio and clipped
      surrogate. Checks: the ratio exactly 1 at the old weights; a planted positive advantage raises its action's
      likelihood.
  Q2  THE THREE TEACHERS IN ONE UPDATE: one flow update, three terms, each with its weight and warm-up; near the
      reference the pathwise teacher leads, on flagged states the planner's (T7's blend, by the same flags); every
      term's size logged. Check: each weight at 0 leaves the other terms' update bit for bit.
  K1  THE COMPUTE KNOB (asked for Oct 27): one setting, the share of the learner's compute spent on returning from big
      perturbations - planning for flagged characters, and learning from pushed experience - the rest on precise
      tracking. ONE CURRENCY: every piece of work priced exactly in multiply-adds from the networks' shapes (a
      world-model step on a row; a flow sample, K velocity evaluations; a decision, states x candidates x horizon x
      rounds model steps plus the flow's plans and the critic's tail; an update's rows) - deterministic, the same on a
      phone and a desktop. AN ACCOUNTANT AND TWO LEVERS: each round the learner sums what it spent on each side; a slow
      controller steers the averaged recovery share toward the knob with (1) the planner's budget - how many
      characters may plan, how many rounds each search gets - and (2) the perturbation exposure - how often pushes
      are injected, and the share of training windows drawn from around pushes and their aftermath. UNUSED BUDGET IS
      NOT WASTED: with nobody in danger the planner costs nothing and the compute flows back to tracking; below the
      target, the push rate rises to make recovery experience. Within the budget, spending already goes where it
      matters most: the most endangered plan first, and a search can stop its rounds once its Gaussian has
      converged. Check: with fixed costs per kind of work, the controller settles the measured share at the knob.
  S2  THE COMPLETE RUN: one lab preset with every piece on, the night trainer's path for it, its logs (the tail, the
      planned share, each teacher's loss, the world model's error after losses (T44), the probe's half-survival
      speed (T43)); a short smoke run on the CPU twin - no NaN, every counter moving.
  S3  THE NIGHT'S PROTOCOL: the runs to compare - today's SuperTrack; the complete system; the complete system less
      each teacher, and with a Gaussian actor in place of the flow - their seeds and budgets, a script for the
      Windows machine, and what the morning reads first.
  R1  REVIEW of F1 - F6: names, comments that carry the reasoning, dead code.
  R2  REVIEW of S1, P1 - Q2, S2.
  D1  THE TUTORIALS: zimrrl - flow policies (flow matching, the Euler sampler, FlowDPG, FPO), with diagrams;
      robot-mocap - the complete system, one model, one critic, one cost, one actor, three teachers, and the data's
      path through it.
  D2  THE NIGHT'S READING: the lab's view of the new logs - the probe's bands, the half-survival speed, the planned
      share, the teachers' sizes - so the first night's results can be read the morning after.

RISKS, said before building, and what answers each.
  The critic's slope is untrained: the ramp (built), pessimism (S1), the barrier as a model-free slope (built).
  FlowDPG is an approximation of the deterministic policy gradient: FPO (Q1) and the planner (P4) do not depend on it.
  A flow trained only by the pathwise gradient may collapse to one action per state: the planner's distilled plans
  (P4) are what keep several ways back, and the probe shows whether it holds.
  The planner trusts SuperTrack's model after falls: T44's measure (S2) says how far to trust it; EfficientTDMPC's
  latent ensemble is the fallback scorer.
  Three teachers may pull apart: each one's size logged (Q2), and the night's runs without each (S3) say which helps.
  Compute: K Euler steps per decision (K = 4), a planner on a budget of characters; measured in the smoke run (S2).

`DEFERRED` stays as it was: C5 (EfficientTDMPC as a learner of its own in the lab), D1 - D3 (the lab's other views),
T5 - T7's learned hazard head - the flags of P3 are the state's own measures first.

## The next twenty turns - prepared Oct 28 (Simon: "Add your favorite ideas to the plan, then look at our whole
## remaining plan. Make it all more precise. Find the best combination of ideas that have the best potential.")

SUPERSEDES Q1 - D2 above (their substance is folded in below). The standing rule for the first night (Simon, Oct 27):
EVERY INGREDIENT PRESENT, EACH AT A SMALL BUDGET; the nights after raise what proves itself and lower what does not.

### The combination, and why it has the most potential

ONE CHANGE OF SHAPE: THE FLOW BECOMES A RECOVERY RESIDUAL IN A FEW SYNERGIES.

    action = MLP policy(goal, state)  +  B c,     c = flow(goal, state, noise)     B: actions x k, k = 8

  - SuperTrack's Gaussian MLP policy stays, full width, trained exactly as now: the precise tracker is not replaced
    (no risk to what already works). The flow adds a correction in k SYNERGIES - the principal directions of the
    body's coordinated motion, B an orthonormal basis (zimrnum's `svd` of centred actions).
  - The multimodality the flow exists for is low-dimensional by nature (which foot, which direction, lean or crouch),
    so k = 8 keeps it and costs a quarter of a 35-wide flow: the velocity network, the Euler steps, the training rows.
  - THE PLANNER SEARCHES COEFFICIENTS, CLOSED LOOP: a candidate is k x H coefficients ADDED TO THE POLICY'S OWN
    REACTION at each rolled state, not H open-loop actions. MPPI's sample efficiency falls steeply with dimension:
    16 candidates over 8 x 4 numbers cover the space far better than over 35 x 4; and a plan made of corrections
    stays meaningful when the state drifts - acting from a late plan adds its correction to the policy's reaction to
    the state actually reached.
  - Every teacher speaks the same small language: FlowDPG's action gradient projects through B (g_c = B^T g_a);
    the planner's answers are coefficients; FPO's likelihood ratio is estimated in k dimensions, better conditioned.
  - A zero flow is exactly SuperTrack: the identity every check below can start from.

  Papers: synergies make high-dimensional control learnable (SAR, Berg et al., RSS 2023); policies in a small latent
  over a tracker (PULSE, Luo et al., ICLR 2024; ASE, Peng et al. 2022); latent skills trained through a learned
  world model (ControlVAE, Yao et al. 2022); generative models in a compressed space (latent diffusion, Rombach et
  al. 2022). The residual structure keeps a full-width escape: what the synergies cannot express, the MLP still can.

THE OTHER CHOICES, kept small:
  - Teacher 3, FPO, on real returns - the one no model error can fool - in coefficient space.
  - The three teachers' weights ramped; pessimism ramped with the tail (T49); each teacher's size logged.
  - The compute knob (K1) with its accountant and two levers; night one runs it at a fixed share.
  - Device numbers reach the logs through a STATS MAILBOX after the plans' - the plan mailbox's idea reused.
  - Correlation time of the flow's noise longer while flagged (T54): a character commits to its way back.
  - Judging twice (T55): at zero noise (the typical action) and with each character's noise held fixed (committed).

### The twenty turns (each: what is built, where, and the check that says it works)

  THE ORDER (Oct 28, Simon: "proceed in the most logical order, very slowly, review as you go; keep it simple and
  flat"): A1; then FPO's shape-independent half - its reference in zimrrl (Q0), which does not depend on the flow's
  shape; then A2 - A5; then FPO in the learner, in synergy space (Q1a, Q1b); then Q2 and the rest as listed.

  A1  SYNERGIES. zimrrl `ActionSynergies(T)`: an orthonormal basis B (actions x k) from a set of action vectors -
      centred, zimrnum `svd`, the top k right singular vectors - with each direction's share of the variance;
      `encode` (c = B^T (a - mean)) and `decode` (a = mean + B c). The first basis: the reference clip's own pose
      changes (its servo targets frame to frame), available before any learning. Checks: B orthonormal to rounding; a
      planted rank-3 set reconstructed exactly at k = 3; the variance shares of a 2-D example by hand. zimrrl tutorial:
      synergies, with a worked 2-D example.
      DONE Oct 28: `zimrrl.ActionSynergies(T)` - `fit` (zimrnum's `svd` of the actions as rows, V's first columns
      as the synergies, each one's share of the energy), `encode` (c = B a), `decode` (B^T c), fitted ABOUT ZERO, not
      centred: the actions are corrections, and a correction of zero must stay "no correction". Checked: the worked
      four-action example by hand (shares 0.8, 0.2, along the axes); three synergies of actions made of three
      directions carry all the energy, are orthonormal, and reproduce every action. zimrrl tutorial 5.7. (The first
      basis - from the reference clip's pose changes - is fitted where the learner is built, A2.)
  Q0  FPO'S REFERENCE (zimrrl). The likelihood ratio a flow can give: exp(old loss - new loss), the per-sample flow
      matching loss at a few (time, noise) draws standing in for the negative log-likelihood; PPO's clipped surrogate
      on it with an advantage; on zimrnum's graph, so its gradient is autodiff's. Checks: the ratio exactly 1 at the
      old weights; a positive advantage's gradient step lowers that action's loss, a negative one raises it.
      DONE Oct 28: `FlowPolicy.drawLosses` (each action's flow matching loss averaged over its draws - the squared
      error summed over its dimensions, as a log-likelihood sums over independent ones - on the graph) and
      `zimrrl.fpoLoss` in the PPO section (FPO is PPO: `PpoClipLoss` given -L_new and -L_old, no second surrogate;
      placed after it, lint's decl-order hint taken - the flow keeps its likelihood stand-in, PPO's section the
      algorithm). Checked: at the old weights every ratio is exactly 1 and the loss exactly minus the mean advantage;
      one gradient step lowers the loss of an action with advantage +1 and raises one with -1. zimrrl tutorial 6.4.
  A2  THE RESIDUAL FLOW IN THE ROLLOUT. `FlowSettings.synergies` (k, 8); the flow's output is k coefficients; the
      policy's turn becomes the MLP's layers as now, then raw += B c (kernel `synergy_decode_add`), then `lat_act`
      (its exploration noise kept, small). The backward: the MLP takes its gradient as in plain SuperTrack, the flow
      FlowDPG with g_c = B^T g_a (kernel `synergy_project`). B in the parameter buffer, never trained, saved with the
      run. Checks: a flow at rest rolls exactly as SuperTrack's MLP alone, every state to the bit; the decode and
      projection against the host; FlowDPG's projected gradient against central differences.
      DONE Oct 28: kernels `synergy_decode_add` (raw += B^T c) and `synergy_project_gradient` (g_c = B g, from the
      gradient buffer into acts); `FlowActor` reshaped - its flow outputs k coefficients, a `Correction` (where the
      synergies are in the parameter buffer, how many, the action width, the flow's OWN noise scale) shared with
      `actingOnly`, each step's coefficients kept; the policy's turn is the MLP, then the correction, then `lat_act`
      (a flow needs a policy, refused by name without one); the backward lost its flow branch - the MLP takes its
      gradient as in plain SuperTrack, the flow keeps B g per step; the training rows hold coefficients and the flow's
      own noise (a seed stream of its own, `flowNoiseSeed`: hashed per (row, index) like the exploration, the same seed
      would have made the two noises the same numbers); the train step takes the policy's Adam and the flow's. The
      planner's flow plans roll the policy with the correction (their kit has the policy; sigma 0). The learner: full
      width for now (`FlowSettings.synergies` 0, the identity basis) until A3 fits one. FOUND: zimrnum's SVD tested
      orthogonality against a fixed 1e-15, which no f32 rotation reaches - every f32 SVD swept to the limit and
      failed; now 4 x the type's epsilon (f64 unchanged in effect), with an f32 check. Also stated: a flow with no
      noise learns nothing from FlowDPG (its floor is the noise's length). Checked: a flow at rest with no noise rolls
      exactly as the policy alone, every action and state; a moving flow adds at the first step exactly its decoded
      coefficients, zimrrl's sampler's; the backward gives the policy the same weight gradients as alone and keeps B g
      for the flow; one step moves both. NOT YET (A3): the host's acting is still the flow alone.
  A3a DONE Oct 28: the host acts as the kit does - `correctedRow`: the policy's raw action plus the flow's
      coefficients (sampled from the flow's mirror) decoded through the host's own copy of the synergies (written at
      build, restored on resume); `chooseExploringAction` made flat - the raw action (corrected, with a flow), then
      SuperTrack's exploration, the same for both; each character's drifting noise in the flow's k coefficients, at
      the flow's own noise scale; a planning character's noise drifts with a longer correlation time
      (`FlowSettings.flagged_noise_correlation_seconds`, 2 s; T54); judged, the policy with the flow's typical
      correction. Checked: after four rounds of training, the host's corrected raw actions equal the kit's for the
      same rows and the same noise (worst 1.5e-8 on actions up to 0.25); a flow at rest, judged, is the policy alone
      to the bit; a flow run still resumes bit for bit. (A3b, a basis from the clip, DROPPED - see below.)

  COMPRESSION SET ASIDE (Oct 28, Simon: "it might be harder to find actions in the pca space ... lets deemphasise pca
  compression and proceed"). The flow stays a FULL-WIDTH correction - k = 35, its synergies the identity - for the
  first night: the residual structure is what protects SuperTrack, and it is built and checked; compression was only
  ever an efficiency, and a basis from the reference clip's pose changes is the wrong data - it holds how the dance
  moves, not the small ankle, hip and stepping corrections a recovery needs, so it would cap the flow quietly.
  `ActionSynergies` stays as a tested building block; a compressed basis is a LATER-NIGHT experiment, fitted from the
  corrections recoveries actually used (a - policy(state) on planned steps), with the energy it leaves over (T61) to
  decide. Also: the flow's own noise is a share of sigma (`FlowSettings.noise_share`, 0.5) - its noise and SuperTrack's
  exploration add their variances, so at half of sigma the two explore 1.25 times as much as SuperTrack alone.

  A4  PLANNING AS CORRECTIONS AROUND THE POLICY, CLOSED LOOP - in two pieces.
  A4a DONE Oct 28: `GivenCorrections` in the latent kit - coefficients for every step and row, [step][row][synergy],
      decoded and added to the policy's raw action as a flow's correction is; a kit takes its corrections from a flow
      or from these, never both (refused by name), and never without a policy. Checked: given corrections of all
      zeros roll exactly as the policy alone; the coefficients a moving flow chose, given back in the flow's place,
      roll exactly as the flow's own rollout did - every activation, action and state, to the bit.
  A4b DONE Oct 29 (written by an earlier attempt at this turn whose reply was lost; reviewed against the last
      snapshot line by line before keeping it): the scorer's kit is built with the training kit's policy (its weights
      shared by shape), sigma 0, its given corrections MPPI's candidate region itself - no copy into the wide rows any
      more, `kit.forward()` instead of `forwardRecorded`; the planner's corrections decode through the flow's synergies
      (full width, refused otherwise) or, without a flow, a basis of its own, the identity (`writeOwnSynergies`; past
      the saved parameters like the mailbox - constant, written again at every build); the flow plans are the
      coefficients the flow chose; acting from a plan is `policyRow` plus the correction (`addCorrection`, shared with
      the flow's own), and teacher 2's examples are now corrections - what a full-width flow outputs, so A5's change of
      examples is done with it. FOUND IN REVIEW: `writeInputs` staged each step's goal only into the goal block, for
      the cost, not into the wide row's goal columns, where the policy now reads it (the gather does both) - the
      scorer's policy, in the tests, planned against zero goals; fixed. Checked: a zero candidate scores as the policy
      alone to the bit, others not, with a random policy; the scorer and planner tests (zero policy, identity basis -
      corrections exactly actions) unchanged in substance; acting from a plan is the policy's reaction plus the
      correction, exact. A4b's plan as written:
      the tracking planner rolls its candidates closed loop - the scorer's kit with the learner's policy, its
      given corrections MPPI's candidate region itself (already [step][row][action], no copy); the flow plans' kit
      writes its coefficients as candidates; the mailbox carries the chosen corrections; acting from a plan is the
      policy's raw action for the state reached plus the plan's correction for that step. Checks: a zero candidate
      scores exactly the policy's own rollout; a flow plan's score equals the flow's rollout's cost; acting from a plan
      is the policy's reaction plus the planned correction, exact.
      DONE Oct 28: kernels `synergy_decode_add` (raw += B^T c) and `synergy_project_gradient` (g_c = B g, from the
      gradient buffer into acts); `FlowActor` reshaped - its flow outputs k coefficients, a `Correction` (where the
      synergies are in the parameter buffer, k, the action width, its OWN noise scale) shared with acting-only actors,
      each step's coefficients kept; the policy's turn is the MLP, then `flowCorrection` (condition, the flow's own
      noise from its own seed stream `flowNoiseSeed` - the exploration's would be the same hashed numbers - the
      sample, the decode-add), then `lat_act`; the backward has ONE path: the MLP's as always, plus the projected
      gradient kept for the flow; the training rows carry coefficients and the flow's noise; the train step runs the
      policy's Adam and the flow's step; a flow needs a policy (refused by name otherwise); the planner's flow plans
      roll the policy with the correction (its weights shared, its exploration only the flow's noise); the learner's
      flow at full width (k = 35, the identity) until A3 fits a basis. FOUND: zimrnum's SVD tested orthogonality
      against a fixed 1e-15, below what f32 can reach - an f32 SVD always gave up - now a few of the type's own
      epsilons (zimrnum gains an f32 check). Checked: a flow at rest with no noise rolls exactly as the policy alone,
      every action and state; moving, it adds at step 0 exactly B^T c with c zimrrl's sampler's; the backward gives
      the policy its very gradients and the flow B g; one step moves both; teacher 2 at weight 0 changes nothing.
      TRANSITIONAL, fixed next: the learner's host acting still runs the flow alone (A3); teacher 2's examples hold
      whole planned actions while the flow learns corrections (A4, A5) - neither to be run before.
  A3  ACTING WITH THE RESIDUAL FLOW. The host: action = MLP(state) + B sampleHost(...); the flow's noise in
      coefficient space, drifting, its correlation time longer while flagged (T54); judged at zero noise; the basis in
      the state file. Checks: the host's action equals the kit rollout's for the same noise; a run resumes bit for bit.
  A4  PLANNING IN SYNERGY SPACE, CLOSED LOOP. The scorer's and the flow plans' kits roll with the MLP policy acting
      (its weights shared, as the world model's are) and each candidate's coefficients decoded and added at each
      step; candidates [step][row][k]; MPPI over k x H; the mailbox carries coefficients; acting from a plan is
      MLP(the state reached) + B c[index]. Checks: zero coefficients score exactly the MLP's own rollout; the known
      zero-cost plan found in coefficient space; acting from a plan is the MLP's reaction plus the decoded step, exact.
  A5  TEACHER 2 IN SYNERGY SPACE, AND THE BASIS FROM RECOVERIES. Distillation examples hold coefficients; flow
      matching in k dimensions. Once a set number of planned steps is held, the basis is refitted ONCE from what the
      recoveries actually did (their residuals a - MLP(state)), the flow's weights kept, then frozen. Checks: the
      one-plan and two-plan tests in coefficient space; a refit on planted low-rank residuals recovers their span.
  TEACHER 3 IN THREE PIECES (Oct 29): Q1a the examples on the host and their batch; Q1b on the device, each example's
  old loss and its advantage from the critic; Q1c FPO's update. The tutorial describes teacher 3 once it teaches (Q1c).
  Q1a DONE Oct 29: `FlowActor.Fpo` (the batch region, packed [goal_t | state_t | coefficients_t | goal_t+1 |
      state_t+1]); the learner keeps every step the flow chose, while exploring, for a character IN RECOVERY - planning,
      or with a hazard of at least `FlowSettings.fpo_start_hazard` (0.5) - as a PENDING example (the condition and the
      flow's own coefficients, before SuperTrack's exploration: from the flow's side that noise is part of the world),
      completed at the next acting step with the condition reached, dropped if the episode ends between; a ring
      (`fpo_examples`, 512) and a batch per round (`fpo_rows`, 32), uploaded before the round's recording. FOUND: the
      fleet's "aftermath" is the steps after a FALL, not after a push - time no longer at risk - so recovery is judged
      by danger, the hazard, however it came. Checked: a pending example holds exactly the condition acted in; the next
      step completes it with exactly the condition reached; a judged step completes one and starts none.
  REVIEWED (Oct 29) after A1 - Q1a: the switch from actions to corrections had left the old word where the meaning
      changed - `plannedAction` (now `plannedCorrection`), teacher 2's examples "[goal | state | action]", the
      learner's overview, the tutorial's acting timeline and teacher-2 passage: all now say correction, the timeline
      showing "policy + plan[k]". Teacher 3's conditions gathered in `keepFpoPending` (the hazard was computed at the
      call site for every exploring step, FPO or not). Known, as for teacher 2: teacher 3's examples are not in the
      state file - a resumed run starts them over.
  Q1b IN THREE PIECES (Oct 29): i the old losses on the kit; ii the advantage, from the cost and the critic; iii the
      learner computing both every round, before its updates.
  Q1b-i DONE Oct 29: `KitFlow.drawLosses` - each example's flow matching loss averaged over its draws (FPO's stand-in
      for a negative log-likelihood), the trainer's rows `draws` consecutive rows per example (refused by name when
      they are not whole examples): the training forward, then kernel `flow_draw_losses`, one thread per example, the
      mean over its draws of the squared error summed over the action's numbers. Checked: equal to zimrrl's
      `FlowPolicy.drawLosses` on the graph for a moving flow, three examples of four draws (2.7073317 against
      2.7073314; 2.025943 exactly; 8.432077 against 8.432076); lavapipe compiles it.
  FOUND before Q1b-ii (Oct 29): the critic does not read the policy's pairing. It learns [goal_k | state_k] - a state
      beside the goal it was MEANT TO MATCH, its own frame's - while the policy, and the flow's condition, pair a state
      with the goal the next step aims at. Teacher 3's examples held the flow's two conditions, so C(this) would have
      read the wrong frame's goal. The example is now [own goal | goal | state | coefficients | next state] (same
      width): the flow's condition [goal | state] is two adjacent parts; C(this) reads [own goal | state], C(next)
      [goal | next state], and the cost is the next state against the goal - the next step's goal was never needed.
      The own goal is the goal the character aimed at one acting step before, kept per character and forgotten at a
      restart, so a character's first step in an episode makes no example. The critic's comment, which said its input
      "is the policy's own", now says what it reads. Checked: no example at the first step; at the second, exactly
      [first step's goal | goal | state | coefficients]; completed with exactly the state reached.
  Q1b-ii DONE Oct 29: `FlowActor.Fpo` has its own `init` (rows, features, synergies) and an `Advantage` part,
      reserved once the critic exists (`reserveAdvantage`): the critic's inputs packed - goals [own goals; goals],
      states [states; next states] - the costs, the heads' values [head][2 x rows], the advantages, and a tail over
      2 x rows rows. `LatentKit.fpoAdvantages`: the four feature parts copied packed (`copyColumns`), each step's cost
      - the next state against the goal it aimed at, this kit's cost and barrier, as the critic's targets charge
      (`lat_tracking_cost`) - the online heads at every start and every next step in one pass, and kernel
      `fpo_advantages`: A = -c - gamma x the heads' mean where it led + their mean where it started (the plain mean;
      pessimism stays with the planner and the tail). Checked: the packed parts are exactly each example's; every
      advantage equals the host's recomputation from the device's costs and head values, with start and next means
      that differ - a swap would show; lavapipe compiles the kernel.
  REVIEWED (Oct 29) after Q1b-ii - two things written in several places, now one: (1) teacher 3's example layout,
      bare arithmetic in four places (the host's pending and completed examples, the allocation, the device's reading)
      with a fifth coming: now `Fpo.Columns` (own goal, goal, state, coefficients, next state, width), which every user
      goes through - the bug class the planner's `SearchShape` closed; (2) SuperTrack's per-step cost, a 13-line
      parameter block in the critic's targets, the planner's scores and teacher 3's advantages: now `TrackingCost`
      (produced by the kit and by the critic's source) and `runTrackingCost`, so "one model, one cost, one critic" is
      one definition in the code. Every suite reaching them passes unchanged - the scorer still equals the CPU model.
  Q1b-iii DONE Oct 29: `Fpo.Losses` (`reserveLosses`, with the flow: a trainer over rows x draws rows, the packed
      conditions and coefficients, the old losses) and the round's `draw_seed`; `LatentKit.fpoRoundStart`: the
      advantages, then each example's condition and coefficients copied packed (`Fpo.Columns`) and broadcast to its
      draws (`broadcast_rows`), each row's noise (the flow's own, at its scale) and time hashed from the draw seed, and
      `KitFlow.drawLosses` - the rows left as they are for the round's updates. The learner: the advantage reserved
      once the critic exists; a batch only with it (teacher 3 needs `train_critic`); `startFpoRound` first in the
      round's recording, the draws seeded by the acting steps (saved with the run); `FlowSettings.fpo_draws` (4).
      Checked: after a round, every draw row holds its example's condition and coefficients; the old losses equal the
      draw losses recomputed on the same rows at the round's starting weights, to the bit; the advantages are finite.
  Q1c IN TWO PIECES (Oct 29): i the update on the kit; ii the learner calling it, the advantages normalised.
  Q1c-i DONE Oct 29: kernel `fpo_velocity_gradient` - FPO's loss differentiated through the ratio and the new
      losses: d loss / d v = weight x A x r x 2 / (B N) x (v - u) where the unclipped term is the smaller, 0 where the
      clipped one is, the choice made as `zimrrl.ppoClipSample` makes it (a shader cannot import zimrrl; the check
      pins the restatement); `KitFlow.fpoGradient` - the new losses on the round's same rows (`drawLosses`), the
      kernel, the backward written over or added; `KitFlow.FpoLosses` (old, new, advantages); PPO's own `clip`
      parameter shared. Checked: equal to autodiff of `zimrrl.fpoLoss` on the flow's weights for a moving flow,
      three examples of four draws - one at ratio 1 with A +1, one with A -0.7, one past the clip whose draws carry no
      gradient at all; lavapipe compiles the kernel.
  Q1c-ii DONE Oct 29 - TEACHER 3 TEACHES: kernel `fpo_normalize_advantages` (one thread, zimrrl's
      `normalizeAdvantages` order: mean, sample deviation, + `advantage_epsilon` - its own 16-byte group of the kernel
      parameters, after the compute host refused a block of 484 bytes); `Fpo.Losses` holds the new losses and the
      normalised advantages beside the old losses; the round start normalises after the advantages; every policy
      update adds `fpoFlow` after teacher 2, before the flow's one optimiser step; `FlowActor.FpoSettings` (rows,
      draws, weight, clip) replaces loose arguments; `FlowSettings.fpo_weight` 0.1, `fpo_clip` 0.2; a batch needs two
      examples (the sample deviation), refused by name. Checked: on the kit, no batch and a batch at weight 0 leave
      the flow's weights the same to the bit, weight 0.5 moves them; in the learner, after a round, the normalised
      advantages have mean 0 and sample deviation 1. The tutorial now describes teacher 3 (the flow's section, the
      teachers sketch, the overview's comparison and its "several ways back").
  REVIEWED FOR UNDERSTANDING (Oct 29), three things: (1) `FlowActor`'s head comment still described the flow
      before A2 - "taking the Gaussian policy's place", a function that no longer exists, a noise shared with the
      exploration - and none of teachers 2 and 3; it is now the map: what the flow is, one rollout step in order, the
      guarantee at rest, the three teachers (what each learns from, where it runs, what holds its data, why three),
      and the one approximation, now correctly only the flow's. (2) Names that said less than they hold:
      `Fpo.Losses` (which also held the draws and the normalised advantages) is `Fpo.Update` - everything one FPO
      update reads - with `reserveUpdate`; `KitFlow.FpoLosses` is `FpoNumbers`, its fields `old_losses_at`,
      `new_losses_at`, `advantages_at`. (3) The learner's acting loop ran eight concerns inline in an order that
      matters but was stated nowhere: `act`'s comment now gives the recipe, and the loop is one call per step -
      `features`, `completeFpoExample`, `projectHazard`, `chooseAction`, `rememberFpoOwnGoal`, `writeAction` - then
      `forgetEndedEpisodes`; the call's shared values are one `Acting`. Behaviour unchanged: every suite passes,
      resume bit for bit included.
  Q2 DONE Oct 29 - TRUST IN THE CRITIC: the three teachers together through one idea. An untrained critic's numbers
      are noise, so everything that leans on it is weighed by one share growing from 0 to 1 over
      `value_tail_ramp_updates` (`criticTrust`), set before every policy update and also where the learner is built
      and where a run resumes, so nothing starts at full trust it has not earned (`applyCriticTrust`): the value
      tail's weight and its pessimism (T49), the planner's tail weight and pessimism, teacher 2's and teacher 3's
      weights. Teacher 1, FlowDPG, leans on the world model's gradient and is not ramped. Checked: built, every one
      is at nothing; after each round, its full setting times min(1, updates / ramp); whole past the ramp. The
      tutorial explains it as one idea, with what it weighs and why. EACH TEACHER'S GRADIENT SIZE moves to S2a, the
      stats mailbox, where it can reach the logs.
## EFFICIENTTDMPC IN FULL, AND HALF THE COMPUTE ON THE WAY BACK (Oct 30)

(Simon, with the paper (arXiv 2605.16692v5): "Read efficienttdmpc. Make sure we use all good ideas from them. Use the
value at intermediate steps, do the tricks to avoid exploiting errors. And find the best ways to integrate our
multiresolution planning idea. We want half of the computation time on discovering precise complicated returns to the
reference, and learning from them. Only the other half is on learning the policy and the model with supermimic. Maybe
supermimic could also use multiresolution differentiable rollouts? Brainstorm more")

THE PAPER (Evers, Meo, Bohmer, Dauwels, Oren, EWRL 2026), on BMPC: every idea aims at the planner's return estimate,
which a planner exploits wherever the model or the value is wrong.
  - MULTI-HORIZON OBJECTIVE (eq. 6): a plan's score is the MEAN over depths h = 1 .. H of "the first h planned actions,
    then the value" - each term the value of a different PREFIX of the plan. It prefers plans whose every prefix stays
    good when the policy takes over, not plans that only look good at the last depth. Acting planner only (horizon 6).
  - VALUE-EQUIVALENT DYNAMICS ENSEMBLE: 4 dynamics heads (own weights, different starts), each rolling the window's
    recorded actions from the encoded start; the SHARED reward and value heads trained on EVERY head's rolled latents
    (the value target a one-step backup averaged over the heads) - so the value is accurate on what every head
    produces, compensating all their errors. Planning scores each plan under every (dynamics head, value head) pair:
    the mean is the objective, the spread the uncertainty (eq. 8-9). 2 / 4 / 8 heads: +10 / 22 / 33% AUC.
  - PESSIMISTIC REANALYZE (eq. 10): mean - beta x spread, where plans become the policy's TARGETS (beta 10, best of
    0 .. 30) - helps exactly the tasks that terminate early (a fall is ours), not the others.
  - Practical: reanalyze (re-planning on replay states for fresh targets) at an eighth of the budget (64 samples, 8
    elites, 3 policy trajectories, horizon 3, terminal-only) - no loss; replay filled every step.
  - Their acting search: horizon 6, 6-8 iterations, 512 samples, 64 elites, 24 policy trajectories. OURS: about 20
    samples, 2 iterations, 16 steps - some 25 times fewer samples.
  - Their Figure 11 is our "plans' honesty", done: each planned sequence scored by one head, by the ensemble and by
    the simulator (3 steps rolled, then the value). Optimised on one head, plans promise much over the policy's own
    action and deliver LESS than it in the simulator; optimised on the ensemble, they promise less and the simulator
    agrees.
OURS TODAY (the tracking scorer): summed costs, the critic ONLY after the last step, ONE world model, pessimism
available but 0 in every run file, a tiny search. None of the paper's defences active.

THE WORK - E: the paper's ideas in our planner; C: the compute split; S: SuperMimic at several resolutions.
  E1 PREFIX VALUES (the multi-horizon objective) in the tracking scorer: score = the mean over depths of
      -(sum of the first h costs + the critic at z_h), each discounted as the critic is. With knots and jumps, depths
      with a state are the fine steps and the jump ends; each prefix weighted by the depths it stands for (a jump end
      for its span - the trapezoid of the uniform mean). The critic heads at each depth (their mean and spread kept
      per depth). Check: eq. 6 on host for planted costs and values; a planted case where the last-depth and the
      prefix objectives prefer different plans.
  E6 HONESTY (TH2b; their Figure 11, but exact - our physics is right there): for every acted plan, what it promised
      for the steps acted from it against the cost the physics gave those steps, beside the same for the flow's own
      plan from that state. Device numbers by round. Measured before and after each of E1-E5.
  E3 PESSIMISM WHERE PLANS TEACH: plans whose corrections become the flow's examples scored mean - beta x spread
      (the critic heads' spread, and with E2 the world models'); beta in our cost units, set against E6.
  E2 A VALUE-EQUIVALENT WORLD MODEL ENSEMBLE: 4 SuperTrack world models, own starts, trained on the same windows; the
      critic also trained on the states each head rolls from the recorded windows (value-equivalent, as their value
      heads); the planner rolls every candidate under every head - the mean the objective, the spread for E3. The skip
      model the same way (4 cheap heads, their spread the far part's uncertainty).
  E4 REANALYZE FOR THE WAY BACK: every round, re-plan on replay states where returns are learned - the aftermath's
      (lost, returning) and the pushed starts - with the cheap pessimistic planner (their eighth: 64 samples, 8 elites,
      3 flow trajectories); the plans' corrections into teacher 2's examples beside the acted ones. The bulk of the
      discovery half: it turns compute into fresh targets without a physics step.
  E5 THE ACTING SEARCH AT THEIR SIZE: with knots (552 numbers a candidate) - 256 to 512 samples, 32 to 64 elites, 4 to
      6 iterations, 8 to 24 flow trajectories.
  C1 WORK ACCOUNTING: each phase's device work counted on the host every round (dense layers: rows x in x out,
      forward 1, backward 2) - SuperMimic's half (world model, policy, critic) and the discovery half (acting search,
      reanalyze, the flow's teachers) - logged as a share. C2 THE SPLIT HELD: `discovery_share` (0.5) - reanalyze's
      states per round set so the discovery half's work matches it. C3 later: device time per phase where timestamp
      queries exist, to calibrate work against time (small batches are latency-bound, so time can differ).
  S1 MULTIRESOLUTION DIFFERENTIABLE ROLLOUTS FOR SUPERMIMIC: the policy's rollout as fine steps through the world
      model (8, the policy reacting each step) then jumps of the skip model - each jump's 4 actions the policy's at the
      jump's start against each step's goal, the gradient flowing through the skip model into them. A horizon of 64
      steps (about a second - what a return takes) in 8 + 14 = 22 sequential stages, fewer than today's 32; a shorter
      chain of compounding steps for the gradient to cross. Gates: the skip model's own (TS2), and a device number -
      on the same windows, the direction of the policy's gradient through jumps against through steps (cosine).
  S2 THE POLICY ON THE ENSEMBLE: its loss averaged over E2's world models (optionally mean + beta x spread) - a policy
      that cannot exploit one model's error, as the paper's planner cannot.
  S3 PREFIX VALUES IN THE POLICY'S LOSS: the critic at intermediate depths (lambda-returns, DreamerV3's actor) -
      lower variance, every prefix counted; with TH3's lambda-return critic.
  BRAINSTORM, not yet planned:
  - DISCOVERED RETURNS AS REFERENCES: a return the physics confirmed (found by the planner, back within 5 s) saved as
    a bridging clip; the tracking policy then learns to track a way back like any mocap - a library that grows from
    discovery, SuperTrack's strength put to work on what the search finds.
  - GO-EXPLORE FOR RETURNS: an archive of the hardest fallen states - the ones not yet returned from - restarted from
    more often; discovery spent where it is still needed.
  - TWO FLEETS: a tracking fleet (SuperMimic's data) and a discovery fleet (always in trouble, planning every step with
    the big search, R3) - the compute split made physical, each fleet's data feeding both halves.
  ORDER: E1 and E6 (the existing planner, measured), TS2b-TS3 (the skip model in), E3, E2, E4 with C1-C2, E5, S1-S3.

## TEMPORAL HIERARCHY - WHAT HAS A REAL CHANCE (Oct 30; after night 1, beside the way-back turns)

(Simon: "Brainstorm ideas for hierarchical time world model. Maybe distilling a model that skips 3 steps to jump to the
4rth step directly would make planning faster? Somehow?" - then: "Think really hard about which versions have real
chance of helping and make the plan more precise".)

WHAT LIMITS THE PLANNER NOW, from the code: not its speed - it decides once a round for 4 characters, about 2 x 16
sequential steps of small kernels, a few milliseconds of a desktop GPU - and not first its horizon, but THE DIMENSION
OF WHAT IT SEARCHES. MPPI keeps an independent Gaussian per step and per action (`mppi_sample`: [state][step][action]),
so a candidate is a point in 69 x 16 = 1,104 dimensions, and the search draws at most 20 random ones (24 candidates,
4 the flow's, some the policy's own). Twenty samples in 1,104 dimensions barely explore: the "elites" are mostly the
least harmful random draws. Each version of a time hierarchy judged against that:

  A TIME HIERARCHY IN THE SEARCH (knots) - REAL CHANCE, CHEAP. A candidate's correction defined at K knots over the
    horizon and interpolated between them: 69 x 4 = 276 dimensions instead of 1,104, smooth corrections (a return is a
    committed motion, not per-step jitter), and the search's dimension no longer grows with the horizon. Known to help
    population planners (spline-parameterised MPPI; iCEM's coloured noise). Touches only the sampling and the refit.
  B THE CRITIC'S MULTI-STEP TARGETS - REAL CHANCE. TD-MPC plans 3 to 5 steps and leans on its value; the lesson is that
    past a short horizon a good value beats a long model rollout through a learned model's compounding error -
    especially through a fall, where the world model is worst. Our critic learns from one-step targets on recorded
    windows; SuperMimic's from lambda-returns on the policy's imagined rollouts. Lambda-returns propagate a fall's
    time to return over many steps per update instead of one.
  C A JUMP WORLD MODEL (skip to step k+K) - CONDITIONAL. It pays only if planning further helps returns AND the
    1-step model's cost to plan that far becomes the limit. Both are unmeasured. Its risks are real: a jump distilled
    from the 1-step model can be no more accurate than it and is worst where it is worst (contacts); a deterministic
    jump through a fall predicts the average of falling left and right; a jump through the policy's closed loop must
    keep tracking the policy. Built only after a measurement says longer horizons help - and then shaped by A: one
    jump per knot interval.
  D FLOW CHUNKS (one sample per knot interval) - REAL CHANCE FOR ACTING SPEED. The flow's host sampling is the cost of
    acting (five Euler steps per character per step); a correction for K steps per sample cuts it K-fold, and matches
    A's plans for distillation. Only if acting still bounds a round on Simon's machine after the threads.
  E PLANNING IN REFERENCE SPACE (waypoint poses the policy tracks) - promising, but needs the motion library deferred
    with motion matching. Later.
  F A GENERATIVE (FLOW) JUMP MODEL - only if C is built and its jumps blur through contacts. Not planned.

THE STEPS (each gated by the one before; what, where, the check):

  TH1 DONE Oct 30 (Simon: "I think we can go ahead with time hierarchy, and maybe knots, immediatelly" - so ahead of
      B5b): `plan_gain_stats` - each decision's chosen plan's score less the best of the actor's own proposals (the
      flow's plans, the first `policy_candidates`), averaged over the deciding states, and the share of choices the
      search drew; `DeviceStats.planner_gain`, `planner_search_share`; the planner's own `stats_at`. MEASURED on the full
      system: EVERY choice the search's, the gain growing 0.03 to 2.3 - the strong form of the diagnosis ("barely
      explores") NOT supported. Two caveats: the flow is untrained there (its proposals little more than the policy with
      noise), and a score is the planner's own estimate through the world model - a search in 1,104 jittery dimensions
      is the kind that finds a model's loopholes, so a growing gain is improvement or exploitation, and only returns
      in the probe with the planner in the loop can tell. Knots narrow the loopholes and are now comparable on the
      same seeds by this number.
  TH2 DONE Oct 30: KNOTS. `KitMppi.Options.knots` and `PlanningSettings.knots` (0: one per step, today's search
      exactly), the kernels' `plan_knots` (the free slot beside the plan's other numbers) with ONE geometry,
      `planKnots` / `planKnotSpan`: the horizon's first and last steps knots, the rest evenly between, a straight line
      between two knots. `mppi_sample` draws per knot (`knotProposal`) and interpolates; `mppi_refit` fits each knot to
      the elites at the knot's own step (exactly their knot values for drawn candidates); `mppi_begin` shifts the knot
      curve, reading between knots - every read at or after the knot written, so in place; `mppi_choose` reads knot
      0's spread. The Gaussian and the noise sized by knots; the decision's noise too. Refused by `KitMppi.init` and by
      the lab ("learner.planning.knots: ...") when the knots miss whole steps; state ZSTSTA13. Checked: the per-step
      kit MPPI test unchanged (knots 0 is today's search); a new test, 7 steps in 3 knots, every step of a sample, the
      refit, and a warm start shifted 2 steps (both knots between, one past the end) against the host; every suite.
      COMPARED on the full system from one seed, knots 0 against 4: the gain over the flow's proposals larger with
      knots at first (0.047 / 0.031, 0.099 / 0.054), smaller later (0.26 / 0.45, 0.70 / 1.31); every choice the
      search's either way. AMBIGUOUS by construction: a smaller late gain is fewer loopholes found or a narrower
      search, and a score through the world model cannot say which.
      NEXT TH2b - THE PLANS' HONESTY: what a chosen plan promised against what it delivered - its predicted cost over
      the steps acted from it against the tracking cost the physics gave the same steps. A search that exploits the
      model promises more than it delivers; that gap, per-step search against knots, is the evidence the gain cannot
      give.
  THE SKIP MODEL AND TWO-SCALE KNOTS (Oct 30; Simon: "I am thinking we could directly learn the skip model for
      predicting 4 steps in the future. And plans could be with knots at 1, 2, 3, 4, 8, 12, 16, 20. Using the skip model
      for the second half of the plan. Is this possible?"). YES - and it replaces TH5's distilled jump. Why it fits:
      the world model is residual in feature space (`lat_advance`: z_k+1 = z_k + change), so the skip model is the same
      kind of network with a wider input - [z_t | the 4 steps' references | the 4 steps' actions] -> the change over 4
      steps - no new integration. Trained DIRECTLY on the world model's own windows (every 4-step stretch of a recorded
      window, the actions actually taken): its target is the physics, stationary while the policy learns, and a direct
      4-step prediction escapes the compounding of four 1-step errors. Simon's knots are TH2's geometry at two scales:
      FINE STEPS 4 (a knot each) then a knot every SPAN 4 steps over a horizon of 20 - and TH2's "4 knots over 16" is
      fine steps 1, span 5. One geometry, two numbers.
      A PLAN SCORED: steps 1-4 as now (the policy reacting every step, the 1-step model, a knot each); steps 5-20 as
      four jumps - the policy evaluated once at the jump's start state against each of its 4 steps' goals (one batch),
      the knots' corrections for those steps added (straight lines between knots), the skip model to the state 4 steps
      on; a jump's steps' cost the mean of its two end states' costs x 4 (a cost head later if needed); the critic's
      tail at step 20. 8 sequential stages instead of 20: a horizon 25% longer than today's at about half its
      sequential cost; a candidate 8 x 69 = 552 numbers instead of 1,104.
      WATCHED: inside a jump the policy does not react (its actions from the jump's start state) - the far half of a
      plan is open-loop 67 ms at a time, fine for scoring far steps, and acting stays closed-loop (the plan's
      corrections added to the policy's own action every step); a deterministic jump through a fall predicts an
      average - the first 4 steps, where precision matters, stay with the 1-step model; the policy's pathwise gradient
      keeps the 1-step model (it needs every step).
  TS1 DONE Oct 30: the knot geometry at two scales - `KitMppi.Options.fine_steps`, `knot_span` and
      `PlanningSettings`'s (replacing the knot count; state ZSTSTA14); the kernels' `plan_fine_steps`, `plan_knot_span`
      in a 16-byte group of their own at the parameters' end (the old slot back to padding); ONE geometry,
      `planFineSteps`, `planKnots`, `planKnotStep`, `planKnotAtOrBefore`, `planStepsPastKnot`, read by `mppi_sample`,
      `mppi_refit`, `mppi_begin` and `mppi_choose`; `robot_bmpc_kit.planKnotsFit` the one check, used by `KitMppi.init`
      and by the lab through `PlanningSettings.knotsFit`. Checked: the per-step MPPI test unchanged; the knots test now
      one function over any geometry against the host's own (`expectKnotSearch`), run on fine 1 / span 3 over 7 and on
      Simon's fine 4 / span 4 over 20 (knots 0, 1, 2, 3, 7, 11, 15, 19) - every step of a sample, the refit, a warm
      start 2 steps on; the kernels', learner's, lab's and bmpc kit's suites. The tutorial: "plans drawn at knots".
  TS1 (as planned) THE KNOT GEOMETRY AS FINE STEPS AND SPAN: `PlanningSettings.fine_steps`, `knot_span` replacing `knots` (no data
      to keep); `planKnots` / `planKnotSpan` -> one geometry: knots at steps 0 .. fine-1, then every span steps to the
      horizon's last; (horizon - fine) divides by span. Check: fine steps = horizon is the per-step search to the bit;
      the knots test restated (fine 1, span 3 over 7) and a two-scale case (fine 4, span 4 over 20).
  TS2a DONE Oct 30: THE SKIP MODEL, BUILT. `SkipModel(M)` before the kit (vocabulary first): a `KitNetwork` of the
      world model's three layers (tanh, tanh, linear) over [z_k | the span's references and actions], predicting the
      change over the span; one application over every jump of a window (W / span jumps); its own clipped Adam (no
      bound: a ceiling never reached - a clip of 0 would scale every update to nothing); `writeStartingParams` as
      `seedWeights` (Xavier, the output a hundredth, biases zero). Built against the world model's numbers only
      (`Shape`) and trained on window offsets passed in (`Windows`) - the lint's cycle (the skip model reading the
      kit, the kit holding it) answered by depending on neither. Kernels `lat_skip_gather` (a jump's RECORDED start -
      block 0's state for the first jump, the recorded state after its predecessor step for later ones, since the
      rollout overwrites the later blocks' states - then each step's reference and action from its block) and
      `lat_skip_targets` (the recorded change). `LatentKit.skip_model`, trained after the world model's step on the
      same windows. Device numbers: `skip_model_loss`, `skip_model_jump_error` and `world_model_span_error` - the gate's
      pair from the same recorded start. Checked: the gather and targets on planted windows (3 rows, 8 steps in jumps
      of 4, a lead, distinct values) exactly against the host; the kernels' and kit's suites.
      NEXT TS2b: the learner's `skip_span` (0: none), reserved after the flow before the saved parameters' end, its
      starting weights; a learner check; the gate's pair measured on the full system.
  TS2 (as planned) THE SKIP MODEL: a network beside the world model (the kit's own layers), its own clipped Adam, trained on the
      world model's windows - each window's 4-step stretches; device numbers on the same windows: its 4-step error, and
      the world model's rolled 4 steps. GATE before any plan reads it: the skip model's error at or below the rolled.
  THE WARM START WITH TWO-SCALE KNOTS (Simon: "When we warmstart the plans in the next timestep, i guess that the
      multiresolution knots make it more complicated because we need to interpolate values on knots from the values at
      the previous dt? Is that a problem?"): NOT A PROBLEM - `mppi_begin` reads the old mean's curve at each knot's
      step plus the plan's age, and that curve IS the plan (piecewise linear through its knots), so reading it loses
      nothing where the new knots are at least as dense as the old; when the age is a multiple of the span every
      coarse knot lands on an old coarse knot exactly, and only the new fine knots read between two old coarse ones
      (denser - lossless). Detail is smoothed only where old fine knots fall under new coarse ones, which an age longer
      than the fine steps puts in the past. Tested (TS1, a warm start 2 steps on over fine 4 / span 4 / 20). FOUND
      looking: decisions come once a round, so a plan's age at the next is the round's 16 steps - with today's horizon
      of 16 EVERY knot's source lies past the old plan's end (the warm start is a cold one); with 20, the last 4 steps
      carry over as the new fine knots. So with jumps, a horizon of 36 (4 fine + 8 jumps of 4, 12 sequential stages,
      fewer than today's 16) carries each decision's far half into the next, its coarse knots aligned. Rule kept: the
      round's length a multiple of the span.
  PLANNING MORE OFTEN (Simon: "Would it make sense to plan more often than every 16 steps? Maybe every step in some
      difficult situations? The warmstart would gradually become very good and the corrections perfect, and using this
      to train the policy and the flows would improve them?"). YES IN PRINCIPLE, three reasons: (1) receding horizon -
      a plan trusted one step before the state is looked at again, so the world model's errors cannot pile up over 16
      steps; (2) the warm start becomes an optimiser - at age 1 each search continues the last, twenty candidates a
      decision adding up across decisions; (3) cleaner teaching - today 15 of a plan's 16 acted steps use corrections
      chosen for an EARLIER state, and those are teacher 2's examples; a decision per step gives each example the
      correction optimised for its own state, and a better flow proposes better plans. LIMITS: the corrections are
      capped by the world model and the critic, and a search replanned every step exploits a loophole every step if
      there is one (the plans' honesty, TH2b, is the guard). THE COST is not the search's arithmetic but the round
      trip: a decision needs the GPU, which runs the previous round's training during acting, so a mid-round decision
      queues behind it - hence one decision a round today (the planner already has the clock - `replan_every`, 4 -
      the plan ages and the warm flags; only the round's scheduling keeps decisions at its end).
  R1 MEASURE FIRST, where the cost does not exist: the recovery probe (single-threaded, not racing training) with the
      planner in the loop, deciding every 16, 4 and 1 steps - the return rate and the time to return. Gate for R2-R3.
  R2 SLICES: the round's GPU work in four slices with a decision between each - every 4 steps, acting waiting a
      millisecond or two at each, training's throughput unchanged.
  R3 BURSTS: a decision every step only while a character is in serious trouble (just pushed, or its state drifting
      from its plan's prediction - the honesty gap) for 8 to 16 steps, with a lighter search per decision (one round,
      fewer candidates: the warm start at age 1 carries the work across decisions).
      Knots at age 1: the fine knots copy exactly; the far knots read a quarter of the way between old ones, rounding
      their corners slightly each step, which the refit restores.
  TS3 THE PLANNER'S SECOND HALF: after the fine steps, jumps of the span - the policy at each jump's start against its
      steps' goals in one batch, the knots' corrections, the skip model; the jump's cost by its end states; the tail at
      the end. Check: a planted skip model equal to four world-model steps gives the plain planner's scores where the
      policy's actions do not change inside a jump.
  TS4 THE EVALUATION: 16 fine steps against 4 fine + 4 jumps of 4 on the full system - the planner's gain, the plans'
      honesty (TH2b: predicted cost of the acted steps against what the physics gave), a decision's time.
  TH1 (as planned) MEASURE THE SEARCH. A device number: the planner's gain - per decision, the chosen plan's score less the policy's
      own plan's (`plan_score_combine`'s scores), averaged over the slots - and the elites' score spread. Check: on the
      full system, how often and by how much the search beats the policy alone. If the gain is near zero, the search
      finds nothing, and A is the fix.
  TH2 KNOTS (A). `PlanningSettings.knots` (0: one per step, today's search exactly): MPPI's Gaussian over [state][knot]
      [action]; `mppi_sample` draws knots and interpolates them linearly to every step; `mppi_refit` refits the knots
      from the elites' knot values; the mailbox's plan stays per step. Check: knots = horizon gives today's plans to the
      bit; 4 knots raise the planner's gain on the full system (TH1's number), and the planned returns in the probe.
  TH3 LAMBDA-RETURNS FOR THE CRITIC (B). Targets along the policy's imagined rollout (the kit's forward, horizon 32):
      G_k = c_k + gamma ((1 - lambda) V(z_k+1) + lambda G_k+1), bounded costs, lambda 0.95 as SuperMimic; the critic
      learning the CURRENT policy's value from imagined states beside the recorded windows' one-step targets. Check:
      on planted costs, the targets as the host computes them; on the full system, the critic's error and the tail's
      value; the probe's return times.
  TH4 THE VALUE OF A HORIZON (gate for C). With knots, the planner at 16, 32 and 48 steps on the return probe with the
      planner in the loop - the 1-step model throughout, only slower. If longer horizons return more often or sooner,
      C is worth building; if not, the value (TH3) is the lever and C is dropped.
  TH5 THE JUMP MODEL (C), only through TH4's gate: one jump per knot interval - the world model given the step size
      (an embedding, as the flow's time) and the interval's held correction and its reference at both ends, through
      the policy's closed loop; trained on the 1-step model's unrolled intervals (and the doubling consistency
      jump(s, 2d) = jump(jump(s, d), d)); a head for the interval's summed bounded cost. A device number checks it
      before any planning reads it: the jump against the unrolled steps on held-out windows. The planner then rolls
      fine steps near and jumps far. Check: the consistency error on tracking and on falls; the plans chosen with
      jumps against without - agreement - at a fraction of the cost.
  TH6 FLOW CHUNKS (D), only if acting still bounds a round on Simon's machine: the flow's sample a correction for one
      knot interval, held across it. Check: acting's time per round; returns in the probe no worse.

## FLOWDPG AND EFFICIENTTDMPC FOR THE WAY BACK - TEN TURNS (Oct 30; supersedes the lists below for what comes next)

(Simon: "We know supermimic is great, but we still want to demonstrate that flowdpg, and efficienttdmpc is great for
discovering paths that bring us back to mocap. Make a new plan for the next 10 turns polishing our system and
brainstorming ideas for really pushing this idea".)

THE CLAIM TO DEMONSTRATE. SuperMimic's pathwise policy is precise near the reference and myopic far from it: its
gradient comes through a model over half a second, from a squared distance that, after a fall, points straight at a
pose the body cannot reach. A FLOW actor taught by FlowDPG keeps several ways of acting where one Gaussian keeps an
average of them, and an EFFICIENTTDMPC-style planner - search through the world model, a critic past the horizon -
finds multi-second ways back no gradient step would. Shown by the return probe (returned, how often, how soon, at 1 to
5 m/s), by the DIVERSITY of the ways back, and by watching them in the lab.

WHAT EXISTS: the flow actor and its three teachers (FlowDPG - the policy's gradient projected on the synergies;
distillation from the planner's plans; FPO); the ensemble critic (two-hot heads, pessimism) and its tail; the MPPI
tracking planner (flags, slots, mailbox, plans as corrections, decisions at a round's end); returns, windows over
returns, starts in trouble, the return probe. WHAT IS MISSING is mostly about FAR FROM THE REFERENCE: the costs there,
planning there, teaching from there, practising there - and showing it.

BRAINSTORM, by the difference expected for discovering ways back (the turns take the top ones):
  1 A COST THAT MEANS SOMETHING FAR AWAY. The tracking cost is a squared distance: after a fall it is huge and says
    only "be the pose", and a two-hot critic's bins may saturate on it - flat values, no direction for the planner or
    FlowDPG. Far from the reference, cost TIME: beyond the failure rule's distance the per-step cost becomes a unit
    per step not yet back plus the distance capped, so the critic learns TIME TO RETURN - what the planner and FlowDPG
    then shorten - while near the reference the cost stays SuperTrack's.
  2 PLAN EVERY RETURN. The flags plan for characters in DANGER; a character in its aftermath is past danger and is
    where search pays most. Every returning character plans (slots permitting, the most recent losses first), its
    horizon covering a round, its tail the time-to-return critic.
  3 DISTIL THE PLANNED RETURNS into the flow (teacher 2 weighted toward return steps), and FPO on return windows: the
    flow learns the ways back the search found, and keeps them when the planner is not there.
  4 SELF-IMITATION OF THE FASTEST RETURNS: a small bank of the quickest returns the fleet itself made, distilled like
    the planner's plans - the policy's own discoveries kept rather than averaged away.
  5 FALLEN STARTS: episodes begin from fallen states the fleet has lain in (a bank of aftermath states, and the
    get-up's lying frames), the reference elsewhere in the minute - get-up practice from every way of lying, not only
    from the falls that happen to come.
  6 THE DIVERSITY OF THE WAYS BACK, measured: each probe push returned K times with K different flow noises - the
    spread of the return times and of the root's paths - the number that shows the flow keeps several ways where a
    Gaussian keeps one.
  7 GOALS FURTHER AHEAD (deferred from night 1, two turns): aiming where the reference will be.
  8 RETURN-AWARE EXPLORATION: the flow's noise correlated longer while returning, so a way back is followed through.
  9 ADVERSARIAL PUSHES: push where and when the policy returns worst - a curriculum over the push's direction and the
    clip's moment, by the return rates.
 10 A CLOCK THAT WAITS (weird): during a return the reference slows until the character is close, then catches up -
    a softer return to learn first, the slack shrinking over training to "where the motion has got to".
 11 HINDSIGHT RETURNS (weird): a failed return relabelled with the reference frames the character did pass near -
    every fall also teaches the transitions it happened to make.

THE FULL SYSTEM, MEASURED Oct 30 (Simon: "We want the first night to have everything working first try. Proceed. Find
the best ways to balance all components"). Night 1 becomes the WHOLE system - the flow and its three teachers, the
planner, the critic, returns - so it must work and be balanced before the handover. Measured on lavapipe with every
component on (the improve file plus the flow 256 wide, planning 4 slots x 24 candidates over a 16-step horizon, replay
256 steps a character):
  - IT DID NOT FIT: 26.4 million floats of activations and 7.5 million of their gradients against the trainer's 16.8
    and 4.2. The trainer's buffers now 128 MB of activations (2^25 floats - exactly WebGPU's guaranteed binding) and
    32 MB of gradients: 79% and 90% used. The planner's gather at 32 candidates was 2.13 million threads, past one
    launch's 2.1 million: 24 candidates a slot (6 per elite, 4 from the flow).
  - IT RAN - 11 rounds, every number finite - and showed FOUR THINGS NOT WORKING, each a precondition for the night:
    (a) PLANS NEVER ACTED ON: 4 decisions every round, a planned share of steps of exactly 0 - the search thrown away.
    (b) FLOWDPG SILENT: its gradient's RMS exactly 0 every round - not the synergies (0 is the full width).
    (c) COSTS FAR AWAY ON THE WRONG SCALE: the critic's values about 0.01 against targets it misses by 1,400 to 4,900
        (its two-hot bins cannot hold a fall's cost - the saturation suspected, confirmed); FPO's advantages to -11,000,
        deviations 24,000; the world model's loss spiking to 1,758. The time-to-return cost is not optional.
    (d) ACTING 13 s A ROUND against 0.1 s of training: the flow sampled on the main thread for every character every
        step (five Euler steps through a 256-wide network) - on Simon's machine it would bound the whole night.

THE TURNS BEFORE NIGHT 1 (replacing turn 1 below; the way-back turns follow after the night):
  B1 DONE Oct 30, both diagnoses CORRECTED by the raw numbers (the first reading had cut every value to seven
     characters): (a) THE PLANS were acted on - 68, 62, 63% of steps in rounds 2 to 4 - and then never, from round 5,
     exactly when training began: the readback carrying a decision's plans lands after the device's whole round,
     training included, so the plans reached the host a round late, every one past its horizon (the CPU twin reads
     back at once - why every planning check passed). FIXED: a learner that plans waits for the newest readback before
     the round it explores (`act`); on lavapipe the planned share is now 50 to 72% after training begins. (b) FLOWDPG
     is NOT silent: its gradient's RMS is about 1.4e-7 - the arithmetic of a step a tenth of the flow's noise length
     through a mean over 1,024 rows x 69 actions. Adam normalises the scale, but the teachers' gradients are SUMMED
     BEFORE Adam: FlowDPG is drowned by distillation (its loss about 0.48) and FPO - the flow is in effect taught by
     them alone. That is B4's: each teacher's share of the update measured and set. A permanent check: on the CPU twin a
     learner with a flow has nonzero cost gradients (up to 5e-4) and velocity gradient (1.5e-5). The tutorial gains the
     wait.
  B1 (as planned) PLANS ACTED ON, FLOWDPG HEARD - each diagnosed to its cause and fixed. Check: a learner with planning acts a
     nonzero share of its steps from plans; a learner with the flow logs a nonzero FlowDPG gradient that moves it.
  B2 DONE Oct 30: MEASURED first - the critic's bins span +-10 on a symlog axis (values to about 22,000), its discount
     1 - 1/90; a fall's cost in the thousands makes values near 90,000: saturated. THE BOUNDED COST, one place:
     `zn_mlp.boundedCost` = cap x tanh(cost / cap), applied by `lat_tracking_cost` - the ONE cost the critic's targets,
     FPO's advantages and the planner's scores charge (`runTrackingCost`) - with `TrackingCost.cap`, the kit's and the
     critic source's `cost_cap`, `Options.return_cost_cap` (state ZSTSTA11), the lab's mirror; the policy's pathwise
     loss keeps SuperTrack's cost (its own gradient kernels). A cap of 25: costs below 8 under 4% off, a fall's steps
     25 each - the critic's value of a fallen state 25 x its discounted steps until near again, at most 2,250, inside
     its bins. Checked: planted rows - near unchanged to a part in ten thousand, far exactly the cap (25, not 900);
     the full system on lavapipe - the critic's error from 1,400-4,900 down to 10-12, FPO's advantages from -11,000
     (deviation 24,000) to about -5 (deviation 2), the plans still acted on; every suite (exit 0). Both night-1 run
     files take the cap, identically. STILL WILD: the world model's loss spikes to 902 and 2,176 on falls - its
     prediction error, not a cost - for B4's balance (a gradient bound of its own). The tutorial: "the time to return".
  B2 (as planned) THE TIME-TO-RETURN COST (brainstorm 1): beyond the failure rule's distance a unit per step plus the distance
     capped - for the critic's targets, the planner's scores and FPO's advantages; SuperTrack's pathwise loss as it is.
     Check: the critic's error on a full run falls to the scale of its values; FPO's advantages of order one before
     their normalisation; the costs near the reference unchanged.
  B3a DONE Oct 30: ACTING IN THREE PHASES, on one thread - `prepareActing` (whether a character acts from its plan, and
     every random number its action uses - the flow's fresh noise, then the exploration's - drawn in the characters'
     order on the calling thread), `computeAction` (its features and raw action from its own numbers, into its own rows
     `acting_z`, `acting_goal`, `acting_raw`: nothing another character's reads or writes), `finishActing` (today's
     bookkeeping in order: teacher 3's completed example, the hazard, the planned count and teacher 2's or teacher 3's
     example, its goal, its action). `chooseAction`, `chooseExploringAction`, `correctedRowExploring` replaced by them
     (`exploringActionFrom`: their arithmetic, the draws made beforehand). FOUND on the way: the buffers first sized
     before `init` had allocated the rows they copy (length 0) - now at `init`'s end. Checked: the learner's whole suite,
     every exact check (resume, planning, the teachers, the flow) - the same numbers to the bit.
  B3b DONE Oct 30: PHASE 2 ON THE FLEET'S TASKS - `ActingScratch(M)`: one task's host-policy rows (its own; the
     mirrored weights and the flow the learner's, shared and read-only), the feature computation's states and probe,
     the flow's starting noise; one per physics task (`acting_scratches`); `computeAction` and `exploringActionFrom`
     work in a task's scratch; `computeEveryAction` splits the characters into tasks on `Fleet.physics_io` through
     `Io.Group`, as the physics is split. Checked pure first: the flow's host sampler and the reference's kinematics
     read only the model and the weights and write only the scratch they are given. Checked: two learners with a
     flow, one loop against four tasks - the actions, every character's state and the flow's drifting noise the same
     after three rounds, to the bit; the learner's whole suite (exit 0); the full system in the trainer with four
     tasks - the critic's errors digit for digit those of the one-thread run. Not measured here: one core.
  REVIEWED Oct 30 (Simon: "Review deeply. Improve comments"), everything since the last review:
    - CHECKED CORRECT: the watchdog's slice of the readback (the readback always reaches `readback_end`, past the
      parameters); the three-phase acting against the old order - a character's action depends on the flags and the
      mailbox of the step before, never on this step's hazards, a planned step advances no flow noise, teacher 3's
      example is completed before the new one is kept; the cost's cap set on the kit before the critic's source and the
      planner's copy are made from it; the trainer's `Io` idle on the main thread while the physics' tasks use it; the
      judge's and probe's fleets single-threaded.
    - COMMENTS: the trainer's sizes file now says what was measured and what it leaves (79%, 90%, 49%); the acting rows
      each say what they hold and when; phase 1 says why the numbers are drawn first (one random stream, so every
      character's action is the same wherever it is computed) rather than by the code it replaced; the exploring
      action's recipe written out; the rates' schedule in hours says why hours; FlowDPG's statistic says why it reads
      about 1e-7 and why its share beside the other teachers is what matters; the critic's statistics say which cost's
      units; the physics scratch gives the whole argument (reads shared, writes its own, allocates from its own arena);
      a run, not a night, in the code; the state checkpoints' retention says it counts this start's only.
  B3 (as planned) ACTING IN PARALLEL: every character's features, policy and flow sample in the physics' tasks - every noise drawn
     first, in order, on the calling thread - so the numbers are the same whatever the threads. Check: one thread and
     four act the same, to the bit; acting's share of a round on lavapipe.
  B4a DONE Oct 30: THE TEACHERS' SHARES - `kit_mlp.TeacherShares` beside `ClippedAdam` (kernels `share_factor`,
     `add_scaled_gradients`, `gradients_from_sum`): each teacher's gradient over the flow's weights written alone
     (`.overwrite`), measured as the clip measures, scaled to its share into a sum, the sum where the flow's optimiser
     reads its gradient; a teacher that taught nothing adds nothing. `FlowSettings.share_teachers` (off: the old sum),
     `dpg_share` (1); teacher 2's share its weight (`distill_weight`), teacher 3's its own (`fpo_weight`, grown with the
     critic's trust). Device numbers: each teacher's natural length (`flow_dpg_weight_gradient`, `..._distill_...`,
     `..._fpo_...`). Checked: planted gradients of lengths 1e-6, 3 and 400 and a silent one - the sum exactly
     share x g / |g|, the silent adding nothing; every suite (sharing off) unchanged; the full system with sharing on.
     B1's DIAGNOSIS CORRECTED AGAIN by the weight-space lengths: FlowDPG was NOT drowned - its gradient on the flow's
     weights is the LARGEST (0.0021 against distillation's 0.0003 and FPO's 0.00015): a tiny velocity gradient per
     element, but over a thousand rows. Summed as they came it took about 85% of each update, by accident of row
     counts; with shares the proportions are chosen - FlowDPG 1, the planner's distillation 0.5 (its ways back from
     about 7% of the update to a third), FPO its weight as the critic earns trust. The tutorial: "the teachers' shares".
  B4b DONE Oct 30: THE WORLD MODEL'S BOUND - `LatentKit.world_optimizer` (a `ClippedAdam` over its weights) and
     `stepWorld`, its length before clipping kept (`world_gradient_norm`); `Options.world_gradient_clip` (0: the kit's
     own Adam, unchanged to the bit), state ZSTSTA12, the lab's mirror. MEASURED with the bound never clipping: 15 to
     40 while tracking, 170 and 587 through a fall - spikes forty times the calm, the loss's own spikes beside them;
     a bound of 50 leaves the calm alone and keeps a fall from inflating Adam's moments. Set in all three night files,
     identically. THE WHOLE SYSTEM'S FILE, `runs/night1_full/run.zon`: night1_improve plus the flow (256 wide, the
     teachers sharing: FlowDPG 1, distillation 0.5, FPO 0.25), the planner (4 slots, 24 candidates, 4 the flow's, two
     rounds of six elites, 16 steps), replay 256. SMOKED as written: buffers 73 / 86 / 49%; planned share 47 to 72%;
     distillation's examples growing 64 a round; FPO full, its advantages sane; the critic's error 8.5 to 12; the
     teachers' lengths moving (FPO's growing with trust); the bound catching the world model's spikes; refused windows
     only at the start; every number finite. NOT SETTLED HERE: the search's cost against a round (lavapipe cannot time
     the GPU - the handover's first ten minutes will), and an adaptive trust (the ramp kept; not a mechanism to add
     the night before). The night's files: reproduce, improve, full.
  B4 (as planned) THE BALANCE: the flow's teachers measured by their SHARE OF THE FLOW'S UPDATE (each one's gradient length, a
     device number each), and the weights set so each has the share it is meant to have - FlowDPG the main one, the
     planner's distillation and FPO beside it, the anchor holding the flow near the policy until the critic is
     trusted; the planner's search against the round's time; the critic's trust against its own error. Check: the
     shares on a full run as set; the full run file smoked five minutes, every component moving.
  B5a DONE Oct 30: THE HANDOVER PAGE (`src/notes/night1_handover.md`): the three runs and what each answers (full
     against improve: the flow and the search; improve against reproduce: returning), sharing one machine (physics
     threads a third of the cores each for three runs), the build, start, stop, resume and exit codes, the first ten
     minutes' lines and columns with what to expect, THE FIRST-HOUR RULE decided now, the morning's files and question
     (the return rate at 2 to 5 m/s, run against run). FOUND writing it: a run the watchdog stopped exited 0 like a
     finished one - now 2, "the run failed". The trainer's header lists a SuperTrack folder's every file. The
     tutorial: "running a long training".
     NEXT B5b: the review since the SuperMimic study, the full gate.
  B5 (as planned) NIGHT 1 HANDED OVER: the full system and, beside it, the Gaussian with returns (night 1's improve) - the review,
     the tutorial's "running a night", the handover page, the gate.

THE TEN TURNS (each: what, where, the check that says it is done):

  1 NIGHT 1 HANDED OVER. A review of everything since the SuperMimic study; the tutorial's "running a night"; the
    handover page (the Windows build, the commands, the first ten minutes, the first-hour rule, what to read in the
    morning); the gate - so night 1 (reproduce against improve) can run while the rest is built.

  2 THE TIME-TO-RETURN COST (brainstorm 1). First measured: the costs a fall reaches against the critic's two-hot
    range (do the bins saturate?). Then the cost beyond the failure rule's distance: a unit per step plus the distance
    capped (`TrackingCost.return_unit`, `return_cap`), one definition for the critic's targets, the planner's scores
    and FlowDPG's value - SuperTrack's own cost untouched near the reference, and the policy's pathwise loss unchanged.
    Check: on planted states, near costs unchanged, far costs the unit plus the cap; a critic trained on returns values
    a fallen state by its time to return, in order of distance.

  3 PLANNING EVERY RETURN (brainstorm 2). The flags plan a character in its aftermath, slots permitting, newest losses
    first; the planner scores with the return cost and the critic's tail; the probe gains a planner-in-the-loop actor,
    so a judgement can say how the search itself returns. Check: every returning character holds a slot while slots
    last; the planned share of return steps; the probe with the planner on lavapipe.

  4 TEACHING FROM RETURNS (brainstorms 3, 4). Teacher 2's examples weighted toward planned return steps; FPO's windows
    a share inside returns, as the policy's; a bank of the fleet's fastest returns distilled like plans
    (self-imitation). Check: the teachers' losses on return examples falling; the bank keeps the fastest; nothing
    else's numbers move.

  5 FALLEN STARTS (brainstorm 5). A bank of states from aftermaths and the get-up's lying frames; a share of starts
    from it, following the push schedule, the reference at a random frame of the minute. Check: such starts begin
    lying; their returns counted; the curriculum's rates untouched by them.

  6 THE DIVERSITY OF THE WAYS BACK (brainstorm 6). The probe returns each push K times with K flow noises: the spread
    of return times and of the root's paths, per band, in `recovery.csv`. Check: a Gaussian policy's spread is its
    noise's alone; a flow's is measured; the columns fill.

  7 THE FLOW'S POLICY FILE AND THE LAB'S RETURNS. The policy file holds the flow, its synergies and its condition, so
    the lab plays a flow run; a lab page pushes a character and shows its return, K returns overlaid from one push.
    Check: the file acts as the learner, number for number; the page renders on lavapipe's screenshot.

  8 NIGHT 2'S RUN FILES. Three runs, all with returns, identical but for the actor: the Gaussian (night 1's improve),
    the flow with its teachers, and the flow with planning every return - each smoked on lavapipe, judged and probed.
    Check: each fits, trains, judges, probes, resumes.

  9 GOALS FURTHER AHEAD, policy-only (brainstorm 7) - or, if night 1's morning says otherwise, what it asks for. The
    goal rows widened for the policy alone, the flow, FPO and the planner keeping the immediate goal; the host from
    the tables. Check: the goal rows hold the frames asked for; acting and the device agree to the bit.

 10 REVIEW, THE TUTORIAL'S CHAPTER ON THE WAY BACK, HANDOVER, GATE. The robot-mocap tutorial gains a chapter: why
    the pathwise gradient is myopic far away, time to return, planning and distilling returns, fallen starts, the
    diversity measured - with the zimrrl tutorial carrying what is not tracking-specific; the night 2 handover; the
    full gate.

## THE FIRST NIGHT IN TEN TURNS - Oct 30 (supersedes every list below for what comes next)

(Simon: "Look at the plan we had before i interrupted you with the multithreading work. Make a complete and precise
new plan for the next 10 turns, that includes everything necessary for a succesful first night".)

WHAT A SUCCESSFUL FIRST NIGHT IS: two runs on the minute (dance 20 s, get-up 18 s, walk 11 s, run 11 s) with pushes
that grow to 2.0 m/s and beyond, on Simon's Windows machine, that (1) run all night without dying or silently
corrupting (safeguards, the exact files smoked first), (2) learn (SuperMimic's fundamentals in place), (3) show
everything that happens (each clip, each teacher, the critic, the pushes, the planner, time), and (4) put the goal to
the test - REPRODUCE (SuperMimic's recipe on the minute, time-locked, an episode ending at a loss) against IMPROVE
(rejoining the mocap after a loss, living on, resets into trouble, bigger pushes). A first night that answers "does
rejoining teach recovery that the recipe alone does not" is a success whatever the answer.

DONE TOWARD IT (Oct 30): the two horizons (`policy_window` 32 over the world model's 8); the policy's clipped
optimiser and the rates' cosine schedule; the reset curriculum; the minute on Geno and its motion; the trainer's own
buffer sizes; and of the actor work: the host's policy on its own, records built apart from their upload, decisions at
a round's end. The device's numbers for the flow's teachers, the world model and the policy's tracking term; per-clip
judging, probing, status and console; pushes that grow; ReleaseSafe; the policy probe's crash fixed.

DECIDED: THE WORKERS WAIT FOR THE SECOND NIGHT. The persistent-worker architecture (web parallelism, acting overlapping
training) is four turns. For a night on Windows, PARALLEL PHYSICS on native threads gives most of the speed in one: a
character's integration is independent of every other's, so it runs on any thread while every random draw - pushes,
restarts - stays on the main thread in its order. The results are identical whatever the thread count, and the web,
running the same loop on one thread, gets the same numbers: Simon's "normal multithreading on native with shared
memory", with results that do not depend on the platform. Also after the first night: future goals, the survival
objective, the push-and-stumble mapping, the lab's view of the log, the compute knob's controller.

REVIEWED Oct 30 (Simon: "Review deeply recent code") - found and fixed, or corrected in the plan:
  - A REFUSED WINDOW DRAW WAS SILENT. Windows are 33 records inside one segment now (the horizon's 32 steps), and
    pushes, restarts and resets into trouble cut segments: a run whose segments fall short stops training with no
    error, its update counts stalling. Counted now (`Resident.windows_refused`); turn 2 logs it.
  - THE CURRICULUM CHASED NOISE: its softmax scaled by the CURRENT highest rate, so late in training, every bin easy,
    bins differing by noise still weighed e^5 apart. Now on an absolute scale - losses per second of motion (rate per
    step x frames per second), the exponent capped - so easy bins weigh nearly the same, as SuperMimic's normalising
    by the largest attainable return does. The check plants a bin losing its reference once a second.
  - PLANS SHORTER THAN A ROUND: one decision a round, at its end, and the planner's default horizon 4 steps against
    rounds of 16 to 48 - a character would act from its plan only at each round's start. A run file whose planning
    horizon is shorter than its round is refused by name (`GenoRun.problem`); N5 sets it to cover a round and the
    readback's frame.
  - TWO CORRECTIONS TO TURNS 4 AND 5, before they are built: (a) a re-sync must NOT start a replay segment - segments
    are for physical discontinuities the world model cannot predict (pushes, teleports); a re-sync changes only the
    reference, and every record carries its own reference row, so a window across it is consistent, while a segment
    per re-sync (re-matching every few steps while far) would chop recoveries shorter than any window. (b) The
    policy's windows start only BEFORE a loss (`WindowStart.before_loss`, "where tracking still means something"):
    with rejoining, a re-synchronised character is tracking again, so a re-sync must open its stretch to the policy's
    windows - or the policy never sees a step of any recovery.

REVIEWED AGAIN Oct 30, after turn 3 (Simon: "Review"):
  - A DATA RACE IN THE PARALLEL PHYSICS, hidden by a one-core container. Every collision world's per-step scratch
    arena, every world's own structures and every character's data were backed by ONE allocator - the fleet's arena,
    not safe on two threads - and a world asks it for memory whenever its contacts outgrow what it holds (the first
    steps; a fall, many bodies on the floor). Four threads on many cores could corrupt it - during exactly the falls a
    night is about. Fixed by construction: `Fleet.character_arenas`, one per character, backed by the fleet's `gpa`
    directly (thread-safe - Zig's general-purpose allocators are), holding each character's data, world and bridge;
    freed on a failed init too. Checked on any machine: across 120 threaded steps the fleet's shared arena does not
    grow by a byte.
  - A STATISTIC SPECIAL-CASED BY NAME: `recordDeviceStat` wrote `stat_barrier`'s output at `w_off` because that kernel
    reads its states at `y_off` - the next statistic reading `y_off` would have overwritten its own input. Now one
    rule: every statistic writes at `Params.stat_off` (a padding slot of the parameter block), all seven kernels and
    their checks moved to it.
  - THE DISK: the container's disk filled to 98%, and the build refused (by its own guard) - cleared of build outputs,
    the build's scratch, old unpacked snapshots and the superseded snapshot. Keep only the newest snapshot.

THE TEN TURNS (each: what, where, the check that says it is done):

  1 DONE Oct 30: kernels `critic_value_stats` (the heads' mean value, their mean spread across heads, their RMS
    error against the targets) and `stat_barrier` (the mean of every rolled state's hinges through the cost's own
    `barrierMeasures` and `barrierHinges`); `DeviceStats` gains `critic_value_mean`, `critic_head_spread`,
    `critic_value_error`, `policy_barrier_hinge`, `policy_tail_value`, `policy_tail_deviation`; ONE recording function
    for the kit and the critic (`recordDeviceStat`), the critic decoding its online heads into its targets' scratch
    only when it keeps a block; the barrier measured only where the kit holds the normaliser (a flow test's kit has
    none - the kit's own assertion caught the first version). Checked: both kernels against the host's arithmetic on
    planted values (the barrier's through `barrierHinges` itself - its smooth hinge is not zero at zero error); in
    the learner every new number finite, the critic's error positive; every suite, lavapipe, the trainer.
  1 (as planned) THE DEVICE'S NUMBERS, COMPLETE. `DeviceStats` gains: the critic's TD loss, its heads' mean value and their mean
    spread (where the critic's update has its online values and targets); the policy loss's barrier and tail parts
    (the barrier's hinge summed over the rollout, the tail's mean critic value at the horizon). Check: each against the
    host's arithmetic in the learner's tests; lavapipe compiles. Tutorial: the stats table complete.

  2 DONE Oct 30: `lab.SuperTrackLog.Line` is the ONE DEFINITION of the log - its fields the columns, the device's
    numbers flattened by their own names (`latent_kit.DeviceStats`), the header and every line generated from it at
    compile time - 38 columns: the round's counts (the learner's totals' differences: steps, failures, updates, pushes
    and their mean speed, decisions, the planned share, non-finite actions, refused readbacks, refused windows), at its
    end (the planning share, the mean hazard, examples held, the trust), its time (acting, training on the CPU's side,
    judging - `Resident.train` split from `simulateAndTrain` so the trainer times the halves), and the device's. The
    status carries the world model's loss, the critic's error, the gradient length and the totals of refused windows
    and non-finite actions. FOUND by the real run: the tail's statistic was 0 in every round - the tail decodes its
    heads' values only when pessimistic; `Tail.addGradient` now decodes them for the log too when the kit keeps a block.
    Checked: the header's and a line's columns agree, every device number among them, no name twice; a 1.2-minute
    lavapipe run - 195 lines of 38 columns, every number finite, the tail's value in every round after the trust
    opened it, 5 refused windows from before the replay held 33-step windows; every suite. The tutorial gains the log.
  2 (as planned) THE HOST'S NUMBERS, THE LOG, THE STATUS. Per round, counted where they happen: pushes given and their mean speed
    (the fleet's counters), the flagged share and the mean hazard, decisions and the share of steps acted from a
    plan, teacher 2's and 3's examples held, the trust in the critic, non-finite actions and refused mirrors, and time
    - milliseconds acting, recording, training, judging, rounds per minute. `lab.SuperTrackLog`: every device and host
    number a named column, one line per round; `status.zon`: the newest of the ones checked first; the console line a
    compact few. Check: a short lavapipe run fills every column, finite; the log reads back by the columns' names.

  3 DONE Oct 30: `Fleet.step` in three phases - every character recorded (in order), every character's physics
    (`driveEveryCharacter`: tasks of consecutive characters on `Fleet.physics_io`'s threads through `Io.Group`, or one
    loop), then measuring, ending, restarting and pushing (in order - every random draw). `DriveScratch` (the seven
    buffers a physics step used from the fleet: targets, the reference's velocity, accelerations, scratch, the dense
    mass matrix, its row, torques) one per task; a collision world's failure flagged per character and reported after
    the join; no file-scope mutable state in the physics (checked). `physics_threads` (`Fleet.Options`; the lab's
    0: every core); the trainer gives the fleet its `Io`. The draws stay in their old order, so the phased step is the
    old step. Checked: eight characters, 120 steps of random actions with restarts - one thread and four the same
    positions, velocities, ends and failures, to the bit; every suite (the resume checks to the bit); the trainer on
    lavapipe through the threaded path. NOT MEASURED HERE: the container has one core - the speed shows on Simon's
    machine, in the console's rounds per minute.
  3 (as planned) PARALLEL PHYSICS ON NATIVE. `Fleet.step` in three phases - before (pushes and their draws, the replay's record:
    in order, on the main thread), the integration (every character's physics, on a pool of native threads, each
    character's world its own), after (errors, failures, ends, restarts and their draws, the curriculum: in order).
    A `physics_threads` setting (0: every core; the web: one). Check: one thread and four give the same replay,
    number for number; the trainer's rounds per second on lavapipe with one and with four.

  REDIRECTED Oct 30 (Simon: "we need to return to the reference directly, smoothly inventing what is necessary. We
  will do motion matching and getup selection another time."): no matching index, no re-sync - a character that loses
  the reference returns to the reference ITSELF, where the clock has it, and the policy invents the way: getting up,
  catching up. The matching index written for the old turn 4 is removed (its column helpers kept for the barrier).

  DONE Oct 30 (Simon: "We will assume 8 hour runs, that could continue for longer. Prepare curiculums to increase push
  force and frequencies so there are none in the first hour and they increase gradually"): THE PUSHES' SCHEDULE in
  TRAINING HOURS - `Pushes.start_hours`, `full_hours`, `scheduleShare` (0 before the start, a straight line to 1 at
  the full hour, 1 after, 1 throughout without a schedule); the share scales the random pushes' RATE and the TOP of
  their speed range together; `Fleet.training_hours`, told each round by the trainer from its saved clock (whatever
  the machine's speed, across a resume); the log's `push_schedule` column. Replaces `ramp_steps` and the fleet's step
  counter. Checked: hour 0.5 pushes nobody, hour 2 about half the full rate inside the half-opened range, hour 4 the
  full rate; every suite. THE NIGHT'S NUMBERS (turn 8): start at hour 1, full at hour 7, held after - a run past eight
  hours trains at full strength. Starts in trouble (turn 4) follow the same share: none in the first hour.

  4a DONE Oct 30: THE RETURN in the fleet - `Fleet.Options.return_steps`: each step of an aftermath asks the rule the
     other way round (held again?), a streak of `return_steps` is a RETURN: the aftermath ends, the episode goes on, a
     later loss counts again; an aftermath that runs out ends its episode. Per character `return_streaks`,
     `steps_since_loss`, `returned`; the fleet's totals `returns`, `return_steps_sum`; a new episode clears the
     streak. 0 is the old aftermath exactly. The lab's `return_steps`, the trainer passing it, the log's `returns` and
     `return_mean_seconds`. Checked: two characters lost by a metre - one put back on its reference returns after
     exactly 8 steps, its episode going on; one kept off ends exactly when its 60-step aftermath runs out, no second
     failure; one return of 8 counted; every suite. The tutorial's "Returning", with a sketch.
  4b DONE Oct 30: THE POLICY'S WINDOWS OVER RETURNS - `WindowStart.after_loss`; `Resident.drawPolicyWindows` draws
     each window inside a return with probability `returnWindowShare()` (`Options.return_window_share`, 0.25, when
     the fleet has returns; none otherwise), offered once and falling back to before a loss; a share of 0 draws
     nothing more from the stream. FOUND: `trainPolicy`'s comment said the tracking loss's gradients SATURATE in a
     fall - they do not: it is a squared distance, so far from the reference the gradient is LARGE; hence the share,
     so returns teach the way back without drowning the tracking near the reference (and the global clipping bounds
     the rest). State file ZSTSTAT9. STARTS IN TROUBLE: `Pushes.start_share` - a new episode pushed at the top of the
     range the schedule has opened, with probability share x the schedule's share (none before it starts). Checked:
     after-loss windows start after a loss, before-loss ones never; four first starts pushed at the top speed, none
     before the schedule; a learner at share 1 stages only windows inside returns, at 0 exactly the old draws from the
     same stream; every suite, the trainer. The tutorial's "Learning the way back", "Starts in trouble".
     DISK: the build cache (8.6 GB) fills the container; cleared at this turn's end - the next turn rebuilds cold.
  4 (as planned) RETURNING TO THE REFERENCE. The aftermath (`Fleet.Options.aftermath_steps`, the reference running on after a
    loss) becomes a RETURN: each step of it asks the failure rule the other way round, and a character whose
    tracking holds again for `return_steps` steps in a row has RETURNED - its aftermath ends and its EPISODE GOES ON,
    a later loss counting again; the limit running out first ends the episode, a failure to return. Counted per clip:
    losses, returns, steps each return took. The policy's windows open over returning stretches (the time-locked
    reference is the goal of a return - `WindowStart.before_loss` gives way to windows anywhere when returning is
    on), so the policy learns from every step of every return. A share of starts begin in trouble: a push at the
    ramp's full speed in the first second. Check: a pushed character that recovers returns and its episode goes on;
    one that cannot ends at the limit; the counts add up; the policy's windows start inside returns.

  5 DONE Oct 30: THE RETURN PROBE - the recovery probe extended, not duplicated: `RecoveryProbe.return_seconds`,
    `return_hold_steps` give the probe's fleet an aftermath with returns and extend the watch to cover it; the band's
    loop reads `failures`/`returned`/`dones` and follows each loss to its end - RETURNED (with the steps from the
    loss), NOT RETURNED (the aftermath ran out, `End.aftermath`), or unresolved (the clip ended first: counted
    nowhere, so `returnRate` is over resolved losses only); `RecoveryBand.lost`, `returned`, `return_steps_sum`,
    `not_returned`; without returns `lost = pushes - survived`, the old probe exactly. `recovery.csv` gains the four
    columns. `GenoControls.probe` - the run's own, default pushes of 1 to 5 m/s, returns followed 5 s; the trainer's
    probes take it (PPO's the same default). Checked: the servo on a walk - every pushed start survived or lost, every
    loss accounted for at most once, with returns and without; a real lavapipe run's recovery.csv - the servo on the
    dance loses every start at every band, one of 13 returning at 2 m/s after 1.7 s; every suite. The tutorial's probe
    gains returns, with a sketch of the four outcomes. (The log's returns columns came with 4a.)
  5 (as planned) THE RETURN PROBE. On each clip, pushes of 1 to 5 m/s on characters tracking it: per band, pushed, lost, returned
    within the limit, the mean time to return - `return.csv`, the servo's lines first; the log's columns for returns
    per round and their mean time. Check: the servo's lines on lavapipe; a column per number.

  6 DEFERRED Oct 30 to after the first night (Simon: "Defer"): reading the code showed the goal is one frame of
    features in many places - the flow's condition (`2 x features` in FPO and distillation), the planner's gather,
    the host's policy and its packing, the policy file - two or three turns of layout change before the safeguards
    and smokes. The freed turn is a BUFFER before the night.
  REVIEWED Oct 30 (Simon: "Review recent code"), the schedule, returns, windows over returns, starts in trouble and
  the return probe:
    - EXPOSURE COUNTED STEPS IN AFTERMATHS: the learner counted every step as watched, the aftermath's too - steps the
      fleet flags as not at risk. With returns, aftermaths are common: the improve run's time to failure would have
      been inflated against the reproduce run's, the night's own comparison. Fixed: only steps not in an aftermath are
      watched, per clip too. Checked: a learner acting step by step with aftermaths - its exposure every
      character-step less the aftermath's, exactly.
    - A RUN LEARNING FROM RETURNS WITHOUT A GRADIENT BOUND is refused (`GenoRun.problem`): windows inside returns carry
      large distances and large gradients, and the policy's global clip is off by default.
    - CHECKED CLEAN: every physics function takes the model read-only (`*const Model`), so the threads only read it;
      the return's streak and steps since a loss reset at a new episode and at a new loss; a window after a return is
      a before-loss window again (the replay's flag is per record); the probe follows a loss only within its watch.
    - NOTED for the run files (turn 8): starts in trouble also raise the curriculum's failure rates where they land -
      spread over every bin, so the curriculum is shifted little; the probe's fleets do not use the physics threads,
      so a five-band probe with five-second returns is the slowest part of a judgement - time it in the smoke.
  6 (as planned, deferred) GOALS FURTHER AHEAD. Returning to a reference that keeps moving means aiming where it will be: the policy reads
    the reference at several frames ahead (SuperMimic reads ten), not the next one only - the goal rows and the
    tables widened, the gather and the policy's input with them. Check: the goal rows hold the frames asked for; a
    learner with them trains, finite.

  7 DONE Oct 30: THE WATCHDOG - `Resident.nonfiniteCause` (the newest readback's weights below `params_end`, named by
    network - world model, policy, critic or flow - then every `DeviceStats` number, the first not finite named);
    `RunState.failed_nonfinite`, `RunStatus.nonfinite`; checked at every round's start (`superTrackEndState`) and by
    both saves after their fresh readback (`error.StateNotFinite`, the loop turning it into the failed end); a failed
    run's final save writes only its log and status; the console names the cause. STATE CHECKPOINTS - each checkpoint
    also keeps `supertrack_state_m<minute>` (`RunFile.stateCheckpointName`), the newest four (`SuperTrackProgress`),
    an overwrite of the newest not kept twice; a flow run checkpoints its state now (before: nothing). FOUND: writes
    were already atomic (`native_os.writeWhole`: beside, then renamed). Checked: a planted NaN in a policy weight named
    as the policy's, a device number by its field; a 1.2-minute run finished, nothing non-finite; a 4.5-minute run with
    checkpoints every 0.7 minutes kept exactly minutes 1 to 4. MOVED TO THE BUFFER TURN: the collapse alarm, and the
    device's buffer use printed at start (a run that does not fit is already refused, `KitTooSmall`).
  7 (as planned) SAFEGUARDS. The learner's state checkpointed every 30 minutes (`supertrack_state_m<N>`, the last four kept); a
    NON-FINITE WATCHDOG - a non-finite weight or device number stops the run with status `.failed_nonfinite` naming
    what went first, the last good checkpoint intact; a COLLAPSE ALARM in the status - each clip's judged time to
    failure under the servo's for three judgements; the DEVICE'S LIMITS printed at start against every buffer, a run
    that does not fit refused by name. Check: a planted non-finite stops the run as said; a restart from a checkpoint
    carries on; a planted oversize refused.

  8 DONE Oct 30: THE RATES' SCHEDULE IN HOURS - `Options.rate_decay_hours` (over `rate_decay_updates` when set),
    `Resident.training_hours` told by the trainer beside the fleet's: a night's updates are known only once a machine
    has run it, its hours from the start (state ZSTSTA10). THE RUN FILES, `runs/night1_reproduce/run.zon` and
    `runs/night1_improve/run.zon`, every number with its reason, IDENTICAL BUT FOR RETURNS (aftermath 300 steps,
    return_steps 8, return_window_share 0.25) - pushes, starts in trouble, everything else the same, so the morning's
    difference is what returning teaches: the minute, 32 characters, replay 512, rows 32, window 8 / horizon 32, width
    256, beta2 0.95, gradient clip 20, cosine over 8 hours to 3%, critic and tail at 1.0, curriculum 1 s 50/40/10,
    pushes 0.5/s at 0.5-3.5 m/s from hour 1 to 7, a quarter of starts in trouble, judged and checkpointed every 30
    minutes, until stopped. Flow and planner left out of night 1: they would confound the one comparison. THE FIRST
    SMOKE - the reproduce file as written, on lavapipe: it fits the trainer's buffers and trains (42 rounds in 2.7 min,
    41 columns finite, losses falling, 6 windows refused only at the start, the gradient's length about 2.3 - the clip
    catches spikes only); resumed from its state at round 42; stopped by its stop file (`stopped`, the file consumed);
    the log continuing. Acting 3.8 s a round against 1 s of training here - one core; the physics threads go after it
    on Simon's machine. The console's "the the minute" fixed. The resumed clock is the last logged round's: the gap
    to a run's reported end is its final save, not training.
  8 (as planned) THE RUN FILES, AND THE FIRST SMOKE. `runs/night1_reproduce/run.zon` and `runs/night1_improve/run.zon`, every
    number with its reason: the minute; characters a multiple of four; window 8, horizon 32; the critic and its tail,
    trust over 1,000 updates; the clipping set from the logged gradient length; the cosine over the night's updates;
    the curriculum; pushes ramped to 2.0 m/s (improve: 3.0) over the first hour; replay steps; judge interval from the
    logged judging time. IMPROVE adds rejoining, living on, resets into trouble, the flow with its teachers and the
    planner. The REPRODUCE file smoked on lavapipe for about ten minutes through a stop and a resume. Check: every
    column moving and finite; the judge, probe and rejoin probe per clip; a checkpoint; the resume carrying on.

  9 DONE Oct 30: THE SECOND SMOKE - the improve file as written, judged at 0.3 minutes on lavapipe: the servo's
    baseline and the policy each judged on the four clips (`judge.csv`, a line per clip each) and probed at 1 to 5
    m/s with returns followed (`recovery.csv`, 40 lines: 4 clips x 5 bands x 2, every loss accounted for - on the walk
    all lost, none returned, as the servo and an untrained policy should); a clean exit. The judgement (servo and
    policy) took about 2.1 minutes of this one core; its time is now SAID on the console at once (it went to the next
    round's line, which a run ending after it never wrote). THE POLICY FILE: night 1's actor is Gaussian, and the
    trainer already checks every start that its policy file acts as the learner does - it passed here; the flow's
    file is deferred with the flow.
 9 (as planned) THE SECOND SMOKE, THE POLICY FILE. The IMPROVE file smoked as the first; its fixes. The policy file holds the
    policy, the flow and the synergies, so the lab plays what the night learned (the flow run's judge already acts as
    the learner does). Check: the file acts as the learner, number for number; the smoke clean.

 BUFFER DONE Oct 30: THE COLLAPSE ALARM - `lab.JudgeLog.collapsedClip` over `judge.csv`'s whole history (so it holds
    across a resume): the first clip whose policy was once judged better than its servo (the clip's batch-0 line) and
    since no better three judgements running; `RunStatus.collapse`, said on the console when it first appears; quiet
    below the servo before ever above it (an untrained policy). THE BUFFERS USED - `Resident.buffers_used` (the final
    layout), said at the start as shares of the trainer's activations, gradients and parameters. FOUND: the night's
    configuration fills 96% of the activations (gradients 68%, parameters 34%) - it fits, a larger one is refused at
    start; the run files now say more characters need proportionally fewer replay steps. Checked: dance collapsed
    (below, above, then below three times), get-up never above (no alarm), walk below only twice (not yet); the start
    line on a resumed smoke; every suite.
10 REVIEW, TUTORIAL, HANDOVER, GATE. Review of everything since the SuperMimic study, for what a night could break;
    the tutorial's "running a night" - the run files, the log's columns and what each says, the alarms, the files a
    run leaves, stopping and resuming; the handover page - the Windows build (`zig build geno-trainer-windows`), the
    commands, the first ten minutes (rounds per minute, every clip's time, nothing non-finite), the FIRST-HOUR RULE
    (each clip's judged time to failure against the servo's and between the two runs), what to read in the morning;
    the full gate; the snapshot.

## THE GOAL - Oct 30 (Simon: "Our goal is to reproduce this result and improve upon it, by having a much shorter
## dataset: just one minute of animation, but survive and come back from much bigger perturbation and discover new ways
## to get up and go back onto mocap. Proceed")

REPRODUCE SuperMimic's core recipe - H 32 with a critic past it, the policy's gradient clipped, a reset curriculum,
future goals - on ONE MINUTE of mocap: the dance (20 s), the get-up (18 s), and LAFAN1's walk, run and push-and-stumble
takes on Geno to fill the minute. IMPROVE on it where it is weakest: SuperMimic ends an episode the moment the robot
deviates (0.25 m, or 0.8 of tilt) and tested pushes only on a standing T-pose; its "lying and standing up" are tracked
get-ups, not recoveries from falls nobody planned. We want characters knocked down mid-dance by pushes far larger, that
get up by ways they find themselves and REJOIN the mocap.

THE DESIGN THIS ASKS FOR - REJOINING THE MOCAP. After a big push the time-locked reference is the wrong goal: the clip
dances on while the character lies on the floor, and the distance to it is huge and points nowhere useful. So the goal
moves: MOTION MATCHING for recovery. A character that has lost its reference matches its pose against every frame of
the minute (height, up direction, joint angles - a few numbers per frame, a few thousand frames, cheap on the host)
and its reference continues from the nearest frame, played forward, matched again while it is still far. Knocked down
mid-dance, it finds the get-up's lying frames, tracks the get-up to standing, and finds the dance again. The mocap
gives the waypoints; the route from an arbitrary fallen pose onto them is what the learner must discover - the critic's
value of being back, the flow's several ways, the planner's search, FPO's real returns. And: characters LIVE ON after
a loss until they rejoin or run out of time; a share of resets start IN TROUBLE (fallen states from the replay, or a
big push in the first second); a REJOIN PROBE measures what matters - big pushes on dancing characters, the time to
fall, to get up, to rejoin.

THE HORIZON, DESIGNED SIMPLY: one kit sized for the policy's 32 steps, the world model's passes (its recorded-action
forward, its backward, its loss) stopping at its own 8 - its update costs what it costs today, the flow, the tail and
the teachers simply sized for 32, nothing moved to a second kit. The windows gathered are 32 long; the world model
learns from their first 8.

THE THIRTY TURNS, REVISED (supersedes the list below):
   1 SM1a DONE Oct 30: `LatentKit.world_steps` - the world model's own window, `steps` by default: its rollout on the
     recorded actions, its backward, its loss (the page's and the log's) and its Adam's divisor stop there; the
     policy's rollout, backward and teachers keep `steps`, the policy's horizon. Checked: in a 32-step kit limited to 8,
     a world update equals an 8-step kit's on windows from the same starts - the same loss, every weight the same,
     and moved; every kit, learner and kernel suite unchanged.
   2 SM1b DONE Oct 30: `Options.policy_window` (0: the world model's `window`) and `Options.horizon()`; the kit as
     long as the horizon, `world_steps` the window; windows drawn and staged the kit's length; a policy window shorter
     than the world model's refused by name; `SavedOptions` holds it (state `ZSTSTAT6`); the lab's settings mirror it
     and the training task's grace covers a whole window of the HORIZON (else an early-failing policy leaves no
     window to train on). Default 0 keeps every page, test and run as it was; the run files set 32. Checked: a
     learner of window 8 and horizon 32 - the kit 32 long, its world window 8, a round training both networks with
     finite weights, a second learner given its state writing back the same bytes; every learner and lab suite
     unchanged. The tutorial's value-tail section gains the two horizons, with a sketch.
   3 SM2 (CLIPPING) DONE Oct 30: `kit_mlp.ClippedAdam` gains an element-wise bound after the global factor
     (`adam_clipped`, `Params.gradient_element_clip`); the kit's `policy_optimizer` - the policy's step through it,
     epsilon carrying the horizon, its length before clipping logged (`DeviceStats.policy_gradient_norm`,
     `stat_copy`); the kit's own Adam takes its corrections from `zn.adamCorrectionMultipliers` (one definition);
     every learner with a policy steps it so, from ONE layout `init` opens and `buildExtras` continues (the
     policy's optimiser, then the critic, the flow, the planner); options `policy_gradient_clip`,
     `policy_element_clip`, `policy_beta2` (state `ZSTSTAT7`, mirrored in the lab) - bounding nothing by default.
     Checked: planted gradients clamped to the bound in Adam's first moment; with nothing to bound, the clipped
     path gives the plain Adam's policy weights to the bit; the learner logs a positive, finite length; every suite
     and lavapipe. The tutorial gains the policy's optimiser. The bounds are set from the smokes' logged lengths.
   3b DONE Oct 30: the rates' schedule - options `rate_decay_updates` (0: constant) and `rate_floor_share` (0.03),
     every network's rate a share of its base by ZIMRNUM'S OWN `cosineLearningRate` at its own update count (found
     already there, with its test - a duplicate written for the purpose was removed; its comment gains the worked
     example); the critic's and the flow's stored rates set before each update, as the trust sets the teachers'
     weights; state `ZSTSTAT8`, mirrored in the lab. Checked: on a schedule of four updates, after each round the
     critic's and the flow's rates are their bases times the share at their own counts, and the floor after it; every
     learner and lab suite, the trainer. The robot-mocap tutorial says so, linking zimrnum 10.10.
   4 REORDERED Oct 30: the reset curriculum came first. Future goals touch every place a policy input is built - the
     gather kernel, the host's acting row, the planner's scorer rows, the flow's condition with FPO's columns and
     teacher 2's examples, the lab's policy file and its judge: two or three turns with risk - while SuperTrack
     tracked well with the next frame alone, and for this goal the curriculum and rejoining matter more. Future goals
     move after the rejoin work (turn 11b), where the matched reference feeds them anyway.
   5 SM4 DONE Oct 30: `robot_track.ResetCurriculum` (`Fleet.Options.curriculum`): each clip in bins of whole frames
     (`binFrames` - counting in seconds made six bins of a 5 s clip), each bin's running failure rate updated at
     every step from the step's reference frame; restarts drawn 50 / 40 / 10 - uniform, softmax(sharpness x rate /
     highest) toward the failing bins, the long-run weights the hard draws' shares average into (`drawStartFrame`).
     A bin length of 0 is no curriculum: the old single draw. The lab's settings carry it beside the pushes (a
     fleet's setting) and the trainer passes it. Checked: with one bin failing at 0.2 of five, 20,000 starts land in
     it 0.59 of the time as the mixture's arithmetic says, the others a quarter of the rest; without a curriculum,
     the old draws from the same stream; a falling fleet's bins hold rates within [0, 1]; every suite and the
     trainer. The tutorial's fleet section explains it with the worked table.
   6 DATA DONE Oct 30: the minute on Geno - the dance (20 s), the get-up (18 s), walking and running (11 s each, from
     the takes' second second): `robot_geno`'s bake per capture; `GenoMotion.one_minute` and `GenoMotion.clipLabels`
     (each motion names its clips, in the trainer's order - one definition for the clips a run trains, the labels
     its lines carry, and the refusal of several clips to any learner but SuperTrack); the trainer embeds walking and
     running, takes the run's clips as the first `clipLabels().len` of Geno's, keeps four clips' windows, and names
     any number of clips on its console line. The push-and-stumble take is SUBJECT 5's - LAFAN1's own 22-joint
     skeleton, not Geno's 35 (no Spine3, Neck1 or end sites; toes named apart): it needs a joint mapping, so it waits
     (LATER). Checked: the bake rebaked once and then holds, every clip on Geno (99 numbers a frame), sixty seconds.
     FOUND, THE DEVICE'S LIMIT FOR REAL: the minute on the trainer stops at start with `KitTooSmall`. The kernels'
     activation buffer is 2^21 floats (8 MB) - sized for the pages, whose CPU twin keeps it as static wasm memory -
     and a minute of reference tables alone (3,600 frames x ~600 numbers) fills it before any replay; the night's
     replay (SuperMimic keeps 1,000 steps per character: ~330 numbers each) wants ~16 million more.
   6b DONE Oct 30: THE KIT'S SIZES PER BUILD. The kernels' buffers are FIXED-SIZE arrays in the shaders too
     (`kompute.bind` declares the field's own type), so a size must reach the shader compile, not just the host. A
     sizes module threaded through every build path would touch the library, the tests, the pages and the shader
     pipeline; instead `zn_mlp.zig` imports its sizes BY RELATIVE PATH (`zn_mlp_sizes.zig`, the pages': 8 / 4 / 1 MB,
     every other build unchanged), and the trainer's build alone copies the kernel source beside its own sizes under
     that name (`zn_mlp_sizes_trainer.zig`: 64 / 16 / 8 MB) - its CPU module and its SPIR-V from the one copy, so they
     agree. Checked: the minute on lavapipe - 423 rounds, every clip named with its time, a clean exit; the Windows
     trainer builds; `check` and the kernels' suite at the pages' sizes unchanged. The tutorial's kit chapter gains the
     sizes, with a table.
  ACTORS - experience on every core, identically on the web and native (Simon, Oct 30: "We should ensure
  multithreading works for generating experience efficiently ... On workers we cant share memory because we want to
  make it work identically on web and native. But now i am realising that memory transfer for gathering experience
  will be costly. Maybe we can have normal multithreading on native with shared memory(?)").
  FOUND: the fleet steps every character on one thread, and acting and training take turns - the CPU's physics and
  the GPU's training never overlap. Every character already has its own physics world (`Fleet.worlds`), so they
  partition freely. `jobs.zig` runs STATELESS kernels (input copied in, result copied out, nothing kept): built for
  latency, one-shot jobs; experience needs PERSISTENT workers - characters, physics worlds, weights kept between rounds.
  THE ARITHMETIC: a record is 441 floats (Geno: 371 features, 69 actions, its table row) - 1.76 KB. A night's round,
  40 characters x 48 steps, is 3.4 MB; at 5 rounds a second 17 MB/s: a native copy (10+ GB/s) spends 0.2% of a
  core on it, a browser's structured clone (~1 GB/s) 2%. The weights the other way, ~1 MB per worker per round. So
  MOVING DATA IS NOT THE COST. What would cost is synchronising per STEP - workers stepping physics but asking the main
  thread for actions 60 times a second, each a round trip.
  THE DESIGN - ACTORS THAT OWN A ROUND: each worker owns its characters (a sub-fleet, each character its own world),
  copies of the policy's, the flow's and the synergies' weights, and every character's acting state (its exploration
  noise, its pending examples, its plan); given ONE message per round - the newest weights, the plans' mailbox, who
  plans - it acts its characters for the whole round on its own, and answers with ONE message: the round's records,
  examples, hazards and counts. Buffers MOVE rather than copy: a transferable ArrayBuffer on the web, a pointer handed
  over on native - the sender gives it up in both, so neither shares mutable memory and neither copies. Same code, same
  semantics, both platforms: native shared-memory threading would save nothing measurable and lose the identity.
  DETERMINISTIC BY CONSTRUCTION: every character's random streams seeded by its global index, so a run is the same
  number for number with one worker or eight - checkable, and a resumed run is the run. AND OVERLAP: the workers act
  round r+1 with round r's weights while the GPU trains on round r - one round of policy lag, which an off-policy
  learner from a replay does not mind; the planner already decides at most once per round. The judge and the probe
  become a worker's job too - judging no longer pauses training (BLIND SPOTS 4). On the web the policy acts on the
  CPU in the workers (a small network) and the training stays on WebGPU.
   6c-a DONE Oct 30: `HostPolicy(M)` - the policy as the CPU acts with it: the mirrored policy, flow and synergy
      weights, a copy of the flow's value (shapes and offsets, nothing of the pipe), the inference's scratch rows, and
      `policyRow`, `correctedRow`, `addCorrection` moved unchanged but for finding the flow in it. The learner holds
      one (`Resident.host`) and every use goes through it; the trainer's too. The one dependency a worker could not
      have - the GPU's kit - is gone from choosing an action. Checked: every learner suite to the bit (host acting
      against the kit, a flow at rest against the policy alone, resume, planning, the teachers), the trainer.
   6c-b DONE Oct 30: a step's records BUILT apart from their UPLOAD - `Resident.buildStepRecords`, static, nothing of
      the device (the fleet, the step, the clips' first rows, scratch, the output), and `uploadStep`, the device's
      side (the no-gaps check, the bookkeeping, the upload); `appendLatest` the two in sequence. Checked: the kit's and
      the learner's suites to the bit, the trainer.
      DESIGN FOR 6c-c, found reading the acting loop: three things in it reach the GPU's side - `refreshMailbox` (a
      host copy of the newest readback, the same within a frame, since readbacks land between frames: once per round
      is the same), `appendLatest` (now split), and `planDecision`, the planner's GPU work, dispatched in the MIDDLE of
      a round when the flags call for it. A worker's round cannot dispatch, so a decision moves to the round's END -
      and that is better, not only possible: its work is submitted with the frame wherever in the round it is called,
      so its plans arrive next frame either way, and deciding at the end plans from the freshest states instead of
      ones up to a round old. The flags' bookkeeping moves with it: the warm start's shift (steps since the last
      decision), the stamp, the ages - counted to the round's end.
   6c-c DONE Oct 30: DECISIONS AT THE ROUND'S END - the flags already deferred a decision the caller did not allow
      (pending, its clock counting, the true plan age reported); `act` now allows one only at a round's LAST step, so
      a decision due earlier waits and is made from the freshest states, stamped with that step - and "at most once
      per round" holds by construction (the separate flag that tracked it is gone). Checked: every learner check
      passes as before; a pushed character acting in rounds of twelve steps - its hazard crossing the start partway
      through a round - is decided at the round's last step, the mailbox stamped with it. The tutorial's "decisions
      at the round's end", with a sketch. A worker's round now never needs the device in its middle.
   6c AC1 THE ACTOR (rest): everything that acts one character - its fleet slot, the mirrors, its noise, pending examples
      and plan - gathered into an `Actor` that runs a round on its own sub-fleet from a round's input to a round's
      output; first on the main thread. Check: the learner's runs the same as before, to the bit.
   6d AC2 PERSISTENT WORKERS: a worker kept alive with its state (the web: a Worker over its own wasm instance; native:
      a thread), round messages whose buffers are moved; inline where workers cannot exist (a sandboxed iframe), as
      jobs.zig does. Check: one worker's round equals the inline round, to the bit.
   6e AC3 MANY WORKERS: the fleet partitioned into sub-fleets, every character's streams seeded by its global index.
      Check: one worker and four give the same records, number for number; resume.
   6f AC4 OVERLAP AND THE JUDGE APART: workers act the next round while the GPU trains; the judge and the probe on a
      worker of their own. Check: rounds per second on lavapipe, one worker against four; the run's numbers sane.
   7 RJ1 the matching index: every frame's pose features, the nearest frame for a pose. Check: a frame finds itself; a
     perturbed pose its nearest.
   8 RJ2 the rejoin: a character that lost its reference has it re-synchronised to the matched frame, played forward,
     matched again while far; the replay records the new reference rows, so the world model and the policy see it.
   9 RJ3 living on: no termination at a loss - the episode lives until rejoined or a time limit; the failure counted
     as before, the recovery counted apart.
  10 RJ4 resets into trouble: a share of restarts from fallen states taken from the replay, or with a big push at once.
  11 RJ5 the rejoin probe: pushes of 1 - 5 m/s on dancing characters; fell, got up, rejoined, and how long each took.
  11b SM3 future goals (moved here), the matched reference feeding them.
  12 - 14 VISIBILITY: the device's numbers' rest, the host's numbers (with rejoins: recovering share, time to rejoin),
     the log's columns.
  15 REVIEW of turns 1 - 14, and the tutorials for all of it.
  16 N4 safeguards and the device's limits.
  17 N5 the run files: REPRODUCE (SuperMimic's recipe on the minute, time-locked, ending at a loss) and IMPROVE (the
     same with rejoining, living on, resets into trouble, big ramped pushes - and the flow, planner and FPO).
  18 - 19 N6 the smokes, on lavapipe, each exact file.
  20 N7 the policy file.  21 N8 review and N9 the night's tutorial.  22 N10 the handover and the gate.
  23 READ THE NIGHT.  24 - 26 its fixes.  27 THE EXTRAS' VERDICT: do flow, planner and FPO find new ways up?
  28 the second night's files, smoked.  29 review and tutorials.  30 the gate.

## SUPERMIMIC - studied Oct 30, and the next thirty turns

(Simon uploaded Liao, Shao, Long, Zakka, Horowitz, Abbeel, Sreenath, "SuperMimic: Scaling Humanoid Whole-Body Control
with One Differentiable World Model", CoRL 2026, arXiv 2610.28480: "Study deeply this work. Find the best way to
integrate some of these ideas in our system. What is the real breakthrough here. Make a detailed plan for the next 30
turns so we can end up with the best possible system".)

WHAT IT IS - SuperTrack, scaled, with SHAC's critic. One deterministic MLP world model (3 x 2048), fit on k = 8 step
autoregressive replay windows (state, reward, observation and termination heads; any head may be analytic), on data
the current policy collects with action noise N(0, 0.1^2) - transitions from old policies stay valid, the dynamics do
not depend on who acted. The deterministic policy is trained by BPTT through the FROZEN model over H = 32 imagined
steps, each rollout seeded from a replay state (Dyna), the objective

    J = sum_{t<H} gamma^t c_t r_{t+1} + gamma^H c_H V(s_H)        c_{t+1} = c_t (1 - d_{t+1}), d the predicted
                                                                    termination probability - a SOFT survival weight
with the BeyondMimic tracking reward (exp kernels on body positions, orientations, velocities, root; bounded per
step), gamma 0.99. The critic V (256, 128) is fit on the IMAGINED transitions to GAE(0.95) targets computed backward
from V(s_H), fixed while fit, 5 epochs x 4 minibatches, no target network. Policy: Adam beta (0.9, 0.95), gradient
clipped to global norm 1.0 THEN element-wise to 0.1; cosine decay of the rates. Resets are a CURRICULUM: the motion
timeline in 1 s bins, each with a running return estimate; 50% of resets uniform, 40% softmax(-25 G_b / G_max) -
the hard bins - and 10% by past weights, so a learned hard motion keeps some practice. The policy reads K = 10 future
reference frames (through an encoder to a 32-d latent) and its last 10 observations. No pushes in training (a
deterministic model cannot predict a discontinuity) - yet, with the critic, pushes of 0.5 - 4 m/s are recovered from
in 0.5 - 2.4 s, and without it never.
RESULTS: 3 h on one H100 beats SONIC (128 L40 GPUs, 7 days: > 1000x fewer GPU-hours); 25 failures of 129,514
motions, 0 after 9.8 h on two GPUs (SONIC: 179 - all its flips and side rolls); the model's 8-step error flat from
1 h to 264 h of motion; its rollouts 10 - 62x faster than MuJoCo Warp; BPTT reaches PPO-on-the-model's best with 64x
fewer imagined steps; horizon ablation: without a critic H <= 16 fails; with one, H = 8 never reaches the target, H = 16
matches critic-free H = 32, H = 32 is fastest, H = 128 slower and worse. Their hardest groups were exactly ours:
lying, resting and standing up; side rolls; flips.

THE REAL BREAKTHROUGH. Not a new component - SuperTrack (2021), SHAC's critic, Dyna's seeding and BeyondMimic's reward
all existed. It is the evidence that the combination SCALES: one world model amortises the dynamics every motion
shares, so adding motions adds evidence, not cost (its error does not grow with data); and three ingredients turn
SuperTrack's analytic gradient from an animation technique into the most efficient way to train a general tracker:
(1) a critic past a short horizon, which is what makes H = 32 work and what produces recovery after pushes; (2) a
differentiable SURVIVAL weight, so staying alive is worth all the future reward, not a penalty near a threshold;
(3) a curriculum over where episodes start, so hard stretches get the practice. For us it settles a question: our core
- SuperTrack with a critic tail - is the right core, and the gains come from getting its fundamentals right, not from
more machinery. SuperMimic reached ZERO failures with no planner, no flow and no PPO. Our flow, planner and FPO aim at
something it did not test - imaginative ways back from big perturbations - so they must prove themselves against a
baseline that has the fundamentals, not against plain SuperTrack.

WHERE WE STAND, checked in the code:
  - our policy imagines `window` = 8 steps, the world model's own window (one `steps` in the kit for both) - the
    horizon SuperMimic's ablation shows never reaching its target even with a critic. THE LARGEST GAP.
  - the policy's Adam has no gradient clipping (the critic's does); BPTT over 32 steps needs it.
  - every restart starts at a uniformly random frame - no curriculum; the get-up's hard stretches get no extra practice.
  - the policy reads one goal frame ahead; SuperMimic reads ten.
  - our objective is SuperTrack's: squared distances to the goals, a barrier near the failure rule, the action's price
    and smoothness, and the critic's cost tail - costs, not rewards; a soft survival weight needs positive bounded
    rewards (with costs, dying would pay).
  - our critic learns from recorded windows (real costs, pessimistic heads) - grounded in the simulator, and FPO's
    advantages need exactly that; SuperMimic's learns from imagined rollouts (the current policy's value in the model).
  - characters: the trainer's default 4; our physics runs on the CPU, so data is our scarce resource, not model
    updates - Dyna's lesson (imagine more per real step) fits us better than it fits them.

DECISIONS:
  ADOPT, before the first night: the policy's horizon separate from the world model's window, H = 32 (the world model
  keeps k = 8); the policy's gradient clipped (global norm, then element-wise) and its Adam's beta2 0.95; a reset
  curriculum by recent failure per second of clip; K future goal frames in the policy's input.
  ADOPT AS A SWITCH, compared on the second night: SuperMimic's objective - bounded tracking rewards with a soft survival
  weight from an analytic termination (the failure rule's margins through a sigmoid) - beside SuperTrack's costs.
  KEEP: our critic on recorded windows (grounded; FPO needs it), its multi-head pessimism, and the pushes (segmented in
  the replay, so the model never predicts across one) - the user's night has significant perturbations.
  NOT FOR US: the sim context xi and sensor noise (no domain randomisation, no robot yet); goal encoders and a shared
  decoder (one interface); a GPU simulator.

THE NEXT THIRTY TURNS (each: what, where, the check). The first night starts after turn 19; turns 20 - 30 read it and
build the second.
  VISIBILITY - so that every change after it can be seen working
   1 N3a-ii rest: the barrier's and the tail's parts of the policy's loss; the critic's error, mean value and heads'
     spread. Check: each against the host's arithmetic.
   2 N3b: the host's numbers per round - each clip's steps and failures, pushes and their mean speed, the flagged share
     and mean hazard, decisions and the planned share, examples held, the trust, non-finite counts, time acting /
     training / judging. Check: against the fleet's and the learner's own counters.
   3 N3c: the log's named columns, the status, the console line. Check: a short lavapipe run fills every column, finite.
  THE FUNDAMENTALS - SuperMimic's proven ingredients, in order of expected effect
   4 SM1 THE HORIZON: the policy's rollout in a kit of its own length (`policy_window`, default 32), sharing the world
     model's weights and the gathered windows' starts; the world model keeps its k = 8. Check: a 32-step policy kit's
     first 8 steps equal the 8-step kit's, number for number; the tail at step 32.
   5 SM2 THE POLICY'S OPTIMISER: its gradient clipped to a global norm, then element-wise (one kernel each, beside the
     critic's), Adam beta2 0.95, rates on a cosine decay to a floor. Check: clipping against the host's arithmetic;
     a huge planted gradient moves the weights by at most the element-wise bound times the rate.
   6 SM3 THE RESET CURRICULUM: each clip's timeline in 1 s bins, each with a running failure rate from the
     characters' own episodes; restarts 50% uniform, 40% by softmax over the hard bins, 10% by past weights;
     per clip, so each clip's characters stay its own. Check: on planted failure rates the draws follow the mixture;
     the bins' weights in the log.
   7 SM4 FUTURE GOALS: the policy reads the goals at chosen frames ahead (default +1, +3, +6, +10 at 60 Hz), the kit's
     lead block widened; the critic too. Check: the gathered rows hold the right reference frames, the clip's last row
     held past its end.
   8 SM5a THE SURVIVAL OBJECTIVE, kit: an analytic soft termination from the failure rule's margins (head height,
     root distance) through a sigmoid; bounded tracking rewards (exp kernels on our features' position and velocity
     errors); the survival weight's product through the rollout - forward and backward. Check: gradient against
     autodiff of the same objective in zimrrl.
   9 SM5b THE SURVIVAL OBJECTIVE, learner: the critic's targets in the same currency (rewards, survival); the switch
     `objective = .supertrack_cost | .survival_reward`. Check: with the switch off, everything to the bit as before.
  10 SM6 REVIEW of turns 4 - 9 for correctness and understanding; the tutorial's chapters gain the horizon, the
     curriculum, the future goals and the survival objective - the system as it now is.
  THE NIGHT
  11 N4 SAFEGUARDS: checkpoints of the state every 30 minutes (the last few kept); the non-finite watchdog naming what
     went first; the collapse alarm; the device's limits against every buffer at start. Check: planted failures.
  12 N5 THE RUN FILES: the BASELINE - SuperTrack with every fundamental (H 32, clipping, curriculum, future goals,
     critic tail) on dance + get-up with ramped pushes; the COMPLETE - the same plus flow, planner, FPO; every number
     with its reason. Check: both read, `GenoRun.problem` null.
  13 N6a SMOKE, baseline, on lavapipe, its exact file, 10 minutes: every column, the judge and probe per clip, a
     checkpoint, stop and resume carrying on.
  14 N6b SMOKE, complete; fixes from both.
  15 N7 THE POLICY FILE: policy, flow, synergies, future-goal offsets - the lab plays what the night learned. Check:
     the file acts as the learner, bit for bit.
  16 N8 REVIEW of the night's path - for what a night could break.
  17 N9 THE TUTORIAL: running a night, reading its log and its alarms.
  18 N10 THE HANDOVER: the Windows build, the commands, what to watch in the first ten minutes, the first-hour rule
     (each clip's judged time to failure against the baseline's and the servo's), what to read in the morning.
  19 THE GATE: the full gate, the snapshot handed over.
  THE SECOND NIGHT - built on what the first shows
  20 READ THE NIGHT: Simon's logs, judged and probed per clip, against the decision table written in turn 18.
  21 - 23 THE FIXES the night asks for (kept free: a first night always asks for something).
  24 SM7 THE SURVIVAL OBJECTIVE ON: a run of each objective, short, compared on the same clips.
  25 SCALING: more clips (LAFAN1's push-and-stumble and other takes, on Geno), each clip's error and time to a target
     as the library grows - SuperMimic's sweep, ours.
  26 THE EXTRAS' VERDICT: flow, planner and FPO against the fundamentals' baseline, on the first two nights - kept,
     changed or dropped, by evidence.
  27 THE SECOND NIGHT'S FILES, smoked.
  28 REVIEW of everything since turn 19.
  29 THE TUTORIALS complete for the system as it is.
  30 THE GATE and the handover of the second night.

## THE FIRST NIGHT - prepared Oct 29

(Simon: "the goal is to increase the chance that the first night training, on the 20 seconds of dance and 20 seconds
of getup at the same time, with significant perturbations, will be a success ... with good diagnostics so we can have
visibility on everything that will happen during training".) SUPERSEDES S2a - G1 above: their substance is folded in
below, ordered by how much each lowers the risk of a lost night.

WHAT WAS FOUND, studying the night's path (`tools/geno_trainer.zig`, `robot_lab.GenoRun`):
  - A run's task names ONE motion (`GenoRunTask.motion`: dance or get-up), and "get-up" is the DANCE CLIP started
    from the floor; the trainer embeds the dance alone. The real get-up take is in the project -
    `assets/lafan1/fallAndGetUp2_subject2.bvh`, 18.0 s, falls, lying and getting up - but baked only as a 5 s window
    (`examples/getup_train/getup.zclip`) for the pages. The dance is 20.0 s.
  - The fleet and the learner already hold several clips (`Fleet.clip_of`; a reference table per clip, each clip's own
    last row in the gather and the plans). But an episode picks its clip at random each restart, so the harder clip -
    whose episodes end sooner - quietly gets less of the time.
  - The judge and the recovery probe run on ONE clip (`fleet.clips[0]`).
  - SuperTrack's log holds six columns: round, minutes, steps watched, failures, and the two update counts. Nothing
    of the world model's error, the policy's or the critic's numbers, the planner, the teachers, the pushes, or either
    clip on its own. A night that went wrong could not be told apart from one that went slowly.
  - THE TRAINER RUNS ON LAVAPIPE IN THE CONTAINER: SuperTrack's default run, headless, about 300 rounds in its first
    minute, with its state, policy, log, the judge and the recovery probe written (the servo alone survives no push at
    any speed, 0.5 to 2.0 m/s - the baseline). So the night's exact run can be smoked here through the real GPU path,
    where the bugs only a GPU shows (the planner's upload order was one) would otherwise first appear at night.

THE STEPS (each: what is built, where, and the check that says it works):

  N1a THE TWO CLIPS IN ONE RUN. `robot_clip_bake.zig` bakes the whole get-up take (18 s) for the trainer;
      `GenoRunTask.motion` gains `.dance_and_getup` (both clips; the trainer embeds both; the other motions as they
      were); the fleet's clip choice gains a fixed assignment - character i on clip i mod 2, every restart on its own
      clip - so each clip gets half the characters and the same time. Check: on the CPU twin, a learner on both clips
      - every character keeps its clip across restarts, every record reads its own clip's rows, every gathered window
      stays inside one clip.
      DONE Oct 29: FOUND - the trainer's dance and the pages' get-up are clips of DIFFERENT robots (99 position
      numbers per frame, Geno; 48, the get-up pages' humanoid), so the get-up had to be copied onto Geno, not cut:
      `robot_geno`'s clip test now bakes per capture - the dance's two cuts, and LAFAN1's whole fall and get-up take,
      1,080 frames, 18.0 s on Geno (`examples/geno_ppo/getup.zclip`), the dance clips byte-for-byte unchanged; the
      trainer embeds it (`geno_getup_zclip`); `PpoMotion.dance_and_getup` (any learner but SuperTrack refused by name
      in `GenoRun.problem`); `robot_track.ClipAssignment` (random, or by_character: character i on clip i mod the
      clips); the trainer's SuperTrack fleet from the run's clips, by character when two, and the features' normaliser
      measured over every clip. Checked: on the CPU twin, after 300 exploring steps with restarts, every step the
      replay holds is on its character's clip and every staged record's table row inside its clip's rows; the
      refusal; AND THROUGH THE REAL GPU PATH - the trainer on lavapipe, `dance_and_getup`, 639 rounds in 1.8 minutes,
      a clean finish, every file written. The tutorial's fleet section explains several clips and the assignment.
  N1b JUDGED AND PROBED PER CLIP. The judge's starts and the recovery probe for each clip; `judge.csv` and
      `recovery.csv` gain a `clip` column; `status.zon` and the console line give each clip's recent time to failure.
      Check: a two-clip run writes a line per clip for the servo and for the policy.
      N1b-i DONE Oct 29: `judge.csv` and `recovery.csv` gain a `clip` column (the clip's label; `JudgeLog.Line.clip`
      read back); SuperTrack's judge loops over the run's clips - each its starts, its servo line and probe the first
      time, its policy line and probe, its console line; PPO's path names its motion. Checked through the real GPU
      path: a two-clip run on lavapipe, servo and policy lines for the dance and the get-up in both files, a clean
      finish - after the policy probe's crash was found and fixed (BLIND SPOTS 1).
      FOUND, for N1b-ii: on the get-up the SERVO "survives" 3 of 11 pushes (none on the dance) - pushes landing while
      the reference lies on the floor, where a body already down cannot fall. The probe's question - does it come
      back when pushed - asks about balance, so on any clip it must push only at frames where the reference stands
      (its head at standing height); otherwise the get-up's probe lines measure lying still.
  N1b-ii DONE Oct 30: the learner counts each clip's exploring steps and failures (`exposure_by_clip`,
      `failures_by_clip`), a step charged to the clip its episode ended on when it just ended (`terminal_clip`) and
      otherwise the one it is on - right for random assignment too; the trainer keeps each clip's recent rounds,
      `status.zon` a `clips` list (`lab.ClipStatus`), the console line each clip's time ("(dance 0.74 s, get-up
      1.59 s)"); the recovery probe pushes only where the reference STANDS (`RecoveryProbe.standing_share`, 0.8 of the
      clip's highest head, `referenceHeadHeights`). Checked through the real GPU path: a two-clip run on lavapipe - the
      console and the status per clip, both clips judged, a clean finish; the get-up's servo now survives NO push (was
      3 of 11, all while the reference lay down).
      FOUND: with pushes only where the reference stands, the get-up keeps 2 probe starts per band (the take is mostly
      falling, lying and rising, and a push needs a second's settle before it and three seconds' watch after) - too
      few to say much. For N5: denser probe starts on the get-up (every quarter second gives about four times as many),
      or accept that the get-up's recovery is read from its judged time to failure and the planning numbers instead.
  N2  DONE Oct 30: `Pushes.ramp_steps` - the range's top rising from `speed_min` to `speed_max` over the fleet's
      steps, in a straight line (`Fleet.pushRampShare`); with no ramp the share is exactly 1, the same draws number
      for number. The fleet counts its steps (`stepped`) and the pushes it gives with their speeds (`pushes_given`,
      `push_speed_sum`) for the log. FOUND, a resume blind spot under it: the learner's steps (`acting_steps`) were
      NOT in the state file - a resumed run restarted every hashed noise stream (the flow's, FPO's draws, the
      planner's) and would have restarted the ramp, the pushes gentle again mid-night; the flow's resume test never
      continued training, so it never saw it. Now saved and restored (state layout `ZSTSTAT5`), the fleet's clock set
      from it. Checked: on a fleet pushed every third step, every push inside the range the ramp has opened, the share
      exactly half at mid-ramp, speeds after the ramp no push could reach before; a resumed learner carries the saved
      run's steps and its fleet's clock. The tutorial's pushes paragraph gains the ramp. The run setting is in steps
      (reproducible on any machine); N5 turns "the first hour" into steps from the measured speed.
  REVIEWED Oct 30 (Simon: "Review. Make the code and tutorial perfect"): comments state what and why, never the
      story behind them - the probe's comment no longer quotes a test's numbers, the trainer's build gives the reason
      for its safety checks rather than the crash that showed it, "the night" is "a run" or "a two-clip run", and the
      recipe's and checker's plan labels (A1, A2, P5, T1) are gone; `PpoMotion` is `GenoMotion` - it names the motions
      of every learner's run, one of them refused to PPO; the judge chooses its controller once; the trainer refuses
      more clips than its progress keeps; the per-clip counters say they are not saved and why. The tutorial's probe
      section gains the standing rule with a height profile, and per-clip judging - the `clip` column, the status's
      list, the console line. LEFT FOR A PASS OF ITS OWN: older plan labels in `robot_geno.zig`'s experiments (S2b,
      S2c, T3, ON, the D phase).
  N2  (as planned) PUSHES THAT GROW. `robot_track.Pushes` gains a ramp: each push's speed drawn from a range that widens from its
      easy end to the full range over `ramp_rounds` - characters learn to track before they are knocked hard. The
      night: random pushes (`rate_per_second`) from 0.5 m/s, the range reaching 0.5 - 2.0 m/s over the first hour.
      Check: the pushes' drawn speeds stay inside the ramped range at each round, and reach the full range after it.
  N3a IN THREE PIECES (Oct 30): i the mechanism and the flow's teachers; ii the world model, the policy and the
      critic; iii the planner.
  N3a-i DONE Oct 30: `robot_latent_kit.DeviceStats` - an extern struct of named numbers, one definition for both
      sides (`slot` a field's place, `floats` the block's size); every learner reserves the block after everything
      else the readback reaches (`Resident.stats_at`), the kit writes it (`LatentKit.stats_at`, `recordStat` - a
      one-thread kernel per number, nothing without a block), the host copies it with every round's readback
      (`refreshDeviceStats`, beside the mirror's sync and whether or not the mirror took its weights). Kernels:
      `stat_root_mean_square`, `stat_mean_square_difference`, `stat_mean_and_deviation`, `fpo_ratio_stats` (the
      clip's choice as `fpo_velocity_gradient` makes it). The flow's teachers' numbers: FlowDPG's velocity gradient's
      root mean square, the distillation's loss, FPO's old losses' and raw advantages' mean and deviation at the
      round start, the ratios' mean and the share the clip holds after each update. `LatentKit.stats_at` is a SHARED
      offset (`placedAt`). Checked: each kernel on planted values against the host's arithmetic (three FPO examples
      below, inside and above the clip, one held); in the learner, every teacher-1 and teacher-3 number against the
      host's arithmetic on the round's own buffers and the learner's copy the block; teacher 2's loss positive,
      finite and copied; lavapipe compiles the kernels. NOTE: on the CPU twin `readLatest` returns each buffer only
      up to the readback window - a test cannot read the activations past it. The tutorial's mailbox passage gains
      the block, with what each number says.
  N3a-ii FIRST HALF DONE Oct 30: the world model's training loss (`DeviceStats.world_model_loss`,
      `LatentKit.recordWorldModelLoss`, called by `trainStep`) and the policy's tracking term (`policy_tracking_loss`,
      after `policyBackward`: the rollout's states against the goals). AND ONE DEFINITION EACH IN THE KERNELS: the
      page's `mse_value` and the log's `stat_mean_square_difference` were the same sum - now both call
      `meanSquaredDifference`; the normalisation and the mean-and-deviation statistic call `meanOf` and
      `sampleDeviationOf`; FPO's update and its ratio statistic decide the clip with one `isClipHolding` (no longer a
      copy kept in step by a test). Checked: the world model's statistic EQUALS the page's loss at every step of the
      world model's test; the policy's term equals the host's arithmetic on the rollout's buffers; every kit, learner
      and kernel suite unchanged; lavapipe compiles. The tutorial's table gains both numbers.
  N3a-ii NEXT: the barrier's and the tail's parts of the policy's loss, the critic's TD error, its heads' mean value
      and their spread.
  N3a THE DEVICE'S NUMBERS (the stats block - S2a's mailbox idea). After the plan mailbox in the parameter buffer, so
      the readback the learner makes every frame carries it: per round, written by small kernels -
          world model    its training loss (the last update's)
          policy         its loss's parts: tracking, barrier, tail
          critic         its TD loss, its heads' mean value and their mean spread
          teacher 1      FlowDPG's velocity-gradient size
          teacher 2      the distillation's flow matching loss
          teacher 3      the mean old loss (T65), the ratios' mean, the share clipped, the advantages' raw mean and
                         spread
          planner        the last decision's best score, the share of decisions won by a flow plan (T58)
      Check: each number against the host for planted values; the block inside the readback.
  N3b THE HOST'S NUMBERS. Per round, counted where they happen: each clip's steps and failures; pushes given and their
      mean speed; the share of characters flagged and the mean hazard; planning decisions and the share of steps
      acted from a plan; teacher 2's and teacher 3's examples held; the trust in the critic; non-finite actions and
      rejected mirrors; and time - milliseconds acting, recording and waiting per round, rounds per minute (the
      compute knob's accountant, K1, measuring only: its controller waits for a night that shows it is needed).
  N3c THE LOG AND THE STATUS. `lab.SuperTrackLog` holds every number of N3a and N3b, one named column each, one line
      per round; `status.zon` holds the newest of the ones a person checks first, and the console line per minute a
      compact few. Check: a run of a few rounds fills every column, finite.
  N4  SAFEGUARDS. The learner's state kept as a checkpoint every `checkpoint_minutes` (`supertrack_state_m<N>`, the
      last few kept); a NON-FINITE WATCHDOG - a non-finite weight or number in the stats stops the run with status
      `.failed_nonfinite`, naming what went first, the last good checkpoint intact; a COLLAPSE ALARM in the status -
      the judged time to failure under the servo's for three judgements in a row. Check: a planted non-finite number
      stops the run as said; a restart from a checkpoint carries on.
  N5  THE NIGHT'S RUN FILES. `runs/night1/run.zon`, every number chosen and said why: SuperTrack on
      `.dance_and_getup`; the critic and its tail (0.5, pessimism 0.5, trust over 1000 updates); the barrier; the
      flow (K 5, its noise half of sigma) and its teachers (distillation 0.5 x 32; FPO 32 rows, 4 draws, 0.1, clip
      0.2, from a hazard of 0.5); planning (2 slots, 16 candidates, horizon 4, 2 rounds, 4 elites, 2 flow plans; start
      0.5, stop 0.25, 10 calm steps, a decision every 4, lookahead 10); the pushes of N2; save every 5 minutes,
      checkpoint every 30, judge every 15, stop after 8 hours. And `runs/night1_baseline/run.zon`: plain SuperTrack on
      the same task and pushes - what the night is measured against. Check: both files are read without a problem
      (`GenoRun.problem`).
  N6  THE SMOKE, ON LAVAPIPE. The night's run here, through the real GPU path, for about ten minutes: every column
      moving and finite, the judge and the probe per clip, a checkpoint written, the run stopped (`stop`) and started
      again carrying on; the baseline likewise. Fix what it shows - this is where the night's surprises should happen.
      Two turns.
  N7  THE POLICY FILE FOR THE CORRECTED POLICY (P5). The `policy` file the trainer writes holds the policy, its flow and
      its synergies, so the lab plays - and judges - what the night learned, not the policy without its correction.
      Check: the file plays as the learner acts, bit for bit.
  N8  REVIEW of the night's path: the trainer's integration, the log, the safeguards - for understanding, and for what
      a night could break.
  N9  THE TUTORIAL: running a night - the run file, the log's columns and what each says, the alarms, the files a run
      leaves, stopping and resuming.
  N10 THE HANDOVER: the Windows build (`zig build geno-trainer` installs it beside the Windows programs); the commands;
      what to look at in the first ten minutes (the console line: rounds per minute, each clip's time to failure,
      nothing non-finite); what to read in the morning (each clip's judgement against the servo, the probe's bands,
      the teachers' sizes, the planned share) - one page.

BLIND SPOTS - reviewed Oct 29 (Simon: "Review deeply again. Focus on our blind spots"), after the smoke found a crash:
  1 CODE NOTHING HAD RUN. The first two-clip smoke died at its first judgement: the recovery probe of a POLICY (not
    the servo's) built its actor for every judge start (19 on the dance) while the probe keeps only the starts with
    room for a push and watch (16) - the actor read and copied past the probe fleet's arrays. An old bug: no test and
    no run had ever probed a policy whose clip had starts too near its end. FIXED: the policy's judge actor acts on
    the fleet it is given, never more (refused by name if larger), its copy the fleet's share; a test probes a policy
    where some starts have no room. AND THE GENERAL LESSON: the trainer's SuperTrack runs have only ever used its
    defaults - 4 characters, a 256-step replay, no critic, no flow, no planning, no pushes, one clip. The night turns
    every one of them on. So N6's smoke must run the EXACT night configuration, long enough for the teachers' rings
    to wrap, a checkpoint to be written and three judgements to happen - not a shortened stand-in.
  2 AN UNCHECKED BUILD HID IT. In ReleaseFast the overrun did not crash where it happened: it corrupted memory and
    the run died minutes later elsewhere, with no message (exit 139) - or could have trained on corruption all night.
    DECIDED: the trainer is built ReleaseSafe for now (`build.zig`, the reason at `optimize`); its cost is the CPU's
    physics, the GPU's work unchanged - N6 measures it.
  3 THE DEVICE'S LIMITS. Lavapipe's limits are generous; a real GPU's storage binding is typically 128 MB. At the
    night's sizes the replay alone may approach it (16 characters x 4,096 steps x ~330 numbers per record ~ 86 MB).
    ADDED TO N4: at start the trainer prints every buffer's size against the device's limits and refuses by name
    when one does not fit - not a mystery at night.
  4 JUDGING PAUSES TRAINING, and two clips double it: on this container a judgement of both clips takes minutes.
    ADDED TO N3b: the seconds each judgement and probe take, logged; N5 chooses the judge's interval from them.
  5 NOTHING HAS EVER SHOWN THAT THE WHOLE SYSTEM LEARNS. Every piece is checked against a reference - FPO against
    autodiff of zimrrl's loss, the planner against the CPU model - but a mistake shared by a piece and its reference,
    or a combination of right pieces that does not learn, passes every check. ADDED TO N10: the night starts with the
    baseline beside it, and the handover gives a FIRST-HOUR rule written in advance - each clip's judged time to
    failure against the baseline's and the servo's - so a run that is not learning is seen in an hour, not a night.
  6 THE NIGHT RUNS ON WINDOWS, built here for Linux only so far. CHECKED: the Windows trainer cross-compiles
    (`zig build geno-trainer-windows`, `zig-out/windows/geno_trainer.exe`, 4.9 MB). N6 builds it again at the end.
  Checked as safe: numbers that grow over a night - the planner's stamp is an integer bit-cast into its slot (exact
  to four billion steps), counters are 64-bit, clip rows as floats far under 2^24.

LATER NIGHTS (recorded, not scheduled): the compute knob's controller (K1); the lab's view of the new columns (D2);
synergies fitted from recorded corrections (T61); the push-and-stumble take (`pushAndStumble1_subject5`, 4.7 s) as
a third clip - a reference for being pushed.
  Q1b-iii AS FIRST PLANNED: the learner, every round with a batch and a critic: the advantage reserved where the learner is
      built; before the round's policy updates, `fpoAdvantages` and the old losses - a flow trainer over rows x draws
      rows, each example's condition and coefficients broadcast to its draws, noise and times hashed from the round's
      own seed (kept for the round's updates: the same draws). Check: in the learner, after a round, the old losses
      equal a recomputation at the round's starting weights.
  Q1a AS FIRST PLANNED - TEACHER 3's DATA. For every collected step of a flagged or aftermath character: its condition, coefficients,
      noise and the flow matching loss at collection (FPO's "old" likelihood), and its cost, in a host ring like the
      distillation examples; a batch per round; the advantage on the device from the critic, one step:
      A = -c - gamma C(s') + C(s). Checks: the stored old losses equal a recomputation at the same weights; the
      advantage against the host for planted critic values.
  Q1b TEACHER 3's UPDATE. FPO: the ratio exp(old loss - new loss) per sample (a few (t, noise) draws each), PPO's
      clipped surrogate, its gradient added at its weight. Checks: the ratio is exactly 1 at the old weights; a planted
      positive advantage lowers its action's flow matching loss (raises its likelihood), a negative one raises it.
  Q2  THE THREE TEACHERS TOGETHER. Weights and warm-up ramps for FlowDPG, distillation and FPO; pessimism ramped with
      the tail's weight (T49); each teacher's gradient norm into the stats. Check: any teacher at weight 0 leaves the
      others' update the same to the bit (the pattern of P4b).
  S2a THE STATS MAILBOX. A block after the plan mailbox: the critic's mean and its heads' disagreement on the policy's
      windows, the tail's size, each teacher's loss and gradient norm, the planned share of steps, the world model's
      error on steps after a loss (T44); SuperTrack's log gains a column for each. Checks: a planted number makes the
      round trip into the log; every column filled after a round.
  K1  THE COMPUTE KNOB. The cost model in multiply-adds from the shapes; the accountant per round; a slow controller
      over the planner's budget (slots, rounds) and the push rate, toward `recovery_share`; the measured share
      logged. Check: with costs planted, the controller settles the share at the knob within a set number of rounds.
  S2b THE COMPLETE RUN. One lab preset, every ingredient at a small budget: synergies 8, flow K 5, planning 2 slots x
      16 candidates x 4 steps x 2 rounds, distillation 0.5 x 32, FPO small, the critic with its pessimistic tail,
      the barrier, pushes with their aftermath, the knob at 0.3. The night trainer's path for it; the state file
      complete (the distillation and FPO rings saved; planning restarts cold, said so). Check: a run with everything
      on resumes with the same weights, moments and rings.
  S2c THE SMOKE RUN. Twenty rounds on the CPU twin with everything on: no non-finite number anywhere, every counter
      and every log column moving; the Windows build compiles. Fix what it shows.
  P5  THE POLICY FILE FOR THE RESIDUAL FLOW. A policy-file kind holding the MLP, the flow and the basis, so the lab
      can play and judge a complete run from its file, and a page can ship it. Check: the file plays as the learner
      acts, bit for bit (the pattern of the Gaussian file's check).
  R1  REVIEW: the residual flow, the synergies, acting and planning in coefficient space - names, comments that
      carry the reasoning, dead code; the new kernels in lavapipe's comparison with the CPU twin.
  R2  REVIEW: the teachers, the knob, the stats, the complete run.
  D1  THE TUTORIALS. zimrrl: synergies, residual flows, FPO, with diagrams and worked numbers. robot-mocap: the
      complete system - one world model, one critic, one cost, the MLP and its residual flow, three teachers, the
      planner, the knob - and the path of one recovery through all of it.
  S3  THE NIGHT'S PROTOCOL. The runs, each at the small budgets: today's SuperTrack; the complete system; the complete
      system without each teacher; without synergies (a full-width residual); without planning. Seeds, the time each
      gets, the Windows script, and what the morning reads first.
  D2  THE NIGHT'S READING. The lab's view of the new columns: the probe's bands and half-survival speed, the planned
      share, each teacher's size, the knob's share, and the judge's two numbers (T55: typical, committed).
  G1  THE GATE AND THE HANDOVER. One full `zig build gate`; everything it shows fixed; the snapshot for the night;
      a one-page checklist of what to start and what to read.

### Kept for later nights (recorded, not scheduled)

  - A LEARNED CONDITIONAL DECODER D(goal, state, z) -> action in place of the fixed basis (ControlVAE, PULSE), trained
    on tracking, planned and recovery actions; Polyak-slow or frozen after a warm-up, so the flow's latent does not
    move under it. When the night shows the synergies too tight.
  - LATENTS THAT SPAN TIME: one latent decoding into a short move of several steps (action chunking) - a recovery step
    one choice, not four.
  - Euler steps by hazard (T60): eight for flagged characters, four for the rest, the same network.
  - Which plan won (T58) and the elites' agreement (T57) as weights on teacher 2's examples.
  - The hazard from the sampler's divergence (T51) and the critic's verdict on the flow's own plan (T56).


#### Phase D - The lab's views (3-5 turns)

**D1. Runs** (L11): a status mark (running, finished, stopped, failed, silent), the name, the learner, minutes, the
newest judgement with its error; sort by any column. **D2. Watch** (L13): the timeline of checkpoints by minute,
the policy or (EfficientTDMPC) the planner. *Folded in (T4, T6, T10, T13, T17, T19):* for an EfficientTDMPC run, the
watch also plots the agent's signals along the shown episode under the character: its value, the two-hot widths,
the SimNorm entropy, the encoder's inverse spreads and the heads' disagreement, with a mark where the failure rule
fired. One view answers several brainstorm questions by looking: does the value see a fall coming before it happens
(T10, T6), which signal warns first and most cheaply (T13, T17, T19), and is lying valued below kneeling - the gravity
gate's slope as a get-up signal (T4). For a SuperTrack or PPO run, the same view through an EfficientTDMPC value
trained on the same task, once one exists. **D3. Compare** (L14): the ticked runs' judgements over minutes (and
steps), each point with its error bar beside the servo's line - error bars need a plot feature in `ui.zig`
(OPEN, Simon to decide); a table of every run judged at the same minutes (checkpoints aligned by
`checkpoint_minutes`); "duplicate with the next seed", and runs of one recipe drawn as their mean and spread.

**D4. The recovery probe** (added Oct 26, for phase G's question and the termination question alike): a judge mode
that pushes every character with impulses of graded size - bands from "a nudge" to "a shove that must take a step"
to "a fall" - at random phases of the dance, and records for each push whether the character came back (back within
the failure rule's limits and the tracking tolerance within N seconds, without the rule firing) and how long it took.
One table per learner: recovery rate and time to recover against push size. Every learner gets its numbers before
any of phase G is built, so G's question - does a flow policy come back better? - is answered by a number, not by
watching. *Known answers:* a push of zero is the plain judge; a push past what any policy survives fails every
character; the same seed pushes the same characters at the same times, so two learners meet the same pushes.

#### Phase E - The Windows night runs (1-2 turns)

**E1** (L15): one zip - `geno_lab.exe`, `geno_trainer.exe`, a `run.zon` per learner, a readme. The first night: a
PPO baseline, a SuperTrack run, an EfficientTDMPC run, each judged every 5 minutes; the morning: the lab's compare
view decides which recipe the next night tries.
*Folded in - the second night's candidates, chosen by what the first shows:* (T1) an EfficientTDMPC run with a long
aftermath (3 s, or endless) beside the default 1 s - a setting already, nothing to build; (T2) if SuperTrack's runs
fail mostly by falling, its failure rule as a soft barrier in its known loss (softplus of each margin past its
limit) - one term in its fused loss kernel and a setting, its own known answer and control; (T3) if SuperTrack's
policy loss is wasted on windows through falls, windows sampled to start before a loss. Each is one bench arm, judged
against the first night's run of the same learner.

#### Phase G - A flow actor: several ways back (proposed Oct 26, from FPO and FlowDPG)

THE QUESTION (Simon): would a flow matching policy - a policy that turns noise into an action through a learned
velocity field, as image generators turn noise into images - come back from large perturbations better? THE REASON TO
THINK SO: after a big push the reference cannot be followed for a while, and the ways back are several and distinct -
a step to the left or to the right, a hand down, a crouch, a turn. A Gaussian policy has one mode: where two ways back
are both good, its mean lies between them, and between a step left and a step right is no step. A flow policy can
hold both. THE EVIDENCE: FPO (McAllister et al., ICLR 2026) trains PHC humanoid motion tracking - our task's nearest
published neighbour - with PPO's machinery and a flow policy: with every joint of the reference given, it matches
Gaussian PPO; when the reference under-determines the action (only the root, or root and hands), it wins clearly
(root only: 54% success against 30%, per-joint error 74 mm against 124 mm). Recovery is that regime: while the body
is off the reference, the reference under-determines what to do. WHAT THE EVIDENCE DOES NOT SAY: nothing in either
paper measures pushes or falls, and recovery may be limited by other things - the value of fallen states (the
termination question, the aftermath), exploration, the failure rule - so D4 measures before G builds.

THE TWO METHODS, AND WHAT EACH OFFERS HERE:
- FPO (on-policy, PPO's family). The policy ratio PPO needs is a likelihood ratio, which a flow policy does not have
  in closed form; FPO replaces it by exp(L_old - L_new) of each action's own conditional flow matching loss, the same
  (flow time, noise) draws used on both sides - the flow matching loss being the negative of a lower bound on the
  log-likelihood, the ratio rises exactly when the action became more likely. Then PPO's clipped surrogate, unchanged.
  The sampler is free (FPO trains through the loss, not through the sampling chain). In the authors' code: 10 Euler
  steps; the time embedded by a few sines and cosines (MuJoCo) or an adaLN scale-and-shift (PHC); the PHC policy's
  executed action the flow's endpoint plus a Gaussian of sd 0.05, and its loss read as that Gaussian's log-likelihood
  (so the ratio exponentiates the loss difference / (2 x 0.05^2) - a temperature); one (time, noise) draw per action
  for PHC, eight for MuJoCo; the log ratio clipped to +-3 before the exponential; PPO's clip at 0.01 to 0.05, smaller
  than a Gaussian's. Fits our PPO learner as a drop-in: the GPU fleet already supplies the samples on-policy methods
  need.
- FlowDPG (Shi et al., CoRL 2026; off-policy, DDPG's family). Improves a flow policy with a critic's ACTION GRADIENT
  without back-propagating through the sampling chain: from a noisy action x_t one velocity evaluation gives the
  clean-action estimate a^ = x_t + (1 - t) v; the critic's gradient g at a^, rescaled to the local velocity's size
  (Delta = alpha |u_t| / |g| x g), gives a better action a* = a^ + Delta; the velocity is regressed toward a* - x_0,
  beside the plain flow matching target (weight lambda, warmed up), with a consistency term |a^ - x_1|^2 keeping a^
  honest. It is the deterministic policy gradient under three named approximations. What matters here: ANY learner that
  produces an action gradient can teach a flow actor this way - and two of ours do.

WHERE OUR LEARNERS ALREADY HAVE WHAT THESE NEED:
- PPO has advantages: FPO directly.
- EfficientTDMPC has a differentiable one-step Q: Q(z, a) = R(z, a) + gamma x mean over heads of V(f_i(z, a)) - the
  expression `KitValueTargets` already computes on the kit, its action gradient the action columns of the wide rows'
  input gradients the readers already gather. FlowDPG's critic, for free; and the planner can draw its policy-prior
  candidates from a flow (a multimodal prior for the search, where a Gaussian prior seeds one region).
- SuperTrack has its own pathwise gradient at every action of a window (its world-model backward computes it): as
  FlowDPG's g, it would teach a flow actor to track as SuperTrack tracks, while the flow keeps several ways back.
So the flow actor is where the three learners can meet: one actor, three teachers - the merge (R5) in its most concrete
form, each teacher's correction a vector added to the same flow target.

THE DEPLOYMENT QUESTION - COMMITMENT. A flow policy samples fresh noise at every decision. Two consecutive decisions
can then pick different ways back - step left, then step right - and DReCon's low-pass action filter would average
them: the Gaussian's failure again, through time. So the noise must persist: one noise per character, held while it
recovers and drifting slowly otherwise (an Ornstein-Uhlenbeck process in noise space), so a character commits to the
way back it began. The policy file gains a flow kind - the velocity network, the step count, the noise rule - and
the lab's player its sampler.

STEPS, each a building block with its known answer, in this order:
**G1. Flow policies in zimrrl** (CPU, one definition): `FlowPolicy(T)` on zimrnum's networks - the velocity on
[observation | noisy action | time embedding], one path convention (t = 0 noise, t = 1 action, as FlowDPG and
Lipman), the Euler sampler, each action's conditional flow matching loss over stored (time, noise) draws, FPO's ratio
and clipped surrogate, FlowDPG's target (a^, the adaptive shift, the consistency term, the anchor). *Known answers:*
the loss by hand; the ratio exactly 1 at the old parameters; the ratio's gradient the loss's, negated (FPO's eq. 19-20);
FlowDPG's gradient against its closed form (eq. 11) by central differences; the sampler exact on a constant field.
**G2. The flow actor on the kit**: one application of the velocity network per Euler step (wide rows [observation |
noisy action | embedding], as the rollout's), an Euler-step kernel, the loss, ratio and surrogate gradient in closed
form (one thread per row, as the distillation), FlowDPG's target kernel. *Known answers:* G1's numbers on the CPU twin,
then on lavapipe. On the way, `robot_gym`'s GPU PPO moves onto `KitNetwork` (the dedupe noted in C2c).
**G3. FPO on the dance** - the decisive experiment, the cheapest: the PPO learner with a flow actor, judged by D4's
recovery probe against Gaussian PPO, same pushes, same seeds. DECISION POINT: no recovery gain - G stops here, parked
with its numbers; a gain - G4 and G5.
**G4. EfficientTDMPC's flow prior**: FlowDPG with the one-step model Q as critic, the planner sampling its prior
candidates from the flow.
**G5. SuperTrack's flow actor, then one actor with three teachers**: SuperTrack's pathwise gradient as FlowDPG's g;
then the teachers' corrections weighted per state by the hazard signals (T6, T7, T13, T17, T19).

#### Phase F - The demo page (later)

A single HTML page that plays a policy file on Geno in the browser: the policy file embedded, the show
(`PolicyShow`) and the judge's numbers - the policy file's learner-neutral form makes this a page of its own, not a
learner's.

### 4. Open decisions (Simon)

- Error bars in `ui.plotCurves` - a general plot feature in `ui.zig` (D3).
- Whether the first night runs before phase C (EfficientTDMPC on the CPU, slower) or after.

### 5. The details of what was done

The entries below, Oct 24-25, record each step as it was built and checked; the plan above supersedes their "next"
lines.

## The lab: three learners on the GPU, one judge, an intuitive UI - prepared Oct 24 (Simon: "Improve the plan so we
## end up with an intutive ui in the lab for starting training runs and evaluating and comparing them on the dance
## tracking task. We want to be able to choose between different versions of rl algos, ppo, supertrack,
## efficienttdmpc, all on gpu.")

**Where it stands.** `geno_lab` (native) lists the run folders, shows a run's policy on Geno at any checkpoint
(`weightsNearest`), draws the runs' curves from their log.csv (RT5), and has a new-run form that writes run.zon and
starts `geno_trainer` as a child program, and stops a run by its `stop` file (built, not yet marked done as RT6) - for
PPO alone. The trainer runs PPO alone (`PpoRun`, `PpoRecipe`); its update is on the GPU (`kit_mlp`, natively on
Vulkan since Oct 17). SuperTrack trains on the GPU kit in its page (`geno_train`, `SuperTrackRecipe`), not in the
trainer. EfficientTDMPC is complete on the CPU (`Bmpc(T)`, the `efficientTdmpc` preset; N7a-N7f-2) and has no GPU
kit: `kit_mlp` lacks LayerNorm with Mish, SimNorm and the two-hot cross-entropy. Each learner judges itself its own
way (PPO's `evaluate` counts exposure and failures); nothing compares two learners on equal terms.

**The shape.** Everything the lab shows or compares is learner-neutral, so that adding a learner touches the trainer
and nothing in the lab:

      run.zon        the task (the clip's range, decimation, the action filter, the failure criteria - the same for
                     every learner and clip), the learner and its recipe (`.ppo`, `.supertrack`, `.efficient_tdmpc`,
                     each a struct of defaulted fields), the run's controls (hours, checkpoint minutes, judge minutes)
      policy         the policy the run would deploy, learner-neutral: the network (layers, activations, weights),
                     the observation normalisation, the action scale, the filter - for EfficientTDMPC its encoder and
                     policy head as one network; the lab and the web demo play any run's policy alike
      policy_m<N>    the same, checkpointed at minute N
      state          the learner's own state for resuming: every network, the optimisers, the running scales - not
                     the replay (Simon, Oct 24): a resumed run refills it
      log.csv        the learner's own columns, one line per update batch
      judge.csv      the judge's columns, the same for every learner: minutes, environment steps, its measures
      status.zon     running, finished, stopped or failed; minutes; the latest judge line
      stop           made by the lab (or by hand): the trainer saves and exits

**The judge** (one definition, used by the trainer every `judge_minutes` and by the lab on any checkpoint): the
dance played from fixed start frames across the clip, fixed seeds, the policy's mean action through the filter,
the same failure criteria, no pushes (Simon, Oct 24: pushes later). Its measures: the share of the clip tracked
before a fall, the mean time to failure, the mean body position error (cm) and the root's, falls per minute - and,
once R5.9's judge is built, its pushes and the body's limits. The x-axes the lab offers: minutes of training (speed, the main target) and environment steps (sample
efficiency).

**The path** - one short turn each, verified headless on lavapipe; Windows waits for Simon:

  Shared ground, PPO first (no change in what PPO learns):
  L1 THE RUN, LEARNER-NEUTRAL. `GenoRun`: the task, `learner: union(enum) { ppo, supertrack, efficient_tdmpc }` with
     each recipe, the controls; ZON read and written with every field defaulted; an older PPO run.zon (no `learner`)
     read as `.ppo`. KNOWN ANSWERS: defaults, a partial file, a misspelt field refused by name, the old file read,
     round trips for all three.
     L1 DONE (Oct 24). In `robot_geno.zig`, after `PpoRun`: `GenoRunTask` (the motion, `decimation`, `beta` - what
     the environment and the judge share; `GenoTask` was taken, the task built from them); `PpoLearner` (PpoRecipe's
     own fields, `recipe(task)` back to a `PpoRecipe`), `SuperTrackLearner` (SuperTrackRecipe's scalars and its
     world model's six settings - the `noise` hook is code no file carries, the world's normaliser buffers are
     state; `recipe(task)` back, the task's clock and filter in its options), `TdmpcLearner` (`TdmpcPreset`
     efficient_tdmpc or bmpc, the action scale, widths, dynamics heads, both horizons, pessimism, learning rate,
     windows, seed - Table 2's values; the rest stays the preset's, mapped at L10); `GenoLearner`, the union;
     `GenoControls` (save, checkpoint and judge minutes, stop after hours or updates); `GenoRun` with `parse` - a
     text that is no `GenoRun` tried as an older `PpoRun` and converted (`fromPpoRun`), else the GenoRun parser's
     description - and `write`. The new defaults are taken from `PpoRecipe{}`, `PpoRun{}` and `supertrack_recipe`,
     one source each until L4 retires the older types. Three tests: an empty file (PPO on the dance) and a partial
     one (EfficientTDMPC, one horizon changed, the rest Table 2's); a misspelt field refused by name and an older
     PPO file read (values in their places, PPO's recipe made back); each learner's run written and read back equal,
     SuperTrack's recipe made back with the task's filter. A control: an assertion made wrong fails the step (3 of
     4 then). Lint and test-fast green. The users - trainer, lab, page - still read `PpoRun`: L4 moves them, and the
     robot-mocap tutorial's run folder with them.
  O1 THE LAB'S OWN FILE, BEFORE L2 (Oct 24 review: Simon, "make sure zimrrl and the lab and the mocap tracking files
     are organised logically"). `robot_geno.zig` is Geno's body (10,440 lines, its header "Geno's own measurements")
     and also holds the run format and the recipes (`PpoMotion`, `PpoRecipe`, `PpoRun`, `SuperTrackRecipe`, L1's
     `GenoRun` with its task, learners and controls) - and L2-L4 would land there too. PROPOSED: `robot_lab.zig`,
     the lab's shared ground - the run folder, the recipes, the policy file (L2), the judge (L3), the learner switch
     (L4) - for its users (`geno_trainer`, `geno_lab`, `geno_ppo`, `geno_train`, `st_bench`), with a test root of its
     own so a lab step compiles that file alone (L1's three tests took 245 s through test-fast, nearly all of it
     building the other roots). Also for Simon: `robot_bmpc.zig` is a general agent (its one user the cartpole gate)
     - into zimrrl beside the ingredients it is assembled from, or kept a robot file until L10 gives it the dance;
     `robot_world.zig` is used by tests and the tutorial alone (the code uses `robot_latent` and `robot_latent_kit`)
     - kept as the tutorial's teaching model, or retired; `robot_sac_track.zig` (187 lines, tests only) - kept until
     a SAC learner joins the lab, or folded into `robot_track_env.zig`.
     O1 DONE (Oct 24; built by a turn that stopped before reporting, checked by the next). `src/robot_lab.zig` (1,202
     lines; `robot_geno.zig` 10,440 -> 9,268): `SuperTrackRecipe`, `supertrack_recipe`, `PpoMotion`, `PpoRecipe`, `PpoRun`, `GenoRunTask`, `PpoLearner`, `SuperTrackLearner`, `TdmpcPreset`, `TdmpcLearner`, `GenoLearner`, `GenoControls`, `GenoRun`, `RunFile`, `TrainerExit`, `RunState`, `RunStatus`, `RunLog`, `RunCurve` - the run
     folder's parameters with L1's three tests; its users (`geno_trainer`, `geno_lab`, `geno_ppo`, `geno_train`,
     `st_bench`) import it. `test-fast -Dfast-root=<file>` runs one file of the fast list alone - a file
     `robot_tests.zig` imports (`robot_geno.zig` among them) is run through that root instead:
     `-Dfast-root=src/robot_tests.zig`. Checked: the lab's root passes; `robot_tests.zig` 642 pass, 119 skipped; the
     trainer, the lab for Windows, both pages for the web and `st_bench` build; the tutorials' folds regenerated (one
     out of date, the trainer's `train`). BMPC, `robot_world` and `robot_sac_track` stay where they are (Simon to
     decide).
  L2 THE POLICY FILE. Written by PPO's trainer beside its state; read by one player (`GenoPolicy`: the network's
     forward pass, the normalisation, the filter) that the lab's watch uses instead of PPO's own. KNOWN ANSWERS:
     the player's actions equal PPO's mean actions on the same observations, bit for bit; a file of another shape
     refused by name.
     L2a DONE (Oct 24): the policy and its file, in `robot_lab.zig`. `GenoPolicy` (the layers - `PolicyLayer`, the
     kit's layout, `PolicyActivation` none or tanh - the normalisation in f64, the observation's and the action's
     clamps, the action scale and the filter), `policyMeanAction` (the arithmetic in the kit's CPU layer's order),
     `policyOfPpo` from `PpoPolicyParts`, `PolicyFile.encode`/`.decode` (little-endian, versioned; refused by name:
     not a policy, unknown version, truncated, unknown activation, layers that do not chain). PPO's normalisation is
     one static function, `robot_ppo_track.normalizeByStatistics`, which its trainer calls as before. Tests: the
     file reads back as itself and acts the same, three refusals (the lab's root); a PPO actor on the kit's CPU twin
     with made-up normaliser statistics acts through its file as PPO acts - its normaliser, `actMean`, the clamp -
     bit for bit on 20 observations (`gpu_learn_tests.zig`, run through `robot_tests.zig`: 659 pass). Left of L2:
     the trainer writes `policy` (and `policy_m<N>`) beside its state; the lab's watch plays it.
     L2a REVIEWED (Oct 24). Found and fixed: the reader trusted the file's counts - a damaged layer count or layer
     size asked for an allocation as large as it said, and a layer's weight count could overflow a 32-bit `usize`
     (the web's) - now every count is checked against the bytes left, with overflow-checked arithmetic, before
     anything is allocated; a file too long and one with no layer were reported as truncated - now
     `PolicyHasTrailingBytes` and `PolicyHasNoLayers`; unknown flags were ignored - now `PolicyFlagsUnknown`; a
     deviation of zero would make an input not a number - now `PolicyDeviationInvalid`; `policyMeanAction` read
     slices of any length - now it asserts the observation's, the action's and the scratch's; `encode` wrote any
     policy - now it asserts one `decode` reads back (and so caught the earlier test's unchained policy, now made by
     damaging the file's bytes). Two tests: the damaged files refused before allocating, and both clamps reached.
     FOR L2b: the weights file is built from `pipe.readLatest(.params)`, not the actor's CPU copy (`cpu_params`,
     refreshed from the readback a frame or more after an update) - the policy file must be built from the same
     parameters, after `waitForReadback`, or the two files can differ by an update. NOTED, NOT CHANGED: the policy's
     clamps (5 deviations, an action of 1) are PPO's literals repeated in `policyOfPpo` - one source would keep them
     from drifting apart.
     L1 REVIEWED (Oct 24). Found and fixed: `TdmpcLearner` stated EfficientTDMPC's values as its defaults (widths
     512, four dynamics heads, horizons 6 and 3, pessimism 10, the learning rate, the windows), so a run that chose
     the BMPC preset still trained EfficientTDMPC's heads and horizons under BMPC's name, and the numbers had two
     sources; every setting a preset decides is now optional, null meaning the preset's own value - the round-trip
     test writes a BMPC run as its preset alone, and an EfficientTDMPC run with two settings changed. The file reads
     in order: the recipes, `GenoRun`, the run folder's files, the policy, each followed by its tests (the policy had
     been put between the SuperTrack recipe and its tests); its header names the parts. FOR L4: `GenoRun` has no
     `problem()` yet - `PpoRun`'s names a value out of its range before training; the trainer reading `GenoRun` needs
     one per learner.
  L3 THE JUDGE. `judgeGenoPolicy`: the protocol above, deterministic; judge.csv written by the trainer. KNOWN ANSWERS:
     a policy of zeros scores the servo baseline's known time to failure; the same policy twice scores the same;
     a control that judges with exploration noise scores differently.
  L4 THE TRAINER BY LEARNER. `geno_trainer`'s loop calls the learner's static functions through one switch on the
     run's learner (start, resume from state, train a slice, save state, write the policy, log columns); PPO
     behind it first. A learner with a replay resumes with it empty: it collects with the resumed policy - no
     random actions - and its updates wait until the replay holds what its first update needs. KNOWN ANSWERS: PPO's
     run from an L1 run.zon matches today's run batch for batch; start, resume, stop.

  SuperTrack into the trainer (it is on the GPU already):
  L5 SUPERTRACK AS A LEARNER: `geno_train`'s training moved behind L4's switch (its recipe, its state, its policy
     file). KNOWN ANSWERS: the trainer's SuperTrack run matches the page's over its first batches; start, resume,
     stop; its policy file plays in the lab.

  EfficientTDMPC onto the GPU (this morning's E1-E5):
  L6 (T4, N9a) THE KIT'S MISSING OPERATIONS, with CPU twins from the same source: NormedDense (Linear, LayerNorm with
     its gain and bias, Mish - forward and backward), SimNorm (softmax in groups of 8), the two-hot categorical
     cross-entropy (101 bins on [-10, 10]). KNOWN ANSWERS: values and gradients against zimrnum's Graph operations.
  L7 (T5, N9b) ITS UPDATE ON THE GPU: encoder, the dynamics ensemble's latent rollout, the consistency, reward and
     value losses, the policy's loss (KL to the target policy, the scaled entropy), Adam, the targets' Polyak -
     against `Bmpc(T)`'s CPU update at reduced widths (agreement over the first steps, both converging).
  L8 (T6, N9c) ITS PLANNER ON THE GPU: MPPI's candidates under every head, the multi-horizon mean, the ensemble's
     score and pessimism - against the CPU actor's decisions on the same states.
  L9 (N8, short) THE CARTPOLE GATE ON THE GPU: the GPU agent reaches the CPU gate's 0.333 here, in minutes.
  L10 EFFICIENTTDMPC AS A LEARNER: the dance task (`TrackEnv` on Geno, one decision step and one update - per-step
     insertion - episodes ended by falls so beta applies), its recipe (Table 2's values defaulted), its state, its
     policy file (the encoder and the policy head as one network). KNOWN ANSWERS: a few hundred steps run, every loss
     finite and falling; start, resume, stop; its policy file plays in the lab.

  The lab's UI, one view at a time:
  L11 RUNS. The runs as a list: a status mark (running, finished, stopped, failed), the name, the learner, minutes
      trained, the latest judge score; a click shows a run, a tick adds it to the comparison; buttons beside it:
      Stop, Resume, Duplicate (a new run with the same settings, its name suggested).
  L12 NEW RUN. The learner chosen first - three buttons, each with its one line (PPO: on-policy, steady; SuperTrack:
      a world model and the tracking loss's exact gradient, fastest on clean tracking; EfficientTDMPC: a world model
      and planning, made hard to exploit). Then a short form: the name (suggested), the clip's range, hours, seed;
      presets ("the paper's settings", "a five-minute check"); "More" opens every field of the learner's recipe -
      the form made from the recipe struct itself (its fields, defaults and doc comments as tooltips), so a recipe
      field added is in the form without lab code. Start writes run.zon and starts the trainer.
  L13 WATCH. The chosen run's policy on Geno beside the reference, a timeline of its checkpoints to pick one, play,
      pause and speed, a push button (one fixed shove) to see it recover; while the run trains, the newest policy
      reloaded. For an EfficientTDMPC run, a switch "Plan" (off by default - Simon, Oct 24): the run's state loaded
      (every network, not the policy file alone) and each decision made by L8's planner on the GPU, the acting
      budget of its recipe, so the policy's moves and the planner's can be watched against each other.
  L14 COMPARE. The ticked runs' judge curves over each other - a measure chosen, the x-axis minutes or steps,
      smoothing; a table of them (learner, minutes, best and latest scores, error, time to failure); two runs side
      by side on the floor from the same start and seed.
  L15 (RT8) THE WINDOWS PACKAGE: one zip - geno_lab.exe, geno_trainer.exe, a run.zon per learner, a readme (start,
      watch, compare, stop, resume) - then Simon's first nights.

**The next turns, precisely (Oct 25).** One small turn each. Each turn's check is the narrowest root that compiles
what it touched - `zbuild test-fast -Dfast-root=src/robot_lab.zig` (about 2 minutes), or
`-Dfast-root=src/robot_tests.zig` (about 3) for a file `robot_tests.zig` imports, `gpu_learn_tests.zig` among them -
plus the style gate, `zbuild lint-check` (seconds: every rule, the layout included, over every source - the trainer's
build does NOT apply every rule to the files it compiles), and the build of what the turn changed; never the whole
suite, no run past 5 minutes. A cached run prints no counts and has passed; to see the counts, change the filter by a character.

  N1 THE TRAINER WRITES THE POLICY (L2, its writing half). At every save, `geno_trainer` writes `policy` beside
     `weights` (a new file, renamed over the old), and at every checkpoint `policy_m<N>` (N its minute of training);
     `RunFile` names both, and a checkpoint's minute reads back from its name. The parts are the SAME parameters the
     weights file holds - `pipe.readLatest(.params)` after `waitForReadback` - never the actor's CPU copy, which lags
     an update. One source for the clamps: PPO's 5 deviations and its action's 1 move into `ppo_track.Options` (as
     `observation_clamp`, `action_clamp`), read by `normalizeByStatistics`' callers, the show, the judge and
     `policyOfPpo`. KNOWN ANSWERS: a 2-batch run on lavapipe writes `policy`; it decodes; its input and action counts
     are the trainer's; its action on an observation equals the trainer's own (normaliser, `actMean`, clamp) on the
     same parameters, bit for bit - the trainer checks this itself after writing its first policy and exits 2 if not.
     N1a DONE (Oct 25): the clamps, one definition each, and the policy files' names. The action's limit is the
     controller's range, so it is `robot_track_env.Options.action_limit` (1), read by `TrackEnv.decide`, PPO's show
     and its judge (`evaluate`), and `PpoPolicyParts.action_limit`; the observation's clamp is PPO's normaliser's,
     `ppo_track.Options.observation_clamp` (5), passed to `normalizeByStatistics` and `PpoPolicyParts`.
     `RunFile.policy_name` ("policy"); `policyCheckpointName`/`policyCheckpointMinute` (`policy_m<minute>`, five
     digits: minutes, a learner-neutral clock, where the weights' checkpoints count batches). Checked: the lab's root
     491 pass, the robot root 662 (PPO's tests, the environment's, the bit-for-bit test), the trainer's build with
     lint. Left of N1 (N1b): the trainer writes `policy` and `policy_m<N>`, and checks the first one itself.
     N1b DONE (Oct 25): `geno_trainer` - `trainerPolicy` (PPO's actor from `pipe.readLatest(.params)`, the weights
     file's parameters, with the normaliser, the limit, the scale and the filter), `savePolicy` (a new file, renamed
     over the old), `saveAll` writing `policy` with the weights, `saveCheckpoint` writing `policy_m<minute>` beside
     `weights_b<batch>` (both names now `RunFile`'s, one definition), and `policyPlaysAsTrained` after a start's first
     save: the file read back, its action on every environment's observation against the trainer's own (the CPU copy
     synced to the readback, the normaliser, `actMean`, the limit), bit for bit - otherwise the run fails, exit 2.
     Checked on lavapipe: a 2-batch run exits 0 with `policy` and `policy_m00000` beside the weights; a CONTROL (one
     weight shifted as written) exits 2, "the policy file does not play as the trainer acts"; the trainer builds for
     the host and for Windows, with lint. The robot-mocap tutorial's run folder lists the policy files and says what
     a policy is.
  N2 THE SHOW, LEARNER-NEUTRAL. `PolicyShow` in `robot_lab.zig`: characters on a fleet of their own, each decision
     the policy's mean action (`policyMeanAction`) through DReCon's filter at the policy's `filter_beta` and
     `action_scale`, held `decimation` physics steps, one physics step per call (for drawing), counting exposure and
     failures - what `ppo_track.Trainer.Show` does, with a policy file in place of the trainer. KNOWN ANSWER: on the
     same seed and characters, a PPO trainer's policy shown by `PolicyShow` and by `Trainer.Show` takes the same
     actions and counts the same exposure and failures over 600 physics steps, bit for bit; CONTROL: one weight
     changed, the actions differ (`robot_ppo_track_tests.zig`, through `robot_tests.zig`).
     N2 DONE (Oct 25): `PolicyShow` in `robot_lab.zig` (`PolicyShowSettings`: characters, seed, decimation, episode
     cap, task, bodies - what a policy file does not carry; `start` in the caller's arena, `step` one physics step,
     `end` the fleet). KNOWN ANSWER (`robot_ppo_track_tests.zig`, not slow-gated: about a second): a PPO trainer
     that has collected 8 decisions, its policy made from its parameters - PPO's `Trainer.Show` and `PolicyShow` on
     the same seed, 2 characters, 600 physics steps: every decision's actions equal, the exposure and the failures
     equal; CONTROL: one weight of the last layer changed, the first decision's actions differ. Robot root 663 pass,
     the lab's root 491, the style gate clean, the trainer's 2-batch run exits 0. The gate, run this turn for the
     first time since L2a, found what the trainer's build had not: `std.math` in the lab file (the policy reader's
     checked arithmetic, now zimrmath's `mulChecked`/`addChecked`/`maxInt`), its layout, two bare `.init` in a struct
     literal, a redundant float conversion in a test, an unused alias and a use before declaration in the trainer,
     `@intFromFloat(@floor(x))` - all fixed.
  V2 ONE NORMALISER, AND THE POLICY'S SECOND VERSION (Oct 25, Simon: "more bug free by construction"). Three
     definitions of observation normalisation existed: zimrrl's `ObsNormalizer` (SAC's), PPO's trainer's own, and the
     policy player's. V2a DONE: `ObsNormalizer.observeF32` and `.applyInPlaceF32` - f32 widened, the same arithmetic,
     narrowed once (zimrrl test: identical statistics and numbers to `observe`/`apply` on the widened values; nothing
     observed leaves an observation as it is - PPO's own normaliser clamped everything to 5 instead, the one change
     V2b brings, never reached in training). V2b DONE (Oct 25): PPO's trainer holds an `ObsNormalizer` (clip = its
     `observation_clamp`) in place of its three fields; the weights file's import and export, the trainer's policy
     parts and the tests follow; both bit-for-bit tests prove nothing else moved - robot root 663 pass, a run and its
     resumption exit 0 (the self-check passing each start), the PPO page builds; `normalizeByStatistics` is gone. V2c: the policy file's second
     version - the policy carries `normalization: ?ObsNormalizer`, frozen, normalised by `applyInPlaceF32`; layers
     chained by construction (the observation's size once, each layer its outputs); the header and each layer's an
     `extern struct`, the flags a `packed struct(u32)`. V2c DONE (Oct 25): `GenoPolicy` is `widths` (the
     observation's size, each layer's outputs - chained by construction, the "layers do not chain" error gone),
     `layers` (activation, weights and biases), `normalization: ?zrl.ObsNormalizer` (frozen; the player normalises
     with `applyInPlaceF32`, the function PPO trains through - the policy's own copy of the arithmetic gone),
     and the controller's limit, scale and filter; `PpoPolicyParts` carries the trainer's normaliser. The file's
     version 2: `PolicyFile.Header` and `LayerHeader` are `extern struct`s written and read as they lie in memory
     (`asBytes`, `bytesToValue`; a comptime check that the target is little-endian), `Flags` a `packed struct(u32)`;
     a version-1 file is refused by its version; `PolicyNormalizationInvalid` for a normaliser that cannot be. The
     tests find a field's place by `@offsetOf`. A double free in the reader's error path, caught by the testing
     allocator, fixed by giving the normaliser's arrays one owner. Lab root 491, robot root 663, a run exits 0 with a
     version-2 policy (180 inputs, 3 layers, normalised), the lab builds for Windows.
  N3 THE LAB WATCHES THE FILE. `geno_lab`'s watch plays a run's `policy` (or the checkpoint chosen) through
     `PolicyShow` - no learner loaded to watch; a run from before policy files is told as such. KNOWN ANSWER: a
     headless lab capture of a run folder with a policy shows Geno following the dance, the run's name and minute.
     N3 DONE (Oct 25): `geno_lab` watches a run by its policy file - `readPolicy`, `policyNearest` (the checkpoint
     nearest a clicked minute), `ShownRun` holding the policy (the lab's `gpa`) and a `PolicyShow` of one character
     (its own heap arena), the task from the run's `run.zon` through the recipe's options; reload puts the newest
     policy in place and the character goes on; a folder without a policy file is told as such. The lab no longer
     starts a GPU compute pipe or builds a trainer to watch: its kernels' table, `readWeights`, `weightsNearest` and
     the `Trainer` alias are gone. KNOWN ANSWER: headless, a run folder from the trainer beside the lab's executable
     - the lab lists it and shows it at once ("showing dance_v2: policy"), Geno following the dance beside the
     reference. The robot-mocap tutorial's lab paragraphs say so; the button is "reload policy".
  N4 THE JUDGE, AND ITS CONTROLS (L3). `judgePolicy` in `robot_lab.zig`, on `PolicyShow`'s stepping: the dance from
     fixed start frames (every second of the clip), a fixed seed per start, the policy's mean action, no pushes.
     Its verdict: the share of the clip tracked before a fall, the mean time to failure, the mean body and root
     position errors (cm), falls per minute - EACH WITH ITS STANDARD ERROR over the starts, so a comparison knows its
     noise. Before it is trusted, its controls (goban's arena measured noise for a day before its controls showed the
     instrument broken): a policy of zeros scores the servo's own time to failure, as the trainer measures it; the
     same policy judged twice gives the same verdict; the judge with exploration noise gives a different one. The
     trainer writes judge.csv every `judge_minutes`.
     N4a DONE (Oct 25): the judge existed - `robot_track.judge` (plan F1: fixed starts, the mean action through an
     `Actor`, nothing random, the servo alone as baseline, `Judgement`). Policy files now reach it: `PolicyDecider`
     (DReCon's subset and the observation's scratch, one `decide` for the show and the judge alike), `PolicyShow` on a
     decider, `PolicyJudgeActor` (a decider, a controller, a countdown: decided every `decimation` steps, filtered,
     a restarted character forgotten), `judgePolicy` (a policy, or none for the servo). CONTROLS
     (`robot_ppo_track_tests.zig`, seconds): a policy of zeros judged exactly as the servo alone - failures, ends,
     steps watched, reward; judged twice the same; a policy at its limit judged otherwise.
     N4b DONE (Oct 25): standard errors without a per-start record - `robot_track.Judgement` keeps, beside its
     totals, the sum of each start's first-episode length squared, the steps of the starts that failed, and each
     start's tracked share of the clip with its square (`Judging.recordStart`). `meanTimeToFailureError`: the delta
     method for the ratio sum(t)/sum(f), its residual sum expanded so the sums suffice; null with no failure (the
     time is then a lower bound) or one start. `meanTrackedShare` and its error. KNOWN ANSWERS: the formulas on four
     hand-made starts against the per-start computation; on the fixture, all starts judged together hold exactly the
     sums of each judged alone, and a start that reached the clip's end tracked a share of exactly 1. Robot root 666.
     Left of N4: the trainer writing judge.csv every `judge_minutes`; the lab showing the judgements.
     N4c DONE (Oct 25): `judge.csv` (`RunFile.judgements`; `lab.JudgeLog`: a header, the servo's line at batch 0,
     then a line per judgement - every field of `robot_track.Judgement`, written as the shortest decimal that reads
     back the same, so a reader rebuilds the judgement and its errors). `PpoRun.judge_minutes` (5; carried into
     `GenoControls`). The trainer's `judgeNewestPolicy`: starts a second apart over the clip, the servo once, the
     newest policy (the latest readback) every `judge_minutes`, the file rewritten whole; a resumed run reads it
     back and keeps the cadence (`lastJudgedMinutes`). Checked: the round trip (lab root 493); a 3-batch run with
     judgements every 0.01 minutes wrote the servo (10 starts, 1.45 s) and batch 2 (1.56 s, standard error 0.13 s);
     resumed to batch 5, it added batch 4 and no second servo line; the trainer builds for Windows. The tutorial's
     run folder lists judge.csv, and says how sure a judgement is. Left of N4: the lab showing the judgements.
     N4d DONE (Oct 25): the lab reads each run's `judge.csv` at every refresh (`judgedRunOf`: the servo's line and
     the newest) and shows, under the run's status, "judged 1.51 +- 0.14 s, the servo 1.45 s" (or "never lost on its
     starts", a lower bound). Headless with the judged run: shown so - beside training's own "loses it every 17.1 s",
     held up by the root assist, which is why runs are compared by the judge. NOT YET: error bars on the curves -
     `ui.plotCurves` draws curves and a dashed baseline only; a plot of points with error bars is an engine feature
     to add to `ui.zig` (Simon to decide).
  N5 THE TRAINER READS `GenoRun` (L4). `GenoRun.problem()` - each learner's ranges named, as `PpoRun.problem`
     names PPO's; the trainer's loop behind one switch on the learner, PPO the only one yet; a new run's run.zon
     written as a `GenoRun`, an older `PpoRun` still read; the lab's new-run form writes `GenoRun`. KNOWN ANSWERS:
     PPO from a `GenoRun` trains batch for batch as from the older file; start, resume, stop; a value out of range
     refused by name before training.
     N5a DONE (Oct 25): `GenoRun.problem()` - the task (`taskProblem`), the learner's settings by its tag
     (`ppoProblem` on the learner's full recipe, `superTrackProblem`, `tdmpcProblem` checking only the settings a run
     names), the controls (`controlsProblem`, judge_minutes now among them) - each check one definition with a
     comptime prefix, so `PpoRun.problem` is the same chain under its own paths ("recipe.beta: ...") and a
     `GenoRun`'s names its own ("task.beta: ...", "learner.supertrack.batch: ..."). `GenoControls.judge_minutes`
     takes `PpoRun`'s default. Lab root 494.
     N5b DONE (Oct 25): the trainer reads `run.zon` as a `GenoRun` (which reads the older `PpoRun` too) and
     checks it (`GenoRun.problem`); `main` switches on its learner - PPO becomes the older `PpoRun` its path takes
     (`GenoRun.toPpoRun`, `fromPpoRun`'s inverse: tested both ways), the others are refused by name ("learner.
     supertrack is not in the trainer yet", exit 1). A folder without `run.zon` still gets the older form, which the
     lab reads. KNOWN ANSWERS: the same run from either format trains to byte-identical weights and policy files, and
     logs identical but for the minutes; lab root 495; the trainer builds for Windows. Left of N5: the lab reading
     `GenoRun`, then the writers (the trainer's default, the lab's new-run form) writing it.
     N5c DONE (Oct 25): the lab reads `run.zon` as a `GenoRun`; a shown run's show takes `lab.showSettingsFor(task)`
     (Geno's task, DReCon's bodies, the run's decision - one definition for any learner); the caption, silence and
     the new-run form follow (the form is PPO's until L12: a PPO run starts it from its settings, another learner's
     from the defaults). Then the writers: the trainer's default `run.zon` and the lab's new runs are `GenoRun`s.
     Checked: headless, a run of each format listed and shown, their curves one; a run started in an empty folder
     wrote a `GenoRun` and trained; the lab builds for Windows. The tutorial's run.zon paragraph says task, learner,
     controls. N5 DONE.
     THE ORDER FROM HERE (Simon, Oct 25: "do it all in the best order, review as you go"): N5's rest, then SuperTrack
     (L5: it trains on the GPU already, the shortest road into the lab), then EfficientTDMPC on the CPU on the dance
     (the CPU agent passes the cartpole gate; its runs become the reference the GPU port is held to), then the GPU
     port (L6-L9), then L10's GPU learner.
     THE ROAD TO THE LAB (Oct 25 estimate, at today's turn size): SuperTrack in the lab 7-9 turns - N5's switch
     with PPO behind it (2 more), L5 (4-6: SuperTrack's state saved and resumed, its policy file - a third version
     naming its observation, SuperTrack's features, and acting every physics step). EfficientTDMPC 13-19 turns more
     on the GPU (L6 kit operations 3-4, L7 its update 4-6, L8 the planner 2-3, L9 the cartpole gate 1-2, L10 the
     dance 3-4) - or 4-5 turns on the CPU first (the CPU agent passes the cartpole gate today), the GPU port after.
  L5 SUPERTRACK, PRECISELY (Oct 25 review). The SuperTrack the lab runs is the GPU learner the `geno_train` page
     trains (`robot_track_resident.Resident`), not the CPU learner `SuperTrackRecipe` describes (`robot_latent`, the
     bench's). Its policy differs from PPO's: it observes SuperTrack's FEATURES (the character's state and the
     reference one frame ahead, each in the root's frame, both normalised by a normaliser measured once from the
     clip - not DReCon's observation, not Welford's); its first layer reads [goal | state] (one dense layer over the
     two, in input order - the GPU's own order; the CPU mirror interleaves them and agrees only to rounding); it acts
     at EVERY physics step on EVERY actuated joint, unfiltered and unclamped. The learner keeps no saved state yet.
       L5a DONE (Oct 25): `SuperTrackLearner` is the GPU learner's options (`resident.Options`) and the action scale,
          defaulted to the page's values, copied by one loop, held to the options at compile time both ways; its
          checks (`superTrackProblem`) rewritten; the page takes its options from it - one definition. Lab root 495,
          the page builds.
       DECIDED (Simon, Oct 25: "I agree"; and "very different algos must work without limiting each other - no
          framework forcing all parts to share rigid interfaces"). DONE: `GenoRunTask` is the motion alone (with Geno's
          rule, physics and servo); `PpoLearner` holds PPO's whole recipe, its `decimation` and `beta` included (the
          mirror check now both ways against `PpoRecipe`); `TdmpcLearner` its own (DReCon's defaults); SuperTrack none
          (`GenoLearner.decimation()` gives 1); `decisionProblem` checks each under its learner's path;
          `showSettingsFor(run)`. Checked: lab root 495; the same run in either format, the filter at 0.25, trains to
          identical weights; the default `run.zon` is `.task = .{ .motion = .dance }` with the learner's decision; the
          lab builds for Windows; the tutorial says the decision is the learner's. A `run.zon` written in the new
          format before this change (only test folders) no longer reads.
       WHAT DIFFERENT LEARNERS SHARE, KEPT THIN (Simon's concern): the run file's envelope (motion, controls, one
          learner of a union - each learner's settings its own struct, mirroring its own options); the measurements
          (`judge.csv`, the status - learner-neutral; the judge acts through `Actor`, a context and a function, so any
          learner's own acting code is judged without the judge knowing its type); the policy file, the common
          denominator for watching and judging - NOT the only way to act: EfficientTDMPC acts best by planning, which
          no network file holds, so the lab must also run a learner's own actor (its planning version, as decided).
          Each learner's training loop is its own function, its state file its own. COMING CORNER TO AVOID: the
          training log's columns are PPO's batch counters - each learner writes its own log, sharing only what the
          curves need (minutes, steps watched, failures), when the second learner's log lands (L5d).
       (Superseded:) the decision interval and DReCon's filter sit in the shared task (`GenoRunTask`), on the
          principle that runs compare only on the same task; but they are a controller's design, not the task's -
          SuperTrack decides every step, unfiltered - and the judge compares controllers fairly on what is truly
          shared (the clip, the failure rule, the physics, the servo). PROPOSED: move `decimation` and `beta` from the
          task to each learner (PPO's recipe has them; SuperTrack's are 1 and 1; EfficientTDMPC's its own) and into the
          policy file (which carries the filter already), so that a policy plays without its run's files.
       L5b the resident learner's state saved and resumed (both networks, Adam's moments, the counters; the replay
          refilled on resuming, as decided). L5c the policy file's version 3: the observation it reads (DReCon's, or
          SuperTrack's features with the clip's frozen normaliser), and its decision interval. L5d the trainer's
          SuperTrack path (`run.toPpoRun` beside a SuperTrack branch; its policy files, judgements, self-check). L5e the
          lab shows and judges a SuperTrack run.
  N6 SUPERTRACK IN THE TRAINER (L5), then the GPU kit for EfficientTDMPC (L6 on).

**What makes the comparison honest** (for the views of L11-L14, built on N4):
  - Equal budgets: checkpoints at the same minutes for every learner (`checkpoint_minutes` 10 by default), so the
    compare view's table can judge every run at the same minute - and an x-axis of environment steps beside minutes.
  - Seeds: one run is one draw. A Duplicate with the next seed is one click, and runs of the same settings and
    different seeds are drawn as their mean with their spread.
  - The judge's own noise: every measure with its standard error; two runs whose difference is within it are told
    apart by no one.

**Decisions (Simon, Oct 24).** A checkpoint does not keep the replay: a resumed run refills it (L4). Watching an
EfficientTDMPC run shows its policy alone by default, planning a switch away (L13). The judge pushes later, with
R5.9's judge; the watch's push button is the eye's test meanwhile (L3, L13).

**After the first nights** (designs below): R5's merge (SuperTrack's pathwise loss with BMPC's pessimistic value
tail) as a fourth learner beside the three; N10's jumpy dynamics; RT9 (the trainer's characters on the CPU's cores);
RT10 (the training wheels); RT7 (the web viewer and the single-file demo, playing L2's policy file).

---

## Resumption, prepared Oct 17 (Simon: "Look at where we are with the reinforcement learning plan. What are the next
## steps? ... prepare more precisely the next few turns")

**Where it stands.** No learner tracks the dance yet. The bench (B1, Sep 28) found the open problem: SuperTrack's
world model learns (trust 3.1 -> 0.23) and its policy exploits it (exploitation ~100; MTTF 1.52 s untrained ->
0.56 s). The work since built ingredients (Stage I: I1 measured harmful, I3's TrackEnv and SacTrack), then BMPC and
EfficientTDMPC reproduced and reviewed on the CPU (R1: B1-B6, N7a-N7f-2 - two planners, the prefix objective, the
dynamics ensemble, its scoring, pessimistic reanalyze, the cross-scoring diagnostic's model side). The cartpole gate
learns (0.333 up vs 0.153 random) at about a hundredth of BMPC's budget, and Oct 4 decided: no more CPU learning
runs - real training is on the GPU. R5 (Oct 5) is the direction: SuperTrack's pathwise loss for the common case,
BMPC's pessimistic critic and a sparse planning teacher where gradients fail, one objective (R5.8), its judge (R5.9).
Stage D (AccelWorld) is not started.

**What Oct 16-17 found, natively.** The GPU path is the critical one, and it does not run on Vulkan yet: headless on
lavapipe, `zimrnum_train` stops at `zn_train`'s `loss_value` pipeline and `cartpole_duel` at `zn_mlp`'s
`mse_value` (both -13, VK_ERROR_UNKNOWN; platforms_plan.md, Oct 17). `zn_mlp` is the kit of every RL page
(cartpole_duel, track_train, geno_train, getup_train, geno_ppo). The two refused kernels share one shape: a
single-thread reduction - every thread past the first returns, a loop sums squared errors, a division, a scalar
store. The pages pass on WebGPU, where the SPIR-V is translated to WGSL; natively the driver compiles it.

**The next turns** (each verified headless here - Windows waits for Simon):

  T1 THE PIPELINE CHECK, AND THE REFUSAL FOUND. `vk-host-test` gains `pipelines`: a pipeline for every entry of every
     GPU module (zn_train, zn_mlp, zn_binary, zn_unary, zn_matmul, zrl_binary) - today it fails on two. Then the
     refusal bisected on that check, one construct at a time against lavapipe: the early return past thread 0, the
     loop's sum, the division by `zm.float`, the second store, the entry wrapper (`kompute.installKernelLean`). The
     fix where the fault is - the kernel's form, kompute's wrapper, or how the Zig backend is driven - and a driver
     workaround only if the SPIR-V is shown valid, with the reason at the site. DONE WHEN every entry makes a pipeline
     on lavapipe and `zimrnum_train` and `cartpole_duel` start headless.
     T1 PROGRESS (Oct 17): the cause found - zig-spirv-quirks.md's Quirk 5. A constant index into a storage-buffer
     array gets its base's pointer type (a pointer to the array, not the element): invalid SPIR-V that WGSL
     translation ignores and a Vulkan driver refuses. Reproduced in one line (`b_data[0] = 1.0`); SPIRV-Tools and the
     Khronos validation layer installed from Ubuntu's archive (vk-host-test requires the layer). spirv-val over the
     cache's 57 modules: 7 invalid - the two compute modules (Quirk 5), two graphics shaders whose run-time-sized
     storage arrays lack the Block decoration, two fragment shaders writing FragDepth without DepthReplacing, and
     `zm_gpu_probe` (a compile-only probe, never a pipeline). NEXT: the host's legalising pass (each access chain's
     result type set to the pointer to the type it reaches), tested on hand-made modules; the `pipelines` check with
     a constant-index kernel; then the two graphics faults.
     T1 DONE (Oct 17) for the fault: `spv_vulkan.legalize` gained a sixth adjustment (`accessChainRetypes`): each
     access chain walked from its base's type through its indices (a struct's member number a constant), its stated
     type set to the pointer to the type reached, the pointer type declared before the first function where missing.
     Four tests on hand-made modules (the quirk in place - one word changed; a new pointer type with the bound raised;
     right chains word for word; a struct member and a ptr chain's first index); the cache's 56 modules all valid by
     spirv-val once legalised (the graphics faults were already the pass's 1st and 5th adjustments, not new). And
     headless with the validation layer on: `zimrnum_train` PASS - losses equal at step 0, 1.04e-7 apart at step
     40, both converged - and `cartpole_duel`'s GPU PPO training (iteration 28, 0 errors). On the way:
     `has_ptr_access_chain` now counts `OpInBoundsPtrAccessChain` too, which gives `ArrayStride` meaning as well.
     Left of T1: the `pipelines` check in `vk-host-test` (every entry of every GPU module, with a constant-index
     kernel) - taken into T2.
     MASTER (Oct 17): the project moved to Zig 0.18.0-dev.253, which fixes the compiler's defect at its source
     (`derivePtr`'s element step); verified on master - lint, test-fast, c2js-diff (103 + 2), test-sound, the
     worklet and page tests, `zimrnum_field` web and native (112/112).
  T2 PROGRESS (Oct 17): `vk-host-test` gained `pipelines` (every pipeline of `zn_train` and `zn_mlp` made under the
     validation layer) and `constant` (`examples/compute_smoke/constant_index.zig`: `values[2]` of a `[16]f32` and
     `grid[1][2]` of a `[4][3]f32` written by constant indices, read back - the written elements hold their values,
     every other element zero); green on lavapipe, no validation messages. Left: the XOR training as an automatic
     native check, `cartpole_duel`'s GPU update against its CPU twin natively, `zimrnum_train` into the catalog.
  T2 TRAINING ON VULKAN, CHECKED END TO END. `zimrnum_train`'s own check made automatic: the XOR network trained on
     Vulkan for 40 steps against zimrnum's Graph, the losses agreeing as on the web (about 1e-7); `cartpole_duel`'s GPU
     PPO update against its CPU twin, natively. `zimrnum_train` into the gallery's catalog. DONE WHEN both run green
     on lavapipe and both pages build for Windows.
  T3 N7f-3, THE DIAGNOSTIC'S ENVIRONMENT SIDE - EfficientTDMPC complete on the CPU. The cartpole as a value type whose
     copy is a snapshot; each plan (single head, ensemble, the policy's) stepped open-loop in a copy, discounted real
     rewards then the learned value at the end; the report's Delta R per planner and evaluator. KNOWN ANSWERS by hand
     on the cartpole; a control that steps the real environment instead of the copy fails them.
  T4 N9a, THE KIT'S MISSING OPERATIONS. BMPC's update and planner listed against `zn_mlp` (dense forward and
     backward, the activations, MSE, Adam, Polyak exist); the missing ones written with CPU twins from the same
     source: NormedDense (LayerNorm + Mish, forward and backward), SimNorm, the two-hot categorical cross-entropy.
     KNOWN ANSWERS: each kernel against zimrnum's graph operation on the same inputs, values and gradients.
  T5 N9b, THE WORLD MODEL'S UPDATE ON THE GPU: the rollout under every dynamics head, the consistency, reward and
     value losses, Adam - against `Bmpc(T)`'s CPU update at reduced widths, by zimrnum_train's method (agreement over
     the first steps, then both converging).
  T6 N9c, MPPI ON THE GPU: candidates rolled under every head, ensemble scoring, pessimism - against the CPU actor's
     decisions on the same states.
  THEN N8's first long run - the cartpole gate at BMPC's budget, on the GPU (natively or in a browser), overnight -
  and R5's P1, the value tail on SuperTrack's loss.

## Night run and demo, prepared Oct 17 (Simon: "I would like to do the mocap tracking night run on windows with the
## best possible rl algo soon. I want to then easily embed the weights and ship a single html file demo showing robot
## tracking")

**The algorithm for the first night.** Of what is built and verified: PPO with DReCon's recipe on Geno (`geno_ppo`:
`ppo_track`, the DReCon bodies, the action filter, normalised inputs, the fading root assist, the dance from 5 s to
15 s) - and since Oct 17 its update runs on the GPU natively (`zn_mlp`, the access-chain fix). SuperTrack
(`geno_train`) learns a world model its policy then exploits (the Sep 28 bench); BMPC and EfficientTDMPC are verified
on the CPU but lack their GPU kit (N9, several turns). So the first night is PPO; the R5 path continues by day and
takes over the nights once it beats PPO on the same judge (R5.9).

**The turns** (each verified headless here; Windows waits for Simon). NR1 was built; the run-folder design below
(RT1-RT9) replaced NR2-NR4 the same day; RT10 (Oct 18) adds the training wheels - help the policy asks for, priced,
gone after the first hour:

  NR1 GENO_PPO, UNATTENDED. The newest weights saved every few minutes as a saved value (`z.saveValue`: files under
      %APPDATA% on Windows), offered for resuming at the next start, so a crash loses minutes; the training curve
      (batches, mean time to failure, reward, losses) kept as a CSV beside them, for the morning; nothing in the run
      waiting for a press. DONE WHEN a headless run saves, a second run resumes from it, and the CSV reads back.
      NR1 DONE (Oct 17). `geno_ppo`: after the first batch and every 5 minutes of training, the newest weights
      (`<motion>.weights`) and a CSV log of raw counts per batch (`<motion>.log.csv`) saved as values
      (`autosaveIfDue`); at start-up, resumed without asking when the trainer accepts them (`resumeFromAutosave`,
      the servo still measured first; out of memory fails the start, so an old log is never overwritten empty);
      "start over" removes them. `ppo_track` gained `weightsByteCount` (the file's size from the network's shape,
      before any readback). Engine: a headless run keeps its saved values as files in `ZIMR_VALUES_DIR` when it
      names one (read at `headless.start`, before the app's init; `native_os.loadValueIn` and kin made public), in
      memory otherwise; `native_os`'s two libc tests skip in builds without libc. Checked: run 1 trained 33 batches,
      autosaved batch 1 (285 KB of weights, the log's header and first line); run 2 from the same folder "resumed
      from batch 1". Lint, test-fast, doc-folds green; robot-mocap tutorial 10.5 describes it.
  Simon, Oct 17: "It will be important to run training headless on windows, starting from parameters written in
  a zon file in a folder for this run. Weights and maybe other files will be written in this folder. After and
  while it is training the independent visual app can load the folder zon and weights from a file dialog to test."
  So the night run moves to a TRAINER PROGRAM and a VIEWER APP sharing a RUN FOLDER; NR1's page autosave stays for
  pages. The run folder:

      run.zon          the run's parameters: the motion, the learner's scalars, the run's own controls
      weights          the newest weights, rewritten whole (new file, then renamed over the old)
      weights_b<N>     checkpoints, every so many minutes
      log.csv          one line per batch, raw counts (as NR1's)
      status.zon       batches, minutes, the latest window's time to failure - for a person or the viewer
      stop             created by hand: the trainer saves and exits

  RT1 THE RUN'S PARAMETERS. `robot_geno.PpoRun`: the motion, the learner's scalar options (environments,
      horizon, epochs, gamma, lambda, the clip's end, width, minibatch, learning rate, initial exploration,
      normalising, the assist's schedule, the episode cap, action scale, decimation, the filter's beta, seed), and the
      run's controls (checkpoint minutes, stop after so many hours or batches); read from ZON with every field
      defaulted (`std.zon.parse.fromSlice`), written back the same way, turned into `Options` with the motion's own
      task and bodies. Tests: defaults, a partial file, an unknown field refused by name, a round trip.
      RT1 DONE (Oct 17). In `robot_geno.zig`, beside `SuperTrackRecipe`: `PpoMotion` (get-up, dance; label, tag),
      `PpoRecipe` (every scalar of `ppo_track.Options`, defaulted to the page's values; `options(motion)` adds Geno's
      task, DReCon bodies and the motion's tag), `PpoRun` (motion, recipe, save and checkpoint minutes, stop after
      hours or batches; `parse` from ZON with the parser's description on failure, `write` back). Three tests: the
      empty file is the page's training, a partial file and a misspelt field (refused, named), a round trip. The
      page now builds its trainer from `PpoRecipe{}` - its old weights still load (same shape and tag), checked by
      resuming the earlier autosave. `st_bench` still compiles with `robot_geno` importing `robot_ppo_track`.
  RT2 THE TRAINER. A standalone native program, like `st_bench` (its own `main(init)`, `cli` for the folder) and
      like `vk-host-test` (the Vulkan host without a window, `z.Compute` with `zn_mlp`): read run.zon, resume from
      the folder's weights if they fit, train flat out, write weights/log/status atomically and checkpoints on
      schedule, stop on `stop` or the configured limit. Built for Windows and for the host; checked headless here on
      a tiny run: files written, a second start resumes, `stop` stops it.
      RT2 DONE (Oct 17). `tools/geno_trainer.zig` (`zig build geno-trainer`, `geno-trainer-windows`): `--run=<folder>`
      (made if missing); run.zon read with `PpoRun.parse` (one with every default written when absent); the Vulkan
      host without a window, `zn_mlp` from its SPIR-V, Geno as the page builds it; resumed from the folder's weights
      and log (refused, folder untouched, when they do not fit); the servo measured alone; then `collect`/`learn`
      flat out, a log line per batch, weights + log + status rewritten whole (new file, rename) after the first
      batch and every `save_minutes`, checkpoints `weights_b<N>` every `checkpoint_minutes`; ends on `stop` (consumed)
      or `stop_after_hours`/`stop_after_batches`; a progress line at most every 10 s. Exit 0 ended, 1 refused, 2 GPU.
      Found and fixed on the way: (1) the servo baseline was measured WITH the root assist (full at batch 1), so it
      read "never fails" - in the trainer, `geno_ppo` and `getup_train` it is now measured with the assist off (2.0 s
      on lavapipe); (2) a resumed trainer ran its first batch at the assist's START, not where the schedule had it -
      `Trainer.assistAfter(iterations)`, used by `learn` and by `importWeights`. Checked on lavapipe: a 3-batch run
      (files, `.finished`), a resume to 5 (assist 0.990, 0.987), a stop (`.stopped`, the file removed), a refusal of a
      wider network (weights byte-identical), a refusal of `.envz` (named), a default run.zon written; the Windows
      build compiles. Lint, test-fast green; robot-mocap tutorial 10.5 describes the run folder.
  Simon, Oct 17, later: "with the visual app, we can also start a new training, by choosing values for the
  parameters in a ui. It saves the zon and starts the headless training as a separate program. We can start multiple
  trainings like that and compare their learning curves. We can kill them when we see that they are finished or when
  they dont work. The ui makes it easy to choose which network to run on the character." So the viewer becomes a
  TRAINING LAB (native), and the web keeps the viewer and the demo:

  RT3 TWO ENGINE PIECES, each one definition for its users. (a) Child programs: the gallery's start, watch and stop
      (`std.process.spawn`, a watcher thread recording the exit, the system's own termination by the id taken at
      start) moved into the engine, the gallery its first user. (b) Files by path, natively: read, write (new file
      then rename), list a folder, the program's own folder; a web build declares them unavailable with a comptime
      error naming why.
      RT3 DONE (Oct 17), and reviewed against Simon's rule ("passing allocs and io to functions that need to
      allocate or do io ... by default we pass it ... we like static functions with many args"). `native_os.zig`
      (exported as `z.native_os`): files by path - `readWhole`, `writeWhole` (new file, rename), `fileExists`,
      `deleteFileIfPresent`, `makeFolder`, `listFolder`/`freeFolderEntries`, `executableFolder`, each taking the
      caller's `gpa` and `io`, a web build refused at compile time; `ChildProgram` (start with the caller's `io`,
      watched by a thread that receives it, stopped by the system's call, `deinit`), the watcher a member of it.
      `servicesIo()` (was `io()`) only for callers with no `Io` to pass: the platform contract's saved values and an
      app. The gallery uses both (its own process code, `kernel32` declarations and `Io.Threaded` gone); the
      trainer's `Run` became `RunProgress` (plain state) and its work static functions taking `gpa`, `arena`, `io`,
      the folder, the trainer and the progress. `native_os.zig` a fast test root (its two libc tests skip there).
      Checked: native_os's tests, test-fast (full), lint, both gallery builds and the trainer, the trainer's
      scenarios (to 3, resume to 5, stop, wider refused), the gallery starting and watching an example. Then
      `geno_ppo`'s helpers: `appendLogLine(gpa, training_log, batches, training_seconds, stats)` returns its error,
      `autosaveIfDue(gpa, trainer, task, training_log, progress)` returns whether it saved, `resumeFromAutosave(gpa,
      trainer, task, training_log)` returns a `ResumeOutcome` (nothing saved, refused by name, resumed) - the page's
      status set by the callers. `startTask`/`startOver` keep the page state: they swap the page's trainer and clip.
      Resuming checked again headless.
  RT4 THE LAB, THE CHARACTER. A native app: a run folder chosen (a list of the folders under the lab's runs folder,
      or a file dialog), its `run.zon` and newest weights - or one of its checkpoints - loaded; Geno on the floor
      follows the dance with that policy's corrections, the reference beside it; reloading picks up newer weights.
      RT4 STEP 1 (Oct 17): `ppo_track.Trainer.Show` - a policy shown, not trained or judged: characters on a fleet
      of their own, each decision the policy's mean action through DReCon's filter exactly as `evaluate` acts, but a
      physics step at a time (`startShow(gpa, characters, seed)`, `stepShow`, `endShow(gpa, show)`), kept between
      calls for a viewer to draw. Test: on the judge's seed with as many characters, `decisions x decimation` steps of
      a show count exactly the exposure and failures `evaluate(decisions)` judges; control: another seed lives a
      different show.
      RT4 DONE (Oct 17). `examples/geno_lab` (registered like geno_ppo: `zn_mlp_entries`, one list in build.zig for
      both; `configureGenoLab` embeds geno_ppo's dance.zclip): lists the run folders in `runs` beside its
      executable (`listRuns`: `native_os.listFolder`, folders only, by name), shows the first at start, a click shows
      another (`loadRun`: run.zon, `PpoRecipe.options` with one environment, the trainer, `readWeights`, a show of
      one), "reload weights" reads the newest weights into the same network, "refresh" lists again. Each frame one
      `stepShow`; the character and the reference drawn as the page draws them; the camera follows the character's
      root. Native only for the folder list (comptime `is_browser`): the web build compiles without it. Found on
      the way: the dance carries Geno ~4 m from the origin, outside a camera orbiting the origin - in geno_ppo too,
      which never showed its character headless; both cameras now follow (`yUpOf` the root). Checked: the lab
      headless beside a runs folder of two runs (dance-a shown at batch 146, Geno and the reference mid-dance), the
      web and Windows builds, geno_ppo headless (character 0 in view, servo 2.0 s). Tutorial 10.5: the lab and
      showing a policy. NOT YET in RT4: choosing one of a run's checkpoints (RT5, with the curves: a checkpoint is a
      point on its run's line), and a file dialog (RT7, the web viewer; natively the runs list replaces it).
      REVIEW (Oct 17, Simon: "verify it, make it more precise, review our code, look for bugs"), fixed and checked:
      (1) `native_os.listFolder` freed `entries.items` - shorter than the list's allocation - on a failure part-way:
      an invalid free; now the names, then the list. (2) the lab's "refresh" kept the shown run's INDEX, so
      "reload weights" could read another run, or past the list's end; the shown run now keeps its folder name and a
      refresh finds it again by name. (3) the trainer promised exit 2 for any setup failure but only a failed Vulkan
      start gave it; `main` now refuses (1) and `runTraining` fails (2): the GPU, the robot, a file not written.
      (4) `ChildProgram.start` left a child unwatched - `running` for good - when its watcher thread could not start;
      such a child is now ended at once, `not_started`. (5) `PpoRun.problem`: every value checked against what the
      trainer needs (at least one character, decision, pass, unit; minibatch within envs x horizon; gamma, lambda,
      beta in range; positive finite step size, scale, save interval) - the trainer refuses, naming the field; the
      lab refuses to load such a run; test. (6) the lab stepped one physics step a frame - a 144 Hz display played
      the dance 2.4 times too fast; it now steps the frame's time, at most 4 steps. (7) `exportWeights` wrote GPU
      parameters from the latest READBACK beside the trainer's CURRENT counters (Adam's step, batches, normaliser):
      a saved file could pair one update's parameters with the next's counters; `isReadbackCurrent` /
      `waitForReadback` - the trainer waits before every save and checkpoint, the page autosaves only on a batch whose
      readback is current. Checked: PpoRun's tests (5), the show test, native_os's tests, lint, the trainer and lab
      builds; the trainer's scenarios (to 3, resume to 5 with the assist at 0.987, stop, `envs = 0` refused by name,
      a wider network refused with the weights untouched); the lab headless (Geno in different poses at frames 60 and
      120).
      REVIEW 2 (Oct 17, Simon: "intermediate locals everywhere to reduce expression complexity to the minimum
      possible ... optimise for understanding"; `dt` a local for `f.time.delta_time`). The lab, the trainer,
      `stepShow`, `PpoRun.problem`, `assistAfter`, zbuild's `fixedFileReport`, the gallery and geno_ppo's drawing:
      nested calls split into named steps, values that do not change hoisted out of loops (the lab's steps owed
      computed before its loop, the show's steps per decision before its characters), compound conditions named
      (`is_gamma_in_range`, `is_save_due`), the trainer's first save of a start a flag (`has_saved_this_start`)
      instead of minutes compared within 1e-6. Found by naming: the drawn floor's slab sat 0.4 m below the grid,
      where the physics floor is - in the lab and in geno_ppo; now its top is 5 mm below (`floor_top`). Checked:
      lint, the show and PpoRun tests, zbuild's tests, the trainer's scenarios, the lab and geno_ppo headless (Geno
      on the drawn floor), the Windows gallery build.
      PARAMETERS, NOT GLOBALS (Oct 17, Simon: "I dont like globals, they give a bad feeling even if they are
      const"). File-scope values sorted four ways: VOCABULARY (imports, aliases, types, embedded bytes) stays; FACTS
      OF DATA are read from the data (the lab's timestep is `model.opt.timestep`; derived values are locals); SHARED
      DEFINITIONS become types in the shared module - `geno.physicsOptions()` (Geno's physics, now also used by six of
      robot_geno's own builders), `geno.RunFile` (the run folder's files: names, `most_bytes`, `checkpointName`),
      `geno.RunLog` (the log's header and `appendLine`, with a test), `ppo_track.secondsToFailure(steps_watched,
      failures, physics_steps_per_second) ?f32` (null when nothing failed; `status.zon` writes null), the trainer's
      `Exit` enum, `RecentBatches.window_batches` a declaration of the measure; PARAMETERS become defaulted structs in
      the state, passed to static functions - the lab's `Look`, `Floor`, `Pacing` (`stepShowForFrame(trainer, show,
      pacing, timestep, dt, owed_seconds)`, `drawFloor`), the trainer's report interval the option
      `--report-seconds`. `rbt`'s import moved to robot_geno's top. Checked: lint, test-fast (full), the RunLog,
      PpoRun and show tests, the trainer's scenarios and exit codes, the lab headless. Then geno_ppo the same way:
      `Look`, `Floor` (`drawFloor`) and `Autosave` (interval, the log's limit - passed to `autosaveIfDue` and
      `resumeFromAutosave`) in its state; its `PpoRecipe` a state field (`Task.options(task, recipe)`, the servo's
      buffer sized by it, the servo counting its fleet's characters); `history_len`, `window_batches`,
      `milestones` declarations of `Progress`, whose arrays they size; its time to failure `ppo_track.
      secondsToFailure` at the model's steps per second (`physicsStepsPerSecond`, passed to `recentWindow` and
      `drawCurve`); its log `geno.RunLog`; its physics `geno.physicsOptions()`. FOUND: the page never autosaved since
      review fix (7) - it checked right after `learn()`, which has just dispatched an update, so the readback was
      never current; now checked every frame (after the first batch), it saves a frame or two after each update.
      Checked: lint; the page headless twice on one values folder - batch 1 saved (its log through RunLog), the
      second run "resumed from batch 1"; its web build; the folds.
      EVEN STEPS (Oct 18, Simon: "for now we can do the smooth slowdown with fixed physics dt"; physics
      interpolation later; animation playback with its own timescale is a separate question). The lab's stepping
      carried a remainder and took the whole steps owed - at a steady 60 the remainder settles at a step's boundary,
      and the filtered frame time, never exactly 1/60, tips it into frames of no step or two (a freeze, a jump).
      `ppo_track.ShowPacing` (most steps per frame, a quarter-step tolerance) and `showStepsForFrame(dt, timestep,
      pacing)`: the frame's duration in steps plus the tolerance, rounded down, at least 1, at most 4, nothing
      carried - one step a frame at 60 (jitter of 2 ms either way included), 50 and 40 in slow motion (0.83, 0.67),
      two at 30; test of each case. Rejected: a shorter last step per frame (the policy, the clip's frames and the
      decisions are on the 1/60 grid; the show would no longer live what the judge judges). Not fixable without
      interpolation: a 144 Hz display shows the pacer's 60 frames for 2 or 3 refreshes each.
  RT5 THE LAB, THE CURVES. What is read: every run folder's `log.csv` (the columns `geno_trainer` writes) and
      `status.zon` (its state, the servo's time to failure), read again every 5 s - the log from the byte it was read
      to, its last line kept back when it has no newline yet. What is drawn, one line a run, in its own colour, all
      on one pair of axes: x = training minutes (the log's second column); y = the time to failure over the window
      of the run's last 8 batches, in seconds - the steps watched over the failures, at 60 steps a second, the
      trainer's own `RecentBatches` measure - plotted on a log scale from 1 s to 60 s, a window with no failure drawn
      at the top edge; the servo's time to failure a dashed line of the run's colour. Beside each run's name: its
      state from `status.zon`, or "silent" when the status says training but has not changed for 3 x save_minutes
      (a trainer that died without a word); its batch; its latest time to failure. A click on a point of a line shows
      the checkpoint nearest that batch (`weights_b<N>`), or the newest weights for the line's end. The parsing is a
      function of the text alone (log text -> points), tested: a window with no failure, a log kept back mid-line, a
      header-only log. DONE WHEN, headless: a runs folder of two logs of different shapes gives a capture with two
      lines, their names and states; the parsing tests pass.
      RT5 STEP 1 (Oct 18): the reading. `geno.RunLog.Line` / `parseLine` (a batch's line read back into named
      fields, the inverse of `appendLine`; null for the header, a missing or extra column, a column not a number);
      `RunLog.window_batches` (8) - the trainer's `RecentBatches` and the page's `Progress` now take their window from
      it; `geno.RunCurve` (`readMore(gpa, log_text, physics_steps_per_second)`: the whole lines past `bytes_read`, a
      last line without its newline waiting, a shorter log read again from its start, a stranger's line skipped and
      counted; a `Point` per batch - batch, training minutes, the window's `?f32` time to failure). Tests: a written
      line read back field for field, the header and malformed lines refused; three batches give none, 20 s, 10 s;
      a partial last line waits then is read once, a shorter log restarts, a stranger's line is counted. Checked:
      lint, the tests, the trainer (to 3) and the page with the shared window.
      RT5 STEP 2 (Oct 18): the lab draws them. Engine: `ui.plotCurves(label, curves, opts) ?PlotClick` beside
      `plotLines` - several `PlotCurve`s (xs, ys, colour, an optional dashed baseline) on one pair of axes, y linear
      or logarithmic (`PlotScale`), marked values with faint lines and numbers, the x range's ends under the frame,
      values outside an axis held at its edge, where it was clicked returned in its own units; each point placed once.
      `geno.RunState` / `RunStatus` (with `parse`) moved from the trainer to robot_geno, so the lab reads what the
      trainer writes. The lab: a `RunWatch` per run (its `RunCurve`, the plot's xs/ys, its status), read at a
      refresh and every `CurvesRefresh.interval_seconds` (5); each run's line under its name in its colour (state,
      batch, latest time to failure); the plot (`CurvePlot`: 1-60 s, log, marks 1/5/20/60, 180 px; `Look.runs`
      colours; nothing-failed at the top; the servo dashed). Found: the plot did not advance the layout (the buttons
      drawn over it) - `advanceLayout` added. Checked: lint, the trainer, the lab headless beside dance-a (146
      batches) and dance-b (7).
      RT5 DONE (Oct 18). A click on the curves: `nearestCurvePoint` (distance measured as drawn: minutes as a share of
      the x range, `decadesAboveLowest` as a share of the log y range), `showPickedPoint` - the run's checkpoint
      nearest the batch (`weightsNearest`: `RunFile.checkpointBatch`, the inverse of `checkpointName`, over the
      folder's names) or its newest weights for a curve's last point; `loadRun`/`readWeights`/`showRunWith` take the
      weights' file name. Silence: `RunStatus.written_at_seconds` (the trainer stamps every status with
      `native_os.wallClockSeconds`; 0 = unknown, never judged) and `RunStatus.isSilent(now, save_minutes)` (training
      or measuring, older than 3 save intervals); the lab reads each run's `save_minutes` from its run.zon once.
      Tests: checkpoint names both ways; silence (recent, old, finished, unknown age). Checked: lint, the tests, the
      trainer (six checkpoints, a stamped status), the lab headless - a click near the first point of a run's curve
      showed `weights_b0000001`, batch 1.
  RT6 THE LAB, STARTING AND STOPPING RUNS. A form: the motion; every field of `PpoRecipe`, each a number box
      starting at the run's default; save and checkpoint minutes; the stop limits; the run's name (starting as the
      motion and the start's date and time). "start" is refused while `PpoRun.problem` names a problem or a folder of
      that name exists; otherwise it makes `runs/<name>`, writes its `run.zon` whole (`PpoRun.write`,
      `native_os.writeWhole`), and starts the trainer beside the lab's executable on it (`ChildProgram.start` with
      `--run=<folder>`). Several at once: each its own `ChildProgram`, its state and exit code beside its line (RT5).
      "stop" writes the folder's `stop` file (the trainer saves, then exits 0); "end now" ends the process
      (`ChildProgram.stop`: the last save is the newest kept). Runs the lab did not start - another lab's, a trainer
      started by hand - show their state from `status.zon` and are stopped by their `stop` file only. DONE WHEN,
      headless: a script fills the form (envs 4, stop after 3 batches) and starts it; the folder appears with its
      `run.zon`; the trainer exits 0; the run's line is drawn; a second run started and stopped by its file ends
      `stopped`.
  RT7 THE WEB VIEWER AND THE DEMO. On the web the lab shows a run chosen by file dialog (`z.userfile`): its
      `run.zon` and a weights file, picked together; the curves and the form stay native. THE DEMO: the lab built
      with one run embedded (`-Drun=<folder>`: its `run.zon` and `weights` as anonymous imports) shows that run from
      the start with no panel but the run's name and batch - one standalone HTML file, in release mode, its size
      reported. DONE WHEN: the demo page's headless check shows Geno with the embedded run's batch, and a file-dialog
      load in the web viewer's test shows a run's batch.
  RT8 THE WINDOWS PACKAGE. `zig build lab-package-windows`: one zip of `geno_lab.exe`, `geno_trainer.exe`, a
      `runs` folder with one example `run.zon`, and a checklist (start the lab; start a run from the form; watch its
      line; reload; stop by file; where the weights are; how to build the demo from a run folder). DONE WHEN: the
      step makes the zip and its listing is exactly those files.
  RT9 THROUGHPUT. The characters of the trainer's fleet stepped on the CPU's cores (the engine's job threads), the
      networks' update unchanged on the GPU; more characters per batch. Measured as batches per hour, and minutes to
      each time-to-failure milestone, on the same run folder before and after, on Simon's Windows machine - the first
      measurement this plan makes, now that the pieces are assembled.
  Simon, Oct 18: "a new action dimension, that is a magic force that pushes on every bone so it comes back to
  reference ... using this action would reduce the reward ... It would be like training wheels that the agent can
  decide to use when needed instead of always being there." Then, after the discussion: "just one schedule, no phase
  2 ... after one hour, there is no force ... increase price and reduce cap at the same time, gradually ... I just
  want to speed up the training so the first hour has more facility finding directions for how to balance."
  RT10 THE TRAINING WHEELS - help the policy asks for, priced, gone after an hour. Needs RT6 (the lab starts the arms
      below) and nothing after it. Built behind one option, off by default: every run without it is today's to the bit.
      DECIDED (Simon, Oct 18): the force on every body, in proportion to its mass; ONE action number in [0, 1] - "this
      much training wheel now"; ONE schedule, no second phase; no force after the first hour; the price sets itself
      and rises as the cap falls; the cap falls smoothly to zero.
      WHY. In the first hour most of PPO's episodes end in a fall within a second or two (the servo alone: 1.53 s), and
      a fall is a CLIFF - the rest of the episode's reward is lost at once, and the policy learns balance only from the
      falls it actually has. Today's root assist (`Gains.assist` - its idea is ZEST's; the comment's credit to RFC is
      corrected in this step) holds the character up on a fixed fade the policy neither chooses nor sees. ZEST
      (Sleiman et al., RAI / Boston Dynamics, arXiv 2602.00401, Jan 2026; read Oct 18 with its supplementary S6): a
      model-based wrench at the torso - a PD on its orientation (200, 10), damping only on its velocity (0, 10: no pull
      toward where the reference is), the reference's accelerations fed forward, gravity cancelled with the whole-body
      mass - scaled by kappa <= 0.6, set per time bin of the clip from that bin's running failure average, held for the
      episode, zero once the bin tracks at 0.8; the actor never sees it, the critic does. Their ablation: without it,
      20 h of training reaches about what 10 h reaches with it, mostly on motions with large torso rotations; easy
      motions barely need it. Simon's version turns the cliff into a SLOPE: the policy asks for help with one number and
      pays for every step of it, so the help it buys is a graded measure of how close it came to falling, and the
      directions toward balance are found down that slope - in the hour when falls would otherwise end most episodes.
      And it is state-driven, not clock- or bin-driven: it helps THIS rollout when it is in trouble.
      THE FORCE - every body b, in proportion to its mass, at its centre of mass (`body_xipos`, `body_mass`):
          f_b = kappa * m_b * (a_ref_b - g + k * (r_ref_b - r_b) + c * (v_ref_b - v_b))
        r_b is the body's place RELATIVE TO THE CHARACTER'S CENTRE OF MASS (the reference body's likewise, relative to
        the reference's), v_b its velocity, a_ref_b the reference body's acceleration (its velocities at frames f and
        f + 1, from the reference states the tracking error already builds), g gravity; k = 200, c = 10 - ZEST's
        numbers. Summed over the bodies this is ZEST's wrench done exactly, applied where the mass is:
          - the total force is M * (a_ref_com - g + c * (v_ref_com - v_com)): gravity cancelled, the centre of mass's
            velocity damped toward the reference's, and NO spring on its position (ZEST's 0) - drift stays the task's;
          - the moment about the centre of mass is k * I_com * theta for a whole-body rotation theta, damped by
            c * I_com: a rotational spring on the body's TRUE composite inertia (ZEST approximates it with a nominal
            torso inertia), so tipping is resisted at the same rate whatever the pose; gravity's share has no moment;
          - what remains pulls the limbs toward the reference's shape - 200 against the servo's 20 Hz spring (w^2
            ~ 15,800; ~1,650 after the implicit step's softening at 60 Hz), so it is small beside the joints, which
            already do that job.
        NOT smaller in total than a root wrench: the force and moment that save a fall are physics, and gravity's
        share is kappa * M * g however it is spread. What IS smaller is the force at any one point and the loads it
        puts through the joints - no hook at the pelvis holding a sagging torso up through the spine. Into the
        equations as generalised forces by `rbt.applyForceAtPoint` (J^T, one body at a time): no mass matrix, cheaper
        than `rootAssist`'s dense one every step. Recomputed every physics step from that step's state; explicit at
        60 Hz, w dt = 0.24 and c dt = 0.17, well inside the explicit spring's bound (robot_maximal's
        h^2 + 4 zeta h < 4). With kappa 0 the function is not entered.
      THE GATE - one more action number: gate = max(0, a), a the policy's clamped action in [-1, 1], so "no help" is a
        whole half of the range and exploration noise around a negative mean does not leak help; through Simon's
        filter like every action (the force does not flicker at 30 Hz; it lags ~0.15 s, as every offset does);
        kappa = cap(s) * applied gate. Its output starts at 1 (that one output's bias), so the first batches are helped
        as today's are. The policy sees the applied gate (DReCon's observation already ends with the applied action)
        and two more numbers, the cap and the price; the critic sees what the policy sees (ZEST measured noisier values
        when its critic could not see the assist).
      THE CLOCK - s = training minutes / `minutes` (60), clamped to [0, 1]: the trainer's own clock (`trainingMinutes`,
        carried across resumes), because "after one hour there is no force" is the rule. The cost of a clock in
        minutes: a run's help depends on its machine's speed - so every batch's cap and price go into its log line,
        any run reads back exactly the help it had, and the tests drive the schedule through s directly.
      THE CAP - cap(s) = start_cap * (1 - smoothstep(0, 1, s)) = start_cap * (1 - 3 s^2 + 2 s^3) (`zm.smoothstep`),
        start_cap 0.6 - ZEST's most, below 1 because at full gravity cancelling Geno weighs nothing: his feet press on
        nothing, friction vanishes, and no footwork is learned while he is held. Flat at the start (97% of the help
        left at six minutes), half at thirty, and FLAT AT THE END: the last of the force fades with zero slope, so the
        hour ends without a step. cap(s >= 1) = 0 and the force is not entered - no force after the hour, by
        construction. (Considered: (1 - s)^2, the quadratic that also lands flat - but it gives up a fifth of the help
        in the first six minutes, the minutes the help is for.)
      THE PRICE - every step's reward pays price * applied gate. Linear, so a little help is not free: L1's sparsity -
        help where it is worth its price and exactly none elsewhere, where a squared cost would allow a little
        everywhere. It never makes a step worse than asking for nothing, so falling on purpose to stop paying is never
        the better deal. The price SETS ITSELF to hold the batch's mean applied gate at `share` (0.25) of the help
        available - a PI update after every batch (Stooke, Achiam, Abbeel 2020, the PID Lagrangian: the proportional
        term damps the overshoot of plain dual ascent):
            e = mean applied gate - share;  I = clamp(I + e, 0, price_max / k_i);  price = clamp(k_p e + k_i I, 0, price_max)
        k_p 0.5, k_i 0.05 (help used 0.25 over the share is priced at about 0.25 within ten batches), price_max 1 (help
        that costs a whole step's best reward). The share is of what is AVAILABLE, so the price climbs by itself as the
        cap falls: the same gate buys less help, the policy asks for more, the price answers - price up and cap down
        together, one schedule. The clamps are the windup guard (claude.md: a never-zero error winds an integrator to
        its limit): where the body truly cannot do without help, the price stops at price_max rather than growing
        without bound - and help whose use will not fall there marks the frames the body cannot follow (Stage F's
        question, answered for free). After the hour the price is frozen and not charged; the gate's output is read by
        nothing (and nothing at run time - the lab's show and RT7's demo run at cap 0).
      THE STATE AND THE OPTIONS - the price, its integral and the clock travel with the trainer's other counters in the
        weights file, so a resumed run continues where its help was; the log line gains cap, price, mean applied gate
        and mean kappa (`geno.RunLog`, `parseLine`). `PpoRecipe.wheels`: enabled, minutes, start_cap, share, price_max,
        k_p, k_i, policy_gated, spring, damping - checked by `PpoRun.problem` (minutes above 0, start_cap in [0, 1),
        share in (0, 1), and `assist_start` 0 when the wheels are on: one helping hand at a time). With the wheels on
        the policy has one more output, so weights without it are refused as a different shape, as a wider network is.
      THE JUDGE stays unhelped: the servo, `evaluate` and the lab's show all run at cap 0. During the hour the training
        batches measure a helped task, so the trainer also judges the policy with the help off every 5 training
        minutes of the hour and logs it, and the lab draws THOSE as the run's line until the hour ends (the helped
        batches stay in the log).
      THE A/B, from the lab (RT6): same seed and recipe, 3 hours each.
          0  no help (`assist_start` 0)
          1  today: the root assist, fading from 1 over 300 batches
          2  the body force on the clock, no gate and no price (`policy_gated` false: kappa = cap(s); the observation
             as arm 3's) - ZEST's force on Simon's schedule, which separates THE FORCE from THE GATE (an A/B that
             changes two things measures neither)
          3  the training wheels
        The verdict: minutes until the UNHELPED time to failure reaches 5 s, 10 s and 20 s; and no dip in arm 3's line
        as its hour ends (arm 1's may dip as its help drains - the lab sketch's "failures come back"). A second seed
        before adopting anything (I1b's rule); into `PpoRecipe`'s defaults only on a clear win.
      KNOWN ANSWERS: (1) THE FORCE - at rest on the reference with kappa 1 and no contact, every body's force is
        -m_b g and one step leaves every velocity zero (weightless); the reference rotated by a small theta about the
        centre of mass gives the angular acceleration 200 theta whatever the pose (the inertia cancels); the reference
        TRANSLATED gives no force at all - negative control: a planted spring on the centre of mass's position fails
        exactly this one; kappa 0 leaves the fleet bit for bit. (2) THE SIGN, the root assist test's shape: the servo
        alone at a constant kappa 0.6 ends fewer episodes than without. (3) THE GATE - an action of -0.5 applies
        nothing; the reward paid equals price x applied gate on a planted decision; with `policy_gated` false, kappa
        follows cap(s) exactly. (4) THE CAP - 0.6 at s 0, 0.3 at 0.5, 0 at 1 and after, slope zero at both ends; past
        the hour the fleet is the unhelped fleet bit for bit. (5) THE PRICE on planted use sequences - above the share
        raises it, below lowers it, never under 0 or over price_max, the integral never under 0. (6) A run stopped at
        minute 20 and resumed continues with the same price and cap.
      DONE WHEN: headless here, a tiny run with `minutes` 1 shows the cap reaching 0 at its first training minute, the
        price moving, the log's new columns, a resume mid-hour carrying price and cap, and the lab drawing its unhelped
        looks; on Simon's machine, the four arms' curves on the lab's plot. SIZE: 3 turns - the force and its tests;
        the gate, clock, cap and price in PPO; the trainer, log and lab.
      CARRIES TO R5: on SuperTrack's pathwise loss the price is one more differentiable term and the gate one more
        action the world model reads (R5.8's gym, "a curriculum from generous to human strength").

## 0. Standing rules (every turn)

**No test or run longer than 5 minutes (Simon, Sep 28).** A bench arm is at most 4-5 minutes; a comparison is made
at the iterations both arms reached. The long baseline is B1's 10-minute run: the bench is deterministic, so a build
with every new knob OFF reproduces B1's rows exactly - check that on 100 iterations before an A/B leans on it.

**Turn discipline:** small steps - record (plan, journal) and end before a turn grows; `C` continues. Anything over
~60 s runs DETACHED (`setsid nohup ... > /tmp/x.log`) and is POLLED to completion within the same turn (sleeps under
~110 s). After a stalled turn: inspect processes (by pid), changed files and the newest logs first. End every turn:
lint clean, `zig build check`, snapshot `zimr2307<letter(s)>.zip`.

**Build and test traps** (each bit us):
- `check` does NOT compile the example pages. When a `pub` signature changes: grep `examples/` for its callers, and
  smoke every page that imports the changed module before landing. (`geno_track` stayed broken from T3 until the
  Sep 27 review: `FailureCheck.init` had gained the body names.)
- A `-Dtest-filter` matching nothing compiles NO test bodies; filter on the test's own name.
- Tests inside a module compile only if a test root references them; only pages instantiate `Trainer(M)` - after
  changing a trainer, smoke the page.
- Insert a declaration ABOVE the next one's `///` comment, never between them (three times on Sep 27 a struct's
  documentation silently became another's).
- Zig: no declarations between container fields; list struct fields explicitly (no `@typeInfo(...).fields`);
  `std.math` only inside zimrmath; whole-init-first (a new field joins the whole-struct literal).
- Never the full `gate` per turn; targeted tests (`test-<stem>`, by name), then `check`. Pages in `release`, never `ship`.

**Writing lint-clean code the first time (Oct 3, Simon: "integrate the non-autofixable rules").** 10 rules autofix
(`fn-args-multiline`, `branch-braces`, `named-struct-init`, `prefer-vec`, `unused-global`, `redundant-import`,
`no-qualified-zm`, `no-qualified-std`, `float-from-int`, `prefer-decl-literal`); the other 44 need a person, so write
them right: EVERY LOCAL TYPED (`const x: T = ...`; captures and `float(...)` inits excepted); lines <= 120 columns
(name an intermediate instead of wrapping a long expression); declare file-scope names ABOVE their first use; a bare
`.init(...)` / `.create(...)` / `.alloc(...)` ONLY as the value of a declaration that names its type - spell `T.init`
in assignments, fields, arguments, returns; no locals or fns named after zm's core words (min, max, clamp, dot,
length, normalize, round, vec, lerp, ...); `@trunc` / `@floor` / `@round` straight to the int, no `@intFromFloat`,
no `@as(T, @round(x))`; `clamp(x, lo, hi)`, never `@max(@min(...))`; `sinTurns` / `cosTurns` when the argument
holds a pi or tau; no `!` on a fn that cannot fail; never swallow an error silently (`catch {}` needs an explained
`lint:off`); `assertUnreachable(@src(), ...)`, not `assertf(false, ...)`; std / builtin imports at file scope; a
fn returns a NAMED struct; snake_case file-scope value consts; no std.math / std.debug.assert / std.debug.print
outside their homes; ASCII comments and test names. Std / zm names used more than once get a file-scope binding.
**The edit loop dogfoods the linter:** after writing, `zimrlint --fix` on the touched files (the autofixes do their
job), then check mode with the enforced rules - what remains is mine to fix. `zig build check` does the same by
default since Oct 3 (`-Dautofix` on: lint --fix -> zig fmt -> lint -> compile). **Logs:** capture stdout and stderr
SEPARATELY (or through a pipe) - with `> file 2>&1` the build runner's summary overwrote the linter's findings at the
start of the file, and they looked missing. Delete a log before a background run polls it, or the poll reads the
last run's `rc`.

**The tutorial is a course (Oct 3, Simon: "make it a course with diagrams").** zimrnum's chapter 18d opens with
18d.0, the whole agent drawn once, and every later section fills one box: what it is, how to use it, the intuition,
an example worked through with numbers, a figure. Figures are inline SVG in `<figure>` (currentColor; accents via
`style="fill:var(--tok-type)"` etc.; a unique marker id each; one `<path>` per arrow), RENDERED AND LOOKED AT before
they ship (`src/notes/scripts/render_figures.py`, Playwright) - and checked again on the built page. The code
comments carry the same diagrams in ASCII and the same worked numbers, so they stand on their own.
TONE (Oct 3, Simon): comments and tutorial read like a professional book - simple and neutral. No development
anecdotes, no plan or turn numbers, no humour, no capitals for emphasis in sentences (capitalised headings are fine),
and none of the constructions that sound clever: "it's not X, it's Y", "X and its proof", "a test that can fail",
"which is the point", "exactly", "bit for bit" in prose. State what the code does and why, with worked numbers.

**NEXT: THE SPLIT - `src/zimrrl.zig` (module `zrl`) AND `zimrrl-tutorial.html`. Before B5b.**

WHY. zimrnum is 40,907 lines; its reinforcement-learning part is a separate subject with its own users (robot BMPC,
the gym / DReCon, SuperTrack's cartpole, the GPU RL rows, the cartpole_duel example). Its own module gives RL its own
tutorial, reference table and gate, and leaves zimrnum as numerics and generic deep learning.

THE LINE. A declaration moves when its doc or signature is about agents: environments and their tasks, rewards,
returns and advantages, policies and critics, exploration, replay and rollouts, the PPO / SAC / TD3 / DQN / AWR / BMPC
algorithms, world-model losses and planners. Distributions, statistics, losses that have an autograd operation,
layers, optimisers, schedules and tensor operations stay, even when only RL uses them today. The inventory is
`python3 src/notes/scripts/zimrrl_split_analysis.py` (MOVES and STAYS inside, each borderline call with its reason).
It classifies by references, not by position: a test block moves when its code (comments stripped) uses a moved
name; a private helper moves when only moved code uses it; it fails loudly if anything that stays uses a moved name.

MEASURED (Oct 3):
  - moving: 58 public declarations, 29 private helpers (fixtures, test constants, cartpoleShootingMpc), 94 of the 333
    zimrnum tests, about 9,470 lines;
  - stays, decided by the code: `ppoClipSample` and `ppoClipObjective` (Graph's PPO operation calls them, at
    zimrnum.zig ~13589 and ~14482, and a GPU kernel calls the first); `squashCorrection` (the tanh change of
    variables; GPU kernels call it); `CategoricalScalar`, `RunningScale`, `klRobustExpectation`, `gatherColumns`,
    `clipGradNorm`, `emaUpdate`, `stepParameters`, the distributions (`DiagGaussian`, `Categorical`, `categorical`)
    and `entropyRows`;
  - nothing that stays uses a moved name (checked; without the two PPO losses kept, `Graph` would have);
  - the moved code uses 64 public zimrnum names (zimrrl binds them at file scope, so moved bodies need no rewriting)
    and 2 private helpers that become `pub` in zimrnum: `ownedTensor`, `addPointMassToGrid`. Every other private
    name it uses is a std / zm alias that zimrrl declares itself.

THE MODULE. `src/zimrrl.zig`, build module "zrl", first line `//! lint:alias zrl`. The linter's `canonical-alias`
rule matches an import string against a declaring file's stem OR its declared alias, so with the module named after
the alias, `const zrl = @import("zrl");` is enforced with no linter change (the alias table is read from the heads of
the linted files: zimrrl.zig must be in the lint file list). Imports: std, zm, zn. zimrnum never imports zrl: the zn
module gets no zrl import in build.zig, so an attempt does not compile. The closure stays shader-free, so zrl is a
`test-fast` root like zn.

THE USERS. `zn.<moved>` -> `zrl.<moved>` plus the import, in: robot_bmpc.zig, robot_gym.zig, robot_supertrack.zig
and robot_mocap_tutorial.zig (the cartpole environment), gpu_learn_tests.zig, src/gpu/zn_binary.zig (cartpole step,
discriminatorReward), src/gpu/zn_conformance.zig (cartpoleStepBatch, discriminatorReward),
src/shaders/zn_rl_gpu_probe.zig, examples/cartpole_duel/cartpole_duel.zig; robot-mocap-tutorial.html quotes 32 moved
names (doc-sync checks those quotes against the source) and links `zimrnum-tutorial.html#wm-replay`. robot_bmpc.zig
keeps `zn.` for CategoricalScalar, RunningScale and clipGradNorm.

THE DIRECTION, ON THE CPU AND ON THE GPU (Oct 3, after Simon's question about PPO in Graph and RL on the GPU).
Generic code never knows an RL algorithm; RL code uses generic code. Two places broke this and are fixed in the split:
  - Graph had one algorithm-named node kind among 30, `ppo_clip` (its forward calls `ppoClipObjective`). PPO's loss
    becomes a composition of generic nodes in zrl: r = exp(log p_new - log p_old), objective = min(r A, clamp(r,
    1 - eps, 1 + eps) A) with clamp as min / max nodes, loss = -mean. Its gradient is PPO's: inside the clip range the
    two branches are the same function; outside it `min` routes the gradient to r A or to the clamped branch, whose
    gradient is zero. The distribution helpers (`klGaussianDiag`, `diagGaussianLogProb`, `squashedReparameterize`) are
    already compositions. After this Graph names no algorithm (stage S0b).
  - zimrnum's GPU half `src/gpu/zn_binary.zig` holds 4 RL kernels among its 40: `cartpole_step`, `cartpole_pole`,
    `ppo_clip`, `disc_reward` (`squash_correction` is the generic tanh formula and stays). They move to zrl's GPU half,
    `src/gpu/zrl_binary.zig`, declared with a `wants_zimrrl` flag beside build.zig's `wants_zimrnum`; only such
    kernel modules receive the zrl import, so the build enforces that `src/gpu/zn_*.zig` never imports zrl (S1b).
GPU training today uses hand-written kompute kernels (the MLP kit `zn_mlp`, `zn_train`), run by `compute_host` on the
CPU or the GPU from one source; there is no GPU autograd. Bringing SuperTrack and BMPC fully onto the GPU keeps this
shape: MLP forward / backward, Adam, SimNorm, two-hot, softmax cross-entropy and the Gaussian KL are generic kernels
(zimrnum's half); the world-model rollout and losses, value targets, policy distillation, MPPI (sampling, scoring
through batched forwards, top-k, refit), replay sampling and write-back, reanalyze and the cartpole environment are
zrl's half; the humanoid's physics is robot.zig's, and GPU-resident physics would be robot work. A fused kernel that
mixes generic maths with an RL formula lives in zrl's half.

STAGES. Each leaves the tree green and is verified before the next.

  S0 - Baseline and doc fixes (no move). DONE Oct 3: the two doc blocks moved to their owners (`saveParameters`,
  `PpoStats` - both had no doc of their own); the header's sweep paragraph states its five RL rows; the baseline
  recorded by name (src/notes/scripts/zimrrl_split_baseline.py -> src/notes/zimrrl_split_baseline.txt: 439 public
  declarations, 333 tests, 784 reference rows; folds 346). Four public declarations have no doc: cartpoleOutcome and
  ppoEpoch (write before they move, in S0b), Dense and saveTensors (later).
    - Record the baseline into `src/notes/zimrrl_split_baseline.txt` (a script): zimrnum's public names, its 333 test
      names, the reference-table rows (784), the source folds (344), test-fast (robot 631, zn 333), check (360), gate
      (406).
    - Fix two orphaned doc fragments the move would otherwise carry to the wrong owner: the StateDict paragraph at the
      top of `Categorical`'s doc (zimrnum.zig ~22818) and the PPO-report paragraph above `MinibatchOrder`'s (~24326).
    - Correct zimrnum's header: the CPU/GPU sweep does include RL rows now (ppoClipSample, the cartpole step, the
      discriminator reward), and say which library each comes from after the split.

  S0b - PPO leaves Graph. DONE Oct 3: `PpoClipLoss(T)` (build / setInputs) composes the loss from exp, sub, mul,
  min, scale, transpose and reduceRows; checked against the fused node before deleting it (value and gradient to
  1e-12, inside the range and in all four clipped regimes; a wrong upper bound fails it); Graph's `ppo_clip` kind, its
  `constants` field, `ppoClipLoss` and `setPpoClipInputs` removed; PpoModel.clip_loss is a PpoClipLoss; ppoUpdate,
  robot_gym (3 sites), the tests, both tutorials and the reference notes ported. Inputs are now [N, 1] or [1, N]
  (rank-1 refused). The analysis with the PPO loss family in MOVES: 61 public, 30 private, 95 tests, no blockers.
  test-zimrnum 333/333, test-fast (robot 631), check 360/360, doc-sync. Disk: the build cache reached 7.7 GB and the
  disk 98% - a full disk shows as "checking cache failed: FileNotFound"; clear .zig-cache when free space is low.

  (S0b as planned:)
    - `PpoClipLoss(T)` in zimrnum for now (it moves in S3): `build(graph, log_prob_new, log_prob_old, advantages,
      clip, allocator)` composes the loss from generic nodes over two constant tensors it owns; `setInputs(log_prob_old,
      advantages)` refreshes them (replaces `Graph.setPpoClipInputs`).
    - Known answers FIRST, against the fused node while it still exists: equal loss and equal gradients (to ~1e-12)
      with ratios inside the range, above 1 + eps with A > 0, below 1 - eps with A < 0, and at the boundary.
    - Then remove the node kind `ppo_clip`, `Graph.ppoClipLoss` and `Graph.setPpoClipInputs`; switch robot_gym.zig (2
      call sites), `ppoUpdate` and the tests; the tutorials (zimrnum 21 mentions, robot-mocap 2 - doc-sync checks).
    - Docs for `cartpoleOutcome` and `ppoEpoch`.
    - Then the analysis script moves `ppoClipSample`, `ppoClipObjective` and `PpoClipLoss` from STAYS to MOVES and must
      still report no blockers.

  S1a - zrl as a facade: callers switch, no code moves. DONE Oct 4, gate 410/410: src/zimrrl.zig
  re-exports the 61 moving names (generated from the analysis's MOVES list, in nine subject groups); build.zig defines
  the `zrl` module (imports zm, zn), carries it in both module structs, and imports it beside the eight non-kernel zn
  sites; the callers switched by script (cartpole_duel, zn_conformance, gpu_learn_tests, robot_bmpc, robot_gym,
  robot_mocap_tutorial, robot_supertrack; robot-mocap tutorial 32 quotes). The GPU probe (src/shaders/
  zn_rl_gpu_probe.zig, compiled to SPIR-V by the raw command line) stays on zn until S1b, with zn_binary. A comment in
  src/gpu/zn_mlp.zig quoted by the robot-mocap fold named `zn.Temperature` and now names `zrl.Temperature`.
  test-fast (1171 / 1260, unchanged), check 360/360, doc-sync.

  (S1a as planned:)
    - src/zimrrl.zig: header (alias, dependency rule, scope), `const zn = @import("zn");`, and
      `pub const X = zn.X;` for the 58 moving names.
    - build.zig: `const zimrrl_mod: *Module = b.addModule("zrl", .{ .root_source_file = b.path("src/zimrrl.zig") })`
      next to zn's (build.zig ~3093), importing zm and zn; `addImport("zrl", zimrrl_mod)` beside EACH of the 9
      `addImport("zn", ...)` sites (an unused import costs nothing - Zig analyses lazily - and no site can be missed);
      the raw command line at build.zig ~6170 gains `--dep zrl` and `-Mzrl=src/zimrrl.zig`, preceded by zrl's own
      `--dep zm --dep zn`.
    - A script switches every user listed above except src/gpu/zn_binary.zig (S1b), and the robot-mocap tutorial's
      quotes.
    - Verify: test-fast counts unchanged, check, doc-sync, lint (canonical-alias), then the gate once (it compiles the
      GPU modules, the probe and the examples).
    After S1a every caller uses its final spelling, so S3 touches no caller.

  S1b INVENTORY (Oct 4, read-only, taken while the S1a gate ran). GPU kernel files and their entries:
    zn_unary 65, zn_matmul 4, zn_train 8: all generic, stay.
    zn_binary 40: RL -> zrl's half: cartpole_step, cartpole_pole, ppo_clip, disc_reward. squash_correction stays.
    zn_mlp 35: 13 are not generic:
      - PPO for a Gaussian policy and SAC, dispatched by robot_gym.zig -> zrl's half: ppo_mean_grad, ppo_logstd_grad,
        squash_fwd, squash_logp, squash_bwd, squash_logstd_grad, sac_target, alpha_grad;
      - SuperTrack's own passes, dispatched only by robot_supertrack.zig -> the third home, the robot's GPU code
        (SuperTrack's CPU code is robot_supertrack.zig; specialised robot code lives with the robot): st_policy_fwd,
        st_policy_bwd, st_world_fwd, st_world_bwd, cp_track_bwd.
    Apps attach kernel files per basename with the entries they use (build.zig ComputeKernel): zimrnum_field attaches
    zn_binary; cartpole_duel, geno_ppo, geno_train, getup_train and track_train attach zn_mlp. `wants_zimrnum` is
    opt-in per kernel because Zig rejects a --dep for a module the file does not import, so `wants_zimrrl` must be
    opt-in per kernel too. To check in S1b: whether CPU-backend callers name the kernel module (`zn_mlp.<entry>`) - if
    so, moving an entry changes those references as well as the build lists. Checked: outside src/gpu only
    `zn_mlp.acts_len` (a helper) and `zn_binary.kernels` (the table the sweep page iterates) are named; the training
    examples import `zn_mlp` (geno_train, geno_ppo, getup_train, cartpole_duel, track_train) and zimrnum_field imports
    `zn_binary`. Still to read in S1b: how a dispatch finds its entry (through the module value?), and the sweep page
    iterating the RL kernel table as well.

  S1b SCOPE, DECIDED Oct 4 after reading the dispatch. `compute_host.Compute(M)` takes ONE kernel module: a trainer
  (robot_gym's `Trainer(zn_mlp)`) dispatches generic kernels (dense_fwd, mse_bwd, adam) and its RL kernels
  (ppo_mean_grad, ...) through one pipe, recorded as one submission per minibatch. So:
    - zn_binary's 4 RL kernels move NOW (S1b): they call `zn.cartpoleStep`, `zn.discriminatorReward`, ... whose home
      becomes zrl in S3, so leaving them would make zn's GPU half import zrl. Only the CPU/GPU sweep dispatches them
      (zn_conformance's rows; zimrnum_field's one pipe per kernel file and `coverEvery(<file>.kernels, ...)`), so the
      move is contained: a fifth sweep pipe, `Compute(zrl_binary)`.
    - zn_mlp's 13 kernels (8 PPO / SAC, 5 SuperTrack) stay for now. They import only kompute and zm - no edge to zrl,
      so the import direction holds - and moving them needs one dispatchable set built from several kernel files
      (or two pipes per trainer, splitting its single submission). That is its own stage, S4b KERNEL SETS: design how
      `Compute` serves entries from several files; then move the 8 to src/gpu/zrl_mlp.zig and the 5 to the robot's
      GPU code. Until then the RL kernels in zn_mlp are a known exception, listed here.

  S1b-1 DONE Oct 4: the build knows `wants_zimrrl`. build.zig `ComputeKernel.wants_zimrrl` (opt-in, default false);
  the kernel's Zig module gets `zrl` when set; `ShaderPipeline.addCompute` / `addComputeKernelImports`
  (src/shader_codegen.zig) take `wants_zimrrl`: the kernel's own list gets `--dep zrl`, `-Mzn` is defined whenever
  either flag is set (zrl imports zn), and `-Mzrl=src/zimrrl.zig` is defined with `--dep zm --dep zn`. No kernel sets
  it yet; check 360/360. The SPIR-V path for it is first exercised by S1b-2's gate.

  S1b-2 DONE (Oct 4). Steps 1-2 done on disk, T0 and T1 clean - src/gpu/zrl_binary.zig written (216 lines:
  the copied ABI, `g` and the three bindings the kernels use, the 4 kernels with `zrl.`, the sacTarget note, the table,
  the installKernel trailer); zn_binary.zig lost them and points to the new file. Found and fixed on the way: three
  generic kernels' docs (bcast_add, mesh_grid_x, slice_columns) had been stranded above cartpole_step's doc; each is
  back above its owner. Steps 3-4 done on disk, T0 and T1 clean: build.zig attaches zrl_binary (wants_zimrrl) to
  zimrnum_field; the page has `pipe_rl`, its uploads, coverage, the three switch arms and a compile-time check that
  zrl_binary's Buffers / Params match zn_binary's; conformance `Kind.rl_binary` on the 4 rows. Step 5 done: the probe imports zrl;
  its raw command line lists zrl and defines zn and zrl. Step 6, verified: zn-rl-gpu (the probe compiles to SPIR-V
  through zrl), test-fast, check 360/360, the gate 410/410 - and, because THE GATE DOES NOT BUILD THE SWEEP PAGE (no
  WGSL newer than zrl_binary.zig appeared), `zig build smoke-install -Dfocus=zimrnum_field` 528/528: the four kernels
  compiled to WGSL through `wants_zimrrl`, and the page's compile-time checks ran. That build first failed: the layout
  check used `@typeInfo(T).@"struct".fields`, and this toolchain's Type.Struct has parallel `field_names` /
  `field_types`; rewritten. Control: renaming a zrl_binary Buffers field fails the page with the check's own message.
  zimrnum-ref regenerates the tutorial unchanged.

  S1b-2 - the move, in this order:
    1. src/gpu/zrl_binary.zig: header (zrl's elementwise kernels: the cartpole step and pole, PPO's clipped sample,
       the discriminator reward); imports kompute, zm, zrl (and zn only if a kernel uses a name that stays in zn);
       `config`, `Buffers`, `Params` copied from zn_binary.zig unchanged (the sweep binds every binary file the same
       way); a `kernels` table of its 4 entries; the 4 kernel functions moved with their docs, `zn.<moved>` ->
       `zrl.<moved>`.
    2. zn_binary.zig: the 4 kernels and their `kernels` rows removed; its header says where they went.
    3. examples/zimrnum_field: build.zig attaches zrl_binary (its 4 entries, `wants_zimrrl = true`, plus
       `wants_zimrnum` if step 1 needs zn); the page gets a pipe `Compute(zrl_binary)` and `coverEvery(zrl_binary.kernels,
       ...)`, and a comptime check that zrl_binary's Buffers and Params match zn_binary's field by field.
    4. src/gpu/zn_conformance.zig: `Kind` gains a member for the new file; the 4 rows use it.
    5. src/shaders/zn_rl_gpu_probe.zig: its moved names spelled `zrl.`; the raw command line that compiles it
       (build.zig ~6170) defines `zrl` and lists it.
    6. Verify: T0 / T1 on every touched file; test-fast (the conformance rows' CPU side), check, then the gate (it
       compiles zrl_binary to WGSL through the new path and builds the sweep page).

  S1b - zrl's GPU half (as first planned; the scope above replaces its zn_mlp part). (NEXT)
    INVENTORY FIRST, BY READING EACH KERNEL (Oct 4): the first count (4 kernels in zn_binary) only searched files that
    import zn. Scanning every src/gpu/zn_*.zig for kernels whose names or docs speak of agents finds, in zn_binary:
    cartpole_step, cartpole_pole, ppo_clip, disc_reward (squash_correction is the generic tanh formula; adam_step_warm
    and polyak_follow are generic training); and in zn_mlp.zig (the MLP kit): sac_target, alpha_grad, squash_logp,
    squash_bwd, squash_logstd_grad, min_route, cp_force, lat_gather, lat_act, lat_act_bwd, st_policy_fwd,
    st_policy_bwd. Classify each into three homes: zimrnum's GPU half (generic arithmetic), zrl's GPU half
    (reinforcement learning), or the robot's own GPU code (SuperTrack-specific: st_*, lat_* - the robot's world model
    and policy). Record who dispatches each (the apps' kernel lists, compute_host users, the examples) before moving
    any.
    - src/gpu/zrl_binary.zig: the 4 RL kernels moved out of zn_binary.zig (`cartpole_step`, `cartpole_pole`,
      `ppo_clip`, `disc_reward`), calling `zrl.` formulas; build.zig gains `wants_zimrrl` beside `wants_zimrnum`
      (kernel_mod.addImport("zrl", ...) only for those); every app whose kernel list names these entries lists the new
      module; zn_conformance.zig's rows for them dispatch to it.
    - Verify: the CPU backend of the sweep in test-fast, then the gate (it compiles the kernels to WGSL and builds the
      sweep page).

  S2 - The doc tooling generalised (no output change). DONE Oct 4: tools/zimrnum_ref.zig has a `Library` table
  (alias, source_path, page_path, optional sweep_path; configured with zn only), `Parsed` (source read, declarations
  extracted), and `documentLibrary` (main's old per-page body, comments kept); main parses every library first, then
  documents each page, then reports duplicate notes once. `insertSourceFolds` takes every parsed library and matches
  each alias, keying folds by (library, name), so a page can fold and arity-check calls into any library;
  `kernelsFor` and `extractDeclarations` take the alias and the path. Verified: three runs, each reproducing
  zimrnum-tutorial.html byte for byte (785 rows, 348 folds); lint clean; check 360/360. To add zrl in S3: one more
  `libraries` entry.
    - tools/zimrnum_ref.zig: a table of libraries {alias, source, page, sweep (optional)}. Per page: its own reference
      table; folds and call-arity checks for every library the page names. Configured with zn only.
    - Verify: `zig build zimrnum-ref` reproduces zimrnum-tutorial.html byte for byte.

  S3 - The move (scripted, re-runnable from the S2 snapshot; no hand edits to moved code - every fix goes into the
  script). (NEXT) Done in three sub-steps, each recorded here before the next:
      S3a DONE (Oct 4): src/notes/scripts/zimrrl_split.py; its dry run (`--dry-run /tmp/split`) passes every
            invariant - 61 public, 30 private, 95 tests, 9,560 lines moving; zimrnum keeps 238 tests and 380 public
            names, zimrrl gets 95 and 61 (380 + 61 = 441 = the 440 before plus addPointMassToGrid, now public);
            test names conserved; no moved name left in zimrnum; nothing in zimrrl used above its declaration.
            Fixes found by the dry run, all inside the script: a private helper whose code uses a moved name moves
            (a fixture and its tests otherwise waited for each other); R02 REPLAY and R03 ROLLOUTS, RETURNS AND
            ADVANTAGES grouped by dependency, each layer sorted topologically; the two SequenceReplay tests' local
            `length` renamed `window_length` (zimrrl does not shadow zm's words); moved one-line std / zm aliases
            join zimrrl's alias block; `ownedTensor` (a one-line test helper) is copied, not published. The
            outputs pass zig fmt and ast-check; after `zimrlint --fix` (22 fixes: zm keywords bound once at file
            scope - cosRad, sinRad, pi, radFromDeg - and unused aliases dropped) both lint with 0 findings.
      S3b DONE (Oct 4). The split is applied: src/zimrnum.zig 31,350 lines, 238 tests; src/zimrrl.zig 9,891 lines,
            95 tests; `src/zimrrl.zig` is a fast test root (`test-zimrrl`, in test-fast). zimrnum's reference table
            649 rows (the moved ones gone; addPointMassToGrid and DiagGaussian.half_log_tau added with notes), 305
            folds - the RL chapters still in zimrnum's tutorial have lost their folds until S3c moves them. Two
            compile errors the analysis could not see - Zig lets a file read a type's private members only from
            inside that file: zrl read `DiagGaussian(f64).half_log_tau`, and zimrnum's `numericalGrad` called
            `PpoClipEval.loss`; both made pub, by rules in the script. Verified: test-zimrrl 95/95, test-zimrnum 238/238,
            test-fast 19/19, check 360/360; and re-running the pipeline (apply, `zimrlint --fix`, `zig fmt`) from the
            backups reproduces both files byte for byte.
      S3c-1 DONE (Oct 4). zimrnum: the tutorial check is `pub fn expectReferenceTableMatches(html, source)` (one
            definition; zimrnum's test is a one-line call). zimrrl.zig: its tutorial check through that helper, an
            ASCII scan and the suffix scan (the leaked-names scan guards zimrnum's own past renames and stays
            there). src/notes/tutorials/zimrrl-tutorial.html: header, chapter 1 (what zimrrl is), chapter 2 the
            generated reference table (139 rows); zimrnum_ref's `libraries` has the zrl entry; the page is in
            build.zig's doc-pages. Notes added: expectReferenceTableMatches, loss (PpoClipEval's). Verified:
            test-zimrnum 238/238, test-zimrrl 98/98, doc-pages 32/32, check 360/360; control: removing CartpoleState's
            row fails zrl's check by name. Found, for S4: the generator reports 18 names with more than one note
            (slice exp log softplus elu silu gelu conv2d klGaussianDiag reshuffle observe step add ...), only the
            first of each rendering. From here on zimrrl.zig is edited directly.
      S3c-2 DONE (Oct 4) - S3 COMPLETE, THE SPLIT IS DONE. src/notes/scripts/zimrrl_tutorial_split.py moved
            chapters 16, 18b, 18d and sections 11.24, 11.25 to zimrrl-tutorial.html as chapters 2 (building blocks,
            with 2.13 / 2.14), 3 (training policies) and 4 (world models, 18d.k -> 4.k, the course map its unnumbered
            opening); reference is chapter 5. zimrnum keeps pointers with the old ids and numbers; its title no
            longer says RL; cross-page links retargeted; a pre-existing dangling link (#polyak) fixed;
            robot_bmpc.zig's header and 8 references -> chapter 4; robot-mocap's link -> zimrrl. Folds: 285 + 63 =
            348, the total before the split. Verified: zimrnum-ref idempotent, test-zimrnum 238/238, test-zimrrl 98/98,
            doc-sync, doc-pages 32/32, check 360/360, test-fast 19/19, the focused sweep page 528/528, the gate
            412/412; on the built zrl page all 11 figures are present with renumbered labels.
      S4 - LATER, each on its own: test names "zn rl: ..." -> "zrl: ..."; kernel sets, then zn_mlp's 13 RL kernels to
            zrl's GPU half and the robot's; close the gaps in zimrnum's chapter numbers (16, 18b, 18d are pointers);
            a tone pass over the moved chapters' headings (e.g. "a unit error with no symptom"); the 18 names with
            more than one reference note.
      RL TUTORIAL ORGANISATION (Simon, Oct 4: "read it all, find the best organisation, make it read well as a whole")
      - IN PROGRESS, before B5b. Read in full (chapters 2-3 ~7,600 words; chapter 4 is the recent BMPC course and
      already flows). Findings: chapters 2 (old reference notes) and 3 (newer teaching) treat the same topics twice -
      terminal/truncated three times (2.1, 2.14, 3.3), PPO's clip three times (2.2, 2.9, 3.5), replay (2.3, 3.4) and
      cartpole (2.4, 3.13) twice; 2.5 mixes an end-to-end test story with the PpoClipLoss passage; chapter 2 carries
      development history (znum comparisons, the turns-vs-radians story, a review's "61% identical") and testing
      detail. DESIGN - follow the library's layers, as a course (chapter 3's teaching flow is the spine):
         1 What zimrrl is (+ how the tutorial is organised)
         2 A first agent: 3.1 the shape of a run, 3.2 a first policy
         3 Environments and episodes: 2.4 cartpole (history removed), 3.13 two tasks, how an episode ends (2.14 + 3.3)
         4 Experience: rollouts and replay (3.4 + 2.3), advantages / GAE (2.6 + 2.1), minibatches (2.13, cleaned)
         5 Policies: 2.7 distributions, 3.8 sampling vs training, 2.8 squash, 3.12 attention over a scene
         6 On-policy: PPO and the clip (3.5 + 2.2), the objective as a loss and its two numbers (2.9 + 2.5's PPO part),
           3.7 AWR
         7 Off-policy: 3.6 the loop, 2.10 DQN, 2.11 SAC and variants, 2.12 TD3
         8 Imitation and tracking: 3.9 adversarial, 3.10 differentiating a gradient, 3.11 tracking rewards and DTW
         9 World models and planning: chapter 4 as it is (4.k -> 9.k)
        10 Reference
      2.5's end-to-end test story is dropped (testing detail). Section ids are kept; a merged section keeps the
      absorbed section's id as an extra anchor. Headings lose their clever second halves ("..., and a unit error with
      no symptom"). STEPS: (1) restructure by script - moves, chapter openings, headings, numbering, contents,
      robot_bmpc.zig's references (4.k -> 9.k), zimrnum's pointers; verify; (2) merge the duplicates; (3) a prose
      pass for tone and transitions, chapter by chapter.
      STEP 1 APPLIED (Oct 4; backups in /tmp/big/org): src/notes/scripts/zimrrl_tutorial_reorganise.py - ten chapters,
      sections moved whole by id (duplicates adjacent: cartpole + rl-tasks, truncation + rl-truncation, rl-collect +
      rlreplay, gae + rlgae, rl-ppo + rlppo), headings retitled, the world-model chapter 4.k -> 9.k (prose and figure
      labels, not attribute values), contents regenerated, robot_bmpc.zig's references -> 9.k, zimrnum's pointers
      updated (minibatchorder's pointer says 4.5 - it becomes 4.3 after step 2's merges). VERIFIED: zimrnum-ref (zn 650
      rows / 285 folds, zrl 139 / 57 - the dropped section's 6 folds gone), test-zimrnum 238/238, test-zimrrl 98/98,
      doc-sync, doc-pages.
      STEP 2 APPLIED (Oct 4; backups in /tmp/big/merge): src/notes/scripts/zimrrl_tutorial_merge.py - four merged
      sections (3.3 how an episode ends, 4.1 rollouts and replay, 4.2 GAE with the recurrence, 6.1 PPO's clip), each
      keeping the absorbed id as an anchor; ppoClipSample's quote matches the source again; minibatchorder 4.3 and
      zimrnum's pointer with it. VERIFIED: zimrnum-ref (zrl 139 rows, 56 folds - the duplicated Transition example
      is quoted once), test-zimrnum 238/238, test-zimrrl 98/98, doc-pages 32/32.
      STEP 3, WIDENED (Simon, Oct 4: "reduce the tutorial by 20%: cut less interesting details and dev anecdotes;
      tone more neutral and precise; maybe add diagrams"). Baseline (prose words, folds / code / figures / reference
      excluded; measured by src/notes/scripts/tutorial_measure.py): 13,797 words, 512 code lines; target
      <= 11,040 words. Chapter words: 1: 237, 2: 359, 3: 939, 4: 941, 5: 1,175, 6: 1,092, 7: 1,288, 8: 1,328,
      9: 6,438. Plan: about 30% from chapters 3-8 (anecdotes and test details live there), about 15% from 9 (detail,
      after reading it); diagrams where they carry intuition - the run loop (2.1), terminal vs truncated on a
      timeline (3.3), the GAE recurrence (4.2), PPO's clipped objective against the ratio (6.1). Progress per chapter
      is recorded below as it lands.
      LANDED (Oct 4; backup of the page before step 3 in /tmp/big/trim; section bodies replaced by
      src/notes/scripts/tutorial_replace_section.py PAGE DIR, one DIR/<id>.html per section): chapter 2 359 -> 290
      words, the run-loop figure replaces the table; chapter 3 939 -> 655, cartpole without the history, the two
      tasks condensed, 3.3 with the terminal / truncated timeline figure. Chapter 4 941 -> 769: minibatches as three
      plain rules (the review figures and the test aside gone), GAE tightened. TOTAL 13,797 -> 13,272 words; code
      512 lines, unchanged. Verified: zimrnum-ref, test-zimrrl 98/98, doc-pages.
      Chapter 5 1,175 -> 863 (each section around its unchanged code; TOTAL 12,960). Chapter 6 1,092 -> 851: the
      PPO clipped-objective figure in 6.1 (two panels, A > 0 and A < 0, band shaded, unclipped branch dashed) replaces
      6.2's pessimism subsection; AWR tightened. Figures now write var(--tok-type, currentColor) so a figure draws
      even without the page stylesheet. TOTAL 12,719 (-1,078); code 510 lines. Still to cut ~1,680.
      Chapter 7 1,288 -> 988 (measured blocks stated as expected values; 7.1 retitled "The off-policy loop";
      DQN's terminal subsection dropped, 3.3 covers it). TOTAL 12,419.
      Chapter 8 1,328 -> 880 (8.2's testing subsection and conversational framing gone; its three backward rules one
      aligned block). TOTAL 11,971 (-1,826, -13.2%); code 504 lines.
      Chapter 9 in progress: 9.9 750 -> ~420 (the segment comparison is two sentences and a link to robot-mocap; the
      write-back mechanics left to the code). 9.2-9.4 and 9.8 tightened (9.4's finished-window paragraph points to
      9.9). A pre-existing orphan `</div><!--/zn-source-->` in 9.3 (from the old zimrnum chapter 18d) removed - fold
      markers now balance. 9.10, 9.11, 9.15, 9.20 and the chapter opening tightened (the opening said "zimrnum's
      building blocks" - they are zimrnum's and zimrrl's now).
      THE PASS IS DONE (Oct 4): 13,797 -> 11,034 prose words (-20.0%); code 512 -> 504 lines (measured-output blocks
      stated as expected values; the numeric pessimism example replaced by the PPO figure). Three new figures - the
      run loop (2.1), terminal vs truncated (3.3), PPO's clipped objective (6.1); every theme colour in the page's
      figures now has a currentColor fallback. All 120 in-page links and the cross-page links resolve; zimrnum-ref
      (56 folds), test-zimrrl 98/98, test-zimrnum, doc-sync, doc-pages green; figures checked on the built page.
      Source comments in zimrrl.zig still carry the old history (znum, etc.) - a separate pass (S4).
      Was: then 7-8 (8.2's testing subsection; SAC and DQN tightened),
      then chapter 9 (read for detail; about 1,000 words). Still to cut: about 2,240 words to reach 11,040.
      Was: STEP 3 - the prose pass, in this order: chapter 3's cartpole (the znum comparisons and the turns story
      out; keep why the step is pure, why reset is its own call, the named state, radians, semi-implicit Euler);
      4.3 Minibatches (the review figures and "caught by the test" out; keep the short stride, the per-draw index,
      reshuffle from identity); 3.1 / 3.2's "zimrnum gives you" where the pieces are zimrrl's; 6.1's three orderings
      against 4.3 (one place for the short stride); 8.2's testing subsection; then each chapter opening against its
      sections, and the transitions between sections.
      Was: STEP 2 - merge the adjacent duplicates, each into the first id with the second kept as an extra anchor:
        3.3 truncation + 3.4 rl-truncation; 4.1 rl-collect + 4.2 rlreplay; 4.3 gae + 4.4 rlgae; 6.1 rl-ppo + 6.2 rlppo;
        then zimrnum's minibatchorder pointer -> 4.3. (3.1 cartpole and 3.2 rl-tasks are not duplicates.)
      STEP 3 - prose pass, chapter by chapter: development history and testing detail out (cartpole's znum and
        turns story, MinibatchOrder's review and "caught by the test", 9.x none expected), "zimrnum gives you" ->
        zimrrl where the pieces moved, transitions between sections, each chapter opening checked against its content.
      ZNUM HISTORY REMOVAL (Simon, Oct 4: "remove all mentions of znum history in source and tutorials") - IN
      PROGRESS, before B5b. Inventory: 371 lines in 14 files (zimrnum-tutorial 111, zimrnum.zig 106,
      tools/zimrnum_parity.zig 71, zimrrl.zig 25, zimrrl-tutorial 17, zimrnum_ref.zig 14, kompute 7, zimrmath 5,
      zn_unary 5, files.html 4, build.zig 3, the probe, zn_matmul, zn_binary 1 each). Development notes (*.md under
      src/notes: the plan, journal, znum_mapping, zimrnum_plan, claude.md) are the log and stay; files.md is the file
      index and is updated. A comparison is REWRITTEN to explain the design directly, never just deleted.
      STEPS: (1) delete tools/zimrnum_parity.zig and its build step (its purpose is parity with znum), then
      build.zig, the small files, files.md / files.html; (2) zimrrl.zig, then regenerate and clean zimrrl's tutorial;
      (3) zimrnum.zig; (4) zimrnum's tutorial. Verify after each: lint, test-zimrnum / test-zimrrl, check, doc pages.
      STEP 1 DONE (Oct 4; backups in /tmp/big/znum1): tools/zimrnum_parity.zig and its build step deleted;
      build.zig (doc-sync's stranded comment moved to its code), kompute.zig and zimrmath.zig (provenance markers),
      zn_unary / zn_binary / zn_matmul (256 = the largest workgroup WebGPU guarantees), the probe, and zimrnum_ref's
      14 notes, all without znum; files.md / files.html regenerated (only the znum_mapping.md note's entry remains,
      a development note). check 360/360, test-zimrnum 238/238. Next: step 2, zimrrl.zig and zimrrl's tutorial.
      STEP 2 DONE (Oct 4): zimrrl.zig has no znum mention (0 of 25). The PPO doc chain is fixed - ppoEpoch has its
      38-line doc back (plus S0's "No parameter changes here: ppoUpdate is the version that trains"), ppoObjective
      its clipped-surrogate / KL-estimator doc, OffPolicyModel only its own; the paragraphs explain the design
      directly (Transition's doc said `seam`, now `episode_end`; the failure-angle test said turns, now radians).
      test-zimrrl 98/98, lint 0. zrl's tutorial: its prose has none; 5 left inside folds of zimrnum functions, which
      step 3 removes at the source. NEXT: step 3, zimrnum.zig (106).
      ALSO DONE (Simon, Oct 4): zimrnum tutorial's chapter 2 "What exists" removed (a stale status table: it listed
      autograd, decompositions, FFT, serialisation as absent); chapters 3.. renumbered down by one (155 headings,
      letter suffixes kept: the pointers are now 15, 17b, 17d); build.zig's "section 3.1" -> 2.1 (backups in
      /tmp/big/status). zimrnum-ref (numbering check), test-zimrnum 238/238, check 360/360, doc-pages green. Noted for the
      comment pass: zimrnum.zig, zn_unary.zig and zimrnum_field.zig cite "section 10.3 ... debt 11" of a plan, not
      the tutorial.
      STEP 3 IN PROGRESS (zimrnum.zig; backup before it: /tmp/big/znum3/zimrnum.before.zig): batch 1a done - the
      header (no longer says RL; the device-checking paragraph points to zrl_binary for the RL rows; "HOUSE RULES"
      without the donor comparison), requireFloat / requireInt, the index view, the 128 threshold, keepdims.
      Batch 1b (dataframes, 18), 2a (3100-4200, 11: Polyak lerp, Push, the Gumbel-max story, affine, compareScalar,
      reshape rules) and 2b (4200-9000, 17: bitwise not, shifts, diff, asinh/acosh/atanh, a false `exp` doc removed,
      softplus's forms, metrics, quantiles, mad, skew) done -> 54 left (test-zimrnum green; /tmp/reflow.py re-wraps a
      doc paragraph if an edit leaves a long line). Noted for later: `Push` (the cartpole action) is RL and still in
      zimrnum. Batch 3a (Simon: "no need to keep znum magic bytes, there are no saved files"): the tensor file
      magic is now "ZIMR\0\0" (same 6 bytes and shape, so the test's pinned header bytes hold; the dtype tags are
      unchanged), its doc and the format block (source and tutorial) updated; Categorical, saveParameters, dft,
      fft, rfft, convolution modes and the two serialisation test comments rewritten. test-zimrnum 238/238 -> 43
      left. Batch 3b (linear algebra, optimisers, convolution, 12) done -> 31 left. Batches 4a (graph and layers, 10)
      and 4b / 4c (tests, 21) done -> STEP 3 DONE: zimrnum.zig has no znum mention; lint 0, test-zimrnum green.
      (A table row in the pseudo-inverse test, broken over three lines by an earlier wrap, rejoined.)
      STEP 4 DONE: the zimrnum tutorial's 31 prose mentions rewritten (two stale facts fixed on the way:
      resolveInferredShape does infer a -1 dimension; the MAD paragraph had a broken sentence). ZNUM HISTORY
      REMOVAL COMPLETE (Oct 4): no mention in any source file or tutorial; the only one left in a page is the
      files index's entry for the development note src/notes/znum_mapping.md (development notes kept as the log).
      Verified: zimrnum-ref, test-zimrnum 238/238, test-zimrrl 98/98, doc-sync, check 360/360, test-fast 19/19,
      doc-pages. Still open from this pass, for the comment pass: plan references in code ("section 10.3 ... debt
      11", in zimrnum.zig, zn_unary.zig, zimrnum_field.zig); `Push` (RL) still in zimrnum.
      Was, in order: elementwise and helpers ~3207-6885 (~25, incl. the
      Gumbel-max story at ~3737), statistics / linear algebra / FFT ~7953-10388 and ~19646-20097, graph and layers
      ~12105-16052, serialisation ~17391-17446 (KEEP the "ZNUM\0\0" magic bytes - a format identifier; only the
      comment changes), tests ~20989-28967. Each batch: read paragraphs (/tmp/paragraphs.py FILE LINES - recreate
      if lost: prints the contiguous comment block around each line), rewrite, T0/T1, test-zimrnum.
      Earlier: STEP 2 batch 1 done (backup /tmp/big/znum2) - the cartpole and rollout paragraphs
      (8) rewritten to explain the design directly; "Register row 62" plan references gone too. 17 mentions left.
      FOUND, to fix together with the rest: a chain of three shifted docs in the PPO region, inherited from zimrnum.
      The 38-line doc above `ppoObjective` ("One PPO epoch over a rollout: shuffle, walk in minibatches ... `ppoObjective`
      is called with the flag OFF") is `ppoEpoch`'s; `ppoObjective`'s own doc ("The clipped surrogate objective over a
      batch, with the diagnostics ... THE KL ESTIMATOR IS exp(r) - 1 - r") is stranded above `OffPolicyModel`, glued
      to OffPolicyModel's own doc with no blank line; `ppoEpoch` carries only the 4-line doc written in S0. Fix:
      each doc back to its owner, S0's 4 lines merged into ppoEpoch's original, the znum paragraphs in all three
      rewritten. Then the rest of zimrrl.zig (tests at ~7560, ~9009, ~9119, ~9175), zrl's tutorial, zimrnum.zig,
      zimrnum's tutorial.
      B5b (NEXT, Oct 4), in three steps, each recorded before the next:
        B5b-1 `Bmpc(T).Schedule`: BMPC's schedule (online_trainer.py) as pure arithmetic - seed_steps = max(5 x
              episode length, 1000) environment steps of random actions; at seeding's end one burst of updates
              (pretraining: world model only); then updates after every frame. Generalised to E environments in
              lock-step by holding the update-to-data ratio u fixed: seed_frames = ceil(seed_steps / E), burst =
              seed_frames x E x u (one update per seeded step), then E x u per frame. KNOWN ANSWERS: E = 1, u = 1,
              L = 1000 is torch's (5000 random steps, 5000 burst updates, 1 per step); E = 8, L = 200 -> 125 frames,
              1000 burst updates, 8 per frame; rounding when E does not divide seed_steps; `at(frame)` for the last
              seed frame, the burst frame and the first steady frame.
        B5b-1 DONE (Oct 4), REVIEWED: `Bmpc(T).Schedule` (seed_frames, burst_updates, updates_per_frame;
              `bmpc(E, L, u)`; `at(frame)` -> Frame { planned, updates, pretraining }), beside discountFor;
              seed_episodes = 5, min_seed_frames = 1000. THE REVIEW'S BUG: the first version divided seed_steps
              among the environments, so at E = 8, L = 200 seeding stopped after 125 frames - before any episode
              had ended, contrary to the rule's purpose (five whole episodes before the planner relies on the
              model) and to BMPC's batched trainer (burst = max(5T, 1000) x envs x utd: seeding counts FRAMES).
              Now seed_frames = max(5L, 1000) per environment, burst = seed_frames x E x u, then E x u per frame;
              E = 1, u = 1 is torch's schedule exactly (why the first tests could not see the bug). Also: no
              division left (bmpc(0, ...) divided by zero); `at` restated as the timeline (no `frame + 1`
              overflow; a written-out schedule with no seed frames has no burst). The doc is a course: the
              timeline, the five-episodes grid with the counter-example, the update-to-data identity, worked
              examples. Five tests; CONTROL: reinstating the division fails exactly the three tests that check
              E > 1 (the E = 1 test passes, as it did for the bug). test-fast 19/19, check 360/360.
        B5b-2 DONE (Oct 4): `Bmpc(T).requireEnvironment` (reset(*Env, Rng, []T) void; step(*Env, []const T, []T)
              T - a compile error naming the expected signature) and `Bmpc(T).Trainer(Environment)`: init (actor,
              learner, replay; discount = discountFor(L) whatever the config says; every environment reset) and
              runFrame (act - random in [-1, 1] while seeding, the planner after; step; rows with the empty target
              while seeding; push; truncation at L with the TRUE final observation, then a reset and first_step; the
              schedule's updates, pretraining flagged). Random streams labelled: acting 1, resets 2 (per environment
              and episode), updates 3 (per update index). Arena-allocated, like the actor and the learner. Five tests
              on a stand-in ramp environment (seeding; the burst and the planned frame; episode boundaries; bit for
              bit; the discount). Controls: truncation one step early fails only the episode test; the burst passed
              as real updates fails only the burst test. test-fast 19/19, check 360/360.
        B5b-2 as planned: the loop (`Trainer`): fixed-length episodes (truncation only - BMPC has no terminal handling), random
              actions with empty targets while seeding, the planner after, rows into SequenceReplay, the burst,
              steady updates, discountFor(L). Tested on a tiny stand-in environment: counts of random / planned
              actions and of updates per phase, episodes resetting at L, the replay's contents.
        B5b-3 REVIEW DONE (Simon, Oct 4: "before the next steps, review carefully, look for bugs, improve comments
              and tutorial, make the code theoretically perfect before testing"). (1) The staleness suspect - the
              actor planning with the initial networks - cleared at all three levels (a frozen binding is
              graph.constant over the SAME tensor; push stores the view; recompute replays every non-leaf node), and
              GUARDED: a wiring test ("what the learner changes, the actor reads at its next decision"; control:
              separate networks keep every score at 0). (2) `Trainer.last_report`, checked in the burst test.
              (3) THE TASK: `zrl.tolerance` (dm_control's rewards.tolerance: gaussian / quadratic / linear,
              defaults as dm_control's; Falloff, Tolerance) and `zrl.cartpoleBalanceReward` (DMC's dense balance
              reward: upright x centred x small control x small velocity), with known-answer tests; the gate now
              rewards balance as DMC does - the setting BMPC's settings were tuned on - while its verdict stays
              behaviour (steps within 12 degrees and 2.4 m). (4) The gate's doc opens with its procedure and the
              reasons for the reward and the verdict; its config states the discount actually used
              (discountFor(L) = 0.95). (5) The tutorial: 9.21 the schedule (a timeline figure) and 9.22 the loop (the
              frame diagram, the episode table, the heart of runFrame). test-fast 19/19, check 360/360, zrl 101/101,
              lint 0. NOT YET RE-RUN: the gate - next, with the diagnostics below if it still fails.
        B5b-3 RE-RUN AND DIAGNOSED (Oct 4). With DMC's balance reward: pole up 0.200 trained vs 0.153 random - still
              failing. The instrumented run (same seeds) says the MODEL LEARNS and the PLANNER CANNOT USE IT: reward
              cross-entropy 0.99 -> 0.64 and value 1.38 -> 0.73 over the run, consistency ~1e-4; zero-action plans
              score 1.79 upright vs 0.88 level and 0.87 hanging (the model ranks states correctly); but at 0.05 rad
              the planner's candidates score 1.788 to 1.800 - a spread of 0.011, so its choice is noise. CAUSE: three
              decisions of 0.02 s look 0.06 s ahead, where no push changes the pole enough to matter, and the value
              function (the CURRENT, poor behaviour's return, after 350 updates) cannot supply the rest. FIX
              (principled, standard): ACTION REPEAT - each decision held for 5 physics steps, so the plan looks 0.3 s
              ahead, the time an untended pole takes to fall (DMC's protocol in the EfficientTDMPC paper repeats 2;
              PlaNet held cartpole actions for 8). Rewards summed over the held steps, as DMC's wrappers do; the
              verdict counts every physics step.
        ACTION REPEAT TRIED AND REVERTED (Oct 4). With 5 held steps: the planner's candidates spanned 2.24 to 2.60
              (30x the spread - it can now tell plans apart), but the model ranked states WORSE (zero-action plans
              2.28 upright vs 2.24 hanging; reward cross-entropy 1.39 -> 1.10, since it must predict five summed
              steps from data dominated by falling poles), and the gate gave 0.016 trained vs 0.033 random (per
              physics step). Reverted to 0.02 s decisions - exactly DMC's protocol (0.01 s physics x repeat 2) - with
              DMC's dense reward and the diagnosis test kept (on demand only).
        CONCLUSION: the assembled agent learns (losses fall, the model ranks states), slowly; the gate's 350 updates
              are far below BMPC's protocol (tens of thousands of updates on DMC's cartpole). At 0.145 s per update
              (32 windows, latent 32, hidden 64) and 0.39 s per frame of 4 decisions, 10k updates take 24 minutes -
              and networks this small should be orders of magnitude faster, so the overhead is in our pipeline.
        B5b-3 NEXT: PROFILE before any further gate work - where an update's 0.145 s and a decision's 0.1 s go
              (graph replay, allocation, the 101-bin heads, the value targets' policy rollouts, reanalyze's planning
              every 10 updates); fix what is not arithmetic; then size the gate from the new costs to thousands of
              updates within 5 minutes. If the CPU cannot get there, N9's GPU kit comes before the gate.
        PROFILED (Oct 4; perf 6.8 from Ubuntu's archive, `perf record -e cpu-clock` on the gate file's profile
              test - 20 seed frames, a burst of 100, 40 planned frames with an update each; 1 core, flat profile since
              release builds omit frame pointers). BEFORE: matmul 69%, log 7%, add 7%, exp 4%, tanh 3% - graph
              replay, backward bookkeeping, the optimiser and allocation each < 0.5%: the time is ARITHMETIC, not
              pipeline. FIX 1 (DONE): `zn.matmul` fast paths - rows of b and out contiguous: the (i, k, j) order,
              Neumaier vectorised across j (both corrections computed, @select per lane); b a transposed contiguous
              matrix: contiguous slices, CompensatedSum in the specification's order; anything else: the
              specification, now `zn.matmulReference` (the naive loop, kept). Every element is the same Neumaier sum
              in the same k order, so the results are BIT-IDENTICAL - a test over 5 shapes x 3 layouts compares
              exact slices; control: dropping the vector path's corrections fails it. Profile run 58 s -> 25 s,
              matmul ~5x faster (69% -> 32% of the new total). zn 239/239, zrl 101/101, test-fast, check, doc-pages
              green; the zimrnum tutorial's matmul paragraph explains the two orders and gives the measurement.
              NEXT TARGETS, from the new profile: log 16% + exp 8% + tanh 7% + ldexp 4% + softplus 3% (BMPC's Mish
              activations and 101-bin softmaxes, compiler-rt's scalar functions - a faster form changes numerics, a
              decision for Simon); `add` 14% (the generic strided walk on bias broadcasts - a contiguous fast path is
              exact); matmul 32% (path B, backward's grad @ wT, is not vectorised). Then re-size the gate.
        SIMON (Oct 4): approximations of activation functions are acceptable; and the real networks will train on the
              GPU, so CPU network performance matters for the gates and the development loop, not the endgame. So:
              CPU work is BOUNDED to what makes the 5-minute gates feasible - cheap, exact wins first - and the real
              effort stays N9's GPU kit. Exact reformulations are preferred to approximations where they exist: Mish
              needs one exponential, since tanh(softplus(x)) = n / (n + 2) with n = e^x (e^x + 2) - a fused node
              (forward x n / (n + 2); slope t + x (1 - t^2) sigmoid(x)) in place of three, scalar forms in zimrmath.
        A LEAK FOUND (Oct 4), while reading the backward pass for the fused node: seven temporaries in
              `Graph.backward` (exp, log, softplus, elu, slice, concat x2) came from the graph's allocator instead of
              the pass's scratch arena, so every backward pass through them kept its scratch - BMPC hits softplus
              (inside every Mish) and concat (latent with action) on every update, so a run's memory grew with its
              updates. FIXED (all seven from `temp`, like the other 24). Test: a graph through all six ops, its
              allocator counted (std.testing.FailingAllocator over an arena) - five passes after the first ask it for
              nothing; control: softplus reverted -> 30 expected, 36 found. (An arena's queryCapacity could not see
              it: small leaks fit the chunk already reserved.) NEXT: the fused Mish node; then an end-to-end check
              that a BMPC update asks its allocator for nothing after the first; then `add`'s fast path; re-profile;
              re-size the gate.
        MISH FUSED (Oct 4): `zm.mish` and `zm.mishSlope` (zimrmath, shader-safe, beside softplus) compute
              x tanh(softplus(x)) and its slope with ONE exponential each, from tanh(softplus(x)) = n / (n + 2),
              n = e^x (e^x + 2); the slope t + x (1 - t^2) sigmoid(x) with 1 - t^2 formed as (1 - t)(1 + t), 1 - t =
              2 / (n + 2); saturation above (1/2) log(8 / eps) (19.1 f64, 9.0 f32) returns x and slope 1. `zn.mish`
              (map over zm.mish); `Graph.mish` is one node (`.mish_op`, replay and backward, scratch from `temp`)
              where it was three. Tests: zm mish against the composition over [-30, 30] within 4e-16 relative, known
              values (mish(-1), mish(1), slope 3/5 at 0), the central difference everywhere, saturation and the
              far tail; the existing graph probe checks the node's backward by finite differences. Control: the slope
              without its product-rule term fails the graph probe. The zimrnum tutorial's activation paragraphs are
              rewritten (no history) with the derivation and a table. zn 240/240, test-fast, check, doc-pages green.
              NEXT: the end-to-end allocation check on a BMPC update; `add`'s fast path; re-profile; re-size the gate.
        MEMORY AND `add` (Oct 4). Two whole-agent tests: once warm, a BMPC update (world model, policy, and the
              reanalyze of every tenth) and a decision ask their allocators for nothing - FailingAllocator counts over
              the window 12..21 (reanalyzing at 20) and over five decisions; control: concat's backward reverted to
              the graph allocator fails the update test (1618 expected, 1678 found) and leaves the decision test
              passing (planning has no backward). `zn.zip` (behind add, sub, mul, ...) gained a ROW path - output
              contiguous, both inputs stepping by one along the last axis: the leading index walked once per row,
              each row a linear loop - for a (1, n) bias under (m, n); exact by construction; test over (3, 5) +
              (1, 5), (2, 3, 4) + (4) and the walk's (3, 5) + (3, 1); control: rows never advanced fails it.
              RE-PROFILED: the profile run 25 s -> 15 s (58 s originally), peak memory 517 MB -> 352 MB; log gone
              (Mish fused), add 14% -> 3.4%; matmul is back to 54% (about 8 s, as before in absolute terms), then exp
              9%, layerNorm 7%, mish 6%. zn 241/241, zrl 101/101, test-fast, check green.
              NEXT: matmul's breakdown by path (the three helpers kept apart in a profile build) - path B (backward's
              grad @ wT, scalar) is the suspect - and its fix; then re-size the gate from the new costs.
        @divCeil (Simon, Oct 4: verify zimr has no std.math.divCeil - Zig added `@divCeil`). Verified: no
              `std.math.divCeil` in code (only zimrmath's test, as the reference). The toolchain (0.17.0-dev.2307)
              has the builtin - scalars, vectors, unsigned, minInt, mixed widths, all probed. `zm.divCeil` (the
              checked wrapper: a zero divisor is an error) now calls `@divCeil`; its old body, -@divFloor(-a, b),
              could not take an unsigned dividend and overflowed at minInt - both now known answers in its test.
              24 hand-written ceilings (a + b - 1) / b in host code and examples became `@divCeil` (exact across the
              type, where the idiom overflows near the top): codecs, physics2d, compute_host, material, net_core,
              zimrrl, robot_geno's test, five examples. GPU KERNELS KEEP THE IDIOM: Zig's SPIR-V backend reports
              "TODO (SPIR-V): implement AIR tag div_ceil" (zimrnum-field: 69 steps failed) - the three kernel lines
              reverted, each with a comment giving the reason. A zimrlint shader rule (like shader-no-atan) is
              possible but not added. robot-mocap's fold of compute_host.run regenerated; check 360/360,
              test-fast green.
        MATMUL BY PATH, AND THE GATE AT 1650 UPDATES (Oct 4). Profiled with the three paths kept apart: path A
              (rows contiguous, vectorised) 46%, path B 6.6%, the specification nothing. Path A REGISTER-BLOCKED:
              `matmulColumns(lanes, count)` keeps `count` vectors of sums and compensations in comptime-indexed
              arrays (registers) across the whole k loop - blocks of 4 vectors, then single vectors, then single
              columns (a one-lane vector); lanes from `suggestVectorLength` (4 f64 here: LLVM prefers 256-bit on this
              AVX-512 Xeon). Bit-identical (test shapes now include n = 45, the single-vector path). The annotated
              loop is packed ymm arithmetic with mask-register selects and no spills - what remains is Neumaier's
              ~10 operations per product. Profile run 58 s -> 12 s overall. CPU work stops here (GPU is the
              endgame). THE GATE re-sized (`gate_schedule` 50 / 1000 / 1, `gate_frames` 700 - shared with the
              diagnosis): 0.333 trained vs 0.153 random, 3 minutes. Diagnosis: the model ranks states correctly
              (zero-action plans 6.38 upright, 5.77 level, 4.41 hanging), losses lower, but the planner's
              candidates at 0.05 rad still span 0.004 - three 0.02 s decisions change the angle little and the
              angular velocity a lot, and a value function that has seen 1650 updates of mediocre behaviour is too
              flat to tell those apart. Mastery needs BMPC's tens of thousands of updates: ~20-30 minutes on this
              CPU.
        DECIDED (Simon, Oct 4): continue the plan WITHOUT further learning runs on the CPU; the GPU work is part of
              the plan, and an OVERNIGHT WEBGPU TRAINING launches as soon as it is ready - that run is where BMPC (then
              EfficientTDMPC) must balance, and later track. The cartpole gate file stays as an on-demand check with
              its instrumented diagnosis; the profile test is removed (it served its purpose). Unit tests with known
              answers remain the way every building block is verified.
        B6a DONE (Oct 4): NETWORKS match BMPC's architecture point for point (encoder one hidden layer + SimNorm;
              dynamics two hidden + SimNorm; reward and value heads two hidden, 101 bins, zero last layer; value
              dropout 0.01 on the first layer; policy mean and log spread; target heads cloned), and the
              initialisation is TD-MPC2's (Mlp's default `small_normal`, std 0.02, zero biases). CONFIG matches
              Table 2's BMPC column value for value - with ONE GAP, BMPC's own: +2 MPPI rounds from 20 action
              dimensions (`Config.iterationsFor`, `large_action_width` 20, `large_action_extra_iterations` 2; the code
              counts `>= 20`, the papers say "> 20"), now used by `Actor.init` and so by both planners. Test: 19 / 20 /
              21 dimensions, and an actor for 20 plans the extra rounds. bmpc 34/34.
        B6b DONE (Oct 4), NO BUG: the world model's update is EfficientTDMPC's Appendix D eqs. 11-15 with one head -
              rollout from the encoded start (block 0 = o_0); consistency against each step's TRUE successor (blocks
              t + 1 = n_t); reward on the ROLLED latents with the action taken, rho^t, mean over steps; value targets
              (eq. 14) from each stored step's own observation (loadWindows: rows step x W + window), a policy draw in
              a frozen graph, the model's reward, gamma x the MEAN of the target heads at f(z, a); every value head on
              the rolled latents, mean over steps and heads; finished windows masked (BMPC-jax's normalisations).
              N7c'S DESIGN, read off where the ensemble enters: LatentRollout once per dynamics head from the same
              encoded z_0; WorldModelLoss over those rollouts - consistency and reward averaged over heads, value over
              heads x value heads (eqs. 12, 13, 15); LatentValueTargets with every dynamics head - R(z, a) is
              head-free (the true latent), only V(f_i(z, a)) is averaged over i (eq. 14); the policy loss over each
              head's detached latents (eq. 16, B6c's territory).
        B6c DONE (Oct 4), deep, NO FUNCTIONAL BUG. Policy update: the rolled latents copied as values (torch's
              zs.detach()), stored means and log spreads (every spread >= 0.05 or exactly 1, so the log is finite),
              the scale updated before the loss (recompute, updateScale, recompute, backward), masks shared with the
              rollout; PolicyDistillationLoss = sum rho^t / H x batch mean of [KL(policy || planner) / scale -
              1e-4 x dims x entropy], the KL averaged over action dimensions (torch). Reanalyze: the first R windows'
              H states step-major, one decision with every state first (no warm start), the exploration spread for the
              policy's plans, evaluate mode (the target is the drawn elite either way), targets into the batch and
              back to the replay - `writeBack` takes STEP-MAJOR rows over the given origins, which is `target_rows`'s
              layout (checked: the silent-misplacement risk). Learner.update: sample -> reanalyze -> world model ->
              policy; real updates counted from 1, so reanalyze falls on the 10th, 20th, ... CODE: clearer names
              (rolled_latent_values, latent_numbers_per_step, batch_row_index, target_column_start / _count,
              reanalyze_interval, interval_reached, reanalyzed_origins), named intermediates, diagrams of the shared
              step-major layout (policy) and of the two layouts reanalyze maps between; one inaccurate test comment of
              mine corrected (the allocation test said reanalyze ran at update 0). bmpc 34/34, lint 0.
              NEXT - THE TUTORIAL, with real figures: 9.18 the policy update (distillation: rolled latents ->
              policy -> KL to the stored planner Gaussians, scale and masks), 9.19 value-equivalent training (heads
              read ROLLED latents, targets come from TRUE ones - the shape of EfficientTDMPC's Figure 2), 9.20
              reanalyze (the batch as a W x H grid, the first R windows re-planned, back into batch and replay).
              Then B6d (the actor).
        B6c's TUTORIAL DONE (Oct 4): the existing figures were read first - 9.18 had the windows' layout and the
              five steps, 9.19 the update's two halves and the discount, 9.20 reanalyze's rhythm and flow (so 9.20
              needed nothing more). ADDED: 9.14 "Why the policy comes first" - two stored answers that disagree,
              the planner-first fit spread between them and BMPC's policy-first fit committed to one (true Gaussian
              curves), then the closed-form KL with a worked number (6.21); 9.18 "Which latents each term reads" -
              value-equivalent training in three rows (true latents and their targets, the rolled latents, the
              heads), each target routed to the heads it scores, consistency as links between the rows. Both
              rendered and checked; zrl 101/101.
        B6d DONE (Oct 4), deep, NO FUNCTIONAL BUG. The actor against BMPC's `_plan` as recorded: the policy's 24
              plans drawn once (sampled, as torch's pi(z)[1]) and fixed for the search, with the actor's spread (the
              exploration bounds in reanalyze's actor); warm start = !first_step (so never in reanalyze); Mppi: the
              mean shifted one step or zeroed, the spread reset to its ceiling (2) EVERY call (as TD-MPC2), scores
              not finite -> 0 BEFORE ranking (BMPC's nan_to_num(0)), elites weighted exp(temperature x (score -
              best)), the refit's spread clamped [0.05, 2], one elite drawn by weight; the scorer's V(z_H) the MEAN of
              the value heads; the action = target + spread x N(0, 1) when exploring, the target when evaluating.
              CODE: the actor's two-line doc became a course (a diagram of one decision, the candidates' layout per
              state, the warm start); names: candidate_scores (was scores; its uses in the tests and the cartpole
              diagnosis follow), warm_starts (was warm), decided_numbers, shapes_match. bmpc 34/34; the cartpole
              file compiles. THE REVIEW B6a-d IS COMPLETE. NEXT: B6d's tutorial half (9.17 has a decision figure - read
              it first, add only what is missing, e.g. the warm start's shift), then N7a.
        B6d's TUTORIAL DONE (Oct 4): 9.17's figure already showed the three steps, the warm start's shift worked
              through and exploration worked through - no new figure; the text gained the spread's reset at every
              decision (only the mean carries over) and the round count (6, or 8 from 20 action dimensions).
              B6 IS COMPLETE.
        N7a-1 DONE (Oct 4): `Bmpc(T).PlannerConfig` {horizon 3, candidates 512, policy_candidates 24, elites 64,
              iterations 6; iterationsFor and the 20-dimension rule moved onto it}, with a doc tabling BMPC's and
              EfficientTDMPC's two planners; `Config.horizon` is now documented as the TRAINING WINDOW only;
              `Config.acting` and `Config.reanalyzing` (default: BMPC's, alike); temperature and the spread bounds
              stay shared. `Actor.init` takes its planner (the Trainer passes `acting`, the Reanalyzer `reanalyzing`;
              reanalyze's STATE count stays training window x R, its PLAN length is its planner's). Fixtures:
              test_planner, gate_planner. KNOWN ANSWERS: every existing bmpc test unchanged (the defaults reproduce
              today's decisions); new test - acting.horizon 6 gives the acting actor 6-step plans (a decision runs),
              reanalyze keeps its planner's 3, and the training window stays 3. bmpc 35/35, lint 0.
        N7a-2 DONE (Oct 4) - N7a COMPLETE: `Config.bmpc(episode_length)` (every default, the discount from L) and
              `Config.efficientTdmpc(episode_length)` (BMPC's, acting.horizon 6, reanalyzing {3, 64, 3 policy plans,
              8 elites}); the discount rule (constants first, then `discountFor`) moved above PlannerConfig and
              Config, vocabulary first. Tests: bmpc(1000) equals the defaults with gamma 0.995 (expectEqualDeep);
              efficientTdmpc(1000) differs from bmpc(1000) exactly in those fields (set back, the configs are equal).
              Tutorial 9.23 "Two configurations": the two jobs, PlannerConfig, the training window apart, Table 2's
              planner numbers as a table, why each change (the cheaper reanalyze as its authors measured it), the
              presets in use. bmpc 37/37, zrl 101/101.
        N7b CODE DONE (Oct 4): zrl `PlanObjective` {final, mean_over_depths} and `planObjectiveWeights` - both
              objectives are weighted sums of the same rewards and values (the reward at step u is in H - u prefixes):
              final rewards gamma^u, value gamma^H at the end; mean rewards gamma^u (H - u) / H, values gamma^h / H
              at every depth. LatentPlanScorer: `Options.objective`, weights computed at build, the value heads run
              only at weighted depths (the end for final - the same cost as before), `score` the weighted sum;
              `value_probabilities` per depth x head (null where unweighted). Final's weights come from the same
              multiplications in the same order, so BMPC's scores are bit-identical (the existing hand-computed
              scorer test passes). Tests: weights by hand (H 3, gamma 0.9, both objectives; H = 1 the same); two plans
              ranked oppositely (A: rewards 1, 0, values 1, 0 -> final 1, mean 1.5; B: 0, 0 and 0, 1.2 -> 1.2, 0.6);
              the scorer's mean = (Q_1 + ... + Q_H) / H with every Q_h computed by hand from its definition.
              Control: the mean's reward weight without its prefix count fails the definition test. robot_bmpc:
              `PlannerConfig.objective` (default final), passed to the scorer; efficientTdmpc's acting planner uses
              mean_over_depths, reanalyze keeps final (Table 2); the preset test checks both. zrl 104/104, bmpc
              37/37, the zrl table 145 rows.
        N7b DONE (Oct 4): the tutorial's 9.7 gained "The objective: the whole plan, or every prefix" - Q_h defined, a
              figure (the plan's latent chain, then Q_1, Q_2, Q_3 each covering its prefix's rewards and ending at its
              value where the policy takes over; final = Q_3, the mean over all three), the two-plan example as a
              table, the weights table (H 3, gamma 0.9), the option in code. (First inserted inside the source fold's
              wrapper by mistake - moved out before the wrapper, where the doc tool does not regenerate.) zrl 104/104.
        N7c-1 DONE (Oct 4): `Config.dynamics_heads` (default 1); `Networks.dynamics` is a list - head 0 from stream
              1 as before (one head is bit-identical), head h > 0 from stream 1's split h (distinct initial weights,
              Appendix D's "initialize heads differently"); every reader takes head 0; `Learner.init` returns
              error.EnsembleTrainingUnimplemented for more than one head (refused, not half-honoured). Test: four
              heads, head 0 equal to the single head's numbers, every pair different, the learner's refusal.
              bmpc 38/38. (efficientTdmpc's preset gets dynamics_heads = 4 in N7c-2, when it can train.)
        REVIEW OF N7b's TUTORIAL AND N7c-1 (Simon, Oct 4: "review carefully the code from the last 2 turns"):
              (1) Rng.split mixes its label through a 32-bit hash, so a head's stream split(1).split(h) has no
              structural relation to the other networks' split(k) - no collision bug (a coincidence is a 2^-32
              event). (2) FIXED: zero dynamics heads left an empty list that every reader indexes - now
              error.NoDynamicsHead at Networks.init. (3) FIXED: the refusal of more than one head sat in Learner.init
              while WorldModelLearner (public, the component that trains the dynamics) built with four heads would
              silently train head 0 - moved into WorldModelLearner.init (Learner and Trainer reach it through it).
              (4) The test now also checks that extra heads leave the encoder, reward, policy, value and target
              networks unchanged number for number, that WorldModelLearner.init refuses, and that zero heads is an
              error. (5) FIXED in the tutorial: plan A's final objective was written "0 + 1 + 0 = 1"; it is
              r_0 + r_1 + V(z_2) = 1 + 0 + 0 (the total was right, the terms were not plan A's). Everything else in
              9.7's subsection checked against the definitions (Q_1 = 2, Q_2 = 1, mean 1.5; 0.81 / 3 = 0.27,
              0.729 / 3 = 0.243). bmpc 38/38, zrl 104/104.
        N7c-2 DONE (Oct 4): zrl's LatentRollout takes `dynamics_heads` + `dynamics_bounds`: ONE encoding pass (z_0
              with gradient and the detached targets shared by every head), each head rolled from the shared z_0
              (`rolled[head][step]`), `head_consistency` per head, `consistency` their mean (eq. 12). WorldModelLoss:
              `HeadTerms` per dynamics head (its reward and value logits and terms, built by `buildHeadTerms` - the old
              per-step body unchanged), `reward` and `value` the heads' means (eqs. 13, 15), the total as before.
              `meanOverHeads`: summed in order then scaled once - two agreeing heads give EXACTLY the one-head term,
              one head adds no node (BMPC bit-identical: every existing zrl test, the hand-computed rollout and loss
              ones included, and every bmpc test pass unchanged). Callers: one-element lists (zrl's fixtures; the
              robot's world model), reads of head 0 (the robot's policy learner and its test; LatentPolicyPlans
              still takes one dynamics network - the policy's plans come from one head). Tests (LossFixture
              .buildWithHeads, twinOf): two identical heads - the shared z_0, the twin's latents equal the single
              head's, consistency / reward / value / total to the bit, the shared networks' gradients equal and each
              head's half (within 1e-12, the backward pass's summation order); changing one head's weight moves only
              its own consistency term. Controls: no 1 / Nf -> the exactness test fails; every head rolled with head
              0 -> both fail. HeadTerms' table note. zrl 106/106, test-fast 19/19, check 360/360.
        N7c-3a DONE (Oct 4): zrl LatentValueTargets takes `dynamics_heads` + `dynamics_bounds`. The heads' chains are
              STACKED along the rows (block i = head i's): the policy, the reward head and the target heads read every
              block in one pass, each dynamics head steps its own block (slice, apply, concat; one head: no slicing,
              today's graph). Every block starts from the true latent and draws with its STORED ROW's noise, so at the
              first step every head draws the same action - eq. 14 exactly at lookahead 1 (R(z, a) head-free, the
              bootstrap averaged); longer lookaheads follow each head's chain with common random numbers. Each head's
              target accumulates apart (`head_targets`), averaged per stored step at the end (summed in order, scaled
              once; one head copied). Tests: two identical heads give exactly the one-head targets over the fixture's
              two-step lookahead; two different heads match eq. 14 computed by hand (one action, one reward, the
              value averaged over value heads then dynamics heads). Control: per-stacked-row noise fails both. The
              doc gained "THROUGH EVERY DYNAMICS HEAD". zrl 108/108, test-fast 19/19, check 360/360.
        REVIEW OF THE ENSEMBLE CODE (Simon, Oct 4: "review deeply, make sure there is no bug, best names, named
              intermediates"): BUG FOUND AND FIXED, PRE-EXISTING (from BMPC's assembly; B6b missed it): a dropout
              mask is a function of its generator and each element's index alone, and Graph.resampleDropout refilled
              EVERY dropout node from ONE generator - so after each resample (WorldModelLearner.update resamples
              before every forward pass) both value heads, at every step, dropped the SAME elements; BMPC's Q heads
              each drop independently. FIX in zimrnum: each node from its own split, rng.split(node index) -
              independent and reproducible; `dropout`'s doc states the rule (one generator per node); test (two nodes
              built from one generator: equal masks; resampled: different; resampled again: the same) + control (one
              generator again -> the test fails). WorldModelLoss's build-time dropout streams, which repeated per step
              and per dynamics head, are now rng.split(dynamics head).split(step).split(value head). The zimrnum
              tutorial's dropout paragraph and table note state the rule. bmpc 38/38 unchanged otherwise.
              NAMES AND INTERMEDIATES: LatentRollout dynamics_head_count, dynamics_head, dynamics_head_bound,
              head_rolled_latents, predicted_next; WorldModelLoss/buildHeadTerms value_head_count (it counted VALUE
              heads under the name head_count), value_head_divisor, value_head / value_head_bound /
              value_head_index, latent, logits; LatentPlanScorer value_head_count, value_head_divisor,
              counts_valid, depth_first_entry; LatentPolicyPlans and LatentValueTargets policy_gaussian (was `head`);
              LatentValueTargets dynamics_head_count (field and local), head_block, block_first_row,
              head_block_inputs, head_block_next_latents, numbers_per_block, true_latents, block_latents,
              sum_over_heads, head_block_target. zimrnum 242/242, zrl 108/108, bmpc 38/38, check 360/360, lint 0.
        N7c-3b DONE (Oct 4) - N7c COMPLETE: the robot trains and uses every dynamics head. WorldModelLearner binds
              every head trained (the rollout and loss through all); the model's parameters gathered as GROUPS in one
              order - every dynamics head, the reward head, every value head - which is also the clip's summation
              order (one head: today's order, bit-identical); the targets graph binds every head frozen (eq. 14).
              PolicyLearner: the heads STACKED into its batch (eq. 16) - `dynamics_head_count`, latents step-major
              with a block of W rows per head per step, the planner's targets repeated per head, the row weight
              rho^t / (H x heads x W) = the average over heads of each head's loss; masks: one head reads the world
              model's columns (one setFinished masks both losses), several get `unfinished_by_head` (each window's
              flag repeated per head, refreshed every update); the scale's first-step statistics over every head's
              windows. The refusal is gone; efficientTdmpc's preset has dynamics_heads = 4. BUG CAUGHT BY THE TESTS
              while building: the mask-refresh loop iterated the (empty, one-head) stacked columns TOGETHER with the
              world model's H columns - Zig's equal-length check panicked; now driven by the stacked columns alone.
              Tests: two identical heads (dropout 0: separate graphs hold separate dropout nodes) report exactly the
              one-head consistency / reward / value / total; one update with three heads moves every head, the
              policy's batch is H x 3 x W rows, every head's block at step 0 is the one encoded latent and the heads
              part at step 1. Controls: only head 0 in the optimiser; head 0's latents in every block - both fail the
              every-head test. bmpc 40/40, test-fast 19/19, check 360/360. (Disk: the build's guard refused at 97%
              - freed stale lint builds, old backups and an old migration directory in /tmp; the cache kept.)
              PLANNING still scores under head 0 - N7d.
        N7c TUTORIAL DONE (Oct 4): 9.24 "An ensemble of dynamics heads" - what the heads are and share, why several
              (errors compound; heads agree where the data pins the dynamics down), value-equivalent training, a
              figure (the encoded targets across the top; one z_0 fanning out to three heads' rollouts, each column
              compared with the same target; the loss averaging the heads' terms), the averaged loss terms, the value
              target through every head (eq. 14), the policy on every head's latents (eq. 16), the planner on the
              first head, `config.dynamics_heads`. 9.23's closing sentence CORRECTED (it said the networks were the
              same in both presets - EfficientTDMPC now trains four heads); pointers in 9.4 (the rollout) and 9.5 (the
              loss). zrl 108/108.
        N7d DONE (Oct 4): zrl LatentPlanScorer takes `dynamics_heads` + bounds. The heads are STACKED along its rows (one
              block of states x candidates per head; z_0 copied into every block by the 0/1 matrix; each step's
              actions concatenated once per block; the reward and value heads read every block; each dynamics head
              steps its own block - one head: no stacking, today's graph). `score` keeps today's accumulation per
              stacked row (BMPC bit-identical: every existing zrl and bmpc test unchanged), the reward part and each
              value head's part on the side, the dynamics heads' scores averaged (summed, scaled once), and
              `score_variances`: per row the VARIANCE OF THE MEAN of the Nf x Nv estimates Q(i, j) (eq. 4; divisor the
              count - the sample form would only rescale beta, recorded in the doc). The robot's actor binds every
              head for its scorer; the policy's own plans still roll head 0 (R1.6's open question). Tests:
              identical dynamics and value heads give exactly the one-head scores and no spread; two distinct heads
              x two value heads match the mean and the variance of the mean computed by hand (four estimates per
              row, each on its own graph). Controls: the estimates' variance without the second division; head 0's
              block only - both fail the by-hand test. Tutorial: 9.7 "Under an ensemble" (the Nf x Nv estimates,
              the mean, the variance of the mean); 9.24's "the planner scores with the first head" CORRECTED. zrl
              110/110, bmpc 40/40, test-fast 19/19, check 360/360.
        N7e DONE (Oct 4): zrl LatentPlanScorer `Options.pessimism` (beta): after the mean and the variance of the mean,
              each score becomes mean - beta x sqrt(variance) (eq. 10); beta 0 subtracts nothing (the branch is
              skipped - BMPC and acting bit-identical). Doc "---- PESSIMISM ----". robot: `PlannerConfig.pessimism`
              (default 0) passed to the actor's scorer; `Config.efficientTdmpc(episode_length,
              episodes_can_end_early)` - reanalyze's beta 10 where episodes can end early, else 0; acting always 0.
              Tests: zrl - two candidates A (higher mean, larger spread) and B found in the scorer's own numbers, beta*
              = (mean_A - mean_B) / (sigma_A - sigma_B) by hand: at 0.99 beta* A still wins, at 1.01 beta* B does, and
              every score equals mean - beta sigma; robot - two configurations differing only in reanalyze's beta:
              their acting actors decide alike to the bit (actions and targets), acting's scorer carries 0, the
              reanalyze actor's 10; the preset's rule both ways. Controls: beta x variance (no sqrt) fails the flip
              test; every actor reading reanalyze's beta fails the acting test. Tutorial: 9.23's table gained the
              objective and pessimism columns, its preset call the second argument (it no longer compiled as
              written), the reason for pessimism in reanalyze only; 9.7 the pessimistic score and the flip point.
              zrl 111/111, bmpc 41/41, test-fast 19/19, check 360/360. DISK: 97% after the builds - the build's guard
              refuses near there; /tmp leftovers removed and .zig-cache cleared (8 GB of stale artifacts; the next
              builds are cold).
        N7f STAGED (Oct 4) - the cross-scoring diagnostic is a BUILDING BLOCK now, measured once training exists:
              N7f-1 the chosen plan, N7f-2 the model side, N7f-3 the environment side and the report.
        N7f-1 DONE (Oct 4): zrl Mppi records `chosen_rows` - per state, the candidate row its plan came from (set by
              `choose`; `Mppi.not_a_candidate` = zm.maxInt(usize) before any choice and after `.mean`). The robot's
              `Actor.copyChosenPlan(state, plan)` copies all H actions of that row (error.NoChosenPlan before a
              decision). Tests: the row is the state's own and one of its refit elites, its first action is the answer
              exactly (no exploration), `.mean` records no candidate; the actor's chosen plan begins with the
              decision's target. Control: the row not recorded fails the zrl test. Lint caught std.math (banned outside
              zimrmath: zm.maxInt) and a qualified std.mem.indexOfScalar (now a file-scope alias); the table gained
              `not_a_candidate`. zrl 112/112, bmpc 43/43, check 360/360 (cold cache after the clearing).
        REVIEW OF N7c-3b, N7d, N7e AND N7f-1 (Simon, Oct 4: "review deeply, no bug, names, intermediates, ASCII
              diagrams, then the tutorial with real diagrams") - CODE HALF DONE. Checked: the scorer's stacked blocks
              line up (z_0's copy rows, the repeated actions, each head's slice); every estimate Q(i, j) = head i's
              reward part + value head j's part along head i (value head j at EVERY weighted depth for the mean
              objective); the variance of the mean; pessimism after the head average; Mppi.plan's loop ends sample ->
              score -> refit -> choose, so the chosen rows are the rows the elites were ranked from; the policy
              learner refreshes its stacked masks before its recompute, from this batch's flags. FIXED, a DEVIATION
              found by following the pessimism: Mppi counted every non-finite score as 0, while BMPC's nan_to_num(0)
              sends -inf to the lowest finite number and +inf to the highest - a pessimistic score whose spread
              overflowed (-inf) was rescued to 0, above every negative score. Now `rankableScore`: NaN -> 0, +-inf ->
              zm.highest / zm.lowest; test (-inf ranks last and NaN as 0; +inf first) + control (the old cleaning
              fails it). CLARITY: the scorer's doc gained the stacked-rows diagram and the Nf x Nv estimate grid;
              score's names share_per_value_head, value_head_parts_start, reward_part / estimate intermediates,
              standard_deviation_of_mean, and a comment on where each part sits; Mppi.chosen_rows a diagram of the
              candidate rows and the chosen plan, choose's `chosen_row`; Actor.copyChosenPlan a diagram. (Lint: one
              comment re-wrapped by hand; check's autofix had bound zm.inf / zm.nan to the existing aliases.) zrl
              113/113, bmpc 42/42 (the robot binary's 42 - an earlier 43 counted one more cached step), check 360/360.
              TUTORIAL HALF DONE (Oct 4): 9.7 gained three figures - the estimate grid worked through (Q = 4.8, 5.2,
              4.6, 5.4: mean 5.0, deviations +-0.2 / +-0.4, their variance 0.10, the variance of the mean 0.025, sigma
              0.16); the scorer's stacked rows (two head blocks of two states' 512 candidates: z0 copies, the same
              actions, each head stepping its block, the reward and value heads over every row); the pessimism chart
              (plan A mean 5.0 sigma 0.3, plan B mean 4.7 sigma 0.1, their penalised scores crossing at beta* = 1.5)
              - and the beta = 10 arithmetic (A 2.0, B 3.7). Rendered and fixed until clean (cell labels overflowing,
              a note past the edge, a label on its line twice). zrl 113/113.
        N7f-2 DONE (Oct 4): `Bmpc(T).PlanScoring` + `buildPlanScoring` (the scorer over the networks, frozen, on its own
              graph - the actor builds its scorer with it, the diagnostic its evaluators; bit-identical, all tests
              unchanged); `Actor.copyPolicyPlan` (candidate row 0 of the state - the policy's first plan, never
              overwritten by sampling; error.NoPolicyPlan without policy plans) sharing `copyPlanOfRow` with
              copyChosenPlan. `Bmpc(T).CrossScoring`: a single-head view of the networks (dynamics[0..1]) and the
              ensemble each plan from the same states (acting settings, evaluation mode, the same stream, no warm
              start); three plans per state (single-head plan, ensemble plan, the policy's - the same for both
              planners); two evaluators (final objective, no pessimism, a row per state and plan kind) fill
              `model_values`; `modelValue`, `meanAdvantage` (Delta R = plan minus policy, averaged over the states).
              Tests: each evaluator scores its planner's chosen plan EXACTLY as the planner did (rows are computed
              independently of their batch); both planners drew the same policy plan; Delta R by hand; identical heads
              plan alike and score alike. FOUND IN THE CONTROLS: with BMPC's zero-initialised reward and value heads
              every plan scores the same constant, so the first version of these tests was VACUOUS - swapping the
              evaluators passed. `wakeScoringHeads` (random reward and value heads, in place) fixed it, with a check
              that the heads disagree; the swap now fails. The same blind spot was in N7e's acting test (two actors'
              decisions compared with sleeping heads: a leaked beta subtracts beta x 0) - woken too, and shown: with
              the structural assertion removed, a leaked beta now fails on the decisions alone. bmpc 44/44, check
              360/360.
              THEN N7f-3: the environment side - a single-head view of the networks (dynamics[0..1]) and the ensemble plan
              from the same states; the policy's plan (row 0 of its candidates); all three scored under one head and
              under the ensemble (final objective), plan minus policy per planner per evaluator.
              THEN N7f-3: the environment side - each plan stepped open-loop in a COPY of the environment (a value
              type whose copy is a full snapshot - the cartpole), discounted real rewards then the learned value at the
              end; the report's Delta R per planner and evaluator; tests on the cartpole by hand.
        N7c-3b PLAN (the robot): WorldModelLearner binds EVERY head trained (rollout and loss through all; the
              model optimiser and the clip over every head's numbers), the targets graph through every head frozen;
              the policy learner on every head's detached latents (eq. 16 - heads stacked into the batch, the
              unfinished masks replicated per head); lift the refusal; efficientTdmpc's preset dynamics_heads = 4.
              Then the tutorial's account of the ensemble (9.4 / 9.5 with a figure).
        N7c-2 DESIGN (decided Oct 4): generalise zrl's blocks to a LIST of dynamics heads - the ensemble is a general
              idea of the TD-MPC family, so it belongs in zrl, and a list encodes z_0 and the consistency targets ONCE
              (composing one rollout per head would encode them Nf times). LatentRollout(dynamics_heads,
              dynamics_bounds): shared encodings, per-head rolled latents, consistency averaged over heads (eq. 12);
              WorldModelLoss: reward and value on every head's rolled latents, averaged over heads (eqs. 13, 15).
              One head = a one-element list; the mean over one is x / 1, exact, so BMPC stays bit-identical.
              KNOWN ANSWERS: two identical heads give the one-head losses exactly ((x + x) / 2 = x); the shared
              modules' gradients equal the one-head ones and each dynamics head's is exactly half; perturbing one
              head moves only its own consistency term. Then N7c-3: LatentValueTargets (eq. 14, the bootstrap averaged
              over heads) and PolicyDistillationLoss (eq. 16, every head's latents); then the preset's 4 heads.
        B6 THE REVIEW, split by component (each read against BMPC's algorithm and against what N7 changes):
              B6a the configuration and the networks (DONE); B6b the world model's learner (DONE) and the value targets (against
              EfficientTDMPC's eq. 14, which N7c extends to every head); B6c the policy learner and reanalyze (DONE); B6d the
              actor (the planner N7a splits in two). The tutorial half of B6 is done (zrl 9.17-9.22).
        THEN, in order: N7a-f (EfficientTDMPC to parity, unit-tested), N9 (the GPU kit: the rollout, the categorical
              heads, MPPI's scoring and the updates as WebGPU kernels), and the overnight WebGPU training (N8's runs).
        B5b-3 IN PROGRESS (Oct 4) - THE GATE IS BUILT AND FAILS. src/robot_bmpc_cartpole.zig: `CartpoleBalance`
              (force = 10 N x action; reward 1 while `failed` is false - pole within 12 deg, cart within 2.4 m - else
              0; no termination), the gate config (latent 32, hidden 64, encoder 32, simnorm 8, H 3, 4 iterations,
              64 candidates, 8 policy plans, 8 elites, 32 windows), E = 4, L = 100; `uprightFraction` (the trained
              planner in evaluate mode, one episode per environment) against `randomUprightFraction` (the control:
              an untrained planner scores every plan 0, so acts at random). `zig build bmpc-cartpole` (ReleaseSafe,
              on demand; zm / zn / zrl inherit the root's optimisation). TIMING (probes): an update 0.145 s, a
              planned frame (4 environments) 0.39 s, the compile 27 s. FIRST RUN (50 seed frames, a burst of 200,
              150 planned frames with 1 update each): pole up 0.110 trained vs 0.153 random - no better than chance.
              HYPOTHESIS: a 3-step plan (0.06 s) with a 0 / 1 reward sees no difference between plans until the pole
              is past saving, so everything rests on the VALUE function, and 350 updates do not teach it. NEXT,
              before any tuning: (1) keep the update reports in the trainer (`last_report`) and log the loss
              trajectory - do consistency, reward and value fall? (2) check the reward head against the true reward
              on upright and fallen states; (3) only then change the task or the budget - DMC's dense balance
              reward (N8 needs it anyway), and/or cheaper updates (16 windows) for more of them. A planted-model
              check if (1)-(2) show learning but the gate still fails.
        B5b-3 as planned: the CARTPOLE GATE: zrl's cartpole as a fixed-length balance task, reduced widths, judged in the real
              simulator after training, inside 5 minutes. Then the tutorial section (zrl chapter 9, after 9.20).
      B5b-2 DESIGN CONSTRAINT (from the v5 parity plan): the loop only calls `Actor.act` and `Learner.update`, so
      N7a's two planners (acting H 6, reanalyze H 3 with its own budget) change the actor and the reanalyzer, never
      the loop.
      Then: B6 (review). Then, in order: N7a-f (EfficientTDMPC to parity, on the CPU at reduced widths, each stage
      with known answers and a control; N7f's cross-scoring diagnostic before any long run), N9 (the GPU kit), N8
      (the suite and the measurements, with N8b). Also open: `Push` to zrl; plan references in code comments.
      (S3c-2 as planned:)
      S3c-2 (NEXT) - the content, in order:
            1. a renumbering map, written out first: zimrnum chapters 16 (rl), 18b (rlpolicies), 18d (worldmodels)
               and sections 11.24 (minibatchorder), 11.25 (truncation) -> zimrrl chapters 2.. in reading order
               (environments and RL operations, training policies, world models and planning), Reference last;
               anchor ids unchanged;
            2. move the HTML (prose, code, figures, folds regenerate) into zimrrl-tutorial.html; renumber headings,
               in-page references and figure labels by the map; update its contents list;
            3. zimrnum-tutorial.html: each moved chapter or section replaced by a short pointer keeping its id;
               its title drops "and RL"; the status table, GPU chapter and recipes spell moved names `zrl.`;
            4. robot_bmpc.zig's 12 section references and its header ("Chapter 18d of the zimrnum tutorial");
               robot-mocap-tutorial.html's link `zimrnum-tutorial.html#wm-replay` -> zimrrl-tutorial.html;
            5. verify: zimrnum-ref (both pages, idempotent on a second run), test-zimrnum, test-zimrrl, test-fast,
               check, doc-pages, doc-sync, `smoke-install -Dfocus=zimrnum_field`, then one gate.
      S3c, in two steps:
            S3c-1 - the machinery: zimrrl.zig's gate test (its page's reference table against its public
                    declarations) and its source scans (copies of zimrnum's, pointed at zimrrl); zimrnum_ref's second
                    `libraries` entry (alias zrl, src/zimrrl.zig, src/notes/tutorials/zimrrl-tutorial.html); a first
                    zimrrl-tutorial.html with its header, chapter 1 (what zimrrl is) and the generated reference
                    table; the page in build.zig's doc-pages list.
            S3c-2 - the content: chapters 16, 18b, 18d and sections 11.24, 11.25 moved to the new page with the
                    explicit renumbering map; pointer sections left in zimrnum's tutorial; robot_bmpc.zig's 12
                    section references and header; robot-mocap's link; then the full verification list and a gate.
      S3b, as planned:
            1. `python3 src/notes/scripts/zimrrl_split.py --apply` on the tree as it is now (back up both files);
            2. `zimrlint --fix` on src/zimrnum.zig and src/zimrrl.zig, `zig fmt`, then lint: 0 findings;
            3. a note for `addPointMassToGrid` in tools/zimrnum_ref.zig, then `zig build zimrnum-ref` (zimrnum's table
               loses the moved rows; its own gate test needs that);
            4. build.zig: a test step `test-zimrrl` (root src/zimrrl.zig, modules zm and zn), mirroring `test-zimrnum`,
               in test-fast and the gate - without it zimrrl's 95 tests would not run;
            5. test-zimrnum (238 tests), test-zimrrl (95), test-fast, check.
      S3a - write src/notes/scripts/zimrrl_split.py and run it as a DRY RUN into /tmp: the new zimrrl.zig and the
            reduced zimrnum.zig, with the invariants checked (public names, test names, line counts) - the tree is
            not touched;
      S3b - apply it to the tree; build zimrnum's and zimrrl's tests, test-fast, check;
      S3c - the tutorial split, zimrnum_ref's second library entry, zimrrl's gate test, then the full verification
            list below and one gate.
    - src/notes/scripts/zimrrl_split.py moves units (a declaration or a test block, each with its doc comments) in
      source order into zimrrl.zig, replacing the facade, under its own layer banners, downward-only like zimrnum's:
      R01 environments, R02 returns and advantages, R03 policy distributions and exploration, R04 replay and rollouts,
      R05 value targets (DQN, SAC, distributional), R06 PPO, R07 off-policy, R08 imitation and rewards, R09 world
      models, R10 planning; then the tests.
    - zimrrl.zig binds the zimrnum names its code uses at file scope (`const Tensor = zn.Tensor;` ...) and declares
      its own std / zm aliases. The tensor operations named with zm's reserved maths words (exp, sqrt, tanh, clamp,
      ...) are written `zn.exp(...)` in the moved code, so zimrrl needs no `lint:off`. `zimrnum.X` -> `zn.X`.
    - zimrnum: `ownedTensor` and `addPointMassToGrid` become `pub` with docs; the shape statistics left in L13
      (skew, kurtosis, geoMean, harmMean, histogram, standardisedMoment) move to L08; L13's banner goes.
    - zimrrl-tutorial.html: 1 What zimrrl is (scope, the line, import, dependency rule), 2 What exists,
      3 Environments (from 16.4, 18b.13), 4 RL operations (the rest of 16, with 11.24 MinibatchOrder and 11.25
      terminal versus truncated), 5 Training policies (18b), 6 World models and planning (18d, the course; 18d.0 ->
      6.0), 7 Recipes and gotchas (the RL ones), 8 Reference (generated). Anchor ids unchanged. Display numbers
      renumbered by an explicit map (16.x -> 3.x / 4.x, 18b.x -> 5.x, 18d.x -> 6.x), applied to headings, in-page
      references (110), figure labels (28) and code comments (robot_bmpc.zig: 12; "Chapter 18d of the zimrnum
      tutorial" -> "Chapter 6 of the zimrrl tutorial").
    - zimrnum-tutorial.html: chapters 16, 18b, 18d and sections 11.24, 11.25 become short pointer sections keeping
      their ids, so old links land on a pointer and zimrnum's numbering stays stable; the status table, the GPU
      chapter and the recipes switch to `zrl.` spellings with a link.
    - zimrrl.zig gets its own gate test (reference table against public declarations, embedding the new page) and
      its own source scans (ASCII, no leaked locals in prose, no empty suffixes), copies of zimrnum's.
    - build.zig: test step `test-zimrrl` (root zimrrl.zig) in test-fast and the gate; the new page in the doc-pages
      list; zimrnum_ref configured with zrl (the zrl page folds and arity-checks both zrl and zn).
    - Invariants, checked by the script and then by the build: public names before = zimrnum after + zimrrl after
      (disjoint); test names before = zimrnum after + zimrrl after (333 = 239 + 94); reference rows 784 = zimrnum's +
      zimrrl's; folds >= 344 across both pages (zn folds may repeat on the zrl page); moved and remaining line counts
      add up.
    - Verify: test-zimrnum, test-zimrrl, test-fast (robot 631), check, lint and coverage (0 findings, tree covered),
      `smoke-install -Dfocus=zimrnum_field` (the gate does not build the sweep page),
      doc-pages, doc-sync, zimrnum-ref idempotent (a second run changes nothing), and one full gate.
    - Rollback: restore the S2 snapshot, fix the script, re-run.

  S4 - Later, each on its own: test names "zn rl: ..." -> "zrl: ..."; the RL GPU kernels into src/gpu/zrl_*.zig;
  close the gaps in zimrnum's chapter numbers; a tone pass over the moved chapters' headings.

  Turns: S0 done; S0b done; S1a done; S1b one turn; S2 one turn; S3 one or two turns; S4 later. Then B5b.

**B5a DONE (Oct 3) - reanalyze.** robot_bmpc.zig `Reanalyzer`: an `Actor` for H x R states built with the policy's
plans at the exploration bounds ([-2, 1]); `reanalyze` gathers the first R windows' stored states (step-major), decides
from scratch (every state an episode's first step), evaluated, and writes the targets into the replay (`writeBack`,
first_step 0 - our rows hold their own targets; torch's index[1:] is its layout) AND into the batch. `WorldModelLearner`
split into `sample` + `learn` (same random streams - `update` = both, numbers unchanged); `Learner.update`: sample ->
reanalyze on every reanalyze_interval-th non-pretraining update -> world model -> policy; `LearnerReport.reanalyzed`.
Config: reanalyze_interval 10, reanalyze_windows 20, exploration_spread [-2, 1]. zimrnum: writeBack's stale
"first_step = 1" doc corrected. Known answers: one decision = a fresh exploring actor's, bit for bit - its candidate
block too - into the replay and the batch, the other windows kept; never warm-started (a SECOND reanalyze = a fresh
decision); the rhythm (pretraining uncounted, 2nd of interval 2 reanalyzes) and the policy reading the fresh answers.
Controls: normal bounds, warm start, reanalyze after the policy, pretraining counted - each fails exactly its own test.
LESSONS: (1) a filtered build that passes prints NOTHING without --summary - always read the summary line, or a
compile error / silent pass reads as a result; (2) on fresh networks every candidate scores alike (zero-last heads), so
a planner's DECISION cannot see what only changes the candidates - compare the candidates themselves. test-fast 631,
check 360/360. Tutorial 18d.20 (one figure). NEXT: B5b - the warm-up schedule and the cartpole gate.

**Engineering rules:**
- A KNOWN ANSWER for every component before it is trusted (a closed form, an exact identity, a parity to float
  precision); every quality number judged in the REAL simulator, by the judge (F1).
- ONE definition per concept, so call sites cannot drift: `robot_track.Task` (the task), `judge` (every verdict on a
  policy), `robot_geno.FailureCheck` (the teacher's verdicts), `Termination.scaled` (every copy of limits),
  `trackingErrorWithHead` (the judges' error), `filterAction` (Simon's filter), `Learner.decideInto` (a SuperTrack
  decision), `bodyIndexByName` (per-robot names), `observeFrom` (DReCon observations), `gaeColumn` (advantages).
- Every graph-side feature gets a GRAPH-vs-ROWS parity: the training graph's loss equals the same rollout done row
  by row outside it (F6a's test is the template).
- Defaults preserve old behaviour; the night's settings are ONE value (A2's recipe), never scattered overrides.
- Comments casual and verbose; the robot-mocap tutorial in sync with SuperTrack/DReCon, presented when it changes.

---

## 1. The goal, stated so it can fail

**North star (Simon, Oct 5).** ONE policy, ONE objective: Geno dances the whole two-minute dance (`Motion.dance`,
LaFAN's dance1_subject2) very precisely - and from any fall, push or distance gets up and returns INTO the dance
where it now is, fluidly and the way a person would: no switch between "tracking" and "recovering"; the body's limits
respected (torque limits, energy). Trained unattended overnight on a desktop GPU in a browser page at SuperTrack's
pace; later on the phone. The design is R5 (R5.8 the unified objective, R5.9 its judge). Beyond it: the clip library
(~100 LaFAN clips - dances, locomotion, falls and get-ups).

**The FIRST night - the 10-second dance only.** After <= 10 h, ONE SuperTrack policy on `Motion.dance_5_15`, judged
by the judge (mean action, 20 starts every 0.5 s, the task's rule):
- mean time to failure >= 8 s (5x the servo alone's 1.53 s);
- >= 60% of the 20 starts reach the clip's end (the servo alone: 1 of 20);
- mean gated reward above the servo's (0.499); the exploitation index bounded all night;
- visible in the morning: Geno dancing the ten seconds.

**Later nights (Phase C):** the whole dance, precisely (R5.9: local and global position error, velocity and
acceleration error); then recovery into it - from fallen, far, fallen-and-far and pushed starts, the share back in
the dance within 5 s and 10 s, the return without a snap, the effort human (R5.9); then the clip library. Failure is
information: the morning protocol says what to look at.

---

## 2. Principles (each with the evidence that made it one)

- **P1 One task for every clip** - no switch asks which motion it is (failure, reward, starts, physics).
- **P2 The task defines failure; learners and teachers optimise, never redefine it.** Since F3b the rule is
  SuperTrack's own: the head's height within 25 cm of the reference head's, the root within 1 m / 90 deg. A teacher
  may add an early WARNING (T4b), never its own rule.
- **P3 Gravity in everything that scores or ends an episode** (frames hide gravity: lying with the right joint
  angles scored 0.80 once) - the reward's gravity gate, the head rule, heights and up in every observation.
- **P4 Root motion followed - and SEEN** by every policy (DReCon's observation does; SuperTrack's: E2).
- **P5 Simon's filter and clock wherever a policy acts - and inside its training.** Decisions at 30 Hz over 60 Hz
  physics (Simon, Sep 27: physics stays 60 Hz), held between; each decision blended 0.2 new / 0.8 applied; the
  world model learns from what was APPLIED.
- **P6 Judged in reality** - the judge, the servo as the baseline, the teacher as a ceiling where it applies.
- **P7 Measure before believing** - "expected neutral" changes have halved results before.

---

## 3. Where we stand (Sep 27 evening; 3.9 adds Sep 28)

**3.1 Geno** - a free root and 23 ball joints (69 action numbers for SuperTrack; DReCon's 10-joint subset, 30
numbers, for PPO); 21 shape-carrying bodies (`tools/geno_fit.py`, the forefoot rule); standing armature 2.0; the
servo's acceleration cap 3,000 (`servo_gains`); floor friction 2.0; self-collision off; 60 Hz, one step a frame;
`resetToFrame` + `restOnFloor` the one reset everywhere; clips lifted onto the floor frame by frame.

**3.2 The task** (`robot_geno.tracking_task`, a `robot_track.Task`): gains (the zero-velocity stable-PD servo, 20 Hz,
critically damped), `task_weights` (gate 0.2 m / 0.5), `task_termination` = SuperTrack's rule (head 0.25 m, root
1 m / 1.57 rad, every other limit off), `contact_exempt` = the feet (the unexpected-contact limit is off: mechanism
only), `head_body = "Head"`. `servo_task` is the D-phase condition. Episode grace: a learner's aid, never the judge's.

**3.3 Baselines** (the judge on `dance_5_15`: 20 starts every 0.5 s, mean action):
| | MTTF | to the end | reward |
|---|---|---|---|
| servo alone | 1.53 s | 1 / 20 | 0.499 |
| servo + velocity feedforward (dropped) | 1.52 s | 1 / 20 | 0.527 |
| teacher (10 starts every 1 s, 5 s cap) | 1.66 s | 1 / 10 | - |
Get-up, servo alone: 2.75 s, 6 / 36.

**3.4 Judge and diagnostics** - `robot_track.judge` / `Judging` (incremental) / `Actor` / `evenStarts` / `judgeOptions`;
`robot_latent.Learner.diagnose` -> `Diagnosis.trust()` (the model's error following the policy's real states over
the trivial predictor's) and `.exploitation()` (promised minus delivered improvement, over doing nothing). Judge
actors exist for the CPU learner and the GPU resident learner.

**3.5 The CPU SuperTrack learner** (`robot_latent.Learner` + `LatentWorld`): the latent residual world model
z' = z + Net(z, reference targets, applied action) over normalised `track.local` features; 2 tanh hidden layers;
MSE losses; L2 action price (`w_action`), CAPS smoothness (`w_smooth`). Options added Sep 27 (defaults = old
behaviour): `WorldOptions.normalize_from_clips` (F4a), `decide_every` (F4e), `filter` (F6a), `sees_applied` (A1) -
the recipe sets true / 2 / 0.2 / true. `decideInto` is the one definition of a decision; `appliedBefore` gives a
window its filter state; `stepAdam` is every policy update (the seven layers, then A1's block).

**3.6 The GPU learner** (`robot_latent_kit` + `robot_track_resident`, page `geno_train`): parity-tested against the
CPU learner at its DEFAULTS; uses the clip normaliser (F4a); still acts every step with no filter - it lags the
recipe (Stage G).

**3.7 PPO / DReCon and the teacher** - unchanged since v3 (archive §3.5): PPO on the kit with a CPU twin, GAE with
bootstrapped cuts, DReCon's controller (now on `filterAction`); the MPPI teacher (`Planner`, `d5_teacher`) with its
early warning `teacher_warning` / `teacher_danger` (T4b).

**3.8 Pages** - `geno_track` (servo viewer), `geno_ppo` (PPO), `geno_train` (SuperTrack): smokes green and leak-free
(Sep 27 review).

**3.9 Added Sep 28** (the ingredients' infrastructure; the journal has the known answers): `robot_track_env.TrackEnv`
- the tracking task decision by decision, one definition for every learner - with `NStep` (n-step transitions); PPO
steps through it; `robot_sac_track.SacTrack` - SAC on the dance (replay rows carry the bootstrap DISCOUNT, CPU and
kit; optional sample-time observation normalisation); in zimrnum: `categoricalProject`, `softCrossEntropy` (rows and
graph), `Params`, `Graph.detach`, `Graph.simNorm`, `Graph.klGaussianDiag` with a log-std per row; I1b's twin world
models (built, off by default); I1's world noise removed; `docfmt`'s stylesheet fixed and tested.

---

## 4. Done (summarised - designs and numbers in the archived v3 and the journal)

- **Toolchain 2307 and memory ownership** (Sep 26-27): the SPIR-V decoration fix and its two guards; the engine's
  own allocator, the leak tracer; all smokes green, the example side returning exactly 0 bytes.
- **Phase T - the task, one definition** (T1), a worst-body limit (T2, mechanism; 0.8 m chosen, later off), unexpected
  contact (T3, mechanism; OFF after the revisit showed it ending good but lagging rises), the teacher's drift
  weight (T4, 0.3 kept), the teacher's early warning without event limits (T4b: dance 1.94 s).
- **Reorder** (Simon): SuperTrack's foundations on the 10-second dance before any curriculum.
- **SuperTrack studied** - the paper, an unofficial repo (no simulator; five bugs) and ours: `supertrack_comparison.md`.
- **F1 the judge**; **F2 trust and exploitation** (CPU learner).
- **F3 velocity feedforward - dropped** (+1% survival; the option stays, off; its end-of-clip velocity fixed in the
  review).
- **F3b SuperTrack's failure rule - adopted** (equally strict as our five limits; simpler; the paper's).
- **F3c 240 Hz physics - dropped** (Simon: 60 Hz physics, 30 Hz policy).
- **F4a the normaliser from the clips**; **F4e the 30 Hz clock (CPU)**; **F6a Simon's filter inside training (CPU)**.
- **Review (Sep 27)**: `geno_track` compiled again; feedforward's end-of-clip velocity; the learner refuses a filter
  outside (0, 1] or a clock under 1; the tutorial caught up (normaliser, clock, filter); every page smoked.
- **A1 the policy sees what it is applying** (Sep 27, CPU): `LearnerOptions.sees_applied`; the first layer's
  `applied_block` (actions x hidden, starts at ZERO, its own Adam stepped with the seven by `stepAdam`); read in the
  graph (the `applied` Var before each decision), `decideInto` (the slot, reset to rest BEFORE the policy reads it),
  `modelLoss`, `diagnose` and cloning (`appliedBefore`). The seven tensors - the kit's layout - untouched. Four known
  answers, and two planted bugs each caught by the test aimed at it (journal).
- **A2 the recipe as one value** (Sep 27): `robot_geno.supertrack_recipe`, a `SuperTrackRecipe` - the fleet's
  `action_scale` beside the learner's `LearnerOptions` (a bare `LearnerOptions` cannot hold the scale, and a bench
  built from one would train at the fleet's default 0.2 rad). Two known answers: each choice against its reason
  (DReCon's clock and filter, filtered implies sees applied, the page's scale, nothing else overridden), and a learner
  built from it on Geno reads it back (30 decisions a second on the model's timestep, the block, the clip normaliser).

---

## 5. Lessons (do not relearn)

L1 frames hide gravity. L2 a greedy planner needs gravity only where the reference is low. L3 a teacher with memory
the student cannot see teaches noise. L4 cloning 660 rows memorises. L5 an episode's end has a kind. L6 what the
policy cannot see it cannot correct. L7 scale before verdicts. L8 separate the task's failure from a planner's
warning. L9 physics transfers (89 nm). (Evidence for each: archived v3 §4.) New on Sep 27:
- **L10 Equally strict rules end the same runs.** Our five limits and the head rule both catch FALLS, at the same
  moment (1.61 vs 1.53 s servo; 1.56 vs 1.66 s teacher) - so the simpler, published one.
- **L11 Less lag is not more balance.** Feedforward cut the per-step lag threefold and bought 1% survival: the limit
  is balance, which only a policy supplies.
- **L12 A graph and its row-by-row twin must agree.** The filter in the graph was trusted only once the graph's loss
  equalled a hand rollout to 1e-5, holds and starting state included.
- **L13 Pages are outside `check`.** A signature change broke `geno_track` silently for a day.
- **L17 One generator per page, and verify a regenerated page by its CONTENT.** zimrnum-tutorial.html belongs to
  `zimrnum_ref`: its folds are derived from the `zn.` names an example uses - to show a declaration, name it in an
  example. After any tool rewrites a page, check that every section is still there; a build and a fold check do
  not look at prose.
- **L16 A test filter hides the tests it does not match - from the COMPILER too.** Before closing a turn that adds
  a public zimrnum declaration, run the whole zimrnum suite (about a minute): the reference-table test checks
  every public name has a row (`zig build zimrnum-ref` regenerates it from notes in `tools/zimrnum_ref.zig`).
- **L15 `checkGradient` cannot see a parameter the forward pass never uses.** Both its gradients are then zero, and
  agree. Pair it with "every checked parameter has a non-zero gradient" (LayerNorm's gain, planted unused, passed a
  plain `checkGradient` and failed the paired check).
- **L14 Knock the model where it is ignorant, not everywhere.** Uniform noise on the model's predictions made the
  policy correct harder and exploit MORE (I1, removed); the disagreement of two models - zero where the data pins
  them, large where it does not - lowered exploitation at every look (I1b).
- **L15 A segment is not an episode.** A shove ends a segment (the world model cannot predict it) but not an episode
  (the controller's filter carries through). What was applied before a record needs the record's place in its
  EPISODE (`Replay.episodeStepAt`); an unknown one is reported, never guessed.
- **L16 Fresh memory reads as zero, so an uninitialised read passes every test.** The learner's slots were read
  before their first write for three steps (A1, F6a, F4e) without a symptom. A value read before its first write
  gets an explicit start - and a test that fails without it (the hand-over check).
- **L14 A parity measured through the loss hides the action path.** At the untrained output layer's 0.01 scale a
  wrong action moves the loss far less than the tolerance: F6a's graph-vs-rows test passed with the graph feeding
  the wrong applied action. Compare the actions themselves, and plant weights under which every input matters.

---

## 6. The work ahead - fundamentals first

(Published methods worth reproducing whole - each broken into ingredients with known answers - live in their own
section, **10. Recent advancements**. Its ingredients feed Stage I; its reproductions are measured on the bench.)

Each step: WHY - DESIGN - KNOWN ANSWER - DONE WHEN - SIZE (turns). CPU first; the kit follows what is adopted.

**6.0 THE ORDER ACROSS STAGES** (Sep 28, revised by Simon at the end of the day: "we don't need to measure things
now. The goal is to have all the necessary ingredients to be able to later build modern RL algos ... Focus on building
blocks, verifying they work. Make it all feel native to zimrnum and nice to look at." - where this and a stage's own
"NEXT" disagree, this wins). BUILDING BLOCKS FIRST, each with its known answers and a negative control, each native
to zimrnum (one definition per idea, the house idioms, comments that teach the idea); the ALGORITHMS are assembled
from them afterwards; measurements (V5, the benches) wait until a decision needs one.
  1. **N2 - the vocabulary.** DONE Sep 28: `detach`, `simNorm`, the per-row Gaussian KL, `symlog` / `symexp`,
     `CategoricalScalar` (two-hot through the SAME split as `categoricalProject`: `addPointMassToGrid`), and the
     layers' first half on zimrnum's own `Dense` template (a layer owns its tensors; `attach` records it on any
     graph; no `Sequential`): `Dense.attachAs(graph, input, .trained | .frozen)` and a `LayerNorm` layer with its gain
     and bias; and, Sep 29, the rest: `Activation` (none / relu / mish / SimNorm with a group) and `Graph.activate`;
     `NormedDense` (BMPC's NormedLinear: Dense, dropout when an rng is given, LayerNorm, the activation);
     `InitScheme.small_normal` (TD-MPC2's std-0.02 normal - its "truncated" bounds are absolute and never bind);
     `Mlp` from a `Spec` (hidden NormedDense layers; a plain head, zeroed for reward and value heads, or a normed last
     layer ending in SimNorm), with `attachAs` (all handles for an `Optimizer`), `params` (a `Params` over the same
     tensors - `clone` for a target), `withParams` (the architecture over a target's tensors), `deinit`. Known answers:
     BMPC's shapes and counts, the initialisation's statistics, a zeroed head, refused specs; `checkGradient` through
     three layers ending in SimNorm with every parameter CONNECTED (L15) and every output group a simplex; frozen =
     trained, a target that stays put then follows; dropout only with an rng and only where the spec has it; each
     activation its op; every byte back under every allocation failure. Negative control: the last layer's
     activation dropped fails exactly the simplex test. N2 COMPLETE.
  2. **N3 - the rollout builder and the world-model loss terms.** DONE Sep 29. First half: every layer now separates
     BINDING from ARITHMETIC (`applyBound` on Dense / LayerNorm / NormedDense; `Mlp.bind` and `Mlp.apply`, `attachAs`
     = both; one `bindTensor` for every trained-or-frozen choice) - binding a tensor at every step would register it
     as H separate parameters, each with a slice of the gradient; and `LatentRollout` (one encoder pass over a
     step-major window, the per-step latents sliced, the targets detached, the rollout started from z_0 WITH
     gradient, the dynamics applied H times over one set of handles, the consistency loss rho^t-weighted and averaged).
     Known answers: each rolled latent is the dynamics applied step by step from the first true encoding, bit for
     bit; the loss is the hand computation; the dynamics pass `checkGradient` and every parameter of both networks is
     connected; the encoder's gradient equals the one from a graph whose targets come from a FROZEN second encoder
     pass (finite differences are no answer for the encoder - nudging it moves the detached targets too); the batch
     rollout is each character's, row for row. Negative control: the rollout started from the detached z_0 fails the
     encoder-gradient test. Second half: `WorldModelLoss` - the reward head on each rolled latent with its action,
     every value head on each rolled latent (an array of `Mlp`s with their handles; dropout from an optional rng),
     both scored by `softCrossEntropy` against two-hot targets the builder allocates as constants (fill with
     `CategoricalScalar.encodeRows`, `recompute` - nothing rebuilt), rho^t over the steps, the value term averaged
     over the heads too, BMPC's total 20 / 0.1 / 0.1; the logits exposed. Known answers: reward and value terms equal
     a hand computation that re-applies the heads to the ROLLED latents' values; refilled targets are read at the next
     recompute and only then; `checkGradient` through the heads and the dynamics with every parameter of every
     network connected. Negative control: value heads reading the detached targets fails exactly the rolled-latents
     test.
  3. **N4 - planning by recompute, and `Mppi`** as a zimrnum planner. FIRST HALF DONE Sep 29: `LatentPlanScorer` -
     the planner's objective (r_0 + gamma r_1 + ... + gamma^H mean V(z_H)) as a graph built once from frozen
     bindings, many states at once (rows state * candidates + candidate; each state encoded once, its latent copied
     by a constant 0/1 product), the bins read back by `decodeRows` after the recompute. Known answers: every row's
     score equals a hand computation that encodes that row's state alone and rolls its own actions; rewriting one
     candidate's actions moves only its score. Negative control: every candidate starting from state 0 fails the
     hand computation. Tutorial 18d.7. SECOND HALF DONE: `Mppi` - `begin` (warm start: last plan shifted one step,
     zero at an episode's start; spread at its ceiling), `sample` (mean + spread x counter-based noise, clamped; the
     caller's policy rows untouched), `refit` (the elites by zimrnum's `argsort`, weights e^(temperature (score -
     best)), the weighted mean and deviation, spread clamped; non-finite scores count 0), `choose` (a drawn elite, the
     best, or the mean; optional exploration jitter), `plan` (the whole loop over a `LatentPlanScorer`). Known answers:
     convergence to a planted optimum (worst simulated error 0.016 over 200 seeds, tested at 0.06) with spreads at
     their floor; policy candidates only returns the best of them exactly and sampling writes nothing; the refit by
     hand; the warm start's shift; samples in [-1, 1], reproducible, different per iteration; `plan` = its steps, bit
     for bit. Negative control: inverted weights fail the hand refit - and ONLY it: elite selection alone converges,
     so the weighting is pinned by the exact computation. Tutorial 18d.8. N4 COMPLETE.
  4. **N5 - `SequenceReplay`** (per-environment rings, masks, write-back). FIRST HALF DONE Sep 30: built on
     `ReplayBuffer` (one ring per environment - the ring is ReplayBuffer's idea, which gained chronological access:
     `slotOf`, `row` in place, and a `deinit`); `push(rows, active)` writes one step of every environment, an
     inactive one nothing; `sample` draws windows as (environment, start) - the environment uniform among those with
     enough steps, the start uniform in its ring - copied STEP-MAJOR (rows t * windows + w, LatentRollout's layout),
     with `finished` 0 up to and including the window's first done and 1 after. Known answers: every window is
     consecutive steps of one environment, including one crossing the ring's physical wrap; `finished` by hand for
     every drawn window. Negative control: marking the done step itself finished fails exactly the finished test.
     Tutorial 18d.9. SECOND HALF DONE Sep 30: `sample` also reports each window's `WindowOrigin` (its environment
     and the PHYSICAL slot of its first step - still valid after later pushes, until overwritten); `writeBack(origins,
     first_step, step_count, first_column, values_in)` copies step-major values into those windows' rows in place
     (reanalyze: a prefix of the origins, first_step 1); empty targets are N(0, 1), written by the caller at push.
     Known answers: after a write-back both rings equal a hand-applied copy EXACTLY, and every unwritten row still
     reads N(0, 1); a frame an environment sits out leaves its ring byte-identical (storage, head, length).
     Negative controls: ignoring first_step fails exactly the write-back test; ignoring the active mask fails
     exactly the inactive one. Tutorial 18d.9 ("Targets that improve"). N5 COMPLETE.
  5. **The ensemble blocks**: members as arrays (mean, variance of the mean) and R3's KL-robust aggregation (R3.7's
     answers; its gradient as tilted weights). DONE Sep 30. Members as arrays needed NOTHING new: an ensemble is an
     array of members (an array of Params), and `meanAxis` / `varianceAxis` over the member axis give eq. 3's mean
     and, divided by the count, eq. 4's variance of the mean (the caller picks ddof). The new block is
     `klRobustExpectation(T, values, delta, tilted_weights_out)` - plain arrays in, one value out: the derivative of
     the KL dual is KL(tilted weights || uniform) - delta, so beta* is the temperature whose tilt sits EXACTLY delta
     from uniform (bisected on a log scale - KL falls monotonically in beta), and the value is the tilted average;
     delta 0 -> the mean, delta >= log(N / k) -> exactly the minimum (k tied lowest). Known answers: the limits
     (exact); the value SANDWICHED - no feasible reweighting (mixtures of uniform with one- and two-value spikes)
     averages lower, and the dual objective computed from its formula never goes higher and meets it at its best
     beta (1e-6) - while the weights sit delta from uniform (1e-9) and order inversely to the values; small delta:
     (mean - robust) / (sqrt(2 delta) std) = 1 +- 0.005 at 1e-4; central differences = the tilted weights (1e-6).
     Negative control: the bisection walking the wrong way fails exactly tests 2-4 (the limits never search).
     Tutorial 18d.10 "Pessimism with a dial".
  6. **TD4's blocks (T5, T6)**: the categorical twin critic's pieces; the deterministic actor family's (pre-activation
     penalty, target smoothing, policy delay, decaying exploration noise).
  7. **V1's block**: a differentiable observation SELECTION on the graph (asymmetric observation); **V2b's**: a DAgger
     buffer (the student's states, the teacher's labels). DONE Sep 30. V1: `gatherColumns` - plain (the one the game
     calls; every column checked before any write) and `Graph.gatherColumns`, a product with a constant 0/1 selection
     matrix built from the existing `oneHotRows`, transposed - no new op, exact (equal as numbers; a negative zero comes
     back as zero), its gradient matmul's own. Known answers: every column in order gives back the input; graph =
     plain under a reordering with a repeat and a column left out; checkGradient, exactly zero for the unchosen, and a
     column chosen twice gets twice one output's hand gradient. Negative control: the plain gather reading the next
     column fails exactly the plain and parity tests. V2b needs NO new zimrnum code: a DAgger buffer is a
     `ReplayBuffer` whose rows are the student's state followed by the teacher's action; the teacher, and the row test
     (labels = the teacher's actions at the student's own states), belong to the robot assembly (V2), where a teacher
     exists. Tutorial 18d.11.
  8. **Then the assemblies**: BMPC (N6), EfficientTDMPC's options (N7), TD4 (T7), SuperTrack's V1 / V3 variants, the
     mixes (I4) - and the measurements (V5, N8's ladder, the multi-clip benchmark) when choosing between them.
  9. **The kit** (Stage G, N9, T8, V4c) for whatever is adopted.
  Stages C-F keep their designs and are revisited when a question they answer comes up; I2 (DroQ / CrossQ) is an
  assembly of blocks already here and waits for 8.

### Stage A - finish the action path (CPU)

**A1 The policy sees what it is applying** (v3's F6b). **DONE Sep 27** (section 4, journal).
- WHY: with the filter, what to ask depends on what is already being applied; DReCon's observation carries it.
  Without it the policy is blind to half of its own control state.
- DESIGN: `LearnerOptions.sees_applied` (default false). The policy's first layer gains a block `W_applied` (actions x
  hidden); its input is the action being applied BEFORE the decision - the slot's value in `decideInto` (rest at an
  episode's start), the `applied` Var entering the decision in the graph, the filter state in `modelLoss` and
  `diagnose`. The CPU parameter layout grows only when the option is on, so the kit's parity at defaults is untouched.
- KNOWN ANSWERS: with `W_applied` zero, outputs are bit-identical to the policy without it; the graph-vs-rows parity
  (F6a's test) with the option on; the judge's actor feeds the slot's value (a unit check with a planted slot).
- DONE WHEN: robot_latent green, both parities. SIZE: 1.

**A2 The recipe as one value.** **DONE Sep 27** - as a `SuperTrackRecipe` (scale + learner options; section 4).
Planned as `robot_geno.supertrack_recipe: robot_latent.LearnerOptions` (normalise from clips,
decide every 2, filter 0.2, sees applied, `supertrack_action_scale`, sigma) - the bench, the pages and the night
read it; a test checks each field against the plan's intent. SIZE: with A1.

### Stage B - the bench (from v3's F10, moved to the front: every later choice is a learning-curve question)

**B1 `zig build st-bench`** - a deterministic CPU SuperTrack run on `dance_5_15` with the recipe. **BUILT Sep 27**
(`src/robot_st_bench.zig`, rooted in `src/` - a `tools/` root cannot reach the robot files; installed to
`tools/zig-out/bin/st_bench`; its known answers pass - journal). **10-minute run DONE Sep 28** (journal; CSV and curve
in `src/notes/bench/`): MTTF falls from the untrained 1.52 s to ~0.56 s and stays; trust 3.1 -> 0.23 (the world model
learns); exploitation ~100 (the policy exploits it). Reviewed:
refuses what the learner refuses (`LearnerOptions.problem`); looks do not touch training. Two builds (Simon, option
C): `st_bench` ReleaseFast for long runs, `st_bench_safe` to clear a configuration's first stretch, `--compare` to hold
them together; an error-level log is fatal in both.
- DESIGN: a small host tool (`tools/st_bench.zig`) over the CPU learner: 8 characters, a replay of >= 30 s in total,
  batch and windows at CPU sizes (hidden 64-128, batch 32-64); each iteration collects a few steps, then one world
  step and one policy step (SuperTrack's rhythm). At iteration 0 and every M iterations: the judge (20 starts) and
  `diagnose` (trust, exploitation) -> one CSV row (iteration, wall seconds, samples, world loss, policy loss, MTTF,
  share to the end, reward, trust, exploitation). Options: minutes, seed, recipe overrides (for A/Bs), output path.
- KNOWN ANSWERS: the same seed gives the same CSV (wall time aside); iteration 0's judge row is the untrained policy's
  (near the servo's, since the policy starts near zero); the iteration rate is reported.
- DONE WHEN: a 10-minute run writes its CSV and the curve is shown. SIZE: 1-2.

**B2 The baseline curve** - DROPPED by the 5-minute rule (Sep 28): B1's 10-minute rows ARE the baseline (a build
with every new knob off reproduces them exactly). Its stop rule, read on B1: MTTF does not rise, the world half
learns, the policy exploits the model - so the work turns to the ingredients (Stage I). The first learning
signal on this dance: does MTTF rise above 1.53 s? Every later A/B is against this curve. If it does not rise at
all: stop, and read trust and exploitation to learn which half fails, before touching the recipe. SIZE: 1.

**B3 The bench's resolution** (Sep 28, from I1b's seeds) - DEFERRED (Simon, Sep 28: "avoid getting stuck with
benchmarks" - the ingredients first; I1b stays built and off, its verdict waits for B3). The effects being tested are
~0.1 s of MTTF; the
seed-to-seed spread of one configuration is ~0.5 s; the judge sees 20 starts. So a verdict needs (a) a summary over the
run, not one look - the mean of the looks, or the area under the MTTF curve; (b) several seeds per arm, each within the
5-minute rule (three 3-minute seeds = one arm); (c) the judge's own noise measured: the same policy judged from two
different sets of 20 starts. DONE WHEN the bench reports a run's summary and a tool compares arms over seeds with
their spread. SIZE: 1.

### Stage I - the ingredients, then the mixes (Simon, Sep 28: "work on the ingredients so we can then mix them")

Each ingredient built on its own, OFF by default, with its known answers, and measured on a <= 5-minute bench arm
against B1's rows; mixed only once each is understood alone. In order, foundations first:

**I1 Noise on the world model's predictions** - built, measured HARMFUL at 0.2 (exploitation ~290 vs ~135, MTTF 0.32
vs 0.53 s over iterations 300-600: every knock is an error the policy is scored on, and the cheapest fix is a harder
correction - what the model believes and the body cannot deliver), and REMOVED (Simon, Sep 28). The data stays in
`src/notes/bench/`, the story in the journal; the lesson is L14.

**I1b Two world models and their disagreement** (Simon, Sep 28) - GENERALISED by R3.8's V3 (a KL-robust soft maximum
of the policy's cost over K models; delta = 0 is this arm's average without the price), and its "NEXT: seed 3" is
superseded by the order in 6.0. Train a SECOND world model on the same data from a
different initialisation; the policy's rollouts step through their AVERAGE, and pay `w_disagree` times the squared
distance between the two predictions at every step. Why it can work where I1's uniform noise failed: where data pins
the models down they agree; where the policy wanders off the data nothing does, so they diverge - disagreement marks
exactly where the model cannot be trusted, which is where the policy exploits it (MOPO's pessimism, from two models).
The penalty's gradient steers the policy back toward states the models agree on, and knocks nothing it knows well.
KNOWN ANSWERS: one model = today's learner exactly (B1's rows); with two, graph-vs-rows parity (the average and the
penalty, row by row); two models from the SAME initialisation have zero disagreement to the bit. Bench: an arm at 4
minutes against B1. Cost: a second world step per iteration and a second model inside every rollout. **BUILT and
first measured Sep 28** (`twin_world`, `w_disagree`, `twin_seed`; `Learner.trainWorld`, `modelStepRow`; bench
`--twin-world`, `--w-disagree`): parity with and without every other ingredient, a same-seed twin changes the loss
not by a bit, a twin stepped but never averaged is caught; twin off reproduces B1. **At w_disagree 1 (4 min, 436
iterations at 1.9 it/s): PROMISING** - exploitation lower at every look (48 / -62 / 86 / 94 vs 299 / 78 / 131 / 136),
tracking reward up to 45% higher by iteration 400 (0.226 vs 0.155), MTTF modestly better at three of four looks - and
better at equal WALL time despite the cost. Not yet adopted (one seed; MTTF still far under the untrained 1.52 s).
**Prices 3 and 10 (Sep 28): not a dose curve** - w 10 beats the
baseline like w 1 (reward 0.215-0.230, exploitation ~95, the best MTTF of any arm: 0.80 at iteration 300, 0.69 at
392), while w 3 between them COLLAPSED (MTTF 0.28-0.36, exploitation up to 1,796). A collapse bracketed by two
working arms reads as run-to-run variance on one seed, not a dose effect - the rule: a second seed before any
adoption. **Seed 2 (Sep 28, 3-minute arms): unresolved.** Seed 2's
own baseline sits 0.46 s above seed 1's (mean MTTF over looks 100-300: 1.08 vs 0.62) while the prices move the
two-seed mean by at most 0.06 s (base 0.85, w 1 0.91, w 3 0.86, w 10 0.83); each price wins one seed and loses or ties
the other (w 3: the collapse on seed 1, the best arm on seed 2 - 1.37 s at its last look). The one pattern both seeds
share: in EVERY arm MTTF drifts down as training goes on. NEXT: seed 3 (same four arms), then decide with three seeds
- and B3 below, because one run cannot resolve effects this size.

**I2 DroQ and CrossQ critics** (journal 7's S3, never built): `SacAgent` gains the critic variants its parts already
support - DroQ (dropout + layer norm, the minimum over M masks of ONE critic, many updates per step) and CrossQ
(batch norm, no target networks, current and next batches through the critic together). KNOWN ANSWERS: the masks'
minimum on planted numbers; CrossQ's batch statistics taken over the joint batch; each variant on the cartpole gate
inside 5 minutes against plain SAC.

**I3 SAC on the tracking task.** Step one BUILT Sep 28: `robot_track_env.TrackEnv`, the tracking task as a
DECISION-level environment - observe; `decide` clamps, holds for `decimation` steps, credits the reward up to the first
end, classifies the end (`.none` / `.stop` lost / `.cut` out of time) and, for a cut, reads the terminal observation
before the controller forgets the filter. One definition for every learner: PPO, SAC, the mixes. KNOWN ANSWER: held
decision for decision against PPO's own `collectOne` on twin fleets - observations, credited rewards, ends, and every
cut's bootstrap (PPO's critic on TrackEnv's terminal observation) identical; a planted cap-as-stop fails it. **PPO moved
onto it Sep 28**: its copy of
the logic deleted, `EndKind` / `ClipEnd` now the env's (PPO re-exports them); a fingerprint of two PPO iterations
(every learning array hashed, the weights after each update) identical before and after - only the reported mean
reward's 7th digit moved, the batch's reward sum now added per character (stats only). Both pages that reach the
trainer's fleet (`geno_ppo`, `getup_train`) updated and smoked in release; PPO's test root 509 pass, 75 skip. **SAC on
the dance BUILT Sep 28** (`src/robot_sac_track.zig`, `SacTrack`): each fleet decision, SAC draws, `TrackEnv` decides,
every transition goes into SAC's replay - next = the next decision's observation, or on a cut the terminal capture
with done FALSE; done TRUE only on a stop - then `updates_per_decision` updates (the UTD knob DroQ turns up). KNOWN
ANSWERS: every replay row held field by field against a twin env driven by the recorded actions (cuts and stops both
exercised); a planted cut-as-termination fails it; a learning smoke - updates run, the actor moves, the critic's loss
stays finite. No observation normaliser yet (raw DReCon observations: a running normaliser and a replay need a
decision of their own). NEXT: the shared actor - SuperTrack's policy and SAC's the same network (inputs, outputs,
weights), so a mix can hand one policy between them; then I2's critics (DroQ, CrossQ) on this SAC.

**I4 The mixes** (after I1-I3): SAC to start (sample-efficient early), then SuperTrack; SuperTrack's loss and SAC's
critic gradient on ONE actor; PPO (`robot_ppo_track`) beside them. Each mix a bench arm against its parts.

**I5 TD4 - Twin Delayed D4PG** (Simon, Sep 28: "study this rl setup, in particular td4 ... we really want all
ingredients available"). Source: roxie, a JAX framework (seven agents, MuJoCo) - `roxie/agents/td4.py`,
`losses/critic_losses.py` (`td4_critic_loss_fn`, `wasserstein_blend_logits`, `_smoothed_target_actions`),
`losses/actor_losses.py` (`td4_actor_loss_fn`, `pre_activation_penalty`), `agents/utils.py` (`repack_samples`),
`utils/math.py` (obs statistics), `configs/agent/td4.yaml`, `experiments/dmc/agent/td4_bench.yaml`; paper arXiv
2505.22642. WHAT IT IS - TD3's machinery with D4PG's categorical critics:
  - a DETERMINISTIC actor, tanh-squashed, layer norm, 256 x 256; exploration = Gaussian action noise 0.4 decaying
    linearly to 0.1 over 40% of the budget;
  - TWIN CATEGORICAL critics: MLP (ReLU, layer norm - "a strong stabilizer against value divergence") -> logits over
    a fixed support (C51); Q = softmax . atoms. Their benchmark: 101 atoms on [-5, 120] (rewards in [0, 1] at gamma
    0.99 bound the return near 100 - true of our tracking reward too);
  - target actor and target critics, polyak tau 0.005; target smoothing: N(0, 0.2) clipped to +-0.5, then to [-1, 1];
  - the target DISTRIBUTION from the twin with the LOWER mean, per sample (`twin_q_weight` 1.0 = the min; below 1 it
    is blended with the other twin along their QUANTILE functions - a Wasserstein interpolation, reprojected - because
    mixing densities would add a second mode and smear the support over backups);
  - loss per twin: categorical TD - the target shifted to r + discount * z, projected onto the support, cross-entropy
    against the online logits (`rlax.categorical_td_learning`);
  - actor loss: -mean of the FIRST critic's Q, + an optional one-sided pre-tanh penalty sum relu(|u| - 1)^2 (off in
    their benchmark); actor and both targets updated every 2 critic steps (policy delay);
  - 5-STEP returns: the return sums gamma^k r up to the window's first end; a termination ends it with no bootstrap,
    a truncation bootstraps from the observation there at gamma^k, a surviving window from step n at gamma^n - each
    sample carries its own discount;
  - observations normalised at SAMPLE time (running sums, clip 5), replay rows RAW - stored rows never go stale;
  - Adam 3e-4 both, GLOBAL grad-norm clip 1; batch 512, replay 500k, warm-up 30k; 1024 envs at 20 updates per 2048
    env steps (massively parallel, LOW update-to-data - ours today is 8 envs on one core, the high-UTD end).
  Their result: HumanoidWalk 989 from the released checkpoint; in their 500M-step grid the categorical critics (TD4,
  D4PG) lead on CPU physics - and TD4 scored 38 on HumanoidStand on GPU physics: strong, not uniformly robust.
HAVE (tested): graph ops relu, tanh, softmaxRows, layerNormRows, min, log, matmul, concat, dropout, mseLoss; Adam
(`gym.AdamSet`); `polyakUpdate`; `clipGradNorm` (global, direction-preserving); `ObsNormalizer` (f64 Welford - roxie
keeps f32 sums); `ReplayBuffer`; `OrnsteinUhlenbeck`; twin critics with a pessimistic target (`SacAgent`); `TrackEnv`
with termination (`.stop`) vs truncation (`.cut` + its terminal observation) - exactly what n-step returns need;
`SacTrack`'s replay mapping.
MISSING - built in this order, each with its known answer:
  - **T1 n-step transitions.** DONE Sep 28. The replay row's last column is the bootstrap DISCOUNT (CPU `SacAgent`:
    `remember` stores gamma(1 - done), `rememberDiscounted` takes one; the kit's `sac_target`; SAC fingerprinted
    bit-identical, the kit still equal to the CPU agent update for update). `TrackEnv.NStep`: a ring of n pending
    decisions per environment - a full window emits its oldest at gamma^n; a cut emits every pending one at gamma^k
    with the terminal observation; a stop emits them all at zero; returns summed newest-first, so n = 1 is the one-step
    row untouched. `SacTrack.Options.n_step` routes every transition through it. KNOWN ANSWERS: planted rewards at gamma
    0.5 against the closed form (full windows, a cut, a stop, a cut on an episode's first decision); n = 1 equal to the
    one-step rows bit for bit; an off-by-one in a cut's discount caught by both; SacTrack's row test unchanged at n = 1
    through NStep; SAC learns at n = 1 and n = 5.
  - **T2 Sample-time normalisation.** DONE Sep 28: `SacOptions.normalize_observations` (off by default - the agent
    exactly as before), clip 5; training actions feed an f64 `ObsNormalizer`, evaluations only read it; `sampleBatch`
    normalises each batch's copy. Known answers: stored rows are the RAW inputs (planted storage-time normalising
    fails it); sampled rows equal their originals normalised by hand; later statistics change batches, never rows; an
    evaluation acts on the hand-normalised observation without feeding the statistics; SAC learns with it at n = 5.
    The design as first planned: Raw rows; `ObsNormalizer` fed from acting; every sampled batch's observations
    and next observations normalised (clip 5) with the statistics of that moment - which also settles SacTrack's open
    question. KNOWN ANSWER: the batch equals the rows normalised by hand with the same statistics; later statistics
    change batches, never stored rows.
  - **T3 The categorical projection** - DONE Sep 28: `zimrnum.categoricalProject(T, v_min, v_max, probs, reward,
    discount, out)`, each moved atom split between its two neighbours by closeness (the upper is always the next atom,
    so an exact landing keeps its mass - the textbook floor/ceil version loses it, and the planted version fails the
    point-mass and clamping tests). Six known answers pass. The plan as first written: (C51; rlax
    `categorical_l2_project`): a distribution on the shifted support r +
    discount * z, projected back onto the fixed atoms - a pure function. KNOWN ANSWERS: mass conserved; a point mass on
    an atom stays; one between two atoms splits in proportion to distance; beyond the support it clamps to the ends;
    discount 0 gives a point mass at r.
  - **T4 Soft cross-entropy on the graph** - DONE Sep 28: `Graph.softCrossEntropy(logits, targets)`, the target as
    DATA like `mseLoss` (no gradient into it). Graph known answers: its value is the row function's, `checkGradient`
    passes; composed through a layer, under a scale of 3, and after its target is refilled and recomputed; a backward
    that ignores the incoming gradient fails exactly the composition test. First half: the math as plain row functions,
    `zimrnum.softCrossEntropyRows` / `softCrossEntropyRowsGrad` (+ `rowLogSumExp`) - known answers: one-hot targets
    give the hard-label loss and gradient exactly; at prediction = target the gradient is zero and the loss the
    target's entropy; the gradient matches central differences; a dropped division by rows fails two of them. LEFT:
    the graph op (builder, backward, recompute) with `checkGradient`. The plan as first written: a primitive
    `softCrossEntropy(logits, target_probs)` with its own
    backward ((softmax - target) / rows), stable where `log(softmaxRows)` is not. KNOWN ANSWERS: `checkGradient`; equal
    to `crossEntropy` on one-hot targets.
  - **T5 The categorical twin critic.** Its network (ReLU, layer norm, logits over the atoms), Q as the categorical
    mean, the target from the lower-mean twin per row, and the quantile blend + reprojection for weight < 1. KNOWN
    ANSWERS: weight 1 = the lower twin exactly, weight 0 = the upper; a distribution blended with itself is itself; the
    blend's mean lies between the two; the critic loss on planted logits against a hand computation. DONE Sep 30, as
    `CategoricalScalar` methods (it owns the grid; `.identity` = C51 / TD4 return atoms): Q = `decode` (existing);
    `quantileBlend` - one walk up both CDFs, each slice of probability placed at the blended bin INDEX (bins evenly
    spaced on the axis) and landed by the shared `addPointMassToGrid`; `twinTarget` / `twinTargetRows` - the lower-
    mean twin per row (a tie: the first), blended by the weight. The network is the existing layers (N2). Known
    answers, sharper than planned: the blend's mean EXACTLY the weighted mean (1e-12); two point masses blend into ONE
    point mass between them; the critic loss (categoricalProject then softCrossEntropyRows) = the hand computation.
    Negative controls: the weight on the wrong twin fails exactly the mean and point-mass tests; the higher twin chosen
    fails exactly the two selection tests. Tutorial 18d.3 ("Twin critics, kept distributions").
  - **T6 The deterministic TD3-family actor.** A tanh MLP (layer norm) that also returns its pre-activation; the
    actor loss -mean Q1 + coef * (relu(u - 1)^2 + relu(-u - 1)^2) (no abs on the tape); a target actor (polyak);
    target smoothing; policy delay; Gaussian exploration on a linear schedule. KNOWN ANSWERS: the penalty is zero
    inside +-1 and its gradient matches finite differences; the delay counts updates; the schedule's end points.
    DONE Sep 30. The actor is the existing layers (tanh, layer norm; the pre-activation is the Dense output before
    `tanh`), the target actor `polyakUpdate`. New: `Graph.preActivationPenalty` (composed of existing ops - a row of
    -1s broadcast by add, two relus, squaredRowNorm, the mean over rows - no abs on the tape); `linearSchedule` (from
    the step alone, both ends exact); `policyUpdateDue` (after every delay-th critic update; 0 refused);
    `addGaussianActionNoise` - ONE function for exploration (no clip: infinity) and target smoothing (std 0.2, clip
    0.5), its counter draw_index * len + i so wide batches never repeat noise. Known answers: the penalty's value by
    hand (2.125) and checkGradient (1e-7), zero value AND gradient inside the band; the delay's 33 actor updates in
    100 at delay 3; the schedule's exact ends, midpoint, flat tail, refusals; the noise clipped, kept in [-1, 1],
    reproducible, zero std = no change, and unclipped its measured std (5%). Negative controls (one scratch copy):
    the penalty's lower side dropped, the delay off by one, the slope over the whole run - each fails exactly its
    own test; the noise tests pass. Tutorial 16.12 "A deterministic actor".
  - **T7 The TD4 agent**, assembled on the CPU graph like `SacAgent`: first on the cartpole gate (inside 5 minutes),
    then on `TrackEnv` beside SacTrack, reading the same n-step rows. The byproducts come nearly free - TD3 (T6 with
    scalar twin critics), D4PG (T3-T5 with one critic, no smoothing), DDPG - so roxie's comparison grid can be ours.
  - **T8 GPU parity** (Stage G): the categorical critic, the projection and the soft cross-entropy as kit kernels,
    checked against the CPU graph - the route to roxie's regime of many environments.

### Stage C - the recipe, decided on the bench

Each an A/B against B2 (same seed; a second seed when the two disagree); adopted only on a clear judge win with
exploitation bounded; the curves recorded in the journal.

**C1 Offset scale and noise** (v3 F4c): 0.6 vs 2.09 rad a unit (the paper's 120 deg), sigma 0.1 of a unit, with
the filter on (which already divides a single decision's reach by five). SIZE: 1.

**C2 The policy's loss as the paper's** (v3 F4b, policy half): L1 per GROUP in LOCAL raw space - positions,
velocities, two-axis rotations, angular velocities, heights, up - with weights that make each group contribute
equally at the start (measured on the first 100 batches, then frozen); the offset penalties L2^2 + L1 at 1/100 of
the tracking terms. Needs: an L1 graph op (gradient sign(y - t) / n), the `track.local` layout as named group
slices, de-normalisation in the graph (scale and shift). KNOWN ANSWERS: the op's gradient by finite differences;
the slices cover the feature vector exactly once; a perfect rollout's loss is 0; graph-vs-rows parity. SIZE: 2.

**C3 The optimiser** (v3 F4d): gradient-norm clipping (25 world, 100 policy), a linear warm-up over the first 2% and
a polynomial decay (power 0.9) to 10% for long runs, the policy rate 1e-4 vs 3e-4. KNOWN ANSWERS: a small gradient
passes untouched, a large one lands exactly on the norm; the schedule's value at 0, at the warm-up's end, at the
end. SIZE: 1.

### Stage D - the world model's form (v3 F9, with F4b's world half)

**D1 Rigid-body ops in the graph** - quaternion product, exp map (rotation vector to quaternion), rotating a vector,
conjugate, the two-axis encoding - each with a finite-difference gradient check. SIZE: 1-2.

**D2 `AccelWorld`** - the paper's model: the same inputs as the latent model; per-body LOCAL linear and angular
accelerations out; to world by the root's rotation; semi-implicit integration (velocity first, position with the new
velocity, rotation exp(dt/2 w) (x) q); `local` recomputed for the next input; the loss L1 in WORLD space (position,
velocity, rotation log-difference, angular velocity) with equal starting contributions. KNOWN ANSWERS: a zero network
rolls out CONSTANT VELOCITY exactly; a network that outputs the TRUE accelerations of a recording reproduces the
recording to float precision over 8 steps; gradients by finite differences; graph-vs-rows parity. SIZE: 2.

**D3 The A/B** - latent vs acceleration on the bench at equal compute, with F2's trust on held-out windows as the
second axis. Keep the winner. SIZE: 1.

### Stage E - scale and drift (v3 F8, F7)

**E1 Windows and scale** - world 8 / policy 32 (16 decisions at 30 Hz); batch and replay as large as the bench
sustains; widths 64-256 on the CPU (the night's come from the desktop probe, ON-a). Measured on the bench.
**E2 Drift** - the policy's input gains the reference root's place and heading from the character; the loss prices
the root's world offset (the paper's rough-terrain variant). KNOWN ANSWER: the input does not move with the character
(DReCon's observation test, twinned). SIZE: 1 each.

### Stage F - the feasible reference (v3 F5), beside the rest

**F5.1** The clip's second channel (servo targets beside the achieved poses) and the fleet reading it - KNOWN ANSWER:
a clip whose target channel equals its pose channel runs bit-identically to today. **F5.2** The offline search on
`dance_5_15` (SAMCON's: short windows, many samples, a beam, backtracking, a stricter shape cost) - KNOWN ANSWERS: the
bake reads back identical; from every judge start the servo alone reaches the end with zero error; fidelity to the
mocap reported and gated. **F5.3** The bench A/B: the original clip vs the feasible one. SIZE: 1 + 2-3 + 1.

### Stage G - the kit catches up (GPU parity for each adopted piece, in adoption order)

The clock (decisions every 2 steps in the rollout kernels), the filter (in-kernel blend and its gradient),
`sees_applied` (the policy layout), the losses, the optimiser, the world model's form. Each: CPU-vs-kit parity at
small sizes with the existing harness, then `geno_train` on the recipe. SIZE: 1 per piece, more for the form.

### Stage H - the gate (v3 F10)

A 30-minute bench run with the chosen recipe: MTTF >= 3 s (2x the servo) and still rising, trust under 1,
exploitation bounded. Pass: Phase R. Fail: the curve says which stage to reopen.

### After the gate (designs in the archived v3 §5)

- **From R4 (Oct 1), for later:** RAY-TOLD's hybrid - an NPC planning with EXACT short rollouts (kinematics, or zimr's
  physics) plus a learned terminal value, in our scorer-agnostic Mppi, with RAYCASTS as its observation (a game-cheap
  V1 view); IQL-TD-MPC's manager of latent subgoals above the tracker, for layered behaviours (where to go, which
  clip). Newt's open-loop rollout length as a world-model diagnostic belongs with V5's measurements.

- **Phase R - runs** (Simon's workflow): `RunConfig` + a compatibility hash; the snapshot zip (`run.json`,
  `state.bin`, `curves.csv`, `events.log`) with a continuation known answer (N + restore + M == N + M); a zip
  writer/reader; the OPFS store (decided), Screen Wake Lock, visibility events; Train (headless) / Test / Pause with
  the judge as a curve; the UI; a 30-minute rehearsal. Open: U2-U6.
- **Phase ON - the first night**: `geno_night` from geno_train on the recipe; the start-up probe picks widths and
  batches (>= 5 iterations/s, >= 1,000 samples/s); checkpoints every 10 min with NaN self-healing; curves every
  minute; Simon's rehearsal; the night; the morning protocol.
- **Phase C - curriculum**: adaptive starts (T5), the get-up with the height term's weight checked on both motions,
  perturbation ramps, more clips.
- **Phase P - PPO hygiene** for an A/B page: advantage clip, action-bound loss, normaliser freeze, diagnostics,
  measured choices.
- **Phase A** - ADD (a learned reward from the difference), the 100-clip library, D5 revisited only on a plateau.
- **Phase X** (the phone) and **Phase M** (motion matching) - later.

---

## 7. Decisions

**Made** (reasons in the journal): SuperTrack is the night's learner, PPO the A/B; offsets from the reference;
SuperTrack's failure rule (F3b); zero-velocity servo (F3); 60 Hz physics and a 30 Hz policy (Simon); Simon's
filter inside training (F6a); the normaliser from the clips (F4a); the event limits (worst body, contact) kept as
mechanism, off; the bench before any recipe change (v4).

**Open, and where each is decided:** the offset scale and noise (C1); the losses (C2); the optimiser (C3); the world
model's form (D3); windows and widths (E1, then the probe); drift (E2); the feasible reference (F5.3); PPO's
choices (Phase P); ADD (A1); 60 vs 120 Hz for contact-rich clips (after the first night, if contact quality is what
the morning shows).

---

## 8. Risks, ranked (with the mitigation)

1. **The CPU bench is too slow to show learning in 30 minutes.** Smaller widths and batches; fewer characters;
   profile an iteration first (B1 reports the rate); if still too slow, Stage G's clock and filter earlier, and the
   bench on the kit.
2. **SuperTrack exploits its world model.** Trust and the exploitation index on every bench row; the filter; noise
   in the paper's units; the gate requires exploitation bounded.
3. **The recipe choices interact** (scale x loss x form). One change at a time against B2, then the winners together
   re-checked once before the gate.
4. **The page crashes or stalls unattended.** Phase R's checkpoints and resume, NaN self-healing, the rehearsal.
5. **Drift ends episodes** - the root limits; E2.
6. **The night learns the dance but a later night not the get-up** - Phase C's adaptive starts and the height term.

---

## 9. Where things live

- `src/robot_track.zig` - the task (`Task`, `Gains`, `TrackingError`, `trackingError` / `trackingErrorWithHead`,
  `Termination`, `reward`, `headBody`, `contactExemptMask`, `filterAction`, `referenceVelocity`), the `Fleet`
  (`startAt`, `driveOnce`, replay), the judge (`judge`, `Judging`, `Actor`, `evenStarts`, `judgeOptions`), `local`.
- `src/robot_latent.zig` - the CPU SuperTrack: `LatentWorld`, `Learner` (`decideInto`, `appliedBefore`, `decides`,
  `diagnose`, `modelLoss`, `judgeActor`), `Normalizer`, `measureNormalizer` / `measureClipNormalizer`.
- `src/robot_latent_kit.zig`, `src/robot_track_resident.zig` - the GPU SuperTrack; `examples/geno_train`.
- `src/robot_geno.zig` - Geno: `tracking_task`, `supertrack_recipe` (`SuperTrackRecipe`), `servo_task`,
  `task_termination`, `task_weights`, `ServoRun`,
  `Planner` (the teacher), `FailureCheck`, `GenoTask` / `Motion`, the T/F measurements.
- `src/robot_policy.zig` (DReCon: `Controller`, `observe`), `src/robot_ppo_track.zig` (PPO), `src/robot_gym.zig`.
- `src/robot_track_env.zig` - `TrackEnv` (the task decision by decision, every learner's one definition), `NStep`;
  `src/robot_sac_track.zig` - `SacTrack` (SAC on the dance); `src/robot_gym.zig` - `SacAgent` (discount rows,
  sample-time normalisation). In `src/zimrnum.zig`: `Params`, `Graph.detach` / `simNorm` / `klGaussianDiag` /
  `softCrossEntropy`, `categoricalProject`.
- `src/notes/bench/r3_kl_robust_check.py` - R3.7's numerical check of the KL-robust value (Python, outside zimr).
- Notes: this plan; `rl_track_journal.md`; `supertrack_comparison.md`; `claude.md`; `archive/rl_track_plan_v1-3.md`.
- Tutorial: `src/notes/tutorials/robot-mocap-tutorial.html` (sections 10-12).

## 10. Recent advancements - reproduce, then carry to the dance

(Simon, Sep 28: "a large new section dedicated to recent advancements ... add to the plan everything necessary to be
able to reproduce this".) Each entry: the claim, the method in full, what is missing in zimr in build order with a
known answer per piece, the open questions, and how it carries to our tracking task. The rule for a reproduction:
FIRST the paper's own setting and ablation direction (did each rung help, as theirs did?), only THEN our task. Tags:
[paper] = stated in the paper; [base, verify] = a detail of TD-MPC2 / BMPC that the paper only references - taken from
those works, to be confirmed against BMPC's code (github.com/wertyuilife2/bmpc - reachable from the container) before
it is built.

### R1 EfficientTDMPC - Evers, Meo, Boehmer, Dauwels, Oren (arXiv 2605.16692v4, 17 Sep 2026)
(v5 of 28 Sep re-read Sep 30: the method and Table 2 agree with these notes - acting horizon 6 with the multi-horizon
mean, reanalyze horizon 3 terminal-only at the 64 / 8 / 3 budget, beta 10 only where episodes end early, spread
[0.05, 2], log std [-3, 1], entropy 1e-4, discount [0.95, 0.995], per-step insertion. New in v5: A.4 wall-clock parity
(47 vs 45 min per 100k decision steps - the cheap reanalyze pays for the ensemble); B.4 penalising acting as well does
not help; C.1 ensemble averaging cuts the planner's predicted exploitation of single heads. For N7: the multi-horizon
objective is the mean over h = 1 .. H of Q_h = sum_{u<h} gamma^u r_u + gamma^h V(z_h) - LatentPlanScorer must read
the value heads at EVERY depth, not only the last.)

**R1.0 The claim** [paper]. State of the art in sample efficiency on HumanoidBench (14 `h1hand` tasks - WITH hands -
1M env steps) and the DeepMind Control Suite (21 easy tasks at 200k, 7 hard at 1M): +27% AUC over the previous best
(Mrs. Q), +57% AUC over BMPC on their ladder tasks, at the same wall-clock as BMPC (47 +- 2 vs 45 +- 3 minutes per
100k decision steps, one A100). The idea in one line: the planner exploits errors in its return estimate, so make the
estimate harder to exploit - average it over rollout depths and over an ensemble of dynamics models, and during
reanalyze penalise its uncertainty. Their Appendix C.1 is the mechanism, measured: a planner maximising a single-head
estimate promises far more than the real simulator delivers (often LESS than the policy's own action); maximising the
ensemble average promises less and delivers more - our I1b finding (exploitation) in their terms.

**R1.1 The base: BMPC, exactly as its code does it** (read Sep 28 from `bmpc-main`: `bmpc/bmpc.py`,
`common/world_model.py`, `common/layers.py`, `common/math.py`, `common/scale.py`, `common/buffer.py`,
`trainer/online_trainer.py`, `config.yaml` - these supersede every "base, verify" tag this entry had).
  - **The vocabulary** (`layers.py`): `NormedLinear` = Linear, then dropout if any, then LayerNorm (with its own gain
    and bias), then an activation (Mish by default). `mlp(in, hidden, out, act)` = NormedLinear hidden layers
    (dropout only on the FIRST) and a last layer that is plain Linear - or a NormedLinear with `act` when one is
    given. `SimNorm` = view the features as groups of 8, softmax within each group, view back. `Ensemble` = N copies
    of one module with their parameters STACKED, evaluated with vmap.
  - **The networks** (`world_model.py`; latent 512, mlp 512, enc 256, bins 101 on [-10, 10]): encoder
    `mlp(obs, [256], 512, act=SimNorm)`; dynamics `mlp(z ++ a, [512, 512], 512, act=SimNorm)` (its last layer:
    Linear -> LayerNorm -> SimNorm); reward `mlp(z ++ a, [512, 512], 101)`; policy `mlp(z, [512, 512], 2 * |A|)`;
    values: an Ensemble of 2 `mlp(z, [512, 512], 101, dropout 0.01)` (state values - `use_v_instead_q`). The reward's
    and the values' LAST-layer weights start at ZERO; everything else TD-MPC2's `init.weight_init` (read before N6).
  - **Three views of the value heads**: live (trained), detached (the same tensors, no gradient - what the planner and
    targets read), target (a copy, `lerp`'d toward the detached each update at tau 0.01). `V(z, "avg")` / `"min"`
    read two RANDOMLY chosen heads (with 2 heads: both).
  - **The policy (BMPC mode)** - NOT SAC's squashed Gaussian: `mean, raw = pi(z)`; mean = tanh(mean);
    log_std = low + (high - low) * (tanh(raw) + 1) / 2 with [low, high] = [-3, 1], or the EXPLORATION bounds [-2, 1];
    sample = clamp(mean + eps * std, -1, 1). Its "scaled entropy" is -log_prob of the Gaussian (no squash term)
    rescaled by the action dimension.
  - **Categorical scalars** (`math.py`): `two_hot(x)` = symlog(x) clamped to [-10, 10], split between its floor bin and
    the next by the fractional offset (T3's point-mass projection exactly; the code's `(i + 1) % bins` wraps, harmless
    - that share is 0); `two_hot_inv(logits)` = softmax . bins, then symexp; `soft_ce(pred, x)` =
    -sum two_hot(x) * log_softmax(pred) (T4 exactly).
  - **The planner** (`_plan`), per call: z = encode(obs). Policy trajectories: 24 rollouts of the policy through the
    model (its EXPLORATION std during reanalyze). Mean = 0, std = 2; warm start: mean[:-1] = previous call's mean
    shifted by one (not at an episode's first step, never in reanalyze). Iterations 6, +2 when |A| >= 20 (the paper
    says > 20; the code >= 20). Each iteration: 488 samples = clamp(mean + std * N(0,1), -1, 1) after the 24 policy
    ones; value = sum_t gamma^t two_hot_inv(R(z_t, a_t)) + gamma^H V(z_H, "avg"), NaN -> 0; the 64 best are the
    elites; score = softmax(temperature * (elite value - best)); mean, std = the score-weighted mean and deviation of
    the elites; std clamped to [0.05, 2]. After: ONE elite drawn by Gumbel sampling on the scores. Returns the
    action = that elite's first action (+ std[0] * N(0,1) unless evaluating, clamped) and `action_dist` = (that
    elite's first action, std[0]) - THE POLICY'S TARGET. The mean is kept for the next warm start.
  - **The value target** (`_td_target_V`, no gradient, on the TRUE encodings of the sampled window's first H states):
    roll the POLICY `td_horizon = 1` step through the model - sum gamma^k two_hot_inv(R(z, pi(z))) - then add
    gamma^k V_target(z_end, "avg"). Model rewards, not the buffer's.
  - **The world-model update** (`_update`), on a window (obs_0..H, a_0..H-1, r_0..H-1): true_zs = encode(all obs)
    without gradient; z = encode(obs_0) WITH gradient; roll the buffer's actions: z_t+1 = next(z_t, a_t),
    consistency += MSE(z_t+1, true_zs[t+1]) * rho^t; reward += soft_ce(R(z_t, a_t), r_t) * rho^t; value +=
    soft_ce(V_j(z_t), target_t) * rho^t for EACH head j (z_t: the ROLLED-OUT latents, z_0 included). Then /H, /H,
    /(H * heads); total = 20 * consistency + 0.1 * reward + 0.1 * value; clip the global gradient norm at 20; one Adam
    step (encoder lr x 0.3). Then the policy update, then the target EMA.
  - **The policy update** (`update_pi`, on the rolled-out latents zs[0..H-1], DETACHED): kl = KL(pi_theta || target) -
    the POLICY first (mode-seeking; the paper writes the reverse) - averaged over action dimensions; divided by a
    running scale (`RunningScale`: an EMA at tau of the 95th minus 5th percentile of the batch's first-step KL,
    floored at 1); loss = mean over t of (kl - 1e-4 * scaled entropy) * rho^t; clip 20; its own Adam (eps 1e-5).
  - **Reanalyze** (every 10th update): the first 20 windows of THIS batch, all H of their states, re-planned (no warm
    start, horizon 3, exploration std for the policy trajectories); the fresh targets replace those in the batch AND
    are written back into the buffer (`index[1:]` - the row layout below).
  - **The buffer** (`buffer.py`, torchrl SliceSampler): windows of H + 1 consecutive steps from ONE episode; row t holds
    obs_t with the action that LED to it, its reward and the planner target from the step before (a leading row per
    episode has NaNs) - so a batch reads `action[1:]`, `reward[1:]`, `target[1:]`. Rows without a planner target
    (random warm-up) train toward N(0, 1). Episodes are added when they END.
    (Torch BMPC adds episodes when they END; ours inserts every step, as BMPC-jax and EfficientTDMPC do - "data
    freshness".)
  - **The schedule** (`online_trainer.py`): random actions for `seed_steps`; at that step, `seed_steps` updates in one
    burst (pretrain: no policy update, no reanalyze); then one update per env step. Discount:
    frac = episode_length / 5, gamma = clamp((frac - 1) / frac, 0.95, 0.995).
  - **Paper vs code** (the code is what produced the numbers): the KL's direction; ">= 20" action dimensions; the
    policy target is a DRAWN elite's first action with the final std, not the planner's mean; reanalyze's policy
    trajectories use the exploration std; the policy trains on rolled-out latents; the value target uses model rewards
    along a policy rollout; the running scale on the KL; the loss weights 20 / 0.1 / 0.1.
  - **Cost on our CPU**: planning at BMPC's size is roughly 6 iterations x 512 samples x 3 steps of 512-wide MLPs -
    on the order of 10 GFLOP per decision, about a second on one core. So: CPU at reduced widths (128) and samples
    first, for the known answers; full size on the kit (N9).

**R1.1c BMPC-jax - what a second implementation teaches** (read Sep 28 from `bmpc-jax-main`: `bmpc_jax/train.py`,
`bmpc.py`, `world_model.py`, `data/sequential_buffer.py`, `config.yaml`; "a performant Jax implementation", with the
BMPC author's help). Where it is FASTER:
  - **One planner call for every environment.** `num_envs` environments step together (4 by default) and `act`
    plans for all of them as one batch; the planner takes any leading batch shape, so the SAME compiled planner
    serves acting (envs) and reanalyze (H x b states). Bigger matrix products, one call's overhead.
  - **Reanalyze and the policy reuse the update's own work.** `update_world_model` returns the true encodings and the
    rolled-out latents it computed; reanalyze plans from those encodings (no re-encoding), the policy trains on those
    latents (no second rollout), and the policy update runs AFTER reanalyze, on the fresh targets.
  - **One encoder pass.** Observations and next observations are stacked and encoded in a single call; the targets
    are cut from it through a stop-gradient. (BMPC-torch encodes the window without gradient AND its first state again
    with gradient.)
  - **All the planner's noise drawn once** per call - (samples, iterations, horizon, action) - not per iteration.
  - **A ring per environment, transition rows, masks.** The buffer is [capacity, envs]; a row is a whole transition
    (obs, action, reward, next obs, terminated, truncated, the planner's mean and std); insertion is one masked write
    per step (per-step insertion - EfficientTDMPC's "data freshness" is already this); a window is (env, start),
    O(1), and may cross an episode's end - `finished` masks (done seen earlier in the window) remove the later steps
    from every loss. No episode index, no "the action that led here" offset.
  - **The update-to-data ratio as a knob**: `num_envs x utd_ratio` updates per loop step; at the warm-up's end, one
    burst of `seed_steps` updates (seed_steps = max(5T, 1000) x envs x utd).
Where it BEHAVES differently (each a choice to test, not a fact):
  - **Terminations.** An optional CONTINUE head (sigmoid; binary cross-entropy against 1 - terminated, weight 1)
    multiplies the running discount: a HARD 0/1 (> 0.5) inside the planner's value, the SOFT probability inside value
    targets. BMPC-torch has no notion of termination (DMC has none); HumanoidBench and TrackEnv (falls) do.
  - **The policy's target is the planner's MEAN and std** (std x 1.5, floored at 0.1), not a drawn elite's action.
  - **rho weights normalised to sum to 1** (rho^t / sum rho^t) where BMPC-torch divides by H.
  - **5 value heads** (BMPC-torch and EfficientTDMPC: 2); evaluation acts on the BEST elite, not a sampled one.

**R1.2 The four changes** [paper - the rungs of their Figure 4a, each measured]:
  1. **Practical.** (a) Per-step replay insertion (every transition as it happens); (b) acting horizon 3 -> 6;
     (c) reanalyze at 1/8 the budget - 64 samples, 8 elites, 3 policy trajectories (reanalyze dominates wall-clock;
     Figure 6: HumanoidBench AUC slightly UP, DMC slightly down). Rung result: mildly better than BMPC.
  2. **Aggregate multi-horizon objective** (eq. 1): the acting planner maximises
     Q^_agg(z, a_1..H) = (1/H) sum_{h=1..H} Q^_h(z, a_1..h), each Q^_h rolling out the first h actions and bootstrapping
     with the value at depth h. Lower variance than the final-depth objective when the Q^_h are not fully correlated or
     variance grows with depth (as in MCTS - MuZero, TSMCTS). ACTING only: reanalyze keeps horizon 3, final depth.
  3. **Ensembles for state-action value estimation** (eqs. 2-4), Nf = 4 dynamics heads f_i:
     TRAINING - every head rolls out the sampled actions from the same z_t, and the reward and value heads train on
     EVERY head's rolled-out latents (the value-equivalent family has never done this - the paper's claimed novelty);
     ESTIMATION (planning AND value-target creation) - Q^(i, j): roll out dynamics head i, bootstrap with value head j
     (eq. 2); the estimate is the mean over all Nf x Nv pairs (eq. 3); PETS-style TS-infinity trajectory sampling (a
     particle keeps ONE dynamics head for its whole rollout); the uncertainty is the variance of that mean,
     Var_{i,j}[Q^(i, j)] / (Nf Nv) (eq. 4 - an underestimate, heads being shared across pairs; used only as a penalty).
     Scaling: 2 -> 4 -> 8 heads better each time (Figure 4b); 4 chosen for wall-clock.
  4. **Pessimistic reanalyze** (eq. 5): the reanalyze planner maximises J = Q^ - beta * sigma^ (sigma^: eq. 4's square
     root), so the policy is distilled toward actions whose value the ensemble AGREES on - actions the models have
     been trained around. beta = 10 on tasks with early termination, 0 elsewhere (Figure 5a: +70% AUC on h1hand-walk,
     -50% on humanoid-walk; 5b: beta 10 best of {0, 1, 3, 10, 30}). Acting stays unpenalised (App. B.4: penalising it
     too does not help).
  The ladder (Figure 4a, 5 tasks, 5-8 seeds): BMPC 1.0 -> +practical ~1.15 -> +multi-horizon ~1.3 -> +ensemble ~1.57.

**R1.3 Reproducing their numbers - the protocol** [paper, App. A]: HumanoidBench h1hand x 14 at 1M steps; DMC 21 easy
at 200k + 7 hard at 1M; 4 seeds a task (8 for the pessimism study); evaluation return against env steps; normalise
each task by BMPC's mean return at the same budget; AUC on a shared step grid, a missing step 0 anchored at BMPC's
untrained score; HumanoidBench and easy/hard DMC averaged separately, the headline the mean of HumanoidBench and
suite-equal DMC. Baseline curves from the authors' repositories (App. A.3). We have neither MuJoCo's DMC nor
HumanoidBench, so an exact reproduction is out of reach inside zimr; what IS in reach: the ablation DIRECTION -
BMPC, then each rung - on tasks we simulate (the gym cartpole and humanoid of `robot_gym`, then TrackEnv), and the
Appendix C.1 exploitation measurement (planner's promise vs the real simulator), which our bench already has the
machinery for (`exploitation` column).

**R1.4 What we have** (tested): the graph autograd with matmul, relu, mish, layerNormRows, softmaxRows, concat,
slice, min, mseLoss, softCrossEntropy (T4); Adam; polyakUpdate (EMA targets); clipGradNorm; ReplayBuffer;
ObsNormalizer; categoricalProject (T3 - a two-hot encoding is its discount-0 case); n-step transitions (T1); TrackEnv
with termination vs truncation; an MPPI over the robot world model (`robot_world`) and a simpler sampling planner in
zimrnum; the twin world models of I1b - a two-head dynamics ensemble whose disagreement already prices the policy (a
cousin of changes 3 and 4); the GPU kit for scale; and, added Sep 28 by N1-N2: `Params` (trained / frozen / target
bindings), `Graph.detach`, `Graph.simNorm`, and `Graph.klGaussianDiag` with a log-std per row (the distillation loss).
NOT here yet: a MuZero-style latent model (SuperTrack's world model is supervised on real states, not
value-equivalent), symlog / two-hot (`CategoricalScalar`), the layer builders, reanalyze, MPPI with elites + policy
samples + warm start.

**R1.5 Native to zimrnum - the design** (Simon, Sep 28: "find the true best way, simplest way ... our library needs
to feel like it was built for this"). The whole TD-MPC class - BMPC, EfficientTDMPC, TD-MPC2, and TD4's critics with
them - reduces to five ideas, and zimrnum already has the hard parts of each:
  1. **A network is its parameters plus ONE builder, bound into any graph.** A `Params` set (tensors in one arena)
     binds into a graph as parameters (trained) or as constants (FROZEN - the same tensors, read live: `constant()`
     wraps the caller's tensor, no copy, so an Adam step on the live weights is seen at once, with nothing to
     re-sync). The TARGET is a second `Params` of the same shape, `polyakUpdate`d in place and bound as constants.
     BMPC's live / detached / target trio is then three bindings of two tensor sets - no module wrappers, no copies.
  2. **Planning is `recompute` of a graph built by the same builder.** The rollout builder - encode, then H steps of
     dynamics and reward, then the value at the end (or at every depth, EfficientTDMPC) - builds the TRAINING graph
     (B window rows, parameters trained) and the PLANNING graph (N sample rows, frozen). An MPPI iteration writes the
     sampled actions into the planning graph's action constants, recomputes, and reads the value column. The planning
     graph's rows are (states x samples): all of TrackEnv's characters plan in ONE recompute (BMPC-jax's batched
     acting), and reanalyze's H x b states use the same graph shape at another size. One
     definition of the model's arithmetic, used for learning and for search - nothing to drift apart (L12's graph-vs-
     rows parity risk does not arise: there is no second implementation).
  3. **An ensemble is an array of members, not a new tensor rank.** E members of one builder, bound and applied in a
     loop; losses and estimates sum or average over them. On the CPU that is the same arithmetic as a batched matmul
     and needs no rank-3 machinery; the kit batches the members on the GPU (N9). E = 1 is the single network, bit
     for bit - value heads (2), dynamics heads (EfficientTDMPC: 4), TD4's twin critics, SAC's twin Qs: one mechanism.
  4. **A small builder vocabulary** over the ops the graph has (add broadcasts a bias row, so a layer is
     `add(matmul(x, W), b)`): `linear`, `normedLinear` (linear, layerNormRows with a gain and bias through `mul` /
     `add`, Mish; dropout where asked), `mlp`; plus four NEW graph ops - `detach(x)` (forward a copy, backward nothing:
     encode (obs, next obs) ONCE and cut the consistency and value targets from it, BMPC-jax's single encoder pass),
     `simNorm(x, group)` (softmax within groups),
     `gaussianKL(mean_p, std_p, mean_q, std_q)` (closed form, rows), and the `CategoricalScalar` helper (symlog
     two-hot targets through `categoricalProject`, the loss through `softCrossEntropy`, decode = softmax . bins then
     symexp).
  5. **Three plain pieces around the graphs**: `SequenceReplay` (BMPC-jax's form, the simpler one: a ring per
     environment of whole transition rows, one masked write per step, windows drawn as (env, start) in O(1) and allowed
     to cross an episode's end, `finished` masks for the losses, per-row target columns reanalyze overwrites), `Mppi`
     (options, warm-start state per environment, all noise drawn once per call, `plan(scorer)` returning the action,
     the target distribution and the mean), and `RunningScale`.
  6. **Nothing computed twice.** The training graph's true encodings feed reanalyze's planner and its rolled-out
     latents feed the policy update, read after the recompute - no second encoding, no second rollout (BMPC-jax).
  Where things live: the vocabulary, the new ops, `Params`, `CategoricalScalar`, `SliceReplay`, `Mppi` and
  `RunningScale` in zimrnum (general machinery, with zimrnum's known-answer tests); the agent - BMPC with
  EfficientTDMPC's changes as options - in `src/robot_tdmpc.zig`, driven by TrackEnv and by the gym tasks.

**R1.5b The build order, each piece with its known answer:**
  - **N1 `Params` and bindings** - DONE Sep 28: `zimrnum.Params(T)` - `init`, `clone`, `bind(graph, .trained |
    .frozen)`, `follow` (polyak per tensor); a learning-rate scale per set is one `Optimizer` per set (nothing new).
    Three known answers pass; a frozen binding that COPIES its tensors fails the live-read one. As planned: Trainable,
    frozen, target; Adam over a `Params` with a learning-rate scale per set
    (the encoder's x 0.3). KNOWN ANSWERS: a frozen binding sees an Adam step without being rebuilt; no gradient ever
    reaches a frozen binding; the target after `polyakUpdate` at tau = 1 equals the live set.
  - **N2 The vocabulary and the new ops.** DONE Sep 28-29 (the layers' second half, Sep 29 - see 6.0): `detach` (a
    stop-gradient - the
    input's value, no gradient
    through it: zero on its own path, the other path's gradient bit for bit); `simNorm` (every group a probability
    vector; one group = `softmaxRows`; in place = out of place; `checkGradient`); the Gaussian KL - the EXISTING
    `Graph.klGaussianDiag`, generalised to a log-std per ROW (BMPC's state-dependent spreads; it was already policy-
    first and composed from tested ops); `symlog` / `symexp` and `CategoricalScalar` (two-hot through the same split as
    `categoricalProject`, now shared as `addPointMassToGrid`; symexp(symlog(x)) = x; decode(encode(x)) = x on and
    between bins, both axes; clamping; equal to the projection of a point mass); the layers on `Dense`'s template -
    `Dense.attachAs`, `LayerNorm`, `NormedDense`, `Mlp` (`checkGradient` through a 3-layer mlp ending in SimNorm).
  - **N3 The rollout builder and the world-model loss** - DONE Sep 29 as `LatentRollout` + `WorldModelLoss` (see
    6.0). The "planted linear system" training answer moves to the assembly (N6), where an optimiser runs. KNOWN
    ANSWERS held: the graph against step-by-step and hand computations, `checkGradient` where finite differences are
    valid, the no-leak comparison for the encoder, refilled targets.
  - **N4 Planning by recompute, and `Mppi`.** KNOWN ANSWERS: the planning graph's value for one sample equals the
    training builder's rollout value for the same latent and actions, bit for bit; on a planted scorer with a known
    optimum MPPI converges to it; with policy trajectories only (no samples) it returns the policy's action; the warm
    start shifts the mean by one step exactly.
  - **N5 `SequenceReplay`.** KNOWN ANSWERS: a window is consecutive rows of ONE environment's ring (across the wrap
    too); `finished` is false up to and including the first done and true after it; a write-back lands exactly on the
    rows named; empty targets read as N(0, 1); per-step insertion of a masked-out environment writes nothing.
  - **N6 BMPC assembled** (acting, the update, the policy's distillation with `RunningScale`, the value target,
    reanalyze, the warm-up burst, the discount rule; `finished` masks in every loss; batched acting over every
    environment; reanalyze and the policy fed by the update's own encodings and rollouts) - on the gym cartpole within
    5 minutes at reduced widths, then TrackEnv. Options from BMPC-jax, each a bench question: the CONTINUE head (hard
    in planning, soft in targets - TrackEnv needs it: falls end episodes), the policy target (drawn elite, as torch;
    or the planner's mean and std x 1.5 floored at 0.1, as jax), rho normalised or divided by H, 2 or 5 value heads.
    KNOWN ANSWERS: every piece's parity above; the untrained agent on TrackEnv is the servo; one update
    at a fixed seed fingerprinted and kept as the regression answer.
    THE TWO REPLAYS (Sep 30; Simon: generic ingredients in zimrnum, specialised code may start as an independent
    fork in the robot files, no frameworks or towers of abstraction - simple functions on arrays): `zimrnum.
    SequenceReplay` (rows of floats; windows may cross an episode's end, `finished` masks the rest) is the generic
    one; `robot_track.Replay` (typed columns - pose, velocity, action, frame, clip and segment ids; windows only
    INSIDE one segment, which changes at every reset and every shove) stays SuperTrack's own. No second window rule
    goes into zimrnum for it. If BMPC on TrackEnv wants sequence windows, start from a copy beside robot_track and
    share only small functions on arrays where one fits naturally.
    The trade-off to keep in view: segments average ~21 frames, so 32-frame windows inside one were 0 / 200 (T5);
    masked windows would still exist. The two tutorials already explain the two rules once each and link both ways.
    N6 BREAKDOWN (Sep 30, after the inventory). HAVE: Params + the layers (SimNorm, LayerNorm, Mish via Activation),
    LatentRollout, WorldModelLoss (consistency / reward / value, rho^t, averaged over steps and heads),
    LatentPlanScorer + Mppi, SequenceReplay (+ writeBack for reanalyze), CategoricalScalar (two-hot, decode),
    klGaussianDiag, diagGaussianLogProb, clipGradNorm, polyakUpdate, AdamSet (robot_gym), symlog / symexp, the
    continuous cartpole (zimrnum). MISSING: `finished` masks in WorldModelLoss (rho^t is per step; finished is per
    ROW - a generic extension, zimrnum); RunningScale (zimrnum, small); the BMPC policy head's pieces (tanh mean,
    log_std mapped into [low, high], KL to the target, the scaled entropy - composed of existing graph ops). The
    agent itself is an ASSEMBLY, not an ingredient: its own file (proposed `src/robot_bmpc.zig`, beside robot_gym,
    whose SacAgent is ~500 lines of a 2953-line file). Turns, each with its known answers:
      B1 finished masks in WorldModelLoss + RunningScale. KA: a mask of all zeros = today's loss bit for bit; a
         masked row contributes nothing (value and gradient); RunningScale = the EMA of q95 - q5 by hand, floored at 1.
         PRECISELY (re-read Sep 30, torch and jax side by side): RunningScale is TORCH's - value starts at 1, each update
         value += tau * (max(1, q95 - q5) - value), the floor on each BATCH's range before the average, percentiles by
         linear interpolation of the sorted batch, the batch being the FIRST step's KL (jax instead stores max(1,
         EMA(range)) - the two agree only while ranges stay above 1). The masks' normalisation, as jax does it (torch's
         windows never cross an episode, so torch has none to copy): consistency at step t = the mean over the
         UNFINISHED rows only; reward and value = the sum over steps of the masked rho-weighted terms, then the mean over
         the WHOLE batch (finished rows as zeros); a continue loss, when there is one, masked too (jax forgets to).
         RUNNINGSCALE DONE Oct 1: `zimrnum.RunningScale(T)` (value 1, tau; `update(batch, scratch)` - quantileSorted's
         interpolation, which is torch's), after `quantile`. KA: the hand EMA (90 -> 9.9, then a 0.5 spread floored ->
         9.01); torch's order pinned against jax's (from 5, a 0.2 spread -> 4.6, not 4.52); 11 shuffled values -> 9; the
         batch untouched; empty / mismatched / NaN refused. Negative control: jax's order fails exactly the two
         numeric tests (8.955, 4.52). Tutorial 18d.12. NEXT: the masks.
         MASKS DONE Oct 1 - B1 COMPLETE. The rollout OWNS them: `LatentRollout.unfinished` (a [batch, 1] column per
         step) and `unfinished_mean_factors` (batch / still counting; 0 when none), all 1 until
         `setFinished(finished)` - SequenceReplay's finished_out as it comes, every entry checked to be 0 or 1 before
         any is written. Consistency at t = mseLoss(z * M, y * M) * factor - the mean over the windows still counting;
         WorldModelLoss multiplies its reward and value TARGETS by the same columns (an all-zero target row costs
         exactly nothing: softCrossEntropyRowsGrad weighs the prediction by the row's target mass - now a unit test),
         the mean staying over the whole batch. One call marks all three terms. New Graph op: copyToEveryColumn
         (copyToEveryRow's twin, an exact matmul by a row of ones). KA: NOTHING FINISHED = the loss as it always was,
         BIT FOR BIT, the total and every gradient of all five networks, against the old formula built by hand on a
         second graph; a finished window counts for nothing - its action, next observation, reward and value targets
         changed, no bit of the loss or any gradient moves (and counted again, the losses part); the masked mean by
         hand; a step with every window finished contributes 0, not NaN; refusals change nothing. Four negative
         controls, each failing exactly its predicted tests. FOR B4: the policy's loss also reads rolled latents -
         check whether jax masks it by finished, and mask it alike if so.
      B2 the policy head: tanh mean, log_std in [low, high], the KL(pi || target) and the scaled entropy on the graph.
         KA: checkGradient; KL zero at pi = target; log_std's ends; parity with klGaussianDiag / diagGaussianLogProb.
         SPLIT Oct 1 into B2a (the head, done) and B2b (the per-step loss). RE-READ OF TORCH'S SOURCE
         (/tmp/bmpc/bmpc-main: world_model.py pi, math.py, bmpc.py update_pi) CORRECTS ONE NOTE: in BMPC mode the
         policy is NOT a squashed draw - mean = tanh(m), action = clamp(mean + s * eps, -1, 1), no Jacobian term; so
         the policy IS N(tanh m, s^2), the Gaussian the KL compares (`squashedReparameterize` is TD-MPC2's, not
         BMPC's). log std = low + dif * (tanh(x) + 1) / 2: [-3, 1], and [-2, 1] ("expl") for the planner's policy
         trajectories during reanalyze only. update_pi(zs.detach()) on zs[:-1]; kl = KL(N(mean, s) || expert) averaged
         over dims; scale.update(kl[0]) BEFORE dividing; loss = mean over t of rho^t * mean over batch of (kl / scale -
         1e-4 * scaled_entropy); clip 20 on the policy's parameters only; its own optimiser. scaled_entropy =
         -size * log N(eps) (up to a 1e-8 guard): its gradient is size per log std, its mean size * entropy.
         B2a DONE Oct 1: `Graph.tanhIntoRange` (beside tanh), `Graph.diagGaussianEntropy` (DiagGaussian.entropy's twin,
         [rows, 1]), `TanhMeanGaussian(T)` (build(graph, output, .{ log_std_low, log_std_high }) -> mean, log_std; the
         doc records the clamp-not-squash and why dims * entropy has exactly torch's scaled-entropy gradient). KA: the
         range's midpoint and exact ends for [-3, 1] and [-2, 1], refusals, the slope by hand; the entropy = DiagGaussian
         .entropy row by row, a gradient of exactly 1 per log std; the head's centres and spreads (saturated ends
         exact), zero KL against itself, one distillation step under checkGradient; odd widths refused. Controls: full
         width fails the range and head tests; the entropy without its + 1/2 fails parity only. Tutorial 18d.13.
         B2b NEXT: the per-step policy loss (rho^t / H, the KL averaged over dims, a [1, 1] scale constant refilled
         after RunningScale.update, the entropy term, the first step's KL rows exposed) + the masks question (jax).
         FOR B3: acting = clamp(tanh(m) + s * eps, -1, 1), a plain function, not squashedReparameterize.
         B2b DONE Oct 1 - B2 COMPLETE. BMPC-jax read first (/tmp/bmpcjax): it DOES mask the policy loss -
         sum over t of lam * kl / scale where ~finished, then the mean over the whole batch (KL summed over dims, no
         entropy, lam normalised). Ours = torch's formula with jax's masks: `PolicyDistillationLoss(T)` - latents ONE
         Var [H * batch, latent], step-major, data (a separate graph's constant or detached rollout rows); the policy in
         one pass; targets zero-filled = N(0, 1) (means, and LOG stds); KL averaged over dims; entropy * c * dims; ONE
         weight column rho^t / (H * batch) * unfinished, built in-graph from the rollout's columns (one setFinished
         marks every loss); each term a dot product; `updateScale(graph, *RunningScale, scratch)` reads step 0's rows,
         sets inverse_scale. KA: the hand computation (formulas written out) nothing finished and one finished; a
         finished row's latent and targets changed -> no bit moves (counted again, the totals part); updateScale = a
         hand RunningScale on step 0's rows only, the scale really moved, and the gradient WITHOUT the second
         recompute equals the one with it, bit for bit (so a shared graph may skip it); checkGradient through the
         policy net, every parameter connected; refusals. Controls: masks ignored -> hand + finished-row tests; last
         step's rows -> updateScale only; entropy without dims -> hand + updateScale. Tutorial 18d.14.
         FOR B4: copy the rollout's rolled[0 .. H-1] values into the policy graph's latent constant (step-major)
         AFTER the world-model forward and BEFORE its Adam step (torch: zs from the same forward, detached); the
         targets from the replay rows (mean, log of std); clip 20 on the policy's parameters alone; its own Adam
         (eps 1e-5).
      B3 the agent's skeleton and ACTING: the six networks (+ target values, zero last layers for reward and values),
         policy trajectories into Mppi, the drawn elite + std noise, replay rows (obs, action, reward, done, target
         mean / std). KA: actions in [-1, 1], one acting step fingerprinted, the replay row layout by hand.
         THE ROW LAYOUT, CORRECTED (Sep 30, from BMPC-jax's buffer): a row must carry its own NEXT OBSERVATION -
         obs ++ action ++ reward ++ next_obs ++ terminated ++ truncated ++ target mean ++ target std, windows of H rows.
         With observations only and windows of H + 1 rows, the step that ENDS an episode takes the next row's
         observation as its successor - the NEXT episode's first state after the reset - so the consistency loss
         would teach the dynamics a jump that never happens (finished is 0 at that step, by design: its reward and
         observation are real). The vector env returns the true final observation; the junk transition after it is the
         masked insertion. The target sits in the SAME row as the observation it was planned from (jax; torch shifts
         it to the next row, `[1:]`), so reanalyze writes back steps 0 .. H - 1: first_step 0. The tutorial's replay
         example (18d.9: windows of horizon + 1, writeBack(..., 1, ...)) changes with this, in B3.
      B4 the UPDATE: windows from SequenceReplay, two-hot targets, the value target (one policy step through the
         model + gamma V_target), WorldModelLoss with masks, clip 20, Adam (encoder lr x 0.3), the policy update with
         RunningScale, the target EMA. KA: one update at a fixed seed fingerprinted (the regression answer); the value
         target by hand on a planted model.
         THE BASE IS TORCH'S (EfficientTDMPC is built on it, Table 2): the policy loss = mean over t of rho^t / H *
         mean over batch and action dimensions of (KL(pi || target) / scale - 1e-4 * scaled entropy), log std in
         [-3, 1]; the value target's action SAMPLED from the policy, its bootstrap the mean of the target heads. jax
         differs on each (KL summed over dimensions, no entropy, rho normalised, log std [-5, 1], five value heads,
         consistency weight 10, a fixed discount 0.99, reanalyze also during the warm-up burst) - bench options.
      B5 REANALYZE + the SCHEDULE (warm-up burst, discount rule) + the CARTPOLE GATE (reduced widths, inside 5 min).
         KA: written-back targets = the re-plan's; gamma's clamp by hand; the gate's balance threshold.
      B6 a review turn; the tutorial (16.x BMPC assembled; robot-mocap when TrackEnv arrives).
      THE NEXT THREE TURNS, MADE PRECISE (Oct 3 review, from BMPC's torch source - bmpc.py act/_plan/_estimate_value/
      _td_target_V/_update, config.yaml - not memory). WHAT THE REVIEW FOUND MISSING ABOVE: (a) the planning SCORER
      was unnamed; (b) acting's details; (c) the value target starts from the TRUE latents, through the TARGET heads,
      and BMPC has NO terminal handling - so the gate uses fixed-length episodes (truncation only) until a continue
      head exists; (d) the update's exact order and normalisations; (e) `Mlp.apply` needs a Graph - acting builds one
      inference graph per act, all samples batched as rows, so gate widths stay small; (f) the row layout's columns.
      BMPC's defaults (config.yaml): horizon 3, iterations 6, samples 512, elites 64, policy trajectories 24, std
      [0.05, 2], temperature 0.5, log std [-3, 1] (exploration [-2, 1] in reanalyze only), entropy 1e-4, 101 bins on
      [-10, 10], latent 512, mlp 512, enc 256, num_q 2, value dropout 0.01, simnorm 8, td_horizon 1, batch 256,
      consistency 20 / reward 0.1 / value 0.1, rho 0.5, lr 3e-4 (encoder x 0.3), clip 20, tau 0.01, discount rule
      denom 5 clamped [0.95, 0.995], reanalyze every 10 updates (20 rows, horizon 3).
      TURN 1 - B3a ACTING (new src/robot_bmpc.zig; its tests reached from src/robot_tests.zig, or test-fast never
        sees them). `Config` (BMPC's defaults; gate widths are the gate's, later). `Networks(T)`: encoder (obs ->
        latent, SimNorm), dynamics (latent ++ action -> latent, SimNorm), reward (latent ++ action -> bins), policy
        (latent -> 2 x action through TanhMeanGaussian), num_q value heads (latent -> bins) and their target copies;
        reward and value heads' LAST LAYERS ZERO. `discountedReturn(rewards[H][rows], terminal_values[rows], gamma,
        scores)` - plain arithmetic on arrays, _estimate_value's sum (reward at (z_t, a_t) BEFORE z moves; + gamma^H
        V avg). `rollLatents` (one inference graph: encode once, H steps of two_hot_inv(reward) then next, the
        heads' average V at the end). `policyTrajectories` (num_pi_trajs rows: a = clamp(tanh m + s eps, -1, 1),
        z <- next). `act(obs, first, mode, rng) -> Acted { action, target_mean, target_std, value }`: Mppi with the
        policy rows in its reserved first rows, `iterations` rounds of sample -> score (NaN -> 0) -> refit, `choose`
        (a score-weighted elite draw, + std[0] eps unless evaluating, clamp), the warm start kept between calls.
        KNOWN ANSWERS: a fresh agent scores every trajectory EXACTLY 0 (zero last layers, symmetric support); one
        trajectory's score by hand (discountedReturn on chosen numbers); a planted reward -(a - 0.3)^2 with V = 0
        drives the chosen first action within 0.05 of 0.3; the policy rows bitwise untouched by sample / refit;
        200 random states -> every action in [-1, 1]; evaluation adds no noise; the warm start is the shifted mean
        (by hand); the replay target = (the chosen elite's first action, std[0]) from Mppi's own outputs; same seed
        -> same action bits. CONTROLS: the terminal value dropped -> the hand score fails (a planted V != 0); policy
        rows overwritten -> the untouched test fails. Tutorial: zimrnum 18d.15, acting in the latent space (the
        score, the policy's place in the search, the elite draw, what the replay keeps). Verify: the file's tests,
        then `check`; nothing over 5 minutes.
      TURN 1 CORRECTED AND SPLIT (Oct 3, while building it): the scorer was NOT missing - `zimrnum.LatentPlanScorer`
        (built Sep 30 with Mppi) is exactly _estimate_value, frozen-bound, states x candidates rows, with known answers;
        `discountedReturn` / `rollLatents` would have duplicated it. What was missing: the POLICY'S PLANS for Mppi's
        reserved rows. TURN 1a DONE: `zimrnum.LatentPolicyPlans(T)` beside the scorer (encode once, copy to each plan's
        rows by a 0/1 product, then per step the policy's TanhMeanGaussian draw clamp(mean + e^(log s) eps, -1, 1) on
        the CPU - each action feeds the next dynamics - 2H recomputes; noise by (state, plan, step, dimension) on the
        counter-based Rng; fills ONLY each state's first `plans` rows; widths read from the networks' specs, refused
        when they disagree). Known answers: every plan bit for bit against a row-by-row reroll on separate single-row
        graphs; only the policy rows written, in [-1, 1]; same seed same plans, other seed others; refusals. Controls
        (on the real source, restored): no dynamics step -> the bit-for-bit test only; every row written -> the rows
        test only. zimrnum 329/329; reference row; tutorial 18d.15 (the plans, and how plans + scorer + Mppi meet at
        one decision - next turn's `act`). TURN 1b NEXT: src/robot_bmpc.zig - `Config`, `Networks(T)` (zero_last on
        reward / values, first_dropout 0.01 on values, sim_norm 8 on encoder / dynamics), `act` assembling scorer +
        plans + Mppi with the known answers listed under TURN 1. Turns 2 and 3 follow unchanged.
      TURN 1b DONE (Oct 3) - TURN 1 COMPLETE: src/robot_bmpc.zig, `Bmpc(T)` = Config (config.yaml's numbers; the
        discount stated by the task until turn 3's rule), Networks (encoder 1 hidden layer + SimNorm; dynamics, reward,
        policy, num_q value heads 2 hidden layers; reward / values `zero_last`, values `first_dropout`; target values
        = `withParams(params().clone())`), Decision, Actor (Mppi + LatentPlanScorer + LatentPolicyPlans on two
        graphs, frozen). `act` = observations in; plans.fill into the scorer's rows; `Mppi.plan` NOISE-FREE (the
        target: drawn elite's first action + first spread); then `Mppi.explore` (new in zimrnum, extracted from
        `choose` - one definition of the jitter) or the target itself when evaluating. What Mppi's own tests already
        prove (convergence on a planted objective, policy rows, refit, warm start, bounds) is not repeated. Known
        answers: a fresh agent's imagination flat (|score| < 1e-12); the exploration by hand (zm.clamp, an independent
        clamp); evaluating = the same target, acted on as is; the policy's plans in the search bit for bit; the same
        seed the same decision; 40 decisions in [-1, 1]. Controls (on the real source, restored): no jitter -> the
        target/exploration test only; no plans -> the plans test only. robot_tests.zig registers the file (the main
        robot step 612 -> 616). zimrnum 329/329, test-fast 616, check 358/358.
      TURN 2 - B3b + B4a THE REPLAY ROW AND THE WORLD-MODEL UPDATE. Row = obs ++ action ++ reward ++ next_obs ++ done
        ++ terminated ++ target_mean ++ target_std (done = terminated or truncated - the column SequenceReplay masks
        windows with; terminated kept for a future continue head); windows of H rows; reanalyze will write back
        first_step 0. `Agent.observe(transition, acted)` pushes it. Tutorial 18d.9's replay example follows (windows
        of H rows, writeBack(..., 0, ...)). `valueTargets(true_latents, ...)`: td_horizon policy steps through the
        model from the TRUE latents (encode(obs) of each row, no gradient), + gamma^h x the TARGET heads' average V.
        `updateWorldModel(windows)`: next-latent targets = encode(next_obs) (no gradient); LatentRollout from row 0's
        obs + WorldModelLoss (masks by setFinished; consistency / H, reward / H, value / (H num_q); coefficients 20 /
        0.1 / 0.1); backward; ONE global norm clip at 20 over every model parameter; Adam with the encoder's lr x
        0.3; the target heads follow (tau 0.01). KNOWN ANSWERS: the row by hand; finished = rows AFTER a done in the
        window (the done row itself counts); the value target by hand on a planted model (td_horizon 1: r + gamma
        V_target); the clip: a gradient of norm 40 comes out at exactly 20, one of norm 10 untouched; Adam's first
        step on the encoder is exactly 0.3 x the unscaled one; the follow by hand; one whole world-model update at a
        fixed seed fingerprinted (the regression answer). CONTROLS: online heads instead of target -> the planted
        target fails; no clip -> the clip test fails. Verify: the tests, `check`.
      TURN 2a DONE (Oct 3) - THE REPLAY ROW: robot_bmpc.zig `Row` (observation | action | reward | next observation |
        done | terminated | target mean | target spread; every offset a named fn - `doneColumn` is SequenceReplay's,
        `targetMeanStart` reanalyze's writeBack column), `Step` (the acted action, the TRUE successor, terminated /
        truncated), `Target` (null -> the empty target N(0, 1), BMPC's warm-up rows). done = terminated or truncated.
        Known answers: a row by hand (all 15 values and the offsets); the empty target; through the real
        SequenceReplay a truncated step counts and the steps after it are finished ([0, 0, 1, 1]), the window's rows
        the pushed ones bit for bit; refusals. Control: done ignoring truncation -> exactly the hand row and the
        replay test fail. SequenceReplay's doc example and tutorial 18d.9 follow (windows of H rows, writeBack from
        step 0, why a row keeps its successor). test-fast 620 (+4); zimrnum 329/329; check 360/360 (the autofix
        chain dogfooded). Written lint-clean the first time (autofix had nothing to do; 0 by-hand findings).
        FOR TURN 2b (the world-model update): LatentRollout takes H + 1 observation blocks (z_0 = block 0, step t's
        consistency target = block t + 1), so feed it [row_0.observation, row_0.next_observation, ...,
        row_(H-1).next_observation] - every step's target its OWN successor, the true final state at an episode's
        end - no change to LatentRollout needed. Then valueTargets, WorldModelLoss with masks, the clip, Adam with the
        encoder at 0.3, the target follow - the known answers listed under TURN 2.
      TURN 2b1 DONE (Oct 3) - THE VALUE TARGETS: `zimrnum.LatentValueTargets(T)` beside the scorer and the plans (the
        generic TD-MPC ingredient): from each stored step's TRUE latent, `lookahead` policy steps through the model
        (draw -> reward read from its bins, discounted -> dynamics), then gamma^h x the TARGET heads' value averaged
        over the heads; built once over frozen handles, rows = windows x steps, 2h + 2 recomputes, noise by (row,
        step, dimension). `TanhMeanGaussian(T).draw` - BMPC's clamp(tanh m + e^(log s) eps, -1, 1) - is now ONE
        definition; LatentPolicyPlans calls it too. Known answers: two steps ahead, two target heads, bit for bit
        against a row-by-row reroll on single-row graphs (the draw's formula written out, the sum term by term);
        zero_last heads -> zero targets; same seed same targets, other seed others; refusals. Controls: the end value
        not discounted -> the bit-for-bit test only; the latents not moved on -> the same, only. zimrnum 333/333;
        tutorial 18d.16 (what a target is, and why the policy, the model and the TARGET heads). TURN 2b2 NEXT - the
        world-model update in robot_bmpc.zig: windows of H rows from SequenceReplay; the rollout's observations
        assembled [row_0.observation, row_t.next_observation ...]; rewards and LatentValueTargets two-hot encoded
        into WorldModelLoss's target tensors; setFinished; backward; clipGradNorm(.., 20) over every world-model
        parameter; two Adams (the encoder at 0.3 x 3e-4); the target heads follow (tau 0.01). Known answers: the
        assembly by hand; the clip at 40 -> 20 and 10 untouched (clipGradNorm's own direction test exists - here the
        wiring); the encoder's first Adam step 0.3 x the other's; the follow by hand; one update fingerprinted.
      TURN 2b2 DONE (Oct 3) - TURN 2 COMPLETE: robot_bmpc.zig `WorldModelLearner` (+ `WorldModelReport`), Config gains
        BMPC's learning numbers (windows 256, rho 0.5, weights 20 / 0.1 / 0.1, rate 3e-4, encoder x 0.3, clip 20, follow
        0.01, lookahead 1). Built once: the world model bound TRAINED on its graph (rollout + WorldModelLoss over
        tensors it owns), two Adams (encoder at 0.3 x - Adam with two parameter groups), LatentValueTargets on a frozen
        graph over the TARGET heads, the heads' Params for the follow. `update`: sample W windows of H rows ->
        `loadWindows` ([o_0 | n_0 .. n_(H-1)] - each step checked against its OWN successor; actions; reward two-hots;
        the targets' observations; a small `rowOf` helper) -> value targets, two-hot -> setFinished -> resampleDropout
        -> forward -> backward -> clipGradNorm over every parameter -> both Adams -> follow. Known answers: the windows
        laid out by hand (blocks, actions, targets' observations; reward two-hots decode back); one update - with the
        clip at 1e-3 the global norm after is the limit to 1e-12, Adam's first step never above the rate and its
        largest change the rate (9e-5 encoder, 3e-4 dynamics), every target number = before + 0.01 x (online - before);
        the same seed the same update bit for bit. Controls: no clip, and the encoder at the full rate - each fails
        exactly the one-update test. test-fast 623 (+3, first try); check 360/360. Tutorial 18d.18 (two figures,
        rendered and checked: the windows laid out, the five steps with their numbers; update's real code).
      TURN 3 DONE (Oct 3) - B4 COMPLETE: robot_bmpc.zig `PolicyLearner` (own graph over a latents tensor; the
        rollout's `unfinished` shared so one setFinished masks both losses; PolicyDistillationLoss with BMPC's entropy
        1e-4 and log-std bounds; RunningScale; its own clip at 20 and Adam epsilon 1e-5), `Learner` (world model, then
        policy unless pretraining), `discountFor` (L / 5 rule, clamped [0.95, 0.995]). The latents are the world model's
        rolled z_0 .. z_(H-1) read AFTER its Adam step - an optimiser changes weights, not the pass's values - which is
        torch's zs.detach(). Known answers: the latents bit for bit = the forward pass's; the targets = means and LOG
        spreads by hand; pretraining leaves the policy bit-identical while the world model moves, and the policy's half
        moves no world-model network; the policy's clip to exactly its limit; the discount at 50 / 100 / 500 / 1000 by
        hand. Controls: latents after a fresh recompute; spreads unlogged; pretraining ignored - each fails exactly its
        own test. test-fast 628 (+5, first try); check 360/360. Tutorial 18d.19 (two figures: the two halves; the
        discount rule plotted, computed - plus the real code).
      TURN 3 - B4b THE POLICY UPDATE AND `update()`. `updatePolicy`: the rollout's rolled[0 .. H-1] values copied,
        step-major, into the policy graph's latent constant AFTER the world model's forward and BEFORE its Adam
        step (torch: zs from the same forward, detached); targets from the rows (mean, LOG of std);
        PolicyDistillationLoss + RunningScale (update on step 0's KL rows, then divide); clip 20 on the policy's
        parameters alone; its own Adam (eps 1e-5). `Agent.update(rng, pretrain)`: sample windows -> world model ->
        policy (skipped while pretraining) -> target follow. The discount rule `discountFor(episode_length)` (denom 5,
        clamp [0.95, 0.995]) lands here too. KNOWN ANSWERS: the policy's latents = the rollout's rolled values, bit
        for bit; the world-model step leaves every policy parameter unchanged and the policy step every model
        parameter; pretrain = no policy change at all; the discount rule by hand (episode 100 -> 0.95 clamp; 1000 ->
        0.995; 50 -> 0.9 -> 0.95); one whole update fingerprinted. CONTROLS: latents taken after the Adam step ->
        the bit-for-bit test fails. Verify: the tests, `check`, then `test-fast` (the robot family).
      AFTER THESE THREE: B5 (reanalyze every 10 updates on 20 rows at horizon 3 with the exploration log std, writing
      back first_step 0; the warm-up schedule; the CARTPOLE GATE - zimrnum's cartpole, fixed-length episodes, gate
      widths, a balance threshold judged in the real simulator, inside 5 minutes), then B6 (review; tutorial 16.x).
  - **N7 EfficientTDMPC to parity with its v5 paper** (Evers, Meo, Bohmer, Dauwels, Oren; EWRL 2026, arXiv
    2605.16692v5, Sep 28 2026 - re-read Oct 4 against our code). THE CHECKLIST, from its Table 2 and Appendix D:
      HAVE  BMPC's base exactly at Table 2's BMPC column: latent 512, hidden 512 in two layers, encoder one hidden
            layer of 256, SimNorm 8, 2 value heads, 1 reward head, batch 256, lr 3e-4, encoder x 0.3, clip 20,
            tau 0.01, rho 0.5, 101 bins on [-10, 10], log std [-3, 1], entropy 1e-4, gamma from L in
            [0.95, 0.995], reanalyze every 10 updates on 20 windows, one update per environment step; PER-STEP
            INSERTION (SequenceReplay writes every frame - their "data freshness"); evaluation = the DRAWN elite
            without noise, as torch (zrl's Mppi doc and the tutorial claimed "best elite" - corrected Oct 4).
      GAP   (a) TWO PLANNERS, configured apart - acting {H 6, 512 samples, 64 elites, 24 policy plans, objective
                MEAN OVER DEPTHS, beta 0} and reanalyze {H 3, 64 / 8 / 3, objective FINAL, beta per task} - while
                the TRAINING window stays H 3. Today one `horizon` serves all three and both planners share one
                budget.
            (b) +2 MPPI iterations from 20 action dimensions up (BMPC's code: `>= 20`; its paper says "> 20"), in
                both planners (6 -> 8). DONE in B6a (Oct 4): it is BMPC's own rule, not EfficientTDMPC's.
            (c) the MULTI-HORIZON objective (eq. 6): (1/H) sum over h = 1..H of Q_h, the prefix of h planned actions
                bootstrapped with the value at depth h. Acting only (reanalyze keeps the final objective).
            (d) the DYNAMICS ENSEMBLE, Nf = 4 (2 and 8 as options; their AUC +10 / +22 / +33% for 2 / 4 / 8): heads
                with separate parameters, initialised differently, sharing the encoder, the reward head, the value
                heads and the policy. Training (Appendix D): every head rolls the window's actions out from the
                ENCODED start (eq. 11); consistency (eq. 12) and reward (eq. 13) averaged over heads; value (eq. 15)
                every value head on every head's latents, averaged over Nv x Nf; the value TARGET (eq. 14) the
                one-step backup from the TRUE latent through EVERY head - action sampled from the policy and
                detached, target value heads averaged - then averaged over heads; the POLICY loss (eq. 16) on each
                head's detached latents, averaged over heads.
            (e) ensemble SCORING (eqs. 7-9): every candidate rolled out under EVERY head (TS-infinity per head, not
                one head per sample - R1.6's guess was wrong) and bootstrapped with every value head: Nf x Nv
                estimates, their MEAN the score; the VARIANCE OF THE MEAN, Var(i, j) / (Nf Nv), kept for (f) (it
                underestimates - the estimates share heads - and the paper finds that harmless).
            (f) PESSIMISTIC REANALYZE (eq. 10): J = mean - beta x sigma, in REANALYZE ONLY (B.4: pessimism while
                acting does not help); beta = 10 where episodes can end early, 0 elsewhere (fig. 5: it hurts
                tasks without early termination).
            (g) PRESETS: `Config.bmpc(...)` (today's numbers, bit for bit) and `Config.efficientTdmpc(...)`, with
                early termination as an argument.
      OPEN  the policy's own plans under an ensemble - which head rolls the policy forward to produce them? Natural
            reading: head 0 generates, every head scores (scoring is where the ensemble matters). A choice with a
            test, and a bench arm if it turns out to matter.
    STAGES, each with known answers (KA) and a control that fails exactly its own test:
      N7a the two planners and the iteration rule. KA: the bmpc preset reproduces today's decisions bit for bit; an
          action of 20 dimensions plans 6 iterations, 21 plans 8; the training window is unchanged by the acting H.
      N7b the multi-horizon objective in the scorer. KA: at H = 1 it IS the final objective; planted rewards and
          values worked by hand; a planted pair of plans where it prefers the one whose prefixes stay valuable and
          the final objective prefers the other.
      N7c the ensemble's training. KA: Nf identical heads give Nf = 1's losses and gradients exactly; distinct seeds
          give distinct heads; one head's consistency term moves only that head and the shared encoder; the value
          target through identical heads equals Nf = 1's.
      N7d ensemble scoring and the variance of the mean. KA: identical heads give zero variance and Nf = 1's scores;
          a planted spread of estimates worked by hand.
      N7e pessimistic reanalyze. KA: beta = 0 is plain reanalyze bit for bit; planted variances flip the chosen
          plan exactly at the beta computed by hand; acting is untouched by beta.
      N7f THE CROSS-SCORING DIAGNOSTIC (their C.1): plan under one head and under the ensemble; score both plans,
          and the policy's action, single-head / ensemble / in the real environment (the same actions stepped, the
          learned values bootstrapping); Delta R = plan minus policy. The ensemble's plans must be the LESS
          exploited (their single-head Delta R looks large and is not real). This is how we know (d)-(e) work
          before any long run.
  - **N8 Measuring - their protocol, on our tasks.** Evaluation episodes every 10k environment steps in evaluate
    mode; per task the mean over at least 4 seeds with 95% CIs (mean +/- 1.96 SE); the area under each curve,
    normalised by OUR BMPC's return at the same budget (BMPC = 1).
      THE SUITE. (1) DMC-EQUIVALENT classic tasks, written to dm_control's definitions (rewards via `tolerance`,
      1000-step episodes, action repeat 2, 200k environment steps): cartpole balance, balance_sparse, swingup,
      swingup_sparse; pendulum swingup; acrobot swingup; reacher easy and hard. Their fig. 9 curves are
      approximate targets - our physics is not MuJoCo. (2) EARLY-TERMINATION tasks: the cartpole hold task (ends
      when the pole falls) and TrackEnv (falls).
      THE RUNS. The ladder: BMPC -> + practical (acting H 6, the cheap reanalyze) -> + multi-horizon -> + ensemble 4
      -> + pessimism (early-termination tasks only). Ensemble 1 / 2 / 4 / 8. Beta 0 / 1 / 3 / 10 / 30 on an
      early-termination task. Cheap vs full reanalyze. Wall-clock per 100k decisions.
      SUCCESS - what "at least as good as theirs" means for us: (i) the ladder's order reproduced, with
      non-overlapping 95% CIs between BMPC and the full method; (ii) the full method >= +30% AUC over our BMPC on
      the suite (theirs: +56% on five tasks); (iii) our BMPC's final aggregate reached in <= 60% of the steps
      (theirs: 43%); (iv) on the DMC-equivalent tasks, returns within the range of their fig. 9 at 100k and 200k
      steps; (v) beta helping where episodes end early and not elsewhere, as in their fig. 5.
  - **N8b Termination.** The paper models no termination - its base, BMPC, has none - yet its pessimism pays exactly
    where episodes end early. For TrackEnv's falls and the cartpole hold task: a CONTINUE head option (sigmoid,
    binary cross-entropy against 1 - terminated; a hard 0/1 inside the planner's value, the soft probability inside
    value targets), measured against no termination on the early-termination tasks, with and without pessimism.
    Kept only if it wins.
  - **N9 The kit - a prerequisite of N8's full-size runs.** The rollout under Nf heads, the categorical heads, MPPI's
    scoring (512 samples x 8 iterations x H 6 x 4 heads per decision) and the value targets as batched GPU kernels,
    checked against the CPU graph. Their A100 takes 47 minutes per 100k decisions; ours need not match, but one
    200k-step run must fit in a day for N8 to be practical. Until then: reduced widths, as the cartpole gate.
  - **N10 Jumpy dynamics - an EXPERIMENT after N7-N9 (Simon, Oct 4).** One more network beside the 1-step dynamics:
    a 4-STEP head f4(z_t, a_t .. a_t+3) -> z_t+4 (SimNorm output, the same latent space), with a 4-step REWARD
    output - the jump skips three per-step rewards - the discounted sum r_t + gamma r_t+1 + gamma^2 r_t+2 +
    gamma^3 r_t+3 (two-hot, the same bins). The encoder and the value heads are shared: V(z) does not depend on how
    z was reached, and the bootstrap after a jump is gamma^4. PLANNING: one FIXED schedule every candidate shares -
    jumps 1, 1, 4, 4: 10 steps of lookahead (0.33 s at DReCon's 30 Hz) in 4 evaluations, against EfficientTDMPC's
    acting H 6 (6 steps in 6). MPPI still searches per-step actions (10 x A), the 4-step head reading its 4; the
    multi-horizon objective's depths become the jump boundaries 1, 2, 6, 10. NOT per-rollout resolutions:
    candidates scored at different resolutions are not comparable (the heads' biases differ). TRAINING: windows of
    >= 5 observations for one jump (11 for the whole schedule); f4's consistency from each true latent against the
    encoding 4 steps later; value-equivalence (the value heads read f4's latents, against the targets 4 steps on);
    the 4-step reward against the window's discounted rewards; masks for spans that cross an episode's end;
    optionally a cross-scale consistency f4(z, a1..a4) ~ f1(f1(f1(f1(z, a1), a2), a3), a4), which needs no data. The
    1-step dynamics stays: the policy needs per-step latents to propose plans and to be distilled (its own plans
    rolled 1-step). LEARNABILITY (DReCon): 133 ms under PD control is smooth, more so with the 0.2 action filter -
    but the filter's state must be in the observation, or the 4-step map is not Markov; contacts inside the span and
    motion-matching switches from user input are the hard parts (the latter unpredictable at any resolution - f4
    learns their average). KNOWN ANSWERS: a linear system z' = A z + B a, where f4 must learn A^4 z + sum over i of
    A^(3-i) B a_i; the 4-step reward as the hand-discounted sum; the schedule's score by hand. MEASURED with N8's
    protocol, the premise first: f4's error against four chained 1-step predictions on held-out windows, then the
    schedule against H 6 at equal planning time.

**R1.6 Open questions - after reading BMPC's code.** ANSWERED: SimNorm's form, two-hot and its loss, the
consistency loss (MSE against no-gradient encodings, rho^t, /H), MPPI's update and warm start, the policy target
(a drawn elite's first action and std), the KL (policy first, running-scaled, with the entropy term), the value
target (model rewards along a policy rollout, target heads), the discount rule, the buffer layout, the schedule. ANSWERED
BY THE v5 PAPER (Oct 4, Appendix D): the dynamics heads share the encoder and each has a consistency term, averaged
over heads (eqs. 11-12); scoring rolls EVERY candidate under EVERY head - not sample k under head k mod E (eqs. 7-8);
value targets average the one-step backup over every head, with the target value heads averaged (eq. 14). See N7.
STILL OPEN: which head rolls the policy forward to produce its own plans under an ensemble (N7, OPEN). And for us: TrackEnv's falls are early terminations, so by their rule
pessimism should help - consistent with I1b.

**R1.7 Carrying it to the dance.** TrackEnv is the environment (decisions, falls as `.stop`, the cap as `.cut`); the
latent model learns from its decisions; the policy prior's action is the residual nudge. Three of R1's ideas apply
beyond BMPC and are worth trying on SuperTrack directly: an ensemble of world models whose MEAN the policy trains
through (I1b averaged two - R1 says 4 to 8, and that more is better); the ensemble's disagreement as a penalty on the
policy's objective (I1b's w_disagree - R1 applies it only where it distills, and only when episodes can end early);
and averaging the objective over rollout depths (SuperTrack's window loss already sums over its steps; R1's form
bootstraps at each depth). Each is an I-stage ingredient with a parity test, then a bench arm.

### R4 Four more read Oct 1 (Simon asked what fits) - CANDIDATES, none scheduled

- **Newt** (Hansen, Su, Wang; arXiv 2511.19584, ICLR 2026) - TD-MPC2 scaled to 200 tasks with online RL, conditioned
  on a language embedding fed to every component; demonstrations used four ways: (1) model-based pretraining of ALL
  components, the policy's Q term off; (2) constrained planning - the planner biased toward the pretrained policy,
  annealed to zero over the first 12% of training; (3) a separate demonstration buffer sampled 50 / 50; (4) a BC term
  in the policy loss, on rolled latents. Also: open-loop plans of 48 steps, 16x its training horizon of 3, close to
  closed-loop on most tasks; model AND batch size matter once tasks multiply. FOR US: (a) V2 gets a third route,
  MODEL-BASED DISTILLATION - per-clip teachers' rollouts as demonstrations; in BMPC the BC term needs no new loss: a
  demonstration row's target columns hold the teacher's action with a small std, and BMPC's existing KL distillation
  IS model-based BC; pretraining = the warm-up burst on demonstration rows; oversampling = a second SequenceReplay,
  half the batch; constrained planning = an Mppi option biasing toward the policy prior, annealed. KA to plan: with
  demonstrations only, the pretrained policy matches plain BC on them; reanalyze never overwrites a demonstration
  row. (b) no task embedding needed: for tracking the REFERENCE is the instruction, already observed. (c) the open-
  loop rollout length at which tracking breaks - a world-model DIAGNOSTIC worth logging (and, at run time, the
  number of steps between re-plans an NPC could afford).
- **RAY-TOLD** (Han, Lee, Kang; arXiv 2604.27450, Apr 2026) - crowd navigation: MPPI with short PHYSICS-based
  rollouts plus a learned terminal value and policy prior (policy trajectories mixed into the MPPI population - our
  24 policy samples already), around a LiDAR-ray latent model. FOR US, after the gate: Mppi is already decoupled from
  its scorer (the caller drives the loop), so a kinematic NPC can plan with EXACT short rollouts + a learned value;
  and ray observations are cheap game sensors (zimr's physics raycasts) - a natural V1 asymmetric observation (the
  NPC's policy senses rays; the world model sees the state).
- **IQL-TD-MPC** (Chitnis et al.; arXiv 2306.00867, 2023; ICRA 2024 - not 2026) - OFFLINE model-based RL: IQL inside
  TD-MPC, then a temporally coarse "manager" planning latent subgoals ("intent embeddings", g = f(z, a^M) - z)
  concatenated to any offline worker's state; large gains on sparse long-horizon AntMaze. FOR US: later, for layered
  behaviours (a manager choosing where to go or which clip, the tracker below); tracking itself is dense and short.
- **ViGMO** - not found under that name (Oct 1). Its subject, visual generalization under distractors with
  augmentation (cf. SADA, RL-ViGen), concerns pixel observations; our agents observe simulator state - low priority.

### R2 onward - candidates to study next (named in R1's related work and baselines)
Mrs. Q (Chang et al. 2026: pessimism critical on HumanoidBench, harmful on DMC), DR.Q (Lyu et al. 2026: debiased
model-based representations for Q-learning), BRC (Nauman et al. 2025: bigger, regularised, categorical critics),
SimBa-v2 (Lee et al. 2025: hyperspherical normalisation), BOOM (Zhan et al. 2025) and TD-M(PC)^2 (Lin et al. 2026):
policy regularised toward the actions taken, TSMCTS (Oren et al. 2026): multi-depth averaging's variance argument,
and roxie's TD4 (plan I5).

### R3 DR-EfficientTDMPC - a PROPOSAL: distributional robustness on top of R1 (Simon, Sep 28)

(Simon: "add this new idea at the end of the plan, make it fit our current plan ... find the best way to prepare for
that; spend 5 turns making the plan and verifying it". Status: COMPLETE, five turns (Sep 28). Turn 1: the critical
reading and the
triage (R3.0-R3.4). Turn 2: DR-SAC's own code read (R3.5) and Simon's use for it - robustness that BUYS physics
speed (R3.6). Turn 3: the core maths checked numerically, a correction to R3.1's scope, the theory and efficiency
claims checked (R3.7). Turn 4: re-centred on OUR problem by Simon - R3.8 is the result and supersedes R3.3, R3.4 and
R3.6 where they differ. Turn 5: the consistency pass - section 6.0 is now ONE order across every track, 3.9
records Sep 28's infrastructure, R1.4 and N2 are current, I1b points at V3.)

**R3.0 What it is.** An unreviewed proposal - no experiments ("expected performance" is argued, not measured) -
composing DR-SAC (Cui et al., ICLR 2026: soft actor-critic against the WORST transition model within a KL ball around
the nominal one, via a scalar dual) with R1 as the engine, plus consistency distillation, BatchEnsemble / MIMO
ensembles, an evidential value head and adaptive test-time compute. So it is read here as a MENU: each idea earns its
place by a known answer and a bench arm, and nothing is taken as a recipe to reproduce.

**R3.1 The core idea, in our terms - worth building.** The TD-MPC family's dynamics heads are DETERMINISTIC, so "the
ensemble as the nominal transition" (R3's section 4.4) is a distribution with N atoms: one next latent per head, each
with weight 1/N. A distribution within a KL ball around it must keep its support (finite KL), so the worst case can only
REWEIGHT those atoms - and the robust expectation of a value v over them is the KL dual (Hu and Hong 2013):

    robust_delta(v_1..v_N) = sup over beta > 0 of { -beta log( (1/N) sum_i exp(-v_i / beta) ) - beta delta }

- a SOFT MINIMUM of the heads' values, with delta the pessimism knob: delta = 0 gives the mean (R1's eq. 3); delta >=
log N lets the worst case put all its weight on the lowest atom (KL(one-hot || uniform) = log N), giving the minimum
(TD3's clipped double-Q); in between, a principled blend. Consequences, each to be verified in turn 3:
  - The per-(z, a) dual is a ONE-DIMENSIONAL CONCAVE maximisation over N numbers - cheap and exact. DR-SAC's dual
    NETWORK g_eta amortises beta* over infinitely many continuous next-state distributions in the offline setting;
    with N atoms it is unnecessary.
  - For small delta, robust_delta ~ mean - sqrt(2 delta) * std: R1's pessimistic reanalyze, J = Q^ - beta sigma^, looks
    like this expansion - with sigma^ the std of the MEAN, beta sigma^ = (beta / sqrt(N)) std, i.e. delta ~ beta^2 /
    (2 N) = 6.25 for R1's beta = 10 and N = Nf x Nv = 8 - already past log 8 = 2.08, where the KL-robust value IS the
    minimum. (If turn 3 confirms it: R1's beta = 10 is "take the worst head", and delta is the natural dial below it.)
  - Its gradient, where it enters a loss, is the envelope theorem's: d robust / d v_i = tilted weights w_i proportional
    to exp(-v_i / beta*), summing to 1 (beta* held at its optimum).
  Two DROP-IN uses in R1 / BMPC, both options on R1's N6 / N7: (1) VALUE TARGETS - y(z) = R(z, pi(z)) + gamma *
  robust_delta over the Nf x Nv pairs (i, j) of V_target,j(f_i(z, pi(z))), where R1 takes their mean; (2) the PLANNER -
  robust_delta over the (i, j) estimates of each candidate sequence (TS-infinity keeps the heads apart; the aggregation
  is across heads, per sequence), acting and/or reanalyze.

**R3.2 The rest, triaged** (verdict and reason; turn 3 checks each against the literature):
  - *Robust SOFT Bellman, SAC's temperature.* BMPC is a distillation method with a 1e-4 entropy bonus, not max-entropy
    RL; the robustness does not need the "soft". Keep robustness, leave the max-entropy framing (optional later).
  - *Probabilistic dynamics heads.* NEEDED for R3.6 - revised in turn 3 (R3.7): deterministic heads carry MODEL
    uncertainty only, and the messy world's spread is invisible to them. An option with a known answer, not a default.
  - *The dual network g_eta.* Unnecessary with N atoms (R3.1). Drop.
  - *"Consistency distillation" of the dynamics.* Mislabelled - a k-step direct predictor regressed on the teacher's
    rollouts is multi-step distillation, not a consistency model (Song et al. 2023: no noise, no probability-flow ODE).
    It also CONFLICTS with R1's multi-horizon objective, which needs the latent at EVERY depth; and on our CPU the cost
    is arithmetic, not sequential depth. Defer; revisit only on the kit, with a student that outputs every depth.
  - *"Consistency planner".* In substance an action-CHUNK policy as MPPI's proposal plus 1-2 refinement iterations.
    BMPC already seeds MPPI with 24 policy trajectories; a chunk policy is a sensible compute knob later. Defer - to be
    measured against R1's 1/8-budget reanalyze first.
  - *BatchEnsemble (Wen et al. 2020) / MIMO (Havasi et al. 2021).* BatchEnsemble cuts PARAMETERS and memory, not
    arithmetic - each member still multiplies its own inputs. MIMO does cut arithmetic - one pass for M members - by
    sharing one network's capacity. Neither saves "a factor N_f N_v" of compute as claimed without paying for it, and
    correlated members weaken exactly the disagreement pessimism feeds on. Defer to the kit; if tried, the known answer
    is R1's Appendix C.1 measurement (does disagreement still predict
    the planner's exploitation?).
  - *Evidential value head (Amini et al. 2020).* Its variance is known to be poorly calibrated as EPISTEMIC uncertainty
    (Meinert et al. 2023), and a categorical value head already reads a return spread for free. Defer; same known
    answer.
  - *Adaptive test-time compute.* Sensible once an uncertainty signal is SHOWN to predict when planning helps. Defer.
  - *The theory* (contraction, interchange, regret) is DR-SAC's, with its assumptions - a FINITE action set (log |A| in
    the bounds, not our continuous actions), a bound exponential in 1 / beta - carried to latent space as sketches.
    Motivation, not load-bearing here.

**R3.3 [DEPRIORITISED in turn 4 - a problem we do not have] What robustness needs that the plan does not have yet:
a SHIFTED-DYNAMICS benchmark.** A robust method is
judged by training on the nominal physics and evaluating on perturbed physics (mass, friction, actuator strength,
action noise, pushes). Without it, "robust" cannot be told from "pessimistic". Turn 4 finds the knobs our fleet
exposes and specifies the benchmark.

**R3.4 [SUPERSEDED by R3.8's V1-V5] Preparation, in order:** P0 measure first - the physics' share of a training
iteration's
wall-clock, and the sim gap (R3.6); P1 the robust aggregation primitive, plain and on the graph, with the known answers
turn 3 verifies; P2 robust value targets and robust planning, as options on N6 / N7; P3 the benchmark - "train messy,
run accurate" (R3.6) and DR-SAC's shift suite (R3.5); P4 bench arms - nominal, domain randomisation, R1's mean, R1's
beta sigma, KL-robust at a delta sweep - all judged in the ACCURATE physics.

**R3.5 DR-SAC's own code, read** (`DR-SAC-master`, Sep 28: `sac.py`, `environment_modifiers.py`,
`config/sac_config.yaml`). What it actually does:
  - The dual is computed WITH its -beta delta term (`dual_func_g`, `dual_func_ind`; the README's formula drops it):
    -beta (logsumexp(-V(s') / beta) - log n) - beta delta, over n = 200 next states SAMPLED from a generative model of
    the nominal transition - a VAE by default, or diffusion, a flow, a score model. That is the same N-atom form as
    R3.1, with N = 200 samples where we have N heads: the generative models exist only to produce samples, and our
    deterministic ensemble produces its atoms directly.
  - The robust value is a DROP-IN in the TD target: target_Q = r + (1 - done) gamma V_robust - where R3.1 puts ours.
    With `use_v`, V(s') is a state-value network, evaluated at the sampled next states (BMPC has state values too).
  - beta*: either the "functional" dual network (exp-activated output, 5 ascent steps on the dual per update) or a
    per-sample bounded scalar search over beta in [1e-4, 1]. That upper bound is a HIDDEN pessimism setting: the dual
    reaches the mean only as beta grows, so with returns in the hundreds a cap of 1 keeps the robust value near the
    sample MINIMUM whatever delta says. Ours: the exact 1-D concave maximum over beta > 0, no cap.
  - delta = 0.1 by default. Everything in it is offline (datasets), SAC with twin critics.
  - The test suite (`environment_modifiers.py`) - the model for our P3: parameter shifts as factors on nominal values
    (gravity, mass, length, engine force, joint stiffness and damping, actuator range); observation noise (gaussian,
    uniform, cauchy, salt-and-pepper, adversarial; per dimension; a frequency); reward shifts; transition
    perturbations with a probability per step (random forces, friction changes, and "teleport" - which moves only the
    OBSERVATION). Train at nominal, judge under each shift.

**R3.6 [PARTLY DEPRIORITISED in turn 4: the cheap physics and solver drift are problems we do not have; the REDUCED
OBSERVATION is kept, and R3.8 reshapes it] Simon's use: robustness that buys physics speed** (Sep 28: "we will be able
to increase physics dt, and reduce
constraint solver steps, for perf, and reduce observation dimensions, which makes the world more messy and
stochastic"). Cheaper physics and a smaller observation make the transitions the learner sees noisier and less
predictable - exactly what a KL ball around the nominal model is meant to absorb. So the benchmark becomes "TRAIN
MESSY, RUN ACCURATE": train in the cheap settings, judge in the accurate physics (and under R3.5's shifts). Details
that make it an honest test:
  - The knobs exist: `Model.opt.timestep` (1/240 by default; tracking fleets set their own) and
    `opt.solver.max_iterations` (60). Soft constraints floor their time constant at 2 x timestep, so a larger step also
    SOFTENS contacts by itself - a change in the physics, not only noise on it.
  - Hold the DECISION rate when the step grows: TrackEnv decides every `decimation` physics steps (30 decisions a
    second at 60 Hz, k = 2); doubling the step means k = 1 - the policy's world stays one decision per 1/30 s.
  - The PD servo is tuned for its step. First known answer: the servo alone - the untrained policy - still tracks the
    clip in the cheap settings (its MTTF there against the accurate physics'); a servo that goes unstable is a
    different problem from the one robustness solves.
  - The SIM GAP, measured: from the same states and actions, how far the cheap physics' next states land from the
    accurate physics' after one decision. The delta sweep should span it.
  - Observation reduction: fewer watched bodies, velocities dropped, fewer future reference frames. Partial
    observability makes transitions stochastic from the learner's side (different states look alike); the ensemble's
    disagreement should rise there - R1's Appendix C.1 measurement again.
  - What the guarantee does NOT cover: DR protects against shifts inside the KL ball around the TRAINING nominal. The
    cheap-to-accurate shift is never seen in training, so delta is chosen by validation - a sweep judged in the
    accurate physics. And the baseline to beat is DOMAIN RANDOMISATION (the step, the solver iterations and the masses
    drawn per episode) - the standard answer for sim-to-sim and sim-to-real transfer - besides the plain nominal policy.
  - Measure first (P0): the speed-up is worth having only if physics is a large share of a training iteration. On our
    CPU the learner's graph may dominate (the SuperTrack bench's iterations are mostly world-model and policy updates);
    the physics share decides whether "cheap physics" buys wall-clock at all.

**R3.7 Turn 3: the maths verified, a scope corrected, the claims checked.** The script is kept in
`src/notes/bench/r3_kl_robust_check.py` (Python, outside zimr). The robust value is computed two independent ways -
the DUAL (a 1-D search over beta) and the PRIMAL (a generic constrained optimiser over the reweightings, knowing
nothing of duality) - on 8 values ~ 100 +- 15, returns-sized:
  1. Dual = primal: worst gap 1.7e-7 of the spread over 40 draws x 7 deltas. The formula is right.
  2. Limits: delta -> 0 gives the mean; delta = log N and above gives EXACTLY the minimum; delta = log N - 0.2 still
     sits 0.16 above it.
  3. Small delta: (mean - robust) / (sqrt(2 delta) std) = 0.981, 0.994, 0.998, 0.9994 at delta = 1e-2 ... 1e-5, the
     std normalised by 1/N. The expansion holds.
  4. R1's beta = 10 with N = 8: mean - beta std / sqrt(N) lands BELOW the worst head in 100% of 2000 draws (either std
     convention). R1's pessimism is not a KL-robust value at all - the KL family never goes below the worst head - it
     is a variance-averse RANKING of candidates, harsher than any delta. So the two are different knobs; both stay
     bench arms (R3.4, P4).
  5. The dual is concave in beta (checked on LINEAR beta grids: worst chord gap 3e-14 of the range - a first check on
     a log-beta grid was malformed, concavity in beta is not concavity in log beta). So a 1-D search for beta* is
     reliable: the known answer for P1's solver.
  6. Gradient: finite differences equal the tilted weights w_i ~ exp(-v_i / beta*) to 3e-9 (envelope theorem).
  7. DR-SAC's cap beta <= 1 at this scale, delta = 0.1: the robust value falls from 89.97 (exact) to 78.08 - next to
     the minimum, 76.11. The cap is a pessimism setting in disguise.
THE SCOPE CORRECTION (turn 1 was wrong here). The N-head form covers MODEL (epistemic) uncertainty only: heads differ
where the data does not pin them down. Simon's messy world adds TRANSITION (aleatoric) spread: with a reduced
observation the same observation leads to different next states - different true states look alike - and a
deterministic head fitting that learns the AVERAGE next latent. The heads can agree on that average, and then the
spread is invisible to the ensemble: a robust value over heads would not see it. So R3.6 needs PROBABILISTIC heads -
the proposal's choice, deferred in turn 1 - each predicting a spread as well as a centre; the nominal is the mixture,
M next latents are sampled per head, and the SAME primitive aggregates the N x M atoms. SimNorm latents live on
simplices, so the noise goes in BEFORE SimNorm (sample the pre-activation, then normalise). Known answer for turn 4's
build step: on a planted coin-flip transition (two next states, equally likely), deterministic heads converge to the
midpoint - zero spread, robust value = the mean - while probabilistic heads recover both branches, and the robust
value moves toward the worse branch as delta grows.
THE THEORY, checked: the KL dual is Hu and Hong's (2013) - verified numerically above for discrete nominals; the
contraction is the standard one for (s, a)-rectangular sets (Iyengar 2005; Nilim and El Ghaoui 2005) - in latent space
it needs the latent model to be Markov, which it need not be; the regret bound grows like exp(V_max / ((1 - gamma)
beta)) - with gamma = 0.99 and returns in the hundreds it is vacuous; the finite-action assumption bounds DR-SAC's
dual network, which we do not use. Motivation, none of it load-bearing.
THE EFFICIENCY CLAIMS, checked: consistency models (Song et al. 2023) distil a probability-flow ODE into a one-step map
- the proposal's "consistency dynamics" is multi-step prediction, mislabelled (R3.2 stands); BatchEnsemble saves memory,
MIMO saves arithmetic at the cost of independence (R3.2 refined); deep evidential regression (Amini et al. 2020) has
been shown not to measure epistemic uncertainty reliably (Meinert et al. 2023; Bengs et al. 2022) (R3.2 stands).

**R3.8 Turn 4 - what has the most value for OUR tracking problem** (Simon, Sep 28: "I like the part about not having
the whole env state in the observation, so it is more stochastic. This is more important than solver drift. I don't
want to try to solve problems we don't have. I like the distillation for reducing the cost of rollouts ... We want
speed and tracking quality for diverse anims."). What we have: SuperTrack's world model sees the character's FULL
simulated state, and so does its policy (the full latent and the goal); DReCon's observation is already partial (six
watched bodies, the centre of mass, reference views 2 / 4 / 6 frames ahead); about ten clips - two dances, two runs,
two walks, a fall-and-get-up, a push-and-stumble, a jump, Geno's dance - of which the bench uses one. In value order:

  **V1 ASYMMETRIC OBSERVATION - the policy partial, the world model full.** In simulation the full state is FREE at
  training time. So the partial observation lives only where it is real: the POLICY - the one thing that runs in the
  game - sees a reduced observation; the WORLD MODEL (and any critic) keeps the full state (asymmetric actor-critic,
  Pinto et al. 2018, carried into SuperTrack). The model stays deterministic and accurate; the policy's gradient,
  taken through it, averages over every state consistent with what the policy sees - so the policy learns the best
  action for its partial view, and the stochasticity sits where Simon wants it and nowhere it hurts. It also SETTLES
  turn 3's correction: probabilistic heads were needed only if the MODEL saw a partial observation - here it does not.
  Build: an observation SELECTION (a fixed choice of features from the model's predicted state - differentiable)
  between the model's rollout and the policy's input; the reductions worth measuring - fewer watched bodies, velocities
  dropped, fewer lookahead frames - with the last applied action kept as a short memory (A1 already feeds it).
  KNOWN ANSWERS: selecting every feature reproduces today's training bit for bit; the parity test (graph = rows) holds
  under any selection; then the bench's curve - tracking quality against observation size.

  **V2 DIVERSE ANIMATIONS - one policy, many clips.** The quality target is a single runtime policy that tracks every
  clip. Two routes, compared on the same benchmark: (a) train one multi-clip SuperTrack policy directly (SuperTrack
  itself was trained on a large dataset); (b) DISTIL: train per-clip (or per-family) teachers - full observation,
  easiest learning - then one STUDENT with the reduced observation, by DAgger (the student acts, the teachers label
  its states; MoCapAct's route for many clips, and the standard teacher-student route to partial observability in
  locomotion). The benchmark first: train on most clips, judge on all of them AND on held-out ones (generalisation),
  tracking quality per clip. KNOWN ANSWERS: a student distilled from ONE teacher on ONE clip reaches the teacher's
  tracking; DAgger's labels are the teacher's actions at the student's own states (a row test).
  A THIRD ROUTE to weigh when V2 starts (R4, Newt): MODEL-BASED DISTILLATION - the teachers' rollouts as demonstrations
  inside BMPC itself (a demonstration row's target = the teacher's action, so BMPC's KL distillation is model-based
  BC; the warm-up burst pretrains on them; a second SequenceReplay sampled 50 / 50; the planner biased toward the
  policy prior, annealed) - a bench question against DAgger, not a default.

  **V3 ROBUST TRAINING THROUGH A WORLD-MODEL ENSEMBLE** - R3.1's primitive, aimed at the failure we MEASURED (I1b: the
  policy exploits the model's errors, exploitation 100-300). K full-state world models; the policy's window cost
  evaluated through each; the K costs aggregated KL-robustly - for COSTS the soft MAXIMUM, -robust(-cost) - with delta
  the dial from the mean (delta = 0: I1b's twin average) to the worst member (delta >= log K). The principled form of
  I1b's disagreement price, with one knob instead of a price per feature. Cheap to build: by the envelope theorem the
  gradient is the tilted weights times each member's gradient, so the graph needs only a weighted sum with the
  weights as constants, refilled each step - no new op. With V1 the members' disagreement is purely MODEL uncertainty,
  which deterministic heads represent correctly. KNOWN ANSWERS: delta = 0 reproduces the ensemble mean's loss (I1b's
  twin average, bit for bit at K = 2); delta >= log K is the worst member's; the weighted-sum gradient matches finite
  differences of the robust cost; R3.7's seven numbers for the primitive itself.

  **V4 DISTILLATION FOR ROLLOUT COST** (Simon's). Where rollouts cost us: SuperTrack's policy loss backpropagates
  through a window of model steps; BMPC-style planning (R1) rolls hundreds of candidates. Three uses, in order of
  value: (a) PLANNER INTO POLICY - BMPC already does it: plan while training, act with the policy alone at run time,
  so the game never pays for search; (b) a SMALL STUDENT world model, distilled from the full-state teacher (or V3's
  ensemble) on replayed states and the policy's own actions, used for the policy's training rollouts - cheaper per
  step on the CPU, re-distilled as the teacher improves; (c) a student that predicts a whole window in ONE pass
  (every intermediate state - the tracking loss needs every frame, which is why R1's multi-horizon objective ruled
  out the proposal's k-step jump) - a win for sequential depth, so for the kit (Stage G). KNOWN ANSWERS: the
  student's k-step error against the teacher's on held-out windows; the policy trained through the student against
  through the teacher - tracking quality against wall-clock.

  **V5 SPEED, MEASURED FIRST** (P0, kept): where a training iteration's time goes - the fleet's physics, the world
  model, the policy's rollout and update - and the RUNTIME cost that matters in the game: one policy forward pass per
  character per decision, so its width and its observation's size (V1 shrinks both).

  NOT OUR PROBLEMS (Simon): cheap physics and solver drift, sim-to-real parameter shifts and the shifted-dynamics
  benchmark (R3.3, R3.6), DR-SAC's theory, probabilistic heads (V1 makes them unnecessary), BatchEnsemble / MIMO /
  evidential values / adaptive test-time compute (R3.2). Kept from R3: the KL-robust primitive (R3.1, verified in
  R3.7) - now serving V3.


### R5 SuperTrack x BMPC / EfficientTDMPC - a MERGE, PROPOSED (Simon, Oct 5)

Simon's brief: "a tentative merge of what we are doing with the direct-gradient supervised learning of SuperTrack.
Brainstorm all possible ways to include this, find the best, most performant solution. Our goal is to be as fast as
SuperTrack, but more robust to large perturbations, and even invent get-ups to get back to the mocap after a fall."
(The SuperTrack paper re-read Oct 5; numbers below are its.)

**R5.1 Why each side is what it is.**
  SUPERTRACK is fast for one reason: a PATHWISE gradient of a KNOWN, DENSE, differentiable loss (the tracking
  losses - local positions, velocities, rotations, angular velocities, heights, up vector) through a learned
  differentiable model, over a window of N_pi = 32 frames. Every policy step gets the exact direction that lowers 32
  frames of tracking error; an iteration is one world-model step (batch 2048, window 8) and one policy step (batch
  1024, window 32); acting is ONE policy forward pass; it is off-policy (a 150k-sample ring, ~5000 samples/s).
  Its three limits are exactly the brief's three goals:
    (1) the HORIZON IS THE WINDOW - nothing after 32 frames (~0.5 s at 60 Hz) reaches the policy (their sec. 7);
    (2) the gradient is LOCAL - a get-up first moves AWAY from the reference (hands down, roll, kneel: the tracking
        error rises before it falls), so no downhill direction leads there (their sec. 8: "does not exploit
        exploration... difficult to discover stepping motions to recover from falls");
    (3) the gym RESETS on a fall (head 25 cm off) - the world model never learns lying, rolling, pushing off the
        ground; the policy never sees a fallen state.
  BMPC / EFFICIENTTDMPC brings what is missing: a VALUE (an unbounded, discounted horizon), a PLANNER (search, which
  can climb uphill in tracking error toward a better long-run value), the ENSEMBLE's disagreement and PESSIMISM
  (robustness: stay where the model has been trained), DISTILLATION (search amortised into a fast policy). Its costs:
  value learning by TD is slow to propagate; acting by MPPI costs a search per step (512 x 6-8 x H x Nf model
  calls); its reward head and latent dynamics carry learned error where SuperTrack's reward is EXACT.
  THE GAME'S BUDGET (R3): one policy forward pass per character per decision - so a planner can be a TRAINING-TIME
  teacher, not a runtime part.

**R5.2 Every way to combine them** (verdict after each):
  M1 THE VALUE TAIL - SuperTrack's pathwise loss over the window plus gamma^H x V(state at the window's end), V
     learned (SHAC, Xu et al. ICLR 2022; Dreamer's actor; MAAC, Clavera et al. 2020; SVG, Heess et al. 2015).
     Removes limit (1) at the cost of one critic. CORE.
  M2 THE KNOWN REWARD - the tracking loss is an exact, differentiable function of the simulated and kinematic
     states (SuperTrack's observation 1), so the planner and the critic's targets use it directly; a reward head
     only where a reward is not known (the get-up objective below is known too). CORE.
  M3 SUPERTRACK'S STRUCTURED MODEL (Stage D's AccelWorld) as the dynamics everywhere - pathwise loss, critic
     targets, planner - against M4 below; Stage D3's A/B decides. Either way an ENSEMBLE of Nf heads (N7c).
  M4 BMPC's LATENT model with pathwise policy training through the latent (Dreamer-style). Value-equivalent, but
     no physical structure - its long rollouts drift (their fig. 14: even the structured model loses joint
     constraints past 64 frames). The D3 A/B's other arm.
  M5 THE PLANNER AS A SPARSE TEACHER - MPPI (the N7 actor: ensemble scoring, the known reward, the critic's tail,
     pessimism) run only on FLAGGED states - large tracking error, fallen, high ensemble disagreement - in the gym
     (directed exploration for a fraction of the characters) and in reanalyze (targets for stored flagged states);
     the policy's loss gains BMPC's KL to the planner's answer on those states. Removes limit (2) where it binds.
     CORE.
  M6 PLAN-WHEN-LOST AT RUNTIME - the planner overrides the policy under high disagreement. Breaks the game's
     budget; kept only as a development tool (a bench arm: how much does search add on top of the policy?).
  M7 THE PESSIMISTIC TAIL - the tail uses mean - beta x sigma over the critic and model ensembles (EfficientTDMPC's
     eq. 10, moved from reanalyze into the pathwise objective): the policy is pulled toward states the ensemble
     agrees on - robustness, and the brake on SuperTrack's model exploitation (risk 2 in section 8). CORE.
  M8 THE GYM FOR FALLS - no termination on a fall during training (episodes bounded by length only); a push
     curriculum (the paper's cubes: 5 m/s, mass growing); fallen starts (ragdoll drops, mid-fall states); a
     transition budget so the ring is not flooded with lying still. Removes limit (3). CORE.
  M9 RE-ENTRY BY MOTION MATCHING - when the simulated character is far from its reference, the reference becomes
     the database frame nearest the SIMULATED pose (DReCon's matching, queried with the physics state), so get-up
     clips (LaFAN has them) are found and tracked from where the character lies; continuous return to the original
     clip once close. Without get-up clips: HOLD the reference and track a reduced objective (height, up vector,
     root toward the held reference) until upright - the value and the planner must INVENT the get-up. SUPERSEDED for the one dance by R5.8 (Oct 5): re-entry and
     the hold are discrete switches; kept for the clip library, where re-entry chooses WHICH clip to rejoin.
  M10 THE CRITIC'S TARGETS FROM IMAGINATION - lambda-returns on model rollouts (MVE, Feinberg et al. 2018;
     Dreamer) plus real transitions: the critic learns at the pathwise loop's pace instead of TD's. CORE (speed).
  M11 SHORT WINDOW, CLIPPED - pathwise gradients through contact explode or mislead with long windows (SHAC's
     finding; Suh et al. 2022 on first-order gradients through contact); with a value tail the window can SHRINK
     (16-32), each piece of the trajectory stable; gradient clipping as SuperTrack found useful.
  M12 MIXED ESTIMATORS - pathwise where the dynamics are smooth, zeroth-order (the planner's search) where they are
     not (Suh et al.'s interpolation): M5's flags are this, by state. Subsumed by M5.
  M13 ACTIONS FAR FROM THE REFERENCE - SuperTrack's offsets around the reference pose (alpha 120) assume the
     reference is near; with M9's re-entry the reference is near again (the get-up clip from the lying pose); with
     the hold fallback, larger offsets are needed - the offsets' scale (or the regularisers' weight) reduced while
     far. Detail of M9.
  M14 THE EXPLOITATION GUARD - the cross-scoring diagnostic (N7f) and the bench's exploitation index on every run;
     M7's beta tuned by it.
  M15 ONE TRAINING RHYTHM - per iteration: one world-model step (the ensemble), one critic step (imagined
     lambda-returns), one policy step (pathwise + tail + KL on flagged states); the planner every K iterations on a
     small flagged batch. SuperTrack's rhythm plus two light steps. CORE.
  REJECTED: noise on the model's predictions (I1, measured harmful); a learned reward head for tracking (M2 makes
  it worse than exact); MPPI acting for every character (its cost is the whole reason SuperTrack is faster).

**R5.3 The recommended design - "SuperTrack with a pessimistic value tail and a sparse planning teacher".**
  The common case - tracking while near the reference - is learned at SuperTrack's speed by SuperTrack's own
  pathwise loss; the rare hard cases - large pushes, falls, get-ups - get BMPC's long horizon and search, where
  gradients cannot go. Compute stays dominated by SuperTrack's loop: the critic is one more MLP step, the planner
  runs on a few percent of states, acting is one policy pass. Runtime is SuperTrack's.
    world model   the structured model or the latent, by D3; Nf = 4 heads (N7c), trained as SuperTrack trains
                  its one, on data that now includes falls (M8)
    objective     exact and ONE everywhere (R5.8): tracking with non-vanishing gradients (local and global
                  terms), effort (torque-limited PD, mechanical power, the filter), the pose prior over the dance
                  and the get-up capture - no head, no switch
    critic        ensemble of two-hot value heads (BMPC's), on (simulated state, reference context: the next few
                  reference frames, local), targets = lambda-returns over imagined rollouts + real transitions,
                  target networks (Polyak 0.01)
    policy loss   sum over t < N of rho^t x R5.8's cost  +  gamma^N x (mean - beta x sigma) of the critic at the
                  window's end  +  lambda_kl x KL(policy || planner) on flagged states  +  SuperTrack's regulariser
    planner       the N7 actor: MPPI over offsets, policy plans as candidates, ensemble scoring with the known
                  reward and the critic's tail; pessimistic in reanalyze (N7e); run on flagged states only
    gym           reset-free (R5.8): the dance's clock never stops; pushes, drops, far starts; no fall
                  termination
    runtime       the policy alone
  Why this, and not a planner-first agent: BMPC's own strength (search) costs per decision, and its own weakness
  (TD's slow value) is exactly what SuperTrack's dense pathwise gradient replaces; and why not SuperTrack plus a
  critic only (I4's mix): a critic alone cannot discover get-ups either - its gradient is local too; the search is
  what finds the first get-up, and distillation is what keeps it.

**R5.4 Stages - each with known answers and a control** (after N7f; P5 after N9's planner kernels; each a bench
  arm against SuperTrack on the dance first):
  P1 THE VALUE TAIL. The critic (ensemble, two-hot, reference context), its imagined lambda-returns, the policy loss
     gains gamma^N x V(end). KNOWN ANSWERS: V = 0 -> SuperTrack's loss bit for bit; on a toy whose payoff lies past
     the window (a delayed reward), SuperTrack alone fails and the tail solves it; the lambda-returns by hand.
  P2 THE PESSIMISTIC TAIL. mean - beta x sigma over the heads. KA: beta = 0 -> P1 bit for bit; planted
     disagreement turns the gradient away from the disputed state at the beta worked out by hand.
  P3 THE UNIFIED OBJECTIVE AND THE RESET-FREE GYM (R5.8). Every term's shape non-vanishing (L1 / log-cosh), the
     global root and heading terms, the dance's clock that never stops, fallen / far / pushed starts, no fall
     termination. KA: exactly on the dance, the cost is SuperTrack's (the new terms zero); the gradient's magnitude
     three metres away equals the slope worked out by hand (and an exp-shaped control's is zero there); a fallen
     episode's reference advances frame by frame.
  P4 THE BODY'S LIMITS AND THE PRIOR (R5.8). Per-joint torque limits in the simulator's PD (saturating); the PD
     law and its clamp as a differentiable function for the effort term; mechanical power; the pose prior (a
     soft-min over the dance's and the get-up capture's poses, or a learned distance field). KA: a target asking
     more than the limit gets exactly the limit; the power by hand on a two-joint chain; the PD law's torques equal
     the simulator's on a single joint; the prior zero on a database pose (hard-min), within tau x log N (soft).
  P5 THE SPARSE TEACHER. Flags (error, fallen, disagreement), the planner on flagged states in the gym and in
     reanalyze, the KL term. KA: no flagged state -> P4's policy loss bit for bit; a flagged state's target is the
     planner's answer; the share of planned states bounded by the budget.
  P6 THE BENCH, against SuperTrack at equal wall-clock, on the dance: SPEED (time to SuperTrack's precision),
     PRECISION and RECOVERY and FLUIDITY and REALISM by R5.9's judge, ROBUSTNESS (the cube sweep: completion
     against mass) - and PHC's forgetting ablation: precision with and without recovery training (their 59.4% ->
     42.5% when mixed naively), which the balanced replay and SuperTrack's per-iteration tracking windows must hold
     at zero loss.
  Dependencies: Stage D (AccelWorld and its A/B), N7 (ensemble, pessimism, scoring, the actor, reanalyze), N9 (the
  planner's GPU kernels), I3 (TrackEnv, its pushes), I4 (the critic-on-SuperTrack mix is P1's ancestor - P1 replaces
  its model-free critic with imagined lambda-returns).

**R5.5 Risks, ranked.**
  1. Pathwise gradients through contact - exploding or misleading (SHAC, Suh et al.): a shorter window with the tail
     (M11), clipping, the learned model's smoothing; measured by gradient norms per window length.
  2. The critic's bias - overestimation pulls the policy into fantasies: ensembles, pessimism (M7), target
     networks, the exploitation guard (M14).
  3. Inventing a get-up needs the search to find ONE first: fallen starts make it frequent, the hold objective
     makes progress visible (height, up), the planner's horizon plus the tail spans it; a curriculum from slow to
     full gravity if nothing is found (Tao et al. 2022's slow-to-fast curriculum, "Learning to Get Up").
  4. The ring flooded with lying states: a fall budget per character; replay balanced by a near / far flag.
  5. Re-entry discontinuities - a reference that jumps: blend the switch over a few frames; the tracking loss's
     velocity terms see the jump otherwise.
  6. The planner's cost creeping up: the flagged share is a hard budget (a few percent), logged.

**R5.6 Open.** The reference context the critic needs (how many future frames); gamma per DECISION - its credit is
  1 / (1 - gamma) decisions: 0.99 is ~3.3 s at Geno's 30 Hz (decide_every 2), ~1.7 s at the paper's 60 Hz - enough
  for a get-up, or 0.995; whether the critic reads the physical state or a latent; how "back to
  the mocap" is judged (inside SuperTrack's own tolerances for a full second); whether to read PHC's fail-state
  recovery (Luo et al. 2023) and "Learning to Get Up" (Tao et al. 2022) before P3 - both PPO-based, both relevant to
  the objective's design.

**R5.7 PHC studied** (Perpetual Humanoid Control - Luo, Cao, Winkler, Kitani, Xu; ICCV 2023, arXiv 2305.06456v3;
  read Oct 5). WHAT IT IS: one PPO imitator of AMASS (11,313 clips, 98.9% success) that also gets up and walks back
  to its reference - never reset. Reward 0.5 task + 0.5 AMP (a discriminator on the last 10 frames of
  proprioception) + an energy penalty -0.0005 x sum over joints |torque x angular velocity|^2 (it removes the foot
  jitter a policy without external forces otherwise learns). Absolute PD targets, not offsets around the reference
  (robust to noisy references). Recovery: a separate primitive P(F) trained with a POINT-GOAL reward (d_(t-1) - d_t,
  the root's distance) + AMP + energy on walking and running clips; the goal state SWITCHED by the root's distance
  (their eq. 3: within 0.5 m the full imitation goal; beyond, every joint target but the root's replaced by the
  simulated value; the goal clamped at 5 m). Fallen starts: dropped, then random joint torques for 150 steps (after
  ASE); far starts 2-5 m away. Recovery measured as the share back within 5 s and 10 s: 95.0% / 98.8% from fallen,
  83.7% / 99.5% far, 93.4% / 98.8% both. PMCP: progressive primitives on harder and harder subsets, frozen, combined
  by a multiplicative composer - because training recovery in the same network FORGOT imitation (P(F) on imitation:
  42.5% success against P(1)'s 59.4%). Relaxed early termination (ankles and toes excluded). Cost: 1536
  environments, ~10 billion samples, a week on an A100.
  WHAT IT TEACHES US:
  (a) THE SWITCH IS A SYMPTOM. Their imitation reward is a product of exp(-k x error) terms: three metres away its
      position term is exp(-300) - no reward and no gradient - so a second objective must take over far away,
      chosen by a distance threshold. A cost whose gradient does NOT vanish with distance (SuperTrack's L1 losses;
      log-cosh) stays informative everywhere: ONE objective can carry the character from the floor into the dance.
  (b) THE SWITCH COSTS WHAT THEY REPORT: "the humanoid can suddenly jolt and snap into motion imitation", and the
      recovery gait shows AMP's asymmetry. A continuous objective has no moment to snap at.
  (c) FORGETTING IS REAL when recovery shares the network - for us one dance, not 11,313 clips, so capacity binds
      less; the guard is data (the replay balanced near / far) and SuperTrack's per-iteration tracking windows -
      measured (P6), not assumed.
  (d) ENERGY matters for realism even with good tracking (jitter); natural recovery needs a MOTION PRIOR (theirs is
      AMP; ours, R5.8's pose prior - we have the get-up capture and a differentiable pipeline).
  (e) Their fallen-start recipe (drop, then random torques for 150 steps) and their recovery metric (back within
      5 s and 10 s, from fallen / far / both) are adopted as they are.

**R5.8 The unified objective - one cost, one network, no switch** (Simon, Oct 5: "learn the 2 minute dance anim very
  precisely, and at the same time learn to get up and return to it fluidly, realistically ... energy, torque limits
  ... both goals in the same unified system, without discrete decision of if we are currently tracking or
  recovering").
  THE TASK, restated: be IN THE DANCE at time t. The dance's clock runs from the episode's start and never stops,
  rewinds or waits - a fall does not pause the music; recovering IS rejoining the dance where it now is. Per decision:

      cost_t = track(s_t, dance_t) + effort(s_t, a_t) + prior(s_t)

  TRACK - SuperTrack's local terms (positions, velocities, two-axis rotations, angular velocities relative to the
    root; heights; the up vector) PLUS global terms (the root's position and heading against the dance's - R4.2's
    drift terms), every one with a shape whose gradient does not vanish far away: L1 as SuperTrack's, or log-cosh
    (quadratic near zero for precision, linear far away). On the dance it is SuperTrack's loss; on the floor three
    metres away it still says where the dance is and how wrong the body is. OPTIONAL and continuous: the local
    terms' weight 1 / (1 + (d / d0)^2), d the root's distance to the dance's - an A/B against the plain sum (the
    long-horizon value may make it unnecessary); a smooth weight, never a threshold.
  EFFORT - the body's limits: per-joint TORQUE LIMITS in the simulator's PD (saturating - a target asking for more
    gets the limit; strengths per joint set from human data, never above what a person has); the MECHANICAL POWER,
    the sum over joints of |torque x angular velocity| (PHC's energy squares it - an A/B); Simon's 0.2 action
    filter. The torques are a known function of the state and the targets (the PD law and its clamp), so the term
    is differentiable through the world model's predicted states: the pathwise loss sees it.
  PRIOR - natural recovery without a discriminator: a differentiable distance to the manifold of real poses - a
    soft-min over the poses of the dance and of `Motion.getup` (LaFAN's fall-and-get-up, already in the assets), or a
    learned distance field to them (Pose-NDF's idea, Tiwari et al. 2022). Near zero all through the dance (its poses
    are on the manifold); along a recovery it pulls the body through kneeling, pushing up and rising - the poses a
    person uses - rather than any pose the physics allows. AMP's role, differentiable, through the same world model.
  WHY THIS GIVES RECOVERY WITHOUT A SWITCH: a fallen character pays TRACK at every decision until it is back, so the
    discounted objective values a fast, cheap, human return - the VALUE TAIL (P1) carries that beyond the window,
    the PLANNER (P5) finds the first get-ups where the gradient alone does not, EFFORT and PRIOR shape them,
    distillation keeps them. The policy always sees the full reference context and the global relative root
    transform - no masking, no mode bit; it learns where each matters.
  ACTIONS - SuperTrack's offsets around the dance's pose (faster and more precise on the dance - their ablation) or
    PHC's absolute targets (indifferent to where the dance is): an A/B on the bench. Offsets with alpha 120 reach a
    get-up's poses, but around a standing reference they start every get-up from the wrong pose.
  THE GYM, reset-free: episodes start at a random dance frame (most near the reference, a set share perturbed);
    perturbations: pushes (cube impacts of growing mass), drops followed by 150 steps of random torques (PHC's
    fallen starts), far starts (2-5 m, any heading), trips mid-dance; no termination by falling, only by length;
    the replay balanced near / far (R5.5's risk 4). If get-ups are not invented: a curriculum from generous to human
    strength and from slow to full speed, as "Learning to Get Up" (Tao et al. 2022) does - to verify when read; or
    RT10's training wheels (help the policy asks for, mass-proportional on every body, priced, gone on a clock),
    carried to the pathwise loss.

**R5.9 The judge for the north star** (mean time to failure becomes meaningless once a policy recovers):
  PRECISION on the dance from random starts, unperturbed: local and global mean per-joint position error (mm),
    velocity and acceleration errors (PHC's E_vel and E_acc - acceleration exposes jitter), the share of frames
    inside SuperTrack's tolerance (head 25 cm, root 1 m / 90 deg).
  RECOVERY from fallen (dropped, then 150 steps of random torques), far (3 m), fallen-and-far, and mid-dance pushes
    of growing impulse: the share BACK IN THE DANCE - inside the tolerance for a full second - within 5 s and 10 s
    (PHC's Succ-5s and Succ-10s), and how long it takes.
  FLUIDITY: no snap - the peak jerk in the second after re-entry against the dance's own peak jerk.
  REALISM: mean mechanical power; the share of decisions at a torque limit; the prior's distance along recoveries;
    and the morning look, side by side with the get-up capture.

## Ideas to come back to

Kept here, at the end, to be taken up after phase B (Simon, Oct 25: "we will come back to them"). Each is a candidate
for a bench arm, with its own known answer and control when it is built; none is part of the current plan.

**R5.10 Termination at the centre - a brainstorm** (Simon, Oct 25: "SuperTrack is good at quality tracking, PPO and
general RL better at finding imaginative ways back from big perturbations... the termination problem is central";
continued a little every turn). The observation that frames it: TERMINATION IS A CLIFF FOR BOTH LEARNERS, in two
different ways. SuperTrack's pathwise gradient cannot cross it (a reset is not differentiable, so its windows stop at
segment ends and nothing after a fall reaches the policy); EfficientTDMPC's value cannot read it (its targets are
model-based, so a stored flag never reaches them). The retarget arc's lesson (claude.md: "a hard limit is a cliff; a
barrier makes it a slope") applies: give each learner a slope where the cliff is.
  T1 THE AFTERMATH AS A DIAL. The aftermath's length bridges the two regimes: short, the data stays near the reference
     (SuperTrack's resets - tracking quality); long, falls and their aftermath fill the data (reset-free - recoveries).
     Anneal it by the judge's time to failure, or keep a POPULATION of patience - some characters with a short
     aftermath, some with an endless one - in one fleet. Cheap: one option already built (B1b).
  T2 THE FAILURE RULE AS A BARRIER for SuperTrack. Its known, differentiable loss gains a soft barrier on the failure
     rule's own margins - softplus((head height error - 0.25 m) / width), the same for the root's 1 m and 1.57 rad -
     so the pathwise gradient pushes away from the cliff before reaching it. The rule is already a function of the
     state; the barrier only makes its edge a slope. Candidate for SuperTrack's next bench arm.
  T3 THE MODEL ON EVERYTHING, THE PATHWISE LOSS ON WHAT IT CAN USE. The world model trains on every window, aftermaths
     included (how a body falls is knowledge); SuperTrack's pathwise policy loss samples windows that start before a
     loss (through a fall its tracking gradients saturate to nothing); the value tail (R5.2 M1) carries the
     aftermath's lesson to the policy. Separates what each learner is good at by WHICH WINDOWS feed it.
  T4 THE GATE'S SLOPE IS A GET-UP SIGNAL - TO MEASURE. Geno's gravity gate never reaches zero: lying flat and 0.8 m
     low keeps about 0.1% of the reward (2% for the height times 6% for the tilt), sitting up (0.4 m low, upright)
     about 13%. Over a value's horizon (1 / (1 - 0.983) = 60 decisions) that is about 0.06 against 7.8 - a difference
     a two-hot value can see, and a planner can climb. Measure it on B1c's data once the value trains: V(lying)
     against V(kneeling).
  T5 HINDSIGHT REFERENCES (weird). For the world model's and the value's training only, relabel an aftermath window's
     reference with a frame near where the body actually is (motion matching, or a get-up clip's frame): the fall
     becomes tracking of something reachable, and the data teaches recovery-shaped values. Risk: values of fallen
     states then read optimistic for the real task - needs its own control.
  T6 A LEARNED HAZARD, SHARED (weird). A small head predicting "the reference is lost within k steps" from the latent
     (trained on the aftermath-free part of the data - it is a classifier, not a terminal): used as a soft discount in
     the planner (Puppeteer's soft cut, but of a hazard, not of a terminal) AND, through the world model, as a learned
     barrier in SuperTrack's pathwise loss - one learned cliff-edge both learners feel.
  T7 A CONTINUOUS BLEND, NO SWITCH. One policy whose correction grows with the hazard: pi = pi_track + h(s) x
     delta_recover, h from T6 - SuperTrack's quality where the hazard is low, the planner-taught recovery where it is
     high, with nothing discrete (the north star's "no switch").
  T8 ONE GYM, TWO STUDENTS. A fleet records whole physics states (`Fleet.replay`: positions, velocities, the action,
     the reference frame), not a learner's features - so the same rows can be featurised for either learner: DReCon's
     observation for EfficientTDMPC, SuperTrack's features for SuperTrack. Both world models then train on ONE stream of
     experience, each off-policy on the other's actions. The planner's recoveries become SuperTrack's data; SuperTrack's
     precise tracking becomes the planner's. The question it raises: whose actions the fleet acts on, and in what
     share (a population again, as T1).
  T9 PLANNED EXPLORATION FOR SUPERTRACK. SuperTrack explores with Gaussian noise on its offsets (sigma 0.1), which
     never finds a stepping recovery (its own sec. 8). Where the hazard is high (T6) or the character is in an
     aftermath, act on EfficientTDMPC's planner instead of the noise: exploration that searches, only where search
     is needed. SuperTrack's world model learns the recoveries the planner found; its pathwise policy learns them
     once its model can predict them.
  T10 THE VALUE AS A JUDGE OF SUPERTRACK. EfficientTDMPC's value, trained on SuperTrack's own data, predicts where
     SuperTrack's policy is about to lose the reference - before the failure rule fires. A view for the lab (the
     value along a watched run) and a measure of how much warning there is: the time between the value's drop and the
     loss is the time a recovery has.
  T11 FEW PLANNERS, MANY ACTORS. The acting planner is the cost (B1c measured it: 3 s a decision on the CPU at small
     widths). Let only a few characters plan - the ones the hazard (T6) flags, or a fixed share - and the rest act on
     the policy with noise, as SuperTrack's characters do. Reanalyze keeps the policy's targets fresh for every stored
     state either way; the planners supply the data the policy cannot find. SuperTrack's cheap collection and
     EfficientTDMPC's search in one fleet - T1's population idea once more, with the planner as what differs.
  T12 SUPERTRACK AS THE PLANNER'S PRIOR. EfficientTDMPC's planner seeds part of its search from its own policy (24 of
     512 candidates are the policy's plans). Distil a trained SuperTrack policy into that policy before EfficientTDMPC
     starts - behaviour cloning onto the latent policy, through the encoder - so that the planner's first plans already
     track with SuperTrack's quality, and its search spends itself on what SuperTrack cannot do: the recoveries. The
     planner then improves on a strong prior instead of discovering tracking from random actions; the distilled policy
     keeps learning from the planner's answers as usual. Needs only a SuperTrack policy file and DReCon's observation
     for both (the player now runs EfficientTDMPC's normed layers, so the two policies can be compared on one state).
  T13 THE LATENT'S OWN DOUBT (weird). The encoder ends in SimNorm: the latent state is 64 groups of 8 soft choices.
     Where the encoder has seen many states like this one, its groups tend to commit (low entropy); far from its data
     they spread out. The mean group entropy is then a free novelty signal - no ensemble, no extra head - computed by
     the player itself. A cheap hazard (T6) to compare with the dynamics heads' disagreement, and a view for the lab:
     where on the dance the agent is out of its depth.
  T14 THE SPREAD THE FILE DROPS. The policy file keeps the head's centres and drops its spreads. But the spread is
     what the planner taught about its own certainty: the policy imitates the planner's action distribution, so where
     the planner's elites disagreed, the policy's spread is wide. Kept as a second output, it is a per-state
     confidence the player gets for free: a view for the show (where the policy is unsure), and a blend weight for
     T7 - SuperTrack's action where EfficientTDMPC's policy is unsure, its own where it is sure, or the reverse where
     the hazard is high. One more layer of A outputs in the file, unused by the controller.
  T15 ONE KIT, BOTH LEARNERS. SuperTrack runs on the kit's fused kernels (`st_world_fwd`, `st_policy_bwd`, ...);
     EfficientTDMPC will run on the same kit's per-layer kernels. Once the normed layer is in the kit, SuperTrack's
     world model and policy could be built of it too - the same normed Mish layers TD-MPC2 found stable - and the two
     learners would share not only a fleet (T8) but a vocabulary of layers: a SuperTrack policy distilled into
     EfficientTDMPC's (T12) would then be a copy of weights, not a fit.
  T17 THE NORM AS A HAZARD SENSOR (weird). `norm_fwd` keeps each row's inverse spread for the backward. For the
     encoder's first layer that number is how spread out the observation's projection is - and a character in a
     state unlike its training data tends to project with an unusual spread. The inverse spreads are already in the
     activation buffer, per character, every decision: watching them costs nothing. Compare with T13's SimNorm entropy
     and the heads' disagreement; the cheapest of the three that predicts a loss could feed T6/T7.
  T18 THE COUPLINGS AS AN ATTENTION SIGNAL (weird). `norm_bwd`'s two couplings - mean(dn) and mean(dn n) - say, for
     each row, how much of the gradient is spent moving the row's mean and spread rather than its pattern. In the
     encoder they measure how much learning a state's observation asks for "everything shifted" versus "something
     specific changed". A row whose couplings dominate is a state the encoder sees as globally unlike the others - a
     fall in progress, say. A diagnostic for free in the backward, another hazard candidate for T6.
  T19 THE TWO-HOT'S WIDTH AS A CONFIDENCE (from C1c). The reward and value heads are distributions over 101 bins,
     read back as their mean only. Their spread is a per-state uncertainty the agent computes anyway - one head's,
     where pessimism's comes from the ensemble's disagreement. If the two agree on the dance, the single head's width
     is the cheaper hazard (T6), and a SuperTrack critic (R5.2's value tail) could carry it as well.
  SCHEDULED (Oct 26): T20 in C2's known answers; T11 as C3's `planning_characters`; T13, T17, T19 read at C4; T4, T6,
  T10, T13, T17, T19 in D2's signal view; T1, T2, T3 as the second night's candidates (E1). The rest wait for the
  merge (R5.4), which this list now argues for in order: T8 (one gym, two students) first - it needs only the
  featurisers both learners have - then T9 and T12 (the planner exploring for SuperTrack, SuperTrack as the planner's
  prior), then T7 (the continuous blend).
  T32 NOISE PERSISTENCE AS COMMITMENT (from phase G). A flow actor's noise chooses which way back; fresh noise every
     decision lets the choice flip and the action filter average the flips. Hold one noise per character while it
     recovers - sampled when the hazard (T6) spikes, released when it settles - and let it drift slowly otherwise: a
     strategy chosen once and carried through.
  T33 PLANNING IN NOISE SPACE (weird; DSRL's idea, EfficientTDMPC's machinery). With a flow actor, the planner need
     not search raw actions: let its candidates be NOISE vectors, each turned into an action by the flow. Every
     candidate is then a feasible, in-distribution action, and the search ranges over strategies - step left, step
     right - rather than over jitter around one. MPPI's elites would pick the noise, and T32 would hold it.
  T34 THE FLOW ACTOR AS THE MERGE'S MEETING POINT (from phase G). FlowDPG adds any teacher's action-gradient
     correction to one flow target; FPO adds advantages. SuperTrack's pathwise gradient, EfficientTDMPC's model Q
     gradient and PPO's advantages can then train ONE actor, each where it is trusted - a concrete form of R5's merge
     and of T7's continuous blend.
  Verdicts so far: T1 and T4 are free (built or measurable in phase B); T2 and T3 are the cheapest SuperTrack-side
  arms; T8 needs only the featurisers both learners already have; T5 to T7 and T9 wait for the merge (R5.4); T10 for
  a trained value. Next turns add to this list as the code teaches.
