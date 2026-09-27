# ★ NAME THINGS SO THE CODE READS WITHOUT THE COMMENT

Standing style rule for this project. Prefer:

  * **Verbose names over short ones.** `target_joint`/`source_of_target`/`bone_length`, not
    `t`/`map`/`len`. A loop index in a 40-line body is not "obvious from context".
  * **An intermediate named constant over a clever expression.** `const bone_is_long_enough:
    bool = bone_length >= opts.min_bone_length;` then `if (bone_is_long_enough)`. The name IS
    the explanation, and unlike a comment it cannot drift from the condition.
  * **A named boolean for every non-trivial `if`.** `joint_is_root`, `has_matching_source`,
    `names_match`, `slices_agree`.
  * **Out-parameters prefixed `out_`**, so a signature says which way data flows.

★ The test: could a reader who skipped the doc comment still follow the body? If the answer
depends on the comment, rename until it does not.

# ★★★ CHECK WHETHER THE REFERENCE ALREADY SOLVED IT

Retargeting to a robot cost eleven candidate formulas, four device rounds and a correction
applied on the wrong side of the delta. **`FlomoGMR/scripts/flomo_to_geno_bvh.py` contained the
answer the whole time**, in `compute_twist_offsets()`, with a docstring describing the exact
symptom ("leaves Geno's arm pointing up — a ~90 degree error").

★ I had read `motion_retarget.py` and the ik_configs three times and never listed `scripts/`.

★★ Before deriving anything in a ported system: **grep the reference for the SYMPTOM, not just
for the feature name.** The file was not called "twist" or "retarget offsets"; its docstring
was.

# ★★★ MEASURE THE LINK YOU CHANGED, NOT THE END OF THE CHAIN

Retargeting an arm: a single FOREARM agreement number ranked three candidate formulas and got
them BACKWARDS. The forearm sits below both the shoulder AND the elbow, so its error blends a
formula error with a bend error.

★ Split by bone and the truth appeared instantly: the candidate that looked WORST (-0.196 on the
forearm) had the shoulder at **+0.916** — nearly right — and was failing for an unrelated
reason.

★★ A summary number over a chain measures the whole chain. **Measure the bone the change
controls**, then the next one down, and the first bad link is where the two diverge.

# ★★★ RETARGETING: COPY ANGLES, NEVER LENGTHS

A robot's bone lengths and joint offsets are FIXED by its model. Asking it to match a human's
joint POSITIONS asks for lengths it does not have — and a solver answers by bending limbs that
should be straight, or curling a leg short of its foot.

★ The same principle fixed three separate problems in one arc:

    shoulder   torso-to-shoulder offset is fixed  -> solve the torso's POSITION
    elbow      the upper arm's length is fixed    -> solve its DIRECTION
    T-pose     every bone length is fixed         -> take only DIRECTIONS from the source

★★ **Take the direction from the source and the magnitude from the model.** Identify what the
model fixes, then solve only for what is free.

# ★★★ DRAW THE TWO THINGS YOU ARE COMPARING, BEFORE COMPARING THEM

Retargeting spent many turns building twist offsets between `humanoid.xml`'s rest pose and
Geno's T-pose. **The robot's `qpos0` is not a T-pose at all** — its arms fold up into a
triangle. One drawing of the two poses side by side settled it instantly.

★★ Worse: a scalar check had "confirmed" it WAS a T-pose (hand at the same height as the upper
arm). **A folded arm satisfies that too.** A carefully chosen number can be consistent with the
wrong picture; a picture cannot.

★ Before deriving anything from two poses, two skeletons or two coordinate frames: **draw them,
superimposed, with axis triads.** It is cheaper than any of the algebra that follows and it
catches the class of error the algebra cannot.

# ★★★ A SHORTEST ARC LEAVES TWIST FREE — so a bone parallel to the missing axis encodes nothing

Aligning direction A onto direction B constrains TWO of three rotational degrees of freedom. The
third — rotation ABOUT the aligned direction — is free by construction.

★ Cost in the retarget arc: the torso's reference bone was `torso -> head` (VERTICAL), so its
twist could not encode YAW, and the shoulders hanging off it at fixed offsets came out a quarter
turn wrong. The facing correction had been removed on the grounds that per-bone twists subsumed
it — true for every bone EXCEPT one parallel to the axis in question.

★★ When a direction-alignment leaves something visibly wrong, ask first: **is the error about
the axis I aligned?** If so, no amount of better alignment fixes it — pick a reference bone
PERPENDICULAR to that axis, or constrain the twist explicitly.

# ★★★ A TARGET IS NOT A POSE

Retargeting to a robot: several rounds were spent A/B-testing orientation formulas that reached
exactly ONE body. **A robot body has no writable orientation** — everything below the free root
poses only through joint angles, so building a target and stopping there leaves the body at
`qpos0` unless a SOLVER consumes it.

★ The experiments compared formulas none of which could move fifteen of the sixteen bodies. The
one that "worked" was the root, which is written directly.

★★ Ask of any A/B: **can the thing I am varying actually reach the thing I am looking at?** If
turning the knob all the way to an absurd value would not change the picture, the experiment is
not running.

# ★★★ EVERYTHING WRONG IN THE SAME WAY = ONE GLOBAL ERROR, NOT MANY LOCAL ONES

Retargeting to `humanoid.xml` burned many rounds on per-joint frame algebra — T-pose
references, bone-direction frames, axis-correspondence conjugation. **The actual fix was a
single 90-degree yaw**: the two skeletons simply FACE different directions.

★★ A per-joint framework CANNOT EXPRESS A GLOBAL CONSTANT, so the search never included "one
number for all of them". Every formula was repaired against a symptom that one yaw removed.

★ The tell was visible the whole time: the robot was wrong THE SAME WAY on every bone. That is
the signature of a global error. Accumulated local errors look DIFFERENT per bone — worse
further down a chain, fine near the root.

★ Ask early: is this wrong differently in different places, or identically everywhere?

# ★★★ A SELF-REFERENTIAL CHECK IS NOT A CHECK

Shipped twice in one session, both reading a perfect 0.0000 while proving nothing:

    qmul(q, conj(q))    identity for ANY q
    qmul(c, conj(c))    identity for ANY c

★ `f(x, conj(x))`, `x - x`, `a == a` and friends report what ALGEBRA guarantees, not what the
code does. **A check must involve a value the code under test did not produce** — a measurement,
a second implementation, a hand-computed constant, or an external invariant like "the figure
ends up standing".

★ The tell: a check that passes the instant it is written, on the first run, on broken code.

# ★★★ RETARGETING: TWO REFERENCE POSES MUST MATCH IN *KIND*, NOT JUST IN POSE

A rest alignment (`conj(source_ref) * target_ref`) is only meaningful when both references
answer the SAME QUESTION about the SAME physical pose. This arc violated it THREE times, each
time in a new disguise:

  1. **real vs inferred** — an FBX's cluster `TransformLink` (real) against a frame derived
     from bone directions (inferred). Broke hands and feet.
  2. **A-pose vs T-pose** — Geno's bind is an A-pose, Mixamo's a T-pose. Drooped every arm 45
     degrees.
  3. **body frame vs bone direction** — `humanoid.xml` has NO body rotations, so its
     `qpos0` orientations are identity and carry no direction; its bones live in POSITION
     OFFSETS. Compared against a human T-pose's rotations, every robot bone came out turned.

★ Before trusting any alignment, ask of BOTH sides: *what exactly does this quaternion measure,
and is the other side measuring the same thing?* "Both are rest poses" is not enough.

# ★★★ "MAKE A PLAN" MEANS THIS EXACT PROCEDURE

When Simon asks for a plan, it is a specific procedure, not a sketch in the chat:

  1. **Study deeply.** Read the code, the notes, the references and the prior art before
     proposing anything. "Check whether the reference already solved it", "grep before
     designing" and "read the solver before planning work on it" all apply here.
  2. **Brainstorm every possible solution**, including the ones you expect to reject.
  3. **Pick your preferred choices**, and say why.
  4. **Write a detailed plan as a `.md` file in `src/notes/`.** The file is the deliverable,
     not the chat reply.
  5. **Ask the open decisions ONE AT A TIME.** Each question gives the choices, the pros and
     cons of each, and your recommendation. Wait for the answer before asking the next one.
  6. **Revise the plan after each decision**, then list every decision back and get Simon's
     explicit agreement with all of them before calling the plan final.

★★ **Do not implement until Simon gives permission.** A finished plan with every question
answered and every decision confirmed is still not permission to start. Neither is `C`: it
resumes a plan that is already approved, never one still under review.

# ★ "C" MEANS CONTINUE

A message that is just `C` (or `c`) means: **carry on with the current plan, no questions.**
Pick up the next unfinished stage of whatever plan is ACTIVE in "Current plan" below, build it,
verify it, ship a snapshot. No need to re-confirm what to work on. **If nothing is ACTIVE, ask
which plan to resume** — do not pick one.

# ★ WHEN THE DISK GUARD FIRES, CLEAR THE WHOLE CACHE

`.zig-cache` reached 8.5 GB and the guard refused to build — working as designed. **Do not
delete `.zig-cache/o` selectively: the configurer lives there**, and removing it gives
`configuration failed: FileNotFound`. `rm -rf .zig-cache` and take the cold rebuild.

# ★★★ IDENTICAL OUTPUT MEANS THE CHANGE DID NOT HAPPEN

A scripted edit whose anchor did not match left the file untouched — `str.replace` returns the
input unchanged and raises nothing. The test then produced numbers IDENTICAL TO THE DECIMAL, and
I wrote a paragraph explaining why the change had not helped.

★★ **A real change to a kinematic chain, a shader, or a solver MOVES SOMETHING.** Bitwise
identical output across a supposed algorithm change means the algorithm did not change.

★ After any anchored edit: **grep for the text just inserted.** One line, and it catches every
silent no-op — of which this session had several, each invisible for exactly as long as nobody
looked.

# ★★★ A STRONG ARGUMENT FOR DELETING CODE IS STILL NOT A MEASUREMENT

The retarget had two mechanisms doing one job. Every rest-pose bug in the arc — six classes —
belonged to the complex one; the simple one was structurally immune. **The plan said delete it.**

★ Measured with everything else identical: **the complex one wins five stages of seven and the
total**, the legs by more than double.

★★ "The simpler mechanism wins ties" is a good rule and this was not a tie. **Deleting would
have traded a present, measured capability for the absence of PAST problems** — the bugs were
already fixed.

★ Wire both behind one flag and let the harness run both every time; then the comparison cannot
rot and the choice stays evidence-based.

# ★★★ BEFORE EXPLAINING A RESIDUAL, MEASURE THE BEST THE MECHANISM COULD DO

A constant 13-degree foot error survived FOUR hypotheses — a rest offset, a pose mismatch, an
unaimed leaf, a geom convention — each plausible, each measured, each wrong.

★ The fifth attempt brute-forced the ankle's two joints over their ranges and asked what the sole
could reach at all: **within 1.2-4.7 degrees.** The solve was leaving 8-12 degrees unclaimed. The
model was never the constraint.

★★ Twenty lines, one run, and it invalidated four turns of increasingly elaborate theory.
**"Is it there to find?" comes before "why did the solver not find it?"**

# ★★★ ZERO IS NOT STRAIGHT — a joint coordinate is measured from the MODEL'S REST, not from zero

`humanoid.xml`'s elbow rests BENT AT 109.5 DEGREES (its arms fold into a triangle at `qpos0`).
Measured on a bare model: **`bend = rest_bend + qpos`, exactly.** Writing a wanted flexion of
90.9 into the coordinate produced 18.6 degrees of actual bend.

★ Every flexion heuristic in the retarget arc assumed zero meant straight, and four turns went
into geometric explanations — cone relations, wrong bones, wrong joint indices — **all of which
were eliminated by measurement before the real cause was found.**

★★ `qpos = wanted - rest`, with `rest` measured once from `qpos0`. And more generally: **a
joint coordinate is an offset from the model's rest configuration, never an absolute angle.**

# ★★★ A JOINT COORDINATE IS NOT A POSE MEASUREMENT

`humanoid.xml`'s elbow has `axis="0 -1 1"` against a forearm at `(.18,-.18,-.18)`. **Writing
-90.9 degrees into that hinge produces 18.6 degrees of actual bend.**

★ Rotating a bone about an axis it is not perpendicular to sweeps it around a CONE:

    cos(flexion) = cos²γ + sin²γ·cos(qpos)      γ = angle(axis, bone)
    maximum bend  φ_max = 2γ

★★ Every heuristic in the retarget arc assumed `qpos == flexion`. **True for a textbook hinge,
silently false for a real robot's** — and it cost several turns of chasing a constant hand error.

★ Before treating any joint coordinate as an angle between bones, check the axis against the
bone it moves.

# ★★★ A CHANGE JUDGED ON QUANTITIES IT WAS NOT AIMED AT HAS NOT BEEN JUDGED

A shoulder-axis constraint was called "measured worse" on arm error, leg error and a whole-body
pop maximum. **The change was about the TORSO, which nothing measured.** Measured properly it
improves the torso axis 18% at a weight 20x smaller than the one first tried.

★★ **A metric suite grows around the bugs you have already found, and its blind spots are exactly
where the next ones live.** Six instruments, and none measured the first thing the project solved.

★ Also: **a constraint that dominates is a different constraint from the one intended.** Sweep the
weight downward before concluding the idea is wrong.

# ★★★ MEASURE WHERE THE CODE RUNS, NOT IN A SECOND IMPLEMENTATION

The retarget's instruments all lived in a headless harness reading BVH, while the capture under
test was FBX and lived only in the example. The obvious fix — teach the harness FBX — would have
required duplicating the FBX-to-skeleton conversion, **which is the exact failure that cost this
project five separate bugs** (a harness computing the same thing a second way, drifting silently).

★★ Chosen instead: put three numbers in the app's own UI, read from the state the shipped code
already produced. **Nothing to drift from**, and they cover the failure classes that actually
cost turns — unresolved mapping, stale cache, wrong world position.

# ★★★ A MEASUREMENT OF AN ADJACENT QUANTITY IS WORTH NOTHING

Worse: it reads exactly like a measurement of the right one. A criterion was gated on "do the two
rest frames agree", built from a printout showing `head 0.0 deg` — but the printout measured
`body_xrot` at `qpos0` while the criterion consumed the SOLVED rest pose. **Different
orientations.** The head passed the measurement and failed the check.

★★ Before trusting a number, name the exact quantity the code will consume and confirm the number
is OF that quantity. **Two other failures in the same session had the same shape**: a foot pitch
measured on a skeletal line and applied to a sole, and a frame-disagreement diagnosis that
explained the head while being true only of the hands.

# ★★★ A TEST THAT SANITISES ITS OWN INPUT IS TESTING THE SANITISER

A test asserted that the retarget's match table resolves against a Mixamo skeleton. It PASSED
while the shipped example FAILED on the same table and the same capture — because the test's
joint list had been extracted with a regex that stripped the `mixamorig:` prefix, and the real
loader does not.

★★ **Feed a test the bytes the program will actually see.** Any cleanup between the source and
the test is a difference the test cannot see, and this one hid a total failure: not one row
matched, and the example's response was to hide the robot.

# ★★★ A WORKAROUND OUTLIVES THE PROBLEM IT WAS BUILT FOR

The retarget built targets from the robot's OWN bone lengths because its arms were 25% too long
and no world-position target was reachable. **A later model fix made the proportions match
(0.99-1.03) — and nothing re-asked whether the workaround was still needed.** It was not; it was
actively harmful, leaving the figure 10 cm out of place.

★★ **Re-test every compensation when the thing it compensates for is fixed.**

★ Also: when a result is wrong, SPLIT the error before explaining it. "solve-miss 0.019 against
target-off 0.032" said in ONE run that the solver was fine and the targets were wrong. A sum
could not have.

# ★★★ ANGLE METRICS ARE BLIND TO TRANSLATION

Nine metrics in the retarget — torso axis, arm, forearm, thigh, shin, sole tilt, pops,
best-possible, jitter — **are all ANGLES.** Shift the whole robot a metre sideways and not one
changes by a degree. The whole figure was 10 cm out of place for many turns and only a screenshot
could see it.

★★ **A metric suite grows around the bugs you have already found.** If every instrument measures
the same KIND of thing, an entire class of error is invisible no matter how many you add.

★ Cheap fix: one position metric alongside the angles.

# ★★★ A SILENT CLAMP IS A SILENT BUG

`s.robot_tasks` was allocated PER BODY (17) while the point-cloud solve produced 43 samples, and
`@min(count, tasks.len)` truncated it. **Two thirds of the robot had no targets and stood in its
rest pose for a whole take** — with no crash, no warning, and plausible-looking output.

★★ Five variants of this now: a vacuous rest check, a phantom edit, a duplicated loop, identity
twists in a test, a body-sized task array. **`@min` against a capacity, `orelse continue`,
`catch return` — each turns "this does not fit" into "this is fine".**

★ When a whole subsystem does nothing, look for where its inputs were silently dropped BEFORE
looking for a bug in its mathematics.

# ★★★ THE SAMPLE RULE: THREE NON-COLLINEAR POINTS, AND THE DOF TO USE THEM

    a body needs THREE NON-COLLINEAR SAMPLES to be fully oriented
    and the DOF to use them — from its own joints OR FROM ANY ANCESTOR

★★ Both clauses were learned by being wrong. **Every weak bone in the retarget was a bone with
too few samples** — the forearm had two COLLINEAR ones (7.9-28.3 deg), a foot had ONE (free to be
33 deg), the thigh had three (1.6-4.2). And asking "what can this JOINT do?" gave the wrong
answer for a foot: its roll is unreachable at the ankle and reachable through the leg.

★★★ **The rule predicts which bones will be weak and what to add, from the model alone.**

# ★★★ MATCH POINTS, NOT CONCEPTS — see `src/notes/retarget_formulation.md`

Six mechanisms were built to carry position, direction, twist, bend plane and swivel between two
skeletons. **All five are special cases of "match some points on the bodies":** one point gives
position, two give direction, three give twist. No rest-pose algebra, no conversion, no seams.

★ One Gauss-Newton solve over ALL dof with 31 point residuals, soft limit barriers and a posture
term matched six hand-tuned mechanisms on the first attempt and beat them on the worst frame.

★★ **A hard joint limit is a CLIFF** — clamping removes a direction from the solve, so the
configuration sticks to walls and jumps between them. A barrier makes it a slope: the solver feels
it early, slides along it, and can back out. **Measured: worst single-frame pop 155 -> 67 deg**,
where warm-starting moved it only to 148 and step-scaling not at all. **Continuity is a property
of the OBJECTIVE, not of the search.**

# ★★★ RETARGET: READ `src/notes/retarget_tutorial.html` FIRST

The complete account — problem, math, what GMR does, our code, its mistakes, the numbers, the
lessons, the revised plan. Written after ~120 iterations. `retarget_recipe.md` is the running
log it was distilled from.

# ★★★ RETARGET: READ `src/notes/retarget_recipe.md` SECOND

It states what works, the ONE structural problem (two mechanisms doing one job), the three-step
recipe worth aiming for, and a plan that decides between them BY MEASUREMENT. Read it before
touching the retarget.

# ★★★ NEXT UP: `src/notes/twist_port_plan.md`

The retarget's remaining work is a faithful PORT of FlomoGMR's `compute_twist_offsets`, whose
math is worked out there in full. **Do not re-derive it** — this arc already spent eleven
candidate formulas and four device rounds failing to.

# ★★★ RETARGET PLAN (PAUSED — the active plan is `zimrnum_plan.md`): `src/notes/retarget_plan.md`

Read that first. **Success is 6 clips: 2 animations x 3 targets** — dance1 and Drop_Kick, onto
Geno, the Mixamo character, and `humanoid.xml`. Two of the six already work (each animation on
its own skeleton, in `geno_dance`), so the job is four: two name/topology remaps and two IK
retargets onto the robot.

It ports FlomoGMR's retargeting into zimr. Every claim in the plan about our own code is cited
with a `src/robot.zig` line number — the Jacobian is an assembly step over `cdof`, not new
physics — and every claim about the skeletons was measured from the files, not assumed.

★ **DECIDED: the interchange type is the POSE** (world position + orientation per joint), not
`qpos`. Storage stays target-specific — a character's pose is its state, a robot's is derived
from `qpos`. Unifying on `qpos` would have made Geno ~231 DOF against `humanoid.xml`'s 27 and
turned an exact index-matched copy into an iterative solve.

★ **DECIDED: Y-UP, CONVERTED AT LOAD.** A Z-up source is rotated when loaded; nothing downstream
thinks about the up axis. `robot_mjcf.build` stays Z-up on purpose — its acceptance test is
agreement with MuJoCo body-for-body, and a frame conversion inside it would turn a disagreement
into two explanations. The rotation happens one layer up, in the retarget loader, exactly as
robot_mjcf.zig:39 anticipates. ★ Gravity must be rotated with the model. ★ We need LESS
conversion than GMR: it rotates BVH into Z-up, we keep BVH's native Y-up and only convert cm->m.

★★ **START AT §13x, THE GENO RAGDOLL**: a MuJoCo model synthesized from Geno's own skeleton,
playing the dance with a DIRECT WRITE and no IK. It exercises the whole qpos path with the
solver removed, so any error is plumbing rather than a limitation of the target — and it then
becomes ground truth for the solver, which must converge to the same answer.

Prior arc (`src/notes/mocap_plan.md`, §11-12): BVH/FBX loading, skinning, and the GenoView look
— shadow map, G-buffer, SSAO, bilateral blur. Complete through §12d.

# ★★★ HOW TO RUN TESTS — `test-fast` FIRST, ALWAYS

    zig build test                                   EVERY QUICK TEST: src/tests.zig + test-fast + tier-A wasm
    zig build test-fast                              the shader-free half only (zimrnum, zimrmath, robot family)
    zig build test-fast -Dtest-filter="<substring>"  one test by name
    zig build zn-<stem> -Dtest-filter="<substring>"  one root, one test - the fastest loop
    zig build test -Dslow-tests                      also the long simulations and learning curves
    zig build zn-<stem> -Dtest-report                also print the robot tests' measurement tables,
                                                     and run the MEASUREMENT tests, which skip otherwise

★★★ **`test` IS A SUPERSET OF `test-fast` (Sep 26).** One command runs every test that is quick,
each binary once and in parallel. `src/tests.zig` no longer runs the robot family - it skips
`zimr.zig`'s robot re-exports (`robot_family` in that file) and leaves them to
`src/robot_tests.zig` - because with both wired, every robot test ran twice. What `test` leaves
out is the long end: `-Dslow-tests` (the same `@hasDecl(options, "slow_tests")` gate the tests
already use) and `test-all-examples`.

★★★ **A PASSING TEST BINARY MUST PRINT NOTHING.** This Zig's build runner prints a test binary's
whole stderr even when every test passed - headed `run test w` and followed by a stale
`failed command:` line - so a few hundred lines of robot tables made a green `zig build test` read
as red. The tables go through `report.print` (`src/test_report.zig`), silent unless
`-Dtest-report`. A new report line uses it too; `std.debug.print` in a test brings the noise back.

★★ **A TEST THAT ASSERTS NOTHING IS A MEASUREMENT, AND MEASUREMENTS DO NOT RUN BY DEFAULT.** Twenty
robot tests printed a table and asserted only `isFinite`, `x == x`, `any or !any`, or their own
setup - the standing and shove sweeps, the servo-ladder debug rungs, the whole-dance runs - and
cost simulation time on every run for no check at all (how much: not yet measured). They open with
`if (!report.requested()) return error.SkipZigTest;` (runtime, so their bodies still compile) and
run under `-Dtest-report`. A measurement that should guard something gets a real assertion
instead: `massDiagonal` printed "0 of 27 DOFs disagree" without ever checking it, and now asserts it.

★★ **`test-fast` COVERS THE SHADER-FREE HALF OF THE ENGINE**: robot, robot_physics,
robot_control, robot_mpc, robot_scene, urdf, mjcf, robot_urdf, robot_mjcf. Each is its own test
artifact depending on `zm` + `build_options` only.

★★★ **WHY IT EXISTS.** `src/tests.zig` is ONE root importing everything, so a change to
`robot.zig` rebuilt a binary linked against every compiled shader in the tree. Measured:
`robot.zig` alone is **33 s / 118 tests**; the full root is minutes and repeatedly timed out
mid-session, which is how five compile errors accumulated in it unnoticed.

★ `-Dtest-filter` was ALREADY SUPPORTED by Zig's test runner and simply not plumbed through
`build.zig`. Nothing exotic — the lever existed.

★ **THE SLOW ONE IS `robot_mpc`: 117 s on its own** (36 tests, several finite-difference
derivative sweeps that step a whole model per epsilon). It is genuinely doing work; the fix is
to filter it out while iterating elsewhere, not to weaken it.

★★ **STILL TRUE AND STILL A TRAP: `zig build check` DOES NOT RUN UNIT TESTS.** It runs the
shader corpus, lint and regression gates. A deliberately broken quaternion order passed `check`
cleanly while `src/tests.zig` had two compile errors and had not built at all.

★ Symptom to recognise: "check green, N tests passing" where N came from a DIFFERENT command
(`zig test -Mroot=src/<file>.zig`) run earlier against one file. That is not the suite.

# claude.md — fresh-session entry point

## Current plan

Each plan file under `src/notes/` is the ONE source of truth for its own decisions, status and
journal — **append per-turn notes there, never here**, and never restate a plan's counts or next
steps in this file. Name a new plan here when work on it begins; finished plans move to
`src/notes/archive/`.

**ACTIVE**

