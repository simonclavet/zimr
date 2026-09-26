# drecon2.md - DReCon and SuperTrack as two zimr examples

Written Sep 15 2026 after reading both papers and measuring what the tree already has.

**The target:** a physically simulated humanoid follows 10 seconds of the dance clip after
10 minutes of training in a browser on WebGPU, with the trained networks surviving a page
reload.

That target is aggressive and the plan is built around finding out early whether it holds,
rather than around assuming it does.

---

## 0a. THE METHOD DECISION, Sep 15

**SuperTrack as the learner. iLQR as an OFFLINE teacher for the world model. DroQ as the
fallback.** Reasoning, because the decision is not obvious and the reasons matter more than the
choice.

### The number that decided it

TD-MPC's own wall-clock table for **Humanoid Stand**:

    time to solve      SAC 9.31 h      TD-MPC 9.39 h
    h per 500k steps   SAC 1.82        TD-MPC 12.94

*** **TD-MPC IS DRAMATICALLY MORE SAMPLE-EFFICIENT AND EXACTLY AS SLOW IN WALL CLOCK**, because
each step costs 7x more. On the simpler Walker Walk it wins 16x over LOOP; at humanoid scale,
sample efficiency buys nothing you can feel. **"Fewer environment steps" is not our metric. Ten
minutes on a clock is.**

** And their **MPC:sim** baseline - real simulator, short horizon, no value function - **fails**
Humanoid Stand. Short-horizon MPC on a humanoid is not automatically a solved problem.

### Why our task is different, and it is the whole argument

Every result above is a HARD EXPLORATION problem: standing up from a random policy means
discovering how to stand. Ours has none of that.

| they have | we have |
|---|---|
| a sparse or shaped reward to discover | **a reference pose at EVERY frame** |
| a policy starting from noise | **open-loop playback that nearly works** |
| a state distribution to explore | reference state initialisation - every frame is a valid start |
| 1.4M frames of diverse motion | one clip |

*** **SO THE BOTTLENECK IS NOT EXPLORATION - IT IS THE VALUE FUNCTION.** SAC, DroQ and AWR all
need a critic representing expected discounted tracking reward to the end of the clip. At
`gamma = 0.99` over 600 steps that is a hard regression, and it is the slow part.

**SuperTrack has no value function at all.** The tracking loss is measured directly on predicted
states over a 32-frame window - no bootstrapping, no TD error, no credit assignment. With a dense
reward and no exploration problem, **a critic is pure overhead: paying for the most expensive
part of RL to solve a problem we do not have.**

### Where iLQR earns its place, and where it does not

*** **OFFLINE, SEEDING THE WORLD MODEL.** SuperTrack's real weakness is 7b/A5: the world model
learns the distribution the CURRENT policy visits, then the policy walks off it. iLQR fixes that
directly - **run it over perturbed states around the reference tube and you get training data
covering exactly where the policy will go, before it goes there.**

** **NOT AT RUNTIME, on two measured grounds.** iLQR needs `A` and `B` at every knot.
Finite-differencing a humanoid at `nv ~ 50` is about 50 rollouts per knot x 12 knots x ~10
iterations = **6,000 dynamics evaluations per control step.** Even at 20 us/step that is 120 ms
per control step - **roughly 10x slower than realtime.** An offline teacher, not a controller.

** **And iLQR linearises, while contact does not.** Our cartpole success does not transfer - a
cartpole has no contact events. **This is the assumption most likely to break and it is the first
thing to test.**

### The fallback and what was dropped

* **DroQ if the world model will not hold.** Specifically because our collection is CPU physics
at tens of microseconds per step while our updates are tiny networks - **collection is the
bottleneck**, which is exactly the regime where a high update-to-data ratio pays.

* **AWR is dropped as a contender.** Its advantage over DroQ is simplicity, not speed, and it
still needs a critic. It stays only as a RIG-DERISKING step - it is the algorithm we have a
learning gate for - and that is a process argument, not a speed one. The earlier plan conflated
the two.

---

## 0b. FIRST DERISKING MEASUREMENT, Sep 15

    5. humanoid_flex, settling   nv 29   8890 ns/step   469x realtime   nc 0

*** **THE CHARACTER IS SMALLER AND CHEAPER THAN THIS PLAN ASSUMED.** `nv = 29`, not the 40-50 I
budgeted from body count, and **8.9 us/step against a 20-40 us estimate.** Both errors were in
the same direction and the plan was pessimistic.

** **BUT `nc 0` - IT NEVER TOUCHED THE GROUND, so this is the free-fall cost.** Twenty thousand
steps is forty seconds of simulated time and the character reports no contacts, which means the
T-pose loads too high, the feet miss, or the model has no contact geometry reaching the floor.
**The expensive regime is unmeasured and the note lives in the benchmark itself rather than
here.**

* The bound from case 4 is what to use meanwhile: a **Go1 at nv 18 with SIXTEEN contacts costs
9829 ns** under PGS, against a contact-free humanoid at nv 29 costing 8890. A humanoid in contact
has two feet, far fewer rows than sixteen - **budget 20-35 us/step as an upper bound.**

### What this buys, arithmetically

At 20 us/step and 4 substeps per 60 Hz control step, one character produces **~12,500 control
steps per second**. Ten minutes of pure collection on one core is 7.5M control steps against a
600-frame clip - **12,000 passes over the whole animation.**

** **So collection is NOT the bottleneck, and that changes the fallback argument in 0a.** DroQ
was recommended partly because "collection is the bottleneck, which is where a high UTD pays".
On this measurement it is not, and the argument for DroQ weakens to its real one: it is a
well-tested method we already have every piece of. **The recommendation stands; one of its
reasons does not.**

### Next derisk, unchanged and now more urgent

Whether iLQR tracks the clip through contacts. The contact regime is exactly what is unmeasured
above AND exactly what iLQR's linearisation assumes away - **the same gap appears twice, which is
a reason to close it before anything else is built on either side.**

---

## 0c. SuperTrack REPRODUCED IN MINIATURE, Sep 15

A cartpole version of the whole mechanism, in `zimrnum` as a test. World model trained on real
rollouts, policy trained ONLY by backprop through it. **The policy never touches the simulator.**

*** **IT WORKS. Tracking loss 0.283 -> 0.211 over 500 iterations**, with gradient arriving at the
policy from a tracking error, backwards through sixteen integration steps and a learned model of
physics. That is SuperTrack's entire claim, on a system small enough to be sure about.

** **THE WORLD MODEL IS THE EASY HALF: 0.036 MSE on accelerations** after 400 supervised steps
with a 32-unit hidden layer. Predicting cartpole dynamics is not hard; the humanoid will be, but
this says the supervised half of the method is not where the risk is.

** **CARTPOLE FIRST WAS THE RIGHT CALL because it has no quaternions.** The integration is
`v += a*dt; x += v*dt` on the tape - the same shape `integrateRigidBodies` will have, without the
rotation algebra. **The quaternion work can now be checked against a loop that already works**,
rather than being debugged at the same time as the training loop.

### Three findings from getting it to run, each a real bug

*** **THE GRAPH MUST BE BUILT ONCE AND ITS LEAVES REWRITTEN.** The first version built the
sixteen-step unroll inside the training loop, so the tape grew by sixteen steps of nodes every
iteration and never shrank. At 500 iterations the test stopped producing output entirely. **This
is not a slow version of the right thing - it is a leak**, and `ppoUpdate` already uses the
correct pattern.

*** **THE WINDOW MUST BE LONG ENOUGH FOR AN ACTION TO MATTER.** The first version used 4 steps,
which at `dt = 0.02` is an EIGHTY MILLISECOND horizon - a few newtons moves the cart under a
centimetre, so the policy could barely affect its own loss and training was flat. **It looked
like the method failing and it was the task being impossible.** SuperTrack's `N_pi = 32` is this
constraint, and their own note says a larger window is needed for motions where apprehension is
required.

* **Directly relevant to the 0.2 s MPC idea:** a 0.2 s window is 12 frames at 60 Hz, and this
experiment says 4 frames is far too few for an action to matter while 16 is enough. **12 is
above the floor but not by much**, and this is the cheapest evidence available on whether that
horizon is viable.

### What is NOT proven, stated plainly

** Longer training made it **worse** - 0.211 at 500 iterations, 0.254 at 2000. That is
oscillation rather than convergence, and it says the loop needs **Adam rather than plain SGD**
before any conclusion about how well this converges. `adamStep` exists; `stepParameters` is
where it goes.

** The task has an irreducible floor: the start is perturbed on all four state components, so
much of the loss is an offset no policy can undo in 0.32 s. **The next version should compare
against a ZERO-FORCE policy rather than against its own starting loss**, which isolates "the
policy does something useful" from "the task has a floor". The test says so in its own comment.

---

## 0d. MPC DATA MAKES A BETTER WORLD MODEL - MEASURED, Sep 15

The claim in 0a was that iLQR earns its place OFFLINE, generating world-model training data
covering where the policy will go. **That claim was untested. It is now measured.**

Two world models, identical initialisation, identical sample count, identical number of steps.
**The only difference is which actions produced their data.** Both evaluated on states an MPC
controller visits.

    world model error on MPC-distribution states
      trained on RANDOM actions    2.62
      trained on MPC actions       1.26

*** **TWICE AS ACCURATE WHERE IT MATTERS.** A model trained on random actions is accurate over
the random distribution - which contains a great deal of flailing a policy will never do, and
spends its capacity there instead of near the trajectory a controller actually follows.

* The MPC is random shooting over 8 steps with 24 samples on the TRUE dynamics - MPPI without
the importance weighting, the same family TD-MPC uses. Cheap enough to run inside a
data-generation loop, which is the whole point of it being an offline teacher.

### The caveat the numbers themselves forced

** **AT A LEARNING RATE OF 0.02 THE MPC MODEL DIVERGED TO NaN AND THE RANDOM ONE DID NOT.** The
expert's data is NARROWER, so the same step is effectively larger along the directions that
remain. Both rates were lowered together - changing one and not the other would have compared a
tuned model against an untuned one rather than two data sources.

* That is worth carrying forward: **expert-distribution data is not simply better-behaved data.**
It is lower-variance, which helps the model and hurts the optimiser, and a plan that swaps random
rollouts for MPC rollouts should expect to retune the learning rate rather than being surprised
by a divergence.

### A Zig bug worth naming

*** **STRUCT-LITERAL FIELDS EVALUATE IN ORDER, AND A GRAPH COPIED BEFORE ITS LOSS IS BUILT IS A
GRAPH WITHOUT ITS LOSS.** Writing `.graph = g` first and `.loss = try g.mseLoss(...)` last copies
the graph BEFORE `mseLoss` appends its nodes. The returned copy then indexes past the end of
`values` inside `backward` - **an out-of-bounds panic several hundred lines from the mistake,
with no stack pointing at the cause.** The loss is now built before the literal.

---

## 0e. THE TWO HALVES COMBINED, Sep 15

World model trained on MPC-distribution data per 0d, policy trained through it per 0c, and a
ZERO-FORCE baseline added because the earlier measurement could not distinguish learning from
the task's floor.

    zero-force (do nothing)   0.287
    untrained policy          0.257    11% better than nothing
    trained policy            0.190    34% better than nothing

*** **THE MIDDLE ROW IS WHY THE BASELINE WAS NEEDED.** An untrained network already beats doing
nothing by 11%, purely because its random outputs happen to damp the pole a little. **Measuring
against the starting loss alone credits that to learning.** Against the baseline the claim is
clean: training moved the policy from 11% to 34%.

* That is a criticism of my own earlier measurement, found by acting on the note the test itself
carried. The 0c version said "the next version should compare against a zero-force policy" and
this is it - **the note was worth writing because it was worth acting on.**

### The 0d finding reproduced itself immediately

** Applying MPC data to the miniature made the world model gate FAIL at the learning rate that
worked for random data, exactly as 0d predicted: expert data is narrower, so the same step is
effectively larger. Lowering it to 0.004 fixed it. **A finding that reproduces the first time it
is applied elsewhere is worth more than one that only held where it was found.**

### What remains before this scales to the humanoid

* **Adam, not SGD.** Still oscillating - 0.211 at 500 iterations, 0.254 at 2000. `adamStep`
exists and `stepParameters` is where it goes. Nothing here claims the loop is TUNED; it claims
the mechanism works.

* **`integrateRigidBodies` with quaternions.** The cartpole integration is `v += a*dt` on the
tape and works. The humanoid needs the rotation algebra, gradient-checked before anything uses
it - turn 14 of the plan, and now checkable against a loop that already trains.

* **The world model was trained ONCE and frozen.** SuperTrack trains both every iteration; this
isolated one to keep a failure unambiguous. Joint training is the next structural step and the
first place the chicken-and-egg problem in 7b/A5 can actually bite.

---

## 0f. STAGE 0 GROUNDWORK - the retarget chain, as it actually is, Sep 15

Surveyed the retargeting path before building anything, and it is much further along than the
plan assumed.

### What already exists and is tested

*** **`rbt.lafan_to_humanoid` IS A READY-MADE JOINT TABLE FOR THIS EXACT PAIR**, and
`robot_mjcf.zig` carries a test - "the real dance drives humanoid.xml" - that retargets
`dance1_20s.bvh` onto the humanoid and checks every joint. **The hard part of stage 0 is done
and was done by somebody who measured it.**

The proven chain, in order, because reconstructing it from the API names alone is a trap:

    rbt.resolveMatchTable          table + body names + human names -> human_of_body
    rbt.referenceOrientationsFromRest   the robot's T-pose, from its own rest
    codecs.bvh.parse(Geno_stance)  the HUMAN's T-pose, as a separate capture
    codecs.bvh.restAlignmentOffsets     the two T-poses -> per-body alignment
    -- then per frame --
    decode channels -> human_local -> compose up the tree -> human_global
    codecs.bvh.retargetRotations   -> robot_local, robot_global

** **THE REST ALIGNMENT IS NOT OPTIONAL AND NOT IDENTITY.** A first attempt at the tool used
identity, which would have produced a character moving plausibly and wrongly. The test's own
note says `humanoid.xml`'s `qpos0` is a T-pose and the human side needs a REAL T-pose too -
`assets/Geno_stance.bvh` - rather than a frame inferred from the dance.

### Status

Drafted at `src/notes/wip/retarget_clip.zig.wip` against this chain. **Read 0h before using it**
- the chain is right, its home is not, and the saving half turned out to be unnecessary.

---

## 0g. WHICH HUMANOID TO RETARGET ONTO - measured, Sep 15

The instinct was that `humanoid_flex.xml` should be reshaped closer to the LaFAN/Geno skeleton to
make retargeting easier. **Measured first, and the premise does not hold the way it looks.**

### The mapping is already complete on both models

    lafan_to_humanoid: 16 rows
      humanoid_flex    resolves 16/16   COMPLETE
      humanoid_flex2   resolves 16/16   COMPLETE

*** **THERE IS NO MISSING CORRESPONDENCE TO FIX.** Every limb, the torso, the pelvis and the head
all map. Reshaping the skeleton to match the BVH's NAMES or its tree would buy nothing the table
does not already provide, and `robot_mjcf.zig` has a passing test driving this exact capture
through it.

### What differs, and which difference actually matters

    humanoid_flex    16 bodies   0 ball  23 hinge   no toes
    humanoid_flex2   18 bodies   7 ball  16 hinge   toes

*** **BALL JOINTS ARE THE REAL DIFFERENCE, AND THEY MATTER FOR A SPECIFIC REASON.** A BVH gives a
full QUATERNION per joint. `humanoid_flex` receives that on skewed hinge pairs -
`axis="2 1 1"` and `axis="0 -1 1"` for the shoulder - so every retargeted rotation is PROJECTED
onto two non-orthogonal axes and the component outside their span is discarded. **A ball joint
takes the quaternion as it is.**

* So the change worth making is not reshaping the tree - it is **using `humanoid_flex2`**, which
already has 7 ball joints and toes, and which the same table already resolves completely. That is
a one-line change to which file the tool loads, not a modelling project.

### The tree inversion is real and is NOT a problem

