# zimrnum - plan v2

Plan v1 is `src/notes/archive/zimrnum_plan_v1.md`: 5678 lines, the full study of znum, the staged
port, and a turn-by-turn journal. Nothing here replaces it as a record - this is what a reader
needs to carry forward, and what is left to do.

---

## 1. Where things stand, measured

| | |
|---|---|
| zimrnum public declarations | **354** |
| tests | **127** zimrnum, **170** zimrmath, 222 raster, 7 easings |
| GPU sweep | **98 rows**, 86 kernels, 95/98 last device run then all green |
| tutorial | 638 KB, 19 sections, 94 subsections |
| element-type guards | `requireFloat` 169, `requireNumeric` 51, `requireInt` 15 |
| znum coverage | **152 of 549 user-facing functions (27%)**, allowing for deliberate renames |

The coverage number is honest but not the point. znum is the reference implementation; the goal is
to **match it and then beat it**, function by function, with the difference written down.

---

## 2. The standing rules

These are not preferences. Every one of them was learned by something breaking.

### Follow znum, then beat it - and check the claim either way

**Read znum's implementation before writing yours.** Not its signature, its body. Twice in recent
turns reading it changed the design: its cartpole uses semi-implicit Euler where Gym uses explicit
(matched, not improved), and its `categorical` subtracts the max before exponentiating - which
demolished my reason for diverging.

**A claim about the code you are replacing needs the same evidence as a claim about your own.** I
wrote in three places that znum's sampler would overflow at logits of 800. It does not. The
divergence was withdrawn and znum's method restored.

**When you do diverge, the register row says why, with a measurement.** "Cleaner" is not a reason.
`polyakUpdate` uses the affine form because the lerp form loses the value at `follow = 1` on a
target of 1e8 - measured, not asserted.

**And say when znum is ahead.** It steps 1024 cartpoles in one GPU dispatch; `polyakUpdate` runs
through an existing kernel there and has no GPU path here. Row 62 records the half still open.

### The tutorial is part of the change, not a follow-up

`src/notes/tutorials/zimrnum-tutorial.html` is generated-checked: `zig build zimrnum-ref` regenerates
the reference table, and a test asserts it matches the public surface. **A new public declaration
without a note fails the suite.**

- Every batch gets a tutorial section in the same turn, under the right `h2`.
- Section order is dependency order: foundations, operations, composition, systems. Autograd
  precedes the layers built on it. Do not append to the end of the file - find the section the
  material belongs to.
- The section explains **why**, not what. The reference table already says what.
- **Every `zn.foo(...)` in the tutorial has its ARITY checked** against the real signature, and a
  mismatch fails `zig build zimrnum-ref`. 289 calls. A source fold proves the NAME resolves; it
  says nothing about how the example CALLS it, so an example could keep folding after a signature
  changed - reading plausibly and costing a reader an hour.
- **Assume no pandas, no PyTorch, no ML background.** The reader is a systems programmer who wants
  numbers to come out right. Lead with the PROBLEM in ordinary terms - "a column holds repeated
  values from a small set, and you want small integers instead" - then the API, then the choice,
  and put the comparison to another library in its own "If you know pandas" paragraph at the end.
  A section that opens with `factorize` and `levels` has already lost half its readers.
- Jargon that is used must be introduced once. Audited: `advantage`, `logits`, `softmax`, `policy`,
  `rollout`, `residual`, `embedding` are all explained somewhere; `DataFrame`, `dtype` and
  `one-hot` appear only inside folded source, which is fine.
- **Removing a public name means three places**: the source, the reference rows, and the
  hand-written sections. Only the first two are gated. When a type goes, grep the tutorial for it -
  `Scope` left two whole sections, two toc entries and a code sample behind.
- After editing, check for dangling `href="#..."` and that every `h3`'s number matches its `h2`.

### The GPU sweep is the only device evidence

`examples/zimrnum_field/` - kernels in `zn_unary.zig` / `zn_binary.zig` / `zn_matmul.zig`, rows in
`zimrnum_field.zig`, entries registered in `build.zig`.

- **A kernel with no row is a compile error.** Keep it that way.
- **Write a headless twin before adding the row**, and *construct its params the way the host
  does*. A twin that picks its own parameters verifies a dispatch that never happens -
  `slice_columns` divided by the output width in my twin and by the field width in the sweep.
- **A twin cannot see a library difference**, only an algebraic one: it compiles the kernel for the
  host, so `@sin` is the host's on both sides. A kernel calling a transcendental needs a ULP bar
  (16), not a zero one. Pure addressing gets zero.
- **Check the output buffer size.** Twice now a kernel has written past it - `mesh_grid` and
  `cartpole_step` - and both times every unit test passed and the smoke caught it.
- Budget: 98 rows x 6 settle frames = 4.90 s against a 6 s limit. About twenty more rows fit.

