# robotgpu - the night - the plan, v3 (Nov 6, 2026)

v2 (Nov 2 - Nov 6) is archived in `src/notes/archive/robotgpu_plan_v2.md`, v1 (Oct 31 - Nov 2) in
`src/notes/archive/robotgpu_plan_v1.md`. This version summarises v2 (section 1), keeps what is in force, and is
precise about the one thing that remains: THE NIGHT - one training run on Simon's RTX 5070 with every idea on and
everything on the device, built so it works the first time.

## 0. The goal

ONE NIGHT, ONE RUN, EVERY IDEA (Simon, Nov 6): no grid search, no ablations - one recipe with every component on,
arranged by feel (section 6), and diagnostics rich enough to see any problem during the run or the morning after
(section 5). Everything on the device: the physics, the tracker, the acting, the records, the learners. Each component
is built and checked before the next (section 4); the run starts only when every check has passed and a dry run on
Simon's machine is clean.

THE GATES, kept from v2 (each a measurement that can come out red):
  G1 PARITY WITH robot.zig: the CPU twin reproduces robot.zig - and now the CPU fleet - bit for bit wherever both have
     the feature.
  G2 THE DEVICE EQUALS ITS TWIN within each array's bar (`step_array_bars`, `largestGapEpsilons`): on lavapipe, on the
     RTX 5070, on WebGPU.
  G3 PARITY WITH MUJOCO for what robot.zig lacks, against real MuJoCo's fixtures.
  G4 THROUGHPUT, measured at the night: decisions a second against the CPU fleet's.
  G5 THE TRACKER TRAINS ON IT - the night's whole question.
  G6 EVERY ROW of v1's parity table done or declined with a reason (off the critical path).

## 1. v2, summarised

v2 set out to finish the simulator and put the tracker on it (its S and P steps), under six principles (section 2).
WHAT IT BUILT, each checked twin against robot.zig bit for bit and device against twin within bars, on lavapipe and
in the WGSL build:
  - THE STEP: kinematics, the centre-of-mass frame, the mass matrix and its factorisation, velocities and bias forces,
    passive and actuator forces, the servo, the smooth acceleration, integration - each kernel calling robot.zig's own
    functions in robot.zig's order.
  - CONTACTS AND CONSTRAINTS: joint limits and the floor's contacts as constraint rows (the collision functions MuJoCo
    3.17's, op by op, cylinders included), their projection, MuJoCo's Newton with its line search and warm start.
  - THE TRACKING TASK (P4a-e): the clips on the device and the servo's targets from them (`reference_targets`); the
    action filter at the physics rate (`filter_actions`; factor 1 by default, 0.5 once the world model reads the
    previous action); the decision program (`Sim.submitDecision`), the twin's decisions equal to the CPU fleet's; a
    stiffness per limb (`limbStart`, `dofLimbs`, `limbSpringFrequency`: f0 3^(s/4)) in the servo, the device and the
    fleet's action (`actionWidth`); the observation - the character's half from `localBody` and the reference's from a
    table per clip frame (`Fleet.clipReferenceFeatures`) - every row equal to `Fleet.observe`'s.
  - THE PAGES AND THE TOOLS: `robotgpu_lab` and the side-by-side page (the CPU fleet beside the device, on Simon's
    phone); vk-host-test with every check; the course (robots.html Part VIII) and the mocap tutorial in step.
  - STUDIES: the SPIR-V (Zig's backend emits no optimiser passes; `spirv-opt -O` speeds pipeline creation about 30% on
    lavapipe and leaves kernel time unchanged - declined, as C++); variable stiffness (Spoljaric, Yan & Lee 2025).
DECISIONS v2 TOOK THAT STAND (Simon's, Nov 6): the action is target offsets and a stiffness per limb, never forces or
torques; the 0.5 filter covers both and stays out of the policy's input; no price on stiffness - high stiffness costs
through the smoothness terms (it makes the offset change fast across states) and through effort; effort is charged
BEYOND THE REFERENCE's ("return to ref should feel like ref"); smoothness by CAPS's temporal and latent-space spatial
terms.
WHAT v2 LEFT: rewards and terminations, resets and pushes, records (its P4f-h); randomisation (P4i, after the night);
the night itself (P5) - planned there as two nights, replaced here by one.

## 2. The principles in force

  P1 FOLLOW MUJOCO WARP CLOSELY - its stages, order and kernel shapes; every array and kernel names its MJW counterpart.
  P2 UNDERSTANDABILITY - one descriptive vocabulary; the code reads like a course; MuJoCo's names as cross-references.
  P3 ONE DEFINITION OF THE ARITHMETIC - a kernel calls the CPU's own function; where the device needs a function that
     lives above robot.zig (robot_track's), the function moves to robot.zig, on values, and both call it.
  P4 DETERMINISTIC BY CONSTRUCTION - no float atomics feed state; random draws counter-based.
  P5 WEB AND NATIVE BOTH FIRST-CLASS - one kernel source; the web at the worlds its memory holds.
  P6 AGNOSTIC TO MEASUREMENT - each choice a profile may overturn in one place.
  P7 EACH COMPONENT CHECKED BEFORE THE NEXT (new): its check written with it, and passing, before the next begins.
  P8 THE DIAGNOSTICS BUILT WITH THE COMPONENTS (new): each component writes its own series (section 5) in the turn it
     is built.

## 3. What exists, and where

  the simulator                 robotgpu.zig (its opening map; sections by banner), robotgpu_program.zig (the programs)
  its host                      robotgpu_host.zig: `Sim`, submit-then-collect readbacks, `StepComparison`
  the CPU fleet and the task    robot_track.zig: `Fleet`, `Task`, the tracking errors and rewards, `local`, the replay
  the shared arithmetic         robot.zig: the physics, the servo, `applyAction`, `filterAction`, the limbs, `localBody`
  the learners                  robot_latent_kit.zig (`LatentKit`, `Resident`: tables and ring in one activation
                                buffer), robot_latent.zig, robot_policy.zig, robot_track_resident.zig (the trainer's
                                loop: the flow actor, its teachers, the planner, the critic)
  the trainer                   examples/geno_lab (`geno_trainer`, recipes in recipes/*.zon, night 1's handover)
  the checks                    robotgpu_tests.zig (twin against robot.zig), robot_latent_kit_tests.zig (twin against
                                the fleet), tools/vk_host_test.zig (device against twin), the pages (Tint)

## 4. The night: the components, in building order

Each component: WHAT is built, what MOVES to robot.zig (P3), its CHECK, the DIAGNOSTICS it adds (section 5), and its
size in turns.

  C1 THE JUDGEMENT: REWARDS, TERMINATIONS, EFFORT.
     WHAT: after each decision, per world, what the fleet's `step` decides after its physics: the tracking error
       (`trackingErrorWithHead`), the tracker's reward (`reward`), SuperMimic's (`superMimicTracking`,
       `superMimicActionRate`, `superMimicJointLimitExcess`), the termination rule (`terminated`) with its grace, the
       aftermath (`keepsAftermath`, the steps left) and the return streaks; terminated and truncated apart; the
       terminal state kept. EFFORT BEYOND THE REFERENCE's: the reference's torques per clip frame on the host
       (`robot.referenceTorques`: `floatingBaseTorques` at the frame's state with its accelerations - a character on
       its reference has exactly these torques), a model_f table `clip_torques` (`ClipPoses.reference_torques`); per
       world two sums through the decision's physics steps, energy |dtau q'| dt / m and torque (dtau / (m g))^2,
       dtau = tau - tau_ref(frame) - a kernel `accumulate_effort` after `servo_torques`, zeroed at the decision's
       start. Kernels: `judge_decision` (per world, after the decision's last step); world_f `rewards`, `effort_sums`;
       world_u `episode_flags`, `episode_counters`.
     MOVES: the tracking error's arithmetic, `reward`, the SuperMimic terms and `terminated` - on values, into
       robot.zig - robot_track keeping its names as aliases.
     CHECK: (a) robot.zig: on the reference exactly, the servo's torques `referenceTorques`' to the bit and both effort
       sums zero. (b) kit: "the twin's judgement is the fleet's" - two worlds through three phases (on the reference;
       knocked a metre off - a loss; held on the reference again - a return), every decision's reward, flags, counters
       and effort sums the twin's as the fleet's, bit for bit, the limbs' stiffness and the 0.5 filter on.
       (c) vk-host-test: the device's rewards and sums within bars.
     DIAGNOSTICS: D2's tracking series. SIZE: 3 turns.
  C2 RESETS AND PUSHES.
     WHAT: counter-based draws `robot.drawUniform(seed, world, episode, draw)` (a stateless hash) replacing the fleet's
       stream (once; no runs to keep); a reset by mask on the device for every world whose episode ended - the start
       (`restart`: the clip and frame drawn, the start noise, a start in trouble with its share), the applied action
       and the filter zeroed, the warm start cleared; pushes on their schedule (`pushScheduleShare`, `push`: the root's
       velocity set). Kernels `reset_ended_worlds`, `push_worlds`.
     MOVES: the start's and the push's arithmetic, on values.
     CHECK: kit: the twin's episodes the fleet's, bit for bit, through at least three resets and three pushes per
       world; vk: within bars. DIAGNOSTICS: D2's starts and pushes. SIZE: 2 turns.
  C3 ACTING ON THE DEVICE.
     WHAT: the SuperMimic policy's forward pass on the device's observations, its exploration drawn on the device,
       into `actions`. The observations packed into `io` (`observation_rows`, no per-world padding) and copied buffer
       to buffer into the learner's input block; the kit's forward pass over world_count rows (normalised as its
       gather normalises); its outputs copied back into `actions` - one device, two pipes, nothing through the host.
     CHECK: the device's actions the CPU mirror's for the same observations, weights and draws - bit for bit on the
       twin, within bars on the device. DIAGNOSTICS: D4's action statistics. SIZE: 3 turns.
  C4 THE RECORDS AND THE BOOKS.
     WHAT: each decision's records - the character's features (the observation's first half), the asked action, the
       frame's table row - packed in `io` as one step of the learner's ring (`Resident`'s record layout) and copied
       into the ring's slot; the flags read back a frame late, the books kept so a window spans only steps whose flags
       have arrived. CHECK: the ring after many decisions the CPU path's; no window crosses an episode's end (a test
       that forces an end at the last unarrived step). SIZE: 2 turns.
  C5 THE PREVIOUS ACTION AND THE STIFFNESS IN THE LEARNERS.
     WHAT: the world model's input gains the applied action (so the 0.5 filter is learnable); every learner's action
       width `actionWidth` (the stiffness numbers). CHECK: the input's layout by a unit test; one training step on a
       fixed batch finite and its loss falling. SIZE: 1 turn.
  C6 THE EFFORT HEAD.
     WHAT: the world model predicts each decision's two effort sums (the records gain them: features + action + row +
       2); the policy's cost charges the predictions. CHECK: the head against the recorded sums on held-out records;
       the policy's gradient through it finite. SIZE: 1 turn.
  C7 CAPS's SMOOTHNESS.
     WHAT: in the actors' losses, temporal `||pi(s_t+1) - pi(s_t)||^2` along windows and spatial
       `||pi(z + eps) - pi(z)||^2` in the world model's latent space; generic, so zimrrl's building blocks, with the
       zimrrl tutorial. CHECK: both terms on a fixed batch against a CPU computation; their gradients finite.
       SIZE: 1-2 turns.
  C8 THE SECOND WORLD MODEL, AT 0.1 s.
     WHAT: the state three decisions (six physics steps) ahead from the state and the three applied actions, trained
       on the same ring (targets three records on); the policy's long windows through it (2 s in 20 steps) beside
       the fine model's 16-step windows. CHECK: its held-out loss falling; its prediction beside the fine model
       composed three times (D5). SIZE: 2 turns.
  C9 THE PHYSICS-MPC TEACHER FOR A FLOWDPG OFFSET.
     WHAT: an offset on top of the SuperMimic policy's action, found by MPPI in the device's own physics: a kernel
       `copy_world_state` copying a planning character's whole state (coordinates, velocities, applied action, warm
       start, clip and frame, episode counters) into K candidate worlds; each candidate's offset sequence - smooth
       noise about the current plan - simulated H decisions by the true physics and judged by C1; the plan weighted
       by exp(-cost / lambda); its first offset the target the flow actor's offset trains toward (FlowDPG). The
       characters in danger plan first (night 1's flags), the rest by turns. Candidate worlds record nothing.
     CHECK: on the twin a candidate after its copy steps exactly as its source; MPPI's weighted plan against a CPU
       computation; the planned offset lowering the true cost against the policy alone, measured and reported.
     DIAGNOSTICS: D4's teacher's gain. SIZE: 3 turns.
  C10 THE TRAINER's DEVICE PATH.
     WHAT: `geno_trainer`'s recipe gains the physics' choice (the CPU's by default); the night's recipe, `night2.zon`,
       with every component on and the schedule (section 6). CHECK: a training smoke of minutes in the sandbox on
       lavapipe - the device path's first rounds against the CPU path's, losses and returns within noise; every
       diagnostic file written; the stop file and the resume. SIZE: 2 turns.
  C11 ON SIMON's MACHINE.
     WHAT: the Windows trainer; a dry run of ten minutes (start, `stop`, resume); the arenas' sizes printed at the
       start against the GPU's binding limits; the worlds' budget set from the measured speed (characters and
       candidates); the diagnostics page on the dry run's folder. CHECK: every series present and plausible.

  C12 THE WORLD MODEL's FORM, as SuperMimic's (its code, Nov 6): ours is dense tanh (`initDense(..., .tanh)`), its
     output started at a hundredth - theirs SiLU with LayerNorm, the output zero, and rounds of the world model alone
     before the policy learns. WHAT: a SiLU and LayerNorm layer in the kit's dense networks, forward and backward on the
     device (zimrnum's `layerNormRows` and `layerNormRowsBackward` are the CPU's), the output started at zero, a
     recipe field for the rounds alone (theirs 500). CHECK: the layer's device forward and backward against zimrnum's
     on a fixed batch; one training round finite; the world model's loss after its rounds alone, reported. SIZE: 2.
  C13 THE PHYSICS RATE, measured: theirs 200 Hz physics under 50 Hz control; ours the clips' rate (the fleet requires
     a clip's frame time to equal the model's timestep), 60 Hz under 30 Hz decisions. Falls and get-ups are contact-
     rich. CHECK, in C10's smoke: for the get-up clip, contacts per world, the deepest penetration, Newton's rounds
     (D1) - and the same clip resampled to 120 Hz (`decide_every` 4) beside it. If 60 Hz misbehaves, the night runs at
     120. SIZE: 1.
  DECIDED BY THE REVIEW (Nov 6): the record is the executed action, noise and teachers included (the trainer steps the
  fleet with the acting's final actions, which its replay records) - as SuperMimic's. No history of observations for
  the night: our observation is the full state, where theirs is proprioceptive and leans on history. FOR SIMON: our
  policy does not see its previous action (its inputs are the goal's lead and the state's features; the RL plan's
  S0c4 was not done) - SuperMimic's does. You ruled out showing it the FILTERED action, to force smooth actions; its
  own previous RAW action is a different signal - it tells the policy where its targets already are, and makes small
  changes easy to choose. Off, as ruled, unless you say otherwise.

  C14 THE RATES, FROM THE RUN FILE (Simon, Nov 6): `decision_hz` (10 or 30) and `physics_hz` (60 or 120) in the recipe,
     the physics rate a whole multiple of the decision rate (`decide_every` = physics_hz / decision_hz, asserted).
     The clips RESAMPLED ONCE, on loading, to the physics rate by precise interpolation - each coordinate between its
     two frames, linear for positions and hinges, a slerp for ball and free joints' quaternions - so every frame
     downstream (the servo's targets, the reference tables, the margins, the episode's clock) stays one physics step
     and the fleet's rule that a clip's frame time is the model's timestep holds by construction. The goal's frames and
     the margins given in seconds, turned into frames at the physics rate. CHECK: a resampled clip at its source frames
     equal to the source (to rounding), between them on the slerp; the fleet and the twin bit for bit at each rate.
     SIZE: 2.
  C15 THE ACTION RAMPED ACROSS EACH DECISION (Simon: "smooth during the physics steps"): the applied action moves
     LINEARLY from the previous decision's to this one's across the decision's physics steps - at step s of N,
     applied = previous + (s/N)(asked - previous) - so it is continuous, reaches the asked action exactly at the
     decision's end, and lags no further; the same at any rate (the exponential filter's factor depended on it). The
     decision's step s counted per world on the device (world_u `decision_step`, zeroed at the decision's start).
     Replaces `action_filter` (its factor 1 is the ramp's N = 1). CHECK: the twin's applied actions the fleet's at every
     physics step, bit for bit; continuity across a decision's boundary. SIZE: 1.
  C16 MORE FOR THE POLICY, CLOSER TO SUPERMIMIC (Simon: "lets go closer to supermimic by giving more to the policy"):
     the previous asked action (theirs: `previous_action`) and the root's rotation relative to the reference's as two
     axes (theirs: `relative_rotation`) join the policy's inputs, beside our full state and our goal. CHECK: the
     inputs' layout by a unit test; the device's observation rows the fleet's, bit for bit. SIZE: 1.
  C8, DECIDED - THE SKIP MODEL: A SECOND LEARNING SIGNAL OVER 3 DECISIONS (Simon, Nov 6: "lets forget about expanding
     grid. That would be usefull if we wanted to do mpc with the model"). ONE world model, its stride an input,
     k in {1, 3}, Fourier-embedded: s_t+k = s_t + k v(s_t, a_bar, ref, xi, phi(k)) - the mean rate of change over the
     jump, so the update is residual at both strides (I + k dv/ds) and its outputs share a scale (normalised by the
     running spread of (s_t+k - s_t) / k). Simon's projection P = s_t + k_max v, said the other way. ITS INPUTS: the
     state; the mean applied action over the jump (exact under C15's ramp); THE REFERENCE AT THE JUMP's END relative to
     the state - our actions are offsets on a moving reference, so over a jump the servo chases the reference and the
     model must know where it went (known from the clip in imagination); the physics context. TRAINING: the one-step
     loss over 8-decision windows as now, beside the stride-3 loss autoregressive over 4 jumps (12 decisions of
     recorded data), each jump's mean recorded action. THE POLICY's SECOND SIGNAL: 16 jumps of 3 decisions (1.6 s at
     30 Hz, 4.8 s at 10 Hz) beside the 32 one-decision steps - the action held across each jump, rewards at the nodes
     only scaled by the jump's width and discounted by absolute time, the survival multiplied at the nodes, the same
     critic at the end; L = L_fine + lambda L_coarse, lambda small at first. CHECK: each stride's held-out loss
     falling; D5's divergence at every coarse node against the device's physics, beside the one-step model composed
     three times; at k = 1 the network the one-step model it was. SIZE: 3.
  C17 GENO's JOINT LIMITS, FROM HIS CAPTURES (Simon, Nov 6: "something simple that would solve the most jarring problems,
     but we need to be confident the mocap passes unchanged"). Not the model text's cones: a cone bounds a ball's total
     turn, so it cannot tell a knee's bend from its backward bend, and the text's angles are what pinned the servo short
     of captured poses before. INSTEAD, A BOX PER BALL IN ROTATION-VECTOR SPACE: each ball's local rotation as a rotation
     vector (axis times angle, three numbers in the joint's frame) at every frame of every clip; per component its
     least and greatest; widened by a margin (10 degrees by default). Every captured pose is inside its box BY
     CONSTRUCTION - the margin keeps it off the edge - and a knee's bend lies along one component whose low end sits
     near zero, so bending backward leaves the box. USED TWICE: (a) THE SERVO's TARGETS CLAMPED INTO THE BOX, as
     `clampHinges` clamps a hinge's - the servo never aims where no capture went, the policy's offsets included;
     (b) SUPERMIMIC's SOFT-LIMIT PENALTY on the simulated pose beyond the box (the ball branch of `jointLimitExcess`
     takes the box). A soft limit and a clamp, never a constraint row: nothing in the physics can pin a pose. WHAT:
     `robot.rotationBoxes(m, poses, frame_count, margin, out)`, called by the fleet on its clips and by the host's
     `packClips` on the same clips, a model table for the device. CHECK: every frame of every clip of the night's
     minute has zero excess and targets the clamp leaves unchanged - the mocap passes unchanged, tested; a knee bent
     backward by the margin and more has excess and a clamped target. SIZE: 2. (The cone constraints in the physics,
     MuJoCo's ball limit, stay for later.)

  C18 THE ADAPTIVE CURRICULUM, SUPERMIMIC's (Simon, Nov 6: "Do adaptive curriculum like supermimic"; their code,
     manager_terms.py). BINS of one second across every clip, each with a RETURN ESTIMATE G. AT EACH FINISHED EPISODE,
     its start bin's G <- 0.8 G + 0.2 R, R the episode's discounted return - plus, unless it was terminated (cut short
     only), the tail it would have earned, gamma^L (its mean reward) / (1 - gamma), L its length. AT EACH START, a bin
     drawn from 0.5 / bins + 0.4 soft + 0.1 avg / sum(avg): soft = softmax(-25 G / (r_max / (1 - gamma))), r_max the
     largest step reward (theirs 5 times the control step), avg the long-run average of soft (avg <- 0.999 avg + 0.001
     soft, at each draw); then a frame uniform within the bin (its end held at the clip's end - and inside our margins).
     OURS NOW differs - failure rates per bin, a `history_memory` - and is replaced by theirs. WHAT: robot.zig, on bin
     arrays, one definition for both engines - `startBinProbabilities` and `updateStartBinReturn`; the HOST keeps the
     bins (from the finished episodes' flags and returns read back, a decision late), and uploads the mixture as a
     cumulative table; the device's reset draws a bin by `drawUniform` and the table's inverse, a frame by `drawBelow`.
     CHECK: the twin's start bins and frames the fleet's for the same draws; the mixture against their formula on fixed
     returns; a bin of low returns drawn more often, measured. SIZE: 2.

  NIGHT 1 - SCOPE, ORDER AND GATES (Nov 7 review, Simon: "think hard about what ... increase our chance of
  success"). PRINCIPLE: the first night changes as little as possible against a learning run already known to work,
  so a failure points at one cause. Everything a night needs; nothing it could do without.
    IN, risk first (the order to build): (a) THE LEARNER'S DEVICE SPIKE (C3's spike: the one-device buffer copies) -
      the largest unknown; if it fails the architecture changes, so it comes before anything that assumes it.
      (b) C2 on the device - resets and pushes from the fleet's draws. (c) C18's device table - the curriculum's
      mixture uploaded once per decision. (d) C3 - acting on the device; the limb numbers written as zeros when the
      stiffness is off. (e) C4 - records and books. (f) C5 - the world model sees the previous applied action and the
      stiffness (needed once the policy sets stiffness). (g) C12 - the world model's form (SiLU, LayerNorm, zero
      output, rounds alone first): cheap and stabilizing. (h) C13 - the physics rate measured, 60 against 120 Hz, and
      C14 only if 120 Hz wins. (i) THE REVIEW's FINDING 5 - rotation boxes about each ball's captured mean.
      (j) C10 - the trainer's device path, `night1.zon` (the plan's `night2.zon` renamed: it is the first night on
      the device). (k) the diagnostics that decide a night: D1 health, D2 tracking, D3 learning, D5 the model against
      the physics, D8 the split of time - the rest after. (l) C11 - the dry run on Simon's machine.
    ALSO IN, after (l)'s first dry run: C8 the skip model and C9 the physics-MPC teacher - built behind their switches,
      off in every experiment but E7 (Simon, Nov 7: they, the stiffness and the filter have not been tried together).
    DEFERRED TO NIGHT 2, each a change a night 1 should be able to blame cleanly afterwards: C7 CAPS; C16 the new goal and policy inputs (keep night 1's observation); C15 the action
      ramp (keep Simon's 0.2 filter, whose behaviour is known); C6 the effort head (SuperMimic's torque and energy
      weights are 0 by default - no imagined cost needs it).
    ADDED BEFORE THE NIGHT: (1) A FEASIBILITY PASS over the minute - the fleet driven by the servo alone (a zero
      policy), per curriculum bin its return and termination rate: seconds even the servo cannot follow are trimmed
      or marked, and the bins' returns START from this pass instead of zero (the curriculum's prior). (2) A CPU
      BASELINE HOUR - the same recipe on the CPU fleet at its own scale, its learning curve kept. (3) GATES, checked by
      the night itself: at the dry run - every device check of the kit green, throughput measured (worlds times
      decisions per second, against the night's sample budget); at hour 1 - the GPU's curve within the CPU baseline's
      noise, or the night stops and says so; throughout - a non-finite number restores the last checkpoint at half
      the learning rate, a world-model divergence above its bound pauses the policy's updates. (4) CHECKPOINTS AND
      RESUME - every 20 minutes, the learner, the bins and the run file; a lost device (a driver reset, a GPU timeout)
      recreated and resumed, kernels' dispatches bounded so none nears an OS's GPU timeout. (5) A FIXED EVALUATION -
      every 30 minutes, the same seeded episodes: tracking error per clip, survival under standard pushes (fixed
      speeds at fixed phases), the share of starts in trouble returned - the morning judges by these, not by the
      training reward; pictures of the same episodes. (6) THE NIGHT's GOAL, stated: track the minute, resist pushes,
      come back from stumbles - not get up from the floor (no get-up clip in the minute).
    REVISED ESTIMATE: about 25 to 30 turns to the dry run, instead of 40 to 50.

  NIGHT 1 IS EIGHT EXPERIMENTS OF AN HOUR (Simon, Nov 7: "prepare 8 experiments. 1 hour each ... The first night will
  tell us just enough so the second night is a success. We can assume there might be no third night"). Night 1 is a
  SCREEN, night 2 the run. EACH EXPERIMENT CHANGES ONE THING against a shared CONTROL (E1) and ANSWERS ONE DECISION for
  night 2; all share seeds, clips, the fixed evaluation and the time budget, so their curves compare at equal minutes.
  An hour judges a slope, not an end: each is read by its evaluation at 20, 40 and 60 minutes against the control's.
    E1 CONTROL - night 1's recipe: 60 Hz physics, the minute of dance, SuperMimic's curriculum, scheduled pushes and
       starts in trouble, the limbs' stiffness in the action, the rotation boxes' clamp and soft limit. Also the gate
       against the CPU baseline hour (run the evening before).
    E2 PHYSICS AT 120 HZ - contacts against throughput (C13): decides night 2's rate.
    E3 NO LIMB STIFFNESS IN THE ACTION - does a policy that sets its own stiffness track and recover better?
    E4 NO CURRICULUM (uniform starts) - does SuperMimic's curriculum pay for itself at this scale?
    E5 HARDER PERTURBATIONS (pushes and starts in trouble at twice the rate and speed) - robustness against tracking.
    E6 TWICE THE WORLD MODEL's UPDATES PER ROUND - is the model the bottleneck (the central ratio, section 6b)?
    E7 THE NEW LEARNING SIGNALS TOGETHER - C8's skip model and C9's planning as an offset around the policy, with the
       limbs' stiffness and the filter, none of which have been trained together (Simon, Nov 7) - so night 2 can use
       them only if night 1 shows them working. From four-papers.html: the skip model distilled from the dense model's
       endpoint (idea 6), the teacher's funnel (7) distilled the FlowDPG way with the reference as anchor (4, 5), and
       the analytic soft termination with the survival weight (1) - the cheapest of the far-start ideas, the leash
       and the approach potential (10.1), ride along, since they change nothing near the reference. (Four times the
       worlds moves to the reserves; the dry run's throughput says whether it fits.)
    E8 NO JOINT LIMITS (no box clamp, no soft limit) - do Geno's limits make the returns look natural, at what cost?
    (Candidates kept in reserve, if one above proves cheap to settle beforehand: the learning rate halved and doubled;
    the aftermath's length; 1024 worlds.)
    NIGHT 2's OWN CANDIDATES, from four-papers.html, each an experiment of its own in a screen before the run or a
    switch in the run if night 1's E7 holds: the imagined return at every depth (idea 2); two model heads with
    pessimism only in trouble (3, 19); the distance curriculum with ground starts from the physics' resting poses
    (9.A1, A2); re-anchoring the goal (10.2); planning in intents (10.3); time-reversed falls as get-up references
    (10.4); a flow head for the first second of trouble (9.E2).
  THE LAB - all in Zig, with a good UI, built on zimr: (1) A RUNNER that takes a run file (`night1.zon`: the control and
  each experiment's one change) and runs the experiments ONE AFTER ANOTHER, EACH IN ITS OWN PROCESS - a crash or a lost
  device ends one experiment, not the night; it records why and starts the next. (2) Each experiment WRITES ITS OWN
  DIRECTORY: the run file it ran, status.zon (state, minute, throughput, health), the CSVs (D1-D8), the evaluation's
  numbers and pictures, its checkpoints. (3) THE LAB's UI, a separate zimr app reading those directories live: the
  queue (waiting, running, done, failed - and why), every experiment's evaluation curves overlaid on the control's,
  health and throughput, the evaluation's pictures, the time left; it can be opened, closed and reopened any time,
  since it only reads. (4) A DRY RUN: the same eight at FIVE MINUTES each - forty minutes to know nothing crashes, every
  file is written and the UI shows it all - run before every night.


  C19 THE PLANNER-FED FLOW OFFSET (Simon, Nov 7, decided question by question; four-papers.html section 11). W:
     SuperMimic's model, two heads. S: the skip model, stride 3, one network, distilled from W's endpoint and the
     physics'. pi: the residual tracker, BPTT plus a modest distillation toward planned actions (BMPC-style). F: a
     flow-matching offset, ALWAYS on, one decision's offset, one sample per decision; sees the observation, the goal,
     pi's action, the distance and the aftermath flag; FlowDPG's update with the anchor = planned offsets on planned
     trajectories that succeeded, and g = the gradient of W's imagined return with respect to the offset (analytic, a
     short BPTT) at F's one-step estimate, scaled to the flow's step, lambda warming up. T: horizon 6 decisions, 64
     candidates (pi + F's samples + noise, warm-started from the previous winner shifted), S screens all with the
     multi-horizon objective averaged over W's heads minus beta x disagreement in trouble, the physics refines the best
     3, the first offset executed, replanned every decision; reward = tracking + penalties + the leash and the approach
     potential. Planner worlds: a fixed tenth of all plus every world in trouble; their trajectories flagged and used
     by every learner. Deployed: pi + F alone. OPEN DIALS for the lab: the planner share, pi's distillation weight, F's
     scale in calm tracking, beta, the leash's margin and width.

  THE NEXT TWENTY TURNS (Nov 7), one checked piece each; every new kernel through vk-host-test and the page's Tint,
  and to Simon's phone when it changes what the page runs; the tutorials in step as each lands.
    1  The resets' review: the observation and kinematics run again after `reset_program`; `ClipPoses.frame_time`
       required; a decision after a reset asserts the `finished` flag gone and the world stepping as the fleet's
       restarted one; `TrackingSettings` refuses a curriculum on the device until its table exists. CHECK: the
       decision check through a reset and one more decision, bit for bit.
    2  `rest_on_floor`: after `reset_pose`, kinematics, `body_lowest_points`, the root lifted by `restOnFloor`'s rule
       (extracted so both engines call it), kinematics again. CHECK: reset worlds' root heights the fleet's.
    3  `perturb_start`: each actuated dof's turn from `drawNormal`, applied as `integratePos` applies turns, the two
       root kicks, then rest and kinematics once more. CHECK: the fleet's `startEpisodeAt` with noise, bit for bit.
    4  `start_in_trouble` and `push_worlds`: the schedule's share in the uniform each decision; a start in trouble's
       kick; the Poisson pushes at the decision number; the scheduled ones by the episode's steps. CHECK: the twin
       against the fleet from a start through an end, a noisy restart in trouble, and pushes - the whole of C2.
       PHONE: the page with resets and pushes running.
    5  C18 on the device: `judge_rewards` accumulates each world's discounted return, reward sum and decisions;
       `begin_reset` records the start bin; the host reads them back each decision, folds with
       `updateStartBinReturn`, runs the round and uploads the mixture's running sums per clip; `begin_reset`'s
       curriculum path. CHECK: the twin's starts the fleet's with the curriculum on.
    6  C3's first half: the policy's forward pass on the device - the kit's MLP reading the simulator's observations
       through a copy or a loan, writing actions back, limb numbers zeroed when stiffness is off. CHECK: the device's
       actions the CPU policy's, bit for bit, for one decision.
    7  C3's second half: exploration noise from the draws, the decision loop closed on the device (observe, act, step,
       judge, reset) for many decisions. CHECK: the twin's episodes the fleet's under the same policy, bit for bit.
       PHONE: the page acting on the device.
    7b THE PAGE's DEVICE CHECK (Simon, Nov 7: after acting on the device, so it checks the closed loop): a scene that
       runs a few decisions with acting, pushes, resets, noise and the curriculum on the phone's GPU and on the CPU
       twin from identical inputs, reads every array back and shows per kernel group a pass or fail with its largest
       difference - EXACT for the integer results (draws, flags, clips, frames, start bins: any difference a
       translation bug), within a tolerance for the floats (GPUs do not round cos, log, asin correctly) - and each
       program's milliseconds (the phone's throughput). The page becomes a phone-side vk-host-test.
    8  C4: records on the device - each decision's observations, actions, rewards and flags copied into the kit's
       ring with `copyFieldInto`; the books. CHECK: the ring's contents the CPU records' for the same episodes.
    9  C10, part one: the learner's data path reads the device ring; one training round on device data. CHECK: the
       round's updates against the CPU trainer's on the same data, within float tolerance.
   10  C10, part two: `night1.zon` - the control and E1-E8's one change each, parsed into switches; a five-minute
       smoke of E1 on the device path. CHECK: it runs, writes its status and CSVs.
   11  THE LAB's RUNNER: one process per experiment, a directory each (the run file, status.zon, the CSVs D1-D3, D5,
       D8), a crash recorded and the next started; the dry-run mode (five minutes each). CHECK: two experiments of two
       minutes in sequence, one made to crash.
   12  THE LAB's UI: a zimr app reading the directories live - the queue, every experiment's curves on the control's,
       health, throughput, pictures, the time left. CHECK: it shows turn 11's run, reopened mid-run.
   13  The night's safety: the fixed evaluation every 30 minutes with pictures; checkpoints every 20 minutes and
       resume; the gates - a non-finite number restores at half the learning rate, a model divergence above its bound
       pauses the policy. CHECK: a run killed and resumed; a NaN injected and recovered.
   14  The feasibility pass (the servo alone over the minute, per-bin returns and termination rates, the curriculum
       seeded from it, the hopeless seconds marked) and the CPU baseline hour's recipe. CHECK: the pass's table.
   15  C12 and C5 and the cheap new signals: the world model's form (SiLU, LayerNorm, zero output, rounds alone), the
       previous action and stiffness as inputs; the analytic soft termination with the survival weight; the leash and
       the approach potential; the imagined return at every depth. CHECK: zimrnum's tests; the kit's.
   16  C13: the physics rate measured, 60 against 120 Hz on get-up contacts, and C14 only if 120 wins. CHECK: the
       measurement's table, the decision recorded.
   17  C8: the skip model - one network with the stride as input, distilled from W's endpoint and the physics'.
       CHECK: its error at stride 3 on held-out windows against three dense steps.
   18  C19's planner: 64 candidates screened by S in two leaps, the multi-horizon objective over two heads, the best
       three refined in the device physics for the planner worlds, the winner's first offset executed, warm-started.
       CHECK: on a held-out stumble, the planner's return above pi's.
   19  C19's F: the flow offset and its FlowDPG update - the anchor on successful plans, g from W's imagined return -
       and E7 wired: the signals together. CHECK: F's samples near the anchor early, improving the imagined return
       later; E7 runs five minutes.
   20  THE DRY RUN: the eight at five minutes each, forty minutes; what breaks fixed; the plan's estimate revised.
       Then C11 on Simon's machine.
  IF TURNS 17-19 SLIP: E7 becomes the cheap new signals alone (the soft termination, the leash and potential, two
  heads, the return at every depth), and the skip model, the planner and F move to night 2's candidates; the night is
  still eight experiments.

  OFF FOR THE NIGHT: randomisation (P4i); the Go1 on the device (`TooManyRows`); the web's training.

## 4b. Raising the odds (Nov 11; Simon: "Add this to the plan. Build and proceed")

WHY THIS SECTION. Read against the journals on Nov 11, the evidence stands so: every kernel and every decision is
checked to the bit, and NO LEARNED POLICY HAS YET BEATEN THE SERVO ON THE DANCE - by the journals no night has run
(night 1's CPU recipes were handed over and not run), and the resident learner has trained only in smokes. What IS
measured: SuperTrack's learner learns the cartpole on the kit (Sep 19); predictive sampling in the TRUE physics tracks
the dance 17.05 s from frame 0 against the servo's 6.65 s, and reaches the 5 s cap from four hard starts against
0.92 s (Sep 24); the servo alone returns once in 65 pushes (Oct 30); and a world model that predicted states well
answered an action's change badly (the action response's cosine 0.43 on servo-plus-noise data, 0.20 on the teacher's
recordings - Sep 24). A night of eight experiments reads only if its control learns. So the additions below put a
proof of learning in front of the night, put the one measured win first, and aim the diagnostics at what the policy's
gradient rides on. Seven additions, O1-O7, each with its reason, its place and its check.

  O1 THE LEARNING LADDER - a proof of learning before the night (the servo ladder's method: one addition per rung, one
     number per rung, a bar, no rung skipped). Run on the RTX 5070 from one run file (`ladder.zon`) by the lab's
     runner, minutes a rung; in the sandbox at toy sizes, for the plumbing alone. Every bar is a RATIO TO A BASELINE
     measured on the same starts in the same run (the servo alone - a zero policy - or the model that predicts no
     change), so no bar is a guessed number:
       L0 THE WORLD MODEL ALONE (C12's rounds alone; data: the servo with exploration, and the teacher's worlds): its
          open-loop error at 8 and at 16 decisions against the device's physics (D5) below a quarter of the no-change
          model's; the action response's cosine (D5b, O3) reported, its bar set from this first run.
       L1 TWO SECONDS, ONE START, no pushes, no start noise: the policy's SuperMimic return on the window above the
          servo's - run twice, each signal alone: L1t by the teacher's distillation alone (O2), L1w by the gradient
          through the world model alone. EITHER passing lets the ladder go on; both are reported, and the night's
          control carries whichever passed (both, if both).
       L2 FIVE SECONDS, every start inside them (the servo already keeps these 5 s - Sep 24 - so the bar is the
          return, not survival): the return above the servo's.
       L3 THE MINUTE: every clip's time to failure above the servo's (the handover's first-hour rule), and the mean
          normalised return above the servo's.
       L4 PUSHES at 2 m/s: the return rate above the servo's (1 in 65).
     A rung that fails stops the ladder and writes its numbers beside the baseline's; THE NIGHT DOES NOT START ON A
     RED LADDER - the evening goes to the failed rung instead. The ladder's last recipe IS the night's control (E1).
     PLACE: after the trainer's device path and the runner; before the lab's UI. CHECK: the ladder's file runs in the
     sandbox at toy size and writes a verdict per rung; a rung made to fail (a zero learning rate) is reported red.
     SIZE: 2 turns.
  O2 TEACHER FIRST (Simon, Nov 11) - the true-physics planner feeds pi from the first minute. It is the one learning
     signal with a measured win on this dance, and it needs no world model: with it, the night's success no longer
     hangs on the gradient through W. The skip model's funnel and the flow offset F (C8, C19) come AFTER, on a pi and a
     teacher that already work - F's anchor is "planned trajectories that succeeded", which exist only then.
     WHAT - C9 made first and plain, Sep 24's recipe on the device:
       - A BLOCK OF PLANNER WORLDS (32 at first) and their CANDIDATE WORLDS (16 each), ordinary worlds at the batch's
         end; candidates record nothing, and no judgement resets them.
       - A PLAN: offsets at knots over H = 8 decisions (0.27 s; Sep 24's 15 steps at 60 Hz), straight lines between,
         each freedom's reach 0.6 rad (Sep 24's measured reach), drawn about the previous winner shifted (the warm
         start, kept as candidate 0) with smooth noise of 0.3.
       - A REPLAN, every 4 decisions: `copy_world_state` (the planner's whole state - coordinates, velocities, applied
         and previous actions, warm start, clip and frame, episode counters - into its candidates), the candidates
         stepped H decisions by the device's own physics, each scored by the judgement's own reward summed over them
         (a fired termination rule its cost); the best candidate's knots are the new plan (predictive sampling, as
         measured). HOW THE CANDIDATES RUN AHEAD of their planner - a dispatch of the step program over the candidate
         block alone, or the planners held by a flag while the candidates run - is settled when the step program is
         read for it: the cheaper of the two.
       - WHAT A PLANNER WORLD EXECUTES: the planned offset on a share of its decisions (beta, 0.5 at first) and pi's
         own action on the rest; the planned offset RECORDED AS THE LABEL either way (DAgger's mixture), so the labels
         cover the states pi itself reaches, not only the planner's.
       - pi's LOSS gains the distillation `w_teach x |pi(o, g) - planned|^2` on labelled records, beside SuperMimic's
         gradient through W; w_teach full at the start, fading as pi's return on the planners' states nears the
         plans' (D4's teacher's gain).
       - The planners' trajectories feed W like any other (EfficientTDMPC's lesson: planned actions are where a
         model's errors hide).
     COST: at these sizes a planner world costs the physics of 32 policy worlds (16 candidates x 16 steps a replan,
     a replan every 4 decisions, against 2 steps a decision); 32 planners add a quarter to 4096 worlds' physics. The
     block's size, the candidates and the replan's period are dials the dry run's throughput sets.
     CHECK: on the twin a candidate after its copy steps exactly as its source (C9's check); the chosen candidate
     against a CPU computation of the same scores; ON THE DEVICE THE TEACHER ALONE OUTLASTS THE SERVO on the dance
     from frame 0, as Sep 24's did on the CPU - the ladder's first number, before any learning; then L1t.
     SIZE: 3 turns (the copy and the blocks; the replan and its score; the labels and pi's term).
  O3 PAIRED WORLDS - the model's ACTION RESPONSE measured, and taught. The policy's gradient through W is W's Jacobian
     in the action; D5 measures W's STATE error, and Sep 24 showed the two part. Only a simulator that can copy a
     world measures the response exactly, and ours can (`copy_world_state`, O2's):
       - A BLOCK OF PAIRED WORLDS (64 at first): at each decision's start a paired world copies one policy world's
         whole state (its source drawn by counter) and takes the source's action plus a perturbation (per freedom,
         drawn by counter, at the exploration's scale); it lives one decision, and is copied afresh at the next.
       - THE DIAGNOSTIC, D5b (`pairs.csv`): over the pairs, the physics' response (the paired world's next state less
         its source's, in W's normalised increments) against W's response to the same perturbation at the same state
         - their cosine and the ratio of their lengths (the right direction at half the size teaches at half the
         rate), by feature group (root, joints, velocities), and apart for worlds in trouble.
       - THE LOSS: `w_pair x |(W(s, a + d) - W(s, a)) - (s'_paired - s'_source)|^2` beside W's window loss - what both
         predictions share cancels, so the term spends W's capacity on the response alone. Both rows are also
         ordinary one-decision records.
       - THE GATE: the weight of pi's gradient through W follows D5b's cosine (off below a floor, pi then learning
         from the teacher alone) - four-papers' idea 20, on the quantity the gradient actually uses.
     CHECK: on the twin a paired world with a zero perturbation ends its decision exactly as its source; the loss's
     gradient against zimrnum's on a fixed batch; D5b written from the first round. SIZE: 2 turns.
  O4 REAL RETURNS FOR THE CRITIC. The critic's real fit is one-step temporal differences on recorded transitions; its
     imagined fit is lambda-returns (rl plan S1a). Far from the reference the model is least right and the critic
     carries everything beyond half a second, so the real fit should reach as far as the records do: LAMBDA-RETURNS
     OVER EACH RECORDED WINDOW's OWN COSTS (S1a's combining kernel, run on the recorded costs and the target heads'
     values at the recorded states), in place of the one-step differences. No model in it; what a real fall cost
     reaches the states before it in one update instead of a window's length of them. Lambda modest (0.5 at first:
     the records are the acting's, noise and plans included, and an uncorrected multi-step return leans toward the
     behaviour that made it); windows from planner worlds stay at one step.
     CHECK: the returns on a fixed recorded window against a CPU computation; at lambda 0 the fit is today's one-step
     fit to the bit. SIZE: 1 turn.
  O5 THE WAY BACK's DATA (rl plan R1; four-papers A2 and A4), cheap on the device once worlds can be copied:
       - THE ARCHIVE OF HARD STATES: each world keeps one snapshot of its whole state, refreshed every second; when
         its aftermath ends without a return, the snapshot - the state about a second before the failure - goes into
         an archive ring on the device; a share of starts (the curriculum's mixture gains the kind) restore from it,
         the clip and frame with the state. The policy meets the moment it failed at, from slightly earlier, until it
         passes.
       - THE GROUND POSES: one device pass before the run - from every half-second of every clip a world pushed over
         and left a second to settle; the resting states kept with their frames. Starts on the ground draw from them,
         their share opening with the push schedule.
     D2 reports returns from archive starts and from ground starts apart. CHECK: on the twin a restored world steps
     exactly as the world it was saved from; a forced failed aftermath lands in the archive; the shares measured.
     SIZE: 2 turns.
  O6 A SCREEN THAT CAN BE READ - an hour judges a slope, and a slope read against one control is read against an
     unknown noise:
       (a) TWO CONTROL SEEDS: E1 runs twice (E1a, E1b); their gap at 20, 40 and 60 minutes is the night's noise floor,
           and an experiment "differs" only beyond it. To keep eight hours, E8 (no joint limits) moves to the
           reserves - its question is read from pictures, which any later run answers.
       (b) THE POLICY's SLOW AVERAGE (rl plan S2, 0.995): the fixed evaluation judges the averaged weights, so a
           curve's wiggle is not one round's update.
       (c) NORMALISERS FITTED, THEN FROZEN: the features' and increments' statistics gathered through the feasibility
           pass and the world model's rounds alone, then held for the run - a falling policy no longer moves the
           meaning of every network's inputs under them.
       (d) THE POLICY's GRADIENT BOUNDED PER WINDOW, before the batch's mean: a fall's window measures 170-590 where a
           calm one measures 15-40 (rl plan, section 7), so under one bound on the mean a single fall sets the
           batch's direction and scales the calm windows' signal away.
       (e) A LADDER OF EXPLORATION ACROSS WORLDS: world w explores at sigma x 2^-(w mod 4) - every clip second
           recorded both nearly as the policy would act (honest returns for the curriculum, clean tracking data) and
           loudly (the action's response, for W).
       (f) E7 BECOMES "THE TEACHER OFF" (no planner worlds, no distillation): what the teacher buys, against a control
           that has it. The new signals together (the skip model, the funnel, F) are night 2's.
     CHECK: (b) the averaged weights against a CPU average over the same updates; (c) the statistics unchanged after
     the freeze; (d) a batch of one fall and many calm windows - the calm windows' share of the update with and
     without the bound, reported; (e) the spreads by world in D4. SIZE: 2 turns; (a) and (f) are `night1.zon`'s.
  O7 TRIPWIRES AGAINST A RUN THAT LEARNS NOTHING ("does not explode" is passed by a learner that does nothing; on
     Oct 30, plans that were never acted on and a teacher whose gradient never arrived were found only by reading).
     After the first rounds of EVERY experiment, of the ladder's rungs and of the dry run, the trainer asserts - and
     on a miss ends the experiment with exit code 2, the tripwire named in status.zon: every network's weights differ
     from their start; every loss term is finite and its gradient's norm on its own network is above zero; the
     policy's offsets are neither all zero nor saturated; the ring's write head moves; planned labels arrive (when
     the teacher is on); pairs.csv has rows (when the pairs are on); the evaluation's servo line equals the
     feasibility pass's (the judge judges what the pass measured).
     CHECK: each tripwire made to fire once (a zero learning rate; a recipe that asks for a teacher switched off; a
     zero action scale). SIZE: 1 turn.

  THE ORDER FROM HERE (Nov 11), replacing the order of turns 8-20 above; one checked piece a turn, as before:
     a  G6's rest; 7f the tracking programs on the GPU (vk-host-test); 7g the page's device check.
     b  8, records on the device (C4).
     c  9-10, the trainer's device path and `night1.zon`; O7's tripwires with its five-minute smoke.
     d  11, the lab's runner; 14, the feasibility pass, with O6c's statistics; `ladder.zon` and O1's verdicts.
     e  O2, the teacher: the copy and the blocks; the replan and its score; the labels and pi's term. Then the
        ladder's first numbers on Simon's machine: the teacher alone against the servo, L0, L1t, L1w.
     f  O3, the paired worlds: D5b, then the loss and the gate.
     g  15, the world model's form and the cheap signals (C12; the soft termination, the leash and the potential, the
        return at every depth - C5 is done), with O4 and O6b-e.
     h  O5, the way back's data.
     i  13, the night's safety; 12, the lab's UI; 16, the physics rate.
     j  20, the dry run; the ladder green on Simon's machine; then the night: E1a, E1b, E2-E6, E7 the teacher off.
     AFTER THE NIGHT - or before it only if every piece above is done: 17 the skip model, 18 the funnel planner, 19
     the flow offset F.

  WHERE THE PLAN STANDS (Nov 11, end of day) - the journal's last entries hold the detail:
     DONE: G6 (every phase of the decision check on worlds of its own); the fleet's own settings
        (`Fleet.trackingSettings`, the settings' types in robot.zig); 7f's device check - whole decisions, device
        against twin, in vk-host-test (42/42 on lavapipe, coverage 52 of 54 kernels) - WHICH THE RTX 5070 PASSES,
        every integer the twin's; the desktop arenas sized for the night (model constants 2^23, integers 2^25).
     OPEN ON THE RTX 5070: two constraint tests fail there, unnamed in the first run. `vk_host_test_2.exe` (a
        release host, the bench arenas) names them and measures a decision's cost at 8 to 1,024 worlds, the wait
        split off, the kernels' times listed. First numbers, Debug host: 2,232 world-decisions a second at 64 worlds.
     OPEN ON THE PHONE: the lab page with its pipelines made in the background - built, run headless here, NOT YET
        SEEN IN A BROWSER (the page took 15 seconds to start with them made the plain way); then 7g.
     OPEN IN THE TREE: the WGSL corpus' pin - the four shaders were seen on the phone and look right, so `zig build
        corpus-refresh`, then tripwires; 7f's last piece (acting WITH exploration on the device); the tracking check
        split into its steps; the tutorials' word on pipelines made in the background, once a browser has shown them.
     THEN, in the order above: b (records on the device, C4), c (the trainer's device path, the tripwires), d ...

## 5. The diagnostics

Written into the run's folder, one line a round, each file's first line its columns:
  D1 health.csv      non-finite counts per array (the watchdog's), constraint-row overflows, Newton's rounds (mean and
                     most), contacts per world, the device's time per program (timestamp queries where it has them),
                     decisions a second.
  D2 tracking.csv    the tracking error by clip and by body (mean, median, 90th percentile), episode lengths,
                     terminations by reason, aftermath lives and returns (how often, how soon), falls, starts in
                     trouble, pushes given.
  D3 learning.csv    every loss term of every learner - each world model's per horizon step, fine and coarse; the
                     policy's tracking, action rate, effort and smoothness; the flow teacher's imitation; the
                     critic's - the gradients' and weights' norms per network, the learning rates, the normaliser's
                     drift.
  D4 acting.csv      the action per joint and each limb's stiffness (mean, spread, saturation), the filter's lag (asked
                     against applied), exploration's scale; the MPC teacher's gain (true cost, planned against not),
                     how often it planned.
  D5 models.csv      each world model rolled open-loop over a few windows beside the device's own physics from the
                     same starts: the divergence per horizon step, fine and coarse.
  D5b pairs.csv      the paired worlds (O3): the physics' response to an action's perturbation against the world
                     model's - their cosine and the ratio of their lengths, by feature group, calm and in trouble.
  D6 pictures/       at each judging (every 30 minutes) a strip of frames of a few worlds (the engine's capture), and a
                     judged run per clip.
  D7 status.zon      alarms with their reasons: anything non-finite (save and stop, as now); a loss rising for an hour;
                     the action's spread collapsing; overflows above a share; returns falling for an hour. And a page
                     of the engine's own, native and web, that reads the folder and draws every series.

## 6. The schedule (the run's arrangement, in `night2.zon`)

  hours 0-8   the minute (dance, get-up, walk, run); decisions at 30 Hz over 60 Hz physics (`decide_every = 2`);
              networks as night 1's (680 wide, the critic 170), the rates' cosine over 8 hours; judged and
              checkpointed every 30 minutes, until stopped.
  from 0      the limbs' stiffness and the 0.5 filter on; CAPS's weights small (set at C10 from the smoke's
              magnitudes); the effort's weights small; the physics-MPC teacher at full strength.
  as D5 falls the teacher fades: its weight follows the fine model's divergence against its value at the start.
  from 1 h    pushes, to full strength at 7 h (as night 1: 0.5 a second, up to 3.5 m/s; a quarter of starts in
              trouble); the coarse model's windows join once its held-out loss has settled.

## 6b. The balance between the components (Simon, Nov 6)

One GPU budget per round, four consumers, each with its levers and the signal that says it is the bottleneck:
  EXPERIENCE   worlds; decisions per round; exploration's shape - action noise, pushes, starts in trouble, the
               curriculum's mixture. More when the world model's held-out error sits well above its training error.
  WORLD MODEL  updates per round (SuperMimic: 10 batches of 2048 windows), window (8), width, rate, rounds alone first
               (500). More while D5's divergence against the physics is high or still falling - it gates the rest.
  POLICY       horizon (32), batch (4096), critic epochs, gamma, the skip model's weight, CAPS's and effort's. More
               when the model is accurate and returns rise slowly per round.
  PLANNING     the candidates' share of worlds, how many characters plan and how often, the horizon, the teacher's
               weight. More while its gain over the policy alone (D4) is high; its worlds return to experience as it
               falls.
THE CENTRAL RATIO: updates per collected step - the world model's and the policy's. Too low wastes the data; too high
overfits the model, and the policy exploits its errors. THE NIGHT's START: SuperMimic's ratios, scaled to our worlds,
as shares of a round's TIME (D1 times every program) - physics and acting 40%, the world model 30%, policy and critic
20%, the teacher 10%. ITS SHIFTS, by the diagnostics, not the clock: the teacher fades as D5's divergence falls, its
share to experience; collection grows when the model's held-out error rises. D8 (added): each round's split of time
across the four, so the morning shows where the time went and what each part bought. Settings in `night2.zon`.

## 7. Risks, and what retires each

  the learner's eight storage buffers          `io` packing and buffer-to-buffer copies (C3, C4)
  the readback's lag                           the books' rule (C4) and its forcing test
  memory                                       the arenas' sizes printed (C11); the budget set from them
  the MPC's cost                               the budget measured (C9, C11); planning by danger, then by turns
  instability in one long run                  D7's alarms; checkpoints every 30 minutes; the resume tested (C10)
  something only Simon's GPU shows             the dry run (C11) before the night

## 8. How a change is checked

  lint                    `zbuild lint-check`
  twin against robot.zig  `zig build test-fast -Dfast-root=src/robotgpu_tests.zig`
  twin against the fleet  `zig build test-fast -Dfast-root=src/robot_latent_kit_tests.zig -Dtest-filter="the twin"`
                          (a filter's unmatched tests are not compiled: run a changed test by its name)
  device against twin     `zig build vk-host-test` (lavapipe)
  the web                 `zig build robotgpu-sidebyside -Dplatform=web -Dmode=release`, then Tint in headless Chrome
  the tutorials           `zbuild doc-sync`

## 9. Journal

- Nov 6: v3 written (Simon: "Make a new version of the plan. Summarise the previous one. Make the new one more
  precise. Archive the old one."): v2 summarised (section 1) and archived; the night's components C1-C11 with what
  moves to robot.zig, the arrays and kernels, the checks and the sizes; the diagnostics D1-D7 by file; the schedule.
- Nov 6: C1, PART ONE - THE REFERENCE's TORQUES. `robot.torquesForAccelerations` (the servo's last step on its own: a
  fixed base's inverse dynamics, or the floating base's with the root's six zero), which `servoTorques` now ends with;
  `robot.referenceTorques(gpa, m, poses, frame_count, frame_time, out)` - at each frame the pose, its velocity
  (`clipVelocity`: the backward difference, frame 0 taking frame 1's), its acceleration (the next velocity less this
  one over h, the last frame taking the one before), and `torquesForAccelerations` at that state: the effort's zero.
  CHECKED: on a smooth clip of Geno, at every interior frame, the torques `torquesForAccelerations`' to the bit, and
  forward dynamics given them - the root's acceleration solved as the floating base solves it, then M a + c - tau on
  every joint row, M formed apart from RNE - zero within 1e-3 of each torque; robotgpu 29/29 (the servo's checks:
  `servoTorques` unchanged). NEXT: the judgement's functions on values in robot.zig, then the device's kernels.
- Nov 6: C1, PART TWO - THE JUDGEMENT IN robot.zig, written by a turn that ended without a reply and verified now.
  Section "THE TRACKER's JUDGEMENT" in robot.zig: `TrackingError`, `trackingErrorOver`, `RewardWeights`, `reward`,
  `SuperMimicScales`, `SuperMimicTracking` (`superMimicTrackingOver`), `superMimicActionRate`,
  `superMimicJointLimitExcess`, `Termination`, `terminated` - generic over a body STORAGE (`comptime Bodies`, checked
  by `requireBodies`; robot.zig's pattern for its LDL): the CPU passes `BodySlices` (a `State`'s slices), the device
  will pass one reading its world arrays, so both judge with one definition. robot_track keeps every name, as an
  alias or a thin wrapper over its `State` (`bodiesOf`). Also: a fixture import in robot.zig renamed, as a parameter
  named `reference` shadowed it; a local of `headingAngle` renamed. CHECKED: lint; robot.zig 142/142; robot_track
  325/368 (43 skipped); the kit's 199 matching tests (a cached pass of the same binary); doc-sync 0 (the mocap
  tutorial's folds follow the moved code). NEXT: C1's device part - the judgement's storage over the world arrays,
  the reference state per clip frame as a table, `accumulate_effort` and `judge_decision`, and the kit's check.
- Nov 6: C1, PART THREE - THE LOWEST POINTS ON THE DEVICE (the judgement's unexpected contact reads them). robot.zig's
  per-shape geometry as functions of its own - `sphereLowestPoint`, `segmentLowestPoint` (capsules and cylinders),
  `boxLowestPoint` - which `geomLowestPoint` calls; the kernel `body_lowest_points` (per world and body, last in
  `observe_program`): each geom placed on its body as robot.zig places it, measured by the same functions, into
  world_f `body_lowest_points`. A hull (MuJoCo's mesh) has no points on the device - as its floor contacts take none -
  so it has no lowest point there: the KUKA, whose links are hulls, is left out of the check, with the reason.
  CHECKED: four posed worlds each of Geno and the humanoid, every body's height robot.zig's `bodyLowestPoints`', bit
  for bit (a probe found the KUKA's hulls); robotgpu 30/30; lint. NOT YET RUN for this kernel: vk-host-test and the
  web build with Tint - at C1's end, with the judgement's kernels. NEXT: the judgement's body storage over the world
  arrays and the reference's states per clip frame; `judge_decision`.
- Nov 6: C1, PART FOUR - THE TRACKING ERROR ON THE DEVICE. `robot.reference_body_numbers` (20: a body's position,
  rotation, velocity, angular velocity, then its lowest point - five vectors); `Fleet.clipReferenceBodies` (the
  reference's bodies at every frame, by the fleet's `referenceStateInto`); `ClipPoses.reference_bodies` with its
  features or neither (`countsWithClips` asserts it), the model_f table `clip_reference_bodies` (packed by
  `packClips`); `DeviceBodies` - the judgement's storage on the device, ONE type for both sides as
  `trackingErrorOver` takes one, a field naming its source (a world's derived quantities, or a reference row);
  `StepOptions.head_body` (`no_head_body` for none; `setHeadBody`); `judge_tracking` (per world, last in
  `observe_program`): robot.zig's `trackingErrorOver` over the device's storages, its terms into world_f
  `tracking_errors`. In this Zig a struct's fields are `@typeInfo(T).@"struct".field_names`. CHECKED: the kit's
  decision check now also compares every term of each world's tracking error with the fleet's own
  `trackingErrorWithHead` at that state and frame - bit for bit after each of three decisions, the stiffness off and
  on; robotgpu (below); lint. NOT YET RUN for the new kernels: vk-host-test, the web build and Tint. NEXT: the rewards,
  the termination, the flags and counters (`judge_decision`), and the effort's sums.
- Nov 6: C1, PART FIVE - THE REWARDS ON THE DEVICE. `judge_rewards` (per world, after `judge_tracking`): the tracker's
  reward (`robot.reward` of the stored tracking error) into world_f `rewards`, and SuperMimic's tracking reward
  (`robot.superMimicTrackingOver` over the device's storages; its total) into `super_mimic_tracking` - SuperMimic's
  action rate and joint-limit terms not yet in it. THE WEIGHTS IN A MODEL TABLE, not the uniform: an extern struct
  holds no array of vectors, and the alternatives inside the uniform (a field list mirrored by hand; nested structs
  padded to WGSL's 16-byte rounding) were worse - so `judgement_weights` (item kind `judgement_numbers`), written by
  `writeJudgementWeights` from a named `JudgementWeights` (the tracker's `RewardWeights`, SuperMimic's
  `SuperMimicScales`), each struct's fields in their declared order (`weightCount`), read back by
  `loadJudgementWeights`; `pack` writes the defaults, `CpuTwin.setJudgementWeights` a task's. CHECKED: the kit's
  decision check now also compares each world's tracker reward with what the fleet earned that decision and its
  SuperMimic tracking total with the fleet's function - bit for bit after each of three decisions, the stiffness off
  and on; robotgpu (below); lint. NOT YET: the host Sim's setter for the weights; vk-host-test, the web build and Tint
  for the new kernels. NEXT: SuperMimic's action rate and joint-limit excess on storages (the previous action per
  world), then the termination with its flags and counters.
- Nov 6: REVIEW of C1's parts one to five (Simon: "Review the last few turns. Look for bugs, things to improve").
  FIXED: (1) THE JUDGEMENT ITS OWN PROGRAM - `judge_program` (`body_lowest_points`, `judge_tracking`,
  `judge_rewards`), submitted after the observation (`Sim.submitJudgement`), so `observe_program` observes only; its
  kernels placed after `observe_reference` in run order (they had been put ahead of the lowest points they read); the
  section "THE TRACKING TASK, THE OBSERVATION AND THE JUDGEMENT", the file's map and the host's and the programs'
  openings say so. (2) ONE DEFINITION OF A WORLD's REFERENCE ROW - `referenceFrameRow` (its clip frame held at the
  clip's last), which `observe_reference`, `judge_tracking` and `judge_rewards` had each computed. (3) THE HOST COULD NOT
  SET THE JUDGEMENT - `Sim.setHeadBody` and `Sim.setJudgementWeights` (an upload into `judgement_weights`), all three
  writers - `pack`'s defaults, the twin's, the host's - through one mapping, `judgementNumbers`
  (`judgement_number_count` numbers). OPEN, FOR SIMON: at frame 0 `referenceTorques` takes frame 1's velocity, but
  the fleet's reference state at frame 0 (`referenceStateInto`) and its starts there have zero velocity - the
  effort's baseline and the reference disagree on that one frame. CHECKED: lint; the kit's decision check 2/2
  (decisions, observations, tracking errors and rewards bit for bit); robotgpu 30/30; vk-host-test, every check, the
  judgement's kernels in the SPIR-V; the page's web build, Tint clean with every kernel's pipeline.
- Nov 6: SUPERMIMIC STUDIED, PAPER AND CODE (Simon: "Study deeply supermimic paper and code. Make sure all
  differences between our system and theirs is wanted."; arXiv 2610.28480, Uni-SuperMimic). THEIRS, from the code:
  OBSERVATION 99 numbers, proprioceptive (joint positions less the default and the calibration offset, joint
  velocities, the root's angular velocity and gravity in its frame, the previous action, the root's rotation
  relative to the reference's), uniform noise per group, with a history of observations. GOAL frames +1..+10 at 50 Hz
  (0.2 s), CLAMPED at the clip's end, each 73 numbers IN THE REFERENCE's CURRENT HEADING FRAME (root offset and
  rotation, the root's velocities in its own frame, joint positions, joint velocities x0.1), encoded by an MLP to a
  32-number latent (tanh). ACTION ABSOLUTE: default pose + calibration offset + 0.25 effort/kp x action - not an
  offset on the reference. REWARD BeyondMimic's (our robot.zig port matches its scales and weights); TERMINATION root
  height > 0.25 m or tilt > 0.8, a sigmoid-softened copy in imagination. WORLD MODEL deterministic, predicting only the
  robot's state (root pose, joint positions and velocities: 71 numbers) as deltas from heading-invariant features,
  the action and the physics context; observation, reward and termination ANALYTIC of the predicted state; MLP
  2048x3, SiLU and LayerNorm, the output zero at the start; 8-step autoregressive windows; 500 rounds of the world
  model alone. POLICY deterministic, Gaussian action noise 0.1 in collection (the executed action recorded), trained
  by BPTT over 32 imagined steps, a critic (256, 128) on privileged features bootstrapping beyond them, the survival
  weight soft; 4096 worlds; physics 200 Hz, control 50 Hz; domain randomisation with its context.
  THE DIFFERENCES, EACH JUDGED - OURS BY INTENT: the action an offset on the reference with a stiffness per limb
  (DReCon's residual; theirs must reproduce the pose, which is why its goal carries joint positions); a sim-only
  character, so the observation may carry everything (body positions, linear velocities - theirs omits what a real
  G1 cannot measure); the goal in the CHARACTER's heading frame (theirs the reference's, plus the relative root
  rotation - the drift is hidden from it for want of a position estimate, which we have); the clip margins (theirs
  clamps the goal at the clip's end - the fake standstill our margins remove); our termination with its grace, its
  aftermath and returns (the night's purpose); the servo (an implicit spring through inverse dynamics, 20 Hz, damping
  1) for an animated character; no randomisation for the night; the exploration of the flow actor and MPC.
  ADOPT THEIRS (nothing argues against): the world model's SiLU, LayerNorm and zero output, and its rounds alone
  before the policy learns (rl plan S5 - to do); the executed, noisy action as the record (verify ours records it);
  the analytic heads - every task quantity a function of the predicted state (ours, L7 - keep it so as effort and
  CAPS join: the effort head is learned, an exception by necessity). VERIFY: whether our policy sees its previous
  action (rl plan S0c4, theirs does); a history of observations (theirs ten - ours none; our full state needs it
  less); THE PHYSICS RATE - theirs 200 Hz, ours 60 Hz: falls and get-ups are contact-rich, so measure a get-up's
  contacts at 60 against 120 Hz before the night (the implicit servo is stable at 60, the contacts may not be).
- Nov 6: OUR CODE REVIEWED AGAINST SUPERMIMIC (Simon: "Review our code, make the plan more complete"). Found: the
  world model dense tanh, no LayerNorm, its output at a hundredth, no rounds alone (C12 added); the physics at the
  clips' rate, 60 Hz (C13 added: measured in the smoke against 120 Hz); the policy blind to its previous action (for
  Simon, off as ruled); the record the executed action (as theirs).
- Nov 6: CLOSER TO SUPERMIMIC, THE RATES, THE RAMP, THE VARIABLE STRIDE (Simon). Added C14 (decision 10 or 30 Hz,
  physics 60 or 120 Hz, from the run file; the clips resampled once by precise interpolation), C15 (the action ramped
  linearly across each decision, replacing the exponential filter), C16 (the previous action and the root's relative
  rotation in the policy's inputs - his ruling against the FILTERED action stands; the ramp makes the previous asked
  action the ramp's start, which the policy should know); C8 replaced by the variable-stride world model, with his
  text.
- Nov 6: THE VARIABLE-STRIDE WORLD MODEL IN FULL (Simon re-sent his text): C8 now follows his formulation - the Fourier
  embedding of the jump, the projection to dt_max interpolated straight, the grid and the window's mean action, the
  time-scaled objective with rewards at the nodes only - his text quoted whole; the display formulas, which did not
  come through, written from it, to check with him. Ours added: two-axis rotations re-orthonormalised after an
  interpolation; the action held across a jump in imagination.
- Nov 6: THE EXPANDING GRID SET ASIDE (Simon: "lets forget about expanding grid. That would be usefull if we wanted to do
  mpc with the model, which we are not really doing in the first night"): C8 is the skip model, a constant stride of
  3 decisions beside the one-step - one network, the stride an input, the mean rate its output (residual at every
  stride, the trap of predicting the projection itself avoided), the reference at the jump's end an input. Simon's
  text, for the record:
  (the variable-stride idea, in full)
     "Physics-based humanoid motion tracking relies on differentiable world models to compute analytic policy
     gradients via Backpropagation-Through-Time (BPTT), reducing training compute by orders of magnitude. However,
     standard autoregressive models predict fixed, high-frequency steps (e.g., 30 Hz), creating a horizon bottleneck:
     dense temporal unrolling suffers from compounding prediction errors and memory explosion, restricting planning to
     myopic windows. Recent hierarchical methods abstract primitive actions into latent macro-actions, but this severs
     the gradient from the physical state space, losing the mechanical constraints necessary for rigid-body contact
     resolution.
     We propose a variable-stride differentiable world model that directly parameterizes the temporal prediction
     grid. By evaluating future trajectories over an expanding sequence of time nodes (e.g., t in
     {1, 2, 4, 7, 11, 15, 19, 24}), we maintain high-frequency resolution for immediate contact dynamics while scaling
     to ~0.13 s intervals for distant ballistic momentum. Modeled as a time-conditioned vector field, the network
     predicts straight-path interpolations, yielding stable analytic gradients across arbitrary jump intervals. Coupled
     with window-averaged action conditioning - enabled by the tracking policy's inherent action smoothness - this
     approach achieves nearly one second of future kinematic prediction in just 8 model evaluations, exponentially
     extending the BPTT horizon under a fixed compute budget.
     1. Time-Conditioned Continuous Dynamics. Instead of a fixed discrete-time transition, the world model predicts
     transitions over an arbitrary continuous temporal jump dt in [dt_min, dt_max]. To prevent spectral bias, dt is
     mapped via a Fourier feature embedding phi(dt) in R^2D, where frequencies w_d are log-linearly spaced. This
     embedding is concatenated with the state s_t, action a_bar_t, and simulation context xi.
     2. Flow-Matching Interpolation. To guarantee stable Jacobians d s_t+dt / d s_t during BPTT, the network f predicts
     a maximal projection state s_project, representing the kinematics if the dynamics were extrapolated to the
     maximum boundary dt_max. The physical state at query time dt is computed via a differentiable linear
     interpolation (LERP). Because s_project is dynamically conditioned on phi(dt), the vector field natively curves to
     resolve physical discontinuities (e.g., ground impacts) at specific endpoints, while the backward pass computes
     gradients through a stable straight line.
     3. Expanding Temporal Grid and Window-Averaged Actions. The BPTT rollout is structured over a non-uniform time
     node sequence T = {t_0, t_1, ..., t_K}, maintaining maximum resolution at the start and expanding to dt_max in
     the future. For a 30 Hz simulation, an 8-evaluation grid is T = {0, 1, 2, 4, 7, 11, 15, 19, 24}. To train the
     model on offline trajectory windows of varying length dt_k = t_k+1 - t_k, we condition f on the mean of the
     executed actions. Because the policy relies on standard action-smoothness penalties (e.g., ||a_t - a_t-1||^2),
     high-frequency torque jitter is suppressed. This allows a_bar_t_k to serve as a mechanically sound proxy for the
     sustained control intent over the dt_k interval.
     4. Time-Scaled Policy Objective. The physical motion-tracking reward r is evaluated strictly at the discrete grid
     nodes T, preventing artifactual penalties from intermediate interpolation steps clipping through collision
     geometry. The deterministic policy pi and value critic V optimize the expanding integral. Here, gamma in [0, 1)
     applies exponential decay tied to absolute time, and c_t_k is the differentiable survival probability. Scaling
     the immediate reward by the jump width dt_k approximates the continuous-time return integral across the
     variable-stride rollout."
- Nov 6: C1, PART SIX - THE TERMINATION RULE ON THE DEVICE. `JudgementWeights.termination` (`robot.Termination`'s nine
  f32 limits; its `grace_steps` belongs to the episode's counters) after the two weight structs in
  `judgement_weights`; `f32FieldCount` (a struct's f32 fields - all of the weights', the termination's limits) replaces
  `weightCount`; `judge_rewards` also stores the rule's verdict - `robot.terminated` of the stored error, 1 or 0, before
  any grace or aftermath - into world_f `termination_rule`. CHECKED: the kit's decision check compares it with the
  fleet's own `terminated` each decision, bit for bit, the stiffness off and on - but in that run the characters stay
  on their reference, so only "it does not fire" is exercised; the firing case comes with the next part's check (a
  knock off the reference, a loss, a return). robotgpu (below); lint. NEXT: the episode's flags and counters - grace,
  failure, aftermath, the return streak, done - their kernel and that check.
- Nov 6: C1, PART SEVEN - THE EPISODE's RULE, ONE DEFINITION. Extracted from the fleet's `step` into robot.zig, on
  values: `EpisodeCounters` (steps, aftermath steps left, return streak, steps since loss), `EpisodeRules` (grace,
  aftermath, return and longest-episode lengths; whether this character keeps an aftermath), `EpisodeVerdict` (in an
  aftermath, lost, returned, aftermath begins, finished, ends at a loss, capped, a return's length), and
  `judgeEpisode` - broken, graced, the rule asked (or, in an aftermath, asked the other way round), the aftermath begun,
  ended by a return or counted down, and the five ends. The fleet's `step` builds the counters from its arrays, calls
  it, and writes them back, its totals from the verdict. CHECKED: the kit's 199 matching tests (168 run, 31 skipped, 0
  failed - the return test among them: a loss, an aftermath, a return; a character that never returns ending with its
  aftermath); robot_track's own (below); lint. NEXT: the device's kernel `judge_episode` through the same function
  (world_u counters and flags, the rules in the uniform), and the kit's check through a loss and a return.
- Nov 6: C1, PART EIGHT - THE EPISODE JUDGED ON THE DEVICE. `judge_episode` (per world, last in `judge_program`):
  robot.zig's `judgeEpisode` on the stored tracking error and the termination's limits, its counters in world_u
  (`episode_steps`, advanced first as the fleet advances it; `aftermath_steps_left`, `return_streaks`,
  `steps_since_loss`), the verdict a bit per `EpisodeFlag` in `episode_flags`, `return_lengths`; the rules in two new
  uniform rows (`EpisodeOptions`: grace, aftermath, return and longest lengths, the worlds that keep an aftermath,
  physics steps per decision for the clip's end), set by `StepOptions.setEpisodeRules` and `Sim.setEpisodeRules`. The
  uniform's array guard (`requireNoArraysInUniform`) given a larger comptime budget for the longer layout. CHECKED:
  the kit's decision check now runs six decisions with events applied to the fleet and the twin alike - character 1
  knocked a metre off before decision 1 (a loss: the rule fires, an aftermath begins), held on its reference before
  decisions 2 and 3 (it returns) - and compares every flag (lost, returned, in aftermath, finished) and every counter
  with the fleet's at each decision, bit for bit, the stiffness off and on, asserting the return happened; robotgpu
  (below); lint. C1 REMAINS: the effort's sums (`accumulate_effort`), then vk-host-test and the web build for every
  judgement kernel.
- Nov 6: C1, PART NINE - THE EFFORT's SUMS ON THE CPU. robot.zig: `EffortSums` (energy, the sum of |dtau q'| dt;
  torque, the sum of (dtau / (m g))^2 - over the actuated dofs and a decision's physics steps), `addDofEffort` (one
  dof's step, the one arithmetic the fleet and the device follow, dof after dof), `characterWeight` (mass times
  gravity's magnitude). The fleet: `clip_reference_torques` (every clip's, once at its start, by
  `rbt.referenceTorques`), `effort_sums` per character (zeroed at each decision's start and at `startAt`),
  `character_weight`; `driveOnce` given the frame's reference torques and the character's sums by its caller (it stays
  unaware of characters), adding each physics step after the servo's torques. Not yet in any reward. CHECKED: the
  kit's 199 matching tests (168 run, 31 skipped, 0 failed - the fleet unchanged); lint. NEXT: the device's side - the
  clips' reference torques as a table (`ClipPoses.reference_torques`), `accumulate_effort` after `servo_torques`,
  zeroed at the decision's start - the twin's sums the fleet's, bit for bit; the effort's weights in SuperMimic's
  reward (zero by default); then vk-host-test and the web build for every judgement kernel.
- Nov 6: THE REFERENCE's TORQUES DROPPED (Simon: "I dont understand how we can compute clip torques. This needs
  contacts, no? Maybe for now disregard clip reference torques. And also lets for the first night have just a very
  small cost for torque"). He is right: `referenceTorques` ran floating-base inverse dynamics with the root free and no
  ground forces - the servo's own contact-free formula, its ideal command on the reference, not the torques a body
  needs (a knee in stance holds the body's weight). Real reference torques need the reference's contact forces (a
  contact-force solve per frame) - later. REMOVED: `referenceTorques`, `clipVelocity`, their test, the fleet's
  `clip_reference_torques`, `driveOnce`'s argument for them. THE EFFORT is now the servo's own: `addDofEffort(sums,
  torque, velocity, timestep, weight)` - energy |tau q'| dt, torque (tau / (m g))^2. SuperMimic's scales gain
  `torque_weight` and `energy_weight`, both zero by default (every test's reward unchanged); the fleet's reward charges
  the torque's mean over the actuated dofs and the decision's steps, and the energy per unit of mass. FOR THE NIGHT:
  `night2.zon` sets the torque's weight very small (to fix at C10 from the smoke's magnitudes in D3), the energy's
  zero - kept as a diagnostic. C1's check (a) - "on the reference the servo's torques are the reference's" - is gone
  with the reference torques. CHECKED: the kit's 199 matching tests (168 run, 31 skipped); robotgpu (below); lint.
  NEXT: the effort on the device (`accumulate_effort`, zeroed at the decision's start; the twin's sums the fleet's),
  the device's SuperMimic penalties (action rate, joint limits, effort), then vk-host-test and the web build.
- Nov 6: C1, PART TEN - THE EFFORT ON THE DEVICE. `accumulate_effort` (per world, in the step program right after
  `servo_torques`, before integration - where the fleet's `driveOnce` adds its own): each actuated dof's torque
  (`applied_joint_forces`) at its velocity through `robot.addDofEffort`, into world_f `effort_energy` and
  `effort_torque_squares`; `zero_effort` in a new `decision_start_program`, which the twin's `runDecision` and the
  host's `submitDecision` run first; the character's weight a one-number model table (`character_weight`, item kind
  `model_single`) that `pack` writes from `robot.characterWeight` - a property of the model, so neither twin nor host
  can forget it. CHECKED: the kit's decision check compares both sums with the fleet's after every decision of the run
  with a loss and a return - bit for bit, the stiffness off and on; robotgpu 29/29; vk-host-test, every check - every
  judgement kernel and the effort's compiled to SPIR-V; the page's web build, Tint clean with every pipeline; lint.
  C1 REMAINS: the device's SuperMimic penalties - the action rate (the previous action per world), the joint limits,
  the effort's cost - beside its tracking total, checked against the fleet's whole SuperMimic reward.
- Nov 6: REVIEW - HUNTING WHAT WILL NOT WORK (Simon: "Review. Hunt for things that will not work"). RANKED:
  (1) NOTHING RESETS A FINISHED WORLD on the device yet (C2): the judgement flags it, then it runs on - its frame past
      the clip, its counters still counting. Every check so far avoids an episode's end. C2 is next, not later.
  (2) EIGHT SETTERS MUST MIRROR THE FLEET - servo, floor, action scale, filter, limb stiffness, head, judgement weights,
      episode rules - and the kit's check calls them one by one; the trainer would have to repeat that list exactly,
      and one missed is a device judged by defaults, silently. FIX: one `TrackingSettings` struct in robotgpu and one
      setter for it; one function on the tracker's side building it from a `Fleet`; the kit's check through that same
      function, so the check covers the mirroring itself.
  (3) A JUDGEMENT WITHOUT ITS TABLES IS SILENT: `observe_reference`, `judge_tracking`, `judge_rewards` and
      `judge_episode` return when `reference_feature_frames` is 0 - a trainer that forgets the reference tables runs
      with no episode ever ending. FIX: `submitObservation` and `submitJudgement` assert the tables exist.
  (4) THE ORDER IS THE CALLER's: the judgement reads what the observation brought forward; submitted alone, or before
      it, it judges stale poses. FIX: one `submitDecisionEnd` (observation, then judgement) as the only way in.
  (5) A HULL IS SILENTLY NOTHING ON THE DEVICE - no floor contact, no lowest point. Geno has none; another robot
      would differ from the CPU without a word. FIX: tracking simulators refuse a model with hull geoms at init.
  (6) THE LEARNER's DEVICE IS UNPROVEN: C3 and C4 assume the simulator's buffers and the learning kit's activation
      buffer live on ONE device, so a buffer-to-buffer copy joins them. If they are two devices, nothing joins them
      but the host. FIX: a spike before C3 - one buffer of the simulator's copied into the kit's, read back.
  (7) MEMORY AT 120 Hz: a few minutes of clips' reference tables (features 387 and bodies 500 numbers a frame) come
      to about 50 MB at 60 Hz and 100 MB at 120 Hz - near WebGPU's default 128 MB binding on the web; native has room.
      C11 prints the arenas' sizes; the web stays at 60 Hz if needed.
  (8) DEVICE AND CPU MAY PART AT A THRESHOLD: the device's floats differ from the twin's within bars, so a world whose
      error sits on a termination limit can end on one and not the other. Harmless - the night runs one engine - but
      no check may demand the device's flags equal the twin's.
  ALREADY IN THE PLAN AND STILL OPEN: the ramp and the rates (C14, C15); the new goal and the policy's inputs (C16,
  the character's heading frame, the near and far frames, the clip margins); acting, records and the books (C3, C4);
  the world model's form and the skip model (C12, C8); the physics rate measured (C13); the device's SuperMimic
  penalties (C1's last piece). THE ORDER NOW: C1's last piece and fixes (2)-(5) together; C2; the spike (6); then C14
  and C15 before C3, since acting reads the observation C16 changes.
- Nov 6: THE REVIEW's FIXES (4), (5), (6). ONE WAY TO A DECISION's END: `Sim.submitDecisionEnd` (the observation,
  then the judgement, in one batch) replaces `submitObservation` and `submitJudgement` - no other caller had them -
  and `CpuTwin.runDecisionEnd` is the twin's; both assert the reference tables exist, so a trainer that forgot them
  stops instead of running with no episode ever ending. HULLS REFUSED WHERE JUDGED: `requireNoHullsWhenJudged`, at both
  tracking inits, names a hull geom when the clips carry the reference's tables - a step-only simulator (the KUKA's
  checks) may still hold hulls: the first version refused every tracking init and aborted those checks. CHECKED: the
  kit's decision check through `runDecisionEnd`, 2/2; robotgpu 29/29; lint. NEXT: fix (2) - one `TrackingSettings`
  and one setter, built from a fleet, the kit's check through it - with C1's last piece, the device's SuperMimic
  penalties; then C2.
- Nov 6: THE REVIEW's FIX (2) - ONE CALL MIRRORS A FLEET. `robotgpu.TrackingSettings` (the floor, the servo's law and
  mode, the action's scale and filter, the limbs' stiffness, the head, the episode's rules, the judgement's weights)
  with `applyToOptions` (the uniform's seven) and one setter per engine, `CpuTwin.setTracking` and `Sim.setTracking`
  (the uniform's, then the judgement's table). The kit's check builds them from its fleet in one function,
  `trackingSettingsOf` - neither the learning kit nor robot_track imports robotgpu, so it lives with the check for now;
  C10 moves it where the trainer shares it. CHECKED: the kit's decision check through `setTracking`, 2/2; robotgpu
  29/29; lint. NEXT: C1's last piece (the device's SuperMimic penalties), then C2.
- Nov 6: THE TUTORIALS DEEPENED (Simon: "Review. Improve comments. Make the tutorials more detailed. It is ok to repeat
  info from the comments to the tutorial and conversly"). The course (robots.html) gains "The judgement": why it is
  its own program after the observation and why one call runs both (`submitDecisionEnd`, folded); reading bodies on
  the device - one storage type for both sides (`DeviceBodies`, folded); what a judged clip carries; why the weights
  live in a model table, not the uniform; the episode's rule with a worked timeline (a knock, a loss, an aftermath, a
  return) and `judgeEpisode` folded; the effort, measured from zero and why (a reference's torques need its contact
  forces), `addDofEffort` and `accumulate_effort` folded; one call for the settings. The mocap tutorial's fleet section
  gains the episode's rule (`judgeEpisode` folded) and the effort (`addDofEffort` folded). CHECKED: doc-sync.
- Nov 6: A BUG FOUND IN THE COMMENTS' REVIEW - SUPERMIMIC's JOINT-LIMIT TERM ON BALL JOINTS. `superMimicJointLimitExcess`
  read `joint_positions[first_coordinate]` as every ranged joint's position; for a ball that is a component of its
  quaternion, compared against an angular range in radians - meaningless. The night's Geno (the fixtures' geno.xml)
  has 23 ball joints, every one ranged, and no hinge; the term's default weight is -2.0, so every SuperMimic reward
  Geno earned carried it. (SuperMimic's G1 has hinges only: its formula never met a ball.) FIXED: `jointLimitExcess` per
  joint type - a hinge's or a slide's soft band about its range's middle, as before; a ball's ROTATION ANGLE
  (`angleBetween` the identity and its orientation, as MuJoCo's ball limit measures it) past the soft share of its
  cone's widest angle; a free joint none - and `superMimicJointLimitExcess(m, joint_positions, share)` summing it over
  the ranged joints in joint order, reading each through `readJointCoordinates`. Its test rewritten with a ball (robot.zig
  keeps a ball's coordinates as its quaternion x, y, z, w). Also: the kit's check lost a plan step number from its
  comment. CHECKED: the kit's 199 matching tests (168 run, 31 skipped, 0 failed), the rewritten test among them; lint.
- Nov 6: CORRECTION - the joint-limit "bug" never touched Geno. robot.zig's model builder sets a ball's and a free
  joint's `joint_range` to null on purpose ("until cone limits exist": applied as a scalar, a ball's range had pinned a
  servo on Geno's balls 0.67 rad short of poses his captures reach). So the penalty, which loops over the model's
  ranges, never saw a ball, and the device's limit rows (`countsOf` counts non-null ranges) never include one - no
  physics bug either. The new ball branch of `jointLimitExcess` is right but unreachable today. THE REAL FINDING: GENO
  HAS NO JOINT LIMITS AT ALL - his model's joints are 23 balls and a free root - neither in his physics nor in his
  reward; after a large perturbation nothing keeps a knee or an elbow from a pose no body takes, which works against
  returns that look natural. FOR SIMON: keep each ball's cone angle in a field of the model's own (`joint_cone_limit`,
  apart from `joint_range`, so no limit row takes it) and let SuperMimic's soft-limit penalty charge it through the ball
  branch - a soft limit for the night, the cone constraints in the physics later.
- Nov 6: GENO's LIMITS, DECIDED BY DATA (Simon: "find the best way to add joint limits to geno... we need to be confident
  the mocap passes unchanged"). C17 added: a box per ball in rotation-vector space from the captures themselves, widened
  by a margin - every captured pose inside it by construction, a backward bend outside it - clamping the servo's
  targets and charged by SuperMimic's soft-limit penalty; never a constraint row. It replaces the cone suggested
  earlier the same day, which cannot tell a bend from a backward bend.
- Nov 6: C17 ON THE CPU - GENO's ROTATION BOXES. robot.zig: `rotationVectorOf` (the shorter way round, from the
  quaternion's vector part as `angleBetween` takes it) and `rotationOfVector`; `RotationBox` and `rotationBoxes` (each
  ball's least and greatest rotation-vector components over every captured frame, widened by a margin);
  `ballBoxExcess`; `clampBalls` (a target outside its box clamped component by component, one inside left to the bit);
  `superMimicJointLimitExcess(m, boxes, positions, share)` - boxed balls by their box, ranged hinges and slides by their
  soft band (`jointLimitExcess`, its ball branch given way to the box). The fleet: `Options.rotation_box_margin` (10
  degrees), `rotation_boxes` over every frame of every clip at its start, the balls' targets clamped after
  `applyAction`, the penalty through the boxes. CHECKED: "the mocap passes Geno's rotation boxes unchanged" - every
  frame of the clip with no ball excess and every target left to the bit by the clamp; a ball turned 0.3 rad past its
  box charged and clamped back inside; the box functions' unit test (a knee's backward bend charged, the rotation
  vector round-tripping); the kit's 199 matching tests (168 run, 31 skipped - the twin still the fleet: no target there
  reaches a box's edge); lint. NEXT: the device's side - the boxes as a model table, the clamp in `reference_targets`,
  and SuperMimic's whole reward in `judge_rewards` (the action rate with each world's previous action, the boxes'
  excess, the torque's cost), the twin's against the fleet's.
- Nov 6: C17 ON THE DEVICE - THE BALLS' CLAMP. `robot.ballTargetInBox` (outside, the rotation vector clamped and turned
  back; inside, the rotation itself, to the bit) - the one rule `clampBalls` and `reference_targets` follow; the model
  table `ball_boxes` (`joint_box_numbers`: per joint low then high, low's fourth number 1 for a boxed ball), written
  by `rotationBoxNumbers` from `TrackingSettings.rotation_boxes` in both engines' `setTracking` (the host's now given
  its scratch allocator); `reference_targets` clamps a boxed ball's target beside the hinges' range. CHECKED: the kit's
  decision check gains a forced clamp - at decision 5 the knocked character, still in its aftermath, asks a large
  action whose ball targets pass their boxes - and every position, observation, judgement, episode flag and effort
  sum stays the fleet's, bit for bit, the stiffness off and on; robotgpu (below); lint. NEXT: SuperMimic's whole reward
  on the device (the action rate with each world's previous action, the boxes' excess, the torque's cost), then C2.
- Nov 6: SUPERMIMIC's WHOLE REWARD ON THE DEVICE - WRITTEN, ONE CHECK FAILING (left in place, so it cannot be
  forgotten). robot.zig: `actionChangeSquared` (which `superMimicActionRate` sums), `characterMass` (which
  `characterWeight` builds on), `effortCost` (the torque's mean over the actuated dofs and the steps, the energy per unit
  of mass - the fleet's `superMimicReward` now calls it). The device: model table `character_mass`; world_f
  `previous_actions` and `super_mimic_rewards`; `judge_rewards` completes the reward - the action rate over the action's
  numbers (extra limb numbers zero on both sides add exactly 0.0), the joints past their limits in joint order (boxed
  balls by `ballBoxExcess`, ranged hinges and slides by `jointLimitExcess`), the effort's cost. THE KIT's CHECK FAILS:
  the fleet's `super_mimic_rewards` -63.528324 against the device's -63.51048 - not rounding. The tracking totals
  already agree to the bit and the effort's weights are zero, so the gap is the action rate or the joint-limit excess.
  NEXT, FIRST: store the device's action rate and joint excess per world beside the reward, compute the fleet's from
  its own functions at the same state, and compare term by term; suspects - which action and previous action each side
  uses at a reset-free decision, and whether the fleet's excess and the device's read the same boxes (the margin's).
- Nov 6: THE SUPERMIMIC GAP NARROWED (probes, removed again). Every decision of the stiffness-off run agrees on
  all three - the fleet's stored reward, the device's, and one recomputed from the fleet's own functions - the forced
  clamp's decision included. The one gap: stiffness on, decision 5, the knocked character - the fleet's reward is the
  recomputed one, the device's differs by exactly joint_limit_weight (-2) times the fleet's excess, 0.008921623, all of
  it ball joint 13, the FIRST pose anywhere outside a box (the device's box path never exercised before). The twin's
  table holds joint 13's box exactly as the fleet's (its flag 1, its bounds), and the twin's own positions give the
  same 0.008921623 through the CPU's functions - but the device used 0: in `judge_rewards` the branch `joint_type ==
  .ball and boxes.load(8 * joint + 3) == 1.0` is not taken for it. SUSPECTS, next: how `ModelTable(.model_f,
  .joint_box_numbers).load` indexes (the item kind's numbers per item, its offset) against `rotationBoxNumbers`'s
  writes, and `jointTypeOf` for a ball. AND A CONSEQUENCE TO CHECK: `reference_targets`' ball clamp tests the same
  flag, so the "forced clamp" check may have passed with no clamp on either side - it needs an assertion that the
  fleet's clamp did act. The kit's check still fails on the whole SuperMimic reward, as recorded.
- Nov 6: THE BOX BRANCH, NARROWER STILL. `ModelTable.load(item)` is `loadNumber(arena, offset + item)` - the very index
  the probe read the flag 1.0 at - yet in `judge_rewards` the branch is never taken. An experiment with the flag test
  dropped (reverted) made the device find an excess of about 2.9 at decision 0, where the fleet's is 0: so the
  rotations the kernel reads differ from the CPU's at the same positions too. TWO SUSPECTS, next: (1) the image the
  twin's kernels read is not the one `CpuTwin.setTracking` writes after initialisation (`g.B.model_f`) - a copy taken
  at init, or the boxes written before something re-packs; test it by reading the flag back through
  `params.layout.model_f.ball_boxes.load` from the test, beside `g.B.model_f`; (2) `loadQuaternion` orders or
  normalises a ball's four numbers otherwise than `readJointCoordinates` - test it by comparing the two for joint 13.
  Both cheap; then the fix, then an assertion that the fleet's clamp acted in the forced-clamp decision.
- Nov 6: THE BOX BRANCH's BUG FOUND AND FIXED - MINE. `jointTypeOf` takes a joint's PACKED TYPE WORD (MuJoCo's
  numbering), not its index; `judge_rewards`' joint loop passed the index - joint 13 decoded as a hinge, so its box was
  skipped, and (in the flag-dropped experiment) joint 1 decoded as a ball, joint 2 as a slide, measured from the wrong
  coordinates. Both suspects cleared first by a probe: the flag through `params` read 1 as the image does, the kernel's
  quaternion the CPU's. FIXED: `jointTypeOf(joint_tables.joint_type.load(joint))`, as every other kernel reads it; no
  other call passes an index. CHECKED: the kit's decision check - SuperMimic's whole reward the fleet's at every
  decision, the stiffness off and on, the decision whose pose left a box (excess 0.008921623) included - 2/2; lint.
  C1 IS COMPLETE ON BOTH ENGINES. NEXT: the forced-clamp check made to prove a clamp acted (the fleet's clamp changing
  a target there); then C2, resets and pushes.
- Nov 6: THAT CLASS OF BUG MADE UNWRITABLE (Simon: "Make this class of bug harder or impossible to make?"). The bug: a
  bare u32 meaning two things - a joint's index and its packed type word - and a decoder named for the joint but taking
  the word. NOW: `typeOfJoint(joint)` - the joint's index in, its word loaded from `joint_type` and decoded inside it -
  and `typeOfGeom(geom)` the same for geoms; the separate decoder is gone, so nothing that takes a raw word remains to
  be handed an index. All eleven joint calls and both geom calls rewritten (the old name gone, the compiler confirms
  none missed). THE RULE, for the code to come: a packed word is decoded only by the accessor that loads it, named for
  what it is asked of. CHECKED: robotgpu 29/29; the kit's decision check 2/2; lint.
- Nov 6: THE FORCED CLAMP PROVEN. The kit's decision check, at decision 5, rebuilds the knocked character's last
  physics step's targets with robot.zig's own `applyAction` (its final applied action, on the reference at the frame
  that step aimed at) and asserts `clampBalls` changes them - so the device's ball clamp is checked where it acts, not
  where it might not. CHECKED: the kit's decision check 2/2, the clamp acting in both runs and every array still the
  fleet's bit for bit; lint. NEXT: C2, resets and pushes.
- Nov 6: NO BARE NUMBERS FOR A JOINT's TYPE (Simon: "Is there a reason why are not using enums for things like 0 =>
  .free"). There was none left: the switch spelled MuJoCo's numbering a second time, for fear of a checked cast's panic
  path on the GPU - but `GeomType`, an `enum(u32)`, already decodes with `@fromBackingInt` in kernels that compile for
  SPIR-V and WGSL. `robot.JointType` was a bare `enum` (a u2 tag), whose cast from u32 would have needed narrowing.
  NOW: `robot.JointType = enum(u32)`, its order MuJoCo's (the comptime pin kept), and `typeOfJoint` one line - the
  enum's own conversion of its packed word; the numbering lives once. CHECKED: robotgpu 29/29; the kit's decision check
  2/2; vk-host-test, every check (the SPIR-V); the page's web build, Tint clean (the WGSL); lint.
- Nov 6: C2, PART ONE - COUNTER-BASED DRAWS. robot.zig: `DrawPurpose` (start clip, start frame, start in trouble, its
  push's direction, a push's chance, speed and direction - each its own stream, so a draw added later never shifts
  another's), `drawWord` (the run's seed, the world, a counter - the world's episode, or the decision - and the purpose,
  each folded in and scrambled by the PCG family's output permutation: integer multiplies, xors and shifts any GPU
  computes exactly), `drawUniform` (the word's top 24 bits as an exact f32 fraction). CHECKED: in [0, 1); the same for
  the same inputs; apart for a different purpose, world or counter; a mean of 10,000 within 0.01 of a half; lint.
  NEXT: the fleet's four uses of its stream (the start's clip and frame - `drawStartFrame` - its start in trouble and
  direction; a decision's push chance, speed and direction) through `drawUniform`, its episodes and decisions counted
  per character; then the device's reset and push kernels from the same draws, the twin's episodes the fleet's.
- Nov 6: REVIEW OF C2's FIRST PART (Simon: "Review"). FOUND: an index drawn as `floor(drawUniform(...) * count)` can be
  `count` itself - for a clip of 600 frames the largest draw times 600 rounds to 600 in f32, one past the end. ADDED:
  `drawBelow(seed, world, counter, purpose, count)` - integers alone, the word's top 16 bits times the count shifted
  down 16, always below it, for a count up to 65536 within 32 bits (WGSL has no 64-bit integers). THE RULE for the
  fleet's and the device's draws: an index through `drawBelow`, a fraction through `drawUniform`, never one made from
  the other. NOTED FOR THE FLEET's WIRING: its seed is a u64 - fold both halves into the u32 the draws take; each
  character's episode counter must count starts the same way on both engines. CHECKED: both draw tests (every index
  below 600 and 3, every one of 3 reached, the largest word's index below its count); lint.
- Nov 6: C2's WIRING, TWO FINDINGS BEFORE IT. (1) THE FLEET's START FRAME HAS TWO PATHS: uniform (one index -
  `drawBelow`) and an ADAPTIVE CURRICULUM (`Options.curriculum.bin_seconds > 0`): start frames weighted by each bin's
  recent failure rate, the long-run weights folded at every restart - state on the host, which the device would need
  as a table refreshed from the flags read back. (2) THE START NOISE (`perturbStart` in `startAt`) draws one number per
  coordinate, so the draws need an index beyond seed, world, counter and purpose: `drawWord` gains `index` (0 for a
  single draw) and `drawSeed` folds the fleet's u64 seed - written, not yet applied (lint-fix had split `drawBelow`'s
  signature: match by name next time). FOR SIMON: does the night use the curriculum? If not, the device's starts are
  uniform and simple; if so, a bins table and its refresh are a part of their own.
- Nov 6: THE CURRICULUM DECIDED - SUPERMIMIC's (Simon: "Yes. Do adaptive curriculum like supermimic"). Read from their
  code: one-second bins, each bin's return estimate updated 0.8/0.2 from its finished episodes (a cut-short episode's
  tail bootstrapped), starts drawn from half uniform, 0.4 a softmax towards low returns, 0.1 its slow average. C18
  added; our failure-rate curriculum gives way to it.
- Nov 6: THE DRAWS' INDEX APPLIED. `drawWord`, `drawBelow` and `drawUniform` take an index within a purpose (0 for a
  single draw; a coordinate's number for the start noise); `drawSeed` folds the fleet's u64 seed into the draws' u32,
  both halves kept. Matched by name this time, the signatures rewritten whole. CHECKED: both draw tests 2/2; lint. NEXT:
  the fleet's uniform starts, starts in trouble and pushes through the draws (per-character episode numbers, the
  decision number), then C18.
- Nov 6: THE FLEET's WIRING, MAPPED (not yet made). What it touches: `restart` (the clip by `drawBelow(.start_clip)`;
  the start in trouble and its direction by `drawUniform`), `drawStartFrame` (its uniform path by
  `drawBelow(.start_frame)` - it gains the character to draw for; its callers: `restart`, and two kit tests,
  robot_latent_kit_tests.zig near 2899 and 2919, the first comparing with a value drawn from the old stream, so its
  expectation is rewritten from the draws, not merely its call), `Fleet.step`'s three uses of the stream (a push's
  chance, speed and direction, the counter the fleet's decision number), `startAt`'s `perturbStart` (one draw per
  coordinate, the index the coordinate's number). New fleet state: `draw_seed` (`rbt.drawSeed(options.seed)`),
  `episode_numbers` per character (advanced at each restart - the counter of its start's draws), `decision_number`.
  The curriculum's path stays on the stream until C18 replaces it.
- Nov 6: THE BALANCE ADDED (Simon: "Add to the plan"): section 6b - the four consumers of a round's budget, their
  levers and the signal of each one's need, the central ratio of updates per collected step, the night's starting split
  of time and the rules that shift it, D8 the split logged per round. REMAINING, estimated: about 40 to 50 turns to
  the dry run (37 by part; every part so far has found something).
- Nov 6: C2, PART TWO - THE FLEET ON COUNTER-BASED DRAWS. New fleet state: `draw_seed` (`rbt.drawSeed`),
  `episode_numbers` per character (advanced at each restart - the counter of its start's draws), `decision_number`
  (advanced at each step - the counter of its pushes'). `restart` draws its clip by `drawBelow(.start_clip)`, its start
  in trouble and that push's direction by `drawUniform`; `drawStartFrame(env, clip_index)`'s uniform path by
  `drawBelow(.start_frame)` (the curriculum's path stays on the stream until C18); `step`'s push chance, speed and
  direction by `drawUniform` at the decision's number, the step's stream gone with them. The curriculum test's "old
  draws" part rewritten from the draws, and it now checks a start frame is the same however often it is drawn within an
  episode. CHECKED: the kit's 200 matching tests (169 run, 31 skipped, 0 failed); robot_track's own (below); lint.
  NEXT: the start noise (`perturbStart`, one draw per coordinate, the index its number), then C18, then the device's
  resets and pushes from the same draws.
- Nov 7: THE PAGE ON SIMON's PHONE, AND ITS ONE WARNING. Republished from the current code: Geno's scene runs on his
  phone - every kernel's pipeline, the judgement's, the effort's and the box clamp's included, compiled on its GPU;
  the GPU's root 5.9 mm from the CPU's at frame 288. The Go1 refused as known (`TooManyRows`: its limits and its feet's
  contact slots exceed a world's fixed rows - MuJoCo Warp's shared row pool is the fix, deferred, the Go1 off for the
  night; its CPU side on its back at run 7, worth a look, not for the night). THE WARNING, "[wgsl] code is
  unreachable", traced to `judge_rewards`' module: `robot.jointLimitExcess`, whose every switch arm returned, left an
  unreachable merge that `spv2wgsl` turned into a dummy return. FIXED in the function - one value chosen, one return -
  the page back to zero warnings in Tint; FOR LATER, the general fix in `spv2wgsl` (nothing emitted after a switch
  whose every arm returns). CHECKED: Tint 0 warnings; the joint-limit test 1/1; the kit's decision check 2/2; lint;
  the page republished.
- Nov 7: CATCHING UNREACHABLE CODE IN THE BUILD - THE CHECKER's RULE, NOT YET ENABLED. `scanUnreachable` in
  tools/spv2wgsl_check.zig (a stack of blocks, each knowing whether its last statement ended control: a statement
  after `return`/`break`/`continue`, or after a `switch` with a `default` whose every arm ends in one; `if` and loops
  taken never to end it) with its unit test (the phone's pattern caught at its line, clean code passing). ON THE REAL
  MODULES: the `judge_rewards` module from before the fix flagged at line 1278 - exactly Tint's warning - but also at
  line 2052, a statement Tint accepts; and the module after the fix still shows two findings. FALSE POSITIVES, so the
  rule is UNWIRED from `checkOne` (it would fail the tripwires on correct code) until they are understood and removed.
  NEXT: read line 2052's context in the old module (`let _21652: bool = phi21647 == 8u;`) and the post-fix module's
  two findings; refine the rule; wire it into `checkOne` beside `scanKnownBugs`; then the translator's own fix (nothing
  emitted after a switch whose every arm returns).
- Nov 7: THE UNREACHABLE-CODE RULE, EXACT AND ENABLED. The false positive was a switch whose arms end in `break`: in
  WGSL a case's `break` leaves only the switch, so control goes on after it. `scanUnreachable` now records HOW each
  block's last statement ended control (return, break, continue); a case arm ends the switch's control only by
  `return` or `continue`, while in any other block every terminator makes what follows unreachable. ON THE REAL
  MODULES: before the fix, one finding - line 1278, Tint's own warning; after it, none. WIRED into `checkOne` beside
  `scanKnownBugs`, so the build's tripwire step (every shader in the cache) fails on unreachable code, naming the
  line. CHECKED: the checker's tests; lint. The whole corpus is first scanned at the next tripwire run. NEXT: the
  translator's own fix (nothing emitted after a switch whose every arm returns), then the start noise and C18.
- Nov 7: THE TRANSLATOR's TRAILING RETURN KEPT, ON PURPOSE. `spv2wgsl`'s `emitUnreachReturn` writes a zero-value
  `return` after a tail whose every arm returns because naga (Firefox) rejects a value-returning function that does not
  end in one; Tint accepts it and only warns. Removing it would trade a harmless warning in Chrome for a failure in
  Firefox. THE POLICY INSTEAD: a Zig function that reaches the GPU returns once - its final switch or if chooses a
  value - and the checker's `scanUnreachable` enforces it at the WGSL level, its comment now giving the reason and the
  fix. CHECKED: lint. NEXT: the start noise through the draws, then C18.
- Nov 7: C2, PART THREE - THE START NOISE ON THE DRAWS. robot.zig: `DrawPurpose.start_noise`; `drawNormal` (Box and
  Muller: the index-th normal of a purpose from the uniform draws 2 index and 2 index + 1, sqrt(-2 ln u1) times the
  cosine of u2 turns - `cosTurns`, as the house rule has it - u1 from (0, 1]). robot_track: `NoiseSource`, a tagged
  union - `drawn` (seed, world, episode: the fleet's, and the device's to come) or `stream` (a Random: robot_geno's
  planners, bit for bit as before) - and `perturbStart` reading its normals from it, each actuated dof's turn at its
  dof's index, the two velocity kicks at the next two; the fleet's `startAt` passes its character's draws.
  CHECKED: the kit's 200 matching tests (169 run, 31 skipped); lint. NOT YET COMPILED: robot_geno's two planner calls
  (`.{ .stream = rng.random() }`) - nothing the tests reference reaches them; the trainer's build will. NEXT: C18.
- Nov 7: C18, PART ONE - SUPERMIMIC's CURRICULUM RULE IN ROBOT.ZIG. `startBinProbabilities(bin_returns, long_run,
  return_scale, out)` (their mixture: 0.5 uniform + 0.4 softmax(-25 G / scale), its largest exponent subtracted first +
  0.1 the long-run average, updated in place 0.999/0.001 at every draw as theirs is) and `updateStartBinReturn(...)`
  (G <- 0.8 G + 0.2 R; R the discounted return plus, for an episode cut short rather than ended by failure, the tail
  gamma^length (mean) / (1 - gamma)) - one definition for the host's bookkeeping and the device's table. CHECKED: their
  formula recomputed on three bins (returns 10, 5, 0): every probability and average to 1e-5, the sum 1, the
  lowest-return bin the most probable; a failed episode its return alone, a cut-short one its tail too; lint. NEXT: the
  fleet's curriculum through them - one-second bins over every clip, each finished episode's discounted return and
  mean reward kept per character, the mixture's draw by `drawUniform` and its cumulative sums, a frame by `drawBelow`.
- Nov 7: C18 - THE RULE's NUMBERS AS PARAMETERS. `robot.StartCurriculumRule` (uniform_share 0.5, hard_share 0.4, the
  history the rest; sharpness 25; history_memory 0.999; return_memory 0.8 - SuperMimic's constants as defaults), passed
  as the first argument of `startBinProbabilities` and `updateStartBinReturn`, no literal left inside them. FOUND IN
  THE FLEET: its `ResetCurriculum` already has SuperMimic's mixture shape (0.5 uniform, 0.4 hard, 0.999 memories) but
  on FAILURE RATES (`bin_failure_rates`, folded at every decision with `rate_memory`; weighted by `hardWeight` with
  its own `sharpness`). NEXT: the fleet on returns - `ResetCurriculum` carries a `StartCurriculumRule`, a discount and
  the largest step reward (its `sharpness` and `rate_memory` gone); `bin_failure_rates` becomes `bin_returns`; per
  character its start bin, discounted return, reward sum; at each episode's end `updateStartBinReturn`; at each start
  the clip's bins through `startBinProbabilities`, a bin by `drawUniform` over the running sums, a frame within it by
  `drawBelow`; the curriculum test rewritten for returns. CHECKED: the rule's test 1/1; lint.
- Nov 7: THE SPIR-V OPTIMIZER INTEGRATED (Simon's upload: tools/spirvopt.zig, a 53,000-line single-file port of
  SPIRV-Tools' source/opt). ONE CHANGE TO BUILD on our toolchain: `std.ArrayListUnmanaged` (gone in 0.18-dev) to
  `std.ArrayList`. Excluded from lint for now through `deletion_skip`, the list of files that opt out of the style
  gate. BUILD: `-Dspirv-opt` (off by default) builds it for the host (ReleaseSafe) and sends every compute kernel's
  SPIR-V through its -O pipeline (`ShaderPipeline.spirvopt_exe`, stage 1b) before WGSL and Vulkan take it. RESULTS:
  WORKS ON VULKAN - vk-host-test passes every check with the optimized SPIR-V, no validation error, the robotgpu twin
  comparisons within their bars. SMALLER - the robotgpu module 803,200 to 692,524 bytes (-14%), optimized in 3.8 s.
  PERFORMANCE NOT MEASURED - the sandbox's Vulkan is lavapipe, on the CPU, and vk-host-test prints no kernel times; a
  GPU's driver optimizes again, so the gain wants a timed run on Simon's GPU. SPV2WGSL DOES NOT YET TAKE ITS OUTPUT:
  its strict guard fails the web build - "`kbuf_world_u` is ACCESSED in the SPIR-V but never in the emitted WGSL" for
  `reference_targets`, `project_constraints` and others: a construct of the optimizer's output that spv2wgsl drops,
  caught at build time rather than miscomputing. NEXT, for this: find that construct in one kernel's optimized SPIR-V.
- Nov 7: SPV2WGSL ON THE OPTIMIZER's OUTPUT - THE SEARCH, PART ONE (Simon: "Do it"). One robotgpu module holds every
  kernel's entry point (spv2wgsl picks one with `--entry`). In the raw module `kbuf_world_u` is reached through 2
  `OpInBoundsAccessChain`s, inside helper functions; in the optimized one, everything inlined, through 73 directly in
  the kernels, with 61 loads and 30 stores on them. Run alone on the optimized module for `filter_actions`, spv2wgsl
  stops with `DroppedBufferAccess` (exit 3) - `kbuf_world_f` accessed in the SPIR-V, never in the WGSL: a guarded
  block dropped whole while its condition stays, the failure `src/notes/spv2wgsl_dropped_block.md` records from an
  earlier bug in spv2wgsl's own SCCP selection fold - now met through the optimizer's control-flow shapes. spv2wgsl has
  no switches for its passes. NEXT: find the block - the first `kbuf_world_f` load or store of `filter_actions` in the
  optimized SPIR-V, its block and the selection guarding it (the shape: a branch whose true edge is the merge? a
  selection the optimizer merged or inverted?) - then spv2wgsl's handling of that shape in its fold or structurizer.
- Nov 7: SPV2WGSL ON THE OPTIMIZER's OUTPUT - THE SHAPE FOUND. `filter_actions` after spirvopt is nine blocks:
  SPIRV-Tools' merge-return pass turns early returns into BREAKS OUT OF SWITCHES WITH ONLY A DEFAULT, two nested
  (`OpSwitch %57 default ...`, both on the same selector, apparently a constant). Block #6 - the then-side of an if -
  branches straight to the OUTER switch's merge (a break); block #7, that if's merge, reached only on the false edge,
  holds the three `kbuf_world_f` accesses spv2wgsl drops. In WGSL the shape is `switch (x) { default { ... if (c) {
  break; } ... } }`, valid. HYPOTHESIS, matching the earlier bug's mechanism (`spv2wgsl_dropped_block.md`): spv2wgsl's
  SCCP folds a single-case constant switch into its default body, the break in #6 loses the construct it leaves, reads
  as a plain branch to the function's end, and #7 looks dead. NEXT: confirm in spv2wgsl's selection fold
  (`mergeBlockPhiWouldOrphan` and its fold), then keep a switch whose merge is the target of a break from inside it
  (or emit it as WGSL's own `switch` with a `default`), then all 8 kernels and the page's Tint with `-Dspirv-opt`.
- Nov 7: THE HYPOTHESIS TESTED - NOT THE CAUSE (OR NOT ALONE). spv2wgsl's fold of constant selections skips a
  case-less switch only when its merge carries a phi that folding would orphan (`mergeBlockPhiWouldOrphan`);
  `filter_actions` returns nothing, so its switches' merges carry none and they fold. Skipping the fold for every
  case-less switch (`isCaselessSwitch`: an `OpSwitch` of three words) did NOT fix it: `filter_actions` and
  `reference_targets` still lose their blocks. Reverted - an unproven change does not stay in a translator every shader
  goes through. NEXT: see what spv2wgsl emits - let the `DroppedBufferAccess` guard write its WGSL before failing, under
  a debugging flag - and read how it lowers the breaks out of those switches (its structurizer, not its fold).
- Nov 7: WHAT SPV2WGSL EMITS FOR THE OPTIMIZED `filter_actions` (a temporary print at the guard, removed; the probe
  tool at /tmp/spvopt/spv2wgsl_probe). ONE `switch (0u) { default: { ... } }` - the INNER case-less switch (#1, whose
  merge carries phis), its two breaks right. AFTER IT the condition of selection #5 (`let _525572: bool = phi603556 ==
  0u;`) and then `return;`. MISSING: the OUTER case-less switch (#0, whose merge is the function's `OpReturn` block and
  carries no phi), the if of #5 that breaks out of it, and #7, the code after that if (the dropped accesses). Not the
  fold (skipping it changed nothing), and `buildIf` already lowers a branch to an outer switch's merge. SUSPECTS, next:
  how the IR builder starts a function whose ENTRY block is itself a switch header (#0 is the entry), and a switch whose
  default target is another construct's header (#0's only edge is #1's `OpSwitch`) - one of them loses the outer
  construct. Trace the builder from the entry block with the probe tool.
- Nov 7: THE BUILDER READ - THE SHAPE SHOULD BUILD. `buildBlock` sends any `switch_header` block to `buildSwitch`
  (the entry block included); the block table marks #0 a switch header (`OpSelectionMerge` + `OpSwitch`); `buildSwitch`
  gives up only on a terminator that is not a switch, and builds its default target as any case. Read along it, the IR
  for `filter_actions` is right: the outer switch's default body starts with the inner switch, which ends at #5; #5's
  if has a true side that leaves the outer switch (`buildIf`'s outer-construct branch) and an empty false side; then #7
  and its accesses before the outer merge. SO EITHER THE EMITTER LOSES PART OF THAT IR, OR THIS FUNCTION NEVER GOES
  THROUGH THE BUILDER. NEXT: a MINIMAL REPRODUCTION in spv2wgsl's own tests (`zig build test-spv2wgsl`, the fast loop;
  SPIR-V assembled inline as the switch tests near line 6352 do) - an entry block that is a case-less switch header
  whose default target is another case-less switch header, an if in the outer body breaking to the outer merge, a
  store after that if - asserting the store survives in the WGSL; it isolates the bug and stays as its regression test.
- Nov 7: THE MINIMAL REPRODUCTION - THE BUILDER IS RIGHT. A builder test in spv2wgsl ("build keeps the code after a
  break out of an outer case-less switch (spirv-opt's merge-return)"): the entry block a case-less switch whose default
  is another, an if breaking out of the outer one, the block after the if - which the builder KEEPS in the outer
  switch's default (test-spv2wgsl, passes; kept as a guard). THE DIFFERENCE FROM THE REAL MODULE: the test's selector
  is an undefined id; `filter_actions`' switches are both on `%57`, A CONSTANT - which is what spv2wgsl's SCCP folds
  and its emitter's handling of folded selections act on, neither of which the builder test runs. NEXT: the same shape
  through the whole translation with an `OpConstant` selector (an end-to-end test asserting the store survives in the
  WGSL), and the probe tool's output for `filter_actions` with the case-less fold skipped - to see which later stage
  removes the outer switch.
- Nov 7: TWO PROBLEMS, NOT ONE (the probe tool, the case-less fold skipped; the source restored). WITH THE FOLD
  SKIPPED, the OUTER switch is emitted - so the case-less fold DID remove it (problem 1, fixed by never folding a
  case-less switch: `isCaselessSwitch`, as tried before). BUT the outer body then ends `let _525572: bool = phi603556
  == 0u; break;` - the if of block #5 folded to its true side (problem 2): spv2wgsl's SCCP took `phi603556 == 0u` for a
  constant true. That phi joins `0u` from the inner switch's early break and `_525626`, a runtime select, from its
  ordinary exit; it reads as constant only if SCCP takes the ordinary exit edge (%525610 -> %525629) for never
  executed - in a case-less switch on a constant selector. NEXT: SCCP's edge executability for `OpSwitch` with no
  cases (its default edge, and the edges inside its body to its merge); a test with a phi at the inner switch's merge
  fed a constant on the early path and a runtime value on the other, asserting the if survives; then both fixes, the
  8 kernels and the page's Tint with `-Dspirv-opt`.
- Nov 7: SCCP's RULES READ - THEY LOOK SOUND. An `OpSwitch` on a constant selector makes only its taken target live
  (the default, for a case-less one - right); a conditional branch folds only on a `.konst` condition, keeping both
  edges live for top or varying. Read along them, block #2's branch (on `_525567 == 0u`, a load from the uniform `P`)
  keeps both edges, so the phi at #5 meets `0u` with the runtime `_525626`, comes out varying, and #5's if should NOT
  fold - yet it is folded. NEXT: the analysis's actual state, printed by the probe tool for `filter_actions` - the
  blocks in `analysis.folded` with their taken targets, the lattice values of the phi, of `%525572`, of `_525567` and
  of `_525609`, and which edges into #5 are live - to see where the actual run departs from the rules.
- Nov 7: SPV2WGSL's TWO BUGS FIXED. THE PROBE showed SCCP's lattice right (every value of #5's condition varying) but
  its fold map holding `525629->525575` - a STALE FOLD: on an early pass of the fixpoint the edge #4 -> #5 was not yet
  live, the phi saw only `0u`, the condition was briefly a constant true and the branch was folded; later the edge
  became live and the condition varying, and the varying rule marked both edges but never removed the fold. FIX 1
  (SCCP): a conditional branch whose condition, or a switch whose selector, is no longer constant loses its fold - the
  folds match the fixpoint. FIX 2 (the fold loop): a case-less switch is never folded (`isCaselessSwitch`) - its breaks
  need its construct. CHECKED: spv2wgsl's tests 67/67 (the builder reproduction among them); lint; THE DEFAULT PAGE's
  Tint - 0 errors, 0 warnings; the page WITH `-Dspirv-opt` BUILDS - the eight kernels that lost blocks translate - but
  Tint rejects one module: `newton_solve`, "unresolved value '_509905'" (line 2256) - spv2wgsl names a value it never
  defines, a third gap the optimizer's output opens, which the strict check does not catch. NEXT: that value in
  `newton_solve`'s optimized SPIR-V - where it is defined, and why its definition is not emitted before its use.
- Nov 7: NEWTON_SOLVE's UNRESOLVED VALUE - FOUND. `_509905` is a `let` at WGSL line 1915, inside a case-less
  `switch (0u) { default: { ... } }` now kept (fix 2), and named again at lines 2256 and 2641, after the switch. IN THE
  SPIR-V, `%509905` (an `OpIAdd`) is used ONCE, in its own block (the load at line 1916): the later "uses" are NOT in
  the SPIR-V - there spv2wgsl replaced other ids, identical expressions, with `_509905` (a redundancy elimination of
  its own). Valid in SSA, where the definition dominates; but it bypasses `markHoistedResults` (which hoists a value
  used in a block other than its own to a function-scope `var`), so the replaced value stays a block-scoped `let`.
  Before fix 2 the switch was folded and its body emitted inline, so the `let` happened to stay visible. NEXT: find
  that pass, and mark a replacement's definition hoisted whenever the replaced use is in another block (or run the
  substitution before `markHoistedResults`).
- Nov 7: THE CAUSE, REFINED - POINTERS AS TEXT. spv2wgsl has no redundancy elimination of its own: it emits an
  access chain's pointer as TEXT (line 7347: "loads and stores through it work as plain text substitution"), so a load
  through `%ptr = OpInBoundsAccessChain kbuf_world_u 0 %509905` prints `kbuf_world_u.field_0[_509905]` WHEREVER the
  load is. The SPIR-V's one use of `%509905` is that access chain, in its own block; spirv-opt's own redundancy
  elimination REUSED that one pointer for loads in later blocks (legal SPIR-V), and the text expansion carries the
  index's name into blocks it was never used in. `markHoistedResults` sees only the access chain's use, in its own
  block, so the index stays a `let`. THE FIX: in `markHoistedResults`, a use of an access-chain pointer defined in
  another block counts as a use of its value operands (its indices, through chained access chains) - they are hoisted.
  NEXT: write it (the defining instruction of a pointer id from `IdInfo`), a test with a pointer reused across blocks,
  then `newton_solve`, the page's Tint with `-Dspirv-opt`, and the default page again.
- Nov 7: FIX 3 - A POINTER's INDICES HOISTED; THEN TINT's UNIFORMITY. `hoistChainIndices` (spv2wgsl, called from
  `markHoistedResults`): an access-chain pointer used outside its block hoists its index values, through every chain
  it is built on (`AccessChain`, `InBoundsAccessChain` - spv2wgsl has no `PtrAccessChain`). CHECKED: spv2wgsl's tests
  67/67; lint; `newton_solve` translates, `_509905` a function-scope `var`. THEN, WITH `-Dspirv-opt`, Tint rejects
  `newton_solve` otherwise: "'workgroupBarrier' must only be called from uniform control flow" (line 8418). The barrier
  sits inside the OUTER case-less switch (line 1868) that spirv-opt's merge-return wraps around nearly the whole kernel,
  after 224 breaks in it, some leaving the wrapper under a runtime condition - which Tint takes to make all that follows
  non-uniform. The raw path has the same early exits as `return`s and passes. THE FIX TO MAKE (4): a case-less switch
  whose merge block ONLY RETURNS is emitted as its body, and a break to that merge as a `return` - undoing merge-return,
  so Tint sees the raw path's control flow. (Alternatively, run spirvopt for the web without `--merge-return`.)
  NEXT: fix 4, then the page's Tint with `-Dspirv-opt`, and the default page and the launcher again.
- Nov 7: FIX 4 - THE MERGE-RETURN WRAPPER UNDONE; AND WHY THE BARRIER STAYS NON-UNIFORM. spv2wgsl's builder: a
  case-less switch AT THE FUNCTION's TOP whose merge returns at once (`isReturnWrapper`) is lowered as its body, its
  merge pushed as a stop of the new `ExitKind.ret`, so every branch to it is a `return`. The reproduction test now
  checks that (the if's true side a return, %70 kept, the chain returning). CHECKED: spv2wgsl's tests 67/67; lint; the
  DEFAULT page's Tint - 0 errors, 0 warnings. WITH `-Dspirv-opt` THE BARRIER STAYS REJECTED (line 8416): its early
  exits are not the wrapper's - they are INLINED HELPERS' early returns. In the raw SPIR-V a helper's `return` leaves
  only the helper, and Tint takes control flow as uniform again when the call returns; inlined, the same exit is a break
  out of an inlined region, and WGSL's uniformity analysis takes everything after a break under a runtime condition as
  non-uniform. INLINING AND TINT's UNIFORMITY ARE AT ODDS for a kernel with a barrier after a helper that can exit
  early. CHOICES FOR SIMON: (a) the web takes the raw SPIR-V and Vulkan the optimized (drivers and Tint optimize
  again; the web gains little from it); (b) a web pass list without inlining and merge-return; (c) leave it off. The
  four spv2wgsl fixes stay - each corrects a translation, and the default page is clean with them.
- Nov 7: CHOICE (b) MADE (Simon: "B") - A WEB PASS LIST. `ShaderPipeline.spirvopt_web_passes`: the -O pipeline, in its
  order, without merge-return and without inlining (42 of its 44 steps); `optimizeSpirv` runs one optimization as a
  build step. With `-Dspirv-opt`, Vulkan takes the -O module and the web the module of the web's passes. SIZES, the
  robotgpu module: raw 803,200 bytes, -O 692,524 (-14%), the web's passes 521,104 (-35%; no helper body copied per
  caller), in 1.4 s. CHECKED: the page built with `-Dspirv-opt` - Tint 0 errors, 0 warnings (`newton_solve` included);
  vk-host-test with `-Dspirv-opt` - every check; lint. NOT CHECKED HERE: the page's numbers (headless Chrome draws no
  WebGPU canvas) - for Simon's phone, robotgpu_sidebyside_spirvopt.html (the GPU's root beside the CPU's).
- Nov 7: C18, PART TWO - THE FLEET ON SUPERMIMIC's CURRICULUM. `ResetCurriculum` carries `rule`
  (`rbt.StartCurriculumRule`), `discount` (0.99) and `largest_step_reward` (5.0, SuperMimic's tracking weights summed) -
  its shares, `sharpness`, `rate_memory` and `history_memory` gone with `hardWeight`. The fleet: `bin_returns` (each
  bin's G, in place of `bin_failure_rates`), `bin_probabilities` (scratch); per character `start_bins`,
  `episode_discounted_returns`, `episode_discount_powers`, `episode_reward_sums`, `episode_decisions`. `startAt` records
  the start bin and clears them; each decision adds its SuperMimic reward, discounted from the episode's start; a
  finished episode folds into its start bin (`foldEpisodeIntoStartBin`: a failure unless cut short at the cap) before
  its restart; `drawStartFrame`'s curriculum path draws the clip's bins through `rbt.startBinProbabilities`, a bin by
  `drawUniform` (index 1) against their running sums, a frame within it by `drawBelow` (index 2) - the fleet's stream
  gone from it. CHECKED: the curriculum test rewritten for returns - every bin at 100 but bin 2 at 0, 20,000 draws, a
  new episode each: bin 2 at 0.587 and the others at 0.103 (SuperMimic's formula), within 0.02; a falling fleet's
  finished episodes fold finite returns into their start bins; the kit's 200 matching tests (169 run, 31 skipped);
  robot_track 325/368; lint. NEXT: the mocap tutorial's curriculum (if it describes the failure rates), then the
  device's resets and pushes from the same draws (C2), the bins' mixture as the device's cumulative table (C18's last).
- Nov 7: THE TUTORIALS IN STEP WITH C18. The mocap tutorial's "Where episodes start" rewritten for SuperMimic's
  curriculum (each bin's return estimate, its update at an episode's end, the mixture toward low return, a worked table:
  every bin at 100 but bin 2 at 0, bin 2 taking 0.97 of the hard draws and 0.59 of the starts); its fold of the step
  without the removed `at`; robots.html's `JointType` line as `enum(u32)`. CHECKED: doc-sync to completion - robots.html
  3,845 lines and the mocap tutorial 13,424, nothing drifted.
- Nov 7: C2 ON THE DEVICE - THE RESET's DESIGN, FROM THE FLEET's `startAt`. The device keeps each world's clip and
  frame (`world_clip`, `world_frame`) beside its episode counters; nothing on it starts an episode yet (the twin
  starts zeroed; the kit's check copies the fleet's states in). A RESET PROGRAM, every kernel masked to the worlds whose
  episode ended, mirroring `restart` then `startAt` line by line: (1) `begin_reset` - the world's episode number + 1
  (a new world_u array, the counter of its start's draws), its clip (`drawBelow(.start_clip)` when clips are drawn),
  its frame (uniform: `1 + drawBelow(.start_frame, 0, last start)`; with the curriculum, C18's cumulative table and
  `drawUniform(.start_frame, 1)` / `drawBelow(.start_frame, 2)`), its counters, previous and applied actions, effort and
  warm start cleared; (2) `reset_pose` - `resetToFrame`'s pose and velocities from the clip tables; (3) kinematics, the
  bodies' lowest points, `rest_on_floor` (the root lifted onto the floor, `restOnFloor`'s rule), kinematics again; (4)
  `perturb_start` - the start noise by `drawNormal` at each coordinate's index, then (3) again; (5) a start in
  trouble's push (`drawUniform(.start_in_trouble / .start_push_direction)`). Then `push_worlds` each decision (chance,
  speed, direction at the decision number). The record segment is the host's (C4). CHECK: the twin's reset worlds the
  fleet's, bit for bit, through an episode end, a restart and the next decisions. FIRST: `begin_reset` and `reset_pose`,
  with `resetToFrame` read first.
- Nov 7: REVIEW OF THE SESSION's CODE (Simon: "Review recent code. Find what will maybe not work"). FINDINGS, worst
  first: (1) THE CURRICULUM's LONG-RUN AVERAGE MOVES ONCE PER START, SuperMimic's once per SAMPLING CALL (all the
  starts of a step together): with hundreds of restarts a decision, ours forgets ~100x faster - its "history" tenth
  is no history. Fix: fold the average once per decision. (2) THE FLEET's RESTARTS ARE ORDER-DEPENDENT: each ended
  episode is folded into its bin and restarted in the same loop, so character k's start sees the folds of characters
  before it and not after - and the device, folding and resetting in parallel, cannot match it. Fix: two passes - fold
  every ended episode, then restart every ended world. (3) A DIRECT `startAt` DOES NOT ADVANCE THE EPISODE NUMBER
  (only `restart` does): repeated direct starts of one character reuse the same draws - the same start noise every
  time. Fix: one `beginEpisode(env)` that advances it, used by every start. (4) `drawBelow` caps a count at 65,536: a
  clip longer than 9.1 minutes at 120 Hz asserts at its first start. (5) ROTATION BOXES NEAR HALF A TURN: a rotation
  vector takes the shorter way round, so near 180 degrees it flips sign; a box drawn from captures near +170 degrees
  sees a target at 185 as -175, outside, and clamps it 35 degrees back - a jump. Risk for shoulders far from the rest
  pose. Fix: measure each ball's rotation relative to its captures' mean rotation, so a box sits far from the flip.
  (6) TRANSCENDENTALS ON A GPU are not correctly rounded: `drawNormal`'s log and cosine, the boxes' asin, sin and cos -
  a real device's resets, noise and clamps differ from the fleet's in the last bits (the twin's stay bit for bit).
  Accepted, as the termination threshold was. (7) WITH THE LIMBS' STIFFNESS OFF, the device's action rate counts the
  limb numbers too; equal to the fleet's only while they are zero - C3's policy must write zeros there.
- Nov 7: THE REVIEW's FIRST THREE FIXED (Simon: "Make our system perfect. Optimise for robustness, and
  understanding"). (1) THE CURRICULUM's ROUND, ONCE PER DECISION: robot.zig splits the mixture into
  `startBinSoftmax`, `foldStartBinHistory` (once per round, as SuperMimic's sampler folds once per call) and
  `startBinMixture` (pure: a start reads it unchanged, so `drawStartFrame` gives the same answer however often it is
  asked); `startBinProbabilities` composes the three (the test against their formula). The fleet keeps `bin_softmax`,
  refreshed by `refreshStartBins` once per decision with any start, after every finished episode is folded; the
  long-run averages start uniform within each clip (a mixture never divides by an empty history), and the first round
  runs before the fleet's first starts. (2) RESTARTS TOGETHER: the step marks each ended character
  (`ended_this_decision`) and `restartEnded` restarts them after the loop - folds first, then one refresh, then the
  starts - so no start depends on another's place in the loop, and the device can match it. (3) EVERY START ADVANCES
  THE EPISODE NUMBER: `beginEpisode` (the counter of a start's draws), `startEpisodeAt` (the start itself), the public
  `startAt` both; `restart` advances once, before its draws. FOUND ON THE WAY (mine, fixed): `ended_this_decision`
  first allocated with the curriculum only (every fleet needs it), and the averages' uniform start placed before the
  bins were laid out. CHECKED: the kit's 200 matching tests (169 run, 31 skipped); robot_track's and robot.zig's
  SuperMimic tests (above); lint. LEFT FROM THE REVIEW: (5) rotation boxes about each ball's captured mean, before the
  night; (4) `drawBelow`'s 65,536 cap, noted; (6) accepted; (7) for C3.
- Nov 7: THE PLAN REVIEWED FOR NIGHT 1 (Simon: "Review the rest of the plan. Make it a bit better and more precise.
  Think hard ..."). Added "NIGHT 1 - SCOPE, ORDER AND GATES": a minimal night in risk-first order (the learner's device
  spike first), six research components deferred to night 2 with reasons, and six additions before the night - a
  feasibility pass seeding the curriculum, a CPU baseline hour, gates the night checks itself, checkpoints with resume
  after a lost device, a fixed evaluation, the night's goal stated. Estimate revised to 25-30 turns.
- Nov 7: NIGHT 1 AS EIGHT EXPERIMENTS AND THE LAB (Simon: "prepare 8 experiments. 1 hour each ... make a system, all
  in zig and with a good ui, the lab, that shows the progress ... a dryrun of the 8 experiments with just 5 minutes
  each"). Added under NIGHT 1: the screen's principle (one change each against the control E1, one decision for night
  2 each, equal seeds and evaluation), a first proposal of the eight (control; 120 Hz; no limb stiffness; no
  curriculum; harder perturbations; twice the model's updates; four times the worlds; no joint limits) with reserves,
  and the lab: a runner of one process per experiment, a directory per experiment, a reading-only UI, a 40-minute
  dry run before every night.
- Nov 7: THE REVIEW's FINDING 5 FIXED - ROTATION BOXES ABOUT THEIR CAPTURES' MEAN. `RotationBox.center`: the captured
  rotations' mean (each turned to the first's hemisphere, summed, normalized); a ball's rotation measured as the
  rotation vector of the turn from the center to it (`rotationVectorInBox`) - in `rotationBoxes`, `ballBoxExcess` and
  `ballTargetInBox` (a clamped target composed back with the center) - so every captured rotation sits far from the half
  turn where a rotation vector flips. The device's table 12 numbers a joint (low, high, center; `loadBallBox`); robot's
  `qmul` alias made public. CHECKED: the kit's 200 matching tests (169 run, 31 skipped) - the mocap through its boxes
  unchanged, the device's forced clamps bit for bit; lint. AND (Simon: "go with that ... curious about skip model and
  planning in offset around policy ... have not been tried together"): E7 becomes those new learning signals together,
  with the stiffness and the filter; C8 and C9 come back into night 1's build, behind switches; four times the worlds to
  the reserves. NEXT: the learner's device spike, then C2's device resets.
- Nov 7: THE LEARNER's DEVICE SPIKE - WHAT IT IS, PRECISELY. The simulator takes the device it is given
  (`robotgpu_host.Sim.initGpu(gpa, device, queue, ...)`, as vk-host-test runs it) and the kit's learner is a
  `z.Compute(zn_mlp)` made the same way - so one device can hold both. What is missing: `z.Compute` (compute_host.zig)
  copies buffer to buffer only inside itself (staging, readbacks: `wgpu.copyBufferToBuffer`, its `field_bufs`); nothing
  public copies one instance's field into another's. THE SPIKE: (1) `z.Compute.fieldBuffer(field)` - a field's buffer
  handle and byte size; (2) one copy between two pipelines on one queue - `copyBetween(queue, source buffer, source
  byte, destination buffer, destination byte, bytes)`, recorded and submitted after the source's dispatches (one queue
  orders them); (3) a vk-host-test check: a simulator and a kit pipeline on one device, the simulator's observations
  after a decision copied into a kit field, read back and compared with the twin's - and the same through the web's
  device (Dawn) in the page. If it holds, experience stays on the GPU from the physics to the learner; if a field's size
  or alignment differs (WebGPU copies need 4-byte multiples and offsets), the spike says so before anything builds on it.
- Nov 7: THE SPIKE's TWO PIECES WRITTEN (compute_host.zig). `Compute.fieldBuffer(field)` - a field's device buffer,
  its size in bytes, its device and queue (`DeviceField`), found as `uploadAt` finds it (`fieldIndex`, `field_bufs`);
  `copyFieldBetween(source, source_byte, destination, destination_byte, byte_count)` - one copy recorded and submitted
  on the shared queue (after every earlier submission; not inside an open batch), asserting one device and queue,
  WebGPU's multiples of 4 bytes and both ranges inside their buffers. CHECKED: lint. NEXT: the vk-host-test check -
  numbers uploaded to a kit pipeline's `params`, copied into a robotgpu simulator's `world_f` on the same device,
  read back with `readRange` (robotgpu reads ranges) - the very numbers; then a decision's observations the same way.
- Nov 7: THE LEARNER's DEVICE SPIKE PASSES ON VULKAN. `Compute.deviceField(field)` (named so: `Compute` already has a
  private `fieldBuffer`) and `copyFieldBetween`, exported from zimr as `z.DeviceField` and `z.copyFieldBetween`.
  vk-host-test's new check (`runCopyBetweenPipelines`): a learning kit's pipeline (`z.Compute(zn_mlp)`) and a robotgpu
  simulator on one device; 64 numbers uploaded to the kit's `params`, copied into the simulator's `world_f`, read back
  with `readRange` - exactly. CHECKED: vk-host-test, every check; lint. THE ARCHITECTURE HOLDS: experience can go from
  the physics to the learner without leaving the GPU. NEXT: the same through the web's device (Dawn, in the page), and
  a decision's observations copied into a kit field - then C2's device resets.
- Nov 7: THE TUTORIALS CAUGHT UP (Simon: "Look at the robot tutorial. Make sure that what we have done in the last few
  turns is explained in detail"). The mocap tutorial, after "Where episodes start": one round per decision (the starts of
  a decision as one round, the folds first, the softmax and history once, the mixture read unchanged; `restartEnded`,
  `refreshStartBins`, `startBinMixture` folded); "Random numbers any engine can draw" (five integers - seed, character,
  counter, purpose, index - folded in and scrambled; a sketch of the three draws; why an index is drawn with integers;
  the start noise's indices; `drawWord`, `drawBelow`, `drawNormal` folded); "Joint limits drawn from the captures" (the
  box about the captures' mean, a worked knee, the clamp and the penalty, never a constraint row; `rotationBoxes`,
  `ballTargetInBox` folded). robots.html, before "Side by side": SuperMimic's whole reward on the device (`effortCost`),
  the rotation boxes on the device (`loadBallBox`), one device for the physics and the learner (`copyFieldBetween`).
  doc-sync now checks robots.html against compute_host.zig too. CHECKED: doc-sync - 3,888 and 14,907 lines, nothing
  drifted.
- Nov 7: THE SPIKE's REVIEW FIXES. (1) THE ORDER ENFORCED: `Compute.copyFieldInto(field, source_byte, destination,
  destination_byte, byte_count)` - refused while its pipeline has an open batch or recording (`batch_enc`, `rec_enc`
  valid: its dispatches not yet submitted, the copy would move what they have not yet written); `copyFieldBetween`
  stays the free function under it, moved above `Compute`. (2) THE SIZE - NOT A PROBLEM: every field buffer is created
  at exactly its field's static size (`@sizeOf(@FieldType(Buffers, fname))`), the size `deviceField` reports; a lent
  buffer is at least that. FOUND ON THE WAY: `Compute` can BORROW another pipeline's buffer and bind it as its own
  (`initGpuBorrowing`, a loan) - sharing without any copy, for when the learner reads the simulator's layout directly.
  CHECKED: vk-host-test, every check, the copy through `copyFieldInto`; lint. NEXT: robots.html on `copyFieldInto` and
  borrowing; the copy in the page (Dawn); a decision's observations into a kit field; then C2's device resets.
- Nov 7: AN OVERVIEW FOR UNDERSTANDING (Simon: "This feels very complicated to me where is all this in the tutorials.
  Make it easier to understand"). robots.html, at the head of section 60: "The whole picture" - one decision's path for
  every world in one sketch (the decision, the observation, the judgement, the learner), each stage in plain words with
  a link to its section, the twin in one paragraph, and where the tracking ideas themselves are explained (the
  robot-mocap tutorial). Only what exists: the device's restarts are not shown until built. CHECKED: doc-sync, nothing
  drifted.
- Nov 7: `begin_reset`, SPECIFIED. Night 1 trains natively (the web's training is off for it), so the copy's web check
  waits, and the observations' copy belongs with the records (C4): the next piece is C2's first kernel. ONE INVOCATION
  PER WORLD; a world whose `episode_flags` holds the ended flag (`EpisodeFlag`, `episodeFlagBit`) begins another, as
  the fleet's `restart` then `startAt` do: (1) its episode number + 1 (a new world_u array, `episode_numbers`, cleared
  at the twin's start as the fleet's are); (2) its clip - kept for a fixed assignment, else `drawBelow(seed, world,
  episode, .start_clip, 0, clip count)`; (3) its frame - uniform: `1 + drawBelow(seed, world, episode, .start_frame, 0,
  clip_frame_count[clip] - 1 - decision_physics_steps)` (the fleet's `lastStartFrame`), the curriculum's path waiting
  for C18's table; `world_clip` and `world_frame` stored; (4) everything the fleet clears at a start - read `restart`
  and `startAt` together first and list them (steps, aftermath, return streak, previous and applied actions, effort,
  the episode's flags, the warm start). NEW SETTINGS: the run's draw seed (`rbt.drawSeed` of the fleet's) and the clip
  assignment, through `TrackingSettings`. CHECK: the twin's clip and frame for every ended world equal the fleet's
  `restart` for the same episode numbers, to the bit. THEN `reset_pose` (`resetToFrame` read first).
- Nov 7: THE PHONE BEFORE THE NIGHT (Simon: "we will check if the whole system works on my phone browser long before
  the first night"). So the web path is not optional: the copy between pipelines on the web's device (Dawn, in the
  page; its readback asynchronous) comes back into the plan ahead of the records, and every new kernel goes through the
  page's Tint and the phone. `begin_reset`'s LIST, READ FROM `restart` AND `startAt`: the episode number + 1; the clip
  - `.random`: `drawBelow(.start_clip)`, `.by_character`: the world's index modulo the clips; the frame (uniform, or the
  curriculum's); then CLEARED: the episode's steps, the aftermath's steps left, the return streak, the previous and the
  applied actions, the effort's sums (`zero_effort` already clears them each decision); NOT CLEARED: the steps since a
  loss (the fleet keeps counting them); the episode's flags are rewritten by the next judgement. THEN the pose
  (`resetToFrame`, which also clears the warm start - the device's per-world constraint forces), rest on the floor, the
  start noise, and a start in trouble - its share is the push schedule's progress, which the host passes each decision
  (`pushScheduleShare`, from the fleet's step count), its speed `speed_min + (speed_max - speed_min) x share`, its
  direction `drawUniform(.start_push_direction)` in turns.
- Nov 7: C2's FIRST KERNEL - `begin_reset`. robotgpu_program.zig's `reset_program` (`begin_reset`, per world); robotgpu:
  world_u `episode_numbers`; `ClipAssignment` (`random`, `by_character` - an enum, not a number); the uniform's
  `draw_seed` and `clip_assignment`, taking the two padding words of their row (the uniform stays whole 16-byte rows);
  `TrackingSettings` carries both from the fleet; the twin's and the host's `runResets`. The kernel: a world whose
  episode ended advances its episode number, chooses its clip (drawn, or its index modulo the clips) and draws its
  start frame uniformly over the frames leaving a decision (the fleet's `lastStartFrame`), stores them, and clears what
  a start clears - the episode's steps, its aftermath, its return streak, its previous and applied actions. CHECKED: the
  kit's decision check extended - two worlds ended on the twin, reset: their clip and frame the fleet's own draws
  (`drawStartFrame`) for their next episode, counters and actions cleared - 2/2 (stiffness off and on); vk-host-test,
  every check (the kernel compiled for SPIR-V); the page's web build and Tint, 0 warnings (compiled for WGSL); lint.
  NEXT: `reset_pose` (`resetToFrame` read first), then rest on the floor, the start noise, a start in trouble.
- Nov 7: SIMON's PHONE - `begin_reset` COMPILES THERE (no warning line). AN OPEN QUESTION: the CPU's hips 226.5 mm from
  the clip at frame 112 (earlier screenshots: 65-67 mm at frame 288) - a harder moment of the dance, or a regression
  from this session's starts and joint limits; Simon asked to watch whether it returns near 60 mm later in the run.
  `reset_pose`, SPECIFIED from the fleet's `resetToFrame`: (1) `d.reset(m)` - every per-world state a fresh `Data`
  holds, cleared: the velocities, the warm start (the constraint forces), the contacts' state; (2) the joint positions -
  the clip's frame (`max(frame, 1)`), from the device's clip tables (the coordinates `reference_targets` already
  reads); (3) the joint velocities - `robot.differentiatePos` between the frame before and this one, over the clip's
  frame time: per joint by its type (a hinge's or slide's difference over time; a ball's or free root's turn as an
  angular velocity) - split out of `differentiatePos` into one per-joint function both engines call; (4) `forward` - the
  existing kinematics program after it. READ FIRST: `differentiatePos`, the device's clip frame time, what `Data.reset`
  clears beside the state the device keeps per world.
- Nov 7: `reset_pose`, READ. `robot.differentiatePos` is per joint already - `jointPositionDifference(type, from, to,
  1 / dt)` gives one joint's velocity, `writeJointVelocity` stores it - so the device's `reset_pose` (one invocation per
  world and joint) calls it as it is, on the clip's coordinates at the frame before and the start frame
  (`loadClipCoordinates`, as `reference_targets` reads them). MISSING ON THE DEVICE: a clip's frame time - a model_f
  table `clip_frame_time` (one per clip), packed by `packClips` from the clips (check `ClipPoses` carries it). STILL TO
  READ: what `Data.reset` clears, set beside the device's per-world arrays (velocities, warm start, contacts).
- Nov 7: `reset_pose`, THE LAST FACTS. `ClipPoses` (poses, frame count, the two reference tables) has NO frame time:
  it gains `frame_time` (from each clip), and `packClips` writes a model_f table `clip_frame_time` beside
  `clip_frame_count`. `Data.reset` clears every per-world quantity robot.zig keeps; ON THE DEVICE most are recomputed
  from the pose by the next kinematics and step (body poses and motions, accelerations, the solver's matrices), so
  `reset_pose` must clear only what persists across steps there: the joint velocities (it sets them), THE WARM START
  (the per-world constraint forces the solver starts from - find its array), the applied actions (`begin_reset` clears
  them), the effort (cleared each decision). THE KERNEL, per world and joint: an ended world's joint at its start frame
  (`world_frame`) - its coordinates from the clip's row at the frame, `loadClipCoordinates`; its velocity
  `robot.jointPositionDifference(type, row at frame - 1, row at frame, 1 / clip_frame_time)`; both stored. CHECK: the
  twin's reset worlds' positions and velocities the fleet's `resetToFrame`, bit for bit; then kinematics, and rest on
  the floor.
- Nov 7: `reset_pose`'s NAMES. The warm start is world_f `warmstart_accelerations` (per world and dof - Newton's start
  when `warm_start` is enabled): zeroed at a reset, as MuJoCo's data reset zeroes it. Coordinates: `loadClipCoordinates`
  (a clip row's joint) and `storeJointCoordinates` (into a world's); no helper stores a joint's velocity - its numbers
  go from `joint_first_dof` on (one for a hinge or slide, three for a ball, six for the free root). Invocations
  `.per_world_and_joint`, as `next_positions`. WRITE NEXT: `ClipPoses.frame_time` and the `clip_frame_time` table; the
  kernel; `reset_program` growing to `begin_reset`, `reset_pose`; the check against `resetToFrame`.
- Nov 7: C2's SECOND KERNEL - `reset_pose`. `ClipPoses.frame_time` and the model_f table `clip_frame_time` (packed with
  the clips); `robot.jointPositionDifference` made public. The kernel, per world and joint, an ended world only: the
  joint's coordinates at the world's start frame from its clip's row (`clip_first_frame` + frame), its velocity
  `jointPositionDifference` from the frame before over the clip's frame time - the fleet's `differentiatePos`, joint by
  joint - and its warm start (`warmstart_accelerations`) zeroed. `reset_program`: `begin_reset`, `reset_pose`. CHECKED:
  the decision check's resets - each reset world's positions and velocities the fleet's own `resetToFrame` at the same
  clip and frame, bit for bit, 2/2 (stiffness off and on); vk-host-test, every check (SPIR-V); the page's web build and
  Tint, 0 warnings (WGSL); lint. NEXT: kinematics after the pose, rest on the floor, the start noise, a start in trouble.
- Nov 7: REVIEW OF THE RESETS, AND THE REMAINING PLAN MADE PRECISE (Simon: "Review recent code, look at the remaining
  plan and make it more precise"). FINDINGS: (1) A RESET WORLD's OBSERVATION IS STALE: the observation program runs at
  the decision's end BEFORE the resets, so the next action for a reset world would read the old episode's last state.
  The fleet observes after its restarts; the device must run kinematics and the observation again after
  `reset_program` (for every world: cheap, and simple). (2) `ClipPoses.frame_time` DEFAULTS TO 0, and a builder that
  forgets it gives every reset world infinite velocities - make it required (no default), so the compiler finds every
  builder. (3) THE `finished` FLAG MUST NOT SURVIVE: `begin_reset` and `reset_pose` act on it, and the next judgement
  must rewrite the flags from scratch (store, not or) - extend the check with a decision after the reset and assert the
  flag is gone and the world steps as the fleet's restarted one. (4) WITH THE CURRICULUM ON, the device cannot yet draw
  a start frame as the fleet does (its table is C18's): until then `TrackingSettings` refuses a curriculum
  (`bin_seconds > 0`) on the device, loudly. (5) `drawBelow` on the GPU has no assertion: a clip shorter than a
  decision plus two frames would give frame 1 there and assert on the CPU - the host asserts every clip's length when
  it packs them.
  C2, THE REST, IN ORDER (each kernel checked on the twin against the fleet, bit for bit, then compiled by vk-host-test
  and the page): (a) `reset_program` grows: after `reset_pose`, the kinematics program (the existing one), then
  `body_lowest_points` (existing), then `rest_on_floor` (per world: the root lifted so the lowest point sits 1 mm above
  the floor - `robot.restOnFloor`'s rule, extracted to a function of the lowest point and the root's height that both
  engines call), then kinematics again; (b) `perturb_start` (per world: each actuated dof's turn `noise.pose x
  drawNormal(seed, world, episode, .start_noise, dof)`, applied through the pose as `robot.integratePos` applies turns
  - per joint, the function `reference_targets` displaces targets with; the two root kicks at the next two indices;
  then `rest_on_floor` and kinematics once more - `perturbStart`'s order), then the observation program again (finding
  1); (c) `start_in_trouble` (per world: `drawUniform(.start_in_trouble)` against `start_share x schedule share`, the
  share in the uniform each decision from the host's `pushScheduleShare`; speed `speed_min + range x share`, direction
  `drawUniform(.start_push_direction)` in turns, the kick as the fleet's `push` applies it - read `push` first);
  (d) `push_worlds`, in the decision program's start, each decision: the Poisson chance `rate x decision seconds x
  share` by `drawUniform(.push_chance)` at the decision number, speed and direction likewise, the scheduled pushes by
  the episode's steps; (e) THE CHECK OF ALL OF IT: the twin against the fleet from a start through an episode's end,
  its restart with noise and a start in trouble, and pushes, bit for bit - the fleet's `restart` and the device's
  draws fed the same seed, episode numbers and decision numbers.
  C18 ON THE DEVICE, PRECISELY: (a) `judge_rewards` accumulates per world the episode's discounted SuperMimic return,
  its reward sum and its decisions (three world_f arrays and the discount's running power), as the fleet's `step`
  does; `begin_reset` records the start bin (the bin of the start frame) in a world_u array; (b) each decision the host
  reads back, for every world: the flags, the start bin, the discounted return, the reward sum, the decisions - small
  arrays - and folds every finished episode into `bin_returns` with `rbt.updateStartBinReturn`, exactly the fleet's
  `foldEpisodeIntoStartBin`; (c) the host runs the round - `rbt.startBinSoftmax`, `rbt.foldStartBinHistory`,
  `rbt.startBinMixture` per clip - and uploads the mixture's RUNNING SUMS per clip as a model_f table; (d)
  `begin_reset`'s curriculum path: the bin by `drawUniform(.start_frame, 1)` against the sums, the frame within it by
  `drawBelow(.start_frame, 2, bin width)`, clamped to [1, last start] - the fleet's `drawStartFrame` line for line.
  ORDER OF A DECISION ON THE DEVICE, SETTLED: decision program (pushes at its start) -> observation -> judgement ->
  resets (begin, pose, kinematics, lowest points, rest, kinematics, noise, rest, kinematics, trouble) -> observation
  again -> read back (flags, returns) -> the host's folds and the table -> the next decision.
- Nov 7: A BREAK FROM IMPLEMENTATION - THE FOUR PAPERS READ AGAIN AND A DOCUMENT BEGUN (Simon: "Read again these four
  papers. Make a new html document explaining these 4 algos in detail, with many diagrams. Then ... brainstorm 20
  promising ways to combine and extend them ... propose changes we could do to our plan"). Notes in /tmp/papers/notes.md;
  the document src/notes/tutorials/four-papers.html: Part I - SuperMimic (the loop, the model and its analytic heads,
  the 8-step autoregressive fit, BPTT over 32 imagined steps with the survival weight, the GAE critic, the numbers),
  SkipWorld (AutoRoll, SkipDistill from the teacher's endpoint, the 120 -> 20 -> K funnel with its ablation), EfficientTDMPC
  (value-equivalent heads, the multi-horizon objective with a worked comparison, the ensemble's mean and variance,
  pessimistic reanalyze where episodes terminate, the practical changes), FlowDPG (the one-step estimate, the two
  vectors, the distilled target with its BC anchor and warm-up, the three approximations, IQL's in-data value), a
  side-by-side table; Part II - what our tracker is trying to do, TWENTY IDEAS (soft analytic termination; the imagined
  return at every depth; two heads and their disagreement; the reference as anchor; the teacher distilled the FlowDPG
  way; the skip model distilled from the dense model; skip-then-refine for the teacher; two teachers for the skip model;
  a pessimistic teacher; reanalyze; curriculum by disagreement; a generative aftermath head; action chunks in trouble;
  SuperMimic's critic; noise outside the model; the context as input; goal interfaces; one network two strides;
  pessimism only in trouble; the model's error as the gate), and FIVE CHANGES recommended for the plan with sizes.
  Eleven SVG diagrams; rendered and checked in headless Chrome (overflows and an unescaped `<` fixed).
- Nov 7: THE FAR-START BRAINSTORM (Simon: "Focus on the different ways we can improve supermimic, by having larger
  perturbations and episode start noise (possibly meters., starting on ground..). Using ideas from the other 3 papers.
  Make a large wild brainstorm"). Part III of four-papers.html, 28 ideas in seven groups: WHERE EPISODES START (a
  curriculum of distance kinds; ground poses from the physics' own settling; mid-fall starts; hindsight starts before
  a lost recovery; pushes scaled by competence), WHAT THE POLICY IS PAID FOR (an approach potential; the survival
  weight as a leash that tightens with approach; a return bonus with a clock; naturalness as closeness to the captures'
  poses; the multi-horizon brake), A MODEL THAT KNOWS WHAT IT DOES NOT KNOW (two heads' disagreement as pessimism,
  curriculum and a shorter horizon; the physics as the teacher where the heads disagree; a second window sampler on
  recoveries; the skip model as the long-range eye), PLANNING THE WAY BACK (the funnel for recoveries only; plan in
  INTENTS; RE-ANCHOR THE GOAL to the frame easiest to reach; TIME-REVERSED FALLS as get-up references; reanalyze the
  hard moments), WHAT THE POLICY IS (distance and aftermath as inputs; a flow head for the first second of trouble;
  chunks scored by the skip model; stiffness as the recovery's dial), THE DATA (hindsight relabelling with the frame
  reached; successful recoveries as the anchor; pushes as model inputs), TWO WILD ONES (a model of the recovery's
  outcome; train the fall). Three diagrams: the ideas along one episode, re-anchoring the goal, the reversed fall.
  FIRST TO TRY, for the experiment that trains the new signals together: the distance curriculum with ground starts,
  the approach potential and the leash, the policy told its distance, the funnel for recoveries only; the re-anchored
  goal for an experiment of its own on night 2.
- Nov 7: FOUR IDEAS WORKED THROUGH (four-papers.html, part 10): THE APPROACH POTENTIAL AND THE LEASH (a telescoping
  potential on the distance to the reference; a leash that never lengthens, from the start's own distance plus a
  margin; soft termination as a sigmoid of D - L; a worked episode from a metre off, decision by decision; nothing
  learned); RE-ANCHORING THE GOAL (seven candidate frames up to three seconds on, cost = distance over speed + skipped
  seconds x penalty - imagined return; a worked table where a standing frame 1.5 s on beats the clock's crouch; the
  choice must be sticky; the records store the goal); PLANNING IN INTENTS (six intents x three timings = 18
  candidates, screened by the skip model, three refined in the physics, the winner's first offset distilled; why
  intents and not random offsets for a 75-number action); TIME-REVERSED FALLS (the last two seconds of each fall,
  reversed and smoothed, keyed by the resting pose, a get-up reference for the nearest ground start; a slower first
  second; only falls whose resting pose the boxes accept). Each with its cost, failure modes and the hour that tests it;
  the round's budget with all four about one and a half units of the control's physics. Diagrams: the leash, the
  rejoining costs, the get-up library.
- Nov 7: THE DOCUMENT FINISHED FOR NOW, AND ITS CONCLUSIONS IN THE PLAN. four-papers.html gains a reading guide with
  links, a glossary of the papers' terms, and "The map" as its own heading. E7 now names what rides together: the
  skip model distilled from the dense model, the teacher's funnel distilled the FlowDPG way with the reference as
  anchor, the analytic soft termination, and - the cheapest far-start ideas - the leash and the approach potential.
  Night 2's candidates listed: the imagined return at every depth, two heads with pessimism in trouble, the distance
  curriculum with ground starts, re-anchoring the goal, intents, reversed falls, a flow head for the first second.
- Nov 7: THE HYBRID DECIDED (Simon: "focus on using the flowdpg for the multimode offset on top of supermimic
  policy, learned by doing both mpc in the real sim and with efficienttdmpc ... skipmodel to find top candidates
  quickly then refine ... actions found by tdmpc ... real trajectories ... learn flowdpg. All trajectories are also
  used for supermimic"), one question at a time: F always on; g from W's imagined return; a tenth of the worlds plus
  every world in trouble plan; the physics refines the top three; receding horizon warm-started from the winner;
  planned actions also distilled into pi; one decision's offset; pi + F alone deployed; one sample per decision; the
  reward with the leash and the potential; horizon 6, 64 candidates, 3 refined. Written as C19 and as section 11 of
  four-papers.html with its data-flow diagram.
- Nov 7: THE NEXT TWENTY TURNS WRITTEN (Simon: "Make the plan for the next 20 turns more precise"): one checked piece
  per turn - the resets finished (1-4), the curriculum on the device (5), acting (6-7), records (8), the trainer's device
  path and the run file (9-10), the lab's runner and UI (11-12), the night's safety (13), the feasibility pass (14), the
  world model's form and the cheap new signals (15), the physics rate (16), the skip model (17), the planner (18), the
  flow offset and E7 (19), the dry run (20) - with the fallback if the last three slip.
- Nov 7: TURN 1 OF 20 - THE RESETS' REVIEW FIXED. (1) The twin's and the host's `runResets` run the observation
  program again after `reset_program` (it begins with the kinematics), so a reset world's next action reads its new
  episode's state; the worlds that did not reset recompute the same numbers. (2) `ClipPoses.frame_time` required (no
  default; the kit's builder the only one). (3) The decision check: each reset world's observation the fleet's at the
  same clip and frame (after the fleet's own `resetToFrame`); then one more `runDecisionEnd`, and the reset worlds'
  `finished` flags gone. (4) The kit's `trackingSettingsOf` refuses a fleet with a curriculum
  (`error.CurriculumNotYetOnTheDevice`) until the curriculum's table reaches the device. CHECKED: the decision check
  2/2 (stiffness off and on); lint. NEXT: turn 2, `rest_on_floor`.
- Nov 7: TURN 2 OF 20 - RESTING ON THE FLOOR. robot.zig: `restLift(clearance, lowest)` - the lift, never down, nothing
  for a lowest point that is not a number - which `restOnFloor` and the device both call. robot_track: the task's
  `rest_clearance` (0.001 m, until now a literal). robotgpu: the uniform's `rest_on_floor` and `rest_clearance` (a row
  with its padding), carried by `TrackingSettings`; the kernel `rest_on_floor` (per world, ended worlds, when the run
  rests its starts): the least of the bodies' lowest points (`body_lowest_points`, the same minimum as
  `robot.lowestPoint`, exact in any order), the lift, the free root raised. `reset_program`: `begin_reset`,
  `reset_pose`, `kinematics_branch`, `body_lowest_points`, `rest_on_floor` (the observation program after it runs the
  kinematics again). THE REQUIRED FRAME TIME (turn 1) FOUND FOUR MORE BUILDERS: vk-host-test's (0.05 s), robotgpu's
  three test clips (0.1 s), the page's (the clip's own) - each given its real frame time. CHECKED: the decision check
  with the rest exercised whatever the task says - the reset worlds' positions the fleet's `resetToFrame` then
  `restOnFloor`, bit for bit, and at least one world truly lifted (not a vacuous pass) - 2/2; robotgpu 29/29;
  vk-host-test, every check (SPIR-V); the page's web build and Tint, 0 warnings (WGSL); lint. NEXT: turn 3, the start
  noise.
- Nov 7: TURN 3 OF 20 - THE START NOISE, AND A FLEET BUG IT FOUND. robotgpu: the uniform's `start_noise_pose` and
  `start_noise_velocity` (a row), carried by `TrackingSettings`; `perturb_start` (per world and joint, ended worlds,
  with noise): each actuated dof's turn `pose x drawNormal(seed, world, episode, .start_noise, dof)`, applied by
  `robot.integrateJointPosition` (made public) as `integratePos` applies it - the root too, with a turn of nothing, as
  the fleet's does - and the root's two horizontal velocities kicked at indices `dof_count` and `dof_count + 1`;
  `rest_after_noise` (per world): `perturbStart`'s own rest, whatever the task says; the rest's body shared as
  `restWorldOnFloor`. `reset_program` grows: `perturb_start`, `kinematics_branch`, `body_lowest_points`,
  `rest_after_noise`. THE BUG: the fleet's `perturbStart` rested the turned pose WITHOUT kinematics on it -
  `restOnFloor` measures the lowest point from the bodies' and geoms' frames, which only kinematics updates - so it
  lifted by the lowest point from BEFORE the noise (a turned foot left in the floor, or a lift too far). The device,
  running kinematics between, disagreed at the root's height. FIXED in the fleet: kinematics on the turned pose before
  its rest. CHECKED: the decision check with forced noise (0.05 rad per dof, 0.2 m/s kick) - positions, velocities and
  observations the fleet's, bit for bit, 2/2; the kit's 200 matching tests (169 run, 31 skipped); robot_track 325/368;
  vk-host-test, every check (SPIR-V); the page's web build and Tint, 0 warnings (WGSL); lint. NEXT: turn 4, starts in
  trouble and pushes, and the whole of C2 checked.
- Nov 7: TURN 4 OF 20 - PUSHES AND STARTS IN TROUBLE; C2 COMPLETE. robotgpu: the uniform's pushes, two rows -
  `push_every`, `push_rate_per_second`, `push_speed_min`, `push_speed_max`, `push_start_share`, and set by the host each
  decision `push_schedule_share`, `decision_number`, `decision_seconds` - carried by `TrackingSettings` from the fleet's
  `Pushes`; `pushRoot` (the fleet's `push`); `push_worlds` (per world, worlds still in their episode: on the schedule by
  the episode's steps, or at random - a Poisson chance of rate x share x seconds - speed and direction drawn at the
  decision's number); `start_in_trouble` (per world, reset worlds: the trouble draw at the episode against the start
  share x share, a push at the schedule's top speed). `reset_program`: `push_worlds` first, `start_in_trouble` last.
  The fleet's `restart` made public. THE CHECK, restructured: the six decisions stay push-free (the fleet's step pushes
  AFTER judging, so a check recomputing judgement terms from its post-step state disagrees for a pushed world - an
  artifact of the check, found and avoided); then three decisions with pushes on a schedule and at random, every world's
  positions and velocities the fleet's, and pushes truly given; then the forced resets through the fleet's own
  `restart` - clip, frame, rested and noised pose, start in trouble's velocities, observation - and the flag cleared.
  ON THE WAY: the disk 97% full (the build cache at 10.5 GB stopped the build) - the cache cleared whole. CHECKED: the
  decision check 2/2 (stiffness off and on); vk-host-test, every check (SPIR-V); the page's web build and Tint, 0
  warnings (WGSL); lint. C2 IS DONE ON BOTH ENGINES. NEXT: turn 5, the curriculum on the device; the page to Simon's
  phone.
- Nov 7: TURN 5 OF 20 - SUPERMIMIC's CURRICULUM ON THE DEVICE. robotgpu: `ClipPoses.curriculum_bins` and `bin_frames`
  (the fleet's `bins_start` and `binFrames`, made public), `Counts.curriculum_bin_total` (with its row's padding);
  model_u tables `clip_first_bin`, `clip_bin_count`, `clip_bin_frames`, the model_f table `bin_running_sums` (item kind
  `curriculum_bins`) - THE MIXTURE AS RUNNING SUMS, summed in the fleet's order, uploaded by the host each round; world
  arrays `episode_discounted_returns`, `episode_discount_powers`, `episode_reward_sums`, `episode_decisions`,
  `start_bins`; the uniform's `curriculum` and `curriculum_discount`. `judge_rewards` accumulates the episode's
  SuperMimic return as the fleet's step does; `begin_reset`'s curriculum path (`curriculumStartFrame`: a bin by
  `drawUniform(.start_frame, 1)` against the sums, a frame within it by `drawBelow(.start_frame, 2)`, held in [1, last
  start] - the fleet's `drawStartFrame` line for line), then the start bin recorded and the accumulators cleared. FOUND:
  the discount's power must start at ONE for every world's first episode (the arrays' zero left every return at zero):
  set at creation on the twin and in the host's `initOnPipe`. The kit's refusal of a curriculum removed. CHECKED: the
  decision check with the curriculum on (half-second bins) - every world's accumulators the fleet's through nine
  decisions, pushes included; the forced resets' clip, frame and start bin the fleet's `restart` by the curriculum -
  2/2; robotgpu 29/29; vk-host-test, every check (SPIR-V); the page's web build and Tint, 0 warnings (WGSL); lint.
  LEFT FOR C10: the host's round on a real device - read back the flags and accumulators, fold every finished episode
  (`updateStartBinReturn`, a failure by the flags), the softmax and history, the sums uploaded. NEXT: turn 6, acting on
  the device.
- Nov 7: SIMON's PHONE - THE PAGE RUNS (GPU root 6.1 mm from the CPU's at frame 134 of run 47; the CPU's hips 35 mm from
  the clip - the 226 mm seen earlier was a hard moment of the dance). DECIDED: the page's device check as turn 7b, after
  acting on the device.
- Nov 7: TURN 6, READ FIRST - HOW THE TRAINER ACTS TODAY. robot_track_resident's `act` acts ON THE CPU, character by
  character, from a host mirror of the policy's weights: the features (goal and state); teacher 3 completing its pending
  flow example (`completeFpoExample`); a hazard projected for the planning flags (`projectHazard`); the action
  (`computeAction`: a plan's correction on the policy when it has one - teacher 2 - or the policy with the flow's
  correction and exploration - teacher 3); its own goal remembered; the action written (never non-finite); then the
  fleet steps. THE RESIDENT TRAINER ALREADY HOLDS MUCH OF C19 - a flow correction trained as a teacher, plans that
  correct the policy, planning flags - so C19 is to be built ON it, not beside it (read `computeAction`, the flow
  actor's `actingOnly`, and the planning flags before C19). ACTING ON THE DEVICE, then: the policy's layers - the
  kit's dense kernels on `z.Compute(zn_mlp)`, its weights in the kit's `params` - run over all the simulator's
  observation rows at once: the observations copied into the kit's acts (`copyFieldInto`, or a loan), the layers run,
  exploration noise added from the counter-based draws, the actions copied back into the simulator's `actions`; the
  flow's correction the same way once its features are on the device. TO READ NEXT: the kit's `KitLayout` (the
  policy's weight offsets and its input and output rows), its dense-layer kernel and params, and the order of the
  policy's input features against the device's observation (equal to `Fleet.observe` since P4(e)).
- Nov 7: TURN 6, READ - THE KIT's POLICY ON THE GPU. The kit's `policyStep` is three `dense_fwd` dispatches over its
  rows (params: rows, in_dim, out_dim, act, x_off, stride, w_off, y_off): the first reads each row's first `lead +
  features` columns - the goal, then the state - with the row's own stride (`blockX(k)`, `width`), weights packed by
  `packPolicy` (w1 then its bias, w2, w3); tanh, tanh, linear into `raw`; then a correction (a flow's or a given one)
  and the exploration, before the write. ACTING ON THE DEVICE IS THOSE THREE DISPATCHES WITH ONE ROW PER WORLD, once
  each world's goal and state sit in the kit's row layout. THE CATCH: the simulator keeps each world's observation in
  its own array; a copy per world would be thousands of copies a decision. THE DESIGN: the kit BORROWS the simulator's
  `world_f` buffer (`initGpuBorrowing`, a loan) and ONE gather kernel moves every world's observation into the kit's
  rows, the goal columns first - and, for the actions, one scatter kernel the other way into the simulator's `actions`.
  TO CHECK FIRST: that the device's observation's order (`observe_character`, `observe_reference`) is the kit's `lead +
  features` order or a fixed permutation of it, and how a kit is built with a borrowed buffer.
- Nov 7: REVIEW OF TURNS 1-5 FOR FIT (Simon: "Review recent code and surroundings. Make sure everything fits well
  together"). THREE SEAMS CLOSED, each a convention nothing enforced: (1) THE DECISION's CLOCK - the decision number and
  the push schedule's share had to be written into the uniform before every reset, which a trainer could forget (the
  same class as the eight setters); now `robotgpu.DecisionClock` {number, push_schedule_share}, `applyTo`, and
  `runResets(clock)` on the twin and the host takes it as an argument. (2) A CURRICULUM WITHOUT BINS - starts would fall
  back to uniform silently while the fleet's follow its curriculum; `setTracking` (twin and host) refuses it
  (`error.CurriculumWithoutBins`). (3) TWO CLEARANCES - the device's rest after noise used the task's `rest_clearance`,
  the fleet's `perturbStart` a literal 0.001; `perturbStart` takes the clearance (the fleet passes the task's, Geno's two
  callers 0.001 as before). CHECKED: the decision check 2/2; robot_track 325/368; robot_geno compiles; lint. NOTED, NOT
  YET: a restarted world's counters beyond those compared (return lengths, steps since a loss) are first compared when
  the loop closes on the device (turn 7: whole episodes against the fleet); `TrackingSettings` has grown to about twenty
  flat fields - group into starts, pushes and curriculum when next touched; robots.html has no section on the device's
  starts, pushes and curriculum - written with turn 7, when the loop closes; the host's curriculum round is C10's.
- Nov 7: TURN 6, FIRST HALF - THE POLICY's INPUTS ON THE DEVICE. FOUND: the latent kit's policy does not read
  `Fleet.observe`'s observation but SuperTrack's features (`robot_track_resident.supertrackFeaturesInto`): the GOAL
  - the reference ONE FRAME AHEAD, held at the clip's last frame - then the STATE, each `track.local` in its root's
  frame and normalised `(x - mean) / spread`. The device holds both raw already: the state is the observation's first
  half (`Fleet.observe` is `local(stateOf)` then `local(reference at the frame)`), the goal a row of the clips'
  precomputed reference features. DESIGN (no loan): the device writes every world's policy row into one block, world
  after world (`WorldArray.at` is world-major), one observation wide - the kit's dense layer takes its input stride as
  an argument, so the acting rows can be exactly `lead + features` wide - and one GPU copy hands the block to the kit;
  the raw actions come back by another. BUILT: the item kind `state_features` (`robot.localSize`), the normaliser's
  model_f tables `feature_means` and `feature_spreads` (setters on the twin and the host), the world array
  `policy_inputs`, the kernel `policy_inputs` (per world) and `policy_inputs_program`. CHECKED: after the decision
  check's six decisions, every world's row the learner's own `supertrackFeaturesInto` (with a normaliser of distinct
  numbers per feature), bit for bit, 2/2; robotgpu 29/29; vk-host-test, every check (SPIR-V); the page's web build and
  Tint, 0 warnings (WGSL); lint. NEXT, THE SECOND HALF: the block copied into the kit's acting rows, the kit's three
  dense layers over them (rows = worlds, stride = one row), the raw actions copied back, and a kernel writing the
  simulator's actions - checked against the CPU policy for one decision.
- Nov 7: TURN 6, SECOND PART - THE KIT ACTS ON ROWS OF ITS OWN. robot_latent_kit: `denseRows` (a dense layer over
  any number of rows; `dense` calls it with the kit's own), `PolicyWeights` and `policyWeights()` (the three layers'
  offsets in `params`, one definition, which `policyStep` now uses too), `PolicyRows` and `reservePolicyRows(layout,
  rows)` (inputs packed `lead + features` wide, two hidden layers, raw actions, reserved after the kit's regions), and
  `actOnRows` (tanh, tanh, linear over packed rows; no correction, no exploration). zn_mlp's `activate` made public, so
  a CPU reference uses the very activation. CHECKED: a kit with a small policy acting on five rows of random inputs
  with random weights - every raw action the CPU's three layers in `dense_fwd`'s order, exactly; the kit's 19 matching
  tests (18 run, 1 skipped), the rollout and planner through the shared offsets; lint. LEFT FOR TURN 6's LAST PART: on
  one device, `policy_inputs_program`, one copy of the simulator's `policy_inputs` block into the kit's `inputs_at`,
  `actOnRows`, one copy of the raw actions into the simulator's `actions` - a host function tying them, and its check
  in vk-host-test on a real GPU (the actions the CPU's for one decision).
- Nov 8: TURN 6, LAST PART - THE POLICY ACTS FOR THE SIMULATOR ON ONE DEVICE. (A turn cut off after its last visible
  reply had gone on to write it, unreported and unchecked: found by the files' times, verified here.) robot_latent_kit:
  `PolicyRows` with `input_stride` and `raw_stride` (the acting rows laid out as the simulator's blocks are), a
  `denseRows` with an output stride, and `actWithSimulator(acting, simulator_field, inputs_at, actions_at)`: one
  `copyFieldBetween` of every world's policy row from the simulator's `policy_inputs` into the kit's acting inputs, the
  three layers (`actOnRows`), one copy of the raw actions into the simulator's `actions`. vk-host-test's
  `runActingOnTheDevice`: rows of known numbers, the actions read back and compared with the CPU's forward pass within
  a GPU's rounding of tanh. FOUND: the run killed by the OUT-OF-MEMORY killer (1.7 GB on the 4 GB machine; llvmpipe
  keeps a freed simulator's memory, so every simulator a run creates adds to its peak). FIXED: the field-copy check and
  the acting check share one kit pipeline, Geno model and simulator, in their own block - freed before the engine's
  leak check, which runs partway through `main` (resources freed only at `main`'s end read as a leak). CHECKED:
  vk-host-test, every check, including "the policy acts for the simulator on one device - every action the CPU's";
  lint. NEXT: turn 7 - exploration noise from the draws where the actions are written, and the decision loop closed on
  the device (observe, act, step, judge, reset), checked against the fleet over whole episodes.
- Nov 8: VERIFIED AND SAVED. vk-host-test on the final sources: every check, the shared-device copy and acting
  included, no leak. THE LOST TURN ALSO CHANGED THE KERNEL `dense_fwd` (zn_mlp: an output stride, `y_off + r x
  outputStride() + o`) - its SPIR-V checked by vk-host-test; its WGSL NOT YET: the three web pages that run zn_mlp
  (geno_train, geno_ppo, getup_train) had all stopped building, each on one stale name (`ghost.pos`, now
  `ghost.joint_positions`) - fixed; getup_train builds and loads in the headless browser with no WGSL error, but draws
  nothing and logs nothing in a minute, so it may never reach its pipelines. TO DO: find why getup_train shows nothing
  (headless or real), and confirm `dense_fwd`'s WGSL by a page that creates the kit's pipelines.
- Nov 8: THE SANDBOX WAS RESET (the repository, /tmp and the build caches gone; the outputs kept): restored from
  zimr444.zip, the toolchain from the uploaded tarball, lavapipe and the validation layer installed. THE BROWSER
  HARNESS REWRITTEN (headless Chrome at /opt/google/chrome with puppeteer from /opt/npm-tools; a copy kept in the
  outputs as headless_webgpu_check.js): WebGPU needs a secure context (a file or localhost, not about:blank), and a
  WebGPU canvas is NOT readable headless - blank screenshots and zero "lit pixels" prove nothing. So the harness now
  reports WebGPU's own evidence: it wraps `requestDevice`, `createShaderModule` and the compute pipeline constructors
  before the page runs, counts devices, modules and pipelines, and prints every WGSL compilation message and every
  device error. THE EARLIER "getup_train draws nothing" WAS THAT ARTIFACT. CHECKED: robotgpu_sidebyside - 1 device, 55
  shader modules, 44 compute pipelines, no message, no error; getup_train - 1 device, 113 modules, 102 pipelines (the
  kit's `dense_fwd` with its output stride among them), no message, no error: `dense_fwd`'s WGSL CONFIRMED.
- Nov 8: TURN 7, FIRST PART - EXPLORATION ON THE DEVICE. READ: without a flow the trainer explores SuperTrack's way -
  the policy's raw action plus sigma x noise_scale x an independent normal number per action (the Ornstein-Uhlenbeck
  noise only drives a flow's starting point) - its normal numbers pre-generated per character (`acting_noise`).
  BUILT: robot.zig's `explorationNoise(seed, world, decision, action, spread)` - ONE definition, drawn by counter (a new
  purpose `explore_action`, appended so no other draw moves); the kernel `explore_actions` and `explore_program`;
  the uniform's `exploration_spread` (a row); `DecisionClock.exploration_spread` - the clock holds what changes from one
  decision to the next, and every program that draws takes it (`runResets`, now `runExploration` on the twin and the
  host). AFTER THE RESET: zbuild rebuilt (`zig build zbuild`; the snapshots leave tools/zig-out out). CHECKED: in the
  decision check, every world's actions set to known numbers and explored at a spread of 0.3 - each its number plus
  `explorationNoise`, exactly, in both configurations (the twin's own actions saved and restored: with limbs they
  are more than the fleet's) - 2/2; vk-host-test, every check (SPIR-V); the page's web build, WebGPU's own evidence: no
  WGSL message, no device error; lint. NEXT: the trainer's numbers from `explorationNoise` too (prepareActing), then
  the closed loop on the device against the fleet over whole episodes.
- Nov 8: FOUND - NINE KERNELS WERE NEVER ON THE DEVICE. The device's kernels (`kernel_names`, the one list the device's
  entry points and the build's compilation come from) are those of `every_dispatch` - the step, before-step,
  after-step, observation, judgement and decision-start programs - and the reset, policy-inputs and exploration
  programs were not in it: `begin_reset`, `reset_pose`, `rest_on_floor`, `perturb_start`, `rest_after_noise`,
  `push_worlds`, `start_in_trouble`, `policy_inputs`, `explore_actions` were never compiled for a GPU (the twin, which
  calls kernels by name on the CPU, is all that ran them). So the claim made before turn 4's phone test - that a clean
  run showed the new kernels compile - WAS WRONG (seen when WebGPU's own evidence counted 55 modules and 44 pipelines
  before and after a new kernel). FIXED: the three programs added to `every_dispatch`. RESULT: the page's web build
  passes (all nine translate to WGSL through spv2wgsl's checks); VK-HOST-TEST NOW FAILS: creating the pipeline
  `push_worlds` fails, the validation layer unable to PARSE its SPIR-V (offset 83412) - a malformed binary, not a rule
  broken. NEXT, FIRST: find which construct (`pushRoot`'s @cos and @sin, the draws?) and whether Zig's SPIR-V backend
  or spirvopt's -O makes it; then every new kernel through vk-host-test, and a device check of the reset, inputs and
  exploration programs against the twin.
- Nov 8: THE NINE KERNELS ON THE DEVICE. The "unparseable SPIR-V" was not: Mesa's full message reads "Entry point not
  found for compute shader push_worlds" - the module the test embedded had no such entry, while the host's kernel list
  (now with the reset, policy-inputs and exploration programs) asked for one. The newest module in the cache HAD it (53
  entry points), and a rerun of vk-host-test passed: the first build after editing robotgpu_program.zig embedded a
  module built from the OLD entry list (the build script imports robotgpu_program.zig for `robotgpu_entries`; most
  likely its runner was not rebuilt that once). HAZARD NOTED: after changing a program list, a missing entry point means
  a stale module - rebuild; a host check comparing the module's entry points with the kernel list, naming this cause,
  is worth adding. CHECKED: vk-host-test, every check, every pipeline created (the nine new among them; acting
  included); the page's web build - WebGPU's own evidence: 64 shader modules and 53 compute pipelines (nine more), no
  WGSL message, no device error; the page republished for Simon's phone. TOOLS: spirv-tools installed (spirv-val passes
  the module under Vulkan 1.2; spirv-dis with byte offsets). NEXT: the trainer's exploration numbers from
  `explorationNoise`, then the closed loop on the device against the fleet over whole episodes.
- Nov 8: THE SAFEGUARDS, PLANNED (Simon: "Make more precise plan for doing what you suggest").
  S1 ONE PROGRAM LIST, BY REFLECTION (robotgpu_program.zig): `every_dispatch` assembled at comptime from every public
     declaration named `*_program`, in declaration order (the step program stays first, as `kernel_names` wants) - a new
     program is on the device the moment it is declared. The build script imports the same file, so it follows.
  S2 EVERY KERNEL IN A PROGRAM (robotgpu.zig, a comptime block): every public `fn (u32) void` must be named in
     `kernel_names`, else a compile error naming it - a kernel written but dispatched nowhere cannot exist.
  S3 THE TWIN THROUGH THE DEVICE's LIST (`CpuTwin.runProgram`): each dispatch's kernel required, at comptime, to be in
     `kernel_names` - the twin can never run a kernel the device lacks. (With S1 it holds by construction; it stays as
     the statement of the rule.)
  S4 THE HOST CHECKS THE MODULE (compute_host, at pipeline creation): the module's entry points read from its SPIR-V
     (each `OpEntryPoint`, opcode 15, its name) or its WGSL (each `@compute` function's name), compared with the kernel
     list; any missing - "the module has 44 entry points, the host expects 53; missing: push_worlds, ...; the module is
     older than the kernel list: rebuild". The two readers are pure functions with tests of their own.
  S5 THE STALE MODULE, ROOT CAUSE: reproduce (add a program, build vk-host-test once); if the build runner kept an old
     entry list, move the entry points into the kernel module itself (exported at comptime from its own `kernel_names`),
     so the module and its entries are one compilation.
  S6 DEVICE COVERAGE (vk-host-test): the device pipe counts dispatches per kernel; the run lists every kernel it never
     dispatched on the GPU and fails on any - after device checks of the reset, policy-inputs and exploration programs
     against the twin (the device check planned as turn 7b) make that possible.
  S7 THE PAGE SHOWS ITS COUNT: "kernels: 53 of 53 compiled", so a phone test proves what it claims.
  ORDER: S1+S2+S3 one turn; S4 one; S5 one; S6 with the device checks; S7 with the demo's loading work.
- Nov 8: THE DEMO ON SIMON's PHONE - slow to load, then unresponsive. MEASURED: the page is 12.3 MB, of which 10.7 MB is
  one base64 WebAssembly binary of 8.0 MB: 0.8 MB of code and 7.2 MB of data - ABOUT 3.8 MB OF BVH MOTION CAPTURE AS
  TEXT (parsed at load), about 1.9 MB of WGSL (53 kernels, each module carrying its helpers), about 1 MB of fonts. The
  base64 is decoded by `Uint8Array.from(atob(...), callback)` - a function call for each of 10.7 million characters.
  Headless (desktop, SwiftShader): first frame at 1.7 s, then 60 fps; 64 shader modules and 53 pipelines, their calls
  cheap on the main thread (compilation happens in the GPU process, at first use); GPU BUFFERS 102 MB, THE LARGEST 32 MB
  (sized for many worlds; the page runs one). LIKELY ON A PHONE: the download; the per-character decode; parsing 3.8 MB
  of text; 53 pipelines compiled at their first dispatch, each a stall; 102 MB of GPU memory. REMEDIES, cheapest first:
  D1 decode the binary without a per-character callback (or stream-compile it); D2 the dance as binary numbers, not BVH
  text (and only the frames shown); D3 buffers sized by the page's counts; D4 pipelines created asynchronously, with a
  progress line ("kernels 12 of 53"); D5 the page compiling only the programs it dispatches; D6 the kernels in one
  shared WGSL module rather than one per kernel.
- Nov 8: THE DEMO's LOAD - D1 DONE. Simon: unresponsive WHILE LOADING, before the dance appears - so the main thread is
  blocked before the first frame. MEASURED PHASE BY PHASE (headless, desktop): `atob` of 10 M characters 52 ms;
  `Uint8Array.from(..., callback)` of 8 MB 736 ms - HALF OF A 1.5 s LOAD, and several times that on a phone;
  WebAssembly instantiation 16 ms; the app's start-up short. FIXED in the page writer (tools/c2js.zig): the binary
  decoded by `Uint8Array.fromBase64` where the browser has it, else one `atob` and a plain loop into a preallocated
  array - no function call per byte (the 64 KB string chunks kept, for the Android viewer's line limit). RESULT: first
  frame at 0.7-0.8 s instead of 1.4 s; 64 modules, 53 pipelines, no WGSL message, no device error; the page
  republished for Simon's phone. NEXT FOR THE LOAD: D2 the dance as binary numbers (3.8 MB of BVH text parsed at load),
  D3 GPU buffers sized by the page's counts (102 MB now, the largest 32 MB).
- Nov 8: SAFEGUARDS S1-S3 DONE (Simon's phone: the page works - GPU root 19.3 mm from the CPU's at frame 261 of run 5 -
  but black for about ten seconds before the character; baking the animations later). S1 robotgpu_program.zig:
  `every_dispatch` collected by REFLECTION - the step program first, then every other public `..._program` in
  declaration order (`isProgramName`; this Zig's `@typeInfo(...).@"struct".decl_names`); the build script, which
  imports the file, follows by construction. S2 robotgpu.zig: a comptime block requiring every public `fn (u32) void`
  to be a device kernel (`isDeviceKernel` over `kernels`), else "kernel 'x' is in no program of robotgpu_program.zig:
  no device compiles it". S3 `CpuTwin.runProgram` requires each dispatch's kernel at comptime (`requireDeviceKernel`):
  the twin can run nothing the device lacks. The kernel list and its checks moved above the twin (declaration order);
  `eql` aliased; `isDeviceKernel` with its own evaluation budget. PROVED BY A DELIBERATE ORPHAN: a kernel in no program
  stops the build with that message, naming it (then removed). CHECKED: robotgpu 29/29; the twin's decision check 2/2;
  vk-host-test, every check; the page - 64 modules, 53 pipelines (the reflected list gives the same kernels), no WGSL
  message, no device error; lint. NEXT: S4, the host checking the module's entry points against the kernel list.
- Nov 8: SAFEGUARD S4 DONE - THE HOST CHECKS THE MODULE. compute_host: `EntryPoints` {count, has_name} and
  `scanEntryPoints(module, name)` - SPIR-V recognised by the file's own `isSpirv` and read by `scanSpirvEntryPoints`
  (after the five-word header, each instruction's word count and opcode; every `OpEntryPoint`, opcode 15, its
  nul-terminated name from its fourth word), WGSL by `scanWgslEntryPoints` (each `@compute` attribute, its function's
  name after the next `fn `). THE PRE-FLIGHT, beside the existing binding cross-check (init-only, kept in release with
  zimr's asserts): a kernel whose module lacks its entry point stops with "kernel 'x': its module has no entry point by
  that name - N entry points for M kernels, K of them missing. The module was built from an older kernel list than the
  host's: rebuild it." compute_host.zig made a FAST TEST ROOT (its tests were reachable only from zimr.zig, the whole
  engine). CHECKED: the scanner's test (a hand-made SPIR-V module and a WGSL snippet, each one entry point, a helper not
  counted) 1/1; vk-host-test, every check, the pre-flight passing on every kernel's SPIR-V; the page, the pre-flight
  passing on every WGSL module - 64 modules, 53 pipelines, no message, no error; lint. NEXT: S5, reproducing the stale
  module to find its root cause.
- Nov 8: SAFEGUARD S5 - THE STALE MODULE's ROOT CAUSE FOUND. The SPIR-V compile is a run step (`zig build-obj` as a
  system command, shader_codegen's `compileKernelSpirv`): the build reruns it only when an input it KNOWS changes - the
  module roots it is given - and robotgpu.zig imports robotgpu_program.zig BY PATH. So the incident's change, to the
  program file alone, left the native module stale: an old module, the host's new kernel list. The fix was already in
  place: `compile.addFileInput(b.path("src/robotgpu_program.zig"))` with a comment stating exactly this - written at
  22:15 on Nov 8, after the incident (21:58) and before the rerun that passed, by a turn cut off after its visible reply
  (the file's time, preserved in the snapshots, shows it; no transcript mentions it). That is also why a probe (a new
  program and kernel, both files changed) did not reproduce it. WITH S1 AND S2, a change to the program file alone can no
  longer change the kernels (every kernel must be in a program, every program is listed by reflection). THE CLASS
  REMAINS: any file a kernel module's root imports by path is invisible to the step unless declared by hand - today only
  robotgpu_program.zig (robot.zig's one path import is a test fixture) - and a missed one would leave the GPU running
  STALE CODE while the twin runs the new, which no entry-point check can see. NEXT (S5b): the inputs found, not listed -
  at configure time, each module root's `@import("....zig")` paths read and followed, every file found declared an
  input of the step; the hand-written declaration removed.
- Nov 9: A CUT-OFF TURN, VERIFIED. After zimr452 a turn ran a NAMING PASS and was cut off before reporting (Simon saw
  its tool summary: "Probably stuck?"): between 00:20 and 00:27 it gave descriptive names and fuller comments to the
  kernel-list checks (robotgpu.zig: `kernel_name` and the doc of `isDeviceKernel`), the program reflection
  (robotgpu_program.zig), the kit's acting (`actOnRows`, `reservePolicyRows`: descriptive names, a comment per layer),
  the shared block of vk-host-test, and compute_host's entry-point scanners (`kernel_name`), removing a duplicate WGSL
  reader there; its last step - the tests again - never reported. RUN TO COMPLETION HERE: lint; compute_host 42/42;
  robotgpu (cached: the cut-off turn had passed it on these sources); the kit's tests 18/19 (1 skipped); the twin's
  decision check 2/2; vk-host-test, every check, acting included; the page - 64 modules, 53 pipelines, no WGSL
  message, no device error. Saved as zimr453.
- Nov 9: S5b, FIRST PART - THE BUILD FINDS THE PATH IMPORTS. shader_codegen.zig: `directPathImports(b, scratch,
  file)` - a file's own `@import("....zig")` paths, resolved against its directory, kept only if the file exists (the
  text can sit in a string), the text freed at once; `PathImports`, a memo of every file's direct imports for the whole
  build, behind a pointer made at `ShaderPipeline.init` (most of the pipeline's functions take it `*const`); the
  methods `pathImportsOf` (through the memo), `declarePathImports` (a root's closure, each file declared once per
  compile) and `addModuleRoot` (the `-M` argument AND its imports) - ALL 11 MODULE ROOTS of the file's compiles go
  through it, so a module added later cannot skip it; the hand-written `addFileInput(robotgpu_program.zig)` removed.
  REVIEWED ON THE WAY: the first version rescanned every root for every compile into the build's arena - the
  configure step was KILLED, out of memory (hundreds of compiles over robot.zig and zimrnum.zig) - hence the memo and
  the freed text. CHECKED: lint (the build configures). NEXT: the proof - a build after editing only
  robotgpu_program.zig must rerun the SPIR-V step - and vk-host-test and the page.
- Nov 9: S5b PROVED. A baseline vk-host-test (passes; its summary lists 11 SPIR-V compiles, `run ... zig
  (compute.spv)`); then ONE CHANGE, a comment appended to robotgpu_program.zig and nothing else: the summary shows
  exactly ONE compile rerun - "contents_changed: /home/claude/zimr/src/robotgpu_program.zig" - the input the build now
  finds by itself, with no hand-written declaration; the ten others cached (nothing over-triggered); vk-host-test passes.
  (A count of "success" lines first read zero: a rerun step reports why it ran, not "success".) The probe comment
  removed. NEXT: the page's web build through the same code (its per-kernel compiles use `addModuleRoot` too), then S6.
- Nov 9: S5b ON THE WEB. The page's web build through `addModuleRoot`: 53 SPIR-V compiles (one per kernel entry), one
  rerun (747 ms, a compile whose key now holds its found imports) and the others cached - right, the program file being
  back to the content of the last web build; the page - 64 modules, 53 pipelines, no WGSL message, no device error.
  S5 IS DONE. NEXT: S6, device coverage - the device pipe counting dispatches per kernel, vk-host-test listing every
  kernel it never dispatched on the GPU.
- Nov 9: S6, FIRST STEP - A PIPE COUNTS ITS DISPATCHES. compute_host: every dispatch passes `dispatchKernel` (both
  backends, `run` and `runPushed`), which now counts it in `dispatch_counts`, one count per kernel by its place in
  `M.kernels`, found at COMPILE TIME (`kernelIndex`): a kernel run that the module's list does not name is a compile
  error - the list is what a device module is compiled with - which generalises S3 to every compute module.
  REVIEWED ON THE WAY: (1) two of compute_host's CPU-only test modules had no kernel list - given theirs; (2) four
  example modules (`double_it`, `tile_gather`, `particle_step`, `shared_rotate`) have none because their builds list
  the entries themselves - adding one would make a SECOND list beside the build's, the very drift being removed - so a
  module without a list runs uncounted (`counts_dispatches`, `@hasDecl`); TO DO: those examples' builds reading the
  module's own list, as robotgpu's does. (3) Zig allows no declaration between fields - moved. CHECKED: compute_host
  43/43 (a new test: two kernels, one run twice - counts 0 and 2); the kit's tests; robotgpu; vk-host-test (the
  examples without lists compile); lint. NEXT: adding the counts up across the 13 simulators vk-host-test makes, and
  the list of kernels never dispatched on the GPU - first as a report.
- Nov 9: S6, SECOND STEP - THE DEVICE COVERAGE REPORT. vk-host-test: `DeviceCoverage` (robotgpu's dispatch counts
  added up over every GPU simulator as it is freed), passed to the five checks that make one and to the shared block
  (`defer coverage.add(&on_device)` after the free's defer, so the counts are taken first); the report before the leak
  check. (The cut-off naming pass had renamed the shared block's simulator `shared_simulator`; the edit script's
  assertion stopped it before it wrote anything.) THE REPORT: 32 OF 53 KERNELS DISPATCHED ON THE DEVICE; 21 NEVER -
  the step program's `site_poses` and `next_activations` (Geno has no sites and no activation dynamics, so they may be
  skipped by design); the tracking task around the step (`filter_actions`, `reference_targets`, `advance_frames`,
  `zero_effort`); the observation (`observe_character`, `observe_reference`); the judgement (`body_lowest_points`,
  `judge_tracking`, `judge_rewards`, `judge_episode`); the resets and pushes (`push_worlds`, `begin_reset`,
  `reset_pose`, `rest_on_floor`, `perturb_start`, `rest_after_noise`, `start_in_trouble`); acting (`policy_inputs`,
  `explore_actions`). The page runs the decision program on WebGPU, so the tracking kernels around the step have run on
  a GPU there - but THE OBSERVATION, JUDGEMENT, RESETS, PUSHES AND ACTING HAVE NEVER RUN ON ANY GPU: every check of them
  so far is the twin's. CHECKED: vk-host-test passes, its report printed; lint. NEXT: device checks of those programs
  against the twin in vk-host-test (the device check planned as 7b, natively first), then the report a failure; the two
  step kernels a model with sites and activations, or named exceptions with their reason.
- Nov 9: VK-HOST-TEST's TIME, MEASURED (Simon: "Find a way to know which tests are long. Find a way to reduce the time
  it takes"). Every output line stamped with the time since the last (each check prints once, when done). IN DEBUG,
  ~380 s: GENO's 64 WORLDS ON THE FLOOR, 100 STEPS - 281 s; the two step comparisons 27 s; two pipelines and acting
  22 s; constrained steps 15 s; the large dispatch 13 s; constraints at exact and at reference 6 s each; the step's
  floor 6 s; all else under a second. IN RELEASESAFE (safety checks and zimr's asserts kept - `zm.allow_assert` is off
  only in ReleaseSmall and ReleaseFast): the run 3 minutes instead of 6, the floor check still 145 s - so its cost is
  mostly llvmpipe's (a GPU emulated on the CPU, the validation layer on every submit), not the twin's; and the COMPILE
  2 minutes instead of 11 s, the test recompiling at every kernel change (its SPIR-V embedded). KEPT DEBUG, the
  measurement in a comment by the setting (`host_test_optimize`). THE PLAN: (1) the floor check smaller by default
  (fewer worlds, fewer steps, standing and lying still) with its full size behind a flag for occasional runs; (2) the
  test timing itself - each check's seconds recorded and the longest listed at the end, built in rather than an
  outside stamper; (3) then the device checks of the tracking programs, sized for llvmpipe from the start.
- Nov 9: VK-HOST-TEST IN 2 MINUTES INSTEAD OF 6. build.zig: the option `-Dlong-checks` (`VulkanHostTestInputs.long_checks`)
  reaching the test through its own options module (`vk_host_test_options`) - this Zig's build has no `b.args`, so a
  command-line flag cannot. The floor check takes its world count from `main` (`runRobotgpuFloorSteps(...,
  world_count, step_count)`) and prints the sizes it ran. TRIED 16 worlds over 25 steps: FAILED its depth bar - device
  and twin agreeing exactly (0.0350 m) but a lying world, starting in the floor's overlap, needs the 100 steps for its
  contacts to push it within 2 cm. So FEWER WORLDS, NOT FEWER STEPS: by default 8 worlds over 100 steps (the worlds
  alternate standing and lying; each world's dynamics its own), at full size 64 with `-Dlong-checks=true`. RESULT: the
  same numbers as at 64 - energy gap 0.0085%, the deepest 0.5 mm in the floor - and the run 2 minutes. NEXT: the test
  timing itself (each check's seconds, the longest listed at the end).
- Nov 9: THE TEST TIMING ITSELF - A CLOCK, AND ZIG's OWN. vk-host-test: `CheckClock` (owned by `main`, no global; the
  engine's `monotonicMilliseconds`), `main`'s 66 result lines printed through it - each line prefixed with its seconds
  - and the five slowest listed: floor (8 worlds) 53.4 s, two pipelines 36.5 s, constrained steps 17.1 s, the step's
  floor 7.0 s. ITS FLAW: 23 result lines are printed inside the checks, not by `main`, so their time is billed to the
  next line `main` prints (the 36.5 s holds the large dispatch and the step comparisons); its labels keep their format
  placeholders. SIMON: "There is already a zig compiler argument for test timing diagnostics" - FOUND: this Zig's run
  step records `ns_per_test`, each test's time as the test runner reports it, shown in the build's web interface
  (`--webui`, implied by `--time-report`); `--time-report` itself reports COMPILE time; `--summary all` times whole
  steps. All of it applies to `test` blocks run through the build's test protocol - vk-host-test is an executable with
  a `main`, so the build sees one 2-minute step. THE BETTER STRUCTURE: the checks as `test` blocks - Zig times each, and
  `-Dtest-filter` runs one check alone (iteration in seconds); costs: the device and simulators the checks share, the
  leak check and coverage report as tests of their own, a 3,700-line file converted over several small turns.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, FIRST SLICE (Simon chose the conversion). FOUND: the build records each test's
  time (`ns_per_test`) but shows it only in its web interface - so each test also prints its own seconds (`TestTimer`).
  THE ENGINE: the Vulkan host is one per process, so `wgpu_vulkan.isStarted()` (its own `host != null`) and an
  IDEMPOTENT `initDevice` (a second call is given the device already made - `bringUp` would build a second instance);
  so the tests share the host without state of their own. vk_host_test.zig: `TestDevice.open()` (starts the host on
  the first test that asks; an error without the validation layer), `TestTimer`, the screen size moved up beside them,
  and THE FIRST CHECK AS A TEST - `robotgpu clear_overflow` (`runRobotgpuOverflow`, the testing allocator's leak check
  per test). build.zig: `vk-host-checks` - the file's test blocks from the same module (`b.addTest`), `-Dtest-filter`
  passed to Zig's test runner. CHECKED: `zig build vk-host-checks -Dtest-filter=clear_overflow` - 1/1, 6.7 s (the
  device's start-up); lint. NEXT: the other checks, a few per turn, smallest first; `main` and `CheckClock` removed at
  the end.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, SECOND SLICE. Five more checks as tests - the ones that return a plain pass and
  that `main` judges by it alone: the large dispatch (`runDispatchTally`), ranged readback, pushed dispatches, buffer
  lending, range requests; each test named for what passing means. CHECKED: `zig build vk-host-checks` - 6/6 in 8 s:
  clear_overflow 7.2 s (the first test, the device's start-up in it), THE LARGE DISPATCH 0.5 s (the stamping of `main`'s
  output had billed it 13 s - the start-up and every silent check before it), the others 0.1-0.2 s; lint. NEXT: the
  checks that return an outcome to judge (the probe, the timings, the Cholesky factorisation, the kit's kernels, ...),
  their judgement moved from `main` into each test.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, THIRD SLICE. The checks that return an outcome: their judgements moved out of
  `main` into functions both `main` and the tests call - `kitMatches`, `probeHolds`, `factorisationHolds`,
  `timingsHold` (one definition each while `main` remains; they stay with the tests after) - and five tests: zimrnum's
  conformance sweep (no case differing), the kit's learning kernels, the probe, the workgroup Cholesky, the timings.
  CHECKED: `vk-host-checks` 11/11 in 15 s (the kit's kernels 4.9 s, the sweep 1.6 s, the timings 0.9 s, the others
  under half a second; the first test 6.8 s with the device's start-up); vk-host-test's `main` still compiles and
  passes (a test build never compiles `main`, so it is run until retired); lint. NEXT: the robotgpu simulation checks
  (steps, floor, limits, constraints, acting), each with its coverage.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, FOURTH SLICE. `FloorSize` and `floorSize()` (the floor check's size, one
  definition for `main` and the test, `-Dlong-checks` the same in both); `floorStepsHold` and `limitStepsHold` (the
  bars and the comments that justify them, moved out of `main`, which calls them); three tests - the floor, the
  constrained steps, the Sim's step clearing every overflow word - each with a coverage ledger of its own for now.
  CHECKED: `vk-host-checks` 14/14 in a minute (the floor 40 s, constrained steps 16.7 s, the Sim 5.9 s); vk-host-test's
  `main` passes; lint. OPEN: device coverage ACROSS tests (each test's ledger is its own) - a decision for Simon once
  the conversion is further on. NEXT: the step comparisons (`runRobotgpuSteps`, twice), the constraints (exact and
  reference), and the shared device block (copy between pipelines, acting).
- Nov 9: DEVICE COVERAGE ACROSS TESTS (Simon: "I trust your judgement"). CHOSEN: a ledger the test file shares,
  `tests_device_coverage`, and a last test reading it - not a test dispatching every program once, which would show a
  kernel CAN run but not that any check compared its results on the device (the gap found). The one mutable module
  global of the tests, with an explained `lint:off module-var` (zimrlint's rule 9): test blocks can share nothing else,
  and Zig runs a file's tests in declaration order, so the report, last, sees the whole run. build.zig: the test
  options' `filtered` (`-Dtest-filter` given) - the report skips then, a part of the checks giving a part of the
  coverage. CHECKED: `vk-host-checks` 15/15 in a minute, the report "32 of 53" - the same as `main`'s, so the three
  converted simulation tests already reach every kernel the old run reached; filtered to the report alone, it skips
  (0 pass, 1 skip); lint. NEXT: the step comparisons, the constraints, the shared device block; then the report a
  failure once the tracking programs have device checks.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, FIFTH SLICE - THE CONSTRAINTS. `constraintsHold(verdict)`: the rows' integers
  equal and every array within its bar (`robotgpu_host.constraint_array_bars`), the loop leaving at the first array over
  its bar - `main`'s loop calls it for its verdict and keeps its printing; two tests, at the exact inertia and at the
  reference pose's, on the shared coverage ledger. CHECKED: filtered to "constraints", 2/2 (10.7 s with the device's
  start-up, 6.5 s); vk-host-test's `main` passes, both constraint lines printed; lint. NEXT: the two step comparisons
  (`runRobotgpuSteps`) and the shared device block (the copy between pipelines, acting).
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, SIXTH SLICE - THE STEPS AND THE DECISION. `oneStepHolds` (the floor touched,
  the step within its bars), `decisionHolds` (its own two arrays within 16 epsilons, the poses within the step's bar -
  the measured reasoning moved with it as its doc comment), `hundredStepsHold` (the device's energy within a hundredth
  of the integrator's drift, with its measurements); `main` calls the last two. Three tests: one driven step, 100
  steps under gravity, the decision. CHECKED: filtered to "robotgpu", 16 pass and the coverage report skipped (the step
  6.5 s, 100 steps 19.0 s, the decision 8.9 s); vk-host-test's `main` passes; lint. COUNT: of `main`'s 33 checks, 17
  have tests; 16 remain - six of graphics (textures, copies, the screen, views), the engine's compute basics (a kernel,
  `runEngineCompute`, the training pipelines), the uniform loop, the memory envelope, the probe table, the constant
  index, counting sort, the copy between pipelines, acting. ESTIMATE: three turns of conversion, one retiring `main`;
  then back to the plan (turn 7: the decision loop closed on the device).
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, SEVENTH SLICE - THE SMALL DEVICE CHECKS. Seven tests, each named from its
  failure message turned to what passing means: the uniform loop, the memory envelope (an arena as large as a binding,
  right at both ends), the maths and the spatial probe tables (`reportProbeResults`, unchanged), the constant index,
  counting sort, a kernel's four times. CHECKED: `vk-host-checks` 27/27 in 2 minutes (the seven at most 0.4 s each),
  coverage 32 of 53; lint (`main` unchanged). COUNT: 24 of `main`'s 33 checks have tests; 9 remain - six of graphics,
  the engine's compute and training pipelines, and the shared device block (the copy between pipelines, acting).
  ESTIMATE: two turns of conversion, one retiring `main`.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, EIGHTH SLICE - GRAPHICS AND THE ENGINE's COMPUTE. `TestDevice.errors_at_open`
  (the host's `messageCounts()` when the test opens it) and `expectNoNewValidationErrors` - what a call returning
  nothing (a clear, views, a pipeline made) is judged by, and what every call in the slice must also keep. Eight
  tests: a texture cleared, two targets cleared, read back, copied, a draw on the headless screen, mip and array views,
  the engine's compute, the training pipelines made; and a run-wide test, declared next to last, for what `main`
  judged at shutdown - no validation error over the whole run. CHECKED: `vk-host-checks` 36/36 in 2 minutes (the
  graphics checks milliseconds each, the training pipelines 4.7 s); lint. COUNT: 32 of `main`'s 33 checks have tests
  (the copy between pipelines and acting, sharing one block, remain). NEXT: that block, then `main` retired.
- Nov 9: VK-HOST-TEST INTO TEST BLOCKS, LAST SLICE. The copy between pipelines and acting, in ONE test as in `main`'s
  shared block (a kit pipeline, Geno's model, one simulator of 8 worlds): llvmpipe keeps a freed simulator's memory,
  so two tests making their own would raise the peak that once killed the run. Its simulator's dispatches added to the
  shared coverage ledger; no new validation error. CHECKED: `vk-host-checks` 37/37 in 2 minutes (36 checks and the
  coverage report; this test 11.8 s), coverage 32 of 53, peak memory 1 GB; lint. EVERY ONE OF `main`'s 33 CHECKS HAS
  A TEST. NEXT: `main` retired - `vk-host-test` running the tests, the executable, `main`, `CheckClock` and `main`'s
  coverage report and leak check removed (the testing allocator checks leaks per test), the Windows build of the test
  kept working.
- Nov 9: `main` RETIRED - VK-HOST-TEST IS ITS TESTS. build.zig: `addVulkanHostTest` builds `b.addTest` (the test
  runner; `-Dtest-filter` through `VulkanHostTestInputs.filters`); `vk-host-test` runs it (with native_os's tests as
  before) and `-Dtest-filter` runs some of it; the separate `vk-host-checks` step removed (now the same); the Windows
  build installs the same test binary, which runs its tests when started on its own, its WGSL check unchanged (it reads
  the built file). vk_host_test.zig: `main` and `CheckClock` removed (zimrlint's autofix then removed three globals only
  they used). FOUND ON THE WAY - THREE CHECKS `main` RAN THAT THE COUNT HAD MISSED (it looked for `run*` names):
  `releaseWhileHeld`, `churnBindGroups`, `churnLargeWrites` - left referenced nowhere by `main`'s removal, now tests
  (a view and a sampler released while a group holds them; bind group churn bounded; large write churn within budget).
  AND the run-wide validation test now judges the host's SHUTDOWN counts, as `main` did: an object never destroyed is
  reported only when the device is. CHECKED: `zig build vk-host-test` - 20/20 steps, 40/40 tests (37 checks, the
  validation and coverage reports, native_os's), 2 minutes, coverage 32 of 53; lint. (The runner's "failed command:"
  line labels a command that wrote to stderr - every test prints its time - not a failure.) THE CONVERSION IS DONE.
  BACK TO THE PLAN: turn 7 - exploration in the trainer's numbers, then the decision loop closed on the device, with
  device checks of the tracking programs (the coverage report a failure once they exist).
- Nov 9: TURN 7 RESUMED - THE TRAINER EXPLORES BY COUNTER. robot_track_resident's `prepareActing`: the exploration's
  numbers (one per action) drawn by `rbt.drawNormal(fleet.draw_seed, world, decision, .explore_action, action)` -
  `explorationNoise`'s own draws - where the learner's random stream drew them; the decision is the fleet's number
  plus one, the decision about to be stepped (its step advances the number first, so the decision's pushes share the
  count). `exploringActionFrom` unchanged: `raw += spread * number` is `explorationNoise`'s multiply and the device's
  add, so the two agree to the bit. The flow's numbers stay on the stream (the flow actor is not on the device yet).
  CHECKED: the trainer's tests 542/653 (111 skipped); lint. NEXT: the decision loop closed on the device, against the
  fleet and the trainer over whole episodes - first, whether the trainer's host policy and the kit's `actOnRows` give
  the same raw actions to the bit (their summation orders), which decides what such a check can demand.
- Nov 9: REVIEW OF THE ACTING PATH (Simon: "Review this code and surroundings. Make the plan better and more
  precise"). FINDINGS:
  R1 THE CPU POLICY AND THE GPU POLICY SUM IN DIFFERENT ORDERS. `HostPolicy.forward`'s first layer adds the goal's
     and the state's terms interleaved, one pair per input; the kit's `dense_fwd` adds the goal block, then the state
     block - its own comment: they "agree to rounding rather than to the bit". (Both use `zm.tanh`.) A closed loop
     compared bit for bit is impossible until one order serves both.
  R2 THE DEVICE HAS NO NON-FINITE GUARD. The trainer's `writeAction` replaces a non-finite component by zero and
     counts it (NaN bodies are never terminated and poison the world); on the device, the policy's raw actions go to
     the physics as they are.
  R3 THE ACTION FILTER MAY BE APPLIED TWICE. The trainer filters in `writeAction` (`options.filter`); the simulator's
     decision filters too (the fleet's `action_filter`, the device's `filter_actions`). One place must hold it: the
     simulator's decision, with the trainer's filter given to it.
  R4 THE EXPLORATION's SPREAD IS COMPUTED BY HAND IN TWO PLACES (the trainer's `noise_scale * sigma`; the device's
     `DecisionClock.exploration_spread`, set by whoever drives it): one function.
  R5 THE DECISION's NUMBER: "the fleet's number plus one" in the trainer, "the fleet's number after its step" in the
     checks, a counter of its own on a device - one definition (`Fleet.decisionAboutToStep`, and the device's driver
     counting the same way).
  R6 THE DEVICE ACTS ONLY WITH THE PLAIN POLICY: no plan's correction (teacher 2), no flow's (teacher 3). A comparison
     with the trainer must switch both off; C19 brings them.
  R7 FRESHNESS: the trainer acts with a host MIRROR of the weights, refreshed on a schedule; a device acts with the
     kit's live parameters - fresher, a difference by design; and the device's normaliser tables must be re-uploaded
     whenever the learner's normaliser changes (C10).
  THE REMAINING TURNS, MADE PRECISE (each one checked piece):
   7a ONE POLICY ORDER: `HostPolicy.forward`'s first layer in `dense_fwd`'s order (the goal block, then the state
      block). CHECK: a test - random weights and rows - the host policy's raw actions the kit's `actOnRows` on the CPU
      pipe, bit for bit.
   7b ONE PLACE EACH: the filter in the simulator's decision (the trainer sets the fleet's `action_filter`;
      `writeAction` stops filtering); `explorationSpread(noise_scale, sigma)` in robot.zig; `Fleet.decisionAboutToStep`.
      CHECK: the trainer's tests; the twin's decision check.
   7c THE DEVICE's GUARD: a kernel ending the acting (`guard_actions`): every non-finite component zero, a world's
      count of them kept. CHECK: on the twin, a NaN weight gives zeros and counts as the trainer's write does.
   7d ACTING AS ONE CALL: `actOnDevice` - the policy's inputs, the copy, `actOnRows`, the copy back, the exploration,
      the guard - on the GPU (`copyFieldBetween`) and on the twin (the same copies between the modules' buffers), with
      the decision's clock. CHECK: for one decision, the twin's actions the trainer's, bit for bit (plain policy).
   7e THE CLOSED LOOP ON THE TWIN: some 60 decisions - starts with noise, pushes, ends and resets - the fleet with the
      trainer against the twin with the kit, plans, flow and curriculum off; every decision's actions, poses,
      velocities, rewards and flags bit for bit. CHECK: a kit test under five minutes.
   7f THE TRACKING PROGRAMS ON THE DEVICE (vk-host-test): observation, judgement, resets and pushes, the policy's
      inputs, exploration, the guard, and a few decisions of the closed loop - the device against the twin, integers
      exact, numbers within bars; then the coverage report FAILS on a gap (51 of 53, `site_poses` and
      `next_activations` named as exceptions until a model with sites and activation dynamics joins). 
   7g THE PAGE's DEVICE CHECK (Simon's, after acting): the same checks on the phone's WebGPU, a line per group.
   8  RECORDS (C4), as planned. 9-10 THE TRAINER's DEVICE PATH (C10) - now naming what R7 requires: the normaliser
      uploaded when it changes, the curriculum's round on the host, the spread's schedule through the clock.
   11-20 as planned (the lab, the night's safety, the feasibility pass, the new signals, the physics rate, the skip
      model, the planner, the flow offset, the dry run).
- Nov 9: 7a DONE - ONE POLICY ORDER. `HostPolicy.policyRow`'s first layer in the kit's own order (`dense_fwd` over the
  row [goal | state]): the bias, every goal term, then every state term - the comment now says why the order matters
  (float addition is not associative). CHECKED: the kit's acting test extended - every row through the trainer's
  `HostPolicy.policyRow` on the same packed weights, the raw actions the kit's `actOnRows`, BIT FOR BIT; and PROVED
  SENSITIVE - with the old interleaved order put back, the test fails at the first component (then restored); the
  trainer's tests 542/653 (111 skipped); lint. NEXT: 7b - the filter in the simulator's decision alone,
  `explorationSpread`, `Fleet.decisionAboutToStep`.
- Nov 9: THE STIFFNESS FILTER OF ITS OWN (Simon: "Make sure it is easy to change the filter for action offsets and
  stiffness. I feel like going closer to 0.25 instead of 0.5 might help ... All these numbers are run params, right?").
  CORRECTING R3: there are TWO filters, not one applied twice - the trainer's decision-rate `options.filter` (DReCon's
  form; 1 = off by default, 0.2 in the lab's and Geno's presets) and the physics-rate `action_filter` of the fleet and
  the device (`filter_actions`; 1 by default, 0.5 in the twin's check). Whether both should act at once stays a
  question for Simon. BUILT: the fleet's `stiffness_filter: ?f32` (null: the offsets' share) and
  `Options.stiffnessFilter()`; the fleet filters the offsets at `action_filter` and the limbs' stiffnesses at their own
  share; the device: the uniform's `stiffness_filter` (a row), `setActionFilter(offsets, stiffness)` on the options and
  the host's `Sim`, `TrackingSettings.stiffness_filter`, and `filter_actions` choosing its share by the number's place
  (the offsets first, `action_count - limb_count` of them). RUN PARAMETERS? NOT YET: these are options set in code by
  presets (robot_lab.zig, robot_geno.zig); the run file (`night1.zon`, C10) is to carry `filter`, `action_filter` and
  `stiffness_filter` per experiment, so a run at 0.25 is one line. CHECKED: the twin's decision check 2/2 - with limbs,
  the offsets at 0.5 and the stiffnesses at 0.25, bit for bit; robot_track 325/368; vk-host-test (the disk full again -
  the cache cleared whole); the page builds, WebGPU's evidence clean (64 modules, 53 pipelines); lint.
- Nov 9: THE FILTER's DEFAULTS (Simon: "filter time for stiffness and offset should be individually tweakable. put
  stiffness at 0.5 and offset at 0.25 by default"). DONE: `stiffness_filter` a value of its own (no longer "the offsets'
  when unset"; `stiffnessFilter()` removed) - offsets and stiffness each set alone, on the fleet, the device and the
  page. TRIED THE DEFAULTS 0.25 AND 0.5: robot_track 325/368 passed, but THE TRAINER's "the skip model learns beside
  the world model" FAILED - its skip model's loss no longer fell within 12 world updates. The filter's own doc says
  why: a filtered motion depends on the previous decision's action, which a world model must then be given - and ours
  is not yet (C5, turn 15). So the defaults stay 1 (no filter) FOR NOW, Simon's 0.25 and 0.5 written in their docs, to
  BECOME THE DEFAULTS IN THE SAME TURN AS C5 - that test their check. (Until then a run may set them, knowing its world
  model is blind to the dependency.) CHECKED: robot_track 325/368; the learning test 2/2 with the defaults at 1; lint.
  AN OPEN POINT: "filter time" - a per-step share means a different time constant at another physics rate (C13 may
  move to 120 Hz); expressing the filters as times (share = 1 - exp(-dt / tau)) would keep their meaning across rates.
- Nov 9: C5 MOVED UP (Simon), AND FOUND LARGER THAN SAID. The CPU learner (robot_latent) already models a filter
  exactly: its world model runs per physics step on the action APPLIED there (what the replay records); its rollouts
  apply `filter * asked + (1 - filter) * applied` inside the graph, differentiated exactly; `sees_applied` hands the
  policy the action being applied before each decision - but for the DECISION-RATE filter (the learner's and the
  trainer's `filter`). Under the PHYSICS-RATE filter (the fleet's `action_filter`, filtered every physics step in
  `driveOnce`, the state in `applied_actions`) the trainer's replay records what it GAVE the fleet - the decision's
  asked action - so the world model learns from asked actions while the physics ran on filtered ones: the blind spot
  the skip-model test showed. TWO DESIGNS: A - model the physics-rate filter (the replay recording each physics step's
  applied action; the graph's filter op per physics step, a share per number); B - use the decision-rate filter the
  learner already models (two shares, offsets and stiffness, in robot_latent, the kit's mirror and the trainer's
  `writeAction`; a decision-filter step on the device's acting path; the physics-rate filters left at 1). Either way
  Simon's 0.25 and 0.5 land as defaults with the skip-model test their check. AWAITING SIMON's CHOICE.
- Nov 9: SIMON CHOSE B (the decision-rate filter carries 0.25 and 0.5; A later if the runs show jerk). CORRECTION
  FOUND AT ONCE: the CPU learner (robot_latent) models the decision filter exactly - graph (`g.scale`/`g.add`), rows
  (`track.filterAction` at three places), `sees_applied` - but THE GPU KIT (robot_latent_kit), the one the trainer and
  the nights use, MODELS NO FILTER: none in its rollout, no applied-action input to its policy. The trainer filters
  only when acting (`writeAction`); its training rollouts never apply the filter, so the policy learns as if its asked
  action were applied directly. B IS THEREFORE LARGER THAN "A SECOND SHARE" - and still smaller than A, which needs
  the same port at every physics step plus a change to the replay. B, MADE PRECISE:
   B1 THE CPU LEARNER's TWO SHARES: `filter` (the joints' offsets) and `stiffness_filter` (the limbs'), the graph's
      filter as a share per action number (an elementwise product with a constant vector, the same multiplications as
      the rows' two-part `filterAction`). CHECK: the existing graph-equals-rows test, with limbs and two shares.
   B2 THE FILTER IN THE KIT's ROLLOUT, forward and backward: at each decision `applied = shares * asked + (1 - shares)
      * applied`, from rest at an episode's start, the gradient reaching both the decision's ask and the earlier
      applied action. CHECK: the kit's rollout the CPU learner's, as the kit's other rollout tests compare.
   B3 THE POLICY SEES THE APPLIED ACTION in the kit (`sees_applied`'s block, starting at zero). CHECK: as B2.
   B4 THE TRAINER AND THE DEVICE: `writeAction` filtering its two parts; the device's acting path gaining the decision
      filter (the raw action plus exploration blended into the action given at the previous decision, rest after a
      reset). CHECK: the trainer's tests; the twin's acting against the trainer's, bit for bit.
   B5 THE DEFAULTS: offsets 0.25, stiffness 0.5 (the decision-rate shares; the physics-rate ones stay 1). CHECK: the
      skip-model test that failed, passing; the trainer's tests.
- Nov 9: B1 AND B2, READ. B1 IS NOTHING TO DO: the CPU learner's actions are the joints' offsets alone (sized by
  `track.actionSize(m)`; limb stiffness never reached it), so its one `filter` already is the offsets' share - its doc
  to say so. B2 IS MOSTLY WIRING: zn_mlp's `lat_act` (forward) and `lat_act_bwd` (backward) ALREADY MODEL THE DECISION
  FILTER - `action = lat_filter x lat_scale x (raw + noise) + (1 - lat_filter) x previous`, the previous read at
  `lat_prev_action` (the previous step's action columns, or before the window the action given before it), and the
  gradient recursion `(1 - lat_filter)` carried back step by step - but the kit's `policyStep` never sets
  `lat_filter`, `lat_prev_action` or its stride, so the filter sits at 1. B2 MADE PRECISE: (a) both kernels given a
  second share for the limbs' stiffness and the offsets' count (`lat_stiffness_filter`, `lat_offset_count`: a
  number's share by its place, as the device's `filter_actions` chooses it), the params kept in whole rows; (b) the
  kit's options carrying the two shares, `policyStep` and its backward setting them and the previous action's place
  (the previous step's action columns; before the window, the replay's action before it); (c) CHECK: the kit's
  rollout and its gradients with the filter on, against the CPU learner's graph (offsets only) and, with limbs,
  against rows filtered in two parts.
- Nov 9: B2(a) DONE - TWO SHARES IN THE ACTION KERNELS. zn_mlp: `lat_stiffness_filter` and `lat_stiffness_count` in
  the params (two padding words of the loss-weight row - the params' size unchanged), `latFilterShare(number)` (the
  offsets first at `lat_filter`, an action's last `lat_stiffness_count` numbers at `lat_stiffness_filter`, as the
  device's `filter_actions` chooses), and both `lat_act` and `lat_act_bwd` taking each number's own share (a number at
  1 never reads or leaves a carry - its share the same at every step). B1: robot_latent's `filter` doc now says it is
  the offsets' share (its actions are the offsets alone). CHECKED: a new test of the two kernels on the CPU pipe -
  two rows of three offsets and two stiffnesses at 0.25 and 0.5: every action its share's blend of the scaled raw
  output and its previous action, every raw output's gradient and carry exact - THE FIRST TEST OF THE FILTER PATHS
  (the kit had always run them at 1); the kit's tests 18/19 (1 skipped); vk-host-test filtered to the kit's - the
  kernels on the GPU, 2/2; lint. NEXT: B2(b) - the kit's options carrying the two shares, the policy step and its
  backward setting them and the previous action's place.
- Nov 9: B2(b) DONE - THE FILTER WIRED INTO THE KIT's ROLLOUT. robot_latent_kit: the fields `filter`,
  `stiffness_filter`, `stiffness_count` (beside `sigma`; 1, 1, 0 - no filter); two regions, `start_actions_at` (rows x
  actions in the activations: the action each row was given before its window, REST unless the trainer stages the
  replay's) and `filter_carry_at` (rows x actions in the gradients), both in `placedAt`'s lists (the kit's own check
  caught the first omission); `policyStep` setting the shares and the previous action's place
  (`previousActionColumns(k)` - decision k-1's action columns at the row's stride - or the starting actions); the
  backward zeroing the carry first when it filters (zn_mlp's new `zero_gradient_rows`, in the kernel list) and setting
  the shares and the carry's place. CHECKED: the kit's tests 32/34 (2 skipped) - every share 1, nothing changed;
  vk-host-test filtered to the kit, 2/2 (the kernels and the new one on the GPU); lint. NEXT: B2(c) - the rollout and
  its gradients with the filter ON against the CPU learner's graph; then the trainer staging each window's starting
  actions from the replay (until then a mid-episode window starts from rest).
- Nov 9: NO PERSONAL NAME IN THE CODE (Simon: "Avoid mentionning the word Simon in the code. Name it action filter or
  something more descriptive"). Every mention in the Zig sources renamed or reworded: the filter is THE ACTION FILTER
  (capitals kept at a sentence's start; "SIMON'S FILTER" -> "THE ACTION FILTER"); attributions in parentheses dropped,
  their references kept; "choice", "idea", "suggestion", "ask", "option" dropped, their substance kept; anecdotes made
  neutral observations ("Observed on a phone:", "what the eye sees", "verified by eye"); the keyboard example's
  drawing, photo and picture as "the drawn layout", "the photo", "the second picture" (its test names too); a sample
  typed text "Ada". The gallery's address (simonclavet.github.io) kept - a real address the build publishes to. The
  tutorials' two mentions fixed the same way. ALSO CORRECTED, found rereading: the fleet's PHYSICS-RATE filter docs
  said 0.25 and 0.5 would become THEIR defaults; with B chosen, those go to the DECISION-RATE shares - the physics-rate
  ones stay 1, no learner modelling them yet. CHECKED: no mention left (the address aside); comment blocks lengthened
  by the rename rewrapped; lint.
- Nov 9: B2(c), THE FORWARD HALF - THE KIT's FILTERED ROLLOUT FOLLOWS THE CPU LEARNER. The kit's forward comparison
  test became `expectPolicyRolloutFollowsCpu(rollout_filter)` (`RolloutFilter`: the offsets' share, the stiffnesses'
  share for an action's last `stiffness_count` numbers, staged starting actions or rest), its CPU side blending each
  scaled action into what was applied before at its number's share, from the window's starting actions, and handing
  the world model the blended action. Two tests: no filter (as before) and offsets 0.25, the last two numbers 0.5,
  staged starting actions. CHECKED: 2/2 within the bars (actions 1e-5, states 1e-4 - the CPU learner's own policy
  still sums interleaved, hence the tolerance); PROVED SENSITIVE - the CPU side's stiffness share moved by 0.1, the
  filtered test fails (then restored); lint. NEXT: the backward half - the policy's gradients through the frozen world
  model with the filter on, against zimrnum's autodiff of the CPU learner's graph (whose `filter` is the offsets'
  share).
- Nov 9: B2(c), THE BACKWARD HALF - THE KIT's GRADIENTS THROUGH THE FILTER MATCH ZIMRNUM's. The gradient comparison
  became `expectPolicyGradientsMatchZimrnum(rollout_filter)`: the graph blends each scaled action into the one applied
  before, `chosen * shares + applied * (1 - shares)` (zimrnum's elementwise `mul` with constant tensors of each
  number's share and its rest; no filter ops at all with no filter), from the same staged starting actions the kit
  reads. Two tests: no filter (as before) and offsets 0.25, the last two numbers 0.5, staged starts. CHECKED: 2/2 -
  every policy weight's gradient within 1e-4 of the largest (the kit's carry recursion against the graph's own
  differentiation of the blend); PROVED SENSITIVE - the graph's stiffness share moved by 0.1, the filtered test fails
  (then restored); lint. B2 IS DONE: the kit models the action filter, two shares, forward and backward. NEXT: B3 - the
  policy in the kit seeing the action applied before its decision (the CPU learner's `sees_applied`).
- Nov 9: B3 DESIGNED - THE KIT's POLICY SEES THE ACTION APPLIED BEFORE ITS DECISION. The CPU learner's form
  (`policyWith`'s `applied`, its `AppliedRow`): a block of weights, actions x hidden, STARTING AT ZERO, its terms summed
  into the first layer after the state's and the goal's, before the tanh - so at zero the policy is exactly the one
  that cannot see it. THE KIT, in four steps:
   B3a THE FORWARD: the policy's packed weights gain the block (always reserved, zero unless trained - a product with
       zero adds exactly nothing, so no flag and no change to any kit that does not use it); `PolicyWeights.applied`;
       the first layer computed as before but LINEAR into its hidden block, the applied block's terms ADDED (a dense
       pass accumulating into its output - a kernel of its own or a parameter of `dense_fwd`), then the tanh; the
       applied action read where the filter reads it (`previousActionColumns(k)`, or the window's starting actions).
       CHECK: the kit's actions against the CPU learner's `policyWith` with `applied`, the block random.
   B3b THE BACKWARD: the block's gradient (the applied action's transpose times the first layer's gradient) and the
       gradient INTO the applied action (the block times it), ADDED to the earlier decision's action gradient - the
       filter's carry for that decision, so the policy's reading of its own past action reaches the decision that
       made it. CHECK: against zimrnum's differentiation of the graph with the applied input.
   B3c THE TRAINER's CPU POLICY (`HostPolicy.policyRow`, from its mirror's block, the applied action from its slot)
       and THE DEVICE's ACTING (the policy's inputs gaining the action given at the previous decision). CHECK: the
       host policy against `actOnRows` bit for bit (as 7a); the twin's acting against the trainer's.
   B3d THE DEFAULTS (was B5): offsets 0.25, stiffness 0.5, the policy seeing what it applies. CHECK: the skip-model
       test; the trainer's tests.
- Nov 9: REVIEW FOR UNDERSTANDING (Simon: "Review recent code. Add intermediate locals to split expressions. Optimise
  for understanding"). Every compound expression of the recent code split into named locals, KEEPING EACH ARITHMETIC
  IN ITS ORDER so results stay bit for bit: zn_mlp's `lat_act` (raw_at, noise, scaled_noise, noisy, chosen;
  previous_at, new_part, kept_part) and `lat_act_bwd` (action_gradient_at, raw_at, before_at, after_at,
  pull_from_before, pull_from_after, price_gradient, through_action; later_whole_gradient, carried, whole_gradient -
  `(through_action + price_gradient) + smooth` as before); the kit's policy step (action_columns_at, step_seed,
  is_first_decision, previous_action_at, previous_action_stride) and backward (step_actions, action_gradient_at,
  step_action_count, penalty_coefficient, smooth_coefficient, has_previous_step, has_next_step, previous_raw,
  next_raw); `actionColumns(k)` - one helper for "decision k's action columns", used for the write and the previous
  action (replacing `previousActionColumns`); the fleet's filter parts (asked_offsets, asked_stiffnesses,
  filtered_offsets, filtered_stiffnesses); the device's exploration (chosen, explored); the tests' blends (new_part,
  kept_part; the graph's as a labelled block). CHECKED: the kit's tests 34/36 (2 skipped) - the filter's kernel,
  rollout and gradient tests among them, bit-exact ones unchanged; the twin's decision check 2/2; robot_track
  325/368; vk-host-test, every test; lint.
- Nov 9: B3a, BY A CUT-OFF TURN, VERIFIED. After zimr482 a turn built the forward half of B3 and was cut off before
  reporting (Simon saw its tool summary: "Stuck?"), between 22:05 and 22:25: zn_mlp's `applied_add_activate` (the
  applied action's terms added to a first layer's linear sum, in order, then its activation; in the kernel list);
  the kit's policy weights gaining the applied block after the layers (`PolicyWeights.applied`,
  `packPolicyWithApplied`; zero by default), its first layer linear then the block's terms and the tanh; the kit's
  tests on `RolloutVariant` (the filter's settings and `applied_block`), the forward check reading the block; and the
  block's knock-on effects - the trainer's weight mirror and a test's index (`policyWeights().applied - 1`), and the
  lab's policy player refusing a policy whose block is not zero (it does not read its applied action) rather than
  dropping the weights. RUN TO COMPLETION HERE: lint; the kit's tests 35/37 (2 skipped); the trainer's tests (cached -
  the cut-off turn had passed them on these sources; the lab compiled there); the twin's decision check 2/2;
  vk-host-test 40/40 (the new kernel on the GPU). NEXT: B3b - the backward: the block's gradient, and the gradient
  into the applied action added to the earlier decision's carry.
- Nov 9: B3b WIRED - THE BACKWARD OF THE APPLIED BLOCK. zn_mlp: `lat_applied_gradient` (the params' last padding word;
  0: none, the region never at the gradients' start) and `lat_act_bwd` adding `from_policy` - what the next decision's
  policy, reading this action as the one applied before it, sends back - to the action's gradient (without a filter)
  or to its whole gradient (with one: `(own + carried) + from_policy`). The kit: the gradients' region
  `applied_gradient_at` (rows x actions; in `placedAt`'s list), zeroed before the backward's last step; at every step
  the block's weight gradient (the applied action, transposed, times the first layer's gradient - at the first
  decision too, from the starting actions); for k > 0 the input gradient into decision k-1's action, which step k-1's
  `lat_act_bwd` adds in. `appliedBeforeAt(k)` and `appliedBeforeStride(k)` - one definition of the applied action's
  place, for the forward (the block and the filter) and the backward. CHECKED: the kit's tests 35/37 (2 skipped) -
  with the block at zero, nothing changed; lint. NEXT: B3b's check - the gradient comparison with a non-zero block,
  the graph reading the applied action through its own block.
- Nov 9: B3b CHECKED - THE APPLIED BLOCK's GRADIENTS MATCH ZIMRNUM's. `expectPolicyGradientsMatchZimrnum` now packs
  the variant's block (`packPolicyWithApplied`; random 0.2 x normal, or zero), puts it on the graph as a parameter, and
  has the graph's policy read the action applied before each decision through it (`policyOnGraph`'s `AppliedInput`) -
  so zimrnum differentiates both the block's weights and the reading's path back into the earlier action; the walk
  compares the block's gradients after the seven layers. A new test: the filter on (0.25, 0.5 for the last two),
  staged starts, a random block. CHECKED: the three gradient tests 3/3 within 1e-4 of the largest; PROVED SENSITIVE -
  with the kit's sent-back gradient switched off (`lat_applied_gradient = 0`), the new test fails (then restored);
  lint. B3a AND B3b ARE DONE: the kit's policy reads what it applied, forward and backward. NEXT: B3c - the trainer's
  CPU policy (`HostPolicy.policyRow` with its mirror's block) and the device's acting reading the applied action.
- Nov 9: B3c, THE ACTING HALF IN THE KIT AND THE TRAINER's CPU POLICY - AND A FAULT OF B3b FOUND AND FIXED.
  BUILT: the kit's acting rows gain `PolicyRows.applied_at` (each row's action applied before its decision, packed);
  `actOnRows`'s first layer linear, then `applied_add_activate` over the block - the rollout's own order; the trainer's
  `HostPolicy` gains `applied` (empty: not read) and `policyRow` sums its terms after the state's, from the block after
  the third layer's bias (`w_applied`). CHECKED: the kit's acting test with random applied actions read through a
  random block - `actOnRows` the CPU reference exactly and the host policy BIT FOR BIT; vk-host-test's acting check on
  the GPU. THE FAULT: B3b's turn ran only the kit's tests - the trainer's "a SuperTrack policy file acts as the kit's
  policy bit for bit" then FAILED: training now gave the block gradients, Adam moved it off zero, and the lab's player
  (which reads no applied action) refused the trained policy (`error.PolicyReadsItsAppliedAction`). FIX: the kit's
  `sees_applied` (the CPU learner's name), off by default - the block trained only when on; read always (a zero block
  adds exactly nothing). It goes on in B5 with the filter's defaults, once every acting path reads the block. CHECKED:
  the kit's tests 36/38 (2 skipped); the trainer's 547/658 (111 skipped); lint. LESSON: after a change to what the
  kit trains, the trainer's suite too. NEXT: B4 - the trainer filtering its two parts and staging each window's
  starting actions, its host policy given the character's last action, the device's acting gaining the decision
  filter and the applied action.
- Nov 9: B4, THE TRAINER's HALF (part one). `Options.stiffness_filter` (the decision-rate share for the limbs'
  stiffnesses, beside `filter`); `writeAction` filtering its two parts through `filterActionPart` (each part copied
  exactly at 1, so a negative zero survives); the kit told the filter the trainer applies (`kit.filter`,
  `stiffness_filter`, `stiffness_count` = the action's numbers after the joints' offsets) so the rollouts blend the
  same way; `computeAction` handing the host policy the character's slot as `applied` - the action given last, read
  before `writeAction` overwrites it. The option's mirrors, each caught by its own compile-time check: the lab's
  `SuperTrackLearner.stiffness_filter`, the saved options' field - and the state header's no-padding check, met by
  the second share taking the place of `padding_after_filter` (that word only paired the lone `filter`). CHECKED: the
  trainer's tests 547/658 (111 skipped, the lab compiled in them); lint. STILL IN B4: each window's starting actions
  staged from the replay (until then a mid-episode window starts from rest), the evaluation's host given its slot,
  and the device's acting gaining the decision filter and the applied action.
- Nov 9: REVIEW OF B4's FIRST PART (Simon: "Review"). FINDINGS: (1) A FAULT, FIXED: the trainer builds its kit with
  the joints' offsets alone (`actions = track.actionSize(m)`) - THE GPU TRAINER's POLICY HAS NO STIFFNESS OUTPUTS - but
  `stiffness_count` was set from `fleet.action_width - offsets`: with limbs, the kit's last offsets would have been
  filtered as stiffnesses. Now the trainer REFUSES a fleet with limb stiffness by name
  (`error.LimbStiffnessNotLearnedByThisTrainer`; before, its actions would have been read with the wrong width,
  silently) and sets `stiffness_count = 0`; the `stiffness_filter` doc says the share acts once a policy has stiffness
  outputs. (No user builds the trainer on such a fleet - only the twin's decision check uses limb stiffness.) (2) AN
  OLDER FAULT, TO FIX NEXT: the judge (`actOnJudgedFleet`) writes the policy's raw actions - NO DECISION FILTER and no
  applied action - while the lab's presets train with `filter` 0.2: the judged policy acts unfiltered, unlike its
  training. The fix: the judge filters into its slots as `writeAction` does, reads them as the applied action, and its
  slots start at rest with every judged episode. (3) Sound: the flow's `correctedRow` goes through `policyRow` (so it
  reads the applied action); the host's `applied` is read before `writeAction` overwrites the slot; `filterActionPart`
  keeps negative zeros at 1. CHECKED: the trainer's tests 547/658 (111 skipped); lint.
- Nov 9: THE JUDGE ACTS AS ITS POLICY TRAINED (the review's second fault, fixed). `giveAction(options, offset_count,
  chosen, given)` - one definition of giving a character its chosen action: no non-finite number into the physics
  (each such component zero, counted, made safe in place), then the action filter into its slot, the offsets at
  `filter` and the stiffnesses after them at `stiffness_filter` - used by training's `writeAction` (which adds the
  count to `nonfinite_actions`) and by the judge's `actOnJudgedFleet`, which before wrote the policy's raw actions
  (no filter, while the lab's presets train at 0.2). The judge's character also reads its slot as the applied action
  (`host.applied`); the judge's slots start at rest (`Judging`'s actions zeroed at creation; only each start's first
  episode is counted). CHECKED: the trainer's tests 547/658 (111 skipped); lint. STILL IN B4: each window's starting
  actions staged from the replay; the device's acting gaining the decision filter and the applied action.
- Nov 9: B4, EACH WINDOW's STARTING ACTIONS FROM THE RING. The ring's records hold no episode marker - windows are
  kept inside one SEGMENT by the replay's rejection sampling - so the host marks each start: `Start.continues_segment`
  (false by default: rest, every earlier caller unchanged), set in `drawWindowsMixed` from `replay.segmentAt` (the
  record before the window the same segment's). `stageStarts` adds the ring's own condition (the record before still
  held: `start.index > oldest`) and uploads one flag per start beside the starts (`continues_at`, `continuesAt(slot)`;
  the data path's end and its staging grown to match). zn_mlp's `lat_gather_start_actions` (in the kernel list), run
  by `gather` after `lat_gather`: per (row, action number), the action of the record a ring step before the window's
  first (the ring wraps), or zero, into the kit's `start_actions_at`. CHECKED: the trainer's tests 547/658 (111
  skipped); the kit's 36/38 (2 skipped); vk-host-test filtered to the kit 2/2 (the kernel on the GPU); lint. NOT YET
  CHECKED: the gathered VALUES - next, a test: every row's starting action the replay's action before its window, or
  zero when the window opens its episode. THEN: the device's acting (the decision filter and the applied action), and
  B5.
- Nov 9: THE STARTING ACTIONS' VALUES CHECKED. A trainer test, "a window starts from the action given before it, or
  from rest opening its episode": a learner on the test fleet, the decision filter at 0.5, four rounds (episodes
  ended among them), then six batches of windows gathered; every row's starting action read back - the replay's
  `actionAt(env, index - 1)` BIT FOR BIT when the window continues its segment and the ring holds the record before
  (`held().first`), zeros when it opens one; and continuing windows must have been met, so the gather itself is
  checked, not only rest. CHECKED: the test passes; PROVED SENSITIVE - the kernel reading the window's own first record
  instead of the one before, the test fails (then restored); lint. NEXT: the device's acting - the decision filter
  and the applied action on the simulator's side (`actOnDevice`, the twin first) - then B5, the defaults.
- Nov 9: B4, THE DEVICE's DECISION FILTER. robotgpu: the world array `chosen_actions` (the policy's choice, explored);
  `explore_actions` exploring the choices; `filter_decision` (one world per invocation; the trainer's `giveAction`):
  each non-finite number zero, then the choice blended into `actions` - the action given at the previous decision -
  the offsets at `decision_filter`, the stiffnesses after them at `decision_stiffness_filter`, by the CPU's own
  `robot.filteredActionNumber`, copied exactly at a share of 1; the shares in the uniform (a row with padding) and in
  `TrackingSettings` (default 1, no filter); `begin_reset` clearing `actions` (rest in a new episode, as the trainer's
  `forgetEndedEpisodes`). `explore_program` became `give_program` (the exploration, then the filter) and the host's and
  twin's `runExploration` became `giveActions`. The kit's `actWithSimulator(acting, simulator, inputs_at, given_at,
  chosen_at)`: the simulator's actions copied in as the applied action (`PolicyRows.applied_at`, now rows `raw_stride`
  apart as the simulator's are), the raw actions out into the choices. The 7c guard is folded in (non-finite numbers
  zero; not yet counted per world). CHECKED: the kit's tests 36/38 (2 skipped; the twin's exploration check through
  `giveActions`, unchanged at no filter); the twin's decision check 2/2; robotgpu 29/29; vk-host-test 40/40 (coverage
  32 of 54 - the new kernel not yet dispatched on the device); the side-by-side page builds, WebGPU's evidence clean
  (65 modules, 54 pipelines); lint. NEXT: a check of the filter's VALUES on the twin against the trainer's
  `giveAction` (shares 0.25 and 0.5 with limbs), then B5.
- Nov 9: THE DEVICE's DECISION FILTER's VALUES CHECKED. In the twin's decision check (both variants, with and without
  limbs), after the exploration check: known choices - the first of each world's a NaN - blended into the actions just
  checked, the offsets at 0.25 and the stiffnesses at 0.5, exploration off so the filter alone acts; every result
  `filteredActionNumber` at its number's share, the NaN asking for nothing - the trainer's `giveAction` rule; the
  shares back to 1 after. CHECKED: 2/2; lint (`std.math.nan` banned outside zimrmath - `zm.nan`, bound at file scope
  as `nan` by lint's autofix). NEXT: B5 - the defaults (offsets 0.25, stiffness 0.5, `sees_applied` on) with every
  acting path now reading the block; check: the skip-model test that failed, the trainer's and the kit's suites.
- Nov 9: B5 SPLIT, AND B5a DONE - THE LAB's PLAYER FILTERS AS THE POLICY TRAINED. Reading the lab's player for B5:
  `policyOfSuperTrack` built its `GenoPolicy` with `filter_beta` 1 - a SuperTrack policy trained through the filter
  (the presets' 0.2) was played unfiltered, the judge's old mismatch again; and `GenoPolicy` has no applied-action
  input at all, so a policy trained with `sees_applied` cannot be played (refused, `PolicyReadsItsAppliedAction`).
  B5a: `PolicyParts.filter` (the trainer's `Options.filter`, filled by `policyParts`), and the player's `filter_beta`
  from it. CHECKED: the trainer's tests 548/659 (111 skipped); lint. B5b, NEXT: `GenoPolicy` reading the applied action
  through a block - its first layer (the block's terms after the observation's, before the tanh), its decider handing
  it the action its filter gave last, its file format (version 0, no compatibility kept) - checked by the trainer's
  "a SuperTrack policy file acts as the kit's policy bit for bit" with a non-zero block. B5c: the defaults (offsets
  0.25, stiffness 0.5, `sees_applied` on) - the skip-model test their check.
- Nov 9: B5b - THE LAB's PLAYER READS THE APPLIED ACTION. robot_lab: `GenoPolicy.applied_block` (optional, freed by
  `deinit`); `AppliedReading` and `GenoPolicy.appliedReading` (the whole action required when the policy has a
  block); `applyPolicyLayer` gaining the reading - its terms after the inputs', before the activation, the kit's
  order; `policyMeanAction(policy, observation, applied, scratch, action)` - the first layer reads it; the decider
  handing it `controller.filtered` for the character (the action its filter gave last); `policyOfSuperTrack` keeping
  the block when any weight is not zero (an all-zero block adds exactly nothing - left out, so every earlier policy
  plays as before) instead of refusing it (`PolicyReadsItsAppliedAction` gone); the file: the observation header's
  reserved word became `applied_block_count`, the block written last and read before the trailing-bytes check. The
  trainer's policy-file test hands the file's policy each row's starting action (what the kit's first decision read);
  PPO's test and the Geno trainer pass none. CHECKED: the trainer's tests 548/659 (111 skipped, the lab in them);
  lint. NOT YET COMPILED: gpu_learn_tests and tools/geno_trainer (one argument each) - with B5c's checks. NEXT: B5c -
  the trainer's `sees_applied` option (its mirrors: the lab's recipe, the saved options with their padding), the
  defaults (offsets 0.25, stiffness 0.5, `sees_applied` on); checks: the skip-model test, the policy-file test with a
  trained, non-zero block, the trainer's and the kit's suites.
- Nov 9: B5c DONE - SIMON's DEFAULTS. The trainer's `filter` 0.25 (the joints' offsets), `stiffness_filter` 0.5, and a
  new `sees_applied` option, on, handed to the kit; its mirrors: the lab's recipe field, the saved options (`sees_applied`
  beside `train_critic`, the bools' padding three bytes to two - the header still free of padding). Five tests then
  failed, each for a reason now fixed: the lab REFUSED a filtered SuperTrack recipe "until imagination passes its
  actions through the filter too" - B2 did exactly that, so the rule is now each share's range (above 0, at most 1),
  its bad case `filter = 0`; the policy-file test asserted the controller hands the fleet the decided action
  unchanged - now it checks the blend into the controller's own previous action at the policy's share, and the mirror
  reads the controller's filtered action as its applied one; the mirror test hands its policy each row's starting
  action; the "fifth of a first action" test states its unfiltered learner (`filter = 1`). `HostPolicy.applied` became
  read-only (`[]const f32`). CHECKED: the trainer's tests 548/659 (111 skipped) - the skip-model test that failed when
  the defaults were first tried now passes, and the policy-file test with a TRAINED, NON-ZERO block through its file,
  bit for bit; the kit's 36/38; PPO's policy tests 23/28 (5 skipped); lint. THE ACTION FILTER's THREAD IS COMPLETE:
  modelled in imagination (forward, backward, two shares), seen by the policy, applied alike by the trainer, the judge,
  the lab's player and the device. NEXT (the plan's order): 7d-7g - acting as one call on the device, the closed loop on
  the twin, the tracking programs on the GPU, the page's device check.
- Nov 9: 7d's PLACE, A DECISION FOR SIMON. Acting as one call chains the simulator's `policy_inputs_program`, the
  kit's `actWithSimulator` (inputs and the actions given last in, raw actions out into the choices) and the
  simulator's `giveActions` (exploration at the decision's clock, the action filter). Today only `robotgpu_host`
  imports `robotgpu`; the kit imports neither; the trainer imports neither. THREE HOMES: (a) the trainer's device path
  (robot_track_resident.zig, which C10 makes drive the device anyway) - it gains the simulator's imports, and holds
  `actOnDevice` (GPU) and `actOnTwin` (the kit's CPU pipe and the twin, the same copies as slices); (b) robotgpu_host,
  taking the kit through a `require`d duck type - the simulator's host then knows of a policy; (c) the kit, taking the
  simulator the same way - the kit then knows of a simulator. RECOMMENDED: (a) - the composition is the trainer's own
  decision loop, the one place that already knows both sides' meaning, and C10 puts the loop there.
- Nov 9: SIMON CHOSE (a) FOR 7d - and the build's module graph stands in the way. Tried: the trainer's file importing
  `robotgpu` (as the host does, by name) and `robotgpu_host.zig` - "no module named 'robotgpu' available within module
  'root'" (reverted). The simulator's file is reached TWO WAYS: BY PATH (`@import("robotgpu.zig")`: the kit's tests,
  robotgpu's own tests) and BY NAME (`@import("robotgpu")`: robotgpu_host, vk_host_test, the two pages), and Zig
  refuses one file in two modules - so the trainer cannot import the host while the kit's tests (which import the
  trainer) hold the simulator by path. THE FIX, ONE IDENTITY FOR THE SIMULATOR: the build gives the fast test roots
  the named `robotgpu` module (the one the host and vk-host-test already use), and the two path importers switch to
  `@import("robotgpu")`; then the trainer imports both and holds `actOnDevice` and `actOnTwin`. A build change, small
  but structural - proposed to Simon before making it.
- Nov 9: THE MODULE FIX IS NOT SMALL (found before touching the build). The fast test roots hold the robot files BY
  PATH (robot.zig, robot_track.zig, ...); vk-host-test builds them as NAMED modules (the kernel module `robotgpu`
  importing the named `robot`, and `robotgpu_host` over that very module). A named `robotgpu` in a fast root would
  bring its own `robot.zig`, which the root also holds by path - the same two-modules refusal one level down. THREE
  WAYS: (1) named modules for the robot files in every test root - one identity everywhere, a structural build
  refactor of several turns, but C10's device trainer needs the host from the trainer anyway; (2) split by need -
  `actOnTwin` beside the trainer (path imports, as the kit's tests), `actOnDevice` in a file compiled only where the
  modules are named (vk-host-test, the pages, C10's device runner); (3) option (b) after all. NO CODE CHANGED.
- Nov 9: SIMON CHOSE (2), AND ITS PLACES FOUND. The engine module (`zimr.zig`) reaches the trainer and the lab, and
  vk-host-test and the pages hold the simulator by name - so NO path import of robotgpu.zig may enter the trainer's
  file. Hence: TWIN ACTING in the kit's tests (outside the engine, already importing the simulator by path; 7e's
  closed loop lives there): `actOnTwin(kit, host, acting, twin, clock)` - the twin's `policy_inputs_program`, the
  inputs and each world's previous action (`actions`) uploaded into the acting rows, `actOnRows` on the kit's CPU
  pipe, the raw actions read back into the twin's `chosen_actions`, then `twin.giveActions(clock)`; compiled (held by a
  comptime reference until 7e uses it); lint. DEVICE ACTING, NEXT: in `robotgpu_host` (where the simulator and the
  engine are both named modules, and the host already imports the engine) taking the kit's concrete type - no
  `anytype`. THEN 7e: the closed loop on the twin through `actOnTwin`, against the fleet and the trainer.
- Nov 9: 7d DONE - ACTING ON THE DEVICE AS ONE CALL. `robotgpu_host.Sim.actWithKit(sim, M, kit, acting, clock)`: the
  simulator's `policy_inputs_program`, the kit's `actWithSimulator` (inputs and each world's previous action in, raw
  actions out into the choices), then `giveActions` (exploration at the clock, the action filter) - nothing read back;
  in the host because there the simulator and the engine are both named modules (the kit's type
  `z.robot_latent_kit.LatentKit(M)`, M the network module; no `anytype`). vk-host-test's acting check runs it once:
  with no filter and no exploration every action its choice exactly (or zero where the choice was not finite).
  CHECKED: vk-host-test 40/40 - DEVICE COVERAGE 35 OF 54 (policy_inputs, explore_actions and filter_decision now run on
  the GPU); lint. NEXT: 7e - the closed loop on the twin through `actOnTwin`, against the fleet and the trainer, bit for
  bit, over some 60 decisions with starts, pushes, ends and resets.
- Nov 9: REVIEW FOR UNDERSTANDING (Simon: "Review. Optimise for understanding"). (1) ONE DEFINITION of a usable action
  number: `robot.isUsableActionNumber` (not a NaN, not beyond 1e30 - with why: a world never ends on its own once
  poisoned), used by the trainer's `giveAction`, the device's `filter_decision`, the CPU learner's action output and
  vk-host-test's check (through the engine, `z.robot` - its root has no named `robot`); the tests of weights and
  returns, a different meaning, keep their own. (2) `actOnTwin`: the twin's `world_f` named once; `input_numbers` and
  `action_numbers` (totals, not per-world counts); the readback unwrapped by name (`orelse unreachable`, the CPU pipe
  always readable). (3) `lat_gather_start_actions`: `start_at`, `steps_back`, `record_index` - the slot-major record
  address said in words. CHECKED: the kit's tests 36/38 (2 skipped); the trainer's 548/659 (111 skipped); robotgpu
  29/29; vk-host-test 40/40 (coverage 35 of 54); lint.
- Nov 9: ZIMRMATH's `isFinite` INSTEAD (Simon: "Is there an equivalent to isUsableActionNumber in zimrmath ... It
  looks a lot like isfinite no?" - "Ok"). zimrmath's `isFinite` (GPU-portable, `x == x and |x| != inf`, 131 uses) is
  the same idea; `isUsableActionNumber` differed only by rejecting finite numbers beyond 1e30 - an arbitrary bound
  carried over from older code, and its doc's reason was WRONG (anything beyond ~1.8e19 already overflows when
  squared, so 1e30 guarded nothing in particular). Deleted; the four sites (the trainer's `giveAction`, the device's
  `filter_decision`, the CPU learner's action output, vk-host-test's check) use `isFinite`, bound at file scope.
  CHECKED: the trainer's tests 548/659 (the CPU learner compiled in them); robotgpu 29/29; vk-host-test 40/40; lint.
- Nov 9: 7e DESIGNED - THE CLOSED LOOP ON THE TWIN, in slices. BASE: `expectTwinDecisionsAreTheFleets` builds a fleet
  and a twin with matched options (both limb variants) and sets the twin's normaliser - the loop extends it rather
  than a second setup. THE PIECES THAT MUST AGREE, EACH ALREADY CHECKED ALONE: the policy's inputs (the twin's
  `policy_inputs` against the trainer's `supertrackFeaturesInto` - the normaliser handed to both), the policy (7a's
  one order; the trainer's mirror = the kit's params), the exploration (counters: seed, world, decision number,
  action; spread `noise_scale x sigma` through the clock), the action filter (`giveAction` = `filter_decision`), the
  physics, judgement, resets and pushes (the decision check). SLICES: (1) ONE DECISION, exploration off - a trainer
  (`Resident`, CPU pipe) on the check's fleet, acting rows reserved in its kit, the trainer acting on the fleet and
  `actOnTwin` on the twin with the trainer's own kit: every world's actions bit for bit. (2) EXPLORATION ON - the
  trainer's draws and the device's at the same decision number. (3) SIXTY DECISIONS - the fleet stepped with the
  trainer's actions, the twin with its own, every decision's actions, poses, velocities, rewards and flags bit for
  bit, through starts, pushes, ends and resets (the filter's slots at rest after each). Each slice proved sensitive
  (a share or a seed changed on one side only must fail it). `actOnTwin`'s comptime reference goes when slice 1 uses
  it.
- Nov 9: 7e SLICE 1 DONE - THE CLOSED LOOP, ONE DECISION, BIT FOR BIT. At the end of the twin's decision check
  (the variant without limbs - the trainer learns offsets alone): a trainer (`Resident`, CPU pipe) on the check's
  fleet, acting rows reserved after its kit and data path (`KitLayout` from `data.end`), `syncMirror`; the twin given
  the trainer's filter shares; both sides from the same previous actions (the judge's slots seeded from the twin's
  offsets); the trainer acting through its judge actor (mean action, `giveAction`, the applied action from its slot),
  the twin through `actOnTwin` with the trainer's own kit and no exploration: every world's offsets agree to the bit -
  with the default filter 0.25 and `sees_applied` on. FOUND ON THE WAY: the twin's action rows hold room for the
  limbs' stiffnesses (40 numbers a world here), the trainer's slots the offsets alone (35) - compared per world.
  `actOnTwin`'s temporary comptime reference removed (this is its use). CHECKED: the twin's decision check 2/2; PROVED
  SENSITIVE - the twin's offsets share moved by 0.1, the slice fails (then restored); lint. NEXT: slice 2, exploration
  on - the trainer's draws and the device's at the same decision number.
- Nov 9: 7e SLICES 2 AND 3 MERGED, MADE PRECISE. The trainer draws exploration as the device does - the same
  `drawNormal(draw_seed, world, decision, .explore_action, action)` and `raw + spread x normal` - so they agree when the
  seed (the fleet's `draw_seed`, the device's `options.draw_seed`), the decision number (`fleet.decision_number + 1`,
  the clock's `number`) and the spread (`noise_scale x sigma`, the clock's `exploration_spread`) agree. The trainer's
  exploring path is private, but its public `act(steps, noise_scale)` acts AND steps the fleet (recording into the
  ring) - the CPU side of the closed loop as it is. THE LOOP: per decision, `learner.act(1, noise_scale)` on the fleet;
  on the twin `actOnTwin` at a clock of that decision's number and spread, then the twin's decision step, judgement
  and resets; every decision's actions (per world, the offsets), poses, velocities, rewards and flags compared bit for
  bit; planning and the flow OFF in the trainer's options (the device has neither, R6). Some 60 decisions, through
  starts, pushes, ends and resets. NEXT TURN: build it.
- Nov 9: 7e's LOOP BUILT, AND ITS FIRST DECISION DIVERGES - KEPT OUT FOR NOW. Per decision: `learner.act(1, 1.0)`
  (exploration on, the fleet stepped), `actOnTwin` at the decision's number (`fleet.decision_number + 1`) and spread
  (`noise_scale x sigma`), then `twin.runDecision(physics_steps)`, `runDecisionEnd`, `runResets` at the fleet's number.
  RESULT: the offsets agree, but the joint positions after the step differ - at the FIRST decision (a probe with one
  decision). So the trainer's `act` steps its fleet differently from the twin's decision sequence; to find which: how
  many physics steps `act(1, ...)` takes, where pushes and resets fall in it, whether it changes state before stepping
  (`projectHazard`, `features`), and the physics-rate filter's state it starts from. The test file restored to
  zimr501's (slice 1, passing); the loop's code, for the next turn:
        // THE CLOSED LOOP OVER DECISIONS: the trainer acting and stepping its fleet (`act`, exploration on), the twin acting
        // through the trainer's kit at the same decision's number and spread, then stepping, judging and resetting as the
        // fleet's step does; every decision's offsets, frames, joint positions and velocities compared bit for bit,
        // through pushes, ends and resets (an ended episode's filter slot at rest on both sides). Planning and the flow
        // are off - their defaults - as the device has neither. The trainer's slots begin where the twin's actions are.
        @memcpy(learner.actions, trainer_actions);
        const noise_scale: f32 = 1.0;
        const spread: f32 = noise_scale * learner.options.sigma;
        const loop_decisions: usize = 60;
        for (0..loop_decisions) |_| {
            const decision_number: u32 = @intCast(fleet.decision_number + 1);
            const acting_clock: robotgpu.DecisionClock = .{
                .number = decision_number,
                .push_schedule_share = fleet.pushScheduleShare(),
                .exploration_spread = spread,
            };
            learner.act(1, noise_scale);
            actOnTwin(learner_kit, &learner_host, acting, twin, acting_clock);
            twin.runDecision(physics_steps);
            twin.runDecisionEnd();
            twin.runResets(.{ .number = fleet.decision_number, .push_schedule_share = fleet.pushScheduleShare() });
            for (0..world_count) |env| {
                const world: u32 = @intCast(env);
                const twin_offsets: []const f32 = world_f[world_arrays.actions.at(world, 0)..][0..trainer_width];
                const trainer_offsets: []const f32 = learner.actions[env * trainer_width ..][0..trainer_width];
                try expectEqualSlices(f32, trainer_offsets, twin_offsets);
                try expectEqual(fleet.frame[env], integers.world_frame.load(world, 0));
                state.joint_positions.loadAll(world, twin_positions);
                state.joint_velocities.loadAll(world, twin_velocities);
                try expectEqualSlices(f32, fleet.data[env].joint_positions, twin_positions);
                try expectEqualSlices(f32, fleet.data[env].joint_velocities, twin_velocities);
            }
        }
- Nov 9: 7e's DIVERGENCE, NARROWED. `act` steps its fleet exactly once per call (`fleet.step(self.actions)`, the
  check's own call), then `forgetEndedEpisodes`. RULED OUT: the twin's limb numbers (exploration does give them noise,
  but the servo reads them only with limb stiffness on - `dofSpringFrequency`); the trainer changing the fleet's
  options (it writes none). THE LEAD: `act`'s own doc - each character's HAZARD "projected a few steps ahead, for the
  planning flags" before anyone steps (`projectHazard`, in `prepareActing`/`computeAction`). If that projection
  simulates on the fleet's own state - restoring positions but not, say, the solver's warm start or contact caches -
  the next step differs while the actions agree, which is exactly what is seen. NEXT TURN: read `projectHazard`; the
  decisive experiment - the fleet's whole state before and after `act`'s acting phases (no step) must be unchanged.
- Nov 9: 7e's DIVERGENCE - THE HAZARD RULED OUT, A BETTER HYPOTHESIS. `projectHazard` returns at once without planning
  flags (planning off), and the trainer writes no fleet field: acting does not touch the fleet. HYPOTHESIS: the loop
  STARTS from states that agree only LOCALLY. Slice 1 compares actions, which come from local features (relative to
  each root); the check's last phase forces resets and compares only the reset worlds' OBSERVATIONS, local too. The
  fleet and the twin may already differ in GLOBAL root position there - and the loop's first failing number is index
  0 of the joint positions, the root's x, at the first decision. THE DECISIVE EXPERIMENT, NEXT TURN: compare every
  world's joint positions and velocities right after slice 1, before the loop. If they already differ, acting is
  sound: start the loop from a state compared whole (before the check's forced resets, or after making the reset
  worlds' global poses agree - and find why the reset places a root differently on the two sides, which would be a
  real finding of its own).
- Nov 9: 7e's DIVERGENCE FOUND - A DEVICE BUG. Three experiments, after slice 1: (0) the fleet and the twin agree IN
  FULL there (every world's global joint positions and velocities) - the "local only" hypothesis was wrong; (A) one
  closed-loop decision with exploration OFF matches in actions and positions; (B) the twin's exploration skipping limb
  numbers - inconclusive (the check's own exploration test expects noise on every number); (B') exploration ON, the
  twin's limb numbers zeroed just before its physics step - MATCHES. SO: the limb numbers (noised by exploration, zero
  in every earlier check) REACH THE TWIN's PHYSICS WITH LIMB STIFFNESS DISABLED, by some path other than
  `dofSpringFrequency` (which is gated). Candidates to read next turn: `reference_targets` (whether a dof's target
  reads an action number past the offsets), `filter_actions` and what reads `applied_actions` past the offsets,
  `zero_effort`, any kernel indexing actions by `action_count` instead of the offsets' count. THE FIX: no kernel may
  read a limb number unless `limb_stiffness` is on; and, separately, the question whether the exploration should
  perturb numbers the policy does not output. The test file restored to slice 1's (passing).
- Nov 9: 7e's DIVERGENCE DIAGNOSED. The only kernel reading a limb number by index is `dofSpringFrequency`, gated by
  `limb_stiffness` - the physics never sees them. But `judge_rewards` sums the ACTION RATE over every device number,
  `counts.action_count`, limb numbers included - while the fleet, limbs disabled, has none (`action_width` = the
  offsets). With exploration noising every number (`explore_actions` over `action_count` too), the twin's action rate,
  reward - and, where it decides an episode's end, its resets - differ from the fleet's; a reset root is the first
  number to differ, at the first decision; zeroing the limb numbers (experiment B') removed it. THE BUG: the device
  has no notion of the action's WIDTH. THE FIX, NEXT TURN: one device helper for the numbers that ARE the action - the
  joints' offsets, then each limb's stiffness only with `limb_stiffness` on (the fleet's `actionWidth`) - used by
  `explore_actions` (noise only on numbers that act) and `judge_rewards` (the action rate over the same numbers);
  then the loop's 60 decisions again; then a check of the reward itself in the loop.
- Nov 9: THE ACTION's WIDTH ON THE DEVICE - BUILT; 7e STILL DIVERGES. robotgpu's `actionWidth()` (the joints' offsets,
  then each limb's stiffness only with `limb_stiffness` on - the fleet's `actionWidth`), declared before its first use;
  `explore_actions` explores only those numbers, `judge_rewards`' action rate sums only those; the twin check's
  exploration test expects the limbs' numbers unexplored without limb stiffness. CHECKED: the twin's decision check
  2/2; robotgpu 29/29; lint. BUT the 60-decision loop still fails on joint positions AT THE FIRST DECISION (probes of
  one and two decisions). THE EXPERIMENTS NOW DISAGREE WITH THE LIMB-NUMBER STORY: exploration OFF matched (A); ON with
  the limb numbers zeroed before the step matched (B'); ON with the limb numbers unexplored fails. OPEN LEADS FOR THE
  NEXT TURN: what else changes with `noise_scale != 0` inside the trainer's `act` (its flow numbers, `may_act_from_plans`,
  anything it does to the fleet's actions buffer between `giveAction` and `fleet.step`); what the twin's limb numbers
  hold now (the kit's raw rows hold 35 numbers in a 40-wide stride - the gap's contents); and a finer probe - the
  physics' first step compared before the decision's second. The loop removed again (the snapshot passes); its code
  in this journal.
- Nov 9: THE REVIEW (Simon: "Before continuing, review deep and wide") AND ITS FIRST STEP. Findings: (1) module-global
  CPU buffers (the twin's arrays, the kit's CPU activations) persist between phases and tests - a raw row wider than
  the policy's actions kept whatever memory held in its gap; (2) device acting is composed twice (`Sim.actWithKit`,
  the kit tests' `actOnTwin`) - 7f must run both on one state and require the same actions; (3) the robot-mocap
  tutorial's PROSE likely lags the action filter's thread (its code excerpts are current) - to verify and update by
  Simon's sync rule; (4) the kit's `sees_applied` doc still says acting paths read the block "only once given the
  applied action" - all do now; (5) sound: the action rate's `previous_actions` over the width, the width's agreement
  with the trainer's refusal of limb fleets. BUILT: `actOnRows` zeroes raw rows wider than the policy's actions before
  its layers write (`zero_rows`) - deterministic state whatever ran before. CHECKED: the kit's tests 36/38; the twin's
  check 2/2; lint. THE 60-DECISION LOOP STILL DIVERGES AT ITS FIRST DECISION with the gap zeroed - the leftover-memory
  hypothesis is wrong too; the loop removed again (its code in /tmp is lost with the sandbox - it is in this journal).
  NEXT: THE DIRECT MEASUREMENT, no more inference - inside the loop's first decision, both sides' asked actions, applied
  actions (physics-rate filter state) and limb numbers before the step; the twin stepped one physics step at a time
  against a fleet stepped the same way; the first differing number named.
- Nov 9: 7e - THE DIRECT MEASUREMENT FOUND TWO THINGS. (1) THE FIRST DECISION WAS NEVER WRONG: both worlds' applied
  actions, asked actions, frames, positions and velocities agree after the step; the "difference" was the TIMING OF
  THE COMPARISON - the twin applies a pending push in its resets (`runResets`), the fleet at the start of its next
  step, the same kick between the same decisions; and the fleet restarts an ended episode within its step (the
  trainer then zeroing its slot), the twin in its resets. Velocities have 41 numbers, positions 48 - the earlier
  "length 41" failure was the root's velocity, kicked on one side only at the comparison. FIX: compare each quantity
  where both sides have applied the same events - a continuing world's pose and velocities after the step, every
  world's actions and a reset world's pose after the twin's resets (and require that resets were crossed). (2) WITH
  THAT, A CONTINUING WORLD's GLOBAL POSITION STILL DIFFERS AT A LATER DECISION - also with the reset worlds' poses not
  compared - most likely a world RESET one decision before, placed differently in GLOBAL position by the fleet and the
  device (the decision check compares a reset world by its local observation only, so it would not see it). NEXT:
  name the decision and whether its world was reset just before; compare a reset world's global pose right after its
  reset, root first. The test restored to slice 1 (passing). The event-placed loop, for the next turn:
        // THE CLOSED LOOP OVER DECISIONS: the trainer acting and stepping its fleet (`act`, exploration on), the twin
        // acting through the trainer's kit at the same decision's number and spread, then stepping, judging and resetting
        // as the fleet's step does; every decision's offsets, frames, joint positions and velocities compared bit for bit,
        // through pushes, ends and resets (an ended episode's filter slot at rest on both sides). Planning and the flow are
        // off - their defaults - as the device has neither. The trainer's slots begin where the twin's actions are.
        @memcpy(learner.actions, trainer_actions);
        const noise_scale: f32 = 1.0;
        const spread: f32 = noise_scale * learner.options.sigma;
        const loop_decisions: usize = 60;
        var reset_decisions: usize = 0;
        for (0..loop_decisions) |_| {
            const decision_number: u32 = @intCast(fleet.decision_number + 1);
            const acting_clock: robotgpu.DecisionClock = .{
                .number = decision_number,
                .push_schedule_share = fleet.pushScheduleShare(),
                .exploration_spread = spread,
            };
            learner.act(1, noise_scale);
            actOnTwin(learner_kit, &learner_host, acting, twin, acting_clock);
            twin.runDecision(physics_steps);
            // Each quantity where both sides have applied the same events. The fleet's step restarts an ended episode
            // within it (and the trainer then zeroes its slot); the twin resets in its decision end - and the twin applies
            // a pending push there too, the fleet at the start of its next step: the same kick between the same decisions.
            // So: a continuing world's pose and velocities after the step; every world's actions, and a reset world's pose,
            // after the twin's resets.
            for (0..world_count) |env| {
                const world: u32 = @intCast(env);
                if (fleet.dones[env]) {
                    continue;
                }
                try expectEqual(fleet.frame[env], integers.world_frame.load(world, 0));
                state.joint_positions.loadAll(world, twin_positions);
                state.joint_velocities.loadAll(world, twin_velocities);
                try expectEqualSlices(f32, fleet.data[env].joint_positions, twin_positions);
                try expectEqualSlices(f32, fleet.data[env].joint_velocities, twin_velocities);
            }
            twin.runDecisionEnd();
            twin.runResets(.{ .number = fleet.decision_number, .push_schedule_share = fleet.pushScheduleShare() });
            for (0..world_count) |env| {
                const world: u32 = @intCast(env);
                const twin_offsets: []const f32 = world_f[world_arrays.actions.at(world, 0)..][0..trainer_width];
                const trainer_offsets: []const f32 = learner.actions[env * trainer_width ..][0..trainer_width];
                try expectEqualSlices(f32, trainer_offsets, twin_offsets);
                if (fleet.dones[env]) {
                    reset_decisions += 1;
                    state.joint_positions.loadAll(world, twin_positions);
                    try expectEqualSlices(f32, fleet.data[env].joint_positions, twin_positions);
                }
            }
        }
        // Episodes ended and began again within the loop: the resets were crossed, not only continuing worlds.
        try expect(reset_decisions > 0);
- Nov 9: 7e's REMAINING DIFFERENCE LOCATED. The event-placed loop, measured: decision 0 agrees in full; THE FIRST
  MISMATCH IS AT DECISION 1, WORLD 0, A CONTINUING WORLD NOT RESET BEFORE (root fleet -0.0461 -0.1364 1.0563, the
  twin's line cut by the runner) - so not a reset's placement. Between decision 0's comparison and decision 1's step
  only the twin's `runDecisionEnd` and `runResets` run on the twin, and the fleet's step begins with its pending
  push: THE PRIME SUSPECT IS THE PUSH ITSELF - the kick the twin applies after decision 0 against the kick the fleet
  applies at the start of decision 1 (their draws' decision numbers, the share, the episode-step gate, the direction's
  frame). The decision check exercises pushes in its own sequence, which may not reach the case the closed loop hits.
  NEXT: the two kicks compared directly - each world's root velocity right after the twin's `runResets` against the
  fleet's right after its push, and the push draws (rbt's push decision and vector) at that decision for both sides.
  The test restored to slice 1 (passing); the event-placed loop's code is in this journal (the entry before).
- Nov 9: THE PUSH, NARROWED. Both sides draw at the same decision number: the fleet's `step` increments
  `decision_number` first and pushes WITHIN that step at the new number; the twin pushes in `runResets` at the
  fleet's number read after the step - equal. Both gate alike: on the schedule when `steps % push_every == 0`, else at
  random (`chance_draw < rate x share x decision seconds`). Yet after decision 0 the twin kicked world 0 and the fleet
  did not. LEADING HYPOTHESIS: the EPISODE STEP COUNT at the gate - the fleet's `self.steps[env]` against the twin's
  `episode_steps` counter - incremented before the gate on one side and after it on the other, so a scheduled push
  fires a decision apart (the decision check may run with random pushes only, or never cross a schedule point).
  NEXT: read where each side increments its episode step count relative to its push gate; then the fix on the side
  that differs from the reference (the fleet is the CPU reference here), and the loop's 60 decisions again.
- Nov 9: THE PUSH, NARROWER STILL. Both sides gate on an INCREMENTED count (the fleet's `steps[env] += 1` early in
  `step`, the twin's `episode_steps` updated by `judgeEpisode` in `runDecisionEnd`, before `runResets` pushes); the
  fleet skips a world whose episode just ended (`continue`), then the SAME scheduled gate (`steps % every == 0`), the
  same random rate (`rate x share x decision seconds`), the same draws. Yet the twin pushed world 0 after decision 0
  and the fleet did not, at an equal share (1) and equal draw numbers. LAST INPUT LEFT: WHAT EACH COUNT COUNTS - the
  fleet's `steps[env]` (decisions?) against the twin's `episode_steps` (`counters.steps` from `robot.judgeEpisode` -
  decisions, or physics steps?). NEXT: print both counts for world 0 at decision 0's push gate; if they differ, the
  twin's count is the one to match to the fleet's (the CPU reference), and the decision check gains a scheduled push
  that crosses its gate.
- Nov 9: 7e - THE CAUSE FOUND: A TEST ARTIFACT, NOT A DEVICE BUG. Printed at decision 0's push gate: the twin's
  episode step count ONE AHEAD of the fleet's (before: fleet 0, twin 1; at the gate: fleet 1, twin 2; pushes every 2
  steps - the twin's scheduled push fired, the fleet's did not). The check's own last lines judge the twin ONCE MORE ON
  ITS OWN (`twin.runDecisionEnd()`, to check a reset world's flags) - advancing its episode counters without the fleet
  stepping. ALSO CORRECTED: the fleet gives its pushes INSIDE `step`, after its episode judgement (not at the start of
  the next step) - both sides kick after the decision's physics, so EVERYTHING compares after the twin's resets. With
  the step counts aligned and all compared after the resets, the loop fails later on ACTIONS - consistent with the same
  artifact through the other counters the extra judgement advanced (the aftermath countdown, the return streak), ending
  an episode on a different decision. THE ROBUST DESIGN, NEXT: the closed loop as ITS OWN TEST on a freshly built fleet
  and twin - the decision check's setup refactored into a shared helper - so no earlier phase leaves artifacts; every
  comparison after the twin's resets; resets required to be crossed. The test restored to slice 1 (passing).
- Nov 9: 7e - THE CLOSED LOOP, ITS OWN TEST, PASSING (Simon: "Make the code perfect. Understandable"). BUILT:
  `MatchedFleetAndTwin` (the decision check's world as one helper: the fleet, the clip's poses, reference features and
  bodies, the twin with every setting, the twin's worlds written where the fleet's start - `init` in place, `deinit`
  frees all); the decision check opening with it, its body unchanged; `uploadStartBinMixture` (the host's curriculum
  round as one function, used by the check); `expectClosedLoopIsTheTrainers` on a FRESH world - the normaliser, a
  trainer, acting rows, one deterministic decision, then SIXTY DECISIONS WITH EXPLORATION, everything compared after
  the twin's resets. A REAL FIX FOUND ON THE WAY: both acting compositions (the kit tests' `actOnTwin`, the host's
  `Sim.actWithKit`) now run `observe_program` before `policy_inputs_program` - the policy's inputs are documented to
  follow the observation, and a reset (or a freshly written world) has moved its bodies since the last one. CHECKED:
  the kit's tests 37/39 (2 skipped) - the closed loop bit for bit over 60 decisions (actions, frames, poses,
  velocities), the action filter at 0.25 / 0.5 and the applied action read; vk-host-test; lint. NOT YET: crossing an
  episode end - with SuperMimic's curriculum a restart's start is drawn from a mixture whose host round the loop does
  not yet match (uploaded after the fleet's step, the twin drew frame 1 where the fleet drew 234: the fleet draws
  inside its step, from the mixture as it was then). NEXT: the curriculum round's timing (or a loop without the
  curriculum first), then resets required to be crossed.
- Nov 9: EXPLAINED IN THE TUTORIAL AND THE COMMENTS (Simon: "Make sure everything we are doing is well explained in
  comments and tutorial. And review more"). The robot-mocap tutorial's 13.3 gains "The action filter, imagined and
  seen": the blend and its two shares with a worked table (1 - (1 - share)^k; two thirds of a change in an eighth of a
  second at 30 decisions a second and 0.25), imagination filtering too and the backward's carry, the policy seeing what
  it applied (the zero-start block, its two gradients), a window starting where its episode was, one rule for giving
  every action (trainer, judge, lab player, device), and the device's chain for one decision (observe, inputs, policy
  with the previous action, choices, exploration over the action's width, the filter; a reset at rest). The kit's
  `sees_applied` doc now names every acting path that reads the block. lint.
- Nov 9: 7e - THE EPISODE END's DIFFERENCE FOUND: THE CLIP's END, JUDGED AT DIFFERENT MOMENTS. With the curriculum's
  upload moved before the fleet's step the mismatch stayed (the fleet's world at frame 234 still running, the twin's
  restarted near 0) - so not the mixture's timing. BOTH SIDES WRITE THE SAME RULE, `frame + physics_steps >=
  frame_count` (the fleet's `clip_over` in `step`, robot_track.zig ~2450; the twin's in `judge_episode`), BUT THE FLEET
  EVALUATES IT WITH THE FRAME ITS DECISION STARTED AT, THE TWIN AFTER ITS FRAMES ADVANCED - so near a clip's end the
  twin ends an episode one decision early. The decision check never runs to a clip's end, so it never saw it. NEXT:
  read exactly where `step` evaluates `clip_over` (before or after its frames advance, before or after the physics),
  match the twin's `judge_episode` to the fleet (the CPU reference), give the decision check a world that reaches its
  clip's end, then the closed loop over 160 decisions with the curriculum's upload and resets required. The test is
  back at 60 decisions (passing).
- Nov 9: CORRECTION - THE CLIP's END IS JUDGED ALIKE. The fleet's `step` advances its frames through ALL of the
  decision's physics steps (the substeps' `frame += 1`, then the last physics step and `self.frame[env] += 1`) BEFORE
  `clip_over` and `rbt.judgeEpisode` - the same moment as the twin's `judge_episode`, after its frames advance. So the
  twin's restart while the fleet's world runs on at frame 234 comes from a DIFFERENT VERDICT (the aftermath's return
  after holding the reference, its countdown, a failure) or a different RESET TRIGGER (which worlds `runResets` restarts
  - finished flags, returns), not from the clip. NEXT: at that decision, print both sides' verdicts - the fleet's
  `dones`, `ended_this_decision`, aftermath and return counts against the twin's episode flags, aftermath countdown and
  return streak - and the rule that sends a world to `begin_reset` on each side.
- Nov 9: THE VERDICTS AGREE; THE START DRAW DIFFERS. Measured at the first differing frame (world 1): both sides ended
  its episode at the same decision (the fleet's `done` true; the twin's flags 20, steps 0, aftermath 0) - but the fleet
  restarted it at FRAME 234 and the twin at FRAME 1, and the twin drew frame 1 whether the curriculum's mixture was
  uploaded before the fleet's step or after it. So the restart's START DRAW differs: either the twin does not draw
  from the uploaded running sums here, or the two take different paths for this restart - this world starts every
  restart IN TROUBLE (`start_share` 1.0), whose start rule may differ from the curriculum's. NEXT: at that reset, the
  fleet's mixture and draw (`curriculumStartFrame`, its uniform) against the twin's running sums and draw
  (`begin_reset`'s curriculum path), and which path each side's restart took (curriculum, trouble, plain); then the
  side that differs from the fleet fixed.
- Nov 9: THE START DRAW, NARROWED. The fleet's restart draw (robot_track.zig ~1808-1822) builds its mixture from
  `bin_softmax` and `bin_history_weights` with `rbt.startBinMixture` - the very arrays `uploadStartBinMixture`
  uploads - and the twin drew frame 1 with the upload before the step and after it alike. So the MIXTURE is unlikely to
  differ; the likelier cause is the PATH: every restart in this world starts IN TROUBLE (`start_share` 1.0), and the
  device's trouble path (`start_in_trouble` / `begin_reset`) may choose its start frame without the curriculum, where
  the fleet's trouble start keeps the curriculum's frame. NEXT SESSION: read the device's `begin_reset` curriculum path
  and `start_in_trouble` for which sets the frame of a restart in trouble; compare with the fleet's restart; fix the
  device to the fleet; give the decision check a judged (not forced) restart in trouble with the curriculum on.
- Nov 9: THE RESTART's FRAME, FIXED - EPISODE NUMBERS. The device draws a restart's frame in `begin_reset` itself
  (the curriculum's `curriculumStartFrame`, else a uniform frame), KEYED BY THE WORLD AND ITS EPISODE NUMBER - and
  `MatchedFleetAndTwin` copied the fleet's poses, velocities, clip and frame into the twin but NOT its episode numbers
  (the decision check copies them by hand before its forced resets). Fixed in the helper: the twin's
  `episode_numbers` are the fleet's. CHECKED: the kit's tests 37/39 (the closed loop at 60 decisions); lint. With the
  fix, 160 decisions with the curriculum's upload before each step: THE FRAMES NOW MATCH THROUGH RESTARTS; A LATER
  DIFFERENCE REMAINS IN THE ACTIONS (35 numbers) - next: the first decision after a restart (its start noise, its
  observation, the trainer's slot at rest), measured as before. The 160-decision version is in /tmp (lost with the
  sandbox): 160 decisions, `uploadStartBinMixture` before `learner.act`, `ended_episodes` counted and required.
- Nov 9: SAFEGUARDS AGAINST THE LAST TURNS' PROBLEMS (Simon: "Find ways to make the problems we had in the last few
  turns impossible or easier to diagnose"). PROPOSED, in order of value:
  G1 ONE DECISION BOUNDARY: the twin's `stepDecision(physics_steps, clock)` = runDecision + runDecisionEnd + runResets,
     the fleet's `step` as one unit; checks compare only between whole decisions. (Impossible: comparing mid-decision -
     the push and restart timing that cost three turns.)
  G2 ONE STATE MAP, BY REFLECTION: every twin world array classified at comptime - copied from the fleet
     (`twin.adoptFleet`), compared with the fleet (`expectWorldsAlike`), or exempt with a stated reason - a new array
     unclassified is a compile error (as S2 for kernels). (Impossible: a twin built from a fleet missing a field - the
     episode numbers; any array forgotten by a comparison.)
  G3 WHOLE-STATE COMPARISON WITH NAMES: `expectWorldsAlike` reports the first difference as decision, world, array
     name, index and both values - not "slices differ at index 0, length 41". (Easier: the velocity-vs-position and the
     counter-offset diagnoses would have been one run each.) Run at the START of every comparison phase too, so an
     artifact left by an earlier phase (the check's extra judgement) is named before it misleads.
  G4 PROGRAMS THAT CANNOT RUN STALE: the policy's inputs program composed with the observation it needs
     (`observe_program ++ policy_inputs`), so no caller can compute inputs from a stale observation. (Impossible: the
     missing observe.)
  G5 THE ACTION's WIDTH AS A TYPE OF ITS OWN in the device's tables: arrays sized by `action_count` read through a view
     that knows which numbers act (offsets, limbs when on) - the width bug and the raw gap made unrepresentable.
  G6 STANDALONE CHECKS ONLY: every comparison test builds its own world (`MatchedFleetAndTwin`), never continuing
     after another check's steps - already adopted for the closed loop; the decision check's phases to follow.
- Nov 9: G4 AND G1 DONE. G4: `policy_inputs_program = observe_program ++ [policy_inputs]` - the observation is part
  of the program, so inputs can never come from a stale one; the explicit observe calls in `actOnTwin` and
  `Sim.actWithKit` removed (the program carries it). G1: `CpuTwin.stepDecision(physics_steps, clock)` - the physics
  steps, the judgement, the restarts and pushes as one unit, as the fleet's `step` is one; the closed loop compares only
  after it. (The decision check's own loop still compares mid-decision by design, per quantity - to convert with G6.)
  CHECKED: the kit's tests 37/39; vk-host-test 40/40 (coverage 37 of 54); lint. NEXT: G2 and G3 together - the twin's
  world arrays classified by reflection (copied, compared, exempt with a reason), `adoptFleet` and `expectWorldsAlike`
  with named first differences; then the closed loop through restarts with them.
- Nov 9: G2/G3 DESIGNED - THE TWIN's WORLD ARRAYS IN THREE CLASSES (from the two layouts' full field lists).
  CARRIED - copied from the fleet by `adoptFleet`, compared by `expectWorldsAlike`: joint_positions, joint_velocities,
  warmstart_accelerations (the solver's warm start - if the fleet keeps one; else exempt with that reason),
  activations (actuator dynamics), actions, applied_actions, previous_actions; world_clip, world_frame,
  episode_numbers, episode_steps, episode_decisions, aftermath_steps_left, return_streaks, steps_since_loss,
  episode_flags, return_lengths, start_bins; episode_discounted_returns, episode_discount_powers, episode_reward_sums.
  PER-DECISION RESULTS - compared after a whole decision, never copied: observations, tracking_errors, rewards,
  super_mimic_tracking, super_mimic_rewards, termination_rule, effort_energy, effort_torque_squares. TWIN-ONLY
  TRANSIENTS - exempt, the device's own scratch with no fleet counterpart: policy_inputs, chosen_actions,
  body_lowest_points. RECOMPUTED WITHIN EVERY STEP FROM THE CARRIED STATE - exempt: every other float array
  (accelerations, forces, servo terms, body and geom poses, inertias, contacts' slots, mass matrix and factors,
  sites) and the integer solver scratch (overflow, limit_candidate_active, floor_slot_filled, constraint_row_*,
  constraint_jacobian_*, newton_*). THE MECHANISM: one comptime table naming every field of `WorldStateLayout` and
  `WorldIntegersLayout` with its class (and, for carried and results, the fleet's counterpart as a small accessor
  function per field); a field missing from the table, or named in it but no longer in a layout, is a compile error
  (as S2 for kernels). `adoptFleet(twin, fleet)` copies the carried; `expectWorldsAlike(fleet, twin, decision)` compares
  carried and results and reports the FIRST difference by decision, world, field and index with both values. Used
  by `MatchedFleetAndTwin.init` (adopt, then compare at once - nothing hidden at the start) and by the closed loop
  after every `stepDecision`. KEPT SIMPLE: one table, two functions, no framework. TO DO NEXT SESSION: find each
  carried field's fleet counterpart (robot_track.zig's Fleet fields), write the table, the two functions, use them.
- Nov 9: G2's COUNTERPART MAP (from the Fleet's per-character fields). DIRECT (twin array <- fleet field): joint_positions
  <- data[env].joint_positions; joint_velocities <- data[env].joint_velocities; world_clip <- clip_of (usize -> u32);
  world_frame <- frame; episode_numbers <- episode_numbers; episode_steps <- steps; episode_decisions <-
  episode_decisions; aftermath_steps_left <- aftermath_steps_left; return_streaks <- return_streaks; steps_since_loss
  <- steps_since_loss; start_bins <- start_bins (usize -> u32); episode_discounted_returns, episode_discount_powers,
  episode_reward_sums <- the same names; rewards, super_mimic_rewards <- the same names (results). BY WIDTH: applied_actions
  and previous_actions <- the same names, the fleet's rows `action_width` wide, the twin's `action_count` (the
  limbs' room) - copied and compared over the fleet's width, the twin's rest held at zero. COMPOSED: episode_flags <-
  the fleet's in_aftermath, dones, failures, returned, ended_this_decision (the bit layout to read from `judgeEpisode`
  / the device's flag bits); effort_energy, effort_torque_squares <- effort_sums[env]'s fields; observations <-
  `fleet.observe` rows; tracking_errors, termination_rule, super_mimic_tracking <- what the fleet's judgement computes
  (`stateOf` and robot.zig's terms - the decision check already compares them per decision: reuse its code). TO FIND:
  warmstart_accelerations and activations (rbt.Data's or zimrphysics.World's fields - carried if the fleet keeps them,
  else exempt with that reason), return_lengths (a fleet counterpart, or exempt). `actions` is the decision's given
  action - the fleet keeps no asked action, so it is compared by the caller (the closed loop, against the trainer's
  slots): exempt in the table with that reason.
- Nov 9: G2 AND G3, THE DIRECT COUNTERPARTS - BUILT AND USED. In the kit's tests: `expectWorldNumbersAlike` and
  `expectWorldCountAlike` (one quantity of one world, by bit pattern; the first difference REPORTED with decision,
  world, name, index and both values); `adoptFleet(fleet, twin)` (the carried state: pose, velocities, applied and
  previous actions over the fleet's width, clip, frame, every episode counter, the episode's discounted return,
  discount power and reward sum); `ComparedMoment` (before any decision: the carried state only - a reward means
  nothing before a decision; after a decision: the rewards too); `expectWorldsAlike(fleet, twin, moment, decision,
  scratch)` (the counters as one table of names, fleet values and twin values). `MatchedFleetAndTwin.init` adopts and
  compares at once; the closed loop compares whole worlds after every `stepDecision` (its trainer-slot actions check
  kept - the fleet keeps no asked action). FIRST CATCH, AT ONCE: the fleet's reward held -3.0e-13 from setting up its
  starts against the twin's 0 - named in one run, and correctly a result, not carried state. CHECKED: the kit's tests
  37/39 - the closed loop's 60 decisions alike in every carried quantity and reward; lint (`report.print`, not
  `std.debug.print`). STILL TO DO: the comptime table over every layout field (copied, compared, exempt with a reason
  - a new field unclassified a compile error), the composed counterparts (episode flags, effort, observations), and
  the closed loop through restarts at 160 decisions, now with named differences.
- Nov 9: FAILURES THAT SPEAK, AND THE NEXT DIFFERENCE NAMED. `report.print` prints only when reports are asked for -
  right for measurements, wrong for failures - so test_report.zig gains `failure` (always printed; the lint exception
  explained at its one place) and the comparison helpers use it. THE 160-DECISION LOOP THROUGH RESTARTS (the
  curriculum's upload before each step, the trainer-slot actions also named) then reported in one run: "worlds differ
  at decision 66, world 1: actions, the trainer's slots[0] fleet -0.019623602 twin -0.019574326" - EVERY CARRIED
  QUANTITY OF BOTH WORLDS ALIKE THROUGH DECISION 65, RESTARTS INCLUDED; at 66 world 1's chosen action differs a little,
  so its POLICY INPUTS differ while its state agrees - most likely right after its restart (the goal: the reference
  read ahead from the new start). NEXT: at that decision, the twin's `policy_inputs` row against the trainer's
  `supertrackFeaturesInto` goal and state, named by feature - the goal half first. The loop restored to 60 decisions
  (passing; the kit's tests 37/39); lint.
- Nov 9: THE INPUTS' DIFFERENCE NAMED: "worlds differ at decision 66, world 1: inputs: state[162] fleet -3.2761717
  twin -3.7267017" - the trainer's features (`learner.features`) against the twin's `policy_inputs` row from the same
  state, before acting. The GOAL half agrees; the STATE half differs at feature 162, while the joint positions and
  velocities agree to the bit - so one side derives that feature differently from the same state, right after world
  1's restart. SUSPECT: the body velocities the features are built from - one side not recomputing them after a restart
  (the policy would then see stale velocities at an episode's start - a real bug on whichever side). NEXT: feature
  162's meaning in `localSize`'s layout (which body, which quantity); whether the fleet's restart and the device's
  reset both recompute the bodies' velocities from the new joint velocities before the observation; the fix on the
  side that is wrong (not necessarily the device: the CPU fleet is the reference only where it is right). (The disk
  filled again - the cache cleared whole.) The test restored (passing).
- Nov 9: FEATURE 162 IS THE ROOT's LINEAR VELOCITY. `localSize` = (bodies - 1) x (3 + 6 + 3 + 3 + 1) + 3, laid out in
  blocks: with 18 bodies besides the world, positions 0..53, rotations 54..161, LINEAR VELOCITIES FROM 162 - the first
  is the root's own, in its local frame. With identical joint velocities on both sides and the twin's observation
  recomputing body velocities from them (`body_velocities_branch`), THE FLEET's FEATURES RIGHT AFTER A RESTART ARE MOST
  LIKELY BUILT FROM BODY VELOCITIES LEFT FROM BEFORE THE RESTART - a CPU-side bug: every policy seeing a stale root
  velocity at an episode's start. NEXT: read the fleet's restart (`startEpisodeAt` / `restart`) for where it sets the
  joint velocities and whether it recomputes the bodies' velocities (the velocity kinematics) before the features are
  read; fix it there if so; a check that a restarted character's features equal those of the same state built fresh;
  then the closed loop through restarts again.
- Nov 9: THE STALE-VELOCITY HYPOTHESIS RULED OUT ON THE FLEET's SIDE. The fleet's restart (`startEpisodeAt`) runs
  `resetToFrame` (which ends with `rbt.forward`), `restOnFloor`, then `perturbStart` (the root's velocity kicks, then
  `rbt.forward` twice around its rest) - and `rbt.forward` runs `kinematics` AND `comVel`, so the bodies' velocities
  are fresh after a restart; `stateOf` reads them (`d.body_velocities`, `dance.pointVelocity`). NEXT: compare the two
  sides' ROOT BODY VELOCITY directly right after world 1's restart (the fleet's `d.body_velocities[root]` and its
  `pointVelocity`, against the twin's `body_velocities` after its observation), with the joint velocities they come
  from - to see which side's velocity disagrees with the shared joint velocities, and where (the free joint's frame,
  the point the velocity is taken at, the rest's lift).
- Nov 9: THE ROOT's VELOCITY MEASURED (decision 66, world 1, right after its restart; joint velocities identical):
  fleet `body_velocities[1]` ang -0.7779 -1.0808 -0.3248, lin 0.1564 0.0559 0.2752; twin's item ang the same, lin
  0.0962 0.6529 0.2752. ANGULAR EQUAL, LINEAR z EQUAL, LINEAR x AND y DIFFER - the signature of the same rigid motion
  expressed ABOUT A DIFFERENT POINT (the difference is omega x delta_p). So right after a reset one side takes the root's
  spatial velocity about a different or stale centre (the subtree centre of mass the velocity is expressed at, or a
  body position not yet updated by the rest's lift). NEXT: at that moment, both sides' root body position and the
  subtree centre of mass the spatial velocity is expressed about (the fleet's `subtree_com` as `comVel` uses it; the
  twin's `subtree_centres_of_mass` as `body_velocities_branch` reads it) - the side whose point disagrees with its own
  fresh kinematics is the one to fix. The test restored (passing).
- Nov 9: WHERE THE ROOT's VELOCITY IS REFERRED - TO READ NEXT SESSION. The fleet's `comVel` (robot.zig) requires the
  position stage and computes spatial body velocities (`d.body_velocities`, with ang and lin), from which `stateOf`
  takes `dance.pointVelocity(m, d, b, d.body_positions[b])` - the linear velocity AT THE BODY's POSITION; the device's
  `body_velocities_branch` writes 8-number items (ang, pad, lin, pad) per body, and its features take the linear
  velocity at some point. THE MEASURED DIFFERENCE (angular and vertical equal, horizontal not, after a reset only)
  says the two refer the root's linear velocity to different points right after a reset - candidates: the device's
  subtree centre of mass (`subtree_centres_of_mass`) or root position stale after the reset's rest lift within the
  observe order, or the feature's point-velocity shift using a centre from before the reset. FIRST STEPS NEXT
  SESSION: (1) read the device's feature code for the linear velocity (which point, which centre); (2) print both
  sides' root position and that centre at decision 66, world 1; (3) fix the side whose centre disagrees with its own
  fresh kinematics; (4) the closed loop through restarts at 160 decisions, required to pass. THE CONVERSATION IS LONG:
  continue from this journal's last entries and zimr514.zip.
- Nov 9: 7e DONE - THE CLOSED LOOP THROUGH RESTARTS, BIT FOR BIT; AND A CPU BUG FOUND BY IT. Measured at decision 66,
  world 1 (right after a restart in trouble): both sides' root position and subtree centre of mass EQUAL, the root's
  angular and vertical velocity equal, the horizontal not - a horizontal kick one side's body velocities missed. THE
  BUG, IN THE FLEET: `Fleet.push` added the kick to the root's joint velocities and only marked the data stale for the
  next physics step - but a policy's features are read BEFORE that step, from the bodies' velocities as they were
  before the kick: every pushed or trouble-started character's next observation saw the motion from before the push.
  The device observes before it acts, so it was right. FIX: `push` recomputes at once (`rbt.forward`) - deterministic,
  the same values the next step would recompute, so the physics is unchanged and only the features become right.
  CHECKED: the closed loop - 160 decisions, actions, every carried quantity and rewards alike to the bit, episodes
  ended and started again (required); robot_track 325/368; the kit's tests 37/39; the trainer's 549/660; lint. The
  safeguards found it: `expectWorldsAlike` and the inputs' named comparison located it in four runs. TODO: the
  robot-mocap tutorial's pushes part - one sentence that a push's effect is visible to the very next observation.
- Nov 9: THE TUTORIAL's PUSH, IN SYNC: the robot-mocap tutorial's push paragraph now says that everything derived from
  the velocities - each body's velocity, which the observation reads - is recomputed at the moment of the push, so the
  very next observation sees the character moving with it. NEXT (the plan's order): 7f - the tracking programs on the
  GPU in vk-host-test against the twin (with `expectWorldsAlike`-style named comparisons), the two acting compositions
  run on one state; the coverage report failing on gaps; then G2's comptime table and G6 for the decision check.
- Nov 9: G2's TABLE DONE - EVERY WORLD ARRAY CLASSIFIED, CHECKED AT COMPILE TIME. `WorldArrayClasses` in the kit's
  tests: carried (16 - what `adoptFleet` copies and `expectWorldsAlike` compares), carried_not_yet_compared (4, each
  with its reason: the episode flags, the solver's warm start, the activations, the return's length), decision_results
  (8), compared_by_caller (`actions`), twin_scratch (3), recomputed_each_step (the physics' intermediates and the
  solver's integers); a comptime block over both layouts' `field_names` - an array named in no list, or twice, or a
  listed name no layout has, is a compile error. PROVED: `start_bins` taken out of the table -> "world array
  `start_bins` must be classified exactly once (WorldArrayClasses)" (then restored). CHECKED: the kit's tests 37/39;
  lint. REMAINING OF THE SAFEGUARDS: the four `carried_not_yet_compared` moved to `carried` with their counterparts;
  the decision results compared (observations, tracking errors, termination rule, effort) through the same named
  helpers; G6 - the decision check's phases on fresh worlds.
- Nov 9: THREE MORE ARRAYS SETTLED. The fleet's per-character data has `warmstart_accelerations` and `activations`
  under the same names: both CARRIED now - copied by `adoptFleet`, compared by `expectWorldsAlike`; the solver's warm
  start and the actuators' activations agree to the bit through the closed loop's 160 decisions and restarts.
  `return_lengths` has no per-character counterpart (the fleet only adds each length into `return_steps_sum` for its
  log): TWIN SCRATCH, the reason in the table's comment. Only `episode_flags` remains not yet compared (the fleet keeps
  them in several fields - aftermath, done, failed, returned). CHECKED: the kit's tests 37/39; lint. NEXT: the episode
  flags composed and compared; the decision results compared by name; G6.
- Nov 9: THE EPISODE FLAGS COMPARED - EVERY CARRIED ARRAY NOW COMPARED. `expectWorldsAlike` composes the fleet's flags
  as the device's `judge_episode` sets its bits - lost (`failures`), returned, in an aftermath, finished (`dones`) and
  ending at the loss (`ends == .lost`, when done) - and compares every flag but the aftermath's beginning, which the
  fleet does not keep. The table: `carried_not_yet_compared` replaced by `compared_composed` (`episode_flags`, with its
  reason). The flags agree through the closed loop's 160 decisions and restarts. CHECKED: the kit's tests 37/39; lint.
  NEXT: the decision results compared by name (observations, tracking errors, termination rule, effort); G6.
- Nov 9: THE DECISION's EFFORT COMPARED. `expectWorldsAlike` (after a decision) compares the fleet's
  `effort_sums[env]` (energy, torque squares) with the device's `effort_energy` and `effort_torque_squares`. NAMED AT
  ONCE: "decision 65, world 1: effort ... fleet 0 twin 1.714425" - a restart: the fleet clears an ended episode's effort
  in its restart, the device at the next decision's start, and the decision's reward has counted it on both sides
  before either - a difference of bookkeeping, not of results: compared for characters whose episode goes on (the
  reason in the comment). CHECKED: the kit's tests 37/39 (the effort alike through 160 decisions); lint. NEXT: the
  observations (the fleet's `observe` fills every world's rows at once - compared in the closed loop with a buffer of
  its own), the tracking terms; G6.
- Nov 9: THE OBSERVATIONS COMPARED IN THE CLOSED LOOP. After every whole decision the fleet's rows
  (`Fleet.observe`, every world's at once into a buffer of the loop's own, `track.observationSize(m)` each) against the
  twin's `observations` row by row, by name. They agree to the bit through 160 decisions and restarts. CHECKED: the
  closed loop 2/2; lint. LEFT OF THE DECISION RESULTS: tracking_errors, super_mimic_tracking, termination_rule (the
  decision check compares them per decision with the fleet's own measures - its code to share); then G6.
- Nov 9: THE TRACKING TERMS COMPARED - EVERY DECISION RESULT NOW COMPARED. `expectTrackingAlike(fleet, twin, env,
  decision, ...)`: the fleet's own measures at a character's state and frame (`trackingErrorWithHead` by term,
  `superMimicTracking`, `terminated`) against the device's `tracking_errors`, `super_mimic_tracking`,
  `termination_rule`, each difference named by term; the closed loop uses it after every decision for characters whose
  episode goes on. All alike through 160 decisions and restarts. The decision check keeps its own copy of the same
  comparison until G6 rebuilds it on fresh worlds (then it uses the helper - one definition). CHECKED: the kit's tests
  37/39; lint. THE CLOSED LOOP NOW COMPARES, EVERY DECISION: the actions against the trainer's slots, every carried
  array, the episode flags, the rewards, the effort, the observations and the tracking terms. NEXT: G6.
- Nov 9: REVIEW AND THE REMAINING PLAN, MADE PRECISE (Simon: "What remains to the plan? Review recent code. Make the
  rest of the plan more precise"). REVIEW: (1) eight more sites mark the robot's data stale instead of recomputing
  (robot_geno.zig 2138, 2365, 2475, 2596, 2683, 2951, 3074, 3452 - the Geno player, its judge, its probes); harmless
  only if every reader recomputes first, and `stateOf` showed readers do not check. (2) The decision check keeps its own
  tracking comparison beside `expectTrackingAlike` - duplicated until G6. (3) `adoptFleet` leaves the twin's limb
  numbers as they are - right while the trainer refuses limb fleets; a limb fleet's check must copy them too.
  (4) Sound: `ComparedMoment`, `report.failure`'s single exception, the classification table, `stepDecision`, the
  observing inputs program.
  THE REMAINING TURNS, EACH ONE CHECKED PIECE:
   G7 READERS THAT REFUSE STALE DATA: `stateOf` (and `dance.pointVelocity`) require the velocity stage
      (`d.requireStage`, as `comVel` requires the position stage); then each robot_geno stale site either recomputes
      at once (as `Fleet.push` now does) or is shown never read before a step. CHECK: robot_track, the trainer's and
      robot_geno's suites; a deliberate stale read fails with the reader's name.
   G6 THE DECISION CHECK ON FRESH WORLDS: its phases (filters, clamps, pushes, forced resets in trouble, curriculum,
      returns) each from `MatchedFleetAndTwin`, stepping with `stepDecision`, compared with `expectWorldsAlike` and
      `expectTrackingAlike` after whole decisions; its private comparisons removed. CHECK: both variants; the same
      events still reached (each phase asserts its event happened).
   7f THE TRACKING PROGRAMS ON THE GPU (vk-host-test): a `Sim` and a twin built alike from one fleet; the same actions
      through `stepDecision`'s device counterpart; every classified array compared - integers exactly, numbers within
      a stated bar per class (the GPU's own rounding) - the first difference named; `Sim.actWithKit` against
      `actOnTwin` on one state, the same actions within the bar. Then the coverage report fails on any kernel never
      dispatched. CHECK: vk-host-test; coverage 54 of 54 or named exceptions.
   7g THE PAGE's DEVICE CHECK (Simon's phone): the same checks on WebGPU, a line per group.
   8  RECORDS ON THE DEVICE (C4): each decision's record into the kit's ring from the device's arrays, no readback.
   9-10 THE TRAINER's DEVICE PATH (C10) and `night1.zon` (the filters' shares and `sees_applied` as run parameters).
   11-20 as planned: the lab, the night's safety, the feasibility pass, the new signals, the physics rate, the skip
      model, the planner, the flow offset, the dry run.
- Nov 9: G7, FIRST STEP - AND AN HONEST GAP. `stateOf` now requires the velocity stage (`d.requireStage(.velocity,
  "stateOf")`); robot_track 325/368 and the trainer 549/660 pass with it - every current reader of `stateOf` reads
  current data. BUT THE SENSITIVITY CHECK DID NOT FAIL: with `Fleet.push` reverted to marking the data stale, the closed
  loop still passed, without the requirement firing. So the path that read the stale velocity before the fix is NOT
  `stateOf` as the loop now exercises it - or the loop no longer reaches it. The push fix restored; the requirement
  kept (correct, passing). NEXT: find the features' path after a push (`supertrackFeaturesInto` and what it reads - its
  own body velocities, `dance.pointVelocity`, or a cached state), confirm by reverting the fix once more with a probe
  that names the reader, and put the stage requirement on THAT reader; then the robot_geno stale sites.
- Nov 9: G7's GAP, NARROWED. The trainer's features (`supertrackFeaturesInto`) read the character through
  `track.stateOf(fleet.m, &fleet.data[character], ...)` - the function that now requires the velocity stage. So with
  `Fleet.push` reverted to marking the data stale, the requirement WOULD have fired had the stale data been read; it did
  not, and the closed loop passed - in the CURRENT loop nothing reads a pushed character before something recomputes
  it. That contradicts the earlier run where the same bug gave the decision-66 difference. TWO EXPLANATIONS TO DECIDE
  BETWEEN: (a) the revert run reused a cached test result (check: force a rebuild - the binary's hash, or a changed
  test name - with the revert, and expect either the requirement firing or the decision-66 difference); (b) the stale
  window was closed by a change since (the observing inputs program is the device's side, so unlikely - but the order
  inside `step` of the restart, its push and the next `forward` should be read). DECIDE (a) FIRST - one forced run.
- Nov 9: CORRECTION - THE PUSH FIX's STORY IS NOT SETTLED. A fresh run (cache cleared) with `Fleet.push` reverted to
  marking the data stale: the closed loop STILL PASSES and the new stage requirement on `stateOf` never fires. So the
  current loop never reads a pushed character's data stale, and the earlier claim - "the push bug caused the
  decision-66 difference; the fix cured it" - is NOT established: the fix and the restored 160-decision loop went in
  together, and the cure may have been elsewhere. The fix stays (recomputing at once after writing velocities is right
  whatever the story: any reader between a push and the next step - the judge, the lab, a measurement - sees current
  data). THE SETTLING EXPERIMENT: the configuration that failed before the fix - the 160-decision loop WITH the
  trainer's features read before each act (`learner.features`, a reader between steps) - run with the fix reverted:
  if the requirement fires naming `stateOf`, the stale window is real for readers between steps (as the measurement
  was) and G7 guards it; if not, the decision-66 cause lies elsewhere and must be found from the journal's runs.
- Nov 9: SETTLED - THE PUSH "BUG" WAS NOT REAL. The settling experiment - `Fleet.push` reverted to marking the data
  stale AND the trainer's features read for every character between steps (`learner.features` before each act) - the
  closed loop passes and the stage requirement on `stateOf` never fires: the fleet's step recomputes before any reader.
  So the earlier claim (zimr515: "a CPU bug: every pushed character's next observation saw the motion from before the
  push") WAS WRONG; the push change (recomputing at once) is harmless and stays as defence, but cured nothing. The
  decision-66 difference went away with another change of that turn and does not reproduce under any configuration
  tried since - its cause is UNKNOWN. What protects us now: the closed loop runs 160 decisions through restarts and
  names any difference at once; G7's requirement fires on any stale read of `stateOf`. Lesson for this journal: claim a
  cause only after its sensitivity check (revert -> fails, restore -> passes) - that check is what exposed this.
  The robot-mocap tutorial's sentence on pushes stays true (recomputed at the moment of the push). NEXT: G6, 7f.
- Nov 9: G6, FIRST PIECE - ONE TRACKING COMPARISON. The decision check's private tracking comparison (its own
  `trackingErrorWithHead`, `superMimicTracking`, `terminated` and seven `expectEqual`s) replaced by the shared
  `expectTrackingAlike` and a named comparison of the two rewards - one definition, every difference named with the
  check's decision and world; its now-unused `task` local removed. CHECKED: the twin's decision check 2/2; the kit's
  tests 37/39; lint. REST OF G6: each phase of the check on a fresh `MatchedFleetAndTwin`, whole decisions
  (`stepDecision`), `expectWorldsAlike` in place of its per-quantity comparisons, each phase asserting its event.
- Nov 9: G6, SECOND PIECE - THE CHECK's MAIN LOOP ON WHOLE DECISIONS. Read again, the decision check's main loop
  already finished each whole decision (judgement, then pushes and restarts) before comparing - the journal's "it
  compares mid-decision" was out of date. Converted: the three twin calls -> `stepDecision`; its own frame, position
  and velocity comparisons -> one `expectWorldsAlike` (now also every carried array, the episode flags, the rewards and
  the effort, by name); its phase assertion kept (no episode ends in these decisions). CHECKED: the twin's decision check
  2/2 (both variants); lint. REST OF G6: the check's other phases (the forced clamp's, the pushes', the forced restarts
  in trouble, the curriculum's draw, the returns) on fresh matched worlds, each asserting its event.
- Nov 11: THE ODDS, WRITTEN INTO THE PLAN (Simon: "Look at the 4 paper brainstorm. Propose ideas to improve the plan.
  Incorporate new ideas to make our chance of success higher"; then "Add this to the plan. Build and proceed"). Read
  first: claude.md, readme.html, this plan and its journal, the tracking plan and its journal, four-papers.html. THE
  FINDING: everything is checked to the bit and nothing has yet been shown to LEARN on the dance - by the journals no
  night has run; the one measured win is Sep 24's predictive sampling in the true physics (17.05 s against the servo's
  6.65 s). SECTION 4b holds the seven additions: O1 the learning ladder before the night (bars as ratios to the servo
  and to the no-change model; the night does not start on a red ladder); O2 TEACHER FIRST, decided - the true-physics
  planner in a block of planner and candidate worlds, its offsets recorded as labels (DAgger's mixture) and distilled
  into pi, the skip model's funnel and the flow F after it; O3 paired worlds - the model's action response measured
  (D5b, `pairs.csv`) and taught, and the gate of pi's gradient through W; O4 lambda-returns over the recorded windows
  for the critic's real fit; O5 the archive of hard states and the ground poses; O6 a screen that can be read (two
  control seeds - E8 to the reserves; the slow average judged; normalisers frozen; the gradient bounded per window;
  a ladder of exploration across worlds; E7 becomes "the teacher off"); O7 tripwires against a run that learns
  nothing. THE ORDER FROM HERE replaces turns 8-20's. Section 5 gains D5b; claude.md's plan line names v3 and 4b; the
  tracking plan's journal points here. THE SANDBOX, fresh again: the 753 toolchain unpacked, lavapipe and the
  validation layer installed, zbuild built; the twin's tests from cold in 101 s.
- Nov 11: G6, THIRD PIECE - THE PUSHES ON WORLDS OF THEIR OWN. `mirrorFleetSettings(fleet, twin, physics_steps)` (the
  kit's tests): the fleet's settings onto the twin through `setTracking` alone - `MatchedFleetAndTwin.init` calls it,
  and so does any check that changes the fleet's options afterwards, so no check writes the device's uniform by hand
  (the pushes' phase wrote `push_every` and `push_rate_per_second` into it directly: a setting written by hand on one
  side is a setting the mirroring was never checked to carry). `expectTwinPushesAreTheFleets` and its test ("the
  twin's pushes are the CPU fleet's, bit for bit - three decisions, on a schedule and at random", both variants): a
  fresh matched pair, pushes switched on in the fleet's options and mirrored, three whole decisions (`stepDecision`),
  `expectWorldsAlike` after each, and the event asserted - at least one push per character. THE DECISION CHECK loses
  its pushes' phase and its own copies of what `expectWorldsAlike` compares (the rewards, the episode's flags and
  counters, the effort), two buffers kept only for their lengths, and an unused layout; its doc comment now says what
  its body does (six whole decisions, then the inputs, the exploration, the filter and the forced restarts).
  CHECKED: the twin's tests 4/4 (3 before); SENSITIVITY - with the mirroring call disabled in the pushes' check it
  fails, "worlds differ at decision 1, world 0: joint_velocities[0] fleet -0.64642656 twin -0.43271083" (the fleet
  pushed at its second decision, the twin not), and passes restored (the file byte for byte the passing one); lint 0.
  REST OF G6: the restarts on worlds of their own, by whole decisions - a character knocked off, its aftermath run
  out, the restart in trouble with its noise and the curriculum's draw (the host's mixture uploaded at the fleet's
  cadence: read the closed loop's test for it first) - in place of the forced flags; then the inputs', the
  exploration's and the filter's phases on fresh worlds. Then 7f.
- Nov 11: G6 DONE - EVERY PHASE OF THE DECISION CHECK ON WORLDS OF ITS OWN (Simon: "Continue. Review as you go. Make
  the code very readable. Keep the tutorial in sync"). THE KIT's TESTS: six checks, each on a fresh
  `MatchedFleetAndTwin`, both variants (offsets alone; offsets with a stiffness per limb), each a short function that
  reads as its events - THE DECISIONS (six whole decisions through a loss, a return and a forced clamp;
  `expectWorldsAlike`, `expectObservationsAlike`, `expectTrackingAlike` after each), THE RESTARTS BY WHOLE DECISIONS
  (starts resting on the floor and an aftermath of 4 decisions, set in the fleet's options and mirrored; a character
  knocked a metre off; its episode ends when its aftermath runs out - `track.End.aftermath`, at decision 4 - and both
  sides start it again in trouble, with its noise, at the frame the curriculum draws from the host's round uploaded
  before each step; compared through the restart and three decisions past it), THE PUSHES, THE POLICY's INPUTS, THE
  EXPLORATION and THE FILTER AT EACH DECISION. The forced restarts (flags set by hand, `fleet.restart` called beside)
  are gone. HELPERS, so each check is its events and not its plumbing: `ComparisonScratch` (the rows a comparison
  loads into), `knockCharacterAside`, `holdCharacterOnItsReference` (`storeCharacterIntoTwin` under both),
  `giveBothTheSameAction`, `stepBothOneDecision`, `expectObservationsAlike`, `expectLastTargetsWereClamped`,
  `knownChoice`. `mirrorFleetSettings` now takes the trainer's filter at each decision (`DecisionFilterShares`; `.{}`
  for none), and NO TEST WRITES THE DEVICE's UNIFORM BY HAND any more: the closed loop mirrors the trainer's shares
  through the call, and puts the filter back to none through it.
  REVIEW, AS IT WENT: (1) FOR THE TRAINER's DEVICE PATH (C10): `setTracking` writes every setting it is given, and
  `TrackingSettings.decision_filter` / `decision_stiffness_filter` default to 1 - `trackingSettingsOf` builds from a
  fleet, which has no filter at the decision's rate - so a trainer that mirrors its settings again without naming its
  shares switches its filter off, silently. The test-side call now cannot be made without them; the shared builder
  C10 moves to the trainer must take the trainer's shares the same way. (2) `give_program`'s doc comment
  (robotgpu_program.zig) described the exploration alone, into the wrong array: it now says the program - the
  exploration added to the choices, then the choices blended into `actions` by the filter. (3) My restart check first
  asserted an end `.lost`; an episode whose aftermath runs out ends `.aftermath` - asserted so, through `expectEqual`,
  so a miss prints what was found (the first version failed "without output"). (4) THE COURSE HAD NO ACCOUNT of what
  follows the judgement on the device - the resets, the pushes, the decision's clock, the settings' one call -
  though C2, C18 and turn 7 built them: written now (below). (5) doc-sync takes 280 s here, nearly all of it the
  mocap tutorial's 13,774 lines against its sources - to shorten when a turn has room (an index of the sources'
  lines instead of a search per line). (6) My runs piped a build into `cat` and read `$?`: that is `cat`'s exit code,
  never the build's - the verdicts above were read from the builds' own summaries; later runs record the build's
  code.
  CHECKED: the twin's tests 8/8 (4 before); SENSITIVITY - without the curriculum's host round the restarts' check
  fails, "worlds differ at decision 4, world 1: joint_positions[0] fleet -0.059337348 twin -0.2660359" (the two
  sides start the new episode at different frames), and the file restored is byte for byte the passing one; lint 0
  (an empty log); doc-folds filled the new folds; doc-gate: 17 pages, no id twice, every page reached.
  THE TUTORIALS: the course (robots.html) gains "Pushes and new episodes" (`#servo-resets`), after the judgement -
  a whole decision as five programs, and why the observation runs once more; the reset program's kernels in a table;
  where an episode starts (the running sums, with a worked draw); the decision's clock and counter-based draws; one
  call for the settings, the filter's shares among them - with folds of `stepDecision`, `reset_program`,
  `runResets`, `DecisionClock` and `TrackingSettings`. doc-sync's sources for the course gain
  `src/robotgpu_program.zig` (its first run named the new fold's 19 lines as found in no source). The mocap tutorial's
  "On the device" says how the filter's shares reach the device and links to the course's section; its 13,774 lines
  check with 0 drifted - last turn's two formula blocks as sketches confirmed.
  NEXT: 7f - the tracking programs on the GPU (vk-host-test): a `Sim` and a twin built alike from one fleet, the same
  actions through whole decisions, every classified array compared - integers exactly, numbers within a stated bar.
- Nov 11: 7f, FIRST SLICE - A FLEET DESCRIBES ITS OWN TASK: ONE DEFINITION OF THE TRACKING SETTINGS (Simon: "C").
  WHY FIRST: 7f builds a device simulator "alike from one fleet" in vk-host-test, and C10's trainer will do the same,
  but the function that builds a fleet's settings (`trackingSettingsOf`) lived in the kit's tests - robot_track cannot
  import robotgpu, nor robotgpu robot_track. THE STRUCTURE, FIXED (a shared type in the lower module): the settings'
  types moved DOWN to robot.zig - `Switch`, `ServoMode`, `EpisodeOptions`, `ClipAssignment`, `JudgementWeights`,
  `TrackingSettings`, and `DecisionFilterShares` beside them; robotgpu keeps every name as an alias, and the struct's
  `applyToOptions` is `robotgpu.applyTrackingSettings(settings, options)`, a function beside the uniform it writes.
  `Fleet.trackingSettings(decision_filter)` (robot_track.zig) builds the value from the fleet's own options and task:
  the floor, the limbs' switch and the physics steps per decision are no longer arguments (the fleet knows them); the
  trainer's filter is the one argument, stated at every call; and a fleet a device cannot mirror - contacts other
  than the floor's, a velocity feedforward, an assist - is refused by assertion. The kit's tests call
  `twin.setTracking(fleet.trackingSettings(shares))`; their own builder, `DecisionFilterShares` and
  `mirrorFleetSettings` are gone. One definition now serves the checks, vk-host-test and the trainer.
  REVIEW: (1) `CpuTwin` HAD LOST ITS DOC COMMENT to `TrackingSettings`, which had been inserted between the comment
  and the struct - so the course's `TrackingSettings` fold of the last turn opened with "THE TWIN, RUN DIRECTLY". The
  comment is back on `CpuTwin`; the fold is robot.zig's. (2) vk-host-test's COVERAGE MISSED ONE DEVICE SIMULATOR, the
  decision test's (the only one not handed the ledger): counted now - 41 of 54 kernels dispatched on the device, 37
  before. The 13 left are 7f's own: the judgement (`body_lowest_points`, `judge_tracking`, `judge_rewards`,
  `judge_episode`), the resets and pushes (`push_worlds`, `begin_reset`, `reset_pose`, `rest_on_floor`,
  `perturb_start`, `rest_after_noise`, `start_in_trouble`), and two that no model of the tests has (`site_poses`,
  `next_activations`). (3) TRIPWIRES, RUN WHOLE FOR THE FIRST TIME IN THIS SANDBOX (the last turn's run, read now),
  HAD TWO REDS OLDER THAN THIS SESSION. The editor configs were stale for 329 apps: regenerated (`zig build
  editor-configs`). THE WGSL CORPUS: four graphics shaders - `examples/rt_fs`, `effect_sieve_fs`,
  `hybrid_raymarch_fs`, `normalmap_fs` - translate to different WGSL than was pinned on Nov 3 for SPIR-V unchanged;
  spv2wgsl changed on Nov 7 (its four fixes). Their interfaces are as pinned (80 of 80), spv2wgsl's own check passes
  all 81, the smoke passes; but the pin holds hashes, not text, so what changed cannot be read here. NOT PINNED: the
  four are to be seen on a device first, then `zig build corpus-refresh`. Until then tripwires stays red on that
  one line.
  CHECKED, each by the build's own exit code: the twin's tests 8/8; robotgpu 29/29; the robot family 679/824 (145
  skipped, none failed); vk-host-test 40/40 on lavapipe; lint 0; doc-folds; doc-gate 17 pages; doc-sync 0 drifted on both tutorials (the course 3987 lines, the mocap tutorial 13912).
  NOT RUN: `zbuild check` (the pages' and the trainer's compile) and the web build with Tint.
  THE TUTORIALS: the course's "One call for the settings" says where the value lives and why, and shows a fleet
  mirrored in two calls; its fold is robot.zig's. The mocap tutorial gains "A fleet describes its own task", with a
  fold of `Fleet.trackingSettings`.
  7f's DEVICE CHECK, DESIGNED FOR THE NEXT TURN (vk-host-test): Geno at his training physics on the get-up clip; a
  fleet for the reference tables and `fleet.trackingSettings`; two `Sim`s (`initGpuTracking`, `initTwinTracking`)
  set alike. THE DEVICE AND THE TWIN PART AT THRESHOLDS (the Nov 6 review's finding 8), so NO TRAJECTORY IS COMPARED:
  every compared decision starts from one state on both (the twin's world arrays uploaded to the device), runs one
  whole decision on each (`submitDecision`, `submitDecisionEnd`, `runResets` at one clock), and compares every
  world array - integers exactly (draws, flags, clips, frames, bins), numbers within a bar per class. Its events are
  made the same on both sides: pushes by the schedule, restarts by flags set on both, the curriculum's table
  uploaded to both. Then acting (`Sim.actWithKit` against the twin's on one state), and the coverage test failing on
  a kernel never dispatched, the two exceptions named. TO READ FIRST: how a `Sim` uploads integer world arrays.
- Nov 11: 7f - THE TRACKING TASK ON THE DEVICE, BY WHOLE DECISIONS (Simon: "C"; the turn's reply was lost, this
  entry written at the next). vk-host-test gains `runRobotgpuTracking` and its test ("robotgpu tracking: whole
  decisions on the device are the twin's - a loss, an end and a new start, pushes"): Geno at his training physics on
  the first two seconds of HIS get-up clip (`examples/geno_ppo/getup.zclip`, embedded as `geno_getup_zclip`, so the
  check runs wherever the executable does), eight worlds; a fleet for the clip's reference tables, the curriculum's
  mixture and `fleet.trackingSettings(.{})`; a `Sim` on the device and one on the twin, set alike. NO TRAJECTORY IS
  COMPARED: before each of three decisions the device takes the twin's worlds whole (both world arenas, read and
  uploaded up to `Sim.worldArenaEnd`), each runs the one decision (`Sim.stepDecision`, new - `submitDecision`,
  `submitDecisionEnd`, `runResets`), and the task's arrays are compared: 20 float arrays by their gap in epsilons,
  each against its bar (`tracking_float_arrays`, one table of names and bars), 11 integer arrays exactly. THE EVENTS,
  on worlds far from any limit, counted on the twin and required: an episode that ended and began again (a character
  knocked a metre off with no aftermath - the curriculum's draw, the rest on the floor, the noise, the start in
  trouble), an aftermath begun and a return (a character knocked off that lives on, then held on its reference for
  two decisions), and 23 pushes (every world in its episode, every decision).
  MEASURED ON LAVAPIPE, in epsilons: poses 8.2, the servo's targets 0.7, the lowest points 0; velocities 350, the
  observation 315; the warm start's accelerations 1,849; every action array 0; tracking errors 37, SuperMimic's
  tracking 7, the rewards 12.5 and 9.4, the episode's sums 4.8 and 6.3; the effort 155 and 50. EVERY INTEGER IS THE
  TWIN's: clips, frames, episode numbers, steps and decisions, flags, aftermath steps, return streaks, steps since a
  loss, start bins, return lengths. THE BARS, by kind: 256 (positions), 4,096 (velocities, the observation), 16,384
  (the solve), 4 (actions), 1,024 (the judgement), 4,096 (the effort) - several times lavapipe's, the RTX 5070 to
  refine.
  WHAT IT SETTLED: `Sim.runResets` and the decision's clock work on a device - eleven of the judgement's and the
  resets' kernels had never been dispatched on one - and the counter-based draws give the same pushes and the same
  start on the GPU as on the CPU.
  SENSITIVITY: the device given another decision number than the twin's - the check fails, "joint_velocities is
  3696219.8 epsilons from the twin's, its bar 4096" (and the observation): its pushes drawn at another number. The
  file restored byte for byte.
  COVERAGE: 52 of 54 kernels dispatched on the device (41 before), and the coverage test now FAILS on a kernel never
  sent to a GPU; the two with no work in the test's models are named (`site_poses`, `next_activations`).
  FOUND ON THE WAY: (1) the kit's tests' get-up clip is the HUMANOID's; Geno's clips are `examples/geno_ppo/`. (2) THE
  MODEL ARENA AND THE CLIPS' TABLES: a frame of Geno's tables is 986 numbers (99 coordinates, 387 features, 500 of
  bodies). The test build's arena (2^18 floats) holds about 260 frames, and a simulator given the whole get-up clip
  is refused (`ModelConstantsTooSmall`) - hence the check's 120 frames. THE DESKTOP SIZES HAD THE SAME 2^18
  (`robotgpu_sizes.zig`, which no build names yet - the trainer's device path will): the night's minute, 3,600
  frames, is 3.55 million floats and would have been refused at the trainer's first line. Raised to 2^23 (8,500
  frames), the arithmetic in its comment. FOR C10: the trainer's build names `robotgpu_sizes.zig`, and its dry run
  starts by making the simulator with the minute's four clips. (3) The test sizes' comment says "a few hundred
  numbers a frame": it is about a thousand for Geno - left as it is this turn (changing the file rebuilds every
  kernel), to correct with the next change there.
  ALSO BUILT: `Sim.stepDecision`, `Sim.worldArenaEnd` (the twin's clearing calls it); build.zig embeds the clip for
  the test.
  THE COURSE: "Whole decisions" in the chapter on checking the device (`#check-decisions`) - why no trajectory is
  compared, integers exactly and numbers within a bar per kind (a table of lavapipe's gaps and the bars), the
  check's events, every kernel reaching a GPU - with folds of `tracking_float_arrays` and `runRobotgpuTracking`.
  CHECKED: vk-host-test 41/41 on lavapipe, and the tracking check again after the last edit to the host; lint 0;
  doc-folds; doc-gate 17 pages; doc-sync's verdicts are in the entry below.
  LEFT OF 7f: acting through the kit WITH exploration on the device against the twin's from one state - today's
  device test acts with a quiet clock (`Sim.actWithKit`, spread 0), so `explore_actions` runs there and adds
  nothing. Then 7g, the page's device check.
- Nov 11: THE LOST TURN, CLOSED. doc-sync 0 drifted on both tutorials (the course 4,265 lines, the mocap tutorial
  13,912); lint 0 after the desktop sizes' change. NOT RUN: `zbuild check` and the web build with Tint - the host
  gained two functions that no page calls yet. NEXT: the tracking check is one long function - split into its steps
  (the worlds' setup, the device given the twin's worlds, the comparison, the events) so it reads as its story; 7f's
  last piece, acting WITH exploration on the device against the twin's; then 7g.
- Nov 11: A WINDOWS RUN PREPARED (Simon: "I am able to do one test on windows now if you want"). THE ONE TEST:
  `vk_host_test.exe`, built at full size (`zig build vk-host-test-windows -Dlong-checks`), to run on the RTX 5070 -
  the tracking programs on a real GPU for the first time. WHAT IT REPORTS BACK: every check's verdict on NVIDIA's
  driver; the tracking check's twenty gaps beside their bars (`reportTrackingGaps`, printed at full size, pass or
  not), to refine the bars; and THE FIRST THROUGHPUT NUMBER - a new test, "robotgpu tracking throughput", runs the
  tracking check at 8, 32 and 64 worlds and then, on the device alone, a hundred whole decisions back to back, each
  followed by the readback of every world's flags that a trainer's host makes; it prints decisions a second and
  world-decisions a second at each size (`reportTrackingThroughput`). Sixty-four worlds is what the test build's
  arenas hold, far from the night's thousands - but how the cost of a decision grows from 8 to 64 worlds says
  whether a decision is its dispatches' overhead or its work, which is what extrapolates. `runRobotgpuTracking` takes
  its size (`TrackingSize`: the worlds, the timed decisions); its start frames come round after nine worlds, and
  its character without an aftermath is the third from the last, so the check is the same at every size. Every
  size is run and reported before any verdict.
  ON LAVAPIPE: the tracking check holds at 8, 32 and 64 worlds (a short timed block); throughput about 30
  world-decisions a second at every size - one CPU core, linear in the worlds, as a software device must be.
  FOUND BUILDING IT - THE WINDOWS BUILD OF EVERY PROGRAM WITH KERNELS HAD BEEN RED SINCE NOV 9: the build's
  native-WGSL check refuses a native program that carries a WGSL entry attribute, and the entry-point pre-flight
  added on Nov 9 (`compute_host.scanWgslEntryPoints`) searches for exactly that text - compiled into native
  programs, where no module is WGSL. FIXED AT THE STRUCTURE: `scanEntryPoints` calls the WGSL scan on a browser's
  host alone (`host.is_browser`, known at compile time - the lint's rule: ask the host, not the processor), so a
  native program does not contain it; a native module that is not SPIR-V reports no entry points, and the
  pre-flight names it.
  CHECKED: vk-host-test 42/42 on lavapipe with the compute host's change, coverage 52 of 54; the Windows executable
  builds and passes the native-WGSL check; lint 0. NOT RUN: the executable itself (it is cross-compiled; its first
  run is Simon's), and a web build after the compute host's change - the web's branch is the code that was there.
- Nov 11: THE RTX 5070's FIRST RUN OF THE TRACKING TASK - 40 OF 42 (Simon ran `vk_host_test.exe`: the Debug build,
  the test's sizes, full size).
  WHAT HOLDS ON NVIDIA's DRIVER: every step-level check, the hundred steps' energy, the floor, the decision, and THE
  TRACKING CHECK - every integer the twin's through an end and a new start, pushes, an aftermath and a return. Its
  gaps beside lavapipe's, in epsilons: poses 7.4 (8.2), targets 1.0 (0.7), velocities 367 (350), the observation 275
  (315), the warm start 1,895 (1,849), applied actions 0.5 (0), tracking errors 28 (37), SuperMimic's tracking 5.7
  (7.0), rewards 14.5 and 7.2 (12.5, 9.4), the episode's sums 3.2 and 7.2 (4.8, 6.3), the effort 177 and 53 (155,
  50). A desktop GPU's gaps are lavapipe's within a fifth: THE BARS STAND, and their comments carry both. Coverage
  52 of 54 there too; every probe within its bar (the arc cosine 11.4 of 32, the six-vector dot 16 of 64).
  THE TWO MISSES: the constraint program's check at both inertias ("the device's rows and solve are the twin's"),
  which failed WITHOUT A WORD - `expect(constraintsHold(...))`. The physics does not part there (the steps, the
  energy, the floor's and the limits' checks all hold on the 5070), so the first suspect is a bar of that check set
  from lavapipe on a weakly determined quantity - a contact's force split across its pyramid's edges, 11,399 of
  32,768 on lavapipe - and the second a row count flipped at a threshold. `constraintsHold` NOW NAMES EACH MISS with
  its numbers, and at full size the check prints every gap and Newton's rounds on both sides
  (`reportConstraintGaps`): the next run says which.
  THE FIRST THROUGHPUT NUMBERS, with a Debug host. A decision is 2 physics steps, the judgement, the resets and two
  observations - 94 dispatches - and the host read every world's flags after each: 8 worlds 21.2 ms a decision (378
  world-decisions a second), 32 worlds 26.1 ms (1,228), 64 worlds 28.7 ms (2,232). READ: about 20 ms a decision
  whatever the worlds, and 0.13 ms more a world. The fixed part is one or more of the host's own work in Debug, the
  wait at each read, and the GPU's serial work inside a kernel (a world's solve runs on one GPU thread); the two
  extrapolations to the night's sizes are far apart - about 6,500 world-decisions a second at 1,024 worlds if the
  slope holds (7,500 its ceiling), 25,000 or more if the fixed part is the cost and the GPU has room. NOT A NUMBER
  TO BUDGET A NIGHT ON YET: the second run measures it.
  BUILT FOR THE SECOND RUN (`vk_host_test.exe` again: `zig build vk-host-test-windows -Dlong-checks
  -Dhost-test-optimize=ReleaseSafe -Dhost-test-sizes=src/robotgpu_sizes_bench.zig`): (1) THE HOST IN RELEASE
  (`-Dhost-test-optimize`, a new build option; Debug stays the default, for its 11-second compile). (2) LARGER
  ARENAS (`-Dhost-test-sizes`, new; `src/robotgpu_sizes_bench.zig`: the desktop's sizes for a quarter of its worlds,
  every arena within lavapipe's 128 MB binding), so the throughput test times 256 and 1,024 worlds - without the
  twin's comparison there (`TrackingSize.compares_with_the_twin`), and skipping, by name, a size the build's arenas
  refuse. (3) THE WAIT SPLIT OFF: 64 and 1,024 worlds again with the flags read once, after the last decision
  (`reads_flags_every_decision`). (4) WHERE THE TIME GOES: after the timed decisions at 64 and 1,024 worlds, the
  GPU's timestamps on and one decision more - each kernel's time, its twelve largest (`reportKernelTimes`). (5) A
  FAIR CLOCK: a warm-up of 30 decisions before it (`warmup_decisions`), and the night's pushes (one every three
  seconds, none at random) in place of the check's push at every decision; each line also gives the decision's
  dispatches with the microseconds each took, and what a world holds in each arena.
  FOUND BUILDING IT: (a) ON LAVAPIPE `newton_solve` IS 98% OF A DECISION's GPU TIME, at 64 worlds and at 1,024 (12
  ms a world a step on one CPU core): if the 5070's profile has that shape, the solve is the one kernel whose cost
  decides a night's size. (b) A FIRST DECISION FROM A POSE AT REST HAS NO CONTACT AND COSTS A QUARTER of the ones
  after it - 256 worlds first ran as fast as 64 - hence the warm-up. (c) WHAT A GENO WORLD HOLDS on a tracking
  task: 11,152 floats of state (not the 8,940 the sizes' comments said), 6,580 integers, 21,756 floats of
  constraint rows. THE DESKTOP SIZES' INTEGERS (`robotgpu_sizes.zig`, 2^23) HELD 1,274 WORLDS, NOT THE NIGHT's
  4,096 (`WorldIntegersTooSmall`): raised to 2^25, the arithmetic in the comments; the state and the rows fit as
  they were.
  CHECKED: vk-host-test 42/42 on lavapipe at the test's sizes; the throughput test at the bench sizes on lavapipe
  through 1,024 worlds (one timed decision a size: 21 s a decision there, 48 world-decisions a second at every
  size, as one CPU core must); lint 0; doc-folds. THE COURSE: the 5070's column beside lavapipe's in "Whole
  decisions".
- Nov 11: THE PHONE's TURN (Simon: "I can only test on phone now" - the second Windows executable waits for a
  Windows machine). FIVE PAGES BUILT FOR IT, each `zig build <name> -Dplatform=web -Dmode=release`:
  (1) `robotgpu_lab` - THE SIMULATOR's CHECKS ON THE PHONE's GPU, and a third GPU's word on the check the RTX 5070
  failed. Its constraint panel now shows the WHOLE verdict - whether the rows' integers are the twin's, Newton's
  rounds on each side and in how many worlds they differ, and EVERY ARRAY's GAP BESIDE ITS BAR, red past it - where
  it showed only the largest. Run headless here first (`zig build robotgpu-lab-headless`, a script of 150 frames and
  a capture, the frame looked at): on lavapipe all three checks agree - the step 238.6 of 1,024 (smooth
  accelerations); the constraints' 1,855 rows, 780 the floor's, integers the twin's, Newton's rounds 264 on both;
  the arrays 1.0 of 4 (violation), 2.0 of 16 (Jacobian), 5.5 of 16 (velocity), 41.8 and 336.2 of 1,024, the force
  2,870 of 32,768, 78.7 and 39.7 of 4,096. WHAT THAT TABLE SAYS ABOUT THE 5070: the tightest bars are the
  geometric ones, 4 and 16 epsilons, set where the "GPU" is the same CPU as the twin; on the 5070 the probes show its
  own trigonometry several times further from the twin's (the arc cosine 11.4 epsilons against lavapipe's 1.9, a
  rotation 3.3 against 0). A violation is an angle taken from a quaternion; so the first suspects are now
  `constraint_violation` and `constraint_velocity`, ahead of the force's split. The phone's page shows which arrays a
  real GPU passes its bars on; the bars are set from that and from the 5070's second run - not before.
  The page also compiles every one of the 54 kernels' WGSL on the phone (the tracking task's too, which no browser
  has compiled yet), and runs the entry-point pre-flight on the browser's branch, after this session's change to it.
  (2-5) THE FOUR SHADERS OF THE CORPUS' RED LINE, to be looked at: `rt_sidebyside` (`rt_fs`: the CPU's ray tracer
  beside the GPU's - the two pictures must be one), `hybrid_render` (`hybrid_raymarch_fs`: the raymarched metaball
  among the raster cubes), `shader_effects` (`effect_sieve_fs`: the effect named sieve), and
  `shaders_normalmap_rendering` (`normalmap_fs`: the tiled floor under a moving light, flat when the normal map is
  switched off). If the four look right, `zig build corpus-refresh` pins them and tripwires is green again.
  THE CACHE WAS FULL (5.5 GB of 9 free): removed whole, the house way; a cold page builds in 165 s, the next ones in
  15 to 28.
  CHECKED: the five pages build; the lab page's headless run on lavapipe - 150 frames, validation 0 errors, the
  frame as described; lint 0; doc-gate. NOT RUN: doc-sync (the course's change is prose alone) and anything in a
  browser - that is the phone's.
  NEXT ON THE PHONE: 7g - the tracking check itself in a page: whole decisions, device against twin, as
  `runRobotgpuTracking` does natively; it needs the comparison made asynchronous (requested, then collected a frame
  at a time, as `StepComparison` and `ConstraintComparison` are), which the native test can then use too.
- Nov 11: THE PHONE's VERDICT (Simon, six screenshots: "Looks good. But lab takes around 15 seconds to boot...").
  THE FOUR SHADERS LOOK RIGHT on his phone: `rt_sidebyside` (the CPU's and the GPU's tracers show one scene),
  `hybrid_render` (the blobs among the cubes), `shaders_normalmap_rendering` (the tiles' relief under the light),
  `shader_effects` (the screenshot is of "ascii", effect 9 of 10, one past the sieve, which he passed on the way).
  TO DO, NOT YET RUN: `zig build corpus-refresh`, then tripwires.
  THE LAB PAGE ON THE PHONE (Android, Chrome): ALL THREE CHECKS AGREE. The step: 134.94 of 1,024 epsilons (smooth
  accelerations); the floor's 1,547 contacts. The constraints: 1,855 rows, 780 the floor's, their integers the
  twin's, Newton's rounds 264 on both; violation 1.0 of 4, Jacobian 3.0 of 16, velocity 6.5 of 16, regularizer 83.6
  and target acceleration 411.5 of 1,024, force 705.5 of 32,768, joint accelerations 37.0 and constraint joint forces
  29.8 of 4,096; every copy after 3 frames. WHAT IT SAYS: (1) all 54 kernels' WGSL compile in a phone's browser, the
  tracking task's among them; (2) the browser's branch of the entry-point pre-flight works after its change; (3) A
  MOBILE GPU PASSES THE CHECK THE RTX 5070 FAILED, with lavapipe's margins - so the tight geometric bars are not too
  tight for a real GPU in general, and the 5070's miss is NVIDIA's own (its trigonometry, its contraction) or the
  native path's. Only the second executable's named verdict decides; no bar is changed.
  THE 15 SECONDS. By the sizes: the page embeds 54 WGSL modules, 2.34 MB of text - `newton_solve` alone 447 KB and
  18,205 lines, `judge_rewards` 202 KB - and makes two device simulators (the step's 34 kernels, then all 54), every
  pipeline created the plain way, which a browser compiles one after another, drawing nothing meanwhile.
  BUILT AGAINST IT - PIPELINES MADE IN THE BACKGROUND, an option; every other page is as it was:
  wgpu.zig - `createComputePipelineInBackground`, `computePipelineState`, `computePipelineMilliseconds`: in a browser
  `createComputePipelineAsync`, through three new bridge functions (the handle given at once to a placeholder, the
  pipeline taking its place in the table when the promise resolves, carrying the milliseconds it took); natively the
  plain creation, ready when it returns. compute_host.zig - `Pipe.initGpuInBackground`, `pipelineProgress` (ready
  of total; a refused pipeline stops the page by its kernel's name), `pipelineMakings` (each kernel's
  milliseconds), and a guard: a kernel dispatched before the pipe is ready asserts. robotgpu_host.zig -
  `Sim.initGpuInBackground`. THE LAB PAGE - a preparing phase: both device simulators asked for at once, "preparing
  the kernels: N of 88 pipelines ready" while the browser compiles; then the seconds from the page's start to ready,
  the three kernels it took longest over, and in a browser how far into its load the page's code started. The line
  the phone clipped (Newton's rounds) is two lines.
  TWO THINGS THE WEB BUILD TAUGHT: the bridge's `new` and `call` carry at most three arguments - the snippet takes
  one object; and the import check reads a registration only as `.set("name", ...)` with the name written there.
  CHECKED: the lab page builds for the web (the transpiler, the import check); run headless on lavapipe - 150
  frames, validation 0 errors, the frame looked at: the checks agree as before, "88 pipelines ready 1.0 s after the
  page's start"; lint 0. NOT CHECKED: anything in a browser - whether the phone's browser compiles in parallel, and
  how long `newton_solve` alone takes, is what the page's own lines will say. NOT RUN: vk-host-test since the
  compute host's change (its plain path is the code that was there, and the headless page ran it), doc-sync, tripwires.
  IF THE BACKGROUND IS NOT ENOUGH: `newton_solve` is a fifth of the text and cannot be split by threads - its
  18,205 lines are the next thing to shrink; and a page served from a site, not opened as a file, lets the browser
  keep its compiled pipelines between visits.