Both models root at `torso` with the pelvis hanging below through `waist_lower`, while a BVH
roots at `Hips` with the spine going up. **The retarget works in GLOBAL space**, computing each
local rotation against whatever parent the ROBOT has - so the inversion needs no special case.
`robot.zig`'s own note says this, and adds that a local-rotation copy could not have done it at
all.

* **Re-rooting at the pelvis would therefore be a large, risky change - inertias, collision geoms,
the free joint - for a problem that is already solved.** Recorded so nobody spends a day on it.

### And what it costs, also measured

    5. humanoid_flex    nv 29    7666 ns/step   544x realtime
    6. humanoid_flex2   nv 43   14307 ns/step   291x realtime

** **1.9x THE COST FOR THE BALL JOINTS**, and `nv` goes 29 -> 43 because a ball joint is three
DOFs where a hinge is one. Both still contact-free (`nc 0`), so both are free-fall readings and
the note in the benchmark applies to each.

* **At 291x realtime that is still comfortably affordable.** One character produces roughly 4,400
control steps per second at 60 Hz with 4 substeps, so ten minutes on one core is 2.6M control
steps against a 600-frame clip - **over four thousand passes over the animation.** The fidelity
is worth the factor of two; collection was never the bottleneck (0b).

### What WOULD improve fidelity, in order

1. **`humanoid_flex2` over `humanoid_flex`** - ball joints where the capture gives quaternions.
   Free, already loadable, already mapped.
2. **More ball joints on the remaining hinge assemblies**, if fidelity is still short. The
   shoulder is the worst offender and the most visible in a dance.
3. **A neck joint.** `head` maps to `Head` but is welded in both models, so every head rotation
   in the capture is discarded. Cheap to add and visible.
4. **Spine subdivision.** The capture has Spine/Spine1/Spine2/Spine3; the robot has two segments.
   The most work and the least visible - do last, if at all.

---

## 0h. THE PRECOMPUTE WAS THE WRONG IDEA - retarget at startup, Sep 15

I spent two attempts building a tool to precompute and save the retargeted clip. **Both were
solving a problem that does not exist**, and Simon's instinct to just compute it at training
start is right for two reasons that only became clear after measuring.

### It is not slow

    600 frames x ~50 joints x ~60 ns  =  about 1.8 ms

* For comparison, one `humanoid_flex2` physics step costs 14.3 us, so **the entire retarget is
roughly 126 physics steps** - and a single pass over the 10-second clip is 2,400. The whole
precompute saves less time than four frames of simulation. **This was premature optimisation
against a cost nobody had measured, which is the same mistake the plan's own budget section
warns about.**

### And the module wall was self-inflicted

The tool could not reach `robot_mjcf.zig` because it is a FILE inside the `robot` module rather
than a module of its own - every route from `tools/` is closed:

    -Mrobot_mjcf=src/robot_mjcf.zig    ->  "file exists in modules 'robot' and 'robot_mjcf'"
    @import("robot_mjcf.zig")          ->  resolves to tools/robot_mjcf.zig
    @import("../src/robot_mjcf.zig")   ->  "import of file outside module path"

*** **BUT `zimr.zig` RE-EXPORTS IT AS `z.robot_mjcf`, AND `examples/catch` ALREADY USES IT.** An
EXAMPLE can reach the whole chain trivially. The wall only existed because I had decided the
precompute belonged in `tools/` before checking whether it needed to.

### What this changes

* No `ZRC1` format, no tool, no build step, no checked-in asset that can go stale against a
changed model. The example loads the BVH and the robot, runs the chain once at startup, and
holds the result in memory. **The simplest thing that works, and it was available from the
start.**

* The parked draft at `src/notes/wip/retarget_clip.zig.wip` still has the correct chain and the
correct model - it is the body of that startup function, minus the file writing.

* **The `tPoseGlobalRotations` change stays useful**: it is now `pub` so an example can call the
same T-pose reference the in-file test uses, rather than a second copy.

** **The habit worth fixing, since this is twice in one session:** both parked drafts were
written against an interface I had inferred rather than read. The measurements in this session
have been reliable because they were measurements; the code has been unreliable exactly where I
guessed. **Read the interface, then write against it** - it costs one grep and it has now cost
two rewrites.

---

## 0i. CORRECTING 0g, AND THE LAST MISSING PIECE, Sep 15

Two findings, one of which reverses a recommendation I made three sections ago.

### `humanoid_flex2`'s ball joints are on the WRONG joints

    ball  (7): knee_right ankle_right toe_joint_right knee_left ankle_left toe_joint_left
               elbow_right
    hinge (16): abdomen_z/y/x  hip_x/z/y (both)  shoulder1/2/3 (both)  elbow_left

*** **0g RECOMMENDED `humanoid_flex2` FOR ITS BALL JOINTS. THEY ARE ON KNEES, ANKLES AND TOES.**
A knee is anatomically ONE degree of freedom, so a ball joint there buys nothing a capture can
use and costs two extra DOFs. The joints where a full quaternion actually arrives - hip,
shoulder, abdomen - are still hinge chains in BOTH models.

** **AND THE SHOULDER AXES ARE IDENTICAL IN BOTH:** `axis="2 1 1"` and `axis="0 -1 1"`, skewed
and non-orthogonal. **The fidelity argument in 0g does not survive looking at which joints got
the ball treatment.**

* What `humanoid_flex2` still genuinely offers is TOES, which a dance capture has and which
matter for foot contact. That is a real reason to prefer it - just not the reason 0g gave, and
at 1.9x the step cost it is now a closer call than that section claimed.

* The hips are fine either way: `hip_x` is `1 0 0`, `hip_z` is `0 0 1`, `hip_y` is orthogonal to
both. **Three orthogonal hinges ARE a full rotation** - decomposable exactly, no information
lost. Only the shoulder's skewed pair is genuinely lossy.

### The last missing piece: rotations are not joint coordinates

*** **THE RETARGET PRODUCES LOCAL ROTATIONS PER BODY. PHYSICS NEEDS JOINT COORDINATES, AND
NOTHING CONVERTS BETWEEN THEM.** The passing test in `robot_mjcf.zig` stops at `robot_local` and
asserts the right bodies were fitted; it never drives a joint. `setJointPos` is scalar-only.

So stage 0 needs one function that does not exist:

    local rotation  ->  hinge chain angles   (decompose onto the axes, in order)
                    ->  ball joint quaternion (direct, modulo rest orientation)

* For three ORTHOGONAL hinges this is an Euler decomposition in the joint's own order and is
exact. For the skewed shoulder pair it is a projection and is lossy - **which is where the
fidelity is actually lost, and it is the same place in both models.**

** **This is the honest last gap for stage 0** and it is small, self-contained, and testable
without any learning: decompose a known rotation, recompose it, and check you get back what you
started with. **That round-trip test should exist before anything drives a character with it.**

---

## 0j. ALL BALL JOINTS - built and measured, Sep 15

`src/tests/fixtures/robot/humanoid_ball.xml`: **14 ball joints, zero hinges.** Generated from
`humanoid_flex2` by collapsing each hinge group into one ball - `abdomen_z/y` becomes `waist`,
`hip_x/z/y` becomes `hip_right`, `shoulder1/2/3` becomes `shoulder_right`.

*** **THIS DISSOLVES THE GAP 0i JUST IDENTIFIED.** A capture gives a full quaternion per joint
and a ball joint takes it directly, so **the decomposition function that would sit between the
retarget and the physics is no longer needed at all** - nor is the round-trip test for it, nor
the lossy projection onto the skewed shoulder axes.

    5. humanoid_flex     nv 29    9237 ns/step   451x realtime
    6. humanoid_flex2    nv 43   17164 ns/step   243x realtime
    7. humanoid_ball     nv 48   20307 ns/step   205x realtime

* **nv 43 -> 48, only five more DOFs**, because most of the hinge groups were already three
hinges - converting three hinges to one ball is DOF-neutral. The cost is 1.18x over flex2 and
2.2x over flex, and at 205x realtime it is still comfortably affordable.

### What going all-ball actually costs, stated rather than glossed

** **ANATOMICALLY WRONG: A KNEE DOES NOT SWIVEL.** That costs nothing for TRACKING, because the
reference clip only ever contains poses a real body made, so the extra freedoms are never
commanded. It costs something when the character has to stay plausible while FALLING - which is
exactly the regime a failing policy spends its time in.

** **THE HAMSTRING TENDONS ARE GONE.** A fixed tendon couples SCALAR joint coordinates - "hip_y
plus half of knee, limited" - and a ball joint has no scalar to couple. The biomechanical
coupling is removed with them, and the character can now bend a knee independently of its hip.

* **The joint limits went too.** Ball joints here carry no range, so nothing stops a limb
rotating through itself. For tracking a real capture that is invisible; for a ragdoll it is not.

** **All three of those point the same way: an all-ball model is right for getting tracking
WORKING and wrong for making a failure look like a body.** Which is the correct order - swap
hinges back in where the constraint earns its place, once there is something to constrain.

---

## 0k. STAGE 0 RUNS, Sep 15

`examples/dance_track` builds, passes smoke-test with physics running (~284 calls/frame), and
ships as a standalone page. **The whole chain works end to end for the first time:** the clip
retargets onto `humanoid_ball` at startup, its rotations become `PoseHold` targets, torque is
applied per substep, physics steps, and both characters draw.

### The panic was found by bisection, not by theory

Three turns of guessing what `RuntimeError: unreachable` meant produced nothing. Cutting the
frame function in half twice found it in minutes:

    setup + clip read only    PASS   ->  retarget and model are fine
    + PoseHold, no rbt.step   PASS   ->  the ball-joint torque path is fine
    + rbt.step                PASS   ->  ...and by then the conversions were fixed

*** **THE CULPRIT WAS A FLOAT-TO-INT CONVERSION, AND THE LINTER HAD BEEN POINTING AT IT.**
`@intFromFloat` is `unreachable` on a NaN or an out-of-range value, and the `int-from-float` rule
had been flagging every one of those sites while I looked elsewhere. Rewriting them as `@trunc`
and `@round` with the destination type pinned fixed the crash as a side effect of satisfying the
linter.

* **A lint rule that looks like style can be pointing at a crash.** The rule's text says
`@intFromFloat` is redundant when the type is already pinned; what it does not say, and what is
true, is that the redundant spelling is also the one that panics on a value the direct one
handles.

### What the example shows, and what it is for

No learning anywhere. The character is driven by the clip alone, which is DReCon's premise made
visible: open-loop playback should be NEARLY a working controller. **Whether it clears the
one-to-two-second bar in 8 is now a thing to look at rather than argue about**, and `kp`/`kv` are
on the State struct where they can be turned.

* The survival readout is on screen next to the playhead, so the stage-0 gate reads itself.

## 0l. THE FIRST DEVICE RUN FOUND A ZERO, Sep 15

The readout said **`kp 0  kv 0`**. There was no torque at all - the character was a limp ragdoll
drifting off the grid, and the doc comment above it promised two characters while only one was
drawn.

*** **`.memory = .managed` HANDS `init` A ZEROED STATE, SO STRUCT-FIELD DEFAULTS NEVER RUN.**
`kp: f32 = 400.0` on the declaration is not an initialiser here - it is a lie that reads like
one. Every field is now set explicitly in `initState`.

* **The panel is what caught it**, and it was added for a different reason. A number on screen
that disagrees with the source is worth more than any amount of reading the source, and this one
had been wrong since the example first compiled.

### What the panel does, and one decision inside it

Reset, pause, show/hide the reference, and live `kp`/`kv` sliders. The gains were borrowed from
the humanoid example, which tuned them for a STATIC pose - a moving reference is a different
problem and these are the first thing to turn.

** **THE RESET BUTTON SETS A FLAG RATHER THAN RESETTING.** The panel draws mid-frame, after the
physics has stepped and while the draw is in flight; rewriting `data.pos` there would put the
character somewhere the frame had already decided it was not. `update` consumes the flag at the
top of the next frame.

* The survival readout now states the stage-0 verdict in words - "TOO SHORT - check retarget or
gains" under 0.2 s, "clears the bar" past 1 s - **so the gate reads itself** rather than needing
someone to remember what the number means.

### The reference character draws by borrowing the model

One model, one `Data`: write the clip's rotations into `pos`, `forward`, draw, restore. It stands
1.2 m to the side, because overlapping ghosts read as one confused character and the GAP is the
tracking error.

** **THE RESTORE IS THE ONLY RISK.** Forgetting it would leave the simulation standing in the
reference's pose every frame - a character that tracks perfectly and is not being simulated at
all, which is the most flattering possible bug.

---

## 0m. WHY THE CHARACTER SLID AWAY - two bugs, one found, Sep 15

The device run showed the simulated character drifting sideways at constant height while the
reference danced correctly. Two causes, and a headless drop test in `robot-bench` now measures
both rather than needing a screenshot.

### Bug 1, FIXED: gravity was pulling sideways

*** **`Options.gravity` DEFAULTS TO `(0, -9.81, 0)` AND AN MJCF MODEL IS Z-UP.** zimr is Y-up
everywhere else, so the default is right for a hand-authored `Spec` and ninety degrees wrong for
anything imported. The character was not floating - it was falling, along its own horizontal.

* **`robot.zig`'s header says this explicitly**: "Imported scenes therefore set
`gravity = (0, 0, -9.81)`, and so do the Go1, humanoid, gripper and cartpole demos." A line of
documentation that was there the whole time and would have saved the run. Every working example
passes it; mine did not.

### Bug 2, DIAGNOSED NOT FIXED: there is no floor

    ragdoll drop: start z 1.282  final z -339.172  lowest -339.172  contacts 0/2000

** **THE CHARACTER FALLS THROUGH THE WORLD.** `robot_mjcf.zig` deliberately drops PLANE geoms -
"MJCF's ground plane belongs to the world", and an infinite plane would wreck a body's mass
properties. Replacing the plane with a static BOX did not help: probing the imported model shows
**zero geoms on body 0**, so worldbody geoms are not imported at all, not just planes.

* **That is consistent rather than broken.** `robot_mjcf` imports a ROBOT, and the ground is the
scene's business - which is why `examples/humanoid` builds a separate `zimrphysics` world with a
static ground box and bridges the robot into it, rather than expecting the MJCF floor to arrive.

* **So `dance_track` has the wrong architecture for contact**, and the fix is to follow the
humanoid example: a `zp.World` with a static ground, `bridge.sync` each step. Not a bug to hunt -
a component to add, and there is a working one to copy.

### The headless drop test is the lasting part

`robot-bench` now reports where the root ends up after 2000 steps and how many frames saw
contact. **A character that falls and lands is the cheapest possible proof that gravity, contact
and the solver are all working**, and it costs no screenshot, no device, and no eyes.

* It also caught that case 7 above runs with the WRONG gravity - the benchmark had been
reproducing the same bug silently, reporting `nc 0` and looking fine.

---

## 0n. THE PHYSICS WORKS - proven headlessly, Sep 15

    ragdoll drop: start z 1.282  final z -339.172  contacts 0/2000     no scene
    with ground:  final z  0.118  lowest  0.118   contacts 2000/2000   with a scene

*** **THE CHARACTER FALLS, LANDS, AND STAYS.** A `zimrphysics` world with a static ground box,
the robot mirrored into it by a `Bridge`, and contact forces returned through `harvest` - the
architecture `examples/humanoid` uses, now measured on `humanoid_ball` for 2000 steps. **Gravity,
contact, the bridge and the solver are all working**, and none of that needed a screenshot.

* `robot-bench` runs BOTH cases side by side, so the difference between them is the scene rather
than anything else. A single number would have said "it lands"; the pair says why the first one
did not.

### `harvest` panics in wasm and not native - isolated to one call

Bisected by staging every call in the loop. `forward`, `sync`, `zp.step`, `PoseHold.apply` and
`rbt.step` all run. **Turning `harvest` on, and nothing else, gives `RuntimeError: unreachable`.**