- `rl_track_plan.md` - **THE CURRENT PLAN (v4, Sep 27 evening); `C` resumes it.** SuperTrack on the 10-second
  dance, fundamentals first, then the first night. Sections: standing rules (turn discipline; build/test traps -
  `check` does not compile pages, insert declarations above doc comments; engineering rules - known answers, one
  definition per concept, graph-vs-rows parity, the recipe as one value), the goal stated so it can fail, the
  principles (P1-P7: one task; SuperTrack's failure rule; gravity; root motion seen; Simon's filter and 30 Hz clock
  inside training; judged in reality), where we stand (the task, the judge's baselines - servo 1.53 s on
  `dance_5_15` -, the CPU and GPU learners), what is DONE (Phase T, F1-F6a, the SuperTrack comparison, the Sep 27
  review), lessons L1-L13, then THE WORK AHEAD in stages: A the action path (the policy sees its applied action; the
  recipe as one value), B THE BENCH (`zig build st-bench`, a deterministic CPU learning curve with the judge and
  trust/exploitation rows) and its baseline curve, C recipe decisions on the bench (offset scale and noise, the
  paper's losses, the optimiser), D the world model's form (rigid-body graph ops, `AccelWorld`, the A/B), E scale and
  drift, F the feasible reference, G the kit's parity, H the gate; then Phases R, ON, C, P, A, X, M; decisions,
  risks, where things live.
  Archived: v3 (Sep 26-27: Phases T and F in full, the MimicKit table, Phase R's workflow study) is
  `src/notes/archive/rl_track_plan_v3.md`; v2 (Sep 23-26) and v1 (T1-T9b) beside it; `rl_track_journal.md` is the
  dated history; `supertrack_comparison.md` tables the paper, an unofficial repo and ours.

- `ragdoll_compare_plan.md` - **PAUSED (it was the current plan at 2163).** A `ragdoll_compare`
  example: the MJCF humanoid dropped twice, once in reduced coordinates (`robot.zig` +
  `robot_physics.Bridge`) and once in maximal coordinates (`zimrphysics`, 13 bodies, 12 joints),
  to measure perf and flexibility side by side. Simon's decisions are in its §8; Stage 0
  (`src/robot_maximal.zig`, headless, no GPU) is under way and its journal says what is next.

- `servo_ladder.md` - **ACTIVE, second — its §8 (2163) re-derives the ladder: BALANCE is the gating risk
  (a held standing pose falls in 1.4 s on both engines), rungs B0-B2 / S0-S2 / R0-R1 / L0.** Getting a ragdoll into a pose, which is upstream of
  every DReCon/SuperTrack decision: a policy that outputs offsets on top of a controller that
  cannot hold a pose is a correction to noise. Written after many turns of an exploding ragdoll
  whose cause was never found. **The diagnosis is that `dance_track` has a dozen interacting
  features and several were changed per turn**, so a failure could not be attributed - while
  every single-feature test passed. The method is a LADDER in a new minimal example,
  `servo_lab`: one addition per rung, one number per rung, a pass threshold, headless first, and
  no rung skipped for being obvious. Rungs 0-2 pass (one hinge static, one hinge on a sine, all
  24 joints holding their own rest pose); rung 2 had never been run and both cleared the
  controller and caught a gain I had just lowered for a plausible reason. `drecon2.md` keeps the
  method decision and the component measurements; this file owns getting unstuck.

- `zimrnum_plan.md` - **plan v3**: where things stand as a measurement (§1), what "best possible" means as five testable properties (§2), and twenty items in dependency order across four tiers (§3). v2 is in `src/notes/archive/zimrnum_plan_v2.md`; the full study, the staged port and the 93-row divergence register are in `src/notes/archive/zimrnum_plan_v1.md`.
  library with autograd, nn, optim, stats and RL that **trains on the GPU**, every kernel authored
  in Zig through `kompute` + `spv2wgsl`. Design donor `znum` (63k lines + a 19k-line WebGPU
  training runtime + 51 Zig kernel files); nothing is cut, `df`/`sparse`/`io` are staged late.
  ★ The file split is LOAD-BEARING: `zimrnum.zig` is `zm`+`kompute` only so it stays `test-fast`
  and `robot.zig` can adopt it; `zimrnum_gpu.zig` holds everything that touches a queue. Do not
  collapse them. ★ zimrnum must NEVER be imported by `src/tests.zig`.
  ★★ Stage 0 is two upstream merges into zimr itself, both from znum's delta ledger and both
  additive: `zm.tanh/sigmoid/gelu` (~45 lines) and `kompute.installKernelLean` + `Uniform(M)` +
  `g.uniform()` (~60 lines, reads the Params uniform directly instead of copying it into a Ctx —
  znum measures the stock path at ~2x the WGSL). ★ **`spv2wgsl` is NOT lifted from znum** — its
  ledger records the transpiler as verbatim, and zimr's copy is the newer one (11 603 vs 11 561
  lines) and carries the 1980 storage-block fix that znum's kernels will need.

**ACTIVE (second, alongside zimrnum — `C` resumes zimrnum unless you name this one)**

- `docs_style_plan.md` — uniformize every published page to white on black, one shared `<style>`
  injected at build time by `tools/docfmt.zig`, Zig's own tokenizer doing all highlighting,
  `<details>` folds, zero runtime JS and zero network. Simon's five decisions are made and
  recorded in §6. Stages 0-4 and 6 are landed; stage 5 (folds in `robots.html`) is what remains.
  `zig build doc-gate` — also wired into `check` — is what keeps it from drifting back.

**PAUSED (was the last pair worked before zimrnum)**

- `mocap_plan.md` — BVH loading in `codecs.zig` plus a `mocap_viewer` example reproducing flomo's
  drop-to-view scrubber (Simon's C++/raylib mocap tool). **BVH only**; FBX deferred, §7 records
  why. Blocked on sample `.bvh` fixtures. Note the first real dependency: zimr has NO runtime file
  input at all, so drag-and-drop is new engine surface in `bridge.zig`, not an example detail.

- `robot_port_plan.md` — MuJoCo's reduced-coordinate dynamics as `src/robot.zig`, consuming
  zimrphysics for collision. Phases 0–3 are done and documented as a course in
  `src/notes/tutorials/robots.html`; `robot_mpc.zig` adds iLQR. Live sub-plans:
  `foot_slip_plan.md`, `arm_balance_plan.md`, `tangential_anchor_plan.md`.

**PAUSED, IN PRIORITY ORDER**

- `lint_opinionated_plan.md` — grow `tools/zimrlint.zig` into an opinionated compiler extension.
  Everything stays in that one file. Next: the (a) no-symbol-table machinery, then
  catch-suppression (~158 sites).
- `spv2wgsl_vs_reference.md` — make `spv2wgsl.zig` always pass Tint/Dawn validation. naga is a
  temporary dev oracle; the permanent gate is our own ported validator.
- `p2p_multiplayer.md` — roadmap complete with 17 headless mesh tests; awaiting a browser test.
- `raylib_port.md` — one example per turn, each leak-free under `.managed`.
- `webgpu_control.md`, `physics_demo.md`, `plot3d.md`.

**PLANNED** — `vulkan_backend.md`: native platforms behind a comptime backend seam. Investigation
complete, implementation deferred; web stays first-class.

## Disk and the zig cache

The container has about **10 GB of headroom**, and a full `zig build test` compiles every tier-A
example to wasm — roughly **8 GB of objects**. It fills the disk in a handful of builds, and a
full disk fails as `configure command exited with code 1`, which looks nothing like "out of
space".

**Use `-Dfocus` for the inner loop.** It narrows example typechecking without skipping the host
unit tests — verified by planting a failure in one and watching the focused build go red:

    zig build test -Dautofix=false -Dfocus=<example> -j1     # ~565 MB of cache
    zig build test -Dautofix=false -j1                       # ~8 GB

**When space runs short, in this order:**

    rm -rf zig-out                                        # regenerable, ~120 MB
    rm -rf .zig-cache/tmp/* && mkdir -p .zig-cache/tmp    # contents, NOT the directory
    /home/claude/prune_cache.sh                           # test binaries only
    rm -rf .zig-cache/o .zig-cache/h .zig-cache/z         # together, never one alone

★★★ **`.zig-cache/o` AND `.zig-cache/h` ARE ONE STRUCTURE.** `o/` holds generated sources; `h/`
holds manifests referencing them by hash. Prune one and the other still claims they exist, so zig
skips regenerating and then cannot open them — `unable to load ... FileNotFound`. Pruning `o/` by
mtime once freed 4.2 GB and broke the build for exactly this reason.

★★ **PRUNE ONLY DIRECTORIES CONTAINING A `test` BINARY.** Every source edit produces a 156 MB
test binary and the old one is never evicted; four builds in six minutes cost 0.6 GB. An earlier
script deleted "anything big and old" and took out the build system's own `configurer`, which is
small, shares the cache, and **does not come back** — only a full `rm -rf .zig-cache` recovered
it. The guard is not "avoid the configurer" but "touch nothing except the thing known to be
disposable".

★ **`.zig-cache/tmp` MUST EXIST.** Removing the directory rather than its contents gives
`configuration failed: FileNotFound` with nothing else to go on.

**A build that exits non-zero with no `error:` lines and a truncated step list has timed out** —
a cold cache needs more than one turn. Re-run it detached; do not start debugging.

## First thing each session
Read `src/web/readme.html`. It is the project description — what zimr is, the
API, the build commands, the shader/compute pipeline, the file layout. **Keep it
current**: any change to a path, type, namespace, build step, or behavior it
describes gets reflected in `readme.html` the same turn (grep it for the old name
before merging). The repo file is canonical, not the `/mnt/user-data/outputs/`
delivery copy.

## Show Simon the code — every turn, no exceptions
★★★ **SHOW AND EXPLAIN, IN THE REPLY ITSELF (Simon, Sep 27).** Every turn's reply contains the new or
changed code - as it stands in the tree after `zig fmt`, not as it was first typed - and says what each
piece does and WHY it is shaped that way. Tool calls do not count: a Python patcher or a `str_replace`
buried in the transcript is not "shown". Print the final regions (`sed -n`) before writing the reply;
doing so caught two stale doc references in the same turn this rule was written.

★★ **INSERT A DECLARATION ABOVE THE NEXT ONE'S DOC COMMENT, NEVER BETWEEN THEM (Sep 27, three times in one
session).** Anchoring a new `pub const X` on the line `pub const Y = struct {` puts X between Y's `///` block and Y:
Y's documentation silently becomes the start of X's, and Y is left undocumented - it compiles, lints and tests clean.
It happened to `Fleet` (under `Task`), to `InModel` (under `Diagnosis`) and nearly again. Anchor on the first `///`
line of the next declaration's comment, then print the region and read both headers before moving on.

★★ **NO `anytype` UNLESS IT IS GENUINELY NECESSARY (Simon, Sep 27).** A function that only ever means one
type takes that type. If the obstacle is an import edge, fix the structure (a shared type in the lower
module, a new file) - that is what turned `ppoTaskOptions(base: anytype)` into `robot_track.Task`. When
`anytype` IS right (real genericity), add a comptime test pinning which types it accepts.

**ALL new or changed code appears in the chat, in full.** This is a hard rule and
the most common way to fail Simon. Concretely:
- A new file: its COMPLETE source must be visible in the conversation. A
  `create_file` call whose content is shown satisfies this; a file written via a
  heredoc inside a long bash script, or assembled by a Python patcher, does NOT —
  in those cases paste the resulting file (or every changed region, whole) in the
  reply.
- An edit: show the full new version of every changed function/region (a
  `str_replace` with visible old/new counts; a sed one-liner does not).
- Shaders and engine changes are never summarized — always the full text.
- Recovering work from a lost context or a prior session? Re-show it (view the
  file in a tool call) before shipping; Simon must never receive code he has not
  seen.
Alongside the code: explain what each piece does and why, walk through anything
non-obvious, and `present_files` any standalone built. If the work is visual,
Simon opens the standalone and sends a screenshot — there is no GPU or browser in
this sandbox, so the visual verdict is always his. Inline code + visual proof,
both, every time, even on multi-example turns.

## ★★★ WHEN A USER SAYS "IT WAS BETTER BEFORE", BISECT YOUR OWN CHANGES

Reported: the humanoid shakes, and it was better before the investigation started. Correct. Two
changes had gone in since — contact friction plumbed through, and the controller's gains
converted to `scale_by_inertia` frequency units. Standing still for five seconds, measuring how
much the joints move:

    BEFORE  kp 400 / kv 10, mu 0.5      0.0000   <- dead still
      + the friction fix only           0.0001   <- still dead still
      + the gain change only           16.8805   <- the regression
    BOTH (what shipped)                16.9196

**One line of the bisect names the culprit**, and it was not the one I had been defending. The
friction fix is measurably harmless AND more correct; the gain conversion was a large
regression on this robot.

★ THE ORIGINAL BUG WAS REAL AND THE FIX WAS TOO BIG. `kv` 40 genuinely diverges — the slider
offered four times the `kv·dt/M < 2` limit. But the answer was to **cap the slider at 10**, not
to change the units of a controller that was measurably perfect. `scale_by_inertia` is the right
tool for a model whose links differ by orders of magnitude (the gripper arm needs it); it is not
a free upgrade.

★★ AND A THIRD PROPERTY FOR CONTROLLER TESTS: **standing still**. The test already asserted
"holds itself up" and "does not explode", and the regression passed both while visibly shaking.
Neither implies stillness.

## ★★★ A DEMO MUST NOT CONTAIN ANYTHING ACCELERATING TO INFINITY

The humanoid demo parked its six throwable balls at **z = −2.0, below the floor**, on the
reasoning that nothing could reach them there. Nothing could — and they **fell forever**,
accumulating kinetic energy without bound.

★ AND THE ENERGY READOUT SUMMED THE WHOLE MODEL, so a figure meant to describe a humanoid lying
still read **17 000 J** of falling balls. Measured after ten seconds of standing:

    balls under the floor:  whole-model 17328.11 J   robot only 4.2323 J
    balls on the floor:     whole-model     3.89 J   robot only 3.8884 J

**The robot was fine the entire time.** Two turns went into chasing an explosion in the robot's
controller that was six spheres offscreen.

★★ THE TELL WAS THERE AND I MISSED IT: the number was **identical at every controller gain** —
17328, 17324, 17339 at ω = 45, 20 and 80. A quantity that does not respond to the thing you are
varying is not being caused by it.

★ TWO RULES OUT OF IT. Park idle objects somewhere they can REST, not somewhere they merely
cannot be reached. And a readout named for one subsystem must sum over that subsystem — here,
the robot's DOF prefix rather than the whole model.

## ★★★ "DOES NOT EXPLODE" IS SATISFIED BY A CONTROLLER THAT DOES NOTHING

Converting the humanoid demo's gains from torque units to frequency units, I verified the new
setting was STABLE — shoved four times, no divergence — and shipped it. **The robot could no
longer stand.** Torso sagged from 0.596 m to 0.266 and it lay down and span.

★ THE ARITHMETIC IS OBVIOUS AFTERWARDS. `scale_by_inertia` divides `kp` by the joint's own
inertia, so ω = 20 on a joint carrying M = 0.01 is an effective torque-unit gain of **4**,
against the 400 it replaced. A hundred times weaker. Converting units without re-checking what
the numbers were WORTH is how a gain silently becomes a different gain.

    omega  20   torso 0.266   COLLAPSES
    omega  30   torso 0.563   stands, peak KE 32 J after four shoves
    omega  45   torso 0.565   stands, peak KE 36 J          <- shipped
    omega 110   torso 0.565   stands, peak KE 38 J

★★ SO A CONTROLLER TEST NEEDS BOTH HALVES, and there is now one: it asserts the robot still
holds itself up AND that shoving it does not blow it up. Either alone is passed by something
useless.

★ AND A SLIDER FLOOR IS PART OF THE SAME LESSON. The range now starts at 25 rad/s, above the
collapse point — a slider whose low end silently drops the robot teaches that something is
broken rather than that the gain is too soft.

## ★★★ A PD's DAMPING TERM IS EXPLICIT — `kv·dt/M < 2` OR IT EXPLODES

`PoseHold`'s derivative term is an APPLIED torque, so the integrator sees it as an external
force and integrates it explicitly. That is stable only while

    kv · dt / M < 2

where `M` is the joint's own mass-matrix diagonal. For this humanoid — armature 0.01, dt 1/500
— **that caps `kv` at 10**, and the demo's slider ran to 40.

★ MEASURED, SHOVING THE ROBOT OVER FOUR TIMES:

    kv 10   peak KE    32 J   settles to 0.003
    kv 40   peak KE   174 J   stays at 39

**MORE DAMPING MADE IT WORSE.** That is the signature of explicit integration, and it reads as a
mysterious explosion rather than as a gain being out of range — which is exactly how it was
reported: a ragdoll bouncing after a couple of shoves, with kinetic energy at 18 000 J and every
velocity pinned to the clamp.

★★ THE FIX IS `scale_by_inertia`, which divides `M` out so the condition becomes `ω·dt < 2` — a
property of the RESPONSE rather than of whichever link is being pushed. Swept ω from 5 to 70
with the same four shoves: every one stable. **Gains in frequency units are not a nicety; in
torque units the same slider is safe on a shoulder and divergent on a wrist.**

★ AND A UI RULE FROM IT: a slider must not offer a value that is guaranteed unstable. If the
range cannot be made safe, the units are wrong.

## ★★★ NEVER DO A WHOLE UNIT OF WORK INSIDE ONE FRAME

The cartpole demo ran one CEM generation per `update`. Measured at 66 ms on a desktop, several
times that on a phone — and **the demo was not interactive at all.** Not slow: untouchable. A
swipe needs several samples to read as a drag and a tap needs its press and release to land in
frames that actually happen, so at two frames a second neither input exists.

★ THE FIX IS NOT A SMALLER CONSTANT, IT IS A SMALLER UNIT. One policy evaluation instead of one
generation of forty, with the generation completing across however many frames it takes. Nothing
about the algorithm changes — same policies, same seeds, same order — only when.

    if (delta_time > 0.022) budget = @max(1.0, budget * 0.8)
    else if (delta_time < 0.012) budget = @min(8.0, budget + 0.5)

★ **THE FLOOR IS ONE AND THE CEILING IS LOW.** A floor of one keeps the slowest device
interactive; a low ceiling means an overshoot costs one bad frame rather than fifteen spent
shrinking back from it. Worst case at the ceiling is 13 ms, inside a 60 fps frame even late in
training when episodes run their full length.

★ AND A SECOND BUG THE SAME SHAPE: the displayed robot stepped ONCE PER FRAME against a 100 Hz
simulation, so it played back at 60% speed on a good device and 30% on a struggling one. The
physics is right and the motion visibly wrong — which reads as the policy being sluggish rather
than the loop being wrong. Anything driving a fixed-timestep simulation from a variable frame
needs an accumulator.

## ★ SIZE THE UI TO THE VIEWPORT — `ui.Ui.scaleToViewport`

zimr ships in a browser tab, so "the window" is anything from a 360 px phone to a 4K desktop. A
panel in fixed pixels is unreadable at one end and comical at the other.

    const narrow = ui.Ui.isNarrow(f.window.widthf());
    const panel_w = if (narrow) f.window.widthf() - 16 else @min(400.0, f.window.widthf() * 0.32);
    const font = u.scaleToViewport(panel_w, if (narrow) 30.0 else 22.0);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});

The second argument is roughly **how many characters of body text fit across the panel** — a
full-width one wants ~30, a floating one ~22. Everything else (padding, spacing, title bar) is
derived, because the 151 examples that already scaled by hand all used the SAME multipliers
(0.35/0.3, 0.4, 0.5, 1.6) and differed only in that one divisor.

★ AND IT IS NOT APPLIED AUTOMATICALLY IN `UiHost.begin`, which would be tidier and wrong: those
151 would then scale twice. 63 examples still size in fixed pixels and can adopt it one at a
time.

★ **A PLOT NEEDS AN EXPLICIT `.width`.** Without one it defaults wider than its panel and the
overlay label renders OUTSIDE the box — invisible on a desktop, obvious in a phone screenshot.

## What zimr is
A pure-Zig port of raylib and Dear ImGui on `wasm32-wasi` + WebGPU. No C
dependencies, no emscripten. WebGPU is the only render path (the old GL backend is
gone).

**★ THE BROWSER IS THE ONLY TARGET. Host builds exist to run the tests and the
benchmarks — nothing ships there.** Two consequences that are easy to forget when
writing engine code on a Linux box:

* **There is no `std.Thread`.** The parallel path is `jobs.zig` — pure kernels on
  Web Workers, by message passing. Its header has the measured ceiling: eight
  workers give about **3.4x**, a partitioned frame **2.7x**, and a hot CPU
  **throttles the GPU**, so buying CPU can cost frames in a renderer.
* **A native-only fast path is not a fast path.** Anything gated on
  `builtin.target.isWasm()` being false runs only in tests, so it is untested
  where it matters and unshipped where it works. The only build dependency is the Zig compiler. Two transpilers, both
written in Zig, carry the code to the browser: `spv2wgsl` (Zig → SPIR-V → WGSL for
shaders and compute kernels) and `c2js` (Zig → C → JavaScript for the browser
host, `src/bridge.zig`). The architecture lives in the `//!` doc atop
`src/zimr.zig`; the public API surface is `CHEATSHEET.md` (codegen). Reference C
is at `/tmp/raylib-master/` and `/tmp/imgui-master/` (the imgui DOCKING branch —
zimr mirrors docking, not master).

## Snapshots — per-turn, non-negotiable
The repo at `/home/claude/zimr` is the source of truth (the sandbox preserves it
across restarts; the zip is insurance and the recovery point if it ever resets).
- **End every turn with a zip** and `present_files` it. Ship only at a GREEN
  milestone — never a mid-broken build.
  ```
  cd /home/claude && zip -r -y -q /mnt/user-data/outputs/zimr<N>.zip zimr \
    -x '*/.zig-cache/*' -x 'zimr/.zig-cache/*' \
    -x '*/zig-out/*' -x 'zimr/zig-out/*' \
    -x 'zimr/tools/zig-x86_64-*' \
    -x 'zimr/tools/bun-linux-x64/*' -x 'zimr/tools/naga/*' \
    -x 'zimr/prebuilt/standalone/*.html' -x '*/.git/*' -x 'zimr/.git/*' \
    -x '*/node_modules/*' -x 'zimr/intake/*' \
    -x 'zimr/*.js.map' \
    -x 'zimr/zimr*/*'
  ```
  NB: the `*/.zig-cache/*` / `*/zig-out/*` / `*/.git/*` forms are DEPTH-AGNOSTIC —
  nested caches exist (e.g. `src/shaders/tools/.zig-cache/`) and the top-level-only
  globs miss them. `zimr/zimr*/*` drops any stray nested project snapshot
  (a 55MB `zimr331/` dupe was accidentally living in the tree — junk, not built).
  Everything else ships (all `src/`, notes, `build.zig`, scripts, examples).
- **Prune** (disk is finite, a full cache is ~2.5G): keep the 5 most recent + every
  10th. If disk is tight mid-turn, `rm -rf .zig-cache tools/.zig-cache` first.
  ```python
  import os,re,glob
  z=glob.glob("/mnt/user-data/outputs/zimr*.zip"); n=lambda p:int(re.search(r"zimr(\d+)\.zip$",p).group(1))
  nums=sorted(n(p) for p in z); keep=set(nums[-5:])|{x for x in nums if x%10==0}
  [os.remove(p) for p in z if n(p) not in keep]
  ```

## Iterating — the velocity path
Don't default to `zig build test` for iteration; it builds broadly. When working a
specific example, shader, or module:
- Build its standalone and hand it back: `zig build <name>-standalone
  -Dmode=release` → `zig-out/standalone/<name>.html` → `present_files`.
- **Always `-Dmode=release` for standalones.** It is ReleaseSmall but keeps the
  zimr asserts (`assertf`/`alwaysAssert`) and their on-page log. Omitting `-Dmode`
  defaults to **debug** (large + slow); reserve debug for crash-stacktrace work.
  The mode enum is `debug | release | ship` (build.zig). `ship` strips zimr's
  asserts and the profiler; older notes calling it `release-with-zimr-asserts` or
  `release-no-zimr-asserts` are stale — those names no longer exist.
- **"Iterate in debug because it builds faster" is FALSE — measured (1282, July).**
  Launcher rebuild after a one-example edit: debug **48s** / release **51s** (+6%),
  and debug peaks at **2 GB** RSS vs release's **1 GB**. Single example: debug ~9-10s
  / release ~13-15s (+50%, i.e. +4-5s). What debug actually costs is the ARTIFACT:
  launcher HTML **26.6 MB** (debug) vs **12.0 MB** (release); a single example
  7.3-10.8 MB vs 1.9-5.1 MB. Simon opens these on a phone. Four seconds of build time
  never beats 5-15 MB of transfer. Do NOT "speed up iteration" by dropping to debug —
  and don't mix modes to compile-check either, since ReleaseSmall has its own
  failure modes (the old UiHost ReleaseSmall hang) that a debug check would miss.
- A new engine shader is just dropping files in `src/shaders/`: a
  `*_vs.zig` / `*_fs.zig` (+ `*_io.zig`) is auto-discovered, translated to `.wgsl`,
  and wired into the engine module. No `build.zig` edit needed.

## Building one example from cold cache — step by step
Zig caches by **content hash** (`touch` invalidates nothing) and its cache GC
evicts old entries **including the tool binaries** (`zimrlint`, `spv2wgsl`,
`c2js`). From a cold or partially evicted cache, one
`zig build <name>-standalone` chains: configure → zimrlint (build the tool,
then lint all ~450 files) → spv2wgsl (ReleaseFast) → per-shader transpiles →
c2js (host JS) → the wasm compile (ReleaseSmall) → standalone pack. That chain
does not fit in one command window on this 1-core box — but every finished
object is cached, so the procedure is an **idempotent retry loop**: rerunning
the SAME command always makes forward progress. Never `rm -rf .zig-cache` to
"fix" anything; that converts minutes of retries into a ~30-minute rebuild.

**Measured cold on compiler 1902** (fresh sandbox, no cache, no toolchain), one core,
`-j1 -Dmode=release -Dautofix=false`. Every round finished well inside its window; **no retry
loop was needed anywhere**:

| step | wall | peak RSS | cache after | Δcache |
|---|---|---|---|---|
| `tar -xJf` the toolchain | 8s | — | — | 410 MB on disk |
| build runner (`zig build -h`) | 104s | 758 M | 26 M | +26 M |
| `c2js-canary` (compiles c2js) | 32s | 462 M | 41 M | +15 M |
| `lint` (compiles zimrlint + 450 files) | 49s | 650 M | 64 M | +23 M |
| **`hello-world-standalone`** | **82s** | 753 M | 243 M | +179 M |
| **`launcher-standalone`** (32 flagships) | **90s** | **1148 M** | 309 M | +66 M |
| `smoke-test -Dfocus=hello_world` | 29s | 638 M | 333 M | +24 M |
| `check` | 54s | 732 M | 370 M | +37 M |

**Cold to launcher is ~6 minutes and 370 MB of cache** — against the 1282 profile's ~22 minutes
and 1.2 GB. The gen_externs Debug+strip fix is what closed that gap; the S2/S3 phases of
`build_profile_1282.md` no longer exist as separate costs. Artifacts: `hello_world.html` 1.7 MB,
`launcher.html` 13.7 MB.

**The launcher standalone builds direct from cold in `-Dmode=release`** — no example-warming, no
OOM (1148 M peak against ~3.9 GB). It runs lint itself, so a separate `zig build lint` warm is
redundant for it. The old "warm each constituent module first" rule is DEAD in release mode;
in `-Dmode=debug` it still peaks ~2 GB, but the launcher never ships in debug.

### ★ THE STREAMLINED SEQUENCE — cold sandbox to a verified launcher

Ordered cheapest-first so the gates that catch SILENT breakage run before the ones that cost
minutes. Total under 4 minutes when nothing is wrong:

    tar -xJf <upload> -C tools/ && . ./.zenv.sh          # 8s
    zig fmt --check src examples build.zig tools/zimrlint.zig   # 1s   tier 2
    <c2js name sweep, below>                             # 4s   tier 3, static
    zig build c2js-canary -Dautofix=false -j1            # 32s  tier 3, dynamic
    zig build hello-world-standalone -Dmode=release -Dautofix=false -j1   # 82s
    zig build launcher-standalone   -Dmode=release -Dautofix=false -j1   # 90s

`hello-world-standalone` is the cheap failure probe: it pulls the ENTIRE tool chain (spv2wgsl,
gen_externs, c2js, per-shader transpiles, the engine wasm) for a fraction of the launcher's
link. If it is green the launcher almost certainly is too. Do NOT pre-warm anything else.

**`measure <label> <cmd...>`** (built once by `zig build measure`; `.zenv.sh` puts it on PATH)
wraps a build and logs wall / peak RSS / cache delta / free disk to `/tmp/measure.log`. It takes
no timeout argument — wrap it in `timeout`. It exists because `--summary all` only prints on
COMPLETION — a round that times out leaves no record at all, and cache delta per round is the
only progress signal that survives. Peak RSS is polled from `/proc` (there is no `/usr/bin/time`
in this sandbox) and summed across the whole `zig` tree, since what matters is what the box holds
at once.

Ground rules for every call:
- FOREGROUND, wrapped in `timeout`, for anything that fits one call. A plain `&`/`nohup` build is
  reaped between tool calls (empty logs, no zig processes) - but a DETACHED one survives:
  `setsid nohup sh -c '...; echo exit $? >> log' < /dev/null > /dev/null 2>&1 &`, then poll the log
  in later calls (Sep 24: a 457 s D3 run finished this way).
- **`timeout 250`, not 170.** The 170s convention was calibrated on the 1282-era chain that cost
  850s in S2 alone. On 1902 the longest single round measured is 104s, so a 170s window mostly
  risks orphaning a step that was about to finish. Raise it and the retry loop disappears.
- `-j1` always (1 core, ~3.9GB RAM).
- **LINT AND FMT (Sep 25, Simon): building is NOT gated.** Tests, smoke tests and release pages neither
  check nor rewrite style - no more `-Dgate=false` / `-Dautofix=false`, and no build ever reformats a file
  under an edit. Style is required where it matters, always as a non-mutating CHECK: every
  `*-standalone` page, `dist`, `check`, and anything in `-Dmode=ship` fail unless `lint-check` (fmt --check +
  lint) passes. `zig build fix` is the ONE step that rewrites (lint --fix, then zig fmt). **End every turn
  with `zig build fix` (if anything needs it) then `zig build check`.**
- **NEVER the full `zig build test` inside a turn (Sep 25):** it outlasts a turn - one died mid-run, its finished work
  unreported. Run the modules touched (`zn-<stem>`), or the main module's tests with `-Dfocus=<example>
  -Dtest-filter=<name>` (113 s for the timer tests), DETACHED if long. The full suite is Simon's, or a detached run.
- **`whole-init-first` (lint):** after `x = ...create(T)` or in `init*(self: *T)`, the FIRST write through the pointer is
  `x.* = .{ ... }` - `create`d memory and `= undefined` ignore field defaults. Name a field `= undefined` in the literal
  if it is filled later. A function that resets or links an already-valid struct is a false positive: say so in a
  `lint:off whole-init-first:` line directly above its first field write.
- **A `timeout`-killed build ORPHANS its children.** `timeout` kills the `zig
  build` PARENT; the `zig build-exe` it spawned keeps compiling — on ONE core,
  forever, starving every command you run afterwards. Symptom: builds that took
  10s now take 60s, a smoke that "hangs", and a `zig build test` that seems to
  compile an example you never asked for (t1284: an orphan compiling
  `triangle_strip`'s Debug smoke wasm ran ~25 minutes and made the whole session
  look stuck). **So: after ANY `rc=124`, and any time a build feels slow, run
  `pgrep -a zig` FIRST** — and kill what you find:
  `for p in $(pgrep -x zig); do kill -9 $p; done` — NEVER `pkill zig` (it
  matches your own shell). A clean core is the difference between a 3s focused
  smoke and a 170s timeout; measure before you conclude the build is slow.
- **Watch the disk across a long turn.** The build guard fails at >=90% and its
  remedy is a ~17-minute cold rebuild. `zig-out` is pure output (1.8 GB after a
  launcher + a few standalones) and is regenerated on demand: once the
  standalones are copied to `/mnt/user-data/outputs`, `rm -rf zig-out` is free
  disk. It took one turn to go 47% -> 86%.

The steps, **one tool call each**:
1. **Warm the linter** (it gates every compile, and its own rebuild is the
   usual cold-cache time sink):
   `timeout 250 $ZIG build lint -Dautofix=false -j1`
   A cold first run may exit non-zero with only a "maker command exited" tail —
   that was the tool finishing its own compile. Run it AGAIN; now read real
   violations via `grep ': \['`.
2. **Build the example**, looping until green:
   `timeout 250 $ZIG build <dash-name>-standalone -Dmode=release -Dautofix=false -j1 2>/tmp/b.log 1>&2; echo rc=$?`
   Interpret the exit:
   - `rc=124` → timed out mid-chain. **Rerun the same command.** From cold
     expect 2–4 rounds (tool compiles ~60–90s each, wasm ~40–80s).
   - `rc=1` and `grep 'error:' /tmp/b.log` shows compile errors → real errors
     in the code; fix them.
   - `rc=1` and the log shows only a failed *configure* step (sometimes with a
     "rm -rf .zig-cache" hint) → the known transient; rerun once, it
     self-heals. Do NOT take the hint.
   - The failed-command tail names which step died (`zimrlint <450 files>`,
     `spv2wgsl`, `c2js`): that is a TOOL rebuild, not your code.
3. **Smoke it**: `timeout 250 $ZIG build smoke-test -Dfocus=<snake_name> -Dautofix=false -j1`
   (first run may also time out while the smoke wasm builds — same retry rule).
   Green includes the per-frame call profile AND the ClobberScan.
4. **Gate**: `timeout 250 $ZIG build check -Dautofix=false -j1` → green =
   `✓ NO REGRESSIONS` + `✓ wgpu_smoke PASSED`.
5. **If shaders were added or changed**: `timeout 250 $ZIG build corpus-refresh -j1`
   — merge-preserving; the output reports `N live + M carried`, and the count
   must never need to shrink.

### A GREEN SMOKE RUN IS NO EVIDENCE THAT A HOST NAMESPACE EXISTS

`webtests/wgpu_smoke.zig` stubs every `extern` the engine declares. `bridge.zig` — the one
browser host — builds the import namespaces for real. **Those are two different lists**, and for
months they disagreed: 20 `js_audio_*` externs were stubbed by smoke and absent from the bridge,
so every audio example compiled, smoke-passed, was marked done, and died in a browser at
`WebAssembly.instantiate` with "Import 'audio': module is not an object or function". None had
ever run.

★★★ **SMOKE SUPPLIES THE VERY IMPORT THE BROWSER LACKS**, which is why it cannot detect this.
When adding an `extern` namespace, check `bridge.zig` builds it — a passing smoke test says
nothing about that. (Fixed: `ZimrAudio` in bridge.zig.)

### VERIFY A ZIMRMATH CHANGE AGAINST SPIR-V IN ~1 SECOND (build nothing else)
**When a compiler bump breaks shaders, read `src/notes/zig-spirv-compiler-interface.md`
first** — it is the contract with Zig's SPIR-V backend (`@SpirvType`, `@extern` descriptor
decorations, exec-mode-on-callconv, and the inline-asm `"t"` type constraint that makes
`OpLoad` of an opaque image type resolve to the module's deduped type id).

zimrmath compiles for BOTH the CPU and SPIR-V. A change that is fine natively can
fail on the shader path — and the only way to find out used to be building an
example, which after a zimrmath edit recompiles EVERY shader.

**`zig build zm-gpu` is that check, and it takes 3 seconds.** It compiles
`src/shaders/zm_gpu_probe.zig` — a real SPIR-V fragment entry point that calls the
riskiest helpers on `zm.Vec` and folds the results into its output, so
`-O ReleaseFast` cannot delete them and call it verified. It is wired into
`zig build check`, so it is no longer something to remember to run.

★ This section previously documented `scripts/spv_math_probe.zig` and a hand-run
command line. **That file did not exist** — the recipe had been carried in this
document long after whatever created it. If a probe fn needs adding, add it to
`src/shaders/zm_gpu_probe.zig`, where the build already compiles it.

The flags, if you ever need them by hand (they are what `src/shader_codegen.zig`
uses; `-fno-llvm -fno-lld` is MANDATORY — LLVM segfaults on the spirv target):

    ZIG=tools/zig-x86_64-linux-*/zig
    $ZIG build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 \
      -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv \
      -femit-bin=/tmp/probe.spv \
      --dep zm -Mroot=src/shaders/zm_gpu_probe.zig -Mzm=src/zimrmath.zig

`zm` has NO module deps, so `--dep zm` is the only one needed.

★★ **The type-parameterized helpers are the ones that break, and they break
silently.** `nan`, `inf`, `floatMax`, `floatMin` and `floatEps` take a TYPE, not a
value, so `perLane` cannot reach them — every one answered `@compileError` for a
vector type, which is exactly what a shader computes in. They splat now
(`FloatScalar` + `splatTo`), and the probe is what keeps them splatting.

Used the same approach to clear the riskiest edit of the vocabulary work:
`clamp01` went from `pub fn clamp01(v: f32) f32` to `pub inline fn clamp01(v: anytype)`
with a `switch (@typeInfo(T))`, and shaders call it 24x directly plus more via
`smoothstep`. Probe compiled in 1s; the @typeInfo switch folds away at comptime
and what reaches the backend is plain OpSelect/OpPhi/OpBranchConditional — the
same ops `min`/`max` already emit.

★★ **THE `std-math` BAN NOW HAS A FILE-LEVEL OPT-OUT, AND ONLY A FILE-LEVEL ONE.**

    //! lint:off std-math: <why this file never reaches a shader>

Per-line `// lint:off std-math` is still refused. The distinction is the point: "this
file never reaches a GPU" is a property of the whole file, declared at the top where a
reviewer sees it. A per-line escape would silence one call inside a file that IS
shader-reachable — the exact hazard the ban was written for — and it would be invisible
4000 lines down.

The ban exists for one reason: std.math is host-only and does not reliably lower to
SPIR-V. A host-only transpiler has no portability exposure, so applying the rule there
follows it past its reason and costs a real dependency for nothing. `tools/c2js.zig`
had gained a whole `zm` import for a single `zm.nan(f64)` — a module dependency for one
constant. Reverted; it carries the directive instead.

★ **THE STANDALONE TOOLS, AND WHAT THEY ACTUALLY DEPEND ON TODAY** (measured, not hoped):

    src/spv2wgsl.zig      std + builtin ONLY — fully extractable as-is
    tools/spv2wgsl.zig    std + the `spv2wgsl` module (it is a thin CLI over the above)
    tools/c2js.zig        std + `jobs_abi` (73 lines, std-free) — effectively two files

Keeping these extractable is worth something concrete: `spv2wgsl` is useful to anyone
doing WebGPU in Zig, and it costs nothing to leave it that way. `tools/mesh_bake.zig`
is the opposite case and keeps its `zm` import — it already pulls zimrmath transitively
through `codecs`, so the dependency is free and the consistency is worth having.

★ **This is a policy, not a check, which means it will drift.** Nothing fails if someone
adds an import to `src/spv2wgsl.zig` tomorrow. The obvious fix is a `//! lint:standalone`
directive whose rule rejects any `@import` outside std/builtin and same-tool relatives —
small, and it turns the paragraph above into a property. Not built yet.

★ **The c2js CASE CORPUS is already skipped from linting** (`build.zig`, the
`firstSegmentIs(entry.path, "c2js_cases")` branch): 102 files of deliberately-varied Zig
that exist to exercise the transpiler, not to follow house style. Note that
`webtests/transpiler_corpus.zig` is a DIFFERENT thing despite the name — it is zimr's own
harness that runs that corpus, so its lint findings are real and it stays linted.

### zimrmath canonical names — the @compileError TEACHING ALIAS (the mechanism)

★★★ **THE LINTER'S AST WALK WAS INCOMPLETE, AND EVERY RULE INHERITED THE GAPS.**
`childNodes` enumerates node tags and ends `else => return buf[0..0]` — no children
for anything unlisted — and `walkNode` visits only *some* children of the tags it
does handle. Each gap is a place a rule silently does not apply. Found one at a
time, by grepping for violations the linter reported zero of:

- `.assign` and the 18 compound forms — an entire right-hand side, unvisited.
  `src/zimrphysics.zig` called `std.math.sign` three times that way.
- `.while_cont` — the `while (i < n) : (i += 1)` form is a DIFFERENT tag from
  `.while_simple`, in neither the switch nor `childNodes`. `src/image.zig:515` had
  `std.math.clamp` inside one and lint reported clean for as long as it existed.
- `if` / `while` **conditions**, and the continue expression. The walk takes
  `then_expr` and `else_expr` and never the condition — so
  `if (std.math.isNan(v))` was invisible.
- positional `.{ a, b, c }` initialisers.

**`std-math` no longer rides the walk.** It sweeps every node index in the file
(`runChecks`), which is complete by construction and cannot grow a new blind spot
when an unfamiliar syntax shape shows up. The other rules still walk, because they
need `pos`/`fn_depth`; widening them is a separate job, one rule at a time, because
each newly-reached node is a violation to fix or baseline.

★★★ **THE BASELINE IS NOW EMPTY — THE TREE LINTS CLEAN WITH NOTHING GRANDFATHERED.**
All 594 violations the ratchet was holding are fixed. `tools/lint_baseline.tsv` is a
comment explaining how to regenerate it, and should stay that way: a non-empty
baseline now means someone accepted a backlog on purpose.

★★★ **LINT-CLEAN AND FMT-CLEAN PROVE NOTHING ABOUT CORRECTNESS.** The last pass fixed
207 findings with no compile in between, exactly as asked. `zig fmt` passed, lint
passed, and **six functions in `ui.zig` were silently broken** — `setScrollX(-50)`
returned -50 instead of 0. Only `zig build test` knew.

The cause is worth memorising: **`@min(A, B)` is SYMMETRIC**, so a regex converting
`@max(0, @min(A, B))` into `clamp(...)` cannot tell the bound from the value. It
guessed, and got six of eight backwards. Every other clamp conversion that session was
written out per-site by hand and was correct. **Do not pattern-match a commutative
operator into a positional one.**

★★ **A `pub const x = @compileError(...)` TEACHING ALIAS TAKES THE TEST GATE DOWN.**
`src/tests.zig` runs `std.testing.refAllDecls(zm)`, which references every PUB decl, so
the error fires when the tests compile rather than when someone writes the old name.
zimrmath already documented this on `saturate` and it still caught me. The working form
is a PRIVATE stub - `fn phi() void {}` - invisible to `refAllDecls` (it only sees pub
decls via `@typeInfo`) while still visible to a reader, and the old name then fails with
"not marked 'pub'" which lands them on the note.

★★ **NON-ZIG CODE: WHAT WENT, WHAT STAYED, AND WHY.**

Deleted - eleven one-shot migration scripts under `scripts/` (brace/alias/cast rewriters, six
docs restylers). They had already been applied; keeping an applied migration invites someone to
run it twice.

Converted to Zig:

| was | now |
|---|---|
| `scripts/zn.sh` | `zig build zn-<stem>` - one step per fast-test root, twelve of them |
| `scripts/measure.sh` | `tools/measure.zig`, installed by `zig build measure` |

`measure` is INSTALLED to `tools/zig-out/bin` rather than run through a step, because this
Zig's `Build` has no `b.args` - a step cannot forward trailing `--` arguments, and the tool is
useless without them. `.zenv.sh` already puts that directory on PATH.

Two things the Zig version does BETTER than the shell it replaced: peak RSS comes from
`request_resource_usage_statistics` / `getMaxRss()` instead of polling `/proc` every 250 ms
(exact, and it counts the build runner's children), and `statfs` is declared directly rather
than shelling out to `df`. It has NO internal timeout: this std's `Child` exposes `wait` and
`kill` but no `tryWait`, so bounding a run would need a watchdog thread when the caller already
has a better one.

★★★ **ONE HAND-DECLARED KERNEL ABI IN THIS REPO: `tools/fs_space.zig`.**

Nothing in this Zig's std exposes filesystem statistics - no `statfs` wrapper, no
`GetDiskFreeSpaceEx` binding - so free space has to be declared by hand, per platform. That
makes it exactly the thing not to have two of, and there were two: `build.zig`'s disk guard
(Linux + Windows, returning `?DiskSpace`) and a SECOND one I wrote in `tools/measure.zig` that
was Linux-only and returned **0** on failure. A zero there reads as "disk full" - the opposite
of "did not measure". Both now call `fs_space.query()`.

★ **`null` IS THE ANSWER FOR A PLATFORM THIS HAS NOT BEEN TESTED ON**, and callers must render
it as `n/a`, never as a number. What that means concretely:

    linux x86_64   syscall + hand-declared struct — CHECKED against `df -m /`, agrees to the MB
    linux 32-bit   null — the layout differs and needs `statfs64`; not guessed at
    windows        `GetDiskFreeSpaceExA` — documented contract, NOT run, no machine here
    macos, bsd     null — its `statfs` needs libc and a different struct, and a wrong struct
                   does not fail loudly, it returns plausible garbage

★★ **PORTABILITY IS NOT A PROPERTY OF THE ENGINE ALONE - IT IS A PROPERTY OF THE TOOLS TOO.**
A dev harness that only runs on Linux quietly makes the repo Linux-only for anyone who tries to
contribute from a Mac.

★ **MUST STAY NON-ZIG, and not for want of trying:**

- `scripts/robot_oracle.py`, `scripts/robot_bench_mujoco.py` - they generate fixtures from REAL
  MuJoCo. The whole point is that an INDEPENDENT implementation produces the reference values.
  Rewriting them in Zig would make zimr its own oracle, which is not a test.
- `.zenv.sh` - it is what puts `zig` on PATH. A build step cannot bootstrap the thing that runs
  build steps.

★★★ **THE DUPLICATE THAT SURFACED BY ACCIDENT.** Adding a step per fast-test root made
`zig build` REFUSE TO CONFIGURE - "a top-level step with name zn-zimrmath already exists" -
because `zimrmath.zig` and `zimrnum.zig` were each listed TWICE in `fast_test_roots`.
`test-fast` had been building and running both of them twice over, for who knows how long. A
duplicate in a list of strings is invisible; a duplicate in a list of NAMES is a hard error.

★★★ **THE TRANSPILER NOW READS ITS OWN OUTPUT BACK: `checkNonFiniteConstants`.**

`src/spv2wgsl.zig` refuses to return WGSL containing a spelling a device has rejected. Two
entries today, both of which cost a debugging cycle:

    return nan;                       a bare non-finite token - WGSL has no such literal
    bitcast<f32>(2143289344u)         a const-expression that folds to an unrepresentable value

It is NOT a WGSL validator and does not try to be one. It is a list of things THIS transpiler has
emitted and a device has actually refused. The point is that the second occurrence costs a build
failure rather than a round trip through a phone. Plant-verified: reverting `nonFiniteName` to
the const-foldable form now fails `zig build` with `spv2wgsl: WgslNonFiniteConstExpr`.

★ **IT IS A HARD ERROR, DELIBERATELY, UNLIKE `checkOutputClosure`.** That neighbouring check runs
only in `.debug` and only WARNS, returning the bad WGSL anyway because "the browser's WGSL
frontend rejects it at pipeline creation if it actually matters". It does matter, and the
rejection names no cause - that reasoning IS the three round trips. There is no use for WGSL that
cannot compile, so this one fails in every mode.

★★ **A LINT RULE WOULD HAVE BEEN THE WRONG ANSWER, and it was considered.** `nan(f32)` inside a
kernel is CORRECT - `diff` of n values genuinely has one slot with no answer, and the host writes
NaN there on purpose. The bug was never in the kernel; it was in how the transpiler spelled the
constant. A rule flagging kernels that use `zm.nan` would fire on legitimate code forever and
teach people to silence it. **Check the layer that was wrong, not the layer that was nearby.**

★★★ **`createShaderModule` NEVER THROWS - ASK `getCompilationInfo()` OR YOU GET THE CASCADE.**

A WGSL module that failed to compile is returned as a live object. The first thing anyone hears
is one call later:

    [Invalid ShaderModule "diff_forward"] is invalid due to a previous error.

**"a previous error" is literally the whole message.** The actual diagnostic - with a line and a
column into the rejected WGSL - sits in `module.getCompilationInfo()`, and nothing was asking.
`src/bridge.zig`'s `jsDeviceCreateShaderModuleWgsl` now attaches a reporter that routes errors to
`window.__wzFail`, the page's existing full-screen surface. It is a Promise and the bridge call
is synchronous, so it fires a moment later - order on screen is not the point, having the
message at all is.

★ **This cost two device round-trips.** A NaN-literal bug was found by reading transpiler output
by eye, fixed correctly, and the SAME cascade came back - because a second problem in the same
module was never being printed. Reading generated code by eye is what you do when the tool that
knows the answer has not been asked.

★★ **AND VERIFY THE ARTIFACT, NOT THE BUILD COMMAND.** A standalone page is base64 wasm; grepping
the HTML for `bitcast<f32>` finds nothing whether or not the fix is in it. Decode the blobs:

    python3 -c "import base64,re; s=open(P).read(); print(sum(base64.b64decode(b).count(T)
      for b in re.findall(r'\"([A-Za-z0-9+/=]{2000,})\"', s)))"

I shipped a page as fixed without doing that, and an `&&` chain had silently skipped the copy on
a failed lint, so the file handed over was the previous build.

★★★ **WGSL HAS NO NaN OR INFINITY LITERAL, AND spv2wgsl WAS EMITTING ONE.**

`renderConstant` printed a float with `{d}`, which renders a NaN as the text `nan`, and then
checked the spelling for any of `".eEnN"` to decide it was "already formatted" - so `nan` and
`inf` were returned VERBATIM. The emitted WGSL was `return nan;`. That is not an identifier, a
keyword or a literal in WGSL; the spec has no way to spell either value.

★ **Nothing in this repo parses the WGSL it produces**, so the failure was invisible to every
gate: `zig build check`, the corpus, the smoke test and the SPIR-V probe all passed. It surfaced
only on a real device, as

    [Invalid ShaderModule "diff_forward"] is invalid due to a previous error
    - While validating compute stage ... entryPoint: "diff_forward"

Every kernel touching `zm.nan` was affected. The sweep's `diff` row is the one that reached a
browser, because `diff` of n values has one slot with no answer and the host writes NaN there.

★ **AND `bitcast<f32>(2143289344u)` IS NOT THE FIX EITHER.** Tint rejects it too:

    :156:10 error: value nan cannot be represented as 'f32'
      return bitcast<f32>(2143289344u);

**A bitcast of a LITERAL is a const-expression**, so it gets folded at compile time, and a WGSL
const-expression must be representable - which is precisely what a NaN is not. Nor does a
module-scope `var<private> x: f32 = bitcast<f32>(...)` help: a module-scope initializer must
ALSO be a const-expression, same fold, same rejection.

The escape is a FUNCTION-SCOPE `var`, which is runtime storage:

    fn nonfinite_2143289344() -> f32 {
      var b: u32 = 2143289344u;
      return bitcast<f32>(b);
    }

The constant evaluator never sees it. The DEVICE has no trouble with NaN at all - only the
compiler's const-eval does. `spv2wgsl` emits one helper per distinct bit pattern, so a module
using NaN five times declares it once and `+inf` never collides with `-inf`.

★ **`std.math` IS ALLOWED IN `src/spv2wgsl.zig`** (file-level `lint:off`, like `tools/c2js.zig`):
it is a host-only transpiler that never reaches a device, so the GPU-portability reason does not
apply. And unlike a `zm` dependency it costs NOTHING - `std` is already imported, so the file
stays as extractable as it was. I reached for `zm.isFinite` first and had to back it out; the
distinction is module edge versus namespace, not std versus not-std.

★★★ **THE ADVANTAGE OVER znum IS NOT PARITY, IT IS THE DYNAMICS.**

znum's continuous-control gate trains a **point mass in R^3** - position in, clamped velocity
out. That is all it has: znum contains NO articulated-body dynamics. `src/robot.zig` is 128
public declarations of `forwardDynamics`/`inverseDynamics`/`step` with MJCF and URDF loading and
MuJoCo-generated fixtures.

**A policy trained against verified articulated dynamics, in one binary, with the physics under
test by the same suite, is a category znum cannot reach** - and both halves are already here.
When zimrnum's RL work is ranked, rank it by what gets to that gate.

★ **AND zimrnum CAN BE BORN WITH znum's BUGS FIXED.** `RL_REVIEW.md` is an adversarial
self-review; its findings are free design constraints. The one that matters most: znum's
`ReplayBuffer` carries ONE `done` flag and therefore cannot distinguish "the episode ended" from
"we cut it at the horizon" - zeroing the bootstrap on a horizon cut teaches the critic the world
ends there. znum calls this structural. **zimrnum's `ReplayBuffer` is a raw ring with no flag
yet**, so carrying `terminal` and `truncated` separately is free TODAY and expensive once
callers exist.

★★★ **A STRUCT-FIELD DEFAULT IS NOT AN INITIALISER WHEN THE CALLER HANDS YOU ZEROED MEMORY.**

`dance_track` declared `kp: f32 = 400.0` and shipped with `kp 0` - `.memory = .managed` gives
`init` a zeroed State and the declaration never runs. No torque at all, a limp ragdoll, and a
source file that read as if the gains were set.

★ **A number on screen that disagrees with the source beats any amount of reading the source.**
The panel was added for a different reason and found this in one glance; it had been wrong since
the example first compiled.

★★★ **KEEP SOURCE DATA IN SOURCE UNITS; CONVERT AT THE POINT OF USE.**

A BVH skeleton drew as a sprawling mess because each bone OFFSET was converted to metres and
Z-up, then rotated by a rotation still in the file's own Y-up frame. **Rotating a Z-up vector by
a Y-up rotation is not a small error - it is a different animation.**

★ The engine's own `bvhForwardKinematicsFromRotations` has the identical recurrence and no such
bug, because its offsets and rotations were loaded into the SAME space. It never converts
mid-walk because it never has two spaces to be between.

★★ The same applies to any value with two consumers wanting different units: converting early
forces one of them to convert back, and **a value that is converted, unconverted and reconverted
is one whose frame nobody can state.**

★★★ **A SMOKE "LEAK": READ BOTH SIDES, THEN RUN `--leak-trace` - DO NOT HAND-INSTRUMENT.**
Every managed smoke prints `live bytes after each deinit: example X -> Y, engine A -> B`. The
example and the engine have SEPARATE counters (`App.gpa` / `App.engine_gpa`): example growth is a
deinit that missed something; ENGINE growth is the engine keeping memory an example caused, which
zimr forbids (examples own their memory). A `WRONG-ALLOCATOR FREE` is memory freed through the other
side's allocator. To see WHAT survived, run the smoke runner by hand with `--leak-trace` (the command
is printed in a failing smoke's `failed command:` line; a passing one does not print it):

    node webtests/runner.mjs <bundle> --web-dir=zig-out/wgpu-smoke/web --frames=5 --focus=<ex> --leak-trace

It prints each block the second lifecycle made and kept, with side, phase and subsystem scope, and
flags a container that GREW (an allocation that replaced an older same-scope block). The glyph-atlas
leak that took an hour by hand reads as one line:
`engine +11532 bytes  frame: glyph_cache - replaced a 5772-byte block ... probably a container that GREW`.
Give a subsystem its scope with `memwatch.pushScope(gpa, "name")` / `popScope(gpa)` at its entry
point (a no-op unless tracing). Plan and history: `src/notes/memory_ownership_plan.md`.

★★★ **INSTALL A PANIC HANDLER BEFORE DEBUGGING ANY WASM BUILD.**

A Zig safety trap in wasm is a bare `RuntimeError: unreachable` - no message, no line, no stack.
Six turns went to bisecting a panic that named itself in ONE build once
`pub const panic = std.debug.FullPanic(common.reportPanic)` existed. An example is the root
module of its own binary, so the handler goes in the example; the function lives in
`example_common`.

★★ **AND `usize` IS 32 BITS ON WASM, 64 NATIVELY.** That was the bug underneath: a contact id
passed through a `usize` parameter, masked to 48 bits, silently fine on one target and trapping
on the other. **An id is not a size** - `usize` means "big enough to index memory" and nothing
else. Any id, key, hash, handle or packed field typed `usize` is the same bug waiting.

★ The general rule: **when a build target differs from the one you test on, the differences are
a checklist, not a surprise.** For wasm: `usize` width, `@intCast` traps, no stack traces.

★★★ **BUILD THE KNOWN-GOOD DEMO BEFORE DEBUGGING YOUR OWN.**

`dance_track`'s panel was invisible across three device runs and two theories. Building
`quadruped-standalone` and diffing its update against mine found both causes in one build:
a missing `ui_host.render`, and an `endDrawing` the runtime already does.

★ **Two bugs whose symptoms cancelled.** Without `render` the panel was silently absent; the
moment `render` was added the stray `endDrawing` turned silence into a crash. Either alone would
have been obvious - together they read as "the panel does not work".

★ The general move: **when something in your code does not work and an engine demo does the same
thing, diff the two before forming a theory.** It is one build and it compares against something
known to be right, which no amount of reading your own code does.

★★★ **BISECT THE FRAME FUNCTION; DO NOT THEORISE ABOUT `unreachable`.**

A wasm panic surfaces as a bare `RuntimeError: unreachable` with no stack, and three rounds of
reasoning about which index might be out of bounds produced nothing. Cutting the frame function
in half twice - setup only, then setup plus the controller, then everything - located it in
minutes.

★ **And the linter had been pointing at the cause the whole time.** `@intFromFloat` is
`unreachable` on a NaN or out-of-range value; the `int-from-float` rule flags it as redundant
where the destination type is pinned. **A rule that reads like style was describing a crash** -
worth reading lint output for what it implies, not only for what it asks.

★★★ **READ THE INTERFACE BEFORE WRITING AGAINST IT - GUESSING COSTS A REWRITE EVERY TIME.**

Two drafts parked in one session, both from the same cause. A retarget tool written against
guessed API names used an identity rest alignment where a real T-pose offset was required - it
would have produced a character moving plausibly and WRONGLY. A second draft assumed
`robot_mjcf` was a module; it is a file inside `robot`, and every import route from `tools/` is
closed.

★ The tell is that the MEASUREMENTS in the same session were all reliable, because a measurement
cannot be guessed - it either runs or it does not. **Code written against an inferred interface
compiles, looks finished, and is wrong in a way no test written by the same guess will catch.**

★★ **And check whether the problem exists before solving it.** The tool was precomputing a
retarget that costs 1.8 ms - about 126 physics steps, against 2,400 for one pass over the clip.
Two attempts at a file format, a build step and a checked-in asset, for a cost nobody had
measured.

★★★ **A STRUCT LITERAL EVALUATES ITS FIELDS IN ORDER, SO COPYING A BUILDER BEFORE CALLING IT
AGAIN LOSES THE LATER WORK.**

    return .{ .graph = g, .loss = try g.mseLoss(pred, y) };   // WRONG

`.graph = g` copies the graph, THEN `mseLoss` appends nodes to the original. The returned copy
does not contain its own loss, and `backward` indexes past the end of `values` - an
out-of-bounds panic hundreds of lines away with no stack pointing at the cause.

★ The rule: **build everything first, then write the literal.** Any field whose expression
mutates another field's value is a field evaluated too late.

★★ **A NUMERICALLY DELICATE FORMULA WRITTEN TWICE WILL BE IMPROVED IN ONLY ONE PLACE.**

softplus existed three times: a tensor op in zimrnum with the scalar inline, a private helper in
`SquashedGaussian`, and a hand copy inside `squashCorrection` written when a kernel needed one.
All three used the stable shifted-`log1p` form - this time. The next improvement would have
landed in whichever copy the author happened to be looking at.

★ The move is not "extract every repeat" but: **when a formula was CHOSEN over an obvious
alternative for numerical reasons, it gets exactly one home** - and if a shader might need it,
that home is the shader-safe module.

★★★ **A TEST THAT ONLY EXERCISES AN OPERATION'S FIRST CALL VERIFIES THE ONE CALL THAT BARELY
MATTERS.**

Our `adam step` conformance row filled both moments with zero - the state that holds for exactly
one update per training run. The kernel was written to match, and so was structurally incapable
of a second step. `polyakUpdate` had no row at all, and at update 1 it moves a value to itself.

★ The pattern to look for: **an operation whose behaviour DEPENDS ON ACCUMULATED STATE is a
different function on its first call than on its thousandth.** Optimiser moments, target-network
follows, running normalisers, schedulers. Test the warm path explicitly, because the cold one is
both easier to write and nearly worthless.

★ A predecessor project lost eleven hypotheses to a GPU trainer that learned correctly for one
update and then diverged. That is the symptom this class of gap produces.

★★ **A NAME THAT PICKS ONE OF TWO CASES CONTRADICTS ANY DOC SAYING THEY ARE ONE.**

`ddimStep` implemented DDPM too - `eta = 0` is DDIM, `eta = 1` is DDPM - and the doc comment said
so, two lines under a name that had already chosen. Renamed `diffusionReverseStep`.

★ The check is mechanical: **if the doc has to explain that the name is only half the story, the
name is wrong.** Same for abbreviations - `cartpoleContStep` made every reader guess at `Cont`
to save eight characters in a file where nothing else is short.

★★★ **A DOC COMMENT THAT DESCRIBES BEHAVIOUR IS A CLAIM, AND AN UNTESTED CLAIM ROTS SILENTLY.**

`discriminatorReward`'s comment said a zero floor "is refused". It was not - the function is
scalar-first and has no error union to refuse with. Every other property of that function had an
assertion; this one had a sentence, and the sentence was wrong from the moment it was written.

★ The tell is grammatical: **"is refused", "must be", "cannot happen" are assertions in prose.**
Either the code enforces them - in which case a test can check it - or the comment is describing
a precondition and should say so. The whole argument for writing reasoning into this codebase is
that it can be checked; a sentence nobody can run is the one kind of comment that gets away.

★★★ **WHEN AN RL POLICY WILL NOT LEARN, CHECK THE EXPLORATION SCALE BEFORE THE LEARNING RATE.**

AWR on cartpole reached a recognisable controller SHAPE - right signs, sensible relative
magnitudes - and the return did not move. Two attempts went into the learning rate. The actual
cause was that `sigma = 0.5` let the policy sample only forces near zero, on a task whose useful
range is +/-10 N: **it never observed what a real push does, so it had no gradient toward one.**
Raising sigma to 2.0 doubled the return immediately.

★ The general form: a policy cannot learn from an action it never takes. When the weights look
right and the returns do not move, the question is whether the action distribution covers the
part of the space where the reward changes - not whether the step size is large enough.

★★★ **WHEN A DEVICE DISAGREES, CHECK THE ARITHMETIC BEFORE THE TOOLCHAIN.**

The sweep's `diff` row reported a finiteness mismatch. The search went: the SPIR-V transpiler
(recently fixed, phi handling is genuinely hard), then the driver (fast-math assumptions eat
NaNs), then - last - what the two sides actually compute. **The kernel tested `id == 0` for a
hole that `zn.diff` puts at column 0 of EVERY ROW.** Sixty-three rows disagreed, in two ways at
once, and the arithmetic was the cheapest thing to check and the last thing checked.

★ Suspicion follows MEMORY rather than probability. A hard bug in area X makes X the available
explanation for the next symptom, however unrelated. The counter is mechanical: **before blaming
a layer, write down what each side computes and compare those.**

★ A one-row diagnostic that removes everything except the question - here `nan direct`, a bare
`nan(f32)` store with no branch and no call chain - is worth more than an hour of hypotheses. It
cost one kernel and eliminated the driver entirely.

★★★ **A SCANNER THAT MATCHES AN EXACT TAG STOPS SEEING THE DOCUMENT WHEN THE TAG GAINS AN
ATTRIBUTE - AND REPORTS SUCCESS WHILE DOING IT.**

`tools/zimrnum_ref.zig` looked for the literal `"<pre><code>"`. The docs restyling gave every
block a `class="zig"`, and **148 of the tutorial's 241 examples silently stopped being checked**
- arity included. The tool found the 93 bare ones, checked those, and printed a success line.
Source folds went 46 -> 290 when it was fixed to match `"<pre><code"` and skip to the `>`.

★ `doc-sync` had the SAME bug for the SAME reason and was fixed three weeks earlier. Two
scanners, one restyling, one lesson not carried across. **When a document's markup changes,
grep for every tool that parses it**, not just the one that broke.

★★★ **`test` AND `test-fast` ARE COMPLEMENTARY, NOT NESTED. NEITHER IS "THE FULL SUITE".**

(HISTORY - superseded Sep 26: `test` now depends on `test-fast`, see "HOW TO RUN TESTS". What
follows is why that edge was added: the blindness it describes is real whenever a step runs one
half without the other.)

Measured, not assumed - `zig build … --summary all` shows the shape:

    zig build test        ONE test binary, rooted at src/tests.zig
    zig build test-fast   SIX test binaries: zimrnum, zimrmath, robot, codecs, physics, …

`src/tests.zig` contains **zero `test` blocks** - it is 56 `refAllDecls` calls - and it
**never mentions zimrnum**. So `zig build test` compiles and exercises the render/engine
half and is BLIND to the numerics/physics half. Touch `src/zimrnum.zig` and it finishes in
2 s having rebuilt nothing.

★ That blindness cost a turn: a `numericalGrad` conversion that wrote through a
`@constCast` const array passed `zig build test` TWICE and was caught only by the gate,
which runs `test-fast`. An earlier note here claimed `test` was "the only complete compile
check"; it is complete for what `tests.zig` imports and for nothing else.

**The rule: after editing a file, run the step that actually builds it.** For the shader
half that is `zig build test`; for zimrnum/zimrmath/robot/codecs/physics it is
`zig build test-fast`; for an example it is that example's smoke.

★★ **FOR ZIMRNUM WORK, SKIP THE BUILD GRAPH ENTIRELY.** `zimrnum.zig` imports `std` and
`zm` and nothing else, so it can be its own test root:

    zig build zn-<stem> -Dgate=false [-Dtest-filter=…]

There is one per fast-test root - `zn-zimrnum`, `zn-zimrmath`, `zn-robot`, and nine more.
Measured after a real edit to zimrnum: **21 s filtered, 71 s for all of its tests, ~1 s when
nothing changed**, against `test-fast`'s 71-212 s for all six modules. `-Dgate=false` skips
the lint/fmt pass that otherwise precedes every compile.

★ Finding these required adding them: `zig build` REFUSED TO CONFIGURE with a duplicate step
name, which is how it came out that `zimrmath.zig` and `zimrnum.zig` were each listed TWICE
in `fast_test_roots` - `test-fast` had been building and running both of them twice over.

Run `zig build test-fast` before calling something done; it is the step the gate runs.

★ **`@TypeOf(map).GetOrPutResult` over the spelled-out map type.** An annotation that
repeats a declaration can drift from it, and did: a `u64` annotation sat over a `u32`
map in zimrnum. `@TypeOf` cannot. Note it is `@TypeOf(map)`, not `@TypeOf(map.*)`, when
the map is a local rather than a pointer parameter.

★★ **`tools/lint_baseline.tsv` IS A RATCHET, NOT A SUPPRESSION LIST.** Fixing the
walk exposed 594 pre-existing violations — the tree was never clean, the walker was
blind, and the hard gate's "after all rules cleared" was true only of what it could
see. The baseline records a count per (file, rule); anything ABOVE it fails, so new
code is held to every rule from today. Keyed by file and rule rather than line, so
an unrelated edit that moves a line does not spuriously fail. Regenerate
deliberately, never casually:

    zimrlint --baseline tools/lint_baseline.tsv --write-baseline <files...>

★★ **std.math IS NOW ZERO TREE-WIDE**, which had never been true. 43 call sites
moved to `zm` across `src/`, `examples/` and `tools/` — floats (`clamp`, `isNan`,
`isInf`, `isFinite`, `floatMax`, `nan`, `pi`) because they are why the rule exists,
and the comptime helpers (`maxInt`, `Log2Int`) because the destination is ONE math
module. zimrmath already had all of them. `tools/mesh_bake.zig` and `tools/c2js.zig`
gained a `zm` import in build.zig to get there: a host-only tool is no exception,
since the point is that one module is the answer to "where does this live", not that
portability happens not to bite in that file.

The tension: **discoverability** wants the alias to EXIST (`zm.mix` should resolve, or people
hand-roll duplicates — which is exactly what happened with `step`/`stepEdge`); **consistency**
wants ONE spelling in the codebase. Both, via a dead decl that teaches:

    pub fn step(edge: f32, v: f32) f32 { ... }        // CANONICAL (was `stepEdge`)
    pub inline fn clamp01(v: anytype) @TypeOf(v)      // CANONICAL, now vector-generic
    pub const stepEdge = @compileError("zimrmath spells this `step` — use `zm.step`");
    pub const saturate = @compileError("... use `zm.clamp01` ...");
    pub const mix      = @compileError("... use `zm.lerp` ...");

Why this beats a lint rule for "force people to use lerp":
1. It is a COMPILE error — cannot be skipped, no linter run needed, fires in the editor.
2. The name still RESOLVES: `@hasDecl` sees it, autocomplete lists it, and a first guess of
   `zm.mix` TELLS you the house name instead of "no member named 'mix'".
3. Zero linter machinery; every future alias is one line.

**Do NOT make `step` a linter KEYWORD.** A keyword is RESERVED (`reserved-math-names`: no other
decl/local may bear the name). Measured collisions: `zimrphysics2d.step(world, dt)` (the public
physics world-step — Box2D spells it the same way), `draw2d`'s dash `step`, `compute_host`'s
`step`. Reserving the word would force renaming a core physics API to satisfy a math linter.
`step` and `mix` are ordinary English words with legitimate non-math meanings — which is exactly
why they were excluded originally. That call was RIGHT; the bug was that `step` did not exist
under a findable name, not that it wasn't reserved. Keywords are for DISTINCTIVE math words
(`dot`, `cross`, `atan2`, `lerp`, `clamp01`), where reserving them costs nothing.
`saturate` was REMOVED from the keyword list (a @compileError decl cannot be aliased/used).

### zimrmath discoverability — a standard op under a non-standard name is INVISIBLE

`step` was already there as `stepEdge`; I searched for `step`, did not find it, and
hand-rolled a duplicate in a shader. Then the compiler revealed that `saturate` and
`lerp` were ALSO already there — my `grep '^pub fn X'` had missed them because they
are declared **`pub inline fn`**. The grep lied three times.
FIX (three layers):
1. `pub const step = stepEdge;` / `pub const mix = lerp;` — only TWO names were
   genuinely absent. The name you TYPE now exists, aliased to the implementation
   that was already there (nothing calling `stepEdge`/`lerp` breaks).
2. A greppable **GPU-MATH VOCABULARY index** in zimrmath's header, listing the
   GLSL/HLSL spelling -> the zimr name (incl. "abs/min/max/sqrt are Zig BUILTINS,
   deliberately not wrapped").
3. A `@hasDecl` test in features_test.zig pinning the whole vocabulary. **@hasDecl
   cannot be fooled by a non-standard name OR a bad grep pattern** — which is the
   real lesson: don't discover an API with grep, ask the compiler.


### GPU VALIDATION IN THE SANDBOX — the class of bug that only showed on device
**Symptom (device only):** `Attachment state of [RenderPipeline "fx_mask"] is not
compatible with [RenderPassEncoder]` — the pipeline was built with
`depthStencilFormat: Depth24Plus` but the open pass had no depth attachment.
**Cause:** `effects2d.load` HARDCODED `.less` + `.depth24_plus` into every
pipeline's StateCombo. That works only for apps with `.depth_format = .depth24_plus`
(shader_effects); an app with `.depth_format = null` (any UI/2D app) gets a
depth-LESS render texture — `loadRenderTexture` sets `.with_depth =
app.gpu_frame.depth_format != null` — and the pipeline is then incompatible.

**THE TWO-LAYER FIX (this is the pattern for this whole class):**

1. **Make it impossible by construction.** `Host.init` now takes `gl`, not a bare
   device, and reads `wgpu_app.appOf(gl).gpu_frame.{device, depth_format}` — the
   ONE source of truth. The caller is never asked for something it can get wrong.
   The pipeline now mirrors renderer_2d exactly:
       `if (depth_format != null) .always else .none`   // DepthMode
       `depth_format orelse .undefined_`                // TextureFormat (0 = no depth)

2. **Teach the SANDBOX the rule the browser enforces.** `webtests/runner.mjs` now
   implements WebGPU's attachment-compatibility check with pure bookkeeping — no
   GPU needed — because BOTH sides are visible to the shims:
     - `js_device_create_render_pipeline(..., descPtr, descLen, labelPtr, labelLen)`
       carries the descriptor blob -> forward-parse `gpu.zig`'s SECTION-3 format to
       get `depth_format` / `sample_count` / `color_format`. (Parse FORWARD: the
       tail is variable — depth-compare string, constants, extra color formats.)
     - `js_encoder_begin_render_pass(..., depth_view, resolve_view)` — `depth_view
       == 0` means no depth.
     - `js_render_pass_set_pipeline(pass, pipeline)` is where the browser rejects,
       so that is where we compare.
   A mismatch pushes `!ASSERT gpu-validation: ...`, which the EXISTING `!ASSERT`
   channel in wgpu_smoke.zig already turns into `✗ FAIL`. **Zero Zig changes.**
   PROVEN: it reproduced the device error in-sandbox on the broken build, and went
   green on the fix (red->green, so it is a real gate, not a tautology).

**GENERAL LESSON:** when a bug is only catchable on the device, ask whether the
sandbox can already SEE both sides of the rule. Here it could — the shims get the
descriptor and the attachments. Same move as `verify_imports.js` (derive the
requirement from the wasm, don't trust the stub). A stub that always succeeds is
not a test; a stub that enforces the real API's contract is.

### effects2d — the 2D effect runner is ENGINE now, not userland (raylib-shaped)
`src/effects2d.zig` + `z.effects2d`. Every effect gallery used to hand-roll its own
bind-group layouts, uniform buffers, pipeline layout, fullscreen quad, and then
drive `setPipeline` / `setBindGroup` x3 / `setVertexBuffer` / `draw` by hand — GPU
plumbing living in an example. Now:

    z.beginTextureModeRaw(gl, target, clear);
    z.effects2d.beginShaderMode(gl, &host, fx);   // raylib BeginShaderMode
    z.effects2d.drawFullscreen(gl);               //        DrawTextureRec
    z.effects2d.endShaderMode(gl);                //        EndShaderMode
    z.endTextureModeRaw(gl);

`Host.init(gpa, device, vs_wgsl)` -> `Host.load(...) !Effect` -> `Effect.setValues`.
BINDING CONTRACT (what `effect_common_io.zig` already declares): @group(0) empty,
@group(1) = source texture + sampler, @group(2) = the effect's uniform block.
The VS wgsl is a PARAMETER, not an `@embedFile` — the generated `.wgsl` is a build
artifact handed to modules by `wireEngineWgsl`, so taking it in keeps the engine
module free of build-graph knowledge.
- **The quad is NDC POSITION ONLY** (`[2]f32`, one attribute). `deferred_shading_vs`
  derives the UV from clip position; shipping a UV attribute fails pipeline
  validation against the VS's declared inputs. (Caught this before device.)
- `Host.setSource` DESTROYS the previous bind group — the hand-rolled version it
  replaced leaked one bind group per resize.
- **`std.EnumArray(Mode, Effect)` for the effect table.** The old `[N]Effect` +
  `switch (mode) => index` map meant adding one effect required editing four things
  in lockstep (array, length, index map, ubo writes) and any one could silently
  drift into a wrong-pipeline-at-runtime. EnumArray makes the mapping total and
  compiler-checked. Ubos are addressed `s.fx.get(.ascii).ubo`, not `s.effects[7]`.
Net: shader_effects.zig 620 -> 477 lines; 285 reusable engine lines.
STYLE: `@trunc` is the house form for float->int, NOT `@intFromFloat` (Simon).

### Build & disk economics (measured, 1-core box)

| what | cost |
|---|---|
| warm no-op rebuild | **1s** |
| edit one example -> standalone (no UI) | **~7s** total, wasm compile **3s** (MaxRSS 193M) |
| edit one example -> standalone (with `z.UiHost`) | **~15s** total, wasm compile **10s** (MaxRSS 309M) |
| build runner alone (compiling `build.zig` into an exe) | **~107s** cold — paid before any step runs |
| `zimrlint` compile / run over ~450 files | **43s** / **8s** |
| `zig build lint` from cold | **~158s** |
| FULL cold rebuild after `rm -rf .zig-cache` | **~17 min** |

(`--summary all` only prints on COMPLETION, so a >170s cold chain shows nothing — profile warm.)

- **The wasm compile dominates** (~70% of a warm rebuild). The tools are cached and cost
  milliseconds; `c2js` is a flat ~2s.
- **Opt mode is NOT the lever.** `-Dmode=debug` compiles in the SAME 10s and uses 2.4x the RAM
  (747M vs 309M). It buys nothing and risks OOM.
- **Cost scales with what the example PULLS IN**, not with engine size — Zig's lazy analysis.
  Pulling in `ui.zig` roughly TRIPLES the compile (3s -> 10s). Worth it for phone testing, but
  budget for it.
- **1 core, ~3.9 GB RAM.** `-j1` is forced by the CPU, not memory. Parallelism is unavailable.
- **Prefer the LAUNCHER over N standalones** when exercising several examples:
  `buildUserModShared` memoizes the shared modules, so engine+UI compile ONCE.
- Untried levers, best first: `-fincremental` / `--watch`; pinning native tool binaries into
  `tools/bin/`; `-ftime-report` to decide between attacking analysis or codegen.

**★ MATCH A TOOL'S OPTIMIZE MODE TO ITS RUNTIME, NOT TO A BLANKET POLICY.** `gen_externs` is
compiled once per shader (~45) because it reflects over the schema at comptime — that duplication
is correct. But each exe RUNS FOR 1 ms, and it was built `ReleaseFast`: LLVM spent ~17.6s
optimizing std *per shader* = **~13 minutes of every cold build**, to make a 1 ms script 0 ms
faster. Now `.optimize = .Debug, .strip = true`: **0.46s per shader**, smaller binary, stronger
safety checks, byte-identical output. `zimrlint` and `c2js` DO earn their optimization — the rule
is runtime-proportional.

**Disk — the hogs are NOT zimr.** Volume ~19G; zimr is <1G. Zig's GLOBAL cache
(`/root/.cache/zig`) is only ~86M, so clearing it frees nothing. Reclaim in this order:
`zig-out` -> `/tmp` scratch -> old zips in outputs -> non-zimr caches (`~/.cache/uv` 1.5G,
`~/.cache/puppeteer` 581M, `~/.npm-global` 749M). `/home/claude/study/` (3.5G, the Rust toolchain
and wgpu-trunk used to build naga) is the biggest single reclaim — **ask before deleting**, and
keep `dawn-main`, `SPIRV-Tools-main`, `corpus_wgsl`, `spv2wgsl_audit.md`. The project
`.zig-cache` is the LAST resort; see "Disk and the zig cache" for how to prune it safely.

**The build guard measures the HAZARD, not a proxy.** `checkDiskSpace` fails only at >=90% full,
via one O(1) `statfs(2)` — cheap enough to run every build. It replaced `checkCacheSize`, which
failed at 6GB of cache: a bad proxy that fired on healthy disks and whose remedy cost a full cold
rebuild. Zig's std has NO statfs wrapper; the ABI struct is spelled out in build.zig.

## A SENTINEL MAY BE DOING WORK THE TYPE DOES NOT EXPLAIN

`argminAll` seeded its running best from `inf(T)`, which is what made it float-only. Replacing
that with the first element looked like a pure simplification - no sentinel, works for integers,
strictly less code - and it CHANGED THE ANSWER.

Seeded from an infinity, a NaN never wins a comparison, so a leading NaN is skipped. Seeded from
element zero, a leading NaN IS the incumbent and nothing can beat it, because every comparison
against a NaN is false. **The infinity was not a float artefact, it was NaN handling wearing one.**

The fix is to say it directly: `x < best or (comptime isFloat(T)) and isNan(best)`. Integers have
no NaNs and the branch folds away.

An existing test caught it. Before removing a constant that looks decorative, ask what it is
comparing against and what happens when that comparison is false.

## REMOVING A TYPE MEANS THREE PLACES, AND A BLANKET RENAME DAMAGES PROSE

Deleting `Scope` from the source left it in two others:

- **The tutorial's hand-written sections.** The reference table is generated and self-checking, so
  the drift gate caught the missing rows - but sections 6.2 and 6.3 were WHOLE PAGES about a type
  that no longer existed, plus two table-of-contents entries and a code sample in section 7.1.
  Nothing checks those.
- **Doc comments quoted into the tutorial as source folds.** One of them read "usually that is a
  `arena`" - because my blanket `Scope` -> `arena` regex rewrote prose as well as code. Three
  lines damaged, and they render in the tutorial.

**A rename that touches identifiers must not touch prose**, which is the first mishap of this
session recurring: grep the result for `a \`arena\`` and `a arena` shapes before moving on.

The audit that found them: grep the tutorial for the removed name, then for every term whose
meaning changed - `Gumbel`, `pole_turns`, `keepdims`. The survivors were all deliberate historical
notes, which is the right outcome: **a record of a withdrawn decision is not a stale reference.**

## A COUNTER MAINTAINED AT N CALL SITES IS WRONG AT THE N+1TH

I replaced the sweep's fixed six settle frames with a dispatch counter, incremented it at the
batched submit, and shipped. **7 of 105 on device** - `inf` against bars of zero.

There are TWO submit paths. `run()` outside a batch takes the other one, so `submitted` stayed
zero, the wait condition was `0 >= 0`, and every row retired before its own work executed.

**Worse than no counter**, because the fixed wait it replaced at least erred toward being late. A
wrong guess is slow; a wrong proof is silent.

The fix is not "increment in both places" - that is the same fragility with a longer fuse. One
`submitDispatch(gp, cmd)` helper submits and counts, both sites call it, and the readback copy
deliberately does not. **Make the omission impossible, not merely corrected.**

⚠ And verify the frame ORDER before believing the new wait: dispatch, then poll, then read the
generation. I checked the character offsets rather than assuming, because "it should be fine either
way" is how the first version got shipped.

## NEVER `cut` A DIAGNOSTIC

I piped lint output through `cut -c1-102` all session. The `int-from-float` message reads

    @intFromFloat is redundant - @trunc/@floor/@round/@ceil convert to int directly; write e.g. @trunc(x)

and I only ever saw `@trunc/@floor/@round/@ceil co`. Then I GUESSED the rest - twice, in opposite
directions: once deleting a `@floor` that should have stayed, once adding a `@trunc` that should
have been the whole expression.

The rule's body, which I never opened, already says **"THE ONE DECISION (don't overthink this - it
cost a full turn once)"**. Someone had already lost a turn to this and written down the answer.

**Truncate listings and inventories; never an error message.** The part past column 100 is usually
the part that says what to do. Same failure as asserting what a doc comment said without reading
it - here I had made it unreadable myself.

## `catch unreachable` IS GONE FROM zimrnum - 109 TO ZERO

`at(indices: []const usize)` returned an error for two reasons and only one was real. The rank
check existed ONLY because a slice hides its arity; the bounds check is what `data[idx]` already
does. **Nobody writes `arr[i] catch unreachable`.**

- `at1`/`at2`/`setAt1`/`setAt2` - the arity is in the NAME, so the rank check is comptime and the
  bounds check lands on the slice index where Zig puts it
- `offsetOf(indices)` - no error, for a coordinate whose rank and bounds are already an invariant.
  Every `flatIndex(walker[0..rank]) catch unreachable` was two impossible checks on the hottest
  line in the library

Cholesky's inner loop went from `(out.at(&.{ i, k }) catch unreachable) * (out.at(&.{ j, k })
catch unreachable)` to `out.at2(i, k) * out.at2(j, k)`.

⚠ A regex sweep over 300 call sites WILL be wrong. Three were - an optional paren ate `setAt`'s
closing one, `@abs(` got swallowed, and a walker rewrote a `try` that had no `catch` - and all
three were compile errors within one command. **The question is never whether the sweep is
correct, it is whether the wrongness is loud.**

## A GPU KERNEL CAN CALL THE HOST FUNCTION - zimrnum COMPILES TO SPIR-V

`cartpole_step` no longer restates `zn.cartpoleStep`'s arithmetic. It CALLS it. The GPU runs the
same code the CPU runs, and the sweep row compares a function against itself.

**Transcription is a second definition that can drift**, and it has already produced two bugs no
unit test could see: the `mesh_grid` buffer overrun and `slice_columns` dividing by the wrong
width. Both were transcription errors, not logic errors.

How it is wired:

- `ComputeKernel.wants_zimrnum` - opt-in PER KERNEL, because Zig rejects a `--dep` for a module
  the file does not import, so passing `zn` to all of them fails on the ones with no use for it.
- `addCompute` adds `--dep zn` to **root's** dep list AND `-Mzn=` further down.

⚠ **`--dep` attaches to the NEXT `-M`.** Declaring `-Mzn=` without a matching `--dep zn` before
`-Mroot=` gives the module a name without making it visible to the kernel, and the compiler says
`module "zn" declared but not used` - which reads like the FILE failed to import it when in fact
the root module's dep list was short. That cost several attempts.

Everything with a host twin can do this now.

## A HAND-BUILT COMPILE LINE IS NOT THE BUILD

Testing whether a SPIR-V kernel could import zimrnum, I ran `zig build-obj -ofmt=spirv` by hand and
got a **segmentation fault**. Then a smaller module: segfault. Then the control with the helper
inlined - which the real build compiles every day: **segfault too**.

That last one is what saved it. A control that fails proves the HARNESS is wrong, not the idea. The
missing flag was `-target spirv32-vulkan`; the build passes it and I had not.

**Without the control I would have recorded "the SPIR-V backend cannot do this" and moved on.**
When an experiment says no, run the case you already know says yes.

## A GATE THAT CHECKS NAMES IS NOT CHECKING AGREEMENT

The correspondence gate asserts every tensor op in `paired` has a zimrmath function of the same
name. It had never compared a VALUE - and `pow` disagreed with `zm.pow` for years of call sites:

    zn.pow(-2, 3)  ->  NaN     (computed as exp(3 * log(-2)), and log(-2) is NaN)
    zm.pow(-2, 3)  ->  -8

The doc comment called the NaN deliberate. It was not defensible once `zm.pow` existed and got it
right, and **nothing would ever have reported the divergence.** `pow` now delegates, and a test
sweeps 42 base/power pairs comparing both implementations - counting the negative bases so a sweep
that happened to contain no working one cannot pass vacuously.

**Pairing by name is a spelling check.** If two functions are supposed to be the same function at
different ranks, something has to compare their answers.

## `Scope` IS GONE - THE CALLER OWNS THE ARENA

zimrnum had a `Scope` wrapping `*std.heap.ArenaAllocator`, heap-allocated via `gpa.create` so the
`Allocator` interface stayed valid when the `Scope` VALUE moved. The idiom is:

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a: Allocator = arena.allocator();

**Three lines either way, and one fewer heap allocation.** Measured before removing anything:

| | |
|---|---|
| by-value arena moved, interface RE-MINTED | passes |
| by-value arena moved, interface CACHED | **aborts** - cached pointer at the old address |
| heap-held arena, interface cached | fine |

So the wrapper bought exactly one thing: a cached `Allocator` surviving a move of the value that
made it. **No caller did that.** All eighteen test sites read the interface in the same frame, and
the one real user - `zimrnum_train`'s `initState` - already took `s: *State`, so the arena goes
into its final home and the interface is minted from there. Nothing moves after the interface
exists, which is SAFER than the wrapper rather than merely simpler.

⚠ I got this wrong twice before measuring: I said zimrnum had no `Scope`, then that the
`gpa.create` critique did not apply to it. Ours was the heap-allocating one; znum's holds the arena
by value. **Two claims about our own code, neither checked.**

## A TWIN THAT PICKS ITS OWN PARAMETERS VERIFIES A DISPATCH THAT NEVER HAPPENS

Three of my new sweep rows went red on device, and two of them had headless twins measuring
EXACTLY ZERO.

`slice_columns` divides by `cols` to find its row. My twin set `cols` to the OUTPUT width. **The
sweep sets `cols` once, for every row, to the field's width** - so the kernel walked 32 rows of 64
where it needed 64 rows of 32. The twin was correct about a configuration nothing dispatches.

`mesh_grid_x`'s CPU reference passed the same buffer for both grids, so the row grid overwrote the
column grid. My twin used two buffers and passed.

**The twin must construct its parameters the way the host does**, not the way that makes the
kernel easy to call. Reading the host's param block and using it verbatim is the check.

⚠ And the third failure was the opposite lesson: `cartpole step` measured exactly zero on the twin
and 2.4e-7 on device - one ULP, and correct. The twin compiles the kernel FOR THE HOST, so `@sin`
is the host's library on both sides. **A twin cannot see a library difference, only an algebraic
one.** A kernel calling a transcendental needs a ULP bar, not a zero one.

## CHECK THE CLAIM YOU MAKE ABOUT THE THING YOU ARE IMPROVING ON

I replaced znum's `categorical` with Gumbel-max and wrote in the doc, the test AND the plan that
znum's version "would overflow at logits of 800". **It does not.** znum subtracts the maximum
before exponentiating, exactly as any correct implementation does, and returns the right ratio -
measured.

The divergence had no justification, and the version I replaced it with was WORSE: Gumbel-max
needs one random draw per CATEGORY where the cumulative sum needs one per sample. It also caused
a real bug - forty streams per draw needed a hash, the hash collided past thirty-one categories,
and 22% of the noise was reused.

**A claim about the code you are replacing is a claim, and it needs the same evidence as a claim
about your own.** Writing it into three places did not make it true; running it took one test.

## AN IMPROVEMENT IN THE API IS NOT AN IMPROVEMENT IN CAPABILITY

My cartpole is a pure function with named fields - genuinely better to use than znum's in-place
`[n_envs, 4]` tensor. But znum's steps **1024 environments in one GPU dispatch with zero
readbacks**, and mine steps one on the host.

That is not a design trade I made, it is a capability I do not have. The pure core makes adding
it cheap - a batch is a loop over it, and the host twin comes free - but until that exists the
honest statement is "better API, less throughput", not "better".

## CONSTANT FOLDING IS A DIFFERENT MACHINE - THREE TIMES NOW

Comptime-known operands do not behave like runtime ones, and every time I have checked a numeric
claim with literals it has told me the wrong thing:

1. `-7 / 2` on two `const` i32 printed -3, looking like Zig allows signed division. With runtime
   operands it is a compile error naming four functions.
2. The cartpole rate looked fine until the magnitude was computed by hand.
3. `1e8 + 1.0 * (1.0 - 1e8)` as a comptime expression gives exactly 1, so the lerp form looks
   lossless. Read the same values back from memory and it is not.

**If the claim is about float or integer ARITHMETIC, the operands have to come from memory.** A
`const` is folded at full precision and proves nothing about the type you named.

Note the module-var rule bans a file-scope `var` for this - read the value back out of a tensor
instead.

## TURNS FOR ANGLES THAT ARE DRAWN, RADIANS FOR ANGLES THAT ARE DIFFERENTIATED

The turns conversion was right for geometry: a quarter turn is exactly 0.25, `sinTurns` is exact
where `sin(tau/4)` is not, and the multiply-then-divide by tau disappears.

**A differentiated angle is the other case.** `d/dtheta sin(theta)` is `cos(theta)` ONLY in
radians; in turns it is `tau * cos`, and every derivative in a dynamics system picks up that
factor. The cartpole equations are differential equations, so radians are the unit in which they
have no constants in them at all.

I wrote cartpole in turns first and converted the angular acceleration on the way in. **That
conversion was a place to be wrong and it was** - the pole fell tau times too fast with every sign
correct. Choosing the unit the equations are written in REMOVES the conversion rather than fixing
it.

So the rule is per piece of angle state, and the name always carries the unit: `pole_rad` and
`pole_rate_rad` cannot be mistaken for `pole_turns`. The limit is still not a rounded constant -
`radFromDeg(12)` rather than znum's `0.2095`, which is 12.0035 degrees.

## A TEST WHOSE INPUT IS TOO NARROW PASSES A BROKEN IMPLEMENTATION

`categorical` indexed one RNG stream with `index *% 31 +% position`. That collides as soon as
there are more than 31 logits: draw 1 position 0 and draw 0 position 31 land on the same slot and
get **the same noise**. Measured at 40 logits: **22% of slots reused** across a hundred draws.

The distribution test used FOUR buckets and passed. Four is under thirty-one, so the bug was
structurally invisible - the same shape as the headless twin being blind to `is_gpu`, and the
`tiny` field's eight decades hiding a cancelling `tanh`.

**And the statistic could not settle it either**: 40 buckets at 200k draws gave 3.1 sigma before
the fix and 3.3 after - the worst of forty is around three sigma by chance. The DETERMINISTIC
check - do two different draws hash to the same slot - was decisive where the statistical one was
noise. `rng.split(index)` was the house tool all along.

## AN OPERATION THAT FAILS PARTWAY THROUGH LEAVES A HALF-WRITTEN OUTPUT

`divideBy` divided and wrote in one pass, so a zero in the middle left `out` as
`{5, 10, -999, -999}` with an error the caller might ignore. **Every other operation in zimrnum
validates up front and then cannot fail** - this one was the odd one out and nothing said so.

The error was correct, the shapes were right, every test passed. Only asking "what does `out`
hold after the failure" found it. One extra validation pass buys the property every neighbour
already has.

## A zimrmath FUNCTION THAT ONLY TAKES SCALARS IS HALF A FUNCTION

Everything here has to run three ways: on a scalar (bias f32), on a `@Vector` lane, and inside a
GPU shader. The house pattern is `anytype` plus a `@typeInfo(T) == .vector` branch - `sinh` shows
it, `perLane` and `splatLike` are the tools.

I added six division functions taking `comptime T` and comparing `denominator == 0`. On a
`@Vector` that yields a vector of BOOLS and does not compile. **The signature looked generic and
was not.**

`anyZero` / `anyNonZero` reduce across lanes; the six now take `anytype`. And add only what is
NEEDED - `gcd` stays scalar because Euclid's loop runs a different number of times per lane, so a
vector version would have to run every lane to the worst case and mask. That is a real limit,
recorded, not an oversight.

## EVERY GAP IN zimrmath IS A WORKAROUND SOMEWHERE ELSE

The lint bans `std.math` outside zimrmath for GPU portability. That is only half a policy: when
zimrmath lacks something std.math has, the caller does not stop - they write it inline. zimrnum's
integer division inlined `@divFloor`, hand-rolled a `divCeil` because `std.math.divCeil` was
banned, and repeated the zero and inexact checks at the call site.

**The fix is not a better workaround, it is the missing function.** zimrmath now has the four
divisions, both remainders, `gcd`, `lcm` and four float classifiers, each tested AGAINST
std.math itself - agreement with the original is the whole specification.

Coverage went 57 to 69 of std.math's 142 public names. When something is missing, copy it in.

## `rm -rf .zig-cache/tmp` BREAKS THE BUILD - THE DIRECTORY MUST EXIST

The troubleshooting block prints `rm -rf .zig-cache/tmp   # scratch` as the gentle first step. It
deletes a directory `configure` expects to find, and the next build fails with
`error: configuration failed: FileNotFound` - which reads like a source problem and is not.

`mkdir -p .zig-cache/tmp` afterwards. Better: `rm -rf .zig-cache/tmp/*`.

**A cleanup step that leaves the tree unable to build is worse than no cleanup step**, because the
error it produces points away from itself.

## `inline` IS NOT A PERFORMANCE TOOL HERE - ZERO REMAIN IN zimrmath

232 public and 7 private `inline fn` were removed. All four suites pass, `check` is green, ten
smokes pass, and **the shipped page is 35 KB smaller** - 1.2%. The compiler was making better
decisions than the annotations were.

AND THE ONE FUNCTION THAT SEEMED TO NEED IT WAS MASKING A COMPILER BUG. With `inline` gone,
`inverseQuat` made the wasm module fail to INSTANTIATE:

    Compiling function "zimrmath.inverseQuat" failed:
    f32.le[0] expected type f32, found local.get of type v128

Putting `inline` back did not fix it - it moved the failure to whichever function the comparison
landed in next, `plot3d.pixelsToNDCRay` among them. The cause was `blend(l <= splat(eps), ...)`,
a VECTOR comparison the wasm backend miscompiles. Every lane of `lengthSq4Splat` holds the same
number, so one scalar compare says the same thing and generates correct code.

**Removing `inline` did not create that bug, it revealed one that had been there all along.** If
a function seems to need the annotation, look at what the annotation is hiding.

## THE TURNS VOCABULARY IS zm KEYWORDS - ALIASED ONCE, USED BARE

`sinTurns cosTurns tanTurns sincosTurns turnsFromRad radFromTurns turnsFromDeg degFromTurns` sit
in the linter's keyword list beside `sin`/`cos`/`radFromDeg`. That means both halves apply: bind
`const sinTurns = zm.sinTurns;` at file scope and use it bare (`no-qualified-zm`), and no other
declaration may take the name (`reserved-math-names`).

The point is that `sinTurns(phase_turns)` reads as a sentence and `zm.sinTurns(phase_turns)` is
noise. 32 qualified calls across 25 files became zero.

`zimrnum` is exempt and already says why, in two `lint:off` lines at the top: its primary
vocabulary is the tensor op of the same name, so `zm.` is doing real disambiguating work there
rather than adding noise.

⚠ **VERIFYING A LINT RULE MEANS CHECKING THE EXIT CODE, NOT GREPPING THE OUTPUT.** I concluded
three times that the rule did not fire, because my grep matched the pass-mode format and the
build prints failures differently. `rc=1` with the control and `rc=0` without is the whole test.

## AN IMPORTED FILE'S TESTS DO RUN - VERIFY THAT BEFORE CLAIMING A GAP

`zig test root.zig` runs the tests of every file the root `@import`s and analyses. `refAllDecls`
is not required; a plain import is enough. Proven with a two-file case: a leaf whose test fails
reports "1 passed; 1 failed" through BOTH a `refAllDecls` root and a plain-import one.

So `src/tests.zig` really does cover the files it lists, and `zig build test` goes red when one of
their tests breaks - verified by inserting a failing assertion into `easings.zig` and watching the
aggregate name it:

    error: 'easings.test.easings: endpoint identities for all functions' failed

⚠ **I claimed the opposite first.** Having found broken tests in `easings.zig`, I inferred that no
gate ran them - because if one had, they would not have been broken. That is a plausible inference
and it was wrong; the tests broke and the gate was simply never run between the break and the
discovery. **A gap in coverage and a gap in when you ran the gate look identical from the
wreckage.**

## FOLDING AN ANGLE INTO RANGE IS ONE SUBTRACTION IN TURNS

    if (a > pi)  a -= 2.0 * pi;      ->    a_turns - @round(a_turns)
    if (a < -pi) a += 2.0 * pi;

Two branches become none, and it is EXACT because subtracting a whole number from a binary float
touches no mantissa bit. It is also **unconditionally correct**: the two-branch form folds exactly
ONE turn, so an input 2.25 turns out comes back at 1.25 - still outside the range it claims to
enforce. That assumption is invisible in the radian form and absent from the turn form.

## EVERY VALUE THAT IS A TURN SAYS `_turns` - PARAMETERS, LOCALS AND FIELDS

Not just parameters. A local called `t0` or `central` or `angle` carries a unit the same way a
parameter does, and the compiler checks neither. The rule is that if a value reaches
`sinTurns`/`cosTurns`, or is passed where a turn is wanted, its NAME says so.

Auditable in one line, which is the point:

    grep for sinTurns\(([a-z_][a-z_0-9.]*)\) and check every capture contains "turns"

Twelve names failed that check after the drawing conversion - `a0`, `a1`, `t0`, `t1`, `central`,
`next`, `angle`, `step`, `ext`, `a2`, `local`, `phase`. All of them held turns. None of them said
so, and every one compiled.

⚠ **A rename that skips field access is a rename that half-works.** `phase` became `phase_turns`
on the declaration while every `state.phase` kept the old name, because the pattern excluded a
leading dot to avoid matching other structs' fields. The build caught it; a field read through
`@field` would not have.

## ONLY TWO ANGLES IN THIS ENGINE CROSS INTO CODE WE DO NOT OWN

Both are Canvas2D, in `bridge.zig`: `j.call("arc", ...)` and `j.call("rotate", ...)`. JavaScript
takes radians and always will. **Everything else is ours** - `WgpuGl.rotate`, `raster.rotate`,
`rotationX/Y/Z`, every draw call - so "we have to keep radians for compatibility" is true of
exactly two lines.

`zimrmath`'s trig primitives stay radian-native and that is correct: a rotation matrix is built
from a sine and a cosine, and radians are what those are FOR. The rule is that the conversion
happens at the edge between the drawing layer and the maths, once, in a named local.

⚠ **A `rl`-prefixed name is ours wearing raylib's clothes, not a binding to anything.** Ten of
them exist. `rlRotatef` took DEGREES because raylib did, and its only caller already held radians
and converted TO degrees to reach it - **radians to degrees to radians, a full round trip for
nothing**. Deleted. When one of these is in the way, delete it rather than route around it.

## A UNIT IN A PARAMETER NAME IS NOT CHECKED BY ANYTHING

`rotation_rad: f32` and `rotation_turns: f32` are the same type. Renaming the parameter and
converting the body changes what the function MEANS and the compiler cannot see it: every caller
still passes what it passed, now scaled wrong by tau. Nothing fails to build, and the lint is
silent.

That is what happened converting `draw2d` to turns. The five call sites in `WgpuGl` and
`SwAdapter` compiled clean while feeding radians into a turns parameter. It was caught by reading,
not by tooling.

**Two things follow.** First, convert at a NAMED BOUNDARY and put the conversion in a local whose
name says the unit - one visible place per module edge, not a rename that spreads. Second, the
only real fix is a type: a `Turns` wrapper the way `Named` wraps a tensor's axes, so a radian
cannot be passed where a turn is wanted. Until that exists, a unit suffix is documentation and
should be treated as documentation.

⚠ A blanket rename also catches things that merely SHARE THE NAME. `rotation_rad` was a field of
`ImageOpts` and `TextureOpts` too - option structs feeding a completely different subsystem that
was not converted. Those broke loudly, which was luck: they were read by name. A field read
through a generic `opts` would not have.

## ZIMRNUM AND ZIMRMATH ARE ASCII-ONLY

A comment that needs a font is a comment that can be mangled. Em-dashes, box-drawing rules, stars
used as emphasis, Greek letters and superscripts all survive a good editor and none of them
survives a bad one, a terminal with the wrong locale, a diff viewer, or a patch pasted through a
chat window. `sigma` reads as sigma everywhere; the character does not.

Write `->` not an arrow, `*` not a middle dot, `sqrt` not a radical, `^2` not a superscript,
`+/-` not a plus-minus. **No stars for emphasis** - if a paragraph matters, say why it matters.

A test in zimrnum embeds both files and counts bytes above 127. zimrnum must be exactly zero;
zimrmath is allowed the four `test "..."` names that still carry maths symbols, and nothing else.

## ★★ A DRAG MUST ANCHOR ON THE PRESS FRAME

`getMouseDelta` on the frame the button goes down is **the whole distance the pointer travelled to
get there**. With a mouse that is nearly zero, because the pointer was already where you clicked.
**With a finger it is the bug**: the pointer teleports from wherever it last was to wherever you
touched, and that jump arrives as one frame's delta — the page pops out from under you before
you have moved at all.

★ Either skip the press frame's delta, or better, **anchor and go absolute**:

    if (pressed) { drag_from = mouse[1]; scroll_from = scroll; dragging = true; }
    else if (dragging and down) { scroll = scroll_from - (mouse[1] - drag_from); }

The absolute form also means the pixel under the finger stays under the finger, and a dropped
frame cannot make the content drift away over a long drag.

⚠ **`examples/voxel` already did this correctly** with a `dragging` guard, and
`zimrnum_field` did not. The pattern was in the codebase before the bug was; the cost of not
looking was a nitpick that reached a device.

## ★★ `rm -rf .zig-cache` IS THE ONLY SAFE PRUNE

The build refuses to start below ~1 GB free, with a message listing what to delete. `rm -rf
zig-out` first — it is regenerable and costs nothing. If that is not enough, **delete the whole
`.zig-cache`**: it rebuilds to about 370 MB from 8.6 GB.

★ **Do NOT prune `.zig-cache/o` selectively.** Deleting entries by mtime removes generated
bootstrap sources the build still depends on, which turns a clear disk error into
`unable to load 'gen_externs_bootstrap.zig'` — a compile error that says nothing about disk.

## ★★ A DEVICE TEST MUST FINISH IN UNDER TWO SECONDS

Simon runs these by hand on a phone. `zimrnum_train` at one step per frame took five seconds
(600 frames at 120 Hz) and was cut to ten steps a frame: 61 frames, about half a second. The
sweep at 59 rows × 3 settle frames is about 1.5 s. **Budget the frame count, not the work** —
the phone is 120 Hz, so 240 frames is the ceiling, and a readback that needs settle frames
costs those frames per row.

## ★★★ STANDALONE PAGES OVER 2 MB DO NOT OPEN IN THE CLAUDE ANDROID VIEWER

Measured Sep 4 2026 by padding ONE page (`hello_world`) with an inert HTML comment, so nothing
but size could differ:

    1 744 389  hello_world           opens
    1 899 978  probe                 opens
    1 990 437  zn_sweep_plain        opens
    1 994 978  probe                 opens
    ---------------------------------------- boundary: 2 000 000
    2 009 978  probe                 FAILS
    2 039 978  probe                 FAILS
    2 044 838  zn_sweep_wrapped      FAILS
    2 399 978  probe                 FAILS
   13 778 120  launcher              FAILS

★★★ **THE BOUNDARY IS BRACKETED TO WITHIN 15 KB AND 2 000 000 SITS INSIDE IT.** The launcher
failing at 13.8 MB — a page that opened in this viewer earlier in the project — says the cap is
recent and hard, not content-dependent. Chrome opens all of them.

★★ **DO NOT BUY THE 71 KB WITH `-Dmode=ship`.** It fits — 2 044 838 under `release` against
**1 973 657** under `ship` — and the saving is exactly the wrong thing: `build.zig` sets
`assert_log = false` and `profile_enabled = false` for `ship` and true for both other modes.
**The 71 KB IS the asserts and the profiler.** Stripping the safety net from a page whose
whole purpose is verification, to make it open in one viewer, is a bad trade at any size.

★ So: build sweeps and demos with `-Dmode=release`, accept that they exceed 2 MB, and say
plainly that the page needs Chrome. `ship` is for shipping, not for measuring.

★ THE METHOD IS THE REUSABLE PART. Three hypotheses died in three turns — corrupted file, line
length, and then a 932-byte "anomaly" that argued against size. What settled it was padding a
page that WORKED until it stopped working, so exactly one variable moved. ★★ The 932-byte anomaly
was my own error: the screenshots that "opened" a 2.04 MB page showed a **Chrome URL bar**, not
the viewer's title bar, and I built an argument on them without checking which app they came
from. **Check the provenance of evidence before reasoning from it.**

## ★★★ THE EMBEDDED WASM IS WRAPPED AT 64 KB PER LINE

⚠ **THE LINE LENGTH WAS NOT THE CAUSE OF THE VIEWER FAILURE — THAT HYPOTHESIS WAS FALSIFIED.**
Wrapping brought the longest line from 1 048 385 to 109 708, identical to `hello_world`, and the
page still would not open. The wrap is kept because a megabyte on one line is bad practice
regardless, but **it fixed nothing and the entry below must not be read as a diagnosis.**

★★ What the falsification taught: I measured one property, found a difference, and shipped a fix
for it in the same turn. The A/B that disproved it was shipped alongside only because it was
cheap — had it not been, a wrong explanation would now be sitting in this file as a fact.
**Ship the control WITH the fix, every time.**


`tools/c2js.zig` used to emit the base64 wasm as ONE string, so a standalone page contained a
single line as long as the encoding. Measured:

    hello_world      747 949 chars on one line   opened everywhere, always
    zimrnum_field  1 048 385 chars on one line   Chrome opened it; Claude's Android viewer would not

`zimrnum_field` was the first page to cross a megabyte on one line and the first that a viewer
refused. A per-line buffer limit is the obvious suspect, and wrapping costs nothing.

★★ **SPLIT INTO JS STRING CONCATENATION, NOT NEWLINES INSIDE THE LITERAL.** `atob` tolerating
whitespace is implementation behaviour, not a spec promise; a page that decodes on one engine and
not another is worse than a long line. `"a" + "b"` is unambiguous everywhere. 64 KB chunks:
under any plausible limit, few enough concatenations that no parser minds.

★ After the fix both pages top out at **109 708** characters — a second base64 blob emitted
elsewhere, well under the size that ever caused trouble.

★ The generic lesson: **a file can be structurally valid and still unopenable.** No null bytes,
correct doctype, valid HTML, runs in Chrome — and a viewer still refuses. When a file "works
somewhere and not here", measure its SHAPE (longest line, nesting depth, blob count), not just
its validity.

## ★★★ THE TURN LOOP: `-Dgate=false` WHILE ITERATING, `zig build check` BEFORE FINISHING

`-Dgate` (default **true**) controls whether the lint/fmt gate precedes every wasm compile.

    iterate:   zig build <target> -Dgate=false     ~1s   no lint, no fmt
    finish:    zig build check                     ~8s   lint + fmt-check + corpus + smoke

★★★ **MEASURED 8s → 1s** on `zimrnum-field-standalone` after touching one file. The gate is right
for a normal build and wrong inside an iteration loop: a half-finished edit fails on a
line-length rule *before the compiler has said whether the change makes sense*, and the linter's
message is then the only thing on screen, hiding the type error that actually matters. That
happened repeatedly during the zimrnum port.

★★ **THE DEFAULT DOES NOT CHANGE.** `-Dgate=false` must be typed per command, and build.zig
prints a warning every time it is used:

    zimr: -Dgate=false - lint and fmt are NOT running. Run `zig build check` (no flags) before finishing.

★★★ **PROVEN SAFE BY NEGATIVE CONTROL, not by argument.** An over-long line was added, then:

    zig build <target> -Dgate=false   rc=0   (skipped, as designed)
    zig build check                   rc=1   [line-length] on the exact line

`check` reaches lint and `zig fmt --check` through its wasm compiles, so **one unflagged command
still covers everything**. The discipline is therefore a single rule: **never pass `-Dgate=false`
to `check`.** If that rule is ever broken the whole scheme is unsafe, which is why the control
above is worth re-running whenever the gate wiring is touched.

★ `-Dgate=false` does NOT disable the `lint` or `fmt` STEPS — `zig build lint` and `zig fmt` are
always available. It removes only the implicit dependency edge. And it is orthogonal to
`-Dautofix`: that one chooses *fix* versus *check* when the gate runs at all.

## ★★★ BEFORE DELETING A FILE, GREP ITS BASENAME — NOT ITS PATH

A byte-identical scan said `src/assets/sample.ogg` and `src/assets/test_sine.wav` were dead
duplicates of copies elsewhere. I checked with `grep -rn '"src/assets'`, found only the file
atlas, and deleted them. **`@embedFile` resolves relative to the IMPORTING FILE**, so the three
real references — `@embedFile("./assets/sample.ogg")` in `src/codecs.zig` and
`@embedFile("../assets/test_sine.wav")` in `src/tests/features_test.zig` — contain neither the
string `src/assets` nor anything a path grep would match.

★★★ **AND `zig build check` STAYED GREEN THROUGH ALL OF IT.** `check` does not compile the test
roots (recorded above, twice). Four snapshots shipped with `zig build test` failing on
`FileNotFound` before the full suite was run again. The identical copies elsewhere were not
substitutes: `@embedFile` cannot reach out of its module's tree, which is WHY the duplicate
existed. It was load-bearing and looked redundant.

★★ **THE RULE**: grep the BASENAME (`sample.ogg`), not the path. And a relative-`@embedFile`
existence sweep is four lines of Python — walk the tree, resolve each `@embedFile("…/…")` against
its own directory, report the misses. Run it before any deletion of a data file.

★ The general shape, for the third time this session: a check that is cheap and blunt finds real
dead weight AND flags load-bearing structure identically. The scan is not the decision.

## ★★★ ADJACENCY IN A LOG IS NOT ATTRIBUTION

Twice in one session I read output next to a thing and concluded it came FROM that thing:

★★ **`grep -B12 FAIL` printed three log rows above a failing test, so I called them that test's
output.** They were not. I then "confirmed" the diagnosis by finding `_ = mode;` in a function the
test calls, and wrote a whole journal entry about a dead A/B — while the file itself said, forty
lines up, that `ArmMode` was GONE and its removal WAS the fix. **Check which code emits the format
string** (`grep` the literal `"mode {s"`), do not infer it from what sits above the FAIL line.

★★ **A per-test timer that measures the gap BEFORE test N's line is measuring test N−1.** My
first "slowest tests" list named three tests that were innocent; corrected, it named three
different ones. The tell was there — the first entry was implausibly the very first test — and I
did not look.

★★★ **THE GENERAL FORM: an instrument that has never been checked against a known answer is not
an instrument.** Both of these produced confident, specific, wrong conclusions that survived
being written down. Before trusting a measurement harness you just wrote, feed it one case whose
answer you already know.

## ★★★ THE TEST PROTOCOL — an artifact costs ~30 s BEFORE it tests anything

**MEASURED on 1980, 1 core, ReleaseSafe, compile-only (`--test-no-exec`), warm `zm`:**

    robot_scene   31 s   6.7 MB      robot   32 s   6.5 MB
    urdf          35 s   9.2 MB      test-fast, all 10 roots, cold: 253 s / +456 MB cache

★★★ **THE FLOOR IS THE CLOSURE, NOT THE MODULE.** `robot_scene` and `robot` cost the SAME 31 s
though one is a fraction of the other. Each `addTest` is a separate whole-program compile, so an
extra test artifact costs ~30 s before it runs a single test. **Splitting a root into N parts
that share a closure multiplies that closure by N.** Ten parts of `src/tests.zig` — which imports
`zimr.zig` — would be TEN engine compiles, not a tenth of one. That is the opposite of the
intended effect, and it is the reason the fast tier is a list of SHADER-FREE roots rather than a
list of small ones.

★★ **SO THE UNIT OF SPLITTING IS THE DEPENDENCY CLOSURE.** A new artifact earns its 30 s only
when it lets you AVOID compiling something. The tiers, cheapest first — a module belongs in the
cheapest tier that can hold it, and the compiler enforces the tier because a module that grows a
dependency stops building there:

| tier | closure | command | budget |
|---|---|---|---|
| T0 | `zm` only | `test-filter` on one root | seconds |
| T1 | `zm` + `build_options` (+ named siblings) | `test-fast` — the 10 shader-free roots | ~30 s each |
| T2 | engine types, NO compiled shader | (not split out yet — see below) | — |
| T3 | engine + ~50 shaders | `zig build test` (`src/tests.zig`) | minutes |
| T4 | wasm example typecheck + smoke | `smoke-test -Dfocus=` | ~30 s focused |

★★★ **AND THE FAST ROOTS ARE NESTED, NOT DISJOINT — THE TIER RE-RUNS THE SAME TESTS 4x.**
Measured once `robot_mjcf` compiled again: `test-fast` is **636 s** and reports
**2 351/2 364 tests passed** across ten artifacts — but eight of them ran 411, 425 or 447 tests
and the same failure appears FOUR times, because `robot_mjcf.zig` imports `robot.zig`,
`robot_physics.zig` and the rest. There are only a few hundred distinct tests in there. **A root
tests its whole closure, so a list of roots where one imports another pays for the overlap every
time.** The cheapest complete run is the set of MAXIMAL roots (the ones that transitively cover
the others), not all of them — work that out before splitting the step, or the split just
reshuffles the redundancy.

★★★ **A COMMAND'S COST IS ITS ARTIFACT COUNT × 30 s.** `test-fast` is 636 s at ten
roots (253 s when a third of it did not compile) — past the 250 s timeout, so it CANNOT be run in one foreground tool call any more. Two
consequences, both mechanical:
  * **Bound the artifacts per command, not the lines per file.** Split `test-fast` into named
    sub-steps of ≤5 roots (`test-robot`, `test-mjcf`, …) that each land under ~150 s, and keep
    `test-fast` as the aggregate.
  * **Anything over the timeout is DETACHED, never retried.** `nohup setsid $ZIG build <step>
    ... &`, then poll `pgrep -x zig` across turns. A single compile unit longer than the timeout
    is unfinishable by retrying — see the section on that below.

★★★ **WHAT TO RUN, WHEN.** The full suite is not a per-turn gate and pretending otherwise is
how it stops being run at all:

    every edit        `test-fast -Dtest-filter=<name>`          seconds
    every turn        the ONE tier the edit touched             <150 s
    before a snapshot `zig build check`                         ~79 s
    arc close / bump / before device / weekly   the whole thing, DETACHED   ~15 min

★★★ **`check` DOES NOT COMPILE THE TEST ROOTS, AND THIS BIT AGAIN ON 1980.** `check` was green
for a whole session while `src/robot_mjcf.zig` had **4 compile errors** (`computeTwistOffsets`
grew a `human_parents_for_rest` parameter and not one of its four call sites was updated) and
`codecs.gltf`'s `minimal JSON document` test leaked 8 398 bytes. claude.md already recorded this
exact failure once — "which is how five compile errors accumulated in it unnoticed" — and it
happened again because nothing in the per-turn loop compiles the fast roots. **The per-turn gate
must include a tier that actually compiles the code you changed.** `check` measures shaders,
lint and regressions; it says NOTHING about whether the tree compiles.

★ A leak reported as `(empty stack trace)` is ReleaseSafe doing its one downside. Flip that one
module to `.Debug` to locate it, then flip it back.

## Build / test gates
- General cross-cutting work: `zig build tier-a-check` — host tests + a small
  representative example typecheck + the spv2wgsl corpus + fixture WGSL.
- wgpu / spv2wgsl work: `zig build wgpu-check` — skips example typechecks.
- Arc close, unfocused: `zig build test` — re-typechecks every example (~80s).
- `-Dfocus=<comma names or prefix glob ending in '*'>` filters build / typecheck /
  smoke. The `smoke-test` filter takes the snake_case directory name
  (`-Dfocus=shader_effects`); build steps are the kebab-case name.
- **Never let a test fail, even one "not yours."** When you touch the tree you own
  the green — fix it the same turn or revert until the pre-existing failure is
  fixed. Fix errors the moment you notice them, with the best long-term solution,
  not a band-aid.
- The build CAN be broken DURING a turn if that reaches a cleaner final state
  (API-shape sweeps, type refactors across many sites); acceptance is green at the
  END of the turn. Prefer the deep correct fix over the local patch.

## ★ SURVIVING A COMPILER BUMP (read this FIRST when a new Zig lands) ★

A toolchain bump breaks zimr in three tiers, and they get progressively harder to
see. Work them in this order; the loud ones mask the quiet ones.

**Tier 1 — compile errors (loud, minutes).** Renamed std/builtin API. The 1676 bump
renamed the optimize enum's FIELDS (`Debug`→`debug`, `ReleaseSmall`→`small`),
keeping the old spellings only as deprecated DECLS. Decl literals resolve where a
result type is known but NOT as a bare enum literal in `==`/switch — which is
exactly why `build.zig`'s ~40 `.optimize = .ReleaseFast` kept compiling while
`builtin.mode == .Debug` did not. **When a rename "only breaks some call sites,"
the split is usually result-type-known vs not; fix the comparisons, leave the
initializers.**

**Tier 2 — the `zig fmt` gate (loud, but looks unrelated).** `zig fmt` ships
automatic migrations for renamed BUILTINS: 1676 rewrote `@enumFromInt` →
`@fromBackingInt(@intCast(x))` and `@intFromEnum` → `@backingInt` across 45 files
(~700 sites). Since every Compile `dependsOn` `zig fmt --check`, this is MANDATORY
before anything builds, and it presents as a bare "process exited with code 1"
naming no file. **Run `$ZIG fmt src examples build.zig tools/zimrlint.zig` early and
read the rewrite as a migration, not as formatting.** Expect fallout: the expanded
forms are longer, so a handful of lines blow the 120-col lint cap (7 last time) —
fix them the way rule 10 says (lift to a named local), don't reflow blindly.

**Tier 3 — SILENT wrong values (the dangerous one).** Anything that PASSES a
compiler-generated name through instead of modelling it keeps "working" and emits
garbage. `tools/c2js.zig` is the big one — 1676's renamed zig.h casts turned 99
call sites per bundle into the literal `0`, green through build, lint, fmt AND
`verify_imports`. **The full story and both gates that now cover it are in
`tools/c2js.zig`'s header; read that when a bump lands.** Three lessons that
generalize beyond c2js: a marker nothing reads is not a gate (audit the tree for
others); read semantics from the toolchain ON DISK (`lib/zig.h`, `lib/std/lang.zig`
ship in the release), never from a name; and `verify_imports` structurally cannot
see this class, since it proves a namespace EXISTS, never that a value is RIGHT.

**When a bump breaks SHADERS rather than the host**, the contract with Zig's SPIR-V
backend — build flags, `@SpirvType`, `@extern` decorations, callconv forms, asm
constraints, the addrspace→storage-class map — plus a step-by-step recovery playbook is
in `src/notes/zig-spirv-compiler-interface.md`. Read it first; the canary spikes there
recompile fastest.

**Standing rule: every c2js pass-through of a compiler-generated name is a
silent-breakage surface.** After ANY bump, before believing a green build, run
`zig build c2js-canary` FIRST — it is seconds, needs no device, and fails with the
exact seed and both values. Then:
`grep -c '/\*?' zig-out/standalone/<app>.html` (expect 0 — now enforced), and skim
the emitted JS of one string-handling function for a bare `0` where a length
belongs.

### ★★★ SWEEP THE WHOLE C SURFACE AT ONCE — DON'T LET `c2js-diff` DRIP-FEED IT

The 1857 bump broke c2js five ways and every one was silent. `c2js-diff` finds
them ONE PER RUN and each run is ~2 minutes, because `differential.sh` runs
`set -e` and a c2js exit-2 aborts the loop at that case. Worse, the loop is
alphabetical, so one broken case near the front hides everything behind it — a
stale `arrays_of_structs` had been masking the rest of the suite entirely.

**Do this instead, once, and get the complete list in one pass:**

    Z=tools/zig-x86_64-linux-*/zig
    mkdir -p /tmp/allc
    for f in tools/c2js_cases/cases/*.zig; do
      $Z build-obj "$f" -ofmt=c -OReleaseSmall -target wasm32-freestanding \
        -femit-bin=/tmp/allc/$(basename $f .zig).c 2>/dev/null
    done
    for f in /tmp/allc/*.c; do ./c2js < "$f" >/dev/null 2>>/tmp/err.txt; done
    grep -oE "unhandled-[a-z]+:[A-Za-z0-9_]+" /tmp/err.txt | sort | uniq -c

Empty output is the goal. This surfaced the last two renames together after
three separate 2-minute rounds had each yielded one.

★ **The second sweep, for what the corpus does not reach:** diff c2js's name
table against the toolchain ON DISK.

    grep -oE '"zig_[A-Za-z0-9_]*"' tools/c2js.zig | tr -d '"' | sort -u
    grep -oE '\bzig_[A-Za-z0-9_]*(##w)?' tools/zig-x86_64-linux-*/lib/zig.h | sort -u

Any c2js prefix matching nothing in zig.h is either a rename or a compiler_rt
softfloat name (`zig_add_f32`, `zig_lt_f`, `zig_extendsfdf` — those live outside
zig.h and are fine). `grep -E '^zig_[a-z0-9]+[A-Z]' ` on the zig.h side lists the
camelCase spellings in one shot.

### 1902 was a NO-OP BUMP — and here is what "no-op" was worth proving

`0.17.0-dev.1902+896bd9e15`, from 1857. **Zero source changes.** All three tiers verified in
under 4 minutes, and every one of them was cheap enough that skipping any of them would have been
false economy:

- **Tier 1/2 clean.** `zig fmt --check` over the GATED surface (`src`, `examples`, `build.zig`,
  `tools/zimrlint.zig`) is clean; lint 0 findings.
- **Tier 3 clean.** The whole-C-surface sweep emitted C for all 102 c2js cases and ran every one
  through c2js: **zero `unhandled-*` markers**. `c2js-canary` PASS. Both shipped standalones have
  `grep -c '/\*?'` == 0.
- Where 1857 broke c2js five ways, 1902 broke it in none. **That is a result you only get by
  running the sweep** — a green build says nothing about it.

★ **THE FMT GATE DOES NOT COVER `tools/`, AND 18 FILES HAVE BEEN ROTTING THERE SINCE 1676.**
**Status on 2163: the debt is paid** — `zig fmt --check tools --exclude tools/zig-x86_64-linux-*`
is clean. The BOUNDARY is not: the gate still names `tools/zimrlint.zig` alone, so the next
automatic migration will stop at it again. What follows is the original finding.
`zig fmt --check` over the whole tree flags `tools/rename_local.zig`, `rename_pub_fn.zig`,
`zm_namedimports.zig`, `decl_deps.zig` and 14 `tools/c2js_cases/cases/*.zig` — all wanting the
*1676* migration (`@intFromEnum`→`@backingInt`, `@enumFromInt`→`@fromBackingInt(@intCast(x))`).
They were missed because the gate lists `tools/zimrlint.zig` INDIVIDUALLY (to avoid fmt walking
into the bundled stdlib under `tools/zig-x86_64-linux-*/lib/std/`) and nothing else in `tools/`.
The deprecated spellings still compile, so this is debt, not breakage — but it means **a bump's
fmt migration silently stops at the gate boundary**, and `tools/c2js_cases/` is exactly the
corpus that is supposed to catch bump regressions. Widen the gate to name the other `tools/`
entries individually, or scan `tools/` with the toolchain dir excluded.

### What 1857 actually renamed (and the two latent bugs it exposed)

Renames — snake to camel, in `lib/zig.h`. `clz`/`ctz`/`mod`/`rem` did NOT change:

    popcount -> popCount      byte_swap -> byteSwap      bit_reverse -> bitReverse
    div_floor -> divFloor     div_trunc -> divTrunc      (int AND float forms)

New lowering: **`~` is no longer a C operator.** Every integer NOT goes through
`zig_not_uN(x, bits)` / `zig_not_iN(x, bits)`. And `@bitCast(float)` to its
integer repr arrives as `zig_u32_bitCast_f32(x)` — ONE arg, no width, so
`castHelper()` does not match it (its pattern wants an integer SOURCE).

★ **c2js keeps BOTH spellings, forever.** It transpiles C, not a compiler, and the
C it is handed may come from any toolchain. The tables are append-only; a missing
spelling is not a compile error, it is a lowering to `0`.

★ **THE `bits` ARG IS THE REAL WIDTH; THE NAME SUFFIX IS ONLY C STORAGE.** They
disagree constantly and the suffix is the tempting one. `math.rotl` emits
`zig_not_u8(t1, UINT8_C(5))` for a 5-bit shift amount — trusting `u8` masks with
255 instead of 31 and hands every downstream shift a value 8x too large. Two
separate bugs this turn came from reading the wrong one, including a PRE-EXISTING
`bigIntWide` bug where `not` masked at `width_str` (storage) so `zig_not_u64(x, 48)`
left every bit above 48 set. **Note `not` takes (arg, bits) — two args — where the
wrapping ops take (a, b, bits); the generic `bits = args[2]` silently falls back.**

★ **AND A LIMIT MACRO IN AN EXPRESSION IS NOT A LIMIT MACRO IN A DATA IMAGE.**
`limitMacroValue` returns MIN values as two's-complement u64 because its other
caller is the data writer, which truncates to the slot width. An expression has no
slot: `INT8_MIN` printed as `18446744073709551488`, so `x != INT8_MIN` was ALWAYS
TRUE. Only `INT64_MIN` had ever been special-cased. Zero markers, zero errors — a
comparison that can never hold. **When one helper serves two consumers with
different truncation contracts, the second consumer is where the bug lives.**

★ **A LINT AUTOFIX ATE A TEST FIXTURE.** `tools/c2js_cases/cases/arrays_of_structs.zig`
held `const Vec = Vec;` — `prefer-vec --fix` had rewritten the DEFINITION, because
the rule exempts zimrmath's canonical binding BY PATH and that file is not that
path. `c2js_cases/` is carved out of the lint scan now, but the damage stayed in
the tree. Grep for it after any autofix sweep:
`grep -rn '^const \([A-Za-z_][A-Za-z0-9_]*\) = \1;' src examples tools`.

### 1980 — ONE REAL BREAK, AND IT ONLY SHOWS IN THE LAUNCHER

`0.17.0-dev.1980+e78ea8f2c`, from 1902. Tiers 1-3 clean everywhere except ONE compile error, in
the compute bindings — `hello_world` pulls no compute, so it built first try and said nothing:

    src/kompute.zig: extern in 'storage_buffer' address space must be a
                     single-item pointer to a struct

★ **A STORAGE BINDING IS A STRUCT NOW, NOT AN ARRAY.** `Globals.bind` declared the extern
straight at the view type (`*addrspace(.storage_buffer) [N]V`). 1980 wants the SPIR-V block shape
the shader path in `shader_builtins.zig` already used. FIX: wrap it in
`extern struct { items: BoundView(FieldT) }` and return `&block.items` — same symbol, same
bytes, and every kernel still writes `pos[i]`. **No kernel file changed.**

★★ **THE ONE-SECOND PROBE IS WHAT MADE IT A ONE-FILE FIX.** Three `build-obj -ofmt=spirv`
probes, no example built (the recipe under "VERIFY A ZIMRMATH CHANGE AGAINST SPIR-V"): pointer to
a bare array REJECTED, pointer to a one-field `extern struct` ACCEPTED, and `&blk.items` ACCEPTED.
That last one is the whole difference between editing `kompute.zig` and editing every kernel.

★★★ **THEN THE DROPPED-BLOCK GATE FALSE-POSITIVED ON THE NEW SHAPE — 13 KERNELS.** spv2wgsl
had lowered it correctly all along (`kbuf_pos.field_0[i]` on
`var<storage, read_write> kbuf_pos: S35821`); the guard searched the WGSL body for the literal
`kbuf_pos[`, which a struct-typed binding never emits. Widened to accept `name[` OR `name.`.
Neither needle can match a longer name by prefix, and a dropped block removes EVERY mention, so
the check keeps its power. **Proven: with both needles made unmatchable it fires 13 times and the
build goes red; with the real ones the launcher builds.** Red -> green, so it is still a gate.

★ **A GUARD FIRING AFTER A BUMP IS NOT AUTOMATICALLY THE BUG.** Read what the transpiler
actually emitted before touching the transpiler — one `spv2wgsl <in.spv> /tmp/out.wgsl` by hand,
then `grep -oE 'kbuf_[a-z_]+[.a-zA-Z0-9_]*\['`, and the answer was in the output, not the theory.

★★★ **AND THE STRUCT WRAP SILENTLY DROPPED THE ADRENO SHAPE TOO — device found it, not the
gates.** Simon's phone: `no matching call to 'atomicStore(ptr<storage, u32, read_write>, u32)'`.
The loud half was atomics; the quiet half was worse. `emitModuleVariable` rewrote a storage
binding whose pointee was a bare `array<ELEM, N>` two ways — RUNTIME-SIZED (t1178, the shape
proven stable on Adreno) and `array<atomic<ELEM>>` when tainted. A one-field block struct hides
that array one level down, where neither rewrite reached it, so every kompute binding came back
FIXED-SIZE and the tainted one came back plain `u32`. FIX: `storageArrayType` applies both
transforms to the struct MEMBER and emits a block carrying them; accesses stay `x.field_0[i]`.

★★ **THE BLOCKS MUST GO THROUGH `emitTypeStruct`'s BODY MAP.** Per-binding blocks are needed
(only some bindings are atomic) but six identical bodies is a nominal-type mismatch Tint rejects,
and `spv2wgsl_check` fails the build on it: `duplicate struct body`. Dedup on the body — atomic
and plain never collide, because `atomic<>` is already part of the member type.

★★★ **WHY NOTHING IN-SANDBOX CAUGHT EITHER.** `check` was GREEN across both bugs: the corpus
is half vacuous on a fresh sandbox (190 fixtures, no matching live input — it still prints
`✓ NO REGRESSIONS`), and the smoke harness runs frames without ever parsing the WGSL as WGSL.
`fluid_gpu` smoke PASSED with a fixed-size binding and a broken atomic in the module. **Read the
emitted WGSL directly after any change to a binding's type** —
`spv2wgsl <in.spv> /tmp/o.wgsl` then grep the `var<storage>` lines — and re-transpile EVERY
`compute.spv` with the current binary rather than trusting cached `.wgsl`, which lingers from
earlier builds and reads exactly like fresh output.

★ A scan that `continue`s on a failing case reports zero problems while skipping the failures.
Mine did, for a round. (The two that fail with `malformed SPIR-V header` are ZERO-BYTE `.spv`
detritus from earlier failed builds — already documented above, still convincing at first sight.)

Measured cold on 1980, 1 core, `-Dmode=release -Dautofix=false -j1`: build runner **92s**;
`c2js-canary` **30s** PASS; whole-C-surface sweep **102/102, zero `unhandled-*`**; `zig fmt
--check` over the gated surface clean; `hello-world-standalone` **118s / 1.74 MB**;
`launcher-standalone` **80s / peak 1132 MB / 13.78 MB**; `check` **79s** green (corpus clean, no
regressions, wgpu_smoke PASS); `smoke-test -Dfocus=fluid_gpu` PASS (init 4372 calls, ~151/frame).

### 2125 — A NO-OP BUMP, AND WHAT "NO-OP" COST TO PROVE THIS TIME

`0.17.0-dev.2125+0d600e488`, from 1980, with `.zig-cache`, `zig-out` and the old toolchain
deleted first. **Zero source changes.** All three tiers clean on the first pass, no retry loop.

★ **Tier 2 cost nothing.** `zig fmt --check` over the gated surface is clean — 2125 ships no
automatic builtin migration, unlike 1676.

★★ **Tier 3 static, and it is now a FOUR-SECOND exclusion: `lib/zig.h`'s name surface is
BYTE-IDENTICAL to 1980** — 841 `zig_*` names on each, `comm -13` empty in both directions. Keep
the previous toolchain's name table (`/tmp/zigh_names.txt`) before deleting it and diff the two;
when nothing was removed, c2js's table cannot have gone stale and the entire rename class that
broke 1857 is ruled out before a single build runs.

★ Whole-C-surface sweep **102/102 emitted, zero `unhandled-*`, zero stderr**. `c2js-canary` PASS.
The `/\*?` unresolved-cast marker is **0** on both standalones; longest line 109 708, unchanged.

★★★ **THE 1980 STORAGE-BLOCK SHAPE SURVIVED — CHECKED BY HAND, BECAUSE NO GATE CAN.** The Adreno
break at 1980 was found by Simon's phone while `check` and smoke were both green, so after any
bump read the emitted WGSL directly. `fluid_gpu`'s `compute.wgsl`: every binding is a one-field
block whose member is a RUNTIME-SIZED array (`array<vec2<f32>>`, not `array<vec2<f32>, N>`), the
tainted one is `array<atomic<u32>>`, and the body map dedups `kbuf_pos_block` across five
bindings while atomic and plain never collide. That is exactly what `storageArrayType` exists to
emit, and one `grep -A3 '^struct .*_block'` confirms all three properties at once.

★★★ **A FRESH SANDBOX MAKES THE CORPUS VACUOUS, AND A BUMP GUARANTEES IT.** `check` prints
`✓ ENTIRE CORPUS TRANSPILES CLEANLY` and `✓ NO REGRESSIONS` while also printing
`⚠ 190 fixture entries have no matching live input` — ALL 190. Fixtures are keyed by INPUT hash
and a new compiler changes every `.spv` byte, so the regression half of `check` compares nothing
on the first run after any bump. **Do not run `corpus-refresh` to clear that warning**: re-pinning
to the new output is precisely how a real output change would get recorded as the baseline. The
transpile-clean half is still live and still worth reading; the regression half is not evidence
here, and the device is.

★ `fluid_gpu` smoke: **init 4372 calls, ~151.0/frame — identical to 1980 to the call**, and
`wgpu_bringup` 202 init / ~28.0 per frame. A matching call profile across a compiler change is
the cheapest evidence that the host path did not move.

Measured cold on 2125, 1 core, `-Dmode=release -Dautofix=false -j1`: `c2js-canary` **139s /
755 MB**; `hello-world-standalone` **136s / 656 MB / 1.73 MB**; `launcher-standalone` **91s /
peak 1142 MB / 13.55 MB**; `check` **61s** green; `smoke-test -Dfocus=fluid_gpu` **34s** PASS.
Cold to launcher is **~6 minutes and 321 MB of cache** — the same envelope as 1902 and 1980.

★★ **`measure` WRITES THE BUILD'S OUTPUT TO A FIXED `/tmp/b.log`**, not to any
redirect placed on the `measure` call. Redirecting the wrapper captures only its own summary
line, so `grep -c 'error:'` on that file reports 0 whatever happened — which reads exactly like a
clean build. The wrapper's `rc=` is the honest verdict; **the log to read is `/tmp/b.log`**, and
it is overwritten by the next measured command.

### 2163 — NO SOURCE CHANGE FOR THE BUMP, AND THE LEAK CHECKER IT SWITCHED ON

`0.17.0-dev.2163+89ff10d56`, from 2125. The tree needed nothing to build; everything below was
found by the bump, not caused by it.

Measured cold, 1 core, `-Dmode=release -Dautofix=false -j1`: build runner **88 s**;
`c2js-canary` **28 s** PASS; whole-C-surface sweep **102/102**, zero `unhandled-*`, zero stderr;
`zig fmt --check` clean on the gated surface AND on all of `tools/`; `hello-world-standalone`
**116 s / 1 731 170 bytes**; `launcher-standalone` **102 s / 13 558 146 bytes**, zero `/*?`,
longest line 110 796; `check` **74 s** green (56/56 transpile clean, doc-gate 12 pages);
`smoke-test -Dfocus=fluid_gpu` **30 s** PASS at init 4372 / ~151.0 per frame — identical to 1980
and 2125 to the call. The storage-block WGSL read by hand still has the 1980 shape: one-field
blocks over runtime-sized arrays, `array<atomic<u32>>` on the tainted binding, one deduplicated
block shared by six bindings.

★★ **zig.h MOVED THIS TIME: 847 `zig_*` names against 2125's 841**, and the 2125 toolchain was
already gone, so the four-second name diff above was impossible. The dynamic sweep is what
cleared the rename class. **Keep the outgoing toolchain's name list before deleting it** —
`grep -oE '\bzig_[A-Za-z0-9_]*(##w)?' <old>/lib/zig.h | sort -u > /tmp/zigh_<ver>.txt` — or
the cheap check is unavailable exactly when it is needed.

★★★ **`std.heap.DebugAllocator` IS NOW `std.heap.SafeAllocator`** (the old name is a deprecated
alias), and `std.process.Init` hands `main` one in Debug/ReleaseSafe that reports leaks at exit
WITHOUT changing the exit code. The first cold build printed two `leaked 11 bytes` with no step
name and `(empty stack trace)`. How it was found, in order: rerun each tool by hand with the
build's exact arguments until one reproduces (zimrlint's full-tree pass); rebuild THAT tool
`-O Debug` for a stack trace (3 s); the trace named `checkFloatFromInt`. The 11 bytes were
`float(a_ok)` and `float(b_ok)`: a rule built its fix text before `emitFix` checked `lint:off`,
and the early return dropped it. Fixed by making `Issue` own a copy made after the check.

★★ **`std.process.exit(1)` SKIPS THE LEAK CHECK.** It ends the process without unwinding, so the
allocator's `deinit` never runs — a tool that exits non-zero can leak without a word, and the
leak above surfaced only because the tree lints clean. zimrlint's `main` now returns `!u8`.
Proven with a planted 7-byte leak: reported on a failing run, where it used to be silent.

★ **A detached build survives between tool calls but NOT across turns.** `setsid nohup` kept
`test-fast` alive through two polls in one turn; by the next turn it was gone with no `EXIT`
line. Its finished objects stay in the cache, so the work is not lost — but a result has to be
read in the same turn it was started, or re-run.

★★★ **`import-cycle` — FILES MUST NOT IMPORT EACH OTHER, EVEN THOUGH ZIG ALLOWS IT.** A zimrlint
rule over every `@import("*.zig")` in the run, each path resolved against its importing file, so
`../robot.zig` and `robot.zig` are one node. It is the one cross-file rule: it reads every input
itself because the per-file loop skips stamped-clean files, and a cycle is two clean files.
`zig build dag-check` was never going to catch most of these: it scans top-level `src/*.zig`
only, by basename, so `tools/`, the fixtures and a file importing itself (it drops self-edges)
are invisible to it — and it lives in `tier-a-check`, which nothing runs, so even the
`robot_mjcf` <-> `robot_physics` pair it COULD see went unreported. What the rule found:

    robot_mjcf <-> robot_physics   the Go1 standing gate lived in robot_mjcf and needed
                                   robot_physics; moved UP into robot_physics. robot_mjcf's
                                   test artifact: 411 -> 364 tests, 17.2 -> 14.0 MB
    zspv <-> zspv_rewrite          (all three files deleted in 2307 - the pass is obsolete)
                                   the CLI shared a file with the SPIR-V reader the rewriter
                                   needs; CLI moved to tools/zspv_main.zig. Old and new zspv
                                   give byte-identical output on all 56 cached shaders
    wgpu.zig -> wgpu.zig           a nested namespace imported its own file to qualify names;
                                   the file-scope names are already in scope

★ **NO BACK EDGES REMAIN.** The last was `robot.zig` -> `tests/fixtures/robot/kuka_iiwa.zig`:
the fixture is GENERATED as a comptime `rbt.ModelSpec` literal plus `rbt.Spec(spec)`, so it
cannot exist without robot.zig, and three robot.zig tests imported it back. They moved into
`robot_urdf.zig`, which already depends on both — 165 lines, changed only by `rbt.` qualifiers.
`zn-robot` no longer runs them; `zn-robot_urdf` and `test-fast` do. The tree carries zero
`lint:off import-cycle`.

★★★ **`test-fast` IS FIVE ARTIFACTS NOW, NOT THIRTEEN.** `src/robot_tests.zig` imports every
robot-family root, so the union compiles once and each test runs once; build.zig reads that
file's import list (`robotTestsMembers`) and leaves its members out of `test-fast` while they
keep their `zn-` steps. Measured on 2163, one core: **252 s for all 875 tests** (866 pass, 9
skip) — zimrmath 171, zimrnum 223, ragdoll 6, zn_conformance 4, robot family 471. Per-module
counts in the aggregate prove nothing was dropped: robot 124, robot_mpc 36, robot_mjcf 34,
robot_control 21, mjcf 17, robot_physics 16, urdf 10, robot_scene 6, robot_urdf 5.

★★ **`-Dslow-tests`** runs the retarget diagnostics that used to need a source edit, including
`WHOLE BODY`, the only test of the shipped `solvePointCloud`:
`zig build zn-robot_mjcf -Dslow-tests -Dtest-filter="WHOLE BODY"`. Host options only; the file
reads it with `@hasDecl` because it also compiles into wasm.

★★ **THE RETARGET'S SILENT CLAMPS ARE CHECKS NOW.** `buildPointSamples` folded its capacity
guards into its skip conditions, so a short `out` dropped whole bodies' samples without a word;
it still refuses to write out of bounds, and asserts at the end that it never had to. `ikStep`
asserts `scratch.len >= ikScratchSize(nv)`. The `@min(nbody, 64)` and `@min(library_n, 192)`
clamps in `geno_dance` and the robot_mjcf harness are assertions.

★ **zimrlint's `--fix` defers `unused-global` deletions to a pass with nothing else to fix.**
Applying a deletion of `const float = zm.float;` in the same pass as `float-from-int` writing
`float(x)` broke the file; the parse guard discarded the pass and neither fix ever landed.

★ Proven both ways: planted cycles fire (two files, a self-import, and a `sub/../` pair), a
suppressed pair does not, a file whose partner is outside the run does not; and an independent
scan of all 788 `.zig` files under src/examples/tools/webtests agrees — zero cycles, exactly
those three suppressed edges.

### 2307 — EVERY GATE GREEN, EVERY GRAPHICS PIPELINE BROKEN

`0.17.0-dev.2307+392b17125`, from 2163. **This bump was first recorded here as a no-op, and it was
not.** fmt clean, `c2js-canary` PASS, 102/102 C sweep, both standalones built, `check` green,
`wgpu_bringup` smoke 202 / ~28 per frame - and on the device EVERY render pipeline failed:
`Binding doesn't exist in [BindGroupLayout "resources_bgl"] ... @group(0) @binding(1) ... "shapes_fs"`.

★★★ **WHAT BROKE.** 2307 rewrote the SPIR-V linker (`b3727d9bd1`). It links each declaration's MIR on
its own and copies an annotation only when its target is defined in THAT unit (`src/link/Spirv/
Flush.zig`, read at 392b17125). zimr decorated every Location / DescriptorSet / Binding with inline
asm (`OpDecorate %target ...`) inside the entry function, targeting a GLOBAL - another unit - so every
one was silently dropped. spv2wgsl then numbered the leftovers from `@group(0)`: 69 of 69 modules in
group 0, 20 with two resources on one slot.

★★★ **THE FIX IS THE LANGUAGE'S OWN SPELLING, not a workaround.** Every interface variable is a
file-scope `@extern(..., .{ .decoration = .{ .location | .descriptor } })` - `ExternOptions.decoration`,
what upstream's own `test/behavior/spirv.zig` uses. `tools/gen_shader_externs.zig` emits them; the old
`setup()`, `zm_location` / `zm_binding` asm helpers, the `u32` sampler placeholder and the whole
`zspv --rewrite-samplers-wgsl` pass are GONE (2307 also rejects a non-opaque `.constant` extern; the
native `@SpirvType` texture + sampler handles work now). Loose uniforms are one-field uniform blocks
(2307 requires a `.uniform` extern to point at a struct; same bytes). Full account, probes and
measurements: `src/notes/spirv_2307_decorations_plan.md`.

★★★ **WHY NOTHING SAW IT, AND WHAT SEES IT NOW.** Nothing in the sandbox compared a shader's bindings
to the host's layout - the WGSL was perfectly valid, it just no longer matched. Two build-time guards
now do, both proven red on the 2307 output and green on the tree:
  * spv2wgsl `checkGraphicsInterfaceDecorated` - a vertex/fragment variable with no DescriptorSet +
    Binding, or no Location / BuiltIn, fails the build by name (compute is exempt: kompute's externs are
    undecorated by design and `compute_host.parseBindings` reads the numbers back by name).
  * `checkWgsl` in the generator, run by each shader's own bootstrap exe after spv2wgsl - every WGSL
    binding must be the (group, binding, kind, name) the schema promised. The embedded WGSL is its output.

★★ **AND A CACHE LESSON.** `spv2wgsl_check` walks EVERY `.spv` in `.zig-cache`. After the fix, stale
pre-fix SPIR-V (genuinely broken) made `check` red while every module the build produced passed.
**After a change to the generator or the transpiler, `rm -rf .zig-cache` before trusting a red OR a
green from a cache-walking gate.** Likewise a failed shader compile leaves a zero-byte `shader.spv`;
the corpus now counts and skips those instead of calling them transpiler failures.

★ **Standing rule for the next bump: a green sandbox says nothing about bindings.** Look at the
emitted WGSL's `@group` lines (or trust the two guards above, which is what they are for), and let the
device have the final word.

## ★★★ A SELF-REFERENTIAL `State` MUST BE BUILT IN THE GLOBAL, NEVER COPIED INTO IT

`examples/wgpu_bringup` built `var s: State = .{...}` on the stack and ended init with
`state = s;`. `State` is self-referential — `GpuFrame.init` keeps `&s.pipeline_cache` and
`&s.bind_group_cache`, `Renderer2D.init` keeps `&s.gpu_frame`, and every
`loadShader(.{ .f = &s.gpu_frame })` keeps that pointer forever. The copy moves the BYTES and
leaves every captured pointer aimed at the dead stack frame.

**It does not crash, and that is what makes it expensive.** The abandoned frame still holds
plausible values, so reads return whatever init left there. What it actually broke: the
one-write-per-frame UBO guard. `noteUboWrite` uses `self.f.encoder` as its frame token,
`beginFrame` updates that field on the REAL `GpuFrame`, and the dangling `self.f` kept reading
the stale `.invalid` from the dead frame — so the token never changed, the counter never reset,
and the assert fired on frame 2, then 3, then 4.

★ **A COUNTER THAT CLIMBS WITH THE FRAME NUMBER IS A RESET BUG, NOT THE THING IT COUNTS.**
"UBO written 2x in ONE frame", then 3x, then 4x, is not a program writing more each frame — it
is a per-frame counter that never resets. Read the SEQUENCE of an assert's numbers before
believing its message; the message names the invariant, the sequence names the mechanism.

FIX: assign the global FIRST, then take `const s: *State = &(state.?)` and run every sub-init
through that pointer. `zig build check` went green on this alone. Swept `examples/` and
`webtests/`: bringup was the only instance (the two webtest `var st: State = .{}` hits are
module-scope globals, not locals). This is the same class claude.md already recorded as fixed
once here — it regressed, so treat "self-referential struct built as a local" as a standing grep
after any example rewrite: `grep -rn 'state = s;' examples/`.

## ★★★ `-Dmode=release` IS THE DIAGNOSTIC MODE FOR ASSERTS — DEBUG HIDES THE SECOND BUG

`zm.assertf` has three lowerings and only one of them lets you see more than one failure:

| mode | behavior |
|---|---|
| `debug` | `std.log.err` + **`@panic`** — stops at the FIRST assert, everything behind it invisible |
| `release` | `std.log.err` only, **keeps running** — every assert in the frame, every frame |
| `ship` | bare **`unreachable`** — and if the condition is false that is REAL UB, not "check removed" |

wgpu_bringup had TWO independent bugs. Debug panicked on the foreign-pipeline assert and never
reached the UBO one; the release build surfaced both in a single 3-frame run. **After fixing an
assert, re-run in release before believing you are done** — and never hand out a `-Dmode=ship`
build of something whose assert is known to fire.

★ **THE SMOKE RUNNER DISCARDS PANIC TEXT.** `webtests/runner.mjs` shims every import generically,
so WASI `fd_write` — where Zig's `defaultPanic` writes — lands in a stub. You get
`RuntimeError: unreachable` plus a stack that names the FUNCTION but not WHICH assert fired.
`flushBatch` has two asserts meaning completely different bugs. `webtests/panic_probe.mjs`
decodes the iovecs and prints the message: `node webtests/panic_probe.mjs <wasm> [frames]`.
**It must return a FRESH INCREMENTING HANDLE from every non-void import, exactly as runner.mjs
does** — returning 0 for everything makes every GPU handle compare equal, so any assert that
compares two handles trivially passes and the probe reports a FALSE GREEN. That cost a round.

## ★★★ THE DEVICE IS THE ORACLE — A LAYOUT ARGUMENT IS NOT EVIDENCE

`flushBatch`'s foreign-pipeline assert fired in bringup, which drew its fullscreen fractal via
`drawTriangleBatched` + `flushBatch` under the mandelbrot pipeline. I argued it was a FALSE
POSITIVE, reasoning that `julia` ships with the same schema shape (`Inputs`/`Outputs`/`Ubo`, no
samplers → FS UBO at group 2 → `loadShader` mints `empty_bgl` at groups 0 and 1) and renders
fine on device.

**The device said otherwise: black canvas, pass clear included — the whole command buffer
rejected at submit, exactly as the assert's message predicts.** The comparison was not
like-for-like: `julia` uses `loadShaderVF` (merged VS+FS), bringup uses plain `loadShader`.
Different layout construction. Two rounds of reading had not caught it; one screenshot did.

★ Had the "transfer batch ownership so the assert stops firing" fix shipped, it would have
SILENCED A REAL DEVICE ERROR and left the screen black with no signal at all. **When a guard
fires and the argument for calling it a false positive is a layout comparison, build the
artifact and look at it — `-Dmode=release` keeps running past the assert precisely so you can.**

FIX: draw through the shader's OWN pipeline, mirroring `wgpu_app.drawFullscreenShader` (the
documented "strictly safe" fullscreen path) — `bindForDraw` + `setVertex(own vbo)` +
`draw(3, 1)`, then `renderer.bindForPass` to restore. Never let the batch flush under a foreign
pipeline: the flush binds the atlas at `batch_reserved_group` (== 1), where a `loadShader`
pipeline has an `empty_bgl`. `z.Vertex2D` is now re-exported from `zimr.zig` so an app can spell
the vertex type for its own buffer. Confirmed rendering on device.

