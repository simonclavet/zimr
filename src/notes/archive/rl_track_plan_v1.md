> **ARCHIVED Sep 23 2026 - superseded by `src/notes/rl_track_plan.md` (v2).** Kept verbatim and not
> maintained: the design, the rungs T1-T9b and Phase R's first steps, with every number they measured.

# rl_track_plan.md — DReCon, SuperTrack and their relatives, reproduced, resident on the GPU

**Status: ACTIVE from Sep 20 2026. T1-T6c done, T6d next.** This is the forward plan only: what we
build, in what order, and how each step proves itself. What happened and what we learned lives in
`rl_track_journal.md` (the previous plan, verbatim, plus one dated entry per turn from now on).

**T-numbers are RUNGS, not turns.** T1-T6c took about fifteen turns, two of them adversarial
reviews that paid for themselves and one of them the floor bug. A rung is done when its known
answer holds; how many turns that costs is a fact to record, not a budget to defend.

---

## 0. Standing rules (every turn)

1. **One known answer per rung.** A step is done when a test compares it with something we already
   know to be true: the CPU implementation, an analytic result, a conservation law, a published
   number. "It trains" is not a known answer.
2. **Every GPU kernel has a CPU twin.** The kit's kernels are Zig that runs on the CPU backend too,
   so parity tests run headless and native. GPU-vs-twin differences are float noise; anything more
   is a bug in the host code, not the math.
3. **Targeted tests every turn; the full gate at the end of each phase** (T2, T8, T13, T19, T25,
   T30) - not every turn.
4. **The tutorial stays in sync, every turn.** Code blocks are generated (`zig build doc-folds`,
   also in the gate); the prose of every chapter a turn touches is updated in that turn; new
   methods get new chapters (map in §8). Present the tutorial when it changes.
5. **Comments casual and verbose**: what it does, why it's built that way, what goes wrong
   otherwise. No development history in code or tutorial - that goes in the journal.
6. **Each turn ends with**: targeted tests green, tutorial in sync, a journal entry, a snapshot.
7. **A measurement is only as good as the world it was made in.** Before trusting a number about
   the character, check that the character is in the world you think it is: standing on the floor,
   colliding, driven by the servo you meant. The floor bug cost three turns of measurements
   because nothing checked the premise, only the conclusions - so every environment now has a
   standing guard (no actions, 30 frames, must still be on the floor), and any new environment
   gets one before it gets a learner.
