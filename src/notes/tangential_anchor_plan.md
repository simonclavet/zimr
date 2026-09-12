# ═══ THE FREE KNOBS ARE EXHAUSTED — AND ONE ROW IS A TRAP ═══

    setup                    slid (m)   cone   iters   ns/step
    shipped default           0.8097   0.20    60.0    359025
    in the demo now           0.1545   0.24    60.0    375096
    min .995                  0.1531   0.25    60.0    350811
    min .999                  0.0524   0.45    60.0    344982   <- INVALID CONFIG
    min .999 width 1e-5       0.1545   0.24    60.0    347304
    min .9999 width 1e-5      0.1545   0.24    60.0    350199
    min .999 width 1e-3       1.4242   1.58    60.0    357841   <- CONE OVER 1

## ★★★ THE 0.0524 ROW IS NOT SHIPPABLE, AND FINDING OUT WHY IS THE USEFUL PART

`robot.zig:1090` requires **`0 < min <= max < 1`**. `contactImpedance` (robot_physics.zig:237)
hardcodes `max = 0.99`. So `min = 0.999` is `min > max` — **a configuration the engine declares
invalid** — and its 0.0524 m is whatever the arithmetic happens to do outside its domain.

★ IT RAN BECAUSE THE CHECK IS A `@compileError` ON JOINT LIMITS AND THERE IS NO RUNTIME
EQUIVALENT FOR CONTACT IMPEDANCE. The bridge can hand the solver an impedance the model would
have rejected at comptime, and nothing says so. **That is a real gap worth closing** — an assert
in `contactImpedance` or wherever `constraint_impedance` is written would have caught this
sweep's own mistake immediately.

★★ AND THE `width 1e-3` ROW SHOWS WHAT INVALID LOOKS LIKE WHEN IT GOES THE OTHER WAY: creep
1.42 m, **cone occupancy 1.58** — the solver asking for 58% more friction than the ground can
supply. Worse than shipped on both counts. **The cone column is what makes that visible**; on
slide distance alone it would just look like a bad setting rather than a broken one.

## ★★ WITHIN VALID SETTINGS, THE FREE LEVER IS SPENT

`min` is capped at 0.99 by `contactImpedance`, and:

    min .99   width 1e-4    0.1545 m
    min .995  width 1e-4    0.1531 m   (0.9% better — noise)

**The demo already has the best valid free configuration.** 5.2x from the shipped default, at no
measurable cost, and further stiffening inside the legal range buys nothing.

★ THE width 1e-5 ROWS COMING BACK IDENTICAL TO width 1e-4 (0.1545 to four decimals, twice) says
the width has stopped mattering below about 1e-4 — the settled contacts are deeper than that, so
the ramp is fully saturated either way. **Another flat result, another parameter eliminated.**

## What is actually left, in order

  1. **Raise `max_iterations` past 60.** The solver is pinned at the cap in every row of every
     sweep — it is the one thing measurably still limiting the answer. **Not free**, so the
     decision needs the creep-versus-ns curve rather than a single point.
  2. **Let `contactImpedance` reach above 0.99** — properly, by raising `max` alongside `min` and
     checking the cone stays under 1. The invalid row hints there may be something here, but it
     has to be measured with a legal configuration before it means anything.
  3. **The tangential anchor**, still last.

★★★ AND FIRST, CHEAPER THAN ANY OF THEM: **validate contact impedance at runtime.** This sweep
spent a row on a configuration the engine already knew was illegal, and said nothing.

---
---

# ═══ ★★★ MEASURED: STIFFER IMPEDANCE CUTS CREEP 5.2x FOR FREE ═══

Static Go1, 20 s, creep and cost measured together so a fix cannot trade one for the other:

    setup                    slid (m)   cone   iters   ns/step
    as shipped                0.8097   0.20    60.0    301988
    tolerance 1e-8            0.8097   0.20    60.0    304844
    tolerance 1e-10           0.8097   0.20    60.0    312133
    impedance .99/.999        0.1545   0.24    60.0    311149
    impedance .95/.99         0.6132   0.20    60.0    296558
    narrow width 1e-4         0.1597   0.23    60.0    308976
    stiff + narrow            0.1545   0.24    60.0    301854   <- FASTER than shipped

## ★★★ THREE FINDINGS, AND THE FIRST TWO KILL HYPOTHESES

