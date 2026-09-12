# Making the quadruped's torso orientation precise

## The current design, and the gap it has

`examples/quadruped` commands torso attitude like this:

  1. sliders set roll / pitch / yaw / height;
  2. the wanted torso pose is written into `data.pos`;
  3. each leg is IK'd **independently** so its foot returns to its planted spot;
  4. only the **leg joint angles** become the target; `PoseHold` drives those.

The file states the design outright: *"the PD controller closes the loop on the real robot —
which is its job, not the planner's."*

★★★ **BUT NOTHING EVER LOOKS AT THE TORSO'S ACTUAL ORIENTATION.** Those joint angles would give
the commanded roll *if the joints tracked perfectly*. Under the trunk's weight they do not, and
the pipeline has no way to notice.

## ★★ MEASURED: EVERY COMMAND UNDERSHOOTS

    axis    commanded   achieved    error    fraction lost
    roll       0.3000     0.2605   0.0395      13%
    roll       0.1500     0.1066   0.0434      29%
    pitch      0.3000     0.2631   0.0369      12%
    pitch      0.1500     0.1195   0.0305      20%

★ **THE ABSOLUTE ERROR IS NEARLY CONSTANT (0.030–0.043 rad) WHILE THE FRACTION LOST DOUBLES AT
SMALL ANGLES.** That shape is diagnostic: a proportional loss would keep the percentage fixed. A
constant offset is PD droop — `kp·e = τ_gravity` settles at a fixed deflection whatever you
asked for. Roughly **2.3 degrees, always in the same direction, invisible to the controller.**

## ★ THE HONEST PART: MPC IS NOT THE ONLY FIX, AND SHOULD NOT PRETEND TO BE

**A few lines would remove most of this without any planner**: read `body_xrot[1]`, compare to
the commanded attitude, and feed the difference back into the commanded angles. That closes the
loop the pipeline is missing, and it is the fair thing to build first — **a demo that beats a
strawman proves nothing**, and "open-loop kinematics" is a strawman once you have named it.

So the comparison must be against the CORRECTED servo, not the shipped one.

## Where a planner should still win, and how it would be checked

  1. **The transient.** An integral correction is slow by construction and overshoots when
     pushed. A planner told the deadline arrives quickly AND settles — the same claim the
     tracking demo already proves for an arm, on a robot people find more interesting.
  2. **A MOVING command.** Oscillate the torso in roll and the servo's structural lag returns —
     `e ≈ 2v/√kp`, exactly as measured on the arm. **Preview is the advantage that survived
     every ablation**, so this is where to point it.
  3. **Torque limits.** The Go1's actuators are rated 35 N·m and the trunk is 5 kg; a servo
     tuned hard enough to beat the droop will saturate, and the planner's box will not let it
     try. Worth measuring whether the corrected servo can even reach the accuracy it needs.

## ★★★ ACCEPTANCE TEST, FIXED BEFORE THE CODE

Command a roll that **oscillates** at 0.5 Hz between ±0.25 rad, and report, for the whole cycle:

    mean |commanded − achieved| attitude error
    peak actuator torque (must stay under 35 N·m for both)

**Bar: the planner beats the CORRECTED closed-loop servo at its best gain, and the servo's gain
is swept until the trend reverses.** Both of those conditions were learned the hard way on the
arm: a baseline left untuned, and a sweep stopped early, each inflated the planner's apparent
win by nearly 2x.

★ AND `applied_force` MUST BE CLEARED BETWEEN CONTROLLERS. `PoseHold` writes it and the planner
does not; that leak made every planner number in this project wrong for a day.

## Why this is a good next example

It reuses machinery that is already measured — `Cost.task` for the attitude residual, the
control box, `setHorizon` — on a robot that reads as a character rather than a lab fixture. And
the interface is exactly the one the game architecture wants: **something upstream says "lean
like this", and the planner makes it true.**

# ═══ ★★★ THE HONEST ANSWER: SIX LINES OF FEEDBACK, NOT A PLANNER ═══

    feedback   axis    commanded   achieved     error   lost
    open       roll       0.3000     0.2526    0.0474    16%
    open       roll       0.1500     0.1015    0.0485    32%
    open       pitch      0.3000     0.2648    0.0352    12%
    open       pitch      0.1500     0.1207    0.0293    20%

    CLOSED     roll       0.3000     0.3032   -0.0032    -1%
    CLOSED     roll       0.1500     0.1549   -0.0049    -3%
    CLOSED     pitch      0.3000     0.2985    0.0015     1%
    CLOSED     pitch      0.1500     0.1504   -0.0004    -0%

**Read the torso's actual attitude, integrate the difference into a trim on the command,
re-solve the legs.** Six lines, no planner, and a 16-32% error becomes at most 3%.