Ruled out, each by making the example match the benchmark exactly and re-running:

    the reference drawing borrowing `data.pos`      still panics
    the controller writing targets from the clip    still panics
    `max_contacts` at 512, then 32, then default    still panics
    `timestep` passed, then not passed              still panics
    world and bridge capacities 256, then 64        still panics
    several substeps per frame, then exactly one    still panics

*** **AND THE NATIVE RUN EXPLAINS WHY IT CANNOT REPRODUCE THERE:**

    with ground:  final z 0.118  contact 2000/2000  peak swept 0 of 32

**`swept_count` IS ALWAYS ZERO NATIVELY.** `harvest` is handed nothing to push, so it clears the
contact list and returns - it cannot hit `pushContact`'s assert because it never calls it. The
character still lands, which means the contacts reaching `rbt.step` arrive through the bridge's
LISTENER rather than through `swept`.

* So a native test of `harvest` would pass no matter how it were written, and the six rounds of
matching the example to the benchmark were matching the wrong thing. **The benchmark was never
exercising the code path that panics.**

### The instrumented page is the actual next measurement

The example now samples `bridge.swept_count` and `data.contacts.len` immediately BEFORE
`harvest` and shows both in the panel. **That turns "it panicked" into "it was asked for N slots
and has M"** - and if N exceeds M the fix is a line, while if N is zero the panic is somewhere
else in `harvest` entirely.

### The invisible panel was TWO bugs, and a known-good demo found both

Building `quadruped-standalone` as a baseline settled in one build what three device runs could
not.

*** **`ui_host.begin` BUILDS THE PANEL AND `ui_host.render` DRAWS IT.** The first version called
`begin` and every widget and never called `render`, so the panel was assembled each frame and
thrown away. **Nothing appeared and nothing errored** - every widget "worked", they simply had no
output.

** **AND `z.endDrawing` MUST NOT BE CALLED BY THE EXAMPLE.** `quadruped` does not call it; the
runtime closes the frame after `update` returns. Calling it explicitly ran the deferred
`ui_host.render` AFTER the frame had ended, which panicked - so adding the missing `render` broke
the example until the extra `endDrawing` came out.

* **Two bugs whose symptoms cancelled**: without `render` the panel was silently absent, and the
moment `render` arrived the stray `endDrawing` turned silence into a crash. Either alone would
have been obvious; together they looked like the panel simply not working.

* **`harvest` still panics independently** with both fixed, which is worth knowing - it is a real
second fault rather than a consequence of the drawing order, and the panel can now report the
contact numbers that will name it.

---

## 0o. A CUBE ON A FLOOR SETTLES IT, Sep 15

Simon's suggestion, and the right one - before believing anything about a nineteen-body
character, ask whether ONE box falls onto ONE floor.

    cube drop:    start z 1.000  final z 0.200  contact 904/1000   peak swept 0
    with ground:  humanoid       final z 0.118  contact 2000/2000  peak swept 0
    ragdoll drop: humanoid, no scene              z -339.172       contact 0/2000

*** **THE BRIDGE WORKS.** A cube dropped from 1 m comes to rest at exactly 0.200 - its own
half-extent - and is in contact for 904 of 1000 frames. So `zimrphysics`, the ground, the
`Bridge` and the contact path are all correct, and every humanoid failure so far has been about
something else.

** **AND `peak swept` IS ZERO IN ALL THREE.** Contacts reach `rbt.step` through the bridge's
LISTENER, not through `harvest`'s swept array - so `harvest` is not the mechanism that catches
the character, and the wasm panic in it is a side issue rather than the blocker it looked like
for three turns. The panel confirms the same zero on device.

### The cube test found the SAME bug a third time

** **`rbt.Spec` ALSO DEFAULTS TO Y-DOWN GRAVITY**, and the first version of this test used it.
The cube fell along Y, never met the floor at z = -0.5, and reported a final z of exactly 1.000 -
**because z was never the falling axis.**

* That is the third appearance of this one default: `Options.gravity` for the imported humanoid
(0m), benchmark case 7 silently (0n), and now a hand-authored `Spec`. **A cube that does not move
at all is obvious in a way a drifting character is not** - which is the entire argument for
testing the smallest thing first.

* The ground is now DRAWN in the example too. It is a static box in the physics world with no
geom in the robot model, so `drawRobot` could not see it - **and a floor nobody can see is
indistinguishable from no floor**, which is how this looked for three device runs.

---

## 0p. *** STAGE 0 PASSES: 9.00 SECONDS OF OPEN-LOOP TRACKING, Sep 15

    18 bodies   48 DOF   15 ball joints
    clip 9.00s / 9.98s   frame 540 of 599
    survived 9.00s   clears the bar
    contacts: swept 1   capacity 32

*** **THE PREMISE HOLDS, AND BY A MARGIN NOBODY EXPECTED.** The plan's bar was one to two
seconds - DReCon's "not sufficient for maintained balance, but comes close". **Open-loop playback
of the retargeted clip through PD control survives nine seconds of a ten-second dance**, with no
learning anywhere.

** That changes what the learning has to do. The plan assumed a policy would be rescuing a
character that falls almost immediately; instead it is correcting the last second of a run that
is already nearly right. **A residual that small is a much easier function to learn** than the
one stage 0 was written to expect - which is the argument DReCon makes for offsetting a
near-working controller rather than replacing it.

* `swept 1` rather than 0: contacts ARE flowing through the bridge now that gravity is on the
correct axis. The earlier zeros were a character falling sideways forever, never meeting a floor.

### And the elliptical bands were a mesh-axis bug

** **`genMeshCylinder(r=1, h=1)` SPANS y IN [0, 1] AND x, z IN [-1, 1]** - Y-axis and
BASE-anchored, not centred. Scaling it as `(radius, radius, length)` and skipping the offset
stretches every capsule across the wrong axis from the wrong origin, which is what the bands
were. The fix is a translate of `-half_height` along Y and a scale of
`(radius, 2*half_height, radius)`.

* `examples/humanoid` carries this with a note saying the extents were MEASURED rather than
derived, and that a previous version there read the UV helper, concluded Z, and rotated by ninety
degrees it did not need. **Two people have now got this wrong the same way.**

* The `else` branch of the shape switch now draws a small red sphere instead of nothing. **An
invisible geom is indistinguishable from an absent one** - the same lesson the missing floor
taught over three device runs, applied preemptively this time.

---

## 0q. THE CONTACT BUDGET, AND WHAT THE `harvest` PANIC IS NOT, Sep 15

### `harvest` pushes from TWO arrays, and the panel was showing one

    with ground:  contact 2000/2000  peak swept 0 + events 45 of 256

*** **`swept` AND `events` ARE SEPARATE, AND `pushContact`'s ASSERT MEASURES THEIR SUM.** The
example's panel reported only `swept` - which sits at 1 or 2 - and hid the array that actually
fills. A humanoid lying on a floor peaks at **45 events**.

** **AND THE DEFAULT `max_contacts` IS 32.** Natively that SATURATED at exactly 32 of 32 - one
more contact and the assert fires. **A budget sized for a quadruped's four feet is not sized for
a character that falls over**, and the native run was silently clipping contacts rather than
reporting it.

* Raised to 256 in both the benchmark and the example. The native humanoid then lands at
z = 0.131 with 45 peak events and contact on every frame.

### What the wasm panic is NOT

** The example now GUARDS the call - `if (swept + events <= capacity)` - and **it still panics**.
So the overflow assert is not what is firing, and four turns of reasoning about contact counts
were aimed at the wrong thing. The bound is now sharp:

    not the architecture      a cube falls and rests at 0.200, 904/1000 frames in contact
    not the model             the same humanoid lands natively at z = 0.131
    not the contact budget    raised to 256, and the guard skips rather than overflows
    not the draw order        `render`/`endDrawing` fixed separately, panel works
    only in wasm              the identical sequence runs 2000 iterations natively

* The example ships with `harvest` off, so the character is clip-driven and falls THROUGH the
floor - visibly wrong rather than quietly broken. `overflow frames` is on the panel for when it
goes back on.

* **The floor is now light enough to see.** It was drawn at r40 g44 b52 against a r22 g24 b30
background - present, and invisible, which is the third time that exact mistake has cost a device
run in this file.

---

## 0r. CONTACT OWNERSHIP - a review, Sep 15

Surveyed after four turns of chasing a contact bug that kept moving. The bug was hard to find
because the design makes it hard to find, and that is worth writing down separately from the bug.

### Finding 1: the receiving buffer is smaller than what can be sent

    bridge.swept   = alloc(SweptHit, model.ngeom)            21 for humanoid_ball
    bridge.events  = alloc(Event, model.opt.max_contacts)    32 by default
    Data.contacts  = alloc(Contact, m.opt.max_contacts)      32 by default

*** **`harvest` PUSHES `swept + events` INTO `contacts`, AND THOSE THREE ARE SIZED BY TWO
DIFFERENT QUANTITIES.** Worst case is `ngeom + max_contacts` = 53 into a buffer of 32.
**Overflow is guaranteed by construction rather than by load** - raising `max_contacts` raises
both the sender and the receiver together and never closes the gap, which is why 256 did not fix
anything.

* **FIXED**: `Data.contacts` is now `alloc(max_contacts + ngeom)`, with the reasoning written
into the allocation itself. The suite stays green.

** **AND IT DID NOT FIX THE WASM PANIC**, which is worth stating plainly - a latent bug found
while looking for a different one, and the two were never the same. The panic survives a
correctly sized buffer, a guard that skips when the sum would overflow, and a 256-contact
budget.

### Finding 2: the buffer has three fill APIs and no owner

    setContacts    "Replace the whole contact set. The usual call from a collision bridge."
    clearContacts  + pushContact, incremental
    pushContact    alone, appending to whatever was there

** **THE DOC NAMES `setContacts` AS THE BRIDGE PATH, AND THE BRIDGE DOES NOT USE IT.** `harvest`
calls `clearContacts` then `pushContact` in two loops - the incremental path, which is the only
one carrying an overflow assert. The documented contract and the only implementation of it
disagree.

* Five files write this buffer: `robot.zig`, `robot_bench.zig`, `robot_scene.zig`,
`robot_physics.zig`, `robot_control.zig`. **Nothing enforces clear-before-push**, so a caller who
forgets accumulates silently across steps and a caller who clears twice loses a frame's contacts.

### Finding 3: `robot.zig` detects no collisions at all

There is no broadphase, no narrowphase, no `collide` in the file. `Data.contacts` is an INPUT -
the solver consumes what someone else computed. That is a clean design and it is nowhere stated;
both times this cost a device run, the confusion was expecting `rbt.step` to find the floor.

* One sentence in `Data.contacts`'s doc comment - "the solver never fills this; a bridge does" -
would have saved both.

### Debugging aids worth building, in order of payoff

1. *** **A `contactSummary(data)` that returns counts, the min and max penetration, and how many
   bodies are involved.** Every debugging turn in this file began by wanting exactly that and
   ending up printing fields by hand. It belongs next to the buffer.

2. ** **Make the overflow an ERROR, not an assert.** `harvest` returning
   `error.ContactBufferFull` lets a caller decide; an assert in wasm is a bare `unreachable`
   with no stack, which is what made four turns expensive.

3. ** **`Bridge.expectedContactCapacity(model)`** - one function returning the number
   `max_contacts` must be for this model, so a caller can size it correctly instead of guessing
   and finding out by crashing.

4. * **Draw the contacts.** A dot per contact point with its normal, in `dance_track`. Contacts
   are the only part of this pipeline with no visual at all, and every other invisible thing in
   this file took three device runs to notice.

5. * **A `sources` field on `Contact`** saying which system pushed it. With five writers and one
   buffer, "who put this here" is currently unanswerable.

---

## 0s. TWO ENGINE BUGS FIXED, PANIC NARROWED TO ONE LOOP, Sep 15

### Fixed 1: the swept array had no bounds check

    events:  if (self.event_count >= self.events.len) return;   guarded
    swept:   self.swept[self.swept_count] = ...;                 NOT guarded

*** **ONE OF THE TWO ARRAYS WAS WRITTEN WITH A GUARD AND THE OTHER WITHOUT**, which is what an
oversight looks like rather than a decision. `swept` is `alloc(SweptHit, model.ngeom)` - a
heuristic, since a geom that moves far enough in one step can sweep against several others - so
overrunning it was an out-of-bounds WRITE into whatever follows the allocation.

* Dropping the hit is the right failure: a missed contact is a character that sinks slightly, a
corrupted heap is anything at all.

### Fixed 2: `Data.contacts` was smaller than what a bridge can send

Now `alloc(max_contacts + ngeom)`. See 0r - the three arrays were sized by two different
quantities and the receiver was the smaller.

### The panic is in the EVENTS loop, not the swept loop

Narrowed by gating `harvest` on `event_count == 0`:

    harvest with events empty     PASS
    harvest with events present   RuntimeError

** So `clearContacts`, `tangentFrame`, `pushContact` and the whole swept loop are fine - the
fault is in the second loop's fields. The one thing it touches that the swept loop does not is
**`data.cvel[event.robot_body]`**, inside `speculativeMargin`.

* `cvel` is `alloc(Motion, nbody)` and `world_body` is 0, so a world contact indexes 0 legally -
**that was the obvious candidate and it is ruled out.** What remains is `contactSoftness`,
`speculativeMargin`'s arithmetic, or an `event.robot_body` that is neither a body index nor the
world sentinel.

** **Neither of the two bugs fixed above was the panic**, and both were found by looking at the
system rather than at the symptom. That is the argument for the 0r review: **the symptom moved
six times and the structure did not.**

---

## 0t. THE BUG, THE FIX, AND HOW TO MAKE THE CLASS IMPOSSIBLE, Sep 15

### What it was

    @intCast(contact.id & 0xFFFF_FFFF_FFFF)     into  constraintKey(source: usize, ...)

*** **`usize` IS 64 BITS NATIVELY AND 32 ON WASM.** The bridge packs the other body's index at
bit 40, which the 48-bit mask keeps - and that field is ZERO for every contact against the world.
So every floor contact worked, and **the first time the character touched ITSELF the page died**.
A humanoid mid-dance does that constantly.

Six turns of bisection. The panic named itself in one build once a handler existed.

### The two fixes, and the second is the real one

1. **A panic handler, now in `example_common`.** A wasm safety trap is a bare
   `RuntimeError: unreachable` with no message. One line per example -
   `pub const panic = std.debug.FullPanic(common.reportPanic)` - and the message reaches the
   console. **This should have existed before any of this work started.**

2. *** **AN ID IS NOT A SIZE.** `constraintKey` took `source: usize`. `usize` means "big enough
   to index this machine's memory"; a contact id is a semantic value whose width has nothing to
   do with the address space. Now `source: u64`, with the 48-bit mask derived once as
   `source_mask` beside the packing that reserves it. **The cast is gone entirely** - there is
   nothing left to overflow.

### Making the class harder, ranked by what would have caught THIS one

1. *** **BAN `usize` FOR NON-INDEX VALUES, BY LINT.** Every id, key, hash, handle and packed
   field typed `usize` is this bug waiting. The rule is mechanical: a parameter named `id`,
   `key`, `hash`, `handle`, `source` or `mask` may not be `usize`. **This one rule catches the
   bug at its cause rather than its symptom.**

2. ** **A COMPTIME WIDTH ASSERTION WHEREVER A LITERAL MASK MEETS A PLATFORM TYPE.**
   `comptime assert(@bitSizeOf(usize) >= 48)` would have failed the wasm BUILD rather than the
   run. Cheap, and it turns "works on my machine" into a compile error on the machine where it
   does not.

3. ** **DERIVE MASKS, NEVER SPELL THEM.** `0xFFFF_FFFF_FFFF` appearing 400 lines from the
   packing that reserves 48 bits is two facts that can drift apart, and they did. One
   `source_mask` constant next to the shift makes them one fact.

4. ** **RUN THE TEST SUITE ON wasm32.** The real gap is that `test-fast` is native-only, so a
   32-bit `usize` is never exercised. Even a SUBSET of tests under `-target wasm32-freestanding`
   would have caught this and every future member of the family. **This is the highest-leverage
   item on the list and the most work.**