## The bind-group-layout validator in runner.mjs — FEASIBLE, LANDED, HALF-PROVEN

Second validator built on the attachment-validator's trick: enforce a WebGPU rule with pure
bookkeeping so it fails in-sandbox instead of on a phone. **Feasibility is not in doubt — every
edge of the graph is directly observable from the shim:**

    create_bind_group_layout(device, entriesPtr, entriesLen, ...) -> bgl
    create_bind_group(device, LAYOUT, ...)                        -> bg
    create_pipeline_layout(device, BGL_ARRAY_PTR, count, ...)     -> pl
    create_render_pipeline(device, LAYOUT, ...)                   -> pipeline
    set_pipeline(pass, pipeline) / set_bind_group(pass, i, bg) / draw*

Layout identity is the raw entries blob compared bytewise (`encodeBindGroupLayoutEntries` is
deterministic, so identical bytes always mean identical layouts; the failure direction is a
missed equivalence, i.e. silence, never a false alarm). Groups whose BGL has zero entries — the
`empty_bgl` `loadShader` mints below a schema's highest used group — are skipped, since an empty
layout declares no bindings. WebGPU's inheritance rule IS modelled: on `set_pipeline` the bound
groups are unset from the first index where the two pipeline layouts' BGL signatures diverge,
which is what keeps a stale group the device would have discarded from being reported.

