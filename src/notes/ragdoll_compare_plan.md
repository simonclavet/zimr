# ragdoll_compare — one humanoid, two engines

Two copies of MuJoCo's `humanoid.xml` fall onto the same floor from the same pose. The left one
is simulated in **reduced coordinates** by `robot.zig`: 27 numbers, and the joints are the
coordinates, so they cannot come apart. The right one is simulated in **maximal coordinates** by
`zimrphysics.zig`: 13 rigid bodies, each with a full world pose, held together by constraints a
solver enforces every step.

The goal is not a verdict. It is a measured answer to two questions:

1. **Performance** — what does each cost per step, where does that time go, how does it scale
   with the number of ragdolls, and what does it cost to reach the same quality?
2. **Flexibility** — what can each express and do *at all*, and what does each make easy or hard?

Everything below is either something read in the code this turn (and cited), or a hypothesis
marked as one. Numbers only enter this file once they have been measured.

---

## 1. What already exists

### 1.1 The reduced side: `robot.zig`, `robot_mjcf.zig`, `robot_physics.zig`

- `robot_mjcf.build(gpa, &robot, options)` turns a parsed MJCF into an `Imported` (model,
  names, keyframes); `applyKeyframe` sets a pose. The humanoid is 1.28 m, 40.8 kg, **27 DOF**
  (free root + 21 hinges), 17 bodies counting the world.
- `rbt.Options`: `timestep`, `integrator` (`euler` | `rk4` | `implicit` | `implicitfast`),
  `solver.algorithm` (`pgs`, the default, | `newton`), `solver.max_iterations`, `warm_start`,
  `max_contacts` (sized at build; exceeding it asserts), `max_velocity` (100).
- Joint stiffness, damping and armature, fixed tendons (`ntendon`, `tendon_*`) and hinge limits
  are all native: passive forces and constraint rows in generalised coordinates.
- **No collision detector, by design.** Contacts arrive as input. `robot_physics.Bridge` keeps
  one KINEMATIC proxy per geom in a zimrphysics `World`, and each step is:

      rbt.forward -> bridge.sync -> zimrphysics.step -> bridge.harvest -> rbt.step

- **Self-collision: none.** All bodies of one articulated tree share a `group_id` (one group per
  ROOT), so zimrphysics never pairs them (`robot_physics.zig`, "ONE GROUP PER ROOT").
- **Coupling is one-way**: the robot pushes world bodies through its proxies; the world's push on
  the robot arrives as contact rows; neither solver sees the other's answer.
- **No sleeping.** A resting ragdoll costs what a falling one does.
- **Already measured** (`robot_physics.zig`, "a ragdoll comes to rest under Newton..."): this
  exact humanoid, limp, dropped tipped, 3000 steps at 1/500 s. Six seconds after landing,
  settled |v| from 1.2 m is **PGS 2.67 vs Newton 0.41**, from 2.5 m **1.39 vs 0.24**, with the
  same final pose either way. And a known gap: **MuJoCo holds max joint |v| at 0.014–0.134 on the
  same drop, ours at 0.67–1.94** — parameters import correctly, dissipation does not match yet.
  The left ragdoll will twitch at rest more than MuJoCo's would. That is a real finding about
  `robot.zig`, not a bug in this example.

### 1.2 The maximal side: `zimrphysics.zig` (a Jolt port)

- `World.createBody(BodyDef)` with shapes including `capsule` (along local Y), `sphere`,
  `tapered_capsule` and **`compound`** (posed leaves, one rigid body).
- `BodyDef` defaults that matter here: `linear_damping = angular_damping = 0.05`,
  `max_angular_speed = 0.25·π·60 ≈ 47 rad/s`, `apply_gyroscopic = false`, `friction 0.5`.
  Mass: `density`, `override_mass`, or a full `mass_props_override`. **`MassProperties` holds mass
  and principal inertia but no centre of mass** — the COM comes from the shape.
