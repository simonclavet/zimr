# ★ THE CURRENT PLAN — mocap on any character, any robot

## ★★★ THE SUCCESS CRITERION — 2 animations x 3 targets = 6 clips

    ANIMATIONS                          TARGETS
    A1  dance1_subject2   BVH, 96 bones  T1  Geno            96 bones, LAFAN1 names
    A2  Drop_Kick         FBX, 67 models T2  Mixamo "Beta"   67 models, mixamorig: names
                                          T3  humanoid.xml    16 bodies, MuJoCo, free root

★ **TWO OF THE SIX ALREADY WORK TODAY** — A1xT1 and A2xT2 are each an animation on its own
skeleton, index-matched, running in `geno_dance`. The real work is FOUR clips: two
character-to-character retargets and two robot retargets. Sizing the job honestly matters more
than counting to six.

    A1 x T1  dance -> Geno       ★ DONE (geno_dance, 96/96 by index)
    A2 x T2  backflip -> Mixamo  ★ DONE (its own take)
    A1 x T2  dance -> Mixamo     name + topology remap, no IK needed
    A2 x T1  backflip -> Geno    name + topology remap, no IK needed
    A1 x T3  dance -> humanoid   FULL IK
    A2 x T3  backflip -> humanoid FULL IK, and the hardest of the six

★ Plus one target that is not in the six but earns its place as the BRIDGE between them:
**T0, a ragdoll synthesized from Geno's own skeleton** (§13x). The dance plays on it EXACTLY,
with no solver, which is the only place in this plan where a robot-side error can be attributed
with certainty.

Goal, stated as a test: **take any BVH/FBX capture and any character or robot model, and play
the motion.** Everything below exists to make that sentence true and checkable.

Reference: `FlomoGMR` (General Motion Retargeting) — `motion_retarget.py` and its ik_configs,
read line by line. Every claim about zimr below was checked against the source, with the file
and line named, because a plan built on a guess about our own code is how §11 lost five rounds.

---

## 1. What GMR does, precisely

The whole per-frame pipeline from `motion_retarget.py`, in order:

    1. scale_human_data(root, scale_table)   per-joint scale in ROOT-LOCAL space
    2. offset_human_data(pos_off, rot_off)   per-joint frame correction
    3. apply_ground_offset(ground)           fixed world shift
    4. offset_human_data_to_ground()         optional: lowest point -> ground_height
    5. set task targets = SE3(rot, pos)
    6. solve table1 to convergence, then table2

Exact semantics, from the source rather than from the names:

**Scaling** (`scale_human_data`, line 243) — root scales alone; every other joint is scaled
about the root and re-added: `local = (pos - root) * scale[j]`, then `pos' = local +
root*scale[root]`. ★ **ROTATIONS ARE UNTOUCHED.** Scaling changes where joints are, never which
way they face — which is why a short robot can wear a tall human's motion.

