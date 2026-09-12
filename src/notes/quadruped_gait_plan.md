# Quadruped gait — a plan

Goal: a Go1 you can drive. Forward, strafe, turn on the spot, blended; long strides; stable
on uneven ground. Each footstep chosen on its own, so the gait emerges from the commands
rather than from a fixed clock.

## 0. What is there now, and why it is not enough

`examples/quadruped` walks with a **kinematic** gait: a phase clock, IK to foot targets,
position-controlled joints. No force reasoning anywhere. Its own comments record the
consequence — measured, trotting at 1.6 Hz:

    duty 0.50  ->  sags to 0.11 m, on its belly
    duty 0.70  ->  falls at 2.5 s
    duty 0.85  ->  z 0.346, no sag

Duty 0.85 means three or four feet on the ground almost always. That is not a trot, it is a
shuffle, and it is the only thing that stands up because nothing is deciding how hard each
foot pushes. Long strides and real trots need ground reaction forces to be *planned*.

## 1. ★★★ THE MEASUREMENT THAT DECIDES THE ARCHITECTURE

Whole-body iLQR on the Go1, measured (ReleaseFast, one core):

    robot.step, no contacts ........  4.1 us
    robot.step, 4 foot contacts .... 12.3 us
    transition() per knot ..........  206 us     (1 base + 48 columns of an 18-dof step)

    horizon   linearise/iteration   iterations per 16.7 ms frame
        20            4.1 ms                4.1
        50           10.3 ms                1.6
       100           20.6 ms                0.8

Those are contact-FREE numbers; standing on four feet triples the step, so a gait-length
horizon of 50 knots costs **~30 ms per iteration — under one iteration per two frames**.

**So the trunk cannot be planned with whole-body iLQR.** Not "would be slow": a gait needs
half a second of lookahead and several iterations per tick, and this is two orders of
magnitude short. Any plan that starts by tuning the existing optimiser is planning to fail.

## 2. The decomposition

Standard in the literature (MIT Cheetah 3, ANYmal) and it is also what Simon proposed: plan
each step on its own. Five layers, each cheap, each testable alone.

    command (vx, vy, yaw_rate)
        |
        v
    [1] gait scheduler ....... which feet are in stance at each future instant
        |
        v
    [2] footstep planner ..... WHERE each swing foot lands (this is the strafe/turn layer)
        |
        v
    [3] trunk MPC ............ trunk trajectory + ground reaction forces, given 1 and 2
        |
        v
    [4] swing trajectories ... a spline from liftoff to the planned footstep
        |
        v
    [5] whole-body mapping ... forces -> joint torques (stance), IK+PD (swing)

### [3] is the part that changes everything: a SINGLE RIGID BODY model

Plan the TRUNK as one rigid body with forces applied at the four feet. Not the 18-dof robot.

    state    = [position(3), orientation(3), linear velocity(3), angular velocity(3)]  = 12
    control  = 3 force components x 4 feet                                             = 12

Two consequences, and both are large:

* **The linearisation is ANALYTIC.** Rigid-body dynamics with known contact points has a
  closed-form Jacobian — no finite differences at all. That sidesteps the f32 precision wall
  (F22/F23) completely rather than tuning around it, which is exactly the outcome Simon asked
  for when he ruled out f64 and autodiff.
* **It is ~100x cheaper.** No differencing, and the backward pass is 12x12 rather than 36x36.
  Estimated ~0.1 ms per iteration at horizon 20 against 30 ms — hundreds of iterations per
  frame instead of half of one.

★ AND IT IS CONVEX. Linear dynamics + quadratic cost + a friction cone is a convex problem:
**no local minima.** Every non-convexity headache from the cartpole work — different optima
between build modes, a cold solve landing in a bad basin, horizon 100 diverging where 60 and
150 worked — simply does not arise. For a robot that must not fall over, that is worth more
than the speed.

## 3. Phases, each with the thing that says it worked

### Phase 1 — split `robot_mpc.zig` into a core and a robot binding — ✅ DONE

The backward Riccati pass, the line search, `boxQP` and the gain bookkeeping are all generic
in `A`, `B` and the cost. What is robot-specific is `rollout` (calls `rbt.step`), the
linearisation loop (calls `deriv.transition`), and `stateDiff`/`readState`.

Split so the SRBD planner reuses the core rather than growing a second copy of a Riccati
recursion. **Verify:** every existing MPC test passes unchanged after the split.

**Done.** `src/mpc_core.zig` — 570 lines, compiles with `zm` alone and no robot import at all:
`Cost`, `Limits`, `Problem` (a read-only VIEW the caller builds from its own layout, so no
planner has to adopt this file's storage), `Gains`, `Predicted`, `Scratch`, `cholesky`,
`choleskySolve`, `boxQP`, and `backward`.

Two shape changes fell out of the split and both are improvements:

* `backward` returns `?Predicted` instead of `bool`. The predicted improvement used to be
  stashed in scratch fields (`expected_1`/`expected_2`) and read back out; returning it makes
  the "already optimal vs bad model" distinction of F21 a value rather than a side effect.
* The box limits arrive as `?Limits` rather than a `has_limits` flag plus two slices, so the
  unbounded case is unrepresentable-as-wrong instead of merely unset.

**All 128 tests pass unchanged** — LQR-gain oracle, box-QP's four hand-computed cases, control
limits, the closed-loop swing-up, the shift invariant. `Plan`'s public API is untouched, so
`examples/mpc_cartpole` needed no edit.

★ AND THE TUTORIAL CAUGHT UP AUTOMATICALLY, because `doc-sync` failed the moment §36 quoted
the pre-split `backward`. `mpc_core.zig` is now a fourth source in the pair table, and §36
says where the code lives and why the split exists.

### Phase 2 — the SRBD model and its analytic linearisation — ✅ DONE

**Verify, and this is the important one:** the analytic `A` and `B` must agree with a
finite-difference linearisation of the same SRBD dynamics, at several states, to ~1e-4.
Cross-checking analytic against numerical is the standard way to catch a sign error in a
cross-product term, and a sign error here is a robot that falls over for reasons that look
like tuning.

**Done.** `src/srbd.zig` — `Body`, `Stance`, `step`, `linearize`, `hoverForces`, three tests.
State is `[p(3), rpy(3), v(3), ω(3)]`, control is 3 forces x 4 feet, `ω` in WORLD axes because
the foot torques `r × f` are naturally world.

★ AND THE CROSS-CHECK IMMEDIATELY EARNED ITS KEEP. The first version wrote the **yaw column of
`A` as zero**, reasoning that `T` is "frozen per knot". The numerical difference disagreed at
once — 0 against −0.0106. Frozen means frozen ACROSS THE HORIZON, not blind to the state it
was evaluated at: `step` reads yaw to build both `T` and `Iw⁻¹`, so rotating the body changes
the map turning `ω` into `Θ̇` AND the inertia the torque acts against. The exact column is a
handful of flops:

    dRz/dψ = Rz'                 dT/dψ = (Rz')ᵀ
    dIw⁻¹/dψ = Rz'·D·Rzᵀ + Rz·D·Rz'ᵀ
    ∂ω'/∂ψ = dt·(dIw⁻¹/dψ)·τ
    ∂Θ'/∂ψ += dt·( (dT/dψ)·ω' + T·∂ω'/∂ψ )