### The gates are build steps now - stop typing command lines

    zig build gate                              lint + fmt --check + check + all fast tests
    zig build smoke-test -Dfocus=zimrnum_field  one smoke (needs a focus, so not in `gate`)
    zig build zimrnum-ref                       regenerate the tutorial reference table

**`test-fast` now includes `zimrnum.zig` and `zimrmath.zig`.** They were not in it, so the only
way to run those 127 + 170 tests was a hand-typed
`zig test --dep zm --dep kompute -Mroot=... -Mzm=... -Mkompute=...`. A gate you have to remember
the command line for is a gate that gets skipped - and the one time it was skipped this session,
the reference table had drifted.

Verified by breaking a zimrnum test and watching `zig build test-fast` return non-zero.

### `catch unreachable` is a smell, and most of them were avoidable

The file had **109**. Cholesky's inner loop read

    acc -= (out.at(&.{ i, k }) catch unreachable) * (out.at(&.{ j, k }) catch unreachable);

`at(indices: []const usize)` fails for two reasons, and **only one is real**:

1. `indices.len != rank` - exists ONLY because a slice hides its arity. The call site writes a
   literal `&.{ i, j }`; the compiler could know it is two, and does not.
2. `i >= shape[axis]` - a genuine bounds check, **and Zig already has a name for it**: it is what
   `data[idx]` does. Panic with a message in Debug and ReleaseSafe, ordinary UB in ReleaseFast.

Nobody writes `arr[i] catch unreachable`. So:

- **`at1`/`setAt1`, `at2`/`setAt2`** - the arity is in the name, so check (1) is gone at comptime
  and (2) lands on `data[]`. Cholesky went 6 -> 0 and now reads like the textbook.
- **`offsetOf(indices)`** - no error, for a coordinate whose rank and bounds you have already
  established. The 45 `flatIndex(walker[0..rank]) catch unreachable` sites were all of this shape:
  two impossible checks on the hottest line in the library.

**109 -> ZERO.** Every `catch unreachable` in zimrnum's code is gone; the three matches left in
the file are the words inside these doc comments. The safety is unchanged - verified by reading out
of bounds and getting `index out of bounds: index 15, len 6`, a real panic with a real message.

The conversion was mechanical but not blind. Three regexes went wrong and each was caught by the
compiler within one command:

- an optional `\)?` in the pattern ate `setAt`'s own closing paren
- `@abs(a.at(...))` became `@absa.at2(...)` - the builtin's opening paren was consumed
- a balanced-paren walker rewrote a `try setAt(...)` that had no `catch unreachable` at all

**None of them could reach the test suite**, which is the argument for doing this kind of sweep
with a compiler rather than by eye: a regex over 300 call sites will be wrong, and the only
question is whether the wrongness is loud.

WARNING: This matters beyond tidiness. A reader deciding whether Zig is usable for numeric work looks at
an inner loop, and `catch unreachable` twice per line is the single thing that makes it look worse
than it is.

### Two ways I wasted a turn, both worth avoiding

**A reference constant has to come from a computation, not from a display.** I read
`std 39.625329` off a six-decimal print and typed `39.62532855824495` into the test - eight digits
I invented. The test failed; the exact value is 39.625328600109640 and zimrnum was right all
along. **The bar was wrong, not the code**, which is the same shape as the cartpole pole-recovery
case but with a fabricated number instead of a fabricated intuition.

**Grep before believing the roadmap.** Three consecutive blocks - serialisation, optimisers,
linalg - were listed as missing and were largely already implemented. The roadmap had been built
from znum's function names, not from reading zimrnum. One `grep -cE "pub (fn|const) NAME"` per
name would have caught all of it, and now has: section 3 is measured rather than assumed.

**Check for an existing helper before writing one - this happened TWICE in consecutive turns.**

1. I wrote `quantileOfSorted` when `quantileSorted` had been in the file for months, with better
   handling and an error union for the `q` range. The linter found it, by complaining about
   `@intFromFloat` in code that should not have existed; the fix was deleting 900 bytes.
2. The linter rejected `std.math.maxInt` in `RowPair.no_row`, and I substituted `zm.highest` -
   the max-reduction identity, which for an integer happens to equal `maxInt`. **`zm.maxInt` was
   already there.** Right value, wrong meaning, and nothing would have caught it.

Both times the trigger was the same: a rejection, then reaching for the nearest remembered name
instead of grepping. `grep -c "^pub fn <name>(" src/zimrmath.zig` is one command.

While fixing (2): `maxInt`/`minInt` had **no agreement test** against `std.math`, though the rest
of the replacements do. They are computed from the bit count here, so an off-by-one shift gives a
number that still looks like a limit. Ten integer types now checked, plus the asymmetric edges,
and `zm.maxInt` verified to lower to SPIR-V.

### A Series can be a VIEW, and a view is not its buffer

