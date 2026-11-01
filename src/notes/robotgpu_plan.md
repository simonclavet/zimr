# robotgpu - MuJoCo Warp in zimr, on the GPU of the web and of Windows - the plan (v1 DRAFT, Oct 31 2026)

STATUS (Nov 1): UNDER WAY. The plan was made FINAL on Oct 31 (18 decisions, each asked one at a time and the whole
list agreed; D19, the web as a later stage, added Nov 1) and Simon said go the same day. DONE ON LAVAPIPE: all of S0
(the engine prerequisites), S1a-S1d and S1e's first half (the layout, the packing, robotgpu as a kernel module with
one kernel). NOT YET: any physics on the device (S2 on), and any run on Simon's GPU (an RTX 5060 Laptop) - a stage is
DONE only when it passes there too. NEXT: S1e-2 (section 8). Written under claude.md's "MAKE A PLAN" procedure. This
file is the one source of truth for robotgpu's decisions, status and journal (section 13).

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
of physics is written.

UPDATE (Oct 31, after S0.1-S0.4 c): four statements above no longer hold. Compute builds DO pass spv2wgsl `--strict`
(shader_codegen.zig), so item 1's markers fail a web build. Vec and Quat ARE in a compute kernel (`robotgpu_probe`'s
`maths` and `spatial`), and robot.zig DOES compile into one: the profiler compiles to nothing on the GPU, and robot.zig
and profiler.zig are modules of their own (`addRobotModules`). `run` DOES check the 65,535-workgroup limit, refusing
by name unless the module sets `Config.large_dispatch`, which spreads workgroups over rows. WITH D18 (native only), items 1-3 and the web half of item 5 leave robotgpu's path - Vulkan runs
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

  T4 NATIVE AS IT IS, THE WEB AS A SECOND BUILD OF THE SAME SOURCE (opened Nov 1 by Simon: "evaluate how hard it would
     be to support webgpu. I know it would be with a reduced perf because of missing features. I dont want native to
     suffer, so some code would need 2 branches"). Native keeps every T1 feature; the kernel module is compiled a second
     time for the web, and each native-only feature has a web counterpart CHOSEN AT COMPILE TIME (`host.is_browser`, or
     a kompute config the web build sets) - the native SPIR-V never contains a fallback, the WGSL never a native-only
     instruction. What each S0 feature becomes on the web, checked against the browsers on Nov 1, 2026:

       FEATURE              NATIVE (unchanged)          WEB COUNTERPART                                    COST ON THE WEB
       subgroup reductions  OpGroupNonUniform* (S0.1)   WebGPU's optional `subgroups` feature (Chrome since  a tree reduction in
                                                        134, not every browser): the web build uses the      shared memory: a few
                                                        workgroup tree reduction kompute already has, or      more barriers
                                                        WGSL's subgroupAdd where the feature is present
                                                        (spv2wgsl refuses subgroup instructions today)
       push constants       Vulkan push constants       WebGPU IMMEDIATES (`var<immediate>`, setImmediates)  one bind-group offset
                            (S0.4 e)                    shipped in Chrome 149-150 (June 2026), feature-       per dispatch
                                                        detected; elsewhere a small uniform ring with
                                                        DYNAMIC OFFSETS, one 256-byte slot a dispatch -
                                                        `runPushed`'s web path, the same API
       large dispatches     rows of 65,535 (S0.4 c)     the same: spv2wgsl already knows `num_workgroups`    none
       ranged readback      a staging copy and a wait   mapAsync: the web cannot block, so a readback is     results a frame later
                            (S0.4 a)                    asked for and COLLECTED later (see the S1e rule)
       timestamps           in the pass (S0.4 d)        the `timestamp-query` feature at pass boundaries,     coarser stage times
                                                        quantised; optional, profiling only
       buffer lending       (S0.4 b)                    the same: one GPUBuffer in two bind groups           none
       shared memory        the device's (32-64 KB):    WebGPU guarantees 16 KB; zimr's web boot asks for    a global-memory Hessian
                            Geno's 23 KB Hessian        no raised limits today. Ask for the adapter's limit   if the adapter offers
                            (S0.5, S3's Newton)         (desktop: 32 KB typically); below what a kernel       less - slower Newton
                                                        needs, its global-memory variant (the Hessian in
                                                        `scratch`), chosen per build
       arena sizes          GBs per binding (S0.6)      128 MB per binding and 256 MB per buffer             fewer worlds: Geno's
                                                        guaranteed; ask for the adapter's limits, and a       constraint rows cap at
                                                        web sizes file                                        about 2,000 worlds at
                                                                                                              128 MB
       the CPU twin         a static `Buffers` in       a web build is GPU-only: the twin's static arenas     none
                            every binary (kompute)      would sit in wasm memory, so compute_host gains a
                                                        GPU-only module option that leaves them out
       float atomics        not used (D7)               not used                                              none
       precision            G1 bars (D11)               the same functions through Tint; per-browser maths    looser web bars where
                                                        may differ in the last bits                           measured

     Beyond the table: WGSL's robustness clamps every storage index (a few percent to tens of percent on memory-bound
     kernels), and a browser's per-dispatch cost is higher (MJW's step is dozens of dispatches). EXPECTED: on the same
     GPU, the web a small factor slower than native at equal worlds, and fewer worlds unless the adapter's limits are
     raised. THE WORK: mostly in the engine, shared by every kernel - spv2wgsl (immediates or a uniform for the push
     block; subgroups where enabled), compute_host's web paths (dynamic-offset pushes, collected readbacks, the GPU-only
     option), the web boot asking for the adapter's limits and features, a web sizes file - then the few kernel-level
     branches where a limit differs (Newton's Hessian), a browser page, and parity checks run in Simon's browser (the
     sandbox has no WebGPU). About 12 to 20 turns.
     + the tracker trainable in a browser; native unchanged; kernels written once.
     - a second build to keep compiling; web results checked only in a browser, outside the sandbox.

  DECIDED Nov 1 (D19): T4, LATER - native stays the reference and the speed target; the web joins as stage SW after the
  tracker (S6), when the whole path it would port exists. FROM S1e ON, two rules keep that stage engine work rather
  than a rewrite: (1) every robotgpu kernel also compiles in the web configuration and translates to WGSL in the build,
  each native-only feature reached through kompute or compute_host, which carry the web counterpart; (2) the host API
  is SUBMIT, THEN COLLECT - a step's results asked for and read later, never waited on mid-frame - which native can
  still complete at once.

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

Eight fields - compute_host's ceiling. A `Layout` rides inside `Params` with the counts (nworld, nbody, njnt, nv, nq,
ngeom, nu, na...), the step options (timestep, gravity, iterations, tolerances, flags) and the feature bits: ONE STRUCT
PER ARENA (`layout.world_f`, `layout.model_u`...), each array's place a 16-byte `WorldArray(arena, kind)` or
`ModelTable(arena, kind)` whose TYPE names its arena and what one item is (a body's vector, a dof's motion...), so a
kernel reads `layout.world_f.xpos.loadVec(world, body)`, an array cannot index another arena, and an item's width is
known at compile time (no arrays in the uniform - std140 rules, Vulkan's as WGSL's, pad array elements to 16 bytes).
Per-world arrays are WORLD-MAJOR by default: item i of world w at `offset + w * stride + width * i`, the stride derived
from the counts (padded to 4 floats), behind the accessors so the element-major alternative is a comptime switch
(4.C). Batched model parameters carry a count: `batch_f[offset + (w % count) * stride + i]`, count 1 until a caller
randomises.

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

  S0 AS IT STANDS (Nov 1): ALL OF S0 DONE on lavapipe, not yet run on Simon's GPU; S1a-S1d and S1e's first half DONE
  (section 13). THE TURNS AS PLANNED, EACH ONE TURN, IN THIS ORDER - what is built, where, and the check that says it
  is done:

  R  REVIEW CARRY-OVERS (the review of Oct 31 - first, before new features):
     R1 The probe's row layouts as TYPES: `MathsInputs` / `MathsResults` and `SpatialInputs` / `SpatialResults`
        as extern structs of f32 arrays in robotgpu_probe.zig; every offset `@offsetOf(T, "field") / 4`, every
        width `@sizeOf` of its field / 4, the row widths `@sizeOf(T) / 4` - replacing `MathsRow` / `SpatialRow`'s
        hand-counted numbers; vk_host_test's `ProbeResult` takes its offset and width from the same declarations.
        Check: vk-host-test's measurements unchanged to the digit.
     R2 vk_gen's name conversion splits digits before a word ("Float32Atomic" -> `float_32atomic`): make it
        `float32_atomic`, regenerate, `vk-abi-check`. Check: the generator's tests (`vk-gen-test`) and the
        ABI check; the one use in wgpu_vulkan.zig follows.
  S0.4 a RANGED READBACK - compute_host.zig. A module's `Config` declares `readback = .ranges` (default `.mirror`,
        today's behaviour): such a module gets NO heap mirror and NO whole-Buffers staging buffer; `readRange(field,
        first, count, destination)` copies that range through a staging buffer of `Config.staging_bytes` (in
        chunks when larger), blocking until it lands. The probe moves to `.ranges`. Check: vk-host-test's probes
        unchanged; a new check reads three ranges of one field (start, middle, end, one crossing a chunk) against
        the twin, exactly.
  S0.4 e PUSH CONSTANTS - the spike is DONE (journal, Oct 31): Zig emits a valid PushConstant block; zimr's check,
        legaliser and reflection accept it. Three turns follow:
        E1 THE HOST. spv_vulkan's reflection reports an entry's `push_constant_bytes` (its PushConstant block's size:
           the last member's offset plus its size, scalar and vector members); the Vulkan host adds a
           VkPushConstantRange (compute stage, offset 0, that size) to the compute pipeline's layout whenever it is
           non-zero - automatic, no layout API changes; `vkCmdPushConstants` joins vk_gen's device commands
           (regenerate, vk-abi-check); `computePassSetPushConstants(pass, bytes)`, Vulkan host only, pushes against
           the pass's bound layout (`PassSlot.pipeline_layout`). Check: vk-host-test green; a module without push
           constants unchanged.
        E2 KOMPUTE AND COMPUTE_HOST. A kernel file declares `pub const PushConstants = extern struct {...}` (a
           multiple of 4 bytes, at most 128 - the least Vulkan guarantees, refused at compile time past it);
           `g.push()` reads it (GPU: `@extern(*addrspace(.push_constant) ...)`; CPU: a module variable the twin's loop
           reads); compute_host's `runPushed(name, n, values)` pushes before each dispatch on every path (single,
           batch, recording), the CPU path setting the variable; a browser build that calls it is a compile error
           (`host.is_browser`). Check: compile green; `run` unchanged for modules without PushConstants.
        E3 THE PROBE. A `write_pushed` entry writes its pushed value into a region its pushed offset names; one batch
           of three dispatches with three values. Check: each region holds its own value - the per-dispatch
           parameter level-scheduled kernels need - on the device and the twin.
  S0.4 d COMPUTE TIMESTAMPS - D1 (bindings and host) DONE (journal, Oct 31). Next:
        D2 COMPUTE_HOST. `enableTimings()` gives a pipe a timestamp pool of two slots per kernel; with timings on,
           every GPU path of `dispatchKernel` resets the kernel's two slots, writes the first at the top before the
           dispatch and the second at the bottom after it; `kernelTimings()` reads the pool (waiting) and returns each
           kernel's last duration in microseconds - (ticks[1] - ticks[0]) x timestamp_period_ns / 1000 - zero for a
           kernel not run since, and none of this when timings are off; native only (`host.is_browser`).
        D3 THE CHECK. A probe entry whose work grows with a pushed count (each invocation iterating `count` times);
           one dispatch with count c, one with 4c. Check: the second's duration exceeds the first's on lavapipe, and a
           pipe without timings reports none.
  S0.4 b BUFFER ADOPTION - compute_host.zig: `initGpu(..., .{ .adopt = &.{ .{ .field = .x, .from = &other_pipe,
        .other_field = .y } } })`: the field binds the other pipe's buffer (the same VkBuffer) - the learner's ring
        and robotgpu's arenas shared without copies (6.12). The adopter never frees it; the owner must outlive it
        (asserted at deinit). Check: a probe pipe writes, an adopting pipe reads the same values with no upload.
  S0.5  THE WORKGROUP SHAPE - robotgpu_probe's `cholesky` entry: one workgroup of 64 per world, its 76 x 76
        symmetric positive definite matrix (A = B B^T + 76 I, random B) loaded into shared memory (23 KB, inside
        lavapipe's 32 KB), factored in place by columns - the diagonal, then the column below it in parallel, then
        the trailing update in parallel, a barrier between - the bounds uniform (from Params), every lane reaching
        every barrier; the twin: the first invocation factors it serially from global memory. Check: L L^T against
        A within 1e-5 relative; device against twin within the reordering bar; two device runs bitwise equal (D7).
  S0.6  THE MEMORY ENVELOPE - robotgpu's arenas for Geno at nworld 4,096 and 8,192 (section 6.2's sizes): their
        bytes per arena against each device's maxStorageBufferRange and memory heaps, recorded here; on lavapipe the
        largest nworld that fits its 128 MB bindings, allocated and touched once. Check: the table in this file.
  S1    FOUNDATIONS, six turns:
        S1a THE SKELETON AND THE LAYOUT. src/robotgpu.zig - the kernel module's `Buffers` (the eight arenas, sized by
            the `robotgpu_sizes` module: robotgpu_sizes.zig for desktop GPUs, robotgpu_sizes_test.zig for tests and
            lavapipe), `Counts`, `ArrayAt` (offset, stride, count, padding - 16 bytes, so the uniform's layout rules hold
            by construction), `Layout` (one named `ArrayAt` per array; S2's per-world arrays first, the constraint and
            contact arrays joining in S3 and S5), `Params`, `layoutFor(counts, capacities)` refusing by name, and the
            world-major index `offset + world * stride + index`. src/robotgpu_tests.zig, a test-fast root. Check: for
            Geno's, the humanoid's and the KUKA's counts every array is 4-float aligned, inside its arena and clear of
            the others; each refusal fires by name.
        S1b R4 AND THE TOPOLOGY. robot.zig: `Model.body_subtree_count` and the depth-first check (bitwise gate);
            `pack` of model_u - parents, subtree counts, roots, each body's dof chain, the ancestor bitmasks, the mass
            matrix's sparsity. Check: pack-then-decode equals the model's tables for the KUKA, the humanoid and Geno.
        S1c THE CONSTANTS. `pack` of model_f - bodies, joints, dofs, geoms - and invweight0 at qpos0 by robot.zig's own
            functions; bounding radii. Check: pack-then-decode reproduces every model field.
        S1d R1, THE SHARED PER-ELEMENT FUNCTIONS. robot.zig's pure `pub fn`s (a body's pose, a joint's cdof, one entry
            of M, one body's RNE force, ...). GATE: robot.zig's suite, the robot family's tests and the benches'
            numbers bit-identical before and after.
        S1e THE HOST AND THE PROGRAM, three turns (the first half - robotgpu as a kernel module, `clear_overflow` on
            the device - done Nov 1):
            S1e-2 A RANGED READBACK REQUESTED, THEN COLLECTED (compute_host): `requestRange(field, first, count)` copies
                  the range into a staging buffer and submits, returning a ticket; `collectRange(ticket, destination)`
                  copies it out once the GPU has finished - false until then, never blocking - with a waiting form for
                  callers that want it now. Native now; the web's mapAsync path in SW, a named compile error until
                  then. The existing whole-field mirror (`readGeneration`, `readLatest`) cannot serve arenas of hundreds
                  of megabytes. Check: two ranges requested, other work submitted, both collected equal to what was
                  uploaded.
            S1e-3 THE HOST: src/robotgpu_host.zig, `Sim` - `init(gpa, device, queue, model, nworld)` (countsOf,
                  layoutFor, pack, the model arenas uploaded once, `Params`), the STEP PROGRAM (a list of kernels with
                  how many invocations each runs - per world, per world and body, per world and branch... - built from
                  the counts; S1's program is `clear_overflow`), `submitStep` (the program as one batch),
                  `requestOverflow` / `collectOverflow` (S1e-2's tickets), `deinit`. Check: a Sim of Geno at 64 worlds
                  on the device and on the CPU twin - overflow poisoned, a step submitted, the bits collected as zero.
            S1e-4 THE WEB CONFIGURATION AND THE DESKTOP BINARY: `addComputeOutput` takes `KernelModules` (robot, the
                  sizes file) like the native path, and `zig build check` translates robotgpu's kernels to WGSL
                  (D19's first rule); the vk host test built for Windows at DESKTOP sizes, for Simon to start - the CPU
                  twin's static arenas near a gigabyte (the risk noted at S1a).
        S1 REVIEW: the code against MJW's io.py once more; comments; the course gains its chapter on the simulator's
            data (arenas, the layout, packing, branches, the host) - in the GPU compute course or a page of its own,
            Simon's choice.

**S1 FOUNDATIONS.** robot.zig R1, R2, R4 under the bitwise gate; robotgpu.zig's Buffers, Params, Layout, sizes files,
`layoutFor` with refusals by name, `pack` (topology, chains, M sparsity, invweight0, bounds), `program`, overflow bits;
`robotgpu_host.Sim`; `robotgpu_tests.zig` in test-fast. Check: pack-then-decode reproduces every model field; each
refusal fires by name; an empty program runs on the CPU and the GPU.

**S2 SMOOTH DYNAMICS, no constraints - its turns, each checked against MJW's kernels (smooth.py, Nov 1):**

    S2a THE TWIN'S HARNESS AND R1's REST: robotgpu_tests runs the CPU twin's kernels directly (the arenas in `g`, an
        invocation loop) - parity with robot.zig in seconds, no Vulkan; robot.zig's remaining smooth functions shared
        (one entry of M, one body's RNE force, a joint's share of `differentiatePos`) under the fingerprint gate.
    S2b KINEMATICS: MJW's `_kinematics_branch` - one invocation per world and branch, root first, `moveByJoint` and
        `freeJointPose` per body; then geoms and sites, one invocation per world and element. Twin = robot.zig, then
        the device = the twin.
    S2c COM_POS AND CRB: subtree sums over depth-first ranges (`body_subtree_count`, MJW's body_subtreenum) -
        subtree_com, cinert, cdof (`dofAboutAxis`); `_crb_subtree`; the mass matrix's entries.
    S2d FACTOR_M AND THE SMOOTH SOLVE: the factorisation's tables packed as io.py builds them - tile blocks for small
        trees, the sparse LDL's `qLD_updates` grouped by depth above them (Geno's 75 dofs) - then qLD, qLDiagInv and
        qacc_smooth = M^-1 qfrc_smooth.
    S2e VELOCITIES AND FORCES: com_vel (`_comvel_branch`), rne (`_cacc_branch`, cfrc_int over subtrees,
        `_qfrc_bias`), passive forces (damping, stiffness), qfrc_applied, actuation (joint transmission, the affine
        law, the filters).
    S2f INTEGRATION AND THE PROGRAM: Euler with implicit damping, integratePos (`rotateQuatByAngularVel`), the velocity
        bound; S2's step program assembled; G1 step by step on the single and double pendulum, the free body, the ball
        chain, the KUKA, the humanoid and Geno, on the twin and the device.
    S2 review.

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

**SW THE WEB BUILD (D19).** The kernel module compiled for the web with its compile-time counterparts (the table in
4.T): spv2wgsl's immediates (or a uniform for the push block) and subgroups where enabled; compute_host's web paths -
pushes through dynamic offsets, readbacks collected a frame later, a GPU-only module without the twin's static arenas;
the web boot asking for the adapter's limits and the `subgroups`, `timestamp-query` features; a web sizes file; the
global-memory Hessian where shared memory is short; robotgpu_lab as a page; the tracker's learner (zn_mlp, already on
the web) lending its buffers as natively. Check, in Simon's browser: the parity checks of S2-S6 at web bars, and the
page's measured steps per second beside native's.

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
  - D19 (Nov 1): T4, LATER - the web as a second build of the same source, stage SW after S6, native unchanged; from
    S1e on every kernel also compiles for the web, and the host API is submit-then-collect (4.T).

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
| D19 | the web, revisited | DECIDED: T4 later - the web as stage SW after S6, native unchanged; kernels compile for the web from S1e | 4.T |

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
- Oct 31: PREPARED FOR S0 in the sandbox (Simon: "Get zimr to compile and study claude.md and readme.html, including
  zimrnum and robot tutorials. prepare for implementing the robotgpu mujoco warp plan"). The tree at
  `/home/claude/zimr` builds with zig 0.18.0-dev.753+1420479be: `zbuild check` green; the bump's tier 2 empty
  (`lint-fix` migrated nothing, only doc-sync refreshed five mirrored blocks of the backends tutorial); tier 3's
  `c2js-canary` passes; `tripwires` run. lavapipe and the Khronos validation layer present. MuJoCo Warp unpacked at
  `/home/claude/mujoco_warp` - this plan's `file.py:line` citations resolve under `mujoco_warp/mujoco_warp/_src/`
  (core: constraint.py 5,868 lines, solver.py 5,712, smooth.py 5,096, forward.py 3,311, types.py 3,046). S0's
  starting points verified: `vk.zig` declares maxPushConstantsSize, maxComputeSharedMemorySize and
  maxComputeWorkGroupCount; the Vulkan host records only maxStorageBufferRange (the binding guard); kompute has no
  subgroup operations. Waiting for Simon's go.
- Oct 31: GO (Simon: "Proceed. At the end of this we should have fast robot sim for mocap tracking on vulkan windows.
  For testing you will use lavapipe. We can trust the plan and mujocowarp sources. Review as you go and prepare to add
  chapters about gpu in robot tutorial"). S0.1a DONE: `vk.zig` gains `PhysicalDeviceProperties2` and its query,
  `PhysicalDeviceVulkan11Properties` (the subgroup's size, stages and operations, C layout), `SubgroupFeature`'s bits
  and `PhysicalDeviceShaderAtomicFloatFeaturesEXT`; the Vulkan host records each device's `ComputeCapabilities` in
  `Gpu.compute` (`computeCapabilities`: shared memory, push constants, workgroup counts and invocations, subgroup size,
  whether compute may use subgroups and which operations, float atomic add only when the extension is offered) and
  says the chosen device's at bring-up. RECORDED ON LAVAPIPE (llvmpipe, LLVM 20.1.2, 256 bits): 32,768 bytes of shared
  memory per workgroup (Geno's 76 x 76 Hessian, about 23 KB, fits - D9), 256 bytes of push constants, 65,535
  workgroups per dimension of up to 1,024 invocations, SUBGROUPS OF 8 with arithmetic, shuffle and ballot, float
  atomic add yes (recorded, unused - D7). Simon's GPU: its line at the first start. `vk-host-test` green.
  NEXT S0.1b: kompute's subgroup reductions (inline SPIR-V, the capabilities declared by the legaliser), refused in a
  web build at compile time; the probe kernel against the twin and bitwise run to run.
  THE TUTORIAL'S GPU CHAPTERS (Simon: "prepare to add chapters about gpu in robot tutorial"), to grow with the stages,
  in robot-mocap-tutorial.html (robot.zig's own pages link them): 1. many worlds in lockstep - why the GPU, what a
  world is, the 8 arenas and the layout; 2. the step as a program of kernels - MuJoCo Warp's shapes (one thread per
  world and element, a workgroup per world), the CPU twin; 3. smooth dynamics on the device - kinematics to the mass
  matrix and its factor; 4. contacts and constraints - the rows, the approximate diagonal; 5. Newton in a workgroup -
  the Hessian in shared memory, each world converging on its own; 6. determinism - why no atomics feed the state; 7.
  checking a simulator - parity with robot.zig, MuJoCo's fixtures, the device against its twin; 8. the tracker on the
  device. Each lands when its stage does.
- Oct 31: S0.1b BEGUN. kompute's SUBGROUPS section: `subgroupAdd` and `subgroupMax` (`OpGroupNonUniformFAdd` /
  `FMax`, Reduce, Subgroup scope, inline SPIR-V as the atomics are) - GPU-only like `localId`, the CPU path computing
  the same reduction from global memory, native only. `src/gpu/robotgpu_probe.zig`, the plan's probe module: entries
  `subgroup_sum` (every invocation its subgroup's sum; the twin takes a subgroup to be consecutive invocations, its
  size from Params) and `workgroup_sum` (64 values halved through shared memory between barriers, every lane reaching
  every barrier; the twin a loop in order). Registered with vk-host-test's kernels; THE COMPILER ASSEMBLES THE
  SUBGROUP INSTRUCTION (the module builds to SPIR-V); `vk-host-test` green. NOT YET KNOWN: whether the compiler
  declared the `GroupNonUniform` capabilities (else the legaliser inserts them - spv_vulkan.zig's `check` refuses every
  capability but Shader today) and what the device says. NEXT: a `robotgpu probe` check in vk_host_test.zig - both
  entries on the device against the twin, and twice for bitwise equality; the legaliser's capabilities; the probe
  kept out of the web's WGSL.
- Oct 31: S0.1 CHECKED ON LAVAPIPE. THE COMPILER DOES NOT DECLARE A SUBGROUP INSTRUCTION'S CAPABILITY: the first load
  failed validation ("GroupNonUniformFAdd requires ... GroupNonUniformArithmetic"). So `spv_vulkan.zig` gains a fifth
  legalization - `subgroupCapabilities` maps every `OpGroupNonUniform*` the module holds to its capability (vote,
  ballot, shuffle, relative shuffle, arithmetic, quad; clustered for a clustered reduction; `GroupNonUniform` with any)
  and `legalize` declares the missing ones straight after the header; `check`, the build's gate, accepts the family
  (`Capability.isAllowed`). `wgpu.computeCapabilities()` hands a program the device's (empty off the native host - a
  @compileError there fired in builds that analyse every public declaration). vk-host-test's `robotgpu probe` check:
  both reductions on the device against the twin from 2,373 inputs of mixed sizes and signs, each run twice. ON
  LAVAPIPE: the subgroup sum EQUALS the twin (gap 0), the workgroup sum within 3.8e-8 of its magnitudes (bar 1e-5),
  TWO RUNS BITWISE IDENTICAL; no validation error. S0.1's gate holds on lavapipe; Simon's GPU at its first run.
  NEXT: spv2wgsl refusing `OpGroupNonUniform*` by name (the web's guard, so such a kernel can never become silent
  zeros in a browser); then S0.2, the maths probe (zimrmath's Vec / Quat / Inertia functions in a kernel against the
  twin, with ULP bars).
- Oct 31: REVIEW OF S0.1 (Simon: "When i say review, it means: find bugs, choose better variable names, more verbose
  even if different from mujoco, more comments. Intermediate locals to simplify expressions. Code should read like a
  course. With diagrams."). BUGS FIXED: the probe check divided by the subgroup size - 0 on a device without subgroup
  arithmetic in compute shaders - now the subgroup sum is reported not applicable there (`ProbeOutcome.subgroup_gap`
  optional, `ComputeCapabilities.hasSubgroupArithmetic`); the kit's device readback was duplicated for the probe -
  now one generic `deviceReadback(Kernel, pipe, field)`. READING: the probe module opens with both reductions drawn
  (a subgroup's eight lanes, the workgroup's six halvings), its buffers `values` / `sums`, its names `invocation`,
  `lane`, `member`, every condition a named local; kompute's subgroup section draws a reduction; the legaliser's
  subgroup code has the opcode-to-capability table and a reduction's words drawn, `SubgroupInstructions` naming the
  spec's bounds and `SubgroupCapabilitySet` hiding the indexing (no bare 61 / 333 / 349 / +4 left); the capability
  query explains Vulkan's `p_next` chain, its locals named for what they hold. vk-host-test green: the subgroup sum
  equal to the twin, the workgroup sum within 3.8e-8, two runs identical, no validation error.
- Oct 31: THE WEB'S GUARD, CHECKED. Every shader and kernel build passes spv2wgsl `--strict` (shader_codegen.zig
  sets it), which refuses an `// ERROR:` line - so section 1.3's "compute builds do not pass --strict" no longer holds,
  and a subgroup instruction could never have become a silent zero in a browser: the probe's `subgroup_sum` through
  spv2wgsl exits 5; its `workgroup_sum` (shared memory and barriers) translates cleanly. The refusal now NAMES the
  instruction (`emitUnhandledPlaceholder`): "subgroup instruction 350 (kompute's subgroup operations, native Vulkan
  only) has no WGSL lowering". S0.1 DONE on lavapipe. NEXT: S0.2, the maths probe.
