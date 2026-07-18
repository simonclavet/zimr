# Making `zimrphysics` (3D / Jolt) and `zimrphysics2d` (2D / Box2D) feel like one family

A plan only — no code is changed yet. The goal is that a developer who learns one engine can
predict the other: shared vocabulary, mirrored creation/query/event flows, parallel naming.

## What "compatible" can and can't mean

The two engines port *different* libraries (Jolt vs Box2D v3) in *different* dimensions, so a
byte-for-byte identical API is neither possible nor desirable. What IS achievable, and what this
plan targets, is **predictable parallelism**: same verbs, same argument order, same result
shapes, same enum names, same event flow — differing only where the physics genuinely differs
(and then differing *loudly* and documented).

Already shared today (the hard part is done):

- Both are single-file, single-threaded, flat-phase pipelines built on `entities.zig` + `zm`.
- Both keep tunables in a `Settings` value on a `World`; both do ECS-at-rest + slice-by-index
  during a step.
- Both carry per-kernel parity tags against their source library.

So ~80% is already parallel. The rest is the table below.

## The divergences

| Concern | 3D (`zimrphysics`) | 2D (`zimrphysics2d`) |
|---|---|---|
| Body-type enum | `MotionType {static,kinematic,dynamic}` | `BodyType {static,kinematic,dynamic}` |
| Create a body | `world.addBody(gpa, BodyDesc) → BodyIndex` (method, per-call gpa) | `createBody(world, BodyDef) → BodyHandle` (free fn, uses `world.allocator`) |
| Body identity | `BodyIndex` (raw u32) | `BodyHandle` (`ent.Handle`, generation-checked) |
| Body descriptor | `BodyDesc` | `BodyDef` |
| Shapes | shared immutable `ShapeStore`; `buildConvexHull`/`buildMesh`/… → `ShapeId`, referenced in the desc | per-body `createShape(world, body, ShapeDef) → ShapeHandle` (a body may own several) |
| Friction/restitution | on the **body** (`BodyDesc.friction`/`.restitution`) — Jolt model | on the **shape** (`ShapeDef.material`) — Box2D v3 model |
| Damping / scale fields | `linear_damping`, `angular_damping`, `gravity_factor`, `max_linear_velocity`, `max_angular_velocity` (on desc) | `linear_damping`, `angular_damping`, `gravity_scale` (on def); max speeds in `Settings` |
| Rotation type | `rotation: Quat` | `rotation: Rot2` |
| Articulation family | "**Constraint**": `addPointConstraint`, `addHingeConstraint`, `addSliderConstraint`, `addFixedConstraint`, `addDistanceConstraint`, `addSwingTwistConstraint`, gear/rack/pulley/path/six-dof | "**Joint**": `createRevoluteJoint`, `createPrismaticJoint`, `createWeldJoint`, `createDistanceJoint`, `createWheelJoint`, `createMotorJoint`, `createFilterJoint` |
| `step` | `step(world, scratch, dt)` | `step(world, dt, sub_step_count)` |
| Ray cast | `castRay(world, origin, direction, max_distance, filter) → ?RayHit` | `castRayClosest(world, origin, translation, filter) → RayResult{hit, …}` |
| Shape cast / overlap | `castShape`, `collideShape`, `collidePoint`, `overlapAabb` | `castShapeClosest`, `overlapShape`, `overlapAabb`, `castMover`/`collideMover` |
| Contact events | `ContactListener` callbacks (`on_contact_added/persisted/removed/validate`), may edit `ContactSettings` mid-step — Jolt model | event **buffers** read after `step`: `getContactEvents`, `getSensorEvents`, `getBodyEvents`, `getJointEvents` — Box2D v3 model |
| Velocity accessors | `getLinearVelocity`, `setLinearVelocity`, `setLinearAndAngularVelocity` | `getLinearVelocity`, `setLinearVelocity`, `getAngularVelocity`, … |

## Recommended unified conventions

For each, "→" is the proposed target. "Who moves" assumes the validated 2D engine's vocabulary
is the default anchor when there's no strong reason otherwise (it ships and is regression-tested),
except where Jolt's idiom is clearly better.