`fromSlice` allocates contiguous, so `data[i]` and `at1(i)` agree and nothing goes wrong. **A
column taken out of a matrix does not agree.** Measured: the middle column of a 2x3 summed to 21 -
the first two buffer elements, belonging to a different column - where the answer is 7.

Ten sites were reading `values.data[row]`: the reductions, both fills, `dropMissing`, `takeRows`,
`describe`, `groupBy` and `joinRows`. All now go through `at1`/`setAt1`, which costs one add for a
contiguous column and is correct for any layout.

A permanent test builds a strided column and runs every one of them through it, including a fill
that writes back into the matrix at the right places and leaves its neighbours alone.

WARNING: **a fill can free the mask.** `fillForward` completing a column triggers
`dropMaskIfComplete`, so a `defer ta.free(col.valid.?)` written before the fill unwraps a null.
Anything holding the mask must re-read `valid` afterwards rather than remembering the pointer.

### Tutorial examples: one dataset a reader can hold

The dataframe sections used bare `10 20 30` keys. They now carry one scenario through - five play
sessions with a level and a score - so `groupBy`, `aggregate` and `describe` all operate on the
same table the reader already has in their head, and `join` uses players and purchases where the
duplicate key is one player buying twice.

The point is not decoration: **`10 20 30` makes a reader parse the mechanism before the meaning**,
and for a join's duplicate-key behaviour the meaning is the whole lesson.

### The arity check, and the three things it got wrong first

Adding it found one real staleness and two bugs in itself, which is roughly the expected ratio:

1. **`zn.pow(-2, 3)` in prose.** Not a call - an illustration of a value - but wearing the `zn.`
   prefix it implies a signature. Dropped the prefix; the checker was right.
2. **`zig fmt` puts a TRAILING COMMA on multiline parameter lists**, so `commas + 1` counted one
   parameter too many for exactly the declarations this file is full of. Counting segments that
   contain something is immune.
3. **A comma inside a string is not a separator.** `zn.einsum(f64, "ij,jk->ik", out, .{a, b})`
   has four arguments and five commas, and a character scanner that does not know about quotes
   accused a correct example.

Verified to FIRE by removing an argument from a real example and watching the build fail.

### Verification

- The bar comes from a measurement, never from a hope. Record the number in the test.
- Assert the property the thing exists for, not its arrangement. Pre-norm is checked by measuring
  that no input gradient collapsed, not by reading where the norm sits.
- A test whose input is too narrow passes a broken implementation. Four buckets hid a sampler bug
  that forty found; an all-positive gradient probe would have passed `elu`, which is the identity
  there. **A branching function needs inputs on both sides of the branch**, and reusing a probe
  built for another function's domain is how that gets missed.
- **Constant folding is a different machine.** If the claim is about float or integer arithmetic,
  the operands must come from memory. Three separate bugs hid behind comptime-known literals.
- Every new function runs at `f64` *and* at `i32` if it claims `requireNumeric`.
- Gradients go against central differences. A piecewise backward needs a non-zero assertion too,
  or it passes against one that returns zero everywhere.

### zimrmath

- **Add only what is needed.** Every gap is a workaround somewhere else - the lint bans `std.math`
  outside it, so a missing function becomes an inline hand-roll at the call site.
- **Everything works on scalars (bias f32), on vectors, and in a shader.** The house pattern is
  `anytype` plus a `@typeInfo(T) == .vector` branch; `perLane` and `splatLike` are the tools. A
  function taking `comptime T` and comparing `x == 0` does not compile on a `@Vector`.
- When a replacement exists in `std.math`, the test compares against `std.math` itself. Agreement
  with the original is the whole specification.

### Forming the 1 loses everything - three times now

`log(1 + small)` returns exactly 1's logarithm, which is 0, as soon as `small` falls under the
epsilon of 1. That has cost this library three separate values:

- `log(softmax(x))` - a value 110 below the row max softmaxed to 0, logarithm `-inf`
- `softplus(x)` - **exactly 0 from x = -50** where the answer is 1.9e-22. znum's has this too
- `logSumExp` - avoided from the start, which is why it was the model for the other two

**`log1p` and the max-subtraction are the two fixes**, and a new function that forms `1 + small`
or `exp` of anything unshifted should be suspected before it is written.

The pattern matters when the small term IS the answer, not when it corrects a large one. Swept the
file for it: `binaryCrossEntropyFromLogits` has the same shape and is FINE, because there the
correction falls below the ulp of `max(x,0) - x*t` before it underflows. Measured rather than
assumed either way.

### When the reference library does something odd, find out why before diverging

znum and pandas both code `factorize` by first appearance. I wrote it sorted, claimed sorting was
better, and recorded a register row saying so. The argument had a hole: **my failure case needs the
encoder to be re-derived at serving time**, and a pipeline that persists the levels - which the
function returns them for - is reproducible under either order.

