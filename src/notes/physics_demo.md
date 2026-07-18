# physics_demo.md — represent every Jolt sample in the zimrphysics demo

## Goal
Two phases, in order:
1. **Parity floor** — one interactive standalone (`wgpu_zimrphysics_demo`) whose
   switchable scenes **cover every JoltPhysics sample** the engine is capable of,
   each modelled on its Jolt counterpart and proven correct (headless harness
   first, on-device screenshot second).
2. **Go beyond** — once parity is reached, build the *mix-everything showcase
   scenes* (see the Showcase section) that combine many subsystems into one
   spectacle. These are the scenes that show off how good the engine is; they are
   the real point, and Jolt parity is the means.

"Represented" (phase 1) means: for every sample in
`JoltPhysics-master/Samples/Tests/*`, there is either (a) a scene that
demonstrates the same capability, or (b) an explicit entry below saying why it
is deferred (engine feature absent) or skipped (non-visual: serialization /
threading / tooling). Reference tree: `/home/claude/jolt_ref/JoltPhysics-master/
Samples/Tests/` — 147 `*Test.cpp` across 13 categories (verified 2026-06-22).

## Engine capability snapshot (verified against `src/zimrphysics.zig`, 2026-06-21)
Much wider than this plan's first draft assumed. What exists *today*:

- **Shapes (14):** `sphere box capsule cylinder tapered_capsule convex_hull
  compound triangle mesh heightfield rotated_translated offset_com empty plane`.
  Missing vs Jolt: `tapered_cylinder`, a `scaled` decorator, mutable compound.
- **Constraints (11 + motors):** `addPointConstraint addFixedConstraint
  addDistanceConstraint addHingeConstraint addSliderConstraint
  addSwingTwistConstraint addGearConstraint addRackAndPinionConstraint
  addPulleyConstraint addSixDofConstraint addPathConstraint`. `MotorSettings`/
  `AngularMotorSettings` give velocity + position(spring: frequency/damping)
  drives → powered hinge/slider/swing-twist. `SwingType = .cone | .pyramid`.
- **Subsystems:** `Ragdoll` (+ `driveToPoseUsingKinematics`), `CharacterVirtual`,
  `Character`, `Vehicle` (`VehicleEngine`/`Transmission`/`Differential`/
  `AntiRollBar`/`Track` → car / motorcycle / tank).
- **Per-body features (`BodyDesc`):** `motion_type {static,kinematic,dynamic}`,
  `motion_quality {discrete,linear_cast(CCD)}`, density / `override_mass` /
  `inertia_multiplier`, friction, restitution, linear/angular damping,
  `gravity_factor`, `max_linear/angular_velocity`, `apply_gyroscopic`,
  `allowed_dofs` (lock world axes → 2D), `is_sensor`, `category`/`collides_with`
  (filtering), `group_id`, per-shape/per-triangle `material`. `ContactSettings`
  carries a conveyor-belt surface velocity and a per-pair sensor flag.
- **Queries:** `castRay` (0..1 `fraction` + world `distance`), `castShape`,
  `queryAabb`.
- **Renderer (`render.zig drawWorld`):** draws `sphere box capsule cylinder
  tapered_capsule compound rotated_translated`. **Gaps:** `convex_hull mesh
  heightfield plane triangle offset_com` are not yet drawn.

## What is shipped (28 scenes, all green; engine hardened) — updated 2026-06-23 (zimr230)
`shapes terrain showcase pyramid stack rods restitution friction_ramp funnel
bridge chain motor weld slider pulley ragdoll gear rack_and_pinion path
newtons_cradle wrecking_ball plinko rube_goldberg tumbler conveyor clockwork stirrer ragdoll_pile`.
Constraint coverage is effectively complete: every Jolt constraint the engine
implements now has a scene AND a permanent regression in
`tools/physics_audit.zig` (now **35/35**): point(bridge), distance(chain),
hinge+powered(motor), fixed(weld), swing-twist+cone(ragdoll), gear(gear train),
rack&pinion, pulley, path. Engine fixes proven by the audit and
`src/tests/zimrphysics_stack_test.zig`: box-box manifold (always face-clip from
the supporting face, edge only as shallow fallback); `castRay` fraction; box-box
SAT min-overlap normal; off-COM distance constraint (`r1+u` moment arm +
per-position-iteration re-derive); the gear missing-`ratio` impulse fix; the
compound/decorator child-rotation composition-order fix (`qmul(parent, child)`,
parent-outer). Standing harness must stay green through every wave below.