### Cheap, mechanical, high-value (rename-only; do these first)

1. **Body-type enum** → `BodyType` on both. (3D: `MotionType` → `BodyType`.) Same members already.
   - Effort: low. Risk: low. The Jolt term "motion type" can survive as a doc alias.
2. **Create verb + descriptor** → `createBody(world, BodyDef) → …` on both.
   - 3D: `addBody` → `createBody`; `BodyDesc` → `BodyDef`; drop the per-call `gpa` and use
     `world.allocator` (the `World` already takes a `gpa` at `init`). Keep a separate *scratch*
     allocator only for `step` if Jolt-style transient buffers need it (see §step).
3. **Query names** → align to the 2D scheme on both:
   - `castRay` → `castRayClosest`; `castShape` → `castShapeClosest`; `collideShape` →
     `overlapShape`; `collidePoint` → `overlapPoint`; keep `overlapAabb`. Result is "closest"
     by default; add `…All` variants later if needed.
4. **Scalar speed caps** → name magnitudes `…_speed`, vectors `…_velocity`, on both.
   - 3D: `max_linear_velocity`/`max_angular_velocity` → `max_linear_speed`/`max_angular_speed`,
     and move the global defaults into `Settings` (2D already does), keeping an optional
     per-body override field with the same name.
   - 3D: `gravity_factor` → `gravity_scale` (2D term).
5. **Settings field names** → make the overlapping tunables identical: `gravity`,
   `sub_step_count` (if 3D adopts it), sleep thresholds, `linear_slop`, `speculative_distance`,
   `restitution_threshold`. Audit both `Settings` structs and reconcile names + units.

### Interaction-pattern alignment (slightly deeper)

6. **Body identity** → `BodyHandle = ent.Handle(Body)` on both. Both already build on
   `ent.Entities`, so `ent.Handle` is available in 3D today. Public API returns/accepts
   `BodyHandle`; the hot loops keep using the raw `BodyIndex` internally (unchanged). This is a
   real safety win (generation-checked, catches use-after-free) and the single biggest
   "feels like the same engine" change. Same move for `ShapeHandle` and the articulation handle.
7. **Articulation family** → unify the **verb + suffix**, and the **names of the shared joints**:
   - `add*Constraint` → `create*Joint` on both, returning a handle.
   - Shared-concept renames in 3D: `Hinge` → `Revolute`, `Slider` → `Prismatic`,
     `Fixed` → `Weld`, `Point` → (keep, or document as a limit-free revolute), `Distance`
     stays. So `addHingeConstraint` → `createRevoluteJoint`, etc.
   - Dimension-unique ones keep their names (3D: swing-twist, six-dof, gear, rack-and-pinion,
     pulley, path; 2D: wheel, motor, filter). List them as "engine-specific" in the contract.
   - This is the most opinionated rename; see Decision A.
8. **Ray/cast result shape** → one convention on both. Recommend `?RayResult` (optional struct)
   everywhere: it's the idiomatic-Zig "miss = null", and drops the redundant `hit: bool`. 2D's
   `castRayClosest` would return `?RayResult`; 3D's `RayHit` becomes `RayResult`. (Alternative:
   keep the `{hit: bool}` struct on both — pick one, apply to ray/shape-cast/mover uniformly.)
9. **`step` signature** → consistent argument order and shape: `step(world, dt) !void` on both,
   with sub-steps and any scratch configured on the `World`/`Settings` rather than passed
   positionally. (2D: drop `sub_step_count` from the call, read `world.settings.sub_step_count`.
   3D: stop passing `scratch` positionally — store a scratch arena on the `World`, or accept it
   as a trailing optional. Net: identical call sites.) See Decision C.

### The hard ones (need your call before touching)

