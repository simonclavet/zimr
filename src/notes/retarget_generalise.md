# ★★★ RETARGETING THE MIXAMO DROP KICK — the plan, and the cleanup it forces

## What is different about this capture

    LAFAN1 (Geno)   Hips Spine Spine1 Spine2 **Spine3** Neck Head  ...ToeBase
    Mixamo          Hips Spine Spine1 **Spine2** Neck Head HeadTop ...ToeBase Toe

★★★ **Mixamo's top spine joint is `Spine2`; LAFAN1's is `Spine3`.** `lafan_to_humanoid` maps the
robot's TORSO — its ROOT — to `Spine3`, which does not exist here. The root would be UNMAPPED, and
everything downstream anchors on it.

★ Also: Mixamo has `HeadTop` and `Toe` that LAFAN1 lacks, and its rest pose is **not a T-pose**
(Mixamo ships an A-pose), while every rest-derived quantity in this system reads
`Geno_stance.bvh`.

## ★★★ THE FIVE HARDCODED ASSUMPTIONS THIS EXPOSES

    1. joint NAMES        "Spine3", "RightToeBase" written into the match table
    2. the T-POSE FILE    `Geno_stance.bvh`, used for twist offsets, foot offsets, rest rotations
    3. the SCALE          0.0097, derived once from Geno's hip height
    4. the FLOOR          taken from the capture's lowest foot — fine, already data-driven
    5. the MATCH TABLE    one table, named for one capture format

★★ Items 1-3 are the work. **Each is a constant standing in for something the capture states**,
which is the same error this project has made a dozen times in miniature.

## The plan

**1. ALTERNATIVES IN THE MATCH TABLE.** A row names several acceptable joints in preference
order — `.{ "torso", &.{"Spine3", "Spine2", "Spine1"} }` — and `resolveMatchTable` takes the first
that exists. **One table serves both skeletons**, and a new capture needs no code.

**2. THE REST POSE FROM THE CAPTURE ITSELF.** Frame 0 of the clip, or the FBX bind pose, instead
of a separate T-pose file. ★ Risk: an A-pose bind is not a T-pose, and this project has been
burned by exactly that (§4, five times). **The construction must not care which it is** — it
only needs both figures in the SAME pose, and the robot is SOLVED into whatever the capture's
rest is.

**3. SCALE FROM THE TWO SKELETONS.** Ratio of total bone length, or of hip height, computed at
load. **The 0.0097 is Geno's number and nothing else's.**

**4. THEN MEASURE, with the instruments that already exist.** Visual mean/worst, per-bone angles,
worst pop, best-possible sweeps. ★ The stock `humanoid.xml` is the target, so the proportion
mismatch will be large again — and the `position_pull` dial exists precisely for that.

## ★★ WHAT NOT TO DO

★ Do not tune anything for this clip before it runs at all. **Every weight in the system was swept
against Geno**, and re-sweeping them per capture would make the system capture-specific in a
second way.

★ Do not add a second match table. **If two tables are needed, the abstraction is wrong.**

---

# ★★★ STEP 1 DONE — one table, both skeletons

`MatchRow.alternatives`: a row names the joint it wants and what it will settle for, in
preference order. `resolveMatchTable` takes the first that exists.

    torso   .human_joint = "Spine3"   .alternatives = &.{ "Spine2", "Spine1", "Spine" }
    toes    "RightToeBase"            &.{ "RightToe" }

★★ **Preference order carries real knowledge**: `Spine3` before `Spine2` before `Spine1` states
which is highest up the chest. It is not a fallback list, it is a ranking.

★ Tested on three skeletons — LAFAN1 (picks `Spine3`), Mixamo (picks `Spine2`), and a minimal one
with only `Spine1` (picks that, one rung lower). **The table is unchanged between them.**

★★★ Without this the robot's TORSO — its ROOT — would map to nothing on the Mixamo clip, and
every stage anchors on that body. **The failure would have been near-silent**: not a crash, just
an unmapped root and a figure in the wrong place, which is a failure mode this project has now
shipped twice.

## Next, in order

    2. THE REST POSE FROM THE CAPTURE     currently `Geno_stance.bvh` for every clip
    3. SCALE FROM THE TWO SKELETONS       currently 0.0097, which is Geno's number
    4. run the drop kick and MEASURE      visual mean/worst, angles, pops — all already exist

★ Step 2 is the risky one. Mixamo ships an **A-pose** bind, not a T-pose, and this project has
been burned five separate times by comparing rest poses of different KINDS. **The construction
must not care which it is** — it needs both figures in the SAME pose, and the robot is solved
into whatever the capture's rest happens to be. That property is already true of
`solveRestPoseFromSource`; what is not yet true is that the rest pose comes from the capture at
all.