## Showcase scenes — mix-everything demos (Wave J, the headline) 🌟
Parity with Jolt is the **floor, not the ceiling**. Once a capability is proven in
isolation, the payoff is combining many of them into one self-running spectacle —
the scenes people actually screenshot and share. Each showcase below is designed to
be (a) instantly readable in a single still, (b) headless-provable (runs to a known
end state with no NaN / no tunnelling), and (c) guarded by its own audit regression.
Build them as a dedicated `showcase:`-prefixed scene group in the launcher.

1. **Rube Goldberg chain reaction** — ✅ SHIPPED (zimr221). The flagship. A CCD marble
   (`motion_quality=.linear_cast`) rolls down a ramp, bowls into a line of six dominoes
   that topple in sequence; the last domino shoves a heavy ball off a ledge; the ball
   drops onto an angled chute that funnels it into a catch bin. Gravity-driven end to
   end (no motors), so it replays identically on Reset. Features: CCD · ramp ·
   stacking+friction (dominoes) · restitution · chute + bin. Audit `rube-goldberg`
   proves the whole chain completes: 6/6 dominoes fall, the ball lands in the bin
   (x≈17.8, y≈-2.9), nothing goes non-finite. Camera uses a new per-scene `camTargetX`
   (=7) to frame the wide left-to-right layout. DESIGN NOTE: the original plan chained
   a hinged lever → pulley → see-saw catapult → paddle wheel; in practice those
   stages are fragile (a free ball rolling across a see-saw doesn't dwell long enough
   to tip it, and catapult launch-direction fights a left-to-right flow), so the
   shipped version is gravity-driven for rock-solid replayability — Jolt-parity
   robustness first. A genuinely-tipping see-saw / powered-paddle finale is a future
   enhancement once a reliable dwell-or-cup trigger is built. ENGINE GOTCHA found
   here: a static fulcrum post whose top touches the plank physically supports it and
   blocks rotation; give post+plank a shared `group_id` (or a gap) so they don't
   collide. (An earlier note here claimed offset-anchor hinges "lock up" — that was a
   MISDIAGNOSIS: the test's static post overlapped the hinged body and pinned it by
   collision. With the post clear, a door hinged at its edge swings as a free pendulum.
   Offset-anchor hinges are fine.)

2. **Wrecking-ball demolition** — ✅ SHIPPED (zimr214). A heavy sphere (density
   5000) hangs from a fixed pivot by a rigid distance-constraint chain, lifted ~70 deg.
   Released, gravity swings it down and it plows through a free-standing 2-deep brick
   wall (30 boxes), scattering it. Features: distance-constraint pendulum · box
   stacking + friction · big mass ratios. Audit `wrecking-ball` proves the wall stands
   (mean displacement 0.06 m before impact) then is demolished (1.64 m after) with the
   ball swinging through (max x 5.16) and no NaN. Chain drawn in drawSceneOverlay. Used
   pure gravity drive rather than a motor — simpler and rock-solid. Maximum satisfaction
   per pixel.

3. **Newton's cradle** — ✅ SHIPPED (zimr213). Five equal balls hang as planar
   pendulums (rigid distance-constraint strings, `allowed_dofs = plane_2d`),
   just touching, restitution 1. Lift the leftmost, the rightmost swings out, then
   it oscillates back and forth energetically (stays lively for 10 s+ at dt=1/60).
   Features: distance constraints · planar DOFs · near-elastic restitution ·
   momentum transfer. Audit `newtons-cradle` proves the clean 2-ball case: impact
   4.56 → far ball out 4.56, near ball stops dead (-0.00) — exact momentum/energy
   conservation. (The 5-ball row is mushier — simultaneous contacts — like Jolt's
   own cradle, but reads correctly.) The first Wave-J showcase to land.

4. **Marble run with conveyors + a windmill** — CONVEYOR ✅ SHIPPED as the `conveyor`
   scene (zimr224): a flat belt carries a stream of marbles from a left feed point into a
   walled catch bin. The inclined-belt variant was tried and dropped — a rolling ball
   won't hold stable contact on a tilted moving belt (gravity-along-slope beats the
   surface-velocity friction), so it slides off regardless of drive sign. The full
   path-rail + windmill marble-run remains a future combination.
   CONVEYOR MECHANIC VERIFIED 2026-06 (zimr223 probes): a static belt body + a contact
   listener that sets `relative_linear_surface_velocity` (belt is the lower body index →
   negate the desired direction) reliably carries a body along the belt. A rolling ball
   rides at center_speed ≈ 0.28 × target (rolling, not sliding) and stays planar (zero
   z-drift). CAUTION: a multi-belt SWITCHBACK cascade flings marbles off the belt ends —
   not a belt bug but crowding: queued marbles shove each other off at high speed, and a
   lone marble rides cleanly. The shipped single-belt-to-bin form sidesteps that: marbles
   only crowd if spawned too fast (well-spaced stream) and the walled bin (left wall just
   below the drop-off) means a jostled marble can't escape. Audit `conveyor`: 15/15 ride
   across into the bin, zero lost.

