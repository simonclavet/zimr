# SuperTrack, EfficientTDMPC and the way back - the plan (v5, Oct 31 2026)

v4, with every decision's design and measurement from Sep 27 to Oct 30, is `archive/rl_track_plan_v4.md` (v1-v3
before it); the day-by-day account is `rl_track_journal.md`. This file says where we are and what comes next.

## The goal

A character tracks a minute of motion capture (dance, get-up, walk, run) and, when pushed hard or fallen, finds its
way back to where the reference has got to - precisely, by complicated returns where needed. Half of the compute goes
to DISCOVERING returns and learning from them (planning, reanalyze, the flow's teachers); half to SuperMimic's
learning of the world model, the policy and the critic.

Night 1 is handed over (`night1_handover.md`): reproduce, improve (returns), full (flow and planner).

## What exists - verified in the code, Oct 31

THE LEARNER (`robot_track_resident.zig`). A round: the CPU acts every character from a mirror of the GPU's weights
(three-phase acting, parallel over the physics threads - `ActingScratch`), records into the ring; the GPU trains in
ONE FRAME per round (every upload of a frame lands before its work). Options: returns (`return_steps`, the aftermath,
`return_window_share`, starts in trouble), pushes on a schedule in training hours, the reset curriculum, rates on a
cosine in hours, gradient bounds for the policy (`policy_gradient_clip`) and the world model (`world_gradient_clip`),
the bounded cost (`return_cost_cap`), the watchdog and state checkpoints. `PlanningSettings`: hazard-driven slots
(`flags`: `budget`, `start_hazard`, `stop_hazard`, `calm_steps` - hysteresis - and `replan_every`, but ONE decision
per frame, so once a round in practice), `candidates`, `horizon`, `rounds`, `elites`, `flow_plans`, `temperature`,
the knots (`fine_steps`, `knot_span`), teacher 2's `distill_weight` / `distill_rows` / `distill_examples`.

THE KIT (`robot_latent_kit.zig`):
  - `LatentKit` - SuperTrack's world model (three dense layers, residual in normalised features: `lat_advance`) on
    recorded windows (`forwardRecorded`, `world_steps` 8), the policy through it (`steps` 32), `stepWorld` with its
    clipped Adam; the ring's window gather (`Resident.gather`: a start per row - character, ring position - per slot).
  - `SkipModel` - BUILT, NOT YET IN THE LEARNER: the world model's three layers over [z | the span's references and
    actions] predicting the change over the span; trained on the world model's windows (`lat_skip_gather`,
    `lat_skip_targets`); its own clipped Adam; device numbers `skip_model_loss`, `skip_model_jump_error`,
    `world_model_span_error` (the gate's pair, one recorded start).
  - `LatentCritic` - EfficientTDMPC's two-hot value heads (2) with target copies, discount 1 - 1/90, learned by
    temporal differences on the windows' REAL transitions; its `Tail` (`forwardValues`) read by the policy's loss and
    the planner. NOT value-equivalent: never trained on the world model's predicted states, where it is read.
  - `FlowActor` - the flow with three teachers (FlowDPG, the planner's distillation, FPO) sharing each update
    (`kit_mlp.TeacherShares`); teacher 2's batch is the acted planned steps (condition, the plan's correction),
    uploaded once a round.
  - `TrackingScorer` - a candidate rolled closed-loop (the policy reacting, the correction added), each step's cost
    (`runTrackingCost`), the critic's heads after the LAST step only, combined by its own kernel
    `tracking_plan_scores`: -(sum of costs + tail weight x (heads' mean + beta x spread)). ONE world model.
  - `TrackingPlanner` - MPPI (`bmpc_kit.KitMppi`) at knots (`zn_mlp.planKnots`: fine steps, then one every span), the
    flow's plans as proposals, the plan's age warm-starting, `plan_gain_stats`, the mailbox read back.
  - `DeviceStats` - every device number, flattened into the log (`robot_lab.SuperTrackLog`).

EFFICIENTTDMPC ON THE GPU (`robot_bmpc_kit.zig`) - complete, NOT in the trainer (it refuses `efficient_tdmpc`):
`KitRollout` (every dynamics head unrolled through the window), `KitWorldModel` (reward and value heads trained on
the rolled latents - value-equivalent), `KitPlanScorer` (scores through `plan_score_combine`: dynamics heads x value
heads, the objective's weights, pessimism as eq. 10), `KitMppi`, `KitPlanner`, `KitLearner` with REANALYZE in chunks
(each stored state its own search). `zimrrl.PlanObjective` - `final` and `mean_over_depths` (eq. 6) - as weights on
rewards and values (`planObjectiveWeights`, tested by hand).

THE LAB AND TRAINER: the judge per clip, the recovery probe (`track.probeRecovery`; the servo, a policy file or the
learner's own actor - NEVER planning), the status, the collapse alarm, run files.

## What is missing

Against EfficientTDMPC: the tracking planner reads the critic only at the end (no prefix values); one world model,
a critic not value-equivalent, no averaging over models; pessimism 0 in every run; a search some 25 times smaller
than its acting search (about 20 samples x 2 iterations against 512 x 6-8). Against our goals: no reanalyze for
returns (teacher 2 learns from acted plans only); no measure of what plans promise against what the physics gives;
the skip model not trained by the learner and the planner not jumping; a probe that cannot plan; no account of where
the compute goes; SuperMimic's rollouts at one resolution through one model.

## Principles

  - One definition: the tracking planner scores through `plan_score_combine` with `planObjectiveWeights` - no second
    objective kernel; a reanalyze planner is a second `TrackingPlanner` on the same networks (the BMPC kit's
    pattern); an ensemble is heads inside the kit.
  - Every turn: compile, targeted tests under five minutes, the tutorial in sync, a snapshot. The full gate before a
    night.
  - Measured before trusted: the plans' honesty, the skip model's gate, the gradient's direction through jumps.

## The next ten turns

T1  PREFIX VALUES - EfficientTDMPC's multi-horizon objective in the tracking planner.
    Build: `TrackingScorer.score` keeps its rollout and step costs; the critic's heads at EVERY depth with weight
    (`Tail.forwardValues` into [dynamics head 0][depth][value head][rows]); the objective's weights from
    `planObjectiveWeights(objective, the critic's discount)` uploaded at the planner's start - costs and cost-to-go in
    as NEGATED weights, the value weights times the tail's weight (re-uploaded when the trust ramp moves it); the score
    by `plan_score_combine` (dynamics heads 1, value heads 2, pessimism beta). `tracking_plan_scores` removed.
    `PlanningSettings.objective` (`zimrrl.PlanObjective` given a fixed tag type so an extern struct can hold it).
    Note: pessimism becomes eq. 10's - beta standard deviations of the MEAN over (model, head) pairs.
    Verified: `plan_score_combine` reads rewards [dynamics head][step][rows] - the step costs' own layout - and values
    [dynamics head][depth][value head][rows] with EVERY depth allocated, read where its weight is not 0; a step's cost
    is that of the state it leads to, so "the first h costs, then the critic at z_h" is the critic's own recursion
    (C(z_0) = c(z_1) + gamma C(z_1)) cut at depth h.
    Check: `final` with discount 1 gives the old formula's scores on planted costs and values (host); `mean_over_depths`
    gives eq. 6 by hand; the full system on lavapipe with each objective - finite, planner gain logged.
    Tutorial: "a plan judged by every prefix".

    DONE Oct 31. `TrackingScorer.Options.objective`, `discount`; `objectiveWeights` (the one computation - negated,
    the values' times the tail's weight as it stands, 0 without a critic) reaching the device two ways - into the
    host's activations by `writeInputs` (the tests), uploaded at every decision's start by `writeObjective` (the trust
    ramp moves the tail's weight); the critic's heads at every weighted depth into [depth][value head][rows]; the score
    by `plan_score_combine` (one model, the critic's 2 heads - 1 without a critic, its weights 0 so nothing is read);
    `tracking_plan_scores` removed; `zimrrl.PlanObjective` given a u32 tag; `PlanningSettings.objective`, the critic's
    discount passed (state ZSTSTA15). Checked: every scorer and tracking-planner test unchanged (no critic, `final`,
    discount 1: the old formula); a learner test - mean over depths, the critic trusted whole, a pushed character's
    decision - its uploaded weights exactly zimrrl's negated, every candidate's score recombined from its costs and the
    critic at every depth; the learner's slow suite run directly, 35 of 35. The full system, one seed, `final` against
    `mean_over_depths`: both finite, the search choosing its own plans throughout; gains 0.03 -> 0.6 and 0.01 -> 0.38,
    in each objective's own units (not comparable - T5's honesty compares them). `final` now discounts its costs with
    the critic's gamma, as the critic costs a future. FOUND: a FlowDPG test's `log.warn` made the build runner print
    "failed command" in every run of the learner's suite while all passed - now a `report.print`, as every
    measurement is; a real failure can no longer hide in that line.

T2  THE SKIP MODEL IN THE LEARNER (TS2b).
    Build: `Options.skip_span` (0: none), the lab's mirror and check (at most the world model's window); reserved in
    `buildExtras` after the flow, before the saved parameters' end (the flow's count taken first); its starting
    weights (`writeStartingParams`) with the learner's random stream; `kit.skip_model` set; state version up.
    Check: a learner test - skip span 4, a few rounds, its loss finite and falling, saved and loaded with the state;
    the full system: the gate's pair in the log (`skip_model_jump_error` against `world_model_span_error`).
    Tutorial: the skip model - what it predicts, how it learns, the gate.

    DONE Oct 31. `Options.skip_span` (`SavedOptions`, the lab's mirror; the lab refuses a span over `window`); a skip
    model counts as an extra; reserved after the flow's count, inside the saved range; its starting weights from the
    learner's stream; `skip_parameter_count` - a fifth named block in the state header, counted against the saved
    range and compared on loading (state ZSTSTA17). FOUND by the test: the header's named blocks must cover the range,
    and a block without a name stopped the save - as designed. FOUND while adding the header's field: the saved
    settings HAD PADDING - three bools (`PlanningSettings.enabled`, `FlowSettings.share_teachers`,
    `SavedOptions.train_critic`) each followed by three hidden bytes, and four before the 8-byte seed - so a state file
    could hold bytes the learner never wrote (the round-trip test passed only because they happened to agree). Now:
    `hasNoPadding`, a compile-time guard on the header and every struct inside it; explicit zero padding words where
    the holes were; `savedOptionsOf` starting from zeros; the options' check allowing `padding_` words. Checked: the
    learner test - skip span 4 in 8-step windows, its loss finite and falling over a dozen updates, the gate's pair
    recorded, a saved state's skip weights restored number for number and saved again byte for byte; the learner's,
    lab's, kit's and kernels' suites (no "failed command" anywhere). The full system with a skip span of 4: buffers
    74 / 88 / 72% (parameters from 49% - its first layer reads four steps); the gate's pair EQUAL at the start (6.678 /
    6.680, ... 1739 / 1738 over six updates) - both models begin predicting "nothing changes", so their first errors are
    the recorded changes' own size; the comparison needs hours (a night). Tutorial: "a model that predicts several
    steps at once".

LESSONS FROM UNI-SUPERMIMIC (Oct 31; Simon: "Study this implementation of supermimic. What can we learn from it?
Also, maybe we could have the skip 4step model be just a new head for the existing one step model so it can share
layers?"). A PyTorch SuperMimic for the Unitree G1 on 4096 simulated environments (LAFAN1 clips, 50 Hz). Read:
`networks.py`, `learner.py`, `mdp.py`, `manager_terms.py`, the configs. In order of what they should change here:
  L1 TRAINING INTENSITY - per collected transition they train about 16 world-model step predictions and 13 imagined
     policy steps (10 world updates of 2048 eight-step windows, then one policy update of 4096 x 32, per ~10,000
     transitions); we train 0.5 and 2 (one update each of 32 windows a round of 512 transitions). Thirty times less for
     the world model, six for the policy - and our GPU waits on the CPU's physics. More updates a round cost no memory.
  L2 THE WORLD MODEL'S INCREMENTS NORMALISED: a running mean and deviation of the per-step CHANGE of every component;
     the network predicts it in those units, and its loss divides each component's error by its change's deviation -
     so a position judged against how far a position moves in a step, every component weighed alike. Ours predicts
     the change in units of the STATE's spread, where most per-step changes are small and weigh little.
  L3 THE CRITIC ON IMAGINED ROLLOUTS: lambda-returns (lambda 0.95) on the policy's own rollout, 5 epochs x 4 minibatches
     a policy update - TH3 / S3 confirmed as SuperMimic's.
  L4 SOFT TERMINATION: each imagined state's failure probability a sigmoid of the root's height and tilt errors past
     the thresholds (temperatures 0.02 m, 0.04); rewards weighted by the probability of being alive (a running
     product), the critic by survival at the end - a fall removes all reward after it, smoothly. Our counterparts: the
     failure barrier and the bounded cost (cap 25 a step, so a fallen state costs as much as tracking can). Kept as
     ours; noted.
  L5 A SLOW AVERAGE OF THE POLICY (0.995) is what they save and evaluate - the judged policy steadier than the live.
  L6 SMALLER ONES: LayerNorm + SiLU in the world model, 2048 wide, its output zero-initialised (ours tanh, 256, output
     a hundredth); the reward a sum of bounded exponentials with the reference re-anchored to the character's own
     position and heading; observation noise in imagination; 10 future goal frames encoded to a 32-number latent and
     10 frames of history; physics randomised per episode (friction, joint offsets, centre of mass) and given to the
     world model and critic as context; 500 iterations of the world model alone first. Their adaptive starts (one-second
     bins, 0.5 uniform / 0.4 softmax of low returns / 0.1 its average) are our reset curriculum already.

THE SKIP MODEL AS A HEAD OF THE WORLD MODEL (replacing TS2's separate network). The world model's rollout already keeps
each step's second hidden layer (`h2`, `hidden` wide) - its encoding of [z_k | reference_k | action_k]. The head reads
[h2_k | the next span - 1 steps' references and actions] and predicts the change over the span: the start state and
its first step encoded once, by the layers the one-step model trains. Its first layer reads hidden + 3 x (references
+ actions) instead of features + 4 x (references + actions) - far fewer parameters (72% of the parameter buffer back
toward 49%), and no first two layers of its own to compute (in training the rollout's `h2` is already there). Its
gradient STOPS at h2: the one-step model, whose accuracy the policy's gradient depends on, is untouched by
construction; letting it flow (shared learning) is a later, measured option. Its jumps: the window's first from
block 0 (the recorded start); the next from the rollout's own state at step 4 (the rollout writes its predictions
there), its target landing on the RECORDED state at step 8 - so the head learns to correct the model's drift, as a
planner's far half needs, its start being a predicted state too. The gate's pair stays (the first jump, from the
recorded start, against the world model rolled 4 steps).

THE NEXT TURNS, REORDERED (T3-T4 replaced; the rest follow, numbered on):
T3  THE SKIP HEAD: `SkipModel` re-based on the world model - `Shape` gains the hidden width; the gather reads
    [h2_k | steps k+1 .. k+span-1's reference and action] from the rollout's blocks; the targets as above; the head
    two layers (hidden, then the change); its backward stops at h2 (no gradient into the world model). The learner's
    state and test as before. Check: the gather against the host on planted blocks and h2; the learner test; the
    world model's loss with and without the head identical to the bit (nothing flows back); parameters' share.
    DONE Oct 31. `SkipModel` re-based as a head: `lat_skip_gather` reads [h2 at the jump's first step | the next
    span - 1 steps' references and actions] (the rollout's [step][row][hidden] hidden layer, the blocks' reference
    columns); `lat_skip_targets` from each jump's own block - block 0's recorded state for the first, the rollout's
    prediction for a later one - to the recorded state after its last step; one hidden layer (`initDense` with
    [hidden]); `Windows` names the blocks' state and reference columns and the hidden layer; the backward's input
    gradient goes nowhere. A span of at least 2 (the kit asserts it, the lab refuses 1). Its starting weights from a
    STREAM OF THEIR OWN (`options.seed` xor a constant) - drawn from the learner's, they shifted every draw after them.
    Checked: the gather and targets against the host on planted blocks and hidden layer (block 4's planted state as a
    rollout's); the learner's skip test (learning, saved and restored); A NEW TEST - two learners on fleets set up
    alike, one with a head: after six rounds the world model's and the policy's weights the same numbers; the
    learner's, lab's, kit's and kernels' suites. The full system: parameters 64% (72% the separate model, 49% none -
    the head's first layer still reads three steps of references and actions); the gate's pair equal within 0.2%
    over six updates (both near "nothing changes" still). The tutorial: "a head that predicts several steps at once".

T4  TRAINING INTENSITY (L1): `world_updates_per_round` and `policy_updates_per_round` - each update its own window-start
    slot in the frame, as now; the night files at, say, 4 and 2 where the device allows. Check: one per round is today's
    learner to the bit; counts in the log; a round's device time on Simon's machine (the handover's first ten minutes).
    DONE Oct 31 - THE MECHANISM EXISTED: `Options.world_updates` and `policy_updates` (each update its own window-start
    slot, `train`); a policy update is skipped, and counted as a refused window, while the replay is shorter than its
    windows. The night files at 4 and 2 (from 0.5 to 2 world-model steps per transition, 2 to 4 policy steps; SuperMimic
    16 and 13), the handover's rule to raise them while training stays below acting. (Run on lavapipe: 4 world
    updates a round - NOT A CHECK: those buffers exceed lavapipe's binding limit, found in T5.) WITH IT - THE WIDTHS (Simon: "We will tweak our networks sizes for supermimic, flow, and
    efficienttdmpc to be a third of what they do"): world model and policy 680 (SuperMimic's 2048), the flow as the
    policy, the critic's heads 170 (EfficientTDMPC's 512) - the critic was 32 wide, its default, in every run file. The
    trainer's buffers: parameters 2^23 floats (32 MB; the run needed 4 million), activations 2^26 (256 MB; 40 million),
    their gradients 2^24 (64 MB; 12.4 million) - past WebGPU's guaranteed 128 MB, the native trainer's alone. Measured:
    59 / 74 / 47%. FOUND: a configuration that did not fit failed as `KitTooSmall`, or as an assertion - now each
    buffer refused by name (`KitActivationsTooSmall`, `KitGradientsTooSmall`, `KitParametersTooSmall`; the learner's
    `KitLayout.checkFitsKit` an error, not an assertion). Checked: the kit's, learner's and lab's suites.

T5  INCREMENTS NORMALISED (L2): a running mean and deviation of the recorded per-step change of every feature; the
    world model's output in those units (`lat_advance` scaling), its loss each feature's error over its change's
    deviation. Check: a planted window where a feature's change is tiny - its error weighed alike; world model loss on
    the full system.
    DONE Oct 31. `robot_latent.measureClipIncrements` - each feature's change between consecutive reference frames
    in the normaliser's units, as the normaliser itself is measured (Geno's dance: spreads 0.031 at the 5th percentile,
    0.13 median, 0.80 max; 18 features constant in the reference); `Options.increment_spread_floor` (0 off; the
    floor 0.03, keeping every weight within about 20 of the median's); `lat_advance` reads mean + spread x output;
    `lat_scale_columns` - `LatentKit.changeGradient` scales the gradient into layer 3 by the spread (the world model's
    backward and the policy's), `weighLoss` the loss term by 1 / spread^2; the scorer's and flow plans' kits copy the
    statistics; the state version ZSTSTA18. Checked: the kernels against hand values; A KIT WITH THE STATISTICS AND A
    PLAIN KIT WITH THEM FOLDED INTO ITS LAST LAYER predict the same states, their gradients equal but layer 3's, which
    is the spread times - the chain rule through every layer at once; a learner test - the placed statistics exactly
    the measurement on its clips, the weights 1 / spread^2, learning finite (it caught a learner reading its own
    normaliser before it was set - the measurement now takes the one given to `init`); every suite with it off.
    FOUND: the desktop buffers (256 MB of activations) exceed lavapipe's maxStorageBufferRange (128 MB) - every run on
    it since the widths changed bound past the device's limit (validation errors, undefined reads; T4's lavapipe checks
    were not valid). Now the Vulkan host refuses a storage binding past the device's limit, loudly, naming the group,
    the size and the limit (`Gpu.max_storage_buffer_range`); `-Dtrainer-portable=true` builds the trainer with buffers
    every device binds (`zn_mlp_sizes_trainer_portable.zig`: 128 / 32 / 16 MB) for smaller runs - this sandbox's.
    With it, on lavapipe (third widths, 16 windows, replay 128, 12 candidates): buffers 69 / 82 / 95%, the statistics
    off and on both finite, no validation error - but three rounds, one world update: THE WORLD MODEL'S LOSS WITH THE
    STATISTICS AGAINST WITHOUT IS STILL TO MEASURE (a longer run).

REVIEW (Oct 31, after T5). FIXED: T4's record claimed a lavapipe check that was not one (corrected above); the scorer's
64-step horizon limit (an assertion, from a stack buffer) removed - the objective's weights now have a host buffer from
the scorer's arena; the portable sizes' header to the line length. RE-READ, sound: T5's backward (the last step's loss
weighed before anything reads it; the change gradient formed then read by layer 3, in the world model's backward and
the policy's); every kit that rolls the world model copies its statistics (the scorer's, the flow plans'); FlowDPG's
gradient goes through the policy's backward, the only other layer-3 site. OPEN, in order:
  1. THE FULL GATE has not run since B4 - the widths, buffers, guard, skip head, padding guard and change statistics
     all landed after. Before any night.
  2. THE NIGHT FILES at the desktop sizes have never executed on a device that binds them: lavapipe cannot (128 MB),
     so Simon's first start is their first run (the guard stops it, naming the limit, on a GPU that cannot either).
  3. T5'S EFFECT is unmeasured: on this sandbox (restarted, now about two CPUs) a portable run did one round in four
     minutes, at 680 wide and at 256 alike. Two 256-wide runs, the statistics off and on, are left running in
     /tmp/runs/p256_*; read them, or measure on a desktop GPU.
  4. THE SKIP HEAD'S GATE needs hours of training to mean anything.
  5. Neither the skip head nor the change statistics is in the night files - deliberately, until measured.

T6  JUMPS, PART 1 (was T3) - the policy over given rows, the jump's staging, the head forward into the planner's blocks.
T7  JUMPS, PART 2 (was T4) - the planner's far half.
T8  SUPERMIMIC THROUGH JUMPS, PART 1 (S1; Simon: "Will we be able to use the skip model for supermimic training? I am
    thinking that backprop through time can benefit from having this 1 2 3 4 8 12 16 20 trajectory + final value. All
    this being small enough to be efficiently differentiated but reach far in time. I think we can say that the policy
    action is interpolated between 4 and 8, between 8 and 12, etc. So training and evaluating the skip model head takes
    action at beginning and end of the 4 step range(?). Does this make sense?"). YES, with one correction. THE POLICY'S
    ROLLOUT AT TWO SCALES: fine steps closed-loop through the world model (the policy reacting each step), then jumps
    through the head; the costs at the fine steps and the jump ends (each end's cost for the steps it stands for); the
    critic after the last. 8 stages reach 20 steps (4 fine + 4 jumps); 19 reach 64 (about a second, a return's time
    scale) - fewer than today's 32, so a shorter chain of Jacobians for the gradient to cross. THE ACTIONS IN A JUMP,
    interpolated - but the end action cannot be the policy's at the jump's END state, which the jump computes (it
    would be circular): the policy is evaluated TWICE at the jump's START state - with the next step's goal (its
    ordinary action) and with the goal at the jump's end (what it would choose from where the jump starts, for where it
    must arrive) - and the steps between are the straight line from one to the other: two differentiable policy
    evaluations a jump, the same straight lines as the planner's knots. THE HEAD KEEPS LEARNING FROM EVERY RECORDED
    ACTION (not the endpoints only): the recorded steps are not straight lines (the policy reacts, exploration adds
    noise); a head shown the ends only would average over steps it cannot see, while one shown all four learns exact
    data and reads a straight line as one input among many. Build: the jump stage in the kit's acting rollout (the
    trunk's two layers at the jump's start with its first action, the head, the state advanced) and its backward
    (the head's application gives its input gradient; back through the trunk's layers as functions - neither trained by
    the policy's update - into the start state and the two actions, into the policy). Check: forward - a jump of the
    rollout against the head's own forward on the same rows; THE GRADIENT'S DIRECTION (the gate): on the same windows,
    the policy's gradient through 4 fine + 4 jumps against through 20 single steps - their cosine, a device number. The
    head learns values, not slopes; until the directions agree the policy does not learn through jumps.
T9  SUPERMIMIC THROUGH JUMPS, PART 2: `Options.policy_fine_steps` and the jump count (0: today's rollout), the
    policy's update through the two-scale rollout once the gate agrees; the far stages' weight a setting (to start low,
    since a policy can exploit a model's errors as a planner can). Check: one scale is today's update to the bit; the
    full system's tracking and return probe against the single-step policy.
T10 THE PLANS' HONESTY (was T5). Then THE PROBE PLANS (was T6) and REANALYZE (was T7) open the next ten.
Queued: compute accounting and the discovery share (was T8), world-model heads and the value-equivalent critic (T9-T10),
L3 (the critic on imagined rollouts - with TH3), L5 (the policy's slow average for judging), S1-S3, R.

T3 (as first planned, superseded) JUMPS, PART 1 - the pieces a jump needs.
    Build: `LatentKit.policyOver(inputs_at, rows, raw_at)` - the policy's own layers over given [goal | state] rows;
    a jump's staging kernel (`plan_skip_inputs`): from a jump's start state, the span's references (the planner's
    blocks) and the actions (the policy's at the start state against each step's goal, plus the plan's corrections
    for those steps), the skip model's rows; the skip model's forward-only application; the predicted state written
    where the next jump and the costs read it (`blockZ`, the next block's state columns).
    Check: the staging against the host on planted blocks; `policyOver` against `policyStep` on the same rows; a jump
    of a zero-weight skip model leaves the state unchanged.

T4  JUMPS, PART 2 - the planner's far half (TS3).
    Build: the scorer's two-scale rollout - `fine_steps` steps closed-loop through the world model, then jumps of
    `knot_span` through the skip model; costs and the critic's values at the fine steps and the jump ends; the
    objective's weights over the whole horizon folded onto the depths that have states (a skipped depth's weight split
    between its jump's two ends in proportion - the cost read as a straight line between them); the tail at the end.
    Settings as before: fine steps 4, span 4, horizon 20 or 36 (the round a multiple of the span).
    Check: the folded weights by hand; with fine steps = horizon, today's scores to the bit; the full system with 4 + 4
    jumps - finite, a decision's work against the fine-only planner's.
    Tutorial: plans whose far half is scored in jumps.

T5  THE PLANS' HONESTY - what a plan promised against what the physics gave (EfficientTDMPC's Figure 11, exact).
    Build: at each decision, the chosen candidate's predicted step costs kept per slot (a copy kernel beside the
    mailbox); a round later, the slots' acted steps gathered from the ring (`Resident.gather`, the slots' character and
    ring position as starts) into a small kit of their own, their real costs (`runTrackingCost`); device numbers
    `plan_promised_cost`, `plan_delivered_cost` (means over the acted steps), the same for the best flow proposal.
    Check: the copy and the means against the host on planted rows; the full system: per-step against knots, `final`
    against `mean_over_depths` - which promise more than they deliver.

T6  THE PROBE PLANS - the recovery probe with the planner in the loop.
    Build: `ProbedController` gains the planning learner - its actor plus decisions for every pushed character from
    the probe's fleet, at a cadence the probe sets (every 16, 4 or 1 steps; the probe is single-threaded and the
    device idle between rounds, so no frame limit applies); `recovery.csv` gains the cadence.
    Verified: today's decision path is the learner's own (`planDecision`: its slots, owners and fleet), so the probe
    needs an entry that decides for given states and reference rows - the planner's staging and search, the slots'
    bookkeeping left to the caller.
    Check: on lavapipe, a short probe at each cadence - returns counted, numbers finite.
    Then the full gate. This is the instrument for R (replanning more often) and for horizons.

T7  REANALYZE FOR THE WAY BACK (E4) - planning on the replay where returns are learned.
    Build: a second `TrackingPlanner` (the reanalyzer) over a chunk of states - its own budget (EfficientTDMPC's
    reanalyze: 64 candidates, 8 elites, 3 flow plans), pessimistic - planning each round from the first states of the
    policy's RETURN windows (drawn from the aftermath) with their references; its chosen corrections written ON THE
    DEVICE into teacher 2's batch beside the acted examples (no host round trip).
    Verified - THE BUFFERS BOUND IT: a planner's rollout holds (horizon + 1) blocks for every candidate row; a chunk of
    8 states x 64 candidates over 16 steps would take about a third of the 128 MB of activations, beside the full
    system's 73%. EfficientTDMPC's reanalyze plans 3 steps with the final objective - here that shortness is what
    makes it fit: horizon 4 (the fine steps), chunks sized by the start's buffer line.
    Check: the examples' rows against the chosen plans; teacher 2's batch full from the first rounds; the full system.

T8  WHERE THE COMPUTE GOES - and half of it on discovery (C1, C2, E5).
    Build: each phase's device work counted on the host every round (dense layers: rows x inputs x outputs, the
    backward twice the forward) - SuperMimic's half (world model, skip model, policy, critic) and discovery's (acting
    search, reanalyze, the flow's teachers) - logged as `discovery_share`; `Options.discovery_share` (0.5) sets the
    reanalyzer's states per round to meet it; the acting search at EfficientTDMPC's size where the share allows
    (256-512 candidates at knots, 4-6 rounds).
    Check: the counts by hand for a small configuration; the share held on the full system.

T9  WORLD MODEL HEADS - a value-equivalent ensemble (E2, part 1).
    Build: `LatentKit.world_heads` (1 today): each head its own weights and optimiser regions, trained on the same
    windows from its own start; the critic ALSO trained on the states each head rolls from the recorded windows
    (EfficientTDMPC's value heads on every head's latents - the same targets); device numbers per head.
    Memory: the heads train IN TURN through the same blocks (each head's forward, backward and step before the next's
    gather of predictions), so activations do not grow with heads - compute does.
    Check: one head is today's learner to the bit; two heads train and differ; the critic's error on rolled states.

T10 THE PLANNER AND THE POLICY ON THE HEADS (E2 part 2, E3, S2).
    Build: the scorer rolls every candidate under every head IN TURN through the same blocks, each head's costs and
    values kept in its own rows of `plan_score_combine`'s layout, then combined over (head, value head) pairs - mean the objective, spread for pessimism where plans teach (the acting planner's beta, the
    reanalyzer's larger); the policy's update rolled through ONE head drawn per update (a policy that cannot keep
    exploiting one model).
    Check: the full system with 2 heads - honesty (T5) against one head; the probe (T6).

## Queued after T10

  - S1 SUPERMIMIC THROUGH JUMPS: the policy's loss through fine steps then skip jumps (the policy's actions in a jump
    taken at its start state), a horizon of about a second in fewer stages than today's 32; gated by the skip model's
    gate and a device number for the direction of the policy's gradient through jumps against through steps.
  - S3 prefix values in the policy's loss, and the critic's lambda-returns on imagined rollouts (SuperMimic's own).
  - R REPLANNING MORE OFTEN, as T6 measures it worth: slices of the round's device work with a decision between each
    (every 4 steps), bursts every step while a character is in serious trouble.
  - Flow chunks: one sample per knot span (acting's cost).
  - Brainstorm: discovered returns kept as reference clips; an archive of the hardest fallen states restarted from
    (Go-Explore); a tracking fleet and a discovery fleet.

## Settled facts worth keeping in view

  - The bounded cost (cap 25) makes the critic a time-to-return estimate; returns and their windows are in every run.
  - On the flow's weights FlowDPG's natural gradient is the LARGEST (about 0.002, against 0.0003 and 0.00015); shares
    set the balance (FlowDPG 1, distillation 0.5, FPO by the critic's trust).
  - The world model's gradient: 15-40 calm, 170-590 through falls; bound 50.
  - The search beats the flow's proposals by a growing margin (TH1) - finding or exploiting, which T5 settles.
  - At one decision a round the warm start carries only horizon - 16 steps; knots make it lossless where it carries.