★ **WHAT IS PROVEN, AND THE EXACT TWO RULES THAT GATE IT.** The negative control passes — silent
across `check` (green) and silent on a known-good release bringup. **It has still never fired on a
real mismatch in its shipped configuration**, and the reason is now understood precisely rather
than guessed. Two rules suppress it:

    applyInheritance()  models WebGPU's "incompatible pipeline layout invalidates
                        bind groups" by unsetting every index >= divergeAt
    checkDraw()         skips a slot whose pipeline-layout BGL has zero entries
                        ("an empty layout declares no bindings")

With both in place, the known-bad bringup draw reports
`groups=[106,107,104] sigs=[0,0,1] bound=[[2,105]]` — groups 0/1 unset AND empty, so nothing is
compared, and the draw is judged legal.

**Relaxing both DOES produce the true positive**, naming the same group Dawn does:

    gpu-validation: drawIndexed with pipeline "mandelbrot" has an INCOMPATIBLE bind
    group at group 1: bound group's layout "resources_bgl" (2 binding(s)) does not
    match the pipeline layout's "empty_bgl" (0 binding(s)).

★ **BUT THE RELAXED RULES ALSO FIRE ON THE KNOWN-GOOD BUILD — THREE TIMES — AND THAT BUILD
RENDERS CORRECTLY ON A DEVICE.** So the relaxed model is wrong, not merely stricter: after
`bindForDraw`, groups 0/1 hold stale 2D bind groups in BOTH the good and bad builds, and only the
bad one is rejected by hardware. The conservative version therefore ships, because a validator
that cries wolf on a green tree is worse than one that stays quiet.