- Oct 31: S0.2 BEGUN - AND STOPPED BY A COMPILER CRASH, the very risk S0.2 exists to find. A `maths` entry in the
  probe (one invocation per table row: unit quaternion, quaternion, vector, angle in; qmul, conjugate, rotate, both
  axis-angle forms, normalize3, cross, dot3, length3, atan2Rad, acosRad out) made the SPIR-V compile SEGFAULT. BISECTED
  with the build's own command, one function a variant: load/store, qmul, conjugate, rotate, quatFromNormAxisAngle,
  cross, dot3, length3, atan2Rad, acosRad all compile; normalize3 and quatFromAxisAngle (which normalises its axis)
  crash. In normalize3 the division compiles and THE ASSERTION crashes: `assertf(dot3(v, v) > 0, @src(), ...)`.
  Further: `unreachable` in a branch compiles; a function taking a `std.builtin.SourceLocation` as a RUN-TIME argument
  crashes (`ignoresLocation(@src(), x)`). Tried: assertf's GPU form taking the location at COMPILE time - STILL
  crashes, so `@src()` itself evaluated in GPU code is the trigger (not yet confirmed by a variant). Reverted (no
  unverified change left in zimrmath); the probe restored to its last state; vk-host-test green. Every robot.zig
  function that asserts would crash a kernel build - the port depends on the fix. NEXT: confirm the trigger (a bare
  `_ = @src();` in a kernel; a comptime-only `@src()`), then the fix in zimrmath (assertf's GPU form must not evaluate
  `@src()` at all on the GPU - e.g. callers' `@src()` made lazy, or an assert form without it for kernels) or a
  compiler workaround, and a canary kernel in the build so the crash class is caught at once; then the maths entry
  back, and its device check with ULP bars.
- Oct 31: THE CRASH, FOUND AND FIXED. Trigger variants: `_ = @src()` compiles; a compile-time-only `@src()` compiles;
  `@src()` passed as a COMPILE-TIME parameter compiles; zimrmath's real `assertf` crashes. THE CAUSE: a
  `std.builtin.SourceLocation` (pointers to the file's and function's names) passed as a RUN-TIME argument crashes this
  compiler's SPIR-V backend (0.18.0-dev.753) - and zimrmath's four location-taking functions took it so: `assert`,
  `assertf`, `assertUnreachable`, `panicf`. THE FIX (zimrmath): each now has a GPU form taking the location at compile
  time (`assertOnGpu`, `assertfOnGpu`, `assertUnreachableOnGpu`, `panicfOnGpu`: `unreachable` when the check fails,
  the location never read) and a CPU form exactly as before (`...OnCpu`, the location at run time, so CPU builds make
  no instance per call site); the public name picks by `is_gpu` (`pub const assertf = if (is_gpu) assertfOnGpu else
  assertfOnCpu`). `@src()` is known at compile time at every call site, so no call changes. Checked: the `assertf`,
  `normalize3` and `quatFromAxisAngle` variants compile; the whole tree's check; lint. THE MATHS ENTRY IS BACK as
  designed (normalize3 and quatFromAxisAngle included) - building the probe is the canary for this crash class from now
  on. ALSO FOUND by the validation layer: a helper taking a storage-buffer pointer as a parameter (`loadVec(table,
  at)`) is invalid SPIR-V without VariablePointers - the helpers now read and write the bindings directly
  (`loadInput`, `storeOutput`), section 1.3's rule confirmed on the native path too. vk-host-test green, no validation
  error. NEXT: the maths entry's device check - every function against the twin in units of f32's epsilon, its bars
  set from the first measurement (plain arithmetic tight, the GPU's sine and cosine looser).
- Oct 31: REVIEW OF THE CRASH FIX AND THE MATHS ENTRY. FOUND FOR S0.3: outside zimrmath, only `profiler.zig` takes a
  `SourceLocation` at run time (`zone`, `zoneNamed`, `beginZone`, `internSrc`) - and robot.zig opens profiler zones
  with `@src()`, so robot.zig in a kernel build would hit THE SAME CRASH, beside the `build_options` dependency 1.3
  names; S0.3 gives the profiler a GPU form that compiles a zone out (or robot.zig's kernel build drops the zones).
  READING: the maths row's layout named once (`MathsRow`: every input's and result's offset, the widths, and the rule
  that the vector and the second quaternion are never zero, as `normalize3` asserts) - the kernel writes through it and
  the device check will read through it; every result a named local before it is stored (`product`, `conjugated`,
  `rotated`, `from_unit_axis`, `from_axis`, `crossed`); `storeResult`, `inputs_at`, `results_at`. zimrmath: `assert`'s
  documentation no longer says "std.debug.assert on GPU"; `assertf`'s draws its two forms (the CPU's location a run-time
  value, logged; the GPU's a compile-time value, never read) and says why. Lint, the documentation gate, the compile
  check and vk-host-test green.
- Oct 31: S0.2 DONE ON LAVAPIPE for zimrmath's functions (robot.zig's `Inertia.rotated` / `translate` / `mul`,
  `crossMotion`, `crossForce` follow S0.3, which puts robot.zig in a kernel build). vk-host-test's MATHS CHECK
  (`MathsCheck`, `runRobotgpuMathsProbe`): 1,024 rows from a seeded generator (a unit rotation; a quaternion and a
  vector whose three-dimensional parts stay away from zero, as normalize3 needs; an angle in [-pi, pi]); the `maths`
  entry on the device and the twin; each result's largest difference in units of f32's epsilon at its scale
  (max(1, |twin|)), read through `MathsRow`. MEASURED: conjugate, rotate, normalize3, cross, dot3, length3 EXACT (0);
  qmul 1.14 (a fused multiply-add); both axis-angle forms 1.00 (zimrmath's GPU sine and cosine within one epsilon of
  the CPU library); acosRad 1.91; atan2Rad 28 - the least precise, about 1e-5 radian near pi. BARS, one per function
  with headroom for other devices: 4 for arithmetic and square roots, 8 for sine / cosine and acos, 64 for atan2 - the
  table in `MathsCheck`'s comment. Every function within its bar; no validation error. NEXT: S0.3 - robot.zig in a
  kernel build (`wants_robot`): its `build_options` dependency through the profiler, and the profiler's run-time
  `SourceLocation` (the crash class) given a GPU form; then the spatial-algebra entries in the probe.
- Oct 31: S0.3 - ROBOT.ZIG COMPILES INTO A KERNEL. The profiler compiles to nothing on the GPU (Simon: "Maybe we
  should make the profiler compile to nothing on gpu ?"): in a GPU build `build_options` is an empty stand-in, so its
  own `@hasDecl` check makes `enabled` false, every zone (`inline`) folds away and a zone's `@src()` never becomes a
  run-time value. The shader pipeline: `KernelModules` (zimrnum, zimrrl, ROBOT), `compileKernelSpirv` (the SPIR-V
  compile, moved out of `addComputeOutput` unchanged but for `robot`), `addNativeComputeOutput` (SPIR-V alone - a
  native kernel never gets a WGSL step). The device test's kernel record gains `wants_robot` and `native_only`; the
  probe is both. The probe's `spatial` entry calls robot.zig's own `crossMotion`, `crossForce`, `Inertia.mul`,
  `translate`, `rotated` and `dot6` (`SpatialRow` names its 48 inputs and 56 results): its SPIR-V builds and the
  device test passes. FOUND, A DESIGN QUESTION FOR SIMON: a file belongs to one module only, and the engine module
  holds robot.zig (and profiler.zig) by relative import - so a CPU twin cannot also have robot.zig as its own module
  ("file exists in modules 'robot' and 'zimr'"). INTERIM: the probe imports `robot` on the GPU and `zimr.robot` on the
  CPU. The lasting answer is either robot.zig (and profiler.zig, which it imports) as modules of their own, the engine
  importing them by name - or robotgpu's twin always reaching robot.zig through the engine. NEXT: the spatial entry's
  device check (`SpatialCheck`, like `MathsCheck`), after Simon's answer on the modules.
- Oct 31: ROBOT.ZIG AND PROFILER.ZIG BECOME MODULES OF THEIR OWN (Simon: "I agree"). Sources: every compiled
  `@import("robot.zig")` / `@import("profiler.zig")` now imports the module by name (35 files; the archived
  `.zig.txt` probes untouched); the KUKA fixture imports `robot`, and `urdf_import`'s default import is the module's
  name. Build: `RobotModules`, `addRobotModules` (profiler reads zm and the options; robot reads zm and the profiler)
  and `addEngineOptionsAndRobot` (an engine module's options made ONE module, shared with the two - two modules rooted
  at one options file are a compile error) at every engine module (8), the modules rooted at src/tests.zig (the main
  test module, the WGSL-diff module) and three tools (robot_bench, clip_bake, and the tools loop); the fast test roots
  and the cartpole test get the two modules; the kernel pipeline gives a robot kernel `robot` and `profiler`; the
  device test's twin imports the ENGINE'S robot module - one file, one module - and the probe imports `robot`
  plainly. `zbuild check` green, lint clean. THE TEST GUARD (a module's tests run only from its own root): before, the
  robot.zig-only test "spec: counts and generated enums" filtered in the robot family ran 2 tests; robot.zig is in the
  fast list and drops out of the family's members once the family imports it by name, so its own root runs it now -
  to confirm (running at the end of this turn), with profiler.zig's tests, which have no root of their own yet.
- Oct 31: THE MODULE REFACTOR VERIFIED, AND S0.3 DONE ON LAVAPIPE. The test guard holds: filtered on the robot.zig-only
  test's name, robot.zig's own fast root runs 1 test and the robot family 1 - two, as before the refactor; profiler.zig
  joined the fast list (its tests had no root once it became a module) and its test runs from there. vk-host-test
  green with the twin on the engine's robot module. THE PROBE CHECK IS NOW ONE DEFINITION: `ProbeResult` (a result's
  place, width and bar), `measureProbeResults`, `reportProbeResults`, `ProbeTable` and `runProbeTable` (fill, run one
  entry on device and twin, measure) - the maths table (`MathsCheck`) and the SPATIAL TABLE (`SpatialCheck`: 1,024
  physically plausible rows) are each a table, a fill function and their bars. MEASURED, robot.zig's own spatial
  algebra on the device against the CPU engine: Inertia.rotated and dot6 exact; Inertia.mul and Inertia.translate
  1.00 epsilon; crossMotion 1.62; crossForce 8.61 - cancellation (forces to 20 against velocities to 3 make terms near
  60, the gap measured at the smaller result's scale), bar 16 with that reason. S0.1-S0.3 DONE on lavapipe. NEXT: S0.4,
  the compute host - ranged readback without a whole-Buffers mirror, buffer adoption, dispatches past 65,535
  workgroups, compute timestamps, push constants.
- Oct 31: S0.4 (c) DONE ON LAVAPIPE - DISPATCHES PAST 65,535 WORKGROUPS. kompute: `Config.large_dispatch` (opt-in, so
  the web's kernels are untouched) and `linearInvocationId` - a large dispatch's index counts the whole rows before
  its own, `row x (num_workgroups.x x workgroup) + x`, both installers deriving it. compute_host: `dispatchGrid` (one
  row when the workgroups fit, else rows of `max_workgroups_per_dimension` = 65,535, WebGPU's limit and the least
  Vulkan guarantees; a unit test) at all three dispatch sites, and a NAMED REFUSAL for a module without the flag that
  asks for more than one row - before, nothing checked the limit; the flag read only where `config` has the field
  (compute_host's own test modules use plain struct literals). The probe: `large_dispatch`, a dispatch capacity of
  2^23 with its buffers fixed at 2^16 (`table_capacity`), and `dispatch_tally` (each invocation below the count adds
  one and its index's low sixteen bits, by atomic add). vk-host-test: 5,000,000 invocations = 78,125 workgroups = two
  rows - device 5,000,000 and index sum 183,050,848, the twin the same, both equal to the host's own sum. The device
  test's `deviceReadback` takes its element type. NEXT: S0.4 (a), ranged readback without a whole-Buffers mirror.
- Oct 31: REVIEW (Simon: "Look at everything we have done and the plan for the next few turns. Is there a way to make
  this code better, more zig idiomatic, easier to read? Review carefully and make the plan more precise"). FOUND: the
  Vulkan declarations added in S0.1 (`PhysicalDeviceProperties2`, `PhysicalDeviceVulkan11Properties`, the float-atomic
  features, `vkGetPhysicalDeviceProperties2`) were written BY HAND inside vk.zig's GENERATED sections - a regeneration
  would have erased them, `vk-abi-check` never covered them, and the subgroup bits were a namespace of u32 constants
  where the file's idiom is a packed flags struct. FIXED THE HOUSE WAY: the three structures and the command added to
  `tools/vk_gen.zig`'s lists (with the `PointClippingBehavior` enumeration their field names), vk.zig REGENERATED from
  Vulkan-Headers 367's registry (97 structures, 35 enumerations, 89 commands), `vk-abi-check` against the official
  headers green; the generated `SubgroupFeatureFlags` and `ShaderStageFlags` replace the hand constants - the host
  reads `subgroup_supported_stages.compute` and asks `hasSubgroupOperations(.{ .arithmetic = true })`. (Building the
  generator compiles vk.zig, so a half-regenerated file needs a stand-in for a missing type before the generator can
  run again.) Section 1.3's four stale statements corrected in place; section 8 gains THE NEXT TURNS, each one turn
  with its files and its check: R1 the probe's row layouts as extern structs with @offsetOf, R2 vk_gen's digit
  naming, S0.4 a ranged readback, e push constants (a spike first), d timestamps, b adoption, S0.5 the cooperative
  Cholesky, S0.6 the memory envelope, then S1's skeleton.
- Oct 31: R1 DONE - THE PROBE'S ROWS ARE TYPES. `MathsInputs` / `MathsResults`, `SpatialInputs` / `SpatialResults`
  (nesting `PairFloats`, a Motion's or Force's eight floats, and `InertiaFloats`, an Inertia's thirteen) as extern
  structs of f32 arrays, explicit padding where the old layout had it; `floatOffset(Row, .field)`,
  `floatWidth(Row, .field)` and `rowWidth(Row)` read places and sizes from `@offsetOf` / `@sizeOf` with field names
  as checked enum literals (`FieldEnum`) - `MathsRow` / `SpatialRow`'s hand-counted numbers gone (and `MathsRow`'s
  documentation, which an earlier insertion had left attached to `SpatialRow`, with them). vk_host_test's tables build
  each result with `probeResult(Results, .field, name, bar)`, place and width from the same declarations. CHECK: every
  measurement unchanged to the digit (maths 1.14 / 0 / 0 / 1.00 / 1.00 / 0 / 0 / 0 / 0 / 28.00 / 1.91, spatial
  1.62 / 8.61 / 1.00 / 1.00 / 0 / 0, the reductions and the large dispatch as before). NEXT: R2.
- Oct 31: R2 DONE - THE GENERATOR'S NAMES. `vk_gen.snakeCase`'s rule, stated in one sentence and tested: a word
  begins at a capital after a lower-case letter, and at a capital followed by a lower-case letter that comes after a
  capital or a digit (an acronym's end, a word after a number); a number begins at a digit after a letter and stands
  alone. So `deviceLUIDValid` -> `device_luid_valid` (was `device_luidvalid`), `shaderBufferFloat32AtomicAdd` ->
  `shader_buffer_float_32_atomic_add` (was `..._32atomic_add`), `storageBuffer8BitAccess` ->
  `storage_buffer_8_bit_access`, while `maxImageDimension2D` stays `max_image_dimension_2d`. (Refined from the plan's
  first wording, `float32_atomic`: numbers as words of their own is the rule the file already followed -
  `shader_float_16`, `maintenance_5` - and `2D` / `3D` must not split.) Regenerated: 24 field names change, every one
  more readable; one use in wgpu_vulkan.zig followed. vk-gen-test 7/7 (the new naming test among them), vk-abi-check
  against the official headers green, the compile check green, vk-host-test green. THE REVIEW'S CARRY-OVERS ARE DONE.
  NEXT: S0.4 a, ranged readback.
- Oct 31: S0.4 a DONE ON LAVAPIPE - RANGED READBACK. kompute: `Readback` (`.mirror`, today's way and the default;
  `.ranges`) and `Config.readback` / `Config.staging_bytes`. compute_host: a `.ranges` module gets NO heap mirror (the
  Gpu record's `mirror` is optional) and a staging buffer of `staging_bytes` rather than the size of all of `Buffers`;
  `readRange(field, first, destination)` copies the range in chunks of `staging_bytes`, each by a command submitted
  after every earlier dispatch and waited for (a poll of the timeline), so the range holds everything dispatched
  before the call; it refuses an open batch or recording, a `.mirror` module, and - at compile time - a browser build
  (`host.is_browser`: a browser cannot wait for the GPU); `readLatest` refuses a `.ranges` module by name. The CPU
  path copies from the module's globals, so a twin reads the same way. The probe is `.ranges` with 4,096-byte staging
  (1,024 floats a chunk, small on purpose); its checks all read through `readRange` now. vk-host-test's new check:
  an exact pattern uploaded, read back in three ranges - the first 100, 3,000 from 30,000 (across three chunk
  boundaries), the last 777 - equal bit for bit on the device and the twin; every earlier measurement unchanged.
  FOR THE NEXT REVIEW: the probe checks' optional results (`?ProbeOutcome`, `?bool`) can no longer be null - a
  waiting read always lands - so they simplify. NEXT: S0.4 e, push constants (a spike first).
- Oct 31: THE GPU TUTORIAL BECOMES A COURSE (Simon: "Make the tutorial much more detailed and understandable. Take this
  opportunity to make a course on zig gpu programming best practices"). gpu-compute-tutorial.html, now "GPU programming
  in Zig", ten chapters: the execution model and memory (new sections, sketches of the dispatch / workgroup / subgroup
  hierarchy and the four kinds of memory); WRITING KERNELS WELL (new chapter - one invocation per element and its
  guard, uniform control flow, helpers that never take a storage pointer, assertions on the GPU and why their location
  is compile-time, libraries in kernels - is_gpu branches, the profiler compiling to nothing, one file one module - and
  data layout with rows as extern structs); COOPERATION INSIDE A WORKGROUP (new - the shared-memory tree with its six
  halvings, subgroups, the twin of a cooperative kernel); the legaliser's subgroup capabilities and native-only
  kernels; large dispatches, reading ranges and device capabilities in the running chapter; PRECISION AND DETERMINISM
  (new - why device and twin differ, measuring in epsilons at the result's scale, cancellation, repeatability and float
  atomics). Twelve new code folds, all filled from the source by `doc-folds`; only built features described; two
  references by section number became links by name. doc-gate green. The robot tutorial's GPU chapters will link here
  for the GPU itself and keep to the simulator.
- Oct 31: S0.4 e - THE PUSH-CONSTANT SPIKE. A kernel declaring `@extern(*addrspace(.push_constant) Push, .{ .name =
  "push" })` (an extern struct of two u32) and reading it COMPILES with the build's own SPIR-V command; the module
  declares only the Shader capability; its PushConstant-class variable points at a struct decorated Block with member
  Offsets 0 and 4 - all Vulkan asks. zimr's `check` requires bindings only of UniformConstant / Uniform / StorageBuffer
  variables, so it passes; `legalize` handles the module; reflection classifies the block as no resource (no
  descriptor). `vk.zig` already declares `PushConstantRange` and the layout's push fields. The Vulkan host's compute
  pass already tracks its bound pipeline's layout (`PassSlot.pipeline_layout`) - what `vkCmdPushConstants` needs.
  The plan's S0.4 e is now three precise turns, E1 (host), E2 (kompute, compute_host), E3 (probe and check).
- Oct 31: S0.4 e - E1 DONE (THE HOST). spv_vulkan: `pushConstantBytes(words)` - a module's PushConstant block, its
  struct's members by their Offset decorations, the block's end at its furthest member's end (scalars by width,
  vectors by count x component; any other member refused, `Error.PushConstantMemberUnsupported`); measured on the
  spike's module: 8 bytes. vk_gen: `vkCmdPushConstants` among the device commands - the generator writes its function
  type AND the dispatch table's entry (the tables are generated too); 90 commands; vk-abi-check green. The Vulkan host:
  every shader module is measured when made (`ShaderModuleSlot.push_constant_bytes`); a pipeline layout keeps its sets'
  layouts (`PipelineLayoutSlot.set_layouts`); a compute pipeline whose module has a block gets a layout of its own -
  the same sets plus one compute-stage range of that size - binds and pushes with it, and destroys it with itself
  (`PipelineSlot.own_layout`), bind groups staying compatible since both layouts share the sets' layouts;
  `computePassSetPushConstants(pass, bytes)` writes against the bound pipeline's layout, refusing loudly when no
  pipeline is bound - Vulkan host only, the web's host declares no such call. Check: the compile check, lint, the ABI
  check, vk-host-test green with every shader (render ones too) measured on the way - no module has a block yet, and
  everything is unchanged. NEXT: E2, kompute and compute_host.
- Oct 31: REVIEW OF S0.4 a AND E1. BUGS FIXED: `readRange` assumed 4-byte elements and a 4-byte-multiple staging size
  (a Vulkan copy moves whole words) - now a compile error for a field of other elements and for a `.ranges` module
  whose `staging_bytes` is not a positive multiple of 4; its offsets are computed in 64 bits and refused past the
  copy's 32-bit offsets; the wait spins with `std.atomic.spinLoopHint`. A push larger than the bound pipeline's range
  was checked by nothing (a validation error far from its cause) - each compute pipeline now records its
  `push_constant_bytes`, the pass the bound one's, and a larger push is refused by name with both sizes.
  `createComputePipeline` leaked its own layout when the pipeline itself was refused - an `errdefer` destroys it; the
  layout slot's set array is initialised rather than partly undefined. `pushConstantBytes` returned whichever block
  it met first when a module had several - now the largest (`blockBytes` measures one), which every block fits.
  The probe checks' results that can no longer be null (a waiting read always lands) are plain values now. TESTED:
  the measurement's own unit test (`Assembler`): a block { u32 at 0, vec4 at 16 } is 32 bytes, a module without one
  0, a block with an array member refused; vk-host-test green; lint and the compile check green.
- Oct 31: S0.4 e DONE ON LAVAPIPE - PUSH CONSTANTS END TO END (E2 and E3 in one turn: E2's code is analysed only when a
  kernel uses it, so the probe's entry was its first real check). kompute: a kernel file's `PushConstants` (an extern
  struct, whole 4-byte words, at most 128 bytes - `requirePushConstants`, checked at compile time); `g.push()` - on
  the GPU an `@extern` in the push-constant address space, on the CPU a module variable the twin's loop reads; both
  declared only when used. compute_host: `run` and `runPushed` over one `dispatchKernel`, whose compile-time `pushes`
  keeps the native call out of every module that never pushes; `pushValues` after the bind group on all three paths
  (single, batch, recording); a browser build calling `runPushed` is a compile error. (Also fixed: `run`'s own
  documentation, which an earlier insertion had left on `reads_ranges`.) FOUND BY THE VALIDATOR: calling `g.push()`
  inside a kernel keeps the returned pointer in a function variable, which SPIR-V's logical addressing forbids ("variables
  may not allocate a pointer type") - the pointer is bound ONCE AT MODULE SCOPE, `const pushed = g.push();`, as
  `params = g.uniform()` always was; `push()`'s documentation says so. The probe: `PushConstants` { region_start,
  value }, `write_pushed`, `pushed_words` (its 8th field), `Params.pushed_region_size`. vk-host-test: ONE batch, three
  `runPushed` dispatches of 1,000 with (0, 11), (1000, 22), (2000, 33) - every word of each region its own value, on
  the device and the twin; no validation error; everything else unchanged. The course gains 7.8 Push constants and the
  module-scope rule for kompute's pointers. NEXT: S0.4 d, compute timestamps.
- Oct 31: S0.4 d - D1 DONE (TIMESTAMP BINDINGS AND HOST). vk_gen: `QueryPoolCreateInfo`, the `QueryType` enumeration
  (timestamp) and five device commands - create / destroy / reset a query pool, write a timestamp, read results;
  regenerated (98 structures, 36 enumerations, 95 commands); the `QueryPool` HANDLE declared by hand in vk.zig's
  hand-written handles section (the generator does not write handles); vk-abi-check green. The Vulkan host: a
  `QueryPoolSlot` table; `ComputeCapabilities.timestamps_in_compute` (timestampComputeAndGraphics) and
  `timestamp_period_ns` (timestampPeriod), said at bring-up - LAVAPIPE: timestamps yes, a tick every 1 ns;
  `createTimestampPool`, `timestampPoolDestroy` (deferred until the GPU is done, a new `Destroy.query_pool`),
  `computePassResetTimestamps`, `computePassWriteTimestamp` (top of the pipeline before, bottom after),
  `timestampPoolRead` (64-bit ticks, waiting) - native only, the web's host declares none. Their section opens with
  how two timestamps time a dispatch. vk-host-test green and unchanged. NEXT: D2.
- Oct 31: S0.4 d DONE ON LAVAPIPE - COMPUTE TIMESTAMPS (D2 and D3 in one turn, D2's code being analysed only once a
  pipe uses it). compute_host: `enableTimings()` - a timestamp pool of two slots per kernel, start and end, refused by
  name on a device that writes no compute timestamps; every GPU path of `dispatchKernel` brackets its dispatch with
  `timeKernelStart` (reset the kernel's two slots, write the first at the top of the pipeline) and `timeKernelEnd`
  (write the second at the bottom), both nothing on the web or without a GPU; `kernelTimings(timings)` - each kernel's
  last duration in microseconds, (ticks[end] - ticks[start], wrapping) x the device's tick, waiting for the
  dispatches and refusing an open batch or recording, zero for a kernel not dispatched since and for every kernel of a
  pipe without timings; the pool released with the pipe. The probe: `busy_work` (a pushed number of rounds a value),
  `PushConstants.iterations`. vk-host-test: 65,536 values, 2,000 rounds 160 ms and 8,000 rounds 634 ms - 3.95x for 4x
  the work - and a pipe without timings reports none. The course gains 7.9 Timing kernels. NEXT: S0.4 b, buffer
  adoption.
- Oct 31: S0.4 b DONE ON LAVAPIPE - BUFFER LENDING; S0.4 IS COMPLETE (a, b, c, d, e). compute_host: `FieldLoan` (a
  buffer, its bytes, the owner's loan count - file-level, so a pipe of one kernel module can borrow from a pipe of
  another); `lendField(.field)` (counted); `initGpuBorrowing(..., borrowed)` binds each borrowed field to the lent
  buffer instead of creating one (asserting it holds the field's bytes) and records the owner's count, `initGpu`
  being it with nothing borrowed - no caller changes; a failed init destroys only its own buffers; `deinit` gives a
  borrowed buffer back instead of destroying it, and an owner's `deinit` asserts every loan came back. vk-host-test:
  an owner zeroes and lends its `pushed_words`, a second pipe borrows it and runs `write_pushed` (77), the owner
  reads 77 in every word of its own buffer - nothing uploaded or copied between them; every loan returned. The course
  gains 7.10 Sharing buffers between pipes. NEXT: S0.5, the cooperative Cholesky in a workgroup.
- Oct 31: S0.5 DONE ON LAVAPIPE - THE WORKGROUP SHAPE (Simon, on zimrnum's tensors: "Would it make sense to use tensors
  in mujoco? Maybe not..." - agreed: MuJoCo's step is tree-shaped, sparse and fused per element, so robotgpu stays
  fused kernels over arenas, as MJW itself is; what is genuinely dense - a world's Hessian - is a routine a kernel calls
  inside one dispatch, checked against zimrnum as an independent reference). The probe's `cholesky`: one workgroup per
  matrix, order up to `max_matrix_order` = 76 (Geno's Newton Hessian; 23 KB of shared memory), factored in place
  column by column - the pivot by one invocation, the column and the trailing update with rows spread over the 64
  lanes, a barrier between; the loop bounds uniform, no barrier in a lane-dependent loop, and a workgroup past the
  matrices leaving whole. FOUND WHILE DESIGNING: robot.zig's `choleskyFactor` (now public, the twin's routine)
  subtracts each entry's products in ascending column order, the very order the workgroup's column-by-column updates
  apply them - the same arithmetic. vk-host-test, eight random SPD matrices of order 76 (B B^T + 76 I): L L^T within
  4.5e-7 of A (relative to its largest entry); the device EQUAL to the twin (0 epsilons - lavapipe fuses no
  multiplies); the twin equal to zimrnum's independent `cholesky`; two device runs identical. Bars 128 epsilons both
  ways - a GPU that fuses each subtraction's multiply may drift over 76 columns - with the reason in the check. The
  course gains 5.4 A matrix factorisation in a workgroup. NEXT: S0.6, the memory envelope.
- Oct 31: S0.6 DONE - THE MEMORY ENVELOPE; S0 IS COMPLETE. The device side, in code: `ComputeCapabilities`
  gains `max_storage_binding_bytes` (maxStorageBufferRange - what one arena may hold) and `device_local_bytes` (the
  largest device-local heap - what the arenas together must fit), said at bring-up. LAVAPIPE: storage bindings up to
  128 MB; device-local memory 3,995 MB (the sandbox's own memory - lavapipe runs on the CPU). vk-host-test allocates
  one arena as large as a binding may span (capped at 256 MB), writes a page at its start and at its very end and
  reads both back: 128 MB on lavapipe, both pages right. THE ARITHMETIC, Geno's arenas per world (nbody 25, nv 75, nq
  99, ngeom 21; at most 49 floor contacts - 4 boxes x 4, 16 capsules x 2, 1 sphere - pyramidal, 196 rows, dense J;
  world_f: the generalized vectors, 96 floats a body, 16 a dof, 16 a geom, the packed mass matrix and its factor
  (about 1,000 entries each), 32 floats a contact, the tracker's 500; scratch: the 75 x 75 Hessian and Newton's
  vectors) - estimates until S1's `layoutFor` computes them exactly:

      arena      per world        at 4,096 worlds    at 8,192 worlds
      world_f     8,940 floats    34.9 KB        140 MB             279 MB
      efc_f      16,464 floats    64.3 KB        257 MB             514 MB
      scratch     6,325 floats    24.7 KB         99 MB             198 MB
      world_u       600 floats     2.3 KB          9 MB              19 MB
      io            100 floats     0.4 KB          2 MB               3 MB
      all        32,429 floats   126.7 KB        507 MB            1013 MB

  THE LARGEST ARENA IS THE CONSTRAINT ROWS (efc_f, the dense Jacobian). On a desktop GPU - bindings of 2 to 4 GB,
  memory of 8 GB and more - 8,192 worlds fit with room. On lavapipe the 128 MB binding caps efc_f at 2,038 worlds
  (about 252 MB in all, within its 3,995 MB): the sandbox's tests run at most that many, and far fewer in
  practice, lavapipe being a CPU. A chain-sparse Jacobian (the plan's ~70 KB a world) would more than double that.
  NEXT: S1, foundations - robotgpu.zig's skeleton.
- Oct 31: S1a DONE - THE SKELETON AND THE LAYOUT. src/robotgpu.zig: the kernel module's `config` (workgroups of 64, a
  large dispatch, readback by ranges), `Buffers` (the eight arenas, sized by the `robotgpu_sizes` module), `ArrayAt`
  (offset, stride, count, padding: 16 bytes, so arrays of them sit in a uniform as written), `Counts`, `Layout` - ONE
  DEFINITION: `world_arrays`, a table of S2's 29 per-world arrays with what each one's length is made of (`PerWorld`:
  positions, velocities, body vectors / motions / frames, dof motions, geom vectors / frames, mass entries), from which
  `Layout`'s named fields are made (`@Struct`, this compiler's reification) and `layoutFor` places each array -
  world-major, every world's block padded to four floats, refusing a too-small `world_f` by name
  (`WorldStateTooSmall`); `worldIndex` = offset + world x stride + index; compile-time checks that `ArrayAt` is 16 bytes
  and `Params` whole 16-byte rows. The head of the file is a short course: the arenas, and world-major arrays drawn.
  src/robotgpu_sizes.zig (desktop: Geno at 4,096 worlds with room) and src/robotgpu_sizes_test.zig (64 worlds), the
  module chosen by the build. src/robotgpu_tests.zig, a test-fast root (the build gives fast roots the test sizes as
  `robotgpu_sizes`): for Geno's, a humanoid's and the KUKA's counts at 64 worlds every array is 4-float aligned, inside
  `world_f` and clear of the others; the refusal fires by name; world-major indexing lands where drawn - 3/3. The whole
  tree's compile check and lint green. NEXT: S1b, R4 and the topology.
- Oct 31: S1b DONE - R4 AND THE TOPOLOGY. robot.zig (R4): `Model.body_subtree_count`, filled by `countSubtrees` right
  after `refreshSubtreeMass` in `buildFromSpec` - the one place every model passes through - which also REFUSES a
  model whose bodies are not depth-first (`BuildError.BodiesNotDepthFirst`: a body outside its parent's run of
  descendants), the guarantee the GPU's tree sums rely on; `robot_urdf`'s error set extends `BuildError`, so it
  carries the new error. THE GATE: robot.zig's own tests 124/124, the robot family 643/783 (140 skipped, the slow),
  no failure - a field and a check, no arithmetic changed. robotgpu.zig: `Counts.nchain`; `model_u_tables`, a second
  table (21 tables: robot.zig's body / joint / dof index tables and the mass matrix's compressed rows, copied; and,
  derived, each body's DOF CHAIN - every dof from the root down, the root's first - with its start and length, and
  the ANCESTOR MASK, a bit per chain dof); `Layout`'s names from both tables; `layoutFor` placing the tables in
  `model_u` and refusing by name (`ModelTablesTooSmall`); `countsOf(model, nworld)`; `pack` (the chain filled from
  its end while walking up the parents, so the root's dofs land first); `world_f_array_names`, `model_u_table_names`.
  robotgpu_tests.zig: the KUKA (its spec), the humanoid and Geno (their MJCF, through mjcf and robot_mjcf) packed
  and read back - every copied table equal to the model's own, every chain equal to a second derivation (up
  `dof_parent` from the body's last dof) and every mask bit set; each arena's layout checked on its own (a first
  version checked them together and saw arenas "overlap" - each starts at 0); both refusals by name: 242/250 (8
  skipped - the root now holds mjcf's and robot_mjcf's own tests). NEXT: S1c, the constants.
- Oct 31: TESTS MADE FAST TO WORK WITH (Simon: "Robot tests are three times too long. There is a way to get a report of
  durations with command line args. Find a way to avoid testing all that as you work. Maybe disable some. Maybe tweak
  some to take less time."). MEASURED with the project's own runner (`-Dtest-timing`, `-Dtest-shards`; the sandbox has
  one core now): the robot family was 204 s of tests, and ONE test took 167.5 s of it - "the agent learns on the
  dance" (300 updates of a small agent with the planner) - every other test at most 1.7 s. That test is now a SLOW
  test (`-Dslow-tests`), its claim intact; a quick form runs by default ("the agent's parts train on the dance": 20
  decisions, about 9 updates, every loss finite and the policy updated - 6 s). The robot family: 39 s of tests now,
  643 pass, 141 skip. robotgpu's root had grown to 242 tests by importing mjcf.zig and robot_mjcf.zig by path (their
  tests came with them): the MJCF importer is now the `robot_import` MODULE for test-fast roots, with
  `robot_mjcf.importSource` (parse, read, build in one call), and the root runs its own 7 tests. claude.md's testing
  section says how to time a suite and to run robotgpu's root alone while working on it.
- Oct 31: S1c DONE - THE CONSTANTS. robotgpu.zig: `Counts.nsite`; `PerModel` gains what model_f's tables are made
  of (a vector per body / joint / geom / site, a body's inertia as sixteen floats, two or five numbers per joint);
  `model_f_tables`, a third table (22: body poses, inertias and masses; joint axes, anchors, ranges, the limits'
  softness (time constant, damping ratio) and impedance (min, max, width, midpoint, power), margin, damping,
  stiffness, reference; dof armature; geom poses, sizes in MuJoCo's convention, friction; site poses) and four more
  model_u tables (joint limited flags, geom types and bodies, site bodies); `layoutFor` places and checks all three
  arenas (`ModelConstantsTooSmall`); `pack(model, layout, model_u, model_f)` = `packTopology` + `packConstants`, last
  in the file (entry points last), the chain sketch on the topology half where it belongs. robotgpu_tests.zig: every
  constant of the KUKA, the humanoid and Geno equal to the model's own BIT FOR BIT - vectors lane by lane, inertias
  field by field, ranges with their flags, softness and impedance, geom types and sizes, sites; model_f's layout
  checked and refused like the others: 8/8. SCOPE, decided here: the INVERSE WEIGHTS at qpos0 join with R5 (S3) -
  robot.zig computes them for its own approximate diagonal and robotgpu packs robot.zig's values, one definition;
  the BOUNDING RADII join with R3's collision fields (S5); a CONVEX HULL packs its type with zero sizes, its vertices
  joining with convex collision (S8). NEXT: S1d, R1 - the shared per-element functions, under the bitwise gate.
- Oct 31: REVIEW AGAINST MUJOCO WARP (Simon: "Read again mujoco warp to make sure we follow closely. Review recent
  code. Look for bugs. Find the best verbose variable names. Improve comments."). READ: io.py's put_model (what it
  computes about the tree and the mass matrix) and smooth.py's kernels. FOUND: MJW no longer walks the tree by levels
  (`body_tree` is unused in smooth.py) but by BRANCHES - `_kinematics_branch`, one invocation per world and leaf,
  walking `body_branches[body_branch_start[b] .. body_branch_start[b + 1]]` root first; subtree sums run over
  depth-first ranges (`body_subtreenum` - our `body_subtree_count`); the sparse factorisation's updates are grouped by
  depth (`qLD_updates`), the dense path tiled. CHANGED: `model_u` gains `body_branches` and `body_branch_start`, as
  io.py computes them (one chain per leaf, the world excluded, leaves in body order; a leaf found as a subtree of one,
  thanks to R4), with `Counts.nbranch` / `nbranch_bodies` and a test (each branch starts on the world, steps parent
  to child, ends at a leaf; every leaf once); every model table carries its MJW NAME as data (`ModelTable.mjw_name`:
  body_parentid, body_subtreenum, M_rownnz, jnt_solref, qpos_spring, geom_quat...; empty for robotgpu's own chains and
  masks); GEOM TYPES packed in MuJoCo's numbering (`GeomType` = mjtGeom: plane 0 ... box 6, mesh 7 - robot.zig's tag
  order differs, and MJW's collision dispatch reads mjtGeom; a hull is MuJoCo's convex mesh); JOINT TYPES pinned at
  compile time to MuJoCo's order (robot.zig's already is: free, ball, slide, hinge); the deliberate differences from
  MJW written where they live (the inertia in robot.zig's ten-number form, damping per joint, one friction
  coefficient); clearer names (`ancestor`, `next_free_world_float` / `_model_word` / `_model_float`,
  `next_chain_entry`, `next_branch_entry`, `chain_fill_end`, `branch_fill_at`). No bug found in the packing; 8/8.
  FOR S2: kinematics as MJW's branch kernel; com_pos's subtree sums over ranges; factor_m's tables (`qLD_updates` by
  depth for the sparse path, or the tiles) computed in pack when factor_m is written, from io.py.
- Oct 31: S1d DONE, ITS SMOOTH-DYNAMICS PART - R1's SHARED FUNCTIONS FOR S2. robot.zig: `moveByJoint(pose,
  joint_type, local_axis, local_anchor, coordinates, rest_coordinate) JointMotion` - kinematics' inner step, one
  joint's motion of the pose built so far (slide along the axis; hinge or ball turning, then the OFF-CENTRE
  CORRECTION), returning the pose with the joint's world anchor and axis - and `freeJointPose(position, orientation)`;
  `kinematics` now loops over a body's joints calling them, every operation in its old order (a hinge's or slide's
  single coordinate read alone, never past qpos's end); `dofAboutAxis` and `rotateQuatByAngularVel`, already pure, made
  public for the kernels. THE GATE, BIT FOR BIT: a fingerprint of 200 steps (Wyhash over qpos, qvel, body_xpos,
  body_xrot) - humanoid 2acacc17d2834891, Geno b51c1eb44de302bf - EQUAL before and after; robot.zig's tests 124/124;
  the robot family 643/784 (141 skipped). The mocap tutorial's block on `rotateQuatByAngularVel` follows the
  declaration to `pub fn`. THE REST OF R1 joins the stage that ports it, under the same gate: one entry of M, a
  body's RNE force and a joint's share of `differentiatePos` with S2's kernels; the constraint-row functions (limit
  distance and sign, pyramid edge, reference acceleration and regulariser) with S3's.
  THE FINGERPRINT, for the next extraction - a temporary test in robotgpu_tests.zig, run with
  `-Dtest-filter="R1 gate"` before and after, then removed (std.debug.print is banned in src/):
      for humanoid.xml and geno.xml: modelFromMjcf; Data.init; 200 x robot.step;
      Wyhash over sliceAsBytes(data.pos), (data.vel), (data.body_xpos), (data.body_xrot); print the final value
  NEXT: S1e - the host and the program.
- Nov 1: S1e, FIRST HALF - ROBOTGPU AS A KERNEL MODULE, ON THE DEVICE. Code comments cleaned of plan and stage
  references (Simon's rule: comments read like a book) - thirteen of mine in the robotgpu work, five older ones of
  the same kind; 27 more in older code (retarget_plan.md and others, ten files) are A CLEANUP STILL TO DO, a careful
  pass since some sit inside sentences. THE BUILD: `ShaderPipeline.KernelModules.robotgpu_sizes`, an optional sizes
  file - the root's `--dep robotgpu_sizes` and the module's `-M` declaration - and `HostTestKernel.robotgpu_sizes`,
  given to the SPIR-V and the CPU twin alike, so both declare the same buffers. robotgpu.zig: `world_u`'s first array,
  `overflow` (a word per world, `PerWorld.single`; `WorldIntegersTooSmall`); the bindings (`g`, `world_u`, the
  uniform); the first kernel, `clear_overflow` (one invocation per world, through the layout); `kernels` and their
  installation. vk-host-test: `world_u` poisoned on the device and the twin, `clear_overflow` over 64 Geno-sized
  worlds, every overflow word zero and every other word still the poison - both. FOUND BY THE VALIDATION LAYER:
  `Counts` padded itself with `[3]u32` at offset 52, and a uniform aligns every array element to 16 bytes - spirv-val
  refused the module (lavapipe ran it anyway). Fixed with scalar padding, and `requireNoArraysInUniform(Params)` now
  refuses any array inside the uniform at compile time, by field name. NEXT: S1e's second half - robotgpu_host.Sim
  and the step program.
- Nov 1: WEBGPU EVALUATED, PLANNED AS STAGE SW (D19). Simon asked how hard WebGPU support would be, accepting lower
  speed but not a slower native. Checked: spv2wgsl translates `num_workgroups` (large dispatches portable) and refuses
  subgroup instructions; it has no push-constant path; the web boot (bridge.zig) asks for no raised limits, only the
  optional `timestamp-query` feature; in the browsers, `subgroups` is optional (Chrome since 134, limited elsewhere)
  and IMMEDIATES - WebGPU's push constants - shipped in Chrome 149-150 (June 2026), feature-detected. Section 4.T gains
  T4 with the feature-by-feature table and the estimate (about 12-20 turns, mostly engine work shared by every
  kernel); D19 places the web as stage SW after S6, with two rules from S1e: every kernel compiles in the web
  configuration too, and the host API is submit-then-collect.
- Nov 1: REVIEW, AND THE NEXT TURNS MADE EXACT. CODE: robotgpu.zig's layout simplified - the two length enums merged
  into one, `Elements` (they overlapped: body vectors, geom vectors, mass entries, a dof each), one entry type
  `ArrayDecl` for all four arenas' tables (renamed `world_f_arrays`, `world_u_arrays`, `model_u_arrays`,
  `model_f_arrays`), `namesOf`, and `placeArrays` - `layoutFor` was four copies of one loop and is four calls now, its
  comment no longer naming world_f alone; `ArrayAt.stride` has one meaning (copy to copy: a world's block, or a model
  table's one copy); `modelIndex` beside `worldIndex`. compute_host's `kernelTimings` takes `*[M.kernels.len]
  KernelTiming`, so a wrong-length buffer cannot compile. `addNativeComputeOutput`'s comment no longer cites the plan
  and says which kernels it serves. Checks: robotgpu 8/8; vk-host-test green. PLAN: MJW's smooth stages read again -
  com_pos and crb sum over subtree ranges, com_vel and rne's accelerations walk branches, factor_m uses tiles below a
  size and qLD_updates above - all of which the packing already supports except factor_m's own tables, packed with
  it. FOUND MISSING: a ranged readback that is requested and collected later (the whole-field mirror cannot serve
  arenas of hundreds of MB, and the web cannot block), now S1e-2, before Sim; `addComputeOutput` lacks robot's and
  the sizes module, needed for D19's WGSL rule, now S1e-4; a fast parity harness (the twin's kernels called directly
  in robotgpu_tests), now S2a; the course chapter on the simulator's data, at S1's review.
- Nov 1: REVIEW AND ESTIMATE, on the Windows machine, nothing compiled (Simon: "Review what has been done, and
  estimate how much time is remaining before we can train robot tracking on native gpu and webgpu ... Is there a way
  to make this code more easy to understand, or zig idiomatic?"). WHERE IT STANDS: about 36 turns since the go - the
  engine side of S0 and the simulator's data side of S1 - and no physics on the device yet. NOTHING HAS RUN ON THE
  RTX 5060: no `vk_host_test.exe` was ever built on Windows, and the Zig on PATH there is dev.349 while the sandbox
  built the tree with dev.753 (installed beside it). ESTIMATE, in turns, to the first GPU-trained Geno: the RTX run
  1-3, S1's rest 4-6, S2 12-20, S3 10-16, S4 3-6, S5 (the floor pairs) 8-12, S6 15-25 - about 55-90; the plan's full
  S3 and S5 scope adds 7-11. The web after that: SW 12-20, plus the learner's own WGSL check (zn_mlp_web_twin_plan.md,
  not started) 5-8. The widest ranges: S2d (MJW factors Geno's 75-dof tree by its sparse path, whose updates are float
  atomics, which D7 rules out - S0.5's workgroup Cholesky already factors 76 x 76), S3's line search, and S6's servo
  re-baseline on the new contacts. SCOPE THAT D15 ALREADY ALLOWS: Geno has no limits, equalities, actuators or
  sensors, and only floor pairs; the goal features depend only on clip and frame (`supertrackFeaturesInto` takes them
  in the reference's own root frame), so they can be a per-clip table. READING (proposed, not applied): `Layout` as
  declared structs nested by arena, each array's type naming its arena and element kind (fields visible in source,
  MJW names as doc comments - `mjw_name` is read by nothing - and an array of one arena unable to index another);
  load and store helpers chosen by the array's type, one set for every kernel, replacing the probe's per-binding
  copies; `placeArrays` checking capacity before narrowing to 32 bits instead of clamping; the layout tests on
  `countsOf` of the three real models, not hand-written counts; `kinematics`' two dead stores after the `moveByJoint`
  extraction; every kernel module's `config` a `k.Config`, so compute_host drops its three `@hasField` reads. NEXT:
  S1e-2, or the layout refactor first if Simon wants it before S2 multiplies its use sites.

- Nov 1: THE LAYOUT AND ACCESSOR REFACTOR, on the Windows machine, written without compiling - the compile and the
  runs are Simon's (Simon: "Refactor first. Make sure the code is perfect. I can help you test on this windows
  machine."). robotgpu.zig: `Layout` is four declared structs, one per arena (`WorldStateLayout`,
  `WorldIntegersLayout`, `ModelTablesLayout`, `ModelConstantsLayout`), each array's place a `WorldArray(arena, kind)`
  or a `ModelTable(arena, kind)` - sixteen bytes, as `ArrayAt` was, with the arena and the item kind in the TYPE.
  `at(world, item)` multiplies by the item's width at compile time; `load` / `store` / `loadVec` / `storeVec` (and
  `ModelTable.loadInertia`) reach the arena's binding as a compile-time constant (`comptime g.bind(arena)`, the value
  a module-scope binding has) and refuse at compile time a vector access on a table of scalars, or floats from words;
  `within` / `fill` / `fillVectors` serve the host's packing; the MJW names are doc comments (`mjw_name` was read by
  nothing). `placeArrays(arena, ...)` finds the arena's layout by its name, takes the copies from the array's type
  (`per_world`), refuses at compile time an array whose type names another arena, and checks the capacity before
  narrowing to 32 bits - no clamp. `pack` zeroes both images first, so a packed model is the same bytes every time.
  FIXED ON THE WAY: `cinert` and `crb` were `.body_frames`, 12 floats, and robot.zig's `Inertia` is 13 - now
  `.body_inertias`, 16, as the model's `body_inertia`. `clear_overflow` stores through the accessor. THE PROBE: one
  `loadVector(comptime field, at)` and one `storeVector` replace `loadInput` / `storeResult` / `loadSpatial` /
  `storeSpatial` - the device's test of the compile-time binding. TESTS: every count from the three real models
  (`Fixtures`, `countsOf`; the invented table is gone, and vk_host_test's overflow check takes Geno's counts from the
  engine's model too); the four refusals, `WorldIntegersTooSmall` new; world-major indexing; a new test of the
  accessors on the twin's arenas; packing read back through the kernels' accessors, each mask checked for no extra
  bits, the branches matched to the leaves in body order; a TEMPORARY "R1 gate" test asserting Oct 31's 200-step
  fingerprints. robot.zig: `kinematics`' two dead stores gone, the body's pose one value (`free:` / `jointed:`
  blocks), `JointCoordinates` naming the four floats `moveByJoint` takes - no arithmetic changed. DOCS: robots.html's
  quotes had drifted 22 lines (21 from S1d's extraction, one older), so `doc-sync` was red; its kinematics fold now
  quotes the source as it stands, with `moveByJoint` beside it; the GPU course's 4.3 shows `loadVector` and explains
  a compile-time buffer parameter. NOT DONE, the review's item on `@hasField`: compute_host cannot name
  `kompute.Config` for its own test modules (kompute.zig is a module of its own, and a file belongs to one module),
  and every real kernel module already uses `k.Config`, where a misspelt field fails to compile - the review
  overstated it. CHECKED HERE: `zig fmt --check` and `ast-check` (dev.753) on every changed file; all 60 lint rules
  with the Oct 31 zimrlint (each file shown able to fail by a planted finding: `const y = a + 1;` - a local copied
  from a bare identifier is exempt from untyped-local, so it proves nothing); doc-sync's rule and doc-folds' rendering
  by script, 0 drifted and all 18 robot and robotgpu folds equal to their source. NOT CHECKED: any compile or run.
  NEXT: Simon's runs - robotgpu's root with the R1 gate, robot.zig's root and the robot family, vk-host-test on the
  RTX 5060 (its first run there), lint-check and the doc checks; then the R1 gate test comes out, and S1e-2.