pandas' actual reasons: first-appearance needs only EQUALITY, so it works on strings and objects;
it is the cheaper pass; and **pandas offers both** through `sort=True` rather than claiming one is
correct.

The outcome is better than either: a required `CodeOrder`, which is the seventh named argument in
this file for the same reason - both answers defensible, wrong one silent.

**"Their choice looks wrong" is a hypothesis, not a finding.** Same shape as the `categorical`
withdrawal: a claim about the code you are diverging from needs evidence.

### The correspondence gate checks names, not values

It asserts every tensor op in `paired` has a zimrmath function of the same name. **`pow` disagreed
with `zm.pow` on negative bases** - `exp(y*log(x))` is NaN where `zm.pow(-2, 3)` is -8 - and
nothing would have reported it. Pairing by name is a spelling check; a test has to compare answers.
One exists now for `pow`, and a second sweeps **all thirty unary names** - 360 comparisons over a
probe that deliberately leaves several domains, since a sweep over pleasant inputs is the kind that
passed `pow` for as long as it was wrong.

A third covers the four remaining names - `atan2Rad`, `hypot`, `clamp`, `lerp` - which is the
group `pow` came from. Two operands means more ways to disagree, so the probe is **deliberately
not symmetric** (argument order), includes an **inverted clamp range**, and takes `lerp` outside
[0, 1] where it extrapolates.

**All thirty-five paired names are now checked by value. Result: `pow` was the only divergence.**
That is worth as much as a find - the pairing can be relied on, and the sweeps are the control
against it drifting.

Every one was verified to FIRE: the unary sweep by perturbing an implementation by 1e-7, the
non-unary one by swapping `atan2`'s arguments. **A test that has never been seen to fail is not yet
a test** - and the first control attempt did not even apply, which the assert caught.

### Memory: the caller owns the arena

`Scope` was removed. The idiom is a stack `std.heap.ArenaAllocator`, `defer arena.deinit()`, and
`arena.allocator()` at the point of use - three lines, the same as the wrapper, with one fewer heap
allocation and no indirection.

A struct that must own an arena takes an **out pointer**: `init(gpa, s: *State)` writes
`s.arena = .init(gpa)` and mints the interface from there, so nothing moves after the interface
exists. That is Zig's answer and it is safer than a movable wrapper, not merely simpler.

**Do not cache an `Allocator` across a move of the value that made it.** Measured: a by-value arena
moved with the interface re-minted passes; with the interface cached it **aborts**. Re-mint.

### Angles

**Turns for angles that are drawn, radians for angles that are differentiated**, decided per piece
of state, and the name always carries the unit - `pole_rad`, `phase_turns`, never bare.
`d/dtheta sin(theta)` is `cos(theta)` only in radians; in turns every derivative picks up a tau, and that
conversion is a place to be wrong.

---

## 3. What remains

Measured against znum's **527 user-facing functions**: 183 present (34%), 344 absent. But that
number is misleading, and the split matters more than the total.

### Of the 344, about 90 are not gaps

| kind | count | why |
|---|---|---|
| Dispatch plumbing | 7 | `binaryOp`, `unaryOp`, `scalarOp`, `compareOp`, `foldScalar` - `map`/`zip` plus comptime is how we do this |
| Scalar variants | 10 | `addScalar`..`geScalar` - one `affine` and one `compareScalar` with a named `Comparison` replace all ten |
| Activation gradients | 5 | `eluGrad`, `geluGrad`, `siluGrad`, `softplusGrad`, `mishGrad` - **the tape provides these**; every activation now has a node |
| znum test fixtures | 6 | `actor`, `critics`, `XorMlpF32` and friends are its own test scaffolding |
| `dimnames` | 20 | `Named` is 60 lines where this is 3302. **Row 19 still owes the check** that those 20 do nothing `Named` cannot |
| `xf` | 10 | Forward-mode versus the tape. A DECISION, not a gap - see the turn below |
| GPU/scope plumbing | ~30 | `Ctx`, `BufferUsage`, device buffers - we solve this differently, and `Scope` was deleted on purpose |

### RL algorithm parity, enumerated

znum's `rl` namespace is 108 functions and 37 types. The **algorithms** in it, checked one by one:

