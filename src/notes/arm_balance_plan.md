# Using the arm to keep the robot up

## ★★★ THE AUTHORITY, MEASURED FIRST

    robot total mass            14.80 kg
    arm mass                     2.06 kg
    arm inertia about shoulder   0.3521 kg m^2
    shoulder motor              60 N.m

    CoM 0.02 m outside support -> tipping  2.90 N.m   arm authority  20.7x
    CoM 0.05 m outside support -> tipping  7.26 N.m   arm authority   8.3x
    CoM 0.10 m outside support -> tipping 14.52 N.m   arm authority   4.1x

**The arm can out-torque the fall by four to twenty times.** That is not marginal — it is a
genuinely powerful actuator that happens to be sitting on top doing decorative work.

★ AND THE REACTION TORQUE IS THE MOTOR TORQUE, EXACTLY. Newton's third law: the shoulder pushes
the arm one way and the trunk the other, with nothing lost in between. **No contact force is
involved**, which is the property that matters here.

---

# ★★ WHY THIS IS THE RIGHT MECHANISM FOR *THIS* ROBOT

During the attitude routine the friction cone runs at **1.83x** — the feet are saturated and
**cannot supply more corrective force**. A leg-based recovery has nothing left to push with.

**Arm momentum needs no contact force at all.** It works precisely in the regime where the legs
have run out, which is the regime this robot actually fails in. That is a stronger argument than
"the arm is available".

---

# THE TWO MECHANISMS, AND THEY ARE DIFFERENT PHYSICS

## 1. CoM shifting — quasi-static, persistent, bounded by REACH

Move mass, move where gravity acts. Measured: the arm swings the whole-body CoM **0.144 m**
fore-aft against a support base of about 0.36 m — **40% of the support polygon**.

  * **Persistent**: hold the arm out and the CoM stays moved, indefinitely.
  * **Slow**: the CoM only moves as fast as the arm does.
  * **Bounded by reach**: 0.144 m is all there is, ever.

## 2. Angular momentum — dynamic, transient, bounded by TRAVEL

`τ_on_trunk = -dL_arm/dt`. Accelerate the arm one way, the body rotates the other. This is the
flywheel from the humanoid work, and it is how a cat rights itself and why a slipping person
windmills their arms.

★★★ **AND IT IS BOUNDED BY TRAVEL, NOT BY TORQUE.** At 170 rad/s² the arm crosses its 2.4 rad
range in **0.168 s**, and then it is at its stop. Stopping it applies the OPPOSITE torque.

**That 0.168 s is the entire budget**, and it is the number that shapes the whole controller: it
is long enough to arrest a fall and far too short to hold a lean.

---

# ★★★ THE CONTROLLER THAT FALLS OUT OF THOSE TWO FACTS

The mechanisms are complementary in exactly the way their bounds suggest:

    1. DISTURBANCE ARRIVES     -> momentum: slam the arm, buy 0.168 s of large torque
    2. FALL ARRESTED           -> CoM shift: move the arm to where it holds the CoM over support
    3. STEADY AGAIN            -> unwind: return the arm to half-bent SLOWLY

★★ **STEP 3 IS THE ONE THAT IS EASY TO GET WRONG**, and it is the flywheel's classic failure. The
arm must come back, or the next disturbance finds it already at its stop with no budget left. But
returning it fast applies the reaction torque in reverse and re-creates the fall.

**Return it slowly enough that the reaction is below the tipping torque.** From the numbers above,
a return taking 1 s uses about a sixth of the available acceleration and produces roughly 10 N.m
— which is above the 2.9 N.m tipping torque at 2 cm, so even the unwind needs care. **Return over
2-3 s, or unwind only while the CoM error is small.**

## A concrete first control law

    // pitch_error: trunk pitch away from level. pitch_rate: its derivative.
    // Both already measured for the attitude trim.

    const wanted_reaction = kp * pitch_error + kd * pitch_rate;   // N.m the trunk needs
    const arm_accel = -wanted_reaction / arm_inertia;             // rad/s^2 to produce it
    // plus a weak spring pulling the arm home, active only when the error is small:
    const home_pull = if (@abs(pitch_error) < 0.02) k_home * (rest_angle - arm_angle) else 0;
    shoulder_command = clamp(arm_accel + home_pull, -alpha_max, alpha_max);

★ `kd` MATTERS MORE THAN `kp` HERE. Momentum control acts on RATE — it arrests a fall in
progress. Position feedback alone would wait for the lean to develop before responding, wasting
most of a 0.168 s budget.

---

# ★ WHAT TO MEASURE, AND THE ORDER

## 1. The oracle first: does it survive a push it otherwise fails?

Apply a known impulse to the trunk and sweep its magnitude. Report the largest push survived,
**arm-passive versus arm-active**. That is a single number, it cannot be argued with, and it is
the whole claim.

    bar: the active arm survives a push at least 2x the one that topples the passive robot.