It is proportional to the TORQUE, which is why `linearize` takes `u` as well as `x` — a
linearisation point is a state and a control, not a state alone. Nothing about convexity
changes; `A` and `B` are still constants once formed.

★ AND SELF-CONSISTENCY IS NOT ENOUGH, so there is a second test that checks `step` against
PHYSICS rather than against its own derivative: free fall at exactly `g` with no feet down;
four feet at `m·g/4` leaving every one of the twelve states unchanged; and both torque SIGNS,
with the convention written out (`front foot at +x pushing +z gives r × f = −y`, so nose-up is
NEGATIVE pitch). A shared mistake between `step` and `linearize` would pass the first test and
fail these.

A third pins that a swing foot contributes nothing — to the step AND to `B`'s columns — since
`active` is the only channel by which the contact schedule reaches the optimiser, and a
non-zero column there would let the planner push with a foot in the air.

### Phase 3 — gait scheduler and footstep planner — ✅ DONE

Scheduler: a phase per leg with configurable offsets. Trot `{0, .5, .5, 0}`, walk
`{0, .5, .25, .75}`, plus stand. Emits a contact schedule over the horizon.

Footstep planner — the Raibert heuristic, which is where strafe and turn-in-place come from
for free:

    p_foot = p_hip_at_touchdown + (T_stance / 2) * v_desired + k * (v_actual - v_desired)

`p_hip_at_touchdown` is the hip position *rotated by the commanded yaw rate over the swing*,
so a pure yaw command makes the feet land on a circle and the robot turns on the spot with no
special case. A pure lateral command makes them land sideways. Blends blend.

**Verify:** commanded (0,0,ω) puts the four footsteps on a circle about the trunk centre;
commanded (v,0,0) puts them a stride ahead; and the *sum* of the two is the sum of the plans.

**Done.** `src/gait.zig` — `Gait` (frequency, duty, per-leg offsets) with `stand`/`trot`/`walk`
presets, `legPhase`/`inStance`/`swingProgress`/`timeToTouchdown`, `Command`, `Layout`, `Trunk`,
`footTarget`, `contactSchedule`, `advance`. Five tests.

Turn-in-place verified: with a pure yaw command every foot lands displaced along its OWN
tangent and all four stay within 5 cm of the hip radius — a circle. No line of the file
mentions turning; it falls out of using the HIP's velocity `v_desired + ω × r_hip` rather than
the body's.

★ AND SUPERPOSITION IS **EXACT**, WHERE I PREDICTED APPROXIMATE. The argument for approximate
was that the yaw rate enters inside `Rz(yaw + ω·t_td)`, which is not linear in its angle. True
and irrelevant: that term appears identically in the pure-turn plan and the combined plan, so
it cancels in `both − (turn + walk − base)`. Measured gap 2.1e-8 at yaw rate 0.2 AND at 1.5 —
the same number, which is float noise rather than a trend, by the rule that a quantity
identical across a swept parameter is not a function of it.

The structural reason is `t_td`: **time to touchdown comes from the clock, not the command**.
Once it is fixed every dependence on the command is affine. So a driver can blend freely and
nothing has to special-case the diagonal. The test now asserts the exact identity across all
four legs and three yaw rates including a negative one.

★ AND ONE TEST FAILED FOR THE RIGHT REASON: a forward command placed the foot 0.018 m short of
the pure geometry, which is exactly `0.6 × 0.03` — the Raibert feedback correctly stepping SHORT
because the robot was not yet moving as fast as commanded. The geometry assertions now use a
trunk already at speed, and the feedback term has its own assertion with its sign pinned.

### Phase 4 — swing trajectories and the force-to-torque map — ✅ DONE

Swing: a cubic or Bezier arc from liftoff to the planned footstep, apex height a parameter.

Stance: `tau = -J_foot^T * f_planned`, where `J_foot` is the foot's translational Jacobian —
`robot.zig` already has `jacBody`/`jacSite`, MuJoCo-verified.

**Verify:** with the robot standing and the planner asked for a pure vertical hold, the
torques it produces match the ones `PoseHold` produces for the same stance, to a few percent.
Two independent routes to the same answer.

**Done**, though NOT by the check written above — see below. `gait.swingPoint` (smoothstep
horizontally, `16t²(1−t)²` vertically, zero derivative at both ends so a foot neither drags on
liftoff nor scuffs on landing) and `src/quadruped.zig` with `stanceTorques` and `footPosition`.

