# zimrnum plan v3

**The goal is not parity with znum. Parity is the floor.** znum is the reference for what a Zig
numerics library should cover; this one should be measurably better where it differs, and every
difference should have a reason written down.

v2 is in `archive/zimrnum_plan_v2.md`. It ran from 133 tests to 152 and closed serialisation, the
optimisers, the dataframe core, the distributions and five RL algorithms. What it got wrong three
times was the roadmap itself, by listing znum's names instead of reading zimrnum - so this version
opens with a measurement rather than a list.

---

## 1. Where it stands, measured

| | |
|---|---|
| znum user-facing surface | 463 |
| present in zimrnum | **360 (77%)** |
| genuinely missing | **103** |
| zimrnum tests | 152 |
| zimrmath tests | 170 |
| reference rows | 522 |
| GPU sweep rows | 105, at 1.75 s of a 6 s budget |
| GPU kernels | 92 |

The 463 excludes, with reasons: znum's GPU dispatch layer (25 entries - zimrnum compiles kernels
as a separate artifact and the sweep is the interface), its test fixtures (6), its type machinery,
and 30-odd deliberate declines recorded in `znum_mapping.md`.

**Every number above came from a script that ran this session.** Where a figure is an estimate it
says so.

---

## 2. What "best possible" means, concretely

Parity is a checklist. These five are the actual objective, and each is testable:

1. **A wrong answer is impossible to get quietly.** Every function that can fail returns an error
   rather than a plausible number. Measured: `catch unreachable` count in code is 0, and out-of-range in
   `astype` is an error where numpy wraps.
2. **The numerics survive their edges.** Not "usually accurate" but: `softplus` holds its tail to
   1.9e-22, `logSoftmax` scores a logit 800 below the max as -800, the squash correction stays
   finite where `tanh` saturates. Each has a test that fails on the naive form.
3. **CPU and GPU agree, and the bar says how exactly.** 105 rows, each with a tolerance chosen
   from the arithmetic: zero where it cannot drift, measured where it can.
4. **The document cannot lie.** The reference table, the opening program and every example's
   argument count are checked by the build.
5. **A newcomer can start.** Section 3.1 is a complete program that compiles and runs.

A turn that adds a function and none of these is a turn that added a function.

---

## 3. The work, in order

Each entry names what, why it is where it is, and what "done" means. **A turn is not finished
until: the functions, a GPU row for anything whose arithmetic can differ, a tutorial section, and
`zig build gate` plus both smokes plus `zimrnum-ref`.**

### Tier 1 - the three that change what the library can do

| # | work | n | done when |
|---|---|---|---|
| **1** | **The recurrent family.** `LSTM`, `GRU`, `BiLSTM`, `StackedLSTM`. The only block where zimrnum has NOTHING rather than something renamed - no cell state, no backprop through time. A kernel row for `lstm_cell`, which is four gates of sigmoid and tanh and exactly the arithmetic that drifts | 4 | **an LSTM learns a toy sequence task** - not a gradient check, a learning curve |
| **2** | **The training loop.** `Dataset`, `DataLoader`, `numBatches`, `reshuffle`, `fit`. Not hard, and it is what turns the library from pieces into three lines at a call site | 6 | `fit` trains XOR with three lines |
| **3** | **`eig` for non-symmetric.** Hessenberg reduction then shifted QR. Days, not hours, and the hardest single piece left anywhere | 1 | a known matrix with a complex conjugate pair |

### Tier 2 - completing blocks that are most of the way there

| # | work | n | done when |
|---|---|---|---|
| **4** | **Conv and normalisation layers.** `Conv2dGeneric`, `Conv2dNoBias`, `AdaptiveAvgPool2d`, `BatchNorm1d/2d`, and the conv gradients `conv2dGradInput`/`conv2dGradWeight`. `conv2d` exists; these are the general strides and the padding | 9 | a conv layer trains on a 2-D toy task |
| **5** | **Dataframe finishing.** `pivot`, `rolling` as a Frame method, `ewmMean`, `interpolate`, `select`, `sortBy`, `toTensor`, `fromTensor`, `readCsv`, `gatherNullable` | 12 | `pivot` round-trips against `groupBy` |
| **6** | **linalg result types.** `LuResult`, `QrResult`, `SvdResult`, `EighResult`, `EigResult`, `tensordot`, `matrixRank`. The decompositions work; these name their parts so a caller does not index a tuple | 7 | each names its parts |
| **7** | **Optimiser plumbing.** `SGD`/`AdamW`/`RMSprop` as STRUCTS over the existing steps, `FlatParams`, `zeroGrad`, `gatherGrads`, `sgdMomentumStep`, `sgdStepWd` | 7 | a four-parameter model trains without threading eight tensors by hand |
| **8** | **RL finishing.** `klGaussianDiag`, `cartpoleContStep`, `reacherStep`, `ReplayBuffer`, `RolloutBuffer.minibatch`, `Categorical.greedy`, `DiagGaussian.deterministic`, `SquashedGaussian.deterministic`/`reparameterize` | 9 | **the mean return rises under PPO**, and a SAC agent trains on the continuous cartpole |

### Tier 3 - ones and twos