- Joints: `createRevoluteJoint` (`HingeSpec`: anchor, axis, limits, motor),
  `createSwingTwistJoint` (`SwingTwistSpec`: cone or pyramid swing, **symmetric** half-angles,
  twist min/max, motors), `createSixDofJoint` (each of 6 axes free / limited / fixed with
  **asymmetric** min/max, motors, friction), plus point, fixed, distance, slider.
- **A Jolt-style ragdoll layer**: `Skeleton`, `RagdollSettings` (one part per bone, each with a
  `SwingTwistSpec` to its parent, plus `additional` constraints of any kind), `Ragdoll`
  (`instantiate`, `setPose`, `getPose`, `driveToPoseUsingMotors`, `driveToPoseUsingKinematics`),
  and `stabilizeRagdoll`, which **rewrites masses** so parent/child ratios sit in [0.8, 1.2].
- Solver `Settings`: `velocity_steps 10`, `position_steps 2`, `baumgarte 0.2`,
  `penetration_slop 0.02`, sleeping on (`time_before_sleep 0.5`).
- Filtering is `category`/`mask` bits plus `group_id` (a shared nonzero group never collides).
  **There is no per-pair filter table** (Jolt's `GroupFilterTable` is not ported).
- **No body or constraint removal** (`Ragdoll` doc comment): a reset rebuilds the `World`.

### 1.3 Examples to borrow from

| Example | What it gives this one |
|---|---|
| `robot_sidebyside` | The same argument on a double pendulum: joint error exactly 0 on the right, "a small number that wanders" on the left. Its fairness preamble is the tone to keep. |
| `physics_sidebyside` | Two worlds on one screen; `pushViewport` for split views; a Reset that rebuilds both. |
| `humanoid` | This model on `robot.zig` + `Bridge`, the fixed-timestep accumulator, and `drawRobot`: geoms as instanced spheres and a Y-running cylinder mesh, Z-up via `zm.zUpToYUp()`. |
| `zimrphysics_demo` | `render.drawWorld` over `world.bodies` for compound/capsule bodies. |
| `robot_contact` | One-way robot↔world coupling, and how to explain its approximation honestly. |
| `robot_bench` (`zig build robot-bench`) | The headless ns-per-step harness; the natural home for the numbers. |

### 1.4 The model: `humanoid.xml`, read closely

| Body | Hinges | Notes |
|---|---|---|
| torso | free joint | two capsules (torso, waist_upper) |
| head | — | welded to torso |
| waist_lower | abdomen_z, abdomen_y | both pivot at `0 0 .065` |
| pelvis | abdomen_x | pivot `0 0 .1` |
| thigh ×2 | hip_x, hip_z, hip_y | one pivot; asymmetric ranges, hip_y **−150..20** |
| shin ×2 | knee | pivot `0 0 .02` |
| foot ×2 | ankle_y, ankle_x | **two different pivots**, `0 0 .08` and `0 0 .04`; two capsules |
| upper_arm ×2 | shoulder1, shoulder2 | orthogonal axes (`2 1 1` · `0 −1 1` = 0) |
| lower_arm ×2 | elbow | |
| hand ×2 | — | sphere, welded to lower_arm |

Also in the file: joint `stiffness` (1 default, 10 big joints, 20 abdomen_z, 6/3 ankles, 0
elbow), `damping` (.2 / 5), `armature .01`; two **fixed tendons** (`hamstring_*`, range −0.3..2)
coupling hip_y and knee; two contact excludes (waist_lower↔thigh); body geoms `condim 1`,
`friction .7`, `solref .015 1`, `solimp .9 .99 .003`; floor `condim 3`; `timestep 0.005`.

---

## 2. Building the maximal ragdoll from the same model

A converter, `maximalFromModel`, reads the **built `rbt.Model`**, not the XML, so both ragdolls
start from one source of truth for geometry, masses and axes.

**Bodies (13).** One zimrphysics body per jointed robot body. Welded bodies (head, hands) merge
into their parent's compound, which is exactly equivalent for rigid motion. Each body's shape is
a compound of its geoms (`geom_shape`, `geom_pos`, `geom_rot`), in the body frame.

**Mass.** `mass_props_override` from `body_mass` / `body_inertia` (diagonalised). The COM cannot
be overridden, so it must come out of the compound's geometry; both sides compute from geoms at
uniform density 1000, so they should agree — **Stage 0 tests it rather than assuming it.**

**Joints (12).** Chosen by how many hinges the child body carries:

| Hinges | Joint | Exact? |
|---|---|---|
| 1 (knee, elbow, abdomen_x) | revolute with limits | yes |
| 2, one pivot (abdomen z/y, shoulders) | six_dof: translation fixed, two rotation axes limited, one fixed | limits yes; the *shape* of the joint space no — see below |
| 2, two pivots (ankles) | six_dof at the midpoint | **no**: 4 cm between pivots is a massless link maximal coordinates cannot hold |
| 3 (hips) | six_dof with three limited rotation axes | limits approximately |

★★ **The honest core of the flexibility question lives in that table.** MJCF composes hinges in
sequence, so a hip's reachable set is a box in (x, z, y) angles. A six_dof or swing-twist limit is
a cone or pyramid in swing-twist space. Near the rest pose they agree; at the extremes they do
not. Stage 0 **measures** the mismatch by sampling poses rather than arguing about it.

A second variant, **"game-style"**, builds the same ragdoll through `RagdollSettings` with
swing-twist joints everywhere, the way Jolt ragdolls are made. It is less faithful, but it is
what a game would ship, and it gets `setPose`/`getPose`/`driveToPoseUsingMotors` for free. Both
variants are measured; the example offers the one Stage 0 shows is fairer, with the other behind a
toggle.

**Things with no maximal equivalent**, listed as findings rather than hidden: armature (rotor
inertia in joint space), the fixed tendons, and exact two-pivot joints.

---

## 3. The fairness contract

Default mode is **"limp"**: no joint springs, no joint damping, no armature, no tendons, on
either side. It is the only setting in which both engines simulate the *same* mechanism. A
second mode, **"as authored"**, gives each side the MJCF's passive forces as well as it can.

| Property | Reduced | Maximal | Made equal by |
|---|---|---|---|
| Geometry | robot geoms | compound of the same geoms | converter |
| Mass, COM, inertia | `body_*` | `mass_props_override` + shape COM | converter, **tested** |
| Timestep | `Options.timestep` | `zimrphysics.step(dt)` | one `dt` for both (default 1/500, the value the existing ragdoll test uses) |
| Gravity | (0, 0, −9.81), Z-up | same | both worlds Z-up |
| Body damping | none | 0.05 by default | set to 0 |
| Speed caps | `max_velocity` 100 | `max_angular_speed` ≈ 47 rad/s | raised to match |
| Gyroscopic terms | exact (bias forces) | off by default | `apply_gyroscopic = true` |
| Contact | soft (`solref`/`solimp`) | rigid + `baumgarte`, slop 2 cm | slop lowered; residual penetration **reported**, not hidden |
| Friction | 0.7 from the model | per body | 0.7 on every part and the floor |
| Self-collision | none (group per root) | none (one `group_id`) | equal by default; maximal-only toggle later |
| Sleeping | none | on by default | **off** for timing, then on as a finding |
| Mass stabilisation | — | `stabilizeRagdoll` | **off**: it changes the masses |
| Threads | 1 | 1 | both single-threaded |
| Initial state | keyframe + drop pose | `setPose` from the reduced FK | same pose, zero velocity |

---

## 4. What gets measured

Headless, native `ReleaseFast`, in the sandbox — that is where the numbers live — and the same
readouts live on screen in the browser build.

**Performance**
- ns per step, **p50 and p95**, split by phase with `z.profiler` zones:
  - reduced: `forward`, `bridge.sync`, `world.step` (collision only), `harvest`, `rbt.step`;
  - maximal: `world.step`, plus the world's own internal split where it exposes one.
- Solver effort: constraint rows, contacts, iterations used, residual.
- **Scaling**: N = 1, 4, 16, 64 ragdolls per engine, separate trees in one world.
- **Cost of equal quality**: for each dt in {1/500, 1/240, 1/120, 1/60}, the step time *and* the
  quality numbers below, so "faster" is never quoted without "at what error".
- Memory per ragdoll: model + state bytes.

**Quality**
- Joint error (maximal only): pivot separation in mm and limit overshoot in degrees, max over
  joints. Reduced prints its zero, which is the point.
- Energy (kinetic + potential) over time; peak body speed; **time to rest** (every body below
  0.05 m/s for 0.5 s) or "never".
- Deepest floor penetration.
- Where each ends up: pelvis height and pose after 6 s, over several drops — they will diverge
  chaotically, so they are compared as distributions, not frame by frame.

**Robustness**: drop height 1.2 / 2.5 / 10 m, an initial tumble, and a large dt, recording which
engine stays sane and how.

---

## 5. Flexibility — every row gets a demonstration, not an opinion

| # | Capability | Reduced (`robot.zig`) | Maximal (`zimrphysics`) | How the example shows it |
|---|---|---|---|---|
| 1 | Joint types | any hinge/slide/ball chain, exact | catalogue: hinge, swing-twist, six_dof… | joint table overlay; ankle pivot error |
| 2 | Joint limits | exact, in joint angles | swing-twist / pyramid approximations | limit-mismatch readout (Stage 0 sampling) |
| 3 | Joint drift | zero by construction | nonzero; grows with speed, mass ratio, dt | live mm readout; `robot_sidebyside`'s argument |
| 4 | Tendons, armature | native | none | "as authored" mode |
| 5 | Other dynamic bodies | one-way via proxies | two-way, native | **drop a crate on both** |
| 6 | Self-collision | none by default | group or category bits (32-part budget) | toggle, maximal side |
| 7 | Sleeping | none | built in | step-time plot collapses on the right when it rests |
| 8 | Breakable joints | rebuild the model | disable a constraint (`enabled`) | "break an arm" button, maximal side |
| 9 | Active ragdoll (hold a pose) | PD / inverse dynamics on joint coords | motors, `driveToPoseUsingMotors` | "hold keyframe" toggle on both, tracking error |
| 10 | Animation ↔ ragdoll switch | write qpos/qvel | `setPose` + body velocities | "stand up / collapse" buttons |
| 11 | Parallelism | per-tree serial | islands parallelise (not used here) | noted, not shown |
| 12 | Batched headless rollouts | imports only zimrmath; GPU batching plausible | the whole collision engine | noted, not shown |
| 13 | State size | 28 + 27 floats | 13 × (pose + velocity) | readout |

Hypotheses to test, not conclusions: reduced wins on exactness, drift and limits; maximal wins on
interaction, sleeping and runtime topology changes; on raw step time for one ragdoll it could go
either way, which is exactly why it gets measured.

---

## 6. The example: `ragdoll_compare`

- **Layout**: one 3D scene, one shared-looking floor, the two ragdolls two metres apart,
  labelled "REDUCED · robot.zig" and "MAXIMAL · zimrphysics". Two separate worlds underneath, so
  every microsecond is attributed to one engine. Orbit and pinch like `humanoid`.
- **Controls** (touch-sized, one compact panel): Drop / Reset, Pause / Step, drop pose (the four
  keyframes, "tipped", "tumble"), drop height, dt, per-side solver (PGS/Newton + iterations;
  velocity/position steps), limp / as authored, and the flexibility buttons from §5.
- **Readout**: per side, step time p50/p95 with the phase split, rows, contacts, joint error,
  energy, penetration, asleep; one small plot of step time over the last few seconds.
- **Registration**: one line in build.zig's example list, next to `robot_sidebyside`.

---

## 7. Stages — each ends at a gate

**Stage 0 — headless, no GPU needed.** The converter and a bench case (`robot_bench` case 5, or
`zig build ragdoll-bench` if it outgrows that file). Tests:
1. total mass equal (40.8 kg), per-body mass/COM/inertia equal within 1e-5;
2. at `qpos0`, every maximal body pose equals the reduced FK;
3. no gravity, no contact: maximal joint error stays under 1e-6 for 10 s;
4. free fall, no floor: both COM trajectories match z₀ − g·t²/2;
5. the drop: both come to rest with pelvis height in [0.05, 0.5] m, maximal joint error bounded;
6. limit mismatch: sample 10 000 random in-range hinge poses, report the fraction the maximal
   limits reject, per joint.

Gate: tests green; the §4 numbers for one ragdoll, both variants, recorded in §9.

**Stage 1 — engine gaps Stage 0 exposes**, each a small change with its own test (for example a
world-level torque/impulse call for passive springs, or asymmetric swing limits if six_dof is not
enough).

**Stage 2 — the example, minimal**: two ragdolls, drop, reset, pause, step time. Gate: smoke and
leak test green (reset rebuilds both worlds), standalone HTML for a real GPU.

**Stage 3 — instrumentation**: phase split, joint error, energy, the plot.

**Stage 4 — flexibility toggles** from §5, one at a time, each checked on screen and headless.

**Stage 5 — write-up**: §9 filled in and a comparison table a reader can trust; optionally a
tutorial section.

---

## 8. Decisions (Simon, Sep 18: "go with what you propose")

1. **Baseline "limp"** on both sides. ✓
2. **dt 1/500** by default; 1/240, 1/120, 1/60 as sweep points. ✓
3. **Both maximal variants measured** in Stage 0; the fairer one becomes the example's default. ✓
4. **Self-collision: TOGGLES** — Simon asked for them. Off by default on both. The maximal
   toggle is filtering (one `group_id`, or per-part category bits for selective pairs); the
   REDUCED toggle is new engine work, because the Bridge puts a whole tree in one group — it
   needs per-body groups with parent/child pairs excluded, and `harvest` must accept contacts
   between two bodies of one tree. Planned as a Stage 1 item.
5. **Stage 4: all thirteen rows.** ✓

---

## 9. Journal

- **2163, Sep 18** — plan written after reading `robot.zig`, `robot_mjcf.zig`,
  `robot_physics.zig`, `zimrphysics.zig` (bodies, shapes, joints, `Ragdoll`, `Settings`,
  filtering), `humanoid.xml`, and the `humanoid`, `robot_sidebyside`, `physics_sidebyside`,
  `robot_contact`, `zimrphysics_demo` and `robot_bench` headers. Nothing built yet.
- **2163, Sep 18 — Stage 0 begun.** `src/robot_maximal.zig`: `build` (robot `Model` -> 13 parts,
  12 joints; head and hands welded into their parents), `Ragdoll.setPose / bodyFrame /
  jointError / centerOfMass / peakSpeed`, `limpReduced`; in `test-fast` through
  `src/robot_tests.zig`, and alone as `zig build zn-robot_maximal`. Measured:
  - **Mass properties equal**: 40.8440 kg on both sides; worst part mass 9.7e-8 relative, COM
    1.2e-7 m, inertia 7.3e-7 relative — **after fixing a zimrphysics bug the test found**: its
    capsule's perpendicular inertia treated both end caps as one sphere at the centre, so every
    capsule tumbled on 20-58% too little inertia (the shin: 0.0188 against MuJoCo's 0.0326).
    The fix is the exact hemisphere term, m·(2r²/5 + h²/4 + 3hr/8).
  - **Bookkeeping exact**: every part's frame reads back as the reduced FK to 6e-8. At the tipped
    drop pose, joints whose hinges share a pivot coincide to 2.7e-7 m; the **ankles, whose two
    hinges pivot 4 cm apart, are 19.8 mm apart** — the measured cost of one pivot for two.
  - **Free fall identical**: 250 steps, expected 1.23116 m, reduced 1.23115, maximal 1.23115.
  - **The drop, 6 s at 1/500, limp**: reduced torso 0.175 m, settled |v| 0.105, 24 contacts.
    Maximal, game-style limits: **never settles** (peak speed 3.6-5.5) and joints open by
    **192 mm at peak in every configuration**, final 23-60 mm. Gyroscopic terms make it worse
    (5.53 vs 4.26); 40 velocity steps help (3.55, 22.8 mm) and do not fix it. **With limits off
    the same ragdoll settles to speed 0.000 and joint error 0.0 mm** (peak 12.7 mm = closing the
    ankle gap). So the LIMITS fight the pose: the drop starts from `keyframes[0]`, and its hip
    and knee angles decompose outside cones built with the twist on the FIRST hinge (hip_x,
    only -30..10).
  - **Next**: report which joints' limits the drop pose violates; put the twist on the bone's
    long axis (hip_z for a thigh); build the faithful six_dof variant with asymmetric limits;
    the limit-mismatch sampling test; ns/step in `robot_bench` under ReleaseFast.

- **2163, Sep 18 (later) — limits diagnosed, Stage 2 begun.**
  - **zimrphysics' swing-twist cone names were documented backwards.** Its `SwingTwistSpec`
    said `plane_half_cone` limits rotation ABOUT the plane axis; the implementation (Jolt's
    meaning) limits the swing WITHIN the twist/plane plane, i.e. rotation about the normal.
    Found by a one-hinge probe: bend ONE hinge to 10% / 90% of its MJCF range, everything else
    at rest, gravity off, step once, and see whether that joint moves. Pushed probes: 12/42
    (twist on the first hinge) and 16/42 (twist on the last) before the fix — every one on a
    swing-twist joint, in exactly the swapped pattern; **0/42 after** (both twist choices).
    Comments fixed in zimrphysics; `robot_maximal` maps the cones the right way round.
  - **`setPose` places parts by maximal kinematics**: rotations from the reduced pose, positions
    down the tree through the maximal pivots. Every joint now starts closed (2e-8 m shared
    pivots, 6e-8 m split); the ankle approximation shows as feet 19.8 mm from the reduced FK.
    Copying positions had made the solver's first step yank a 2 cm gap shut through each leg.
  - **The drop, split by which limits the maximal side carries** (6 s, 1/500, limp, gyroscopic
    on, 10 velocity steps): ALL — never settles (7.7 m/s), joint gap peak 161 mm, final 27 mm;
    HINGES ONLY — settles (0.11), peak 118 mm, final 9.4 mm; NONE — settles (0.000), peak
    5.5 mm, final 0.0 mm. Slack on the 2-hinge bodies' missing axis (0 / 0.35 / 0.7 rad) does
    not help, so it stays 0. **At the squat drop pose every joint is pushed** even though each
    hinge alone passes: MJCF's box of hinge angles and the swing-twist pyramid disagree for
    COMBINED bends — the flexibility finding in its plainest form.
  - **Open for Stage 1**: why swing-twist limits stop this ragdoll settling, and why hinge
    limits alone open joints by 12 cm transiently (engine work, measured first); the faithful
    six_dof variant; ns/step in `robot_bench`.
  - **Stage 2: `examples/ragdoll_compare`.** Orange = reduced, blue = maximal, drawn 1.6 m
    apart from two worlds. Panel: µs/step per engine (half-second windows, since a browser clock
    is coarse), speed, contacts, joint gap and its peak, maximal limit mode (all / hinges only /
    none, which rebuilds), drop again, pause. Smoke PASS (init 4181 calls, ~3393 per frame, GPU
    handles flat over two lifecycles); standalone `ragdoll-compare-standalone` 2.68 MB.

- **2163, Sep 18 (evening) — REACHING POSES, both models** (test "reaching a pose"). Torso
  WELDED to the world in both (the `<freejoint>` stripped; the converter builds a world-welded
  body as a static part), gravity on, limp, 1/500, no floor. One metric for both: the worst
  joint's rotation error against the target, from body rotations. At 2 s:

      method                                  HOLD rest   REACH squat
      reduced PD kp400 kv20 (the ladder's)    44° (osc.)  131°
      reduced PD + exact gravity comp          0.00°      149°
      reduced COMPUTED TORQUE 5 Hz             0.00°      0.00°
      reduced computed torque 10 Hz            0.00°      0.00°
      reduced inertia-scaled PD + gravity      0.00°      151.8° (one joint never moves; open)
      maximal motors 5 Hz                     17.7° sag   43.7°
      maximal motors 10 Hz                     4.6° sag   10.8° (17.7° peak, last 0.5 s)
      maximal motors 20 Hz                     1.15° sag  blows up against the limits
      maximal motors 10 Hz, limits opened      19.0°      20.2°

  * **Reduced + computed torque is exact**: tau = M(q) a_des + c(q, v) from robot.zig's own
    `inverseDynamics`, a_des a critically damped 5 Hz spring per joint. It holds and reaches the
    squat to 0.00°. This is the controller the anim-following plan should stand on; the policy
    interface stays "a target pose", so DReCon's PD-target offsets become CT-target offsets.
  * **The ladder's plain PD is unstable here** — explicit damping on light limbs at 500 Hz with
    no armature — and exact gravity compensation does not rescue it (149°): the PD is the
    unstable part. The ladder's rung 2 passed at 2 kHz with the floating root SNAPPED BACK each
    step, and a first version of this test showed why that matters: within each step the body
    free-falls and its joints carry no gravity load. Rung 2 should be re-run on a fixed base.
  * **Maximal motors are springs solved in the solver**: stable at any frequency, frequency-
    stated so a hand and a thigh behave alike, and they SAG under gravity as 1/f² (17.7 / 4.6 /
    1.15°), because the maximal model has no joint-space dynamics to compensate gravity with.
    Reaching the squat is blocked by the limit mismatch (Stage 0), and 20 Hz fights it hard
    enough to blow up. With cones opened to π the swing-twist motors hold only ~20° — a Stage 1
    engine item.
  * **Next for the anim-following plan**: the free-root rungs (ladder 6-7) need the
    underactuated form — CT on the hinge rows, contacts and balance supplying the root.

- **2163, Sep 18 (night) — STIFF, STABLE POSE REACHING AT 60 Hz.**
  - **The stability math, confirmed by measurement.** Computed torque makes each joint a
    spring-damper a = w²e - 2ζwv; stepped by semi-implicit Euler (robot.zig's order: v, then
    q from the new v) it is stable only while h² + 4ζh < 4, h = w·dt — for ζ = 1, h < 0.83,
    i.e. **7.9 Hz at 60 Hz**. Measured on the fixed base at 60 Hz: 5 Hz (h 0.52) and 7 Hz
    (h 0.73) reach the squat to 0.00°; 9 Hz (h 0.94) fails (108.9°).
  - **The implicit spring is unconditionally stable** (`stableSpringAccel`): ask for the spring
    at the END of the step and solve, a = [w²(e - dt·v) - 2ζwv] / (1 + 2ζh + h²) — backward
    Euler, Tan et al.'s stable PD in computed-torque form. At 60 Hz, fixed base: **5, 10, 20
    and 60 Hz all reach and hold the squat to 0.00°.**
  - **A free root needs FLOATING-base inverse dynamics** (`floatingBaseTorques`): the root rows
    must be zero, so a_r = -M_rr^-1 (c_r + M_rj a_j) and the torques are the joint rows of M a + c
    with that a_r. The fixed-base rows threw the falling body off at the velocity cap.
  - **robot.zig lacked MuJoCo's `refsafe`** — every soft constraint's time constant clamped to
    at least 2·timestep. The limp humanoid at 60 Hz, its contacts asking for 0.015 s against a
    0.033 s floor, fell through the floor to -58 m. Clamped in `projectConstraints`; limp at 60 Hz
    now lands and settles (0.06 m/s); the whole robot family's tests pass unchanged.
  - **Result, free root, falling onto the floor, one step per 60 Hz frame, holding the squat:
    reduced with implicit CT + floating-base ID — 12.3° at 10 Hz, 7.0° at 20 Hz, settled.**
  - **The maximal side does not hold it yet.** Its motors at 60 Hz, fixed base: hold 17.6 / 4.6
    / 1.2 / 0.5° at 5 / 10 / 20 / 60 Hz and reach to ~10° at 10-20 Hz. Free and on the floor, no
    variant holds — the final error stays at the limp value (~171-179°) with limits on or off,
    gyroscopic on or off (off cuts the joint gap to 16 mm), 10 or 40 velocity steps, torque
    unbounded or 300. Next: split FLIGHT from CONTACT (does it hold the squat in the air?).
  - **Example:** a 500 Hz / 60 Hz toggle; "hold the squat" drives the reduced side with implicit
    CT through floating-base ID at 20 Hz and the maximal side with 10 Hz motors.

- **2163, Sep 18 (late) — the device run, and a zimrphysics HINGE FRAME BUG.**
  - **First numbers from a phone** (Chrome, Android, standalone, 60 Hz, limp): reduced
    **735 us/step**, maximal **194 us/step** — the maximal ragdoll is ~3.8x cheaper per step.
  - **The "maximal shakes" screenshot was not a browser difference.** The same test compiled to
    wasm32-wasi (simd128, ReleaseSmall) and run under node's WASI prints the native numbers to
    the digit; the phone's peak gap, 84.7 mm, is exactly the headless value for "hold the squat"
    ON with 10 Hz motors at 60 Hz — the page had been held, then released, and a released
    ragdoll stays wherever the motors left it until "drop again".
  - **Flight vs contact.** Free body, no floor, 10 Hz motors, rest -> squat: upright 21.6 ->
    13.4 -> 4.6 deg at 0.5 / 1 / 2 s; the SAME drive with the body turned 80 deg: 31.8 -> 137 ->
    97 deg. A correct rigid-body engine cannot care which way the whole body faces.
  - **The bug:** zimrphysics' hinge stored `inv_initial = A0 B0^-1` and measured
    `conj(A) inv_initial B` — a relative rotation in the PARENT's local frame — about the WORLD
    hinge axis. Right only while the parent is unrotated. Now Jolt's world-frame form:
    `inv_initial = B0^-1 A0`, `diff = B inv_initial A^-1`, at creation and all three angle sites.
  - **What it changes.** Tipped drive: 22.4 -> 13.7 -> 5.1 deg, the upright numbers. The floor
    at 60 Hz with 10 Hz motors (limits off): 41 deg, 1.6 m/s, gap 24 mm (was 171 deg, 53 m/s,
    85 mm); 4 substeps: gap 8 mm. The drop with HINGE limits only now settles perfectly
    (0.000 m/s, peak gap 5.5 mm; was 118 mm) — Stage 0's "hinge limits open joints by 12 cm"
    was this bug. At the drop pose the hips are no longer pushed (0.004 rad; was 0.26-0.37);
    the ankles and waist still are (0.35 / 0.13 rad) — their 2-hinge combined bends leak onto
    the locked third axis, which is genuine. ALL limits still never settles (4.0 m/s, peak
    145 mm): the swing-twist limit is the next suspect, and gets the same rotated-body test.

- **2163, Sep 18 (late) — standing, and the dance ladder.** Device run (hinge limits only):
  maximal settles to a 0.1 mm joint gap (peak 4.3 mm); 391 vs 96 us/step on this run. New test
  "standing": the standing pose (qpos0) held on the floor at 60 Hz, torso free — **both engines
  fall, 1.40 s (reduced, implicit CT 20 Hz) and 1.45 s (maximal, motors 20 Hz)**; shoved 0.5 /
  1.0 m/s, 0.55-0.9 s. A perfectly held pose is a statue, and this statue is a pendulum: balance,
  not pose accuracy, is what stands between here and the dance. The consequences for the
  anim-following plan are written up in `servo_ladder.md` §8 (rungs B0-B2, S0-S2, R0-R1, L0).
