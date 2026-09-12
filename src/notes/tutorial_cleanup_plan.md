# Cleaning up `robots.html`

## The brief

Remove historical anecdotes. Less AI-sounding. No hype, no "it is not X, it is Y". Explain the
system as a robot simulation course would. Describe the examples clearly. Interesting without
being cringe.

## What is actually wrong, counted

The physics is sound and the explanations are mostly good — section 0 derives
`M(q)v̇ + c = τ + Jᵀf` and motivates generalized coordinates clearly. The problems are register:

    "worth internalising / worth keeping / worth its own"     9 occurrences
    "honestly / honest answer"                                7
    "cost a day / cost three turns"                           2
    "is not X, it is Y"                                       2
    ★ decoration                                              9

And the section titles carried the anecdotes in the open: *"Data, and a bug worth keeping"*,
*"Regularization, and the distinction that cost a day"*, *"A crane, and the move that looks like a
mistake"*.

## The register to write in

A course explains **what the system does and why it is built that way**. It does not narrate the
author's experience of building it. Two rules that cover most of the edits:

  1. **Say the fact, not the feeling about the fact.** "This cost a day to find" becomes the
     description of the failure and how to detect it — the reader gets the useful part without
     the diary.
  2. **State a thing directly rather than by contrast with what it is not.** "It is not a force,
     it is a constraint" becomes "contact is modelled as a constraint", followed by the reason.

Where a mistake genuinely teaches — and several here do — keep the mechanism and drop the
narrative. "A reference must be reachable within the horizon" is a lesson; "I made this mistake
five times" is a memoir.

## Plan, one pass per turn

  1. **Titles and nav** — done. 24 headings and 22 nav entries rewritten; doc-sync clean.
  2. **Sections 0-13**, the foundations: spec, Model, Data, kinematics.
  3. **Sections 14-30**, dynamics and contact.
  4. **Sections 31-40**, planning and iLQR.
  5. **Sections 41-43**, the examples — these need the most work. They are currently framed as
     stories about debugging; they should read as worked problems with a stated setup, a method,
     and measured results.
  6. **Final read-through** for tone consistency and any remaining tics.

## Notes for the later passes

  * `doc-sync` checks 25 exempt blocks against the source. **Code excerpts must not be edited
    freely** — the checker will catch drift, and it should.
  * The examples' measured numbers are all real and should stay. Removing the anecdote does not
    mean removing the evidence; a course is more convincing with the measurements in it.
  * Section 12 explains how the page is verified against the code. That is worth keeping and
    worth rewriting — it is a genuinely unusual property of this tutorial.

## ✅ Pass 2 — sections 0-13, the foundations

  * **The opening** no longer says the equation has "one honest answer"; it states it.
  * **Generalized coordinates** are motivated by where the error goes, not by calling the
    alternative "the wrong answer".
  * **The inertia section** was a paragraph about a paragraph — *"this used to describe a
    limitation that no longer exists, and the story is worth more than the limitation was"*.
    Rewritten as the technical point it was hiding: principal moments are the natural form for
    STORING an inertia and the wrong form for COMBINING them, which is why `Inertia` keeps six
    numbers and `rotated()` can do `R·I·Rᵀ` directly. **The lesson survives; the history does
    not.**
  * **The doc-sync note** said the prose "was wrong for months". Now it states the property a
    reader needs: code blocks are verified on every build, prose is not, and where they disagree
    the code is right.
  * **Course framing added**: prerequisites (linear algebra, undergraduate mechanics; no prior
    robotics), what the reader can do at the end, and a phase table mapping section ranges to
    working capability.

★ THE PHASE TABLE IS THE MOST USEFUL ADDITION. The page already had a phase structure and never
stated it — a reader could not tell that §19 is a natural stopping point with a working dynamics
simulator behind it.

## ✅ Pass 3 — sections 14 and 15, the mass matrix