★ THE PLANNED CHECK WAS THE WRONG ONE, and the wrong number said so. Comparing `−Jᵀf` against
`bias_force` at the LEG joints gave a correlation of **−0.62**, and the code was right:
`|Jᵀf| = 10.9` against `|c_leg| = 1.6`. Those are not the same quantity — the ground force
carries a quarter of the ROBOT, the leg bias carries a thigh and a calf. From `M·v̇ + c = τ + Jᵀf`
static equilibrium at a leg joint is `τ = c − Jᵀf`, **dominated by `−Jᵀf`**, so anticorrelation
with a small `c_leg` is exactly what the physics predicts.

★ THE FLOATING BASE IS WHERE THE CLAIM IS FALSIFIABLE, and it needs no controller to compare
against. The base has NO ACTUATORS, so its six rows of the same equation read
`c_base = (Jᵀf)_base` with nothing else in them: the ground forces alone must cancel gravity on
the whole robot and produce no net moment. That is an identity. It now checks the vertical
balance to 5%, the three moment rows to 0.5, that flipping the forces inverts it, and that
`stanceTorques` leaves the base rows at exactly zero — which is the restriction it exists to
make, since the trunk cannot torque itself.

★ AND A CLEAN FACTOR OF TWO IS A COUNTING BUG. An intermediate version bent a `LegWiring` into
producing the base rows and got 62.5 against 125.0 — each base DOF fed by two legs instead of
four, because the struct holds three DOFs per leg by design. The test computes the identity
itself now, and `stanceTorques` keeps its restriction.

### Phase 5 — close the loop on flat ground — 🚧 IN PROGRESS, NOT WORKING

Stand, then trot in place, then trot forward, then strafe, then turn.

**Verify, as a test, not by eye:** trunk height stays within a band for 10 s; commanded
velocity is tracked to some tolerance; and — the one the old gait fails — **duty can go to
0.5 without sagging.** That is the number that says forces are being planned rather than
hoped for.

**Built, not working.** `TrunkPlan`, `solveTrunk`, `forceBox`, `buildTrunkReference` are in
and compile; the acceptance test is written, FAILS, and is `SkipZigTest` so the tree stays
green while the banner above it records the state. Three attempts:

    attempt                                        z range           tilt    x after 4 s
    1. footTarget re-evaluated every knot          [ 0.194, 0.474]   0.08    0.40
    2. planted feet held, offset vs CURRENT centre [−3.885, 0.480]  13.82    3.09
    3. planted feet held, offset vs PREDICTED      [−0.748, 0.467]  10.39    0.26

★ ATTEMPTS 2 AND 3 EACH FIXED A REAL MODELLING ERROR AND EACH MADE THE NUMBER WORSE. Worth
reading rather than reverting: (1) bounced ±14 cm because a planted foot was modelled as
SLIDING, and it survived only because the slide happened to track the body. Removing the error
removed that accidental support with it. A metric getting worse as the model gets more correct
means something else was leaning on the error.

★ THE PRIME SUSPECT WAS `forceBox` AT KNOT ZERO, AND IT WAS A REAL BUG THAT WAS NOT THE BUG.
Fixing it — `Problem.limits` is per-knot now, `horizon × nu`, and the articulated path fills
every knot with the same box — made the trot WORSE (tilt 19.3). The actual fault only appeared
on the simplest case:

**The planner could not hold a motionless robot up.** Four feet down, no gait, no command: it
returned **exactly zero force on all four feet**, every tick, and the trunk free-fell to
−19.5 m while the cost climbed to 2.6e6. `backward` was returning null. `Q_uu` is 12×12 —
three components at four feet — but reaches the trunk through SIX physical dimensions, so it
is rank-deficient by construction; in f32 a control weight of 5e-4 cannot separate the six
null directions from zero, the Cholesky hits a non-positive pivot, and the "plan" is an
unsolved linear system.

That is the statically-indeterminate force allocation named as a risk in §4 before a line was
written. The fix is the regularization ladder `optimize` already uses: raise the diagonal
until the factorisation succeeds. **With it the stand is exact — `fz` converges to 29.41 N
against a quarter-weight of 29.4, found by the optimiser rather than told** — and trot tilt
fell from 19.3 rad to 0.97, from a body spinning freely to a body rocking.

★★ ALWAYS ISOLATE ON THE SIMPLEST CASE FIRST. Four attempts went into the gait — the contact
model, the moment arms, the force box — while the planner could not hold a still robot up.
Every one of those was a real bug and none of them was THE bug. The stand test took ten
minutes and would have found it before any of them.

★ OLD NOTE, KEPT BECAUSE IT WAS THE RIGHT SHAPE OF SUSPICION AND STILL WRONG: `backward` holds one `Limits` for the
whole horizon, so a foot in swing NOW is pinned to zero force at EVERY future knot — including
the ones where it should be carrying the robot. At duty 0.5 that is half the feet, permanently.
The tilt of 10 rad is the tell: that is not a robot leaning, it is a body spinning freely,
which is what a planner told most of its feet cannot push would produce.

`Problem.limits` is per-knot now. What remains for the trot: the contact set inside the
horizon is still wrong for a SWITCHING gait — a leg in stance keeps one contact point across
knots where it lifts and re-lands — and the predicted trunk centre uses the commanded velocity
rather than the reference being tracked. The robot walks BACKWARD on a forward command, which
points at a sign error in a moment arm rather than at weights.

Next: move that bookkeeping out of the test into a controller function, and verify it on a
WALK (duty 0.75, one foot swinging) before attempting a trot.

### F-DEMO — the demo found a bug in ten seconds that the tests had not

`examples/mpc_quadruped` renders the trunk, the contact points and the planned forces. First
look at it on a device: **vertical force 34.25 N against a weight of 117.72**, height sagging
0.300 → 0.206, and the trunk visibly sitting off to one side of its own feet.