★★ AND THE PASSIVE BASELINE MUST HAVE THE ARM PRESENT BUT HELD STILL — not the arm removed.
Removing it changes the mass and the CoM height, which are the very things under test. **A
baseline that differs in two ways cannot attribute the result to one of them.**

## 2. Then the gait

The demo tips backwards when walking. **If the arm can arrest a 15 N.s push it can arrest a
gait's tipping moment**, and the same controller should let the stride go back up to the 0.16 m
the bare robot walked well with.

## 3. Then the routine

Whether arm balance and the gimbal can share the arm at all is a real question: the gimbal wants
the gripper still, balance wants it swinging. **They conflict**, and the honest resolution is a
priority — balance wins when the pitch error exceeds a threshold, and the gimbal has the arm the
rest of the time. Worth building precisely because the conflict is visible on screen.

---

# ★ AND THE HALF-BENT REST POSE IS PART OF THE DESIGN, NOT A COSMETIC CHOICE

Simon asked for it and the arithmetic agrees: **an arm at a joint stop has zero momentum budget
in one direction.** Half bent leaves 2.4 rad of travel each way, which is what makes the 0.168 s
window symmetric. A folded or extended arm can only catch a fall one way.

# ═══ ★★★ MEASURED WITH THE ARM: THE GAIT HAS NO WORKING SETTING ═══

The gait probe now splices the arm, so it tests the robot that ships. Corrected stance direction
throughout, 10 s each:

    hz    stride  duty    travelled x   trunk z   verdict
    1.4    0.10   0.65      -0.35 m      0.295    stands, barely moves
    1.4    0.16   0.65      -3.28 m      0.140    **FELL**
    2.0    0.16   0.60      -0.53 m      0.130    **FELL**
    2.4    0.20   0.55      -0.82 m      0.223    stands, backward

**With the arm, nothing walks forward.** The bare robot managed +1.43 m at 2.0/0.16/0.60; the same
settings with 2 kg on top put it on the floor. ★ THAT IS SIMON'S TIPPING, REPRODUCED AND ISOLATED
TO THE ARM — not to the stance direction, which is correct, and not to tuning, which has no good
value here.

## ★★ AND IT SHARPENS THE CASE FOR THE BALANCE CONTROLLER

This is no longer "the arm could help". It is **the arm broke the gait and the arm is the only
thing with enough authority to fix it** — 60 N·m of reaction against a 2.9-14.5 N·m tipping
torque, needing no contact force.

★ THE COMPARISON IS ALSO NOW PROPERLY SHAPED. The passive baseline is this table: same robot,
same mass, same CoM height, arm held still. **Nothing differs but the control**, which is exactly
the condition an honest before/after needs and the one that "remove the arm" would have violated.

## 🚧 THE CONTROLLER ITSELF DID NOT LAND

The momentum law was written — trunk pitch and rate driving the shoulder, `kd` dominant, with a
slow pull home gated on being nearly level — and its edit failed its assertion against a file the
previous edit had already changed. **The numbers above are the arm-passive baseline only.**

★★ RECORDED AS UNTESTED RATHER THAN ASSUMED. The law is in this file's section above; the next
session should write it into a FRESH probe rather than patching the gait one again, which has now
resisted two edits in a row — the same lesson `claude.md` already carries about rewriting a probe
when it needs its fifth edit.

## The order from here

  1. **Fresh probe, momentum law, one question**: does arm-active stand where arm-passive falls,
     at 2.0/0.16/0.60? That is the single cell where the bare robot is known to walk well.
  2. **Then sweep `kp`/`kd`** against distance travelled, not against staying up — staying up is
     the floor, walking is the goal.
  3. **Then the demo**, with the arm's balance on a checkbox so the difference is watchable.

# ═══ ★★★ THE FRESH PROBE CONTRADICTS THE PATCHED ONE ═══

Written from scratch (the gait probe had resisted two edits), trot 10 s, arm always present:

      kp    kd    hz  stride  duty    moved     z    arm swing  worst pitch
       0     0   2.0   0.16   0.60    0.567   0.298     0.000       0.053  FORWARD
       0     0   1.6   0.08   0.75   -0.931   0.296     0.000       0.029  backward
       2     6   2.0   0.16   0.60    0.488   0.298     0.715       0.068  FORWARD
       4    12   2.0   0.16   0.60   -0.465   0.129     4.600       0.435  **FELL**
       8    24   2.0   0.16   0.60   -0.418   0.126     4.600       0.609  **FELL**
       4    12   1.6   0.12   0.70   -0.383   0.297     0.713       0.035  backward
       8    24   1.6   0.12   0.70   -0.359   0.297     1.277       0.031  backward

## ★★★ TWO CONCLUSIONS FROM LAST TURN WERE WRONG

**1. `2.0/0.16/0.60` WALKS FORWARD WITH THE ARM** — +0.567 m, standing at z 0.298. Last turn's
patched probe reported it falling at z 0.13. The patched run's edit had failed its assertion, so
that output came from a **stale binary**, and I read it as data.

**2. `1.6/0.08/0.75` — WHAT I BACKED THE DEMO OFF TO — WALKS BACKWARD**, -0.931 m. I had the two
settings exactly the wrong way round.

