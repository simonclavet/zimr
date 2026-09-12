# A task-space cost for the articulated planner

## ★★★ THE OBSERVATION THAT PROMPTED THIS (Simon's, and it is right)

> "Is there a way to make the MPC version better by having the smoothness of the path as a cost,
> along with position and velocity to match a reachable point and time on the ball trajectory?
> We should use MPC more?"

**We are barely using it.** In `examples/catch` the sequence is:

  1. `Ik` picks the interception POSE;
  2. `Ik` + the hand Jacobian picks the joint VELOCITIES;
  3. the planner tracks a smoothstep between them, in joint space.

Every decision was made before `optimize` was called. **The planner is a trajectory follower
wearing an optimiser's clothes**, and it can at best tie the servo — which is exactly what the
measurements show.

★★ AND IT IS WORSE THAN REDUNDANT: it OVER-CONSTRAINS. The task is three numbers (where the hand
should be) plus three more (how it should be moving). The arm has five joints. Converting the
task into a specific joint configuration throws the null space away — many poses put the hand on
that ball, `Ik` picks one, and the planner is then forbidden from using any of the others.

## Evidence that the joint-space formulation is the ceiling

    formulation                          gaps per throw
    fixed IK branch                      0.086  0.137  0.116  0.185
    NEAREST IK branch, re-solved live    0.086  0.028  0.118  0.184

Re-solving from the current pose so the target is the nearest configuration helps **where it can**
— one throw fell to 0.028, inside the 5 cm bar — and does nothing on the rest. **Picking a better
single configuration is still picking a single configuration.**

★ AND THE OBVIOUS SMOOTHNESS LEVER IS HARMFUL, MEASURED: raising the running velocity weight from
0.02 to 0.5 took the gaps from 0.086 to **0.790**. Penalising joint speed fights the one thing
the task requires. **Smoothness must be a cost on the CHANGE in control, not on speed** — and
that is a different feature with a different implementation.

## What to build

### 1. A task residual in `Cost`

    task: ?struct {
        body: u32,
        offset: Vec,
        position: []const f32,   // 3 per knot, the target
        velocity: []const f32,   // 3 per knot
        w_position: f32,
        w_velocity: f32,
    } = null,

Both fold into the existing quadratic machinery as Gauss-Newton terms, using the point Jacobian
`J` that `rbt.jacPoint` already provides:

    position residual  r = p(q) − p*        Q_x  += Jᵀ W r        Q_xx += Jᵀ W J
    velocity residual  r = J q̇ − v*         Q_v  += Jᵀ W r        Q_vv += Jᵀ W J

★ THE ONE STRUCTURAL COST: `Q_xx` is currently built from a DIAGONAL weight vector, and `JᵀWJ`
is dense. `backward` must accept a dense block. That is a real change to a well-tested function
and deserves its own turn and its own oracle — **not a bolt-on at the end of a session.**

### 2. A control-rate cost, for smoothness done properly

`0.5·w·(u[k] − u[k−1])²`. It couples adjacent controls, which the standard recursion does not
express — the textbook answer is to AUGMENT THE STATE with the previous control, turning the rate
term into an ordinary state cost on an `ndx + nu` system.

★ WORTH DOING FOR THE ROCKET TOO, where the chatter was diagnosed and only half-fixed by the
warm-start shift.

## ★ THE ORACLE, DECIDED BEFORE THE CODE

A task cost is right if, on a REDUNDANT arm, it reaches a task target that no single fixed IK
branch reaches from the same start — i.e. the planner finds a configuration `Ik` did not pick.
**That is a test the joint-space formulation cannot pass by construction**, so it cannot be
faked by tuning.

And on the catch: the bar stays where it was written before any code — **6 of 8 throws with gap
under 5 cm and relative speed under 0.5 m/s**, against pursuit's at most 1.

## ✅ THE CHANNEL AND THE REDUCTION ARE BUILT, WITH TWO ORACLES

**`Problem.extra_gradient` / `extra_hessian`** — per-knot terms added to `Q_x` and `Q_xx`.

★ PRECOMPUTED, NOT DESCRIBED, AND THAT WAS THE KEY DESIGN CALL. `backward` is a Riccati
recursion; it knows states, controls and quadratics, and **must not learn about robots**. A
caller holding a hand Jacobian can reduce any task residual to Gauss-Newton form and hand over
the result — which keeps the optimiser generic and means the same channel serves obstacle terms,
centre-of-mass terms, or anything else quadratic. It cost two lines inside `backward`, because
`Q_xx` was already dense; only the diagonal cost was special-cased.

**`addTaskResidual`** — the reduction itself: `Q_x += Jᵀ·w·r`, `Q_xx += Jᵀ·w·J`, into either the
position or the velocity block.