---

# ★★★ STEPS 2 AND 3 WERE ALREADY DONE — the cleanup had happened by accident

Checking before building, as planned, found that the example is **already capture-driven**:

    the rest pose   `source.rest_positions` / `source.rest_orientations`  — the CHARACTER's own
    the scale       `cm_to_m * robot_hip / source.hip_height`             — derived per source
    joint names     **none left in the example's retarget path**

★★ Deleting `buildCorePairs` and `coreDirectionTarget` when the point cloud subsumed them removed
every hardcoded joint name; `buildPointSamples` works from `human_of_body` and
`firstChildOfJoint`, which are structural. **The generalisation was a side effect of simplifying**,
which is the usual way it happens and the reason the plan should always start by looking.

★ Only the harness still reads `Geno_stance.bvh` — a test fixture choosing its own input, which
is correct.

## So the whole gap was the match table

★★★ And the failure would have been **near-silent in a specific way**: `resolveMatchTable` fails,
the example calls `setStatus` and sets `show_robot = false`. **The robot would VANISH, not look
wrong** — easy to read as a rendering bug rather than a mapping one.

## What now guards it

    resolveMatchTable: one table serves LAFAN1 and Mixamo    the MECHANISM, three rows
    lafan_to_humanoid resolves against a Mixamo skeleton     the SHIPPED table, 25 real joints

★★ The second matters because the first would pass even if the real table named a joint Mixamo
lacks. **A mechanism test and a data test are different tests**, and this project has twice
shipped a working mechanism fed the wrong data.

## Remaining, for when the clip is on screen

★ Mixamo's bind is an **A-pose**, not a T-pose. `solveRestPoseFromSource` solves the robot into
whatever the capture's rest is, so the KIND should not matter — but that property has never been
tested on a non-T-pose, and five separate bugs in this project were rest poses of different kinds.
**It is the first thing to suspect if the drop kick looks wrong.**

★ The stock `humanoid.xml` has none of flex2's Geno-matched proportions, so the arm ratio will be
large again. **`position_pull` is the dial** — 1.0 suits matched proportions, lower values suit
mismatched ones, and it is now a stated parameter rather than a hidden assumption.

---

# ★★★ THE UI, AND A CACHE THAT WOULD HAVE RETARGETED TO THE WRONG BONES

## ★★★ THE BUG VERIFYING THE UI FOUND

`buildPointSamples` runs only when `robot_sample_count == 0`, and **each sample stores a JOINT
INDEX into the source skeleton.** Nothing invalidated that cache when `robot_source` changed.

★★ Switching from Geno to the Mixamo drop kick would have kept samples pointing at **Geno's**
indices — a different skeleton with a different joint order. **It would not crash**: the indices
are in range for both. It would just retarget to the wrong bones.

★★★ **Fifth time a cache has outlived the thing it was built from**, and the quietest of the
five: no error, no clamp, no missing target — simply the right machinery reading the wrong rows.

★ Fixed where `robot_dirty` is consumed: reset `robot_sample_count` and `robot_has_previous`
before `refreshRobotMap`. **The posture cache had the same problem** — last frame's configuration
belongs to the old source too.

## Defaults changed, and why

    robot_source     0 -> 1        the robot follows the MIXAMO DROP KICK
    show_mesh    true -> false     the robot is drawn OVERLAID; a solid mesh hides it entirely
    show_skeleton false -> true    the skeleton is what the robot is compared TO

★★ **Every screenshot in this project has begun by toggling the mesh off.** A default that must be
undone before anything can be seen is the wrong default.

★★★ And the source default now points at the capture the system has NEVER been tuned against:
different skeleton (`Spine2`, not `Spine3`), different rest pose (an A-pose bind), different
motion. **The untested path is the one on screen**, rather than the one nobody opens.

---

# ★★★ THE ROBOT STOOD STILL ON THE DROP KICK — two scales that could disagree

The robot held a near-rest pose while the character danced. **A figure that does not move at all
is not a bad solve; it is targets it cannot use.**

## The cause: unit assumptions spread across two fields

    rest scale     `cm_to_m * robot_hip_height_m / source.hip_height`
    frame scale    `robot_hip_height / source.hip_height`

★★★ Both pair `rest_positions` (assumed CENTIMETRES) with `hip_height` (assumed METRES), and the
two expressions **do not even agree with each other** — one applies `cm_to_m`, the other does
not. That worked because Geno happens to honour both assumptions. **A different capture honours
neither**, and there is nothing in the code that would say so.

