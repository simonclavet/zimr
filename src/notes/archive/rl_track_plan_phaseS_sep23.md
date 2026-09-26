# Phase S as it stood on Sep 23, before consolidation (the plan keeps the summary)

### Phase S - SuperTrack, made good (on the new robot, on the phone)

**First contact, Sep 23 (Simon: "holding just the T-pose with SuperTrack headless in 3 minutes of CPU?").**
The task's fleet takes any model and clip (`robot_track.Fleet.init(model, clips, options)`, now with a
`floor_friction` option), so the CPU learner (`robot_latent.Learner`) runs on Geno UNCHANGED. Test "S0 -
SuperTrack learns to hold Geno's T-pose" (slow; `-Dslow-tests=true -Dmode=release`, ~4 min with compile):
a 10 s held T-pose (`robot_geno.heldClip`), 8 environments, 1,000 world-model steps, 60 rounds. **Seed 1:
policy 2.67 s mean time to failure against the servo's 1.29 s. Seed 2: 0.43 s** - the world loss climbing
1.0 -> 21, the policy loss to 357. Unstable: as the policy moves the robot off the prefill's states, the
world model diverges and the policy exploits it. S2's recipe (the normaliser from wider data, gradient
clipping, L1 losses, more world updates per round) is exactly the cure to try first, judged over >= 3 seeds.
**S2 begun - recipes (`HoldRecipe`, `holdTrial`; seed 1, ~3 min each):**

| recipe | world loss | policy / servo time to failure |
|---|---|---|
| first: 150 prefill @0.1, world rate 1e-3, window 8 | 5.7 (seed 2: 21) | 2.67 / 1.29 s (seed 2: 0.43) |
| steady: 400 prefill @0.3, world 3e-4 x16/round, policy 1e-4 | 0.119 | 1.29 / 1.29 |
| committed: steady, policy 3e-4 x16/round | 0.150 | 1.29 / 1.29 |
| far-sighted: committed, window 32, action penalty 0.01 | 0.205 | 1.29 / 1.29 |

The world model is STABLE now - but every stable recipe ties the servo EXACTLY: the policy does nothing.
Diagnosis to test next (S2a): the world model has not learned what an ACTION does - the prefill explores at
0.3 of a 0.3 rad authority (~0.09 rad), small beside a topple's own dynamics - so the policy's gradient is
zero and doing nothing is its honest optimum (the first recipe "won" on a diverging model's hallucinated
action effects). **Known answer:** perturb one action by a fixed amount and compare the change in future
pose the world model predicts with the simulator's; then the policy's mean |action| during judging. If the
model is blind to actions: explore wider (a larger prefill noise, or an authority beyond 0.3 rad), or train
the world model on action-rich windows.
**S2a MEASURED - the ties were the yardstick, and the gap is model exploitation.** `judge` divides env-steps by
failures over 300 steps, so it moves only in whole falls (31 falls = 1.29 s): the "exact ties" were integer
counts. Judged over 20 s (`judge_steps`, 4x the resolution), far-sighted recipe, seed 1: **servo 1.19 s (134
falls), policy 1.12 s (143) - slightly WORSE in reality - while inside the model the policy cuts the tracking
loss 1.263 -> 1.013 with a mean action 0.15 of its authority.** The world model is stable but wrong about what
actions do, and the policy exploits it. **Next:** (a) the direct known answer - one action perturbed by a fixed
amount, the model's predicted pose change against the simulator's - to see WHERE the model is wrong; (b) S5,
an ensemble with a disagreement penalty, which targets exploitation itself; (c) wider, action-rich
exploration so the model sees what actions really do.
- **S2b - model-free experience beside the model (Simon's idea).** A SAC-family actor on part of the fleet
  (half its environments, say), every transition into the one shared ring: the world model trains on all of
  it, SuperTrack's policy trains through the model, the model-free actor trains on REAL data only - so it has
  no model to exploit, improves behaviour while the model is still bad, and its entropy-seeking, state-
  dependent exploration is exactly the action-rich data (near balance, near falls) the model lacks. SAC
  already exists (`robot_gym.zig`, over `zimrnum`). **CrossQ first** - batch renormalisation, no target
  networks, one update per step, sample efficiency like REDQ/DroQ at a fraction of the compute (a CPU core,
  a phone); it is H1's critic moved earlier with a second job. **DroQ** (dropout and layer norm in the
  Q-functions, ~20 updates per step) if CrossQ proves unstable. 69 action dimensions are hard for SAC to
  explore, so S0b's reduced space helps it most. **Known answers:** (1) the world model's action response
  against the simulator's (S2a (a)) improves when it trains on the mixed data; (2) real mean time to failure
  over 20 s, >= 3 seeds, equal CPU time: SuperTrack alone, the model-free actor alone, and the mix.
  **Simon: assume the world model is unusable for the first minutes (hours?) - something model-free must
  carry early training.** First step taken: the EXISTING model-free learner (PPO, `robot_ppo_track`) on
  Geno's held T-pose, as the baseline. It needed R8a part 4 for real: DReCon's policy subset was the old
  robot's body NAMES - now `robot_policy.subsetFor(watched, actuated)`, the trainer takes both lists (and
  `gains`, `floor_friction`) as options, and Geno supplies its own (`robot_geno.drecon_watched` /
  `drecon_actuated`: feet, chest, head, forearms watched; spine, legs, upper arms actuated - 30 of 69 action
  dimensions, S0b's reduction already). **Result, 100 s of one CPU core (102,400 steps): PPO 64.0 frames an
  episode against the servo's 62.8** - +2%, nothing yet. Holding a T-pose without balance control is hard
  for both learners at minute budgets. Next: CrossQ (sample efficiency is the point), then longer budgets.
  **SAC on Geno, measured** ("S2b - SAC holds Geno's T-pose", robot_gym's `SacAgent` unchanged, in DReCon's
  layer on Geno): 110 s of one core gave only **12,784 transitions** - each update (batch 128, two critics, an
  actor) costs ~70 ms here, against PPO's 102,400 steps in 100 s - and **61.5 frames an episode against the
  servo's 60.9**: nothing yet. **The table at a two-minute CPU budget:** SuperTrack stable but unhelpful; PPO
  +2%; SAC +1%. None holds the T-pose yet. For the critic family the CPU cannot buy useful sample counts, let
  alone DroQ's ~20 updates per transition: it belongs on the GPU, where `GpuSacOn` already exists. **Next,
  in order:** (1) GPU SAC (`GpuSacOn`) in the same DReCon layer on Geno - samples per second first, then the
  hold; (2) CrossQ's changes on that GPU critic (batch renormalisation, no target networks); (3) the mix with
  SuperTrack's world model (S2b's real claim), judged by the model's action response and real MTTF, >= 3
  seeds, equal wall-clock.