The cause was a velocity command issued while the gait was STAND. No foot lifts, so no foot is
re-planted, but the reference still translates — the trunk walks out from over its support, the
moment arm `r = foot − centre` grows without bound, and the planner cannot push up without
tipping. So it trades vertical force away and sags.

★ THE PLANNER WAS RIGHT. It was handed a geometry with no solution and returned the least-bad
answer available. **You cannot translate without stepping**, and `stand` now says so: the
command is zeroed and the panel explains why.

★ AND THE READOUT THAT WOULD HAVE MADE IT OBVIOUS IS NOW THERE — "trunk off feet", the
horizontal distance from the centre of mass to the centroid of the contact points, against a
support radius of about 0.19 m. Watching vertical force sag without that is watching a symptom.
Every test so far measured height and tilt; none measured whether the robot was still ON its
feet.

### Phase 6 — uneven terrain

Terrain enters in exactly three places, which is the point of the decomposition:

* the footstep planner queries ground height at the candidate landing spot;
* the swing arc clears the ground between liftoff and landing;
* the trunk MPC gets the real contact heights, so it leans correctly.

**Verify:** a 5 cm step up, a slope, and scattered blocks — crossed without falling, and
compared against the same terrain with the old kinematic gait, which should visibly fail.

### Phase 7 — the demo

Drive it. A virtual stick for `(vx, vy)`, another for yaw. Draw the planned footsteps as
markers and the trunk MPC's predicted CoM path as a ribbon — the same "watch it think" idea
that made the cartpole demo readable.

Frame budget as before: the trunk MPC is cheap enough that this is not in doubt, but the
budget loop stays, because the swing IK and the whole-body map are not free.

## 4. Risks, named in advance

* **The contact seam.** Feet hit zimrphysics geometry, and the two solvers do not negotiate
  (F17). For static ground the "immovable" approximation is exact, so this is fine — but the
  moment anything the robot steps on can move, it is not, and the escape hatch is to put that
  object in the robot's own tree.
* **Force allocation is the hard part, not the trunk.** Four feet on the ground is a
  statically indeterminate problem: many force distributions hold the same trunk. The cost
  has to break the tie, and a bad tie-break shows up as chattering feet rather than as an
  error. Watch for it and make the regulariser explicit.
* **Yaw representation.** SRBD linearises orientation about the current attitude; a naive
  Euler parameterisation is fine near level and wrong when the trunk pitches hard. Keep it
  small-angle about the *current* attitude, and say so in the code.
* **Do not reuse the cartpole's cost weights.** They were tuned for a 1-dof problem and will
  read as "MPC does not work" if they are carried over unexamined.

## 4b. ★★★ THE FILE SPLIT WAS WRONG, AND THE EVIDENCE SAID SO

Phase 1 put the model-agnostic iLQR in its own `mpc_core.zig`, justified as "so the SRBD
planner reuses the core rather than growing a second copy of a Riccati recursion".

**Reuse never needed a separate file.** Checked: `mpc_core.zig`'s only real consumer was
`robot_mpc.zig` — the other two importers were the `zimr.zig` re-export and the `tests.zig`
registration, which are bookkeeping. Same for `srbd`, `gait` and `quadruped`: one or two
consumers each, all inside this subsystem.

★ WHAT ACTUALLY MATTERED WAS THE API DECOUPLING — `backward` taking a `Problem`/`Gains` VIEW
instead of a `*Plan`. That is a property of the signature, and it survives the merge intact.
Conflating "make it model-agnostic" with "give it its own file" is the error.

`robot_derivative.zig` went the same way for the same reason — one real consumer — bringing it
to FIVE files merged into one. The only collisions the single namespace produced were `Options`
(now `DerivativeOptions`) and a second `Scratch` (now `DerivativeScratch`), both of which the
compiler named immediately.

So the five files are now one. `robot_mpc.zig` is ~4 130 lines against `robot.zig`'s 12 000 and
`zimrphysics.zig`'s 18 000 — entirely in keeping. Six banner-separated sections: finite-difference derivatives, the iLQR core,
the trunk model, the gait, the whole-body map, and the articulated binding. **349 tests
pass unchanged**, which is what proves the merge was mechanical.

Renames the single namespace forced, all of them improvements:
`mpc_core.Cost` → `Weights` (it is the weights, and `Cost` was already taken by the one with a
reference trajectory); `srbd.step`/`linearize` → `srbdStep`/`srbdLinearize` (bare `step` next to
`rbt.step` was a trap); `srbd.Body` → `TrunkModel`; `srbd.max_feet` and `gait.leg_count` were
the same four and are now one constant.

## 4c. ★★★ THE MODEL IS MISSING THE INVERTED-PENDULUM TERM

Simon asked, looking at the demo drift with zero command: *"are the feet forces able to
constrain horizontal movement correctly?"* Two bugs came out of chasing that.

**(a) The friction box was not inside the friction cone.** `forceBox` bounded the tangential
components by `μ·f_max/√2` with `f_max` a CONSTANT, and the doc comment claimed that fits
inside the cone. It does not: at `fz = 0` the cone permits nothing and that box permitted 85 N.
Measured, standing with zero command: the feet produced **149.95 N then 230.10 N of tangential
force while carrying 0.56 N of load**, and the trunk slid sideways to 7.8 m *with no tilt at
all*. A body translating with zero tilt on planted feet is the signature — only horizontal
force can do that, and none was available in reality. Fixed by bounding against that foot's own
normal force, estimated from the hover share on the first pass and from the previous pass after
that. Lateral runaway went 7.78 m → 0.18 m.

**(b) And underneath it, `srbdLinearize` has no `∂ω′/∂p`.** The torque is `τ = Σ rᵢ × fᵢ` with
`rᵢ = footᵢ − p`, so with planted feet a pure translation changes every moment arm and produces
torque. That coupling IS the inverted pendulum, and the model does not have it:

    ∂τ/∂p  = Σ [fᵢ]×        ∂ω′/∂p = dt·Iw⁻¹·Σ[fᵢ]×        ∂Θ′/∂p = dt²·T·Iw⁻¹·Σ[fᵢ]×