| algorithm | znum | zimrnum |
|---|---|---|
| PPO | `ppoUpdate`, `ppoLoss`, `clippedSurrogate` | `ppoObjective`, `ppoClipLoss`, `PpoConfig`, `PpoStats` |
| GAE | `gae`, `computeAdvantages`, `normalizeAdvantages` | `gae`, `RolloutStep` |
| REINFORCE | (in the examples) | trains, 5 seeds |
| DQN | `dqnUpdate` | `dqnTarget`, `DqnKind`, `Transition` |
| TD3 | `td3Update` | `sacTarget` with `alpha = 0` IS TD3's target; twin critics via `CriticAggregate` |
| SAC | `sacUpdate`, `Temperature` | `sacTarget`, `Temperature`, `aggregateCritics` |
| **DroQ** | dropout critics | `CriticAggregate` takes a SLICE - M dropout passes are M estimates |
| **REDQ** | (not in znum) | `randomSubset` - M of N, re-drawn each step |
| **CrossQ** | LayerNorm, no target | a one-element slice; the caller simply passes no target estimates |
| Polyak averaging | `polyakUpdate` | `polyakUpdate` |
| Distributions | Categorical, MultiCategorical, Bernoulli, DiagGaussian, SquashedGaussian | Categorical, DiagGaussian, SquashedGaussian |
| Diagnostics | `explainedVariance`, `klGaussianDiag` | `explainedVariance` |
| Buffers | `ReplayBuffer`, `RolloutBuffer`, `BinSampler` | none - the caller owns its storage |
| Environments | cartpole, cartpoleCont, reacher | cartpole (+ batched, + a GPU kernel) |

**The algorithms are now all reachable.** The unifying observation, which znum makes too: the
critic estimates arrive as a **SLICE, not a pair**. Twin critics pass two, DroQ passes M dropout
passes of one network, REDQ passes a random subset of an ensemble, CrossQ passes one and no target
at all. One `sacTarget` covers every variant, and `alpha = 0` is exactly TD3.

**zimrnum reaches REDQ, which znum does not** - `randomSubset` is a partial Fisher-Yates, so the
subset is re-drawn each step rather than fixed.

What remains is not algorithms but **plumbing**: a `ReplayBuffer`, and a driver that runs the
update. `MultiCategorical` and `Bernoulli` are thin over `Categorical`; `klGaussianDiag` is a
closed form.

### The road to parity - `src/notes/znum_mapping.md` is the ledger

**Parity means: every user-facing znum function has an equivalent here, or a register row saying
why not.** Nothing else counts as done.

| | |
|---|---|
| znum numerics surface | 628 |
| present in zimrnum, incl. renames | 346 |
| **missing, every name read** | **130** |
| misattributed by the scanner, triaged below | 152 |

The 152 turned out to be three things, none of them a gap:

- **~70 GPU plumbing** - `createBindGroup`, `dispatch1D`, `readBuffer`, `packUniform`,
  `unaryKernelName`. znum dispatches kernels from inside the library; zimrnum compiles them as a
  separate artifact and the sweep is the interface. **Not parity work, by design**
- **~20 znum test fixtures** - `predictXorF32`, `tanhSumLoss`, `geluSumLoss`, `targetCritics`
- **~60 Tensor constructors and methods** - `zeros`, `ones`, `full`, `eye`, `arange`, `linspace`,
  `numel`, `item`. **These ARE real**, and the scanner missed them because it only reads
  column-zero declarations while zimrnum has them as methods or not at all

So the honest target is **130 + about 25 constructors = ~155 functions**, and the turns below
account for every one.

### The sweep waits for its own dispatch now, not for six frames

The settle count was **six fixed frames per row**, and its own comment admitted the number came
from the time budget rather than a measurement - because there was no way to ask which dispatch a
readback belonged to. It had been wrong twice: three frames held for 86 rows and failed at 91,
with another row's data arriving as `inf` against a bar of zero.

`Compute.readGeneration()` answers the question. It reports `submitted` and `mirrored` - dispatches
on the queue, and dispatches the mirror reflects. The harness records the count after its dispatch
and retires the row when the mirror reaches it. **Never early, never a frame longer than
necessary**, and it does not move with row count or with what else the browser is doing.

⚠ **FIRST DEVICE RUN: 7 of 105.** `inf` and `88.76` against bars of zero - the exact signature of
another row's data that the settle comment describes.

The cause: there are TWO places a dispatch reaches the queue, batched and direct, and I incremented
the counter at one of them. The sweep uses `run()` outside a batch, so `submitted` stayed at zero,
`mirrored >= wanted` was `0 >= 0`, and every row retired on its first frame before its own dispatch
had executed. Seven passed by luck.

**A counter maintained at N call sites will be wrong the first time someone adds the N+1th** - and
it is worse than no counter, because the fixed wait it replaced at least erred toward being late.
So it is not two increments now: both sites call one `submitDispatch(gp, cmd)` helper that submits
and counts, and the readback copy deliberately does not.

Frame order verified rather than assumed: the harness dispatches, THEN polls, and the generation is
read after the poll - so the frame that completes a copy also retires the row. **Two frames per
row, not six**, and the device run is what confirms it.

WARNING: NOT five rows per frame, which was the first idea. The rows share one output buffer per
pipeline kind, so they would overwrite each other - precisely the failure the settle count existed
to prevent. Pipelining the wait is the safe version of the same win.

Three notes worth keeping:

- `copy_at` stamps the dispatch count when the copy is ENCODED, not when it completes. Anything
  submitted afterwards is not in that copy, and recording the wrong one of those two is the bug
  the counter exists to prevent