5. * **Make wasm-only differences a checklist rather than a surprise.** `usize` width, pointer
   size, `@intCast` traps, no stack traces, different float determinism. A short doc in
   `claude.md` beats rediscovering each one.

* Items 1 and 2 are afternoons. Item 4 is the one that would make the whole class impossible, and
it is worth scoping properly rather than doing badly.

---

## 0u. THE PREVENTION IDEAS, MEASURED - and two of three were not worth doing, Sep 15

Measured before building, and the measurement changed the answer.

### Idea 1, the `usize`-for-ids lint rule: NOT WORTH ADDING

    all usize params named like ids            86
    minus idx / *_index / *_count / *_len       2
    of those 2, actually indices                2

** **THE RULE WOULD FIRE TWO FALSE POSITIVES AND ZERO TRUE ONES.** Both remaining hits are
locals in `zimrphysics2d` used to index a list - correct `usize` by definition. **A lint rule
whose only output is noise trains people to ignore lint output**, which costs more than the bug
it was meant to catch.

### Idea 3, deriving masks instead of spelling them: ALREADY DONE, NOTHING LEFT

    hex literals 9+ digits, anywhere in src/    43
    of those, near a `usize`                     1
    that one, `0xdead_beef`, fits in 32 bits     yes

* **The bug was a singleton.** The one spelled mask that met a platform type has been replaced by
`source_mask`, derived beside the packing that reserves it. There is no second instance to fix,
so a general rule has nothing to act on.

### Idea 2, comptime width assertions: NO REMAINING SITE

The one place it was needed is now `source: u64` and cannot overflow by construction. An
assertion guarding an impossible case is a comment that costs a build.

### What the measurement DID justify: the panic handler, everywhere it matters

*** Added to **21 physics-touching examples** - `example_common` is wired into every example
automatically by `build.zig`, so the import is free and the change is two lines per file.

*** **AND IT IMMEDIATELY FOUND A SECOND BUG: `examples/quadruped` PANICS IN `control` AND HAS
BEEN DOING SO SILENTLY.** Verified pre-existing by commenting the handler out and re-running -
still panics, just without saying so. **The quadruped demo was shipped as a known-good baseline
earlier in this very session**, and it was broken the whole time.

* That is the entire argument for the handler in one example: it did not fix anything, it made
an existing failure audible, and the failure had survived a full gate.

---

## 0v. STAGE 0 RE-MEASURED WITH A FLOOR: 0.5 SECONDS, NOT 9, Sep 15

*** **THE 9.00s IN 0p WAS MEASURED WHILE THE CHARACTER WAS FALLING THROUGH THE FLOOR.** It
reported nine seconds because nothing was there to fall onto - a number that looked like a pass
and measured nothing. **A gate that can pass for the wrong reason is worse than no gate**, and
this one did.

Now measured headlessly, in `robot_control.zig`, with a real ground:

    kp   100  kv 10  ->  0.38s        kp   400  kv 40  ->  0.45s
    kp   200  kv 10  ->  0.42s        kp   800  kv 40  ->  0.47s
    kp   400  kv 10  ->  0.38s        kp  1500  kv 40  ->  0.50s
    kp   200  kv 20  ->  0.47s
    kp   400  kv 20  ->  0.38s        best: 0.50s of 10.00s
    kp   800  kv 20  ->  0.48s

### The sweep is FLAT, and that is the finding

** **0.38s TO 0.50s ACROSS A FIFTEEN-FOLD RANGE OF `kp`.** Gains are not the limiting factor -
which rules out the first thing anyone would try and the thing the panel sliders were built for.
**A flat sweep is worth more than a good result**: it says stop tuning.

* Reference state initialisation was added while doing this - the first version started the
character in its T-POSE while the target was the clip's frame 0, so the controller crossed that
whole gap in one step. **That is a shove at t = 0 with nothing to do with whether the clip is
trackable.** Fixing it made the number slightly WORSE, which is its own small result.

### So DReCon's premise does not hold on this setup

** Their claim is that open-loop playback "comes close" to maintained balance. **Half a second is
not close.** The plan's bar was one to two seconds and its escape hatch (7b/A7) says: three turns
without clearing it means the rig is the problem, not the learner.

* The two most likely causes, both self-inflicted and both recorded earlier:
  1. **The root is not driven at all.** `PoseHold` acts on ball joints; the free joint has no
     controller, so the torso's global orientation is purely ballistic. A character whose torso
     cannot resist toppling will topple.
  2. **The all-ball model has no joint limits and no hamstring tendons** - 0j said plainly that
     this is "right for getting tracking working and wrong for making a failure look like a
     body". A knee that bends backwards does not catch a fall.

* Cause 1 is the one to test first: it is a property of the CONTROLLER rather than the model, and
DReCon's own controller is joint-space PD plus contact - so if a free root is enough to explain
half a second, that is a correctable design gap rather than a modelling one.

---

## 0w. MuJoCo'S BALL-JOINT MATH FIXES STAGE 0: 0.50s -> 1.63s, Sep 15

Read MuJoCo's source for how it actuates ball joints. The actuator itself is not what we want -
`mjTRN_JOINT` on a ball gives a ONE-dimensional actuator whose `gear` is a 3-vector selecting a
fixed axis, and `length = dot(quat2Vel(q), gearAxis)`. A tracking controller needs a 3-DOF
orientation servo, which MuJoCo expresses through its joint SPRING rather than an actuator.

**The spring is the thing to copy**, and reading it found two real bugs in ours.

### Bug 1: the axis was not a unit vector, so the gain vanished with the error

    zimr:    quatToAxisAngle -> axis = raw xyz, angle = 2*acos(w)
    MuJoCo:  quat2Vel        -> axis = xyz NORMALIZED, angle = 2*atan2(|xyz|, w)

*** **THE RAW `xyz` HAS LENGTH `sin(theta/2)`, NOT ONE.** So `axis * angle` gave
`sin(theta/2) * theta` where it should give `theta` - near the target that is QUADRATICALLY too
small. **The controller was weakest exactly where it needed to be most precise, and no amount of
raising `kp` fixes a gain that vanishes with the error.** That is why the first sweep was flat
across a fifteen-fold `kp` range: the gain was being multiplied by zero as the error closed.

* `atan2` over `acos` is the second half of it - `acos` loses precision near `w = 1`, the
small-angle case a servo lives in.

### Bug 2: the error was in the wrong frame

    ours:    target * conj(current)      the error in the WORLD frame
    MuJoCo:  conj(target) * current      the error in the TARGET's frame

** A ball joint's velocity coordinates live in the joint's own frame, so the torque must too.
The two forms agree only when the parent is unrotated - which for a root-adjacent joint is
nearly true and for a wrist is not at all.

### The result

    before:  0.38 - 0.50s, FLAT across kp 100..1500
    after:   0.13 - 1.63s, and the best is 1.63s at kp 500, kv 20

*** **STAGE 0 CLEARS THE PLAN'S ONE-SECOND BAR.** And the sweep is no longer flat, which is the
corroborating detail: with a correct error magnitude, gains matter again. A flat sweep was never
"gains do not help" - it was "the gain is being cancelled".

* 500/20 sits at the EDGE of the swept range, so the true optimum is probably higher and this is
a lower bound rather than a tuned result.

### What came across, as named primitives

`zm.quat2Vel` and `zm.subQuat`, matching `mju_quat2Vel` and `mju_subQuat` including the
normalize-first and the wrap-past-pi handling. **Named after their originals on purpose** - the
next person comparing against MuJoCo should be able to find them.

---

## 0w. THE BALL-JOINT CONTROLLER: THREE BUGS, ONE STILL OPEN, Sep 15

### Bug 1, the big one: ball joints were never powered

    Actuation.init:  .hinge, .slide => powered = true
                     .free,  .ball  => {}

*** **`humanoid_ball` IS ENTIRELY BALL JOINTS, SO NOTHING WAS POWERED AND `PoseHold.apply`
SKIPPED EVERY JOINT.** The panel showed `kp 400` and the character was limp - healthy gains,
zero torque. Simon spotted it from the screen: "even with ragdoll not checked there is no
torque."

* The original note said a ball joint "cannot be driven by a scalar torque", which was TRUE
until `PoseHold` learned to drive one with a rotation error. **The premise changed and the switch
did not follow.** Ball joints are powered now; a free joint still is not, and that part stands -
a floating base has no motor.

** **This also explains the flat sweep in 0v.** Gains looked irrelevant because they WERE
irrelevant: nothing was using them. A flat sweep meant "not connected", not "not the bottleneck",
and reading it as the latter cost a turn.

### Bug 2: the axis from `quatToAxisAngle` is not a unit vector

    pub fn quatToAxisAngle(q, axis, angle) { axis.* = q; angle.* = 2*acos(q[3]); }

** The raw `xyz` has magnitude `sin(theta/2)`, so `axis * angle` gives `sin(theta/2)*theta`
rather than `theta` - **quadratically too weak near the target**, which is exactly where a
tracking controller should be precise.

* `zm.quat2Vel` and `zm.subQuat` already existed for this, written as MuJoCo's `mju_quat2Vel`
with a doc comment naming this trap. **The correct function was there and the wrong one was
easier to find.**

### Bug 3: the error was computed in the wrong frame

`subQuat(a, b)` is the rotation carrying `b` to `a` **in b's frame**, and its doc says outright
that the frame is the easy part to get wrong. A joint's DOFs live in the CURRENT frame, so
`current` must be the second argument. Now `subQuat(want, current)` with `+kp`, matching
MuJoCo's `mju_subQuat(res, qdes, qpos)`.

### Where the number stands, and one thing unexplained

    best: 0.75s of 10.00s at kp 800 / kv 40

* The 5.00s recorded mid-session was measured with bug 2 present - the `sin(theta/2)` scaling
made the controller gentle near the target and relatively stronger far from it, a nonlinearity
that happened to help. **A good number from a buggy formula is not a result**, and it went away
when the formula was fixed.

** **UNEXPLAINED: fixing bug 3 changed nothing - all nine sweep rows are bit-identical before
and after.** The edit is in the file. Either the two frames genuinely coincide for these errors,
or the rebuild served a stale binary. **Worth resolving before trusting the next reading**, and
recorded rather than glossed.

---

## 0x. ROOT MOTION - the reference was dancing in a phone booth, Sep 15

    root X:  -81.6 .. 151.2   travel 232.8 cm
    root Y:   53.1 ..  82.8   travel  29.8 cm  (up)
    root Z:  359.4 .. 471.5   travel 112.1 cm

    horizontal travel over 10 s: 2.58 m

*** **THE CLIP TRAVELS TWO AND A HALF METRES AND NONE OF IT WAS BEING USED.**
`retargetRotations` handles ORIENTATIONS and says nothing about where the character is; the root
translation lives in the BVH's first three channels and was decoded by nothing. The reference
performed a travelling dance on the spot.

* Only the root carries position channels - every other joint is pure rotation about its parent's
offset - so reading them costs one `switch` inside the walk that was already happening.

### Two conversions, both properties of THIS clip

    centimetres -> metres    this capture's offsets run to the hundreds (root at 179, 82, 332)
    Y-up -> Z-up             a BVH is Y-up; an MJCF model is Z-up, so the last two swap

* Neither is a property of the FORMAT - a BVH may be authored in any unit - so they are written
at the point of use rather than buried in a helper, where the next capture that disagrees would
be hard to find.

** **AND THE REFERENCE IS POSITIONED RELATIVE TO ITS OWN FIRST FRAME.** This capture's root
begins at (1.79, 3.32, 0.83) metres - wherever the mocap studio's origin happened to be - which
would have put the reference off screen entirely. Subtracting frame 0 puts it beside the ragdoll
and lets the two be compared.

* The camera now frames both and pulls back to 14 m, because a pair that starts 1.2 m apart and
travels 2.58 m does not stay in a 3-metre orbit.

---

## 0y. *** STAGE 0 PASSES FOR REAL: 10.00s OF 10.00s, Sep 15

    kp   100  kv  10  ->   0.37s        kp   800  kv  40  ->  10.00s
    kp   200  kv  20  ->   0.43s        kp   800  kv  60  ->   0.82s
    kp   400  kv  20  ->   1.13s        kp  1500  kv  60  ->   1.98s
    kp   400  kv  40  ->   0.17s        kp  2500  kv  80  ->   9.07s
                                        kp  4000  kv 100  ->   0.17s

*** **OPEN-LOOP PLAYBACK SURVIVES THE ENTIRE CLIP.** With a real floor, real contacts, a working
ball-joint controller and the root's orientation initialised from the clip. DReCon's premise -
that this "comes close" to maintained balance - **holds on this rig**, and every learned method
downstream can be a correction to something that nearly works.

### The last missing piece was the ROOT's orientation

** `torso` is the robot's root and carries a FREE joint, so a loop that writes only ball joints
left it at whatever `qpos0` held. The character therefore started **facing the wrong way** while
the clip's limbs moved as if it faced the right way - a yaw shove at t = 0 that had nothing to do
with tracking.

* The same omission made the kinematic reference dance with a FROZEN TORSO: limbs moving
correctly around a trunk that never turned. **One bug, two symptoms** - Simon saw both ("the
kinematic guy is not moving correctly", "the ragdoll explodes") and they had a single cause.

* Only the reference uses the root rotation as a target. The simulated character's root stays
unactuated on purpose: a floating base has no motor, and driving it would be cheating.

### The landscape is sharp, and that is the honest caveat

** **0.17s at 400/40, 10.00s at 800/40, 1.98s at 1500/60.** Neighbouring settings differ by two
orders of magnitude. The controller works and is **not robust** - which is exactly the gap a
learned correction exists to close, and a reason not to read 10.00s as "solved".

### Where the plan stands

* Stage 0 is done, and the numbers that matter are now headless: one `zig build test-fast`
prints the sweep, so the next question costs a build rather than a device run.

* Next is the plan's turn 5 in earnest - record the two BASELINES (open-loop survival AND
tracking error, plus the zero-policy floor) so that a learner has something to beat that is not
its own first guess.

---

## 0z. THE KINEMATIC REFERENCE WAS ROUND-TRIPPING THROUGH JOINT COORDINATES, Sep 15

Simon: "We never got good retargetting on the ball joint version of the robot. We had a good
result on humanoid.xml and humanoid_flex.xml." Correct, and the reason is in how the result was
CONSUMED rather than in the retarget.

### What `geno_dance` does, and what this did

    geno_dance:   retargetRotations -> local rotations -> bvhForwardKinematicsFromRotations
    dance_track:  retargetRotations -> local rotations -> write ball qpos -> rbt.forward

*** **THE SECOND PATH ASSUMES A BALL JOINT'S qpos IS THE BODY'S LOCAL ROTATION**, which holds
only if the joint frame and the body frame coincide. `geno_dance`'s retarget is visibly correct
and it never makes that assumption - it runs forward kinematics on the rotations DIRECTLY.

** The reference is now drawn from the retarget's own GLOBAL rotations, walking the body tree
with the model's offsets. **A bad reference now means a bad retarget rather than a bad
conversion**, and those are very different things to fix.

* It also borrows nothing: no writing into `data.pos`, no `forward`, no restore. That removes a
whole class of bug rather than guarding against it - the old version's restore was the single
most dangerous line in the file.

### The disagreement that matters more than either number

** **THE HEADLESS SWEEP REACHED 10.00s AT kp 800 / kv 40. ON THE DEVICE THAT EXPLODES**, and
Simon needed 84 / 3.4 to calm it. Two measurements of the same controller disagreeing by an order
of magnitude in gain means **one of them is not measuring what it claims**, and averaging them
would hide it.

* Most likely suspects, in order: the example runs several substeps per frame at a
frame-rate-dependent count while the test runs exactly four; the example's `dt` comes from the
browser and the test's is fixed; the example applies `PoseHold` once per substep and the test
does too, but after a `harvest` that may differ in contact count. **All three are testable
headlessly**, which is where to do it.

* Defaulted to the gentler pair so the page is watchable while that is resolved.

---

## 0aa. NOBODY HAS EVER VALIDATED SKELETON -> ROBOT POSE, Sep 15