5. **Plinko / Galton board** — ✅ SHIPPED (zimr219). 40 balls released one at a time
   from the top centre (per-step spawner in `update`) cascade through a 6-row staggered
   field of FRICTIONLESS pegs (restitution 0.30) into binned slots, building a bell curve.
   Audit `plinko`: 40/40 reach the bins, zero jams, centre > edges. Balls are full 3D (no
   `plane_2d` needed — all geometry is at z=0 so they stay planar; maxAbsZ=0.0000 headless).
   ROOT-CAUSE LOG (why balls were invisible for several iterations): NOT physics — headless
   always showed 40/40 landing. The bug was the shared 3D immediate-mode batch in
   `src/draw3d.zig`: `batch_capacity` was 65536 verts and EXCESS PRIMITIVES ARE DROPPED (no
   mid-frame flush, unlike the 2D batch). At 12×16 tessellation a sphere is ~1152 verts, so
   ~51 peg spheres alone ate ~59K verts, leaving room for only ~5-6 balls before the batch
   truncated — every body drawn after that silently vanished. Fix: raised batch_capacity to
   262144, AND made the truncation impossible: `Cube3D.drawStream` now GROWS the GPU vertex
   buffer to fit the frame (in batch_capacity chunks, mirroring the instance buffer's
   grow-on-demand) instead of clamping, with an `assertf` backstop if a buffer past the GPU
   max is ever needed; the textured path asserts loudly on overflow too (zimr220). LESSON:
   when geometry past a certain body-count vanishes but headless physics is clean, suspect a
   fixed-size render batch that truncates rather than flushes/grows. (Also: a
   static body's colour is always `static_color` regardless of material — colouring static
   pegs as a freshness probe does nothing; change GEOMETRY, e.g. row count, instead.)

6. **Clockwork drive** — ✅ SHIPPED as the `clockwork` scene (zimr225). A five-gear train
   of ALTERNATING radii (so each gear spins at a visibly different rate and adjacent gears
   counter-rotate) driven by a velocity motor on the first gear; the last gear drives a
   VERTICAL rack — a piston tangent to its right edge — via rack-and-pinion. (First built
   with a long horizontal rack centred under the last gear; it visually skewered the
   neighbouring gear, so it became a short vertical piston on the right that crosses nothing.
   Gravity then pulls the rack along its own slide axis, so the rack-pinion coupling carries
   its weight — verified it holds, doesn't sag.) The drive REVERSES when the rack reaches the
   end of its travel (reciprocation verified, zimr222), so the machine oscillates forever —
   continuous, no projectiles. Gears are disk+spoke compounds so rotation reads clearly.
   Features: powered hinge motor · gear train (pure velocity coupling) · rack & pinion ·
   reciprocation. Audit `clockwork`: each gear holds w0*r0/r_i (alternating sign), rack
   reciprocates ~2 units about its home height, nothing non-finite.

7. **Ragdoll playground** — drop a pile of swing-twist ragdolls onto a see-saw or
   into the funnel, or seat one on a spinning platform. Features: ragdoll
   (swing-twist+cone) · stacking · hinge platform. Stress test that also looks alive.

10. **Ragdoll pile** — ✅ SHIPPED as `ragdoll_pile` (zimr230). Three Jolt-standard humanoid
   ragdolls (12 capsule bones each: 3 torso segments, head, two two-bone arms, two two-bone
   legs) joined by 11 swing-twist constraints with per-joint cone/twist limits taken straight
   from Jolt's RagdollLoader (tight spine ±5deg, hinge-like elbows/knees via normal-cone 0 +
   wide plane-cone, wide shoulders/hips). Dropped with a shove so they topple, collide, and
   flop into a heap — the classic Jolt "Ragdoll" sample. Each ragdoll is its own collision
   group (no self-collision; ragdoll-vs-ragdoll and ragdoll-vs-ground do collide). Launch
   fires a ball into the pile. Note: the existing `ragdoll` scene is really a swing-twist CONE
   showcase (4 hanging capsules); this is the actual articulated humanoid. Audit `ragdoll_pile`:
   one dropped ragdoll stays 12/12 finite, joints hold, settles flat (avg <1 m/s, maxY <1) by
   450 steps.