★★ The comment above the rest scale already warned about this — *"two quantities from the same
struct in different units is a trap"* — and the fix at the time was to move the conversion rather
than to remove the assumption. **The warning was right and the repair was too small.**

## `captureScale`, one derivation used everywhere

    source's tallest rest joint  vs  the robot's own height  ->  a ratio of two LENGTHS

★★★ The source's unit CANCELS. **A scale derived from one quantity cannot disagree with itself**,
and using the same function for the rest pose and the per-frame targets means those two cannot
disagree either — which matters because every foot and twist offset is measured in the rest pose
and applied per frame.

★ `robot_height_m = 1.445` joins `robot_hip_height_m = 0.830` as a measured constant rather than a
guessed one.

## ★★ WHAT THIS EPISODE IS AN INSTANCE OF

    one table, two skeletons        naming, fixed by alternatives
    one cache, two sources          indices, fixed by invalidation
    one scale, two unit assumptions magnitudes, fixed by cancellation

**Every generalisation failure so far has been a constant standing in for something the capture
states.** The drop kick did not break the retarget; it exposed three places where the retarget was
never general.

---

# ★★★ `mixamorig:Spine2` — AND A TEST THAT SANITISED ITS OWN INPUT

The robot checkbox was UNCHECKED on screen. That is not a display default: `resolveMatchTable`
failed, the example called `setStatus` and set `show_robot = false`. **The robot never moved
because it was never posed.**

## The cause

★★★ **Mixamo prefixes every bone: `mixamorig:Spine2`, not `Spine2`.** The table names bare
joints, so NOT ONE row matched.

★ Fixed with `jointNameMatches`: compare after the last `:` or `|`. Exporter-agnostic without
listing prefixes — **a list of known prefixes would be the same mistake as a list of known joint
names, one level up.**

## ★★★ THE TEST FAILURE THAT MATTERS MORE

I wrote "lafan_to_humanoid resolves against a Mixamo skeleton" and it PASSED — **while the shipped
example failed on the same table and the same capture.** The test fed it bare names, because I
had extracted the joint list with a regex that stripped the prefix.

    the regex        `mixamorig:?([A-Za-z0-9]{3,20})`   -> captured the name WITHOUT the prefix
    the test         used those bare names               -> passed
    the example      used `clip.boneName()`              -> failed on every row

★★★ **A test that sanitises its own input is testing the sanitiser.** The extraction step that
made the joint list readable also made it wrong, and nothing connected the two — the same shape
as the harness/example divergences, but inside a single test.

★★ It now uses the fully-prefixed names, and would have caught this the first time.

## The tally for this capture

    one table, two skeletons          naming        -> alternatives
    one cache, two sources            indices       -> invalidation
    one scale, two unit assumptions   magnitudes    -> cancellation
    bare names vs `mixamorig:`        namespacing   -> match after the separator

★ Four constants standing in for something the capture states. **None of them was a retargeting
bug**; all four were the system assuming its only capture was every capture.

---

# ★★★ THE BIGGEST REMAINING WEAKNESS WAS NOT THE ALGORITHM

The drop kick works. **But every metric in this project lives in the harness, on Geno** — and the
drop kick exists only in the example. Every diagnosis this session ran:

    screenshot -> guess -> measure something else, in a different program, on a different capture

★★★ Six silent failures were found that way, each costing turns: an unmapped table, a stale
sample cache, two disagreeing scales, a prefixed joint name, a truncated task array, a metric
blind to translation. **None was visible in the thing being looked at.**

## Three numbers, on device

    bodies 18/18  samples 76        an unmapped table hides the robot and looks like a RENDER bug
    fit 0.027 m  worst 0.061 m      the quantity the eye integrates; angles cannot see it

★★ Each answers a question that actually went wrong:

    **bodies**   `resolveMatchTable` failing set `show_robot = false`. For two turns that read as
                 "the robot is not drawing" rather than "the table did not resolve."
    **samples**  a cache built against the previous source retargets to the WRONG BONES, in
                 range, with no error at all. **The quietest failure this project has had.**
    **fit**      the 10 cm offset that nine angle metrics could not see, plus WHICH body is worst
                 — which is how `waist_lower` was found.

★ Cheap: all three are read from state the solve already computes.

## ★★ AND AN HONEST LABEL

The checkbox read `robot (humanoid.xml)` for several turns after the example switched to the flex
model. **A UI that lies about which model it is showing makes every screenshot ambiguous** — and
every diagnosis in this project has started from a screenshot.

