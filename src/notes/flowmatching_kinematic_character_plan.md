# The flow-matching kinematic character - the plan (v1 FINAL, Nov 22 2026)

STATUS: FINAL (Nov 22) - D0-D9, the sizes decided again after D8, and the smaller choices confirmed by Simon ("i agree.
Don't implement it just yet"). NOT IMPLEMENTED: stage F0 starts only when Simon says go. Written under claude.md's "MAKE
A PLAN" procedure (claude.md:146-164): study, brainstorm every option, pick, write it down here, then ask the open
decisions ONE AT A TIME (section 7) and revise after each. **Nothing is implemented and nothing will be until Simon says
go.** No build or test was run for this plan (Simon's rule): every
claim about zimr's code was read and is cited `file:line`; every claim about the paper was read from its text
(pdftotext of the PDF) and is cited by section, table or equation; every claim about the reference implementation is
cited `file:line` in `C:\Users\sclav\Downloads\ControlOperators-main\ControlOperators-main` ("the reference" below).
Named in claude.md's "Current plan" since Nov 22 (Simon), as one of the two current plans beside the mocap tracking
plan (`robotgpu_plan.md` v4) - still not started.

THE ASK (Simon, Nov 22): "Study deeply Control Operators paper [ControlOperators.pdf], especially the flowmatching part.
Also look at the implementation [ControlOperators-main]. The data is here: [lafan1-resolved-main]. Make a detailed plan
for implementing flowmatching within zimr, using the examples of geno-lab, using zimrnum and have everything on gpu. Ask
me questions when you are not sure about the design. Also look at what we do in the mocap tracking project. Our
ultimate goal will be to track in physics the output of the flowmatching controller. We will focus on navigation for
now. Make the flowmatchingkinematiccharacterplan."

WHAT WAS READ: the paper whole (Gou, van de Panne, Holden, "Control Operators for Interactive Character Animation", ACM
TOG 44(6) 231, SIGGRAPH Asia 2025 - sections 3-7, Algorithms 1-2, Tables 1-3, Figs 5, 14, 17's caption); the reference
whole (`train.py`, `networks.py`, `control_operators.py`, `control_encoder.py`, `controller.py`, `gameplay_input.py`,
`quat.py`, `README.md`); the dataset repository (`README.md`, its file list, `Geno_bind.bvh`'s hierarchy, the licence's
head); in zimr - `src/kit_mlp.zig` (the head, KitLayout, KitLayerKind, KitNetwork whole, ClippedAdam's settings, KitFlow
whole), `src/gpu/zn_mlp.zig` (the head, Act, mse_bwd, the joins, the flow kernels, hashed noise), the three sizes files
and the kernel list, `src/zimrnum.zig` (Activation, NormedDense, Mlp, the graph's op list), `src/zimrmath.zig`
(twoAxis, fromTwoAxis, rotateQuatByAngularVel), `src/robot_geno.zig` (the head, jointFromLocal, restForward, the copy),
`src/robot_dance.zig` (Clip, ZCLIP001, auditClip), `src/robot_track.zig` and `src/robot_track_resident.zig` (heads),
`src/codecs.zig` (bvh), `examples/geno_lab/geno_lab.zig` (head, state, drawing), `tools/geno_trainer.zig` (head),
`examples/geno_lab/recipes/first_run.zon`, `src/native_os.zig` (its functions), `src/runtime.zig` (gamepads),
`examples/geno_dance/geno_dance.zig` (head), `src/compute_host.zig` (its pipes), `build.zig` (the tools, the trainer's
build, the fast roots), `assets/lafan1/README.md`, the tracking plan as it then was
(`src/notes/archive/rl_track_plan_v6.md`, sections 0-1), `src/notes/archive/robotgpu_plan_v3.md` (section 4b's status,
4c's rules, the journal's tail), `src/notes/zn_mlp_web_twin_plan.md` (this file's shape),
claude.md (the rules this plan leans on).


## 0. The goal, stated so it can fail

A kinematic Geno walks and runs where a gamepad tells him - the paper's latent autoregressive flow-matching controller
(section 4.2), trained in zimr on LAFAN1-resolved with zimrnum's GPU kit, every training iteration and every frame of
the character on the GPU - and then a physics Geno tracks him.

  G1 THE LATENT SPACE. The autoencoder reproduces the training frames with a mean joint-position error under 1 cm - the
     paper's Fig. 6: "typically produces joint position errors of <1cm, even at the end of joint-chains" - the worst
     joint's mean named beside it; a held-out take's error reported. Seen to fail: the untrained autoencoder (tens of
     centimetres).
  G2 IT KEEPS GOING. Uncontrolled, 64 random starts x 4 noise seeds x 20 s: no rollout goes non-finite; the latent clip
     (section 3.9) acts on under 1% of the values; the paper's artefact measures (Table 1, section 6.3: foot sliding,
     jitteriness, toe and heel penetration and their frequencies) within 2x of the ground truth's own on the same data.
     Seen to fail: a flow after 100 iterations.
  G3 IT GOES WHERE IT IS TOLD. Velocity-facing: from standing, a command held for 3 s - 0, 1, 2 and 3 m/s, in 8
     directions relative to the facing, with and without a facing - and after the first second the root's mean speed
     within 0.3 m/s of the command, its direction within 20 degrees, the facing within 20 degrees when given.
     Trajectory: a held stick, the root's position at the 1 s point within 0.4 m of where the springs predicted it one
     second earlier. PROVISIONAL bars, set again from the first measurement (robotgpu_plan.md's R5: bars from
     measurements). Seen to fail: the uncontrolled flow given the same commands.
  G4 EVERYTHING ON THE GPU, AT 60 FPS. A frame - the controls, the control encoder, 4 Euler steps, the latent clip, the
     decoder, the root, the smoothing, the forward kinematics - is kit dispatches, with nothing read back inside the
     frame's chain but the drawn pose (a frame late); the kit's work of a frame measured under 4 ms on the RTX 5070; the
     CPU twin computes the same frame to float noise.
  G5 AS FAST AS POSSIBLE (Simon, Nov 22: "Let's focus on making it as fast as possible"). The scoreboard (section
     3.13): wall-clock on the RTX 5070 to USABLE (G3) and to GOOD (G2 and G3 at their bars), the reference's recipe as
     the baseline (D8) and every speed lever of 2.U an A/B against it. The bar: usable within 10 minutes - the paper's 10-15
     minutes on an RTX 3080 (section 4.2), on a faster card; the baseline's own times measured and written here first.
  G6 TRACKABLE (the hand-off, T1). A 60 s rollout under a scripted gamepad, copied onto the Geno ragdoll
     (`robot_geno.copyClip`), audits clean (`robot_dance.auditClip`: no joint past its range, no quaternion sign flip,
     no single-frame jump past 0.15 rad - assets/lafan1/README.md's criteria for the tracking set), its copy residual
     no worse than the tracking set's (7.3 mm at most, robot_geno.zig:2214-2221); then the tracker's score on it - a
     measurement until a tracker is trained for navigation.


## 1. What exists - verified

### 1.1 The paper: the parts this plan implements

THE POSE (section 4.1). p = [r_v r_a t t_v q q_a o]: the root's local linear and angular velocity, the pelvis's local
translation and velocity, every joint's local rotation as two axes, their angular velocities, and extras (the foot
contacts). Normalised: the mean subtracted, each KIND of variable divided by its average standard deviation, rotations
and angular velocities scaled by the length of the joint chain below them ("a much faster-to-train alternative to
including a forward kinematics loss"), and per-variable loss weights tuned so that every part contributes about equally
at the start.

THE AUTOENCODER (section 4.1). Encoder and decoder each one hidden layer of 512 ELU units; latent 128; 250k iterations at
a batch of 1024, learning rate 1e-3 decaying linearly to zero, about an hour. The latent then normalised by its mean and
"the maximum of the standard deviation across all latent dimensions".

THE FLOW (section 4.2, Algorithms 1-2). z_bar = (1 - t) z_tilde + t z_f, z_tilde ~ N(0, I) (eq. 22); the loss
|V(z_bar, z_hat_(f-1), C(v_f), t) - (z_f - z_tilde)|^2 (eq. 23), the Flow Network V and the Control Encoder C trained
together (RAdam in Algorithm 1); z_hat_(f-1) = z_(f-1) + sigma eps, sigma ~ U(0, sigma_max) - noise on the previous pose
in place of scheduled sampling, so training never runs inference; at run time S Euler steps from noise, t = s/S
(Algorithm 2), S = 4: Table 2 has quality saturating at 4 to 8 steps (S = 1: foot sliding 0.458, jitter 1.12; S = 4:
0.250, 0.368; S = 32 worse again). The network: an MLP of 8 hidden layers of 800, GELU, a LayerNorm before each internal
linear layer, skip connections concatenating the input to each hidden layer; 500k iterations at a batch of 4096, 1e-3
decaying linearly, sigma_max = 0.25; 5 to 20 hours on an RTX 3080. Distillation to one step optional (eq. 24).

WHAT THE RESULTS RAN WITH (section 5): foot locking and IK from the predicted contacts, and the pose update blended 0.25
decoded rotations with 0.75 the previous rotations integrated by the decoded angular velocities, "quite effective at
removing residual noise from the Flow Matching process".

THE ABLATIONS (section 6.3, Table 1, Fig. 14). Without LayerNorm: worse, still works. Without skip connections: "much
more noisy and unstable", trajectories "drift or explode". Without the latent space: unstable on their data (fingers,
a large pose); on 100STYLE (no fingers) "the use of the latent space was far less impactful".

THE CONTROL ENCODER (sections 3.2-3.4, 6.2). Operators as functions with parameters: typed operators (Location,
Direction, Velocity as themselves; Rotation as two axes; Scale as a log; Index divided by a maximum), Encode (a linear
layer and an activation), And (concatenation), Or (a linear layer per option into a fixed size, then the option's
one-hot), Set (multi-head self-attention plus a count), and derived ones - Optional = Or with the empty vector, FixedArray
= And over elements, Array and Dictionary over Set (eqs. 1-19). A hand-crafted control vector "performs similarly to the
Control Encoder Network, with perhaps slightly reduced motion quality" (section 6.2.1): the operators abstract the
design, they are not a quality lever.

THE LIMITS (section 7). Residual noise when the character stands still; with poor coverage the flow "can sporadically
get stuck in a situation where the character floats or remain stationary when provided with control inputs outside of
the training data, e.g., a trajectory which is moving too fast". And an idea for later: an uncontrolled distilled flow
used as a prior, with a control encoder that outputs the initial noise's mean and log-std, trained in minutes per
behaviour.

### 1.2 The reference implementation, and where it departs from the paper

It says itself that it "is not the exact implementation as in the paper or paper videos" (README.md:5). What it does:

  THE DATA. 39 takes tagged `all` and curated `locomotion` ranges over 11 of them (train.py:109-176), each take also
     mirrored: Left and Right swapped by name, positions x (-1, 1, 1), rotations x (1, 1, -1, -1) in its (w, x, y, z)
     order (train.py:243-257).
  THE ROOT. A "Simulation" bone: Spine2's world position on the floor, Savitzky-Golay filtered (31 frames, cubic,
     `interp` edges); the Hips' forward axis projected on the floor, renormalised, filtered (61, cubic), renormalised; the
     Hips made local to it (train.py:262-292).
  VELOCITIES. Central differences at 60 Hz with the two ends extrapolated; angular velocities from
     `q(t+1) * conj(q(t))` - an increment on the LEFT, so in the parent's frame (train.py:296-310), integrated the same
     way at run time (controller.py:1140).
  CONTACTS. A toe (LeftToeBase, RightToeBase) moving under 0.15 m/s, then a median filter of 6 frames (train.py:314-337).
  THE POSE VECTOR. [root velocity in its own frame 3 | root angular velocity in its own frame 3 | hips' local position 3 |
     two axes of every bone but the root | hips' local velocity 3 | angular velocities of every bone but the root |
     2 contacts] (train.py:581-598) - 689 numbers with Geno's 75 joints. Each kind divided by its mean standard
     deviation (604-612); loss weights: the per-bone weights of Holden's joint-error-propagation table (30-107) times
     the bone count less one for rotations and angular velocities, 1 elsewhere (615-626); `Xdist`, each normalised
     dimension's own standard deviation (632).
  THE AUTOENCODER. MLP(689 -> 512 ELU -> 256) and back - latent 256, not the paper's 128 (696-702); the decoder's output
     multiplied by Xdist; trained on windows of two consecutive frames (684-689) with 3 x L1 weighted + 15 x L1 of the
     pair's difference + 0.01 |Z| + 0.1 |Z1 - Z0| (735-744); AdamW with AMSGrad (torch's default weight decay, 0.01),
     1e-3 decaying linearly, batch 2048, 500k iterations - the defaults of `--niterations` and `--batch_size`, shared by
     both networks (474-478, 720-725).
  THE LATENT. Normalised by its mean and the MEAN standard deviation over dimensions, not the maximum; then Zdist (each
     dimension's standard deviation), Zmin and Zmax kept (811-822).
  THE FLOW NETWORK. `SkipCatMLP`, 10 x 1024 - not 8 x 800 (854): a first Linear and GELU, then per layer LayerNorm ->
     concatenate the input -> Linear -> GELU, and the output a Linear over [h | input] with no LayerNorm (networks.py:56-89).
     Its input [z_bar | z_hat_prev | c | t], t a single column.
  THE NOISE AND THE SCALE. The source is Zdist x N(0, I), not N(0, I), and the network's output is multiplied by Zdist -
     its notes say both work better (866-881, 927, 940).
  THE PREVIOUS POSE. z_prev + Zdist x sigma_max x U(0, 1) x eps per row, sigma_max = 0.5, not 0.25 (479, 933).
  THE STEP. mean((Zdist V - (z_f - z_tilde))^2), AdamW with AMSGrad, batch 2048, 500k iterations (906-947).
  INFERENCE. S = 4, then the result clipped to [Zmin, Zmax] (controller.py:998-1006, train.py:983).
  THE CONTROL ENCODER. `UberControlEncoder` = Or { uncontrolled: Null, velocity_facing: And { velocity: Velocity,
     direction: Optional(Direction) }, trajectory: FixedArray(And { location: Location, direction: Direction }, 3) }
     (control_encoder.py:87-101). Or is a Linear per option into 256, then the option's one-hot (control_operators.py:79-112):
     259 numbers out, no activation anywhere.
  TRAINING CONTROLS (control_encoder.py:103-192). Uncontrolled on every frame; trajectory - the root's position and facing
     20, 40 and 60 frames ahead, in the root frame of the frame being generated - on the locomotion ranges; velocity_facing -
     the root's velocity and facing 15 frames (0.25 s) ahead, once with and once without the facing - on the locomotion
     ranges. The lists concatenated and drawn from uniformly (train.py:891, 918).
  RUNTIME CONTROLS (control_encoder.py:194-317, gameplay_input.py:36-122). The left stick, its magnitude squared past a
     dead zone, times 3 m/s (x1.5 under the right trigger), in the camera's frame; trajectory: springs with half-lives of
     0.2 s from the root's position, velocity and acceleration, and its rotation and angular velocity, predict the root at
     1/3, 2/3 and 1 s; velocity_facing: the desired velocity and the right stick's facing, both in the root's frame.
  THE FRAME (controller.py:1124-1158). Encode the control, 4 Euler steps, clip; decode; integrate the root from its local
     velocities (1028-1032); blend with the previous pose integrated by its velocities, alpha = 0.75 (1082, 1138-1140); foot
     locking and two-bone IK (529-781); draw.
  ITS NOTES ON NETWORKS (networks.py:4-17): a ResNet-style `SkipMLP` "generally works just as well" as the concatenating
     skips - "the most important aspect is that there is some mechanism for propagation of the input to deeper layers";
     a very deep network without LayerNorm can be unstable.

### 1.3 The data on disk

* The folder named in the ask is the dataset's REPOSITORY, not its motion: `Geno.fbx`/`.mb`, `Geno_bind` and
  `Geno_stance` (.bvh, .fbx), `subjects/subject1-5.fbx` (MotionBuilder actor and character set-ups, as its README says),
  the export scripts, `mirror.py`, and the licence - CC BY-NC-ND 4.0, research only. Its README points to a download for
  the motion.
* **THE MOTION IS ALREADY ON THIS MACHINE**: `C:\Users\sclav\Downloads\Flomo2\Flomo2\data\lafan1_bvh` holds all 77
  takes, 5.3 GB of BVH, 60 fps, Geno's 75 joints with six channels each (`walk1_subject1.bvh`: 15,679 frames, as
  train.py:138 has it); `C:\dev\tests202601\Flomo\data\lafan\bvh` lists the same 77.
* The reference's `all` set: 39 takes, about 542,000 frames (2.5 hours), 1.09 million mirrored. Its `locomotion` ranges:
  about 156,000 frames (43 minutes), 312,000 mirrored. (Sums of train.py:109-176.)
* zimr's own LAFAN1 (assets/lafan1/README.md): the tracking set - 4 clips of subject 2, 1,200 frames each, fingers
  stripped - and three of subject 5 on LAFAN's own skeleton from the motion-matching database.

### 1.4 zimr: the GPU kit - and a flow already on it

* THE KIT: five flat f32 buffers - params, grads, acts, dacts, loss - every network placed by offsets
  (kit_mlp.zig:14-29); one kernel module, `gpu/zn_mlp.zig`, compiled to SPIR-V for Vulkan and to WGSL through spv2wgsl,
  with a CPU twin that runs the same kernel source on the host (zn_mlp.zig:1-19, kit_mlp.zig:1-2); pipes on a device,
  the twin, workers or a measuring stub (compute_host.zig:884, 895, 907, 1026). Examples already open a kit pipe on the
  app's own device (`z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, ...)`, geno_train.zig:215, geno_ppo.zig:403).
* KitNetwork's layers are three kinds: dense with a fused tanh or relu; NormedDense - linear -> LayerNorm -> Mish, SiLU or
  SimNorm, TD-MPC2's order; plain (kit_mlp.zig:285-321). **No GELU and no ELU** (zn_mlp.zig:68: `Act = linear, tanh,
  relu`). **No skip**: every layer after the first reads the one before's outputs, packed (kit_mlp.zig:951-953).
* **KitFlow** - zimrrl's FlowPolicy on the kit, the tracker's flow actor (`.actor = .flow` in
  examples/geno_lab/recipes/first_run.zon): wide rows [condition | point | time features], the time as sine-cosine pairs
  of pi 2^p t, three pairs by default (kit_mlp.zig:1938-2019); the sampler - K Euler steps, each on a block of its own
  (2080-2125); the trainer - each row's straight path (`flow_path_points`), the velocity there, `mse_bwd` against
  a - x_0, and back through the network (2171-2261). It is exactly eq. 22-23 and Algorithm 2, over a KitNetwork.
* KERNELS THIS PLAN REUSES: `norm_fwd` (zn_mlp.zig:1357), `dense_fwd_tiled` (916) and its two backwards, `act_bwd`
  (514), `mse_bwd` (943 - one scalar weight, no per-column weights), the joins `place_columns` and `take_columns` (2978,
  2994) and `lat_take`, which adds (3132), `add_block` (3029), `copy_columns` (4407), `hashed_noise` (4392: normal noise
  into strided columns under a seed), `hashed_uniforms` (4438), `flow_time_features` (4333), `flow_euler_step` (4353),
  `flow_path_points` (4370).
* THE OPTIMISER: ClippedAdam - Adam behind a global gradient-norm clip, no weight decay (kit_mlp.zig:1704-1716); Muon has
  the decoupled decay (zn_mlp.zig:1228-1239).
* SIZES ARE PER PROGRAM: the pages' - acts 2^21, dacts 2^20, params 2^18, with the CPU twin (gpu/zn_mlp_sizes.zig); the
  headless trainer's - 2^29, 2^27, 2^23, no twin (gpu/zn_mlp_sizes_trainer.zig), copied in by build.zig (2446-2570).
* DEVICE CHECKS: vk-host-test's kit check runs the kernels on a device against the twin (claude.md, "First thing each
  session", step 3); new kernels need rows there and in the WGSL corpus (`tests/fixtures/wgsl_corpus.txt`).

### 1.5 zimr: zimrnum's CPU side - the reference for every kernel

* The graph has what both networks need: `elu` (zimrnum.zig:12217), `gelu` - the tanh form, PyTorch's
  `approximate="tanh"` (12282, 6093-6095) where the reference's `nn.GELU()` is the erf form, `layerNormRows` (13123),
  `concat` (13216), `matmul`, `add`, `relu`, `scale`, `mseLoss` (13384). No `abs`: an L1 is relu(x) + relu(-x).
* `Mlp` is TD-MPC2's shape, NormedDense hidden layers (16692-16777); `Activation` has no gelu or elu (7105-7115).
* zm's two axes are the matrix's first two COLUMNS, [x0 x1 x2 y0 y1 y2] (zimrmath.zig:7658, 7695); the reference
  stores the same six numbers row by row (quat.py:42-55), and keeps the quaternion's scalar first where zm keeps it last.
  This plan uses zm's conventions throughout and never exchanges tensors with the reference, so the two orders never
  meet. zm's `rotateQuatByAngularVel` increments on the RIGHT, in the body's frame (zimrmath.zig:7632) - the reference's
  joint angular velocities increment on the LEFT (1.2): the character's code does what the reference does, written out.

### 1.6 zimr: Geno, clips and the tracker - where the character will be handed over

* The LaFAN resolved captures' 35 non-finger joints ARE Geno's, and the Geno ragdoll is built from Geno's own skeleton,
  so a capture is copied, not retargeted: `jointFromLocal(rest_local, pose_local) = conj(rest_local) * pose_local`
  (robot_geno.zig:1-41, 281-294); `copyClip` turns a BVH capture into a `dance.Clip` (robot_geno.zig:2214-2222) - a qpos
  per frame, baked as ZCLIP001 (robot_dance.zig:131-157) - and `auditClip` checks one (robot_dance.zig:455).
* A tracker compares the simulated character with the clip's kinematic one, both as a `State` (robot_track.zig:1-36).
  The tracker's goal and gates, its simulator and the SuperMimic foundation are robotgpu_plan.md's (v4, Nov 22: the
  foundation's S0-S3 written, its first check started; the tracking plan and robotgpu v3 are in archive/).
* The tracking set holds a minute of dance, get-up, walk and run (assets/lafan1/README.md). Nothing has been trained for
  navigation, and nothing tracks a reference generated live.

### 1.7 zimr: the lab and the trainer this plan follows

* geno_lab lists run folders, plays a run's newest policy on Geno with the reference beside him, draws the learning
  curves, follows the newest policy while a trainer runs, and starts, resumes and stops trainers (geno_lab.zig:1-22).
* geno_trainer: a run is a folder - `run.zon`, the newest weights, checkpoints, `log.csv`, `status.zon`, `stop` - every
  file written whole to `<name>.new` and renamed over the old (geno_trainer.zig:1-48), through `native_os.writeWhole`,
  `readWhole`, `listFolder`, `makeFolder` and `ChildProgram` (native_os.zig:367-600). Recipes live in
  `examples/geno_lab/recipes/*.zon`, each copied into a new folder as its `run.zon`.

### 1.8 zimr: input, drawing, files

* Gamepads: raylib's API - `isGamepadAvailable`, `getGamepadAxisMovement`, the buttons (runtime.zig:2418-2590), native
  and in the browser.
* A skinned Geno: `loadFbxModel` and `draw3d.poseSkinMatrices` / `skinMeshCpu` (geno_dance.zig:1-24); the ragdoll as
  capsules (`drawRobot`, geno_lab.zig:690).
* BVH read and written: `codecs.bvh.parse` and `encode` (codecs.zig:16577, 16687, 16926); `bvh-trim` drops the fingers by
  name (assets/lafan1/README.md).

### 1.9 What does not exist

A motion database built from many takes; Savitzky-Golay and median filters; the simulation bone; contact labels. GELU and
ELU on the kit; a network with skips on the kit; L1 losses; a per-column loss weight. Control operators. A batch drawn on
the GPU from resident tables of frames and controls (`lat_gather` is the tracker's own). A character that lives on the
GPU from frame to frame. The flow's trainer, its run folder, its lab.


## 2. The brainstorm - every axis, every option, the pick and why

### 2.A Where the work lives (D1)

  (a) ITS OWN FILES, GENO_LAB'S CONVENTIONS: a library (`src/character_flow.zig`, `src/control_operators.zig`,
      `src/character_flow_kit.zig`), a trainer (`tools/flow_trainer.zig`) and a lab (`examples/flow_lab`) - run folders,
      whole-file writes, the stop file, the curves, "follow the newest", recipes - written the way geno_lab and
      geno_trainer write them, sharing `native_os`'s pieces, not their code.
  (b) INSIDE GENO_LAB AND GENO_TRAINER: a third learner beside PPO and SuperTrack (`.learner = .kinematic_flow`) and a view
      of geno_lab. One lab, one trainer, one run list - but geno_trainer is 3,554 lines and robot_lab 8,492 of the
      tracker's state, and two projects moving at once would share every file.
  (c) (a) now, and geno_lab takes the flow character as its reference at T3 - the day the two must be one program.
  PICK (c). The character is a different product from a tracker - no physics, no policy, a gamepad - and the point where
  they meet (T3) is a reference source in geno_lab, which the library makes a few calls. DECIDED (c), Nov 22.

### 2.B The data (D2)

  (a) THE REFERENCE'S SPLIT: uncontrolled on its 39 `all` takes, the navigation controls on its curated `locomotion`
      ranges, every take mirrored - 1.09 million frames.
  (b) LOCOMOTION ONLY, for every mode: 312,000 frames - a third of the memory and the autoencoder's work; everything it
      makes is walking, running or standing, all of which a tracker will meet; less variety for the latent space and
      for uncontrolled play.
  (c) EVERY WALK, RUN AND SPRINT TAKE WHOLE (19 takes): more locomotion, but the reference left parts out on purpose -
      walk2 and walk4 whole, most of walk3, part of run2_subject4 - and says why only by leaving them out.
  (d) ALL 77 TAKES: falls, get-ups, obstacles, pushes - nothing navigation asks for, and much the tracker cannot follow.
  PICK (a): it is the behaviour to reproduce, the controls only ever see the curated locomotion, the variety costs no
  code, and it fits (section 3.12). The recipe's `.set` field makes (b) a one-word change. DECIDED (a), Nov 22.

### 2.C Fingers - and the end joints (smaller, picked)

Drop the 40 finger joints: 35 joints, a pose of 329 numbers (section 3.3), as the tracking set and the ragdoll have it
(robot_geno.zig:5-9). The paper found the latent space mattered most WITH fingers (section 6.3.2) - nothing we use is
lost. The end joints (HeadEnd, the ArmEnds, LegEnds, ToeBaseEnds) stay: they are robot_geno's 35.

### 2.D The pose representation (smaller, picked)

The reference's p, exactly, over the 35 joints. Rejected: joint positions (Learned Motion Matching's features), the
tracker's `State` (bodies' positions and velocities), global rotations - the reference's was measured by its authors on
this data, and the decoder's local rotations go to the ragdoll's qpos exactly (`jointFromLocal`), so the tracker needs
nothing else.

### 2.E The latent space (D3)

  (a) THE AUTOENCODER, LATENT 128 - the paper's size; our pose (329) is under half of the reference's (689).
  (b) LATENT 256 - the reference's, on 689 numbers with fingers; the flow's input and first layer grow by a third.
  (c) NO AUTOENCODER: the flow in normalised pose space - the paper's ablation: unstable with fingers, close without.
  PICK (a), and (b) if G1 fails at 128. Beyond quality, the ENCODER is what T5 needs: a simulated pose re-encoded into the
  flow's latent, so that the kinematic character can come back to where the physical one is. DECIDED (a), Nov 22.

### 2.F The flow network on the kit (D4)

  (a) THE REFERENCE'S SKIPCATMLP, EXACTLY, from the kit's kernels plus GELU's two: layer 0 dense -> GELU; each later
      layer LayerNorm (`norm_fwd`) -> `place_columns` into a wide row [n | x] -> dense over it -> GELU; the output a dense
      over [h | x]. Its backward: the wide gradient split by `take_columns` and `lat_take`, the input's share summed over
      every layer (section 3.5).
  (b) THE KIT'S NORMEDDENSE (linear -> LayerNorm -> SiLU) WITH THE CONCATENATING SKIP ADDED: fewer new kernels; a
      different network from the one the paper measured - the norm on the other side of the activation.
  (c) RESIDUAL, the reference's `SkipMLP` (h <- h + ELU(W h + b), no LayerNorm): its note says "just as well"; an add
      per layer; untested by the paper.
  (d) THE PLAIN KIT MLP, no skip: no new code - and Table 1's worst row.
  PICK (a). Port what was measured, then ablate from it (claude.md: "check whether the reference already solved it").
  SIZE: the paper's 8 x 800 by default (8.0 million parameters at latent 128, section 3.12); the reference's 10 x 1024 a
  recipe; 4 x 512 a recipe for quick turns. DECIDED (a) at 8 x 800, Nov 22 - "do what the paper does", and make it
  learn as fast as possible (2.U). THEN, once D8 made the reference the baseline, THE SIZE DECIDED AGAIN (2.V, "THE
  SIZES"): the reference's 10 x 1024 at latent 128 - 14.9 million multiply-adds a row; 8 x 800 the first A/B of S11,
  4 x 512 for quick turns.

### 2.G The noise, the velocity's scale - and whitened latents (D8: the baseline)

D8 (b) makes this the BASELINE; the paper's unit Gaussian in the normalised latent is the A/B (S10, reversed). The
mechanism - one switch, whitened or not, with the per-column weights - is the same either way.

The reference's choice (its notes: better), done the kit's way: the flow lives in WHITENED latents w = z / Zdist, so its
source noise is plain N(0, I), its velocity needs no scale, and its loss is weighted per column by Zdist^2 - which is the
reference's loss to the letter: mean_j (Zdist_j V_j - (z_j - z_tilde_j))^2 = mean_j Zdist_j^2 (V_j - (w_j - w_tilde_j))^2.
The previous pose's noise becomes sigma_max U(0, 1) eps in w, and the clip [Zmin, Zmax] becomes [Zmin, Zmax] / Zdist.
Costs: one mode of `mse_bwd` (a per-column weight read from acts). KitFlow's sampler and `flow_path_points` are untouched.

### 2.H Time (smaller, picked)

THE REFERENCE's single column t (D8 (b)): a KitFlow option, `time_input = .column | .features`, the column written by
`flow_time_features` in a mode of its own. KitFlow's sine-cosine features (three pairs: sin and cos of pi t, 2 pi t,
4 pi t - existing and tested, t in [0, 1) recoverable from the first pair alone) are the A/B.

### 2.I The optimiser (smaller, picked)

THE REFERENCE's, AdamW with AMSGrad (D8 (b)): ClippedAdam gains two settings - a decoupled weight decay (w <- w (1 -
rate x decay) before the step, as Muon's kernel already does it), 0.01 as torch's AdamW, and AMSGrad (the denominator
from the running MAXIMUM of the second moment, torch's `max_exp_avg_sq`, kept in acts: one float per parameter, 15.5
million at the reference's network); the clip set so high it never acts (the reference clips nothing); 1e-3 decaying
linearly to zero. RAdam (the paper's) not built: its correction matters in the first steps, where a warm-up (S8) does the
same work. Muon is S5 (2.U).

### 2.J The control encoder (D5)

  (a) CONTROL OPERATORS AS DATA: a small schema - Null, Location, Direction, Velocity, Rotation, Index, And, Or, Optional,
      FixedArray, Encode - compiled into a FEATURIZER (a fixed-width row per control: every option's inputs, zero when the
      option is not taken, and the one-hots) and a stack of kit layers EQUAL to the operators: an Or over a featurized
      row is exactly one dense layer over [the options' inputs | the one-hot], its options' weight matrices and biases the
      blocks of one matrix - an option not taken reads zeros, and its bias is the one-hot's row - so the parameters are
      the reference's own, not a reparametrisation. Nesting (the Optional inside velocity_facing) is one more layer, its
      output placed into the next layer's wide row. The navigation schema is the reference's Uber encoder.
  (b) A HAND-WRITTEN VECTOR for navigation: the paper's section 6.2.1 says the same quality. It is what (a) compiles to
      for this schema, minus the per-option layers.
  (c) EVERY OPERATOR NOW, Set's attention and String's CLIP among them: new kernels nothing here needs yet.
  PICK (a): little more than (b), and the next behaviour - move to target (eq. 20), a style, a pick-up - is a schema, not
  code. DECIDED (a), Nov 22.

### 2.K The training controls (smaller, picked)

Computed once on the CPU from the database into two resident tables: per frame the raw future quantities (24 numbers:
three future locations and directions, the future velocity and direction) with their validity, and the SAMPLE LIST - the
reference's concatenated lists as (frame, kind) pairs, about 2.0 million (uncontrolled 54%, trajectory 15%, velocity
15.5%, velocity with facing 15.5%). A GPU kernel builds each batch row's featurized control from them.

### 2.L The batches (smaller, picked)

Drawn on the GPU: `hashed_uniforms` under the step's seed -> positions in the sample list -> a gather kernel -> each row's
latent pair and featurized control. Nothing uploaded per step but the parameter block. (Drawn on the CPU and uploaded,
it would be about 0.6 million floats a step.)

### 2.M The runtime - decided by the ask: everything on the GPU

  (a) EVERY FRAME ON THE KIT: the controls from the gamepad's world-space command and the GPU-held root (the springs in a
      kernel), the encoder, the sampler, the clip, the decoder, the root's integration, the smoothing, the forward
      kinematics; the CPU reads back the posed skeleton to draw it, a frame late, and never waits on it. PICKED.
  (b) THE SAMPLER ON THE GPU, THE REST ON THE CPU: either the controls see a root a frame old, or each frame waits on a
      readback.
  (c) THE CPU ALONE: about 32 million multiply-adds a frame - beyond a frame in wasm, and not the ask.

### 2.N What the lab draws (smaller, picked)

Geno skinned, geno_dance's path; from T1 a toggle for the ragdoll's capsules posed by the copy - exactly what the
tracker will be asked to follow.

### 2.O After the decoder (smaller, picked)

The reference's smoothing (alpha 0.75) in the frame's program. Foot locking and IK a late optional stage (F12), for the
eye only: the physics will own the feet.

### 2.P Verification (D6)

  (a) A PYTHON ORACLE: a script in `scripts/` that runs the reference's own data functions - the database's processing,
      the pose vector, the training controls, from its `quat.py`, `bvh.py` and `train.py`, called, not copied - on two
      short takes, writing a small fixture the Zig tests compare with. Needs numpy and scipy on the Windows machine (no
      torch: the oracle stops before the networks). The house allows exactly this: an independent implementation
      producing reference values (claude.md: "MUST STAY NON-ZIG").
  (b) ZIG-ONLY CHECKS against facts the code did not produce: a Savitzky-Golay filter reproduces any cubic exactly,
      edges included; mirroring twice is the identity; forward kinematics of the stored data equals the BVH's own; the
      controls of a root moving on a known path.
  (c) BOTH.
  PICK (c): the oracle catches a MISREADING of the reference - an axis, an edge mode, a lookahead counted from the wrong
  frame - which no property can; the properties catch a broken implementation of a right reading. DECIDED (c), Nov 22.

### 2.Q Buffer sizes (smaller, picked)

A sizes file for the flow's trainer - acts 2^29, dacts 2^27, params 2^24 (the 10 x 1024 flow, its encoder and the
autoencoder are 15.5 million floats, past 2^23, inside 2^24's 16.8) - and one for the native lab - params 2^24, acts 2^22, dacts 2^16, no
twin. The web page's sizes are F13's decision.

### 2.R The hand-off to physics, in order (D7)

  (a) OFFLINE FIRST: T1 a rollout baked as BVH and clip, tracked by whatever tracker exists, in geno_lab; T2 training data
      for the tracker from flow rollouts; T3 live in geno_lab; T4 on the device, a flow per world; T5 the loop closed.
  (b) LIVE FIRST: T3 straight away - the first time the tracker meets the character is in real time, with nothing
      measured about the clip it is following.
  PICK (a): each step measures what the next one needs. DECIDED (a), Nov 22.

### 2.S Rejected, or later - listed so that the choice is visible

* Learned Motion Matching (the paper's other controller, section 4.3): a matching function per behaviour, an answer every
  8 frames (section 7).
* Diffusion (DDPM, DDIM): more steps for the same quality (section 2.2).
* A SEGMENT FLOW - a flow over 8 frames at a time: a lookahead for the tracker and an eighth of the cost per frame - but not
  the measured method. A follow-up once the single-frame flow works (section 6).
* One-step distillation (eq. 24), shortcut models: follow-ups.
* The uncontrolled prior with encoders that condition its noise (section 7): a follow-up - new behaviours in minutes.

### 2.T Smaller choices (picked, listed for confirmation at the end)

* The hyper-parameters are THE REFERENCE's (D8 (b)): the autoencoder 500k at a batch of 2,048 pairs (or to its gate,
  S9), the flow 500k at 2,048, sigma_max 0.5, S = 4, 1e-3 decaying linearly to zero, checkpoints every 10k iterations;
  the paper's (the autoencoder 250k at 1,024, the flow at 4,096, sigma_max 0.25) as recipes.
* The simulation bone, the velocities, the contacts and the mirroring exactly as the reference computes them (1.2).
* Y up, metres, the facing along +z - the reference's frame, and claude.md's "Y-UP, CONVERTED AT LOAD"; the ragdoll's
  z up only inside the copy (robot_geno's `Copier`).
* Joint angular velocities in the parent's frame, incremented on the left, as the reference (1.2) - written out, not
  `rotateQuatByAngularVel`.
* The latent's scale is the reference's MEAN standard deviation (D8 (b)); the paper's maximum a switch.
* f32 throughout. Indices held in f32 tables are exact below 2^24 (16.7 million): the largest is 1.09 million.
* Names: `character_flow*`, `control_operators`, `flow_db`, `flow_trainer`, `flow_lab`; the files ZFMDB001 (the
  database) and ZFLOW001 (a trained character).
* Run folders outside the repository (geno_trainer's rule): no weights trained on LAFAN1 (CC BY-NC-ND) are committed.

### 2.U Speed - every lever, and how each is judged (D9; Simon, Nov 22: "as fast as possible")

THE MEASURE is wall-clock on the RTX 5070 to USABLE (G3) and to GOOD (G2 and G3 at their bars) - the scoreboard, 3.13 -
with the reference's recipe as the baseline (D8) and each lever an A/B against it, both wired behind one flag (claude.md: "wire
both behind one flag and let the harness run both every time"). A run's time is steps x time per step; the levers split
the same way.

WHAT IS KNOWN OF THE TIME PER STEP. The kit's dense layers became one register-blocked product on Nov 20 (64 x 64 a
workgroup, 8 x 8 sums a lane, zn_mlp.zig:566-617; robotgpu v3's I23), after the night had measured the tiled form
at "about 0.25 and 0.5 TFLOPS, 1-2% of the 5070's f32 peak" (robotgpu_plan_v3.md:2443-2444); the blocked form's own rate
at the tracker's sizes is in the Nov 20 A/B (a dense forward 0.207 ms a dispatch, a weights' gradient 0.698 ms -
robotgpu_plan_v3.md:9600-9603), not yet as a share of the peak, and never at the flow's shapes. Not yet built: double
buffering, a split of the inner index for the weights' gradient, cooperative matrices (I23's list). A flow step at batch
2048 is about 183 GFLOP at 10 x 1024 (3.12): 6 ms at the 5070's f32 peak (about 31 TFLOPS), 37-92 ms at the 2-5
TFLOPS the estimate assumes.

ON THE TIME PER STEP:
  S1 MEASURE FIRST (F0): the blocked products at the flow's own shapes - 2,048 rows through 516 x 1,024, 1,540 x 1,024
     and 1,540 x 128 (and 8 x 800's, for S11) - forward and both gradients - timed on the 5070 (`Compute.readTimings`, compute_host.zig:2055-2170, as
     geno_trainer's `kernel_times.csv` does): their TFLOPS and share of the peak, and the elementwise kernels' share of
     a step. Everything below is weighed against that number.
  S2 FUSED FINISHES: GELU in the blocked product's finish (as tanh and relu are fused into it), the LayerNorm writing
     straight into the next layer's wide row (no `place_columns`), the bias in the product - three to four dispatches a
     layer down to two, and as many passes over memory. Built only if S1 shows the elementwise kernels matter.
  S3 THE PRODUCT ITSELF (I23's remaining list - double buffering, split inner index, tensor cores in bf16 with f32
     sums): the tracking plan's work; the flow's shapes join its measurements, and its gains come here for free.
  S4 THE BATCH: the paper's 4,096 against the reference's 2,048 - a fuller GPU per sample, half the steps per epoch;
     judged in wall-clock to the gates, not in samples a second.

ON THE NUMBER OF STEPS:
  S5 MUON on the 9 hidden matrices, Adam on the first and last layers, the biases and the norms' gains - Muon's own
     convention and SuperMimic's MuonAdam, already on the kit (kit_mlp.zig:1504-1688). TWO GAPS: the kit's Muon is
     SQUARE only (kit_mlp.zig:1523), and the flow's hidden matrices are 1,540 x 1,024 - the Newton-Schulz rounds must run
     on the smaller Gram matrix (1,024 x 1,024), as torch transposes a tall matrix (kit_mlp.zig:1533-1534); and a range
     holds at most 4 Muon matrices (kit_mlp.zig:1688) where the flow has 9. Both are on the tracking plan's list too
     (the Nov 22 journal: "the rectangular Muon it needs"), so the work is shared. Evidence: 1.3-2x fewer steps reported
     on transformers (the NanoGPT speedrun; Liu et al. 2025, "Muon is scalable"); nothing published for an 8-layer flow
     MLP - the A/B decides.
  S6 AVERAGED WEIGHTS (EMA, decay 0.999): the lab and the gates read an exponential average of the flow's weights, kept
     by the kit's `polyak` kernel (the critic's target follow). Diffusion and flow models sample much better from the
     average than from the raw weights early in training: usable sooner at no cost in steps.
  S7 THE SAMPLER'S OWN TIMES: at S = 4 the sampler asks for the velocity only at t = 0, 1/4, 1/2, 3/4 (Algorithm 2). Drawing
     the training times there - all of them, or half with the rest uniform - puts every gradient where the sampler
     reads. Sound: the loss's minimiser at each t is the marginal velocity at that t, whichever times are drawn. The cost:
     S is fixed by the training (S = 8 would need a new one). A switch `time_draw = .uniform | .sampler | .mixed`.
  S8 THE SCHEDULE: warm up, hold the rate, decay over the last tenth (warmup-stable-decay) in place of a linear decay
     over 500k: a checkpoint becomes a good one after a short cool-down, so "usable" is a matter of the clock, not of
     the plan's length. Against the paper's linear decay.
  S9 THE AUTOENCODER STOPS AT ITS GATE: phase 1 ends when G1 passes (checked every 5k steps), not after 250k-500k - the
     paper's hour becomes whatever G1 needs on a pose half the reference's size.
  S10 THE SOURCE: the reference's whitened source is the baseline (2.G, D8 (b) - its notes: the network "does not have
     to transport samples as far"); the paper's unit Gaussian the A/B, to know what the trick is worth here.
  S11 A SMALLER NETWORK TO BE USABLE: 8 x 800 (the paper's, about half the step) and 4 x 512 against the baseline's
     10 x 1024, in minutes to G3.

REJECTED, OR NOT IN THIS PLAN:
  - Minibatch optimal-transport pairing of noise and data (Tong et al. 2023): straighter paths and quicker convergence
    for an UNCONDITIONAL flow - but every row here has its own condition, and pairing across rows makes each condition's
    source distribution something other than the N(0, I) the sampler starts from. Rejected for this conditional flow.
  - Half precision (f16 or bf16 products on the tensor cores): the largest single lever (several times on the products)
    and a kit-wide change - WGSL's f16, SPIR-V's Float16, cooperative matrices; I23's list, the tracking plan's.
  - Shortcut models and one-step distillation: speed of sampling, not of learning (section 6).

FLOWDPG (Simon asked) - what it can and cannot do here. FlowDPG (zimrrl's `FlowPolicy.flowDpgTargets`, on the kit as
`KitFlow.flowDpgGradient`, kit_mlp.zig:2338-2366) moves a flow's velocity toward a target pushed down a COST's gradient
at the sampled action, an anchor to the flow-matching term holding it near the data. It needs a cost differentiable in
the flow's output - the tracker's is its world model. For the kinematic flow, imitation is the flow-matching loss itself,
which already learns the data's distribution as fast as the network and the optimiser allow: FlowDPG does not make that
faster. What it adds is an OBJECTIVE beyond imitation, after imitation has trained:
  (a) FOLLOWING THE COMMAND - the decoded root's velocity against the commanded one, the trajectory's points against the
      springs' - aimed at the paper's own limit (section 7: the character "floats or remain stationary" on commands
      outside the data);
  (b) THE ARTEFACTS - foot sliding under a predicted contact, ground penetration (Table 1's measures, as costs);
  (c) TRACKABILITY - the tracker's world model's predicted tracking error of the next frame, so that the kinematic flow
      learns to ask only for what the physics can do: the physics goal, as a cost.
  PICK: (a) and (b) as a late stage (F15), judged on G3 and Table 1 against the plain flow; (c) in the hand-off (T6),
  once a tracker's world model exists for navigation.

THE ORDER (D9) - PICK (a): S1 (F0) first; then the baseline at the reference's recipe (AdamW with AMSGrad, D8), to have
a curve; then the A/Bs in order of payoff over cost - S6 (EMA) and S9 (the autoencoder's gate), cheap; S10 and S7,
switches; S4, a number; S8, a schedule; S5 (Muon), kit work shared with the tracking plan; S2 and S3 when S1 says the
kernels bound. (b) would put Muon in the first run, without a baseline to measure it against.
DECIDED (a), Nov 22, with the two cheap levers folded into the first run where they cost no measurement: the EMA weights
kept beside the raw ones and BOTH evaluated in the same run (one run gives both "usable" times), and the autoencoder
stopping at its gate (phase 1's time measured both ways once). Then one A/B at a time: the source (S10), the sampler's
times (S7), the batch (S4), the schedule (S8), Muon (S5), the smaller networks (S11), the fused finishes (S2).

### 2.V The paper or the reference, where they differ (D8)

The two agree on the method and differ in its numbers (1.2). D3 and D4 took the paper's sizes (latent 128, 8 x 800). The
rest:

                                        THE PAPER                    THE REFERENCE
    the source noise, the velocity      N(0, I), V unscaled          Zdist x N(0, I), Zdist x V (2.G's whitening)
    sigma_max, the previous pose        0.25                         0.5
    the latent's scale                  the maximum std              the mean std
    the flow's batch                    4,096                        2,048
    the optimiser                       RAdam (Algorithm 1)          AdamW, AMSGrad, decay 0.01
    the autoencoder                     250k at 1,024, ~1 hour       500k at 2,048
    the time input                      not stated                   one column t

  (a) THE PAPER'S NUMBERS AS THE BASELINE, every reference variant an A/B recipe beside it (the optimiser Adam + decay,
      the kit's, until S5 says Muon; the time as KitFlow's features, which carry t exactly).
  (b) THE REFERENCE'S NUMBERS AS THE BASELINE (it is the code verified on this very data, and its notes claim the noise
      trick helps), the paper's as A/Bs.
  (c) A MIX: the paper's everywhere but the noise and scale (the reference's notes' one claimed improvement).
  PICK (a) - Simon's "do what the paper does" - with (c)'s whitened source as the scoreboard's first A/B (S10): if it
  wins, the baseline changes by one flag.
  DECIDED (b), Nov 22 - Simon: the repository "was iterated for longer after the paper was published ... we can assume
  it is better and we should follow it". Its notes say as much where it departs (train.py:868-871, 878-880: "we found
  that you get better results"), and it is the code run on this very data. So the baseline is the reference's column of
  the table above: the whitened source (2.G), sigma_max 0.5, the mean std, batch 2,048, AdamW with AMSGrad and decay
  0.01 (2.I), the autoencoder 500k at 2,048, the time as one column. The paper's column becomes the A/Bs.

  THE SIZES (D3 and D4 again). Both were decided at the paper's numbers (latent 128, 8 x 800) before the reference became
  the baseline. The reference's are latent 256 and 10 x 1024 - chosen for a pose of 689 numbers with fingers. Ours is
  329. The reference's COMPRESSION is 689 -> 256, 2.7 to one; ours at 128 is 329 -> 128, 2.6 to one - the same ratio,
  so latent 128 IS the reference's choice carried over to a pose without fingers. Its network, 10 x 1024, is also the
  paper's own note on stability: "If trained with a larger network (e.g. 10 layers, 1024 neurons), we did see an
  improvement on the generation stability" (section 6.3.2). At latent 128 it is 15.0 million multiply-adds a row
  against 8 x 800's 8.0 - 1.9 times a step's cost, and still inside the buffers (3.12).
    (a) the reference's network, 10 x 1024, at latent 128 - its compression ratio; 8 x 800 the first A/B of S11
    (b) the reference's sizes exactly - latent 256, 10 x 1024 (17.8 million): a pose barely compressed (329 -> 256)
    (c) keep the decided sizes - latent 128, 8 x 800 - the reference's recipe on the paper's network
  PICK (a).


## 3. The design - the picks, assembled

### 3.1 Files

    src/character_flow.zig            CPU, a fast-test root: the skeleton without fingers; the takes and their tags;
                                      BVH Euler -> quaternions; the simulation bone; velocities; contacts; mirroring;
                                      Savitzky-Golay and median filters; the database file and its reader; the pose
                                      vector, its statistics and weights; decoding and the root; the training controls;
                                      the runtime springs - the host side of every kernel's arithmetic
    src/control_operators.zig         the schema as data, the featurizer, the layer stack it compiles to
    src/kit_mlp.zig                   KitSkipNetwork (section 3.5), beside KitNetwork; KitFlow over either network
    src/character_flow_kit.zig        the kit programs: the autoencoder's step, the latent table, the flow's step, the
                                      frame
    src/gpu/zn_mlp.zig                the new kernels (sections 3.4, 3.5, 3.7, 3.9); zn_mlp_kernels.zig lists them
    src/gpu/zn_mlp_sizes_flow_trainer.zig, src/gpu/zn_mlp_sizes_flow_lab.zig
    src/gpu_learn_tests.zig           the new kernels against zimrnum's graph, on the twin
    tools/flow_db.zig                 BVH takes -> the database
    tools/flow_trainer.zig            the run folder's trainer
    tools/vk_host_test.zig            the new kernels' rows in the kit check
    examples/flow_lab/flow_lab.zig    the lab; examples/flow_lab/recipes/*.zon
    scripts/flow_oracle.py            (D6) the reference's data functions -> src/tests/fixtures/flow/oracle.zon
    build.zig                         flow-db, flow-trainer (and -windows), flow-lab; the three new fast roots

### 3.2 The motion database (ZFMDB001)

    header      magic, joint count (35), frame count, range count, tag-range count, frame time
    skeleton    names, parents, the bind's local offsets (metres), the mean local offsets (the reference's Xref_pos,
                train.py:587 - what forward kinematics uses for every bone but the root and the hips)
    ranges      per take and mirror: name, first frame, end, mirrored
    tag ranges  per tag: tag, first frame, end (the reference's table, both mirrors)
    per frame   the simulation bone's position (3) and rotation (4); the hips' position local to it (3); the 35 joints'
                local rotations (4 each; the hips' local to the simulation bone); the two contacts - 152 floats
                (1.09 million frames: 660 MB)

Velocities and angular velocities are derived on load, per range, by the reference's differences: the same numbers,
half the file. The tool reads the 39 takes' 2.7 GB of text once.

### 3.3 The pose vector (329 numbers)

    [  0,   3)  the root's velocity in its own frame          [219, 222)  the hips' local velocity
    [  3,   6)  the root's angular velocity in its own frame  [222, 327)  the 35 joints' angular velocities
    [  6,   9)  the hips' local position                      [327, 329)  the two contacts
    [  9, 219)  the 35 joints' two axes (zm's column order)

Statistics as the reference (1.2): the mean; a scale per kind (its dimensions' mean standard deviation); the weights -
the reference's per-bone weights for the 35 joints (train.py:30-107, the finger rows dropped) times 35 for rotations and
angular velocities, 1 elsewhere; Xdist. Decoding inverts it: two axes -> rotation (`fromTwoAxis`), the root integrated
from its local velocities (controller.py:1028-1032), the hips and the joints posed over the mean offsets.

### 3.4 The autoencoder on the kit

Encoder dense 329 -> 512 ELU -> 128; decoder dense 128 -> 512 ELU -> 329, its output times Xdist (0.47 million
parameters). NEW: ELU fused into `dense_fwd` (`Act.elu`; its slope from the output alone: 1 above zero, y + 1 below - so
`act_bwd` needs no extra region); three loss gradients - `weighted_l1_bwd` (w_c sign(s_c y - t) s_c / n, s = Xdist the
prediction's per-column scale), `pair_difference_l1_bwd` (rows in pairs, the same on (y1 - y0) against (t1 - t0), into
both rows), `latent_l1_bwd` (|z| and |z1 - z0|, added into the latent's gradient before the encoder's backward); their
values for the log; `gather_rows` (rows of a resident table by an index column, into a packed block). A step: the pairs'
starts drawn from the resident list of valid starts, both frames gathered, the encoder and the decoder forward, the three
gradients, both backwards, AdamW with AMSGrad (2.I); the phase ending at G1's first pass (S9). THEN THE LATENT TABLE:
every frame encoded on the device in chunks; the mean, the scalar
scale and Zdist taken by a column-statistics pass; Zmin and Zmax; the table rewritten whitened (2.G).

### 3.5 The skip network on the kit (KitSkipNetwork, kit_mlp.zig)

    layer 0        x (width n) -> dense n -> h -> GELU                                     W0, b0
    layer k >= 1   LayerNorm(h_(k-1)) (gain, bias) -> [n_k | x] -> dense (h + n) -> h -> GELU    gain, bias, Wk, bk
    output         [h_(L-1) | x] -> dense (h + n) -> out, linear                           Wout, bout

THE FORWARD of layer k: `norm_fwd` over the previous GELU output (its normalised rows, inverse spreads and scaled values,
packed) -> `place_columns` of the scaled values into the first h columns of the layer's wide row, whose last n columns
hold x (placed once per application) -> `dense_fwd_tiled` over the wide row (its stride h + n) -> `gelu_fwd` (NEW, reads
the linear outputs). THE BACKWARD, top down: `gelu_bwd` (NEW, from the stored linear outputs) -> `dense_bwd_w_tiled`
(reads the wide row through the stride) and `dense_bwd_x_tiled` (the wide gradient, packed) -> `take_columns` of its
first h columns into the scaled values' gradient -> `norm_params_bwd` and `norm_bwd` -> the previous layer's output
gradient; and the wide gradient's last n columns into THE NETWORK'S INPUT GRADIENT - the output layer's written
(`take_columns`), every later arrival added (`lat_take`; layer 0's packed one by `add_block`). It offers KitNetwork's
interface - `application`, `forward`, `backward`, `outputsOffset`, `inputsGradientOffset`, `forwardHost` - so KitFlow
takes either network (a comptime parameter). Its CPU reference is zimrnum's graph: matmul and add, gelu,
layerNormRows with the gain and bias, concat.

### 3.6 The control encoder for navigation

    schema       Or { uncontrolled: Null,
                      velocity_facing: And { velocity: Velocity, direction: Optional(Direction) },
                      trajectory: FixedArray(And { location: Location, direction: Direction }, 3) }
    featurized   [ velocity 3 | direction 3 | the Optional's one-hot 2 | 3 x (location 3, direction 3) = 18 | the Or's one-hot 3 ]
                 = 29 numbers; the options not taken are zeros
    layer A      the Optional: dense over [direction 3 | its one-hot 2] -> 256        (zero for a row that is not
                                                                                       velocity_facing: no bias, the
                                                                                       one-hot carries it)
    layer B      the Or: dense over [velocity 3 | A 256 | the Optional's one-hot 2 | trajectory 18 | the Or's one-hot 3]
                 -> 256
    out          [ B 256 | the Or's one-hot 3 ] = 259 numbers -> the flow's condition columns

The training rows are featurized on the GPU from the sample list and the raw-controls table (2.K); the runtime row by
the frame's controls kernel (3.9). The encoder trains with the flow: the flow's input gradient at the condition columns
is the encoder's output gradient.

### 3.7 The flow trainer, one step, kernel by kernel

     1  hashed_uniforms (seed = the step)             -> each row's place in the sample list
     2  gather_flow_rows (NEW)                        -> w_f into the targets; w_(f-1) into the condition columns; the
                                                         featurized control into the encoder's input
     3  previous_pose_noise (NEW)                     -> w_(f-1) + sigma_max u eps, u and eps hashed per row
     4  the encoder forward (A, B)                    -> B's output and the one-hot placed into the condition columns
     5  hashed_noise, hashed_uniforms                 -> each row's source noise and time
     6  flow_path_points, flow_time_features           -> the point on each row's path, its velocity, the time column
                                                         (2.H; the features in the A/B)
     7  the skip network forward                      -> the velocity
     8  mse_bwd, per-column weights Zdist^2 (NEW mode) -> the velocity's gradient
     9  the skip network backward                     -> the parameters' gradients, the input gradient
    10  take_columns (the condition's encoder part)    -> the encoder's output gradient; its backward
    11  ClippedAdam with decay and AMSGrad (2.I)       -> the step over [encoder | flow], at this step's rate
    12  polyak                                        -> the averaged (EMA) weights follow the step (S6)
    13  every 100 steps: the loss's value             -> read back for the log and the console

### 3.8 The run folder

    run.zon          FlowRun: the database's path and the set, the autoencoder's and the flow's shapes, the schema, the
                     hyper-parameters, the phases' iterations
    autoencoder      the autoencoder's weights and the pose's statistics, after phase 1
    character        ZFLOW001 - everything the lab needs: the skeleton, every statistic, the autoencoder (both halves),
                     the control encoder and the flow, each raw and averaged (S6), 256 start latents with their roots;
                     rewritten whole every few minutes
    character_m<N>   a checkpoint after N minutes
    log.csv          one line per 100 steps: phase, step, the losses, the rate, seconds
    speed.csv        the scoreboard's line for this run (3.13): minutes to usable and to good, the step's time
    evaluate.csv     the measures of F11, each time they are taken
    status.zon       the phase, the step, minutes, the latest loss, what stopped being finite (if anything)
    stop             created by anyone: the trainer saves and exits

The phases run in order - the autoencoder, the latent table, the flow - and a resumed run carries on from the phase it
stopped in.

### 3.9 The frame, kernel by kernel

The CPU uploads the command: the mode, the desired velocity and facing in the world (or none), the springs' half-lives,
the frame's seed. Then, on the kit:

     1  flow_runtime_controls (NEW)   the springs from the GPU-held root (position, rotation, velocity, angular velocity,
                                      acceleration) predict the root at 1/3, 2/3, 1 s; everything into the root's frame ->
                                      the featurized row
     2  the encoder (A, B)            -> the condition columns of the sampler's four blocks, beside w_prev
     3  hashed_noise                  -> the first block's point
     4  KitFlow.sample                -> 4 Euler steps -> w_next
     5  clip_columns (NEW)            -> w_next inside [Zmin, Zmax] / Zdist
     6  the latent's affine           -> z_next = Zdist w_next, the decoder's input z Zscale + Zoffset
     7  the decoder                   -> the pose vector
     8  flow_pose_decode (NEW)        -> denormalised; the root integrated on the GPU-held root; the joints' rotations
                                         from two axes; the smoothing (alpha) against last frame's pose
     9  flow_forward_kinematics (NEW) -> 35 world positions and rotations, for drawing (and at T3 for the copy)
    10  copy_columns                  -> w_next becomes w_prev

The CPU reads back step 9's pose, the contacts and the predicted trajectory, a frame late, skins Geno and draws. A reset
writes one of the character file's start latents and its root. The CPU twin runs the same program on the host: the
tests, and a machine with no GPU.

### 3.10 The lab (examples/flow_lab)

geno_lab's shape: the runs beside its executable, their curves (each phase's loss against minutes), the newest character
loaded and "follow the newest" while a trainer runs, start, resume and stop. The character: Geno skinned on the floor,
the camera following him (geno_lab's `CameraFollow`); 1, 2, 3 for uncontrolled, trajectory and velocity-facing; the left
stick moves, the right stick faces, the right trigger runs (x1.5); WASD and the arrows without a gamepad; R resets; the
smoothing slider; the trajectory's points and directions, the velocity and the facing drawn; G3's numbers live in the
panel (speed error, direction error, facing error), and the foot sliding and jitter of the last ten seconds.

### 3.11 The hand-off to physics

T1: a scripted command track (a `.zon` of segments: mode, stick, trigger, seconds) -> a rollout on the twin or the device
-> a BVH of the 35 joints (`codecs.bvh.encode`) -> `robot_geno.copyClip` -> a `dance.Clip` -> `auditClip` -> geno_lab
plays it as the reference beside the physics Geno. T2-T5 as 2.R lists them; T3's per-frame copy is the `Copier`'s
arithmetic on the readback, T4's a kernel of it writing straight into the simulator's reference rows.

### 3.12 Budget arithmetic

    THE FLOW, latent 128, 10 x 1024     input 128 + 128 + 259 + 1 = 516 (the time as one column, 2.H); layer 0
    (the baseline, D3/D4 again)         516 x 1024; 9 x (1024 + 516) x 1024; output (1024 + 516) x 128 -> 14.9 million
                                        multiply-adds a row, 14.9 million parameters (8 x 800: 8.0 million; the
                                        reference's own 10 x 1024 at latent 256: 17.8 million)
    ALL PARAMETERS                      flow 14.9 M + encoder 0.07 M + autoencoder 0.47 M = 15.5 M floats -> params 2^24
                                        (16.8 M)
    A TRAINING STEP, batch 2048         30.6 G multiply-adds forward, about 92 G with the backward (183 GFLOP): at 5
                                        TFLOPS sustained 37 ms, at 2 TFLOPS 92 ms -> 500k steps 5 to 13 hours, 10k
                                        steps 6 to 15 minutes. AN ESTIMATE: F0 measures the products at these shapes
                                        and F8's first run the step; the recipes follow the measurements.
    ACTIVATIONS, a training row         ~56,000 floats (9 x 5,600 for the normed layers and their wide rows) -> 115 M at
                                        2,048 rows; gradients ~36,000 -> 73 M
    OPTIMISER AND AVERAGE               AMSGrad's running maximum (2.I) and the EMA weights (S6), 15.5 M floats each, in
                                        acts
    TABLES                              the pose table, phase 1 only: 1.09 M x 329 = 357 M floats (1.43 GB); the
                                        whitened latents: 1.09 M x 128 = 139 M; the raw controls 26 M; the sample list
                                        4 M -> phase 1 ~370 M, phase 3 ~315 M with the activations and the optimiser's,
                                        inside acts 2^29 (537 M)
    A FRAME                             4 x 14.9 M + 0.3 M = 60 M multiply-adds, about 175 dispatches; resident: the
                                        parameters, ~0.3 M floats of blocks, the start latents
    AT THE PAPER's BATCH, 4,096         a step twice the multiply-adds (366 GFLOP); activations 230 M, gradients 146 M -
                                        the gradients past 2^27 (134 M): the paper's batch needs dacts 2^28, or 8 x 800

### 3.13 The scoreboard (G5)

One file per run, `speed.csv`, and one table here, updated after every A/B:

    run    the recipe's name and the one lever it changes from the baseline
    usable the wall-clock minutes to G3 (checked on the EMA weights every 2 minutes of training, on the twin's
           evaluation of a fixed command sweep - section 0's G3, 8 directions x 4 speeds, both facing modes)
    good   the minutes to G2 and G3 at their bars together
    step   the milliseconds of a training step, and the samples a second
    note   what else moved (a gate's margin, the loss's floor)

Each lever runs against the baseline from the same seed and the same database, one at a time; a lever is kept when it
shortens "usable" or "good" without lengthening the other, and the baseline then moves to include it (robotgpu_plan.md
R7: "unchanged means measured" - a lever that changes nothing measurable is not kept). The checks read the gates by the
trainer itself (`flow_trainer` evaluates on a schedule and writes `speed.csv`), so no person has to watch a run to time
it.


## 4. Stages - each ends in a check that can come out red

Every check follows robotgpu_plan.md's R1 (seen to fail on the thing it is for, then passing again) and R5 (bars from
measurements). Simon builds and runs; each stage hands over its commands, `zbuild lint-fix` first.

F0 THE KIT AT THE FLOW's SHAPES (S1). A bench mode of the trainer (`flow_trainer --bench`), before any new kernel: plain
   KitNetwork layers of the flow's shapes (2,048 and 4,096 rows through 516 x 1,024, 1,540 x 1,024, 1,540 x 128 - and
   8 x 800's 516 x 800, 1,316 x 800, 1,316 x 128), forward and
   both gradients, each dispatch timed on the device (`Compute.readTimings`); printed as milliseconds, TFLOPS and share of
   the 5070's peak, and written into 2.U and 3.12. CHECK: the bench's multiply-add count against the shapes' arithmetic
   (a dispatch timed at zero or past the peak is a timing bug, not a result). `zbuild flow-trainer-windows`, then
   `flow_trainer --bench` on the 5070.

F1 THE TAKES, READ (`character_flow.zig`). The skeleton without fingers (by name, as bvh-trim); BVH channels to
   quaternions; forward kinematics; Savitzky-Golay with scipy's `interp` edges and the median filter with its `nearest`
   edges; the simulation bone; the hips made local to it; velocities and angular velocities; contacts; mirroring (in zm's
   order: positions (-x, y, z), rotations (x, -y, -z, w), derived from the reference's (w, x, -y, -z), and checked by a
   drawing before any number: claude.md, "DRAW THE TWO THINGS YOU ARE COMPARING").
   CHECKS: forward kinematics of the stored locals reproduces the BVH's own within 0.1 mm on all 35 joints over 200 frames
   of walk1_subject1 (seen to fail: the Euler order reversed); mirror(mirror(x)) = x to float noise, and a mirrored step
   swaps the toes' heights (seen to fail: the name swap left out); the filter reproduces cubics exactly to the last
   sample (seen to fail: the window off by one); the simulation bone at height 0 with a unit direction; with D6 (c), the
   oracle's simulation bone, velocities and contacts on two 300-frame takes within 1e-4.
   `zbuild test-character_flow`.
F2 THE DATABASE (`tools/flow_db.zig`, the reader). The reference's tag table, both mirrors, ZFMDB001;
   `zbuild flow-db -- C:/Users/sclav/Downloads/Flomo2/Flomo2/data/lafan1_bvh <out file> all`.
   CHECKS: written and read back equal; each take's frame count its file's `Frames:` line; every tag range inside its
   take; a truncated file refused (`NotADatabase`); the time and size printed - and written here.
F3 THE POSE VECTOR. Its layout, statistics and weights; decoding; the root.
   CHECKS: pose -> vector -> pose to float noise; integrating the root's local velocities over 10 s of walk1 stays within
   5 cm of the simulation bone's own path (seen to fail: the velocity left in the world's frame); with D6 (c), the
   oracle's statistics within 1e-4.
F4 THE AUTOENCODER'S KERNELS. ELU fused; the three L1 gradients; `gather_rows`; the loss values; ClippedAdam's decay.
   CHECKS: on the twin, a whole autoencoder step's gradients on 8 pairs against zimrnum's graph (elu, the L1 by relus),
   within 1e-5 relative (seen to fail: one gradient's sign flipped); vk-host-test rows (device against twin); the WGSL
   corpus refreshed. `zbuild test-gpu_learn_tests`, `zbuild vk-host-test`.
F5 THE AUTOENCODER TRAINED, THE LATENT TABLE (`character_flow_kit.zig`, flow_trainer's phases 1 and 2). Phase 1 stops
   at its gate (S9, D9): G1 measured every 5k steps, the phase ended at the first pass - and, once, run on to the
   reference's 500k to say what the stop cost in G1's margin.
   CHECKS: G1; the loss read in the log falls (a bar set from the first run); the latent table's statistics against a
   readback of 4,096 of its rows.
F6 THE SKIP NETWORK (`KitSkipNetwork`, `gelu_fwd`, `gelu_bwd`).
   CHECKS: forward and backward against zimrnum's graph on the twin, 16 rows, within 1e-5 relative - the parameters'
   gradients and the input gradient (seen to fail: one layer's input-gradient add left out); vk-host-test rows.
F7 CONTROL OPERATORS (`control_operators.zig`): the schema, the featurizer, the compiled layers; the navigation schema;
   the training controls' tables; the springs on the host.
   CHECKS: the compiled layers against a plain operator-by-operator evaluation on random weights, to float noise (a
   second implementation, the reference's semantics written plainly); a root going straight along +z at 1 m/s gives the
   trajectory's points at 0.333, 0.667 and 1.0 m and the velocity (0, 0, 1) (seen to fail: the lookahead counted from
   the previous frame); with D6 (c), the oracle's training controls on two takes within 1e-4; the spring's prediction
   for a held command against its closed form far out (the slope reaches the desired velocity).
F8 THE FLOW TRAINED (`character_flow_kit.zig`, flow_trainer's phase 3, the run folder). The EMA weights (S6, D9) kept
   beside the raw ones by `polyak` after every step, both written into the character file and both evaluated on the
   scoreboard's schedule - one run, two "usable" times.
   CHECKS: the whole step's gradients against zimrnum's graph on 16 rows (twin); an overfit - 600 frames of walk1, 5k
   steps, uncontrolled: the 4-step sample from each true previous latent lands near the true next one (a bar from the
   run; seen to fail at step 0); THE FIRST RUN ON THE RTX 5070: the step's time measured and written into 3.12, the
   curve, G2 and G3 at 10k and 50k steps and at the end.
F9 THE FRAME (`flow_runtime_controls`, `clip_columns`, `flow_pose_decode`, `flow_forward_kinematics`, the program).
   CHECKS: a frame on the twin against a host-only path (zimrnum's forward and character_flow's host decoding) to float
   noise; 600 uncontrolled frames finite on the twin; the device against the twin from one state (R3); G4's time.
F10 THE LAB. G3 and G4 read live; Simon drives Geno with the gamepad and sends a screenshot or a video.
F11 THE MEASURES (`flow_trainer --evaluate`): Table 1's measures as section 6.3 defines them (a toe's contact when it moves
   under 20 cm/s below 20 cm; jitter the mean magnitude of the joints' accelerations), the ground truth's beside them, G3's
   command sweep, Table 2's sweep of S; `evaluate.csv` in the run folder, the latest in the lab.
F12 THE FEET (optional): foot locking and two-bone IK after the readback, for the eye (controller.py:529-781).
F13 THE PAGE (later, its own decisions): the page's sizes, the weights (62 MB at f32 for 15.5 M parameters - embedded, or
   served beside the page, or a smaller network), WebGPU's dispatch cost per frame measured on the phone.
F14 THE SPEED LEVERS, one A/B each on the scoreboard (3.13), in D9's order (the EMA and the autoencoder's gate already in
   the first run, F5 and F8): the source (S10), the sampler's times (S7), the batch (S4), the schedule (S8), Muon (S5: rectangular Muon on the
   kit and more than four matrices a range - its own checks: two steps on a 24 x 16 matrix against torch's algorithm in
   f64, as the square one was checked on Nov 18; seen to fail without the transpose), the fused finishes (S2) if F0 asks.
F15 FLOWDPG AFTER IMITATION (2.U, (a) and (b)): `KitFlow.flowDpgGradient` with a cost of the command's error and the
   artefacts on the decoded frame, the flow-matching anchor holding the data; judged on G3 and Table 1's measures against
   the flow before it. CHECK: the cost's gradient at the flow's output against finite differences on the twin.

T1 A CLIP. A scripted rollout -> BVH -> copyClip -> the audit; geno_lab plays it as the reference. G6.
T2 THE TRACKER'S DATA. Minutes of flow rollouts under random command tracks, baked as clips, for the tracking plan's
   recipes (that plan owns the training).
T3 LIVE IN GENO_LAB. The flow character as geno_lab's reference, driven by the gamepad, the physics Geno tracking it.
T4 ON THE DEVICE. A flow per world, its output written into the simulator's reference rows by a kernel - the tracker
   trained on live flow motion, no CPU in the loop.
T5 THE LOOP CLOSED. When the physical character strays (a push, a fall), its pose re-encoded (the autoencoder's
   encoder) as the flow's previous latent, blended, so the kinematic character comes back to where the body is - the
   previous-pose noise of training (up to sigma_max of a standard deviation in every latent dimension) is what lets the
   flow accept a latent that is not its own.
T6 TRACKABLE BY CONSTRUCTION (2.U, FlowDPG (c)): once a tracker's world model exists for navigation, its predicted
   tracking error of the flow's next frame as FlowDPG's cost - the kinematic character learning to ask only for what the
   physics can follow.


## 5. Risks

* THE KIT'S SPEED. 3.12 is an estimate; if F8 measures it several times slower, the recipes shrink (4 x 512, batch 1024)
  and the tiled kernels' blocking becomes a stage of its own.
* SMALL DEPARTURES ADD UP. GELU's tanh form against the erf, sine-cosine time against a column, the mean scale against the
  max, whitened latents: each defensible, each untested by the paper. G2 and G3 judge; each has a switch so an ablation
  is a recipe.
* OUT OF THE DATA (section 7): the character floats or freezes when asked for more than the data holds - the command is
  clamped to the data's speeds (3 m/s, 4.5 under the trigger, the reference's).
* MEMORY: the pose table is 1.43 GB on the device in phase 1 and about 2 GB on the host while it is built.
* THE TRACKER: not yet trained for navigation, and moving on its own plan's schedule; T1 is a measurement, not a gate,
  until it is.
* THE ORACLE needs numpy and scipy on the Windows machine; without them D6 falls back to (b) alone.
* THE LICENCE: CC BY-NC-ND 4.0, research use; nothing trained on it goes into the repository.
* THE WEB: new kernels pass through spv2wgsl, whose WGSL only a device sees (zn_mlp_web_twin_plan.md); they join the
  corpus, and the page (F13) waits for the browser check that plan describes.


## 6. Not in this plan - what it makes cheap

* Move to target (eq. 20), styles (a one-hot), interactions (sit, pick up, jump to a target): schemas over the same
  machinery.
* Set, Array and Dictionary (attention) and String (text): the operators for variable inputs.
* One-step distillation (eq. 24), and the uncontrolled prior with noise-conditioning encoders (section 7).
* A segment flow (8 frames a step) - the tracker's lookahead for free.
* Learned Motion Matching (section 4.3) on the same latent space.
* Other datasets on Geno: 100STYLE, ZeroEGGS, Motorica (the retarget repositories the dataset's README lists).
* A tutorial page for the character, if Simon wants one written alongside the work.


## 7. Decisions - asked one at a time

    D0  DECIDED BY THE ASK: everything on the GPU - training and every frame (2.M (a)).
    D1  Where the work lives (2.A): (c) - its own files in geno_lab's conventions, geno_lab taking the flow character
        as its reference at T3.                                   DECIDED Nov 22 (Simon: "Own files, meet at T3")
    D2  The data (2.B): (a) - the reference's split, uncontrolled on its 39 `all` takes, the controls on its curated
        `locomotion` ranges, all mirrored.                        DECIDED Nov 22 (Simon: "Reference split")
    D3  The latent space (2.E): (a) - the autoencoder, latent 128; 256 only if G1 fails at 128.
                                                                  DECIDED Nov 22 (Simon: "AE, latent 128")
    D4  The flow network on the kit (2.F): (a) - the paper's network, the SkipCatMLP (its size since decided again:
        10 x 1024, below).
                                                                  DECIDED Nov 22 (Simon: "I think we should do what the
                                                                  paper does. But we should maybe look at recent things
                                                                  like muon, and FlowDPG, for trying to speed up
                                                                  learning? Let's focus on making it as fast as
                                                                  possible")
    D8  Paper or reference, where they differ (2.V): (b) - THE REFERENCE's numbers are the baseline, the paper's A/Bs.
                                                                  DECIDED Nov 22 (Simon: "The repo might be actually
                                                                  better than the paper, since it was iterated for
                                                                  longer after the paper was published. I think we can
                                                                  assume it is better and we should follow it?")
    D3/D4 AGAIN - the sizes, now that the reference is the baseline (2.V, "THE SIZES"): (a) - the reference's 10 x 1024
        at latent 128, its compression ratio carried over; 8 x 800 the first A/B of S11.
                                                                  DECIDED Nov 22 (Simon: "10x1024 at latent 128")
    D9  The speed levers' order (2.U): (a) - F0 measures first, the reference's recipe as the first run with the EMA
        evaluated beside the raw weights and the autoencoder stopping at its gate, then one A/B at a time.
                                                                  DECIDED Nov 22 (Simon: "Measure, baseline, then A/Bs")
    D5  The control encoder (2.J): (a) - a small Control Operators schema compiled into a featurizer and kit layers;
        the navigation schema the reference's Uber encoder.       DECIDED Nov 22 (Simon: "Small Control Operators")
    D6  Verification (2.P): (c) - the Python oracle of the reference's own data functions AND the Zig property checks;
        numpy and scipy installed once on the Windows machine.    DECIDED Nov 22 (Simon: "Oracle + properties")
    D7  The hand-off's order (2.R): (a) - offline first: T1 a clip, T2 the tracker's data, T3 live in geno_lab, T4 on
        the device, T5 the loop closed, T6 trackability by FlowDPG.
                                                                  DECIDED Nov 22 (Simon: "Offline first")
    THE SMALLER CHOICES - 2.C, 2.D, 2.G, 2.H, 2.I, 2.K, 2.L, 2.N, 2.O, 2.Q, 2.T - read back with every decision above
        and confirmed together.                                   CONFIRMED Nov 22 (Simon: "i agree. Don't implement
                                                                  it just yet")


## 8. Journal

- Nov 22 (v1 DRAFT). The user: the ask above. Read the paper (pdftotext: the Read tool could not render the PDF, poppler
  is not installed; Git's own pdftotext was there), the reference whole, the dataset repository, and zimr's kit,
  zimrnum, Geno, the clips, the tracker's heads, geno_lab and geno_trainer. Found: the dataset folder holds no motion,
  and the whole of LAFAN1-resolved's BVH is already on the machine (1.3); a flow on the kit exists (KitFlow) and is the
  method's sampler and loss as they stand; what the kit lacks is GELU, ELU, a skip and L1. Wrote this plan; D1 asked.
- Nov 22 (D1-D4). D1 (c), D2 (a), D3 (a) as picked. D4, the user: "I think we should do what the paper does. But we should
  maybe look at recent things like muon, and FlowDPG, for trying to speed up learning? Let's focus on making it as fast
  as possible." - the paper's network at 8 x 800. ADDED: G5 as the scoreboard (wall-clock to usable and to good), 2.U
  (every speed lever: measure the kit at the flow's shapes first - F0; EMA, the autoencoder's gate, the whitened
  source, the sampler's own times, the batch, the schedule, Muon; FlowDPG as an objective after imitation, not a speed
  lever - F15 and T6), 2.V (the paper's numbers against the reference's, D8), 3.13, F0, F14, F15, T6. FOUND: the kit's
  Muon is square-only and holds four matrices a range (kit_mlp.zig:1523, 1688); the flow's hidden matrices are
  1,321 x 800 - rectangular Muon, also on the tracking plan's list. D8 asked.
- Nov 22 (D8, THE SIZES). D8, the user: "The repo might be actually better than the paper, since it was iterated for
  longer after the paper was published. I think we can assume it is better and we should follow it?" - (b), the
  reference's numbers as the baseline (its notes on its departures agree: train.py:868-880). Revised: 2.G (the whitened
  source the baseline), 2.H (the time as one column), 2.I (AdamW with AMSGrad: two ClippedAdam settings), 2.T (the
  reference's hyper-parameters, the mean std), 2.U (the baseline named). THE SIZES asked again, since D3 and D4 had
  taken the paper's: the user chose (a), 10 x 1024 at latent 128 - the reference's network, at the reference's
  compression ratio on our 329-number pose. Revised: 2.F, 2.Q (params 2^24 holds 15.5 M), 2.U's S1 and S5 (the hidden
  matrices 1,540 x 1,024, nine of them), S11 (8 x 800 the first smaller A/B), 3.12 (14.9 M multiply-adds a row; a step
  about 183 GFLOP; the paper's batch of 4,096 needs dacts 2^28), F0's shapes, F13's weights (62 MB). D9 asked.
- Nov 22 (FINAL). D9 (a) - F0 first, the reference's recipe as the first run with the EMA evaluated beside the raw
  weights and the autoencoder stopping at its gate, then one A/B at a time (F5, F8 and F14 revised to say so); D5 (a),
  D6 (c), D7 (a), each as picked. Every decision and every smaller choice read back; the user: "i agree. Don't implement
  it just yet". THE PLAN IS FINAL AND NOT IMPLEMENTED: F0 (the kit's products timed at the flow's shapes) is the first
  stage, and it starts only on Simon's go.