9. **Stirrer** — ✅ SHIPPED as the `stirrer` scene (zimr227). A near-full-width four-blade rotor spins
   about a VERTICAL axis inside a ROUND bowl (32 tangent wall segments), vigorously STEERING a
   deep load of 36 MIXED-shape objects (spheres, cubes, cylinders, capsules) around the wall.
   The first version had a small rotor in a square bowl and objects just sat in the corners; a
   bigger rotor in a square bowl wedged box/cylinder shapes into the flat walls and NaN'd. Two
   fixes: (a) ROUND wall so the blade tip pushes objects ALONG the wall (orbit) not into a
   corner; (b) FAT convex radius on cubes/cylinders so deep contacts resolve via GJK before the
   EPA degeneracy. Objects rain in from above so none spawn inside the blades. Driven by a swing-twist
   TWIST motor — the one constraint the showcase hadn't exercised under power (the ragdoll
   scene uses swing-twist passively for cone+twist limits, never drives it). A tight cone
   (normal/plane half-cone 0.05) keeps it to pure spin, no tilt. Reliable by clearance: the
   bowl is wider than the blade reach so balls churn rather than getting pinched against the
   wall and flung (an over-tight bowl DID fling them — keep blade-tip-to-wall gap > ball
   diameter). swing-twist CS target note: the twist component is the CS frame's X-axis, so
   the velocity target is vec(speed, 0, 0) regardless of the world twist axis. Audit
   `stirrer`: 36/36 stay in AND keep moving (avg ~2.9 m/s), rotor holds 1.5 rad/s, finite over
   7200 steps (120 s).

8. **Tumbler** — ✅ SHIPPED (zimr223). A hexagonal drum (six tangential wall boxes as
   one compound body) spins on a velocity-motored hinge (1.3 rad/s) while 15 balls
   tumble inside. Reliable BY CONSTRUCTION — the drum contains the load, so nothing can
   fly off (the failure mode that sank the conveyor cascade). Features: powered hinge
   motor · compound shape as a moving container · many-body contact. Audit `tumbler`:
   15/15 stay inside, drum holds 1.3 rad/s, balls tumble, zero z-drift. Tap launches a
   ball into the drum.

Sequencing: build **#1, #2, #4** first — they each exercise a different cluster of
features and read instantly. Every showcase that needs a capability we haven't
wired into a scene yet (CCD bodies, conveyor surface velocity, a see-saw rig)
doubles as the proving ground that promotes that feature from "engine has it" to
"demonstrated + regression-guarded". Showcases are where the missing General-wave
features (Sensor, ConveyorBelt, HighSpeed/CCD, GyroscopicForce) naturally land.

## Coverage matrix
Legend: ✅ shipped · ▶ feasible now (engine ready; needs a scene, maybe a
renderer draw) · 🔧 needs a named small engine/renderer add first · ⛔ deferred
(engine feature absent — see "Deferred") · — non-visual (skip: serialization /
threading / pure-tooling).

### Shapes (18) — Wave B (after renderer Wave A)
| sample | status | note |
|---|---|---|
| SphereShape, BoxShape, CapsuleShape, CylinderShape | ✅ | in showcase |
| TaperedCapsuleShape | ▶ | shape + renderer exist |
| RotatedTranslatedShape, StaticCompoundShape | ▶ | renderer exists |
| OffsetCenterOfMassShape | 🔧 render offset_com | draw child at shifted COM |
| ConvexHullShape | 🔧 render convex_hull | draw hull faces |
| MeshShape, MeshShapeUserData | 🔧 render mesh | static triangle soup + per-tri material |
| HeightFieldShape | 🔧 render heightfield | terrain grid |
| PlaneShape | 🔧 render plane | infinite ground quad |
| TriangleShape | 🔧 render triangle | single tri leaf |
| EmptyShape | ▶ | constraint-only anchor (no draw) |
| TaperedCylinderShape | 🔧 engine: add `tapered_cylinder` | mirror tapered_capsule |
| MutableCompoundShape | 🔧 engine: runtime add/remove on compound | |
| DeformedHeightFieldShape | 🔧 engine: heightfield mutation | static HF first |

