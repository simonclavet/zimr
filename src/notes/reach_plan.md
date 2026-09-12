# Reaching a target in 0.3 s — the example that fits the architecture

## ★★★ THE ARCHITECTURE SIMON DESCRIBED, AND WHY IT MAKES SENSE

> RL chooses a kinematic target 0.3 s ahead; MPC reaches it smoothly and precisely.

This is a sound and standard division of labour, for a reason worth stating: **RL is strong at
*what to do* over long horizons with objectives nobody can write down, and weak at precise,
smooth, constraint-respecting execution. MPC is exactly the reverse.** And the interface — a
kinematic target 0.3 s out — is low-dimensional, which is what makes the RL side tractable at
all. A policy emitting torques must learn the arm's dynamics; a policy emitting a hand target
does not.

★ IT ALSO REFRAMES WHAT A DEMO HAS TO PROVE. Not "MPC beats PD at a task" — the catch showed how
slippery that is — but the narrow claim the architecture actually rests on:

> **Given a target 0.3 s away, MPC reaches it better than PD.**

## ★★ THE BIND THAT MAKES THE CLAIM PROVABLE, AND IT IS MEASURED

PD is genuinely good at reaching a joint target, so a demo means nothing unless the setup
contains something PD cannot escape. **Torque limits are that thing**, and the tradeoff is real:

    controller     err at 0.30 s   overshoot   peak torque
    PD kp   300       0.1745        0.1745         260
    PD kp  1200       0.0995        0.1166         318
    PD kp  4000       0.1861        0.2084         348

★★★ **THERE IS NO GAIN THAT DOES BOTH JOBS.** Slow enough not to overshoot means not arriving;
fast enough to arrive means saturating and sailing past. The best of the family lands **0.0995 m
short at the deadline and then overshoots by 0.117** — and the two fast settings exceed the
260 N·m limit outright, which a real actuator would simply refuse.

**A planner has no such tradeoff**: it is told WHEN, and works out the profile that fits inside
the torque it actually has. That is a structural difference, not a tuning one, and it is exactly
the regime the RL-plus-MPC architecture puts MPC in.

## 🚧 AND THE PLANNER SIDE IS NOT WORKING YET

    MPC 0.30 s        1.0298        1.2608         260

It commands full torque — so the control box is live — and does not arrive. **Untested
hypotheses are not worth writing down here**; the first move is to print `Result` (cost in and
out, `converged`, `regularization`), which distinguished "starved" from "wrong cost" in one shot
on the catch and would have saved three turns had it been done first.

★ ONE THING ALREADY LEARNED FROM IT: **the horizon rule reverses between these two problems.**
For an interception, `horizon = time remaining` is right — the moment is fixed and passes. For a
recurring 0.3 s deadline it is wrong, and shrinking to the floor of 2 knots left the plan no room
at all. "Horizon equals time remaining" is not a rule; it is an answer to **"does the moment
recur?"**

## The demo, once the planner works

**A sequence of targets, one every 0.3 s** — which is exactly what the RL layer would emit. Two
arms, same targets, same motors.

  * the PD arm is perpetually a step behind, overshooting and ringing into each new target;
  * the planner hits each one, at rest, on time;
  * **torque bars showing saturation** make the bind visible rather than asserted — the PD arm
    pinned at its limit while the planned one sits inside it.

★ ACCEPTANCE TEST, FIXED NOW: over 10 targets, **hand error at each deadline under 2 cm, zero
overshoot beyond 2 cm, and peak torque never above the actuator limit.** PD to be reported at its
best gain, whichever that turns out to be — its own best case, not a strawman.

★★ AND IT PREVIEWS THE REAL SYSTEM. If the targets come from a script today and a policy later,
nothing below the interface changes. The demo IS the bottom half of the architecture, which makes
it worth more than a one-off.

## ★★★ THE DIAGNOSIS RAN PROPERLY, AND FIXED TWO REAL THINGS — AND IT STILL LOSES

`Result` first, as it should have been all along:

    t 0  cost 1.27e4 -> 1.13e4  it 8  conv false  reg 1e-6  ctrl0   -2.5
    t 5  cost 4.12e4 -> 1.07e4  it 8  conv false  reg 1e-6  ctrl0  260.0
    t10  cost 5.83e4 -> 6.14e3  it 8  conv false  reg 1e-6  ctrl0  257.6
    t15  cost 3.20e4 -> 5.87e3  it 8  conv false  reg 1e-6  ctrl0 -132.0