★ THE LESSON IS ONE THIS PROJECT ALREADY CARRIES AND I BROKE ANYWAY: **when an edit fails its
assertion, the binary is stale and its output is the PREVIOUS build's.** It has now cost real
conclusions twice.

## ★★ AND THE BALANCE CONTROLLER MAKES THINGS WORSE, NOT BETTER

  * **kp 2 / kd 6**: 0.488 m against the passive 0.567 — slightly worse, arm swinging 0.715 rad.
  * **kp 4+**: **falls**, with the arm swinging **4.600 rad — its entire range.**

★ THE ARM SWING COLUMN IS WHAT DIAGNOSES IT. At 4.600 the arm is slamming stop to stop: the
controller is saturated, so it spends the whole 0.168 s budget instantly and then holds against
its limit, which converts a momentum actuator into dead weight in the worst possible place.
**Saturation is not "too much gain" to be trimmed — it is the controller operating outside the
mechanism it was designed around.**

★★ AND THE PASSIVE ROW IS THE HONEST BASELINE: the robot walks fine at 2.0/0.16/0.60 **with the
arm just held still.** Nothing needed rescuing at this operating point, so the controller had
only downside to contribute.

## 🚧 WHAT STILL DOES NOT ADD UP — AND IT MATTERS

Simon observes the DEMO tipping backwards. This probe says the gait alone, with the arm, is fine
at those settings. **The difference is that the demo runs the gait alongside the attitude trim,
the gimbal and the routine — three other controllers, all writing `s.home`.**

★★★ THAT IS THE SAME CLASS OF BUG AS THE ARM'S COUNTER-ANIMATION BEING OVERWRITTEN: multiple
solves writing one array, where order and precedence decide the outcome. **The next measurement
is the demo with the routine and gimbal OFF**, gait only — if it walks forward there, the
interaction is the fault and not the gait.

## The order from here

  1. **Set the demo to 2.0/0.16/0.60** — measured forward, twice now, at two different lifts.
  2. **Test gait-only versus gait-plus-everything** in the demo. One checkbox each, already
     present.
  3. **Leave the arm balance off.** It is measured to hurt at this operating point, and the place
     it should help — where the passive robot actually falls — has not been found yet. **A
     controller with no demonstrated failure to fix is not ready to ship.**

# ═══ ★★★ THE PITCH TRACE SHOWS WHY — AND IT IS NOT THE SIGN ═══

Per-second trunk pitch, which turns "it fell" into a shape:

    kp 0  kd 0    -0.023 -0.011 -0.012 -0.011 -0.012 ...    steady, tiny, walks FORWARD
    kp 4  kd 12   -0.039 -0.339 -0.271 -0.258 -0.379 ...    fell 5.50 s
    kp 4  kd 12   (sign flipped)  0.018 0.008 ... 0.018     fell **0.88 s**

★ FLIPPING THE SIGN MADE IT FALL SIX TIMES SOONER, so the reaction direction is not the fault —
and a sweep of gains only ever chose how fast it fell, which is the signature of something other
than tuning.

## ★★★ THE ARM SWING COLUMN IS THE DIAGNOSIS: **4.600 IN EVERY ACTIVE ROW, BOTH SIGNS**

4.600 rad is the arm's entire clamped range. The law was written as an INTEGRATOR:

    home[shoulder] += dt * (kp * pitch + kd * rate)

**An integrator on a persistently non-zero error winds to its limit whatever its sign.** The
passive robot sits at a steady -0.012 rad of pitch all run — small, harmless, and never zero — so
the integrator accumulates it forever and parks the arm against its stop. There it is not a
momentum actuator at all; it is 2 kg of dead weight held at maximum lever arm.

★★ THE LAW SHOULD BE PROPORTIONAL, NOT INTEGRAL:

    home[shoulder] = rest + k_p * pitch + k_d * rate

**Bounded by construction** — a bounded input gives a bounded arm angle, and the arm returns to
`rest` by itself whenever the robot is level. No anti-windup, no gating, no pull-home term: those
were all patches for a wind-up that a proportional law does not have.

★ AND THAT ALSO EXPLAINS WHY THE "PULL HOME" GATE DID NOTHING. It only acted when pitch < 0.03
AND rate < 0.3 — conditions the integrator's own excursion prevented from ever holding.

## What was learned that keeps

  1. **The passive robot at 2.0/0.16/0.60 is fine**: pitch steady at -0.011, walks +0.567 m. It
     needed no rescuing, which is why every active variant could only make it worse.
  2. **A per-second trace is worth far more than a worst-case scalar.** "Worst pitch 0.435" says
     nothing; `-0.039 -0.339 -0.271` says the controller did it, within one second, and pointed
     straight at the mechanism.
  3. **`arm swing` as a reported quantity is what identified saturation.** Without it, both sign
     conventions look like ordinary instability and the natural next move is another gain sweep —
     which would have failed identically for a third time.

## Next