10. **Contact events: buffers vs listeners.** These follow the source libraries and serve
    different needs. Buffers (2D) are data-oriented and match the stated "everything in view,
    flat phases" design; listeners (3D) allow *mid-step mutation* of contact response
    (one-way platforms, conveyor surface speed, per-contact friction overrides) that a
    post-step buffer can't express. Note 2D already has `enable_pre_solve` on `ShapeDef`, i.e.
    the *concept* of a mid-step hook exists on both. **Recommendation:** converge on a single
    shape with two halves, present in both engines:
    - *Buffers* for the common begin/end-touch + sensor + body-move + joint events
      (`getContactEvents`, …) — 3D gains these.
    - *One optional callback* for mid-step contact modification (validate + pre-solve), with the
      same struct name and field names on both — 2D formalizes its pre-solve into this. See
      Decision B.

## Decisions I need from you

- **Decision A — articulation vocabulary.** Adopt Box2D's "joint" + revolute/prismatic/weld on
  both (my recommendation, for cross-engine predictability and because 2D is the shipped one)?
  Or keep Jolt's "constraint" + hinge/slider/fixed in 3D and only unify the verb (`create…`)?
- **Decision B — event model.** Add buffer-style event getters to 3D and a shared
  validate/pre-solve callback to both (recommended), or keep each engine's native model and only
  align the *names* of the event payload structs?
- **Decision C — `step` shape.** Move sub-steps/scratch onto `World`/`Settings` so both call
  `step(world, dt)` (recommended), or keep the positional differences?
- **Decision D — material location.** Leave friction/restitution where each source lib puts it
  (3D: body, 2D: shape) and just document it + expose parallel `getFriction`/`setFriction`
  accessors? Or actually move one (invasive)? Recommend: document + parallel accessors, don't move.
- **Decision E — convergence direction.** Default to anchoring on the validated 2D vocabulary
  except where Jolt's is clearly better (e.g. `?RayResult`)? Or a clean-sheet shared vocabulary
  that both move toward?

## A mechanism to keep them aligned: `physics_common.zig`

The durable way to make "compatible" stick (rather than re-diverging) is a small shared module
both engines import for the genuinely dimension-independent surface:

- Shared enums: `BodyType`, `MotionQuality`, motor states, `BackFaceMode`, query-filter shape.
- Shared result *shapes* (generic over the vector type): `RayResult`, `CastResult`, `OverlapHit`.
- The naming-rules doc (verbs, `_speed` vs `_velocity`, `create*` family, handle-not-index).
- A tiny `comptime` conformance check that fails to compile if one engine drops a name the
  contract requires.

This is the "best for the future" piece: the two files stay parallel because a single source of
truth defines the parallel parts.

## What to deliberately NOT unify

- **Math types.** `Vec2`/`Rot2`/`Transform2`/`Mat22` vs `Vec`/`Quat`/`Mat3` are inherent to the
  dimension. Keep them; just keep the *naming style* consistent (e.g. if 2D is `Vec2`, the 3D
  vector reading as plain `Vec` is fine, or rename to `Vec3` for symmetry — minor, your call).
- **The shape model.** 3D's shared immutable `ShapeStore` (+ `ShapeId` in the desc) is core Jolt
  and good for instanced meshes; 2D's per-body `createShape` is core Box2D. Forcing one onto the
  other is a deep rewrite for little gain. Align the *creation verbs and naming* and document the
  structural difference rather than unifying the model.
- **Joint types with no analogue** (swing-twist/six-dof/gear/pulley/path in 3D; wheel in 2D).

## Suggested sequencing

- **Phase 0** — agree the vocabulary (this doc + Decisions A–E).
- **Phase 1** — mechanical renames (§1–5): enums, `createBody`/`BodyDef`, query names, speed/scale
  field names, `Settings` reconciliation. Each engine behind its own test/regression net. Note the
  3D engine isn't compile-checked yet, so Phase 1 on 3D pairs naturally with a first build pass.
- **Phase 2** — identity → handles (§6), result shape (§8), `step` shape (§9).
- **Phase 3** — articulation family (§7) and the event model (§10), per Decisions A/B.
- **Phase 4** — extract `physics_common.zig` + write the cross-engine API-contract doc and the
  comptime conformance check.

Phase 1 alone gets ~70% of the "feels like one family" benefit for low risk and is a good place
to start once a direction is chosen.
