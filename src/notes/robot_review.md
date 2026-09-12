# robot review — findings, evidence, and the fix list

Scratch file for the deep review Simon asked for (zimr1156+). Every line here is
either MEASURED in this sandbox or quoted from the tree. Delete when the fixes land.

## What the system actually is

| file | lines | role |
|---|---|---|
| `robot.zig` | 11933 | the engine: spatial algebra → Spec/Model/Data → kinematics → CRB → solver → step |
| `zimrphysics.zig` | 18583 | the Jolt port (maximal coordinates) — the other half |
| `robot_physics.zig` | 2170 | the seam: robot links as kinematic proxies in a zimrphysics world |
| `mjcf.zig` | 2131 | MJCF XML parser |
| `robot_mjcf.zig` | 1614 | parsed MJCF → `robot.Model` |
| `robot_control.zig` | 1600 | PoseHold, IK, actuation helpers |
| `robot_scene.zig` | 522 | scene assembly |
| `robot_bench.zig` | 343 | the §4g benchmark — **not wired into build.zig** |
| `robot_urdf.zig` | 259 | URDF import (rotates Z-up→Y-up; MJCF does not) |
| `physics_common.zig` | 57 | shared bits |

Tests: 111 in robot.zig, 15 robot_physics, 15 robot_mjcf, 17 mjcf, 11 robot_control,
6 robot_scene, 2 robot_urdf. **All green** (`zig build test -Dfocus=tier-a`, 246s).

## MEASURED — the benchmark, run in this sandbox

Built by hand (see "bench is unreachable" below), `-OReleaseFast`, 200k steps/case:

    1. two-link arm              nv  2       371 ns/step   11242x rt  nc 0   solver 0 it
    2. KUKA iiwa, free           nv  7      1628 ns/step    2559x rt  nc 1   solver 1 it
    3. KUKA, all limits active   nv  7      2375 ns/step    1754x rt  nc 5   solver 1 it
    4. Go1 standing, pgs         nv 18     12461 ns/step     161x rt  nc 16  solver 3 it
    4. Go1 standing, newton      nv 18     21659 ns/step      92x rt  nc 16  solver 2 it

## FINDINGS

### F1 — robot.zig's module doc says the file has no `step`. It has had one for months.

`src/robot.zig` header, "## Status":

> PHASE 0 of `src/notes/robot_port_plan.md`: spatial algebra, the model spec, comptime
> validation and enum generation, `Model`/`build`, `Data`, and the qpos↔qvel helpers.
> Kinematics is phase 1; there is deliberately no `step` yet.

`step` is at line 6717. So are contacts, two solvers, tendons, sensors, actuators,
equalities, four integrators. The file is ~12k lines and its own front door describes
the first 1.5k. claude.md's rule — "update the `//!` doc in the same turn, like a
test" — has been broken here for the whole life of the subsystem, and this is the
FIRST thing a fresh session reads.

### F2 — "THIS FILE IS Y-UP" is false for every MJCF model, which is the headline feature

`robot.zig` header states it as an invariant of the file, in a shouting heading.
But `robot_mjcf.zig:31` documents the opposite and gives a good reason:

> ── ★ NO AXIS CONVERSION, AND THAT IS DELIBERATE ──
> The URDF path rotates Z-up into Y-up at the root … This path does NOT, and the
> reason is verification: the acceptance test for MJCF import is that forward
> kinematics agrees with MuJoCo body for body.

And `robot_mjcf.zig:913` sets `.gravity = vec(0, 0, -9.81)` for imported scenes.
`robot_bench.zig:refreshFeet` uses `at[2]` and normal `vec(0,0,1)` — Z-up.

robot.zig is in fact **axis-agnostic**: gravity is an `Options` field and nothing
else in the file assumes an up axis. The header states a DEFAULT as an INVARIANT.
readme.md advertises "It reads MJCF, so models from the MuJoCo Menagerie load
directly" — so the Z-up path is the main path, and the front door denies it exists.

### F3 — readme.md's verification table overstates the evidence for three rows

The table is copied from robot_port_plan.md §"Every subsystem now has an external
oracle". Two different kinds of evidence are presented in one column:

* **Generated MuJoCo fixtures** — `scripts/robot_oracle.py` → `reference.zig`,
  11 models. It emits: qpos qvel mass_matrix bias(qfrc_bias) acc body_pos
  body_ipos subtree_com cinert cdof jac_com_p jac_com_r nefc efc_j efc_pos
  efc_aref ncon contacts contact_bodies efc_r efc_r_ratio efc_diag.
* **Hand-derived closed forms** with a comment asserting MuJoCo agrees.

Rows claiming a MuJoCo field the generator does NOT emit, and which appears
nowhere else in the tree: `ten_length`, `ten_velocity`, `qfrc_passive` — grep
across `src/` and `scripts/` finds these three strings ONLY in the plan's table.
The tendon test (`robot.zig:11861`) is hand-derived; its own comment says
"HAND-DERIVABLE, WHICH IS WHAT MAKES IT AN ORACLE", then asserts "MuJoCo reports
exactly that" with nothing in the repo showing MuJoCo was run.

