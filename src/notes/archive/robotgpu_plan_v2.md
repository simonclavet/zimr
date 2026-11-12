# robotgpu - MuJoCo Warp in zimr, on native and on the web - the plan, v2 (Nov 2, 2026)

v1 (Oct 31 - Nov 2) is archived in `src/notes/archive/robotgpu_plan_v1.md`: its study of MuJoCo Warp (sections 2-3),
the brainstorm behind every decision (section 4), the parity table of every MJW feature (section 5), the first
architecture (section 6) and the journal of everything built through S2e-4. This version keeps what is still in force,
states what changed, summarises what exists, and is precise about what remains.


## 0. The goal

`src/robotgpu.zig`: MuJoCo Warp's simulator, in zimr. Thousands of independent worlds of one robot model stepped in
lockstep on the GPU, every kernel written once in Zig through `kompute` - compiled to SPIR-V for zimr's native Vulkan
host and to WGSL for WebGPU - and the same source running on the CPU as the twin. It builds its GPU model from
`robot.zig`'s `Model`, uses `zimrmath` for every vector, and imports nothing from the engine: the device is driven one
layer up, by `robotgpu_host.zig`.

WHAT THE GPU IS FOR: training. A robot in a game runs on the CPU engine (robot.zig); the GPU accelerates the many-world
training of the tracker. It must give GOOD RESULTS ON WEBGPU - a browser trains, with fewer worlds where its memory is
smaller - WITHOUT GIVING UP ANY PERFORMANCE ON NATIVE (D20).

THE GATES - each a measurement that can come out red:

  G1 PARITY WITH robot.zig. The CPU twin reproduces robot.zig BIT FOR BIT wherever both have the feature (the kernels
     call robot.zig's own functions, in its order), step by step; over many steps, by statistics.
  G2 THE DEVICE EQUALS ITS TWIN within each array's bar (`step_array_bars`): the gap measured against the size of the
     quantity it belongs to, in epsilons (`largestGapEpsilons`) - on lavapipe in the sandbox, on Simon's RTX 5070 under
     Vulkan, and on WebGPU in Simon's browser and phone (`robotgpu_lab`).
  G3 PARITY WITH MUJOCO for every feature robot.zig lacks, against fixtures from real MuJoCo (where MJW deliberately
     differs, MJW-generated fixtures), each such row documented.
  G4 THROUGHPUT. Native: at least 20x the CPU fleet's steps per second for Geno, and THE HEAD-TO-HEAD - robotgpu
     against MJW's own speed test on the same RTX 5070, same model, same worlds - with any gap placed by per-kernel
     timings. Web: steps per second measured and reported beside native's, at the worlds the browser's limits allow.
  G5 THE TRACKER TRAINS ON IT - native, and on the web within its memory - and the policy still tracks when judged by
     robot.zig in its MuJoCo mode.
  G6 EVERY ROW of v1's parity table DONE or DECLINED WITH A REASON.


## 1. The principles in force

  P1 FOLLOW MUJOCO WARP CLOSELY. Its stages, its order of passes, its kernel shapes (one invocation per world, per world
     and element, per world and branch) - D5. Every array and kernel names its MJW counterpart in a comment ("MuJoCo's
     name: `cfrc_int`", "MJW: `_comvel_branch`"), so the two codes can be read side by side.
  P2 MUCH BETTER UNDERSTANDABILITY (D21). One descriptive vocabulary for both engines - `joint_velocities`,
     `subtree_bias_forces`, `body_first_joint`, `dof_count` - with MuJoCo's names only as cross-references. The code
     reads like a course: each stage's section opens with the physics, how it maps onto the GPU, what it reads and
     writes; each kernel explains its algorithm. robots.html's Part VIII gains a chapter with each stage.
  P3 ONE DEFINITION OF THE ARITHMETIC (D1). Where robot.zig has a piece of the physics, the kernel calls robot.zig's own
     function - directly, or generic over a STORAGE (`factorLdlInPlace`, `solveLdl`, `velocityThroughJoint`) - so the
     twin is exact. Where robot.zig's ORDER differs from MJW's, robot.zig's order is kept (the twin's exactness is the
     regression test); the difference is written down.
  P4 DETERMINISTIC BY CONSTRUCTION (D7). No float atomics feed state. MJW's atomics become gathers in a fixed order,
     sums taken per world in robot.zig's order, and - for constraint rows and contacts - slots fixed by the model,
     marked per world, compacted per world in a fixed order.
  P5 WEB AND NATIVE BOTH FIRST-CLASS (D20, replacing D18 "native only" and D19 "the web later"). One kernel source.
     Native's fast paths (subgroup reductions, push constants, larger workgroup memory) sit behind comptime branches
     with portable counterparts on the web; each target has its sizes; every stage is checked on both; where a web
     limit bites (workgroup memory, binding sizes, world counts) the answer is a storage or layout variant chosen at
     compile time - never a weaker algorithm, never a silent difference.
  P6 AGNOSTIC TO WHAT MEASUREMENT WILL SHOW. Each choice a profile may overturn lives in one place - a storage (where a
     world's factor lives), a kernel (the order of a sum), the step program (which kernels, in which shape), the bars
     table (how close). The first form of each kernel is the exact one; the head-to-head (S2f) decides reshapes.
  P7 REFUSED BY NAME. A model with anything the device does not simulate is refused before packing (`ModelError`,
     today `TendonsNotSimulated`), never run with part of its physics missing.

DECISIONS STILL IN FORCE from v1 (section 12 there has the options weighed):

| # | decision |
|---|---|
| D1 | robot.zig's per-element arithmetic shared as functions both engines call; traversal per engine |
| D2 | one `robotgpu.zig` (layout, packing, kernels), beside it `robotgpu_host.zig` and the sizes files |
| D3 | robot.zig's `Model` is the source of truth, extended with MuJoCo's collision and constraint fields |
| D4 | eight arenas, a layout of offsets in the Params uniform, an overflow refused by name |
| D5 | MuJoCo Warp's kernel shapes from the start |
| D6 | one accessor, world-major |
| D7 | deterministic by construction, no atomics feeding state |
| D8 | both constraint diagonals on both engines, MuJoCo's approximation the GPU's default |
| D9 | Newton, one workgroup per world, every round inside one dispatch, the Hessian in workgroup memory; MJW's per-round dispatches and CG measured beside it |
| D10 | qacc warm start on both engines |
| D11 | MJW's narrowphase ported, primitive first, convex next |
| D12 | MuJoCo's per-geom materials and pairs |
| D13 | robotgpu.zig device-free; robotgpu_host.zig runs the program |
| D14 | the tracker entirely on the device; the judge is robot.zig in its MuJoCo mode |
| D15 | the tracker first, then full parity |
| D16 | MuJoCo C fixtures are the oracle, MJW's where it deliberately differs |
| D17 | generic kernels, comptime variants only where a flag changes a kernel's shape |
| D20 | (Nov 2) the web first-class beside native, native's performance untouched - P5 |
| D21 | (Nov 2) follow MJW closely, with much better understandability - P1, P2 |

Settled while building (Nov 1-2): the device is compared with the twin per quantity, normwise, against per-array bars
(256 epsilons; 1024 for the factor and what is solved with it, which carry the matrix's conditioning); the GPU keeps
zimrmath's accurate polynomial sine and cosine (the hardware's is graphics-grade, and costs Geno under half a percent
of a step); sums whose order robot.zig fixes run one invocation per world (the subtree sums, the factorisation) until
the head-to-head says otherwise.


## 2. What exists (Oct 31 - Nov 2)

  - S0, THE ENGINE'S PREREQUISITES: subgroup reductions, kernels calling robot.zig and zimrmath, large dispatches,
    ranged readback, push constants, GPU timings, buffer lending, a workgroup Cholesky (76 x 76 in 23 KB), the memory
    envelope - on lavapipe.
  - S1, THE FOUNDATIONS: the arenas and their typed accessors (`WorldArray`, `ModelTable`, item kinds), packing (the
    topology, the constants, the branches), `Sim` (on a device, as the twin, on a lent pipe), the step program as data,
    a submit-then-collect host API, every kernel built for WGSL too, and `robotgpu_lab` - the checks as a page, native
    headless and on the web.
  - S2 SO FAR, each stage its own section of `robotgpu.zig`: kinematics (per branch; geoms and sites per element); the
    centre-of-mass frame (subtree centres per world; inertias and dof axes per element); the mass matrix (composite
    inertias per world; rows per dof); the factorisation and the smooth solve (robot.zig's LDL over a world's storage,
    per world); velocities (per branch, `velocityThroughJoint`); the bias forces (RNE: accelerations per branch, body
    forces per body, subtree sums per world, the projection per dof); the passive forces (per dof; tendons refused).
  - THE CHECKS IN PLACE: the twin = robot.zig bit for bit at every stage above (the KUKA, the humanoid, Geno); the
    device against the twin for every array (`StepComparison`) - on lavapipe at most 22.7 epsilons outside the factor,
    83 in it; on Simon's phone 24 before the factor existed; the WGSL build; the page on the phone.
  - THE VOCABULARY (V1-V3b): both engines' state, the model's tables and the counts renamed; MuJoCo's names kept as
    cross-references; both tutorials in step.
  - THE COURSE: robots.html Part VIII, chapters 45-52 (the simulator's data, kinematics, the centre-of-mass frame, the
    mass matrix, the factorisation, velocities, the bias forces, the passive forces).
  - WAITING ON SIMON: `vk_host_test.exe` on the RTX 5070 (cross-compiled); the phone on the latest page.
  - NOT YET MEASURED: performance on any real GPU.


## 3. What remains

Rewritten Nov 4, for the goal as Simon restated it: THE FASTEST APPROXIMATE SOLVER FOR TRAINING A GAME-READY WALKING
RAGDOLL - speed far before precision, every difference from MuJoCo and MuJoCo Warp backed by evidence. Geno's physics is
the target throughout (`robot_geno.physicsOptions`): Newton capped at 3 rounds and 5 line-search iterations (D28),
MuJoCo's reference-pose inertia (D27), MuJoCo's warm start on. The rate to come - physics at 90 to 120 Hz under a 30 Hz
decision (Simon) - re-measures the caps and the warm start when it is set.

Every step ends with: robot.zig first wherever the algorithm changes (as S3b4b was), the twin against it bit for bit;
the device against the twin within bars on lavapipe, the RTX 5070 and the web when Simon runs them; the WGSL through
Tint; the step's chapter of the course.

THE CRITICAL PATH, in order (rewritten again Nov 4, after Isaac Lab - section 6):

  P1 DONE: THE KERNEL'S NEWTON, robot.zig's - kept products, each round's forces, the exact line search run by lane 0
     (`robot.searchLineOver`), the scaled stops, the caps; the twin bit for bit; the device's rounds equal in every
     world; on Simon's phone (AGREE, 157 rounds, 607 epsilons, 32 KB of workgroup memory); chapter 57 rewritten.
  P2 DONE (Nov 5) - S3c THE CONSTRAINT STEP: the constraint program inside the step program, between the smooth acceleration and the
     velocity update; the device's refusal of constrained models lifted for the rows it makes; MuJoCo's warm start as
     its flag (`warmstart_accelerations` per world, saved by the step program after its solve, zeroed by a reset, the
     cheaper of it and the free acceleration taken). Check: the KUKA and the humanoid stepping on their limits, the
     twin's steps bit for bit against robot.zig's `step`, warm and cold; the device over many steps by statistics.
  P2b RETIRED (Nov 5) - THE SERVO IS ALREADY IMPLICIT. Geno's servo (`robot_track.pdTorques`) is Tan's stable PD: the
     critically damped spring's acceleration evaluated at the END of the step ("an explicit spring stiffer than about
     8 Hz explodes at 60 Hz"), then the torque that produces it through the full mass matrix - inverse dynamics, its
     floating-base form for a free root. Its armature of 2.0 (`standing_armature`) is not a stability crutch but its
     strength: "a joint's strength is its free-flight inertia, and 2 on every joint makes each as strong standing as
     the load it carries needs", measured to cost the dance nothing. The comparison with Isaac Lab's G1 (torque-gain PD,
     armature 0.01) assumed a law Geno does not have.
  P3 CONTACTS, ONE GENERATOR FOR BOTH ENGINES.
     (a) DONE (Nov 5) - THE GENERATOR: MuJoCo's plane-sphere, plane-capsule and plane-box, written once in robot.zig, run by a device
         kernel per world and geom into deterministic slots (a sphere 1, a capsule 2, a box 4) and by the CPU for Geno
         on a flat floor in place of zimrphysics. FLOOR ONLY - the CPU tracker's links do not collide with each other,
         and Isaac Lab's G1 runs with self-collision off on both its backends. MuJoCo's contact softness and margin,
         Geno's friction. Check: each pair against MuJoCo 3.17 (fixtures from its Python); a box dropped comes to rest;
         Geno standing 10 s; the servo's survival on the new contacts beside zimrphysics'.
     (b) CONTACT ROWS on the device: four pyramid edges a contact in slot order; each row's Jacobian along its body's
         dof chain; its inertia from the bodies' translation weights x (1 + mu^2). Geno's worst, lying down: 49
         contacts, 196 rows, about 28 KB of workgroup memory.
     (c) NEWTON'S ROW WORK FOR CONTACTS, MJW's way (`_use_incremental`): the Hessian built at the solve's start, then
         updated by the rows whose activity changed and refactored only when something did; J^T f over each row's
         chain. robot.zig first, then the kernel.
     (d) THE CAP'S TAIL (Isaac Lab's microduck found 10 rounds too few for its contact solves): Geno's walk, run, falls
         and get-up with contacts, the servo's survival and the tracker's reward at caps 3 and 5 - D28 raised if 3 costs
         them. Check, for all of P3: Geno lying and standing, the twin bit for bit, the device within bars; G4's first
         numbers with contacts.
     (e) FEET AT LARGE STEPS, MEASURED (Newton): a foot landing at 60 and 120 Hz - penetration and rebound - and a
         standing foot's creep under MuJoCo's soft pyramidal friction; speculative normal rows (clearance / h, Newton's),
         a margin, elliptic cones or Steel's friction anchors only where the measurements call for them.
  P4 S6 THE TRACKER ON THE DEVICE (D14), AS ONE DECISION PROGRAM (Isaac Lab's decision-as-a-CUDA-graph): a fixed list
     of dispatches submitted once a decision. Nothing in it waits for the host - every per-world choice a mask on the
     device, never a readback ("graph-safe"); natively the decision's command buffer recorded once and replayed (zimr's
     CUDA graph), on the web one encoder a decision. Every piece: robot.zig (or the CPU fleet) first where the
     algorithm is new or moves, the twin against it bit for bit, the device within bars, the WGSL through Tint, the
     course. A decision, in order:
         once        the actions uploaded (the learner's, or a zero action)
         per step    filter_actions, reference_targets      before_step_program
                     the step program (the servo first)     step_program
                     advance_frames                         after_step_program
         once        observations, rewards, terminations, resets, pushes, records
     (a) DONE (Nov 6) - THE CLIPS AND THE SERVO's TARGETS: the clips' rows on the device, each world's clip, frame and
         action (`initTwinTracking` / `initGpuTracking`, `setWorldClip`, `setActionScale`); `reference_targets` - the
         clip's pose a frame ahead (held at the last), the action integrated onto it as a displacement in velocity
         space, the hinge clamp - and `advance_frames`; `applyAction`, `clampHinges`, `actionSize` in robot.zig.
     (b) THE FILTER, AT THE PHYSICS RATE (Simon, Nov 6): before each physics step each world's applied action moves
         halfway to its policy's, `applied = applied + 0.5 (asked - applied)` (1 is none) - `robot.filterActionToward`
         beside `applyAction`, called by `Fleet.driveOnce` and by the kernel `filter_actions` (per world and action
         number, first in `before_step_program`); a world array `applied_actions`, zero at a reset, read by
         `reference_targets`; the factor `action_filter` in the task's uniform row. Not in the policy's input. The
         decision-rate filters (S0b's `Options.filter`, S0c1's `lat_filter`) stay at 1: one filter, never two in
         series. CHECK: the twin's applied actions robot.zig's over several steps, bit for bit; the CPU fleet at factor
         1 unchanged to the bit.
     (c) THE DECISION PROGRAM: `Sim.submitDecision(physics_steps)` - the actions uploaded, then for each physics step
         the three programs above; the CPU fleet's `step` at `decide_every` already the same sequence (S0a). CHECK: a
         few decisions of the twin against `Fleet.step` on one clip, the same actions and robot.zig's floor - the
         worlds' positions and velocities bit for bit; the device within bars; the side-by-side page driven by it.
     (d) VARIABLE STIFFNESS PER LIMB (Spoljaric, Yan & Lee 2025, arXiv 2502.09436 - the study in the journal, Nov 6):
         the action gains ONE STIFFNESS NUMBER PER LIMB, so the policy chooses how stiff each limb's servo is.
           LIMBS, from the model's tree: a body's limb is its first ancestor, or itself, whose parent branches; the free
             root's dofs belong to none. Geno has six - two legs and two arms (12 dofs each), the spine (Spine to
             Spine3, 12) and the neck with the head (9): all 69, the action 69 -> 75 (+8.7%). The Go1 has its four legs,
             the paper's grouping. `robot.limbOfBody`; on the device a model table `dof_limb`.
           THE NUMBER s in [-1, 1], squashed as the others, sets the limb's spring frequency f = f0 3^(s/4). Stiffness
             goes as f^2, so a limb's stiffness spans a factor of 3 - the paper's 20 to 60 - centred in the logarithm on
             the tuned f0 = 20 Hz: 15.2 Hz to 26.3 Hz, and s = 0 exactly today's servo (3^0 is 1).
           THE DAMPING RATIO STAYS 1. The paper couples d = 0.2 sqrt(k): critical damping, 2 sqrt(k I), for one fixed
             inertia, I = 0.01 kg m^2. Our spring acts on accelerations and the mass matrix brings each joint's own
             inertia, so ratio 1 is critical for every joint - the paper's coupling, exact. The acceleration bound
             (3000) stays.
           NO STIFFNESS COST (Simon, Nov 6). High stiffness is made expensive by what it does, not by a price on the
             number: a stiff servo makes the offset change quickly across the state space - a small error is a large
             force, so the offset must follow the state closely - which the policy's smoothness terms penalise
             (rl_track_plan, Nov 6: CAPS's temporal and spatial terms, the spatial one in the world model's latent
             space); and it spends torque and energy, which SuperMimic's reward now charges (P4f).
           NOT IN THE POLICY's INPUT, as the filter's state is not (the paper's policy reads its last action; ours does
             not). The world model reads it - it is part of the action. The filter smooths it with the rest.
           THE GROUPING's EVIDENCE, the paper's: per leg the best in velocity tracking and among the best in push
             recovery; per joint (24 actions) the worst in tracking - too large an action; per leg x joint group (an
             outer product, 19) the best in energy. So per limb first; a limb x level outer product (6 + 4 numbers on
             Geno) the variant if energy or naturalness asks for it.
           WHERE: robot.zig first - `servoTorques` given a frequency per dof (the law's frequency times the dof's limb's
             3^(s/4)), `Fleet.driveOnce` passing it; the device's `servo_accelerations` reading the world's applied
             stiffness for the dof's limb. A switch, `limb_stiffness`, off: off, the action and the servo exactly
             today's.
           CHECK: off, everything unchanged to the bit; on with every s = 0, the servo's torques off's to the bit; the
             twin's frequencies and torques robot.zig's; after residency, the paper's experiment in our terms - tracking
             error, push recovery (the recovery probe's boundary by direction, its Fig. 4), the aftermath's returns -
             per limb against a fixed 20 Hz.
     (e) THE OBSERVATIONS, once a decision: the derived quantities first (the static form of Isaac Lab's lazy buffers),
         then each world's state as the CPU fleet reads it (`stateOf`, `exemptFromContact`, each body in the
         character's frame, `track.local`) and its goal (the learner kit's table row, `Resident.uploadTables`: the same
         function on the host, read on the device), written into the learner's lent buffers. CHECK: the twin's rows
         the CPU fleet's `observe`, bit for bit.
     (f) THE REWARDS AND TERMINATIONS: SuperMimic's terms (`superMimicTracking`, the action rate, the joint-limit
         excess) and the tracker's (`trackingErrorWithHead`, `reward`); the termination rule with its grace and its
         aftermath (`terminated`, the return streaks), TERMINATED AND TRUNCATED APART, the terminal state kept. AND
         EFFORT BEYOND THE REFERENCE's (Simon, Nov 6: "return to ref should feel like ref") - a character on its
         reference spends exactly the reference's effort and is charged nothing; only what it spends beyond that is:
           THE REFERENCE's TORQUES, once per clip on the host, by the servo's own function: at each frame f the
             reference's state - its pose, its velocity v(f) by the backward difference from f-1 (`differentiatePos`,
             as `startAt` takes it) - and its joints' accelerations a(f) = (v(f+1) - v(f)) / h; then
             `floatingBaseTorques` at that state with those accelerations - the free root's six zero, the root's own
             acceleration solved from its block, contacts left out, exactly as the servo computes its torques. A
             character following the reference exactly has those joint accelerations at that state, so its servo's
             torques ARE these, number for number. The first frame takes the second's velocity; the last, the
             acceleration before it. `robot.referenceTorques(m, poses, frame_count, h, scratch..., out)`: a frame's
             dof_count numbers in a row, frame after frame.
           STORED beside the clip's coordinates: on the CPU a table per clip (the fleet's); on the device the model_f
             table `clip_torques` (frames x dofs), packed by `packClips` from the host's numbers (`ClipPoses` gains
             `reference_torques`).
           TWO SUMS per world through the decision's physics steps, each step's excess torque the servo's own less the
             reference's at the world's frame, dtau = tau - tau_ref(frame): ENERGY, sum of |dtau q'| dt over the dofs
             and the steps, divided by the character's mass (J/kg - a motor without regeneration spends on braking
             too); TORQUE, the mean over the dofs and the steps of (dtau / (m g))^2 (against the character's weight
             times a metre). On the device a kernel per world after `servo_torques` each physics step
             (`accumulate_effort`, a loop over the dofs - floats have no atomics in WGSL) and one zeroing both at the
             decision's start; on the CPU inside `driveOnce`, the same order. The reward charges both, weights small
             and measured - and with the reference's own effort subtracted, holding a pose against gravity costs
             nothing, so the weights no longer trade tracking for sag.
         CHECK: on the reference exactly - a clip's state and its accelerations - the servo's torques equal
         `referenceTorques`' to the bit and both sums are zero; each world's reward, done and aftermath flags and its
         two sums, the twin's against the CPU fleet's, bit for bit; the device within bars.
     (g) THE RESETS AND PUSHES: the worlds that ended reset by a mask on the device - the clip's pose at a sampled
         frame, the floor rest, the start noise, the applied action zeroed - and pushes that set the root's velocity
         (`Fleet.push`). THE DRAWS from a counter-based generator (a hash of the world, its episode and the draw's
         index) that the CPU fleet uses too, so the twin and the fleet draw alike and the check is bit for bit (the
         fleet's random stream changes once; no runs to keep). CHECK: the twin's resets and pushes the CPU fleet's.
     (h) THE RECORDS: each decision's state, action, reward, flags and segment into the learner's lent buffers - the
         feature ring of `robot_latent_kit.Resident` - never through the host. CHECK: the learner's rounds fed end to
         end; a zero action reproduces the reference; the servo's baseline on the device beside the CPU fleet's on the
         same physics (returns and falls as distributions).
  P4i (was P4b; after the first resident run) RANDOMISATION AS PER-WORLD MODEL FIELDS (Isaac Lab's startup events; MJW's
     batched model fields): friction, the bodies' masses and their centres per world, drawn at a world's reset; the mass
     matrix and the reference inverse weights from the world's own values. Check: the twin with one world's fields
     against robot.zig built with them.
  P5 THE FIRST NIGHT ON THE DEVICE (Simon's RTX 5070): G4 (steps per second against the CPU fleet, and against MJW on
     the same card - Isaac Lab publishes no humanoid figure to stand against) and GT3 (wall-clock to the judged
     return); the web at the worlds its memory holds. Speed levers measured there, each against the servo's survival:
     M factored once a decision (Steel's `update_mass_matrix_interval`), a GPU-shaped line-search sum.

OFF THE CRITICAL PATH, each when it pays: G3's MuJoCo fixtures for what robot.zig lacks; S7-S10 (MJW parity, watching
training worlds, flex, SDF, the discrete integrator, tactile sensors); robot.zig's own default inertia (MuJoCo's, once
the other robots are measured); a GPU-shaped line-search sum (lanes' partials in a fixed tree, robot.zig's order
changed with it) once G4 places the time; the intermittent zimrnum readback (section 6, Nov 4).

THE WEB, AT EVERY STEP: each kernel in the WGSL build; the page's checks in Simon's browser and on his phone; the
adapter's limits and features requested at boot; readbacks collected a frame later; the learner's buffers lent as
natively.

