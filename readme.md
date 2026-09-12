A zig port of raylib, imgui, implot, box2d / jolt physics, and MuJoCo-style robot
dynamics, for wasm/webgpu. Includes transpilers from zig to wgsl (gpu) and
javascript (web) so we can live in a pure zig world. Work in progress.

Live demo gallery: https://simonclavet.codeberg.page/Zimr/

The long writeup, with the launcher running live in the page: https://simonclavet.codeberg.page/Zimr/readme.html

## Robot dynamics

`src/robot.zig` is a reduced-coordinate articulated-body simulator in the style of
MuJoCo — joints are exact by construction rather than constraints a solver has to
maintain. It reads MJCF, so models from the MuJoCo Menagerie load directly.

## Motion capture and retargeting

`src/codecs.zig` reads **BVH** and **FBX**, so a skeleton and its animation load
from whatever tool produced them. `examples/geno_dance` plays a skinned character
and drives a MuJoCo robot from the same clip.

Three calls, in `src/robot.zig`:

    const scale = robot.captureScale(&model, frame);
    const n = robot.buildPointSamples(&model, inputs, &samples);
    robot.solvePointCloud(&model, &data, samples[0..n], opts);

`captureScale` converts the capture's units to the robot's metres.
`buildPointSamples` runs once per robot-capture pairing and returns the sample set.
`solvePointCloud` runs per frame and leaves the pose in `data`. A `MatchRow` table
states which capture joint drives which robot body; it accepts alternative joint
names and ignores exporter prefixes like `mixamorig:`, so one table serves several
rigs.

Retargeting is one optimisation rather than a pipeline of stages. Each frame
minimises

    E(q) = Σ ‖ T_b(q)·s_bk − ŷ_bk ‖²  +  λ_lim Σ barrier(q_j)  +  λ_smo ‖q ⊖ q_prev‖²

over the whole configuration by Gauss-Newton: sample points on the robot's bodies
matched to where the capture puts them, joint limits as a soft barrier, and a term
holding the pose near the previous frame.

Sample points rather than joint rotations, because one point on a body fixes its
position, two fix its direction and three fix its twist. Aiming a bone, choosing a
bend plane, resolving a limb's swivel and converting a rotation between
differently-built skeletons are then the same operation, and a body carrying too few
samples is under-constrained in a way the sample count makes visible.

Two choices matter for quality. Joint limits enter as a **soft barrier**, so the
solve slides along a limit rather than sticking against a clamp and jumping between
the answers on either side. And limb targets take their **direction from the capture
and their length from the robot**, keeping every target reachable when the skeletons
differ in proportion; `position_pull` blends between that and the capture's own joint
positions.

Correspondences — twist offsets, foot heel and toe, leaf orientation — are measured
once from the rest pose and reused per frame. A sample whose target misses its own
point at rest is dropped, so a mismatched joint pair is excluded rather than fought.

`examples/geno_dance/humanoid_flex2.xml` is the stock humanoid adapted to one
capture: arm lengths and spine proportions matched, one shoulder axis added, a toe
bone added.


Every subsystem is checked against MuJoCo's own numbers rather than against
plausibility:

Two kinds of evidence, kept distinct because they are not equally strong:

| | checked against | how |
|---|---|---|
| forward kinematics | MuJoCo's `xpos`, every body, to 1e-4 | generated fixture |
| mass matrix, `cinert`, `cdof` | MuJoCo's `mj_fullM` and friends | generated fixture |
| bias forces, accelerations | MuJoCo's `qfrc_bias`, `qacc` | generated fixture |
| Jacobians | MuJoCo's `mj_jacBodyCom` | generated fixture |
| constraint rows and softness | MuJoCo's `efc_J` / `efc_pos` / `efc_aref` / `efc_R` | generated fixture |
| constraint forces | `m·g`, and MuJoCo's resting depth | closed form |
| actuators | every gain, gear and transmission, hand-derived | closed form |
| tendons | length, rate, and the transpose that spreads the force | closed form |
| sensors | MuJoCo's own readings for the same model and state | fixture |
| integrators | an rk4 reference at dt = 1/20000 | self-consistency |

The **generated fixtures** are real MuJoCo output: `scripts/robot_oracle.py` runs
mujoco 3.11 over eleven models and writes `src/tests/fixtures/robot/reference.zig`.
The **closed forms** are quantities derivable with a pen — which makes them oracles
that do not depend on MuJoCo being right either, and in that sense the stronger
check, but they are single states rather than a swept corpus.

Speed is a build step rather than a claim: `zig build robot-bench` runs four models
for 200 000 steps each and prints ns/step. Case 4 fails the build if the Go1 is not
actually holding the pose the case is named for. On one 1-core box, mid-2026:

    two-link arm    nv  2     292 ns/step
    KUKA iiwa       nv  7    1664 ns/step
    KUKA, limits    nv  7    2376 ns/step
    Go1 standing    nv 18   12313 ns/step  (pgs)   22273 ns/step  (newton)

`scripts/robot_bench_mujoco.py` is the other half — the same models under `mj_step`,
so the comparison is on your machine rather than on a number in a readme. Compare
Newton against Newton: MuJoCo's default solver is Newton, and quoting our PGS
against it flatters us by about 1.8x for a reason that has nothing to do with speed.

Two constraint solvers, because the right one depends on the scene. PGS is roughly
twice as fast where contacts are few and weakly coupled — and does not reach the
tolerance on a standing quadruped, stopping on its stall detector at a few times
`tolerance` rather than at it. Newton converges there in two iterations, and settles
a six-box stack that PGS cannot in a hundred. PGS is the default because "close, and
fast" beats "exact, and slower" for most scenes; `solver.algorithm = .newton` is one
field when it does not.

**Planning, not just control.** `robot_mpc.zig` is iLQR over a horizon: a backward
Riccati pass, a line-searched forward pass, and a box-constrained `Q_uu` solve so
the plan respects the torques an actuator can actually produce. On a linear system
it reproduces hand-derived LQR gains to 0.1%. On a cartpole with a motor too weak
to lift its own pole — 0.164 N·m available against the 0.294 N·m gravity asks at
horizontal — it finds the pump: swing the wrong way, build energy, come back up.

`examples/mpc_cartpole` runs that live, in a browser tab, with the plan drawn as a
ghost trajectory so you can watch the optimiser think. The frame budget is the
architecture: a warm re-solve is 0.35 ms, but a cold swing-up solve is ~100 ms, so
the unit of work is one iLQR iteration and a frame does as many as it can afford.

Demos: `examples/humanoid` (27 DOF, ragdoll, live solver and softness knobs),
`examples/quadruped` (Go1 from Menagerie), `examples/gripper` (IK and a geared
gripper), `examples/cartpole` (a policy learning to balance, live),
`examples/mpc_cartpole` (a planner swinging one up, live), `examples/geno_dance`
(BVH and FBX captures driving both a skinned character and a robot, retargeted live).

The tutorial — `src/notes/tutorials/robots.html` — builds the whole thing from
spatial algebra upward, and Part VII derives LQR from a single quadratic, turns it
into iLQR, and reads the optimiser that does it.