- `Generation` is a NAMED type. Anonymous structs are distinct per `Compute(M)` instantiation and
  the sweep holds three pipelines; the error names two generated type names and is not fun to read
- On CPU and worker backends both counters are zero, so `mirrored >= wanted` is immediately true
  and the row retires at once. Correct, and no special case at the call site

### Next: an output ring, for 0.5 s - and FOUR SLOTS ARE ALREADY FREE

With the generation wait the sweep costs 2 frames per row: dispatch and encode the copy, then the
copy lands and the row retires. 105 rows = 210 frames = **1.75 s**. To reach 0.5 s the rows have to
share frames, and they cannot today because they share one output buffer.

**The finding that makes this cheap:** `config.max` is `1 << 14` = 16384 floats and a row uses
64 x 64 = 4096. **Four slots already fit in the buffer that exists.** No resize, no extra memory -
105/4 = 27 dispatch frames plus a drain, about 0.25 s.

The mechanism needs no kernel changes and no wgpu changes:

- `gpu.BindGroupEntry.Resource.buffer` **already carries `offset` and `size`** - checked
- So: `ring` bind groups per kernel instead of one, the `out` entry's offset set to
  `slot * stride`. `bout[id]` then lands at `offset + id` with the kernel none the wiser
- `run(name, n)` gains a slot; `bind_groups[ki * ring + slot]`
- One `copyBufferToBuffer` of the whole ring gives four rows' results per readback

⚠ **What does not exist yet:** the generic compute layer has no notion of WHICH field is the
output. It iterates `buffer_field_names` uniformly and binds every one at offset 0. A convention
(`out` by name) or a module declaration (`pub const ring_field = .out`) has to come first.

That is why this is its own turn rather than a tail-end addition: it is the init path of
`compute_host.zig`, which every GPU example depends on, and it needs device verification of its
own. **A speedup on a test page that runs in 1.75 s of a 6 s budget is not worth breaking
`fluid_gpu` for.**

### A caller-supplied `out` may be a VIEW, and new code keeps forgetting

`rfftfreq` and `histogramEdges` wrote `out.data[k]` directly. `out` comes from the caller and may
be a strided column of a matrix - so the values would land in whichever column the buffer starts
with. **The exact bug the `Series` work found, arriving in code written after it was recorded.**

Both write through `setAt1` now, and a test hands one of them the middle column of a 5x3 grid and
checks the neighbours are untouched.

The rule, since it has now come up twice: **anything that writes into a tensor it did not allocate
goes through `setAt1`/`setAt2`/`offsetOf`.** Writing `data[i]` is only safe for a buffer you just
allocated yourself - which is most constructors, and nothing else.

### The reference table showed `varianceAxis(` and nothing else

`declSignature` read ONE LINE of the declaration. The `fn-args-multiline` lint rule requires one
parameter per line for anything with three or more, so **most of this library's declarations span
several lines** - and the Signature column showed an opening bracket for every one of them.

The rule this file has been satisfying all along was breaking the table it generates, and nothing
noticed because the column was never checked for content, only for existence.

Fixed: the scan walks forward to the `{` that opens the body, tracking paren depth so a `&.{ ... }`
default does not stop it early, and collapses whitespace. Two seams needed tidying afterwards - a
space after the opening `(`, and `zig fmt`'s trailing comma becoming `, )`.

**All 511 rows verified**: none ends in `(`, none has an unclosed paren, none contains `( ` or
` )`. That check is worth keeping - it is the one that would have caught this years earlier.

### The tutorial's two structural additions

**3.1 A complete program.** Fits a line to noisy data and reports the loss before and after -
a tensor, a layer, a tape, a gradient and an update in forty lines. It is `examples/zimrnum_hello.zig`
and `zig build zimrnum-hello` runs it, so the output the section quotes is the output it produces:
loss 9.4206 to 0.0070, slope 3.054 against a true 3.0.

**An example printed in a document and compiled nowhere is a claim.** This one is a build target,
so a signature change breaks the build rather than the document. It also has to pass the house
lint rules, which is why every local in it carries a type.

**19 Recipes.** Tasks rather than functions, in five groups - getting data in and out, columns with
gaps, working with a table, training a model, running on the GPU. Each row links to the section
that explains the pieces.

A check worth keeping: every `href="#anchor">N.M</a>` in the document is now verified against the
heading it points at. That caught two wrong section numbers and a link to a section that does not
exist, none of which a dangling-anchor check would find.

### Tutorial tone: what it is and how to use it, not how it was built

The tutorial had accumulated development voice - "measured:", "the test asserts", "my first
version", "I wrote". **That belongs in this plan, not in a document someone reads to learn the
library.** A reader wants the fact, not the history of discovering it.