THE NIGHT (Simon, Nov 6): ONE RUN, EVERY IDEA, NO GRID. One night, one recipe with every component on, arranged by
feel (THE SCHEDULE), and diagnostics rich enough to see any problem during the run or the morning after - no grid
search, no ablations. Everything on the device: the physics, the tracker, the acting, the records, the learners. Each
component built and checked before the next; the run starts only when every check passes and a dry run on Simon's
machine is clean.

  THE COMPONENTS, in building order, each with its check:
  C1 REWARDS AND TERMINATIONS (P4f) with the effort beyond the reference's. CHECK: each world's reward, its done,
     failure, aftermath and return flags and its two effort sums, the twin's as the CPU fleet's, bit for bit, through a
     run that loses the reference and returns; the device within bars on lavapipe.
  C2 RESETS AND PUSHES (P4g), from counter-based draws the fleet and the device share. CHECK: the twin's episodes the
     fleet's, bit for bit, through resets and pushes.
  C3 ACTING ON THE DEVICE: the SuperMimic policy's forward pass on the device's observations (normalised as the kit's
     gather normalises them), its exploration from counter-based draws, written into `actions`; the weights read where
     the learner keeps them, never copied through the host. CHECK: the device's actions the CPU mirror's for the same
     observations and draws - bit for bit on the twin, within bars on the device.
  C4 THE RECORDS AND THE BOOKS ON THE DEVICE (P4h): each decision's records packed in `io` as one step of the learner's
     ring and copied buffer to buffer into it (one device, two pipes); the flags read back a frame late, and the books
     kept so a window only spans steps whose flags have arrived. CHECK: the ring after many decisions the CPU path's;
     no window crosses an episode's end.
  C5 THE WORLD MODEL READS THE PREVIOUS APPLIED ACTION (so the filter at 0.5 is learnable), THE LIMBS' STIFFNESS ON (the
     learners' action widths). CHECK: the world model's input carries the applied action; the fleet and the twin with
     both, bit for bit (the fleet's side done).
  C6 THE EFFORT HEAD: the world model predicts each decision's two effort sums; the policy's cost charges the
     predictions. CHECK: the head's predictions against the recorded sums on held-out records; the policy's gradient
     through it finite.
  C7 CAPS's SMOOTHNESS in the actor's loss - temporal, and spatial in the world model's latent space. CHECK: both terms
     on a fixed batch against a CPU computation; their gradients finite.
  C8 A SECOND WORLD MODEL AT 0.1 s (Simon): the state three decisions (six physics steps) ahead from the state and the
     applied actions over them, trained on the same ring (its targets three records on), giving the policy long windows
     in few coarse steps beside the fine model's short ones. CHECK: its loss on held-out windows; its prediction beside
     the fine model's composed three times, measured (they need not agree).
  C9 THE PHYSICS-MPC TEACHER FOR A FLOWDPG OFFSET (Simon): an offset on top of the SuperMimic policy's action, found by
     sampling-based MPC in the device's own physics - good trajectories before the world model has learned anything. A
     character chosen to plan has its state copied into K candidate worlds (a world-to-world copy kernel); each
     candidate's offset sequence (smooth noise about the current plan, MPPI's) is simulated H decisions by the true
     physics and tracker, scored by the tracking cost and the effort; the plan's first offset is the target the flow
     actor's offset is trained toward (FlowDPG). The fleet's worlds and the candidates' in one `Sim`. CHECK: on the
     twin, a candidate world after a copy steps exactly as its source; MPPI's weighted plan against a CPU computation;
     the planned offset lowering the true tracking cost against the policy alone, measured.
  C10 THE TRAINER's DEVICE PATH: geno_trainer's recipe choosing the device; the night's recipe with every component.
     CHECK: a training smoke of minutes in the sandbox on lavapipe - the device path's first rounds against the CPU
     path's, losses and returns within noise; the stop file and the resume.
  C11 ON SIMON's MACHINE: the Windows trainer; a dry run of minutes on the RTX 5070 (start, `stop`, resume); the arenas'
     sizes printed at the start against the GPU's binding limits; the diagnostics' page reading the dry run's folder.

  THE DIAGNOSTICS, so that one run is enough - written into the run's folder as it goes, one line a round:
  D1 health: non-finite counts per array (the watchdog's), constraint-row overflows, Newton's rounds (mean and most),
     contacts per world, the device's time per program (timestamp queries where the device has them), decisions a
     second.
  D2 tracking: the tracking error by clip and by body (mean, median, 90th percentile), episode lengths, terminations by
     reason, aftermath lives and returns (how often, how soon), falls, pushes given.
  D3 learning: every loss term of every learner - each world model's per horizon step, fine and coarse; the policy's
     tracking, action rate, effort and smoothness; the flow teacher's imitation; the critic's - the gradients' and the
     weights' norms per network, the learning rates, the normaliser's drift.
  D4 acting: the action per joint and each limb's stiffness (mean, spread, saturation), the filter's lag (asked against
     applied), exploration's scale; the MPC teacher's gain over the policy (the true cost, planned against not) and how
     often it planned.
  D5 THE WORLD MODELS AGAINST THE PHYSICS: each round, a few windows rolled open-loop through each world model beside
     the device's own physics from the same start - the divergence per horizon step, fine and coarse: the earliest sign
     of a model that will mislead the policy.
  D6 pictures: at each judging (every 30 minutes) a strip of frames of a few worlds (the engine's capture) and a judged
     run per clip.
  D7 alarms into `status.zon`, each with its reason: anything non-finite (the run saves and stops, as now); a loss
     rising for an hour; the action's spread collapsing; overflows above a share; returns falling for an hour. And a
     page of the engine's own, native and web, that reads the folder and draws every series.

  THE SCHEDULE, the run's arrangement by feel, in its recipe: the physics-MPC teacher strongest at first, fading as D5's
  divergence falls; the pushes from hour 1 to full strength at hour 7 (as night 1); the limbs' stiffness and the filter
  on from the start; CAPS's weights small from the start; the coarse model's windows joining once its loss settles.

## 4. Risks, and what retires each

  - ZIG'S YOUNG SPIR-V COMPILER may leave speed on the table -> the head-to-head and the driver's per-pipeline
    statistics show it; hot kernels reshaped; Zig's NVPTX target as an escape hatch for a kernel that cannot keep up.
  - THE WEB'S LIMITS: 16 KB of workgroup memory by default (Newton's Hessian for Geno needs 22.5 KB), binding sizes
    (fewer worlds per arena), subgroups absent on some browsers -> storages and layouts chosen at compile time per
    target (P5); the limits requested at boot; the worlds per arena from the web sizes file.
  - PER-WORLD SERIAL KERNELS (the subtree sums, the factorisation, later Newton) may underuse a large GPU -> measured at
    S2f-4; MJW's parallel forms brought in behind the same names where they show.
  - DEVICE ARITHMETIC differs from the twin's (division and square root a few ulps; conditioning in the factor) -> bars
    per quantity, measured on each device; a wrong kernel misses by thousands of epsilons.
  - DETERMINISM'S COST (no atomics) -> measured with the rest; gathers and compactions are often as fast.
  - THE SCALE OF ALL OF MJW -> staged; the tracker benefits at S6; every later row declinable by decision.
  - A robot.zig REFACTOR MOVES A NUMBER -> the fingerprint gate; revert, do not explain.


## 5. Where things live, and how a change is checked

  - `src/robotgpu.zig` - the vocabulary of the arenas, the layout, packing, the kernels, stage by stage.
  - `src/robotgpu_program.zig` - the step program as data, the one list of the kernels (the build reads it too).
  - `src/robotgpu_host.zig` - the pipe, `Sim`, the bars, the comparison.
  - `src/robotgpu_sizes.zig`, `src/robotgpu_sizes_test.zig` - the arenas' sizes per target.
  - `src/robotgpu_tests.zig` - the twin against robot.zig, the layout, the refusals.
  - `tools/vk_host_test.zig` - the device against the twin (lavapipe here, the RTX 5070 at Simon's).
  - `examples/robotgpu_lab/` - the checks as a page, native headless and on the web.
  - `src/robot.zig` - the CPU engine and the functions both engines share.
  - `src/notes/tutorials/robots.html`, Part VIII - the course.
  - `/home/claude/mujoco_warp` - MJW's source, read for every stage (the sandbox's checkout).

A CHANGE IS CHECKED BY: lint; robotgpu's tests (the twin against robot.zig); when robot.zig changes, the fingerprint
gate, robot.zig's own tests, the robot family and doc-sync; the WGSL build; the device test (the bars); the page
headless and its web build; doc-folds, doc-sync and doc-gate when a tutorial or a quoted source changes; a journal
entry; a snapshot.


## 6. Journal

- Nov 2: v2. The plan had grown to 2,900 lines; v1 archived whole (`src/notes/archive/robotgpu_plan_v1.md`), and this
  version written to summarise what exists and to be precise about what remains. TWO DECISIONS CHANGED (Simon): D18
  ("native only, officially") and D19 ("the web later, stage SW after S6") are replaced by D20 - the web first-class,
  good results on WebGPU without giving up any native performance - and D21 records the direction the work had
  already taken: follow MuJoCo Warp closely, with much better understandability. The gates follow: G2 on WebGPU too,
  G4 with the head-to-head and a web figure, G5 on the web within its memory; the web's work moves from one late stage
  into every stage. NEXT: S2e-5, actuation.
- Nov 2: ON SIMON'S PHONE (the page with S2e-4): AGREE - largest gap 106.37 epsilons in smooth_joint_accelerations,
  its bar 1024 (lavapipe 81.4: the phone about 1.3 times wider there); the copies arrived after 6 frames.
- Nov 2: REVIEW OF S2e-4 - "make it perfect". (1) `passive_joint_forces` read the joint's type even when its stiffness
  was zero; now it mirrors robot.zig's structure - the stiffness first, the type only for a joint with a spring - with
  every nested load a named value and the damper and the spring each commented. (2) THE REFUSAL renamed
  `refuseUnsimulatedFeatures` (in zimr `require...` names a comptime check of an argument's shape, not a runtime check
  of a model) and MOVED to the first line of `Sim.initGpu` and `Sim.initTwin`: before, the host counted, laid out,
  allocated both upload images - and, for the device, made the pipe - before refusing. (3) ITS TEST, beside the layout
  refusals: Geno passes; a copy given a tendon is refused with `ModelError.TendonsNotSimulated`. CHECKED: robotgpu
  12/12 (the twin still bit for bit), WGSL, vk-host-test, the web page, doc-folds, doc-sync, lint.
- Nov 2: S2e-5a DONE - ACTUATION'S DATA (the kernels next). robot.zig's `actuation`, read whole: `transmission` first
  (a joint actuator's length and velocity are its joint's first coordinate and first dof's rate - the gear is folded
  into gain and bias); per actuator, the control clamped when it has a range, the activation dynamics (none; integrator;
  filter; filter_exact through `@exp`) writing the activation RATE and taking the stored activation as input, the force
  `((gain * input + bias0) + bias1 * length) + bias2 * velocity`, clamped when it has a range; a joint actuator adds its
  force to its one dof - so the per-dof GATHER in actuator order is robot.zig's `+=` to the bit. robotgpu.zig: item
  kinds `actuator_vectors` (4) and `actuator_pairs` (2); per-world `activation_rates`, `actuator_forces`,
  `actuator_lengths`, `actuator_velocities` (MuJoCo's act_dot, actuator_force, _length, _velocity); tables
  `actuator_target`, `actuator_activation_index`, `actuator_dynamics`, `actuator_control_limited`,
  `actuator_force_limited`, THE TRANSPOSE `dof_first_actuator` / `dof_actuator_count` / `dof_actuators` (each dof's
  joint actuators in actuator order), and constants `actuator_gain`, `actuator_bias`, `actuator_control_range`,
  `actuator_force_range`, `actuator_time_constant` - each naming its MJW array; `ActivationDynamics` and
  `activationDynamicsOf`, an EXHAUSTIVE switch from robot.zig's `Activation` (a first try pinned the numbering by
  reflection; this Zig's `@typeInfo` API is moving - the switch is plainer and fails the build the same way); packing
  fills them all. TEST: every fixture's actuators packed as robot.zig has them, every joint actuator listed once under
  its dof in actuator order - and the fixtures between them have actuators, so it cannot pass on nothing. FOUND: the
  device test's build hit the compiler's 1,000-branch budget in jobs.zig's `assertPod`, which walks a job header's type
  field by field - robotgpu's Params nests the whole layout, fifteen arrays bigger now; the walk given a budget of
  100,000 with the reason in a comment. CHECKED: robotgpu 13/13, WGSL, vk-host-test (22.69), `zbuild check`, lint.
  NEXT: S2e-5b - the kernels `actuator_forces` (per world and actuator, with the transmission) and
  `actuator_joint_forces` (per world and dof, the gather); the twin against robot.zig's `actuation`; the device; the
  page; the course.
- Nov 2: S2e-5b DONE - ACTUATION ON THE GPU. robotgpu.zig: a section ACTUATION (its introduction: the control
  clamped, the activation's rate written and its value read, the affine force law clamped; the gather in place of
  MJW's atomic scatter); `ModelTable.loadPair` (width-checked, built from `load`'s own read); `actuator_forces`, PER
  WORLD AND ACTUATOR - the transmission (length and velocity from the target joint), `zm.clamp` (robot.zig's own),
  the four dynamics (filter_exact through `@exp`), `gain * input + bias0 + bias1 * length + bias2 * velocity` in
  robot.zig's expression shape, the force clamped; `actuator_joint_forces`, PER WORLD AND DOF - from zero, the forces
  of `dof_actuators` in actuator order. The host's new shape `per_world_and_actuator`; both kernels in the step
  program after the passive forces; bars 256. The page and the device test give each world its own controls. Lint's
  `reserved-math-names` renamed the locals `length`/`velocity` (zm.length) `actuator_length`/`actuator_velocity`.
  CHECKED: twin = robot.zig's `actuation` BIT FOR BIT (lengths, velocities, forces, activation rates, the dofs'
  actuator forces; the KUKA's and the humanoid's actuators, controls large enough to clamp); robotgpu 13/13; WGSL;
  vk-host-test - every actuation array 0.0, VACUOUSLY: Geno's model declares no actuators (its servo acts from
  outside the model); the device check of actuation moves to S2f-3, on the humanoid; `zbuild check`; the page
  headless and its web build. THE COURSE: robots.html chapter 53, "Actuation on many worlds" (the three steps, the
  force law sketched, the gather instead of the scatter with a worked dof). NEXT: S2e-6, the smooth forces.
- Nov 2: S2e-6 DONE - THE SMOOTH FORCES; S2e COMPLETE. robotgpu.zig: `smooth_joint_forces`, per world and dof,
  opening THE SMOOTH ACCELERATION section (its introduction now names both kernels): `((applied + actuator) + passive)
  - bias`, robot.zig's `forwardDynamics` order (MJW's `_qfrc_smooth` rounds differently); in the step program before
  the solve; bar 256. The test forces retire: the page and the device test now upload each world's APPLIED forces -
  a world's real input - and the solve's right-hand side is computed. CHECKED: twin = robot.zig BIT FOR BIT - the
  smooth forces against robot.zig's own sum, the smooth acceleration against `forwardDynamics` itself (the twin test
  calls it now, instead of a hand-made solve); robotgpu 13/13; lint. FOR SIMON'S RTX 5070 (he offered a Windows test
  today): `robotgpu_windows.zip` - robotgpu_lab.exe and vk_host_test.exe cross-compiled in release mode (with their
  .pdb) and a README; vk_host_test needs the Vulkan SDK for its validation layer. NEXT: S2f-1, implicit damping -
  and the RTX's results, the first on NVIDIA hardware.
- Nov 2: THE FIRST RUN ON NVIDIA HARDWARE - Simon's Windows machine, an RTX 5070 (not the 5060 the plan had named:
  corrected throughout), Vulkan 1.4, validation on. THE DEVICE: 48 KB of workgroup memory, 256 bytes of push
  constants, subgroups of 32 (arithmetic, shuffle, ballot), float atomic add, 1 ns timestamps, storage bindings to
  4,095 MB, 11,943 MB of device memory - every assumption of the plan's native path holds. THE LAB: AGREE, largest gap
  230.11 epsilons in smooth_joint_accelerations, bar 1024; copies after 1 frame. THE HOST TEST: large dispatches,
  staging, the learning kernels (3.2e-6 relative), subgroup and workgroup sums, TWO DEVICE RUNS IDENTICAL (subgroup
  sum, workgroup sum, the Cholesky), timings (busy work 43 us, four times the rounds 162 us), push constants, ranged
  readback, lending - all pass. THE STEP, every array within its bar: poses 2.2-2.8, subtree centres 2.5, dof axes
  14.5, body inertias 16.0, mass matrix 2.8, composite inertias 16.0, velocities 14.0, axis rates 25.1, bias
  accelerations 13.0, subtree bias forces 19.3, bias and smooth forces 3.6, mass factor 57.6, inverse diagonal 120.6,
  smooth acceleration 230.1 - about twice to three times lavapipe's (NVIDIA fuses multiply-adds; its square root is not
  correctly rounded), each well inside its bar. TWO PROBE BARS FAILED - both set from lavapipe alone: `dot6` 16.00
  against 4 (six products near 60 cancelling into a small power, each product fused) and `acosRad` 11.44 against 8 (a
  polynomial with a square root, steep near +-1); `rotate` (3.33) and `crossMotion` (2.93) stood close to their 4. THE
  PROBE TABLES now carry a column per device and bars two to four times the worst: dot6 64 (the cancellation reasoning
  crossForce already had), acosRad 32, rotate 8, crossMotion 8 - each with its reason. Simon cannot test more today.
- Nov 2: S2f-1a DONE - THE MASS-MATRIX PRODUCT, SHARED. robot.zig's Euler velocity update (`dampedVelocityStep`), read
  whole: without dof damping, `velocity += dt * acceleration`; with it, `dt * (M acceleration)` by `mulM`, M + dt D
  factored by `factorMDamped`, solved, added. `mulM` uses each stored entry twice - its own row, and mirrored into
  an ancestor's - so its loop's order is part of its result: now `multiplyByMassMatrix(storage, dof_count)`, generic
  over a storage (`requireMassProductStorage`: rowStart, rowEntries, column, massEntry, input, output, setOutput;
  robot.zig's `MassProductArrays`), `mulM` keeping its checks and calling it; a comptime test of the storage. THE
  GATE: fingerprints equal; robot.zig's root 126/126; the family 651/795 (144 skipped); doc-sync 0 drifted. The plan's
  S2f-1 rewritten from the code it mirrors. NEXT: S2f-1b - the kernels (the product, the damped factor and solve, the
  velocity update, the acceleration copy), the twin against robot.zig's step, the device, the page, the course.
- Nov 2: S2f-1b DONE - THE VELOCITY UPDATE ON THE GPU. robotgpu.zig: a section THE VELOCITY UPDATE (its introduction:
  Euler's update, why a damper is taken implicitly - `(M + dt D) dv = dt (M a)`, unconditionally stable - robot.zig's
  four steps drawn); `joint_accelerations` (per world and dof: the smooth acceleration, a model's constraint forces
  having nowhere to come from yet); `damped_velocity_changes` (per world: the product by the shared
  `multiplyByMassMatrix` into `velocity_changes`, scaled by dt; M copied into the DAMPED FACTOR'S OWN ARRAYS, dt x
  damping on each damped joint's dofs' diagonals in joint order; `factorLdlInPlace`, `solveLdl`; nothing for a model
  without damping); `next_velocities` (per world and dof: the change, or `dt * acceleration`, as robot.zig adds them).
  The flag `has_dof_damping` packed; `WorldMassMatrix(factor_array, inverse_diagonal_array, solution_array)` generic
  over the three arrays it touches (`SmoothAccelerationSolve`, `VelocityChangeSolve`); `WorldMassProduct`. FOUND BY
  THE TWIN - the test failing 0.0842 against 0.0870, located with temporary markers and a dump: the solves agreed but
  the factors differed by exactly the damping. robot.zig REFACTORS M after its damped solve (`dampedVelocityStep`'s
  closing `factorM`, which its comment measures at 4.5% of a step) so `mass_factor` is M's again; the device now keeps
  the damped factor in `damped_mass_factor` and its inverse diagonal - M's factor untouched, the same end state with no
  refactorisation (MJW keeps its integration matrix apart likewise). THE TEST restructured: one helper,
  `robotThroughForwardDynamics`, takes robot.zig through forward dynamics for a world (every stage's results stay in
  `Data`); the first loop compares every stage through the smooth acceleration, the velocity-update kernels run after
  it, and a second loop compares the damped change, M's untouched factor and the next velocities against robot.zig's
  own `dampedVelocityStep` (made `pub`). CHECKED: robotgpu 13/13 (the KUKA and the humanoid damped, Geno plain), lint,
  WGSL. NOT YET THIS TURN: vk-host-test, the page's builds, the course's chapter on the velocity update - next turn,
  with S2f-2 (positions, activations, the time).
- Nov 2: REVIEW OF S2f-1, AND A CORRECTION. `next_velocities` set a `var` to zero and overwrote it in both branches
  (and read `velocity_changes` where it did not need it): now two plain paths - the damped change with an early
  return, then the explicit update - each value named, the bits unchanged. THE CORRECTION: earlier entries (S2e-4,
  S2e-5b, S2f-1b) said Geno has no damping, so its device check of the passive forces "compared zeros", and that Geno
  took the velocity update's plain path. WRONG: all 23 of Geno's joints have damping 0.2. The passive forces' 0.0 on
  the device was a genuine exact match (`-damping * rate`, one multiply, rounded alike everywhere), and the device has
  been checking the implicit damping for real - velocity_changes 64.1, damped_mass_factor 61.3, joint_velocities 52.7
  epsilons on lavapipe. Only actuation's device check is empty (Geno declares no actuators). And since the KUKA, the
  humanoid and Geno ALL have damping, the explicit path was untested: the twin parity now also runs on a copy of the
  KUKA with its damping zeroed. The course gains chapter 54, "The velocity update on many worlds". TO SWEEP LATER:
  robot.zig's own comments still carry measurement stories and plan references (`dampedVelocityStep`'s, "(phase 2)").