Rewrite the law as proportional and re-run the same table. **The diagnosis is specific enough
that this is a small, well-posed change**, and the trace is already in place to judge it.

# ═══ ★★★ IT WORKS: FEEDFORWARD, PHASE-LOCKED TO THE GAIT ═══

    amp  phase    moved     z    swing   pitch trace
    0.0  0.00     0.567   0.298  0.000   -0.023 -0.011 -0.012 -0.011 -0.012 ...  baseline
    0.3  0.00    -0.886   0.309  0.600   backward
    0.3  0.25    -0.457   0.300  0.600   drifts to -0.59
    0.3  0.50    -1.894   0.133  0.600   **FELL** at 4.36 s
    0.3  0.75   **0.843** 0.301  0.600   -0.023 0.013 -0.002 -0.001 -0.000 0.000
    0.6  0.75     0.217   0.126  1.200   FELL
    1.0  0.75    -1.041   0.138  2.000   FELL

★★★ **amp 0.3 / phase 0.75 WALKS 1.49x FURTHER THAN PASSIVE AND FLATTENS THE PITCH BIAS TO ZERO**
— 0.843 m against 0.567, with the trace going from a steady -0.012 to 0.000. The same amplitude a
quarter-cycle away falls over at 4.36 s.

## ★★ WHY THIS WORKS WHERE EVERY FEEDBACK LAW FAILED

**The passive robot did not need rescuing.** It walks with a small steady pitch, so a reactive
controller has nothing to react to and can only inject noise — and an integrator on a never-zero
error additionally winds to its stop. Three feedback variants, three failures, all explained by
that one fact.

★ **BUT THE DISTURBANCE IS PERIODIC AND KNOWN.** A trot's pitch wobble comes from the diagonal
pairs alternating at exactly `hz`, with a fixed phase relationship to the gait clock. It can be
cancelled OPEN-LOOP, and cancelling it is worth 50% more distance.

★★ THIS IS `examples/tracking`'S RESULT IN A DIFFERENT COSTUME: **when the disturbance is known
in advance, feedforward beats feedback.** There it was preview against a servo's lag; here it is
a phase-locked swing against a gait's own wobble. The measured advantage in both cases comes from
information, not from gain.

★ AND IT CANNOT WIND UP. A bounded sinusoid gives a bounded arm angle, with no gate, no
anti-windup and no pull-home — the three patches the integrator needed and that never worked
because they were treating a symptom of the wrong law.

## ★ PHASE IS THE PARAMETER, NOT AMPLITUDE

Same 0.3 amplitude spans **falling at 4.36 s** to **the best result measured**, purely on WHEN in
the step the swing happens. And amplitude past 0.3 fails at every phase — 0.6 and 1.0 both fall —
so the useful range is narrow and the sweep had to cover phase densely to find it.

★★ WORTH SAYING PLAINLY: a sweep over amplitude alone would have concluded "the arm does not
help", at every amplitude, and been wrong.

## Next

  1. Refine around **amp 0.3, phase 0.75** — the sweep was coarse (quarter-cycle steps).
  2. Put it in the demo behind the gait, with amplitude and phase on sliders.
  3. **And this is the shape an RL policy would learn**: a phase-locked, bounded, feedforward
     pattern keyed to the gait clock. Finding it by hand first means the learned version has a
     baseline to beat and a structure to be checked against.

## ✅ SHIPPED INTO `examples/quadruped`

The counter-swing is written into the shoulder inside `solveGait`, right after the leg IK, so it
rides the same `s.home` the legs do and needs no loop of its own. **The gait phase is the only
input** — no measurement, no feedback, nothing that can wind up.

    arm swing  0.30   (slider 0 to 0.8)
    arm phase  0.75   (slider 0 to 1.0)

★ BOTH ARE SLIDERS BECAUSE PHASE IS WORTH FEELING. Dragging it a quarter turn takes the robot
from walking 1.49x further than a still arm to falling over at 4.36 s — that is a control
demonstrating its own sensitivity, which no printed number does as well.

★★ AND IT SITS NEXT TO `stride` AND `duty`, where it belongs: it is a gait parameter, not a
balance controller. **That framing is the finding.** The three attempts that failed were all
framed as balance controllers reacting to a fall, and the passive robot was never falling.

# ═══ ★★★ FOOT LIFT WAS THE MISSING PARAMETER — AND THE DEMO WAS RUNNING THE WRONG VALUES ═══

## 🐛 FIRST, A SHADOWED ASSIGNMENT

    553:  s.gait_hz = 2.0;
    554:  s.gait_stride = 0.16;    <- the measured value
    555:  s.gait_lift = 0.05;
    556:  s.gait_stride = 0.06;    <- overwrote it two lines later
    557:  s.gait_lift = 0.03;

An earlier edit inserted the new values ABOVE the originals instead of replacing them, so the
last write won. **The demo has been running stride 0.06 all along** — which is exactly what
Simon's screenshot showed, and why it crept backwards while the probe walked forward.

