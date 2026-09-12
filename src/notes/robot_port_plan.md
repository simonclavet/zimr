# robot.zig — port plan

**One sentence:** `src/robot.zig` adds *reduced-coordinate* articulated-body dynamics
(MuJoCo's model) to zimr, consuming zimrmath and zimrphysics for everything they already
do, so that zimr can simulate a robot **correctly** rather than approximately.

Read `src/notes/tutorials/mujoco-tutorial.html` first — it is the conceptual half of this
plan. This file is the engineering half: decisions, phases, seams, and the problems we
expect to hit.

**STATUS: the engine is complete and beats MuJoCo on every benchmark case.** A real KUKA
iiwa imports from URDF, renders with its own meshes, and pushes crates that push back. See
"Where things stand" for the current picture and "THE ROAD TO A QUADRUPED" for what is next.

Per claude.md this plan carries its own record: each completed phase ends with what actually
happened, and §4f collects the lessons whose shape recurs.

---

## How to read this document

It is long because it is a LOG, not a specification: decisions with the evidence that
produced them, including the wrong turns. That is deliberate — a plan that records only its
conclusions cannot stop anyone repeating the attempts that failed.

**If you are picking this up cold, read these five and skip the rest until you need it:**

| section | what it settles |
|---|---|
| **Where things stand** (below) | what exists today, in one screen |
| **THE ROAD TO A QUADRUPED** | the next 20 turns, with acceptance criteria |
| **§4k — the coupling, reconsidered** | why free bodies live in the robot's tree, and the momentum proof |
| **PHASE A COMPLETE** | the contact-quality investigation: two positional lags, four wrong hypotheses |
| **§4f — standing lessons** | the mistakes worth not repeating, mine included |

Everything else is reference: phase-by-phase derivations (§2–§3), the MuJoCo comparisons
(§4e, §4h, the `engine_core_constraint.c` read), the import work (§4i), and the performance
measurements (§4g).

**Conventions used throughout.** A ★ marks a decision that was not obvious and has a reason
recorded beside it. A ✅ marks something landed and verified. Tables of measurements are
always real numbers from a real run, never estimates — if a figure appears here, a command
produced it.

---

## Where things stand

**Engine: complete.** Phases 0–10 all landed. `src/robot.zig` is ~8.5k lines and 97 tests —
spatial algebra, kinematics, mass matrix, bias forces, Jacobians, actuators, joint limits,
soft constraints with a PGS solver, contacts, fixed tendons, sensors, and an
implicit-in-velocity integrator. Oracle-verified against MuJoCo throughout.

**Seam: a DETECTOR, not a simulator (§4k).** `src/robot_physics.zig` steers a kinematic proxy
per geom and hands back contacts; zimrphysics resolves nothing the robot cares about.
`src/robot_scene.zig` composes robots and free bodies into one tree, so a contact between an
arm and a crate is one constraint between two inertias — momentum conserved by construction,
measured at 0.002%.

**Contact quality: settled.** Every case — flat, edge-balanced, corner-balanced, five-crate
tower, arm sweeping a pile — converges in **1–2 solver iterations** with residual |ω| of
zero. Getting there took five sessions and the answer was two positional lags in the seam,
not anything in a solver.

**Import: working.** `codecs.xml` (7 tests) and `src/urdf.zig` (8 tests) land the reader
and the semantic layer; the real KUKA iiwa imports as an 8-body, 7-DOF chain. What remains is
the emitter (§4i-ter) and a 3D example.

**Demos:** `robot_demo` (11 scenes), `robot_pendulum`, `robot_sidebyside`, `robot_contact`.

**★ THE TARGET: a quadruped carrying a crate and walking across crates that move under its
feet**, with reinforcement-learned gaits after. See "THE ROAD TO A QUADRUPED" for the next 20
turns; §4k explains why the architecture changed to make it possible.

**Immediate work:** Phase A — free bodies in the robot's own tree, which removes the
two-solver seam rather than patching it.



---

## 0. Scope

**In:** kinematic tree, generalized coordinates, mass matrix (CRB), bias forces (RNE),
sparse LᵀDL factor/solve, Jacobians, actuators, tendons, soft constraints, sensors,
integrators (semi-implicit Euler, RK4, implicit-in-velocity), inverse dynamics.

**Out, permanently:** collision detection (zimrphysics owns it — this is the whole point),
rendering (zimr draws), XML/MJCF/URDF parsing (the model is Zig; a loader can *generate*
Zig later), deformables/flex, SDF collision, plugins, muscles.

**Out, for now:** closed-loop equality constraints beyond `connect`/`weld`, elliptic
friction cones, the Newton solver, islands, sleeping.

---

## 1. Decisions taken up front

These are the choices that are expensive to change later. Each is a decision, not a
default, and each has a reason.

### 1.1 Precision: f32 everywhere, with a localized f64 escape hatch

MuJoCo is `double` (`mjtNum`) throughout. zm is **f32-only** (`Vec = @Vector(4, f32)`).

**Decision (Simon): f32. zm is the foundation and the core uses it — `Vec`, `Quat`,
`Mat3`, `dot3`, `cross`, the whole vocabulary.** A robot model does NOT get to choose its
precision; there is one numeric type in zimr and this is it. Abandoning zm for a private
`Vec3r` would make robot.zig a foreign body in its own tree, and that cost is real even
though it does not show up in a benchmark.

**The risk this accepts, stated plainly:** the mass matrix of a chain with a large mass
ratio (a 100 kg torso and a 10 g fingertip) has a condition number in the millions. An
LᵀDL of that in f32 loses most of the mantissa. The symptom is a robot that goes mushy or
diverges with no obvious cause, and there is no device screenshot that diagnoses it.

**The escape hatch, designed now so it is not a scramble later.** The conditioning risk is
not spread evenly across the pipeline — it is concentrated in exactly one place:

| stage | conditioning | precision |
|---|---|---|
| kinematics, comPos, Jacobians, RNE | benign — sums of similar-magnitude terms | f32 |
| CRB accumulation | mild — 10-float adds down a subtree | f32 |
| **`factorM` / `solveM` (LᵀDL)** | **this is where mass ratios bite** | **f64 internally** |
| the constraint solve | moderate; watch it | f32, revisit |

So when the first problem appears, the fix is: **`factorM` takes f32 in, widens to f64 in
a fixed-size local scratch, factors and back-substitutes there, and narrows on the way
out.** Contained to two functions. It does not touch `Data`, the model spec, the API, or
any other algorithm — and crucially it is invisible to the user, which is precisely what
"I don't want each robot to have to choose" requires.

Do **not** build this preemptively. Build f32, add the conditioning probe below, and widen
`factorM` the day the probe fires or a demo misbehaves.

**Instrument for it from phase 2**, so the failure is diagnosable rather than mysterious:
a debug-only estimate of `cond(M)` (cheap version: `max(D)/min(D)` from the LᵀDL diagonal,
which is free — we already computed `D`) with an `assertf` past a threshold, wrapped in
`if (comptime zm.allow_assert)`. When someone's robot misbehaves, the first question is
answered before it is asked.

**Armature is required and non-zero by default.** It is diagonal regularization of `M` and
it is the cheapest defence we have against this whole class of problem. MuJoCo treats it
as a physical parameter (rotor inertia through a gearbox), which it is — but it is also
the numerical lever, and defaulting it to zero would be a trap.

### 1.2 Up axis: zimr's Y-up wins

MuJoCo and essentially all robotics models are **Z-up** (`gravity "0 0 -9.81"`).
zimrphysics is **Y-up** (`vec(0, -9.81, 0)`), as is everything else in zimr.

**Decision (Simon): robot.zig is Y-up, like the rest of zimr.** Any model imported from the
robotics world gets a documented root rotation. Fighting this would put a coordinate
conversion at every zimrphysics and rendering seam, forever, to spare a future importer
one matrix.

Write it in the file header in capitals. This is exactly the class of thing that produces
a three-turn debugging session eighteen months from now.

### 1.3 Model is a runtime struct; a comptime spec builder produces it

**Decision (Simon): the hybrid.** `Model` is an ordinary runtime struct — built once, then
treated as const — which is exactly MuJoCo's `mjModel`. On top of it sits a *comptime spec
builder* that takes a literal, validates it at compile time, and generates name enums.

```zig
// comptime: validated when it compiles, and it generates Arm.Body / Arm.Joint / Arm.Actuator
const Arm = robot.Spec(.{
    .bodies = .{
        .{ .name = "base",  .parent = null },
        .{ .name = "upper", .parent = "base",  .joint = .{ .hinge = .{ .axis = zm.vec3(0, 0, 1) } } },
        .{ .name = "fore",  .parent = "upper", .joint = .{ .hinge = .{ .axis = zm.vec3(0, 1, 0) } } },
    },
    .actuators = .{
        .{ .name = "shoulder", .on = .{ .joint = "upper" }, .kind = .{ .position = .{ .kp = 40 } } },
    },
});

// runtime: an ordinary allocated struct, like zimrphysics's World
var model: robot.Model = try Arm.build(gpa);
defer model.deinit(gpa);
var data: robot.Data = try robot.Data.init(gpa, &model);
defer data.deinit(gpa);

data.setCtrl(Arm.Actuator.shoulder, 0.4);   // enum, compile-checked
robot.step(&model, &data, dt);              // model is *const: the split is in the type
```

**Why this over the pure-comptime `Model(spec) -> type` I first proposed.** Two reasons,
and the second is a correction of my own argument:

1. **Consistency.** zimrphysics is built at runtime (`createBody`, `shapes.add`, growable
   pools). Two different paradigms for "construct a physics thing" in one library is
   exactly the kind of seam that makes a monolith feel like two libraries.
2. **The GPU argument for comptime was wrong.** I claimed `Data` had to be a comptime
   struct to be a plain value type for batched rollouts. But MJX batches *runtime-built*
   MuJoCo models fine, because `mjData` is a flat buffer — which is at least as
   GPU-friendly as a struct of fixed arrays, arguably more so.

What the comptime layer still buys, and why it is worth keeping:
- name enums (§1.4) — `@backingInt` of the enum IS the index, since the builder assigns
  indices in spec order;
- validation as `@compileError` (missing parent, actuator on a nonexistent joint, a 1-D
  gear on a ball joint) rather than a runtime check;
- a literal spec reads like the rest of zimr's designated-struct-literal API.

What it no longer forecloses: **runtime models**. A URDF/MJCF importer, a procedural
robot, or a robot editor all build a `Model` directly. They lose the enums and fall back
to integer indices or a name lookup (MuJoCo's `mj_name2id` path) — an honest cost, paid
only by the callers who need it.

**The one consequence to stay honest about:** the sparsity tables (`dof_parent`,
`M_rowadr`, chain lengths) are now build-once *runtime* data, not comptime constants. That
is a small price and it removes P3 almost entirely, but it means the CRB inner loop reads
those tables from memory. Exactly what MuJoCo does; no worse.

### 1.5 One file, flat, free functions

`robot.step(&data, dt)` on the namespace, matching `zp.step(&world, dt)`. No methods on a
God object, no builders. Section banners like zimrphysics. Expect 6–10k lines when
complete; that is in line with the house norm and Simon has asked for a single file.

### 1.6 Rot6d — noted, deliberately not yet

`Rot6d` (Zhou et al. 2019) represents a rotation as the first two columns of its matrix,
reconstructed by Gram-Schmidt. Its property is **continuity**: every 3- or 4-parameter
representation of SO(3) has a discontinuity (quaternions have the double cover `q ≡ −q`),
and 6D is the minimal continuous one. That matters enormously when a rotation is being
*regressed or optimized* — learned policies, trajectory optimization, pose estimation —
and not at all when it is merely being composed or applied.

**Is it a peer of `Quat` and `Mat` in zimrmath?** For its job, yes. But its job is
optimization, and nothing in zimr optimizes rotations today. MuJoCo does not use it; it
comes from the robot-learning world that would *consume* robot.zig, not from the simulator.

**Decision: hold, with a written criterion.** Add `Rot6d` to zimrmath when either
(a) phase G lands and a policy/rollout interface needs to emit rotations, or (b) a second
client appears outside robot.zig. Until then it would be a primitive with one hypothetical
user, and zimrmath's whole discipline is that it stays small and shader-safe.

If it does land, note it is shader-safe by construction (two `Vec3`s and a Gram-Schmidt —
no branches), so it fits zimrmath's tier without an exception. That is a point in its
favour whenever the question is reopened.

---

## 2. The seam with zimrmath and zimrphysics

### 2.1 What robot.zig CONSUMES unchanged

| From | What | Notes |
|---|---|---|
| zm | `Quat` ops, `Mat3`, `skew`, `Aabb`, `assertf`, `clamp`, trig | at f32 seams only |
| zimrphysics | `Shape` union (sphere/box/capsule/hull/mesh/heightfield/plane) | robot *geoms* are zimrphysics shapes |
| zimrphysics | `ShapeStore`, GJK/SAT narrow phase, `Manifold` | the contact seam |
| zimrphysics | `BroadPhase` (BVH) | via a World, see §2.3 |
| zimrphysics | `buildConvexHull`, `buildMesh`, `buildHeightField` | asset path, free |
| entities.zig | nothing (robot has no ECS need) | comptime model instead |

### 2.2 What we must ADD to zimrphysics / zimrmath

Small, additive, and each justifiable on its own terms — no robot-specific concepts leak in.

1. **`zp.shapeInertia(shape, density) -> Inertia`** — zimrphysics has `shapeMass`, but it
   returns the **inverse** (`inv_mass`, `inv_inertia_diagonal`) because the solver only
   ever needs the inverse. CRB needs the **forward** mass, the full 3×3 inertia about the
   body COM, and the COM offset. The computation already exists inside `shapeMass`; expose
   the un-inverted intermediate. *Justification to a zimrphysics reader: "the forward mass
   properties, which the inverse ones are derived from" — no mention of robots.*

2. **`pub` on `collideShapes`** — currently private. It is the exact function robot.zig
   needs (shape+pose × shape+pose → manifolds). One keyword.

3. **`zm.Mat3.fromDiagonalRotation(diag, quat)`** and a general symmetric-3×3 helper —
   converting a principal-axis inertia into a full tensor. Trivial, generally useful.

4. **`zm.spatial` — NOT added.** 6D motion/force vectors and the 10-parameter inertia stay
   *inside robot.zig*. zimrmath must remain shader-safe and small, and nothing else in zimr
   wants spatial algebra. This is a deliberate no.

### 2.3 The collision seam, concretely

The impedance mismatch: zimrphysics collides *bodies in a World*; robot.zig has *geoms on
tree links* and no World.

**Decision (phase 7):** the robot **registers its links as kinematic bodies in a
zimrphysics World**. Each step, robot.zig writes link poses into those bodies; the World's
existing broad phase and narrow phase run; robot.zig reads the manifolds back and converts
them to constraint rows.

Why this and not a private broadphase inside robot.zig:
- reuses the BVH, the shape set, and every collision fix zimrphysics ever gets;
- robot-vs-**world** contact (arm touching level geometry) works with zero extra code;
- robot-vs-**dynamic-body** contact becomes possible (see problem P4);
- zimrphysics learns nothing about robots — it just sees kinematic bodies, which it
  already supports.

The cost is one pose write + one manifold read per link per step. Measure it; if it hurts,
the fallback is a robot-private BVH over its own geoms, which is a contained change.

---

## 3. Internal structure of robot.zig

Section order, mirroring the pipeline so the file reads top-to-bottom in execution order:

```
  1. HEADER          //! what this is, Y-up warning, Real=f64 rule, divergence ledger
  2. Real / Vec3r / spatial algebra (Motion, Force, Inertia10, crossMotion, crossForce)
  3. Model spec types (BodySpec, JointSpec, GeomSpec, ActuatorSpec, TendonSpec, SensorSpec)
  4. Model(spec) -> type   [validation, enum generation, index tables, Data generation]
  5. Kinematics            [mj_kinematics, mj_comPos]
  6. Inertia               [mj_crb, mj_factorM, mj_solveM]
  7. Velocity & bias       [mj_comVel, mj_rne]
  8. Jacobians             [mj_jac and friends]
  9. Passive forces        [springs, dampers, fluid]
 10. Actuators             [transmission, activation, gain/bias]
 11. Tendons               [fixed, then spatial]
 12. Constraints           [rows, impedance/aref, the solver]
 13. Contacts              [the zimrphysics seam]
 14. Sensors
 15. Integrators           [euler, rk4, implicitfast]
 16. Inverse dynamics
 17. step / forward / step1 / step2
```

---

## 3b. Adversarial review — what the first draft got wrong

Re-read against MuJoCo's `mjModel`/`mjData` field lists rather than against my own plan.
Seven omissions, three of which would have caused real damage.

### CRITICAL — would have broken the port

**R1 — `qpos0` was missing entirely.** MuJoCo's reference configuration. It is not a
convenience: the `Â` diagonal approximation that scales the constraint regularizer
(§6 of the tutorial — the thing that makes `solref` mean the same on a 1 g finger and a
100 kg torso) is **computed at `qpos0` by the compiler**. Without a reference pose the
entire soft-constraint parameterization has no anchor. It is also what `reset()` restores,
what keyframes are relative to, and what equality constraints measure against.
→ `qpos0` is a phase-0 concept, in the spec and in `Model`. Not a phase-6 afterthought.

**R2 — bodies had no pose relative to their parent.** My own example spec reads
`.{ .name = "upper", .parent = "base", .joint = ... }` with no offset. A kinematic tree
without relative transforms is not a kinematic tree. Every body needs `pos` and `rot`
relative to its parent frame, and every joint needs its own anchor `pos` within the body.
→ Embarrassing, and exactly the kind of thing a prose plan hides. Phase 0.

**R3 — contact order is not deterministic.** MuJoCo *sorts* its contacts, with the comment
that "the broadphase bounding boxes will not be deterministic, which means the order in
which the contacts are received by the collector is not deterministic". We are consuming
zimrphysics's broadphase, so **we inherit exactly that non-determinism**, and a constraint
solver is order-sensitive — same inputs, different answer.
→ Phase 7 must sort manifolds by a stable key (body index, then sub-shape id) before
building constraint rows. Cheap, and invisible until someone tries to reproduce a
trajectory, which is when it is most expensive to discover.

### IMPORTANT — would have caused rework

**R4 — sites were used but never defined.** Sites appear in transmissions (Cartesian
thrust), tendon routing, sensor attachment and Jacobian targets. They are massless,
collisionless frames on a body, and they need to exist in the spec from phase 0 even
though nothing consumes them until phase 5.

**R5 — body inertia from geoms was hand-waved.** "Consume `zp.shapeInertia`" skips the
actual work: sum each geom's inertia about the body frame (parallel-axis to a common
point), producing mass, COM and a full 3×3 tensor — then **diagonalize** it, because
MuJoCo stores `body_inertia` as three principal moments plus `body_iquat`. The
eigen-decomposition of a symmetric 3×3 is a real, testable piece of phase 1.

**R6 — one joint per body is a restriction, not a model.** MuJoCo allows several joints on
one body (`body_jntnum`/`body_jntadr`); three hinges on one body is how you build a ball
joint with per-axis limits, which is common in robot models.
→ The spec takes `.joints` (a list). Supporting it from the start costs little; retrofitting
it means touching every index table.

**R7 — the constraint count is dynamic and nothing sized it.** `nefc` changes every step
with the contact set. zimrphysics learned this painfully (zimr392: the contact pool
overflowed at 2047 and the world silently froze; zimr393/396: the fix was growable pools).
→ Do not repeat it. Size constraint storage generously, `assertf` loudly on overflow with
the count and the cap in the message, and prefer growth over a hard cap. The lesson is
already paid for in this tree; inherit it.

### Smaller, folded into the phases

- **Options** (`gravity`, `timestep`, integrator choice, solver iterations/tolerance) live
  in `Model.opt`, mirroring `mjModel.opt`. Phase 0.
- **`Data` field inventory** — enumerate it explicitly in phase 0 rather than growing it
  ad hoc; it is the thing phase G has to serialize.
- **Degenerate models**: a zero-mass body makes `M` singular. Validate at `build()` and
  return an error naming the body. MuJoCo errors here too.
- **Armature default** needs a *rule*, not "non-zero": default to a small fraction of the
  DOF's own diagonal `M0` (MuJoCo's `dof_M0`), so it scales with the model instead of being
  an absolute number that is wrong at every scale but one.
- **Joint `range`** belongs in the spec from phase 0 even though limits are enforced in
  phase 6 — otherwise every example model gets rewritten at phase 6.
- **`reset()` and state save/restore** — needed by the demo's scene switcher *and* by the
  determinism test. Phase 0, and free once `qpos0` exists (R1).
- **`step1`/`step2` split** so a controller can run between stage 19 and 20. Phase 3, when
  `step` first exists; it is a split of an existing function, not new code.
- **Actuator `ctrlrange`** clamping. Phase 5.
- **Quaternion renormalization** after every integration, and a test that drift stays bounded
  over 10⁵ steps. Phase 3.
- **Profiler zones** (`rbt.kinematics`, `rbt.crb`, `rbt.rne`, `rbt.solve`, …) from phase 1,
  not retrofitted. zimrphysics2d got them late (zimr397) and immediately found that the
  "sleep" zone was 22% of the step — instrumentation that arrives early pays for itself.
- **`nv == 0`** (a model of only welded bodies) must not divide by zero anywhere.

## 4. Phases

**Status: phases 0–5 LANDED; phase 6 LANDED (6a rows, 6b, 6c solver, 6d contacts and the
zimrphysics seam); phases 8, 9 and 10 LANDED.** Every phase in this plan is complete; what remains is §4g's performance work, spatial tendons, and the coupling upgrades in §4h. Performance target and its work
list: **§4g** — parity with MuJoCo or better, measured, by the end. (57 tests, lint 0, all gates green). Each completed phase
carries a `✅ LANDED` block recording what was actually built, what diverged from MuJoCo and
why, and which traps it cost. Cross-cutting findings live in §4f. **Next: phase 6**, planned
in detail in §4e.


Every phase ends green, host-tested, and useful on its own. No phase depends on a device.

### Phase 0 — foundations
Spatial algebra (`Motion`/`Force` as `(rot:lin)` 6-vectors, matching MuJoCo's `cdof`
layout; `Inertia10` as `[Ixx Iyy Izz, Ixy Ixz Iyz, hx hy hz, m]` so composite accumulation
is a 10-element add), the spec structs, `Spec()` (comptime validation + enum generation),
`Model` + `build()` (runtime tables), and `Data`.

The spec must be **complete on day one** — every field below is cheap now and expensive to
retrofit, because adding one touches every index table (§3b):

- body: `name`, `parent`, **`pos` + `rot` relative to parent** (R2), geoms, sites,
  **`joints` as a list** (R6)
- joint: `type`, `axis`, **anchor `pos` within the body**, **`range`** (R-list),
  `armature`, `damping`, `stiffness`, `ref`
- site: `name`, `pos`, `rot` (R4) — massless, collisionless frames
- geom: a zimrphysics `Shape` + local pose + `density`/`mass`
- **`qpos0`** (R1) — the reference configuration; anchors `reset()`, keyframes, equality
  targets and the phase-6 `Â` approximation
- `Model.opt`: `gravity`, `timestep`, `integrator`, solver iterations/tolerance
- also here: `reset()`, `differentiatePos`/`integratePos`/`normalizeQuat` (P9), and the
  explicit `Data` field inventory

**Done when:** a 3-link arm builds with correct `nq`/`nv` and ancestor tables, indexing by
enum works, `reset()` returns to `qpos0`, and each validation rule (missing parent,
unknown joint target, zero-mass body, bad gear arity) has its own `@compileError` **proven
to fire by a negative test** — the "a gate that never fires is not a gate" rule applied to
comptime.

**Also measure here:** `Spec()` comptime cost on a humanoid-sized literal (P3).

**Tests:** comptime asserts on nq/nv/ancestor tables for hand-worked trees; a negative
test per validation rule (this is the "a gate that never fires is not a gate" rule applied
to `@compileError`).

**✅ DONE.** Spatial algebra (`Motion`/`Force` as separate types so adding a velocity to a
force is a compile error; `Inertia` in the 10-parameter packing; `dot6`, `crossMotion`,
`crossForce`), the full spec, `Spec()` with `@Enum` name generation and `@compileError`
validation, `Model`/`buildFromSpec` with the M sparsity tables, `Data` with its whole field
inventory grouped by writing stage, `reset`, and the three qpos↔qvel bridges.

*Found on the way:* an `ArenaAllocator` is **not movable** once an `Allocator` has been
taken from it — storing it by value in `Model` and returning stranded every allocation.
Both `Model` and `Data` hold `*ArenaAllocator`. General rule: **any struct that hands out
pointers to itself cannot be returned by value.**

*Measured (P3):* `@setEvalBranchQuota` is REQUIRED — an 18-body humanoid does not compile
without it. With `quotaFor(spec)` scaling the budget, a 17-body / 31-DOF humanoid
instantiates in **~0.4 s over an empty-file baseline**, which settles P3 and validates the
"comptime shape, runtime loops" split.

> **✅ LANDED.** Spatial algebra (`Motion`/`Force` as separate types, so adding a velocity to
> a force is a compile error; `Inertia` in the 10-parameter packing; `dot6`, `crossMotion`,
> `crossForce`), the full spec, `Spec()` with comptime validation and `@Enum` name
> generation, `Model` + `buildFromSpec` including the M sparsity tables, `Data`, `reset`, and
> the three qpos↔qvel bridges.
>
> **P3 answered by measurement.** An 18-body humanoid did not COMPILE — `evaluation exceeded
> 1000 backwards branches`. Fixed with `@setEvalBranchQuota` scaled by the spec (`quotaFor`)
> rather than a magic number, since name-uniqueness is quadratic. After the fix a 17-body /
> 31-DOF humanoid instantiates in **~0.4 s over an empty-file baseline**, which is what
> validates §1.3's "comptime shape, runtime loops" split.
>
> **Zig trap:** an `ArenaAllocator` is not movable once an `Allocator` has been taken from it
> — the allocator holds the struct's ADDRESS, so returning `Model` by value stranded every
> allocation. Both `Model` and `Data` hold `*ArenaAllocator`. General rule: **any struct that
> hands out pointers to itself cannot be returned by value.**

### Phase 1 — kinematics and body inertia
`kinematics` (parent→child pose composition, quaternion normalization) and `comPos`
(subtree COM frames, `cdof`, `cinert`).

Includes the piece the first draft hand-waved (R5): **aggregate each body's geoms into its
inertia** — sum via parallel-axis to a common point for mass, COM and a full 3×3 tensor,
then **diagonalize** it (symmetric 3×3 eigen-decomposition) into three principal moments
plus a quaternion, matching `body_inertia` + `body_iquat`. Consumes the new
`zp.shapeInertia` (§2.2). Testable in isolation against known solids (a box's principal
moments are analytic) *and* against the oracle's `body_inertia`.

Profiler zones start here (`rbt.kinematics`, `rbt.compos`), not as a retrofit.

**Done when:** a 3-link arm's tip matches a hand-computed transform; a free body's `cdof`
is the identity basis.

**Trap:** `cdof` for a hinge is `(axis, axis × offset)` where `offset = subtree_com −
anchor`. Get the sign wrong and everything downstream is subtly wrong in a way that still
*looks* like a working simulation. Pin it with a test that checks a single hinge's `cdof`
against the analytic value.

**✅ DONE.** `kinematics`, `Pose`, `comPos`, and the R5 geom aggregation.

*Better than planned:* R5's symmetric-3×3 eigendecomposition turned out to be **unnecessary**.
`Inertia` already holds the full symmetric tensor in six floats, so `rotated()` handles a
rotated geom directly. One fewer numerical routine, one float less than MuJoCo, no
degenerate-eigenvalue cases, and `body_iquat` deleted. Aggregation is now three existing
operations: `rotated` → `translate` → `add`.

*Found by the oracle:* `Inertia.rotated` needs the **rows** of R (`I' = R·I·Rᵀ` expands to
`rowᵃ·(I·rowᵇ)`), and `rotate(q, e_k)` gives the **columns**. Using columns computes
`Rᵀ·I·R` — same eigenvalues, same trace, still symmetric and positive definite, wrong
off-diagonals. No invariant distinguishes them.

> **✅ LANDED.** `kinematics`, `Pose`, `normalizeQuat`, `comPos`, `Inertia.rotated`, and the
> R5 geom aggregation. Oracle-verified for body poses, `subtree_com`, `cinert` and `cdof`.
>
> **Divergence, deliberate:** MuJoCo stores body inertia as three principal moments plus a
> quaternion (7 floats), which requires a symmetric-3×3 eigendecomposition. `Inertia` already
> holds the full symmetric tensor in 6, so `rotated()` handles a rotated geom directly and we
> never diagonalize — one fewer numerical routine, one float less, no degenerate-eigenvalue
> edge cases, and `body_iquat` deleted. MuJoCo's form is better *in C*, where a diagonal
> inertia cheapens its inner loops; the six-float form composes better here.
>
> **Two traps, both pinned by tests:** a hinge rotates a body about its ANCHOR, not the body
> origin, so the origin is recomputed as `anchor − R·jnt_pos`; and `I' = R·I·Rᵀ` needs the
> ROWS of R while `rotate(q, e_k)` gives the COLUMNS — an error that preserves symmetry,
> eigenvalues and trace, and shows up only in the off-diagonal terms.

### Phase 2 — mass matrix
`crb`, `factorM` (sparse LᵀDL over the ancestor chains), `solveM`.

**Done when:** `M` matches a dense reference built by finite-differencing momentum; `M` is
symmetric positive definite; `M·(M⁻¹x) == x` to 1e-12 (f64).

**Note:** armature is added to the diagonal here and is *required*, not optional — it is
the cheapest stabilizer we have and the main defence against the conditioning problem
(P1). Default it to a small positive value rather than zero.

**✅ DONE.** `crb`, `factorM`, `solveM`, `massMatrixDense`, `mulM`, `conditionEstimate`.

The LᵀDL has **no fill-in**, structurally: row `k` holds `k`'s ancestor chain, and any `i`
on that chain has a chain that is a PREFIX of `k`'s. So the factor occupies exactly the same
`nM` entries as `M`, shares its index tables, and needs no symbolic analysis and no
elimination-order heuristic — **a kinematic tree IS a perfect elimination ordering.** And
because rows are stored root-first, a prefix in the tree is a prefix in MEMORY, so the
update is a strided add of two contiguous runs.

*P1 answered as far as it can be:* `conditionEstimate` ships free (D was computed anyway)
and is verified to fire — it reads >100× higher on the 1000:1 `mass_ratio` model than on a
balanced arm. **Do not widen `factorM` to f64 until it fires in anger.**

> **✅ LANDED.** `crb`, `factorM`, `solveM`, `mulM`, `massMatrixDense`, `conditionEstimate`.
>
> The LᵀDL has **no fill-in**, structurally: row `k` holds `k`'s ancestor chain, and any `i`
> on that chain has a chain that is a PREFIX of `k`'s. So the factor occupies exactly the
> same `nM` entries as `M`, shares its index tables, and needs no symbolic analysis pass and
> no elimination-order heuristic — **a kinematic tree IS a perfect elimination ordering**.
> And because rows are stored root-first, a prefix in the tree is a prefix in MEMORY, so the
> update is a strided add of two contiguous runs with no index translation.
>
> **P1 answered as far as it can be pre-emptively:** `conditionEstimate` ships free, since
> `D` was computed anyway. Do NOT widen `factorM` to f64 until it fires.

### Phase 3 — bias forces and explicit integrators
`comVel`, `rne`, semi-implicit Euler, RK4.

Also here: the **`step1`/`step2` split** (a controller hook between the state-derived and
force-derived halves — a split of `step`, not new code), and **quaternion renormalization**
after every integration.

**Done when:** a double pendulum swings correctly and conserves energy under RK4 to
< 0.1 % over 10 s; gravity-only free body follows a parabola exactly; and quaternion drift
on a tumbling free body stays bounded over 10⁵ steps.

**SHIPS THE FIRST DEMO** (Simon's pick): `examples/robot_pendulum` — a double pendulum
drawn with existing zimr primitives, no new engine surface. Chaotic motion is a sharp
visual test: it looks wrong immediately if `M` or `c` is wrong.

**✅ DONE.** `comVel`, `rne`/`biasForce`, `inverseDynamics`, `forwardDynamics`, `passive`,
semi-implicit Euler, RK4, `step`, `step1`/`step2`, `energy`.

*The forward/inverse round trip closes to 1e-4*, which is the strongest single piece of
evidence that phases 0–3 are correct.

*Design correction it forced:* armature lives on `M`'s diagonal and **nowhere in the tree**,
so RNE-with-acceleration cannot see it. Inverse dynamics computes `τ = M·a + c` with the
assembled `M` instead (as MuJoCo's `mj_inverse` does), which makes the round trip exact **by
construction** rather than by two recursions agreeing. Prefer that arrangement wherever
there is a choice.

*Two bugs found later, by the audit:* ball and free joints computed `cdof_dot` per-DOF
instead of per-joint (see §4f), and RK4 advanced the activation state four times per step.

> **✅ LANDED.** `comVel`, `rne`/`biasForce`, `inverseDynamics`, `forwardDynamics`,
> semi-implicit Euler, RK4, `step`, `step1`/`step2`, `energy`. **The engine simulates.**
> Device-confirmed: RK4 energy drift −0.005% at t = 8.6 s on a phone.
>
> **Design correction, found by the round-trip test.** It first failed by 1.3%,
> systematically. Armature sits on `M`'s diagonal but lives NOWHERE IN THE TREE — it is
> gearbox rotor inertia, not link inertia — so an RNE recursion given an acceleration cannot
> see it. MuJoCo's `mj_inverse` does not use `mj_rne(...,1,...)` either; it computes
> `τ = M·a + c` with the actual M. Restructured to match, and `rne` lost its acceleration
> parameter entirely. **The round trip is now exact BY CONSTRUCTION**, because both
> directions use the same M rather than requiring two recursions to agree.
>
> **Bug found later, by the audit:** `comVel` was wrong for ball and free joints — see §4f.

### Phase 4 — Jacobians
Body/site/joint Jacobians via ancestor-chain walk.

**Done when:** every Jacobian agrees with a central finite difference of the forward
kinematics to 1e-6.

**This is the highest-value test in the project.** It is cheap, it is brutal, and it
independently validates phases 1 and 2's frame conventions. Write it early; it will catch
the `cdof` sign trap if phase 1's test somehow didn't.

> **Milestone:** phases 0–4 are the irreducible core. At this point zimr can do forward
> and inverse dynamics on an articulated tree and compute task Jacobians — enough for a
> torque-controlled arm demo with no constraint solver at all.

**✅ DONE.** `jacPoint`, `jacBodyCom`, `jacSite`, `applyForceAtPoint`.

*Layout divergence, deliberate:* one `Vec` **per DOF** rather than MuJoCo's 3×nv row-major.
Column `i` reads as "the velocity this point gains per unit of DOF i", which is what every
consumer wants. The conventional layout wins when handing a matrix to a BLAS; this one wins
when reading it.

Tested four ways, of which the most valuable is a case checkable **by hand**: push a
straight-down arm's tip with 1 N and the shoulder reads 0.9 N·m, the elbow 0.4 N·m. Every
other test compares against something computed; that one compares against something
understood.

> **✅ LANDED.** `jacPoint`, `jacBodyCom`, `jacSite`, `applyForceAtPoint`.
>
> **Layout divergence, deliberate:** a Jacobian is conventionally 3×nv row-major floats; ours
> is one `Vec` PER DOF, so column `i` reads as "the velocity this point gains per unit of DOF
> i" and the arithmetic stays in zm's vocabulary. The conventional layout wins when handing a
> matrix to a BLAS; this one wins when reading it.
>
> Only DOFs that move the body get a column, found by walking the ancestor chain — the same
> traversal `crb` and `factorM` use. Three algorithms, one chain walk, all off phase 0's
> `dof_parent`.
>
> **Best test in the project:** push a straight-down arm's tip with 1 N and the shoulder must
> read 0.9 N·m, the elbow 0.4 N·m. Every other test compares against something COMPUTED; this
> one against something UNDERSTOOD. **Trap:** the finite-difference probe must track a
> MATERIAL point on the body, not a fixed world point.

### Phase 5 — actuators and passive forces
Transmission (`joint`, then `tendon`, then `site`), affine gain/bias, activation dynamics
(`none`, `integrator`, `filter`, `filterexact`). Joint springs and dampers.

**Done when:** a position servo holds a load against gravity with the analytically
predicted steady-state error; a `filterexact` actuator is stable at `tau < dt` where
`filter` diverges (this difference is the reason both exist).

**✅ DONE.** `transmission`, `actuation`, `setCtrl`, `passive`, and the joint transmission.

**One affine law**, with the shortcuts as different coefficients rather than different
mechanisms: `position` is `gain = kp, bias = (0, −kp, −kv)`, which expands to exactly
`kp(u−l) − kv·l̇`. A servo IS a motor whose bias terms subtract the current state. Kept
affine deliberately, so it can be inverted.

`filter_exact` is not an optimisation — an Euler-integrated filter **diverges** once τ < dt,
and a fast actuator in a slow simulation is ordinary. Verified: at τ = dt/4 the exact form
converges to 1.0 and the Euler form exceeds 10.

*Zig note:* a multi-prong `switch` capture (`.filter, .filter_exact => |f|`) needs a SHARED
named payload type. Two anonymous structs with identical fields are still different types.

**Demos shipped:** `examples/robot_pendulum` (phase 3 first light, energy-drift HUD,
device-confirmed at −0.005% over 8.6 s under RK4) and `examples/robot_demo` (8 scenes,
3 categories, `scenes.zig` + host in the shape of `zimrphysics2d_demo`).

*Demo bug worth remembering:* all arm scenes first shared ONE model carrying position
servos, whose `ctrl` defaults to zero — so the servos silently overruled gravity
compensation and the reach controller alike. **An arm with motors is a different machine
from an arm without.** Split into `Arm.Free` and `Arm.Servo`.

> **✅ LANDED.** `transmission`, `actuation`, `passive`, `setCtrl`, the `ActuatorSpec`
> shortcuts, and `examples/robot_demo`.
>
> MuJoCo's model implemented as **one affine law**, with the shortcuts as different
> coefficients rather than different mechanisms: `position` is `gain = kp, bias = (0, −kp,
> −kv)`, which expands to exactly `kp(u−l) − kv·l̇`. A servo IS a motor whose bias terms
> subtract the current state. Kept affine deliberately — an affine law can be inverted, which
> is what lets inverse dynamics recover the control.
>
> `filter_exact` is not an optimisation: an Euler-integrated filter DIVERGES once its time
> constant is shorter than the timestep. At τ = dt/4 the exact form converges to 1.0 and the
> Euler form exceeds 10.
>
> **Zig note:** `.filter, .filter_exact => |f|` needs a SHARED named payload type — two
> anonymous structs with identical fields are still different types.
>
> **Bugs found later, by the audit:** joint damping and stiffness were stored and never
> applied (`passive` added), and `actuation` advanced `act` itself so RK4 integrated the
> activation four times per step (split into `act_dot` plus one integration). See §4f.

### Phase 6 — soft constraints
Constraint row assembly (equality → friction loss → limit → contact, in that fixed order),
the impedance model (`R = (1−d)/d · Â`, `aref = −b(Jv) − k·r`), and **one** solver:
projected Gauss-Seidel over a pyramidal cone.

**Done when:** a joint stops at its limit with the softness the model asked for, and the
achieved penetration under a constant load is independent of link mass (that invariance is
the whole point of the `Â` scaling — test it explicitly with a 100:1 mass ratio).

**This is the risk phase.** See P7.

> **✅ 6a LANDED** — the rows, with no solver. `Softness`, `Impedance`, `ConstraintKind`,
> `makeConstraints`, `projectConstraints`. Every row matches MuJoCo: Jacobian, residual,
> exact `Â`, `R` and `aref`, across three limit models × three states.
>
> **Ordering paid off exactly as §4e predicted.** `aref` came out wrong by a constant
> factor of `1/d_max` while `J`, `pos`, `Â` and `R` were all correct — an error that, with a
> solver in the loop, presents as "the limit feels mistuned" rather than as a bug. The cause:
> **impedance scales the STIFFNESS term and not the damping one.** MuJoCo's
> `mj_referenceConstraint` is explicit — `aref = −B·vel − K·I·(pos−margin)` — and both
> plausible alternatives (impedance on the whole reference, or on neither term) give a
> reference wrong by a constant. Recorded in the code, since the reading is not obvious:
> `d` gates how hard the spring pulls toward satisfaction, while damping opposes
> constraint-space motion regardless, because a half-engaged constraint still resists
> velocity.
>
> **Exact `Â`, per §4e.** `Â_ii = (J M⁻¹ Jᵀ)_ii` via one back-substitution per row through
> the factorization `factorM` already produced. Fixtures are generated with MuJoCo's
> `DIAGEXACT` flag so the comparison is like-for-like. The cheap approximation is not
> implemented and will not be until profiling asks.
>
> **Spec surface:** `Softness { time_const_s, damp_ratio }` and
> `Impedance { min, max, width, midpoint, power }` as named options, where MuJoCo has
> `solref[2]` and `solimp[5]`. Same math, and the units are legible at the call site.
>
> **Storage:** `nc_max` sized at build (one row per limited joint is exact, since a joint can
> only violate one end at a time), arrays never reallocated, overflow is a loud assert
> naming both counts — the zimr392 lesson applied before it could bite.
>
> **Test note:** `checkConstraintRows` asserts it saw BOTH an active and an inactive state.
> A suite that only ever sees active constraints cannot catch a broken activation test, and
> the `rest` fixtures exist to provide the other branch.
>
> **✅ 6b LANDED** — nothing separate to build. The exact diagonal shipped in 6a, so
> MuJoCo's cheap approximation is simply never implemented. It can be added if profiling
> ever asks; nothing depends on it.
>
> **✅ 6c LANDED** — `SolverOptions`, `solveConstraints` (projected Gauss-Seidel, unilateral
> rows), `constraintResidual`, `constraintScale`, `constraintConverged`, and the joint-space
> report `Jᵀf`. **A joint now stops at its limit with the softness the model asked for**,
> which was this phase's stated goal.
>
> The derivation is written into the file rather than assumed, because everything after
> refers back to it: `M a = τ + Jᵀf` ⟹ `J a = a_free + A f` with `A = J M⁻¹ Jᵀ`; the soft
> condition `J a = aref − R f` ⟹ **`(A + R) f = aref − a_free`**, subject to `f ∈ K`. The
> per-row update collapses to `Δ = (aref_i − J_i·a − R_i f_i) / (Â_i + R_i)` once you notice
> that `(A f)_i + a_free,i` IS the constraint-space acceleration currently being
> experienced — so no matrix `A` is ever formed and the coupling between rows travels
> through the shared acceleration vector.
>
> **Why R is not a hack, recorded:** `A` is positive SEMI-definite and genuinely singular
> whenever constraints are redundant (a box on four points). `R > 0` makes `(A+R)` strictly
> positive definite, so the problem has exactly one solution — the softness the modeller
> asked for is the same quantity that makes the mathematics well posed.
>
> **§4d's constraint discharged.** `constraintResidual` is the natural complementarity
> function `‖min(f_i, s_i)‖` with `s_i = J_i·a + R_i f_i − aref_i`, which is zero exactly
> when the KKT conditions hold. It earns its place immediately as an honest convergence
> check — a solver that STOPPED is not a solver that CONVERGED — and it is precisely the
> expression implicit differentiation needs later, so the gradient path is an addition
> rather than a rewrite.
>
> **A real design bug of mine, found by a test:** the convergence tolerance was ABSOLUTE.
> Reference accelerations for a stiff limit run to several hundred, and f32 carries about
> seven digits, so the smallest representable residual near 500 is ~5e-5 — an absolute
> tolerance of 1e-7 is unreachable and the solver span to `max_iterations` on a problem it
> had solved exactly. Now relative to the problem's own scale, with the reasoning in the
> code. **`constraintConverged()` exists so the rule lives in one place**; two copies of a
> convergence criterion is one copy too many.
>
> **Three test PREMISES were also wrong**, all the same mistake: a pendulum at `q = 0` hangs
> at its equilibrium, so gravity exerts no torque and a limit straddling that point is never
> engaged. Limits must be placed where gravity actually presses into them. Worth recording —
> it is an easy way to write a constraint test that passes without testing anything.
>
> **Proven to fire:** removing the `@max(0, ...)` projection turns the KKT test red.
>
> **ADVERSARIAL REVIEW against the MuJoCo source, after 6c.** Read
> `mj_instantiateLimit`, `mj_makeImpedance`, `mj_referenceConstraint`, `solPGS` and
> `mj_fwdConstraint` line by line against ours.
>
> **✅ The solver formulation is provably equivalent.** MuJoCo forms `efc_AR` explicitly and
> computes `res = efc_b + (AR·f)_i` with `efc_b = J·qacc_smooth − aref`. Substituting
> `A f = J(a − a_free)` turns that into `J_i·a + R_i f_i − aref_i` — exactly our residual.
> Ours avoids ever forming `A`, letting the coupling travel through the shared acceleration
> vector instead, which is cheaper for small row counts and identical in exact arithmetic.
>
> **★ ONE REAL BUG FOUND: limits are TWO-SIDED.** MuJoCo loops `for side = −1, +1` and emits
> a row per end within margin; ours took `min(q − lo, hi − q)` and emitted at most one. It
> looks impossible for both to be active — a joint cannot be past both stops — but `margin`
> makes it reachable: when the range is narrower than `2·margin`, the joint is within margin
> of both ends everywhere in its travel. Verified against a new `limit_both_sides` fixture,
> where MuJoCo emits two rows with `J = +1, −1`. **`constraint_capacity` was also sized at
> one row per limited joint, so the fix without the resize would have been an overflow.**
> Now two per joint. Proven load-bearing: restoring the one-row shortcut turns the suite red.
>
> **Three silent-acceptance gaps closed in `Spec()`**, each of which previously produced
> wrong-or-ignored behaviour with no diagnostic: a `range` on a ball or free joint (MuJoCo
> supports it via quaternion→axis-angle; we do not, and silently ignoring a limit the model
> asked for is worse than refusing it); a non-positive time constant or damping ratio
> (MuJoCo overloads the SIGN of `solref` to mean "these are K and B directly" — `Softness`
> names its fields, so a negative value is simply nonsense); and an impedance ramp that is
> not a valid sigmoid.
>
> **Verified matching:** the `+1`/`−1` Jacobian sign per end; `dist = side·(range − value)`;
> activation at `dist < margin`; `pos − margin` used in both the impedance sigmoid and
> `aref`; the row denominator `A_ii + R_i`; `Jᵀf` reported in joint coordinates.
>
> **Divergences accepted and recorded**, all performance rather than correctness: MuJoCo
> shuffles constraint visitation order each sweep with a fixed-seed PCG32, applies Nesterov
> momentum, and warm-starts from the previous step's forces. We do none of the three. Ours
> is deterministic without needing a seeded shuffle; the other two are worth revisiting when
> contacts make the row count large enough to matter.
>
> **✅ 6d-i LANDED — contact ROWS, with collision detection still out of the picture.**
> `Contact`, `addContact`, per-row softness/impedance, `Options.max_contacts`. Rows match
> MuJoCo exactly on a sphere-on-plane fixture across three states.
>
> **The pyramid trick, and why friction needed no solver changes.** Coulomb friction is
> physically a second-order cone: `‖f_t‖ ≤ μ·f_n`. Approximating the cone by a PYRAMID
> whose edges are `n ± μ_k·t_k`, each with its own non-negative force, makes the total force
> a non-negative combination of edge directions — so it is inside the pyramid automatically,
> the normal components sum to `f_n`, and the tangential imbalance is bounded by `μ·f_n`,
> which IS the friction law. **Every edge row is just `f ≥ 0`, exactly like a joint limit, so
> the 6c solver handles friction without a single line of change.** The cost is the standard
> one: friction is stronger along the pyramid's edges than its faces (up to √2 for two
> tangents). All four rows of a contact share the penetration as their residual, so a
> friction row engages exactly when its contact does.
>
> `addContact` takes a plain `Contact` value with no reference to the shapes that produced
> it — the row builder needs the geometry of the touching, not the identity of the touchers.
> That is what will let zimrphysics be the collision source in 6d-ii without robot.zig
> knowing anything about it. Contact against static geometry needs no special case: a static
> body's Jacobian is identically zero, so `J_b − J_a` handles world contact and body-body
> contact with the same expression.
>
> **★ THE ORACLE WAS WRONG, AND THE FIX GENERALIZES.** MuJoCo 3.11's `efc_diagA` under
> `mjENBL_DIAGEXACT` returns **1.86e-14 for every row of a contact** whose true
> `diag(J M⁻¹ Jᵀ)` is 0.6255 — while working correctly for limit rows, which is why 6a never
> noticed. Computing the diagonal directly from MuJoCo's own `efc_J` and mass matrix in
> NumPy gives 0.6255, matching ours exactly.
>
> The fixture now emits that computed ground truth instead of reading the derived field, and
> `R` is compared as the RATIO `R/Â` — which is `(1−d)/d`, the impedance sigmoid's output,
> and so is independent of whichever diagonal was used. **Standing lesson: when an oracle
> exposes both primitives and derived quantities, derive the ground truth yourself.** A
> derived field can be wrong, flag-dependent, or mean something subtly different; the
> primitives cannot.
>
> **A process failure of my own worth recording:** a `str.replace` in the generator silently
> did not match (an earlier `sed` had changed the target text) and I had not asserted on it,
> so the fixture emitted a field the struct did not declare. **Assert on every replace.** The
> rule already existed for the memory tools; it applies to every scripted edit.
>
> **ADVERSARIAL REVIEW of 6d-i. Two design flaws and one solver bug.**
>
> **★ DESIGN FLAW: `forward()` silently ignored contacts.** It runs `makeConstraints` and
> `projectConstraints` back to back, so an `addContact` that built rows directly had NO
> moment at which a caller could invoke it. Every contact user would have had to hand-run
> the pipeline — which is exactly what the test did, and why the hole was invisible.
> **Contacts are now an INPUT buffer in `Data`, like `ctrl`**: `clearContacts`,
> `pushContact`, `setContacts`, consumed by `makeConstraints`. There is no ordering left to
> get wrong. This also suits phase G, since everything a step needs now lives in `Data`.
>
> **★ DESIGN FLAW: determinism was the caller's problem.** R3/P12 says contact order must be
> stable because Gauss-Seidel is order-sensitive, and the plan had the caller sorting.
> Wrong place: a caller can forget. `makeConstraints` now sorts by `(body_a, body_b, id)`
> itself, and `Contact.id` was added so a detector can supply a stable per-point identity —
> which is also what a future warm start needs to match a row to last step's force.
>
> **★ SOLVER BUG: a row the mechanism cannot move along got a force of ~1e11.** When
> `Â = J M⁻¹ Jᵀ` is zero, the row's denominator was a clamped 1e-10. Invisible in the
> acceleration (its `M⁻¹Jᵀ` is zero too) but it poisons the reported forces and the
> convergence residual. Not exotic either — a planar mechanism has no motion along the
> out-of-plane tangent, so both of that tangent's pyramid edges are degenerate, and the
> very first contact fixture exercises it. Such a row is satisfied by definition; the solver
> and the residual now skip it. **`Â`, `R` and `aref` are still recorded as computed**,
> because MuJoCo reports them too and zeroing them would disagree with the reference for no
> gain.
>
> **A gap in the tests, found by the negative test rather than by reading:** the first
> version of that fix passed with the bug re-planted, i.e. nothing verified it. Added a test
> that asserts degenerate rows carry zero force and that all forces stay finite — and it
> also asserts the configuration **does not converge**, correctly: a 1-DOF pendulum cannot
> move along a floor normal at all, so a 35 mm penetration is not something any force can
> undo. A solver that merely STOPPED would look identical from outside; `solver_iterations`
> and `constraintResidual` are what distinguish "solved" from "gave up", and a model asking
> for the impossible should be visibly unsolved rather than quietly approximated.
>
> **DESIGN DECISION for 6d-ii, settled with evidence rather than by assumption.**
>
> Two candidates. **(A) Register robot links as kinematic bodies in a zimrphysics World**, as
> §2.3 originally proposed. **(B) Read-only**: robot.zig computes its geom AABBs, queries the
> broad phase for candidates, and calls narrow phase itself — duplicating no state and
> needing no body handles.
>
> **(B) is disqualified by one consequence.** If the robot's links are not in the world's
> broad phase, zimrphysics's own step never sees them, so a dynamic box cannot collide
> against the arm at all — and "the arm sweeps a box off a table" is the phase-7 demo. The
> state-duplication cost of (A) is real but it buys the thing the demo is for.
>
> **★ AND (A) NEEDS NO CHANGES TO ZIMRPHYSICS.** Surveying it before writing anything, every
> piece already exists:
>   * `MotionType.kinematic` — links are driven, not simulated.
>   * `World.contact_listener` — an extension point built for exactly this, whose docs
>     already say callbacks should RECORD events to act on after `step` returns. No
>     manifold-retention API to add.
>   * `Manifold.normal` (world, A→B) and `ManifoldPoint.point_on_a` / `point_on_b`, so
>     penetration is `dot(normal, point_on_b − point_on_a)` (negative when overlapping,
>     matching `Contact.distance`) and the contact position is their midpoint — the same
>     convention MuJoCo uses.
>   * **`ManifoldPoint.feature_id`, documented as "stable id for warm-start matching across
>     frames"** — precisely what `Contact.id` needs for the determinism sort and for future
>     warm starting. zimrphysics had already solved the contact-identity problem.
>
> **★ ONE ZIMRPHYSICS CHANGE WAS REQUIRED AFTER ALL, and finding it was the point of
> building the thing.** The narrow phase drops any pair where neither body has finite mass —
> static/static, static/kinematic, kinematic/kinematic — because its own solver could carry
> no impulse across it. Entirely sound reasoning *for zimrphysics*. It is wrong for us:
> **a robot proxy is kinematic, so it could not touch STATIC LEVEL GEOMETRY at all.** No
> floor, no table, no wall. The symptom was a bridge test that had been written with a
> DYNAMIC floor as a workaround — and a dynamic floor falls, so it had left the scene before
> the pendulum swung down to where it used to be.
>
> Added `Body.report_immovable_contacts` (default off): report this body's contacts even
> when neither side can respond, because its motion is owned by something outside this
> engine and only that owner can decide what the impulse means. Deliberately distinct from
> `is_sensor`, which bypasses the same gate but *also* suppresses the response against
> dynamic bodies — a robot proxy must keep pushing crates. The flag's doc comment mentions
> no robots: "a body whose motion is decided elsewhere — an external integrator, an
> animation, another simulation". Proven load-bearing: removing the opt-in turns the bridge
> test red.
>
> That is the shape §2.2 predicted — small, additive, justifiable to a zimrphysics reader
> without reference to robots — and it is the only one the seam needed.
>
> **The shape of the seam:** register each link with geoms as a kinematic body; write link
> poses into those bodies each step; `zp.step` runs and a listener records every manifold
> touching a robot body; robot.zig converts them to `Contact` values and calls
> `setContacts`. The world's solver pushes the box treating the arm as immovable, and
> robot.zig pushes the arm treating the box as immovable — the one-way coupling of §5/P4,
> now stated as what each side believes rather than as a limitation.

### Phase 7 — contacts via zimrphysics
Register links as kinematic bodies; per step write poses, read manifolds, **sort them by
`(body, sub)`** (R3/P12 — zimrphysics's broadphase order is not deterministic and the
solver is order-sensitive), convert to constraint rows.

**Done when:** the arm sweeps a zimrphysics box off a table.

**Explicit approximation (Simon):** the robot is one-way coupled — infinitely massive from
the world's point of view. The box gets pushed correctly; the robot feels no load. Right
for a heavy arm and light objects, wrong when the robot lifts something heavy.

Documented as a divergence in the file header. The upgrade, when a demo needs it, is P4(a):
read last step's contact impulses back as an external force on the robot. One step of lag,
a few lines. Do not pre-build it.

### Phase 8 — tendons
Fixed tendons (linear combinations of joint coordinates) first; spatial tendons (site
paths with sphere/cylinder wrapping) after.

**Done when:** a differential drive works from two joints and two tendon actuators — the
`model/car` example, ported.

> **✅ FIXED TENDONS LANDED.** `TendonSpec`, `TendonJoint`, `tendonLengths`, tendon springs
> and dampers in `passive`, and a `.tendon` transmission for actuators. 80 tests.
>
> **Followed MuJoCo's `mj_tendon` closely**, including the structural choice that matters: a
> fixed tendon's Jacobian is the coefficient vector and is CONSTANT, so it lives in `Model`
> rather than being recomputed per step. MuJoCo keeps `ten_J` in `mjData` because a spatial
> tendon's is configuration-dependent and both kinds share the array; ours is in the model
> until spatial tendons need to move it, and the row layout is chosen so that move is local.
>
> **The idea, recorded because it is the reason tendons exist:** a tendon couples joints
> WITHOUT a closed kinematic loop. The alternative — an equality constraint between the same
> joints — costs a solver row and holds only approximately. A tendon holds EXACTLY and costs
> a dot product, because it is a definition that gets evaluated rather than a constraint that
> has to be enforced.
>
> The force path is `Jᵀf` again in miniature: one scalar actuator force spreads across every
> DOF the tendon touches, in proportion to that joint's coefficient — which is how a real
> tendon distributes tension along its path. Same for a tendon spring, which acts on the
> tendon's LENGTH rather than on any single joint, so a coupled finger springs back to a
> pose rather than each knuckle springing back independently.
>
> **Tests:** the definition (length and velocity ARE the linear combination); the phase's
> stated goal, a differential drive where two controls become "forward" and "turn" and
> neither one is a wheel, with a pure turn leaving the forward coordinate untouched; the
> transpose spreading; and a tendon spring pulling its length — not its joints — to rest.
> Proven to fire: dropping the coefficient's sign turns them red.
>
> **Index-space trap worth noting:** a tendon's coefficients index DOFs but its length reads
> POSITION coordinates, and those are different spaces in general (`nq ≠ nv`). The hop
> through the owning joint translates between them, and it is exact only because `Spec()`
> restricts a tendon to scalar joints.
>
> **Deferred:** spatial tendons (a path through sites, wrapping around spheres and
> cylinders). Everything downstream is already written against a scalar length and a
> Jacobian row, so they slot in at `tendonLengths` alone.
### Phase 9 — sensors and inverse dynamics
Sensors at the three pipeline stages; `inverse`; and the **forward-then-inverse round
trip** as a permanent test.

**Done when:** `inverse(forward(τ)) == τ` to 1e-9 on every example model. This single
check validates `M`, `c` and `J` simultaneously; MuJoCo ships it as pipeline stage 25 for
exactly that reason.

> **✅ LANDED.** `SensorKind`, `SensorSpec`, staged `sensors()`, `bodyAccelerations`,
> `siteVelocity`, `siteProperAcceleration`. Twelve sensor kinds across the three stages.
> 85 tests. (Inverse dynamics and the forward/inverse round trip landed back in phase 3.)
>
> **Why sensors belong in the engine, recorded because it is not obvious:** everything a
> sensor reports is derivable from `Data`, so leaving them to the caller looks reasonable.
> It is not — the derivation is only available AT THE RIGHT MOMENT. An accelerometer
> measures proper acceleration, which exists only after constraint forces are known; a gyro
> needs velocities but must not see forces. Reconstructing either from outside the step
> means finite-differencing, which is both wrong and noisy. Hence three evaluation points,
> as MuJoCo does, with `SensorKind.stage` recording which.
>
> **They are also the observation half of §4d's loop.** A learned policy reads sensors and
> writes controls, so `sensor_data` is one flat array by design — it is the vector a policy
> consumes, and it maps onto a tensor without restructuring.
>
> **★ The accelerometer is the one worth getting right, and it has two traps.**
>
> 1. **PROPER acceleration, not coordinate acceleration.** A real instrument at rest on a
>    table reads `g` upward; one in free fall reads zero. That falls out for free from the
>    `−gravity` world seed already used by `rne` — the same trick, reused — and would be
>    near-impossible to bolt on afterwards. Tested both ways.
> 2. **The Coriolis correction.** Carrying a spatial ACCELERATION out to a point is not the
>    same operation as carrying a velocity out: a point on a rotating body accelerates even
>    at constant spatial acceleration, and the correction is `ω × v_point`. MuJoCo's
>    `mj_objectAcceleration` adds it explicitly. **The error is exactly zero whenever the
>    body is not rotating — which is every simple test one would think to write.** So the
>    test spins the arm at a constant rate with gravity off and demands `ω²r`; neutralising
>    the term reads 0 against an expected 4.5.
>
> **Deferred, and named:** touch, rangefinder, magnetometer, camera projection, force/torque
> at a site (needs `rnePostConstraint`), ball-joint quaternion sensors, and the limit
> sensors. All are additive — a new `SensorKind` arm plus a case — because the staging and
> the packed layout are already in place.
### Phase 10 — implicit-in-velocity integrator
`(M − hD)v_new = ...` with `D = ∂(forces)/∂v`, Cholesky (implicitfast).

**Done when:** a heavily damped model is stable at a timestep where semi-implicit Euler
explodes.

> **✅ LANDED — and with it, every phase in this plan.** `smoothVelDerivative`, `luFactor`,
> `luSolve`, `advanceImplicitFast`. 89 tests.
>
> **The derivation, in the file:** explicit Euler evaluates the acceleration at the CURRENT
> velocity, which is why a strong damper destabilises it — an overshoot produces a larger
> restoring force, which produces a larger overshoot. Evaluating at the NEW velocity is
> stable for any damping, and one Newton step resolves the circularity:
> **`(M − h·D)·Δv = h·M·a`**, where the right-hand side is `h·M·a` because `a` is exactly
> `M⁻¹F`, already computed. With `D = 0` it collapses to `Δv = h·a` — explicit Euler — and
> that identity is the first test rather than an assumed property.
>
> **What "fast" means, confirmed against the source.** `mjd_smooth_vel(m, d, flg_bias)`:
> MuJoCo's `implicit` passes 1 and includes `mjd_rne_vel`, the Coriolis derivative;
> `implicitfast` passes 0 and skips it. **That single omission IS the speed difference.**
> What it costs is accuracy for a fast-TUMBLING free body; for a damped, actuated mechanism
> the actuator and passive terms carry the stability, which is the trade a robot wants.
>
> **The term most likely to be got wrong, and it is not diagonal.** Joint damping is
> diagonal. Tendon damping is NOT: the force `−b·(c·v)` reaches DOF `j` scaled by `c_j`, so
> the contribution is `−b·cⱼcₖ` — an outer product coupling every DOF the tendon touches to
> every other. Same shape for a tendon actuator's `bias[2]`. **This is why `M − h·D` loses
> the tree sparsity and needs a dense LU rather than `factorM`**, and why a diagonal
> approximation would look right and silently drop the coupling. The finite-difference test
> catches exactly that: replacing the outer product with its diagonal reads 0 against an
> expected 0.9.
>
> A dense LU with partial pivoting rather than a Cholesky, even though `D` happens to be
> symmetric for today's force set — a future velocity-dependent force need not be, and a
> Cholesky would fail silently on the day one arrives. MuJoCo uses `qLU` for the same reason.
>
> **Tests:** the `D = 0` collapse to Euler (exact, and the widest net for sign and transpose
> errors); the derivative against a central finite difference of the force, on a model
> carrying all three sources; stability where Euler diverges — **in two steps**; and
> monotonic energy loss, since a damper can only remove energy.
>
> **Two test premises I had to correct**, both mine: "stable" means BOUNDED, not settled — a
> big joint damper still leaves a pendulum ringing down slowly, so demanding a near-zero
> velocity would test the model's damping ratio rather than the integrator. And a
> monotonicity test passes trivially for a system that never moves, so it also has to assert
> that a real fraction of the starting energy is gone.
>
> **Recorded for §4g:** `smoothVelDerivative` takes no `Data` — for this force set every
> term is a model constant, so the matrix could be built once per model rather than per step.
> The dense `nv × nv` LU is O(nv³) per step and joins S1 on the optimisation list.
### Phase G — GPU batched rollouts (opportunistic, after phase 5)
See §6.

---

## 4b. The examples — planned up front, not accreted

zimr's physics demos set the shape: `zimrphysics2d_demo` is `scenes.zig` + `render.zig` +
a host, with a `Scene { category, name, build, update, control, cam }` table, a
category/name switcher, and a perf HUD. 137 scenes, one table. robot.zig gets the same
structure from the first demo, so scenes accrete into a planned table rather than a pile
of one-off examples.

**Three deliverables, not one.**

### A. `examples/robot_pendulum` — the phase-3 first light
Deliberately minimal and separate from the demo: one file, a double pendulum, no UI beyond
a reset. It exists to be the *earliest possible* visual and to stay diffable when something
breaks later. Do not grow it; new scenes go in the demo.

### B. `examples/robot_demo` — the scene table
`scenes.zig` + `render.zig` + host, mirroring the 2D demo. Scenes are listed here **with
the phase that unlocks them**, so the table is a roadmap and never blocks on unbuilt
capability.

**Eleven scenes plus three standalone examples exist today** — `robot_demo` (Basics ×3,
Kinematics ×2, Actuators ×3, Limits ×2, Sensors ×1), `robot_pendulum`,
**`robot_sidebyside`** (#1 on this list) and **`robot_contact`** (#2) — both now built.

> **`robot_contact` notes.** An actuated arm sweeping a crate off a static table, the whole
> zimrphysics seam end to end: steer the proxies, step the world, harvest the contacts its
> listener recorded, step the arm. Everything locked to the XY plane via
> `AllowedDofs.plane_2d`, so a 2D drawing is honest rather than a projection.
>
> Two things it demonstrates that nothing else does. **The static table only works because
> the proxies set `report_immovable_contacts`** — without that flag zimrphysics drops any
> pair where neither body can respond, and the arm passes through the table. And the arm is
> driven by position SERVOS rather than by scripted torques, so what you watch is the
> controller deciding what to do about an obstacle, not an animation.
>
> The readout shows contacts, rows (four per contact — a pyramid), solver iterations and the
> summed constraint force, with a peak so a brief tap leaves a trace.
>
> **★ THE FIRST VERSION DID NOT WORK, and the reason generalises.** A device screenshot
> showed the arm straightening out, shaking, and never reaching the crate. The cause: I had
> authored the sweep by GUESSING JOINT ANGLES — interpolate the shoulder from 1.9 to 0.4,
> the elbow from −1.2 to −0.7, and hope the hand went somewhere useful. It did not. The arm
> drove its own tip into the table and spent the sweep fighting a contact it should never
> have made.
>
> **Joint angles are the wrong space to author a motion in.** The task is about where the
> HAND goes; the angles are whatever achieves that, and a human cannot reliably guess them
> for even two links. The sweep is now specified in Cartesian coordinates — a horizontal
> line at crate height, clear of the table — and closed-form two-link IK solves for the
> angles, verified to round-trip through forward kinematics to 1e-7 at every waypoint before
> the scene was rebuilt.
>
> That is also what a real robot does: a planner works in task space, IK turns the path into
> joint targets, and the servos chase those. Keeping that structure means the scene stays a
> demonstration of position servos rather than becoming an animation — and the commanded
> tip is now drawn, so the gap between it and the actual tip IS the servo's tracking error,
> visibly growing when the arm meets the crate.
>
> **A real engine bug fell out of the same screenshot:** the readout said `solver 60 it` even
> with `rows 0`. `solveConstraints` returns early when there are no constraints and never
> reset `solver_iterations`, so a step that did no work reported the last constrained step's
> count — reading as a solver in trouble. Fixed, and the no-constraint test now asserts the
> diagnostic is honest about not having run.
>
> **Also surfaced: `robot_physics` was not exported from `zimr.zig`.** The bridge existed,
> was tested, and was unreachable from any example. Now exported, with the reason it is a
> separate module in the doc comment — robot.zig depends only on zimrmath, so a headless
> rollout does not drag a collision engine along. Scenes gained an optional `readout` hook so one can surface the numbers it is
actually about — the IMU scene uses it, and the integrator and inverse-dynamics scenes will. Everything
below the line is built; everything above it is capability the engine HAS and does not yet
show. A capability with no demo is one nobody will discover, and — going by the servo bug a
device screenshot caught — one whose failures nobody will see either.

### Built

| Category | Scene | Shows |
|---|---|---|
| Basics | single / double / triple pendulum | chaos, and deeper chains exercising the sparsity |
| Kinematics | weightless arm | gravity compensation; drag to bat it around |
| Kinematics | reach to target | Jacobian-transpose IK, interactive |
| Actuators | position servos, swept | PD servos tracking a moving command |
| Actuators | servo droop | steady-state error, deliberately uncompensated |
| Actuators | free fall | the same arm with no motors |
| Limits | joint limits / soft limits | soft constraints as stops; the impedance ramp |

> **`robot_sidebyside` device report.** Left reads **0.006948 m joint error, worst
> 0.014994**; right reads **0.000000**. The kink at the left elbow is that number made
> geometric — the two links are drawn from each body's OWN pose, so where they fail to meet
> is the error itself.
>
> **★ A CONVENTION THIS SURFACED, worth applying to every example: SCALE UI WITH THE
> VIEWPORT.** A standalone build renders into a canvas at DEVICE resolution — a phone
> reporting a CSS width of 400 gives a canvas near 1080 wide — so a font asked for at 13
> "pixels" arrives about four CSS pixels tall. **The in-app viewer hides this** by rendering
> smaller; open the same file in a browser full-screen and the labels are unreadable, which
> is exactly what a device screenshot showed. `uiScale(w, h) = max(1, min(w, h) / 450)`
> makes a glyph a fixed fraction of the screen rather than a fixed count of pixels, needs no
> device pixel ratio (not exposed here), and behaves on a desktop window and a phone alike.
> Applied to `robot_sidebyside` and `robot_demo`; the next example should start with it.
>
> Fixes the screenshots prompted:
> * **Layout is now aspect-aware.** A phone in portrait is roughly 1:2, and forcing two
>   panels across it left each narrower than the pendulum is long — arms overran the divider
>   and the two readouts collided. Stacked when tall, side by side when wide.
> * **★ The demo now says the divergence is EXPECTED.** A double pendulum is chaotic, so any
>   difference between two discretisations is amplified exponentially and the arms are in
>   visibly different poses within seconds. Without saying so, the demo looks like it is
>   failing. The claim it makes is about how far each engine's own joints have come apart —
>   a property of the METHOD, not of the trajectory.
>
> Also: the generalized side's zero is now MEASURED, by reading the elbow twice (as the
> parent's far end and as the child's origin) exactly as the maximal side does. A hardcoded
> zero would be a claim; this is a measurement that happens to be zero, and it would report
> a regression in `kinematics` if one ever appeared.

### To build, in value order

| # | Category | Scene | Shows — and why it is worth a scene |
|---|---|---|---|
| ✅ | **Showcase** | **`robot_sidebyside`** — BUILT, device-confirmed | ★ **THE THESIS, MADE VISIBLE.** The same double pendulum: zimrphysics on the left (maximal, joints as constraints), robot.zig on the right (generalized). Live joint-anchor error readout: **0.000 on the right forever, a wandering number on the left.** Planned in §4b since the beginning and still unbuilt. Needs nothing past phase 3. Be fair to zimrphysics in the caption — it is the right tool for loose bodies. |
| ✅ | Contact | **`robot_contact`** — BUILT |
| ✅ | **Import** | **`robot_3d`** — BUILT: a real KUKA iiwa from URDF, in 3D | The zimrphysics seam, end to end. The demo phase 7 was written for. |
| 3 | Contact | arm resting on the floor | Persistent contact, not impulsive — and the static-geometry path `report_immovable_contacts` exists for. |
| ✅ | Sensors | **IMU readout** — BUILT | Live accelerometer / gyro / velocimeter on a swinging arm. Reads **9.81 at rest** and near zero at the top of a free swing — proper acceleration, made visible. The single best demonstration that the physics is real rather than plausible. |
| 5 | Tendons | differential drive | Two controls, two wheels, and neither control is a wheel. Drive and steer independently. Tested but never seen. |
| 6 | Tendons | coupled fingers | One tendon, several knuckles bending in a fixed ratio — the mechanism a gripper is. |
| 7 | Integrators | Euler vs implicitfast vs RK4 | One stiff damped model, three integrators, energy plotted. Euler diverges **in two steps**; the others do not. A slider for the timestep makes the stability boundary something you can find with your finger. |
| 8 | Dynamics | inverse dynamics readout | Live required torque per joint while you drag the arm. Shows what a motor would have to do — the quantity a roboticist actually cares about. |
| 9 | Kinematics | **singularity** | Straighten the arm fully and watch the Jacobian lose rank: the tip stops responding along one direction, and no torque helps. A real property of mechanisms, and the closing exercise of the course. |
| 10 | Kinematics | Jacobian columns | Each DOF's contribution at the tip, drawn as an arrow. Makes `J` a picture. |
| 11 | Actuators | filter vs filterexact | Set `τ < dt` and watch one diverge and the other not. **This is why both exist**, and the test asserts it at τ = dt/4. |
| 12 | Limits | mass-ratio invariance | The same load on a 1:1 and a 100:1 chain, penetration side by side. The `Â` scaling made visible — without it these differ by two orders of magnitude. |
| 13 | Showcase | 6-DOF arm | The thing people picture when they hear "robot". |
| 14 | Showcase | quadruped stand | Contact and actuators together; the first scene that is a *robot doing something*. |
| ✅ | Import | ~~a real robot~~ | **DONE** — `robot_3d`, the KUKA iiwa. A Menagerie MJCF model is the follow-on, once MJCF import exists. |

Numbers 1, 4 and 7 are the ones that would most change what a visitor understands, and none
needs anything the engine lacks.

**Scenes double as tests.** Several rows above are the *visual* form of a host test that
already exists (mass-ratio invariance, RK4 energy, filter divergence). That pairing is
deliberate: when the test passes and the demo looks wrong, the bug is in rendering or in
the model, and that is a much smaller search.

### C. `examples/robot_sidebyside` — the thesis, made visible
**The same double pendulum, twice.** Left: zimrphysics — two bodies plus revolute joints,
maximal coordinates. Right: robot.zig — two hinge DOFs, generalized coordinates. Identical
initial state, identical mass, identical timestep, drawn identically.

Under stress (high speed, small timestep, or a heavy tip) the left one's joints visibly
separate and drift, because they are constraints being *enforced* to a tolerance; the right
one cannot drift, because the freedom to drift was never represented. Add a live readout of
joint-anchor error: **0.000 on the right, forever, and a wandering number on the left.**

This is the entire argument for the project in one screen, it needs nothing beyond phase 3,
and it fits the house tradition exactly (`mandel_sidebyside`, `rt_sidebyside`,
`cube_sidebyside`, `physics_sidebyside`, `helmet_sw`, `decal_sw`).

**Be fair to zimrphysics in it.** The left side is not a strawman — it is the right tool for
loose bodies, and the demo should say so in its caption. What it shows is a *specific*
tradeoff, not that one engine is worse.

### What the demos need from the engine
Plan these as engine work, not as demo work, or they get hand-rolled three times:

- **`robot.debugDraw(model, data, opts)`** — links, joint frames, COMs, contact points,
  Jacobian arrows. Mirrors `phys.draw` for the 2D engine, which the 2D demo leans on
  heavily. Options-struct for what to show.
- **Profiler zones** from phase 1 (see R-list), so the HUD has something to display the
  day it is written.
- **`reset()`** for the scene switcher (falls out of `qpos0`, R1).
- **Orbit camera** — `OrbitCamera` already exists (zimr542) with the first-touch pop fixed
  (zimr543). Reuse; do not write another.

## 4c. Where we can actually beat MuJoCo

Not on speed, and not soon. MuJoCo is fifteen years of tuning by people who invented half
of this. But there are places where **the language is the advantage**, and they are worth
naming so we take them deliberately rather than stumbling into them.

**Adopted already:**

1. **`Motion` and `Force` are different types.** In MuJoCo both are `mjtNum[6]` and nothing
   stops you adding a velocity to a force. Two identical Zig structs cost a few lines and
   turn a whole class of spatial-algebra error into a compile error. This is the cheapest
   real win in the file.
2. **The model is validated at compile time.** A missing parent, a free joint in the middle
   of a tree, a massless moving body — all `@compileError` with the offending name, where
   MuJoCo's compiler raises them at load or (worse) lets them through to a singular mass
   matrix.
3. **Names are enums, and `@backingInt` IS the index.** MuJoCo does `mj_name2id` string
   lookups. Ours costs nothing and misspelling is a compile error.
4. **The pipeline stage watermark** (`Data.stage`). MuJoCo's own docs single out the
   imperative pipeline as the thing that surprises people: write `qpos` and everything
   derived is silently stale. In C the options are "check nothing" or "pay forever". Zig
   has a third: `assertf` compiles out of a ship build, so a development build says
   *"crb needs the position stage, but this Data is only at .stale"* and a ship build pays
   nothing. Note it is a DEBUGGING AID, never control flow — the pipeline stays explicit,
   which is the part of MuJoCo's design that is right.

**Available, not yet taken:**

5. **SIMD width.** `Vec` is `@Vector(4, f32)`, so a `Motion` is two vector registers for
   six numbers. MuJoCo is scalar f64 with hand-written AVX in places. On wasm SIMD128 a
   tree pass over `cdof` could genuinely be faster per DOF — but this is a *measurement*,
   not a claim, and it must not be made before phase 3 has something to measure.
6. **Errors instead of silent resets.** MuJoCo detects divergence, resets the state and
   raises a global warning flag. A Zig error union makes that the caller's decision.
7. **Batched rollouts as a first-class path** (phase G). MJX is a separate reimplementation
   in JAX; kompute lets the same kernel source run `.cpu`/`.worker`/`.gpu` unchanged.

**Deliberately NOT taken — clever, but worse to read:**

- *Typestate*: encoding the pipeline stage in the TYPE (`Data(.position)` → `Data(.velocity)`)
  would make a missed stage a compile error rather than an assert. It also doubles the
  type surface, makes every signature noisier, and fights every loop that steps repeatedly.
  The watermark gets ~90% of the value for ~5% of the cost.
- *Generating `Motion`/`Force` from one `Spatial(kind)` template*: removes ~20 duplicated
  lines and makes both types harder to read. The duplication is the documentation.
- *Full `inline for` unrolling of the tree passes*: rejected in §1.3 on build-size grounds,
  and the hybrid model decision makes it moot.

---

## 4d. Downstream: a differentiable GPU physics engine

**Known now, so it can shape decisions while they are still cheap.** After MuJoCo, the next
project is integrating an existing Zig libtorch port, with the goal of a **GPU
differentiable** physics engine. That is a much bigger prize than a fast simulator, and
several choices already made turn out to be the right ones — but a few upcoming ones would
be expensive to get wrong.

**Already aligned, by luck or by argument:**

- **The soft constraint model is the differentiable one.** This is the big one. Hard
  complementarity contact is non-differentiable at the contact boundary — the gradient
  simply does not exist where it matters. MuJoCo's convex soft model has a gradient
  everywhere, and its docs note `solimp` can be set to 0 specifically to make contact-force
  onset smooth and differentiable. Phase 6 was already going to be this; now it has a
  second reason.
- **`Model` / `Data` split.** `Model` is *parameters* — masses, inertias, damping,
  armature — and those are exactly what system identification wants gradients with respect
  to. `Data` is state. The split libtorch wants is the split MuJoCo already has.
- **`Data` is a flat, pointer-free buffer**, so it maps onto a tensor without a
  restructure. §1.3's hybrid preserved this; it is now load-bearing twice over.
- **f32**, which is torch's default working precision.
- **CRB rather than Featherstone's ABA.** ABA is O(n) always, CRB only O(n) via tree
  sparsity — but ABA never produces `M`, and both the constraint solver and any implicit
  gradient need `A = J M⁻¹ Jᵀ`. We are on the composable side of that fork.

**Upcoming choices that differentiability constrains:**

- **★ The phase-6 solver must have differentiable *optimality conditions*, not just a
  differentiable implementation.** Naive autodiff through an iterative solver unrolls every
  iteration into the tape: huge, slow, and numerically poor. The right technique is
  *implicit differentiation* — differentiate the KKT/optimality conditions of the converged
  solution and solve one linear system for the gradient, at a cost independent of iteration
  count. **This is a design constraint on phase 6, not a later add-on:** the solver must
  converge to a solution characterised by conditions we can write down and differentiate.
  A solver that merely "gets close enough" is not differentiable in this sense. Write the
  optimality conditions down when the solver is written, even if nothing consumes them yet.
- **Branches on state are gradient holes.** Every `if` on a state-dependent quantity is a
  point where the gradient is wrong or absent. Some are unavoidable (contact on/off), which
  is exactly what the soft model smooths. Prefer `@min`/`@max`/`@select` over `if` in the
  numerical core — the same discipline zimr already applies to shader code for a completely
  different reason.
- **Batching stops being optional.** Phase G moves from "nice demo" to "the point": gradient
  methods need many rollouts. Keep `Data` batchable.
- **Avoid non-tensor-shaped fields in hot arrays.** `jnt_range: []?[2]f32` is an optional
  per row — fine for the CPU, awkward as a tensor. Not worth changing yet; worth noticing
  before it multiplies.

**Not a reason to redesign anything today.** It is a reason to write phase 6's optimality
conditions down, and to keep the numerical core branch-light.

---

## 4e. Phase 6 in detail — the risk phase, planned before it starts

P7 says this is where the taste is and to budget 3-4x. That is not a plan. This is.

### The order, and why

**6a. Constraint rows, with NO solver.** Assemble `J`, the residual `r`, and the reference
acceleration `aref` for equality constraints and joint limits. Verify against MuJoCo's
`efc_J` / `efc_pos` / `efc_aref` fixtures with the solver switched off entirely. **Do not
write a solver until the rows are right**, because a wrong row and a wrong solver produce
the same symptom and debugging both at once is where the 3-4x estimate comes from.

**6b. The `Â` diagonal.** MuJoCo's approximation is computed at `qpos0` and has three
documented error sources; it also ships a `diagexact` flag that computes `A_ii = ‖Y_i‖²`
with `Y = J M^{-1/2}` at the current configuration. **Implement the EXACT diagonal first.**
It costs one back-substitution per row, we already have `solveM`, and it removes an entire
class of "why is this constraint behaving oddly" from 6c. Add the cheap approximation later
if profiling asks — the opposite order means debugging a solver against an inertia estimate
that is itself approximate.

**6c. One solver: projected Gauss-Seidel, pyramidal cone.** Nothing else until a demo
demands it. Elliptic cones and the Newton solver are the second half of `engine_solver.c`
and neither is needed to make an arm touch a table.

**6d. Contacts**, via the zimrphysics seam, with the R3/P12 sort.

### The differentiability constraint, made concrete (§4d)

"Write down the optimality conditions" is easy to nod at and skip. Concretely, PGS on the
soft-constraint problem converges to the solution of

    (A + R) f = aref − au,     f ∈ K (the friction cone)

so at convergence, for each row either `f` is interior to `K` and the residual
`(A+R)f − (aref − au)` is zero, or `f` is on the boundary and the residual is normal to it.
**Write a `constraintResidual()` that computes exactly that and returns its norm**, in 6c,
as a convergence check. It costs almost nothing, it is the honest way to know the solver
converged rather than merely stopped, and it is *the same expression* implicit
differentiation will need later. Building it as a diagnostic now means the gradient path is
not a rewrite.

### Test strategy, decided in advance

The audit's lesson applies double here: **generate oracle fixtures for constrained models
BEFORE writing 6a** — a model with a joint limit, one with an equality constraint, one with
a contact. MuJoCo exposes `efc_*` directly. Then:

- rows against the oracle, solver off (6a);
- `Â` against `diagexact` (6b);
- **mass-scale invariance** — the same load on a 1:1 and a 100:1 chain must produce the same
  penetration, which is the entire point of the impedance-scaled parameterization and the
  test that catches a wrong `Â`;
- `constraintResidual` below tolerance at convergence, on every fixture state;
- **determinism**: same scene twice from the same seed, bit-identical trajectories (P12).

### What "done" looks like

A joint stops at its limit with the softness the model asked for, the residual is small, and
the penetration is mass-invariant. Contact is 6d, not 6c.

---

## 4f. Standing lessons from the audits

Bugs whose *shape* recurs. Each cost a real debugging session, and each has a rule.

**A fixture generated but not asserted against is worse than no fixture — it looks like
coverage.** Five of six oracle models sat unread while a serious bug lived in the paths they
covered. Every model in `scripts/robot_oracle.py` now has a test; when a model is added,
its test is added in the same turn.

**A hinge-only test suite cannot see ball or free joint bugs.** `comVel` differentiated each
DOF against a velocity that already included its siblings — correct for scalar joints,
wrong for a rotation triple, where the three axes are simultaneous components of ONE
rotation and must share a snapshot. 43 tests passed over it. **When a code path has a
special case, a model exercising that special case is not optional.**

**A field stored and never read is a lie the compiler will not catch.** `jnt_damping` and
`jnt_stiffness` were plumbed through the spec, the model and the build, and applied
nowhere — the demo asked for damping it never got. Zig's `unused-global` does not reach
struct fields; a test that asserts the field *does something* is the only guard.

**Two code paths agreeing is weaker evidence than one source of truth.** The forward/inverse
round trip is exact because both directions use the same `M`, not because two recursions
agree. Prefer arrangements where a test *cannot* pass for the wrong reason.

**Convert conventions once, at the boundary.** Y-up and MuJoCo's `(w,x,y,z)` quaternions are
both handled in `scripts/robot_oracle.py`, so fixtures are already in zimr's frame. A
conversion in a test is a conversion that will be forgotten in the next test.

**A real robot's inertias span orders of magnitude, and uniform gains cannot survive it.**
The KUKA's joints run 3.43 down to 0.011 kg·m². Every arm built by hand for these tests had
links of comparable size, so nothing revealed it until a real model arrived. When a
controller needs one gain per joint, that is a sign the mass matrix should be doing the work
instead — computed torque, `τ = M·a* + c`, makes the closed loop identical everywhere.

**When a subsystem is unfamiliar, READ TEN CALL SITES before writing one.** The UI panel
went through three wrong versions — a hand-computed size, a zero height, then
`always_auto_resize` — because I was reasoning from the API's shape instead of from how it
is used. A survey settled it in one command: **nine of ten examples never call
`setNextWindowSize` at all**; they pass `initial_pos` / `initial_size` as window options.
The difference is not cosmetic — `setNextWindowSize` is an imperative override re-applied
EVERY FRAME, so it fights the window's own layout, while `initial_size` seeds it once.
Guessing cost three device round trips; the survey would have cost one command.

**A half-applied engine fix is worse than none.** The zero-means-auto-fit change patched the
window CREATION path and missed the per-frame consumer, so the override re-applied the zero
on frame two and the window still collapsed. The fix looked right, compiled, passed its own
test — and did nothing. When changing behaviour that has both a create path and a per-frame
path, grep for every read of the field, not just the first.

**Match the convention people already expect, or they will write the code that assumes it.**
`setNextWindowSize(.{ 380, 0 })` is how Dear ImGui says "this wide, as tall as the content
needs". zimr took the zero literally and made a window ONE PIXEL tall with every control
clipped — which reads as the UI failing to render, not as a size request being honoured. Now
a zero component means auto-fit on that axis, and a test pins it. The fix is not "document
the footgun"; it is to make the natural call do the natural thing.

**★ AND THE RUNTIME LINT EARNED ITS KEEP.** zimr's UI warns when a window's content is more
than 3x its viewport, and it printed *content (216px) is >3x its viewport (1px)* — naming the
exact number that was wrong. Minutes instead of an evening, from a phone screenshot. Worth
remembering when adding a subsystem: a cheap invariant check with a specific message beats
any amount of after-the-fact debugging.

**A bug fixed LOCALLY at one of several identical sites is a bug still shipping.** A u16
index buffer is a multiple of four bytes only when the index count is even — and indices come
in threes, so any mesh with an ODD TRIANGLE COUNT fails WebGPU's `queueWriteBuffer`. A KUKA
link has 2759 triangles: 16554 bytes, rejected. The engine had **three** index-upload sites;
one of them already carried a hand-rolled fix with a comment explaining the problem, and the
other two were untouched. All three now go through `createBufferInit`, which pads by
construction, and `alignedBufferSize` is exported so a caller recording the buffer's size
cannot compute it differently from the function that made it.

**The lesson generalises past this bug:** when fixing something, grep for the same call
shape elsewhere before considering it fixed. The local fix was correct, well commented, and
left the product broken.

**★★ A HAND-COPIED GENERATED FILE GOES STALE SILENTLY, AND THAT IS THE WORST KIND OF WRONG.**
`robot_3d` imported its own copy of `kuka_iiwa.zig`, copied there when the example was
written. When the importer learned to emit collision hulls, the copy did not change — so the
example simulated a robot with **`ngeom = 0`**. The bridge created no proxies, the arm did
not exist as far as the collision detector was concerned, and it swept through a crate tower
reporting zero contacts while every other part of the seam worked perfectly.

**Nothing warns about this.** It compiles, it runs, it is simply an older robot. Three
separate sessions of debugging went into the coupling, the floor, the placement and the
world's construction before the cause turned out to be a file nobody had touched.

The fix is not to re-copy it. `zig build urdf-import` now emits BOTH targets from the one
URDF — an example cannot import across a module boundary, so the duplicate must exist, but
it can be generated rather than copied. The emitter takes the import as an EXPRESSION
(`@import("../../../robot.zig")` vs `@import("zimr").robot`) so it needs to know nothing
about which world it is writing for.

**Generated output obeys the same lint as everything else.** The first hull emission ran to
157 columns against a 120 limit, and `zig fmt` collapses a struct literal onto one line
whenever it can — so the emitter now writes one field per line with trailing commas, which
is how you tell `zig fmt` to keep it broken.

**★ A WORLD BUILT ON A LOCAL AND COPIED INTO A STRUCT IS A DEAD WORLD.** `robot_3d` created
its `zp.World`, floor and crates on a stack local, then moved the world into the state
struct. Nothing crashed, nothing warned: the arm simply swept through the tower reporting
**zero contacts, forever**, with the geometry, the placement, the bridge and the step order
all correct. The bodies had been created against the original.

Two things made it findable. The readout said `contacts 0 / peak 0 N` — a running maximum
that had never once been nonzero, which is a much stronger statement than "it looks wrong".
And **`robot_contact` had the same seam and worked**, so diffing the two demos located it in
one command: that one built everything through `s.world`, this one did not.

The lesson generalises past this bug: when a subsystem works in one place and not another,
diff the two call sites before debugging the subsystem.

**A thin static shape is a hole for anything moving fast.** The crate tower exploded — five
crates to y = −100 m — and it looked like a stacking failure. It was a 10 cm floor: struck by
the arm at 3.5 m/s a crate crosses the whole slab inside one 1/240 s step, misses it, and
free-falls forever. **Bisecting isolated it in one run**: the tower alone settled to within
2 mm and stayed, which moved the suspicion off the stack and onto the collision. A floor is
a solid half-space, not a sheet, and a static box costs the same at any size.

**Measure the thing you are about to blame, and prime the measurement.** The first speed
check said the wrist reached 175 m/s, which would have explained everything — and was an
artifact: the tracker's previous position started at the origin because `forward` had not
run. Primed correctly it read 3.54 m/s, which sent the search somewhere else entirely. A
wrong number that CONFIRMS your hypothesis is more expensive than no number.

**★ WHEN FOUR CORRECT FIXES DO NOT MOVE THE NUMBER, STOP FIXING.** The impulse handoff took
four rounds, each of which found and fixed a genuine bug — a missing inertia term, an
exported positional correction, pyramid rows summing their normals, an absolute acceleration
where a relative one was needed. The symptom did not change once. That is not bad luck; it
means the model of the failure is wrong somewhere the current measurements cannot see, and
the fifth guess from the same vantage point is worth less than the first minute of a
different approach. **Build the smallest failing case instead** — one contact, one row, unit
mass, no articulation — where a factor of anything has nowhere to hide.

**★★ A MULTI-EDIT SCRIPT THAT THROWS WRITES NOTHING — AND I REPORTED IT AS DONE. AGAIN.**
The `robot_3d` controller fix was applied in a script whose LAST edit asserted zero matches.
The exception fired before the write, so none of the earlier edits landed either — including
the one that mattered. A later script then added the `desired_acc` FIELD without the code
that uses it, leaving a file that compiled, shipped, and crashed on the device with exactly
the error I had claimed to fix.

This is the third occurrence and the rule already existed. What was missing was the second
half: **after any scripted edit, grep for the result before building.** A build that succeeds
proves the file parses, not that the change is in it. The check costs one command:

    grep -c "<the old code>" <file>   # must be 0
    grep -c "<the new code>" <file>   # must be 1

Applied here, it would have caught the failure in the same minute it happened rather than
one device round trip later.

**★★ WHEN TWO PATHS TO THE SAME STATE DISAGREE, PRINT BOTH AND DIFF THEM.** The live mass
slider blew up: `factorM: pivot 34 is negative`, peak forces over 1 MN, velocities past 1e21.
Three plausible causes were investigated and each was wrong — a stale warm start (helped, did
not fix), changing mass while contacts are active (re-posing the scene did not fix it), the
solver being unable to carry heavy stacks.

**That last one was the discriminator, and it should have been the FIRST test.** A tower
BUILT at 300 kg was perfectly stable — 6.2 kN peak, no NaN — while the same tower SCALED to
300 kg exploded. Two paths to the same state, one working. Printing both models side by side
took one command and every field matched except one: **`body_subtree_mass`, still reading
0.8 kg for a 100 kg body.**

It is accumulated once at build time and never recomputed, and it feeds the centre-of-mass
reductions that run before the mass matrix is factored. A stale value does not produce a
small error — it produces a mass matrix assembled from **two different systems**.

`robot.refreshSubtreeMass` now exists for anyone mutating mass on a live model, and the fix
is total:

| | peak force | peak crate speed | NaN |
|---|---|---|---|
| without | 401,512 N | 1.1e21 m/s | **yes** |
| **with** | **3,942 N** | **2.46 m/s** | **no** |

The general lesson is the diff, not the field: when the same state is reachable two ways and
only one works, stop reasoning about mechanisms and compare the two states directly.

**A convenience default can be a trap.** URDF's `<limit>` bounds were being defaulted to
zero when absent — which welds the joint shut. A robot whose every joint is locked reads as
a physics bug, not an import one, and the search would start in the wrong file. Where a
missing value has a *plausible-looking wrong* answer, refuse instead of defaulting.

**"The first match wins" is a silent topology bug.** `findLink` returned the first link of a
given name, so two links sharing one left the second unreachable and every joint naming it
wired to the first. Duplicate names are now rejected before any name is resolved, and the
tree walk works in indices so a name cannot be re-resolved later.

**Verify the build actually RAN before believing a negative test.** A full disk surfaces as
`configure command exited with code 1` — nothing like "out of space" — so a planted bug can
appear to be caught when in truth nothing compiled. Twice now. Check the exit code and the
test count, not just a grep for "failed".

****Journalling something as done does not make it done.** `step1`/`step2` were recorded as
part of phase 3 and did not exist. When a phase entry claims a function, grep for it.

---

## 4g. ★ Performance: the endgame target

**The goal is explicit: by the time this port is finished, robot.zig must be AT LEAST as
fast as MuJoCo on an equivalent model, measured, on the same machine.** Not "close enough",
not "fast enough for a demo". Parity or better, or the port has not succeeded — a
reduced-coordinate simulator that is slower than the reference has no reason to exist when
the reference is open source.

That is a statement about the END, not about now. **Until phase 9, optimise for
understanding.** Every one of the deliberate slownesses below is a choice made to keep the
code checkable, and each is listed with what it costs and what removes it, so that "make it
fast" is a scheduled task with a work list rather than a rewrite.

### What we start ahead on

- **f32 with SIMD.** MuJoCo is f64 scalar with some hand-written AVX. `Motion` and `Force`
  are two `@Vector(4, f32)` each, so the tree passes vectorize for free, and wasm SIMD128
  is 4-wide at f32 and 2-wide at f64. This should be a real win in `kinematics`, `comPos`,
  `crb` and `rne` — the passes that dominate a model with few constraints.
- **No fill-in in the factorization**, same as MuJoCo, and we inherit it structurally rather
  than by an analysis pass.
- **No allocator traffic anywhere in a step.** `Data` is sized once.
- **A comptime-validated model**, so the hot paths carry no shape checks.

### Deliberate slownesses, with their cost and their fix

| # | What | Cost | Fix, when |
|---|---|---|---|
| S1 | **Dense constraint Jacobian**, `nc × nv` | A limit row has ONE nonzero out of `nv`. On a humanoid (`nv = 27`) every solver dot product is ~27× more work than needed, and the solver is the inner loop. **This is the single biggest known gap.** | Per-row sparse storage (index list + values), as MuJoCo's `efc_J_rownnz`/`colind`. Do it when contacts make `nc` large — phase 6d or immediately after. |
| S2 | **Exact `Â` via a solve per row** | One back-substitution per constraint row per step. MuJoCo's default approximation is O(1) per row. | Keep exact as the default — it is correct and it made 6c debuggable. Add the approximation behind a flag if profiling shows it matters. Note the exact version is also what implicit differentiation wants. |
| S3 | **No warm starting** ★ **NOW THE TOP PRIORITY** | PGS from zero each step. **Measured: 29 iterations where MuJoCo needs few enough that its constrained case costs only 1.12× its free one.** This single gap is most of why case 3 loses. | Needs stable row identity across steps (row indices shift as constraints activate). `Contact.id` and the `(body, source)` sort already exist for exactly this. |
| S4 | **No Nesterov momentum** | MuJoCo's PGS has it; convergence on stiff problems is meaningfully faster. | ~20 lines on top of the existing sweep. After 6d, measured. |
| S5 | **PGS only** | Newton converges in far fewer iterations on hard contact sets. MuJoCo defaults to Newton for a reason. | The plan's P7 says one algorithm until a demo demands better. A contact demo may well demand it. |
| S6 | **No islands** | One global solve where MuJoCo splits into independent subproblems. Matters for scenes, not for one robot. | Only if a multi-robot scene needs it. zimrphysics already has island machinery to borrow from. |
| S7 | **No profiler zones** | We cannot currently say WHERE time goes. | ★ Do this FIRST when optimisation starts — it was on the phase-1 list and slipped. Optimising without it is guessing. |

### ★★ S3 WARM STARTING LANDED — and we now beat MuJoCo on all three cases

| case | zimr before | **zimr now** | MuJoCo | |
|---|---|---|---|---|
| 1. two-link arm | 435 ns | **~290 ns** | 2531 ns | 8.7x faster |
| 2. KUKA iiwa free | 1921 ns | **~1330 ns** | 5937 ns | 4.5x faster |
| 3. KUKA, 5 limits | 8184 ns | **~2040 ns** | 6638 ns | **3.3x faster — was 0.81x** |

**Case 3 is the attributable win: 4x faster, and solver iterations went 29 → 1.** Cases 1
and 2 have no constraints, so warm starting cannot explain their change — re-running three
times shows case 1 swinging 20% between runs (it is the smallest workload and the noisiest),
so those numbers are reported but NOT claimed as this change's doing.

§4g's goal — parity or better, measured, on the same machine — is met on all three.

**★★ REVIEWED AGAINST MUJOCO'S OWN WARM START, and it found a real gap.**

MuJoCo warm-starts **`qacc`** — the nv-vector of accelerations — not per-constraint forces
(`engine_forward.c:warmstart`). That needs no constraint matching at all, which is simpler
than the key scheme here. For its PGS path, though, it DOES carry `efc_force` across steps,
relying on row order being stable rather than matching rows explicitly. **Our keyed matching
is the more robust of the two** — a row that genuinely persists keeps its force even when
other rows come and go — so the design stays.

**But MuJoCo does something we did not, and it matters.** It checks whether the warm start is
actually BETTER than starting from zero, and throws it away if not:

    cost(f) = ½fᵀ(A+R)f − fᵀ(aref − a_free),   and   cost(0) = 0

so a warm force with positive cost is worse than nothing, and the solver would spend
iterations undoing it. MuJoCo zeroes `efc_force` in exactly that case (and for Newton, picks
whichever of `qacc_warmstart` / `qacc_smooth` has the lower cost). Now implemented here, and
measured on the KUKA against five limits:

| situation | with guard | without |
|---|---|---|
| settled | 1 it | 1 it |
| poisoned warm force | **29 it** | 43 it |
| large velocity kick | **1 it** | 2 it |

The cost needs no matrix: after seeding, `(A·f)ᵢ = J·accᵢ − J·a_freeᵢ`, so it is one dot
product per row.

**★ AND A LESSON ABOUT TESTING SOLVERS.** The first version of this test used a ONE-ROW
model and passed with the guard disabled — because with a single row PGS reaches the exact
answer in one iteration whatever it starts from, so a bad start costs nothing. It takes a
COUPLED set to show the difference. The test now uses the KUKA's five limits and asserts the
`warm_start_rejected` flag rather than an iteration count, since pinning "29" would break on
any legitimate solver change.

**★★ THE BUG THAT MADE IT CATASTROPHIC RATHER THAN MERELY SLOW.** The first implementation
warm-started the FORCES and left `d.acc` holding the free acceleration. The iteration then
computed the whole force again and added it on top of the warm value, doubling it every
step: a joint resting on its limit sank straight through and its constraint force reached
**7619 N**. An existing test caught it immediately.

Seeding `acc += M⁻¹Jᵀf` alongside the force is what makes the two agree, so the iteration
measures only what is still MISSING — which is the entire point. The `M⁻¹Jᵀ` is already
computed by `projectConstraints`, so seeding costs one multiply-add per DOF and cannot
disagree with what the solver does with the same force.

**Row identity, which is what makes matching possible.** Row index is not identity — rows are
rebuilt each step and their order shifts as constraints come and go. `constraint_key` packs
the kind, the source, and a discriminator: which END for a limit (both ends share a joint
index, so without it a joint swinging between stops inherits the wrong force), and which
pyramid EDGE for a contact, keyed on `Contact.id` — the stable detector identity that phase
6d added for exactly this. Exact, not hashed: a collision would warm-start a row from an
unrelated force, which is a wrong answer that converges.

**`warm_start` is an option, defaulting on.** Off gives a solve that depends on nothing but
the current state, which §4d's differential rollouts may want — and it is how the test proves
the converged answer is the same either way.

### ★ FIRST MEASUREMENT — and §4g's prediction was right

`src/robot_bench.zig` and `scripts/robot_bench_mujoco.py`, 200,000 steps each, same machine,
single-threaded, same models, same initial state, MuJoCo 3.11.0.

| case | zimr | MuJoCo | |
|---|---|---|---|
| 1. two-link arm, nv 2 | **462 ns/step** | 2531 ns/step | **5.5× faster** |
| 2. KUKA iiwa free, nv 7 | **1897 ns/step** | 5937 ns/step | **3.1× faster** |
| 3. KUKA, 5 limits active | 8057 ns/step | **6638 ns/step** | **0.82× — WE LOSE** |

§4g predicted exactly this shape: *"Expect to LOSE this one until S1, S3 and S5 are
addressed."* The smooth dynamics win comfortably; the constraint path does not.

**★ THE CAUSE IS ONE NUMBER: 29 SOLVER ITERATIONS.** Case 3 costs 4.2× case 2 for us and
only 1.12× for MuJoCo, on the same five rows. We are not slower per iteration — we are
running far more of them. That points squarely at:

* **S3 (no warm starting).** Every step restarts PGS from zero force. MuJoCo warm-starts
  from the previous step's solution, and for a constraint set that barely changes between
  steps that is most of the difference. **This is now the highest-value optimisation in the
  table**, promoted above S1 on evidence.
* **S5 (PGS only).** MuJoCo defaults to Newton, which converges in far fewer iterations.
* **S2 (exact `Â`)**, five back-substitutions per step, is a real but secondary cost.

**Two methodology traps, both caught and worth recording:**

1. **The Python binding nearly ruined the measurement.** Calling `mj_step` once per
   iteration costs about a microsecond of pybind11 overhead — which for a model whose
   physics takes 500 ns would have timed the language boundary and reported it as MuJoCo
   being slow. `mj_step(m, d, nstep=N)` loops in C. It moved MuJoCo's two-link figure from
   3340 to 2531 ns; without it, case 1 would have looked like a 7× win instead of 5.5×.
2. **Both sides must run the same model.** MuJoCo cannot open the KUKA URDF at all without
   its mesh files, so the script strips `<collision>` and `<visual>` — leaving eight
   inertials and seven hinges on both sides. Leaving meshes in for one engine and out for
   the other would have compared different problems.

**One difference that is not a trick but must be stated: MuJoCo is f64, zimr is f32.** That
is §1.1's design decision, and a 2× memory-bandwidth advantage is part of why the tree
passes win. Pretending otherwise would be dishonest.

**Profiler zones are in** (`robot.kinematics`, `crb`, `factorM`, `rne`, `constraints`,
`project`, `solve`, `forward`, `step`), so the next question — where inside case 3 the time
goes — is now answerable rather than guessable.

### The benchmark, defined now so it cannot be chosen to flatter us

Three models, each stepped for a fixed number of steps, wall time compared against MuJoCo
on the same machine with the same timestep and the same solver iteration cap:

1. **A 2-link arm, no contact** — measures the smooth-dynamics passes in isolation. This is
   where f32 + SIMD should already win.
2. **A humanoid-sized tree (~27 DOF), no contact** — measures whether the tree passes scale.
3. **The same humanoid with ~20 active contacts** — measures the solver, and is where S1,
   S3 and S5 will show up. Expect to LOSE this one until they are addressed.

Report all three separately. A single aggregate number would let a win on (1) hide a loss
on (3), and (3) is the one that decides whether the engine is usable for robotics.

### The rule until then

Write the clear version, leave the measurement hook, and record the cost in this table. Do
not micro-optimise anything before S7 exists — every optimisation made without a profiler
is a guess that also costs readability.

---

## ★★★ 4k. THE COUPLING, RECONSIDERED FROM THE TOP

Four attempts at an impulse handoff each found a real bug and none moved the symptom. That
is the evidence for a design review rather than a fifth fix, and the review changes the
answer.

### The mistake was accepting the seam as given

Every version of §4h assumed two solvers must agree about a shared contact, and asked how to
make them. That question has no clean answer. A contact is a single constraint between two
inertias; **resolving it in two places is not an approximation of resolving it once, it is a
different and worse problem** — and every fix attempted was a way of making two wrong answers
cancel.

The four bugs found were all real, and fixing them all still left a crate at 76 m/s, because
none of them addressed the thing actually wrong.

### ★ What MuJoCo does, and why it has no coupling problem

**It has no second engine.** A free-floating box in MuJoCo is a body with a `<freejoint/>` —
six degrees of freedom in `qpos`, in the same tree as every robot link. A contact between an
arm and a box is a contact between two bodies of ONE system. The Jacobian spans both sides,
the mass matrix contains both inertias, one solver resolves it, and momentum is conserved by
construction rather than by handoff.

MuJoCo did not solve bidirectional coupling. **It declined to create the problem.**

### ★★ And zimr can do the same thing TODAY

Two capabilities already exist, built and tested for other reasons:

* **`JointKind.free`** — 6 DOFs, `nq = 7` with a quaternion, landed in phase 2. A free body
  is expressible in the robot's tree right now.
* **`addContactRows` already handles body-vs-body.** It builds the RELATIVE Jacobian
  `jac_b − jac_a` between two tree bodies, with contact-against-world falling out of the same
  expression because a static body's Jacobian is identically zero. The oracle fixtures
  already exercise multi-body contacts.

So the crate that will not behave is a crate on the wrong side of a line that did not need to
exist. Put it in the tree and every problem in §4h-ter evaporates — not because they are
solved, but because they are no longer posed.

### ✅ PROVEN BEFORE PLANNING FURTHER

`test "unified tree: a robot pushing a FREE BODY conserves momentum"` — a slider pusher
(2 kg) and a free-jointed crate (0.5 kg) in ONE tree, one contact between them, no gravity so
total momentum is a closed quantity.

    momentum: started 2.00000, ended 1.99995   ->   error 0.002%

**Over 600 steps, with no handoff, no second engine, and no new machinery.** `nv = 7` (one
slide plus six free), `nq = 8`. This is the number that is not merely wrong but MEANINGLESS
in the current architecture, because the two halves have no common ledger to balance.

One wrinkle worth recording: the first run of this test read 0.58% out, which looked like a
conservation failure and was a bookkeeping one — the slider carried default ARMATURE, which
is rotor inertia and not mass, so `m·v` did not account for all of the resistance. Set to
zero, the books balance. A momentum test must sum every inertia the solver knows about.

### The revised architecture

| concern | owner |
|---|---|
| dynamics of the robot AND anything it must interact with correctly | **`robot.zig`**, one solver, one mass matrix |
| collision DETECTION — broad phase, narrow phase, manifolds, hulls | **`zimrphysics`** |
| the rest of the world: scenery, debris, ragdolls, anything the robot does not touch | **`zimrphysics`**, as now |

The bridge stops being a coupler and becomes a DETECTOR: proxies out for every tree body
(links and free bodies alike), manifolds back. No impulse handoff, no `applyReactions`, no
sensor question, no mass properties crossing the boundary — those all exist only to service
a seam that is being removed.

**This is a smaller change than it sounds**, because the hard parts are done. `buildRuntime`
already constructs a `Model` from a runtime spec, so a scene can add free bodies without
recompiling. `Contact` already carries two tree body indices. The contact solver already
handles them.

### What it costs, stated honestly

* **Everything the robot interacts with pays articulated-solver prices.** A thousand pieces of
  debris should stay in zimrphysics; a crate the arm must push belongs in the tree. That is a
  scene-authoring decision and needs to be an obvious one.
* **Bodies must be able to move between the two at runtime** if a scene wants debris that
  becomes interactive. Deferred until something needs it — §1.1's rule.
* **`robot.zig` gains world-collision responsibility it has been free of.** It still does no
  detection; it receives manifolds. The dependency rule (zimrmath only) is unchanged.

### The plan, in order

1. **A failing test first, at the smallest scale that can fail**: one slider link, one free
   body, one contact, hand-computed impulse. §4f's lesson — every experiment so far ran on
   four contact points and sixteen rows, enough machinery to hide a factor of anything.
2. **A `Scene` on top of `buildRuntime`**: a robot spec plus free bodies, built into one
   `Model`. Free bodies get `.free` joints and their geoms.
3. **The bridge reports tree-body pairs.** `harvest` maps both sides to tree indices instead
   of `world_body` — it already has the mapping for links; free bodies join the same table.
4. **Delete the handoff machinery** — `applyReactions`, `external`, `external_com`,
   `external_velocity`, `external_acceleration`, `constraint_reaction_fraction`, and the
   external term in `Â`. All of it exists to service the seam. **Keep the tests**: they
   describe behaviour that must still hold, and should be rewritten against the new path.
5. **Momentum as the acceptance test**: arm pushes free crate, total linear momentum of the
   whole system is conserved to integrator error. Not approximately, not qualitatively — a
   number, and one that is meaningless today because the two halves have no common ledger.

### What survives from §4h-ter

The measurements. The mass-independence table is the clearest statement of what the old
architecture cost, and the four bugs found were real bugs in real code. But the code they
fixed is code the new design deletes, which is the most useful thing a review can conclude.

---

## 4h-ter. THE IMPULSE HANDOFF — designed before it is written

§4h-bis established by elimination that the crate ejection is the COUPLING, not the
parameters. This is the fix, specified first, as §4e was for phase 6.

### What is actually wrong today, stated exactly

A robot-vs-dynamic contact is resolved TWICE, by two solvers, each treating the other side as
immovable:

* **zimrphysics** sees a kinematic proxy — infinite mass, cannot be pushed back — so the
  whole contact resolves on the crate, and a deep overlap ejects it at whatever speed
  separates the shapes. Hundreds of metres per second, measured.
* **robot.zig** sees `body_b = world_body`, which `Contact` documents as "an external
  dynamic body is immovable from the robot's point of view". So the arm braces against a
  1 kg crate as though it were bolted to the floor.

Both errors point the same way: **each side over-resists.** A consequence worth stating
because it is counter-intuitive — **making the crates heavier changes nothing about how the
arm feels them.** The arm already treats them as infinitely heavy. Mass only enters on the
zimrphysics side, where it decides how fast the crate leaves.

### The fix: one solver owns the pair

The robot's solver already handles articulated inertia properly, and a contact is a
constraint between TWO inertias. Give it the second one.

**1. `Contact` carries the external body's inverse mass and inverse world inertia.** For a
static body both are zero, which reproduces today's behaviour exactly — so the change is
additive and every existing test stays valid.

**2. `Â` gains the external side.** The constraint-space inertia of a contact between an
articulated chain and a free body is

    Â = Jᵣ M⁻¹ Jᵣᵀ  +  1/m  +  (r × n)ᵀ I⁻¹ (r × n)

The first term is what `projectConstraints` already computes; the other two are the crate's
resistance at the contact point. With them, the force needed to stop the relative motion is
the force to stop a 1 kg box, not to move a wall.

**3. The solved impulse is handed back.** After `solveConstraints`, each robot-vs-dynamic row
applies `−f·n·h` to the external body through `applyImpulse`. Equal and opposite, once,
computed by a solver that knew both masses.

**4. zimrphysics must NOT also resolve the pair.** This is the part that makes it work rather
than double-count, and `is_sensor` is exactly the mechanism: a sensor proxy is still tested
by the broad and narrow phases and still fires the contact listener, but contributes no
constraint of its own. The proxies become sensors ONLY where they meet dynamic bodies;
against static geometry the current path is correct and stays.

> **✅ STEPS 1 AND 2 LANDED.** `Contact` carries `external.inverse_mass`,
> `external.inverse_inertia` and `external_com`; `Â` adds `1/m + (r×n)ᵀI⁻¹(r×n)`. Both
> default to zero, which IS the immovable case — so the change is purely additive and all 96
> tests passed unchanged on the first run.
>
> **The row direction is stored, not reconstructed.** A pyramid gives four rows per contact,
> each `normal + sign·mu·tangent`, and each feels a different share of the external body's
> inertia — a push along the lever arm resists differently from one through the centre of
> mass. Computing it from the contact NORMAL would be right for one row in four, so
> `constraint_direction` is filled where the row is formed.
>
> A test pins the physics that was missing: the constraint-space inertia is strictly larger
> against a 1 kg crate than against the floor, and a 1000 kg body sits between the two —
> which is the first time "make the crates heavier" means anything to the robot at all.
>
> **Steps 3 and 4 are WRITTEN BUT NOT ENABLED, and the reason is worth recording.**
>
> `Bridge.applyReactions` exists, the proxies can be made sensors with one flag, and
> `harvest` can fill the mass properties — all three lines are in place and commented. They
> are switched off, because turning them on made an existing test fail in a way that
> revealed the design is INCOMPLETE.
>
> **What the sleep test caught.** With the proxies as sensors, zimrphysics stops holding a
> crate that rests on the arm, so the robot's solver must. It did not. Adding the relative
> velocity (`Contact.external_velocity`, since a contact constrains RELATIVE motion and the
> row was only measuring the robot's own) was necessary but not sufficient.
>
> **The remaining gap, stated precisely.** `Â` now says "this force produces this much
> relative acceleration", counting both inertias — but the solver's iteration measures
> progress with `J·acc`, and `acc` tracks only the ROBOT's response. The external body's
> share of the acceleration is applied after the solve, as a force, so within one iteration
> the two disagree. A resting contact never converges on a force that holds.
>
> **What it needs:** the solver must carry the external body's acceleration response per row
> — updating it alongside `d.acc` when a row's force changes, exactly as it does for the
> robot's DOFs. That is a real extension to `solveConstraints`, not a wiring change.
>
> **What DID land, and is tested:** `Â` carries the external inertia, the constraint velocity
> is relative, and `Contact` has the fields. All inert while nothing supplies mass, which is
> why the tree is green — and one line from being live once the solver can hold up its end.

> **★★ THE COST OF NOT FINISHING THIS, MEASURED ACROSS A 666x MASS RANGE.**
>
> "Would a heavier crate block the arm?" is answerable today, and the answer is the clearest
> possible argument for the handoff. The KUKA sweeps a five-crate tower, crate density varied
> from 100 to 50,000:
>
> | crate mass | worst arm lag | peak force | crate flew |
> |---|---|---|---|
> | 0.1 kg | 0.3746 rad | 798 N | 285.8 m |
> | 0.8 kg | 0.3706 rad | 686 N | 284.0 m |
> | 6.7 kg | 0.3739 rad | 766 N | 285.4 m |
> | **66.6 kg** | **0.3751 rad** | 828 N | **284.9 m** |
>
> **Mass changes nothing. In either direction.** A 66 kg crate is flung 285 m exactly like a
> 100 g one, and blocks the arm to within 1% of the same tracking error. That is both halves
> of the approximation visible at once: the robot treats every external body as a wall, and
> zimrphysics treats every proxy as a wall.
>
> To answer the question directly: **the arm is ALREADY blocked as hard as it can be** — it
> behaves as though pushing against immovable geometry, at every mass. What a heavier crate
> ought to change is how LONG the block lasts, and even that is invisible here because the
> crate leaves at the same speed regardless.
>
> **⚠️ STEP 4 IS BLOCKED — and the cause is now MEASURED, not guessed.**
>
> **★ FIRST, A CORRECTION: sensors DO report contacts.** The previous note here said they did
> not. An isolated test — a kinematic sensor platform, a dynamic crate, a listener, no robot
> anywhere — fires **53 callbacks**. The earlier conclusion came from watching the robot demo
> and inferring; the isolated rig took ten minutes and said the opposite. *Test the mechanism,
> not the system that uses it.*
>
> **What actually goes wrong**, traced step by step on a crate resting on a robot table:
>
> | step | rows | solver force | distance |
> |---|---|---|---|
> | 0–7 | 0 | 0 | separating, crate settling |
> | **8** | 16 | **7399 N** | first penetration, −1.1 mm |
> | 9 | — | — | crate leaving at **76 m/s** |
>
> `7399 N / 240 Hz = 30.8 N·s` on a 0.4 kg crate is 77 m/s — the numbers close exactly. So
> nothing is broken in the plumbing: the solver is internally consistent, `Â` correctly
> includes the crate's inverse mass, and the reaction sign is right. **The demanded
> acceleration is simply absurd**, because a soft contact asks for its penetration back on a
> time constant tuned for the robot's own multi-kilogram links, and that is 1900x the 3.9 N
> it takes to hold this crate up.
>
> **★ THE INSIGHT, AND THE NEXT STEP.** A soft constraint's force has two parts: a VELOCITY
> part, which is real Newtonian reaction, and a POSITION part — the Baumgarte-style term that
> pushes accumulated penetration back out. The position part is a numerical fudge, not a
> force anything exerted, and handing it across the seam is what launches the crate. Only the
> velocity part should cross.
>
> **Attempted, and it is NOT sufficient on its own.** `constraint_reaction_fraction` now
> records the damping term's share of `aref`, and `applyReactions` exports only that. It cut
> the first-contact force from 7399 N to 323 N per row — but the crate still left at 71 m/s,
> and tracing why turned up the next thing:
>
> **★ A PYRAMID IS FOUR ROWS, AND EACH CARRIES THE FULL NORMAL.** Four contact points times
> four pyramid edges is SIXTEEN rows, each of whose direction is `normal + sign·mu·tangent`.
> The tangents cancel across opposing edges; the normals ADD. Summing every row's reaction
> therefore delivers several times the physical normal force. The robot's own solver is
> consistent with this — its Jacobian rows carry the full normal too — but an exported
> impulse must be the PHYSICAL one, which means resolving the pyramid back to a single
> force per contact point before it crosses the seam.
>
> **★ A FOURTH REAL BUG, ALSO FIXED, ALSO NOT SUFFICIENT: the constraint acceleration was
> not relative.** Once `Â` counts the external body's inverse mass, the row describes the
> RELATIVE motion of a pair — so the acceleration it measures must be relative too. The
> velocity term already was (`vel −= external_velocity`); the acceleration was not. A crate
> in free fall accelerates at −9.81 whether the robot knows or not, and a constraint using an
> absolute acceleration against a relative inertia describes no physical situation at all.
> `Contact.external_acceleration` and `externalAlongRow` fix it, symmetrically with the
> velocity.
>
> **And the crate still launches.** Four attempts, four genuine bugs found and fixed —
> external inertia missing, positional correction exported, pyramid rows summing, absolute
> acceleration — and the symptom is unchanged. **That is the signal to stop.** When four
> correct fixes do not move a number, the model of the failure is wrong somewhere the
> measurements so far cannot see, and a fifth guess from the same vantage point is not worth
> making.
>
> ### Where a fresh attempt should start
>
> Not in `robot_physics.zig`. The next thing to establish is the SIMPLEST case that fails:
> one contact, one row, a unit mass, no pyramid, no articulation — a slider robot pressing a
> free box, with the impulse computed by hand and compared against what `applyReactions`
> delivers. Every experiment so far has been on a system with four contact points, sixteen
> rows and a hinge, which is enough machinery to hide a factor of anything.
>
> The three engine-side pieces are correct, tested, and dormant behind `external = .{}`:
> external inertia in `Â`, the reaction fraction, and the relative acceleration. They cost
> nothing while switched off and no work is lost.

**Superseded — the pyramid note above stands but is not the whole story.**
>
> **Reverted to the known-good state** for shipping: ordinary kinematic proxies, external
> mass unsupplied. Everything built along the way — external `Â`, per-row direction, the
> reaction fraction, `applyReactions` — is in place and dormant behind two lines.

> **The state as shipped:** proxies are ordinary kinematic bodies, external mass unsupplied,
> which is the previously working behaviour. The engine work (external `Â`, per-row
> direction, `applyReactions`) is in place and dormant, and one line switches it on.

**⚠️ Superseded — see above.**
>
> Steps 1–3 are done and tested: `Contact` carries the external inertia, `Â` includes it,
> `constraint_direction` is stored per pyramid row, and `applyReactions` hands the solved
> impulse back through `addForceAtPosition`.
>
> **Step 4 was to make the proxies sensors.** `is_sensor` is documented as bypassing the
> immovable-pair gate while "additionally suppressing the collision response against dynamic
> bodies" — precisely one-solver-owns-the-pair. It does not behave that way.
>
> | case | with sensor proxies |
> |---|---|
> | arm STRIKES a crate tower | **works well** — crates leave at 4 m/s instead of hundreds, none tunnel, 13 contacts, momentum plausible |
> | crate RESTS on the arm | **broken** — zero contacts reported, and the crate accelerates upward to y = 217 m |
>
> So the idea is sound — the struck case is exactly the improvement §4h-ter predicted — but a
> sensor proxy is not simply "detects but does not respond", and the resting and struck cases
> differ in a way the flag's description does not explain. That needs an afternoon inside
> zimrphysics' narrow phase, not another guess from outside it.
>
> **Reverted to the previously working state**: proxies are ordinary kinematic bodies again,
> and the external mass is left UNSUPPLIED to match — because while both solvers resolve the
> pair, supplying it counts the crate's give twice and softens every contact. Zero is the
> immovable case, which is what the robot assumed before any of this.
>
> **The engine work is done and dormant.** One line in `harvest` switches it on the moment
> the sensor question is answered, and the acceptance test is already written: `robot_3d`'s
> speed clamp should become removable, and removing it should change nothing.

### What this buys, and what it costs

Crates get pushed rather than launched, the arm feels a light box as light, and momentum is
conserved across the seam for the first time. The cost is that `Bridge` must know which
counterpart bodies are dynamic and fetch their mass properties — one lookup per contact,
during harvest, where the body handle is already in hand.

### How it gets verified

**Momentum.** Push a free crate with the arm and check that the crate's momentum change
equals the impulse the arm's solver reported, to within the integrator's error. That is a
number, and it is zero today because nothing hands anything back.

**And the demo stops needing its plaster.** `robot_3d`'s speed clamp exists only because
ejection is unbounded; when the handoff lands the clamp should be removable, and removing it
should change nothing. That is the acceptance test.

---

## 4h-bis. ★ THE COUPLING LIMIT, OBSERVED — evidence for the §4h upgrade

The 3D crate tower made §4h's known approximation VISIBLE for the first time, and the
investigation is worth keeping because it rules out everything else.

**The symptom:** the arm sweeps through a five-crate tower and two crates leave at hundreds
of metres per second, cross the floor inside one step, and fall forever.

**What was ruled out, in order:**

| hypothesis | test | result |
|---|---|---|
| the stack is unstable | run the tower with NO arm | settles to 2 mm and stays — stack is fine |
| the arm moves absurdly fast | measure wrist speed | 3.5 m/s — brisk, not absurd |
| the floor is too thin | 0.05 m → 0.5 m | tunnelling still happens |
| the imported hulls are wrong | print every geom's extent | 10–30 cm per link — correct |
| it is an impact-velocity problem | sweep 4x slower, crates 4x denser | **barely changes it** |

That last row is the one that settles it. If speed and mass do not matter, the energy is not
coming from the impact — it is coming from the CONSTRAINT RESOLUTION. A kinematic proxy has
infinite mass and cannot be pushed back, so a deep overlap resolves entirely on the crate's
side and the separation impulse is whatever it takes.

**One measurement error worth recording:** the first wrist-speed check read 175 m/s and would
have "explained" everything. It was an artifact — the tracker's previous position started at
the origin because `forward` had not run yet. A wrong number that confirms your hypothesis is
more expensive than no number.

**The fix is §4h's impulse handoff**, unchanged and now motivated by evidence rather than
argument: a robot-vs-dynamic pair should be resolved ONCE with both masses, instead of each
engine solving it alone treating the other as immovable. `robot_3d` carries a speed clamp in
the meantime, labelled in the source as a demo guard rather than physics.

---

## 4h. ★ The zimrphysics seam, reviewed adversarially

This interface will carry every later phase, so it got a review of its own. What follows is
the design space, what we chose, what is actually wrong today, and where the blind spots are.

### The design space, enumerated

Two simulators must agree about one reality. Every possible arrangement is a choice on three
axes, and it is worth seeing all of them before defending one.

**Axis 1 — who owns the robot's geometric state?** The robot must own it: generalized
coordinates cannot be reconstructed from body poses. Settled, not really a choice.

**Axis 2 — who solves a shared contact?** This is the real axis.

| | Design | Load transfer | Verdict |
|---|---|---|---|
| **A** | **Mirror + independent solve** — each side solves the contact treating the other as immovable. | Depends on the RATIO of two stiffnesses. | **CURRENT.** Simple, works, unphysical coupling (below). |
| **B** | **Impulse handoff** — zimrphysics solves; the robot receives the resulting impulse as an external force, and builds no row. | Exact, one step late. | Better *where it applies*. See the asymmetry below. |
| **C** | **Robot as authority** — dynamic bodies touching the robot are absorbed into its tree as `free`-joint bodies, one system, one solve, then written back. | Exact, no lag, no coupling error. | Genuinely possible — §1.3's hybrid makes `Model` a runtime struct and `free` joints already exist. Expensive and invasive. |
| **D** | **World as authority** — the robot becomes maximal-coordinate bodies. | Exact. | Defeats the entire point of the port. |
| **E** | **Alternate to convergence** — iterate the two solvers each step. | Exact at convergence. | Doubles or triples the cost; the classic co-simulation answer. |

**Axis 3 — frame ordering.** Currently `sync → world.step → harvest → robot.step`. The
manifold depths handed to the robot are measured before the world's solve, so both engines
resolve the same pre-solve penetration. Consistent, with one step of lag on the world's
motion. Acceptable at 240 Hz; worth remembering it exists.

### ★ The finding that matters most: the static/dynamic asymmetry

**A and B are not competitors. They apply to different contacts, and the code should choose
per contact.**

- **Robot vs STATIC geometry** (a floor, a table). zimrphysics computes NO impulse — that is
  exactly the immovable pair `report_immovable_contacts` re-enables reporting for. There is
  no impulse to hand over, so **the robot must build its own rows. Only A is possible.**
- **Robot vs DYNAMIC body** (a crate). zimrphysics computes a real impulse. **B gives exact
  load transfer where A does not.**

Neither the plan nor the code anticipated this split. It is the single most valuable thing
this review found.

### Why A's load transfer is worse than "double counting" admits

The file header calls the current coupling double-counting and says a heavy crate feels
stiffer than it should. True but understated. Trace what the arm actually feels with a crate
resting on it:

1. zimrphysics holds the crate up, settling at a penetration `p` where ITS contact stiffness
   produces `mg`.
2. robot.zig sees that same `p` and produces `f_rbt(p)` on the arm.
3. `f_rbt(p) = mg` **only if the two contact stiffnesses happen to match.**

So the load a robot feels depends on the ratio of two independently-tuned softness
parameters. Retune zimrphysics's contacts for a crate-stacking demo and every robot in the
scene silently feels a different weight. That is not an approximation with a known error
bound; it is an unphysical coupling between two tuning knobs, and it is the strongest
argument for B.

### Bugs found and fixed in this review

1. **`deinit` left the proxies in the world AND left a dangling listener.** The world kept a
   `context` pointer to freed memory and called into it on the next step, and the proxy
   bodies went on colliding on behalf of a robot that no longer existed. `deinit` now takes
   the world, removes its bodies, and clears the listener only if it is still ours.
2. **Proxies had no `group_id`**, so every pair of overlapping adjacent links was broad- and
   narrow-phased each step for a result `onContact` immediately discards. Harmless but not
   free — and `report_immovable_contacts` made it worse, since opting out of the immovable
   gate is precisely what put that work back. All of one robot's proxies now share a group.
3. **The tangent frame is discontinuous** — the helper axis jumps as the normal rotates, and
   the frame rotates ninety degrees with it. Nothing breaks today (any orthogonal basis is
   valid) but the pyramid's anisotropy rotates and warm starting will be impossible. Fixed
   by documenting the exact remedy at the call site: carry the frame on the `Contact` across
   steps and re-orthogonalise. `Contact` already takes tangents as an input for this reason.

### Blind spots — things that will bite and have no test

- ~~**Sleeping**~~ — **DISCHARGED BY MEASUREMENT.** The worry was that a crate asleep on a
  motionless arm would stop being reported and the arm would silently stop feeling its
  weight. It does not happen: `moveKinematic` calls `setLinearVelocity`, which wakes the
  proxy EVERY step, and the narrow phase's island gate passes when either endpoint is
  awake. Verified over four times `time_before_sleep` with a crate on a flat link, and the
  test stays as a permanent guard.

  Worth keeping the process note: the first attempt FAILED, and the cause was not sleeping
  at all — a box balanced on a SPHERE rolls off. **A failing test proves something is
  wrong, not what.** Had I taken it at face value I would have "fixed" a bug that did not
  exist.
- **Speculative contacts.** zimrphysics reports manifolds before touching; `addContactRows`
  discards anything with `distance >= margin`, so the robot forgoes the anti-tunnelling the
  world gets for free. A fast link can pass through what the world would have stopped.
- **Restitution.** zimrphysics contacts bounce; robot.zig's model has no restitution at all.
  The same collision is elastic on one side and not the other.
- **Allocation in the step loop.** `moveKinematic` takes an allocator and is called per geom
  per step. §4g wants no allocator traffic in a step; this needs measuring.
- **Two robots in one world** happens to work — each bridge sees the other's proxies as
  world, giving one-way coupling in both directions — but it works by accident, not design,
  and nothing tests it.
- **World body capacity.** `world_to_robot` is sized once from a caller-supplied capacity. A
  world that grows past it silently stops recognising proxies.

### How futureproof is this, honestly?

**The parts that will survive:** `Contact` as a plain value type with no shape identity;
contacts as an INPUT to the robot rather than something it discovers; the bridge living in
its own file so robot.zig depends only on zimrmath. Those three make every option above
reachable without touching the core.

**The part most likely to be rewritten:** the coupling itself. Design A is the simplest
thing that works, and its load transfer is wrong in a way that a demo will eventually
expose. The B upgrade is contained — the bridge already knows which side is dynamic, so it
can hand over an impulse instead of a manifold for exactly those contacts.

**The thing to avoid committing to:** anything that assumes a contact's response is decided
by robot.zig. Design B and design C both move that decision elsewhere, and `Data.contacts`
being an input list rather than a callback is what keeps them open.

---

## 4i. ★ Importing real robots — the gap, measured

The engine can now simulate a robot. It cannot yet *read* one, and every interesting robot
already exists as a file somebody else wrote. This section is what stands between here and
loading a Franka Panda.

### Where the models are, and that they are reachable

**MuJoCo Menagerie** (`google-deepmind/mujoco_menagerie`) is the good collection: arms
(Franka Panda, UR5e, xArm), quadrupeds (Go1, ANYmal, Spot), humanoids (H1, G1), hands
(Shadow, Allegro, Robotiq). High quality, MJCF, permissively licensed, actively maintained.
**Verified downloadable from this sandbox** — `raw.githubusercontent.com` is allowlisted, so
importer work can be tested against real files rather than against toys we wrote ourselves.
URDF (the ROS format) is the other large source and is a second target, not a first.

### What real models actually use — a census, not a guess

Tag counts across five downloaded models (Panda, UR5e, Go1, H1, Robotiq 2F85):

| count | tag | status |
|---|---|---|
| 281 | `geom` | ✅ but see meshes |
| 122 | `mesh` | ❌ **every collision geom is a mesh** |
| 74 | `joint` | ✅ hinge, slide, free |
| 62 | `inertial` | ❌ **explicit mass/com/inertia per body** |
| 55 | `default` | ❌ class inheritance, pervasive (80–106 uses per model) |
| 20/19/16 | `general`/`motor`/`position` | ✅ the affine actuator |
| 11 | `site` | ✅ |
| 9 | `exclude` | ❌ contact exclusion pairs |
| 3 | `keyframe` | ❌ named poses |
| 2 | `tendon`+`fixed` | ✅ fixed tendons |
| 2 | `equality`+`connect` | ❌ **closed loops** |
| 2 | `freejoint` | ✅ |

Two findings worth calling out because they were not obvious:

**★ `<inertial>` is the biggest single gap.** Sixty-two uses. Real models specify mass, COM
and a full inertia tensor per body — measured from CAD or hardware — rather than deriving
them from geom density, which is what `geomsToBodyMass` does. A Panda link reads
`mass="0.629769" fullinertia="0.00315 0.00388 0.004285 8.29e-7 0.00015 8.23e-6"`. Our
`Inertia` already stores exactly that shape (six symmetric components plus mass and first
moment), so this is a spec field and a build branch, not new machinery. **Do it first: it is
cheap and nothing else is usable without it.**

**`<option integrator="implicitfast"/>`** is what the Panda asks for — the integrator phase
10 just built. Pleasant confirmation that the phase order tracked what real models need.

### The ordered gap list

1. ~~**`<inertial>`**~~ — **✅ LANDED.** `InertialSpec` on `BodySpec`; when present it
   replaces the geom-derived properties entirely, while the geoms go on colliding. A near
   transcription rather than a computation, which is the payoff for `Inertia` storing the
   full symmetric tensor — MuJoCo's `fullinertia` order `(xx, yy, zz, xy, xz, yz)` copies
   straight into `diag` and `off`, with no eigendecomposition anywhere.

   `Spec()` rejects a non-positive mass or principal moment, and a diagonal violating the
   **triangle inequality** — `Ixx + Iyy ≥ Izz` and its permutations. No rigid body has
   moments that fail it, and catching it here beats a `factorM` pivot assert three phases
   downstream with no idea which body was wrong.

   Tested with a REAL Panda link's numbers, on a body whose geom is a deliberately absurd
   4000 kg sphere — so ignoring the stated values would be off by orders of magnitude
   rather than subtly. Plus an equivalence test: read the geom path's output back out, feed
   it in as a stated inertial, and the dynamics agree to 1e-4. That is what makes the second
   path trustworthy — it is not a parallel way of describing mass that might disagree, it is
   the same quantity entered differently.
2. **`<default>` class resolution** — pure importer work, no engine change. Pervasive, so
   an importer that ignores it reads almost nothing correctly.
3. **Mesh geoms** — `GeomShape` gains a mesh/hull arm; zimrphysics already has hulls,
   meshes and `buildConvexHull`. Needs an STL/OBJ loader and an asset path convention.
4. **`<contact><exclude>`** — pair filtering. The seam already has `group_id`; per-pair
   exclusion needs a little more, and without it adjacent links self-collide.
5. **`<equality><connect>`** — closed kinematic loops. **The only item that is real engine
   work**, and it is the natural §11 below.
6. **`<keyframe>`** — named poses. Trivial once `qpos0` exists, which it does.
7. **Units and axes** — `<compiler angle="degree|radian">`, and the Z-up → Y-up rotation
   §1.2 promised would live in the importer. This is that importer.

### Importer strategy: generate Zig first, parse at runtime later

**Phase A — offline code generation.** A tool reads MJCF and emits a `robot.Spec(...)`
literal as Zig source. The model is then comptime-validated like any hand-written one, no
XML parser ships in the binary, and the generated file is readable and diffable in review.
This is the same pattern as `scripts/robot_oracle.py` emitting fixtures, which has worked
well. **Do this first**: it converts an import bug into a compile error and a readable diff.

**Phase B — runtime parsing**, for a model editor, user-supplied files, or anything chosen
after the binary was built. §1.3's hybrid was designed to keep this reachable: `Model` is an
ordinary runtime struct, so a parser can build one directly and lose only the generated name
enums.

The tool should be Zig (house rule), and it should be a `zig build` step so a regenerated
model is one command. Assets are the awkward part: meshes are separate binary files, and
zimr has no convention yet for a model that owns a directory. Decide that when meshes land,
not before.

### The honest scope warning

MJCF is large. A complete importer is not the goal and would not pay for itself — the goal
is to load the Menagerie models we actually want to run. **Import what those five models
use, error loudly on everything else**, and grow the supported set when a specific model
demands it. An importer that silently ignores a tag it does not understand produces a robot
that is subtly the wrong shape, which is the worst outcome available.

---

## 4i-bis. ★ "A real robot from a URDF, moving in 3D" — scoped and estimated

Asked directly, so answered with a survey rather than a guess. Two things checked first,
because the estimate hinges entirely on them.

### What already exists (checked, not assumed)

**3D rendering is NOT a blocker.** zimr already has `OrbitCamera`, `drawCube`, `drawSphere`,
`drawCylinder`, `drawLine3D`, `drawGrid` and their wireframe variants, plus
`examples/physics_sidebyside` to copy a camera setup from. A capsule is a cylinder and two
spheres. This was the biggest unknown and it costs roughly one turn, not five.

**There is no XML parser in the tree.** `src/plot.zig` and `tools/serve.zig` mention XML but
neither parses it. So one has to be written — a URDF subset, not a general parser.

### The finding that decides the scope

The KUKA iiwa URDF (a representative arm) contains **8 links, 7 revolute joints, 8
`<inertial>` blocks, 16 meshes and ZERO primitive collision shapes.** Real URDFs describe
collision with meshes, always.

**But a robot MOVING does not need collision at all.** The dynamics come from the inertials,
which URDF states explicitly and which §4i just landed support for. Links can be drawn as
capsules between joint origins — honest, legible, and no mesh loader. So:

* **Milestone 1 — a real URDF arm swinging and servoing in 3D. No meshes, no contact.**
* **Milestone 2 — meshes, so it can touch the floor.** STL loading, hulls (zimrphysics has
  `buildConvexHull`), and an asset-path convention zimr does not yet have.

> **✅ STEP 1 LANDED: `src/xml.zig`**, a small strict XML reader. 7 tests, lint 0.
>
> **Written after reading urdfdom** (the ROS reference implementation) rather than inventing
> conventions. The instructive part of urdfdom is not its parser — it delegates to tinyxml2 —
> but that most of its 2000 lines are then spent CHECKING that what tinyxml2 found means
> what it hoped. That is the cost of a permissive reader, and the failure mode is a robot
> that is silently the wrong shape.
>
> So this one is strict by design. No DTDs, no entity definitions, no namespace resolution;
> anything it cannot understand is an error **carrying a line and column**, and the semantic
> layer above can then trust its input. Duplicate attributes are an error rather than
> last-wins, because a file with `xyz` twice is a file whose author believed something
> untrue about it. An unknown `&...;` is an error rather than passthrough, since in a robot
> file it is far more likely an unresolved xacro than a literal.
>
> **Fast by shape rather than by tricks.** One pass, one arena, no per-node allocation.
> Elements and attributes live in flat arrays; children are a contiguous SPAN, so walking a
> tree is a slice iteration and not a pointer chase. Names and un-escaped values are slices
> into the source — nothing is copied — and the no-`&` path allocates nothing at all.
>
> **The one structural subtlety**, recorded because it is the thing a naive version gets
> wrong: children must end up contiguous, but a child's own subtree is parsed before the
> next sibling is known. Appending directly would interleave grandchildren between siblings.
> Each level therefore collects finished children on a stack and copies them in one block
> when the element closes — that copy is what buys the flat layout, and there is a test that
> would catch losing it.
>
> **Verified against the real thing.** `src/tests/fixtures/robot/kuka_iiwa.urdf` is checked
> in and parsed as a test: 8 links, 7 revolute joints, 8 inertials, 168 elements, with the
> joint topology and axes read out correctly. A file written by someone else for a different
> toolchain exercises what synthetic cases cannot.
>
> **★ REVIEWED AGAINST THREE OTHER IMPLEMENTATIONS** — `zig-xml` (a conformant W3C parser),
> `URDFLoader.js` (the three.js loader, the most-used one in the wild) and
> `tinyurdfparser` (a small C++ one over KDL). Four things came out of it, and one of them
> would have been a silent disaster.
>
> **★★ THE RPY CONVENTION, CONFIRMED FROM TWO INDEPENDENT SOURCES.** URDF orientations are
> given as `rpy="roll pitch yaw"`, and the composition order is the single most dangerous
> thing in the whole importer — get it wrong and every link is subtly rotated, which is
> exactly the "right shape, wrong pose" failure §4i-bis names as the estimate-killer.
> `URDFLoader.js` uses a three.js Euler with order `'ZYX'`; `tinyurdfparser` uses
> `KDL::Rotation::RPY(r, p, y)`. Both are:
>
>     R = Rz(yaw) · Ry(pitch) · Rx(roll)
>
> i.e. FIXED-axis roll about X, then pitch about Y, then yaw about Z, composing right to
> left. Two implementations from different ecosystems agreeing is the evidence worth having
> before writing a line of it.
>
> **`<mimic>` joints are fixed tendons.** `URDFLoader.js` handles a joint whose motion is
> `multiplier · other + offset`, and even detects cycles among them. Grippers use these
> constantly. **That is exactly `TendonSpec` with two coefficients** — phase 8 turns out to
> have already built the mechanism, and the importer just has to recognise the tag. A
> pleasing confirmation that the phase order tracked what real models need.
>
> **`package://` URI resolution.** Mesh paths are `package://robot_description/meshes/x.stl`,
> not filesystem paths. `URDFLoader.js` takes a resolver that can be a prefix string, a
> name→path map, or a function. Needed for Milestone 2; noted now so the asset convention is
> designed with it in mind rather than retrofitted.
>
> **What `zig-xml` does that we deliberately do not.** It interns strings into a byte pool
> with a hash map, making name comparison an integer compare — a real win on documents with
> deep repetition. Not adopted: robot files are a few hundred kilobytes, the zero-copy slice
> approach already allocates almost nothing, and interning would trade that for a hash map
> on every name. Recorded in the code as the thing to revisit if something starts feeding
> megabyte-scale documents. Its reader-based streaming is likewise the right call for its
> goals and the wrong one for ours — streaming forfeits "slices into the source".
>
> **The parser now lives in `codecs.zig`** as `pub const xml`, alongside `obj`, `gltf`, `png`
> and the rest. That is where format parsing belongs in this codebase, and a future reader
> looking for one will look there.
>
> **✅ STEP 2 LANDED: `src/urdf.zig`**, the semantic layer. 8 tests, lint 0. The real KUKA
> imports as an 8-body, 7-DOF chain with mass on every link.
>
> **The architecture, which is one pass and two thin backends:**
>
>     bytes -> codecs.xml -> urdf.parse -> urdf.Robot -> { emit Zig | build a Model }
>
> The hard part — tree construction, frame conversion, unit handling — happens ONCE and both
> consumers inherit it. A code generator and a runtime loader written as separate parsers
> would be two chances to get the conventions wrong and no way to test one against the other.
> `urdf.Robot` deliberately does not depend on `robot.zig`: it is a plain description in
> zimr's conventions, which keeps this file testable alone and the engine free of formats.
>
> **★ THREE CONVERSIONS, AND ALL THREE ARE PROVEN LOAD-BEARING** (each planted bug turns the
> suite red):
>
> 1. **RPY**, `R = Rz(yaw)·Ry(pitch)·Rx(roll)` — confirmed against two implementations
>    before writing it. Tested by what the rotation DOES to basis vectors rather than by
>    comparing quaternion components, since components can agree with a wrong convention
>    that happens to share a sign pattern. One case separates the orders: roll-then-yaw
>    applied to +Y gives +Z one way and −X the other.
> 2. **Z-up → Y-up turned out to be a ONE-LINE change**, which was the pleasant surprise. A
>    rigid rotation of the whole model leaves every body's pose RELATIVE TO ITS PARENT
>    unchanged — so only the root is rotated, and joint axes, inertia tensors and child
>    transforms all come along for free. §4i-bis budgeted this as a risk; the tree structure
>    did the work.
> 3. **The rotated inertial origin**, the gap §4i-bis identified. `I' = R·I·Rᵀ` applied here
>    means `robot.InertialSpec` never needs an orientation field — the engine's spec stays
>    minimal and the conversion lives with the other conversions.
>
> **And URDF's joint convention lines up with ours exactly.** URDF puts the parent→child
> transform on the JOINT; zimr puts it on the BODY; the joint anchor is then the child's own
> origin, which is already zimr's default. §4i-bis flagged this as the highest risk and it
> needed no algebra at all.
>
> **Refusals, all tested:** a forest instead of a tree, an unknown link, a cycle, a `planar`
> joint, a malformed tuple. Every one carries a diagnostic — a URDF that half-imports is
> worse than one that does not, because the failure shows up later as a machine that is
> subtly the wrong shape.
>
> `fixed` joints become a body with NO joint, which is what a weld IS in generalized
> coordinates rather than an approximation of one. `<mimic>` is recorded for the backend to
> emit as a tendon.
>
> **Revised estimate: 3–5 turns remaining** (emit + 3D example + device iteration), since 3D rendering turned out to exist and
> `codecs.zig` already has `obj` and `gltf` parsers to follow for meshes.

### Estimate for Milestone 1: **5–7 turns, call it 6**

| turns | item | risk |
|---|---|---|
| 1–1.5 | Minimal XML parser, URDF subset, with tests | low — bounded and testable |
| 1.5–2 | URDF → `robot.Spec` codegen | ★ **highest** — see below |
| 0.5–1 | Gaps the real KUKA turns up | unpredictable by definition |
| 1–1.5 | 3D example: orbit camera, capsule links, servos, HUD | low, rendering exists |
| ~1 | Device iteration | near-certain, going by this session |

**Where the risk actually is — the frame conventions, all in the codegen:**

1. **URDF puts the transform on the JOINT; we put it on the BODY.** A URDF joint carries an
   `<origin xyz rpy>` from parent link to child link, and the joint axis lives in the child
   frame. Ours has `BodySpec.pos/rot` and a joint axis in the body frame. The mapping is
   mechanical but easy to get subtly wrong, and wrong here means a robot that is the right
   shape in the wrong pose.
2. **Z-up → Y-up**, which §1.2 promised would live in the importer. It rotates positions,
   joint axes AND inertia tensors. `Inertia.rotated` exists and is tested, which helps.
3. **★ A REAL GAP: `<inertial><origin>` carries `rpy` as well as `xyz`.** `InertialSpec` has
   `pos` but no rotation — it assumes the stated tensor is already in the body frame. URDF
   models routinely rotate it. Either `InertialSpec` gains a rotation, or the importer
   pre-rotates with `Inertia.rotated` and emits the result. The second is better: it keeps
   the engine's spec minimal and puts the conversion where §4i says conversions belong.

**Milestone 2 adds 2–3 turns:** binary STL is easy (~100 lines), convex hulls exist, and the
awkward part is that zimr has no convention for a model that owns a directory of assets.

### The one thing that would blow the estimate

An importer that silently mis-parses produces a robot that is *subtly* the wrong shape — and
subtle wrongness in a 7-DOF arm is very hard to see. Mitigation, decided in advance: **import
the KUKA, then compare its forward kinematics against MuJoCo's** for the same joint angles,
the same way the oracle already pins everything else. MuJoCo can load URDF directly, so the
comparison costs one script and turns "looks about right" into a number.

---

## 4i-quater. ★ Codegen vs comptime vs runtime — the honest comparison

Asked directly whether the generator earns its complexity. It is a fair challenge and the
answer is more mixed than §4i-ter implied, so here it is properly.

### The three options

**A — CODEGEN (built).** A tool reads the URDF and writes a `robot.Spec(...)` literal that
is checked in.

**B — COMPTIME.** `@embedFile` the URDF and parse it during compilation:
`rbt.Spec(urdf.comptimeSpec(@embedFile("kuka.urdf")))`. One line, no tool, no build step, no
artifact that can go stale.

**C — RUNTIME.** Parse at startup and build a `Model` directly. `Model` is already an
ordinary runtime struct (§1.3), so this is roughly 150 lines mapping `urdf.Robot` onto it.

### B is not available, and this was measured

`codecs.xml.parse` takes an `Allocator`, and **Zig cannot evaluate an allocator at
comptime** — `FixedBufferAllocator` fails with "unable to evaluate comptime expression" on
the pointer arithmetic inside `rawAlloc`. So B is not "the same parser, called differently";
it needs a SECOND parser in a comptime-only style (`comptime var` plus `++` concatenation,
which is quadratic in the node count).

Two costs follow. A parallel implementation to keep in step with the first — exactly the
duplication §4i's architecture note argues against — and compile time proportional to file
size, on a `++` chain, for files that run to hundreds of kilobytes. B is elegant for a toy
and does not scale to a Menagerie humanoid.

### A vs C, without the thumb on the scale

**What A genuinely buys:**
* **Comptime name enums.** `Kuka.Joint.shoulder` is compile-checked. Real value when
  hand-writing a controller against a known robot; no value at all for a robot chosen at
  runtime, where you have indices anyway.
* **`Spec()`'s validation applies to the importer's output.** Not theoretical — it caught
  the `mass="0.0"` base as a compile error naming the body.
* No parser in the binary, no startup cost.

**What A costs:**
* A second code path (~250 lines) and a build step.
* A checked-in artifact that can drift from its source.
* **Cannot load a robot chosen at runtime**, which rules out an editor, a demo with a robot
  picker, or user-supplied files.

**Honest verdict:** for the current goal — get ONE known robot moving — A and C are close,
and **C is simpler.** A's advantages are real but narrow: they matter for a robot whose name
you write in source, and for §4d's batched rollouts of a fixed model. They do not matter for
loading a robot you were handed.

### What this means

**Not overengineering, but arguably built in the wrong order.** The XML reader and
`urdf.zig` are needed by all three options — that work stands whatever happens. Only
`emitZig` and the tool are specific to A, and §4i already called for "A first, C later"
without examining whether C was the better first step. It probably was: it is smaller and it
unblocks the same demo.

**Both should exist, and C is cheap** because `urdf.Robot` already carries the converted,
validated description. The right split is: **C for robots the program is handed, A for
robots the program is written against.** Neither is a rewrite of the other; they are two
thin backends on one semantic layer, which is why §4i's architecture put that layer in the
middle.

**Do not build a third.** B stays unbuilt permanently — it costs a duplicate parser to save
a build step.

### ✅ BOTH NOW EXIST, and the refactor removed duplication rather than adding it

`src/robot_urdf.zig` (2 tests) loads a URDF into a live `Model` at runtime.

**The key move was making `buildFromSpec` take a RUNTIME `ModelSpec`.** It was 358 lines
with only six `inline for` loops and five comptime name lookups — `ModelSpec` is plain data,
so nothing about building a model ever needed the spec at compile time. Dropping `comptime`
from the parameter, turning the loops into ordinary ones and the lookups into linear scans
was the whole change, and **there is still exactly one piece of code that turns a
description into index tables.** A second builder would have been the duplication §4i's
architecture warns about; this is the opposite.

`Spec()` keeps its compile-time validation and name enums by passing a comptime spec into
the same function. `buildRuntime` is the public door for everyone else.

**The property that makes two backends safe, asserted:** a test loads the KUKA both ways and
requires the models to agree — DOF counts, tree, masses, inertias, positions, and the
acceleration from the same state. Without it the paths would drift the moment one gained a
field the other missed, and the symptom would be a robot that behaves differently depending
on how it was loaded.

**On keeping the codegen — SETTLED: keep it.** The question was whether compile-checked
joint names justify a build step and a checked-in artifact. They do: writing a controller
against a specific robot is a first-class use, and `Kuka.Joint.lbr_iiwa_joint_4` being a
compile error when mistyped is worth more than the noise costs. `robot_3d` uses it.

The split stands as §4i-quater describes: **codegen for robots the program is written
against, runtime for robots it is handed.** Both end at the same builder and a test asserts
they agree.

---

## 4i-ter. The emitter — specified before it is written

`urdf.Robot` is done; this is the mapping onto `robot.ModelSpec`. Writing it down first is
the same discipline §4e used for phase 6, and for the same reason: the mapping is where the
remaining judgement calls are, and finding them in code review is more expensive than
finding them here.

> **✅ LANDED.** `urdf.emitZig` + `tools/urdf_import.zig` + `zig build urdf-import`. The
> real KUKA generates `src/tests/fixtures/robot/kuka_iiwa.zig` — 8 bodies, 7 joints — and
> **a test builds and simulates it**: nv 7, mass ~24 kg from the URDF's inertials, well
> conditioned, ten seconds of swinging without diverging.
>
> **★ THE PAYOFF FOR GENERATING SOURCE, made concrete.** Merely `@import`-ing the generated
> file runs `Spec()` over it — so every validation rule in the engine is applied to the
> importer's output AT COMPILE TIME. A convention regression becomes a build failure naming
> the body, not a wrong number nobody notices. The type system checks the importer's
> homework.
>
> **Three things only real data could have found:**
>
> 1. **A real URDF's fixed base declares `mass="0.0"`.** `lbr_iiwa_link_0` is bolted down
>    and states zero mass, and `Spec()` rejected that outright. It is legal on a body with
>    NO degrees of freedom — nothing accelerates it, so nothing divides by it — and fatal on
>    one with joints, which is the same rule as the geom check beside it. Relaxed
>    accordingly.
> 2. **`-0` does not compile.** A −90° rotation produces components of `-0.0`, `{d}` prints
>    `-0`, and Zig rejects it as an ambiguous integer literal. Normalising negative zero is
>    correct as well as convenient: the sign carries no information about a robot's geometry.
>    Whole numbers also need an explicit `.0`, or they are integer literals where a float is
>    wanted.
> 3. **The generated file must survive `zig fmt --check`.** A checked-in generated file is
>    subject to the formatting gate like any other, so the build step formats it — the same
>    arrangement `scripts/robot_oracle.py` uses for its fixtures.
>
> **Armature is added by the importer**, not read from the file: URDF describes the
> mechanism, not the gearbox. A real geared joint has rotor inertia, and without it a model
> with light distal links is badly conditioned — which surfaces as a solver that will not
> converge rather than as anything recognisable.
>
> **Geoms emitted alongside an `<inertial>` carry `.mass = 0`**, so the geom's
> density-derived mass cannot be added to the stated one. Belt and braces, since
> `InertialSpec` already replaces the geom-derived properties, but it documents the intent
> where a reader would wonder.

### The mapping, decision by decision

| URDF | zimr | note |
|---|---|---|
| `<link>` | `BodySpec` | one for one |
| joint `<origin>` | `BodySpec.pos/rot` | URDF puts the transform on the joint, we put it on the body — already converted by `urdf.zig` |
| `revolute` | `JointSpec{ .kind = .hinge, .range }` | |
| `continuous` | `JointSpec{ .kind = .hinge }`, no range | |
| `prismatic` | `.kind = .slide` with range | |
| `fixed` | **no joint at all** | a weld IS zero DOFs in generalized coordinates |
| `floating` | `.kind = .free` | |
| `<inertial>` | `InertialSpec` | rotation already folded in by `urdf.zig` |
| `<collision>` primitives | `GeomSpec` | box/cylinder/sphere map directly |
| `<collision>` mesh | **omitted, with a warning** | Milestone 2 |
| `<mimic>` | `TendonSpec` with coefficients `(1, −multiplier)` | phase 8 already built it |

### The three decisions that are not mechanical

**1. A link with an `<inertial>` but no collision geometry.** Common — URDF models often give
a link mass without a collision shape. `Spec()` currently rejects a body with joints and no
geoms as massless, but with an `InertialSpec` present that check should not fire. **Verify
that path**: §4i's inertial work added the `else if`, so it should already be right, but it
has no test with a jointed geom-less body.

**2. `<mimic>` offset.** A tendon expresses `q_follower = multiplier · q_driver` exactly, but
NOT the `+ offset` — a fixed tendon is linear, not affine. Options: fold the offset into the
follower joint's `ref`, or refuse a nonzero offset until a model needs it. **Refuse first**,
per §1.1's rule against pre-building escape hatches; almost every real mimic has offset 0.

**3. Where the generated file lives, and whether it is checked in.** Checked in, and
regenerated by a build step. A generated model that is a build artifact cannot be reviewed
in a diff, and a diff is exactly how a convention regression would be caught.

### What the emitter must NOT do

Silently drop anything. A mesh geom is skipped with a warning naming the link; anything else
unmapped is a hard error. The census in §4i exists so the set of things that can appear is
known, and §4i's scope warning applies here too — an importer that quietly ignores a tag
produces a robot that is subtly the wrong shape.

### How it gets verified

**Forward kinematics against MuJoCo**, as §4i-bis planned. MuJoCo loads URDF directly, so:
import the KUKA both ways, set the same joint angles, compare body world poses. That turns
"looks about right" into a number and reuses the oracle machinery that already exists.

---

## 4i-quinquies. ✅ MILESTONE 1 REACHED — a real robot, from a URDF, in 3D

`examples/robot_3d`: a KUKA LBR iiwa, seven axes, mass properties measured from the real
hardware, described in a file somebody else wrote for a different toolchain — simulated and
drawn in three dimensions with an orbit camera and four selectable poses.

**The estimate was 5–7 turns; it took 5.** What made it land at the low end was measuring
before guessing: 3D rendering already existed (`OrbitCamera`, `drawLine3D`, `drawSphere`,
`drawGrid`), and the two conversions budgeted as risks turned out to be one-liners — a rigid
tree rotation for Z-up→Y-up, and URDF's joint-origin convention lining up with ours exactly.

**★ THE CONTROLLER EXPLODED ON A DEVICE, and why is a property of robot arms rather than a
coding slip.** The first version was a plain joint-space PD with one gain pair for all seven
joints. Touching a pose button sent `joint_4` to −5,365,848 rad in a few frames.

**This arm's joint inertias span a factor of 300** — 3.43 kg·m² at the shoulder, 0.011 at
the wrist. A damping gain that is gentle on the shoulder is violent on the wrist. Explicit
integration needs roughly `kv·dt/M_ii < 2`; measured per joint, `kv = 30` at `dt = 1/240`
put the wrist at **11.4**. Uniform gains cannot work on a real arm, and that is exactly the
kind of thing a toy model built by hand never reveals — every test arm so far had links of
comparable size.

**The fix is the textbook answer: COMPUTED-TORQUE CONTROL.** Ask for an acceleration and let
the mass matrix convert it to torque:

    a* = kp·(q* − q) − kv·q̇          the motion wanted, in acceleration
    ★ τ  = M(q)·a* + c                 what it costs, given the real inertia

Substituting into `M q̈ + c = τ` gives `q̈ = a*` EXACTLY — the closed loop is a linear,
decoupled second-order system with the same response on every joint, in every configuration.
The 300× spread disappears because `M` is precisely the thing that accounts for it, and the
gains become physical: `kp = ω²`, `kv = 2ζω`. It costs one `mulM`, which exists because
inverse dynamics needed it, plus `bias_force` — the torque that merely holds the arm up.

**Verified headlessly BEFORE shipping this time**: all four pose transitions, peak velocity
3.4 rad/s, final error under 1.4°, no divergence. Two demos have now gone out broken because
I checked that they compiled rather than that they worked.

**The skeleton depiction is honest, not a shortcut.** The URDF's collision geometry is
entirely meshes, which the importer skips, so there is no shape to draw. Links as segments
between joint origins is exactly what is being simulated: eight inertias connected by seven
hinges. The mass is real even though the silhouette is not. Meshes are Milestone 2.

**A lint rule paid for itself:** `depth-format` caught that a 3D render needs a depth buffer
before `beginMode3D` could assert at runtime — on a device, in a standalone, where the
failure would have been a blank screen.

### ✅ MESHES — and they needed no parser work at all

The KUKA URDF names **`.obj` for visual and `.stl` for collision**, and `codecs.obj` has
parsed OBJ since long before robots existed. So the visual half cost one 40-line shim
rearranging the codec's CPU mesh into the renderer's C layout — not a parser.

890 KB across eight links, embedded like `damaged_helmet` embeds its 3.7 MB glb. The
standalone is 3.0 MB.

**★ THE MESH IS DECORATION; THE SKELETON IS THE TRUTH.** Each mesh is placed by its body's
SIMULATED pose — the engine produces a position and orientation per body and the shape hangs
off that frame, affecting nothing. The mass comes from the URDF's `<inertial>` blocks, and
the collision geometry (separate `.stl`) is not loaded. **A pretty robot that quietly implies
more physics than it has is a real hazard**, so `W` toggles the frames and the caption says
which one is real.

**✅ HULL COLLISION LANDED.** `GeomShape` gained a `.hull` arm carrying a POINT CLOUD, and
`robot_physics` turns it into a real collider via `shapes.addConvexHull`.

**The split of responsibility is the point.** `robot.zig` carries the points and has no hull
builder — nor should it, since it never asks whether two shapes touch. The physics engine,
which owns collision, builds the hull. That keeps §1.3's dependency rule intact: the
dynamics engine still depends only on zimrmath.

Mass properties for a hull come from its BOUNDING BOX rather than the true volume: an
overestimate, which is the safe direction (it never makes a link easier to spin than it is),
and irrelevant in practice because any model carrying hulls is an imported one that states
`<inertial>` explicitly. Exact hull inertia belongs with the hull builder.

A test drops an octahedron-hulled body onto a floor and requires it to make contact and come
to rest ON it — the end of the import path, from URDF mesh to reported contact.

**✅ `codecs.stl` LANDED** — binary and ASCII, 4 tests, with the real KUKA collision mesh
checked in as a fixture. Written after reading MuJoCo's `LoadSTL` declaration and the widely
used `stl_reader`.

**★ THE FORMAT DETECTION IS THE WHOLE PROBLEM, and everyone gets it wrong.** STL has two
encodings and no version field. The usual guess — "does the file start with `solid`?" — is
what `stl_reader` does, and its own documentation admits it "may fail, of course". It fails
often: the binary format opens with 80 bytes of FREE TEXT and plenty of exporters write
`solid <name>` there. Such a file is then parsed as ASCII, finds no `vertex` tokens, and
yields an EMPTY MESH — a failure that looks like a corrupt file rather than a misdetection.

Detection here is arithmetic instead: a binary STL is exactly `84 + 50·n` bytes where `n` is
the count at offset 80. A false positive needs a file whose size accidentally satisfies an
equation determined by its own contents. There is a test with a binary file whose header
starts with `solid`.

Confirmation the reader is right: the KUKA's `link_0.stl` is 151984 bytes = 84 + 50x3038,
and **3038 is exactly the triangle count of the matching `link_0.obj`** — two encodings of
the same shape, read by two different parsers, agreeing.

Vertices are deliberately NOT welded. STL repeats every shared corner, and the consumers
here are hull construction (which discards duplicates anyway) and point-cloud inertia (which
is unaffected); welding costs a spatial hash and buys neither anything.

**✅ `urdf.hullPoints` LANDED — the reduction that makes emitting hulls possible at all.**

**The problem, measured first:** a KUKA link's collision mesh is 3038 triangles = 9114
vertices (STL repeats every shared corner). Emitted verbatim that is **347 KB of Zig per
link, 2.7 MB for the arm**, to describe a shape whose hull has under a hundred corners.

**The idea:** every vertex of a convex hull is the FARTHEST point of the cloud in some
direction. Sample many directions, keep the extreme point in each, discard the rest. What
comes back is a SUBSET of the original points, so it can only under-approximate — no
direction invents a point the mesh does not contain.

| directions | points kept | generated size |
|---|---|---|
| 32 | 35 | 1 KB |
| **128** | **80** | **3 KB** (from 356 KB — a 100x reduction) |
| 256 | 108 | 4 KB |

**Two details that are not incidental:**

* **Fibonacci-sphere directions, not latitude/longitude.** Lat/long bands cluster at the
  poles: they would resolve the top of a shape finely and miss detail around its equator.
* **★ The six axes are sampled FIRST, explicitly.** A Fibonacci spiral spreads evenly but
  hits no axis exactly, so the extreme point along ±X/±Y/±Z can be missed by a fraction of a
  millimetre. That is not cosmetic — the kept points' bounding box becomes the geom's
  `bounds_half_extent`, which the inertia is computed from. Seeding the axes makes the AABB
  EXACT for six extra iterations, and a test asserts it matches the full mesh's to 1e-4.

**On a single hull per mesh, checked against the field.** A concave link becomes its convex
hull, which over-approximates the solid. That is NOT a shortcut relative to MuJoCo, whose
collision system is convex-only and treats a `<mesh>` geom as its hull too. `obj2mjcf` offers
CoACD decomposition into several hulls and offers it **opt-in, with a single hull as the
default**. Matching that default is parity; decomposition can follow if a model needs it.

**✅ THE IMPORTER WIRING LANDED — the chain is complete.**

    <collision><mesh filename="meshes/link_0.stl"/>
      -> resolve relative to the URDF  -> codecs.stl
      -> hullPoints (9114 -> 80)       -> .hull geom
      -> zimrphysics convex hull       -> a contact

`zig build urdf-import` now reports **"8 bodies, 7 joints, 8 collision hulls"**, and the
generated file is 54 KB rather than the 2.7 MB a raw cloud would have cost.

**The file I/O is the CALLER's.** `urdf.resolveMeshes` takes a callback and knows nothing
about paths, so `urdf.zig` stays testable without a disk and reusable from a build tool, a
game or a browser. The tool owns `package://` stripping and the base directory.

**An unreadable mesh is SKIPPED, not fatal** — mesh files are routinely distributed
separately from the URDF, and a robot with correct inertias and no collision geometry is a
useful thing that MuJoCo itself refuses to produce. The count comes back so the tool can say
so out loud; it named all seven missing files before they were fetched.

**★ A REAL SEMANTIC GAP THE VALIDATION CAUGHT.** `Spec()` rejected a geom with
`mass = 0` — but that is exactly what a COLLISION-ONLY geom is, and it is what an imported
robot needs: mass properties come from `<inertial>`, and a geom that also contributed would
count every link twice. Zero is now legal AND meaningful; negative is still an error (not a
shape that weighs nothing, a shape that weighs less than nothing); and zero WITHOUT an
`<inertial>` is rejected, since the body would then have no mass at all. Only an imported
model puts geoms and an explicit inertial on the same body, which is why nothing had reached
this path before.

**✅ MILESTONE 2 COMPLETE — the KUKA touches the world.** `robot_3d` now carries a floor and
a crate, and the arm knocks the crate across the floor with its own collision hulls.

Verified headlessly BEFORE shipping (the rule from §4f, after two demos went out broken):
**5 simultaneous contacts, 945 N peak load on the arm, crate displaced 0.60 m.**

Two poses were added for it — "wind up" holds the arm clear, "sweep" carries it across the
crate's position. Going from one to the other is a real arm swinging its own mass into an
obstacle, with the controller DISCOVERING the obstacle rather than being told about it.

**★ A LATENT BUG SURFACED, and only a real model could have.** The contact row key passed
`contact.id` (a u64 from the detector) into a `usize` parameter. No test had ever produced a
contact through the full imported-robot path, so it had never been instantiated. The id is
now narrowed explicitly to the 48 bits the key packing reserves.

**Two ordering constraints, both documented at their site** because both fail silently:

* **The bridge is built LAST in init**, after the arm's kinematics have run. It snapshots
  where each hull IS; built earlier every proxy is born at the origin and the first world
  step sees eight hulls scything across the scene from there.
* **Sync before the world step, harvest before the controller.** Sync late and the detector
  tests last frame's arm against this frame's crate; harvest late and the constraint rows
  are missing when the arm's own solver runs.

### The tower, and three findings from a device screenshot

`robot_3d` now stacks **five crates** rather than placing one — a single box slides, a stack
TOPPLES, and toppling exercises far more of both engines: the crates rest on each other
through zimrphysics' own solver while the arm meets only the one it strikes.

**★ 1. THE FIRST TOWER WAS NEVER HIT — peak force 0 N.** Placed by eye at radius 0.56, where
the arm's sweep passes at radius 0.70. Printing the wrist position across the sweep showed it
travels an ARC at y = 0.200; the tower moved onto that arc and the strike landed. **The same
lesson as the 2D contact demo**: a robot's reachable set is not something to eyeball — ask
the kinematics where the hand goes, then put the target there.

**★ 2. THE POSE COMMAND STEPPED INSTANTLY, and a computed-torque controller obliged.** Asked
to move a metre in one timestep it produced the speed of a swung bat and launched crates a
hundred metres. Real arms are commanded along a TRAJECTORY, not teleported to a setpoint, so
the commanded pose now slides toward the selected one at 1.4 rad/s — roughly what a real
industrial joint does.

**★ 3. §4h's ONE-WAY COUPLING SHOWED ITS TEETH, and no tuning fixed it.** One crate of five
still left at ~200 m. Sweeping at 0.6, 0.9 and 1.4 rad/s and tripling the crate density all
produced the same single escapee — because the cause is STRUCTURAL: the arm's proxies are
kinematic, so a crate pinched between an immovable arm and another crate has no legal resting
place and the resolver ejects it at whatever speed clears the overlap. An infinite mass ratio
has no correct answer for a pinch.

A speed cap keeps the scene watchable, commented at length as the workaround it is. **This is
the strongest argument yet for §4h's impulse handoff**, which would let the pinch LOAD the
arm instead of launching the crate — moving it up the list below.

**Also fixed: the UI did not eat input.** Dragging a checkbox also spun the camera, because
the camera read `wantCaptureMouse` before the UI had submitted its windows — it hit-tests
against THIS frame's windows, so it can only answer once they exist. The UI block now runs
first; `ui_host.render` is deferred, so the panel still draws on top.

---

## ★★★ THE ROAD TO A QUADRUPED — the next 20 turns

**The target, stated so every decision below can be checked against it: a quadruped robot
carrying a crate and walking across crates that move under its feet.** Reinforcement learning
for gait discovery comes after; nothing here should make that harder, and several things
below exist to make it easy.

Everything on this road is also the MuJoCo port finishing itself. A quadruped on shifting
ground exercises more of the engine at once than any test written so far: free bodies, many
simultaneous contacts, friction that has to actually hold, and a solver under real load.

---

### Phase A — the unified tree (turns 1–5)

§4k established the architecture and proved momentum conservation on the smallest case. This
builds it out.

| # | work | done when |
|---|---|---|
| ✅1 | **`Scene`** — `src/robot_scene.zig`, **5 tests, now MANY ROBOTS.** Two robots that must touch each other have to share one model, for the same reason a robot and a crate do — MuJoCo scenes work this way too. Robot 0 keeps its indices unshifted so a generated joint enum stays valid; later robots are name-prefixed, because `jointIndexByName` returns the FIRST match and a duplicated arm would otherwise have its actuators silently drive the wrong robot. Momentum is conserved across two robots AND a crate — a push propagating through a free body to a robot that never touched it. |
| ✅2 | **The bridge reports tree-vs-tree.** | **DONE.** `Event.other_body` carries the second tree index; `harvest` fills `body_a` from it. **★ The old code EXPLICITLY SKIPPED pairs with a tree body on both sides** — commented as "robot self-collision, which needs the two-body contact Jacobian rather than the against-the-world one". That Jacobian has existed since phase 6, and a scene's crates are now tree bodies, so the skip was silently dropping every arm-vs-crate contact. |
| ✅3 | **Delete the handoff.** | **DONE — 13.6 KB removed** (8.0 from `robot.zig`, 5.6 from `robot_physics.zig`). Gone: `applyReactions`, `bodyOfContact`, `ExternalInertia`, `externalInertia`, `externalAlongRow`, `Contact.external{,_com,_velocity,_acceleration}`, `constraint_reaction_fraction`, the external `Â` term and the external acceleration term. **`harvest` no longer takes the world** — it briefly needed one to look up how heavy the other side was, and in a unified tree the robot already knows. What crosses the boundary is now purely GEOMETRY. |
| ✅4 | **`robot_3d` converted.** | **DONE.** Crates are free-jointed bodies in the arm's own model, built through `Scene` from `kuka.spec`. zimrphysics keeps the floor and does all the DETECTION; it simulates none of the dynamics. `Scene` guarantees robot 0's indices, so `kuka.Model.Joint.*` still names the right joints. Resetting a crate is now writing `qpos` — the same operation as resetting a joint angle, with no separate rigid-body store to keep in step. **Needs a device check: heavier crates should visibly resist more.** |
| ✅5 | **Free-body stress.** | **PASSES — 5-crate tower stands 10 s, worst drift 18 mm** (soft-contact settling, not collapse). Getting there found TWO real engine bugs, below. |

**★★ TWO ENGINE BUGS THE UNIFIED TREE EXPOSED**, neither reachable before free bodies
existed and both silent:

**1. A free joint's `qpos0` ignored the body's declared pose.** For every other joint the
body's `pos`/`rot` is a fixed offset from the parent and the joint moves relative to it; a
free joint HAS no fixed offset — its seven coordinates ARE the pose. Leaving `qpos0` at zero
discarded wherever the model said the body was, so **five crates all appeared at the origin
on step zero, already interpenetrating**. Nothing warned: the model was valid, the simulation
stable, every body simply in the wrong place. MuJoCo seeds `qpos0` from `body_pos`/`body_quat`
for exactly this reason.

**2. Every proxy shared one collision group, so no tree body ever saw another.** zimrphysics
skips pairs sharing a nonzero `group_id`, and one group per model was a sound optimisation
while robot-vs-robot pairs were discarded anyway. With crates in the tree, crate-versus-crate
became the ordinary case. The symptom was precise and easy to misread: contacts WERE reported
and the crates DID rest on the floor — but every reported contact was crate-0-versus-floor,
so the tower sank into itself.

Now grouped by `body_root`, which keeps what the optimisation was for: one articulated chain
still does not self-collide (adjacent links overlap at every joint), while a free body is its
own root and collides with everything.

**And a testing lesson:** three momentum tests failed on fixing bug 1, because their velocity
thresholds had been tuned against the broken geometry — the crate permanently overlapping the
pusher. Momentum conservation itself was unaffected (0.0009%). **Tight numbers measured on a
wrong setup make the fix look like a regression.** The assertions now test the property.

**★ WHAT THE DELETION PROVES.** Every one of those fields was a hand-rolled reconstruction of
something the relative Jacobian does exactly: `J M⁻¹ Jᵀ` already contains both inertias,
`J·v` is already the relative velocity, `J·a` the relative acceleration. Four debugging
rounds went into making those reconstructions agree with each other. **The right fix deleted
them.**

That is the clearest signal available that §4k's review reached the right answer — the new
architecture is not a bigger machine that handles more cases, it is a smaller one that has
fewer cases to handle.

**Two decisions recorded at turn 1, both about what a free body is NOT:**

* **No armature.** Armature is a gearbox's rotor inertia reflected through a transmission,
  and a loose crate has neither. Adding it would make the crate resist by an amount
  corresponding to nothing, and would silently break momentum accounting — `m·v` would stop
  being the whole story. This exact mistake cost a debugging round: a momentum test read
  0.58% out and looked like a conservation failure when it was default armature.
* **The robot keeps its indices.** Free bodies follow the robot's own bodies, never
  interleave, because a generated model names its joints through an enum whose values ARE
  those indices. Asserted in a test rather than left to convention.

**Risk:** free bodies in the tree means `nv` grows and the mass matrix gains 6 DOFs per crate.
Sparsity should keep it cheap — a free body is its own root with no parent coupling — but that
is an assumption to MEASURE at turn 5, not to trust.

---

### ★ CONTACT QUALITY — measured at the end of Phase A, and it sets up Phase C

Crates that shiver in place after being knocked. Bisected rather than guessed:

| case | result |
|---|---|
| one crate dropped flat | **perfect** — 4 contacts, 1–2 iterations, \|v\| 1e-5, ids stable |
| one crate dropped TILTED | **perfect** — falls flat, tilt → 0, no residual spin |
| five settled crates, 20 s | no dropouts, \|v\| 1e-5 — **but 27 mean / 60 worst PGS iterations** |

**★ A REAL BUG FOUND ON THE WAY: contact ids did not include the BODY PAIR.** The id packed
sub-shape, feature and point index — unique within one pair and identical across pairs. Five
crates on the same floor produced the same sub-shape (0), the same box-vs-box feature ids and
the same point indices, so **all five numbered their contacts identically**.

`constraintKey` is exact rather than hashed precisely so a collision cannot happen, and its
own comment warned that one "would silently warm-start a row from an unrelated force — a
wrong answer that converges". That is exactly what happened. Fixed: the tree bodies are in
the id now, which is the right discriminator because they are stable across frames (a
zimrphysics body index need not be) and they are what the solver reasons about anyway.

**But that was not the convergence problem.** Instrumented afterwards: the warm start matches
**every row on every step** and is never rejected by the cost guard. So PGS is simply
converging slowly on 80 rows of a resting scene — chattering on friction rows at their
boundary, at velocities of 1e-5 where nothing is physically moving.

**★★ REPRODUCED, AND THE CAUSE WAS THE CONTACT MARGIN.** The per-crate readout settled it in
one screenshot: `tilt/contacts: 0.0/4  2.2/1  2.2/1  2.5/1` — boxes at 126–143° with ONE
contact each, which is impossible, plus `iters 60`.

Starting a crate in that pose reproduced it immediately: tilt swinging 2.2 → 1.57 → 2.6 → 0.9
forever, |ω| stuck at 1–2.7 rad/s, and — the tell — **`contacts 1` with `rows 0`**. The
contact was being reported and then discarded.

**The bridge never set `Contact.margin`, so it was zero.** zimrphysics reports every pair
within its speculative distance (2 cm), and the robot threw away all of them until the shapes
already overlapped. For a box resting flat that is harmless. For a box on a corner it is a
limit cycle: fall in, get a large corrective shove (60 iterations, the cap), separate, lose
the rows entirely, fall again.

| margin | flat drop | corner-balanced |
|---|---|---|
| 0 (was) | correct | **dances forever**, \|ω\| 1–2.7 |
| 0.004 | 4 mm high | **still dances**, \|ω\| 3.6 |
| **0.02** | 20 mm high | **falls flat and settles**, \|ω\| 0.006 |

**The remaining cost, stated plainly: a body settles one margin above the surface**, because
the constraint's equilibrium is where `distance == margin`. Correct-but-offset beats
stable-looking-but-dancing, so that is today's trade.

**And the proper fix is now specified.** MuJoCo splits the two jobs: `margin` decides
inclusion, `gap` (default 0) decides where force vanishes, and the IMPEDANCE RAMPS across the
band — from zero at `margin` to full at contact. That damps the approach without moving the
equilibrium. The naive half was tried (`violation = distance`, gap = 0 with no ramp): correct
resting height, and the limit cycle came straight back. **It is a feature to build, and it
belongs in Phase C turn 12 beside the Newton solver.**

**On why it would not reproduce headlessly:** nothing to do with dt or the machine — the
timestep is a fixed-step accumulator in both. My harness's crates SLID; a hand on a phone
swings the arm hard enough to FLIP them, and only the flipped pose exposes the bug. The fix
was to stop trying to guess the state and put the state in the readout.

**★ WARM STARTING TESTED DIRECTLY — Simon's hypothesis, and the answer is the opposite.**
A tilted crate dropped at 0.50, 0.70 and 0.785 rad (balanced exactly on an edge), each run
with `warm_start` on and off:

| | warm ON | warm OFF |
|---|---|---|
| worst iterations | **28–29** | **60 (the cap)** |
| residual \|ω\| | 1e-5 | 5e-5 |
| final tilt | 0.0000 — falls flat | 0.0000 — falls flat |

Warm starting HALVES the iterations and gives five times less residual motion. It is helping,
not causing. Worth having asked: it was the cheapest hypothesis to eliminate and it was
eliminated in one run.

**And the corner-rest does not reproduce headlessly at all.** Every case tried — one crate
flat, one crate tilted to the balance point, five crates settled, five crates swept by the
arm over 20 s — settles upright at 1 iteration with tilt under 0.01 rad. Whatever a device is
showing is not in the physics reachable from a headless harness, which means the next step is
to make it OBSERVABLE rather than to keep guessing.

**`robot_3d` now reports tilt and contact count PER CRATE.** The two numbers separate the two
possibilities that look identical in a screenshot: a box tilted ~0.79 rad with ONE contact is
impossible (a single point force cannot resist the gravity torque about that point, so it
must tip), while a box tilted with contacts against a NEIGHBOUR is an ordinary leaning pile
and correct physics.

**That is §4g's S5 (PGS only, no Newton), and it is now the top item for Phase C turn 12.**
It is also exactly the risk that section already names: *"a quadruped that will not stand
still is the hardest thing on this list, and it fails for solver reasons rather than
modelling ones."* Four feet on the ground will be 30–60 rows of precisely this. Better to
have measured it on five crates first.

## ★★★ WHY zimrphysics STACKS BOXES AND robot.zig DOES NOT

The margin did not fix it — with `margin = 0.02` a device reported a peak contact force of
**1,363,943,800 N**. 1.4 giganewtons, and the arm glitching. So the question became the right
one: *zimrphysics simulates box stacks perfectly well. What does it do that robot.zig does
not?*

Read its solver. The answer is not a parameter.

### The two engines solve different problems

| | zimrphysics | robot.zig |
|---|---|---|
| passes per step | **`velocity_steps: 10` then `position_steps: 2`** | one, over accelerations |
| what a contact produces | an **impulse** (`total_lambda`, accumulated and warm-started per point) | a **force**, from `aref` |
| how penetration is removed | **`solvePosition` MOVES THE BODIES** — `body_a.com_pos -= …` | folded into `aref = −B·vel − K·I·(pos − margin)` |

**★ That last row is the whole thing.** In zimrphysics, penetration never becomes a force: it
is corrected by TRANSLATING the bodies in a separate pass. Depth cannot blow up a force
because depth never produces one.

In robot.zig, penetration IS a force — `−K·I·violation`, applied over `dt`. A 2 cm overlap on
a soft contact with a stiff time constant asks for an enormous acceleration, and there is
nothing to bound it. **1.4 GN is that equation working exactly as written.**

### ★★★ SOLVED — `moveKinematic` STEERS, IT DOES NOT TELEPORT

After the ordering fix the corner case still would not settle, and the wide review found the
second half of the same mistake — this one inside the bridge.

    pub fn moveKinematic(world, gpa, idx, target_position, target_rotation, dt) {
        ...
        setLinearVelocity(..., delta_pos / dt);
        setAngularVelocity(..., quatGetAngularVelocity(delta_rot, dt));
    }

**It does not move the body. It sets a VELOCITY that will carry it to the target over `dt`.**
So during the collision detection that follows, the proxy is still at the PREVIOUS pose — the
detector reports contacts for where the robot was, not where it is.

For a body resting flat that lag is invisible, which is why every flat test passed for weeks.
For a box rocking on a corner it is fatal: the corner it is told about is last step's, so the
push lands in the wrong place and the box rocks instead of tipping.

**Steering was RIGHT while the bridge was a simulator** — a kinematic body needs a velocity
for its contacts with dynamic bodies to transfer momentum. §4k made the bridge a pure
DETECTOR: the crates it once pushed are tree bodies now and zimrphysics resolves nothing. So
the velocity buys nothing and the lag is pure cost. `setTransform` puts the proxy exactly
where the tree says it is.

| case | before | after |
|---|---|---|
| flat drop | 4 contacts, 60 iters, \|ω\| 1e-5 | 4 contacts, **2 iters**, \|ω\| **0.00000** |
| edge-balanced | 4 contacts, 60 iters | 4 contacts, **2 iters**, \|ω\| **0.00000** |
| **corner-balanced** | **dances forever**, \|ω\| 0.9–5.3 | **falls onto a face and stops dead**, \|ω\| **0.00000** |

**Iterations went from 60 (the cap) to 2.** The PGS convergence problem that looked like it
needed Newton was a symptom: the solver was being handed an inconsistent problem every step —
contacts for one pose, dynamics for another — and could not converge on something that did
not describe a single instant. Given a consistent problem it converges in two sweeps.

**★ THE LESSON, and it is the one this whole investigation is about.** Four things were tried
that were plausible, principled, and wrong: disabling warm starting, tuning the margin,
bounding the force, matching MuJoCo's impedance (already matched). Each was a hypothesis
about the SOLVER. The bug was in neither engine — it was in the seam, and specifically in a
function whose name (`moveKinematic`) describes what it does for the caller it was written
for, not what this caller now needed. **When a component is repurposed, re-read what it
actually does, not what it is called.**

### ★★ MUJOCO'S SOURCE READ LINE BY LINE — and almost everything already matches

Rather than reason about MuJoCo, read `engine_core_constraint.c`. Four things checked, and
the result was not what the previous section guessed:

| MuJoCo | ours | verdict |
|---|---|---|
| `aref = −B·vel − K·I·(pos − margin)` (`mj_referenceConstraint`) | identical | ✅ match |
| `getimpedance`: ramp `dmin→dmax` over `width`, two-piece power curve | identical, `Impedance.at` is a faithful port | ✅ match |
| defaults `solimp = [0.9, 0.95, 0.001, 0.5, 2]` | same five numbers | ✅ match |
| `R = max(MINVAL, (1−imp)·diagA/imp)` | same formula | ✅ match |

**Measured on a live corner contact: `R/Â = 0.0526`, against MuJoCo's `(1−0.95)/0.95 = 0.0526`.**
Identical to four digits. So the impedance ramp that the previous section proposed as fix "A"
was **already implemented and already correct** — a useful thing to have discovered before
spending a turn building it.

### ★ THE REAL DIFFERENCE FOUND: MuJoCo COLLIDES AT THE POSE IT SOLVES AT

`mj_forward` runs kinematics → collision → constraint → solve, all at the same `q`. The demo
loop did:

    sync proxies → step world → harvest → forward → control → step
                                          ^^^^^^^

`sync` steers the proxies from `body_xpos`, and `body_xpos` was last computed by the
PREVIOUS iteration's `forward` — i.e. before the previous integration. **A full step of
positional lag**: the collision detector was always testing where the bodies had been.

Reordered to `forward → sync → step world → harvest → control → step`:

| | old order | MuJoCo order |
|---|---|---|
| corner-balanced crate, residual \|ω\| | 5.29 | **0.90** |

**5.8x less residual motion**, from moving one line. For a body resting flat the lag is
invisible, which is why every flat test passed; for one balanced on a corner it is the
difference between a contact computed for the current pose and one computed for a pose the
body has already left.

**It is not the whole answer** — the corner case still does not fully settle (tilt 1.92,
\|ω\| 0.90, 60 iterations). What remains points squarely at the solver, since the
formulation, the parameters and now the ordering all match MuJoCo. **MuJoCo defaults to
NEWTON; we run PGS**, and 60 iterations at the cap on a scene this small is PGS failing to
converge, not physics disagreeing.

### Why MuJoCo does not have this problem despite also being acceleration-level

Worth stating, because it rules out "just copy zimrphysics" as the only answer. MuJoCo is
acceleration-level too and stacks boxes fine. It differs in three ways we do not yet match:

1. **`solimp` — the impedance RAMPS with distance**, from `dmin` to `dmax` across the
   constraint band, so the force grows smoothly rather than switching on at full stiffness.
2. **Newton by default**, not PGS. Our 60-iteration cap is PGS failing to converge on rows
   that Newton would close in a handful.
3. **Contact-relative tuning**: `solref` is expressed as a time constant and damping ratio
   that stay sane across mass ratios, rather than a raw stiffness.

### What this means for the plan

Phase C turn 12 was "friction that holds". It is now **the solver work**, and it has three
candidate paths, in increasing order of how much they change:

* **A. Impedance ramp (`solimp`).** Closest to MuJoCo, smallest change, keeps the
  architecture. Bounds the force by construction. **Try first.**
* **B. Bound the constraint force.** A cheap safety net — no contact should exert more than
  the momentum change it could physically cause in one step. Cheap enough to add regardless.
* **C. A position pass for FREE BODIES.** zimrphysics' answer, and available to us for free
  bodies specifically because a free body's `qpos` IS its pose, so it can be translated
  directly. Not available for articulated links — moving one would require IK — which is
  exactly why MuJoCo does not do it either.

**A and B together are the likely answer**, and C is worth knowing about because it explains
why the two engines diverge here at all: zimrphysics can move a body, and a generalized-
coordinate solver mostly cannot.

> **✅ B IS DONE.** `SolverOptions.max_force_scale` (default 100) bounds each row's force at a
> multiple of what it takes to arrest that row's constraint-space motion in one timestep. All
> 97 tests pass unchanged, which is the evidence that it never binds in a healthy contact —
> it is a floor under the failure, not a change to the physics. A simulation that limps beats
> one that produces giganewtons.
>
> **A is the next piece of real work**, and it is the one that actually fixes this.

### What was tried and did not work, so nobody repeats it

| attempt | result |
|---|---|
| disable warm starting | **worse** — 60 iterations vs 29, 5x the residual motion |
| `margin = 0.004` | still dances |
| `margin = 0.02` | corner settles in isolation, but **1.4 GN in the full scene** |
| `violation = distance` (gap = 0, no ramp) | correct rest height, limit cycle returns |

Reverted to `margin = 0` — the dancing is a visible artefact, the giganewton is a broken
simulation, and the first is the better failure to ship while the real fix is built.

---

### ✅ PHASE A COMPLETE — and what the whole detour was actually about

All five turns landed, and the contact quality that blocked them is resolved: **every case
settles at 1–2 solver iterations with |ω| = 0.00000**, where before it was 60 iterations (the
cap) and boxes danced on their corners indefinitely.

**The one-line summary of five sessions: the bug was never in a solver.** It was two
positional lags in the seam, each invisible for a body resting flat and each fatal for one
balanced on a corner:

1. **The demo collided before it did kinematics** — `sync` ran before `forward`, so proxies
   were steered from positions computed before the previous integration.
2. **`moveKinematic` steers rather than teleports** — it sets a velocity to REACH a pose over
   `dt`, so the detector saw the previous pose regardless.

Both are now fixed and MuJoCo's ordering is matched: kinematics, then collision, then solve,
all at one `q`.

**Four principled hypotheses were wrong along the way**, and the record matters more than the
answer: disable warm starting (it was helping — 29 iterations vs 60), tune the margin (0.004
still danced, 0.02 gave 1.4 GN), bound the force (a useful net, not a fix), match MuJoCo's
impedance ramp (already matched, to four digits — `R/Â = 0.0526`). Every one was a hypothesis
about the SOLVER, and the solver was fine. **A component that is repurposed must be re-read
for what it does, not what it is called.**

**Cleanup done in the same pass:** `sync` no longer takes `dt` (nothing steers), the contact
margin is a documented zero rather than a tuned constant, and the stale references to the
deleted handoff are gone.

### ★★ THE PAYOFF, MEASURED: A HEAVY CRATE BLOCKS A WEAK ARM

The question Phase A existed to make answerable. A torque-limited arm sweeping into a single
block sitting on its path:

| motors | crate | arm lag from commanded | crate moved |
|---|---|---|---|
| strong, 300 Nm | 1 kg | 0.0008 rad | **0.40 m** — brushed aside |
| strong, 300 Nm | 20 kg | 0.0000 rad | 0.002 m |
| strong, 300 Nm | 200 kg | 0.0000 rad | 0.000 m |
| **weak, 25 Nm** | 1 kg | 0.0000 rad | pushed away |
| **weak, 25 Nm** | **20 kg** | **2.16 rad — STALLED** | 0.096 m |
| **weak, 25 Nm** | **200 kg** | **2.29 rad — stalled harder** | 0.008 m |

**A weak arm is stopped by a heavy block, and stopped MORE by a heavier one.** A strong arm
pushes the same block aside without losing its pose. Both directions of the interaction are
now real.

Compare the same measurement under the old two-solver seam, recorded above: across a **666x**
mass range the arm's tracking error varied by under 1%, because each engine treated the other
side as immovable. That table and this one are the whole case for §4k in two screens.

**Note the torque limit is the thing that makes this visible.** Gravity compensation is
applied first and the TOTAL is then clamped — a weak motor cannot exceed its rating to win an
argument. Without a limit, computed torque will produce whatever force the mass matrix asks
for and no crate can ever block anything, which is a controller artefact rather than physics.

### ✅ AND IT IS NOW A SLIDER — the coupling made interactive

`robot_3d` carries two logarithmic sliders, **crate kg** (0.2–300) and **motor N·m** (3–300),
and they turn the tables above into something you can feel in one gesture: drag the mass up
and the arm stops being able to move the boxes; drag the motors up and it wins again.

**Live, with no rebuild.** `body_inertia` is read by `crb` every step to form the mass
matrix, so scaling it changes the physics from the next step — the crate genuinely becomes
heavier rather than being re-created heavier. Verified through exactly the demo's own path:

| crates | motors | arm lag | farthest crate |
|---|---|---|---|
| 0.8 kg | 25 N·m | 0.0000 rad | **606 m** ← tunnelling, see below |
| 10 kg | 25 N·m | **1.78 rad — blocked** | 0.72 m |
| 100 kg | 25 N·m | **2.33 rad — stuck fast** | 0.000 m |
| 100 kg | 300 N·m | 0.0000 rad | 0.000 m |

**Two design notes worth keeping.** The motor ceiling clamps the total AFTER gravity
compensation — clamping only the tracking term would let a weak arm treat its own weight as
free, which is not what a rating means. And the sliders edit base-10 EXPONENTS, because both
quantities span three decades and the interesting transition is narrow and central; a linear
slider spends most of its travel in a region where nothing further changes.

**And the 606 m is the tunnelling item below, now trivially reproducible**: set the crates
light, the motors strong, and sweep.

### ★ ONE OPEN ITEM CARRIED INTO PHASE C

Measured on the full scene after a hard sweep: **a crate reaches 128 m/s**. The solver
converges in one iteration and peak force is a sane 800 N, so this is not the old
force-explosion — it looks like a fast-moving proxy sweeping through a crate and the contact
being resolved once, hard. Tunnelling of exactly the kind speculative contacts exist to
prevent, and the margin is now zero.

**A second, smaller open item: a `-nan` crate position** in one configuration (1 kg block, 25
Nm motors) during a six-case sweep — and it does NOT reproduce when that case is run alone
for the same 15 s. So it is either sensitive to something the surrounding runs change, or the
detector, not the solver. Recorded rather than guessed at; a bug that appears in six-of-six
but not one-of-one is worth a proper hunt, not a patch.

**Tunnelling is turn 12's first job**, and it is now a well-posed question rather than a vague
instability: what does a contact do when the relative motion in one step exceeds the shapes'
size? MuJoCo's answer is that `margin` should be nonzero for fast contacts, which is a
different use of the same field from the one that failed above — there it was hiding a lag,
here it would be doing its actual job.

### Phase B — MJCF import (turns 6–9)

The good quadrupeds live in MuJoCo Menagerie, and Menagerie is MJCF. `codecs.xml` already
reads it; what is missing is the semantics.

| # | work | done when |
|---|---|---|
| ✅6 | **`<default>` class resolution** — `src/mjcf.zig`, 6 tests. | **DONE, against MuJoCo's own `humanoid.xml`** (21 nested `<default>` blocks) rather than a fixture. Verified against numbers a live MuJoCo 3.11.0 reports for the same file. |
| ✅7 | **`<worldbody>` tree** — `src/mjcf.zig`, 11 tests, 1110 lines. | **DONE.** `humanoid.xml` reads back with MuJoCo's own body count, parents, positions, joint types, class-inherited ranges (in degrees), and class-inherited geom types. |
| ✅8 | **Actuators and keyframes** — 13 tests total. | **DONE.** The humanoid's 21 actuators and 4 keyframes read back matching MuJoCo, including per-joint gear ratios and `ctrlrange` inherited from the root default. Sensors deferred: `humanoid.xml` has none, so there is nothing to verify against yet — §1.1's rule. |
| ✅9 | **Verify against MuJoCo** — `src/robot_mjcf.zig`, 2 tests. | **PASSES. All 16 humanoid bodies agree to 1e-4** on a deliberately asymmetric pose, against MuJoCo 3.11.0. |

**★ AND A LIVE ORACLE EXISTS — `mujoco` 3.11.0 is installed**, so every MJCF claim can be
checked against what MuJoCo actually builds rather than against a reading of the docs. Used
already: `geom_solimp[1] = [0.9, 0.99, 0.003, 0.5, 2.0]` and `geom_friction[1] = [0.7, 0.005,
0.0001]` for the humanoid both come from a class TWO levels up, so matching them is evidence
the flattening is right rather than merely self-consistent.

**Two decisions recorded at turn 6:**

* **Attributes are inherited as RAW STRINGS, parsed once at the end.** A class may set
  `size=".06"` for a geom whose `type` comes from its grandparent, and whether that size is a
  radius or a half-extent is unknowable until both are in hand. Resolving on strings also
  means an attribute this importer does not understand yet still INHERITS correctly rather
  than being silently dropped.
* **`Class` is flattened at parse time**, not walked at lookup. A nested class starts as a
  copy of its parent and overrides field by field — replacing the whole per-kind set would be
  the easy mistake, and would leave `humanoid.xml`'s feet with a size and no type.
* **Duplicate class names are rejected**, not last-wins, for the same reason duplicate URDF
  link names are (§4i): every `class="x"` in the file becomes ambiguous, and silently picking
  one produces a model wrong in a way nobody would check.

**★★ TURN 7 SO FAR: THE TWO THINGS THAT SILENTLY BEND A ROBOT.**

**Orientation has FIVE spellings and real models use four.** Counted across MuJoCo's own model
directory: `euler` 184 times, `zaxis` 37, `xyaxes` 15, `quat` 4. A reader handling only `quat`
— the one a programmer would design for — mis-orients almost every real element, and a missing
orientation attribute is indistinguishable from an identity one, so nothing complains.

Each is now pinned to a quaternion **MuJoCo itself produced** (one `from_xml_string` per row,
not derived from what it ought to be):

| spelling | MuJoCo's quaternion (w x y z) |
|---|---|
| `euler="30 0 0"` | 0.965926, 0.258819, 0, 0 |
| `euler="10 20 30"` | 0.943714, 0.127679, 0.144878, 0.268536 |
| `axisangle="0 1 0 45"` | 0.92388, 0, 0.382683, 0 |
| `zaxis="1 0 0"` | 0.707107, 0, 0.707107, 0 |
| `xyaxes="0 1 0 -1 0 0"` | 0.707107, 0, 0, 0.707107 |
| `quat=".7071 0 .7071 0"` | 0.707107, 0, 0.707107, 0 |

Three traps inside that: **MuJoCo's quaternion is W FIRST** where zm's is w last (reversing it
gives a rotation that looks almost right, which is the worst kind of wrong); `axisangle`'s
AXIS is never unit-converted while its angle always is; and `xyaxes` must be
re-orthogonalised, because files state the second axis approximately and a matrix with
non-orthogonal columns is not a rotation.

**★ AND MJCF DEFAULTS TO DEGREES.** URDF is radians and always radians. `humanoid.xml` says
`range="-30 10"` on class `hip_x`, and MuJoCo's built model reports `[-0.5236, 0.1745]`. A
reader assuming radians gives that joint **57x** its intended range — which does not fail; it
produces a knee that bends backwards.

**★★ AND TWO MORE THINGS THAT SILENTLY EMPTY A MODEL, both found by reading the real file
rather than the spec:**

**`childclass` reaches every DESCENDANT.** `humanoid.xml` opens
`<body name="torso" childclass="body">` and then states almost nothing on its geoms for the
rest of the file — all of them inherit through that one attribute. Treating it as applying to
the body that states it gives every geom below no type and no size.

**`fromto` replaces position, orientation AND half-length at once**, and it is how real
models are written: 14 uses against 12 plain `size`s in the humanoid. Two endpoints of a
capsule's axis — centre is their midpoint, rotation takes +Z along the segment, half-length is
half its length. Ignore it and the geom becomes a zero-length capsule at the body origin:
present in the model, invisible in the world, contributing no collision.

**One asymmetry worth stating:** a hinge's `range` converts from degrees, a SLIDE's does not —
it is in metres. Running a slider's range through the angle conversion shrinks it by 57, the
same trap as the degrees default but pointing the other way.

**★★ TURN 8: THE REASON MJCF IS WORTH READING AT ALL.** URDF says a knee exists and how it
bends. MJCF says what DRIVES it.

**Gear is a transmission ratio, not a limit** — and it varies six-fold across one robot:
`abdomen_z` 40, `knee_right` 80, `hip_y_right` 120, `ankle_y_right` 20, with `ctrlrange` a
flat ±1 everywhere. Ignore `gear` and every joint produces 1 N·m, which is indistinguishable
from a robot with no actuators, because it simply collapses.

**Four named keyframes** — `squat`, `stand_on_left_leg`, `prone`, `supine` — each 28 numbers
matching `nq`, with `squat` putting the torso at z = 0.596. **This is what makes a legged
robot testable at all**: dropped at its zero pose a humanoid is a tangle of straight limbs
that falls before a controller can act, and Menagerie quadrupeds almost always ship a `home`
key for exactly this reason. Phase C turn 11 ("it STANDS") depends on having one.

**And actuator defaults do not leak between kinds.** A `<motor>` default block must not
configure a `<position>` servo: they are different transmissions that give the same attribute
names different meanings — `kp` is a gain on a servo and nothing on a motor. Pinned by a test,
because sharing a default set would silently hand one the other's numbers.

**Fallback if MJCF proves deep:** a URDF quadruped (ANYmal, Go1 and Spot all have URDF
distributions) reaches the same milestone through the path already built. Take it if turn 7
is not clearly landing — the goal is a walking robot, not a format.

---

### ✅ PHASE B COMPLETE — MJCF imports, and FK agrees with MuJoCo

`src/mjcf.zig` (13 tests) reads; `src/robot_mjcf.zig` (2 tests) converts. The gate:

**Every one of the humanoid's 16 bodies within 1e-4 of MuJoCo's own forward kinematics**, on a
pose chosen to be ASYMMETRIC — every hinge at `0.15 + 0.05·j` — so no left/right symmetry can
mask a sign error and no joint sits at zero where a wrong axis would go unnoticed.

That single test exercises everything Phase B built at once: default resolution through nested
classes, `childclass` inheritance, all five orientation spellings, the degrees conversion,
`fromto` capsules, and the tree walk. Against a reference that cannot be argued with.

**Three conversion decisions worth carrying forward:**

* **No axis conversion in this path.** URDF rotates Z-up to Y-up at the root; MJCF import does
  NOT, because the acceptance test is fidelity to MuJoCo and a frame conversion in the middle
  turns any disagreement into two candidate explanations instead of one. A caller wanting
  Y-up applies the same one-line root rotation.
* **An unrepresentable geom is skipped, not fatal** — and returns `null` rather than an error,
  because it is not a failure. Real models are full of visual-only geometry, decorative
  meshes and a ground plane that belongs to the world. An error type would invite a caller to
  `try` it and refuse the whole robot over a decoration.
* **A keyframe of the wrong length is refused, not truncated.** Loading a pose written for a
  different model is a plausible mistake, and quietly taking its first `nq` numbers gives a
  robot bent into a shape nobody chose, with nothing to indicate why.

**Deferred honestly:** sensors (`humanoid.xml` has none, so nothing to verify against), meshes
(the `<asset>` block is unread), and per-geom friction (MJCF states it per geom, the engine
takes it per CONTACT — a real mismatch that needs a decision, not a silent default).

### ★★★ AND A REAL QUADRUPED IMPORTS — Unitree Go1, FK against MuJoCo

Menagerie fetched, and `unitree_go1/go1.xml` is checked in as a fixture: **13 bodies, 12
actuators, nq=19, nv=18, 104 uses of `class`/`<default>`, 70 geoms, and a `home` keyframe.**
Written by the manufacturer's integrators rather than the engine's authors, so it exercises
the format the way the target models do.

**All 13 bodies agree with MuJoCo's forward kinematics to 1e-4**, from `home` plus the same
asymmetric hinge sweep used on the humanoid.

**★ TWO BUGS THE GO1 CAUGHT THAT THE HUMANOID COULD NOT**, both because a quadruped is
symmetric and the test pose was not — a symmetric pose would have agreed to 1e-4 while being
wrong:

**1. ~~`buildRuntime` does NOT preserve the file's body order.~~ — WRONG, corrected in the
review below.** `buildFromSpec` assigns `bi = spec_index + 1`; there is no reordering. The Go1
appeared mirrored because of bug 2, and a pose-matching mechanism was built to work around a
cause that had already been found. It has been deleted. **`build` still returns an `Imported`
carrying names**, because the model genuinely has none — but the mapping inside it is now the
identity it always was.

**2. A keyframe's free-joint quaternion is W-FIRST.** `qpos` is raw, and MuJoCo lays a free
joint out as `(x, y, z, W, x, y, z)`. Copied verbatim, the Go1's upright `home` quaternion
`(1, 0, 0, 0)` becomes `(x=1, y=0, z=0, w=0)` — a half-turn about X. The result is a mirrored
quadruped that stands perfectly well and walks backwards. Same trap as the `quat` attribute,
one level deeper, and `<compiler>`-independent because a keyframe is never in degrees.

### Phase C — it stands, then it walks (turns 10–15)

| # | work | done when |
|---|---|---|
| ✅10 | **Contact cost at scale, measured — and a 2.3x speedup found.** | Go1 standing: **10,292 ns/step against MuJoCo's 20,209 — 2.0x FASTER**, after the stall check below. Getting an honest number took three attempts. |
| ✅11 | **It STANDS.** | **PASSES — a real Unitree Go1, 30 s at 500 Hz.** Trunk settles at 0.2828 against a 0.2700 home (1.3 cm), max \|v\| **0.0087 m/s**, four feet down. Now a test in the suite. |
| 🔄12 | **Contact quality.** The unsatisfiable-row bug is fixed and nothing is lost through the floor; peaks of 10–50 m/s on a hard sweep remain. THEN friction: a standing robot must not slide, a pushed one must. | nothing ejected above 5 m/s; a foot on a 20° slope holds at mu=0.8 and slips at mu=0.2 |
| 13 | **A scripted trot.** Not learned — a hand-written gait, because a controller that works is the thing RL later replaces. | the robot moves 1 m without falling |
| 14 | **Walking on flat ground, measured.** | 10 m, no falls, feet do not skate |
| 15 | **★ THE TARGET: walking on moving crates**, and carrying one. | crosses 5 loose crates; a carried crate stays carried |

**★★★ TURN 11 PASSED — AND THE TWO FAILURES BEFORE IT WERE BOTH CONTROLLER MISTAKES, NOT
SOLVER ONES.** Worth recording because the plan predicted the opposite ("it fails for solver
reasons rather than modelling ones") and the prediction was wrong:

**1. Gravity compensation on the free joint makes the robot FLY.** `bias_force` covers every
DOF including the trunk's six; adding all of it cancels the machine's own weight and it rises
at a steady 2.4 m/s. A trunk has no motor, so it must feel its weight. **This is the third
time the same rule has bitten** — the crates in Phase A, the arm's controller in the demo, and
now a quadruped. It is now stated once and clearly: *gravity compensation is something a MOTOR
does, and only actuated DOFs have one.*

**2. Computed torque cannot command a floating base.** `τ = M·a*` solves for accelerations the
trunk has no way to produce; zeroing those rows afterwards leaves the legs making up a
difference they were never asked for. The robot folded to a third of its height — 0.08 m
against 0.27 — which looks exactly like a tuning problem and is not one. Plain PD in torque
space, clamped to each joint's rating, is what the manufacturer's `<position kp="100"
forcerange="-35.55 35.55">` actually describes.

**And the solver was fine throughout.** Once the controller was right it stood on the first
try, with 8 contacts and no drift. The contact work in Phase A — the two positional lags — is
what bought that.

**One more convention worth stating: MJCF IS Z-UP**, so the world's gravity must be too.
Handing a Z-up robot Y-up gravity gives a machine that falls sideways, which also looks like a
controller problem.

**✅ AND IT IS A DEMO YOU CAN PUSH OVER.** `examples/quadruped/` — the Go1 standing, with
**kp** and **kv** on sliders and a **shove** button. Drag kp down and the legs fold under the
robot's weight; drag it up and it goes rigid. The default is the manufacturer's own `kp = 100`,
straight out of `<position kp="100" forcerange="-35.55 35.55">` in `go1.xml`.

**What is drawn are the COLLISION geoms, not the visual meshes** — the Go1's 13 `<mesh>` geoms
are skipped because their vertices live in an unread `<asset>` block. That turns out to be the
better picture for a physics demo: what you see IS what the solver sees, so a foot that looks
like it is touching the ground is touching the ground. Contact points are drawn too.

**The Z-up conversion happens at DRAW TIME, once.** The simulation stays in MJCF's own frame,
where its numbers are checkable against MuJoCo; only the camera's world is Y-up.

**★ THE ORDER OF PHASE C CHANGED, and the reason is worth keeping.** Turn 10 was "profile
contact cost before trying to stand", on the theory that a quadruped would need the headroom.
It did not: **the Go1 stood on the first try once the controller was right**, at 8 contacts,
with no profiling done. Measuring before there is a thing to measure is how a plan spends a
turn on reassurance. The profiling moved to Phase D, next to the benchmark it belongs with.

**Risk, and it is the real one:** a quadruped that will not stand still is the hardest thing
on this list, and it fails for solver reasons rather than modelling ones — contact softness,
friction anisotropy, and the warm start all show up here first. Turn 11 is the gate; if it is
shaky, turns 12–15 are guesswork.

---

### ★★★ INTERACTION — a standing requirement, not a demo garnish

**A simulation you cannot poke is a simulation you cannot judge.** Every real bug in this
project was found by someone interacting with a scene and seeing something wrong: crates that
danced on their corners, an arm that swept through a tower, a quadruped that flew. Headless
tests confirmed each fix afterwards; not one of them found the problem first.

So interaction is a plan item with its own acceptance criteria, applied to every demo from
here on:

| form | what it tests that nothing else does | status |
|---|---|---|
| **throw a projectile** | impact response at a chosen point and speed, and whether the controller recovers | ✅ `quadruped` — a pool of 6 balls, aimed from the camera |
| **shove the body** | recovery from a velocity impulse with no contact transient | ✅ `quadruped` |
| **drag a body with the mouse** | sustained force at an arbitrary point; reveals joint limits and stiction that an impulse passes straight through | ☐ |
| **change mass / gains live** | whether the coupling is real — the property Phase A existed for | ✅ `robot_3d` (crate kg, motor N·m), `quadruped` (kp, kv) |
| **place obstacles** | walking over things, which is the Phase C target | ☐ turn 15 |
| **grab and hold** | the carrying half of "carrying a crate and walking" | ☐ turn 15 |

**Two design rules that came out of building the first two:**

* **A projectile must be a body in the ROBOT'S TREE**, not a zimrphysics body. Otherwise the
  impact is resolved by a different solver treating the robot as immovable — the exact
  approximation §4k removed, and it would make a thrown ball bounce off a wall rather than
  push a robot. `robot_mjcf.buildScene` exists for this.
* **A fixed pool, parked below the floor and recycled**, rather than spawning on demand. A
  tree cannot gain a body without being rebuilt, and rebuilding mid-throw discards the
  robot's state. Parked balls cost six DOFs each and contribute no contacts.

**Measured**: a 0.6 kg ball at 6 m/s moves the Go1's trunk 7 cm and bounces away, and the
robot stays standing at 0.2828 m. Both halves of that are the point — it is pushed, and it
recovers.

### 🔄 TURN 12 — "TUNNELLING" IS THE WRONG NAME FOR IT

The open item said crates get ejected because they move too fast for one step. **Measured, and
that is not what happens.** Varying the sweep:

| sweep rate | torque | peak crate speed | lost through the floor |
|---|---|---|---|
| 1.4 rad/s | 300 N·m | 88.06 m/s | 4 |
| 4.0 rad/s | 1000 N·m | 89.33 m/s | 4 |
| **10.0 rad/s** | **3000 N·m** | **17.85 m/s** | **0** |

**The SLOW sweep is worse.** Seven times the speed and ten times the torque produce a fifth
of the ejection, which is backwards for anything caused by motion outrunning the detector.

**The real cause, from the first step where a crate exceeded 5 m/s: `deepest overlap =
−0.25175 m` on a crate 0.11 m across** — buried more than twice its own size. The reference
acceleration `−K·I·violation` grows LINEARLY with overlap and nothing bounds it, so that
contact asked for 250x what a 1 mm one does.

**★ THE FIX SO FAR: penetration recovery is bounded**, which every solver does somehow because
unbounded recovery is a spring with no travel limit. `SolverOptions.max_recovery_velocity`
(2 m/s) caps how much separation one step may demand — a deeply overlapped contact then
unwinds over several steps instead of firing apart in one.

    1.4 rad/s:  88.06 m/s, 4 lost  ->  35.62 m/s, 0 lost

**Scoped to CONTACTS only.** Applied to every row it broke two existing tests immediately: a
joint limit's violation is an ANGLE and a slider's is a length, so a metres-per-second cap is a
category error there. Contacts are the rows whose violation can be made arbitrarily deep by
geometry arriving late, so they are the rows that need it.

**★★ THEN THE BISECTION, AND IT OVERTURNED THE DIAGNOSIS TWICE.**

By crate count, everything else held fixed:

| crates | peak crate speed | deepest overlap |
|---|---|---|
| 1 | 0.04 m/s | −0.071 |
| **2** | **89.88 m/s** | **−0.551** |
| 3 | 10.47 m/s | −0.071 |
| 5 | 89.33 m/s | −0.574 |

**TWO crates fails and THREE does not** — non-monotonic, so it is a particular configuration
rather than a matter of scale, and two crates is the smallest failing case worth working on.

A 0.55 m overlap cannot be crate-versus-crate: they are 0.11 m across. It is the size of the
FLOOR SLAB, and varying that confirmed it moved with thickness:

| floor thickness | peak crate | deepest overlap |
|---|---|---|
| 1.0 m | 89.88 m/s | −0.551 |
| 0.1 m | 10.99 m/s | −0.029 |
| 0.02 m | 8.28 m/s | −0.068 |

**★ WHICH LOOKED LIKE THE ANSWER AND IS NOT.** Clamping reported depth to 0.2 m — defensible
on its own, since a manifold claiming an 11 cm body is half a metre inside something has lost
track of which way is out — produced **bit-identical results**. Identical peaks across a
chaotic simulation means the clamp never fired at the moment that matters.

So cause and effect were the wrong way round: **a crate is ejected at 90 m/s first, and buries
itself in the slab afterwards.** The deep overlap is the wreckage, not the collision. Thinner
floors score better only because an ejected crate passes through and leaves, rather than
rattling inside a metre of static geometry.

**What is genuinely established, and it is the useful part:**

* it is NOT speed — a seven-times-faster sweep ejects a fifth as hard, so CCD would have been
  the wrong build;
* it is NOT the reported depth — clamping it changes nothing;
* it IS configuration-specific — two crates fail where three do not;
* `max_recovery_velocity` helps the slow case genuinely (88 → 35.6 m/s, 4 lost → 0) and is
  worth keeping on its own merits.

**★★★ AND THEN IT WAS FOUND: A CONTACT THE SOLVER COULD NEVER SATISFY.**

The two-crate case blows up at **step 40** — during wind-up, two hundred steps before the
sweep. Two crates with NO robot are perfectly fine (0.29 m/s, 1.8 mm overlap), so the arm was
always the story. Dumping every contact at the starting pose:

    a= 0  b= 1  distance  -0.07084 m      <-- the world, versus the KUKA's BASE LINK
    a= 0  b= 9  distance  -0.00000 m
    ...

**The robot's base sits 7 cm inside the floor, permanently, from step zero.** The base link is
welded to the world — no joint, no degree of freedom — so nothing can ever change that
distance. It looks completely correct because the base cannot move.

But it produced four rows every step carrying an unfixable 7 cm violation, and they consumed
the solver's whole iteration budget. **The damage landed on the rows that mattered.**

| | before | after clearing the floor from the base |
|---|---|---|
| 2 crates | 89.88 m/s, 1 lost | **1.34 m/s, 0 lost** |
| 5 crates | 89.33 m/s, 4 lost | **21.07 m/s, 0 lost** |

**★ FIXED IN THE ENGINE, NOT THE SCENE.** The scene was wrong and it should not have mattered:
a contact whose relative motion no coordinate can affect is not something a solver can satisfy
OR violate — feeding it one asks for an answer to a question with no variables. `Bridge` now
precomputes which tree bodies are welded to the world and drops pairs where both sides are,
which costs one bool per body and nothing per step.

    2 crates,  4.0 rad/s ->  51.14 m/s, 0 lost
    5 crates,  1.4 rad/s ->  11.82 m/s, 0 lost
    5 crates,  4.0 rad/s ->  14.18 m/s, 0 lost
    5 crates, 10.0 rad/s ->  22.37 m/s, 0 lost

**Nothing is lost through the floor in any configuration now**, and the 90 m/s ejections are
gone. Peaks of 10–50 m/s remain on a hard sweep and are a separate, smaller question.

**★ THE LESSON, AND IT IS NOT ABOUT CONTACTS.** Three plausible causes were measured and
eliminated — speed, reported depth, floor thickness — and the actual one was a row that had
been there since step zero of every run, in plain sight, doing nothing visible. **A constraint
that cannot be satisfied is not inert; it consumes the budget that the satisfiable ones
needed.** Worth looking for wherever a solver mysteriously fails to converge.

**The next session starts from two crates**, and should find where the first large impulse
comes from before touching anything else. Three hypotheses have now been eliminated by
measurement rather than argument, which is the part that carries forward.

**★ AND A LESSON THAT REVERSES ONE ALREADY IN §4f.** The old note read *"a thin static shape is
a hole for anything moving fast; floors should be thick."* True when zimrphysics simulated the
crates. With the robot's solver owning contact it is **backwards**: a thick floor is a metre of
geometry a stray body can get lost inside. Both are real and belong to different
architectures, which is exactly why the depth clamp stays — so neither has to be remembered by
whoever writes the next scene.

### 🔍 REVIEW PASS — bugs found by reading, not by running

Three found so far, and all three share a shape: **code that produces a plausible answer where
it should produce none.**

**1. A stale comment concealing a wrong behaviour.** `robot_mjcf` still described a
pose-matching algorithm that had been deleted, and the check it justified raised
`AmbiguousBodyMapping` for what is really just an UNNAMED body. MJCF does not require `name`
and real files leave structural bodies anonymous; refusing the robot over one is the same
mistake as refusing it for a decorative mesh. The whole `Error` set collapsed back to
`Allocator.Error` — it was that one dead variant.

**2. `bodyIndex("")` returned the WORLD.** `names[0]` is the world's entry and it is `""`, as is
every anonymous body's. A caller passing an empty string through — a missing attribute, a
lookup that already failed — got body 0 and would read the world's pose as a robot part.
Plausible answer, no error anywhere. Now explicitly refused, with a test.

**3. An inherited `mesh` overrode an explicit `type`.** `readGeom` applied the two in sequence
and let `mesh` win unconditionally. A collision capsule inside a class whose visuals are meshes
became a mesh — and since the converter cannot build meshes, it was then SKIPPED. The result
is a robot that imports cleanly, keeps every body, joint and name, and quietly loses the
geometry that made it solid. **A robot that imports and falls through the floor is worse than
one that refuses to import.** Fixed to MJCF's actual rule: `type` is authoritative, `mesh`
implies the type only when nothing else stated one. The Go1 does not trigger it (42 collision
geoms before and after), so this is protective rather than corrective — which is the right
time to fix such a thing.

**4. Five allocations in a struct literal, with no `errdefer` possible.** `Bridge.init` made
five `try gpa.alloc` calls inside a `Bridge{...}` literal, then two more fallible calls
(`addShape`, `createBody`) after it. A struct literal has nowhere to put an `errdefer`, so a
failure at the third allocation leaked the first two, and a failure in `createBody` leaked all
five. Now allocated one at a time, each with its own `errdefer`.

**★ AND THE ERROR PATH IS NOW TESTED, which is the only way to know.** `FailingAllocator`
walks the failure point outward — one run per allocation index — over `testing.allocator`,
which reports any block left unfreed. The loop must terminate by SUCCEEDING rather than by
exhausting its range, or the test would pass while proving nothing about the happy path. This
class of bug is invisible otherwise: the only trigger is OOM, and no ordinary test goes near
it.

**5. ★★ EVERY CAPSULE WAS ROTATED 90°.** `GeomShape` says it in its own doc comment —
*"Segment along local Y plus a radius — zimr's capsule convention, not MuJoCo's"* — and the
converter copied the numbers across without rotating. MJCF's capsules and cylinders run along
local **Z**; the engine's run along **Y**. All 24 of the Go1's capsules were crossways to the
limbs they belong to.

**6. ★★ AND EVERY FOOT WAS 21 cm ABOVE THE ANKLE.** `readGeom` read `pos` and the orientation
STRAIGHT FROM THE ELEMENT, bypassing the default resolution every other attribute goes
through. The Go1 states its feet as

    <default class="foot">
      <geom type="sphere" size="0.023" pos="0 0 -0.213" .../>
    </default>

so the offset lives in the class and was dropped: each foot collapsed onto its calf's origin.
**The robot was standing on its shins**, which looks exactly like a robot standing.

**Neither was caught by anything.** FK agrees to 1e-4 with both bugs present, because FK is
about BODY poses and geoms do not enter it. The standing gate passed because a shin is as good
as a foot for holding a robot up. It took measuring the lowest collision point per geom —
`foot: −0.0178, shin: +0.0033` after the fix, the other way round before — to see it.

**What this cost the test suite, stated plainly:** the standing gate's `0.27 ± 0.03` was
calibrated against the buggy geometry, so it now asserts a RANGE — that the robot is on its
legs rather than at a particular height. The right number needs re-deriving from MuJoCo with
the Menagerie mesh assets present, which are not checked in. **That is a genuine to-do, not a
loosened test**, and it is recorded as one.

**★ THE LESSON FOR THE IMPORTER AS A WHOLE.** Both bugs are the same shape: an attribute read
from the element when it should have been resolved through the class chain. `readGeom` now
routes `pos`, all five orientation spellings, `type`, `size`, `mesh`, `friction`, `mass` and
`density` through `defaults.resolve`. **Anything that does not go through it is a bug waiting
for a model that uses a class**, and Menagerie models use classes for nearly everything.

**5. The quadruped demo's capsules — and a fix that made it worse before it made it better.**

The first reading said `GeomShape.capsule` runs along local **Y** while `genMeshCylinder`
extends along **Z**, so the drawing was rotated by −90° to reconcile them. **That reading was
wrong and the "fix" produced visible ribbons** — flat curved bands wrapped around the limbs —
because a non-uniform scale then landed across the shape instead of along it.

**`cylinderUv` puts the axis in its third slot, which reads as Z. But `parametricMesh` REMAPS
as it writes** — `verts.y = p[2]` — so the finished mesh extends along zimr's **Y**, the same
axis the engine uses. No rotation was ever needed.

Measured, which is what settled it:

    genMeshCylinder(r=1, h=1) extent:
      x: [-1.000, 1.000]   y: [0.000, 1.000]   z: [-1.000, 1.000]

Two lessons, and the second is the one worth keeping:

* The real correction is the **span**, not the axis: the mesh runs [0, h] rather than
  [−h/2, +h/2], so it needs a half-length shift along Y and nothing else.
* **Reading the generator was not enough — the answer was two functions away.** A convention
  established in one function and silently rewritten by its caller cannot be found by reading
  either one. Printing the mesh's bounds took a single command and would have been right the
  first time. *When a convention matters, measure the artefact rather than reading the code
  that makes it.*

**(The original observation still stands: the demo's claim is that WHAT YOU SEE IS WHAT THE
SOLVER SEES, and a mis-drawn limb makes that false in the most misleading way available — the
picture still looks like a robot.)**

~~The quadruped demo drew every capsule 90° across its own limb.~~ `GeomShape.capsule` runs
along local **Y** — zimr's convention, not MuJoCo's — and `robot_mjcf` rotates each geom's
frame on import so MJCF's Z-capsules line up. The demo drew along Z. Measured on the Go1's
calf: the engine's axis points **(0.87, 0, −0.50)**, down the limb; the drawing pointed
**(0, −1, 0)**, straight out the side.

**This is the worst kind of wrong for that demo specifically**, whose whole claim is that WHAT
YOU SEE IS WHAT THE SOLVER SEES. The picture still looked like a robot — just not the one
being simulated.

**★ AND THE FIX'S SIGN WAS WRONG FIRST TOO.** `rotationX(+90°)` sends the mesh's +Z to −Y, not
+Y, so the end caps would have been swapped end for end — invisible on a symmetric capsule and
wrong for anything offset along it. Caught by printing the rotation's column instead of
trusting the derivation. `robot_mjcf.z_to_y` documents making exactly this mistake one layer
down, which is fair warning that this sign is easy to get backwards twice.

**The pattern is worth naming.** Every one of these returns something usable instead of
failing: the world instead of a body, a mesh instead of a capsule, an error instead of an
anonymous body. That is the same shape as `moveKinematic` — the bug that cost this project the
most time — where a function did something reasonable for its original caller and wrong for
its new one. **A default that looks like an answer is worse than no answer**, and it is worth
grepping for wherever a lookup can fail quietly.

### ★★ INTERACTION — a cross-cutting requirement, not a phase

**Every demo should be pokeable.** A robot you can only watch tells you it did not crash; a
robot you can shove, drag and throw things at tells you whether the physics is RIGHT. Three
sessions of contact bugs were found by pushing on a scene rather than by reading numbers —
the corner-balancing cubes, the mass slider's negative pivot, the crate tunnelling — and each
time the readout that made it findable was added AFTER the symptom, not before.

So this is a standing requirement on every example from here, applied as each is touched
rather than as a separate turn:

| interaction | what it tests that watching cannot |
|---|---|
| **shove** (impulse to a body) | recovery, and whether a controller has authority |
| **drag** (mouse ray → a spring to the grabbed body) | contact under sustained load, in a direction the demo author did not choose |
| **throw projectiles** | fast-moving contact — the tunnelling case, on demand |
| **live parameters** (mass, gains, friction) | whether behaviour changes with physics or merely looks like it does |
| **pick up and place** | grasping, and two-sided contact against a controlled body |

**Two of these already exist and both earned their keep immediately.** `robot_3d`'s mass
slider found a stale `body_subtree_mass` that produced a negative pivot in `factorM`;
`quadruped`'s shove is what turns "it stands" into "it stays standing".

**★ AND THE DRAG IS THE MOST VALUABLE ONE NOT YET BUILT.** A mouse ray into the scene plus a
spring to the grabbed point lets a human apply an arbitrary force in an arbitrary direction —
which is exactly the input a scripted test cannot generate and a bug is most likely to hide
from. It needs a ray-vs-geom pick and a per-frame external force; both are small on top of
what exists.

**Projectiles need the tunnelling fix first** (Phase C turn 12), or they will simply pass
through everything and demonstrate the bug rather than the physics. That ordering is the
point: build the interaction that exposes the problem you are about to fix.

### ★★★ REVIEW OF PHASES A–C — what the code said versus what it did

Read adversarially, with every claim re-measured rather than re-read. Four findings, and the
first two are the kind only a review catches.

**1. A WORKAROUND FOR A BUG THAT WAS ALREADY FIXED.** `robot_mjcf.build` recovered its
name→index mapping by matching each tree body's parent-relative pose against the spec,
because the builder was believed to reorder bodies. It does not — `buildFromSpec` assigns
`bi = spec_index + 1`. The belief came from the Go1 appearing mirrored, which was really the
free joint's **w-first quaternion**, found and fixed separately in the same session. The
matcher survived its own cause.

Deleting it is more than tidiness: **nine of the Go1's bodies share the pose `(0, 0, −0.213)`**,
so the matcher disambiguated them only through parent names assigned on earlier iterations. It
worked, and it was one symmetric model away from pairing the wrong leg.

**2. TWO OF THREE SAFETY GUARDS DO NOTHING.** Each was disabled in turn on the workloads that
motivated it:

| guard | with it removed |
|---|---|
| **`max_recovery_velocity`** | 5 crates @ 1.4 rad/s: **11.8 → 88.4 m/s, 0 → 4 lost** — genuinely load-bearing |
| `max_force_scale` | **bit-identical** on every case |
| `max_penetration` (depth clamp) | **bit-identical** on every case |

Both dead ones were added while chasing causes that turned out to be wrong — a 1.4 GN force
that came from a stale `body_subtree_mass`, and a 0.55 m overlap that was the wreckage of an
ejection rather than its cause. **A guard that never changes an outcome is not free: it tells
the next reader that something is protected when nothing has ever been shown to need it.**

`max_penetration` was actively harmful and is deleted. It clamped reported depth to 0.2 m, and
during this very review a diagnostic printed `deepest overlap −0.20000` — which I read as a
measurement and which was the clamp's own value. **It corrupted the instrument I was using to
evaluate it.**

`max_force_scale` is kept, because the failure it guards destroys a simulation outright and it
costs one `clamp` on a line that already clamps — but its doc comment now says plainly that it
has never been observed to fire.

**3. `Scene` SILENTLY DROPPED TENDONS AND SENSORS** on every robot after the first. They name
joints and sites, so they need the same prefixing the bodies get; that was simply not written.
Now it returns `MultiRobotTendonsUnsupported` rather than proceeding — a scene where robot 2's
cable drives robot 1's joint is a bug nobody would think to look for.

**4. `mjcf.Kind` ADVERTISED FIVE VARIANTS NOTHING READ** — `site`, `mesh`, `material`, `pair`,
`equality`, `tendon`. `readClass` already skips unknown tags, so an absent kind costs nothing;
a present-but-unread one costs a reader's trust in the whole enum.

**★ THE PATTERN ACROSS ALL FOUR.** Every one is residue from a wrong hypothesis that was
correctly abandoned — but only in the analysis, not in the code. **When a diagnosis is
overturned, the code written under it has to be revisited too**, and nothing prompts that
automatically: the tests still pass, because the code is harmless. It is only wrong about why
it exists.

### ★★★ TURN 10 — AND THREE WRONG ANSWERS BEFORE THE RIGHT ONE

`robot_bench` has a fourth case: a real Go1 holding its home pose with four foot contacts. The
other three are articulated dynamics with at most five limit rows and **no contact at all**, so
none of them measures the regime Phase C lives in.

| case | zimr | MuJoCo | |
|---|---|---|---|
| 1. two-link arm, nv 2 | **280 ns** | 2531 ns | 9.0x faster |
| 2. KUKA iiwa free, nv 7 | **1277 ns** | 5937 ns | 4.6x faster |
| 3. KUKA, 5 limits, nv 7 | **1961 ns** | 6638 ns | 3.4x faster |
| **4. Go1 standing, 4 contacts, nv 18** | **23,977 ns** | **20,209 ns** | **0.84x — near parity** |

**★ THE FIRST TWO READINGS OF CASE 4 WERE NONSENSE, and how they failed is the useful part.**

**52,415 ns — the robot was in FREE FALL.** `benchmark()` only calls `rbt.step`; nothing was
holding the pose. Over 200 000 steps the Go1 fell to **z = −743 161 m**, dragged by four
contacts pinned where its feet used to be, and the solver burned 60 iterations per step
fighting a configuration that had stopped describing anything. I reported that number, and
concluded from it that we lose to MuJoCo by 2.6x and that Newton was now the critical path.
**Both conclusions came from a measurement of garbage.**

**41,923 ns — controlled, but the contacts still lied.** Adding the PD hold stopped the fall.
The contacts were still pinned at their original positions and depths, so they got less true
every step. "Holding the contacts fixed" is not the same as holding them CONSTANT.

**23,977 ns — the contacts follow the feet.** A sphere foot on a ground plane needs no broad
phase to place: the contact is directly beneath it, and its depth is its height below the
plane. That keeps zimrphysics out of the timed region — the number is the robot's solver —
while leaving the contacts TRUE, which is the part that matters.

**★ AND THE CASE NOW VERIFIES ITS OWN PREMISE.** It prints the trunk's final height and whether
that is still standing (`z 0.3333`, home 0.2700, true). **A benchmark that does not check its
premise measures whatever it happens to be doing** — and will do so confidently, at four
significant figures, for as long as nobody asks.

**★★★ AND THEN `solver 60 it` TURNED OUT TO BE A 2.3x SPEEDUP SITTING IN PLAIN SIGHT.**

Solving the settled Go1 cold, from an identical state each time:

| iterations | 1 | 2 | 5 | 10 | 20 | 60 | 200 | 1000 |
|---|---|---|---|---|---|---|---|---|
| residual | 19.70 | 10.14 | 6.74 | 3.93 | 1.35 | 0.0199 | **4.0e-6** | **4.0e-6** |

PGS converges completely by ~200 sweeps and then **plateaus at 4.013e-6 against a target of
3.55e-6** — thirteen percent away, and unreachable in f32. So the solver reached its best
answer and spent every remaining iteration failing to improve on it. **`60 it` reads as failure
to converge; it was failure to NOTICE convergence.**

`SolverOptions.min_progress` (1%) stops a sweep that improves the residual by less than that
fraction. Relative, so scale-free, and far below the progress of a problem genuinely still
descending — the Go1 above was still halving its residual per sweep at iteration 20.

    before:  23,977 ns/step,  solver 60 it
    after:   10,292 ns/step,  solver  4 it     ← same answer, trunk still at z 0.3333

**★★ AND THE FIRST VERSION BROKE SOMETHING ELSE, which is why the check is GATED.** Slow
progress means two different things and they need opposite responses: near the floor it means
"finished, and the target is unreachable" — stop; mid-impact it means "this problem is hard" —
keep going. Testing progress alone conflates them. The ungated check took a KUKA sweeping a
crate tower from **14 m/s of ejection to 32**, by walking away from half-solved contacts.

`stall_window` (100x the tolerance target) requires the residual to be near the floor before
`min_progress` may stop the solve. The measured plateau sat 1.13x above its target, so 100x is
generous for the case this exists to catch, while a mid-impact residual runs thousands of
times larger and stays well outside it.

| | Go1 standing | KUKA crate sweep, peak ejection |
|---|---|---|
| no stall check | 23,977 ns, 60 it | 14.18 m/s |
| ungated | **10,292 ns**, 4 it | **31.99 m/s** ✗ |
| **gated (shipped)** | **12,303 ns**, 7 it | **14.18 m/s** ✓ |

Most of the speedup kept, the regression gone — and the crate number is bit-identical to the
baseline, which is the evidence the gate closes exactly where it should.

**A speedup found by measurement can still cost something the measurement does not show.** The
Go1 case would have shipped the ungated version happily; only re-running an unrelated scene
caught it. **Regression-check the scenes a change was not aimed at.**

**All 97 tests passed unchanged**, which is the evidence it never fires on work that is
converging.

| case | zimr | MuJoCo | |
|---|---|---|---|
| **4. Go1 standing, 4 contacts, nv 18** | **10,292 ns** | **20,209 ns** | **2.0x faster** |

**★ THE LESSON: A DIAGNOSTIC THAT LOOKS LIKE A PROBLEM MAY BE A MEASUREMENT.** `60 it` was
read three times as "PGS cannot handle contact" and used to argue that Newton was the critical
path. It was one plot away from being read correctly, and the plot took one command. **Plot
the thing before theorising about it** — the shape of a convergence curve says which of "too
slow", "stuck", and "already finished" you are looking at, and they need completely different
work.

§4g's S5 (Newton) is now a considered improvement rather than the critical path — and every
benchmark case is faster than MuJoCo again.


## ★★★ LINE-BY-LINE AGAINST MuJoCo'S SOURCE — what differs, and whether it is justified

Read against `engine_forward.c`, `engine_core_constraint.c`, `engine_solver.c` and
`mjtype.h`, plus MuJoCo's own reported defaults.

### The pipeline matches, stage for stage

| MuJoCo | ours |
|---|---|
| `mj_fwdKinematics` | `kinematics`, `comPos` |
| `mj_makeM` / `mj_factorM` | `crb` / `factorM` |
| `mj_collision` | (zimrphysics, outside the engine — §4k) |
| `mj_makeConstraint` | `makeConstraints` |
| `mj_island` | — (see below) |
| `mj_projectConstraint` | `projectConstraints` |
| `mj_transmission` | folded into `actuation` |
| `mj_comVel` / `mj_passive` / `mj_rne` | `comVel` / `passive` / `biasForce` |
| `mj_fwdActuation` / `mj_fwdAcceleration` | `actuation` / `forwardDynamics` |
| `mj_fwdConstraint` | `solveConstraints` |

### ✅ Where we already agree — verified in source, not assumed

* **`aref = −B·vel − K·I·(pos − margin)`** — identical, including the asymmetry that impedance
  scales the stiffness term and not the damping one.
* **`solimp` impedance ramp** — same two-piece power curve, same defaults
  `[0.9, 0.95, 0.001, 0.5, 2]`. **Measured on a live contact: `R/Â = 0.0526` against MuJoCo's
  `(1−0.95)/0.95 = 0.0526`.**
* **`R = max(MINVAL, (1−imp)·diagA/imp)`** — same formula.
* **Pyramidal friction** — MuJoCo's default `cone` is pyramidal, as is ours.
* **★ Implicit-in-velocity integration.** `mj_Euler` looks explicit and is not: when any DOF
  has damping it forms `M + h·diag(B)` and factors THAT. Our integrator does the same thing,
  so this is a match rather than the improvement it was once described as.
* **★ Progress-based termination.** MuJoCo's PGS stops on `improvement < tolerance` — a
  PROGRESS test, not a residual one. Our `min_progress` mirrors MuJoCo's actual criterion
  rather than departing from it. MuJoCo makes it scale-free by dividing by
  `meaninertia · max(1, nv)`; we make it scale-free by expressing it as a fraction. Different
  routes, same property.

### ✅ Justified differences

**f32 against MuJoCo's f64.** `mjtNum` is `double` unless `mjUSESINGLE`. This is the root of
several divergences and justifies them: our tolerance is RELATIVE where MuJoCo's is an
absolute `1e-8` (unreachable in f32 — the measured PGS floor on a standing Go1 was 4e-6), and
our `min_regularizer` / `min_constraint_diag` floors are `1e-10` where `mjMINVAL` is `1e-15`.
Choosing f32 is deliberate: it is half the bandwidth on a memory-bound solver, and it is what
a GPU port will need.

**No islands.** MuJoCo computes them (`mj_island`) but **`enableflags` defaults to 0, so they
are OFF** — the reference configuration does not use them either. Not a gap.

**No sleeping.** Same: gated behind `mjENBL_SLEEP`, off by default.

**Contact detection outside the engine.** MuJoCo owns `mj_collision`; ours comes from
zimrphysics through a bridge. §4k covers why, and the measured cost is linear.

### ⚠ REAL GAPS, in order of value

**1. ✅ Nesterov momentum — BUILT, CORRECT, AND MEASURED SLOWER. Off by default.**

Implemented exactly as `engine_solver.c` does it: `β = (k−1)/(k+2)`, extrapolate the force
vector, project back onto the cone, and restart adaptively when the sweep's correction opposes
the extrapolation (O'Donoghue–Candès). On a standing Go1 it does precisely what the theory
promises, and loses anyway:

    momentum off:  14 solver iterations,  17,847 ns/step
    momentum on:    3 solver iterations,  19,280 ns/step

**A 4.7x reduction in iterations, and 8% slower.** Extrapolating the forces invalidates `d.acc`,
which must then be rebuilt — and `rebuildAccelerationFromForces` is O(rows × nv), the same
order as the sweep it is accelerating. At sixteen rows the fixed cost per iteration eats the
saved sweeps.

**Kept rather than deleted, because the trade reverses with size**: the rebuild is once per
iteration while the sweeps saved grow with row count, so a scene with hundreds of contact rows
should favour it. A test pins that it still reaches the same answer in no more iterations, so
the switch does not rot while it is off.

**★ THE LESSON IS ABOUT MuJoCo, NOT ABOUT MOMENTUM.** MuJoCo runs f64, elliptic friction cones,
and a Newton solver whose inner loop is far more expensive than a Gauss-Seidel sweep. The same
acceleration pays for itself there and does not here. **Copying a technique from a reference
implementation copies its cost model too**, and that has to be measured rather than inherited.
This is the second time this session the source suggested something the measurement declined —
the first was reading `60 it` as a solver weakness when it was a stopping-criterion bug.

**★★ AND A PROCESS FAILURE WORTH RECORDING.** The first A/B appeared to show momentum slower,
then a later `grep` showed the flag set to `true` when the "off" run should have left it
`false` — meaning I could not tell which configuration had produced which number. **Both runs
were redone with the flag printed alongside each result.** A/B measurements need the
configuration read back at the point of measurement, not inferred from the edits believed to
have been made.

~~Nesterov momentum in PGS — the cheap win, not Newton.~~ MuJoCo's PGS carries
Nesterov acceleration with O'Donoghue–Candès gradient restart: it extrapolates the force
vector and resets whenever the correction opposes the extrapolation. Ours is plain PGS. This
is a well-defined, bounded change to a loop we already have, and it targets exactly the
measured weakness — a 16-row standing contact problem needing ~200 sweeps to reach its floor.
**It should be tried before Newton**, which is a much larger build for the same goal.

**2. Newton with line search.** MuJoCo's DEFAULT solver, with `ls_iterations = 50`. Our
benchmark says we are faster than MuJoCo anyway on every case, so this is a convergence-quality
item rather than a speed one.

**3. Equality constraints.** Parallel linkages (Cassie, Digit) cannot be expressed at all.

**4. Spatial tendons, flex/deformables, SDF collision, muscle actuators.** Whole subsystems,
none needed for the roadmap's target.

### The one thing worth changing in the plan

**§4g's S5 said "Newton".** The source says the cheaper move is Nesterov-accelerated PGS
first — same loop, a few lines, and it attacks the measured problem directly. Newton stays on
the list behind it.

## ★★★ THE NEW TARGET — three robots that reach, aim, and get hit

**Humanoid, quadruped and arm, each able to hold a pose reliably, put an end effector on a
target, and be knocked about by projectiles.** That is a sharper goal than "walks", and it
exercises more of the engine: pose control, Jacobians, IK, and fast contact against free
bodies.

### ✅ Step 1 — `src/robot_control.zig`, the shared control layer (4 tests)

Both pieces every demo had been re-implementing, in one place:

**`PoseHold`** — PD in torque space with a per-joint ceiling, gravity-compensated. The ceiling
is what makes a robot weak or strong; without one a PD law produces whatever torque the error
demands and every robot is infinitely strong.

**`Ik`** — damped least squares, `Δq = Jᵀ(J·Jᵀ + λ²I)⁻¹Δx`. The naive `J⁺` explodes near a
singularity: a stretched arm has a nearly rank-deficient Jacobian, so the pseudo-inverse asks
for enormous joint motion to achieve a tiny Cartesian one. The damped form trades exactness
for boundedness. **The system solved is 3×3 whatever the robot's size**, because it is `J·Jᵀ`
and the task is three-dimensional — the same cost on a 30-DOF humanoid as on a 7-DOF arm.

**★ `Actuation` — the mask that ends a bug that has bitten three times.** Gravity compensation
is something a MOTOR does, and `bias_force` covers every DOF including a floating base's six.
Adding all of it cancels the machine's own weight: crates hung in mid-air in `robot_3d`, and
the Go1 **rose at a steady 2.4 m/s**. The mask is computed once from the model's topology so
the question is asked in one place rather than remembered at every call site. A test pins that
a floating base receives exactly zero applied force and really does fall.

**Three IK decisions worth keeping:**

* **Unpowered DOFs are zeroed out of the Jacobian.** A humanoid's Jacobian includes its root's
  six DOFs, and a solver free to use them "reaches" the target by TELEPORTING THE PELVIS — a
  perfect solution to the equations and a useless one for a robot.
* **Joint limits are enforced in the solve**, not left to the constraint solver. An answer that
  violates a limit is not a pose the robot can hold, and handing one to a controller produces a
  machine fighting itself.
* **`reached = false` is a normal outcome.** A target outside the workspace has no solution and
  the useful answer is the nearest pose — a caller steering a hand toward a moving object wants
  it to keep pointing the right way, not to stop. Tested on a target 50 m away: the arm
  stretches toward it, stays finite, and reports honestly.

Tested on the real KUKA rather than a two-link contrivance, because 7-DOF redundancy is what
makes `J·Jᵀ` genuinely rank-deficient and is the case damping exists for.

### ✅ All three robots now stand, under test

| robot | source | DOF | result |
|---|---|---|---|
| **arm** — KUKA iiwa | URDF | 7 | holds pose, reaches IK targets |
| **quadruped** — Unitree Go1 | MJCF (Menagerie) | 18 | 30 s, 1.3 cm drift, \|v\| 0.0087 |
| **humanoid** — MuJoCo's own | MJCF | 27 | 10 s, 4.5 mm drift, \|v\| 0.018 |

### ✅ EQUALITY CONSTRAINTS — closed loops, which a tree cannot express

Reduced coordinates buy exact joints and no drift, and pay for it in TOPOLOGY: a tree has no
rings, so a mechanism whose links form one could not be spelled at all. That excluded a whole
class of real machine — **Cassie and Digit's parallel shins, four-bar suspensions, delta arms,
and most geared grippers**.

`EqualitySpec` states a point that two bodies share; `makeConstraints` emits it as rows the
solver enforces. Verified on a four-bar: **separation 0.168 m closed to under a millimetre**,
and the follower arm moved only because the closure moved it — untied it never leaves zero,
since gravity on a hanging arm produces no torque about its own pivot.

**★★ THREE ROWS, NOT ONE ALONG THE ERROR.** Projecting onto the error direction looks right
while the error is small and drifts sideways: a direction derived from the error cannot
constrain the two axes the error does not happen to point along. World X, Y and Z always span
the space whatever the error is doing.

**★★ AND THE SOLVER'S CLAMP HAD TO LEARN A SECOND CASE.** Its comment read *"every row is
unilateral today"* — true for limits and contacts, which may push and not pull. **An equality
is bilateral**: a loop closure welds two points and neither may leave, so clamping its force at
zero gives a linkage that resists compression and comes apart under tension — a rubber band
rather than a rod. The test asserts at least one row carries NEGATIVE force, which is the
property that clamp would destroy.

**★ EACH BODY'S JACOBIAN AT ITS OWN ANCHOR**, not at a shared point. For a contact the two
touching points coincide by definition; for a loop closure they coincide only once the
constraint is satisfied, and using one point for both computes the wrong velocity relationship
exactly when the error is largest.

**A note on the test's own threshold.** The follower's peak swing is 0.012 rad and the bar is
set at 0.005 — below the measurement rather than at a round number that happened to pass. It is
small because the geometry keeps the closure nearly satisfied throughout: the leader's tip
travels mostly along the line joining the anchors, the direction the constraint cares least
about. The separation number is the strong evidence.

### ★ REVIEW OF THE EQUALITY CODE — two changes, one of which beats MuJoCo's API

**1. `pair_jac_a` / `pair_jac_b`, formerly `contact_jac_*`.** The buffers hold two bodies' point
Jacobians for any row built from a PAIR — contacts and loop closures both. Named for the first
thing that used them, the name said something untrue about half the callers the moment
equalities started borrowing them.

**2. ★★ THE PARTNER ANCHOR IS DERIVED, and this is a place we are genuinely better.**

Both anchors describe the same physical point in two frames, so stating both states one fact
twice — and getting the second wrong by a centimetre gives a mechanism that lurches on frame
one and then behaves, which reads as a solver problem and is a typo. `anchor_b` is now
optional; null means "whatever makes this exact at the rest pose", computed by walking each
body's parent chain at `qpos0`.

**MuJoCo derives it too — but only in the file format.** `<connect anchor="...">` takes one
point and the COMPILER fills the other in; `mjModel` still stores both, and a model assembled
through `mjSpec` in code gets no such help. Having the derivation in the API means every model
gets it, however it was built. A test asserts the constraint's violation is zero before
anything moves, which is the property the derivation exists to guarantee.

**Checked against `engine_core_constraint.c` and found equivalent:** MuJoCo computes the error
as `pos[0] − pos[1]` with the Jacobian difference the same way round, explicitly noting it is
"opposite of contact"; ours uses `b − a` for both. Consistent within each, so the constraint is
identical and only the force's sign convention differs.

**✅ MJCF `<equality>` PARSING — DONE, and it agrees with MuJoCo on the derived anchor.**

A four-bar fixture, imported end to end. MuJoCo reports
`eq_data = [0.4, −0.3, 0, 0, −0.3, 0]`; the file states only the first three, and **both engines
derive the same second three** — `left` at x = −0.2 and `right` at x = +0.2, so a point 0.4
along `left` lands on `right`'s origin.

**MJCF spells this two ways and both are read.** Body semantic
(`body1`/`body2`/`anchor`) and site semantic (`site1`/`site2`, two named points that must
coincide). The site form is why sites had to be readable first — it names points whose BODIES
are what the closure actually ties.

**★ AN EMPTY `body2` IS THE WORLD**, which is how MJCF pins something to a fixed point.
Requiring it would refuse a legal and common construction; and the robot-name prefix must NOT
be applied to it, because there is one world and it belongs to no robot.

**Only `connect` is read.** MuJoCo has five types — `weld`, `joint` coupling, `tendon`,
`distance` — and an unrecognised entry is SKIPPED rather than refused, the same call made for
sensors and unrepresentable geoms. A model carrying a weld it does not depend on still imports;
one that depends on it visibly comes apart, which is the honest failure.

**✅ JOINT COUPLING — DONE.** `<equality type="joint">`: one joint's coordinate as a polynomial
in another's, `driven − rest = c0 + c1·x + … + c4·x⁴` with `x = driver − rest`. **MuJoCo's
`polycoef` exactly**, so a coupling written for one engine reads the same in the other.

Two tests: a **mirrored gripper** (`.{ 0, -1 }` — two fingers, one motor, tracking to under a
millimetre) and a **locked joint** (null driver, which pins a joint to a constant without
removing it from the model, so one robot definition serves both free and fixed wrists).

**★ ONE ROW, and the Jacobian is the polynomial's DERIVATIVE** — `[1 on driven, −poly′(x) on
driver]`. Linear coupling makes that a constant, which is the case every gripper uses.

**★ AND A DIVISION BY ZERO THAT WOULD HAVE POISONED EVERY SOLVE.** The slope is accumulated as
`k·cₖ·xᵏ⁻¹` using a running power divided by `x` — which at `x = 0` is `0/0`. That is the REST
POSE, so it is the first state every model is in. Rebuilt directly there, where the slope is
just `c1`.

**★ `Equality` IS NOW A STRUCT WITH A `holds` UNION, not a union outright.** The two kinds share
nothing but their softness — and making the whole type a union would force every caller that
only wants to know how STIFFLY a closure is held to unwrap a variant it does not care about.

**✅ AND MJCF PARSES THE JOINT FORM TOO.** A gripper fixture, imported end to end: one motor on
the left finger, the right mirroring it through the coupling alone, settling matched to 2 mm
where MuJoCo settles at `(0.08025, −0.08008)`.

**★ `polycoef="0 -1"` IS TWO NUMBERS AND MEANS FIVE.** MuJoCo reports `[0, −1, 0, 0, 0]` — the
omitted terms are zero, not absent, and almost every real file writes the short form. That
needed a SECOND reader: `readFloatsUpTo` fills what is present and leaves the rest, while
`readFloats` stays strict. They must not share one, because a `pos` with two numbers is a
mistake rather than an abbreviation, and a reader lenient enough for coefficients would accept
a broken position silently.

**★ THE JOINT FORM NAMES JOINTS, NOT BODIES**, so the converter routes it separately and applies
the robot prefix to the JOINT names. Sending it down the body path would look up `""` and fail
with a name error that says nothing about what was actually wrong.

**✅ WELD — DONE. Equalities are complete.** Six rows: the three position rows a `connect`
already had, plus three for orientation.

**★ WHAT A WELD IS FOR, AND WHY IT IS NOT A JOINTLESS BODY.** A body with no joint is welded to
its PARENT and the tree gives that for free. This ties two bodies not related that way — a hand
gripping a crate, two halves bolted together at runtime — and it can be REMOVED again, which a
topology cannot. The distinguishing property is orientation: a `connect` pins a point and
leaves the pair free to pivot about it like a ball joint.

**★★ THE ORIENTATION ERROR IS A ROTATION VECTOR, TAKEN IN THE WORLD FRAME.** MuJoCo rotates
every Jacobian column by `neg(q1)·(jac0−jac1)·q0·relpose` so error and Jacobian both live in the
error's frame; this leaves both in the world. **Equivalent** — rotating the error and all three
rows by the same rotation gives three rows spanning the same space with the same solution — and
it costs one quaternion multiply instead of one per DOF, with no frame left to explain. A
justified simplification rather than an accidental divergence.

**★ `q` AND `−q` ARE THE SAME ROTATION** and the vector part flips between them, so the one with
positive `w` is chosen: a weld 179° out then corrects by 1° rather than by 359°.

**★★ AND A UNION BUG THE FOCUSED TEST RUN COULD NOT SEE.** The position rows read
`closure.holds.connect` unconditionally — correct for a connect, and for a weld it reads the
wrong variant. **The focused run passed and the full suite crashed** on
`access of union field 'connect' while field 'weld' is active`, because the focused build has
safety checks off. That is the second time this session a focused pass has certified something
broken; the pattern is now clear enough to state: **a focused run is a fast iteration tool, not
a verification.**

### ✅ `robot.State` — snapshot and replay, the foundation under RL and planning

`Data` is mostly SCRATCH: Jacobians, mass factorisations, body poses, sensor readings, all
recomputed by `forward`. Copying it would be slower and would invite a subtler bug — two
"states" differing only in stale scratch compare unequal while describing the same physics.

The core is **joint coordinates, joint velocities, actuator activation**, and `restore` marks
the derived data stale so the next `forward` rebuilds from it. Skipping that leaves body poses
describing the state that WAS there, which reads correctly until something uses a pose without
calling `forward`.

**Proven by replay, not asserted:** run, snapshot, run further, restore, run the same further
steps, and require the continuations to be **bit-for-bit equal**. `expectApproxEqAbs` would
pass on a state that had quietly lost something and diverged later.

**★★ AND A TEST THAT DISPROVED ITS OWN PREMISE.** A second test was written to justify keeping
`warm_force` in the snapshot, by showing a replay that diverges without it. **It does not
diverge** — two free bodies with eight contact rows reach the same answer whether or not the
solver starts from last step's forces. The first version of that test was wronger still: it
claimed a cold solve lands elsewhere, which is false for one joint at a limit, where
convergence takes a single iteration either way.

The field stays, for a narrow reason rather than a hand-waved one: the solver stops on
`min_progress` and an iteration cap, so warm and cold solves CAN halt at different iterates
once the residual is still moving when the stop fires. That regime is real and the test scene
is not in it. **The comment records "could not construct a case where it matters" rather than
"it is required"** — one memcpy against a failure that would surface as a training run quietly
not reproducing.

### ✅ EQUALITIES ARE COMPLETE — all three types, both engine and MJCF

| type | rows | what it unlocks |
|---|---|---|
| `connect` | 3 | four-bars, parallel shins (Cassie, Digit), delta arms |
| `joint` | 1 | geared grippers, locked joints, any known ratio |
| `weld` | 6 | a payload rigidly held by a manipulator, removable at runtime |

**★ `connect` AND `weld` READ IDENTICALLY IN MJCF except for one attribute**, so the reader
branches on the tag once and shares everything after. A weld IS a connect that also holds
orientation, and the format says so the same way — two bodies or two sites, plus an anchor.
Keeping one reader is what stops the two spellings drifting apart in code the way they have not
in the format.

**★ THE SHARED POINT MAY DIFFER FROM MuJoCo'S, AND THAT IS FINE.** On a weld with no stated
`anchor`, MuJoCo defaults the point to one body's origin and this defaults to the other's. For a
weld it makes no difference: constraining any one point PLUS the orientation fixes the entire
relative pose, so the two describe the same rigid attachment. Worth stating because a diff of
`eq_data` against ours looks like a discrepancy and is not.

**MuJoCo's `relpose` is left to the builder**, which derives it from the rest pose — the same
treatment the partner anchor gets. The format can state it; no real model does, because a weld
means "hold them as they are", which is exactly what the derivation produces.

### ✅ PROJECTILES — swept contacts, and the last item on the target list

**Stopped at every speed tested, up to 100 m/s against a 2 cm wall.** Previously through at
anything above ~10 m/s.

    before:  20 m/s -> z  5.9    100 m/s -> z 119.0
    after:   20 m/s -> z −2.0    100 m/s -> z  −5.6

**★ ZIMRPHYSICS HAD THE SWEEP ALL ALONG — `castShapeClosest` is public.** What it does not have
is a way to run CCD for a PROXY: its own path is gated on `inv_mass > 0`, and every bridge
proxy is kinematic by construction. Calling the cast directly is the same computation without
the gate.

**★★ THE OUTPUT IS A CONTACT, NOT A POSITION — and the first attempt got that wrong.** Placing
the proxy at the impact point seems obvious and fails: the proxy freezes while the tree body,
which the robot's own solver integrates, flies on. The two then describe different robots and
the contact is reported for a pose nothing is in. **This module produces contacts**, so the
sweep's output is a contact with a POSITIVE distance — which is exactly a speculative contact,
and the solver already knows how to decelerate against one.

**★★★ AND IT ONLY WORKED ONCE THE SWEPT CONTACT WAS MADE STIFF.** With the default softness the
ball decelerated and still crossed: a 0.02 s time constant is ten steps at 500 Hz, and the
contact exists for ONE — it had done a tenth of its work when the ball was already past. Two
timesteps is the stiffest the solver can represent, and it is the right choice for a contact
that describes an impact which must be arrested before the next frame rather than a foot
settling onto a floor.

**Three smaller things, each of which broke it silently:**

* **The threshold is `0.75 × the shape's inner radius`**, matching zimrphysics' own
  `linear_cast_threshold` rather than inventing a second convention. Requiring the body to
  outrun its whole radius sounds right and fires too late — a 0.05 m ball at 20 m/s moves
  0.040 m per step and never trips a 0.050 m bar, while what it must cross is the WALL's half
  thickness, not its own radius.
* **Static geometry maps to `world_body`, not `not_a_robot_body`** — the latter is maxInt, a
  sentinel for "no mapping", and pushing it in as a body index reads off the end of every
  per-body array. Segfaulted on the first swept contact.
* **Swept contacts are emitted FIRST in `harvest`**, so they are never the rows dropped when a
  step overflows `max_contacts`. A contact that keeps a body inside the world matters more than
  one more row under a resting foot.

### ✅ SENSORS — the observation side, which nothing had exercised

`robot.zig` has carried **twelve sensor kinds** for a long time and MJCF supplied none of them,
so an imported robot could be DRIVEN and could not be READ. That is half the interface missing:
useless for control, and useless for RL, where the observation is the whole point.

Now parsed and verified against MuJoCo's own readings on a purpose-built fixture — neither the
Go1 nor the humanoid declares a sensor, so there was no oracle until one was written:

| sensor | MuJoCo | ours |
|---|---|---|
| `jointpos`, `jointvel` | 0.3, 1.1, −0.6 | match to 1e-4 |
| `framepos` (site) | (−0.029552, 0, 0.331264) | match to 1e-4 |

**★ SITES CAME WITH THEM, and had to.** A geom is collision or visual; a site is neither — it
is a frame you mount an instrument on, and every frame-relative sensor names one. They were not
read at all before, so sensors were unreachable regardless of parsing.

**★ MJCF NAMES SENSORS BY TAG, NOT BY ATTRIBUTE.** `<jointpos joint="x"/>` and
`<framepos objtype="site" objname="x"/>` are different ELEMENTS, and the attribute naming the
target changes with the kind — `joint`, `site`, `actuator`, or the `objtype`/`objname` pair.
An unrecognised sensor is SKIPPED rather than refused: MuJoCo has upwards of thirty kinds, and
a model carrying a rangefinder should still import.

**★★ AND A BUG THE FOCUSED TEST RUN COULD NOT SEE.** Sensor names are `allocPrint`ed into the
scratch arena `build` tears down on the way out, so keeping the slices handed every caller a
DANGLING POINTER. Body names get away with borrowing because they come from the `mjcf.Robot`,
which outlives the model; a prefixed sensor name has no such home. **The focused run passed and
the full suite crashed** — the freed memory still read correctly until another test allocated
over it. Worth remembering before trusting a focused pass on anything that outlives a function.

### Next, in order

1. **✅ A humanoid that stands — DONE, and it is the hardest of the three.** A quadruped
   standing is nearly a table; a humanoid is an inverted pendulum on two small feet, 1.28 m
   tall and 40.8 kg, 27 DOF, held up by ankle torque alone. MuJoCo's own `humanoid.xml`,
   through the same import path, held by `PoseHold` for 5000 steps at 500 Hz: **torso at
   1.2775 m against a 1.2820 m start — 4.5 mm of drift — and max |v| = 0.018 m/s.** Now a test.

   **★ THE GAIN BAND IS NARROW, AND BOTH FAILURES SAY SOMETHING:**

   | gains | outcome |
   |---|---|
   | kp 100, kv 2, limit 100 | torso sinks to **0.24 m** — too weak to hold itself up |
   | **kp 400, kv 10, limit 300** | **1.2775 m, \|v\| 0.018 — stands** |
   | kp 1000, kv 30, limit 1000 | torso at **−201 m**, \|v\| 90 — diverges |

   Too soft and it folds; too stiff and the controller outruns the timestep and throws the
   robot across the map. The Go1 tolerates a far wider band because its pose is nearly
   statically stable, whereas every humanoid joint has to be actively held. **The stiff-end
   failure is a controller/timestep interaction, not a physics one** — worth stating because
   "the robot exploded" reads like a solver bug and is not one here.
2. **🔄 Projectiles — DIAGNOSED COMPLETELY, and it is none of the three things it looked like.**

   A 0.05 m ball fired at a wall, bisected against every hypothesis in turn:

   | hypothesis | test | verdict |
   |---|---|---|
   | tunnelling — moves too far per step | 8000 Hz, **2.5 mm/step**, a twentieth of its radius | ❌ still passes through |
   | the solver cannot absorb the impulse | contacts written BY HAND, no detector | ❌ stops it at 50 m/s, every time constant |
   | contact too soft | `time_const_s` 0.02 → 0.002 | ❌ no change |
   | **the overlap flips the normal** | wall thickness varied | ✅ **exactly this** |

       20 m/s, wall 0.10 m:  through      50 m/s, wall 0.10 m:  through
       20 m/s, wall 0.50 m:  STOPPED      50 m/s, wall 0.50 m:  through
       20 m/s, wall 2.00 m:  STOPPED      50 m/s, wall 2.00 m:  STOPPED

   **It is a THICKNESS threshold, not a speed one**, and the mechanism is visible in the
   trace: the ball is decelerated **from 20 m/s to 1.32** — the solver does its job — but by
   then its centre has passed the wall's MID-PLANE, the nearest exit face flips, and the
   contact correctly ejects it out the far side. The normal reads `(0, 0, +1)` and the
   distance is positive and growing: a perfectly resolved contact, on the wrong side.

   **★ THIS IS THE SAME ROOT CAUSE AS TURN 12'S CRATE EJECTIONS**, where a crate reported a
   0.55 m overlap against a 1 m floor. That was diagnosed as wreckage rather than cause, and
   correctly — but the mechanism was real and this is it, isolated. **A convex shape has no
   memory of which side something entered from**, so once the mid-plane is crossed the
   geometry is unambiguous and wrong.

   **Shipped: a motion-proportional speculative margin.** The margin is now `|v|·dt` capped at
   6 cm, so a contact begins acting a step before it lands instead of after. It moves the
   20 m/s case from z=8.3 to z=1.8 — a real improvement and not a fix, since it cannot help
   once the mid-plane is crossed.

   **What actually fixes it is CCD**, and the constraint is known: `zimrphysics` has
   `linear_cast` but requires `inv_mass > 0`, and every proxy is kinematic. Either that
   restriction lifts for proxies, or the bridge sweeps them itself.

   **Until then the demos have a usable rule:** projectiles up to ~20 m/s work against thick
   geometry, and thin walls are what fail. Reversing turn 12's advice again — **for the
   DETECTOR, thick is better; for the SOLVER's reported depth, thin is better** — and the two
   want opposite things, which is worth knowing before the next scene is built.
3. **One demo per robot**, each pokeable, each with an IK target to drag.

## 🔧 DISK PRESSURE — measured, and the cause is one number

Builds have been failing for space, and clearing the whole cache each time costs a full cold
rebuild — several minutes, and long enough that a `zig build test` times out mid-turn and looks
like a test failure.

**★ EVERY SOURCE EDIT PRODUCES A 156 MB TEST BINARY, and the old one is never evicted.**
Measured: **four builds in six minutes, 0.6 GB.** That is essentially all of it —
`tools/` is 423 MB and fixed, `zig-out/` 119 MB and regenerated per standalone, `/tmp/mj` 114 MB
and worth keeping as the MuJoCo oracle.

**★★ AND DELETING FROM `o/` ALONE BREAKS THE NEXT BUILD.** `.zig-cache/h` holds the manifests
that say "this output already exists". Remove an output without its manifest and zig stays
certain of a file that is gone:

    error: failed to spawn configure script ".zig-cache/o/<hash>/configurer": FileNotFound

which reads like a corrupt checkout and is self-inflicted. **This bit twice before the cause was
found** — once as a mysterious `FileNotFound`, once as a build that "worked" and then did not.
`h/` is 6 MB and rebuilds in seconds, so it is dropped whenever anything in `o/` is.

**`/home/claude/prune_cache.sh`** does both: removes object directories over 20 MB and older
than 20 minutes, then clears `h/`. Verified against the exact failure sequence — grow the cache
with two rebuilds, prune, build again, clean. It keeps the incremental cache useful, where
`rm -rf .zig-cache` throws away everything and pays for it on the next build.

# ═══ THE PLAN FROM HERE ═══
#
# Written after the original 20-turn roadmap was overtaken: its target ("walking on moving
# crates") was reached differently, and the goal has sharpened to **better, simpler and nicer
# than MuJoCo, integrated with zimr, ready for RL**. This section supersedes the turn table
# below, which is kept because its findings are still true.

## Where we actually stand against MuJoCo

**Better already, and worth defending:**

| | |
|---|---|
| **Runs in a browser** | A standalone HTML file, no install, works on a phone. MuJoCo needs a native build or WASM gymnastics, and this is the single largest practical difference. |
| **Faster on every measured case** | 9.0x / 4.6x / 3.4x on contact-free cases, **1.6x** on a standing Go1 with 16 rows. |
| **Exact `Â` diagonal** | MuJoCo approximates it; ours is `(J M⁻¹ Jᵀ)_ii` computed properly. |
| **Derived anchors in the API** | MuJoCo derives a weld's partner anchor and relpose in its COMPILER only; a model built through `mjSpec` in code gets no help. Ours derives in the spec, so every model benefits however it was built. |
| **Comments that say why** | The reason a constant is 0.75 and not 1.0 is next to it, with the measurement. |

**Worse, deliberately:** f32 against MuJoCo's f64 — half the bandwidth on a memory-bound
solver, and what a GPU port will want. Everything downstream (relative tolerance, `1e-10`
floors) follows from that one choice.

**Worse, not yet addressed:** no Newton solver (PGS with a stall check instead); no spatial
tendons, flex, SDF collision, muscle actuators or plugins; no Python bindings.

## What "nicer" concretely means, and the work it implies

### A. The demo story — the thing MuJoCo cannot easily do

A browser tab that runs a real robot, on a phone, with sliders. That is the showcase, and the
gap is content rather than capability. Ranked by what each proves:

1. **★ HARDCODED TROT** — and it is closer than it looks. `solveBodyPose` already holds four
   feet at commanded world positions through per-leg IK; a gait is the same machinery with the
   targets MOVING. Each foot follows a cycle: stance (a straight line backwards under the body)
   then swing (an arc forward through the air), with legs phase-offset. Trot is diagonal pairs
   at 0.5 phase.
2. **★★ GAIT GALLERY** — walk, trot, pace and bound differ ONLY in the four phase offsets.
   Four sliders and one line of code, and it makes the abstraction visible: gaits are not four
   algorithms, they are four numbers.
3. **PARALLEL-LINKAGE LEG** — a Cassie-style shin closed by an `equality`, which no tree can
   express. Shows the constraint doing something a topology cannot.
4. **PICK AND PLACE** — the KUKA plus a two-finger gripper coupled by `equality type="joint"`,
   IK to a target, close, lift, drop. Exercises IK, coupling and contact in one story.
5. **RAGDOLL** — the humanoid with the controller off, knocked about by projectiles. Cheap,
   and the clearest possible demonstration that the dynamics are real.
6. **PUSH RECOVERY** — the humanoid shoved, with the CM and support polygon drawn. The
   `BalancedIk` nullspace machinery already computes the CM Jacobian.
7. **MULTI-ROBOT** — `Scene` already supports several robots; four Go1s in one world is a
   one-line change and looks like a product.

### B. RL readiness — what exists and what is missing

**Done:** deterministic replay from `State` (bit-for-bit); environment independence (many
`Data`, one `Model`, proven interleaved); `observe` packing qpos+qvel+sensors; sensors from
MJCF; `reset`.

**Missing, in order:**

1. **An `Env` wrapper.** Model + Data + State + observation buffer, with `reset`, `step(action)`
   and `observation()`. Not because the pieces are hard to assemble but because everyone
   assembles them slightly differently and then their results are not comparable.
2. **Action-space description** — sizes, bounds from `ctrl_range`, and which DOFs are driven.
   `Actuation` has half of this already.
3. **Batched stepping.** The independence property is proven; what is missing is the loop that
   uses it, and a decision about threading.
4. **A learning demo in the browser.** A tiny policy trained live on a toy task, plotted as it
   improves. This is the thing MuJoCo genuinely cannot do casually, and it would make the
   engine's case better than any benchmark.

### C. Integration with zimr

Already exported: `robot`, `robot_physics`, `robot_scene`, `robot_mjcf`, `robot_control`. Nine
robot examples. A `robots.html` tutorial and a `mujoco-tutorial.html`.

**Gaps:** the tutorial predates MJCF import, sensors, equalities and the control layer — it
teaches an engine that has since grown a great deal. And no example yet uses `robot_control`
except the three demos, so the IK and pose-holding are invisible to anyone reading the gallery.

## ★★★ ALL FOUR OF MuJoCo'S INTEGRATORS, INCLUDING THE ONE WE LACKED

| MuJoCo | ours | what it is |
|---|---|---|
| `mjINT_EULER` | `.euler` | semi-implicit, joint damping implicit |
| `mjINT_RK4` | `.rk4` | explicit 4th-order Runge-Kutta |
| `mjINT_IMPLICITFAST` | `.implicitfast` | implicit in velocity, no Coriolis derivative |
| `mjINT_IMPLICIT` | **`.implicit`** ✅ | implicit in velocity, **with** it |

**★ THE LINE BETWEEN THE TWO IMPLICIT MODES IS ONE TERM.** Everything else in `D` — joint
damping, tendon damping, actuator velocity terms — is a MODEL CONSTANT and could be built once
per model. The Coriolis derivative is not: it depends on the current velocity, changes every
step, and is most of the cost. MuJoCo draws the line in exactly the same place, at
`mjd_smooth_vel`'s `flg_bias`, and solves `implicit` with an **LU** because that matrix is
asymmetric where `implicitfast`'s stays symmetric.

### ★★★ WHAT EACH INTEGRATOR IS ACTUALLY FOR — measured, and one claim withdrawn

A rotor at 80 rad/s on a damped gimbal, against an rk4 reference at dt = 1/20000, after 1 s:

| dt | euler | implicitfast | implicit | rk4 |
|---|---|---|---|---|
| 1/500 | 0.00057 | 0.00057 | **0.00014** | 0.00001 |
| 1/100 | 0.00269 | 0.00269 | **0.00063** | 0.00002 |

**`implicit` is four times more accurate than `implicitfast`**, at one linear solve per step
against rk4's four force evaluations. That is the case for it, and it is a real one.

**★★ AND THE CLAIM THIS SECTION FIRST MADE DID NOT SURVIVE MEASUREMENT.** It said `implicit` was
"the only one that stabilises a fast-tumbling free body". On a torque-free plate spun about its
intermediate axis:

    euler         energy 0.02952   world |L| drift 0.01633
    implicitfast  energy 0.02952   world |L| drift 0.01633
    implicit      energy 0.06083   world |L| drift 0.02067   ← WORSE than implicitfast
    rk4           energy 0.00000   world |L| drift 0.00015   ← dominates completely

**Implicit methods buy stiffness, not accuracy**, and a torque-free tumbler is not stiff — it is
merely fast. For that case rk4 is the right answer and nothing else is close.

**★ AND THE FIRST METRIC WAS WRONG TOO.** Momentum was measured in the body frame, where the
Dzhanibekov flip reads as a 200% "drift" — the flip is real physics, not integrator error, and
`implicit`'s apparently better number came from FAILING to reproduce it. World-frame angular
momentum is the invariant; the body frame is not.

**★ AND A TEST THAT SAID NOTHING.** A first comparison used spins of 200 and 600 rad/s, where
every integrator reported a peak velocity of exactly 100 — the velocity BOUND, not divergence.
80 rad/s sits under it and the comparison means something.

**Our solve already uses LU with partial pivoting**, so the asymmetric matrix `implicit`
produces is handled correctly — the caveat raised when it was written turned out to be
unfounded, which was worth five minutes to confirm rather than assume.

**★★ `rneVelDerivative` MIRRORS `rne` ONE LEVEL UP** — the same forward sweep, the same backward
sum, the same projection onto `cdof`, propagating a 6×nv matrix per body where `rne` propagates
a 6-vector. Reading them side by side is the only sane way to check either.

**★★★ AND IT IS VERIFIED AGAINST FINITE DIFFERENCES, which is the only honest test for an
analytic derivative.** A mirror of an existing function is exactly the code that looks right
while being one term out. Perturb each velocity, re-run `rne`, compare:

    worst mismatch     0.002024      (tolerance 0.05, set by the DIFFERENCE's truncation error)
    largest entry      0.982487      (so the matrix is genuinely non-trivial)

The test model TUMBLES on purpose — the Coriolis term is quadratic in velocity, so at rest every
entry is zero and the comparison would pass on a function that returned nothing. The
"largest entry" assertion exists for exactly that, and its first threshold (`> 1.0`) failed on
a derivative correct to 0.002 — the wrong reason for a test to go red, so the bar now sits below
the measurement rather than at a round number.

**★ THE SCRATCH IS ALLOCATED ONLY FOR `.implicit`** — `nbody × nv` six-vectors, about 29 kB on a
humanoid, and entirely dead weight for the three integrators that never form that matrix.

## ★★★ THE DEFAULT INTEGRATOR DID NOT HANDLE DAMPING — MuJoCo'S DOES

Chasing why a hand-built arm would not track a commanded pose, past two contact bugs and a
controller rewrite, the actual cause was the integrator.

**Explicit integration of a damping force is stable only while `c·h/I < 2`.** Generous for a
shoulder, very tight for anything light. On the arm, the mass diagonal at the wrist is
**0.00041** against 0.13 at the shoulder — three hundred times smaller — so an unremarkable
`damping="0.5"` gives `c·h/I = 2.44` and the velocity flips sign and grows every step:

    damping 0.50  ->  |v| = 100.000   (the velocity clamp: diverged)
    damping 0.05  ->  |v| =   1.06
    damping 0.00  ->  |v| =   0.17

**★★ AND THE SYMPTOM WAS NOT AN EXPLOSION.** A velocity alternating sign integrates to nearly
nothing, so the POSITION sat almost still. It reads as a badly tuned controller, not a broken
integrator — **two rounds of gain-hunting and an inertia-scaling rewrite went past it.**

**★ "MuJoCo'S DEFAULT IS EULER" IS TRUE AND MISLEADING.** `mj_Euler` is explicit only while no
DOF is damped; the moment one is, it forms `qH = M + h·diag(B)`, factors that, and solves.
Matching it is not adopting an exotic integrator — it is finishing the ordinary one. Verified in
`engine_forward.c`.

`factorM` now takes an optional damping impulse; the damping goes on the FACTORISATION and not
on `mass_matrix`, which the constraint solver and `massDiagonal` both read and which must keep
meaning inertia. The plain factorisation is restored afterwards, since `qLD` is shared scratch.
A model-level `has_dof_damping` flag picks the path once at build time, so an undamped model
pays nothing.

**Measured after: pure tree dynamics settle to |v| = 0.03 where they used to pin at 100.**

**★ AND A TEST THAT DOCUMENTED THE LIMITATION HAD TO CHANGE.** `implicit: stable where Euler
explodes` asserted `results[0] >= 99.0` — Euler running away in two steps. That was true and it
was a limitation rather than a law. It now asserts both integrators stay bounded, and says why
the number changed. `implicitfast` still earns its place: it covers the whole velocity
derivative including tendon coupling, where Euler covers joint damping only.

### And a control-layer option that came out of the same hunt

`PoseHold.scale_by_inertia` divides the gains by each joint's own inertia, so `kp` becomes ω²
and `kv` becomes 2ζω — a frequency and a damping ratio rather than torque numbers that only mean
something next to a particular link.

**★ IT IS OFF BY DEFAULT ANYWAY.** Switching it would silently reinterpret every gain any caller
has tuned, and several here were MEASURED rather than guessed — the Go1's kp = 100 and the
humanoid's kp = 400 both sit in narrow experimental bands. Quietly changing what they mean is a
worse failure than making callers ask, because it looks like the robot changed.

## ★★★ TWO CONTACT-FILTERING BUGS, FOUND BY BUILDING THE GRIPPER

The pick-and-place demo has not shipped, and chasing why it would not work turned up two real
engine defects that every jointed robot was living with.

### 1. MuJoCo's PARENT FILTER was missing entirely

**Two links joined by a hinge OVERLAP near that hinge, always, by construction** — that is what
a joint looks like geometrically. Reporting those overlaps as contacts gives a limb that fights
itself the moment it folds. Measured on a 4-DOF arm commanded to a reachable pose: `wrist`
against `right_finger` — a parent and its own child — **two contacts that never cleared**, with
the elbow pinned 0.43 rad short however long it ran and whatever the gains.

MuJoCo does this in `filterBodyPair`, and the rule has three clauses:

    same weld body                     -> skip
    both DOF-less                      -> skip   (we had this, as `isRigid`)
    either is the other's weld parent  -> skip   (we had NOTHING)

**★ WELD, NOT PARENT.** A chain of jointless bodies is ONE rigid object however many links it is
written as, so the relation is "same rigid piece, or adjacent rigid pieces" — filtering on the
raw parent would miss a decorative link sitting between two real ones. `weld[b]` is the nearest
ancestor reachable without crossing a joint, computed parent-first in one pass because
`buildRuntime` guarantees that ordering.

**★ AND NEITHER SIDE MAY BE THE WORLD.** A body resting on the ground has the world as its weld
parent, and filtering that would drop every floor contact there is.

### 2. The SWEPT path bypassed both filters

`onContact` applies them; `recordSweptContact` pushes straight into `harvest` and applied
neither. So the continuous-collision code I added for projectiles was manufacturing exactly the
self-contacts the filter exists to remove.

**★ TWO PATHS TO THE SAME OUTPUT MUST SHARE THE SAME RULES.** Adding a second producer of
contacts without giving it the first one's filters is the whole of this bug, and it will be true
of the next producer too. Worth stating next to the code rather than learned again.

**Result:** contacts went 2 → 0 on the folding test, and a deliberately over-folded two-link arm
now reports **not one contact** and stays where it is put.

### What is still wrong with the arm, and what it is not

The arm still tracks a commanded pose to only ~0.5 rad on some poses, with the wrist joint's
torque saturated. **A/B'd with the equality coupling removed: identical.** So it is not the
coupling, and it is not contact any more. The KUKA, Go1 and humanoid all track fine, which
points at the hand-built model's masses and gains rather than the engine — but it is unproven
either way and should not be assumed.

**Next:** find the arm's tracking problem (start by checking whether `PoseHold`'s gravity
compensation is saturating the wrist), then build the demo.

## ✅ THE ARM TRACKS — and the fix was the option built for it two turns earlier

Three engine bugs were found chasing this (parent-child filter, swept path bypassing filters,
implicit damping). None of them was the last one. **The controller was.**

    scale_by_inertia = false, kp 600, kv  25:  worst joint error 0.50000   max|v| 100.000
    scale_by_inertia = true,  kp 2500, kv 100:  worst joint error 0.00005   max|v|   0.000

`kp = 600` on a wrist whose mass-matrix diagonal is 0.00041 gives ω·dt ≈ 2.4 — past the
explicit limit, so the joint diverged and pinned at the velocity clamp while its POSITION sat
still, reading as "stuck". With the gains in frequency units it tracks to fifty microns.

**★ THIS IS THE MODEL `scale_by_inertia` EXISTS FOR**, and it stays off by default anyway — the
Go1's kp = 100 and the humanoid's kp = 400 are measured numbers in narrow bands, and silently
reinterpreting them would look like the robot changed. A model whose links differ by three
orders of magnitude turns it on.

### ★★ AND THE REMAINING FAILURE WAS MY TARGETS, NOT THE ROBOT

With the controller fixed, low grasps still self-collided — 1 or 2 contacts, missing by 16 cm.
Two rounds went into blaming the model's geometry (slimming the base, thinning the links) for
almost no change. **The measurement that settled it took one command: at the ready pose, zero
contacts.** The arm is clean at rest; only IK poses reaching DOWN fold it into itself.

    (0.30, 0.00, 0.55): ik 0.0005  miss 0.0005  contacts 0
    (0.38, 0.00, 0.45): ik 0.0003  miss 0.0003  contacts 0
    (0.30, 0.25, 0.50): ik 0.0009  miss 0.0009  contacts 0
    (0.45, 0.00, 0.55): ik 0.0009  miss 0.0009  contacts 0
    (0.25,−0.30, 0.48): ik 0.0006  miss 0.0006  contacts 0

Five targets at the arm's natural working height: **sub-millimetre, zero contacts, every one.**

**★ IK DOES NOT KNOW ABOUT COLLISION** — nor does MuJoCo's — so a reachable-looking solution can
fold a limb through its own base, and the solver will report a tiny error for a pose the robot
cannot occupy. That is not a bug to fix; it is a constraint on where a demo puts its objects.

**The demo needs a TABLE**, with the object at z ≈ 0.45–0.55 where the arm works naturally.

### ★★★ AND THE TABLE MAKES IT WORSE, WHICH IS THE REAL LESSON

With a table added at the arm's working height, the cube rests perfectly — `(0.450, 0.000,
0.470)`, unshifted, four clean contacts — and **the arm now collides with the TABLE** on its way
to a target directly above the cube. Five contacts, missing by 0.155.

The five free-space targets that reached to sub-millimetre had no obstacle in the workspace.
Putting one there is exactly what a pick-and-place scene does, and **IK is collision-blind**, so
every waypoint has to be chosen by a human who can see the obstacle. That is not a defect in
this engine — MuJoCo's IK is equally blind — but it decides what a demo can be.

**★ AND ONE MORE SELF-INFLICTED ROUND WORTH RECORDING.** The first table spanned x from 0.10,
straight through the forearm's resting position at x = 0.163: the arm began embedded in the
furniture and the cube was fired to `(−1.894, 1.452)`. A scene's obstacles have to be placed
against the robot's ACTUAL rest pose, which takes one print of `body_xpos` and was skipped.

### Reassessment: is pick-and-place the right demo?

Parts of four turns have gone into it. What it exercises — equality coupling, IK, contact — is
all separately verified by tests already. What it additionally needs is **collision-aware
waypoint choice**, which is a planning problem this engine does not claim to solve and which no
amount of iterating on cube positions substitutes for.

**Two honest options**, and the next turn should pick deliberately rather than continue:

1. **Ship it as a hand-driven demo** — sliders for the IK target and the gripper, no scripted
   sequence. The user avoids the table with their own eyes, which is what the demo is FOR:
   showing IK and a coupled gripper working. Small, and it lands.
2. **Drop it and take push-recovery or ragdoll instead** (plan items 7), which need no
   obstacle avoidance and reuse the CM Jacobian already built.

**✅ OPTION 1 SHIPPED — `examples/gripper/`.**

Sliders for the IK target (x, y, z) and one slider for the gripper. The right finger is not set
by the demo at all: an `<equality type="joint" polycoef="0 -1">` ties it to the left and the
SOLVER moves it, which is what a parallel gripper physically is.

**★ `reach err` IS THE POINT OF THE PANEL.** Drag the target down and toward the base and it
climbs — that is the solver telling you the truth about a pose it found and the robot cannot
hold. A scripted sequence would have hidden exactly that.

Three API mismatches came from copying the quadruped's shape without checking its calls:
`loadFont` takes a frame and an allocator, `u.window` returns an optional handle rather than a
bool, and the mesh generators take an ALLOCATOR and a slice count. Each was a one-line fix and
none would have existed if the working file had been read rather than remembered.

## 🔄 PICK AND PLACE — the model works, the demo is not built yet

`src/tests/fixtures/robot/arm_gripper.xml`: a 4-DOF arm with a two-finger gripper closed by
`<joint joint1="right" joint2="left" polycoef="0 -1"/>`. Imports as 7 bodies, nv 12 with a cube
in the scene, and **the coupling mirrors correctly** — commanding the left finger moved the
right to −0.0514 against +0.0512.

**★★ AND A FINDING WORTH MORE THAN THE DEMO: A MODEL NEEDS A READY POSE.**

With every joint at zero the arm stands straight up, which is a SINGULAR configuration — the
Jacobian has no preferred direction, so IK starting there picks one arbitrarily. Measured:

    goal ( 0.30, 0, 0.05)  ->  ended (−0.50, 0, 0.45)   the opposite side of the robot
    goal ( 0.25, 0, 0.30)  ->  ended (−0.50, 0, 0.45)   same corner, whatever was asked

A `<key name="ready" qpos="0 0.5 -1.0 0.5 0 0"/>` with a bent elbow costs nothing and removes
the ambiguity entirely. **This is why real models ship a keyframe** — not obvious until a
hand-built model did not have one. Worth remembering when importing anything whose `qpos0` is
all zeros: the first IK call from that pose may swing the arm somewhere absurd, and it is the
model's fault rather than the solver's.

**Joint ranges were the second limit.** Nothing reached below z = 0.35 until `lift`, `elbow` and
`pitch` were widened; after that six targets across the workspace land within 2 cm, four within
a millimetre.

**Still to build:** the demo itself — reach, close, lift, place — which wants a turn of its own
rather than being rushed onto the end of this one.

## ✅ NEWTON — BUILT, AND IT CLEARS THE ACCEPTANCE TEST BY FIVE ORDERS OF MAGNITUDE

Six-box stack, 96 rows, cold solve from the settled state:

| | 1 | 2 | 5 | 20 | 100 |
|---|---|---|---|---|---|
| **PGS** | 26.7 | 16.6 | 13.4 | 4.83 | 0.269 |
| **Newton** | **0.0000004** | **0.0000005** | converged | converged | converged |

**Newton converges in TWO iterations and the stack stands** (top box at 0.5471, its correct
height). PGS is still falling at a hundred and drops the stack to the floor. The bar the plan
set — "Newton at 5 must beat PGS at 100" — is cleared by a factor of half a million.

### How it works, and why the pieces are what they are

Constrained dynamics is a convex minimisation in ACCELERATION space:

    L(a) = ½·(a − a_free)ᵀ M (a − a_free)  +  Σ over active rows  ½·(Jᵢ·a − aref_i)² / R_i

The first term says "stay near the acceleration you would have had" — that is `free_acc`,
already computed. The second penalises each violated row.

    ∇L = M(a − a_free) + Jᵀ D r        H = M + Jᵀ D J

**`H` is EXACT, not an approximation**, which is what buys quadratic convergence and is the
entire difference from sweeping rows.

**★ THE ACTIVE SET IS RE-DECIDED EVERY ITERATION**, because a unilateral row contributes to the
cost only while violated. That makes `L` piecewise quadratic rather than quadratic, and is
exactly why the LINE SEARCH is not optional: a full Newton step can cross into a region where a
different set of rows is active, where it is no longer the minimiser.

**★ CHOLESKY, NOT LU.** `H` is symmetric positive definite — `M` is, and `Jᵀ D J` is positive
semi-definite for `D ≥ 0` — so Cholesky is valid and half the work. It falls back to the
gradient direction if the factorisation fails, which is always a descent direction and merely
slower.

**★ DENSE IS THE RIGHT CALL.** `H` is nv×nv where nv is tens, and `Jᵀ D J` fills in the moment
two contacts share a body — which in a stack is every pair.

### PGS REMAINS THE DEFAULT, and not grudgingly

At FIVE iterations PGS gives a stack height error of 0.00308 against MuJoCo Newton's 0.00273 and
**MuJoCo PGS's 0.01386** — already Newton-class and 4.5x better than MuJoCo's own PGS, because
the exact `Â` diagonal and the stall check do real work. Most scenes never reach the coupled
regime where Newton's asymptotics matter, and PGS is far cheaper per iteration.

### ✅ AND THE COST IS MEASURED — the crossover is real, and so is the parity

`robot_bench`, Go1 standing, nv 18, sixteen rows, 200 000 steps:

| | ns/step | solver iterations |
|---|---|---|
| **ours, PGS** | **10 876** | 3 |
| ours, Newton | 19 989 | 2 |
| MuJoCo (Newton is its default) | 20 209 | |

**Newton uses fewer iterations and costs twice as much**, exactly as O(nv³) predicts. Both reach
the same answer — trunk at 0.3325, still standing.

**★★ AND THE COMPARISON THAT MATTERS: Newton against Newton, we are at PARITY with MuJoCo**
(19 989 against 20 209). Our PGS is **1.86x faster than either**. The earlier "2.0x faster than
MuJoCo" figure was PGS against MuJoCo's Newton, which is a fair thing to report only alongside
this — a like-for-like number and a best-configuration number are different claims.

**So PGS stays the default, now measured rather than assumed**: it is nearly twice as fast on
the case robots actually spend their time in, and Newton is there for the coupled cases where
PGS cannot converge at all.

## ★★★ THE NEWTON GAP, MEASURED — and it is the largest remaining one

PGS has been "good enough" on every case measured so far, and the Go1 benchmark has it 1.6x
faster than MuJoCo. This is where it stops being good enough, with numbers.

**A six-box stack, 96 contact rows, one cold solve:**

| iterations | 1 | 5 | 20 | 40 | 100 |
|---|---|---|---|---|---|
| residual | 26.7 | 13.4 | 4.83 | 1.11 | **0.269** |

Roughly linear convergence, halving every ~15 iterations, and **still not converged at 100**.
MuJoCo's Newton reaches its answer in FIVE on the same problem — its height error is identical
at 5, 20 and 100 iterations — and MuJoCo's own PGS needs about 20.

**★ THE STACK COLLAPSES.** Settled for a second at 200 iterations, the top box ends at z = 0.049
— on the floor. MuJoCo holds it at every solver and iteration setting tried.

### What the earlier, worse benchmarks taught

**A tall tower is chaotic, not a solver benchmark.** Sweeping the iteration cap over a long
simulation gave: cap 20 collapses, 30 holds, 40 and 50 collapse, 60–100 hold. That is not
convergence quality, it is a metastable equilibrium deciding differently on rounding. **The
honest measurement is the residual after ONE solve from a fixed state**, where nothing has time
to amplify.

**And the first mass-ratio test proved nothing**: a 500:1 stack in MuJoCo, where both solvers
agreed exactly because both let the heavy box sink through. Agreement between two wrong answers
is not a comparison.

### Where PGS still wins, and why this is not a rout

At FIVE iterations ours gives a height error of 0.00308 against MuJoCo Newton's 0.00273 and
MuJoCo PGS's 0.01386 — so at low iteration counts our PGS is already Newton-class and **4.5x
better than MuJoCo's own PGS**. The exact `Â` diagonal and the stall check are doing real work.
The gap is specifically *asymptotic*: PGS cannot drive 96 coupled rows to zero, however long it
runs.

### Newton, concretely

MuJoCo minimises a convex objective over accelerations rather than sweeping rows:

    min over a:  ½·aᵀ M a  +  s(J a)      s = the constraint cost, smooth and convex

with the Newton step solving `(M + Jᵀ D J)·Δa = −∇`, `D` the cost's Hessian, plus a line
search. The pieces already exist — `factorM`, the row Jacobians, `constraintResidual` — and what
is missing is the Hessian assembly, a Cholesky of the reduced system, and the line search.

**This is a multi-turn job and should be treated as one**, with the residual table above as the
acceptance test: Newton has to reach at 5 iterations what PGS does not reach at 100.

## ✅ IK ORIENTATION — the gap the gripper demo exposed

`Ik` placed a POINT. Enough for a foot, which only has to be somewhere; not enough for a hand,
because **a top-down grasp is a statement about direction** and a position-only solver returns
whatever attitude its nullspace drifted into. Measured on the demo: the jaws sat sideways at
rest and no choice of target position changed it.

`IkTarget.orientation` adds three rows to the same Jacobian.

**★ THE ERROR IS A ROTATION VECTOR.** `wanted · current⁻¹` is the rotation still to perform; a
quaternion's vector part is half the rotation vector to first order, so `2·vec` is the error in
radians about each world axis — the units the angular Jacobian already produces. And `q` and
`−q` being the same rotation, the positive-`w` one is taken, so a target 179° away corrects by
1° rather than 359°.

**★★ THE SOLVE IS WRITTEN FOR N ROWS, NOT FORKED.** The position-only path is the same code with
the orientation half skipped, so it cannot drift away from the six-row one. That meant replacing
the hand-written 3×3 cofactor inverse with a Cholesky — `J·Jᵀ + λ²I` is a Gram matrix plus a
positive diagonal, so it is symmetric positive definite by construction, and cofactors at six
would be unreadable.

**★ `angle_weight` AFFECTS ONLY THE REPORTED NUMBER**, never the solve. The two halves are in
different units — metres and radians — and none combines them honestly, so `error_distance`
stays the distance a caller can act on, with the angle folded in just enough that a converged
position cannot claim success while the wrist points backwards.

A test asserts both solvers reach the point and only one aims: adding three rows must not cost
the three that already worked.

## ✅ THE ARENA LEAK — found, fixed, and guarded

`readRobot` and `readDefaults` built into a **stack-local** `ArenaAllocator` and returned the
struct **by value**. An `Allocator` taken from an arena holds that struct's ADDRESS, so every
allocator handed out during construction pointed at a dead frame.

**`robot.zig` documents this exact hazard on `Model.arena`.** The answer was one file away for
two sessions.

**Why it hid:** a single-buffer arena survives the move by luck. `sensors.xml` was the only
fixture whose parse grew the arena past a second buffer, and only optimised builds laid the
stack out so it showed — hence a 3324-byte leak, ReleaseSafe only, one file out of five.

**★ THE RULE IS NOT "never store an arena by value".** Two other structs do and are correct:
`frame_arena` and `zimrphysics.World.scratch_arena` both take their handle from a struct that
has already stopped moving. The bug is: *an allocator was taken, memory was allocated through
it, and then the struct moved.* The check is not a grep for a type.

**Guarded two ways**, because a comment did not stop it the first time:

* a `@compileError` if `Robot.arena` ever stops being a pointer — reverting it now fails to
  BUILD, not at test time;
* a test that reads every arena-owned slice after the return, on the Go1, whose parse is large
  enough to need the second buffer that made the bug detectable at all.

**And the tool that closed it:** `src/leakwatch.zig`, a scope-labelling allocator wrapper with a
`watch_size` trace. Setting it to 3324 counted **zero** allocations of that size in the whole
sequence — which is what turned the search from "which of our calls leaks" into "what is holding
memory we never requested".

## ✅ `Batch` — N environments, one model, one matrix

**★ THE FLAT LAYOUT IS THE POINT, not the loop.** Observations come back as one contiguous
`count × observationSize` buffer, row-major, and actions go in the same shape. A policy wants a
matrix; handing it a slice per environment forces a copy at exactly the boundary where copies
are expensive. The stepping loop itself is four lines.

**★★ IT STEPS SERIALLY, AND THAT IS A DECISION RATHER THAN A PLACEHOLDER.** zimr's primary
target is a browser tab, which has one thread. `jobs.zig` — the sanctioned parallel path — is a
message-passing kernel registry for shipping buffers to workers, not for touching in-process
memory. `std.Thread` would work natively and not at all where this engine actually runs.

The loop body touches only its own `Env` and a read-only `Model`, so parallelising later is a
change of scheduler and not of design. **Claiming it now would be a lie with a `for` loop behind
it.**

**Verified bit-for-bit against solo runs.** Four environments with four different action rows,
600 steps: each matches the same environment run alone, exactly. `robot.zig` already proves the
underlying independence; this checks the layer above, where an indexing slip in the observation
matrix would be just as invisible and considerably more likely — and the test asserts the row
stride explicitly, because an off-by-one there gives every environment its NEIGHBOUR's
observation: plausible numbers, wrong entirely, and no test of the physics would notice.

## ★★★ AUDIT — what is verified against MuJoCo, and what was merely believed

Asked what to do next, the useful question turned out to be: **which subsystems are checked
against the reference, and which are checked only by "it looks right"?**

| subsystem | oracle |
|---|---|
| forward kinematics | MuJoCo's `xpos`, every body, 1e-4 |
| mass and inertia | MuJoCo's `body_mass`, trace-matched |
| sensors | MuJoCo's `sensordata` |
| equalities | MuJoCo's `eq_data`, including the derived anchor |
| integrators | an rk4 reference at dt = 1/20000 |
| Coriolis derivative | finite differences, every joint kind |
| **the SOLVER** | **behaviour only — until now** |

**★ "THE ROBOT STANDS" IS A WEAK ORACLE.** Many wrong solvers make a robot stand. A constraint
force 10% high still supports a box; it surfaces later as a foot that bounces, a grip that
crushes, or a policy that learns to exploit a contact model no real robot has. The solver is the
most complex code here and it was the least externally validated.

### ✅ Closed: the solver's FORCES now match MuJoCo

A 2 kg box resting on a plane — chosen because the answer is known without either engine, since
a resting body must carry exactly its own weight:

    MuJoCo (Newton, 200 iters, tol 1e-12):   z 0.099892   qfrc_constraint[2] 19.62
    ours, PGS:                               z 0.099878   qfrc_constraint[2] 19.620
    ours, Newton:                            z 0.099878   qfrc_constraint[2] 19.620

`m·g = 19.62 N` exactly, on both solvers. Sixteen rows in all three — four contact points, four
pyramid edges each — so the two engines are solving the SAME problem, not reaching similar
answers from different ones. Resting depth agrees to 1.4e-5, which is the softness constant
behaving identically.

The test also asserts **zero tangential force**: a friction pyramid that is not symmetric about
the normal leaves a residual a resting box would slide under, slowly enough that no behavioural
test would catch it.

### What the audit found healthy

* **No TODOs, no unimplemented paths, no swallowed errors** across all six robot modules.
* `robot.zig` is 11 759 lines but **35% of that is tests**, and its largest single item is 542
  lines. Big, not tangled.
* Nothing in the robot modules touches threads — correct for a wasm-only target.

### ✅ AND THE LAST TWO: actuators and tendons

**Every actuator transmission, at q = 0.3, v = 1.4, ctrl = 0.7** — each number derivable without
either engine, which is what makes it an oracle rather than two guesses agreeing:

    motor,    gear 2.5  ->  ctrl · gear      = 0.7 × 2.5   =   1.75
    position, kp 30     ->  kp · (ctrl − q)  = 30 × 0.4    =  12.0
    velocity, kv 5      ->  kv · (ctrl − v)  = 5 × (−0.7)  =  −3.5

MuJoCo reports 1.75, 12.0, −3.5. So do we, exactly. **The sign on `velocity` is the one worth
having pinned** — negative because the joint is moving faster than commanded, so the actuator
brakes. A sign slip passes every behavioural test that only accelerates from rest.

**A fixed tendon**, coefficients 1.0 and −0.5 at q = (0.4, −0.2), v = (1.1, 0.6):

    length 0.5    velocity 0.8    force −18.4    spread: j1 −18.4, j2 +9.2

Three things can be independently wrong — the length, its rate, and the transpose that spreads
the force back — and a behaviour test sees only their product. **The sign flip on j2 is the
part that matters**: a negative coefficient is how a differential is built, and dropping it in
the transpose couples the joints the wrong way while still looking like a spring.

### Every subsystem now has an external oracle

| subsystem | oracle |
|---|---|
| forward kinematics | MuJoCo `xpos`, every body, 1e-4 |
| mass and inertia | MuJoCo `body_mass` |
| sensors | MuJoCo `sensordata` |
| equalities | MuJoCo `eq_data` |
| **solver forces** | MuJoCo `qfrc_constraint`, and `m·g` |
| **actuators** | MuJoCo `qfrc_actuator`, all three kinds |
| **tendons** | MuJoCo `ten_length` / `ten_velocity` / `qfrc_passive` |
| integrators | rk4 at dt = 1/20000 |
| Coriolis derivative | finite differences, every joint kind |

### Remaining, and none of it is verification

Spatial tendons, deformables, SDF collision, muscle actuators. Each is something a specific
model would need; none blocks a legged robot, an arm, or a policy.

## 🔄 THE LIVE LEARNING DEMO — the learning is verified, the UI is not built

Learning-before-UI this time, because the last several demo turns each needed a round of
on-device fixes. **A cartpole and cross-entropy method on a 4-weight linear policy solves it on
this engine**, elite score by generation (max 500):

    start ±0.10, fail past 0.30:  215 → 500 by gen 4
    start ±0.15, fail past 0.25:  178 → 471 → 500
    start ±0.18, fail past 0.21:  150 → 489 → 500

CEM needs no gradients and is about twenty lines, which is what a demo wants: the whole training
algorithm fits on screen beside the robot it is training.

### ★ A TEST DESIGN BUG CAUGHT BY A SUSPICIOUS NUMBER

The first sweep plateaued at exactly **375 and 250** — three quarters and one half of the
maximum. Those are not ceilings. The initial tilt exceeded the failure limit, so a fixed
fraction of episodes **scored zero before the policy acted**. A plateau at a round fraction of
the maximum is arithmetic, not a learning curve, and it would have been easy to report as "the
policy's limit".

### ✅ AND A REAL PERFORMANCE BUG FOUND BY BENCHMARKING IT

Cartpole is nv 2, and `Env.step` was taking **1168 ns** — against 247 for the two-link arm
benchmark, the same size problem without the wrapper.

`Env.step` called `rbt.forward` and then `rbt.step`. **`rbt.step` forwards internally** — every
integrator branch begins with one, because it cannot advance a state it has not derived. The
explicit call recomputed the whole kinematics, mass matrix and bias for nothing, on the hot path
of every rollout.

    1168 ns  ->  824 ns          one CEM generation: 93.4 ms  ->  65.9 ms

The second `forward` stays and is not redundant: `step` leaves the state stale by design, and an
observation read from stale body poses is last frame's.

**Feasible live:** ~66 ms per generation worst case, most episodes ending early, and six
generations to solve. Spread over frames that is under a second of wall time with the robot
visible throughout.

**✅ BUILT — `examples/cartpole/`.** The cartpole rendered, the elite-score curve plotted beside
it, the four policy weights and their spread shown as numbers, and a `generations / frame`
slider. Turning it up makes the curve climb and the frame rate drop, which is an honest thing
for a demo to show rather than hide.

**★ TWO ENVIRONMENTS, ONE MODEL.** The displayed robot runs the current best policy in its own
`Env` while training runs in another — sharing one would make the display flicker through forty
policies a frame. That this is safe is exactly what `robot.zig`'s independence proof buys.

**★ THE POLICY IS FOUR NUMBERS, ON SCREEN.** Watching them move is most of what makes the demo
legible: the search is not a black box, it is a Gaussian walking across a plane.

**★ AND A CEM DETAIL WORTH THE COMMENT IT GOT:** the spread has a floor. Without one the
Gaussian collapses onto the first decent policy it finds and the search stops — the classic
failure, and it looks like convergence rather than like giving up.

## ★★ THE RAGDOLL — the solver difference in a real scene

A 27-DOF humanoid dropped on its side with **no control at all**. That is the hardest thing a
contact solver is routinely asked to do: a limp body has no actuator holding anything, so every
joint is free to be pushed by every contact.

Six seconds after landing, from two heights:

| | peak contacts | settled \|v\| |
|---|---|---|
| PGS, from 1.2 m | 16 | **2.67** |
| Newton, from 1.2 m | 15 | **0.41** |
| PGS, from 2.5 m | 15 | **1.39** |
| Newton, from 2.5 m | 15 | **0.24** |

**★ BOTH REACH THE SAME POSE** — pelvis at z 0.177 either way — so this is not PGS getting the
answer wrong. It is PGS not getting all the way there: fifteen coupled rows, linear convergence,
and a residual that reads on screen as a body which will not stop twitching.

**★★ AND THIS IS THE CASE FOR HAVING BOTH SOLVERS.** PGS is the default and 1.86x faster on a Go1
holding its pose — sixteen rows, little coupling. A ragdoll is the other regime. Choosing per
scene is the whole point, and this is the first scene where the choice is visible rather than
arithmetic.

The test asserts the CAPABILITY (Newton settles it) rather than the deficiency, with the bar set
where PGS's 2.67 fails and a genuine settle passes.

**✅ BUILT — in `examples/humanoid/`, not a new demo.** A `limp` checkbox that stops the
controller, a `drop it` button that lifts and tips the body, a live PGS/Newton switch, and the
**peak joint speed on screen** — because the difference between the solvers is a residual
velocity, and no one can eyeball 2.7 against 0.4. Toggle the solver and watch the number.

**★ THE LIVE SWITCH NEEDED THE MODEL BUILT FOR NEWTON.** Its working set is sized once at
`Data.init`, so a model built for PGS cannot become a Newton one later. Building the other way
round is free — Newton's buffers go unread while PGS is selected — and getting it backwards now
hits the assert added during the review rather than writing past an empty slice.

**★ AND A RAGDOLL IS THE CONTROLLER NOT RUNNING**, not a different model. One `if`.

## THE RAGDOLL CREEP — investigated, one cause confirmed, one still open

A landed ragdoll slides slowly. Reported from the demo, then chased with instrumentation.

### What it is NOT — three hypotheses killed by measurement

* **Not warm-start churn.** The key match rate is **99.9%**. A first pass compared contact ids
  naively and reported "13-31 changes per half second", which sounded damning and was an
  artefact of the comparison rather than of the solver.
* **Not angled contact normals.** All fourteen normals are vertical to 0.0 degrees and their
  horizontal components sum to 0.0012. No sideways push from penetration recovery.
* **Not a solver difference.** PGS and Newton drift identically.

### CONFIRMED CAUSE: contact friction is a hardcoded 0.5

Every contact carries mu = 0.5 regardless of anything. Two independent drops:

* the model's own `friction=".7"` is discarded at import — `robot_mjcf.zig` says so outright;
* the floor body's friction never arrives either, because `settings.friction` is null for these
  pairs and `default_friction` applies.

Confirmed by drift being **identical to four decimals** across floor mu 0.2 to 1.0.

**AND IT MATTERS.** Rebuilt with `default_friction = 0.7`, the model's own value:

| | drift at t = 28 s | per-interval |
|---|---|---|
| ours at mu 0.5 | 0.109 and **growing** | 0.016 -> 0.109 |
| ours at mu 0.7 | **0.076** | steady at 0.016 |
| **MuJoCo** | **0.071** | decaying |

From accelerating to steady, and within 7% of MuJoCo. **The fix is to plumb friction through** —
MJCF geom to `Model` to proxy body to contact — the same path the swept-contact fix took.

### AND THE CREEP ITSELF IS REAL PHYSICS

MuJoCo creeps too, on the same model and drop: 0.071 m over 25 s. This humanoid's joints carry
**springs** (`stiffness` on 19 of 22 joints, total 124), so a body lying in a pose its springs
dislike works its way around like a wind-up toy. That is the model, not the engine.

### FRICTION: FIXED, and the chain was broken in FIVE places

MJCF parsed it correctly; `robot_mjcf` discarded it with a comment saying so; `Model` had
nowhere to put it; the proxy body was created without it; and `onContact` fell through to a
hardcoded 0.5. Any one of those gives the same symptom.

All five repaired — `GeomSpec.friction` to `Model.geom_friction` to the proxy body to a
geometric mean at contact time. **Drift now 0.0705 m against MuJoCo's 0.071**, within 1%, and
steady rather than accelerating. A test walks the whole chain rather than its end, so a future
break is attributed to the link that broke.

### AND THE INTEGRATION IS EXACT

One hinge, damping 5, stiffness 10, armature 0.01, no gravity, no contacts — the reductive case
that isolates passive-force integration completely:

    t (s)          0.5       1.0       1.5       2.0       2.5       3.0
    MuJoCo    0.293761  0.105959  0.038219  0.013786  0.004972  0.001794
    euler     0.293761  0.105959  0.038219  0.013786  0.004972  0.001794
    implicit  0.293761  0.105959  0.038219  0.013786  0.004972  0.001794

**Identical to six decimals.** So damping, springs and armature are integrated correctly and the
remaining energy is coming from somewhere else.

### STILL OPEN: joint velocities are 10x MuJoCo's

Even with friction corrected, the limbs keep moving far more than they should:

    MuJoCo   max joint |v|  0.014 - 0.134
    ours     max joint |v|  0.34  - 2.40

Parameters import correctly and are integrated exactly (above), so **the energy is entering
through the contact solve.** Narrowing it further stalled, and the stall is worth recording:

**A PROBE THAT WAS WRONG TWICE, THE SAME WAY.** Chasing a suspected deep penetration, the
capsule's lowest point was computed as `centre − radius − half_height`, which is only true for a
VERTICAL capsule. The foot capsules lie flat, so this manufactured a 9.4 cm penetration for a
foot sitting 4.1 cm clear of the floor. A second attempt corrected for the axis and still
disagreed with every capsule — while the two SPHERES matched the reported depth exactly, to five
decimals.

**Two spheres agreeing exactly is the tell**: the reported depths are right and the probe's
geometry is wrong. Nothing here is evidence of a contact bug, and it would have been easy to
report one.

## ✅ ANALYTIC CAPSULE×CAPSULE — and the axis bug it exposed

Legs passed through each other because capsule×capsule reached `collideConvexGeneric`, which
**fails exactly where two legs press together**:

    gap  0.010   depth -0.0880   2 points   correct
    gap  0.000   depth -0.0980   NONE       *** 9.8 cm of overlap, no contact
    gap -0.010   depth -0.1080   2 points   correct

At zero gap the axes are coincident, the GJK simplex is degenerate, and nothing comes back.
`collideCapsuleCapsule` does segment-to-segment closest approach then a sphere-sphere test —
closed form, and **the parallel case gets its own branch**, which is precisely what an iterative
solver cannot supply: when the axes are parallel the 2×2 system is singular and every point of
the overlapping span is equally close, so the midpoint is taken.

### ★★★ AND IT SURFACED A 90° AXIS ERROR THAT WOULD HAVE SHIPPED SILENTLY

First written assuming a capsule's axis is its local **+Z**. It is **+Y** — `supportPoint`
returns `vec(0, up, 0)`. The consequence, in the standing pose:

    ours, +Z (wrong):  thigh_right ends (-0.010, -0.265, 0.642) .. (-0.010, 0.075, 0.652)
    MuJoCo:            thigh_right ends (-0.010, -0.090, 0.477) .. (-0.010, -0.100, 0.817)

Both thighs lying ACROSS the body instead of down it, overlapping by 12 cm where MuJoCo measures
them 6 cm apart. **The centres were right, so the robot still looked correct** — only the
collision axis was turned ninety degrees, and nothing reported contacts from that pair until
this routine started asking.

★ THE CATCH WAS THE HUMANOID GATE, which collapsed to 0.082 m. And the diagnosis came from
asking MuJoCo the same question directly — `mj_geomDistance` said **+0.06** where we said
**−0.12**, and a brute-force sweep of our own geometry agreed with our number, which located the
disagreement in the GEOMETRY rather than in the new routine.

**Verified:** standing home pose now gives **8 contacts, 0 self — exactly MuJoCo's 8 and 0.**

## (superseded) the original capsule×capsule report

Reported from the device once the foot shaking was gone: **the legs pass through each other.**

The pair filter is not the cause — `weld_parent` only suppresses a body against its own parent,
so the two thighs are unrelated and their pairs do fire. What they reach is
`collideConvexGeneric`, the same GJK/EPA path that was degrading for capsule×box.

**★ AND IT FAILS EXACTLY WHERE TWO LEGS PRESS TOGETHER.** Measured, sweeping two parallel
capsules through one another:

    gap  0.010   depth -0.0880   2 pts   correct
    gap  0.000   depth -0.0980   NONE    *** 9.8 cm of overlap, no contact at all
    gap -0.010   depth -0.1080   2 pts   correct

At `gap = 0` the two axes are **coincident**, the GJK simplex is degenerate, and the routine
returns nothing. Legs resting against each other sit at exactly that configuration.

★ MuJoCo HAS `mjc_CapsuleCapsule` IN ITS TABLE — analytic, like every other primitive pair. Ours
does not, and capsule×capsule is the second-most-common pair a humanoid makes after
capsule×ground.

**The fix has the same shape as the one that just landed**: segment-to-segment closest approach,
then a sphere-sphere test at that point. The degenerate case — parallel, coincident axes — needs
an explicit branch, which is precisely what GJK cannot supply.

## ✅ ANALYTIC CAPSULE×BOX — landed, on the second construction

`collideCapsuleBox` now handles the pair a walking robot makes constantly: every foot, shin and
forearm against the ground. It was falling through to GJK/EPA, which **returns a depth of 8.5 m
once the overlap passes about 27 cm** — escaping through the side of a 12 m floor rather than
its top face.

**★ THE CLOSEST POINT ON THE SEGMENT, NOT THE END-CAPS.** The first attempt tested only the two
end-caps: exact for a capsule lying flat, and it returns NOTHING for one standing against a
wall, where the shaft does the touching. That collapsed the humanoid to 0.165 m and walked the
character controller through walls. `segmentBoxClosest` finds the real closest approach.

**★ TERNARY SEARCH, because point-to-box distance is convex along a segment.** An earlier
alternating-projection version stalled at a non-optimal fixed point whenever the segment ran
nearly tangent to a face — every failure sat on a box EDGE, off by up to 2 cm. Convexity in one
variable is a stronger property than convexity in two sets.

**Verified:** the full suite passes, including the humanoid stand gate and both character-walk
tests that the end-cap version broke. A foot-sized capsule dropped flat settles at z = 0.02700
against a radius of 0.027 — **error 0.00000 m**.

### And a real bug it uncovered in `collideSphereBox`

`clamp` leaves a point INSIDE the box exactly where it was, so `point_on_box` came out at the
sphere's own centre and the reported depth was a constant **−radius** however deep it had sunk.
The NORMAL was already right — that branch picks the nearest face — so only the point was
wrong, which is why nothing noticed: a sphere fully inside a box is rare, and while it is barely
inside the error is small. Capsule end-caps resting on the ground routinely are inside, so it
mattered immediately. Fixed by projecting to that same nearest face.

## 🔄 THE FIRST ATTEMPT — end-caps only, and what it taught

The approach is right. **My construction was too naive and the tests caught it.**

### What was built

`collideCapsuleBox` as two sphere-box tests at the capsule's end-caps — the same construction
MuJoCo uses for `mjc_PlaneCapsule`, reusing our already-analytic `collideSphereBox`.

**On the case it was designed for it is perfect.** A foot-sized capsule lowered through the
floor box, error against the capsule's true lowest point:

    lowest point   EPA reports    analytic     error
      -0.2670        -0.2670       -0.2670    0.000000
      -0.2870        -8.5449       -0.2870    0.000000
      -0.3470        -8.5449       -0.3470    0.000000

Exact at every depth, including where EPA escapes through the side of a 12 m floor.

### ★★★ AND IT BROKE THE HUMANOID GATE AND BOTH CHARACTER-WALK TESTS

Torso collapsed to 0.165 m against 1.282. **End-caps are not where a capsule always touches.**
A capsule lying flat on the ground contacts on its caps; a capsule standing VERTICALLY against
a wall contacts on its **shaft**, and the character controller is exactly that — a vertical
capsule against boxes. My routine returned `null` for it and the character walked through walls.

★ I HAD WRITTEN THAT LIMITATION IN THE DOC COMMENT and then scoped it wrongly: "on a large flat
floor the end-caps are the lowest points" is true for a HORIZONTAL capsule and says nothing
about a vertical one. **A limitation you have written down is not a limitation you have
understood.**

### ★★ AND IT UNCOVERED A REAL BUG IN `collideSphereBox` ON THE WAY

`clamp` leaves a point INSIDE the box exactly where it was, so `point_on_box` comes out at the
sphere's own centre and the reported depth is a constant **−radius** however deep it has sunk.
Invisible while only spheres use that path — a sphere fully inside a box is rare — and it is
what made the first analytic capsule attempt report −0.0270 at every depth.

**Not fixed, because it was not verified in isolation.** It is a genuine defect and worth its
own change, separately, with its own test.

### What a correct implementation needs

Not the end-caps but the **closest point on the SEGMENT to the box**, which is well-conditioned
and covers shaft contacts. MuJoCo's `mjraw_CapsuleBox` is about 250 lines of face/edge/corner
analysis for exactly this reason — the cases are genuinely numerous, and two endpoint tests are
not a shortcut through them.

**Everything is reverted; the tree is as it was.** The knowledge is the deliverable: EPA's
failure is now quantified, the architectural difference is understood, and the shape of the real
fix is clear.

## ★★★ HOW MuJoCo GETS CONTACTS vs HOW WE DO — the architectural difference

**MuJoCo dispatches through a table of ANALYTIC routines, one per primitive pair:**

    /*         PLANE  SPHERE          CAPSULE           BOX            MESH   */
    /*PLANE*/  {0,    mjc_PlaneSphere, mjc_PlaneCapsule, mjc_PlaneBox,  mjc_PlaneConvex}
    /*SPHERE*/ {                       mjc_SphereCapsule, mjc_SphereBox, mjc_Convex}
    /*CAPSULE*/{                                          mjc_CapsuleBox, mjc_Convex}

Only ellipsoid, cylinder and mesh pairs fall through to `mjc_Convex` (GJK/MPR). `mjc_PlaneCapsule`
is about twenty lines: take the capsule's two endpoints and run a sphere-plane test on each.
**Closed-form, exact at any depth, always up to two contacts** — and it aligns the contact frame
with the capsule axis, so the friction directions are stable frame to frame.

**We special-case FOUR pairs** — sphere×sphere, sphere×box, box×sphere, box×box — and everything
else goes to `collideConvexGeneric`, which is GJK then EPA. **Capsule×box is every foot contact
on this humanoid.**

### What the probe actually showed, which corrected the hypothesis

A foot capsule lowered through the floor box, asked of the pair dispatch directly:

    lowest pt   manifold   points   depth
     -0.0070      yes         2    -0.0070
     -0.1270      yes         2    -0.1270      exact
     -0.2670      yes         2    -0.2670      exact
     -0.2870      yes         2    -8.5449      *** garbage
     -0.3270      yes         2    -8.5449

**EPA does NOT drop the contact**, which was the theory. It returns two points at every depth
tested — and past about 0.27 m it returns a **depth of 8.5 m**, having picked an escape direction
out through the side of a 12 m wide floor. That is the classic EPA degeneracy: once deep enough,
the nearest face is no longer the right one.

★ SO THE `orelse return null` AT `collideConvexGeneric`'s EPA CALL IS NOT FIRING HERE — but it
remains a bad failure mode on its own terms: **silently reporting no contact for shapes that are
demonstrably overlapping.** Worth fixing regardless of this bug.

### Where the theory now stands

Live, the foot's contacts churn 0..1 while it sits ~7 cm inside the floor. Static EPA does not
explain that, so the drop happens somewhere else — the broad phase, a filter, or a
configuration-dependent EPA failure the static sweep does not reach. **Not yet located.**

### Candidate solutions, in order of how well they match the evidence

1. **★ AN ANALYTIC CAPSULE×BOX AND CAPSULE×PLANE PATH.** This is exactly what MuJoCo does and
   what our dispatch is missing for the one pair that matters most — feet, shins, forearms are
   all capsules and the ground is a box. It removes the degeneracy rather than working around
   it, and `mjc_PlaneCapsule` shows how little code it takes.
2. **Make EPA failure loud rather than silent.** Overlapping shapes returning "no contact" should
   at minimum fall back to the GJK separating direction with a clamped depth, never to nothing.
3. Prevent deep penetration at all (speculative contacts, or extending the existing swept path to
   ordinary landings). Addresses the trigger rather than the mechanism, and is the most work.

**Nothing was changed. This is measurement and reading.** The previous round of tuning made the
system worse and had to be reverted; this stays diagnostic until the mechanism is certain.

## 🔬 THE FOOT BOUNCE — six theories, five eliminated, one strongly supported

Instrumented rather than guessed at, with the theories and their distinguishing predictions
written down BEFORE the run so the data could refute rather than confirm.

### Eliminated by measurement

| | theory | what killed it |
|---|---|---|
| T1 | contact too stiff (`time_const` 0.004 vs solref 0.015) | the bounce is 4 mm at ~27–48 Hz, but persists with the foot barely loaded; stiffness alone predicts ringing that decays |
| T4 | the foot's two capsules fighting | only ONE contact ever exists on the foot at a time |
| T5 | controller fighting the contact | the bounce is identical when LIMP, with no controller at all |
| T6 | solver under-convergence | iterations peak at 6–8 against a cap of 100; never pinned |
| — | proxy lag | **every proxy is within 0.000557 m of where the tree says its geom is** |

### ★★★ SUPPORTED: the foot is DEEPLY penetrated, and detection then becomes intermittent

Caught in the act, four consecutive occurrences:

    contact: world vs foot_left   distance -0.12983   position z -0.0649
      foot geom 11: caps z -0.0421/0.1175, radius 0.027  ->  lowest point z = -0.0691

**The foot is genuinely 6.9 cm below the floor.** Not a false contact, not a bad probe — the
capsule's own end-caps put it there.

And the decisive observation: **foot contacts churn 0..1**. Most steps report NO contact for a
foot that is seven centimetres underground; occasionally one appears. Force when it appears,
gravity when it does not — a limit cycle at exactly the frequency observed.

★ WHY DEEP PENETRATION WOULD DO THIS: it is the known-hard case for GJK/EPA. Once shapes are
well inside one another the witness points become unreliable, and a detector that finds the pair
on some steps and not others produces precisely this bounce.

★ AND A SEPARATE ODDITY IN THE SAME DATA: the reported `distance` is −0.1298 where the true
penetration is 0.0691 — a factor of **1.88**, suspiciously near 2. The contact POSITION is
exactly `distance/2`, which is the correct midpoint convention, so the two are consistent with
each other and both roughly twice the truth. Worth chasing on its own.

### What has NOT been established

Why the foot gets that deep in the first place. A landing foot moves ~10 mm per step at 500 Hz,
so reaching 69 mm takes seven steps of essentially unopposed motion — which points at the
contact appearing late rather than at the solver failing to push. **Not yet measured**, and it is
the next thing to look at.

★ NO PARAMETER WAS CHANGED IN THIS INVESTIGATION. The previous round of tuning made things worse
and had to be reverted; this one is measurement only until the mechanism is certain.

### ANSWERED: MuJoCo does NOT have this problem

The right question, asked from a device: are the oscillations inevitable? Measured on the
identical model, drop and instant — `foot_left` z over 0.4 s:

    MuJoCo   range 0.00111 m,  0 direction reversals   (monotonic drift, no oscillation)
    ours     range 0.00402 m, 38 direction reversals   (~48 Hz)

**It is not inevitable and it is not physics. It is ours.**

### AND THE CAUSE IS THE SAME CLASS AS THE FRICTION BUG: `solref` IS DROPPED

`robot_physics.zig` hardcodes `time_const_s = 2.0 * timestep` = **0.004 s** for every contact.
The humanoid declares `solref=".015 1"` — 0.015 s. **Our contacts are 3.75x stiffer than the
model asks**, and 1/0.004 = 40 Hz sits right on the 48 Hz measured.

`mjcf.zig` PARSES it — there is a test asserting the string ".015 1" is read — and nothing
carries it to the contact. Exactly the shape of the friction bug: parsed, then dropped.

Substituting the model's own 0.015 cuts settled kinetic energy **3.5x, from 0.018 J to 0.0051**.

★ BUT THE OSCILLATION FIGURES CAME BACK BIT-IDENTICAL — same 0.00402 range, same 38 reversals —
which a stiffness change should not leave untouched. Something else sets that frequency, and one
run cannot say what. **Not concluded**: the `solref` gap is real and worth fixing on the energy
evidence alone, and the oscillation is a separate open question.

### AND ANOTHER GAP THE COMPARISON EXPOSED

    MuJoCo   11 contacts, 2 of them ROBOT-vs-ROBOT
    ours     14 contacts, 0 of them robot-vs-robot

**We detect no self-collision at all** where MuJoCo finds two. The parent-child weld filter may
be over-filtering — it was written to stop adjacent links fighting at their shared joint, and a
limb resting against a torso is not that. Worth its own investigation.

### THE ENERGY AUDIT — and the right metric turned out not to be velocity

**PEAK JOINT VELOCITY WAS THE WRONG THING TO MEASURE.** A hand with almost no inertia spinning
at 2 rad/s is nearly no energy, so "10x MuJoCo's joint velocity" overstated the problem. Total
kinetic energy is the metric, and it gives a cleaner number:

    ours     0.0137 - 0.0262 J
    MuJoCo   0.0003 - 0.0007 J

About **40x**, which is real and is the residual. But far less alarming than 10x on a velocity
that carries no energy.

### A MEASUREMENT THAT WAS AN ARTEFACT, CAUGHT BY MEASURING IT THREE WAYS

The first audit computed `f . v` using the velocity AFTER the step and reported contacts doing
**+10 J** of positive work per 2 s. That is nonsense by construction: if the force caused that
velocity, the product is positive whatever the physics. Measured three ways:

    f . v_after      +11.2 J      <- what was nearly reported
    f . v_before      -9.1 J
    f . v_midpoint    +1.1 J      <- the actual work integral

Still positive, and a passive contact should never do net positive work — so there IS a leak,
about **1.5 J per 2 s**, mostly balanced by damping at an equilibrium 40x MuJoCo's.

★ THE HABIT WORTH KEEPING: when a measurement produces a shocking number, compute it a second
way before believing it. Three of this session's leads dissolved on re-measurement.

### SUGGESTIVE BUT UNPROVEN: `max_recovery_velocity`

Total KE after 13 s, varying the bound on penetration recovery:

    cap 2.0 (default)   0.01790 J
    cap 0.2             0.00263 J     <- 7x less, within 4x of MuJoCo
    cap 100 (off)       0.00918 J

Tightening it helps a lot. But turning it OFF also helps, which breaks monotonicity — and this
ragdoll is chaotic, so a single run cannot separate signal from variation. **Do not tune this on
one sample.** The next step is the same sweep over several drop seeds, and only then a change.

## ✅ SOFT CONTACT — a live "fat thickness" knob, with no new solver code

`Bridge.flesh` exposes what the solver could already do and nothing was choosing: `Impedance`
ramps a constraint from `min` to `max` across a `width` of penetration — MuJoCo's `solimp` —
and every contact was taking the struct default.

Measured on a humanoid dropped limp from 1.2 m:

    fat 0.000, damp 1.0:  rebound 0.222 m/s   sink  2.0 mm   pelvis 0.1924
    fat 0.010, damp 1.0:  rebound 0.216 m/s   sink  5.3 mm   pelvis 0.1755
    fat 0.010, damp 4.0:  rebound 0.191 m/s   sink  5.6 mm   pelvis 0.1760
    fat 0.030, damp 4.0:  rebound 0.163 m/s   sink 14.4 mm   pelvis 0.1670

### ★★ TWO BUGS ON THE WAY, BOTH THE SAME SHAPE AS EARLIER ONES

**The knob did nothing at first.** Two contact producers, and only the SWEPT one was patched —
the discrete path, which makes almost every contact, had no `.softness` field at all and
silently took struct defaults. Third time this session: friction, the swept filter, now this.

**Then unifying their defaults broke the stack test**, dropping six boxes by 3 cm. The two paths
had DIFFERENT defaults for good reasons — a swept contact is deliberately stiff at
`2 × timestep` because it exists to stop something fast; a discrete one takes 0.02. Each keeps
its own now, and the flesh setting overrides only when set.

★ THE COST OF SOFTNESS IS DEPTH, and depth is where the iterative collision path fails. Turning
this up is only safe because capsule×box and capsule×capsule are now closed-form.

## Ordered plan

| # | work | why it is next |
|---|---|---|
| ✅1 | **Trot on the Go1** | **DONE** — stable at duty 0.85; drifts rather than propelling, which needs a body-velocity command (MPC/RL work). |
| ✅2 | **Gait gallery** | **DONE** — trot/pace/bound buttons, and a 4-beat walk labelled `(falls)` because it measurably does. |
| ✅3 | **`Env` wrapper + action space** | **DONE** — reset/step/observe, actions clamped to `ctrlrange`, `markStart`. |
| ✅4 | **Gripper demo** | **DONE as hand-driven** (`examples/gripper/`) — IK target sliders and a coupled gripper. A scripted pick needs collision-aware waypoints, which IK cannot supply. |
| ✅4.5 | **IK orientation targets** | **DONE** — `IkTarget.orientation`. Six rows instead of three, Cholesky instead of a hand-written 3×3 inverse. The gripper demo aims its jaws down; untick the box and watch the wrist wander. |
| ✅5 | **Refresh `robots.html`** | **DONE** — nine new sections (§20–28): contact, both solvers, all four integrators, equalities, MJCF, sensors, control, the collision seam. 2447 → 2660 lines. |
| ✅6 | **Batched stepping** | **DONE** — `ctl.Batch`: N envs on one model, flat row-major observation and action matrices. Serial, deliberately: see below. |
| ✅7 | **Ragdoll** | **DONE** — in `examples/humanoid/`: a `limp` toggle, a `drop it` button, a live PGS/Newton switch, and the peak joint speed shown so the difference is a number. |
| ✅8 | **Live learning demo** | **DONE** — `examples/cartpole/`: CEM training a linear policy live, elite-score curve beside the robot, policy weights on screen. |
| ✅3.5 | **Newton solver** | **DONE** — 96-row stack: residual 5e-7 in 2 iterations where PGS leaves 0.269 after 100. PGS stays the default (1.86x faster on a Go1). |
| 10 | Spatial tendons, SDF, flex | Only if a target model needs them. |

**★ THE ORDERING PRINCIPLE:** demos before features from here. Every remaining MuJoCo feature is
one a specific model would need; every demo is something the engine can already do and nobody
can see. The gap between what this engine IS and what it LOOKS like is now the biggest one.

## ★★★ STRATEGIC REVIEW — what is actually worth doing next

Three questions were asked: is performance good enough, should the two engines be unified more
cleverly, and are we at feature parity. All three are answerable with measurements, and the
answers redirect the roadmap.

### 1. Performance is good enough. Stop working on it.

| case | zimr | MuJoCo | |
|---|---|---|---|
| two-link arm | 280 ns | 2531 ns | 9.0x |
| KUKA free | 1277 ns | 5937 ns | 4.6x |
| KUKA, 5 limits | 1961 ns | 6638 ns | 3.4x |
| Go1 standing, 16 rows | 12,303 ns | 20,209 ns | 1.6x |

And free bodies in the tree scale **linearly** — measured 5 to 400 bodies, flat at **243 ns per
body per step**, no quadratic term:

    5 bodies (nv   30):   1,221 ns    243 ns/body
   50 bodies (nv  300):  12,169 ns    243 ns/body
  400 bodies (nv 2400):  97,371 ns    243 ns/body

**§4g's remaining items (S1 sparse Jacobians, S2 cheaper Â, S5 Newton) are now premature
optimisation.** Faster than MuJoCo everywhere, with linear scaling, is enough for a simulator
whose accuracy is the problem — see §3.

### 2. The two engines should NOT be unified further. The current split is right.

§4k already made the important call: anything the robot must interact with correctly goes in
its tree, and zimrphysics is a pure DETECTOR. The measurement above says that scales.

The alternative — Bullet's `btMultiBody` hybrid, where one LCP mixes articulated links (via
their Jacobians) and rigid bodies (via inverse mass) — is a real design and buys two things:
runtime add/remove of bodies, and cheap debris that never touches the articulated solver.
**Neither is worth the seam.** That seam cost five sessions and produced four wrong diagnoses;
the code for it was written and then deleted, and the deletion removed 13.6 KB.

**One honest caveat.** The handoff was abandoned because of behaviour later traced to two
positional lags — `sync` before `forward`, and `moveKinematic` steering rather than teleporting
— both of which are now fixed. So the hybrid is more viable than it looked. It is still not
worth building while the tree scales linearly and the accuracy gap below is open.

### 3. ★★ THE REAL GAP IS ACCURACY, NOT FEATURES — we are simulating the wrong robot

`<inertial>` appears **once per body** in the Go1 and we do not parse it. Every mass and
inertia is derived from the SIMPLIFIED COLLISION PRIMITIVES instead of the manufacturer's CAD
values:

| body | MuJoCo (stated) | zimr (derived) | error |
|---|---|---|---|
| total | 12.7434 kg | 11.5601 kg | −9% |
| trunk | 5.2040 kg | 7.9507 kg | **+53%** |
| FR_hip | 0.6800 kg | 0.3867 kg | **−43%** |
| FR_thigh | 1.0090 kg | 0.2592 kg | **−74%** |
| FR_calf | 0.1959 kg | 0.1235 kg | −37% |

The inertia tensors are worse than the masses. MuJoCo's trunk is `(0.0717, 0.0630, 0.0168)`;
ours is `(0.0221, 0.0702, 0.0776)` — **not the same numbers and not even the same ordering**, so
the body we simulate is heaviest about a different axis than the real one.

**The Go1 stands because standing is forgiving.** A gait computed on these numbers would be
wrong in a way that looks plausible, and a policy trained on them would learn the wrong robot
and never transfer. **This invalidates Phase C's remaining turns until it is fixed** — there is
no point tuning a trot for a machine whose thigh is a quarter of its real mass.

Every FK test still passes, because forward kinematics does not depend on mass. That is exactly
why this went unnoticed: the verification that existed could not see it.

### The revised order

1. **✅ `<inertial>` parsing — DONE.** Total mass now **12.7434 kg, exactly MuJoCo's**, and
   every body matches. The 30-second standing gate still passes, on the right robot this time.

   **MJCF states it as `diaginertia` + an orientation, not `fullinertia`** — a CAD tool
   produces principal moments and the rotation that diagonalises them, and that is what every
   Menagerie model records. Supporting only `fullinertia` would have read them all as stating
   nothing and silently fallen back to the geom-derived numbers, which is precisely the
   failure being fixed. The conversion `I = R·diag(d)·Rᵀ` happens in the importer so the
   engine keeps one representation.

2. **✅ A mass/inertia oracle — DONE, and it compares the TRACE.** MuJoCo's `body_inertia`
   holds PRINCIPAL moments with `body_iquat` carrying the rotation; ours is the tensor in the
   body's own frame with off-diagonals doing that work. Same tensor, different diagonals — the
   trunk's come out in a different ORDER. **Comparing diagonals directly would fail while
   nothing is wrong**, which is the kind of test that gets weakened until it passes. The trace
   is rotation-invariant, so it compares the physics rather than the convention.

   It also pins the trunk under 6 kg, so a regression to geom-derived mass (7.95 kg) fails
   loudly rather than drifting.
3. **✅ Collision meshes — DONE.** `<asset>` parsing, `resolveMeshes`, and a hull geom out the
   other side. The Go1 collides with primitives, which is why it worked at all; a great many
   models collide with MESHES and imported as bodies with **no collision geometry whatsoever**
   — a robot that looks right and falls through the floor.

   **Three details that would each have silently broken it:**

   * **The asset name defaults to the FILE STEM.** The Go1 writes
     `<mesh class="go1" file="trunk.stl"/>` and refers to it as `mesh="trunk"`; the name is
     never stated. Requiring one leaves every geom pointing at an asset that does not exist.
   * **`meshdir` is where the files live** — `<compiler meshdir="assets">`. Resolving against
     the model's own directory, the obvious guess, misses all of them.
   * **Scale is applied BEFORE the hull is reduced.** Reducing first and scaling the survivors
     gives the same answer for a uniform scale and the wrong one for a per-axis scale: the
     support points of a stretched shape are not the stretched support points of the original.
     The test uses `scale="2 1 1"` so that the difference is visible.

   **A mesh that fails to load degrades rather than failing the import** — real models refer to
   visual assets a headless caller has no reason to ship, and refusing the robot over one would
   make the importer useless on exactly the files it exists for. `resolveMeshes` returns the
   count resolved, so a caller can notice when the answer is zero.

   Loading stays behind a CALLBACK, as in `urdf.resolveMeshes`: `mjcf.zig` never touches a
   disk, which is what keeps it testable from a string literal.
4. **Then** the trot, on a robot whose numbers are right.

**Equality constraints (§4j) move up** once meshes land: parallel-linkage robots (Cassie,
Digit) cannot be represented at all without them, and that is a whole class of machine rather
than a refinement.

### Phase D — faster and clearer than MuJoCo (turns 16–20)

| # | work | done when |
|---|---|---|
| 16 | **Benchmark the quadruped** against MuJoCo, same machine, same model. This is the honest test: the current 3-case benchmark tops out at 5 constraint rows. | three new cases: standing, trotting, trotting on crates |
| 17 | **§4g's remaining slownesses**, chosen by what turn 16 says — S1 sparse Jacobians, S2 cheaper `Â`, S5 Newton. Not before. | parity or better on all six cases |
| 18 | **★ UNDERSTANDABILITY, treated as a deliverable.** The tutorial covers phases 0–10; it does not cover free bodies, import, or contact. A reader should be able to follow from "what is a mass matrix" to "why my robot fell over". | `robots.html` covers the whole engine; every section runs its own code via doc-sync |
| 19 | **The RL-facing surface.** Batched rollout, reset-to-keyframe, observation and action buffers. §4d designed this; a quadruped is what makes it concrete. | 64 parallel Go1 rollouts, deterministic given a seed |
| 20 | **Full audit**, as §4f-style: read everything written in phases A–D adversarially, plant bugs in the load-bearing tests, verify they fire. | audit recorded; every claim in this plan either true or struck |

---

### What this road deliberately does NOT include

* **Equality constraints (§4j)** — no quadruped needs a closed loop. Still deferred.
* **Spatial tendons** — cable routing matters for hands, not legs.
* **Merging `robot` and `zimrphysics`** — agreed as the eventual destination, and explicitly
  not now. Phase A removes the seam's PHYSICS problem; the two modules staying separate is
  then a code-organisation question with no correctness attached, which is the right time to
  leave something alone.
* **The RL algorithm itself.** Turn 19 builds the surface it needs. What learns on top is a
  different project and should not constrain this one.

---

## What remains

The engine is complete and beats MuJoCo on all three benchmark cases; a real robot imports,
renders, and collides. Remaining work, in rough order of value:

1. **§4h coupling upgrade** — dynamic bodies via impulse handoff rather than the current
   one-way approximation. The one place the seam is knowingly unphysical.
2. **§4j equality constraints** — closed loops, which no serial arm needs but a delta robot
   or a four-bar linkage does.
3. **MJCF import** — Menagerie's models are better than most URDFs, and `codecs.xml` already
   does the reading. Mostly `<default>` class resolution.
4. **Spatial tendons** — routing through sites, for cable-driven mechanisms.
5. **§4g's remaining slownesses** (S1 sparse Jacobians, S2 cheaper Â, S5 Newton). Lower
   priority now that the measured goal is met.

**Not needed, and worth recording so nobody builds them:** an STL parser, and a COLLADA
(`.dae`) one. Other KUKA distributions ship those formats, but the bullet3 models use OBJ
and OBJ is already handled.

---

## 4j. Equality constraints — closed loops

The one engine gap the import census turned up, and worth its own section because it is the
last piece of MuJoCo's constraint model we do not have.

A tree cannot express a loop. A Robotiq gripper's linkage, a four-bar, a parallel delta arm —
all need two branches of the tree pinned back together, and generalized coordinates
structurally cannot do it. That is the one thing maximal coordinates get for free (§1 of the
tutorial), and MuJoCo's answer is to close the loop with a CONSTRAINT rather than a joint.

**Everything needed already exists.** Phase 6 built rows, impedance, the solver and the
residual; an equality is another `ConstraintKind` with a different Jacobian and a residual
that can be positive OR negative — the only real difference, since a loop closure is
bilateral where a limit and a contact are unilateral. The solver's clamp becomes
`f ∈ (−∞, ∞)` for those rows instead of `f ≥ 0`, which is a smaller change than it sounds:
MuJoCo orders equality rows FIRST for exactly this reason, so the clamp can be a bound on the
row index.

The types worth having, in order of value:
1. **`connect`** — pin two bodies at a point. Three rows. This is what the gripper uses, and
   what closes a four-bar.
2. **`joint`** — couple two scalar joints by a polynomial. One row. Note a *linear* coupling
   is already expressible as a fixed tendon and should stay that way: a tendon is exact and
   costs a dot product, where an equality costs a solver row (§ phase 8).
3. **`weld`** — pin two bodies completely. Six rows.

---

## 5. Problems we expect, and what we will do

Written in advance so that hitting one is recognition, not discovery.

**P1 — f32 conditioning.** *Expected — this is the accepted risk of §1.1.* High mass
ratios blow up `cond(M)`; the f32 LᵀDL loses accuracy; the robot looks mushy or diverges
with no obvious cause.
→ Armature non-zero by default. The `max(D)/min(D)` probe from phase 2 makes it
diagnosable. When it fires: widen **`factorM`/`solveM` only** to f64 internally, per the
table in §1.1 — two functions, invisible to callers, no model-spec change. Do not
pre-build it, and do not respond by making the whole core f64.

**P2 — the `cdof` frame convention.** *Expected, high-cost.* Rotation-first `(rot:lin)`,
global orientation, translated to the **root's** subtree COM (not the body's). Every sign
and offset here is load-bearing and a mistake produces a plausible-looking wrong answer.
→ Pin the convention in the header comment; test a single hinge's `cdof` analytically in
phase 1; the phase-4 finite-difference Jacobian test is the independent backstop.

**P3 — comptime cost.** *Largely dissolved by §1.3's hybrid*, but not zero: `Spec()` still
validates and generates enums at compile time, and a humanoid-sized literal is big.
→ Keep the comptime layer thin — validate, name, index, and nothing else. All *table
construction* happens in `build()` at runtime. Still worth a one-off measurement of
`Spec()` cost on a humanoid-sized literal during phase 0, because a 1-core box makes
comptime regressions expensive and phase 0 is the cheapest moment to find out.

**P4 — two-solver coupling.** *Expected, deferred.* Robot in generalized coordinates,
world in maximal coordinates. Who solves a shared contact? A truly co-simulated system
needs one combined solve, which is a research-grade problem.
→ Phase 7 ships **one-way** coupling (robot infinitely massive), which is correct for a
heavy arm and light objects and wrong for a light arm and heavy objects. Upgrade path,
in increasing cost: (a) feed last step's contact impulse back as an external force on the
robot — one line, one step of lag, fixes most of it; (b) iterate the two solvers per step;
(c) assemble one system. Do (a) when someone notices; (b) and (c) only on evidence.

**P5 — the up-axis clash.** *Certain.* Y-up here, Z-up in every robot model in the world.
→ RESOLVED, but NOT as planned, and the plan said otherwise for months. **No `zUpToYUp()`
helper was ever written** — grep the tree; that name appears only in this paragraph. What
actually happened is better: `robot.zig` turned out to be axis-AGNOSTIC (gravity is an
`Options` field and every other direction comes from the model), so there is nothing to
convert inside the core and no helper to call. MJCF models therefore stay **Z-up** and set
`gravity = (0, 0, -9.81)` — deliberately, because the acceptance test for import is that
forward kinematics agrees with MuJoCo body for body, and a rotation in the middle turns any
disagreement into two candidate explanations. URDF **is** rotated to Y-up at the root, since
it has no MuJoCo to be checked against and the demos want zimr's convention. The Go1,
humanoid, gripper and cartpole demos are all Z-up. See `robot.zig`'s header.

**P6 — no oracle.** *Expected.* We cannot eyeball a mass matrix, and there is no device
test that helps — this subsystem is invisible.
→ §7. Multiple independent oracles, of which the finite-difference Jacobian and the
fwd/inv round trip are the strongest.

**P7 — the constraint solver is the hard part.** *Certain.* MuJoCo's
`engine_core_constraint.c` is 3,479 lines plus `engine_solver.c` at 2,587 — four
algorithms, two cone types, and the diagonal approximation that makes `solref` behave
across mass scales. This is where the taste is, and where a naive port will produce
something that technically runs and feels wrong.
→ Ordering is the mitigation and it is already in the plan: phases 0–5 are a complete,
useful simulator with **no solver**. When phase 6 starts, ship exactly one algorithm (PGS,
pyramidal) and resist the others until a demo actually needs them. Budget 3–4× the
estimate for this phase alone.

**P8 — linter friction.** *Certain, minor.* Dense math hits `untyped-local`, the 120-col
cap, and `reserved-math-names` (`float`, `int`, `vec`, `cross`, `dot`, `Quat`, `Mat` are
all zm keywords needing file-scope aliases). Names like `mass`, `axis`, `inertia`, `jac`
need checking against the keyword list before use.
→ Write lint-clean on the first pass; alias the zm keywords at file scope once, at the
top, as zimrphysics does.

**P9 — quaternion coordinates.** *Expected.* `nq ≠ nv`, `qpos` cannot be subtracted,
integration of a quaternion by an angular velocity is not addition, and normalization
drifts.
→ Implement `differentiatePos` / `integratePos` / `normalizeQuat` in phase 0 *before*
anything uses them, and test the round trip. Every one of them is a place where an
`f32`-shaped instinct produces a subtly wrong answer.

**P10 — wasm size.** *Possible.* robot.zig is large and pulls no shaders, but a model's
generated `Data` and tables are per-model comptime data. Ten example robots in the
launcher could add up.
→ Zig's lazy analysis means an unused `Model()` costs nothing. Watch the launcher size at
phase 5 and again at phase 9; the numbers are already tracked per turn.

**P11 — API drift from zimrphysics.** *Possible.* Two physics engines in one tree with
different vocabularies for the same concept (`Body`, `Shape`, `step`, `gravity`) invites
confusion.
→ Follow `physics_common.zig`'s existing precedent: shared concepts get shared types where
they genuinely are the same thing, and a `assertParallelEngines`-style comptime check if a
third engine ever makes the pattern worth generalizing. Do *not* force parity where the
models genuinely differ — that was the lesson of the 2D/3D harmonization arc.


**P12 — contact non-determinism inherited from zimrphysics.** *Certain if unhandled* — see
R3. The broadphase does not promise a stable order and the solver is order-sensitive.
→ Sort manifolds by `(body, sub)` before building rows, at phase 7. Then pin it: run the
same scene twice from the same seed and require bit-identical trajectories, as the 2D
engine's snapshot tests do.

**P13 — constraint storage overflow.** *Certain if unhandled* — see R7 and zimr392, where
the 2D engine's contact pool silently froze the world at capacity.
→ Growable, or generously sized with a loud named `assertf` carrying live count and cap.
Never a silent clamp.

**P14 — the demo outruns the engine.** *Likely.* A scene table invites writing scenes that
need capability that does not exist, and then the table blocks.
→ The table in §4b carries a phase column. A scene whose phase has not landed is simply
absent from the roster; the switcher never sees it.

**P15 — `debugDraw` grows into a renderer.** *Likely.* The 2D demo's `render.zig` is 229
lines and it is the demo's, not the engine's — but the *contact overlay* lived there and
caused three separate device bugs (zimr416/418/419: ring overflow, freeze, corruption).
→ Keep `robot.debugDraw` to primitives the 2D path already survives, and remember the
lesson from zimr418: a debug point is a small **quad**, not a tessellated circle. That one
detail was a 12× cost difference and a device freeze.

---

## 6. The GPU angle

zimr's kompute already gives the exact shape this wants: one kernel source, three backends
(`.cpu | .worker | .gpu`), `c.id` as the invocation index, `Params` by value, buffers as
module globals. Nothing about it needs to change.

**The natural fit is batched rollouts, not a single fast robot.** A single robot's tree
passes are inherently sequential (parent before child) and `nv` is tiny — there is no
parallelism worth a dispatch. But *hundreds of copies of the same robot* under different
controls is embarrassingly parallel, and it is exactly what MJX (MuJoCo's JAX sibling)
exists to do, because it is the inner loop of every modern robot-learning method.

```zig
// one instance per invocation; the comptime model makes the layout known
pub fn rollout(c: k.Ctx(@This())) void {
    const inst = c.id;
    var d: Arm.Data = b.state[inst];
    var t: u32 = 0;
    while (t < c.params.horizon) : (t += 1) {
        Arm.step(&d, c.params.dt);
    }
    b.state[inst] = d;
}
```

What has to be true for that to work, and what to design for now even though phase G is
late:

- **`Data` must be a flat, pointer-free buffer** — the batched arm slices one `Data`'s
  worth per instance out of one big allocation. This is MuJoCo's `mjData` layout and it is
  what MJX batches; §1.3's hybrid keeps it.
- **Precision is already f32**, so the GPU arm is the same arithmetic as the CPU arm —
  a genuine simplification that fell out of §1.1. If `factorM` later widens to f64 on the
  host, the GPU arm keeps the f32 path and *that* is where a fidelity note becomes needed.
- **Instance-major layout** for coalesced access — decide this when phase G starts, not
  before, but keep `Data` a struct-of-arrays so the transposition is mechanical.
- **The constraint solver is the blocker**, not the dynamics. Variable contact counts and
  variable iteration counts are hostile to a GPU dispatch; MJX pads to fixed sizes. Phases
  0–5 (no solver) are GPU-ready almost for free; phase 6 onward is not, and that is fine —
  a batched *smooth-dynamics* rollout is already a real capability.

**Also worth noting for physics generally:** the same argument applies to zimrphysics.
Batched rollouts of a whole zimrphysics world would be the same shape. Nothing here
depends on that, but if robot.zig proves the pattern, it transfers.

---

## 7. How we will know it is right

No device can help here. Every gate is a host test, and the good ones are physical
invariants rather than golden values:

1. **Finite-difference Jacobians** (phase 4) — the cheapest strong test in the project.
2. **Forward/inverse round trip** (phase 9) — validates `M`, `c`, `J` at once.
3. **Energy conservation** under RK4 with no damping and no contact.
4. **Momentum conservation** for a free body with no external force.
5. **`M` symmetric positive definite**, and `M·M⁻¹x = x`.
6. **Analytic cases:** single pendulum period, double pendulum against a published
   trajectory, a free body's parabola.
7. **Mass-scale invariance** of contact penetration (phase 6) — the `Â` test.

### The oracle: real MuJoCo, and it already works

**Settled empirically, not by argument:** `pip install mujoco --break-system-packages`
succeeds in this sandbox (`pypi.org` and `files.pythonhosted.org` are both in the network
allowlist). MuJoCo **3.11.0** imports and runs. No CMake, no FetchContent, no hand-built
`mjModel`, no C harness — the plan's fallback ladder is unnecessary.

Verified on the phase-3 double pendulum, which emits exactly the quantities every early
phase needs:

```
nq,nv = 2 2
M = [[1.450094672 0.305548683]
     [0.305548683 0.131263951]]
bias c = [ 4.681951859 -1.918642201]
qacc  = [-12.381380011  43.437337633]
jacp(lower com) = [[-0.661880443 -0.184212199] [0 0] [0.069876435 -0.077883668]]
```

**API notes (the probe cost three tries):** the field is `d.M`, not `d.qM`, in 3.x; and
`mj_fullM(m, d, dst)` takes model, data, destination — not `(m, dst, qM)`.

**The workflow — fixtures, generated once and checked in. BUILT, not planned:**
`scripts/robot_oracle.py` exists and `src/tests/fixtures/robot/reference.zig` is in the
tree (18 cases across 6 models × 3 states). It defines a set of reference models (single pendulum, double
pendulum, a 3-hinge arm, a free body, a ball joint, one high-mass-ratio chain for the P1
probe), evaluates each at several `(qpos, qvel)` states, and emits a **Zig source file** of
reference values into `src/tests/fixtures/robot/`. The host tests import that file and
compare. Tests stay hermetic: no Python, no network, no MuJoCo at test time — the same
shape as the spv2wgsl corpus.

Regenerate only when adding a model or a state; never as part of a build. The generator
runs `zig fmt` on its own output, because the build gates on `zig fmt --check src` and
leaving that to a comment is a trap for whoever regenerates next.

Generated fixtures are carved out of the linter (`isSkipped`, alongside the existing
`quad_glb_data.zig` precedent): style rules describe how a human writes code and say
nothing useful about a machine-written number table. Verified not over-broad — a planted
violation elsewhere in `src/tests/` still fires.

**Already validated by construction:** in `double_pendulum`, `M[1][1]` is byte-identical
across all three states (link 2's inertia about its own joint does not depend on q2) while
`M[0][0]` falls from 1.557 at rest to 1.450 when folded, and 1.45009467 matches an
independent Z-up probe at the same qpos — i.e. the Y-up authoring is a pure rotation of
identical physics, not a different model.

**What this buys, phase by phase:** phase 1 checks `cdof` and body poses; phase 2 checks
`M` element-wise (and the LᵀDL against `mj_solveM`); phase 3 checks `c` and `qacc`; phase
4 checks Jacobians against `mj_jacBodyCom` directly rather than only against finite
differences; phase 9 checks inverse dynamics against `mj_inverse`. **The `cdof` sign trap
(P2) is caught by the phase-1 fixture instead of by a confusing demo three phases later.**

**Y-up caveat:** MuJoCo is Z-up (§1.2). Either author the reference models Z-up and rotate
the expected values in the generator, or author them with gravity `0 -9.81 0` so the
fixture is already in zimr's frame. **Prefer the latter** — the conversion then lives in
one Python file rather than in every test, and a fixture that needs mental rotation to
read is a fixture that will eventually be misread.

**One caution:** MuJoCo is f64 and we are f32 (§1.1). Fixture tolerances must be f32-sized
(~1e-5 relative, not 1e-12), and a *growing* gap as models get stiffer is itself the P1
signal — worth watching deliberately rather than just loosening the tolerance.

## 8. Open questions for Simon

1. ~~Precision~~ — **DECIDED: f32, zm throughout, no per-robot choice.** Localized f64
   widening of `factorM` is the escape hatch if the conditioning probe fires (§1.1).
2. ~~Up axis~~ — **DECIDED: Y-up.** zimr's convention wins inside zimr; the rotation lives
   in the importer, a place we control and can test, not smeared across every seam.
3. ~~Model construction~~ — **DECIDED: hybrid.** Runtime `Model` struct + comptime `Spec()`
   builder that validates and generates name enums. Runtime-built models stay possible.
4. ~~Phase 7 coupling~~ — **DECIDED: one-way, upgrade on evidence.** The robot is
   infinitely massive from the world's view. Consistent with the §1.1 rule against
   pre-building escape hatches; the impulse-feedback upgrade stays documented and small.
5. ~~First demo target~~ — **DECIDED: a double pendulum, at the end of phase 3.** Earliest
   possible visual, needs no engine surface beyond the core, and chaotic motion is
   unforgiving of exactly the errors most likely to be lurking (the `cdof` sign trap,
   frame-convention mistakes). The phase-4 Jacobian reach demo follows as the second.
6. ~~Oracle~~ — **RESOLVED empirically: `pip install mujoco` works** (3.11.0, verified
   against the phase-3 double pendulum). Differential testing against real MuJoCo is
   available from phase 1 onward, via checked-in generated fixtures.

---
