# Persistent contacts — feasibility

## ★★★ THE DESIGN ALREADY ANTICIPATES THIS

Two things in `zimrphysics.zig` say so outright:

    8450:  feature_id: u32, // stable id for warm-start matching across frames

    12449: local_a: Vec, // contact point on A, in A's local frame (position-solve anchor)
    12450: local_b: Vec, // contact point on B, in B's local frame

**The matching key exists and is populated by every manifold builder** (sphere-box, face
manifolds, the fallback path — all set `feature_id`). **The anchor exists** and is already
described as a position-solve anchor, expressed in each body's local frame, which is exactly the
frame it must be in to survive the bodies moving.

★ WHAT IS MISSING IS ONE LINE'S WORTH OF LIFETIME:

    17813: // Per-step transient buffers come from a World-owned arena (reset each step)
    17816: _ = world.scratch_arena.reset(.retain_capacity);

Contacts live in that arena. **The ids and anchors are computed correctly every step and then
discarded before anything can match against them.**

## The work, and it is bounded

  1. **A persistent map** from `(body_a, body_b, sub, feature_id)` to last step's accumulated
     impulses, living outside the per-step arena. Jolt calls this the contact cache; the file
     already mirrors Jolt closely enough to cite it throughout, so the shape is known.
  2. **Seed on match**: when this step's manifold produces a point whose key was present last
     step, start its `AxisPart.total_lambda` from the cached value instead of zero. That is
     warm starting, and `AxisPart` already accumulates the impulse — 118 references to
     `total_lambda` in the file, so the plumbing is there.
  3. **Anchor on match**: keep `local_a`/`local_b` from the FIRST step the contact appeared,
     rather than recomputing them, and let the position solve pull toward that. **This is the
     part that stops creep** — a resting contact then resists motion from where it started
     rather than merely opposing current velocity.

★★ (3) IS THE ONE THAT FIXES SIMON'S SLIDING, and it is the smaller change: no new storage
beyond the cache (1) needs anyway, and the position solve already consumes those fields.

## ★ THE ACCEPTANCE TEST, FIXED BEFORE THE CODE

A Go1 holding its home pose, nothing commanded to move, 20 seconds:

    today:  1.0168 m of foot slide, friction demand 0.20 of the cone
    bar:    under 0.01 m, with the demand still well inside the cone

★★ AND THE SECOND HALF OF THAT BAR MATTERS AS MUCH AS THE FIRST. If the slide stops because the
demand rose to the cone, the fix has merely traded creep for friction saturation. **The
measurement that identified this — demand as a FRACTION of the limit — is also the one that
verifies the repair.**

## Risk

Contact caching changes every stacking and resting behaviour in the engine, so the existing
physics suite is the real gate. **Do not tune the demo against it** — a change this deep is
verified by the tests that already exist, and only then by a robot.

# ═══ ★★★ CORRECTION AFTER READING THE CODE: TWO THIRDS ALREADY EXIST ═══

The plan above was written from field names. Reading the solver changes it substantially.

## ✅ WARM STARTING IS ALREADY IMPLEMENTED

    16591: const point_key: PointKey = .{ .a = @min(a,b), .b = @max(a,b), .sub = sub, .feature = ... };
    16597: point.normal_part.total_lambda = world.cache.lookupNormal(point_key);

`ManifoldCache` holds `normal_now` / `normal_prev` per `PointKey`, plus `lookupFriction` /
`storeFriction` per manifold. **Items 1 and 2 of the plan are done.** The engine already carries
both normal and friction impulses across frames and seeds the solver with them.

★ SO THE CREEP IS NOT A MISSING WARM START. That hypothesis is dead, and it was the obvious one.

## ★★★ AND THE ANCHOR IS NORMAL-ONLY, WHICH IS THE REAL FINDING

    18372: const world_a = body_a.com_pos + rotate(body_a.rot, p.local_a);
    18375: const gap = dot3(world_b - world_a, c.normal) + s.penetration_slop;

`local_a` / `local_b` ARE persisted-shaped — local frames, per feature — but the position solve
projects their difference **onto the normal only**. They are a PENETRATION anchor. The tangential
component of `world_b - world_a` is computed and thrown away.

**So persisting them would change nothing.** Nothing reads the tangential part.

## The actual remaining work, now precisely scoped

**Add a tangential position term.** Either:

  * project `world_b - world_a` onto the two tangents as well, and feed that offset as a BIAS
    into `friction1` / `friction2` — so static friction resists displacement from where the
    contact formed, not merely current velocity; or
  * apply a direct tangential position correction alongside the existing normal one.

★ AND THE ANCHOR MUST THEN COME FROM THE FIRST STEP THE FEATURE APPEARED, cached by `PointKey`
like the impulses already are — otherwise it is recomputed from the current manifold every step
and describes no fixed place.

## 🛑 WHY I AM STOPPING HERE RATHER THAN STARTING IT

This is a change to the contact solver's position pass, which governs **every stacking, resting
and jamming behaviour in the engine**. The gate is the full physics suite, and iterating on it
needs several runs.

★★ **A HALF-IMPLEMENTED TANGENTIAL ANCHOR THAT BREAKS STACKING WOULD BE FAR WORSE THAN THE CREEP
IT FIXES.** Starting a deep solver change without the room to verify it is how a working engine
becomes a broken one — and the creep is a slow drift in one demo, not a blocker.

★ WHAT THIS SESSION LEAVES BEHIND IS THE VALUABLE HALF: the work is scoped from "implement
contact persistence" — which turned out to be **already done** — to a single, specific,
well-understood addition, with a measurement that proves the need and an acceptance test that
would prove the fix.

    today:  1.0168 m of foot slide in 20 static seconds, demand 0.20 of the cone
    bar:    under 0.01 m, demand still well inside the cone