★ **THE INITIAL COST JUMPING TENFOLD BETWEEN SOLVES IS THE TELL.** A warm start that works
produces an initial cost near the previous FINAL cost. Ten-fold jumps mean the seed no longer
describes the problem — and `ctrl0` chattering between its bounds is the same fact from the other
side.

### Two real bugs, both fixed

  1. **`shift` ran every tick and `optimize` every fifth.** Four shifts in five propagated the
     tail of a chattering sequence with nothing correcting it: garbage slid forward and
     re-consumed, warm-start rollout diverging, `initial_cost` reaching **1.5e5**, the solver
     spending its whole budget climbing back. **Shift and solve must be paired.** After pairing,
     initial costs track previous finals (1.27e4→1.17e4→1.13e4→1.06e4) and the control commits to
     a direction.
  2. **The reference was the goal at every knot** — "be at the destination already", for the
     third time this session after the rocket and the catch.

### And a third thing, which is the interesting one

Replacing that with a **smoothstep** reference — the fix that worked for the rendezvous — helped
a little and was still wrong, for a reason worth keeping:

★★ **A SMOOTHSTEP HAS ZERO SLOPE AT THE START.** It tells the arm to barely move for the first
fifth of the window, and for "arrive in 0.3 s under a torque limit" the optimal profile is close
to BANG-BANG. I was prescribing the opposite of the answer.

**The same reference shape is right for one problem and backwards for the other**: a rendezvous
cares about the path because arrival must match something moving; a deadline reach cares only
about the endpoint. **A reference is scaffolding for a planner that cannot see far enough — when
it can see the whole task, scaffolding is a worse plan imposed from outside.**

## 🚧 STILL LOSING, AND STOPPING HERE

    formulation                          err at 0.30 s
    PD, best gain (kp 1200)                  0.0995
    MPC, goal at every knot                  1.0298
    MPC, paired shift + smoothstep           0.7862
    MPC, terminal-only, zero running weight   1.0555

**Three formulations, no improvement, and the best of them is eight times worse than a PD.** By
the rule this session keeps re-learning, that is not a tuning surface — stop and write it down.

★ WHAT IS NOT THE PROBLEM, MEASURED: the control box works (peak torque exactly 260, never over,
while two of the three PD gains BREACH it at 318 and 348). The warm start now works. The arm is
capable — the PD covers 1.12 m of the 1.218 in the window.

★★ THE NEXT THING TO MEASURE IS THE SAME ONE THAT SETTLED THE CATCH: **`conv false` at 8
iterations on every single solve.** On the catch a 6-to-60 sweep proved iterations were NOT the
answer, and the null result pointed at the cost. Run that sweep here before touching a weight —
if 60 iterations converge and close the gap, the answer is the budget; if they change nothing,
the cost is asking for the wrong thing and the terminal-vs-running balance is where to look.

**Do not tune before that sweep.** It costs one probe and it has twice been decisive.

# ═══ TRACKING A MOVING TARGET — AND A BUG THAT INVALIDATED EVERY EARLIER COMPARISON ═══

## ★★★ `PoseHold` WAS EXCEEDING ITS OWN TORQUE LIMIT, BY UP TO 4x

The comment in `robot_control.zig` said:

> *"gravity compensation is added, THEN the total is clamped... The rating bounds everything the
> motor does."*

The code clamped `wanted` and added `bias_force` **outside** the clamp. So the real ceiling was
`max_torque + gravity` — **measured at 1589 N·m on an arm rated 400.**

★★ **EVERY PD-VERSUS-PLANNER COMPARISON IN THIS PROJECT WAS UNFAIR IN THE SERVO'S FAVOUR.** The
planner is held to its box by `boxQP`; the servo was not held to anything. On the tracking test
the PD's peak torque read 567, 946 and 1589 against the planner's exact 400.

★ A COMMENT THAT DISAGREES WITH ITS CODE IS A BUG REPORT SOMEONE ALREADY WROTE. This one stated
the correct semantics and sat three lines above the line that broke them. **Reading the comment
next to the number was what found it** — 1589 against a stated 400 is the kind of impossibility
worth stopping for, and it was visible in every torque column printed this session.

Fixed; suite and lint clean. With everyone at 400 the PD degrades as predicted (mean error
0.106 → 0.186), which is the fix working.