### Constraints (20) — Wave C ✅ COMPLETE (edge cases only; slider leak & hinge offset-anchor both re-verified non-issues)
| sample | status | note |
|---|---|---|
| PointConstraint | ✅ | bridge (audit `point-bridge`) |
| DistanceConstraint | ✅ | chain (audit `distance-constraint`) |
| HingeConstraint, PoweredHingeConstraint | ✅ | motor (audit `hinge-motor`) |
| FixedConstraint | ✅ | weld (audit `fixed-weld`) |
| SliderConstraint, PoweredSliderConstraint | ✅ | slider scene shipped; perpendicular-lock leak RE-VERIFIED could-not-reproduce (held 0.0000 under symmetric stress + reversing motor) |
| SwingTwistConstraint, PoweredSwingTwistConstraint, SwingTwistConstraintFriction | ✅ | ragdoll (swing-twist+cone); powered-motor probe still pending |
| ConeConstraint | ✅ | swing-twist `.cone` (ragdoll) |
| GearConstraint | ✅ | gear train (audit `gear-chain`); drift-correction path still open |
| RackAndPinionConstraint | ✅ | rack & pinion (audit `rack-pinion`); constant drive only — reciprocation gap logged |
| PulleyConstraint | ✅ | pulley (audit `pulley`) |
| PathConstraint | ✅ | path / bead on rail (audit `path`) |
| SixDOFConstraint | 🔧 needs a scene | engine ready + probe-verified; no dedicated scene/audit yet |
| Spring | ▶ | soft distance/six-DOF (frequency/damping); fits the Newton's-cradle / soft-mount showcase |
| ConstraintPriority, ConstraintSingularity, ConstraintVsCOMChange | ▶ | small edge-case scenes (solve ordering / aligned axes / offset_com) |

### General (39) — Wave D
| sample | status |
|---|---|
| Pyramid, Stack, Friction, Restitution, Funnel | ✅ |
| Simple, Wall, HeavyOnLight, BigVsSmall | ▶ |
| Damping, GravityFactor, ModifyMass, Kinematic | ▶ |
| ChangeMotionType, ChangeMotionQuality, ChangeShape, ChangeObjectLayer | ▶ |
| GyroscopicForce (`apply_gyroscopic`) | ▶ |
| AllowedDOFs, TwoDFunnel (`allowed_dofs`) | ▶ |
| HighSpeed (`motion_quality=.linear_cast` CCD) | ▶ |
| CenterOfMass (`offset_com`) | ▶ |
| Sensor (`is_sensor`), ConveyorBelt (contact surface vel) | ▶ |
| ShapeFilter (`category`/`collides_with`), ActiveEdges, EnhancedInternalEdgeRemoval | ▶ |
| ContactListener, ContactManifold, ManifoldReduction | ▶ |
| FrictionPerTriangle (per-tri material), Island, ActivateDuringUpdate | ▶ |
| DynamicMesh | 🔧 engine: rebuild mesh BVH per frame |
| Multithreaded, LoadSaveBinary, LoadSaveScene, SimCollideBodyVsBody, SimShapeFilter | — |

### Rig (10) — Wave E (ragdoll)
| sample | status |
|---|---|
| CreateRig, RigPile, PoweredRig | ▶ (`Ragdoll`) |
| KinematicRig | ▶ (`driveToPoseUsingKinematics`) |
| BigWorld | ▶ (large coordinates) |
| LoadRig | ▶ (hard-code one rig spec) |
| LoadSaveRig, LoadSaveBinaryRig | — |
| SkeletonMapper | — (animation retargeting, not physics) |
| SoftKeyframedRig | ⛔ (soft body) |

### Character (5) — Wave F
| sample | status |
|---|---|
| Character, CharacterVirtual, CharacterBase | ▶ |
| CharacterSpaceShip (moving platform) | ▶ |
| CharacterPlanet (radial gravity) | 🔧 engine: per-body gravity direction (have `gravity_factor`, need a vector) |

### Vehicle (6) — Wave G
| sample | status |
|---|---|
| Vehicle, VehicleConstraint | ▶ (`Vehicle`) |
| Motorcycle (2 wheels + lean), Tank (`VehicleTrack`), VehicleStress | ▶ |
| VehicleSixDOF | ▶ (alt construction via six-DOF) |

### ConvexCollision (7) + BroadPhase (3) — Wave H (query visualizers)
| sample | status |
|---|---|
| EPA, ClosestPoint, ConvexHull, ConvexHullShrink, CapsuleVsBox, RandomRay, InteractivePairs | ▶ (`castShape`/`castRay`/closest-point overlays) |
| BroadPhaseCastRay, BroadPhaseInsertion, BroadPhase | ▶ (`castRay`/`queryAabb` stress) |

