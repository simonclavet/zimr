# Humanoid one-leg balance — where MPC should shine

## Why this problem and not the quadruped gait

**Every quadruped failure was about the contact set changing**: gait sequencing, footstep
placement, which feet are down at knot k, the margin gate, leg reach as the feet advance.
Standing on one leg removes that entire category — one foot planted, support polygon fixed,
no schedule. What remains is the part that was already verified: `boxQP` against four
hand-computed answers, the Riccati recursion matching LQR to 0.1%, the regularization ladder.

**And the MPC argument here is structural, not incremental.** Windmilling the arms is
BORROWING: you accept angular momentum now to pull the centre of mass back over the foot, and
you must dump it before the arms hit their limits. That is a finite-horizon trade with a
terminal constraint, and no reactive gain can represent "spend momentum now, repay it in
400 ms". On one foot the centre-of-pressure box is about 0.2 x 0.1 m, so any real push
saturates it immediately — after which angular momentum, bounded in excursion, is the ONLY
authority left. Rationing a limited resource over time is exactly a constrained finite-horizon
problem.

## ✅ PHASE A — measured

**The model ships the pose.** MuJoCo's humanoid has a `stand_on_left_leg` keyframe. 17 bodies,
nv 27, nu 21, 40.8 kg.

    CM            (-0.0301, -0.1160, 0.8307)
    left foot     (-0.0680, -0.1031, 0.0266)
    right foot    (-0.4046, -0.3485, 0.3913)
    CM is 0.0400 m horizontally from the left foot
    right foot is 0.3913 m clear of the ground

A genuine one-leg stance with the mass nearly over the support. Nothing to design.

★ **AND MY FIRST CONTACT MODEL WAS WRONG, WHICH IS WORTH KEEPING.** The feet are two horizontal
capsules spanning x = −0.07 to +0.14 — a 0.21 m sole. Pushing one contact at each capsule's
CENTRE gives a single point under the middle of the foot, which resists NO PITCH AT ALL: the
robot pivots about it and goes over at every gain. The Go1 got away with one contact per foot
because its feet genuinely are spheres. Fixed to four points at the capsule ends, and verified
before trusting it — half-height 0.1055 x 2 = 0.211 m, matching the sole's `fromto` length.

★ **JOINT-SPACE `PoseHold` DOES NOT HOLD THE POSE.** Swept kp 200/400/800 against kv 10/25, all
six fall, tilt 1.05 to 2.27 rad. That is the expected answer and the reason the problem is
worth doing: a joint PD has NO balance feedback. It regulates joint angles, and ankle torque
proportional to joint error is a poor proxy for where the mass is. `examples/humanoid` already
shows the same controller holding the TWO-foot stance, so the setup is sound and the
controller is the missing piece.

★ AND ONE CONTROL WAS MEANINGLESS: enabling right-foot contacts alongside the left gave
byte-identical results, because in this pose the right foot is 0.39 m off the ground and its
contacts are skipped anyway. A two-leg comparison needs a two-leg POSE, not two-leg contacts.
The existing humanoid example supplies that evidence instead.

## The acceptance test, stated before building anything

**A push magnitude the PD cannot survive and MPC can, with the arms visibly doing the work.**
Not "MPC runs", not "the cost goes down" — a push in newton-seconds, a PD that falls at it, and
a planner that does not.

## Remaining phases

## ✅ PHASE B — the centroidal momentum matrix, done

`centroidalMomentum` (6 x nv, angular and linear rows) and `centroidalMomentumDirect` in
`robot_control.zig`, beside `comJacobian`.

★ **TWO INDEPENDENT ROUTES, ON PURPOSE.** The matrix is assembled from body Jacobians; the
direct sum reads `cinert`/`cvel`, which the dynamics maintains for its own reasons and which
never touches a Jacobian. They agree on a random pose and a random velocity. That is the same
cross-check that caught the missing `∂ω′/∂p` block in the trunk model.

★ **AND A PHYSICS ORACLE THAT BEATS ANY IDENTITY.** Gravity acts at the centre of mass, so it
exerts no torque about it: with no contacts and no actuation, angular momentum about the
robot's own centre of mass is EXACTLY conserved however wildly the limbs flail. Thrown into a
tumble from 5 m up, it drifts under 5% over half a second of free flight. **An error shared
between the matrix and the direct sum would pass the first test and fail this one.**

Both tests also assert the answer is not trivially zero, and the conservation test asserts that
LINEAR momentum is *not* conserved — if it were, the robot would not be falling and the test
would be measuring nothing.

  * ~~**B — centroidal momentum matrix.**~~ DONE. `comJacobian` exists; the momentum matrix `A_G(q)` does
    not. Its oracle: it must match a finite difference of the robot's total momentum, the same
    cross-check that caught the missing `∂ω′/∂p` in the trunk model.
## ✅ PHASE C — the balancing model, done

`BalanceModel`, `lipmStep`, `lipmLinearize` in `robot_mpc.zig`. State is
`[com_xy, vel_xy, momentum_xy]`, control is `[cop_xy, momentum_rate_xy]`.

**The derivation, because the signs are the whole thing.** From `m·c̈ = f`, `L̇ = (p − c) × f`
and `f_z = m·g`, eliminating the force:

    c̈ₓ = (g/h)·(cₓ − pₓ) − L̇_y/(m·h)
    c̈_y = (g/h)·(c_y − p_y) + L̇ₓ/(m·h)

Note the cross-coupling with OPPOSITE signs — a cross product relates them. And `(cₓ − pₓ)` is
positive feedback: that sign IS the inverted pendulum, and getting it backwards gives a model
that looks stable in simulation and falls over on a robot.

★ **ANGULAR MOMENTUM IS A STATE, NOT A CONTROL**, because it is the thing with a hard limit.
Arms only rotate so far, so a planner cannot keep spending it — it has to give it back. Making
it a state with its rate as the control is what lets a horizon express "accept momentum now,
return it before the arms run out". A reactive controller has nowhere to put that sentence.