Went looking for the proven path Simon remembered. It is proven for something else.

    geno_dance:  jnt_qpos_adr appears ONCE, and it writes the ROOT POSITION
                 the dancing figure is a SKELETON, posed by bvhForwardKinematicsFromRotations
                 the robot is loaded, and its rest pose is recorded - not animated from the clip

    robot_mjcf:  "the real dance drives humanoid.xml" checks that the right BODIES were FITTED
                 it stops at `robot_local` and never drives a joint

*** **SO THE GOOD RESULT ON `humanoid.xml` IS A SKELETON RESULT AND A NUMERIC ONE.** The step
that turns retargeted rotations into a posed ROBOT has never been done anywhere in this codebase
before `dance_track`, on any model. **It is not that the ball-joint version broke something that
worked - it is that nothing worked yet**, and the earlier models were never asked to.

* That reframes every attempt in the last several turns. "Why is it worse on `humanoid_ball`"
was the wrong question; the right one is "what does it take to pose a robot from a retarget at
all", and the answer is not written down because nobody has needed it.

### What that means for the reference

** Drawing from the retarget's GLOBAL rotations (0z) is still the right move - it is what
`geno_dance` effectively does for its skeleton, and it removes the qpos round trip. If the
character is STILL wrong after that, then the globals themselves are wrong for this model, and
the suspect is `humanoid_ball.xml` - **a file generated by a script that collapsed hinge groups,
whose rest pose feeds `referenceOrientationsFromRest` and therefore the whole alignment.**

* The cheapest next test is to draw the reference from the retarget onto `humanoid_flex2` - the
model `geno_dance` loads and the one the match table was written against - and see whether the
same drawing code produces a correct figure. **That separates "my drawing is wrong" from "my
model is wrong" in one build**, and both have been suspects for three turns.

---

## 0ab. THREE CHARACTERS, ONE OF THEM A CONTROL, Sep 15

`dance_track` now draws three figures side by side:

    origin   blue    RAGDOLL            physics, PD-driven from the clip
    1.2 m    pale    ROBOT REFERENCE    retarget -> global rotations -> tree walk
    2.4 m    orange  CAPTURE SKELETON   the BVH's own offsets and rotations, NO retarget

*** **THE THIRD ONE SHARES NOTHING WITH THE OTHER TWO.** No match table, no rest alignment, no
robot model, no `resolveMatchTable` - offsets and rotations straight from the file, posed by one
forward pass. It is what `geno_dance` draws and what is visibly correct there.

** **That makes it a CONTROL rather than a third thing to look at.** The comparison it enables:

    capture dances, robot reference does not  ->  the retarget or the model it targets
    NEITHER dances                            ->  upstream of both, in how the clip is read
    both dance, ragdoll falls                 ->  stage 0 is honest and the controller is next

* The middle outcome would be the most useful, because it is ONE bug rather than two - and it is
the one nobody has checked, since every previous test of this clip went through the retarget.

* Three turns have gone to "the kinematic guy is wrong" without being able to say whether the
fault was in reading the clip, retargeting it, or drawing the result. **This tells them apart by
looking**, which is what should have been built the first time the question came up.

---

## 0ac. HIPS ON THE FLOOR: the height was being subtracted away, Sep 15

    root height over the clip:  0.531 .. 0.828 m   (mean 0.684)
    what the code displayed:    0.000 throughout

*** **BOTH REFERENCE CHARACTERS SUBTRACTED THE WHOLE ROOT POSITION, INCLUDING HEIGHT.** The
skeleton then performed the dance with its pelvis dragging along the floor - every joint angle
correct, the whole figure sunk into the ground. Simon: "Hips stuck on ground."

* The reasoning behind the subtraction was sound and over-applied. The clip's ORIGIN is wherever
the mocap studio put it - this one starts at (1.79, 3.32) horizontally - so re-origining is
necessary or the character is off screen. **But the height is not arbitrary**: 0.53 to 0.83 m is
where this performer's hips actually were, including a real crouch-and-rise, and it is the one
component that must survive untouched.

    horizontal  re-origin to frame 0     arbitrary, studio-dependent
    vertical    keep absolute            physical, and the floor is at zero

** **THE SAME BUG WAS IN BOTH CHARACTERS** - the capture skeleton and the robot reference were
written a turn apart, and the second inherited the first's mistake because it copied the
"relative to frame 0" idea wholesale rather than the reasoning behind it. **A shortcut copied
without its argument is a bug copied with it.**

---

## 0ad. THE FRAMES WERE MIXED - a Z-up offset rotated by a Y-up rotation, Sep 15

Compared line by line against `draw3d.bvhForwardKinematicsFromRotations`, as Simon asked. **The
recurrence is identical:**

    root:   pos = root_translation                       rot = local[root]
    child:  pos = parent_pos + rotate(parent_rot, off)   rot = qmul(parent_rot, local)

*** **SO THE ALGORITHM WAS NEVER THE DIFFERENCE. THE FRAMES WERE.** My version converted each
offset to metres and Z-up, then rotated it by `human_global` - which is built from the BVH's own
Euler channels and lives in the BVH's Y-UP frame. **Rotating a Z-up vector by a Y-up rotation is
not a small error; it is a different animation**, and it produced a sprawling figure with nothing
in common with the dance.

* The proven function does not have this problem because its offsets and rotations were loaded
into the SAME space by the same loader. It never converts mid-walk because it never has two
spaces to be between.

### The fix is a rule, not a patch

    the whole walk stays in BVH space         raw units, Y-up, offsets and rotations agreeing
    convert ONCE, at the point of use         the skeleton to draw, the reference to metres Z-up

** The root track is now kept RAW as well. Converting it at load forced one of its two consumers
to convert back - and a value that gets converted, unconverted and reconverted is a value whose
frame nobody can state. **Keep source data in source units; convert where it is used.**

* Verified rather than assumed: the longest bone segment is 0.399 m, which is a thigh. Units are
centimetres and 0.01 is the right factor.

---

## 0ae. BACK TO `humanoid_flex`, WITH HINGE DECOMPOSITION, Sep 15

Simon's call, and the right one: retarget onto the model the match table was written against, and
drive the ragdoll toward it.

*** **THE ALL-BALL MODEL WAS BUILT TO AVOID A DECOMPOSITION THAT TURNS OUT TO BE EASY.** Its whole
justification was that a retargeted quaternion could be written straight into a joint - and it
never produced a correct pose, because posing a robot from a retarget had never worked on ANY
model (0aa). The ball version was not a regression from a working thing; it was the first
attempt, and it removed joint limits and tendons to buy something that was not needed.

### Sequential axis projection

For a hinge with axis `a`, the angle reproducing a rotation `q` about it is the swing-twist
twist: `2 * atan2(dot(q.xyz, a), q.w)`. **Verified: exact on-axis, and correctly zero for a
rotation about a perpendicular axis.**

For a chain - `abdomen_z` then `abdomen_y`, or three shoulder hinges - each joint takes the twist
about its own axis and passes the REMAINDER on, in the model's own joint order.

** **ONE DECOMPOSITION PER BODY, NOT PER JOINT.** A body's hinges share one rotation, so walking
joints and decomposing each in isolation would give every hinge in a chain the FULL rotation
about its own axis - three joints each doing the whole job, which is three times too much. The
peeling only means anything with all of a body's axes in view.

* **It is lossy where the axes are not orthogonal**, and `humanoid_flex`'s shoulder pair
(`2 1 1` and `0 -1 1`) is exactly that case. The residual is what the retarget cannot express on
this skeleton - **a property of the MODEL, not of the decomposition**, and worth remembering when
the shoulders look wrong.

---

## 0af. `solvePointCloud` IS THE MECHANISM, AND IT ALREADY EXISTS, Sep 15

Looked again at how `geno_dance` drives its robot, as Simon asked. It does not write joint angles
at all.

    robot_tasks: []z.robot.IkTask
    z.robot.solvePointCloud(model, data, samples, opts)

*** **IT SOLVES INVERSE KINEMATICS AGAINST A POINT CLOUD OF THE RETARGETED SKELETON**, and the
function's own doc says what it replaced: "ONE SOLVE, REPLACING SIX SEQUENTIAL MECHANISMS. No
masks, no sequence, no rest-pose algebra, no aim rule, no bend-plane rule, no hinge formula."

** **MY `hingeAnglesFromLocal` IS THE "hinge formula" THAT SENTENCE SAYS WAS REPLACED.** I wrote
a sequential axis decomposition in the last turn, complete with a note about it being lossy on
non-orthogonal axes - rediscovering, badly, a problem this codebase had already solved properly.
**The answer to "how do I pose a robot from a capture" was a function call.**

### What it takes, and it is small

    refreshPointSamples       23 lines   body + local point + which human joint it tracks
    buildRetargetedSkeleton   48 lines   target positions per body
    rootBodyWorldPosition     17 lines   where the root goes

* Plus `PointCloudOptions`, whose defaults do the hard parts: `posture_weight` keeps redundant
DOF still between frames, `limit_barrier` makes a joint limit a SLOPE rather than a cliff, and
`previous_qpos` warm-starts from the last frame so the solve is continuous.

### And this gives the ragdoll its targets

** The solved `data.pos` IS a full set of joint angles, consistent with the model's limits and
its kinematics - **exactly what a PD controller wants and exactly what the decomposition was
trying to produce**. Kinematic robot follows the capture by IK; ragdoll follows the kinematic
robot by PD. That is Simon's design and it has one mechanism per step rather than one per
guess.

* Fixed in passing: the panel said "24 ball joints" for a model with none - it was printing
`njnt`. **A label that contradicts the model it describes is worse than no label**, because it
gets read as information.

---

## 0ag. THE IK PATH IS WIRED - `solvePointCloud` drives the kinematic robot, Sep 15

`dance_track` now reproduces `geno_dance`'s mechanism:

    buildPointSamples    body + local point + which human joint it tracks
    buildRetargetedSkeleton  target body positions: HUMAN directions, ROBOT bone lengths
    solvePointCloud      one IK solve -> a full set of joint angles
    PD                   the ragdoll follows those angles

*** **THE HAND-ROLLED DECOMPOSITION IS GONE.** `solvePointCloud`'s doc says it replaced "six
sequential mechanisms ... no hinge formula", and the thing written two turns ago WAS that hinge
formula. Deleting it is the change; the rest is wiring.

** **THE SOLVED POSE IS REACHABLE BY CONSTRUCTION** - it obeys the model's limits and its
kinematics, so the PD target is something the robot can actually adopt. A per-axis projection
could never promise that: it produced angles that happened to be numbers.

### Two details that are not obvious and cost a build each

* **The lengths come from the ROBOT and the directions from the HUMAN.** A capture's limbs are
whatever length that performer had, so copying positions would stretch the robot. Copying only
the direction keeps its proportions and asks the solve for the closest reachable pose.

* **`previous_qpos` makes the solve continuous.** Without it every frame starts from scratch and
a redundant DOF can flip between two equally good answers - which reads as a limb snapping
rather than as an IK problem.

### The panic handler paid for itself again

** The first attempt sized the IK scratch by guessing `8 * nv + 64`. It panicked inside
`robot.ikStep`, **the handler named the function in one build**, and `ikScratchSize(nv)` turned
out to exist. Before the handler existed this was a bare `unreachable` and cost six turns; this
time it cost one.

---

## 0ah. THE SOLVE WAS RUNNING AND NOTHING WAS READING IT, Sep 15

Verified line by line, as Simon asked. Two lines were missing and they were the two that mattered.

    solvePointCloud(m, &kin_data, ...)     writes kin_data.pos AND NOTHING ELSE
    rbt.forward(m, &kin_data)              MISSING - body transforms never updated
    drawReference read clip_global         WRONG SOURCE - the raw retarget, not the solve

*** **A SOLVE WHOSE RESULT IS NEVER READ IS A SOLVE THAT MAY AS WELL NOT RUN.** The IK ran every
frame, wrote a correct set of joint angles, and the pale character on screen was still being
drawn from the retarget's raw global rotations by a hand-written tree walk. **It looked like the
IK was failing when it was being ignored.**

* `solvePointCloud` writes `pos` only. Body transforms stay whatever the last `forward` left -
or the REST POSE for ever, if `forward` was never called. Nothing errors; the drawing is simply
of a different pose than the one that was solved.

### The reference now draws the same geoms as the ragdoll

** Both read `m.geom_*` and differ only in which `Data` supplies the transforms. **So any
difference between them is the PHYSICS**, which is the entire reason for drawing them side by
side - and while one was drawn from a hand walk and the other from the solver, that comparison
meant nothing.

* Three pieces of state died with the change: `clip_global`, `ref_pos` and `scratch_pos` all
existed only to feed the hand-rolled drawing. **The version that reads the solve needs none of
them** - including the `scratch_pos` save-and-restore that was the most dangerous line in the
file.

---

## 0ai. GEOMS FLYING INTO THE DISTANCE: a hundred-fold scale error, Sep 15

    robot body offsets:   0.108 .. 1.282 m
    human bones, raw:     2.6   .. 39.9  cm
    what the solve saw:   human targets in CENTIMETRES against a robot in METRES

*** **THE IK WAS ASKED TO REACH TARGETS A HUNDRED TIMES TOO FAR AWAY**, and it flew off trying.
Simon: "geoms flying, exploding and glitching in the distance" - which is what a solver does with
an unreachable target, not a failure of the solver.

* The cause is 0ad's rule applied and then not finished. `human_points` is kept in BVH space -
centimetres, Y-up - because the SKELETON DRAWING wants it raw, and that was right. But the solve
is a second consumer wanting a different space, and it was handed the raw buffer.

    skeleton drawing   BVH space, raw            converts as it draws
    IK solve           metres, Z-up              NOW converts before solving
    rest pose          metres, Z-up              same - it is compared against robot rest

** **THE REST POSE NEEDED IT TOO, AND THAT IS THE SUBTLER HALF.** `buildPointSamples` compares
the human rest positions against the ROBOT's rest positions to decide where a sample sits on a
body. In centimetres, every sample lands a hundred times too far from the body it belongs to -
**the samples would have been wrong even after the per-frame targets were fixed.**

* "Convert at the point of use" means EVERY point of use. The rule was right and applying it to
one of three consumers is how a rule becomes a bug.

---

## 0aj. THE FIGURE WAS BURIED, SO THE RAGDOLL LAUNCHED, Sep 15

The IK poses correctly now and the whole figure sat in the ground - so the ragdoll, initialised
from that pose, popped out of the floor on its first step and flew.

*** **THE FK WALK STARTS ITS ROOT AT THE ORIGIN.** Every point it produces is RELATIVE to the
hips, by design - that is what let the skeleton be drawn anywhere. Handing those to the IK put
the pelvis at z = 0 and the legs through the floor, and a physics solver asked to resolve a
character intersecting the ground answers with a large upward impulse. **The explosion was the
correct response to the pose it was given.**

    horizontal   re-origin to frame 0    the studio's origin is arbitrary
    vertical     keep absolute           0.53 to 0.83 m is where the hips were

** **THAT IS THE THIRD PLACE THIS RULE HAS HAD TO BE STATED** - the capture skeleton (0ac), the
robot reference (0ac), and now the IK targets. Each consumer re-derives it, and each one got it
wrong the first time. **A rule restated three times is a function that should exist**, and if
there is a fourth consumer it should take one.

### And the panel now shows both root heights

* `reference` and `ragdoll`, side by side. **A reference root at 0.00 means the IK targets lost
their world position**, which is the failure above - visible without rotating the camera, and
the kind of number that would have turned this turn into a glance.

---

## 0ak. SUSPEND IT AND MEASURE THE TRACKING, Sep 15

Simon's call: forget balance, hang the ragdoll from a hook, and measure max joint error.

*** **EVERY SURVIVAL NUMBER SO FAR MEASURED BALANCE AND TRACKING TOGETHER, AND BALANCE
DOMINATED.** The run ended before the tracking had said anything - 0.3 seconds of data about a
ten-second question. Suspended, gravity and contact stop mattering and the only thing left is
whether the PD reaches the angles the IK solved.

    hook          the root's three TRANSLATIONAL DOFs, pulled to a fixed point
    free          the three rotational ones, so it can still swing and twist
    metric        max over hinges of |target angle - current angle|