### ScaledShapes (15) — Wave I (one engine add unlocks all)
🔧 **engine: add a `scaled` decorator** (`{ child, scale: Vec }`, like
`rotated_translated`). Then ScaledBox/Sphere/Capsule/Cylinder/ConvexHull/Mesh/
HeightField/Plane/Triangle/TaperedCapsule/TaperedCylinder/OffsetCOM/
StaticCompound/MutableCompound + DynamicScaledShape all become one gallery scene.

### Deferred — need engine features explicitly out of this plan's scope
| category | count | reason |
|---|---|---|
| SoftBody (SoftBody*Constraint, Pressure, Skinned, …) | 18 | ⛔ no soft-body solver |
| Hair (HairCollision, HairGravityPreload, Hair) | 3 | ⛔ no strand/DER solver |
| Water (Boat, WaterShape) | 2 | ⛔ no buoyancy/fluid |
| Tools (LoadSnapshot) | 1 | — serialization |

## Build-out waves (each ends GREEN: harness + `lint-check`, screenshot, zip)
Order chosen so prerequisites land first and each wave is independently shippable.

- **Wave A — renderer coverage.** Add `drawWorld` cases for `convex_hull mesh
  heightfield plane triangle offset_com`. No physics change; unblocks all of
  Wave B. (Pure rendering — Simon's screenshot is the check.)
- **Wave B — Shapes gallery.** One or two scenes placing every shape type on a
  floor; a per-triangle-material mesh covers MeshShapeUserData. Harness: each
  shape rests stably on the mesh/heightfield floor.
- **Wave C — Constraints complete. ✅ DONE (zimr211).** Scenes + audit regressions
  shipped for slider, swing-twist+cone (ragdoll), gear, rack-and-pinion, pulley, and
  path, on top of the earlier point/distance/hinge/fixed. Remaining tails: a dedicated
  six-DOF scene, a spring scene, the priority/singularity/COM-change edge cases, and
  the logged solver gaps (gear drift-correction, rack
  reciprocation, swing-twist powered-motor probe). NOTE: a previously-logged "hinge
  offset-anchor lockup" was a false alarm (a colliding static post in the test, not a
  solver bug); verified a door hinged at its edge swings freely as a pendulum.
- **Wave D — General mechanics.** Group the General samples into themed scenes
  (sensors+conveyor, filtering, kinematic/motion-type/quality, damping/gravity/
  mass, gyroscopic, 2D/allowed-DOFs, high-speed CCD, heavy-on-light/wall/big-vs-
  small, contact-listener/manifold/active-edges, island/activate). Harness the
  ones with a measurable outcome (CCD no-tunnel, sensor fires, belt transports).
- **Wave E — Rig/ragdoll.** create / pile / powered / kinematic-driven / big-world.
- **Wave F — Character.** virtual + base over steps/ramps; spaceship platform;
  (planet after the per-body gravity-vector add).
- **Wave G — Vehicle.** car, motorcycle, tank, six-DOF, stress.
- **Wave H — Collision/broadphase visualizers.** castShape/closest-point/EPA and
  broadphase ray/insert overlays (these are query demos, not dynamics).
- **Wave I — Scaled shapes.** add the `scaled` decorator + renderer support, then
  the scaled gallery.
- **Wave J — Showcase (the headline).** The mix-everything scenes above
  (Rube Goldberg, wrecking ball, Newton's cradle, marble run, Plinko, clockwork,
  ragdoll playground). Can be built incrementally and interleaved with the other
  waves — each showcase pulls in whatever General-wave feature it needs (CCD,
  conveyor, sensor) and proves it in context. This is where "as good as Jolt"
  turns into "more fun than the Jolt samples".
- **Engine adds along the way** (each test-first, isolated): `tapered_cylinder`
  shape, mutable compound add/remove, per-body gravity *vector*, optional
  heightfield/mesh mutation for the Deformed/Dynamic samples.
- **Land.** Update `src/web/readme.html` (new scope + any new public API),
  regenerate the cheatsheet if the curated surface changed, refresh
  `src/notes/files.md`, archive this plan to `src/notes/archive/`.

## Standing rules
- Pure Zig, `wasm32-wasi` + WebGPU; standalones built
  `-Dmode=release-with-zimr-asserts`. No GPU/browser in the sandbox — Simon's
  screenshot is the visual verdict every visual wave.
- Use `ui.zig` and `zimrmath` maximally; no new math types outside `zimrmath`.
- Every solver/engine change is proven with a headless `zp.step` harness
  (`tools/physics_audit.zig` or a `/tmp` probe) **before** any visual relies on
  it; add a permanent regression to `tools/physics_audit.zig` /
  `src/tests/zimrphysics_stack_test.zig`.