**1. TOLERANCE IS NOT THE LEVER.** 1e-6, 1e-8 and 1e-10 give byte-identical creep. A flat sweep
means the swept parameter is not the cause — the third time this project has learned that, and
it saves the "solve tighter" direction entirely.

**2. THE SOLVER IS AT ITS ITERATION CAP, ALWAYS.** `iters 60.0` in every row, and 60 IS
`max_iterations`. It never converges, which is exactly why tolerance does nothing — the loop
exits on the cap, not on the residual. **The engine's own comment (5128) about "14 iterations"
was measured on a different scene and does not describe this one.**

**3. IMPEDANCE IS THE FREE LEVER.** 0.9/0.95 to 0.99/0.999 takes creep from 0.81 m to 0.155 m —
**5.2x** — and `stiff + narrow` came out at **301,854 ns/step against the shipped 301,988**, which
is a wash within noise. No extra iterations, no new state, no solver change: the same arithmetic
with a different constant.

★ AND THE FRICTION CONE STAYS INSIDE ITS LIMIT — occupancy 0.20 to 0.24. **The creep did not stop
by trading itself for saturation**, which was the failure mode the acceptance test was written to
catch. The robot is still held by friction it would really have.

## ★★ WHY THIS IS MUJOCO'S ANSWER, ARRIVED AT FROM THE OTHER END

MuJoCo's `impratio` stiffens friction relative to normal *"preventing slip, without increasing the
actual friction coefficient"*. Stiffening the whole contact is the blunt version of the same
move — and on a pyramid basis, where no row is purely frictional, **the blunt version is the one
that is actually available.** MuJoCo's own warning against high `impratio` with pyramidal cones
says as much.

## 🚧 IT IS NOT ENOUGH ON ITS OWN

    bar:      under 0.010 m
    reached:  0.155 m

**5.2x for free, and still 15x short.** The remaining options, now properly ordered by cost:

  1. **Raise `max_iterations` above 60.** The solver is pinned at the cap, so this is the one
     lever known to be doing something — but it is paid every step, and the point of this sweep
     was to avoid that. **Measure the creep/ns curve before deciding**: if 90 iterations buys
     another 3x for 10% cost, that may be worth it; if it buys 10% for 50%, it is not.
  2. **Push impedance further** — 0.999/0.9999. Free if it works, and the cone occupancy is the
     thing to watch: it must stay well under 1.
  3. **The tangential anchor** below, which is now the third choice rather than the first.

★★★ AND THE ORDER MATTERS BECAUSE (1) AND (2) ARE MEASUREMENTS AND (3) IS A PROJECT. The sweep
that produced this table is one probe and it moved the number 5x; the anchor is 40 lines in a
contact solver with a whole physics suite as its gate.

---
---

# ⚠️⚠️ READ THIS FIRST — THE CREEP IS IN `robot.zig`, NOT `zimrphysics.zig`

Everything below the MuJoCo section was investigated in the WRONG SOLVER. There are two:

  * **`zimrphysics.zig`** — the general rigid-body engine (Jolt-shaped: sequential impulse,
    `ManifoldCache`, `AxisPart`). **It does not have this problem.**
  * **`robot.zig`** — the articulated-body solver, which is what the quadruped actually runs.
    The bridge harvests contact GEOMETRY from zimrphysics; `robot.zig` builds the constraint rows
    and solves them. `rows_per_contact = 4`, `constraint_force`, `addContactRows` — all the
    quantities the creep was measured with are ITS quantities.

★ THAT ONE FACT INVALIDATES THE `CachedFriction` / `AxisPart` / `prepare(...)` plan below
entirely. Those are zimrphysics types and the creeping solver never touches them.

---

# ★★★ WHAT `robot.zig` ACTUALLY DOES, AND WHERE IT DIVERGES FROM MUJOCO

## It is a faithful MuJoCo port — including the impedance model

`robot.zig:472` has MuJoCo's `solimp` as `Impedance{ min, max, width, midpoint }`, the same
sigmoid. `constraint_violation`, `constraint_impedance`, the pyramid basis — this is MuJoCo's
design, ported.

## And the pyramid convention is CORRECT

`robot.zig:4628`:

    const violation: f32 = contact.distance - contact.margin;
    ... every pyramid row gets `d.constraint_violation[row] = violation;`