** **THE ROTATIONAL DOFS ARE LEFT FREE ON PURPOSE.** Driving them too would CLAMP the character
rather than hang it, and a clamped root hides exactly the errors this exists to expose - a limb
swinging wrong shows up as the torso reacting, and a bolted torso cannot.

** **MAX, NOT MEAN.** A mean over twenty-four joints hides one limb being completely wrong behind
twenty-three being fine - and one wrong limb is what a viewer sees. The max says how bad the
worst joint is, which is the honest summary of whether a pose is tracked.

* The panel reports the worst joint's INDEX and which body it belongs to. Joint names are
comptime-only on `Spec`-built models and an imported one carries body names but not joint ones,
so "joint 7 on thigh_right" is as specific as this model allows.

### Why this matters for the plan

* **This is the first number that will still mean the same thing once learning exists.** Survival
time is about a controller AND a character AND a floor; max joint error is about the controller
alone. A learned correction's whole job is to make it smaller, and until now there was nothing
for it to be smaller than.

---

## 0al. 596 DEGREES OF JOINT ERROR, AND A HARD PIN, Sep 15

    max joint error 10.402 rad (596.0 deg)

*** **THAT IS NOT A TRACKING ERROR, IT IS A CHARACTER SPINNING FREELY.** A hinge cannot be six
hundred degrees from its target in any meaningful sense - the number says the ragdoll's joints
had wound past full turns while the soft hook pulled at its middle. **A spring hook measures a
tug of war, not tracking.**

** A flailing character generates forces that overwhelm any finite stiffness, so the hook was
never going to hold it. Raising the stiffness would have been the obvious next move and the wrong
one: a stiffer spring is still a spring, and the thing being measured would still have been the
contest between it and the controller.

### So: a constraint

    pin_root    write the root's qpos and zero its velocity, AFTER each step

* **Position AND orientation, which the hook deliberately left free.** The hook exists to watch
the character move; the pin exists to measure whether it tracks. **With the base completely
immobile, every remaining degree of freedom is a joint and every error is the controller's.**

* Applied after `rbt.step` rather than before. Doing it first would let the step move the root
again and the pin would lag a frame - visible as a character jittering against its own
constraint.

* Both are checkboxes and both can be off. The three modes answer different questions: free =
does it balance, hook = does it move plausibly, pin = does it track.

---

## 0am. THE PIN, LOWERED - and a default I nearly changed by mistake, Sep 15

* **The pin now sits beside the kinematic robot at its own height**, not three metres up. The
whole value of pinning is that the two poses can be read against each other, which needs them
close and level - at three metres the character was above the framing and the comparison was
impossible by eye.

### `scale_by_inertia` is right in principle and made the measurement worse

Chasing "following does not work well", the obvious suspect was that `PoseHold.scale_by_inertia`
DEFAULTS TO FALSE - so a heavy thigh and a light forearm get the same `kp`, the forearm
oscillates at a stiffness the thigh barely notices, and no single gain tracks both.
`examples/humanoid`'s own note says it "removes the inertia dependence", turning `kp` into
frequency units. `examples/gripper` sets it.

*** **SO I TURNED IT ON, AND STANDING SURVIVAL FELL FROM 10.00s TO 0.53s.** The gains that
BALANCE are in torque units; changing the units moves the good region, and the sweep was
searching the old one.

** **A DEFAULT THAT MAKES THE ONE NUMBER YOU CAN MEASURE WORSE IS NOT A FIX**, however good the
argument for it. It is a toggle in `dance_track` now and off in the headless sweep, with the
measurement written beside both - because the two regimes genuinely want different numbers and
picking one silently would have buried that.

* Worth trying WITH the pin on: balance is out of the picture there, so frequency units may well
track better even though they balance worse. **That is a real experiment and it is now one
checkbox**, where before it would have been a rebuild and a guess.

---

## 0an. ONE ELBOW, ROOT PINNED, AND THE SERVO STILL DOES NOT HOLD, Sep 15

Simon's suggestion: debug headless, one joint, everything else frozen. It worked - the problem is
now isolated to something much smaller than a dancing character.

    one elbow, target -1.00 rad from 0, root pinned every step, 2 s, settled error:

      kp  100  kv 10  inertia off  ->  0.854 rad  (48.9 deg)
      kp  400  kv 20  inertia off  ->  1.336 rad  (76.5 deg)
      kp  800  kv 40  inertia off  ->  0.932 rad  (53.4 deg)
      kp  100  kv 10  inertia ON   ->  1.488 rad  (85.2 deg)
      kp  400  kv 20  inertia ON   ->  1.549 rad  (88.7 deg)

*** **A SINGLE JOINT, WITH NO BALANCE, NO CONTACT AND NO CLIP, CANNOT HOLD A TARGET ONE RADIAN
AWAY - AT ANY GAIN.** The target is well inside the elbow's declared limit of [-2.62, 0.35]. This
is not tuning and it is not the dance: **the servo itself does not work**, and every number in
this file that depended on it has been measuring that.

** **AND GAIN DOES NOT MONOTONICALLY HELP** - 100 is better than 400, which is worse than 800.
A correct PD improves with stiffness until it destabilises; a landscape that wanders like this
says the error is not a stiffness error at all.

* Ruled out on the way: **all 24 hinges are limited, none unlimited**, so the 1825-degree reading
was not a joint free to wind. And `applied_force` IS consumed - `d.acc[i] = applied_force[i] +
actuator_force[i] + passive_force[i]` - so the torque is reaching the dynamics.

* **A bug in the test, not the servo, found on the way:** pinning the root by writing qpos
without calling `forward` leaves the mass matrix stale, and `scale_by_inertia` reads
`massDiagonal` from it. That crashed rather than lying, which is the good failure.

### Where to look next

* The two suspects the measurement leaves standing:

  1. **`bias_force` inside the clamp.** `PoseHold` adds gravity compensation and the solver's
     `acc` does not include `bias_force` - so if the sign or the frame is off, the controller is
     fighting gravity rather than cancelling it, and more gain makes the fight worse.
  2. **The rotation-error path itself.** 0w corrected the frame from `subQuat(current, want)` to
     `subQuat(want, current)` and the numbers did not move - which was flagged unexplained then
     and is still unexplained now.

* **This test is the right place to answer both**: one joint, deterministic, two seconds, and a
number that should be near zero. **Anything that fixes the servo will show here first.**

---

## 0ao. THE SERVO OSCILLATES, AND THE QUADRUPED'S DOES TOO, Sep 15

Compared against the working demo, as Simon asked, and the comparison was decisive in a way I did
not expect.

    kp  100  PoseHold    -> 0.854 rad error, ended at -1.494
    kp  400  PoseHold    -> 1.336 rad error, ended at -0.524
    kp  800  PoseHold    -> 0.932 rad error, ended at -1.494
    kp  100  QUADRUPED   -> 2.102 rad error
    kp  400  QUADRUPED   -> 1.842 rad error
    kp  800  QUADRUPED   -> 1.861 rad error

    goal -1.00, elbow limit [-2.62 .. 0.35]

*** **`examples/quadruped`'s OWN SERVO, INLINED, IS EQUALLY BAD.** It stands a Go1 successfully
and it cannot hold this elbow either. **So the fault is not in `PoseHold`** - not the bias
placement, not the clamp, not the rotation-error path. Two independent implementations failing
identically points at what they share: the rig, the model, or the integrator.

** **AND IT IS OSCILLATING, NOT FAILING.** Ending at -1.494 and -0.524 about a goal of -1.0 is a
swing of roughly plus or minus half a radian around the RIGHT value, inside the joint's limits.
**The direction is correct and the magnitude is correct; only the settling is not.** That rules
out sign errors, frame errors and limit violations in one measurement - which is three of the
suspects this file has been carrying.

* The quadruped's servo differs from `PoseHold` in exactly one way - it adds `bias_force` OUTSIDE
the clamp where `PoseHold` adds it inside - and `PoseHold`'s own comment records that the outside
placement was a BUG fixed earlier, measured at 1589 Nm on an arm rated 400. The comparison
confirms that fix was right and is not what is wrong now.

### What is left

* Two candidates, both shared by the two implementations:

  1. **The arm is a pendulum and only the elbow is damped.** Every joint is PD-held, so a
     shoulder that oscillates swings the whole arm and the elbow angle rides along. The test
     drives ONE joint away from rest but holds all of them, so this is testable by freezing the
     shoulders outright.
  2. **The integrator at `dt = 1/240` with these stiffnesses.** `examples/humanoid`'s own note
     says its stiff end "outruns the timestep and throws the robot" - the same failure, and it
     found the band by experiment rather than by analysis.

* **The elbow rig answers both cheaply** and is now in `robot_control.zig` with the quadruped's
servo alongside `PoseHold` as a control. Whatever fixes one should fix both, and if a change
helps only `PoseHold` it is probably not the real fix.

---

## 0ao. *** THE TIMESTEP WAS THE BUG. THE SERVO WAS ALWAYS CORRECT, Sep 15

    elbow oscillation amplitude, last second of ten:

      gains      240 Hz    2000 Hz    improvement
      kp 100      0.308      0.014          22x
      kp 400      1.770      0.004         442x
      kp 800      1.102      0.002         551x

    and the elbow lands on -0.998 against a goal of -1.000.

*** **A PD WITH POSITIVE DAMPING CANNOT SUSTAIN A LIMIT CYCLE UNLESS ENERGY IS INJECTED, AND AN
EXPLICIT INTEGRATOR INJECTS IT WHEN THE STEP IS LONG RELATIVE TO THE STIFFNESS.** The default
`timestep = 1/240` was too coarse for these gains, and everything downstream inherited it.

** **AND NOW MORE GAIN IS BETTER** - 100 -> 0.014, 400 -> 0.004, 800 -> 0.002 - which is what a
correct PD does. At 240 Hz the landscape wandered (100 better than 400, worse than 800), and 0an
read that as "the error is not a stiffness error at all". **It was a stiffness error; the
instability threshold was just below the useful gains.**

### What this explains, retroactively

* Every strange servo number in this file has one cause:

    1825 deg of joint error            a joint oscillating through many turns
    gain not monotonically helping     stiffer controller destabilises sooner at a fixed step
    "ragdoll shaking uncontrollably"   the limit cycle, seen
    inertia scaling making it worse    it raises effective stiffness, so it destabilises earlier
    both PD implementations failing    neither was wrong; the integrator was

** **THE LOST TURN'S FINDING WAS RIGHT AND ITS CONCLUSION WAS WRONG.** It measured the
quadruped's servo as equally bad and concluded "it is not the controller" - correct. The next
inference should have been "then it is the thing BOTH controllers sit on", and that is the
integrator.

### What to change

* `dance_track` runs `sim_dt = 1/240` with 4 substeps. **The fix is a smaller substep, not a
gentler gain** - and a gentler gain was exactly the workaround applied three times in this file.

* Cost: at 1/2000 a ten-second clip is 20,000 steps against 2,400. The humanoid measured 8.9
us/step contact-free, so a pass costs about 0.18 s of compute rather than 0.02 - **still four
thousand passes in ten minutes**, and 0b already established collection is not the bottleneck.

---

## 0ap. A FIXED 60 Hz CLOCK, AND THE `<exclude>` GAP, Sep 15

### The simulation no longer sees frame time

*** **THE OLD LOOP DERIVED ITS SUBSTEP COUNT FROM `delta_time`**, so the physics ran a different
number of steps every frame and a different number again on a slow device. **That is why the
headless sweep and the phone disagreed by an order of magnitude in gain** (0z) - they were never
running the same simulation, and no amount of comparing them could have been meaningful.

    control_dt              1/60, fixed - the clip's rate and the policy's rate
    substeps_per_control    33, a CONSTANT (2000/60), not a device property
    accumulator             real time in, whole control steps out

** **THE CAP IS ON STEPS PER FRAME, NOT ON `dt`.** A backgrounded tab drops its backlog and
carries on - visibly a skip. Clamping `dt` instead would let the physics take one enormous step,
which is the classic way to destroy a simulation on a hitch, and the old loop did exactly that.

* A number from the device is now comparable to a number from a test, which it has not been at
any point in this file.

### `<exclude>` is in the MJCF and nothing reads it

** `humanoid_flex.xml` excludes `waist_lower` from both thighs, and **`src/mjcf.zig` has no
`exclude` handling at all** - the word does not appear. So those pairs collide in the physics
world whenever they touch.

* Measured at rest: centres 0.228 m apart against a radii sum of 0.120 m, so they are CLEAR when
standing. **The exclusion matters during motion** - a thigh raised toward the waist - which is
most of a dance and none of a rest pose. Simon's suspicion was right and the rest-pose check was
the wrong place to look for it.

* The fix is an importer change: parse `<contact><exclude>` into pairs and hand them to the
bridge, which already filters same and adjacent bodies via `sameOrAdjacentWeld` and would just
need the explicit list too. **Not done - recorded with the measurement, because it is engine
work and the fixed clock had to land first.**

---

## 0aq. 18.5 RADIANS - AND I STILL HAD NOT MEASURED WHICH SIDE, Sep 15

    max joint error 18.501 rad (1060 deg)

*** **2.9 FULL TURNS, ON A HINGE LIMITED TO +/-2.62 RAD.** Either the IK produced an angle
outside the limit or the simulated joint wound past it - and **three turns have gone by without
measuring which**, because `|target - pos|` cannot say. That is a failure of instrumentation, not
of analysis, and it is the same shape as the contact bug where the panel showed `swept` and hid
`events`.

** The panel now reports **both maxima against the widest declared limit**: `max |angle|: target
X   sim Y   widest limit Z`. One glance answers it, where three turns of reasoning did not.

### What the code says so far

* **`PointCloudOptions.limit_barrier` DEFAULTS TO 1.0**, so the IK is already limit-aware - the
barrier adds `w*(1/(q-lo) - 1/(hi-q))` to the gradient and its doc says the solver "slides ALONG
the limit and can always back out". So the target should be in range, which points at the
SIMULATION as the wild side.

* Added anyway: **the target is clamped to each joint's range.** It should be a no-op given the
barrier, and it is there because "should be" is not "is". **It cannot mask the opposite failure**
- a sim joint that has escaped still shows a large error and the new panel line still says so.

### The thing I should have built first

** Every bug in this file that took more than one turn took it for the same reason: **a number
that summarised two possibilities into one figure.** Survival mixed balance with tracking. Joint
error mixed target with sim. Contacts showed swept and hid events. **The fix each time was to
split the number, and each time it was cheaper than the turn that preceded it.**

---

## 0ar. *** A WIN: ONE ELBOW TRACKS A MOVING TARGET TO 9 DEGREES, Sep 15

Simon's design: freeze every bone but the right arm, servo the elbow, limit velocities, watch
what the motor does. A 0.5 Hz sine inside the joint's own range rather than the clip - no
retarget, no IK, no contact to blame.

       kp   err deg   torque Nm
      100      18.4         1.8
      200      13.9         2.1
      400       9.3         2.6
      600       9.3         2.6
      800       9.2         2.6
     1200       9.2         2.9
     1600       9.2      1000.0   <-- the ceiling, a 345-fold jump

*** **THE SERVO WORKS.** Nine degrees of tracking error on a moving target, at 2.6 Nm. After many
turns of an exploding ragdoll, one joint asked to follow something does follow it.

** **AND IT EXONERATES THE EXAMPLE'S GAINS.** `dance_track` runs kp 800: 9.2 degrees, 2.6 Nm,
nowhere near the cliff. **So the explosion is not the elbow servo and not the stiffness** - it is
something that only appears with all joints driven together, which is a much smaller search than
"the controller is wrong somewhere".

### Three things the numbers say that guessing did not

* **The error PLATEAUS at 9.2 degrees from kp 400 upward.** More gain buys nothing, so the
residual is not a stiffness limit - it is PHASE LAG on a moving target, which is exactly the
quantity a feed-forward or learned correction reduces and a P gain cannot.