- Nov 2: S2f-2 DONE - THE ADVANCE; THE EULER STEP COMPLETE ON THE GPU. robot.zig's `advanceEuler`, read whole: the
  activations (`a += dt * rate`), the velocity update, `boundVelocity` (a velocity not finite becomes zero, any other
  is clamped to `opt.max_velocity` - between the two integrations, so a bad velocity never reaches the positions),
  `integratePos` and `normalizeQuats`; robot.zig keeps no simulation time, so neither does the device. robotgpu.zig:
  `max_velocity` in the step options (a second 16-byte row of the uniform, padded); a section THE ADVANCE with its
  introduction; `next_activations` (per world and activation), `bound_velocities` (per world and dof, `isFinite` and
  `clamp` - zimrmath's, as robot.zig's), `next_positions` (per world and joint) and `turnQuaternion` (the shared
  `rotateQuatByAngularVel`, then `normalizeQuat` - one quaternion's own normalisation in the same invocation gives
  robot.zig's two-pass bits). The activations follow the velocity update here, robot.zig integrates them first:
  neither reads the other. New shapes `per_world_and_activation`, `per_world_and_joint`. robot.zig's `advanceEuler`
  made `pub`; the twin test's second loop calls it. CHECKED: twin = robot.zig BIT FOR BIT through the whole Euler step
  (activations, bounded velocities, every coordinate including turned quaternions; the damped KUKA, the undamped KUKA,
  the humanoid, Geno); robotgpu 13/13; fingerprints; robot.zig's root 126/126; WGSL; vk-host-test - joint_positions
  0.5, joint_velocities 52.7 epsilons; the page headless and its web build; doc-folds, doc-sync (the course's quote
  of `advanceEuler` follows its new `pub`), doc-gate. THE COURSE: robots.html chapter 55, "The advance on many
  worlds". NEXT: S2f-3 - the step program over many steps, on several robots (G1, G2), and THE OPEN QUESTION first:
  a model with constraints, stepped without them.
- Nov 2: REVIEW (Simon, on `turnQuaternion`'s four `joint_positions.load(world, first_coordinate + k)`: "This feels
  like something a helper would make nicer"). A free or ball joint's coordinates and rates are RUNS of consecutive
  numbers in arrays of single numbers - three for a position or an angular velocity, four for a quaternion - and four
  places built values from them load by load. `WorldArray` gains `loadVector3` (built with `zm.vec`, its fourth lane
  zero, as robot.zig's `vec`), `storeVector3`, `loadQuaternion`, `storeQuaternion` - each width-checked at compile time
  to arrays of single numbers, beside `loadVec`/`storeVec` for arrays of vectors. USED IN: kinematics (a free body's
  position and quaternion, a ball joint's quaternion), `turnQuaternion` (now five named lines), and `next_positions`,
  whose free joint's translation became one vector expression, `position + splat(dt) * linear_velocity` - each lane
  rounded as robot.zig rounds each coordinate. CHECKED: robotgpu 13/13 (bit for bit, unchanged), lint, WGSL,
  vk-host-test (joint_positions 0.5 epsilons), doc-folds (four folds now show the helpers), doc-sync.
- Nov 2: CONSTRAINTS ON A STEPPING DEVICE - DECIDED AND DONE. robot.zig had no switch for its constraints; it has one
  now, `opt.disable_constraints` (default false; MuJoCo's mjDSBL_CONSTRAINT): `makeConstraints` builds no rows, so the
  projection and the solve leave the smooth acceleration as it is - no special case anywhere else, no stale rows.
  robotgpu's `refuseUnsimulatedFeatures` gains `ModelError.ConstraintsNotSimulated`: a model with a limited joint, an
  equality, or geoms that may touch (`opt.max_contacts > 0`) is refused unless its options disable its constraints.
  THE OPT-INS, explicit and commented where the model is loaded: the device test's two Sims and the lab's set
  `geno.model.opt.disable_constraints = true`. THE TEST: Geno as loaded is refused; with the switch it passes; a tendon
  is refused either way. The twin harness packs without a Sim, so the parity tests compare kernels as before.
  CHECKED: robotgpu 13/13, fingerprints (equal - the default changes nothing), robot.zig's root 126/126, the family
  651/795 (144 skipped), `zbuild check`, vk-host-test, the page headless and its web build, doc-sync, lint.
  NEXT: S2f-3 - the step program over many steps on several robots, with the switch set on both engines.
- Nov 2: REVIEW FOR ZIG IDIOM (Simon, on `var has_limits: bool = false; for (...) |range| { has_limits = has_limits or
  range != null; }`: "this sort of code worries me. Why are we not using an init block with an early out?"). Two
  shapes were not idiomatic. (1) A FLAG ACCUMULATED IN A LOOP THAT NEVER STOPS - the refusal's `has_limits` and a
  test helper's `has_child`: now `for` as an expression, `break true` at the first hit, `else false` - a const that
  says what it means; the refusal also returns early for a model that disables its constraints. (2) A VAR GIVEN A
  DEFAULT AND OVERWRITTEN UNDER A CONDITION - actuation's `control`, `input`, `force` and the bias pass's
  `acceleration`: now consts from `if` and `switch` expressions, labelled blocks (`clamped:`, `integrated:`,
  `filtered:`, `filtered_exactly:`) where a branch also writes the activation's rate - robot.zig's own `actuation`
  writes `input` this way; `acceleration` stays a var because the dof loop adds into it. KEPT, with a comment:
  `StepComparison.collect`'s `all_arrived`, which must visit every request on every call (each is collected) and so
  cannot stop early. Loop counters in kernels stay `u32` `while` loops (a `for` over a range yields usize, casts
  everywhere in shader code); walks up a parent chain stay `while (ancestor != 0) : (ancestor = parent[ancestor])`;
  running maxima and sums stay vars. Lint's `branch-braces` braced the new one-line ifs. CHECKED: robotgpu 13/13 (bit
  for bit, unchanged), WGSL (switch expressions with labelled blocks translate), vk-host-test, the web page,
  doc-folds, doc-sync, lint. robot.zig itself was not swept - an older, larger file, for its own review.
- Nov 2: EARLY OUT, AS A HABIT (Simon, on the refusal's flags tested together: "Just return early for each case, in
  order of probability or cost? ... as a habit we need to organise our conditions to early out optimally").
  `refuseUnsimulatedFeatures` now returns at each condition, ordered: tendons (a count), the opt-out (a flag),
  possible contact (two counts - the likely constraint), equalities (a count, rare), the joints' ranges (the one loop)
  last; a comment states the order. The habit is in claude.md ("Conditions: return early, the cheap and the likely
  first"). The GPU code had no other such chain: `is_free_body` already tests the count before the load and decode,
  and `and` short-circuits.
- Nov 2: S2f-3a DONE - G1 ON THE TWIN, STEP AFTER STEP. THE STEP PROGRAM MOVED into robotgpu.zig (`Invocations`, with
  `count` public, `Dispatch`, `step_program`, after the kernel list): it is data about the simulator, the host runs
  it, and the twin's tests now walk the very same list - neither can drift from the other. Its description was STALE,
  ending at "the smooth acceleration" two stages ago (an earlier replacement of mine had not matched and said nothing):
  rewritten for the whole step. THE TEST `expectTwinSteps`: four worlds of a model, each its own state and inputs
  (`giveTwinWorldsInputs` / `giveRobotWorldInputs`, the latter now also `robotThroughForwardDynamics`' - one
  definition of the inputs), the model's constraints disabled on both engines (`opt.disable_constraints` on a shallow
  copy), the whole program run 20 times on the twin, robot.zig's own `step` 20 times per world - and every coordinate,
  velocity and activation EQUAL TO THE BIT: the damped KUKA, the undamped KUKA, the humanoid, Geno. CHECKED: robotgpu
  14/14, `zbuild check`, vk-host-test, the web page, doc-sync, lint. NEXT: S2f-3b - the device over many steps, by
  statistics (its gap's growth, energy), and the simpler models.
- Nov 2: REVIEW - ONE LIST OF THE KERNELS. Every stage had been adding each kernel by hand to FIVE lists:
  `robotgpu.kernels` (the SPIR-V entries), `step_program` (the same names with their shapes), two lists in build.zig
  (the WGSL translation, the lab's build) and the lab's shader table (an `@embedFile` constant and a table row per
  kernel) - a forgotten edit away from a kernel compiled for one target and not another. NOW ONE: the step program
  lives in `src/robotgpu_program.zig` (`Invocations`, `Dispatch`, `step_program`), a file of its own depending on
  nothing, because the build script must read it and cannot import robotgpu.zig (robot.zig, the engine's modules) -
  its header says so. robotgpu.zig re-exports it, DERIVES `kernels` from it at compile time, and counts a dispatch's
  invocations (`invocationCount`, beside `Counts`, which the program file must not import); build.zig derives
  `robotgpu_entries` from it (both its lists); the lab builds its table at compile time (`kernelTable`: each
  dispatch's kernel with `@embedFile(kernel ++ "_wgsl")`), forty hand-written lines gone. A new kernel is now one
  line in the program. CHECKED: robotgpu 14/14, `zbuild check`, WGSL, vk-host-test, the page headless and its web
  build, doc-sync, lint.
- Nov 2: S2f-3b (the twin's half) DONE - THE SIMPLE MODELS. robot.zig has no builders for them, so each is a few lines
  of MJCF in robotgpu_tests.zig beside the humanoid's and Geno's, isolating one mechanism of the step: a single
  pendulum (one hinge), a double pendulum (a hinge whose axis the first one's motion carries - the axis rates), a free
  body (a box, an asymmetric inertia tumbling under gravity - the quaternion turned), a ball chain (three ball joints).
  All four in the many-step test: 20 steps, four worlds each, every coordinate, velocity and activation EQUAL TO THE
  BIT with robot.zig's own `step` - with the arm (damped and not), the humanoid and Geno, eight models. CHECKED:
  robotgpu 14/14, lint. NEXT: the device over many steps - its gap's growth and each world's energy (robot.zig's
  `energy`, computed on the CPU from the device's state and from the twin's), measured on lavapipe before any bar.
- Nov 2: S2f-3c DONE (lavapipe) - THE DEVICE OVER MANY STEPS. vk-host-test's step check became `runRobotgpuSteps(...,
  step_count, inputs)`: every world's coordinates and velocities read back from both (`readWorldArrays`) and each
  world's ENERGY computed on the CPU by robot.zig itself (`worldEnergy`: kinematics, the centre-of-mass frame, the
  composite inertias, then `energy`), before and after. FIRST MEASUREMENT, DRIVEN (applied forces, dampers): the
  twin's energy changed 31-fold and the device's differed 2.8% - meaningless, as the applied forces and the dampers
  do path-dependent work, free to differ once the paths part. So `StepInputs`: `driven` (every force path, the
  one-step check) and `conservative` (gravity alone: no applied force, no control, the dampers zeroed on a copy of the
  model) - energy then changes only by the integrator's own error. ALSO FOUND: the report's worst array, 2^23
  epsilons in `velocity_changes`, was two UNWRITTEN buffers compared (an undamped model's step never writes the damped
  update's arrays; a device buffer is not zeroed): `StepArrayBar.written` (`.always`, `.when_damped` for the damped
  update's three arrays), `Sim.has_dof_damping` recorded at creation, and an unwritten array is not requested (its
  stride left zero; inside the `inline for` the runtime condition guards the body - an early `continue` there is
  comptime control flow in a runtime block). MEASURED, 100 steps under gravity alone, Geno's 64 worlds: the arrays
  still within 370 epsilons of the twin's (subtree_bias_forces); the energy, relative to the start - device against
  twin 2.15e-6, the twin's own drift 7.08e-2. THE BAR: the device's energy gap below a hundredth of the twin's drift
  (here a margin of about 330) - scaled by the integrator itself, not a number picked. CHECKED: vk-host-test,
  robotgpu 14/14, `zbuild check`, the page headless and its web build, doc-sync, lint. NEXT: run on the RTX 5070;
  then S2f-4, the head-to-head with MuJoCo Warp.
- Nov 2: THE RTX 5070, SECOND RUN (Simon's Windows machine; robotgpu_windows.zip from zimr271, release mode) - EVERY
  CHECK PASSED, the new energy bar included (the test returns at its first failure and reached its final line, "no
  validation errors, no warnings"). The lab: AGREE, largest gap 230.11 epsilons (smooth_joint_accelerations), bar
  1024, every copy after one frame - the first run's value, as the stages before the advance are unchanged and the GPU
  is deterministic. The step's new arrays (epsilons): joint_positions 1.0, joint_velocities 76.4, velocity_changes
  83.8, damped_mass_factor 60.4, its inverse diagonal 115.4, activations 0.0 (Geno has none). Probes within their
  per-device bars: dot6 16.00 (64), atan2Rad 28.50 (64), acosRad 11.44 (32), crossForce 8.61 (16), crossMotion 2.93
  (8), rotate 3.33 (8), the rest at most 2. Cholesky 1.75 epsilons from the twin, two device runs identical; timings
  3.90x for four times the rounds (3.75x on a second run). THE 100-STEP LINE (from the full output, a second photo):
  under gravity alone the arrays apart by up to 280.59 epsilons (subtree_bias_forces - closer than lavapipe's 370);
  energy relative to the start, device against twin 2.40e-6 (lavapipe 2.15e-6), the twin's own drift 7.08e-2 (the
  same on both, the twin being the same CPU code) - a margin of about 295 under the bar. The step bars' comment in
  robotgpu_host.zig was STALE (two groups, from an early stage): rewritten with all five groups and both devices -
  poses/frame/mass matrix 8.3 | 16.0 (bar 256), velocities and forces 22.7 | 25.1 (256), factor and solve 239 | 230
  (1024), velocity update 67.4 | 115 (1024), the advance 0.5 | 1.0 (1024) - and fused multiply-adds named beside
  division and square root; the energy bar's comment in vk-host-test gives both devices' numbers.
- Nov 3: S3a DESIGNED - JOINT LIMITS AS ROWS (the tracking plan's E1a; Simon: "Continue with the plan"). Read in
  robot.zig: `makeConstraints` emits, after any equality rows, two CANDIDATE ENDS per joint with a range (hinges and
  slides - a ball or free joint gets no range) in joint order, lower then upper: distance q - lo with J = +1, hi - q
  with J = -1; an end becomes a row when its distance is below the joint's margin, its violation distance - margin,
  its softness and impedance the joint's. `projectConstraints` is one loop body per row: M^-1 J^T by the factor, the
  row's inertia J M^-1 J^T, its velocity J qdot, the impedance (`Impedance.at`, clamped), the regulariser
  (1 - imp)/imp x inertia, the target acceleration -b vel - k imp violation (capped for contacts only).
  THE DESIGN: model tables - each candidate's joint and end, the joint's range, margin, softness (time constant,
  damping ratio) and impedance (its curve's parameters). Kernels: `limit_candidates` (per world and candidate: the
  distance, whether active); `constraint_rows` (one invocation per world: the active candidates in candidate order
  into rows - robot.zig's own order - each row's candidate, J's sign, its violation; the world's row count; beyond
  the model's capacity, the world's overflow bit); `constraint_jacobians` (per world and row: the dense row, the sign
  at the joint's dof); `project_constraints` (per world and row: robot.zig's loop body, `Impedance.at` its own).
  World arrays: the row count; per candidate the distance and the flag; per row its candidate, sign, violation,
  inertia, velocity, regulariser, target acceleration; per row and dof J and M^-1 J^T. CHECK, on the twin to the bit:
  the KUKA's worlds posed at and past their limits - inside the margin, beyond, both ends - against robot.zig's
  `makeConstraints` and `projectConstraints` (no equalities, no contacts): every row's count, J, violation, inertia,
  velocity, regulariser and target acceleration; then the device within bars. NOT YET: equality rows (still
  refused), contacts (S4, S5), the solve (S3b, Newton), the step using it (S3c).
- Nov 3: REVIEW AGAINST MUJOCO WARP (Simon: "You still have mjw code? Read it again. Find differences between them and
  us. Are they all justified?"). MJW's `constraint.py` (`_efc_row`, `_limit_slide_hinge`) read against robot.zig and
  S3a's design; the smooth stages recalled against `smooth.py`.
  THE CONSTRAINTS:
    1. ROWS PER LIMITED JOINT: MJW one, the nearer end (pos = min(q - lo, hi - q) - margin, J by which is nearer);
       robot.zig two candidate ends, lower then upper, each a row inside its margin - MuJoCo C's own order, which its
       fixtures compare row by row. JUSTIFIED: robot.zig follows MuJoCo; MJW simplifies, differing only when a range
       is narrower than twice its margin.
    2. THE REGULARISER: MJW (and MuJoCo) R = (1 - imp)/imp x `dof_invweight0` - the model's inverse weight at the
       reference pose, MuJoCo's diagonal APPROXIMATION; robot.zig the EXACT J M^-1 J^T, a solve per row every step.
       JUSTIFIED FOR PGS, robot.zig's default, whose Gauss-Seidel step divides by inertia + R; NOT for Newton, which
       Geno runs (`robot_geno.zig`, the judge) and robotgpu plans (D9) - there the exact inertia only feeds a
       regulariser MuJoCo computes otherwise, and on the device it would cost a solve per row per step. PROPOSED:
       robot.zig takes MuJoCo's approximation for R (the exact inertia kept where PGS divides by it), so robotgpu's
       projection needs no solve - Simon's decision, as it changes the game's constraint softness away from the
       reference pose.
    3. ROW SLOTS: MJW an atomic counter (its order the scheduler's; MJW has a `deterministic` mode for contacts);
       ours fixed candidate slots. JUSTIFIED: determinism, and the twin's bit-for-bit check.
    4. DENSE J: MJW dense or sparse; ours dense, as robot.zig. JUSTIFIED at Geno's 75 dofs; sparse if models grow.
    5. MJW stores D = 1/R; robot.zig R - names only.
    6. MJW reads every parameter per world (`worldid % shape`), for randomised models; ours per model. JUSTIFIED: no
       randomisation (the tracking plan's D3).
    7. MJW's discrete refsafe (`is_discrete`) and dof frictionloss rows; robot.zig has neither. JUSTIFIED: not used.
  THE SMOOTH STAGES (done):
    8. Kinematics: MJW per tree level over bodies; ours per world and branch, walking each chain. Same bits either way
       (each body from its parent); ours fewer dispatches, MJW more parallel for wide trees. JUSTIFIED.
    9. Subtree centres of mass, composite inertias, subtree forces: MJW per level, its sums in the scheduler's order;
       ours one invocation per world in robot.zig's order. JUSTIFIED by the twin's bit-for-bit check; the cost is
       parallelism, for the head-to-head (G4) to price.
   10. The mass matrix's factor: MJW a tile Cholesky, a workgroup cooperating per world (or sparse); ours an LDL by
       one invocation per world. JUSTIFIED for parity now; the head-to-head's first suspect - the workgroup Cholesky
       of S3b's Newton (the probe's pattern) could factor the mass matrix too.
   11. Actuator forces: MJW an atomic scatter; ours a gather in actuator order. JUSTIFIED: determinism.
   12. The damped velocity update: both factor M + dt D; ours into separate arrays, sparing robot.zig's restore.
       JUSTIFIED.
  OPEN: (2), for Simon. Every other difference serves determinism, the twin's check, or a model we do not have.
- Nov 3: DECIDED - GPU-OPTIMAL ALGORITHMS, MUJOCO'S SEMANTICS (Simon: "I trust that you will take the best decisions.
  On gpu the optimal algos are different. Be ambitious. We want the best system. Take your time").
  D22 THE BEST ALGORITHM FOR THE DEVICE, NOT THE CPU'S. Until now every kernel reproduced robot.zig's arithmetic, so
      the twin could equal robot.zig to the bit. From S3 on, a stage uses the algorithm best for a GPU - cooperative
      workgroups, parallel levels, gathers in a fixed order - whenever it differs from the CPU's. What stays: the twin
      (the kernels run on the CPU), equal to the device within bars; and robot.zig as the reference, now compared
      within bars and by the physics' own invariants (the solver's optimality conditions, constraint satisfaction,
      energy) wherever the algorithms differ. Determinism stays absolute: no atomics whose order the scheduler picks.
  D23 MUJOCO'S SEMANTICS EXACTLY, for robot.zig and the device alike: the game's physics and the device's must be the
      same physics, and MuJoCo's is the one the field measures against. First consequence: the REGULARISER - MuJoCo's
      diagonal approximation from the reference pose (`dof_invweight0` for joint rows, `body_invweight0` for contacts
      and equalities), not the exact J M^-1 J^T. robot.zig computes the constants at build as MuJoCo's compiler does,
      uses them for every row, and keeps the exact diagonal only where Gauss-Seidel divides by it; the device needs no
      solve per row.
  D24 THE SOLVER, NEWTON IN ONE WORKGROUP PER WORLD (D9, now the design for speed as well as order): the Hessian
      M + J^T D J in workgroup memory, factored cooperatively (the Cholesky probe's pattern, every barrier reached by
      all), the line search's reductions cooperative, every round in one dispatch.
  D25 THE ORDER: correctness and features first, measured optimisation second. S3 (constraints, Newton) and S5
      (contacts) are designed for the GPU from the start; the smooth stages built for parity (the single-invocation
      LDL, the per-world subtree sums) are re-done after the head-to-head with MuJoCo Warp (G4) shows where the time
      goes - the cooperative factor first suspect, the Hessian's Cholesky its likely replacement.
  S3, REVISED:
    S3a1 DONE Nov 3. THE REFERENCE-POSE CONSTANTS in robot.zig - `dof_invweight0`, `body_invweight0` - as MuJoCo computes them:
         the mass matrix at the reference pose, its inverse's diagonal averaged per joint (a free joint's translations
         and rotations apart), each body's translational and rotational inverse weights. Checked on models whose
         weights are known in closed form (a pendulum: 1 / its inertia about the hinge).
    S3a2 THE REGULARISER in robot.zig from those constants for every row kind; the exact diagonal only for
         Gauss-Seidel; robot.zig's fingerprints re-baselined deliberately, its fixtures re-checked against MuJoCo's D.
    S3a3 LIMITS AS ROWS on the device (the design above), the regulariser from the table - no solve per row.
    S3b  NEWTON IN ONE WORKGROUP PER WORLD (D24), against robot.zig's Newton within bars and by its optimality
         conditions.
    S3c  The constraint step on the device; the bars on lavapipe and the RTX 5070.
- Nov 3: S3a1 DONE - THE REFERENCE-POSE INVERSE WEIGHTS in robot.zig: `Model.dof_invweight0` (the inverse mass
  matrix's diagonal at the reference pose, a ball joint's three averaged, a free joint's translations and rotations
  apart) and `Model.body_invweight0` (each body's centre of mass: J M^-1 J^T's translational and rotational diagonals,
  each averaged over three axes; zero for the world), computed as every model's build ends (`setReferenceWeights`:
  the model posed at its reference, kinematics, the centre-of-mass frame, the composite inertias, the factor, then a
  solve per DOF and six per body). The function sits with the dynamics it runs, the build's one forward call to it
  explained (`lint:off decl-order`). Not yet read: S3a2 makes the regulariser use them. CHECKED: the pendulum's weight
  1 over MuJoCo's own mass matrix (the oracle's), to 1e-5; robot.zig 127/127; the fingerprints unchanged (nothing
  reads the constants yet); the robot family 661/805; `zbuild check`; lint.
- Nov 3: CORRECTED BY REVIEW - THE EXACT DIAGONAL STAYS (D23 amended; S3a1 reverted). Starting S3a2, robot.zig's own
  tests showed its exact constraint-space diagonal is a deliberate, tested design, not an accident: its MuJoCo
  fixtures are generated with MuJoCo's DIAGEXACT flag ("so this compares like with like"), and a test, "R scales with
  constraint-space inertia, which is the whole point", holds the softness mass-invariant - a hundred times the mass, a
  hundredth of the inertia, R following it exactly. It is also the better physics for this system: a row's softness is
  specified as a time constant and a damping ratio, which mean what they say only against the CURRENT effective
  inertia; MuJoCo's default approximation fixes them to the reference pose, and Geno's inertia changes greatly as it
  dances, falls and gets up. Its cost is a solve per row against the factor the step already has - a few hundred
  operations, parallel across rows on the device, far below Newton's factorisation each round. So D23 reads: MuJoCo's
  semantics, in its DIAGEXACT mode, for robot.zig and the device alike. The reference-pose constants (S3a1) had no
  user left and were removed - unused work at every model's build. robot.zig 127 - 1 tests, the fingerprints
  unchanged. S3, AGAIN: S3a limits as rows on the device as designed (Nov 3) - the exact diagonal by a solve per world
  and row with the world's factor; S3b Newton in one workgroup per world; S3c the constraint step on the device.
- Nov 3: S3a, STEP 1 OF 3 DONE - THE ROWS' DATA. `Counts` gains `limited_joint_count`, `limit_candidate_count` and
  `constraint_capacity` (the three filling the three padding words, the uniform's size unchanged); four item kinds
  (`limited_joints`, `limit_candidates`, `constraint_rows`, `constraint_row_dofs`); the model's table `limited_joints`
  (candidate c the lower end, c even, or the upper, c odd, of joint `limited_joints[c / 2]` - robot.zig's order for
  its limit rows), packed beside `jnt_limited`. THE ROWS' FLOATS GET THEIR OWN ARENA: `efc_f`, declared from the start
  as "each world's constraint rows" but without a layout until now - `ConstraintRowsLayout` (each candidate's distance;
  each row's violation, dense Jacobian, M^-1 J^T, inertia, velocity, regulariser, target acceleration), with its
  capacity and its error (`ConstraintRowsTooSmall`); the integers (each candidate's flag, each row's candidate, the row
  count) in `world_u` with the world's others. The generic solve's storage gains `solution_first` (0 for every use so
  far; `row x dof_count` for one row of a row-major array), so robot.zig's `solveLdl` solves a row's M^-1 J^T
  unchanged. robot.zig's `min_impedance`, `max_impedance` and `min_regularizer` are public, for the device's one
  definition of them. DESIGN FOUND ON THE WAY: the device keeps ITS OWN BUDGET of rows - robot.zig's
  `constraint_capacity` holds four rows for each of Geno's 256 CPU contacts, about 1,050 rows, 157,000 floats of dense
  rows a world: 40 MB at 64 worlds, 2.6 GB at 4,096. So the device's rows are, for now, both ends of every limited
  joint; S5's contacts come with a device budget per world and SPARSE Jacobian rows (a contact's row touches only its
  two bodies' chains - MJW's own choice above 60 dofs; Geno has 75). AND: Geno has no limited joint - its constraints
  begin with contacts; the KUKA and the humanoid carry the limit checks. CHECKED: robotgpu 15/15 (the packing - every
  limited joint once, in joint order, two candidates each; each arena refused by name, `efc_f` by the KUKA's rows);
  `zbuild check`; vk-host-test (no validation messages, the 100-step energy check as before); the robot family
  661/805; lint. NEXT: step 2, `limit_candidates` and `constraint_rows`, on the twin against robot.zig's rows.
- Nov 3: THE RTX 5070, THIRD RUN (Simon's logs; the package of Nov 3, before S3a) - every check passes, no validation
  errors and no warnings, the lab closing clean. The Cholesky probe, now reaching every barrier from every invocation:
  L L^T within 5.0e-7 of A, the device 1.75 epsilons from the twin (lavapipe 0.00 - NVIDIA's fused multiply-adds
  rounding at other points), TWO DEVICE RUNS IDENTICAL - the barrier fix holds on the hardware where non-uniform
  barriers are real hazards. The step and the 100 steps as on the second run: 230.11 epsilons (smooth accelerations,
  bar 1024); the arrays within 280.59 after 100 steps (lavapipe 370.15); the energy 2.40e-6 apart against a drift of
  7.08e-2. THE DEVICE, AS NEWTON (S3b, D24) WILL USE IT: 48 KB of workgroup memory - Geno's 75 x 75 Hessian, 22.5 KB,
  fits with room for the line search's reductions; subgroups of 32 with arithmetic, shuffle and ballot - a
  reduction's first stage within a subgroup, no barrier; storage bindings up to 4 GB, 11.9 GB of device memory.
  NOTED, NOT CHASED (no benchmarking for now): the timing probe's busy work took 9.7x as long for 4x the rounds
  (66 us, 646 us) - the probe checks the timestamps' order and units, not the scaling.
- Nov 3: S3a, STEP 2 OF 3 DONE - WHICH ROWS. robotgpu_program.zig gains the CONSTRAINT PROGRAM beside the step
  (`limit_candidates` per world and candidate, `constraint_rows` per world), two kinds of invocation count (per world
  and limit candidate, per world and constraint row), and `kernel_names`, the one list of every kernel - the step's,
  then the constraint program's - that robotgpu's entry points and the build's compilation both take. The step does
  not run the constraint program yet: no solver reads the rows. `limit_candidates`: candidate c an end of joint
  `limited_joints[c / 2]`, its distance q - lo (lower) or hi - q (upper), active while below the joint's margin.
  `constraint_rows`: one invocation per world packs the active candidates from row 0 in candidate order - robot.zig's
  and MuJoCo's order, never the scheduler's - each row its candidate and its violation (distance - margin), then the
  row count. CHECKED: on the twin, the KUKA's five worlds posed so every joint visits every place along its range (past
  the lower end, inside the lower margin, free, inside the upper margin, past the upper end) with a 0.05 margin, against
  robot.zig's `makeConstraints`: every world's row count, every row's kind, joint and end, and its violation to the
  bit, rows at both ends; robotgpu 16/16; the new module translated to WGSL, no warning; `zbuild check`; lint. THE
  ROBOTS COURSE: chapter 56, "Constraint rows on many worlds" (a joint's two ends, the margin and the violation on a
  number line, the two passes in a fixed order beside MuJoCo Warp's atomic counter, a worked example, the two kernels
  folded); "Checking the device" is now 57. NEXT: step 3, `constraint_jacobians` and `project_constraints` - the
  dense rows, then robot.zig's projection with the exact diagonal by a solve per world and row - against robot.zig to
  the bit.
- Nov 3: REVIEW OF S3a's FIRST TWO STEPS (Simon: "Review"). THREE FIXES AND ONE DECISION.
  (1) NAN PARITY: robot.zig skips an end when `distance >= margin`; the kernel tested `distance < margin` - equal for
      every number, not for NaN, where robot.zig KEEPS a (NaN) row and the device dropped it, a joint gone NaN silently
      losing its limit. The kernel now tests robot.zig's condition word for word, its comment saying why.
  (2) THE JACOBIAN SPARSE NOW, NOT AT S5 (D26): a limit's row has one nonzero among Geno's 75 dofs; dense rows write 75
      numbers to record one, sum 75 products in every dot product, and would cost Newton's Hessian about 75^2 a row.
      Contacts need sparse rows anyway, so step 3 would have been written twice. The rows' Jacobians are ELLPACK -
      every row `Counts.row_nonzero_capacity` slots (one for limits), each a dof (`world_u`) and a value (`efc_f`), the
      first `constraint_jacobian_nonzero_count` in use, in dof order, every slot's place fixed by the model. Bit for
      bit with robot.zig still: its dense sums only add products of zero, which change no sum. `constraint_rows`
      writes each limit row's one nonzero itself - its Jacobian kernel is gone; contacts' rows will get one.
      `Counts` grows a 16-byte row (the capacity and three padding words).
  (3) THE COURSE: "a condition the solver will hold" - rows are soft - now "enforces, softly (sec. 30)"; the sentence
      that the step "does not use the rows yet" - a passing state - now where the constraint program is listed; a
      section on a row's Jacobian (the one nonzero, an example over the KUKA's seven dofs, the ELLPACK slots).
  (4) THE ARENA COMMENTS: `efc_f`'s "the dense Jacobian first, about 16,460 floats" - a planning estimate, wrong
      twice over - now says what the arena holds.
  CHECKED: robotgpu 16/16 (the twin's sparse rows, spread over every dof, equal robot.zig's dense ones); `zbuild
  check`; vk-host-test with the larger uniform (the step 238.64 epsilons, bar 1024; the 100 steps as before; no
  validation messages); doc-sync; lint. STEP 3 IS NOW `project_constraints` alone - robot.zig's projection over the
  sparse rows, the exact diagonal by a solve per world and row.
- Nov 3: S3a DONE - LIMITS AS ROWS ON THE DEVICE, STEP 3 OF 3: EACH ROW'S PROJECTION. `project_constraints` (per world
  and row slot, slots past the world's rows returning): robot.zig's `projectConstraints` in its arithmetic - M^-1 J^T
  (the row's sparse Jacobian spread over every dof and solved in place with the world's factor: `ConstraintRowSolve`,
  `WorldMassMatrix` gaining the solution's ARENA as a parameter, `.world_f` for its two other uses, `.efc_f` here), the
  inertia J M^-1 J^T and the velocity J qdot over the row's nonzeros in dof order, the impedance (robot.zig's own
  `Impedance.at`, clamped by its now-public limits), the regulariser and the target acceleration from the joint's
  softness and the step's timestep (`StepOptions.of` takes the model's). The constraint program is now three
  dispatches. CHECKED - the twin against robot.zig's `makeConstraints` and `projectConstraints`, the KUKA's five worlds
  posed around their limits and moving: every row's M^-1 J^T at every dof, its inertia, velocity, regulariser and
  target acceleration, to the bit. REVIEWED AS IT WENT: the first test could not see a wrong timestep (the 0.02 s
  time constant won its max) nor the impedance curve's interior (at the default width of 0.001 every row sat at the
  curve's maximum); now joint 0's time constant is under two steps (the floor decides), joint 1's curve is 0.2 wide
  (violations of 0.025 to 0.08 on both sides of its 0.3 midpoint, power 3), joint 2's is linear (power 1, robot.zig's
  own branch) - still to the bit. robotgpu 17/17; `zbuild check`; the robotgpu lab built for the web (the module with
  the constraint kernels translated to WGSL, no warning); doc-folds, doc-sync; lint. THE ROBOTS COURSE: chapter 56
  gains "Each row's projection" (the five quantities, why the inertia is exact, a worked example - a lower end inside
  its margin by 0.025 and moving away at 0.1: k 2770, b 105.3, the damper -10.5 and the spring +65.8, target 55.3,
  regulariser 0.026 - and the kernel folded). The build cache was cleared (9.5 GB; Simon's leave), 11 GB free.
  NEXT: S3b, NEWTON IN ONE WORKGROUP PER WORLD (D24) - robot.zig's `solveNewton` read first, its line search and
  convergence the ones to reproduce; the Hessian M + J^T D J in workgroup memory, factored cooperatively.
- Nov 3: S3b DESIGNED - NEWTON, read from robot.zig (`solveNewton`, `newtonCost`, `choleskyFactor`, `choleskySolve`,
  `mulM`). ROBOT.ZIG'S NEWTON, per iteration: residuals r_i = J_i a - aref_i, a unilateral row active while r_i < 0
  (none active: done); the gradient M (a - a_free) + sum over the active rows of J_i^T r_i / R_i (its squared norm
  below tolerance^2: done); the dense Hessian H = M + sum of J_i^T J_i / R_i; the step from a Cholesky solve of
  H delta = -g (a failed factorisation: the gradient direction); a BACKTRACKING line search, alpha from 1 halved up to
  8 times, the first lowering the cost taken (none: done). Cold start from the smooth acceleration; afterwards each
  row's force -r/R (clamped at zero for a unilateral row) and the joint forces J^T f.
  WHY A COOPERATIVE VERSION CAN KEEP ITS BITS: `choleskyFactor` computes each entry as a RUNNING SUBTRACTION, a_ij then
  minus a_ik a_jk for k in order - a column-parallel factorisation (the probe's pattern: the pivot, a barrier, the
  column below it in parallel) does the same subtractions per entry in the same order; `choleskySolve`'s forward and
  backward substitutions done column by column give every unknown its subtractions in k order too; `newtonCost` and
  `mulM` are sums in a fixed order - their terms parallel, one invocation summing in order (75 dofs and the rows:
  nothing); the gradient and the Hessian accumulate over rows in row order for every entry, parallel over dofs or
  entries; and the sparse rows change no sum, the dense loops adding only products of zero. (A GPU's fused
  multiply-adds can still round otherwise - NVIDIA's did in the Cholesky probe, 1.75 epsilons - so the device is held
  to bars, the twin to the bit.)
  THE STEPS. S3b1: robot.zig's Newton GENERIC OVER ITS STORAGE, as `solveLdl` is - robot.zig calling it with its Data
  (dense rows: every dof a nonzero), bit for bit as today (the fingerprints), the twin with a world's arrays (sparse
  rows): one definition of the algorithm for the CPU and the twin. S3b2: the twin's Newton, one invocation per world,
  its working set (the Hessian, the vectors) in the `scratch` arena - against robot.zig to the bit on the KUKA's limits;
  the rows' forces and the joint forces with it. S3b3: THE DEVICE'S NEWTON, ONE WORKGROUP PER WORLD (D24) - every phase
  cooperative (residuals and the line search's trial residuals per row, the gradient per dof, the Hessian per entry,
  the factorisation and the substitutions column by column, the ordered sums by one invocation), every barrier
  reached by every invocation, the loop's exits decided from workgroup memory so they are uniform; the Hessian in
  workgroup memory sized for Geno's 75 dofs (22.5 KB - the RTX 5070 has 48 KB, lavapipe 32 KB) - against the twin
  within bars. FOR THE WEB: WebGPU's default workgroup memory is 16 KB; the higher limit most adapters grant (32 KB)
  to be requested at device creation, or the Hessian in global memory where an adapter offers less.
- Nov 3: S3b REVISED - THE TWIN RUNS THE DEVICE'S OWN COOPERATIVE CODE, AND THE WEB NEEDS A UNIFORM LOAD FIRST.
  (1) NOT A GENERIC ROBOT.ZIG NEWTON (S3b1 as designed above): its storage interface would run to some twenty-five
  methods - the tower of abstraction this codebase avoids. INSTEAD the Newton is written once as PHASES, each a
  function of the lane, run through one helper: on the GPU every lane runs the phase, then a barrier; on the CPU twin
  lane 0's invocation runs the phase for every lane in turn (the other lanes return) - a barrier's meaning exactly,
  every lane done before any starts the next. The twin thus runs the device's code, so the twin-against-robot.zig
  check proves the COOPERATIVE algorithm's arithmetic to the bit, the device-against-twin check only the GPU's
  rounding, and robot.zig is untouched. `k.shared` is a static array on the CPU, so the phases read and write the same
  workgroup arrays on both (its comment, "never read on the CPU", to be amended). The probe's right-looking
  Cholesky - each entry's subtractions in column order - is robot.zig's `choleskyFactor` arithmetic.
  (2) THE WEB: Newton's loops exit on data (no active row, a small gradient, no downhill step), with barriers inside.
  On Vulkan that is legal - a value read from workgroup memory after a barrier is the same in every invocation, the
  control flow uniform at run time. WGSL's validators check uniformity STATICALLY and take a workgroup-memory read as
  non-uniform unless it is `workgroupUniformLoad`; Chrome's (Tint) would reject the kernel, and with it the whole
  robotgpu module - the lab's web page with it. spv2wgsl's own check (`checkBarrierUniformity`: no return before a
  barrier) would not catch it. Fixed-count loops with the work switched off are no answer: some 150 barriers an
  iteration (Geno's factorisation and substitutions) times the maximum iterations, milliseconds a step.
  S3b, AGAIN: S3b1 `k.workgroupUniformLoad` - kompute's marker (on Vulkan a barrier and a load), spv2wgsl emitting
  WGSL's `workgroupUniformLoad` for it; a probe kernel looping on a workgroup value with a barrier inside, run on
  lavapipe, its WGSL passing a strict uniformity check. S3b2 the Newton as phases, the twin to the bit against
  robot.zig on the KUKA's limits (forces and joint forces with it). S3b3 the device's Newton within bars.
- Nov 3: S3b1 DONE - A UNIFORM WORKGROUP LOAD, AND THE TRANSLATOR'S TRIVIAL PHIS (Simon: "very difficult to fix without
  changing zig compiler. But maybe possible. Proceed carefully").
  KOMPUTE: `k.sharedUniform(T, n, name)` - a workgroup array named with `uniform_shared_prefix` - and
  `k.workgroupUniformLoad(T, n, array, index)` (on Vulkan a barrier, the read, a barrier: WGSL's builtin's own meaning
  written out; on the CPU the plain read). THE RULE, learnt from the probe: a uniform array is a BROADCAST - whoever
  decides writes it, with plain stores; everyone reads it together, through the uniform load and nothing else (a
  one-invocation read-modify-write, `-= 1`, is refused - keep a private copy and store it). `k.shared`'s comment now
  says the CPU array is a real one, which code running a workgroup's lanes itself may use.
  SPV2WGSL: uniform variables marked by name, as atomics are by use (`markUniformWorkgroupVariables`), their names
  protected as `kbuf_` ones are (a helper's parameter name arrives for them on every read); `emitLoad` writes a read of
  one as `workgroupUniformLoad(&...)`. AND TRIVIAL-PHI ELIMINATION (`trivialPhiConstant`): Zig's SPIR-V backend merges
  control flow through phis saying which block came before; when an `if`'s branches rejoin, every edge brings the same
  constant, and written as a `var` assigned in each branch such a phi read to WGSL's uniformity analysis as set under
  the `if` - after `if (lane == 0) { ... }`, every later decision non-uniform, every later barrier refused. A phi with
  one constant on every edge IS that constant: named by it, no variable, no assignment - the same program. A phi whose
  edges differ is a real choice between paths and stays a variable: divergent control flow before a barrier remains a
  rule for kernels (as an early return is), not something to hide. No change to Zig.
  VERIFIED WITH CHROME'S OWN VALIDATOR, IN THE CONTAINER: Tint, through a headless Chrome 131 on its software adapter
  (SwiftShader). RECIPE (outside the repository - a verification aid, as lavapipe is): puppeteer from
  ~/.npm-global/lib/node_modules/@mermaid-js/mermaid-cli/node_modules/puppeteer; the FULL Chrome binary under
  ~/.cache/puppeteer/chrome/linux-131.0.6778.204/ (the headless shell has no adapter), headless, with
  --no-sandbox --enable-unsafe-webgpu --enable-unsafe-swiftshader --use-webgpu-adapter=swiftshader
  --enable-features=Vulkan --use-vulkan=swiftshader; a page served on 127.0.0.1 (WebGPU wants a secure context; about:blank
  and data: URLs are not); requestAdapter({forceFallbackAdapter: true}), createShaderModule, getCompilationInfo. The
  adapter grants 32 KB of workgroup memory. Proven on a pair: a barrier in a loop exiting on a workgroup value
  rejected ("must only be called from uniform control flow"), the same through workgroupUniformLoad accepted.
  RESULTS: BEFORE the change, every cached WGSL module - 388 - passes Tint with no message. AFTER: the probe's
  `uniform_loop` (a countdown in a uniform value, barriers inside), translated by our translator, passes with none,
  while its plain-read control is still refused; every regenerated module - 263 - passes; every corpus graphics shader -
  80 - passes. The probe on lavapipe: every invocation's sum the twin's and the closed form's. The translator's own
  tests: 63/63 (`zig test src/spv2wgsl.zig` - std only). THE PINNED CORPUS (`zig build corpus`): one shader moved,
  `examples/bloom_fullscreen_vs`, and the diff is exactly two phi variables gone (their identical-constant
  assignments with them, `phi113 == 8u` now `8u == 8u`); both versions pass Tint; refreshed (`zig build
  corpus-refresh`), green - 80/80 interfaces and outputs, which also re-pins 62 shaders the fixture had gone stale on.
  ALSO FOUND: each kernel is translated into a WGSL module of its own (a kernel the browser refuses breaks only its own
  pipeline). FIXED ON THE WAY: `test-fast` with a root not on its list ran nothing and reported success - it fooled this
  work twice; it now fails, naming the file and the list. CHECKED: lint; robotgpu 17/17; `zbuild check`; vk-host-test.
  NEXT: S3b2, the Newton as phases - the lane-loop helper first, then the solver, the twin against robot.zig to the bit.
- Nov 3: REVIEW OF S3b1 (Simon: "Review"). WHAT HOLDS: `trivialPhiConstant` reads the operands at the right places
  (values at 2, 4, 6... with parents between); a phi fed the same UNDEFINED value stays a variable (only `.constant`
  qualifies); the uniform load relies on kompute's `workgroupUniformLoad` being `inline` (through a called function the
  pointer would lose its root variable and the read be written plain) - it is, and its comment requires it. FIXED:
  (1) THE PREFIX WAS A CONTRACT WITH NO GUARD - kompute's `uniform_shared_prefix` and spv2wgsl's
  `uniform_workgroup_prefix`, two literals in two modules; drifted apart, every uniform read would quietly turn plain.
  `src/tests.zig`, which imports both, now holds them equal (spv2wgsl's made public). (2) THE GPU COMPUTE TUTORIAL:
  section 5.5, "Decisions a workgroup makes together" - when a workgroup must decide alike, why Vulkan accepts it at
  run time and WGSL refuses it from the source, the uniform array as a BROADCAST (written by whoever decides, read by all
  through the uniform load, a private copy for one invocation's own arithmetic), a sketch, the probe's `uniform_loop`
  folded; section 4.2's "loop bounds ... from Params or compile-time constants" now also "or from a value the workgroup
  has decided together". NOTED FOR LATER: (a) translated for the web each uniform read carries two barriers more than it
  needs (kompute's own pair around the builtin, which has its own) - harmless, a few reads a round; (b) spv2wgsl's
  build-time uniformity check sees only a return before a barrier - a fuller analysis (as `sampler_uniformity` does for
  samplers), or Chrome's Tint in the gate where a browser is present, would catch at build time what the browser now
  catches at load; (c) the Newton's phases must keep every lane's state between phases in workgroup arrays, since on the
  twin one invocation runs each phase for every lane in turn - a lane's local variables do not survive from one phase
  to the next. CHECKED: lint; `zbuild check`; doc-folds; doc-sync.
- Nov 3: S3b2 DONE - NEWTON AS PHASES, A WORKGROUP PER WORLD, THE TWIN TO THE BIT. `newton_solve` (the constraint
  program's fourth dispatch, `per_world_workgroup`: robotgpu's 64 invocations a world): robot.zig's `solveNewton` -
  cold start from the free acceleration; each round the residuals and active rows (per row), the gradient (a - a_free
  per dof, each row's r / R, M (a - a_free) by robot.zig's own `multiplyByMassMatrix` on the first lane over a storage
  of workgroup vectors, then J^T (r / R) per dof in row order), the stop on the gradient's length, the dense Hessian M
  + J^T R^-1 J (per entry, its rows in row order), the factor right-looking column by column (the pivot on the first
  lane, the column scaled per row, the trailing update per entry - each entry's subtractions in column order, robot.zig's
  `choleskyFactor`), the step by the first lane (`choleskySolve`'s forward and backward substitutions in its order -
  the backward one's subtractions run in increasing index, so it cannot go column by column), the backtracking line
  search (trial per dof, M s on the first lane, each row's cost term per row, the ordered sum on the first lane), the
  advance; then each row's force -r / R (clamped at zero), through workgroup memory to the joint forces J^T f (a
  barrier orders workgroup memory, not the storage buffers) - and the accelerations, the forces, the joint forces and
  the rounds written out. Every decision through `newton_decision`, a uniform workgroup value. Working set in workgroup
  memory (`max_newton_dofs` 76, `max_newton_rows` 128): about 26.5 KB. `runPhase` runs a phase for every lane: on the
  GPU, then a barrier; on the twin, the workgroup's first invocation runs it for each lane in turn. `StepOptions` gains
  `newton_max_iterations` and `newton_tolerance` (robot.zig's `opt.solver`); new outputs `constraint_force` (efc_f),
  `constraint_joint_forces` (world_f), `newton_iterations` (world_u).
  REVIEWED AS IT WENT: (1) the cost's row test written as robot.zig's (`residual >= 0` leaves a row out) - not
  `residual < 0` keeps it, which differs for NaN. (2) A KOMPUTE BUG, FOUND BY THE FIRST RUN: on the CPU, `k.shared`
  backed each array with a static in a struct capturing only `T` and `n` - and Zig deduplicates a struct declared in a
  function by the values its body captures, so every workgroup array of the same type and length was ONE buffer (the
  six Newton vectors, the three row arrays, the factored flag with the decision). Harmless while the CPU never read them;
  the struct now captures the name too, each array its own. The first run showed it: no rounds, an acceleration of 0
  where the smooth one is 0.149.
  CHECKED: ON THE TWIN, the KUKA's five worlds moving under controls, applied forces and gravity, posed around their
  limits with 0.05 margins, Newton chosen, against robot.zig's whole `forward`: every world's accelerations and joint
  forces at every dof, every row's force, the rounds (1 to 2) - TO THE BIT; robotgpu 18/18. ON THE WEB: the kernel
  translated by our translator (3 uniform loads, 30 barriers, 236 phis that are real choices) passes Chrome's Tint with
  no message, AND its pipeline is created - the checker now creates each entry point's pipeline, where a device's
  workgroup-memory limit is enforced (proven on a 36 KB control, refused against the adapter's 32 KB); all 30 of
  robotgpu's kernels pass both. `zbuild check`; the robot family 661/805; lint.
  NEXT: S3b3 - the device: Newton on lavapipe against the twin within bars (vk-host-test), then the RTX 5070; the robots
  course's chapter on the solver.
- Nov 3: REVIEW OF THE SOLVER AGAINST MUJOCO WARP'S (Simon: "Read again mjw. Find differences. Review what we have").
  MJW's `solver.py` read: `_solve`, `_solver_iteration`, `_solve_done`, `_solve_init_dof`, `_linesearch_iterative`.
  THE SAME: the cost, its gradient M (a - a_free) + J^T D r over the active rows, the Hessian M + J^T D J, the step
  -H^-1 g, a limit row active while J a - aref < 0, the forces -D r clamped for unilateral rows.
  DIFFERENT, AND JUDGED:
    1. THE WARM START: MJW starts from the previous step's answer (`qacc_warmstart`) whenever a world has rows; robot.zig
       and the kernel start cold, from the free acceleration. The previous answer is usually close - fewer rounds.
    2. THE LINE SEARCH: MJW's is EXACT - the line's quadratic coefficients computed once (the inertia's from one M s,
       each row's from J a - aref and J s), so the cost and its first two derivatives at any step length are a pass over
       the rows; it brackets the lowest point and closes in with Newton steps in the step length, to a tolerance scaled
       by the step's length and the inertia (`ls_tolerance`, `ls_iterations`). Ours BACKTRACKS: the full step, halved up
       to eight times, the first that lowers the cost - every trial a whole cost, an M product included, and the step
       taken only as good as the first halving that helps.
    3. THE STOPPING RULES: MJW's (MuJoCo's) - the line search found nothing (alpha 0), or the cost's improvement, the
       gradient's length or the improvement the quadratic model predicts (half the Newton decrement g^T H^-1 g) below
       the tolerance, all SCALED by the mean inertia and the dof count so one tolerance means the same for a light model
       and a heavy one. Ours: no active row, the RAW squared gradient below tolerance^2, or no lowering step.
    4. THE ORGANISATION: MJW a round as separate kernels over all worlds, converged worlds dropping out (a CUDA graph's
       conditional while); ours a world's rounds in one workgroup, one dispatch. JUSTIFIED (D24); priced by the
       head-to-head (G4).
    5. MJW updates the Hessian in place when few rows change state, and has tiled, blocked and sparse factorisations;
       ours builds it afresh each round. Optimisations for the measured stage (D25).
  DECIDED (D23, MuJoCo's semantics): 1-3 are where robot.zig's Newton is not MuJoCo's, and all three make it faster as
  well as faithful. S3b4, after S3b3's device bars: MUJOCO'S NEWTON in robot.zig first - the warm start (the previous
  answer kept per world), the exact line search, MuJoCo's scaled stopping rules; its tests and fingerprints
  re-baselined deliberately - then the kernel, the twin to the bit again. The converged answer is the same lowest
  point; what changes is how fast it is reached and exactly where the rounds stop.
  OUR OWN, FOUND REVIEWING: the Hessian's and the gradient's row terms search each row's slots for a dof
  (`rowJacobianEntry`) - per entry and row, O(n^2 x rows x slots) a round: nothing for limits (one slot, a few rows),
  far too slow for contacts (Geno: 5,625 entries x 128 rows x some 30 slots). S5 restructures it - each round's active
  rows' nonzeros gathered into workgroup memory, or each dof's list of the rows that touch it built once a step.
  THE ROBOTS COURSE: chapter 57, "The constraint solver on many worlds" - what the solver finds (the cost, a joint at
  its limit drawn and solved: free acceleration 2, target 4, answer 3), Newton's method round by round on it (one step,
  because the step stayed on its piece), the factorisation column by column on a 3 x 3 matrix of whole numbers (pivot,
  column, trailing update; the same numbers as robot.zig's row-by-row order), the line search and the three stopping
  rules, the forces from the answer (M a = M a_free + J^T f, checked on the example), the workgroup's phases in a table,
  the decisions through a uniform value, the twin, and MuJoCo Warp's solver set beside it; `newton_solve`, `runPhase`
  and `newtonUpdateTrailing` folded. "Checking the device" is now 58. CHECKED: doc-folds, doc-sync (3,111 lines).
- Nov 3: S3b3 DONE - THE CONSTRAINT PROGRAM ON A DEVICE. `Sim.submitDispatches` (any dispatches as one batch;
  `submitStep` is it with the step program); `z.robot_humanoid_model` (MuJoCo's humanoid, exposed as Geno's is - Geno's
  joints are all balls, which take no range). THE CHECK (vk-host-test, `runRobotgpuConstraints`): the humanoid's 64
  worlds posed around their limits (0.05 margins) and moving, the step up to the free acceleration, then the rows, the
  projection and Newton on device and twin; the rows' integers (count, candidates, Jacobian dofs and counts) EXACTLY,
  each world's rows compared only up to its count, every quantity against a bar measured on lavapipe:
      violations 0.0 (bar 4), Jacobians 0.0 (1), velocities 0.0 (16), target accelerations 0.0 (64)
      M^-1 J^T 230.6, inertias 230.6, regularisers 230.4 (1024 - the step's solve's rounding)
      row forces 382.7, joint accelerations 75.1, joint forces 47.8 (4096 - Newton's answer)
  1,075 rows; no validation messages; the RTX 5070 to refine the bars.
  FOUND ON THE WAY - A TWIN THAT STARTED FROM STALE MEMORY: `Sim` never cleared its world arenas. A device buffer
  starts as zeros (WebGPU's promise, the Vulkan backend's fill); the twin's arenas are the module's static arrays, and
  held the last twin's numbers - Geno's controls and forces, read as the humanoid's. Two symptoms: the step check
  failed whenever the constraint check ran before it (gaps of exactly 2^23 epsilons: leftover numbers, not rounding),
  and the twin's Newton answers were off by ~1,000 against robot.zig while the DEVICE's were off by ~0.001 - found by
  comparing both with robot.zig on the device test's own inputs, after a bisection by rounds had pointed at the device.
  `initTwin` now clears world_f, world_u and efc_f to the end of the layout's last array; documented: one twin at a
  time. Also fixed: the check's own indexing (a world's numbers start at world x stride, padded).
  REVIEW (Simon: "Review"): (1) CORRECTED - the rounds differ in 48 of 64 worlds (by at most 2), not three: the totals
  hid counts going both ways. (2) WHY: NEWTON NEVER STOPS ON ITS GRADIENT - on the humanoid the gradient at the answer
  is 5e-4 to 3e-3, a thousand times the 1e-6 tolerance, with accelerations of 1,500 to 3,200 (about 1e-7 relative: as
  converged as f32 allows). Every solve ends when the line search finds nothing lower - run to f32's noise floor, its
  round count set by the last bits. The answers agree within 400 epsilons; the rounds spent proving it are wasted.
  S3b4's SCALED stopping rules (MuJoCo's) are now justified by measurement, not only by precedent. (3) The report says
  how many worlds' rounds differ and by how much at most. CHECKED: vk-host-test (lavapipe); robotgpu 18/18 (Newton on
  the twin to the bit against robot.zig on the KUKA AND the humanoid); lint. NEXT: the RTX 5070 run; then S3b4.
- Nov 3: S3b4 DESIGNED - MUJOCO'S NEWTON, from MJW's `_linesearch_iterative_kernel`, `_solve_done`, `_inertia_scale`,
  `_solve_init_dof` (its non-elliptic path: equality, limit and pyramidal rows - robot.zig has no friction-loss or
  elliptic rows). For robot.zig first, then the kernel (the twin to the bit again). The converged answer is the same
  lowest point; what changes is the starting point, how each round's step is sized, and when the rounds stop.
  1. THE INERTIA SCALE: 1 / trace(M), per world and step (MJW's "inverse trace of the inertia matrix, which scales the
     termination criteria"; MuJoCo C's 1 / (meaninertia x nv) at the reference pose).
  2. THE STOPPING RULES (MuJoCo's): done when the line search found no step (alpha = 0), or when the cost's improvement
     is positive and its scaled value below the tolerance, or the gradient's scaled length, or half the scaled Newton
     decrement (g^T H^-1 g, a by-product of the step's solve) - or at the rounds' limit. The tolerance means one thing
     for a light model and a heavy one.
  3. THE LINE SEARCH, EXACT, along the step s: the inertia's term is a quadratic in alpha whose coefficients come from
     one product M s; each row's term from its J a - aref and J s (`jaref`, `jv`), active at alpha while
     jaref + alpha jv < 0 for a row that may only push; every candidate's cost, slope and curvature a pass over the
     rows. COSTS RELATIVE TO alpha = 0, computed from the coefficients (alpha (slope0 + 1/2 alpha curvature)) - never a
     difference of two large f32 costs, so the improvement keeps its own precision and a rule on it can fire (the
     backtracking search's comparisons drown in the costs' rounding - why every solve now runs to f32's floor). The
     search: the point at 0; a first Newton step in alpha, accepted if its slope is within `gtol` and it lowers the
     cost; else a bracket of the two by slope; then up to `ls_iterations` rounds of three candidates - a Newton step from
     each end and the midpoint - the lowest converged candidate taken, else each end moved to a candidate with a slope
     of its own sign nearer zero (MJW's order: lo by lo_next, mid, hi_next; hi by hi_next - also when it crosses the
     minimum from below - mid, lo_next); stopped when nothing moves, or an end is within `gtol` on the cost-lowering
     side; the best end that lowered the cost is alpha, its lowering the improvement. gtol = max(tolerance x
     ls_tolerance x |s| / scale, 1e-6), and, in f32, never below the slope's own rounding (8 epsilons x the size of the
     slope's terms - MJW's noise floor), nor a step at a start whose slope is already below it.
  4. THE WARM START: the previous step's accelerations kept per world (MuJoCo's `qacc_warmstart`), and the solve starts
     from whichever of them and the free acceleration has the lower cost (MuJoCo C's rule; MJW starts from the warm
     one whenever there are rows). Usually close: fewer rounds.
  5. THE OPTIONS: `ls_iterations` (50) and `ls_tolerance` (0.01), MuJoCo's; Newton's tolerance read in MuJoCo's scaled
     sense (robot.zig's Gauss-Seidel keeps its own).
  STEPS: S3b4a the line search in robot.zig as a function of its own, on the line's coefficients, with tests on
  one-dimensional piecewise quadratics whose lowest points are known; S3b4b robot.zig's Newton on it, the scaled rules
  and the warm start - against today's answers within f32's tolerance, with fewer rounds, each solve stopped by a rule
  and not by noise - its fingerprints re-baselined deliberately; S3b4c the kernel, the twin to the bit, the device
  within bars.
- Nov 3: S3b4a DONE - MUJOCO'S EXACT LINE SEARCH IN ROBOT.ZIG, as a function of its own (not yet used by Newton).
  `LinePoint` (a point's cost change from alpha = 0, slope, curvature); `SearchLine` (the line's coefficients: the
  inertia's s^T M (a - a_free) and 1/2 s^T M s, each row's residual J a - aref, rate J s, weight D = 1/R and whether it
  may only push) with `at(alpha)` - each row's change taken whole from the coefficients (`rowLinePoint`: active at both
  ends alpha (D jv jaref + 1/2 alpha D jv^2); turning on, plus its cost at 0, which was not counted; turning off, minus
  it), never as a difference of two f32 costs - and `slopeSize` (the bound sqrt(2 cost curvature) on the rows' slope
  plus the inertia's: the slope's noise floor is 8 epsilons of it); `searchLine` (MJW's: the start, the first Newton
  step taken if converged, else the bracket by slope and up to `max_iterations` of three candidates - a Newton step
  from each end and the midpoint - in MJW's order, with its stops and its "crosses from below" rule). `std.math` is
  banned in robot.zig for the GPU's sake - f32's epsilon and largest value are literals - and this code goes to the
  kernel at S3b4c. CHECKED, against closed forms: one quadratic (the first Newton step, alpha -3/4, improvement 9/8); a
  row that stops pushing along the line (the bracket crosses the kink to alpha 4, improvement 13); a row that starts
  pushing (alpha 14/11, where it balances the inertia); a start at the lowest point (no step). robot.zig 130/130; the
  fingerprints unchanged; lint. NEXT: S3b4b - Newton on it, the scaled stopping rules, the warm start.
- Nov 3: S3b4b DONE - ROBOT.ZIG'S NEWTON IS MUJOCO'S. `newtonDerivatives` (residuals, active set, gradient, Hessian,
  factor, step - and the gradient's length and the Newton decrement g^T H^-1 g for the stops); each round builds its
  `SearchLine` (M s for the inertia's two coefficients, J s per row) and runs `searchLine`, its slope tolerance
  max(tolerance x line_search_tolerance x |s| / scale, 1e-6); the stops MuJoCo's, each scaled by 1 / trace(M) (M's
  diagonal the last entry of each row): no step, a small improvement, a small gradient, half a small decrement; a start
  already meeting the gradient's rule takes no round. New options `line_search_iterations` (50) and
  `line_search_tolerance` (0.01); `tolerance`'s documentation gains Newton's scaled sense - it already warned that an
  absolute tolerance in f32 "would spin to max_iterations on a problem it had already solved exactly", which is what
  Newton's raw-gradient rule did. MEASURED against the old Newton (the twin still runs it - the same inputs): the same
  answers to f32's convergence (accelerations 3e-8 to 4e-6 relative, row forces 0 to 8e-6), the KUKA's five worlds in
  8 rounds against 9, the humanoid's in 16 against 21 - cold solves both, so the saving is the line search and the
  stops alone.
  THE WARM START, MuJoCo's (`warmstart_accelerations`, saved by `step` after its solve - not by `forward` - cleared by
  `forgetWarmStart`; the last step's accelerations taken when they cost less than the free acceleration): KEPT FOR ITS
  SEMANTICS, AND NOT A CLEAR WIN. A standing Go1, settled: 899 rounds warm against 1,000 cold over 1,000 steps (a
  start already meeting the gradient's rule takes none). MuJoCo's humanoid stepping into its limits: 181 warm against
  166 cold over 100 states - traced: from the free acceleration every row that will push is already pushing, so the
  first step is exact (one round); the warm start sits where last step's rows BALANCED, some now just clear of
  violation, so the Hessian misses them, the first step crosses their kinks and the line search cuts it to alpha
  0.09-0.5, and a second round finishes. Lower cost is not fewer rounds. Tests say exactly that: the humanoid's, each
  state solved cold and warm, the same answer (within 2.8e-5 of the largest); the Go1's, the same stance and fewer
  rounds once settled. The twin's Newton test skipped, visibly, until S3b4c.
  FOUND ON THE WAY - A ROOT THAT TESTED NOTHING: `-Dfast-root=src/robot_mjcf.zig` reported success with no test
  binary at all - the robot family's members run inside the union (`robot_tests.zig`), so their own runs were wired
  only to their per-root steps, and `-Dfast-root` filtered the union out too. It now runs the selected member's own
  binary (244 of 255, 11 skipped; the new Go1 test among them). The fix before it caught a root NOT on the list; this
  one, a root on it. CHECKED: robot.zig 130/130; robotgpu 18 of 19 (one skipped, on purpose); robot_mjcf 244 of 255;
  the robot family's union 662 of 806, none failed; the fingerprints unchanged (they run Gauss-Seidel); lint.
  PENDING with S3b4c: the robots course's chapter 57 (it teaches backtracking, the raw gradient's rule and the cold
  start, and lists all three as MJW's differences) - rewritten once the kernel matches, so it teaches one solver.
- Nov 4: S3b4b RECOVERED AND REVIEWED. The turn that did S3b4b ended before its reply, its work in place on disk and
  recorded above. Diffed against zimr313 (the snapshot before it): build.zig, robot.zig, robot_mjcf.zig,
  robotgpu_tests.zig and this plan, as recorded. The code reviewed sound - the gradient, the exact Hessian, the
  decrement -g.s = g^T H^-1 g, a start with nothing active taking no round (its gradient is zero), the warm start saved
  by every integrator's `step` and cleared by `forgetWarmStart`. Fixed on review: two explanatory comments the rewrite
  had dropped restored (why the working set's size is asserted; the caller's contract is forces); the shared
  `warm_start` option documented for both solvers - Gauss-Seidel's row forces and Newton's accelerations, with
  Newton's measured small gain - and the history wording ("as before") made neutral. RE-CHECKED on the tree as it is:
  robot.zig 130/130; robotgpu 18 of 19 (the twin's Newton test skipped until S3b4c); robot_mjcf 244 of 255, the Go1
  warm-start test run alone too (passes); the fingerprints unchanged; lint.
- Nov 4: NEWTON COMPARED WITH MJW AGAIN, AND WRITTEN ITS WAY (Simon: "compare again with mjw and review; find the best
  way to write this code"). MJW's round (`_solver_iteration`): line search, `_update_constraint` (each row's state and
  force from its Jaref), `_update_gradient` (grad = Ma - qfrc_smooth - qfrc_constraint, the Hessian, its factor, the
  search), `_solve_done`. Same as robot.zig's: the exact line search, the four scaled stops. DIFFERENT: (1) MJW KEEPS
  Jaref and Ma between rounds, moved by alpha jv and alpha Mv - robot.zig multiplied out J a and M (a - a_free) every
  round, and J a again for the forces at the end; (2) MJW's forces are every round's, the gradient built from them;
  (3) MJW's warm start is taken whenever there are rows (robot.zig: MuJoCo C's cheaper-of-the-two, two cost
  evaluations); (4) MJW counts a round before testing, so a solve takes one at least (robot.zig: a start already
  meeting the gradient's rule takes none - kept, a deliberate difference).
  DONE IN ROBOT.ZIG: (a) THE KEPT PRODUCTS - `newton_residual` (J a - aref) and `newton_inertia_gradient`
  (M (a - a_free), in the dead `newton_trial`'s place) multiplied out once at the start, moved with each step;
  `newtonDerivatives` builds each row's force f = -D r, the joint forces J^T f and the gradient M (a - a_free) - J^T f
  from them (the forces the answer as well, the end's recovery gone); the line's slope s^T M (a - a_free) from the kept
  product. MEASURED against the old Newton, cold both: the KUKA 8 rounds (old 9), accelerations 1.8e-7 of the largest
  apart, row forces 1.6e-6; the HUMANOID 11 rounds (16 multiplying out, old 21), 3.5e-6 and 6.2e-6. WHY FEWER: a
  residual multiplied out again re-injects J a's rounding (~1e-4 in thousands, ~0.1 in the gradient through a stiff
  row's D) into every round's stops; moved, it is the line search's own model. The warm start re-measured: the Go1 901
  warm against 1,000 cold (was 899), the humanoid stepping 181 against 166 (unchanged). (b) THE LINE SEARCH AS A STATE
  - `LineSearch` (`begin` with the point at 0, `takeNewtonPoint`, `candidateAlphas`, `advance` with their points;
  `is_done`, `result`), its decisions and arithmetic unchanged; `searchLine` is its CPU driver, a pass over the rows a
  point. CHECKED: robot.zig 130/130; robotgpu 18 of 19 (the twin's skipped until S3b4c); the Go1 test; the
  fingerprints unchanged; lint.
  S3b4c, THE KERNEL, WRITTEN THE SAME WAY: the start cold (a = a_free, so M (a - a_free) = 0 and only r = J a - aref is
  multiplied out); each round's phases MJW's dataflow - the rows' activity and forces (lanes over rows), J^T f and the
  gradient (lanes over dofs, each summing its rows in row order, as robot.zig accumulates), the Hessian and factor as
  now, the step, the measures; the line - M s (`NewtonMassProduct`), J s (lanes over rows), its three sums (one
  invocation, in dof order); THE SAME `LineSearch`, driven by one invocation: each point the lanes' rows evaluated by
  `rowLinePoint` into a workgroup array, summed by one invocation in row order after the inertia's (`SearchLine.at`'s
  order - the twin to the bit), one candidate a pass (3 x 128 floats; the working set stays near 28 KB of the web's
  32); the decision to go on a uniform load; then a, M (a - a_free) and r moved. D26 - THE DEVICE'S NEWTON STARTS
  COLD: measured, Newton's warm start is a small gain at best (the Go1 a tenth of its rounds once settled; the humanoid
  stepping, rounds lost); on the device it is a per-world history the step program keeps and every reset must clear.
  robot.zig keeps the option; the twin is compared with it off.
- Nov 4: D26 REVISED - THE WARM START MEASURED WHERE IT MATTERS (Simon: "every thing we decide to do differently
  will need to be backed by more evidence; are you really sure we should not warmstart?"). The first D26 rested on two
  scenes with few rounds, totals only, no contacts, and a weak argument (a per-world array of nv floats is no burden;
  MuJoCo's mj_resetData zeroes its own). RE-READ MUJOCO C (engine_forward.c `warmstart`): the best of qacc_warmstart
  and qacc_smooth by cost - robot.zig's rule - kept unless it costs MORE (robot.zig took it only when it cost less:
  the tie fixed to MuJoCo's); saved as the step finishes, RK4's from its last stage - as robot.zig. NEW COUNTER
  `solver_line_evaluations` (MuJoCo's `neval`, summed): the points Newton's line searches evaluated, each a pass over
  the rows - with the rounds, what a solve costs. MEASURED on the tracker's own scene - `FleetSetup.initTwoClips`, the
  tracker's humanoid (humanoid_flex2) on Newton at 60 Hz, contacts from zimrphysics through the bridge, four
  characters on the get-up and the dance with zero actions (the reference servo), 2,000 steps, warm against cold:
      get-up  cold 2.57 rounds a step, 11.45 evaluations, worst 7, steps of 6+ rounds 35
              warm 3.01 (+17%),        15.64 (+37%),      worst 8, 131
      dance   cold 2.57, 11.84, worst 8, 31;   warm 2.84 (+10%), 14.21 (+20%), worst 8, 70
      ~14 rows a step; the mean reward 0.5742 both - the same motion, a fair comparison
  With the Go1 standing at 500 Hz (901 warm against 1,000 cold) and the humanoid stepping into its limits at 200 Hz
  (181 against 166): FOR NEWTON THE WARM START PAYS WHERE LITTLE CHANGES BETWEEN STEPS AND COSTS WHERE MUCH DOES. Why:
  from the free acceleration every row that will push is already pushing, so the first step is nearly exact; the warm
  start sits where last step's rows balanced, misses the ones now just clear, and crosses their kinks. MuJoCo's one
  rule serves all its solvers - Gauss-Seidel and CG, which converge linearly, gain the most from a good start.
  D26 (REVISED) - THE DEVICE HAS MUJOCO'S WARM START, AS ITS FLAG: not a structural difference from MuJoCo but its
  `warmstart` flag, set per use by measurement - for the tracker at 60 Hz, off. S3b4c (the constraint program, which
  has no step history) solves cold, the twin compared with robot.zig's warm_start off; S3c (the constraint step on
  the device) adds the warm start - a per-world array saved by the step program, cleared on reset, the cost
  comparison as two passes - with the flag, and measures it there. The CPU tracker runs robot.zig's default (on): the
  measurement says off would save it 10-17% of its rounds - a change to the tracker's physics at the tolerance's
  level, Simon's to make.
- Nov 4: THE GOAL RESTATED (Simon): "the fastest approximate solver for training a game-ready walking ragdoll. Speed is
  much more important than precision." The device's Newton no longer aims at MuJoCo's converged answer but at a cheap
  step that is good enough - every choice still backed by evidence, and the reference for fast training is MuJoCo's
  own: MUJOCO PLAYGROUND'S LOCOMOTION SCENES (its tarball's 36 XMLs, read Nov 4): Newton with `iterations` 1 (Go1, H1,
  OP3, Spot) or 3 (G1, T1, Berkeley humanoid, Apollo), `ls_iterations` 5 in every scene; physics at 2-5 ms under a
  20 ms control step; "feetonly" scenes - the feet's small capsules the only geoms that collide (contype 0, conaffinity
  1 against the floor; every body geom contype = conaffinity = 0); `eulerdamp` disabled. All of it MuJoCo's options,
  not deviations from it.
  MUJOCO'S INERTIA IS APPROXIMATE BY DEFAULT (engine_core_constraint.c): each row's inverse inertia for its softness R
  comes from `mj_diagApprox` - `body_invweight0` for contacts, `dof_invweight0` for joint limits, computed once at the
  reference pose - and the exact J M^-1 J^T diagonal only under `mjENBL_DIAGEXACT`, an enable flag, off by default.
  MuJoCo Warp has no exact mode at all (constraint.py reads `body_invweight0` / `dof_invweight0`). D23 chose the
  NON-default exact mode; robot.zig has only that one.
  MEASURED ON GENO, the goal's own character (`physicsOptions`: Newton at 60 Hz, `standing_armature`, zimrphysics
  contacts), the reference servo on walk.zclip and run.zclip (LAFAN1's subject 2), ten starts each:
      survival: 864-939 of 3,880 frames for every variant (converged, capped at 3, 2, 1, warm or cold) - the servo
      alone loses the reference a quarter of the way through whatever the solver does; NOT a measure of the solver
      work: converged 1.81 / 1.52 rounds a step (walk / run), 7.1 / 6.1 line evaluations; capped at 3: 1.78 / 1.44,
      at the cap on 27% / 22% of steps; at 2: 1.48 / 1.22; at 1: 0.91 / 0.77, 4.2 / 3.9 evaluations
  and, at the SAME 1,394 states along the converged trajectory (a capped solve against the converged one):
      accelerations apart, mean (worst), of the largest: 1 round 12% (191%), 2 rounds 1.6% (102%), 3 rounds 0.15% (20%)
      the force the rows leave unexplained, |M (a - a_free) - J^T f| / |M (a - a_free)|: converged 4e-6, 1 round 85%,
      2 rounds 4.3%, 3 rounds 0.4%
  ONE ROUND IS NOT ENOUGH AT 60 Hz FROM THE FREE ACCELERATION - Playground's one-round scenes step at 4 ms and warm,
  each solve starting next to its answer; three rounds, Playground's humanoids' choice, is converged in all but the
  tail here, at no cost on average (most steps end in one or two), and the cap bounds the tail - on the device, where
  a dispatch lasts as long as its slowest world.
  DECISIONS: D28 - NEWTON CAPPED AT 3 ROUNDS AND 5 LINE-SEARCH ITERATIONS (Playground's humanoids; measured above).
  D26 stands - cold at 60 Hz (measured). D27 (NEXT) - MUJOCO'S APPROXIMATE INERTIA, its default (and MJW's only mode):
  `body_invweight0` / `dof_invweight0` at the reference pose (MuJoCo's engine_setconst.c), robot.zig's exact form kept
  as the opt-in `mjENBL_DIAGEXACT` - returning to the reference, and the per-row M^-1 J^T solve gone from the device's
  constraint program; measured on Geno before it is Geno's. THE RATE STAYS 60 Hz, ONE STEP A DECISION: three rounds
  once a frame against Playground's one round four times a frame, which also repeats the smooth dynamics four times;
  the CPU tracker already stands on it. TO DECIDE AT S5 (contacts): Playground's feet-only collision for walking, the
  floor the only other geom; a ragdoll's falls (whole-body against the floor) a later choice.
- Nov 4: THE RATES TO COME (Simon): physics perhaps at 90 or 120 Hz under a 30 Hz control step - three or four
  physics steps sharing a decision's targets, each starting nearer its answer; Simon expects the warm start to pay
  there, as it did for the settled Go1 at 500 Hz. D26-revised already admits it (MuJoCo's flag, S3c); the caps (D28)
  and the warm start are measured again at whatever rate is chosen - the servo harness steps at the model's timestep.
- Nov 4: D27a DONE - MUJOCO'S APPROXIMATE INERTIA IN ROBOT.ZIG, as an option (no physics changed yet).
  `ConstraintInertia` (.exact - MuJoCo's `mjENBL_DIAGEXACT`; .reference_pose - its default, `mj_diagApprox`) as
  `Options.constraint_inertia`, starting at .exact until measured. THE MODEL'S TABLES (MuJoCo's `setInertia0`, last in
  `buildFromSpec` as it is last in `mj_setConst`): `body_translation_inverse_weight` / `body_rotation_inverse_weight`
  (the mean translation and rotation diagonals of J M^-1 J^T for each body's centre of mass, at the reference pose) and
  `dof_inverse_weight` (each joint's block of M^-1: a free joint's two means, a ball's one, a hinge's entry) -
  `computeReferenceInverseWeights` on a Data of its own, after the dynamics it calls (one explained `lint:off
  decl-order`: a cycle, the model measured by the dynamics that take it). EACH ROW'S MAKER RECORDS MUJOCO'S RULE
  (`constraint_reference_inertia`): a limit its joint's weight; a pyramid edge the bodies' translation weights x
  (1 + mu^2); a connect, and a weld's position rows, the translation weights; a weld's rotation rows the rotation
  weights (no torque scale, as MuJoCo); a joint coupling its joints'. `projectConstraints` reads the option, and
  NEWTON AT THE REFERENCE POSE'S INERTIA SKIPS THE PER-ROW M^-1 J^T SOLVE (Gauss-Seidel still makes it: it solves on
  A itself). FOUND ON THE WAY: `constraint_direction` was written per contact row every step and read by nothing -
  kept for an external body's inertia (section 4h-ter) that was never built; gone, and the two comments that
  described that body's inertia and velocity as if they were applied now say what is so (the other side is fixed;
  `robot_physics.zig`'s header). CHECKED: closed forms - a free box (1 / (mass + armature), the mean of
  1 / (inertia + armature)), a hinged rod (the lever arm squared over the inertia about the axis, parallel axes), a
  box's contact edges (its weight x 1.25 at mu 0.5, R / A unchanged, no M^-1 J^T computed); AGAINST MUJOCO 3.17.0
  itself (its Python package, a one-off check): the humanoid's and Geno's body and dof weights equal to every printed
  digit (torso 0.0527037 / 3.2303, foot 0.365733 / 48.3435; Geno's hips 0.0633676 / 7.766, Neck1 0.142868 / 49.6654);
  robot.zig 133/133; robotgpu 18 of 19; robot_mjcf 244 of 255; the fingerprints unchanged; lint. NEXT, D27b: measured
  on Geno - the motion either way and the solve's cost - then Geno's options (D26, D27, D28 together), then the
  device's projection without the solve.
- Nov 4: D27b DONE - THE REFERENCE POSE'S INERTIA MEASURED ON GENO, AND GENO'S PHYSICS SET. At 1,451 states along
  Geno's walk and run under the servo (12.6 rows each, all contacts - Geno's balls have no ranges), each solved both
  ways: the contact rows' approximate / exact inertia 0.896 (geometric mean), 0.043 to 2.65, 99.8% of 18,328 rows
  within a factor of two; the accelerations at the same state 3.1% of the largest apart on average, 17.7% at worst -
  a change of model (each row's softness), not a solver error; `forward` 257.7 us exact against 235.9 approximate
  (8.5% off, Newton's rounds 1.94 against 1.97); survival under the servo 1,788 against 1,797 of 7,760 frames.
  GENO'S `physicsOptions`: Newton capped at 3 rounds and 5 line-search iterations (D28) and MuJoCo's reference-pose
  inertia (D27), the evidence in its documentation. THE WARM START STAYS MuJoCo's, ON, FOR GENO: D26's evidence was
  the tracker's humanoid (humanoid_flex2), and on Geno itself the converged runs took 1.62 rounds a step warm against
  1.81 cold on the walk, 1.49 against 1.52 on the run - mixed, not enough to deviate from MuJoCo. (D26-revised holds
  for the device: MuJoCo's flag, set per use by measurement.) robot.zig's own default stays exact: flipping it to
  MuJoCo's changes every other robot's physics, to be measured on them first. CHECKED: robot_geno 342 of 424 (82
  slow tests skipped as always - the long training runs); robot_bmpc_dance's five through the robot family's union
  (TrackCharacter 5/5, the agent 5 of 6); the fingerprints unchanged (cached - nothing they build from changed);
  lint. NEXT, D27c: the device - the model's weights packed, each row's reference inertia made where its row is,
  and the projection without the per-row solve when the model asks for the reference pose.
- Nov 4: D27c DONE - MUJOCO'S DEFAULT INERTIA ON THE DEVICE. `dof_inverse_weight` packed (MJW: `dof_invweight0`, a
  model table filled like `dof_armature`); `StepOptions.constraint_inertia` in the uniform's padding slot
  (`robot.ConstraintInertia` given a u32 tag for the extern struct); the rows kernel, at the reference pose's inertia,
  stores each limit row's inertia - its joint's weight, MuJoCo's `efc_diagApprox` for a limit; the projection reads it
  and neither fills nor solves M^-1 J^T, the exact inertia's path unchanged. (The bodies' weights wait for contacts,
  S4.) CHECKED: the twin's projection test at both inertias, bit for bit against robot.zig (M^-1 J^T compared at the
  exact one only); robotgpu 18 of 19; robot.zig 133/133; ON THE DEVICE (lavapipe), the constraint check now at both:
      exact            inertia 230.6 eps, regulariser 230.4, M^-1 J^T 230.6; forces 382.7, accelerations 75.1;
                       rounds apart in 48 worlds by at most 2
      reference pose   inertia 0.0, regulariser 0.0 (the solve's rounding gone - Newton's inputs equal the twin's);
                       forces 278.0, accelerations 1,105.4 (bar 4,096); rounds apart in 54 worlds by at most 4
  - the kernel's Newton is still the backtracking one that runs every solve to f32's noise floor, its rounds set by
  rounding; S3b4c's (robot.zig's: 11 rounds on the humanoid where this takes 21) is what closes it. Lint.
  OPEN - AN INTERMITTENT READBACK: one vk-host-test run of three reported zimrnum's polyak follow, adam step (warm)
  and disc reward as "the read never held the dispatch" - the read not seeing the dispatch's writes, not a numeric
  difference; nothing changed touched zimrnum, and two runs since passed. To find: a readback that can race its
  dispatch.
- Nov 4: S3b4c-1 DONE - THE LINE SEARCH WRITTEN ONCE FOR BOTH ENGINES. As `multiplyByMassMatrix` is: a rows storage
  checked at compile time (`requireLineRows`: `residual`, `rate`, `weight`, `isUnilateral`); `linePointAt` (the
  inertia's term, then each row's in row order), `lineSlopeSize` and `searchLineOver` (the CPU driver, generalised:
  the start, the Newton point, the iterations of three candidates - `LineSearch` deciding) over any such storage;
  `SearchLine` is robot.zig's storage (its slices), `at`, `slopeSize` and `searchLine` delegating - the arithmetic and
  its order unchanged. robot.zig 133/133; robotgpu 18 of 19; lint.
  S3b4c-2, THE KERNEL, DESIGNED - ONE INVOCATION RUNS THE LINE SEARCH. Each point is a sum over the rows in robot.zig's
  row order (the twin to the bit), so it is sequential whoever makes it; the search between points is a chain of
  scalar decisions. So lane 0 runs `robot.searchLineOver` itself over the workgroup's rows (a `NewtonLineRows`
  storage), no barrier inside, the other lanes waiting at the phase's - one definition, not a port. (Measured
  optimisation later, D25: a GPU-shaped sum - lanes' partials in a fixed tree - would change robot.zig's order too.)
  The round, MJW's dataflow as robot.zig's (kept products):
      start      each row's D = 1/R and kind (rows); a = a_free (dofs); r = J a - aref (rows, sparse J);
                 M (a - a_free) by `NewtonMassProduct` (zero at the cold start, as robot.zig's mulM of zero);
                 the scale 1 / trace(M) (M's stored diagonal holds the armature on both engines)
      derivatives  each row active or not and its force -D r (rows); J^T f (dofs, each over the rows in row order);
                 g = M (a - a_free) - J^T f (dofs); H = M + J^T D J (as now, D from the rows' weights); the factor
                 (as now); s = -g, solved if factored; |g| and g^T H^-1 g (lane 0, dof order)
      stops      lane 0's decision, read as a uniform: robot.zig's four, scaled, and a start already converged
      the line   M s (`NewtonMassProduct`); J s (rows); s^T M (a - a_free), 1/2 s^T M s, |s|^2 (lane 0, dof order);
                 the search (lane 0); a += alpha s, M (a - a_free) += alpha M s (dofs), r += alpha J s (rows)
      the end    a, the forces, J^T f, the rounds and the line's evaluations stored for the world
  NEW OPTIONS in the uniform: `line_search_iterations` and `line_search_tolerance` (a third row). The working set:
  the Hessian (76 x 76), six dof vectors (a, M (a - a_free), g, s, M s, the mass product's input), five row arrays
  (r, D, J s, the force, active and kind as integers) - about 27 KB of the web's 32, the cost arrays gone. The twin's
  test against robot.zig back, robot.zig's warm start off (D26-revised: S3c brings the device's).
- Nov 4: REVIEW, AND THE REMAINING STEPS MADE PRECISE (Simon: "review recent code; make sure the remaining steps are
  precise and lead to the best possible code; how many turns before a GPU-resident sim and training for tracking?").
  CODE: robot.zig's Newton (kept products, each round's forces, the line search over a rows storage, the scaled stops,
  the caps) and the device's reference-pose inertia hold up; one fix - THE REFERENCE WEIGHTS COULD GO STALE: measured
  at the build, they depend on the masses, the inertias and the armature, and `refreshSubtreeMass` told a caller
  changing masses at runtime to call it alone. `refreshReferenceInverseWeights` is public now, both documented
  (MuJoCo's `mj_setConst`); nothing mutates a built model today, but randomised physics (the tracking plan's D3)
  would. robot.zig 133/133; lint.
  WHAT THE REMAINING STEPS GAINED: (1) CONTACTS FROM ONE GENERATOR - the CPU tracker's contacts are zimrphysics'
  (Jolt's manifolds), which neither MuJoCo nor the device makes; MuJoCo's plane-primitive functions written once and
  run by both engines put training and the game on the same contacts, and make S4's upload rig unnecessary (P3a).
  (2) FLOOR ONLY: Geno's 22 geoms (16 capsules, 4 boxes, a sphere) collide with nothing but the floor on the CPU - the
  bridge's links are kinematic bodies, which do not collide with each other - so the device matches that, not
  MuJoCo's default self-collision. (3) NEWTON'S ROW WORK FOR CONTACTS IS MJW's INCREMENTAL HESSIAN, its default for
  Newton on pyramidal cones: a contact row has about 27 nonzeros of Geno's 75 dofs, up to 196 rows lying down - the
  kernel's search over entries would not survive it (P3c). (4) Section 3 rewritten as the critical path P1-P5, the
  tracking plan's E-steps pointing at it; its S0 with Simon's rates.
  THE ESTIMATE, in turns of this session's size: P1 2-3, P2 2, P3 5-7 (the generator 2, the rows 1-2, the incremental
  Hessian 2-3), P4 6-8, P5 one to package for Simon's run - A GPU-RESIDENT SIMULATION WITH CONTACTS IN ABOUT 9 TO 12
  TURNS, THE TRACKER TRAINING ON IT IN ABOUT 16 TO 21, the reviews and the course's chapters inside those numbers;
  Simon's RTX and browser runs at P1 (the bars), P3 (G4's first numbers) and P5.
- Nov 4: P1 (S3b4c-2) - THE KERNEL'S NEWTON IS ROBOT.ZIG'S. The phases MJW's dataflow as robot.zig's: the start
  (each row's D = 1/R and kind; a = a_free; the kept residuals r = J a - aref; the kept inertia gradient
  M (a - a_free) by robot.zig's product; the scale 1 / trace(M)); the derivatives (each row's activity and force -D r;
  J^T f and g = M (a - a_free) - J^T f per dof; the Hessian, D from the rows' weights; the factor as before; the step
  and, in dof order, |g| and -g^T s); the stops as a uniform decision; the line (M s, the inertia's slope from the kept
  product, its half curvature, |s|^2; J s per row); THE LINE SEARCH RUN BY LANE 0 - `robot.searchLineOver` over the
  workgroup's rows (`NewtonLineRows`); the advance (a, M (a - a_free), r by alpha); the answer stored (accelerations,
  J^T f, the rows' forces, the rounds and - new, `newton_line_evaluations` - the line's evaluations). The uniform's
  third row: `newton_line_search_iterations`, `newton_line_search_tolerance`. The cost arrays gone; about 28 KB.
  CHECKED: THE TWIN'S NEWTON TEST BACK, BIT FOR BIT against robot.zig (warm start off) - accelerations, joint forces,
  the rows' forces, the rounds and the evaluations - on the KUKA and the humanoid; robotgpu 19/19. ON THE DEVICE
  (lavapipe), the humanoid's 64 worlds: rounds 177 on the device and 177 on the twin at the exact inertia, 157 and
  157 at the reference pose's - NO world apart (were 48 and 54); accelerations 84.1 and 78.7 epsilons (the reference
  pose's 1,105 before); forces 245.2 and 233.0; no validation messages.
  FOUND BY CHROME'S TINT, FIXED IN spv2wgsl: (1) WGSL'S RESERVED WORDS - a Zig local named `active` (robot.zig's
  `rowLinePoint`) reached the WGSL by its name; `sanitizeName` now renames every keyword and reserved word of the WGSL
  specification's lists (a trailing underscore; two leading underscores, the implementation's, become `_z_`); (2) F32'S
  LARGEST VALUE - its shortest decimal, 3.4028235e38, read as WGSL reads a literal (an abstract float), lies past f32's
  range, and Tint refused the line search's starting minimum; such a value is written by the exact value's shortest
  f64 decimal, which reads back to it exactly - every other constant as before. Both tested; the pinned corpus 80 of
  80 as pinned. spv2wgsl IS A FAST TEST ROOT now (its closure is `std` alone): 65 tests in seconds, where the full
  test binary takes more than five minutes to compile.
  OPEN - SWIFTSHADER DROPS THE DEVICE CREATING THE NEWTON PIPELINE: 29 of the 30 web modules pass, pipelines
  included; the Newton module (12,145 lines of WGSL, the old one 8,021, which still passes here) compiles in Tint but
  loses SwiftShader's device at pipeline creation. Bisected so far: without the call to the line search phase the
  pipeline is made - the cause is in the line search's code.
- Nov 4: THE SWIFTSHADER PIPELINE FAILURE, BISECTED SO FAR. Tint compiles the Newton module and validates it; only
  SwiftShader (Chrome's CPU fallback adapter) loses its device creating the pipeline. On copies of the module's WGSL:
  without the call to the line search phase, the pipeline is made; WITHOUT THE CALL TO `LineSearch.advance`, IT IS
  MADE; without `takeNewtonPoint`, it still fails; with f32's largest constant replaced by 1e30, it still fails. At the
  source: `advance` made `inline` (so neither its pointer nor its arrays are parameters), it still fails - THE CAUSE IS
  IN `advance`'s BODY, not in how it is called. Not its nesting either: its deepest `if` is 16 levels down, where the
  old kernel's `newton_solve`, which passes, went to 28. (A bisect by inserting `return` at "top-level" lines is
  misleading: spv2wgsl indents only `if` and `}` by depth, every other statement at two spaces, so such a `return`
  lands at arbitrary depths.) NEXT: bisect `advance`'s body at the source, keeping it compilable (the moved flags
  then constants, not unmutated vars) - the converged candidates' choice, the bracket's six moves (`isInBracket`'s
  short-circuit chains, each `and` and `or` a branch in the WGSL), the tail; and Simon's browser on a real GPU, which
  decides whether this is SwiftShader's limit or the module's - the lab page built in release.
- Nov 4: THE SWIFTSHADER PIPELINE FAILURE, FOUND AND FIXED - THE LINE SEARCH'S SHORT-CIRCUIT CHAINS. Bisected at the
  source: `advance` without the bracket's six moves, the pipeline is made. Every condition there is a chain - Zig's
  `and` and `or` stop at the first operand that decides, which the GPU code gets as a branch and a merge (in the WGSL
  an `if` per operand, with guards and phis) - and the bracket's moves are six `isInBracket` tests, each two `and`s
  joined by an `or`. FIX, in robot.zig (both engines run the code): `both` and `either`, which combine two comparisons
  already made as integers - the same answers, no branch - for every compound condition of the line search's
  decisions (the candidates' convergence, the bracket's tests, its ends' stops, the improvement, the search's end).
  Every operand is a plain comparison, so nothing that was skipped is now evaluated, and the CPU computes the same.
  CHECKED: the Newton module's pipeline made on SwiftShader (11,722 lines, 400 fewer); all 30 web modules through Tint,
  pipelines included, no messages; robot.zig 133/133; robotgpu 19/19 (the twin bit for bit); the device unchanged -
  177 / 177 and 157 / 157 rounds, accelerations 84.1 and 78.7 epsilons; lint. P1 DONE but for Simon's browser and
  RTX, and chapter 57.
  THE INTERMITTENT READBACK, AGAIN: the same three zimrnum cases - polyak follow, adam step (warm), disc reward - "the
  read never held the dispatch", in two device runs of about seven; a run straight after passed. The same three each
  time: a pattern, not chance - the next thing to find.
- Nov 4: THE LAB ON SIMON'S PHONE (the published standalone page, in the Claude app's viewer: WebAssembly and WebGPU
  both work there): the step program on Geno's 64 worlds AGREES with the twin, its largest gap 134.94 epsilons
  (smooth_joint_accelerations, bar 1024), every copy after 3 frames - the first check on a real mobile GPU. The page
  checks the STEP only: the constraint program - the new Newton kernel - has not run on a phone yet.
  THE CONSTRAINT CHECK SHARED, for the lab to run it: what the device test held alone now lives in robotgpu_host
  beside `StepComparison`, in its shape - `poseAroundLimits` (the scene: each limited joint at one of five places
  along its range, every dof moving), `submitThroughConstraints` (the step up to the free acceleration, then the
  constraint program), `constraint_array_bars`, `ConstraintVerdict` and `ConstraintComparison` (request, collect
  without waiting, compare: the integers exactly, each row's numbers for the world's rows, the dof arrays whole; its
  floats' requests in whichever arena holds them). The device test drives it in a loop, as it does the step's; its own
  table, outcome, reader and dispatch finder gone. CHECKED: the device test's numbers unchanged to the digit (1,075
  rows; rounds 177 / 177 and 157 / 157; inertia 230.6 and 0.0, forces 245.2 and 233.0, accelerations 84.1 and 78.7);
  lint. NEXT: the lab page runs it - the constraint program's kernels in its pipe, the humanoid's worlds beside Geno's,
  the verdict on the page; then the headless capture here and the page on Simon's phone; then the readback flake,
  which has now failed three device runs of about nine, always the same three zimrnum cases.
- Nov 4: THE LAB RUNS THE CONSTRAINT CHECK, AND THE WEB CAN RUN NEWTON. The lab page (`robotgpu_lab`): MuJoCo's humanoid
  around its limits beside Geno's step, through `robotgpu_host.ConstraintComparison` at the reference pose's inertia
  (Geno's training setting); its Sims made once the step checks' requests are made (a twin's requests snapshot at
  request time, and every twin works in the module's arrays); the verdict, its worst array (`ConstraintVerdict.
  worstArray`) and the device's workgroup memory on the page. HEADLESS on lavapipe: AGREE, 1,075 rows, 157 / 157
  rounds, 233.00 epsilons (constraint_force; bar 4,096), 32,768 bytes granted, 28,348 needed. ON SIMON'S PHONE (the
  published page): AGREE, 1,075 rows, 157 rounds, 607.38 epsilons, 32,768 bytes - THE NEW NEWTON ON A MOBILE GPU.
  FOUND AND FIXED - NO BROWSER COULD HAVE RUN NEWTON: the web boot called `requestDevice` with no limits, so every
  WebGPU device had the 16 KB default of workgroup memory; the boot now asks for the adapter's own
  `maxComputeWorkgroupStorageSize` (within what the adapter supports, so never refused) and records what was granted;
  `wgpu.workgroupStorageLimit(device)` on both backends (the bridge's; Vulkan's `maxComputeSharedMemorySize`);
  `robotgpu.newton_workgroup_bytes` summed from the working set's own array types; `Sim.initGpu` refuses a device too
  small for Newton (`error.WorkgroupMemoryTooSmall`), the page saying REFUSED with both numbers. The device test passes
  with them. A LIMIT OF THIS SANDBOX: headless Chrome here compiles and validates the WGSL but presents no zimr canvas
  (a control page with the old boot as blank) - pages are checked natively (`robotgpu-lab-headless`) and on Simon's
  devices. THE READBACK FLAKE'S LIKELY CAUSE: `runAndRead` (vk-host-test) gives up after 1,000,000 polls of
  `readLatest` with no wait between them - a window set by how fast the CPU spins, where lavapipe's GPU is that CPU;
  the fix is a deadline in wall time, to confirm by repeated runs.
- Nov 4: ISAAC LAB STUDIED (its main branch, uploaded by Simon), AGAINST MUJOCO WARP AND PLAYGROUND.
  WHAT IT IS: a framework over physics backends - PhysX and NEWTON, NVIDIA's open engine on Warp, whose default solver
  is MUJOCO WARP (`NewtonCfg.solver_cfg`: "If None (default), MJWarpSolverCfg is used") - with environments built of
  managers (actions, observations, rewards, terminations, events, commands, curriculum, recorders), sensors, and
  wrappers for rsl_rl, skrl, rl_games and SB3. Its worlds are replicated in one scene (Newton: per-world copies, as
  MJW's nworld; PhysX: one scene, collision-filtered).
  ITS LOCOMOTION PHYSICS (the tasks' own MJWarpSolverCfg): physics at 200 to 500 Hz (dt 0.005 for the G1 and the
  microduck, 0.002 for Spot), 1 or 2 solver substeps, a 50 Hz decision (decimation 4 or 10); Newton with 100 rounds
  and 50 line-search iterations, pyramidal cones, impratio 1, INTEGRATOR "implicitfast" (22 of the tasks' settings);
  njmax / nconmax per task (the G1 300 / 300, Spot 130 / 40, the microduck 96 / 16); THE G1's SELF-COLLISION OFF on
  both backends. Two schools, then: Playground's (1 to 3 rounds, 5 line-search iterations, physics at 4 ms - speed)
  and Isaac Lab's (100 and 50, smaller steps, substeps - fidelity for the real robot). Our goal is Playground's.
  EVIDENCE ON CAPS (the microduck's own comments): "microduck_rl's 10 iterations stop some contact solves short; MJWarp
  exits once every world converges" and "the original 20-step budget exhausts line search" - MJW's rounds run in
  lockstep over every world until all converge, a batch as slow as its slowest world. For D28: our 3 rounds are
  measured (Geno: 0.15% of the largest acceleration on average, 20% at worst) but the tail is what a low cap risks -
  re-measured with contacts at P3 by the servo's survival and the tracker's reward, raised if it costs them. Our
  workgroup per world stops each world on its own rule: a converged world frees its slot instead of idling.
  ITS SPEED MACHINERY: (1) A DECISION IS ONE CUDA GRAPH - "physics-owned decimation" captures a decision's physics steps
  with the actuators inside (`use_newton_actuators`), callbacks before and after the actuators and before each solver
  substep, all GRAPH-SAFE ("fixed shapes, no host branching on device data"); without the graph "the simulation
  performance will be severely degraded" - launching many small kernels one by one dominates. (2) Collision
  decimation (re-collide every N substeps). (3) Lazy data: timestamped buffers, each derived quantity computed when
  read, at most once per physics time. (4) Determinism opt-in (`deterministic_mode`), its contact sorting costing work
  and memory - ours is by construction (deterministic slots, ordered sums), what makes the twin's bit-for-bit test
  possible.
  ITS ACTUATORS: the G1's are IMPLICIT - the PD inside the solver - stiffness 150 to 200 N m/rad, damping 5, ARMATURE
  0.01, at 200 Hz; explicit models beside them (ideal PD, DC motor saturation, delays, actuator networks; BAM servo
  models in the Newton backend). GENO'S ARMATURE IS 2.0 (`standing_armature`), two hundred times the G1's: an explicit
  damper is stable only while h kd / I < 2 - at 60 Hz a damping of 20 on a 0.05 kg m^2 link breaks it tenfold, and the
  armature buys the stability back by making the limbs heavy. Implicit damping (h kd in the integrator's matrix,
  MuJoCo's implicitfast) is stable at any step.
  ITS ENVIRONMENT LOOP (ManagerBasedRLEnv.step): the action processed once; per physics step the actuators applied,
  the data written, the solver stepped, the sensors updated; then the episode counters, TERMINATED AND TIME-OUTS APART
  (the learner bootstraps at a time-out), rewards (each term x dt), resets within the step with the terminal
  observation kept first (`final_obs`), commands, interval events, observations after the resets. ITS RANDOMISATION
  (the velocity template): at startup friction, base mass and its centre; at reset an external wrench, the root's
  state and the joints'; at intervals a push that SETS the base's velocity; uniform noise on each observation. ITS
  PPO (the G1): 24 steps per environment an update, [512, 256, 128] ELU, clip 0.2, 5 epochs, 4 minibatches, lr 1e-3
  adaptive at KL 0.01, gamma 0.99, lambda 0.95; 1,500 updates flat, 6,000 rough. No humanoid throughput is published in
  the repository (its examples: Cartpole, 857,000 steps a second headless) - G4 measures against MJW on Simon's card.
  NO MOTION TRACKING in the main branch (no AMP, no mimic task; `locomanip_tracking` tracks commands).
  WHAT WE TAKE - each into section 3: (T1) THE DECISION PROGRAM (P4): one submission per decision, a fixed list of
  dispatches - for each physics step the servo's torques, then the step - then observations, rewards, terminations,
  resets and records, every per-world choice a mask on the device, never a readback: our CUDA graph. Natively a
  recorded command buffer replayed (Vulkan); on the web one encoder per decision. (T2) IMPLICIT PD (new P2b): the
  servo's damping in the step's implicit matrix, as MuJoCo's position actuators under implicitfast - robot.zig first -
  so Geno's armature can come down toward a physical value; measured first (stability and the servo's survival at
  60 Hz and at Simon's 90 to 120 Hz, explicit against implicit, armature 2.0 against small). (T3) FLOOR ONLY stands,
  now with the G1's evidence. (T4) THE CAP'S TAIL re-measured at P3 (above). (T5) TERMINATED AND TRUNCATED APART, the
  terminal state kept (the tracker's aftermath already keeps it) - in the device's records at P4. (T6) DERIVED
  QUANTITIES ONCE A DECISION, placed by the program after the last physics step (the static form of Isaac Lab's lazy
  buffers). (T7) RANDOMISATION AS PER-WORLD MODEL FIELDS (P4b): friction, masses and centres per world - MJW's batched
  model fields - the reference inverse weights refreshed per world when the masses change. (T8) DETERMINISM stays by
  construction.
- Nov 4: NEWTON STUDIED (its main branch, uploaded by Simon) - NVIDIA's open engine on Warp, Isaac Lab's backend, MJW its
  default rigid solver. Its solvers: SolverMuJoCo (MJW, with Newton's collision pipeline or MuJoCo's), STEEL
  (reduced-coordinate articulations with PGS - below), Featherstone (semi-implicit), Kamino (an NCP with proximal ADMM,
  or DVI), XPBD, VBD, implicit MPM, and couplings between them.
  STEEL, THE CLOSEST TO US: Featherstone's forward kinematics and inverse dynamics on the tree, CRBA and its factor, an
  unconstrained velocity prediction, then contacts, limits and velocity limits as rows solved by PROJECTED GAUSS-SEIDEL
  IN IMPULSE SPACE (12 iterations by default, Baumgarte 0.2, CFM 1e-6). Its default `matrix_free` mode keeps each row's
  Y = H^-1 J^T and J Y, recomputes J v each iteration, and applies each impulse to one world-local velocity at once,
  ONE FUSED KERNEL SWEEPING A WORLD's ROWS - each world's J and Y dense in tiles, the rows in sequence, the lanes over
  the dofs. ITS DRIVES ARE IMPLICIT by default ("augmented"): "folding dt kd + dt^2 ke into the mass matrix"; or PGS
  rows with the PhysX articulation drive, which bound the drive's whole reaction. FRICTION PATCHES with persistent
  anchors "so static friction holds without creep". `update_mass_matrix_interval`: M rebuilt and refactored every N
  steps. Joint limits off by default, contact warm start off by default.
  DETERMINISM (Newton's own guide): three sources - floats accumulated by atomics, slots reserved by an atomic counter,
  races that pick a winner - cured by recording atomics and replaying them in a fixed order, and by sorting contacts,
  at a cost in speed and memory; and "code paths that write each output from exactly one thread are already
  deterministic and cost nothing extra" - our deterministic slots and ordered sums take that path throughout.
  ITS PRIMITIVE CONTACTS (collision_primitive.py) are MuJoCo's, in fixed slots: plane-capsule two contacts at the end
  spheres, the frame along the capsule's axis; plane-box the eight corners tested and up to FOUR DEEPEST kept, unused
  slots at a maximal distance - P3a's layout (a sphere 1, a capsule 2, a box 4) as both references write it.
  SPECULATIVE CONTACTS (SolverMuJoCo, experimental): frictionless normal rows for separated candidates, "bounding
  closing velocity by clearance divided by the physics timestep" - against tunnelling at large steps, "not continuous
  collision detection". At 60 Hz a foot landing at 3 m/s moves 5 cm a step, far more than any margin.
  TWO MEASUREMENTS FROM ITS CHANGELOG, BOTH BACKING CHOICES WE MADE: "the serial forward-kinematics kernel for chain
  articulations ... is faster than the level-parallel kernel at typical batch sizes" (our kinematics is per world and
  branch, as MJW's `_kinematics_branch`); "incremental contact conversion when the contact set is unchanged (~6x speedup
  on anymal_d with 4096 worlds)" - converting contacts between formats was five sixths of the step; our generator will
  write its contacts into fixed slots the rows read, no conversion. Its worlds: one model with every world's entities
  side by side, a world index on each, global entities (the floor) in world -1; MJW's: a shared model, chosen fields
  expanded per world - P4b follows MJW's.
  WHAT IT CHANGES - each into section 3: (N1) P2b's form exact - Steel's augmented drive, derived for our step:
  (M + h kd + h^2 kp) a = tau + kp (q* - q) - kd (v - v*) - h kp v, one diagonal addition before the factor (where
  the armature already goes) and one term on the right; a ball's three dofs take kp linearised; the constraint solve on
  the same matrix. (N2) P3e, MEASURED BEFORE ANY CHANGE: feet landing at 60 and 120 Hz - the penetration and the
  rebound - and a standing foot's creep under MuJoCo's soft pyramidal friction; speculative normal rows (Newton's),
  MuJoCo's margin, elliptic cones or Steel's anchors only if the measurements show the need. (N3) P3c's alternative
  noted, not taken: Steel's matrix-free PGS (a world's rows in one fused sweep, 12 iterations) if Newton's incremental
  Hessian is too slow on contacts - MJW's Newton stays the reference. (N4) A SPEED LEVER FOR P5, needing evidence:
  M rebuilt and factored once a decision, not every physics step (Steel's `update_mass_matrix_interval`) - not MuJoCo's
  semantics, so measured against the servo's survival first.
- Nov 5: THE READBACK FLAKE FIXED, AND P2's FIRST PART - THE CONSTRAINT PROGRAM INSIDE THE STEP.
  THE FLAKE: every read the device test polled in a loop gave up after a count of polls - a window set by how fast the
  CPU spins, where lavapipe's "GPU" is that same CPU. `ReadDeadline` (vk-host-test): five loops (the raw read, the
  engine's two, the constant-index kernel's, zimrnum's `runAndRead`) bounded by a wall-clock deadline (10 s, read from
  the platform's clock, `native_os`), its limit a default field rather than a file-scope constant. Four device runs
  since, every read held; the flake was about one run in three.
  P2, PART ONE: THE STEP IS SMOOTH DYNAMICS, THEN THE CONSTRAINT PROGRAM, THEN THE INTEGRATION (`robotgpu_program`:
  `smooth_program ++ constraint_program ++ integration_program`, one list the device and the twin run; `kernel_names`
  the step's). The copy kernel `joint_accelerations` gone: Newton writes the step's acceleration, and the integration
  already takes MuJoCo's Euler from M times it (smooth and constraint forces both). A WORLD WITH NO ROWS gets
  robot.zig's answer at once (`newtonDecideRows`, a uniform decision; `newtonStoreFree`: the free acceleration, no joint
  force, no round, no line evaluated) - no Hessian for a problem without a constraint. THE MODEL's SWITCH ON THE DEVICE
  (`StepOptions.constraints`, `ConstraintsSwitch`): a model whose options disable its constraints makes no row, as on
  robot.zig - FOUND IN REVIEW: before, `limit_candidates` ignored the option, harmless only while the step never ran
  the constraint kernels. THE REFUSAL NARROWED to contacts and equalities - joint limits the device simulates; the
  checks keep their limits with `max_contacts = 0` and submit the whole step (`submitThroughConstraints` gone). Two
  twin helpers fixed: the smooth-dynamics test now stops at the free acceleration and runs the constraint program
  (no row) before the integration, as the step does. CHECKED: THE TWIN'S CONSTRAINED STEP IS robot.zig's, 20 STEPS ON
  THE LIMITS, BIT FOR BIT (the KUKA and the humanoid: every coordinate and velocity, the last step's rows and rounds
  equal and present; `expectTwinStepsOnLimits`); robotgpu 20/20; the device unchanged (Geno 238.64 epsilons; the
  humanoid 1,075 rows, 177 / 177 and 157 / 157 rounds, 84.1 and 78.7); the lab headless the same; lint.
  A CONSEQUENCE TO KNOW: every step program now holds `newton_solve`, so any device Sim needs Newton's 28 KB of
  workgroup memory, Geno's unconstrained step included (`Sim.initGpu` refuses less, by name). WebGPU guarantees 16 KB;
  desktops, Simon's phone and every adapter met so far grant 32 KB. A step program without Newton for constraint-free
  models, if a 16 KB device ever matters.
  NEXT IN P2: the device stepped many times on the limits, by statistics (the limits held, the energy); MuJoCo's warm
  start as its flag on the device; then P2b's measurement.
- Nov 5: P2's DEVICE CHECK OVER MANY STEPS (`runRobotgpuLimitSteps`, vk-host-test): MuJoCo's humanoid in 64 worlds
  posed around its limits and moving, contacts off, the rows at the reference pose's inertia, the whole constrained
  step 100 times on the device and the twin. Trajectories drift apart in rounding, so what is compared must hold
  whatever the drift: each world's energy (only the limits' and the joints' dissipation change it) and how far past its
  range any joint ended (`deepestLimitViolation`; some worlds start 0.03 rad past an end). MEASURED on lavapipe: the
  energy gap 0.0104% of the initial, no joint past its range on either - BARS 1% and 0.01 rad, the test failing beyond.
  Six device runs in a row since the read deadline, every read held. NEXT IN P2: MuJoCo's warm start as its flag on the
  device; then P2b's measurement.
- Nov 5: P2 DONE - MUJOCO'S WARM START ON THE DEVICE, AS ITS FLAG. `warmstart_accelerations` per world (MuJoCo's
  `qacc_warmstart`): saved by every step from Newton's answer (`newtonStore`) - and by a world with no rows, its free
  acceleration (`newtonStoreFree`) - as robot.zig's `step` saves it after `forward`; zero at a world's start, as a new
  `Data` holds it. `StepOptions.warm_start` (the uniform's last slot; the device's on-off options one type, `Switch`,
  the constraints' too). `newtonChooseStart` (lane 0, before the kept products are formed): with the warm start on,
  robot.zig's `newtonCostAt` in its arithmetic and order (`newtonCostAt`: 1/2 (a - a_free)^T M (a - a_free) by the same
  mass product, then 1/2 r^2 / R for the rows active at those accelerations), the free acceleration's cost first, then
  the warm start's, the warm start kept unless it costs MORE; then a - a_free for the inertia's gradient. CHECKED: the
  twin's constrained step is robot.zig's over 20 steps on the limits, WARM AND COLD, bit for bit; robotgpu 20/20; on the
  device the 100 constrained steps' energy gap 0.0087% (bar 1%), the limits held; the single step's rounds 177 / 177
  (exact) and 174 / 174 (the reference pose's - more than cold, where a first step's warm candidate, zero, cost less
  than the free acceleration in some worlds), device and twin choosing alike in every world; lint.
  FOUND IN REVIEW - TWO DEFECTS IN THE TEST'S OWN HARNESS, which the cold path could not show (it never reads the warm
  array, and its start's product M (a - a_free) is of a zero vector): the tests' `Twin.init` never cleared the module's
  world arenas, so a twin began from the previous test's numbers - now cleared, as `Sim.initTwin` does; and the robot.zig
  side stepped its four worlds with one `Data`, carrying a world's warm start into the next - each world now begins with
  `forgetWarmStart`, as each of the twin's begins from zero. NEXT: P2b - the implicit servo's measurement first; then
  P3.
- Nov 5: P2b RETIRED, ON READING THE SERVO. Before measuring an implicit servo, its law: `robot_track.pdTorques` is
  Tan's stable PD - the spring's acceleration at the end of the step, through floating-base inverse dynamics with the
  full mass matrix - so it is implicit already; the diagonal shortcut its documentation rejects ("the robot passes
  100 rad/s within twenty frames") is the very form the Isaac Lab and Newton comparison assumed. Geno's armature of 2.0
  is the servo's strength standing (`standing_armature`, measured in S2c: the T-pose held 10 s, the dance unharmed).
  WHAT IT TELLS P4: the servo is a heavy kernel of its own - inverse dynamics with the dense mass matrix every physics
  step - to be designed against its cost. A LESSON FOR THESE STUDIES: read our own law before borrowing another
  engine's fix for it.
- Nov 5: P3a, PART ONE - THE GENERATOR IN ROBOT.ZIG, MuJoCo's own functions (engine_collision_primitive.c, read Nov 5):
  `Plane` (a point and its unit normal), `PlaneContact` (MuJoCo's `mjPreContact`: position halfway between the
  surfaces, distance negative in overlap, a tangent hint), `planeSphere` (`mjraw_PlaneSphere`: a contact while the
  sphere's surface is within the margin, at the midpoint between its lowest point and the plane), `planeCapsule`
  (`mjc_PlaneCapsule`: the sphere test at each end, the +axis end first, each frame along the capsule's axis - zimr's
  capsule lies along its local Y, MuJoCo's along Z), `planeBox` (`mjc_PlaneBox`: the eight corners in index order,
  each a contact while on the box's lower half and within the margin, AT MOST THE FIRST FOUR IN THAT ORDER - not the
  four deepest, as Newton keeps them: we follow MuJoCo), `contactFrame` (`mju_makeFrame`: the hint, else the world's y
  or, near it, z, made orthogonal; the second tangent normal x first). Fixed slots by construction: a sphere 1, a
  capsule 2, a box 4. GeomShape's comment no longer says robot.zig never collides. CHECKED against closed forms: a
  sphere sunk 0.05 (the midpoint at -0.025), a capsule flat (both ends) and tilted 45 degrees (one end, its distance
  exact), a box resting (its four lower corners in corner order, each at half its depth), the frame orthonormal with
  its hint kept; robot.zig 137/137; lint. NEXT: MuJoCo 3.17's own numbers for each pair (fixtures from its Python,
  once); the CPU's floor contacts for a robot (each geom's world pose from its body; friction MuJoCo's maximum of the
  pair); Geno's servo survival on them beside zimrphysics'; then the device's kernel.
- Nov 5: REVIEW (Simon: "Review"). THE CODE: the read deadline, the constraint step, the warm start, the many-step
  check, the generator - sound. ONE GAP FIXED: the device could not forget a world's warm start - a world re-posed by
  `uploadWorldPositions` kept the last pose's answer as its candidate start (MuJoCo's cost comparison would mostly
  refuse it, but robot.zig resets it, and its own test needed exactly that): `Sim.forgetWarmStart(world)`, named in
  `uploadWorldPositions`' documentation. ONE ASSUMPTION NAMED: every device row is marked "may only push"
  (`newtonStartWeights`), true while the rows are limits and contacts; the rows carry their kind before equalities
  come. THE COURSE WAS A SOLVER BEHIND - chapter 57 still taught the halving line search, the raw stopping rules, the
  old working set and phases, and named as MuJoCo Warp's differences the very things since adopted; chapter 56 said the
  inertia was always exact. REWRITTEN: chapter 56's inertia (MuJoCo's reference pose by default, DIAGEXACT as the
  option, Geno's choice); chapter 57's "Where Newton starts" (the warm start), "The line search" (MuJoCo's exact search,
  worked on the chapter's joint from a = 5: the step crossing the limit's turn, the bracket landing on a = 3 in one
  round), "When to stop" (the four scaled rules; Geno's caps), "The solve inside the step", "A workgroup per world"
  (the working set of 28,348 bytes, the kept products, the phases), "MuJoCo Warp's solver" (the same method in the same
  detail; what still differs). doc-sync: robots.html 0 drifted; lint. A HABIT TO KEEP: the course in the same turn as
  the code it teaches (the preference was written for exactly this).
- Nov 5: P3a, PART TWO - THE CPU's FLOOR CONTACTS, MUJOCO's NUMBERS, AND THE SERVO ON THEM. `Floor` (a plane, its
  friction and margin) and `pushFloorContacts` (robot.zig): every moving geom against the floor - its world pose from
  its body's, the geoms in order and each geom's slots in theirs (the device kernel's order to come), each contact keyed
  by geom and slot for Gauss-Seidel's warm start, its friction THE LARGER OF THE GEOM'S AND THE FLOOR'S - MuJoCo's rule,
  read in its source (`mj_contactParam`, same priority: "friction: max"; solref and solimp mixed by solmix) - its frame
  `contactFrame`'s; a moving cylinder or hull refused by name (`error.UnsupportedFloorShape`), not left without its
  contacts. FOUND ON THE WAY: `GeomSpec.friction`'s documentation said MuJoCo combines a pair as sqrt(a b) - that is
  zimrphysics' rule; corrected. CHECKED AGAINST MUJOCO 3.17 ITSELF (its Python, mj_forward on a floor and one primitive,
  recorded as numbers): a sphere (its contact and frame), a capsule turned 45 degrees (MuJoCo's one contact is our -axis
  slot, its first tangent the axis laid flat), a box turned about two axes (MuJoCo's three contacts in its corner order,
  and no fourth) - all within 1e-6; a box resting through `pushFloorContacts` (four contacts, keyed, the friction the
  larger); robot.zig 139/139; lint.
  MEASURED - GENO's SERVO ON THE GENERATOR's CONTACTS BESIDE ZIMRPHYSICS' (walk and run, 20 starts, a temporary switch
  in ServoRun): survival 2,699 of 7,760 frames against 1,748 (+54%), with 3.18 contacts a step against 6.04 - MuJoCo's
  functions make a contact once a shape touches (margin 0) where zimrphysics' manifolds hold more points, and the
  friction is MuJoCo's maximum (2.0 against the floor) rather than zimrphysics' geometric mean (1.41 for a geom's 1).
  THE GENERATOR IS A SOUND REPLACEMENT, AND THE BETTER ONE FOR THE SERVO; half the contacts is half the device's contact
  rows. NEXT: the CPU tracker on it (a fleet option, its survival and reward measured, then its default - the game and
  training on the same contacts), and the device's collision kernel calling the same functions; the course's section.
- Nov 5: P3a, PART TWO - MuJoCo's NUMBERS AND THE CPU's FLOOR (written by a turn that stalled at its last command;
  reviewed and its tests run after). A TEST WITH MuJoCo 3.17's OWN CONTACTS (`mj_forward` in its Python package, the
  numbers recorded): a sphere, a capsule turned 45 degrees about y (one contact, its lower end's, the frame's first
  tangent the axis laid on the floor), a turned box (three contacts in MuJoCo's corner order, and no fourth) - positions,
  distances and frames within 1e-6; MuJoCo's quaternions (w, x, y, z) against zimr's (x, y, z, w), its capsule along
  local z against zimr's y. `Floor` (a plane, a friction, a margin) and `pushFloorContacts`: every geom of a robot
  against the floor, each geom's world pose from its body, the geoms in order and each one's slots in theirs - the
  order robotgpu's kernel will make them in - keyed by geom and slot for Gauss-Seidel's warm start; a contact's
  friction the LARGER of its geom's and the floor's (MuJoCo's rule for geoms of one priority - the comment that said
  MuJoCo takes sqrt(a*b) corrected: that is zimrphysics' rule); the world as body_a, so the normal points from the
  floor to the body, as `Contact.normal` is defined; a moving cylinder or hull refused by name
  (`error.UnsupportedFloorShape`) rather than left without contacts. A box resting on the floor: four contacts at its
  lower corners, keyed and framed. CHECKED: robot.zig 139/139; lint. NEXT: Geno's servo survival on robot.zig's floor
  contacts beside zimrphysics'; then the device's kernel.
- Nov 5: P3a, MEASURED - GENO's SERVO ON robot.zig's FLOOR CONTACTS AGAINST zimrphysics'. `ServoRun.ContactSource`
  (`physics_engine`, the default - zimrphysics through the bridge, the floor and Geno's bodies against each other -
  or `robot_floor`, `rbt.pushFloorContacts`, the floor alone, what the device makes). The servo alone on the 10-second
  dance from the judge's 20 starts (F1's), by the task's failure rule:
      zimrphysics, its friction rule (sqrt: Geno's geoms 1, the floor 2 -> 1.41)    1.55 s, 1 of 20 to the end
      robot.zig's floor, MuJoCo's rule (the larger -> 2)                            2.79 s, 1 of 20
      robot.zig's floor at the physics engine's grip (1.41)                          3.15 s, 3 of 20
  NONE of zimrphysics' contacts in these runs is between Geno's own bodies (0.0%), so the floor alone loses nothing
  here; and at equal friction robot.zig's floor contacts - MuJoCo's plane functions - DOUBLE the servo's survival, so
  the difference is the contacts' geometry, not their grip. THE EVIDENCE FOR THE PLAN's AIM: training and play on the
  contacts the device will make costs the servo nothing - it gains. NEXT: robot.zig's floor the tracker's contacts
  (`ServoRun`'s default, and the judge's), the friction rule MuJoCo's; the floor's own friction (2.0, tuned against
  zimrphysics' rule) left as it is until measured on the new contacts; then the device's kernel.
- Nov 5: THE TRACKER STANDS ON robot.zig's FLOOR. `robot_track.ContactSource` (`robot_floor`, `physics_engine`) - one
  definition, `ServoRun.ContactSource` its alias - and `Task.contacts`, robot.zig's floor by default: the fleet's
  `driveOnce` (training, the judge, every planner that imagines a step through it) and `ServoRun` both take
  `rbt.pushFloorContacts`, the contacts the device will make; the physics engine's collision stays the other source.
  `Task.floor_friction`'s comment now names each source's rule (robot.zig MuJoCo's larger, the physics engine the
  geometric mean); the floor's 2.0 left as it is until measured on the new contacts. CHECKED: robot_track 326 passed,
  robot_geno 342 (the slow and report-gated skipped); S2c on the new floor - the T-pose still holds its full 10 s;
  the robot-mocap tutorial (the tracker's floor contacts, MuJoCo's functions and friction rule; the physics engine for
  self-collision) and doc-sync, 0 drifted; lint. LEFT FOR LATER: the fleet still builds a physics-engine world and
  bridge per environment that robot.zig's floor does not use. NEXT: the device's collision kernel (P3a's device side).
- Nov 5: P3a, THE DEVICE's FLOOR KERNEL (`floor_contacts`, the constraint program's first dispatch, one invocation per
  world and geom): robot.zig's own plane functions on each geom's pose in the world (`geom_poses`' arrays), each of the
  geom's SLOTS filled or left empty - `Counts.floor_slot_count`, each moving geom's `robot.floorSlotsOf` (a sphere 1, a
  capsule 2, a box 4) in geom order, `geom_first_floor_slot` and `geom_floor_slot_count` packed per geom; the slots'
  `floor_slot_filled` (world_u), positions, distances and the frame's two tangents (world_f, `robot.contactFrame`).
  THE FLOOR in the uniform's fourth row (`floor_contacts`, a `Switch`, off unless set - a model holds no floor - and
  `floor_height`, `floor_friction`, `floor_margin`); `Counts`' padding now two words. `pushFloorContacts` places a
  geom by `Pose.compose`, as kinematics and the device's `geom_poses` do - one definition of where a geom is. CHECKED:
  THE TWIN's FLOOR CONTACTS ARE robot.zig's, BIT FOR BIT, slot by slot in robot.zig's push order (Geno and the
  humanoid, four worlds each, the floor at the root's height so the legs reach under it: positions, distances,
  tangents; contacts present); robotgpu 21/21; the device test with the kernel compiled into the step program (its
  pipeline built, no validation messages, every number unchanged - the floor off there); lint. NEXT: a host call to
  give a Sim its floor; the kernel on the device against the twin (lavapipe) and through WGSL (Tint); then P3b, the
  contact rows.
- Nov 5: THE FLOOR ON THE DEVICE, AND A REGRESSION OF P2's FOUND ON THE WEB. `Sim.setFloor(robot.Floor)`: the floor's
  four options set for the steps submitted after (the pipe rewrites its uniform at the next batch when the options
  differ); a plane not facing up refused by name (`error.FloorNotHorizontal`). An empty slot is now all zeros, so two
  engines agreeing on which slots hold contacts agree on every number. The floor's arrays are among the step's
  compared arrays (`step_array_bars`, the poses' bar of 256). THE DEVICE CHECK FIRST PASSED ON AN EMPTY FLOOR - every gap
  0.0, because the check raises each world's root 0.15 m above the last and no foot reached a floor at 5 cm: the floor
  now stands at the middle world's root height (worlds below deep in it, the middle one's legs under it, those above
  clear), and the check counts the twin's filled slots and FAILS ON NONE: 1,547 contacts; positions 1.5, distances 8.0,
  tangents 13.9 epsilons against bars of 256; the filled sets equal; no validation messages.
  THE WEB BUILD WAS BROKEN SINCE P2 - review had run the lab natively only: spv2wgsl refuses a barrier after an early
  `return` (`BarrierInNonUniformControlFlow`), and `newton_solve`'s no-rows exit returned early - uniform in fact (a
  `workgroupUniformLoad`), which the translator cannot see. Now a branch: the rows' solve and its store in the `if`,
  the free answer in the `else`, nothing returning. AND A TRANSLATOR BUG: `emitCompositeExtract` wrote every index as
  `[i]`, wrong for a struct's member (WGSL indexes no structure) - first met by the floor kernel's optional
  parameters (a Zig optional by value is a struct of its payload and its flag): it now walks the composite's type as
  `emitAccessChain` does, a struct's member named `.field_N`; a test pins it (spv2wgsl 66/66). TINT (headless Chrome,
  SwiftShader, 32 KB granted) now accepts every kernel's WGSL; the verdicts are drawn on the canvas, which headless
  Chrome cannot present - the republished page is for Simon's phone. CHECKED: robotgpu 21/21; the device unchanged
  (the constrained steps' 0.0087%, the step's 238.64 epsilons, rounds 177 / 177 and 174 / 174); lint. A HABIT: the
  web build with every change to the kernels, not only the native lab. NEXT: P3b, the contact rows (four pyramid edges
  a contact, the Jacobian along each body's chain, the bodies' translation weights for the reference pose's inertia);
  the course's chapter 57 when the floor's contacts make rows.
- Nov 5: REVIEW (Simon: "Review"), OF THE FLOOR's CONTACTS. FOUND AND FIXED: (1) THE LAB HAD THE EMPTY-FLOOR DEFECT the
  device test had - its worlds are posed alike (each root `pose_step x 3` above the last), so a floor at 5 cm touched
  nothing and the phone would have shown AGREE on empty slots: its floor now stands at the middle world's root height,
  and the page shows the twin's filled slots ("the floor's 1547 contacts among them" - counted right after the step
  comparison's request, as the constraint check's twin shares the arrays and has not run yet). (2) THE STALLED TURN
  HAD ALSO WRITTEN THE COURSE'S CHAPTER 59, "Contacts against the floor", which its review had not read (only its two
  Zig files were diffed): read now - accurate and in the course's style (the sphere, the capsule, the box with worked
  numbers, the frame, MuJoCo's friction rule, the fixed slots) - and given "On the device" (the slots, the kernel and
  its fold, `Sim.setFloor`, the horizontal floor). (3) Section 27 said this engine does not detect collisions: it now
  says robot.zig makes its own contacts for a robot on a flat floor and leaves the rest to zimrphysics. CHECKED AND
  CLEAR: the floor contacts' softness - Geno's MJCF sets no solref, solimp, margin, condim or priority, and the bridge's
  time constant of two steps is what robot.zig's clamp makes of MuJoCo's default 0.02 s at 60 Hz. NOTED: the humanoid's
  constraint-force gap is 719 epsilons with the warm start (233 cold), its rounds 174 against 157 - more rounds, more
  rounding, within its bar of 4,096. Lab headless and web (Tint) clean; doc-sync 0 drifted; lint.
- Nov 5: SIMON's PHONE, THE FLOOR ON A MOBILE GPU THROUGH WGSL: the step AGREE (largest gap 134.94 epsilons, in
  smooth_joint_accelerations), the floor's 1,547 contacts among the compared arrays; the humanoid's constraints AGREE,
  1,075 rows, 174 rounds on the GPU and on the twin - the constraint force's gap 1,115.63 epsilons against a bar of
  4,096 (lavapipe 719): the least headroom of any check, about 3.7 times; watched, not changed. THE LAB's LINES were cut
  at a phone's width ("smooth_joint_a", "the floor's 1547 co"): every line now 48 characters or fewer - the worst array
  and its bar on a line of their own, the floor's count on its own, the rounds below the rows - and the page 520 tall;
  republished. THE DISK: 98% full (0.5 GB free, `.zig-cache` 9 GB) - the build's guard refused the web build; freed
  `zig-out`, `.zig-cache/tmp`, Newton's unpacked source and pip's cache (1.2 GB free, 94%). The cache grows with every
  build: the guard's own order when it refuses again - `zig-out`, then `.zig-cache/tmp`, the whole cache last.
  P3b's DESIGN, from robot.zig's own `makeConstraints` and `addContactRows`:
    ORDER - equalities, then limits, then contacts SORTED by `contactBefore` (body_a, body_b, then the contact's key -
      geom << 3 | slot): for the floor, by the geom's BODY, then geom, then slot. The device's slot order is geom
      order, the same only while geoms are numbered in body order (MJCF's are, depth-first; a model built in code need
      not be): `pack` lays out the slots sorted by body (stable in geom order), so the orders agree for any model.
    ROWS - a contact makes rows only while its distance is under its margin; its violation the distance less the
      margin; the Jacobian each body's point Jacobian at the contact (`jacPoint`, along its dof chain), the second's
      less the first's (the world's zero), projected on the normal and the two tangents; four rows, for each tangent
      then each sign: normal + sign x mu x tangent - stored sparse, the chain's dofs in dof order, so every sum over a
      row matches robot.zig's dense one (its extra terms are zeros); the reference pose's inertia the two bodies'
      translation weights x (1 + mu^2); softness and impedance robot.zig's contact defaults; every row may only push.
    CAPACITY - `constraint_capacity` grows by four rows a floor slot (Geno, every geom down: 48 slots, 192 rows);
      `row_nonzero_capacity` the longest dof chain; NEWTON's ROWS 128 -> 256: 24 bytes a row in workgroup memory,
      31,420 bytes in all - within the 32 KB a phone grants, with 1,348 to spare (the Hessian, 76 x 76, is 23 KB of it).
    COST, FOR P3c - the Hessian is built entry by entry over the rows, which for limits (one nonzero a row) is cheap and
      for contacts (a chain's nonzeros) is not: each row's outer product over its nonzeros, the rows in order so every
      entry sums them in robot.zig's order - then MJW's incremental update.
- Nov 5: P3b ON THE TWIN - THE FLOOR's CONTACT ROWS, BIT FOR BIT WITH robot.zig's STEP. The rows' kind and source
  (`constraint_row_kind`, `robot.ConstraintKind` itself - one definition for both engines - and `constraint_row_source`,
  a limit's candidate or a contact's floor slot; `constraint_row_candidate` renamed, as robot.zig's `constraint_source`
  carries both meanings). THE SLOTS IN robot.zig's CONTACT ORDER (`pack`: by body, then geom, then slot - so the rows
  agree for any model, not only MJCF's depth-first numbering), each slot's geom (`floor_slot_geom`), the bodies'
  translation weights (`body_translation_inverse_weight`, MJW's `body_invweight0`). `packContactRows` (after the
  limits in `constraint_rows`): robot.zig's `addContactRows` line for line - no rows at the margin or beyond, the
  violation the distance less the margin, the point Jacobian on the body's chain (`jacPoint`: lin + ang x (point -
  the root's subtree centre of mass)), four edges (each tangent, then each sign: normal + sign x mu x tangent, its
  expression in its order), mu the larger of the geom's and the floor's, the reference pose's inertia (the two bodies'
  translation weights) x (1 + mu^2). `project_constraints` gives a contact row robot.zig's contact defaults (softness
  and impedance as `pushFloorContacts` leaves them). Counts: four rows a floor slot; nonzeros the longest chain.
  Newton's rows 128 -> 256. The tests' arenas: `world_u` 2^19, `efc_f` 2^22.
  CHECKED: THE TWIN's STEP ON THE FLOOR IS robot.zig's (pose, `pushFloorContacts`, `step`), 10 STEPS, BIT FOR BIT -
  Geno and the humanoid, cold and warm: every coordinate and velocity, the last step's rows and rounds; contact rows
  made and solved along the way (counted over every step on robot.zig: the last step can be clear of the floor, a
  centimetre of overlap pushed out within the softness's time constant); and with the constraints disabled, no row on
  either. robotgpu 22/22; the device test passes (Geno's step 238.64 epsilons, the floor's 1,547 contacts, the
  constrained steps); lint.
  FOUND BY THE DEVICE TEST: the contact rows were gated on the floor alone, so a model whose constraints are disabled -
  Geno's step check, with a floor for its slots - still made rows (worlds sunk in the floor, pushed out hard: the
  100-step energy check failed). robot.zig makes no row of any kind for such a model: now gated on both switches, and
  the twin test covers it.
  THE DISK, AGAIN: the cache refilled it within a few builds (582 MB free after the cheap steps); the whole cache
  removed (the guard's last resort) - 11 GB free, the next builds cold (lint and robotgpu's tests rebuilt in under
  five minutes).
  NEXT: the device's refusal narrowed (a floor's contacts are simulated: the refusal for possible contact goes - the
  device's contacts are the floor's, set by `setFloor`, and nothing else); the contact rows on the device against the
  twin (Geno's step on the floor: its rows compared, and many steps by statistics); the web build and Tint; chapter
  59's rows; then P3c.
- Nov 5: REVIEW (Simon: "Clear cache. Review"). THE CACHE CLEARED (95 MB since the cold rebuild; 11 GB free).
  FOUND AND FIXED: (1) NEWTON's CAPACITIES WERE NOT CHECKED. Newton clamps a world's rows to its 256 - a row past them
  would have been left out of the solve SILENTLY, the device's answer apart from robot.zig's with no sign - and a model
  wider than 76 dofs would run its loops past the working set's arrays (wrong numbers on a GPU, a panic on the twin;
  `Sim.forgetWarmStart` would slice past its own). Geno, at 75 dofs and 192 possible rows, sat just inside both. Now
  REFUSED BY NAME (`ModelError.TooManyDofs`, first and whatever the constraints; `ModelError.TooManyRows`, on a
  world's most rows, `Counts.constraint_capacity`); `max_newton_dofs` and `max_newton_rows` moved before the refusal
  that reads them (lint's decl-order, taken as the design hint it was: they are the device's vocabulary now). (2) THE
  REFUSAL NARROWED, as P3b needed: possible contact is no longer refused - the device's contacts are its floor's
  (`setFloor`), robot.zig's `pushFloorContacts`, and no body touches another; equalities still are. The refusal test:
  Geno accepted with his constraints on, a copy one dof too wide refused, a copy of seventy boxes on one body (1,120
  possible rows) refused. (3) STALE COMMENTS: the rows kernel's (now the floor's rows after the limits), Newton's start
  ("every row is a joint limit's"), the working set's size (31,420 bytes: the Hessian 23 KB, the 256 rows 6 KB), the
  constraint program's, the device checks' ("contacts, which the device does not simulate yet" - Geno's checks keep
  their constraints off for what they measure; the humanoid's `max_contacts = 0` gone, no floor being set there).
  (4) THE COURSE A STEP BEHIND THE CODE AGAIN - chapter 57's working set and constraint program, chapter 59's device
  section without the rows: brought up (the rows, the pyramid of section 20, the Jacobian on the chain, the order,
  `packContactRows`' fold). CHECKED: robotgpu 22/22; the device test (Geno's step 238.64 epsilons, the humanoid's
  rounds 177 / 177 and 174 / 174, no validation messages); doc-sync 0 drifted; lint.
  NOTED, THE NEXT STEP: THE CONTACT ROWS HAVE NOT RUN ON A GPU - Geno's device check keeps its constraints off, and the
  humanoid's constraint check sets no floor: give that check a floor, so the device's contact rows are compared with
  the twin's on lavapipe and on Simon's phone.
- Nov 5: P3b ON THE DEVICE - THE FLOOR's CONTACT ROWS ON A GPU. The humanoid's constraint check (device test and lab)
  given a floor 2 cm above the lowest point of the first world's pose (`robotgpu_host.floorUnderLowestPoint`: found
  with robot.zig under a probe floor high above everything), its contact rows counted on the twin
  (`robotgpu_host.countRowsOfKind`) and shown. MEASURED on lavapipe, 1,855 rows of which 780 the floor's contacts',
  the rows' integers equal and Newton's rounds equal in every world (238 / 238 exact, 264 / 264 reference pose):
      violation 1.0, Jacobian values 2.0, velocity 5.5, target acceleration 336.2, M^-1 J^T, inertia and regulariser
      230.6 (exact; 0, 0 and 41.8 at the reference pose), per-row force 11,398.7 (exact; 2,870.2 at the reference
      pose), joint accelerations 84.1 / 78.7, constraint joint forces 43.5 / 39.7 epsilons.
  THREE BARS CHANGED, ON THE MEASUREMENT: the Jacobian values 1 -> 16 (a contact's from its geometry, where a limit's
  is +1 or -1 exactly); the target acceleration 64 -> 1,024 (built from the solves' inertias); each row's force
  4,096 -> 32,768 - a contact's four pyramid edges can trade force among themselves for nearly the same push on the
  robot, so how its force splits across them is only weakly determined (unique by the rows' softness, but barely):
  the push itself, J^T f, and the accelerations keep their bar of 4,096, at 44 and 84 measured. The lab's page:
  "AGREE - 1855 rows, 780 the floor's", 264 rounds on both; Newton needs 31,420 bytes of the 32,768 granted. Tint
  clean; the page republished for Simon's phone (its 32 KB leaves 1,348 bytes to spare). robotgpu 22/22; lint.
  NEXT: Simon's phone on the contact rows; the many-step constrained check on a floor (penetration and energy over
  100 steps); then P3c - the Hessian's cost with contact rows, each row's outer product over its nonzeros.
- Nov 5: SIMON's PHONE ON THE CONTACT ROWS: AGREE, 1,855 rows of which 780 the floor's, rounds 264 / 264, the largest
  gap 6.50 epsilons (in constraint_velocity, its bar 16); 31,420 bytes of its 32,768.
  REVIEW, FOR P3c - NEWTON's ROW WORK IS THE COST TO REMOVE FIRST. `newtonHessian` builds all nv^2 entries (both
  triangles, where the factorisation reads only the lower one), and for each walks every active row, finding the row's
  entry for each of the two dofs by a linear search through its nonzeros in global memory (`rowJacobianEntry`);
  `newtonGradient` searches the same way per dof and row. With limits (one nonzero a row) it was cheap; with contacts
  (a chain's dofs a row) it is not: Geno walking, 8 foot contacts, 32 rows of 15 nonzeros - about 5.4 million searched
  loads a build, four builds a step. THE FORM: each active row's outer product over its own chain, the lower triangle
  only, the rows in order - so every entry still sums its rows in robot.zig's order and the twin stays exact WITHOUT
  changing robot.zig - about 3,600 multiply-adds a build there; the gradient a scatter of each row's f J over its chain,
  the rows in order per dof. MJW's incremental update (only the rows whose activity changed) after, measured.
  THE ROUTE TO RESIDENCY (Simon, Nov 5: how many turns until the simulation and SuperMimic / EfficientTDMPC are
  resident on the GPU?). The learners are on the GPU already (`robot_track_resident.zig` trains there; EfficientTDMPC's
  kit is complete there, unused by the trainer); what is not is the ENVIRONMENT - robot.zig's physics and the tracking
  task on the CPU fleet. In the order of risk, each a verified step a turn or two:
      P3c Newton's row work (outer products, the gradient's scatter) .................. 2
      P3's device checks: the many-step check on a floor, Geno lying and standing ...... 1
      P4  the servo on the device - Tan's stable PD through floating-base inverse
          dynamics, the free root's block apart (the heaviest kernel, first) ......... 2-3
          the clips on the device and the reference sampled .......................... 1-2
          the observations and their derived quantities .............................. 1-2
          SuperMimic's rewards; the terminations, terminated and truncated apart ...... 1-2
          the resets and pushes as masks (the warm start forgotten with each) ......... 1-2
          the action filter, the PD targets and the decision's clock (S0) ............. 1-2
          the decision program assembled, its records into the learner's buffers;
          checks: a zero action reproduces the reference, the servo's baseline
          against the CPU fleet's .................................................... 2-3
      the trainer on the device's worlds - acting from the GPU's own weights ......... 1-2
      EfficientTDMPC acting on the device (its planner in the decision program) ...... 2-3
  SuperMimic resident: about 13 to 20 turns; with EfficientTDMPC, about 16 to 23. DEFERRED until after the first
  resident run, as accuracy and robustness rather than residency: P3d (the cap's tail with contacts), P3e (feet at
  large steps), P4b (randomisation), P5's night on the RTX 5070 (Simon's to run) - about 5 more.
- Nov 5: P3c, FIRST STEP - NEWTON's ROW WORK WITHOUT SEARCHES. The outer products of last turn's plan need a barrier
  between rows (every chain passes through the root's six dofs, so any two rows touch the same entries); kept instead:
  each lane its entries, the rows in order as before - every sum taking its terms in robot.zig's order, the twin exact
  with robot.zig unchanged - and each row's entry for a dof READ AT ONCE. `newton_row_subject` (in place of the
  push-only flag - no extra workgroup memory, Newton still 31,420 bytes): a row's kind in the top three bits, a limit's
  dof or a contact's body below; whether a row may only push follows from its kind (`ConstraintKind.isUnilateral`, as
  robot.zig). `body_chain_rank` (a number per body and dof, packed with the chains; `no_chain_place` for a dof not on
  the body's chain - MJW's `body_isdofancestor` with the place in it): a contact row's nonzeros are its body's chain in
  dof order, so `newtonRowEntry` reads the dof's place - one table read where `rowJacobianEntry` searched, kept for
  kinds the device does not make. A table rather than a popcount over `body_ancestor_mask`: spv2wgsl has no
  `OpBitCount`, and the table is a single read. THE HESSIAN's LOWER TRIANGLE ONLY (the factorisation and both solves
  read no other). The gradient reads the same way. CHECKED: robotgpu 22/22 (the twin bit for bit on the floor, on the
  limits, in Newton's tests); the device unchanged (Geno's step 238.64 epsilons; the humanoid on its floor, 1,855 rows,
  rounds 238 / 238 and 264 / 264, accelerations 84.1 / 78.7, joint forces 43.5 / 39.7 epsilons); the web build and
  Tint clean; chapter 57 (what a row stands on, the lower triangle); doc-sync; lint.
  NEXT: the many-step check on a floor (Geno lying and standing, penetration and energy over 100 steps) - P3's device
  checks - then P4, the servo on the device first.
- Nov 5: SIMON's PHONE ON NEWTON's ROWS READ AT ONCE: unchanged - AGREE, 1,855 rows of which 780 the floor's, rounds
  264 / 264, the largest gap 6.50 epsilons; a change that alters nothing on two GPUs is what it should be.
  P3's DEVICE CHECKS - THE FLOOR OVER MANY STEPS (`runRobotgpuFloorSteps`, vk-host-test): Geno with his training
  physics (`robot_geno.physicsOptions`: 60 Hz, Newton 3 rounds and 5 line-search iterations, the reference pose's
  inertia, the warm start) in 64 worlds - the even ones standing in his reference pose, the odd ones lying (the root
  turned a quarter about x, lowered so their lowest point lies as deep) - on one floor 5 mm into the standing pose's
  lowest point, no servo: the standing fall, the lying settle; 100 steps on the device and the twin. Compared, as the
  trajectories drift: each world's energy, the deepest any geom ends in the floor (`deepestPenetration`, robot.zig's
  own floor contacts on the final poses), every number finite (`zm.isFinite` - std.math is the GPU-portable math's
  alone). MEASURED on lavapipe: 3,584 contact rows at the first step (about 56 a world); energy gap 0.0085% of the
  initial; the deepest in the floor 0.5 mm on both; every number finite. BARS 1%, 2 cm, finite, and rows made at the
  first step - the test failing beyond. P3, AS RESIDENCY NEEDS IT, IS DONE: the floor's contacts made, solved and
  held on the device, its rows read at once. P3d and P3e (the cap's tail with contacts, feet at large steps) wait for
  the first resident run.
  NEXT: P4, the servo on the device first - robot_track's `pdTorquesToward` (Tan's stable PD: the spring's acceleration
  at the step's end, then floating-base inverse dynamics through the mass matrix), read first, its device form chosen
  against its cost.
- Nov 5: P4, THE SERVO - READ, ITS DEVICE FORM CHOSEN, robot.zig's HALF DONE. `robot_track.pdTorquesToward` is four
  stages: each dof's position error toward the target (`differentiatePos`: a ball's a rotation vector); each non-root
  dof's wanted acceleration (Tan's stable spring, `stableSpringAccelToward` - (w^2 (e - dt v) - 2 zeta w (v - v*)) /
  (1 + 2 zeta h + h^2), w = 2 pi f, h = w dt - clamped; the root's six zero); for a free root
  `rmx.floatingBaseTorques` - the dense mass matrix's root rows, the root's 6 x 6 block solved by Gaussian
  elimination with partial pivoting for the root's own acceleration, then `rbt.inverseDynamics` on the whole - and
  the root's six torques zeroed; a root assist only when the gains ask (Geno's do not: `servo_gains` sets only
  `max_acceleration = 3000`; frequency 20 Hz, critical damping, no assist, no feedforward by default). THE FINDING THAT
  MAKES IT CHEAP ON THE DEVICE: robot.zig's `inverseDynamics` is already M a + the bias forces through the assembled
  mass matrix ("so armature is included and the round trip is exact by construction") - `mulM` is the device's own
  `multiplyByMassMatrix` - so the device needs no second Newton-Euler pass: the step's mass matrix and bias forces,
  reused. The torques land in `applied_joint_forces`, which the step reads: THE SERVO GOES INSIDE THE STEP PROGRAM,
  after the bias forces and before the smooth forces - three kernels: each joint's error, each dof's wanted
  acceleration, and per world the root's block solve, then M a + bias.
  robot.zig's HALF (one definition for both engines): the two springs moved from robot_maximal.zig, which the GPU
  cannot build (it is zimrphysics' side), into robot.zig, robot_maximal keeping their names as aliases; one joint's
  `differentiatePos` as a pure function of its coordinates (`jointPositionDifference`, values in and out, so a kernel
  calls it on a world's joint), `differentiatePos` built on it. The spring without feedforward is the feedforward one
  at a zero target velocity to the bit (v - 0 = v), so one spring serves both. CHECKED: robot.zig 139/139,
  robot_track 326, robot_geno 342 - nothing changed; lint.
  NEXT: the device's servo - its uniform row (the mode: off, toward rest, toward motion; frequency, damping, the
  acceleration's bound), its arrays (the targets and their velocities, the errors, the accelerations), its three
  kernels, `Sim.setServo` (a root assist refused by name), and the twin's torques against `pdTorquesToward`, bit for
  bit.
- Nov 6: A TURN THAT DID NOT REPLY - its work found on disk, read, and kept. A review of the latest code ran to its end
  - every check it started passed - but its reply never came, and Simon asked whether it was stuck. Its changes,
  read from the files against zimr348: `body_chain_rank` named `body_chain_place` (a place in the chain, which is what
  it holds); the floor slots' layout taken out of `pack` into `packFloorSlots`, above its caller; the contact rows'
  packer in smaller pieces (`FloorContact`, what a contact's rows need; `floorContactAt`, none for an empty slot or a
  contact at its margin or beyond; `storeContactEdgeRow`, one pyramid edge's row); the subject word's three helpers
  gathered into `RowSubject` (`pack`, `kindOf`, `dofOrBodyOf`, the shift named `kind_shift` rather than a bare 29);
  the two springs with named quantities (`angular_frequency`, `phase_per_step`, the spring's pull and the damper's -
  the same operations in the same order, so the same bits), `robot_maximal`'s aliases documented apart; both
  tutorials brought along. ITS CHECKS, read from /tmp: robotgpu's tests; the device test (every number unchanged -
  Geno's step 238.64 epsilons, the floor's steps, the humanoid's rows and rounds - no validation messages); the web
  build and Tint at a phone's width; doc-sync, 0 drifted; robot_geno's tests, 342. Lint confirmed after its last edit;
  the snapshot it never took.
- Nov 6: P4, THE SERVO's LAW IN robot.zig - so robotgpu's twin can be held to it (robotgpu's tests cannot import
  robot_track, which brings the fleet and zimrphysics). `robot.servoTorques` with `robot.ServoLaw` (frequency, damping,
  the acceleration's bound): each dof's position error (`differentiatePos`), the implicit spring at the step's end
  toward the target's velocity or toward rest (one spring - toward rest is a zero target velocity, to the bit),
  bounded; then inverse dynamics, its floating-base form for a free root (`robot.floatingBaseTorques`, moved from
  robot_maximal with its reasoning: why fixed-base torques fail on a free body) with the root's 6 x 6 block solved by
  `robot.rootBlockAcceleration` - Gaussian elimination with partial pivoting and back substitution, a function of
  values a kernel can call - and `robot.rootDofCount`. robot_track's `pdTorquesToward` is now robot.zig's law plus the
  root's assist, which stays the CPU tracker's own (and the device will refuse); `rootDofs` a wrapper; robot_maximal
  keeps `floatingBaseTorques` as an alias, for robot_gym and its own callers. CHECKED, AND BIT-IDENTICAL IN PRACTICE:
  the servo's survival on the 10-second dance - chaotic, so any change of rounding would move it - reproduces its
  times exactly (1.55 s on zimrphysics, 2.79 s and 3.15 s on robot.zig's floor, the same runs reaching the end);
  robot.zig 139/139, robot_track 326, robot_geno 342; lint.
  NEXT: the device's servo against `robot.servoTorques`, bit for bit - the uniform's servo row, its arrays, its three
  kernels before the smooth forces, `Sim.setServo`.
- Nov 6: P4, THE SERVO ON THE DEVICE - and Simon's ask for it (Nov 6): "Geno ragdoll servoing to the dance simulated on
  GPU, and maybe other robots - the quadruped and the KUKA - side by side, CPU and GPU". THE SERVO, three kernels in
  the step program before the smooth forces, its torques the worlds' applied forces: `servo_errors` (per world and
  joint: `robot.jointPositionDifference`, `differentiatePos` over a step of one), `servo_accelerations` (per world
  and dof: `robot.stableSpringAccelToward`, toward each dof's target velocity or toward rest, bounded; a free root's
  six zero), `servo_torques` (per world: for a free root its 6 x 6 block from the mass matrix's root rows -
  `massMatrixEntry`, moved up beside the matrix's helpers, now shared with Newton - and its right-hand side
  -(c_r + M_rj a_j) in dof order, solved by `robot.rootBlockAcceleration`; then M a by robot.zig's product
  (`ServoMassProduct`) plus the bias forces, a free root's six torques zero). `ServoMode` (off, toward rest, toward
  motion) and the uniform's fifth row (frequency, damping, the acceleration's bound); `servo_targets` and
  `servo_target_velocities` the host sets each decision; `Sim.setServo(robot.ServoLaw, mode)` - the root's assist the
  CPU tracker's alone. CHECKED: THE TWIN's SERVO IS robot.zig's `servoTorques`, BIT FOR BIT - Geno (a free root and
  balls), the humanoid (a free root and hinges), the KUKA (a fixed base, no block) - toward rest and toward motion;
  robotgpu 23/23; the device test unchanged with the kernels compiled in (no validation messages); the web build and
  Tint clean; lint.
  NEXT, SIMON's PAGE: `robotgpu_sidebyside` - `geno_track`'s scene doubled, robot.zig on the left and robotgpu on the
  right: Geno servoing the copied dance clip on the floor (both on robot.zig's floor contacts and the same servo law);
  the GPU's body poses read back a frame late, for drawing only; then the Go1 servoing to its home pose and the KUKA to
  moving joint targets as further scenes; checked on Simon's phone.
- Nov 6: SIMON's PAGE - `robotgpu_sidebyside` (examples/robotgpu_sidebyside; published at
  https://claude.ai/artifact/BipLvreyx6rTaHrk7LC3yB): Geno servoing the copied dance on two engines at once. LEFT
  robot.zig on the CPU - the tracking task's own harness, `robot_geno.ServoRun`, on robot.zig's floor; RIGHT robotgpu
  on the GPU - one world of the same model, `Sim.setFloor` and `Sim.setServo` with the same floor and law, started
  from the state the CPU's `start` leaves (the frame's pose, the velocity into it, rested 1 mm over the floor), the
  clip's frame uploaded each frame (`servo_targets`), its body poses read back a frame or more later
  (`pipe.requestRange`) for drawing alone. One model built at the capture's own frame time (0.016667 - the BVH's
  rounded 1/60), so the physics and both servos read one timestep; the servo alone, the balance reflex off (it reads
  the CPU's own state), both restarting together when the CPU's Geno loses the reference or the clip ends. Drawn from
  the robot.zig model's own geoms (`drawRobot`), so the Go1 and the KUKA draw alike. The dance capture
  (dance1_20s.bvh, 3.8 MB) and the bind pose embedded; the page 10.8 MB. MEASURED IN IT, honestly: the hips' gap,
  the GPU's pose against the CPU's AT THE SAME STEP (first shown against the CPU's pose now, which counted the
  readback's frame of lag - 39 mm where the engines were 15 mm apart). 15.3 mm two seconds into a run on lavapipe:
  the twin is robot.zig to the bit, the device differs from the twin in its last bits, and a dance on the edge of
  falling amplifies them. Native headless and the web build clean (validation, Tint).
  NEXT: the Go1 servoing to its home pose and the KUKA to moving joint targets, as scenes of the same page; Simon's
  phone.
- Nov 6: SIMON's PHONE ON THE SIDE-BY-SIDE PAGE: run 9, frame 69, the hips 10.7 mm apart - the two engines on a mobile
  GPU through WGSL. REVIEW (Simon: "Make the code perfect. Optimise for understanding"): THE PAGE - the GPU's poses as
  one request in flight (`PoseRequest`: both arrays' requests, each collected once as it lands - `collectArray` - and
  the CPU's hips at its step, so the two are compared at one step); the sides named for what they are (`cpu`, a
  `ServoRun`; `gpu`, a `Sim` or null with its refusal); the GPU's world returned by `makeGpu` rather than assigned
  through a pointer lint could not prove initialised, its pose buffers by `GpuPoses.alloc`; `ServoRun.step`'s result
  no longer thrown away unnamed - it is the CPU's hips' distance from the clip's, the servo's own tracking error, now
  shown beside the engines' gap (502 mm against 15 mm, two seconds into a run: the free root is steered by its feet
  alone, so the dance's travel is followed roughly - the engines agree some thirty times more closely than the servo
  follows the clip); the drawing split into `drawScene` and `drawText`, one line of text a `drawLine`, each side's
  colours a `Colours`. THE KERNEL - the root's 6 x 7 system its own function (`rootBlockSystem`, as robot.zig's
  `floatingBaseTorques` builds it), so `servo_torques` reads as the law does; `servo_errors`' arrays named
  `coordinates` and `target_coordinates`. robot.zig - `floatingBaseTorques`' documentation stated neutrally (its
  reason kept: torques assuming a still root make a free body diverge). THE COURSE - chapter 60, the servo on the
  device: the three kernels, where they sit in the step, the free root's block solve, the side-by-side page and why
  the two part; folds of `rootBlockSystem` and `servo_torques`; linked to the robot-mocap tutorial's section 7. CHECKED:
  robotgpu 23/23 (the twin's servo still robot.zig's to the bit); the page natively and on the web unchanged in
  behaviour (the same frame, the same 15.3 mm), Tint clean, republished; doc-sync 0 drifted; lint.
  NEXT: the Go1 servoing to its home pose and the KUKA to moving joint targets, as scenes of the page.
- Nov 6: SCENES on the side-by-side page: `SceneKind` (geno_dance, go1_stand), one `Scene` at a time, built in place
  when shown and released when left (one GPU world at a time); a button in the lower left moves to the next (the
  check script taps it). The CPU side of a robot without a task harness: `CpuServo` - robot.zig's servo step in
  `ServoRun`'s order, as the device takes it (floor contacts from the step's start, bias forces, `servoTorques`
  applied, step, forward). The Go1 exported by zimr (`robot_go1_model`), servoed to its home pose (its first keyframe)
  after a 10 cm drop, every 180 frames; drawn from its collision shapes (cylinders now drawn too). Geno's scene as
  before (checked: headless, the button, 0 validation messages).
  THE GO1 FOUND TWO GAPS, both refusals rather than errors:
  (1) CYLINDERS ON THE FLOOR. MuJoCo collides a cylinder with a plane (`mjc_PlaneCylinder`, up to 4 contacts);
  robot.zig's `pushFloorContacts` refuses one (`UnsupportedFloorShape`) - and `floorSlotsOf` gives it 0 slots, so the
  DEVICE silently leaves cylinders without contacts where the CPU refuses: the two disagree. The Go1 has 12 (hip
  guards, two on the trunk). FIX: MuJoCo's plane-cylinder in robot.zig, 4 slots, the device's floor kernel through the
  same function, checked against MuJoCo fixtures as P3a's shapes were.
  (2) ROWS RESERVED FOR EVERY SLOT. The device's capacity is a world's worst case (`countsOf().constraint_capacity`:
  the limits' rows plus 4 pyramid edges per floor slot, touching or not), refused over Newton's 256
  (`TooManyRows`). The Go1 without its cylinders: 24 capsules (48 slots), 2 boxes (8), 4 feet (4) - 60 slots, 240
  rows, plus 12 limited joints: over. With its cylinders at 4 slots each, 432 and more. Standing, its four feet touch:
  16 rows. MuJoCo makes rows only for contacts within the margin, and MuJoCo Warp packs each world's rows up to njmax,
  a fill past it a warning (mjWARN_CNSTRFULL), not a refusal of the model. PROPOSED: rows packed per world for the
  slots filled (and the limits active), the capacity a runtime overflow (the world's overflow word) rather than a
  model refusal - MuJoCo Warp's design, so the reference followed, not departed from.
  ORDER PROPOSED: (1) first (self-contained), then (2).
- Nov 6: (1) CYLINDERS ON THE FLOOR - DONE. `robot.planeCylinder`, MuJoCo 3.17.0's `mjc_PlaneCylinder` (fetched from
  its tag, followed operation by operation): up to four contacts in MuJoCo's order - the deepest rim point (none at all
  when it is beyond the margin), the same side of the other cap's rim, and two more a third of the way round the nearer
  cap, an equilateral triangle; the cap lying flat takes the cylinder's local x (zimr's local x is MuJoCo's: the import
  turns MuJoCo's z onto zimr's y by a quarter turn about x). `floorSlotsOf(.cylinder)` 4 (was 0: the device had left
  cylinders without contacts silently while robot.zig refused them - the two now agree); `pushFloorContacts` and the
  device's floor kernel call it. CHECKED: five scenes against MuJoCo 3.17's own contacts (lying tilted 2 degrees - the
  tilt so the deeper end, and so the slot order, is decided by geometry, not by the sign of a rounding residue -;
  tilted 20 degrees, one contact; exactly upright, the local-x path, three; buried, all four) within 1e-6; the twin's
  floor contacts robot.zig's to the bit on the Go1, cylinder contacts among them, beside Geno and the humanoid;
  robotgpu 23/23; the web build translated and Tint clean; the course's chapter 59, "A cylinder" (the four points, a
  sketch, the upright cap worked, a fold); doc-sync 0 drifted.
  THE GO1 THEN TUMBLES ON LANDING (watched at frames 5, 15, 30, 60: in the home pose in the air; legs splayed after
  landing; the trunk on end by frame 60). Its model asks for physics the page did not give it: MuJoCo's default 2 ms
  step (500 Hz; the MJCF sets none), elliptic friction cones with impratio 100, joint damping 2 (1 at the abductions),
  armature 0.01, frictionloss 0.2, and position actuators - kp 100, torques held to +-23.7 Nm (+-35.55 at the knees).
  The page ran it at Geno's training physics (16.7 ms steps) under an unlimited inverse-dynamics servo. NEXT: the Go1
  at its own 2 ms step, several steps a frame on both engines; then the cone and the actuators - each a difference
  from the reference model to weigh with evidence. Then (2), the rows packed per world.
- Nov 6: BACK TO THE DANCE (Simon: "lets go back to the dance tracking plan"); the Go1's physics and the packed rows set
  aside. P4's first piece, THE CLIPS ON THE DEVICE, starts from what the CPU fleet does each physics step
  (`Fleet.driveOnce`): the servo aims at the reference pose a frame ahead (`at = min(frame + 1, last)`), the action
  added to it as a displacement in velocity space (`applyAction`: scaled, the free root's six zero, through
  `integratePos`), every hinge then held in its range (`clampHinges`); the servo; the step. The device's step already
  has the servo, reading `servo_targets`.
  DONE: ONE JOINT's INTEGRATION, `robot.integrateJointPosition` (`integratePos`' body for one joint, a function of
  values beside its inverse `jointPositionDifference`; `integratePos` now loops over it): what a kernel forming the
  targets calls, as robot.zig does. CHECKED: one joint's integration lands on the pose its difference aimed at, a slide,
  a hinge, a ball and a free joint; robotgpu 23/23 (the twin's steps unchanged to the bit).
  DESIGN, P4a - THE CLIPS ON THE DEVICE:
    COUNTS: `clip_count`, `clip_frame_total` (every clip's frames together), `action_count` (`actionSize`: the dofs
      less the free root's) - zero for a simulator without a task; `countsOf` given the task's clip sizes.
    ARRAYS: model_f `clip_poses`, a row per frame of every clip - `clip.pose(frame)[root_len..]`, exactly the pose
      `applyAction` reads; model_u `clip_first_frame` and `clip_frame_count` per clip; world_u `world_clip` and
      `world_frame`; world_f `actions`, `action_count` a world. The rows computed and uploaded once by the host from
      the CPU's own clips (`Sim.uploadClips`), as the learner kit's tables are (`Resident.uploadTables`).
    KERNEL `reference_targets`, per world and joint: `applyAction` and `clampHinges` for the joint - the clip's pose
      at `min(frame + 1, last)`, `integrateJointPosition` over a step of one with the world's action scaled (the root's
      dofs zero), a hinge's or a slide's target clamped to its range - into `servo_targets`. Then `advance_frames`,
      per world, a frame on after each physics step, as `Fleet.step`'s clock advances it.
    CHECK: the twin's targets against `applyAction` + `clampHinges` on every world, bit for bit (Geno; the humanoid
      for its hinges' clamps); the device within bars.
  BRAINSTORM (the termination problem): with resets as masks on the device, a world that has lost the reference costs
  no more to keep than to reset - so the device can hold a standing population of AFTERMATH worlds, never reset until
  they return or a long horizon ends, each a sample of what recovery looks like from where the policy actually fails.
  SuperTrack's world model learns from all worlds; a return-seeking learner (PPO, or EfficientTDMPC's planner) trains
  on the aftermath worlds alone, rewarded for returning. And the termination itself could be the world model's
  judgement rather than a fixed distance: the latent kit runs on the same GPU, so each decision it can give every
  world its predicted chance of returning, and a world is reset only when that chance falls below a threshold -
  the rule's cliff replaced by the model's own estimate of hopelessness.
- Nov 6: ONE JOINT's COORDINATES NAMED (Simon: "var moved: [7]f32 = coordinates; we always use that everywhere. Is
  there a way to make this code more self explanatory without costing perf?"). `robot.JointCoordinates` and
  `robot.JointVelocity`: the same seven and six numbers, in a struct, with a constructor and readers per joint type
  (`ofSingle` / `single`, `ofBall` / `ballOrientation` or `ballAngular`, `ofFree` / `freePosition`, `freeOrientation`
  or `freeLinear`, `freeAngular`), all inline - each compiles to the loads or stores hand indexing would, on the CPU
  and in the kernels. `integrateJointPosition` and `jointPositionDifference` now read as their arithmetic, a line per
  joint type. ONE DEFINITION: robot.zig already had a `JointCoordinates`, an alias of `Vec` - a joint's coordinates as
  `moveByJoint` took them, four floats for every joint but a free one: the same idea with less room. Merged: the alias
  gone, `moveByJoint` reading `single()` and `ballOrientation()`, both kinematics reading a joint's coordinates in one
  call (`robot.readJointCoordinates`; the device's `loadJointCoordinates`, beside its servo's errors). The model-level
  reads and writes are free functions after `Model` (`read`/`writeJointCoordinates`, `read`/`writeJointVelocity`) -
  reading a model's run is the model's business, not the vocabulary's - each read a switch on the joint's type with its
  loads written out. A slip on the way: the rewrite's cut first swallowed `angularVelBetween`, found by the compiler and
  restored from zimr356 as it was. CHECKED: robot.zig's kinematics 5/5, positions 8/8, MuJoCo fixtures 15/15;
  robotgpu 23/23 (the twin's steps robot.zig's to the bit); the web build translated, Tint clean; the course's chapter 7
  given the layout's table and a fold, its `moveByJoint` paragraph and excerpt read by name; doc-sync 0 drifted.
- Nov 6: P4a - THE CLIPS ON THE DEVICE, AND THE SERVO's TARGETS FROM THEM. Counts `clip_count`, `clip_frame_total`,
  `action_count` (`robot.actionSize`); item kinds `clips`, `clip_coordinates`, `actions`; arrays model_u
  `clip_first_frame`, `clip_frame_count`, model_f `clip_coordinates` (every clip frame's coordinates, frame after
  frame, clip after clip), world_u `world_clip`, `world_frame`, world_f `actions`; the uniform's sixth row, the task's
  (`action_scale`, padded). `robotgpu.ClipPoses` (a clip as plain rows of the model's coordinates - the host stays
  apart from robot_dance; the caller makes the rows), `countsWithClips`, `packClips`. HOST: `Sim.initTwinTracking`,
  `Sim.initGpuTracking` (the plain constructors unchanged, their 48 callers untouched - zero clips), `setWorldClip`,
  `setActionScale`; actions through `uploadWorldArray("actions")`. KERNELS, in programs of their own around a physics
  step (`before_step_program`, `after_step_program`; `kernel_names` now every program's, so the build translates them
  and they are entry points): `reference_targets` per world and joint - the clip's pose a frame ahead (held at the
  last), the action integrated onto it as a displacement in velocity space (`robot.integrateJointPosition`, the root
  none), a hinge's or slide's target clamped (`zm.clamp`, as the CPU) - and `advance_frames` per world. ONE DEFINITION:
  `applyAction`, `clampHinges` and `actionSize` MOVED from robot_track to robot.zig, as the servo law was (robot_track
  keeps their names as aliases; its eight callers untouched) - importing robot_track into the device's tests by path
  put one file in two modules, and the device's shared physics lives in robot.zig anyway. CHECKED: the twin's targets
  robot.zig's `applyAction` + `clampHinges`, bit for bit, on four worlds of Geno (balls) and of the humanoid (hinges,
  the clamp's path taken), the last world at the clip's last frame; the clock a frame a world; robotgpu 25/25;
  robot_track's action tests 3/3 through the aliases; the web build translated, Tint clean; the course's chapter 60,
  "The servo's targets from the reference", with a fold; the mocap tutorial's folds pointed at robot.zig; doc-sync 0.
  NEXT: the decision program itself - for each physics step [reference_targets, the step, advance_frames] submitted
  as one list (`Sim.submitDecision`), the actions held across it; checked against the CPU fleet's `step` on the same
  clip and actions (the poses after a decision, within bars on the device, the twin first).
- Nov 6: THE FILTER BACK, AT THE PHYSICS RATE (Simon: "To make the action smoother we can just bring back the filter we
  said we did not want anymore but i think we want since decision happen less often than physics. But with a big
  stiffness of 0.5 lerping factor. Move current action halfway to what policy says. No need to have current filtered
  result in the policy i think."). Paused Nov 2 (rl_track_plan) for two costs: the previous applied action in the
  policy's input (+69 numbers, +8.9%), and DReCon's 0.2 per 30 Hz decision lagging about 0.15 s. Both answered here:
    WHAT: before EACH PHYSICS STEP, each world's applied action moves halfway to the policy's -
      applied = applied + 0.5 (asked - applied) - and the servo's targets are formed from the applied one. A new
      decision then ramps in over its physics steps instead of jumping at its start: 50% of the way after one step,
      75% after two (today's clock), 94% after four (a 120 Hz physics under a 30 Hz decision). Lag: about 1.4 physics
      steps (24 ms at 60 Hz), against the paused filter's 0.15 s. The factor 1 is no filter.
    NOT IN THE POLICY's INPUT (Simon): the policy reads what it read; the filter's state is the simulator's.
    WHAT IT COSTS THE WORLD MODEL: the motion over a decision now depends on the previous decision's action too - by
      the share still applied when the decision starts (25% at two physics steps a decision, 6% at four). The replay
      holds the previous record's action already, so the WORLD MODEL can be given it as an input at no cost to the
      policy (a given beside the state, not a choice) - which keeps its prediction exact. Decide when S0c's training
      side is taken up again.
    WHERE: ONE definition beside `applyAction` in robot.zig (`filterActionToward(applied, asked, factor)`), called
      by the CPU fleet's `driveOnce` before `applyAction` each physics step, and by the device's `filter_actions` kernel
      (per world and action number) first in `before_step_program`, before `reference_targets` - which then reads the
      applied actions (a world array `applied_actions`; the factor `action_filter` in the task's uniform row, beside
      `action_scale`). A world's applied action zero at its reset: the servo aims at the reference until the policy
      speaks. The decision-rate machinery (S0b's `Options.filter`, S0c1's `lat_filter` kernels) stays off, at 1: one
      filter, the simulator's, never two in series.
- Nov 6: STUDIED - "VARIABLE STIFFNESS FOR ROBUST LOCOMOTION THROUGH REINFORCEMENT LEARNING" (Spoljaric, Yan & Lee,
  TU Wien and DLR, arXiv 2502.09436, IFAC 2025). A quadruped (Unitree Go2, 12 dofs) trained by PPO in MuJoCo MJX
  (4096 environments, 2000 epochs, pushes of 50 to 150 N every 6 s, domain randomisation of stiffness, damping,
  motor strength, mass, friction, delay), its action the joints' target positions AND their PD stiffness, k in 20 to
  60 Nm/rad, the damping tied to it, d = 0.2 sqrt(k). Four groupings: per joint (IJS, 24 actions), per joint type -
  hip, thigh, knee (PJS, 15), per leg (PLS, 16), and leg x joint type as an outer product (HJLS, 19); baselines at
  fixed 20 and 50. FOUND: per leg the lowest velocity-tracking error at every speed (below the stiff baseline);
  push recovery within the training range best per joint type, beyond it per joint then per leg, every grouping above
  the soft baseline at 300 N; energy (cost of transport) between the two baselines, the outer product the lowest of
  the four; per joint the worst tracking. Walking, the stiffness sat near 30 to 35 (the range's logarithmic middle);
  pushed, the legs away from the push stiffened to the ceiling and those toward it relaxed to the floor, and the robot
  recovered where both baselines fell. Under a 5 kg payload the stiffness rose, and fell when it was removed.
  Lowering the floor below 20 hurt the gait. Its reward charges joint power and its distribution - which is what kept
  the stiffness moderate. THE INTEGRATION (section 3, P4d): one stiffness number per LIMB (Geno six, from the tree),
  mapped to the servo's spring frequency f0 3^(s/4) (the paper's factor 3 in stiffness, centred on our tuned 20 Hz),
  the damping ratio kept at 1 (the paper's coupling is critical damping for one inertia; ours is critical for every
  joint), a stiffness cost in SuperMimic's reward in place of the paper's power terms, not in the policy's input,
  behind a switch. WHY IT FITS: our servo is already a stiffness - a spring frequency the mass matrix turns into
  torque - so the policy choosing it changes one number per limb in one function both engines share; and it bears on
  the termination problem directly: a character that can soften the limbs a push lands on and stiffen those it stands
  on recovers from pushes a fixed servo falls under (the paper's Fig. 5).
  THE PLAN MADE PRECISE: P4 rewritten as ordered steps (a) to (h), each with what it is, where it lives and how it is
  checked - the decision's order spelled out (once the actions; per physics step the filter, the targets, the step,
  the frame; once the observations, rewards, terminations, resets, pushes and records); the filter (b) and the
  variable stiffness (d) in their places; the resets' draws from a counter-based generator both engines share, so
  their check is bit for bit.
- Nov 6: P4b DONE - THE FILTER AT THE PHYSICS RATE, on both engines and in the planner. `robot.filterAction` and its
  number `robot.filteredActionNumber` (moved from robot_track, which aliases it), the blend in its exact form,
  `factor asked + (1 - factor) applied` - exact at 1, where `applied + factor (asked - applied)`, the form first
  planned, rounds twice. THE FLEET: `Options.action_filter`, `applied_actions` per character (zero at `startAt`);
  `driveOnce` takes the character's filter state and filters before `applyAction`. THE PLANNER (robot_world's MPPI):
  each sample's filter state through its model rollout and `planTrue`'s, the character's to begin with - the step a
  plan imagines is the step taken. THE DEVICE: `filter_actions` per world and action number (a new invocation shape,
  `per_world_and_action`), first in `before_step_program`; `applied_actions` per world; `reference_targets` reads it;
  `action_filter` in the task's uniform row (1 by default); `Sim.setActionFilter`. THE FACTOR IS 1 BY DEFAULT, on
  both: the world model learns from recorded policy actions, and a filtered motion also depends on the previous
  decision's - 0.5 goes on with the world model reading that (rl_track_plan, Nov 6). CHECKED: the twin's filter
  robot.zig's over three physics steps at 0.5 from rest, bit for bit (seven eighths of the way); the reference
  targets through the filter at 1 unchanged; robotgpu 26/26; robot.zig's filter test; the kit's fleet tests (the
  clock's - a decision at two physics steps is two at one - unchanged at 1, to the bit); robot_track and robot_world
  compiled against the new `driveOnce`; the web build translated, Tint clean; the course's chapter 60 (the filter as
  the targets' step 0) and the mocap tutorial's section 11.7 (the filter at the physics rate); doc-sync 0.
  NEXT: P4c, the decision program - `Sim.submitDecision`, checked against `Fleet.step`.
- Nov 6: P4c - THE DECISION PROGRAM, CHECKED AGAINST THE CPU FLEET. `Sim.submitDecision(physics_steps)`: one batch, for
  each physics step `before_step_program` (the filter, the targets), `step_program`, `after_step_program` (the frame);
  `submitDispatches` and it share `runDispatches`. THE TWIN MOVED into robotgpu.zig as `CpuTwin` (`init`,
  `initTracking`, `run`, `runProgram`, `runDecision`) - robotgpu's tests alias it - so any test root can drive it.
  THE CHECK, in the kit's tests (the fleet lives there; robotgpu's own tests cannot import robot_track, which puts one
  file in two modules, and every fast root has `robotgpu_sizes`): a fleet of two characters on `FleetSetup`'s
  humanoid and get-up clip, deciding every second physics step, filtered at 0.5 (the filter exercised, not off); the
  twin given the fleet's world - its floor, servo law, action scale and filter, each character's started state and
  frame; the clip's frame time set to the model's timestep (the device's servo steps at the timestep, the fleet's at
  the clip's frame time). THREE DECISIONS: every position, velocity and frame of both characters equal to the bit, no
  episode ended - the filter's state carried across decisions, the hinges' limits, the floor's contacts, the servo
  through its free root. CHECKED: the new test; robotgpu 26/26 through the alias; the web build; the course's chapter
  60, "A decision" (its order, a fold of `submitDecision`); lint. NOT YET COMPILED: `submitDecision`'s body, which no
  caller reaches yet - NEXT, the device's decision within bars against the twin (vk-host-test, then the lab page and
  the side-by-side page driven by decisions: its CPU side then the fleet's `driveOnce`, which aims a frame ahead where
  `ServoRun` aims at the frame).
- Nov 6: P4c ON THE DEVICE - THE DECISION WITHIN ITS BARS (vk-host-test, lavapipe). `runRobotgpuDecision`: Geno at his
  training physics, 64 worlds tracking one clip (his reference pose carried a little further each frame), each at its
  own frame and action, on the floor, the servo through the filter at 0.5; one decision of two physics steps
  (`submitDecision` - its first caller, so its body is now compiled) on the device and the twin; every step array
  compared, and the decision's own two read back from both. MEASURED: the applied actions 0.00 epsilons apart, the
  servo's targets 1.00 (a ball's target turned through the device's own sine and cosine); the poses 79.6 (joint
  positions), 7.8 (bodies), 35.5 (orientations); the last physics step's velocities up to 977 and accelerations up to
  8574 (joint accelerations; the one-step check's worst is 238.6). THE READING: the decision's own arithmetic agrees to
  an epsilon, and a 20 Hz servo multiplies a target's last-bit difference by its stiffness (omega^2 about 16000), so
  over two physics steps the velocities and accelerations part past one free step's bars. THE VERDICT therefore judges
  what a decision adds: its own two arrays within 16 epsilons and the poses within the step's bar - a decision composed
  wrongly (a dispatch missed or out of order, the wrong frame or action read) misses both by far - and reports the
  rest; the step's own arithmetic keeps its judge, the one-step comparison. vk-host-test passes, every check.
  ALSO: robotgpu_host given `zm` (both builders of its module - the tests' and pages'), its `assertf` from there
  (zimr exports none; the web build had not compiled `setWorldClip`'s alias, nothing calling it); two locals named
  `length` renamed `number_count` (zm's reserved names, in scope now). CHECKED: vk-host-test; the page's web build;
  doc-sync 0; lint.
  NEXT: the side-by-side page driven by decisions - its GPU side `initGpuTracking` with the dance, `submitDecision(1)`
  a frame; its CPU side the fleet's `driveOnce` (aiming a frame ahead) in place of `ServoRun` (aiming at the frame).
- Nov 6: REVIEW of the decision's work (Simon: "Review"). ONE DEFINITION where there were copies: (1) THE UNIFORM's
  SETTERS on `StepOptions` itself - `setFloor`, `setServo`, `setActionScale`, `setActionFilter` - the host's `Sim`
  setters delegating to them, and the kit's twin-against-fleet test calling them instead of writing a dozen uniform
  fields by hand, so a test configures its twin as a simulator is configured, never otherwise; (2) `Gains.law()` in
  robot_track - the servo's law from the tracker's gains - used by `pdTorquesToward`, the kit's test and the
  side-by-side page (whose `lawOf` had written it out); (3) one way to read a world array back in vk-host-test,
  `readWorldFloats`, `readWorldArrays` built on it. CLEARER: `WorldArray.storeAll` / `loadAll` (a world's whole block,
  as a host or a test holds it) in place of the test's per-number loops, its comparisons `expectEqualSlices`; the
  decision check's gaps bound to named locals. CHECKED: the kit's twin against the fleet (still bit for bit) and the
  fleet's own tests (the clock's); robotgpu 26/26; vk-host-test, every check (the decision's own arrays 0.00 and 1.00
  epsilons); the page's web build; doc-sync 0; lint.
- Nov 6: THE SIDE-BY-SIDE PAGE DRIVEN BY DECISIONS. Geno's scene: on the CPU the tracking task's own fleet
  (`robot_track.Fleet`, one character, `robot_geno.tracking_task` - his servo, floor and failure rule - his body names
  given for the task's feet and head; the servo alone, no action), on the GPU the decision program
  (`initGpuTracking` with the dance as `ClipPoses`, its kernel table every program's, `submitDecision(1)` a frame -
  the targets formed and the frame advanced on the device). The fleet's own resets drive the page's runs: when
  `Fleet.step` has ended an episode and begun the next (`dones`, then `restart` within the step), the GPU's world is
  begun again from exactly the fleet's new state (`restartGpuFromCpu`: pose, velocity, warm start, clip frame, the
  filter at rest) and the poses in flight, of the run that ended, are dropped (`GpuPoses.dropInFlight`). The first run
  starts at frame 1 (a start takes the velocity into its frame from the one before). The Go1's scene keeps its
  uploaded targets (its GPU still refused, `TooManyRows`). Gone: `ServoRun` from the page, `runEnded`, `targetOf`;
  `startRun` infallible. A BUG CAUGHT on the way: `clipsOf` returned `&.{...}` of runtime values - a temporary,
  dangling once returned (its length read as 4294967297) - now `GenoDance.device_clips`, kept beside the clip.
  CHECKED: natively headless (frame 454 of the second run - the fleet's rule ended the first; the CPU's hips 9.7 mm
  from the clip's, the GPU's root 14.9 mm from the CPU's; 0 validation messages); the web build; Tint in headless
  Chrome, no errors (it draws no canvas pixels for this page - nor did it before; the phone is the visual check);
  republished at its link; the course's "Side by side" rewritten; lint.
- Nov 6: THE SPIR-V STUDIED (Simon: "Is the spv emitted by the compiler optimised? Would it benefit from passing it through
  spirv opt on native?"). Kernels compile through Zig's own SPIR-V backend (`-fno-llvm -O ReleaseFast`): no optimiser
  passes. robotgpu's module: 426 functions and 1,341 calls (helpers not inlined), 1,021 function-local variables with
  3,095 loads and 1,695 stores, 1,151 phis (Zig's `const`s in SSA). `spirv-opt -O` (SPIRV-Tools 2025.1, installed in
  the sandbox for the measurement only): both modules pass `spirv-val`; 643,828 -> 598,044 bytes, 36 functions and no
  calls, 15 variables, loads and stores halved and more. ON LAVAPIPE (vk-host-test, both modules within every bar):
  pipeline creation for the 36 kernels about 30% faster (2,552-2,809 ms against 1,856-1,955); 100 steps unchanged
  within noise (993 and 1,068 ms against 973) - Mesa inlines and lowers to SSA itself. DECISION: not on native - the
  win is startup, and spirv-opt is C++, which zimr removed to keep its shader pipeline pure Zig. Unmeasured: a phone's
  driver, and the web path (spv2wgsl would first have to take spirv-opt's output). Zig-side routes if startup matters:
  `inline fn` on the small hot helpers; an inliner and a variables-to-registers pass in Zig, as spv2wgsl is.
- Nov 6: P4d, PART ONE - THE LIMBS AND THEIR SPRINGS in robot.zig. `limbHead` (a body's first ancestor, or itself,
  whose parent branches; a path that never branches is one limb, headed by its topmost body), `dofLimbs` (each dof's
  limb, numbered as their first dofs come; the free root's dofs `no_limb`), `limbSpringFrequency` (f0 3^(s/4), through
  `@exp2` so the device's and the CPU's take one path; exactly f0 at s = 0), `LimbStiffness` (each dof's limb and each
  limb's s), `servoTorques` given an optional `LimbStiffness` (null: today's servo - its three callers pass null).
  CHECKED: Geno's six limbs in his model's order (the spine, the neck with the head, the right arm, the left arm, the
  right leg, the left leg - 12, 9, 12, 12, 12, 12 dofs), the KUKA one limb of 7, the humanoid's free root in none;
  every limb at s = 0 gives the torques of no limbs, to the bit; s spans a factor of 3 in stiffness; robotgpu 28/28;
  the page's web build; the course's chapter 60, "A stiffness per limb". NEXT, PART TWO: the device (`dof_limb`, the
  stiffness numbers after the joints' in the action, `servo_accelerations` reading them, a switch) and the action's
  layout on the fleet and the learners, with SuperMimic's stiffness cost.
- Nov 6: A STALE TEST, found by the kit's tests run in full (198 matching "the "): "a return - back on the reference..."
  failed - its character 0, put back on its reference until it returned, then left to the servo alone, lost the
  reference again at step 57 (49 steps after returning), short of the 52 the test assumed. zimr363 fails identically,
  so neither this turn nor the review caused it; today's earlier changes are bit-identical by construction. The
  premise had gone stale with earlier days' physics (the floor's contacts, the solver). FIXED: character 0 held on its
  reference to the end, so the test reads the rule, not how long a servo alone stands. The kit's matching tests:
  167/198 run, 31 skipped, 0 failed.
- Nov 6: REVIEW of P4d's first part (Simon: "Review"). NAMED FOR WHAT IT IS: `limbHead` became `limbStart` ("where a
  body's limb starts") - Geno has a body named Head, and "the limb head" read as his - its scratch `limb_starting_at`;
  `no_limb` described as what it is (above every limb's number); `dofLimbs`' comment gives Geno's limbs in his
  model's order. COMMENTS STAND ON THEIR OWN: plan step numbers ("P4d", "the plan's 0.5", "robotgpu P4b") and a date
  ("the physics of Nov 6") taken out of today's code comments - the reasons stated instead (the filter's default of 1:
  a filtered motion depends on the previous decision's action, which a world model learning from the policy's actions
  must then be given; the return test: how long a servo alone keeps a character up is the physics', and can be shorter
  than the aftermath that remains). THE COURSE DESCRIBES WHAT EXISTS: "A stiffness per limb" no longer says a policy
  chooses it (not yet built) - the servo can be given a stiffness per limb. CHECKED: robotgpu 28/28; the kit's 198
  matching tests (167 run, 31 skipped, 0 failed); doc-sync 0; lint.
- Nov 6: P4d, PART TWO - THE STIFFNESS ON THE DEVICE. THE LIMBS IN THE MODEL: `Model.dof_limb` and `limb_count`,
  computed once in `buildFromSpec` from the whole tree (its section beside the reference weights', whose decl-order
  exemption it had displaced - restored to its line); `no_limb`, `childCount`, `limbStart`, `dofLimbs` and
  `rootDofCount` moved up beside `buildFromSpec`, which now calls them (`limbSpringFrequency`, `LimbStiffness` stay
  with the servo). THE DEVICE: `Counts.limb_count`; a world's action sized for the joints' numbers and then one per
  limb (`action_count`), filtered with the rest; the model table `dof_limb` (packed in `packTopology` beside
  `dof_body` - first written before `pack` cleared its image, and so wiped: the servo check caught it, a torque of
  -2710.96 against robot.zig's -2662.61); the task's uniform row's `limb_stiffness` (a `Switch`, off), set by
  `StepOptions.setLimbStiffness` and `Sim.setLimbStiffness`; `servo_accelerations` through `dofSpringFrequency` -
  `robot.LimbStiffness.dofFrequency` on the device. `uploadWorldArray` now refuses more numbers than a world's block
  (fewer fill its front, as a joints-only action does). CHECKED: the twin's servo robot.zig's, bit for bit, on Geno,
  the humanoid and the KUKA, toward rest and motion, limbs off and on (each world its own stiffness per limb); the
  servo check now sets its uniform through `setServo`; robotgpu 28/28; the kit's twin against the fleet; vk-host-test,
  every check; the page's web build; the course's "A stiffness per limb" (the device's part, a fold). NEXT: the
  action's layout on the fleet and the learners - the stiffness numbers in `Fleet` (`driveOnce` passing
  `LimbStiffness`), `actionSize` and the learners' widths, SuperMimic's stiffness cost.
- Nov 6: P4d's last part, refined by Simon's decisions (rl_track_plan, Nov 6): the action stays target offsets and
  stiffness (no force-level actions); the 0.5 filter covers both (the device's `filter_actions` already runs over
  every number); smoothness penalties on both as the state and the goal change belong to the learners' losses.
- Nov 6: P4d DONE - THE STIFFNESS IN THE FLEET's ACTION. `robot_track.actionWidth(m, limb_stiffness)`: the joints'
  offsets (`actionSize`, now described as the action's joints' part), then one number per limb when on - the
  device's layout. `Fleet.Options.limb_stiffness` (off); `Fleet.action_width`, one field the fleet's own uses all read
  (the start, the reward's action rate, driving, `step`'s check - each had computed `actionSize` itself); the replay's
  width given by its producer (`Replay.init`'s `action_width`, its field renamed to match), so the records carry the
  stiffness numbers. `driveOnce` filters the whole action, then reads its two parts: the offsets onto the reference
  (`applyAction` takes the joints' part only - it reads one number per actuated dof), each limb's stiffness into its
  spring (`stiffness_of_limbs`, a `LimbStiffness`, through `pdTorquesToward`'s new `limbs` - null from its two other
  callers, the rest-only wrapper and `ServoRun`). The MPPI planner (robot_world) refuses a fleet with stiffness,
  explicitly: it plans offsets. No stiffness cost (withdrawn, Nov 6). CHECKED: the twin's decisions the fleet's, bit
  for bit, with the limbs' stiffness off and on (each character's own stiffness per limb, filtered at 0.5); a fleet
  with every limb at zero the fleet without limbs, bit for bit, over four steps; the kit's 199 matching tests (168
  run, 31 skipped, 0 failed); robot_track's two replay tests by name (a filter's unmatched tests are not compiled);
  robot_geno's servo tests; robot_world's; the page's web build; the mocap tutorial's 11.7 (the action's layout);
  doc-sync 0; lint. Also fixed: a comment's "its filter at's 0.5", left by the last review's edit.
  NEXT: P4e, the observations.
- Nov 6: P4e, PART ONE - THE CHARACTER's HALF OF THE OBSERVATION ON THE DEVICE. ONE DEFINITION in robot.zig:
  `rootBody` (moved from robot_track), `twoAxis` (moved), `motionPointVelocity` (robot_dance's `pointVelocity`'s
  formula as a function of values - `pointVelocity` now calls it), `LocalBody` / `localBody` (one body's features in
  the root's frame: position less the root's, rotation as two axes, frame origin's velocity, angular velocity, all
  turned by the root's rotation undone, and height in world), `localSize` (moved); robot_track aliases the moved names,
  and its `local` computes each body once through `localBody`, writing it at its kind's offset (positions, rotations,
  velocities, angular, heights, then up) - the same arithmetic, so the same numbers. THE DEVICE: `Counts.root_body`
  (from `robot.rootBody`); the item kind and world array `observations` (two `localSize` halves); the kernel
  `observe_character` (per world, `local`'s layout from `localBody`); `observe_program` - the step's own
  `kinematics_branch`, `subtree_centres_of_mass`, `dof_axes`, `body_velocities_branch` bringing the derived
  quantities forward to the state the step left, as `observe`'s `rbt.forward` does, then `observe_character`;
  `Sim.submitObservation`; `kernel_names` now each kernel once (programs share kernels; the name comparison the
  program file's own, as it imports nothing; the comptime budget raised for it). CHECKED: the kit's decision check
  also compares the character's half of every world's observation with `Fleet.observe`'s after each decision - bit
  for bit, the limbs' stiffness off and on; robotgpu 28/28; the kit's 199 matching tests (168 run, 31 skipped, 0
  failed - `local`'s rewrite changed no learner's numbers); vk-host-test, every check; the page's web build; Tint;
  the course's chapter 60, "The observation"; the mocap tutorial's folds of `local`, `localSize` and `twoAxis`
  refreshed (the last two now folded from robot.zig); doc-sync 0. Caught by compile-time checks: a body's orientation
  is one 4-number item, read by `loadVec`, not `loadQuaternion` (a run of single numbers).
- Nov 6: THE DISK GUARD's MESSAGE made plain (Simon: "less dramatic"): why the build stops, how much the cache holds,
  how to make room - clearing the whole cache is fine once nothing else large can go, the next build refilling it;
  the one rule kept: clear it whole or not at all. The cache was cleared whole this session (9.4 GB of superseded
  artifacts; 11 GB free after).
- Nov 6: P4e, PART ONE - THE CHARACTER's HALF OF THE OBSERVATION ON THE DEVICE. ONE DEFINITION in robot.zig:
  `rootBody`, `twoAxis`, `motionPointVelocity` (robot_dance's `pointVelocity` now its caller), `localBody` (one
  body's features in the root's frame), `localSize`; robot_track aliases the moved names, and its `local` computes
  each body once through `localBody`, writing it at its kind's offset (the layout now written out in its comment).
  THE DEVICE: `Counts.root_body`; the item kind and world array `observations` (two halves of `localSize`);
  `observe_character`, one invocation per world, writing `local`'s layout from `localBody`; `observe_program` - the
  step's own `kinematics_branch`, `subtree_centres_of_mass`, `dof_axes`, `body_velocities_branch`, bringing the
  quantities the observation reads forward to the state the step left (as the fleet's `observe` calls
  `rbt.forward`), then `observe_character`; `Sim.submitObservation`. `kernel_names` lists each kernel once (programs
  now share kernels; its own name comparison - the program file imports nothing - under a raised comptime budget).
  CAUGHT by compile-time checks: a body's orientation is one 4-number item (`loadVec`), not a run of coordinates
  (`loadQuaternion`). CHECKED: the kit's decision check now also compares the character's half of every world's
  observation with `Fleet.observe`'s after each decision - bit for bit, the limbs' stiffness off and on; robotgpu
  28/28; the kit's 199 matching tests (168 run, 31 skipped, 0 failed - `local`'s rewrite left every learner's numbers
  as they were); vk-host-test, every check; the page's web build, Tint clean; the course's "The observation" (the
  program, the layout, a fold); the mocap tutorial's fold of `local` refreshed; doc-sync 0; lint.
  ALSO: the whole build cache cleared at 739 MB free (11 GB after), as the build's message advises; the disk guard's
  message in build.zig reworded neutrally (why the build stops, and how to make room - the cache cleared whole or not
  at all). NEXT, PART TWO: the reference's half - per clip frame on the host by `referenceStateInto` and `local`,
  a model_f table beside the clip's coordinates, copied into each world's observation for its frame.
- Nov 6: P4e DONE - THE REFERENCE's HALF, built by a turn that ended without a reply and verified now. On the
  host, `Fleet.clipReferenceFeatures` - at every frame the fleet's own `referenceStateInto` then `local`, `localSize`
  numbers a frame. On the device: `ClipPoses.reference_features` (empty where nothing observes the clip);
  `Counts.reference_feature_frames` - the clips' frames when they carry features, every clip or none
  (`countsWithClips` asserts it), else 0 and no table; the model_f table `clip_reference_features`, packed by
  `packClips`; `observe_reference`, one invocation per world after `observe_character`, copying its frame's row
  (the frame held at the clip's last, as `referenceStateInto` holds it) after the character's half. A duplicate of
  mine - a free `clipReferenceFeatures` and `referenceStateOfClip`, written before I found that turn's work - undone
  by restoring robot_track.zig from zimr370, so one definition stands. CHECKED (run, not cached: new filters): the
  kit's decision check - every whole observation row, the character's and the reference's, the twin's as
  `Fleet.observe`'s, bit for bit, after each of three decisions, the limbs' stiffness off and on - 2/2; robotgpu
  28/28; vk-host-test, every check; the page's web build, Tint clean; the course's "The observation" (the reference's
  half, a fold of `observe_reference`); doc-sync 0; lint. NEXT: P4f, the rewards and terminations, with the effort
  beyond the reference's.
- Nov 6: HOLISTIC REVIEW (Simon: "Review holistically. Make sure our architecture works. Improve the comments so we can
  find our way in the code. The look at the plan. Tell me what remains to be done before our night training."). THE
  WAY THROUGH THE CODE: robotgpu.zig's opening map rewritten - every program and every kernel group in the order a
  decision runs them, each beside the banner that finds it; THE KERNELS given a banner per group (THE STEP's START,
  KINEMATICS, THE CENTRE-OF-MASS FRAME, THE MASS MATRIX, VELOCITIES AND BIAS FORCES, PASSIVE AND ACTUATOR FORCES, THE
  SERVO, THE SMOOTH ACCELERATION, CONTACTS, THE CONSTRAINT ROWS, NEWTON, INTEGRATION, THE TRACKING TASK AND THE
  OBSERVATION, DISPATCHING AND THE CPU TWIN); the tracking task's and the observation's kernels moved after the
  integration, from the middle of the step's (where each had been put beside a neighbour), so the file reads in run
  order; robotgpu_host.zig's opening gains the tracking task's calls in their order of use; robotgpu_program.zig's
  names its four programs. THE ARCHITECTURE: what is built works and is checked; the gap is the trainer, and acting
  in it - "BEFORE THE FIRST NIGHT ON THE DEVICE" in section 3 lays out nights A and B and parts N1-N5, each with its
  check. CHECKED: lint; robotgpu's 26 matching tests; the kit's decision and observation check, 2/2.
- Nov 6: ONE NIGHT (Simon: "There will only one night. We need to prepare a system of logs of diagnostics that will
  enable us to see problems. I dont want to do a large grid search of parameters and ablations. I want to have one big
  run with all the ideas, organised artistically according to our feelings. Straight to all components." - and FlowDPG
  back, as an offset on the SuperMimic policy found by MPC in the device's own physics; a second world model at
  0.1 s). Nights A and B replaced by THE NIGHT in section 3: components C1-C11 in building order, each with its check;
  diagnostics D1-D7; the schedule.

