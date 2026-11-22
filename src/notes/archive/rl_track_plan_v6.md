# SuperMimic, EfficientTDMPC and FlowDPG in one system - the tracking plan (v6, Nov 2 2026)

v5 (Oct 31) - its turns T1-T5 done, and the first reading of Uni-SuperMimic - is `archive/rl_track_plan_v5.md`, v1-v4
before it; the day-by-day account is `rl_track_journal.md`. The simulator the tracker is to train on is
`robotgpu_plan.md`'s. This file says what the one system is, what each of its parts still lacks, and the order of the
work.

## 0. The goal

A character tracks a minute of motion capture - dance, get-up, walk, run - as precisely as SuperMimic tracks its forty
LAFAN1 clips. Where SuperMimic's episode ends, at a loss, ours goes on: pushed hard or fallen, the character finds its
way back to where the reference has got to, inventing the get-ups the mocap does not show. One policy, no switch
between tracking and recovering. Trained overnight on the RTX 5070 on robotgpu's worlds, and in a browser on fewer;
shipped as a single HTML file with its weights.

THE GATES - each a measurement that can come out red:

  GT1 REPRODUCE. SuperMimic's own evaluation on our minute: every clip from its first frame to its end,
      deterministic (no action or observation noise), scored by the normalised return of SuperMimic's reward - its
      six bounded exponentials and two penalties, divided by their maximum. At least 0.83 averaged over the clips,
      none failed (SuperMimic on LAFAN1's 40 clips: 0.827, none failed).
  GT2 THE WAY BACK. The recovery probe's return rate - returned / (returned + not returned) - at pushes of 2 to 5 m/s,
      the full system against the reproduction; and starts the mocap never shows (lying down in the middle of the
      dance) brought back into it.
  GT3 SPEED. Wall-clock to GT1 on the RTX 5070, robotgpu's worlds against the CPU fleet. SuperMimic's reference: a
      strong checkpoint in about 40 minutes on one GPU, with 4096 worlds.
  GT4 THE WEB. The same training in a browser, at the worlds its memory holds; its wall-clock beside native's.
  GT5 THE DEMO. A single HTML file, the trained weights embedded, tracking and recovering on robot.zig in a browser.

## 1. The one system

What each part brings, and what it cannot do alone:

  SuperMimic      THE LEARNER'S SPINE. A world model of the full state, trained hard on many worlds' data; the policy
                  learned by the exact gradient of 32 imagined steps through it, a critic's value carrying the
                  objective past them; the task written as differentiable functions of a predicted state (the reward,
                  a soft termination, the critic's features). Fast and precise where the model is right - blind past
                  its horizon, and to whatever its data never held.
  EfficientTDMPC  THE SEARCH. MPPI through the world model, every depth's value counted (the multi-horizon objective),
                  an ensemble's disagreement as pessimism against the model's errors, and REANALYZE - stored states
                  searched again, so the targets improve as the model does. It finds ways back that no local gradient
                  reaches.
  FlowDPG         THE ACTOR'S FORM. A flow on top of the policy holds several answers to one situation - a step left
                  and a step right - so the different ways back the search finds live side by side instead of
                  averaging into a fall. Three teachers, each wrong in a different way: FlowDPG (the world model's
                  gradient), the planner (its plans, distilled), FPO (real outcomes, scored by the critic).
  The way back    OURS. An episode does not end at a loss (the aftermath, returns, starts in trouble, pushes on a
                  schedule); the bounded cost makes the critic an estimate of the time to return; the skip head lets
                  the planner and the policy reach far; DReCon's 0.2 action smoothing, always.
  robotgpu        THE WORLDS. Thousands of them stepped on the GPU beside the networks - SuperMimic's data intensity
                  and EfficientTDMPC's search size, without the CPU's physics in between.

ONE ROUND, when everything is in place:

      robotgpu's worlds ──transitions──▶ THE REPLAY (on the GPU)
            ▲                                │ windows                     │ states in trouble
            │ actions                        ▼                             ▼
      ACTING: the policy and the flow   THE WORLD MODEL               REANALYZE: the planner
      (the planner for characters       (its heads, the skip head)    searching stored states
       in trouble)                           │                             │
            ▲                                ▼                             ▼
            │                     IMAGINATION: the policy's gradient  its plans ──▶ teacher 2
            │                     through the model; the critic on    real outcomes ──▶ teacher 3
            │                     lambda-returns; teacher 1 (FlowDPG)
            └──────────────────── the weights, on the same device ─────────────────────┘

## 2. What exists (verified in the code, Nov 2)

THE LEARNER (`robot_track_resident.zig`), on the CPU FLEET: robot.zig's physics on the CPU's threads acts every
character from a mirror of the GPU's weights; the GPU trains in one frame a round. Returns, the aftermath, starts in
trouble, pushes on a schedule, the reset curriculum, the rates' cosine, gradient bounds, the bounded cost, the
watchdog, checkpoints; world-model and policy updates per round (SuperMimic's intensity, L1); hazard-driven planning
slots.

THE KIT (`robot_latent_kit.zig`): the world model (`LatentKit`, its increments normalised - L2); the skip head (on the
world model's second hidden layer, trained in the learner, not yet jumping); the critic (`LatentCritic`: two two-hot
heads with target copies, temporal differences on REAL transitions - not value-equivalent); the flow actor
(`FlowActor`, three teachers); the tracking scorer and planner (MPPI at knots, the flow's proposals, every depth's value
- v5's T1).

EFFICIENTTDMPC (`robot_bmpc_kit.zig`): complete on the GPU - its rollout, value-equivalent world model, scorer with
pessimism, MPPI, planner, and learner with reanalyze. The trainer does not use it.

THE LAB AND TRAINER: the judge per clip (time to failure), the recovery probe (without planning), the status, the
collapse alarm, run files. NIGHT 1's three recipes are handed over (`night1_handover.md`: reproduce, improve, full) -
NOT YET RUN.

ROBOTGPU (`robotgpu_plan.md`): the smooth step on the GPU, kinematics through to the positions, every kernel calling
robot.zig's own functions. The twin equals robot.zig bit for bit over many steps on eight models; the device equals
the twin within each array's bar on lavapipe and on the RTX 5070, and over 100 steps its energy within a hundredth of
the integrator's own drift. No constraints, no contacts, no tracker kernels yet.

## 3. SuperMimic, studied again (Nov 2)

The same code as on Oct 31 (Uni-SuperMimic, its checksum unchanged), read this time for how the whole loop is put
together. Oct 31's lessons and where they stand:

  L1 training intensity                  DONE (world-model and policy updates per round)
  L2 increments normalised                DONE
  L3 the critic on imagined rollouts      to do - S1 below
  L4 soft termination                     KEPT AS OURS: the failure barrier and the bounded cost
  L5 the policy's slow average            to do - S2
  L6 LayerNorm + SiLU, a zero output,
     observation noise, ten goal frames,
     ten steps of history, randomised
     physics with its context, a warm-up  to do - S3-S6 (none of them in our learner today)

What the second reading adds:

  L7 THE CONTRACT. The task hands the learner differentiable functions of a PREDICTED state - the observation, the
     reward, the soft termination, the critic's features, the goal - so imagination needs nothing but the world
     model. Ours has the same shape for the cost (`runTrackingCost`) and the policy's inputs.
  L8 THE POLICY'S OBJECTIVE. Over 32 imagined steps, the sum of gamma^t x survival_t x reward_t, plus
     gamma^32 x survival_32 x the critic's value of the last state - survival the running product of 1 - the soft
     termination. The gradient flows through the world model and the critic, both frozen; clipped at norm 1 and at
     value 0.1; an update whose norm is not finite is skipped on the device, without a read-back.
  L9 ACTING. The deterministic policy plus Gaussian noise of 0.1 - no stochastic policy, no entropy - and uniform
     observation noise, in acting and in imagination alike. The observation is 99 proprioceptive numbers: joint
     positions (less each episode's joint offsets), joint velocities, the angular velocity and gravity in the body's
     frame, the previous action, and the root's rotation relative to the reference's. No root position, no linear
     velocity.
  L10 THE CRITIC. Privileged features - the body's and the root's errors in the heading frame, the joints' errors,
     the episode's physics context - with the goal's latent; fitted to lambda-returns (gamma 0.99, lambda 0.95) of
     the imagined trajectory, five epochs of four minibatches after each policy update. Small: 256 then 128.
  L11 THE ENVIRONMENT. Physics at 200 Hz, the policy at 50 Hz; MuJoCo Warp with room for 128 contacts and 500
     constraint rows per world; 10-second episodes; a hard termination at 0.25 m of root-height error or 0.8 of tilt
     error. Its six fall-and-get-up clips are tracked as references: a fall the reference does not make ends the
     episode. That is where our goal goes beyond it.
  L12 THE EVALUATION. Every clip from frame 0, deterministic, to its end; the normalised return averaged over the
     clips and weighted by frames; the failed clips counted. 0.827 on LAFAN1's 40 clips, none failed; 0.924 over
     129,487 BONES-SEED clips. GT1 adopts it beside our judge's time to failure.

## 4. What remains

Six tracks. Each item says what, where it comes from, and its check.

E - THE WORLDS (robotgpu's critical path, P1-P5 in `robotgpu_plan.md` section 3, rewritten Nov 4 for the fastest
    approximate solver - Geno's `physicsOptions`: Newton at 3 rounds and 5 line-search iterations, MuJoCo's
    reference-pose inertia, its warm start)
  E1 P1-P2 NEWTON AND THE CONSTRAINT STEP ON THE DEVICE - the kernel's Newton robot.zig's, then inside the step program,
     with MuJoCo's warm start as its flag. Check: the twin bit for bit against robot.zig's `step` on the limits.
  E2 P3 CONTACTS, ONE GENERATOR FOR BOTH ENGINES - MuJoCo's plane-sphere, plane-capsule and plane-box, written once,
     run by the device and by the CPU for Geno on a flat floor (in place of zimrphysics for the robot against the
     floor: training and the game on the same contacts); floor only, as the CPU tracker has no self-collision; Newton's
     Hessian updated by the rows that changed (MJW's). Check: each pair against MuJoCo; Geno standing 10 s.
  E3 P4 THE TRACKER ON THE DEVICE, AS ONE DECISION PROGRAM (Isaac Lab's decision as one CUDA graph) - a decision's
     physics steps, the servo's torques inside each; the observations, rewards and terminations (terminated and
     truncated apart, the terminal state kept) once; resets and pushes as masks on the device; the records written into
     the learner's lent buffers - submitted once, nothing waiting for the host. The judge keeps robot.zig's physics -
     the game's. E3b: the startup randomisation (friction, masses, centres per world - robotgpu P4b), which Isaac Lab's every legged task runs. (The servo needs no implicit treatment: it is Tan's stable PD already - robotgpu P2b, retired.)
  E4 P5 THE FIRST NIGHT ON THE DEVICE, and THE HEAD-TO-HEAD WITH MUJOCO WARP on the same card - measurements.

S - SUPERMIMIC'S REMAINING
  S0 THE TWO CLOCKS (D4): physics at 60 Hz; the policy and the world model at 30 Hz - Simon, Nov 4: perhaps physics at 90
     or 120 Hz under the 30 Hz decision (three or four steps a decision), the solver's caps and warm start re-measured
     there. In the learner
     (`robot_track_resident.zig`, which has no clock today - `robot_latent.zig`'s `decide_every` is the older CPU
     learner's): a decision every second physics step, Simon's filter applied once a decision and the target held in
     between (P5; v4 measured its lag at about 0.15 s); one record a decision, its cost evaluated on the decision's
     state, so imagination and reality are scored alike; the reference sampled at decisions. The kit models whatever
     the records hold, so the world model's step, the policy's imagined step, the skip head's span and the planner's
     knots become decisions without a change of their own. The judge, the probe and the demo decide every second step
     of robot.zig's physics; the device's tracker (E3) dispatches the step program twice a decision. Check: with a
     clock of 1 the learner reproduces today's runs to the bit; with 2, decisions at exactly 30 per second.
  S1 THE CRITIC ON IMAGINATION (L3, L10): lambda-returns on the policy's own imagined rollout, beside or instead of the
     temporal differences on real transitions. Check: the critic's error against the real returns.
  S2 THE POLICY'S SLOW AVERAGE (L5), at 0.995; the judge, the probe and the demo read it.
  S3 OBSERVATION NOISE (L9) in acting and imagination; our policy's inputs set beside SuperMimic's 99.
  S4 THE GOAL AND THE HISTORY (L6): ten future frames encoded to a latent; ten steps of history - each measured
     against today's inputs.
  S5 THE WORLD MODEL'S FORM (L6): LayerNorm and SiLU, the output initialised to zero; rounds of the world model
     alone before the policy learns.
  S6 RANDOMISED PHYSICS WITH ITS CONTEXT (L6) - DEFERRED (D3): friction, joint offsets and the centre of mass per
     episode, told to the world model and the critic; friction alone first, if the policy proves brittle.
  S7 THROUGH JUMPS (v5's T8-T9): the policy's gradient through fine steps, then the skip head's jumps - past 32 steps
     at the cost of eight and a few jumps.
  S8 INTENSITY AT SCALE: SuperMimic's ratios - per collected transition, about 16 predicted world-model steps and 13
     imagined policy steps - once the worlds are on the device.

T - EFFICIENTTDMPC'S REMAINING
  T1 THE PLANS' HONESTY (v5's T10): what a plan promised against what the physics gave - at each decision, the chosen
     candidate's predicted costs against the costs that followed.
  T2 THE FAR HALF (v5's T6-T7): the planner's rollout in fine steps, then jumps.
  T3 THE PROBE PLANS: the recovery probe with the planner in the loop - GT2 for the planning version.
  T4 REANALYZE FOR THE WAY BACK: a second planner on stored states in trouble; its plans teach the flow (teacher 2)
     and the critic.
  T5 HEADS AND PESSIMISM (v5's T9-T10): world-model heads trained alike from their own initialisations; the planner
     and the policy rolled on every head; the critic value-equivalent; pessimism on (EfficientTDMPC's eq. 10).
  T6 THE SEARCH AT ITS SIZE: 512 candidates and 6-8 iterations once acting runs on the device (about 20 and 2
     today); replanning more often than once a round.

F - THE FLOW
  F1 CHUNKS: one flow sample per knot span, the cost of acting cut accordingly.
  F2 THE TEACHERS' SHARES, as measured (FlowDPG 1, the planner's 0.5, FPO as the critic earns trust), revisited once
     reanalyze's plans arrive.
  F3 THE WAYS BACK KEPT APART: a measure of the flow's distinct answers at a state in trouble - several returns, not
     one averaged.

R - THE WAY BACK
  R1 THE HARDEST STATES KEPT: an archive of the fallen states the policy failed from, restarted from.
  R2 DISCOVERED RETURNS AS CLIPS: a return that worked, kept as a reference the policy can track.
  R3 REALISM: energy and torque limits.

M - MEASUREMENT, RUNS, SHIPPING
  M1 GT1'S MEASURE in the judge: SuperMimic's reward and its normalisation, every clip from frame 0, deterministic.
  M2 WHERE THE COMPUTE GOES (v5's queue): each phase's device work per round, and the discovery share (the goal's
     half).
  M3 THE NIGHTS: night 1 on the CPU fleet (reproduce, improve, full) once its open items are done - the full gate,
     and the night files bound on the RTX 5070; the later nights on the device.
  M4 THE DEMO (GT5).

## 5. The order

Two lanes. THE WORLDS is the main lane (E1, E2, E3), because thousands of worlds change what every learner step can
measure; THE LEARNER's small steps go between, each measured on the CPU fleet's nights until the device's worlds
arrive. Each step is a turn's size.

  THE LEARNER, BEFORE E3: M1, then S0 - the rates every later run uses - then S1, the critic on imagination (Simon,
  Nov 2: "We need a good critic" - at half a second of imagination the critic carries everything beyond it), then
  night 1 (M3), the baseline every later run is read against; then S2, S3, S5; T1, as the plans' honesty is measured before more search is spent; S7 and
  T2, the skip head's two uses; T3, T4; F1.
  AFTER E3, the learner on the device's worlds: S8 and T6 at the sizes the device allows; T5; F2, F3; R1-R3; GT3,
  GT4; M4.

THE NEXT TEN STEPS:

   1. M1  GT1's measure in the judge - DONE Nov 2 (M1a the tracking terms, M1b the penalties and the fleet's score,
          M1c the trainer's whole-clip judgement in `judge.csv`).
   2. S0a DONE Nov 2. The clock in the fleet (`Fleet.Options.decide_every`): one step a decision - the physics stepped that many
          times with the targets held and the reference advancing each physics step; the record (the fleet's own),
          the reward, the termination and the episode's end once a decision. The learner, the judge and the probe
          then all decide at 30 Hz; a clock of 1 reproduces today's runs to the bit.
   3. S0b DONE Nov 2. Simon's filter in the resident learner's acting and records (FOUND Nov 2: the resident learner and its kit
          have neither the filter nor the clock; the older CPU learner had both, P5): the fleet given the filter's
          output once a decision; the record holding the applied action and the filter's state.
          PAUSED Nov 2 (Simon: "Ok lets forget about the filter for now"): S0c2-S0c4 deferred. In DReCon the filter
          was essential against shaking, from a stochastic policy's fresh noise at every decision; SuperMimic acts
          deterministically, smooths through its objective's action-rate penalty, and needs none - while the filter's
          0.15 s lag works against fast recoveries. What is built stays, off at 1 and exact there: the option (S0b)
          and the kernels (S0c1). The filter returns if the runs shake.
          S0c The filter inside training. The servo's targets within a decision are the APPLIED action alone, so the
          physics' next state depends on (state, applied action): the world model needs no change, its recorded
          windows already hold applied actions (S0b). Imagination must produce them - in four steps:
          S0c1 DONE Nov 2 - the kernels (`gpu/zn_mlp.zig`): `lat_act` blends the chosen action with the previous
               step's action columns (`lat_filter`, `lat_prev_action`, `lat_prev_action_stride`); `lat_act_bwd`
               carries the action columns' gradient back through the blend (`lat_carry`); both exact at 1.
          S0c2 the kit's wiring: `policyStep` and `policyBackward` pass the filter, the previous columns and the
               carry (its region in the gradient buffer, zeroed before each backward); checked against the older
               CPU learner's training graph with its filter - the kit's filtered rollout and gradient, number for
               number.
          S0c3 the windows' starting actions: the action given before each window's start, gathered from the record
               before it (zero at an episode's start); the planner's rows from the acting characters' applied actions.
          S0c4 the policy sees the previous applied action (where its targets already are), as SuperMimic's
               observation holds its previous action.
          S0d DONE Nov 2. The night recipes at 30 Hz, the policy's imagination 16 decisions (0.53 s - the reach of today's 32
          steps at 60 Hz, at half the steps; SuperMimic's 32 at 50 Hz are 0.64 s) over the world model's window of
          8 (0.27 s); the learner's judge actor (`actOnJudgedFleet`, which hands the fleet the raw mean action every
          step) with the filter and the clock, so the learner is judged as it acts.
   3d S0e DONE Nov 2. (FOUND by review, Nov 2) THE PROBE'S TIME AT THE CLOCK: the learner's probe fleets decide at the clock (S0d),
          so the probe counts decisions - but its settle, watch and averaging counts (60, 180, 15: "one second, then
          three"), its return limit (seconds over the clip's frame time) and the seconds it reports (callers pass the
          clip's frame time) all assume 1/60 s a step; and it places the push at a reference FRAME (`start_frame +
          settle_steps`). Fix: durations in seconds (settle 1, watch 3, average 0.25), counted at the probe fleet's
          `decisionSeconds`, frames as decisions x the clock; each `RecoveryBand` carrying its own step's seconds, so
          no caller passes a frame time.
   4. S1a DONE Nov 2 (the kernel; the critic's imagined fit, wired, the recipes at an equal weight) The critic on
          imagination, BESIDE its fit on real transitions (Simon: "Critic should be trained on both real
          and imagined, right?"): the real windows' temporal differences keep it honest about what happens; the
          policy's own imagined decisions make it right where it is read - imagination's states, the current policy.
          Lambda-returns over the imagined decisions, from the last state's value backwards -
          G_H = V_H,  G_k = c_(k+1) + gamma x ((1 - lambda) x V_(k+1) + lambda x G_(k+1))  - V the target heads; the
          inputs the rollout's own state and goal blocks; the costs and the fit the critic's own kernels; one new
          kernel to combine. Lambda 0.92 per decision (0.4 s, SuperMimic's 0.95 at 50 Hz in seconds); the balance
          of the two fits a share, measured.
   4b T0  DONE Nov 2. THE TUTORIAL'S DEBT: the robot-mocap tutorial explains none of this session's tracker work - the clock (30
          decisions a second over 60 Hz physics), SuperMimic's measure (GT1), the probe in seconds, the critic's
          imagined fit with its lambda-returns. A chapter's worth, before S1b.
   5. S1b FOLDED INTO THE LOG, Nov 2: a true check against real returns needs real trajectories of several seconds
          (at 1.5 s, about 4.5 s before the uncounted tail is under 5%) - long gathers on the GPU, or the critic and its
          cost on the CPU over the replay: measuring machinery Simon's way defers ("assemble, measure later"). The log
          already records the critic's value, its spread, and its error against its REAL one-step targets every round,
          the imagined fit leaving those numbers to the real one - night 1 reads them. The check itself returns if the
          numbers call for it. Was: Its check against the real returns, beside today's temporal differences on real transitions; the night
          recipes with it.
   6. M3  Night 1's open items: the full gate; the night files bound on the RTX 5070 (a minute of the trainer on
          Simon's machine). Then night 1, at 30 Hz, with the critic on imagination.
   7. E1a Constraint rows: limits in deterministic slots - the Jacobian, the position, the margin, the reference
          acceleration; the KUKA on its limits, on the twin.
   8. E1b Newton in one workgroup per world; robot.zig's constraint tests replayed on the twin.
   9. E1c The constraint step on the device; the bars on lavapipe and on the RTX 5070.
  10. S2  The policy's slow average.

## 6. Decisions, asked one at a time

  D1 THE LANES' ORDER - DECIDED Nov 2 (Simon: "Agree with recommendation"): the worlds first, the learner's small
     steps between, each measured on the CPU fleet's nights until the device's worlds arrive.
  D2 THE HEAD-TO-HEAD WITH MUJOCO WARP - DECIDED Nov 2 (Simon: "With you"): after E2, with contacts and constraints
     on both sides - SuperMimic's setting, and the number that decides training speed. Until then, the device test's
     own per-kernel timings show the slowest kernels. The script stays outside the repository.
  D3 RANDOMISED PHYSICS - DECIDED Nov 2 (Simon: "Not now"): SuperMimic randomises friction, joint offsets and the
     centre of mass to cross to a real robot; our character lives on robot.zig's own physics. Robustness comes first
     from pushes, starts in trouble and returns; randomisation - friction alone first - returns if the policy proves
     brittle under pushes.
  D4 THE RATES - DECIDED Nov 2 (Simon: "I want to try physics at 60, policy and world model at 30"): two physics
     steps per decision, the world model stepping from decision to decision - SuperMimic's structure (its world model
     at its 50 Hz policy rate, four physics steps inside a step) at our rates. The game's physics is unchanged, and the
     world model's windows, the policy's imagination, the skip head's jumps and the planner's horizon reach twice as
     far in time for the same compute. It returns to v4's choice (F3c, P5: 60 Hz physics, 30 Hz policy), with the
     world model now at the policy's rate. Item S0.
  D5 G1 BESIDE GENO - DECIDED Nov 2 (Simon: "Geno. For the first night."): our minute on Geno, scored by GT1's
     measure; SuperMimic's G1 and LAFAN1's 40 clips only if that comparison is ever in doubt.

  ALL FIVE DECIDED, Nov 2. With D4, Simon also set the first night's horizon: "16 steps for policy learning which
  bring us at 0.5 seconds" - S0b.

## 7. Settled facts worth keeping in view

  - The bounded cost (cap 25) makes the critic an estimate of the time to return; returns and their windows are in
    every run.
  - On the flow's weights FlowDPG's natural gradient is the LARGEST (about 0.002, against 0.0003 and 0.00015); the
    shares set the balance (FlowDPG 1, distillation 0.5, FPO by the critic's trust).
  - The world model's gradient: 15-40 calm, 170-590 through falls; bound 50.
  - The search beats the flow's proposals by a growing margin - finding or exploiting, which T1 settles.
  - At one decision a round the warm start carries only horizon - 16 steps; knots make it lossless where it carries.
  - robotgpu's step: the twin is robot.zig to the bit; the device's numbers are the twin's within each array's bar;
    over 100 steps the device's energy is within 2.4e-6 of the twin's, against the integrator's own 7.1e-2.
  - SuperMimic's world model and critic are given the episode's physics context; its policy sees only proprioception
    and the reference.
  - The rates: physics at 60 Hz; the policy and the world model at 30 Hz, two physics steps a decision (D4).
  - The first night: Geno (D5); the policy imagines 16 decisions, about 0.5 s, over a world-model window of 8.

## 8. Journal

- Nov 2: v6 written (Simon: "Study again this supermimic implementation. Look at what remains in our robot gpu and
  mocap tracking plan. Make a new mocap tracking plan that puts together what remains to be done for having
  supermimic, efficienttdmpc, flowdpg together in a single system."). Uni-SuperMimic read again - the same code as
  Oct 31 - for its whole loop: the contract, the policy's objective, acting, the critic, the environment, the
  evaluation (L7-L12). The single system already exists in prototype (night 1's `full` recipe, on the CPU fleet);
  v6 gathers what each part lacks, v5's remaining turns among them, and robotgpu's stages the tracker depends on.
  v5 archived whole.
- Nov 2: D1 decided - the worlds lane first (E1, E2, E3), the learner's small steps between.
- Nov 2: D2 decided - the head-to-head with MuJoCo Warp after E2, with contacts and constraints.
- Nov 2: D3 decided - no randomised physics for now (S6 deferred).
- Nov 2: D4 decided - physics at 60 Hz, the policy and the world model at 30 Hz (S0, before night 1). The learner the
  nights use has no clock today: it acts and models at 60 Hz.
- Nov 2: D5 decided - Geno, for the first night - and the first night's horizon set: the policy imagines 16 decisions
  (0.53 s). All five decisions made; the work starts at step 1, GT1's measure in the judge.
- Nov 2: THE ORDER CHANGED (Simon: "Change the order. We need a good critic. Proceed"): S1, the critic on imagined
  lambda-returns, before night 1 - M1, S0, S1, then night 1, then the worlds lane.
- Nov 2: M1a DONE - SuperMimic's tracking terms as a function of two whole-body states (`robot_track.zig`:
  `SuperMimicScales`, `SuperMimicTracking`, `superMimicTracking`, `headingAngle`): the reference re-anchored to the
  character - turned by the heading of the roots' relative rotation, moved to the character's ground position at its
  own height - six bounded exponentials of squared errors, averaged over every body, at most 5 a step. Three tests:
  the reference itself earns 5; drift and heading forgiven in the pose and charged at the root, at their closed
  forms; a velocity error costs what its scale says. Run through `robot_tests.zig`'s root (`robot_track.zig` is one
  of its members, so `-Dfast-root=src/robot_track.zig` builds nothing): 4/4 with the filter "SuperMimic".
- Nov 2: M1b DONE - SuperMimic's two penalties as functions on arrays (`superMimicActionRate`: the squared change of
  the policy's raw action since its previous decision; `superMimicJointLimitExcess`: limited joints past their range
  narrowed to nine tenths - the joints robot.zig limits, hinges and slides, as it applies no range to a ball); their
  weights in `SuperMimicScales`, the scales in the task (`Task.super_mimic`). The fleet scores every environment's
  step on SuperMimic's scale inside its step loop (`Fleet.super_mimic_rewards`, `superMimicReward`) - the one moment
  the character's and the reference's states are both at hand, before a finished character is restarted - with each
  environment's previous raw action kept (`previous_asked`, zero at an episode's start). The judgement sums it over
  the first episodes and normalises it by the most the starts could earn (`superMimicNormalisedReturn`). FOUND: a
  start needs frame 1 or later (`startAt`), so GT1's "first frame" is frame 1. CHECKED: the robot family 656/800 (the
  five new tests; 651 before), lint.
- Nov 2: M1c DONE - GT1 IN THE NIGHT'S FILES. Every `judge.csv` line gains SuperMimic's two sums
  (`super_mimic_return_sum`, `super_mimic_available_steps`), so any judgement reads on SuperMimic's scale; the trainer
  (`tools/geno_trainer.zig`, both judging paths - the older trainer's and the resident learner's per clip) adds a
  second judgement each time, the whole clip from frame 1 with one start - SuperMimic's evaluation - as the clip's
  "<clip>/whole" line, the servo's first. Its normalised return is super_mimic_return_sum / (5 x
  super_mimic_available_steps); a clip failed when that line's reached_end is 0. CORRECTED, M1b: the fleet never
  filters - its callers run Simon's filter (`robot_policy.Controller`) and the clock - so the action rate is the
  change of the action the FLEET IS GIVEN (the filtered one in the lab's judge, the raw mean in the learner's judge
  actor), not the raw policy output as first written; names and comments now say so (`previous_actions`). FOUND, for
  S0a: the learner's judge actor applies neither the filter nor the clock. CHECKED: the robot family 656/800, `zbuild
  check`, the Windows trainer, doc-sync, lint.
- Nov 2: FOUND, starting S0 - THE RESIDENT LEARNER HAS NO FILTER. Neither `robot_track_resident.zig` nor
  `robot_latent_kit.zig` applies Simon's filter or a clock, and the night recipes set neither: the night learner acts
  and trains on unfiltered actions at 60 Hz (its judge actor matches it). The older CPU learner (`robot_latent.zig`:
  `filter`, `decide_every`) and the PPO path had both (P5). S0 becomes four steps: the clock in the fleet (S0a), the
  filter in acting and records (S0b), inside training (S0c), the recipes and the judge actor (S0d).
- Nov 2: S0a DONE - THE CLOCK IN THE FLEET. `Fleet.Options.decide_every` (1 by default; refused below 1): one `step`
  is one decision - the targets held for every physics step but the last, each character's reference advancing a
  frame after each (the servo follows the moving reference within a decision), the last physics step measured as
  before - so the fleet's record, reward, termination and episode end come once a decision, and the learner, the
  judge and the probe decide at the fleet's clock without changes of their own. With it: the decision's start frame
  for the reset curriculum (`frame + 1 - decide_every`); a push's chance over the decision's duration; the clip over
  when another decision would pass its last frame; starts that leave a decision's frames (`lastStartFrame`, replacing
  three `frame_count - 2`; `startAt`'s check); the judge's frame time and available steps in decisions. Every step
  count in the options now counts decisions (the recipes are converted in S0d). `step`'s doc comment, drifted onto
  `floorWorld`, is back on `step`. CHECKED: the robot family 657/801 - every test unchanged at a clock of 1, and the
  new one: a decision at a clock of 2 equals two steps at a clock of 1 with the action held, to the bit (positions,
  velocities, frame, reward); `zbuild check`; doc-folds; doc-sync; lint.
- Nov 2: LINT (Simon: "Add assertUnreachable to the list of reserved names that need to be aliased"):
  `assertUnreachable` joins zimrlint's `keywords` (`tools/zimrlint.zig`, under "assertions") - aliased at file scope,
  used bare, never another declaration's name. 26 files already used it so; 23 qualified calls in 9 files (the
  fleet, the sound module and its worklet test module, six robot examples) became bare, the 8 files without the
  alias given it. CHECKED: lint, `zbuild check`, doc-folds, doc-sync.
- Nov 2: S0b DONE - SIMON'S FILTER IN THE RESIDENT LEARNER'S ACTING. `Options.filter` (1 by default - no filter, the
  chosen action copied exactly; refused outside (0, 1]): `writeAction` makes the chosen action safe in place (a
  non-finite component counted and asking for nothing), then blends it into the character's slot of `actions` -
  which holds the action given at its previous decision, so the slot IS the filter's state - through the tracker's one
  definition (`track.filterAction`). The fleet records what it is given, so the replay holds the applied actions. A
  character whose episode ends has its slot zeroed (`forgetEndedEpisodes`): its filter starts at rest. The option is
  mirrored in the lab (`SuperTrackLearner.filter`) and saved with the state (`SavedOptions.filter`, with an explicit
  `padding_after_filter` - the state header's no-padding guard caught the four bytes the new field shifted). The
  default stays 1 until S0c: acting filtered while imagination fed the world model unfiltered actions would train the
  two on different actions. CHECKED: the robot family 658/802 - every test unchanged at 1, and the new one: two learners
  alike but for the filter choose the same first action, and the filtered one gives the fleet exactly 0.2 of it;
  `zbuild check`; doc-folds; doc-sync; lint.
- Nov 2: S0c1 DONE - SIMON'S FILTER IN THE ROLLOUT'S KERNELS. `lat_act`: the action written is lat_filter x lat_scale x
  (raw + noise) + (1 - lat_filter) x the previous action (read at `lat_prev_action`, rows `lat_prev_action_stride`
  apart: the previous step's action columns, or the window's starting actions). `lat_act_bwd`: a step's action feeds
  the next step's by (1 - lat_filter), so the backward - last step to first - keeps a CARRY per (row, action) at
  `lat_carry`, whole = own + (1 - lat_filter) x carry, and gives the raw output lat_filter x lat_scale x whole plus the
  prices. At 1 both return early with today's expressions, exactly (a blend at zero weight would still read the
  previous columns, and 0 x NaN is NaN). The four parameters fill padding words of the uniform block (`_p9`, `_p4` -
  `_p6`), so nothing moves. CHECKED at 1: the robot family 658/802 unchanged, the GPU learning kit's tests, `zbuild
  check`, lint. The filtered path is checked in S0c2, against the older CPU learner's graph with its filter.
- Nov 2: THE FILTER PAUSED (Simon: "In drecon we noticed that the action filter was essential for reducing shaking. I am
  not sure if in the supermimic and efficienttdmpc it will really help... by how much are we increasing the state
  dimension for the policy?" - then "Ok lets forget about the filter for now"). The numbers: Geno's policy reads 774
  (goal and state, 387 each: 24 character bodies x 16 + 3); the previous applied action would add 69 (+8.9%); the
  world model none. The case against, for now: DReCon's shaking came from a stochastic policy's fresh noise at every
  decision; SuperMimic acts deterministically and smooths through an action-rate penalty; the planner's plans are
  smooth by construction (knots); at 0.2 per 30 Hz decision the filter lags about 0.15 s, against fast recoveries.
  S0b's option and S0c1's kernels stay, off at 1 and exact there.
- Nov 2: S0d DONE - THE NIGHT AT 30 HZ. The lab's recipe view gains the clock and the episode cap (`decide_every`,
  `max_steps`, fleet fields beside the others); the trainer passes both to the training fleet and the clock to the
  learner's own judge and probe fleets (`probeAndRecord`'s `learner_clock`; the PPO path's calls a named clock of 1,
  its policy file bringing its own); the SuperTrack policy file now carries the learner's clock as its decimation
  (`policyOfSuperTrack`'s `decimation`, read from the learner's fleet) instead of a fixed 1, so the demo and the
  judge's controller decide as the policy was trained to. THE RECIPES (all three): `decide_every = 2`, `max_steps =
  300` (10 s), `policy_window = 16` (0.53 s, Simon), the aftermath 150 (5 s) and the return hold 4 (0.13 s) where they
  are set; the world model's window 8 (now 0.27 s), the planner's horizon 16 (now 0.53 s, the policy's reach) and the
  replay's 256 (now 8.5 s) kept; everything in seconds, hours or updates unchanged. The handover says so (and its
  stale "256 wide" is 680, the critic 170). CHECKED: lint, the robot family 658/802 (the recipes' tests among it),
  `zbuild check` (the trainer).
- Nov 2: THE CRITIC'S TIME SCALES IN SECONDS (Simon: "yes please do what you recommend for the parameters"). The
  critic's discount was 1 - 1/90 per PHYSICS step - its own documented second and a half at 60 Hz - and since the clock
  (S0a) a step is a decision, so at 30 Hz it had silently become three seconds. It is now documented per decision
  (`CriticOptions.discount`, default unchanged for the default clock) and the night recipes set 1 - 1/45 (0.97777778,
  the same 1.5 s at 30 a second). The imagined lambda-returns (S1a) take SuperMimic's 0.4 s: 0.92 per decision.
- Nov 2: S1a-1 DONE - THE LAMBDA-RETURN KERNEL. `value_lambda_combine` (`gpu/zn_mlp.zig`): one step of the critic's
  lambda-returns along an imagined trajectory, walked backward, one thread per row - `zimrrl.gae`'s recurrence in f32
  (delta = c_(k+1) + gamma V_(k+1) - V_k; running = delta + gamma lambda running_(k+1); G_k = running + V_k), V the
  target heads' mean (`meanTargetValue`), no trace cut (a fall is no terminal); `target_lambda` in the value target's
  row of the uniform block (its padding `_p14`). CHECKED: against `zimrrl.gae` row by row (three rows, four steps, two
  heads), to f32's rounding of gae's f64; the robot family 659/803; `zbuild check`; lint. FOUND: `gpu_learn_tests.zig`
  is a member of `robot_tests.zig`, so `-Dfast-root=src/gpu_learn_tests.zig` runs NOTHING ("1/1 steps succeeded",
  no count) - its tests run through the family; and `build.zig` lists the kit's kernels by hand, a second copy of
  `zn_mlp.zig`'s list (QUEUED: one list, as robotgpu's).
- Nov 2: REVIEW of the session's code (Simon: "Review recent code"). FOUND, from the clock reaching the learner's
  fleets (S0a, S0d), every place that turned fleet steps into time at 1/60 s: (1) the trainer's time to failure for
  the learner - FIXED: one definition of a step's duration, `Fleet.decisionSeconds()` (the timestep x the clock), used
  by the push probability (bit for bit) and the trainer (`decisions_per_second`; `RecentRounds.secondsToFailure`'s
  `steps_per_second`); (2) the recovery probe's durations - queued as S0e, before S1a's next piece, as night 1's
  recovery numbers depend on it. (3) The paused filter was a trap - a recipe could set it, filtering acting while
  imagination did not - so the lab refuses it ("filter: 1 (none) until imagination passes its actions through the
  filter too"), the refusal in its table of refused recipes; the learner's mechanism and its test stay. (4) Checked
  and right: the judge's decisions available match the decisions an episode takes for either parity of frames; the
  SuperMimic measure, penalties and normaliser; the clock's substeps; the export's decimation; the push schedule's
  hours (wall-clock, unaffected); the lambda-return kernel. CHECKED: lint, the robot family 659/803, `zbuild check`.
- Nov 2: S0e DONE - THE RECOVERY PROBE IN SECONDS. `RecoveryProbe`'s durations are seconds (settle 1, watch 3, the
  running mean 0.25, the return limit as before, the return's hold 8/60), counted in its fleet's steps by `stepsAt`
  (`ProbeSteps`, each rounded; the running mean at least one) - so at a clock of 1 every count is the old one. The
  band counts at its probe fleet's clock and stamps its own `step_seconds`, so `meanRecoverySeconds` and
  `meanReturnSeconds` take no frame time from callers, and `recoveries.csv`'s last column is `step_seconds` (no reader
  parses it by name). The start selection keeps its units apart: room for settle and watch decisions and one decision
  more, in frames (decisions x the clock), and the push at `start + settle x the clock`. ONE DEFINITION of a decision's
  duration, `secondsPerDecision(timestep, clock)`: the fleet's `decisionSeconds`, the judge and the probe. FOUND by
  its new test: a quarter of a second is 7.5 decisions at 30 a second, and the f32 quotient falls just short of the half
  (1/60 has no exact binary form) - 7, deterministically; the test says so. CHECKED: the robot family 660/804 (the new
  test: the same seconds at either clock), `zbuild check`, doc-folds, doc-sync, lint.
- Nov 2: S1a-2 DESIGNED - THE CRITIC'S IMAGINED FIT. Read: the kit holds the POLICY's steps (16; the world model
  trains on the first 8, `world_steps`), one kit for both; the critic's `Source` reads the recorded blocks (`blockT`,
  `blockG` from step 1: (steps - 1) x rows transitions), and the imagined states lie in `blockZ` in the same layout -
  so an imagined `Source` is the same struct at `blockZ(1)`, the same four placements, the same transition count, and
  the critic's passes and regions serve it unchanged. BUT the critic updates inside `trainWorld`, on the world
  model's gathered windows, while the policy updates in `trainPolicy` on its own: the imagined states exist only right
  after a policy step. So the imagined fit is an UPDATE OF ITS OWN after each policy step - the critic's heads and
  optimiser shared, its two-hot loss weighted by `CriticOptions.imagined_share` (0: it never runs, the real update
  bit for bit as today), lambda `CriticOptions.imagined_lambda` (0.92; both in the struct the learner already
  mirrors and saves whole). New: the target values at each transition's OWN state (the GAE form's V_k; one more
  forward per head, into a region of its own); `target_head_stride` in the kernel's free `_p15` (the critic keeps
  values [head][transitions]); a kernel that zeroes a region, for the running advantage (none exists; a product
  with zero is not safe - 0 x NaN is NaN). The test: a critic over synthetic imagined blocks, its imagined targets
  against `zimrrl.gae` on the costs and values the kit itself computed.
- Nov 2: S1a-2 DONE - THE CRITIC'S IMAGINED FIT. `CriticOptions.imagined_share` (0: none - the real update bit for bit
  as before) and `imagined_lambda` (0.92); `LatentCritic.reserveImagined` (its places after `init`: the imagined
  states' block, the values at each transition's own state [heads][transitions], the running advantage [rows]);
  `computeImaginedTargets` (the same four placements from the imagined blocks - `blockZ` from step 1 - the costs, the
  target heads at both ends of each transition, the walk back from the last with `value_lambda_combine` after
  `zero_rows`); `updateImagined`; the real update split into `computeTargets` and a shared `fitTargets` (the loss's
  weight, and whether the fit writes the log's numbers - the imagined one leaves them to the real one). The kernel's
  `target_head_stride` (the free `_p15`; 0 the rows) and a new `zero_rows`, in both kernel lists. The learner: the
  imagined fit after each policy step, while its rollout is in the kit's blocks, counted with the real updates (one
  optimiser); the night recipes at `imagined_share = 1.0`. ON THE WAY: `assertUnreachable` returns void, not
  noreturn (a kernel cannot abort), so an `orelse` calling it still returns; the ZON serializer's compile-time walk of
  a whole run outgrew the default thousand branches with two more critic fields - `GenoRun.write` raises it, saying
  why. CHECKED: the new test - the imagined targets by hand, the costs where each transition led, the inputs the
  imagined states beside their goals, the returns zimrrl's GAE at lambda 0.8 - the robot family 661/805, `zbuild
  check`, doc-folds, doc-sync, lint.
- Nov 2: T0 DONE - THE ROBOT-MOCAP TUTORIAL BROUGHT TO THE CODE. 11.7 gains "Decisions and physics steps" (the clock's
  timeline, why a held offset still moves, every count in decisions; `secondsPerDecision` folded). 11.12, "Credit past
  the window", was STALE - it said the learner has no critic - and is rewritten as it is: the value tail, the discount
  as a duration (1 - 1/45 is 1.5 s at 30 a second), trust growing over the first updates, the two fits and what each
  corrects, the lambda-return recurrence and a worked example (costs 0.2, 0.3, 0.5, values 2, gamma 0.9, lambda 0.8:
  2.228, 2.316, 2.3 against the one-step 2.0, 2.1, 2.3); `value_lambda_combine` and `computeImaginedTargets` folded.
  11.15 gains SuperMimic's measure (the re-anchoring, the normalised return, a fall's cost) and the recovery probe
  (its durations in seconds at any clock); `superMimicTracking` and `RecoveryProbe` folded. The paused filter is not
  described: the tutorial says what the system does. CHECKED: doc-folds (five new folds filled), doc-sync.
- Nov 2: S1b folded into the log (above); on to night 1's open items: the Windows trainer built and packaged with the
  three recipes at 30 Hz for a minute's binding check on the RTX 5070, and the full gate.
- Nov 3: NIGHT 1'S OPEN ITEMS. THE TRAINER: `geno_trainer.exe` cross-built for Windows in release mode - its kernels,
  the four clips and Geno embedded, so it runs from any folder - packaged with the three recipes at 30 Hz, the
  handover and a README: a minute's binding check on the RTX 5070 first (what to send back), then the night.
  THE FULL GATE: red, four root errors, none in the tracker's work and most likely accumulated since the last pass
  the journal records (before the robotgpu arc): (1) `editor-configs --check` - the checked-in editor configs do not
  list every web and Windows app (the robotgpu lab's builds arrived since); `zig build editor-configs` regenerates.
  (2) `spv2wgsl_check our-corpus` - three cached modules, each `compute.spv` of 86,920 bytes, do not translate; which
  module they are is to trace. (3) the macOS launcher: `std.os.linux`'s vdso reached from an aarch64-macos build
  (11 references hidden; `-freference-trace` to follow). (4) the wasm launcher's compile killed (signal KILL - the
  container's memory, not the code). NEXT: the gate green - (1) to (3) - in parallel with Simon's minute.
- Nov 3: REVIEW (Simon: "Explain. Review. What are you saying. Look at our plan. Make the system perfect"). The gate's
  errors, traced: (1) the editor configs lacked the apps added since the last pass - REGENERATED (`zig build
  editor-configs`: 328 web and 328 Windows apps). (2) the spv2wgsl corpus's failing module is robotgpu's PROBE module
  (`src/gpu/robotgpu_probe.zig`), and the failure is a real bug: its `cholesky` kernel returned early before its
  workgroup barriers (`BarrierInNonUniformControlFlow`) - every invocation of a workgroup would return together, but
  nothing lets a compiler see it, so WGSL refuses it and SPIR-V leaves it undefined; it worked on lavapipe and the
  RTX 5070 by luck. FIXED: a workgroup past the matrices reaches every barrier and only skips its buffer reads and
  writes; its comment, which claimed uniform control flow, corrected. No other cached module warns (each checked
  alone). To do: the probe's tests on lavapipe; the five stale cached copies of the old module cleared, as the
  corpus scans the cache. (3) the macOS launcher reaching `std.os.linux` and (4) the wasm launcher killed for memory:
  still to trace. THE PERFECT LIST (proposed): the gate green; the paused filter removed rather than kept half-built;
  the kit's kernel list made one, as robotgpu's; then night 1.
- Nov 3: THE GATE'S ERRORS FIXED (Simon: "Dont remove the paused filter. We will revive it and try it soon. We dont
  have a macos target yet. I dont know where it comes from"). THE FILTER STAYS, paused, to be revived. (1) The editor
  configs: regenerated. (2) robotgpu's Cholesky probe: verified on lavapipe after its fix (L L^T within 4.5e-7 of A,
  the device 0.00 epsilons from the twin, two device runs identical, no validation messages); the five stale cached
  copies of the old module cleared; the translation corpus 119 ok, 0 failed. (3) THE MACOS ERROR, traced: not a macOS
  target but `platforms-check`, which compiles the engine for systems with no platform code yet (macOS, Android -
  `platform/unwritten.zig`) so it stays portable before they exist. The engine's clock (`native_os.monotonicMilliseconds`,
  reached through the runner, the profiler and `wgpu.nowMs`) treated every system but Windows as Linux and called
  Linux's system call: now three ways - Windows' counter, Linux's system call (no C library needed, so the sound
  tests' root still builds), any other system's C library (macOS always links it). macOS and Android compile. (4) The
  wasm launcher's debug build needs more memory than this container's 4 GB - an environment limit, not the code.
  ALSO: the disk. This container allows about 19 GB; the build refuses at 97% used. The cache had grown to 8 GB and
  the free space to 0.5 GB: `zig-out` (regenerable), the scratch directory and `~/.cache/uv` (1.5 GB of Python
  packages from the SuperMimic study - zimr has no Python tools) cleared, 2.4 GB free. CHECKED: lint, `zbuild check`,
  vk-host-test, the corpus.
- Nov 3: REVIEW AND IMPROVEMENT (Simon: "Review and improve the code and tutorial"). ONE LIST OF THE KIT'S KERNELS:
  `zn_mlp.zig` and `build.zig` each listed all 102 by hand (in agreement - every edit made twice); now
  `src/gpu/zn_mlp_kernels.zig`, depending on nothing so the build script can read it, re-exported by the kit as its
  `kernels` and read by the build as `zn_mlp_entries` - as robotgpu's program file. FOUND by the full check: the night
  trainer's build compiles a COPY of the kit beside its night-sized `zn_mlp_sizes.zig`, so the list is copied beside
  it too. THE TUTORIAL: SuperMimic's measure has a worked example (a character 0.36 m adrift and half a radian turned,
  its pose exact: the body terms 1, the root 0.236 and 0.210 at half weight - 4.22 of 5, the decision worth 0.845);
  the clock's section names the night's counts as durations (an episode 300 decisions, 10 s; an aftermath 150, 5 s;
  the imagination 16, 0.53 s; a replay 256, 8.5 s). CHECKED: lint, `zbuild check`, the robot family 661/805.
- Nov 3: REVIEW, CONTINUED - THREE SIMPLIFICATIONS, no result changed (the robot family 661/805 after each).
  `superMimicTracking`: its six terms through one definition (`boundedTerm`: 1 at no error, exp(-1) at the scale's
  square), named, then returned in one literal - no struct built with a zero total and patched. The critic: the
  imagined targets had been written as a copy of the real ones' first half (the four placements, the costs, the target
  heads where each transition led) - now `prepareTransitions(states_at)`, shared; the imagined targets add only what
  is theirs (the values where each transition began, the walk back). The fleet's step: `physicsStep` - one drive of
  every character, checked loudly - for every physics step of a decision, the check no longer written twice, and the
  physics' threading comment back on the code it describes. CHECKED: lint, `zbuild check`, the family 661/805.
- Nov 3: THE ROBOTS COURSE - CHAPTER 56, "Checking the device" (Simon: "Before i can test, improve the tutorial").
  The course explained every stage's algorithm (chapters 45-55) and nothing of how the device is checked - what his
  test prints. Now: the three engines and their two comparisons (robot.zig to the twin, to the bit; the twin to the
  device, within each array's bar); where a GPU's numbers differ (division and square root, fused multiply-adds, its
  own transcendentals - correct roundings at other points); the gap in epsilons against each quantity's size, the
  bars with both devices' gaps; the probes, ranking the sources of difference; workgroups and barriers - every
  invocation must reach every barrier, the pattern that guards the memory and not the barrier, the Cholesky kernel
  as its example; many steps judged by energy (the integrator's drift as the scale, both devices' numbers); the lab
  page. Folds: `largestGapEpsilons`, `cholesky`, `worldEnergy`. doc-sync's sources for the course gain the probes'
  kernels and the device test, which the chapter now quotes. CHECKED: doc-folds, doc-sync, lint.
- Nov 5: THE TRACKER's CONTACTS ARE robot.zig's FLOOR (robotgpu P3a): `Task.contacts` = `.robot_floor`, MuJoCo's plane
  functions, the contacts robotgpu's device makes - for the fleet (training, the judge, planners) and `ServoRun`.
  Measured first on the servo over the 10-second dance at equal friction: time to failure 3.15 s against zimrphysics'
  1.55 s; none of zimrphysics' contacts there was between Geno's own bodies (his model excludes self-collision). S2c
  still holds the T-pose 10 s. Every earlier number in this plan was measured on zimrphysics' contacts.
- Nov 6: TWO CHANGES TO THE ACTION, planned in robotgpu's P4 (its section 3), both for the learners to take up:
  (1) THE FILTER BACK, AT THE PHYSICS RATE (Simon): before each physics step the applied action moves halfway to the
  policy's (0.5), not in the policy's input; one filter, the simulator's - S0b's `Options.filter` and S0c1's
  `lat_filter` stay at 1, never two in series. The world model then wants the previous decision's action as an input
  (a given beside the state), since the motion over a decision depends on it by the share still applied at its start
  (25% at two physics steps a decision). (2) VARIABLE STIFFNESS PER LIMB (Spoljaric, Yan & Lee 2025, arXiv
  2502.09436; the study in robotgpu's journal): one stiffness number per limb joins the action - Geno's six limbs from
  his tree, 69 -> 75 numbers - setting the limb servo's spring frequency f0 3^(s/4), 15.2 to 26.3 Hz about the tuned
  20; a stiffness cost in SuperMimic's reward (-0.1 on the limbs' mean s^2) where the paper charged joint power; behind
  a switch, off by default. FOR THE LEARNERS: the actor's and the world model's action width from the task's action
  layout rather than `actionSize` alone; SuperTrack's cost (`TrackingCost`) and the planner's given the stiffness
  term; the judge actor and the policy files carrying the layout and the filter's factor.
- Nov 6: OFFSET AND STIFFNESS, DECIDED (Simon): (1) THE ACTION STAYS TARGET OFFSETS AND STIFFNESS - never accelerations
  or torques (force-level actions learn much harder: Peng & van de Panne 2017, "does the choice of action space
  matter?", and Simon's own experience). (2) THE 0.5 FILTER COVERS THE STIFFNESS TOO - on the device it already does
  (`filter_actions` runs over every number of the action), and `robot.filterAction` over the fleet's whole action will
  once the stiffness joins it; the filtered action stays out of the policy's input - the policy learns to act through
  the filter, which pushes it toward smooth actions. (3) IN CALM SITUATIONS the stiffness should be chosen so that a
  smooth, even near-constant offset across states works. (4) PENALTIES ON RAPID CHANGE OF OFFSET AND STIFFNESS AS THE
  STATE AND THE GOAL CHANGE - to design. CANDIDATES (brainstorm, Nov 6): CAPS's temporal and spatial terms in the
  actor's loss (Mysore et al. 2021) - the spatial one taken in the world model's latent space, where nearness means
  similar dynamics; the change measured against how far the situation moved (a Lipschitz ratio, or a Jacobian penalty
  by finite differences) with the offset weighted above the stiffness, so the stiffness does the adapting; the
  stiffness's change under an absolute (total-variation) penalty, so it holds steady and switches at events - a
  landing, a push - the filter turning each switch into a ramp; a mirror-symmetry loss (Yu, Turk & Liu 2018: mirrored
  situations, mirrored offsets and stiffness); the smoothness weight lowered where the situation is not calm (the
  world model's predicted deviation, an aftermath), so smoothness never fights a recovery.
- Nov 6: THE SMOOTHNESS, CHOSEN (Simon: "I want to try 1 and 2. The goal is to find simple policy with stable offset
  and stiffness."). In every actor's loss (SuperTrack's through the world model first; EfficientTDMPC's and PPO's
  actors after), two terms over the whole action - offsets and stiffness alike: TEMPORAL, the squared change of the
  policy's raw action between consecutive states of a window, `||pi(s_t+1, g_t+1) - pi(s_t, g_t)||^2` (CAPS, Mysore
  et al. 2021); SPATIAL, in the world model's latent space - where nearness means similar dynamics -
  `||pi(z + eps) - pi(z)||^2`, eps Gaussian at a fixed share of each latent's spread, one extra actor pass a sample.
  Weights and the noise's share to measure. Generic, so zimrrl's: the two terms as building blocks there, with the
  zimrrl tutorial. NO STIFFNESS COST: high stiffness makes the offset change fast across states (a small error is a
  large force), which the spatial term charges, and spends torque and energy, which the reward charges (robotgpu
  P4f: energy |tau q'| dt over the decision per unit of mass, torque (tau / (m g))^2). The stiffness's tie-break and
  the -0.1 mean s^2 of Nov 6 are withdrawn.
- Nov 6: EFFORT BEYOND THE REFERENCE's (Simon: "Return to ref should feel like ref"). The reward's effort terms are
  measured against the reference's own effort (robotgpu P4f): the reference's torques per frame by the servo's own
  floating-base inverse dynamics at the reference's state and accelerations, so a character on its reference is
  charged nothing and a returning one only what it spends beyond the reference - energy |dtau q'| dt per unit of
  mass, torque (dtau / (m g))^2, dtau = tau - tau_ref. FOR THE LEARNERS: PPO's and EfficientTDMPC's actors see them in
  the reward as it is; SuperTrack's policy, trained through the world model on predicted states, cannot compute a
  torque from a predicted pose - so its world model gains a head predicting each decision's two effort sums from the
  same latent and action (trained on the sums the replay records), and the policy's cost charges the predictions. The
  replay's record gains the two sums.
- Nov 6: ONE NIGHT, EVERY IDEA (robotgpu_plan section 3, THE NIGHT). The learners' part of it: the world model reads the
  previous applied action (the filter at 0.5 learnable) and the action's width carries the limbs' stiffness (C5); an
  effort head (C6); CAPS's terms (C7); a SECOND WORLD MODEL AT 0.1 s - three decisions ahead from the state and the
  applied actions over them, on the same ring, giving the policy long windows in few steps (C8); FLOWDPG BACK as an
  offset on the SuperMimic policy, trained toward the first offset of plans found by MPPI in the device's own physics -
  K candidate worlds per planning character, copied from it, simulated H decisions by the true physics and tracker
  (C9) - so good trajectories exist before any world model has learned. Diagnostics D3-D5 read the learners: every loss
  term, the norms, the actions' statistics, and each world model rolled open-loop beside the physics.
- Nov 6: robotgpu_plan v3 (v2 archived) holds THE NIGHT - every component, the learners' included (C3-C9), with its
  check; this plan keeps the learners' history and reasoning.

- Nov 11: THE ODDS, IN THE NIGHT's PLAN (Simon: "Add this to the plan. Build and proceed"). Seven additions to the
  night are written in `robotgpu_plan.md` section 4b (O1-O7), with the order of the work from there. What they move
  in this plan: TEACHER FIRST - the true-physics planner feeds the policy by distillation before the skip model's
  jumps and the flow (T2, T4, F1-F3 follow it); R1, the hardest states kept, moves up as O5 with ground starts from
  the physics' own resting poses; S2, the policy's slow average, moves before the night as O6b; S1's real fit becomes
  lambda-returns over the recorded windows (O4); and a learning ladder (O1) stands in front of the night as GT1's
  first evidence - the policy above the servo on two seconds, five seconds, the minute, then under pushes.