That is not a bad test — a hand-derivable closed form is arguably a BETTER oracle
than a generated fixture, being independent of MuJoCo entirely. The defect is that
the table launders it as the same evidence as `xpos`-to-1e-4. Fix the table, not
the test. (Still to check: `qfrc_constraint`, `qfrc_actuator`, `sensordata`, `eq_data`.)

### F4 — the benchmark cannot be run from the build

`robot_bench.zig` has `pub fn main`, is named in the plan as the §4g acceptance
measurement, and backs readme.md's headline number. It appears in **neither
`build.zig` nor `src/tests.zig`**. Reproducing the number in this sandbox took a
hand-rolled `build-exe` with a stubbed `build_options` module. A benchmark nobody
can run is a number nobody can check — and readme.md leads with it.

### F5 — the readme's headline compares our fast solver against MuJoCo's default

readme.md: "A Unitree Go1 holding its pose runs at **10.9 µs/step** against
MuJoCo's 20.2 on the same machine — and Newton-solver against Newton-solver, the
two are at parity."

10.9 is PGS. MuJoCo's default is Newton. The honest comparison is the second
clause, and it is the quieter one. Measured here: PGS 12.5 µs, Newton 21.7 µs —
consistent ratio, different machine. Lead with the parity claim; keep the PGS
number as the "and here is a solver choice that is often adequate and ~1.7x
faster" it actually is.

### F6 — "Go1 holding its pose" rises 6 cm while doing it

The bench prints, for both solvers:

    (trunk ended at z 0.3325, home is 0.2700 — still standing: true)

A 23% rise on a 27 cm trunk is not "holding a pose". Both solvers land on the
identical height, so it is a stable equilibrium rather than drift — most likely
the home keyframe is not a contact equilibrium and the robot settles upward. But
the assertion the bench prints ("still standing") passes a robot doing something
the label denies, which is exactly the class claude.md's ★★★ free-fall-benchmark
lesson is about. NEEDS INVESTIGATION — either the premise or the label is wrong.

### F7 — a DISCREDITED diagnosis was still in the code, hiding real leak coverage — FIXED

`robot_mjcf.zig:1311` gave its test a private `DebugAllocator` under a 20-line
argument concluding the 3324-byte ReleaseSafe leak was "an artefact of
DebugAllocator's bucket accounting, not memory this code failed to return."

claude.md's ★★★ "AN ARENA IS NOT MOVABLE" documents the same leak — same size, same
fixture, same ReleaseSafe-only signature — being traced to `readRobot`/`readDefaults`
returning a struct holding a STACK-LOCAL `ArenaAllocator` by value. It was real, and
it is fixed (`Robot.arena: *std.heap.ArenaAllocator`). The workaround outlived it.

MEASURED: flipped to `std.testing.allocator` → 324 passed, 1 skipped, 0 failed,
ReleaseSafe. The comment now tells the true story, including WHY the false diagnosis
was persuasive — every measurement in it was individually true. leakwatch saw zero
live allocations because it counts what passes through the wrapper and a stranded
arena BUFFER never does.

### F8 — the default solver never reaches tolerance on the flagship robot — DOCUMENTED + PINNED

Go1 holding home pose, 16 rows, 20 000 steps, measured:

    pgs     kp 100   residual 6.8e-6   converged FALSE
    pgs     kp 300   residual 3.0e-6   converged FALSE
    newton  kp 100   residual 1.8e-7   converged true
    newton  kp 300   residual 1.2e-7   converged true

PGS stops on `min_progress`, not on `tolerance` — its documented linear-convergence
floor. The simulation is fine (both solvers agree on resting height to 4 decimals,
stance stable indefinitely); what is not fine is reading `constraintConverged` as a
health check. Now in `SolverOptions.algorithm`'s doc AND pinned by a test that fails
loudly if PGS ever starts converging here.

## DONE this pass

* robot.zig header: "no `step` yet" → a real pipeline map of `forward`, plus a
  "what this file does NOT do" section naming the six sibling files.
* robot.zig header: "THIS FILE IS Y-UP" → the truth, that the file is axis-agnostic,
  MJCF stays Z-up (the main path), URDF is rotated. Same for `Options.gravity`.
* `robot_bench.zig`: deleted ~20 lines of dead initial-contact code that used BODY
  position (z 0.1376) instead of GEOM position (z 0.0052) with a fabricated depth,
  and was overwritten by `refreshFeet` before the first timed step. Deleted the
  stale `52,415 ns/step … solver 60 it … 2.6x SLOWER` block, retracted two comments
  later in the same function. `applyKeyframe`'s result is now checked. kp 100 → 300
  so the case is genuinely holding its pose. The self-check now measures JOINT error
  (what the PD servos) rather than a ±28% height box, reads the reference height
  from the keyframe instead of the literal `"0.2700"`, and FAILS the build on a
  violated premise.
* `build.zig`: `zig build robot-bench`. The number readme.md quotes is reproducible.
* `readme.md`: verification table split into generated-fixture vs closed-form, with
  the three rows naming MuJoCo fields nothing in the tree reads corrected; speed
  claim replaced by the build step and a Newton-vs-Newton instruction.