* **`max_torque` defaults to 1000 and the jump to it is a cliff, not a slope** - 2.9 Nm at kp
1200, saturated at 1600. A clipped PD is bang-bang: slam, overshoot, slam back. **That is what
shaking looks like when it happens**, and it is worth knowing the edge sits just above the useful
range.

* **A velocity ceiling changed nothing** at any gain that was not already saturated. It cannot
make a wrong controller right - it can only stop a diverging one reaching infinity, which is the
difference between a readable number and a NaN.

### And multi-joint coupling is cleared too

    unfreezing progressively, elbow -> -1.00 rad, kp 800 kv 40:
      round 0:  2 bodies free  ->  elbow err 0.0019 rad  SETTLED
      round 1:  4 bodies free  ->  elbow err 0.0017 rad  SETTLED
      round 2:  6 bodies free  ->  elbow err 0.0019 rad  SETTLED
      round 3: 10 bodies free  ->  elbow err 0.0019 rad  SETTLED

*** **TEN FREE BODIES AND THE ELBOW STILL SETTLES TO TWO THOUSANDTHS OF A RADIAN.** Suspect 1
below - "all joints at once" - is wrong. Adding bodies does not degrade it at all, so the shared
mass matrix and the joints fighting each other are not the mechanism.

** **THAT LEAVES ONLY WHAT THE FULL EXAMPLE HAS AND THESE TESTS DO NOT**: contacts, a free root,
and IK-derived targets that move every frame. Three candidates instead of the whole controller,
and each is separately testable in the same rig.

### Where to look next, now that the servo is cleared

* The remaining candidates, in order of how much the measurement narrows them:

  1. **`<exclude>` not imported** (0ap) - `waist_lower` against both thighs, clear at rest and
     colliding through a dance. **Now the leading suspect**, because it is present in the
     example and absent from every test that passes.
  2. **The root.** The one body with no target, and its reaction to twenty-four driven joints has
     never been measured. The progressive test froze it throughout.
  3. **IK targets that move every frame.** The sine was smooth by construction; a solve that
     jumps between two equally good poses on adjacent frames would look exactly like shaking,
     and `previous_qpos` is the only thing preventing it.

---

## 0as. VERIFYING THE JOINT MATH - three numbers that decide it, Sep 15

With the servo cleared (0ar) the remaining suspects are all about the TARGET rather than the
controller, so the panel now measures the target. Three lines, each answering one suspect.

    IK residual X m on BODY          converged / NOT CONVERGING
    target jump/frame X rad          smooth / NOT SMOOTH
    max |angle| target / sim / limit

### 1. Does the solve reach its own targets?

*** **THE JOINT MATH HAS NEVER BEEN VERIFIED, ONLY ASSUMED.** `solvePointCloud` is given target
body positions and returns a pose; whether that pose PUTS THE BODIES THERE is a separate
question, and the answer decides whether the PD is chasing the dance or chasing whatever the IK
settled for.

* A residual of a centimetre or two is a skeleton that cannot quite reach - fine, expected, and
the reason `buildRetargetedSkeleton` copies directions rather than positions. **Tens of
centimetres means the solve is not converging** and the target has little to do with the clip.

### 2. Is the target smooth?

** **A SOLVE THAT FLIPS BETWEEN TWO EQUALLY GOOD POSES ON ADJACENT FRAMES HANDS THE PD A STEP
INPUT SIXTY TIMES A SECOND** - indistinguishable from shaking, and nothing to do with stiffness.
0ar showed one elbow follows a SMOOTH sine to 9 degrees; it says nothing about a target that
jumps. A dance should not turn any joint much past 0.1 rad per frame at 60 fps. **`previous_qpos`
is the only thing preventing the flip and nobody has checked that it does.**

### 3. And gentler gains, per Simon

* Default now kp 100 / kv 10, and the slider reaches down to 10. Measured in 0ar: 18.4 degrees
of tracking at kp 100 against 9.2 at kp 800 - **half the accuracy for a controller that can be
looked at**, and since 9.2 is a plateau the gap between 100 and 800 is smaller than the gap
between watchable and not.

* Every gain in this file has been chosen from above. "Reduce stiffness until it stops exploding"
needs a range that goes low enough to find out where that is, and 0-to-1500 with a default of 800
never did.

---

## 0. The two papers in one paragraph each

**DReCon (Bergamin et al. 2019).** A kinematic controller plays motion capture and hands its
joint angles to the physics engine as open-loop PD targets. That alone falls over. A policy
trained with PPO adds small *corrective offsets* to a subset of those targets, and that is
enough to keep the character upright. The policy is tiny - 2 layers of 128 - because it is only
learning the correction, not the motion.

**SuperTrack (Fussell et al. 2021).** Train a *world model* to predict the physics, then train
the policy by BACKPROPAGATING THE TRACKING LOSS THROUGH IT. No reward, no advantage, no PPO -
the world model is a differentiable stand-in for the simulator, so the policy is optimised by
supervised learning. Both networks train together from one shared buffer.

*** **THE SECOND IS THE ONE THAT CAN HIT TEN MINUTES, AND THE FIRST IS THE ONE THAT PROVES THE
RIG.** SuperTrack is off-policy, sample-efficient, and its own paper reports PPO being bounded
by the rate of experience gathering while it was not. DReCon is PPO and needed 3e8 steps over
30 hours. Ordering the work DReCon-first is still right, for reasons in section 4.

---

## 1. What the tree already has

Measured, not assumed.

| need | what exists | state |
|---|---|---|
| the character | `src/tests/fixtures/robot/humanoid_flex.xml` | 41 bodies, loaded by `robot_mjcf.zig` |
| the motion | `examples/mocap_viewer/dance1_20s.bvh`, 10 s used | loaded by `draw3d.loadBvhSkeletalClip` |
| retargeting | `codecs.retargetRotations`, `draw3d.bvhForwardKinematics` | proven in `examples/geno_dance` |
| physics | `robot.zig` - `rbt.Spec`, `rbt.forward`, `rbt.step` | KUKA at `nv = 7` runs **1738 ns/step**, 2397x realtime |
| PD actuation | `robot.setCtrl`, `actuation`, `limbActuation` | present |
| the RL half | `ppoUpdate`, `gae`, `Graph.diagGaussianLogProb`, `normalizeAdvantages` | done, tested |
| the supervised half | `Graph`, `adamStep`, `mseLoss`, `stepParameters` | done, tested |
| **weight persistence** | `zn.saveParameters` / `loadParameters` to a byte buffer | done |
| **file upload** | `z.web.userfile` queue, proven in `mocap_viewer` on `.bvh`/`.fbx` | done, 64 MB ceiling |
| GPU arithmetic | 111-row CPU/GPU conformance sweep, RL rows included | green on device |

** **EVERY ROW ABOVE WAS VERIFIED BY SCRIPT, not from memory** - the zimrnum names against its
public surface, the assets against the filesystem, and the four things section 2 asks for
(`ewmaFilter`, `integrateRigidBodies`, `radamStep`, `localise`) confirmed genuinely ABSENT rather
than assumed so.

** **NOTHING IN EITHER PAPER'S LEARNING HALF IS MISSING.** What is missing is the plumbing
between the halves, and one genuinely new component: the world model's integrator.

---

## 2. What has to be built, by paper

### 2a. Shared foundation (both papers need all of it)

| | what | where | notes |
|---|---|---|---|
| **S1** | `CharacterState` - positions, velocities, rotations, angular velocities per body | example-local | Both papers use the SAME representation for kinematic and simulated characters. One struct, two instances |
| **S2** | `localise(state) -> features` | example-local | Root-relative positions and velocities, two-axis rotations, heights, up-vector. **SuperTrack eq 1-7.** The single most important piece for learning at all - global coordinates are neither translation nor rotation invariant and a network fed them learns the dance's position on the floor |
| **S3** | clip playback as a kinematic character | example-local | Retarget once at load, hold 600 frames of `CharacterState`. **No motion matching** - see 4a |
| **S4** | PD targets from kinematic joint angles | `robot.setCtrl` | the open-loop half |
| **S5** | reference state initialisation | example-local | reset the sim character to a random clip frame. Both papers rely on it; without it the policy only ever sees frame 0 |
| **S6** | `zn.saveParameters` -> a `ZNW1` file, downloaded; upload to reload | **download needs one bridge export** | see section 5 |

*** **S2 IS NOT OPTIONAL AND IS THE EASIEST THING TO GET SUBTLY WRONG.** SuperTrack spells out
seven equations for it and says plainly that global coordinates are inappropriate to feed a
network. A two-axis rotation matrix rather than a quaternion because quaternions double-cover -
`q` and `-q` are the same rotation and a network sees two different inputs.

### 2b. DReCon-specific

| | what | notes |
|---|---|---|
| **D1** | 110-ish dim observation, per the paper's `s_t` | CM velocities of both characters, their difference, desired velocity, per-body positions and velocities for a SUBSET of six bodies, sim-minus-kin errors, and the previous smoothed action |
| **D2** | corrective-offset action on a SUBSET of joints | the paper uses 10 of them. **Fewer actions is faster, not a compromise** - their ablation says credit assignment gets easier |
| **D3** | `ewmaFilter(previous, action, stiffness)` -> **zimrnum** | `y_t = beta*a_t + (1-beta)*y_{t-1}`, `beta = 0.2`. Smooths twitching; the paper feeds `y_{t-1}` back into the state so the policy can SEE its own filter |
| **D4** | the five reward terms | position, velocity, local pose, CM velocity, and a `fall_factor` multiplier |
| **D5** | small final-layer init, uniform in [-0.01, 0.01] | ***** this is the difference between training and not.** With standard init the policy's first actions are large and destroy the open-loop control that was nearly working. Their Fig 9 shows it plainly |

** **D4's REWARD IS A PRODUCT, NOT A SUM, AND THE PAPER EXPLAINS WHY.** `exp` of summed negative
distances equals the product of the individual exponentials, each in `(0, 1]` - so the WORST
tracked body caps the total and the policy is forced to improve it rather than trading it
against a well-tracked one. Our `trackingKernel` already is `w*exp(-alpha*|e|)`; the composition
is the caller's.

### 2c. SuperTrack-specific

| | what | where | notes |
|---|---|---|---|
| **T1** | world model: `(local state, PD targets) -> accelerations` | `Chain` on the tape | predicts ACCELERATIONS, not velocities - their ablation shows it matters |
| **T2** | `integrateRigidBodies(state, lin_acc, ang_acc, dt)` | **zimrnum, ON THE TAPE** | **the one genuinely new component.** SuperTrack eq 8-12. The policy's gradient flows through this, so it must be tape ops |
| **T3** | windowed rollout, `N_W = 8` and `N_pi = 32` | example-local | the world model is unrolled through the tape for the whole window |
| **T4** | the eight policy losses | composes from existing | local position, velocity, rotation, angular velocity, height, up, plus L2 and L1 regularisation on the offsets |
| **T5** | `radamStep` | **zimrnum** | both papers use RAdam. We have Adam; RAdam is Adam with a rectified warmup term that removes the need for a learning-rate warmup |

*** **T2 IS WHAT MAKES THE WHOLE METHOD WORK AND IT IS WHY `gradientOf` MATTERED.** The policy's
loss is measured on a state that is the world model's output integrated forward 32 times. Every
one of those integrations has to be differentiable, or the gradient reaches the policy through
only the last step. `exp(dt/2 * omega) (x) q` for the rotation update needs a quaternion
exponential on the tape.

* **The rotation integration is the delicate part.** Positions and velocities are `add` and
`scale`. Rotations are a quaternion exponential and a quaternion product, and both need
backwards. They compose from `mul`, `add`, `sin`, `cos` and a norm - none of which are new - but
the composition has to be written carefully and gradient-checked.

---

## 3. Ten minutes, honestly

The papers report 30 hours (DReCon, 3e8 steps) and 20-40 hours (SuperTrack, 100k-200k
iterations, with basic balancing at ~10k iterations / 2 hours).

**Why our target is not those numbers:**

| their problem | ours |
|---|---|
| LaFAN: 1.4M frames, 6.5 hours of diverse motion | **600 frames, one clip** |
| a policy general over a whole database | a policy for ONE trajectory |
| 5 layers x 1024 units (SuperTrack) | as small as works - start at 3 x 256 |
| 20 bodies, 19 joints, PhysX at 240 Hz | `humanoid_flex`, our solver, 60 Hz control |

SuperTrack's ~10,000 iterations to basic balance is the number to beat, and 10 minutes at
10 ms/iteration is 60,000 iterations. **The iteration COUNT is comfortably reachable; the
question is entirely whether an iteration can be 10 ms.** Theirs was ~720 ms with batch 2048,
window 8, through 5x1024 networks. Ours would be perhaps 100x less arithmetic.

** **SO THE PLAN'S FIRST REAL MILESTONE IS A MEASUREMENT, NOT A FEATURE** - see 4b. If an
iteration cannot get near 10 ms, the target moves and we find out in an afternoon rather than
after building everything.

* **Physics is the other half of the budget and we have a real number for it.** KUKA at `nv = 7`
costs 1738 ns/step. `humanoid_flex` has 41 bodies, so `nv` is perhaps 40-50 and the constraint
solve grows superlinearly - budget 20-40 us/step until measured. At 60 Hz control with 4
substeps that is 80-160 us per character per control step, so **one character generates ~7,000
control steps per second and a hundred of them saturate a core.** Collection is not free and the
measurement in 4b must include it.

---

## 4. The order to build in

### 4a. Stage 0 - the kinematic rig, no learning at all

Retarget the 10 s clip onto `humanoid_flex`, play it back as PD targets with **no policy**, and
watch it fall over.

*** **THIS IS THE MOST IMPORTANT STAGE AND IT CONTAINS NO NEURAL NETWORK.** DReCon's whole
premise is that open-loop playback is *nearly* right - "not sufficient for maintained balance,
but comes close". If our open-loop character falls in the first 200 ms, the retargeting or the
PD gains are wrong, and no amount of policy will fix it. **The character should get a second or
two in before losing balance.** That is the gate for stage 0 and it is worth however long it
takes.

** **NO MOTION MATCHING.** DReCon's kinematic controller exists to satisfy interactive user
input from a 10-minute database. We have one 10-second clip and no user. Playing it back IS the
kinematic controller, and building motion matching first would be building the part of the paper
that our goal does not need. Add it later if interactive control becomes the goal.

### 4b. Stage 1 - the measurement that sets the target

Before either learner: time one full iteration end to end with real shapes. Collection for N
characters, a world-model update at `N_W = 8`, a policy update at `N_pi = 32`. Report
microseconds per part.

**This answers the only question that matters early:** what is achievable in 600 seconds? If an
iteration is 10 ms, 60,000 iterations. If it is 200 ms, 3,000 - below SuperTrack's balance
threshold, and the plan needs smaller networks, fewer bodies, or a longer target.

### 4c. Stage 2 - DReCon, because it proves the rig with the simpler learner

PPO over the existing `ppoUpdate`. D1-D5. It will not hit ten minutes and **it is not supposed
to** - it is supposed to demonstrate that the observation, the action, the reward and the
physics loop are all correct, using a learner we have already tested end to end on cartpole.

* When it learns anything at all - the character surviving measurably longer than open-loop -
the rig is proven and SuperTrack becomes a change of learner rather than a change of everything.

### 4d. Stage 3 - SuperTrack, the one aimed at the target

T1-T5, with T2 gradient-checked before anything depends on it.

* **The world model is trained first and alone, for one clear reason:** the policy's gradient is
only as good as the model it flows through. A policy trained against a world model that has not
yet learned the physics is optimising against noise. SuperTrack trains both every iteration, but
the first few hundred iterations should be world-model-only.

### 4e. Stage 4 - persistence

Networks to `localStorage`, reload without retraining.

---

## 5. Saving networks: explicit files, not localStorage

**Decision, Sep 15: `localStorage` is out.** Not because of a measurement but because of what we
are building - a world model is millions of parameters, and any scheme with a 5 MB ceiling
shapes the network before the network shapes itself. **A storage limit is a bad reason to pick
an architecture.**