★★★ **THAT IS THE ANSWER TO "CAN MPC MAKE THIS BETTER", AND IT IS NO.** Not for the steady-state
error, which is the whole gap the shipped demo has. Reaching for a planner here would have been
building a 400-line answer to a six-line problem, and beating a baseline that was only weak
because a loop was missing.

★ AND IT SHOULD BE MERGED INTO `examples/quadruped` REGARDLESS of what happens with MPC. The
demo's sliders currently lie: ask for 0.15 rad of roll and you get 0.10. That is a bug in a
shipped example, found by measuring a claim rather than reading the code.

## Where a planner could still earn its place — narrowed, and honestly

The steady-state case is closed. What remains:

  1. **A MOVING command.** The trim loop is an integrator: it converges to a CONSTANT target and
     lags a moving one, exactly like the PD on the arm. Oscillate the roll and the structural lag
     `e ≈ 2v/√kp` returns — and **preview is the advantage that survived every ablation.**
  2. **The transient.** The trim takes about 60 ticks to settle; a planner told the deadline
     arrives directly. Worth measuring, worth much less than (1).
  3. **Torque limits.** 35 N·m actuators; whether the trim loop saturates them chasing a fast
     command is a measurement, not an assumption.

★★ SO THE EXAMPLE TO BUILD, IF ANY, IS **"track a moving attitude command"**, not "hold a static
one" — the same shape as the arm demo, on a robot that reads as a character. And the baseline is
the CLOSED-LOOP servo at its best gain, swept until the trend reverses.

**Do not build it to win.** The static case just showed that the interesting question can have
"no" as its answer, and that answer was worth more than a demo would have been.

## ✅ MERGED INTO `examples/quadruped`

`trim_roll` / `trim_pitch`, integrated from the measured attitude error on a **12-frame cadence**
— slow on purpose, because `solveBodyPose`'s own comment records that re-solving every frame
destabilises the robot, and an integrator stacked on a PD that is still settling will fight the
transient it is measuring.

★ AND THE PANEL NOW SHOWS **ASKED VERSUS ACTUAL**, plus the live trim. That is the part that
should have existed from the start: the bug was not that the number was wrong, it was that
**nobody could see it was wrong.** A commanded value with no measured counterpart is a claim,
not a readout.

★ THE TRIM RESETS WITH THE STANCE. It is an integrator, and an integrator carried across a
teleport is the same class of stale state as a warm start nobody cleared — which cost this
project a day.

## ★ AND THE SMOKE TRAP IS PRE-EXISTING, CHECKED RATHER THAN ASSUMED

`examples/quadruped` traps in the debug smoke run with `integerOutOfBounds` inside
`addContactRows`. **Verified against the previous snapshot: the unmodified demo traps
identically**, so it is not from this change — it is the same engine fault already recorded for
`examples/humanoid`, where raising `max_contacts` changed nothing and a failed `@intCast` inside
the engine is the actual cause.

Worth the two-minute check every time: a result that happened to be right for the wrong reasons
is indistinguishable from one that is right, until you look.

# ═══ ✅ THE ROUTINE IS IN, AND IT CLOSES THE MPC QUESTION — AS "NO" ═══

Simon's design: **pitch and yaw in quadrature sweeping a cone, roll oscillating at its own
frequency.** The rates are incommensurate (0.55 and 0.31), so the attitude never exactly repeats
and nothing downstream can quietly memorise the pattern instead of tracking it.

## ★★★ THE MEASUREMENT THAT SAYS NOT TO BUILD THE MPC VERSION

    trim cadence   mean lag    worst lag
              12     0.0182       0.0588   ← what shipped
               4     0.0098       0.0377   ← now
               1     3.0294       3.3396   ← the robot falls over

**The trim loop tracks the moving routine to about one degree**, and half that at cadence 4. An
MPC example here would be competing for tenths of a degree on a task the simple thing already
does well — **which is not a demo, it is a rounding error with a title.**

★ THAT IS THE SECOND TIME THIS EXAMPLE HAS ANSWERED "NO", and both times the measurement took
minutes and would have taken hours to reach by building. The static case was six lines of
feedback; the moving case is a cadence constant.

★★ AND CADENCE 1 FALLING OVER IS `solveBodyPose`'S OWN WARNING, CONFIRMED. The file said
re-solving every frame "actively destabilises the robot"; the number is 3.03 rad. **A comment
that turns out to be exactly right is worth measuring too** — now the safe range has a floor
under it instead of a caution.

## What the quadruped demo now has

  * **attitude feedback**, so the sliders no longer lie (16–32% error → under 3%);
  * **asked-versus-actual on the panel**, which is what made the bug findable at all;
  * **the routine**, on a checkbox, with its own rate and size sliders;
  * **a lag readout**, so the routine is scored rather than merely admired.

★ THE LAG NUMBER IS THE POINT OF THE ROUTINE. Anything that only looks impressive proves
nothing; the mean lag is the quantity any future planner would have to beat, and it is now on
screen so the bar cannot quietly move.