**THE OPEN QUESTION, stated precisely:** good and bad differ only in that the bad build runs
`flushBatch` under the foreign pipeline (`drawIndexed` off the batch's buffers) while the good one
runs `draw(3,1)` off its own VBO — and `setBindGroup`'s dedup means the bad build does not even
re-emit the group-1 bind. So the device-visible difference is NOT "which bind groups are set", and
bind-group layout identity alone cannot separate these two cases. Whatever Dawn rejected, this
validator as scoped cannot see it. Anyone continuing should start by getting the ACTUAL Dawn error
string off a device (remote-debug the black build) rather than inferring it — that one string
would settle in a minute what two rounds of modelling could not.

## `runner.mjs` fixes that came out of chasing the above — ALL VERIFIED

★★★ **WASI `fd_write` MUST BE IMPLEMENTED, NOT STUBBED — the generic stub HANGS the runner
forever.** A `-Dmode=release` SUT lowers `assertf` to `std.log.err` + keep running, which on a
wasi target lands in `fd_write`. The generic stub returned a value without ever writing
`nwritten` into memory, and Zig's writer loops until every byte is reported written — so it spun
forever. Symptom: the runner hangs with a ZERO-BYTE log; `panic_probe.mjs`, which implements
fd_write for real, completes the same frame instantly. That contrast is the diagnostic. Now
implemented (decode the iovecs, set `nwritten`, return 0) and served from the Proxy fallback too,
which also surfaces release-mode assert text to the gate as `!ASSERT`.

★ **`--trace-calls`** writes each host call to stderr UNBUFFERED, and echoes every distinct
`!ASSERT`. Everything else the runner prints is buffered until the logic finishes, so a hung or
killed run produced a zero-byte log and no clue where it stopped — precisely when you need one.
This is what located the `fd_write` spin: the trace ended on two `js_queue_write_buffer` with no
`js_log` after them. **Reach for it first on any hang.**

★ **`--max-log=N` log safety valve.** `sutCallLog` hands the logic `log.slice()` — a FULL COPY —
six times. A release SUT re-emits the same assert every frame, and node died at a 2 GB heap before
the logic read anything. Fix: a generous cap (500k, inert on debug runs) plus exact-duplicate
`!ASSERT` suppression, since `wgpu_smoke` fails on the first match anyway. Do NOT "fix" a runaway
log by truncating plain call records early — the handle-balance and per-verb counts are computed
from them, so a tight cap would quietly change what the gate checks. It is a valve, not a budget.

Net effect: **release wasms can now be run through `runner.mjs` at all** (verified:
`✓ PASS bringup_GOOD_release 298922 bytes, init 202 calls, ~28.0/frame`), which is the only mode
that shows more than one assert per run.

## ★ `-O` IN `zig build-exe` IS PER-MODULE — `-M` MODULES DEFAULT TO DEBUG

`zig build-exe -O ReleaseFast --dep foo -Mroot=a.zig -Mfoo=b.zig` optimises **a.zig only**.
`b.zig` — and every stdlib generic instantiated inside it — is built Debug. A benchmark wired
that way reported a 1.5-SECOND FBX parse that is actually 109 ms.

★ **The tell is that Debug and ReleaseFast time IDENTICALLY.** That cannot happen for real work;
it means the code under test was not optimised in either run. If a micro-benchmark ever shows no
Debug/Release difference, suspect the harness before the code — and put a known-good control in
the SAME binary, which is what finally isolated it here.

## ★ `updateMeshBuffer` MUTATES `mesh.vertices` — KEEP THE REST POSE SEPARATELY

`z.updateMeshBuffer(mesh, 0, bytes, 0)` memcpys into `mesh.vertices` itself. Any CPU-skinning or
morph loop that also READS `mesh.vertices` as its source is a feedback loop: each frame deforms
the previous frame's output. On device it looks like the model exploding into a fan of triangles
that keeps drifting EVEN WITH ANIMATION PAUSED — the "still moving while paused" part is the
tell, because it means the input is changing, not the pose.

Save a `base_positions` copy at load and always skin from that. `examples/skinned_mesh` and
`examples/geno_dance` both do.

★ The cheap regression test is an invariant, not a screenshot: skinning with the BIND POSE must
reproduce the rest mesh exactly, since `inverse(bindWorld) * bindWorld == identity`.

## ★ WHEN A CHECK READS A CACHE, REMOVING THE SOURCE IS NOT A CONTROL

`spv2wgsl_check` scans compiled `.spv` under `.zig-cache`. Deleting the three new shader source
files and seeing the SAME failure count "proved" they were pre-existing — they were not. The
cache still held the compiled output, and every failure traced to those files.

★ To attribute a failure in a cache-reading check, clear the cache entries or identify the
inputs directly (`strings shader.spv | grep <name>` named them in seconds). A control that does
not actually remove the thing under test is worse than no control: it produces a confident
wrong conclusion.

★★ Also: failed intermediate compiles leave ZERO-BYTE `.spv` in the cache, which the checker
reports as TRANS-FAIL. Two of the five failures were that — build detritus, not translator bugs.

## ★ MAKE THE OMISSION UNREPRESENTABLE, THEN VERIFY THE TEST FAILS

`skinMeshCpu` took `(mesh, base_positions, skin, out)` and silently left NORMALS in the bind
pose for its whole life. Lighting frozen to the rest pose on a moving body — read on device as
"the asset's normals look wrong", which sent the investigation at the data instead of the code.

Three fixes, in descending order of how much they actually help:

1. ★★ **THE SIGNATURE.** It now takes `base_normals` and `out_normals` too. With normals absent
   from the parameter list, forgetting them was not an oversight a caller COULD make — it was
   unrepresentable, and the omission lived where no caller could see it. Six arguments is the
   right price for that.
2. ★ **AN INVARIANT TEST**: for a vertex bound entirely to one bone, the skinned normal must
   equal that bone's skin rotation applied to the rest normal. Exact, not statistical.
3. A comment. Worth writing, worth nothing on its own — it does not fire.

★★★ **AND VERIFY THE TEST FAILS.** The bug was reintroduced deliberately and the test caught
it; only then was it known to be a guard. An invariant nobody has watched fail is a hope.

★ Note what did NOT catch it: bounding boxes, vertex centroids, the foreign-clip test — all
about POSITIONS. A bind-pose test is the identity for normals too, so it passes either way.
**When adding a geometry test, ask which channels it actually exercises.**

## ★ TEST AGAINST THE WORLD, NOT AGAINST THE ALGEBRA

A skinned character was wrong for five rounds. Every test written for it PASSED the whole time:
bind-pose identity (`inverse(X)*X == I` holds for any X), bounding-box extents, and two matrix
convention checks. None of them compared the MESH to the SKELETON positionally.

The test that found it in one run: **for each joint, take the centroid of the vertices it
dominantly weights and compare it to that joint's bind position.** Right bind = ~5 units (flesh
radius). Wrong bind = 35 (a limb length). It needs no reasoning about conventions at all.