### The oracles, and why they cannot be faked

  1. **Equivalence.** The same running cost expressed twice — once as `cost.state`, once as an
     extra diagonal Hessian with the matching gradient — must give the same gains. A wrong scale,
     sign or knot index makes them diverge, and **no weight tuning could make them agree**. Plus
     a check that dropping the channel DOES change the answer, so the equivalence cannot pass by
     both sides ignoring it.
  2. **A numerical gradient of the task itself.** `addTaskResidual` claims `Jᵀwr` is the gradient
     of `0.5·w·|p(q) − target|²`; nudge each joint, recompute the hand position through forward
     kinematics, difference the cost. A transposed Jacobian, a weight at the wrong power, or a
     flipped sign all fail it. Plus symmetry and non-negative diagonal, which `JᵀwJ` has by
     construction and which the recursion depends on.

★ THE SECOND-ORDER TERM IS DROPPED ON PURPOSE — the exact Hessian carries `∂J/∂q · w · r`, which
needs second derivatives of the kinematics and vanishes as the residual does. Gauss-Newton is
positive semi-definite by construction, which the recursion needs, and converges quadratically
near the solution, which is where it matters.

## ✅✅ IT IS ASSEMBLED AND WORKING — AND THE END-TO-END TEST FOUND A REAL BUG

`Cost.task`, `Task` and `accumulateTask` were already present and wired through to
`Problem.extra_gradient`. **I planned a feature that was half-built and reported only the half I
remembered writing.** Worth naming plainly: the same shape as `readLimits`, where a capability
existed and went unused, and the cheap check in both cases is to grep for the thing before
designing it.

★★★ AND THE THIRD ORACLE EARNED ITS PLACE IMMEDIATELY. `accumulateTask` called `jacPoint` on a
`Data` at `.stale` — `optimize`'s loop leaves it there after stepping — so the Jacobian was
being taken at a stale configuration, and the point it hangs on was stale too.

**Neither unit oracle could have caught it.** The equivalence test checks the channel; the
numerical-gradient test checks the algebra. Both are perfectly happy with correct algebra about
the WRONG CONFIGURATION. Only running the whole loop shows where the caller evaluates the
Jacobian.

### The end-to-end test, and why it is shaped the way it is

**The joint reference is all zeros and every state weight is zero.** If the arm reaches the
target when the only thing asking it to move is the TASK, the task cost is doing the work — a
test that left a helpful pose reference in place could be passed by the pose reference alone,
which is exactly the confusion this feature exists to remove. Gravity off, so it is about the
cost rather than about holding a pose. Start gap asserted > 0.5 m so the test cannot be vacuous,
final gap < 0.10 m AND < 20% of the start, so a drift that happens to end nearby does not pass.

## Remaining

The catch demo does not yet USE it — a caller must fill the arrays itself. The next step is a
task description on `Cost` that `optimize` reduces per knot, calling `jacPoint` at each rollout
state. **The hard part — the reduction and its correctness — is done and pinned.**

And the oracle for the whole idea stands unchanged: **on a redundant arm, reach a task target
that no fixed IK branch reaches from the same start.** The joint-space formulation cannot pass
that by construction.

## 🚧 THE TASK COST, POINTED AT THE CATCH — WORSE, AND THE REASON IS STRUCTURAL

    controller   gaps over eight throws
    IK + PD      0.007 - 0.013   (swats all eight: relative speed 4.7 - 7.2 m/s)
    TASK MPC     0.031 - 0.497   (misses seven of eight)

**Worse than the joint-space version**, which reached 0.08 to 0.18 with the same horizon
machinery. That is not the feature failing; it is the feature being used wrong, and the shape of
the error is worth writing down.

★★★ **A TASK IS RANK-DEFICIENT.** A position task is rank 3, a velocity task is rank 3, and the
arm has 5 joints — so `JᵀWJ` leaves at least two directions with **zero curvature**. Every
state weight was set to zero to prove the task was doing the work (which the unit test needed),
and the result is a `Q_xx` that is singular in the null space. The regularisation ladder then
carries the entire problem, which is what it is FOR and not what it is GOOD at.

★ THE RIGHT REGULARISER IS A SMALL WEIGHT ON JOINT VELOCITY. It damps motion in the directions
the task does not care about without fighting it in the ones it does. Weighting joint POSITION
instead would pull toward a pose — reintroducing exactly the over-constraint this feature exists
to remove.

**This is a real and general lesson about task-space MPC, not a tuning detail**: the freedom that
makes a task cost worth having is the same freedom that makes it singular, and something has to
occupy the null space.

★★ THE SWEEP OVER THAT DAMPING WAS WRITTEN AND ITS EDIT FAILED ITS ASSERTION — the third wrapper
edit to resist this file. `claude.md` already says what that means: **write the sweep as its own
probe.** The numbers above are the undamped run and are labelled as such.

## Next, in order

  1. Sweep the null-space damping (own file): 0, 0.02, 0.2, 1.0.
  2. If that closes it, the demo gets the task cost and Simon's question has its answer.
  3. If it does not, compare against the joint-space version at equal effort — the honest
     possibility is that on a 5-DOF arm with a 3-DOF task there is not enough redundancy for
     the task formulation to pay for its own conditioning cost, and that would itself be worth
     knowing and saying.