★ WHY THE CROSS-CHECK MISSED IT: that test holds `Stance.offset` FIXED across the sweep, and
with a fixed offset the term genuinely is zero — the feet move with the body, which is a
hovering platform rather than a robot on the ground. Analytic and numerical agreed perfectly on
a case that never exercises the missing block. **A verification is only as good as the states
it sweeps.**

★ AND IT EXPLAINS THE EARLIER "STAND WORKS EXACTLY" RESULT, which used exactly that fixed-offset
probe. The 29.41 N force allocation was real; the stability was an artefact of the geometry
never changing. Measured now: stable indefinitely with offsets fixed, falls from ANY lookahead
between 0.2 s and 1.2 s once the feet are planted. **Lengthening the horizon does not help,
because the horizon is not the problem — the model inside it is blind.**

Next: add the position columns, and extend the Jacobian cross-check to sweep states where the
contact points are FIXED IN THE WORLD rather than fixed relative to the trunk.

## 4d. ★★★ A NEW DIRECTION, AND A HARD FACT ABOUT THE GO1

Simon's suggestion: forget gaits, stand on three legs, and reach a slider-controlled point with
the fourth foot. It is a better plan than debugging the trunk planner further — it uses the
REAL articulated robot (real legs, real reach, real contacts) instead of a testbed that has
already been shown unable to settle anything, and it is one step of a walk, frozen.

Measured before building anything, on the real Go1 with `PoseHold` and foot contacts:

    lifted foot   shift CM first   trunk z   roll     verdict
    none          --                0.332   -0.001    STANDS
    any of 4      no               -0.309   ±3.10     falls (rolls 180 degrees)
    any of 4      yes              -0.31    ±3.11     falls

★ **THE GO1 CANNOT STAND ON THREE LEGS FROM ITS HOME STANCE, AND THE REASON IS GEOMETRIC.**
Feet sit at (±0.19, ±0.13). The diagonal from (0.19, 0.13) to (−0.19, −0.13) passes exactly
through the origin, so the centre of mass lies precisely ON THE EDGE of whichever triangle
remains. Marginally stable, and it tips. This is why real quadrupeds shift their weight before
lifting, and why static walks need duty above 0.75 — the numbers `examples/quadruped` measured
by trial (0.85 stands, 0.70 falls) have a geometric explanation.

### ★★★ MEASURED THE CM INSTEAD OF ASSUMING IT — AND FOUND TWO THINGS

Simon's plan (move the CM over the average of the other three feet, THEN lift 5 cm) is the
standard static walk and is right. It failed because the implementation was wrong, so the CM
was measured directly rather than assumed:

    lift   goal for CM      CM before        margin    CM after         margin   moved
    FR     (-0.082, 0.043)  (-0.051, 0.001)  +0.0191   ( 0.215,-0.299)  -0.379   0.401 m
    FL     (-0.082,-0.043)  (-0.051, 0.001)  +0.0175   ( 0.211, 0.300)  -0.378   0.398 m
    RR     ( 0.042, 0.043)  (-0.051, 0.001)  -0.0175   (-0.264,-0.231)  -0.330   0.315 m

(margin = signed distance to the nearest triangle edge, positive inside)

**(1) THE CM IS NOT AT THE ORIGIN.** It sits at (−0.051, 0.001) — 51 mm behind centre, because
the Go1's trunk mass is not centred between the hips. So the four-foot stance is NOT symmetric
about the CM, and the two diagonals are not equivalent: **lifting a FRONT foot leaves the CM
already inside the triangle by ~19 mm, while lifting a REAR foot leaves it 17 mm outside.**
That asymmetry decides which leg a static walk can lift first, and no amount of gait tuning
substitutes for knowing it.

**(2) `BalancedIk` MOVES THE CM THE WRONG WAY — 0.40 m, away from a goal 0.05 m off.** Its
maths is right (`Δq = J_comᵀ·gain·drift`, a proper descent direction). The misuse is mine: it
computes the CM with the BASE FIXED and the feet free, which is the arm case it was written
for. A standing quadruped is the opposite — the FEET are pinned and the base moves — so
flexing a stance leg displaces the trunk rather than the foot, and the CM moves opposite to
what the model predicts.

★ THE RIGHT TOOL IS ALREADY IN THE TREE: `examples/quadruped`'s `solveBodyPose`. Command the
TORSO pose, pin the feet, and the leg angles are fully determined — both ends of every leg are
fixed. Its own comment carries the matching lesson, measured: solve from the CAPTURED stance,
because re-deriving from the live robot each frame turns a constant into an unstable loop
(trunk climbs 0.3327 → 0.3515 → then loses contact at 0.2134).

So the plan stands, with the implementation corrected:
  1. shift the commanded TORSO pose so the CM lands over the three-foot centroid, feet pinned;
  2. wait for it to settle, and MEASURE the margin rather than assuming;
  3. only then lift the fourth foot 5 cm;
  4. lift a FRONT foot first — the margin says it is the easier case by 36 mm.

★ OLD NOTE, KEPT: A NAIVE WEIGHT SHIFT DID NOT RESCUE IT. `BalancedIk` pulling the CM to the centroid of the
three remaining feet, applied for a full second BEFORE the lift (an earlier version lifted at
step zero while the shift was still happening — the one thing a real quadruped never does),
still tips. So either the shift is not reaching the CM, or a centroid target is not far enough
inside the triangle. **That is the next thing to measure**, and it is measurable directly:
compute the actual CM against the triangle's edges and report the margin, rather than assuming
the IK achieved what it was asked for.

The probe is kept at `src/notes/three_leg_probe.zig.txt`.

★ AND NOTE WHAT "falls" MEANS HERE: trunk z reaches −0.31, i.e. it passes through the floor.
Only the FEET have contacts, so once the robot tips the trunk and thighs meet nothing. For a
demo where tipping is a likely outcome, the body needs contacts too, or the failure looks like
a bug in something else.