These two carry the first genuinely hard mathematics in the course, so they got content work as
well as tone work.

### Content added

**§14 now derives `M` rather than asserting it.** The energy reading said only that "`M` is the
second derivative of kinetic energy with respect to velocity", which is true and unhelpful. It
now shows the two lines that matter: each body's kinetic energy is `½m|v|² + ½ωᵀIω`, every body's
velocity is `J_body·v`, so summing gives `½vᵀ(Σ JᵀI J)v` and the bracket is `M`.

★ THAT DERIVATION EARNS TWO PROPERTIES THE COURSE USES LATER: `M` is **symmetric by
construction**, and **positive definite** unless some direction of motion costs no energy. §15
factorizes `M` as `LᵀDL` with no pivoting, which is only valid for a symmetric positive definite
matrix — and it previously just asserted that. The two sections are now connected by a sentence
that says which section established what.

### Tone

    "one of the prettier algorithms in mechanics"   -> "rests on a single observation"
    "the reason is worth sitting with"              -> "for a kinematic tree it cannot happen"
    "Why this is a big deal."                       -> "What that buys."
    "Now the whole thing falls out."                -> "The rest follows."
    "That is the algorithm. One line."              -> "That is the whole algorithm."
    "<h3>The trick</h3>"                            -> "<h3>Composite Rigid Body</h3>"

★ THE ARM-SWING OPENING WAS LEFT EXACTLY AS IT WAS. "Hold your arm straight out and swing it from
the shoulder; now fold it at the elbow and swing again" is the best sentence in the section — it
gives the reader the configuration-dependence of `M` before any notation appears. **Removing
personality is not the goal; removing self-commentary is.**

### A constraint discovered

One target sentence was inside a doc-sync'd code block and had to be left alone. **Code comments
in this file are quoted verbatim from `robot.zig`**, so improving them means editing the source,
not the page — and doc-sync will catch any attempt to do otherwise.

## ✅ Pass 4 — sections 16 to 19: bias forces, stepping, Jacobians

### Content added

**§16 now says what RNE is for.** The section described the algorithm — forward pass for
acceleration, backward pass for force — without connecting it to the `c` in the equation of
motion. Added:

> Run RNE with the true joint accelerations and it computes the torques that produce them — that
> is *inverse* dynamics. Run it with `v̇ = 0` and it computes the torques needed to produce *no*
> acceleration, which is exactly `c(q,v)`. One routine serves both, and forward dynamics uses the
> second form.

★ THAT IS THE SENTENCE A STUDENT NEEDS. Without it, RNE and `c` look like two separate pieces of
machinery, and the reader has no idea why a function named for inverse dynamics appears in the
forward pipeline.

### Tone

    "Here is the mechanism, in one observation."           -> "The mechanism is this."
    "the rate of change ... is worth computing"            -> "each motion axis has a rate of change"
    "A subtlety worth pausing on."                         -> "One subtlety."
    "the single most reused piece of machinery in robotics" -> "reused throughout the rest of this course"
    "That is the entire computation."                       -> "That is the whole computation"
    "<h3>The derivation is two lines</h3>"                  -> "<h3>Deriving it</h3>"

### Consistency

**Four exercises were introduced four different ways** — "Try this.", "Try this, with everything
now in place." — and are now all `Exercise.`, alongside one `Check your understanding`. A reader
scanning for practice work can now find it.

**§19 said "Phases 0 through 4 are the irreducible core, and they are complete"**, which
contradicts the phase table added in pass 2 and was wrong regardless: §19 ends phase 2. Now
"Phases 0 through 2 are complete."

★ THAT KIND OF DRIFT IS WHAT A STRUCTURE TABLE EXPOSES. The claim was invisible until something
else in the document stated the same fact differently.

### Left alone deliberately

§17 is almost entirely doc-sync'd code, and its comments — semi-implicit Euler versus explicit,
why RK4 stops being worth it once contact makes the dynamics non-smooth — are good writing that
lives in `robot.zig`. **Improving them means editing the source**, which is a different task from
cleaning up the page.