Swept: 26 instances of "the test asserts/checks" became statements of the property itself, plus
every "Measured:", "my first version" and first person. The `gotchas-tests` subsection - traps in
the tests rather than the code - was removed entirely: it is about writing this library, not using
it. **Those lessons live here.**

⚠ The source folds still carry zimrnum.zig's doc comments verbatim, and those keep their
development notes on purpose - they are for whoever edits the function, and they are collapsed by
default. The rule is: **prose is for the user, doc comments are for the maintainer.**

### The tutorial has a Gotchas section now - section 19

znum ships a separate 61 KB beginner tutorial with "Recipes", "Debugging & gotchas" and a
"Checklist". Mine is a 820 KB reference with no such collection: every trap was findable only by
reading the section it was discovered in.

Section 19 gathers them under five headings - missing data, edges and empties, numerics that lose
the value, shapes and names, and **traps in the tests rather than the code** - each linking to
where it is explained. Every entry produced a wrong answer WITHOUT producing an error during this
port, which is the bar for inclusion.

Still missing relative to znum's beginner doc: a **"0 - a complete program"** opener and a
**Recipes** section. Worth a turn.

### The rule for every turn from here

Each turn does four things, and is not finished until all four are green:

1. **The functions**, with znum read first and a register row for any divergence
2. **A GPU row for anything whose arithmetic can differ between backends** - a transcendental, a
   division, a reduction. Pure addressing needs none: it cannot drift
3. **A tutorial section** in the right `h2`, leading with the problem in ordinary terms, with a
   concrete example and one thing a reader would otherwise get wrong
4. **`zig build gate`**, plus both smokes and `zimrnum-ref`

### The turns, in order