## 4e. ★★★ IT STANDS ON THREE LEGS — TWO BUGS, NEITHER WHERE I LOOKED

Simon's plan works. Measured, Go1, real contacts, three phases:

    phase                        lift   margin    trunk z   roll     foot lift   verdict
    no shift, no lift            FR     +0.0375    0.361   -0.001    0.022       OK
    shift only, four down        FR     -0.1098    0.335   -0.009    0.023       OK
    shift then lift 5 cm         FR     -0.1094    0.335   -0.006    0.043       STANDS ON 3
    shift then lift 5 cm         FL     -0.1081    0.336    0.002    0.043       STANDS ON 3
    shift then lift 5 cm         RR     -0.3817   -0.335    3.123   -0.020       falls
    shift then lift 5 cm         RL     -0.3793   -0.335   -3.123   -0.020       falls

**A FRONT foot lifts 43 mm and the robot holds, level, at 0.335.** Rear feet still fall — which
is exactly what the CM measurement predicted a turn earlier: the CM sits 51 mm behind centre, so
a front lift starts inside the support triangle and a rear lift starts outside it. The physics
was right; only the code was wrong.

★ BUG ONE: **`applyKeyframe` is not a memcpy.** `robot.keyframes[0].qpos` is in the FILE's
layout; the model's differs in the free joint's quaternion. Copying the raw array put the Go1
**upside down** — feet at z = 0.535, above a trunk at 0.27. Every IK solve, foot position and CM
number in this arc described an inverted machine, and nothing complained, because an inverted
pose is still a valid pose.

★ BUG TWO, AND IT IS THE ONE THAT ACTUALLY HELD IT DOWN: **a missing `rbt.forward` after
restoring the live state.** The loop swaps in the commanded pose, runs IK, swaps the live pose
back and marks it stale — but `plantFeet` reads `body_xpos` to decide where contacts go and how
deep they are. Stale kinematics meant contacts placed from the IK configuration, several
centimetres from the actual feet. The robot was being held up by contacts that were not under
it.

★★ AND MY DIAGNOSIS THE TURN BEFORE WAS WRONG. I had concluded "the IK round-trip is not the
identity" and made that the next thing to chase. Measuring it directly took one probe: identity,
zero iterations, `reached = true`, `max |qpos − home| = 0.000000`. The IK was never the problem.
**The measurement that would have exonerated it took ten minutes and I deferred it a full turn
in favour of a hypothesis.**

★ WHAT THE MARGIN COLUMN SAYS NOW: it goes NEGATIVE while the robot happily stands (−0.11 with a
front foot up). So the CM leaving the support triangle is not fatal here — the lifted leg's own
mass and the contact softness carry it. The margin is a useful diagnostic, not a hard predicate,
and a static-stability test built on it would have rejected a configuration that works.

### ★★★ ALL FOUR LEGS NOW LIFT — THE SHIFT HAD TO BECOME A CLOSED LOOP

The rear-foot failure was not "a bigger shift". Moving the torso by `d` does NOT move the CM by
`d`: the legs carry about half the robot and largely stay put, so the CM follows roughly half
as far. Swept the open-loop factor:

    torso shift   front feet          rear feet
    x1.0          OK (margin -0.11)   falls (-0.38)
    x1.5          falls               falls
    x2.0          falls               OK (+0.024)
    x2.5          falls               OK (+0.057)

★ **NO SINGLE FACTOR WORKS.** Front needs one and falls at two; rear needs two and falls at
one — because the open-loop formula computes a different target displacement for each
(0.082 backward versus 0.042 forward), while the CM needs about the same travel either way.
There is no constant to find, which is why looking for one kept failing.

★ INTEGRATING THE MEASURED CM ERROR REMOVES THE CONSTANT. `torso_offset += rate·(goal − CM)`
converges on whatever displacement the geometry actually needs. **All four legs then work with
one setting, margin +0.071 for every one of them** — the same number four times, which is the
loop arriving at the same place regardless of which foot comes up. Rate 0.002 and 0.005 hold;
0.010 overshoots and tips every foot.

★ AND THE LIFT NOW WAITS FOR THE MASS, NOT FOR A TIMER: the foot only rises once the measured
margin is actually positive. A fixed delay works until the shift is slower than the delay, and
then the robot steps off a support it has not reached yet.

`examples/three_leg` demonstrates it: pick any foot, drive it with sliders, and watch the
yellow CM dot move over the green support triangle before the foot leaves the ground. Turning
the shift off rolls the robot over instantly, whichever foot is chosen.

### 🚧 THE STATIC WALK: IT WALKS, THEN FALLS

Sequenced four three-leg steps in the crawl order rear-right, front-right, rear-left,
front-left — never two on the same side or the same diagonal in a row, which is what keeps a
triangle with the mass inside it available at every phase. Feet swing forward on
`swingPoint`, and the body is NEVER commanded forward: it advances because the SUPPORT does,
since the torso chases the centroid of whichever three feet are down.

**It walks, then falls.** Best run 0.715 m before going over; several strides and sway rates
all end the same way.

★ THE TRACE NAMES THE MECHANISM. At t = 1.0 s: torso offset −0.372 m, legs asked to span
**0.880 m against a Go1's true reach of 0.426**, trunk launched to z = 0.480 from 0.270.

**An integrator with no rate limit slams.** The CM error at the start of a step is about
0.11 m, so at a gain of 0.01 per tick the commanded torso slews at **0.57 m/s** — faster than
the legs can follow. The commanded root runs past their reach, the IK saturates, and
`PoseHold` drives hard at the resulting extreme pose. Rate-limiting the per-tick motion helps
and does not fix it: 0.05, 0.10 and 0.20 m/s all still fall.