★ THE SCREENSHOT IS WHAT CAUGHT IT. The panel displayed 0.060 and 0.030 against source that says
0.16 and 0.05. **A visible parameter readout turns a silent shadowing bug into a two-second
observation**, which is the second time in this project the on-screen value has caught something
the code review did not.

## ★★ AND THE SWEEP

    amp  phase  lift    moved     z
    0.3  0.75   0.03    0.379   0.301   FORWARD
    0.3  0.75   0.05    0.843   0.301   FORWARD
    0.3  0.75   0.08  **0.957** 0.300   FORWARD
    0.3  0.75   0.12    0.193   0.141   FELL
    0.0  0.00   0.08   -0.351   0.129   **FELL**   <- no arm swing
    0.3  0.75   0.20 stride     0.125   FELL
    0.3  0.70   0.08    0.070   0.125   FELL
    0.3  0.80   0.08    0.655   0.301   FORWARD

**Lift 0.03 to 0.08 nearly triples the distance.** A swinging foot either clears or catches, and a
catch on a top-heavy robot is a trip.

★★★ **AND AT LIFT 0.08 THE ARM SWING BECOMES NECESSARY.** Passive, the robot falls at 6.22 s; with
the swing it walks 0.957 m. Every earlier attempt failed partly because the passive robot did not
need help — **raising the lift created the regime where it does**, and the arm now fixes a
demonstrated failure rather than merely not hurting one.

★ PHASE REMAINS THE KNIFE EDGE: 0.70 falls, 0.75 is best, 0.80 works but is 30% worse. And stride
0.20 falls at every phase, so 0.16 is the ceiling.

## Shipped

    hz 2.0   stride 0.16   duty 0.60   lift 0.08   arm swing 0.3 @ phase 0.75

## ✅ TWO MODE-HYGIENE FIXES SIMON SPOTTED

**1. "reset everything" now includes the arm.** The padded keyframe carries the half-bent pose,
but the GIMBAL re-solved the arm on the very next frame if left on — so the arm snapped straight
back to wherever it had been holding. The reset now clears the mode as well as the angles, plus
`hold_point`, the trim integrators, the routine clock and the slip counters.

★ `hold_point` IS A CAPTURED WORLD POSITION, and surviving a reset made the arm reach for a place
relative to feet that had moved — **the same stale-anchor problem that made the gimbal drift,
arriving through the reset path instead.** Anything captured from the world has to be cleared
when the world is.

**2. Turning on `walk` establishes the arm pose.** The counter-swing was measured around a
half-bent arm; started from wherever the gimbal left it, the swing is offset and **the phase
measured to work is not the phase the robot gets** — which is a silent 30%-to-falling difference
given how sharp the phase optimum is.

★★ **A MODE THAT DEPENDS ON A POSE SHOULD ESTABLISH THAT POSE** rather than inherit whatever the
last mode left. And walk now turns the gimbal off, because the two want the arm for opposite
reasons: one holds the gripper still, the other swings it. They cannot both have it, and saying
so explicitly beats letting the later writer win by accident.

## 🐛 THE ARM STAYED VERTICAL: NAME MATCHED AGAINST THE WRONG INDEX

    for (0..m.njnt) |j| {
        if (std.mem.eql(u8, s.robot.joints[j].name, "arm_shoulder")) { ... }
    }

★★★ **`s.robot.joints` IS MJCF PARSE ORDER; `j` IS THE IMPORTER'S MODEL ORDER.** Indexing one by
the other compares unrelated joints, so the match never fired where it should and could fire
where it should not. The arm stayed at its keyframe pose — vertical — and the counter-swing was
written into whatever joint happened to sit at that index.

★★ AND IT FAILED SILENTLY IN BOTH DIRECTIONS. `setArmRest` did nothing; the swing wrote
somewhere. **Neither produced an error**, which is why it survived a build, a lint pass and a
full gate run.

## The fix: identify by ACTUATION MASK, never by name-versus-index

`limbActuation` from the gripper already marks exactly the arm's DOFs, and it is what the
gimbal's IK uses — so it is verified by a feature that visibly works. Walking joints in model
order and taking the powered ones yields the chain root-to-tip: yaw, shoulder, elbow, wrist.

    armShoulderQ(s)  // the second powered joint in the arm's chain

★ RETURNED RATHER THAN CACHED, so it cannot go stale if the model is rebuilt — and both the rest
pose and the swing now come from the same source of truth.

★★ THE GENERAL RULE: **`Imported` has `bodyIndex` but no joint equivalent**, and that absence is
what pushed the first attempt toward name matching. When a lookup does not exist, the answer is
an existing verified mask — not a hand-rolled index correspondence that happens to compile.

# ═══ ★★★ COMPLIANCE MAKES IT WORSE — THE TUNED-MASS-DAMPER IDEA IS WRONG HERE ═══

The arm's stiffness and damping swept independently of the legs', 10 s each:

    arm kp   arm kv    moved     pitch behaviour
       100        6   **0.957**  flat, essentially zero        <- as shipped
       100       20     -0.396   drifts to -0.48
        40        8     -0.157   drifts to -0.40
        20        6     -0.257   drifts to -0.50
        10        4     -0.196   drifts to -0.49
       300       12     FELL at 8.03 s
     20, no commanded swing      -0.272
     10, no commanded swing      -0.281