| # | work | GPU | tutorial | done when |
|---|---|---|---|---|
| **1** | **DONE.** `zeros`, `ones`, `full`, `fullLike`, `zerosLike`, `onesLike`, `eye`, `arange`, `linspace`, `item`, `EndPoint`. `numel` is `size` and `empty` is `alloc` - aliases, not gaps | none needed | 4.6 "Making a tensor, and two endpoint conventions" | done: 140 tests |
| **2** | **DONE, and mostly already there.** All six comparisons exist as `equal`/`less`/`greater` etc AND already have sweep rows with a ZERO bar; `contiguous` is `materialise`; `sort` exists. The one real gap was **`astype`** - out of range is a `DomainError` because Zig's `@intFromFloat` is UB, not a wrap | already rowed | 4.7 "astype, and a case where Zig forced the better answer" | done: 141 tests |
| **3** | **DONE:** `resolveInferredShape` (the `-1`, with znum's three refusals kept), `swapaxes` as a VIEW, `stack` with the new axis. `dstack` and `repeat` remain - both thin over `stack` and `repeatEach` | none - addressing cannot drift | "The -1 dimension, and stack versus concat" | done: 142 tests |
| **4** | **DONE.** `argExtreme` with a named `Extreme`. `argExtremeAxis` and `reduceAxisOp` are NOT added: `argmaxAxis`/`argminAxis` already exist and read better at a call site than a parameterised third spelling, and `reduceAxisOp` is znum's dispatch layer | **5 rows**: `countNonzero`, `diff`, `all`, `any` at a ZERO bar; `prodAll` at 1e-3 because multiplication is not associative in floating point. **105 rows, 5.25 s of 6 s** | 9.9 "Reductions on the GPU, and which bars can be zero" | done: 143 tests |
| **5** | **DONE.** `perClassMetrics` with `PerClass{precision, recall, f1, support}` and `histogramEdges`. The rest were already there under spelled-out names: `bce` is `binaryCrossEntropy`, `nll` is `crossEntropy`, `klDiv` is `klDivergence`, `randn`/`randint` are `fillNormal`/`boundedIndex`. Remaining: `rank`, `predictedClasses` (argmaxAxis covers it) | none - all reductions over a tiny matrix | 12.10 "Precision and recall pull in opposite directions" | done: 144 tests |
| **6** | **DONE.** `rfftfreq`, `trapz`, `trapzCoords`. `isPowerOfTwo` was already in zimrmath; `gradient` exists. Remaining: `irfft` and `gradientNonUniform` | none - `trapz` is a weighted sum over a tiny series | 9.11 "Integrating a sampled function, and labelling a spectrum" | done: 145 tests |
| **7** | **PART DONE:** `shiftRows`, `rollingMean`, `Frame.rename`, `Frame.dropColumn`. `fromTensor` already existed. Remaining: `pivot`, `ewmMean`, `toTensor`, `readCsv`, and **the index family is a DECISION, not mechanical work** - `setIndex`/`loc` import pandas' most confusing concept and need a register row either way | none - all row addressing | 12.11 "Shifting and smoothing, where the edges have no answer" | done: 146 tests |
| **8** | **linalg** (8): result types `LuResult`/`QrResult`/`SvdResult`/`EighResult`, `tensordotN`, `matrixRank` | none - they call existing kernels | "What a decomposition returns" | each names its parts |
| **9** | **`eig` for non-symmetric** | none | "Eigenvalues without symmetry" - Hessenberg then shifted QR, and why the symmetric case is easier | a known matrix with a complex pair |
| **10-11** | **Optimisers and training** (25): `SGD`/`AdamW`/`RMSprop` as STRUCTS over the existing steps, `FlatParams`, `clipFlatGrad`, `Dataset`, `DataLoader`, `numBatches`, `reshuffle`, `fit` | `sgd_step_wd` row | "A training loop you do not write twice" | `fit` trains XOR with three lines at the call site |
| **12-14** | **Recurrent and conv layers** (15): `LSTM`, `GRU`, `BiLSTM`, `StackedLSTM`, `BatchNorm1d`/`2d`, `Conv2dGeneric`, `Conv2dNoBias`, `AdaptiveAvgPool2d` | `lstm_cell` row - it is four gates of sigmoid and tanh, exactly the arithmetic that drifts | "Why a recurrent layer is not a loop over a Dense" | an LSTM learns a toy sequence |
| **15-17** | **`gae`, `Categorical`, `DiagGaussian`, `SquashedGaussian`, `PpoConfig`, `PpoStats`, `ppoObjective` DONE.** All verified against znum: the same k3 KL estimator `exp(r)-1-r` (non-negative, unlike the cheap `old-new`), the same squash identity, the same clamp-in-both-halves rule. The clip's asymmetry is tested directly - improvement capped, penalty not. Remaining: `reacherStep`, and a loop that runs it | rows owed for `gae` and `ppoObjective` | 16.6 GAE, 16.7 distributions, 16.8 squash, 16.9 the PPO objective | **the mean return rises under PPO** |
| **18** | **Triage what remains.** Re-run the mapping, read every name still unmatched, and either implement it or write a register row | - | - | `znum_mapping.md` shows ZERO unexplained |
| **19** | **The GPU sweep, completed.** Every op whose arithmetic can differ has a row. Integer buffer support in the harness, so the six integer divisions can be rowed | the point of the turn | "What the sweep does not check" | budget still under 6 s, or the settle count drops |
| **20** | **The two owed decisions**: the `xf` question, and row 19's `Named` versus `dimnames` | - | one section each | a register row either way |

### Parity is turn 18, and the rest is what makes it worth having

Turns 1-17 close the named gaps. **Turn 18 is the one that makes "parity" true** rather than
approximately true: re-run the ledger, read every unmatched name, implement or explain. A number
that came from a scanner is a hypothesis; a ledger where every line has been read is a fact.

### Where zimrnum is already ahead

Not a count - these are things znum does not have or does worse, each with a measurement behind it:

- **Every activation has a tape node.** Four of znum's can be evaluated and not trained
- **`softplus` keeps its tail**: 1.9e-22 at x = -50 where znum's returns exactly 0
- **`ppoClipLoss` is differentiable.** znum's clipped objective is a scalar, so it cannot train
- **A GPU kernel calls the host function**, so the twin is not a transcription
- **The tests prove an agent LEARNS**, five seeds measured, which no numerics library claims
- **`pow(-2, 3)` is -8**, and all 35 zm-paired names are checked by value
- **The caller owns the arena** - no wrapper, no `gpa.create`, and the interface is minted where it lives
- **Aggregates keep their type.** znum returns f64 for all ten; six do not need it, and a count
  past 2^53 is not representable in one
- **No `text` column variant.** znum has one; a string column is not a tensor, and every numeric
  operation would need an arm that errors. `factorize` gives codes the library can use
- Seven named arguments where both answers are defensible: `Ddof`, `Use`, `Look`, `Push`,
  `Comparison`, `FeedForward`, `CodeOrder`

## 4. The divergence register

93 rows in v1, `src/notes/archive/zimrnum_plan_v1.md`. Every one records a place zimrnum does
something znum does not, with the reason. **New divergences append there**, and the rule has not
changed: a row without a measurement is a preference wearing a justification.

The ones worth carrying in your head:

- **31 (closed)** - `argmaxAxis` takes the index type as a second parameter. The float index was a
  limitation of the signature that read like one of the type system.
- **42** - `BatchNorm`'s mode is an argument, not a field. Forgetting `.eval()` is one of the most
  common bugs in PyTorch; on a batch of one every feature comes out exactly zero.
- **48** - `Attention`'s causal mask is an argument. Without it a model **sees the answer it is
  predicting**: loss near zero, beautiful curve, nonsense on anything unseen.
- **54** - `div` is not spellable on integers. Zig's own rule, and Zig names four.
- **57 (withdrawn)** - `categorical` is znum's method. The reason for diverging did not exist.
- **59** - turns for drawn angles, radians for differentiated ones.
- **62 (half open)** - znum's cartpole runs batched on GPU; ours now does too. `polyakUpdate` does
  not.