`localStorage` also evicts. iOS Safari discards it under memory pressure, so a ten-minute
training run can vanish between one page visit and the next, silently.

### What already exists, and it is half the job

*** **UPLOAD IS BUILT, PROVEN, AND EXACTLY OUR CASE.** `examples/mocap_viewer` takes `.bvh` and
`.fbx` two ways - dropped anywhere on the page, or through a Load button - over a queue API:

    while (z.web.userfile.pendingCount() > 0) {
        const size = z.web.userfile.nextSize();
        const name_len = z.web.userfile.nextName(&name_buf);
        const got = z.web.userfile.readNext(buf);
    }

Two of its decisions transfer directly and are worth naming rather than rediscovering:

** **IT SNIFFS THE FORMAT FROM THE BYTES, NOT THE FILE NAME.** A weights file gets a magic
number for the same reason, and then the version check and the format check are the SAME check
rather than two that can disagree.

** **IT REFUSES AN OVERSIZED FILE BEFORE ALLOCATING** - `max_file_bytes` is 64 MB and the check
happens before the `alloc`. That is the wasm-memory lesson already solved; a weights loader
inherits it for free.

### What has to be built: one bridge export

There is no download anywhere in the runtime - no `createObjectURL`, no `Blob`, no anchor click.
So:

    js_userfile_download(name_ptr, name_len, data_ptr, data_len)

A `Blob`, a `createObjectURL`, a synthetic anchor click, a `revokeObjectURL`. Roughly fifteen
lines, in `bridge.zig` beside the twenty-odd DOM exports already there, with a `z.web.userfile`
wrapper to match `readNext`.

### The file format, precisely

    magic     "ZNW1"                      4 bytes, sniffed not trusted
    version   u32                         bumped when ANY field below changes meaning
    kind      u32                         0 policy, 1 world model, 2 critic
    obs_dim   u32
    act_dim   u32
    layers    u32, then that many u32     the shape, in order
    params    u64                         total f32 count, checked against the byte length
    weights   params x f32, little endian

*** **THE LOADER REFUSES A MISMATCH RATHER THAN RESHAPING TO FIT.** A weights blob is a list of
numbers whose meaning lives entirely in the layout that produced it. Load one against a changed
observation and every number is finite, every shape can be made to fit by chance, and the policy
produces plausible wrong actions. **The header is not metadata, it is the thing that makes the
file safe to load** - and the refusal must name which field disagreed.

** **f32 ON DISK even when training in f64.** The saved weights are for inference and for moving
between machines; half the bytes at no visible cost. The loader widens on the way in.

* Three files rather than one bundle - policy, world model, critic - because SuperTrack's own
transfer result is that a world model generalises across motions while a policy does not.
**Keeping a good world model while retraining a policy is a real workflow**, and one bundle
makes it impossible.

* **The upload path is the important one to get right, not the download.** A download that fails
is obvious. A load that succeeds against the wrong layout is the failure this codebase keeps
finding, and it is why the header carries shapes rather than just a version.

## 6. What could go wrong, ranked

| | risk | why it ranks here | mitigation |
|---|---|---|---|
| 1 | **Open-loop playback falls immediately** | stage 0 gates everything, and retargeting errors look like physics errors | stage 0 is its own milestone with a stated bar - a second or two upright |
| 2 | **An iteration is 100x too slow** | the ten-minute target dies quietly and late | stage 1 measures before anything is built on it |
| 3 | **T2's rotation gradient is wrong** | the policy trains against a subtly wrong derivative and converges to something plausible and bad | `checkGradient` on the quaternion integration BEFORE the policy exists |
| 4 | **The world model is accurate and useless** | it can be right on the data it saw and wrong everywhere the policy wants to go - their Fig 14 shows predictions degrading past 64 frames | keep `N_W = 8`; train world-model-only first; watch the LOSS on fresh data, not on the buffer |
| 5 | **Reward or loss weights unbalanced** | both papers tune weights for "roughly equal contribution at the start of training" - a term two orders of magnitude larger owns the gradient | log every term separately from the first iteration |
| 6 | **Saved weights load against a changed layout** | finite, plausible, wrong | versioned header, section 5 |

* **Risk 4 is the one specific to model-based methods and the least familiar.** A world model
overfits to the state distribution it was trained on, which is the distribution the CURRENT
policy produces. As the policy improves it walks off that distribution and the model's
predictions degrade exactly where the policy is trying to go. The window-based training and the
shared cyclic buffer are both about this, and they are why the buffer holds ~150,000 samples in
the paper rather than a few thousand.

---

## 7b. Adversarial review of this plan

Written by attacking the plan rather than defending it. Three of these change the 20 turns.

### A1. "Reaches the end without falling" is satisfiable by standing still ***

**The stated goal has a trivial solution.** A policy that plants both feet and ignores the clip
never falls and reaches ten seconds. If the reward is dominated by a fall term, that is not even
a degenerate corner - it is the easiest local optimum available and gradient descent finds it
first.

*Fix, and it changes the metric:* **two numbers, always reported together.**

    survival     seconds before the head deviates > 25 cm from the reference
    tracking     mean local-position error over the frames that survived

* Standing still gets survival 10.0 and a terrible tracking error, and **the plan must treat that
as a FAILURE, loudly.** DReCon's reward is a PRODUCT of tracking terms times a fall factor
exactly so that not-falling buys nothing on its own - that structure is the answer and section 2b
already names it, but the METRIC had not caught up.

### A2. There is no baseline, so "it learned" is unfalsifiable **

The plan compares three learners against each other and never against the two numbers that make
any of them meaningful.

*Fix:* turn 5 records both, and every later plot carries them as horizontal lines.

    open-loop      clip -> PD targets, no policy at all
    zero policy    the network at initialisation, outputs near zero

* These are nearly the same run and that is the point: **D5 initialises the final layer near
zero specifically so the untrained policy IS the open-loop controller.** If they differ much, the
initialisation is wrong and turn 10 would have chased it as a learning problem.

### A3. The three-way comparison is unfair as specified ***

Turns 7-13 tune the observation and reward while building AWR, then hand that setup to SAC. **Any
choice made to help the first method is a headwind for the second**, and the plot would say "AWR
wins" when it means "AWR was here first".

*Fix, and it is cheap:* **freeze the observation, the reward, the network shape and the seed set
BEFORE turn 7**, in a single `TrackingTask` struct that all three import. What each method may
tune is only its own hyperparameters - learning rates, batch size, update-to-data ratio.

* And report **wall clock, not iterations.** A method needing ten times the updates at a tenth
the cost is a tie, and the whole question is what fits in ten minutes.

### A4. Reference state initialisation and the metric contradict each other **

Both papers reset to a RANDOM frame - without it the policy only ever sees frame 0. But the goal
is reaching the END of the clip, which is measured from frame 0.

*Fix:* they are two different runs and the plan must say so. **Train with random resets, evaluate
from frame 0 with the policy deterministic** - `SquashedGaussian.deterministic` and
`Categorical.greedy` exist for exactly this. Evaluating the exploring policy measures the noise.

### A5. The world model has a chicken-and-egg problem the plan waves at **

Turn 15 trains the world model alone, turn 16 trains the policy through it. But a world model
learns the distribution the CURRENT policy visits, and the policy then walks off it - which is
precisely where its predictions are worst.

*Fix:* **watch the world model's loss on FRESH data, never on the buffer it trained from.** A
model that is accurate on the buffer and useless ahead of the policy shows exactly that
divergence, and nothing else does. Their `N_W = 8` window and 150k-sample buffer are both about
this.

### A6. Ten seconds is a 600-step episode, which is near both papers' maximum *

SuperTrack terminates at 512 frames and DReCon at 20 seconds. **Our whole task is one episode at
their episode length**, so "reach the end" is their survival-rate metric with the bar at 100%.

*Not a problem - a calibration.* It says the task is hard in the way their task is hard, and that
a partial result (surviving 6 of 10 seconds) is real progress rather than a failure.

### A7. If the humanoid will not stand open-loop, turns 3-5 could eat ten turns **

Retargeting onto a physical character is the classic time sink, and the plan gates everything on
it while offering no way out.

*Fix - an escape hatch, decided in advance:* **if turn 5 has not cleared one second of open-loop
standing after three turns, drop to a simpler articulated figure** - the existing cartpole or a
planar walker - prove the entire learning stack end to end on it, and return to the humanoid with
a rig that is known to work. **The learning stack and the character rig are separate risks and
should not be allowed to fail as one.**

### A8. "Half DReCon's width" may be too small for the world model *

2x64 is a reasonable policy. SuperTrack used 5x1024 for a world model approximating rigid-body
physics across a database - ours needs it only near one trajectory, but 2x64 might not hold even
that.

*Fix:* the policy stays 2x64 for the comparison's sake; **the world model is allowed to be bigger
and the plan should expect to grow it.** With `localStorage` gone there is no reason not to.

---

## 7c. The ladder, with numbers

What "better" means at each rung, so progress is a fact rather than an impression.

| rung | survival | tracking | meaning |
|---|---|---|---|
| 0 | open-loop, measured turn 5 | measured | the floor everything is compared against |
| 1 | > 2x open-loop | any | the policy is doing SOMETHING |
| 2 | > 5 s | better than open-loop | it is balancing, and it is not standing still |
| 3 | **10.0 s** | within 2x of open-loop's best frames | **the stated goal** |
| 4 | 10.0 s | near the reference | the result the papers get |

* **Rung 2's second column is the one that catches the standing-still policy**, and it is the
reason the ladder has two columns at all.

---

## 8. The next 20 turns, precisely

Written so each turn has a stated deliverable and a stated way to know it worked. Sizes follow
Simon's call: **half DReCon's width, so 2 layers of 64**, and one 10-second clip.

**The question the whole sequence answers:** which learner gets a humanoid to the end of ten
seconds of dance without falling, with no perturbations, fastest.

### Turns 1-2: persistence, on the phone

| turn | deliverable | how we know |
|---|---|---|
| 1 | `js_userfile_download` in `bridge.zig` + a `z.web.userfile.download` wrapper | a standalone writes a `ZNW1` file and the phone receives it |
| 2 | Simon runs it on the phone at both sizes | the headline line says both survive, or names which does not |

** **The round trip must be BYTE FOR BYTE and the pattern must contain all 256 values.** A
length check passes on any path that mangles non-text bytes. Download, re-upload, compare.

*** **AND THE TEST THAT MATTERS MOST IS THE ONE THAT MUST FAIL:** hand the loader a file whose
header says a different `obs_dim`, and it must REFUSE by name. A loader that accepts it is worse
than no persistence at all, because every number it produces afterwards is finite and wrong.

### Turns 3-5: the kinematic rig, no learning

| turn | deliverable | how we know |
|---|---|---|
| 3 | retarget onto **`humanoid_flex2`** AT STARTUP via `z.robot_mjcf` - no tool, no saved file (0g, 0h) | the kinematic character dances; the sim character is a ragdoll |
| 4 | clip joint angles -> PD targets via `setCtrl`, open loop | the sim character *attempts* the motion |
| 5 | **record BOTH baselines** - open-loop survival and tracking error, and the zero-init policy | *** **the gate: one to two seconds of open-loop standing.** Under 200 ms means retargeting or gains are wrong and NO policy will fix it. *** **An escape hatch is decided NOW, not later:** if this has not cleared one second after three turns, drop to a simpler articulated figure, prove the whole learning stack on it, and come back - see 7b/A7 |

### Turn 6: the measurement that sets the target

One number, before any learner: microseconds for a collection step, a forward pass, and a
backward pass at 2x64 with the real observation width. **600 seconds divided by that is the
iteration budget**, and it decides whether ten minutes is a plan or a wish.

### Turn 6b: freeze the task before any learner exists

*** **ONE `TrackingTask` STRUCT, IMPORTED BY ALL THREE METHODS** - observation layout, reward
terms and weights, network shape, episode length, and the seed set. **Frozen before turn 7.**

Without this the comparison is rigged by construction: everything tuned while building AWR is a
headwind for whatever comes second, and the plot would report arrival order as if it were merit
(7b/A3). Each method may tune only its OWN hyperparameters - learning rates, batch size, UTD.

### Turns 7-10: the first learner - AWR

AWR first, not SAC, for three reasons: it is the algorithm we already have a **learning gate**
for; it is off-policy so it reuses the buffer; and its update is one loss with no critic
bootstrap, so when it fails the cause is in the observation or the reward, not the algorithm.

| turn | deliverable |
|---|---|
| 7 | observation and reward: DReCon's five terms via `trackingKernel`, combined as a PRODUCT |
| 8 | AWR actor + critic at 2x64, `advantageWeights`, `maskedMean`, `stepParameters` |
| 9 | reference state initialisation and early termination (head deviates > 25 cm) |
| 10 | **first learning curve - SURVIVAL AND TRACKING, on one plot, with both baselines as horizontal lines** |

*** **TWO NUMBERS, ALWAYS TOGETHER.** A policy that plants its feet and ignores the clip survives
ten seconds with a terrible tracking error, and that is the easiest local optimum in the whole
problem - see 7b/A1. Survival alone would call it a win.

** **Train with random resets, evaluate from frame 0 with the policy DETERMINISTIC.** Two
different runs, and `SquashedGaussian.deterministic` exists for the second one. Evaluating the
exploring policy measures the noise (7b/A4).

### Turns 11-13: SAC with the modern extensions

Everything is already in the tree: `sacTarget`, `SquashedGaussian`, `Temperature.forActionDim`,
`min` for twin critics, `dropout`/`resampleDropout` for DroQ, `offPolicyUpdate`.

| turn | deliverable |
|---|---|
| 11 | SAC on the same observation and reward, same sizes |
| 12 | DroQ: dropout critics, `min` folded over M masks, high update-to-data ratio |
| 13 | **head-to-head with AWR on one plot** - same clip, same seeds, same wall clock |

* Simon's intuition is that SAC-with-extensions or AWR gets there quickly, and turns 10 and 13
are what settle it. **The comparison is wall clock, not iterations** - a method that needs ten
times the updates but each is ten times cheaper is a tie.

### Turns 14-17: SuperTrack

| turn | deliverable |
|---|---|
| 14 | `integrateRigidBodies` on the tape, **`checkGradient` on the quaternion path before anything uses it** |
| 15 | world model trained ALONE - **sized as large as it needs to be, not 2x64**, and judged on FRESH data rather than the buffer it trained from (7b/A5, A8) |
| 16 | policy trained by backprop through the world model, window 32 |
| 17 | **three-way plot**: AWR, SAC-DroQ, SuperTrack |

### Turns 18-20: ship it

| turn | deliverable |
|---|---|
| 18 | winner's weights downloaded as `ZNW1`, re-uploaded, and the character still dances - **plus the refusal test: a file with the wrong `obs_dim` must be rejected by name** |
| 19 | standalone page: train button, save button, and a visible survival-time readout |
| 20 | tutorial chapter and the plan updated with what actually happened |

### What is deliberately NOT in these 20 turns

* **MPC with a 0.2 s window.** Simon raised it and it is a good idea - our iLQR already solves
cartpole swingup in seconds, and a 12-frame horizon is cheap. But it is a THIRD method, and
adding it before the first two have a number would mean three half-finished comparisons instead
of one finished one. **It belongs at turn 21**, where it can be measured against a winner.

* **Perturbations.** The stated task is reaching the end of the clip unperturbed. Robustness is
what DReCon's projectile training is for and it is a different experiment.

* **Motion matching, a motion database, GPU-resident physics.** Section 7.

---

## 7. What this plan deliberately excludes

- **Motion matching** - see 4a. One clip, no user input.
- **A motion database.** Ten seconds, one clip. Generalising across motions is what makes the
  papers 30-hour jobs.
- **Rough terrain, interactive control, get-up behaviours.** All named as future work in the
  papers themselves.
- **GPU-resident physics.** `robot.zig` is CPU and the sweep does not cover it. Collection on the
  CPU and training on the GPU is the split that already works; changing that is a separate
  project with its own verification problem.
