# rl_track_plan.md - v4 (Sep 27, 2026, evening): SuperTrack on the 10-second dance - fundamentals, the bench, the night

v4 replaces v3 (archived as `src/notes/archive/rl_track_plan_v3.md` - every step's full design and measurement up to
Sep 27, the MimicKit table, Phase R's workflow study). v2 and v1 are archived beside it; `rl_track_journal.md` is the
dated history; `supertrack_comparison.md` tables the paper, an unofficial implementation and ours. What v4 changes:
the finished work is summarised (§4), and what remains is ordered by what everything else stands on - the action path,
then a BENCH that turns every remaining choice into a measured A/B (v3 had no such tool before its last step), then
the recipe decisions, the world model's form, scale, the kit's parity, a gate, and the night.

---

## 0. Standing rules (every turn)

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
- Never the full `gate` per turn; targeted tests (`zn-<stem>`, by name), then `check`. Pages in `release`, never `ship`.

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

**North star.** One Geno policy tracks ~100 LaFAN clips - dances, locomotion, falls and get-ups, unnamed - from
random starts, robust to pushes; trained unattended overnight on a desktop GPU in a browser page; later on the phone.

**The FIRST night - the 10-second dance only.** After <= 10 h, ONE SuperTrack policy on `Motion.dance_5_15`, judged
by the judge (mean action, 20 starts every 0.5 s, the task's rule):
- mean time to failure >= 8 s (5x the servo alone's 1.53 s);
- >= 60% of the 20 starts reach the clip's end (the servo alone: 1 of 20);
- mean gated reward above the servo's (0.499); the exploitation index bounded all night;
- visible in the morning: Geno dancing the ten seconds.

**Later nights (Phase C):** the whole dance (>= 80% of episodes past 10 s), the whole get-up (>= 50% of pre-rise
starts reach standing), reward above the servo's on both, then the clip library. Failure is information: the
morning protocol says what to look at.

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

## 3. Where we stand (Sep 27 evening)

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
behaviour): `WorldOptions.normalize_from_clips` (F4a), `decide_every` (F4e), `filter` (F6a) - the recipe sets
true / 2 / 0.2. `decideInto` is the one definition of a decision; `appliedBefore` gives a window its filter state.

**3.6 The GPU learner** (`robot_latent_kit` + `robot_track_resident`, page `geno_train`): parity-tested against the
CPU learner at its DEFAULTS; uses the clip normaliser (F4a); still acts every step with no filter - it lags the
recipe (Stage G).

**3.7 PPO / DReCon and the teacher** - unchanged since v3 (archive §3.5): PPO on the kit with a CPU twin, GAE with
bootstrapped cuts, DReCon's controller (now on `filterAction`); the MPPI teacher (`Planner`, `d5_teacher`) with its
early warning `teacher_warning` / `teacher_danger` (T4b).

**3.8 Pages** - `geno_track` (servo viewer), `geno_ppo` (PPO), `geno_train` (SuperTrack): smokes green and leak-free
(Sep 27 review).

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
- **F3 velocity feedforward - dropped** (+1% survival; the option stays, off; its end-of-clip velocity fixed in the review).
- **F3b SuperTrack's failure rule - adopted** (equally strict as our five limits; simpler; the paper's).
- **F3c 240 Hz physics - dropped** (Simon: 60 Hz physics, 30 Hz policy).
- **F4a the normaliser from the clips**; **F4e the 30 Hz clock (CPU)**; **F6a Simon's filter inside training (CPU)**.
- **Review (Sep 27)**: `geno_track` compiled again; feedforward's end-of-clip velocity; the learner refuses a filter
  outside (0, 1] or a clock under 1; the tutorial caught up (normaliser, clock, filter); every page smoked.

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

---

## 6. The work ahead - fundamentals first

Each step: WHY - DESIGN - KNOWN ANSWER - DONE WHEN - SIZE (turns). CPU first; the kit follows what is adopted.

### Stage A - finish the action path (CPU)

**A1 The policy sees what it is applying** (v3's F6b).
- WHY: with the filter, what to ask depends on what is already being applied; DReCon's observation carries it.
  Without it the policy is blind to half of its own control state.
- DESIGN: `LearnerOptions.sees_applied` (default false). The policy's first layer gains a block `W_applied` (actions x
  hidden); its input is the action being applied BEFORE the decision - the slot's value in `decideInto` (rest at an
  episode's start), the `applied` Var entering the decision in the graph, the filter state in `modelLoss` and
  `diagnose`. The CPU parameter layout grows only when the option is on, so the kit's parity at defaults is untouched.
- KNOWN ANSWERS: with `W_applied` zero, outputs are bit-identical to the policy without it; the graph-vs-rows parity
  (F6a's test) with the option on; the judge's actor feeds the slot's value (a unit check with a planted slot).
- DONE WHEN: robot_latent green, both parities. SIZE: 1.

**A2 The recipe as one value.** `robot_geno.supertrack_recipe: robot_latent.LearnerOptions` (normalise from clips,
decide every 2, filter 0.2, sees applied, `supertrack_action_scale`, sigma) - the bench, the pages and the night
read it; a test checks each field against the plan's intent. SIZE: with A1.

### Stage B - the bench (from v3's F10, moved to the front: every later choice is a learning-curve question)

**B1 `zig build st-bench`** - a deterministic CPU SuperTrack run on `dance_5_15` with the recipe.
- DESIGN: a small host tool (`tools/st_bench.zig`) over the CPU learner: 8 characters, a replay of >= 30 s in total,
  batch and windows at CPU sizes (hidden 64-128, batch 32-64); each iteration collects a few steps, then one world
  step and one policy step (SuperTrack's rhythm). At iteration 0 and every M iterations: the judge (20 starts) and
  `diagnose` (trust, exploitation) -> one CSV row (iteration, wall seconds, samples, world loss, policy loss, MTTF,
  share to the end, reward, trust, exploitation). Options: minutes, seed, recipe overrides (for A/Bs), output path.
- KNOWN ANSWERS: the same seed gives the same CSV (wall time aside); iteration 0's judge row is the untrained policy's
  (near the servo's, since the policy starts near zero); the iteration rate is reported.
- DONE WHEN: a 10-minute run writes its CSV and the curve is shown. SIZE: 1-2.

**B2 The baseline curve** - today's recipe (latent, MSE, 0.6 rad, sigma 0.1) for 30 minutes. The first learning
signal on this dance: does MTTF rise above 1.53 s? Every later A/B is against this curve. If it does not rise at
all: stop, and read trust and exploitation to learn which half fails, before touching the recipe. SIZE: 1.

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
- `src/robot_geno.zig` - Geno: `tracking_task`, `servo_task`, `task_termination`, `task_weights`, `ServoRun`,
  `Planner` (the teacher), `FailureCheck`, `GenoTask` / `Motion`, the T/F measurements.
- `src/robot_policy.zig` (DReCon: `Controller`, `observe`), `src/robot_ppo_track.zig` (PPO), `src/robot_gym.zig`.
- Notes: this plan; `rl_track_journal.md`; `supertrack_comparison.md`; `claude.md`; `archive/rl_track_plan_v1-3.md`.
- Tutorial: `src/notes/tutorials/robot-mocap-tutorial.html` (sections 10-12).
