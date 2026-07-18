# Porting the box2d sample corpus → wgpu_zimrphysics2d_demo

The box2d testbed registers **137 samples** across 14 categories. They are not all
"scenes": some are collision-query *visualizers* (draw a ray + its hits, no world
step), some are perf benchmarks, some are bug repros. This plan triages every one
and ports them in waves into `examples/wgpu_zimrphysics2d_demo/scenes.zig`.

## Architecture
- `scenes.zig` owns `Scene{ category, name, build(*World)!void, update: ?*const fn(*World)void }`
  plus a `pub const list` registry and a set of Options-struct spawn helpers
  (`addBody`, `attachBox/Circle/Capsule`, `groundBox/Segment`, `pinRevolute/Weld/
  Distance`). Adding a scene = one helper-built `build` fn + one `list` entry.
- The main demo renders any scene via the existing DebugDraw→DrawList adapter and
  drives an optional per-frame `update` hook (wind, spawners, kinematic motion).
- UI: a scrollable, category-grouped picker (collapsingHeader per category).

## Engine support (confirmed present)
Shapes: box/rounded/offset/polygon(hull)/circle/capsule/segment/chain. Joints:
revolute, prismatic, wheel, distance, weld, motor, filter, pulley (pulley added
zimr388 for the Dominos showcase — box2d v2's b2PulleyJoint, dropped in v3).
Forces: force/torque/
impulse (+toCenter/angular). World: explode, ray/shape cast, contact+sensor+body+
joint events, setBodyType/enable/disable, set lin/ang velocity. Gap: no runtime
joint-motor *setter* surfaced (motors are set at creation) → input-driven motor
samples (Driving) are approximated with constant motors for now.

## Triage + waves

### WAVE 1 — pure world-building scenes (THIS PASS, ~30)
Stacking: Single Box, Vertical Stack, Tilted Stack, Circle Stack, Capsule Stack,
  Confined, Double Domino, Pyramid(existing). 
Bodies: Body Type, Sleep, Weeble.
Continuous: Drop, Skinny Box, Bounce House, Wedge.
Shapes: Friction, Restitution, Rounded, Ellipse, Compound Shapes, Offset,
  Rolling Resistance, Conveyor Belt(tangent_speed), Wind(update-hook), Explosion.
Joints: Revolute, Bridge, Ball & Chain, Cantilever, Soft Body(distance), Wheel.
World: Tiles.
Benchmark: Tumbler.

### WAVE 2 — joints + chains needing frame/axis math or chain shapes
Joints: Prismatic, Distance Joint, Motor Joint, Door, Ragdoll, Scale Ragdoll,
  Doohickey, Scissor Lift, Gear Lift, Driving(car), Top Down Friction, Separation,
  Breakable(joint force events), Filter Joint, Motion Locks, User Constraint.
Shapes: Chain Shape, Chain Link, Chain Segment, Custom Filter, Filter, Modify
  Geometry, Recreate Static, Tangent Speed, Box Restitution, Wind variants.
Continuous: Chain Drop, Chain Slide, Pinball, Ghost Bumps, Segment Slide, Wedge
  variants, Restitution Threshold, Speculative*.
Stacking: Arch, Card House, Cliff.
Bodies: Pivot, Set Velocity, Kinematic, Wake Touching, Mixed Locks, Bad.
World: Far Pyramid, Far Gate, Far Ragdolls.
Robustness: HighMassRatio1-3, Overlap Recovery, Tiny Pyramid, Cart, Multiple
  Prismatic.
Benchmark (as stress scenes): Spinner, Rain, Many Tumblers, Large Pyramid,
  Compounds, Joint Grid, Smash, Barrel, Washer, Sleep, Kinematic.

### WAVE 3 — events-driven (need per-frame event reading + reaction)
Events: Contact, Persistent Contact, Circle Impulse, Projectile Event, Body Move,
  Foot Sensor, Platformer, Sensor Bookend/Funnel/Hits/Types, Joint event.

### WAVE 4 — collision LAB (separate mode: query visualizers, custom drawing,
###          not a stepped world)
Collision: Ray Cast, Shape Cast, Cast World, Overlap World, Manifold, Smooth
  Manifold, Dynamic Tree, Time of Impact, Shape Distance. Character: Mover.
Geometry: Convex Hull. Benchmark: Cast, Shape Distance, CreateDestroy (Capacity & Washer
  DONE; CreateDestroy/Large Compounds over-capacity, deferred).

### CAPACITY: entity pools are now GROWABLE (zimr396)
Entities(T).grow + World.growBodies/Shapes/Contacts/Joints; create paths grow-and-retry. No fixed
cap, no per-scene caps. Benchmarks run at box2d-native numbers (Washer 90x90=8100 done). Large
Compounds (~50k shapes, BVH broad-phase) and CreateDestroy (5050) now portable; CreateDestroy has a
u8 handle-generation churn caveat. Future: segmented chunk arena for component-bearing pools.

### Issues bug-repros — DONE (zimr394) except Disable
Issues: Bad Steiner, Crash01, StaticVsBulletBug, Unstable Prismatic Joints,
  Unstable Windmill — PORTED (5). Disable = interactive enable/disable checkbox
  with no autonomous behaviour, DEFERRED. Determinism: Falling Hinges, SnapShot
  remain (serialize/harness, low value). (Port more only if a regression needs a
  visual repro.)

## Status — GOAL RAISED: 100% coverage (Simon, 2026-06-27)
Earlier waves stopped at 59 live scenes (skip-tier + benchmarks + collision-lab + a few
engine-blocked omitted). Simon now wants ALL 137 box2d samples present. Re-diffed against
the real box2d-main source (samples/sample_*.cpp, 137 RegisterSample calls).

LIVE: 59 scenes. MISSING: 83 entries, of which 4 are already present under our "Lab"
category (Collision Ray Cast / Shape Cast / Overlap World, Geometry Convex Hull) — naming
only. So ~79 真 to add.

PORTABILITY (engine capability re-audited 2026-06-27 — far better than the old note):
present = setFilter/Friction/Restitution, setBodyType, enable/disableBody, destroyBody/
Shape, createChain, applyForce, explode, setLin/AngVelocity, ALL events (contact/sensor/
body/joint), all 6 joint types (revolute/prismatic/wheel/distance/weld/motor).
  • PORTABLE NOW (~70): all Shapes(8), Stacking/Robustness(7), World Far*(3), Bodies(3),
    most Continuous(10), all Events(9), most Joints (Breakable/Filter/Separation/TopDown/
    ScaleRagdoll/Scissor/Gear via creation-time motors), all Benchmark stress (spawn-N),
    Determinism Falling Hinges, all Issues(6) bug-repros.
  • NEEDS ENGINE WORK (9, Simon's call): Character|Mover (character/mover solver),
    Joints|User Constraint (custom constraint callback), Determinism|SnapShot (world
    serialization), Collision|{Cast World, Dynamic Tree, Manifold, Smooth Manifold, Time
    of Impact, Shape Distance} (expose collision internals + a query/custom-draw lab mode).
  • GAP that affects fidelity only: no runtime motor-SPEED/TARGET setter (motors set at
    creation) → interactive Driving/Door approximated with constant motors.

WAVE ORDER to 100% (each batch screenshot-verified by Simon):
  B1 Shapes(8): [DONE] Box Restitution, Filter (added a `filter:` field to attachBox/Box).
     [pending] Custom Filter (needs custom pair-filter callback = engine work), Tangent Speed
     (curved chain-conveyor w/ per-segment materials = chain batch), Modify Geometry (runtime
     geom swap + per-scene state), Recreate Static (per-frame ground destroy/recreate + state),
     Chain Link, Chain Segment (chain shapes). NOTE: our Scene.update hook is stateless
     (fn(*World)void) — Modify Geometry / Recreate Static need a per-scene state slot first.
  B2 [PARTIAL] Robustness: DONE HighMassRatio1/2/3, Overlap Recovery, Tiny Pyramid.
     pending Cart + Multiple Prismatic (joints -> B4). World Far*(3) DEFERRED (origin at 1e6/1e7
     = far-from-origin f32 test; verify engine handles large coords before porting). Stacking
     extras Arch/Card House/Cliff still to do.
     INFRA ADDED this batch: per-scene camera. Scene now has `cam: ?CamHint{target,ppm}`; loadScene
     applies it (null = demo default {0,4.5}/34). REQUIRED — box2d samples each set camera center+zoom;
     without it large/tiny-scale scenes fall off-screen. ppm ~= 300/box2d_zoom for the 900x600 window.
  B3 [Bodies DONE] Bad (zero-density capsule vs normal), Mixed Locks (added lock_x/y/rot to the
     Body helper -> allowed_dofs), Wake Touching (10 boxes settle+sleep). Continuous: DONE Speculative Fallback/Sliver/Ghost, Pixel Imperfect, Restitution Threshold.
     DONE Chain Slide, Segment Slide, Bounce Humans (state slot + makeRagdoll: timed spawn + rotating
     gravity). remaining Continuous (2, deferred), Ghost Bumps (interactive shape-type toggle +
     rebuild), Pinball (flippers = revolute motors + plunger).
  B4 [PARTIAL] Joints: DONE Filter Joint (createFilterJoint), Top Down Friction (100 mixed shapes,
     each tied to ground by a motor joint w/ max_velocity_force/torque=10 = friction; added restitution
     to the Cap helper). pending: DONE Motion Locks + Separation (multi-joint galleries),
     DONE Scissor Lift (crossed-capsule scissor, stiff joints, sprung strut; VISUAL CHECK NEEDED), DONE Scale Ragdoll (row of scaled ragdolls via makeRagdoll). BLOCKED: Gear
     Lift (no gear joint in 2D engine), DONE Breakable (state slot + getConstraintForce + new pub destroyJoint), User
     Constraint (custom constraint callback = engine work).
  B5 Events(9) via the event API.
  B6 Benchmark stress(15) + Issues(6) + Determinism Falling Hinges.
  B7 Lab mode expansion + the 9 engine-work items (needs engine decisions first).

================================================================================
FEATURE-COMPLETENESS AUDIT  (zimr377 — 82 ported / 60 remaining of 137+ samples)
================================================================================
Two buckets remain. Bucket A is portable NOW (infra exists). Bucket B needs 2D
ENGINE work (solver/architecture) — these are the real "feature complete" gaps.

-- BUCKET A: portable with current infra (~28), no engine changes --------------
  Benchmark (15)  : bulk spawn-N stress scenes (Many Pyramids, Tumbler, Joint Grid,
                    Smash, Many Tumblers, etc). Pure spawning loops — portable.
  Issues (6)      : targeted bug-repro scenes — portable.
  Events (6)      : contact/sensor/body-move events via our event API; the
                    interactive ones are now unblocked by the per-scene STATE slot.
  Determinism (1) : Falling Hinges — portable (revolute chain).
  Joints galleries: Motion Locks, Separation (multi-joint, stateless but large),
                    Scissor Lift (prismatic+motor mechanism).
  Continuous      : Bounce Humans (needs makeRagdoll helper + STATE timer — slot ready).
  Geometry (1)    : Convex Hull — already present as a Lab scene (naming only).

-- BUCKET B: needs 2D-engine features (the true feature-completeness gaps) ------
  These need zimrphysics2d solver/architecture work and visual verification
  (wgpu-check gates the 3D engine + smoke, NOT 2D-engine correctness), so each is
  flagged for a deliberate engine pass rather than a blind port:
  1. GEAR JOINT        -> Joints|Gear Lift. New joint type (couples two joints).
  2. USER CONSTRAINT   -> Joints|User Constraint. Per-step custom constraint hook.
  3. CHARACTER/MOVER   -> Character|Mover. Kinematic character solver + capsule cast.
  4. WORLD SERIALIZE   -> Determinism|SnapShot. World snapshot/restore.
  5. COLLISION QUERIES -> Collision (6: Cast World, Dynamic Tree, Manifold, Smooth
                          Manifold, Time of Impact, Shape Distance). Expose ray/shape
                          cast + manifold/distance queries + a "lab" draw mode.
  6. RUNTIME GEOM SET  -> Shapes|Modify Geometry (+ interactive UI), Custom Filter
                          (pair-filter callback). setCircle/setPolygon/setCapsule/
                          setSegment in place; custom contact-filter callback.
  7. FAR ORIGIN        -> World (3: Far*). Verify f32 behaviour at 1e6–1e7 coords
                          before porting (may be an engine tolerance limitation).

  STATE SLOT (DONE, zimr377): Scene.build_s/update_s + SceneState{body[4],joint[4],
  u[4],f[4]} carried in the demo State, reset per scene, update_s runs each fixed
  step before phys.step. Proven by Shapes|Recreate Static (ground destroyed+rebuilt
  every step). Unblocks Breakable, Bounce Humans, interactive Events, etc.

  NEXT HELPER: makeRagdoll(world,pos,scale) factored from jointRagdoll -> unblocks
  Scale Ragdoll, Bounce Humans, Far Ragdolls.

  SHOWCASE (DONE, zimr388): category "Showcase" + scene "Dominos" — the CS296 Rube
  Goldberg machine (Erin Catto / IIT-Bombay). Faithful v2->v3 port of ~40 bodies
  (cannon+recoil, right staircase of revolving flaps + balls, 7-domino run, weight
  balance, LEFT PULLEY, centre see-saw platform, bottom see-saw, water basin).
  Drove the PULLEY JOINT engine feature (JointType.pulley, createPulleyJoint, inline
  host test). New helper attachRotBox = SetAsBox(hw,hh,center,angle)+friction. This
  is an ADDITION beyond the box2d-137 corpus; portable-remaining of the 137 unchanged.
  The pulley was the last missing joint TYPE (all 8 box2d joint kinds now present).

  zimr389: +3 scenes (109 total, 31 of 137 left). Benchmark|Compounds (two-triangle
  compound grid, reduced 14x14), Benchmark|Barrel (mixed-shape grid, deterministic
  hash01 sizing), Events|Projectile Event (autonomous: auto-fired bullet -> contact
  event -> explode + destroyBody, via build_s/update_s state slot). New helpers
  benchBin (3-box U-bin) + hash01. DEFERRED: Washer (no inner floor + capacity),
  Large Compounds (capacity); remaining Events (Sensor Hits/Types/Joint/Persistent
  Contact) are visualization-driven and update_s has no draw context, so they need a
  different approach (the explosion in Projectile Event was the one physical reaction).
