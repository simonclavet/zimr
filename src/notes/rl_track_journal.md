# rl_track_journal.md - the history of the RL / tracking track, Sep 19-20 2026

This is the old `rl_track_plan.md`, kept VERBATIM below as the record: every measurement, every
bug and what it taught, every decision and why. The forward plan now lives in
`rl_track_plan.md`; new dated entries go at the END of this file, one per turn.

---

# rl_track_plan.md — a ragdoll that tracks 5 seconds of the dance, trained in a few hours on WebGPU

**Status: ACTIVE, Sep 19 2026 (2163).** Supersedes the ordering in `servo_ladder.md` §8.4 for the
learning half; the controller half (§8.5-§9) is what this plan stands on. `drecon2.md` keeps the
method history (0a: why SuperTrack; §3: "ten minutes, honestly"; 7b: its adversarial review).

## 1. The goal, stated so it can fail

`humanoid_flex2`, free root, real floor, 60 Hz physics, follows the first **5 seconds** of
`dance1_20s.bvh` (retargeted, 5 Hz filtered, grounded — servo_ladder §8.8) **without falling and
with mean worst-body error under 15 degrees**, from a policy trained **in the browser on WebGPU
in at most ~3 hours** of wall time. The metric is the one the free-root rungs already print.

## 2. The arithmetic that decides everything

    hours = samples needed / samples per second

**Samples per second — measured, not guessed:**

    HumanoidEnv, 21 hinges, 30 Hz policy / 60 Hz physics, native ReleaseSafe, 1 core   ~2,300 /s
    per physics step on a phone (ragdoll_compare, wasm):  reduced 391-735 us, maximal 96-194 us

`humanoid_flex2` (36 DOF) with contact-consistent inverse dynamics will cost more — budget
~1,000-1,500 samples/s per thread natively and ~600-1,000 in wasm until measured (P3).

**Samples needed — the literature, and why ours should be far lower:**

    DeepMimic, PPO, one clip from torques-ish PD targets       ~60M (walk) to 200M (acrobatics)
    DReCon, PPO, a whole database                               3e8 steps, 30 h
    SuperTrack, world model, a whole database                   basic balance at ~10k iterations
    Isaac Gym / MJX style PPO, one clip, 4,096 envs on a GPU    tens of M, minutes

Ours is one short clip, and the policy does not learn to MOVE: `Tracker` + exact inverse
dynamics already follow the dance locally within 7 degrees (B2) — the policy learns only the
balance correction (servo_ladder §8.10: 0.6 s of following with no help). That is DReCon's premise
with a much better controller underneath. **Working guess: 10-30M samples for PPO.** P2 measures it.

**What that means:**

    samples     1 thread (1.2k/s)   8 threads native (10k/s)   4 web workers (3.5k/s)
    10M         2.3 h               17 min                     48 min
    30M         7 h                 50 min                     2.4 h
    100M        23 h                2.8 h                      8 h

*** **THE WHOLE PLAN TURNS ON ONE NUMBER P2 PRODUCES: samples-to-success for PPO on our stack.**
Under ~30M, PPO + CPU workers + a GPU learner reaches the goal. Over it, the plan switches to
the sample-efficient method (P7) rather than trying to buy throughput.

## 3. The architecture

    N humanoids (64-256), lockstep ──obs──> GPU: policy forward for all N (one dispatch)
      CPU physics, split across workers <──actions──
      rollout buffer (N x T samples) ───────> GPU: PPO update (minibatches, epochs, Adam)

* **Simulation stays on the CPU.** A GPU physics port is the only road to thousands of envs,
and it is a project of its own; the budget above does not need it. Revisit only if P2's number
is large AND the world model (P7) disappoints.
* **The network goes to the GPU because of the UPDATE, not inference.** One PPO iteration over
64k samples x 10 epochs through a 76-256-256-21 MLP is ~3.5e11 flops: ~35 s on one CPU core,
well under a second on a desktop GPU, a few seconds on a phone's. Inference for N characters per
step is small either way.
* **100 characters in one scene, not colliding with each other.** Each is its own `robot.zig`
model and data, so they never interact through their dynamics; the only shared thing is the
floor. The cheapest separation is SPACING — a grid 4 m apart, which the broadphase separates for
free — rather than collision groups; groups become necessary only when characters must share
ground. What batching buys is not cheaper physics (the cost is linear in N) but: one policy
dispatch for all, one rollout loop filling N x T samples, and a natural split across workers.
* **Threads in the browser.** Web Workers need SharedArrayBuffer for shared memory, and that needs
cross-origin isolation (COOP/COEP headers): available from a proper server, NOT from a standalone
HTML opened from the phone's files. Without it, workers exchange observations and actions by
message (100 x 76 floats per step is ~30 KB — cheap). Design for message passing; use SAB where
it exists.

## 4. The path — each milestone one number, headless and native before the browser

    P1  PPO learns LOCOMOTION on HumanoidEnv (robot_gym.zig), native, one thread.
        Number: mean episode length rising above the statue's 37.6 steps; return vs samples.
        Why first: it proves zimrnum's PPO loop (Gaussian policy, value net, GAE, observation
        normalisation) on OUR physics before the harder task, with published curves to compare.

    P2  DanceEnv: humanoid_flex2 tracking the 5 s clip. Action = offsets on the REFERENCE frame
        (DReCon), reference-state initialisation (start at a random frame), early termination
        (a fall, or worst-body error over ~45 deg), DeepMimic-style reward exp(-k x error) per
        term. PPO, native.
        Number: SAMPLES TO SUCCESS (§1's metric). The decision point of the whole plan.

    P3  Batched stepping: N characters lockstep, std.Thread workers natively.
        Number: samples/s vs threads (target: linear to 8).

    P4  The maximal engine as the simulator (4x cheaper per step on a phone).
        Number: P2's samples-to-success on it, and wall time. Trades controller quality for speed;
        DReCon itself used a maximal engine with PD motors.

    P5  GPU learner: zn_train generalised from its two-layer network to the PPO update — a
        3-layer Gaussian policy and value head, the clipped surrogate, Adam — each kernel checked
        against the CPU path by the existing sweep contract.
        Number: ms per PPO iteration, desktop and phone.

    P6  The browser: workers for physics, WebGPU for learning, a few characters drawn live, the
        networks saved as files (drecon2 §5). Number: §1's goal, end to end.

    P7  (only if P2 says PPO needs too many samples) SuperTrack: a world model trained on
        collected transitions, the policy trained by backpropagation through it. zimrnum already
        has it in miniature and an MPC-data world model that beat random-action data (drecon2 0d).
        More GPU, far fewer samples — the method drecon2 0a chose for exactly this budget.

## 5. What could go wrong, ranked

1. **P2's number is 100M+.** Then P7, not more threads. Mitigations inside P2 first: a shorter
   first target (1 s, then 2 s, then 5 s), a curriculum on the filter cutoff.
2. **The low-level controller costs too much per sample.** Contact-consistent ID is a dense solve
   per substep; floating-base ID is cheaper and was enough for joint tracking. Measure both in P3.
3. **zn_train's generalisation is bigger than it looks** (Gaussian log-probs, clipping and Adam
   on the GPU with CPU parity). Mitigation: the CPU learner is correct already; the GPU only
   has to match it, kernel by kernel.
4. **Browser threads**: no SharedArrayBuffer from a standalone file. Message passing is designed in.
5. **The policy learns to cheat the metric** (drecon2 7b/A1: standing still survives). The metric
   is error-to-reference, not survival, and early termination is on error as well as falls.

## 6. Journal

- **Sep 19 — P1 wired, the first curve flat.** `robot_gym.zig`'s P1 test trains zimrnum's own PPO
  on `HumanoidEnv`: a 76-64-64-21 Gaussian policy and a value net built on zimrnum's graph (bias
  through a ones column: the graph's `add` needs equal shapes), clipped surrogate + 0.5 x value
  loss, GAE(0.99, 0.95), 2,048 steps an iteration, 5 epochs of 256-sample minibatches, Adam 3e-4,
  running observation normalisation. ~4 s per PPO update on one CPU core.
  * **A library fix on the way:** `ppoClipLoss` returned shape [1] while `mseLoss` and
    `crossEntropy` return [1, 1], so the loss `PpoModel`'s own doc calls typical - clip plus value
    loss - failed with ShapeMismatch. Now [1, 1]; zimrnum's RL tests pass.
  * **The curve: 16.1 -> 17.0 steps over 30k samples - the RANDOM level (15), not the statue's
    37.6.** The starting policy explores with sigma ~0.6 times the 0.5 rad action scale: +-0.3 rad
    of flailing on every joint, so it starts below the statue, and 30k samples is little for a
    humanoid. **Next: start near the statue (log-std -1.5), then ~250k samples.**
- **Sep 19 — the phone run, and a leak.** `rl_humanoid.html` on Simon's phone: **1,311 samples/s**
  (wasm, one thread - the plan's estimate held), 1.4 s per PPO update, mean length flat at 29-31
  through 13 iterations, and the memory watchdog: +250 MiB per ~100 frames.
  * **The leak was zimrnum's `Graph.backward`**: ~20 op backwards and `matmulBackward` allocated
    temporaries from the graph's allocator and never freed them - harmless for a throwaway graph
    in an arena, ~60 MiB an iteration for PPO's one graph reused minibatch after minibatch. Now a
    per-pass `Graph.scratch` arena, reset at every `backward`; long-lived graphs give it a real
    allocator (`useScratchAllocator`), because a reset that keeps capacity merges buffers into a
    fresh allocation that an arena parent can never free. **~80x smaller; a residual of ~0.75 MiB
    an iteration is still open** (P1's test bounds it at 8 MiB over 8 iterations and prints it).
  * **Why nothing learned: `ppoUpdate` steps PLAIN SGD** (its doc said Adam), and the trainer used
    Adam's 3e-4. Now an SGD rate of 0.02, with rewards scaled by 0.05 so value targets stay near
    unit size; the doc says SGD. Adam in `ppoUpdate` is the better fix, and the next one.
  * Also: zimrnum's "source is ASCII" test had been failing since the previous turn's comment -
    run the FULL zimrnum suite after touching it, not a filtered one.
- **Sep 19 — watching the result, and 30 fps.** `PpoTrainer.updateSlice` does ONE minibatch
  (advantages from GAE normalised over the whole rollout once, rows shuffled each epoch, a
  256-row chunk to `ppoUpdate`), and `policyMean` gives the policy's noise-free action.
  `rl_humanoid` now trains for 25 ms a frame in slices (8 env steps, or one minibatch) and
  shows a SECOND humanoid running the current policy in real time - the result - with its
  episode length and distance walked. The smoke test passes whole again (its shutdown check
  included), ~2,000 host calls a frame instead of ~8,300.
  * Natively, the sliced update ended P1 at 14.5 steps where the unsliced one sat at ~30: with
    plain SGD at 0.02 the policy now moves, the wrong way. **Adam in `ppoUpdate` is next.**
- **Sep 19 — Adam, and why the phone showed a star pose.** On the device the sliced SGD trainer
  settled at 14.3 steps (random level) with the watched policy in a STAR POSE: its mean action
  saturated at the +-0.5 rad offset clamp on many joints - SGD at 0.02 moves the output weights
  ~0.02 per unit gradient, 40 minibatches an iteration. The trainer now runs each minibatch
  itself (leaves gathered, clip inputs refreshed, recompute, backward) and steps **Adam**
  (`zn.adamStep`, 3e-4, a moment/velocity pair per weight tensor). Natively: stable, 30.0 -> 31.4
  steps and 151 -> 158 return over 12 iterations - the right direction, and 24k samples is very
  little for a humanoid. The page's samples/s is now cumulative over training time (a window spent
  wholly updating read 0), and the training budget adapts to hold 30 fps (a fixed 25 ms gave 22).
- **Sep 19 — "slidy feet", measured; and P1's first real curve.**
  * **The feet are not slippery.** A statue held still slides its feet 2-3 mm in its first half
    second at 60, 120 and 240 Hz physics - contact friction is fine. The sliding seen on the phone
    is the POLICY: an early policy leans forward and drives the legs back, and a falling body
    pushes its feet past the friction cone. (Aside: zimr ignores MJCF `condim`; this humanoid's
    feet inherit condim=1, frictionless in MuJoCo proper, and have friction here.)
  * The statue stands longer at higher physics rates: falls at step 37 / 48 / 58 at 60 / 120 /
    240 Hz. A knob if learning stays hard: 120 Hz costs 2x and starts the policy 30% higher.
  * **P1 LONG** (`-Dslow-tests`): 150 iterations, 307k samples natively - mean length 29.7 ->
    36.3 (best 38.4, past the statue's 37.6), return 151 -> 186. **PPO learns on our stack, and
    slowly: ~+20% return per 300k samples at this stage.** Locomotion from scratch is the hard
    case; tracking (P2) has a dense per-frame reward and reference-state initialisation.
  * Next candidates to speed it: smaller initial noise (the stochastic policy starts ~20% below
    the statue), a 256-256 network, 8k-sample iterations with 10 epochs, and 120 Hz physics.

## 7. OFF-POLICY METHODS, WORLD MODELS, AND THE GPU (Sep 19, Simon: before the dance)

Try the modern methods - SAC and its sample-efficient variants (DroQ, REDQ, CrossQ), and
SuperTrack's world model - and train on the GPU.

### 7.1 The arithmetic that orders everything

Off-policy methods buy SAMPLE efficiency with COMPUTE per sample. Measured today on one CPU core
(P1 LONG: ~250 s of 380 s spent in 150 PPO updates of 40 minibatches): **~41 ms per minibatch
update of a 20k-parameter network, batch 256**, through zimrnum's CPU graph.

    method        updates per env step   networks             CPU per env step   100k steps on CPU
    PPO (ours)    ~0.1 (batched)         2 x 64-64            ~4 ms              ~7 min
    SAC           1                      actor + 2 critics,   ~0.5 s             ~15 h
                                         256-256 (~270k)
    CrossQ        1 (no target nets)     as SAC, batch-norm   ~0.5 s             ~15 h
    DroQ / REDQ   10-20                  as SAC (+dropout,    5-10 s             days
                                         layer norm)
    simulation    -                      -                    0.4 ms native, ~0.8 ms on a phone

*** **ON THE CPU THE MODERN METHODS ARE COMPUTE-BOUND BY ~1000x.** On a GPU at even 10-20% of
its peak, a SAC update is ~1 ms on a desktop and ~5-10 ms on a phone - so GPU training is not a
nicety for this plan's second half, it is the enabler. And the simulation stays on the CPU:
one env step is 0.4-0.8 ms, far below any of these update costs.

### 7.2 What exists - VERIFIED exhaustively (the first version of this table was wrong)

Simon asked for an exhaustive check before building; it found most of what §7.2 had called
missing. From zimrnum's public API, its Graph's op list, and its tests:

    SAC-family building blocks, each with tests                       status
    SquashedGaussian, graph squashedReparameterize (tanh actor,       EXISTS, tested (finite at
      reparameterised sample + log-prob), squashCorrection              saturation)
    sacTarget + CriticAggregate/aggregateCritics - "one slice          EXISTS, tested
      covers TD3, DroQ, REDQ and CrossQ"; graph `min` (twin pessimism)
    Temperature (SAC entropy tuning; target entropy scales with dim)  EXISTS, tested
    ReplayBuffer(T) (ring of flat rows: init/push/sample), Transition EXISTS, tested
    offPolicyUpdate + OffPolicyModel: ONE critic loop for SAC, TD3    EXISTS, tested - but it
      and DQN (caller computes targets and the actor step), polyak      steps PLAIN SGD, like ppoUpdate
    graph layerNormRows, adaptiveLayerNorm, dropout, resampleDropout   EXISTS, finite-difference
      (DroQ's critic)                                                   checked
    BatchNorm(T).attach(graph, input, use) (CrossQ's critic)          EXISTS, tested
    graph concat (Q(s, a)), softplus/silu/gelu/mish, attention,        EXISTS
      encoderBlock, conv2d, embedding; ObsNormalizer; clipGradNorm
    dqnTarget (double DQN), OrnsteinUhlenbeck (DDPG), AWR weights,     EXISTS, tested
      discriminatorReward (AMP), trackingKernel (DeepMimic), diffusion
      schedules (MDM-style)

    learning gates that train END TO END                               status
    REINFORCE on cartpole ("the return must RISE"); AWR on cartpole    EXISTS
    SuperTrack's MECHANISM on cartpole: a world model (state, force)   EXISTS (a test) - the
      -> accelerations trained on real rollouts, the policy trained      mechanism, not a module
      by backpropagating the tracking loss through it
    MPC-data world model beats random-action data                      EXISTS (a test)
    PPO on HumanoidEnv (ours, robot_gym)                               EXISTS
    **A complete SAC / TD3 / DroQ / CrossQ AGENT, trained end to end**  **MISSING** - every
                                                                        piece exists, unassembled

    GPU                                                                status
    kompute: one kernel source, WebGPU dispatch or CPU loop            EXISTS
    zn_matmul: matmul, matmul_tiled (shared memory + barriers),        EXISTS, same-device twin
      matmul_bt, transpose; zn_unary / zn_binary elementwise; batched
      cartpole with a GPU twin
    zn_train: a two-layer net, 4,096-float buffers, plain SGD          EXISTS, a demo
    **A GPU trainer for real networks (any size, Adam, the RL losses)** **MISSING**

### 7.3 The order

    S1  ASSEMBLE SAC from zimrnum's parts (SquashedGaussian actor, twin critics through concat,
        sacTarget + CriticAggregate.min, Temperature, ReplayBuffer, polyak) and step ADAM - not
        offPolicyUpdate's SGD, the trap ppoUpdate already sprang. Gate 1: continuous cartpole
        (fast, known to be learnable, zimrnum's own learning-gate environment). Gate 2:
        HumanoidEnv with small nets, native, against PPO's curve (36 steps at 307k samples).
        DroQ and CrossQ are then a critic change each (dropout + layer norm; BatchNorm, no target).
    G1  The GPU MLP trainer (kompute): layers of any size up to a large `max`, tiled matmuls
        (zn_matmul's), tanh / relu, backward to weights AND inputs (the SAC actor's gradient flows
        through the critic into its action input), Adam; the RL losses as small kernels. Every
        kernel checked against zimrnum's CPU graph on the same numbers (the sweep contract).
    G2  The number: ms per SAC update on the phone and a desktop, from a page.
    S2  SAC with the GPU learner in rl_humanoid (an algorithm switch), CPU physics.
    S3  CrossQ (batch renorm, no target nets - the compute-cheap one), then DroQ (dropout +
        layer norm, many updates per step - where the GPU pays most).
    W1  SuperTrack: needs the tracking task (P2's DanceEnv) - a world model predicting the next
        state from state and PD targets, trained on replayed transitions; the policy trained by
        backpropagating through the model unrolled over 8-32 frames (the GPU trainer's layers
        reused across time, gradients accumulated). zimrnum's miniature is the reference.

- **Sep 19 — S1: SAC assembled; it learns cartpole, then α runs away.** `robot_gym.SacAgent`: a
  tanh-squashed Gaussian actor (`squashedReparameterize` - which takes a state-INDEPENDENT log-std
  row [1, dims], so the log-std is one learned row, tanh-bounded to [-5, 2]), twin critics on
  `concat(s, a)`, targets y = r + gamma (1 - done)(min Q' - alpha log pi) from plain forwards of the
  actor and polyak target critics, `zn.Temperature`, `zn.ReplayBuffer`, Adam everywhere
  (`offPolicyUpdate` steps plain SGD). Two build bugs on the way: squashedReparameterize's [1, dims]
  log-std (ShapeMismatch), and a `Var` is an index into ONE graph - the actor graph re-applies the
  critics' layers, overwriting their stored handles, so the critic graph's are captured first.
  * Gate 1, continuous cartpole (cap 500), ~25 ms an update on the CPU graph:
      steps 2k / 4k / 6k / 8k / 10k / 12k / 14k: mean length 28 / 65 / 131 / **166** / 106 / 52 / 36
      alpha 1.3 / 2.4 / 5.2 / 11 / 24 / 52 / 115 - doubling every 2k steps, from the first update.
  * **It learns, then collapses as alpha runs away.** Temperature's sign and the graph's log-prob
    sign are both right (checked). alpha rose at Adam's full step rate from update one, so the
    ACTOR GRAPH reports mean log pi > 1 where the initial policy's is ~0.08. Prime suspect: the
    noise tensor handed to `squashedReparameterize` at build time is copied into the graph, so
    later refills never reach it (eps = 0 forever). **Next: a unit test comparing the graph's log pi
    with the plain one for the same noise** - it will say which, in one run.
  * The gate is behind `-Dslow-tests` (several minutes on the CPU graph).
- **Sep 19 — the alpha runaway was MY target entropy: +1 instead of -1 per dimension.**
  `Temperature.forActionDim(dim, per_dim)` sets target = per_dim x dim, and SAC's heuristic is
  per_dim = -1 (zimrnum's own tests pass -1.0). +1.0 asked a tanh-squashed 1-D action for entropy
  +1, above its maximum (the uniform's, log 2 ~ 0.69): alpha could only rise. The noise theory was
  wrong - `Graph.constant` references its tensor, so refilled noise does reach the graph.
  * **Gate 1 passes on correctness:** steps 2k..16k, mean length 26 / 96 / 268 / 226 / 273 / 250 /
    222 / 209 - ~10x random and stable; alpha anneals 0.73 -> 0.034. It plateaus at ~250 of the
    500 cap: gamma 0.99 is a ~100-step horizon, short for a slow cart drift that ends episodes
    near step 250 - a known cartpole-hold trait; gamma 0.995 is the usual remedy.
  * Cost: ~25 ms an update on the CPU graph for a 4-input problem. **Gate 2 (HumanoidEnv, 97 inputs
    to the critics)** will be several times that per update - tens of minutes natively for 20k
    steps: the GPU trainer (G1) is what makes the humanoid comparison practical.
- **Sep 19 — G1: the GPU layer kit, proven on its CPU twin.** `src/gpu/zn_mlp.zig`: dense layers
  of any size over flat buffers (params / grads / Adam moments laid out alike; activations and
  their gradients at host offsets), one dispatch per layer operation - `dense_fwd`, `act_bwd`,
  `dense_bwd_x` (the input gradient SAC's actor needs through the critic), `dense_bwd_w`,
  `mse_bwd`, `mse_value`, `adam` (bias corrections from the host: no pow in a kernel). Buffers of
  256k floats (a humanoid SAC critic fits). `z.Compute` re-uploads the params before every
  unbatched dispatch, which is what lets one pipeline serve every layer of every network.
  * **Parity with zimrnum's graph, 20 Adam steps of a 5-16-1 tanh net, batch 8: worst loss gap
    1.4e-6, worst weight gap 6e-7** - the whole chain composes, input gradients included.
  * One thread per output element, as zn_train; `zn_matmul.matmul_tiled` is the speed step once
    the SAC path runs. WGSL is registered per example in build.zig - next, with the page.
  **Next: SAC's critic and actor on the kit, in a visual cartpole page (mpc_cartpole's style),
  a CPU/GPU switch and ms per update on screen.**
- **Sep 19 — PPO with its update on the kit: it learns the cartpole hold.** zn_mlp gained a
  Gaussian PPO head (`ppo_mean_grad`: per row the log-prob, ratio and clipped surrogate, the
  gradient at the mean; `ppo_logstd_grad`: per dimension, summed over rows). `robot_gym.GpuPpo`:
  policy MLP + log-std row + value MLP contiguous in the kit's params (ONE Adam dispatch steps all),
  a CPU copy to ACT with, refreshed by `syncWeights` from the readback (a frame late on a GPU -
  harmless, because the clipped ratio uses the log-probs of the policy that actually acted), and
  `trainMinibatch`: ~25 dispatches - policy forward, the PPO head, the policy backward chain,
  value forward, MSE, the value backward chain, Adam.
  * On the kit's CPU TWIN (the GPU's kernels, same order), zimrnum's continuous cartpole `.hold`,
    16 envs x 64 steps an iteration, 4 epochs of 256-row minibatches: mean episode length
    26 / 67 / 121 / 229 / **349** / 239 / 196 / 229 at 5k..41k samples - ~20 s for 41k natively.
    Late numbers are noisy: once it holds, only 2-9 episodes END per iteration; the page should
    report survival of the last N episodes or the fraction upright.
  * **Next: the page** - the kit registered for WGSL, envs on the CPU and the update on the GPU
    in parallel, beside `mpc_cartpole`'s MPC on the same cartpole.
- **Sep 19 — the page: `examples/cartpole_duel`, PPO on the GPU beside MPC on the CPU.** A copy
  of `mpc_cartpole` (its model, planner and ghost trajectory, now starting upright for the hold)
  with a PPO side on the SAME robot.zig cartpole model: 16 `rbt.Data` stepped on the CPU, the
  update on the GPU through `zn_mlp` (`robot_gym.GpuPpoOn(M)`, generic over the kernel module),
  rollouts double-buffered so the next is collected while the last one's minibatches train, the
  weights back through the readback a frame late. Panel: samples/s, survival of the last 20
  episodes, the GPU's epoch/minibatch, weight syncs.
  * **The kit had no export hook.** A kompute module needs `comptime { for (kernels) |name|
    k.installKernelLean(@This(), name); }`; without it the SPIR-V compile exports NOTHING - a
    68-byte module, an empty compute.wgsl per entry, `initGpu` failing on UniformBindingNotFound
    (the page's 22-byte log) - while the CPU twin, calling the functions directly, passed every
    test. `zig build check`'s spv2wgsl sweep flags it ("no entry-point attribute"): run check
    before the smoke test when a kernel module changes.
  * One file, two modules: the page gets `zn_mlp` as a NAMED module, so no file of `zimr` may
    import it by path. The kit's proofs moved to `src/gpu_learn_tests.zig` (in `robot_tests`).
  * `compute_host.initGpu` leaked its field buffers when a later step failed (buffer+7 per
    lifecycle in the smoke runner): an errdefer now destroys them.
  * Smoke: 4,292 init calls (nine pipelines), ~553 a frame. Standalone at `-Dmode=release`
    (ReleaseSmall): 2.5 MB page, its embedded wasm 1.1 MB and byte-identical to the build's.
  **Next: the device run** - weights coming back (the sync count climbing) and survival rising
  toward 500 within ~20-40k samples; if survival stalls while weights arrive, an on-page
  GPU-vs-CPU-twin parity readout, as zimrnum_train has.
- **Sep 19 — cartpole_duel budgeted for 60 fps; the readback made small; leaks checked.** On
  Simon's phone the first page ran at a low frame rate and stalled the whole device. Three causes:
  * **A dispatch flood.** `runPpo` busy-looped a fixed 10 ms and issued a minibatch (~25 GPU
    submissions) on every pass while training - dozens a frame, none waited for, on a GPU the
    phone shares with its compositor. Now: PPO's CPU budget is steered AIMD on the frame time
    (0.25-8 ms), and a GPU batch (1-4 minibatches, steered likewise) goes out only once the last
    is BACK - `readGeneration().mirrored` has reached the `submitted` recorded after it.
  * **Whole-struct readbacks.** `compute_host`'s GPU readback copied EVERY field whole - 7 MiB a
    readback for the kit's 1 MiB fields, mapped and copied into wasm memory every frame - to
    return 6 KB of weights. It now copies each field's first `element_count` elements packed, and
    unpacks them in place, last field first (a packed offset never exceeds the real one). What a
    caller sees is unchanged; it was always sliced to `element_count`. A native test packs and
    unpacks three fields, one shorter than the count. This helps every page that reads back.
  * **A deadlock the stub could not show.** `readLatest` both lands a copy and encodes the next,
    and `mirrored` only advances inside it; the page called it only once the GPU looked idle, so
    after one batch nothing encoded a copy and training would have stopped. It now polls every
    frame. (The stub GPU reports 0/0 generations, so the smoke run never waited.)
  * **Leaks.** Lifecycle: two init/deinit cycles leave identical handle counts, shutdown balanced.
    Runtime: the smoke runner itself grows ~2.5 MB a frame (it logs every host call as a string,
    and the logic copies the log six times) and dies near 600 frames on ANY page - mpc_cartpole
    included. With its log capped (--max-log=2000): cartpole_duel 141 -> 196 MB over 1,100 frames,
    mpc_cartpole 127 -> 181 MB - the same residual on both, so none of it is the PPO/GPU path.
- **Sep 19 — on Simon's phone: cartpole_duel at 60 fps, PPO learning on the GPU.** Iteration 72,
  74,752 samples at 6,143 samples/s, survival (last 20) **429 of 500**, weights back from the GPU
  333 times, budgets settled at CPU 6.3 ms and 4 minibatches a batch, the GPU still busy 32 frames
  a second (a batch round-trips in about two frames - the backpressure working). Frame 16.6 ms.
  * **Follow-up: MPC is squeezed to 1 iteration a frame.** PPO's AIMD grows into all the headroom,
    and MPC's own rule only adds iterations below 0.7 x 16.7 ms - never, at a vsync-locked 16.6.
    Holding is fine (cost 0.0); a shove or swing-up would plan poorly. The frame needs a fair split.
- **Sep 19 — S2, step 1: SAC's update on the kit, equal to SacAgent's.** Eight kernels in zn_mlp:
  `squash_fwd` (u = mean + std eps, a = tanh u, written straight into the critic's strided
  [state | action] rows), `squash_logp` (the stable tanh correction), `sac_target`,
  `min_route` (the whole -min(q1, q2) gradient to the smaller critic, ties left, as zimrnum's
  `min`), `squash_bwd` (both critics' action-input gradients through tanh, plus alpha's 2 tanh
  pull), `squash_logstd_grad` (through SacAgent's tanh bound), `alpha_grad` (zn.Temperature's),
  `polyak`; dense layers read input rows with an optional stride, so the actor reads states out of
  the critic's rows. `robot_gym.GpuSacOn(M)`: actor + log-std + log alpha contiguous (one Adam),
  twin critics contiguous (one Adam), targets mirroring them (one polyak); ~60 dispatches an
  update in SacAgent's exact order. `SacAgent.update` now draws its batch and noise and calls
  `updateWith`, which a check can call with its own.
  * **Parity, 5 updates at lr 1e-2, 2 action dimensions, same batches and noise: worst gaps actor
    3.0e-7, log-std 1.0e-7, log alpha 5.6e-8, critics 1.8e-7, targets 1.2e-7 - while the weights
    MOVED 0.050 (actor) and 0.048 (critics).** Right on the first run.
  * cartpole_duel registers all 17 kernels (its pipeline table is the module's whole list): smoke
    4,372 init calls, balanced.
  **Next: G2 - SAC on the GPU in a page, ms per update on the phone** (cartpole_duel's learner as
  a PPO/SAC switch is the cheapest page), then S2 proper in rl_humanoid.

## 8. The endgame (Simon, Sep 19): everything resident on the GPU

The picture this track is heading for: **robot.zig's dynamics on zimrnum tensors with autograd**,
batched over many worlds and resident on the GPU; **MPC on the GPU** over that differentiable
model; a **SuperTrack-style world model** trained from GPU-resident replay; **short-horizon MPC
homing in on good actions** inside the learning loop; and **SAC-family critics (DroQ / CrossQ)**
supplying the value beyond the planner's horizon - the combination TD-MPC2 uses (a learned model,
an MPPI-style planner, a TD-learned value and a policy prior), here with a differentiable
SIMULATOR available beside the learned model. The goal: state-of-the-art tracking of complicated
mocap, all of it on the device.

    E1  Batched dispatch: many dispatches in ONE submission, each with its own params (a params
        ring behind a dynamic uniform offset). Every item below is hundreds of kernels a frame;
        today each dispatch is its own submit. G2 will measure what that costs.
    E2  robot.zig's step as kernels: RNEA / CRBA / ABA per world, many worlds a dispatch,
        contacts included - forward only first, checked against robot.zig world for world.
    E3  Its reverse mode: the step's gradients (autograd over the kernels, or hand-derived
        adjoints like the kit's), checked against finite differences - the differentiable sim.
    E4  MPC on the GPU: batched rollouts (MPPI) and gradient steps through E3, warm-started, a
        frame's budget - mpc_cartpole, then the humanoid, resident.
    E5  SuperTrack resident: the world model on the kit, trained from GPU replay; the policy
        through it over 8-32 frames; MPC (E4) refining actions against it or against the sim.
    E6  The critic beyond the horizon: SAC / DroQ / CrossQ targets on the same replay - the
        kit's S2 kernels - and the mocap tracking task end to end.
- **Sep 19 — G2's page: SAC on the GPU in cartpole_duel, and MPC's fair share.**
  * **A learner switch, PPO / SAC,** each on its own pipe (its own weights, kept across switches).
    SAC: the 16 cartpoles push transitions into a CPU replay (random actions for the first
    1,000, as SacAgent; `done` is a fall, never the cap); a batch of 1-8 updates (AIMD, like PPO's
    minibatches) goes to the GPU only once the last is back; the actor alone reads back
    (`GpuSacOn.readbackActorOnly`: it is first in params) for `act` on the CPU. `GpuSacOn`
    gained `initFresh` (a SacAgent's own initialisation), `syncActor` and `act`.
  * **The G2 numbers on the panel:** updates/s, **submit ms an update** (the CPU's encoding and
    submission of its ~60 dispatches - each dispatch is its own submit today) and **round trip
    ms a batch** (dispatch to weights back: an upper bound on the GPU's time). Expect the submit
    cost to dominate on a phone - which is §8's E1 (batched dispatch) measured, not guessed.
  * **MPC's fair share.** Its rule added iterations only below 0.7 of the frame target - never,
    at a vsync-locked 16.6 ms - so on the phone it sat at 1 iteration a frame. Its budget is now
    milliseconds under the learners' own AIMD (+0.1 ms on time, x0.7 late), turned into iterations
    by the measured ms an iteration: two AIMD flows with equal parameters converge to equal shares.
  * Headless: the smoke run passes (two pipes, 34 pipelines, balanced); SAC made the default for
    one build ran 250 frames uncapped - lifecycle clean, no traps, ~113 GPU buffer writes a frame
    (updates dispatching). ReleaseSmall page 2.7 MB, its wasm 1.27 MB, byte-identical to the build.
  **Next: Simon's phone numbers for SAC** (submit ms, round trip, whether it learns), then E1 if
  the submit cost dominates, then S2 proper in rl_humanoid.
- **Sep 19 — SuperTrack ALONE holds a real cartpole upright under pushes.** Simon's question: with
  no reward, no critic, no MPC and no PPO or SAC - only a world model learned by supervision and a
  policy optimised by back-propagating a tracking loss through it - does the pole stay up?
  `src/robot_supertrack.zig` (slow-gated test), the paper's recipe on zimrnum's cartpole: 8 real
  cartpoles gather with the current policy + sigma 0.1 noise, a push to the pole every 40 steps
  (+-0.4 rad/s); a ring PER cartpole, a new segment at every reset and every push (a window never
  spans an unmodelled push); the world model (cart rate, pole angle, pole rate, force) ->
  accelerations, integrated ON THE TAPE exactly as the simulator (semi-implicit, 0.02 s), trained
  on 8-frame windows of its own predictions; the policy unrolled 32 frames through the frozen
  world model, loss = distance from upright-at-centre + a small action penalty; one step of each
  an iteration, batch 32, hidden 32, Adam 1e-3. MSE, not the paper's L1 (the tape has no abs).
  * **Real episodes (the policy WITHOUT noise, 10 of them, cap 500, pushes): zero-force baseline
    34.3; iteration 250 (8k samples) 312; 1,000 (32k) 434; 1,750 (56k) 481; 2,750 (88k) 500.0 -
    every episode to the cap, through every push; 3,000 still 500.0.** The world model's loss is
    2e-5 by iteration 250. ~28 ms an iteration natively on the CPU graph, ~85 s the run.
  * The first run failed on MY bug, not the method: one shared ring, so "consecutive" records
    were different cartpoles - world-model windows of nine cartpoles, and a policy start's 1-step
    window that never matched a segment (the policy never trained; its loss printed 0.0000).
  * **Caveats:** one seed; 10 evaluation episodes a checkpoint; a regulation task, and the
    cartpole is easy for a world model (4-D, smooth, no contacts). Against the earlier PPO and SAC
    runs on this cartpole it is far ahead - but those had no pushes and different nets and
    budgets, so that is indicative, not a controlled comparison.
  * **What it means for §8:** for dense, differentiable tracking losses the world model and the
    analytic gradient do the heavy lifting. What the others add is what SuperTrack lacks by its
    own account: a horizon beyond the policy window (a critic's value at the window's end - SAC /
    DroQ / CrossQ targets), and search where no gradient leads, such as a recovery step (MPC with
    the world model). So they are refinements on top of it rather than its foundation.
  **Next:** SuperTrack into the cartpole page in place of MPC (small nets, an iteration a frame);
  E1 (batched dispatch - a SuperTrack policy step is hundreds of kernels); SuperTrack on the kit,
  checked against this CPU version as S2 was; then the humanoid (W1).
- **Sep 19 — SuperTrack on the kit: exact, and it learns - but not yet cheap.** Measured first:
  the CPU graph's SuperTrack costs 28 ms an iteration natively (full size) and 8 ms at the
  page-sized configuration (batch 16, 16-frame window), which learns markedly worse (295 real
  steps at 1,500 iterations, against 434 at 1,000 full-size). An iteration is only ~2M
  multiply-adds, so the graph's per-op overhead was the cost - hence the kit, not the page, first.
  * zn_mlp's `cp_` kernels: `cp_step` (semi-implicit, as zimrnum's cartpole) and its exact
    adjoint `cp_step_bwd`; `cp_track_bwd` against a target block (zeros for the policy, real
    states for the world model); `cp_wm_input` / `_bwd`; `cp_force` (tanh(o + sigma eps)) /
    `_bwd` (with the action penalty); `add_block`; and an `accumulate` flag on `dense_bwd_w` so
    weight gradients SUM over the unrolled steps. Params grew to 176 bytes (a multiple of 16:
    172 was refused by compute_host's std140 check).
  * `robot_supertrack.SuperTrackKitOn(M)`: per-step offsets for every unrolled activation; the
    uploaded inputs (a zero target, starts, noise, real windows) in one compact region at the
    front of acts; the forward unroll, then the backward in reverse. The graph SuperTrack gained
    `trainWorldWith` / `trainPolicyWith` and sampling split from training
    (`sampleWorldBatch`, `samplePolicyBatch`, `loadPolicy`), so either trainer takes its batches.
  * **Parity, 4 iterations (world step + policy step), windows 4/6, lr 1e-2: both networks within
    1.2e-7 of the graph's, while their weights moved ~0.04.** Right on the first run.
  * **End to end on the kit's CPU twin (full size), the real cartpole with pushes: 363 / 407 /
    425 / 471 real steps at 500 / 1,000 / 1,500 / 2,000 iterations** - the graph's own run was
    384 / 434 / - / 481 (1,750): the same learning.
  * **But 14.7 ms an iteration, only 2x the graph's 28.** An iteration is ~1,050 dispatches (a
    32-step unroll, forward and back, each step a chain of small kernels); on the CPU twin that
    is dispatch and bounds-check overhead, and on a GPU the same granularity costs per-dispatch
    time. So the next steps are: E1 (one submission for all of them), then FUSION - a whole
    step's forward, and its backward, as a few kernels rather than ~30 - before SuperTrack is
    cheap enough to train in a page at 60 fps. The page registers all 25 kernels (smoke: 4,723
    init calls, balanced).
- **Sep 19 — E1: many dispatches, one submission, each with its own params.** `compute_host`
  gained RECORDING: between `beginRecording` and `submitRecording`, a `run` writes its params
  into a slot of a params table, encodes `copyBufferToBuffer(table[slot] -> uniform)` and then its
  dispatch in its own compute pass, all in ONE encoder; `submitRecording` uploads the table in one
  `writeBuffer` (queue writes land before the submission that follows) and submits once. The copies
  run in order on the GPU timeline, so every dispatch sees exactly its own params - pipelines, bind
  groups and WGSL untouched (dynamic uniform offsets would save the copies; a later refinement).
  2,048 slots, auto-flushing when full; `uniform_synced` invalidated after (the GPU wrote the
  uniform); the table destroyed at teardown. CPU and worker backends run at once, as always, so
  every CPU-twin parity check covers the path. PPO's minibatch, SAC's update and SuperTrack's two
  steps each record between their upload and their last dispatch.
  * **Headless proof, from the call trace:** PPO minibatches go out as ONE submission of 24
    dispatches (was 24 submissions); SAC updates as ONE of 69 (was 69); no asserts, the lifecycle
    balanced. Correctness on a real GPU is the device's to show: PPO still learning, SAC's
    "submit ms an update" falling.
  * **★ A correction: until this turn, neither learner had EVER trained in the smoke runs.** The
    runner's clock advances 16 ms on every `nowMs()` call, so the budget-first collection loops
    exited before collecting anything - no rollout, no replay, no update. Last turn's "SAC made the
    default ran 250 frames, updates dispatching" was wrong: those ~113 writes a frame were
    rendering. The page now collects at least one tick a frame before consulting the budget
    (a tick is ~0.1 ms): learning always progresses, and the training paths are exercised
    headlessly - which is how the recordings above were seen at all.
  **Next: Simon's phone - PPO still learning, SAC's submit ms; then fusion (a SuperTrack step's
  forward and backward as a few kernels, not ~30), then SuperTrack live in the page.**
- **Sep 19 — fusion: a SuperTrack iteration is 8 dispatches, not ~1,050; SuperTrack in the page.**
  zn_mlp's `st_` kernels run the cartpole SuperTrack with ONE THREAD PER BATCH ROW walking the
  whole window: `st_policy_fwd` (policy, force, world model, integration, every step's
  activations into a per-(step, row) record), `st_policy_bwd` (the window in reverse: tracking
  gradient, the step's adjoint, back through the world model to its input, the force, the policy -
  into the row's OWN gradient slice), `st_world_fwd` / `st_world_bwd` (with the world model's
  weight gradients), `st_reduce` (a thread per weight sums the rows). Scalars and global memory
  only, for the SPIR-V compile. Right for hidden 32; a humanoid wants a workgroup per row.
  * **Parity with the graph (4 iterations, windows 4/6, lr 1e-2): policy 1.2e-7, world 1.5e-7
    while the weights moved ~0.04 - first run. On the real cartpole the fused path gives the
    IDENTICAL curve (363 / 407 / 425 / 471).** The CPU twin: 8.5 ms an iteration (per-layer 14.7,
    graph 28) - the dispatches were not the whole story on the CPU; what remains is arithmetic in
    a safety-checked native build. The per-layer learning run is now slow-gated.
  * **The page: SuperTrack is the switch's third learner** (PPO -> SAC -> SuperTrack), on the page's
    robot.zig cartpole: the action held 2 physics steps (0.02 s, the proven step; a 32-step window
    is 0.64 s), actions in actuator units (force limit 1), a push to the pole every 40 of its
    steps; the CPU SuperTrack object gathers, samples and acts (refreshed from the readback, the
    policy only - it is first in params); the kit trains FUSED, a world step and a policy step per
    GPU round trip, 8 dispatches in two submissions. The panel: iterations, survival (pushed),
    submit ms, round trip. `robot_supertrack` is exported from zimr.
  * **The smoke runner's clobber rule, met rather than argued with.** It treats every write in a
    frame as landing before the frame's submission (right for the renderer's one frame encoder)
    and failed SuperTrack's two steps a frame twice: first on `acts` (each step uploaded the whole
    staging block from 0), then on the params TABLE (each recording wrote it from slot 0). Both are
    correct by WebGPU's queue ordering - and PPO's 4 minibatches a frame learned on Simon's phone -
    but both are now structurally immune: `compute_host.uploadAt` (an element offset), each step
    uploading only its own disjoint region; and the params table a RING across recordings.
  * Headless: SuperTrack made the default for one build ran clean (no clobbers, balanced, ~1,288
    calls a frame); PPO-default smoke, check (66 shaders), compute_host's 52 tests all pass.
    ReleaseSmall page 3.0 MB, its wasm 1.5 MB, byte-identical to the build.
  **Next: Simon's phone - SuperTrack learning in the page (survival under pushes, submit ms, round
  trip); then MPC out of the page (Simon: no longer needed), and the humanoid.**

## 10. W1 — SuperTrack on the dance, verified step by step (Simon: "be very careful")

The last dance-servo attempt failed on retargeting and joint-math bugs that each produced
plausible-looking numbers: a mirror swizzle, IK soft terms that were dead code, a hinge frame
measured in the wrong space, 3-hinge shoulder branch flips (servo_ladder.md 8.5-8.6). A learner
trains happily on a subtly wrong target, so W1 verifies every representation and every piece of
joint math INDEPENDENTLY before a network touches it, one gate at a time:

    W1.0  the reference, audited: the 10 s dance on humanoid_flex2, 5 Hz filtered (the servo
          ladder's validated reference) - joint types, range excess, per-frame jumps, quaternion
          sign flips, the velocities a tracker would demand.                          DONE (below)
    W1.1  the body-state conventions: (a) measured by finite differences      DONE (below)
          (b) Local(): root-relative, two-axis rotations, heights, up - invariant under a global
              yaw and translation; two-axis -> rotation round trip
          (c) the paper's integrator (eqs. 8-12) reproduces the SIMULATOR's next state from its
              own accelerations - world-frame w pre-multiplied, as (a) measured
    W1.2  actions: per-joint PD-target offsets on the reference - a hinge adds an angle, a ball
          composes exp(alpha/2 o) with the reference quaternion (ORDER checked like qmul in (a));
          the free root is not actuated. Zero offsets reproduce the reference's targets exactly.
    W1.3  world-model data on flex2: the simulator tracking the reference under noisy offsets;
          windows that never span a reset
    W1.4  the world model: multi-step prediction error against horizon (the paper's Fig. 14),
          on held-out windows, before any policy exists
    W1.5  the policy through it; evaluation on the REAL simulator: survival and per-body error

- **Sep 19 — W1.1a: the conventions, MEASURED (`robot_dance` test, fast).** On flex2, 5 random
  states and velocities, a 1e-3 `integratePos` step, forward kinematics again; worst over bodies
  (largest |w| 7.2 rad/s, |v| 6.5 m/s):
      cvel.ang vs the WORLD-frame difference log(q2 q1^-1)/h     0.011 rad/s    <- it is world
      cvel.ang vs the BODY-frame difference log(q1^-1 q2)/h      11.9 rad/s
      COM (x2 - x1)/h vs cvel.lin SHIFTED from the tree's shared origin (root's subtree COM),
        v = cvel.lin + w x (c - O)                               0.015 m/s      <- it must be shifted
      ... vs cvel.lin as it stands                               5.9 m/s
  and `qmul(a, b)` applies b first (asserted). **cvel.lin is NOT a body's velocity - using it as
  one is off by up to ~6 m/s here and would still train.** Every SuperTrack body velocity comes
  from the shift; the integrator pre-multiplies a world-frame w.
- **Sep 19 — W1.0: the reference audited (`robot_dance` test, slow).** 599 frames at 60 Hz; IK
  residual mean 6.5 cm, worst 13.9 cm; **0 hinge-frames out of range; 0 quaternion sign flips**
  (every ball joint and the root). The model's joints in order: free root; abdomen 3 hinges;
  each hip 3 hinges; knee, ankle, toe BALLS on both legs; each shoulder 3 (non-orthogonal)
  hinges; **the right elbow a BALL with NO range, the left elbow a ranged HINGE** - an asymmetry,
  almost certainly an editing accident. It is also the only joint the audit flags: **a 0.41 rad
  single-frame jump at frame 76 and the clip's fastest demanded velocity, 19 rad/s on one of its
  axes at frame 75** - after the 5 Hz filter. An unconstrained 3-DOF elbow lets the IK twist the
  forearm about its own axis; a genuine fast swing or a twist flip decides whether the reference
  or the model is fixed, and it is not guessed.
  * The audit's first run mislabelled joints: `imported.names` is BODY names (19), not joint
    names (24); a joint is labelled by its body (`names[jnt_body[j]]`), as `measureTargets` does.
  **Next: W1.0b - the right elbow at frames 70-80 (its three components, twist about the forearm
  against swing), and the decision it forces: both elbows as ranged hinges (anatomical, and
  symmetric) is the default proposal, re-validated by the retarget's WHOLE BODY test; the ball
  knees/ankles/toes likewise examined. Then W1.1b-c.**

## 11. The confidence ladder: retargeting and servoing, one known answer per rung (Simon: "start small")

The failed dance attempt was big-first: retargeting, joint math, balance and the servo tangled
together, so no number could say which was broken. Each rung here isolates ONE thing and has a
right answer known in advance; where a rung guards against a known bug, it is also run ON that bug
to prove it catches it. (T = retarget, J = joint servo - distinct from servo_ladder.md's B/R/S.)
All in `robot_dance.zig`, beside its fixtures.

    rung  what                                              measured (Sep 19)                  cost
    T0    the capture's REST pose retargeted: each limb     segment directions 1.6-7.7 deg     fast
          segment points where the capture's does           (worst: left thigh); handedness
          (directions, so T- or A-pose alike)               agrees; IK residual 5.8 cm
    T1a   the CONVERSION keeps the capture's own raw        .rotate 600 of 600 frames;         fast
          handedness in every frame; the old swizzle        .swizzle 0 of 600 - proven on the
          must flip it (triple product: a reflection        mirror bug itself
          keeps every dot product, so only it can tell)
    T1b   the retarget end to end, through the rotation     residual 6.5 cm vs 15.3 cm (2.4x)  slow
          and through the mirror: the mirror must fit
          worse (the IK residual)
    J0    a hinge through the DANCE SERVO's own path        overshoot 0.0000 rad; 5% at        fast
          (Tracker -> bias -> inverse dynamics -> step):    0.417 s vs 0.377 s analytic (the
          critically damped, settled on time                60 Hz implicit spring ~10% slower)
    J1    a ball joint from a ROTATED start (from           path off the geodesic 0.020-0.034  fast
          identity a frame mistake is invisible): the       deg in 4 cases; final 0.0000 deg
          path must stay on the geodesic
    W1.1a the body-velocity conventions (section 10)        world-frame w; cvel.lin SHIFTED    fast
    W1.0  the reference audited (section 10)                0 sign flips, 0 hinge excess;      slow
                                                            the right elbow (ball, NO range)

- **What the rungs taught, beyond passing:**
  * **A chirality proxy built from limbs is not a chirality measure.** T1's first version compared
    against the robot's rest sign and agreed in only 581 of 600 frames - a dancer's foot pointing
    backwards flips the triple product legitimately. Against the capture's own RAW handedness the
    conversion is exact (T1a). On the ROBOT the same proxy "followed" the mirror too (547 of 561
    frames): a body with ball knees and ankles can contort until even a mirrored cloud gives the
    "right" sign.
  * **On flex2 the IK residual is a WEAK mirror detector** (2.4x; the old humanoid_flex showed
    35.7 cm). A future mirror bug could hide under the residual; T1a is the guard.
  * **The dance servo's joint math is right where it can be wrong:** J1 follows the geodesic to
    0.03 deg from rotated starts, so the Tracker's ball error really is in the child's frame and
    composed correctly; J0 is critically damped with no overshoot.
  * My own label bug again caught by a rung: body names indexed by joint (W1.0's first run).
- **Next rungs, in order:**
    J2  a fixed-base LIMB (flex2's right arm: 3-hinge shoulder + the ball elbow) tracking a smooth
        synthetic trajectory generated in its own joint space - the tracking error has a bound
        from J0/J1; any excess is the chain
    T2  IK self-consistency: flex2's OWN body poses from known configurations as targets - the IK
        must recover them (body orientations; shoulders may take an equivalent branch)
    T3  the right elbow at frames 70-80 (twist about the forearm against swing): the model
        decision (both elbows as ranged hinges, re-validated by the WHOLE BODY test)
    J3  the whole body, fixed base, on the dance: the existing B2 - now with every rung under it
- **Sep 19 — T2 and J2: the IK is self-consistent; the SERVO had a discretisation bug, now fixed.**
  * **T2 (IK self-consistency, fast):** every body's pose from 8 known in-range configurations as
    `ikStep` targets (joint limits respected, from the rest pose): recovered to 0.00-0.06 deg in
    most trials, 0.20 deg worst, positions 0.27 mm worst. The IK is not where a dance goes wrong.
  * **J2 (a fixed-base limb, fast):** flex2's right arm (3-hinge shoulder + ball elbow), gravity on,
    a smooth joint-space trajectory through integratePos, the dance servo's own path at 20 Hz; run
    on the STOCK model and the LIMP one (`limpKeepArmature`, what the B rungs servo):

        model, before the fix       0.5 Hz mean / worst      2 Hz mean / worst
        stock                       1.37 / 2.53 deg          4.58 / 7.34 deg
        limp                        0.22 / 0.27              3.50 / 4.22       <- speed-dependent
        limp, AFTER                 0.006 / 0.07             0.007 / 0.06      (500x)
        stock, after                1.27 / 2.34              3.37 / 5.47       (passive forces)

  * **★★★ THE BUG: `Tracker` took the velocity error against v_ref = (next - now)/dt.** robot.zig's
    Euler is semi-implicit (v += dt a, then q += dt v): to land exactly on `next`, the robot must
    be at `now` with v_prev = (now - prev)/dt, the BACKWARD difference. Perfectly on track the
    spring therefore saw -dt a_ref of velocity error every step and pushed off the reference until
    the position term balanced it - ~dt a_ref / (pi f) per joint, compounding down chains. Against
    v_prev an exactly-tracked reference has zero error in both terms. Held targets (J0, J1, the
    standing rungs) are unaffected by construction.
  * **What it changes - the dance's fixed-base rungs:**
        B2 on humanoid_flex2      mean 4.74 / worst 26.60 deg, 29 frames over 10  ->  0.03 / 0.09, 0
        B2 on humanoid_flex       mean 2.78 / worst  7.12 deg                      ->  0.03 / 0.08
        B1 (reach frame 0)        0.06 / 0.04 deg, unchanged
    **servo_ladder.md 8.5-8.8 read B2's error as the TARGETS (flips, transients near frame 505 and
    577); most of it was this servo bug.** On a fixed base the reduced servo now follows the whole
    dance essentially exactly.
  * **What it does not change - balance.** The free-root rungs: with no assist the dance is followed
    0.67 s (was 0.68); standing 1.47-2.33 s (identical: held poses); fully assisted, joints still
    ~14 deg mean (floor contacts the servo does not model). Tracking error was inflated; the GATE
    is still balance - the part a learned policy must supply.
  * **Passive forces are a servo bias on the stock model** (1-3 deg, growing with speed: damping is
    proportional to velocity): inverse dynamics does not cancel flex2's joint springs, damping and
    tendon springs. For SuperTrack's data either limp the model or put the passive forces into
    the servo's feedforward - a decision to take deliberately, not by default.
- **Next rungs:** J3 the MAXIMAL ragdoll's servo (zimrphysics motors, `robot_maximal.driveToPose`)
  - B2's maximal side is still 22.6 deg mean / 53 deg worst, and it is the "ragdoll" of the failed
  attempt: J0/J1/J2 again on that path, same known answers; T3 the right elbow (frames 70-80).
- **Sep 19 — J3: the maximal ragdoll. A latent joint-zero bug, found and fixed; and two facts.**
  * **Fact 1 - the ragdoll has NO ball joints.** `robot_maximal.build` supports hinges and the free
    root only (`error.UnsupportedJoint`). humanoid_flex2 has 7 ball joints, so its ragdoll has never
    been built: every flex2 dance run was the REDUCED model, and B2's "maximal 22.6 deg" is
    humanoid_flex (all hinges). J3b asserts the refusal (the ball probe AND flex2), so it cannot
    change silently; J1 on the ragdoll waits for ball joints.
  * **Fact 2 - joints are built only below a root** (a free body, or one welded to the world): a
    hinge straight to the world gets no joint, and J3a's first probe drove a free-floating arm.
    The probes now hang from a welded base.
  * **J3a (hinge motor):** 1 rad at 2 Hz: OVERSHOOT 0.098 rad (~10%) where the reduced servo (J0)
    has none; 5% at 0.383 s (J0 0.417); final 1e-5. zimrphysics' motor at "damping 1" is not
    critically damped - the soft constraint's discretisation and solve.
  * **J3c (same law, same targets, two engines):** humanoid_flex's right arm (the 3-hinge shoulder
    becomes ONE swing-twist joint, the elbow a hinge) on J2's trajectory; the ragdoll's position
    motors against the reduced model running the SAME law (Tracker toward the next frame as a held
    target - no feedforward), and the full Tracker. First run: **83.5 deg mean at BOTH speeds** -
    not lag. A per-body breakdown: at build every body within 1 deg; after 1 s only
    lower_arm_right and hand_right, both 83.92 deg - the ELBOW hinge.
  * **(Corrected in the review below: this was a documented, unchecked PRECONDITION of `build` -
    "d must be qpos0" - that my J3c test broke, not an undiscovered library bug.)**
  * **★★★ THE BUG: a zimrphysics joint measures from its orientation AT CREATION** (a revolute
    joint's zero is the build pose, as are a swing-twist joint's frames), while `driveToPose` hands
    a hinge motor the raw MJCF angle and the hinge limits are MJCF ranges - right only if every
    hinge was 0 at build. J3c built the ragdoll at a reference frame (the elbow near its range
    centre): every elbow target was 84 deg off, and its limits with it. Every caller so far built
    at qpos0, which hid it. **Fix: `build` makes the parts and joints at the REST pose (qpos0), where
    the engine's zeros are MJCF's, then moves the finished ragdoll to the requested pose with
    `setPose`** - hinge zeros, limits and swing-twist frames all right by construction; callers at
    qpos0 unchanged (B2 maximal still 22.59; robot_maximal's own 412 tests pass).
  * **After:** 0.5 Hz ragdoll 3.30 / 5.69 deg vs same law 2.22 / 2.79 (1.48x - the J3a overshoot);
    2 Hz 24.7 / 39.2 vs 8.2 / 10.8 (3.0x) with no body offset: the soft motor effectively softer
    than its nominal 20 Hz in a 60 Hz world. Joint math consistent; motor dynamics remain.
    J3c now asserts the build (every body within 0.5 deg of its build pose) and the 0.5 Hz ratio.
- **Next rungs:** J4 the ragdoll motor's frequency response on ONE hinge (a sinusoidal target at
  0.5-4 Hz: gain and phase against the reduced same law) - is the 3x at 2 Hz the motor alone?
  Then feedforward for the ragdoll (target velocities into the motors) if it is; T3 the right
  elbow; and the decision the ragdoll forces for flex2: ball joints in `robot_maximal`, or the
  dance stays reduced-only.

## 12. Review (Sep 19): everything this session touched, verified and cleaned

Every file changed this session (11 code files and this note) read as a reviewer, then every
suite re-run and the full gate. Found and fixed:
- **A double free on `robot_maximal.build`'s error path - introduced by the J3 fix.** Six
  `errdefer gpa.free(...)` were still in scope when the new `errdefer ragdoll.deinit()` and
  `setPose` ran: a failing `setPose` would free each slice twice. `build` is now a wrapper over
  `buildAtRest` (the original body and its errdefers, unposed) - one owner per path.
- **The J3 story, corrected:** `build`'s doc ALREADY said the pose "must be qpos0 ... pose it
  afterwards with setPose". J3c broke a documented, unchecked precondition; what changed is that
  it can no longer be broken (any pose is valid now), and the doc says so.
- **`compute_host`:** the recording's CPU slot array was allocated whenever the GPU table was
  missing (a leak on a retry) - each half now guarded by its own existence; teardown asserts no
  recording is open (an open one leaks its encoder and never runs); a stale dispatch-count doc.
- **Duplication removed:** `GpuPpoOn.cpuLayer` (identical to the file's `kitLayer`);
  `SacAgent.policy` (a second copy of the actor forward and tanh-corrected log-prob - it now
  draws its noise in the same order and delegates to `policyWithNoise`); J2's inline trajectory
  generator (identical to `armReference`, checked); the capture match-table code in T0 and
  `ChiralBodies` (`matchHuman`); the world model's x10 output scale, three literals ->
  `robot_supertrack.acc_scale`.
- **Names and docs that drifted:** the page's `ppo_budget_ms` served all three learners ->
  `learner_budget_ms`, its bounds (shared with MPC) -> `cpu_budget_{min,max}_ms`; the page header
  (still "PPO vs MPC", "25 dispatches a minibatch") rewritten; `SuperTrackKitOn`'s doc now
  describes both paths (per-layer reference, fused training).
- **Checked and clean:** no debugging scaffolding left (DEBUG/DIAG/probes), no TODO markers,
  every debug print marked, no stale claims found by pattern; every shared test helper has a
  caller. Numbers unchanged by the refactors: J2 to the last digit, B2, T2, J3c, the S2 and
  SuperTrack parities, the fused run's 363 / 407 / 425 / 471.
- **Left as it is, deliberately:** MPC is still on the cartpole page (Simon said it is no longer
  needed; removing it is a feature change, not a cleanup - a decision to take on its own).
- **Verified after an interruption (Sep 20).** The review above was written by a turn that died
  before verifying it; this re-read every change it made against the zimr1354 snapshot (all sound)
  and finished the job: two doc comments in cartpole_duel still called the shared budget "PPO's"
  (fixed). **The full gate: exit 0 (283 s); the robot aggregator 526 passed, 18 skipped, 0 failed;
  doc-sync, lint, fmt and the shader corpus (66 ok) clean.** (A "failed command" line the runner
  prints beside a passing test binary is an artefact - the binary's own summary says 0 failed.)

## 13. The robot-mocap tutorial (Simon, Sep 20: five turns)

A new tutorial, `src/notes/tutorials/robot-mocap-tutorial.html` (installed as
`robot-mocap-tutorial.html`), covering everything this plan touched, in the zimrnum and robots
tutorials' tone: what the system is, how to use it, and the intuition behind each algorithm - no
testing details, war stories or development anecdotes (Simon's standing preference).
- **Organised as the reader's journey from a capture file to a simulated body performing it:**
  what this is; getting started; motion-capture data; frames, units and handedness; the robot side
  (reduced coordinates, body state and its conventions); retargeting; servoing a clip; the floor
  and balance; the maximal ragdoll; learning to track (the gym, PPO, SAC); SuperTrack; the GPU
  training kit; running it in a page; conventions and gotchas; recipes; reference.
- **Nothing in it is an unchecked claim.** Library source is quoted in folds as zimrnum's tutorial
  does, and doc-sync checks every quoted line against the source (a row pairing the page with
  every module it quotes). The usage code lives in a compiled test file,
  `src/robot_mocap_tutorial.zig`, and is quoted FROM it - so it compiles, runs and cannot drift.
- **Five turns:** 1 skeleton, contents, chapter 1, wiring; 2 getting started, capture data, frames,
  the robot side; 3 retargeting, servoing, the floor; 4 the ragdoll, learning, SuperTrack, the GPU
  kit, pages; 5 gotchas, recipes, the reference, and a full verification pass.
- **Turn 2 (Sep 20): chapters 2-5 written** - getting started (the whole pipeline in one test),
  motion-capture data, frames/units/handedness, the robot side. `src/robot_mocap_tutorial.zig`
  now exists (a test root with its own `zn-` step, in the robot aggregator, in the tutorial's
  doc-sync row with `codecs.zig`): four examples, all passing; the page quotes them and 11 library
  declarations verbatim - doc-sync: 515 lines checked, 0 drifted; doc-gate and check clean.
  * **Library changes the tutorial called for:** `globalsAtFrame`, `bvhPoints`, `toRobot`,
    `rotationToRobot` and `limpKeepArmature` are public (no behaviour change); new
    `robot_dance.bodyVelocity(m, d, body)` - world angular velocity and COM velocity, the cvel
    shift done once, correctly; W1.1a now measures the helper itself.
  * **The capture, as it really is:** every joint (not just the root) carries six channels,
    rotations Z-Y-X; end sites are joints with no channels; only the root's position channels are
    used (bones are the OFFSETs). The chapter teaches exactly that.
- **Turn 3 (Sep 20): chapters 6-8 written** - retargeting (points not angles, the match table,
  three samples per body, one solve per frame with its limit barrier and posture term, clips and
  settling, grounding, filtering in velocity space), servoing (the reference from three frames,
  the implicit spring, agreeing with the integrator, computed torque, passive forces), the floor
  (the unactuated root, what the floor must supply, cones, contactTorques, the root as a
  preference, and why balance needs learning). Four more examples (6, 7a, 7b, 8), all passing;
  doc-sync 2194 lines, 0 drifted; doc-gate and check clean.
  * **Doc comments rewritten as principles** (they are folded verbatim, and the tutorial carries
    no development history): robot.zig's PointSample, solvePointCloud, buildPointSamples;
    robot_dance's RetargetOptions.ground, Clip.smoothed, Tracker (both comments),
    contactTorques, contactConsistentTorques, limpKeepArmature. No quote in robots.html moved.
  * Measured while writing 7b: one shoulder at 1 Hz, worst body error 0.056 deg limp against
    0.58 deg on the model as written (its springs and dampers) - the example asserts < 0.1 deg and
    more than 5x.
- **Turn 4 (Sep 20): chapters 9-13 written** - the maximal ragdoll, learning to track (the gym, PPO,
  SAC), SuperTrack, the GPU training kit (all 27 kernels folded by family, compute_host's
  submission and readback, the three kit learners), and running it in a page (cartpole_duel).
  Four more examples (9, 10a, 10b, 11), twelve in all, all passing; doc-sync now pairs the page
  with zimrphysics and cartpole_duel too: 7412 lines, 0 drifted; doc-gate and check clean.
  * **Doc comments rewritten as principles** in robot_gym (TrainerOptions twice, the PPO minibatch),
    robot_maximal (TwistHinge.first, two options, `build`), compute_host (two plan references,
    uploadAt's queue rule) and cartpole_duel (four blocks).
  * Measured while writing 9: the ragdoll driving humanoid_flex's right elbow to -0.8 rad (gravity
    off, 4 Hz motors) is 1.07 deg off at 2 s and 0.079 deg at 4 s, with or without the swing-twist
    cone limits: a chain of soft motors settles more slowly than one spring. The example drives 4 s.
- **Turn 5 (Sep 20): the tutorial is complete, and it can no longer drift from the code.**
  Chapters 14 (conventions and gotchas) and 15 (recipes) written; chapter 16 is a GENERATED
  reference of every public declaration in robot_dance, robot_gym, robot_supertrack,
  robot_maximal and zn_mlp.

## 14. Keeping the tutorial in sync (Simon, Sep 20: "as we work on supertrack / drecon, we will
## always keep the tutorial in sync")

- **The tutorial's code is generated, never pasted.** Every code block in
  robot-mocap-tutorial.html names its declaration (`data-src` = file, `data-decl` = how its first
  line starts, `data-in` when that is ambiguous), and `tools/doc_folds.zig` fills it in: the doc
  comment through the closing line, exactly. `zig build doc-folds` regenerates every block and the
  chapter 16 reference; **the gate now runs it** (in place with the default -Dautofix, strictly
  with -Dautofix=false) **and then doc-sync** - which, until now, was not in the gate at all. A
  code change the page doesn't reflect cannot pass the gate.
- **What stays manual is the prose.** When SuperTrack / DReCon work changes what a module does,
  update the chapter that explains it in the same turn: 11 (SuperTrack), 12 (the kit), 10 (the
  gym), 7-8 (servo, balance), 9 (ragdoll). New public API appears in chapter 16 by itself; give it
  a paragraph and a tagged block where it belongs. New examples go in
  `src/robot_mocap_tutorial.zig` as tests and appear as tagged blocks.
- **The comment voice (Simon, Sep 20): casual and verbose.** Say what a thing does, why it is built
  that way, and what goes wrong otherwise - second person, explained rather than shouted, no
  development history (that lives here, in the plan). robot_dance.zig's public API and the
  examples file are rewritten in it; robot_gym, robot_supertrack, robot_maximal, zn_mlp and
  compute_host follow as the SuperTrack / DReCon work touches them, and the folds update
  themselves.

---

## Entries from the new plan (rl_track_plan.md, Sep 20)

- **Sep 20 — T0: the plan rewritten, precise, for 30 turns.** Read the survey Simon pointed at
  (Bao et al. 2024, arXiv 2404.17070: DRL for bipedal locomotion). It is robotics-flavoured, but its
  taxonomy places everything we are building: residual vs guided vs reference-free end-to-end
  policies; feedback-DRL hybrids (a non-learned planner over a learned controller - DReCon exactly);
  learned hierarchies; PPO's dominance for parallel throughput; model-based RL as the
  sample-efficient branch (SuperTrack). The new plan: goals G1-G5 with pass/fail numbers, the
  methods placed on that map, what exists, the resident architecture, the arithmetic (throughput
  stops being the constraint once physics is on the GPU), T1-T30 each with one deliverable and its
  known answer, decisions D1-D7, ranked risks with fallbacks.
  * **Corrected on the way: flex2 is nq 51 / nv 43** (16 hinges, 7 balls, the free root) - the
    old plan's "36 DOF" was wrong. (A first count said 20 hinges: the slice ran past
    `</worldbody>` into the tendon section, whose `<fixed><joint joint=...>` references look like
    joints. Bounded to the worldbody, 16 - the tutorial's count was right.)
  * The old plan is this file's body above, verbatim; code and notes that cited its sections now
    cite this journal (same section numbers). The tutorial's SacAgent fold regenerated itself.
  **Next: T1 - LAFAN1 locomotion into assets, audited; D1 (the elbows).**
- **Sep 20 — T1 (part 1): LAFAN1 locomotion, converted and verified.** LAFAN1's official BVHs
  are in a Git LFS archive whose host this sandbox can't reach (403); Holden's Motion-Matching
  repository is a plain archive whose `resources/database.bin` holds walk1 / run1 /
  pushAndStumble1 (subject 5) processed by its `generate_database.py`: cut, resampled 30 -> 60 fps
  (and deliberately 10% faster), a Simulation footprint bone in front of LAFAN's 22, local
  quaternions stored w-first, each take also mirrored. Verified on the file before anything used
  it: the parent array IS LAFAN's order behind the footprint bone; bones never stretch (4e-6 m).
  * **`tools/lafan_db.zig`** (`zig build lafan-db -- <database.bin> <dir> <seconds>`): the takes
    back to BVH through zimr's own codec - LAFAN's skeleton, Hips as root (footprint folded in),
    Z-Y-X channels, cm, End Sites - and it VERIFIES each file by reading it back and running FK
    both ways; it refuses to write past 0.01 cm. **`assets/lafan1/`**: walk1 and run1 (60 s each,
    ~2.1 MB), pushAndStumble1 (4.7 s), all within 0.001 cm of the database; README with the
    provenance and the licence (CC BY-NC-ND 4.0).
  * **The check caught three things on the real data.** (1) asin(-r20) is ill-conditioned near
    +-90 deg - the middle angle is now atan2(-r20, hypot(r00, r10)). (2) Near gimbal lock the
    first and last angles are each ill-determined; computed independently their errors add, so
    x is now the REMAINDER after undoing z and y. (3) The actual failure: **database.bin holds
    two non-unit quaternions** (Simulation and Hips, |q| = 1 + 9.6e-5, one frame of run1), and
    rotating by a non-unit quaternion scales by |q|^2 - the REFERENCE FK was a millimetre off.
    Every stored rotation is now normalised on the way in. (Located by making the failure message
    name its frame, bone and both positions - a check that doesn't locate itself starts a hunt.)
  * **LAFAN has no rest pose**: its bones point along +X, so zero rotations are a straight line.
    `retargetClip` needs the capture's rest to BE flex2's rest (it pairs it with qpos0). Next:
    construct it - aim each capture bone along the flex2 segment it drives; joints with several
    children (hips, chest) by a least-squares rotation (Wahba's problem) - with its own known
    answer (segment directions vs flex2's, per bone).
  * Tutorial: §3.8 (the locomotion data, and `eulerZYX` as a generated fold).
  **Next: T1 part 2 - the constructed rest pose, `auditClip`, the locomotion retarget audits, D1.**
- **Sep 20 — T1 (part 2): the route to LAFAN, the clip audit, and D1.**
  * **GenoView** (Simon's upload: the Geno mesh, `Geno_bind` / `Geno_stance`, the export scripts)
    points at **"LaFAN resolved"** - all of LAFAN1 retargeted onto Geno, the skeleton our dance and
    match table already use. That is the simplest route: no new rest-pose machinery. Its data is on
    theorangeduck.com, which this sandbox can't reach - asked Simon for `bvh.zip`. The plan to
    CONSTRUCT a LAFAN rest pose (aim bones along flex2's rest; Wahba for multi-child joints) is set
    aside; the motion-matching conversions stay, as the second route of a cross-check.
  * **`auditClip` / `ClipAudit`** (public, allocation-free): residual, range excess, sign flips,
    the worst single-frame jump - W1.0's audit as library code. Tutorial §6.8.
  * **D1 measured, on the dance's right arm (10 s, 5 Hz):**
        elbow   forearm dir mean/worst   upper arm mean/worst   residual mean/worst   worst jump
        ball    34.9 / 87.8 deg          9.2 / 30.3             6.5 / 13.9 cm         0.41 rad (the elbow, frame 76)
        hinge   16.2 / 46.9              13.7 / 45.1            7.4 / 17.0            0.22 rad (a shin)
    The ball was chosen for exactly the fit it fails to give - its orientation targets fight the
    position samples (flex2 rests elbow-bent 109.5 deg; the capture's stance arm is straight).
    **D1 taken: both elbows ranged hinges** (the right's axis mirrors the left's: pseudovector,
    (0,-1,-1) -> (0,-1,1)); flex2 is now nq 48 / nv 41, 17 hinges, 6 balls. The D1 test stays and
    asserts the hinge's forearm keeps winning. The model file's comment says why, with the numbers.
  * **A crash it exposed:** the B0-B2 test zeroed flex2's ARMATURE (`limpReduced`, "for fairness
    with the ragdoll") - a ragdoll flex2 can't even have - and with the new elbow's poses a pivot
    went negative (-7e-8, the left ankle: tiny foot and toe bodies). The limp is now chosen per
    model: armature zeroed only when a maximal twin is built (no ball joints).
  * **Quality item, recorded in the plan:** with either elbow the arm is 14-16 deg off the capture
    on average - the paired rest poses disagree at the elbow. A matched or solved rest is the fix.
  * Verified: robot_dance fast and slow suites, all 12 tutorial examples, doc-folds (the new folds
    and the reference filled themselves - 92 rows), doc-sync 7611 lines 0 drifted, doc-gate, check.
  **Next: Simon's LAFAN-on-Geno -> walk/run retargets and their audits, the two-route cross-check;
  then T2 (the GPU world: FK on the kit, parity with robot.zig).**
- **Sep 20 — the tracking set, and the plan refocused on it.** Simon's four clips (LAFAN1 on Geno:
  walk1, run1, dance2, fallAndGetUp2, subject 2) and a new goal: the fastest route to tracking
  THESE with quality under small perturbations, with a SuperTrack + SAC + MPC hybrid; motion
  matching moves to the end.
  * **The clips.** Full takes are 57-89 MB each. Cut to 20 s windows (18 s for the get-up, chosen
    to hold a whole standing -> fall -> ground -> rise cycle) past the binding pose at each take's
    start, and stripped of their 40 finger joints - `bvh_trim` gained a drop list, a stub End Site
    for any joint that loses all its children, and a round-trip check of what it writes. 7.5 MB ->
    3.3 MB a clip.
  * **Audited (the "reference set" test, slow):** residual mean 4.9 / 5.1 / 5.3 / 5.9 cm
    (walk / run / dance2 / get-up), worst 8.0-9.2; **0 range excess, 0 sign flips**, worst
    single-frame jump 0.10-0.14 rad. Better than the old dance (7.4 cm, 0.22 rad).
  * **A new measure, `lowestBodyPoint`, earning its keep immediately:** the references put the body
    THROUGH the floor - 2.7-3.8 cm for walk/run/dance, **10.0 cm for the get-up**, which lies down
    while grounding shifts by the median lowest FOOT point. A tracker would fight that. It is now
    D8 in the plan, decided at T4 before anything learns.
  * **A precondition that was never stated:** `retargetClip` matches a capture and its rest pose
    joint by joint BY INDEX. The trimmed clips (46 joints) against the full stance (75) walked off
    the end of a scratch array. Stated and asserted now; `assets/lafan1/Geno_stance.bvh` is the
    stance cut the same way.
  * **The plan, rewritten around the goal:** G1 quality (< 6 cm, < 8 deg mean, no fall), G2 shoves
    (50-150 N, no fall in 20 runs, back under G1 within 1 s), G3 every hybrid part earns its place
    by ablation, G4 a frame under 4 ms desktop / 16 ms phone. Order chosen for speed to a result:
    the task and SuperTrack first on the CPU sim we already have (T2-T9), the GPU simulator next
    for the 50x that every later experiment needs (T10-T15), then the hybrid (T16-T21), then
    quality and robustness on all four clips (T22-T26), then motion matching and DReCon (T27-T30).
  **Next: T2 - Local(), with its invariance and round-trip known answers.**
- **Sep 20 — T2: the state a tracker sees, and its two known answers (plus a third that caught a
  design bug).** `src/robot_track.zig`: `State` (every body's world pose and velocity),
  `local` (the state in the root's frame, heights and up kept in world), `twoAxis` /
  `fromTwoAxis`, `integrate` (velocity then position, world-frame w pre-multiplied),
  `accelerationsBetween`. `robot_dance.pointVelocity` is now the primitive under `bodyVelocity`,
  because a tracker wants the velocity of a body's frame ORIGIN, not its centre of mass.
  * **`local` leaked the character's absolute position.** It wrote an entry for the WORLD body
    "so indices line up" - and the world's origin seen from the root is exactly where the character
    is standing. The invariance check read 8.87, the distance walked. The world body is out, and
    the doc says why.
  * **The rotation check was measuring f32, not the integrator.** `2 acos(w)` for a w near 1 loses
    half its digits: it reported 0.00098 rad at BOTH 60 and 120 Hz - its own precision floor. Small
    angles now come from the quaternion's vector part.
  * **The numbers:** invariance 1.1e-6 under a yaw and a 10 m walk, against 0.21 for a lift or a
    tilt (the controls: a representation blind to everything is useless); two-axis round trip
    < 1e-6; integrator velocities exact (6e-8), positions 54 um mean at 60 Hz and 15 um at 120
    (x0.28 - the O(dt^2) signature), rotations 4.4e-4 -> 1.7e-4 rad.
  * Registered as a test root, in the robot aggregator, and in doc-sync; tutorial §11.5 with the
    folds; lint, doc-folds (0 regenerated after), doc-sync, doc-gate and check all clean.
  **Next: T3 - actions (PD offsets on the reference), with zero offsets reproducing the reference's
  targets exactly.**
- **Sep 20 — T3: actions, and the actuator model the policy acts through.** `applyAction` makes an
  action a displacement in velocity space and hands it to `integratePos`, so a hinge adds an angle
  and a ball composes `exp(a/2)` on the right without anyone re-deriving either; the free root gets
  nothing. Zero action reproduces the reference bitwise. A bounded action reaches 0.425 m at 0.2 rad
  and 0.198 at 0.1 - linear, no joint amplifying it.
  * **The PD law took three tries, and the failures were the useful part.** First: spring
    accelerations scaled by the mass matrix's diagonal. The robot collapsed - 175 deg mean on the
    walk. Lowering the frequency to 5 Hz and compensating gravity did nothing (167-175 deg at every
    setting), which ruled out my first two guesses. The diagnostic (|torque|, the diagonal's range,
    |err|, |vel| at frames 1, 2, 20) showed 100 rad/s and 116 kNm by frame 20: a runaway from the
    first frames. **Why: for a chain, (M^-1)_kk >= 1/M_kk, so a torque buys MORE acceleration than
    the diagonal predicts - the implicit damping the spring asked for arrives explicit and
    amplified, and explicit damping at 20 Hz with a 60 Hz step is unconditionally unstable.**
  * **The fix is to realise the spring through the model:** ask `stableSpringAccel` for the
    acceleration, then `inverseDynamics` (fixed base) or `floatingBaseTorques` (free root) for the
    torque that actually produces it. Stable, and exactly as weak as it should be - it knows where
    the clip IS, not where it is going.
  * **The numbers on the walk, fixed base:** computed torque with feedforward 0.022 deg mean (0.079
    worst); the spring 3.84 (10.5) at 20 Hz, 5.57 at 10, 2.93 at 40. The 20 Hz figure matches the
    predicted no-feedforward lag, ~2 v / omega. The test asserts BOTH sides - the spring must stay
    under 6 deg and over 1, because a spring as good as computed torque would mean the reference's
    velocity is leaking in and the offsets would have nothing to do.
  * Tutorial §11.6; lint, doc-folds, doc-sync, doc-gate, check clean.
  **Next: T4 - the task: reward, termination (by error, not height - the get-up lies down),
  reference-state initialisation, torque limits, and D8 (the reference's floor penetration).**
- **Sep 20 — T4: the task, and D8.** `TrackingError` / `reward` / `Termination` / `resetToFrame`,
  and an authority limit on the servo (`Gains.max_acceleration`, 400 rad/s^2 - it does not bind on
  the walk, so the spring's numbers are unchanged).
  * **The error is split into pose and place on purpose:** the four pose terms are measured in the
    root's frame, the two root terms in the world. A character making perfect shapes while drifting
    across the room passes the first four and fails the last two.
  * **Termination by tracking error alone.** A height test - the obvious one - would score the
    get-up's best possible tracking as a failure, because it lies on the floor for ten seconds.
  * **D8, and a first experiment that measured nothing.** With a free root and an open-loop servo,
    both floor options gave identical numbers (0.35 s survived, 0.012 m error): balance dominates
    and the floor never gets its chance. Re-run with the ROOT HELD on the reference, the question
    became answerable - and a third option appeared once both sides were measured. Grounded by its
    typical frame, the get-up lies 10.7 cm inside the floor; lifted clear of it, it floats 6.4 cm
    while standing. **Per-frame lifting, smoothed at 3 Hz, is right about both** (typical frame
    0.000 m, deepest -0.2 cm). Pose error was identical across all three, so geometry decided it.
  * Tutorial §10.1 (the task) and §6.6 (what one grounding offset cannot fix); lint, all
    robot_track tests, doc-folds, doc-sync, doc-gate and check clean.
  **Next: T5 - collection into per-environment replay rings with segment ids, and the window
  sampler that cannot straddle a reset or a shove.**
- **Sep 20 — T5: the data.** `Replay`: per-environment rings holding the simulator's own pose and
  velocity (half the memory of body features, and it cannot disagree with the model - FK
  reconstructs the rest on sampling), the action, the reference frame, and a segment id that
  changes at every reset and every shove. `sampleWindow` returns only frames sharing one segment:
  checking the ends is enough, since ids only increase. `Fleet`: characters tracking clips
  together - observe, act, step, with actions arriving in one flat array because that is the shape
  the GPU version wants.
  * **The property, 10,000 draws:** every window one unbroken stretch - same segment, consecutive
    frames, nothing since overwritten - from a ring deliberately filled with segments of 1, 2 and
    100 frames wrapping several times. 10,000 of 10,000 returned a window.
  * **The fleet, with noise instead of a policy:** 8 environments x 600 steps, mean reward 0.688,
    228 episodes, 236 segments, 200/200 sampled windows reconstructing into sane states.
  * **★ The finding that matters for T7:** draws of 200 at window length 8 / 16 / 32 gave
    200 / 200 / **0**. Segments average ~21 frames because an unguided character loses the reference
    in a third of a second - so the world model's 8-frame windows are abundant and the policy's
    32-frame windows do not exist yet. Recorded as D10: grow the policy's window with episode
    length, or keep termination loose early.
  * Tutorial §11.7; lint, tests, doc-folds, doc-sync, doc-gate and check clean.
  **Next: T6 - the world model on the kit, 8-frame windows, and its multi-step error against
  horizon on held-out windows.**
- **Sep 20 — an adversarial review of T2-T5 (Simon: one turn, long horizon).** Read back everything
  written since the plan was refocused, hunting for what breaks LATER: hidden preconditions,
  allocation-failure leaks, numerical traps a half-trained network will find, ambiguous semantics,
  magic constants, and tests that cannot fail. Fourteen findings, all fixed, with regression tests
  where a test could exist.
  * **Would have produced NaN:** `fromTwoAxis` normalised whatever it was handed - and a network
    outputs near-zero or parallel axes constantly early in training. Now total: a degenerate axis
    falls back to a fixed one (wrong but finite; NaN would have been untraceable three layers away).
    New test feeds it zeros, parallel, antiparallel, 1e-9 and 1e9 and demands a unit rotation.
  * **Would have servoed at the wrong rate, silently:** the `Fleet` drove the servo at the CLIP's
    frame time while the simulator stepped at the MODEL's timestep, with nothing checking they
    agree. A 30 fps clip would have "worked". Asserted now, with the clip's `nq` and length.
  * **Would have become an off-by-one in a kernel:** a window of n records is n-1 transitions, so
    "an eight-frame window" quietly meant seven steps. `Window` now counts `steps` and derives
    `frames()`, and a test pins the contract.
  * **Would have reintroduced the T2 bug:** `local` accepted root 0 (the world), which puts every
    position back in world space - the exact leak the invariance rung caught. Asserted. The root
    body is also derived from the model now (`rootBody`) instead of being hardcoded as 1 in three
    places.
  * **Would have leaked on a failed allocation:** `State.init` and `Replay.init` now use errdefer;
    the `Fleet` owns an ARENA instead - a dozen buffers allocated one at a time is a dozen chances
    to leak the previous eleven, and an arena has one.
  * **Would have moved the floor:** `integrate` stepped body 0, the world, if a model predicted an
    acceleration for it. Skipped now, and tested.
  * **Unstated preconditions, now stated:** `liftPerFrame` / `liftAboveFloor` write the root's
    height, so the clip must be the model's and the model must have a free root; `applyAction`,
    `Replay.append`, `Fleet.observe` and `Fleet.step` check their slice lengths; `trackingError`
    refuses a one-body model; `resetToFrame` documents that frame 0 starts at 1.
  * **A test that could not fail:** D8 printed its numbers and asserted nothing. It now asserts the
    decision - as retargeted buries the clip, one offset floats it, per frame is right on both
    sides.
  * **A measurement reporting its own noise:** `auditClip` took ball-joint jumps as `2 acos(dot)`,
    which cannot resolve below ~1e-3 rad in f32 - the same floor that fooled the T2 integrator
    check. Now from the relative quaternion's vector part. The reference set's numbers are
    unchanged (its jumps are far above the floor), which is the right outcome for a fix like this.
  * **A tool that would mis-extract:** `doc_folds` treated any line ending in `;` with a `{` as a
    block, so a one-line `pub const x = [_]u32{ 1, 2 };` would have swallowed the next declaration.
    It counts braces now. No such fold exists yet - which is why it was worth fixing now.
  * Verified after: all robot_track tests (fast and slow), the whole robot_dance suite including
    slow, doc-folds (11 blocks regenerated by themselves), doc-sync 8295 lines 0 drifted, doc-gate,
    lint and check.
  **Next: T6 - the world model on the kit, 8-step windows, multi-step error against horizon.**
- **Sep 20 — T6a: the world model's question, and the harness that will judge the answer.** Split
  T6 in two so each half is verifiable: this turn defines what the model is asked and calibrates
  the measurement; next turn trains one against it.
  * **The input** is the state in the root's frame plus the servo's TARGETS - two numbers a hinge
    (sine and cosine; an angle wraps) and six a ball. Not the servo's error: the error depends on
    the state, and in a rollout the state is the model's own guess, so feeding it would mix the
    model's drift into its input. **The output** is every body's linear and angular acceleration in
    the root's frame, divided by 30 so a network's outputs sit near one.
  * **`measureDrift`** rolls a source through recorded windows on its own predictions, targets from
    the record, and reports mean body position and rotation error at every step. Sources are a
    union rather than all going through the `Predictor` interface, because the two reference
    sources are properties of the RECORD, not models.
  * **Calibrated first, with two sources that cannot be wrong** (200 identical windows):

        step            1        2        4        8
        oracle      0.25 mm  0.47 mm  0.84 mm  1.64 mm
        hold first  0.25 mm  19.3 mm  85.7 mm   346 mm

    The oracle is the integrator's accumulation floor; the baseline is what "repeat the last
    acceleration" costs. 211x between them at 8 steps is the room a learned model has to land in.
  * **The first-step agreement assertion caught a flaw in its own test:** both measurements shared
    one RNG, so each drew a DIFFERENT sample of windows and the curves were not comparable. Each
    source now gets its own identically-seeded generator. Without that assertion the test would
    have passed and the comparison would have been quietly meaningless.
  * Tutorial §11.8; lint, all robot_track tests, doc-folds, doc-sync, doc-gate and check clean.
  **Next: T6b - the MLP, trained on 8-step windows of its own predictions, measured on this curve.**
- **Sep 20 — T6b: a network on the kit, with its gradients proved.** `src/kit_mlp.zig`:
  `KitMlp(M)` - a `Spec` of layer sizes, `forward`, `trainStep` (mean-squared error and Adam), and
  the weights out for saving and parity. Parameters laid out one contiguous block a layer, weights
  then biases, exactly as `dense_fwd` reads them; activations as the batch's input, each layer's
  output, then the targets. Registered as a test root and in doc-sync; tutorial §12.4.
  * **No zimrnum-graph twin, on purpose.** The plan said "graph first, then the kit with parity",
    which is how the cartpole was done - but the kit's kernels already run on the CPU twin, so a
    graph version would be a second copy of the same maths to keep in step for no benefit. The
    cartpole predates the twin.
  * **The checks:** forward matches a plain-Zig reference to 1e-6; **every parameter's step is
    checked against finite differences on that reference** - 30 of 37 had a gradient worth checking,
    none moved uphill, and each moved by exactly one learning rate, which is what Adam's first step
    is; and it fits sin(3x)y, 1.697 -> 0.002 in 400 steps. A falling loss is not evidence that a
    backward pass is right; a weight moving the wrong way against a measured gradient is evidence
    that it is wrong.
  * **Two things the kit taught me on the way.** Readback is PREFIX-ONLY and the prefix
    (`element_count`) has to be set before the work is SUBMITTED, not before the read - otherwise
    `readLatest` hands back an empty slice, which is what the first run did. And on a GPU that
    readback is a frame late, so `forward` and the loss are exact on the twin and merely recent on
    a device; stated in the module's header where it will be read.
  * **doc-folds caught my own mistake:** the tutorial fold named `"        pub fn trainStep("` with
    its indentation, and declarations are matched trimmed - so it reported `NotFound` by name
    instead of silently writing nothing. The diagnostics added in the review turn paid for
    themselves.
  **Next: T6c - the world model on this trainer, measured against T6a's drift curve.**
- **Sep 20 — a second adversarial review (T6a and T6b).** Six findings, all fixed, one of them a
  real bug that would have corrupted training silently a dozen turns from now.
  * **★ A record did not know which clip it came from.** `Fleet.targetsAt` rebuilt a record's servo
    targets from the environment's CURRENT clip - but a ring outlives episodes, and every restart
    picks a clip at random. With one clip it is invisible; with four (T22, and D9's single policy
    for all four) every window older than the last restart would be rebuilt against the wrong
    reference, poisoning the world model and the policy with no symptom but bad results. Records
    now carry their clip. The regression test runs two clips of different lengths: 1,285 of 3,200
    records sit past the short clip's end, and each is attributed to the long one.
  * **A training step read back every weight.** `trainStep` set the readback prefix to the
    parameter count and copied the weights each step - and since the kit's readback copies that
    prefix out of ALL SEVEN buffers, that was megabytes a step to learn one float. One number comes
    back now; `requestParameters` widens it when someone actually wants the weights. (The first fix
    did not work: `init` left the prefix wide, so `@max(prefix, 1)` kept it there. Measuring the
    default is what caught it.)
  * **`forward` demanded a full batch**, so a rollout asking one state at a time would have padded
    to 256 rows - a hundred times the work for the same answer. Any batch up to the maximum now,
    and the widened readback is restored afterwards so a caller does not silently keep paying for
    it.
  * **`Spec.hidden` was borrowed** and kept for the network's life: a caller building layer sizes in
    a scratch buffer would have left a dangling slice. Copied now.
  * **Activation codes were magic numbers** (1, 2) that happen to match the kernel module's enum;
    they are the enum now.
  * **Nothing checked that the parameters fit the kit.** Sizing the world model afterwards showed
    why it matters: 361 -> 512, 512 -> 108 is 503k parameters against buffers of 262k. It would
    have written past the end. Asserted, with the numbers in the message - and the sizing is now in
    the plan, before T6c writes the network.
  * Verified: all robot_track tests (fast and slow), kit_mlp's three, doc-folds, doc-sync 8618
    lines 0 drifted, doc-gate, lint, check.
  **Next: T6c - the world model, at 256 wide, measured against T6a's drift curve.**
- **Sep 20 — T6c: the world model, and a phase of work the measurement removed.**
  `src/robot_world.zig`: `WorldModel(M)` - `KitMlp` over the T6a features, one training example per
  recorded transition (the state, the targets it was driven toward, the acceleration it produced).
  * **The result, on data collected with noise for a policy** (200 windows, mean body position
    error by step):

        step            1        2        4        8
        oracle       0.3 mm   0.5 mm   0.9 mm   1.7 mm
        LEARNED      5.0 mm   8.1 mm  14.1 mm  35.4 mm    256 wide, 128 rows, 2500 steps
        hold first   0.3 mm  18.5 mm  84.0 mm   342 mm

    9.7x the baseline at 8 steps; the bar was 5x. Loss 9.8 -> 1.2 and still falling, so this is not
    even converged.
  * **★ The finding: single-step supervision cleared the bar.** SuperTrack trains its world model
    through the rollout - gradients through the integration, kernels we do not have. The first
    measurement said the simpler thing suffices at this quality, so that work is not needed. It was
    worth building the harness before the model to be able to say that.
  * **How the measurement guided it, in order:** the small configuration (128 wide, 600 steps) gave
    3.7x with the loss still falling, which pointed at capacity and training rather than at a
    better training scheme. Widening and training longer took it to 9.7x. The committed test keeps
    the quick configuration and asserts 3x, monotone growth, and no step more than doubling the
    previous one.
  * **Still unmeasurable: 32-step drift**, which is the horizon a policy is unrolled over. Windows
    that long do not exist yet (D10 - an unguided character loses the reference in a third of a
    second). It becomes measurable when a policy survives longer, in T7.
  * **Operational:** the build refused to start - its own disk guard, at 97% full with an 8.4 GB
    `.zig-cache`. Pruning by age left dangling manifests ("FileNotFound"), so the cache was cleared
    and rebuilt cold (42 s). Worth knowing: prune the whole cache, not part of it.
  * **doc-folds caught the same mistake I made last turn** - a fold key copied WITH its indentation
    - so the tool now trims the key, since it matches against the trimmed line anyway. Verified by
    re-indenting the key on purpose and watching it work.
  **Next: T7 - the policy, trained by backpropagating a tracking loss through this model.**
- **Sep 20 — T7 attempt: a planner that could not work, and the reason why.** Started MPPI through
  the world model (forward passes only - no adjoint kernels - with the horizon taken from the drift
  curve: plan only as far as the model is trustworthy). It tracked WORSE than doing nothing.
  Chasing that down found a foundational bug.
  * **★ THE FLEET HAD NO FLOOR.** In this engine the articulated-body dynamics (`robot`) and
    collision (`zimrphysics`) are separate, joined by a `robot_physics.Bridge`: poses out, contacts
    back. The dance rungs build that world (`runOnFloor`); the fleet never did. A floor geom in the
    model TEXT collides with nothing on its own. So every character since T5 has been in free fall
    - joints tracking beautifully (pose error 8 mm) while the whole body sank 0.58 m in 20 frames,
    `contact_count` zero at every frame.
  * **How it surfaced, and why it took three turns:** every controller and every horizon gave
    IDENTICAL survival (25.0 frames, 8 episodes), which is physically impossible - free fall does
    not care what the joints do. The evidence had been there since T4: "loses the reference in a
    third of a second" was the time to fall 0.6 m, and the ~21-frame episodes were a stopwatch on
    gravity.
  * **Fixed:** every environment owns a collision world and a bridge; `driveOnce` syncs, collides
    and harvests before stepping, and the planner imagines futures in its own world so an imagined
    step is the step that would be taken. A collision failure now fails loudly rather than leaving
    a character quietly falling through the floor.
  * **The guard:** from a reference start with NO actions, after 30 frames the character must be on
    the floor - 7 mm below it with 7 contacts, rather than 576 mm below it with none.
  * **What it changes.** Episodes 21 -> 46 frames. **32-step windows 0/200 -> 200/200**, which makes
    D10 moot: the policy window scarcity was an artifact of the missing floor. The world model loss
    is much higher (26.4 -> 8.6 against 10.8 -> 3.9) and its drift advantage 2.3x instead of 3.7x,
    because contact dynamics are discontinuous and genuinely harder than falling.
  * **What it invalidates:** the numbers in T5, T6a and T6c describe free fall. The harness, the
    features, the trainer and the model code are all sound - the dynamics under them were wrong.
  * Lint, check, all robot_track tests (fast and slow), robot_world, doc-folds, doc-sync, doc-gate
    and doc-pages clean.
  **Next: T6d - retrain and re-measure on the ground, then T7 with a model of the real dynamics.**
- **Sep 20 — the plan, revised around a PPO baseline (Simon's call), and reviewed whole.**
  * **★ T7 is now the PPO baseline: DReCon's RL half on a five-second get-up**, placed BEFORE
    SuperTrack's policy. It is model-free, so it waits on nothing that is still being measured; it
    needs only pieces that already have known answers; it is the first end-to-end tracking result;
    G3's table needs the baseline anyway; and a policy that survives produces the long episodes
    every later rung wants. Motion matching stays in Phase F - DReCon splits in two and the halves
    sit at opposite ends of the plan.
  * **What the paper settles, taken from its own ablations:** initialise the policy's last layer
    near zero (Fig 9 - and our servo is stronger than their open-loop, so it matters more here);
    a subset of bodies and joints in the state and action (Fig 12, and Fig 13 says pose-plus-errors
    is the right state); the action filter beta = 0.2 with k = 2 (Figs 6, 7). Our present
    582-number observation over all 19 bodies with a 35-DOF action is the arm of Fig 12 that lost.
    Two layers of ~48 units (D11) is defensible: their Fig 8 has 16 and 32 learning FASTER early on
    a task far larger than one clip. **DReCon's conclusion calls getting up off the floor
    unsolved**, which makes it a bold target and a cheap early failure.
  * **New decisions:** D11 (the policy's size and its subsets), D12 (the reward's shape - ours lets
    one bad limb hide behind five good ones; theirs sums inside the exponential and forces fixing
    the worst-tracked body, which is what a get-up needs).
  * **Phase B had a hole**: it was titled T5-T9 but the schedule jumped from T6d to Phase C - the
    T6 subdivision had displaced the old T7-T9. Now T7 (PPO), T8 (SuperTrack's policy, reusing
    T7's machinery so only the gradient's source changes) and T9 (the phase gate).
  * **The whole plan reviewed:** three finished rungs now carry a ⚠ saying their numbers were
    measured in free fall (the findings' shape holds, the numbers do not) - T6c's "single-step
    supervision was enough" is exactly the conclusion the wrong dynamics could have handed us for
    free, so T6d re-decides it. Two standing rules added: a measurement is only as good as the
    world it was made in, and every experiment carries a control. The collision-bridge fact is now
    in the inventory where it cannot be forgotten. Risks re-ranked (the wrong-world class is now
    #1, CPU throughput #2, the get-up #3) and every stale rung reference fixed.
  * doc-sync caught the tutorial teaching an assertion I had rewritten at the end of last turn;
    doc-folds regenerated it. Check, doc-gate and the chain clean.
  **Next: T6d - retrain and re-measure on the ground; then T7a's throughput number.**
- **Sep 20 — T6d: re-measured on the ground, and the conclusion reversed.** Same features, harness
  and network; a character that stands.

        horizon      oracle    LEARNED   hold first   ratio
        8 steps      2.7 mm     61 mm      357 mm      5.8x
        32 steps     9.5 mm    1.42 m     6.04 m       4.3x

  * **★ T6c was wrong, and wrong in the way the bad dynamics predicted.** "Single-step supervision
    was enough" held at 9.7x on free fall; on the ground it is 5.8x at 8 steps - still past the
    bar, but only just - and at 32 steps the model is **1.42 m** out, which is not a model of
    anything. The oracle at 9.5 mm says the harness is sound and the error is the model's own,
    compounding. Free fall is an easy thing to predict and it flattered the method. Loss 25.3 ->
    5.9 against 9.8 -> 1.2 in free fall: contact dynamics are discontinuous and genuinely harder.
  * **What it changes:** T8's policy window is **8 frames, not 32** - gradients through a 32-frame
    rollout of this model would be gradients of fiction. The options are ranked in the plan
    (unroll 8 and let the critic carry the rest; train the world model through its rollout with
    the adjoint kernels T6c said we could skip; or unroll the real simulator). D6 is resolved: 256
    wide, and the window is whatever the drift curve licenses.
  * **★ T7a's gate, measured: 2,642 env-steps/s** (16 environments, contacts, single-threaded) -
    within a whisker of DReCon's own 2,500/s on 8 parallel Bullet sims for a comparable character.
    So 1M samples is 6 minutes here, 5M is 32, 20M is 2.1 hours: PPO on one short clip is
    affordable as background runs if it learns inside ~20M, and waits for Phase C if it does not.
    One core in this container; on a real machine the fleet loop is trivially parallel over
    environments.
  * **The tutorial taught the free-fall numbers as fact** until this turn - §11.9 now carries both
    horizons and the point they make: a model may be unrolled as far as its drift curve licenses
    and no further.
  * Two small things the run cost: `std.time.Timer` does not exist in this pinned std (the lint
    rule says so in its own message - `std.Io.Clock.now(.awake, io)` is the house idiom), and the
    first edit script aborted on an assertion that lives in the other module, so a background run
    measured the old configuration. Check the file you think you edited.
  **Next: T7a - the residual policy machinery (near-zero output init, DReCon-shaped observation and
  action subsets, the action filter), with its zero-action known answer.**
- **Sep 20 — T7a: the residual policy's machinery, four known answers.** `src/robot_policy.zig`.
  * **The observation is 108 numbers** - three centre-of-mass velocities (simulated, reference,
    difference), six watched bodies' positions and velocities, the same six as ERRORS against the
    reference, and the filter's last output. DReCon's is 110 for a character with half again as
    many degrees of freedom, which is a good sign the design transfers rather than a coincidence.
    **Invariance measured: 1.5e-6** under a 10 m move and a 0.8 rad turn; a 0.15 rad lean changes
    it by far more, which is the control - an invariant observation must not be an oblivious one.
  * **The action is 27 of 35 degrees of freedom** over hips, knees, ankles, abdomen and shoulders,
    named by the BODY each joint drives (as DReCon lists theirs, and because `Imported` carries
    body names but not joint names). Toes and elbows stay with the reference.
  * **The heading frame is yaw-only at the centre of mass**, with a fallback for a character lying
    face-down whose forward axis points at the floor and whose horizontal part vanishes. That case
    is exactly the get-up, which is exactly the clip this is for.
  * **The zero-action property, exact:** a zero request expands to zero on all 35 degrees of
    freedom, so the servo drives the character untouched - the property that lets a policy start
    as the servo and improve from there, inherited from T3's bitwise-exact `applyAction`.
  * **`kit_mlp` gained `output_scale`:** the last layer initialised uniform near zero, DReCon's
    Fig 9. Measured: largest first action **0.114** against **3.88** untouched - and the
    controller's filter takes a fifth of that on the first step, so the character feels about two
    hundredths of a radian while the servo does the work.
  * **Cost of the turn, twice:** two edit scripts aborted before writing because `zig fmt` had
    reformatted the text I was matching on - the same class of mistake as last turn's. Scripts now
    assert that the file CHANGED before writing, which is the check that would have caught both.
  **Next: T7b - PPO on the five-second get-up, in the background, with the walk slice as control.**
- **Sep 20 — T7b-1: the PPO trainer, wiring proved with its control.** `src/robot_ppo_track.zig`.
  * **A PPO step is a DECISION**, held for `decimation` physics steps: reward averaged over them,
    terminal if either ended the episode, and no credit to a failed decision for the fresh start
    that replaced it. GAE (0.99 / 0.95), normalised per batch; epochs of shuffled minibatches
    through the existing `GpuPpoOn` - which, it turned out, already initialised its output layer at
    gain 0.01, so the option I started adding would have been a second knob for the same thing.
  * **The get-up window, from the capture itself:** the hips sit at 3-6 cm from 3 s to 9 s and
    rise 6 -> 81 cm from 9 s to 14 s. Frames 540-840 start lying and end standing. `Clip.window`
    carves it (poses, per-frame residuals and their bodies, all sliced together).
  * **Known answer: the untrained policy IS the servo** - 56.9 frames an episode and 9 ended, for
    both. **And its control** (standing rule 8, earning its keep): the same trainer with
    exploration at 1.6 scores 0.553 against 0.621, which a disconnected policy could not.
  * **Two process lessons.** Running `zn-robot_ppo_track` without `-Dtest-filter` ran all 492 robot
    tests with the slow ones on - importing `robot_gym` pulls the whole suite in - which looked
    exactly like a hang for fifteen minutes. And one long background run was SIGKILLed mid-suite
    when a tool call ended badly: training will run in checkpointed chunks, which a run should be
    able to do regardless.
  **Next: T7b-2 - checkpointing, then the get-up run in chunks, with the walk slice as control.**
- **Sep 20 — T7b-2: checkpoints, and the first PPO results on the ground.**
  * **Checkpointing:** weights, Adam's moments and step, counters; written to `<path>.partial` and
    renamed so a killed run keeps its last good checkpoint. Round trip exact: a trainer built from
    a different seed, after loading, matches the original to the bit on weights, moments and value.
    `-Dtrain-chunk` runs one resumable chunk per invocation and never runs in the slow suite.
  * **Judged by the mean action, against the servo alone:** get-up 78.2 vs 68.3 frames an episode
    (108 vs 130 ended) after 516k physics steps; walk 48.7 vs 40.6 (190 vs 227) after 264k. **Both
    learn, at similar rates** - the control says the setup works and the get-up is not anomalously
    hard yet. 108 against 130 is about two standard deviations: suggestive, and the training curve
    agrees (66.5 -> 81.8 frames an episode across the two chunks, noise included).
  * **Why "judged" matters:** training episodes carry exploration noise, and reward per step is
    confounded by resets (a character that loses the reference is put back on it and scores well).
    Survival under the mean action, against the servo on the same starts, is the honest number.
  * **The files:** `/tmp` markers failed silently last turn because this std's `Dir.cwd()` wants
    relative paths; checkpoints live in `train/` (git-ignored, kept in snapshots so a run resumes
    from one).
  * **The budget:** ~1,300 physics steps/s of TRAINING on one core, ~250k a chunk. The levers are
    in the plan; the cheapest is caching the reference's states per clip frame.
  **Next: more chunks on both clips, and the reference-state cache.**
- **Sep 20 — T7b-3 (Simon: "your call"): measured before optimising, and the guess was wrong.**
  * **The profile of one fleet step (452 us):** forward before colliding 28%, step + forward 61%,
    collision 7.5%, the reference's kinematics 2.7%. The reference cache I had proposed would have
    saved 2.7%. What the profile found instead was a REDUNDANT `forward`: every step ends with one,
    nothing writes to the data before the next step begins, and `forward` is deliberately
    uncached. Skipped behind the stage watermark; bitwise identical to the old path over 300 steps
    with restarts and shoves; **1.56x end to end** (186 iterations a chunk against 119) - more than
    the 28% suggested, since the trainer's evaluation steps the fleet too.
  * **The build cached a chunk:** identical binary and arguments meant a skipped run in 0 s - a
    chunk's whole effect is its side effect on `train/`. `-Dtrain-chunk` now makes the
    per-module run always execute. The editing script refused to guess between two matching sites
    and found the right one (`fast_run`, not `run`) - the check-that-it-changed rule paying off.
  * **The curve:** get-up +14.5% (516k) -> +35% (897k) -> **+38% (1.26M)**, 93.6 frames an episode
    against the servo's 68.0; at 897k reward per step overtook the servo's too, despite the reset
    confound. Walk control +20% -> **+24%** (635k). Flattening, as early PPO curves do.
  * **Next lever:** `rbt.step` + `forward` are ~85% of a step now; `robot.zig` documents a known
    inefficiency in `robot.project`. Engine-level, benched with `robot_bench`, and it pays for
    everything that simulates.
  **Next: more chunks; then the step's remaining 85%.**
- **Sep 21 — a turn that did not finish, and what it left.** One response ran out of room before
  it could report; its work landed anyway and was verified the next turn (check, lint, doc chain).
  * **Training chunks build ReleaseFast** (tests stay ReleaseSafe, checks armed). Same floating
    point; only the bounds and overflow checks go - for code those tests already proved.
  * **★ Judging on fixed starts, in a fleet of its own** (`evaluation_seed`). The old `evaluate`
    continued the TRAINING fleet's random stream, so the policy and the servo were judged on
    DIFFERENT starts and part of every difference between them was luck. Now the servo's number is a
    constant across chunks: if it ever moves, something other than the policy changed.
  * **The run, now at 2.80M physics steps (1,365 iterations):** training curve 73 -> 82 -> 95 -> 97
    -> 102 -> 106 -> 108 frames an episode in blocks of ~300k steps, still rising. Judged on the
    fixed starts: **get-up 93.3 vs 64.2 frames (+45%), 88 vs 138 ended; walk 54.9 vs 42.0 (+31%)**.
  * Lesson: when a turn dies, the container is the record. Diff against the last snapshot before
    doing anything - this one had changed two files and was still running a chunk.
- **Sep 21 — T7b-4: the trailing forward, and a step at 2.2x.** Reading `robot.step` showed it
  runs a full `forward` before integrating - so the fleet's own trailing `forward` computed the
  factorisation, constraints and dynamics solve purely for the next `step` to redo them. The
  readers between steps need four stages (`kinematics`, `comPos`, `crb`, `comVel`), now called
  alone; the entry guard asks for `velocity`. **364.5 -> 208.1 us a fleet step.**
  * **Proved four ways:** the bitwise test (full `forward` before every step vs the partial
    state, 300 steps, restarts and shoves) in ReleaseSafe AND ReleaseFast; the fleet test's exact
    post-floor numbers; the trainer's wiring test to the digit; the servo's judged score
    unchanged (64.2 frames, 138 ended - also confirming the fixed-start judging is a constant).
  * **A chunk now fits 308 iterations** against 186. The get-up, judged: **102.4 frames an
    episode, +59% over the servo**, 79 ended against 138, at 3.43M physics steps.
  * Two small lessons. "A passing test prints nothing" also means a filter typo prints nothing -
    `--summary all` with a forced run (`-Dtrain-chunk` makes runs uncacheable) SHOWS the count. And
    this build runner labels a successful run's stderr "failed command": the summary line is the
    verdict, not that label.
  * This turn was deliberately short on calls and long waits, after the last one died of neither.
- **Sep 21 — the north star moves to Simon's phone, and T7c.** Simon: train from scratch on his
  phone (CPU environment, GPU networks), download and upload weights himself, no weights from this
  side ever - and get the time to the bar from hours to minutes with the world model, modern SAC
  variants, MPC and the environment on the GPU. The plan now leads with that (§1), maps the modern
  methods onto a ladder each rung of which must save minutes on the phone (§2: symmetry and
  normalisation; the policy through the world model; high update-to-data SAC in the DroQ / CrossQ
  / SimBa line; TD-MPC2-style planning; the GPU environment), and adds T7c-T7e: the incremental
  trainer, the phone bench page, and the baseline measured on his device. `train/` is excluded
  from snapshots from now on.
  * **T7c:** `collect` / `learn` - a phone frame collects a few decisions and goes back to
    drawing; the update is dispatched when the batch fills and the GPU trains while the next one
    is collected. Weights as bytes in a versioned format (`ZPPOTRK2`) carrying the network's
    shape. Proved: iterate-from-pieces reproduces the old numbers to the digit; sliced == whole to
    the bit; a round trip across seeds matches down to the device-side Adam moments; bad files are
    refused by name.
  * **★ Found on the way: the kit's CPU twin keeps its buffers in module globals**, so two hosts in
    one process share them. The first version of the new test interleaved two trainers - every
    parameter differed while every count matched, which is what pointed at sharing rather than
    at slicing. **And an older test had been passing for the wrong reason:** the checkpoint round
    trip compared host A's Adam moments with host B's, i.e. one buffer with itself. It now defers
    that check to the bytes-based test, where it cannot alias.
  **Next: T7d - the phone bench page.**
- **Sep 21 — T7d, part one: the page, written and registered.** `examples/getup_train`: the
  flex2 humanoid and the get-up clip embedded; retarget, smooth, window and per-frame lift at
  startup; the networks on the GPU (`z.Compute(zn_mlp).initGpu`, as `cartpole_duel` does), the
  characters on the CPU; `collect` a slice of decisions a frame, adapted to the frame time the
  device achieves (grow under 18 ms, shrink over 24); training character 0 drawn in blue with its
  reference in grey; the survival curve as a text sparkline. Registered in both build tables.
  * **What the engine already had, found by reading rather than building:** a phone-correct upload
    (`web.userfile` puts a real transparent `<input type=file>` over the wasm-drawn button, because
    mobile Safari opens a picker only inside a genuine gesture); worker pools, with a measured note
    that 8 workers give ~3.4x on a phone and a hot CPU throttles the GPU; and `cartpole_duel`'s
    warning that flooding a phone's GPU queue stalls the whole device, compositor included.
  * **Blocked on a rule the project already states:** kit proofs importing `gpu/zn_mlp.zig` by path
    must live outside the zimr module. Exporting `robot_ppo_track` to pages put its tests inside.
    Moving them to their own file is next, then the weights buttons.
  * Stopped here deliberately: a long turn, and the last one that ran long died before reporting.
- **Sep 21 — T7d: the phone bench builds, with save and load.**
  * The trainer's tests moved to `robot_ppo_track_tests.zig` (4/4 pass there), which unblocked the
    page: it builds, lint-clean, and `check` passes for the whole project.
  * **Download did not exist**, so the web layer gained it, mirroring upload exactly: a real,
    transparent `<a download>` over the wasm-drawn Save button, its Blob refreshed after every
    batch with the previous object URL revoked. A mobile browser saves only from a genuine tap, and
    by the time a canvas-drawn button notices one the gesture has expired - the same reason the
    engine's upload is a real `<input type=file>`. `mocap_viewer`, the other page on that overlay,
    still builds.
  * **Size:** 17 MB standalone in debug, **7.5 MB in `-Dmode=ship`**. The capture is 3.2 MB of
    text and the page needs only 14.5 s of it - the obvious next saving.
  * **Honest status: compiled, not run.** There is no WebGPU in this container. The pipeline under
    the page is the one the native tests prove; the device-only questions (does WebGPU accept the
    kernels at these shapes, how long does startup's retarget block, what frame time does a phone
    hold) are T7e's, and Simon's to answer.
- **Sep 21 — the first phone run crashed, and the tool that finds such things was already here.**
  Simon's phone: "memory access out of bounds" at startup, in a `ship` build that named nothing.
  Simon: always build pages in `release` (asserts kept), never `ship`. The project's
  `smoke-test` (the wasm in Node, GPU and DOM stubbed, 60 frames, imports and leaks audited)
  reproduced it in three seconds with symbols:
  * **Bug 1 - `State` defaults were never applied.** `wgpu_app` makes the state with
    `gpa.create`, which is uninitialised memory; the page's runtime fields had defaults written on
    the struct and were never assigned, so `failed` read as a garbage slice and the panel's first
    `u.text` printed it. Fixed by moving them into one `Progress` struct assigned whole as
    `initState`'s first line - a later field cannot be forgotten.
  * **Bug 2 - the fleet kept a caller's local array.** The page built its list of clips as a local
    array; the fleet kept the slice ("borrowed", its docs said) past `initState`'s return. The same
    lifetime trap as `KitMlp`'s `spec.hidden`, fixed the same way: the fleet copies the list.
  * Then the audit's two leaks: the GPU compute host never released (9 buffers, 30 bind groups, 30
    pipelines), and the meshes and UI host. Smoke now passes in debug AND release; release is
    4.99 MB of wasm, 7.66 MB as one standalone file.
  * **The lesson is mine:** the page went to a device without passing the smoke runner that
    already existed and would have caught both bugs in seconds. Standing rule 10 now requires it.
  * Noted for T7e: 1,267 clock calls a frame from the profiler's zones in the simulation - each a
    crossing into JS, the first suspect if a phone's frame budget is tight.
- **Sep 21 — the first phone run, and the plan re-ordered by what the phone taught.** Simon's phone
  trains: 8 characters, **3 decisions a frame (~3,000 physics steps a second, like this server core)**,
  111k steps in the first minutes, best batch 1.74 s against the servo's ~1.1 s. Simon: find the
  best way to the long-term goal.
  * **The argument:** on a phone, simulated samples are the scarce resource and batched GPU work is
    not, so the best method is the one that learns most per sample using GPU compute - gradients
    through a differentiable model. Checked, not remembered: **DiffMimic** (backflip in 10 minutes
    against DeepMimic's day, ~90% fewer samples; names learned-model error accumulation as the risk
    and anchors rollouts on reference states), **SHAC** (short-horizon gradients plus a critic,
    17x PPO in wall clock), **CrossQ** (update ratio 1 matching ratio-20 methods, ~4x faster; no
    target networks, batch-normalised critic), **SimBa** (normalisation and residual blocks help
    SAC, PPO and TD-MPC2), **RFC** (a root wrench makes hard motions learnable; annealed to zero).
  * **The method, then:** SuperTrack's world model as the differentiable simulator, SHAC's critic
    past an 8-frame window (T6d's drift curve says 8 is what the model is good for), windows
    anchored on recorded states, a CrossQ-style critic, an annealed root assist, normalised
    observations. The GPU environment comes AFTER - it multiplies a good method rather than rescuing
    a wasteful one.
  * **D15, the decision worth its own rung:** a LATENT world model (next features directly, as
    TD-MPC2's is) turns every rollout into a chain of MLPs the kit can already backpropagate - the
    whole SuperTrack loop on the phone's GPU with existing kernels, instead of hand-written adjoints
    of the integration. Decided by the drift curve per line of new code.
  * **T8a, the visible part:** the panel fits portrait (the block glyphs were not in the font - an
    ASCII ramp now), and the page times its own milestones at 2, 3, 4 and 5 s, so every method's
    minutes are recorded where they matter. Smoke-tested in debug and release before shipping.
- **Sep 21 — T8a and T8b, the first of ten turns built ahead of the phone.** Simon cannot test for
  ten turns: go as far as theory allows, verifying only what would otherwise fail silently.
  * **The profiler, frozen in the page:** its zones return before touching the clock when frozen,
    and the page was paying ~1,275 wasm-to-JS clock reads a frame for a profile nobody sees. JS
    calls a frame: 1,590 -> 315.
  * **The servo, measured on the device:** 48 zero-action decisions on the training fleet before
    learning starts, so the panel's comparison is against this phone's servo, not a number from
    here.
  * **Normalised observations**, Welford in f64 (an f32 mean stops moving at millions of samples),
    carried in weights v3 with a flag; mismatched files refused. Round trip tested.
  * **The root assist:** a spring on the root toward the reference, realised as a fraction of the
    root rows of `M a + c` - the wrench that would hold it there. `floatingBaseTorques` could not
    supply it (it treats the root as unactuated and ignores its entries), so it is computed on its
    own, and only when asked for, so zero is the old path to the bit. **The one check that could not
    be skipped was its sign** - a wrench pushing the wrong way would train quietly worse: 25
    episodes ended unassisted, 10 held. My first bar (3x) was too strict for an honest reason:
    episodes also end when the clip does, which a well-held character reaches sooner.
  * Milestones now count only unassisted batches. Next: T8c, the world model in latent form (D15).
- **Sep 21 — turn 2 of ten: the dance, and the bench's metric fixed at the root.** Simon's phone at
  410 batches showed "best 4.31 s, servo 0.24 s, milestones --" - and designing the dance's
  milestones exposed that the get-up's could never be reached. Under reference-state starts an
  episode ends when the clip does, so on a 5-second clip mean episode length averages ~2.5 s for a
  PERFECT policy; the milestones at 3, 4 and 5 s were unreachable, and the 4.31 s best was a batch
  of lucky early starts. The servo's 0.24 s had a second fault: censoring - it averaged only
  episodes that ended inside its short window, dropping every long one.
  * **Mean time to failure replaces both** (exposure over failures; failures = the reference lost;
    the clip ending is survival), windowed over 8 batches, optional where nothing has failed.
    Clip-length independent, so the get-up and the dance share milestones at 2, 5, 10, 20 s. The
    same estimator measures the servo, now over 96 decisions.
  * **The dance** (20 s, what we have), a longer episode cap, and a task tag in weights v4.
  * **Baked clips:** `robot_clip_bake` runs the page's own pipeline offline and verifies what it
    wrote. 3.2 MB and 3.6 MB of capture text became 60 KB and 240 KB; the standalone page went
    from 7.66 to 3.67 MB carrying two motions, and startup does no IK.
  * Both motions smoke-tested in debug and release (the dance by temporarily starting on it).
  **Next: T8c, the latent world model.**
- **Sep 21 — turn 3 of ten: T8c, D15 decided - latent.** Simon's dance run (614 batches, 629k
  steps): PPO loses the dancer every 1.1 s against the servo's 0.9 s, and the phone had dropped to
  one decision a frame (thermal, probably - a long run while charging). Samples got scarcer and PPO
  wastes them: the case for learning through a model, made by the phone. No standalones for a few
  turns; theory-first.
  * **The design that makes T8d cheap:** the latent model takes the action AS ITSELF beside the
    reference's encoded targets - so the policy-to-model path is linear - and lives in normalised
    feature space, where the tracking loss is a plain distance. First layer as three summed
    matmuls: a concat without a concat op.
  * **Built on zimrnum's autodiff** (the cartpole's recipe: graph once, write the batch into
    constants, recompute, backward, AdamSet), trained through 8-step rollouts.
  * **The comparison, same windows, pose drift in the root frame:** latent 15.5 mm at 8 steps and
    30.7 mm at 32; structured 247 mm and 7.93 m. The structured model's pose drift is far worse
    than its world-position drift (61 mm at 8 in T6d): small errors in the predicted root rotation
    swing every body in the root frame. The latent model predicts root-frame features directly and
    never has that lever.
  * The log's "failed command" line with exit 0 is this runner labelling a test step that wrote to
    stderr - checked, not assumed: no error line, zero exit.
  **Next: T8d - the policy through the latent model, with a critic past the window.**
- **Sep 21 — turn 4 of ten: T8d's first half, and its known answer failing honestly.** The policy
  through the latent model, SuperTrack's loop on zimrnum (the cartpole's recipe: the world model's
  tensors as parameters of the policy's graph, shared memory, only the policy's Adam applied).
  * **First run: the real-simulator bar failed** - servo 0.85 s, policy 0.80 s - while the policy's
    loss fell 14% in the model. Rather than loosen the bar, a diagnostic that splits the question:
    the same held windows, no noise, the policy against doing nothing INSIDE the model. Answer: 4%
    better, with 0.21-rad actions, against a model whose own rollout error (0.242) was eight times
    that gain. The policy was optimising inside the model's noise - and the model had been seeded
    with 0.03-rad action noise, so it barely knew what an action does.
  * **One experiment aimed at that diagnosis:** the model trained first (600 steps), seeded with
    0.1-rad noise, exploration sigma 0.3, action price 0.1, the policy's budget unchanged. Model
    0.165; in-model gain 4% -> 11%; actions halved; real simulator 0.89 s vs 0.85.
  * **And then the part that matters most:** that "pass" is not evidence. ~185 failures each, 8
    apart: 0.6 sigma. The first run's "fail" was noise too. A test whose verdict flips on noise is a
    coin toss dressed as a test - so it now asserts the deterministic in-model mechanism and
    REPORTS reality, and the real-simulator margin is the open question for a real budget.
  **Next: the critic past the window (SHAC), then the loop on the kit.**
- **Sep 21 — a turn that died, and a new rule.** The turn writing T8d's critic ran too long and its
  response was cut off mid-generation. Simon: end turns earlier. **New working rule: one small step
  per turn, ~10 tool calls at most, long runs in the background with brief polls, every turn ending
  at a clean checkpoint (compiles, lint-clean, snapshot).** The dead turn left its work in
  `robot_track_st.zig`: SHAC's critic (`Options.critic`, off by default; `trainCritic`; `initWith`,
  so a learner can borrow a world model it does not own - for a frozen-model comparison) and a test
  "past the window". It parses, compiles and lints clean; it has NOT completed a run. **Next turn:
  run that test in the background and read what it says.**
- **Sep 21 — T8d's critic verified: it passed, cached.** The "past the window" test returned "run
  test cached": the identical binary had already passed in the turn that died (a formatting fix did
  not change it). Real pass; its numbers are the ones that turn recorded in the test. Conclusion: no
  critic at CPU budgets; the gain carries past the window without one. Also learned: a background
  job must be fully detached (setsid, all three streams redirected) or the tool waits on its pipe.
- **Sep 21 — T9a step 1: the latent model's two joins on the kit.** `lat_advance` (z + change into the
  next strided block and a contiguous copy) and `lat_take` (the strided gradient back into the
  contiguous one), bitwise equal to plain Zig, nothing written outside their blocks. A first crash was
  the test's, not the kernels': the CPU twin's readback is `element_count` long, zero by default.
- **Sep 21 — T9a step 2: the rollout on the kit, bitwise.** `LatentKit.forward` (three dense layers per
  step over the wide block, joined by `lat_advance`) against `stepWith` - the CPU model's step made
  free-standing so the kit is checked against the code the model trains with, not a copy. Worst
  difference over 8 chained steps at real sizes: 0. Next: the backward pass against zimrnum.
- **Sep 21 — T9a step 3: backpropagation through the rollout, on the kit.** Walking back from the last
  step: the change's gradient IS the next state's (layer 3 reads dZ_{k+1} directly), weight gradients
  accumulated across steps, each state's gradient = its loss term + the residual (`add_block`) + the
  network path out of its strided block (`lat_take`). Against zimrnum's graph, all 23,363 gradients:
  worst 6.7e-6 of 16.6. The mean-vs-sum factor (x8) was checked, not assumed. Next: one Adam step.
- **Sep 21 — T9a step 4, and T9a done: the latent world model trains on the kit.** Adam on identical
  gradients (so the optimiser is tested, not the gradients' rounding, which can flip a first step's
  sign near zero), 3 steps: 1.5e-8. The sum-vs-mean factor is cancelled exactly by scaling epsilon.
  Rollout bitwise, gradients 4e-7 relative, Adam half an ulp. Next: the policy through it, on the kit.
- **Sep 21 — adversarial review of T8-T9a.** The real bug: `LatentKit` never checked its layout against
  the kit's 2^18-float buffers, and the phone configuration needs ~470k - a silent GPU overrun. Now refused
  by name. Also: judging consumed the training RNG; the kit test stopped importing robot_gym (478 -> 56
  tests). Cleared: acting and training goals share a frame. Five open items ranked in the plan.
- **Sep 21 — deep review, robot_track_st.zig: the critic removed.** Rebuilt from the reviewed 1390
  version plus every good change since (noise fix, horizon argument, WalkSetup, main test) and a
  single-learner past-the-window test; the critic, `initWith` and `trainCritic` gone (920 -> 694 lines),
  their lesson kept in the header. Compiles, lint-clean; the two slow tests were still running at the
  turn's end (detached; `/tmp/st_slow.log`). The old version is in `/tmp/robot_track_st.with_critic.zig`
  and in snapshot 1398.
- **Sep 21 — the critic's removal verified; background jobs do not survive a turn.** The detached run
  started last turn was gone with no exit line: the environment stops jobs between turns, setsid or not.
  Re-run inside one turn (one CPU, ~10 min): past the window 0.730 -> 0.557 at 24 steps (-24%, more than
  the -20% at 8); the main test identical to the digit. **Working rule, amended: a long run starts and
  finishes within one turn** (the runner is named `maker`, not `zig`, when counting processes).
- **Sep 21 — the last review turn: residency.** Simon: the goal is single-core wasm + WebGPU with as
  much of sim and training resident on the GPU as possible. Through that lens, T9a's flaw: the host
  stages every window (FK per record, ~250 KB a step). T9b re-planned: a GPU-resident feature ring
  (appended once per step), reference tables uploaded once per clip, a gather kernel that normalises
  (which also unfreezes the normaliser), per-buffer kit sizes; the CPU keeps only sim + acting from a
  mirror (readbacks are a frame late). Code: stale header fixed, test setup deduplicated (-18 lines,
  every number identical).
- **Sep 21 — T9b step 1: the activation buffer grows; a build bug from T9a found.** `acts` = 2^21 floats,
  the rest unchanged; no new buffer, because the kit binds 7 and WebGPU guarantees 8 (past it, writes
  vanish silently). The phone configuration (32 x 256) fits now. Building a page to prove the transpiler
  found that `lat_advance`/`lat_take` were never in build.zig's two per-page kernel lists - every page
  on this kit had been failing to build since T9a step 1. New kernels: build a page, not just tests.
- **Sep 21 — T9b step 2: resident tables and ring.** One upload per simulation step (step-major, lockstep
  asserted), tables once per clip, raw features so the gather can normalise. Bitwise against the CPU's own
  feature code on a real fleet (baked get-up, no retarget). Noted for step 3: same-offset uploads in one
  frame clobber, so window starts need per-step regions.
- **Sep 21 — a tutorial turn.** New 11.12 (credit past the window: why tracking's dense reference lets
  short windows teach long motions, and why a bootstrapped critic is not free), and 12.6-12.8 (what runs
  where on a phone, the latent model on the kit, keeping data resident) with the tutorial's first two
  figures (inline SVG in currentColor, theme-safe). The GPU paragraph left 11.10 for 12.7. Doc chain,
  gate and page build clean.
- **Sep 21 — T9b step 3: the gather, bitwise.** `lat_gather` builds each window on the GPU from the ring,
  tables and normaliser; only two floats per window travel. Bitwise against the CPU's own feature code.
  Two shadowing errors on the way (the kit's module-level `k`; a `rows` meaning two things) - the second a
  real readability hazard, renamed `table_rows`. Page build proves the transpiler; smoke passes.
- **Sep 21 — T9b step 4: resident world-model training, step for step.** 60 steps on shared windows: kit
  and CPU losses within 1.2e-5 at every step, both 0.373 -> 0.248 (ten-step means). The 20-step version
  failed its descent check with both rising identically - understood (transient + batch noise), not
  deleted: the check now averages. The loss value is one mse_value over the contiguous blocks.
- **Sep 21 — review of T9b steps 3-4 (finished after a turn died mid-way).** Two silent hazards closed: the
  ring could miss a step unnoticed (now books + a no-gaps check), and the resident regions could overlap the
  rollout's blocks (now refused). Asserts -> assertf. Comments on every tricky part. D15 and T8d re-run
  after the `trainStep` split: identical to the digit. One slip of my own on the way: an edit script
  guarded an insertion with a condition that skipped it silently - the very failure mode under review.
- **Sep 21 — deep review of T9b 3-4 (a turn lost to length, its work intact).** Ring bookkeeping (no gaps,
  windows inside the ring), an overlap check, assertf with messages, comments on the tricky parts. My own
  edit script skipped an insertion SILENTLY on a missed anchor - caught by the next check. D15 and T8d
  identical after the split. Keep turns short.
- **Sep 21 — T9b 5a done: one row feeds both networks.** `[goal | z | reference | action]`: the world model
  reads its slice bitwise, gradients at lead 0 and 291, and the gather writes goals and the goal block,
  bitwise against the CPU learner. Next: 5b, the policy's forward.
- **Sep 21 — bug hunt over T9b 5-5a.** Arithmetic consistent; the real bug was on an error path no test
  took: `FleetSetup.init` without errdefers leaked on a missing clip. Fixed; its test shown to fail without
  the fix (tests should have teeth). Params alignment already compile-checked.
- **Sep 21 — T9b 5b (deterministic): the policy acts in the kit's rollout.** Actions 4.8e-7, states 5.7e-6
  against the CPU learner's own code over 8 steps. Next: the noise (a counter-based hash, same on CPU).
- **Sep 21 — T9b 5b done: noise from a hash.** Irwin-Hall over a lowbias32 hash: exact on every device,
  one function shared by kernel and CPU. Statistics sound; noisy rollout 7.7e-7 / 3.8e-6. Next: 5c.
- **Sep 21 — T9b 5c: the policy's gradients on the kit.** Through the frozen world model, four sources per
  state, 20,867 gradients to 1.2e-6 relative against zimrnum. `activationGrads` had the world model's
  width baked in - generalised before it could silently cut the policy's tanh' short. Next: 5d, Adam.
- **Sep 21 — SuperTrack conformance review (Simon supplied the paper).** Structure matches the paper;
  deliberate deviations recorded (latent model, sizes). Two real bugs found by reading it: actions scaled
  twice on the SuperTrack path (0.3 x 0.2 - a fifth of the intended authority, which may explain T8d's
  weak real-simulator gain), and a one-frame lag (servo and policy aim at frame i, the paper at i+1).
  Seven more deviations ranked in the plan: kinematic-data normaliser, L1 group-weighted losses, window
  32, gradient clipping, ELU, and minor ones.
- **Sep 21 — bug 1 fixed in code: one action scale, owned by the fleet.** The slow tests did not finish in
  21 minutes (previously ~12 for both) - unexplained yet; next turn runs each alone, timed.
- **Sep 21 — bug 1's verification: a test tuned against the bug.** The slow 21 minutes was an unfiltered
  run (462 tests), not a hang. Past-the-window passes with the true authority; the main T8d test fails -
  its sigma 0.3 had been tuned when the authority was secretly a fifth, so at the true scale it jitters
  joint targets by 0.09 rad a step. Next: sigma 0.1 (default, paper), re-run alone. Also: `pkill -f`
  matched its own command line and killed the tool's shell - kill by process name.
- **Sep 21 — bug 1 closed.** One scale owned by the fleet, the paper's noise (sigma 0.1): world loss 0.181,
  in-model gain -18% (was -11% under the bug), past the window -31%/-20%. Next: bug 2, the frame lag.
- **Sep 21 — bug 2, first half: the servo aims at frame i+1.** Tracking and PPO tests pass; PPO's per-step
  reward rises 0.621 -> 0.632. The SuperTrack side still feeds frame i to its world model - next turn.
- **Sep 21 — bug 2 closed: everything aims at the next frame.** World model reference, policy goal and servo
  agree on frame i+1 (SuperTrack's k_{i+1}). Kit parity holds; real simulator 0.99 s vs servo 0.85 s, the
  best gap yet (~1.4 sigma). Both bugs the paper exposed are fixed. Next: step 5d (Adam on the policy).
- **Sep 21 — T9b 5d: Adam on the policy alone.** 7.5e-9 against zimrnum; the world model untouched
  under bait. A replacement span swallowed `loss()`; restored, and the function list diffed against the
  snapshot (the first diff was hollow - its extraction had died with the shell). Next: 5e, the driver.
- **Sep 21 — review + tutorial.** Bug 2's fix had not reached three places that also define the servo's
  target or the policy's reference: `targetsAt` (structured model data), the MPPI planner, PPO's
  observation. Fixed. Tutorial: the frame convention and one action scale in 11.11; new 12.9 (the
  policy on the kit) with a figure of the shared row.
- **Sep 21 — the structured model got worse after the frame fix.** D15 fine; the planner test fails at its
  world-model stage (192 mm at 8 steps, was 61). Cause unknown - next turn, before 5e. The learner gained
  its optional noise function for 5e's check.
- **Sep 21 — to the bottom of the structured model's "regression": there was none.** Frame i reproduces the
  old run bitwise; my 61 mm baseline came from another configuration. Mismatched targets change nothing
  (190 vs 192 mm), so no inconsistency; the frame fix makes the data ~16% harder for this single-step
  model. Budget 600 -> 900: 133 mm, a third of the baseline. Lesson: compare against the SAME test's own
  recorded output, not a number remembered from a summary.
- **Sep 21 — T9b 5e, first piece: the policy's GPU update matches the CPU learner to 9.7e-8.** Gather,
  acting rollout, backward through the fixed world model, Adam on the policy, same windows and hashed
  noise, 30 updates. The learner's split kept its draw order - slow tests identical to the digit.
- **Sep 21 — slow tests: SuperTrack's 554 s -> 81 s.** Baked walk + small budgets; assertions keep their
  meaning, not their margins. robot_world's edit was lost inside a command that overran - lesson: never
  chain an edit and a long build in one call; the edit's evidence dies with the build.
- **Sep 21 — slow suite 767 s -> 162 s (~4.7x).** robot_world joined robot_track_st: baked walk, half the
  characters, width 64, smaller budgets; magnitude bars relaxed, structural checks kept. Conclusions
  unchanged. Compilation now dominates a run.
- **Sep 21 — T9b 5e, second piece: acting vs recorded rollouts.** With a policy in the kit, the world
  model's update must roll the RECORDED actions; `forward` would have given it the policy's. Split, and
  the step-4 comparison now runs with a policy present so the mistake cannot come back. My own test
  checked the action columns before the gather ran - moved after it.
- **Sep 21 — T9b 5e, third piece: start slots.** `stageStarts` + `gather(slot)`, matching a frame's real
  order (uploads land first, dispatches run in order). Tested with two batches staged before either
  gather. Next: the driver itself - rounds of collecting, world updates and policy updates.
- **Sep 21 — T9b 5e done: the resident loop runs.** `robot_track_resident`: CPU simulates and acts from a
  mirror, GPU trains both networks on windows it gathers itself, a slot per update. 12 rounds end to end;
  world loss falls; mirror follows. Next: T9b (6) acting from the mirror on the page, and (7) the page
  itself - PPO and the resident learner side by side.
- **Sep 21 — adversarial review of the driver: the mirror could act on uninitialised memory.** The readback
  window is zero until the caller widens it, so `init`'s refresh did nothing and the first round acted on
  whatever alloc left. Zeroed mirror, `init` widens the window, errdefers throughout; full-batch staging.
  Comments made fuller where the layout is implicit (the packed mirror, the seeding, the policy's turn),
  and the tutorial gained 12.10 on the loop.
- **Sep 21 — Simon's idea: filter the action (D17).** DReCon's `y = 0.2 a + 0.8 y_prev`, already in our PPO
  path, missing from SuperTrack's. Plausible: smoother control is easier for the world model, and filtered
  noise explores better than white noise at 60 Hz. Requires the world model to see the APPLIED action, and
  a second carried state in the rollout. Planned as an A/B at one budget.
- **Sep 21 — T9b (6) done: the mirror acts as the GPU's policy would, to 7.2e-9.** Same rows, noise off,
  inputs read from the buffer the GPU used. Next: (7) the page - PPO and the resident learner side by
  side, timed to their milestones.
- **Sep 21 — T9b (7) started.** Page kernels already cover the resident learner; `measureNormalizer` made
  standalone and public so a page can get the statistics without a CPU world model. Kit comparisons
  unchanged (1.2e-5, 9.7e-8). Next: the page's learner switch.
- **Sep 21 — Simon: no side-by-side on the page.** The resident learner alone, plus a train-only mode (no
  render, no UI) and a 20 fps UI when shown. Loop by TIME BUDGET, not a fixed count, so one code path
  fits phone and desktop; watch for callback throttling and thermal throttling (show training seconds
  against wall-clock).
- **Sep 21 — the driver counts exposure and failures**, the PPO bench's metric, so milestone times compare
  across pages. Page scaffolding read; `examples/track_train` next.
- **Sep 21 — review for native GPU and a GPU simulator.** The device seam is already one file; the CPU
  twins are what make a backend swap safe. Done today: the ring's record and table layouts named once in
  the kernel module, so the future kernel that WRITES records has one master. Planned: split the kit
  file, readback by range instead of one global count, and name the ring's bookkeeping contract.
- **Sep 21 — the page is blocked on module structure, not on page code.** The learner's files import the
  kernel module by path for their tests; a page imports it by name. Facade export → 'file exists in two
  modules'. Reverted, pages build. Next: how a page gets `zn_mlp`, and give zimr the same named import.
- **Sep 21 — module structure settled the house way.** Kernel modules are per page, so zimr can never hold
  that file; tests needing a concrete one live in `<name>_tests.zig`. Driver's tests split out and
  passing. Kit's tests next, then the facade and the page.
- **Sep 21 — blocker cleared.** Kit's tests split out too; facade exports the learner; a page builds. The
  kit file is now 1,001 lines of implementation - the review's file split, arrived at from the other
  direction. Every number unchanged.
- **Sep 21 — the SuperTrack page builds.** `examples/track_train`, train-only toggle, budget-adaptive
  slice. Lesson: copy the working page's forms rather than guess them - interface, colours, kernel
  table, robot drawing were all wrong first time. Next: smoke test.
- **Sep 21 — first phone run of the resident learner: 30x real time, and worse than the servo.** 1.20 s vs
  2.22 s, but the policy's number carries exploration noise the servo's did not - my measurement fault.
  The rest is the world model being exploitable. One round already fills a frame, and it is the CPU sim.
  Next: viewer mode, the judged number, the leak, then world-model quality.
- **Sep 21 — viewer mode, the judged number, and a real leak.** Watching runs at the wall clock, noise off,
  longer leash. Two mean-times now, never one. The leak was `measureNormalizer`'s working sums, unfreed
  since it was written - hidden by the arena the world model gave it.
- **Sep 21 — the get-up reference stands on 36-degree soles.** Simon spotted it in the viewer; measured in
  `robot_dance`. Clearance is fine, the ANGLE is not. Two measurement traps: the toe is a separate body,
  and a body axis is not the sole. Next: the same angle on the capture, to place the blame.
- **Sep 21 — the foot had no depth (Simon).** Sole was 2.7 cm under the ankle; a human ankle rides 7-8 cm.
  Retargeting matches ankle position, so the foot hovered. Sole lowered to -.075, heel geom added, clips
  re-baked: feet now the deepest part on 235/300 frames (was 197). Tilt unchanged at 35.7 deg - that part
  is the retarget's rest-pose alignment, not geometry. Next: measure both rest poses' ankle-to-toe.
- **Sep 21 — SuperTrack ON HOLD; new Phase R: a robot that IS Geno.** Two findings decided it. Our LAFAN
  captures are already Geno's skeleton (35 of 35 joints, four trivial offset differences), so IK
  retargeting solves a problem we do not have. And the foot's tilt is ANATOMY: Geno's ankle-to-toe
  descends 22 deg in both rest poses, which our horizontal-footed robot fights instead of embodying.
  Ten experiments written, R1-R10, ending at the servo's own number on the new robot.
- **Sep 21 — Phase R started: R1 done.** `robot_geno.zig` reads Geno's bind and stance into bones and
  world places, shader-free, own FK. Hips 0.855, thigh 0.382, shin 0.399, ankle 0.083 up, sole descends
  23.3/21.9 deg; bind and stance identical to 0.0000 m. Next: R2/R3 - declare the rest pose and derive
  the sole plane.
- **Sep 21 — R4's method settled: shape by region.** Principal-axis capsules for round parts, boxes for
  torso/shoulders/hands/feet: 98.6% of vertices within 1 cm at 108 L (bone-axis capsules: 254 L). Mass
  will come from the mesh's own volume, not the geoms'. Next: geoms in the captures' bind frames, and a
  viewer of get-up and dance for Simon.
- **Sep 21 — `geno_fit`: the fitted shapes on the get-up and the dance, for Simon to judge.** Shapes stored
  in world bind coordinates and attached through the page's own kinematics, so they cannot sit in a
  different frame from the one that moves them. Feet boxes floor-aligned.
- **Sep 21 — pills everywhere but the feet, symmetric by construction (Simon).** Pairs fitted once on
  both sides' vertices mirrored together; centre bones on their vertices plus their mirror. Torso pills
  run across. 98.0% of vertices within 1 cm; the torso's 90.5-94.5% is the one-pill ceiling.
- **Sep 21 — shapes out of the ground.** The capture sinks Geno's own mesh up to 12.7 cm (head, lying):
  the reference needs a per-frame lift - now an envelope-then-smooth in the viewer. And the shapes bulged
  out of the mesh; each is now fixed by the least-volume change that keeps it inside on every frame
  (thighs keep their girth by retracting the knee end). Next: the skinned mesh in the viewer.
- **Sep 23 — connected, athletic, and the mesh.** Neighbouring shapes must overlap >= 1.5 cm (elbow 2.5 cm);
  torso pills from the body's cross-sections, then belly in / chest out with the back held; Geno's skinned
  mesh in the viewer, see-through over the shapes.
- **Sep 23 — no shoulders, slimmer neck, shapes chosen together.** Clavicle pills removed; neck = 0.75 x its
  column's median radius. Found the forearm silently left poking through (parent-first search starved it);
  now every connected chain is chosen jointly by dynamic programming, and fallbacks warn.
- **Sep 23 — the plan, v2.** v1 (1,619 lines) archived verbatim as `archive/rl_track_plan_v1.md`; v2 (~275
  lines) keeps only what is left - phases R, S, C, H, Q, M, each rung with its known answer - plus an index
  of the modern tricks (in / next / todo), the open decisions (new: D18 Geno's joints, D19 self-contact on
  the GPU, D20 f16) and the ranked risks. It is the current plan in `claude.md`; ragdoll_compare is paused.
- **Sep 23 — R2 and R3 done.** Rest pose = bind, with the convention proved (bind from identity joints
  exactly; the stance from its copied joints to 3.8e-7 m). The sole from Geno's mesh: -4.5 mm, ankle 8.8 cm
  above, heel and toes touching; mesh and skeleton share a frame to 3e-7 m. A correction caught by the new
  test: my scratch said the file's zero lay flat, because Geno's files carry POSITION channels on every
  joint and zeroing all channels collapsed the skeleton; the true zero-rotation pose has the arms straight
  up and the feet level.
- **Sep 23 — R5: Geno weighs 60 kg.** The volume sampler is exact on an analytic box; Geno's skin is closed
  (0 odd columns of 1,845): 60.0 L at 1.707 m. Six of eight segments within 20% of de Leva or Dempster;
  the upper arm (+31%) and foot (+37%) are not - the skin weights cut at the shoulder cap and the ankle
  flesh where the tables cut at joint centres. Pinned in the test; D21 / R5b decides the convention.
- **Sep 23 — R5b: it is Geno's build, not the cut.** Masses now cut at the joints the tables' way (square to
  the proximal segment, level at the trunk); a mitre was tried first and measured worse. Every partition
  leaves the upper arm and foot 29-46% above the tables at the same weights (2.2 kg, 1.2 kg), so Geno's
  arms and feet are genuinely heavy. D21 taken. Next: R6, joint ranges from the capture library.
- **Sep 23 — R6: joint ranges from four clips.** Knees 142 deg, elbows 120 / 107 (anatomy holds). Elbow and
  right-knee twists say hinges would lose captured motion (D18 leans to balls); the hips' ~100 deg twist is
  Codman's paradox, so limits use the total angle; tails pass p99.5 by 2-10 deg (a 24 deg toe spike), so
  limits will be max + margin after glitches are removed. Next: R6b, the model assembled.
- **Sep 23 — R6b, first slice: Geno as MJCF.** `writeModel`: 23 bodies in their bone frames, only the root
  turned z-up, ball joints limited at max + 5 deg, R5b's masses. Through the engine's import and FK: every
  body within 2 um of bind, 60.04 kg in. Next: the shapes, the floor, the standing guard.
- **Sep 23 — plan: S0b and D22 (Simon's idea).** Keep ball joints in the body, but let the policy correct only
  the axes that matter: chosen by a PCA of each joint's motion plus a correction-sensitivity study, judged
  by minutes to bar against S0's full 66-action space.
- **Sep 23 — R6b: shapes and floor in the model.** The shape table moved to `src/` (one table: model and page
  read it). Shapes carried into body frames, massless; the pelvis is a sphere (a zero-length capsule crashed
  the reader's `fromto`). All 21 shapes within 2.1 um of the fit. Next: the standing guard.
- **Sep 23 — R6b done: the standing guard passes.** Geno's model in a floor world through the bridge: no
  actions, 30 frames, contacts, hips 0.86 -> 0.69 m as the ragdoll crumples, every body above the floor.
  Next: R7, retargeting becomes a copy (and what folding Neck1 costs).
- **Sep 23 — R7, half: the copy turns every body exactly.** `Copier` (w last, root absolute - read off the
  engine's rest) copies all 1,080 get-up frames; every body's turn matches to 7.4e-5 deg. Open: positions
  2 mm (capture offsets?), the head 12.9 mm (fold Neck1 no more: D18), a sole-tilt probe that reads 90 deg.
- **Sep 23 — every bone kept; a blocker found.** Simon: keep the bones, drop only big shapes; the copy must stay
  exact. Neck1 is a body again (head copies to 0.0000 m). But designed overlaps across shapeless bodies
  collide (only adjacent bodies are spared): with room for every contact the guard launches the robot to
  2.7 m - the old pass hid behind a 32-contact cap. Next: R6c, MJCF contact exclusions in reader, model, bridge.
- **Sep 23 — R6c: contact exclusions, the blocker cleared.** MJCF `<contact><exclude>` now read, carried in the
  model and honoured by the bridge; Geno's model excludes its three neighbour pairs across shapeless bodies.
  The standing guard passes with room for every contact. Next: R7's open findings (2 mm, the tilt probe).
- **Sep 23 — review, cleanup, and the path made clear.** Code: the guard's spent blocker flag removed (its
  assertions stand plainly), stale comments refreshed, the model test named for what it covers. Plan: Phase R
  rewritten - done rungs compressed to what each settled; next rungs as procedures with closing answers, adding
  R8a (the training task moves onto Geno: model fixture, clips by copy, servo on balls, layouts from the model,
  the fleet's own guard). Tutorial: new §5.6 (a robot built from the character), Geno in §5.1, §6 opens with
  when retargeting is a copy; doc-sync 0 drifted.
- **Sep 23 — R7 done: the copy is exact.** The 2 mm was the captures' own stretch (thighs and upper arms change
  length by up to 3.2 mm over time - no rigid robot can copy that). Against rigid bones, all four clips copy to
  3.2 um and 7.7e-5 deg; the walk's standing soles tilt 2.1 deg. Next: R8a, training moves onto Geno.
- **Sep 23 — R8a parts 1-2: Geno's model and clips, in the task's formats.** `geno.xml` is a fixture held
  byte-equal to `writeModel` (rewritten, and failing once, when the model changes). `copyClip` turns a capture
  into the task's `dance.Clip` (99 numbers a frame; residual = the capture's stretch, 3.2 mm worst). Next:
  part 3, the servo on Geno's 23 ball joints.
- **Sep 23 — R8a part 3 begun: the task's servo on Geno.** `pdTorques` is generic (acceleration springs through
  inverse dynamics - no gain table). On Geno from its fixture, gravity off: error 2.02 -> 0.67 rad in 0.5 s, not
  the 1 % asked. First suspect: the model's floor plane pinning the bind soles (4.5 mm in). Diagnostics queued.
- **Sep 23 — R8a part 3 done; an engine bug found.** The servo stalled 0.67 rad short on Geno; diagnosed in order
  (not the floor, not the clamp): the engine applied ball ranges as a scalar limit on the quaternion's first number.
  Fixed at assignment (balls unlimited until cone limits, E1). The servo now closes 2.02 rad to 0.00000 in 0.5 s.
  The old robot's ball joints were mis-limited too. Next: the standalone page `geno_track` for Simon's phone.
- **Sep 23 — the page: `geno_track`.** Geno as a physical robot on a floor, pulled through a copied walk or
  get-up by the task's servo alone, the reference as a ghost, falls timed. Built first time in release; smoke
  PASS. Sent to Simon's phone.
- **Sep 23 — headless: the servo on a floor is unstable on Geno.** `ServoRun` (the page's loop, reusable) held the
  walk's first frame: the robot launched 21.9 m in 2 s. Walk MTTF 0.54 s, get-up 0.83 s - meaningless until stable.
  Servo alone and ragdoll alone are both fine; together at 60 Hz they are not. Next (S1): flex2's armature/damping/
  timestep, armature on Geno's joints, sub-stepping, the per-frame lift - one at a time, judged by the held stand.
- **Sep 23 — S1: armature and damping end the launch; the stand still falls.** Geno's balls now carry the old
  robot's armature .01 / damping .2: held stand 21.9 m -> 1.0 m, get-up MTTF 1.84 s. But even bind falls (0.70 m in
  2 s). Suspect: floating-base inverse dynamics ignores contacts, so a standing robot gets no weight compensation.
  Next: `robot_dance.contactConsistentTorques` on the held stand.
- **Sep 23 — S1 (e): contact-consistent torques help the stand only partly.** Same spring, torques that know the
  floor: bind stand 0.70 -> 0.51 m (still falls), get-up MTTF 1.84 -> 1.03 s. Not the cause. Next: find which joint
  gives way first in the held stand; then sub-stepping, the lift, cone limits.
- **Sep 23 — S1 (f): the body was colliding with itself.** Instrumented, the held stand showed the spine blown on
  frame 0: torso pills overlap the pill two joints away, and those pairs collided. Now every pair overlapping at rest
  is excluded (18). The stand no longer explodes - it topples slowly through the legs; get-up MTTF 2.61 s, walk 0.93 s.
- **Sep 23 — tuned for the get-up; the page rebuilt.** Sweep: the servo's acceleration cap is the lever (400 -> 3000:
  get-up MTTF 2.61 -> 3.02 s); armature, damping and frequency don't beat it. `servo_gains` carries it; `geno_track`
  rebuilt with it and with the 18 at-rest exclusions - smoke PASS, to Simon's phone.
- **Sep 23 — the page gets a no-reset toggle, stiffness sliders and step timing.** Headless: the servo is stable to
  120 Hz on a 60 Hz step; 20 Hz still keeps the get-up longest (3.02 s vs 2.5-2.6 s) - stiffer follows the impossible.
- **Sep 23 — the dance is now dance1, its first 30 s.** Simon's clip, trimmed to 1,800 frames (Geno's full 75-joint
  skeleton), replaces dance2 in Geno's tracking set. Ranges re-measured (knees 148.6 deg), the fixture regenerated,
  the copy exact on all four clips. The old robot's baked clips are untouched.
- **Sep 23 — the stand, again: balanced pose, yielding joints.** With the tuned servo the held stand still tips
  (1.21 m in 2 s). The bind pose is statically balanced (centre of mass 11.4 cm from the heels, 12.1 from the toes),
  so the servo is not holding it rigid. Next: servo torque vs static need at t = 0, joint by joint.
- **Sep 23 — the page holds the T-pose, with a knee bend.** Simon's request: hold Geno's T-pose under a checkbox,
  with a live, balanced knee bend (hips and ankles take half each the other way). Smoke PASS; to his phone.
- **Sep 23 — friction, clean restarts, and SuperTrack's first contact with Geno.** Floor friction 2.0 (feet skated
  28 cm in a 2 s stand at 0.5); a live slider. Restarts now forget warm starts and cached contacts - 0 of 99 numbers
  differ across a restart, no rebuild. The fleet takes a floor friction; the CPU SuperTrack learner runs on Geno
  unchanged: holding the T-pose, seed 1 gives 2.67 s against the servo's 1.29 - seed 2, 0.43 s (world model
  diverging). Unstable; S2's recipe next, over several seeds.
- **Sep 23 — S2: a stable world model, a policy that does nothing.** A wider normaliser, a gentler world model and
  more updates stop the divergence (world loss 0.12-0.21 against 5.7-21) - but three stable recipes, windows of 8 and
  32, all tie the servo exactly (1.29 s). Suspect: the model is blind to actions (prefill exploration ~0.09 rad).
  Next: measure the model's predicted response to an action against the simulator's.
- **Sep 23 — S2a: the ties were integers; the real gap is exploitation.** `judge`'s 300-step window moves in whole
  falls (31 = 1.29 s). Over 20 s: servo 1.19 s, policy 1.12 s - slightly worse - while in the model the policy cuts
  the loss 20%. A stable world model, wrong about actions; the policy exploits it. Next: the model's action response
  against the simulator's, then an ensemble with a disagreement penalty (S5).
- **Sep 23 — plan: S2b (Simon's idea), model-free experience beside the model.** A SAC-family actor (CrossQ first,
  DroQ if unstable) on part of the fleet feeds the shared ring: no model to exploit, and the action-rich data the
  world model lacks. Judged by the model's action response and by real MTTF over seeds at equal CPU.
- **Sep 23 — the model-free baseline on Geno: PPO.** DReCon's policy subset was the old robot's names; now
  `subsetFor(watched, actuated)` with Geno's own lists (30 of 69 action dims). PPO, 100 s on one core: 64.0 frames an
  episode against the servo's 62.8 - nothing yet. Next: CrossQ, and longer budgets.
- **Sep 23 — SAC on Geno: update-bound on the CPU.** In DReCon's layer on the held T-pose, 110 s bought 12,784
  transitions (~70 ms an update) and 61.5 frames against the servo's 60.9. At two CPU minutes: SuperTrack flat, PPO
  +2%, SAC +1%. The critic family belongs on the GPU (`GpuSacOn` exists) - next, then CrossQ, then the mix.
- **Sep 23 — plan: S2c, a balance MPC as teacher (Simon's idea).** Whole-body iLQR through Geno's contacts is a
  research project; the pendulum planner (`solveBalance`) + ankle and hip strategies on the servo is the first
  MPC. If it holds the T-pose (>= 10 s), its trajectories train the world model and seed the policies.
- **Sep 23 — S2c first attempt: a capture-point ankle reflex, +11%.** 0.92 s -> 1.02 s as the gain rises: right sign,
  small effect - the T-pose buckles at knees and hips rather than tipping. Blocker for S2c: (h), the servo's torques
  against the pose's static need on the floor; hypothesis: floating-base torques never compensate the weight.
- **Sep 23 — stronger ankles, by armature: not the ankles.** Armature scales the servo's ankle torque exactly (ceiling
  58 -> 24,028 N m) but the T-pose holds 0.92 -> 1.15 s at best; the ankles already had ~2x a stance's need. Next: armature
  on the whole leg chain (knees and hips are light in flight, heavy standing), and (h).
- **Sep 23 — THE T-POSE HOLDS.** Armature 2 on every joint (in this servo a joint's strength is its free-flight
  inertia) + the capture-point ankle reflex at gain 2-4: the full 10 s (9.98 s), where the servo alone falls at 0.9 s.
  Legs+spine alone reached 7.7 s; gains of 8+ oscillate into a fall. Next: its cost on the get-up and walk, then
  armature as a model parameter, the reflex on the page, and its trajectories for the learners.
- **Sep 23 — SuperTrack on the dance's first 5 s.** Armature 2 costs the dance nothing (servo 1.26 s vs 1.24). The
  world model fits (loss 0.015) and says the policy helps (-19% tracking loss) - in reality the servo never failed in
  20 s x 8 envs and the policy failed 10 times. Exploitation again; next a tracking-quality judge, then S5's ensemble.
- **Sep 23 — a tracking-quality judge.** Falls plus DReCon's mean reward in the real simulator. On the dance's first
  5 s: servo 0 falls / 0.950, the SuperTrack policy 10 falls / 0.844 - worse, while the model says 19% better. Next: S5.
- **Sep 23 — plan reordered: data first (Simon).** Teachers that cannot exploit (reflex, sampling MPC over the true
  simulator), model-free learners on the GPU (CrossQ / DroQ, PPO baseline), the world model judged on pooled data
  before any policy trusts it, then SuperTrack distilled and fine-tuned. Ensembles only if exploitation survives.
- **Sep 23 — D1 foundation: save and restore.** Two rollouts from one restored moment are bit-identical (99/99); a
  restored rollout drifts 8.15 mm from the unbroken run in 20 steps (forgotten warm starts). Next: the sampling planner.
- **Sep 23 — the holding T-pose on the phone.** `geno_track`: armature 2 on every joint, the capture-point reflex
  slider (default 3), clean restarts. The reflex is `geno.Reflex`, shared by the page and `ServoRun` (still 9.98 s).
- **Sep 23 — restarts rest on the floor.** The walk's copied first frame had its feet 16.8 mm in the floor (a 0.21 m/s
  jump); `restOnFloor` lifts to 1 mm clear: no jump. Spin 1.09 -> 0.90 rad/s remains: next, start velocities from the
  clip, and the same in the training fleet's resets.
- **Sep 23 — the easy start, measured: the servo must agree.** Reference velocities + 3 held frames raised the root's
  spin against the reference to 2.07 rad/s (0.94 from rest): the servo damps toward zero velocity and brakes the limbs.
  Held off until the servo damps toward the reference's velocity (feedforward); then the per-frame lift for the clip.
- **Sep 23 — the launch verified: velocities exact, then erased.** Integrated one frame, the reset's velocities land every
  body within 0.0005 mm of the next dance frame. One real step misses by up to 25 mm - as if launched still: the servo's
  damping toward zero (~251/s) keeps ~1.5% of a launch velocity. Next: velocity feedforward, judged by this test.
- **Sep 23 — review.** Code: the 3-frame hold removed (Simon dropped it), three superseded S2c sweeps folded into one
  guarded test (the T-pose must hold > 9.5 s at gain 3); all 488 robot_geno tests pass. Plan: Phase S rewritten from a
  225-line log to its state and ordered next steps (the log archived). Tutorial: 8.7-8.9 (standing, the reflex, starts).
- **Sep 24 — velocity feedforward, measured.** Built as an option (`pdTorquesToward`, end velocity g-1 -> g). One step
  from an exact launch: 14.3 -> 4.8 mm at the fastest frame; without contacts, gravity's g dt^2 = 2.72 mm is all that is
  left. Survival over the whole dance unchanged (1.74 vs 1.73 s): the limit is balance. With clean starts and standing
  armature the servo alone now keeps up with the dance's first 5 s from every start. Contacts throw limbs at some
  frames (up to 20 mm a step) - self-collision pairs next.
- **Sep 24 — one reset everywhere; the dance's self-overlaps.** The copied dance sinks into the floor on 1,798 of 1,800
  frames (up to 48 mm): clips are lifted per frame, the fleet rests resets on the floor (an option), and tests, page and
  training share `resetToFrame` (backward difference, exact to 0.0005 mm). The dance's poses put limbs inside each other
  (up to 62 mm, hands); excluding those pairs leaves servo survival unchanged - a decision for Simon.
- **Sep 24 — self-collision off (Simon), in the model.** `self_collision = false`: every pair of Geno's 21 shape-carrying
  bodies excluded (210), so tests, page and fleets all follow. The dance's worst one-step throw: 29.4 -> 3.6 mm. Back on
  once training works.
- **Sep 24 — D1: predictive sampling over the true simulator WORKS.** Knots of offsets on DReCon's joints, 16 samples x
  15 steps, sigma 0.3: from four hard starts every run reaches the 5 s cap (servo alone 0.92 s); the whole dance from frame
  0 in one run: 17.05 s (servo 6.65 s). No model, nothing to exploit - the teacher D3 and D4 need.
- **Sep 24 — D1's cost: shape first.** Scored in world positions the whole-dance run ended lost (heading 31 deg, shape
  547 mm off); scored by shape in the root's frame + 0.3 x the root's miss it ends at 15 s with heading 4 deg and shape
  148 mm off. Kept: a teacher must be faithful. Sweeps from here on: >= 3 seeds a setting.
- **Sep 24 — the teacher's reach: 0.6 rad.** Unlimited, the planner's offsets random-walk past 3 rad. Limited per freedom:
  unlimited 4.74 s, 0.6 rad 4.45 s, 0.3 rad 2.46 s (servo 0.92) from four hard starts - Geno's policies need action_scale
  ~0.6. Planner recording code (choose/act/actionOf/record, test "D3 data") found in the tree unaccounted for;
  reviewed and verified (1.2e-7), adopted pending Simon's word on its origin.
- **Sep 24 — D3's yardstick built; expert data alone does not teach actions.** Action response vs the true simulator:
  model on servo + noise - cosine 0.43; model on the teacher's recordings - cosine 0.20, though it predicts states
  better. The teacher's action is a function of its state, so the model need not learn the action's effect. Next: the
  planner's rejected candidates as data - diverse, state-independent actions where balance is decided.
- **Sep 24 — D3 checkpoints: budget AND data.** Action-response cosine at 400/800/1,600 steps - servo noise 0.34/0.43/0.54
  (but worse and worse on the teacher's states), teacher 0.06/0.20/0.31, teacher's candidates 0.19/0.31/0.44 (best states).
  Nothing plateaus: the GPU must train these. Next: candidates with state-independent jitter (DART-style).
- **Sep 24 — D3's data recipe: the teacher's jittered candidates.** DART-style jitter on recorded candidate steps: action
  response as good as pure servo noise at every checkpoint (cosine 0.52 vs 0.51 at 1,600 steps) AND the best prediction
  of the teacher's states (0.311 vs 0.377). Scale is the GPU's. Next: D4, cloning the teacher.
- **Sep 25 — `geno_train`: SuperTrack on Geno on the GPU.** The GPU training page on Geno (standing armature, floor rests,
  action scale 0.6, the dance 5-15 s baked). Smoke PASS; for Simon's 3-minute phone test - throughput and policy vs servo.
- **Sep 25 — the style gate moved (Simon).** Builds are no longer gated by lint/fmt and nothing rewrites files mid-iteration.
  `*-standalone`, `dist`, `check` and ship mode require a clean `lint-check` (non-mutating); `zig build fix` is the only
  rewriting step. Verified: a misformatted file passes a smoke build, fails a standalone build, `fix` repairs it.
- **Sep 25 — the exploding policy, measured and smoothed.** On the page's setup the SuperTrack policy's actions jump 0.111 a
  frame (size 0.159) and it falls more than the servo. CAPS temporal smoothness, two-sided, on the CPU learner and the GPU
  kit (gradients match autodiff to 1.4e-6): jumps -> 0.025, falls 140 -> 118. geno_train: 4 characters, w_smooth 1.
- **Sep 25 — the phone crash: not a leak, an unbounded GPU queue.** Live CPU bytes flat and GPU handles identical from 60 to
  300 frames (new: `-Dsmoke-frames`, a live-bytes line). The page scaled rounds by CPU frame time, up to 64 a frame, while
  the phone's GPU fell behind. Now at most 8 rounds unconfirmed (`readGeneration`), in geno_train and track_train. Also
  found: after 300 frames deinit frees no GPU resource - to fix.
- **Sep 25 — the phone's third report: a death spiral, and NaN never checked.** Updates froze at 174: a policy failing
  within a window's length leaves no window. Grace period at reset; non-finite states end episodes; the mirror refuses
  non-finite weights and non-finite actions become zero - both counted on the panel. Smoothness kernel branch-free.
- **Sep 25 — training runs on the phone.** Updates now match rounds; exploring 0.91 s (was 0.08). The huge 'bad weights'
  number was an uninitialised counter (fixed). 'Frames waiting' is the backpressure working - now shown as a recent share.
  Throughput lead: ~320 compute passes a round, one per dispatch - one pass with dynamic uniform offsets would fix it.
- **Sep 25 — lint rule `whole-init-first` (Simon's idea).** After `x = ...create(T)`, and in `init*(self: *T)`, the first write
  through the pointer must be `x.* = .{...}` (defaults applied, every field named). 17 sites flagged, 107 already complied.
  16 converted; 2 were false positives - `initTimer` (a clock RESET: now `time.* = .{ .base = ..., .target = target }`,
  naming what survives) and `TreeNode.init` (links an initialised component: original kept, one reasoned lint:off).
  The first attempt's turn died running the FULL suite - its targeted runs had all passed; timer tests 11/11 filtered.
- **Sep 25 — the GPU confidence test.** geno_track trains XOR on the GPU beside the servo and the drawing (on by default,
  up to 512 dispatches a frame, backpressure, fresh weights every 2,000 steps). If it survives the phone, the fault is
  the learner's load (readbacks, uploads, passes); if not, the infrastructure's. A pre-existing long-run teardown leak
  found on the way (texture/sampler/view + 6 buffers per lifecycle after 300 frames).
- **Sep 25 — the GPU infrastructure is sound; XOR's NaN is the algorithm's.** Minutes of XOR beside physics and drawing on
  the phone, no crash. Its NaN reproduces on the kernels' CPU twin: rate 0.5 diverges on 3 of 8 seeds in 30 steps; 0.2
  never does - the page now uses it. Next rung: PPO on the GPU with Geno (a geno_ppo page from getup_train).
- **Sep 25 — forefoot toes; geno_ppo.** Toe boxes rebuilt in the foot's frame by the fitter (5 x 3.5 x 7.2 cm, sole flush):
  armature-only standing 1.2 -> 1.55 s. XOR out of geno_track. geno_ppo = getup_train on Geno, PPO on the GPU by default,
  one learn per batch. PPO's action scale now explicit (0.2 rad a unit; ~7 deg exploration, ~1.4 deg filtered).
- **Sep 25 — the smoke harness made honest for long runs.** Its clobber scan now knows a submission consumes the writes
  before it (PPO's minibatches were a false alarm), and its leak checks skip - saying so - once the 500k-entry call log is
  capped: the 'long-run teardown leaks' were the cap. geno_ppo: clean at 800 and 300 frames. The phone crash is not
  anything zimr can count; next: CPU-host learning, and 2 characters, as switches.
- **Sep 25 — D4: the teacher cloned, and distribution shift.** Cloning (same parameters and Adam as SuperTrack) fits the
  planner's actions (loss 0.50 -> 0.03) but in reality loses to the servo (reward 0.647 vs 0.781, 103 vs 98 falls): right on
  the teacher's states, lost on its own. Next: DAgger - the planner labels the states the student reaches.
- **Sep 25 — DAgger does not rescue the clone; the labels are noise.** Three rounds: no better than cloning (124-126 falls
  vs the servo's 98) and the student's jitter doubles as labels grow. Predictive sampling's argmax is a good trajectory
  but a noisy decision. Next: MPPI's cost-weighted average as plan and label.
- **Sep 25 — MPPI: the best controller, a worse teacher.** Sharp MPPI (temperature 0.03) holds the hard starts 4.88 s
  (predictive sampling 4.67). Cloned, it teaches worse (160 falls vs 118) and DAgger degrades further - the teacher's
  action depends on its plan memory and 15 frames of lookahead the student cannot see. Next: cold-start labels; more lookahead.
- **Sep 25 — DReCon's filter, and the best teacher.** Simon (Clavet - DReCon's author of the 0.2 action smoothing) asks
  for it everywhere. The planner acts through it; with its raw search pushed twice as hard, sharp MPPI + filter 0.2
  holds the hard starts 5.01 s - the best controller measured. The student will be DReCon's policy (it observes the
  last action - the filter's state), cloned from this teacher, then fine-tuned by PPO.
- **Sep 25 — the teacher on DReCon's clock, and what its actions ask of a student.** Decimation 2: 3.48 s (5.01 deciding
  every step). Its raw offsets average 0.34 rad (applied 0.24); 56% pass 0.2 rad - a DReCon student at 0.2 rad a unit
  can express only 43.5% of them. The student's scale is Simon's call.
- **Sep 25 — the student's reach, and D5.** Capping the teacher at 0.6 rad collapses it (1.34-1.46 s vs 3.48): through a 0.2
  filter a strong correction needs a large raw command - the student gets scale 1.2 (actions in [-1, 1]). D5 designed: one
  DReCon policy, three gradients (the planner's imitation, SuperTrack's world-model gradient, PPO) weighted by measurements;
  the switch to the world model driven by its validated error on the policy's own fresh rollouts.
- **Sep 25 — D5 made precise; steps 1-2.** The plan's D5 now states definitions, losses, measured weights (w_BC from the
  student-teacher reward gap; w_WM from the world model's held-out error against a trivial predictor, gated on action
  response) and a known answer per step. geno_ppo acts at 1.2 rad a unit, log sigma -1.2. The teacher's labels replayed
  through DReCon's controller rebuild its targets to 2.4e-7 - its semantics ARE DReCon's.
- **Sep 25 — D5's recorder.** The teacher's decisions stored as DReCon observations (exactly PPO's) and labels; each
  observation's last-action slot equals DReCon's controller's held action to 8e-9. The clone will be PPO's own update with
  a behaviour-cloning gradient on the mean - one network, nothing copied.
- **Sep 25 — the clone on the kit.** `GpuPpoOn.cloneMinibatch`: PPO's own policy chain (now shared, extracted verbatim)
  with `mse_bwd` for the PPO head and Adam over the policy's layers only - no new kernel. Matches zimrnum's graph to 3.3e-7
  over 10 steps; log-std and value bit for bit untouched; GPU PPO's cartpole still learns.
- **Sep 25 — D5 step 3: the clone fits, and falls.** 810 teacher decisions cloned into PPO's own network (error 0.0038
  per element); judged: servo 96 failures / MTTF 100 / reward 0.784, clone 184 / 52 / 0.373. `evaluate` now counts failures
  (it left them zero). Next: does the teacher's replay transfer to the fleet's physics; the observation's lookahead; DAgger.
- **Sep 25 — the demonstrations transfer.** The teacher's labels replayed open-loop in the trainer's fleet from its exact
  state track its own run to 89 nm after a step and under 0.6 um for 45 steps: the same physics. (A first 10 mm 'mismatch'
  was the test's: a placed state must be forwarded.) The clone's failure is the policy's: held-out error next.
- **Sep 25 — the clone memorised; the teacher is learnable.** Held out (unseen starts), the clone's error 0.0199 is worse than
  predicting zero (0.0111): it memorised 660 rows. The teacher's labels are 4x more signal than sampling noise (re-planned
  from identical states). Left: data/capacity (a learning curve; perturbed starts multiply data) and hidden plan memory.
  Simon: perturb episode starts as DReCon did - D5.5 in the plan (PPO's starts AND the teacher's, for recoveries).
- **Sep 25 — plan memory was half of every label; removing it is not enough.** A memoryless teacher (plans from the
  filter's state, 2 MPPI iterations) is the best yet (3.65 s). But the clone's held-out error rises from the constant's
  (0.0084 at 25 updates) with every update: 660 rows teach nothing transferable. Normaliser refuted. Next: 10x data with
  perturbed starts - or the teacher feeds the world model and a small imitation weight instead.
- **Sep 25 — perturbed starts, calibrated; 10x data running.** `perturbStart` (pose noise + root kick, rested on the floor)
  in the fleet and the recorder. The servo alone survives about half the starts at 0.05 rad + 0.25 m/s: D5.5's level. The
  clone's 10x-data run (clean + perturbed teacher starts) is running detached.
- **Sep 26 — SuperTrack reread; ST in the plan.** The paper summarised precisely (gym, Local(X) with heights and up, the
  acceleration world model integrated over 8-frame windows, the 32-frame policy, L1 losses, 5 x 1024 nets, 150k buffer, 10^4
  iterations to first balance). Ours judged against it: every run that 'showed exploitation' was 3-5 orders of magnitude of
  optimisation short. The way back: parity, the model's form re-decided at scale, and measured anti-exploitation (an
  exploitation index, D5.2's trust signal, DReCon's filter in the graph, bigger perturbations). The 10x clone rerun died with
  its turn (detached runs do not outlive the turn) - queued.
- **Sep 26 — the overnight run planned (ON); feasibility measured.** The whole dance is feasible (the teacher holds 4 of 6
  four-second windows whole). The get-up is half: from mid-rise the teacher lifts the head to ~1.25 m; from the floor it
  never rises (head 0.5 m vs the reference's 1.0-1.4 m) while 'surviving' by the hips test - the head-height rule is the
  get-up's criterion. Next: search or physics for the floor-to-crouch lift.
- **Sep 26 — the get-up is feasible; the teacher was never asked to go up.** A stalled turn (invisible to the next) had run
  2.1b (search, agility, authority) and 2.1c (every joint): all failed from the floor. The cost dropped height and tilt
  (shape measured from the root's own pose). With SuperTrack's height and up terms, the teacher lifts the head from the floor
  to 1.1-1.3 m. Every cost and reward must see gravity.
- **Sep 26 — the gravity audit.** The task's reward scored a body lying with the right joint angles 0.80 while its reference
  stood; now a gravity GATE (heights and up, SuperTrack-style) takes it to 0.00002, and termination has a relative height limit.
  Wired into PPO's fleets and both Geno pages. Gravity at full weight halved the teacher's dance; a hinge (beyond 10 cm, ~11 deg)
  keeps 3.27 s of 3.65. Next: the floor lift with the hinge.
- **Sep 26 — one teacher per motion.** Hinged gravity keeps the dance but loses the rise; the root's height and tilt alone
  lift nothing (the rise is led by torso and head). `teacherFor(motion)`: no gravity for the dance (3.65 s), every body's
  height for the get-up (head to 1.1-1.3 m). SuperTrack's height term will carry the get-up - checked in the mini-night.
- **Sep 26 — one teacher cost for every clip.** Simon: ~100 clips, get-ups hidden, so nothing may be per-motion. Gravity on the
  body's axis lifts Geno best (head to the reference's 0.99 / 1.24 m from two floor starts) but taxes the dance; gated by how low
  the REFERENCE is (a per-frame property of its pose), the dance keeps 3.43 s of 3.65 and the get-up its lift. Next: one failure
  criterion for everything.
- **Sep 26 — one failure criterion, and what it must be.** `FailureCheck` (the task's own rule through its own functions) is used
  everywhere; the hips rule is gone. Measured: failure must mean fallen (height relative 0.4 m, tilt ~47 deg) or lost the pose -
  not drifting or turning (the teacher had wandered 0.5 m with its pose 6-12 cm off). But as the TEACHER's early warning the old
  hips rule was better; the teacher's cost will shape toward the path instead (across weight), the task's rule stays one.
- **Sep 26 — MimicKit restudied (MK2).** Biggest finding: our PPO treats the step cap and clip ends as deaths (GAE's alive=0 at
  any end, and the value at t+1 is the NEW episode's) - MimicKit bootstraps timeouts from the terminal observation. Also: their
  per-motion contact lists (a clip-agnostic 'unexpected contact' is better), worst-body pose limit, root height and 1-3 step
  lookahead in the observation, action-bound loss, advantage clip, frozen normaliser, LCP smoothness, ADD's learned differential
  reward (the 100-clip end state). Plan reordered: episode ends first.
- **Sep 26 — PPO's episode ends, done right.** The fleet says why an episode ended and keeps the state it ended in; the trainer
  values that state for episodes cut short (the cap; clip ends by option) and stops at losses; GAE is a pure function with a
  closed-form known answer (a right critic's advantages are exactly zero after a bootstrapped cut). End-to-end check next.
- **Sep 26 — the cut path, end to end.** A real trainer with a 6-step cap: 4 cut decisions, each bootstrapped from a finite, non-zero
  value of where it ended; learn runs. MK2.9 item 1 closed; next, the observation (root height, lookahead).
- **Sep 26 — the observation sees height and the future.** Centre-of-mass height, and the reference 33/67/100 ms ahead (where its
  centre of mass goes, and its shape then), all through one `observeFrom`. Heading-invariant to 1.4e-6. Geno's observation 175 numbers.
- **Sep 26 — root motion followed, and SEEN.** Simon was right: MimicKit rewards the global root (displacement and yaw), shows the
  policy its targets relative to itself, and fails at 1 m. Our reward had the global terms but the observation hid drift; now it shows
  the reference's place and heading from the character (exactly: 0.5 m seen 0.500000, 0.3 rad seen 0.300000), and the task fails at
  1 m / 90 deg again.
- **Sep 26 — adversarial review.** Three real bugs fixed: the watching leash dropped the tilt limit (now `Termination.scaled`, the one
  copy), FailureCheck's reference had no velocities (now bit-identical to the fleet's error), and 'frames kept' was one high on
  completion. Open: Geno's task options repeated at every call site - to centralise.
- **Sep 26 — plan v3.** A clean restatement (526 lines): standing rules and traps, the goal stated so it can fail, seven principles with
  their evidence, where we stand (robot, task, observation, action, learners, teacher, pages, known answers), nine lessons, then the
  work in order - T (task finished), P (PPO hygiene), S (SuperTrack as published, safe from its model), ON (the night), A (ADD, 100
  clips, D5 revisited), X (phone), M - with decisions, risks, file map and comparison tables. v2 archived.

- **Sep 26 — step 0: the Geno pages on toolchain 2307.** After the 2307 shader fix (spirv_2307_decorations_plan.md),
  geno_train (3.7 MB), geno_ppo (3.6 MB) and geno_track (11.8 MB) build through both new shader gates, and their smokes
  RUN: frames execute, GPU validation passes (train init 4564 calls / ~2258 per frame, ppo 4550 / ~325, track 4179 /
  ~855). But every managed smoke now FAILS the lifecycle leak check - hello_world and fluid_gpu too, so it is the engine,
  not Geno. The original uploaded tree fails identically on 2307, so the session's shader changes are cleared;
  claude.md records fluid_gpu's smoke PASSING on 2163, so 2307 is the prime suspect (not yet proven: the check may be
  newer than that record). The harness now prints the size: a CONSTANT per lifecycle (5760 bytes for hello_world at 1,
  10, 60 or 240 frames), always a multiple of 2880 - fluid_gpu 1x, hello_world and geno_ppo 2x, geno_train and
  geno_track ~4x (+128). One fixed-size engine allocation per init-something, never freed by deinit. Pages never
  deinit in a browser, so the pages themselves are usable; the smoke gate is red until found. Next: find the 2880.
- **Sep 26 — the smoke "leak" found: the shared glyph atlas.** Pre-existing, as Simon guessed - not 2307. Method: a
  temporary allocation trace (every alloc/remap/resize/free during the second lifecycle, paired by pointer; removed
  after). hello_world: exactly ONE block outlives lifecycle 2 - an 11532-byte hash-map table that replaced a 5772-byte
  one - allocated in the example's UPDATE, during its third `text` call (0 frames = no growth; 1 or 240 = the same).
  Cause: `Renderer2D.glyph_cache` (src/glyph_atlas.zig) keys glyphs by `FontFace.id`, "a counter, never reused". Each
  lifecycle reloads its font, gets a new face id, and rasterizes new entries; unloading the font leaves the old ones
  (documented in `unloadFontOwned`: they "go unused until it starts over" - the atlas resets only when its 4 pages
  fill). A bounded cache, but it grows on every font reload, which the managed lifecycle gate (flat live bytes)
  correctly flags - and the launcher switching apps is the production case. Every example draws text, hence every
  example "leaks" a hash-map growth step (2880 / 5760 / 11648). `resetRegistryFrom` (the launcher's per-child teardown,
  and `runnerDeinit`) is where the atlas should start over. Awaiting Simon's pick of the fix.
- **Sep 27 — T1: one definition of Geno's task.** `robot_geno.ppoTaskOptions(base)` stamps the task (DReCon
  bodies, servo gains, floor, rest-on-floor, the student's action scale, the gated reward, the task's failure rule)
  onto a PPO trainer's options; `robot_geno.fleetTaskOptions(envs, capacity, grace)` builds a raw fleet's (the
  SuperTrack path). `anytype` for the PPO one on purpose: naming `robot_ppo_track.Options` would pull the GPU compute
  host into robot_geno's shader-free test tier - and every assignment is a named field, so a rename is a compile error,
  never a silent skip. Migrated: geno_ppo, geno_train and the three Geno trainers in robot_ppo_track_tests - two of
  which (D5 step 3's, and the end-to-end cut-path test) had been running WITHOUT the gravity gate and with the old
  limits, and the T-pose one without the action scale and the floor rest. `grep` finds no hand-set Geno task field
  outside robot_geno. The action scales now exist once each: `student_scale` 1.2 (its reasoning moved there from
  geno_ppo: 0.6 barely beat the servo through DReCon's filter) and `supertrack_action_scale` 0.6 (unexplained;
  Phase S re-measures). Known answers: both helpers' fields equal the constants, the caller's knobs survive - each
  test proven live by a planted failure. The cut-path test passes under the full task (2/2, not skipped). Pages
  smoke green with call profiles IDENTICAL to before (ppo 4550 / 325.1, train 4564 / 2258.3). Left of T1's DONE
  WHEN: re-measure D5 step 3's judge numbers under the gated reward (a long measurement - detached, next turn).
- **Sep 27 — T1 redone TYPED: the task is a value, not a helper.** Simon: no `anytype` unless necessary.
  `ppoTaskOptions(base: anytype)` was avoiding an import edge, not being generic - so it is gone, with
  `fleetTaskOptions`. Now `robot_track.Task` (servo gains, floor friction, floor rest, reward weights, termination -
  what the character is asked to do and when it failed) is embedded as `task` in BOTH `Fleet.Options` and
  `robot_ppo_track.Options`; the PPO trainer hands it to its training and judging fleets in ONE assignment each
  (it copied six fields, twice). `robot_policy.Bodies` groups DReCon's watched/actuated lists the same way.
  robot_geno holds typed constants: `tracking_task` (the gated reward and the task's failure rule),
  `servo_task` (the D-phase condition: default reward and limits - kept so recorded experiment numbers
  reproduce, visible by NAME), `drecon_bodies`; action scales stay per learner (`student_scale`,
  `supertrack_action_scale`, now also used by the jitter test's literal 0.6). The constant is `tracking_task`, not
  `task`: 12 locals/params in robot_geno are named `task` and Zig rejects shadowing.
  CORRECTION to the previous entry: robot_geno ITSELF built nine Geno fleets by hand (my grep excluded it); now
  seven experiments use `servo_task` (S2b keeps its no-rest setting explicitly), the FailureCheck parity test
  `tracking_task`. Known answers: `tracking_task` carries the gates, `servo_task` differs in exactly those two
  fields; the cut-path test asserts the trainer's FLEET runs `geno.tracking_task` whole. PPO test root unfiltered:
  483 pass / 68 skip / 0 fail; pages geno_ppo, geno_train, getup_train, track_train smoke green, the Geno pages
  with identical call profiles. Left of T1: move the D-phase experiments to `tracking_task` and re-measure D5 step 3.
- **Sep 27 — adversarial review of the session's code; tutorial and plan brought up to date.** Found and fixed:
  (1) spv2wgsl `checkNoHandleValues` matched `texture_`/`sampler` ANYWHERE on a line - a local merely NAMED
  `sampler_count` failed the build (proven with a probe first); it now reads only the TYPE (after `->` / the `var`'s
  `:`), exact handle names; innocent-name cases added to its test; runtime-handle probe still refused, 217 cached
  modules pass. (2) `checkGraphicsInterfaceDecorated` judged a module with no SELECTED entry point as a vertex shader
  (`exec_model` defaults to 0 = Vertex); it now skips when no entry was selected. (3) `runnerWrongSideFrees` summed
  with `+` (traps on overflow) - now `+|`. (4) The Task refactor had put `pub const Task` BETWEEN `Fleet`'s doc
  comment and `Fleet`, so Fleet's documentation silently became Task's - caught by regenerating the tutorial's folds;
  Task moved above it. (5) `TrackingError` said "six ways" with eight fields (height, up) - source doc and tutorial
  prose fixed. Checked and found sound: no other root reads the moved option fields; the allocator split, atlas
  reset, leak trace and checkWgsl hold under the cases tried. Tutorial 10.1: eight parts (pose, place, gravity), and
  the task as ONE value with folds for `Task`, `tracking_task`, `drecon_bodies`. Plan T1: typed design as built,
  status, what remains. claude.md: show AND explain code in the reply every turn; no `anytype` unless necessary.
- **Sep 27 — D5 step 3 re-measured: the first completed 10x-data clone, under Geno's full task.** (The 10x rerun queued on
  Sep 25 had died with its turn, so this is also that result.) 17.7 min wall. Teacher: 12916 frames over 216 starts (clean +
  perturbed) -> 6461 demonstrations. Clone error 0.0749 -> 0.0575 over 2000 minibatches. HELD OUT (43 starts, 1287 rows):
  0.0675 vs always-zero 0.0770 - now ~12% better than predicting nothing (Sep 25, 660 rows: worse than zero - it had
  memorised); the curve flattens after ~1000 updates (0.0760 at 25 -> 0.0674 at 1000 -> 0.0675 at 2000). JUDGED (600
  decisions x 8, `tracking_task`): servo 90 failures / MTTF 107 / reward 0.493; clone 103 / 93 / 0.367. The clone still
  loses to the servo alone, but by 14% more failures where Sep 25's lost by 2x (184 vs 96). Two things changed since Sep 25
  (10x data AND the gated reward) - compare clone to servo WITHIN a run; rewards across the two runs are different
  quantities. Normaliser healthy (0 of 180 inputs flat; 0.06% / 0.10% pinned). T1 done.
- **Sep 27 — T2 mechanism: the worst body.** `TrackingError.worst_body` - the largest single body's distance in the
  root frame, the same per-body measure the mean averages, computed in the same loop - and `Termination.worst_body`
  (off by default, 1e30). The mean hides one limb far off; MimicKit ends on the worst body. And the field-list drift
  is closed for good: `Termination.scaled` and `terminated` now WALK the struct (every f32 limit, against the
  `TrackingError` field of the same name), with a comptime check that fails the build - "Termination.bogus limits
  nothing: TrackingError has no field of that name" (proven by planting one) - so a new limit is two lines in two
  structs, nothing else. The FailureCheck parity test walks every TrackingError field the same way (its list had
  been hand-written) - still 0.00e0, worst_body included. Known answer (synthetic states, one body moved 0.8 m of
  six): mean 0.16 passes the default rule, worst 0.8; the verdict flips between limits 0.79 and 0.81; `scaled`
  carries it. Next: measure the value on the servo and the teacher, both clips.
- **Sep 27 — T2 measured: where a worst-body limit would cut.** The servo alone (12 starts) and the teacher (`d5_teacher`,
  4 starts) on both clips, run until the current rule (`task_termination`, worst_body off) loses the reference or 5 s;
  each candidate's first crossing noted. The servo alone NEVER bends a limb far off: its worst body peaks at 0.05 m mean,
  0.10 m (dance) / 0.16 m (get-up) max, before any loss - it fails by falling WHOLE (root, height, tilt), never by one
  limb: a PD servo pulled straight to the reference pose follows its shape. The teacher, the best tracker, swings limbs
  far WHILE SUCCEEDING: mean peak 0.57 / 0.51 m, max 0.69 / 0.67 m. So a limit at 0.4 / 0.5 / 0.6 m cuts the teacher's
  good runs (dance 4 / 3 / 1, get-up 3 / 2 / 2 - some while the reference lay low); from 0.7 m NOTHING is cut by either
  tracker. 0.7 is 1 cm above the largest excursion seen - too tight on 4 teacher starts a clip. Recommended 0.8 m (11 cm
  of margin over the best tracker's largest good excursion; still catches a limb truly lost); MimicKit's 1.0 m is the
  safe alternative. Also: the ON.0b servo attribution test's hand-written limit list (it skipped the tilt limit) now walks
  `Termination`. Awaiting Simon's pick for `task_termination.worst_body`.
- **Sep 27 — T2 done: Geno's worst body capped at 0.8 m** (Simon's pick of the measured candidates).
  `task_termination.worst_body = 0.8`, with the measurement's reasoning in its doc. The T2 measurement test is pinned to
  the rule WITHOUT the limit (`run.check.termination.worst_body = 1e30`) and reproduced its numbers byte for byte; the
  FailureCheck parity test is still 0.00e0 with the limit included; tutorial 10.1 says what the cap is for.
- **Sep 27 — T3 code complete: unexpected contact** (verified by known answers and argument; no long runs, per Simon).
  GEOMETRY, the same for character and reference: `rbt.lowestPoint` split into `geomLowestPoint` (one shape's math) and
  `bodyLowestPoints`; `State.lowest` per body, filled by `stateOf`, `no_shape_height` from `init` (a world model's
  prediction never touches). `TrackingError.unexpected_contact` = of the bodies the character has within `contact_band`
  (1 cm) of the floor, the highest the reference holds its counterpart; an unknown reference height accuses nothing.
  `Termination.unexpected_contact` off by default (T2's rule: two fields, nothing else). Per-ROBOT exemption:
  `Task.contact_exempt` names (Geno's `foot_bodies`: both feet and toes - a foot is down in stance while a lagging
  character's reference lifts it into swing), resolved by `contactExemptMask` (a typo is an error; the world's empty
  name never matches) in the fleet (`Fleet.Options.body_names`; the PPO trainer keeps its caller's names for its judge)
  and in FailureCheck; `exemptFromContact` applies it to the CHARACTER's state only. Known answers: knee down vs a
  standing reference reads 0.45 and flips at the limit; both kneeling 0; a lagged foot swing 0.2, 0 once exempt; an
  unknown reference 0; per-body minimum == lowestPoint on the rig. The known answers FOUND two bugs before they shipped:
  the mask leaked on a typo (errdefer), and `feet` / `body_names` shadowed existing names. robot_track 433 pass / 0
  leaks; parity 0.00e0 with the contact term and exemption on both sides; PPO cut-path passes; geno_train builds.
  Geno's value is NOT set yet: 0.3 m recommended on the geometry (knee end 0.45 m standing, hands and hips 0.7-0.9 m,
  a hand lagging a get-up's lift tolerated for ~0.3-0.6 s) - Simon's call.
- **Sep 27 — T3 value set; Phase R (runs) planned.** Simon let me decide T3: `task_termination.unexpected_contact =
  0.3` on the geometry (reasoning in its doc; the overnight rehearsal is its measurement). The `tracking_task` known
  answer then FAILED, correctly: `servo_task` now differs from `tracking_task` in three fields (the feet exemption is
  part of the failure rule it leaves out) - the test states that now. Parity 0.00e0 with the contact limit live.
  PHASE R written into the plan (Simon: one run a night on the laptop, tested in the morning, prepared by day; old
  school; programmatic setup, UI for runtime things). MimicKit studied: one program `--mode train|test`, three YAML
  configs copied into a self-describing out_dir, evaluation (deterministic test episodes) INSIDE training as the
  curve, runs compared by overlaying log.txt; its model.pt omits the optimizer and counters - a warm start. Ours: a
  typed `RunConfig` in code + a snapshot zip (run.json, state.bin with Adam moments / counters / RNG / sampler stats,
  curves.csv, events.log, README.txt) that alone tests or CONTINUES the run exactly; Train (headless) / Test (training
  paused) / Pause; the judge as a curve. FOUND: ON-a's "IndexedDB via zimr's storage" does not exist - zimr has
  localStorage (~5 MB strings), a drop queue and a click-to-download anchor; OPFS proposed. And a laptop trap: a hidden
  tab stops the frame loop (training halts) - wake lock + visibility guard. Decisions U1-U6 to ask.
- **Sep 27 — T4: no drift weight passes; the A/B found why the teacher regressed.** `across_weight` is now
  `Planner.Options.across_weight` (0.3 default, behaviour unchanged). Measured under today's `task_termination`
  (D1's dance starts, until the rule loses the reference, cap 5 s; ON.2.1h's floor lift, 4 s fixed): servo alone
  1.14 s; drift weight 0.3 / 1.0 / 2.0 -> dance 1.37 / 1.65 / 1.48 s, lift head best (ref 0.99 / 1.24 / 1.43)
  0.62/0.63/0.66, 0.53/0.50/0.94, 0.63/0.79/0.82 m. None reaches 3 s: `d5_teacher` keeps 0.3 (T4's timebox).
  But the lift had REGRESSED from Sep 26's 0.75/0.91/1.19 with no teacher change - and the A/B (0.3, T2's worst-body
  and T3's contact limits switched off in the teacher's CHECK) brings the rise back from 530/554: 0.90 / 1.12 m
  (509: 0.45, worse - single runs). Why: the teacher's early warning pays the fall penalty within `danger` (0.6) of
  EVERY limit - the worst body at 0.48 m (under the 0.69 m swings T2 saw it make while succeeding) and contact at
  0.18 m (a hand pushing the floor while the reference's lifts) - so it plans away from its own balance moves and
  from pushing off the floor. (The dance A/B is confounded: without the limits the run is also JUDGED more loosely.)
  Proposed T4b: the teacher's early warning without the EVENT limits (worst body, contact) - the task's rule still
  judges; P2: the teacher may shape.
- **Sep 27 — T4b: the teacher's early warning, three ways.** `FailureCheck.withinLimits` (the check against given
  limits; `within(fraction)` wraps it), `Planner.Options.warning` (null = the check's own rule), `teacher_danger`
  (0.6) and `teacher_warning`. Measured (dance judged by the task's WHOLE rule, D1's four starts, cap 5 s; lift from
  509/530/554, head best vs 0.99/1.24/1.43 m):
      warning                                  dance     lift              mean shortfall
      margin on every limit (T4)               1.37 s    0.62/0.63/0.66    0.38 m
      event limits left OUT                    1.13 s    0.77/0.90/1.12    0.28 m   (dance = the servo's 1.14)
      event limits warned AT the event (kept)  1.94 s    0.66/0.36/1.13    0.37 m   (dance 1.85-2.08 every start)
  Kept: a margin on the gradual limits (drift, heading, height, tilt), none on the event ones (worst body, contact) -
  `teacher_warning` divides them by the margin so they land ON the task's values. The best dance yet, consistent;
  the lift no worse than T4's overall. SUSPECTED: T3's contact limit (0.3 m, chosen on geometry) blocks SLOW get-ups -
  the teacher rises well from 530 only when free to cross an event limit, and it rises slower than the reference
  (head 0.3-0.5 m below it), so its hands still push the floor after the reference's are 0.3 m up. If so, the task
  would end a learner's slow-but-real get-up too. Next: measure which limit the lift from 530 crosses (T3 revisit).
- **Sep 27 — T3 revisit: the event limits are off; lag is RSI's job.** Judged silently with the task's whole rule, the
  teacher's three good rises (event limits free in its warning; head to 0.77 / 0.90 / 1.12 m) would ALL end within
  0.8 s: from 509 the worst body (0.83 > 0.8), from 530 contact (Spine3 down, reference's 0.30 m up), from 554
  contact (RightArm + RightForeArm down, reference's 0.6 m up) - a rise LAGGING the reference, not a fall. Both event
  limits OFF in `task_termination` (mechanism kept, tested; T3 rejected in its frame form by its own bar). Then the
  gradual limits end the same rises at 1.03-1.68 s (tilt 0.95 / 0.83 > 0.8; pose rotation 1.24 > 1.2) - and that is
  fine: DeepMimic's reference-state initialisation starts episodes in step with the reference, so the rise is learned
  stretch by stretch; falling behind just ends an episode. Consequences: T5 (adaptive starts) carries the get-up; the
  teacher's 4-second open-loop "lift" is not what the night needs - survival under the rule from starts spread
  through the clip is. A lag-tolerant contact rule (the reference's lowest point over the last ~0.5 s) is noted for
  later. Tutorial 10.1 updated: the event terms are measured, not limited, and why.
- **Sep 27 — the plan reordered: foundations before curriculum** (Simon: "a good SuperTrack training on the 10-second
  dance that is always similarly difficult; critical things before tweaking the curriculum"). New order: T (done) ->
  F (SuperTrack foundations on `dance_5_15`) -> R -> ON (first night: the 10-second dance ONLY, uniform starts, no
  perturbations) -> C (curriculum: T5 adaptive starts, the get-up / S13, perturbation ramps, more clips) -> P -> A.
  Phase F, in its order: F1 the judge (deterministic: mean action, 20 starts every 0.5 s, MTTF / share reaching the
  end / gated reward, the servo on the same starts) - first, because everything after is measured by it; F2 the
  exploitation index and trust, measured every evaluation; F3 the servo's target velocities, measured on the servo
  alone (a free win if it holds longer); F4 the paper's inputs and losses (normaliser from the clip, L1, noise units);
  F5 Simon's filter in the graph; F6 drift in the policy's input and loss; F7 windows / data / scale; F8 the world
  model's form (optionally a buffer pre-filled with the teacher's demonstrations); F9 a CPU mini-run - the gate before
  GPU time. S10's control and S12 only if F2 shows exploitation. The first night's success: MTTF >= 5x the servo's,
  >= 60% of the judge's starts reaching the clip's end, reward above the servo's, exploitation bounded.
- **Sep 27 — F1a: the judge.** `robot_track.judge(gpa, m, clip, options, starts, actor)`: its own fleet, one
  environment per start, placed EXACTLY (`Fleet.startAt`, split out of `restart` with the same random draws - every
  fleet test still passes, 434), the actor's mean action (an `Actor`: context pointer + function, no anytype; null =
  the servo alone), no noise, no shoves, no grace, no cap before the clip's end; every start's FIRST episode counted
  to its end. `Judgement`: MTTF (watched time per failure), share reaching the clip's end, mean gated reward.
  `evenStarts(clip, every)`. Known answers on the rig: identical twice; every start counted once; the servo IS the
  zero actor. BASELINE on `dance_5_15`, 20 starts every 0.5 s: servo alone MTTF 1.61 s, 1/20 to the end, reward
  0.476 - the first night's bar is now >= 8 s. Review catch: `copyState` duplicated `State.copyFrom` and missed T3's
  `lowest` array (a copied terminal state kept stale floor heights) - deleted; the one caller uses `copyFrom`.
- **Sep 27 — F1b: SuperTrack judged.** `Resident.judgeActor()` acts on the judge's fleet with the policy mirror's MEAN
  action (the learner's `features` now `featuresOf(fleet, env)`; non-finite actions zeroed as in `act`). The judge
  became INCREMENTAL - `robot_track.Judging` (`init`, `advance(actor, budget) -> done`, `result`), `judge` = run to
  the end, bounded by the clip's length - because a whole judgement is ~1 s native, seconds on a phone, and the
  night's judge (R4) must not stall frames. Known answers: zero mirror == servo EXACTLY; trained != servo; judging
  leaves the learner's rng, its fleet's rng and frames byte-identical; chunks of 7 == one shot. The panel wiring goes
  to the night page (R4), not the phone page. F1 complete for the foundations.
- **Sep 27 — F2: trust and exploitation, on the judge's starts.** `latent.Learner.diagnose` (the CPU learner - F9's):
  five rollouts from every judge start (real zero / real policy / model zero / model on the policy's recorded actions
  / model closed-loop policy), compared over the steps BOTH real rollouts lived. TRUST = the model's error following
  where the policy really went, over the trivial predictor "it tracks the reference" (whose error on those states is
  their tracking loss - so e_0 costs nothing). EXPLOITATION = promised gain (model zero - model policy) minus delivered
  (real zero - real policy), over real zero. The judge's rollouts are held out by construction. A bug caught in
  review before any run: on the step an episode ends, the fleet has ALREADY restarted it - its state there is the next
  episode's; such a step is not compared. Refactors that removed duplication: `LatentWorld.targetsOf` (the servo's
  aimed-at target, one definition for recorded and live steps), `goalOf` / `liveFeaturesOf` take a fleet,
  `robot_track.judgeOptions` (one definition of a judged fleet). Known answers: zero policy -> exploitation exactly 0,
  identical twice, the learner's fleet untouched. robot_latent 437 pass unfiltered. The CPU learner has its judge actor
  too. Tutorial: 11.13 "How you know it is learning" (the judge, trust, exploitation). Two documentation bugs found:
  the robot tutorial's 11.2 and 11.8 shared the anchor `worldmodel`; the zimrnum tutorial's chapters 16 and 18b shared
  `rl` (18b was unreachable from the contents). Fixed, and doc-gate gained property 5 - no id twice in a page.
- **Sep 27 — F3: velocity feedforward judged, and dropped.** Made a servo option the fleet honours
  (`Gains.velocity_feedforward`, so it travels in `Task`; `ServoRun`'s separate flag retired into it) with the reference's
  velocity from ONE helper, `robot_track.referenceVelocity` - the old ServoRun copy indexed the clip with the model's
  nq (right only while clip.nq == m.nq: T6's fault class), fixed in the move. The judge on `dance_5_15`, servo alone:
  zero-velocity damping MTTF 1.61 s / reward 0.476 (F1's baseline, exactly); feedforward 1.63 s / 0.498. Survival +1%:
  balance is the limit (Sep 24 said the same under the old rule). Dropped by F3's own bar - and it would make part of
  the servo invisible to the world model, whose reference input is the next pose, not the reference's velocity.
- **Sep 27 — F5 added: a FEASIBLE reference (Simon's idea).** Bake the dance into a physically possible version with a
  strong OFFLINE search, so the learner only learns feedback. Precedent: SAMCON (Liu et al. 2010) turns mocap into an
  open-loop control trajectory the simulator performs; "Guided Learning of Control Graphs" (Liu et al. 2016) learns only
  the feedback around such trajectories. Refinements recorded in F5: save TWO channels - the achieved states (the new
  reference) and the servo targets actually used (mocap + planned offsets; the world model's reference input) - so the
  servo alone replays the dance from any exact start; the replay is a knife-edge off exact states, which is exactly
  the feedback to learn; the search must beat today's teacher (~2 s) with a beam, many samples per short window and
  BACKTRACKING (SAMCON's core), under a STRICTER shape cost (the teacher's 0.7 m balance swings must not be baked in);
  fidelity to the original mocap reported and gated. F10's mini-run A/Bs original vs feasible for the first night.
  Phase F renumbered: F5 feasible reference, F6 filter, F7 drift, F8 windows/data/scale, F9 world model form, F10 mini-run.
- **Sep 27 — F4a: the normaliser from the clip.** `latent.measureClipNormalizer(owned, m, clips)`: every frame of every
  clip posed exactly as the fleet poses a reference, in the model's local features - the paper's way. Before: measured
  over the replay after geno_train's 200-step servo warm-up, i.e. ~3 s of FALLING, so "one spread" meant "typical of
  falling". Now it means "typical of the dance", fixed before the first step. The two measures share one `Moments`
  accumulator (sums, squares, the 1e-3 spread floor, the Normalizer - with an errdefer the old code lacked).
  `WorldOptions.normalize_from_clips` off by default; geno_train switched. Known answer: its own frames come out mean 0,
  variance 1 (to 1e-3), floored features exactly 0; identical twice. robot_latent 438 pass; geno_train smoke green.
- **Sep 27 — SuperTrack studied three ways: the paper, an unofficial repo, ours** (`src/notes/supertrack_comparison.md`).
  The repo (Simon's upload) has NO physics simulator - its world model learns mocap kinematics - and five bugs (no root
  subtraction in Local, angular velocity logged after dividing the matrix by dt, explicit-Euler order, acos(w) as the
  rotation loss, alpha = 120 used as radians); read for shape, not choices. The PAPER, read in full, changed the plan:
  its failure rule is the HEAD's height 25 cm off the reference's after a minimum of 48 frames (ours: five limits, an
  8-frame grace) -> F3b; it simulates at 240 Hz, four steps a frame (ours 60 Hz) -> F3c; losses are L1 in WORLD space
  (world model) and LOCAL space per group (policy) with equal-contribution weights - ours one L2 over normalised
  features, which down-weights fast features -> F4b; alpha 120 degrees, sigma 0.1 (0.21 rad; ours 0.6 / 0.06) -> F4c;
  RAdam and gradient clipping -> F4d. Confirmed: our Local(X), policy inputs, off-policy buffer use, and F4a's
  normaliser-from-kinematic-data. Corrected: my F3 doc claimed SuperTrack's servo is zero-velocity - the paper used the
  reference's joint velocities in PhysX, zero in Havok/Bullet, with similar results (so F3's "off" stands, reworded).
  Review catch: `InModel`'s doc comment had been swallowed by `Diagnosis` (inserted between them) - fixed; claude.md
  now carries the rule (third time this session).
- **Sep 27 — F3b: SuperTrack's failure rule, adopted.** The head's height gap as an error term and a limit
  (`TrackingError.head_height`, `Termination.head_height`), the head named per robot (`Task.head_body = "Head"` for
  Geno) and resolved like the feet (`headBody`; one `bodyIndexByName` for both); `trackingErrorWithHead` for the two
  judges, `trackingError` = it without a head (18 call sites untouched). Judged side by side on the servo alone (F1's
  judge) and the teacher: dance 1.61 vs 1.53 s, get-up 2.89 vs 2.75 s, teacher 1.56 vs 1.66 s - equally strict; both
  fail by falling and the head says so. Adopted: head 25 cm + root 1 m / 90 deg, everything else OFF (our pose
  defaults 0.35 m / 1.2 rad included) - one clip-agnostic limit, the one the paper's results were measured under.
  The paper's minimum episode (48 frames) is our training grace - to be max(48, the policy window) on the night.
  Known answers: the head gap exact (1.0 -> 1.25 reads 0.25, flips between 0.24 and 0.26), other bodies' heights
  leave it 0, a misspelt head is an error; parity 0.00e0 with the head on both sides. F1's baseline: 1.53 s.
- **Sep 27 — F4e: the policy's clock, 30 Hz (Simon: physics stays 60 Hz, the policy acts at 30).** Checking it found
  SuperTrack acting EVERY physics step here (60 Hz, as the paper) while DReCon / PPO decide every second step. F3c
  (240 Hz physics) dropped. The CPU learner now has `decide_every` (default 1 = unchanged): decisions on the even steps
  of each episode, held between - collecting, in the policy's rollouts through the model (the held step applies the
  decision's own graph node; penalties priced on decisions only), in `modelLoss`, `diagnose` and the judge's actor
  (the judge's action buffer persists, so an actor that does not write holds). The world model stays per physics step,
  learning from the action actually applied. Plan: the remaining F steps ordered by fundamentals - the action path
  (F4e, F6 filter, F4c scale/noise), the world model (F9 + its F4b loss), the policy's loss (F4b), the optimiser (F4d),
  scale (F8, F7), the feasible reference (F5), the mini-run (F10). Kit clock + parity before R/ON.
- **Sep 27 — F6a: Simon's filter inside SuperTrack's training.** `robot_track.filterAction` (applied = beta asked +
  (1 - beta) applied) is now the one definition - DReCon's controller calls it. The CPU learner: `filter` (1 = none;
  0.2 on the night), `decideInto` - ONE definition of a decision shared by collecting, the judge and `diagnose` (noise
  only when asked, never a non-finite action, rest at an episode's first step, then the filter) - and the rollout
  graph blending with tensors from the replay's action before the window (`appliedBefore`), so a decision's gradient
  reaches every later step it still shapes. The world model learns from what was APPLIED. The known answer that
  matters: noise off, the graph's loss = the same rollout row by row (policyRow, filterAction, stepRow) to 1e-5, with
  held steps and a non-rest starting state. F6b (the policy seeing its last applied action) is next - it changes the
  policy's parameter layout, so it gets its own step.
- **Sep 27 — review of the last six steps, and plan v4.** Found: `geno_track` had not COMPILED since T3
  (`FailureCheck.init` gained the body names; pages are outside `check`) - fixed, smoked; feedforward's target
  velocity at a clip's end was the last moving step's (and a one-frame clip underflowed) - now `referenceVelocity(frame)`,
  zero at the end; the CPU learner now refuses a filter outside (0, 1] or a clock under 1; the tutorial caught up with
  F4a / F4e / F6a (11.10, 11.11). Clean on inspection: FailureCheck's error paths, the normaliser's posing against the
  goals', the clock's episode alignment, `appliedBefore`, the graph's holds and penalties. Re-run: robot_geno 457 pass
  under the new rule; robot_latent 442; every Geno page smoked green and leak-free; F3 re-measured (1.53 vs 1.52 s,
  reward 0.499 vs 0.527). Plan v4 written (v3 archived): the done work summarised; what remains in stages A-H with
  the BENCH (a deterministic CPU learning curve) moved ahead of every recipe decision.
- **Sep 27 — A1: the policy sees what it is applying (CPU).** `LearnerOptions.sees_applied` (default false). The
  action applied BEFORE a decision - the filter's state - is a third input to the policy's first layer, through
  `Learner.applied_block`: actions x hidden, ZERO at the start (made after the seven from no random numbers, so the
  seven and the random stream behind them are bit for bit a blind learner's), with its own Adam; `stepAdam` steps the
  seven and the block together, so no update path can leave the block out and the two Adams count in lockstep. Where
  it is read: the training graph (`applied` as it stands before each decision - a Var, so the gradient also reaches
  the decisions that made it), `decideInto` (the slot; the episode-start reset now happens BEFORE the policy reads it),
  `modelLoss` and `diagnose` (their filter state), and cloning (`appliedBefore` per recorded step, so a cloned policy
  is the function the learner acts with). `policyOnGraph` / `policyWith` take it as one optional value (`AppliedInput`,
  `AppliedRow`: weights and action together); the kit's call sites pass null. Known answers: at zero the block is
  invisible - the same raw action whatever it is told, the same first update (loss and all seven tensors exactly),
  only the block moving; graph-vs-rows parity with the block planted; a decision reads its planted slot (and not what
  a slot-ignoring decision would blend), and rest at an episode's first step; cloning's loss equals the rows'. Negative
  control: two planted bugs in one build - the graph fed the window's STARTING applied action at every decision, and
  `decideInto` reading the slot before the reset. The reset bug failed its test at once; the graph bug PASSED the
  parity test, because at the untrained output layer's 0.01 scale a wrong action moves the loss far below 1e-5 - F6a's
  test had the same blind spot. Fixed: the helper now plants the output layer too and compares the graph's applied
  action at EVERY step (`step_actions`) with the rows', beside the loss; re-planted, the graph bug fails it (L14).
  robot_latent 8 of 8 (the clock, the filter, the four A1s, diagnose, the normaliser); the kit's three policy tests
  green at defaults.
- **Sep 27 — A1 landed (the turn that wrote it stalled before replying).** Recovered from its logs: the code, the
  tests, the tutorial paragraph (11.11) and the plan were all in the tree; `check` had gone red on ONE line (a
  123-column comment in `robot_latent_kit_tests.zig`), rewrapped. Re-verified from the binaries themselves: robot_latent
  9 pass / 2 skip (the two `robot_track_st` measurements, skipped by design) - all four A1s OK; the kit 17 of 17; both
  pages that import robot_latent (`geno_train`, `track_train`) smoke green, example 0 -> 0 bytes. Simon ran geno_train
  on his phone: 4 characters, 1456 rounds, 1211 character-steps a second, 1574 s of motion in 74 s, the servo alone
  2.67 s there - then it throttled and crashed (he will try a desktop; Phase R's self-healing and checkpoints are
  what answers an unattended crash). A2 (the recipe as one value) is next.
- **Sep 27 — A2: the recipe as one value.** `robot_geno.supertrack_recipe`: 0.6 rad a unit, sigma 0.1, a decision
  every 2 steps, the filter at 0.2, sees applied, the normaliser from the clips - every other learner option at its
  default (sizes are the bench's and the probe's). Typed `SuperTrackRecipe` (the fleet's `action_scale` + a
  `LearnerOptions`) rather than the plan's bare `LearnerOptions`: the scale is the fleet's, and a recipe without it
  would let a bench build its fleet at the fleet's default 0.2 rad. Known answers, each against its REASON: the clock
  and the filter equal `robot_policy.Controller.Options`' defaults (DReCon's, P5); filtered implies `sees_applied`;
  the scale equals `supertrack_action_scale` (what geno_train reads until Stage G); `std.meta.eql` against the
  defaults with the plan's five changes (no stray override). And read back at the point of use: a learner built from
  it on Geno's dance (sizes shrunk, the bench's override) has 30 decisions a second on the model's own timestep, the
  applied block, and the clip's normaliser bit for bit. `supertrack_action_scale`'s doc no longer says SuperTrack
  lacks the filter. Tutorial 11.11 gained a paragraph. Next: B1, the bench.
- **Sep 27 — B1 built: `zig build st-bench`.** `src/robot_st_bench.zig` (rooted in `src/` like robot-bench and
  clip-bake; ReleaseFast like the training chunks; installed to `tools/zig-out/bin/st_bench` like `measure`, since a
  step cannot forward arguments). Geno on `dance_5_15`, fleet and learner built from `supertrack_recipe` at CPU sizes
  (8 characters x 4 steps an iteration, replay 256 each = 34 s; policy and world 64 wide, batch 32; window 16),
  SuperTrack's rhythm (collect, one world update, one policy update); a LOOK every `every` iterations (default 100):
  the judge's 20 starts + `diagnose` -> one CSV row written at once (iteration, wall, samples, both losses, MTTF,
  share to the end, reward, trust, exploitation), provenance lines read back from the built objects. Options are
  refused when misspelt. The recipe gained `training_grace_steps` (48, the paper's minimum episode) and
  `trainingTask()` (grace = max(48, window)); the A2 test checks the trained task is Geno's own but for the grace.
  Known answers: the servo line reads 1.532 s / 1 of 20 / 0.4987 (F1's baseline); iteration 0 reads 1.52 s (the
  untrained policy ~ the servo); the same seed twice gives identical rows (wall aside), seed 2 differs. Rate on this
  box: 3.2 iterations/s - collect 12 ms, world 82 ms, POLICY 222 ms an iteration: the policy update is 70% of the time
  (risk 1's knob). First 40 iterations: MTTF 1.52 -> 1.17 s while exploitation rose 0.02 -> 4.9 - the policy exploits a
  world model 40 updates old, the curve's job to show whether that turns. Next: the 10-minute run, then B2's 30.
- **Sep 27 — deep review of A1-B1: one real bug in the bench, three hazards cleared by measurement.**
  1. BUG: a setting the learner REFUSES still RAN. The bench was ReleaseFast, where `assertf` is stripped - with the
     default mode's `assert_log` it logs one line and carries on - so `--filter=0` printed "assert failed" and ran to
     exit 0, writing a plausible CSV: a policy that can never move reads exactly like the servo, so an A/B arm with a
     bad setting would have reported "no effect". Fixed twice over: `LearnerOptions.problem()` is now the ONE
     definition of valid learner settings (`Learner.init` asserts it; `!(x > lo)` so NaN fails too), and the bench
     refuses with it in words before building anything, plus its own: a non-positive action scale, a replay no
     longer than a window (that network would never update and its curve would sit flat). Six bad settings, six
     refusals. And the bench now builds ReleaseSafe.
  2. MEASURED - ReleaseSafe costs this workload 1.7x, not the ~15% claude.md quotes for tools: 3.2 -> 1.9
     iterations/s (policy update 221 -> 375 ms). The rows are BITWISE IDENTICAL in both modes (same seed, 40
     iterations), so the speed/safety choice changes no number, only whether a fault stops the run. Put to Simon.
  3. MEASURED - looking does not touch training: the row at iteration 40 is identical with a look every 20 or every
     40 iterations. (The determinism check could not show this: both runs looked at the same iterations.)
  Cleared by reading: nothing outside robot_track copies the replay (so `episode_steps` cannot be dropped); the
  block's Adam is built and stepped exactly as the seven's (same `AdamSet`, same rate, stepped together). Hazard kept
  for Stage G: the kit's `packPolicy` takes `[7]Tensor`, so a learner with A1's block would lose it there - today only
  tests call it, all at defaults.
- **Sep 27 — the bench's build: option C (Simon).** Two builds of `src/robot_st_bench.zig` from `zig build st-bench`:
  `st_bench` (ReleaseFast, 3.2 it/s) for long runs, `st_bench_safe` (ReleaseSafe, 1.9 it/s) to CLEAR a configuration -
  its first stretch run Safe, then `st_bench --compare=safe.csv,fast.csv`, which checks every configuration line but
  the build's and every shared row but the wall clock, and says how far agreement reaches. In both builds an
  error-level log is FATAL (`std_options.logFn = fatalLog`, pinned by a comptime check to std's `defaultLog` type):
  ReleaseFast strips a failed assert to a log line, and that line now stops the run. Expected outcomes are EXIT CODES
  (0 ran/agree, 1 disagree, 2 refused), not errors - std logs an error returned from `main`, which the hook would turn
  into a panic. Every CSV names its build (`# build: fast|safe`). Controls: a Safe 40-iteration prefix and a Fast
  60-iteration run agree (3 rows, rc 0); another arm's CSV is refused on its configuration line (rc 1); one digit
  changed in the sixth decimal of one loss is caught (rc 1); `--prove-fatal-log=1` kills both builds (rc 134, the
  planted line printed first); a refused filter exits 2 without a panic.
- **Sep 27 — review of the last turns (A1 recovered, A2): four bugs, each now with a test that fails without its fix.**
  1. The learner's action SLOTS started UNINITIALISED: `fleet_actions` came from `owned.alloc` and was read before its
     first write - held on a clock's odd steps, blended into by the filter (F6a), read by A1's policy. Fresh arena
     pages are zero, so every test passed. Now each slot starts as what its character was last applying (the
     replay's newest record) when the fleet is mid-episode, rest otherwise - which also makes the hand-over record
     agree with `appliedBefore`.
  2. `appliedBefore` GUESSED rest in two places F6a had documented as simplifications, and A1 made the policy READ
     the guess: across a SHOVE (a shove ends a segment, not an episode - the filter carries through) and at the
     oldest record of a full ring (the step before it is gone). The replay now records each step's place in its
     episode (`Replay.appendStep`, `episodeStepAt`; `append` records null: not a rollout step); `appliedBefore` is exact
     across shoves and reports UNKNOWN (NaN into `out`) at the ring's edge; the learner draws through `drawWindow`
     (redraws an unknown start when it matters: a filter, or a policy that sees it - identical to `sampleWindow` at
     defaults), `trainPolicyOn` refuses (`error.UnknownAppliedAction`) before filling anything, cloning too.
  3. CLONING under a filter or a clock regressed the raw ask onto blended or held records - A1's cloning test even ran
     it at filter 0.2 and called it right. `cloneStep` refuses (`error.CloningNeedsRawActions`); A1's test clones
     without a filter. No production caller cloned with either (the D-phase learners run at defaults).
  4. A2's second test had two checks true by construction (the learner's copied options, the fleet built from the
     value) - removed (claude.md: a self-referential check is not a check).
  Known answer for 1 and 2 - COLLECTION ITSELF: the slot every character was about to decide from, recorded before
  each step with shoves every 7 steps, episodes capped at 50 and the ring wrapped; every record in the ring agrees
  (the hand-over included), the oldest is unknown, training refuses a window there, 1000 draws all known. Negative
  controls, one build each: the old segment rule planted -> fails; the old zero start planted -> fails (the hand-over
  check). robot_latent 11 pass / 2 skip; the A2 tests; the kit 17 of 17. Tutorial 11.7: a segment is not an episode.
- **Sep 28 — B1 DONE: the 10-minute run (`st_bench --minutes=10`, seed 1, the recipe's CPU sizes).** 1,659
  iterations in 600 s on this ONE-core sandbox (2.8 it/s: collect 9 + world 90 + policy 255 ms an iteration); 18
  judged rows in `src/notes/bench/b1_10min_seed1.csv`, the curve beside it (`.png`). Known answer: iteration 0 is the
  untrained policy, judged like the servo (MTTF 1.52 s vs the servo's 1.53). Then:
  - MTTF FALLS under that baseline within 100 iterations (0.62 s) and stays there (0.50-0.64 s, 0.56 at the end);
    no start reaches the end after iteration 100; reward 0.50 -> ~0.17.
  - TRUST (the model's error following the policy's real path, over the trivial "it tracks" predictor's) goes
    3.14 -> 0.23, monotone after iteration 200: the WORLD MODEL learns - by 10 minutes it is four times better than
    assuming the character tracks.
  - EXPLOITATION (the gain the model promises the policy over doing nothing, minus the real one, per unit of the
    real zero-action loss) jumps to 299 at iteration 100 and stays at 90-136: the policy optimises through the
    model into states where the model is wrong in its favour. Trust is measured on the policy's RECORDED actions;
    exploitation on the policy acting INSIDE the model - the model is right where the policy went, wrong where the
    policy would take it.
  Reading (B2's own rule, read early): the world half works, the coupling does not - the policy exploits the
  model. So B2's 30-minute baseline will likely show the same flat curve; it is still the curve every Stage C A/B is
  judged against, and C's adoption rule ("exploitation bounded") is the one this run says matters most.
- **Sep 28 — I1: noise on the world model's predictions, built and measured (Simon: work on the ingredients).**
  `LearnerOptions.world_noise` (and `world_noise_draw`, the tests' deterministic stand-in, like `noise`): after every
  predicted step of the policy's training rollout, `z += world_noise * eps` - eps a [batch, features] constant per
  step, refilled each call; drawn from the learner's stream only when the knob is on, so a learner without it draws
  exactly the stream it always did. `problem()` refuses a negative or NaN value; `st_bench --world-noise` and the
  CSV's configuration line carry it. Known answers: the parity test (graph vs rows, now over a `Variation`) with the
  noise, with and without A1's input - the rows add the same draws after `stepRow`; negative control: the graph's
  noise planted at HALF size fails exactly that test; zero noise reproduces B1's rows 0 and 100 in every column but
  wall time. Bench, 4 minutes at 0.2 (678 iterations) against B1's rows:

      iteration   MTTF base / noise   trust base / noise   exploitation base / noise
         200        0.68 / 0.46          0.99 / 0.86            78 / 132
         300        0.55 / 0.32          0.62 / 0.72           131 / 297
         400        0.50 / 0.32          0.47 / 0.56           136 / 289
         500        0.53 / 0.30          0.40 / 0.48           136 / 291
         600        0.59 / 0.32          0.34 / 0.39           128 / 177

  HARMFUL at 0.2: exploitation about doubles, MTTF falls by 40%, the model learns a little slower (from a worse
  policy's data). The mechanism the numbers fit: every knock is an error the policy is scored on, and the cheapest
  way to shrink it is a harder correction - the action the model believes and the body cannot deliver. Kept, off.
  Next for it: 0.05 (is the harm monotone?), noise scaled to the model's per-feature error, and the window length.
  Tutorial: a paragraph on the knob beside the others that fight exploitation.
- **Sep 28 — I1b: two world models and their disagreement (Simon's idea), built and measured.** `twin_world` trains a
  second `LatentWorld` (seed + 1, or `twin_seed`) on the same replay - its own stream, so its own batches too; the
  normalisers match because both are measured from the same replay. In the policy graph both step from the SAME
  state and the rollout goes on from their average `(p + o) * 0.5`; `w_disagree` prices `|p - o|^2` per feature on
  every step, held or not - the gap written `p + (-o)` so its gradient reaches BOTH predictions. `modelStepRow` is the
  one row-level step (`modelLoss` and `diagnose` go through it), `trainWorld` trains both. `problem()` refuses a
  price without a twin. Known answers: the parity test over twin + price, and over every ingredient at once (A1,
  world noise, twin); a SAME-seed twin with a price gives the single model's loss to the bit; negative control -
  the twin stepped but not averaged fails exactly the parity test; twin off reproduces B1's rows. Bench, 4 minutes,
  w_disagree 1 (436 iterations at 1.9 it/s: world 155 ms, policy 372 ms - both carry a second model):

      iteration   MTTF base / twin   reward base / twin   exploitation base / twin
         100        0.62 / 1.06        0.217 / 0.260          299 /  48
         200        0.68 / 0.52        0.203 / 0.187           78 / -62
         300        0.55 / 0.63        0.173 / 0.209          131 /  86
         400        0.50 / 0.54        0.155 / 0.226          136 /  94

  PROMISING, where I1's noise was harmful: exploitation lower at every look (briefly NEGATIVE - pessimistic, the
  direction the price pushes), reward up to 45% higher, MTTF modestly better - and better at equal wall time too
  (4 minutes: reward 0.226 against the baseline's ~0.17). Still far from the goal (MTTF under the untrained 1.52 s);
  one seed. Next: stronger prices (3, 10), then a second seed. Chart: `src/notes/bench/i1b_twin_vs_noise.png`.
  Found on the way: `zbuild` reports a missing `zig` on PATH as a bare `error: FileNotFound` - worth a real message.
- **Sep 28 — I1 removed (Simon: "we know model noise was a bad idea").** `world_noise`, its draw hook, the per-step
  constants, the injection, the draws, its parity test and the bench's `--world-noise` are gone; the all-ingredients
  parity case keeps the twin with A1's input. The measurements stay (`src/notes/bench/i1_*`) and the lesson is L14.
- **Sep 28 — I1b's price, at 3 and 10 (4 minutes each, seed 1).** Same iterations, MTTF / reward / exploitation:

      iteration   baseline             w 1                  w 3                  w 10
         100      0.62 0.217  299      1.06 0.260   48      0.89 0.320   45      0.52 0.262  218
         200      0.68 0.203   78      0.52 0.187  -62      0.36 0.172 1796      0.55 0.230   97
         300      0.55 0.173  131      0.63 0.209   86      0.28 0.098  642      0.80 0.215   96

  Last rows: w 1 at 436 - 0.59 s; w 3 at 392 - 0.31 s, exploitation 468; w 10 at 392 - 0.69 s, the best of any arm.
  Not a dose curve: the collapse at 3 sits between two working prices, so one seed cannot tell a dose effect from a
  run that took one bad excursion (bad data, then both models learning from it). Next: seeds 2 and 3 for each price.
  Chart `src/notes/bench/i1b_prices_seed1.png`. Also this turn: `zbuild` says why a build could not start
  ("could not start `zig build`: FileNotFound - is `zig` on PATH?") instead of a bare error name.
- **Sep 28 — I1b, seed 2 (3-minute arms: the baseline and w 1, 3, 10). The seed matters more than the price.**
  MTTF / reward / exploitation:

      iteration   baseline             w 1                  w 3                  w 10
         100      1.24 0.328    8      1.08 0.359   15      1.22 0.322   15      1.30 0.357   13
         200      1.16 0.292    7      1.00 0.357    4      1.20 0.362    7      0.97 0.284   38
         300      0.84 0.238   17      1.15 0.229   14      1.19 0.357    2      0.83 0.251   56
      last look  0.41 at 634          0.38 at 360          1.37 at 355          0.89 at 350

  Mean MTTF over looks 100-300 - seed 1: base 0.62, w1 0.74, w3 0.51, w10 0.62; seed 2: base 1.08, w1 1.08, w3 1.20,
  w10 1.03; the two seeds' mean: 0.85 / 0.91 / 0.86 / 0.83. The same configuration moves 0.46 s between seeds, the
  prices move the mean 0.06 s at most, and each price wins one seed and loses or ties the other - w 3 collapsed on
  seed 1 and is seed 2's best arm. Exploitation fell in 4 of 6 seed-price pairs, a hint in the twin's direction and
  no more. What both seeds share: MTTF drifts DOWN in every arm as training goes on (seed 2's baseline 1.24 -> 0.41
  by iteration 634). Chart `src/notes/bench/i1b_two_seeds.png`; CSVs `i1b_seed2_w*_3min.csv`. Plan: seed 3, and B3 -
  a bench that can resolve 0.1 s (a run's summary, seeds per arm, the judge's own noise).
- **Sep 28 — Simon: "avoid getting stuck with benchmarks; continue with the fundamentals".** B3 deferred. Surveyed
  what exists for the SAC half of the mixes: `robot_gym.SacAgent` (S1, on the gym's humanoid and cartpole), zimrnum's
  DroQ/CrossQ primitives (never assembled - S3), PPO on the tracking task (`robot_ppo_track`), whose environment was
  woven into its trainer. So the foundation first: **`src/robot_track_env.zig`, `TrackEnv`** - the decision-level
  tracking environment every learner will step through (observe; `decide`: clamp, hold `decimation` steps, credit the
  reward up to the first end, classify the end, read a cut's terminal observation before the filter is forgotten).
  Known answer: twin fleets - one in a PPO trainer, one in a TrackEnv - driven by PPO's own draws for 48 decisions x
  4 characters with a 40-step cap and bootstrapped clip ends: observations, rewards, ends and every cut's bootstrap
  identical (exact f32). Negative control: the cap planted as a stop fails exactly that test. `EndKind` and
  `ClipEnd` are still PPO's; they move, and PPO's copy of the logic goes, next turn.
- **Sep 28 — PPO steps through `TrackEnv`; its own copy of the task's logic is gone.** The trainer holds `env:
  TrackEnv` (plus its outcomes and terminal buffers) where it held the fleet, subset, controller, views, scratch state,
  applied action and episode counters; `collectOne` is: observe and draw for every character, one `env.decide`, then
  PPO's bookkeeping from the outcomes - a cut's bootstrap valued from the env's terminal capture after the decision
  (nothing the value reads moves inside one). `EndKind` and `ClipEnd` live in the env; PPO re-exports them. Known
  answer - a fingerprint recorded BEFORE the change (two iterations, normalisation on, bootstrapped clip ends, a
  30-step cap: every learning array hashed, the weights after each update, the stats): after it, iteration 0
  identical in everything, iteration 1 identical in arrays, weights and every integer stat; the mean reward moved in
  its 7th digit (0.5777777 -> 0.5777775), as predicted before the edit - the batch's reward sum is now added per
  character instead of per step (a statistic nothing learns from). The trap the plan names bit exactly as it says:
  both pages read `s.trainer.fleet` to draw the characters (`check` does not compile pages) - updated, both smoked in
  release; one test read `trainer.fleet` too. PPO's test root: 509 pass, 75 skip.
- **Sep 28 — SAC on the dance (plan I3): `src/robot_sac_track.zig`, `SacTrack`.** `robot_gym.SacAgent` (S1's SAC)
  learning from `TrackEnv`'s decisions - one decision for the whole fleet per `step`: SAC draws (uniform in its
  warm-up), `TrackEnv.decide`, then each transition into the replay - the observation before, the action drawn, the
  credited reward; next = where the next decision starts, except a CUT, whose next is the terminal capture with done
  FALSE (SAC bootstraps from where it ended); done TRUE only on a STOP. Then `updates_per_decision` updates. Known
  answers: every replay row of 40 decisions x 4 characters held field by field against a twin `TrackEnv` driven by
  the actions the replay recorded (30-step cap -> cuts; a radian per unit of action in the uniform warm-up -> stops;
  both exercised); negative control - a cut stored as a termination fails exactly that test; a smoke - past a
  64-transition warm-up, updates run, the actor's weights move, the critic's loss is finite (both tests: 2 s). Raw
  DReCon observations for now - normalising a replay's rows is its own decision.
- **Sep 28 — studied roxie's TD4 (Simon: "we really want all ingredients available").** roxie (JAX, seven agents
  on MuJoCo) - TD4 = TD3's machinery (target actor, target smoothing, policy delay, deterministic tanh actor) with
  D4PG's categorical critics, twinned: the target distribution comes from the twin with the lower mean per sample,
  optionally blended with the other along quantile functions (a Wasserstein interpolation, reprojected - mixing
  densities would smear the support); categorical TD (C51 projection + cross-entropy); 5-step returns that stop at
  terminations and bootstrap at truncations; observations normalised at SAMPLE time from running sums (raw replay
  rows - the answer to SacTrack's open question); layer norm in actor and critics; global grad-norm clip 1; Gaussian
  exploration 0.4 -> 0.1. Headline: HumanoidWalk 989; in their grid the categorical critics lead on CPU physics, and
  TD4 collapsed on one task on GPU physics (Stand, 38). Our HAVE list is long (graph ops, Adam, polyak, clipGradNorm,
  ObsNormalizer, ReplayBuffer, twin critics, TrackEnv's stop/cut + terminal observation); the MISSING pieces are plan
  I5's T1-T8: n-step transitions, sample-time normalisation, the categorical projection, a soft cross-entropy graph
  primitive, the categorical twin critic with its quantile blend, the deterministic actor family, the assembled agent
  (cartpole, then TrackEnv), GPU parity.
- **Sep 28 — T1, first half: the replay's last column is the bootstrap DISCOUNT.** `SacAgent.remember(..., done)`
  keeps its interface and stores gamma * (1 - done) - the product the target used to form, in the same order;
  `rememberDiscounted` takes a discount directly (n-step rows); the target is reward + discount * soft on the CPU and
  in the kit's `sac_target` kernel (the host copies the column unchanged, so one kernel line moves the GPU with the
  CPU); the kit parity test's rows carry discounts (0 where they said done, 0.99 otherwise). Known answers: SAC on the
  walk clip, 40 decisions past a 64-transition warm-up, fingerprinted BEFORE the change and after - 25 updates, actor
  and both critics hashing identically (5d93ec50ee66cc6e); the kit's SAC update still SacAgent's, update for update;
  the row test now reads the discount column. Next: the n-step accumulator itself.
- **Sep 28 — T1 done: `TrackEnv.NStep`, and SAC on n-step rows.** Per environment, a ring of n pending decisions:
  the episode goes on and the ring is full - the oldest goes out, its return over n decisions, bootstrapping from the
  observation after the newest at gamma^n; a CUT - every pending decision goes out, returns to the end, the terminal
  observation, gamma^k for its own k; a STOP - all out at zero. So a window never crosses an episode's end and nothing
  is dropped at one. Returns summed newest-first (Horner), so at n = 1 the return is the reward with no arithmetic and
  the discount gamma itself. Known answers: planted rewards 1, 2, 4, 8, 16 at gamma 0.5 (every sum exact) - windows
  3 and 6, a cut emitting 12, 16, 16 at 1/8, 1/4, 1/2, a stop at zero, a first-decision cut at gamma; n = 1 against
  the one-step rows bit for bit; a cut's discount planted off by one fails both tests. `SacTrack.Options.n_step`:
  its row test passes unchanged at n = 1 through NStep, and SAC learns at n = 1 and 5. `robot_track_env.zig` joins
  the robot family's test root and gets its own `zn-robot_track_env` step; `robot_sac_track.zig` is compiled there.

- **Sep 28 — T2 done, and a review of everything since TrackEnv (Simon: "simplify, hunt for bugs, improve
  comments, more descriptive names"; in small turns after one response failed to generate).** T2 - built by the
  interrupted turn and found intact: `SacOptions.normalize_observations`, training actions feed an f64
  `ObsNormalizer`, `sampleBatch` normalises each batch's copy, the replay stays raw. The review, file by file:
  `robot_track_env.zig` (NStep's names - oldest/pending, next_obs/terminal_obs, completed, windowFrom, gammaPower -
  and why n-step helps; `push` now asserts room for n; `heldSteps()` the one definition of a decision's length; two
  subtleties written down - an early end lets the old decision drive the fresh episode for the rest of the hold, and
  `failures` counts every held step), `robot_sac_track.zig` (`done` was a COUNT - now `completed_count`; header
  rewritten for discount rows and the normaliser), `SacAgent` (act documented; `feedNormalizer` / `normalized` /
  `widen`; `updateWith`'s doc said done), PPO (`taskOptions`, `batch_row`, the lockstep test renamed for what it tests
  now). Bugs: none in behaviour. A TEST gap: T2's test could not see storage-time normalising (it snapshotted after
  storing) - it now checks rows are the raw inputs, and the planted bug fails it.
- **Sep 28 — Simon: fold titles showed "\\25b8\\00a0 name \\2014 source".** `tools/docfmt.zig`'s stylesheet is a Zig
  MULTILINE string literal, which escapes nothing - and its three fold rules were written with doubled backslashes
  (right for an ordinary "..." string, wrong here), so the CSS reached every styled page as an escaped backslash and the
  browser printed the code. Fixed to single backslashes; a new `docfmt` test in `tools-test` (so in `check`) forbids
  a doubled backslash anywhere in the stylesheet - written first, it failed on the broken CSS.
- **Sep 28 — T3 done: `zimrnum.categoricalProject`.** C51's projection on an evenly spaced support: every atom of the
  next state's distribution moved to reward + discount * z, clamped to the support, its mass split between its two
  nearest atoms by closeness - which keeps the mean (so Q still obeys Bellman) and always the mass. Known answers on
  five atoms one apart (exact shares): a point mass stays, a quarter-way atom splits 3/4 - 1/4, beyond the ends it
  clamps, discount 0 collapses onto the reward, mass and mean kept, bad shapes refused. Negative control: the
  textbook floor/ceil neighbours (an exact landing loses its mass) fail exactly the point-mass and clamping tests.
- **Sep 28 — T4 done: soft cross-entropy, as row functions and as a graph operation.** The categorical critic's loss
  (-sum target_j log softmax_j, in log space; gradient predicted - target over rows). Row known answers: one-hot
  targets give the hard-label loss and gradient exactly; at prediction = target the gradient is zero and the loss the
  target's entropy; central differences agree. Graph: `softCrossEntropy(logits, targets)` wired like `mseLoss` - the
  target is data (TD4's comes from frozen target networks); `checkGradient` passes alone, through a layer, under a
  scale, and after the target is refilled. Negative controls: the gradient without its /rows fails the row tests; the
  backward ignoring the incoming gradient fails exactly the composition test.
- **Sep 28 — Plan section 10, "Recent advancements", opened with R1: EfficientTDMPC** (Evers et al., arXiv
  2605.16692v4 - Simon: "add to the plan everything necessary to be able to reproduce this"). BMPC's base written out
  component by component (the paper's Table 1-2; details it only references to TD-MPC2 / BMPC tagged "base, verify"
  against github.com/wertyuilife2/bmpc), the four changes with their equations (per-step insertion + horizon 6 +
  1/8 reanalyze; the multi-horizon mean; four dynamics heads trained value-equivalently with TS-infinity and the
  variance of the mean; beta sigma pessimism in reanalyze on early-terminating tasks), the protocol, twelve missing
  pieces in build order each with a known answer, the open questions, and how it carries to the dance. Two links to
  our own work: T3's projection of a point mass IS TD-MPC2's two-hot target, and their Appendix C.1 (a single-head
  planner promises more than the simulator delivers; the ensemble mean less, and delivers more) is I1b's exploitation
  finding measured their way.
- **Sep 28 — BMPC's code read (`bmpc-main`), and the design that makes the TD-MPC class native to zimrnum.** Plan R1.1
  now states BMPC exactly as its code does it - every "base, verify" tag replaced - with the paper-vs-code
  differences listed: the KL runs policy-first (the paper writes the reverse); the policy target is a DRAWN elite's
  first action with the final std, not the planner's mean; reanalyze's policy trajectories use the exploration std;
  iterations +2 at >= 20 action dimensions; the policy trains on detached ROLLED-OUT latents; the value target rolls
  the policy through the model with MODEL rewards; the KL is divided by a percentile running scale; loss weights
  20 / 0.1 / 0.1. The design (R1.5): a network = its parameters + ONE builder bound into any graph (`constant()`
  wraps the caller's tensor, so a frozen binding reads the live weights - BMPC's live / detached / target trio is
  three bindings of two tensor sets); planning = `recompute` of a graph built by the SAME rollout builder as training
  (one definition of the model's arithmetic for learning and search); an ensemble = an array of members, not a new
  rank; a small vocabulary (linear, normedLinear, mlp) plus three new ops (simNorm, gaussianKL, CategoricalScalar);
  SliceReplay, Mppi, RunningScale around them. Build order N1-N9, each with its known answer.
- **Sep 28 — BMPC-jax read (`bmpc-jax-main`): its speed is structural, and two of its tricks simplify our design.**
  Faster by: one planner call for every environment (any leading batch shape - acting and reanalyze share it);
  reanalyze and the policy reusing the update's own encodings and rollouts; one encoder pass (targets cut by a
  stop-gradient); all planner noise drawn once; a per-environment ring of whole transition rows with O(1) window
  sampling and `finished` masks instead of episode-bounded windows; per-step insertion; an update-to-data knob.
  Behaves differently by: a CONTINUE head for terminations (hard in planning, soft in targets - TrackEnv's falls
  need it); the policy distilled toward the planner's MEAN (std x 1.5, floor 0.1); rho normalised to sum 1; 5 value
  heads. Into the design (plan R1.5): a `detach` op (the single encoder pass), `SequenceReplay` replacing
  `SliceReplay`, the planning graph's rows = states x samples (every character in one recompute), and "nothing
  computed twice"; the behaviour differences become N6 options, each a bench question.
- **Sep 28 — N1 done: `zimrnum.Params(T)`.** A network's tensors as one set: `bind(graph, .trained)` enters them as
  parameters (an `Optimizer` on the returned values steps them in place), `bind(graph, .frozen)` as constants - the
  SAME tensors, since `Graph.constant` wraps without copying - and a target is a `clone` moved by `follow` (polyak
  per tensor, exact at 0 and 1). BMPC's live / detached / target trio is two sets and a choice at `bind`; the
  encoder's 0.3x rate is its own `Optimizer`. Known answers: an SGD step in the training graph is seen by a frozen
  binding in another graph at its next recompute, unrebuilt; no gradient reaches a frozen binding (`gradOf` refuses,
  its tensors are bit-identical after a step) while the trained one passes `checkGradient`; a target at 0 stays, at
  1/2 lands halfway, at 1 is the live set bit for bit, and a clone is a copy. Negative control: a frozen binding
  that copies its tensors fails exactly the live-read test.
- **Sep 28 — N2 begins: `Graph.detach`, the stop-gradient.** The value is a copy of its input's (through `scale` by
  exactly 1 - correct for any view), refreshed by `recompute`; `backward` stops there; `gradientOf` gets an explicit,
  exact case (a stop-gradient contributes nothing) rather than its unsupported-op error. What it enables: BMPC-jax's
  single encoder pass, targets cut from it. Known answers (finite differences cannot check a stop-gradient on its own
  input - perturbing x does move detach(x) - so they are exact statements): the value equals the input, the input's
  gradient through it is exactly zero while the other path passes `checkGradient`; with two paths, one detached, the
  input's gradient is the undetached path's alone, bit for bit; recompute refreshes the copy. Negative control: a
  detach that lets the gradient through fails exactly the zero-gradient and two-path tests.
- **Sep 28 — N2: `simNorm`.** Plain `simNormRows` / `simNormRowsGrad` (each group's max subtracted; the gradient a
  softmax Jacobian applied group by group) and `Graph.simNorm(x, group)`, the group size in the node's geometry.
  Known answers: every group of two rows x two groups of four is a probability vector; one group spanning the row
  equals `softmaxRows` and `softmaxBackward`; adding 100 to one group's inputs changes no output (groups are separate
  softmaxes); widths that are not whole groups are refused; `checkGradient` through a layer into SimNorm. Negative
  control: the gradient's weighted sum taken over the whole ROW (softmax's rule) passes the one-group test - where
  the two coincide - and fails exactly `checkGradient`.
- **Sep 28 — Review (Simon: "verbose names, intermediate locals, comments equivalent to reading the papers, perfect
  and beautiful"), part 1: `Params` and `detach`.** `Params`: its doc now explains the design in full - a network's
  numbers kept apart from its arithmetic, the three roles one network plays in the TD-MPC family (trained, frozen,
  target), why target networks exist (DQN's self-chasing target, DDPG's Polyak form, what tau = 0.01 means). A real
  defect found and fixed: `init` and `clone` leaked on a part-way allocation failure and there was no `deinit` -
  harmless only under an arena; now `deinit`, and cleanup on failure in `init`, `clone` and `bind`. Known answer:
  `std.testing.checkAllAllocationFailures` over a set's whole life - every allocation failing in turn, nothing
  leaked; removing `init`'s cleanup fails it with the 384-byte leak named. `detach`: its doc now carries the
  argument from self-predictive learning (TD-MPC's consistency loss compares two outputs of ONE encoder; without a
  stop-gradient the cheapest fix is collapse - BYOL, SimSiam, SPR detach the target side for exactly this).
  The tests' short names (sgd, x, y, live, target...) made verbose; a regex rename briefly broke the optimizer's
  `.sgd` union tag and two comments - caught by reading the result before running it.
- **Sep 28 — Review, part 2: `simNorm` and the soft cross-entropy.** No arithmetic defect. `simNorm`: its doc now
  carries the paper (Lavoie et al., simplicial embeddings) and why the TD-MPC family ends its encoder and dynamics
  with it - a latent rolled through itself must stay bounded; 64 groups of 8 act as soft categorical choices; no
  temperature, unlike the original - and the gradient is DERIVED in the doc (the softmax Jacobian, applied group by
  group without forming it). Names: input / output / output_gradient / group_start / feature, named intermediates.
  A promise the doc made but no test checked - "out may be the input itself" - now has a known answer: in place is
  bit for bit the out-of-place result, forward and gradient. Soft cross-entropy: its doc now covers BOTH uses in the
  family (a distributional critic's projected target; regression as classification - DreamerV3 / TD-MPC2 / BMPC's
  reward and value heads over 101 two-hot bins in symlog space), why a scalar is predicted as a distribution (the
  gradient, predicted - target, is bounded whatever the reward's scale; squared error's grows with the error), and
  cross-entropy = KL + the target's entropy; the builder's values are named. Six and six tests pass; check green.
- **Sep 28 — N2: the Gaussian KL - found already here, generalised instead of duplicated.** Checking before writing
  `gaussianKL` turned up `Graph.klGaussianDiag`: KL(policy || reference) - BMPC's own direction - composed from tested
  ops, the reference passed as tensors (data). Its one gap: both log-stds had to be [1, D] (PPO's state-independent
  spread); BMPC's policy and planner targets carry one per ROW. Now either, for both sides; the shared case's
  arithmetic is untouched (its existing test passes unchanged). The doc now teaches the KL: what it measures, the
  closed form read as three pieces, why the direction is a design decision (mode-seeking vs mass-covering - KL(N(0,1)
  || N(0,4)) = 0.318 against 0.807 the other way), BMPC's code against its paper, sum vs BMPC's mean over dimensions,
  the exponentials' safe domain. New known answers: per-row spreads against the closed form with `checkGradient`
  through each row's spread; a shared spread bit-identical to the same spread repeated per row; the direction numbers.
  Negative control: the log term's sign flipped fails the three formula tests (the path-equivalence test rightly
  passes - both paths carry the same flip).
- **Sep 28 — R3 (turn 1 of 5): DR-EfficientTDMPC, a proposal, read critically and added to plan section 10.** An
  unreviewed proposal with no experiments, composing DR-SAC's KL-robust Bellman objective with R1 plus consistency
  distillation, BatchEnsemble/MIMO, an evidential value head and adaptive compute - read as a menu, not a recipe.
  The core idea fits us unusually well: with the family's DETERMINISTIC dynamics heads the nominal transition is N
  atoms, a KL ball can only reweight them, and the robust value is a soft minimum over heads - delta = 0 the mean
  (R1), delta >= log N the minimum (TD3); beta* a 1-D concave maximisation, so DR-SAC's dual NETWORK is unneeded; small
  delta ~ mean - sqrt(2 delta) std, which makes R1's beta sigma look like its expansion (to verify in turn 2). The rest
  triaged with reasons: consistency dynamics mislabelled and in conflict with R1's multi-horizon objective;
  BatchEnsemble saves parameters, not arithmetic, and weakens disagreement; evidential variance poorly calibrated as
  epistemic; theory assumes finite actions. What robustness needs that the plan lacks: a shifted-dynamics benchmark.
- **Sep 28 — R3 turn 2 of 5: DR-SAC's code read, and Simon's use for robustness.** DR-SAC (`DR-SAC-master`): the dual
  keeps its -beta delta term (the README drops it); the expectation runs over 200 next states SAMPLED from a
  generative model (VAE / diffusion / flow / score) - our deterministic ensemble gives its atoms directly, so none of
  that machinery is needed; the robust value is a drop-in in the TD target; beta* comes from a dual network or a
  per-sample search bounded to [1e-4, 1] - a hidden cap that keeps the value near the sample minimum for large
  returns; delta 0.1; offline. Its test suite (parameter-factor shifts, five observation noises, reward shifts,
  random forces / friction / observation-only "teleports") is the model for ours. Simon's idea - larger physics
  step, fewer solver iterations, fewer observation dimensions: messier transitions, which is what the KL ball
  absorbs - becomes the benchmark "train messy, run accurate" (plan R3.6): our knobs exist (`opt.timestep`,
  `opt.solver.max_iterations`; a larger step also softens contacts), hold the decision rate by lowering the
  decimation, check the servo stays stable first, measure the sim gap, domain randomisation as the baseline to
  beat, delta chosen by validation in the accurate physics, and P0 - profile first: cheap physics buys wall-clock
  only if physics is a large share of an iteration.
- **Sep 28 — R3 turn 3 of 5: the maths verified; turn 1's scope corrected.** A sandbox script (kept as
  `src/notes/bench/r3_kl_robust_check.py`) computes the KL-robust value two independent ways - the dual, and a generic
  constrained optimiser over reweightings that knows nothing of duality: equal to 1.7e-7 of the spread. Limits exact
  (delta -> 0 the mean, delta >= log N exactly the minimum); small delta ~ mean - sqrt(2 delta) std (ratio 0.9994 at
  1e-5); gradient = the tilted weights (3e-9); concave in beta - after a first check on a LOG-beta grid proved
  malformed (concavity in beta is not in log beta). Two findings: R1's beta = 10 lands BELOW the worst head in 100% of
  draws - it is a variance-averse ranking, not a KL-robust value; DR-SAC's beta <= 1 cap pulls the value next to the
  minimum. And a correction: deterministic heads carry MODEL uncertainty only - the messy world's transition spread
  (aliased observations) is averaged away inside each head, so R3.6 needs probabilistic heads (noise before SimNorm),
  with the same aggregation over N x M sampled atoms. Theory: standard where it matters, vacuous where it bounds.
  Efficiency: BatchEnsemble saves memory, MIMO arithmetic (at the cost of independence).
- **Sep 28 — R3 turn 4 of 5: re-centred on OUR problem (Simon: partial observation over solver drift, no problems
  we do not have, distillation for rollout cost, speed and quality for diverse animations).** The key simplification:
  in simulation the full state is free at training time, so the partial observation lives only in the POLICY (what
  runs in the game) while the world model keeps the full state - asymmetric actor-critic carried into SuperTrack. The
  model stays deterministic and accurate; the policy's gradient through it averages over the states consistent with
  its view; and turn 3's probabilistic heads become unnecessary. Plan R3.8, in value order: V1 asymmetric observation
  (a differentiable feature selection between the model's state and the policy; full selection = today bit for bit);
  V2 diverse animations - one multi-clip policy trained directly, or per-clip teachers distilled into a reduced-
  observation student by DAgger, on a benchmark with held-out clips; V3 the KL-robust primitive aimed at the measured
  exploitation - a soft maximum of the policy's cost over K world models, delta from I1b's twin average to the worst
  member, the gradient a constant-weighted sum (envelope theorem, no new op); V4 distillation for rollout cost -
  planner into policy (no search at run time), a small student world model for training rollouts, a whole-window
  student for the kit; V5 speed measured first, and the runtime cost per character. Deprioritised: cheap physics,
  shifted dynamics, DR theory, probabilistic heads, BatchEnsemble / MIMO / evidential / adaptive compute.
- **Sep 28 — R3 turn 5 of 5: the consistency pass.** Section 6.0 is new: ONE order across the four tracks
  (SuperTrack's learner, R1's BMPC, TD4's critics, R3.8's value items) - measure the time (V5), asymmetric
  observation (V1), many clips (V2a), the robust ensemble (V3), the vocabulary both new agents share (N2's rest),
  then distillation (V2b, V4b), BMPC (N3-N8), TD4 and the mixes, the kit - with why: the working learner first,
  aimed at the goal; shared parts built once; new agents last, their value for our task still a hypothesis. Section
  3.9 records what Sep 28 added; R1.4's inventory and N2's text are current (N2 had been mangled by an earlier edit);
  I1b points at V3; section 9 names the new files; five over-long lines from earlier edits rewrapped. R3 complete.
- **Sep 28 — Back to the building blocks (Simon: "we don't need to measure things now ... have all the necessary
  ingredients ... building blocks, verifying they work ... native to zimrnum and nice to look at").** Plan 6.0
  reordered: blocks first, assemblies after, measurements when a decision needs one. N2 resumed where the new ideas
  came in: `symlog` / `symexp` (through zimrmath's accurate `log1p` / `expm1` - std.math is banned outside zimrmath)
  and `CategoricalScalar` (regression as classification: symlog or identity axis, `encode` / `decode` and their row
  forms, `check`). The two-hot's split was already `categoricalProject`'s, so it became ONE helper,
  `addPointMassToGrid`, used by both (the projection's six answers still pass). Known answers: symexp(symlog(x)) = x,
  odd, identity near zero; two neighbouring bins summing to 1, one-hot on a bin, clamped; encode = the projection of a
  point mass; decode(encode(x)) = x on and between bins, tiny and huge, both axes; rows = the single values. Negative
  control: the textbook floor/ceil split planted in the shared helper fails exactly four tests - two of each user.
- **Sep 28 — N2: the layers, first half - on zimrnum's own `Dense` template, not beside it.** Checking before
  writing found `Dense` (a layer owns its weight and bias; `attach` records it on any graph; deliberately no
  `Sequential` - "a struct holding two of these IS the composition") and `InitScheme`. So: `Dense.attachAs(graph,
  input, binding)` - `.frozen` enters the SAME tensors as constants, what planners and targets need (`attach` =
  `.trained`, unchanged for its callers); a `LayerNorm` layer on the same template (gain and bias; `mul` wants equal
  shapes, so the gain is spread by the graph's `copyToEveryRow`, now public); and TD-MPC2's initialiser read from
  BMPC's `init.py` - a "truncated" normal of std 0.02 whose +-2 bounds are ABSOLUTE, so it never truncates. Known
  answers: a frozen Dense computes bit-identical outputs and asks for no gradient; LayerNorm at gain 1 / bias 0 IS
  `layerNormRows`, and a planted gain / bias match the hand computation; `checkGradient` through gain, bias and the
  layer below. A lesson (L15) from the negative control: with the gain planted UNUSED, the plain `checkGradient`
  still passed - an unconnected parameter's two gradients are both zero and agree - so the test now also requires
  every checked parameter's gradient to be non-zero, and the planted bug fails both tests.
- **Sep 29 — N2 complete: the layers' second half, on `Dense`'s template.** `Activation` (a union: none / relu /
  mish / SimNorm with a group) and `Graph.activate`, one place that knows which op each is; `initNormal` and
  `InitScheme.small_normal` (TD-MPC2's std 0.02 - PyTorch's "truncated" bounds are absolute, never binding; both
  layers that switch on the scheme got the case; `Dense.init` now frees its weight if the bias fails); `NormedDense`
  (Dense, dropout only when an rng is handed in, LayerNorm, the activation - four tensors, `overTensors` for a copy
  over other storage); `Mlp` from a `Spec` (hidden NormedDense layers, a plain or normed last layer, `zero_last` for
  heads and refused for a normed last layer whose norm would undo it, dropout on the first hidden layer only, a
  derived rng per layer), with `attachAs` (every handle for an `Optimizer`), `params` / `withParams` (a target
  network in two lines) and `deinit`, cleanup on every failure path. Six known answers pass, among them
  `checkGradient` through three layers ending in SimNorm with every parameter connected (L15) and every output group
  a simplex, and `checkAllAllocationFailures` over a full life. Negative control: the last layer attached without its
  activation fails exactly the simplex test. Two locals named `norm` shadowed zimrnum's `norm` - renamed.
- **Sep 29 — N3, first half: bind once / apply many, and `LatentRollout`.** A rollout applies the dynamics H times,
  and `attachAs` bound a layer's tensors at every call - H bindings of one tensor would be H parameters to the graph,
  each holding a slice of the gradient, an optimiser on one missing the rest. So every layer now separates its
  binding from its arithmetic: `applyBound` (Dense, LayerNorm, NormedDense), `Mlp.bind` + `Mlp.apply`, `attachAs` =
  both, one `bindTensor` for the trained-or-frozen choice; every existing test passes unchanged. `LatentRollout`:
  the window's observations encoded in ONE pass (BMPC-jax) and sliced per step, targets detached, z_0 with gradient,
  the dynamics over one set of handles, the consistency loss rho^t / H. Four known answers pass (rolled latents =
  the step-by-step application bit for bit; the loss by hand; the dynamics by `checkGradient` and every parameter
  connected; the encoder's gradient against a graph with a FROZEN second encoder pass for the targets; batch = each
  character's rollout). A test written wrong first: `checkGradient` on the ENCODER - nudging its weights also moves
  the detached targets, the very dependence the stop-gradient removes - replaced by the no-leak comparison. Negative
  control: the rollout started from the detached z_0 fails exactly the encoder-gradient test.
- **Sep 29 — N3 complete: `WorldModelLoss`.** On the rollout: the reward head on each rolled latent with its action,
  every value head on each rolled latent (heads as an array of `Mlp`s with their own handles, dropout from an
  optional rng per head), both scored by `softCrossEntropy` against two-hot targets the builder allocates as
  constants and hands back as tensors (fill with `CategoricalScalar.encodeRows`, `recompute`), rho^t over the steps,
  the value term averaged over the heads as well, BMPC's total 20 c + 0.1 r + 0.1 v; the logits exposed. Known
  answers: the terms equal a hand computation that re-applies the heads to the ROLLED latents' values in a second
  graph (which is what catches heads reading the targets); refilled targets read at the next recompute and only
  then, the new value by hand; `checkGradient` through the reward head, both value heads and the dynamics, every
  parameter of every network connected. Negative control: value heads on the detached targets fail exactly the
  rolled-latents test. (Rng seeds are u32 - a u64 cast slipped in and the compiler caught it.)
- **Sep 29 — Review (3 turns, with the tutorial), turn 1: the layers, and the tutorial's ground.** `NormedDense`'s
  arithmetic now names its four handles and says what each step is for (the linear map; dropout, and why; the norm;
  the activation on a normalised signal); `overTensors` -> `withTensors` (matching `Mlp.withParams`); `Mlp`'s
  counters and flowing value named (`bound_parameters`, `bound_count`, `parameters_used`, `activations`,
  `tensors_used`, `gathered_count`). Every layer, rollout and loss test passes unchanged. The tutorial: zimrnum's
  own (chapters 16 / 17 / 18 / 18b / 18c already build an RL arc) gets a new chapter, 18d, after diffusion; its
  existing folds are hand copies (no data-src), so the new chapter's folds will be GENERATED - zimrnum-tutorial.html
  joined `doc_folds`' page list (it only touches blocks with data-src; the old ones are left alone).
- **Sep 29 — Review turn 2: the rollout and the loss; the tutorial's chapter 18d, first half.** `LatentRollout` and
  `WorldModelLoss` renamed through (`encoded_window`, `encoded_step`, `step_weight` for rho^t, `step_count`,
  `consistency_sum`, `reward_loss_sum`, `value_loss_sum`, `reward_share`, `heads_part`) with comments on WHY: the
  one-pass encoding's two copies of step 0 (one the encoder learns through, one it cannot), rho^t as trust in deeper
  predictions, BMPC's 20 / 0.1 / 0.1 (the latent space first). Tests unchanged (4, 3). zimrnum's tutorial gains
  "18d. World models: learning to imagine" - the introduction, 18d.1 (a network is its numbers plus its arithmetic:
  trained / frozen / target), 18d.2 (the layers: why a layer norm in every layer, SimNorm, bind once / apply many,
  `Mlp`, TD-MPC2's initialisation), 18d.3 (a number as a distribution: the bounded cross-entropy gradient, symlog,
  the two-hot, one split shared with the projection) - each with a short example checked against the real
  signatures and GENERATED folds (8: Params, Mlp, NormedDense, LayerNorm, Activation, CategoricalScalar, symlog,
  addPointMassToGrid), which `check` now verifies. The table of contents gains 18c (missing before) and 18d.
- **Sep 29 — Review turn 3: chapter 18d complete.** 18d.4 the latent rollout (the value-equivalent idea, the
  consistency loss, why its targets are detached and its start is not, rho^t, the step-by-step layout, the dynamics
  bound once), 18d.5 the world model's loss (why the heads read the ROLLED latents, the value heads as an ensemble
  with optional dropout, targets refilled per update, BMPC's weights), 18d.6 one update end to end (fill the window
  and the two-hots, recompute, backward, the optimisers, the targets follow; where value targets come from). Ten
  generated folds in all, verified by `check`. A final pass over the chapter checked every example call against its
  real signature and every stated number; one claim corrected - TD-MPC2 builds every network's HIDDEN layers from
  the normed layer (a head's last layer is a plain linear).
- **Sep 29 — N4, first half: `LatentPlanScorer` (Simon, standing: "update the tutorial as you go; the comments must
  stand on their own").** The planner's objective as a graph: each state encoded once, its latent copied to its
  candidates' rows by a constant 0/1 product (exact), the dynamics rolled over the actions the planner writes into
  constants, the reward head's probabilities per step and every value head's at the end; `score` recomputes and reads
  the bins back with `decodeRows`, summing r_t discounted by gamma^t and the heads' mean value by gamma^H. Built once
  from FROZEN bindings - planning reads the live weights and never trains them - for states x candidates rows
  (acting: a state per character; reanalyze: every replayed state). Known answers: each row's score = a hand
  computation in a separate graph that encodes the row's state alone and rolls its own actions (1e-12); one
  candidate's rewritten actions move only its score. Negative control: every row starting from state 0 fails exactly
  the hand computation. Tutorial: 18d.7 "Scoring plans by imagination", its fold generated.
- **Sep 29 — N4 complete: `Mppi`.** The caller drives the loop (no callbacks, no anytype): `begin` / `sample` /
  score / `refit` / `choose`, with `plan` for a `LatentPlanScorer`. zimrnum's counter-based `Rng` makes BMPC-jax's
  "draw all noise up front" unnecessary - the noise for (iteration, state, candidate, step, dimension) is a pure
  function of its index, and a plan is reproducible from its seed. Elites ranked by the existing `argsort`; the
  best elite weighs exactly 1 before normalising, so the weights never sum to zero; a non-finite score counts 0.
  The convergence test's tolerance came from a 200-seed simulation of the same rule (worst 0.016; tested at 0.06).
  Six known answers pass. The negative control taught something: inverted weights still CONVERGE (choosing the
  elites does most of the work) and are caught only by the exact refit - which is why the suite has both. Two names
  (`floor`, `outer`) shadowed zimrnum declarations; renamed. Tutorial 18d.8 "Searching for the best plan: MPPI".
- **Sep 29 — Aside (Simon): `std.mem.eql` -> bare `eql`.** `const eql = std.mem.eql;` beside zimrnum's other std
  aliases; all 54 uses replaced; nothing in the file was named `eql`, so nothing collided. While there: a duplicate
  alias I had added (`scalarIsFinite`, when `isFinite = zm.isFinite` already existed) removed. Running the WHOLE
  zimrnum suite (280 tests, 65 s) - a filter would only compile the tests it matches - exposed a failure that
  predates the refactor: the reference-table test, failing since `categoricalProject` because every public
  declaration from T3 on had no row, and my filtered runs and `check` never run that suite. Fixed at the source:
  52 notes added to `tools/zimrnum_ref.zig`, five shared-name notes (`init`, `deinit`, `sample`, `bind`, `apply`)
  rewritten to cover every type that uses them, the table regenerated (739 rows), a typo in the test fixed. 280/280
  pass. LESSON (L16): run the full zimrnum suite before closing any turn that adds a public declaration.
- **Sep 29 — The aliases, and a tutorial incident found and repaired.** Eleven more bare aliases in zimrnum
  (`testing_allocator` 228 uses, `ArenaAllocator` 115, `indexOf` / `indexOfPos` / `indexOfScalar` /
  `indexOfScalarPos` / `startsWith`, `sortSlice` + `ascending` - not `sort` / `asc`: zimrnum's `sort` is the
  tensor one - `readInt`, `writeInt`); collisions checked as whole words anywhere (only comments said
  "ascending"); 280/280. INCIDENT: zimrnum's tutorial folds are GENERATED by `zimrnum_ref` (from the `zn.` names
  each example uses; each run strips `<div class="zn-source">` .. `</div><!--/zn-source-->` and regenerates) - I
  had wrongly called them hand copies and given chapter 18d `doc_folds` blocks closed by a plain `</div>`. The
  previous turn's `zimrnum-ref` run stripped from 18d.1's block to the next generated close tag: 18d.2 - 18d.8 and
  the Recipes heading were deleted, and neither `check` nor the page build looks at prose - so the tutorial
  presented that turn was damaged. Repaired: restored from snapshot 62, my blocks removed, the examples now name
  what they show (`zn.Activation`, `zn.NormedDense`, `zn.LayerNorm`, `zn.symlog` added), the page taken off
  `doc_folds`' list (one generator per page). Verified by CONTENT: all sections present, 12 folds in 18d, a second
  generator run changes nothing, and the page's prose equals the good snapshot's but for the three intended edits.
- **Sep 29 - no-qualified-std, and the migration's first batch (not yet compiled, by agreement).** zimrlint: the
  zm alias machinery generalised (QualifiedMember, AliasFamily, fileScopeBinds, markCanonicalInits, bareUseFix;
  no-qualified-zm pinned first by three characterisation tests, unchanged after); `no-qualified-std` (opt-in,
  ADVISORY - the linter's first: printed, counted apart, never failing; 28-entry vocabulary counted from zimr's
  code - `ascending` / `descending` dropped as too rare, and zimrnum's `ascending` reverted to `std.sort.asc`);
  it opens pointer / optional / array types itself. Found: `childNodes` has no case for those types, so every
  rule is blind inside them - widening it exposed 20 hidden `prefer-vec` spellings (`[4]@Vector(4, f32)`) and 10
  `fn-args-multiline` reports on fn-pointer TYPES; reverted, a decision for Simon. 76 zimrlint tests, `check` OK.
  MIGRATION: `scripts/migrate_std_aliases.py` - sites from the linter (never text search), each verified to be
  exactly `std.<path>` at its column, replaced right to left, bindings into the header's std alias block; per
  file `zig fmt`, `zig ast-check`, and a per-rule lint comparison (no-qualified-std to zero, nothing else grows),
  else restored. Order: most-imported files first (488 files, ~6400 uses in all). Batch 1: zimrmath, shader_
  interface, codecs, command_line, robot, wgpu, mjcf - 378 uses, all verified. zimr.zig RESTORED by the net:
  its std import is at line 955, after its uses, so new bindings there grow decl-order ("used before its
  declaration") - moving its std import to the top is Simon's call.
- **Sep 29 - The std-alias migration, batches 2 and 3, and the first compile.** Batch 2 (robot_mjcf,
  robot_dance, robot_track, zimrphysics, compute_host, gpu, text2d, gpu_iface, ui, raster, image; web.zig had
  nothing) 1388 uses; batch 3 (runtime, robot_physics, shader_introspect, robot_gym, robot_latent,
  shader_runtime_wgpu, shapes2d, wgpu_texture, spv2wgsl, robot_maximal, renderer_2d, entities, raster_shader,
  BindGroupCache) 439 uses - every file dry-run first (zero skips, insertion points reviewed), then applied and
  verified (fmt, ast-check, per-rule lint). Running total 2205 uses in 32 files. A first batch-2 run found no
  `zig` on PATH: every file failed its fmt step and was RESTORED byte-exact; the script now refuses to start
  without its tools. CORRECTION: `check` is the wgpu-migration audit plus lint and fmt - NOT a compile of src/;
  earlier "check passes" meant that. The compile proof: `test-fast` exceeds 5 minutes, so the per-module steps
  instead - zn-zimrmath, command_line, mjcf, robot, robot_physics, robot_mjcf, robot_dance, robot_track,
  robot_gym, robot_latent, robot_maximal: all pass (3698 tests). Not yet compiled: the graphics / web files
  (ui, raster, spv2wgsl, text2d, gpu, wgpu, runtime, ...) - `test` or `test-windows` next.
- **Sep 29 - Migration: batches 1-3 proven on the graphics side; batch 4.** `test-windows` is broken on its own
  (74 errors, all module wiring - `zm` and `build_options` missing from its test root; none names an alias) - a
  finding, not a proof. `test` (engine suites + tier-A example pages, which compile ui / raster / spv2wgsl /
  text2d / gpu / wgpu / runtime / ...): 431/431 steps, 2639 tests (95 skipped) - batches 1-3 compile everywhere.
  The script's insertion rule improved: when a header line itself gets a replacement (`const Writer =
  std.Io.Writer;` -> `Io.Writer`), new bindings go right after the std import, above their first use. Batch 4:
  14 files, 512 uses, verified (robot_geno 226, draw3d 121, sound 50, urdf 25, ...); 5 files had nothing; cli.zig
  RESTORED - like zimr.zig its std import is near the end (line ~1250), so bindings grow decl-order. Running
  total 2717 uses in 46 files; batch 4 not yet compiled.
- **Sep 29 - Simon: "yes to all".** (1) Late std imports moved to the top: zimr.zig (after its //! doc) and
  cli.zig (its five-line import block), matched by exact text; decl-order fell (6 -> 4, 5 -> 0); both then
  migrated (2 + 12 uses). (2) zimrlint's `childNodes` widened: pointer, optional and array types are opened for
  every rule (no-qualified-std's own descent removed - the walker does it now; 76/76 zimrlint tests). The 29
  findings it exposed fixed by `fix_exposed.py` (verify-at-position, restore-on-failure, the targeted rule must
  fall by exactly the fixes): 19 prefer-vec (`[4]@Vector(4, f32)` -> `[4]Vec` in shader IO structs and
  examples, `?@Vector(2, f32)` -> `?Vec2`; `zm` / `Vec` bindings added where missing - 85 of 97 IO files already
  imported zm), 10 fn-args-multiline on fn-pointer TYPES (a trailing comma, then one parameter per line). The
  robot-mocap and zimrnum tutorials' generated folds regenerated (both verified by content: all sections, zero
  prose lines changed). `check` OK. Still to do from "yes": test-windows' module wiring.
- **Sep 30 - A failed response, cleaned up; test-windows fixed.** The previous response died mid-turn, leaving
  a half-finished build.zig restructuring (~70 lines of the host-test wiring removed) and a background loop
  still running `zig build test` against it. Restored build.zig from snapshot 68 (byte-identical; whole tree
  matched the snapshot), stopped the loop (a `pgrep -f` that matched its own command line was a false alarm).
  Then the fix, small: `test-windows` compiles the same root as the host tests (src/tests.zig) but got ONE
  import where the host module gets ~80 lines (engine shader embeds, per-shader externs modules,
  shader_interface, zm, zn, a SPIR-V fixture, build_options). The block moved verbatim into
  `wireHostTestImports(b, test_mod, target, wiring)` - one definition, both steps call it (the externs modules
  take the caller's target; zm / zn / shader_interface / shader_builtins are target-free). `test-windows`:
  306/306 steps, both Windows binaries compile. The host `test` still to re-prove (step 3).
- **Sep 30 - Compile proof for everything since the last one.** `zig build test` (engine suites + tier-A
  examples; two runs, the second resuming from the first's cache): 431/431 steps - batch 4, the moved std
  imports (zimr.zig, cli.zig), the shader IO `Vec` fixes, the fn-pointer types and the shared host-test wiring
  all compile and pass. (The second run's 2027/2033 counts only what it re-ran; cached steps are ones that
  passed.) Still to prove: the per-module steps for batch 4's robot files, then batches 5 and 6.
- **Sep 30 - Batch 4's per-module steps.** zn-robot_policy (438 pass, 29 skip), zn-robot_track_env (2),
  zn-robot_scene (133), zn-urdf (173, 4 skip), zn-cli (cached - already passed inside `test`),
  zn-robot_supertrack (compiles; its 2 tests are the gated slow ones, both skipped), zn-robot_geno (476, 68
  skip): all 5/5 steps. With `test` (431/431), everything migrated so far - 2731 uses in 48 files - is compiled
  and tested. Next: batches 5 and 6.
- **Sep 30 - Migration batches 5 and 6.** Batch 5: 16 files, 339 uses (robot_control 71, robot_latent_kit_tests
  68, robot_ppo_track_tests 57, zimrphysics2d 53, robot_mpc 29, robot_mocap_tutorial 25, ...). Batch 6: 20 files,
  186 uses (robot_world, gpu_learn_tests, docfmt, wgsl_reflect, the src/tests/* suites, three GPU-kernel example
  files, ...). All dry-run first (zero skips, insertion points reviewed), applied, verified (fmt, ast-check,
  per-rule lint). The work list's bookkeeping had fused two paths (an append onto a file with no trailing
  newline) - both files already migrated; repaired. The robot-mocap tutorial's folds (14) regenerated: 124
  sections, zero prose lines changed; the page build compiled the migrated docfmt.zig. Running total 3256 uses in
  84 files; batches 5 and 6 not yet compiled.
- **Sep 30 - Batches 5 and 6 proven.** `test`: 431/431 steps, 2639/2734 tests (95 skipped) - the second run
  re-ran every test. Per-module, all 5/5: zn-robot_world (compiles; 2 gated tests skipped), robot_urdf 305,
  kit_mlp 57, robot_control 416, robot_mocap_tutorial 434, robot_track_resident_tests 502, gpu_learn_tests 458,
  robot_latent_kit_tests 499, robot_ppo_track_tests 514, robot_mpc 389 (skips as usual). Everything migrated -
  3256 uses in 84 files - compiled and tested. Next: batches 7 onward (~420 files, nearly all small).
- **Sep 30 - The migration's last pass, and a second failed response cleaned up.** Simon: "do it all carefully,
  test only once at the end". The response died mid-way, but its migration run had completed: 394 files, 161
  migrated and verified, 230 with nothing to change, 3 restored - and it was mid-way through its final tests,
  which were stopped. Checked rather than trusted: (1) the 3 "restored" files were NOT the originals - the turn had
  hand-edited them and a second pass backed up the edited versions; put back to the snapshot, then deliberate
  pre-fixes, each verified to change no lint count: wgpu_smoke_test.zig had a PRE-EXISTING ast-check error (a
  discard of a parameter it uses - no build step compiles that file); doc_folds.zig and lafan_db.zig bound `Io`
  after the aliases that would use it (one line moved up); then migrated by the script. (2) Every other changed
  file PROVEN to be the migration's transformation, line by line against the snapshot (every added line a
  vocabulary binding, every changed line a pure substitution): 160 exactly, and net_mesh_test.zig with `zig fmt`'s
  own `@intFromEnum` -> `@backingInt` canonicalisation (first misread as a hand edit - the original is not
  fmt-clean in this toolchain). The std-alias migration is COMPLETE: 248 files. The final test run: next.
- **Sep 30 - The final test run.** After the repairs: zimrnum-ref, doc-folds, `check` (358/358), `test` (431/431),
  `test-windows` (306/306) - cache hits, which are proofs (Zig caches by exact input content, and caches test
  results only when they pass), doc-pages 30/30; both tutorials verified by content (124 and 192 sections, zero
  prose lines changed). NOT proven: `all-examples`. The previous run died silently because the sandbox's DISK
  QUOTA was full (~19 GB); freeing regenerable outputs gave 2.6 GB, but all-examples installs every example (314
  dirs + a 1 GB smoke set in 130 s) and a watchdog stopped it at 246 MB free - with no compile errors up to then.
  /dev/shm is RAM (3 GB total), so no room there either. To finish: all-examples on Simon's machine, or the
  migrated examples' own app steps in small groups, clearing outputs between groups.
- **Sep 30 - no-qualified-std graduated; decl-order measured.** The rule now fails the build like the others:
  advisory flag dropped (the doc says it started advisory and graduated), `no_qualified_std` added to build.zig's
  `LintRule` and `zimr_lint_rules`, messages no longer say "advisory". The advisory mechanism keeps its own test
  (`isAdvisoryIn` / `failingCountIn` on a small table) since no real rule is advisory now. The enforced rule
  immediately caught the test I had just written (qualified `std.heap.ArenaAllocator` in a file that binds it).
  76/76 zimrlint tests, `check` OK with the rule on across the tree. decl-order (lint_autofix.md: tier A2/A3, "move
  blocks"): 1158 violations in 152 files of zimr's own code (build.zig's "~1100" still right) - 111 files with 1-5,
  31 with 6-20, 10 with 21+ (zimrnum 114, robot 95, zimrphysics2d_demo/scenes 91, ui 51, zimrphysics2d 49, build.zig
  45, zimrmath 44, geno_dance 38, robot_geno 36, mjcf 29). Functions count; mutual recursion needs a per-site
  lint:off. Estimate given to Simon: about 10-14 turns (see the reply).
- **Sep 30 - decl-order, Phase 1 begun: the reorder core in zimrlint.** Found the existing toolkit and plan
  (tools/decl_deps.zig + tools/decl_reorder.py, src/notes/decl_order_plan.md, claude.md's history: ui.zig stays
  in FEATURE order by Simon's decision; the old tools break code). Built per the plan, in Zig (claude.md: no
  Python): `reorderDecls` - blocks from the syntax tree WITH the terminating `;`, plus the `///` / `//` lines
  directly above (a blank line stops the walk, so the //! header and banners stay); the HOIST strategy (each
  forward-referenced declaration to just above the declaration holding its earliest use, then its own
  dependencies in turn, using decl-order's exact notion of a forward reference); a file that has not settled
  after one move per declaration is a cycle and is refused; guards: same non-blank lines (a permutation),
  `compilesClean` (parse + AstGen), none left - or nothing is written. Five fixtures with exact outputs (simple
  hoist; doc comment travels, header and banner stay; multiline string with its `;`; a chain; a refused cycle and
  a byte-identical ordered file): 81/81. Negative control: the old tool's bug planted (the `;` left behind) fails
  exactly the multiline-string fixture. Next: `--reorder-decls [--dry-run]` on the command line, then the easy
  files. Also flagged to Simon: scripts/migrate_std_aliases.py is Python, against the tooling purge.
- **Sep 30 - `zimrlint --reorder-decls [--dry-run]`, and the first 44 files.** Wired as a mode (LintCli
  `--reorder-decls`, Args `reorder_decls`, `runReorderDecls`: per file "already in order" / "moved N
  declaration(s), M line(s)" / "refused - why"; writes unless --dry-run; exit 1 if any file refused). Dry run
  over the 67 files with 1-2 violations: 64 reorder cleanly (2023 lines in all - 44 files <= 30 lines, 16 at
  31-100, 4 above 100: sound 178, raster_shader 160, four_ways 122, zimrphysics2d_demo 105), 3 refused as cycles
  (examples/robot_demo/scenes.zig, tools/c2js.zig, tools/cheatsheet.zig - explained lint:offs, by hand). Applied
  the 44 mild files, each verified beyond the tool's own guards (fmt --check, ast-check, per-rule lint against a
  backup: decl-order 0, nothing grown): 44/44, none restored. Not yet compiled. Simon asked whether the std-alias
  script could be a zimrlint autofix: yes - the missing half (insert the binding when the name is free) fits
  the fix loop's passes and its AstGen rollback; planned next, then the Python script goes.
- **Sep 30 - The std-alias migration becomes a zimrlint autofix; the Python script is gone.** no-qualified-std
  now carries a fix on an UNBOUND use too: insert the vocabulary's binding line (built at compile time, so a fix
  owns no memory) at the start of the line after the header's last std alias - or right after the std import
  when a header line uses the name. That placement is decided per NAME, not per use: a first version decided it
  per use, a header use and a signature use of `std.Io` asked for two different spots, both landed, and the
  duplicate `const Io` sank the pass (the AstGen rollback caught it, and the test said so). `collectFixes` now
  keeps one of identical edits (several uses of one missing name each ask for the same insertion). One pass adds
  the binding, the next - now bound - rewrites every use. Three end-to-end fix-loop tests (binding then use; a
  header line gets its binding above it; three uses make one binding): 84/84. The linter then held its author to
  the house rules (an untyped comptime tuple, a 3-parameter signature, a qualified expectEqualStrings) - fixed;
  `check` OK. scripts/migrate_std_aliases.py deleted (claude.md: tooling is all Zig).
- **Sep 30 - decl-order: the 20 larger easy files.** Previewed first on scratch copies. A line diff misreports
  which side of a reorder moved (a lone `}` "moving", a test that never moves), so the preview compares the
  SEQUENCE of top-level declarations before and after: those outside their longest common subsequence are what
  moved. Every file: 1-2 small hoists - mostly `update` above the example's `pub const app = .{ .update = update
  ... }` spec (the spec now follows what it names), and helpers above their users (drawScene, statsTable,
  beginDrag, isIdentByte, createBuffer, ...). Applied and verified (fmt, ast-check, per-rule lint against a
  backup): 20/20, byte-identical to the reviewed previews. decl-order total so far: 64 of the 67 easy files
  clean; left: 3 cycles, the 31 medium files, the 10 large ones. Not yet compiled (batch 1 + 2).
- **Sep 30 - decl-order: the remaining files measured; a real bug found and fixed.** Simon: very hard files
  (ui.zig) may take a file-level `//! lint:off decl-order` at first (the mechanism exists:
  fileSuppressedByDirective). Dry-run of all 87 remaining files one at a time (a single run over all of them
  timed out: every hoist re-parses the file, minutes on 40k lines): ~62 move <= 500 lines; the hard ~16 are
  cycles (build.zig, bridge, serialize, robot_physics, profiler, spv2wgsl, robot_demo/scenes, c2js, cheatsheet),
  60-second timeouts (robot, zimrmath, wgpu_app), very large moves (robot_mjcf 2884, geno_dance 2529,
  zimrphysics2d_demo/scenes 1832, mjcf 898, urdf 780, humanoid 659), and ui.zig. THE BUG: robot_mjcf and
  geno_dance were refused "does not parse" - a throwaway debug build showed a `///` left behind (separated from
  its declaration by a blank line - Zig attaches doc comments across blank lines, the upward LINE walk stopped
  at the blank) landing above a moved-in `test` (test_doc_comment). Fixed from the syntax tree: a block starts
  at the doc_comment tokens right before its declaration. Also guarded: a field's user sends the declaration
  above the FIRST field (Zig rejects declarations between fields - checked). Two fixtures; 85/85. The 64 files
  already reordered were re-run from their originals with the fixed tool: all 64 identical - untouched by the bug.
- **Sep 30 - decl-order at ZERO across zimr's code (not yet compiled, not yet gated).** (1) 23 file-level
  exemptions, one explained `//! lint:off decl-order: <why>` header line each (Simon: very hard files take one
  at first): 9 reference cycles (build.zig, bridge, profiler, robot_physics, serialize, spv2wgsl,
  robot_demo/scenes, c2js, cheatsheet), 7 too slow for --reorder-decls to plan in 60 s (robot, wgpu_app,
  zimrmath, zimrnum, zimrphysics, zimrphysics2d, zimrlint), 6 very large moves (robot_mjcf 2884, geno_dance 2529,
  zimrphysics2d_demo/scenes 1832, mjcf 898, urdf 780, humanoid 659), and ui.zig (FEATURE order by decision) -
  669 of the 1158 violations; each verified (fmt, ast-check, decl-order 0, nothing grown). (2) The other 65
  files (each <= 500 lines moved) reordered with the fixed tool and verified: 65/65. Tree-wide
  `--decl-order-only`: 0. Its exit 1 came from one import-cycle report, cli.zig <-> cli/test.zig - PRE-EXISTING
  (already in snapshot 73), outside the build's lint scope; a finding for later. Next: compile everything
  reordered, then add `.decl_order` to zimr_lint_rules.
- **Sep 30 - Every lint rule opt-in; zimrmath passes decl-order for real.** (1) zimrlint: the `opt_in` flag gone -
  a rule runs only when `--enable` names it; `--enable` takes every rule; `--list-rules` marks advisory rules
  only; allRulesArgs enables all; the two-tier tests rewritten (catch-suppression reports nothing until enabled;
  canonical-alias's test helper now enables its rule). build.zig: `LintRule` lists all 53 rules (each commented
  with its title, generated from rule_notes), `zimr_lint_rules` 52 (all but decl_order - the same set as
  before); template/build.zig lists its 52 explicitly (its old set: the formerly always-on rules + its 10, still
  without no_qualified_std). The tree lints clean with the explicit list. (2) Disk full again: freeing it by
  deleting 62 cached test binaries BROKE the build - this dev Zig errors ("checking cache failed:
  FileNotFound") instead of missing, and zbuild's own advice (`rm -rf .zig-cache/tmp`) breaks configuration
  unless the dir is recreated. Removed the 61 manifests naming deleted outputs; three steps of `check` still fail
  on the same paths (references elsewhere, likely .zig-cache/z) - OPEN. (3) zimrmath (Simon: "before more tests,
  get zimrmath to pass decl order"): the reorder tool timed out because `tokenLocation(0, tok)` counts lines from
  the top every call - now a line-start table + binary search (>280 s -> 9 s). It then REFUSED: one real cycle,
  computeCosSin2 <-> Rot2 (found with tools/decl_deps + Tarjan). The tool now honours decl-order's own
  suppressions (a declaration whose earliest forward use is lint:off'd is not a forward reference - an
  explained cycle and a file-level exemption are left alone; fixture; 86/86; a 0- vs 1-based line bug caught by
  it). zimrmath: file-level exemption removed, the cycle's edge explained
  (`// lint:off decl-order: Rot2.fromAngle calls this - a cycle`), reordered (45 hoists, 558 of 11203 lines,
  ~40 of 687 declarations - helpers above their users), verified with ALL 53 rules (a first verification had
  enabled NONE: my helper looked for the "(opt-in" marker this very change removed): decl-order 0, nothing else.
- **Sep 30 - The build cache repaired; `check` green.** Why it stayed broken after removing the manifests that
  named deleted outputs: a COMPILE step's manifest does not record its output directory (the `o/` name is derived
  from the inputs), so the compile step reported a hit without checking its output existed, and the run step then
  failed opening `o/<digest>/test`. Removing the manifests that name the failing tests' roots (tools/serve,
  example_source, docfmt: 5 manifests) made them ordinary misses: tools-test 7/7 steps, 6/6 tests; `check` rc 0.
  The same repair applies to any other test step whose binary was deleted (sandbox cache only - the tree is
  fine). build.zig's low-disk advice corrected: `rm -rf .zig-cache/tmp && mkdir .zig-cache/tmp` (the build needs
  the dir), and a warning never to delete single entries under .zig-cache/o.
- **Sep 30 - The order treatment for more files: 10 exemptions removed.** Procedure per file (a driver in /tmp):
  a scratch copy without the file-level exemption; its declaration graph (tools/decl_deps) and Tarjan's
  strongly connected groups; every `--decl-order-only` report whose use AND used declaration sit in the same
  group gets an explained standalone directive above it (`// lint:off decl-order: X and Y reference each other -
  a cycle` - a comment line is valid anywhere and never lengthens code); then --reorder-decls, which honours those
  directives. Applied with a backup and verified with ALL 53 rules (fmt, ast-check, decl-order 0 without the
  exemption, nothing grown): robot_demo/scenes (1 edge, no move), bridge (5 edges, no move), spv2wgsl (50 lines),
  profiler (4 edges, 113), robot_physics (1 edge, 124), serialize (4 edges - encode/decode/free message<->field
  recursion - 170), wgpu_app (200), cheatsheet (1 edge, 74), c2js (47), zimrphysics (1 edge, 8): 10/10. Left
  exempt: build.zig (its cycle's forward edge is not among the reports - needs a look), zimrnum (the dry run did
  not finish in 10 min: one re-parse of 37k lines per hoist - batch hoists per pass next), zimrlint (not reached),
  ui.zig (feature order by decision), and seven that need no cycle directive but would move a lot: robot 5105
  lines, robot_mjcf 2884, geno_dance 2529, zimrphysics2d 2405, zimrphysics2d_demo/scenes 1832, mjcf 898, urdf 780,
  humanoid 659 - Simon's call.
- **Sep 30 - --reorder-decls hoists in batches.** One re-parse per pass instead of per hoist: `forwardReferences`
  returns every (unsuppressed) forward reference, earliest use first; each pass takes every hoist that disturbs
  no other (a block may not both move and receive, nor move twice - those wait for the next pass, exactly when
  one-at-a-time would have done them) and `hoistBlocks` applies them in one sweep, blocks bound for one target in
  earliest-use order. The cycle budget still counts single hoists. 87/87 (a new fixture: two blocks, one user, one
  pass). Re-run from the originals of the 64 earlier easy-file reorders: 64/64 byte-identical. zimrlint's dry run
  now takes 2 s (moves 1360 lines - big-move group), zimrnum's 83 s (was: unfinished after 10 min) - and REFUSED:
  its cycles (mod/rem/DivideWay/divideBy; bindTensor/Params), like build.zig's (App/AppContext), have a member
  whose earliest use is OUTSIDE the cycle, so hoisting pulls it away from its partners and the cycle chases
  itself. Next: the tool treats each strongly connected group as one unit (hoisted together, members in order)
  and lists the in-group forward edges that need an explained lint:off, instead of refusing.
- **Sep 30 - Cycles verified one by one (Simon: "keep one only if there is no other way; lint:off as a last
  resort").** Test per directive: remove it alone and ask --reorder-decls (the rule's own notion) to order the
  file. (1) bridge.zig: all 5 of the directives I had added were NOT needed - decl_deps (which placed them) counts
  enum field names as references; removed, the file reordered (5 moves). zimrphysics.zig:5426 (an OLDER directive,
  "World<->ContactListener hub") not needed either - removed with its now-false justification. (2) Fixed by
  DESIGN: zimrmath's computeCosSin2 <-> Rot2 - the algorithm's only caller was Rot2.fromAngle, which just
  forwarded; the body now IS Rot2.fromAngle (docs merged, Box2D citation kept; the local renamed folded_radians -
  `angle` would shadow Rot2.angle; one long line split without regrouping - the port's exact evaluation order is
  the point). zimrnum's bindTensor <-> Params - `Binding` lived inside the generic Params(T), a separate type per
  element type; now one file-scope `zn.Binding` (8 signatures), the nested copy gone. (3) A RULE false positive:
  `enum { floor, mod, rem }` parses bare names as tuple-like fields with identifier "types", so decl-order saw
  DivideWay's field names as uses of the functions mod and rem. `enumFieldNameNodes` (shared by the rule and the
  tool) skips them; a test both ways; 88/88. zimrnum now orders with NO directive (137 declarations, ~7.1k of 37k
  lines - big-move group, Simon's call). Tool: a scratch arena per pass (zimrnum's trees had exhausted memory:
  exit 137). zimrnum tutorial folds regenerated (192 sections, prose unchanged). 18 real cycles left for design
  review: profiler 4 (Zone <-> endZone/annotate*), serialize 4 (message <-> field recursion), bridge 4 older
  (toH<->tupleToH, Value<->g, g, Element<->Document), zimrphysics 3 (handleOf<->World, ShapeStore<->buildCompound,
  CharacterVirtual<->listener), robot_physics (Bridge<->onContact), robot_demo/scenes (ArmSpec<->Arm), cheatsheet
  (scopeOfExpr<->declOfExpr). Not yet compiled: zimrmath, zimrnum.
- **Sep 30 - zimrmath and zimrnum compiled; profiler's four cycles removed by design.** zn-zimrmath 171/171
  (Rot2.fromAngle now holds Box2D's algorithm), zn-zimrnum 280/280 (the file-scope `zn.Binding`). profiler: each
  public `Zone` method was an `inline` forwarder (gated on `enabled`, so a profiler-less build folds it to
  nothing) to a private free function taking the Zone - two spellings of one operation, and the four "cycles".
  The bodies are now Zone's own out-of-line private methods (recordEnd / recordText / recordValue /
  recordColor): same codegen (callers still pay one call, not a copy of the body), members of one struct may
  refer to each other in any order, and the four free functions and four lint:offs are gone. decl-order 0 with
  no move, nothing grown (53 rules); zn-robot 127/127 compiles recordEnd with the profiler on (the other three
  are compiled by `test`, run after the review). 14 real cycles left: serialize 4, bridge 4 (older), zimrphysics
  3, robot_physics, robot_demo/scenes, cheatsheet.
- **Sep 30 - serialize's cycles: one removed by design, three kept as the format's own recursion.** freeDecoded <->
  freeFieldValue was one idea written twice: freeFieldValue already freed any decoded type, its struct case
  handing back to freeDecoded, which looped the fields handing back to it. Now ONE self-recursive `freeDecoded`
  (any decoded type; a struct's fields freed by the same call) - the public signature unchanged, freeFieldValue
  gone. The other three (size, encode, decode: message <-> field) are the protobuf grammar itself - a message is
  its fields, a field may hold a message, and only the field level has a tag - so a single function would need a
  message-or-field parameter; kept, each directive now saying so (`a field may hold a message - the format
  recurses`). `zig test src/serialize.zig` 8/8; in order; nothing grown (53 rules). 10 real cycles left: bridge 4
  (older), zimrphysics 3, robot_physics, robot_demo/scenes, cheatsheet.
- **Sep 30 - bridge.zig's page singleton examined: one link cut, the real cycle mapped.** `Value` (the base JS-handle
  wrapper) used exactly one thing from `g`: `g.scratch.call_args`, a 16-handle buffer for marshalling one call's
  arguments to JS. Now a local `[n]Handle` in that method (n is comptime) - JS reads it during the synchronous
  call, and a call that re-enters Zig and calls again gets its own buffer instead of overwriting a shared one;
  the field and its doc bullet are gone. Value no longer touches g. But the tool still refuses without directives:
  a 32-declaration strongly connected group - `BridgeGlobals` (g's type) EMBEDS state types living inside
  behaviour namespaces (ZimrBoot.EvRec, css.Sheet, UserFile, ...) whose code uses g; and Value <-> toH/objToH
  (Value's methods marshal through them, they build Values). The two directives are back with the TRUE reasons.
  The clean design (Simon's call - a real refactor of a 7k-line file): g's type holds data records only, declared
  early, behaviour namespaces after g. `check` OK (compiles bridge); decl-order 0; nothing grown (53 rules).
- **Sep 30 - Three more cycles: two dissolved by design, one kept with its reason.** robot_demo/scenes: `ArmSpec`
  (the arm's model, built from Arm.upper / Arm.lower) lived outside `Arm`, which built its specs from it - a
  type's own construction outside the type. Now `Arm.modelSpec(actuated)`, beside the dimensions it uses; no
  directive. robot_physics: `onContact` cast its context to *Bridge, called self.robotBodyOf, read
  Bridge.not_a_robot_body, and only Bridge.listen used it - Bridge's callback in all but location. Moved into
  Bridge (a private fn with the same callback signature), with `default_friction`, which only it used; no
  directive. cheatsheet: scopeOfExpr <-> declOfExpr is name resolution itself (`a.b` is looked up in the scope `a`
  opens onto, and `a` is a name) - KEPT, the directive now says so. Verified (53 rules: decl-order 0, nothing
  grown); zn-robot_physics 401 pass (7 skipped); `zig build robot-demo cheatsheet` 321/321. Left: zimrphysics 3,
  and bridge's big group (Simon's call on the refactor).
- **Sep 30 - zimrphysics' cycles, by Simon's rule ("don't make the code more complicated to satisfy the rule -
  unless it becomes better, simpler, flatter, more linear, just lint off").** handleOf: a one-line accessor over
  World's own bodies table, called 9 times as `handleOf(world, idx)` - now World's private method,
  `world.handleOf(idx)`, same signature and body (World's methods name their receiver `world`). That exposed
  the REAL cycle handleOf's directive had been masking: World is the hub - its methods call dozens of feature
  functions defined before it, which take *World - so the castRayVehicleFloor directive I removed earlier (on a
  necessity test skewed by that mask) is back, with the true reason. buildCompound (public geometry: volume, COM,
  inertia; reads the store) and CharacterVirtual <-> its listener (callbacks receiving their owner): KEPT, the
  latter's directive now saying why. 53 rules: decl-order 0, nothing grown. `test` hit the sandbox's stale cache
  again (two test-fast roots): removed the manifests naming the 19 test-fast roots not rebuilt this session;
  the compile proof for zimrphysics is next.
- **Sep 30 - requireGraphicsSink: the shape of `sink` at the front door.** Simon: a function taking anytype should
  make its argument's expected shape trivial to know - a `require` first line, even one that is mostly a pointer
  to examples; where that gets hard (the Zig team's warnings), do nothing. Survey: 614 anytype parameters in 48
  files - interfaces (`gl` 138, `sink` 30), numeric shapes (~110 in zimrmath), tuples, callables. The precedent,
  renderer_trait's `assertIsGlContext`, is only called from WgpuGl's self-checks and its list has DRIFTED (11
  methods the 2D code calls are missing, 7 listed ones unused there: `gl` is two surfaces under one name) - the
  risk made concrete. The plot sink is the clean case: one consumer (plot.zig), two real implementations
  (SvgSink, plot_ui.DrawListSink), a contract of six methods (line, text, fillRect, triangleFilled, circleFilled,
  texturedQuad - pushClip / popClip are DrawListSink's own). `pub fn requireGraphicsSink(sink: anytype)`: its doc
  lists the six signatures and names the two sinks to copy; its body checks the names with @hasDecl through a
  pointer. First line of all 27 public sink-taking functions. Tests: SvgSink passes (plot.zig, compiled directly:
  1/1); DrawListSink's test sits in plot_ui.zig (runs with `test`). Negative control: a sink without texturedQuad
  fails at compile time with `plot: a graphics sink needs `texturedQuad`, and ...HalfSink has none (see
  requireGraphicsSink)`, traced to the caller. Lint clean (53 rules). The deferred `test` run is next.
- **Sep 30 - `test` green: 431/431 steps.** The compile proof for the cycle review and requireGraphicsSink
  (zimrphysics, profiler, robot_physics, serialize, zimrmath, zimrnum, bridge's call_args, plot + DrawListSink's
  test). Four resuming attempts (the repaired roots recompiled); the last ran 2029/2035 (6 skipped), the rest
  cached passes. It found one real thing on the way: a test-only capture sink (`Cap`, in "plotImage maps data
  bounds to a pixel rect") implemented just texturedQuad - all plotImage calls - and the six-method contract
  refused it. Kept ONE contract (a single shape to know; per-function method lists would be 27 lists to keep in
  step with their bodies - the drift problem): Cap got the five other methods as documented no-ops. plot.zig's own
  57 tests pass directly. Disk watched across attempts (freed ~160 MB of old temporary linter builds).
- **Sep 30 - The big-move files, judged by LOCALITY (Simon: without breaking anything or hurting locality and
  understandability).** "Lines moved" sums block sizes, so it says nothing about locality; measured instead, per
  moved declaration, how far it travels and whether it leaves its banner-delimited section (/tmp/big/locality.py:
  the declaration sequence before/after, its longest common subsequence, banners). Applied (no declaration leaves
  its section): humanoid (an example, one section - helpers above their callers) and urdf (hullPoints,
  resolveMeshes, applyTensor, rotateInertia, quatFromRpy now sit together right above `Reader`, the XML reader
  that uses them; requireIdentifier within the emitter section). Verified (53 rules) and `zig build zn-urdf
  humanoid` 319/319 (urdf 173 pass, 4 skipped). Measured: robot_mjcf 0 cross-section (candidate), zimrphysics2d 1
  of 49 (check it), geno_dance 16 (one banner - coarse; look), mjcf 16 (its sections are CHRONOLOGICAL - "The body
  tree - turn 7", "Actuators... - turn 8", Tests in the middle; hoisting would gather the data-model types above
  the model, arguably better, but the banners would need conceptual titles - a proposal for Simon),
  zimrphysics2d_demo/scenes 29 of 33 and robot 82 of 122 (keep exempt: a reorder would scatter feature-organized
  code; the exemption text should say so). zimrnum and zimrlint not measured yet.
- **Sep 30 - The organizing principle, and mjcf laid out by it.** Simon: organize so that reading linearly from
  the top builds understanding bottom-up and reading from the bottom gives it top-down - i.e. LAYERS: vocabulary
  at the top, entry points at the bottom, tests last; a section marks a layer, not a turn. mjcf (sections were
  chronological - "turn 7", "turn 8" - with Tests in the middle): laid out as (1) The model - what reading an MJCF
  file produces (Joint, Geom, Inertial, Body, Actuator, Site, Sensor, Equality, ..., Robot last), (2) Reading
  attributes - defaults and classes, units, numbers, orientations, (3) Reading elements - one reader per MJCF
  element, (4) Reading a robot - the entry point (readRobot), (5) Tests. A layout script (/tmp/big/layout.py)
  splits the file into top-level blocks (doc comments attached across blank lines), rebuilds it from an explicit
  section list, asserts every declaration placed exactly once and the lines unchanged but for the banners; the
  reorder tool then made 10 fix-ups, every one inside its layer except AngleUnit and Compiler moving into the
  model (Robot keeps the compiler settings it was read with - correct). Exemption removed; 53 rules: decl-order 0,
  nothing grown; zn-mjcf 180 pass (4 skipped).
- **Sep 30 - robot_mjcf and zimrphysics2d ordered.** robot_mjcf: `Imported` (the result type) rises above
  build / buildScene (the entry points) - type first, then use; tests stay interleaved near the code they
  check. zimrphysics2d is already layered (geometry -> collision queries -> bodies -> broad phase -> contacts ->
  solver -> joints -> islands -> events -> world); its big move is ONE cohesive cluster, the SIMD wide solver
  (simd_width, FloatW, Vec2W, WideConstraint, buildWideBlocks, warmStartWide, solveWide, applyRestitutionWide),
  rising intact above the step code that uses it. The tool's one cross-section move was wrong: it would have put
  `Shape` (defined in "World") into "Contacts" above its first user. Moved by hand to its real home, right after
  `Body` in "Bodies" (everything Shape names is declared before Body - no new forward reference); afterwards
  exactly one declaration changed section: Shape, World -> Bodies. Both verified (53 rules); zn-robot_mjcf 354
  pass (7 skipped); `zig build zimrphysics2d-demo` 315/315 (zimrphysics2d's own tests run with `test`, after the
  rest).
- **Sep 30 - geno_dance ordered: the layers fell out of the hoist.** No real sections (the "16 cross-section"
  count came from a separator that is not a section), and `update`, the frame entry point, sat in the middle.
  After the hoist the file reads in layers with every feature group intact: the data (Character, State) ->
  rendering resources (constants, uniform layouts, shaders) -> setup (makeCharacter, init*, deinit) -> posing
  (retarget map, robot twists and map, poseCharacter, poseRobot) -> drawing (passes, robot and skeleton views,
  drawScene, the UI panel tabs, drawPanel) -> update -> app (the app spec, last). Verified (53 rules);
  `zig build geno-dance` 315/315.
- **Sep 30 - robot.zig reorganized by layer, not scattered.** Already layered (spatial algebra -> the model spec ->
  Model -> Data -> the pipeline's phases -> stepping -> tests -> retargeting); the hoist would have scattered 82
  declarations across its 19 sections. Instead, each of the 20 declarations used above its section was given its
  true home: vocabulary up to its layer (Stage beside SensorKind; EqualitySpec, SolverOptions - what the user
  writes - into the spec; Equality, Anchor and its helpers into Model; ConstraintKind and Contact above Data;
  normalizeQuat and Pose into spatial algebra; siteIndex beside Model; tendonLengths into kinematics;
  constraintKey beside the rows), functions filed too early down to theirs (geomLowestPoint, bodyLowestPoints,
  lowestPoint, restOnFloor - they run on a BUILT model and step it - into a new section, "Placing a built robot"),
  and two whole sections into dependency order ("Spec() - the comptime layer" after Model; "Position coordinates"
  before Stepping). A mover (/tmp/big/mover.py: banners WITH their prose paragraphs move as one; non-blank lines
  asserted unchanged but for the new banner), then the tool's fix-ups - 85 inside their sections, 6 dependencies
  following their users. Against the original: 24 declarations in a different section, every one deliberate.
  Exemption removed; 53 rules: decl-order 0, nothing grown; zn-robot 127/127.
- **Sep 30 - The physics-2D demo's scenes: one registry moved, not 99 declarations.** Nearly every
  "used above its section" was one user: `list`, the table of every scene, sitting mid-file inside "Issues"; and
  the banner titled "Registry" headed scene functions, not the registry. Layered: spawn helpers at the top (now
  with makeRagdoll, a helper used by scenes in several sections), the scenes section by section, and a new last
  section "Registry - every scene, by category: the demo's menu" holding list, categories, categoryIndex,
  firstInCategory - read from the bottom, the menu first. The misleading banner now names what it holds ("Scenes
  - robustness, bodies, continuous, joints, shapes, benchmarks, showcase"). After those moves the file was ALREADY
  in order (the tool: nothing to do; the plain hoist had wanted 99 moves). Only the two banner titles changed;
  53 rules clean; `zig build zimrphysics2d-demo` 315/315.
- **Sep 30 - zimrnum, step 1 of its reorganization: its own layer order.** The header has always declared the
  rule ("TABLE OF CONTENTS (downward-only: a symbol may call its own layer or a LOWER one)"), and the sections
  are numbered layers - but were laid out L00 L01 L02 TESTS L03 L06 L07 L09 L08 L15 L16 L14 L13 L11a L11b L12
  L11 L10 GATE, and 104 references went UP a layer. Step 1 (a pure permutation): the 19 sections, each whole with
  its prose and its interleaved tests, in layer order (L00 .. L16, the TESTS helpers after L02, THE TUTORIAL GATE
  last), and the stride walkers (Walk, Walk2, advance - tensor iteration used from L03 up, filed under
  OPTIMISERS) moved into L03 TENSOR. Non-blank lines identical as a multiset; 53 rules clean; the exemption kept
  until step 2 makes the file pass for real. What the tool would still move across sections fell from 104
  upward references to 32 - step 2's worklist: statistics' users still in L06 (describe, medianAbsDev,
  coefficientOfVariation, ...), losses / activations outside L07 (softmaxRows, the simNorm family,
  ppoClipObjective, mseLoss), something in L08 using Graph (likely a test - it drags autograd and its backward
  kernels into statistics), Params toward the layers, ComplexNumber toward eig, and convolution -> L10a, below
  autograd, which calls its kernels.
- **Sep 30 - zimrnum, step 2: it keeps its own promise, with no exemption.** Each misfiled declaration to its true
  layer: L06 gets scale, dotAll, norm and the row kernels (gatherRows, scatterAddRows, fillRowMaxAndMask); L07 the
  activations and losses (Activation, softmaxRows, softmaxBackward, the simNorm family, fillDropoutMask, mseLoss,
  ppoClipObjective, ppoClipSample); L08 the statistics (describe, medianAbsDev, coefficientOfVariation,
  standardError, correlationMatrix, quantile, quantileSorted, median, DiagGaussian); L09 determinant,
  ComplexNumber, hessenberg, eig; L11 autograd how tensors enter a graph (Binding, bindTensor, Params,
  ownedTensor) and the two Graph.softCrossEntropy tests that sat in statistics (they had been dragging autograd
  and its kernels into L08). Convolution renumbered L10a and moved below autograd, which calls its kernels
  (conv2dBackward with it). One SIMPLIFICATION on the way: `layerNormBackward` was a leftover shim (it dropped
  `y` and forwarded to layerNormRowsBackward, after an earlier de-duplication) - deleted, its one call site now
  calls layerNormRowsBackward. Upward references: 104 -> 32 after step 1 -> 0 now; the tool's 97 remaining moves
  all stay inside their layer. Exemption removed; 53 rules: decl-order 0, nothing grown; zn-zimrnum 280/280,
  zn-rl-gpu (zimrnum's RL arithmetic for SPIR-V) 7/7 steps; the tutorial's reference regenerated in layer order
  (192 sections, prose unchanged, 888 rows).
- **Sep 30 - zimrlint ordered; the rewriting machinery gets its own section.** Only ONE declaration was used above
  its section: compilesClean (parse + AstGen), filed under "Per-file mtime cache", used by reorderDecls - which
  I had put beside the decl-order rule inside the walker section, though it is a DRIVER mode, like --fix. Now:
  a banner "Rewriting files - `--fix` and `--reorder-decls`." above compilesClean (the fix cluster: compilesClean,
  applyFixes, collectFixes, FixOutcome, runFixLoop), and the whole reorder block (DeclBlock ... joinLines, its
  own sub-header with it) right after runFixLoop, before main. The tool's remaining 23 moves are short and stay
  in their sections (the largest: the advisory helpers end up directly after the rule-notes table they read).
  Exemption removed; 53 rules: decl-order 0, nothing grown; zimrlint 88/88; `check` (the linter built from this
  source, linting the tree) OK - after one fix of my own: plot.zig's test sink's no-op triangleFilled had 5
  parameters on one line (fn-args-multiline); `test` does not lint, so it had slipped through.
- **Sep 30 - build.zig: `build` last.** The App <-> AppContext cycle is the callback shape (an app's `configure` hook
  receives the context; the context's buildAppModule takes the App) - breaking it (a free function after both)
  would not be simpler, so it KEEPS an explained directive on the hook field. The file's 45 reports had one
  cause: `pub fn build`, the entry point, sat at the TOP and called everything defined after it - the classic
  build.zig layout, the inverse of the layering. One move: `build` to the end (now lines 2887-7278); the pair then
  fell into place, and the tool made 11 small helper moves (ComputeKernel above the App that holds it,
  ShaderPipeline above AppContext, the wgpu app builders in calling order). File-level exemption removed; 53
  rules: decl-order 0, nothing grown; `check` OK (configures from this file). Disk at 940 MB.
- **Sep 30 - decl_order ON: zimr's build enforces it.** `.decl_order` added to `zimr_lint_rules` (in LintRule order;
  its doc says why it joined last); the template already enabled it. The first enforced `check` found 17
  violations my sweeps had never covered - webtests/transpiler_corpus.zig (9) and webtests/wgpu_smoke.zig (8),
  two harnesses whose helpers now sit above the main that calls them (verified, nothing grown). `check` OK.
  ui.zig is the ONLY file-level exemption left; bridge.zig needs none (0 reports - its two real cycles carry
  explained per-site directives). Simon's question - how many per-line lint:offs would ui need instead, keeping
  its organization: 51 forward-referenced declarations as it stands (50 crossing its 178 feature sections),
  dominated by the two core types (UiContext, 1078 lines, used by 76 sections; Ui, 4392 lines, 48 sections) and
  ~25 widget implementations defined after their public wrappers (buttonImpl, inputTextImpl, plotImpl, ...).
- **Sep 30 - ui.zig keeps its exemption (Simon: its wrapper <-> impl pairs reference each other); work toward
  linear reading instead.** zimr_lint_rules' doc corrected (only ui.zig is exempt). ui.zig mapped: foundations
  (stacks, public types, ID hashing, draw list, flags, tab bar, debug log, UiContext @5625), the widget API (Ui
  @14461, ~4400 lines; option structs), widget implementations (22880-28763), tests (28763-40381), then two
  INLINED former modules - "Dock layer" (40381) and "Persistence layer" (41126). Neither is self-contained:
  docking is spread over FOUR places (DockRequest / DockContext ~4700, DockNodeFlags / SplitResult / undock ~8600-
  8900, the layer at 40381, the dockSpace widget at 24635), and DockContext holds the layer's DockNode;
  persistence over THREE (its Persisted* types ~4640, its code at the end using UiContext / Window / Ui, `apply`
  ~22288). Plan: gather each topic in layered order - dock vocabulary (Dir, DockNode, small enums) beside
  DockContext; dock algorithms + tests just before the dockSpace widget; the persistence layer beside "layout
  persistence". Measure: forward references (51 today) must only go down.
- **Sep 30 - ui.zig reorganized for locality (it keeps its exemption).** Three moves, each measured by the
  forward-reference count (51 -> 50 -> 50 -> 50: the count is dominated by UiContext and Ui, used by sections
  above them, and by the wrapper <-> impl pairs - none of which these moves touch), kept for LOCALITY: (1) the
  dock tree's vocabulary (intro, enums and small types, DockNode) now sits right before DockRequest / DockContext,
  which UiContext holds; (2) the dock tree's algorithms (mutation primitives, layout, request processing, tests)
  sit directly before the `dockSpace` widget that drives them; (3) persistence is one contiguous stretch - layout
  persistence, the "Persistence integration" section (which holds the persistence API: current_version,
  makeTabBarKey, apply - under a "tests" title), then the persistence layer and its tests. The file no longer ends
  with two pasted-in former modules. The dock module's numbered "SECTION 1..8" banners, now in two places,
  retitled by content ("Dock tree - DockNode", ..., "Dock tree - request processing"). Exactly 9 lines changed
  (the banner titles); 53 rules: nothing grown; `zig build zimrphysics2d-demo` 315/315 (compiles ui). ui's own
  tests: with the full `test`, next.
- **Sep 30 - The template enables every rule; what a project's lint covers.** template/build.zig now lists all 53
  (no_qualified_std added, after no_qualified_zm, its comment from the rule's title). Its one finding - myproject1
  used `std.Random` qualified - fixed by zimrlint's own --fix (two passes: the binding, then the use). Simon's
  question, answered from the code: a project's lint (zimr.Project, `lint.dirs`, default {"src"}, relative to the
  PROJECT root) checks ONLY the project's own .zig files, never zimr's; the linter is compiled once from the
  dependency (tools/zimrlint.zig + the cli parser), then per-file stamps in the project's cache skip unchanged
  files; it runs in `zig build lint`, `check` and every `<app>-standalone` - a plain `zig build` never waits on it.
  Project.Lint.enable's doc (still "on top of the always-on set") corrected. Disk full again (the build's guard
  refused at 0.5 GB): removed the WHOLE .zig-cache (8 GB - safe, unlike single entries; costs one cold rebuild);
  8.9 GB free. `check` OK; `template-check` 2/2 (cold).
- **Sep 30 - `test` green after the whole reorganization: 431/431 steps.** From a cold cache (three resuming
  attempts; the last ran 2039/2045, 6 skipped; the rest cached passes). Covers everything reordered since the
  previous full run - zimrnum (its own layer order), zimrlint, robot, mjcf, robot_mjcf, urdf, zimrphysics2d, the
  demos, geno_dance, humanoid, build.zig, the webtests harnesses and ui.zig. decl-order is now ENFORCED by
  zimr's build and enabled in the template; every file passes it - in layers, vocabulary first, entry points
  last - with explained per-site directives on the genuine cycles, and ui.zig alone keeping an explained
  file-level exemption (feature order; its wrapper <-> impl pairs).
- **Sep 30 - Stranded banners: audited, and my claim corrected.** A scan found 44 banners with no code under them.
  Checked each against the pre-reorder backups: almost all - INCLUDING bridge.zig's six (css, ZIMR BOOT, THE ONE
  GLOBAL, PHASE 3a, WASI shim, CLASSIC INPUT WIRING) - were ALREADY stranded before my reorders, or are deliberate
  prose sections (spv2wgsl's "Scope and intent", "Architecture", ...); seven more files with stranded banners
  (entities, runtime, raytracer, ui_full_showcase, ecs_solar_system, cube_demo, lambert_demo) were never in any of
  my batches. So I was wrong to tell Simon the bridge's banners were my doing - they predate this session (the
  earlier sweep's tool had the same blind spot). My reorder stranded exactly ONE: renderer_trait.zig's
  "SECTION 3 - `SwAdapter`" (SwAdapter was hoisted above a user) - put back above SwAdapter's doc comment. And
  zimrlint's "Walker" banner was DUPLICATED (an old copy-paste) - one copy removed. Both clean (53 rules).
  Remaining stranded banners: bridge's six fold into the bridge change (each goes above its namespace); the others
  need a per-file read (prose section, or a home to restore).
- **Sep 30 - bridge.zig laid out in its layers.** (1) The page state depends on nothing but Value: `EvRec` left
  ZimrBoot as file-scope `EventRecord` (documented from the code: `code` is the number the app attached with
  domListen, kept as data-zbcode; a / b the event's offsetX / offsetY; drained by domPollEvent as three
  little-endian words), and g keeps the default stylesheet's HANDLE (`?Value`; css.defaultSheet rewraps it).
  (2) Three stranded comments (older than this session) handled: `read_staging`'s description became that
  field's doc, the numeric fast-path paragraph went to the branch in Value.call that it explains, and the line
  about a shared >6-argument scratch (gone since call_args went local) was deleted. (3) Layout, measured by the
  forward references left: kernel -> marshalling -> Value -> the small JS-global helpers -> THE ONE GLOBAL
  (EventRecord, UserFile, BridgeGlobals, g) -> string building (putc ... fmt, and log / warn / err, which are
  formatted console output) -> the typed facades (+ document(), fetch, ...) -> the behaviour, each under its OWN
  banner again (PHASE 3a: ZimrWgpu, WASI shim, CLASSIC INPUT WIRING, ZimrAudio, ZimrJobs, css, WASM hosting,
  the host-side module runtime) -> ZIMR BOOT: ZimrBoot and start() last. The six banners stranded at the end of
  the file are back above their namespaces. Forward references 8 -> 6 -> 5: exactly Value's conversions
  (asElement, asCtx2D, asEvent, asPromise, asResponse) - a facade wraps a Value and a Value offers to view itself
  as one: a real cycle, explained at each. The old putc directive (its reason no longer true) removed. The tool:
  already in order. 53 rules: decl-order 0, nothing grown; `zig build cube-demo` 327/327 (compiles and
  transpiles the bridge).
- **Sep 30 - raytracer laid out by its own banners; the gl contract surveyed.** raytracer.zig: an earlier sweep had
  hoisted the per-frame functions above `update` and left their five banners piled at the end. Laid out in
  layers under them: Init -> Material scatter -> Sky + tonemap -> Trace (hitSphere, hitScene, rayColor) ->
  Rendering -> Input -> UI panel -> Per-frame update -> Main entry point (deinit, app). Already in order (no
  extra move); 53 rules clean; `zig build raytracer` 315/315. gl: the 2D code (shapes2d, draw2d, text2d, image;
  105 parameters) calls 18 methods; draw3d calls only `renderer`, so the old trait's 3D methods (frustum,
  vertex3f, matrixMode, ...) are rlgl-era leftovers - ONE contract, not two. But no backend has all 18 (WgpuGl
  lacks getMatrixTransform; raster lacks it and the glyph methods; SwAdapter lacks the matrix stack, scissor and
  glyphs), only glyphDeviceMapping is probed with @hasDecl, and partial backends work because Zig compiles
  lazily - what gl must provide depends on the function called: the case the Zig team warns about. Plan (Simon's
  rule - document what cannot be checked honestly): `requireGl(gl)` in types.zig (the vocabulary every 2D file
  already imports; renderer_trait would drag raster / SwAdapter into their imports): its doc lists the methods by
  capability (always: begin end color4ub vertex2f; textures; transforms; clipping; text) and which backend
  provides which; its body checks only the four every backend has. First line of every public 2D function
  taking gl; the drifted assertIsGlContext (9 callers) replaced by it.
- **Sep 30 - The gl backends completed, and a GPU rotation bug found.** Simon: explicit `@compileError` stubs in
  the backends for unsupported things. Applied with care, the survey changed the picture: (1) SwAdapter lacked
  pushMatrix / popMatrix / translate / rotate / scissor only because those forwards were never written - raster
  supports them all - so they are now forwards, not stubs; (2) `getMatrixTransform` (called by shapes2d's
  drawRectangleLines, itself reached only from dead code) had NO implementation anywhere - now an accessor in
  WgpuGl (its modelview) and raster (the top of the modelview stack), forwarded by SwAdapter; (3) the glyph
  methods must NOT get stubs: text2d's `rasterizesGlyphs` probes `@hasDecl(glyphDeviceMapping)` to choose the
  on-demand atlas (WgpuGl) over the baked-atlas fallback the software backends use - a stub would flip the probe
  and break software text. They are an optional capability; the contract will say so. (4) A REAL BUG: the 2D code
  passes TURNS to gl.rotate (text2d, image), raster.rotate takes turns (its doc: "TURNS, TO MATCH WgpuGl.rotate"),
  but WgpuGl.rotate passed its argument straight to zm.rotationZ, which takes RADIANS - a quarter-turn text
  rotated ~14 degrees on the GPU. Fixed at the edge (radFromTurns), the doc rewritten (its rlRotatef mention was
  stale), and a twin of raster's quarter-turn test added to WgpuGl (runs via zimr.zig's test block). `test`
  431/431. Next: requireGl in types.zig and its call sites; stubs only where a gl type truly cannot do
  something.
- **Sep 30 - The gl contracts.** `types.requireGl(gl)`: the 2D drawing surface - 15 required methods, each with
  its signature in the doc (rotate in TURNS), the backends to copy (WgpuGl; SwAdapter over raster.Context), the
  rule that a backend that cannot do something still DECLARES it as a @compileError saying why, and the optional
  glyph capability (glyphEntry / glyphDeviceMapping / bindGlyphPage - probed by text2d to choose the on-demand
  atlas over the baked fallback, so deliberately never stubbed). In types.zig because renderer_trait would close
  an import cycle (SwAdapter imports draw2d and text2d). First line of 88 public 2D functions (shapes2d 53,
  draw2d 21, text2d 8, image 6). `renderer_trait.requireGlScene(gl)`: requireGl plus the scene setup
  (matrixMode, loadIdentity, multMatrix, frustum, vertex3f, clearColor, clear) - the old assertIsGlContext was a
  real second contract after all (wgpu_app's camera code, the sidebyside example), not a leftover; renamed,
  documented, renderer_trait.zig rewritten honestly (its header described the retired GlAdapter), WgpuGl's two
  duplicate trait tests made one, the curated file description updated. The first compile named the partial gl
  types: shapes2d's TestGl (the inert smoke-test stub) had `translatef` - the rlgl name - instead of `translate`,
  so smoke tests of any translating function could never compile (those paths were silently untested); now
  translate, rotate and an identity getMatrixTransform. draw2d's EmitProbe (records geometry only) declares the
  rest as explicit @compileErrors with reasons - none fires. A decl-order slip of mine (TestGl using Mat /
  identity above their aliases) fixed by keeping the aliases together. `test` 431/431; `check` OK.
- **Sep 30 - The scene contract at its real call site.** The only renderer-polymorphic function that uses scene
  methods is the sidebyside example's `drawScene(gl: anytype)` (wgpu_app's beginMode2D / endMode2D use a concrete
  WgpuGl - nothing to describe). zimr.zig now exports `renderer_trait` (documented; no cycle - nothing it imports
  leads back to the root), and drawScene states its contract first (`requireGlScene(gl)`, bound in the example's
  header). `zig build sidebyside` 315/315 - drawScene instantiated for both backends, both satisfy it; `check`
  OK; `test` 431/431.
- **Sep 30 - Stranded banners returned to their code (older than this session).** Six files read by title:
  entities (Arches, Chunk, Subcmd - hoisted below the Entity banner long ago - each under its own banner again,
  and Entity's banner back above Entity), runtime (the inlined effects section), ui_full_showcase (Panels 1-5 above
  panelWidgets, sortBuilds, panelPlots, pack, panelDragDrop), ecs_solar_system (Systems above advanceOrbit),
  cube_demo and lambert_demo ("Frame" above update) - 12 banners; examples 357/357. A tree-wide re-scan then read
  the remaining 18 one by one: deliberate prose stays (zimrphysics' "Parity status vs Jolt", zimrmath's "zimr
  additions", zimrlint's SHADER-SAFE / Sampler-at-top notes); one I had just made myself (ecs_solar_system's
  "Per-frame update", which had headed the systems too) went above update; and seven more returned: WgpuGl's
  Matrix helpers (above identityMatrix - by text, it lies above the file's first banner), runtime's camera
  section, ui's Dock tree - DockContext (so DockRequest heads DockRequest) and Widget: bullet (above
  bulletImpl), zimrphysics' Broad phase and The world. gpu.zig: "SECTION 4 - primitive writers" headed the four
  little-endian byte writers an old reorder had scattered above their users in sections 1-3 - the writers are
  vocabulary, so their section now comes FIRST, retitled "Primitive writers - the little-endian byte writers
  every encoder below uses". Every move: lines unchanged but titles, ast-check, already in order, 53 rules clean;
  `test` 431/431 (2640 tests), `zig build ecs-solar-system` OK. Left for a closer read: spv2wgsl's "Per-id
  table" and "Public entry point", ui's "Layout - cursor advancement", zimrphysics' convex-hull and warm-start
  notes, zimrlint's "FFI seam detection".
- **Sep 30 - The last stranded banners settled; the reorder tool can no longer strand one.** spv2wgsl's "Per-id
  table" was in place but malformed (a doubled bar split title from prose) - merged; its "Public entry point"
  went above convertSpirvToWgslEntry (the entry points, last in the file); ui's "Layout - cursor advancement"
  above advanceLayout; zimrphysics' "Convex hull builder" above buildConvexHull; zimrlint's "FFI seam detection"
  DELETED - no such code exists (the module-var rule handles C-ABI seams by allow-list and lint:off). The five
  left are deliberate notes (zimrmath "zimr additions"; zimrphysics' warm-start SKETCH and "Parity status vs
  Jolt"; zimrlint's two shader-tier notes). THE GUARD: reorderDecls now refuses when a section banner that headed
  at least one declaration would head none afterwards (bannersWithCode, isBannerBar,
  isTopLevelDeclarationLine) - "move that section by hand", since moving sections is a judgment call. Fixture:
  a hoist that would strand "Helpers" is refused, file unchanged; the same hoist inside one section goes ahead.
  89/89; `check` OK (after the tool itself hoisted the two helpers above bannersWithCode).
- **Sep 30 - zimrmath: requireFloatLike, and the first thing it caught.** Of zimrmath's 132 public anytype
  functions, 54 already guard their types with a switch (sinRad, lerp, ...), 31 do plain arithmetic over MIXED
  shapes (abs / square any number, andInt / xorInt integers only, dot / cross2 float vectors - one check cannot
  describe them, so none: Simon's rule), and 30 use float-only operations. `requireFloatLike(comptime T)` - a float
  of any width, a comptime_float, or a vector of floats; integers refused on purpose (convert where it is visible)
  - is the first line of 28 of those (pointFromArr3 / dirFromArr3 take arrays). It caught, in zimrphysics2d,
  `length2(.{ p[0] - g[0], p[1] - g[1] })` - an anonymous tuple that compiled only because dot2 coerces one -
  which is `p - g` written out by hand: now `length2(p - g)`. zn-zimrmath 171/171; `test` 431/431 (2640 tests).
  Next: every example (all-examples), shaders included.
- **Sep 30 - all-examples stopped (Simon: too long); back to the RL plan.** Eight attempts compiled ~313 of ~322
  examples (shaders included) with requireFloatLike in place - no compile errors. The disk could not hold the
  run: each attempt re-installs everything already compiled into zig-out, so the peak grows; the watchdog was
  changed to prune zig-out instead of stopping. (A compile-only all-examples step would fix that for good.)
  N4 VERIFIED on today's tree: LatentPlanScorer and Mppi in place, their eight tests in the full zimrnum suite
  (passing), the tutorial's 18d.7 and 18d.8 intact after the layer-order regeneration. Next: N5 SequenceReplay -
  zimrnum already has ReplayBuffer (one flat ring of fixed-width transitions, uniform sampling) and
  RolloutBuffer; N5 extends what exists rather than adding a second replay.
- **Sep 30 - N5, first half: `SequenceReplay`.** Design read from R1.5 and the BMPC-jax notes: a ring per
  environment of whole rows, O(1) windows as (environment, start), allowed across an episode's end, `finished`
  masks, per-step masked insertion. One definition per idea: the ring is ReplayBuffer's, so ReplayBuffer gained
  chronological access (`slotOf` - the oldest is `len` slots behind the head, one formula for filling and full;
  `row`, in place, for the write-back to come; `deinit`, which it never had) and SequenceReplay holds one per
  environment. Windows come out STEP-MAJOR because LatentRollout reads rows t * batch + b. Known answers: (1) every
  window is consecutive steps of one environment, the rings deliberately wrapped so a window crossing the physical
  end (steps 4, 5, 6 in slots 4, 0, 1) is drawn and checked; (2) `finished` against a hand computation for every
  drawn window. Negative control: the done step itself marked finished fails exactly test (2). Ref notes: three new
  rows, `push` (it had none) and `sample` / `deinit` widened. Tutorial 18d.9 "Remembering stretches of play", its
  fold generated (332). zimrnum 282/282.
- **Sep 30 - N5's first half VERIFIED after a restart** (the turn that built it lost its reply; its files survived,
  and zimrnum.zig was edited four minutes after the entry above claimed 282/282 - so everything was re-checked on
  the file as it stands). Code read: ReplayBuffer's slotOf (oldest = len slots behind the head - right for filling
  and full), row in place, deinit; SequenceReplay's init (errdefer frees exactly the rings made), push (inactive
  environments write nothing), sample (environment uniform among those with enough steps, start uniform over every
  valid position, step-major copy, finished 0 through the done step and 1 after). Tests read: the wrap window is
  REQUIRED to be drawn; finished against a hand computation for every window. Both run DIRECTLY (bypassing the
  build cache): 2/2. The negative control re-planted (done step marked finished): exactly the finished test fails,
  "expected 0, found 1". zimrnum suite green (cache hit on these exact contents); 53 rules clean on zimrnum and
  zimrnum_ref; reference rows present; tutorial 18d.9's prose free of testing talk. Small notes for the second
  half: ReplayBuffer.deinit has no doc comment, and sample's two-counters-per-window scheme deserves a line.
- **Sep 30 - SequenceReplay rewritten as a course (Simon: clearer names, more locals, ASCII diagrams - "the code
  is actually a course").** Same behaviour, same expressions named: `environment_rings`, `row_width`,
  `step_rows`, `environment_is_active`, `draw_index`, `window_length`, `windows_out`, `finished_out`;
  `eligible_rank`, `chosen_ring`, `last_valid_start`, `first_value_of_output_row`,
  `an_earlier_step_ended_the_episode`; the which-environment search pulled out as `eligibleRing` (with a worked
  example in its doc). ReplayBuffer's new methods take `chronological_index`, and slotOf names its parts
  (`head_minus_len_kept_nonnegative`, `oldest_slot`). Diagrams in the comments: a ring of 5 after 7 pushes
  (physical slots vs chronological order, the head marked), the formula for the oldest slot, the flat storage,
  one ring per environment and how push splits a frame, a window as (environment, start), finished on an example
  window, and the step-major batch row by row. The draw counters explained (two per window, offset by the draw
  index). Tutorial: 18d.9 regenerated by `zig build zimrnum-ref` (the fold shows the new code and its diagrams);
  its hand-written example renamed to the same vocabulary. The two tests: field renamed only, run directly 2/2;
  zimrnum 282/282; 53 rules clean. (A false alarm on the way: my splice's own check matched `..rings` inside
  `[0..rings_built]` and refused to write - so the first "2/2" was the OLD code; caught, check narrowed, redone.)
- **Sep 30 - Highlighting: it was already there.** Both tutorials carry the `<!--docfmt:style-->` marker and are
  on the published list, so `zig build doc-pages` runs tools/docfmt.zig over them: every `<code class="zig">`
  block highlighted at BUILD time through std.zig.Tokenizer (`tok-*` spans; the one shared stylesheet injected
  at the marker) - zero script, one highlighter for the gallery and every doc page. Built: zimrnum-tutorial
  30,965 spans, robot-mocap-tutorial 12,771. The tutorials looked plain because I was handing Simon the SOURCE
  html (src/notes/tutorials/), which is never highlighted. From now on: present the BUILT page,
  zig-out/web/<page>.html, after `zig build doc-pages`. No code changed.
- **Sep 30 - The two tutorials complement each other on replay.** Both explained "one ring per character"; each
  explained a different window rule; neither mentioned the other. zimrnum 18d.9 gains "Two ways to treat a break":
  a shove is a break of another kind (the motion goes on, but jumps unpredictably), so SuperTrack's replay keeps
  the same ring and only draws windows inside one segment - the price of each rule (masking: windows partly empty;
  segments: long windows hard to find - ~21-frame segments, 32-frame windows may not exist), linking to
  robot-mocap #replay. Robot-mocap 11.7 gains a paragraph saying its machinery WORKS THE SAME WAY as zimrnum's
  SequenceReplay (not that it is it - today it is its own code) and pointing there for the mechanics, keeping only
  what is particular: the segment rule. Plan, under N6: unify the replays when BMPC comes to TrackEnv (typed
  columns kept; rings and window sampling from zimrnum; "inside one segment" as a second window rule). Checked:
  zimrnum-ref and doc-folds regenerate nothing (the prose stands; 196 blocks, 0 errors); doc-pages builds; both
  links land on existing ids; zimrnum 282/282 (its reference test reads the page).
- **Sep 30 - N5 COMPLETE: the write-back, empty targets, and the masked insertion's answer.** (Simon, standing:
  generic ingredients in zimrnum; specialised code may start as an independent fork in the robot files; no
  frameworks or towers of abstraction - simple functions on arrays. The plan's N6 note rewritten to match:
  robot_track.Replay stays SuperTrack's own, no second window rule in zimrnum.) `sample` also fills `origins_out`
  - a `WindowOrigin` per window, its environment and the PHYSICAL slot of its first step (still valid after
  later pushes, until overwritten); `eligibleRing` became `eligibleEnvironment` (the origin needs the index).
  `writeBack(origins, first_step, step_count, first_column, values_in)`: step-major values copied into those
  windows' rows in place - reanalyze passes a prefix of the batch's origins and first_step 1 (BMPC's row t holds
  the target planned at t - 1). Empty targets: N(0, 1), written by the caller at push - no machinery, the doc
  states the convention. Known answers: (3) after writing back targets that name their (window, step), both rings
  equal a hand-applied copy EXACTLY, and every sampled row read N(0, 1) before; (5) a frame environment 1 sits
  out leaves its ring byte-identical - storage, head, length - and its time order is the frames it stepped (0,
  1, 4, 5). Negative controls: ignoring first_step fails exactly the write-back test (the first attempt did not
  even compile - an unused parameter - and printed nothing: re-planted with a discard, then it failed as it
  should); ignoring the active mask fails exactly the inactive test. Reference: 749 rows (WindowOrigin,
  writeBack); tutorial 18d.9 "Targets that improve" + the example (origins, writeBack); zimrnum 284/284; 53 rules
  clean. Next per the plan: the ensemble blocks (item 5).
- **Sep 30 - Plan item 5 COMPLETE: the ensemble blocks.** Members as arrays needed nothing new: an ensemble is an
  array of members, and meanAxis / varianceAxis over the member axis already give eq. 3's mean and (/ count) eq.
  4's variance of the mean - recorded instead of wrapped. The new block, plain arrays in and one value out:
  `klRobustExpectation(T, values, delta, tilted_weights_out)` beside standardError. The maths gave the algorithm:
  the KL dual's derivative is KL(tilted weights || uniform) - delta, so beta* is the temperature whose tilt sits
  exactly delta from uniform, bisected on a log scale (KL falls monotonically in beta), and the value is the tilted
  average; delta 0 -> mean, delta >= log(N / k) -> exactly the minimum. Its doc draws KL against beta. Known
  answers: limits exact; the value SANDWICHED with no optimiser - no reweighting within delta (mixtures of
  uniform with one- and two-value spikes) averages lower, the dual objective from its formula never higher and
  meeting it at its best beta (1e-6) - the weights delta from uniform (1e-9), ordered inversely to the values;
  small delta ratio 1 +- 0.005 at 1e-4; central differences = the tilted weights (1e-6). Negative control: the
  bisection flipped fails exactly tests 2-4 (0.18 from uniform, a ratio of 21.9, the gradient 0.19 off) - test 1
  passes because the limits never search. Lint caught two one-line signatures of mine (4 and 5 parameters) - one
  per line now. Reference 750 rows; tutorial 18d.10 "Pessimism with a dial" (333 folds); zimrnum 288/288; 53 rules
  clean. Next per the plan: item 6, TD4's blocks (T5, T6).
- **Sep 30 - T5 DONE: the categorical twin critic's pieces.** Most of it existed: Q is `CategoricalScalar.decode`
  (its `.identity` axis is documented as C51 / TD4 return atoms), the network is N2's layers, the critic loss is
  categoricalProject then softCrossEntropyRows. New - extending CategoricalScalar, which owns the grid, with plain
  functions on arrays: `quantileBlend` (one walk up both CDFs; each slice of probability placed at the blended bin
  INDEX - the bins are evenly spaced on the axis - and landed by the shared addPointMassToGrid, its third user),
  `twinTarget` / `twinTargetRows` (the lower-mean twin per row, a tie to the first, blended by the weight; weight 1
  and 0 copy exactly). Known answers, sharper than the plan's: the blend's mean EXACTLY the weighted mean (1e-12);
  a distribution blended with itself is itself; two point masses blend into ONE point mass between them (at 0.5:
  bin 20 of 10 and 30; at 0.25: bin 25) - the reason for quantiles over a density mix; weight 1 / 0 = lower /
  upper exactly in either order; rows chosen row by row; the critic loss on planted logits = the hand computation.
  Negative controls: the weight on the wrong twin fails exactly the mean and point-mass tests (the symmetric ones
  pass, as predicted); the higher twin chosen fails exactly the two selection tests. Slips caught: `.{0} ** 41` no
  longer parses here (@splat); a 121-column reference line; the critic-loss test first placed above
  softCrossEntropyRows - decl-order flagged it, moved after softCrossEntropyRowsGrad. Reference 753 rows; tutorial
  18d.3 "Twin critics, kept distributions"; zimrnum 294/294; 53 rules clean. Next: T6, the deterministic actor.
- **Sep 30 - Review (Simon: "make it perfect and verbose ... look for bugs"), part 1: the replays.** TWO REAL BUGS in
  SequenceReplay.writeBack: (1) PARTIAL UPDATES - the environment index was checked inside the write loop, so a bad
  origin late in the list returned an error after earlier windows had been overwritten; (2) WRITES OUTSIDE THE STORED
  HISTORY - nothing checked the steps exist: past the newest row the write wrapped onto the OLDEST rows (full ring) or
  onto slots holding nothing yet (filling ring), and a first_slot beyond the capacity was hidden by the modulo. Fixed:
  every origin checked BEFORE anything is written (a real environment; a slot below the capacity holding a stored
  row; stored rows for every step after it), the writes going through `row()` like sample's reads. Also: an empty
  write-back is a no-op (reanalyze may choose no windows); `eligible_ring_count` -> `eligible_environment_count`.
  ReplayBuffer: `chronologicalIndexOf(slot)`, slotOf's inverse (one `oldestSlot` behind both); slotOf / row keep
  zimrnum's unchecked fast-path form (`Tensor.offsetOf`'s convention) but now SAY that an index >= len WRAPS rather
  than panics; sample's locals named and its physical-slot draw explained (kept on purpose: a uniform slot below len
  IS a uniform stored row - a ring fills from slot 0 - and switching to chronological indices would change which rows
  every fixed seed draws). Tests: chronologicalIndexOf undoes slotOf (filling and full; unfilled slots at len or
  beyond); the write-back all or nothing (a bad environment last, steps past the newest, a slot beyond the ring, a
  slot not filled yet - each an error, the rings byte-identical; empty = no-op). Negative control: today's tests run
  against the OLD writeBack - exactly the all-or-nothing test fails ("expected error.DomainError"). zimrnum 296/296;
  reference 754 rows; 53 rules clean. Part 2 next: klRobustExpectation, the twin-critic methods, the tutorial prose.
- **Sep 30 - Review, part 2: klRobustExpectation, the twin-critic methods, the tutorial prose.** klRobustExpectation:
  (K1) NON-FINITE VALUES were accepted - @min / @max step over a NaN the sum does not, so at delta 0 (no search) a
  NaN came straight back as the answer, and at delta infinite the minimum skipped it; now refused. (The old code
  refused my first NaN test only BY ACCIDENT: the NaN weights summed to a KL of 0 and the bracket gave up after 4096
  halvings - the negative control exposed it, so the test now covers delta 0, 0.1 and infinity.) (K2) THE MIDPOINT
  OVERFLOWED: sqrt(a * b) of two temperatures of the values' scale passes f32's 3.4e38 once the scale passes ~1e19
  and the search silently returned the mean; now sqrt(a) * sqrt(b). (K3) An edge: delta within rounding of log(N/k)
  could saturate the tilt with KL still <= delta, and halving on would reach beta = 0, weight exp(-0/0) = NaN; the
  sharpening now stops on saturation and returns the minimum. (K4) Names: fillTiltedWeightsReturningKl, the two
  bracket counters separate, why the normaliser is never zero. Tests: non-finite refused at three deltas; f32 at
  scale 1e25 = f64 to 1e-4 and well below the mean; delta just below log N finite and in range. Negative control:
  the OLD function fails exactly the non-finite and the huge-scale tests. Twin critics: quantileBlend's parameters
  first / second / first_weight (it blends any two distributions; lower / upper belong to twinTarget), its doc now
  says what it assumes (distributions; the blend carries the smaller total; a negative entry is empty);
  twinTargetRows checks ranks before reading shapes. Tutorial: 18d.3 showed the CategoricalScalar fold TWICE (my
  separate twin example used zn.CategoricalScalar, and the generator folds every zn. name after every example) - now
  three paragraphs and ONE example, each fold once (333 folds); 18d.9 says the write-back checks every address and
  writes nothing on a bad one; 18d.10's "log N" is log(N / k) with ties. zimrnum 299/299; 53 rules clean.
  (Then `doc-pages` refused to start: the disk had filled again, 546 MB free - the build cache back to 8.3 GB.
  Removed whole, as before; 8.9 GB free; the pages rebuilt cold.)
- **Sep 30 - T6 DONE: the deterministic actor's blocks.** The actor is the existing layers (its pre-activation is the
  Dense output before `tanh`); the target actor is `polyakUpdate`. New, simple functions on arrays plus one composed
  graph method: `Graph.preActivationPenalty` (a row of -1s broadcast by add, two relus, squaredRowNorm, the mean
  over rows via transpose + reduceRows - existing ops only, no abs on the tape); `linearSchedule` (from the step
  alone, both ends returned exactly); `policyUpdateDue` (after every delay-th critic update; a delay of 0 refused);
  `addGaussianActionNoise` - ONE function for TD3's two noises, exploration (no clip) and target smoothing (0.2,
  clip 0.5) - its counter draw_index * len + i, because a fixed stride would repeat noise once a batch outgrew it
  (1024 environments x 64 dimensions = 65536 values). Known answers: the penalty by hand (2.125) and checkGradient
  (< 1e-7), zero value AND gradient inside the band; 33 actor updates in 100 at delay 3; the schedule's exact ends,
  midpoint, flat tail and refusals; the noise clipped, inside [-1, 1], reproducible, zero std = unchanged, unclipped
  std measured within 5%. Negative controls, one scratch copy: the penalty's lower side dropped, the delay off by
  one, the slope over the whole run - each failed exactly its own test, the noise tests passed. A shadowing slip
  (`gradient` is a zimrnum function) renamed. Reference 758 rows; tutorial 16.12 "A deterministic actor: TD3's and
  TD4's helpers" (folds once each), and 16.3 now points to 18d.9; zimrnum 304/304; 53 rules clean. Item 6 (TD4's
  blocks T5, T6) COMPLETE. Next per the plan: item 7, V1's block (a differentiable observation selection) and V2b's
  (a DAgger buffer).
- **Sep 30 - Item 7 DONE: V1's observation selection; V2b needs nothing new.** V1: `gatherColumns`, plain (the one
  the game calls - mirrors gatherRows, every column checked before any write) and `Graph.gatherColumns`, a product
  with a constant 0/1 selection matrix built from the existing oneHotRows, transposed - no new op, its gradient
  matmul's own. EXACT, with one honest caveat found while writing the doc: equal as NUMBERS, not bits - a negative
  zero comes back as zero (-0 + 0 = +0); and the input must be finite (0 * inf = NaN). Known answers: every column in
  order gives back the input (a -0 included); graph = plain exactly under a reordering with a repeat and a column
  left out; checkGradient, exactly zero for the unchosen, and a column chosen twice gets exactly twice one output's
  HAND gradient (my first draft only checked "nonzero" while its name claimed "doubled" - caught on re-reading, now
  checked against 2 (x - t) / 6). Negative control: the plain gather reading the next column fails exactly the plain
  and parity tests. V2b: a DAgger buffer is a ReplayBuffer whose rows are student state ++ teacher action - no new
  zimrnum code (Simon's rule); the teacher and the row test belong to the robot assembly (V2). Reference 760 rows;
  tutorial 18d.11 "Watching less than the model knows" (with the DAgger recipe); zimrnum 307/307; 53 rules clean.
  Next per the plan: item 8, the assemblies - BMPC (N6) first.
- **Sep 30 - Review, part 3: random streams, and the new sections.** A REAL BUG in T6's addGaussianActionNoise: its
  counter, draw_index * len + i in 32-bit arithmetic, wraps - with 1024 environments x 64 action dimensions, len is
  2^16, so draw 65536 landed exactly on draw 0's counters and the exploration noise would have REPEATED every 65536
  steps (its doc claimed the opposite). SequenceReplay.sample's index * 0x9e37 + 2w wrapped more gently (draws
  millions apart occasionally coming back to nearly the same counters). Both now draw from ONE STREAM PER DRAW,
  `rng.split(draw_index)` (split derives a seed through bijections, so distinct labels give distinct streams), the
  element index as the counter. Regression test: 65536 values per draw, draws 0 and 65536 must differ - the old
  formula, planted back, fails exactly it. ReplayBuffer.sample keeps its form (robot_gym's SAC agent calls it one
  row at a time with a fresh per-update stream, so it never wraps in practice; SacTrack's fingerprints rest on it)
  and its doc now says so and how to use it. Mppi checked: already split per iteration and state - correct.
  Tutorial: 18d.11's example had a `...` placeholder - now the real two loops; its prose said "each output column
  holds a single 1" - it is each column of the MATRIX; 16.12's "TD3's computes" -> "TD3's actor computes". The
  rest of T6 / V1 re-read: sound. zimrnum 308/308; 53 rules clean.
- **Sep 30 - N6 designed, not yet built: the inventory and the breakdown.** Read N6 and R1.1 / R1.1c in full. Most
  ingredients exist; missing: `finished` masks in WorldModelLoss (its only weight is rho^t, per step - finished is
  per row), RunningScale, the BMPC policy head's pieces. The agent is an assembly - its own file, proposed
  `src/robot_bmpc.zig`. Six turns B1-B6, each with known answers, recorded in the plan under N6. No code this turn.
- **Sep 30 - BMPC-jax and EfficientTDMPC v5 re-read (Simon: "did we forget something").** ONE REAL GAP in our N6
  design: jax stores each row's NEXT OBSERVATION and samples windows of H rows; we had planned observations only and
  windows of H + 1 rows - so the step that ENDS an episode would take the next episode's first state (after the
  reset) as its successor, and the consistency loss would teach the dynamics a jump that never happens. Fixed in the
  plan (B3's row layout; the target in the same row as its observation, write-back first_step 0; the tutorial's
  replay example to follow in B3). SequenceReplay itself is generic and needs no change. Also pinned for B1: torch's
  RunningScale exactly (EMA toward max(1, q95 - q5), the floor per batch before averaging - jax floors after, and
  stores it) and the masks' normalisation (jax: consistency over unfinished rows; reward / value summed over steps,
  mean over the whole batch; a continue loss masked, which jax forgets). B4's base stated as torch's (entropy 1e-4,
  KL averaged over dimensions, rho / H, log std [-3, 1]); jax's differences listed as bench options. v5 agrees with our
  R1 notes; new: A.4 wall-clock parity, B.4 acting penalty no help, C.1 ensemble cuts planner exploitation; for N7 the
  multi-horizon objective needs the value heads at every depth. Mppi's defaults already match (512/24/64/6/0.5,
  spread [0.05, 2]).
- **Oct 1 - Four more papers weighed (Simon: "something to include?"): plan R4, candidates only.** Newt is the one
  that maps onto what we have: its demonstration recipe fits BMPC almost for free (a demonstration row's target =
  the teacher's action -> BMPC's KL distillation IS model-based BC; pretraining = the warm-up burst; 50 / 50 = a
  second SequenceReplay; constrained planning = an Mppi bias annealed) - a model-based third route for V2's
  multi-clip student; no task embedding needed (the reference is the instruction); open-loop length as a world-model
  diagnostic. RAY-TOLD: exact short rollouts + learned value in our scorer-agnostic Mppi, and ray observations as a
  game-cheap V1 view - after the gate. IQL-TD-MPC (2023 / ICRA 2024, not 2026): offline, hierarchical - later.
  ViGMO: not found by that name; visual - low priority for state-based agents. Nothing scheduled; B1 is still next.
- **Oct 1 - B1, first half: RunningScale; R4 pointers placed.** The four papers now also have pointers where they
  will act (V2: Newt's model-based distillation as a third route to weigh; "After the gate": RAY-TOLD's exact-
  rollout scorer with ray observations, IQL-TD-MPC's subgoal manager, Newt's open-loop length as a diagnostic).
  `zimrnum.RunningScale(T)`, after `quantile`: value (starts 1) and tau; update(batch, scratch) copies and sorts the
  batch (left untouched), takes q5 and q95 by quantileSorted - whose interpolation at q * (n - 1) IS torch's - and
  moves value += tau * (max(1, q95 - q5) - value): torch's order, the floor per batch before averaging. Known
  answers: the hand EMA (101 values: spread 90 -> 9.9; then a 0.5 spread floored -> 9.01); torch's order pinned
  against jax's (from 5, a 0.2 spread -> 4.6, not jax's 4.52); 11 shuffled values -> 9; the batch untouched;
  empty, mismatched scratch and NaN refused. Negative control: jax's order (average, then floor) fails exactly the
  two numeric tests, with exactly jax's numbers (8.955, 4.52). Slips: `scale` shadows a zimrnum function (test
  locals now kl_scale); two doc lines at 121. Reference 762 rows; tutorial 18d.12; zimrnum 311/311; 53 rules
  clean. Next: B1's second half - the `finished` masks in WorldModelLoss.
- **Oct 1 - B1 COMPLETE: the finished masks.** Read first: WorldModelLoss's reward and value terms are
  softCrossEntropy against two-hot constants; consistency is LatentRollout's own. The deciding fact:
  softCrossEntropyRowsGrad weighs the prediction by the row's TARGET MASS, so an all-zero target row costs exactly
  nothing, value and gradient - masking reward and value is masking their targets (now pinned by its own unit test;
  the backward case's comment said "predicted - target" and now gives the real formula). Design: the rollout OWNS
  the masks - an `unfinished` [batch, 1] column per step and a factor batch / still counting (0 when none) - all 1
  until `setFinished(finished_out)`, which checks every entry is 0 or 1 before writing any; consistency at t =
  mseLoss(z * M, y * M) * factor (the mean over the windows still counting); WorldModelLoss multiplies its targets
  by the same columns (whole-batch mean, finished as 0): one call marks all three terms. New Graph op
  copyToEveryColumn (copyToEveryRow's twin). Known answers: nothing finished = the old formula BIT FOR BIT, total and
  every gradient of five networks, against a hand-built second graph in the old node order; a finished window's
  action, next observation and targets changed -> no bit moves anywhere (and counted again, the losses part); the
  masked mean by hand; all finished at a step -> 0, not NaN; refusals change nothing. Four negative controls, each
  failing exactly the predicted tests (no rescale: 9, 10; targets unmasked: 15; consistency target unmasked: 9, 15;
  gradient assuming mass 1: the zero-row test and 15). Slips: an anchor across a blank line (caught before any
  write), `gradient` shadowing a zimrnum function. zimrnum 317/317; 53 rules clean; reference 764 rows; tutorial
  18d.4 paragraph. For B4: check whether jax masks the policy's loss by finished. Next: B2, the policy head.
- **Oct 1 - B2a: the policy head; one note corrected from torch's own source.** Before designing, re-read BMPC's
  torch code (still on disk at /tmp/bmpc/bmpc-main) instead of trusting the recorded summary - and it corrected one
  point that matters: in BMPC mode the policy is NOT a squashed draw. mean = tanh(m), action = clamp(mean + s * eps,
  -1, 1), no Jacobian - so the policy IS N(tanh m, s^2), the very Gaussian its KL compares, and SAC's
  squashedReparameterize is TD-MPC2's way, not BMPC's (noted in the plan for B3). Also confirmed from source: log std
  = low + dif * (tanh + 1) / 2 in [-3, 1] ([-2, 1] for reanalyze's policy trajectories); update_pi on zs.detach();
  the KL averaged over dims; scale.update(kl[0]) before dividing; scaled_entropy = -size * log N(eps), whose
  gradient is size per log std and whose mean is size * entropy - so dims * entropy has exactly torch's gradient.
  Existing pieces reused: Graph.klGaussianDiag (already KL(policy || reference), per-row spreads, the reference as
  data), Graph.slice on columns, DiagGaussian(T).half_log_tau (the house pattern, not hoisted). New:
  Graph.tanhIntoRange, Graph.diagGaussianEntropy, TanhMeanGaussian(T). Known answers: exact ends for both ranges,
  the slope by hand; entropy parity with DiagGaussian.entropy and a gradient of exactly 1; centres, spreads, zero
  KL against itself, a distillation step under checkGradient. Two controls, each failing exactly its predicted
  tests. zimrnum 320/320; 53 rules clean; reference 769 rows; tutorial 18d.13. Next: B2b, the per-step policy loss.
- **Oct 1 - B2b: the policy loss; B2 COMPLETE.** Settled from BMPC-jax's source (/tmp/bmpcjax), not memory: jax DOES
  mask the policy loss (sum over t of lam * kl / scale where ~finished, then the mean over the whole batch) - torch
  has no masks only because its windows never cross an episode. So: torch's formula with jax's masks.
  `PolicyDistillationLoss(T)`: the latents ONE Var [H * batch, latent], step-major, data (a separate graph's constant,
  or detached rollout rows); the policy in one pass through TanhMeanGaussian; targets zero-filled = N(0, 1); the KL
  averaged over dims; c * dims * entropy; one weight column rho^t / (H * batch) * unfinished, built in-graph from the
  rollout's shared columns (one setFinished marks all four terms now); each term one dot product; updateScale reads
  step 0's rows into the RunningScale and sets 1 / scale. Known answers: the hand computation with the formulas
  written out (nothing finished; one finished, counting 0 over the whole batch); a finished row's latent and targets
  changed -> no bit moves (counted again, the totals part); updateScale = a hand RunningScale on step 0's rows only,
  the scale really moved, and the gradient WITHOUT the second recompute equals the one with it, bit for bit (a
  shared graph may skip it - now documented as a known answer); checkGradient through the policy network, every
  parameter connected; refusals. Three controls, each failing exactly its predicted tests. Lint: two 4-parameter
  signatures put one per line. zimrnum 325/325; 53 rules clean; reference 773 rows; tutorial 18d.14. Next: B3, the
  agent's skeleton and acting (robot_bmpc.zig) - acting = clamp(tanh(m) + s * eps, -1, 1).
- **Oct 1 - Lint pause: decl literals across zimrnum.** Simon asked whether `const x: Tensor(T) = try .alloc(...)`
  is accepted in place of `try Tensor(T).alloc(...)`. Proven first on one line in a scratch copy: it compiles
  (Tensor(T).alloc returns Error!Self; decl literals work through `try`, as the code's existing `try .build(...)`
  already showed) and its tests pass; all 53 lint rules accept it (none concerns decl literals). Then a conservative
  converter (/tmp/declit/declit.py): only `const|var name: X = [try ]X.fn(...)` with the two X texts byte-identical
  (a regex backreference: same text, same scope, same type - so `.fn` is the same declaration), X a plain or dotted
  name with at most one non-nested argument list, and the call the WHOLE initializer (its matching paren, found by a
  scanner that skips strings, chars and comments, followed only by `;`). Dry run: 1160 sites, 0 excluded (718
  Tensor(f64).alloc, 114 Tensor(T).alloc, the fromSlice family, Rng.init, Series, the RNN cells' init, the typed
  wrappers' .of). Written back to front; an independent checker confirmed 39913 lines, exactly 1160 changed, each
  equal to the original with only the receiver removed. zig fmt unchanged; zimrnum 325/325; `zig build check`
  358/358 steps; 53 rules clean; folds regenerated. Elsewhere: 919 sites in 84 files, left for Simon to decide.
- **Oct 1-2 - prefer-decl-literal (advisory, --fix) landed in zimrlint; a walker blind spot found; lint plan written.**
  The rule (LintRule `prefer_decl_literal`, NOT in zimr_lint_rules): fires on `const|var x: X = [try ]X.fn(...)` with
  the receiver spelled with exactly the annotation's tokens and the call the whole initializer; the fix deletes the
  receiver. 3 tests, 3 negative controls; zimrlint 92/92. On pre-conversion zimrnum it found only 1057 of 1160: the
  walker never visits members of a container reached as an expression (`return struct {...}` - every generic type),
  for EVERY rule. A one-branch fix in a scratch copy makes `--fix` reproduce the verified 1160 byte for byte (+1 split
  declaration). Not landed: `check` lints from source with the 53 rules and the baseline - newly visible code must be
  measured and ratcheted first. Simon's policy (Oct 2): constructor-like decl literals only with the type on the same
  line; other literals free. Last turn's helper sat below its caller (decl-order would have failed `check`): moved;
  `check` 358/358. The plan, L0-L7: src/notes/lint_opinionated_plan.md, "NEXT".
- **Oct 2 - Lint plan L1: the coverage oracle (`zimrlint --coverage`).** Simon: the creation vocabulary is a big,
  opinionated list (creation of memory-owning things must show the type); proceed. Built inside zimrlint.zig (no new
  files): Ctx.visited marked by walkNode; walkCoverage / unwalkedNodes / runCoverage; a `--coverage` flag. Test: the
  known hole (a declaration in a struct returned by a function) is found, a walked one is not. zimrlint 93/93;
  self-lint clean. Slips: an anchor matching Ctx AND Args (nothing written; widened); `@typeInfo(...).@"enum".fields`
  is `field_names` in this Zig (the unit test never instantiated runCoverage - the exe build caught it). Measured on a
  COPY of check's 839 files: 125610 tracked nodes never walked, in 717 files; the statement-shaped holes (2321
  declarations, 973 functions, ~1600 control-flow nodes) are L2's work, field accesses and calls mostly read through
  their parents. Next: L2 - the container-as-expression branch, re-measure, attribute the rest.
- **Oct 2 - Lint plan L2, step 1: one branch, then attribution; L2 revised to a complete walk.** In scratch: the
  container-as-expression branch plus a root-attributing `--coverage` (outermost unwalked nodes by token span,
  labelled by the token before them or by what opens their block). On the 839-file copy: 125610 -> 112388 unwalked;
  declarations 2321 -> 224, functions 973 -> 180, most loops and ifs closed. The 76127 remaining roots: type positions
  (~18000, by design so far), defer/errdefer bodies (6386), if conditions (~9000), for operands (~3250), operator
  operands, struct-literal values, array elements, array access - all one cause: `childNodes` is a partial switch
  with `else => no children`. Revised L2: an EXHAUSTIVE `childNodes` (no `else` arm), compiler-enforced. No change to
  the real tree this turn (scratch only); the plan records the numbers.
- **Oct 2 - Lint plan L2 done in scratch: a COMPLETE walk, 125610 -> 0 unwalked nodes.** An exhaustive
  `allChildren` (163 tags, no `else`, compiled first time) iterating fixed children + list slices; walkNode's handlers
  completed (conditions, continue expressions, for inputs, case values, declaration types and attributes, the fn
  prototype); `walkContainerChildren` via `fullContainerDecl` for every container tag plus its tag argument (it
  handled 2 of 12 container tags: tagged and tag-typed containers were never walked); `walkTypeExpr` through
  `allChildren`. Re-measured on the 839-file copy at each stage: 112388 -> 226 -> 0. Slips: an anchor matching twice
  (nothing written); a `$'\t'` bash-ism under sh (sampled with Python instead). Saved as
  src/notes/lint_complete_walk.patch (verified to reproduce the scratch). Next: L3 - the 53 enforced rules over the
  newly visible code, on the copy: counts above the baseline, autofixable vs manual; and the double type-rule call.
- **Oct 2 - Lint plan L3: what the complete walk exposes.** Linted the copy with the committed walker and the
  complete walk, no baseline, then filtered to the 721 files `check` lints (the build also skips the vendored cli,
  notes/staging, webtests/external_project, tools/c2js_cases - the first comparison over all 839 copied files had
  mixed those in). Committed walker: 0 there (green; the baseline is empty). Complete walk: 1967 distinct, genuine
  on sampling; 1618 autofixable (no-qualified-std 1319, no-qualified-zm 285, float-from-int 14), 349 manual. 107
  duplicates traced to the fn_decl handler's by-hand prototype checks (turn 348's fix for the old blind walk) now that
  the prototype is walked: ONE WALK in scratch - walkTypeExpr and its three call sites removed; re-linted: 0
  duplicates, identical distinct set. Slips: a doc-filtered read made an anchor miss (nothing written); a `pkill -f`
  matched its own shell (then `pkill -x`). Patch regenerated (verified). Next: L4 - land, autofix, ratchet the rest.
- **Oct 2 - Lint plan L4 in detail: autofix a bit more, burn the rest down by hand with few compiles.** Measured
  what the cheap checks catch: `zig ast-check` (0.24 s on zimrnum) catches syntax, undeclared identifiers (renames),
  shadowing (alias collisions), unused locals - not types; fmt 0.04 s; one-file lint 27 s at worst. So three tiers:
  T0 per edit, T1 per file, T2 (`check` ~4 min + touched module tests) once per batch. lint_autofix.md §6 already
  rated fn-args-multiline and branch-braces A1 and prefer-std-alias A2: writing those takes the by-hand remainder
  from 349 to 146 findings in 35 files, half of it in entities.zig, gpu/zn_conformance.zig, utils.zig, zimrnum.zig.
  int-from-float stays by hand on purpose (the rounding choice is the improvement). Landing (L4b) waits for the
  next full build, with prefer-decl-literal. Plan: lint_opinionated_plan.md, L4a-L4d.
- **Oct 2 - L4a, part 1: autofixes for fn-args-multiline and branch-braces.** In the real zimrlint: `closingParen` +
  one comma before it (fmt does the layout); `emitBranchBraces` -> `{ body; }`, swallowing the statement's `;` but
  never an `else`. Tests run std's renderAlloc after the fix (parse + rule silent); two negative controls each fail
  their own test. The linter fixed its own two findings (dogfood); 95/95. On real code, a copy of the 25 files with
  all 104 findings: fix + fmt -> 0 left, all pass ast-check. Slips: my comments claimed `--fix` formats (it is `zig
  build fix` = --fix then fmt - corrected); one command ran past 300 s (the fix loop on 25 files, zimrnum last -
  re-run alone in the background: fixed 19). Patch refreshed on top. Next: prefer-std-alias's fix.
- **Oct 2 - L4a part 2: prefer-std-alias folded into no-qualified-std; the L4b package's first unit-test run.**
  Simon asked "Stuck?" - not stuck; the previous step had finished. prefer-std-alias's names have no overlap with
  no-qualified-std's vocabulary and its findings (98 ArrayList, 1 allocPrint) never share a line - and the vocabulary
  doc already said "until that rule folds in". Folded (16 names; the rule retired; build.zig's LintRule field and list
  entry removed; a test). With today's walker the fold adds 132 findings (ArrayList in signatures/fields) - so it rides
  L4b. The package is one patch now, src/notes/lint_l4b.patch (two files, verified). First unit-test run of the
  complete walk: 3/96 fail - the coverage test must flip; two no-qualified-zm tests break because `zm.Vec3` in a
  signature is now seen (Vec3 IS a keyword; the test predates that) - a scope decision for Simon (bodies only, or
  everywhere). Also: no-qualified-zm's fix cannot insert a missing binding (L3 overstated autofixable).
- **Oct 2 - zm keywords bare EVERYWHERE (Simon); no-qualified-zm gets a two-pass binding fix.** In the L4b package:
  the rule's wording, catalog, docs updated; tests 69/70 corrected (70's "Vec3 is not a keyword" predated Vec3
  becoming one), a test pinning the decision; the coverage test flipped; the long line wrapped - 97/97. Then the fix:
  missing binding inserted at `bindingInsertOffset` (std's insertion point, generic in its roots - renamed), the
  next pass drops `zm.`; skipped when the name is declared in the file (`declarationCount`) - a collision no parse
  check would catch. Tests + a negative control (no guard fails exactly the collision test). 99/99. Patch refreshed
  (verified). Real tree untouched this turn.
- **Oct 2 - Every fixable lint finding names the command that fixes it.** `printIssues` appends
  ` - autofix: <command>` when a finding has a fix and returns the count; the summary prints "K of the findings can
  be fixed automatically: <command>". `--fix-command` (zimr's build: `zig build fix`; default: rerun with --fix).
  Apps had no fix step - added to the project helper (lint --fix, then zig fmt over the lint dirs; `LintOptions.fix`
  / `.fix_command`); verified via the template's `zig build -l`. Ad-hoc "(`--fix` ...)" phrases removed from
  messages. 96/96, self-lint clean, `check` 358/358; the L4b package rebased cleanly, 100/100.
- **Oct 2 - The package re-measured: 2009 findings, 1849 autofix, 159 by hand in 37 files.** Fixability read off
  each finding's new marker. One by-hand finding was codecs.zig's file-level `lint:off prefer-std-alias`, now naming
  no rule - I had said no such directive existed; my search had been cut at 20 lines. Its deletion joins the package
  (3 files); without it codecs.zig's 106 findings are all autofixable. runtime.zig's 9 zm findings are the collision
  guard at work (per-struct bindings). Patch verified.
- **Oct 2 - The L4b dry run found two real fix bugs.** One --fix over a fresh copy: 1368 edits, nothing visibly
  refused; fmt; ast-check 719/721 (2 pre-existing notes excerpts); re-lint: 642 still fixable, and a second run applied
  zero edits to the 21 files holding them - silently, while still printing "can be fixed automatically". (1) Bisected
  (codecs.zig; a scratch diagnostic: no single culprit, a combination of 81): collectFixes sorted by start only, so
  two names' identical binding insertions interleaved and slipped past the adjacent-duplicate check - a redeclaration,
  the guard discarded the whole pass. Fixed in the package (sort by start, end, text), test + negative control,
  101/101. (2) A drop-`zm.` rewrite above an existing late binding (wgpu_app.zig: binding at 1768, use at 1312) made a
  decl-order violation - next: rewrite only below the binding, else report. Also next: make rollbacks loud.
- **Oct 2 - Both fix bugs fixed; the L4b dry run converges in one `zig build fix`.** (2) rewrites only below the
  binding (fileScopeBinding returns its token; above it, a by-hand "move that binding up"). Robustness: a breaking
  pass falls back to applyFixesGuarded (one at a time from the last, keep what stays clean, refuse the rest), with an
  honest report and "refused here - by hand" hints. Tests + 2 negative controls; package 103/103. Dry run again: 2079
  edits in one run (1368 before), ast-check clean but the 2 pre-existing excerpts, re-lint 160 by hand + 1 refused
  float-from-int (features_test.zig) - nothing else fixable, no decl-order. Next small thing: float-from-int should
  only offer a fix that resolves.
- **Oct 2 - L4b landed; lint then commented out at Simon's request.** Patch applied (103/103); `--fix` exits 0
  unless an input failed; prefer_decl_literal joined the rules (Simon: "same line" = one logical line, so a split
  declaration still names its type - L5 retired). `zig build fix`: 3094 edits in 270 files, 1 refused, fmt clean.
  zimrlint.zig's own 12 new findings fixed (reorder tool for the decl-order; dead isStdRoot removed; 10 locals
  typed). Baseline 160. The gate failed on lint: the build's paths are `./src/...`, the baseline's `src/...`.
  Simon: comment out all of zimr_lint_rules for now - done (53 lines; `zig build lint` passes). Open: compile and
  tests of the fixed tree (never reached), tutorial folds, and the baseline's paths before re-enabling.
- **Oct 2 - Lint re-enabled; the fixed tree compiles; GATE 406/406.** Rules restored; baseline regenerated via
  `zig build lint -- --write-baseline` (the build's ./src paths; 163 findings). check: only doc_folds failed (stale
  excerpts) - regenerated, 358/358. Gate: template's build.zig still enabled prefer_std_alias (missed by a search cut
  at 20 lines - again) - removed; robots.html quoted 4 rewritten lines - updated; the template's lint then found
  `zm.Camera3D` in a signature - fixed by its new `zig build fix`. Gate 406/406, all tests passing. Lesson kept: a
  search I rely on must never be cut short.
- **Oct 2 - L4c begins; a linter bug first.** entities.zig reported `pub const TagEnum = ...` in a file-scope
  `union(enum)` as an untyped local: L2's isContainerDeclTag edit had landed in checkAnonReturn (an anchor on a
  shared switch tail; one match, wrong function), so tagged-union members took the generic descent and were linted
  as statements. Reverted checkAnonReturn exactly; added the tags to isContainerDeclTag, verified in place; a
  regression test (104/104); check 358/358; baseline 163 -> 161. Next: entities.zig's 36 by hand.
- **Oct 2 - L4c batch 1: entities.zig, 36 by hand, one compile.** Types read from each local's source (iterators,
  slots, handles, comptime `type`s, `@FieldType` for the generic field read); `bytes` no longer the address of a
  temporary slice; `CompFlag.max` -> `CompFlag.capacity`. ast-check caught an ambiguous `Iterator` (named both
  ArchChange's and CmdBuf's) -> `ArchChange.Iterator`. check 358/358; baseline 161 -> 125.
- **Oct 2 - L4c batch 2: gpu/zn_conformance.zig.** 11 useless-error-return were function literals
  (`struct { fn f ... }.f`) whose `anyerror!void` the table's `cpu` field dictates - fixed in the linter
  (`isFunctionLiteral`, test + negative control), not by 11 lint:offs. 5 locals named `vec` (zm's word) ->
  `output_row`. check 358/358; baseline 125 -> 109.
- **Oct 2 - L4c batch 3: utils.zig, 14 untyped locals, one compile.** The bounded array's locals typed from their
  sources (`T`, `*T`, `[]const T`, `usize`, `Self` via `.init`, `[]T` from the aligned `slice()`), `newlen` ->
  `new_length`. check 358/358 first try.
- **Oct 2 - L4c batch 4: zimrnum.zig.** `sumValid`'s anonymous return named `ValidSum` (+ reference row);
  attach results typed by their own nested `Attached` (qualified - plain would be the block's); Chain's loop names
  `Layer` via @FieldType; three int-from-float by intent (`@round` throughout - one was already rounding); the
  split DataLoader declaration made a decl literal. zn-zimrnum 325/325, check 358/358; baseline 95 -> 84.
- **Oct 2 - L4c batch 5: runtime.zig.** The merged file's namespaces each re-bound zm names (old files' imports);
  seven bound once in the header, ten per-namespace copies removed, then the autofix made the 9 uses bare. check
  358/358. Simon: dedent code shared in chat (it renders with only the first line at the left).
- **Oct 2 - L4c batch 6: shader_runtime_wgpu.zig, 7 untyped locals, one compile** (check 358/358 first try).
- **Oct 2 - L4c batch 7: int-from-float, 29 sites.** Colours round (ranges checked), pixel sizes round, sample
  indices floor - and robot.zig's `steps = 1.0 / dt` rounds, fixing a latent bug: in f32 1/(1/500) = 499.99997, so
  the integrator test's "one second" was 499 steps. check 358/358; test-fast 622 passed.
- **Oct 2 - L4c batch 8: the last 14 untyped locals.** `held()`'s anonymous struct named `HeldSteps`; compute_host's
  `dst` pointers name `field_name` first; jobs' kernel loop gets an explained lint:off (each kernel its own fn type).
  check 358/358, test-fast 17/17; robot-mocap tutorial 1 fold. Baseline 39 -> 25.
- **Oct 2 - L4c batch 9: clamp-pattern, 7 sites -> `clamp(v, lo, hi)`** (exact for every number - the nestings differ
  only on NaN, impossible at these sites); the Julia colours also round (batch 7's convention). check 358/358,
  test-fast 612.
- **Oct 2 - L4c batch 10: the robot family, and a cascade.** normalize -> normalizeObservations, round ->
  simulateAndTrain (tests, examples, tutorial fold key), sin(2 pi t) -> sinTurns(t), an explained lint:off for a test's
  best-effort cleanup. Two useless `!` dropped; their callers' `!` then went useless - learn, iterate, setParameters
  followed; 10 test `try`s and two examples' dead error branches gone. check 358/358, test-fast 612, doc-sync 0.
- **Oct 2 - L4c DONE: the baseline is empty.** The last 12: frame indices named (floor), a count taken from its
  integer, two split decl literals, assertUnreachable, one file-scope builtin, wgpu_app's Vec2 binding moved up,
  named f32 locals instead of `@as(f32, @floatFromInt(...))` where zm is absent. Full gate 406/406, 618 tests.
  172 by-hand findings in ten batches; two linter bugs fixed; one latent test bug fixed.
- **Oct 2 - L6 investigated: a census of every decl-literal call.** 3577 in 230 files, 95.7% in view (typed
  declarations, split ones included). The converse rule would flag 143: member assignments 84, literal fields 23,
  local assignments 19, elements 9, arguments 7, a return. Vocabulary covers 31 of 52 names - every memory-owning
  constructor. Census kept as src/notes/l6_census.patch. Decisions open: assignments; std value constructors as
  arguments (.of, .limited, .fromByteUnits); `.empty(...)`; the fix style.
- **Oct 2 - L6 decided and built: `constructor-in-view` (advisory).** Simon: simple, no dependence on type or variable
  names, assignments in. A constructor-like decl literal only as a typed declaration's value (branches included);
  spell the type everywhere else. Tests + negative control, 108/108, check 358/358. Tree: 143 in 34 files, matching
  the census. Next: fix them in batches, then graduate it into zimr_lint_rules.
- **Oct 2 - constructor-in-view refined to BARE words.** Simon: `.initBozo(gpa)` is fine anywhere; bare `.init` is the
  problem. The 15 words now match whole; compounds carry their own words. Tests + negative control, 108/108, check
  358/358. Tree: 136, all `.init(`.
- **Oct 2 - constructor-in-view burn-down, batch 1: robot_gym.zig, 28.** Each assignment spells its field's declared
  type. check 358/358 (3 robot-mocap folds regenerated), test-fast 612. 108 left.
- **Oct 2 - constructor-in-view batch 2: zimrnum.zig, 13.** Rule refined: elements of the array a typed declaration
  declares are in view (`var graphs: [2]Graph(f64) = .{ .init(arena), .init(arena) }`) - struct-literal fields stay
  flagged. Seven lines spell their type. zn-zimrnum 325/325, check 358/358. 95 left in 32 files.
- **Oct 2 - constructor-in-view batch 3: robot_supertrack, robot_latent, robot_geno - 32.** Simon confirmed the array
  refinement. Each assignment spells its field's type. check 358/358, test-fast 616, 2 robot-mocap folds. 63 left.
- **Oct 2 - constructor-in-view batch 4: codecs, robot_sac_track, robot_world - 16.** check 358/358, test-fast passed.
  47 left.
- **Oct 2 - constructor-in-view DONE and enforced.** The last 47 in one pass (each type from its declaration, the
  doubtful ones checked by hand); one more gap fixed in the rule (a field's default value names its type); the rule
  joined zimr_lint_rules, no longer advisory. Tested once at the end: zimrlint 108/108, tree 0 findings, full gate
  406/406 with 619 tests. Nothing to fix.
- **Oct 2 - L4d: the coverage guard.** `--coverage` now fails on any unwalked node (with a summary); a
  `lint-coverage` build step over exactly lint's files; the gate runs it. Tree fully covered (58 s); a blind linter
  makes it exit 1 (negative control). The lint arc is closed: complete walk, empty baseline, constructor-in-view
  enforced, coverage guarded. Next: RL B3.
- **Oct 3 - Review of the last RL turn (B2b) and the plan; the next three turns made precise.** B2b stands (torch's
  formula with jax's masks, known answers, controls, 18d.14). Read from BMPC's torch source (still in /tmp/bmpc):
  the planning scorer (_estimate_value), acting (_plan: 24 policy trajectories fixed in MPPI's first rows, a
  score-weighted elite draw, target = (elite's first action, std[0]), + std[0] eps, clamp, warm start), the value
  target (td_horizon policy steps from the TRUE latents through the TARGET heads; NO terminal handling - the gate
  must use fixed-length episodes), the update's order (WM loss / H, / H, / (H num_q); one clip 20 over all model
  parameters; encoder lr x 0.3; then the policy on the rolled latents, detached; then the target follow), and the
  defaults (config.yaml). `Mlp.apply` needs a Graph: acting builds one inference graph per act. Plan: TURN 1 B3a
  acting (robot_bmpc.zig), TURN 2 the replay row + world-model update, TURN 3 the policy update + update(); then
  B5 (reanalyze, schedule, cartpole gate) and B6.
- **Oct 3 - B3, turn 1a: `LatentPolicyPlans` - the policy's own plans for MPPI.** The review's "missing scorer" was
  wrong: LatentPlanScorer exists and is _estimate_value. What was missing - the policy's plans for Mppi's reserved
  rows - is built in zimrnum beside it (built once, frozen, the draw between recomputes, only the policy rows
  written). Bit for bit against a row-by-row reroll; two controls each failing exactly their test. Mistakes the
  tests caught and I fixed: `try` on `at2` (not an error union), `.init(seed)` arguments (constructor-in-view, on
  my own new code), the tutorial fold (derived from `zn.` names in examples, not hand-written). zimrnum 329/329,
  check 358/358, tutorial 18d.15. Next: robot_bmpc.zig - Config, Networks, act.
- **Oct 3 - B3 turn 1b: robot_bmpc.zig - BMPC's networks and ACTING. Turn 1 complete.** `Bmpc(T)`: Config,
  Networks (zero-last heads, cloned target heads), Actor (plans + scorer + Mppi, frozen), `act` (plans into the
  search; Mppi.plan noise-free for the replay target; Mppi.explore - extracted from choose - for the action). Four
  known answers, two controls each failing exactly its test. Caught on the way: `.init` bare in assignments and a
  return (constructor-in-view), `std.mem.eql` qualified, four long lines, `zn.scalarClamp` not public (the test now
  clamps with zm.clamp - an independent clamp), a control whose mutation broke the syntax (redone). zimrnum
  329/329, test-fast 616 (+4), check 358/358. Next: turn 2 - the replay row and the world-model update.
- **Oct 3 - The linter dogfooded; the write-first checklist; B3/B4 turn 2a: the replay row.** `-Dautofix` (its
  comment said default true, its code false) is now on: lint --fix -> zig fmt -> lint (check) -> compile, and lint-check
  / check see the fixed tree - a planted fixable finding was repaired by plain `zig build check` (file byte for byte
  restored), a planted untyped local failed it with the finding named. A false lead (findings "missing": my `> f 2>&1`
  capture let the build runner's summary overwrite them) cost a detour; logs are now captured stream by stream. The 44
  by-hand rules are a checklist in the plan's standing rules. Then the Row (BMPC's layout, each row its own successor,
  done = terminated or truncated, the empty target N(0, 1)): 4 known answers, a control failing exactly the two it
  should; SequenceReplay's doc and 18d.9 follow. Written lint-clean first time. test-fast 620, check 360/360.
- **Oct 3 - B4, turn 2b1: the value targets.** `zimrnum.LatentValueTargets` - the policy's lookahead from each stored
  step's true latent, through the model, closed by the TARGET heads' averaged value (BMPC's _td_target_V) - and
  `TanhMeanGaussian.draw`, the draw's one definition (the plans use it now). Bit for bit against a row-by-row reroll
  two steps ahead with two heads; zero heads give zero; seeds; refusals; two controls each failing exactly the
  bit-for-bit test. The autofix fixed one signature itself; one long line by hand. zimrnum 333/333, check 360/360,
  tutorial 18d.16. Next: the world-model update (turn 2b2).
- **Oct 3 - Review, and the BMPC chapter made a course.** Review of the last turns' code: one stale comment (robot_bmpc's
  "what is here so far" predated the Row) and Mppi's header not mentioning `explore` - fixed. Tutorial: the chapter
  intro now promises the whole agent; 18d.0 the course map (the two loops, every box a section); figures with worked
  examples in 18d.9 (a window across an episode end), 18d.13 (the draw: clamp, not squash - 0.8 + 0.45 = 1.25 -> 1),
  18d.15 (one state's 512 candidates, 24 fixed, 6 rounds, the elite drawn), 18d.16 (a value target: 0.5 + 0.9 x 2.5 =
  2.75); new 18d.17 (one decision assembled: three phases, the warm start [0.2, 0.5, -0.1] -> [0.5, -0.1, 0], the
  exploration 0.6 -> 1.05 -> 1.0 with (0.6, 0.3) kept; act's real code). Every figure rendered and looked at before it
  shipped (Playwright) - which caught overflowing text, colliding labels, missing arrowheads (marker-end marks only a
  path's last segment), a cut-off canvas and one misleading arrow - and checked again on the built page. Code comments
  gained the same in ASCII: the two loops, the window, the block layout, the 2.75 target, the draw, explore. check
  360/360.
- **Oct 3 - B4 turn 2b2: the world-model update. Turn 2 complete.** `WorldModelLearner` in robot_bmpc.zig: windows laid
  out with each step checked against its own successor, value targets from the target heads, the masked loss, ONE
  clip over everything, two Adams (encoder at 0.3), the target heads' 1% follow. Three known answers (the layout by
  hand; the clip exact, Adam's first step at the rate, the follow by hand; same seed same update) passed first
  compile; two controls each failing exactly the one-update test. Written lint-clean with the dogfooded loop (the
  autofix split a signature and removed two unused constants; long lines rewritten around a `rowOf` helper).
  Tutorial 18d.18 with two figures, rendered and checked on the built page. test-fast 623, check 360/360. Next: turn
  3 - the policy update and `update()`.
- **Oct 3 - B4 turn 3: the policy update and `update()`. B4 complete - BMPC can act and learn.** PolicyLearner on its
  own graph (latents copied as numbers from the world model's forward pass, the planner's means and log spreads from
  the rows, the running KL scale, its own clip and Adam), Learner (pretraining skips the policy), discountFor. Five
  known answers passed first compile; three controls each failing exactly their own test. Lint findings while
  writing: one zm core-word shadow (`length` -> `episode_steps`), two long lines. Tutorial 18d.19 with two figures,
  checked rendered and on the built page. test-fast 628, check 360/360. Next: B5 - reanalyze, the warm-up schedule,
  and the cartpole gate.
- **Oct 3 - B5a: reanalyze.** Built as what it is - a decision: an Actor with the policy's plans at the exploration
  bounds, every state a first step, evaluated; answers written into the replay and the batch, between sampling and
  learning. The world-model update split into sample + learn without changing a number. A first control went
  undetected - fresh networks score every candidate alike, so the decision could not see the bounds; the test now
  compares the candidate block. Another run looked like a pass but was a compile error read without its summary.
  Both lessons in the plan. Tutorial 18d.20. test-fast 631, check 360/360.
- **Oct 3 - Review of the policy update and reanalyze.** Re-checked against BMPC's source: the policy trains on
  zs[:-1] (z_0 .. z_(H-1)), and our row t's own target pairs with z_t as torch's row t + 1 does; no bugs found.
  Simplified: the policy's targets written by whole rows; reanalyze as two symmetric step x window loops
  (`state_index`, `batch_row_index`); `Learner.update`'s `reanalyzing`; `discountFor` reads as an effective horizon
  n = L / 5 (BMPC's (n - 1) / n form kept for exact clamped values); renamed fields (`reanalyzed_windows`,
  `target_rows`, `discount_horizon_divisor`). Comments, test names, 18d.19, 18d.20 and their figures rewritten in a
  plain book tone; the file header's stale "lands next" and a plan reference in Config removed. test-fast 631 after
  the refactor; two controls re-planted on the new loops, each caught (one first failed to compile - read from its
  summary). check 360/360.
- **Oct 3 - Investigation: splitting RL out of zimrnum.** Measured with a repeatable script
  (src/notes/scripts/zimrrl_split_analysis.py): 58 public declarations, 29 private helpers, 94 of 333 tests, about
  9,470 of 40,907 lines move; nothing that stays uses a moved name once the two PPO losses stay (Graph's PPO
  operation calls them). The linter's canonical-alias rule already supports a `zrl` module. Callers: 9 source files
  and the robot-mocap tutorial's quotes. Found two orphaned doc fragments and a stale header claim about the GPU
  sweep. The staged plan (S0 - S4) is in the plan, ahead of B5b.
- **Oct 3 - The direction settled; split stage S0 done.** Simon asked what Graph knowing PPO means for RL on the GPU.
  Findings: `ppo_clip` is Graph's only algorithm-named node kind (30 kinds; the distribution helpers are already
  compositions) and can be composed from generic nodes with PPO's exact gradient; the GPU side has no autograd -
  hand-written kompute kernels run by compute_host - and zimrnum's GPU half holds 4 RL kernels. Plan amended: S0b
  takes PPO out of Graph, S1b gives zrl its own GPU half (`wants_zimrrl`), so generic code never knows an RL algorithm
  on either side. S0: two detached doc blocks returned to `saveParameters` and `PpoStats`; the header states the
  sweep's five RL rows; the baseline recorded by name (439 public, 333 tests, 784 rows). zn-zimrnum 333/333, check
  360/360.
- **Oct 3 - Safari: "'texture_2d<f32>' cannot be used as the type of a 'let'" (shapes_fs, every 2D page).** Simon tried
  zimr on an iPad. Cause: spv2wgsl's `emitLoad` bound every load with `let`, including texture and sampler HANDLES;
  WGSL requires a `let`'s type to be constructible or a pointer. Chrome accepts it, Safari enforces the
  specification. The translator's own guard `checkNoHandleValues` listed `let` of a handle as legal, and its test
  expected it. Fix: a handle load binds nothing (the result id names the module-scope variable; uses substitute it);
  `markHoistedResults` never hoists a handle; `checkNoHandleValues` now refuses a handle `let` (runs on every
  translation, so the build fails on a regression); its doc and test corrected. Two docs merged above it went back to
  `checkBarrierUniformity` and `checkNonFiniteConstants`. Verified: `zig build test` 431/431 steps (2028 tests); 125
  regenerated WGSL files, 0 handle lets; the shapes shader now samples `textureSample(texture0, texture0_sampler,
  uv)`. Note: build.zig's comment describes a `wgpu-check` step that does not exist. Safari stops at the first error -
  re-test on the iPad for any further spec difference.
- **Oct 3 - Split stage S0b: PPO leaves Graph.** `PpoClipLoss(T)` builds PPO's clipped surrogate from generic graph
  operations; it matched the fused node to 1e-12 in value and gradient in every clip regime before the node was
  removed. Graph now names no algorithm; with the PPO loss family classified as RL the split analysis reports no
  blockers. Ported PpoModel, ppoUpdate, robot_gym, the tests, the tutorial passage (rewritten in the plain tone) and
  robot-mocap's quotes; stale reference notes for the removed API deleted. Docs written for cartpoleOutcome and
  ppoEpoch. A full disk (98%, 7.7 GB of build cache) first showed as a cache error; cleared. test-fast, check
  360/360, doc-sync, zn-zimrnum 333/333.
- **Oct 4 - Split stage S1a: zrl as a facade.** src/zimrrl.zig re-exports the 61 moving names; the zrl module is wired
  beside every non-kernel zn import; seven source files, the robot-mocap tutorial's quotes and one zn_mlp comment now
  spell the moved names `zrl.`. Two slips caught by the checks: the build script's pattern first matched the new
  module's own zn import (an assertion stopped it before writing), and the caller script also rewrote the facade
  (restored from its backup). test-fast unchanged, check 360/360, doc-sync. Finding for S1b: zn_mlp.zig holds SAC and
  SuperTrack kernels, so the GPU half needs a full inventory, including a third home - the robot's GPU code.
- **Oct 4 - S1a verified after a session restart.** The restarted session found S1a's work on disk and recorded in
  the plan, re-checked it independently (the facade re-exports exactly the analysis's 61 names; only zn_binary and
  the GPU probe still spell moved names with zn., as planned for S1b; every touched file lint-clean), then ran the
  pending full gate: 410/410 (GPU modules, the SPIR-V probe, every example). While the gate ran: the S1b inventory -
  zn_binary's 4 RL kernels, and in zn_mlp 8 PPO / SAC kernels (zrl's half) and 5 SuperTrack kernels (a third home,
  the robot's GPU code); `wants_zimrrl` must be opt-in per kernel.
- **Oct 4 - S1b scoped and S1b-1 done.** Reading the dispatch: `compute_host.Compute(M)` serves one kernel module, and
  a trainer dispatches its generic and RL kernels through one pipe in one submission. So zn_binary's 4 RL kernels
  (which call zn formulas that become zrl's) move now, through the sweep only; zn_mlp's 13 RL kernels (no import of
  zrl) wait for a kernel-set design (S4b). S1b-1: the build and the shader pipeline learned `wants_zimrrl`; check
  360/360. S1b-2's steps are written out in the plan.
- **Oct 4 - S1b-2: zrl's GPU half.** The four RL kernels moved from zn_binary.zig to src/gpu/zrl_binary.zig (the
  ABI copied, the kernels calling `zrl.`), attached to the sweep page with `wants_zimrrl`; the page has a fourth
  pipeline and a compile-time check that the two files' Buffers and Params match field by field; the conformance table
  has `Kind.rl_binary`; the GPU probe imports zrl. On the way, three generic kernels' docs that had been stranded above
  cartpole_step's went back to their owners. The gate passed but did not build the sweep page - found by looking for
  the new WGSL and not finding it; the focused page build exposed a type-info API change in the new check, fixed, and
  a control showed the check fails on a mismatch. zn_binary no longer depends on any RL name.
- **Oct 4 - S2: the doc tool handles several libraries.** zimrnum_ref now reads a `Library` table; every page's
  examples are matched against every library's alias, so a page can fold and arity-check calls into either library.
  Restructured textually so main's comments moved with its body. Proof of no behaviour change: the tutorial is
  reproduced byte for byte, three runs. check 360/360. Next: S3, the move itself.
- **Oct 4 - S3b: the split is applied.** zimrnum.zig 40,907 -> 31,350 lines; zimrrl.zig 9,891 lines with 61 public
  declarations and 95 tests, a fast test root of its own. The compiler found what the static analysis could not: two
  private members reached across the new file boundary (DiagGaussian.half_log_tau, PpoClipEval.loss), made pub by
  rules in the script. All suites green (zrl 95/95, zn 238/238, test-fast, check 360/360), and the script reproduces
  the tree byte for byte from the backups. The RL chapters' folds wait in zimrnum's tutorial for S3c.
- **Oct 4 - S3c-1: zimrrl's documentation machinery.** The tutorial check became one shared helper
  (`zn.expectReferenceTableMatches`) used by both libraries; zimrrl has its own check, ASCII scan and suffix scan; a
  first zimrrl-tutorial.html with a generated 139-row reference table; the doc tool documents both libraries. A
  control (one row removed) fails zrl's check by name. Next: S3c-2, moving the RL chapters.
- **Oct 4 - S3c-2: the tutorial split. The zimrnum / zimrrl split is complete.** The RL chapters moved to
  zimrrl-tutorial.html (chapters 2-4, reference 5) by a script that finds blocks by id, renumbers references and
  figure labels, leaves pointers in zimrnum and retargets links across the two pages; its invariants (every id kept,
  every link resolving, no old numbers, no stale zn. spellings) and both pages' heading numbering held. Folds are
  conserved (285 + 63 = 348). All suites, doc-sync, the sweep page and the gate (412/412) green. Next: B5b.
- **Oct 4 - RL tutorial organisation, step 1.** Read the whole tutorial: chapters 2 and 3 were two generations of the
  same material (terminal/truncated three times, PPO's clip three times, replay and cartpole twice), with development
  history and testing detail. Reorganised by the library's layers into ten chapters (a first agent, environments,
  experience, policies, on-policy, off-policy, imitation, world models, reference) by a script that moves sections
  whole by id; duplicates now sit side by side for the merge step. All checks green. Next: merges, then prose.

- **Oct 4 - RL tutorial organisation, step 2.** The four duplicated topics are one section each: how an episode ends
  (3.3), rollouts and replay (4.1), GAE with its recurrence (4.2), PPO's clip (6.1); the absorbed sections' ids stay as
  anchors. ppoClipSample's quoted body matched the source again (it still showed zimrnum's scalarClamp). All checks
  green. Next: the prose pass.
- **Oct 4 - RL tutorial: 20% shorter, neutral, three new figures.** Prose 13,797 -> 11,034 words, chapter by chapter:
  history and test detail out, measured blocks stated as expected values, repeated explanations replaced by links.
  New figures: the run loop, terminal vs truncated, PPO's clipped objective. Found on the way: a stray fold closing
  marker inherited from the old zimrnum chapter, and figure colours that vanished without the page stylesheet - both
  fixed. All checks green.
- **Oct 4 - znum history removed from source and tutorials.** 371 lines in 14 files at the start. The parity tool
  (whose purpose was parity with znum) and its build step deleted; every comparison rewritten to explain the design
  directly rather than deleted; the tensor file magic is now "ZIMR\0\0" (no saved files existed). On the way: the PPO
  doc chain in zimrrl.zig returned to its owners, a false `exp` doc removed, stale facts fixed (Transition's
  `seam`, the cartpole angle in turns, the reshape -1 claim), a broken MAD sentence and a broken test table row
  repaired. The zimrnum tutorial also lost its stale "What exists" chapter (chapters renumbered). All checks green.
- **Oct 4 - B5b-1: BMPC's schedule.** `Bmpc(T).Schedule`: seeding, the pretraining burst and the steady phase as
  arithmetic over frames, generalised to E environments by holding the update-to-data ratio fixed; one environment
  at ratio 1 is torch's schedule. Four known-answer tests; a control (no rounding) fails exactly its test. Next:
  the loop over a stand-in environment, then the cartpole gate.
- **Oct 4 - B5b-1 reviewed: a real bug in the schedule.** Dividing the seed steps among the environments meant that
  with 8 environments and 200-step episodes, seeding ended after 125 frames - before any episode had ended. Seeding
  now counts frames per environment (five episodes in every one), the burst catches up one update per seeded step,
  and the ratio of updates to data is u from the burst on. The one-environment test could not see the bug (both
  readings agree there); the new tests could, and a control proves it. Comments rewritten as a course, with the
  timeline, the episodes grid and the update-to-data identity drawn in ASCII.

- **Oct 4 - EfficientTDMPC v5 re-read against our code; the plan made sufficient for parity.** Everything in BMPC's
  column of their Table 2 is in place (widths, rates, per-step insertion, evaluation by a drawn elite). The gaps are
  theirs: two planners configured apart (acting H 6 with the multi-horizon mean; reanalyze H 3, 64 / 8 / 3, final
  objective, pessimism), +2 iterations above 20 action dimensions, the value-equivalent dynamics ensemble (training
  and scoring per Appendix D - every candidate under every head, which our earlier guess had wrong), presets. N7 is
  now six stages with known answers, ending with their cross-scoring diagnostic; N8 is their protocol on our tasks
  (DMC-equivalent classics and the early-termination tasks) with explicit success criteria; N8b decides termination
  for TrackEnv by measurement; N9 is the GPU prerequisite. Fixed on the way: zrl's Mppi doc and the tutorial said
  evaluation takes the best elite; the code (and torch) draws one.
- **Oct 4 - B5b-2: the training loop.** `Trainer(Environment)` runs one frame at a time as the schedule says: random
  actions with empty targets while seeding, the planner after; fixed-length episodes cut by truncation with the true
  final observation kept; the burst as pretraining; labelled random streams so the same seeds replay the same run.
  Five tests on a stand-in environment and two controls, each failing exactly its own test. Next: the cartpole gate.
- **Oct 4 - B5b-3: the cartpole gate is built, and it fails.** `zig build bmpc-cartpole` trains a small BMPC agent on
  the cartpole (fixed 100-step episodes, reward 1 while the pole is up) and judges it in the simulator against
  random actions: 0.110 of the steps up trained, 0.153 at random. The leading hypothesis is structural - a 3-step plan
  with a 0 / 1 reward depends entirely on a value function 350 updates do not teach - but it is a hypothesis, so the
  next step is diagnosis (losses, the reward head) before any change to the task or the budget.
- **Oct 4 - B5b-3 reviewed before re-testing.** No wiring bug: the actor reads the learner's tensors live, now
  guarded by a test with a control. The loop keeps its latest update's report. The gate's task now rewards balance
  the way the DeepMind Control Suite does (`zrl.tolerance`, `zrl.cartpoleBalanceReward`, both with known answers),
  since BMPC's three-step plans were tuned for graded rewards; the verdict stays behaviour. The tutorial gained the
  schedule (with a timeline figure) and the training loop. The gate itself is re-run next.
- **Oct 4 - the gate, diagnosed.** With DMC's dense reward: 0.200 up trained vs 0.153 random. Instrumented: the model
  learns (reward and value losses fall; it scores upright 1.79 vs hanging 0.87) but the planner's candidates span only
  0.011 - three 0.02 s decisions are too short for a push to matter, and the value function after 350 updates cannot
  make up the rest. Action repeat 5 widened the planner's spread 30x but made the model's job harder (it barely ranked
  upright above hanging); reverted to DMC's 0.02 s protocol. Conclusion: learning works, the budget is ~100x short,
  and 0.145 s per update for networks this small says the overhead is ours. Next: profile.
- **Oct 4 - profiled, and the first fix.** perf (installed from Ubuntu's archive, software-clock sampling) showed the
  time is arithmetic, not pipeline: matmul 69%. `zn.matmul` gained two fast paths that are bit-identical to the naive
  loop (now `zn.matmulReference`, the specification): the same Neumaier sum per element in the same order, visited
  in the order memory and the vector unit prefer. The profile run went from 58 s to 25 s. Next: `add`'s broadcast
  path, path B's vectorisation, and a decision on the transcendental functions.
- **Oct 4 - a memory leak in the backward pass, fixed.** Simon: approximate activations are fine, and the endgame is
  GPU training, so CPU work stays bounded to what the gates need. Reading the backward pass to fuse Mish found seven
  temporaries taken from the graph's allocator instead of the pass's scratch arena - BMPC hit two of them (softplus,
  concat) on every update, so memory grew with training. Fixed, with a test that counts the allocator's calls (an
  arena's capacity hides small leaks) and a control that fails it. Next: Mish as one node with one exponential.
- **Oct 4 - Mish as one node, with one exponential.** tanh(softplus(x)) = n / (n + 2) with n = e^x (e^x + 2), so mish
  and its slope need one exponential each instead of an exponential, a logarithm and a hyperbolic tangent - the same
  function, accurate in both tails, saturating cleanly. Scalar forms in zimrmath (shader-safe), one tape node in
  zimrnum; checked against the composition, by central differences, and by the graph's own gradient probe.
- **Oct 4 - the agent's memory is flat, and broadcasting is fast.** Two tests now hold a warm BMPC update (reanalyze
  included) and a warm decision to zero allocations, with a control that reintroduces the concat leak. `zip` gained
  a row path for the bias broadcast. The profile run is down to 15 s from 58 s, peak memory from 517 to 352 MB;
  matmul is again the half that remains.
- **Oct 4 - `@divCeil`.** No `std.math.divCeil` in zimr's code. `zm.divCeil` now wraps the builtin (fixing its
  unsigned and minInt cases), and 24 hand-written ceilings in host code and examples use it. The SPIR-V backend does
  not lower `@divCeil` yet, so the three GPU kernel ceilings stay written out, with the reason at each site.
- **Oct 4 - the gate at five times the training.** matmul's vectorised path, register-blocked, is now limited by
  Neumaier's arithmetic itself; the profile run is 12 s, from 58 s. The gate, re-sized to 1650 updates in 3 minutes:
  0.333 up trained vs 0.153 random - learning, not mastery. The model ranks states correctly; the planner still
  cannot separate its candidates, because the value function is too flat after so few updates. Mastery needs BMPC's
  tens of thousands of updates; how to gate it is Simon's call.
- **Oct 4 - decided: no more CPU learning runs.** The plan continues - B6's review, EfficientTDMPC's additions, the
  GPU kit - towards an overnight WebGPU training, where the agent must learn to balance (and later to track). The
  cartpole gate remains as an on-demand check with its diagnosis.
- **Oct 4 - B6a: the networks and the configuration, reviewed.** Both match BMPC (the initialisation included). One
  gap was BMPC's own: two more MPPI rounds from 20 action dimensions - `Config.iterationsFor`, counted as the code
  counts (`>= 20`), which matters for the robot. Next: the world model's learner and the value targets.
- **Oct 4 - B6b: the world model's update, reviewed - no bug.** It is Appendix D's equations 11 to 15 with one
  dynamics head, down to which stored observation feeds each value target. The review also fixed where the ensemble
  enters for N7c: the rollout, the loss and the targets, each once per head.
- **Oct 4 - B6c: the policy update and reanalyze, reviewed deeply - no functional bug.** Checked against BMPC's code
  as recorded (the KL's direction and averaging, the scale's order, reanalyze's settings) and, line by line, the
  layouts where a silent misplacement could hide - writeBack's row order among them. The code gained clearer names,
  named intermediates and diagrams of its layouts. Next: the tutorial's figures for the policy update, value-
  equivalent training and reanalyze.
- **Oct 4 - two figures for the tutorial.** 9.14 shows why the divergence puts the policy first (two disagreeing
  answers: averaging between them versus committing to one), with the closed form worked through; 9.18 shows
  value-equivalent training as three rows - targets from the true latents, heads scored on the rolled ones. Next: B6d,
  the actor.
- **Oct 4 - B6d: the actor, reviewed deeply - no functional bug.** Every point of BMPC's planner checked, down to
  the spread's reset at every call and the cleaning of non-finite scores before ranking. The actor's doc is now a
  course with a diagram of one decision; its fields have clearer names. The review of the assembled agent is
  complete; next its last tutorial figure, then EfficientTDMPC's two planners (N7a).
- **Oct 4 - B6 complete; N7a-1: two planners.** The planner's settings are now a `PlannerConfig`, and the agent has
  two - one to act, one to reanalyze - while `Config.horizon` is only the training window. Today's numbers are the
  defaults, so every decision is unchanged; a new test shows a six-step acting planner leaving the training window
  and reanalyze's planner alone. Next: the BMPC and EfficientTDMPC presets.
- **Oct 4 - N7a complete: two presets.** `Config.bmpc` and `Config.efficientTdmpc` are Table 2's two columns, each
  checked field by field; the tutorial's 9.23 explains the two planners and the two configurations. Next: the
  multi-horizon objective.
- **Oct 4 - N7b: the multi-horizon objective.** Both objectives turn out to be weighted sums of the same rewards and
  values, so the scorer takes an objective and its weights; BMPC's scores stay bit-identical, and EfficientTDMPC's
  acting planner scores a plan by the mean of its prefixes - checked against the paper's definition, computed by
  hand. Next: its tutorial figure, then the dynamics ensemble.
- **Oct 4 - N7b complete: the objective in the tutorial.** 9.7 explains the whole-plan and every-prefix objectives
  with a figure of one plan's three prefix scores, the example of two plans they rank oppositely, and the weights.
  Next: the dynamics ensemble (N7c).
- **Oct 4 - N7c-1: the networks hold an ensemble of dynamics heads.** Head 0 is exactly the single network BMPC had;
  the others start from their own random streams. Until the ensemble trains, the learner refuses more than one head
  rather than leave three untrained. N7c-2's design is settled: zrl's rollout and loss take a list of heads.
- **Oct 4 - the last two turns reviewed.** No stream collision (Rng.split hashes its label), but two real gaps in
  N7c-1 fixed - a zero-head configuration, and the ensemble refusal living one level above the component that trains
  the dynamics - and one wrong worked line in the tutorial (plan A's final objective written with plan B-like terms).
- **Oct 4 - N7c-2: the world model trains through every dynamics head.** zrl's rollout encodes once and rolls each
  head from the shared latent; the loss scores every head's latents and averages the heads' terms - summed then
  scaled once, so agreeing heads give exactly the one-head numbers and BMPC is unchanged to the bit. Two controls
  confirm the tests see a missing average and a head that never rolls its own network.
- **Oct 4 - N7c-3a: value targets through every dynamics head.** The heads' lookahead chains are stacked along the
  rows and share each stored step's noise, so at the first step they all take the one action of eq. 14; the target
  averages where each head leads. Checked against eq. 14 by hand, exact for agreeing heads, and a control shows the
  shared noise matters. Next: the robot trains and uses every head.
- **Oct 4 - deep review of the ensemble code: one real bug, older than the ensemble.** Resampling dropout gave every
  dropout node the same mask, so BMPC's two value heads - at every step - dropped the same elements instead of
  independently. Each node now draws from its own split of the generator, with a test and a control; the loss's own
  dropout streams are unique per dynamics head, step and value head. The rest of the review renamed what had become
  ambiguous (several `head_count`s counting different heads) and named the intermediates.
- **Oct 4 - N7c complete: the agent trains an ensemble of dynamics heads.** Every head is bound, rolled, scored and
  stepped by the optimiser; the value targets average where the heads lead; the policy learns on every head's latents,
  stacked into its batch. One head stays bit-identical to BMPC; two identical heads report exactly the one-head loss;
  controls show the tests notice a head left out of the optimiser or of the policy's batch. EfficientTDMPC's preset
  now has four heads. Planning still reads the first - next, the ensemble's tutorial and its scoring.
- **Oct 4 - the ensemble in the tutorial.** 9.24 explains the dynamics heads with a figure of one encoded latent
  fanning out into three rollouts, each compared with the same targets; the value target and the policy through
  every head; and a stale sentence in 9.23 corrected. Next: scoring plans under every head (N7d).
- **Oct 4 - N10 added: jumpy dynamics, an experiment after EfficientTDMPC's parity.** Simon's idea, discussed: a
  4-step dynamics head (with a 4-step reward output) beside the 1-step one, planning on a fixed 1, 1, 4, 4 schedule -
  ten steps of lookahead in four evaluations. Shared encoder and value heads; a fixed schedule so candidates stay
  comparable; the 1-step head kept for the policy. To be tested on a linear system first, then measured.
- **Oct 4 - N7d: plans scored under every dynamics head.** Each candidate is rolled under every head and bootstrapped
  with every value head; the score is the mean of those estimates, and the variance of that mean is kept for the
  pessimism to come. One head stays BMPC's to the bit; the variance is checked against a hand computation, and two
  controls show the tests notice a missing division and an ensemble silently reduced to its first head.
- **Oct 4 - N7e: pessimistic reanalyze.** The scorer can make a plan pay beta standard deviations of the heads'
  disagreement; EfficientTDMPC's preset turns it on in reanalyze where episodes can end early, never while acting.
  The chosen plan flips exactly at the beta worked out by hand, and two controls show the tests notice a variance
  used in place of its square root and acting reading reanalyze's setting. The build cache was cleared for disk space.
- **Oct 4 - N7f-1: the planner remembers which plan it chose.** MPPI now records the candidate row behind each
  state's answer, and the actor can hand out the whole chosen plan - the first piece of the cross-scoring diagnostic,
  which will compare plans made under one head and under the ensemble against the real environment.
- **Oct 4 - deep review of the ensemble's scoring, pessimism and the chosen plan.** Every layout and order checked;
  one deviation from BMPC fixed - an infinite score now ranks like BMPC's nan_to_num(0) ranks it, so a pessimistic
  score that overflowed downward ranks last instead of being rescued to 0. The scorer, MPPI and the actor gained
  diagrams of their row layouts, the estimate grid and the chosen plan. Next: the same pictures in the tutorial.
- **Oct 4 - ensemble scoring and pessimism, drawn.** The tutorial's scoring section shows one candidate's grid of
  estimates worked through to its spread, the scorer's rows stacked per head, and two plans' pessimistic scores
  crossing as beta grows - the steadier plan overtaking the higher one. Next: the cross-scoring diagnostic's model
  side (N7f-2).
- **Oct 4 - N7f-2: plans scored across models.** The diagnostic plans the same states under one dynamics head and
  under the ensemble and scores both plans and the policy's under both models. Its controls exposed a blind spot:
  BMPC starts the reward and value heads at zero, so every plan scored alike and the first tests could not fail. The
  tests now wake those heads - and the same fix turned a vacuous comparison in the pessimism test into a real one.
- **Oct 5 - R5: a merge of SuperTrack and BMPC, proposed.** SuperTrack is fast because its policy follows the exact
  gradient of a known tracking loss through a learned model - and its three limits (a horizon of one window, a local
  gradient, a gym that resets on falls) are the three goals: robustness to large pushes and get-ups. The proposal
  keeps SuperTrack's loop for the common case and adds BMPC's tools where gradients fail: a pessimistic value tail
  on the pathwise loss, a planner run only on hard states as a teacher, a gym that keeps falls, and re-entry by
  motion matching on the simulated pose. Fifteen options weighed; staged P1-P5 with known answers; runtime stays one
  policy pass.
- **Oct 5 - the north star narrowed and unified, after PHC.** The goal is now the whole two-minute dance, precisely,
  plus realistic recovery back into it - one objective, no switch between tracking and recovering. PHC needed its
  switch because its exponential rewards vanish far from the reference; a cost whose gradient does not vanish
  (SuperTrack's L1) stays informative from the floor, and the value function makes returning worth it. Torque limits,
  mechanical power and a differentiable pose prior over the dance and the get-up capture keep the recovery human.
  R5.7-R5.9 hold the study, the objective and the new judge; the stages gained the objective and the body's limits.