★ Generalise: when a geometric pipeline is wrong, assert a RELATIONSHIP BETWEEN TWO INDEPENDENT
THINGS the pipeline produced — not an identity the algebra guarantees.

★★ And: **with two faults outstanding, no single-variable experiment is conclusive.** Correct
evidence (a bind that legitimately differed from FK) was read as a bug because a second fault
masked the render it was tested against.

## ★ FIXED: `beginMode3D` NOW HONOURS `Camera3D.projection`

It used to build `perspectiveFovRh` unconditionally, so an orthographic camera became a
perspective one whose `fovy_deg` was read as DEGREES — a shadow light with a 4-unit extent
turned into a 4-degree telephoto that saw a fraction of one surface. Flat render, no assert,
smoke green: indistinguishable from a pass that never ran.

★ **What made it worth FIXING rather than DOCUMENTING**: `Camera3D.projMatrix` and
`getScreenToWorldRayWithViewport` ALREADY honoured the field. Two of three consumers agreed and
one silently disagreed — an inconsistency, not a missing feature. `beginMode3D` now calls
`cam.projMatrix(aspect, near, far)`, and a test in `zimrmath` pins both the matrix shape and
that ortho `fovy_deg` is a WORLD HEIGHT rather than an angle.

★★ The general lesson: when an API accepts a field it ignores, prefer making it honour the
field over documenting that it does not. A doc comment does not fire when someone gets it
wrong; a correct implementation makes getting it wrong impossible.

## ★★ A TEST THAT CONSTRUCTS THE STATE UNDER TEST SAYS NOTHING ABOUT THE PRODUCER

Two bugs in one session, same shape:

1. `itemHoverable`'s unit test SET `ctx.item_clip` by hand. It proved the predicate was right
   and proved nothing about whether the field was ever populated — and it was not: the fix set
   it only on the window POP path, so every widget was submitted while the clip still held the
   previous window's rect. Test green, bug live. Now set on BOTH push and pop via one helper.
2. The load-scale test compared mesh vertices and bind matrices, while its own comment said
   "mesh, bind and ANIMATED POSE". The clip was never scaled, and a character playing its own
   take vanished — a metre bind driven by a centimetre animation.

★ Ask of any new test: does it exercise the PRODUCER, or does it hand-build the producer's
output and check a consumer? The second is worth writing, but it is not a guard.

★ And in (2) the words were already right. **A comment naming three things while the code
checks two is worse than no comment** — it reads as coverage that does not exist.

## ★ UI: TWO CONTROLS THAT MOVE TOGETHER ARE AN ID COLLISION

A widget's identity comes from its LABEL. Emit the same label twice — typically by looping over
a list and offering the same set of choices per row — and the two controls share one state:
clicking either moves both.

★ `geno_dance` hit this with a per-character "plays:" radio group. Both rows offered the same
two character names, so selecting a source for one character silently changed the other's, and
one combination was unreachable.

**Fix: `u.pushIdInt(row_index)` / `u.popId()` around each row.** `defer u.popId()` inside a loop
body is correct in Zig — a loop body is a scope, so it runs per iteration.

★ The symptom to recognise: two controls that look independent and move together. That is
almost never a state bug; it is one ID being shared.

## ★ UI: INTERACTION HAD NO CLIP, ONLY DRAWING DID

53 widgets hit-tested with a bare `pointInRect(ctx.input.mouse_pos, rect)` — "is the mouse
where this widget WOULD be". A widget scrolled out of its window, or laid out past the window's
edge, keeps its layout rect, so it stayed GRABBABLE while not being drawn. Dragging in empty
space moved sliders that were nowhere on screen.

★★ **The clip stack that already existed is DRAW-TIME**, consulted when the draw list is
replayed. That is exactly why the fault was invisible from the rendering side: the widget was
correctly not DRAWN and incorrectly still LIVE. Two systems that both need clipping, only one
of which had it.

Fixed with `UiContext.item_clip` (set from the current window whenever the window stack
changes) and a shared `itemHoverable(ctx, rect)` that ANDs the item rect with it. All 53 call
sites converted mechanically. ImGui's equivalent is `ItemHoverable` -> `IsClippedEx`.

★ When adding a widget, hit-test with `itemHoverable`, never `pointInRect` on the mouse
directly.

## ★ OFFSCREEN PASSES GO BEFORE `clearViewport`, NOT AFTER

`beginTextureModeRaw` / `beginTextureModeMrtRaw` branch on `drawing_active`:

  * **screen NOT open (offscreen-first)** — the pass opens and closes cleanly. This is the
    intended path.
  * **screen ALREADY open** — the 2D batch is FLUSHED, the screen pass is ENDED, the offscreen
    pass runs, and `endTextureModeRaw` REOPENS the screen via `reopen2DPass`. Everything
    pending at that moment is drawn early, under whatever state the teardown left.

The reopen does restore the screen ortho, so the projection itself is fine — but the forced
mid-frame flush changes WHEN pending 2D geometry lands, and an interleaved screen/offscreen
order is far harder to reason about than a strict "all offscreen, then the screen".

★ Keep every RTT pass above `clearViewport`. If a pass needs the camera, HOIST THE CAMERA —
it usually depends only on the UI context, not on the screen pass being open.

★★ And beware a comment that asserts an ordering the code does not enforce: `geno_dance` had
"── THE G-BUFFER PREPASS ── before the screen pass opens" sitting directly BELOW
`clearViewport`. The comment was written when it was true and the call drifted later.

## ★ `cube3d` IS CREATED LAZILY — GUARD ANY init-TIME GPU CALL THAT NEEDS IT

`App.cube3d` is built on the first `beginMode3D`. Anything called from an app's `init` runs
BEFORE that, so `if (app.cube3d) |*c3d|` silently takes the null branch: no upload, no error,
and every later pass draws nothing. The symptom is a BLACK SCREEN with a passing smoke.

`uploadDecalReceiver` already guarded for this and says so in a comment; `uploadMeshGpu` was
added without the guard and reproduced the bug exactly. **Any new `wgpu_app` entry point that
touches `cube3d` and could be called from init needs:**

    if (app.cube3d == null) app.cube3d = draw3d.Cube3D.init(app.gpa, &app.gpu_frame) catch null;

★★ **AND NOTE WHAT THE SMOKE COULD NOT SEE**: drawing NOTHING is a valid frame. The harness
checks for validation errors, clobbers and leaks — not for "did any geometry reach the
screen". A pass that uploads no vertices and draws no indices passes every check. Host-call
COUNT is the signal that exists: the fix moved init from 4250 to 4485 calls, which is the
uploads appearing.

## ★ THE CONFIGURED WINDOW SIZE IS A REQUEST, NOT THE VIEWPORT

`AppSpec.config.window.width` is what the app ASKS for. On a phone the canvas is whatever fits,
so anchoring an overlay to that constant can place it OFF-SCREEN — where it does not draw, does
not error, and looks exactly like a feature that silently failed to work.

Use `f.window.widthf()` / `f.window.heightf()` for anything positioned relative to an edge, and
SIZE overlays as a fraction of `@min(w, h)` rather than in fixed pixels. `examples/render_texture`
does both.

★ The symptom to recognise: "the toggle is on but I see nothing", with the smoke passing. A
draw that lands outside the viewport is indistinguishable from one that never happened.

## ★ CHANGE ONE THING PER DEVICE ROUND

Chasing a skinning bug, two fixes went in together — deriving the bind pose differently AND
baking the mesh-node transform. The first was never wrong; the second was the whole bug. Because
both moved at once, the derivation looked guilty, got replaced with file-read cluster matrices,
and that sent the hunt somewhere else entirely. **Two device rounds lost to one combined edit.**

When a visual bug needs a device to confirm, change ONE variable per round, and prefer a
MEASUREMENT over a screenshot where one exists: `inverse(bind) * bindWorld` deviating from the
identity named the culprit in a single run after two rounds of staring at renders.

## ★★★ zm's TWO CONVENTIONS THAT SILENTLY DROP TRANSFORMS

Both cost a device round on the geno_dance skinning bug. **Both are invisible in a bind pose**
— where translations are zero and the composition is identity — so a green bind-pose test proves
nothing about either.

**1. `zm.vec(x,y,z)` IS A DIRECTION: lane 3 is 0.** Its own doc says so: "the translation row of
an affine matrix has no effect". Use it for a vertex POSITION and every skin matrix's
translation is discarded — the mesh collapses toward the origin while the skeleton walks away.
**`zm.pointVec(x,y,z)` sets lane 3 to 1.** `examples/skinned_mesh` writes `f32x4(x, y, z, 1.0)`
explicitly for this reason.