### F9 — `doc-sync` is real, and it protects less than the page implies — DOCUMENTED

Good news first: `zig build doc-sync` genuinely checks every `<pre>` in
`robots.html` against `src/robot.zig` line for line — 1591 lines, 10 exempt
(`class="bad"` counterexamples and `class="sketch"` pseudocode), 0 drifted. The
tutorial's claim to be checked is TRUE, and it is why a sweep of every identifier
in the page found nothing stale.

**But it checks code blocks and nothing else.** §9 carried a paragraph saying
summing rotated geoms "needs a symmetric-3×3 eigen-decomposition… it belongs in
phase 1", above a byte-current code block that already does it correctly:
`Inertia` keeps `diag` + `off` rather than MuJoCo's principal-moments-plus-quaternion
packing, so `rotated()` computes `I' = R·I·Rᵀ` directly (robot.zig:333) and no
decomposition is needed at all. The representation chosen to make CRB cheap
dissolved the work as a side effect. The prose was wrong for months under a green
gate. §9 now tells that story and states the rule: when the page and the code
disagree, the code wins and the page is the bug.

### Tutorial structure — fixed

* 167 KB, 32 sections, **no navigation of any kind**. Added a grouped contents
  block: six parts in reading order, plus an "asides" group, with the section
  numbers kept and explained as build order. All 32 `<h2>` got ids; verified all
  32 links resolve and no section is orphaned.