**Offsets** (`offset_human_data`, line 268) — `quat' = quat * rot_offset` (RIGHT-multiply, so
the offset is in the joint's LOCAL frame), then `pos' = pos + rotate(quat', pos_offset)`. ★ The
position offset is applied through the CORRECTED rotation, not the original.

**The solve** (`retarget`, line 173):

    err = error()
    loop:  vel = solve_ik(config, tasks, dt, solver, damping, limits)
           config.integrate_inplace(vel, dt)
           next = error()
           stop when (err - next) <= 0.001 or iter >= max_iter

★ It solves for a joint VELOCITY and integrates, rather than solving for a position directly.
That is what makes it robust on a redundant chain: each step is a small least-squares move, and
`lm_damping = 1` keeps it stable near singularities. `error()` is the L2 norm over all task
errors concatenated (line 222).

**Tasks** (`setup_retarget_configuration`, line 107) — one `mink.FrameTask` per table row with
`position_cost = pos_weight`, `orientation_cost = rot_weight`, `lm_damping = 1`. ★ A row whose
BOTH weights are zero is skipped entirely, so a table can carry commented-out rows as zeros.

### ★★ The match table is the whole retargeting spec

    robot_body -> [human_joint, pos_weight, rot_weight, pos_offset, rot_offset_quat]

From `bvh_lafan1_to_g1.json`, measured:

    pelvis               ["Hips",         pos 0,  rot 10]
    left_hip_yaw_link    ["LeftUpLeg",    pos 0,  rot 10]
    left_knee_link       ["LeftLeg",      pos 0,  rot 10]
    left_ankle_roll_link ["LeftFootMod",  pos 50, rot 10]

★ **Read the asymmetry.** Pelvis, hip and knee match ORIENTATION ONLY (pos weight 0) — a robot's
limb lengths differ, and demanding their positions would fight the skeleton against itself. The
ankle gets pos weight 50, five times any rotation weight: **feet must land where the human's
landed or the robot skates.** That single choice is most of what makes retargeted motion look
right, and it is DATA.

★ `rot_offset` values like `[-0.707, 0.707, 0, 0]` are 90-degree axis swaps: the fixed
difference between a human joint's convention and a robot link's frame.

★ **Two tables, run in sequence** (`use_ik_match_table1/2`). Table 1 places the body; table 2
refines extremities against the result. It is a priority scheme without a priority solver.

---

## 2. What zimr already has — every line verified

    src/robot.zig:2544   cdof: []Motion       each DOF's motion axis as a spatial vector
    src/robot.zig:2542   subtree_com: []Vec   the frame cdof is expressed in
    src/robot.zig:149    Motion{ ang, lin }   spatial vector layout
    src/robot.zig:1564   dof_body, dof_jnt    DOF -> body and joint
    src/robot.zig:1522   body_parent          walks terminate at world (line 1873)
    src/robot.zig:1896   body_root            per-body kinematic-tree root
    src/robot.zig:3074   pub fn kinematics    body poses from qpos
    src/robot.zig:3175   pub fn comPos        subtree_com + cdof + cinert
    src/robot.zig:1546   jnt_qpos_adr         qpos slice per joint (nq != nv for quats, line 421)
    src/robot.zig:3422   factorM / solveM     an LDL factor and solve already exist
    src/tests/fixtures/robot/humanoid.xml     MuJoCo's humanoid, 27 DOF
    examples/humanoid                          it already stands on its own two feet
    draw3d.bvhForwardKinematics                world pos + rot per joint — the exact input
                                               a match table consumes

### ★★★ The Jacobian is an assembly step, not new physics — verified

`cdof[j]` is "each DOF's motion axis as a spatial vector" in the subtree-COM frame
(robot.zig:2543-2544). **That is exactly MuJoCo's `d->cdof`**, and `mj_jac` is built from it:

    offset = point - subtree_com[body_root[body]]
    for each dof j on the path world -> body:
        jacp[:, j] = cdof[j].lin + cross(cdof[j].ang, offset)
        jacr[:, j] = cdof[j].ang

Every table that formula needs is present and public. ★ The one piece to write is the "path
world -> body" walk, and `body_parent` already terminates at the world body (line 1873), so it
is a `while (b != world_body) b = body_parent[b]` loop over `body_dof_adr/num`.

---

## 2b. ★★★ DECIDED: UNIFY ON THE POSE, NOT ON qpos

The interchange type between every stage is a **pose**: world position + orientation per joint.

    positions: []Vec,   rotations: []Quat     // parallel, indexed by joint

★ Everything already speaks this. `bvhForwardKinematics` outputs it. GMR's `human_data` IS it
(`{"Hips": (pos, quat), ...}`). The match table consumes it. Skinning needs it. A robot's
`body_xpos`/`body_xquat` are it.

**Storage stays target-specific**: a character's pose IS its state; a robot's pose is DERIVED
from `qpos`. One retargeter, one table format, one viewer — the difference is confined to a
single writer at the end.

★★ **WHY NOT UNIFY ON qpos**, which was the tempting answer: every character would need a
synthesized MuJoCo model, and Geno as ball-joints-plus-free-root is **~231 DOF against
`humanoid.xml`'s 27** — the simple case made eight times heavier than the hard one. Worse,
**dance -> Geno is currently EXACT** (96/96 by index, a direct copy); routing it through
iterative IK would trade an exact result for a converged one. Unifying on the pose keeps that
path exact and costs nothing, because it is what the code already produces.

★ And it leaves the door open: characters as full physical models become a NEW SOURCE OF POSES
with nothing above it changing — which is exactly what §13x below does.

---

## 2c. ★★★ DECIDED: Y-UP, CONVERTED AT LOAD — never at render

zimr is Y-up everywhere — cameras, capsules along local Y, every non-robot demo — and the
retarget pipeline joins it. **A Z-up source is rotated when it is LOADED**, and nothing
downstream ever thinks about the up axis again.

★ Simon's reason, recorded because it is the design constraint: *some parts of robot.zig and
some robot examples are Z-up and just switch at render. I don't like that.* A convention that
holds until the last moment and then flips is one every reader has to keep in their head.

### ★★ WHAT WE DO NOT CHANGE, AND WHY

`robot_mjcf.build` stays Z-up. Its own doc (robot_mjcf.zig:33) gives the reason and it is a good
one: *"the acceptance test for MJCF import is that forward kinematics agrees with MuJoCo body
for body, and a frame conversion in the middle turns any disagreement into two candidate
explanations instead of one."*

★ **That is the same principle this project has been paid to learn all session** — do not put a
transform between a thing and the test that validates it. Importing MJCF is a FIDELITY job;
converting frames is a DISPLAY job; fusing them would cost the one clean signal we have that the
import is right.

★ So the conversion happens ONE LAYER UP, in the retarget pipeline's loader, using the same
root rotation the URDF path already applies (robot_mjcf.zig:39 anticipates exactly this caller).
Two operations, two tests: import fidelity against MuJoCo in Z-up, and the rotation verified on
its own — a known point maps correctly, and rotating by the inverse returns the original.

### Consequences, each of which will bite if forgotten

**1. ★ GRAVITY MUST FOLLOW THE ROTATION.** `Options.gravity` defaults to `(0, -9.81, 0)` but
imported MJCF scenes set `(0, 0, -9.81)` (robot.zig:36). A model rotated to Y-up whose gravity
was not rotated falls sideways. ★ robot.zig:42 already warns: *"check the model's gravity before
you write a `vec(0, 1, 0)` anywhere near a robot."*

**2. ★★ WE NEED LESS CONVERSION THAN GMR, NOT MORE.** GMR's LAFAN loader rotates BVH from Y-up
INTO Z-up (`[[1,0,0],[0,0,-1],[0,1,0]]`) because MuJoCo is Z-up. **We keep BVH's native Y-up and
skip that rotation entirely.** One less transform in the chain, and the one place GMR's own
pipeline could silently mismatch simply does not exist for us.

**3. ★ DONE ALREADY — `geno_dance` IS METRES.** `LoadFbxModelOptions.scale` and
`draw3d.scaleBvhSkeletalClip` convert at load; the example no longer imports `zm.scaling` at
all, which is the clearest evidence the draw-time conversion is gone. ★ The scene was ALREADY
metric — `ground_extent`, `light_extent`, `capsule_radius` and the AO radius were always in
metres, because the old 0.01 converted before they applied. This finished a convention rather
than starting one. Guarded by a test that loads the same file at two scales and asserts mesh
vertices, bind TRANSLATIONS (not the rotation block) and normal length all move correctly
together — the partial-scale failure made arithmetic instead of visual.

**3b. UNITS STILL CONVERT: cm -> m.** BVH is centimetres (Geno spans Y 0..170) and robots are
metres. GMR divides by 100 at load and so do we — it is the same loader step, just without the
rotation. ★ Note `geno_dance` currently keeps centimetres and scales by 0.01 at DRAW time. That
is the same "convert at the last moment" pattern being removed here, and the retarget path
should not inherit it: **poses are metres, Y-up, from the loader onward.**

**4. `examples/humanoid` AND THE OTHER Z-UP DEMOS ARE UNAFFECTED.** They load their own model
with their own gravity and keep working. Only the retarget pipeline's loader rotates, so this is
an addition rather than a migration. ★ The eventual project-wide switch to Z-up that Simon wants
"one day" is also unaffected — it would flip the loader, not scatter changes through the demos.

---

## 3. Design — flat functions, plain data, no session object

    /// One row of a match table. Indices, not names: resolved once at load.
    pub const IkTarget = struct {
        robot_body: u32,
        human_joint: u32,
        pos_weight: f32,
        rot_weight: f32,
        pos_offset: Vec,
        rot_offset: Quat,
    };

    pub const RetargetOptions = struct {
        damping: f32 = 1.0,
        max_iter: u32 = 20,
        tolerance: f32 = 0.001,   // GMR's exact stopping threshold
        dt: f32 = 0.01,
    };

    /// Body Jacobian at a point. `jacp`/`jacr` are 3 x nv, row-major.
    pub fn jacBody(m: *const Model, d: *const Data, body: u32, point: Vec,
                   jacp: ?[]f32, jacr: ?[]f32) void;

    /// One frame. Mutates `d.qpos`; caller re-runs kinematics.
    pub fn retargetFrame(m: *const Model, d: *Data, targets: []const IkTarget,
                         human_pos: []const Vec, human_rot: []const Quat,
                         opts: RetargetOptions) RetargetStats;

    /// Human-side preparation, separable and independently testable.
    pub fn scaleHumanPose(root: u32, scale: []const f32,
                          pos: []Vec) void;
    pub fn offsetHumanPose(targets: []const IkTarget,
                           pos: []Vec, rot: []Quat) void;
    pub fn groundHumanPose(pos: []Vec, ground_height: f32) void;

★ **No retargeter object.** A match table is a slice, a pose is two slices, and a frame is a
function call. The state that would live in a session — `configuration`, `tasks`, cached errors
— is either `Data` (which zimr already owns) or a loop variable.

★ **Names, indices, and files.** The table is authored as JSON with NAMES (so it is editable and
diffable) and resolved to indices ONCE at load. The solver never sees a string.

---

## 4. Phases — ★ IN BUILD ORDER, which is NOT alphabetical

    13x   Geno ragdoll: skeletonToModel + direct-write playback   NO SOLVER
    13f   BVH-to-BVH direct retarget                              NO ROBOT
    13e2  the two character-to-character clips (A1xT2, A2xT1)      delivers 2 of 4
    13a   jacBody, finite-difference verified
    13b   one-task damped least squares
    13c   human-side scale / offset / ground
    13d   match table + full frame -> humanoid.xml                delivers the last 2
    13e   viewer
    13g   two-bone analytic IK (optional refinement)

★ **13x AND 13f BOTH COME BEFORE ANY SOLVER WORK**, and neither needs a Jacobian: 13x writes
joint rotations directly, 13f copies them between skeletons. Together they deliver two of the
four missing clips AND the ground truth the solver is later checked against. Building the
solver first would mean debugging it with nothing to compare to.



- **13a. `jacBody`.** ★ **VERIFIABLE WITH NO IK, NO ROBOT, NO CAPTURE, NO RENDERER**: perturb
  `qpos[i]` by epsilon, re-run `kinematics`, and assert the body moved by `J[:, i] * epsilon`.
  A finite-difference test against the analytic Jacobian is exact to a tolerance and catches a
  wrong frame, a wrong cross-product order, and a missed DOF in the chain. **Write this test
  first** — every later phase rests on it, and §12 showed what an unverified foundation costs.
  ★ Free and ball joints make `nq != nv`; the test must cover a model with a free root.

- **13b. ONE TASK, ONE BODY.** Damped least squares on a single target:
  `(JᵀWJ + lambda I) dq = JᵀW e`. Drive one body to a fixed point and assert convergence.
  ★ No table, no capture, no scaling — if this does not converge, nothing downstream can.
  `factorM`/`solveM` (line 3422) are for the MASS matrix, not this; the IK normal equations are
  a separate small dense solve. **Do not reuse the name.**

- **13c. HUMAN-SIDE PREPARATION.** `scaleHumanPose`, `offsetHumanPose`, `groundHumanPose`, each
  a pure function over slices. ★ Testable without any robot: scaling by 1.0 is the identity;
  scaling by 0.5 halves every distance from the root and changes NO rotation; grounding puts the
  lowest point at exactly `ground_height`.

- **13d. THE MATCH TABLE + FULL FRAME.** Load JSON, resolve names, run table1 then table2 to
  convergence. Driven by `bvhForwardKinematics` output.
  ★ Verify against a DEGENERATE case first: retarget the human skeleton onto ITSELF with
  identity offsets and unit scale. The result must reproduce the input pose to solver tolerance.
  **That is the retargeting equivalent of the identity test, and unlike the bind-pose identity
  of §11 it is not vacuous — it exercises the whole solve.**

- **13x-1. `skeletonToModel` — DONE.** `robot.zig`: one body per bone, one BALL joint per bone,
  a FREE joint at the root, capsules sized from bone length, inertia from the capsule.
  `check` green.

  ★ **PLAIN SLICES, NOT A CLIP TYPE**: `(names, parents, offsets)`. `robot.zig` knows nothing
  about animation formats and does not start now — and this keeps it free of a dependency on
  `draw3d`. The caller unpacks whatever it has.

  ★ Verified by a property, not a picture: at `qpos0` the forward kinematics must place every
  body exactly where the rest offsets say. A three-bone chain 1 m apart lands at y = 0, 1, 2.
  **`nq > nv` is asserted explicitly** — the free root means `qpos` carries a quaternion, so a
  wrong layout fails here rather than drifting later.

  ★ The capsule spans BACKWARD from the body origin toward its parent, because a bone's offset
  is measured FROM the parent; drawing it forward would put every limb one segment ahead.

- **13x-2. ★★★ DIRECT-WRITE PLAYBACK — DONE AND VERIFIED.** `robot.poseFromLocalRotations`
  writes each bone's local rotation straight into its ball joint's `qpos` slice; the root's free
  joint takes the translation too. **No IK, no solver, no Jacobian.**

  ★★ **VERIFIED BY FAILURE, NOT BY GREEN.** The test compares the robot's `kinematics` against
  an independent FK walk of the same chain — positions AND orientations, with the
  quaternion double-cover handled. Then the quaternion order was deliberately written in
  MuJoCo's `(w,x,y,z)` instead of zm's `(x,y,z,w)`: **117 passed, 1 failed.** Restored: 118
  passed. The test catches the exact bug it exists for.

  ★ Field names that are NOT MuJoCo's, and cost five compile errors to learn:
  `Data.pos` (not `qpos`), `body_xrot` (not `body_xquat`), `Model.deinit()` (no allocator),
  `capsule.half_height` (not `half_length`).

- **13x-2c. ★★★ THE REAL SKELETON, THE REAL CAPTURE — DONE.**
  `src/tests/ragdoll_bvh_test.zig`: parse `dance1_20s.bvh`, build the ragdoll from its 96 joints,
  decode frame 120's channels, direct-write, and compare `robot.kinematics` against an
  independent FK walk. **Agreement within 1e-4 m on a 1.7 m figure — float noise, not
  tolerance.**

  ★ Why the synthetic four-bone test was not enough: it cannot reach a deep hierarchy where a
  parent error compounds, zero-length end sites, a travelling root, or 96 distinct quaternions.

  ★★ **VERIFIED BY FAILURE**: writing the quaternion in MuJoCo's (w,x,y,z) fails it across all
  96 bones; restoring zm's (x,y,z,w) passes.

  ★★ **AND ITS LIMIT IS DOCUMENTED IN THE FILE.** Both sides share `quatFromChannels`, so a
  wrong EULER DECODE cancels out — corrupting the channel order leaves the test green. That is
  the correct scope (this tests the qpos path, not the decoder), but it had to be MEASURED
  rather than assumed. A 0.0001 nudge of one quaternion component also passes, because the
  joint normalises: a control has to change the ROTATION, not just the numbers.

  ★ It runs in the FAST TIER — `codecs.zig` needs only `zm`, so the whole animation-to-robot
  path is shader-free and testable in seconds.

- **13x-2b. (superseded) THE DIRECT-WRITE PLAYBACK — a robot synthesized FROM the skeleton, playing the dance
  EXACTLY.** Sits between the character clips and `humanoid.xml`, and it is the most valuable
  test in this plan.

      pub fn skeletonToModel(gpa, clip: BvhSkeletalClip, opts) !robot.Model;

  One body per bone, one BALL joint per bone, a free joint at the root, body offsets taken from
  the rest pose, inertias from bone length and a density. The result is a ragdoll with Geno's
  exact topology and proportions.

  ★★ **THEN THE DANCE PLAYS ON IT WITH NO IK AT ALL.** A ball joint's `qpos` IS a quaternion,
  and BVH is exactly root translation plus per-joint rotations — so retargeting is a DIRECT
  WRITE of each bone's local rotation into its joint's `qpos` slice. Nothing to solve.

  ★★★ **THAT IS WHY IT IS THE RIGHT TEST.** It exercises the ENTIRE qpos path — quaternion
  layout, `jnt_qpos_adr`, `nq != nv`, free-joint handling, `kinematics` — with the SOLVER
  REMOVED. Every one of the predicted failures 4 and 5 (silent quaternion drift, shortest-arc)
  is reachable here, and any error is unambiguously plumbing rather than a limitation of the
  target. **`humanoid.xml` cannot give that signal**, because there errors are EXPECTED and a
  bug is indistinguishable from a knee that only has one hinge.

  ★★ **AND THEN RUN THE IK ON THE SAME MODEL.** The solver must converge to the answer the
  direct write already produced, to solver tolerance. That is ground truth for the IK —
  available BEFORE facing a target where nobody knows what the right answer looks like.
  A discrepancy is a solver bug, full stop.

  ★ Ordering consequence: **13x comes BEFORE 13a-13b are trusted**, because its direct-write
  half needs no Jacobian at all. Build the ragdoll, play the dance on it exactly, and only then
  is there something to check the Jacobian and the solver against.

  ★ It also delivers a ragdoll: with inertias and the source skeleton's joint limits it drops
  into `robot.zig`'s dynamics, which is the physical-tracking arc's starting point.

- **13x-3. ★ CAPSULE TUNING, VISUALLY — mesh and capsules together, semi-transparent.**
  Draw the skinned mesh AND the synthesized ragdoll's capsules in the same frame, one of them
  translucent, with `radius_ratio` / `min_radius` / `max_radius` / `density` as live sliders.

  ★ **CAPSULE SIZES CANNOT BE DERIVED, ONLY JUDGED.** `radius_ratio = 0.18` is a guess; a
  forearm and a thigh want different fractions of their length, and the only cheap test of
  "does this capsule fit this limb" is seeing them overlaid. The numbers then get baked in as
  new defaults, which is what makes this a tuning session rather than a permanent slider.

  ★ It also catches a class of bug nothing else does: a capsule pointing the wrong way along
  its bone is INVISIBLE in a rest-pose position test (the endpoints still land correctly) and
  obvious the moment it is drawn against the mesh. The backward-spanning capsule in 13x-1 is
  exactly that shape of mistake.

  ★ Mass follows radius squared, so this is also inertia tuning — a ragdoll whose forearms
  outweigh its thighs behaves wrongly and reads as a solver problem.

- **13e. VIEWER — `examples/mocap_robot`.** Capture on the left, robot on the right, one clip.
  `geno_dance`'s two-character layout is the proven shape, and its debug-inset discipline
  applies: show the TARGET markers and the per-task error, not just the final pose.

- **13e-2. THE TWO CHARACTER-TO-CHARACTER CLIPS (A1xT2, A2xT1) COME BEFORE THE ROBOT ONES.**
  ★ They need NO IK and NO robot: strip the `mixamorig:` prefix, map by name, compose the
  dropped spine joint into its parent, scale the root by height ratio. That is 13f's direct
  path, and getting it right validates the NAME MAPPING and the SCALING in isolation — the two
  things the IK path also depends on and would otherwise debug simultaneously.

- **13f-1. SKELETON-TO-SKELETON RETARGET — DONE.** `codecs.bvh.mapJointsByName`,
  `mappedCount`, `retargetRotations`, `scaleRootPosition`. `check` green, `test-fast` green.

  ★★★ **IT WORKS IN GLOBAL SPACE, WHICH IS BETTER THAN WHAT THIS PLAN PROPOSED.** The plan said
  to copy LOCAL rotations and "compose the dropped joint's rotation into its surviving parent"
  by hand. Unnecessary: taking the target's desired GLOBAL orientation from its source and
  converting to local against the already-resolved parent —

      dst_local[t] = inverse(dst_global[parent(t)]) * src_global[map[t]]

  — absorbs an unmapped source joint FOR FREE, because its rotation is already baked into the
  global orientation of the next mapped joint down the chain. LAFAN1's Spine3 and Neck1, which
  Mixamo lacks, need no special case at all.

  ★ Requires PARENTS BEFORE CHILDREN in index order — true of every skeleton here, and now
  asserted rather than assumed.

  ★ **VERIFIED BY FAILURE, TWICE.** Retargeting a skeleton onto ITSELF must return the pose
  unchanged; reversing the conjugate multiplication order fails it. And unlike §11's bind-pose
  identity — which holds for ANY bind and proved nothing — this exercises the whole path: name
  map, global-to-local, parent walk.

  ★★ **THE `mixamorig:` PREFIX IS STRIPPED AT MAP TIME**, and the silent-failure case is a
  test: with stripping off, a LAFAN1 table against Mixamo matches ZERO joints and would produce
  a REST POSE rather than an error. `mappedCount` exists so callers can refuse that, and the
  plan's rule stands — an unmapped required joint is a load error, not a quiet identity.

  ★ `scaleRootPosition` uses HIP HEIGHT, not total height: what must match is root travel
  relative to leg length. Two characters of equal height with different leg lengths take
  different strides.

- **13f-1b. READABILITY PASS — DONE.** `retargetRotations`, `mapJointsByName`, `stripPrefix`,
  `mappedCount`, `scaleRootPosition`, `skeletonToModel` and `poseFromLocalRotations` rewritten
  with verbose names and named intermediates: `target_joint`/`source_of_target` not `t`/`map`,
  `bone_is_long_enough` and `has_matching_source` as named booleans, `out_` on every
  out-parameter. Style rule recorded in claude.md.

  ★ Verified the rewrite changed nothing that matters: 118 robot tests pass, all 3 retarget
  tests pass, and reversing the conjugate multiplication order STILL fails the identity test.
  A readability pass that quietly disables a guard is worse than none.

- **13f-2. CROSS-RIG RETARGET ON REAL DATA — DONE (headless).**
  LAFAN1's `dance1_20s.bvh` retargeted onto the Mixamo skeleton extracted from `Drop_Kick.fbx`.
  `test-fast` green in 21 s, `check` green.

  ★★ **MEASURED: 72 OF 78 MIXAMO JOINTS FIND A LAFAN1 SOURCE** (the capture has 96). The six
  that miss are the rigs genuinely disagreeing — `HeadTop_End` vs `HeadEnd`, and end sites named
  differently. They keep their REST orientation, which is the correct degradation: a stiff
  fingertip, not a scrambled skeleton.

  ★★★ **THE PROPERTY THAT MAKES IT A RETARGET AND NOT A COPY**, and what the test asserts:
  every mapped joint ends up ORIENTED like its source (exact, 1e-5), while the target keeps its
  OWN bone LENGTHS. The test proves the second half too — it requires at least one mapped bone
  whose length differs from its source's, so two secretly-identical rigs cannot pass it.

  ★ The mapped-count threshold is deliberately far below 72: it exists to catch a REGRESSION in
  the prefix strip (which would give 0), not to pin a number a fixture change would break.

  REMAINING for the two clips: this is the SKELETON half. Driving a MESH with the result needs
  the target's bind pose, which `geno_dance` already has — that is viewer work, not solver work.

- **13f-3. THE MESHES ARE DRIVEN — all four clips selectable on screen.**
  `geno_dance` gains a "plays:" radio per character. Any character can be driven by any
  character's clip, so the four combinations — including A1xT2 and A2xT1, the two missing ones
  — are one tap apart. Smoke PASS, `check` green, 0 lint.

  ★★ **`bvhForwardKinematicsFromRotations` IS THE NEW PIECE, AND IT EXISTS FOR ONE REASON.**
  `bvhForwardKinematics` reads each frame's stored TRANSLATIONS, and on a capture like `dance1`
  every joint has position channels — so those translations encode the SOURCE's bone lengths.
  Using it for a retarget would hand the target the source's skeleton and silently defeat the
  whole exercise. The new one walks the TARGET's own rest offsets and takes only the root's
  translation, scaled.

  ★ **`source_is_self` IS PASSED, NOT INFERRED.** The tempting shortcut —
  `mapped_joint_count == 0` — conflates "not retargeting" with "the name map matched nothing",
  and the second is a bug the UI must report rather than quietly fall back from. The panel
  shows `mapped N/M joints` whenever a foreign source is selected.

  ★ Maps rebuild only on a selection change, not per frame: mapping is a string compare per
  joint pair.

  ★ A failed map falls back to the character's own clip AND says so in the status line — a
  stale map still driving a character is indistinguishable on screen from a solver bug, which
  is the failure this arc keeps having to design against.

- **13f-4. ★★★ REST-POSE ALIGNMENT — the legs bent backwards, and the cause was measurable.**

  Device showed Geno playing Drop_Kick with its legs in the wrong direction. Measured from the
  two files rather than guessed:

      LeftLeg    LAFAN1 (0,-1,0)   Mixamo (0,+1,0)   dot = -1.000
      LeftFoot   LAFAN1 (0,-1,0)   Mixamo (0,+1,0)   dot = -1.000
      LeftArm    LAFAN1 (0, 1,0)   Mixamo (0, 1,0)   dot = +1.000

  ★★ **THE LEG BONES POINT EXACTLY OPPOSITE AT REST WHILE THE ARMS AGREE** — which is why the
  arms looked right and only the legs were wrong. Copying global orientations assumes both rigs
  agree about rest; these do not.

  ★★★ **AND THE CORRECTION IS DERIVABLE, NOT AUTHORABLE.** This is GMR's hand-typed
  `rot_offset` column — one quaternion per match-table row. When both skeletons carry a rest
  pose (every BVH and FBX one does), that quaternion is exactly

      conjugate(source_rest[s]) * target_rest[t]

  so authoring it by hand is transcribing what the files already state. `restBoneOrientations`
  recovers a joint's rest orientation from where its bone POINTS — rest ROTATIONS are identity
  in these formats, all the shape is in the OFFSETS — and `restAlignmentOffsets` builds the
  correction. **This removes an entire hand-authored column from the plan's match table.**

  ★ The 180-degree branch of the shortest-arc has no unique axis and needs an arbitrary
  perpendicular. That is the LEG case, so it is the branch that actually runs, not a corner
  case to hand-wave.

  ★ **VERIFIED BY THE PROPERTY, plus a guard against it being a no-op**: feeding the retarget
  the SOURCE'S OWN REST orientations must produce every target joint at ITS OWN rest — rest maps
  to rest, which is what "align the T-poses" means. And the test asserts the alignment is NOT
  all identity, because a correction that silently becomes a no-op would pass the first check.

- **13f-5. UI ID COLLISION — FIXED.** The per-character "plays:" radio rows offered the same
  two labels, and a widget's identity comes from its LABEL — so both rows shared ONE radio
  group. Selecting a source for one character moved the other's, which made
  "Geno plays Drop_Kick" unreachable.

  ★ Fixed with `pushIdInt(row_index)` / `popId()` per row. Checked the other three examples
  using `radioButton` — all use distinct labels, so this was the only occurrence.

  ★ Recorded in claude.md: two controls that look independent and move together are an ID
  collision, not a state bug.

- **13f-6. HANDS AND FEET STILL BREAK — measured, not yet fixed.**

  With rest alignment on, limbs are correct and EXTREMITIES are not. Measured cause:

      LeftFoot   src(0, 0, 1)          dst(0, 1, 0)           dot = 0.000   via ToeBase
      LeftHand   src(0.50,0.69,0.52)   dst(-0.68,0.62,0.40)   dot = 0.296   via Thumb1

  ★★ **A JOINT'S REST DIRECTION IS TAKEN FROM ITS FIRST CHILD**, so a hand's orientation is
  defined by its THUMB and a foot's by its TOE. Those are near-arbitrary directions that the two
  rigs disagree about by ~72 and 90 degrees, where a limb bone points cleanly along +/-Y and the
  rigs broadly agree. **The construction is fine for limbs and ill-conditioned for extremities.**

  ★ First children were checked and MATCH (both `Thumb1`, both `ToeBase`), so this is not a
  child-ordering difference — the rigs genuinely place thumbs and toes differently.

  ★ SHIPPED AS A TOGGLE (`align rest poses`) rather than guessed at. The limb correction is
  verified by a test; the extremity behaviour is not, so both states are visible side by side
  instead of one being assumed better.

  NEXT HYPOTHESES, in order:
  1. **A direction alone underdetermines a frame** — shortest-arc leaves the twist unconstrained,
     which barely matters for a bone pointing along +/-Y and matters a great deal for a thumb.
     A two-vector frame (bone direction plus the parent's direction, Gram-Schmidt) pins it.
  2. **Extremities may want no alignment at all** — a hand's job is to follow its forearm, and
     inheriting the forearm's correction may beat deriving one from the thumb.
  3. GMR side-steps this entirely: its table maps `LeftFootMod` — the foot's POSITION with the
     TOE's ORIENTATION — a synthetic joint built precisely because the ankle frame is unhelpful.
     That is evidence the answer is a per-joint rule, not a better global construction.

- **13f-7. ★★★ THE ROOT CAUSE, FOUND IN GENOVIEW'S OWN RESOURCES.**

  `GenoView-InverseKinematics/resources` ships TWO pose files for the same 75-joint skeleton,
  and they answer the whole question. Their world poses, computed:

      Geno_bind.bvh     LeftHand (49.4, 102.6, -4.9)   arm DOWN      = A-POSE
      Geno_stance.bvh   LeftHand (65.0, 136.1, -1.9)   arm OUT       = T-POSE

  ★★ **`Geno_bind.bvh` MATCHES THE CLUSTER `TransformLink` VALUES MEASURED IN §11 EXACTLY**
  (49.4, 102.6, -4.9). Independent confirmation that the FBX skin bind pose and this file are
  the same thing — and that §11's conclusion was right.

  ★ The two files carry IDENTICAL ROTATION channels and differ only in POSITIONS. So "bind" vs
  "stance" is a difference of joint PLACEMENT, and a T-pose is a genuinely separate artifact
  that cannot be derived from the bind.

  ★★★ **AND THE ACTUAL BUG: MIXAMO'S REST ROTATIONS ARE NOT IDENTITY.** FK-ing Mixamo's
  offsets with identity rotations puts every bone along +Y:

      LeftHand (4.6, 212.0, 0.7)     straight up above the shoulder
      LeftFoot (8.2, 186.4, 0.0)     also up

  That is not a pose at all. **Mixamo's offsets are expressed in ROTATED local joint frames**,
  and `restBoneOrientations` assumed rest rotations were identity — true for a BVH, false for
  this FBX. Deriving a rest orientation from bone DIRECTIONS was therefore building the
  correction from garbage for the FBX side, which is why extremities broke while limbs
  survived: the limb error happened to be dominated by the real (0,-1,0)/(0,+1,0) flip.

  ★★ **THE FIX, AND IT USES DATA ALREADY EXTRACTED:**
    * **FBX side** — a joint's true global orientation at bind is the cluster `TransformLink`,
      which `FbxModel.bind` ALREADY holds (§11). Use its rotation block, not the offsets.
    * **BVH side** — needs an explicit T-pose file. `Geno_stance.bvh` is exactly that, and both
      it and `Geno_bind.bvh` are now in `intake/`.
    * Then `rest_alignment = conjugate(source_tpose_global) * target_tpose_global` with REAL
      orientations rather than ones inferred from where a thumb happens to point.

  ★ This is what Simon meant by "prepare T poses for both and align them carefully" — and the
  reason the derived version could not work is now measured rather than suspected.

- **13f-8. T-POSE ALIGNMENT IMPLEMENTED — from the bind data already in the file.**
  `draw3d.fbxBindOrientations` + `codecs.bvh.referenceOrientationsFromPose`. `check` green,
  6 retarget tests pass, smoke PASS, 0 lint.

  ★★ **NO NEW FILE WAS NEEDED FOR THE FBX SIDE.** A joint's true world orientation at bind is
  the skin cluster's `TransformLink`, rotations included — and §11 already extracts it into
  `FbxModel.bind` for skinning. The retarget now reads its ROTATION BLOCK as the reference
  pose. The translation is deliberately dropped: orientation aligns two rigs, size is
  `scaleRootPosition`'s job.

  ★ **DERIVATION IS KEPT AS A FALLBACK**, for a bare BVH with no bind data — where rest
  rotations genuinely ARE identity and the derivation holds. Selected by testing whether the
  bind is all-identity, so the right path is chosen from the DATA rather than from a flag the
  caller has to remember to set.

  ★★★ **AND THE CONDEMNING MEASUREMENT IS NOW A TEST.** FK-ing Mixamo's offsets with identity
  rotations puts the hand at (4.6, 212.0, 0.7) and the FOOT ABOVE THE HIPS. The test asserts
  exactly that — `foot_height > hips_height` — so the assumption that broke extremities can
  never be quietly reintroduced. A test that pins a KNOWN-BAD property is unusual and right
  here: it is the evidence for why the fallback is a fallback.

- **13f-9. ★★★ THE REFERENCES MUST DEPICT THE SAME PHYSICAL POSE — arms drooped 45 degrees.**

  Feet came out right with bind orientations; ARMS hung 45 degrees down. Simon named the cause
  and the mechanism confirms it exactly:

      Geno's FBX bind    = A-POSE  (hand at 102.6, hip height)
      Mixamo's FBX bind  = T-POSE  (arms out at shoulder height)

  ★★ `conjugate(mixamo_T) * geno_A` puts Geno in its **A-rest** whenever Mixamo sits in its
  T-rest, so every arm carries a constant droop for the whole clip. **Neither bind is wrong —
  they simply describe different configurations, and an alignment between them can only ever be
  as consistent as the two references are.**

  ★ Fixed by giving Geno `Geno_stance.bvh` — the same 75-joint skeleton in a T-POSE, which is
  precisely why GenoView ships it alongside the bind. Mixamo needs no file because its bind
  already IS a T-pose.

  ★ `referenceOrientationsFromTPoseBvh` forward-kinematics the pose file (a BVH stores LOCAL
  rotations; the reference needs WORLD ones) and matches joints **by name, not index** — the
  two loaders need not agree on ordering, and a silent index mismatch would rotate the wrong
  joints.

  ★★ **THE GENERAL RULE, worth carrying to `humanoid.xml`:** a retarget's reference poses are
  an INPUT, not something to be discovered. When a rig's bind is not the canonical pose, supply
  the canonical one. Deriving it, as §13f-6 tried, only works when the rest data happens to
  describe a real pose — and Mixamo's does not.

  Also fixed: the panel was 250px tall holding 651px of content, which the UI lint had been
  warning about on device — then at 660px it swallowed the whole phone screen. **Now four
  TABS** (Motion / Light / AO / Debug) in a 268px window.

  ★ Playback — play, mesh, skeleton, time — sits ABOVE the tab bar, because it is the one
  control wanted from every tab. Everything else belongs to exactly one concern, which is what
  makes tabs the right shape rather than a scroll region.

- **13g-1. ★★★ THE ROBOT CLIPS MAY NOT NEED IK AT ALL — `robot.fitLocalRotations`.**
  `check` green, `test-fast` green, 0 lint.

  This plan assumed `humanoid.xml` required iterative IK because its knee is ONE hinge
  (`range="-160 2"`) and its hip is three SEPARATE hinges rather than a ball. **That assumption
  was wrong, and the reason is closed-form:**

  ★★ A hinge's best angle for a desired rotation is a PROJECTION — the twist of that rotation
  about the hinge axis, from a swing-twist decomposition. A chain of orthogonal hinges is an
  Euler decomposition. Both are analytic. So the "best fit, not a match" that §4b said was all a
  robot's rotation task could achieve is available WITHOUT a solver, per joint, in one pass.

  ★★★ **AND IT REPORTS WHAT IT COULD NOT DO.** `out_residual_error` records the angle of the
  requested rotation each joint failed to represent. **That is the number that separates "the
  model cannot do this" from "the code is broken"** — precisely the distinction the adversarial
  review (§4c prediction 1) said would otherwise be impossible to make on a backflip that
  exceeds `abdomen_y`'s range.

  ★ Verified three ways, each a separate failure mode:
    * a pure bend about the hinge axis is represented EXACTLY (residual ~0)
    * a pure twist about an axis the hinge lacks gives residual > 0.9 — the loss is reported,
      not silently absorbed
    * a bend past the joint limit is CLAMPED, and the clamping is itself counted as loss, so a
      pose the robot could never hold never looks free

  ★ Joint limits are honoured in the fit rather than after it. `jnt_range` (robot.zig:1548) was
  in the plan's §4b list of things that would bite, and it does not, because it is applied where
  the angle is chosen.

  REMAINING for the two robot clips: the 16-row match table (LAFAN1 names -> `humanoid.xml`
  bodies), `humanoid.xml`'s reference orientations from its own `qpos0`, and the viewer. The
  Jacobian and damped-least-squares phases (§13a, §13b) are now OPTIONAL — worth building only
  if the analytic fit proves insufficient on real motion, which is a measurement, not a guess.

- **13g-2. THE MATCH TABLE — 16 rows, resolving against the real `humanoid.xml`.**
  `robot.lafan_to_humanoid` + `robot.resolveMatchTable`. `check` green, 0 lint.

  ★★ **NO WEIGHT COLUMN, unlike GMR's.** GMR pairs each row with position and rotation weights
  so its SOLVER can trade one task against another. `fitLocalRotations` needs none: it gives
  every joint the best rotation its DOF can express and REPORTS the shortfall. The weights
  existed to arbitrate between competing tasks; with a per-joint analytic fit there is nothing
  to arbitrate.

  ★★★ **AND THE INVERTED TREE COSTS NOTHING.** `humanoid.xml` roots at `torso` with `pelvis`
  hanging BELOW it through `waist_lower`; a BVH roots at `Hips` and the spine goes up. §4b
  flagged this as a trap that would make the robot translate from the wrong point. The
  global-space retarget handles it with NO special case — each body's local rotation is computed
  against whatever parent the ROBOT has, never the one the human has. **A local-rotation copy
  could not have done this at all**, which is the second time that design choice has paid.

  ★ **AN UNKNOWN BODY NAME IS AN ERROR**, and the test proves it by feeding in a typo. Without
  that check, a table of sixteen wrong names would "resolve" just as quietly as a correct one,
  and the symptom — a stiff limb — is indistinguishable from a solver bug. §4c prediction 5
  asked for exactly this to be a load error rather than a silent identity pose.

  ★ 16 robot bodies against LAFAN1's 96 joints: no shoulders, no spine chain past one waist
  segment, no toes, no fingers. Unmapped bodies keep their rest orientation, and the motion that
  carries a performance — limbs, torso, head — is all present.

- **13g-3. PER-BODY FITTING + THE ROBOT'S REFERENCE POSE — DONE.**
  `robot.fitBodyRotation` + `robot.referenceOrientationsFromRest`. `check` green, 382 tests in
  `robot_mjcf`, 0 lint.

  ★★★ **A STRUCTURAL GAP `fitLocalRotations` COULD NOT COVER: `humanoid.xml`'s hip is THREE
  hinges on ONE body** (`hip_x`, `hip_z`, `hip_y`) while the knee is one. A per-JOINT fit hands
  the same desired rotation to each hip hinge and applies it three times over. `fitBodyRotation`
  walks the body's joint chain, taking each joint's twist about its own axis and **REMOVING what
  it took before the next joint fits the remainder** — an Euler decomposition, closed-form.

  ★★ **MEASURED ON THE REAL MODEL:**

      thigh_left (3 hinges)   arbitrary rotation   residual = 0.0000   exact
      shin_left  (1 hinge)    0.8 rad across it    residual = 0.8000   all of it lost

  Three orthogonal hinges span SO(3), so a hip fits exactly. A knee loses precisely the angle it
  was asked to turn about an axis it does not have. **The residual is not a vague quality score
  — it is the angle that could not be represented**, which is what makes a MODEL limit
  distinguishable from a BUG.

  ★ **THE ROBOT'S REFERENCE POSE NEEDS NO EXTRA FILE**: `qpos0` IS the rest configuration, so
  kinematics on it gives every body's rest orientation. That completes the set — an FBX supplies
  its reference through cluster `TransformLink`, a BVH through a T-pose file, a MuJoCo model
  through `qpos0`. **Three formats, three sources, one meaning.**

  ★ A test-design mistake worth keeping: the first "the knee cannot do this" rotation was
  hardcoded as (0,1,0) and fitted EXACTLY — because that IS the knee's axis. A test for "cannot
  represent this" must construct something genuinely perpendicular TO THE MODEL'S OWN AXIS, or
  it measures nothing. Now derived from `jnt_axis`.

- **13g-4. THE FULL PIPELINE RUNS ON REAL DATA — AND THE NUMBER SAYS IT IS NOT GOOD YET.**
  Real `dance1_20s.bvh` -> real `humanoid.xml`: table resolved against both name sets, both
  reference poses built, retargeted, fitted, kinematics run. `check` green, 0 lint.

  ★★★ **MEASURED, frame 200: mean residual 1.095 rad (63 degrees), worst 2.272 (130).**
  A one-hinge knee losing a human knee's twist is expected and was predicted (§4c). **Sixty-three
  degrees on average is far more than that explains.**

  ★★ **THE LIKELY CAUSE IS THIS ARC'S RECURRING LESSON, IN A NEW PLACE: the two reference poses
  are not the same KIND of thing.** The robot's comes from `qpos0` — a REAL orientation. The
  human's comes from `restBoneOrientations` — a frame INFERRED from bone directions
  (zero-twist-from-+Y). Aligning a real orientation against an inferred one is exactly the
  character-side bug of §13f-7, repeated.

  ★ NEXT: give the human side a real T-pose (`Geno_stance.bvh`, already in `intake/`), and
  CHECK whether `humanoid.xml`'s `qpos0` depicts the same physical configuration a T-pose does.
  If it does not, the robot needs its own T-pose keyframe — MJCF supports `<key>` for exactly
  this, and `mjcf.readKeyframes` already exists.

  ★ **THE TEST ASSERTS THE MEASURED VALUE AS A CEILING, not as a quality bar** — `< 1.5` mean,
  `< 2.6` worst. It is a REGRESSION guard on a known-bad number, and the number is meant to
  fall. Writing it as if it were a pass would be the dishonest version.

  ★ It also pins that every mapped body received a pose, and that every body position is FINITE
  and within 100 m — a pose full of NaNs would satisfy a residual bound while being nonsense.

- **13g-5. REFERENCE MISMATCH FIXED — the residual HALVED.**

      inferred human rest  vs  robot qpos0   mean 1.095 rad  (63 degrees)
      REAL T-pose on both sides              mean ~0.5 rad   (29 degrees)

  ★★★ **MEASURED FIRST: `humanoid.xml`'s `qpos0` IS A T-POSE** — its hand sits at the same
  height as its upper arm. That is what made `Geno_stance.bvh` the right partner for it, and
  checking rather than assuming is what turned a guess into a fix.

  ★★ The old pairing put a REAL orientation (the robot's) against an INFERRED one (a frame
  built from bone directions). **That is §13f-7's bug in a new place**, and it is now the third
  time this arc has paid for mixing the two kinds. The rule is worth stating plainly:
  **a rest alignment is only as meaningful as the two references depicting the SAME PHYSICAL
  POSE, by the SAME KIND of measurement.**

  ★ What remains is genuine: a one-hinge knee cannot follow a human knee's twist, and 16 robot
  bodies cannot express what 96 human joints do. §4c predicted a non-zero residual before any
  of this was built.

  ★ The test's ceiling (`mean < 0.6`) is a REGRESSION GUARD on a measured value, found by
  bisecting the real number — not a quality bar, and meant to fall further.

- **13g-6. THE VIEWER — `humanoid.xml` STANDS BESIDE THE CHARACTERS AND PLAYS EITHER CLIP.**
  Smoke PASS with all GPU handles balanced, `check` green, 0 lint.

  ★★★ **ALL SIX CLIPS ARE NOW REACHABLE FROM THE UI:**

      A1 x T1  dance    -> Geno           native
      A2 x T2  backflip -> Mixamo         native
      A1 x T2  dance    -> Mixamo         retargeted, T-pose aligned
      A2 x T1  backflip -> Geno           retargeted, T-pose aligned
      A1 x T3  dance    -> humanoid.xml   retargeted + fitted
      A2 x T3  backflip -> humanoid.xml   retargeted + fitted

  ★ **THE ROBOT REUSED EVERY PIECE THE CHARACTERS NEEDED** and required no new machinery: the
  global-space retarget handles its inverted tree (torso root, pelvis below), `fitBodyRotation`
  decomposes each rotation across whatever DOF a body has, and its reference pose comes from
  `qpos0`. The only robot-specific code is loading the model and drawing capsules.

  ★★ **THE RESIDUAL IS ON SCREEN, in radians and degrees.** A 16-body robot cannot express what
  96 human joints do, and its one-hinge knee cannot follow a human knee's twist — so the number
  that says how much was lost sits next to the thing it describes. **Without it, a model limit
  reads as a bug**, which §4c predicted would be the hardest thing about this phase.

  ★ The robot draws whether or not the skeleton view is on: it has no mesh, so capsules are all
  it has, and `drawScene`'s early return on `show_skeleton` would have hidden it entirely.

- **13g-6b. ★★ THE ROBOT LAY FLAT — Z-UP, and the plan had already said so.**

  Device showed the robot as a horizontal sprawl while the residual read a healthy 0.43 rad
  (25 deg). Both facts were true: **the fit was working and the robot was upright IN ITS OWN
  FRAME** — MuJoCo models are Z-UP, and `robot_mjcf.build` keeps them that way on purpose
  (robot_mjcf.zig:33: its acceptance test is agreement with MuJoCo body for body, and a frame
  conversion inside it would turn a disagreement into two explanations).

  ★★★ **§2c OF THIS PLAN DECIDED "Y-UP, CONVERTED AT LOAD" AND I DID NOT APPLY IT.** The
  decision was recorded, the reasoning was right, and the code shipped without it. **A decision
  written down is not a decision implemented** — worth its own line, because the note read as
  if the work were done.

  ★ Fixed with the one-line root rotation robot_mjcf.zig:39 anticipates its callers applying:
  `(x, y, z)` -> `(x, z, -y)`, once, where robot data enters the scene. **Positions only, and
  that is the right scope** — the rest alignment already maps the Y-up human T-pose onto the
  Z-up robot T-pose, so the robot's ROTATIONS are self-consistent in its own frame and only the
  display needed converting.

  ★ Converted in `poseRobot`, not in the draw call, so every later consumer — contact, shadows,
  a second view — reads Y-up like the rest of zimr rather than each re-deriving it.

- **13g-6c. TWO BUGS: the robot danced IN PLACE, and its radio was unreachable.**

  ★★★ **THE ROOT NEVER TRANSLATED.** `fitBodyRotation` writes only the ROTATION half of a free
  joint — its own doc says the translation is the caller's business — and nobody was being the
  caller. The robot held `qpos0`'s position and danced with its torso pinned to the world.
  **A documented "caller's business" with no caller is a gap, not a design**, and the doc
  comment read as though it were handled.

  ★ Fixed by writing the free joint's translation after the fit, with the source root converted
  Y-UP -> Z-UP: `(x, y, z)` -> `(x, -z, y)`. That is the exact INVERSE of the conversion applied
  to the robot's output positions, and the two are now a matched pair that must move together.
  Scaled by hip height so a 1.7 m capture does not make a 1.28 m robot lunge.

  ★★ **THE ROBOT'S RADIO ROW REUSED THE CHARACTERS' LABELS**, and a `pushIdInt` scope alone was
  not enough to keep the selection reachable. Fixed with DISTINCT LABEL TEXT
  (`robot: dance1` / `robot: drop kick`). **A label that differs cannot be undone by a later
  edit; an id scope can** — which is the stronger fix even where scoping should have sufficed.

- **13g-7. ★★★ BACK TO THE DRAWING BOARD — what "retarget correctly" actually requires.**

  The robot was a scrambled handful of capsules at 0.70 rad (40 deg). Two findings, one fixed
  and one structural.

  ### FIXED: a rotation delta was never converted between world frames

  ★ First hypothesis eliminated cheaply: `humanoid.xml` has **NO body rotations at all** — no
  `quat`, `euler` or `axisangle` anywhere in the file. So `body_rot` is identity throughout and
  `robot_reference` (from `qpos0`) is IDENTITY FOR EVERY BODY.

  ★★★ That made the real bug visible. The motion being transferred is each joint's rotation
  relative to its T-pose, `delta = human_global * conj(human_T)` — **a rotation expressed in
  Y-UP COORDINATES.** Handing it to a Z-up robot applies the right angle about the WRONG AXIS:
  a forward bend becomes a sideways one. A rotation changes frame by a SIMILARITY TRANSFORM:

      delta_z_up = R * delta_y_up * conjugate(R),   R = +90 degrees about X

  ★★ **CONVERTING POSITIONS (13g-6b) DID NOT IMPLY THIS.** Positions transform by R alone;
  rotations need R on both sides. Doing the first and assuming the second was covered is the
  frame equivalent of scaling a mesh without its bind pose.

  ### STRUCTURAL: per-joint rotation fitting cannot place an end effector

  ★★★ **§13g-1's conclusion — "the robot clips may not need IK at all" — WAS TOO STRONG, and
  GMR's own table says why.** Re-read the weights:

      pelvis               pos 0,  rot 10
      left_knee_link       pos 0,  rot 10
      left_ankle_roll_link pos 50, rot 10     <- FIVE TIMES any rotation weight

  ★ A rotation-only fit orients each joint independently, so **error COMPOUNDS down the chain
  and nothing constrains where the hand or foot ends up.** On a robot whose limb lengths differ
  from the human's — which is the entire point of retargeting — the ankle lands wherever the
  accumulated orientation error puts it. **GMR weights the ankle's POSITION at 50 precisely
  because that is what stops a robot skating**, and a position target is not expressible as a
  per-joint rotation fit. It needs a Jacobian.

  ★ So the analytic fit is still right for what it does — a hinge's best angle IS a projection,
  and the residual it reports is honest and worth keeping. It is simply not sufficient alone.
  **§13a (`jacBody`) and §13b (damped least squares) go back on the critical path**, and the
  measurement that justifies them now exists rather than being assumed.

  ★ The right shape, from GMR: rotation fitting gives the INITIAL guess (cheap, close), then a
  few IK iterations pull the weighted position targets — ankles above all — onto the human's.
  That is why GMR iterates only `while curr - next > 0.001`: from a good start it converges in
  a handful of steps.

- **13a. `jacBody` — DONE, and verified by mutation, not just by passing.**
  Assembled from `cdof` exactly as the plan predicted: `jacp[:,j] = cdof[j].lin +
  cross(cdof[j].ang, offset)`, `jacr[:,j] = cdof[j].ang`, over the DOFs on the path from the
  body up to the world. **No new physics — `comPos` already produced everything needed.**
  `check` green, 0 lint.

  ★★★ **VERIFIED BY FINITE DIFFERENCE**, with no IK, no capture and no renderer: perturb one
  DOF, re-run kinematics, and the point must move by that column. Both mutations are CAUGHT:
  reversing the cross product, and dropping the body's own DOFs from the walk.

  ★★ **TWO TEST-DESIGN MISTAKES, both of which made a wrong Jacobian look right:**

  1. **The point was the body ORIGIN.** A body's own joint rotates ABOUT its origin without
     translating it, so an origin-point Jacobian is insensitive to that body's own DOFs — and
     the "skip its own dofs" mutation passed. Fixed with an OFFSET point.
  2. **The offset point was then measured wrongly.** The Jacobian was taken at the offset point
     while the finite difference measured the ORIGIN's motion — two different quantities, and it
     failed even the CORRECT Jacobian. The point has to be tracked as a MATERIAL POINT:
     `body_xpos + rotate(body_xrot, local_offset)`.

  ★ The perturbation goes through `integratePos`, never `qpos += v*dt`: a free joint's
  quaternion does not integrate by addition, and doing so drifts it off unit length while still
  looking plausible. §4c predicted this as the most likely silent wrong result.

- **13b. DAMPED LEAST SQUARES — DONE.** `robot.ikStep` + `IkTask` + `ikScratchSize`, solving
  `(JᵀW J + lambda I) dq = JᵀW e` with an in-place Cholesky. `check` green, 0 lint.

  ★ SPD by construction (`JᵀW J` is positive semi-definite for positive weights, damping makes
  it strictly positive), so a Cholesky suffices — no pivoting.

  ★★ **INTEGRATED, NEVER ADDED.** The step goes through `integratePos`, because `qpos` is longer
  than `nv` wherever a free joint carries a quaternion. `pos += step` looks right and drifts it
  off unit length.

  ★ Allocation-free: the caller owns the scratch, because this runs once per frame per
  character.

  ### ★★★ WHAT THE MUTATION TESTING FOUND

  * **Sign flip on the error — CAUGHT.**
  * **Damping removed — PASSED.** The convergence test uses a BENT chain, which is
    well-conditioned, so damping never mattered there. Damping exists for the SINGULAR case,
    and a test that never reaches one cannot justify it.
  * Fixed by adding an UNREACHABLE target, which pulls the chain straight — **the case a dance
    capture hits constantly**, at every fully extended knee and elbow.

  ★★ **AND THAT NEW TEST WAS WRONG FIRST.** It bounded `qpos` magnitude, and failed the CORRECT
  solver: a free root chasing a target 9 m away legitimately travels a long way. **The invariant
  is FINITENESS, not magnitude.** Third time this session a test has failed correct code — and
  each time the mutation check is what distinguished "the code is wrong" from "the test is".

  ★ The convergence test also checks the error falls MONOTONICALLY, not merely that it ends
  small: a solver that overshoots and oscillates can still land on a lucky iteration.

- **13c. IK WIRED INTO THE ROBOT PIPELINE — GMR's two-stage shape.**
  Smoke PASS, `check` green, 0 lint.

      stage 1   rotation fit per body        the INITIAL GUESS: cheap, close, no solver
      stage 2   a few `ikStep`s              weighted POSITION targets pull the ends on

  ★★★ **POSITION WEIGHTS ONLY WHERE THEY MATTER**, straight from GMR's table:

      feet    50     must land where the human's landed, or the robot skates
      pelvis  20     keeps the robot on the capture's path
      hands   10     read as intentional, but not at the feet's expense
      the rest 0     orientation only

  **A robot's limb lengths differ from a human's, so demanding EVERY joint's position would
  fight the skeleton against itself.** That asymmetry is the retargeting knowledge, and it now
  lives in the table as `position_weight`.

  ★ **GMR'S STOPPING RULE, not a fixed count**: iterate while the error is still falling by more
  than 0.001. From a good initial guess that is a handful of steps, which is exactly why the
  rotation fit earns its place rather than being replaced.

  ★★ **THE STAGE IS TOGGLEABLE — `ik steps: off / 4 / 8 / 16`.** Off is the A/B that says
  whether the position targets are helping, rather than assuming they must. Given §13g-1 already
  reached one confident conclusion about IK that turned out too strong, a switch beats a claim.

  ★ Targets are built RELATIVE TO THE ROOT before scaling, so the size ratio applies to the POSE
  rather than to a world position — a robot at the origin and a capture 3 m away must not be
  scaled apart.

- **13c-2. ★★★ BONE ORIENTATIONS STILL WRONG — and the cause is the SAME RULE, violated again.**

  Device: the robot is now a recognisable humanoid with limbs in the right places (the IK stage
  works) but every bone is oriented wrongly.

  ### The diagnosis, measured

      humanoid.xml   lower_arm_left  pos=".18 .18 -.18"     diagonal: out, forward, down
      humanoid.xml   thigh_left      pos="0 .1 -.04"
      humanoid.xml   body rotations  NONE ANYWHERE          quat/euler/axisangle absent

  ★★★ **THE ROBOT'S BONE DIRECTIONS LIVE ENTIRELY IN ITS POSITION OFFSETS**, and
  `robot_reference` is taken from `qpos0`'s body ROTATIONS — which are identity for every body
  and therefore carry NO direction information at all.

  Meanwhile the human's reference comes from the T-pose's ROTATIONS. So the alignment compares:

      robot   "body frame orientation"        identity, meaningless here
      human   "T-pose joint rotation"         real

  ★★ **THAT IS THE THIRD VIOLATION OF THIS ARC'S OWN RULE**, stated at §13g-5 and broken again
  immediately: *a rest alignment is only as meaningful as the two references depicting the same
  physical pose, BY THE SAME KIND OF MEASUREMENT.* "Real vs inferred" was one axis of that rule;
  **"body frame vs bone direction" is another, and I only checked the first.**

  ### The fix

  ★ Both references must answer the SAME question — **"which way does this bone point at
  rest?"** — computed the same way:

    * **robot**: bone directions from each body's child `body_pos` offset at `qpos0`, through
      `codecs.bvh.restBoneOrientations`, which is exactly that construction.
    * **human**: bone directions from the T-pose's FK POSITIONS, not from its rotation channels.

  ★ Note this makes the human side use `restBoneOrientations` again — but on the T-POSE's
  positions rather than the bind's, which is the part §13f-7 got wrong. The lesson was never
  "derived is bad"; it was "both sides must match". A DERIVED pair is fine; a mixed pair is not.

  ★ The IK stage is unaffected and already earning its keep: it pulls the ends onto the right
  PLACES, which is why the figure reads as humanoid at all despite every bone being turned.

- **13c-3. BONE-DIRECTION REFERENCES ON BOTH SIDES — DONE.**
  `robot.referenceOrientationsFromBoneDirections` + `characterBoneDirections` in the example.
  Smoke PASS, `check` green, 0 lint.

  ★★★ Both sides now answer the SAME QUESTION through the SAME construction — shortest arc from
  +Y onto the direction the bone points at rest. The robot reads its `body_pos` offsets (where
  its bone directions actually live); the character reads its rest-pose offsets.

  ★★ **THE CHARACTER KEEPS ITS OTHER REFERENCE TOO.** Character-to-character retargeting still
  uses real T-pose / bind orientations, because there BOTH sides are real. **The rule is that
  the two sides must match — not that any one construction is universally right.** A derived
  pair is fine; a mixed pair is not. That distinction is what §13f-7 got wrong in the opposite
  direction.

  ★ Pinned by a test that shows the difference directly: with all body rotations identity — the
  `humanoid.xml` shape — the body-frame read returns identity for EVERY body while the
  bone-direction read distinguishes a +Y bone from a +X one.

  ★ A test-sizing mistake worth recording: the array was sized to the BONE count, but `nbody`
  includes the WORLD body, so a 3-bone skeleton makes 4. The short array silently capped the
  child search and reported every orientation as identity — which looked exactly like the code
  bug it was meant to detect. Now asserts `nbody == 4` before relying on it.

- **13c-4. ★★★ A REFERENCE ORIENTATION IS A FRAME CORRESPONDENCE, NOT A POSE TO REACH.**

  Device with IK OFF: the robot went horizontal again and the residual JUMPED to 1.53 rad
  (88 deg) — worse than the 0.43 it had before the bone-direction change.

  ### Why

  The formulation was `want = delta * robot_bone_dir`. At the human's rest `delta` is identity,
  so the robot was sent TO its bone-direction orientation — and **the torso's bone points +Z**,
  so the whole robot tipped over.

  ★★★ **THE ROBOT'S REST CONFIGURATION IS `qpos0`, WHOSE BODY ROTATIONS ARE IDENTITY.** The
  bone directions are not a pose; they say how the two skeletons' AXES CORRESPOND. Multiplying
  by one confuses a change of basis with a target.

  ### The right shape

      A     = robot_bone_dir * conjugate(human_bone_dir_in_robot_frame)
      want  = A * delta * conjugate(A) * robot_rest

  ★★ **THE CORRESPONDENCE BELONGS ON BOTH SIDES OF THE DELTA.** At the human's rest, `delta` is
  identity and `want` is `robot_rest` — **rest maps to rest**, the property silently lost by the
  one-sided version. And a human rotation about axis `n` becomes a robot rotation about `A n`,
  which is what "the same motion on a differently-built skeleton" actually means.

  ★ This is the SECOND time this arc has needed a similarity transform where a single
  multiplication looked sufficient — the first was the Y-up/Z-up world frame (§13g-7). **Both
  have the same tell: a rotation being moved between frames, not composed within one.** A
  rotation changes frame with the conjugate on both sides; only a pose composes on one.

  ★ `rest maps to rest` is now the property to TEST for the robot pairing, exactly as it is for
  the character pairing — it would have caught this before the device did.

- **13d. ★★★ REBUILT AS GMR ACTUALLY DOES IT — SE3 TARGETS, NO DECOMPOSITION.**
  Smoke PASS, `check` green, 0 lint.

  ### What GMR does, read from the source rather than inferred

      setup_retarget_configuration:  one mink.FrameTask per row, position_cost + orientation_cost
      update_targets:                task.set_target(SE3.from_rotation_and_translation(rot, pos))
      retarget:                      solve_ik over ALL tasks at once

  ★★★ **GMR SETS A FULL SE3 TARGET — POSITION AND ORIENTATION, BOTH IN WORLD SPACE — TAKEN
  STRAIGHT FROM THE HUMAN'S CORRECTED POSE, AND SOLVES EVERY TASK TOGETHER. It never computes
  per-joint local rotations and never decomposes anything.**

  ### Why three attempts failed

  ★★ Every previous version computed `local = conj(parent_DESIRED_global) * desired_global`.
  **That assumes the parent REACHES its desired orientation** — and `humanoid.xml`'s knee is one
  hinge, so it cannot. Every child was then solved against a parent that was wrong, and the
  error compounded down the chain.

  **The 89-degree residual was never one joint's honest shortfall; it was accumulated
  inconsistency.** A solver has no such problem: when a parent falls short it compensates with
  the child, because it optimises all joints against all targets simultaneously.

  ★ That also explains why each frame-algebra fix (world-frame conjugation, bone directions,
  axis correspondence) was individually right and made no real difference. **They were correct
  repairs to a mechanism that could not work.**

  ### What was kept

  ★ `ikStep` gained ORIENTATION rows: error is the rotation vector of `target * conj(current)`
  in world space, Jacobian is `jacr`. Position and orientation stack into one normal-equations
  solve.

  ★ The derived rest alignment survives, but as GMR's `rot_offset` — **applied to the TARGET**,
  not used to compute joint locals. Still bone-direction on both sides, still the same kind of
  measurement.

  ★ `fitBodyRotation` remains and is still correct for what it does; it is simply no longer the
  mechanism. Its residual was an honest per-joint number and a misleading whole-pose one.

  ★ Each frame starts from `qpos0` rather than warm-starting, so a bad frame cannot poison the
  next — worth more than the iterations it costs while the pipeline is still being trusted.
  Default raised to 30 steps, with 10/30/80 selectable.

- **13d-2. ★★★ THREE QUANTITIES, PREVIOUSLY CONFLATED — and a rest check that runs every frame.**

  Still broken on device. The cause was not the mechanism this time but the FORMULA, and it is
  the same confusion that has driven every failure in this arc:

      H_rest   the human's T-POSE ANIMATION rotation for a joint
      h        the human's rest BONE DIRECTION frame
      b        the robot's rest BONE DIRECTION frame

  ★★★ **`H_rest` AND `h` ARE NOT THE SAME THING.** One is where a joint's frame points at rest;
  the other is where its BONE points. Every version so far used one where it needed the other —
  which is exactly why each frame-algebra repair (world conjugation, bone directions, axis
  correspondence) was individually CORRECT and changed nothing that mattered.

  The formula, written out:

      delta = R (H * conj(H_rest)) R⁻¹      the MOTION, in the robot's frame
      M     = b * conj(R h R⁻¹)             the human's bone frame -> the robot's
      want  = M * delta * conj(M)           the motion, on the robot's bones

  ★ At the human's rest, `delta` is identity and `want` is identity — **which IS the robot's
  rest**, since `humanoid.xml` declares no body rotations. And a human rotation about axis `n`
  becomes a robot rotation about `M n`.

  ### ★★ THE REST CHECK NOW RUNS EVERY FRAME AND IS ON SCREEN

  Feed the target formula the human's OWN REST rotations; every target must come out identity.
  **This is the property all three failed attempts lost SILENTLY**, and it costs one pass over
  16 bodies to verify continuously rather than discovering it from a screenshot.

  ★ Reported, not asserted — a wrong value should show as a number climbing in the UI, not kill
  a demo mid-frame. `rest check` must read 0.0000.

  ★★ **THIS IS THE INVARIANT I SHOULD HAVE WIRED IN FIRST.** It exists for the character
  pairing as a unit test and I reasoned about it for the robot instead of measuring it — four
  device rounds, every one of which it would have caught before shipping.

- **13d-3. ★★★ I SHIPPED A VACUOUS CHECK — TWICE — AND THE REAL NUMBER SAYS OVER-CONSTRAINT.**

  Device: `rest check 0.0000`, `ik error 0.593`, robot still splayed.

  ### The rest check was worthless, and I wrote it

  ★★★ It computed `qmul(rest_orientations[j], conj(rest_orientations[j]))` — **identity for ANY
  quaternion.** It read 0.0000 while proving nothing. My replacement was `qmul(c, conj(c))`,
  **also identity for any input.** Two vacuous checks in a row, of exactly the kind this
  session's own notes warn about three times over.

  ★ **REMOVED rather than guessed a third time.** A real one has to compare against something
  EXTERNAL — solve with the human at its T-pose and assert the robot ends up STANDING, head
  above pelvis above feet. That needs its own solve and belongs in a TEST, not the frame loop.

  ★★ The lesson generalises: **a self-referential check is not a check.** `f(x, conj(x))` can
  only ever report what algebra guarantees. A check must involve a value the code under test did
  not produce.

  ### The real number: 0.593 is over-constraint, not a solver bug

  ★★★ 16 mapped bodies asking 3 position + 3 orientation components each is **96 constraints
  against `humanoid.xml`'s 27 DEGREES OF FREEDOM.** A least-squares solve of that satisfies
  nothing well. The solver is working; the system has no good answer.

  ★★ **GMR'S WEIGHTS CANNOT TRANSFER, and that is the deeper reason a faithful port still looked
  wrong.** G1 has roughly twice the DOF and a real shoulder chain. `humanoid.xml` has ONE waist
  segment, NO shoulders, and a single-hinge knee. Copying `rot_weight = 10` onto all 16 bodies
  imported a number that only made sense on a richer robot.

  ★ Fixed by making `rotation_weight` per-row, requested only where the robot can deliver it —
  torso, thighs, upper arms, feet, head. Bodies whose orientation is a CONSEQUENCE of their
  chain (shins, forearms, the pelvis hanging under the torso) get position only, and no
  orientation row is emitted at all for them.

- **13e. ★★★ ONE BONE AT A TIME — Simon's plan, and it should have been the plan all along.**

  ### The framing that was missing

  ★★★ *"Focus on the torso bone. Place it on the torso of the anim. Then work out the others.
  Orientation will be important, then IK should only be a quality bonus."*

  **That is right, and it reframes everything.** ORIENTATION IS THE SUBSTANCE of retargeting;
  IK is refinement. I had been solving sixteen bodies simultaneously and **never once verified a
  single one** — four device rounds where any bone might have been wrong and none could be
  isolated.

  ### What changed

  ★★ **THE TORSO IS NOW WRITTEN, NOT SOLVED.** It is the root body and carries the free joint,
  so its position and orientation span six DOF with no chain above them — the target is
  reachable EXACTLY. Asking a solver for something directly writable only adds error.
  **If the torso alone does not land on the human's torso, nothing below it can help.**

  ★ **`bones: 1 / 2 / 4 / 8 / 16`** — how many mapped bodies take part. Start at 1, verify, add
  the next. The bar for each is visual and immediate: does this bone sit where the character's
  does, pointing the same way?

  ★ **`ik error` now reports `-- (solver idle)`** when the solver did not run. It was showing a
  stale `0.000` with IK OFF, which reads as a perfect result and is the same class of mistake as
  the vacuous rest check — a number that looks like success while measuring nothing.

  ### Why this beats what came before

  ★★ Every previous round changed a formula and re-ran the whole sixteen-body solve, so a fix
  and a regression were indistinguishable. With one bone placed directly there is no solver, no
  weights and no chain — **just a frame transform, either right or wrong on sight.** The next
  bone is only added once the current one is right, so the first bad one is always the newest.

- **13e-2. ★ TORSO POSITION CONFIRMED ON DEVICE — the first verified thing in this arc.**
  `bones: 1`, IK off: the torso lands on the character's torso. **Position is right, which
  means the scale, the root offset and the Y-up/Z-up conversion for POSITIONS are all correct.**
  Everything remaining is orientation.

- **13e-3. SEVEN CANDIDATE ORIENTATION FORMULAS, SELECTABLE BY RADIO.**

  ★★★ Simon's suggestion, and the right call: **deriving the correct formula has cost several
  device rounds and each derivation looked sound at the time.** Picking between the candidates
  by eye takes one sitting.

      none      the robot ignores the human            sanity: nothing else moves the bone
      raw       R H R⁻¹                                the human's world orientation IS the robot's
      delta     R (H conj(H_rest)) R⁻¹                 motion from rest, onto the identity rest
      conj M    M delta conj(M)                        the derivation's answer
      post M    delta * M                              correspondence composed AFTER
      pre M     M * delta                              ...and BEFORE
      flip R    conj M with the up-axis turned the other way

  ★ They are not arbitrary guesses — **each is a specific claim about what the reference
  means**, and which one looks right is itself the answer to a question I have not been able to
  settle on paper.

  ★ `none` is the control: with it selected the bone must sit at the robot's rest orientation.
  If anything else moves, something outside this formula is writing the pose.

- **13f. ★★★ THE ANSWER: `raw` PLUS A FACING YAW. Most of this arc solved a problem that does
  not exist.**

  Device, cycling the seven: **`raw` is right** — with a 90-degree yaw offset.

  ### What that means

  ★★★ **`raw` is `R H R⁻¹`: the human's world orientation IS the robot's.** No rest removal, no
  bone correspondence, no per-joint alignment. The T-pose references, the bone-direction
  frames, the axis-correspondence conjugation — **all of it was machinery for a correction that
  is not needed.**

  ★★ What IS needed is a single GLOBAL difference: the two skeletons **FACE different
  directions.** A capture authored facing one way, a MuJoCo model authored facing another. One
  yaw about the world up axis, shared by every bone.

  ### Why the whole arc missed it

  ★★★ **A per-joint framework cannot express a global constant.** Every attempt assumed the
  correction varied per bone — that is what a rest alignment IS — so the search never included
  "one number for all sixteen". Each formula was then repaired against a symptom that a single
  yaw would have removed entirely.

  ★ And the shape of the evidence was there: the robot was consistently WRONG IN THE SAME WAY
  across every bone, which is the signature of a global error, not an accumulation of local
  ones. I read it as "everything is broken" instead of "everything is broken IDENTICALLY".

  ### Shipped

  ★ `raw+yaw` applies the yaw on the LEFT — a WORLD-space correction, rotating the whole result.
  `yaw right` applies it on the right for comparison, which turns each body about its OWN axis
  instead: a different claim that looks different on a limb, and worth being able to tell apart.

  ★ The yaw is about **Z**, the robot's up axis — not Y, which is up on the character side.
  That distinction would tip the robot rather than turn it.

  ★ Live slider, so 90 can be confirmed rather than assumed, and the sign settled by eye.

- **13f-2. YAW CONFIRMED AT -90, AND BOTH FACINGS MEASURED.**

      LAFAN1    LeftToeBase offset (Y-up)  = (0, 0, 15.26)       character faces +Z
      humanoid  foot geom fromto (Z-up)    = -.07 -> +.14 in x    robot faces +X

  ★★★ **A quarter turn apart, and nothing else differs.** That is the entire correction — one
  number shared by all sixteen bones — and it is the post-rationalisation for why every
  per-joint rest alignment this arc built was machinery for a problem that does not exist.

  ★★ **THE DERIVATION DISAGREES WITH THE DEVICE, AND THAT IS RECORDED RATHER THAN SMOOTHED
  OVER.** Mapping Y-up to Z-up as `(x, y, z) -> (x, -z, y)` sends the human's +Z forward to -Y;
  taking -Y to +X is **+90** about Z on paper. The device wants **-90**. So one of two sign
  conventions is opposite to my assumption — the handedness of that map, or zm's rotation sense.

  ★ The measured value is authoritative. **A derivation that disagrees with the device is a
  derivation with a bug in it**, and writing "+90 by symmetry" over a working -90 would bury a
  real inconsistency for the next reader. Worth chasing when the pipeline is done, not now.

  ★ Defaults: `raw+yaw` at -90, **all sixteen bones**. The 1/2/4/8 bisection steps stay, so a
  future problem can be narrowed the way this one finally was.

- **13g. ★★★ GMR'S `rot_offset` COLUMN, READ PROPERLY — the answer to "a weird mapping each?"**

  From `bvh_lafan1_to_g1.json`, all fourteen rows:

      [ 0.5,   0.5,   0.5,  0.5]   pelvis, torso
      [-0.5,   0.5,   0.5, -0.5]   hips, knees        (both sides)
      [-0.707, 0.707, 0,    0  ]   ankles             (both sides)
      [ 0.5,   0.5,  -0.5, -0.5]   shoulders          (both sides)
      [ 0.707, 0.707, 0,    0  ]   elbows, wrists     (both sides)

  ★★★ **NOT PER BONE — PER GROUP. Five distinct values for fourteen bones.** And every
  component is exactly +/-0.5 or +/-0.707: these are **axis-permutation quaternions**, 90 or 120
  degree turns. Not tuned numbers — discrete frame relabelings, one per limb-segment
  convention in the robot's URDF.

  ★★ **AND THAT IS A PROPERTY OF G1, NOT OF RETARGETING.** G1's links each carry their own
  frame convention, so the table needs one offset per convention. **`humanoid.xml` declares NO
  body rotations at all** — every body is world-aligned — so it has ONE convention, and one
  global offset is genuinely enough. The single -90 yaw is not a shortcut; it is what this
  robot's table degenerates to.

  ### But the human side still varies per joint

  ★ **`raw` works on the TORSO because a spine's T-pose rotation is near identity**, so `raw`
  and `delta` coincide there. An ARM in a T-pose points sideways and its T-pose rotation is
  emphatically not identity — `raw` hands the robot that absolute orientation and the limb comes
  out turned.

  ★ So the prediction is: **`delta+yaw` should fix the limbs while leaving the torso unchanged.**
  Added as mode 9. The yaw CONJUGATES the delta rather than multiplying it, because a
  rest-relative rotation moving between frames takes the conjugate on both sides — the third
  time this arc has met that rule.

  ★ **This is a falsifiable prediction, not another guess**: if `delta+yaw` fixes limbs and
  keeps the torso, the model is right. If it fixes limbs and BREAKS the torso, the human's
  spine T-pose rotation is not near identity and that assumption needs measuring.

- **13h. ★★★ THE ROBOT HAD NO WAY TO POSE ITS BONES AT ALL — every orientation A/B was
  testing only the torso.**

  Device: with IK off the humanoid's bones do not move. Obvious in hindsight and it invalidates
  several rounds of work:

  ★★★ **A ROBOT BODY HAS NO WRITABLE ORIENTATION.** Everything below the free root reaches its
  pose ONLY through joint angles. `poseRobot` wrote the root and built TARGETS for the rest —
  and a target does nothing unless a solver consumes it. **With IK off the robot was rigid at
  rest, translated by its root and nothing more.**

  ★★ So every orientation experiment at `bones: 16, ik: off` — raw, delta, conj M, post M,
  pre M, flip R — **was comparing formulas that only ever reached ONE body.** "raw+yaw fixes
  the torso" was true and told us nothing about the other fifteen, because nothing else could
  move whatever the answer.

  ★ The tell was there in the plan's own framing: *"orientation is the substance, IK is a
  quality bonus"* is only achievable if orientation is APPLIED without IK. It was not.

  ### The fix, and the flaw it repairs

  Each body's desired world orientation is now converted to a LOCAL rotation and fitted onto
  whatever DOF it has, before the solver runs.

  ★★★ **AGAINST THE PARENT'S ACHIEVED ORIENTATION, NOT ITS DESIRED ONE.** That was the fatal
  flaw in the earlier decomposition (§13d): a hinge parent cannot reach what it was asked for,
  and solving a child against the REQUEST rather than the RESULT compounded error down the
  chain. `kinematics` is re-run per body so each child sees what its parent actually did — 16
  cheap calls a frame, and the difference between a correct decomposition and the one that
  produced 89 degrees of residual.

  ★ Bodies are visited parents-first (MuJoCo's ordering), and the ROOT's `kinematics` was moved
  INSIDE the loop — leaving it until after fed every child a stale root, which is a wrong
  answer rather than a missing one.

- **13i. ★★★ "AIM" — POSE THE BONE BY ITS DIRECTION, FROM FIRST PRINCIPLES.**

  The robot stands with recognisable limbs; the forearms point backwards. That is not a subtle
  twist error — **the segment is aimed the wrong way**, so aim it directly rather than matching
  a full orientation and hoping the direction follows.

  ### Why this sidesteps everything that has gone wrong

  ★★★ **POSITIONS ARE ALREADY VERIFIED CORRECT** — the torso lands on the character's torso, so
  the scale, root offset and Y-up/Z-up position conversion are all right. **The human's bone
  DIRECTION, converted with that SAME conversion, is therefore correct by construction.**

  ★★ So: no T-pose reference, no rest alignment, no bone-direction quaternions, no facing yaw.
  **A direction comparison carries its own frame.** Every one of those was an attempt to relate
  two ORIENTATION conventions; a direction has no convention to relate.

  ### The construction

      d_robot   the body's FIRST CHILD offset, normalised, in local coordinates
      d_human   the capture's joint-to-child-joint direction, through the position conversion
      W         shortestArc(d_robot -> d_human), a WORLD rotation
      local     conj(parent_ACHIEVED) * W, fitted onto whatever DOF the body has

  ★ Shortest arc because **twist about a bone is unobservable in its direction** — picking the
  twist-free rotation is the honest default, not an arbitrary choice. Twist is what the IK
  refinement and the rotation targets are for, and it is genuinely secondary on a limb.

  ★ Selected as `AIM (bone direction)`, so it sits beside the ten frame-algebra candidates and
  can be judged against them rather than replacing them on my say-so.

- **13j. ★★★ THE T-POSES MEASURED SIDE BY SIDE — legs already match, only the ARMS differ.**

      torso           robot( 0.00, 0.00, 1.00)   human( 0.00, 0.00, 1.00)   MATCH
      thigh_left      robot( 0.00,-0.02,-1.00)   human( 0.00, 0.04,-1.00)   MATCH
      shin_left       robot( 0.00, 0.00,-1.00)   human( 0.00, 0.14,-0.99)   close
      upper_arm_left  robot( 0.58, 0.58,-0.58)   human( 1.00,-0.00,-0.02)   ~55 deg apart
      lower_arm_left  robot( 0.58,-0.58, 0.58)   human( 1.00,-0.00,-0.05)

  ★★★ **TORSO AND LEGS ALREADY AGREE.** The human T-pose through the POSITION conversion
  matches the robot's rest for spine and both legs — which is why those always looked plausible,
  and confirms the position conversion was never the problem.

  ★★ **`humanoid.xml` RESTS ITS ARMS ON A DIAGONAL** — down, out and forward — not straight out.
  **Its `qpos0` is a T-pose for the LEGS and an A-POSE for the ARMS.** An earlier check compared
  hand height against shoulder height and pronounced the whole model a T-pose: too coarse to see
  the arms differ, and it sent several rounds chasing a GLOBAL fix for a PER-LIMB problem.

  ★★★ **AND THAT IS EXACTLY WHY GMR'S TABLE HAS DIFFERENT OFFSETS PER LIMB GROUP.** Its
  shoulders carry `[0.5, 0.5, -0.5, -0.5]` where hips and knees carry `[-0.5, 0.5, 0.5, -0.5]`
  — not per-bone tuning, but the plain fact that **a robot's arm convention and its leg
  convention genuinely differ.** I read that table three times and treated it as tuning noise.

  ★ Now a permanent test rather than a comment: it ASSERTS the legs and torso agree (dot > 0.95)
  and that the arm does NOT (dot < 0.75). The known-good and the known-bad are both pinned, so
  the next change cannot quietly break the half that works.

- **13k. PER-LIMB CORRECTION, DERIVED FROM THE TWO REST POSES — `delta + limb fix`.**
  Smoke PASS, `check` green, 0 lint.

  For every mapped body: the rotation taking the HUMAN's rest bone direction onto the ROBOT's,
  computed once at load. Then the motion is expressed in the robot's own limb frame:

      want = C * delta * conj(C)

  ★★★ **THE SAME CODE PRODUCES "NO CORRECTION" WHERE NONE IS NEEDED.** Torso and legs get
  identity automatically because their directions already agree; the arms get their ~55 degrees.
  No rule exempts the legs — the measurement does.

  ★★ This is GMR's `rot_offset` column **computed rather than hand-authored**, and the reason
  theirs varies per limb GROUP is precisely this: a robot's arm convention and its leg
  convention differ. Their five values are five limb conventions, not five tuning passes.

  ★ At the human's rest, `delta` is identity and `want` is identity — **the robot keeps ITS
  rest, diagonal arms and all**, which is correct. A robot standing still should look like
  itself, not like a human.

  ### ★★ AND A CORRECTION I OWE THE RECORD

  **`delta+yaw` was never fairly tested.** Every mode comparison before §13h reached only the
  torso, so it was dismissed on evidence that could not exist. It may well be right on its own:
  `delta` keeps the robot's rest and applies motion relative to the HUMAN's rest, which is
  already the correct behaviour for a robot whose arms rest diagonally.

  ★ Worth trying BOTH now that bones are actually posed — `delta+yaw` and `delta + limb fix` —
  because if the plain one suffices, the limb correction is unnecessary machinery and should go.

- **13l. ★★★ HEADLESS VERIFICATION OF THE RIGHT FOREARM — no eye required, and it found the
  real culprit.**

  A test poses the robot across 24 frames of the capture under each candidate formula and
  measures the RIGHT FOREARM against the human's:

      delta_only      agreement -0.634   spread 0.603
      delta_limb_fix  agreement  0.027   spread 0.503
      aim             agreement -0.087   spread 0.661

  ★ **BOTH numbers are needed.** `agreement` is the mean cosine against the human's forearm
  direction (+1.0 is correct). `spread` is how much the ROBOT's own direction varies —
  **a rigid arm can score well on agreement alone if the human's arm happens to sit near it**,
  which is exactly the trap that let a frozen robot survive several rounds of eyeballing.

  ★ The spreads are healthy, so the arm genuinely moves. The pipeline runs; the failure is in
  DIRECTION, not liveness.

  ### ★★★ AND `aim` IS THE DIAGNOSTIC RESULT

  **`aim` aims the bone AT the target by construction, so it should score near +1.0.** It scores
  -0.087. That means **`fitBodyRotation` DESTROYS THE AIM**: it decomposes a world-target
  ORIENTATION across the body's joints, minimising ROTATION error — which is not the same as
  minimising DIRECTION error, and a two-hinge shoulder has no reason to preserve one while
  optimising the other.

  ★★ **THE ORIENTATION FORMULA MAY NOT BE THE PROBLEM AT ALL.** The decomposition is discarding
  whatever the formula asks for, which would make every formula comparison in this arc — all
  eleven modes — a measurement of the fit rather than of the formula.

  ★ Next, and cheap: measure the aim BEFORE and AFTER `fitBodyRotation` on one body.

- **13m. ★★★ MEASURED — AND MY HYPOTHESIS WAS WRONG. The fit is fine; the ELBOW is one hinge.**

      shoulder   dof 2   aim construction 1.000 -> delivered 1.000   (rotation residual 0.057)
      elbow      dof 1   aim delivered -0.010

  ★★ **`fitBodyRotation` PRESERVES THE AIM.** A 2-DOF shoulder delivers the requested direction
  exactly. The claim that every formula comparison in this arc measured the fit rather than the
  formula is **false**, and the test that asserted it has been renamed to say so — a test whose
  NAME states a refuted hypothesis is worse than no test.

  ★★★ **THE ELBOW IS ONE HINGE AND CANNOT AIM AT ALL.** It swings in a single plane, so an
  arbitrary target gives -0.010 — perpendicular. **The pipeline's -0.087 on the forearm is
  exactly what a one-hinge elbow produces. That is the MODEL, not a bug.**

  ### ★★★ WHICH SPECIFIES THE FIX

  **A forearm cannot be aimed; it can only be BENT.** So the arm chain needs two different
  treatments, and treating them alike is what has been wrong:

    * **shoulder (2 DOF)** — AIM the upper arm at the human's upper-arm direction. Proven to
      work: 1.000.
    * **elbow (1 DOF)** — set the hinge to the human's ELBOW FLEXION ANGLE, the angle between
      the human's upper arm and forearm. Not a direction, a scalar.

  ★ The forearm's direction then follows from the shoulder being right plus the correct bend —
  which is how a real arm works, and why a hinge is the right model for an elbow.

  ★★ The same split applies to the leg: hip aims (3 DOF), **knee bends (1 DOF)**. §4b flagged
  the single-hinge knee as a limitation to report; it is really an instruction about which
  ALGORITHM each joint needs.

- **13n. THE SPLIT IMPLEMENTED — and it produced the largest gain of the arc.**

                          BEFORE the bend fix    AFTER
      delta_only              -0.634              +0.151
      delta_limb_fix          +0.027              -0.231
      aim                     -0.087              -0.196

  ★★★ **BENDING THE ONE-HINGE JOINTS INSTEAD OF AIMING THEM MOVED `delta_only` BY 0.79** — from
  pointing backwards to leaning the right way. **The largest single improvement in this arc, and
  it came from measuring what the MODEL can do rather than deriving what the FORMULA should
  be.**

  ★★ **THE OTHER TWO GOT WORSE, WHICH IS INFORMATIVE.** Their corrections were partly
  COMPENSATING for the wrong elbow treatment. A fix that improves one candidate and degrades
  others is evidence the others were tuned against a bug — and a reason to distrust any
  parameter tuned before the mechanism was right.

  ★ Implementation: a body with exactly ONE hinge takes the human's FLEXION ANGLE as a scalar.
  Flexion is measured from the parent bone's CONTINUATION (departure from straight), not between
  the two segments — the supplement would read a straight limb as fully bent. **The SIGN comes
  from `jnt_range`**, so a knee bending negative and an elbow bending positive need no code
  change, only a different model.

  ★ Default is now `delta` — the measured best, not a derived favourite. **+0.151 is still far
  from +1.0**, so this is the current leader rather than a solution.

  ### Next, and now isolable

  ★ The forearm's direction depends on the SHOULDER being right. Measure the UPPER ARM's
  agreement separately: that isolates the shoulder's target from the elbow's bend, and the two
  can finally be debugged independently — which the single forearm number could never do.

- **13o. ★★★ SPLITTING THE TWO BONES FOUND IT: `aim` HAS THE SHOULDER AT 0.916.**

      mode              upper_arm    forearm
      delta_only          -0.407      +0.151
      delta_limb_fix      +0.133      -0.231
      aim                 +0.916      -0.196

  ★★★ **`aim` GETS THE UPPER ARM TO 0.916 — about 23 degrees, far ahead of anything else in
  this arc.** And a single forearm number had it looking WORST at -0.196. **Measuring the two
  bones separately is what made the truth visible**: `aim` has the shoulder nearly right and
  fails somewhere else entirely.

  ★★ **THE REMAINING FAILURE IS TWIST, AND THE MEASUREMENT SAYS SO.** `aim` uses the SHORTEST
  arc, which by construction adds no rotation about the bone — so the upper arm points correctly
  and its TWIST is arbitrary. **The elbow's hinge axis is fixed in the upper arm's frame**, so a
  wrong twist bends the forearm in the wrong PLANE. A good direction with a bad bend plane is
  exactly the pattern observed.

  ★ Default is now `AIM`, chosen on the UPPER-ARM number — the bone that formula actually
  decides. The forearm is a consequence of it plus the bend, and judging a formula by a
  downstream consequence is what hid this for several rounds.

  ### ★ THE LESSON WORTH KEEPING

  **A summary number over a chain measures the whole chain, not the link you changed.** The
  forearm sits below the shoulder AND the elbow, so its agreement blends a formula error with a
  bend error and can rank the candidates backwards — which it did. **Measure the bone the change
  controls.**

  ### Next

  ★ After aiming the upper arm, choose the TWIST about its axis so the elbow's bend plane
  matches the human's. Classic swing-twist arm IK — and reached by measurement rather than
  derivation, which is the first time in this arc that has been true of a next step.

- **13p. ★★★ SWING-TWIST — the forearm goes from -0.196 to +0.563, and the trade-off is the
  MODEL, not the algorithm.**

      mode              upper_arm    forearm     sum
      delta_only          -0.407      +0.151     -0.26
      delta_limb_fix      +0.133      -0.231     -0.10
      aim                 +0.916      -0.196     +0.72
      aim_twist           +0.598      +0.563     +1.16   <- best overall

  ★★★ **CHOOSING THE TWIST TOOK THE FOREARM FROM -0.196 TO +0.563.** The bend plane was the
  remaining error, exactly as the split measurement predicted — the first time in this arc a
  predicted fix landed as predicted.

  ★★★ **AND IT COST UPPER-ARM ACCURACY, WHICH IS THE MODEL SPEAKING.** A 2-DOF shoulder needs
  BOTH degrees of freedom for a direction and **has none spare for twist.** Asking for the bend
  plane forces it to give up some aim. **No algorithm avoids this** — `humanoid.xml`'s shoulder
  physically cannot both point exactly and twist to order. A real robot arm with three shoulder
  DOF would not face the trade.

  ★★ So the choice is the best TOTAL, not the best single bone. Optimising either bone alone
  makes the other worse, which is why the earlier single-forearm number ranked everything
  backwards and the earlier single-shoulder view would have too.

  ★ Implemented once in `robot.aimBoneWithTwist` and used by BOTH the example and the test, so
  the number measured is the number shipped. A straight limb returns the plain aim — there is no
  bend plane to match, and forcing one would make a straight arm jitter on capture noise.

  ★ The test's floor rose from -0.3 to +0.3: a guard against regression, not a claim of success.

- **13q. ★★★ STEP BACK: THE SCORECARD, AND WHAT IS ACTUALLY ESTABLISHED.**

  ### The measurement, in interpretable units

      1. upper arm POSITION    0.302 m      <- STAGE 1 IS ALREADY BADLY WRONG
      2. upper arm DIRECTION    54.3 deg
      3. elbow BEND             77.1 deg
      4. upper arm TWIST        67.7 deg

  ★★★ **POSITION FAILS FIRST.** The shoulder sits 30 cm from where it belongs on a 1.28 m robot,
  and **every orientation number in this arc was measured on a shoulder in the wrong place.**
  Simon's instruction to fix position before orientation is not a preference; the numbers say the
  rest is unreadable until it holds.

  ★ Staged deliberately: each quantity alone, in the order it depends on the one above, in
  METRES and DEGREES. "0.598" says nothing about whether an arm looks right; "54 degrees off"
  says it immediately.

  ★ Fixed while building it: the scale was computed from the LIVE root height, so it wobbled
  every frame as the character crouched — a moving ruler. From the rest pose it is 0.302 rather
  than 0.351.

  ### ★★ WHAT IS ESTABLISHED (not guessed)

  1. Torso POSITION is right — verified on device.
  2. Positions convert correctly Y-up -> Z-up; the torso landing proves it.
  3. `fitBodyRotation` preserves a requested direction on a 2-DOF body (1.000).
  4. A 1-DOF elbow cannot aim (-0.010); it must be BENT by a flexion angle.
  5. A 2-DOF shoulder cannot both aim and twist — measured trade, 0.916/-0.196 vs 0.598/+0.563.
  6. `humanoid.xml` rests LEGS in a T-pose and ARMS on a diagonal.
  7. Torso and leg rest directions already match the human's; only arms differ.
  8. GMR's `rot_offset` values are axis permutations grouped by LIMB, not per-bone tuning.
  9. A target is not a pose — non-root bodies move only through joints.
  10. Measuring the end of a chain ranks candidates backwards.

  ### ★★★ TEN THINGS TO TRY, IN THE ORDER THE SCORECARD DEMANDS

  **Stage 1 — get the upper arm's POSITION right (0.302 m -> target < 0.05 m):**

  1. **Measure the IRREDUCIBLE error first.** The robot's shoulder offset from its torso is
     FIXED by the model; no joint can move it. Compute the best possible position error for a
     perfectly placed torso — if it is already 0.25 m, the remaining budget is 0.05 and chasing
     it elsewhere is wasted.
  2. **Scale per LIMB, not globally.** One hip-height ratio cannot make both a leg and an arm
     match. GMR ships a `human_scale_table` per body for exactly this.
  3. **Re-check the torso match row.** `Spine2` may be the wrong human joint for `torso`; the
     robot's torso sits between the shoulders, LAFAN1's Spine2 lower. Try Spine3 or Neck.
  4. **Place the torso by the SHOULDER MIDPOINT** rather than by a spine joint — the quantity
     that matters for arm position is where the shoulders are, not where a spine bone is.
  5. **Let IK move the torso** with the two shoulders as position targets. The torso is the only
     body that CAN move them, and it currently gets no say.

  **Stage 2 — upper arm DIRECTION (54.3 deg -> target < 15 deg), only once stage 1 holds:**

  6. **Re-run the eleven formula candidates against the SCORECARD**, not the forearm cosine.
     Every previous ranking used a blended number and got them backwards at least once.
  7. **Try matching the shoulder-to-HAND vector** instead of per-bone directions — a two-bone
     limb has one meaningful reach direction, and the elbow is a consequence of it.

  **Stage 3 — elbow BEND (77.1 deg) and TWIST (67.7 deg):**

  8. **Check the bend SIGN.** 77 degrees of error on a scalar with a known range smells like an
     inverted sign, which `jnt_range` should have settled — verify it did.
  9. **Two-bone analytic IK** (shoulder + elbow from a hand target). Closed-form, no solver, and
     it produces bend and twist TOGETHER rather than as separate corrections that fight.
  10. **Compare against GMR's own output** for this clip and robot. It is the reference
      implementation; a numeric diff against it would end every remaining argument by
      measurement rather than derivation.

  ★★ **AND A DISCIPLINE FOR ALL TEN**: change one thing, re-run the scorecard, keep it only if
  the stage it targets improves AND no earlier stage regresses. This arc's losses came from
  changing several things against a blended number.

- **13r. ★★★ CANDIDATE 3 DONE — `Spine3` NOT `Spine2`, chosen by MEASUREMENT.**

  Shoulder-offset error against every plausible driver for `torso`:

      Spine 0.453   Spine1 0.375   Spine2 0.284   Spine3 0.226   Neck 0.253   Neck1 0.284

  ★★ **`Spine2` was chosen because it SOUNDS like a torso.** The robot's torso actually sits
  high, between the shoulders — and the difference is 6 cm of arm placement on a 1.28 m robot.
  Naming is not a measurement.

  ### Scorecard after the change

      1. upper arm POSITION    0.302 -> 0.253 m
      2. upper arm DIRECTION    54.3 -> 53.0 deg
      3. elbow BEND             77.1 -> 77.1 deg
      4. upper arm TWIST        67.7 -> 63.6 deg

  ★ Stage 1 improved and nothing below regressed, which is the discipline this arc needed and
  mostly lacked.

  ★★ **A MISMATCHED RULER, CAUGHT IN PASSING.** The scorecard still measured the arm relative to
  `Spine2` after the table moved to `Spine3` — the measurement disagreeing with the thing
  measured. Aligning them moved the reading from 0.307 to 0.253, meaning **the first
  "improvement" I saw was partly the ruler, not the change.** Any harness that names a joint
  must name the SAME joint the code does.

  ### ★★★ AND CANDIDATE 1 IS ANSWERED: THE FLOOR IS ~0.21 m

  **No human joint gets the shoulder offset below 0.21 m at a single hip-height scale.** The
  robot's torso-to-shoulder offset is FIXED by the model, so 0.21 is irreducible by mapping —
  **it is a SCALING problem.** At 0.253 we are within 4 cm of that floor, so further mapping
  work on stage 1 is nearly exhausted.

  ### ★★★ 13s. THE SCALE WAS 8.5% WRONG — a hardcoded constant next to real geometry

      ROBOT  height 1.445 m   hips 0.830   shoulder 1.315
      HUMAN  height 165.0 cm  hips  84.4   shoulder  136.7
      ratios height 0.0088    hips 0.0098  shoulder 0.0096

  ★★★ **THE PIPELINE HARDCODED THE ROBOT'S HIP HEIGHT AS 0.9 m. IT IS 0.830.** That put the
  scale at 0.01066 against a measured 0.00983 — **8.5% too large, on every target, on every
  frame, for this entire arc.** Every position error measured included it.

  ★★ Simon's question — "look at the heights, maybe scale the anim to match the robot" — is what
  surfaced it. **A guessed constant sitting next to geometry that could have been measured is a
  bug waiting for someone to look.** I wrote `0.9` as an estimate and never returned to it.

  ★ Scale now uses the SHOULDER height ratio rather than the hip: stage 1 is about where the ARM
  starts, and the three ratios differ by enough (0.0088 to 0.0098) that the choice is worth 5 cm.

  ### Scorecard through both fixes

      stage                     start    Spine3    scale
      1. upper arm POSITION     0.302    0.253     0.242 m
      2. upper arm DIRECTION     54.3     53.0      53.0 deg
      3. elbow BEND              77.1     77.1      77.1 deg
      4. upper arm TWIST         67.7     63.6      63.6 deg

  ★ Stage 1 has come down 20% and nothing below has regressed. The ~0.21 m floor still stands,
  so roughly 3 cm of mapping headroom remains before per-limb scaling is the only lever left.

  ### ★★★ 13t. THE SCORECARD, MADE HONEST — AND THE TORSO'S ORIENTATION IS THE REAL STAGE 1

      1. torso ORIENTATION      50.6 deg   <- STAGE 1, and it is bad
      2. upper arm POSITION    0.242 m     (a CONSEQUENCE of the torso)
      3. upper arm DIRECTION    53.0 deg
      4. elbow BEND             77.1 deg
      5. upper arm TWIST        63.6 deg

  ★★★ **THE ARM'S 53 DEGREES IS BARELY WORSE THAN THE TORSO'S 50.6.** The arm error is almost
  entirely **the torso's error inherited** — which means every hour spent on arm formulas was
  spent below a frame that was already half a right angle out.

  ★★ **AND SIMON VERIFIED THE TORSO'S POSITION ON DEVICE, NEVER ITS ORIENTATION.** "Torso looks
  good" settled stage 1's position and left its orientation unmeasured for the whole arc.

  ★ **THE LIKELY FIX IS ALREADY KNOWN**: `raw+yaw` at -90 was confirmed good FOR THE TORSO on
  device. The current build aims the torso like a limb, which discards that. **Different bodies
  want different formulas** — torso by facing yaw, limbs by aim+twist — which is exactly the
  per-limb-group structure GMR's table has and which I keep rediscovering.

  ### ★★ TWO FAKE NUMBERS REMOVED FROM THIS SCORECARD IN ONE SESSION

  1. A `Spine2`/`Spine3` mismatch: the ruler named a different joint than the code.
  2. A torso position of 0.913 m: the robot measured WORLD-ABSOLUTE against the human's
     ROOT-RELATIVE, and the harness never sets the root translation the pipeline does.

  ★★ **DELETED RATHER THAN CAVEATED.** A number with a footnote gets quoted without the
  footnote. **A comparison between two different frames of reference is not a measurement**, and
  a harness that omits what the pipeline does cannot report on it.

  ★ Next for stage 1 is candidate 2: **per-limb scaling.** One hip-height ratio cannot make a
  leg and an arm both match, which is precisely why GMR ships a per-body `human_scale_table`
  rather than a single number. — hip aims, knee bends, same split. The arm was
  the hard case because a 2-DOF shoulder is over-subscribed; a 3-DOF hip should not trade.

- **13k-2-old. (superseded) DEVICE: `delta+yaw` vs `delta + limb fix` vs `AIM`, IK off, 16 bones.** Legs and torso need none — the
  measurement says so — so the fix is one offset applied to the arm chain, which is the shape
  GMR's table had all along. They finally reach all
  sixteen bodies, so the comparison means something this time. Then IK back on as a REFINEMENT** — its actual
  job, per Simon's framing, now that orientation is carrying the motion. If `raw+yaw` holds at
  bones 2, 4, 8, 16 the retarget is essentially done and IK returns to being a refinement —
  which is what Simon said it should be from the start.

- **13e-4-old. (superseded) DEVICE: `bones: 1`, IK off, cycle the seven. Which one puts the torso's
  ORIENTATION on the character's?** Then add bone 2 and confirm the same choice still holds —
  a formula that is right for one bone and wrong for the next is a frame error, not a mapping
  error.

- **13d-4-old. (superseded) DEVICE CHECK. Watch `ik error`: it should fall well below 0.593 now that the
  system is no longer asking for more than the robot has.** The question is no longer "are the rotations right" but
  "does the solver reach its targets" — the `ik error` readout answers it directly.

- **13c-2-old. (superseded) DEVICE CHECK the two-stage solve.** Watch the residual and the feet with the
  IK off versus on; that comparison is the whole point of the toggle.

- **13c-old. (superseded) WIRE IK INTO THE ROBOT PIPELINE** — rotation fit for the initial guess, then a
  few `ikStep`s pulling weighted ankle/hand position targets, GMR's own shape. Then: tune the match table against what the residual and the
  render show, and decide whether the remaining loss is the model or the mapping.** GMR's own Phase 2: map joints by name, copy LOCAL rotations
  with an offset, scale the root by the height ratio, leave unmapped joints at rest. Their note:
  *"simpler than GMR's IK approach and sufficient when both skeletons are human with similar
  topology."*
  ★ Build this EVEN THOUGH the IK path is the goal — it needs nothing from `robot.zig`, runs on
  today's BVH pipeline, and gives an independent reference the IK solver must broadly agree with
  on human-to-human cases. A disagreement then points at the solver, not at the data.

- **13g. TWO-BONE ANALYTIC IK.** Closed-form shoulder-elbow-wrist and hip-knee-ankle. GMR's own
  fallback for proportion mismatch, useful with or without the iterative solver, and cheap.

---

## 4b. ★★★ MEASURED SKELETONS — what actually has to be bridged

Not assumed. Read from the files:

    A1 dance1_20s.bvh   ROOT Hips, then Spine/Spine1/Spine2/Spine3, Neck/Neck1/Head/HeadEnd,
                        Left|Right Shoulder/Arm/ForeArm/Hand + fingers, UpLeg/Leg/Foot/ToeBase
                        75 JOINT/ROOT records
    A2 Drop_Kick.fbx    67 Models, ALL PREFIXED `mixamorig:`
                        Spine/Spine1/Spine2 (THREE, not four), ONE Neck (no Neck1),
                        HeadTop_End rather than HeadEnd
    T3 humanoid.xml     16 bodies: torso head waist_lower pelvis
                        thigh_* shin_* foot_* upper_arm_* lower_arm_* hand_*
                        37 joint records, `<freejoint name="root"/>` on TORSO

### ★★ FOUR CONCRETE MISMATCHES, EACH WITH A CONSEQUENCE

**1. THE PREFIX.** `Hips` vs `mixamorig:Hips`. Trivial, but it must be STRIPPED AT LOAD or every
name lookup fails silently and the table maps nothing. ★ An unmapped table must be a load
ERROR, never an identity pose.

**2. SPINE CHAIN LENGTHS DIFFER.** LAFAN1 has Spine, Spine1, Spine2, Spine3 (four); Mixamo has
Spine, Spine1, Spine2 (three). LAFAN1 has Neck and Neck1; Mixamo has one Neck. ★ **A name map
alone cannot fix this** — copying `Spine3`'s local rotation onto nothing loses that segment's
bend, and the torso comes out straighter than the capture. The fix is to COMPOSE the dropped
joint's rotation into its surviving parent, which the direct BVH path must do explicitly.

**3. ★★★ THE ROBOT'S TREE IS INVERTED RELATIVE TO THE HUMAN'S.** BVH roots at `Hips` and the
spine goes UP. `humanoid.xml` roots at `torso` — `<freejoint name="root"/>` is on the TORSO —
and `pelvis` hangs BELOW it through `waist_lower`. So the free joint that carries global motion
is at the chest, not the hips. ★ The table's root row must target `torso`, and the pelvis must be
reached BY THE SOLVER rather than driven directly. This is exactly what IK is for, but a plan
that assumed "root = Hips = pelvis" would produce a robot translating from the wrong point.

**4. ★★★ THE KNEE IS ONE HINGE.** `<joint name="knee_right" class="knee"/>` — a single axis,
`range="-160 2"`. A BVH knee rotation with ANY twist or varus/valgus component CANNOT be
matched; the solver will fit the bend and discard the rest. Same for hips, which are three
SEPARATE hinges (`hip_x/hip_z/hip_y`) rather than a ball joint. ★ **The rotation task on a robot
is a best fit, not a match**, and the per-task error at convergence is the honest measure of how
much was lost. Report it; do not hide it behind a screenshot.

**5. JOINT LIMITS ARE REAL AND WILL BITE THE BACKFLIP.** `abdomen_y range="-75 30"`,
`knee range="-160 2"`. `jnt_range: []?[2]f32` exists (robot.zig:1548) and the IK MUST clamp to
it, or it produces poses the robot cannot hold and the dynamics arc inherits nonsense. GMR
passes `ik_limits` to `solve_ik` for this reason.

---

## 4c. ★ PREDICTED FAILURES, most to least likely

★ Written before building, so they can be checked off rather than rediscovered.

**1. The backflip on humanoid.xml will violate spine limits.** A backflip needs far more torso
extension than `abdomen_y`'s -75..30 allows, and the neck/head have none of the range a tucked
flip uses. **Expected outcome: a recognisable but under-curled flip.** That is a MODEL
limitation, not a solver bug — and confusing the two would send the investigation at the IK.
★ Measure it: report per-task error and how many DOFs sit AT a limit.

**2. Foot skate on both robot clips.** GMR gives ankles pos weight 50 against rot weight 10 for
exactly this. If our first table weights them evenly the feet will slide. ★ Fix is data, not
code — which is why the table is a file.

**3. The dropped spine joint will make Mixamo look stiff.** See mismatch 2. Predicted symptom:
the character reads correct but the upper back does not bend as much as the capture.

**4. `nq != nv` will silently drift the free-joint quaternion.** A naive `qpos += dq*dt` looks
right, renders plausibly for a few frames, then the root rotation degrades. ★ The free joint is
CONFIRMED present in humanoid.xml, so this WILL be exercised. Integration must be per-joint-type
from the first line of code, not retrofitted.

**5. The backflip's root goes inverted and may flip the solver's quaternion.** Rotation error
computed as a naive quaternion difference takes the long way round when the target passes
through 180 degrees. ★ Use the shortest-arc convention (negate when `dot < 0`) — cheap, and
invisible until an animation actually inverts. The backflip is precisely that animation.

**6. Mixamo's mesh is bound to ITS skeleton, so A1xT2 must retarget the SKELETON, then skin.**
The existing `skinMeshCpu` path already does the second half; the risk is assuming a retargeted
pose can be fed to a mesh bound to a different rig.

---

## 5. ★ Adversarial review — what this plan gets wrong if nobody checks

**1. ★★ RETARGETING IGNORES BALANCE, AND A HUMANOID IS AN INVERTED PENDULUM.** GMR emits a
KINEMATIC pose stream; nothing in it guarantees the robot could hold that pose. `examples/humanoid`
already documents how hard merely standing is — 1.28 m, 27 DOF, held up by ankle torque.
**Play retargeted motion kinematically first**: set `qpos`, run `kinematics`, draw. Physical
tracking is a SEPARATE arc with its own controller. Conflating them means debugging a solver and
a balance controller simultaneously, which is exactly the failure §11 paid five device rounds for.

**2. TWO SOLVERS, ONE WORD.** `robot.zig` already has a constraint solver with
`constraint_jacobian` (line 2619) for CONTACTS. The IK solver is unrelated and operates on a
different Jacobian. Keep `constraint_jacobian` and `jacBody` visibly distinct, and do not let
"solve" mean both.

**3. `nq != nv`.** A free joint carries a quaternion (line 421), so `qpos` is longer than the DOF
count and cannot be integrated by naive addition. Integration must be per-joint-type:
quaternions compose, hinges add. ★ This is the single most likely source of a silent wrong
result, because a naive `qpos += dq * dt` LOOKS right and drifts the quaternion off unit length.

**4. THE TABLE IS DATA AND BELONGS IN A FILE.** The interesting knowledge — which joints get
position weight and which only orientation — must be tunable without a rebuild. One table per
(source, robot) pair.

**5b. ★ THE SIX CLIPS NEED A DEFINITION OF "HIGH QUALITY" THAT IS NOT AN OPINION.** Proposed,
per clip: (a) no joint sits at a limit for more than a few percent of frames, (b) foot contact
does not slide while planted — measure the planted foot's world speed, (c) per-task position
error stays under a few centimetres on the ankles, (d) the root trajectory tracks the source's
scaled path. ★ All four are numbers a test can print, and three of them would catch foot skate
before anyone looks at a render.

**5. "ANY ANIMATION ON ANY ROBOT" HAS A LIMIT, AND IT SHOULD BE NAMED.** Retargeting maps joints
by a table; a robot with no analogue for a joint simply has no row for it. A quadruped cannot
wear a walk cycle. ★ The honest claim is: **any source whose skeleton can be mapped onto the
target's, with the table saying how.** Where a mapping does not exist the pipeline should say so
at LOAD time — an unmapped required body is a config error, not a silent identity pose.

**6. WHAT MAKES US CONFIDENT IT WORKS, CONCRETELY.** Four checks, none of which need a human eye:
   - `jacBody` matches finite differences (13a)
   - single-task IK converges on a redundant chain (13b)
   - human-onto-itself reproduces the input pose (13d)
   - the direct BVH path and the IK path agree on a human-to-human case (13f)
  ★ Only after all four does a screenshot mean anything.

---

## 6. Staying a monolith

Everything lands in files that already exist, in zimr's existing shape:

    src/robot.zig      jacBody, ikSolve, retargetFrame — next to the physics they use
    src/codecs.zig     the match-table JSON parse, next to bvh/fbx
    src/draw3d.zig     nothing new: bvhForwardKinematics already produces the input
    examples/mocap_robot   the demo

★ No new module, no plugin layer, no registry. A retarget is a function over slices, which is
what the rest of zimr looks like — and it is why `poseSkinMatrices` and `skinMeshCpu` ended up
as free functions rather than a `Skinner`.

---

## ★★★ 14. THE RECIPE ALREADY EXISTS: `FlomoGMR/scripts/flomo_to_geno_bvh.py`

Simon asked whether GMR already contains work that does exactly this. **It does**, in
`compute_twist_offsets()`, and its docstring describes the problem this arc spent many rounds
rediscovering — in the same words:

> *"Geno's LeftArm->LeftForeArm offset points along +Z (up), while the source T-pose has it
> pointing laterally. Copying an identity rotation from the source T-pose leaves Geno's arm
> pointing up — a ~90 degree error."*

### ★★★ THE FORMULA, AND THE PIECE I DID NOT HAVE

    q_corrected = inv(R_twist_parent) * q_src * R_twist_self

where `R_twist_J` maps the ROBOT's rest bone direction onto the SOURCE T-POSE's bone direction,
**both expressed in the joint's LOCAL frame**.

★★★ **THE `inv(R_twist_parent)` FACTOR IS WHAT I WAS MISSING.** Their docstring says why:

> *"undoes the parent's twist so it doesn't accumulate and distort children. Without it, each
> joint in a chain would get the parent's twist baked in on top of its own."*

**My correction was `C * delta * conj(C)` — a similarity transform in WORLD space.** The correct
form is a LOCAL correction that CHAINS: each joint undoes its parent's twist before applying its
own. That is precisely why my per-limb correction made the forearm worse while helping the
shoulder, and why errors compounded down every chain.

★ And the verification they give is the property I never managed to state cleanly:

    world_rot_J_geno = world_rot_J_src * R_twist_J
    =>  world_rot_J_geno * d_geno = world_rot_J_src * d_target

**The bone direction matches exactly, by construction.**

### ★★ OTHER THINGS THEIR IMPLEMENTATION KNOWS

* **Processed per CHAIN, parent-to-child** — `['RightShoulder','RightArm','RightForeArm',
  'RightHand']` — so `R_twist_parent` is available when the child is computed. My loop went over
  bodies in index order and never tracked a per-chain parent twist.
* **Local frame, not world.** `d_target` is the source's T-pose bone direction transformed into
  the joint's local frame using **the joint's SOURCE world orientation**, because `R_twist`
  bridges from the source frame to the robot's. I computed both in world.
* **Leaves get identity** — no child bone to align, so no twist to compute.
* **Hands use a PROXY**: the source has no finger joints, so `MiddleFinger1` is the robot's
  reference direction and `forearm->hand` the source's, because in a T-pose the palm extends
  along the forearm. That is the `LeftFootMod` trick again — a synthetic direction where the
  natural one is missing.

### What to do with it

★ **Port `compute_twist_offsets` faithfully rather than deriving again.** This arc's record on
deriving this particular thing is: eleven candidate formulas, four device rounds, and a
correction applied on the wrong side of the delta. **The reference implementation is right
there, its reasoning is written down, and it is verifiable against the scorecard already built.**

★ The scorecard is the check: `torso ORIENTATION 50.6 deg`, `upper arm DIRECTION 53.0 deg`,
`elbow BEND 77.1`, `twist 63.6`. A faithful port should collapse all four.

★ Note their target is GENO (a 75-joint humanoid), not `humanoid.xml`. The chain structure and
the hand proxy will need adapting, but **the math is the math** — and it is the part that has
resisted derivation.