## ✅ Pass 5 — sections 20 and 21: contact and the solvers

### The step that was moving too fast

§20 crossed from "contact is a complementarity condition" to "so we solve it on accelerations" in
a single sentence: *"Stated on positions, that condition is a hard combinatorial problem. Stated
on accelerations, it becomes a linear system with sign conditions."* That is the hardest idea in
the section and it was asserted rather than shown. It now takes four paragraphs:

  1. **why positions are combinatorial** — you must decide touching-or-separated for every
     contact, the choices interact because a force at one contact moves the bodies at another,
     and `n` contacts give `2ⁿ` assignments with no way to know which is right without trying;
  2. **what differentiating twice buys** — `a = M⁻¹(τ + Jᵀf − c)` is linear in `f`, so the three
     conditions become an LCP: `J·a − aref ≥ 0`, `f ≥ 0`, and their product zero;
  3. **that this is a standard object** with standard algorithms, harder than a linear solve but
     with the combinatorial explosion gone;
  4. **what it costs** — the constraint now acts on accelerations, so an interpenetration already
     present is not removed by it, because zero acceleration keeps the error exactly where it is.

★ (4) IS WHAT MAKES `aref` MAKE SENSE. The page introduced `aref` immediately afterwards and the
reader had no reason to expect it. Now the previous paragraph creates the need and `aref` answers
it.

### Tone

    "not a fixed amount, not a spring, but whatever it takes"   -> "whatever it takes, however much that is"
    "Why the constraint is soft, and deliberately so."          -> "Why the constraint is soft."
    "Two solvers, and when each is right"                       -> "Two constraint solvers"
    "Projected Gauss-Seidel: sweep and clamp"                   -> "Projected Gauss-Seidel"
    "Newton: minimise the whole thing at once"                  -> "Newton"
    "★ And on that Go1, PGS never reaches the tolerance"        -> "PGS does not reach the tolerance on that Go1"

**All star decoration is gone from the page** — two headings and one note. The last of them
carried an anecdote (*"this line first read `@abs(current)`"*) which is now the rule it teaches:
the threshold is measured against the starting cost, and using the current one puts a feedback
loop in the stopping rule.

### Left alone

§21's measurements stay exactly as they are — PGS residuals at 1, 5, 20, 100 iterations, and the
1.8x speed ratio on a Go1 with the instruction to run `zig build robot-bench` rather than trust a
number from another machine. **That is good course material and needed no help.**

## ✅ Pass 6 — the heading voice, which Simon named precisely

> *"The function I had to rewrite... Inertia, and why it is ten numbers... The aliases, and why
> they are all there. Those sound very AI. It sounds just a bit too weirdly personal, somehow."*

### What the pattern is

**"X, and why Y"** — an appositive that promises a revelation. It positions the writer as someone
holding a secret about to be shared, rather than naming what the section covers. A textbook says
"Spatial inertia"; a blog post says "Inertia, and why it is ten numbers."

★ THAT IS WHY IT READS AS PERSONAL WITHOUT CONTAINING A PRONOUN. The "and why..." implies a
speaker who found the answer interesting, and invites the reader to share that reaction. **The
interest should be in the content, and the reader should decide.**

Three families, all removed:

    (a) the revelation appositive
        "Inertia, and why it is ten numbers"         -> "Spatial inertia: ten numbers"
        "The aliases, and why they are all there"    -> "The aliases"
        "Euler, and the part everyone gets wrong"    -> "Euler"
        "The transpose, and what it is for"          -> "The transpose"

    (b) the author's labour
        "The function I had to rewrite"              -> "Composing two transforms"
        "Checked against MuJoCo, not against myself" -> "Checked against MuJoCo"
        "The one line that had to change everywhere" -> "Threading the timestep through"

    (c) coyness and hype
        "The subtle line"        -> "Differentiating against the accumulated velocity"
        "The gravity trick"      -> "Gravity as a base acceleration"
        "A free diagnostic"      -> "Conditioning, from the same factorization"
        "The number"             -> "The measurement"