★ **AND THE DYNAMICS IS EXACTLY LINEAR**, so `A` and `B` are constants — they do not depend on
the state at all. The trunk model had a mild yaw dependence that had to be re-linearised; this
has none. **One backward pass is the exact answer and there is no basin to fall into.**

★ THE PHYSICS ORACLES, WHICH DO NOT REPEAT THE MODEL BACK TO ITSELF:
  * released from rest it must go as `c₀·cosh(ω·t)` with `ω = √(g/h)` = **3.44 rad/s** — a
    number that appears nowhere in the code and must therefore be reproduced;
  * the flywheel moves the mass **with the centre of pressure held still**, which is the whole
    point and the thing no reactive controller can do without stepping;
  * both cross-signs pinned SEPARATELY — momentum about y drives −x, about x drives +y.
    Checking a norm would have passed with both wrong;
  * the centre of pressure pushes the mass AWAY from itself;
  * balanced exactly over the support, nothing moves for five thousand steps.

The Jacobian cross-check carries every lesson from the trunk model: centred differences, a
nudge of 1e-2 rather than something smaller, and a tolerance relative to each entry.

★ AND `zm.cosh` WAS ADDED PROPERLY rather than reaching for `std.math`: the linter blocks that
outside `zimrmath` for GPU portability, with no opt-out. Wrapped with a SPIR-V branch using the
exact `(eˣ + e⁻ˣ)/2` identity, following `cbrt`.

  * ~~**C — LIPM + flywheel**~~ DONE. and its analytic Jacobians, verified the way `srbdLinearize` was:
    centred differences, eps swept, tolerance relative to the entry size.
## ✅ PHASE D — the planner, and the acceptance test PASSES

`BalancePlan`, `BalanceLimits`, `solveBalance` in `robot_mpc.zig`, reusing `backward`, `boxQP`
and the regularization ladder unchanged. `A` and `B` are filled ONCE rather than per knot,
because they do not depend on the state.

★★★ **THE ACCEPTANCE TEST, STATED BEFORE ANY OF THIS WAS BUILT, NOW MEASURED.** Largest
sideways shove survived — same model, same cost, same horizon, the only difference being
whether the limbs may move:

    centre of pressure alone .... 0.30 m/s
    with the limbs .............. 0.85 m/s     **2.83x**

"Survived" is not "stayed inside the box": the mass must come BACK within 5 cm of the support
with its velocity under 0.10 m/s, and the momentum given back rather than parked at its limit.

★ WHY IT WORKS: on one foot the support is a few centimetres, so any real shove saturates the
centre of pressure immediately. After that the only authority left is angular momentum — and
because it is bounded in EXCURSION rather than rate, spending it is BORROWING. That is a
finite-horizon trade, which is exactly what a planner represents and a gain cannot.

★ AND THE TEST ASSERTS 1.3x RATHER THAN 2.8x, deliberately: it should measure the CLAIM that
the flywheel matters, not pin a number that drifts with the cost weights. The measured value
lives in a comment beside it.

  * ~~**D — MPC on it**~~ DONE., reusing `backward`, `boxQP` and the ladder. CoP box from the foot
    polygon, momentum box from the arm limits.
## 🚧 PHASE E — GATED BEFORE BUILDING THE DEMO, AND THE GATE FAILED

The planner produces a momentum RATE. Getting that onto the real humanoid needs a whole-body
mapping, so that was tested first — headlessly, before any demo work. **This is the discipline
that was missing for the whole quadruped arc.**

The obvious mapping is Jacobian transpose, `τ = A_G_angᵀ·w` on the limb DOFs. Measured in free
flight (no contacts, so gravity exerts no torque about the centre of mass and any momentum
change must come from the torques):

    requested w          achieved dL/dt            cosine
    ( 1.00, 0.00, 0.00)  (-0.029, 0.054,-0.018)    -0.462
    ( 0.00, 1.00, 0.00)  (-0.180, 0.050, 0.041)     0.262
    ( 0.00, 0.00, 1.00)  ( 0.027,-0.018,-0.004)    -0.135
    ( 0.60,-0.80, 0.00)  (-0.025, 0.044, 0.023)    -0.903
    (-0.30, 0.40, 0.87)  (-0.018,-0.021, 0.013)     0.274

★★★ **IT DOES NOT WORK, AND THE REASON IS STRUCTURAL.** A transpose maps a wrench to torques
under a QUASI-STATIC assumption. Here the dynamics is the whole point:

    L̇ = A_G·q̈ + Ȧ_G·q̇   and   q̈ = M⁻¹(τ − c)
    so with τ = A_Gᵀ·w:   L̇ = (A_G·M⁻¹·A_Gᵀ)·w + …

`A_G·M⁻¹·A_Gᵀ` is a 6×6 positive-definite operator, **not the identity**, so `L̇` comes out along
a rotated and rescaled direction — which is precisely what a cosine of −0.9 looks like. The
correct mapping inverts it:

    τ = A_Gᵀ·(A_G·M⁻¹·A_Gᵀ)⁻¹·w

`factorM` and `solveM` already exist in `robot.zig`, so the pieces are there. And the floating
base has no actuators, which is what makes windmilling work at all — so the real version is the
standard whole-body QP with the unactuated base rows as equality constraints.

★ THE POINT WORTH KEEPING: **a mapping that is merely plausible is not a mapping.** This one
looks right, is written in a hundred papers as shorthand, and produces motion anticorrelated
with the request. Ten minutes of gating caught it before it became a demo that "almost works"
and days of tuning cost weights that were never the problem.

### ★★★ AND THE CORRECTED MAPPING REVEALED THE REAL ERROR: FREE FLIGHT IS THE WRONG GATE

`momentumTorques` built as planned — `τ = Gᵀ(G·Gᵀ)⁻¹·w` with `G = A_G·M⁻¹·Sᵀ`, costing three
mass-matrix solves rather than one per joint (`G`'s rows are `M⁻¹·A_G_rowᵢ`, since `M⁻¹` is
symmetric) and a 3×3 solve. It scored a cosine of 0.214 — better than the transpose's −0.46 and
still wrong.