| # | work | n |
|---|---|---|
| **9** | **manip and reduce.** `dstack`, `repeat`, `reshapeInfer` as a Tensor method, `logspace`, `scatter`, `unravelIndex` | 6 |
| **10** | **Losses and metrics as names.** `bce`, `nll`, `klDiv` exist under spelled-out names - add the short aliases OR a register row saying why not. `f1PerClass`, `predictedClasses` | 5 |
| **11** | **Signal, schedules, checkpoints.** `irfft`, `schedule.linear`, `linearOverFraction`, `checkpoint.save`/`load`, `randNormal`, `randIndex` | 7 |
| **12** | **Quantization.** `dequantize`, `mulQweight`. A real feature zimrnum lacks entirely, and the one place znum is doing something zimrnum has not attempted | 2 |

### Tier 4 - not functions, and they matter more than tiers 2 and 3

| # | work | done when |
|---|---|---|
| **13** | **The output ring.** Four slots already fit in the existing buffer (`config.max` is 16384, a row uses 4096). Needs a "which field is the output" notion the generic compute layer lacks. **0.5 s instead of 1.75 s**, and headroom for 240 rows | the sweep runs green on device in under 0.5 s |
| **14** | **Integer buffers in the sweep.** The six integer divisions cannot be rowed at all today - the harness is f32 only | `divFloor` and friends have rows |
| **15** | **Complete the GPU sweep.** Every operation whose arithmetic can differ. `acosh`, `logSoftmaxRows`, `cosineSimilarity`, `dotAll`, the axis reductions | budget still under 6 s |
| **16** | **`numericalGrad` as a public helper.** Several tests roll their own central difference | they all call one function |
| **17** | **The two owed decisions.** The `xf` forward-mode question, and row 19's `Named` versus `dimnames` | a register row either way, with evidence |
| **18** | **Argument TYPES in the tutorial checker.** Arity is checked; types are not, so `zn.aggregate(f64, .mean, ...)` on an integer column fails the compiler and not the document | a wrong type in an example fails `zimrnum-ref` |
| **19** | **Finish `zimrnum-parity`'s exclusion list.** It runs and reports an UPPER BOUND because `internal_namespaces` does not name every machinery type in znum | the tool's number matches the hand-read one |
| **20** | **The final read.** Re-run the mapping, read every unmatched name, implement or record. A number from a scanner is a hypothesis; a ledger where every line has been read is a fact | `znum_mapping.md` shows ZERO unexplained |

---

## 4. Standing rules

These have each been earned by a specific failure. They are not style preferences.

**Before writing anything:**

- **Grep before believing this document.** `grep -cE "pub (fn|const) NAME" src/zimrnum.zig`. Three
  blocks in v2 were listed as missing and were already done.
- **Read znum's version first**, and check the claim about the code being replaced. The
  `categorical` rewrite was justified by an overflow claim that was false - znum subtracts the max
  too.
- **Check for an existing helper.** `quantileSorted` existed when `quantileOfSorted` was written;
  `zm.maxInt` existed when `zm.highest` was used for a sentinel.

**While writing:**

- **Anything that writes into a tensor it did not allocate goes through `setAt1`/`setAt2`/
  `offsetOf`.** Raw `data[i]` is safe only for a buffer just allocated. A caller's `out` may be a
  strided column.
- **Forming the 1 loses everything.** `log(1+x)`, `softplus`, `logSumExp`, the tanh squash
  correction - four places so far. Use `log1p` and subtract the max.
- **A counter maintained at N call sites is wrong at the N+1th.** Put it in one function.
- **An enum variant that always errors is worse than absent.**

**When testing:**

- **Constant folding is a different machine.** Operands must come from memory, or a claim about
  f32 arithmetic is a claim about comptime.
- **A control that does not apply looks exactly like a test that cannot fail.** Assert the
  perturbation landed.
- **A zero bar is a stronger claim than a small one.** Use one wherever the arithmetic cannot
  drift.
- **A reference constant must come from a computation, not a display.**
- **Write the WRONG implementation and watch the test fail.** Per-tensor gradient clipping passes
  every magnitude check; only a direction check catches it.

**When reading output:**

- **Never `cut` a diagnostic.** The `int-from-float` message says exactly what to do past column
  100, and guessing cost two wrong fixes in opposite directions.

**When editing documents:**

- **Existence checks pass on empty.** The reference table rendered with `varianceAxis(` in the
  signature column for months. Check content: no signature ends in `(`, no link's section number
  disagrees with its target.
- **Prose is for the user, doc comments are for the maintainer.** No development history in the
  tutorial.

---

## 5. Where zimrnum is already ahead of znum

Recorded so the next pass does not "fix" these back:

- **`catch unreachable` is 0 in code**, against 109 before the sweep (the four remaining hits are
  the doc comments recording that). `at1`/`at2`/`offsetOf` put the arity
  in the name so the bounds check is Zig's.
- **REDQ**, which znum does not have. `randomSubset` is a partial Fisher-Yates so the subset is
  re-drawn each step rather than fixed.
- **One `compareScalar` with a named `Comparison`** replaces six `*Scalar` functions; one `affine`
  replaces four.
- **The tape provides activation gradients**, so `eluGrad`/`geluGrad`/`siluGrad`/`softplusGrad`/
  `mishGrad` are five functions that do not need to exist.
- **No `Scope` wrapper.** The caller owns the arena, which removed a heap allocation per scope and
  a cached-interface hazard nothing had.
- **`softplus` holds its tail to 1.9e-22**, where znum's `max(x,0) + log(1+e^-|x|)` returns 0 from
  x = -50 down.
- **Aggregates keep their type.** `sum` of an `i32` column is an `i32`; `mean` of one is a compile
  error rather than a silent float.
- **The document is checked by the build** - reference table, opening program, example arity.
