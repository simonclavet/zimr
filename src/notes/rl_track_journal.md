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