That looks wrong against MuJoCo's elliptic path, which zeroes friction positions
(`mju_zero(cpos, con->dim); cpos[0] = con->dist;`). **But MuJoCo's PYRAMIDAL path does the same
thing robot.zig does** — `engine_core_constraint.c:1679`: `cpos[0] = cpos[1] = con->dist;`.
Giving every pyramid row the normal distance is the pyramid convention, in both engines.

**So that is not the bug.** Worth stating plainly, because it is the first thing that looks
wrong and chasing it would waste a day.

## ★★★ THE DIVERGENCE: `robot.zig` PORTED `solimp` BUT NOT `impratio`

`robot.zig:4670`:

    d.constraint_impedance[row] = contact.impedance;

**Every row of the contact — the normal row and all four friction rows — gets the same
impedance.** MuJoCo divides the friction rows' regularisation by `impratio`
(`R[i+1] = R[i]/impratio`), documented as:

> *"causes friction forces to be harder than normal forces, having the general effect of
> preventing slip, without increasing the actual friction coefficient."*

★ **THAT IS THE MISSING PIECE, NAMED BY THE ENGINE THIS ONE WAS PORTED FROM**, and it is the
exact symptom: slip that more friction does not fix.

---

# ★★ BUT THE PYRAMID COMPLICATES IT — AND MUJOCO SAYS SO

> *"For pyramidal friction cones the situation is more complex because the pyramidal
> approximation mixes normal and frictional dimensions within each basis vector; it is not
> recommended to use high impratio values with pyramidal cones."*

`robot.zig` uses a pyramid: each row's direction is `normal + sign·mu·tangent`. **There is no row
that is purely friction to stiffen.** Raising every contact row's impedance stiffens the normal
direction too, which changes penetration behaviour and contact stability.

So the options, in increasing order of cost:

  1. **More solver iterations.** `solver_iterations` is reported per step (2687) and the header
     at 5174 shows 14 iterations in a benchmark. Sequential/iterative solvers creep because they
     stop early — **the cheapest possible test is to raise the cap and see whether the creep
     falls.** If it does, the creep is convergence and nothing structural is wrong.
  2. **Raise contact impedance** toward 1 (currently `min 0.9, max 0.95`). Affects the normal
     direction too, so it must be checked against penetration and against the slope test.
  3. **A per-row impedance scale** — `impratio` for the pyramid, applied only to the friction
     COMPONENT of each row. Requires deciding what that means for a mixed basis, which is
     precisely the complexity MuJoCo warns about.
  4. **An elliptic cone**, which would give genuinely separate friction rows and make `impratio`
     straightforward. The largest change, and the one MuJoCo itself recommends for high impratio.

★★★ **RUN (1) FIRST.** It is a parameter, it is free, and a solver that stops at 14 iterations
while creeping 50 mm/s is the simplest possible explanation. **Measure before building anything.**

---

# THE TEST, UNCHANGED AND STILL FIRST

One box — or better, the quadruped standing still, since that is the measured case — and a single
scalar:

    today:  1.0168 m of foot slide in 20 static seconds, cone occupancy 0.20
    bar:    under 0.01 m, cone occupancy unchanged

★ SWEEP `solver_iterations` AGAINST THAT NUMBER BEFORE TOUCHING ANY CODE. A flat sweep says the
creep is structural and sends you to (2)-(4); a falling one says it was convergence all along.
**That is one probe and it decides between a parameter and a solver rewrite.**

---
---

# 🗄️ BELOW: THE ORIGINAL PLAN, WRITTEN AGAINST THE WRONG SOLVER

Kept because the MuJoCo analysis in it is sound and transfers — but `CachedFriction`, `AxisPart`
and `prepare(...)` are zimrphysics types, and **zimrphysics is not where the creep is.**

---

# ⚠️ READ THIS FIRST — MUJOCO DOES NOT SOLVE IT THE WAY THIS PLAN PROPOSES

Studying `mujoco-main` after writing the plan below changes the recommendation.

## ★★★ MUJOCO GIVES FRICTION ROWS **ZERO** POSITION ERROR

`engine_core_constraint.c:1698`:

    // normal pos = dist, all others 0
    mju_zero(cpos, con->dim);
    cpos[0] = con->dist;

Its reference acceleration (3255) is `aref = -B*vel - K*(pos-margin)` — **both** a velocity and a
position term, applied to every row. But for a contact, only the NORMAL row gets a non-zero
`pos`. The friction rows get zero, so their `aref` reduces to `-B*vel`.