**Every softer setting is worse, and every stiffer one too.** The shipped gains are the best
measured by a wide margin.

## ★★ THE HYPOTHESIS WAS REASONABLE AND WRONG, AND THE REASON MATTERS

The arithmetic looked compelling: at `kp 100` the arm's natural frequency is
`sqrt(100/0.352) = 16.9 rad/s = 2.7 Hz` against a 2.0 Hz gait — near resonance with the exact
disturbance it should absorb. A tuned mass damper wants to be **detuned and damped**.

★★★ **BUT THE ARM IS NOT ABSORBING. IT IS EXECUTING.** The counter-swing is a commanded
trajectory, and a compliant joint does not follow a command — it lags and softens it. Making the
arm compliant does not turn it into a damper; it turns off the feedforward that was doing the
work. **The "no commanded swing" rows confirm it**: soft AND passive is -0.27, no better than
soft and commanded.

★ SO THE MECHANISM DECIDES THE GAINS, NOT THE FREQUENCY MATCH. A passive absorber wants softness;
an actuator delivering a planned motion wants stiffness. **Reasoning from the resonance without
first asking which of the two this is** produced a confident prediction in the wrong direction.

## 🚧 AND SIMON'S OSCILLATION IS THEREFORE NOT EXPLAINED

The probe at the shipped gains shows a **flat** pitch trace — `-0.026 0.019 0.007 -0.003 0.001
-0.000 ...` — with no oscillation at all, and walks 0.957 m forward.

★ SO WHAT IS SEEN IN THE DEMO COMES FROM SOMEWHERE THE PROBE DOES NOT HAVE. The demo runs the
gait alongside the attitude trim, and both write `s.home`; the trim re-solves every 4 frames on
measured attitude, which is a feedback loop the probe has no equivalent of. **That is the next
thing to test: walk with the torso posing off entirely**, which the demo already exposes as a
checkbox.

★★ AND IT IS THE SAME SUSPECT AS THREE TURNS AGO, still untested: multiple controllers writing
one array. It has already produced two bugs in this file.

# ═══ ★★★ FOUND IT: THE ATTITUDE TRIM FIGHTS THE GAIT ═══

The probe was given the one thing the demo has and it lacked — `solveBodyPose`'s attitude trim,
integrating measured pitch and folding it into the commanded attitude on a 4-frame cadence:

    swing  trim     moved     z    pitch, first second
     0.3   off    **0.957**  0.300      -0.026        FORWARD
     0.3   ON       0.123    0.139      **+0.229**    **FELL at 1.80 s**
     0.0   ON      -1.195    0.141      +0.224        FELL at 3.15 s

**With the trim on it falls at 1.80 s where without it the robot walks 0.957 m.** That is Simon's
oscillation and fall, reproduced and isolated — and it is the entire difference between a probe
that walked forward for many turns and a demo that toppled.

## ★★ WHY: AN INTEGRATOR NEEDS A REACHABLE, STEADY SETPOINT

The trim is right on a STANDING robot — it took the attitude sliders from 16-32% short to under
3%. **A trot pitches by design, every step**, and the integrator treats that periodic motion as an
error to remove. It winds against the gait, and the pitch goes to +0.229 within a second.

★ LEVEL IS BOTH REACHABLE AND STEADY WHILE STANDING; IT IS NEITHER WHILE WALKING. Same
controller, same gains, correct in one mode and destructive in the other — which is why no gain
value would have fixed it and why it survived so long.

## ★ THE FOURTH BUG IN THIS FILE FROM TWO CONTROLLERS WRITING ONE ARRAY

  1. the arm's counter-animation overwritten by `solveBodyPose` (order);
  2. `s.gait_stride` overwritten two lines after being set (duplicate assignment);
  3. the arm found by name against the wrong index (silent no-op);
  4. **this** — the trim and the gait both writing `s.home`, each correct alone.

★★ THE PATTERN IS NOT CARELESSNESS, IT IS STRUCTURE: `s.home` is a shared mutable target with
four writers and no ownership rule. **The demo needs one**, and the cheap version is what has
been applied piecemeal — each mode disabling the others it conflicts with, stated explicitly at
the point of conflict.

## Applied

`gait_on` now disables the trim and zeroes its accumulators, exactly as `walk` already disables
the gimbal. Three modes, three explicit exclusions, all measured rather than assumed.

# ═══ ★★★ THE ESCAPE: A CRAWL, NOT A TROT ═══

    gait     hz  stride  duty  swing    moved     z    pitch trace
    trot    2.0   0.16   0.60   0.3     0.957   0.300   flat but fragile
    crawl   1.0   0.14   0.80   0.0     0.194   0.303   0.012 0.011 0.010 0.010 ...
    crawl   1.4   0.14   0.80   0.0     0.207   0.302   0.001 -0.011 -0.014 ...
    crawl   1.0   0.14   0.85   0.0     0.201   0.303   0.008 0.011 0.011 ...
    crawl   1.0   0.14   0.80   0.3     0.127   0.298   (the swing makes it WORSE)