## 🚧 AND THE PLANNER STILL LOSES, ACROSS THREE DIFFERENT PROBLEMS

    problem                         PD best    MPC      ratio
    catch a thrown ball             0.007      0.031    PD
    reach a target in 0.30 s        0.0995     0.786    PD by 8x
    track a moving target           0.186      1.501    PD by 8x

**The tracking setup was the one most likely to work** — preview is a difference in INFORMATION,
not tuning, and a servo's lag against a moving target is structural. It lost by the same margin
as the others.

★★★ THAT CONSISTENCY IS ITSELF THE FINDING. Three unrelated problems, three formulations each,
the planner losing by a similar factor every time, while its own unit tests pass — `optimize`
demonstrably drives a hand to a target in the end-to-end task test. **The common factor is not
the problem statements; it is how they are being driven.**

★ THE STRONGEST REMAINING SUSPECT, AND IT IS CHEAP: the reference is built by calling `Ik` once
per knot, 76 times per tick, at 6 iterations each, chained from the previous knot's solution. If
those solves do not converge the reference is garbage, and **a planner tracking a garbage
reference perfectly would look exactly like this.** Check `Ik.Result.reached` on the reference
knots before touching anything else.

★★ AND THE CONTROL EXPERIMENT THAT SETTLES IT: give the planner a reference it CANNOT get wrong —
a static target, or a joint-space sinusoid computed in closed form with no IK at all — and see
whether it tracks. If it tracks a clean reference and fails an IK-built one, the fault is the
reference. If it fails both, the fault is in the driving loop and every problem-specific
explanation offered so far has been noise.

# ═══ ✅✅✅ FOUND IT. THE PLANNER WINS BY 3x. THE DEFECT WAS IN THE HARNESS. ═══

    PD kp  2500    mean 0.68456 rad
    PD kp  9000    mean 0.43719 rad
    PD kp 20000    mean 0.28698 rad
    MPC preview    mean 0.09589 rad     ← 3x better than the best PD

## ★★★ `PoseHold` WRITES `applied_force`; THE PLANNER WRITES `ctrl`; `step` APPLIES BOTH

Nobody clears `applied_force`. So a planner run that FOLLOWS a servo run inherits the servo's
last torques and adds them to its own, every tick, for the whole run.

**Every comparison in this session ran the PD first.** Every planner number reported for hours
was contaminated — the planner was fighting a stale servo the entire time.

★ THE PROOF IS EXACT: the same planner, same weights, same reference, scored **0.096 rad run
first and 2.69 rad run after a PD.** And the solver's own cost tells the same story — **5554
contaminated against 7.5 clean.** It was not failing to optimise; it was optimising correctly
against a robot that had another controller's torques bolted on.

## ★★ HOW IT WAS FOUND, WHICH IS THE REUSABLE PART

Not by a tenth explanation. By the **control experiment**: strip away everything
problem-specific — no IK, no interception, no task translation — and give the planner a
closed-form joint sinusoid it cannot get wrong. Then the only remaining variables are the solver
and the harness.

★ AND THE DECIDING CLUE WAS A CONTRADICTION BETWEEN TWO OF MY OWN RUNS: 0.096 rad and 4.02 rad
at identical settings. **Two runs disagreeing at the same settings means one of them is
measuring something other than what its labels say** — that is not noise to average over, it is
the finding. Putting both controllers in a single process with a shared reset made the leak
inevitable to spot.

## ★ AND A SECOND REAL BUG, FOUND ON THE WAY

`PoseHold` clamped its tracking term and added gravity compensation OUTSIDE the clamp, so the
real ceiling was `max_torque + gravity` — **1589 N·m on an arm rated 400.** The comment three
lines above said the total should be clamped. Fixed; suite and lint clean. Every servo in every
comparison had been given up to 4x the torque its planner opponent was held to.

## What this means for the architecture

**The claim the RL-plus-MPC design rests on is now measured and true**: given a target trajectory
0.3 s ahead, the planner tracks it **3x more accurately than the best-tuned PD**, at the same
torque limit, on a long arm with a heavy end mass. Preview beats feedback, as the theory says it
should — the earlier failures were never about that.

**Next: rebuild the demo on this, and re-run the catch and reach comparisons with the leak
closed.** Both of those may look very different.