**2. `zm.mulMat(a, b)` APPLIES b FIRST, THEN a** — the opposite of reading it left to right, and
the opposite of raylib's `MatrixMultiply`. Measured: `mulMat(rotate90Z, translate10X)` moves
(1,0,0) to (0,11,0), i.e. translate then rotate. So **"rotate then translate" is
`mulMat(translation, rotation)`**, and "apply invBind then world" is `mulMat(world, invBind)`.

Both are now pinned by `draw3d`'s test `zm: mulMat and mulMatVec compose in the order the
skinning path assumes`. **Port raylib or MotionMatching math with this in front of you** — Simon
flagged it exactly: "our matrix multiplication is different from raylib".

★ Prefer composing an inverse from inverse parts — `mulMat(matFromQuat(conjugate(q)),
translationV(-p))` — over inverting a matrix by hand. It needs no assumption about which row or
column holds the translation, which was the assumption that produced the wrong answer twice.

## Known sandbox quirks
- **`/bin/sh` does not brace-expand**: `rm src/{a,b}.zig` is a silent no-op. Use a
  loop or `xargs`.
- **`zig build test` runs at the default stack** (no more `ulimit -s unlimited`):
  the host corpus tests that drove the spv2wgsl recursive emitter past the 8MB
  thread stack were removed (zimr1233). Transpiler regression coverage now lives
  only in the standalone `wgpu-corpus` / `wgpu-check` gate (own process), so run
  that when touching `spv2wgsl.zig`. If a NEW host test ever recurses that deep,
  prefer a `std.Thread.spawn(.{ .stack_size = ... })` wrapper over reinstating the
  global ulimit footgun.
- **A `corpus` run on a FRESH sandbox is HALF vacuous, and it still says
  `✓ NO REGRESSIONS`.** The step scans `.zig-cache` for `.spv`, so it only ever sees
  the shaders the examples you happened to build pulled in — 54 of them after
  hello_world + launcher, against 190 pinned fixtures. Every fixture then reports
  "no matching live shader", and the regression half of the gate compares nothing.
  The REAL signal in that run is the other half: `transpiled cleanly (zero
  unresolved): 54 / clean rate 100.0%`. Read that number, not the checkmark.
  **A compiler bump changes every SPIR-V md5, so `corpus-refresh` after one looks
  tempting and is a trap** on a thin cache: it would re-pin only the shaders that
  sandbox built, blessing their current output as the reference. Refresh only after
  a full `all-examples` build, on a box with the disk for it.
- **Cold setup**: the zip does NOT carry the toolchain (`tools/zig-x86_64-*` is
  excluded by the zip recipe), so on a FRESH sandbox there is no compiler at all —
  Simon uploads the Zig tarball and it goes in as:
  `tar -xJf <upload> -C tools/` → `tools/zig-x86_64-linux-<ver>/zig`.
  Then `. ./.zenv.sh` (it GLOB-resolves the toolchain dir; do not pin a version
  string in it — that file rotted for months naming a `704` build that was gone).
  **If the uploaded toolchain is NEWER than the tree's last green build, do the
  fmt/API migration BEFORE chasing build errors** — see "SURVIVING A COMPILER
  BUMP" above. A cold sandbox on a bumped compiler spent 3 of its first 4 build
  rounds on that, and the first failure named no file at all.
  There is NO `tools/build.zig`: the Zig tools (zimrlint, spv2wgsl, c2js,
  gen_externs) are steps of the ROOT `build.zig` and are built on demand.
  If something is missing, ASK — don't hunt the network.

## ★ THE TEST SUITE BUILDS ReleaseSafe, AND THAT IS A DELIBERATE CHOICE

Debug and ReleaseSafe both keep every safety check — bounds, overflow, undefined reads — which
is the part that matters. What differs is speed, and the speed is not a luxury:

    Debug        did not finish inside a 285 s budget
    ReleaseSafe  235 s cold, 9 s warm

A suite that times out gets re-run rather than read, and a re-run costs more attention than the
compile time it saved. **The first ReleaseSafe run also reported a leak the timing-out Debug run
had never reached.**

★ THE ONE THING ReleaseSafe LOSES is allocation stack traces — a leak reports "(empty stack
trace)". Switch that one module back to `.Debug` temporarily if a leak needs locating.

★ AND NOTE WHAT NEITHER GIVES YOU: a `zig run -O ReleaseFast` probe has safety OFF. A probe
written to VERIFY something is exactly where that matters, and it silently wrote past the end of
an undersized buffer while reporting agreement to four decimals.

## ★★★ AN ARENA IS NOT MOVABLE — the bug that cost two sessions

`ArenaAllocator` stores the address of its own struct inside the `Allocator` it hands out.
Return it by value and every allocation is registered with a copy that is about to vanish;
`deinit` on the copy frees nothing. It compiles, it runs, it leaks everything.

★ **THE RULE, STATED PRECISELY**: "never store an arena by value" is wrong — it is fine to store
one by value if the struct never moves. The real rule is **any struct that hands out pointers to
itself cannot be returned by value**, which also covers `std.heap.MemoryPool` and anything with a
self-referential handle. Store `arena: *ArenaAllocator`, allocate it with `gpa.create`, and free
it in `deinit`.

★★ WHY IT TOOK TWO SESSIONS: the leak reports named the *innermost* allocation, so the search
went to the array being allocated instead of the allocator handing it out. **A leak report names
the victim, not the mechanism.** What found it was printing the arena's address at construction
and at `deinit` and seeing they differed.

## ★★ TWO PATHS THAT MUST AGREE — the review checklist

Nearly every bug found by review this session had the same shape: **two pieces of code that must
say the same thing, where only one was updated.** Worth checking deliberately rather than
rediscovering:

- **A mirror of an existing function needs a case for every branch the original has.**
  `rneVelDerivative` mirrors `rne`/`comVel` and walked every DOF as a hinge — right for hinges,
  wrong for the free and ball joints `comVel` special-cases. A hinge-only test model cannot see
  it: measured, 0.0009 error on a hinge chain and **1.31 on a ball joint**.
- **A second producer of a shared output needs the first one's filters.** Swept contacts
  bypassed the rigidity and parent-child filters, and separately hardcoded `friction = 0.5`
  where the discrete path reads the material.
- **A capacity reservation and the code that consumes it must count the same way.** Capacity
  reserved three rows per equality; a `weld` needs six.
- **Scratch handed to a nested call must not alias the caller's own slices.** `BalancedIk` named
  three slices and passed the same buffer to `Ik.solve`, which writes all three. Correct only
  because of statement order.
- **A buffer indexed per DOF is not sized per body.** `deriv_cdof_dot` was allocated
  `nbody × nv` and indexed `nv × nv`.

★ AND THE LAST ONE WAS INVISIBLE IN A ReleaseFast PROBE — bounds checks are off there, so the
writes landed past the end and the numbers still looked right. The suite caught it on the first
run with safety on. Which is the same lesson as the section below, arriving by a new route.

## ★★ A FOCUSED TEST RUN IS NOT A VERIFICATION

`-Dfocus=<example>` is a fast iteration tool. It has certified broken code **twice** in one
session:

* **Dangling pointers.** Sensor names were `allocPrint`ed into a scratch arena freed on the way
  out. The focused run passed; the full suite crashed — the freed memory still read correctly
  until another test allocated over it.
* **A wrong union field.** Equality rows read `holds.connect` unconditionally, which is wrong
  for a weld. The focused run passed because **it builds with safety checks off**; the full
  suite panicked with `access of union field 'connect' while field 'weld' is active`.

Iterate with focus; **land nothing on it**. The gate is the full `zig build test`, and the two
disagree precisely where it matters most.

## Lint — hard gate at 0
Any new lint issue blocks `zig build`. Scope is `src/` + `examples/` + `tools/`
recursive, minus path-prefix carve-outs and a `deletion_skip` full-path list
(condemned files only — never add live code to dodge a fix).
- Write lint-clean on the first pass; apply the rules as you write.
- Edit lint sweeps bottom-up — a multi-line edit shifts the lines below it.
- Improve the linter (`tools/zimrlint.zig`) rather than mechanically satisfying
  its own checks; after any change, re-verify it still fires on a known-bad sample.
- **OPT-IN RULES (Sep 26).** A short list of zimrlint rules is house taste rather than
  bug-catching, and runs only when named by `--enable=<tag>`: untyped-local, anon-return,
  branch-braces, decl-order, fn-args-multiline, module-var, no-qualified-zm,
  reserved-math-names, prefer-std-alias, ascii-comments (`zimrlint --list-rules` marks them).
  zimr enables ALL of them for itself except decl-order - `zimr_lint_rules` in build.zig -
  so nothing changed for this tree. The list exists for apps built on zimr: build.zig's
  `LintRule` / `addLint` let a project pick the ones it agrees with. Every other rule is
  always on and cannot be turned off. A `lint:off` naming a tag that is not a rule is itself
  an error (`unknown-lint-tag`).
- `decl-order` (declare-before-use for file-scope `fn`/`const`/`var`) is the one opt-in
  rule zimr does NOT enable: `zig build lint -- --enable=decl-order`. The sweep once got it
  to 50 hits, all in ui.zig - **but on Sep 26 it measured 1101 again** (zimrnum 108, robot
  93, zimrphysics2d_demo/scenes 91, ui 51, ...): nothing gated it, and the per-file lint
  stamps did not record which rules were enabled, so every `--decl-order` run since the
  sweep skipped all stamped-clean files and printed nothing. Stamps now hash the enabled
  set. Enabling it for zimr means sweeping those 1101 first.
  **Decision (Simon): ui.zig stays in FEATURE order** — a widget beside its helpers.
  Reordering it into a pure DAG kills only 16 of the 50 while reshuffling ~57% of a
  42k-line file. Do NOT reorder it and do NOT `lint:off` its 50; the rule is off in the
  gate, so they cost nothing. `tools/decl_reorder.py` is for future files where the
  reshuffle is mild.
  Where a true cycle is irreducible (entities' ECS cluster, zimrphysics
  World<->subsystems, bridge, wgpu_app's active_app<->App, zimrlint's
  walkNode<->walkBlockBody, plot3d's Im<->Context back-pointer), an EXPLAINED
  `// lint:off decl-order: <why>` on the forward leg is the answer — justify it in the
  comment lines ABOVE (keep the directive line itself short, all <=120 cols).
  Self-recursion is fine.
  GOTCHA when moving a decl: a `// lint:off <rule>` line does NOT travel with it —
  re-attach it as a LEADING directive (trailing busts the 120-col rule) or the
  suppressed issue resurfaces.

## Style — one line each (the linter prints the rule when you break it)
1. 3+ fn args: one per line + trailing comma (3-4 may stay on one line if ≤90 cols).
2. Locals get explicit types — add one whenever you see a local without it.
3. Braces on EVERY branch (even `if (c) return x;` — for debugger breakpoints).
4. Casual present-tense comments: what the code does + why, never how it got there
   (no turn numbers, plan-step refs, history). Section banners `// ===== X =====`
   are fine in long files; ASCII art inside short fns is not.
5. `@splat(N)` for arrays-of-N.
6. Lift magic literals used at 2+ call sites. Lift complex sub-exprs out of
   conditions.
7. Helpers only when the name does real work and a second caller exists.
8. No mutable module globals (the C-ABI exception lives in `zimr.zig`); a
   function-scoped `const Cache = struct { var X = ...; };` is a hidden global —
   same restriction.
9. Lines ≤120 cols (markdown exempt); a trailing comma forces `zig fmt` multi-line.
10. Use the int that fits (`usize` for sizes/indices, signed for negatives, c-types
    straight off FFI) — pick for clarity, don't contort to dodge one.
11. Never read a var in the same literal that overwrites it.
12. `extern struct` only at real FFI seams.
13. An options arg, not `xxxEx` variants: `opts: FooOpts = .{}`.
14. float→int: NEVER `@intFromFloat` (banned/deprecated). Type on the line already
    (typed decl, fn return, call arg, struct/array field) → bare builtin
    `@round(x)`/`@trunc(x)`/`@floor(x)`/`@ceil(x)` — it converts in one step. Type
    NOT on the line → `zm.roundi(T,x)` / `zm.int(T,x)`(trunc) / `zm.floori` /
    `zm.ceili`. Never wrap or double-spell. Get this right the FIRST time — it's a
    30-second decision, not a build-fumble loop.
    Likewise int→float: `zm.float(x)`, never `@as(f32, @floatFromInt(x))`.
15. Matrix compose order: to apply transform P then Q, use `zm.compose(P, Q)`
    (reads in application order) — NOT bare `mulMat`. `mulMat(a, b)` applies `b`
    FIRST then `a` (later transform on the LEFT); it's fine for the already-natural
    `view_proj = mulMat(proj, view)`, but for any sequence prefer `compose`/`composeN`.
    ⚠ PORTING RAYLIB: raylib's `MatrixMultiply(left, right)` is the OPPOSITE order
    (applies left first). Translate `MatrixMultiply(A, B)` → `compose(A, B)` (same
    operand order) or `mulMat(B, A)` (swapped) — NEVER `mulMat(A, B)`. Copying
    raylib's order into `mulMat` verbatim silently reverses the composition (it
    compiles, looks close, mis-places geometry — cost us 3 turns on the decals port).
    See src/notes/math.md "Porting matrix code from raylib".

**Touching a fn means bringing the whole fn up to spec** — every line you touch
gets clearer (add asserts, comments, logs that make future bugs impossible).

## Defensive coding — assert every precondition
`assertf` liberally at the top of a fn for every precondition (arg ranges,
invariant flags, non-empty slices, unit-quat-ness). Failure is a clean trap with
`file:line` + message; without it, silent UB three frames later. Always pass
`@src()`. EXPENSIVE checks (O(n) scan, hash, tree walk) must be wrapped in
`if (comptime assert.allow_assert) { ... }` — `assertf` evaluates its `ok` arg
before checking the build flag, so an unwrapped costly precondition tanks the ship
build; the comptime guard elides it in `ship`.
```zig
assertf(substeps > 0, @src(), "substeps must be > 0", .{});
if (comptime assert.allow_assert) { /* costly check */ assertf(ok, @src(), "...", .{}); }
```

- **Never reorder, overwrite or compact an array whose elements are OWNED allocations
  freed by index — build a borrowed view instead.** `tools/spv2wgsl.zig` filtered its argv
  flags with `pos = items[1..]; pos[0] = args[0];`, which aliased one allocation into two
  slots; the cleanup loop then freed it twice. Silent heap corruption on EVERY shader
  transpile under ReleaseFast; ReleaseSafe's allocator caught it on the first build. The
  `--entry=` compaction (`pos[w] = pos[r]`) had the same defect.
- **The build tools are ReleaseSafe on purpose.** They cost ~14-20% run time vs ReleaseFast
  (~0.7s/build total) and they catch exactly the class of bug above. Worth it.

## Big-system docs live IN CODE, not in plans
Architecture for a major subsystem belongs in a `//!` module doc on that
subsystem's front-door file — not a plan or tutorial (those rot or get archived).
The WebGPU stack is documented atop `src/zimr.zig`; every sibling file gets a short
pointer to the canonical doc, not a re-explanation. When the architecture changes,
update the `//!` doc in the same turn, like a test.

## Zig 0.17 API gotchas (toolchain is 0.17.0-dev; grep the tree before assuming an API)
- **Containers are UNMANAGED, init with `.empty`, methods take the allocator.**
  `std.ArrayList(T)` IS the unmanaged type. `var xs: std.ArrayList(T) = .empty;`
  (NOT `.{}`, NOT `.init(alloc)`). Methods: `xs.append(alloc, v)`,
  `xs.toOwnedSlice(alloc)`, `map.getOrPut(alloc, k)`. `pop()` returns `?T`. Type the
  getOrPut result for the explicit-types rule:
  `const gop: @TypeOf(map).GetOrPutResult = ...`.
- **No `GeneralPurposeAllocator`, and on 2163 no `DebugAllocator` either** — it is
  `std.heap.SafeAllocator` (the old name survives as a deprecated alias):
  `var s: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{}); const gpa = s.allocator();`.
  A tool with `main(init: std.process.Init)` already gets one as `init.gpa` in Debug/ReleaseSafe,
  and it reports leaks at exit — but only if `main` RETURNS; `std.process.exit` skips the check.
- **File I/O goes through `std.Io`**: get an io
  (`var t = std.Io.Threaded.init(alloc, .{}); const io = t.io();`), then
  `std.Io.Dir.cwd().openDir(io, p, .{.iterate=true})` /
  `.readFileAlloc(io, p, gpa, limit)` / `while (try it.next(io)) |e|`. `entry.name`
  lives in a shared buffer — `arena.dupe` it before the next io call. Build text
  with `ArrayList(u8).append`/`appendSlice` + `allocPrint`, not `std.Io.Writer`.
- **`std.meta.Int` and `@Type(.{.int=...})` are GONE → `@Int(.unsigned, bits)`**
  (builtin). `std.meta.fields` is a hard `@compileError` → `std.meta.fieldNames(T)`
  / `fieldTypes(T)`.
- **`@typeInfo` is struct-of-arrays (parallel arrays).** Struct: `info.field_names`
  + `info.field_types` (no `.fields`). Fn: `info.param_types: []const ?type` +
  `info.return_type`. Enum: `field_names` + `field_values`. Iterate exactly the
  array(s) you use (`inline for (info.field_names, info.field_types) |n, t|`) — an
  unused inline-for capture is a compile error.
- **Other renames:** `bufPrintZ` → `bufPrintSentinel(buf, fmt, args, 0)`; `dupeZ` →
  `allocSentinel(u8, len, 0)` + `@memcpy`; `EnumSet.initEmpty()` → `EnumSet.empty`;
  `alignedAlloc(T, .of(T), n)` (alignment is an `Alignment` enum); a `switch` on an
  inferred error set needs `else`. `std.math.clamp(v, lo, hi)` over nested
  `@max/@min`.
- **`std.log.err` inside a test FAILS the test STEP** even if assertions pass;
  `std.log.warn` doesn't. A guard expected to fire in a test must return its error
  without logging, or log at warn.
- **The build enforces `zig fmt`** — non-conforming looks like a compile error. Run
  `zig fmt <file>` after any `.zig` edit (python-regex edits especially).
- **Test aggregators must compile or they don't run** — a green `zig build` of demos
  does NOT prove `src/tests.zig` compiles (demos don't instantiate every path). Run
  `zig build test` after toolchain-sensitive changes. `refAllDecls` is a partial net
  (non-generic decls only; generic bodies need an instantiating test).

## Working with Simon
- **Port the source you can see, not the source you remember.** Before writing Zig
  for an imgui/raylib/stb API, read the actual upstream (`/tmp/imgui-master/`
  DOCKING, `/tmp/raylib-master/`, stb under `raylib-master/src/external/`): header
  for declarations, `.cpp`/`.c` for behavior, the `_demo` for canonical usage. Cite
  `file:line` in the Zig fn's doc comment and enumerate intentional divergences. If
  it isn't on disk and you can't fetch it, ASK — API recall is the failure mode.
- **One concrete decision per question** — 2-4 options (+ implicit "other"), brief
  context, the pros and cons of each, and your **(Recommended)** pick. After decisions
  land, summarize them, confirm Simon agrees with all of them, and implement only once
  Simon says go (see "MAKE A PLAN" at the top).
- **Build the demo in parallel with the API** — land scaffolding from turn 1 of a
  multi-turn step. Every snapshot should be phone-testable.
- **Allocator policy**: if >80% of a struct's methods can allocate, the `gpa` stays
  on the struct. Caller-owned storage types take `gpa` explicitly on mutating
  methods, so the user can substitute a no-alloc-after-init allocator and pick a
  different allocator for their data than zimr's.
- **Don't present what you haven't verified** — before `present_files` of a new
  standalone, grep the bundle for undefined exports / missing externs and scan the
  build output. Simon's loop is slow; a broken standalone burns a round-trip.

## Archived history — and where the journal goes now
**claude.md has NO journal. Do not start one here.** Append the per-turn record to the
ACTIVE PLAN FILE named at the top of this file (`src/notes/<plan>.md`) — the work and its
log then live together, and both retire when the plan is archived. With no plan active,
a turn that only built or fixed something needs no journal entry at all; the code, its
tests and the zip are the record.

This file is the fresh-session entry point, not the ledger. It once carried the journal
inline; at ~4000 lines it was 81% of the file and buried the standing rules a session
actually has to read. It moved out verbatim to
`src/notes/archive/changelogs/changelog_zimr309-954_from_claude_md.md`, alongside the
earlier `changelog_zimr264-479_pruned.md`.

**What DOES earn a place here:** a rule that governs how a session works — the build
procedure, the gates, the style rules, how to work with Simon. A lesson about how one
SUBSYSTEM behaves belongs in that subsystem's code, next to what it governs (see
"Big-system docs live IN CODE"), not here.

Authoritative state lives elsewhere and must never be restated here (it drifts):
`src/web/readme.html` (what zimr is + the API), `src/notes/raylib_port.md` (the port
counts), `build.zig` (build steps + modes), the `//!` docs in code (architecture).

## Tone
- **Never apologize, never go sad.** A turn that didn't go as planned is
  *information*. Banned: "sorry," "unfortunately," "I apologize," "I failed to." If
  something broke: "caught it — here's the fix."
- **Casual, direct, generous.** Push back when Simon is wrong; show life when
  something cracks open.
- **Be skeptical of labels.** "Known issue / intentional / negative test /
  already-done" — mine or a past note's — are not evidence; verify cheaply (read the
  code, run the one input, grep the output). A 30-second check beats a stale belief.
- **This file is yours to edit.** When you learn something a future Claude needs (a
  Zig quirk, a bug pattern, a faster command), write it down. Re-read it on a
  meta/process question, a rule bent twice, or ~10 turns since the last read.

## Cross-platform (Linux sandbox AND Simon's Windows — neither is "the" one)
Targets desktop browsers + iOS Safari + Android Chrome. Never break desktop while
fixing mobile — gate mobile paths by feature detection
(`window.visualViewport`, `'ontouchstart'`), not hard-coded checks.
- Directory walks must tolerate a missing/differently-named root (`catch continue`,
  never `@panic` — it once took down the whole configure on Windows).
- No Linux-only hardcoded paths — match an OS-agnostic prefix or branch on
  `builtin.os.tag`. Compare on bare basename (a literal `"src/foo.zig"` in
  `endsWith` misses every Windows path).
- Every `.sh` a build step shells out to needs a `.bat`/`.ps1` sibling, or gate it
  so absence is a skip.

The standing check: touching `build.zig`, a script, or anything that opens a path or
probes the toolchain → "does this still work on the OTHER OS?" before calling it
done.

## ★ MEASURE THE ARTEFACT, NOT THE CODE THAT MAKES IT

Repeatedly the cheapest correct move, and repeatedly skipped:

- **Convention questions.** `genMeshCylinder` looked like it built a Z-axis mesh — `cylinderUv`
  puts the axis in its third slot — but `parametricMesh` REMAPS as it writes (`verts.y = p[2]`).
  A convention set in one function and silently rewritten by its caller cannot be found by
  reading either. Printing the mesh's bounds took one command; reading it wrong produced a demo
  full of flat ribbons.
- **A/B measurements.** Read the flag back **at the point of measurement**. A Nesterov A/B was
  nearly recorded from runs whose configuration could not be confirmed afterwards.
- **Benchmarks.** Make the case assert its own premise. A "Go1 standing" benchmark was
  measuring a robot in free fall at **z = −743 161 m**, dragged by pinned contacts, and reported
  four significant figures for it. It now prints the trunk height and whether that is standing.

### ★★ A STAGE TIMED IN A LOOP IS TIMED ON ITS OWN OUTPUT

The obvious way to break a pipeline down — call each stage 50 000 times, sum the times —
produced a total **one third** of the measured full step, with the solver reading as the
cheapest thing in it:

    kinematics 532 · comPos 476 · crb 375 · factorM 514 · solveConstraints 593
    TOTAL 3567 ns   against a real step of 12 874 ns

Both artefacts, same cause. `solveConstraints` run again on an already-solved state
converges in zero iterations. `factorM` refactors an unchanged matrix out of warm cache.
**The second call of any stage is not doing the work the first one did**, and a loop is
all second calls.

★ THE SECOND ATTEMPT WAS ALSO WRONG, in a way worth naming separately: full step vs step
with the contacts cleared, which "isolated the constraint path" at 65% — except clearing
them also removed the controller and the foot-placement loop, because both lived in the
same helper. **An A/B that changes two things measures neither.** The one valid
measurement of the three swept `max_iterations` and nothing else.

Use the profiler's zones, which wrap each stage inside a REAL step, or change exactly one
parameter and difference the whole.

### ★★★ `for (1..count)` OVER A BUFFER THAT CAN BE EMPTY IS AN UNDERFLOW

`1..0` is not an empty range in Zig, it is an integer underflow. It runs fine in release on the
host and traps instantly in the debug wasm smoke run.

**Hit twice in one session** — `examples/rocket` and then `examples/catch`, the identical line
drawing a trail before the trail had two points. Writing it down the first time did not prevent
the second, so the rule is mechanical: **any `for (1..count)` needs `if (count >= 2)` around it
unless the buffer is provably non-empty.**

★ AND THE DEBUG WASM GATE CAUGHT IT BOTH TIMES. The release host build is not a check for this
class; the smoke run is.

### ★★★ SHOW THE MOMENT, NOT THE FRAME

A demo whose verdict is decided in ~30 ms of simulated time and which only draws the live frame
has thrown away its own argument before anyone can look. `examples/catch` read as "did something
happen?" for exactly this reason: by the time the eye found the ball, the catch was over and the
ball had been deleted.

★ FOUR CHEAP FIXES, ALL OF WHICH APPLY TO ANY EVENT-SHAPED DEMO:
  * **hold the decisive instant** — keep the positions at closest approach and keep drawing them,
    with the gap as a line coloured by the outcome;
  * **leave the projectile on screen** afterwards rather than deleting it with the flight;
  * **trail the moving part**, because reaching AHEAD and chasing look identical in any single
    frame and unmistakable over a whole throw;
  * **slow it down and loop it**, so it can be watched rather than clicked at.

### ★★★ FIX THE MISSING LOOP BEFORE REACHING FOR THE PLANNER

`examples/quadruped` commanded torso attitude open-loop and undershot every command by 12-32%.
The temptation was to answer it with MPC. **Six lines of attitude feedback — read the real
orientation, integrate the error into a trim, re-solve — took it to under 3%.**

★ A 400-LINE ANSWER TO A SIX-LINE PROBLEM IS NOT A BETTER ANSWER, and beating a baseline that is
only weak because a loop is missing proves nothing about the planner. **Add the missing feedback
FIRST, then ask whether anything remains.** What remained here was the moving-command case, which
is a genuinely different and much narrower claim.

★★ AND THE MEASUREMENT FOUND A BUG IN A SHIPPED DEMO: its sliders lie, asking for 0.15 rad and
delivering 0.10. That was found by measuring a claim, not by reading the code — nobody reads
"the PD closes the loop" and notices that it closes the wrong one.

### ★★★ MEASUREMENT DISCIPLINE — seven rules, each paid for

- **A sweep must run until the trend reverses.** A servo's gain swept to 20 000 was still
  improving; stopping there would have doubled the apparent win over the planner. The optimum was
  90 000, and 180 000 reversed. **A number quoted from a sweep that never turned is whatever the
  sweep happened to stop at.**
- **And it must stay inside the parameter's legal range.** The best row of a creep sweep came from
  `impedance.min = 0.999` where the model requires `0 < min <= max < 1` and `max` is 0.99. `min >
  max` is invalid, and the number is whatever the arithmetic does outside its domain. It ran
  because the validation is a `@compileError` on joint limits with no runtime equivalent for
  contacts. **The most extreme setting is the most likely to be out of range, and the one the eye
  goes to first.**
- **Check the baseline against a known value first.** A comparison ran with `kv = 2*sqrt(kp)`
  copied from a different example, against a shipped `0.6*sqrt(kp)` — so the sweep measured a
  servo nobody uses.
- **Re-sweep the baseline when the task changes.** Tuning that was optimal for holding a pose is
  not optimal for tracking, and carrying it over understates the baseline.
- **A passive baseline must differ in exactly one thing.** Testing whether an arm helps balance,
  the tempting control is "the same robot without the arm" — which changes mass, CoM height AND
  control. The right one is the arm present and held still.
- **Report the fix and its cost in the same table.** A creep sweep reported slide distance AND
  ns/step per row: stiffening the contact cut creep **5.2x** at 301,854 ns against a shipped
  301,988 — free, within noise. Reported separately, "5x better" and "3% slower" are two facts
  needing reconciliation; together they are one conclusion. The same table also showed `iters
  60.0` in every row, revealing the solver was pinned at its cap — invisible from the creep
  column alone.
- **Write the acceptance test before the code.** It is what makes a negative result readable: an
  interception demo that missed by 0.24 m was a clean "no" against a stated bar, rather than an
  argument about whether 0.24 is close.
- **A flat sweep says the swept parameter is not the cause.** Tolerance 1e-6, 1e-8 and 1e-10 gave
  byte-identical creep. Mass 2.06 -> 0.25 kg all fell. **Both times the real cause was elsewhere,
  and the flat result is what said so.**
- **Two runs disagreeing at identical settings is the finding, not noise.** The same configuration
  scored 0.096 and 2.69 depending only on what ran before it — `applied_force` persisting between
  controllers. Do not average it, and do not re-run hoping for consistency: put the competing
  cases in one process with a shared reset.

### ★★★ A COMMENT THAT DISAGREES WITH ITS CODE IS A BUG REPORT SOMEONE ALREADY WROTE

`PoseHold` carried a comment saying gravity compensation is added and THEN the total is clamped,
"the rating bounds everything the motor does". The code clamped the tracking term and added
gravity OUTSIDE the clamp — a real ceiling of `max_torque + gravity`, measured at **1589 N·m on
an arm rated 400**, which made every servo-versus-planner comparison in the project unfair in the
servo's favour.

★ IT WAS VISIBLE IN EVERY TORQUE COLUMN PRINTED FOR HOURS. A peak of 1589 against a stated limit
of 400 is an impossibility, and impossibilities are worth stopping for — the same class as a
flat-footed robot reporting a 2 cm sole spread, or a normal force of 78.8 N under a 40 kg load.

★★ WHEN A NUMBER AND A NEARBY COMMENT DISAGREE, ONE OF THEM IS A BUG, and the comment usually
says which behaviour was intended. Read them together.

### ★★★ READ THE SOLVER BEFORE PLANNING WORK ON IT

A plan to add contact warm starting was written from field names — `feature_id` documented as
"for warm-start matching across frames", `local_a` as "position-solve anchor". Reading the code
found **warm starting already fully implemented**: a `ManifoldCache` keyed by `PointKey`, seeding
both normal and friction impulses every step.

★ AND THE ANCHOR TURNED OUT TO BE NORMAL-ONLY — the position solve projects it onto the contact
normal and discards the tangential part — so persisting it, the plan's centrepiece, **would have
changed nothing.**

★★ FIELD NAMES AND COMMENTS DESCRIBE INTENT; ONLY THE CODE DESCRIBES BEHAVIOUR. Twenty minutes of
reading turned a three-part plan into one specific addition and killed two hypotheses, one of
which was the obvious one.

### ★★★ EXTRACTING A SHARED SHAPE: THE DIFFERENCE IS THE POINT, AND THE HAZARD

Two solvers written independently — a gait and a posing routine — arrived at identical six-step
bodies: save the pose array, seed it, plant the torso, IK four legs, harvest, restore. **Only the
seed and the goals differed.**

★ EXTRACTING IT MADE THAT DIFFERENCE READABLE — body-relative goals seeded from the last command
versus world-fixed goals seeded from a stored stance. That contrast IS the explanation of walking
versus posing, and it was invisible in two copies of the same forty lines. It also put two
invariants in one place instead of two, both of which had already caused bugs.

★★ **AND THE MERGE BROKE THE GAIT.** One solver seeded only the hinges, deliberately leaving the
root's live position alone; the other did a full copy. The extraction wrote one `@memcpy` and
flattened that, so the gait solved its legs against a stale body position while its goals used
the live one. A working gait became "dances in place and falls".

★★★ SO BOTH RISKS ARE REAL: duplicated invariants drift, and **merging erases distinctions while
looking cleaner**. Diff the two bodies before merging, not after — "same six steps" was true of
the shape and false of the details. Where they genuinely differ, make it a **parameter**: a
caller cannot forget an argument it must pass, but it can easily forget a rule in a comment.

### ★★★ A RATIO TO ITS IDEAL SAYS WHAT IS WRONG; AN ABSOLUTE NUMBER ONLY SAYS HOW MUCH

**Against a limit.** A robot sliding 1 m in 20 s looked like a friction problem. The tangential
demand measured **0.20 of the friction cone** — four fifths of the grip unused, so it was not
Coulomb slip and more friction would have raised a limit never reached. On a 17-degree slope the
same measure read 0.74 while Coulomb said it should hold to 56 degrees: two independent setups,
one conclusion.