**MuJoCo has the machinery for a position-level friction term and deliberately does not use it.**
That is a strong signal: the plan below proposes exactly what the most respected contact solver
in robotics chose not to do.

## ★★ WHAT IT DOES INSTEAD: STIFFEN THE FRICTION CONSTRAINT

`engine_core_constraint.c:2222`:

    // set R[1] = R[0]/impratio
    R[i+1] = R[i]/mju_max(mjMINVAL, m->opt.impratio);

`R` is the constraint regularisation; dividing it makes friction stiffer than the normal
direction. From MuJoCo's own reference documentation:

> *"Settings larger than 1 cause friction forces to be **harder** than normal forces, having the
> general effect of **preventing slip, without increasing the actual friction coefficient**."*

★★★ **THAT IS THIS EXACT PROBLEM, NAMED, WITH A ONE-PARAMETER ANSWER.** Not an anchor, not a
position solve on the tangents — a stiffer friction constraint, plus a global convex solve run to
convergence so the per-step residual that creeps is small to begin with.

## ★ SO THE ORDER OF WORK CHANGES

  1. **First, look for zimrphysics's equivalent of `impratio`.** `AxisPart` already has a
     `softness` term — `effective_bias = part.bias + part.softness * part.total_lambda` — and the
     comment says it is 0 for rigid constraints. **Find out what the friction rows actually
     use**, and whether stiffening them (or simply giving friction more solver iterations)
     removes the creep. That is a parameter change, not 40 lines in the contact solver.
  2. **Then, and only if that fails**, consider the anchor below. It is a real technique — PhysX
     uses friction anchors — but it is the heavier answer, and MuJoCo's choice is evidence that
     the lighter one is usually enough.

★★ THE ONE-BODY TEST IN SECTION 5.1 IS STILL THE FIRST THING TO WRITE, and it is now MORE
valuable: it measures creep against a single scalar, which is exactly the shape needed to sweep
a stiffness parameter. **Write the test, sweep the knob, and only reach for the anchor if the
sweep flattens.**

★ AND THE SWEEP HAS A KNOWN FAILURE MODE, also from MuJoCo's docs: *"it is not recommended to use
high impratio values with pyramidal cones"* — because a pyramid mixes normal and friction into
each basis vector. **zimrphysics uses a four-row pyramid basis** (`rows_per_contact = 4`), so
this warning applies directly and the sweep must watch for normal-force artefacts, not only creep.

---

# Stopping the creep: a tangential anchor for resting contacts

## The symptom, twice, by independent routes

    flat ground, nothing moving, 20 s   slid 1.0168 m   cone occupancy 0.20
    17.6 deg slope, mu 1.50, 18 s       slid 0.1064 m   cone occupancy 0.74
                                        (Coulomb says it holds to 56.3 deg)

**Both slide while the friction cone has grip to spare.** More friction raises a limit that is
never reached. This is not Coulomb slip.

---

# 1. WHY IT CREEPS — THE EXACT MECHANISM

`AxisPart.solveGetTotalLambda` (zimrphysics.zig:3532):

    jv     = dot3(axis, rel_lin) + angular terms      // relative velocity along the tangent
    lambda = effective_mass * (jv - effective_bias)

and the friction constraint is prepared with **bias = the conveyor surface velocity**, normally
zero (16622):

    contact.friction1.prepare(ma, inv_i_a, rf_a, mb, inv_i_b, rf_b, tangent1, dot3(tangent1, surf));

★★★ **SO STATIC FRICTION IS PURELY A VELOCITY CONSTRAINT: it drives relative tangential velocity
to zero and knows nothing about position.** Every step it removes the velocity it can see, and
every step a little residual survives — solver tolerance, the gap between the velocity solve and
the integration, warm-start ramp-in. Those residuals integrate. **Nothing anywhere pulls the
contact back toward where it was**, so the errors accumulate forever in whatever direction they
happen to point.

★ THE NORMAL DIRECTION DOES NOT HAVE THIS PROBLEM because the position solve exists for it
(18375): `gap = dot3(world_b - world_a, c.normal)`. **The machinery is there and is applied to
exactly one of the three directions.**

---

# 2. THE FIX — ANCHOR THE TANGENTIAL DIRECTIONS TOO

Give each resting manifold a **material anchor**: the point where it first stuck, stored in each
body's local frame so it follows the bodies. Each step, measure how far the two anchors have
separated tangentially, and feed that as a velocity bias so the friction constraint drives the
contact *back*.