9. **Pages are built in `release`** (ReleaseSmall with zimr's own asserts), never `ship`: a failure
   on a device should name itself, not trap anonymously. (Simon, Sep 21.)
10. **A page passes `zig build smoke-test -Dfocus=<page>` before it reaches a device** - in both
    debug and release. It loads the wasm in Node with the GPU and DOM stubbed, ticks 60 frames, and
    audits every import, GPU resource and allocation. It found both of the first phone crash's
    bugs in seconds; running it first would have spared the round trip.
8. **Every experiment carries a control.** The oracle beside the world model, the servo beside the
   planner, the walk beside the get-up. A disappointing number means nothing on its own: the
   control says whether the method is wrong or the task is hard.

---

## 1. The goal, stated so it can fail

**THE NORTH STAR (Simon, Sep 21).** On Simon's phone, in the browser: the get-up environment trains
**from scratch** - its characters stepped on the phone's CPU, its networks trained on the phone's
GPU - and the page **downloads the weights to a file** on request and **accepts an uploaded weights
file** to carry on from, or to watch. Weights come only from runs on his phone: nothing trained on
this side is ever shipped in a page, an asset or a snapshot.

**The metric that follows from it is wall-clock time to the bar on his phone**, and the sample
count beside it. PPO from scratch will take hours; the aim is minutes. Every method in §2 earns its
place by the minutes it removes on that bench - measured there, against the PPO baseline, on the
same page. That is the question the whole plan now answers.

**Track four clips, well, under small perturbations** - on `humanoid_flex2` (nq 48, nv 41), with a
**SuperTrack + SAC + MPC hybrid**, everything resident on the GPU. The clips, retargeted and
audited (`assets/lafan1/`, the "reference set" test):

    walk1_subject2        20 s   walking, turning, stopping
    run1_subject2         20 s   running, with turns
    dance2_subject2       20 s   dancing
    fallAndGetUp2_subject2 18 s  standing, falling, lying down, getting up

| goal | passes when |
|---|---|
| **G1 quality** | each clip tracked for its whole length with no fall: **mean body position error < 6 cm and mean body rotation error < 8 deg** (per frame, over all 18 bodies, after the first 0.5 s), on the real simulator with the policy's mean action |
| **G2 perturbations** | with a random shove every 2 s - 50-150 N for 0.15 s on the torso, random direction - **no fall in 20 consecutive runs of each clip**, and the error back under G1's bound within 1 s of each shove |
| **G3 the hybrid earns its parts** | measured on the same task and budget, against the PPO baseline (T7): SuperTrack alone, + the critic beyond the window, + MPC at runtime. Each part stays only if it improves G1 or G2 |
| **G4 cost** | the trained controller runs a frame in **under 4 ms on a desktop and under 16 ms on the phone**, MPC included, with every buffer resident |

The get-up is the hard one and it is in the set on purpose: it goes to ground, so contacts happen
on hands, forearms, pelvis and back as well as feet (all 18 bodies carry collision geometry, so all
of that is representable), and the "has it fallen?" test cannot be a height threshold - both
settled in T4. Its reference used to sit 10 cm inside the floor; D8's per-frame lift puts the
typical frame ON the floor with the deepest frame clear of it. DReCon's own conclusion calls
getting up off the floor unsolved, which is part of why it is here.

## 2. The methods, and how they fit together

The survey (Bao et al. 2024, arXiv 2404.17070) sorts learned locomotion into **end-to-end**
schemes - *residual* (the policy offsets a reference's joint targets), *guided* (the policy is
rewarded for imitating a reference), *reference-free* - and **hierarchical** ones, where a planner
sits above a learned controller. Everything below is residual: the reference is a clip, the policy
offsets its PD targets, and what differs is where the learning signal comes from.

| part | what it contributes | why it is in the mix |
|---|---|---|
| **SuperTrack** (Fussell 2021) - a world model learned by supervision, the policy trained by backpropagating a tracking loss through it | the fast, dense learner: gradients that know how the dynamics respond, not just whether a try went well | it is the backbone. Proven here on the cartpole; an order of magnitude fewer samples than PPO on DReCon's own comparison |
| **A critic** (SAC / CrossQ targets on the replay) | value BEYOND the policy's 32-frame window | SuperTrack's own stated blind spot: inside the window it is exact, past it, nothing. A recovery that pays off in a second and a half is invisible to it |
| **MPC** (MPPI over the learned world model, short horizon, warm-started from the policy) | search where no gradient leads: a recovery step, a hand placed to push off the floor | perturbations put the body off the policy's distribution, which is exactly where planning beats a policy - and the world model makes rollouts cheap |
| **PPO on a residual policy** (DReCon's RL half, DeepMimic's ancestor) | the baseline every part of the hybrid is measured against, and the shortest path to a first tracking result | **early, at T7**: model-free, so it needs nothing that is still being measured, and a policy that survives makes every later rung cheaper |
| (AMP, motion matching, DReCon's kinematic half) | extra methods and the interactive layer | later: §6 Phase F |

That combination is TD-MPC2's shape - a learned model, a planner, a value, a policy prior - with
SuperTrack's supervised world model and BPTT policy in place of its latent-space RL, and with a
differentiable SIMULATOR available beside the learned model (§6 Phase E).

**The ladder from hours to minutes** - modern methods mapped onto the pieces already built, cheapest
first, each kept only if the bench says it saves time:

| rung | what it buys | the modern reference |
|---|---|---|
| observation normalisation, mirror symmetry | the two cheapest known wins: well-scaled inputs, and every episode doubled by reflecting it (the physics is symmetric; the reference is mirrored with it) | standard practice in the DeepMimic / AMP line |
| **the policy trained through the world model** | gradients instead of trial and error: SuperTrack's whole claim - an 8-frame window is what T6d's drift curve licenses | SuperTrack (Fussell 2021); Dreamer-style imagination |
| **SAC at a high update-to-data ratio** | many gradient steps per sample, made stable by normalised critics and dropout or batch-norm, without target networks | DroQ, CrossQ, SimBa / BRO (2022-2024) |
| **the world model + critic + MPPI at runtime** | planning through the learned model with the policy as its prior and the critic past the horizon - better actions, so better data, so fewer samples | TD-MPC2 (Hansen 2024) - the plan's hybrid, named |
| **the environment on the GPU** | throughput: hundreds of characters where the CPU steps sixteen | Isaac Gym / Brax / MJX |

**THE BEST PATH TO MINUTES (Sep 21 review, after the first phone run).** The phone's economics
decide the method. Simulated samples are the SCARCE resource - CPU-bound, about 3,000 physics steps
a second on Simon's phone (8 characters, 3 decisions a frame) - while batched network work on its
GPU is comparatively plentiful. So the winner is whichever method extracts the most learning from
each simulated sample, paid for in GPU compute. The evidence, checked rather than remembered:

  * **Gradients through a differentiable model beat policy gradients by an order of magnitude.**
    DiffMimic (Ren et al., ICLR 2023) learns a backflip in 10 minutes where DeepMimic needs about a
    day, with ~90% fewer samples - and names the risk of doing it through a LEARNED model: error
    accumulation, exactly our T6d finding (61 mm at 8 steps, 1.42 m at 32). Its answer,
    Demonstration Replay, anchors rollouts on reference states so gradients stay meaningful.
  * **Short horizons plus a critic.** SHAC (Xu et al., ICLR 2022) takes gradients through the
    dynamics over a short window and lets a critic absorb the non-smooth distant future: 17x
    faster than PPO in wall clock on a muscle-driven humanoid. **Our world model is trustworthy for
    8 steps - that is SHAC's shape exactly.** A learned model is also SMOOTH by construction, which
    sidesteps the biased gradients at stiff contacts that trouble true differentiable simulators
    (AHAC, 2024).
  * **The critic, cheaply.** CrossQ (Bhatt et al., ICLR 2024) matches the high update-to-data
    methods at a ratio of 1 - twenty times fewer gradient steps, ~4x faster in wall clock - by
    dropping target networks and batch-normalising the critic. On a phone GPU, compute per sample
    matters as much as samples, so this is the right critic. SimBa's normalisation and residual
    blocks help SAC, PPO and TD-MPC2 alike.
  * **For a get-up specifically:** residual force control (Yuan & Kitani 2020) adds a root wrench
    to the action space so a hard, contact-rich motion is learnable at all, and a curriculum anneals
    it to zero (Skeleton2Humanoid 2022) so the final policy stands on its own.

**So the method is: SuperTrack's world model as the differentiable simulator, SHAC's critic
beyond an 8-frame window, rollouts anchored on real recorded states (DiffMimic), a CrossQ-style
critic, an annealed root assist, normalised observations - measured on the phone against PPO.**
Throughput (the GPU environment) comes AFTER, when the sample rate is the limit: it multiplies a
good method, it does not rescue a wasteful one. Runtime MPC serves robustness (G2), not training
speed.

**DReCon splits in two, and the halves sit at opposite ends.** Its RL half - a feedback policy that
offsets a reference's PD targets, trained by PPO - is at T7, because it is the cheapest honest
tracking result available and everything else is measured against it. Its kinematic half, motion
matching, is the interactive layer a player steers; it needs a tracker underneath that works, so it
waits for Phase F.

## 3. What exists (verified Sep 20)

**Works, with its known answer on file (journal):**
- `robot.zig` reduced-coordinate dynamics on the CPU (FK, RNEA, CRBA, soft-constraint contacts
  with PGS by default); `humanoid_flex2` is nq 48 / nv 41 since D1 (both elbows ranged hinges).
- Retargeting onto flex2 of the dance and of the **tracking set** - walk, run, dance2, fall-and-get-up
  (`assets/lafan1/`, 4.9-5.9 cm mean IK residual, no range excess, no sign flips, no jump past
  0.15 rad); `auditClip` / `ClipAudit` and `lowestBodyPoint` measure all of that; `Clip.smoothed`
  (5 Hz, velocity space); grounding. A capture and its rest pose must be the same skeleton - stated
  now, and checked.
- `Tracker` + inverse dynamics: the fixed-base dance followed to 0.03° mean / 0.09° worst (after
  the v_prev fix); free root with no help falls in ~0.67 s.
- `contactTorques` / `contactConsistentTorques` (CPU, dense).
- `HumanoidEnv` (CPU; robot.zig dynamics, contacts through a zimrphysics bridge; 60 Hz physics,
  30 Hz policy).
- PPO and SAC on zimrnum graphs (CPU) and on the zn_mlp kit (`GpuPpoOn`, `GpuSacOn`), with
  parity; SuperTrack on the cartpole (CPU graph and the kit, per-layer and fused; holds the pole
  through every push after ~3k iterations).
- **The task** (`src/robot_track.zig`): `TrackingError` / `reward` / `Termination` / `resetToFrame`,
  the servo with an authority limit, `liftPerFrame`, `Replay` (rings with segment ids, records
  carrying their clip) and `Fleet` (characters stepping together on a floor, observe-act-step).
- **The world model** (`src/robot_world.zig`): features, `measureDrift` with its oracle and
  baseline, `WorldModel`, and an MPPI `Planner` that can also roll the real simulator for control.
- **A network on the kit** (`src/kit_mlp.zig`): layer sizes in, forward, an MSE-and-Adam step, the
  weights out - gradients checked against finite differences, parameters checked against the kit's
  buffer size.
- compute_host: one submission per recorded update, `uploadAt`, prefix readback, CPU twin.
- The maximal ragdoll (hinges only; built at rest, then posed).
- The tutorial, with generated code and a generated reference.

**Does not exist yet:** any trained humanoid policy; GPU physics and GPU contacts; per-world RNG,
resets and episodes on the GPU; observation and reward kernels; GPU rollouts and GAE; locomotion
data; motion matching; the AMP discriminator; the simulator's gradients; adjoints through the
integration (which T6c says the world model does not need, subject to T6d).

**The fact that cost the most to learn, kept here so it cannot be forgotten:** in this engine the
articulated-body dynamics (`robot.zig`) and collision (`zimrphysics`) are SEPARATE, joined by a
`robot_physics.Bridge` - poses out, contacts back. A floor geom in a model's text collides with
nothing until somebody builds that world and syncs it each step. An environment without the bridge
runs happily in mid-air and looks busy the whole time.

**Retarget quality to revisit:** with either elbow the arm is 14-16° off the capture on average -
flex2 rests with its elbows bent 109.5° while the capture's stance arm is nearly straight, and the rest
poses are paired as if they were the same. A matched rest (or a solved robot rest) is the likely fix.

---

## 4. The architecture, resident

**State: structure-of-arrays over W worlds, in storage buffers.** `pos[W×51]`, `vel[W×43]`, body
poses `[W×18×7]`, `cvel [W×18×6]`, bias `[W×43]`, mass matrix + its Cholesky factor `[W×43×43]`,
contacts `[W×16×…]`, PD targets, per-world RNG state, episode bookkeeping (clip cursor, step,
return). The model (tree, joint types, axes, offsets, inertias, ranges, geoms) is one read-only
buffer shared by all worlds. Reference clips live on the GPU as `[frames×51]` per clip.

**Granularity: one thread per world for the tree recursions** (FK, RNEA, CRBA are serial over 18
bodies but parallel over worlds); a workgroup per world only where measurement says it pays (the
43×43 Cholesky, the contact solve) - decided in T7 (D3).

**One control step = one recorded submission:**

    1  policy forward over all W observations (kit dense kernels); sample a ~ N(mu, sigma) from
       per-world RNG; log-probs
    2  PD targets = reference (+) offsets  (hinges add, balls compose, root unactuated)
    3  physics x2 substeps (120 Hz): FK -> velocities -> bias -> stable-PD torques -> contacts
       (capsule/sphere vs plane, <= 16 points) -> PGS, fixed iterations -> integrate
    4  observation, reward, termination, reset-with-RSI kernels
    5  write the rollout row (PPO) or the replay row with its segment id (SuperTrack / SAC)

**Learners on the same buffers:** PPO (rollout W×T, GAE kernel, a permutation buffer for
minibatches, the kit's update); SuperTrack (per-world replay rings with segment ids; world model and
policy as per-layer kit kernels - the fused per-row kernels suit the cartpole's tiny nets, not
1k-wide MLPs); SAC/CrossQ critics on the same replay.

**The CPU:** input to a uniform, AIMD budgets, a few scalars read back a frame late. **Rendering
reads the body-pose buffer directly** (instanced capsules in the vertex shader), so displaying
4,096 characters costs no readback at all.

**Hard limits we design within:** f32 only; WGSL's per-stage storage-buffer bindings (the kit's
flat buffers + offsets pattern); `maxStorageBufferBindingSize` (128 MB default - 4,096 worlds ×
43×43 f32 = 30 MB, fine); no float atomics (reductions are two-pass kernels).

---

## 5. The arithmetic

**Cost of one world-step (flex2, estimated; measured in T15):** FK ~5k flops, RNEA ~15k, CRBA ~20k,
Cholesky ~13k, contacts + 20 PGS sweeps ~100k, integration ~2k: **~0.15 MFLOP**, ×2 substeps. At
4,096 worlds that is ~1.2 GFLOP a control step. A desktop GPU running this serial-per-thread code at
an effective 0.5-1 TFLOPS: **1-2.5 ms a control step → 1.5-4M samples/s, upper bound**; a phone
~50× less → **30-80k/s**. The target in §1 leaves a 10× margin for everything the estimate forgets.

**Samples each method needs (literature):** DeepMimic 60-200M per skill; DReCon ~300M (30 h on
their CPU cluster); SuperTrack an order of magnitude fewer than DReCon (its own claim, measured
against DReCon); AMP comparable to DeepMimic. Ours starts from an exact servo (the policy learns the
balance correction, not the motion), so G1 should need fewer - **T7a measures our end of it**
(env-steps per second on the CPU fleet) and T7b measures the samples a short clip actually takes.

**What that buys:** 100M samples at 1M/s is under 2 minutes on a desktop; at 30k/s, ~55 minutes on
the phone. **Throughput stops being the constraint; the constraint becomes getting each piece
right** - which is what §0.1 is for.

---

## 6. The schedule

**The order is chosen for speed to a tracking result**, not for tidiness: every piece that can be
got right on the machine we already have (CPU simulation, GPU training on the kit) comes before
the GPU simulator, because those pieces are cheap to iterate and they decide whether the method
works at all. The GPU simulator then multiplies the throughput of everything that follows - the
hybrid's ablations, four clips, perturbation curricula - by a factor the arithmetic in §5 puts
near fifty.

**The first tracking result is T7**, deliberately placed before the expensive phases: a project
that can track one clip has something to measure everything else against, and one that cannot does
not yet know whether any of this works.

Each turn: **one deliverable, its known answer, the tutorial chapter it touches.**

### Phase A — The reference set and the task (T1-T4)

**T1 — DONE.** The four clips retargeted and audited (residual 4.9-5.9 cm mean, no range excess,
no sign flips, no jump past 0.15 rad); `auditClip` and `lowestBodyPoint` public; D1 taken (both
elbows ranged hinges); `tools/lafan_db.zig` and the bvh-trim drop option.

**T2 — DONE. The reference, as a tracker sees it (W1.1b-c).** `src/robot_track.zig`: `State`,
`local` (root-relative positions, two-axis rotations, velocities, angular velocities, world heights,
up), `twoAxis` / `fromTwoAxis`, `integrate`, `accelerationsBetween`. Measured: `local` changes by
**1.1e-6** under a yaw and a 10 m walk while a 25 cm lift or a 0.3 rad tilt changes it by **0.21**
(the controls); two axes round trip within **1e-6**; the integrator fed the simulator's own
accelerations reproduces its next state with velocities exact (6e-8) and positions **54 um mean at
60 Hz, 15 um at 120** - the O(dt^2) an explicit step is allowed. Tutorial §11.5.

**T3 — DONE. Actions and the servo (W1.2).** `actionSize` (35 on flex2: one per hinge, three per
ball, none for the root), `applyAction` (a displacement in velocity space, applied by
`integratePos` so hinges add and balls compose on the right), `clampHinges`, `Gains`, `pdTorques`.
Measured: a zero action reproduces the reference EXACTLY (same numbers, not close); a bounded
action moves the worst body 0.425 m at 0.2 rad and 0.198 at 0.1 (linear in the scale); on a fixed
base following the walk, **computed torque 0.022 deg mean / 0.079 worst, the policy's spring 3.84
deg mean / 10.5 worst at 20 Hz** (5.57 at 10 Hz, 2.93 at 40) - and that gap is what the offsets
exist to close. Tutorial §11.6.
  * **The actuator model, settled by measurement:** a pose-target spring whose acceleration is
    realised THROUGH the model (inverse dynamics, or `floatingBaseTorques` when the root is free).
    Scaling the spring's acceleration by the mass matrix's DIAGONAL - the obvious per-joint gain -
    diverges: a chain buys more acceleration per torque than the diagonal predicts, so implicit
    damping becomes explicit and amplified, and at 20 Hz with a 60 Hz step the robot passes
    100 rad/s within twenty frames (measured, all frequencies, with and without bias compensation).
  * **Open:** torque limits. The spring can ask for any torque; real actuators cannot. A limit
    belongs in the task (T4) before any policy learns to rely on infinite strength.

**T4 — DONE. The task: reward, termination, episodes, and the floor.** `TrackingError` (six terms:
four pose terms in the root's frame, two root terms in the world - so perfect shapes in the wrong
place do not score), `RewardWeights` / `reward` (weighted `exp(-err/scale)`, 1 on the reference),
`Termination` (by tracking error ALONE - a height test would call the get-up's best possible
tracking a failure), `resetToFrame` (reference-state initialisation, exact), and `Gains
.max_acceleration` (an authority limit, model-scaled; it does not bind on the walk - the numbers are
unchanged - so it is a rail, not a handicap). Tutorial §10.1, §6.6.
  * **D8 TAKEN: lift each frame by what it needs, smoothed (3 Hz)** - `liftPerFrame`. Measured with
    the root HELD on the reference (with a free root the character loses the reference in 0.35 s
    either way, and the floor never gets a chance to matter):

        clip, option            reference deepest   typical frame   sim reaches
        walk, as retargeted          -0.028 m         -0.017 m       -0.036 m
        walk, lifted clear            0.000           +0.012         -0.007
        walk, PER FRAME              -0.007            0.000         -0.020
        get-up, as retargeted        -0.107           -0.044         -0.113
        get-up, lifted clear          0.000           +0.064         -0.005
        get-up, PER FRAME            -0.002           -0.000         -0.027

    One offset can only be right about one side: grounded by its typical frame the get-up lies
    10 cm inside the floor; lifted clear, it floats 6 cm in the air while standing. Per frame is
    right about both. The pose error with the root held is identical for all three (0.0121 walk,
    0.0151 get-up), so the decision rests entirely on geometry.
  * **Where it is applied:** by the TASK when it loads a clip, not by `retargetClip` - the retarget
    should keep saying where the capture puts the body.

### Phase B — A tracking policy: data, a world model, and two ways to learn (T5-T9)

**T5 — DONE. Data.** `Replay` (per-environment rings of the simulator's own pose and velocity, plus
the action, the reference frame and a SEGMENT that changes at every reset and every shove) and
`Fleet` (characters tracking clips together: observe, act, step - the shape the GPU version wants).
**Known answer: 10,000 of 10,000 draws returned an unbroken window** from a ring deliberately filled
with segments of 1, 2 and 100 frames wrapped several times over - same segment throughout,
consecutive frames, nothing overwritten. A fleet of 8 tracking the walk with NOISE for a policy:
mean reward 0.688, 228 episodes and 236 segments in 4,800 steps, every sampled window reconstructing
into states. Tutorial §11.7.
  * **⚠ MEASURED IN FREE FALL** (the floor bug, found at T7): the shape of these findings holds, the numbers do not. T6d re-measures. The episode lengths here (~21 frames) were the time to fall 0.6 m, and
    the "no 32-frame windows" finding with them. Standing: episodes 46 frames, 32-step windows
    200/200, mean reward 0.578 (the free-fall 0.688 was inflated by constant resets onto the
    reference). The machinery - rings, segments, the sampler, the 10,000-draw property - is
    unaffected.

**T6a — DONE. What the world model is asked, and the harness that judges it.** Its input (the state
in the root's frame, plus the servo's targets: sine and cosine a hinge, two axes a ball - the
TARGETS, not the servo's error, which during a rollout would feed the model its own drift), its
output (every body's acceleration in the root's frame, scaled), a `Predictor` interface, and
`measureDrift`: roll a source through recorded windows on its OWN predictions and measure the drift
at every step. **Calibrated before anything is judged by it**, with two sources that need no
training - mean body position error by step, over the same 200 windows:

        step            1        2        4        8
        oracle      0.25 mm  0.47 mm  0.84 mm  1.64 mm     (the integrator's floor)
        hold first  0.25 mm  19.3 mm  85.7 mm   346 mm     (the baseline to beat)

  They agree exactly at step 1, as they must (the baseline's first acceleration IS the oracle's) -
  a free check that the harness has no seam. Tutorial §11.8.
  * **⚠ MEASURED IN FREE FALL** (the floor bug, found at T7): the shape of these findings holds, the numbers do not. T6d re-measures. The oracle's floor is a property of the integrator and stands; the
    baseline's curve is the free-fall one (standing, it is 376 mm at 8 steps).

**T6b — DONE. A network on the kit, and its gradients proved.** `src/kit_mlp.zig`: `KitMlp(M)` -
layer sizes in, `forward`, `trainStep` (MSE + Adam) and the weights out, generic over the kernel
module so the same code runs on a GPU and on the kit's CPU twin. **Known answers:** the forward
pass matches a plain-Zig reference to 1e-6; every parameter's move is checked against FINITE
DIFFERENCES on that reference (30 of 37 had a gradient worth checking, none moved the wrong way,
each by exactly one learning rate - Adam's first step); and it fits sin(3x)y, loss 1.697 -> 0.002 in
400 steps. Tutorial §12.4.
  * **Departure from the plan, deliberately:** no zimrnum-graph version. The kit's kernels already
    run on the CPU twin, which is where parity comes from - a graph copy would be a second
    implementation of the same maths to keep in step, for nothing. The cartpole needed one because
    it predated the twin.
  * **Why a shared trainer at all:** every learner so far laid out its own buffer offsets by hand,
    and the cartpole's does it for two networks and an unrolled window across some forty fields.
    The world model, the policy and the critic all want the same thing.

**T6c — DONE. The world model.** `src/robot_world.zig`: `WorldModel(M)` - `KitMlp` over the T6a
features, trained on recorded transitions. **Known answer met, and then some** - mean body position
error by rollout step, same 200 windows, data collected with NOISE for a policy (the hardest
distribution: the character is falling in every direction):

        step            1        2        4        8
        oracle       0.3 mm   0.5 mm   0.9 mm   1.7 mm
        LEARNED      5.0 mm   8.1 mm  14.1 mm  35.4 mm     (256 wide, 2500 steps)
        hold first   0.3 mm  18.5 mm  84.0 mm   342 mm

  **9.7x better than the baseline at 8 steps against a bar of 5x**, growing smoothly, and the loss
  was still falling (9.8 -> 1.2). Tutorial §11.9.
  * **⚠ MEASURED IN FREE FALL** (the floor bug, found at T7): the shape of these findings holds, the numbers do not. T6d re-measures. A model of free fall is an easy model. Standing, the same small
    configuration gets 2.3x instead of 3.7x and its loss is far higher, because contact dynamics
    are discontinuous.
  * **★ Single-step supervision was enough - ON FREE FALL.** SuperTrack trains the world model
    THROUGH the rollout, which needs gradients through the integration and kernels this kit does
    not have. That conclusion is exactly the one the wrong dynamics could have handed us for free,
    so T6d re-decides it on the ground: if the re-measured curve clears the bar, the kernels stay
    unwritten; if it does not, they are the next rung and the reason is on file.
  * The committed test runs a small, quick configuration (128 wide, 600 steps: 3.7x) and asserts
    3x, a rising curve, and no step more than doubling the last - a model fine at four steps and
    wild by eight is useless to a policy unrolled through it, and that shows up as a jump.
  * **Not yet measurable: the 32-step drift** the policy actually needs. Windows that long do not
    exist while an unguided character loses the reference in a third of a second (D10). It becomes
    measurable as soon as a policy survives longer - which is T7's business.

**T6d — DONE. Re-measured on the ground.** Same features, same harness, same 256-wide network,
2,500 steps, data collected with noise on a character that is actually standing:

        horizon      oracle    LEARNED   hold first   ratio
        8 steps      2.7 mm     61 mm      357 mm      5.8x
        32 steps     9.5 mm    1.42 m     6.04 m       4.3x

  Loss 25.3 -> 5.9 (against 9.8 -> 1.2 in free fall: contact dynamics are discontinuous and much
  harder). **The 8-step bar still passes - 5.8x against a bar of 5x - but only just**, where free
  fall gave 9.7x.
  * **★ THE VERDICT ON T6c's CONCLUSION: single-step supervision is NOT enough after all, for the
    horizon that matters.** At 8 steps the model is worth planning through (6 cm). At 32 - the
    window SuperTrack's policy is unrolled over - it is 1.42 m out, which is not a model of
    anything; the oracle's 9.5 mm says the harness is fine and the error is the model's own,
    compounding. Free fall is an easy thing to predict and it flattered the method. This is why
    T6d existed.
  * **Which changes T8** (see below): the policy's window is 8 frames, where the model is
    trustworthy, unless and until the world model is trained THROUGH its rollout - the adjoint
    kernels T6c said we could skip. The critic in Phase D exists precisely to supply value beyond
    the window, and now has more work to do.
  * **D6 resolved:** 256 wide (512 does not fit the kit's buffers), and the window is what the
    drift curve licenses - 8 today, 32 only after rollout training earns it.

**T7 — The PPO baseline: DReCon's feedback policy on a five-second get-up.**

Placed here, before SuperTrack's policy, for five reasons: it is MODEL-FREE, so it does not wait on
a world model that is mid-re-measurement; every piece it needs already exists and has a known
answer (the fleet on its floor, the task, `kit_mlp`, `GpuPpoOn`); it is the project's first
end-to-end tracking result; **G3's table needs this baseline anyway**; and a policy that survives
produces the long episodes everything after it wants - the 32-frame windows, the drift curve at
the horizon that matters, data that is not a character falling over.

Motion matching is NOT part of this. DReCon's kinematic half is Phase F; what is borrowed here is
its RL half, with a clip played back where the motion matcher would be. Worth knowing before we
start: **DReCon's own conclusion lists getting up off the floor as unsolved** - "we have not yet
developed good methods of making a character stand up from a fall". A result here is past their
published scope, and a failure is cheap and early.

**T7a — DONE. The machinery.** `src/robot_policy.zig`: the DReCon-shaped observation (**108
numbers**, against their 110 for a character with half again as many degrees of freedom), the
action subset (**27 of 35** model degrees of freedom, over 6 watched bodies), the heading frame,
and the `Controller` that filters and holds. `kit_mlp` gained `output_scale`. **Known answers:**
the observation changes by **1.5e-6** under a 10 m move and a 0.8 rad turn while a 0.15 rad lean
changes it by a great deal (the control - invariance must not be blindness); the filter moves a
fifth of the way on its first step and closes without overshoot; with decimation 2 it moves every
other step; a zero request expands to **exactly** zero on every one of the 35 degrees of freedom,
so the servo drives the character untouched; and a network at output scale 0.01 asks for 0.114 at
most where an untouched one asks for 3.88. Tutorial §10.2.
  * **The heading frame falls back** when the character is face-down and its forward axis points at
    the floor - which is the get-up, and the get-up is the point of the set.

**T7a's original brief, for the record:**
  * **The gate, MEASURED (T6d's run): 2,642 env-steps/s**, 16 environments with contacts, single
    threaded - within a whisker of DReCon's own 2,500/s on 8 parallel Bullet sims, for a
    comparable character. So: **1M samples = 6 minutes, 5M = 32 minutes, 20M = 2.1 hours** here.
    DReCon needed 3e8 for the whole locomotion distribution with a user steering it; ours is one
    five-second clip, no user input, reference-state starts, a near-zero-init residual on a servo
    far stronger than their open-loop, and small networks. If that is learnable inside ~20M it
    fits in background runs; past that it waits for Phase C. **Training runs in the background
    across turns** - the pattern the slow suites already use - with progress and checkpoints on
    disk so a turn can poll it.
  * **`KitMlp` gains an output scale**, and the policy's last layer is initialised near zero
    (DReCon Fig 9: 0.4 against 0.2 mean reward at the start, and the gap persists). The whole
    premise is that the open-loop servo dominates early; He-initialising the output layer throws
    that away. Our servo is stronger than theirs, so this matters here more, not less.
  * **A DReCon-shaped observation:** the simulated character's bodies and their velocities for a
    SUBSET, the error against the reference, and the previous smoothed action. Their Fig 13 says
    pose-plus-errors beats pose alone and beats pose-plus-reference; their Fig 12 says a subset of
    bodies and joints learns faster AND better than all of them. Today's 582-number observation
    over all 19 bodies with a 35-DOF action is exactly the arm of that ablation which lost.
  * **A filtered action:** `y = beta a + (1 - beta) y_prev` with beta = 0.2, the policy evaluated
    every k = 2 physics steps, `y_prev` fed back in the observation (their Figs 6 and 7: smoother
    motion, slightly lower peak reward, much better looking).
  * **Known answer:** with the policy's output forced to zero the fleet behaves EXACTLY as the
    servo alone (same numbers, as T3's zero action does), and the filter's first output is beta
    times the first action - so the residual machinery is provably a no-op until the policy asks
    for something.

**T7b-1 — DONE. The trainer, and its wiring proved.** `src/robot_ppo_track.zig`: `Trainer(M)` -
collection over the fleet with decisions held for `decimation` physics steps, GAE (0.99 / 0.95)
normalised per batch, epochs of shuffled minibatches through `GpuPpoOn`. `Clip.window` carves the
get-up proper (frames 540-840: hips 6 cm -> 81 cm) and the walk control (frames 60-360); the fleet
now reports each environment's reward and episode end. **Known answers:** an untrained policy with
no exploration survives **exactly** as long as the servo alone (56.9 frames an episode, 9 ended,
both); and the CONTROL - the same trainer with exploration at 1.6 tracks measurably worse (reward
0.553 against 0.621), which a policy wired to nothing could not do. Tutorial §10.3.
  * `GpuPpoOn` already initialised its output layer at gain 0.01 - DReCon's Fig 9 has been in the
    gym all along - so no second knob was added.
  * **★ An environment fact for the runs to come: a long background process can be SIGKILLed** when
    a tool call ends badly (one run was, mid-suite). So training runs in CHUNKS with the policy
    checkpointed to disk between them - which it should do anyway: a run that cannot resume is a
    run that cannot survive anything.

**T7b-2 — UNDER WAY. Checkpointed chunks, and the first results.** `Trainer.save` / `load` (weights,
Adam's moments, counters; written to a temporary name and renamed, so a killed run keeps its last
good checkpoint), `Trainer.evaluate` (the MEAN action against the servo alone), `GpuPpoOn.actMean`,
and a `-Dtrain-chunk` build option that runs one resumable chunk (~180 s of learning) per
invocation, appending its learning curve to `train/<name>.csv`. **Known answer:** a checkpoint
loaded into a trainer built from a different seed gives the same weights to the bit, the same
Adam moments and step, the same counters, and the same value for the same observation.

        judged by the mean action, 300 decisions x 16 environments
                                 steps     frames/episode   episodes ended
        get-up   PPO policy      516k          78.2              108
                 servo alone                   68.3              130
        walk     PPO policy      264k          48.7              190
                 servo alone                   40.6              227

  Both learn: +14.5% survival on the get-up, +20% on the walk (the control), at similar rates, so
  the setup works and the get-up is not anomalously hard at this stage. The walk's servo baseline is
  SHORTER than the get-up's - walking needs balance from the first frame, the get-up starts lying
  down. Reward per step barely moves, as expected: surviving longer means more time in the hard part.
  * **The budget question, measured:** training runs at ~1,300 physics steps/s on this single core
    (half the raw collection rate - observation, acting and updates cost the rest), so a chunk is
    ~250k steps and 20M would be ~80 chunks. Levers, cheapest first: cache the reference's states per
    clip frame (the fleet re-runs forward kinematics on it every step); run chunks on a many-core
    machine with the fleet parallel over environments; or Phase C's simulator.

**T7b-3 — UNDER WAY. A profile, a 1.56x step, and a curve that keeps rising.**
  * **Profiled one fleet step before optimising anything** (452 us): `rbt.forward` before colliding
    28%, `rbt.step` + `rbt.forward` 61%, collision 7.5%, the reference's kinematics **2.7%** - so the
    reference cache planned last turn would have saved almost nothing. The first `forward` was
    REDUNDANT: every step ends with one and nothing writes to the data in between. Skipped behind
    the stage watermark (it still runs after a restart or shove). **Known answer: bitwise
    identical** to the old path over 300 steps with restarts and shoves. **Measured end to end:
    186 iterations a chunk against 119 - 1.56x.**
  * **The build cached identical chunk runs** - same binary, same arguments, 0 s and no learning -
    because a chunk's effect is what it writes to `train/`. `-Dtrain-chunk` now marks the
    per-module run as having side effects.

        judged by the mean action          physics steps   frames/episode   ended
        get-up   policy / servo alone           516k        78.2 / 68.3     108 / 130
                                                897k        92.0 / 68.0      94 / 132
                                              1,262k        93.6 / 68.0      92 / 131   +38%
        walk     policy / servo alone           264k        48.7 / 40.6     190 / 227
                                                635k        50.9 / 41.0     179 / 226   +24%

  At 897k the get-up's reward per step overtook the servo's too (0.629 against 0.606), despite the
  reset confound working against it. The curve is flattening, as early PPO curves do.
  * **The next lever, by the profile:** `rbt.step` + its `forward` are now ~85% of a step (~275 of
    ~325 us). `robot.zig`'s own notes say `robot.project` does two jobs in one pass and Newton reads
    only one of them - an engine-level optimisation, measured with `robot_bench`, and it speeds up
    everything that simulates, not only this run.

**T7b-4 — UNDER WAY. The step at 2.2x, and the get-up at +59%.**
  * **`rbt.step` runs a complete `forward` of its own** before integrating, so the fleet's trailing
    full `forward` computed the factorisation, constraints and dynamics solve only for the next
    `step` to compute them again. Replaced by the four stages actually READ between steps -
    `kinematics`, `comPos`, `crb` (the servo's mass matrix), `comVel` - with the entry guard asking
    for `velocity`. **364.5 -> 208.1 us a fleet step (1.75x; 2.2x since the original 452 us).**
    **Known answer, bitwise:** a fleet given a full `forward` before every step matches one relying
    on the partial state, over 300 steps with restarts and shoves, in ReleaseSafe AND ReleaseFast;
    the fleet test reproduces the post-floor numbers exactly (0.578, 104 episodes, 157 segments);
    the trainer's wiring test and the servo's judged score (64.2 frames, 138 ended) are unchanged
    to the digit. A chunk now fits 308 iterations against 186.
  * **Judged on the fixed starts:** get-up **102.4 frames an episode against the servo's 64.2
    (+59%)**, 79 ended against 138, at 3.43M physics steps. Still rising.
  * The build runner prints a successful run's stderr followed by its command line labelled
    "failed command" - noise, not a failure; the summary line is the verdict.

**T7c — DONE. The trainer made incremental, and the weights as a file.** A phone frame cannot block for
two thousand physics steps, so `iterate` becomes `collect` (a slice of decisions per frame) and
`learn` (advantages, then the update dispatched - on a GPU it trains while the next batch is
collected, and the acting weights catch up when the readback lands, which PPO's clipped ratio
tolerates). The weights become BYTES - `exportWeights` / `importWeights`, one versioned format that
carries the network's shape, so a file from a differently shaped network is refused by name rather
than loaded wrong. **Known answers:** `iterate` rebuilt from `collect` + `learn` reproduces the
old numbers to the digit (the wiring test's 56.9 frames and 9 episodes); weights exported and
imported into a trainer from another seed act identically.

  * **Done and proved:** `collect` / `learn` (with `iterate` rebuilt from them, reproducing the
    wiring test to the digit); a batch sliced three decisions at a time trains the same weights to
    the bit; `exportWeights` / `importWeights` in a versioned format carrying the shape
    (`ZPPOTRK2`), round-tripping across seeds down to the Adam moments on the device; a non-weights
    file, a truncated one, and weights for another width each refused by name.
  * **★ The kit's CPU twin is a singleton per kernel module:** its buffers are module globals (so
    the same kernels compile to WGSL, where storage buffers are globals), and two hosts in one
    process SHARE them. Tests use one live trainer at a time and compare device state against the
    exported bytes. The GPU has no such sharing; one trainer per page is the design anyway.

**T7d — DONE (untested on a device). The phone bench: `examples/getup_train`.** Builds as
`zig build getup-train`, and as ONE self-contained file with `zig build getup-train-standalone
-Dmode=ship` (**7.5 MB**; 17 MB in debug - of the rest, 3.2 MB is the capture as text, of which the
page needs only the first 14.5 s: trimming it is the obvious next saving). Characters on the CPU,
networks on the GPU (`z.Compute(zn_mlp).initGpu`), a slice of decisions a frame adapted to the frame
time, the character and its reference drawn, the survival curve, and the weights buttons:
  * **Save** - the engine had upload but not download, so `web.userfile` gained `offerDownload` /
    `setSaveRect` / `hideSave`: a real, transparent `<a download>` over the drawn button, its Blob
    replaced (and the old URL revoked) after every batch, so the tap is a genuine gesture - the
    rule mobile browsers apply to saving exactly as to picking. Files are named by batch count.
  * **Load** - `web.userfile`'s picker overlay, straight into `importWeights`: carried on from, or
    refused by name.
  * **The trainer's tests moved to `robot_ppo_track_tests.zig`**, outside the zimr module, by the
    project's own rule for kit proofs (they import `gpu/zn_mlp.zig` by path; a page imports it as
    a module). Training chunks now run from `zn-robot_ppo_track_tests`.
  * **The first device run crashed** (a wasm out-of-bounds trap on Simon's phone). The smoke
    runner reproduced it in 3 s and named both causes: `State` defaults never applied (the framework
    `gpa.create`s the state, uninitialised - fixed by one `Progress` struct assigned whole), and the
    fleet keeping a caller's local array of clips past its stack frame (fixed in the fleet: it now
    copies the list). Plus two teardown leaks the audit caught. Smoke passes in debug and release.
  * **For T7e:** the smoke run counts **1,267 clock calls a frame** (`js_now_ms`) - the profiler's
    zones in the simulation's hot path, each a crossing into JS. Cheap on a desktop, measurable on a
    phone: the first thing to look at if the frame budget is tight.
  * **Not yet run in a browser** - there is no WebGPU here. Everything under the page is proved
    natively (the pipeline, the trainer, the byte format); what only a device can say is T7e.

**T7e — UNDER WAY: the first phone run (Sep 21).** After a crash that the smoke runner reproduced
and fixed (standing rule 10), the page trains on Simon's phone: 8 characters, **3 decisions a frame
(~3,000 physics steps a second - the same as this server core)**, 108 batches and 111k physics steps
in the first minutes, best batch **1.74 s** with the reference against the servo's ~1.1 s. The
panel needs work for portrait (too tall and too wide; the curve's block glyphs are not in the font).

**T7e's original brief:** On Simon's phone: the baseline. PPO from scratch: minutes of wall clock to each
milestone of the survival curve, frame times, environment-steps a second. This is the number every
later rung is measured against, and it is measured on his device, not estimated on this one.

**Every rung after this one reports its time-to-bar on the bench**, beside PPO's. PPO on a five-second slice of `fallAndGetUp2_subject2`, reference-state starts,
DReCon's reward terms, an episode cap. **Known answer:** mean episode length rises above what the
servo alone manages (46 frames, measured), and the tracking error falls with it; the rung passes
when the slice is completed without falling at **mean body position error < 10 cm** - G1's bound
relaxed, because this is the first one.
  * **The control, run beside it:** the same setup on a five-second walk slice. Without it, a
    disappointing get-up cannot be told apart from a broken PPO wiring - and one of those is worth
    fixing while the other is worth accepting.
  * **D11 (here): how small, and which subset.** Two layers of ~48 units for both policy and value
    (a third of DReCon's 128; their Fig 8 shows 16 and 32 learning FASTER early and plateauing only
    a little lower, on a task far larger than one clip), and which bodies and joints the
    observation and action cover. Decided by what reaches the bar soonest.
  * **D12 (here): the reward's shape.** Ours is a weighted sum of exponentials, which lets one bad
    limb hide behind five good ones. DReCon sums over bodies INSIDE each exponential, which behaves
    like a product and forces the policy to fix its worst-tracked body - and on a get-up, one arm
    that fails to plant ruins the motion. Measured on episode length, as their Fig 14 does.

**The rungs from here follow §2's best path.** Each reports minutes-to-milestone on the phone.

**T8a — PARTLY DONE: the panel fits a portrait phone** (16 px font, six short lines, an ASCII
density-ramp curve every font can draw) **and the page times its own milestones** - wall-clock
training minutes at which a batch first stays with the reference for 2, 3, 4 and 5 s, reset when
weights are loaded. Smoke-tested in debug and release. Still to do: the servo judged on the
device, and the profiler's clock calls out of the hot path.

**T8a's brief:** The bench, made to measure. The panel fitted to a portrait phone (fewer, shorter lines;
an ASCII curve); the servo alone judged ON THE DEVICE at startup (a few seconds, fixed starts) so the
page shows policy against servo; and a **minutes-to-milestone readout** - wall-clock time at which
the survival first passes 2, 3, 4 and 5 s - so every method's time-to-bar is recorded by the page
itself. The profiler's zones kept out of the page's hot path (1,267 clock calls a frame, each a
crossing into JS). **Known answer:** smoke-tested in debug and release; the servo's judged number is
the same on every start of the page.

**T8b — DONE.** Observation normalisation (Welford in f64, clipped at five deviations, carried in
weights format v3 - a file and a trainer that disagree about normalising are refused by name) and
the root assist (`Gains.assist`: a spring on the root toward the reference, realised as `assist`
times the root rows of full-body inverse dynamics; bypassed entirely at zero, faded linearly over
`assist_batches`). Both opt-in, so every earlier known answer holds to the digit. **The sign
check:** the servo alone, fully assisted, ended 10 episodes where it ended 25 unassisted. The page
turns both on, **freezes the profiler (JS calls a frame 1,590 -> 315)**, measures the servo on the
device before training, and counts milestones only once the assist has faded. Smoke-tested in debug
and release. T8a is complete with it.

**T8b's brief:** The tricks every learner gets. Observation normalisation (running mean and variance,
saved in the weights file - a model loaded without its normaliser is a different model), and the
**annealed root assist**: a wrench on the root that starts strong enough to keep the character up
and fades to zero on a schedule, so the policy learns the motion before it has to learn balance. The
bar is judged with the assist at ZERO. Measured on PPO, on the phone. **Known answer:** assist at
zero reproduces T7's numbers exactly; normalisation's statistics round-trip through the file.

**T8a+ — DONE: a second motion, an honest metric, baked clips (Simon: "try the dance").**
  * **The metric was wrong, not just biased.** Characters start at random points of the clip (RSI),
    so an episode can never outlast what is left of it: on the 5-second get-up the mean remaining
    clip is 2.5 s, so milestones of 3, 4 and 5 s of EPISODE LENGTH were unreachable by a perfect
    policy. And the on-device servo number (0.24 s) was censored: only episodes that ended inside a
    96-step window were averaged. **Both replaced by mean time to failure** - exposure over failures,
    where a failure is losing the reference and running out of clip is survival - estimated over
    the last 8 batches (one batch is ~17 s of character-time). Clip-length independent, so both
    motions share milestones: 2, 5, 10, 20 s. The fleet now reports `failures` per ending.
  * **The dance:** all 20 s of `dance2_subject2` (Simon: use what we have), `max_episode_steps` long
    enough for it, and a `tag` in the weights (format v4) so a dance policy is refused by the get-up
    by name - the shapes are identical, nothing else would notice.
  * **Baked clips** (`zig build clip-bake`, self-verifying): 60 KB for the get-up and 240 KB for the
    dance, from 3.2 and 3.6 MB of capture text. **The standalone page: 7.66 MB -> 3.67 MB with two
    motions**, and no IK at startup. Both motions smoke-tested (the dance by starting on it).

**T8c — DONE: D15 decided, LATENT, by a wide margin.** `src/robot_latent.zig`: the next features
directly, z' = z + Net(z, reference targets, action), in normalised feature space, the action as
its own input (so T8d's path from policy output to model input is linear), the first layer as three
summed matmuls; trained THROUGH its own 8-step rollouts on zimrnum's autodiff (the CPU reference a
GPU version will be checked against). Same robot, data, width (128), budget (600 steps) and windows
as the structured model; POSE drift (mean body distance in the root frame - what a tracking policy
is scored on; `Drift.pose` added to the harness for the structured side):

| horizon | structured learned | its hold-first | its oracle | **latent learned** | its persist | its hold-first |
|---|---|---|---|---|---|---|
| 8 steps | 247 mm | 494 mm | 2.7 mm | **15.5 mm** | 35.1 mm | 79.1 mm |
| 32 steps | 7.93 m | 5.77 m | 9.5 mm | **30.7 mm** | 77.5 mm | 357 mm |

16x better at 8 steps, ~250x at 32 - where the structured model has blown up past its own baseline
and the latent one sits at ~3x the integrator's floor. Part of the margin is training through
rollouts, which is exactly what the latent form makes cheap: the decision was the best model per
line of new code. **Consequence for T8d:** the policy trains through THIS model, and 32 frames -
SuperTrack's own window - is back on the table (30.7 mm), with SHAC's critic for beyond.

**T8c's brief:** The world model worth unrolling: structured or latent (D15). Two candidates, one drift
curve. STRUCTURED is today's: accelerations out, integrated - physically honest, but training it
through its own rollouts needs hand-derived adjoints of the integration and the feature map, new
kernels. LATENT predicts the next features directly, as TD-MPC2's latent dynamics do: a rollout is a
chain of MLPs, so training THROUGH it - and training a policy through it - needs only the kit's
existing dense kernels. Both trained on multi-step rollouts (8 steps, anchored on recorded states),
judged by drift at 8 and 32. **Known answer:** the harness's oracle and baseline as before; the
winner is whichever drifts less at 8 steps for the least new code.

**T8d — FIRST HALF DONE: the policy through the latent model, on the CPU (`src/robot_track_st.zig`).**
SuperTrack's loop - collect in the real simulator, train the latent world model through its own
rollouts, train the policy through the model on windows starting at REAL recorded states - on
zimrnum's autodiff, the world model's tensors shared into the policy's graph and untouched by its
optimiser, exploration noise inside the rollouts as well as in collection. Measured on the walk at a
small budget (256 policy updates), with an in-model diagnostic that splits model from reality:

| | first run | model trained first |
|---|---|---|
| world model rollout loss | 0.242 | **0.165** |
| in the model, nothing -> policy (same held windows, no noise) | 0.840 -> 0.809 (-4%) | 0.671 -> **0.600 (-11%)** |
| mean action | 0.21 rad | 0.10 rad |
| REAL simulator, mean time to failure, servo / policy | 0.85 / 0.80 s | 0.85 / 0.89 s |

**The lesson:** a policy trained through a model can only be as right as the model. Seeded with
0.03-rad action noise and trained alongside from scratch, the model could not say what an action
does, and the policy learned large actions worth 4% in the model and nothing in reality. Trained
first (600 steps), on data whose actions vary (0.1 rad), with exploration sigma 0.3 and a real price
on action size (0.1): 11% in the model, actions halved. **The real-simulator differences in BOTH runs
are within noise** (~185 failures each over 160 s of character-time; 8 apart is ~0.6 sigma), so the
test asserts the deterministic mechanism (in-model, policy < 0.95 x nothing) and REPORTS reality.
**Open question for the GPU version:** beating the servo in the simulator by a significant margin at
a real budget - thousands of policy updates, which the CPU reference cannot afford in a test.

**T8d's second half - DONE, and the answer is "not at this budget".** SHAC's critic is written
(`Options.critic`, off by default; `trainCritic`; `initWith` lends one frozen world model to two
learners differing only in the critic). On that frozen model, 8-step windows, judged in the model over
24 steps: **without a critic the gain carries past the window** (asserted: better than doing nothing
at 24 steps), and **the critic HURTS** (24 steps: 0.558 without, 0.693 with, 0.876 with warm-up and 4
critic updates a step - reported). Reason: a bootstrapped critic starts at "no cost to come" and its
input gradient is noise until dozens of bootstrap rounds have passed, while the window's end enters the
policy's loss amplified ~92x (gamma^8 / (1 - gamma)). SHAC leans on budgets - thousands of parallel
environments, target networks, TD(lambda) - that belong on the GPU. **Next: the loop on the kit,
without a critic; the critic revisited there.** (The run passed in the turn that died; this turn's
rerun was a cache hit on the identical binary - a real pass, numbers as that turn recorded them.)

**T8d's brief:** The policy through the model, with a critic beyond it (SHAC on SuperTrack). 8-frame
windows starting on real recorded states (DiffMimic's anchoring comes free - every window starts on
the record), the tracking loss backpropagated through the world model into the policy, and a value
critic bootstrapping past the window. All of it batched on the GPU - the phone's plentiful resource
- while the CPU only simulates. **Known answer:** on the phone, the same milestones as PPO in a
fraction of the minutes; and natively, gradients through the window checked against finite
differences before any training.

**T8e — The critic, CrossQ-style.** Batch-normalised, no target network, update ratio 1: the
cheapest good critic there is, for T8d's bootstrap - and, run on its own as SAC, the model-free
comparison that says how much of T8d's gain is the model's.

**T9a — The latent world model on the kit: the design (Sep 21, from the kit's own kernels).**
Two facts make it small. `dense_fwd`/`dense_bwd_*` read input rows with a host-set **stride**
(`params.stride`, 0 = `in_dim`) - so `[z | reference | action]` is one wide row and the concat is a
buffer LAYOUT, no kernel. And `dense_bwd_w` has an **`accumulate`** flag - so weight gradients sum
across the rollout's steps with nothing new.

  * **Layout, per step k:** a block `X_k` (rows x (F+R+A)) holding `[z_k | ref_k | a_k]`; the host
    stages every `ref_k`, `a_k` and `z_0`; the device fills `z_k` for k >= 1. Plus a contiguous
    `Z_k` (rows x F) for the loss, since the MSE kernels read contiguous rows.
  * **Forward:** layer 1 on `X_k` (stride F+R+A) -> tanh -> layer 2 -> tanh -> layer 3 -> `D_k`
    (the change); then **NEW `lat_advance`**: `z_k + D_k` written to BOTH `X_{k+1}[:, 0:F]`
    (strided) and `Z_{k+1}` (contiguous). Loss: `mse_value` per step on `Z_{k+1}` vs its target.
  * **Backward, k = H-1 down to 0:** the change's gradient is exactly the next state's gradient
    (`z_{k+1} = z_k + D_k`); through layers 3, 2, 1 with `act_bwd`, `dense_bwd_x`, and
    `dense_bwd_w` (accumulate after the first step processed) -> `dX_k`. Then the state's gradient
    `dZ_k = mse_bwd(Z_k) + dZ_{k+1}` (the residual path: `add_block`, contiguous) **+ NEW
    `lat_take`**: `dX_k[:, 0:F]` (strided) added into `dZ_k` (contiguous). Then `adam`.
  * **New kernels: two, both generic** (a strided add-and-copy forward, a strided gather-add
    backward). Everything else exists.
  * **Budget:** rows 32, H 8, width 128 needs ~340k floats of activations - over the kit's 2^18 per
    buffer. Rows 16, or the kit's buffer size raised; decided when implemented.
  * **(1) DONE:** `lat_advance` and `lat_take` in the kit, bitwise equal to plain Zig on the CPU twin,
    and neither writes outside its block (kit_mlp's test).
  * **(2) DONE:** the forward rollout on the kit (`src/robot_latent_kit.zig`, `LatentKit`) against
    the CPU model's own step (`robot_latent.stepWith`, shared by both): 8 chained steps, real sizes
    (291/70/35), worst difference **exactly 0** - the kit adds a stacked layer's inputs in the CPU
    model's order, bias first.
  * **(3) DONE:** `LatentKit.backward` against zimrnum's graph of the CPU model (built from the
    model's own `step`): all 23,363 weight gradients through 8 chained steps, worst difference 6.7e-6
    against a largest gradient of 16.6. The kit's loss is the SUM over steps - 8x the CPU model's mean,
    checked as such; Adam cancels the constant.
  * **(4) DONE - T9a COMPLETE: the latent model's whole training step runs on the kit.** `adamStep`
    (epsilon x steps, so the summed loss takes the CPU model's exact step) against `AdamSet` on identical
    gradients, 3 steps: worst 1.5e-8 (half an ulp). `trainStep` = forward + backward + Adam.
  * **Known answers, in order (one per turn):** (1) the two kernels alone, against plain Zig;
    (2) the forward rollout's `Z_k` against `robot_latent.stepRow` for the same weights, to 1e-5;
    (3) every gradient against zimrnum's graph for the same batch, to 1e-4; (4) one Adam step equal.

**Adversarial review of T8-T9a (Sep 21).** Hunting what would fail SILENTLY.
  * **FIXED - `LatentKit` could overrun the kit's buffers.** Every kit buffer is 2^18 floats and the
    layout was never checked against it; the plan's phone configuration (32 rows, width 256, 8 steps)
    needs ~470k. On a GPU that writes past the end with no error anywhere. `init` now refuses with
    `error.KitTooSmall`; tested both ways (32/256 refused, 16/128 fits).
  * **FIXED - judging consumed the training's random stream** (`Learner.act` drew noise even at zero).
  * **SIMPLIFIED** - the kit's Adam test calls `zn.adamStep` (what `AdamSet` wraps) instead of importing
    robot_gym, whose 424 unrelated tests had joined this root; `packWeights` is a plain loop.
  * **CLEARED - acting and training aim at the same frame.** `Fleet.step` records a state with its frame
    before advancing it, and acting reads the same `fleet.frame`; no off-by-one.
  * **OPEN, ranked:** (1) T9b's width: at width 256 the rollout does not fit 2^18 - rows 16 at width 128
    does; decide between a bigger kit buffer and a smaller model. (2) Baked clips can go STALE silently
    when the retarget, filter or lift changes - a slow test that re-bakes in memory and compares with
    the committed files. (3) The latent model's normaliser is frozen at init from early data; a long run
    drifts out of it. (4) The critic code the dead turn wrote is still unreviewed by a live turn, and
    carries a negative result - **REMOVED (deep review, Sep 21):** 226 lines out of `robot_track_st.zig`
    (920 -> 694); the file header records what it measured and why it hurt; the past-the-window
    assertion kept as a single-learner test (world model trained, then left alone). **Verified:** both
    slow tests pass on the rebuilt file - past the window 24 steps: nothing 0.730, policy 0.557 (the gain
    GROWS past the window: -20% at 8, -24% at 24); the main test reproduces every earlier number exactly. (5) The page's
    servo phase steps the training fleet behind the trainer's back: the first batch's episode lengths
    are off (mean time to failure is not).

**THE LAST REVIEW TURN - GPU residency (Sep 21). The goal, restated by Simon: train on SINGLE-CORE
wasm and WebGPU, with as much of the simulation and the training RESIDENT on the GPU as possible.**
Through that lens the verified T9a has one design flaw, and it shapes all of T9b: `LatentKit` expects
the HOST to stage every training window - features by forward kinematics for every record of every
window (the reference's too), ~250 KB uploaded, every training step. On one wasm core that would be
the most expensive part of training, on the wrong processor. So:

  * **Stays on the CPU (one core):** the simulation (until Phase C) - and ACTING, from a CPU mirror of
    the GPU-trained policy, as PPO already does (`KitMlp.cpu_params`). Not a shortcut: WebGPU readbacks
    arrive a frame late, and a CPU simulation needs its action now. The live state's features, once
    per step, since acting needs them anyway.
  * **Moves to the GPU and STAYS there:** (1) the REPLAY of features - a ring, appended with `uploadAt`
    once per simulation step (a record is ~1.6 KB: raw features, action, frame, clip, segment);
    (2) the REFERENCE tables - every clip frame's goal features and encoded targets, computed and
    uploaded ONCE per clip (get-up 300 x 361 floats, dance 1199 x 361); (3) a GATHER kernel building
    each window's wide blocks and targets from the ring and the tables, given only the sampled window
    starts (the one per-step upload: a few dozen integers); (4) NORMALISATION inside the gather, from a
    small mean/spread buffer - the ring holds RAW features, so the normaliser can be refreshed at will
    (open item 3, solved by construction); (5) the world model's training (T9a), the policy through it,
    and Adam. Readbacks: the policy's weights for the acting mirror, and a loss for the panel - both
    asynchronous, a frame late, harmless.
  * **Capacity:** the ring and the tables outgrow the kit's one-size 2^18-float buffers. The kit needs
    PER-BUFFER sizes - a dedicated replay buffer (WebGPU allows 128 MB bindings by default); and since
    the CPU twin's buffers are static arrays, every size is also wasm memory: size for the phone.
  * **What remains on the one core, after all this:** the simulation and acting - measured at ~3k
    physics steps a second on Simon's phone. Phase C (the simulation on the GPU) removes the first and
    makes acting a GPU dispatch reading GPU state: then the whole loop is resident and the CPU only
    issues commands.

**T9b step (1) DONE - per-buffer kit sizes, without a new buffer.** The host already sizes each GPU
buffer from its own field, so only `acts` grew (2^21 floats, `zn_mlp.acts_len`) - the ring and tables
will live in it, because a NEW buffer would be the kit's 8th and 9th, past WebGPU's guaranteed 8, where
writes are silently dropped. `LatentKit` checks every region against its own buffer: the plan's phone
configuration (32 rows, width 256) now FITS; 128 rows is refused by its gradients. The transpiler
accepts the per-field size (page built), and the smoke test passes. **Caught on the way:** the build's
two per-page kernel lists never got `lat_advance` / `lat_take` (T9a step 1) - every page using the kit
had failed to build since, unnoticed because the kit's tests run on the CPU twin, which needs no WGSL.
Fixed; and a lesson for new kernels: build a page, not just the tests.

**T9b step (2) DONE - the resident tables and ring** (`Resident` in `robot_latent_kit.zig`). Table
rows per clip frame (the reference's RAW features + encoded targets), uploaded once; ring records
(raw features + action + table row, 327 floats) with the replay's capacity, laid out STEP-MAJOR so a
simulation step is one upload for every character (all append in lockstep - asserted). The CPU keeps
sampling windows (it knows where episodes break). Checked BITWISE against features computed
independently by the same functions: all 128 live records of a 4-character fleet on the baked get-up,
and table rows across the clip - the test checks the addressing, where resident-data bugs hide.
**For step (3):** `uploadAt`'s own warning - two uploads to the SAME offset in one frame clobber each
other before either dispatch runs - so each training step's window starts need their own region.

**T9b step (3) DONE - the gather kernel** (`lat_gather`, `Resident.gather`). One thread per number:
the normalised first state and targets, the reference from the table row (at the SAME offset in a
table row and a wide row), the action from the record. Per window only two floats travel (character,
first slot). Normalises with the CPU's operations in its order: **bitwise equal** to `local` +
`Normalizer.toNormal` + `encodeTargets` + the replay's actions, 4 windows x 5 steps of a real fleet.
Twelve NAMED parameters (48 bytes, alignment kept). Proven through the transpiler by a page build
(`@trunc` for the float-held integers, per the engine's lint), and the page's smoke test passes.
**For step (4):** the starts region is one per `Resident`; several training steps in one frame need
a region each (same-offset uploads in a frame clobber).

**T9b step (4) DONE - the world model trains on the GPU, from windows the GPU assembles.** Gather,
rollout, backward, Adam, against the CPU model's `trainOn` (split from `trainStep`; sampling first,
so RNG order is unchanged) from the same weights and normaliser on the SAME windows, 60 steps: the
kit follows the CPU model's loss at every step to 1.2e-5 relative, and both descend (ten-step means
0.3728 -> 0.2479). The loss value needs no kernel: one `mse_value` over the contiguous Z and T blocks
IS the mean over steps. A first 20-step version saw both RISE, identically - a transient (near-zero
output layer vs Adam's first steps) plus single-batch noise; judged by ten-step means over 60, both
fall. **Verified (review, Sep 21):** D15 and T8d reproduce every number after the `trainStep` split.
**Review of steps 3-4:** the asserts are `assertf` with messages; `Resident` now keeps BOOKS - the
replay indices its ring has received - and refuses a skipped append (a missed step would otherwise
leave a stale slot the CPU still samples) and any window outside what the ring holds; `gather`
refuses a kit whose blocks reach the resident regions. The tricky parts are commented: the buffer
layout in one picture, the gather's index arithmetic, staging reuse, the one start region, the
single-thread loss.

**T9b step (5) - the policy through the model, on the kit: the design (Sep 21).** Five sub-steps, one
checked answer each, because it is the largest piece of T9b:
  * **(5a) One row for both networks: `[goal | z | reference | action]`.** The policy reads the first
    2F columns (its stacked first layer: goal block, then z block); the world model reads from column F
    on, with the row's stride - a SUB-RANGE of a strided row, which `dense_fwd`'s `x_off + r*stride + i`
    supports by construction (5a's test proves it). The gather also writes each row's goal (the table's
    goal columns, normalised) and a contiguous goal block for the tracking loss. Known answer: with the
    goal columns present, the world-model rollout still matches the CPU model bitwise.
  * **(5a, first half) DONE:** `LatentKit` takes a `lead` of goal columns; `width` (the row's stride) and
    `inputs` (the world model's width) are separate fields, because the input-gradient block is laid out
    by `inputs`. With 291 random goal columns the rollout is still BITWISE, the next rows' goal columns
    untouched; the gradient check runs at lead 0 AND 291 (9.5e-6 of 14.3) - lead 0 alone could not catch
    a width mix-up, the widths being equal there. The gather refuses a lead until it writes goals
    (second half, next).
  * **(5a) DONE:** the gather now fills each row's goal (the reference at the step's frame, normalised)
    and a contiguous goal block for steps 1..steps - bitwise against the CPU learner's own recipe, the
    world model's slice unmoved; `lat_lead` must be 0 or the feature count (a goal IS a feature vector).
    Two more named parameters (+2 padding); page build and smoke pass.
  * **Bug hunt over 5-5a (Sep 21):** the offsets in the gather against the layout helpers, and the goal
    indexing against the CPU learner - all consistent. FOUND: the resident tests' `FleetSetup.init` had
    no errdefers, so a missing baked clip leaked the robot and FAILED the tests instead of skipping them;
    fixed, with a test of that path shown to fail (20 leak reports) without the fix. CLEARED: the
    parameter block's 16-byte multiple is enforced at compile time by the compute host. The gather's
    window check no longer carries an unreachable fallback.
  * **(5b) The policy's forward.** Per step: three dense layers -> raw action (contiguous); a NEW
    `lat_act` writes `scale * (raw + sigma * eps)` into the row's action columns; then the world model's
    step. Noise from a counter-based hash (step, row, column, seed) computed on the GPU - no upload -
    with the same hash on the CPU for the check. Known answer: the kit's rollout against the CPU
    Learner's (`policyRow` + `stepRow`) on the same windows, to ~1e-6 (the policy's summation order
    differs from the CPU's interleaved one, so not bitwise).
  * **(5b, deterministic half) DONE:** the policy acts inside `LatentKit`'s rollout (`policy_hidden` > 0;
    its weights after the world model's at `p_at`, packed goal block then state block; its blocks after
    the rollout's). `lat_act` writes `scale * raw` into the row's action columns before the world model
    reads the row. Against the CPU learner's own `policyWith` (extracted from `policyRow`) feeding
    `stepWith`, 8 steps: actions to 4.8e-7, states to 5.7e-6 (rounding from the interleaved vs blocked
    first-layer sums, compounding through the loop). Page build and smoke pass. `lat_sigma`/`lat_seed`
    are declared already; the noise itself is next.
  * **(5b) DONE - the noise:** `latNoise` (in the kit's own file, so the CPU reference calls the very
    function the kernel does): an integer hash of (seed, row, column) - shifts, xors, wrapping
    multiplies, the same bits on any GPU - to four uniforms from the top 24 bits (exact as floats), summed
    and scaled (Irwin-Hall: mean 0, variance 1, bounded +-3.46; not Box-Muller, whose log/cos GPUs may
    round differently). `latStepSeed` mixes one seed per step. Statistics checked (40,000 draws: mean,
    variance, neighbour correlation, bound); the noisy rollout follows the CPU learner (actions 7.7e-7,
    states 3.8e-6). The integer hash transpiles (page built); smoke passes.
  * **(5c) Backward, through a FROZEN world model.** The world model's layers pass input gradients only
    (`dense_bwd_x`, no weight gradients). A state's gradient now has FOUR sources: its tracking term, the
    residual, the world model's input gradient into its z columns, and the POLICY's (the policy reads z
    too). The action columns' gradient becomes the raw action's through a NEW `lat_act_bwd` (x scale),
    plus the action price. Known answer: every policy gradient against zimrnum's graph of the CPU
    Learner (T8d's), to ~1e-5 relative.
  * **(5c) DONE - backward through the frozen world model:** `policyBackward`. The world model's layers
    pass input gradients only; `lat_act_bwd` turns the action columns' gradient into the raw action's
    (`scale * d action + price * raw`; the noise is additive, so it adds nothing); the policy's layers
    accumulate weight gradients across steps. A state's gradient gathers from FOUR places - its tracking
    term against the GOAL, the residual, the world model's input gradient, and the policy's (at offset
    `lead` of a block `lead + features` wide: a third width). `activationGrads` now takes its width -
    it had hard-coded the world model's hidden size. Against zimrnum's graph of the CPU learner's own
    `policyOnGraph` + `step`, same hashed noise: all 20,867 policy gradients = 8x the CPU's, worst 1.6e-6
    of 1.37. Page build and smoke pass.
  * **(5d) Adam on the policy's weights only** - its own offset in the parameter buffer, beside the world
    model's. Budget at width 128: world 104,867 + policy 95,651 = 200,518 of 262,144 floats (width 256
    would need 466k: stay at 128).
  * **(5d) DONE:** `adamPolicy` (the Adam step generalised to a region, `adamOver`; the kit's `adam`
    offsets all four of its buffers by one `w_off`, checked by reading it) and `policyTrainStep` (forward,
    `policyBackward`, `adamPolicy` with epsilon x steps). Against zimrnum's `adamStep` on identical
    gradients, 3 steps: 7.5e-9 over 10,195 weights; the world model's weights bitwise unchanged and its
    moments still zero, with its gradient region full of non-zero bait. (An edit deleted `loss()` on the
    way - caught by the compiler, restored, and every function diffed against the snapshot.)
  * **Review of bug 2's reach (Sep 21):** the servo's aim changed, so everything that builds "the servo's
    target" or shows a policy "the reference" had to follow - and three places had not: `Fleet.targetsAt`
    (the structured world model's training input, rebuilt from the replay), the MPPI planner's horizon
    (`frame + h` -> `frame + h + 1`), and PPO's observation and evaluation (the reference at the frame the
    servo aims at). All fixed; tracking and PPO tests pass (an untrained PPO policy is unaffected by what
    it observes, so its wiring numbers are identical). **Verified since, in part:** D15 is unaffected (latent 16.0 /
    32.0 mm at 8 / 32 steps, was 15.5 / 30.7; structured still far worse). **The planner test FAILS** at its
    world-model stage: the structured model drifts 192 mm at 8 steps (T6d: 61 mm), loss 27.0 -> 9.08 (T6d:
    25.3 -> 5.9). Unexplained. `targetsAt` has three consumers - the structured model's training
    (robot_world:135), the drift harness (robot_track:1490) and a test (robot_track:2536) - so an
    inconsistency among them is the first suspect; data that is simply harder for this fragile
    single-step model the second. **FOUND (deep review, Sep 21) - not a regression.** (1) Servo and
    `targetsAt` both back at frame i reproduce the transcript's run of this test BITWISE (loss 26.3644 ->
    8.6494, 166.4 mm at 8 steps): nothing degraded since T6d. The "61 mm" compared against was a different
    measurement's configuration, not this test's - a wrong baseline, not a code change. (2) Servo at i+1
    with `targetsAt` deliberately left at i gives 190 mm, the same as the consistent 192: at this model's
    resolution one frame of target input does not matter, so there is no inconsistency to find. (3) So
    the frame fix makes this fragile single-step model's data ~16% harder (166 -> 192 mm), enough to
    cross a bar the test passed by 12%. Remedy: its training budget 600 -> 900 steps (the budget is the
    knob; the bar stays): 133 mm vs hold-first 379 - a third - and the planner stage passes. The latent
    model, the one SuperTrack uses, barely noticed (15.5 -> 16.0 mm). Done meanwhile for 5e: the
    learner takes an optional `noise(update, step, row, action)` function (default: its own random
    stream, so nothing else moves) and counts its updates - set in `init`, since `gpa.create` would never
    apply a field default. Parses; not yet compiled. Also still pending for 5e: the CPU
    learner's in-rollout noise must become `latNoise`, or 5e's step-for-step check cannot hold.
  * **(5e, first piece) DONE - the policy's resident update follows the CPU learner step for step.** The
    learner's `trainPolicy` split into `fillRow` + `update`, with `trainPolicyOn(windows)` for given windows -
    sampling and filling still interleaved in `trainPolicy`, because filling draws the rollout's noise
    from the same stream (the slow tests reproduce every earlier number exactly). The learner handed the
    kit's hash as its noise; the kit's seed = the learner's update count. 30 updates on gathered windows,
    world model held fixed: loss 0.885 -> 0.637, worst relative gap to the kit **9.7e-8**.
    **Next pieces:** world and policy updates interleaved (the world model training too), a window-start
    region per update (the clobbering rule), then the loop against the CPU learner over tens of rounds.
  * **Test time (Sep 21, Simon: a third, even if losses barely fall):** the walk is BAKED now
    (`assets/lafan1/walk1_subject2.zclip`, the tests' exact pipeline, verified) - no half-minute of IK per
    test. robot_track_st's two slow tests rewritten on one `WalkSetup` (baked walk, 8 characters, replay
    256, width 64, batch 16, 200 + 60 / 8x(8+8) updates, judging 300 steps), asserting what that budget can
    show (policy better than nothing in the model; the gain carries past the window): **554 s -> 81 s
    with compile, ~7x.** At this budget the real simulator shows the policy BELOW the servo (0.71 vs
    0.89 s; world loss 0.404) - reported, not asserted: a weak model is easy to exploit.
    **robot_world's two: DONE** - the same treatment (baked walk, 8
    characters, replay 256, width 64, rows 32, planner 400 steps and D15 250, drift over 80 windows), the
    planner's two magnitude bars relaxed to "the loss falls" and "the learned model beats hold-first"
    (its structural checks - above the oracle, drift smooth and monotone, the planner making contact -
    are untouched): **213 s -> 69-81 s with compile**, the tests themselves ~160 s -> under 30. The
    conclusions hold: planner 183 mm at 8 steps vs 378 baseline; D15 latent 21.8 mm vs persist 32.5, and
    38.7 mm at 32 where the structured model is at 9.3 m. `loadClip` and `readAll` deleted with their last
    callers. **The whole slow suite: 767 s -> 162 s, ~4.7x** - compilation (~53 s a root) now dominates.
  * **(5e, second piece) DONE - the two updates share the kit without spoiling each other.** A bug found
    by writing the driver's shape down: `forward` runs the policy when one exists, which is right for a
    POLICY update and wrong for the world model's - trained through it, the world model would learn the
    simulator's outcomes for actions the simulator never took. Now `forward` (acting) and
    `forwardRecorded` (the actions as gathered) are separate, and the world's `trainStep` takes the
    recorded one. The step-4 comparison now runs WITH a policy in the kit - it would part company with the
    CPU model at once otherwise - and checks that a recorded rollout leaves each row's action columns as
    the gather wrote them: still 1.2e-5 over 60 updates.
  * **(5e, third piece) DONE - a window-start region per update.** `Resident` takes `slots` regions and
    `gather` splits in two: `stageStarts(starts, slot, steps)` (the upload, with the ring-range check -
    now including the window's last record) and `gather(kit, slot)` (the dispatch). That is the shape a
    frame really has: uploads first, dispatches in order - so two updates may share the rollout's blocks,
    each one's dispatches reading them before the next gather overwrites them, but never one place for
    their starts. Tested as a frame does it: both batches staged, then gathered in turn, each finding its
    own windows.
  * **(5e) DONE - the driver: `src/robot_track_resident.zig`.** One round = SuperTrack's iteration, split
    by processor: the CPU simulates and acts from a MIRROR of the GPU's policy weights (readbacks are a
    frame late; the simulator needs its action now), records every step into the ring with one upload,
    and the GPU trains the world model and then the policy on windows it gathers itself, each update in
    its own start slot. The driver owns both networks' seeding (Xavier, near-zero output layers: the
    world model starts as "nothing changes", the policy as the servo alone) and takes the normaliser as
    an argument, so the paper's kinematic-table statistics can be used when we want them. Tested end to
    end on a real fleet: 12 rounds, 12 + 12 updates, world loss 1.379 -> 1.275, and the mirror follows
    the GPU. Correctness lives in the step-for-step comparisons (gather bitwise; world model 1.2e-5;
    policy 9.7e-8).
  * **Adversarial review of 5e (Sep 21).** FOUND, in the driver: `init` seeded the weights and then
    refreshed the mirror - but the host's readback window starts at NOTHING and the caller only widens it
    after `init`, so the refresh silently did nothing and the mirror held whatever `alloc` left there.
    The first round simulated on uninitialised weights; my own test sailed past it. Now the mirror starts
    ZEROED (a missed refresh means the servo alone, not noise), `init` widens the readback itself, and
    the driver's allocations have errdefers (the gap the fleet setup once had). The fix shows: the world
    model's loss over 12 rounds went 1.379 -> 1.275 before, 1.434 -> 1.085 after. Also tightened:
    `stageStarts` demands a FULL batch, since a partial one would leave the previous update's windows in
    the rest of the slot to be gathered again.
  * **(5e's brief was:)** world and policy steps interleaved, a window-start region per step (the
    clobbering rule), the noise seed advanced per step. Known answer: the kit's policy losses follow the
    CPU Learner's over tens of steps, as step 4 did for the world model.

**SUPERTRACK CONFORMANCE REVIEW (Sep 21, against Fussell, Bergamin & Holden 2021).**

*Follows the paper:* the `Local` representation (Eqs. 1-7: root-relative positions, velocities, two-axis
rotations, angular velocities, heights, up - ours is exactly this); the world model trained through its
own 8-step rollouts from a real state (Alg. 1's teacher forcing); the policy trained through the world
model from a real first state, noise INSIDE the rollout (o + sigma N), OFFSETS on the reference pose
rather than absolute targets (their Sec. 6.2 ablation), the world model untouched by the policy's loss,
the pre-noise offset penalised; the gym acting with the same noise, off-policy replay, world and policy
updates interleaved with collection; a survival-style measure (our mean time to failure).

*Deliberate deviations (kept, reasons recorded):* the LATENT world model (D15) instead of accelerations
integrated in world space - but note D15 compared it against our structured model trained SINGLE-step,
while the paper trains the structured one through rollouts, and its Sec. 6.3 finds accelerations beat
velocities; our latent change-of-features is velocity-level for the position features. Kept for code
economy on the kit; revisit if quality plateaus. Networks 2x128 tanh vs their 5x1024 ELU; replay a few
thousand records vs their 150,000; batches 8-32 vs 1024-2048 - all the phone's budget.

*Unintended deviations - TO FIX, ranked:*
  1. **FIXED IN CODE, VERIFICATION PENDING (Sep 21):** the learner's `action_scale` is gone; it passes
     raw + noise (what the fleet records), `modelLoss` reports radians via the fleet's scale, and the
     walk tests' fleets carry `action_scale = 0.3` - the authority intended, five times what the policy
     had. Compiles, lint-clean. The "21 minutes" was MY command: the test root run with slow tests and no
     filter also runs every imported module's slow tests (462 tests). Alone: past-the-window PASSES
     (192 s; 24 steps nothing 0.664, policy 0.592). The main T8d test FAILS (360 s): world loss 0.918
     (was 0.165), in the model the policy is WORSE than nothing (1.245 vs 1.151), real 0.80 vs servo
     0.85 s, actions 0.13 rad (true radians now). Cause: the test's sigma = 0.3 was tuned while the
     authority was secretly 0.06 rad/unit (effective noise 0.018 rad); at the true 0.3 it is 0.09 rad
     of joint-target jitter every step - data the world model cannot learn at this budget. **DONE and verified:**
     the tests now use the learner's default sigma (0.1, the paper's). Both pass (545 s together): world
     loss 0.181; in the model nothing 0.724 -> policy 0.595 (-18%, was -11% under the bug); past the
     window -31% at 8 steps and -20% at 24; actions 0.10 rad, true radians. Real simulator 0.88 vs servo
     0.85 s - within noise at this budget, as before: still the GPU budget's question.
     *The bug as found:* the learner multiplies by its `action_scale` (0.3)
     and the fleet's `applyAction` by its own (0.2) - one unit of policy output is 0.06 rad, five times
     less authority than intended, and T8d's "rad" figures were learner units. PPO scales once (the
     fleet). Fix: ONE scale, owned by the fleet that applies it; the learner passes raw + noise, and the
     kit's `action_scale` becomes 1 (the world model sees the recorded action either way).
  2. **FIRST HALF DONE (Sep 21): the fleet's servo aims at frame i+1** (`driveOnce`, clamped at the end).
     The tracking stack's 17 tests pass (slow included); PPO's 4 pass, the wiring test's reward per step
     up 0.621 -> 0.632 (episode lengths unchanged at that scale). **SECOND HALF DONE (Sep 21):** the SuperTrack
     side now matches - the world model's reference input is the pose the servo aimed at (frame i+1,
     clamped like `driveOnce`), and the policy sees K_{i+1} - in the CPU model, the learner (graph, live
     acting, `modelLoss`) and the gather (goal and reference from the NEXT record, action from its own).
     Kit: 15/15, gather bitwise, training step-for-step to 1.2e-5. Slow tests pass: in the model 0.661 ->
     0.553 (-16%), past the window -28% / -20%, and the REAL simulator policy 0.99 s vs servo 0.85 s (+16%,
     ~1.4 sigma - the best yet, suggestive, not yet significant at this budget). Page build passes. What
     it used to say: `LatentWorld.referenceAt` and the gather's reference columns must take frame i+1
     (the next record's table row), and the policy's goal must be K_{i+1} (the learner's `goals[k + 1]`,
     the live goal at frame + 1, and the gather's row goal from the next record).
     *The bug as found:* the fleet's servo targets frame i during the step to i+1 (the
     paper: k_{i+1}); the policy is given the goal at frame i (the paper: Local(K_{i+1})). Both learners
     carry it. Fix in the fleet (target frame + 1, clamped at the clip's end) and in the learner and the
     gather (the policy's goal = the NEXT step's; the world model's reference input = the frame the
     servo actually used).
  3. **The normaliser from the kinematic data** (their Sec. 3.3: mean and spread from the database,
     offline): compute it from the reference tables at startup - which removes the frozen-normaliser
     problem (open item 3) at the root, and stops depending on early, bad simulated states.
  4. **L1 losses, weighted per quantity group** (theirs, for both models: positions, velocities,
     rotations, angular velocities, heights, up, each weighted to contribute equally at the start). Ours
     are L2 per normalised feature, so a group counts by its size (rotations 108 features, heights 18).
     Needs an L1 gradient kernel (sign(y - t) / n) and group weights.
  5. **Policy window 32** (theirs; ours 8 in the tests) - the latent model drifts 30.7 mm at 32 steps.
  6. **Gradient clipping** (they found it helps long windows).
  7. **ELU** (theirs; the kit has linear, tanh, relu).
  8. Minor: their L1 offset penalty beside the L2; RAdam rather than Adam.

*Possibly forgotten, for later:* world-space ROOT drift - local losses cannot see it; the paper adds
world-space root terms where drift matters (terrain), and our termination does include root error;
target joint velocities in the PD targets (ours none - their Sec. 5.1.3 shows it is fine); transfer and
fine-tuning between clips (their Sec. 5.2). The kit's parity tests are against OUR learner, so fixes 1-2
change both sides together and the tests move with them.

**D17 - the filtered action (Simon, Sep 21). Why it is worth trying.** Our PPO path already does this
(`robot_policy.zig`: `y = beta a + (1 - beta) y_prev`, beta = 0.2, DReCon's, with the filter's own
output in the observation); the SuperTrack path does not - it hands raw offsets plus fresh noise to the
simulator every step at 60 Hz. Three reasons to expect a gain: (1) smoother control has less
high-frequency content, which is exactly what a one-step world model predicts worst - and our world
model is the weak link the policy exploits; (2) white noise every 16 ms largely averages out inside the
servo's own response time, while filtered noise DRIFTS and explores far better per unit of disturbance;
(3) tracking corrections should be sustained, not twitchy.

**What it requires (not optional).** The applied offset depends on the filter's state, so the WORLD
MODEL must be given the APPLIED action, not the raw one - otherwise its inputs no longer determine the
next state and it is being asked to predict something it cannot see. Concretely:
  * The learner filters where the action becomes an offset and the fleet RECORDS the applied action
    (exactly how the PPO controller already works), so the world model keeps learning from what happened.
  * In a rollout the filter is a SECOND carried state beside `z`: `y_k = beta (raw_k + noise) + (1 - beta)
    y_{k-1}`, differentiable, with `y_{-1}` the previous record's applied action (zero at a segment's
    start, where the fleet resets the filter). On the kit that is one more recurrence in `lat_act`, written
    like `lat_advance` writes z - into the next row and a contiguous copy - and its `(1 - beta)` path in
    the backward pass.
  * The policy should SEE `y_prev` (our PPO observation does): a policy blind to its own control state
    cannot tell whether it is already pushing. In the row that means `[goal | filter | state | reference |
    action]` - the policy's slice the first `2F + A`, the world model's from `F + A` on, both still
    contiguous, the lead becoming `F + A`.

**The test (one budget, one A/B).** Train the CPU learner twice at the same small budget, beta = 0.2
against no filter, and compare: the world model's loss, the policy's in-model gain, and the real
simulator's mean time to failure. Cheap now that the slow tests take a minute; decisive either way,
because the mechanism it claims to help (the world model's accuracy) is measured directly.

**T9b, re-ordered by residency - one known answer per turn:** (1) per-buffer kit sizes; (2) the
reference tables and the feature ring with its append; (3) the gather kernel with normalisation,
checked against `LatentWorld.featuresAt` / `referenceAt` on the same records; (4) the world model
training on gathered windows, loss equal to the CPU model's on the same windows; (5) the policy
through the model on the kit (its forward, gradients, Adam - T9a's pattern again); (6) acting from the
mirror - **DONE**: the mirror's action matches the kit's own policy to **7.2e-9** over 8 rows x 35
actions, on trained weights, with the rows read straight out of the buffer the GPU used, so a
disagreement could only come from the weights or the arithmetic. This is the one thing the mirror must
get right: if the two ever part, the loop collects under one policy and improves another, and every
loss on the page would still look healthy; (7) **the page - the resident learner alone** (Simon, Sep 21:
no shootout; our best idea takes all the room). Already in place: the page names every kernel the
learner needs, and `latent.measureNormalizer(gpa, fleet)` is standalone and public, so a page can
measure the statistics without building a CPU world model to get them - and it is the natural home for
the paper's version, measured from the reference clips.

**The frame loop, by time budget rather than by count.** A callback runs rounds until its budget is
spent, then yields - the same code then fills a desktop and a phone alike, instead of a fixed number of
rounds that starves one and stalls the other. Two modes over that: **shown**, drawing every third
callback (20 fps is plenty to watch a character) and training on all of them; and **train only**, no
render pass and no UI at all, with a larger budget. The toggle is read every callback, so the page
stays responsive even while training flat out.

**Two things to design around.** A browser throttles its callbacks when nothing is drawn or the tab is
hidden, so the loop must never assume 60 wake-ups a second - which the budget already handles. And a
phone at full tilt throttles thermally: wall-clock progress can FALL while every loss looks healthy, so
the page shows training seconds against wall-clock seconds, making it visible rather than mysterious.

**Progress (Sep 21):** the driver now counts EXPOSURE and FAILURES as it collects - steps watched per
character, and the reference lost (a clip running out is survival) - which is exactly what the PPO
bench counts, so a milestone reached on either page means the same thing. The new page goes in
`examples/track_train`, beside the PPO bench rather than replacing it: the bench keeps its recorded
numbers for comparison, and the new page is free to be shaped around the learner. Its slice is the
bench's proven adaptive one (grow while frames come in under budget, shrink the moment one does not),
with the budget set by mode - about 50 ms when shown, which IS the 20 fps, and far longer when training
only, where nothing draws.

**BLOCKER found (Sep 21), before any page code.** A page cannot reach the learner through the facade
yet: `robot_latent_kit` and `robot_track_resident` import the kernel module BY PATH (`gpu/zn_mlp.zig`)
for their tests, so any module containing them contains that file too - and a page imports the same
file as its own named module `zn_mlp`. Exporting them from the facade gives exactly
`file exists in modules 'zn_mlp' and 'zimr'`. Proven by building a page, then reverted; pages build.
**Traced and settled:** a page's `@import("zn_mlp")` is a module `b.createModule`d PER PAGE from
`src/gpu/zn_mlp.zig`, so the zimr module can never contain that file - by path OR by name, since a
second instance is a second module. The house answer is already in the tree: a file inside the
facade's reach keeps tests that need a concrete kernel module in a SEPARATE `<name>_tests.zig`
(`robot_ppo_track` / `robot_ppo_track_tests`), which is why `robot_world` and `kit_mlp` are not in the
facade and it is.
**Done:** `robot_track_resident_tests.zig` split out and registered (build roots, aggregator,
doc_sync); both tests pass unchanged (world loss 1.434 -> 1.085; mirror 7.2e-9). Three of the driver's
operations became public on the way - drawing windows, a character's features, the policy's action
from the mirror - each defensible as something a page will want.
**Done too:** `robot_latent_kit_tests.zig` split out the same way - the tests turned out to need NOTHING
private (the two names that looked like it were words in prose), so the kit lost 1,341 lines of tests
and keeps 1,001 of implementation, which is the file split the review asked for as well. The facade now
exports `robot_latent`, `robot_latent_kit` and `robot_track_resident`, and A PAGE BUILDS - the blocker
is gone. All 18 kit tests and both driver tests pass unchanged (1.2e-5, 9.7e-8, 7.2e-9).
**The page EXISTS and BUILDS:** `examples/track_train` - 8 characters, networks 64 wide, windows of 8,
one world and one policy update a round, a servo-only warm-up of 200 steps that both measures the
normaliser and gives the servo's own mean time to failure on that device. Its slice adapts to a budget
set by mode (50 ms shown, 250 ms training only), and its panel shows rounds, updates, mean time to
failure against the servo's, character-steps a second, and motion trained against wall-clock spent -
the pair that makes thermal throttling visible. Four things had to be taken from the working page
rather than invented: the interface is a window with `u.text`/`u.button`, colours are bytes, the
kernel table is an `inline for` over the module's WHOLE kernel list (so a page must register every
kernel, not just the ones it dispatches), and the robot drawing walks the model's geometry itself.
**FIRST RUN ON THE PHONE (Simon, Sep 21).** 2,277 rounds: 4,860 s of motion trained in 159 s of wall
clock - **30x real time**, 1,865 character-steps a second - and the loop held up (the smoke test had
caught two faults first: the params uniform overwritten thousands of times a frame, fixed by one
RECORDING PER ROUND; and windows sampled from replay the ring never received, fixed by asking the ring
what it `held`). Mean time to failure **1.20 s against the servo's 2.22 s**.

**Read honestly, that is two problems, and one of them is mine.**
  1. **The comparison is unfair.** The policy's number is collected WITH exploration noise; the servo's
     was measured clean. Fix: judge the policy the way the servo was judged - `act(steps, 0)` on a short
     stretch every so often - and show that number beside the collected one, never instead of it.
  2. **The rest is the known failure mode:** a weak world model is easy for a policy to exploit, exactly
     as the CPU learner showed at small budgets (0.71 s against the servo's 0.89 s). More rounds of the
     same shape will plateau, not converge - what is short is world-model QUALITY per round, not rounds.
     The levers, in order: more world updates per policy update (the paper's ratio, not our 1:1), the
     normaliser measured from the reference clips rather than early flailing, D17's filtered action, and
     the paper's remaining deviations (policy window 32, L1 group-weighted losses, gradient clipping).

**Also measured: the slice never grew past ONE round a frame**, so a round already fills 50 ms - and at
8 characters x 16 steps that is the CPU's simulation, not the GPU's training. Train-only's larger
budget is the next number to read; beyond it, the character count is the dial, and after that Phase C.

**Next, in order:**
  0. **DONE (Sep 21): viewer mode, the judged number, and the leak.** Viewer mode steps at the wall
     clock with the noise off, pauses training, refreshes the mirror each frame, and gives a character a
     longer leash (termination x1.8) so losing the reference can be WATCHED rather than replaced at once
     by a restart. The panel now shows two numbers and never one: "while exploring" (the policy plus its
     noise, which is what collecting measures) and "the policy alone" (noise off - the only one
     comparable with the servo's). The leak was real and older than this page: `measureNormalizer` never
     freed its two working sums, which stayed invisible while it only ever ran on an arena the world
     model frees wholesale - a page passing an ordinary allocator is what showed it. Smoke test passes
     clean.
  0b. **THE REFERENCE ITSELF IS NOT STANDABLE (Simon saw it; Sep 21 measured it).** New measurement in
     `robot_dance`: on the baked get-up, feet are down on 217 of 600 foot-frames, floor clearance is
     fine (-4 mm to a few cm, so the lift is doing its job) - but when a foot is DOWN its sole is
     **35.9 deg from flat on average, 47.8 deg at worst**. That is standing on an edge, which the
     physical character cannot hold, so the servo burns its authority fighting the reference. Two
     traps found while measuring: a foot is TWO bodies here (foot + toe, and the toe is the lower),
     and the sole's angle must be taken from foot TO TOE rather than from a body axis one assumes
     points along it - the first said the feet never touch the ground at all, the second read 47 deg
     where the honest answer was 36.
     **(Sep 21, Simon) THE FOOT HAD NO DEPTH AND NO HEEL.** Its capsules lay AT the ankle (z = 0), so
     the sole was 2.7 cm below the ankle joint while a human ankle rides 7-8 cm up - and retargeting
     puts the robot's ankle where the capture's ankle IS. The robot's thin foot therefore hovered ~5 cm
     above the floor while the actor's foot was flat on it, and the per-frame lift only ever raises, so
     nothing pulled it down. Fixed in `humanoid_flex2.xml`: the sole drops to -.075 and a heel geom sits
     under and behind the ankle (shape only - no joint moved, no DOF added). Clips re-baked.
     **Result: the feet are the deepest part on 235 of 300 frames, up from 197, and down on 236
     foot-frames, up from 217 - but the TILT is unchanged at 35.7 deg.** Which tells us the tilt was
     never geometric: it is the ROTATION the retarget gives the foot.
     **And the capture says why.** Its ankle-to-toe line descends even on a flat foot, because the toe
     joint sits below the ankle and mocap skeletons have no heel; the robot's foot segment is parallel to
     its sole. Matching segment DIRECTIONS therefore tilts the robot's sole by that anatomical
     difference. At the standing frame the capture reads 26 deg (of which perhaps 20 is anatomy) and the
     robot reads 34 - so the rest-pose offset that should absorb it is not doing so.
     **Next measurement, which decides the cause:** the same angle on the CAPTURE's own ankle-to-toe,
     frame for frame. Flat there and tilted here means the retarget or the ankle's range is losing it
     (the model's notes already say the range was widened once for exactly this); tilted in both means
     the source motion is.
  1. ~~Viewer mode (Simon's request).~~ Watch the policy in real time: one character, no exploration
     noise, stepping at the wall clock rather than as fast as it can, and episodes allowed to run ON
     past where they would normally end - so a failure can be watched instead of being replaced
     instantly by a restart. Training pauses or slows while watching; the panel says which it is.
  2. **The honest judged number** (fault 1 above), shown beside the collected one.
  3. **The shutdown leak** the smoke test reports: allocations the page does not free at teardown.
     Harmless in a session, but it is the check that guards every page.
  4. Then the world-model levers, in the order listed above.

**Known answer:** rounds a second, simulated steps a second, and updates a second in each mode, and the
milestone times that follow - train-only should buy a clear multiple, or the toggle is not worth its
switch.

**T9 — Phase B's gate.** G1 on the get-up with whichever learner is ahead, on the phone, the time
recorded; the full gate; the chapters.

**After Phase B:** Phase C (the environment on the GPU) when the phone's sample rate is what limits
the best learner - with jobs.zig's workers (~3.4x on a phone, measured by the engine) as the cheap
step before it. Phase D's runtime MPC serves G2's robustness, not training speed.

### Phase R - A ROBOT THAT IS GENO (Sep 21: the new first step; SuperTrack on hold)

**Why we stopped.** Simon watched the policy in the viewer and said the feet never go flat. Measuring
that led somewhere much bigger than a bad frame or two.

  * **The captures are ALREADY Geno's skeleton.** Every one of the 35 joints in our LAFAN files is a
    Geno joint (Geno's other 40 are fingers), and only four offsets differ at all: the root's world
    placement, and three differences under 2 mm. The LAFAN files we use are the *resolved* dataset -
    retargeted onto Geno by the same author as the viewer Simon sent. **So retargeting by inverse
    kinematics is solving a problem we do not have.**
  * **The foot's 22 degrees are anatomy, not error.** In BOTH of Geno's rest poses - bind (A) and
    stance (T) - with the foot flat on the floor, the ankle-to-toe line DESCENDS: 23.3 deg bind,
    21.9 deg stance, because the toe joint sits below the ankle and a mocap skeleton has no heel. Our
    robot's foot segment is horizontal, so matching segment DIRECTIONS tilts its sole by that amount.
    Measured on our reference: 35.7 deg average tilt when a foot is down, and 100% of down-frames "on
    an edge". A capture frame reading 26 deg is really a foot 4 deg off flat.
  * **And the foot had no depth** (already fixed: sole 7.5 cm below the ankle, heel geom added). Geno
    says 7.4-8.35 cm, so our number was right by luck. It should be DERIVED from the skeleton.

**The decision: build the robot from Geno's own measurements, and make retargeting an identity.** The
learner, the resident loop, the pages and the kit are untouched by this - they take a model and a clip.

**The experiments, each with the answer that decides it.** Source: `GenoView`'s resources
(`Geno_bind.bvh`, `Geno_stance.bvh`, `Geno.bin`, the export scripts), which Simon supplied.

  * **R1 - the skeleton, exactly. DONE (Sep 21).** `src/robot_geno.zig` reads Geno's own pose files -
    both now fixtures - into bones with parents and offsets in metres, doing its own kinematics rather
    than the renderer's, because the robot's tests run in a shader-free tier (and because the offsets
    then come straight from the file instead of being recovered from a pose). Measured through our own
    code: **hips 0.855 m, thigh 0.382, shin 0.399, ankle-to-toe 0.153; the ankle sits 0.083 m up and its
    toe 0.023 m; the rest sole descends 23.3 deg (bind) and 21.9 deg (stance); 96 bones, and bind and
    stance are the SAME skeleton to 0.0000 m** - they differ only by rotations. The test asserts each of
    these, so a change in the parser, the codec or the files shows up here rather than as a robot that
    silently stopped matching its captures.
  * **R1 (superseded wording) - the skeleton, exactly.** Build the robot's bodies from `Geno_bind.bvh`'s offsets (cm to m),
    same hierarchy minus the fingers. **Known answer:** the robot's forward kinematics at its rest pose
    reproduces Geno's bind-pose world joint positions to under 1 mm, joint for joint.
  * **R2 - which rest pose.** Bind (A) and stance (T) share every OFFSET and differ only by rotations.
    Declare which one the robot's zero pose is; keep the other as a stored pose. **Known answer:** the
    ankle-to-toe descent is 23.3 deg in bind and 21.9 in stance - the anatomy constant, written down
    once, in the model.
  * **R3 - the sole plane, derived.** In the bind pose the floor is y = 0 and the ankle is 8.35 cm up.
    Place the foot, heel and toe geoms so the sole IS that plane. **Known answer:** posed at bind, each
    foot's lowest point is 0 +- 5 mm, and heel AND toe both touch.
  * **R4 - geoms that fit the mesh: METHOD SETTLED (Sep 21).** `Geno.bin` is the skinned mesh IN THE
    BIND POSE (10,329 vertices, metres, y-up, standing on the floor - lowest point -5 mm) with four bone
    weights per vertex and every joint's world bind transform. Each vertex belongs to its strongest
    bone; fingers fold into their hand and `Neck1` owns nothing, leaving 23 bodies. Three methods,
    judged by R4's criterion (share of a bone's vertices within its geom + 1 cm) AND by volume, so a
    shape cannot win by being enormous:
      - capsule ALONG THE BONE (joint to child): 98.1% covered, **254 litres** - bloated wherever the
        flesh is not centred on the bone;
      - capsule along the vertices' PRINCIPAL AXIS: 97.9%, **132 litres** - half the volume;
      - **SHAPE BY REGION** - principal-axis capsules for the round parts (thighs, shins, arms,
        forearms, neck, head, toes) and principal-axis BOXES for the flat ones (hips, the four spine
        segments, shoulders, hands, feet): **98.6% covered, 108 litres.** The torso is where it pays
        (Spine: 92.9% in 14.8 L as a capsule, 98.4% in 8.3 L as a box), and the feet get what they
        most need - a FLAT SOLE.
    **And mass must NOT come from these volumes:** 108 L would weigh 109 kg, because neighbouring geoms
    overlap at every joint and a box fills its corners. R5 measures the mesh's own enclosed volume,
    region by region, instead.
    **Shown (Sep 21): `examples/geno_fit`** - the 23 fitted shapes riding Geno's bones through the whole
    get-up and ten seconds of the dance, driven straight by the captures' rotations, with the capture's
    skeleton drawn over them. The shapes are generated by `tools/geno_fit.py` (the prototype that
    settled the method; a Zig generator should replace it and keep its rule) in WORLD BIND coordinates;
    the page runs the bind pose through the same kinematics it animates with and attaches each shape to
    its bone from there, so the frame a shape is attached in and the frame it is moved by cannot
    disagree. The feet's boxes are aligned with the floor, not their vertices' principal axes: in the
    bind pose the sole IS horizontal, and a slightly tilted principal axis would put back the very tilt
    this phase removes. Both captures are 60 fps, so `getup_frames`' alignment was right after all.
    **Simon's first look (Sep 21): only the feet should be boxes, the rest pills - fitted well, looking
    good, SYMMETRIC.** Done in the generator:
      - **Pills everywhere but the feet** - foot and toe both floor-aligned boxes, so the sole is flat
        from heel to toe tip.
      - **Symmetry by construction, not by averaging afterwards.** A left/right pair is fitted ONCE, on
        the left bone's vertices together with the right bone's mirrored across the centre plane (x = 0
        in the bind pose), and the right gets that shape mirrored back. A centre bone is fitted on its
        vertices plus their own mirror image. Both sides now match exactly, and each fit uses twice the
        data.
      - **The torso's pills run ACROSS the body.** One pill per segment tops out near 93.5% of the
        torso's vertices whichever way it runs; across does it in 66 litres against 72 upright, gives the
        familiar stacked look, and lets segments roll against each other as the spine bends. Forced for
        all five segments so the stack is consistent (it lifted the hips from 92.3% to 94.0%).
    **Fit, against each bone's OWN vertices: 98.0% overall within 1 cm; limbs, head, neck, hands and
    feet 97-100%; the torso segments 90.5-94.5%, which is the single-pill ceiling.**
    **Simon, lying down in the get-up: every shape must be out of the ground.** Two findings, two fixes.
      1. **The capture itself puts Geno's MESH through the floor** - skinned exactly (the bind pose gives
         back the mesh to 0.000001 m), it is below the floor on nearly every frame: 1.8 cm standing
         (Geno's hips sit 4 cm lower in the capture than in its own bind pose), and 12.7 cm with the
         HEAD while lying. LaFAN-resolved moves Geno's skeleton on the actor's trajectory; a character
         built differently from the actor then meets the world differently. So the reference must be
         LIFTED per frame by the new body's lowest point, as our old clips were. The viewer does it now:
         each frame's need is widened to its neighbours' largest (a quarter-second envelope) and THEN
         smoothed, so the lift is never below any frame's need and moves like a body, not a spring.
      2. **The shapes bulged out of the mesh** - on 202 of 270 sampled frames some shape reached more
         than 5 mm below the posed mesh (the thighs by 7.2 cm, kneeling). A capsule cannot taper and a
         limb does, so a uniform shrink would have left sticks. `geno_fit.py` now skins the mesh through
         the captures and gives each shape the change that REMOVES THE LEAST VOLUME while keeping it
         within 3 mm of the mesh on every frame: pulling either end in, thinning, or both. It takes 4 s.
         The thighs keep their girth (knee end in 11 cm, 77% kept); shoulders and head are fixed by
         retracting an end; the hands (7% kept) and hips (20%) must thin, because a flat hand and a
         shallow pelvis can only hold a round pill inside them by its being slim.
    **Simon, on the dance: "elbows should still connect", "a bit more athletic - smaller belly, a bit
    bigger torso" (fit may be poorer), and "show the mesh, under a toggle". Done:**
      - **Connection is now a rule of the fit.** The motion search had pulled the upper arm's elbow end in
        8 cm with nothing to say the elbow must stay covered. Limbs now keep their FLESH's principal axis
        (a capsule on the bone line pokes out the front of the shin, where the tibia sits) but span joint
        to joint along it, and the search - parent before child - must keep >= 1.5 cm of overlap with
        each neighbour. (Tried first: every chain joint INSIDE both neighbours - too strong, the thighs
        kept 24%.) Result: elbow 2.5 cm, wrist 7.3, knee 10.5, hip-pelvis 1.7, neck 5.0 / 12.3; thighs
        keep 77%, shins 90%, pelvis 61% (was 20%).
      - **The torso is built from cross-sections, then made athletic.** Vertex ownership had made a pot
        belly: Geno's skin weights give the waist's sides to the belly bones (pills 12-13 cm wider than
        the waist, 3.7 cm out in front) and leave the lower chest a thin band at the back (9.6 cm behind
        the front). Now each torso pill takes the whole torso's front, back and width at its height.
        ATHLETIC, applied last so the fit cannot undo it, back always held: belly depth x0.85 / width
        x0.90, waist x0.88 / x0.92, chest x1.08 / x1.08. Widths run 0.25 -> 0.23 -> 0.30 -> 0.35 m; belly
        3.1 cm flatter than the mesh, chest 1.7-1.9 cm fuller; pills overlap 5-12 cm, no gaps.
      - **The mesh, under a toggle.** Geno.fbx (the retargeting demo's) supplies mesh and weights only;
        each model bone is skinned by its carrier (itself, or its nearest carried ancestor - fingers ride
        the hand) as `world_now * inverse(world_bind)`, both from this page's own kinematics, so mesh and
        shapes cannot disagree about a bone. See-through while the shapes are on. Page 7.4 MB.
    **Simon: "remove the shoulder and reduce neck".** The clavicle pills are gone (21 shapes); the arm
    meets the chest pill directly (1.6 cm). The neck's radius is now its COLUMN's - the median flesh
    radius over the middle of the neck, 5.8 cm, not the 90th percentile, which caught the trapezius
    skirt (7.2) - times 0.75: 4.4 cm.
    **And a silent failure found on the way.** Searching parent before child let the upper arm spend the
    elbow's whole overlap (its end in 7 cm), so the forearm - poking through at the same elbow - had no
    room and was KEPT AS FITTED, 2 cm through the mesh, since the previous build; nothing reported it.
    Two fixes: that fallback now prints a warning, and the shapes are CHOSEN TOGETHER - each connected
    chain is a tree, so dynamic programming finds the exact least-volume-lost combination in which every
    shape stays inside the mesh and every connected pair overlaps >= 1.5 cm (each shape's options: every
    pair of end pulls with its least sufficient thinning; more thinning never helps an overlap). The
    elbow is now shared: arm end in 2 cm and 2 cm thinner, forearm end in 4 cm; overlap 2.4 cm. The
    athletic torso is DESIGNED first and left as designed, so arms and neck are chosen against the torso
    they really meet (fitting against the pre-athletic chest, the slim neck could not reach 1.5 cm).
    **Then: place each geom in its bone's frame AS THE CAPTURES DEFINE IT** - the BVH bind pose's own
    joint frames, not Maya's joint orients, which need not agree - and show it on the get-up and the
    dance, driven straight by the captures' rotations, for Simon to judge by eye.
  * **R4 (original wording) - geoms that fit the mesh.** `Geno.bin` carries the skinned mesh and its bone weights: for each
    bone, fit a capsule to the vertices that bone dominates. **Known answer:** at least 95% of a bone's
    dominant vertices lie within its capsule plus 1 cm, and no capsule overlaps a non-adjacent one at
    rest.
  * **R5 - mass and inertia from the body, not from guesses.** Segment volumes from the fitted geoms at
    a uniform density. **Known answer:** total mass about 70 kg at Geno's height, and each segment's
    share within 20% of published anthropometry.
  * **R6 - joint ranges from the data.** For a library of captures (walk, run, dance, get-up, stumble),
    measure the angle every joint actually uses. **Known answer:** limits containing 99.5% of the
    library, with the excess named per joint; no frame outside a limit by more than 2 deg.
  * **R7 - retargeting becomes a copy.** With the bones matching, tracking a capture is copying
    rotations: no IK, no alignment offsets, nothing to tune. **Known answer:** every joint's world
    position within 1 mm of the capture's on every frame of the get-up, and the sole tilt on a standing
    frame under 5 deg.
  * **R8 - is the reference standable now.** With the identity retarget: sole tilt when a foot is down,
    penetration, and how often a foot is the deepest part. **Known answer:** tilt when down under 8 deg
    on average, nothing deeper than 1 cm, feet deepest on nearly every standing frame.
  * **R9 - the ragdoll holds a pose.** Put the robot at a standing capture frame with the servo holding
    that frame. **Known answer:** the root drifts under 2 cm in 2 s, and no joint sits on a limit.
  * **R10 - the servo alone, on the new robot.** No learning: the servo following the get-up.
    **Known answer:** a mean time to failure well above today's 2.22 s - and it becomes the number every
    learner is measured against from then on.

**Then SuperTrack resumes**, on a robot whose reference is physically possible. Everything built so far
still applies: the resident loop, the mirror, the slots, the page and its train-only mode.

### Review, Sep 21 - the form, and what native GPU and a GPU simulator will ask of us

**What is already right, and should not be disturbed.** The device seam is `Compute(M)`: the learner
code touches `upload`, `uploadAt`, `run`, `params` and `readLatest`, and every WebGPU handle lives
inside the host. Kernels are Zig, transpiled - so a native SPIR-V backend is a change to ONE file, not
to the kit, the resident data, the driver or any test. What makes that swap safe is the CPU twin: every
kernel has a plain-Zig implementation, and every GPU path is checked against it on identical inputs, so
the same tests judge whichever backend is underneath.

**Done today: the resident layouts are named once.** A record (raw features, the action taken, and the
reference-table row aimed at) and a table row (a frame's features, then its servo targets) were spelled
out twice - in the host that packs them and in `lat_gather` that reads them. They now live in the
kernel module both sides already import (`latRecordWidth`, `latRecordAction`, `latRecordTableRow`,
`latTableWidth`), because the third party arrives with the GPU simulator: a kernel that WRITES records.
The kit's tests are unchanged to the digit, and a page still builds, so the helpers transpile.

**Next, in order of value:**
  1. **Split `robot_latent_kit.zig` (2,332 lines)** into the networks' kit and the resident data - two
     concerns that only share a buffer. The rest of the stack is already one concern per file.
  2. **Readback by range, per field.** `element_count` is a single global "how much of EVERY buffer
     comes back", which the driver widens from a distance - a web-flavoured simplification (one staging
     copy a frame). `request(.params, offset, count)` would be clearer and is what native wants anyway.
     It touches every user of the host, so it is a deliberate change, not a drive-by.
  3. **What a GPU simulator still needs from us.** The records are already the right shape - flat rows
     in a device buffer, one write per step. What remains CPU-shaped is the BOOKKEEPING: restarts,
     failures, which clip a character is on, and the window sampling that knows where episodes begin
     and end. Naming that contract the way the layouts are now named is the next step, and it can be
     done long before any kernel exists.
  4. **The storage-buffer floor is a web limit.** Tables and ring share the activations buffer because
     a compute stage is guaranteed only eight storage buffers on WebGPU. Now said where the design is
     described, so nobody later reads it as physics.

**Still open, unchanged by this review:** the paper's remaining deviations (normalise from the
kinematic data - `measureNormalizer` is now the natural home; L1 group-weighted losses; a policy window
of 32; gradient clipping; ELU; RAdam), D17's filtered action, and the page (rung 7).

### Phase C — The simulator on the GPU (T10-T15)

Same rungs as before, now with a purpose: fifty times the data for every experiment after it.

**T10 — State layout and forward kinematics** (parity with robot.zig, 1e-5).
**T11 — Bias forces and inverse dynamics** (RNEA per world, 1e-4).
**T12 — Mass matrix, Cholesky, forward dynamics, integration** (M(M⁻¹τ) = τ; momentum and energy
conserved gravity-free; 60 steps against robot.zig).
**T13 — Contacts** (capsules and spheres against the floor, PGS): a resting humanoid's normal
forces sum to its weight within 1%; a slide stops within v²/2μg ± 5%; a drop penetrates < 1 cm.
**T14 — The servo, episodes and resets on the GPU**, plus the tracking reward and observation
kernels: each matches its CPU twin to 1e-5, and the zero-action episode-length distribution matches
the CPU gym's within 10%.
**T15 — Throughput and residency:** W = 64…4,096; ms per control step on desktop and phone;
rendering straight from the pose buffer; the whole training loop with nothing but scalars read back.
**Known answer:** SuperTrack reaches T8's quality from the same seed, only faster.

### Phase D — The hybrid (T16-T21)

**T16 — The critic.** SAC/CrossQ on the same replay and reward, resident. **Known answer:** its
value predicts the discounted tracking return on held-out states (correlation, and calibration
against Monte-Carlo returns).

**T17 — The critic in the policy.** The value at the window's end as a terminal term in the BPTT
loss. **Ablation:** G1 and G2 with and without it, same budget and seeds.

**T18 — MPC over the world model.** MPPI, 8-16 frames, the policy as the prior, the critic as the
terminal value; batched over worlds on the GPU. **Known answer:** on a perturbed state it finds an
action sequence with lower predicted tracking cost than the policy's, and the real simulator agrees.

**T19 — MPC at runtime.** Frame budget, warm starts, how many samples are worth it. **Ablation:**
G2 with and without MPC; ms a frame on desktop and phone (G4).

**T20 — MPC in the loop.** Data collected with MPC-refined actions, the policy trained on it -
does the policy inherit the recovery? **Ablation against T17.**

**T21 — G3: the table.** Each part's contribution to quality, robustness, samples and runtime cost.
Parts that earn nothing come out.

### Phase E — Quality and robustness (T22-T26)

**T22 — All four clips to G1**, one policy per clip. **T23 — G2: the perturbation campaign**
(curriculum during training; a fixed battery for reporting). **T24 — One policy, four clips** (the
clip as part of the observation): does it hold quality? **T25 — The differentiable simulator**
(E3: the step's adjoints, checked against finite differences) and policy gradients through it,
against the world model's, same budget. **T26 — The phone:** G4 end to end, and what has to give.

### Phase F — The interactive layer, and the close (T27-T30)

**T27 — Motion matching** on the GPU: the feature database from the tracking set and the
motion-matching clips, a brute-force search kernel, inertialised transitions - the kinematic
controller a player steers. **T28 — DReCon:** that controller as the reference, the tracker
underneath, trained as Phase D ended up recommending. **T29 — The comparison and the tutorial**
(every method, its numbers, its chapter). **T30 — The full gate, the pages on the phone, the
retrospective.**

## 7. Decisions, and when they are taken

| | decision | taken at | by |
|---|---|---|---|
| D1 | the elbows: both ranged hinges? **TAKEN (T1): yes** - on the dance the hinge forearm is 16° off the capture on average (47° worst) against a ball's 35° (88°), with no 0.41 rad twist snap; the upper arm pays 9° → 14°. Guarded by the D1 test. | T1 | the dance audit |
| D2 | the contact model on the GPU: PGS soft constraints, or penalty | T13 | T13's known answers at 120 Hz |
| D3 | thread- or workgroup-per-world, per kernel | T15 | measured ms per step |
| D4 | residual actions throughout (taken: every method in §2 is residual) | - | - |
| D5 | AMP at all, given the focus on tracking | T29 | whether G1-G3 leave room |
| D6 | the world model's size and windows. **TAKEN (T6b-d): 256 wide** (512 overflows the kit's 2^18-float buffers), **and the window is whatever the drift curve licenses - 8 frames today** (61 mm), not 32 (1.42 m) | T6d | the drift curve on the ground |
| D7 | Phase F's extra method | T29 | what G1-G3 leave open |
| D8 | the reference's floor penetration **TAKEN (T4): lift each frame by what it needs, smoothed** - the only option right on both sides (see the schedule) | T4 | geometry, with the root held |
| D9 | one policy per clip, or one policy for all four | T24 | quality at G1's bound |
| D11 | the residual policy's size and its subsets: how small the two networks, which bodies in the observation, which joints get offsets | T7 | which reaches T7b's bar soonest |
| D12 | the reward's shape: our weighted sum of exponentials, or DReCon's sum-INSIDE-the-exponential, which forces fixing the worst-tracked body | T7 | episode length, as DReCon's own Fig 14 compares it |
| D13 | the order of the ladder (§2) past T8 - which sample-efficiency method next, decided by minutes saved on the phone, not by which paper is newest | after T7e, and after each rung | the bench |
| D14 | the weights file: versioned, carrying the network's shape and the optimiser's state, so an upload either continues the run exactly or is refused by name | **T7c** | a round trip across seeds |
| D15 | ~~the world model's form~~ **RESOLVED (T8c): LATENT** - 15.5 vs 247 mm pose drift at 8 steps, 30.7 mm vs 7.9 m at 32, same data and budget: STRUCTURED (accelerations, integrated; new adjoint kernels) or LATENT (next features directly; a chain of MLPs the kit already backpropagates) | T8c | drift at 8 and 32 steps, per line of new code |
| D17 | a FILTERED action for the SuperTrack path (Simon's idea): the policy emits a raw offset, the simulator applies `y = 0.2 a + 0.8 y_prev` - DReCon's smoothing, which our PPO path already uses | T9b, after the page | the world model's loss, the in-model gain, and the real simulator's mean time to failure, filtered against unfiltered at one budget |
| D16 | the root assist: a scheduled wrench faded to zero, or RFC's learned residual wrench with a penalty that grows | T8b | minutes to milestone on the phone, judged at zero assist |
| D10 | ~~the policy BPTT window early on~~ **MOOT: the 21-frame segments were the missing floor; standing, episodes average 46 frames and 32-step windows are always available (200/200)** | T7 | measured |

---

## 8. Tutorial chapters (kept in sync as each lands)

Existing chapters change as their code does: 3 (the clips), 5 (the model), 6 (auditing and what
grounding cannot fix), 7-8 (the servo and the floor), 10 (the task, the gym, the learners), 11
(SuperTrack on the humanoid: the state, the actions, the rings, the world model and how it is
judged), 12 (the kit, and an ordinary network on it), 13 (pages). New chapters, each added in the
turn its code lands: **tracking by PPO: DReCon's feedback policy on one clip** (T7), **the GPU
world** (T10-T15), **the hybrid: critic and planner** (T16-T21), **gradients through the simulator**
(T25), **motion matching** (T27), **DReCon, whole** (T28), **the comparison** (T29).

---

## 9. Risks, ranked - the early warning, and the fallback

1. **★ A measurement made in the wrong world.** The floor bug made three turns of numbers describe
   a character in free fall, and every individual test passed throughout. Warning: any result that
   is suspiciously identical across conditions that should differ - that is what exposed it.
   Fallback: standing rule 7's guard on every environment, and a control beside every experiment.
2. **PPO on the CPU is too slow for even one short clip.** **Measured: 2,642 env-steps/s**, so 20M
   samples is 2.1 hours of background time and 100M is half a day. Warning: T7b's episode-length
   curve stalling while the sample count climbs past ~20M. Fallback: T7 waits for Phase C's
   simulator; T8's SuperTrack path does not depend on it, and neither does Phase D.
3. **The get-up doesn't track** (contacts on hands and back, no height test for "fallen", and
   DReCon's authors call it unsolved). Warning: T7b, with the walk slice beside it as the control.
   Fallback: it becomes its own milestone after Phase D, with the hybrid's planner - the part most
   likely to find a way onto its feet - and G1/G2 are reported for the other three meanwhile.
4. **GPU physics too slow, or unstable, on the phone.** Warning: T15's ms per step. Fallback:
   physics on CPU workers, learning on the GPU - today's architecture, which works.
5. **GPU contacts disagree with robot.zig.** Warning: T13. Fallback: a GPU contact model with its
   own known answers (rest = weight, slide = μg, drop penetration < 1 cm); the CPU twin keeps the
   GPU honest either way.
6. **WGSL and WebGPU limits** (bindings per stage, buffer size, workgroup memory) - and the kit's
   own 2^18-float buffers, which a 512-wide network already overflows. Warning: T10-T12, and D6.
   Fallback: split kernels; raise the kit's buffer size deliberately, not by accident.
7. **The policy games the metric** (standing still survives). Metrics are error to the reference, and
   termination fires on error as well as on falls.
8. **The phone is slower than any estimate made here.** Warning: T7e's env-steps a second on the
   device. Fallback: fewer environments a frame (the frame budget adapts), the simulation moved to
   a worker (`jobs.zig`), and - the real answer - Phase C's environment on the GPU. The plan's point
   is to make the method need fewer samples, which helps every device alike.
9. **The schedule is long.** Warning: any phase gate that needs more turns than its rungs.
   Fallback: Phase F shrinks first (motion matching, and DReCon's kinematic half), then Phase E's
   extras; G1-G3 are protected. T7 is deliberately early so that the project owns a tracking
   result - any tracking result - before the expensive phases start.