**Every crawl configuration stands.** Quarter-spread phases at duty 0.80 leave **three feet down
at all times**, so the centre of mass only has to stay inside a triangle that always exists —
statically stable by construction, which is the right property for a robot with 2 kg high on its
back.

★★ AND IT NEEDS NO ARM SWING. Adding one makes it worse: the swing exists to cancel a TROT's
wobble, and a crawl does not have one. **Every arm experiment in this file was solving a problem
created by choosing the wrong gait.**

## 🐛 THE DEMO ALREADY OFFERED THIS GAIT, LABELLED "(falls)"

    if (u.button("walk 4-beat (falls)", .{})) {
        s.gait_offset = .{ 0.0, 0.25, 0.5, 0.75 };
    }

★★★ **THE BUTTON CHANGED THE PHASING AND NOT THE TIMINGS.** Measured at the trot's hz 2.0 and
duty 0.60, four spread phases genuinely do fall — a foot is always mid-swing and the Go1 cannot
carry that on three legs at that stride. **At its own settings it is the most robust gait here**,
and it had been sitting behind a discouraging label for the whole session.

★ A GAIT PATTERN IS NOT A PARAMETER ON ITS OWN. Changing offsets without changing rate and duty
measures the new pattern at the old one's settings. Every pattern button now sets its own
timings, which is the fix and also what the "(falls)" label was really reporting.

## Shipped

**Crawl is now the default** — `{0, 0.5, 0.25, 0.75}`, hz 1.4, stride 0.14, duty 0.80, lift 0.06,
no arm swing. The trot is one button away, 4.6x faster and fragile, with its own settings
attached.

# ═══ ★★★ MAKING THE CRAWL ADVANCE: STRIDE, NOT RATE ═══

    hz   stride  duty    moved     z
    1.4   0.14   0.80    0.207   0.302   <- was shipping
    1.4   0.20   0.80  **0.655** 0.307   <- now
    1.4   0.26   0.80   -0.103   0.126   FELL at 2.96 s
    2.0   0.20   0.80    0.134   0.305   stands, but a third of the distance
    2.5   0.20   0.80   -0.751   0.128   FELL at 1.87 s
    2.0   0.26   0.75   -0.619   0.128   FELL
    3.0   0.26   0.75   -0.236   0.126   FELL

**Stride 0.20 travels 3.2x further than 0.14 and still stands solidly** — pitch flat, trunk at
0.307. And the shape of the surface is sharp on both sides: 0.26 falls, and every rate above 1.4
either loses distance or topples.

## ★★ WHY RATE HURTS WHERE STRIDE HELPS

A crawl's whole margin is the time each foot has to settle before the next one lifts. **Raising
`hz` spends exactly that margin** — 2.0 costs two thirds of the distance, 2.5 falls at 1.87 s.
Raising the stride does not: the foot has the same time, it simply covers more ground in it.

★ **LONGER STEPS, NOT FASTER ONES**, and that is a property of the gait rather than of this robot
— it is why real quadrupeds lengthen their stride before they raise their cadence.

## ★ AND THE EFFICIENCY FRAMING IS WHAT MADE THIS FINDABLE

A crawl advances one stride per cycle, so `stride x hz x 10 s` is what perfect grip would give.
The shipped setting reached **10%** of it — which says the problem was never "the gait is too
slow to see" but "nine tenths of every step is being lost." **Distance alone cannot separate
those, and they want opposite fixes.** At 0.20 the same measure reaches 23%.

★★ THE REMAINING 77% IS STILL FOOT SLIP, which the friction-cone and creep work already
characterised: the contact solver lets a loaded foot drift inside its own friction limit. **The
gait is now limited by the same engine behaviour the slope demo was built to expose**, which is a
satisfying place to arrive from the opposite direction.

# ═══ ★★★ THE SHOW: WALKING AND POSING AT ONCE ═══

Crawl at the measured 1.4 / 0.20 / 0.80, with the torso on its own clocks and the arm sweeping:

    roll pitch   bob  armlift    moved     z
    0.00  0.00  0.000    0.0     0.655   0.307   the crawl alone
    0.06  0.06  0.015    0.3     0.650   0.301
    0.10  0.10  0.025    0.5     0.628   0.297
    0.14  0.14  0.035    0.7   **0.470   0.293**   <- the edge, and what ships
    0.18  0.18  0.045    0.9    -0.983   0.126   **FELL at 6.42 s**
    0.14  0.14  0.035    0.0     0.516   0.293   (arm still)
    0.00  0.00  0.000    0.9   **0.696** 0.307   (arm alone — costs NOTHING)

**8 degrees of roll and pitch, 3.5 cm of bob, a big slow arm sweep, and it still walks 0.47 m.**