## ★★★ THE ABLATION, AND A FAIRNESS CHECK THAT HALVED THE CLAIM

    controller                RMS error
    PD kp   2500                0.685
    PD kp   9000                0.437
    PD kp  20000                0.287
    PD kp  45000                0.209
    PD kp  90000              **0.156**   ← the servo's true optimum
    PD kp 180000                0.168     ← past it; the trend reverses
    MPC, preview REMOVED        0.213
    MPC with preview          **0.096**

★★ **THE ADVANTAGE IS 1.63x, NOT 3x.** The first sweep stopped at kp 20000 where the trend was
still improving, and quoting that as "the best PD" would have doubled the apparent win.
**A sweep must run until it REVERSES**, or the number quoted is whatever the sweep happened to
stop at. Pushing to 180000 found the turn and cost one run.

★★★ **AND THE ABLATION ASSIGNS THE CREDIT.** Remove the preview — every knot referencing the
target at NOW, everything else identical — and the planner scores 0.213 and **LOSES to a
well-tuned PD**. So:

  * a planner that merely knows the DYNAMICS does not beat a servo here;
  * a planner that knows the FUTURE does;
  * **preview is the entire advantage**, and that is now a measured attribution rather than a
    story told about a number.

★ THE DEMO WAS UNFAIR AND IS FIXED: its gain slider capped at 40000, below the servo's optimum of
90000, so the opponent's best setting was unreachable. **A comparison whose slider cannot reach
the opponent's best setting is a strawman with a user interface.** Range now runs to 200000 and
the servo OPENS at its measured best.

## Verified

  * same torque limit for both (400 N·m), enforced for the servo by the `PoseHold` clamp fix and
    for the planner by `boxQP`;
  * same information at `t = now` — both IK to the target's current position;
  * `applied_force` cleared between controllers, so neither inherits the other's torques;
  * scoring window starts at 1.5 s, after the start transient, for both;
  * lint clean, tier-a green, doc-sync 0 drifted, smoke passes.

Full derivation and the bug story are in tutorial **§43**.

## ★★★ 1 FPS → 60, AND A TRAP AVOIDED BY RE-MEASURING

The first version ran at about **1 fps**. The arithmetic says why:

    per rendered frame at 60 fps: 4.2 sim steps
      per sim step, per arm: optimize 4.41 ms + reference IK 3.04 ms = 7.45 ms
      two arms:  62 ms per frame  ->  16 fps ceiling, measured at ~1

★ **THE IK WAS A THIRD OF IT, FOR A PATH THAT REPEATS.** `Ik` ran once per knot per tick — 76
solves per arm per sim step at 250 Hz. The target follows a FIXED CLOSED PATH, so its joint-space
reference is a periodic function of phase: **tabulate 512 poses once at startup and read them
forever.** Every runtime IK solve disappears, for both controllers, so neither pays for its
reference any more and the comparison measures control rather than inverse kinematics.

★ THE TABLE IS BUILT CHAINED AND IN TWO PASSES, so each solve starts beside its answer and the
last entry meets the first — a fresh solve per entry would not give a CONTINUOUS table on a
redundant arm, and a discontinuity in the reference is a step input the planner would faithfully
chase.

## ★★ AND THE TRAP: CUTTING COST DESTROYED THE RESULT

Dropping to 50 knots and 2 iterations made it fast and made the planner **lose**:

    50 knots, 2 iterations    0.315 rad   ← loses to the servo's 0.156
    75 knots, 2 iterations    0.248 rad   ← still loses
    75 knots, 3 iterations    0.162 rad   ← ties
    75 knots, 4 iterations    0.126 rad   ← wins by 1.24x
    75 knots, 6 iterations    0.096 rad   ← wins by 1.63x

**A demo tuned for frame rate that no longer shows its own result is worthless.** The cheap
configuration had to be RE-MEASURED rather than assumed to behave like the expensive one — and it
did not. The demo now runs at the measured floor, not at whatever was fast.

## ✅ THE CADENCE, NOW MEASURED (was labelled unverified)

    cadence 1 (250 Hz)   0.098 m
    cadence 2 (125 Hz)   0.117 m
    cadence 4  (63 Hz)   0.186 m   ← what shipped, nearly 2x worse
    cadence 8  (31 Hz)   0.331 m

★★★ **`feedbackControl` DOES NOT COVER THE GAPS FOR FREE.** It is much better than holding the
last control — cadence 4 still beats the servo — but the error roughly doubles from 250 Hz to
63 Hz and quadruples by 31 Hz. Worth knowing before designing a real system around a replan rate.