- Each turn: show all new/changed code, end GREEN (`zig build lint-check` = 0,
  `zig build test`, audit 21/21+), zip the project.
- The scene list is getting long: keep `Scene` grouped by category with the
  `joint:`/caption metadata so the launcher stays legible (consider category
  sub-menus if it grows past ~30).

## Scope guard
This plan surfaces and hardens **existing** engine capability across scenes, and
makes the small additive shapes/decorators noted above (tapered_cylinder, scaled
decorator, mutable compound, per-body gravity vector) — each a localized,
test-first change. It does **not** add major new simulation subsystems: soft
bodies, hair/DER, cloth, buoyancy/water, or continuous-fluid are out of scope
(they would each be their own plan). Record new-feature ideas here; don't build
them under this plan.

## Parity gaps found while building gear (2026-06)

- **Constraint-connected bodies are not collision-filtered.** Jolt defaults each constraint to
  collide_connected=false, so a body and the static anchor it is jointed to do not collide.
  zimr has no such filter: an anchor/hub overlapping its jointed body produces real contacts.
  This bit the gear scene (a static hub sphere sits inside each spinning gear). Workaround in
  scenes: put the anchor in the same group_id as its body. Proper fix: a per-constraint
  collide_connected flag (default false) + a connected-pair filter in the broadphase/narrowphase.
- **Sphere-vs-cylinder deep-penetration manifold is unstable.** With a sphere buried in a fast-
  spinning cylinder (the hub-in-gear case), the contact walks the COM off the joint and diverges;
  the same overlap with a box is stable. Worth a manifold audit (box tolerates it, cylinder does not).

## Wave C — constraint-engine bugs found (deferred, need dedicated fixes)

- **Gear (`addGearConstraint`)** — FIXED 2026-06 (zimr205). The velocity part omitted the
  `ratio` factor when applying the impulse to body B (Jolt: `ratio*lambda*I2^-1*a2`), so its
  applied impulse was inconsistent with its own jv/effective-mass: with refs=-1 the spin did
  not transfer, and with refs set the drift path over-worked and blew up. Restored the factor
  (velocity + position). Pure velocity coupling (refs=-1) now transfers correctly and is stable
  at dt=1/60 (audit `gear-chain`: a 2:1 pair holds wB=-wA/2). Shipped a `gear train` scene
  (3 meshing disks, motor on the first). RE-VERIFIED 2026-06: the optional drift-correction path (refs set) is STABLE — a 1:1 pair
  with both hinge refs wired holds wB=-wA exactly with zero blow-up at 8 AND 40 rad/s over
  900 steps. The previously-feared `hingeCurrentAngle` frame mismatch does not destabilise it
  in practice. (Repro: /tmp/gear.zig.)

- **Rack-and-pinion (`addRackAndPinionConstraint`)** — SHIPPED 2026-06 (zimr209). The part is
  correct as-is: unlike the gear, it bakes `ratio` into `ratio_inv_m2_b = ratio*invM2*sliderAxis`
  in prepare, so the body-B impulse is consistent with its jv/effective-mass (velocity solve
  nullifies jv exactly; verified). Pure velocity coupling (refs=-1) tracks v_rack = w/ratio
  precisely and is rock-solid at dt=1/60 in BOTH directions (audit `rack-pinion`). Shipped a
  `rack & pinion` scene: a motored pinion (disk+spoke) drives a long toothed rack on a slider;
  pinion+rack share a no-collide group (the constraint meshes them; teeth are visual only —
  same contamination lesson as the gear hub). CONSTANT drive only; the rack slides off and
  Reset replays. RE-VERIFIED 2026-06: reciprocation WORKS. Flipping the pinion velocity-motor target every
  120 steps (5 reversals, passing through exact rest each time) reciprocates the rack cleanly
  0<->1.303 m with the pinion ang-vel tracking +/-1.3 — NO deadlock, NO NaN over 700 steps.
  The earlier deadlock/NaN appears fixed by the intervening motor/coupling work. (The undamped
  position-motor-spring decay (b) was not re-checked.) Repro: /tmp/rp.zig.

- **Pulley (`addPulleyConstraint`)** — SHIPPED + audit-guarded (`pulley`). A rigid rope
  (min == max == creation length) over two fixed points: a heavy box (density 1500) and a
  light box (density 300) hang from the ends. Headless-proven: heavy descends 5.00 -> 0.48
  (rests on floor), light rises 3.50 -> 8.02, total rope length |a-fa| + |b-fb| conserved
  (8.20, drift 0 at steady state). The rope is not a body; `drawSceneOverlay` draws it.
  No parity gap found — behaves like Jolt's PulleyConstraintTest.