★★ THE ARM IS FREE AND THE TORSO IS NOT. Sweeping the arm alone travels 0.696 m — slightly MORE
than the bare crawl — while the torso amplitudes spend the margin. That is worth knowing for the
next round of "make it more impressive": **the arm is where the spare authority is.**

## ★ WHAT HAD TO CHANGE TO COMBINE THEM AT ALL

`solveGait` planted the torso at `rest_rot` exactly, so **the roll and pitch sliders did nothing
while walking.** The routine and the locomotion were mutually invisible, and folding the command
into the gait's torso pose is what lets them run together.

★★★ AND IT IS FEEDFORWARD, WHICH IS THE WHOLE REASON IT WORKS. The attitude is COMMANDED and the
legs solve for it; nothing measures the result and corrects it. **The trim did measure and
correct, and toppled the robot in under two seconds** — a walking robot's pitch is not an error.

## ★ FIVE INCOMMENSURATE RATES, AND THE GAIT'S IS NOT ONE OF THEM

    gait 1.4   pitch 0.31   roll 0.23   bob 0.17   arm 0.11

A torso motion locked to the footfall reads as a limp. One that drifts against it reads as
dancing — and with no common multiple the whole pose never repeats.

# ═══ ✅ REVIEW AND SIMPLIFY: THE DUPLICATION WAS THE INCONSISTENCY ═══

## ★★★ TWO SOLVERS, ONE SHAPE

`solveGait` and `solveBodyPose` were written independently and had converged on exactly the same
six steps: save `data.pos`, seed a pose, plant the torso, IK four legs, harvest hinges into
`home`, restore. **They differed only in the seed and the foot goals.**

Extracted to `solveLegsInto(s, seed, attitude, height, goals)` plus `harvestPose(s)`. Both
solvers are now a handful of lines and **the difference between walking and posing is visible at
a glance**:

  * gait: seed `home`, goals = foot rest + cycle offset, **body-relative**;
  * posing: seed `stance`, goals = `planted`, **world-fixed**.

★ AND THE SPLIT BETWEEN SOLVE AND HARVEST IS LOAD-BEARING, not cosmetic: the gait writes the arm
BETWEEN them. That ordering is the bug that once made the arm's motion silently disappear, and
having two named functions makes the correct place to write obvious.

★★ TWO INVARIANTS NOW LIVE IN ONE PLACE INSTEAD OF TWO. `data.pos` is scratch and must be
restored — a solve that leaks teleports the robot. And the seed must be a COMMAND, never the
measured robot, or the IK closes a feedback loop and the pose walks away from itself. **Both were
duplicated, which is how one copy drifts.**

## ★★ THE ARM'S JOINT LOOKUP, DUPLICATED THREE WAYS

`setArmRest` walked the powered joints to set four angles; `armShoulderQ` walked them again to
find one index; and `1.1` appeared as a literal in three places including a spliced XML string.

Now `armJointQ(s, n)` is the single walk, `arm_rest` is the single array, and
`arm_rest_shoulder` names the value the gait and routine sweep around.

★ THE KEYFRAME STRING STILL REPEATS THOSE NUMBERS and now says so explicitly — it is text
spliced into XML, so the compiler cannot check it. **A comment is the only available guard**, and
noting that is better than pretending the duplication is gone.

## Result

    1969 -> 1913 lines, with two solvers reduced to their actual difference

Lint clean, tier-a green, both standalones built, 73/73 imports.

## 🐛 THE REFACTOR BROKE THE GAIT, AND THE BUG IS THE POINT OF THE REFACTOR

`solveGait` seeded **only the hinges** from `home`, deliberately leaving the root's live x/y
alone. `solveBodyPose` did a **full copy** from `stance`. Extracting the shared shape, I wrote one
`@memcpy(seed)` and flattened that difference.

★★★ **THE GAIT THEN COMPUTED ITS FOOT GOALS FROM THE LIVE TORSO POSITION AND SOLVED THE LEGS
AGAINST A STALE ONE.** The body is travelling; `home`'s root x/y is wherever the command was last
written. The legs solve for a body that is not where the goals assume it is — which looks exactly
like "dances in place for a second and then falls".

★★ AND IT IS PRECISELY THE FAILURE MODE THE REFACTOR WAS MEANT TO PREVENT. The stated reason for
extracting was that duplicated invariants drift. **Merging two functions that differ in a subtle
way loses the difference just as surely** — the risk moves from "one copy drifts" to "the
distinction is silently erased", and the second is harder to spot because the code looks cleaner.

★ THE FIX MAKES THE DIFFERENCE AN ARGUMENT rather than a convention: `solveLegsInto` now takes
the ground position explicitly. The gait passes the LIVE torso position; posing passes the
STANCE one. **A caller cannot forget a parameter it has to write**, and the two call sites now
state which they want and why.

## ★ WHAT I SHOULD HAVE DONE

Diffed the two functions **before** merging them, not after. The seed difference was one line and
visible in both bodies — and "they are the same six steps" was true of the shape and false of the
details, which is the only kind of sameness that matters when merging.