★ WHAT I WOULD DO NEXT, AND IT IS A DESIGN CHANGE RATHER THAN A TUNING PASS: **the torso
should be commanded forward as part of the gait, not left to chase the centroid.** Chasing is
a CORRECTION and it is being asked to be the DRIVE — so it always lags, the error stays large,
and the integrator stays saturated. A static walk commands the body forward by one stride per
cycle and uses the CM loop only for the lateral sway on top of that. Then the error the
integrator sees is small, and a rate limit is a safety net rather than the thing holding it
together.

Probe kept at `src/notes/walk_probe.zig.txt` with the sweep and the trace already wired.

### 🚧 IT STAYS UP NOW, BUT BARELY MOVES — THE TRADEOFF, MEASURED

Two changes since: the torso is FEEDFORWARD to `goal − com_offset` (the root position that puts
the CM on the goal, computed rather than integrated toward) with a small residual integrator on
top, and the swing is gated on the support margin.

★ THE TRACE FIRST, because it says exactly where the old version died. It completed **two steps
cleanly** and failed on the third:

    t=0.6  leg RR  margin +0.057  reach 0.361   fine
    t=0.9  leg FR  margin +0.022  reach 0.353   fine
    t=1.5  leg RL  margin -0.079  reach 0.369   already negative
    t=1.8  leg RL  margin -0.286  reach 0.583   gone

The margin at swing START was +0.022 and then FELL during the swing. A gate on the starting
margin does not keep the mass inside for the whole step.

★ SWEEPING THE GATE GIVES THE TRADEOFF IN NUMBERS:

    gate 0.02   travels -0.329   falls
    gate 0.05   travels  0.572   falls
    gate 0.08   travels  0.070   WALKS — trunk level at 0.334, tilt 0.074
    gate 0.11   travels  0.070   WALKS

**At 0.08 it stays up indefinitely and covers one stride in 24 s** — it spends nearly all its
time waiting for a margin it rarely reaches. Stable and useless; below that, quick and falls
over.

### ✅ AIMING DEEPER WORKS, AND EXPOSED THE REAL FAULT

`aim = centroid + bias·(centroid − swing_foot)` implemented and swept:

    bias 0.0   travels -0.581   tilt 3.58   falls
    bias 0.3   travels  0.488   tilt 2.33   falls
    bias 0.6   travels  0.422   tilt 1.74   falls
    bias 0.9   travels  0.401   tilt 1.48   falls

Tilt more than halves and the robot now completes about EIGHT steps instead of two. So the
diagnosis was right and the fix is real.

★★★ AND THEN THE SWEEP THAT MATTERED: with bias on, gate 0.03 / 0.06 / 0.09 give **byte-
identical** results, and so do swing 0.6 s and 1.0 s. Every combination falls at ~0.42 m.
**A quantity identical across a swept parameter is not a function of it** — so the remaining
fault is in none of these knobs. Aiming deeper raised the margin above every gate, and the
gate stopped being what limits the gait.

### ★★★ ONLY ONE STEP EVER COMPLETES — AND "AIM DEEPER" AIMED THE WRONG WAY

Two hypotheses tested and killed, and the real picture found.

**Warm-starting the IK from the previous command: no effect.** 0.422 m either way, tilt 1.743
against 1.733. The re-seed was never the problem.

**Counting the steps was what mattered.** Final state after a "0.42 m walk":

    steps completed 1   foot x:  0.188  0.188 -0.128 -0.188   trunk x  0.422

**Only leg RR ever moved**, by exactly one stride. The other three are still where they
started, and the trunk has travelled 0.422 m — with three feet planted and a leg reach of
0.426 m. **That is not walking, it is the trunk being thrown while the feet stay put**, which
is also why the distance always came out near the leg length and why no timing parameter
changed it.

★★★ AND THE BIAS FORMULA IS BACKWARDS. `centroid + k·(centroid − swing_foot)` extrapolates
AWAY from one vertex — which moves the target toward the OPPOSITE EDGE, so it gets SHALLOWER,
not deeper. The centroid is already near the deepest point of a triangle; the genuinely deepest
is the incenter, and neither is reached by pushing away from a vertex.

The sweep said so and I read it as success: travel went DOWN as bias went up (0.488 → 0.422 →
0.401). Only the tilt improved, which is what let it look like progress.

### ✅ THE REACH GUARD, THE PLAIN CENTROID, AND A FORWARD MARCH

All three done, and the picture is finally honest.

**The guard first**, because it turns fiction into a dated abort:

    ★ REACH EXCEEDED at t=1.67s: leg 0 needs 0.426 m, limit 0.426

Checked against the COMMANDED pose, not the live one — the live robot only tells you afterwards
that it could not do what it was asked.

**Bias deleted**, plain centroid restored. With the guard armed the run now reports two clean
steps and then:

    t=1.20  leg FR  margin +0.048  torso_x -0.001   body already retreating
    t=1.60  leg RL  margin -0.122  torso_x -0.037   stuck
    completed 2 steps, trunk x -0.200

★★★ **THE TRUNK WAS GOING BACKWARD** while two feet had advanced 0.06 each. Lifting a FRONT
foot removes it from the support centroid, so the sway target moves behind — correctly, that
IS the weight shift — and **nothing ever pushed forward again.** The centroid is a SWAY target
and it was being asked to be the DRIVE. (I identified this shape two turns earlier and then
implemented "feedforward the torso to the centroid", which is still only the sway.)

**Adding a march — `stride · completed / 4`, with the centroid correction riding on top —
moves it from 2 steps to 3, and the trunk from −0.200 to +0.170.** It now walks forward.

### ✅ A FULL GAIT CYCLE NOW COMPLETES

    sway m/s   steps   trunk x   feet x after
      0.03       4      0.112    0.248  0.248 -0.128 -0.128
      0.06       4      0.130    0.248  0.248 -0.128 -0.128
      0.12       2     -0.169    0.248  0.188 -0.128 -0.188
      0.25       3      0.170    0.248  0.188 -0.128 -0.128