* `<title>`/`<meta description>` described sections 2–6 of 32 ("spatial algebra,
  the comptime model spec, and the runtime Model/Data split"). Rewritten.
* "What you will be able to do by the end" stopped at phase 1. Extended through
  contact, solvers, MJCF and control — which is 11 of the 32 sections.
* §9 retitled from "What phase 0 deliberately did not do" and its stale "Next"
  roadmap (measure comptime cost → phase 1 → then CRB, all long done) removed.

**Not a defect after all:** §19 and §28 ("What you can do now" / "…honestly") look
like a duplicate pair and are not — §28 opens "Everything in §19, plus:" and is a
deliberate second checkpoint. Read them before touching them; I nearly did not.

### F10 — "the solver is where the Go1's 12 µs goes" — MY HYPOTHESIS, AND IT IS WRONG

Last turn I said PGS at 15 iterations was "the obvious first place to look". Measured
it: same warm state, same controller, same contacts, ONLY `max_iterations` varied.

    cap    1     2     3     5    10    20    60
    ns  9886 10909 11328 11975 12148 13234 12625

**Capping the solver at a single iteration saves about 16% of the step.** The other 84%
is not the solver. Any optimisation aimed there was aimed at the wrong place, and the
one A/B that would have said so took ten minutes.

### F11 — `solver_iterations` is a DISTRIBUTION and the bench printed one sample — FIXED

`data.solver_iterations` holds whatever the last step needed. On a warm Go1 that
fluctuates step to step, so successive runs of the same benchmark printed `3 it`,
`15 it`, `2 it` for identical work — and I quoted those numbers as if they meant
something. Now accumulated over the run:

    pgs     5.0 mean, 27 max
    newton  1.9 mean,  5 max

The mean says what the solver typically costs; the max says whether anything is ever
hard. **27 is information the single sample never showed** at any point in this review.

### F12 — a stage breakdown I ALMOST published, and why it was worthless

I timed each pipeline stage by calling it 50 000 times in a loop and summing:

    kinematics 532 · comPos 476 · crb 375 · factorM 514 · comVel 69
    makeConstraints 585 · biasForce 210 · forwardDynamics 213 · solveConstraints 593
    TOTAL 3567 ns   — against a measured 12 874 ns full step

The total is a third of the real step, and `solveConstraints` reads as trivial. Both
are artefacts: **calling a stage repeatedly on an unchanging state measures the stage
re-run on its own output.** `solveConstraints` on an already-solved state converges in
zero iterations; `factorM` refactors an unchanged matrix in warm cache. A second
attempt — full step vs step with `clearContacts` — was also invalid, because removing
the contacts also removed the controller and the foot-placement loop that ran inside
the same helper, so the 8.4 µs difference was not attributable to the constraint path.

Neither number is in this repo. The valid measurement is the cap sweep in F10, because
it changes exactly one thing.

### F13 — ANSWERED, with the right instrument, and it is `projectConstraints`

`profiler.zig`'s zones already wrapped every stage of `forward`, inside real steps, on
a state that keeps evolving. They were the correct tool for F12's question and had
never been pointed at it. Now permanently part of `zig build robot-bench`:

    robot.step         15295 ns  x1.0   99.5%
    robot.forward      13055 ns  x1.0   84.9%
      robot.solve       4213 ns  x1.0   27.4%   <- the solver proper
      robot.project     4031 ns  x1.0   26.2%   <- nobody suspected this
      robot.factorM      693 ns  x3.0   13.5%   <- THREE times per step
      robot.constraints  974 ns  x1.0    6.3%
      robot.kinematics   668 ns  x1.0    4.3%
      robot.crb          604 ns  x1.0    3.9%
      robot.comPos       575 ns  x1.0    3.7%
      robot.rne          302 ns  x1.0    2.0%
      robot.comVel       182 ns  x1.0    1.2%

**The constraint path is 60% of the step** (solve + project + constraints), which
partly rehabilitates the hypothesis F10 demolished — and refines it into something
actionable. `projectConstraints` costs as much as the solve itself and **is not
affected by the iteration cap at all**, which is exactly why the F10 sweep saw only
16%: capping iterations trims part of `solve` and leaves `project`'s 26% untouched.
The two measurements never disagreed; the first one just could not see the second's
subject.

`factorM` at x3.0/step is the other surprise and the cheapest thing to look at first:
one of those is the base factor and the others are the damped refactor the implicit
damping path needs. Whether all three are necessary is a question nobody had the
information to ask before.

### F14 — my own breakdown was wrong AGAIN, and the tell was in the output

First run printed `x0.6/step` for EVERY row — including stages called exactly once.
The profiler's frame ring holds 256 and I asked for 400; `aggregate` summarised the
256 it still had and every calls-per-step figure came out at 0.64 of the truth. It
does not fail, it just quietly answers about fewer frames.

★ **A ratio identical across unrelated rows is a property of the divisor.** That is
the same tell as claude.md's energy readout that was 17328 J at every controller gain.
Fixed by staying inside the ring; the comment in `profileStages` names both the trap
and the tell.

### F15 — the x3.0 was TWO stages wearing one name, and my fix made it worse first

`factorM` is a one-line wrapper: `factorMDamped(m, d, 0)`. The zone lived in the
callee under the fixed name `robot.factorM`, so every factorisation in the engine
reported under it — plain and damped alike — and `x3.0/step` could not tell you which
of the three to go and look at.

★ I renamed the callee's zone to `robot.factorMDamped`, which is the obvious fix and
is WRONG: it relabels every plain factorisation as damped. **The output said so
immediately — `robot.factorM` vanished from the breakdown and the damped row absorbed
all three calls. A row disappearing when you rename another row means they were always
the same row.** Same class of tell as the `x0.6` in F14 and claude.md's energy readout
that was 17328 J at every gain.

The real fix names the zone by what it did, choosing the literal at runtime;
`internSrc` keys on (file, line, NAME), so two literals at one call site intern as two
entries — precisely the case that condition exists to allow. Now:

    robot.factorM         436 ns  x2.0   8.8%
    robot.factorMDamped   423 ns  x1.0   4.3%

### F16 — 4.5% of every step is spent undoing a side effect

The second plain `factorM` is `advanceImplicit*` RESTORING `qLD` after the damped
factorisation, and the very next `forward` opens by overwriting it. Nothing in the
engine reads `qLD` in between.

It is kept, and the reason is the word "engine": a CALLER sits in that gap by design —
that is the whole point of the `step1`/`step2` split — and `solveM`/`massDiagonal` are
public. The stage watermark catches calling a stage out of ORDER; it cannot catch
reading a factorisation of the wrong MATRIX, because the stage is legitimately
`.position` either way. A controller scaling gains by `massDiagonal` between steps
would silently get damped inertias.

Documented at the call site with the measured cost, so the trade is informed: the
cheap fix is a flag on `Data` recording which matrix `qLD` holds, making the restore
lazy and the assert possible. Not done, because "nothing is lazy, nothing is cached"
is worth more than 4.5% — but it is now a KNOWN 4.5% with a known price.

### F17 — the 25.5% is TWO jobs, and only one is dual-only (found by reading MuJoCo)

`projectConstraints` does:

  (a) **M⁻¹Jᵀ per row** — PGS needs it every sweep; Newton never reads it. zimr's Newton
      is PRIMAL (nv×nv Hessian over accelerations, `solveNewton` asserts it) and returns
      before the PGS body.
  (b) **the exact Â = J M⁻¹ Jᵀ diagonal**, which becomes `R = (1−d)/d · Â` — the
      constraint softness, needed by BOTH solvers.

★ I skipped the whole call for Newton. **Four tests failed instantly**: a box stack fell to
−19.6, the MuJoCo force check read 0 against 19.62, the Go1 dropped to −78 m. R was gone,
so every constraint was infinitely soft. Reverted. The 25% is not waste.

**MuJoCo splits exactly these two**, which is where the structure was noticed and is the
shape of the real fix: `mj_diagApprox` runs always and is cheap; `mj_makeY`/`mj_makeAR`
build the full projection only `if (isDual || diagexact)`, and `mj_isDual` is true just for
`mjSOL_PGS`. Their exact diagonal is opt-in behind `mjENBL_DIAGEXACT`. Their sparse
`mj_makeY` also pre-counts row nonzeros, so it exploits the Jacobian sparsity zimr does not.

Doing the same here **changes the physics** — R moves, so contact softness moves — and must
be re-verified against the `efc_R` fixtures. Not a change to make casually. Recorded at the
call site in `forward` with the failure evidence, so the next attempt starts informed.

### F18 — SIZING THE MuJoCo SPLIT BEFORE DOING IT: it buys ~4% where it matters

`profileStages` now runs for both solvers, which is what made this answerable:

    solver   step      project        solve
    pgs      13.8 us   3697 (26.7%)   3933 (28.4%)
    newton   23.5 us   3638 (15.5%)  13734 (58.5%)

★ `mj_diagApprox` IS A TABLE LOOKUP, NOT A COMPUTATION. `body_invweight0` /
`dof_invweight0` are precomputed at model-compile time from the reference pose, and the
runtime "diagonal" adds two of them — O(1) per row, no `solveM`. That is the whole
reason MuJoCo's default is cheap, and it is also why it is an APPROXIMATION: their R is
state-INDEPENDENT, where zimr's exact Â makes R a function of the current configuration.

So the split buys:

* **Newton** — skip `project` entirely: 23.5 → ~19.9 us, a 15% win on a solver that is
  not the default and would STILL be 44% slower than PGS.
* **PGS** — must keep M⁻¹Jᵀ (the per-row `solveM`, the bulk of `project`). Only the exact
  diagonal's dot product becomes a lookup: 288 mults out of a `solveM` per row. **Roughly
  4% of a step**, on the default path.

Against that: R moves, so contact softness moves, so every `efc_R` / force / resting-depth
fixture needs re-verifying, and the exact-vs-approximate diagonal is a real physics
difference — not a refactor. **4% is not worth a physics change.** Deferred, with the
numbers, rather than declined on taste.

★ AND THE REAL TARGET IS NOW VISIBLE: **Newton's cost is `solve` at 58.5%** — 13.7 us for
a 2-iteration solve on 16 rows at nv=18. That is where Newton's gap lives, and nobody had
looked because `project` was the number in front of us. If MPC pushes toward Newton (it
may: PGS not reaching tolerance, F8, matters more inside a derivative loop), that is the
thing to read.

★ ONE MPC-SPECIFIC NOTE ON THE APPROXIMATE DIAGONAL, for whenever this is revisited: a
state-independent R removes one path by which state affects the step, which makes
finite-difference derivatives BETTER conditioned, not worse. That is a genuine argument
for the split that has nothing to do with speed — and it should be made on those grounds,
measured on derivative quality, rather than smuggled in as an optimisation.

## MPC readiness — what is already there

Assessed because MPC is the next destination. Present and tested:

* `State.save`/`restore` with a determinism test — replay from a snapshot is bit-exact.
* `step1`/`step2` split, with a test that the split equals the whole. This is where a
  controller injects, and it is exactly the hook MPC wants.
* `SolverOptions.warm_start = false`, which exists specifically so a differential rollout
  gets a solve depending on nothing but the current state. Warm starting across perturbed
  rollouts would otherwise make finite differences lie.
* `Data` is flat and pointer-free, sized from the model, explicitly so many instances can
  be sliced for batched rollouts.
* `observe`/`observationSize` for a flat state+sensor vector.

**~~Missing: derivatives.~~ WRONG — the code already existed**, ~790 lines with six tests, and
I had written it MYSELF earlier in the session and forgotten. I then compounded the error by
inferring from mtimes that "another surface" was working the container, and built a whole
story on it — including advising Simon to split work by file. There was no other surface.
Nobody else works here.

★ THE LESSON IS NOT "CHECK MTIMES BETTER". It is that an unexplained artefact should raise
"what did I do that I do not remember" before "who else is here" — the first is common and the
second, in this setup, is impossible. Now merged into `robot_mpc.zig` with everything else.

It is good, and independently verified here: `transition()` computes all four of A, B, C, D;
`ndx = 2·nv + na` throughout; nudging via `integratePos`, differencing via
`differentiatePos`; `warm_start` forced off and restored. Its `defaultEps` is DERIVED for
f32 rather than inherited — `sqrt(1.19e-7) ≈ 3.4e-4` forward, `cbrt ≈ 4.9e-3` centered —
and pinned by a sweep test that requires the error curve to be U-shaped and the default to
beat MuJoCo's 1e-6, which sits in the sweep specifically to fail anyone "aligning with
MuJoCo" by copying it.

### F19 — `State` was not a complete snapshot — FIXED AND PINNED

It saved `warm_force` without `warm_key`/`warm_count`. Warm starting matches rows by KEY —
rows are rebuilt every step and reorder as constraints come and go — so a restore handed
the solver the snapshot's forces under whatever labels the last step left. Right array,
wrong labels.

★ The existing replay test passes either way, because it restores into a Data whose contact
set never changed, so the stale keys are accidentally the correct ones. The new test makes
the contact IDENTITY change while the count stays the same, which is the actual shape of
the bug: nothing about the sizes is wrong, only the labels.

### F20 — a step with NO constraints leaves `warm_count` stale — found, NOT fixed

`solveConstraints` early-returns when `constraint_count == 0`. It resets `solver_iterations`
there (with a comment explaining exactly why a stale diagnostic is harmful) and does NOT
reset `warm_count`/`warm_key`. So a ball that leaves the ground and returns warm-starts its
new contact from the force it carried before the flight.

Arguably a feature, arguably a bug — a bouncing contact re-acquiring its old force may
converge faster or may inject a stale impulse — and it is a physics-affecting change either
way. Recorded rather than changed at the end of a session. It is why the test above uses a
changed contact ID rather than an emptied contact set.

### F21 — iLQR landed. Three bugs, each disguised as something else.

`src/robot_mpc.zig` — cost model, backward Riccati pass, line-searched forward pass. Both
tests pass; wired into `src/tests.zig`. The LQR test reproduces an independent Riccati
recursion to **0.1%**, fed the SAME A and B out of `plan.scratch` so it isolates the
recursion from the differencing.

1. **Aliasing.** `Q_xx` finished IN PLACE over `V_xx·A`; the multiply consumed rows it had
   already overwritten. 5.5% → 1.5%.
2. **`l_x` missing from `Q_x`.** Leaves `K` correct and silently breaks the FEEDFORWARD —
   a planner converging to the wrong trajectory with every gain right.
3. **Regularization leaking into kept gains.** At the optimum every line search fails, so
   regularization climbed 10x/iteration and `plan.feedback` held a damped exploratory pass —
   gains half size. Fixed by using the backward pass's PREDICTED improvement to tell
   "already optimal" from "model is bad"; they are identical from the line search alone.

★ AND TWO OF MY OWN TEST ASSERTIONS WERE THE BUG, NOT THE CODE. A paper oracle for `B` that
had no business being in an MPC file (cost two rounds pointing at the wrong file), and
`|final position| < 0.1` — a number I wanted to be true. A tolerance sweep settled it:

    tol 1e-4:  cost 27.3582   2 iters   final q 0.20190
    tol 1e-6:  cost 27.3546  14 iters   final q 0.19843
    tol 1e-9:  cost 27.3502  60 iters   final q 0.19449

Five orders of magnitude buys 0.03%. It had converged; **0.195 is the optimum**. The test
now asserts the sweep — a tighter tolerance must not move the answer — which tests the
claim instead of pinning an endpoint nobody derived.

### F22 — f32 caps finite-difference derivatives, and it is not a bug

`B = ∂x′/∂u` on a LINEAR cart, where B is exactly constant:

    q=0.0  v=0.0   B = [4.95050e-5, 4.95050e-3]   correct
    q=1.0  v=0.0   B = [0.00000e0,  4.95050e-3]   top entry GONE
    ctrl=5.0       B = [3.45267e-4, 4.94703e-3]   7x too large

A control nudge moves `q′` by `h²·eps/M ≈ 1.7e-8`; f32 resolves ~1.2e-7 near `q′ ≈ 1`. The
signal is below the last bit of the number it is added to. **No epsilon fixes this** —
clearing the noise floor puts truncation error back. This is why MuJoCo is f64, and it
retroactively explains the "paper B is 3.5x off" I wrongly blamed on armature.

Planning from `q = 1` still works (the velocity row is clean, position integrates from it),
but `∂q′/∂u` is unreliable far from the origin. Options, cheapest first: per-block epsilon
scaled by `|q|`; an f64 state path for the derivative only; or analytic/autodiff
derivatives — which is where the libtorch work goes anyway and sidesteps it entirely.

### F23 — MEASURED BEFORE BUILDING: cartpole derivatives are noise across a swing-up

Self-consistency test (no analytic oracle for a cartpole): compute `B` at five states with
eps over {1e-5, 1e-4, 3.4e-4, 1e-3, 1e-2} and report the relative spread. A real derivative
barely moves; noise swings.

    state                          B[0] dx'/du   B[1] dth'/du   B[2] dvx'/du  B[3] dvth'/du
    x=0.0 th=0.00  at rest              ok             ok             ok            ok
    x=0.0 th=3.14  at rest (START)      ok          NOISE 1.70        ok            ok
    x=0.5 th=2.00  moving            NOISE 1.13     NOISE 1.00     SHAKY 0.09    SHAKY 0.14
    x=1.5 th=1.00  moving fast       NOISE 1.70     NOISE 1.03     SHAKY 0.14    SHAKY 0.35
    x=0.0 th=0.10  near upright           ok        SHAKY 0.06        ok            ok

★ THE PATTERN IS VELOCITY, NOT POSITION. Every clean row is a zero-velocity state. Once the
robot moves, `q' = q + h·v'` is dominated by `h·v` (~0.03) while the control contributes
`h²·gear·eps/M` (~2e-7) — and f32 resolves ~2.4e-7 near `th = 2.0`. Same mechanism as F22,
but the magnitude that kills it is the VELOCITY term, not the position.

**So the derivatives are reliable exactly where a swing-up does not happen and unreliable
exactly where it does.** Balancing near upright is fine; the swing itself is not.

★ AND ONE TEMPTING FIX DOES NOT WORK: differencing `q' − q` instead of `q'` looks like it
should dodge the cancellation, and does not — the information is destroyed inside `step`
when `q + h·v'` rounds away the control's contribution, before any subtraction happens.
Real options are an f64 state path for the differencing, or analytic derivatives.

### F24 — the cartpole model already declares control limits

`examples/cartpole/cartpole.zig` has `.ctrl_range = .{ -1, 1 }` with `.gear = 6`. The
actuator clamps in `actuation`, so an UNCONSTRAINED plan asks for torques the robot will
never apply and then reports the resulting trajectory as achievable. A swing-up is *defined*
by the motor being too weak to lift directly; without box constraints iLQR solves a
different, easier problem and the plan is a lie. Box-QP on `Q_uu` (MuJoCo's `boxQP`) is
self-contained in `solveGains` and does not depend on F23.

### F25 — THE f32 DERIVATIVE PROBLEM IS FIXED, without f64 and without autodiff

Every supported integrator ends with `q′ = integratePos(q, v′, h)`, so a control reaches
position ONLY through velocity: **∂q′/∂u = h · ∂v′/∂u**. Differencing it directly asks f32
to see ~2e-7 inside a `q′` of order 1; differencing the VELOCITY row puts the same signal
against a much smaller number, where it survives. So take the good rows and multiply by `h`.

Verified before being trusted, where the differencing is reliable — differenced `∂q′/∂u`
against `h·∂v′/∂u`, worst relative disagreement:

    two-hinge arm, at rest      6.6e-8
    two-hinge arm, ω = 1        4.7e-5
    two-hinge arm, ω = 5        2.1e-4

Cartpole position-row spread across five epsilons, before → after:

    upright at rest       0.0000  ok     →  0.0000  ok
    hanging at rest       1.7000  NOISE  →  0.0000  ok
    mid-swing moving      1.1333  NOISE  →  0.1420  SHAKY
    moving fast           1.7000  NOISE  →  0.3462  SHAKY
    near upright          0.0638  SHAKY  →  0.0013  ok

**Every NOISE row is gone.** All 121 derivative-file tests still pass, including its own
oracle tests. `Options.position_rows_from_integrator`, default true.

★★ AND IT IS `B` ONLY — THE SAME TRICK ON `A` IS WRONG, which is worth more than the fix.
`∂q′/∂q` is NOT `I + h·∂v′/∂q`: `integratePos` depends on `q` directly as well as through
`v′`, and for a quaternion that direct path is the exponential map's adjoint rather than the
identity. Measured on a free body at ω = 1, the "prediction" was off by a factor of **1.3e4**
— while the same prediction is exact at ω = 0, so a test at rest would have blessed it.
Applying this to `A` for symmetry is the kind of tidiness that produces a silent catastrophe
on exactly the model class nobody checks by eye.

### F25 — control limits landed: box-QP, wired, and the active set exposed

`boxQP` — projected Newton, built and tested IN ISOLATION first (the lesson from F21's
debugging), against four hand-computed answers. The third is the one that matters: with a
COUPLED Hessian, clamp-after-solve gives `y = 1.0` where the correct answer is `y = 1.3` —
the free actuator must work harder to cover the saturated one. A one-actuator test cannot
see this, and a cartpole is a one-actuator test.

Wired into the backward pass: `k` solved inside the box, feedback solved on the FREE block
only, and the forward pass clamps too (the backward pass keeps `k` in the box, but
`α·k + K·δx` can still leave it).

★ AND ONE ASSERTION OF MINE WAS WRONG IN AN INSTRUCTIVE WAY. I asserted "feedback is zero
wherever `|u|` sits on the bound" — measured, the gain there was −10.1. **A control at its
upper limit still has authority to come back DOWN**; it is pinned only when the gradient
pushes it further out. That is a different set from "at the bound", and it is the solver's
own `clamped` set. Now exposed as `Plan.clamped`, which an MPC caller wants anyway: it says
which actuators have no headroom in the direction the plan wants to go.

★ AND ANOTHER TEST OF MINE ASKED FOR THE IMPOSSIBLE. First version: gear 1, cap ±0.3, 0.4 s
horizon, cart 2 m out. It "failed" — correctly. Force 0.3 on inertia 2.02 is a = 0.148 m/s²,
which covers 1.2 cm in 0.4 s. No plan moves further because none exists. Resized FROM THE
DYNAMICS (gear 20 → a ≈ 2.97, 1 m needs ≈ 0.82 s, horizon 1.2 s leaves room to arrive and
decelerate) and it converges: cost 110 → 27.8 in 23 iterations, final position 0.033.

### F26 — three identical timeouts were mine, not the build's

`zig build test` compiles `src/tests.zig` and its imports as ONE unit with no mid-compile
checkpoint. Kill it at 170 s and the next run restarts from zero — so once that unit crosses
the tool timeout it is **unfinishable by retrying**. It had been 157 s, then 163 s; ~600 new
lines pushed it to ~335 s.

The tell was an EMPTY log every time: a build making progress prints. Detaching with
`nohup setsid` finished it in one pass, after which the ordinary command returns in ~1 s.
Recorded in claude.md with the recipe and the rule: **two identical timeouts mean stop and
measure, not retry.**

### F27 — THE CARTPOLE SWINGS ITSELF UP

Verified end to end, from theta = 3.0, motor capped at ±1 with gear 6:

    t=0.00  th 3.000  x  0.000  vth  0.000   pump one way
    t=0.50  th 3.971  x -0.548  vth  1.022
    t=1.00  th 3.083  x -1.937  vth -4.656   back through the bottom
    t=1.25  th 1.778  x -2.374  vth -7.592   fastest point
    t=1.50  th 0.471  x -2.354  vth -4.175   arriving
    t=2.50  th 0.023  x -1.291  vth -0.106   upright, at rest (1.3 deg)

Passed horizontal, saturated 77/250 knots, converged in 142 iterations. It also converges
from EXACTLY pi (theta_end 0.206) — my prediction that the zero gradient there would block
it was wrong: only the FIRST knot has zero sensitivity, and later knots carry the gradient.

★ THE DERIVATIVE NOISE COST ITERATIONS, NOT CORRECTNESS — which is what was predicted in
advance and is the reason the attempt was worth making before doing anything architectural
about f32.

★ ONE THING TO WATCH: the plan drives the cart to |x| = 2.430 against a rail declared at
2.4. Joint limits are SOFT constraints, so 3 cm of violation is the constraint working as
specified — but a planner will lean on that softness, because nothing in the cost stops it.
If a plan must respect a hard limit, the limit belongs in the cost, not only in the model.

### F28 — two swing-up tests, two copies of the fixture: merged

The other surface added a swing-up in parallel with mine. Theirs was better where it counts
— starts from exactly pi, asserts a tighter final angle, and records a genuinely valuable
finding: **ReleaseFast and ReleaseSafe land in DIFFERENT LOCAL OPTIMA** (final x −0.026 vs
−2.403, both upright and at rest). Swing-up is non-convex, float contraction differs by
parts in 1e7 between build modes, and that is enough to send the line search into a
different basin. Their test therefore asserts the TASK, not which valid solution was found —
pinning the cart position would be pinning the build mode.

Deleted my duplicate test and my duplicate `SwingCartpole` fixture; folded my distinctive
checks into theirs (the torque-budget arithmetic showing the motor is short by ~1.8x,
passed-horizontal, peak angular speed, saturation count). One test, 29 s, one fixture.

### F29 — receding horizon works, and a tick costs 2% of a frame

`shift` (slide the plan one knot, duplicating the last) + `feedbackControl` (`u₀ + K₀·δx`
in the tangent space). Closed loop tested: pole disturbed 0.25 rad and falling at 0.8 rad/s,
caught and held for 2 s on a budget of TWO iterations per tick.

Measured cost of one full tick (shift + optimize + feedbackControl + step), ReleaseFast:

    horizon  budget   cold_ms   tick_us   final_theta
       40      2         1.2       254       -0.004
       60      1         2.8       206       -0.003
       60      2         2.9       354       -0.003
      100      2         2.8       346       -7.348   <-- DIVERGED
      150      2        31.9       829        0.006

★ A 60 Hz frame is 16 667 us, so a horizon-60 tick at 354 us is **2% of a frame**. Even at
100 Hz physics (1.67 ticks per frame) it is under 4%. Interactivity is not in question for
balancing.

★ BUT THE COLD SOLVE IS NOT FREE: 32 ms at horizon 150 would drop a frame outright, and the
swing-up needs a longer horizon still. An interactive demo must BUDGET the cold solve across
frames rather than run it in one — which also makes a better demo, since the plan visibly
converges.

★ AND HORIZON 100 DIVERGED where both 60 and 150 succeeded, identically at budgets 1, 2 and
5 — so it is deterministic, not a budget starvation. Non-convexity again: a cold solve that
lands in a poor basin, followed by warm re-solves that faithfully track it downhill. Worth
knowing before anyone assumes longer horizon = more robust.

## Next: MPC proper

The derivative layer is done and verified. What iLQG/DDP needs on top of it: a rollout
buffer over a horizon, a quadratic cost model, the backward Riccati pass, and a line search
on the forward pass. None of it needs new physics.

## Still to do

- the zimrphysics seam: double-counting, `moveKinematic`, the upgrade ladder
- `projectConstraints` at 25.5% — the one big cost nobody has read yet. `solveM` is
  already sparsity-aware via the tree structure of M, but the per-row memcpy, the
  D-inverse pass and the final dot product are all dense over nv. A contact row's
  Jacobian is non-zero only on the path from the contact body to the root: for a Go1
  foot that is roughly half of nv=18. Worth measuring the actual density before
  assuming it is exploitable.)
- ~~§21/§22/§26 are thin~~ — **I WAS WRONG, and byte count was the wrong metric.**
  Read them: each is dense, measured, and carries a "wrong intuition corrected by
  measurement" note (implicit is NOT the integrator for a fast tumbler; IK will
  happily put a forearm through a table). They are SHORT because they report
  measurements on concepts already built, where §2 derives spatial algebra from
  nothing. Judging a section by its size is the same class of error as
  `checkCacheSize` measuring a proxy instead of the hazard.
- What §21 DID need, and now has: the measured fact that PGS never reaches
  tolerance on the Go1. The section's whole job is "when is each solver right"
  and it claimed the two give "the same answer" — same physics, different
  precision, and `constraintConverged` is false every step under the default.
- §27 omitted the seam's double-counting approximation AND its escape hatch
  (put the object in the robot's own tree; momentum conserved by construction,
  and there is a test named for it). Both added.
- `robot_port_plan.md` P5 promised a `robot.zUpToYUp()` helper. It appears
  nowhere in the tree. Corrected to describe what actually happened: robot.zig
  is axis-agnostic, so no helper was needed.