**37 headings rewritten** — 32 subheadings plus 5 more on a second look, and 8 section titles I
had introduced the same pattern into myself in earlier passes ("Stepping, and how to test an
integrator", "Two steps, and a recursion falls out").

★★ THE TEST THAT CATCHES IT: **does the title name the topic, or advertise that an explanation is
coming?** "Why there is no fill-in" names a topic. "The property that makes this work" advertises.
Both were on this page.

### And the prose was already clean

Searching for first-person labour in the body text found two instances, both describing a genuine
failure mode ("a first version tested only the two end-caps, which is exact for a cap...") rather
than reminiscing. **The voice problem was concentrated in the headings**, which makes sense —
headings are where a writer reaches for interest, and where a reader is least willing to be sold
to.

## ✅ Pass 7 — sections 22 to 30, and a page-wide register sweep

### Content: two passages saying the same thing without knowing it

§22 justifies implicit damping with the mass-matrix diagonal on a small arm: **0.13 at the
shoulder against 0.00041 at the wrist**, a factor of 300. §26 justifies inertia-scaled PD gains
with exactly the same two numbers, four sections later, as though it were a fresh observation.

They are now linked — §26 says "this is the same ratio that forced implicit damping in §22". ★ A
STUDENT MEETING A FACT TWICE SHOULD BE TOLD IT IS THE SAME FACT, or they file it as two
coincidences instead of one property of the machine.

### The "worth X" construction, counted and removed

Fifteen occurrences in prose, all of the form *"that distinction is worth internalising"*,
*"a subtlety worth pausing on"*, *"two things worth carrying out of this part"*.

★★ **IT IS AN INSTRUCTION ABOUT HOW TO FEEL ABOUT THE CONTENT**, which is the same fault as the
heading pattern Simon named: the writer telling the reader what to value rather than stating the
thing and letting them judge. Replaced with the fact itself —

    "That distinction is worth internalising: a test that passes because..."
      -> "The distinction matters: a test that passes because..."

    "There is a regime where no epsilon works, and it is worth seeing rather than being told."
      -> "...and the measurement shows it more clearly than a description would."

    "Two things are worth carrying out of this part."
      -> "Two things to take from this part."

**Fifteen down to five**, and the survivors are genuine cost/benefit judgements — "collision
detection is worth the seam", "a convention worth the small effort" — where something is being
weighed against its price rather than recommended to the reader's attention.

### And a stale cross-reference

The Part VI navigation still pointed at *"28 What you can do now, honestly"*, retitled two passes
ago. ★ RENAMING A HEADING MEANS SEARCHING FOR ITS OLD TEXT, not just fixing the two places you
remember; this page has both a nav list and inline part-summaries that quote titles.

## ✅ Pass 8 — sections 31 to 34: the planning derivation

This is the densest mathematics on the page, and it needed the least work. The chain from LQR
to the Riccati recursion to Q-notation is well built: each step is short, the algebra is shown
rather than asserted, and §34 explicitly maps its new names back onto §33's formulas so the
reader can see nothing has changed but the notation.

★ THE ONE STRUCTURAL STRENGTH WORTH NOTING: **§33 tells the reader which step to slow down on**
("this is the whole of dynamic programming... it turns one big optimisation over every control
at once into N tiny ones"). That is the hardest idea in the part, and it is flagged as such
rather than passed over at the same pace as the algebra around it.

### Tone

    "And the one idea that makes it practical."     -> "Model predictive control."
    "The trick is to solve it backwards."           -> "The way through is to solve it backwards."
    "This is the test's oracle."                    -> "This recursion is the test's oracle."
    "That is the whole of LQR in one line"          -> "That is LQR in one line"

**The word "trick" is now gone from the page** — it appeared in a heading ("The gravity trick",
fixed in pass 6) and here.

### The "not X, it is Y" pattern, found properly

A plain count of "is not a" returns 12, almost all legitimate negation. Searching for the actual
construction — `is not X (—|,) it is Y` — found exactly three:

    "Two identical structs is not duplication here, it is the point."
      -> "The two structs are identical on purpose."

    "its sparsity is not a property of the state — it is the ancestor relation"
      -> "its sparsity comes from the ancestor relation rather than from the state"

    "is not converging slowly — it is overshooting"
      -> "is overshooting rather than converging slowly"

★★ THE SECOND ONE CARRIED REAL INFORMATION AND KEPT IT. The construction is a stylistic tic, not
a content problem, so the fix is to state the same fact in the positive and let the contrast be
implied by "rather than". **Removing the pattern should never remove the distinction it was
drawing.**

## ✅ Pass 9 — sections 35 to 40: iLQR, the passes, regularization

### Tone

    "But we do not need a globally linear model — we need one that is..."
      -> "A globally linear model is not required though — only one accurate near..."

    "Which sounds complete, and hides a trap."     -> "That rule has a failure case."
    "Rolling out through the real dynamics is the point."
      -> "...is what makes the test meaningful."
    "Honest status."                               -> "Status."
    "What it does and does not break."             -> "What this breaks."
    "§41 is what that buys."                       -> "The three sections that follow put it to work."

**All star decoration is now gone from the prose.** Five survived into this pass; four were
inside doc-sync'd code blocks and belong to `robot.zig`, one was in a note and is now a plain
bold lead-in. ★ THE DISTINCTION MATTERS FOR FUTURE PASSES: a grep for `★` on this file counts
source comments as well as page prose, and only the second kind is editable here.

### Content left exactly as it is

**§38's regularization trap and §39's f32 measurement are the two best sections in the part**, and
neither needed anything beyond removing decoration:

  * §38 shows that *"already optimal"* and *"the model is bad"* are indistinguishable from the
    line search, gives the failure it produces (a gain of −1.711 against a correct −3.240 on a
    problem that was already solved), and the fix — ask the backward pass what improvement it
    predicts, which costs nothing because the quantities are already computed.
  * §39 shows `B = ∂x′/∂u` measured on a linear cart where the true value is constant, and it
    reads `4.95e-5`, then `0`, then `3.45e-4` depending only on where the state sits. Then the
    arithmetic: the signal is 1.7e-8 against an f32 resolution of 1.2e-7 near q≈1.

★★ BOTH ARE MEASUREMENTS RATHER THAN CLAIMS, and both name what the reader should do about it
(§39's "ways out, cheapest first"). **That is the register the rest of the page is being moved
towards** — they did not need editing because they were already in it.

## ✅ Pass 10 — sections 41 to 43: the three examples

### They now share a shape

Three worked examples had three different internal structures. All three now open with the
problem, then:

    §41 crane     The model, and how it was checked | Results
    §42 rocket    The model, and how it was checked | Five ways to state the problem wrongly
                                                    | Two remaining errors
    §43 tracking  Why the servo lags | What the planner uses instead | Results, and an ablation

★ THE ROCKET KEEPS ITS EXTRA SECTIONS ON PURPOSE. Its five failures are the point of the example,
and forcing it into the crane's two headings would have thrown away the part that teaches most.
**Parallel structure means the same shape where the content is the same shape.**

### A stale cross-reference, and why it was fragile

    §37 is titled "the forward pass, and why the step size is not optional"

That title was renamed in pass 6. **Quoting a heading inside prose creates a dependency nothing
checks** — `doc-sync` verifies code blocks against the source and has no opinion about the page's
internal references. Rewritten to state the content instead: "§37 explains why the step size is
not optional", which stays true whatever the heading says.

### Tone

    "The cartpole is a fine test and a poor advertisement"
      -> "A gantry crane carries a hanging load... the same mathematics as the cartpole"
    "The crane works, which makes it a poor teacher."
      -> "The crane example succeeded on the first serious attempt. This one did not."
    "That is not a flare. It is a solver re-deriving from scratch."
      -> "That is a solver re-deriving its answer from scratch."
    "It came in at a thousandth."
      -> "The residual swing came in at a thousandth of the PD's, against a bar of a tenth."
    "the answer turned out to be one thing rather than the several I kept proposing"
      -> "The answer turns out to be a single property, and the ablation at the end isolates it."

### First person, swept

Five instances in prose. **Three stay**: "Part I", and two rhetorical *"if I apply this torque"*
constructions that put the reader in the driver's seat rather than the author. Two were diary and
are gone —

    "It was not being able to read my own code"
      -> "The rewrite was prompted by readability rather than by a failing test"

    "the deciding clue was two of my own runs disagreeing"
      -> "The deciding clue was two runs disagreeing at identical settings."

★★ IN BOTH CASES THE LESSON SURVIVED INTACT. Readability is a sufficient reason to rewrite; two
runs disagreeing at identical settings is the finding rather than noise. **Only the ownership of
the anecdote was removed.**

## ✅ Pass 11 — sections 2 to 9 and 24 to 29, plus a structural check

### Tone

    "Storing the 10 is not just a memory saving — it makes..."
      -> "Storing the 10 saves memory, and it also makes..."
    "The side the increment applies on is the whole game"
      -> "...decides the meaning"
    "the rarest thing in zimr"                  -> removed
    "The direction also needs saying out loud." -> "The direction is worth stating explicitly."
    "The name matters."                         -> "The name is dotSpatial because..."
    "It is general, elegant, and what most engines do."
      -> "It is general, and it is what most engines do."
    "A clever answer, and the question was wrong"
      -> "The answer was correct for the question asked, and the question was wrong"

★ THE LAST ONE IS THE SAME EDIT AS EVERYWHERE ELSE: "clever" is the writer's verdict on the
result. **Saying what actually happened — the optimiser answered the question it was given — is
both more precise and less pleased with itself.**

### A structural check worth having

Wrote a script rather than reading: extract every `id="sN"`, every `href="#sN"`, every heading
title and every nav title, and compare.

    anchors: 45   refs: 45   broken: none
    nav/heading mismatches: 1   (§10 head "Phase 1: forward kinematics", nav "Forward kinematics")

★★ FIVE PASSES OF RENAMING PRODUCED EXACTLY ONE DRIFT, and it was invisible to reading because
the two strings sit 1400 lines apart. **This check should run whenever a heading changes** —
`doc-sync` verifies code against source and has no opinion about the page's internal consistency,
which is the gap this fills.

### Flourish vocabulary, swept

"elegant", "clever", "neat", "the whole game", "turns out" — five occurrences, four removed, one
("turns out") left because it reads as ordinary English rather than as a reveal. **"The entire"
appears eight times and all eight are correct**: they mean the whole of something, not emphasis.

## ✅ Pass 12 — a continuous read, which finds what section-by-section editing cannot

Reading each section in isolation for eleven passes missed things that only appear in sequence.
Extracting **every section's opening sentence into one list** made them visible immediately.

### Five sections opened with the same word

    20  Everything up to here has been smooth...
    24  Everything so far has been about models written in Zig...
    28  Everything in §19, plus:
    36  Everything above, as it is actually written.
    40  Everything so far optimises a fixed horizon...

★ NONE OF THESE IS WRONG ON ITS OWN. Together they are a formula, and a reader moving through the
page feels it even without being able to name it. Each now says what its own section is about —
"The dynamics so far have been smooth", "The models so far have been written in Zig", "The same
recursion as it is actually written", "The optimiser so far solves a fixed horizon".

★★ §28 KEPT ITS "Everything in §19, plus:" because that one is literal: it is a capability list
that genuinely extends another capability list.

### Measurements rather than impressions

    paragraphs        319, median 39 words, longest 107, none over 110
    em-dashes         168 in 13,054 words = 1 per 77, no paragraph with 3+
    sentence starts   "That is" x27, "It is" x25, "This is" x8

**The first two are healthy** and needed nothing — worth measuring rather than guessing, since
"too many em-dashes" is a common complaint that turned out not to apply here.

**"That is" x27 is a real tic**: the summarising verdict. Most are legitimate — a summary after a
derivation is standard technical writing — so only the five weakest were changed, where the
phrase carried no content: *"That is what Softness is"* became *"That describes Softness"*,
*"That is the whole routine"* became *"The routine ends there."*

★★★ THE LESSON FOR THE REMAINING PASSES: **some faults are only visible in aggregate.** Extract
one feature across the whole document — first sentences, paragraph lengths, sentence openings —
and read that list instead of the prose. It takes a minute and finds what a careful read of each
section separately cannot.

## ✅ `readme.html` — the robot simulator was missing entirely

`grep -c "robot.zig" src/web/readme.html` returned **0**. The section is titled "The physics
engines" and opened "Two of them" — an engine with a 13,000-word course behind it was not
mentioned anywhere on the project's landing page.

Added one paragraph after the 2D engine, in the readme's own register: dense, factual, source
paths in `<code>`. It leads with **what makes it a different kind of engine** rather than with a
feature list — the other two carry full poses and enforce joints with a solver; this one uses
generalized coordinates, so the joints cannot be violated because the freedom to violate them was
never represented. Then the MuJoCo lineage (CRB, `LᵀDL`, RNE, PGS/Newton on a complementarity
problem), the joint and equality types, MJCF import, `robot_mpc.zig`, and the bridge that means
collision detection is written once.

### Two things the check caught

**The intro said "Two of them."** Adding a third engine to a section that counts them means
updating the count — now "Three of them... Two are general rigid-body engines in maximal
coordinates; the third is an articulated-robot simulator in generalized coordinates", which also
gives the reader the taxonomy before the details.

★ **A LINK TO THE TUTORIAL WOULD HAVE 404'd.** `src/notes/tutorials/` is not staged into the web
output — only `src/web/*.html` and a short explicit list in `build.zig` are. The readme's one
existing doc link points at `tutorial.html`, which lives in `src/web/`. Replaced with the path in
`<code>`, matching how the readme names other source files.

Verified by building through the highlight pipeline (`zig build readme`) rather than by reading
the source: the paragraph survives into `zig-out/web/readme.html` at 121,953 bytes, and tier-a
is green.

## ✅ The walkthroughs are now staged and reachable

`build.zig`'s web page list gained six standalone pages from `src/notes/tutorials/`, staged flat
so the readme's links stay relative:

    robots.html  mujoco-tutorial.html  gpu-compute-tutorial.html
    rtt-tutorial.html  shader-authoring-tutorial.html  wgpu-ports-tutorial.html

Only these six ship — **not the whole notes tree**, which is working material rather than
documentation. `gpu_compute_tutorial.html` was skipped: byte-identical to the hyphenated one
(same md5), so staging both would ship the same page twice under two names.

A new **Long-form walkthroughs** section in the readme lists them with a sentence each, and the
robot paragraph's `<code>` path became a real link.

### Three things the checks caught

**1. A duplicate `id`.** The readme already had `<h3 id="walkthroughs">More walkthroughs: the 2D
and UI side</h3>`, and I gave the new section the same id. ★ MY FIRST ANCHOR CHECK MISSED IT
because it tested that every `href` had a target, not that every target was unique. **A set
lookup cannot see duplicates** — counting is a different question from membership. The new
section is `#docs`.

**2. A pre-existing dead link.** Verifying the links against the *shipped output* rather than the
source found `tutorial.html` broken: the readme has said "New to graphics? start with the
from-scratch tutorial" for a long time, and the file exists at 71 KB in `src/web/` but was never
in the staging list. Now staged, and the sentence works.

**3. Nothing else.** Eight relative links in the shipped readme, all resolving.

★★ THE TEST THAT FOUND TWO OF THESE: parse the built `zig-out/web/readme.html`, extract every
relative `.html` href, and stat each one in the same directory. **Checking the source would have
found neither** — the source has no opinion about what gets installed.

## ✅ `claude.md` — 2153 → 1743 lines (19%), 20.9k → 17.5k words

Nothing was dropped for being an anecdote alone. **Every cut was either duplication, a
contradiction, or narrative around a lesson that survived.**

### Duplication, which was most of it

**Three sections on disk and the zig cache**, at lines 70, 881 and 1914, giving *conflicting*
advice: one said "Never prune `.zig-cache/o` partially — full wipe or nothing", another shipped a
script that prunes it. Merged into one, keeping the later (evolved) rules and the headroom
numbers from the earlier. **81 lines → 38, and a contradiction removed.**

**Four pairs of lessons that were the same lesson twice**, all from this session's robot work:

    MERGING TWO SIMILAR FUNCTIONS + WHEN TWO FUNCTIONS CONVERGE   -> one entry
    INTEGRATOR NEEDS A SETPOINT  + INTEGRATOR ON A NEVER-ZERO ERROR -> one entry
    A MODE SELECTOR MUST SET     + A MODE THAT DEPENDS ON A POSE   -> one entry
    MEASURE A DEMAND AS A FRACTION + EXPRESS A RESULT AS A FRACTION -> one entry

★ THE FIRST PAIR WAS ONE INCIDENT WRITTEN UP TWICE — once for the refactor and once for the bug
it caused. Together they read better: both risks are real, and the entry now says so.

**Three entries in "Sharp edges" were byte-identical duplicates** of entries above them.

**Two more copies of the cache-pruning advice** inside "Build & disk economics", now pointing at
the merged section instead.

### Grouping, which bought the rest

Thirteen individual lessons became two grouped sections:

  * **MEASUREMENT DISCIPLINE** — 7 entries, 106 lines → 38. Sweeps that must reverse and stay in
    range, baselines checked and re-swept, the cost column, the flat sweep, two runs disagreeing.
  * **PROBES AND HARNESSES** — 6 entries, 89 lines → 27. Stale binaries, asserted replaces, probes
    that build the wrong scene, the fifth edit, contaminated harnesses, unit oracles.

★★ THEY READ BETTER GROUPED. Each was a full section with its own incident; as a bulleted rule
with one measurement each, the cluster is scannable and the relationships between them are
visible — "a flat sweep says the parameter is not the cause" belongs next to "a sweep must run
until it reverses".

### Narrative removed, lesson kept

  * **WebAudio** (51 → 13): the lesson is "a green smoke run is no evidence that a host namespace
    exists, because smoke supplies the very import the browser lacks". The other 38 lines were an
    inventory of a fix already made.
  * **The arena bug** (55 → 17, four sections → one): the rule, why "never store an arena by
    value" is the wrong statement of it, and why a leak report names the victim rather than the
    mechanism.
  * **The cold-cache walkthrough** (88 → 75): it documented its own supersession twice — round
    counts, then "these are now pessimistic", then "the old rule said X, that is FALSE". Now
    states current fact; the ground rules and steps are untouched.
  * **The plan index** (67 → 28): per-plan detail duplicating the plan files that the section
    itself calls the source of truth. It also said "Next step: phase 0" for a phase finished long
    ago with a course written about the result.

### Verified

Every merged section checked for its key facts afterwards — the prune rules, the arena rule, the
0.20 cone fraction, the 10% efficiency, the 5.2x free win, the SCCP 44%. No duplicate headings, no
orphaned fragments, lint green.