★★★ **BECAUSE THE QUESTION IS UNANSWERABLE. Internal joint torques CANNOT change centroidal
angular momentum** — Newton's third law, and the Phase B conservation test proves it directly:
thrown into a tumble with no contacts, `L` holds to under 5% however wildly the limbs flail.

So `G` is **exactly zero** for a free-floating robot. There is no authority to find, and the
ridge inside `momentumTorques` was the only reason it returned anything at all. The 0.214 was
noise being normalised.

★ **AND THIS REFRAMES WHAT THE FLYWHEEL IS.** Windmilling does not CREATE angular momentum, it
REDISTRIBUTES it: the arms take some, the body gives it up, the total is unchanged. What changes
the total is the GROUND REACTION — `L̇ = (p − c) × f`, which is exactly the term the balancing
model already has and which `solveBalance` already plans. **The limbs' job is to move the body
into a configuration where the ground can supply the momentum the planner asked for, not to
supply it themselves.**

`momentumTorques` is not wrong — `G` is genuinely non-zero once a foot is planted, because the
base is no longer free. It must simply be exercised there. The free-flight test is kept, skipped,
with this explanation attached, because it is the cleanest statement of the distinction.

★ THE LESSON, AND IT IS THE SAME ONE TWICE: **the gate was right and the hypothesis under it was
wrong.** Gating caught the transpose (cosine −0.90). Gating caught the pseudoinverse too (0.214).
What it could not catch was that both were answering a question with no answer — and only
noticing that a test I had already written FORBADE the thing I was asking for closed it.

## ✅ THE DEMO EXISTS: `examples/balance_flywheel`

Two identical inverted pendulums, same shove, same planner, same cost, same horizon. The near
one may only shift its centre of pressure inside its foot; the far one may also spin its arms.
The pressure marker turns pink when it is pinned to the foot edge with nothing left, and the
arms' ANGLE is the integral of the angular momentum — so a pendulum with no momentum authority
simply never moves them. The comparison, drawn.

★ EVERYTHING IN IT WAS ALREADY VERIFIED: the model against `cosh(ω·t)` with ω = √(g/h), the
Jacobians against centred differences, the planner against the 0.30 → 0.85 m/s result. Nothing
in the demo is new physics, which is exactly why it was built first.

## The humanoid, and what the study turn changed

★★★ **THE MECHANISM, STATED CORRECTLY.** From `L̇ = (p − c) × f`:

    L̇_y = −h·fₓ − (pₓ − cₓ)·m·g

Two independent knobs: the **centre of pressure**, limited by the foot, and the **tangential
force**, limited by friction. Once the foot has run out of room the first is finished, but you
can still push sideways — and that generates angular momentum which must go into the arms or
the body rotates. **The arms are a momentum SINK; the windmilling is the price of the sideways
push, not the push itself.**

That makes the whole-body controller much smaller than the QP I was heading toward:
  * centre of pressure → ankle torque, `τ = f_z × (p_desired − p_foot)`;
  * momentum → drive the arm joints to hold it, `q̇_arms = A_G_arms⁺·L_target`. The arms
    accelerating creates a reaction the foot resists, which IS the tangential force;
  * everything else → posture hold.

★ AND THE RISK I HAD WALKED PAST: Phase A measured that `PoseHold` cannot hold the ONE-LEG pose
at all, so an A/B there would have compared two failures. `examples/humanoid` DOES stand on two
feet — kp 400, drifting 4.5 mm over ten seconds, with a shove button already wired. **So the
humanoid work starts from two feet**, where a working baseline exists, and one leg becomes a
stretch rather than a prerequisite.

Gates, in order, each cheap and each able to fail:
  1. ankle torque → centre of pressure, checked against `τ = f_z × offset`. **ATTEMPTED, AND
     THE TESTBED IS WRONG — see below.**
  2. arm momentum tracking → trunk angular velocity stays small under a shove;
  3. `solveBalance` replacing the hand-tuned ankle policy;
  4. the A/B: same shove, arms enabled against disabled. Same push, PD against MPC, side by side.

Probe kept at `src/notes/humanoid_balance_probe.zig.txt`.

### 🚧 GATE 1 ATTEMPT — HAND-PUSHED CONTACTS DO NOT HOLD A HUMANOID