## 2.1 Storage — extend `CachedFriction`

    pub const CachedFriction = struct {
        linear: [2]f32,
        angular: f32,
        anchor_a: Vec,      // where the manifold stuck, in A's local frame (relative to COM)
        anchor_b: Vec,      // ditto for B
        anchored: bool,     // false = no anchor yet this contact
    };

★ IT RIDES THE EXISTING CACHE. `friction_now` / `friction_prev` are already keyed by
`ManifoldKey{a, b, sub}` and already survive a step, and `purgeCacheMap` already drops entries
naming a removed body. **No new lifecycle, no new invalidation path** — which matters, because
lifecycle bugs in a contact cache are the ones that produce irreproducible jitter.

## 2.2 Set the anchor when the manifold appears

In the block at 16628 that reads `lookupFriction`:

    const cached = world.cache.lookupFriction(friction_key);
    if (cached.anchored) {
        anchor_a = cached.anchor_a;
        anchor_b = cached.anchor_b;
    } else {
        anchor_a = rotate(conjugate(body_a.rot), friction_center - body_a.com_pos);
        anchor_b = rotate(conjugate(body_b.rot), friction_center - body_b.com_pos);
    }

`friction_center` is already computed here for `rf_a` / `rf_b`, so this costs two rotations.

## 2.3 Measure the drift and turn it into a bias

    const world_a = body_a.com_pos + rotate(body_a.rot, anchor_a);
    const world_b = body_b.com_pos + rotate(body_b.rot, anchor_b);
    const drift   = world_a - world_b;

    // Only the tangential part — the normal direction has its own position solve.
    const drift_t = drift - normal * splat(dot3(drift, normal));

    const beta: f32 = 0.2;   // see 3.1
    const bias1 = dot3(tangent1, surf) - beta * dot3(tangent1, drift_t) / dt;
    const bias2 = dot3(tangent2, surf) - beta * dot3(tangent2, drift_t) / dt;

★★ **THE SIGN FOLLOWS FROM THE SOLVE, NOT FROM INTUITION.** `lambda` drives `jv` toward `bias`,
and `jv` is `(v_a - v_b)` along the tangent (16619 says so). If A has drifted in `+t` relative to
B, `dot3(t, drift_t) > 0`, and we want `v_a - v_b` NEGATIVE along `t` to come back — hence the
minus. Getting this backwards doubles the creep instead of removing it, and would look like the
fix "making it worse", so **it is worth checking against a one-body test before anything else.**

## 2.4 ★★★ RESET THE ANCHOR WHEN THE CONTACT ACTUALLY SLIPS

**This is the subtlety that makes or breaks the whole thing.**

If a box is genuinely sliding down a steep slope, its anchor stays where it first touched and the
measured drift grows without limit. The bias then demands an ever larger corrective velocity —
which the cone clamps, so it does not explode, but the constraint spends its entire budget
fighting an impossible target and the sliding friction becomes wrong.

**When the friction impulse saturates the cone, the contact IS slipping, and "where it stuck" is
now.** So after the solve, when storing:

    const saturated = @abs(lambda1) >= limit - epsilon or @abs(lambda2) >= limit - epsilon;
    if (saturated) {
        // re-anchor to the current contact position: it slipped, this is the new home
        store .anchored = false   (or store the current friction_center)
    } else {
        store the existing anchor unchanged
    }

★ THE CONE CHECK ALREADY EXISTS in the solve loop around 18215 (`lambda1`,
`solveGetTotalLambda`, then the cone clamp). The saturation flag falls out of the clamp that is
already computed — **no new physics, one boolean.**

---

# 3. THE PARAMETERS, AND WHY THESE VALUES

## 3.1 `beta` — how much of the drift to remove per step

**0.2, not 1.0.** Removing the whole error in one step makes the friction constraint fight the
velocity solve within the same iteration: the bias demands motion that the cone then clamps,
which changes the effective velocity target, which changes the drift next step. That is a
feedback loop with a gain of one, and it rings.

★ 0.2 removes the error with a time constant of about five steps — 20 ms at 250 Hz — which is far
faster than the creep accumulates (50 mm/s means 0.2 mm per step) and slow enough not to
interact with the iteration count.