- **S2c - a balance MPC as TEACHER (Simon: "if it works, use its better trajectories to learn the model, or
  kickstart the policies").** BEFORE the GPU work. What exists: `robot_mpc.optimize` (whole-body iLQR, finite-
  difference derivatives) proven on cart, cartpole swing-up and linear systems - never on a humanoid through
  contacts; on Geno that is 75 velocity dims and 69 controls to linearise per knot, through the floor: a
  research project, not a first step. And `robot_mpc.solveBalance`: a linear-inverted-pendulum planner over
  centre of pressure and momentum rate - how real humanoids hold balance. **The rung:** (1) Geno's centroid
  and support polygon from the model (masses R5b, soles R3); (2) `solveBalance` re-planned each frame; (3)
  its plan realised through the servo's targets - ANKLE strategy (the centre of pressure, by ankle pitch and
  roll offsets) and HIP strategy (the momentum rate, by hip offsets) - on `ServoRun`. **Known answers:** the
  T-pose held >= 10 s where the servo alone falls in ~1.2 s; then survival under shoves. **Then its data:**
  (a) the world model trained on MPC trajectories against servo ones, judged by its action response against
  the simulator's (S2a); (b) a policy cloned from the MPC teacher as the starting point for PPO / SAC /
  SuperTrack (MPC-Net, guided policy search), judged by real MTTF from the first minute.
  **S2c, first attempt - capture-point feedback through the ankles** (`ServoRun.balance_gain`: lean = gain x
  how far the capture point `com + velocity/omega` sits ahead of the feet, into both ankles' targets, fore and
  aft; test "S2c - capture-point balance"): **0.92 s at gain 0 rising steadily to 1.02 s at gain 8** - the
  sign is right, the effect 11%. The T-pose does not tip over stiff ankles: it BUCKLES - the instrumented stand
  (S1 f) showed knees and hips yielding from 0.12 s - and no ankle reflex holds a giving knee. **So (h) is
  the blocker for S2c too, and the NEXT STEP:** at t = 0 of the held stand, the servo's torques at hips,
  knees and ankles against the static torques the pose needs on the floor (inverse dynamics with the contact
  forces). Hypothesis: `pdTorques` computes FLOATING-base torques, so the weight the floor carries up the legs
  reaches the joints as a load it never compensates. If so, a servo with gravity-and-contact compensation (the
  measured contact forces' Jacobian-transpose load added to its torques) should hold the pose rigid - then the
  ankle reflex (and `solveBalance` on top) can do its job.
  **Stronger ankles, measured (Simon: "maybe ankles are just not strong enough?").** In the task's servo a
  joint's strength IS its free-flight inertia (torque = inertia x the spring's acceleration, capped at 3000
  rad/s^2); the ankle's is only the foot's. Armature on the ankles adds to it exactly (0.019 -> 0.109 -> 0.509
  kg m^2) and lifts the torque ceiling with it (58 -> 1,528 -> 24,028 N m) at no compute and the same dt - but
  the T-pose holds 0.92 -> 1.15 s at best: the ankles' 58 N m were already about twice a stance's need. Not the
  ankles. The same principle points at the real knob: the knees and hips carry the upper body standing but are
  light in flight - so armature on the whole leg chain is the next cheap experiment, beside (h).
  **THE T-POSE HOLDS (Simon: "find ways to make the T-pose hold").** Strength had to be WHOLE-BODY and joined
  with balance - neither alone works: **armature 2 on every joint + the capture-point ankle reflex at gain 2-4
  rad/m holds the T-pose the full 10 s clip (9.98 s; the servo alone: 0.9 s).** Measured steps: armature 2 on the
  legs alone 1.18 s (reflex 1.48); legs + spine 1.17 s (reflex, gain 4: 7.07-7.72 s); every joint, gain 2 or 4:
  9.98 s. The reflex has a window: gain 8 and 16 over-correct into oscillation and fall (1.57 / 0.90 s). Why
  it works: in the task's servo a joint's strength is its free-flight inertia; armature makes every joint as
  strong standing as the load it carries needs, and a rigid body is what an ankle reflex can lean.
  **NEXT (in order):** (1) the get-up and walk re-measured with armature 2 everywhere (heavier joints swing
  slower - it may cost the fast clips) before it becomes the model's default; (2) armature as a per-joint
  model parameter (`writeModel`), the fixture regenerated; (3) the reflex on the page (a checkbox, a gain
  slider) for Simon; (4) S2c's use of it - the world model trained on its trajectories (action response vs
  the simulator), a policy cloned from it as the learners' starting point; (5) lateral (roll) balance and
  shoves.
  **Back to SuperTrack on the dance, its first 5 s (Simon).** Armature 2 everywhere costs the dance nothing:
  the servo alone keeps up 1.26 s on average against 1.24 with light joints (9 starts, hips within 35 cm) - so
  the learner trains on the robot that can also stand (`dance_armature = 2`; `trackTrial` takes a clip
  source). **SuperTrack, stable recipe, ~3 min CPU, seed 1:** world loss 0.015 (the model fits this data very
  well); in the model the policy cuts the tracking loss 19% (0.0412 -> 0.0334); **in reality the servo alone
  never failed in 20 s x 8 environments (by the fleet's fall criterion) while the policy failed 10 times.**
  Exploitation again - and two yardsticks disagree (ServoRun's "keeps up" 1.26 s; the fleet's "never falls"
  in 5 s episodes). **Next:** (1) a real-simulator TRACKING-QUALITY judge (mean pose error against the
  reference, with and without the policy) - falls alone cannot rank dance controllers; (2) S5's ensemble with
  a disagreement penalty (exploitation's direct cure); (3) the S2c teacher's data.
  **The tracking-quality judge, done** (`judgeQuality`: a fresh fleet, falls AND the mean DReCon reward over
  1,200 steps x 8): **servo 0 falls, reward 0.9504; policy 10 falls, reward 0.8443** - the policy tracks the
  dance 11% WORSE while the model credits it with 19% better. Exploitation, measured on the axis that matters.
  **Next: S5** - an ensemble of world models, the policy's loss penalised by their disagreement.
- **REORDERED (Simon, Sep 23): DATA FIRST, THE MODEL SECOND, EXPLOITATION LAST.** "Spend time building
  trajectories and a good model before the policy tries to exploit it." Our measurements agree: the model fits
  its data (loss 0.015) - but its data is the servo plus small noise, silent on what actions do where it
  matters, and a policy trained through it finds exactly those gaps. An ensemble only DETECTS the gaps; better
  data REMOVES them. S5 is demoted to "only if exploitation survives D1-D4".
  - **D1 - teachers that cannot exploit.** Standing: the capture-point reflex (done, 10 s). The dance: sampling
    MPC over the TRUE simulator - predictive sampling / MPPI, the fleet's parallel environments as its
    rollouts (MuJoCo MPC's recipe for humanoids) - judged by the real tracking reward against the servo's.
    **D1 started (Sep 23).** D2's GPU throughput can only be measured on the phone (the container runs the
    kernels on its CPU), so D1 goes first, on the CPU. Its foundation, done: `ServoRun.Snapshot`, `save`,
    `restore` (positions, velocities, the reflex's memory; warm starts and cached contacts forgotten, as a clean
    start does). **Two 20-step rollouts from one restore: 99 of 99 numbers identical; the restored rollout
    drifts 8.15 mm at the root from the run that never stopped** - the planner's known prediction cost. Next:
    the predictive-sampling planner itself - K perturbed plans over the DReCon actuated subset, H steps each
    from the saved moment, the best one's first action applied; judged by the real tracking reward on the
    dance's first 5 s against the servo's (CPU budget: K 16 x H 15 ~ 240 steps per control step).
    **On the phone (Sep 23):** `geno_track` now runs Geno with `standing_armature` (2) on every joint, the
    capture-point reflex (`geno.Reflex`, shared with `ServoRun`) behind a "balance reflex" slider (0-8, default
    3, acting while "hold T-pose" is on), and a CLEAN restart (warm starts, cached contacts, the bridge's motion,
    the reflex's memory all forgotten). Headless: the refactor still holds the T-pose 9.98 s at gains 2 and 4.
    **Restarts rest ON the floor (Simon: "he jumps up and spins quickly on resets").** A copied pose put the
    walk's feet 16.8 mm INTO the floor; the solver threw them out at 0.21 m/s. `rbt.lowestPoint` (every
    collision shape's lowest point) and `rbt.restOnFloor` (lift the free root to 1 mm clear, never lower) now
    run on every `ServoRun` start and page restart: 0.00 m/s upward. The SPIN only fell 1.09 -> 0.90 rad/s: its
    other cause is starting at zero velocity while the clip moves. **Next:** (1) start velocities from the
    clip (DeepMimic's reference-state initialisation: root and joint velocities by differencing frames f and
    f+1); (2) the same rest-on-floor and velocities in the training fleet's resets (`robot_track.Fleet`, an
    option), since every learner episode starts there - this IS R8a part 5.
    **The easy start (Simon: "initialise and hold the reference's pose and velocities for 3 frames").** Built in
    `ServoRun` (`referenceVelocity` by `robot_mpc.stateDiff`, the engine's own tangent difference; `hold_frames`;
    one lift over the held window). MEASURED, walk frame 60, ten steps after release, root against the
    reference's motion: at rest 0.55 m/s vertical, 0.94 rad/s spin; easy start 0.51 m/s, **2.07 rad/s - worse.**
    Why: `pdTorques` damps toward ZERO velocity (as DReCon's and SuperTrack's servos do), so it brakes limbs
    handed the walk's speed within a few frames, and the braking torques spin the free trunk. **Next, in order:**
    (1) VELOCITY FEEDFORWARD in the servo - damping toward the reference's velocity (an option on `pdTorques`,
    the old robot untouched) - then `reset_hold_frames` 3 (off, 0, until then); (2) the clip's PER-FRAME lift
    (R8a part 5): the copied walk sinks its feet up to 17 mm into the floor on many frames, so the servo fights
    the floor all the time - lift each frame so its lowest point touches, not pierces; (3) both in the fleet.
    **The launch, verified (Simon: "forget the hold; get the velocities right on the first frame; reset at a
    random dance frame and verify").** Test "a launch at a random dance frame": the launch velocities integrated
    one frame land EVERY body within 0.0005 mm of the next frame, at 5 random frames - they are exactly right.
    One REAL step then misses the next frame by 2.7-6.3 mm on average, up to 24.7 mm (a hand) - and launched at
    rest, much the same on fast frames (26.8 mm). The servo erases the launch: critically damped at 20 Hz its
    damping rate is ~251/s toward ZERO velocity, so one implicit 1/60 s step keeps ~1.5% of a launch velocity.
    Gravity alone accounts for 1.4 mm a step. **Next: velocity feedforward in the servo** (damp toward the
    reference's velocity; an option on `pdTorques`, the old robot untouched) - this test is its yardstick: the
    real step's miss should fall toward gravity's 1.4 mm.
  - **D2 - model-free learners on the GPU.** No dynamics model to exploit, and their own weakness (Q
    overestimation) is what CrossQ (batch renormalisation, no target networks) and DroQ (dropout Q-ensembles,
    many updates per sample) were built around. With physics the bottleneck, extracting the most per sample
    matters: CrossQ / DroQ on the existing GPU SAC (`GpuSacOn`) - first its samples/s and updates/s on Geno's
    fleet - and PPO as the robust baseline with a mature GPU path. Judged by real tracking reward and falls on
    the dance's first 5 s, equal wall-clock, >= 3 seeds.
  - **D3 - the world model on the pooled data** (servo, teachers, model-free actors) - judged BEFORE any policy
    trains through it, by its action response against the simulator's (S2a's known answer).
  - **D4 - SuperTrack's policy distilled from the best actor or teacher, then fine-tuned through the model** -
    judged by real tracking reward; if it still degrades in reality, then S5's ensemble.

The limiter is world-model quality per round, not rounds. Each rung is an A/B at one budget: the
world model's held-out loss, the policy's in-model gain, and **the real mean time to failure with
the policy alone** - kept only if it buys minutes.

- **S0 - the new baseline.** The resident learner and the PPO bench re-run on the Geno robot, every
  joint correctable on all three axes (66 actions): the table every later rung adds a row to, and the
  control for S0b.
- **S0b - the action space: correct only the axes that matter (Simon's idea; D22).** The BODY keeps its
  ball joints (R6: hinges would lose captured motion); the POLICY gets fewer knobs. An axis without an
  offset is still tracked in full by the servo, on the reference's own target - it just gets no learned
  correction - so fewer actions cost no fidelity, and buy a smaller space to explore and fewer things
  for the world model to predict. Two measurements choose the axes: (1) **how the joint moves** - a
  PCA of each joint's rotation vectors (away from rest) over the capture library, in its own frame, so
  the axes are the motion's own, not the bone's arbitrary x/y/z (R6's split already misleads: knee twist
  27 deg left, 70 right); keep the components holding ~95% of the variance; (2) **what a correction
  does** - the change in tracking error a few frames on per unit offset along each axis, through the
  world model and checked on the simulator, so an axis that barely moves but matters (an ankle's roll;
  a hand pushing off the floor in the get-up) is kept. **Known answer:** the PCA finds ONE dominant
  axis at each knee (the bend) - a check the method works; then minutes-to-bar on the phone, reduced
  against S0's full space, at equal or better tracking.
- **S1 - the resident learner's weights file** (world model, policy, normaliser, optimiser state;
  versioned, refused by name on a mismatch) and download/upload on `track_train`. **Known answer:** a
  round trip continues a run to the digit, as D14 did for PPO.
- **S2 - the paper's recipe.** World updates per policy update above 1 (ours is 1:1); the normaliser
  measured from the reference clips instead of early flailing; L1 losses weighted by group, gradient
  clipping, ELU, RAdam. One lever at a time.
- **S3 - the filtered action (D17)**, `y = 0.2 a + 0.8 y_prev`: the fleet records the APPLIED action,
  the filter is a second carried state in the rollout, and the policy sees `y_prev`.
- **S4 - mirror symmetry.** Every recorded window also stored mirrored - exact on Geno, which is
  symmetric by construction. **Known answer first:** the mirror of a simulated step equals the step of
  the mirrored state, to float noise. Then the A/B.
- **S5 - an ensemble world model with a disagreement penalty** (3-5 members; the policy's loss pays
  for their disagreement), the standard answer to a policy exploiting its model. **Known answer:** the
  disagreement predicts real drift on held-out windows. Then the A/B.
- **S6 - failure-weighted starts** (hard-negative mining): reset frames drawn in proportion to recent
  failures, with a floor. **Known answer:** the failure histogram flattens.
- **S7 - longer windows.** Re-measure drift after S2-S5 and lengthen toward the paper's 32, re-anchoring
  an imagined state on its record when it drifts past a bound (DiffMimic's demonstration replay).
- **S8 - the phone gate.** The get-up tracked without a fall at mean body position error < 10 cm (G1
  relaxed), minutes-to-bar against PPO's on the same device; the phase's full gate and chapters.