**At 0.03 and 0.06 m/s all four feet have advanced by exactly one stride** — a complete crawl
cycle — before a leg reaches its limit at the start of the second.

★★★ THE SWAY SPEED IS SET BY LEG COMPLIANCE, NOT BY THE PLAN, and instrumenting commanded
against actual body position is what showed it:

    t=1.40  cmd -0.022  actual -0.113   0.09 m behind
    t=1.80  cmd  0.027  actual -0.178   0.21 m behind
    t=2.60  cmd  0.135  actual  0.142   now ahead

Moving a 12 kg trunk means bending springy legs against planted feet, and `PoseHold` at kp 100
is a badly damped second-order system. Commanding 0.25 m/s produced a **±0.2 m oscillation of
the body relative to its feet** — which is what stretched a rear leg, not the march. Slowing
the command to 0.03 m/s lets it track, and the gait immediately doubles its steps.

★ AND ONE IDEA WAS A NO-OP, WHICH IS WORTH RECORDING SO IT IS NOT TRIED AGAIN. Replacing
`stride · completed / 4` with the mean of the four foot positions gave **byte-identical**
output. They are the same quantity: each completed step advances one foot by `stride`, so the
mean advances by `stride/4` per step. The "self-correcting when a step is delayed" property I
imagined does not exist — both are driven by completed steps, not by time.

### 🚧 THE DEMO FLIPS ON THE FIRST STEP; THE PROBE DOES NOT. NOT YET EXPLAINED.

Reported from a device: the walk in `examples/three_leg` goes over immediately, while the
headless probe with the same parameters completes four steps. **Not reproduced headlessly**, so
the two fixes below are defensible on their own merits and are NOT confirmed to be the cause.

★ FIXED ANYWAY — TWO REAL STALENESS BUGS IN `s.margin`:

  1. **On the walk toggle.** `s.margin` is computed for whichever leg the lift-mode combo last
     EXCLUDED. The crawl starts on a different leg, so the first gate check reads a margin
     belonging to another triangle — and if a foot had just been held up, that margin is
     comfortably positive and the first swing fires with the torso shifted for the wrong foot.
  2. **On every step transition.** When `steps_done` increments the active leg changes, but
     `s.margin` still describes the triangle just finished, where the weight was deliberately
     shifted. The gate passes instantly and the next foot leaves with no shift at all.

Both now force `margin = -1`, so the gate must wait for a value computed for the leg actually
about to move. **Applying the same invalidation to the probe changed nothing** — byte-identical
four steps — which is how we know it was not what the probe was hitting.

★ AND A PHASE READOUT, because "flips on the first step", "never steps" and "steps too early"
look identical from outside:

    steps 0   next leg rear right
      shifting weight: margin -0.0175 / gate 0.030

That is the state to read off the next screenshot: whether it is waiting for a margin it never
reaches, or swinging with one it should not have.

★ WHAT ENDS THE PROBE RUN: the trunk finishes each cycle about **0.05 m ahead of the mean foot**
position, and that lead accumulates until a rear leg maxes out early in cycle two. The four
support centroids average exactly to the mean foot, so the bias is not geometric — it is
DWELL: the gait waits different lengths of time on each leg for the margin gate, so the
time-average of the sway target is not its spatial average. Equalising dwell, or subtracting the
running mean of the sway, is the next thing to try.

★ OLD NOTE: STILL FAILING, AND THE GUARD NAMES IT: `REACH EXCEEDED at t=2.99s: leg 2 needs 0.427 m`.
The rear legs advance once per cycle while the body marches continuously, so between their
steps they stretch. **Next: replace the step-counter march with the MEAN OF THE FOUR FOOT
POSITIONS**, which advances exactly as the feet do and is self-correcting when a step is
delayed, instead of running on a counter that assumes every step happens on time.

★ OLD LIST, ITEMS 1 AND 2 NOW DONE:
  1. **Fix the aim**: target the incenter, or just the plain centroid. Delete the bias term.
  2. **Assert leg reach every tick** and abort the run when it is exceeded — every failure in
     this arc announced itself there first, and the run would have stopped at 0.05 m instead of
     producing 0.42 m of fiction.
  3. **Find out why the second step never starts.** The gate opens for step one and never
     again; print the margin continuously through step two rather than sampling it.

★ OLD NOTE, NOW DISPROVEN: the IK re-seeds from `home` every tick, so each solve must
travel the whole accumulated displacement within twelve iterations at a 0.15 step. Early on
that is nothing; after several strides it is the entire distance walked. A consistent
distance-based failure that ignores every timing parameter fits that shape. **Warm-starting the
solve from the previous COMMAND** (still command space — the achieved pose is `target +
steady-state error` and must not be used) is a small change and the thing to try first.

★ OLD NOTE, KEPT: THE FIX IS TO AIM DEEPER, NOT TO TUNE THE GATE. The CM is aimed at the CENTROID of the
support triangle, which is the shallowest point that counts as "inside" — so the margin is
marginal by construction and any drift during the swing takes it out. Real crawl gaits aim
PAST the centroid, biased away from the swinging leg:

    aim = centroid + k · (centroid − swing_foot)

That puts the mass comfortably inside for the whole step instead of just at its start, and the
gate then becomes a safety check rather than the thing holding the gait together. That is the
next thing to do, and it is a two-line change to the probe.

★ AND ONE INVARIANT SHOULD BE AN ASSERTION EVERYWHERE, not a thing I notice afterwards: **leg
reach**. 0.880 m against 0.426 is unmistakable, and every failure in this arc — the SRBD
trunk, the three-leg lift, now the walk — announced itself in that number first. Anything
commanding foot positions should check it and say so.

## 5. What NOT to do first

Do not start by making the existing kinematic gait better. Its ceiling is the duty-0.85
shuffle, and every hour spent tuning it is an hour not spent on the layer that removes the
ceiling. The new path should stand up on its own before the old one is touched.