★★ AND IT MUST BE SWEPT, not assumed: **0.05, 0.1, 0.2, 0.4, 0.8**, watching both the creep and
the stacking tests. A value that fixes creep and makes boxes jitter is not a fix.

## 3.2 The drift cap

    const max_drift: f32 = 0.01;  // 1 cm
    drift_t = clampLength(drift_t, max_drift);

★ WITHOUT A CAP, a single bad frame — a tunnelled contact, a teleport, a body repositioned by
game code — writes a huge anchor error and the correction launches the object. **The cap makes
the worst case a bounded nudge instead of an explosion**, and 1 cm is far larger than any real
creep while far smaller than any real displacement.

---

# 4. WHAT COULD GO WRONG, AND HOW EACH IS CAUGHT

| risk | symptom | guard |
|---|---|---|
| sign flipped | creep doubles | one-body test, section 5.1, run FIRST |
| no slip re-anchor | sliding objects stick or judder on slopes | slope test above `atan(mu)` must still slide freely |
| `beta` too high | resting stacks jitter | existing `zimrphysics_stack_test` |
| anchor survives a teleport | object snaps back after being moved | `bridge.teleported()` must clear the cache for those bodies |
| rolling treated as sliding | balls stick instead of rolling | a rolling-ball test; rolling has zero contact-point velocity so the anchor should track naturally, but **this is the case I am least sure of and it must be measured** |

★★ THE ROLLING CASE DESERVES SPECIAL ATTENTION. A rolling ball's contact point is instantaneously
stationary, which is exactly what the anchor wants — but the contact FEATURE changes every step
as new surface comes round, so `feature_id` may not match and the anchor may re-form constantly.
**If that happens the fix is harmless there (no accumulated anchor, behaviour unchanged), but it
must be confirmed rather than hoped.**

---

# 5. THE TEST ORDER — CHEAPEST DISCRIMINATOR FIRST

## 5.1 One body, flat ground, no robot

A single box resting on level ground for 20 s. **Nothing should move at all.**

★ THIS RUNS BEFORE ANY OTHER TEST because it isolates the sign and the mechanism from every other
variable. If a lone box on flat ground still creeps, nothing about a quadruped will be
informative. And if the sign is backwards, this is where it is obvious.

## 5.2 The existing physics suite, unchanged

`zimrphysics_stack_test`, `character_walk_test`, `snapshot_regression_test`. **These are the real
gate.** A change to the contact solver's tangential behaviour touches every resting, stacking and
jamming case in the engine.

★ **DO NOT TUNE AGAINST THE ROBOT DEMO.** The suite is what says whether the engine still works;
the robot is what says whether the symptom is gone. Confusing the two is how a working engine
becomes a broken one with a nice-looking demo.

## 5.3 The slope, both sides of the threshold

`examples/friction_slope`, already built:

  * **below `atan(mu)`** — must hold, and now must hold WITHOUT creeping;
  * **above `atan(mu)`** — must still slide freely, at a rate matching `g(sin θ − μ cos θ)`.

★★ THE SECOND HALF IS THE ONE THAT CATCHES AN OVER-EAGER FIX. An anchor with no slip reset makes
everything stick, which passes the creep test and breaks the physics. **The demo already prints
cone occupancy**, so the check is direct: sliding should show a FULL cone, holding should show a
partial one, and neither should drift.

## 5.4 The quadruped, last

    today:  1.0168 m of foot slide in 20 static seconds
    bar:    under 0.01 m, with cone occupancy unchanged at about 0.20

★ THE SECOND CLAUSE MATTERS AS MUCH AS THE FIRST: if the sliding stops because the demand rose to
the cone, the fix has traded creep for saturation and the robot is now held by friction it does
not have on a real surface.

---

# 6. SCOPE

Roughly **40 lines** across three sites in `zimrphysics.zig`:

  * `CachedFriction` — three fields (8376);
  * manifold setup — anchor lookup, drift, bias (16610-16632);
  * solve/store — the saturation flag and the anchor write-back (18215 area).

★ NO NEW ALLOCATION, no new lifecycle, no change to the constraint solver's structure. **The
smallness is the point**: this rides machinery that already exists and works, which is why it is
worth doing carefully rather than cleverly.

★★★ AND THE ONE-BODY TEST IN 5.1 IS THE FIRST THING TO WRITE, before any of the code above.
It is twenty lines, it isolates the mechanism completely, and every subsequent test is harder to
interpret without it.
