# robotgpu - MuJoCo Warp in zimr, on the GPU of the web and of Windows - the plan (v1 DRAFT, Oct 31 2026)

STATUS: FINAL (Oct 31) - all 18 decisions answered one at a time and the full list agreed by Simon ("agree. Don't
implement just yet"). NOT STARTED: implementation, beginning with S0, waits for Simon's explicit go. Written under claude.md's "MAKE A PLAN" procedure: study,
brainstorm every option, pick, write it down here, then ask the open decisions ONE AT A TIME (section 12) and revise
after each. **Nothing is implemented and nothing will be until Simon says go.** This file is the one source of truth
for robotgpu's decisions, status and journal (section 13).

Simon's ask (Oct 31): "study deeply how our robot simulator robot.zig works, and is used by our robot tracking project.
And study even more deeply how mujoco warp works. Make a md plan, in src/notes, for creating robotgpu.zig, similar to
robot.zig, which will use zimr kompute capabilities, with zimrmath, zimrnum, on web and windows gpu, with zig shaders,
for reproducing all functionality of mujoco warp in zimr style. We will then use it for our robot mocap tracking
project. We want to end up this plan with a robotgpu.zig, that can include only basic zimr files such as zimrmath and
zimrnum and zimrphysics and robot.zig. We could change parts of robot.zig to make it easier to do robotgpu.zig, if
necessary."

What was read for this plan: `src/robot.zig` (the header, Model, Data, every pipeline stage, both solvers, the
integrators, `State`), `src/robot_track.zig` and `src/robot_track_resident.zig` (how the tracker steps it),
`src/robot_physics.zig` (the contact bridge), `src/kompute.zig`, `src/compute_host.zig`, `src/gpu/zn_mlp.zig` (the house
kernel style), `src/notes/rl_track_plan.md`, `rl_track_journal.md`, `robot_port_plan.md` (its section 6, "the GPU
angle"), and MuJoCo Warp at `C:\Users\sclav\Downloads\mujoco_warp-main\mujoco_warp-main`: `types.py`, `forward.py`,
`smooth.py`, `constraint.py`, `solver.py`, `warp_util.py`, `io.py` read directly; `collision_*.py`, `sensor.py`,
`passive.py`, `derivative.py`, `inverse.py`, `island.py`, `sleep.py`, `history.py`, `set_const.py`, `ray.py`, `bvh.py`,
`render*.py` read in full by six study passes whose digests are folded into section 2. MJW citations are
`file.py:line` under `mujoco_warp/_src/`.


## 0. The goal, stated so it can fail

`src/robotgpu.zig`: MuJoCo Warp's simulator, in zimr. Thousands of independent worlds of one robot model stepped in
lockstep on the GPU, every kernel written in Zig through `kompute`, compiled to SPIR-V and run by zimr's native Vulkan
host - NATIVE ONLY, officially (D18): training never runs in a browser - and the SAME source running as the CPU twin. It builds its GPU
model from `robot.zig`'s `Model`, uses `zimrmath` for every vector, `zimrnum` where a tensor routine or the
counter-based `Rng` fits, and imports nothing from the engine (no `gpu.zig`, `wgpu.zig`, `compute_host.zig`): the
device is driven one layer up, the way `zimrnum.zig` stays queue-free while `src/gpu/zn_*.zig` hold its kernels.

WHAT THE GPU IS FOR (Simon, Oct 31, with D1): "Gpu is really just to accelerate training." A robot in a GAME runs on
the CPU engine - robot.zig, with zimrphysics for its scene - and that stays as it is. Training should "theoretically
work on web and native", accepting less memory (fewer worlds) on the web; if the web cannot do it, robot-tracking
training on native only is acceptable. Then, with D5 and D18 (Oct 31): "We want maximal perf right from the
beginning", and robotgpu is officially NATIVE ONLY - Windows on Vulkan for training, lavapipe for the sandbox's tests.
The web keeps robot.zig on the CPU for games and demos; nothing in robotgpu is shaped by WebGPU's limits.

THE GATES - each one a measurement that can come out red:

  G1 PARITY WITH robot.zig. On every feature both engines have, robotgpu's CPU twin reproduces robot.zig step for step
     to f32 tolerance (1e-5 relative, the tolerance `src/tests/fixtures/robot/reference.zig` already uses), with the
     same contacts fed in: a KUKA on its limits, a Go1 standing, the humanoid falling, Geno tracking a clip.
  G2 GPU EQUALS ITS TWIN. Every kernel's GPU output matches the CPU twin to a stated ULP bar (zero where the arithmetic
     is plain, a few ULP where a transcendental is called - the zimrnum sweep's rule; a tolerance where float atomics
     reorder a sum) on lavapipe in the sandbox and on Simon's GPU under Vulkan.
  G3 PARITY WITH MUJOCO. Every feature robot.zig lacks (collision, MuJoCo's contact parameters, the approximate
     constraint diagonal, MJW's Newton line search, elliptic cones, the sensors, the passive forces...) checked against
     REAL MuJoCo through fixtures `scripts/robot_oracle.py` generates - never against ourselves; where MuJoCo Warp
     deliberately differs from MuJoCo C, against fixtures MJW generates, each such row documented (D16).
  G4 THROUGHPUT. On Simon's desktop GPU, natively, Geno with N worlds: at least 20x the CPU fleet's steps per second
     at equal physics (the journal's "the GPU simulator next, for the 50x that every later experiment needs", Sep 20).
  G5 THE TRACKER TRAINS ON IT. `robot_track_resident` learns with robotgpu as its simulator, and the policy it produces
     still tracks when judged by robot.zig in its MuJoCo mode - the engine games deploy it on (D14), held to the same
     physics as training by G1 (plan principle P7, "judged in reality").
  G6 EVERY ROW OF THE PARITY TABLE (section 5) is DONE or DECLINED WITH A REASON.


## 1. What exists - the zimr side, verified in the code

### 1.1 robot.zig - what it is

16,483 lines; `zm`, `std` and the profiler only. Reduced coordinates in the style of MuJoCo, f32 throughout
(robot.zig:44-55 says why, and names the one escape hatch: widen `factorM`/`solveM` to f64 inside). The things that
matter for a GPU port:

  - MODEL / DATA. `Model` is flat parallel arrays indexed by body, joint, dof, geom, site, sensor, tendon, actuator,
    built once and never written (robot.zig:1324-1486). `Data` is "sized from the model, flat, and free of pointers so
    a batched rollout can slice many instances out of one allocation later" (robot.zig:2854-2860) - written for this
    day, though every field is still its own slice in one arena per instance.
  - CONVENTIONS. Spatial vectors angular-first (MuJoCo's rot:lin, robot.zig:146-158); `Motion`/`Force` as two `Vec`
    each; the ten-number spatial inertia (`Inertia`: diag, off, h, mass - robot.zig:239-414), full symmetric tensor
    rather than MuJoCo's principal moments; quaternions (x, y, z, w) in `qpos` where MuJoCo has (w, x, y, z)
    (robot.zig:8347-8350); bodies parent-first (`Spec()` refuses otherwise); body 0 is the world; the frame for every
    spatial quantity is the tree root's subtree centre of mass (`comPos`, robot.zig:3674).
  - THE PIPELINE (`forward`, robot.zig:6335): kinematics -> comPos -> crb -> factorM -> sensors(position) -> comVel ->
    makeConstraints -> projectConstraints -> biasForce (RNE) -> passive -> actuation -> sensors(velocity) ->
    forwardDynamics -> solveConstraints -> bodyAccelerations + sensors(force). `step` = forward + integrator (Euler
    with implicit joint damping `dampedVelocityStep` robot.zig:6415, RK4, implicit and implicitfast with an LU of
    M - h*D robot.zig:7042). `step1`/`step2` split for controllers.
  - THE MASS MATRIX: packed lower triangle over ancestor chains, diagonal last in each row (`mass_row_start`,
    `mass_col_index`), L^T D L in place with no fill-in walking rows backward (`factorMDamped`, robot.zig:3941-4021).
    MJW stores M the same way (its `_M`, smooth.py:1056-1097, writes the diagonal at `rowadr + rownnz - 1` and walks
    `dof_parentid` down the row).
  - CONSTRAINTS: rows with a DENSE `constraint_capacity x nv` Jacobian; limits (both ends can be active), pyramidal
    contacts (4 rows: n +/- mu*t), equalities connect / weld / joint coupling. Softness as MuJoCo's solref/solimp
    (`Softness`, `Impedance`) with refsafe (time constant >= 2 dt) and a recovery-velocity cap on contacts.
    **The constraint diagonal is EXACT**: `projectConstraints` (robot.zig:5145) solves M^-1 J^T for every row and takes
    A_hat = J M^-1 J^T, where MuJoCo by default - and MJW always - uses a model-constant approximation (section 2.7).
  - SOLVERS: PGS (default; warm-started by u64 row KEYS) and a primal Newton with a dense nv x nv Hessian, Cholesky and
    an 8-step backtracking line search (`solveNewton`, robot.zig:5447). Newton starts from the free acceleration and is
    not warm-started.
  - NO COLLISION, EVER: contacts are an input (`Data.pushContact`). `robot_physics.Bridge` registers each link as a
    kinematic body in a `zimrphysics` world and harvests that world's manifolds (robot_physics.zig:1-35).
  - THE STAGE WATERMARK (`Data.stage`), `State` snapshots carrying warm-start keys (robot.zig:11279), MuJoCo oracle
    fixtures from `scripts/robot_oracle.py`, ~130 tests in the file and ~760 in the robot family.

### 1.2 How the tracking project uses it

THE ROBOT IS GENO (robot_geno.zig:1-41), a ragdoll synthesized from Geno's LaFAN1 skeleton and baked to
`tests/fixtures/robot/geno.xml`, loaded by the trainer in `GenoBody.init` (tools/geno_trainer.zig:806-836):

  - nbody 25 (world + 24), njnt 24 = one free root + 23 BALL joints, nq 99, NV 75, action 69 = nv - 6.
  - nu 0: no actuators - the servo writes torques straight into `d.applied_force` (robot_track.zig:2065). No
    sensors, equalities or tendons. Ball ranges are dropped (robot.zig never limits ball joints), so no limit rows.
  - 21 massless geoms: 16 capsules, 1 sphere (the hips), 4 boxes (feet and toes); mass from 24 stated inertials.
    Armature overridden to 2.0 on every ball (geno_trainer.zig:821-825), damping 0.2 (so Euler's implicit damping
    runs every step). SELF-COLLISION OFF: all 210 body pairs excluded (robot_geno.zig:1771-1811) - collision is 21
    geoms against the floor and nothing else.
  - Options: timestep 1/60 (the clip's frame time, asserted), gravity -Z, Euler, NEWTON (60 iterations max,
    tolerance 1e-6), warm start on, pyramidal cones, exact A_hat, max_contacts 256 (so ~1,070 rows x 75 of dense
    Jacobian allocated per character, robot.zig:3279-3328).

ONE ACTING STEP (robot_track_resident.zig:1797-1901, robot_track.zig:2012-2355), per character:

  1. Features: `stateOf` -> `local` -> normalise (387 floats: positions, two-axis rotations, velocities, angular
     velocities, heights, up - robot_track.zig:213-293), the goal from the reference at frame+1 (a full
     `rbt.forward` on scratch Data), the host MLP [goal | state] 774 -> 680 -> 680 -> 69 from a mirror of the GPU's
     weights, plus 0.1 N(0,1) exploration (and the flow's 5 Euler steps in the full run).
  2. `driveOnce`: target = `integratePos(clip.pose(frame + 1), 0.6 a)`; collide through the zimrphysics bridge (a
     floor BOX per character, friction 2.0 combined geometrically to 1.41, speculative margin min(|v| dt, 0.06));
     `biasForce`; THE SERVO `pdTorquesToward` (robot_track.zig:565-597): per joint dof a backward-Euler spring
     acceleration at 20 Hz, critically damped (`stableSpringAccel`, robot_maximal.zig:144-166), clamped, then
     `floatingBaseTorques` (robot_maximal.zig:191-258) - dense M, a 6x6 Gaussian elimination so the root's force is
     zero, tau = M a + c - into `applied_force`; then `rbt.step`, then kinematics/comPos/crb/comVel again.
  3. Bookkeeping: frame + 1, the reference state (another full forward), tracking error and reward, termination
     (head 0.25 m), aftermath and returns, resets (`resetToFrame` + `restOnFloor`), pushes (0.5-3.5 m/s on the root).
  4. The record: per character a third extra forward to rebuild the state, then one upload of every character's
     457-float record (387 features | 69 actions | table row) into the ring inside zn_mlp's `acts` buffer
     (robot_latent_kit.zig:3808-3867).

Per character-step that is one constrained step plus THREE contact-free full forwards, two of them serial.

SCALE AND TIMING. Night runs: 32 characters, 16 steps a round = 512 character-steps, then 4 world-model and 2 policy
updates. The judge every 30 minutes is about 10^5 single-threaded character-steps. Measured: Geno's physics step ~0.6 ms
on a phone; a lavapipe smoke run spent ~7.4 ms per character-step acting, ACTING 79% OF THE ROUND
(archive/rl_track_plan_v4.md:2023-2027); "our GPU waits on the CPU's physics" (rl_track_plan.md:140-143). Uni-SuperMimic,
the comparison the plan keeps making, runs 4,096 environments. No desktop measurement exists yet.

WHAT THE LEARNER NEEDS FROM PHYSICS: only features (`local`), the applied action, the frame index and the
episode/segment flags - it never reads q or v. Everything a GPU simulator would have to hand over is a function of
kinematics and comVel, plus the bookkeeping that today lives in the fleet.

THE KNOWN ANSWERS a port must reproduce: physics on 4 threads equals 1 thread bit for bit (robot_latent_kit_tests.zig:
2942); a zero action reproduces the reference (robot_track.zig:3671); the servo on Geno without gravity reaches every
joint within 1% in 0.5 s (robot_geno.zig:4401-4482); the servo baseline on dance_5_15 survives 1.532 s, reward 0.4987
(notes/bench/b1_10min_seed1.csv); save/restore replays identically (robot_geno.zig:5480).

TWO CONSEQUENCES FOR THE PLAN. (a) Geno's nv of 75 puts a dense Hessian at 75 x 75 x 4 = 22.5 KB, past WebGPU's 16 KB
of workgroup memory - which mattered until D18 made robotgpu native-only: a desktop GPU's 48-64 KB holds it (6.8). (b) Moving Geno to MuJoCo-faithful
contacts CHANGES THE PHYSICS THE TRACKER WAS TUNED ON - plane instead of box, MuJoCo's max-friction rule instead of the
geometric mean (2.0 against 1.41), MuJoCo's margins instead of the speculative one, the approximate diagonal, a warm
start. Section 6.12 and decision D8/D12 deal with it; the judge must run the SAME physics as training (G5).

### 1.3 zimr's GPU compute

KOMPUTE (kompute.zig): a kernel file declares `config`, `Buffers` (extern struct of fixed-size arrays), `Params`
(extern, a multiple of 16 bytes, padded with scalars), `g = k.Globals(@This())`, one `g.bind(.field)` alias per field
at module scope, a `pub const kernels` list and a `comptime` block installing them. The LEAN form
(`installKernelLean`, kompute.zig:417-467) reads Params straight from the uniform through `g.uniform()` and takes a raw
id; the stock form copies Params field by field (the OpCopyLogical bug) and emits about twice the WGSL. Bindings are
declared, not parsed: the uniform at 0, field i at 1 + i. Each field is its own storage buffer (one big binding was
mis-addressed on Adreno past ~1,000 invocations, kompute.zig:338-344). Atomics: u32 add/load/store only, by inline
SPIR-V. Workgroup memory (`k.shared`, module scope only) and `k.workgroupBarrier`; derive the workgroup from `c.id`,
never `workgroup_id` (kompute.zig:164-174).

BUILD (build.zig:1912-1945, shader_codegen.zig:608-711): `ComputeKernel` records compile a kernel file with
`zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv`, deps `zm` and
`kompute` always, `zn` / `zrl` when opted in (`wants_zimrnum`, `wants_zimrrl`); then `spv2wgsl --entry=<name>` once per
entry for the web. Native apps and the trainer embed the SPIR-V under the same names. A kernel file may import only
those modules plus relative files whose imports fit the same list - **robot.zig does not fit today**: it imports
`profiler.zig`, which needs `build_options` (profiler.zig:27). Tests import kernel files by path from test-fast roots
(one file cannot sit in two modules).

RUNTIME (`compute_host.Compute(M)`): `initCpu` (the module's static `g.B` IS the storage), `initWorker`, `initGpu` (one
buffer per field, the uniform, ONE staging buffer the size of all of `Buffers`, a heap mirror the same size; on the
WEB a bind group per kernel holding only the fields its WGSL uses, asserted <= 8; on NATIVE every field bound -
compute_host.zig:685-687; more than 8 `Buffers` fields is a compile error, compute_host.zig:596-608). `upload` /
`uploadAt` write ranges. `run(name, n)` dispatches ceil(n / workgroup) in x only, nothing checking the 65,535 limit.
Three ways to submit: unbatched (a submit per dispatch); `beginBatch(params)`..`endBatch` (ONE params value, ONE compute
pass, every dispatch in it - compute_host.zig:1169-1204); `beginRecording`..`submitRecording` (a 2,048-slot params
table, a copy into the uniform and a pass of its own per dispatch). `readLatest` copies the first `element_count`
elements of EVERY field (per-field ranges were planned, never built); about a frame of latency. The native Vulkan host
puts a full barrier before every pass, copy and dispatch; storage bindings past `max_storage_buffer_range` panic.
**There is no GPU timing for compute** - WebGPU timestamps cover render passes only, Vulkan's `gpuMsLast` returns 0.

PATTERNS TO REUSE: zn_mlp's 7 flat buffers with offsets in a ~220-line Params (zn_mlp.zig:70-325);
`kit_mlp.KitLayout` reserving regions and refusing an overfull one BY NAME (kit_mlp.zig:157-226); fused
one-thread-per-row kernels with `inline fn` helpers and scratch in global memory; `zrl_binary.cartpole_step` calling the
HOST function from the kernel - 1,024 environments a dispatch, the only per-environment simulation kernel in the tree
(zrl_binary.zig:79-126); the CPU twin as oracle (vk-host-test's device-versus-twin at 1e-5, zn_conformance's ULP bars).
Dispatch budgets seen in practice: 11 per fluid substep in one batch, 512 small ones a frame on a phone, ~1,050 per
SuperTrack iteration fused down to 8.

WHAT THE STUDY FOUND THAT WILL BITE (each verified against the code or the build cache):

  1. **A LIVE WEB BUG: writes through a pointer parameter of a non-inline function are LOST in WGSL.** spv2wgsl lowers
     a pointer parameter by value and leaves a `// ERROR:` comment (spv2wgsl.zig:7478-7498, 8549-8594), and compute
     builds do not pass `--strict` (shader_codegen.zig:681-698), so the build stays green. Verified today in
     `.zig-cache/o/389cee9e.../compute.wgsl:427-428`: `norm_fwd` calls `zimrmath_CompensatedSum_f32__add(total, x)` on
     a copy, so its sums stay zero in the browser. ~14 zn_mlp / zn_unary kernels carry the marker; Vulkan and the CPU
     twin are correct, so only a browser run shows it. RULE FOR robotgpu: helpers taking `*T` are `inline`, or work
     by value - and S0 fixes the lowering and turns `--strict` on for compute (section 8).
  2. 64-bit types silently become 32-bit on the web (spv2wgsl.zig:2141-2148).
  3. Unhandled opcodes become ZERO with a Debug-only warning (spv2wgsl.zig:7806-7878): `OpCompositeInsert`,
     `OpVectorInsertDynamic`, `OpVectorExtractDynamic` are missing - so a runtime-indexed `Vec` lane, and possibly a
     lane written in place, would silently read or write zero; integer `OpNot` prints as `!(x)`; no `Fma`. Which of
     these robot.zig-style maths actually emits is what S0.2's probe finds out.
  4. THE TWIN IS NOT THE SAME ARITHMETIC wherever zimrmath branches on `is_gpu` (17 sites): `sinRad` is exact on the
     CPU and a polynomial on the GPU (zimrmath.zig:1406-1418), `pow`, `atan2Rad`, `hypot` differ. Hinge kinematics
     calls sin and cos, so GPU and twin differ by ULPs from the first step and diverge chaotically over long rollouts:
     G2 compares ONE step from identical inputs, never trajectories.
  5. SIZE: 8 `Buffers` fields per module; the staging buffer and the heap mirror are each the size of ALL of
     `Buffers`; the CPU twin's `g.B` is a static the size of all of `Buffers` in every binary that imports the module
     (zn_mlp's 8 MB is "wasm memory on every page"). A simulator's arenas are hundreds of MB.
  6. NO `Vec` OR `Quat` IN ANY COMPUTE KERNEL YET, and no shader of any kind calls a quaternion function; no compute
     kernel uses a function-local array (slices of them do not compile at all - no variable pointers).

None of this blocks robotgpu. All of it shapes stage S0 (section 8), which exists to retire these risks before a line
of physics is written. WITH D18 (native only), items 1-3 and the web half of item 5 leave robotgpu's path - Vulkan runs
the SPIR-V itself - and stay a bug in the existing web learner, for its own session; items 4 and 6 still apply.


## 2. MuJoCo Warp - how it actually works

### 2.1 What it is

Google DeepMind and NVIDIA's GPU MuJoCo (part of Newton), Python authored as NVIDIA Warp kernels that Warp JIT-compiles
to CUDA. This copy is the 3.9-era tree (`ls_parallel` "was removed in MuJoCo Warp 3.9.1", types.py:1177-1192). About
62,000 lines of non-test Python (types 3,046; io 3,551; forward 3,311; smooth 5,096; constraint 5,868; solver 5,712;
passive 4,539; derivative 4,573; sensor 3,521; collision_* 12,400; ray/bvh/render 5,000; island/sleep 2,200;
history 1,200; set_const 900) and about 40,000 of tests. Everything is float32 - the same bet robot.zig made, and the
existence proof that a MuJoCo-class simulator holds together in single precision (io.py:467-470 clamps the solver
tolerance to at least 1e-6 for exactly that reason).

Against MuJoCo C (README): no PGS solver, no plugins, flex experimental, the implicitfast midpoint feature missing. It
adds things MuJoCo C lacks: a ray-traced batch renderer, a new DISCRETE integrator, and its own sleep/island machinery.
Its nightly numbers run humanoid at 8,192 worlds (benchmarks/README.md); its capacities are per-world
(`nconmax` 24, `njmax` 64 for the humanoid).

### 2.2 The data model

  - MODEL. Arrays shared by every world, plus a set of fields annotated `"*"` in their first dimension that may be
    batched: shape (1 or nworld, ...), and EVERY kernel reads them as `field[worldid % field.shape[0]]`
    (forward.py:110 for the timestep; smooth.py:93-127 for body_pos, jnt_axis, qpos0). That one idiom is how MJW does
    domain randomisation: masses, geom sizes, gravity, friction, timestep, gains, all per world, with no second code
    path (io.py `put_model(batch_sizes=...)`, io.py:321-344).
  - PRECOMPUTED TOPOLOGY (io.py:720-760 and around): `body_tree` (bodies grouped by depth), `body_subtreenum` (subtree
    sizes - bodies are DFS-ordered, so a body's subtree is the contiguous range [b, b + subtreenum)), `body_branches`
    (every root-to-leaf ancestor chain, flattened, io.py:733-750), M's CSR (`M_rownnz`, `M_rowadr`, `M_colind`), the
    factorisation's schedule (`qLD_updates`) and per-tree dense blocks (`M_tiles`), `body_isdofancestor` (an
    nbody x nv mask), the static collision pair list (`nxn_geom_pair`, `nxn_pairid`), per-type index lists
    (`eq_connect_adr`, `jnt_limited_slide_hinge_adr`...).
  - DATA. Every per-world array is world-major: (nworld, n...) (types.py:2462-2790). `qpos`, `qvel`, `xpos`, `cdof`,
    `M` (nworld, nC), `qLD`, `efc.*` (nworld, njmax)... CONTACTS are the exception: ONE pool for all worlds
    (`naconmax` = nconmax x nworld), each contact tagged with its `worldid`, slots claimed by an atomic counter `nacon`
    (types.py:2358-2404). Per-world `overflow` bitmasks replace exceptions (types.py:203-249; NEFC, BROADPHASE,
    NARROWPHASE, ITERATIONS...), with optional `wp.printf`.
  - CAPACITIES ARE PER WORLD AND FIXED AT `make_data` (io.py:1885-2115): nconmax and njmax default to 48 and 64 for a
    plain model, bucketed to 16/24/32/48/...; nvmax for the compacted solve. Nothing is allocated during a step
    (a requirement of CUDA graph capture, warp_util.py:148-167).

### 2.3 The pipeline (forward.py:3217-3246)

    forward:
      fwd_position      kinematics, com_pos, camlight, flex, tendon      (fwd_kinematics, forward.py:2419)
                        crb, tendon_armature, [factor_m]
                        collision                                         (collision_driver.collision)
                        make_constraint                                   (constraint.py:4805)
                        [sleep, island], transmission
      sensor_pos, energy_pos
      fwd_velocity      actuator & tendon velocity, com_vel, passive, rne, tendon_bias      (forward.py:2538)
      sensor_vel, energy_vel
      [control callback]
      fwd_actuation     actuator forces -> qfrc_actuator                  (forward.py:3013)
      fwd_acceleration  qfrc_smooth = passive - bias + actuator + applied (+ xfrc), qacc_smooth = M^-1 qfrc_smooth
      solve             constrained qacc                                  (solver.py:4100)
      [rne_postconstraint], sensor_acc
    step = forward + euler | rungekutta4 | implicit | discrete           (forward.py:3255)
    step1 / step2 split around the control callback                      (forward.py:3272, 3292)

The ORDER is MuJoCo's and robot.zig's, with one structural difference: MJW computes M and its factor in fwd_position
and collision in the same pass, where robot.zig takes contacts from outside.

### 2.4 The nine kernel strategies - the part to understand

Everything in MJW is one of these nine shapes. They are what a port has to translate, kernel by kernel.

  K1 ELEMENT GRIDS. `wp.launch(dim=(nworld, n))`, one thread per (world, element), no communication. The bulk of the
     code: geom/site/cam frames, cinert, cdof, qfrc sums, integrator updates, every per-row constraint update.

  K2 BRANCHES, for root-to-leaf recursions (smooth.py:52-151 kinematics, 1468-1502 RNE's acceleration pass,
     2819-2892 com_vel). One thread per (world, root-to-leaf chain); the thread walks its chain from the root, so a
     shared ancestor (the pelvis is on every chain) is recomputed by every chain through it and written by all of
     them with identical values. Parallelism nbranch per world (5 for a humanoid) at the price of redundant work and a
     benign race.

  K3 CONTIGUOUS SUBTREE SUMS, for leaf-to-root accumulations (smooth.py:680-707 subtree com, 1038-1053 composite
     inertia, 1552-1569 RNE's force pass). Because bodies are numbered depth-first, a subtree is a contiguous index
     range, so one thread per (world, body) simply sums [b, b + subtreenum) - O(nbody x depth) work, no atomics,
     deterministic, fully parallel; one per-world thread then folds the roots into the world (smooth.py:710-737,
     1572-1588). **This is the single most portable idea in MJW**: it replaces the backward tree pass, which on a GPU
     would need float atomics or a level-by-level schedule.

  K4 THE MASS MATRIX AND ITS FACTOR. `_M` (smooth.py:1056-1097): one thread per (world, dof), the row of M over the
     dof's ancestor chain - robot.zig's `crb` inner loop exactly. The factorisation is chosen per kinematic tree
     (io.py:270-318, smooth.py:1437-1447): a diagonal-only tree takes reciprocals; up to 6 dofs a scalar Cholesky in
     one thread (smooth.py:1332-1373); up to 64 a cooperative tile Cholesky in shared memory (smooth.py:1376-1408,
     cuSolverDx underneath); beyond that a sparse L'DL scheduled by level, whose updates use FLOAT ATOMICS
     (`wp.atomic_sub`, smooth.py:1238-1270).

  K5 CONSTRAINT ROWS. One specialised kernel per constraint type (equality connect / weld / joint / tendon / flex;
     friction dof / tendon; limits slide-hinge / ball / tendon; contacts - constraint.py:286-4300), each launched over
     (nworld, count of that type) or over the contact pool. A thread RESERVES its rows with an integer
     `atomic_add` on the world's `nefc` (constraint.py:107, 2614) - so row order varies from run to run - and fills
     them through one shared function, `_efc_row` (constraint.py:211-283). Contact Jacobians: dense, tiled over blocks
     of dofs with the `body_isdofancestor` mask (constraint.py:3678-3813), or sparse rows walking the two dof chains
     (constraint.py:3023).

  K6 THE SOLVER, one world per thread BLOCK. Primal Newton (default) or CG; no PGS. Per world: the line search is a
     block of threads striding over that world's rows with tile reductions (solver.py:883-1455); the Hessian
     H = M + J^T D J is a tile matmul per world (solver.py:2708-2784) and its Cholesky a tile Cholesky
     (solver.py:2920-2956); per (world, row) kernels update forces and states (solver.py:1836-1963); a per-world done
     flag retires converged worlds (solver.py:3860-3923). The iteration loop is a CUDA graph conditional,
     `wp.capture_while(nsolving, ...)`, or a fixed host loop when that is unavailable (solver.py:4175-4206).

  K7 COLLISION OVER STATIC PAIRS. The candidate pairs are fixed at load (all geom pairs passing contype/conaffinity,
     parent and exclude filters); a broadphase culls them per world (bounding sphere / AABB / OBB, or sweep-and-prune
     for big scenes) and appends survivors with an integer atomic; the narrowphase runs ONE KERNEL PER PAIR TYPE
     (plane-capsule, capsule-capsule, ...) over the survivors, writing contacts into the global pool with an atomic
     counter (section 2.6).

  K8 SPECIALISATION. `@cache_kernel` closures plus `wp.static(...)` compile one CUDA kernel per combination of flags
     (sparse/dense, cone, Newton/CG, deterministic, pair type, iteration counts) (warp_util.py:148-167). Branches that
     do not apply to the model are never in the binary.

  K9 OPTIONAL DETERMINISM. `opt.deterministic` (types.py:309) switches Warp's recorded atomics on; constraint-row
     sorting is still a stub (`_sort_constraints`, constraint.py:4799-4802, `pass`). **By default MJW is not
     run-to-run deterministic**: float atomics reorder sums, and integer atomics reorder rows and contacts.

### 2.5 Smooth dynamics, stage by stage

  - kinematics (smooth.py:434-492): K2 for body frames (free joints read straight from qpos; hinge/ball compose about
    the anchor and re-centre - "correct for off-center rotation", the same correction robot.zig makes at
    robot.zig:3595-3600), then K1 for xmat, inertial frames, geom and site frames. Hinge and slide measure from
    `qpos0` exactly as robot.zig does.
  - com_pos (smooth.py:833-864): K3 subtree com; K1 `_cinert` (MuJoCo's 10-number com-based inertia, rotated by ximat
    and shifted to the root's subtree com: smooth.py:740-785) and `_cdof` per joint (smooth.py:788-830) - the formulas
    of robot.zig's `comPos` line for line (free: three world axes, then three body axes about the offset).
  - crb (smooth.py:1100-1129): K3 `_crb_subtree`, then K4 `_M` with armature added on the diagonal (including actuator
    armature folded into joints, `util_misc.dof_armature_total`).
  - factor_m: K4.
  - com_vel (smooth.py:2895-2919): K2, cvel and cdof_dot together, free joints' translation axes with zero cdof_dot,
    ball/free rotations differentiated against the velocity BEFORE the triple - robot.zig's `rotationTriple` rule.
  - rne (smooth.py:1614-1629): gravity as the world's acceleration (`_cacc_world`), K2 for cacc, K1 for each body's
    force (I a + v x* I v), K3 to sum subtrees, K1 to project on cdof. Again robot.zig's RNE term for term.
  - rne_postconstraint (smooth.py:2165): cfrc_ext from applied forces, equality forces, contact forces (float
    atomics) and tendons, then cacc with qacc and cfrc_int - only when a sensor needs it.
  - solve_m / factor_solve_i (smooth.py:3957-4158): per block, the matching triangular solves.

The conclusion that matters for a port: **MJW's smooth dynamics is robot.zig's smooth dynamics, re-shaped for a GPU.**
Not one formula differs; only the traversal does. robot.zig's tests against MuJoCo fixtures therefore already pin the
arithmetic a GPU port must reproduce.

### 2.6 Collision

  - THE DRIVER (`collision`, collision_driver.py:1160-1239): reset the pair and contact counters, broadphase,
    narrowphase in the order convex -> primitive -> SDF, flex, surface velocity, a host contact-filter callback, and
    a contact sort that is an empty TODO (collision_driver.py:1154-1157). Called twice per step when sleep is on (the
    second pass only for newly woken bodies).
  - CANDIDATE PAIRS AT LOAD (io.py:801-892): every i < j geom pair passes when `(contype1 & conaffinity2) |
    (contype2 & conaffinity1)` is nonzero, the geoms sit on different weld bodies, not both on dof-less welds, not
    parent and child (unless FILTERPARENT is disabled), and not in `<contact><exclude>`; an explicit `<pair>` replaces
    all of that with its own parameters. The survivors are `nxn_geom_pair_filtered`, and a census per pair type
    (`geom_pair_type_count`) decides which narrowphase kernels exist at all.
  - BROADPHASE. NXN (collision_driver.py:838-959): one thread per (world, candidate pair); plane pairs test the other
    geom's distance along the plane normal against its bounding radius plus margins; others a bounding-sphere test,
    then an AABB test, then a 6-axis OBB separating-axis test (collision_driver.py:284-355), each switchable by the
    `broadphase_filter` bits; a survivor claims a slot in the shared pair pool with an integer atomic. SAP
    (collision_driver.py:424-792) projects bounding spheres on one fixed axis, sorts per world, binary-searches ranges,
    scans and sweeps - auto-selected only past 250,000 candidate pairs (io.py:883-888), so never for a robot.
  - PRIMITIVE NARROWPHASE (collision_primitive.py:1287-1448, collision_primitive_core.py): one generated kernel, one
    thread per surviving pair, an unrolled static if-chain over the pair types present. Per pair:

        plane-sphere 1 | plane-capsule 2 | plane-ellipsoid 1 | plane-cylinder 4 | plane-box 8 (all corners, filtered
        by depth) | plane-mesh 4 (support hill-climb, incident polygon, max-area 4) | sphere-sphere 1 |
        sphere-capsule 1 | sphere-cylinder 1 | sphere-box 1 | capsule-capsule 2 (MuJoCo's segment weights) |
        capsule-box 2 (`mjc_CapsuleBox`) | box-box 8 (15-axis SAT, face clipping; primitive only with NATIVECCD
        disabled, convex by default)

  - CONTACT PARAMETERS (collision_core.py:294-470): an explicit pair supplies everything; otherwise margin and gap are
    SUMMED over the two geoms, the higher `priority` wins condim, friction and adhesion outright, equal priority mixes
    solref and solimp by `solmix` weight (element-wise min of solref when either is in direct form), takes the max
    condim and the element-wise max friction, sums adhesion; friction expands to 5 numbers (slide, slide, spin, roll,
    roll), each clamped above MJ_MINMU. A contact is DETECTED within margin + gap and ACTIVE within margin; the
    constraint uses `dist - includemargin`. (MuJoCo C combines margin and gap differently - `max`, and
    `includemargin = margin - gap` - which G3's fixtures must settle before we copy either.)
  - CONTACT LAYOUT: struct-of-arrays over the shared pool: dist, pos, frame (row 0 the normal from geom 0 to geom 1),
    includemargin, friction[5], solref, solreffriction, solimp[5], dim, geom[2], efc_address[nmaxpyramid], worldid,
    type bits (constraint / sensor / passive), geomcollisionid, adhesion, surfacevel (types.py:2358-2404). Every
    contact takes its own `atomic_add(nacon)` (collision_core.py:271): a pair's contacts need not even be adjacent.
    Overflow skips the write and keeps counting, flagged later.

  - THE TABLE. `MJ_COLLISION_TABLE` (collision_driver.py:49-83) maps each geom-type pair to PRIMITIVE (analytic: plane
    with anything, sphere with sphere/capsule/cylinder/box, capsule with capsule/box) or CONVEX (GJK/EPA: everything
    with meshes, ellipsoids, cylinders, heightfields, and box-box). SDF has its own pass. **A humanoid or G1 on flat
    ground with capsules, spheres and boxes never leaves the primitive path** - MJW's own G1 and humanoid benchmarks
    are capsules, spheres and a plane (benchmarks/unitree_g1/unitree_g1_mjlab.xml, humanoid/humanoid.xml).
  - CONVEX (collision_convex.py, collision_gjk.py): one specialised kernel per pair type over the candidate list;
    GJK with signed-volume sub-distance (collision_gjk.py:369-797) on the CORE shapes (spheres and capsules shrunk to
    a point or segment, radii added back - collision_gjk.py:2631-2709); EPA from a hexahedron or tetrahedron seed,
    linear face scans, a horizon list, up to `ccd_iterations` (collision_gjk.py:1346-1489); then MULTI-CONTACT by
    clipping the incident face against the reference face, Sutherland-Hodgman, kept to the 4 points of largest area
    (collision_gjk.py:2272-2545). Mesh support functions hill-climb MuJoCo's convex-hull vertex graph, warm-started
    from the previous support vertex. No MPR. EPA scratch lives in global memory, one row per CCD slot claimed by an
    integer atomic (about 6 KB a pair at 35 iterations). No float atomics anywhere in it.
  - HEIGHTFIELD: per-cell triangular prisms selected by the other geom's AABB, GJK/EPA per prism, up to 4 contacts
    kept by a farthest-point rule (collision_convex.py:62-749).
  - SDF (collision_sdf.py): octree SDFs from meshes, Halton-seeded gradient descent per seed point, a contact per seed
    with no deduplication; plugin SDFs are stubs.
  - FLEX (collision_flex.py, 20 kernels): vertex-plane, element-geom, sweep-and-prune self collision, int64 radix-sorted
    deduplication. Experimental.

### 2.7 Constraints

  - ROW PARAMETERS (`_contact_kbimp`, `_efc_row`, constraint.py:142-283): k and b from solref (time constant clamped to
    2 dt unless REFSAFE is disabled; negative solref is the direct stiffness/damping form), impedance from solimp's
    two-piece power sigmoid, `D = 1 / max(invweight (1 - imp) / imp, MINVAL)`, `aref = -k imp pos - b vel`. The
    `invweight` is a MODEL CONSTANT computed at qpos0 by set_const (`dof_invweight0` = diag M^-1; `body_invweight0` =
    the mean translational and rotational diagonal of J M^-1 J^T at the body's com - set_const.py:206-385), combined
    per row: for a contact, the two bodies' invweights summed (with the friction rows scaled by impratio).
    **MuJoCo's `mj_diagApprox`. MJW does not support the exact diagonal at all** (`DIAGEXACT` is refused by put_model,
    io.py:372-379). robot.zig computes the exact one - see decision D8.
  - KINDS: equality connect / weld / joint / tendon / flex / flexstrain; friction loss on dofs and tendons; limits on
    slide/hinge (both ends), ball (a cone on the rotation angle), tendons; contacts frictionless (condim 1), pyramidal
    (2(condim-1) rows) or elliptic (condim rows), with torsional and rolling friction at condim 4 and 6.
  - ORDER within a world: equalities, friction, limits, contacts - counted separately (`ne`, `nf`, `nl`) because the
    solver treats the first two specially.
  - DENSE OR SPARSE: dense J (nworld, njmax_pad, nv_pad) up to nv = 32 by default, CSR above (io.py:260-267); dense
    above nv 60 is refused (io.py:419-422).

### 2.8 The solver

MuJoCo's primal formulation: minimise over qacc

    1/2 (qacc - qacc_smooth)' M (qacc - qacc_smooth)  +  s(J qacc - aref)

where s is a per-row convex penalty: quadratic in the active region with weight D, linear in the friction-loss
regions, zero when a unilateral row is satisfied, the cone's own function for elliptic contacts.

  - INIT (solver.py:1678-1711, 4031-4097): qacc from `qacc_warmstart` (last step's qacc) when the world has rows, else
    qacc_smooth; Jaref = J qacc - aref; Ma = M qacc; constraint states and forces; inertia_scale = 1/trace(M) for the
    convergence test (solver.py:143-159).
  - ITERATION (solver.py:3942-4028): exact line search along the search direction - the cost along the ray is
    piecewise quadratic, and the search brackets the minimum with 1-D Newton steps on its derivative
    (solver.py:883-1455, `ls_iterations`, `ls_tolerance`); update force and STATE per row (QUADRATIC, LINEAR_NEG/POS,
    SATISFIED, CONE); gradient `M qacc - qfrc_smooth - J' force`; Newton: H = M + J' D_active J, Cholesky, search =
    -H^-1 grad (an "incremental" mode skips refactoring when no row changed state); CG: Polak-Ribiere with M^-1 as
    preconditioner. Converged when the scaled improvement, gradient or Newton decrement drops under tolerance, or the
    step is zero (`_solve_done`, solver.py:3860-3923).
  - LOOP CONTROL: `wp.capture_while` until no world is still solving, or `opt.iterations` fixed rounds - every
    kernel of a round checks the world's done flag first.
  - NOSLIP (solver.py:4596+): optional post-pass, a PGS over friction rows with small QCQPs for elliptic cones.
  - COMPACTED SOLVE with sleep on: awake dofs packed into nvmax_pad and the dense Newton run at that size
    (solver.py:4371-4534; island.py:1074-1162).

Against robot.zig's Newton: the same objective and Hessian, but robot.zig backtracks (8 halvings from a full step)
where MJW searches exactly, starts from the free acceleration where MJW warm-starts from last step's qacc, and stops on
the gradient norm alone.

### 2.9 Actuation, passive forces, tendons, sensors

  - TRANSMISSION (smooth.py:2922-3633): joint (all joint types, moment rows of 1/3/6), jointinparent, slider-crank,
    tendon, site (with or without a reference site), body (adhesion). Moments are a per-world CSR whose row addresses
    come from an integer bump counter (nondeterministic order; a TODO says to precompute it, smooth.py:3548).
  - FORCE (forward.py:2563-2893): ctrl clamp; act_dot by dyntype (integrator, filter, filterexact, muscle, DC motor
    with up to 5 states, user); actearly; gain fixed / affine / muscle / DC motor; bias affine / muscle / back-EMF;
    force clamp; cogging and LuGre friction for DC motors; tendon actuator-force limits; `qfrc_actuator` scattered
    with float atomics (forward.py:2948-2978); joint actuator-force range and gravity compensation routed to actuators
    (forward.py:2981-3010). Newer MuJoCo features are all here: multi-input controls (`ctrladr`), actuator damping and
    armature folded into joints, ctrl delays through `history`.
  - PASSIVE (passive.py:4179-4539): joint springs (free and ball through a quaternion difference against
    `qpos_spring`) and dampers with polynomial terms, per joint, no atomics; tendon springs with a deadband (float
    atomics through ten_J); gravity compensation (atomics); fluid forces (inertia-box and ellipsoid models: added
    mass, Magnus, Kutta lift, drag); adhesion; the whole flex elasticity family. Spring, damper, gravcomp, fluid and
    adhesion kept in separate arrays.
  - TENDONS (smooth.py:4425-5096): fixed and spatial; sites, sphere and cylinder wrapping (`util_misc.wrap`,
    `wrap_inside` a 20-iteration Newton), pulleys; ten_J is CSR with a static pattern; tendon armature and the J-dot
    bias.
  - SENSORS (sensor.py): split by stage at load (io.py:1053-1110), one kernel per stage switching on type, one thread
    per (world, sensor): positions, quats, axes, frame pos/quat/axes in body/geom/site/camera frames with optional
    reference frames, subtree com, geom distance/normal/fromto (from extra SENSOR contacts the collision pass emits),
    insidesite, magnetometer, camera projection, rangefinders (ray casts, one per site or per camera pixel), clock,
    energies; velocimeter, gyro, frame lin/ang velocity, subtree linvel/angmom; accelerometer, force, torque, frame
    accelerations (via rne_postconstraint), actuator/joint/tendon forces, touch (contact normal forces in a site zone),
    contact sensors (match, sort, reduce), tactile (SDF per taxel), limit pos/vel/force. Cutoffs applied; noise is not
    modelled; delays and sample-and-hold through `history`.

### 2.10 Integrators

  - EULER (forward.py:1383-1424): semi-implicit; with any damping it adds h * d(damping)/dv to M's diagonal,
    refactors, and solves M' qacc' = M qacc - robot.zig's `dampedVelocityStep` exactly.
  - RK4 (forward.py:1581-1650): four forward passes, activations integrated per stage.
  - IMPLICITFAST / IMPLICIT (forward.py:2360-2416, derivative.py): M - h qDeriv from actuator velocity gains, damping,
    tendon damping and fluid (`deriv_smooth_vel`), plus the analytic RNE velocity derivative for IMPLICIT
    (`deriv_rne_vel`, float atomics level by level); factored per block (IMPLICIT: a sparse LU in one thread per world,
    smooth.py:4160-4283); free bodies get a separate 6x6 LU with the gyroscopic term.
  - DISCRETE (derivative.py "effective metric"): M + hD + h^2K assembled and solved by PCG - MJW-only, for stiff flex.
  - Position update (forward.py:93-154): free and ball quaternions integrated on the sphere, hinge/slide added.

### 2.11 Inverse dynamics, islands, sleep, history, constants

  - INVERSE (inverse.py:246-302): position and velocity stages, then constraint forces from the given qacc with NO
    iteration (one `_update_constraint`), qfrc_inverse = bias + M qacc - passive - constraint; a discrete-time variant
    undoes each integrator's implicit step (RK4 unsupported).
  - ISLANDS (island.py): trees coupled by active rows, found by a parallel union-find with integer atomics (cas/min/max)
    and one serial labelling thread per world. Computed for MuJoCo-compatible output; the solver does NOT partition
    by island.
  - SLEEP (sleep.py): MuJoCo's tree sleep - velocity under `sleep_tolerance` for long enough, no applied forces;
    sleeping trees zeroed, woken by contact with an awake tree, by equalities, by limited tendons or by the user; the
    solve runs compacted over awake dofs.
  - HISTORY (history.py): per-actuator ctrl delays and per-sensor delay / sample-and-hold, a circular buffer per
    object inside one float array, zero-order / linear / Catmull-Rom reads.
  - SET_CONST (set_const.py:761-864): recomputes model constants after edits - subtree mass, geom bounds (aabb,
    rbound), tendon_length0, equality anchors, camera/light references, and the INERT0 group (dof, body, tendon
    invweight0, actuator_acc0) by nv unit solves at qpos0.
  - IO (io.py): put_model from an `mjModel`, make_data / put_data / reset_data, capacities, overflow, unsupported
    features refused loudly (PGS, plugins, DIAGEXACT, dense J above nv 60, sleep without Newton...).

### 2.12 Rays, BVH and the batch renderer

  - RAYS (ray.py): mj_ray per world, brute force over geoms with a block argmin, or through a BVH; analytic
    plane/sphere/capsule/ellipsoid/cylinder/box, mesh and heightfield by brute force. Used by rangefinders (always
    brute force), touch sensors and mesh SDF approximation.
  - BVH (bvh.py): Warp's `wp.Bvh` over geom AABBs, one group per world, refit (never rebuilt) each step from geom poses;
    `wp.Mesh` per mesh and per heightfield (greedy-meshed), flex meshes refit with float atomics.
  - RENDERER (render.py, render_util.py): a ray-tracing megakernel, one thread per (world, camera pixel), Blinn-Phong
    with spot/directional/point lights, optional any-hit shadows, textures, skybox, Gaussian splats, RGB + planar depth
    + segmentation, supersampling.
  - WebGPU has no `wp.Bvh`/`wp.Mesh`, 64-bit handles or float atomics; the study's recommendation, adopted in
    section 6.13: RASTERIZE camera images with zimr's own renderer (instanced primitives read straight from the
    simulation's buffers), keep RAY CASTING in compute for rays, rangefinders and touch, build mesh BVHs on the host.

### 2.13 What MJW leans on that a browser does not have

  - FLOAT ATOMICS: qfrc_actuator scatter, the sparse factorisation, tendon passive forces, gravity compensation,
    contact force accumulation, RNE derivatives, J*qvel tile reductions, the touch sensor... dozens of sites.
  - TILES: cooperative tile load/store, matmul, Cholesky, reduce, sort, argmin (Warp's block primitives over
    cuBLASDx/cuSolverDx).
  - CUDA GRAPHS: `capture_while` drives the solver loop on the device with no host round trip.
  - SPECIALISATION per flag combination at runtime (`cache_kernel`), and 20-80 array arguments per kernel.
  - LARGE ALLOCATIONS: 64-bit addressing, buffers of gigabytes.

Each of these has a zimr answer (section 3); none of them is a reason MJW's ALGORITHMS cannot run in WGSL.


## 3. What WebGPU does not have, and what each MJW construct becomes

SUPERSEDED IN PART BY D18 (native only, Oct 31). The table below was written when the browser was the hard target and
every rule followed WebGPU's GUARANTEED limits. It stays as the record of what a web port would face; section 3.1 says
what each row becomes on the native Vulkan host, which is now the only target.

| MJW leans on | the WebGPU fact | robotgpu's answer |
|---|---|---|
| float atomics (dozens of sites, 2.13) | WGSL atomics are `u32`/`i32` only | OWNER COMPUTES: every float output written by exactly one thread. Tree sums by K3 contiguous ranges; scatters (`qfrc_actuator`, tendon and gravcomp forces) as GATHERS through a static transpose built at pack time; reductions as workgroup trees in shared memory or one thread's loop. Never a CAS loop on floats (slow and order-dependent). |
| integer atomics for slot claims | available (`kompute.atomicAdd` on `u32`) | Usable, but allocation is DETERMINISTIC by construction (decision D7): fixed slots, per-world scans and sorts. Atomics only for overflow flags and counters nobody orders by. |
| tiles: cooperative load/matmul/Cholesky/reduce/sort | none; workgroup memory + `workgroupBarrier` | Hand-written workgroup kernels in Zig (`k.shared`, `k.workgroupBarrier`), the zn_matmul tiling pattern. RULE: every loop that contains a barrier gets its trip count from the Params uniform or a comptime constant - never from storage - and per-world counts (nefc, ncon) become masks. That keeps WGSL's uniformity analysis and spv2wgsl's `checkBarrierUniformity` (spv2wgsl.zig:2461) satisfied. |
| 64x64 tiles in shared memory | `maxComputeWorkgroupStorageSize` 16,384 bytes | A dense nv x nv Hessian fits only to nv ~ 56 (with room for vectors). Above that the per-world factorisation runs from global memory (L2-resident) or the solver is CG (decision D9). |
| 1024-thread blocks | 256 invocations per workgroup, 65,535 workgroups per dimension | 1-D kompute ids cap a dispatch at 65,535 x workgroup threads; (world, element) kernels larger than that loop (grid stride) or split by a base offset. |
| 20-80 array arguments per kernel | 8 storage buffers per stage (default; compute_host asserts it, `max_portable_storage_buffers`, compute_host.zig:193, and refuses a module with more than 8 fields) | A handful of ARENA buffers (model f32 / model u32 / world state f32 / world state u32 / constraints / scratch) addressed by offsets from a LAYOUT the host computes once (section 6.2) - zn_mlp's pattern of flat buffers plus offsets, generalised. At most 8 fields per module, so every kernel is legal on the web (where only used fields are bound) and on native (where all are). |
| gigabyte buffers, 64-bit addressing | 128 MiB per storage binding, 256 MiB per buffer (defaults) | Sizes files like zn_mlp's (a portable set and a native set, `-Dtrainer-portable` precedent); sparse J; H only in scratch; arenas split by role so no single one passes the binding limit; nworld chosen per device. |
| CUDA graphs, `capture_while` | none; every dispatch encoded by the host | The whole step is ONE batch: one params value for every dispatch, so it runs in one compute pass (`beginBatch`, compute_host.zig:1169). Anything that would vary per dispatch (level, iteration, stage) moves into storage. Iterative solves loop INSIDE one kernel - a thread per world first, a workgroup per world later - so a solve is one dispatch and every world stops at its own convergence. |
| runtime specialisation per flag (`cache_kernel`, `wp.static`) | pipelines are compiled ahead of time from WGSL | Zig comptime: a kernel name per variant where it matters (cone type, pair type); model features as UNIFORM booleans in the layout, so one WGSL serves every model and a branch over an absent feature costs a uniform compare. |
| `wp.printf`, overflow warnings | none | MJW's own answer: per-world overflow and diagnostic bitmasks, read back with the usual frame of latency. |
| synchronous host reads | readback is asynchronous, about a frame late (`readLatest`, `readGeneration`) | Nothing in the step needs the host. The learner reads simulator state ON THE DEVICE (section 6.12); the host reads statistics late. |
| u64 handles, int64 sort keys | no 64-bit integers | None needed: no BVH handles, no flex radix keys; robot.zig's u64 constraint KEYS do not travel - the GPU warm-starts from last step's qacc, as MuJoCo and MJW do (decision D10). |
| `inf` sentinels (unused contact slots), NaN tests | WGSL promises neither NaN nor inf behaviour; spv2wgsl refuses non-finite constants (spv2wgsl.zig:2386) | Explicit counts and flags, never a sentinel distance. |
| vec3 packed at 12 bytes; row-major mat33 | `array<vec3f>` strides 16; WGSL matrices are column-major | Everything stored as `zm.Vec` (16 bytes) and `zm.Quat`, rotations as quaternions with frames built in registers - robot.zig's own conventions, so no conversion layer exists to get wrong. |
| `wp.round` half away from zero, `sign(0)` | WGSL rounds half to even, `sign(0) = 0` | The CPU twin and the GPU run the same `zm` functions; any place the two lowerings could differ gets a twin test. |
| drivers that misreport `workgroup_id` (Adreno, kompute.zig:164-174) | - | Derive (world, lane) from `c.id` only, as kompute documents. |
| pointer parameters, missing opcodes, 64-bit types (section 1.3, items 1-3) | spv2wgsl lowers them wrongly or to zero, green build | Fixed at the root in S0; until then `*T` helpers are `inline`, no runtime-indexed or in-place-written `Vec` lanes, no 64-bit types in kernel code. |
| one-thread-per-id CPU loop | a workgroup kernel with barriers has no valid sequential twin | Kernels whose GPU path cooperates through shared memory carry an explicit per-world CPU path (zn_unary's pattern); the FIRST version of every stage is a plain per-thread kernel whose twin is exact (section 4.B). |

### 3.1 On the native Vulkan host (D18) - what each MJW construct becomes now

| MJW leans on | native Vulkan (desktop GPU, and lavapipe for tests) | robotgpu's answer |
|---|---|---|
| float atomics | `VK_EXT_shader_atomic_float` (`shaderBufferFloat32AtomicAdd`) on NVIDIA, AMD, Intel and lavapipe - to be CONFIRMED on Simon's GPU in S0 | Available, and NOT used for any state (D7: deterministic by construction) - owner-computes gathers instead. Recorded by S0.1 for completeness. |
| tiles: cooperative reductions, matmul, Cholesky, sort | workgroup memory sized by the device (`maxComputeSharedMemorySize`, typically 48-64 KB) and subgroup operations (Vulkan 1.1: arithmetic, shuffle, ballot) | Workgroup kernels with `k.shared` and barriers, plus `kompute` subgroup reductions (native-only, by inline SPIR-V). Geno's 76 x 76 Hessian (23 KB) fits in shared memory. |
| 20-80 array arguments | descriptor limits in the hundreds; compute_host binds every field natively but caps a module at 8 fields | 8 arenas stay enough (6.2); lifting the cap for native modules is available if a measurement wants more. |
| gigabyte buffers | `maxStorageBufferRange` typically 2-4 GB on desktop (128 MB on lavapipe) | Native sizes files; the sandbox runs few worlds under lavapipe's 128 MB. |
| CUDA graphs, `capture_while` | none (no device-side conditional launch) | Unchanged: one batch per step; solver rounds as a fixed count with per-world done flags, or loops inside a workgroup kernel (D9). |
| per-dispatch parameters | push constants (`maxPushConstantsSize` >= 128 bytes) | Optional: a push-constant block for the few values that vary per dispatch (a level, a round), so a step stays one batch even with MJW's level-scheduled kernels. |
| 64-bit types | `shaderInt64` / `shaderFloat64` usually present, not enabled by the host | Not needed; f32 throughout, as MJW and robot.zig. |
| spv2wgsl's lowering bugs (1.3, items 1-3) | not involved: the host runs the SPIR-V | Off robotgpu's path. The SPIR-V still goes through zimr's legaliser (`spv_vulkan.zig`); S0's probe covers what it does to Vec/Quat code. |
| timing | `vkCmdWriteTimestamp` exists; the host's `gpuMsLast` returns 0 today | S0 adds per-stage timestamps to the native host. |


## 4. The brainstorm - every axis, every option, the pick and why

Each axis lists the options considered, the rejected ones included. The picks become decisions D1-D17 (section 12),
asked one at a time; until Simon answers, a pick is a recommendation.

### 4.A How robotgpu relates to robot.zig (D1 - the big one)

  A1 INDEPENDENT PORT. robotgpu re-implements MJW's arithmetic; tests compare it with robot.zig.
     + Free to follow MJW line by line; robot.zig untouched.
     - Two definitions of every formula. claude.md: "a numerically delicate formula written twice will be improved in
       only one place"; "one definition per concept". Section 2.5 found the two engines' smooth arithmetic IDENTICAL,
       so writing it twice buys nothing.
  A2 SHARED PER-ELEMENT FUNCTIONS. The arithmetic acting on ONE element - a body's pose from its parent and joints, a
     body's com-frame inertia, a joint's cdof, one row of M, one constraint row's k/b/impedance/D/aref, one contact's
     pyramid rows, the spatial algebra - becomes pure `pub fn`s over values in robot.zig. robot.zig's loops call them;
     robotgpu's kernels call the same functions. Only the TRAVERSAL is written twice, because only the traversal
     genuinely differs between a CPU loop and a GPU decomposition.
     + One definition of the physics; robot.zig's MuJoCo fixtures pin the GPU arithmetic for free; G1 mostly holds by
       construction.
     - Those functions must stay shader-safe (values in and out; no slices, allocators, `std.math`, profiler). A
       refactor inside a 16k-line file with ~760 dependent tests - verified BIT-IDENTICAL, no number may move.
  A3 robot.zig BECOMES THE CPU TWIN (robotgpu at nworld = 1 replaces robot.zig's internals).
     + One engine.
     - Every robot file depends on robot.zig's per-instance API (Data slices, stage watermark, step1/step2, State);
       GPU-shaped traversals are slower on a CPU; the riskiest possible first move.
  A4 ONE GENERIC PIPELINE over an accessor type, instantiated by both.
     + Shares the loops too.
     - The loops are exactly what must differ (K1-K6 are not robot.zig's loops), and it is `anytype` everywhere.

  PICK A2: "one definition per concept" applied exactly where the definitions are, robot.zig's public API untouched.
  Gate: robot.zig's suite and benches produce bit-identical numbers before and after the extraction.

  DECIDED Oct 31 (D1): A2, "share formulas".

  ONE OBSTACLE, settled in S0: a kernel build may import only zm, kompute, zn, zrl and relative files that fit that
  list, and robot.zig imports `profiler.zig`, which needs `build_options` (section 1.3). Either the kernel build learns
  to pass robot.zig's modules (a `wants_robot` beside `wants_zimrnum`, and lazy analysis keeps the profiler out of the
  SPIR-V), or the shared functions live in a small profiler-free file that robot.zig itself imports
  (`robot_math.zig`, robot.zig re-exporting it so no caller changes). S0 tries the first; the second is the fallback.

### 4.B Parallel decomposition (D5)

  B1 ONE THREAD PER WORLD for everything - robot.zig's loops inside a kernel.
     + Simplest; the CPU twin keeps robot.zig's order of operations; deterministic; parallelism = nworld.
     - Dense solver maths serial per thread; long register-heavy kernels; occupancy only from the world count.
  B2 MJW-FAITHFUL K1-K6.
     + Maximum parallelism.
     - Hundreds of mostly tiny dispatches per step; MJW's shapes lean on float atomics and tiles.
  B3 ONE WORKGROUP PER WORLD for everything (a megakernel).
     + One dispatch per step.
     - Most stages cannot occupy a workgroup; one enormous WGSL module; impossible to profile by stage.
  B4 HYBRID BY STAGE, MEASURED: K1 grids for element-parallel stages, per-world (or per-branch) threads for root-to-leaf
     recursions, K3 range sums for leaf-to-root accumulations, per-world threads for the tree factorisation, a
     WORKGROUP PER WORLD for the constraint solve.

  PICK B4 in two passes: every stage first in its simplest correct shape (often B1), proven against robot.zig; then
  stages widened in order of their MEASURED share of the step (timestamp queries per stage on the GPU, profiler zones
  on the CPU twin). "Optimising without a measurement is guessing" (robot_bench.zig header).

  DECIDED Oct 31 (D5): B2, MUJOCO WARP'S SHAPES FROM THE START - Simon: "We want maximal perf right from the
  beginning." Consequences, folded into section 6: the step program is MJW's kernel list (K1-K6, section 2.4), not a
  per-world first pass; parity with robot.zig (G1) is to TOLERANCE from the start, since MJW's shapes sum in different
  orders (the CPU twin itself stays bitwise run-to-run, and stays the GPU's oracle); per-stage GPU timing (S0) is still
  how the shapes are tuned. How MJW's float-atomic and tile kernels are realised depends on the target platforms (D18).

### 4.C Memory layout (D6)

  C1 WORLD-MAJOR [world][i] (MJW): a world's arrays contiguous; per-world readback and reset are ranges; coalesced for
     (world, element) kernels and for workgroup-per-world kernels.
  C2 ELEMENT-MAJOR [i][world]: coalesced for one-thread-per-world kernels; strided for workgroup-per-world ones.
  C3 PER ARRAY behind one accessor (`at(field, world, i)`) whose layout is a comptime switch, measured both ways.

  PICK C3, defaulting to C1. The accessor costs nothing and turns the layout into a measurement ("wire both behind one
  flag and let the harness run both").

  DECIDED Oct 31 (D6): C3, one accessor, world-major by default, element-major one comptime flag away.

### 4.D Buffers and the layout (D4)

  D-a A BUFFER PER ARRAY (MJW): impossible under 8 storage bindings.
  D-b ARENAS BY ROLE, offsets in the Params uniform: model constants (f32, u32), per-world state (f32, u32),
     constraints, contacts, scratch - each a `Buffers` field; every array an (offset, per-world stride) pair in a
     `Layout` inside `Params`, uploaded once per step.
  D-c ARENAS, offsets in a storage buffer: frees the uniform, costs a binding and a dependent load per access.
  D-d COMPTIME OFFSETS from a comptime model (`rbt.Spec`): fastest, but one WGSL per robot.

  PICK D-b. A layout of a few hundred u32s is far below the 64 KiB uniform; uniform loads are cheap and UNIFORM (they
  keep barrier loops legal, section 3); batch mode writes the uniform once per step. Arena LENGTHS come from sizes
  files (zn_mlp's precedent), offsets from the model at pack time.

  DECIDED Oct 31 (D4): D-b, 8 arenas and a Layout of offsets inside Params (section 6.2).

### 4.E Determinism (D7)

  E1 MJW: integer atomics claim pairs, contacts and rows; their order varies run to run.
  E2 DETERMINISTIC BY CONSTRUCTION: each candidate pair owns fixed contact slots; a per-world pass compacts them in
     pair order; constraint rows land at offsets from per-world prefix sums; no float atomics anywhere.

  PICK E2. zimr leans on determinism wherever it matters: robot.zig's determinism test, `State` replays bit for bit,
  finite differences from restored snapshots, "physics on 4 threads equals 1 thread", reproducible night runs. The
  price - fixed per-pair slots and a compaction pass - is small for robots (Geno: 21 pairs, at most 65 contacts).

  DECIDED Oct 31 (D7): E2. On the native host (D18) float atomics exist but feed no state; subgroup reductions are
  used only where S0.1 shows them bitwise-repeatable on the device (otherwise fixed-order shared-memory trees). The
  determinism test - the same run twice on one GPU, bitwise - is part of every stage's gate.

### 4.F The model's source of truth (D3)

  F1 robot.zig's `Model`, EXTENDED with what MuJoCo's collision and constraint stages need (contype/conaffinity,
     condim, friction[3], solref/solimp, margin/gap, priority/solmix, plane geoms, pairs, excludes, subtree counts,
     invweight0...), packed by robotgpu into arenas.
  F2 A SECOND MODEL TYPE for the GPU, with its own MJCF importer.
  F3 MJW's own route from an mjModel - Python and MuJoCo at runtime; no.

  PICK F1: one importer (`robot_mjcf`), one model, one place to be right about MuJoCo's semantics.

  DECIDED Oct 31 (D3): F1. With D14 it also means the judge (robot.zig in MuJoCo mode) and the GPU read one model.

### 4.G The mass-matrix factorisation

  G-a ONE THREAD PER WORLD, robot.zig's in-place L^T D L (no fill-in, rows backward) - the shared function. For Geno:
      75 rows of at most 27 entries, ~30k multiply-adds.
  G-b ONE WORKGROUP PER TREE, dense Cholesky in shared memory (MJW's tile path) - Geno's single 75-dof tree does not
      fit 16 KB.
  G-c LEVEL-SCHEDULED SPARSE (MJW's large-tree path) - float atomics; a gather form exists and is complex.

  PICK G-a; revisit only if the per-stage timings put it on top.

### 4.H The constraint diagonal (D8)

  H1 EXACT (robot.zig today): A_hat = J M^-1 J^T per row, a tree solve per row per step.
  H2 MUJOCO'S APPROXIMATION (MuJoCo's default; MJW's ONLY mode): invweight0 constants computed at qpos0.
  H3 BOTH, as an option on both engines.

  PICK H3, H2 the GPU default (MJW fidelity, and no per-row solve), robot.zig gaining H2 so G1 compares like with like.
  It CHANGES CONTACT SOFTNESS against what the tracker was tuned on - Simon's call.

  DECIDED Oct 31 (D8): H3. The GPU defaults to the approximation; robot.zig keeps the exact diagonal as ITS default and
  gains the approximation as an option (R5); the exact diagonal stays available on the GPU behind the same option.

### 4.I The constraint solver (D9)

  I1 NEWTON, ONE THREAD PER WORLD, iterations inside the kernel: one dispatch per solve, MJW's exact line search and
     convergence test, H = M + J^T D J and its Cholesky in a per-world scratch region of global memory (Geno: 75 x 75,
     padded to 76 x 76, 23 KB a world). Its CPU twin is EXACT - the same code in a loop.
  I2 NEWTON, ONE WORKGROUP PER WORLD: the same algorithm with the workgroup cooperating on H's assembly, the Cholesky
     (right-looking, a barrier per column) and the row reductions of the line search. H in shared memory only up to
     nv ~ 56; Geno's stays in global memory. GPU-only cooperation needs an explicit per-world CPU path for its twin.
  I3 MJW'S MULTI-DISPATCH LOOP: a fixed number of rounds of (line search, update, Hessian, factor) dispatches, every
     kernel checking a done flag.
  I4 CG (MJW parity): no Hessian; M^-1 through the tree factor as preconditioner; more, cheaper iterations.
  I5 PGS (robot.zig's default and MuJoCo C's; MJW has none): sequential per world, one thread per world.

  PICK I1 first (correct, exact twin, one dispatch), then I2 when the measured solve time says so, I4 behind `solver`
  timed against Newton on Geno. PGS only if a robot.zig parity test needs it - the tracker already runs Newton.

  REVISED AFTER D5 AND D18: with MJW's shapes from the start and native shared memory (Geno's 76 x 76 Hessian, 23 KB,
  now FITS), the pick moves to I2 - MJW's own per-world block algorithms (line search with block reductions, the
  Hessian assembled by the block, its Cholesky in shared memory, subgroup reductions) fused into ONE dispatch whose
  rounds loop inside the kernel. I3, MJW's literal per-round dispatches, is what Warp does only because a CUDA graph
  conditional skips the rounds nobody needs; on Vulkan, with no device-side conditional launch, every one of up to
  `opt.iterations` rounds would be dispatched and barriered whatever converged. I3 stays the measured alternative;
  CG (I4) beside Newton.

  DECIDED Oct 31 (D9): I2. Section 6.8 describes it.

### 4.J Warm start (D10)

  J1 qacc_warmstart: Newton starts from last step's qacc (MuJoCo, MJW).
  J2 robot.zig's u64 row KEYS matched per row (PGS's).

  PICK J1 on the GPU, and give robot.zig's Newton the same (it starts cold from free_acc today) so the two match. Keys
  stay for robot.zig's PGS.

  DECIDED Oct 31 (D10): J1 on both engines - robot.zig gains `Data.qacc_warmstart` (saved by `step`, carried by
  `State` so a restore replays bitwise) and Newton starting from it as an option, on in its MuJoCo mode.

### 4.K Collision (D11)

  K-a PORT MJW'S PRIMITIVE NARROWPHASE - written for GPUs (fixed outputs, no allocation) - with zimrphysics's
      narrowphase as a second CPU oracle.
  K-b CALL zimrphysics's narrowphase from kernels: its functions take `*const Shape` unions over slices and write
      manifolds - not shader-safe without refactoring an 18k-line Jolt port.
  K-c KEEP COLLISION ON THE CPU (robot_physics.Bridge) and upload contacts each step: defeats the purpose; useful as a
      stage-4 test rig only.

  PICK K-a, then MJW's convex path (GJK, EPA, multi-contact) for meshes, cylinders, ellipsoids.

  DECIDED Oct 31 (D11): K-a. The same narrowphase functions run on the CPU to feed robot.zig's MuJoCo mode (the judge,
  D14); zimrphysics stays a second CPU oracle in tests and the collision engine of games' mixed scenes.

### 4.L Contact parameters (D12)

  L1 MuJoCo's per-geom material (priority, solmix, condim, friction[3], solref/solimp, margin/gap) and `<pair>`.
  L2 robot.zig's per-contact softness with one friction per geom (combined geometrically by the bridge).

  PICK L1: an MJCF model's contacts are tuned in L1's terms. robot.zig's `Contact` stays a valid input.

  DECIDED Oct 31 (D12): L1. Geno's XML states the contact values it is meant to have (the floor's friction among them),
  so keeping today's feel or moving to MuJoCo's defaults is a line in the model, measured in S6.

### 4.M Who drives the device (D13)

  M1 robotgpu.zig holds the kernels, the layout, the packing and a PROGRAM - the ordered list of (kernel, thread
     count) one step is; a thin host file one layer up owns `compute_host.Compute(robotgpu)` and runs the program as
     one batch. robotgpu.zig imports std, zm, zn, kompute, robot.zig (and zimrphysics if collision maths is shared).
  M2 robotgpu.zig drives the device through compute_host itself: breaks the import closure Simon asked for, and leaves
     the fast test tier.

  PICK M1 - the zimrnum / src/gpu split, which already works.

  DECIDED Oct 31 (D13): M1 - robotgpu.zig device-free; `robotgpu_host.zig` runs its program on the Vulkan host.

### 4.N How the tracker uses it (D14)

  N1 EVERYTHING ON THE DEVICE: observations, the policy's action, the servo, resets and pushes, recording into the
     ring - kernels; the host encodes dispatches and reads statistics late.
  N2 PHYSICS ON THE DEVICE, ACTING ON THE HOST from readbacks: impossible in lockstep - the action for step t needs the
     state at t, and a readback is a frame late.

  PICK N1 (section 6.12 says how robotgpu's buffers and the learner's meet).

### 4.O Specialisation (D17)

  O1 GENERIC KERNELS with model features as uniform flags: one WGSL for every model.
  O2 COMPTIME MODEL SPECIALISATION (unrolled chains, constant offsets) per robot.

  PICK O1; O2 stays available for one fixed robot if a measurement asks.

  DECIDED Oct 31 (D17): O1 - generic kernels, model features as uniform flags, comptime variants only where a flag
  changes a kernel's shape (cone type, collision pair type), as MJW specialises.

### 4.P One file or a family (D2)

  P1 ONE `robotgpu.zig`: the kernel module (Buffers, Params, kernels, `installKernels`), the layout, the packing, the
     program, the CPU twin's harness - grown like robot.zig (16k lines) and zimrnum (32k).
  P2 A FRONT DOOR plus sibling kernel modules (`robotgpu_collide.zig`, `robotgpu_solve.zig`...). Separate modules mean
     separate `Buffers`, so every module boundary is a buffer-sharing problem (section 6.12's, multiplied).

  PICK P1, with the shader-safe maths both engines share living in robot.zig (A2). Revisit only if one module's
  SPIR-V/WGSL build time becomes the bottleneck - measured.
  P3 ONE MODULE, HELPER FILES (offered with D2): robotgpu.zig keeps Buffers and every entry point, large pure-maths
     sections in files it imports.

  DECIDED Oct 31 (D2): P1, one robotgpu.zig.

### 4.Q The oracle (D16)

  Q1 robot.zig for every shared feature (G1); REAL MuJoCo fixtures from `scripts/robot_oracle.py` for the rest (G3);
     the CPU twin for GPU equality (G2).
  Q2 MJW as the oracle (CPU Warp can run it): a reimplementation too; MuJoCo C is the reference both derive from. MJW
     stays a PERFORMANCE reference and a reading guide.

  PICK Q1.

  DECIDED Oct 31 (D16): Q1 with one refinement - REAL MuJoCo C fixtures are the oracle (plus robot.zig for shared
  features and the twin for the GPU); where MJW DELIBERATELY differs from MuJoCo C, MJW's behaviour wins (the ask is
  MuJoCo Warp) and is pinned by a fixture MJW itself generates, each such row documented (margin and gap, 2.6, is
  the first candidate).

### 4.R Scope order (D15)

  R1 TRACKER FIRST, THEN FULL PARITY: the features Geno's tracking needs, end to end on the device (S0-S6, G5); then
     MJW parity in order of value - S7 (the rigid-body set any robot's training uses), S8 (meshes, heightfields,
     spatial tendons, muscles...), S9, S10 - each row DONE or DECLINED with a reason (G6).
  R1b TRACKER FIRST, THEN PARITY ON DEMAND: S0-S6, then S7; every S8-S10 row built only when a training task needs it
     (a robot with mesh collision, terrain, muscles), the rest recorded as DEFERRED rather than scheduled.
  R2 MJW'S MODULE ORDER: smooth, collision, constraint, solver, sensors... before any use.

  PICK R1: the tracker is the reason for the work, and an end-to-end user finds the integration problems early; full
  parity stays the goal Simon set. With D1's statement that the GPU is for training only, S9 (rendering many worlds)
  shrinks to VIEWING a few training worlds - batch vision rendering serves no stated goal - and S10 (flex, SDF, the
  discrete integrator, tactile) is the natural candidate for DECLINED.

  DECIDED Oct 31 (D15): R1, tracker first, then full parity. Each S10 row is decided (built or declined, with its
  reason) when the work reaches it.

### 4.T Target platforms (D18 - opened by Simon's answer to D5)

  T1 NATIVE ONLY, OFFICIALLY: Windows on Vulkan for training; lavapipe for the sandbox's tests. Desktop GPUs then
     offer what MJW leans on: float atomic add on storage buffers (`VK_EXT_shader_atomic_float`), subgroup operations
     (Vulkan 1.1: reductions, shuffles, ballots - MJW's tile reductions), shared memory sized by the device (typically
     48-64 KB: Geno's 22.5 KB Hessian fits), storage bindings up to the device's `maxStorageBufferRange` (often GBs),
     push constants for per-dispatch parameters, and more than 8 buffers a kernel if compute_host lifts its cap for
     native modules. MJW's kernels port nearly line by line, and spv2wgsl leaves the critical path.
     + maximal performance and the most faithful port; Simon already accepted native-only training (D1).
     - training never runs in a browser (games are unaffected: they run robot.zig on the CPU); the engine work moves
       to the Vulkan host (enabling those features, the float-atomic capability through the SPIR-V legaliser, push
       constants, compute timestamps); kompute gains native-only primitives that must refuse a web build; subgroup and
       shared-memory paths need explicit CPU-twin code; float atomics make sums order-dependent unless D7 says
       otherwise.
  T2 WEB AND NATIVE FROM ONE PORTABLE SOURCE, the web at a smaller scale (the plan as first drafted): MJW's shapes
     redesigned around WebGPU's guaranteed limits - owner-computes instead of float atomics, 16 KB tiles, 8 bindings,
     128 MB bindings.
     + training wherever Chrome runs.
     - every MJW kernel needs a redesign; slower on native than T1; spv2wgsl's risks (1.3) on the critical path.
  T3 NATIVE FIRST, PORTABLE WHERE IT IS FREE: native-only features allowed where a measurement shows they pay, portable
     code by default, so a web build stays possible later.
     + keeps the door open.
     - two disciplines in one file; every native feature needs a measured case; the web build would still lag.

  PICK T1: it is what "maximal perf right from the beginning" asks for, the web was already accepted as optional for
  training, and it makes MJW's kernels directly portable instead of redesigned. Every S0 item that existed only for the
  browser (spv2wgsl fixes, the 8-binding and 128 MB constraints, the twin's static arenas in wasm) leaves robotgpu's
  path - the spv2wgsl fix still matters for the existing web learner, as its own session.

  DECIDED Oct 31 (D18): T1, NATIVE ONLY, OFFICIALLY. Sections 0, 1.3, 3.1, 6, 8, 9 and 10 revised to match.

### 4.S Which simulator judges a GPU-trained policy (part of D14)

  S1 robot.zig with the zimrphysics bridge, as today: different contacts from training (box floor, geometric friction,
     speculative margin, exact diagonal) - the judge would measure a sim-to-sim gap, not the policy.
  S2 robotgpu's CPU TWIN: the same kernels on the CPU, single- or multi-threaded - identical physics by construction.
  S3 robot.zig in a MuJoCo mode: robot.zig gains the approximate diagonal and consumes robotgpu's CPU-twin
     narrowphase instead of the bridge.

  PICK S2 for the tracker's judge, S3 as G1's comparison rig. The CPU twin is a complete simulator in its own right -
  that is what kompute's one-source model buys.

  REVISED AFTER D1's remark ("For using the robot in a game, I think cpu is ok"): a trained policy is DEPLOYED in
  robot.zig on the CPU. The judge should measure it there, so the pick moves to S3 - robot.zig in its MuJoCo mode (the
  approximate diagonal of D8, MuJoCo's contacts from robotgpu's CPU narrowphase helper, MJW's Newton line search) is
  both the judge and the engine games use; G1 is what makes the two physics the same. S2 (the CPU twin) and S4 below
  stay as fast cross-checks.
  S4 THE GPU ITSELF judges: the same physics as training, and the judge's ~10^5 steps every 30 minutes become a
     fraction of a second - but it is neither the deployment engine nor independent of the training code.

  DECIDED Oct 31 (D14): N1 + S3 - the whole acting loop on the device; the judge is robot.zig in its MuJoCo mode.


## 5. The parity table - every MJW feature, where it stands, which stage brings it

"robot.zig" says what the CPU engine has today; "stage" refers to section 8. DECLINED rows carry their reason; nothing
is dropped silently (G6).

| feature | MJW | robot.zig today | stage |
|---|---|---|---|
| free / ball / hinge / slide joints, qpos0-relative hinges and slides | smooth.py:52-151 | yes | S2 |
| mocap bodies | smooth.py:93-104 | no | S7 |
| body, inertial, geom, site frames | smooth.py:154-232 | bodies, sites (geoms on demand) | S2 |
| camera and light frames (camlight) | smooth.py:867-1035 | no | S9 |
| subtree com, cinert, cdof | smooth.py:680-864 | yes | S2 |
| composite inertia, M with joint armature | smooth.py:1038-1129 | yes | S2 |
| actuator armature and damping folded into joints | util_misc.py:1043-1109 | no | S7 |
| factor M, solve M | smooth.py:1238-1447, 3957-4158 | yes (L^T D L) | S2 |
| com_vel, cdof_dot | smooth.py:2813-2919 | yes | S2 |
| RNE bias forces, gravity as world acceleration | smooth.py:1450-1629 | yes | S2 |
| rne_postconstraint: cacc, cfrc_int, cfrc_ext | smooth.py:2165-2391 | body accelerations only | S7 |
| subtree linvel / angmom | smooth.py:4286-4422 | no | S7 |
| qfrc_applied | types.py:2650 | `applied_force` | S2 |
| xfrc_applied (Cartesian wrenches on bodies) | support.py:277-336 | `applyForceAtPoint` helper | S7 |
| joint damping and stiffness (hinge, slide) | passive.py:86-231 | yes (no polynomial terms) | S2 |
| polynomial damping / stiffness terms | util_misc.py:916-946 | no | S7 |
| ball and free joint springs (quaternion difference) | passive.py:159-225 | no | S7 |
| gravity compensation | passive.py:405-442 | no | S7 |
| fluid forces, inertia-box and ellipsoid models | passive.py:445-703 | no | S8 |
| adhesion | passive.py:706-780 | no | S8 |
| joint transmission, affine force law, ctrl and force clamps | forward.py:2563-2893 | yes | S2 (joint), S7 (rest) |
| dyntypes integrator, filter, filterexact | forward.py:2624-2732 | yes | S7 |
| actlimited, actearly, jnt_actfrcrange | forward.py:2734-2782, 2981-3010 | no | S7 |
| muscle gain, bias, dynamics | util_misc.py:484-746 | no | S8 |
| DC motor (states, back-EMF, cogging, LuGre) | util_misc.py:750-880 | no | S8 |
| multi-input controls (`ctrladr`, `ctrlnum`) | forward.py:2607-2614 | no | S8 |
| transmissions jointinparent, slider-crank, site, site + refsite, body | smooth.py:2922-3538 | no | S7 (site), S8 (rest) |
| fixed tendons | smooth.py:4425-4469 | yes | S7 |
| spatial tendons, sites, pulleys, sphere and cylinder wrapping | smooth.py:4518-4990, util_misc.py:113-481 | no | S8 |
| tendon springs (deadband), dampers, armature, J-dot bias, limits, friction loss | passive.py:234-327, smooth.py:1132-2810 | fixed-tendon springs only | S7 |
| static pair filter (contype/conaffinity, parent, exclude, `<pair>`) | io.py:801-892 | excludes only (bridge) | S5 |
| broadphase NXN with plane / sphere / AABB / OBB tests | collision_driver.py:284-959 | (zimrphysics) | S5 |
| broadphase sweep-and-prune | collision_driver.py:424-792 | - | DECLINED for now: MJW itself only uses it past 250,000 candidate pairs |
| primitive narrowphase, 13 pair types | collision_primitive*.py | (zimrphysics) | S5 (plane pairs first, then the rest) |
| MuJoCo contact parameters (priority, solmix, condim, friction[5], margin, gap) | collision_core.py:294-470 | per-contact softness, one friction | S5 |
| convex narrowphase: GJK, EPA, multi-contact, mesh hill-climb | collision_convex.py, collision_gjk.py | (zimrphysics GJK/EPA) | S8 |
| heightfields | collision_convex.py:62-749 | - | S8 |
| SDF collision | collision_sdf.py | - | S10 |
| flex collision | collision_flex.py | - | S10 |
| surface velocity | collision_driver.py:1217-1233 | - | S8 |
| limits on slide and hinge (both ends, margin) | constraint.py:2134 | yes | S3 |
| limits on ball joints (cone) and tendons | constraint.py:2255, 2396 | no | S7 |
| friction loss on dofs and tendons | constraint.py:1900-2131 | no | S7 |
| equality connect, weld, joint | constraint.py:286-1563 | yes | S7 |
| equality tendon | constraint.py:769 | no | S7 |
| equality flex, flexstrain | constraint.py:963, 1565 | - | S10 |
| contacts frictionless and pyramidal | constraint.py:2534-4300 | pyramidal | S4 |
| elliptic cones, condim 4 and 6, impratio | constraint.py, solver.py:316-883 | no | S7 |
| approximate constraint diagonal (invweight0) | constraint.py:206-283 | exact only | S3 (both, D8) |
| refsafe, direct (negative) solref | constraint.py:142-203 | refsafe yes, direct no | S3 |
| contact recovery-velocity cap | - | robot.zig only (robot.zig:5240-5280) | S3, OFF by default for MJW fidelity |
| Newton, exact line search, MJW's convergence test | solver.py:883-4223 | Newton with backtracking | S3 |
| CG solver | solver.py:3742-3858 | no | S7 |
| PGS solver | - (MuJoCo C has it) | yes | DECLINED unless a parity test needs it |
| noslip | solver.py:4596+ | no | S8 |
| qacc warm start | solver.py:1678-1711 | keys, PGS only | S3 |
| islands (as output) | island.py | no | S8 |
| sleep, wake, compacted solve | sleep.py, solver.py:4371-4534 | no | S8 |
| Euler with implicit damping | forward.py:1330-1424 | yes | S2 |
| RK4 | forward.py:1427-1650 | yes | S7 |
| implicitfast, implicit (velocity derivatives, LU) | forward.py:2360-2416, derivative.py:53-670 | yes | S7 |
| discrete integrator (effective metric, PCG) | derivative.py:3337-4573 | - | S10 (it exists for stiff flex) |
| velocity bound and non-finite containment | - | robot.zig only (robot.zig:6481) | S2, an option |
| sensors, position stage (joint/tendon/actuator pos, ballquat, frame*, subtree com, clock, magnetometer) | sensor.py:728-924 | joint pos, site pos/quat | S7 |
| sensors, velocity stage (velocimeter, gyro, joint/tendon/actuator vel, ballangvel, frame lin/ang vel, subtree) | sensor.py:1165-1679 | partly | S7 |
| sensors, acceleration stage (accelerometer, force, torque, frame acc, actuator/joint/tendon force) | sensor.py:1786-2125 | accelerometer, actuator force | S7 |
| touch, contact sensors, limit pos/vel/frc | sensor.py:2128-2931, 398-1959 | no | S7 (touch, limits), S8 (contact) |
| geom distance/normal/fromto, insidesite, camprojection | sensor.py:731-917 | no | S8 |
| rangefinder (rays) | sensor.py:983-1046 | no | S8 |
| tactile | sensor.py:2220-2457 | no | S10 |
| sensor cutoff | sensor.py:61-125 | no | S7 |
| ctrl and sensor delays, sample-and-hold (history) | history.py | no | S8 |
| energy (potential, kinetic) | sensor.py:3151-3521 | `energy` | S7 |
| inverse dynamics (`mj_inverse`, discrete-time variant) | inverse.py | `inverseDynamics` (smooth part) | S7 |
| set_const (subtree mass, geom bounds, invweight0, lengthrange) | set_const.py | subtree mass | S1 (host side, at pack time) |
| per-world model parameters (domain randomisation) | io.py:321-344 | no | S6 |
| get/set state, reset, keyframes | support.py:687-1027, io.py | `State`, `reset`, `applyKeyframe` | S6 |
| rays (`ray`, `rays`) | ray.py | no | S8 |
| batch rendering | render.py | (zimr's renderer, CPU state) | S9, rasterised (2.12) |
| overflow bitmask | types.py:203-249 | asserts | S1 |
| plugins and Python callbacks | types.py:1221-1241 | - | DECLINED: in Zig a user writes kernels in the same module |
| flex bodies (cloth, soft) | passive.py, collision_flex.py | - | S10, or DECLINED by decision |


## 6. The architecture - the picks, assembled

Everything here follows from the picks in section 4; if a decision in section 12 goes the other way, the matching
subsection is rewritten.

### 6.0 What "zimr style" means for this file

The house rules, applied: verbose names and a named boolean for every non-trivial condition; `out_` parameters;
`assertf` on every precondition at the top of a host function, expensive checks behind `comptime assert.allow_assert`;
no `anytype` unless genuinely generic, with a comptime test pinning what it accepts; `Vec`/`Quat` from zm for every
vector, quaternions (x, y, z, w) as robot.zig stores them; declarations dependency-first; lines <= 120. The
architecture lives in a `//!` doc atop `robotgpu.zig`, not in this plan. Every capacity refuses an overflow BY NAME
(`kit_mlp.KitLayout.checkFitsKit`'s pattern) at layout time, and every per-world overflow at run time sets a bit the
host reads and REPORTS - never a silent clamp (claude.md: "a silent clamp is a silent bug"). Kernels are lean
(`installKernelLean`), take a raw id, guard their own range, and keep every barrier loop bounded by a uniform.

### 6.1 Files and the import closure

    src/robotgpu.zig            THE SIMULATOR. The kernel module (Buffers, Params, kernels, installKernels), the
                                Layout, the packing from rbt.Model, the step Program, the CPU twin's harness, the
                                MuJoCo narrowphase and solver maths. Imports: std, zm, kompute, zn (Rng), robot.zig.
                                Not zimrphysics: its narrowphase is not shader-safe (4.K); it stays a CPU oracle.
    src/robotgpu_sizes.zig      arena lengths for the native trainer and lab (desktop GPUs, GBs of storage);
                                robotgpu_sizes_test.zig (a few worlds, within lavapipe's 128 MB, for test-fast and the
                                sandbox) copied in under that name by build.zig - zn_mlp_sizes' mechanism.
    src/robotgpu_host.zig       ENGINE SIDE, the only file touching a queue: `Sim` = Compute(robotgpu) on the native
                                Vulkan host + the program run as one batch + uploads, readbacks, overflow reports,
                                per-stage timings. Native only (D18): it refuses a web build at compile time.
    src/robotgpu_tests.zig      a test-fast root importing robotgpu.zig by path: layout, packing, the CPU twin's
                                parity with robot.zig, MuJoCo fixtures, determinism.
    src/gpu/track_device.zig    (S6) the tracker's device kernels - servo, features, rewards, resets, ring records -
                                binding robotgpu's and the learning kit's buffers (6.12).
    examples/robotgpu_lab/      a native Windows app: N worlds on the GPU, a few drawn, the GPU-versus-twin check
                                and the per-stage timings on screen (native only, D18).
    scripts/robot_oracle.py     extended with collision, constraint-row and solver fixtures (G3).

### 6.2 Buffers, arenas and the layout

    pub const Buffers = extern struct {
        model_f: [sizes.model_f]f32,   // real-valued model constants; every Vec on a 4-float boundary
        model_u: [sizes.model_u]u32,   // topology and index tables
        batch_f: [sizes.batch_f]f32,   // per-world model parameters (domain randomisation, MJW's `field[w % n]`)
        world_f: [sizes.world_f]f32,   // per-world state and everything derived from it
        world_u: [sizes.world_u]u32,   // per-world integers: counts, row kinds and sources, contact pairs, overflow bits
        efc_f:   [sizes.efc_f]f32,     // per-world constraint rows: J, pos, margin, D, aref, vel, force
        scratch: [sizes.scratch]f32,   // per-world solver workspace: H and its factor, line-search state
        io:      [sizes.io]f32,        // the host's window: uploads (ctrl, resets) and small readbacks
    };

Eight fields - compute_host's ceiling. A `Layout` (an extern struct of named u32 offsets, flat, no arrays - std140
uniform rules, Vulkan's as WGSL's, pad nested structs and array elements to 16 bytes) rides inside `Params` with the counts (nworld, nbody,
njnt, nv, nq, ngeom, nu, na...), the step options (timestep, gravity, iterations, tolerances, flags) and the feature
bits. Per-world arrays are WORLD-MAJOR by default: element i of world w at `offset + w * stride + i`, the stride
derived from the counts (padded to 4 floats), behind one accessor so the element-major alternative is a comptime
switch (4.C). Batched model parameters carry a count: `batch_f[offset + (w % count) * stride + i]`, count 1 until a
caller randomises.

`layoutFor(model, capacities)` computes every offset, checks every arena against its sizes-file length and refuses by
name (`error.WorldStateTooSmall`...); the host prints which arena, how much it needed and what it had.

### 6.3 Packing - host side, once per model

`pack(model, layout, out_model_f, out_model_u)` turns `rbt.Model` into the two model arenas and computes what MJW's
io.py and set_const compute:

  - TOPOLOGY: verify depth-first body order (contiguous subtrees - required by K3 and by the chain tables; refuse
    `error.BodiesNotDepthFirst` if not); body_subtree_count; per-body root; per-body dof CHAIN (root to body) and its
    length; a per-body dof-ancestor bitmask (nbody x ceil(nv / 32) words) for gathers; M's sparsity from robot.zig's own
    tables.
  - CONSTANTS AT qpos0 (MJW's set_const, by robot.zig's CPU functions): dof_invweight0 (diag M^-1), body_invweight0
    (mean translational and rotational diagonal of J M^-1 J^T at the body's com), geom bounding radii and boxes.
  - COLLISION: the static candidate pairs (MuJoCo's contype/conaffinity, weld, parent and exclude filters, `<pair>`
    overrides), grouped by pair type; each pair's fixed contact-slot base and its type's maximum contact count; each
    pair's mixed contact parameters (recomputed in-kernel only for batched geoms).
  - THE PROGRAM's shape: which kernels exist for this model (no box-box kernel without boxes).

### 6.4 The step program

The step is DATA: `program(layout)` returns the ordered dispatches (kernel id, thread count), and `robotgpu_host.Sim`
runs them as ONE batch - one params value, one compute pass, no per-dispatch uploads, the barrier zimr's Vulkan host
puts before every dispatch doing all the synchronising (each dispatch sees the previous one's writes). Several steps can share a submission.

SUPERSEDED BY D5 (Oct 31): the program is MJW's kernel list from the start - kinematics per (world, branch); inertial,
geom and site frames per (world, element); subtree com and composite inertia as contiguous-range sums per (world,
body); cinert per body; cdof per joint; M's rows per (world, dof); the factor per tree block (scalar per thread, a
cooperative block for a mid-size tree, MJW's level schedule for a large one - Geno's 75-dof tree); broadphase per
(world, pair) then narrowphase per pair type; constraint rows per type and per (world, source); the contact Jacobian per
(world, dof block); com_vel and RNE's acceleration pass per (world, branch), its forces per (world, body), the subtree
force sums, the projection per (world, dof); passive per joint; actuation per actuator; qfrc per dof; the solver's
rounds (6.8); the integrator's per-dof and per-joint kernels. Roughly 40-60 dispatches before the solver, plus the
solver's per round. The per-world-first program below is kept as the reference it replaced; its kernels survive only
where MJW itself uses one thread per world (the world-root folds, the serial labelling steps).

The superseded first program, every stage in its simplest correct shape (4.B), for Geno:

    POSITION      kinematics      nworld            body frames, inertial frames, sites, geom frames
                  com_pos         nworld            subtree com, cinert, cdof (robot.zig's order)
                  crb_mass        nworld            composite inertias, the rows of M
                  factor_m        nworld            L^T D L
    COLLISION     collide_<type>  nworld x pairs    bounding test + narrowphase into the pair's fixed slots, per type
                  contacts        nworld            compaction in pair order, overflow bit
    CONSTRAINTS   rows_plan       nworld            counts and offsets: equalities, friction loss, limits, contacts
                  rows_<kind>     nworld x sources  J, pos, margin, D, aref, vel per row
    VELOCITY      com_vel         nworld            cvel, cdof_dot
                  passive         nworld x njnt     springs, dampers
                  rne             nworld            bias forces
    ACTUATION     actuation       nworld x nu       forces, act_dot
                  smooth          nworld x nv       qfrc_actuator by gather, qfrc_smooth
                  smooth_acc      nworld            qacc_smooth through the factor
    SOLVE         newton          nworld            I1, iterations inside
    INTEGRATE     euler           nworld            implicit damping, act, qvel, qpos, quaternions, warm start

About 20 dispatches a step for Geno, against MJW's 100-300 launches - and every one of them a pure function of the
arenas, so the CPU twin runs the same list in a loop. Widening a stage later (K3 subtree sums, per-dof rows, a
workgroup solve) changes one entry, behind a flag, measured against the entry it replaces.

### 6.5 Smooth dynamics

Each stage's per-element arithmetic is robot.zig's (4.A): a body's pose from its parent and joints with the off-centre
correction; `Inertia.rotated` and `translate`; `dofAboutAxis`; `crossMotion` / `crossForce` / `Inertia.mul`; the
`rotationTriple` rule; a row of M; the L^T D L elimination; `solveM`; gravity as the world's acceleration. With MJW's
shapes (D5) the traversals differ from robot.zig's loops - contiguous-range sums instead of backward folds, branch
threads instead of one forward pass - so the twin agrees with robot.zig to f32 TOLERANCE (G1), while the shared
per-element functions keep every formula identical. The twin is still bitwise-deterministic run to run, and it is the
GPU's oracle (G2).

Hinge rotations call sin and cos, which zimrmath computes differently on the GPU (section 1.3, item 4): the GPU matches
the twin to a few ULP per step, never bitwise, and long rollouts are compared statistically, not trajectory by
trajectory.

### 6.6 Collision

  - PAIRS are static (6.3), grouped by type. One kernel per pair type present in the model, one thread per (world,
    pair): the broadphase test MJW uses (plane: the other geom's distance along the normal against its bounding radius
    plus margins; otherwise bounding spheres), then the narrowphase function, then up to the type's maximum contacts
    written into the pair's own slots with a count. No atomics; the slot of every contact is known before the step.
  - NARROWPHASE FUNCTIONS are ports of MJW's `collision_primitive_core.py` (itself MuJoCo's C) into robotgpu.zig as
    value functions over `Vec`: inputs by value, a fixed-size result struct returned (no pointer parameters - section
    1.3). Geno needs three: plane-capsule (2 contacts), plane-sphere (1), plane-box (up to 8 corners, depth-filtered).
  - COMPACTION, one thread per world: walk the pairs in order, copy active contacts into the world's list
    (`nconmax` long), set the count, set the overflow bit if it does not fit - a deterministic order with no sort.
  - CONTACT RECORD: position, normal, first tangent (the second is their cross product), distance, include-margin,
    condim, the pair index (which locates friction, solref, solimp), the geom ids.
  - THE SAME FUNCTIONS ON THE CPU feed robot.zig: a host helper runs them per pair and pushes `rbt.Contact`s, so
    robot.zig can run MuJoCo's contacts without zimrphysics - G1's comparison rig and the judge's alternative (4.S).
  - MuJoCo's margin and gap: MJW sums both geoms' margins and treats gap as an extra detection band; MuJoCo C may take
    the max and set includemargin = margin - gap (unverified). If MJW's rule is deliberate, MJW's wins and gets an MJW
    fixture (D16); if it is an MJW bug, MuJoCo C's.

### 6.7 Constraints

`rows_plan` (one thread per world) counts equalities, friction-loss dofs, active limits (both ends, margin) and contact
rows (1 frictionless, 2(condim - 1) pyramidal, condim elliptic), writes each source's first row and the world's ne,
nf, nl, nefc, and flags an overflow past njmax. The row builders then run per (world, source) and write: J (DENSE
nv_pad-wide rows first - robot.zig's form, so its row functions apply directly; CHAIN-SPARSE rows, values along the
union of the two bodies' dof chains, when the memory budget asks - for Geno that is at most 27 values a row instead of
76), pos and margin, the diagonal (approximate from the invweight0 constants, or exact by a per-row solve - D8), D and
aref through ONE shared function holding MuJoCo's `kbimp` and `efc_row` arithmetic (refsafe, direct solref, the
impedance sigmoid), and vel = J qvel. The pyramid's edge directions n +/- mu_k t_k come from the same function robot.zig's
`addContactRows` uses.

### 6.8 The solver

DECIDED (D9): I2 - ONE WORKGROUP PER WORLD, every Newton round inside ONE dispatch. The workgroup holds its world's
Hessian (nv_pad x nv_pad - Geno's 76 x 76, 23 KB) and the solve's vectors in shared memory; its lanes stride over the
world's rows for the line search's per-row quadratics, the row states and forces, and J' D J's assembly; reductions go
through subgroup operations and shared memory; the Cholesky is right-looking, a barrier per column; every loop with a
barrier is bounded by a uniform (nv_pad, njmax, opt.iterations) and masked by the world's own counts; the round loop
ends for the whole workgroup when its world's convergence flag (read back from shared memory after a barrier) says so.
Its CPU twin is an explicit per-world path calling the same per-row and per-entry functions. MJW's per-round dispatches
(I3) and CG (I4) are measured beside it. What follows was written for the first pick (I1) and describes the algorithm,
which is unchanged:

I1 first: one thread per world runs MuJoCo's primal Newton to convergence inside one dispatch. Scratch holds qacc, Ma,
Jaref and jv per row, the per-row quadratic coefficients, search, gradient, and H (nv_pad^2) with its Cholesky factor.
The algorithm is MJW's (section 2.8): warm start from last step's qacc; exact line search on the piecewise-quadratic cost
along the search direction (1-D Newton steps with bracketing, `ls_iterations`, `ls_tolerance`); row states (quadratic,
linear, satisfied, cone) and forces; gradient M qacc - qfrc_smooth - J' f; H = M + J' D_active J; Cholesky; search =
-H^-1 grad; MJW's convergence test (scaled improvement, gradient or Newton decrement under tolerance, or a zero step),
iterations bounded by `opt.iterations`. Outputs: qacc, row forces, qfrc_constraint, iteration count, the warm start.
Cost for Geno, standing (64 rows): about 130k multiply-adds an iteration, three or four iterations warm-started.

Then I2 when the per-stage times say so: the same algorithm with a workgroup per world - rows strided over lanes,
reductions through shared memory, H assembled in parallel, a right-looking Cholesky with a barrier per column - its
CPU path the I1 code. CG (I4) beside it for large nv.

### 6.9 Integrators

`euler`, one thread per world: if any dof is damped, factor M + h diag(B) in scratch and solve for the damped
acceleration from M qacc (MuJoCo's Euler, robot.zig's `dampedVelocityStep`); advance activations; qvel += h qacc;
the velocity bound (robot.zig's option, off for MJW fidelity); qpos by robot.zig's `integratePos` (quaternions on the
sphere); normalise; time; save the warm start. RK4 and implicitfast / implicit follow in S7, the latter through
robot.zig's own `smoothVelDerivative` / `rneVelDerivative` arithmetic and an LU per world.

### 6.10 Actuation, passive forces, tendons, sensors

Actuation per (world, actuator), with `qfrc_actuator` GATHERED per (world, dof) through a static dof-to-actuator
transpose (no float atomics); joint springs and dampers per (world, joint); fixed tendons per (world, tendon) with
their force gathered the same way. Sensors run per (world, sensor) at their stage, each kind a branch in one kernel
per stage (MJW's split), the acceleration-stage ones after the solve with the cacc pass they need. All of S7.

### 6.11 The host API

robotgpu.zig (no device): `Capacities`, `Layout`, `layoutFor`, `pack`, `program`, decoders that read a world back out of
an arena image (tests, drawing), and the CPU narrowphase helper. robotgpu_host.zig (device):

    var sim: robotgpu_host.Sim = try .init(gpa, device, queue, &model, .{ .nworld = 4096, .nconmax = 48, .njmax = 192 });
    sim.uploadCtrl(...);               // or adopted by the tracker's kernels, 6.12
    sim.resetWorlds(mask, qpos, qvel); // masked, on the device
    sim.step(steps);                   // one batch per step
    sim.readSummary(...);              // a small range, a frame late; overflow bits checked and reported every read

### 6.12 The tracker on the device (S6)

The learner never reads q or v (1.2) - it needs features, actions, frame indices and episode flags, all functions of
the simulator's state plus bookkeeping. So the whole acting loop moves onto the device:

  - THE BUFFERS MEET BY ADOPTION. A new compute_host option lets a module bind ANOTHER module's GPU buffer as one of its
    fields (`.adopt = .{ .sim_world = sim.compute.fieldBuffer(.world_f) }`). The tracker's kernel module declares
    fields with robotgpu's arena types (same sizes file) and the kit's `acts`, adopts them, and reads robotgpu's state
    through robotgpu.zig's accessors, imported as a library. On the CPU twin, adoption is copy-in / copy-out around the
    run - the same semantics. (zn_mlp already uses 7 of its 8 fields, so "one module for everything" is not available.)
  - THE TRACKER'S KERNELS (`src/gpu/track_device.zig`): the servo (`stableSpringAccel` per dof, then
    `floatingBaseTorques` - dense M from the packed rows, the 6x6 root solve, tau = M a + c - into qfrc_applied), the
    387 `local()` features written straight into the ring's slot in `acts`, reward and termination (the tracking
    error, head height), resets from the reference tables already in `acts` (qpos and qvel from clip frames, then the
    position stage and `restOnFloor`'s lift for the reset worlds), pushes from a counter-based `zn.Rng` stream per
    world, frame and segment counters.
  - THE POLICY ACTS ON THE DEVICE: zn_mlp's dense layers over nworld rows, the exploration noise by its existing hash,
    the actions where the servo kernel reads them.
  - THE HOST keeps what is genuinely sequential or slow-moving: window sampling (from flags read back a frame late),
    curriculum weights, logging, and the judge - robot.zig in its MuJoCo mode, the engine games deploy on (D14), held to
    training's physics by G1.
  - A FRAME is then [robotgpu step] + [tracker kernels] + [policy forward], k times, then the learner's updates - no
    upload per step at all.
  - BEFORE ANY LEARNING: the servo baseline (MTTF 1.532 s on dance_5_15 today) re-measured on robotgpu's physics. The
    physics changes (plane, MuJoCo friction rule, margins, diagonal, warm start - 1.2) mean the tracker's tuning is
    re-validated, not assumed.

### 6.13 Rendering and rays

S2's lab app reads a few worlds back and draws them as today's robot demos do. S9 draws many worlds straight from the
device: instanced primitives whose transforms a vertex shader reads from robotgpu's buffers (adoption again), RGB,
depth and segmentation per camera - the rasteriser MJW's study recommends over porting its ray tracer. Rays
(`ray`, `rays`, rangefinders) are compute kernels in S8, brute force over geoms first.

### 6.14 Tests and tooling

  - test-fast (`robotgpu_tests.zig`, the CPU twin, a few worlds from the test sizes file): layout and its refusals;
    pack and decode; every stage equal to robot.zig within f32 tolerance (G1, D5); MuJoCo fixtures for collision,
    rows and solver; determinism (the same run twice, bitwise; a world's result independent of nworld and of its
    neighbours); overflow bits set and reported.
  - vk-host-test: every kernel on the device against its twin, one step from identical inputs, with ULP bars -
    lavapipe in the sandbox, Simon's GPU on Windows.
  - the lab app (native): the same device check on Simon's GPU, and the throughput on screen.
  - `robotgpu-bench` (native, headless): steps per second at nworld 256 / 1,024 / 4,096 / 8,192 for Geno, the
    humanoid and the Go1, per-stage times from compute timestamps (S0 adds them), the CPU fleet's number beside it.


## 7. What robotgpu asks of robot.zig and its neighbours

robot.zig's public API, `Data`, `State`, the stage watermark and every default stay as they are. The changes:

  R1 SHARED PER-ELEMENT FUNCTIONS (S1, decision D1). Pure `pub fn`s, values in and a value out, for: a body's pose
     from its parent's and its joints' (kinematics' inner body, with the off-centre correction); a body's com-frame
     inertia (`Inertia.rotated` and `translate` - already pure); a joint's cdof (`dofAboutAxis`); one entry of M; one
     body's RNE force; the rotation-triple rule; a limit row's distance and sign; a pyramid edge's direction; a row's
     reference acceleration and regulariser (`Impedance.at` is pure; the k, b, refsafe and R arithmetic of
     `projectConstraints` becomes one function); quaternion integration (`rotateQuatByAngularVel`); a joint's share of
     `differentiatePos`. Loops whose arithmetic is delicate (the L^T D L elimination, `solveM`) are shared as `inline`
     functions over an accessor, decided one function at a time. GATE: robot.zig's suite, the robot family's ~760
     tests and the benches' numbers are BIT-IDENTICAL before and after.
  R2 IMPORTABLE BY A KERNEL BUILD (S0.3): `wants_robot`, or the `robot_math.zig` split (4.A).
  R3 MUJOCO'S COLLISION FIELDS ON THE MODEL (S5): `GeomSpec` gains contype, conaffinity, condim, priority, solmix,
     solref (`Softness`), solimp (`Impedance`), margin, gap and a three-number friction (slide, spin, roll - today's
     `friction` its first); `GeomShape` gains `plane` (massless) and later `ellipsoid`; geoms on the world body
     (static scenery) are allowed; `ModelSpec.pairs` mirrors `<contact><pair>` (excludes already exist). robot.zig
     ignores all of it except that a plane has no mass - it still does no collision.
  R4 BODY ORDER (S1): `Model.body_subtree_count`, and a build-time guarantee of depth-first order (a check, or a
     canonical renumbering inside `buildFromSpec`) - contiguous subtrees are what the GPU's tree sums rely on.
  R5 SOLVER OPTIONS (S3, D8 and D10): `SolverOptions.diagonal: .exact | .approximate` with the invweight0 constants
     computed at build from the model's own functions at qpos0; `Data.qacc_warmstart` (carried by `State`) and Newton
     starting from it;
     Newton's line search and convergence test as MJW's (an option beside today's backtracking); the contact
     recovery-velocity cap as an option. robot.zig's defaults unchanged, so no demo or test moves.
  R6 robot_mjcf (S5): import the collision fields, world planes and `<pair>` instead of dropping them
     (robot_mjcf.zig:208-221); robot_geno writes the floor plane and the contact parameters Geno is meant to have
     (today's effective floor friction is 1.41 by the bridge's geometric mean; MuJoCo's rule would make it 2.0 - D12).


## 8. The work, in stages

Each stage: what is built, what checks it, what it hands on. A stage is DONE when its gate passes on lavapipe and on
Simon's GPU under Vulkan (native only, D18). Every turn inside a stage ends with its targeted tests.

**S0 SPIKES AND ENGINE PREREQUISITES - no physics; retire section 1.3's and 3.1's risks first. Native only (D18).**

  S0.1 THE NATIVE FEATURES: the Vulkan host queries and enables the subgroup arithmetic / shuffle / ballot operations
       and reads `maxComputeSharedMemorySize`, `maxStorageBufferRange` and `maxPushConstantsSize` into `Gpu`; kompute
       gains subgroup reductions (inline SPIR-V; the capability declared by zimr's legaliser, `spv_vulkan.zig`),
       refusing a web build at compile time. Float atomics are queried and recorded only (D7). Check: a probe kernel's
       subgroup and shared-memory reductions agree with the twin within the reordering tolerance AND repeat bitwise run
       to run on lavapipe and Simon's GPU (D7's condition for using them); the limits printed and recorded here.
  S0.2 THE MATHS PROBE: `robotgpu_probe`, a kernel calling every zimrmath function robot.zig's per-element maths uses
       (qmul, rotate, conjugate, quatFromNormAxisAngle, normalize, cross, dot3, Vec arithmetic; `Inertia.rotated`,
       `translate`, `mul`; `crossMotion`, `crossForce`) over a table of inputs, compiled to SPIR-V, through the
       legaliser, against the twin with ULP bars on lavapipe and Simon's GPU - the tree's first `Vec`/`Quat` compute
       kernel.
  S0.3 robot.zig in a kernel build (`wants_robot`), or the `robot_math.zig` fallback.
  S0.4 compute_host: (a) ranged readback into a small staging buffer, and no whole-`Buffers` heap mirror for big
       modules; (b) buffer ADOPTION (6.12); (c) dispatches past 65,535 workgroups (a 2-D dispatch, kompute deriving the
       linear id); (d) compute timestamps on the native host (`vkCmdWriteTimestamp` per stage); (e) optional push
       constants for per-dispatch values, so MJW's level-scheduled kernels stay inside one batch.
  S0.5 THE WORKGROUP SHAPE: a cooperative kernel with barrier loops bounded by uniforms and its Hessian in shared memory
       - a per-world Cholesky of random 76 x 76 SPD matrices, the solver's skeleton - against its CPU path, on
       lavapipe and Simon's GPU.
  S0.6 THE MEMORY ENVELOPE: Geno-sized arenas at nworld 4,096 (and 8,192) on Simon's GPU, a few worlds on lavapipe;
       the device's reported limits recorded in this file.

  MOVED OUT: the spv2wgsl fixes (pointer parameters, missing opcodes, `--strict` for compute) concern the existing web
  learner, not robotgpu - their own session (proposed Oct 31).

**S1 FOUNDATIONS.** robot.zig R1, R2, R4 under the bitwise gate; robotgpu.zig's Buffers, Params, Layout, sizes files,
`layoutFor` with refusals by name, `pack` (topology, chains, M sparsity, invweight0, bounds), `program`, overflow bits;
`robotgpu_host.Sim`; `robotgpu_tests.zig` in test-fast. Check: pack-then-decode reproduces every model field; each
refusal fires by name; an empty program runs on the CPU and the GPU.

**S2 SMOOTH DYNAMICS, no constraints.** kinematics, com_pos, crb_mass, factor_m, com_vel, rne, passive (joint
damping and stiffness), qfrc_applied, actuation (joint transmission, the affine law, the filters), qacc_smooth, Euler
with implicit damping, integratePos, the velocity bound - in MJW's kernel shapes (D5). Check: G1 TO TOLERANCE, the twin
against robot.zig stage by stage and step by step, on the single and double pendulum, the free body, the ball chain,
the KUKA, the humanoid and Geno in free fall; G2 one step with ULP bars on every device; energy behaviour matching
robot.zig's damping tests; Geno in free fall on the device; the first nworld sweep of throughput.

**S3 CONSTRAINTS AND NEWTON.** Limit rows; row parameters with both diagonals; the equality rows robot.zig has
(connect, weld, joint coupling); Newton I1 with MJW's line search and convergence; qacc warm start; robot.zig's R5 so G1
compares like with like. Check: the KUKA on its limits and robot.zig's constraint tests replayed on the twin -
converged qacc and forces equal within the solver tolerance; the KKT conditions at the answer (robot.zig's own test);
MuJoCo fixtures for pos, D and aref with the approximate diagonal (G3).

**S4 CONTACTS AS INPUT - the parity rig.** Per-world contacts uploaded from robot_physics's bridge, pyramidal rows,
Newton. Check: the Go1 standing, the humanoid falling onto its floor and Geno standing - robotgpu against robot.zig
fed the SAME contacts, step by step for N steps within tolerance. The last comparison before collision itself moves.

**S5 PRIMITIVE COLLISION.** robot.zig R3 and R6; the static pairs; plane-sphere, plane-capsule and plane-box first
(everything Geno needs), then sphere-sphere / capsule / box, capsule-capsule / box, box-box, plane-cylinder /
ellipsoid; MuJoCo's contact parameters; compaction; the CPU helper feeding robot.zig the same contacts. Check G3: every
pair type against MuJoCo fixtures over randomised poses (count, positions, normals, distances); a box dropped on a
plane coming to rest; Geno standing still for 10 s, with MuJoCo C's creep as the bar; throughput with contacts.

**S6 THE TRACKER ON THE DEVICE.** Adoption (S0.4 b); `src/gpu/track_device.zig`; the policy acting on the device;
`robot_track_resident` gaining the device simulator beside the CPU fleet; the judge on robot.zig in its MuJoCo mode
(D14). Check: a
zero action reproduces the reference (robot_track.zig:3671's known answer, on the device); the servo on Geno without
gravity reaches every joint within 1% in 0.5 s (robot_geno.zig:4401's); the SERVO BASELINE re-measured on robotgpu's
physics before any learning; then the A/B that decides G4 and G5 - the night configuration on the CPU fleet (32
characters) against the device (1,024-4,096 worlds), wall-clock to a judged MTTF.

**S7 MJW PARITY I - the rigid-body set.** Sensors (non-ray, all three stages, cutoff); xfrc_applied; mocap; ball and
free springs, polynomial damping and stiffness; gravity compensation; actuator dyntypes, gains, biases, clamps,
actlimited, actearly, actfrcrange, armature and damping from actuators, site transmission; fixed tendons (springs,
dampers, limits, friction loss, armature, J-dot bias, actuators); equality tendon; friction loss; ball limits; elliptic
cones, condim 4 and 6, impratio; CG; RK4; implicitfast and implicit; subtree velocities; energy; inverse dynamics;
per-world model parameters; reset, keyframes, get and set state. Check: G3 fixtures per feature; G1 wherever robot.zig
has the feature.

**S8 MJW PARITY II.** Convex collision (GJK, EPA, multi-contact, mesh hill-climbing; cylinders, ellipsoids, meshes);
heightfields; spatial tendons and wrapping; slider-crank, joint-in-parent and body transmissions, adhesion; muscles, DC
motors, multi-input controls; fluid forces; noslip; rays and rangefinders; geom-distance, contact and touch sensors;
history (delays, sample-and-hold); islands and sleep; surface velocity. Check: G3.

**S9 RENDERING.** Many worlds drawn straight from the device (6.13). Since the GPU is for training (D1), this is for
WATCHING training worlds; MJW's batch renderer for vision-based policies is out of scope unless a task asks for it.

**S10 FLEX, SDF, THE DISCRETE INTEGRATOR, TACTILE SENSORS** - or declined (D15).


## 9. Risks, and what retires each

  - PHYSICS DRIFT FROM THE TRACKER'S TUNING (1.2 b) -> S6 re-baselines the servo before any learning; every
    MuJoCo-versus-robot.zig difference is an option on both engines, so a tuning can be reproduced either way.
  - NATIVE FEATURES MISSING ON SIMON'S GPU (float atomics, subgroup arithmetic, shared memory size) -> S0.1 queries
    them first; every kernel has a feature-free path (deterministic gathers, shared-memory reductions) so a missing
    feature costs speed, not correctness.
  - ZIG'S SPIR-V BACKEND AND THE LEGALISER (no `@atomicRmw` in the backend; capabilities for float atomics and
    subgroups declared by hand; Vec/Quat code never compiled for compute before) -> S0.1, S0.2, S0.5, before any
    physics.
  - DISPATCH COST: MJW's shapes mean 40-60 dispatches a step plus the solver's rounds, each behind a full barrier on
    zimr's Vulkan host -> one batch per step, several steps per submission, per-stage timestamps (S0.4 d) to see what
    the barriers cost; fusing neighbouring kernels where they show.
  - THE WEB IS GONE FOR TRAINING (D18): a phone or a browser cannot train with robotgpu; they keep robot.zig on the CPU.
    Accepted by Simon.
  - TWIN AND GPU ARITHMETIC DIFFER (zimrmath's is_gpu branches, FMA) -> one-step comparisons with ULP bars; long runs
    compared by statistics (resting drift, survival), never trajectory against trajectory.
  - PER-WORLD SOLVER COST at nv 75 (a 75 x 75 Cholesky per Newton iteration) -> measured in S3; I2 and CG are the
    planned answers; chain-sparse J cuts H's assembly.
  - DETERMINISM IS PER DEVICE: repeated runs on one GPU are bitwise, across GPUs or twin-versus-GPU they are not ->
    replays and finite differences stay on one device; tests say which kind of equality they assert.
  - THE SCALE OF "ALL OF MJW": 62k lines of Python behind an estimated 25-40k lines of Zig -> staged so the tracker
    benefits at S6, every later row declinable by decision.
  - THE robot.zig REFACTOR MOVES A NUMBER -> the bitwise gate; revert, do not explain.
  - NO GPU TIMING TODAY -> S0.4 d before any claim of speed.
  - GENO'S BODY ORDER may not be depth-first (synthesized, not parsed) -> S1 checks every fixture model; a canonical
    renumbering at build if needed.


## 10. What it should cost - estimates, to be replaced by measurements

Per Geno world-step, counted on the per-world shapes (the work is the same in MJW's shapes, only spread wider):
kinematics through the factor ~50k multiply-adds; collision ~2k; rows ~50k
(dense J); RNE and passive ~10k; Newton ~130k an iteration x 3-4 warm-started; Euler's damped refactor ~35k. About
0.6 million multiply-adds, three quarters of them Newton's. At 4,096 worlds that is 2.5 GFLOP a step: on a desktop GPU
at the 2-5% of peak that latency-bound per-thread code reaches, 2-6 ms a step, or 0.7-2 million world-steps a second.
The CPU fleet: Geno's step ~0.6 ms on a phone, a few thousand steps a second per desktop core. So G4's 20x holds with
margin before I2 or CG, if the estimate is within a factor of three. These per-thread figures are the CONSERVATIVE
bound: MJW's shapes (D5) spread the same work over many more threads, and native shared memory and subgroups (D18) let
the solver's Hessian and reductions run cooperatively.

Memory with dense J and njmax 128: ~100 KB a world (25k floats), 400 MB at 4,096 worlds, 800 MB at 8,192 - within a
desktop GPU's memory and its `maxStorageBufferRange` per arena (D18). Chain-sparse J brings it to ~70 KB a world.

These are arithmetic, not measurements; the journal records what the devices say.


## 11. Where things live

  - this plan: `src/notes/robotgpu_plan.md` - decisions, status, journal
  - the simulator: `src/robotgpu.zig` (its `//!` doc is the architecture), its sizes files, `src/robotgpu_host.zig`
  - tests: `src/robotgpu_tests.zig` (test-fast), vk-host-test entries, `examples/robotgpu_lab` (native app)
  - the tracker's device side: `src/gpu/track_device.zig`; `robot_track_resident.zig` gains the device simulator
  - fixtures: `scripts/robot_oracle.py` -> `src/tests/fixtures/robot/`
  - the reference, read-only: MuJoCo Warp at `C:\Users\sclav\Downloads\mujoco_warp-main\mujoco_warp-main` (Oct 31)


## 12. Decisions - asked one at a time

Each is asked with its options, their pros and cons and the recommendation; the plan is revised after each answer, and
the whole list confirmed before the plan is called final. Nothing is implemented before Simon says go.

DECISIONS TAKEN:

  - D1 (Oct 31): A2, SHARE FORMULAS - robot.zig's per-element arithmetic becomes pure functions both engines call.
    With it, Simon's statement of purpose: "I wanted the mocap trainings to theoretically work on web and native, but I
    can accept that we might have less memory on web. If not possible I will accept that training robot tracking will
    only happen on native. For using the robot in a game, I think cpu is ok. Gpu is really just to accelerate
    training." Folded into section 0 (what the GPU is for), G4, and section 9's browser-memory risk.
  - D15 (Oct 31): R1, TRACKER FIRST, THEN FULL PARITY - S0-S6 for Geno's training, then S7, S8, S9 (watching training
    worlds), S10 (each row built or declined with a reason when reached).
  - D8 (Oct 31): H3, BOTH DIAGONALS ON BOTH ENGINES - the GPU defaults to MuJoCo's approximation (invweight0 at qpos0),
    robot.zig keeps exact as its default; the exact path stays selectable on the GPU.
  - D12 (Oct 31): L1, MUJOCO'S MATERIAL - per-geom priority, solmix, condim, friction[3], solref/solimp, margin/gap and
    `<pair>` on robot.zig's Model (R3), imported by robot_mjcf (R6), mixed as MuJoCo does; Geno's XML states its values.
  - D5 (Oct 31): B2, MUJOCO WARP'S SHAPES FROM THE START - "We want maximal perf right from the beginning." G1 becomes
    tolerance-based from the start; section 6.4's program becomes MJW's kernel list. Simon added: "Maybe we could
    officialize that this will never work on web" - opened as D18, asked next.
  - D18 (Oct 31): T1, NATIVE ONLY, OFFICIALLY - Windows on Vulkan for training, lavapipe for the sandbox; float
    atomics, subgroups, device-sized shared memory and large buffers available (3.1); no browser training, ever.
  - D9 (Oct 31): I2, NEWTON WITH A WORKGROUP PER WORLD - every round inside one dispatch, the Hessian in shared memory,
    each world stopping at its own convergence; MJW's per-round dispatches and CG measured beside it; no PGS.
  - D7 (Oct 31): E2, DETERMINISTIC BY CONSTRUCTION - no atomics feed state; reruns on one GPU are bitwise; subgroup
    reductions only where shown bitwise-repeatable.
  - D14 (Oct 31): N1 + S3 - observations, the policy's action, the servo, rewards, resets, pushes and replay records
    all as kernels sharing buffers with the learner; the judge is robot.zig in its MuJoCo mode, the engine games use.
  - D2 (Oct 31): P1, ONE robotgpu.zig - the kernel module, layout, packing, program and twin harness in one file,
    beside it only sizes files and robotgpu_host.zig.
  - D3 (Oct 31): F1, robot.zig's MODEL EXTENDED with MuJoCo's collision and constraint fields (R3-R6); robotgpu packs it.
  - D4 (Oct 31): D-b, 8 ARENAS + A LAYOUT OF OFFSETS IN PARAMS, refusing an overflow by name.
  - D6 (Oct 31): C3, ONE ACCESSOR, WORLD-MAJOR BY DEFAULT, element-major a comptime flag for measurement.
  - D10 (Oct 31): J1, qacc WARM START ON BOTH ENGINES - robot.zig's Newton gains it (option, on in MuJoCo mode), `State`
    carries it.
  - D11 (Oct 31): K-a, PORT MJW'S NARROWPHASE - primitive first, convex next; the same functions feed robot.zig's
    MuJoCo mode on the CPU; zimrphysics remains a CPU oracle.
  - D13 (Oct 31): M1, DEVICE-FREE robotgpu.zig + `robotgpu_host.zig` running the program as one batch per step.
  - D16 (Oct 31): MUJOCO C FIXTURES ARE THE ORACLE (with robot.zig and the twin); where MJW deliberately differs, MJW's
    behaviour wins, pinned by an MJW-generated fixture, each row documented.
  - D17 (Oct 31): O1, GENERIC KERNELS + FLAG VARIANTS - one build for every robot; comptime variants only where a flag
    changes a kernel's shape.

| # | decision | recommendation | where |
|---|---|---|---|
| D1 | how robotgpu relates to robot.zig | DECIDED: A2, shared per-element functions in robot.zig, traversal per engine, a bitwise refactor | 4.A |
| D2 | one file or a family | DECIDED: P1, one `robotgpu.zig`, plus sizes files and a host file | 4.P |
| D3 | the model's source of truth | DECIDED: F1, robot.zig's Model, extended with MuJoCo's collision fields | 4.F |
| D4 | buffers | DECIDED: D-b, 8 arenas, a Layout of offsets inside the Params uniform | 4.D |
| D5 | parallel decomposition | DECIDED: B2, MuJoCo Warp's shapes from the start | 4.B |
| D6 | memory layout | DECIDED: C3, one accessor, world-major by default, element-major measured | 4.C |
| D7 | determinism | DECIDED: E2, deterministic by construction, no atomics feeding state | 4.E |
| D8 | the constraint diagonal | DECIDED: H3, both on both engines, the approximation the GPU's default | 4.H |
| D9 | the solver | DECIDED: I2, Newton, a workgroup per world, rounds inside one dispatch, H in shared memory; I3 and CG measured beside it; no PGS | 4.I |
| D10 | warm start | DECIDED: J1, qacc, robot.zig's Newton too | 4.J |
| D11 | collision | DECIDED: K-a, MJW's primitive narrowphase, then its convex path | 4.K |
| D12 | contact parameters | DECIDED: L1, MuJoCo's per-geom material and pairs | 4.L |
| D13 | who drives the device | DECIDED: M1, robotgpu.zig device-free, robotgpu_host.zig runs the program | 4.M |
| D14 | the tracker | DECIDED: N1 everything on the device; the judge is robot.zig in MuJoCo mode | 4.N, 4.S |
| D15 | scope and order | DECIDED: R1, tracker first, then full parity; S10 rows decided when reached | 4.R, S10 |
| D16 | the oracle | DECIDED: MuJoCo C fixtures + robot.zig + the twin; MJW's own fixtures where it deliberately differs | 4.Q |
| D17 | specialisation | DECIDED: O1, generic kernels, uniform feature flags, comptime variants by shape | 4.O |
| D18 | target platforms | DECIDED: T1, native only (Windows Vulkan), officially - training never in a browser | 4.T |

ORDER OF ASKING: D1, D15, D8, D12 - the four that change the physics or the scope - then D5, D18 (opened by D5's
answer), D9, D7, D14, D2, D3, D4, D6, D10, D11, D13, D16, D17.


## 13. Journal

- Oct 31: plan v1 drafted. Studied robot.zig, the tracker's use of it, zimr's GPU stack, and all of MuJoCo Warp (the
  core read directly, the rest through six full-file digests). FOUND while studying, outside this plan: spv2wgsl's
  pointer-parameter lowering loses writes in WGSL (1.3, item 1) - verified in the build cache for `norm_fwd`, so the
  zn kernels carrying the marker compute wrongly in browsers today. Reported to Simon, not fixed here; S0.1 is the root
  fix if the plan goes ahead (a separate fix session was proposed to Simon as a card).
- Oct 31: D1 decided - A2, share formulas. Simon: the GPU is for accelerating training only; games stay on the CPU;
  web training wanted at a smaller scale, native-only training accepted if the web cannot. Section 0, G4 and the
  browser-memory risk revised to match. Next question: D15, scope and order.
- Oct 31: D15 decided - R1, tracker first, then full parity. Next question: D8, the constraint diagonal.
- Oct 31: D8 decided - H3, both diagonals, the GPU defaulting to MuJoCo's approximation. Next question: D12, contact
  parameters.
- Oct 31: D12 decided - L1, MuJoCo's per-geom material. Next question: D5, the parallel decomposition.
- Oct 31: D5 decided - B2, MuJoCo Warp's shapes from the start ("maximal perf right from the beginning"); 6.4, 6.5 and
  S2's gate revised (G1 to tolerance). Simon floated making robotgpu officially native-only: opened as D18 (4.T),
  asked next. Checked for it: the Vulkan bindings (vk.zig) already declare the limits and feature structs (shared
  memory size, push constants, subgroup flags), but the host enables none of them yet.
- Oct 31: D18 decided - T1, native only, officially. Revised: section 0 (goal, G2, G4), 1.3 (the web-only findings
  leave robotgpu's path), 3 (marked superseded in part; new 3.1 for native Vulkan), 6.1 and 6.14 (native lab app, no
  Chrome), S0 (native features, timestamps, push constants; the spv2wgsl fixes moved out to their own session), the
  risks and the costs. With native shared memory, 4.I's pick moved to I2. Next question: D9, the solver.
- Oct 31: D9 decided - I2, a workgroup per world with every Newton round in one dispatch; 6.8 rewritten to lead with
  it. Next question: D7, determinism (now that native float atomics make MJW's literal scatters possible).
- Oct 31: D7 decided - E2, deterministic by construction; float atomics recorded but unused, subgroup reductions only
  where bitwise-repeatable; S0.1 and 3.1 revised. 4.S's pick moved to S3 (judge on robot.zig in MuJoCo mode, the engine
  games deploy on). Next question: D14, the tracker's loop and its judge.
- Oct 31: D14 decided - N1 + S3; G5, 6.12 and S6 revised (the judge is robot.zig in MuJoCo mode). Next question: D2,
  one file or a family.
- Oct 31: D2 decided - P1, one robotgpu.zig. Next question: D3, the model's source of truth.
- Oct 31: D3 decided - F1, robot.zig's Model extended. Next question: D4, buffers.
- Oct 31: D4 decided - D-b, 8 arenas, offsets in Params. Next question: D6, memory layout.
- Oct 31: D6 decided - C3, accessor with world-major default. Next question: D10, warm start.
- Oct 31: D10 decided - J1 on both engines; R5 notes `State` carries the warm start. Next question: D11, collision.
- Oct 31: D11 decided - K-a, port MJW's narrowphase. Next question: D13, who drives the device.
- Oct 31: D13 decided - M1. Next question: D16, the oracle.
- Oct 31: D16 decided - MuJoCo C fixtures, MJW's where it deliberately differs; G3 and 6.6 revised. Next question:
  D17, specialisation (the last).
- Oct 31: D17 decided - O1, generic kernels with flag variants. ALL EIGHTEEN DECISIONS ANSWERED. Consistency sweep:
  1.2's Hessian note, 6.2's uniform rule, 6.4's barrier wording, 6.14's parity gate and 10's estimate brought in line
  with D5 and D18. Next: the full list read back to Simon for explicit agreement before the plan is called final.
- Oct 31: THE PLAN IS FINAL. Simon agreed with all 18 decisions: "agree. Don't implement just yet." Nothing is
  implemented; S0 starts only on his go.