Wrote the centre-of-pressure readout (normal-force-weighted mean of the contact points; row 0
of each contact's four rows is the normal) and swept ankle torque against the prediction
`p = 2·τ / f_z`. The numbers were nonsense, and instrumenting the stance said why:

    at qpos0: torso z 1.2820
      all EIGHT foot points within ±0.010 m of the ground
    but: 4 contacts, normal force 0.9 N against a weight of 400.7 N

★★★ **THE STANCE IS RIGHT AND THE CONTACTS ARE NOT.** The geometry checks out — the robot is
upright with both soles flat — but a hand-pushed four-point-per-foot model carries 0.2% of the
robot's weight. It is not standing; it is falling slowly through a token contact set.

★ AND THE WORKING EXAMPLE NEVER DID IT THAT WAY: `examples/humanoid` runs a real `zp.World` and
lets the collision pipeline generate contacts. **That is where its kp-400, 4.5 mm-drift stand
comes from.** Hand-pushing contacts worked for the Go1 — spherical feet genuinely ARE point
contacts — and does not transfer to a 40 kg biped on two flat soles.

★ TWO POSE FACTS WORTH KEEPING, both of which cost a round:
  * `qpos0` is the standing pose. The model's four keyframes are squat / one-legged / prone /
    supine — all interesting, none of them the pose to hold.
  * A zero pose is not standing either: it gave 0.9 N of normal force, i.e. a machine on the
    floor.

### ✅ THE TESTBED IS VALID NOW — AND GATE 1 WAS SWEEPING THE WRONG VARIABLE

Rebuilt inside a real `zp.World` with the bridge (sync → step → harvest), copying
`examples/humanoid` rather than inventing a contact set:

    ankle Nm   contacts   normal N   torso z
         0.0          8       78.8    1.2770     STANDS (from 1.282)

**Eight contacts and it stands.** The testbed is real. Everything below is measured on a robot
that is actually standing rather than falling slowly through a token contact set.

★ THEN TWO ATTEMPTS AT THE ANKLE, BOTH WRONG IN INSTRUCTIVE WAYS:

  1. **Adding torque on top of `PoseHold` means fighting it.** The servo pulls the joint back
     toward its target, so the net torque is wherever the two settle — not what was asked for.
     Predicted a pressure shift of 0.165, measured 0.065.
  2. **Replacing `PoseHold` at the ankle collapses the robot** — torso to 0.259 even at zero
     commanded torque. Obvious in hindsight: a humanoid needs ankle torque to stand AT ALL, so
     commanding zero is commanding a limp ankle.

★★★ **WHICH IS THE ANSWER: THE ANKLE TORQUE *IS* THE CENTRE-OF-PRESSURE COMMAND**, not
something layered on top of a pose servo:

    τ_ankle = f_z · (p_desired − p_ankle)

At equilibrium `p_desired` sits under the centre of mass, which is NOT above the ankle — so the
torque is non-zero and that is exactly what holds the robot up. Sweeping τ with `p_desired` left
implicit at the ankle position was asking the robot to stand with its pressure in the wrong
place.

### 🚧 GATE 1 STILL FAILING AFTER THREE ATTEMPTS — HANDING OFF THE STATE

The geometry, finally measured (and this should have been the FIRST thing, not the fourth):

    centre of mass x   0.0157
    both ankles    x  -0.0100
    ankle pitch dofs   13, 19

So the equilibrium pressure sits **0.0257 m ahead of the ankle**, and the torque to hold it is
`0.5 × 400 N × 0.0257` ≈ **5.1 N·m per ankle**.

Swept `p_desired` over that value with BOTH signs of the ankle torque. Every case falls — torso
to ~0.26 from 1.28, achieved pressure 0.2 to 1.3 m, i.e. far outside a 0.21 m foot.

★ WHAT IS NOW KNOWN GOOD, so the next attempt does not re-verify it:
  * the world, bridge and contacts — **8 contacts, torso holds 1.2770 from 1.282** with plain
    `PoseHold` and no ankle command at all;
  * the pressure readout, which reads `constraint_force` row 0 per contact;
  * the geometry above.

### ✅ THE ANKLE, CHARACTERISED IN ISOLATION — AND ALL THREE SUSPICIONS WERE WRONG

The five-line probe that should have come first. One torque, one dof, gravity off, nothing else
driven:

    foot_left   joint 14  dof 19  hinge  axis ( 0.000, 1.000, 0.000)
    foot_left   joint 15  dof 20  hinge  axis (-0.894, 0.000,-0.447)
    foot_right  joint  8  dof 13  hinge  axis ( 0.000, 1.000, 0.000)

    dof 13   +5 N·m   qvel  +8.46   angle  +0.269   range ±0.873
    dof 13   -5 N·m   qvel  -8.90   angle  -0.268

★ **THE AXIS IS EXACTLY AS DECLARED** — dof 13 and 19 are pitch, `(0, 1, 0)`. The response is
linear and symmetric in both directions, and the ±0.873 rad range is generous. Every suspicion
about the ankle was wrong; it works.

★ AND ONE MEASUREMENT ERROR ON THE WAY, WORTH KEEPING. The first version read
`cvel[foot].ang` — the foot's WORLD angular velocity — and got a response dominated by **z**
for a joint whose axis is **y**. That was not the joint rotating: it was the whole free-floating
chain recoiling from the torque. **The joint velocity is what the torque acts on**; the foot's
world motion is that plus everything the rest of the robot did about it.

★★★ WHICH LEAVES ONE NUMBER AS THE SUSPECT: `τ/α` gives the ankle joint an effective inertia of
**0.030 kg·m²**. It carries the whole robot statically and has almost no inertia of its own, so
removing its position servo and applying open-loop torque leaves something very light being
driven hard — it will whip against those ±0.87 rad limits. **The pressure command almost
certainly needs damping in place of the servo it replaced:**

    τ_ankle = f_z·(p_want − p_ankle) − kv·q̇

Swept `kv` over 2, 8 and 25. **All three still fall.** Damping is not it either.

### ★★★ BUT THE SWEEP SURFACED THE REAL LEAD: THE NORMAL FORCE READS 5x TOO SMALL

    robot weight                        400.7 N
    summed contact normal, STANDING      78.8 N
    summed contact normal, during sweep  87 - 120 N

**The robot is standing and its contacts report a fifth of its weight.** Every ankle torque in
Gate 1 is computed as `f_z · lever`, so if `f_z` is five times too small, so is the command —
which is exactly the shape of "the ankle cannot hold it up" across every sign, every damping and
every requested pressure.

★ AND IT IS NOT AN OBVIOUS UNIT SLIP. `harvest` genuinely pushes the contacts into `rbt.Data`
and robot.zig's own solver resolves them, so `constraint_force` should be the force in newtons.
The ratio 400.7 / 78.8 = 5.08 does not match the timestep, the contact count, or `rows_per_contact`.

### ✅ FOUND IT: `rows_per_contact` IS A PYRAMID FRICTION BASIS, NOT `[normal, t1, t2, …]`

The conservation probe, run exactly as prescribed — stand with plain `PoseHold`, average the
contact normal over a settled second:

    dt 0.00100:  weight 400.7 N   mean normal 80.12   ratio 0.200   range [78.8, 81.2]
    dt 0.00050:  weight 400.7 N   mean normal 80.12   ratio 0.200   range [78.8, 81.2]

**Exactly one fifth, at both timesteps.** Steady, not oscillating — and timestep-independence
rules out an impulse-versus-force confusion. A clean 1/5 with the robot in equilibrium says the
wrong row is being read, so all four were dumped:

    contact 0:  12.739  9.898  24.608  9.249    normal (0,0,1)
    ...
    sum of ALL rows: 400.25          against a weight of 400.7 N

★★★ **99.9%.** The four rows are a PYRAMID FRICTION BASIS — four non-negative multipliers
arranged about the normal, whose sum is the normal force — not `[normal, tangent, tangent, …]`.
Reading row 0 read a fifth of the load, so `τ = f_z · lever` commanded a fifth of the torque,
which is precisely "the ankle cannot hold it up" across every sign, every damping and every
requested pressure.

★ WITH IT FIXED the force reads 598–913 N where it read 87–120. **The gate still fails** — the
robot still goes over — but for the first time it is failing on a correct measurement rather
than a broken one. Damping at 2, 8 and 25 all fall.

★★ AND THE LESSON IS THE ONE I WROTE DOWN LAST TURN AND THEN GOT TO USE: **a number that
disagrees with a conservation law is the finding, whatever else the run was about.** The 78.8 N
was visible in the first successful standing run, several turns before it was chased. The check
that found it took one probe and had an answer that could not be argued with.

★★ THE PATTERN, STATED PLAINLY: four turns on this gate, four plausible hypotheses (contact
model, servo interference, axis convention, damping), each disproven by a measurement that also
handed back a fact I did not chase. The 78.8 N was visible in the FIRST successful standing run
and I read past it because the robot was standing. **A number that disagrees with a conservation
law by 5x is the finding, whatever else the run was about.**

★★★ AND THE HONEST ASSESSMENT: **three turns on one gate without landing it.** The pattern is
the same each time — a plausible mapping, a confident sweep, and a fall. The thing that has
actually worked in this session is measuring the geometry FIRST and deriving the command from
it, and I did that at the end rather than the start.

**A cheaper next step than continuing:** verify the ankle axis in isolation. Apply a known
torque to dof 13 on a robot held rigid otherwise, and measure which way the foot rotates and by
how much. That is a five-line probe against an unambiguous prediction, and every attempt so far
has assumed its answer.

**So the gate sweeps `p_desired`, not torque**, computes `τ = f_z·(p_desired − p_ankle)` from the
measured normal force each tick, and checks the achieved pressure tracks the request. The ankle
comes out of `PoseHold`'s target set entirely; the pose servo keeps every other joint.

The centre-of-pressure readout works and keeps — it reads `constraint_force`, which is populated
the same way regardless of who generated the contacts.

Probe at `src/notes/cop_gate_probe.zig.txt`.

## ✅✅ GATE 1 PASSED — THE PLANNER STANDS THE REAL HUMANOID

    push m/s   ankle kv   torso z   CM drift   verdict
        0.00        4.0    1.2810    -0.0158   STANDS
        0.00       15.0    1.2810    -0.0158   STANDS
        0.15        4.0    1.2810    -0.0158   STANDS
        0.30        4.0    1.2810    -0.0157   STANDS
        0.30       15.0    1.2810    -0.0157   STANDS

`solveBalance` reading the robot's centre of mass and velocity, choosing a centre of pressure,
and the ankles realising it — on the real 27-DOF humanoid with real contacts. Six cases, all
standing, 1.6 cm of drift.

★★★ TWO THINGS UNLOCKED IT, AND BOTH CAME FROM MEASURING RATHER THAN REASONING:

  1. **A fixed pressure command is not a balance controller.** Every earlier attempt held the
     pressure at ONE spot and asked whether the robot stood. It never could — an inverted
     pendulum held open-loop has no restoring anything. The pressure must MOVE with the mass,
     which is what the planner is for. I spent four turns testing an open-loop hold of an
     unstable system.
  2. **The sign, read off the controller that already works.** Plain `PoseHold` stands this
     robot, so its ankle torque IS correct by construction: **+7.816 N·m**, against
     `0.5·f_z·(p_cop − p_ankle)` = **+7.29**, within 7%. POSITIVE. Every attempt had used the
     negative. Deriving it from a working system took one print; arguing it from a cross product
     had failed repeatedly.

## 🚧 IN THE EXAMPLE IT TRAPS — SHIPPED OFF BY DEFAULT

Wired into `examples/humanoid` behind a toggle. Enabled, it traps inside `addContactRows`: the
contact rows overflow, i.e. the robot is flailing hard enough to pile up contacts.

★ THE SAME CONTROL LAW STANDS IN THE PROBE, so the law is not what differs. What differs is the
scene: `buildScene` appends the throwable BALLS to the same model (fixed — the centre of mass is
now summed over the robot's bodies only), the example steps `zp` and `rbt` in a different order
from the probe, and it carries its own solver seam. One of those is it.

**Shipped default-off** so the example is exactly as it was and the work is visible rather than
crashing. Next: run the example's exact step order inside the probe, which is the difference
that has not been eliminated.

## ✅ THE FLYWHEEL IS WIRED INTO THE EXAMPLE

★ AND THE REASON THERE WAS NOTHING TO WATCH WAS MINE: `max_momentum_rate` was set to **0.0**.
The planner had no momentum authority at all — only permission to shift the pressure inside the
foot, which is the ANKLE strategy. It stands slightly better and moves nothing, exactly as
reported.

Now wired:
  * an **arm authority** slider driving `max_momentum_rate` (0 = ankle only);
  * the momentum command mapped to limb velocities by
    `q̇ = A_G_limbsᵀ(A_G_limbs·A_G_limbsᵀ)⁻¹·L`, a 3×3 solve;
  * arms, forearms, hands, waist and pelvis as the flywheel set;
  * a **limb swing** readout so the motion is a number, not an impression.

★★★ **VELOCITY, NOT TORQUE, AND THAT DISTINCTION IS THE PHYSICS.** Internal joint torques
cannot change total angular momentum — the conservation test in `robot_control.zig` proves it
directly. The limbs are a momentum SINK: the GROUND supplies the momentum through the tangential
contact force, and the arms decide whether it lands in them or in the trunk. Asking them to MOVE
at the rate that holds it is the honest statement of that job, and asking them to CREATE it is
the mistake that cost two turns earlier in this plan.

★ ONE ZIG DETAIL WORTH KEEPING: a `Vec` cannot be indexed with a runtime loop counter, so the
loops over the three momentum axes must be `inline for`. It compiles for the host and fails for
wasm, which is a slow way to find out.

## ★★★ WHY IT EXPLODED — FOUR FAULTS, MEASURED

### 1. A dimensional error no gain could fix

`ctrl[rate_offset]` is `L̇`, kg·m²/**s²**. The map `A_G·q̇ = L` wants a MOMENTUM, kg·m²/**s**.
The `0.25` sitting between them was a number chosen to make the magnitude look plausible. The
plan's STATE carries the momentum it intends to hold; that is the target.

### 2. The planner was given 2x the authority the body owns

Measured from the mass matrix, then priced honestly:

    per arm: spin 0.255 x 8 rad/s = 2.04, orbital 2.5 kg x 0.3 m x 2.4 m/s = 1.80
    both arms: **7.68 kg·m²/s**
    dv it can arrest = L/(m·h) = **0.23 m/s**

At `max_momentum_rate = 80` the planner asked for **16.4** — 2.1x capacity — and the tracker
faithfully demanded **55 rad/s** of arm velocity to deliver it. That is the explosion.

★★ AND THIS CORRECTS AN EARLIER CLAIM OF MINE. `examples/balance_flywheel` quotes 0.30 → 0.85
m/s, **2.83x**, and that run used |L| ≈ 16 — momentum this body cannot carry. **The honest
number is about 0.30 → 0.53, roughly 1.75x.** Still a real and worthwhile margin; not the one
advertised.

### 3. Momentum excursion is a STATE limit and `boxQP` bounds controls only

There is no constraint to write, so the cost weight is the entire brake. At 0.02 momentum was
nearly free. Swept: weight 2.0 keeps a 0.3 m/s push peaking at 0.54, inside capacity.

★ AND THE SWEEP ALSO SHOWED WHERE THE WEIGHT DOES NOTHING: at 0.6 m/s the peak is **16.4 at
every weight from 0.02 to 60** — because that is `rate_limit × time_to_fall`, momentum
integrating while the robot goes over anyway. Identical across a 3000x sweep is not a tuning
knob.

### 4. The waist and pelvis are not a flywheel

Their inertias are **8.72 and 5.99** — the whole upper body, against 0.14 to 0.19 for the arms.
Driving them to hold momentum moves half the robot's mass, which moves the centre of mass, which
the pressure controller is simultaneously regulating. Two controllers, one variable. Arms only.

★ AND THE GAIN CEILING IS A MEASURED NUMBER: explicit PD wants `kd·dt/I < 2`, and the smallest
limb inertia is **0.068** (forearm), so at 1/500 the ceiling is **68**. Twenty leaves margin.

## 🚧 STILL TRAPPING — AND NOT WHERE I EXPECTED

All four corrections are in `examples/humanoid`. The smoke run still traps with `memory access
out of bounds` — **and it traps with `momentum_rate = 0` and `balance_on = false`**, so the
fault is NOT in the limb code that was just added. Something in the balance wiring traps
regardless of whether it runs. Shipped with the arm authority defaulted to zero.

### ★★★ BISECTED — AND THE SMOKE TRAP WAS ALREADY THERE

Extracted `zimr1210` — from before Phase A, before ANY balance work — and ran its
`examples/humanoid` unchanged:

    RuntimeError: unreachable        (addContactRows, constraint rows overflowed)

**The humanoid smoke test has been failing independently of this work.** Part of a turn went
into chasing a phantom, and five minutes of bisecting against an old snapshot settled what
reasoning had not.

★ AND THE TWO TRAPS ARE DIFFERENT, which is the useful part:
  * the PRE-EXISTING one is `unreachable` in `addContactRows` — the constraint rows overflow,
    so the scene is generating more contacts than `max_contacts = 128` allows. A ragdoll plus
    three balls plus a ground plane will do that.
  * the one added with the balance wiring is `memory access out of bounds`, a different fault
    in different code.

Fixing the first is a capacity question and has nothing to do with balancing. The second is
mine and is still open.

★★ THE PROCESS LESSON, AND IT IS CHEAP: **when something fails, check whether it failed before
you touched it.** Snapshots exist precisely for this and I reached for them only after
exhausting reasoning. `unzip` an old one, swap the file, run the gate — under five minutes, and
it reframed the whole problem.

**Next:** raise `max_contacts` in the example (or find why so many contacts appear) for the
pre-existing trap, and bisect the balance additions field-by-field for the new one.

## ✅ MY OOB FOUND — A WRITE THROUGH AN UNALLOCATED SLICE

    line 332:  s.balance_hold.powered[dof] = false;
    line 344:  s.balance_hold = try ctl.Actuation.init(gpa, &model);

**Written to twelve lines before it was allocated.** In debug wasm that is `memory access out of
bounds`; on the host it happens to land in whatever memory was there. The arms are removed from
the servo in a second pass now, after the actuation set exists.

★ AND THE TRAP CHANGED CHARACTER WHEN FIXED — from `memory access out of bounds` back to the
pre-existing `unreachable`. **That is how you know a bisect landed**: not that the failure went
away, but that it became the OTHER failure.

★ THE PRE-EXISTING ONE IS NOT A CAPACITY PROBLEM EITHER. Raised `max_contacts` from 128 to 384
and it traps identically — so it is a failed `@intCast` inside `addContactRows`, in engine code,
not a budget the example got wrong. Reverted, with the finding recorded where the number is.

## Where the humanoid stands

  * `solveBalance` drives the ankles, and stands the robot: **six pushes, torso 1.2810, drift
    0.016 m** (headless, real contacts).
  * The flywheel is wired with all four corrections — momentum not rate, arms only, derived rate
    of 40, momentum weight 2.0, clamped velocity and torque.
  * The example builds, lints, verifies imports and passes the suite. **The smoke run still
    traps on the pre-existing engine fault**, so the browser is the only place to see it.

## ✅ A PROCEDURAL ONE-LEG POSE, AND IT NEARLY DOUBLES THE FLYWHEEL

`buildOneLegPose` in `examples/humanoid`: left leg lifted, arms out at 45 degrees forward and to
the sides, mass placed over the support foot.

    arms EXTENDED   15.54 kg·m²/s   -> arrests 0.428 m/s
    arms folded      7.92 kg·m²/s   -> arrests 0.218 m/s

★★★ **NEARLY DOUBLE, AND THE REASON IS GEOMETRIC.** The orbital part of the centroidal angular
momentum goes as `m·r²·ω`, and extending an arm takes `r` from about 0.3 m to 0.6. **The arms
ARE the flywheel**, and a pose with them folded throws most of it away — which is exactly what
the shipped `stand_on_left_leg` keyframe does.

★ THE MASS LANDS ON THE FOOT IN **ONE NEWTON STEP**, to 0.6 mm:

    iter   hip_x     hip_y     CM-over-foot
       0   0.0000    0.0000    |0.1088|
       1   0.1347   -0.0726    |0.0006|

Translating the root moves foot and mass together, so their offset is fixed by the joints alone
— `hip_x` swings it sideways, `hip_y` fore-and-aft. A 2x2 numerical Jacobian on those two, and
it converges immediately. The shipped keyframe starts **0.040 m** off, so a balance controller
opens by fighting an offset instead of at equilibrium.

★ AND THE ARMS GO OUT BY IK, NOT BY ANGLE. The shoulder axes are `2 1 1` and `0 -1 1` — not
orthogonal, not aligned with anything — so "45 degrees" in joint space would mean whatever those
axes made of it. A hand POSITION is unambiguous, and `limbActuation` keeps each solve inside its
own arm.

Final pose: torso 1.296, hands 1.075 m apart at (0.368, ∓0.538, 1.356), left foot clear at
0.213.

## ✅ "IT EXPLODES" AND "RESET DOES NOT RESET" WERE THE SAME BUG

★★★ **`solveBalance` WARM-STARTS FROM `plan.ctrl` — that array is the ITERATE, not an output.**
After a fall it holds whatever extreme pressure and momentum commands the planner reached while
going over, and every reset path cleared only the POSE. The first tick on the fresh pose then
applied them.

That is both symptoms at once: reset appeared not to take, because the CONTROLLER did not reset;
and it exploded, because a stale extreme plan met an upright robot. `restorePose` now clears
`plan.ctrl`, `plan.reference`, `applied_force`, and the readouts.

★★ AND THE ONE-LEG CHECKBOX WENT AROUND `restorePose` ENTIRELY, doing its own half-reset. It
missed `bridge.teleported()` — and the comment already in that function says why that matters:
writing `data.pos` is a TELEPORT, and a swept contact drawn across the gap finds the floor and
fires the robot away. **Half a reset is worse than none, because it looks like it worked.**
Every pose change now goes through the one path.

★ TWO MORE, FOUND WHILE FIXING THOSE:
  * `buildOneLegPose` used `pose_scratch` as its save buffer and the caller passed the SAME
    array as the output. It happened to work and was one edit from not. It now leaves the pose
    in `data.pos`, which is what the only caller wants anyway.
  * **the ankle load is clamped to twice the weight.** The ankle torque is `f_z · lever`, so it
    scales directly with the reported contact force — and during an impact the solver
    legitimately reports several times the weight for a few ticks. Multiplying a spike into a
    joint command is a feedback loop with a spike in it.

★ THE LESSON: **a controller has state, and resetting the world does not reset it.** The pose,
the velocities, the solver warm start and the bridge were all handled; the planner's iterate was
not, and it is the one that acts first on the next tick.

## 🚧 THE BUILT POSE IS A BUTTON NOW — AND IT DOES NOT HOLD

Moved from a checkbox to a button beside the model's four keyframes, going through `restorePose`
so it gets the teleport notice, the warm-start clear and the planner reset. It also switches the
balance controller ON, because offering a one-legged pose with the only controller that could
hold it switched off is offering a pose that always falls.

    pose servo alone        torso 1.296 -> 0.452, tilt 2.31   falls
    + pitch ankle only      torso        -> 0.480, tilt 2.45   falls
    + BOTH ankles           torso        -> 0.486, tilt 0.16   falls

★★★ **THE ROLL ANKLE IS MOST OF THE DIFFERENCE, AND IT WAS SIMPLY NOT BEING DRIVEN.** Only
`ankle_y` was commanded, so the LATERAL axis was uncontrolled — and on one leg that is the hard
direction: the foot is 0.21 m long and **0.06 m wide**, so there is barely any polygon to move
the pressure inside. With both ankles the tilt falls from 2.45 rad to **0.16**. It no longer
tips.

★ IT SINKS INSTEAD — torso to 0.486 with the trunk still upright. That is a DIFFERENT failure
and it is not a torque ceiling: `PoseHold.max_torque` defaults to **1000 N·m**, so the leg has
ample authority and folds anyway. Why the support leg collapses is the open question, and the
tilt number says it is worth answering rather than starting over.

★ AND THE ROLL SIGN WAS MEASURED, NOT DERIVED: `-1` gives tilt 0.156, `+1` gives 1.744, and zero
gives 1.994. Same technique as the pitch ankle, where reading the working controller's torque
settled in one print what several turns of cross-product argument had not.

## ✅✅ THE POSE WAS STANDING ON ONE CORNER — SIMON SPOTTED IT

> "Local bone rots are correct but globally we should orient the body."

Exactly right, and measurable. `buildOneLegPose` set joint angles and dropped the root's HEIGHT,
and never touched the root's ORIENTATION. Bending the support hip rotates the leg against a
torso that stays bolt upright, so the foot arrives at the ground at whatever angle the chain
leaves it:

    sole contact heights, before:  0.0493  0.0000  0.0334  0.0266
    spread 0.0493 m over a 0.21 m sole -> tilted 13.2 degrees
    foot up-axis (-0.073, -0.134, 0.988)

**One corner touching, the other three between 27 and 49 mm in the air.** That is not a stance,
it is a pose caught mid-fall — and no controller holds it, because a foot on a corner has no
support polygon at all. It explains "he cannot hold it" completely.

★ `levelFoot` rotates the WHOLE robot so the sole's up-axis is vertical:

    after:  0.0205  0.0003  0.0003  0.0205     foot up-axis (-0.010, 0.001, 1.000)

Two points down instead of one, and symmetric. The 5.5 degrees that remain are the foot model's
own rake — the sole is raked in the file, visible at `qpos0` too — not an error.

★★ AND THE ORDER HAD TO CHANGE WITH IT. Levelling rotates everything, so anything placed in
WORLD coordinates beforehand rotates too: reaching first left the arms lopsided, right hand at
z 1.166 against left at 1.677, from a step meant to be symmetric. Stance first, arms last — then
one more Newton pass, because reaching moves roughly 5 kg out to half a metre and took the
centre of mass from 0.6 mm off the foot to 21 mm.

★ AND `zm.atan2` WAS ALREADY THERE. Reaching for `std.math.atan2` tripped the same GPU-portability
rule that caught `std.math.cosh` earlier — banned outside `zimrmath`, no opt-out. Worth checking
before wrapping: the wrapper existed.

## 🚧 "FALLS FORWARD" — TWO CAUSES FOUND, ONE ATTEMPT REVERTED

### ✅ The mass was aimed at the wrong point

The sole runs from **−0.07 to +0.14** in the foot's frame, so its middle is **0.035 m forward**
of the foot BODY ORIGIN — a third of the way to the toe. Every version targeted the origin,
putting the mass that far behind the middle of its own support before anything moved.

★ AND A ONE-LEGGED STAND HAS NO MARGIN TO SPEND. The sole supplies about `f_z × 0.105` ≈ 42 N·m
of restoring moment against `m·g·h·θ` ≈ 360·θ, so a stiff ankle holds out to roughly **6.7
degrees** of lean. 3.5 cm at 0.9 m is **2.2 of those degrees given away for nothing** — a third
of the whole budget. That is why it fell FORWARD rather than wobbling.

`comOverFoot` now targets the mean of the four sole contact points.

### ✅ The roll ankle is now driven in the example too

Only `ankle_y` was commanded, so the LATERAL axis was uncontrolled — and the foot is 0.21 m long
against **0.06 m wide**. Measured: pitch alone gives tilt 2.45 rad, both ankles **0.16**.

### ❌ AND A PLANE-FIT LEVELLER MADE THINGS WORSE — REVERTED

The body-frame leveller leaves a 5.5 degree residual because the two sole capsules SPLAY (foot1
runs y −0.01 to −0.03, foot2 +0.01 to +0.03), so the body's up-axis is not the sole's normal.
Fitting a plane through the four contact points levelled the sole beautifully — **0.3 mm spread,
0.1 degrees** — and rotated the body 45 degrees doing it, after which the Newton pinned against
its hip limits with the mass 0.59 m away.

★ THE SPANNING VECTORS ARE 0.21 m AND 0.02 m. That cross product is ill-conditioned in f32, and
a small angular error in the normal becomes a large body rotation. A least-squares fit over all
four points, or levelling about the foot's long axis only, would be the way — **not** two
vectors of wildly different length.

Reverted to the body-frame version, which leaves the sole 5.5 degrees raked but the pose sane.

## ★★★★ THE ROOT CAUSE: A CAPSULE RUNS ALONG LOCAL **Y**, NOT Z

From `robot.zig`, one line in `GeomShape`:

    /// Segment along local Y plus a radius — zimr's capsule convention, not MuJoCo's.

**Every foot calculation in this arc used Z.** The endpoints were therefore perpendicular to the
real sole, and three turns of "findings" were artefacts of it:

  * the sole "raked 5.5 degrees" — it is not raked at all;
  * the built pose "tilted 13.2 degrees, resting on one corner";
  * the plane-fit leveller rotating the body 45 degrees and pinning the Newton at its limits.

★★ AND THE TELL WAS IN THE VERY FIRST MEASUREMENT. At `qpos0` this humanoid STANDS, so its soles
are flat by definition — and the probe reported a **2 cm spread** there. A flat-footed robot at
its own standing pose cannot have a raked sole. I read past it three times because I was looking
at the one-leg pose, not at the control.

With the axis corrected:

    qpos0 sole spread:  0.00000 m     exactly flat, as it must be
    built pose spread:  0.0021 m      0.6 degrees, was "5.5"

**A control that cannot lie, checked first, would have saved three turns.** Same lesson as the
78.8 N normal force — a number that contradicts something you know for certain IS the finding.

## 🚧 WHAT REMAINS: THE LATERAL SHIFT NEEDS TWO JOINTS

With the geometry right, the Newton stalls **at a joint limit**:

    hip_x  alone:  runs to -0.52 (its limit), leaves 16 mm lateral offset
    abdomen_x alone: runs to -0.60 (its limit), leaves 20 mm

On a foot **0.06 m wide** (±0.03), 16-20 mm is over half the half-width — marginal at best. And
saturating either joint alone is the answer to Simon's "use torso rotation to balance": standing
on one leg needs the hip AND the torso leaning together, because neither has the range on its
own. Real one-legged stances look like that for exactly this reason.

**Next:** three unknowns (hip_x, abdomen_x, hip_y) against two equations, solved least-norm —
the same `solve3`-shaped problem as the momentum map. That distributes the lean instead of
pinning one joint and giving up.

## ⚠️ REGRESSION: THE ROLL ANKLE BROKE THE TWO-FOOTED STAND

Wiring the roll ankle into the controller broke a stand that had been holding at torso **1.2810
across six pushes** — because it was measured on ONE LEG and applied to BOTH cases.

★★★ **WITH TWO FEET, THE LATERAL CENTRE OF PRESSURE IS SET BY HOW THE LOAD SPLITS BETWEEN THE
FEET** — a 0.3 m stance width — **not by rolling either ankle inside its own 0.06 m sole.**
Commanding roll there fights a stance that was already fine, using the wrong actuator for the
job entirely. On one leg it is the only lateral authority there is, and worth 2.45 rad of tilt.

So the roll command is now gated on one-leg mode. And the roll dof STAYS IN THE POSE SERVO
otherwise: a joint that is neither servo'd nor commanded is limp, and a limp ankle collapses
under a standing robot — the same trap as the pitch ankle several turns back.

★ THE PROCESS FAILURE IS THE PLAIN ONE: **a change measured in one configuration was shipped
into all of them.** The one-leg probe said 2.45 rad to 0.16, which was true and had nothing to
say about two feet. Re-running the two-foot regression took one command and I did not run it.