**Against perfect.** A crawling robot moved 0.207 m in 10 s, which reads as "too slow, speed it
up". Dividing by what perfect grip would deliver — `stride x hz x time` — gave **10%**, which says
something else entirely: nine tenths of every step was lost, and the fix is grip or stride rather
than cadence. Raising the rate then did exactly what the ratio predicted and the distance did not:
it lost two thirds of the travel and fell over.

### ★★★ A MODE MUST ESTABLISH EVERYTHING IT WAS MEASURED WITH

**Parameters.** A demo offered four gait patterns as buttons that changed only the leg PHASING.
One was labelled "walk 4-beat (falls)" — and it does fall, at the trot's rate and duty. At its own
settings it is the most robust gait available. **The label was an honest report of a dishonest
measurement**: changing offsets without changing rate and duty measures the new pattern at the old
one's settings, then records the result as a property of the pattern. It cost many turns of
arm-balance work spent rescuing a trot, when the answer was a gait that never needed rescuing and
was already on screen.

**Pose.** The same gait's arm counter-swing was tuned around a half-bent arm. Switched on after a
different mode had moved the arm elsewhere, the swing was offset — and its phase optimum is sharp
enough that a quarter-cycle separates walking from falling, so **the mode silently did not get the
behaviour it was measured with**.

★ THE SAME APPLIES TO RESET: clearing state is not enough if another mode will immediately
recreate it. The mode has to be cleared too.

★★ AND WHEN TWO MODES WANT THE SAME ACTUATOR FOR OPPOSITE REASONS, SAY SO IN CODE. Letting the
later writer win by accident is how an arm's counter-animation was silently overwritten.

### ★★★ TWO WAYS AN INTEGRATOR DESTROYS A WORKING SYSTEM

Both were found on the same robot, in the same week, and neither is fixable by tuning.

★★ **A NEVER-ZERO ERROR WINDS IT TO ITS LIMIT, WHATEVER ITS SIGN.** An arm driven by
`home += dt*(kp*pitch + kd*rate)` saturated its full range in every configuration and **both
sign conventions** — flipping the sign only changed the fall from 5.50 s to 0.88 s. The robot sat
at a steady -0.012 rad of pitch: small, harmless, never zero. The arm parked against its stop,
where it stopped being a momentum actuator and became dead weight at maximum lever arm. A gain
sweep could only choose how fast it failed. **Proportional is bounded by construction** —
`home = rest + k*error` returns to rest by itself, and the anti-windup gate written alongside the
integrator never fired because the integrator's own excursion kept its conditions from holding.

★★ **AND IT NEEDS A SETPOINT THAT IS REACHABLE *AND* STEADY.** An attitude trim took a standing
quadruped's commanded roll from 16-32% short to under 3%. Unchanged, it made the WALKING robot
fall at 1.80 s where it otherwise walked 0.957 m — a trot pitches by design every step, and the
integrator treats that periodic motion as error to remove. **Correct in one mode, destructive in
the other, at identical gains.** "Level" is reachable and steady while standing; while walking it
is neither.

★★★ BEFORE ADDING AN INTEGRATOR, ASK BOTH: is the error ever actually zero, and is the target
steady in every mode the system runs?

### ★★★ ASK WHAT THE COMPONENT IS DOING BEFORE TUNING IT FROM THEORY

An arm oscillated, and the arithmetic was compelling: `sqrt(kp/I)` put its natural frequency at
2.7 Hz against a 2.0 Hz disturbance — near resonance, so a tuned mass damper wants to be softer
and more damped. **Every softer setting measured worse; the stiffest shipped value was best by a
wide margin.**

★ THE ARM WAS NOT ABSORBING, IT WAS EXECUTING. Its counter-swing is a commanded trajectory, and a
compliant joint does not follow a command — softening it did not create a damper, it switched off
the feedforward that was doing the work.

★★ **A PASSIVE ABSORBER WANTS SOFTNESS; AN ACTUATOR DELIVERING A PLANNED MOTION WANTS STIFFNESS.**
Same hardware, same frequency, opposite tuning. Reasoning from the resonance without first asking
which of the two it was produced a confident prediction in exactly the wrong direction.

### ★★★ NEVER INDEX ONE COLLECTION BY ANOTHER'S ORDER

Arm joints were found with `s.robot.joints[j].name` where `j` was the MODEL's joint index.
`robot.joints` is MJCF parse order; `j` is the importer's. **Two unrelated orderings.**

★ TEXT LOST HERE. A bad edit overwrote the rest of this account with a duplicate of "A MODE MUST
ESTABLISH EVERYTHING IT WAS MEASURED WITH" above; the duplicate is removed and the original is
not recoverable. The rule survives in the heading — index a collection only by its OWN order —
but the incident's outcome is no longer recorded here.

### ★★★ AN ON-SCREEN PARAMETER READOUT CATCHES WHAT CODE REVIEW DOES NOT

A demo's panel showed `stride 0.060` while its source said `s.gait_stride = 0.16;`. An earlier
edit had inserted the new values ABOVE the originals rather than replacing them, so two lines
later the old ones overwrote them and **the demo ran the wrong parameters for several turns**.

★ THE SOURCE READ CORRECTLY IF YOU STOPPED AT THE FIRST ASSIGNMENT. Only the running value
disagreed — which is exactly what a readout is for, and the second time in this project the
on-screen number caught something reading the code did not.

★★ AND IT EXPLAINED A CONTRADICTION THAT HAD COST TWO TURNS: the probe walked forward, the demo
crept backward, on what looked like identical settings. **They were not identical, and no amount
of reasoning about the difference would have found that.**

### ★★★ IF THE SYSTEM DOES NOT NEED RESCUING, A FEEDBACK CONTROLLER CAN ONLY ADD NOISE

Three balance laws made a walking robot worse, and the explanation was in the baseline all along:
**it walks fine**, with a small steady pitch. A reactive controller had nothing to react to.

★ THE DISTURBANCE WAS PERIODIC AND KNOWN — a trot's wobble is locked to the gait clock — so the
answer was FEEDFORWARD: a bounded sinusoid at the gait frequency. **1.49x further travelled and
the pitch bias flattened to zero**, where every feedback variant had failed.

★★ AND PHASE WAS THE PARAMETER, NOT AMPLITUDE. The same 0.3 rad swing spans falling at 4.36 s to
the best result measured, purely on WHEN in the step it happens. **A sweep over amplitude alone
would have concluded "the arm does not help" at every amplitude, and been wrong.**

★★★ THE GENERAL FORM: before reaching for feedback, ask whether the disturbance is KNOWN.

★ TEXT LOST HERE. A bad edit ate the rest of that sentence and welded on a fragment from another
section ("...instability and the natural next step is a third gain sweep"); not reconstructed.

★★ **Report an actuator's excursion whenever it is under closed-loop control.**

### ★★★ PROBES AND HARNESSES — the failures that produce confident wrong answers

- **A failed edit means the next run is the PREVIOUS build.** Twice in one session a `python`
  edit raised an assertion, the build reused the existing binary, and its output was read as new
  data — reversing a real conclusion. The signature is always a traceback above plausible output.
  **Treat any run whose edit reported an error as having produced no data at all.**
- **Assert every string replace.** `zig fmt` moves the text under you between turns, so a patch
  written against remembered source silently matches nothing. Assert the old text is present, and
  grep for the new text before reading results.
- **When a probe builds its own scene, check it is the scene under test.** A gait sweep measured a
  bare Go1 and recommended a 2.7x stride; the demo splices a 2 kg arm and fell over. The probe
  built its model from the fixture, the demo modifies the fixture at load time.
- **When a probe needs its fifth edit, rewrite it.** Patched probes accumulate stale parameters
  and dead branches, and each further edit is likelier to fail than the last.
- **When the same side loses across unrelated problems, suspect the harness.** A planner losing
  three different comparisons was not three tuning failures; it was one contaminated array.
- **Unit oracles cannot see where the caller stands.** Every unit test passed while the caller
  handed the tested function a reference no one could reach. **Test the composition, not only the
  parts.**

### ★★★ CONFIRM WHICH COMPONENT YOU ARE DEBUGGING BEFORE READING ITS SOURCE

A creep bug was investigated for two turns in `zimrphysics.zig` — its cache, its `AxisPart`, its
`prepare()` — and a 40-line plan written against those types. **The creeping solver is
`robot.zig`.** The bridge harvests contact GEOMETRY from zimrphysics; robot.zig builds and solves
the constraint rows, and every quantity the creep was measured with (`constraint_force`,
`rows_per_contact`, `contacts`) is robot.zig's.

★ THE MEASUREMENTS WERE ALWAYS RIGHT; the reading was in the wrong file. **A project with two
solvers needs the question "which one runs this?" answered before the question "how does it
work?"** — and the answer is in the call path, not in the plausibility of the names.

### ★★★ CHECK WHAT A MATURE IMPLEMENTATION DOES BEFORE BUILDING THE CLEVER FIX

A 40-line plan to add tangential position anchors to the contact solver was written, scoped and
line-referenced. Then MuJoCo's source: **it gives friction rows zero position error on purpose**
(`mju_zero(cpos, con->dim); cpos[0] = con->dist;`) despite having the machinery to do otherwise.

★ IT STIFFENS THE FRICTION CONSTRAINT INSTEAD — `R[i+1] = R[i]/impratio` — documented as
"preventing slip, without increasing the actual friction coefficient", which is the problem
statement verbatim. **A one-parameter answer where the plan had a solver change.**

★★ THE MOST RESPECTED IMPLEMENTATION CHOOSING NOT TO DO SOMETHING IS EVIDENCE. Not proof — PhysX
does use friction anchors — but enough to reorder the work: try the parameter, keep the anchor as
the fallback.

★★★ WHEN A HARD PROBLEM HAS BEEN SOLVED BEFORE, the question is not "how would I do this" but
"how did they, and why that way".

### ★★★ DERIVE A FRAME CONVERSION, DO NOT GUESS THE AXIS

A slope was tilted about Y in the solver's Z-up frame and drawn with `rotationX` in the render's
Y-up frame. Substituting the swizzle `(x,y,z)_zup -> (x,z,y)_yup` into the rotation shows it
becomes a rotation in the render x–y plane — **about Z** — with the sign flipped.

★ THE SYMPTOM POINTED AT THE WRONG THING. The robot's pose was set in solver space and was
correct throughout; **the floor was drawn wrong**, which reads exactly like the robot banking the
wrong way. Two lines of algebra would have settled it before the first screenshot.

★★ AND THE NUMBERS WERE NEVER AFFECTED — the physics ran in solver space the whole time. **A
rendering bug can make a correct measurement look wrong**, so check which side of the swizzle a
discrepancy lives on before doubting the simulation.

### ★★★ WHEN PREVIEW MAKES IT WORSE, THE ERROR IS NOT LAG

A gimbal held its point to 17 mm. Feeding the arm the base's FUTURE pose — free, since the
routine is closed form, and the exact information a planner would spend a horizon computing —
made it **four times worse**, with the arm's joint sweeps GROWING from 1.63 to 2.69 rad.

★ MORE EFFORT FOR A WORSE RESULT MEANS THE CONTROLLER IS FIGHTING THE WRONG THING. Preview only
helps when the error is lag; here it was steady-state deflection under load, which a lead
actively aggravates by asking the arm to be somewhere it will then have to come back from.

★★ THE DIAGNOSTIC IS CHEAP AND WORTH RUNNING BEFORE ANY PLANNER: **feed the controller the
future and see if it improves.** If it does not, MPC's main advantage is unavailable and the
remaining error is somewhere a loop can reach.

### ★★★ TWO SOLVES WRITING ONE ARRAY IS A SEQUENCING BUG, NOT A CONTROL BUG

An arm's counter-animation was computed correctly and then overwritten: its IK ran at line 1075,
and the torso's `solveBodyPose` — which copies EVERY hinge joint from a stored stance — ran at
line 1181. The reported symptom was "I don't see any counter animating", and the arm was solving
perfectly the whole time.

★ **NO AMOUNT OF TUNING EITHER SOLVE WOULD HAVE FOUND IT.** When a controller's output seems to
have no effect, check who else writes its output array before checking the controller. Order is
part of a controller's definition.

### ★★★ A REFERENCE COMPUTED FOR A STATE THE ROBOT NEVER REACHES CANNOT BE TRACKED

A gimbal's arm reference was built against the COMMANDED torso pose. The torso droops and lags,
so the arm tracked its reference perfectly and still missed — the reference described a robot
that never existed.

    arm IK against the COMMANDED torso    117 mm of drift
    arm IK against the ACTUAL torso        20 mm

**Six times better from changing what the reference is anchored to**, with a worse controller.
And feedforward along the commanded trajectory — the same information a planner would use —
bought nothing, which is what says the fault is upstream of the controller entirely.

★ **ANCHOR REFERENCES TO MEASURED STATE, NOT COMMANDED STATE.** Feet where they are, base where
it is, then compute what the rest must do. The alternative accumulates every unmodelled error
into a target nobody can reach.

★★ AND A FEEDFORWARD THAT CHANGES NOTHING IS A DIAGNOSTIC: it means the tracking is not the
bottleneck, so no amount of better control — planner included — will help until the reference is
fixed.

### ★★★ A TIMESTEP THAT IS FINE FOR ONE ROBOT IS NOT A GENERAL SETTING

A coarser sim step (1/125) was measured on a fixed-base arm to be both cheaper AND more accurate,
and became the demo's setting. Reused on a legged robot, **every controller fell** — including
servo gains that stand comfortably at 1/250.

★ THE ARM HAS NO CONTACTS. Contact stiffness is what sets the rate a leg needs, so nothing about
that measurement transferred. **A number measured on one robot is a fact about that robot**, and
carrying it across is the same mistake as carrying gains across.

### ★★ FINITE-DIFFERENCE DERIVATIVES DO NOT SURVIVE CONTACT

`optimize` drives a fixed-base arm to 1.63x better than a tuned servo. Pointed at a quadruped
holding a gimbal, it put the robot on the floor while every servo setting stayed up.

★ NUDGE A JOINT AND A FOOT MAY GAIN OR LOSE A CONSTRAINT ROW; **the quotient across that boundary
is not a derivative of anything.** `examples/mpc_quadruped` already ships with "NOTHING HOLDS
YET, INCLUDING THE STAND" in its header — the same wall, reached from a different direction and
at the cost of a turn that a two-minute read of that header would have saved.

★★ FOR LEGGED ROBOTS THE TOOL IS THE SRBD TRUNK PLANNER with an explicit friction pyramid, not a
finite-differenced whole-body one.

### ★★★ INSERT JOINTS AT THE END, OR RENAME EVERY INDEX DOWNSTREAM

Splicing an arm into a quadruped's MJCF *before* the legs put its four joints first in qpos
order, shifting every leg index by four. Leg angles landed in arm joints, the legs stayed
straight, and the robot toppled on reset.

★ IT PRESENTED AS A MASS PROBLEM and survived two sweeps chasing that: six rest poses, then
masses from 2.06 kg down to **0.25 kg** — all falling. **A quarter-kilo arm toppling a 12 kg
robot is impossible**, and that impossibility is what broke it open. Moved after the legs, every
mass from 0.25 to 2.06 kg stands.

★★ **A SWEEP WHERE NOTHING CHANGES IS TELLING YOU THE SWEPT PARAMETER IS NOT THE CAUSE.** Twice
now in this project — iteration counts on the catch, masses here. Believe it the first time.

★★★ AND THE RULE: **appending joints changes no existing index; inserting in the middle renames
every number downstream.** Appending is nearly always available and nearly always right.

### ★★★ ANYTHING THAT CHANGES `nq` INVALIDATES EVERY ARRAY KEYED TO IT

Splicing a four-joint arm into a robot took `nq` from 19 to 23. The `home` keyframe still carried
19 numbers, `applyKeyframe` correctly refused it, **and both call sites discarded the result with
`_ =`** — so the refusal was silent and the robot never got its standing pose. The reported
symptom was "I can't see the arm", which is three inferences away from the cause.

★ `examples/humanoid` DOCUMENTS THIS EXACT BUG, in a comment written after it happened there:
*"the keyframe was 28 numbers, the model 70 once the projectiles joined the tree."* **A note in
one example does not protect another.** The rule has to be mechanical: a model transform owns
every consequence of the transform — keyframes, saved poses, references, weight vectors — not
just the bodies it inserted.

★★ AND NEVER DISCARD A VALIDITY RESULT WITH `_ =`. A silent refusal is worse than a crash,
because a crash names its cause and a silent one makes you debug the renderer.

### ★★ GREP BEFORE DESIGNING

Twice in one session a capability was designed from scratch and found to already exist —
`Plan.readLimits`, then the entire `Cost.task` assembly. Both were present, documented and
unused. **Search for the name before writing the plan**; the cost is one grep and the alternative
is a turn.

### ★★★ A DEMO THAT IDLES UNTIL CLICKED HAS A SMOKE TEST THAT VERIFIES NOTHING

`examples/catch` smoke-passed while carrying an assert that fired on the very first ball. The
run executes sixty frames; with nothing in flight it never entered `optimize`, so the failing
path was never touched. **The gate was green because the interesting code did not run.**

★ THE FIX IS ONE LINE: **start the demo doing the thing.** Throw the ball, launch the descent,
begin the sweep — in `initState`, so the automated run exercises the planner rather than an idle
scene. It is also a better demo: something happens the moment it opens.

★★ AND WHEN IT DID RUN, IT FOUND TWO MORE THINGS IMMEDIATELY: a reference sliced to the wrong
length (`optimize` asserts `(horizon + 1) × nstate`, and `setHorizon` moves the horizon under a
fixed buffer), and Node's 2 GB heap exhausted by profiler timestamps. **Both were invisible while
the scene sat still.**

### ★★★ A PANEL SIZED IN VIEWPORT FRACTIONS EATS A PHONE

Every robot demo asked for a panel 70-80% of the viewport HEIGHT. On a desktop that reads as a
sidebar; on a phone it leaves the thing the demo is about as a sliver at the bottom, which is
backwards for anything whose argument is something you WATCH.

★ TWO FIXES, BOTH ONE LINE:
  * **let the window size to its content** — `.flags = .{ .always_auto_resize = true }` with a
    height of `0` — so it is as small as its widgets allow rather than as large as the screen;
  * **cap the WIDTH** at ~340 px on narrow viewports instead of `viewport_w - 16`, so it does
    not span the display either.

★★ AND EXPLANATORY PROSE DOES NOT BELONG IN AN INTERACTIVE BOX. `ui.zig` names the recipe for a
borderless overlay: `.{ .no_title_bar, .no_resize, .no_move, .no_background, .no_inputs }`.
**`no_inputs` matters as much as `no_background`** — text that silently eats taps is worse than
text in a box. Put the widgets in the window and the sentences on the scene.

### ★★★ A SINGLE COMPILE UNIT LONGER THAN THE TIMEOUT NEVER FINISHES, EVER

`zig build test` compiles `src/tests.zig` and everything it imports as ONE unit. There is no
mid-compile checkpoint: kill it at 170s and the next run starts from zero. So once that unit
crosses the tool timeout it becomes **unfinishable by retrying**, and the retry loop looks
exactly like a build that is "nearly there".

Measured: the host suite was 157s, then 163s, then adding ~600 lines to a file in
`tests.zig` pushed it to **~335s**. Three identical `rc=124` timeouts followed, with an
EMPTY log each time — that emptiness is the tell, because a build making progress prints.

★ THE FIX IS TO DETACH, not to retry:

    nohup setsid $ZIG build test -Dfocus=tier-a -Dautofix=false -j1 \
      >/tmp/bg.log 2>&1 < /dev/null &
    # then poll across turns: pgrep -x zig, and watch /tmp/bg.log

It runs to completion with no wall clock limit; poll `pgrep -x zig` until it is gone. **Within
the same turn only** — on 2163 a detached `test-fast` was alive at two polls and gone, with no
`EXIT` line, by the next turn. Whatever it finished is cached; whatever it did not must be re-run. Once
it lands, the cache is warm and the ordinary `zig build test` returns in about a second.

★ AND THE DIAGNOSTIC RULE: **two identical timeouts mean stop and measure, not retry.** Check
`wc -c` on the log (empty = still compiling, never got to running), `pgrep -x zig` for
orphans that survived the kill, and `du -sh .zig-cache` for growth. Three blind retries cost
more than the one detached run that answered it.

**And plot before theorising.** `solver 60 it` was read three times as "PGS cannot handle
contact" and used to argue Newton was the critical path. One convergence curve showed it
plateauing at 4.0e-6 against an unreachable 3.55e-6 target — not slow convergence, a stopping
criterion that could never fire. The fix was one option and 2.3x faster. *Too slow*, *stuck* and
*already finished* look identical in a scalar and obvious in a plot.

## ★ A DEFAULT THAT LOOKS LIKE AN ANSWER IS WORSE THAN NO ANSWER

The most expensive bugs in this project all return something usable where they should fail:

- `moveKinematic` **steered** where the caller wanted a teleport — reasonable for its original
  user, silently wrong for the new one, and five sessions of contact debugging.
- `bodyIndex("")` returned the **world**, so a failed lookup read the world's pose as a robot
  part.
- An inherited `mesh` overrode an explicit `type`, so a collision capsule became a mesh and was
  then SKIPPED — a robot that imports cleanly and falls through the floor.
- `applyKeyframe` refused silently on a length mismatch and the caller discarded the result:
  four pose buttons that did nothing, under a label claiming they had worked.

When repurposing a function, re-read what it actually does. When a lookup can fail, make the
failure visible at the call site.

## Coordinate systems (read before touching positioning code)
Three pixel kinds, and a logical-vs-CSS distinction that only matters under `.fit`:

| Name           | Where you see it                                              | Phone (DPR=3, 360-wide) |
| -------------- | ------------------------------------------------------------- | ----------------------- |
| **CSS pixel**  | `event.clientX`, DOM styles, `visualViewport`, `clientWidth`  | 360                     |
| **Backing px** | `canvas.width`, the GPU viewport / framebuffer                | 1080 = 360 × DPR        |
| **Logical px** | wasm widget code — `box.x`, `f.window.screen_width`, input    | = CSS in `.responsive`; fixed `cfg.window.width × .height` in `.fit` |

**Modes (`cfg.window.scale`)**:
- **`.responsive`** (default): logical px == CSS px. The wasm reads the canvas CSS
  dims each frame and reprograms the projection. Hit-test direct; HUDs anchor to
  `f.window.screen_width/height`. Use this unless you have a deliberate fixed design.
- **`.fit`** (opt-in): fixed logical size, scaled uniformly with letterbox bars on
  aspect mismatch (the bars are intentional). For retro games, kiosk, forced
  orientation.

**Input contract (single invariant): all input coords entering wasm are logical
pixels** — mouse, touch, drag, wheel. The bridge does CSS→logical at the JS seam, so
`getMousePosition()` matches the space `drawRectangle(x,y,...)` draws in — no ratio
scaling in user code, ever. When off-size on phone: open in desktop Chrome (DPR≈1) —
correct there ⇒ DPR-related, wrong ⇒ mode-related; then log
`x,y,w,h,screen_w,clientW,dpr` and do the pixel arithmetic, don't guess.

## Sharp edges
- **★ SCCP'S FOLD RULE — a one-word bug that disabled folding almost everywhere.** The exclusion
  was documented as "skip the fold when the merge block carries an OpPhi AND is itself a construct
  header", and the code tested the first conjunct only. Zig lowers every branchy helper into a
  numeric phi state machine, so nearly every merge carries a phi and folding was off almost
  always. Implementing the rule as documented (`mergeBlockPhiWouldOrphan`) removed **44% of every
  `if` in every shader** — 3973 -> 2242 across 350 shaders, WGSL 8.1% smaller — with 350/350 still
  transpiling and zero undeclared identifiers.
  **When a guard's comment describes an AND and the code tests one conjunct, the comment is
  usually right and the code is the bug** — but check which, because over-approximating in a
  safety check is invisible: it just silently does nothing useful. The residual survivors (merge
  IS a header AND carries a phi) are the case the rule legitimately protects.

- **★ THE SAMPLER-UNIFORMITY GATE (`sampler_uniformity` in src/spv2wgsl.zig).** Runs on every
  shader at build time, on the SCCP-folded SPIR-V, and FAILS THE BUILD when an implicit-LOD
  `textureSample` is reachable only through a branch whose condition derives from a varying.
  This class used to be discoverable ONLY on device, at pipeline creation. Regression-pinned
  by two fixtures in `src/tests/fixtures/uniformity/` (the real decal_fs as it failed, and the
  fixed one as the negative control).
- **Building that gate taught two things worth more than the gate itself:**
  1. **A PHI WHOSE INCOMING VALUES ARE ALL CONSTANTS CAN STILL BE NON-UNIFORM.** Zig's SPIR-V
     lowers a branchy helper into a numeric phi state machine: `%654 = OpPhi(59u, 61u)`, then
     `%659 = %654 == 61u`, and the sample lives under `%659`. Every value in that chain is a
     constant, so a pure DATA-flow taint says "uniform" and sails straight past the bug. The
     phi is non-uniform because the CONTROL FLOW selecting between its arms is. A uniformity
     analysis needs control dependence, not just def-use. My first version had exactly this
     hole and produced a false negative on the very bug it was written for — it only got
     caught because I re-introduced the bug and demanded the gate fire.
  2. **`types.operandsAt` returns the words AFTER the opcode word.** Index operands from 0
     (`ops[0]` = result_type, `ops[1]` = result), not from 1. Getting this wrong panicked on
     all 260 shaders.
- **A GATE THAT HAS NEVER FIRED IS NOT A GATE.** Always prove it by re-introducing the bug
  (revert the fix, rebuild, demand a non-zero exit), THEN prove no false positives across
  every shader. "It compiles and reports nothing" is indistinguishable from "it is broken".
- **A BRANCHING HELPER IN THE MATH VOCABULARY IS A HAZARD TO EVERY `textureSample`
  DOWNSTREAM OF IT.** `textureSample` needs derivatives, so it needs UNIFORM control flow.
  A `zm` helper written as `if (v < 0) 0 else ...` emits REAL branches; if its condition
  derives from a varying (it usually does), the transpiler nests every downstream sample
  inside that branch and Dawn rejects the shader: *"'textureSample' must only be called from
  uniform control flow"*, with the tell-tale note *"reading from module-scope private
  variable 'o_normal' may result in a non-uniform value"* (that private var IS the varying).
  Keep zm's GPU vocabulary BRANCH-FREE: `@min`/`@max`/`@select`, never `if`. `clamp01` IS
  `clamp(v, 0, 1)`; `step` is `@floatFromInt(@intFromBool(v >= edge))`. The source-level
  `[sampler-in-branch]` lint CANNOT see this — decal_fs's source samples unconditionally at
  the top; the branch was manufactured inside a helper and exists only in the emitted code.
- **Nesting in the emitted WGSL is NOT automatically a bug.** spv2wgsl's phi-dispatch emits
  dead `if (73u == 73u)` guards. A CONSTANT condition is uniform, so a sample inside one is
  legal — `effect_ascii_fs` sits 3 `if`s deep and is valid. The question is never "is it
  nested" but "does the enclosing condition derive from a varying". A depth-only heuristic
  gives false positives; I raised one and had to retract it.
- **A `pub const X = @compileError(...)` decl takes down the TEST GATE.** `src/tests.zig` runs
  `std.testing.refAllDecls(zm)`, which REFERENCES every pub decl — and referencing a
  @compileError decl is, of course, an error. Dead spellings (`mix`, `saturate`, `stepEdge`)
  are therefore PRIVATE, empty decls whose doc comment names the canonical spelling: `zm.mix`
  fails with "not marked pub" and Zig points at that comment. `@typeInfo` only exposes pub
  decls, so refAllDecls never sees them. features_test pins that they are NOT pub; zimrmath's
  own test pins that they still exist.
- **Drag/orbit camera first-touch pop** → a `dragging: bool` latch that SKIPS the
  first drag frame. `getMouseDelta` is `current − previous`; on the no-touch→touch
  boundary `previous` is stale, so frame 1 jumps. Fix:
  `if (down) { if (s.dragging) apply(getMouseDelta()); s.dragging = true; } else s.dragging = false;`
  — raw delta, no threshold, so rotation tracks 1:1 and only the press frame is
  skipped. Don't use the UI `getMouseDragDelta` threshold helper for a free camera.
- In library code import the math module as `const zm = @import("zimrmath.zig")`; in
  examples it's `const zm = @import("zm")`.
- **Every file that does math imports `zm` and binds `Vec`**: `const zm =
  @import("zm"); const Vec = zm.Vec;` (and `Vec2`/`Vec3`/`Mat` as needed). Prefer
  `zm` directly — do NOT reach for `z.Vec` (it isn't even re-exported through
  zimr). `Vec` is zimr's central type; write it, never the longhand `@Vector(4,
  f32)`. This holds in ALL shaders too, io schema files included: `Vec` in an
  `extern struct` UBO/vertex field transpiles to the identical `vec4<f32>` std140
  layout (verified — terrain_fs_io's Vec-typed Ubo → WGSL `field_N: vec4<f32>`,
  smoke PASS), so externs are NOT a special case. The `prefer-vec` lint rule
  enforces this (`@Vector(N,f32)` → `Vec`/`Vec3`/`Vec2`; only `zimrmath.zig`'s
  canonical `const Vec = @Vector(4,f32)` definitions are exempt; `@Vector(4,u8)`
  and other non-f32/exotic widths keep the raw form). GATING (default on) — the
  whole tree (246 findings / 73 files) was migrated in zimr531, so any new
  `@Vector(N,f32)` fails the gate; `--fix` autofixes wherever `Vec` is bound,
  `// lint:off prefer-vec: <why>` is the escape hatch.
- **Never re-export a zm type through a namespace** (e.g. `pub const Vec2 = zm.Vec2` inside one
  struct that a sibling then borrows as `other.Vec2`). That manufactures a false dependency edge
  between siblings. Every file/section declares its own `const Vec2 = zm.Vec2` (binding name ==
  member name). In big flat files, a borrowed type is the usual cause of a "cycle" that is really
  just a re-export.
- **FILE-AS-STRUCT is the house pattern for a single-type file** (`Canvas.zig`, `BindGroupCache.zig`,
  `WgpuGl.zig`, `SwAdapter.zig`): rename the file CamelCase = the type, top-level
  `const <TypeName> = @This();` (a descriptive alias — NEVER bare `@This()` or `Self` inline),
  fields+methods hoisted to file scope, helper types (Options, Key) nested under it. Importers do
  `const Canvas = @import("Canvas.zig");`. Multi-export namespaces (`gpu.zig`, `raster.zig`)
  stay namespaces — don't force them.
- **Graph tooling** (all Zig, no Python — the analysis/codegen purge is complete):
  `tools/import_graph.zig` is the shared library (collectImports, Graph, sccs, levels,
  transitiveReduction); `zig build dag-check` is the level report for top-level `src/*.zig` (by
  basename; the one place `@import("zm")` counts as an edge) — the tree-wide cycle GATE is
  zimrlint's `import-cycle`, which runs before every compile;
  `zig build files-md` regenerates the per-file atlas (curated text in
  `tools/file_descriptions.zig`); `zig build dag-png` renders `src/notes/dag.png` (layered) and
  `dag_force.png` (force-directed), tunables at the top of `tools/dag_png.zig`. Current shape:
  83 modules and 385 import edges on 2163 (dag-check), 0 cycles. **When porting a generator, prove it:**
  snapshot the old output and diff byte-for-byte before deleting the original.
  The PNGs are NOT in the ship zip (the recipe excludes `*.png`) — attach them separately.
- **COMPILE-CHECK RECIPES for cross-cutting refactors**: native/Canvas path → `zig build dag-png`
  (~1 min, compiles `zimr_native_mod`); WebGPU path (gpu/wgpu_app/caches) → `zig build hello-world`
  (compiles the full wgpu wasm module). Both run lint over the roster first.
- **`grep | head` HIDES consumers.** Always grep WITHOUT `head` before declaring a rename complete
  (a `head` once hid a `z.descriptor_encoder` user and shipped a broken build).

- **Never count on the NEXT turn to collect a detached run.** One died between turns (its log empty); another, from a stalled turn, finished on its own. Poll every run to completion within the turn that starts it.
- **A turn must never wait on a long test.** Anything over ~60 s runs detached (setsid nohup, log to /tmp) and is polled with sleeps under ~120 s per call. A turn that died waiting (Sep 25, D5 step 3, 162 s) lost its whole reply though the test passed.
- **A test filter that matches nothing compiles NO test bodies** (`--test-filter` skips analysing non-matching tests), so `-Dtest-filter=NO_SUCH` checks only non-test code. To compile-check a test, filter on ITS name (Sep 26: a missing field passed such a "check").
- **Long turns stall** (twice on Sep 26, the reply lost though the work went on). Keep a turn to a few runs; record and end before it grows.