## What I would do next

1. ★★ **Run the harness on the drop kick.** It reads BVH; the drop kick is FBX. Exporting one
   frame set, or teaching the harness the FBX path, would let every existing instrument — the
   best-possible sweeps, the pop maximum, the per-bone angles — speak about the capture that is
   actually on screen.
2. ★ **Re-sweep the four weights against the drop kick.** Every one was chosen on Geno, and a
   weight is a ratio against the other terms.
3. ★ **A second robot.** `humanoid_flex2` is Geno-shaped; the stock model on a Mixamo capture is
   the honest generalisation test, and `position_pull` is the dial that should make it work.

---

# ★★★ WHY THE HARNESS WILL **NOT** LEARN FBX — a decision, not an omission

The plan's item 1 was "run the harness on the drop kick." Investigated and **deliberately not
done**, for two reasons found by looking rather than assumed:

    `loadFbxModel` lives in `draw3d.zig`, which pulls in `gpu.zig`, `runtime.zig` and the
    shader stack — **423 GPU references** into a headless test module.

    `codecs.fbx.parse` returns a raw DOCUMENT TREE, not a skeleton. Turning one into a clip is
    what `loadFbxModel` does, and **re-implementing it in the harness would duplicate the
    conversion.**

★★★ **That duplication is exactly the failure this project has paid for five times**: a harness
that computes the same thing a second way drifts, and the drift is invisible until a screenshot
disagrees. Building a second FBX→skeleton path to measure the first one would be the largest
instance of it yet.

## ★★ SO THE ON-DEVICE READOUT WAS THE RIGHT ANSWER, NOT A CONSOLATION

    bodies 18/18  samples 76        fit 0.027 m  worst 0.061 m  waist_lower

**The measurement belongs where the code runs.** Three numbers in the robot panel cover the three
failure classes that actually cost turns — unresolved table, stale cache, wrong place — and they
read from the state the shipped solve produced, so there is nothing to drift from.

★ The harness keeps doing what it is good at: BVH captures, best-possible sweeps, pop maxima,
per-bone angles — **on the capture it can load without a second loader.**

## Revised next steps

    ~~1. run the harness on the drop kick~~   rejected: it would need a duplicate FBX path
    2. re-sweep the four weights on the drop kick, USING THE ON-DEVICE READOUT
    3. the stock `humanoid.xml` on a Mixamo capture — the honest generalisation test, with
       `position_pull` as the dial

★★ Item 2 is now possible in a way it was not an hour ago: **the numbers needed to judge a weight
change are on screen with the capture they apply to.**

---

# ★★★ THE DIAL, EXPOSED — and a control that would have lied

## `target pull` is now a slider

    0.0   targets from the ROBOT's own bone lengths     exactly reachable, drifts from the capture
    1.0   targets ARE the capture's joints              stands where the dancer stands

★★ It was a hardcoded `1.0`, chosen by sweeping on `humanoid_flex2.xml` — **a robot built to
Geno's proportions.** For a robot whose proportions do NOT match, a lower value is right, and that
is precisely the case the dial exists for. **A constant that is correct for one configuration is
not a constant.**

★ It sits next to the `fit` / `worst` readout, so the trade can be judged on the capture it
applies to instead of inferred from a different one.

## ★★★ THE MODEL TOGGLE I BUILT AND THEN REMOVED

I added a checkbox to swap `humanoid_flex2.xml` for the stock model, marked `robot_dirty`, and
checked before shipping. **`robot_dirty` refreshes the MAPPING; the model is parsed in
`initRobot`, which runs once.**

★★★ The checkbox would have looked live and done nothing — and worse, **a screenshot taken after
clicking it would have shown flex2 while the UI claimed stock.** That is the same class as the
label reading `humanoid.xml` while embedding flex2, but strictly worse: **a stale label misleads
once; a dead control misleads every time it is used.**

★ Removed rather than shipped. Reloading the robot mid-session means rebuilding model, data,
tasks, scratch, samples and rest pose — real work, not a checkbox. The flag stays, read once, with
a comment saying so.

## ★★ THE PATTERN THIS SESSION KEEPS PRODUCING

    a truncated task array      plausible output, a third of the robot unposed
    a stale sample cache        plausible output, the wrong bones
    a test that sanitised input plausible pass, a total failure shipped
    a dead checkbox             plausible UI, a false claim in every screenshot

**Each would have produced something that looked like it was working.** The only defence that has
worked consistently is checking the mechanism BEFORE trusting the output — and this time it
happened before shipping rather than after a screenshot.