★★ AND THE BUDGET ALLOWED BETTER ALL ALONG. The cost was double-counted: **only ONE arm plans**,
the other is a servo, so a replan costs 6.6 ms per frame rather than 13.2. An arithmetic slip in
a back-of-envelope estimate had been paying for itself in accuracy for two turns. Cadence is now
2, and the demo should read near 0.117 rather than 0.186.

★ THE LESSON IS SMALL AND KEEPS RECURRING: **a budget estimate is a measurement too.** It was
never checked against anything, and it silently set a parameter that mattered.

## ✅ (previously) ONE THING UNVERIFIED

The probe replans every sim step; the demo replans every fourth with `feedbackControl` covering
the gaps. That is what `feedbackControl` exists for and what real MPC does — **but "supposed to"
is not a measurement.** The sweep to check it was written and its edit failed against a stale
binary, so it is recorded as untested.

★ THE ON-SCREEN MEAN IS THE CHECK: near **0.096** and the cadence is free; near the servo's
**0.156** and it is not. The number is on the panel precisely so this can be settled by looking.

## ★★★ 20 FPS → TARGET 60: THE COARSER TIMESTEP IS BOTH CHEAPER AND BETTER

    sim Hz  knots  iters   knot-iters/s   PD best    MPC
       250     75      6          56250    0.4771   0.2500
       125     40      6          15000    0.7709   0.2152
       125     40      4          10000    0.7709   0.2183   ← chosen
       125     30      4           7500    0.7709   0.2303
       100     30      4           6000    1.6479   0.2118

★★ **A KNOT IS ONE MODEL TIMESTEP**, so halving the sim rate halves the knots needed for the same
preview. 40 knots at 1/125 is **0.32 s** of lookahead; 75 at 1/250 was 0.30 s. Same foresight,
**2.8x less work per frame and 5.6x less per second of simulated time** — and the tracking got
BETTER, 0.250 to 0.218, because preview is what wins and the preview did not shrink.

★ THE ESTIMATE THAT CAUSED IT: **14.7 us per knot was measured NATIVELY**, and the demo runs in
wasm at two to three times that. A "6.6 ms" replan was really 15-20 ms on the phone. **A native
measurement is not a wasm budget**, and that unexamined conversion set the parameters for three
turns.

★ I STOPPED AT 125 Hz DELIBERATELY. 100 Hz is cheaper again and scores better, but the servo
collapses there (0.77 to 1.65) — a control rate low enough to cripple the opponent flatters the
planner, and the win should come from preview rather than from starving the comparison.

Also per Simon: **circle radius 0.32 → 0.46, speed 1.5 → 2.2** (tip about 1.0 m/s). Both widen
the servo's lag, since `e ≈ 2v/√kp` grows directly with speed.

## ★★ THE SERVO'S OPTIMUM MOVED WITH THE TASK, AND THE DEMO DID NOT FOLLOW

Changing the circle from r=0.32 at speed 1.5 to r=0.46 at 2.2 moved the PD's best gain:

    kp  20000: 1.5066
    kp  45000: 1.1047
    kp  90000: 0.8945   ← the demo's default, left over from the old task
    kp 180000: 0.7709   ← its actual best here
    kp 360000: 1.8890

★★★ **A DEFAULT TUNED FOR ONE SETTING IS NOT A DEFAULT.** Changing the task and leaving the
opponent's gain where it was handicaps it by accident — the same fairness failure as the slider
that could not reach 90000, arriving from a different direction. **Whenever the task changes, the
baseline's tuning has to be re-swept**, and that is cheap: one probe run.

Set to 180000.

## ★ AND THREE THINGS THE SCREENSHOT SHOWED THAT NO MEASUREMENT WOULD

  * **"What is the yellow cube?"** — the legend named the pink LINE and never said what the
    target looked like. A reader who has to ask what a shape means is a reader the demo failed.
  * **Both traces were the same green**, so the picture was a tangle with no way to tell whose
    path was whose. One colour per controller now: pink for the servo, green for the planner.
  * **The trail was three laps long** at the new speed — spaghetti that hid the very wobble it
    exists to show. Sized to roughly one lap.

★ NONE OF THESE ARE VISIBLE FROM A PROBE. A number can say the servo is 3.5x worse; only looking
at it says the picture is unreadable.