- **Path (`addPathConstraint`)** — SHIPPED + audit-guarded (`path`). A bead is constrained to a
  valley-shaped Hermite spline (3 control points, in a static anchor's space, rotation_type
  `.free`). The construction's `qmul(path_to_body_a, body_a.rot)` round-trips to
  `world_path_rotation` under the proven first-arg-outer convention. Headless-proven frictionless:
  the bead stays exactly on the path plane (maxZ = 0.0000), slides to the bottom (minY = 3.00),
  and swings back up to 4.75 vs a 5.00 start — energy conserved, no spurious work. Scene `path
  (bead on rail)` draws the spline via `pathWorldPoint` sampled over [0,1] in drawSceneOverlay.

Two remaining constraints have real solver bugs; scenes were NOT shipped to avoid
demos that violate their own rules. Both want the Jolt-comparison treatment the
distance constraint already got.

- **Slider (`addSliderConstraint`)** — the perpendicular (DualAxisConstraintPart)
  lock was logged as leaking (~0.18 m cube / ~0.5 m thin platform, holding n1 but
  leaking n2). RE-VERIFIED 2026-06: could NOT reproduce. A +Y slider (coincident
  anchor) under symmetric perpendicular gravity stress (g = (3, -9.81, 3)) holds BOTH
  perpendicular axes at 0.0000 — with tight limits AND with an active reversing
  velocity motor driving the platform up/down through Y. No leak, no asymmetry. Likely
  fixed by the intervening constraint-code work (swing-twist re-port / shared parts).
  Re-test against a /tmp/slider-style harness if a leak is ever seen again. (Lower-limit
  softness was noted too; not re-checked.)
- **Swing-twist (`addSwingTwistConstraint`)** — FIXED 2026-06 (zimr203). Root cause:
  the swing-twist part + its two consumers (dedicated swing-twist + SixDOF) built the
  constraint frame reversed-from-Jolt but self-consistently; the CONE's one-sided
  velocity limit [-inf,0] then got the wrong-sign jv (locked paths survived because
  they are bidirectional). Re-ported the whole frame to Jolt-literal (constraint_to_body
  = conj(R)*c2w; cb = R*c2b; q = conj(cb1)*cb2; part = c2w*q_swing; solvePosition +
  motor forms). Probe battery: cone holds ~0.36 (was 1.53), twist ~0.44, near-locked
  0.0000, SixDOF rotation ~0.36 + translation pinned. Shipped with a `ragdoll` demo
  scene. Motors flipped to Jolt forms; RE-VERIFIED 2026-06 with a dedicated probe: the twist velocity motor drives the bone to exactly the target (3.000 rad/s) and the twist limit correctly arrests it at the bound. Motors work. (Repro: /tmp/st.zig.)


### Open engine items (collision robustness)
- **Polytope deep-penetration EPA degeneracy (NaN).** The big-rotor stirrer (zimr229)
  pinned this down: 36 SPHERES churned hard (avg ~2.7 m/s) are 36/36 stable over 3000 steps,
  but box/cylinder/capsule shapes go non-finite when wedged into deep penetration (a flat wall
  + a fast blade is the worst case). Same family as the sphere-vs-cylinder note. Worked around
  in the stirrer with a ROUND wall (tangential push, no corner wedge) + FAT convex radius (GJK
  resolves the contact before EPA). The underlying EPA path still needs the real fix: reproduce
  with two boxes forced flush into deep penetration and trace where the expanding polytope /
  contact normal goes non-finite (the pyramid EPA "unbounded face growth" note is the lead).
- **tapered_capsule and convex_hull NaN under heavy crowding.** Found building the 36-object
  stirrer (zimr228): a bowl full of churning tapered_capsules OR convex_hulls goes non-finite
  within ~300 steps, while sphere/box/cylinder/capsule are rock-solid at the same count. Each
  shape is fine in isolation and in light scenes (the showcase scene shows one of each) — the
  failure needs many of them in sustained deep contact. Isolated per-shape (sphere/box/
  cylinder/capsule all 36/36; tapered_capsule and convex_hull each 0/36 + NaN). The stirrer
  excludes these two shapes for now. Likely the same family as the sphere-vs-cylinder
  deep-penetration manifold note. Next: reproduce minimally (two tapered_capsules forced into
  deep penetration) and trace where the manifold/normal goes non-finite.
