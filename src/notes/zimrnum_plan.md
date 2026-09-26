# zimrnum plan v3

**The goal is not parity with znum. Parity is the floor.** znum is the reference for what a Zig
numerics library should cover; this one should be measurably better where it differs, and every
difference should have a reason written down.

v2 is in `archive/zimrnum_plan_v2.md`. It ran from 133 tests to 152 and closed serialisation, the
optimisers, the dataframe core, the distributions and five RL algorithms. What it got wrong three
times was the roadmap itself, by listing znum's names instead of reading zimrnum - so this version
opens with a measurement rather than a list.

---

## 0. THE RL LEDGER — re-verified Sep 14 (second pass)

Method, stated because three earlier counts were wrong: `znum.zig` lines **16878-21854**
(boundaries checked - `pub const rl = struct` opens at 16878, `pub const metrics` follows at
21856), extracted with `^ *pub (fn|const)` at **any** indent, same pattern both sides, and every
"covered under another name" claim checked programmatically against zimrnum's symbol table.

**znum `rl`: 108 declarations. 68 absent from zimrnum (excluding `rl` itself). 19 are real gaps.**

| classification | n | |
|---|---|---|
| covered under another name | 17 | all verified present: `ppoLoss`->`ppoClipObjective`, `clippedSurrogate`->`ppoClipSample`, `AdamState`->`Adam`, `counterRng`->`Rng`, `Rollout`->`RolloutBuffer`, `insert`->`push`, `minibatch`->`MinibatchOrder`, `computeAdvantages`->`gae`, `alphaValue`->`alpha`, `setTargetEntropyPerDim`->`forActionDim`, `uniform01`->`uniform`, `linear`->`linearLearningRate`, `update`->`observe`, `schedule`->the `*LearningRate` family, `reparameterize`->`squashedReparameterize`, `loss`->`Temperature.gradient`, `actionNoise`->`OrnsteinUhlenbeck` |
| deferred: robot work | 16 | `zest`, `BinSampler`, `ReferenceClip` and their methods - residual control, curriculum sampling, mocap playback |
| not capability | 7 | `Batch` `Config` `Minibatch` `Reparam` `Sample` `Shape` `Step` - nested type NAMES; zimrnum decomposes differently |
| declined: device/host split | 6 | `greedyDevice` `logProbDevice` `sampleDevice` `cartpoleContStepHost` `cartpoleStepHost` `reacherStepHost`. zimrnum's GPU interface is the sweep; a `*Host` twin of every function is the design the sweep exists to avoid |
| different design | 2 | `alphaOnTape` `alphaOnTape2D` - `Temperature.gradient` is the closed form, one fewer tape node |
| declined: composed instead | 1 | `stepClipped` - zimrnum composes `clipGradNorm` + `adamStep` |
| **REAL GAPS** | **19** | below |

### The 19, in the order they should be closed

| | n | why this order |
|---|---|---|
| `sacUpdate` `td3Update` `dqnUpdate` `ppoUpdateContinuous` | 4 | Every primitive beneath them exists and is tested; `ppoUpdate` proved the loop shape works end to end |
| `SacConfig/Stats` `Td3Config/Stats` `DqnConfig/Stats` | 6 | Trivial structs, but adding them BEFORE the updates that consume them would be cargo-culting - they land together |
| ~~`cartpoleContStep` `cartpole_state_dim`~~ **DONE Sep 14** + `cartpoleObserve` `cartpole_action_dim`; `reacherStep` `reacher_joints` `cartpole_rd_dim` remain | 3 left | **ANALYTIC environments - equations, not a physics engine.** Not the robot work being deferred |
| `Bernoulli` `MultiCategorical` | 2 | Binary and multi-discrete action spaces. Real capability, orthogonal to continuous control |
| `ResidentRollout` | 1 | GPU-resident rollout. znum's is DISCRETE-ONLY, so a continuous one is ahead rather than level |
| `minOverMasks` | 1 | Masked reduction for variable-length episodes |

★ **Everything not in that list of 19 is justified, and each justification is now checked rather
than asserted.** The 17 "covered" claims were verified against zimrnum's symbol table by a script,
not by memory - the previous pass asserted several of them without looking.

## 0b. Superseded ledger (first pass, kept for the correction it records)

## 0. THE RL LEDGER — the one table to read first

Measured Sep 14 against `/tmp/znum/znum/znum.zig`, lines 16878-21856, at EVERY indent depth
(the earlier count of 59 was an eight-space grep and missed 47 declarations; see the correction
in section 3d).

**znum `rl`: 107 public declarations. zimrnum has the equivalent of 37. 70 names absent.**

### Present and tested in zimrnum

| layer | what |
|---|---|
| collection | `RolloutBuffer` (refuses to wrap), `RolloutStep`, `ReplayBuffer`, `Transition` |
| credit | `gae`, `generalizedAdvantage`, `normalizeAdvantages` |
| batching | `MinibatchOrder` |
| objective | `ppoClipSample`, `ppoClipObjective`, `ppoObjective`, `ppoEpoch`, `Graph.ppoClipLoss` |
| off-policy targets | `sacTarget`, `dqnTarget`, `CriticAggregate`, `aggregateCritics` |
| distributions | `Categorical` (+`greedy`), `DiagGaussian`, `SquashedGaussian` (+`deterministic`) |
| differentiable policy | `Graph.diagGaussianLogProb`, `Graph.squashedReparameterize` -> `SquashedDraw` |
| exploration | `OrnsteinUhlenbeck` |
| SAC temperature | `Temperature` (+`forActionDim`, `alpha`, `gradient`) |
| observations | `ObsNormalizer` |
| diagnostics | `klGaussianDiag`, `PpoStats` |
| schedules | `linearLearningRate`, `linearOverFraction`, cosine/warmup/step/exponential |
| env | `CartpoleState`, `cartpoleStep`, `cartpoleStepBatch` |

### Absent, with a verdict on each

| what | n | verdict |
|---|---|---|
| ~~`ppoUpdate`~~ **DONE** / ~~`ppoUpdateContinuous`~~ **NOT NEEDED** / ~~`sacUpdate` `td3Update` `dqnUpdate`~~ **ONE `offPolicyUpdate` - see 3j** | **0 left** | Two loops cover all five of znum's update functions, because in both cases the caller supplies the loss and the loop never learns which algorithm it is running |
| `SacConfig/Stats` `Td3Config/Stats` `DqnConfig/Stats` | 6 | Absent. Needed by the updates above; zimrnum has PPO's pair only |
| `Bernoulli` `MultiCategorical` | 2 | Absent. Binary and multi-discrete action spaces |
| `cartpoleContStep` `reacherStep` + `*Host` twins + dim constants | 7 | Absent. ANALYTIC continuous environments - no physics engine, just equations - which is what a learning gate needs before the robot work starts |
| `minOverMasks` | 1 | **Now identified: it is DroQ's min over dropout masks** - see 0c. Needs `Graph.min`, the first genuinely new backward the RL work has required |
| `ResidentRollout` + its `Minibatch`/`Step`/`computeAdvantages`/`minibatch` | 5 | Absent. GPU-resident rollout. **znum's is DISCRETE-ONLY**, so a continuous one is ahead rather than level |
| `zest` (5) `BinSampler` (4) `ReferenceClip` (5) | 14 | **Deferred on purpose** - residual control, curriculum sampling, mocap playback. Robot work |
| `greedyDevice` `logProbDevice` `sampleDevice` | 3 | **Declined.** znum's CPU/GPU dispatch split; zimrnum's GPU interface is the sweep |
| `Batch` `Config` `Minibatch` `Reparam` `Sample` `Shape` `Step` | 7 | **Not capability.** Nested type NAMES; zimrnum decomposes differently |
| `alphaOnTape` `alphaOnTape2D` `loss` | 3 | **Different design.** `Temperature.gradient` is the closed form - same answer, one fewer tape node |
| `stepClipped` | 1 | **Declined.** zimrnum composes `clipGradNorm` + `adamStep` |
| `ppoLoss` `clippedSurrogate` `AdamState` `counterRng` `schedule` `Rollout` `cartpoleStep` `alphaValue` `setTargetEntropyPerDim` `computeAdvantages` `uniform01` `insert` `minibatch` `linear` `apply` `update` `advance` `duration` `pose` `setFrame` `velocity` `slotOf` `sampleSlots` `temperature` `errorSquared` | 25 | **Covered under other names, or methods of deferred types** |

**Next: the five update functions, continuous first.** Nothing else blocks them.

## 0d. Beyond MPEAC: see `src/notes/advancedrl.md`

MimicKit read Sep 15 (103 files) for the ingredients behind its adversarial, diffusion and
regression-based methods - AMP, ASE, ADD, AWR and a motion diffusion model. The full mapping is
in `advancedrl.md`; two things from it belong here because they change this plan's ordering.

★★★ **`Graph.backward` IS NOT DIFFERENTIABLE, AND THAT BLOCKS THE WHOLE ADVERSARIAL FAMILY.** It
writes into `grads` tensors directly and builds no tape nodes - verified by grep, zero calls to
`push` in its body. AMP, ASE and ADD all carry a gradient penalty on the discriminator, which is
a function OF the input-gradient and needs `create_graph=True` in PyTorch's terms. Without it an
adversarial discriminator becomes a step function the generator can neither fool nor learn from.

**This is the largest single item anywhere in zimrnum's RL work**, and `advancedrl.md` schedules
it LAST and staged, deliberately: everything else in these families is arithmetic with closed-form
answers to test against, while second-order autodiff has no oracle short of finite differences of
finite differences. It should land when nothing else is moving.

★ **The good news is how much is already there.** The SAC and PPO work put most of it in the tree
without meaning to: `binaryCrossEntropyFromLogits` IS the GAN loss, `ObsNormalizer` is exactly
AMP's separate discriminator-observation normaliser, `ReplayBuffer` is its discriminator replay,
`polyakUpdate` IS the diffusion EMA with `follow = 1 - decay`, and `Attention`, `layerNormRows`
and `dropout` are the DiT block. The remaining first-order work is roughly twenty small functions.

## 0c. MPEAC — what it needs, what we have, and the two things we do not

A concrete target worth planning against: **Motion-Prior Efficient Actor-Critic** for humanoid
parkour and mocap following. It is SAC with four modern grafts - DroQ's dropout critics, CrossQ's
target-free updates, DeepMimic-style motion priors, and a PPO-style trust region - so it is a good
test of whether zimrnum's pieces compose into something real rather than only into textbook SAC.

**Mapped component by component against the tree, checked rather than assumed:**

| MPEAC needs | zimrnum has | status |
|---|---|---|
| High UTD (10-20 gradient steps per env step) | `offPolicyUpdate` called in a loop | **have** - the UTD ratio is a `for` loop around it, not a feature |
| Dropout critic (DroQ) | `Graph.dropout`, `Graph.resampleDropout` | **have** - `resampleDropout` is exactly the per-mask resample the method needs |
| LayerNorm critic, NO target network (CrossQ) | `Graph.layerNormRows`; `OffPolicyModel.target_weights` defaults to `&.{}` | **have.** The empty target list was written as "DQN without one is a valid if unstable configuration" - it turns out to be CrossQ's whole point |
| Reparameterised action + squashed log-prob | `Graph.squashedReparameterize` -> `SquashedDraw` | **have** |
| Temperature tuning to `-dim(A)` | `Temperature.forActionDim(action_dim, -1.0)` | **have** |
| Residual actions (`a_applied = a_ref + a_res`) | `Graph.add` | **have** - the residual formulation is an addition, not a mechanism |
| Critic loss, MSE to target | `Graph.mseLoss` | **have** |
| Reference-state initialisation (start at a random mocap frame) | - | **needs `ReferenceClip`**, which is deferred robot work. Substitutable with a fixed start while the rest is built |
| **min over M dropout masks** | - | **GAP 1** |
| **KL(policy \|\| prior) ON THE TAPE** | `klGaussianDiag` is CPU-only | **GAP 2** |

### GAP 1 — elementwise `min` on the tape

DroQ's entire trick: evaluate one critic under M dropout masks and take the MINIMUM, which
approximates an ensemble's pessimism at a fraction of the compute. The tape has no `min`.

**This is what znum's `minOverMasks` is**, and it has been sitting in our gap list since Sep 14
classified only by name. The forward is elementwise; the backward routes the gradient to whichever
input won and zero to the other - the same shape as `@min` in `ppoClipSample`, where taking the
smaller term is what makes PPO a trust region rather than a plain policy gradient.

★ Worth noting it cannot be composed the way `diagGaussianLogProb` was. `min(a,b)` is
`0.5*(a+b-|a-b|)`, and `abs` is not on the tape either - so this is the first genuinely NEW
backward zimrnum's RL work has needed.

### GAP 2 — the Gaussian KL on the tape

MPEAC's actor loss carries two KL terms: one pulling the policy toward the motion prior, one
anchoring it to a slowly-updated old policy. **Both are penalties the gradient must flow
through**, so the CPU `klGaussianDiag` is a dead end for exactly the reason
`DiagGaussian.logProb` was before `diagGaussianLogProb` existed: right number, no gradient.

The closed form is `log(s_p/s_q) + (s_q^2 + (m_q-m_p)^2)/(2 s_p^2) - 0.5` summed over dimensions,
and every term is already on the tape - `sub`, `mul`, `exp`, `scale`, plus the matmul-with-ones
broadcast and row-sum that `diagGaussianLogProb` established. So this one COMPOSES and needs no
new backward.

★ The prior's variance is a fixed hyperparameter, so the prior side is a CONSTANT - only the
policy's mean and log_std carry gradient. That halves the expression and removes any question of
differentiating through the reference motion.

### The order to close them

1. ~~`Graph.klGaussianDiagOnTape`~~ **DONE Sep 14 as `Graph.klToReference`** - composed from
   existing ops, no new backward. Unlocks both of MPEAC's KL terms (motion prior AND trust
   region - the same call, with a slowly-updated copy of the policy as the reference) plus PPO's
   adaptive-KL penalty. Verified against the CPU `klGaussianDiag` to 1e-10, `checkGradient` under
   1e-7 on both mean and log_std, and exactly zero at the prior.
2. ~~**`Graph.min`**~~ **DONE Sep 14.** One new backward, and the first this RL work has needed -
   everything else composed. Unlocks DroQ critics AND TD3's twin-critic minimum.
3. **`ReferenceClip`** - with the robot work, when mocap playback lands.

★★★ **MPEAC IS NOW EXPRESSIBLE.** Both tape gaps are closed and neither required touching the
update loops - which is the argument for having written those so the caller supplies the loss.
What remains is `ReferenceClip` for reference-state initialisation, which is mocap playback and
belongs with the robot work; a fixed start substitutes while the rest is built.

**The assembly, for whoever writes it:**

    critic   Dense -> layerNormRows -> dropout -> ... -> scalar   (no target network)
    masks    resampleDropout, recompute, fold with `min` over M
    target   sacTarget(transition, masks_min, next_log_prob, gamma, alpha, .minimum)
    actor    alpha * log_prob - min_Q
             + gamma_prior * klToReference(mean, log_std, reference_mean, reference_log_std)
             + beta        * klToReference(mean, log_std, old_mean, old_log_std)
    alpha    Temperature.forActionDim(action_dim, -1.0), stepped by `gradient`
    loop     offPolicyUpdate with `target_weights = &.{}`, called UTD times per env step

## 1. Where it stands, measured

| | |
|---|---|
| znum user-facing surface | 463 |
| present in zimrnum | **360 (77%)** |
| genuinely missing | **106 distinct**, measured against the tree Sep 13. The older "103" and `znum_mapping.md`'s "130" were both wrong - see that file's re-read |
| zimrnum tests | **161** (was 152 when this plan was written) |
| zimrmath tests | 170 |
| reference rows | **640** (was 522; `zimrnum-ref` regenerated after Tier 1) |
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
| **1** | ~~**The recurrent family.**~~ **DONE.** `LstmCell` pre-existed; `LSTM` (the sequence level and the `bind`/`stepBound` split that makes BPTT work), `GruCell`, `GRU`, `BiLSTM` and `StackedLSTM` all landed Sep 12 | 4 of 4 | **met.** Each learns a task the others cannot do by accident, measured as curves; the BiLSTM runs a forward-only control that fails |
| **2** | ~~**The training loop.**~~ **DONE Sep 13.** `Dataset`, `DataLoader`, `numBatches`, `reshuffle`, `fit`, plus `Fitting`/`Fit`/`FitReport` | 6 | **met.** `fit` trains XOR in three lines |
| **3** | ~~**`eig` for non-symmetric.**~~ **DONE Sep 13.** `hessenberg` + shifted QR to real Schur form. Eigen*values*, not vectors | 1 | **met.** The rotation's exact +/-i, a companion matrix deflating a 1x1 and a 2x2, trace/determinant invariants, and agreement with `eigh` |

★★★ **A 1-BASED ALGORITHM TRANSLATED TO 0-BASED `usize` CRASHES INSTEAD OF ANSWERING.** The
published shifted-QR iteration indexes `l - 1` and `hi - 2` freely, because in a 1-based array
those are always in range. The first version here used `usize` and underflowed on the very first
test - "failed without output", no assertion, no diagnostic. The indices are `isize` now with a
cast per access. **Any algorithm taken from a 1-based source needs signed indices or an explicit
guard at every decrement**, and the failure mode is a crash rather than a wrong number, which is
at least honest.

★★ **`eig` cannot reuse anything `eigh` does, and the reason is not implementation.** A
non-symmetric real matrix need not have any real eigenvalue: `[[0,-1],[1,0]]` has `+i` and `-i`,
and no real similarity transform can ever triangularise it, because a real triangular matrix wears
real eigenvalues on its diagonal. So the iteration aims for real Schur form and **a 2x2 block IS
the conjugate pair** - the negative discriminant of one quadratic is the only place a complex
number is formed in the whole routine.

★ **The Hessenberg test checks trace and determinant, not just the zeros.** Applying the
reflector from one side - `P A` rather than `P A P` - produces a perfectly Hessenberg matrix with
the WRONG eigenvalues. The shape proves nothing; the similarity invariants catch exactly that.

★ **`std.math` is banned outside zimrmath**, including `floatEps`. `zm.floatEps` already existed.
The lint says so with no `lint:off` available, which is the right shape for a portability rule.

★★ **An MSE of exactly 0.0 was checked rather than accepted.** `zn fit: XOR in three lines`
reported a final epoch mean of **exactly zero**, which normally means a test is comparing
something to itself. Re-run with targets of 0.3/0.7 instead of 0/1 it lands at **1.04e-21** with
predictions reading 0.29999999995 - so the optimiser reaches machine precision either way, and
0 and 1 being exactly representable in binary is the only reason one of them prints clean. The
probe is recorded in the test comment, because "the loss went to zero" is not a claim anyone
should have to re-derive.

★ **`Rng` is INDEXED, not a stream.** It has no `next`; `bits(index)` and `intBelow(index, bound)`
take the position as an argument. So `DataLoader` carries an epoch counter and draws each epoch's
permutation from `rng.split(epoch)` - same seed and same epoch is the same order on every run,
which a stateful generator could not promise after an interrupted epoch.

★ **Dropping the last partial batch is forced by the tape, not chosen.** `fit` feeds batches by
writing THROUGH the graph's leaf tensors, which were allocated once at a fixed height, so a short
tail has nowhere to go. Frameworks make this a `drop_last` flag because they rebuild per batch.
`numBatches` reports the truncated count rather than rounding up to a batch that cannot run.

★★ **A stack of two beat one layer 6x, and the test had been written saying it would not.**
`zn StackedLSTM` was built to show only "a stack composes and trains" - the remember-the-first-step
sequence looked too easy for depth to matter. Measured on identical seeds and budget: **0.51% of
the target variance against the single layer's 3.2%**, gradient checking at 5.0e-13 through two
layers and eight timesteps. The comment now records the measurement AND what it does not separate:
the stack carries twice the parameters, so this is depth-plus-capacity against neither. A
parameter-matched single layer would settle it, and that is a different test.

★★ **The BiLSTM's control is run, not reasoned about.** The task asks for the LAST step's value
from the FIRST position's output - a forward LSTM has no path to it. Rather than assert that from
the architecture, the test trains a forward-only model on the identical task and budget: variance
**0.295**, bidirectional **0.0119** (4.0%), forward-only **0.276** (**93.6%** - barely better than
answering with the mean). A **23x** gap, measured.

★ **`trainCurve` replaced four copies of the same twenty lines.** Each recurrent test was about to
carry its own moment/velocity setup and AdamW loop, differing only in the tensor list - and a
fifth copy that stepped the head but forgot a gate would still show a falling loss. One helper,
returning both ends of the curve.

**What the Sep 12 review turn found, reviewing the LSTM/GRU code rather than adding to it.**

★★★ **`zimrnum_ref`'s note table silently drops every duplicate.** `noteFor` returns the FIRST
entry for a name, so a second note under that name is dead text rendering nowhere - and nothing
said so. `Gate` had two, and **every `Gate` row in the reference table, `LstmCell`'s and
`GruCell`'s included, was rendering the gated unit's "sigmoid or silu, chosen at comptime"** while
the note written for the cells sat unused. `Stepped` and `Bound` acquired the same fault when the
GRU landed, each asserting the LSTM's parameter count over the GRU's rows. Three notes rewritten
to be true of every owner; `reportDuplicateNotes` now prints the rest. **15 names still carry a
dead second note**: `slice exp log softplus elu silu gelu conv2d step add concat moveAxis sumAxis
meanAxis maxAxis` - mostly free-function against `Graph`-method pairs, each needing a judgement
about whether one text covers both. Owed work, and §2's "the document cannot lie" is not true
until it is done.

★★ **The GRU is SLOWER than the LSTM here, not weaker, and the test now says which.** Same task,
seeds, optimiser and 400 steps: variance **1.016**, loss **1.206 -> 0.0835**, which is **8.2% of
the variance** against the LSTM's **3.2%**. Run past the bar it reaches **7.8e-4 at 800 steps and
0.000000 by 1600**, well below where the LSTM stands at 400 - so the one-state shape costs steps
on this task, not capability. The 400-step margin is thin (0.0835 against a 0.1016 bar): if that
test goes red the reading is "the GRU got slower", and loosening the bar or lengthening the
schedule would erase the comparison the test exists to make.

★ **`GruCell.stepBound` allocated a ones-tensor per timestep**, to build `1 - z`, and its comment
described a `scale(z, -1)` implementation that was not the one written. `(1-z)*n + z*h` is
`n + z*(h - n)`, which needs no constant: three tape ops instead of five, nothing allocated per
step, and the measured learning curve is unchanged to six decimals.

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
| **16** | ~~**`numericalGrad` as a public helper.**~~ **DONE Sep 13.** The function already existed - the roadmap was wrong for the SIXTH time. What was missing was the call sites: `crossEntropyRowsGrad` and `ppoClipObjective` still hand-rolled their loops, and both now go through it (7 call sites, was 5) | **met, with one recorded exception.** The two remaining central differences are SCALAR - `(zm.sigmoid(x+h) - zm.sigmoid(x-h)) / 2h` - and `numericalGrad` takes a Tensor. A scalar overload for two call sites would be machinery, not reuse |
| **17** | **The two owed decisions.** The `xf` forward-mode question, and row 19's `Named` versus `dimnames` | a register row either way, with evidence |
| **18** | ~~**Argument TYPES in the tutorial checker.**~~ **DONE Sep 13.** Every `comptime …: type` position is now checked in both directions: a literal in a type slot, or a scalar type name in a value slot. Identifiers are left alone deliberately - deciding those needs a compiler | **met, and it found something worse.** `example_open` was the exact string `"<pre><code>"`, and the docs restyling had given every block a `class="zig"` - so **148 of the tutorial's 241 examples had silently stopped being checked at all**, arity included. The scanner matched the 93 bare ones and reported success. Fixed to match the prefix and skip to `>`; source folds went 46 -> 290. Both checks verified by planting a wrong type and a wrong arity in previously-invisible blocks |
| **19** | **UNBLOCKED Sep 14, and now measured.** With znum checked out the tool runs: **znum 1338 public declarations, ours 501, matched 412, declined 65, STILL MISSING 861.** That 861 is 754 distinct names, and **only 91 of them are declared at COLUMN ZERO in znum** - the other 663 are methods. The tool tracks an enclosing `pub const X = struct` by scanning BACKWARD for the nearest one with no brace-nesting check, which over a 63,000-line file is wrong far more often than right; `internal_namespaces` then filters on that wrong answer. **The fix is the enclosing scan, not a longer exclusion list** | the tool's number matches a hand-read one |
| **20** | **The final read. HALF DONE Sep 13** - the half that needs no znum checkout. Every name `znum_mapping.md` lists as missing was checked against the tree: of 130 entries, **six are duplicates** and **18 are present today** (seven from Tier 1, eleven that were already there when the file was written). **106 are genuinely absent, and this plan names only 42 of them** - the other 64 are now listed in the mapping. Then 15 of the 64 were read and found present under other spellings (`eq`->`equal`, `cosineLR`->`cosineLearningRate`, three that are METHODS the column-zero scanner cannot see), and 5 more are declines (znum's `*Host`/`*Device` dispatch split). **44 left to read** | `znum_mapping.md` shows ZERO unexplained |

---

## 3b. The znum read, Sep 14 — what it changes

znum is checked out, so §19's parity number is real for the first time and its source and
review documents are readable. Four things came out of it, and one of them reorders the plan.

### 3b.1 zimrnum has every RL PRIMITIVE and none of the ASSEMBLY

Measured against `znum.zig`'s `rl` namespace (95 public declarations, 4,197 lines, 348 tests,
five learning gates):

| | zimrnum | znum |
|---|---|---|
| distributions | `Categorical` `DiagGaussian` `SquashedGaussian` | same, plus `MultiCategorical` |
| advantage | `gae` `generalizedAdvantage` `normalizeAdvantages` | `gae` `computeAdvantages` `normalizeAdvantages` |
| objectives | `ppoObjective` `ppoClipObjective` `sacTarget` `dqnTarget` | `ppoLoss` |
| **updates** | **none** | `ppoUpdate` `ppoUpdateContinuous` `sacUpdate` `td3Update` `dqnUpdate` |
| configs/stats | `PpoConfig` `PpoStats` | + `SacConfig/Stats` `Td3Config/Stats` `DqnConfig/Stats` |
| buffers | `ReplayBuffer` (raw ring) | `ReplayBuffer` `RolloutBuffer` `ResidentRollout` |

znum's own roadmap calls these "algorithms that are pure assembly (each ~150 lines + one gate)".
**That is the whole remaining distance on the RL side** - five functions over primitives zimrnum
already has and tests.

### 3b.2 ★★★ ZIMRNUM CAN BE BORN WITH znum's BUGS ALREADY FIXED

`RL_REVIEW.md` is an adversarial self-review. Its findings are free design constraints:

- **Truncation.** znum's `ReplayBuffer` carries ONE `done` flag, so it cannot distinguish "the
  episode ended" from "we cut it at the horizon" - and zeroing the bootstrap on a horizon cut
  teaches the critic that the world ends there. Its own review calls this structural. **zimrnum's
  `ReplayBuffer` is a raw flat ring with no flag at all**, so it can carry `terminal` and
  `truncated` as separate fields for free, today, before anything depends on the shape.
- **The two PPO updates are 61% identical and have already diverged** - `desired_kl` was
  silently ignored on the discrete path. Extract the shared minibatch half ONCE (shuffle,
  gather, advantage constants, clip, step), leave the distribution-specific part separate.
  znum names that exact split after paying for it.
- **A config field that does nothing on one path is worse than an absent one**, because an
  absent one fails to compile. Any shared config must work on every path that accepts it.
- **`sacUpdate` is 226 lines doing five jobs.** Split critic and actor at birth.

### 3b.3 ★★★ THE ADVANTAGE znum CANNOT COPY: REAL DYNAMICS

znum's continuous-control gate, `rl_reach3d_ppo.zig`, trains on a **point mass in R^3** - state
is a position, action is a clamped desired velocity. That is not a criticism of the gate; it is
all znum has. **znum contains no articulated-body dynamics whatsoever.**

`src/robot.zig` is 128 public declarations of `forwardDynamics`, `inverseDynamics`, `step`, with
MJCF and URDF loading and fixtures generated from real MuJoCo. A continuous-control gate on a
KUKA iiwa, or on the existing cartpole/quadruped/gripper models, is a different CATEGORY of
evidence from a point mass - and it is reachable because both halves are already in this tree and
already tested.

**This is the focus.** Not "RL parity with znum", but the continuous-control loop znum cannot
close: a policy trained against verified articulated dynamics, in one binary, with the physics
under test by the same suite.

### 3b.4 The revised order

| | work | why here |
|---|---|---|
| **R1** | ~~`terminal`/`truncated` distinction off-policy~~ **DONE Sep 14.** `Transition` carries `truncated`; `bootstraps()` is the single place the rule is written and BOTH `dqnTarget` and `sacTarget` ask it; `validate()` refuses the contradiction. Two tests, one of which reproduces znum's bug exactly - planting `!(terminal or truncated)` gives `expected 11.8, found 1`, the entire bootstrap gone | **met.** On-policy `RolloutStep` already had `terminal`/`seam`; this is the off-policy half. **Still open:** `ReplayBuffer` is a raw `[]T` ring, so the flags travel in the `Transition` rather than in the buffer - fine today, worth revisiting when a rollout loop exists to lose them |
| **R2** | **IN PROGRESS.** Three shared pieces in: `ppoClipSample` (per-sample surrogate, scalar-first so a kernel can call it), `MinibatchOrder` (the shuffled walk), and `ppoEpoch` (shuffle -> gather -> objective -> weighted average, no model needed so it is testable without one) | **what remains is the model-facing wrapper**: run the network over each stride to produce `log_prob_new`/`entropies`, call `ppoEpoch`, step the optimiser. Statistics are weighted by minibatch SIZE - plant-verified that equal-weight averaging fails the test |
| **R2-gpu** | ~~RL arithmetic verified shader-compatible~~ **DONE Sep 14.** `zig build zn-rl-gpu` compiles `src/shaders/zn_rl_gpu_probe.zig` - a real SPIR-V entry point calling `ppoClipSample` at and past the clip boundary - and hangs off `wgpu_check`. Plant-tested: an allocator inside the function gives `cannot construct slices without the 'variable_pointers' feature` | **met, and it measured something worse.** The op sweep is 92 kernels and **not one RL operation**; PPO's surrogate and the off-policy targets had never been compiled for a device at all. This proves the SHAPE compiles - the sweep would prove the ANSWERS agree, and no RL row is in it yet |
| **R3** | A learning gate on a REAL robot: `robot.zig` dynamics, MJCF model, mean return rises | the thing znum structurally cannot do |
| **R4** | `sacUpdate`, split critic/actor | off-policy sample efficiency is what a robot task needs |
| **R5** | `td3Update`, `dqnUpdate` | assembly over the same primitives |

Tier 2 items 4-7 and all of Tier 3 stay where they are. Tier 4's remaining infrastructure items
(13, 14, 15) are unchanged and still rank above Tier 2-3 function work.

---

## 3c. Where zimrnum's GPU half should live — measured Sep 14

**The question:** the GPU tests are only in `examples/`. Should the important part be on the
engine side, with the example wrapping it?

**Measured first.** `examples/zimrnum_field/` and `examples/zimrnum_train/` are 4,871 lines, and
they are two different things sitting in one folder:

| | lines | imports |
|---|---|---|
| `zn_unary` `zn_binary` `zn_matmul` `zn_train` | **2,185** | `kompute`, `zm` — and nothing else |
| `zimrnum_field.zig` `zimrnum_train.zig` | 2,686 | `std`, `zimr`, `zm`, `zn` |

The kernels have **no dependency on the example harness at all**. They are zimrnum's GPU
implementation, with the same closure discipline as `zimrnum.zig` itself. And `src/` cannot
reach any of it: the only mention of these files anywhere under `src/` is a doc comment.

★★★ **THE RULE THAT KEPT THEM THERE WAS MISREAD.** "zimrnum must stay shader-free" is real and
load-bearing — it is what makes `src/zimrnum.zig` a `test-fast` root and what lets `robot.zig`
adopt it without dragging a WebGPU queue into a Jacobian test. But it constrains **a module's
import closure, not a directory**. A separate module under `src/` that imports `kompute` does
not touch `zimrnum.zig`'s closure by one byte. The fear was of the wrong thing, and it cost
2,185 lines of library code being unreachable from the engine.

**Three things, not two, and they want three homes:**

1. **Kernel source** (2,185 lines) — library code. Belongs under `src/`.
2. **The conformance table** — 52 `Case` rows with per-op tolerances and the CPU reference,
   currently buried inside the 2,386-line demo. This is **the only thing proving CPU and GPU
   agree**, and it is the most valuable test zimrnum has. It should be a step, not an example.
3. **The visualisation** — the field rendering and UI. Genuinely an example; stays.

### DONE Sep 14 - the kernels are engine code

All four moved to `src/gpu/`. `examples/zimrnum_field/` and `examples/zimrnum_train/` are now
ONE FILE each, holding only their rendering.

Two build changes were needed, both small:

1. `ComputeKernel.source_path` - the path was a format string with `examples/` baked in.
2. **Each kernel is now exposed as a NAMED MODULE.** `addComputeKernelImports` only ever
   provided the compiled WGSL as `<entry>_wgsl`; the Zig source was reached by a RELATIVE
   import (`@import("zn_matmul.zig")`), and that was the real tie to the folder. The build now
   does `user_mod.addImport(k.basename, kernel_mod)` with `kompute` + `zm` (+ `zn` when the
   kernel wants it) on the module, so callers write `@import("zn_matmul")` and no longer care
   where the file sits.

Verified: `zimrnum_field` passes at 5238 init calls and `zimrnum_train` at 4278, both identical
to before the move. `files.md` regenerated - four entries under `src/gpu/`, zero stale.

### DONE Sep 14 - the conformance table is engine code too

`src/gpu/zn_conformance.zig` (1,581 lines) now holds the 52-row table, its CPU reference, the
ten pinned sweep parameters and `compare`. **`examples/zimrnum_field/zimrnum_field.zig` went
2,386 -> 861 lines** and holds only rendering. Sweep unchanged at 5238 init calls.

It is a `test-fast` root, so it has **headless tests that need no device**:

| invariant | what it catches |
|---|---|
| no row repeats another's (kind, entry, **input**) | a duplicated row whose CPU reference is never compared against anything |
| `tol >= 0`, `ulps >= 0`, both finite | **a negative tolerance accepts everything** - the one failure a sweep cannot report, because it looks exactly like success |
| `0 < out_len <= count`, `threads > 0` | a row reading past the reference, or silently comparing a prefix |
| `compare` returns infinity on a finiteness mismatch | the `div` row's real bug: a finite GPU answer against an infinite reference used to pass on tolerance |

★ **The first of those failed when written, and taught me the table's design.** `expm1`, `log1p`
and `tanhf` are each rowed TWICE - once on `.noise`, once on `.tiny` - because the first two
exist precisely for small arguments and a sweep that only fed them noise would never exercise
the path they were written for. The invariant is (kind, entry, input), not (kind, entry). My
rule was wrong; the corrected one still catches the real hazard.

### Still to do

The CPU-vs-GPU comparison itself still runs only by building the field demo, because it needs a
queue. That is inherent, not a layering problem - but the table it runs is now engine code with
its own tests, and a headless harness that dispatched the kernels without rendering would be a
small job on top of what exists.

---

★★★ **READ THE EXIT CODE, NOT THE OUTPUT.** Twice this session a plant test "passed" when it
had never run: once because `--test-filter` matched a different test, once because the grep
pattern did not match the failure text. `zig build zn-<stem>` DOES return 1 on a failing test -
verified - so the check is `echo rc=$?`, not `grep -E 'FAIL'`.

★ And a plant that does not plant proves nothing: `s.replace(...)` silently does nothing when the
pattern has drifted. **Assert the replacement count before trusting the result.**

### ★★★ CORRECTION Sep 14: the parity measurement below was WRONG

The comparison that produced the table used `grep -oE '^        pub (fn|const)'` - **exactly
eight spaces**. znum's `rl` namespace declares at three depths:

    8 spaces   95 decls   methods of nested types  <- all the comparison saw
    4 spaces   47 decls   rl's own members         <- INVISIBLE to it
   12 spaces    7 decls

So the real surface is **107 declarations, not 59**, and **70 are absent, not 40**. Every update
function - `ppoUpdate`, `ppoUpdateContinuous`, `sacUpdate`, `td3Update`, `dqnUpdate` - sits at
four spaces and was silently excluded, which is how "parity except ResidentRollave" got said out
loud. The table below is accurate about what it covers and was never the whole surface.

★ **This is the THIRD measurement of this shape to go wrong in one session** - a per-name
`grep -c` loop that returned 0 for a name that existed, a 60-line window that missed a method at
line 83, and now an indent-anchored grep that hid a whole tier. The pattern is always the same:
an anchored pattern that looks precise, silently matches a subset, and reports a confident
number. **Extract with the loosest anchor that still excludes noise, then classify.**

### What the missing 4-space tier actually contains

| | verdict |
|---|---|
| `ppoUpdate` `ppoUpdateContinuous` `sacUpdate` `td3Update` `dqnUpdate` | **The assembly layer, genuinely absent.** Every primitive beneath them now exists and is tested |
| `SacConfig` `SacStats` `Td3Config` `Td3Stats` `DqnConfig` `DqnStats` | Absent. zimrnum has `PpoConfig`/`PpoStats` only |
| `Bernoulli` `MultiCategorical` | Absent. Distributions for multi-discrete and binary actions |
| `cartpoleContStep` `reacherStep` (+ their `*Host` twins and dims) | Absent. Analytic continuous environments for learning gates |
| `klGaussianDiag` | **CLOSED Sep 14** |
| `minOverMasks` | Absent |
| `ppoLoss` `clippedSurrogate` `AdamState` `counterRng` `schedule` `Rollout` `cartpoleStep` | **Covered** as `ppoClipObjective`, `ppoClipSample`, `Adam`, `Rng`, the `*LearningRate` family, `RolloutBuffer`, `cartpoleStep` |
| `zest` `BinSampler` `ReferenceClip` `ResidentRollout` | Deferred as before |

### klGaussianDiag, Sep 14

`PpoStats.approx_kl` is an estimate from the sampled ratios - free during an update, but noisy at
small batch sizes and able to go NEGATIVE, which a divergence cannot. For a DECISION (stop this
update early, raise the penalty) the exact value uses the distributions rather than the samples,
so a threshold means the same thing every run.

★★ **KL IS NOT SYMMETRIC AND THE DIRECTION IS THE POINT.** `KL(new || old)`: how surprised the
policy that collected the data is by the new one. Swap the arguments and you compute something
real, different, and silent - the numbers stay positive and similar in magnitude, and the trust
region binds at the wrong time in a way that reads as a tuning problem. Plant-verified: the
reversed direction still passes identity AND positivity, and fails only the asymmetry assertion.

### Verified against znum's RL surface, Sep 14 - every difference judged

59 column-zero declarations in znum's `rl`; **40 absent from zimrnum**, attributed to their owning
type by brace depth rather than guessed. The verdict, group by group:

| what | n | verdict |
|---|---|---|
| `greedyDevice` `logProbDevice` `sampleDevice` | 3 | **Justified.** znum's CPU/GPU dispatch split. zimrnum's GPU interface is the sweep - adding a `*Device` twin of every function would be adopting the design the split exists to avoid |
| `Batch` `Config` `Minibatch` `Reparam` `Sample` `Shape` `Step` | 7 | **Justified.** Nested type NAMES, not capability. zimrnum decomposes differently - `MinibatchOrder` where znum has a `Minibatch` type |
| `alphaValue` `setTargetEntropyPerDim` `computeAdvantages` `uniform01` `insert` `minibatch` | 6 | **Justified.** Present under other names: `Temperature.alpha`, `Temperature.forActionDim`, `gae`/`RolloutBuffer.advantages`, `Rng.uniform`, `ReplayBuffer.push`, `MinibatchOrder` |
| `alphaOnTape` `alphaOnTape2D` `loss` | 3 | **Justified, different design.** znum puts alpha on the tape; zimrnum's `Temperature.gradient` is the closed form. Same answer, one fewer tape node |
| `stepClipped` | 1 | **Justified.** zimrnum composes `clipGradNorm` + `adamStep` rather than fusing them |
| `linear` `linearOverFraction` | 2 | **CLOSED Sep 14** as `linearLearningRate` (matching the existing `cosineLearningRate`/`stepLearningRate` family) and `linearOverFraction`. It is the schedule PPO actually uses: on-policy data is discarded each update, so late steps want a rate genuinely near zero rather than asymptotically near a floor |
| `zest`: `assistScale` `criticallyDampedGains` `errorSquared` `residualAction` `trackingTerm` | 5 | **Deferred, on purpose.** Residual control for robots |
| `ReferenceClip`: `advance` `duration` `pose` `setFrame` `velocity` | 5 | **Deferred.** Motion-capture reference playback - zimr already has the BVH/retarget machinery, so this belongs with the robot work |
| `BinSampler`: `Config` `sampleSlots` `slotOf` `temperature` | 4 | **Deferred.** Part of ZEST's curriculum sampling |
| `ObsNormalizer`: `apply` `update` | 2 | **WAS a real gap. CLOSED Sep 14** - and improved on znum's in two ways, below |
| `ResidentRollout`: `Minibatch` `Step` `computeAdvantages` `minibatch` | 4 | **NOT JUSTIFIED - a real gap**, though a GPU-path one, and znum's own is discrete-only |
| `deterministic` `greedy` | 2 | **WAS a real gap. CLOSED this pass** |

★★ **`deterministic` and `greedy` were the gap worth closing first.** Neither distribution could
produce its EVALUATION action. A return measured while sampling is measuring the exploration as
much as the policy, and is systematically worse than what the policy would do if deployed -
so without these, every reported number would have been quietly pessimistic.

`deterministic` is `tanh(mean)`: the MODE, not the mean of the squashed distribution. Those
differ because `tanh` is not linear, and averaging samples converges to the wrong one - the test
draws 2000 samples and pins the gap. `greedy` breaks ties toward the lowest index, not because
that is better but because it is DECIDED: random tie-breaking would make an evaluation
irreproducible for a reason nobody would think to look for.

**36 of znum's 59 RL names remain absent, and the classification above accounts for every one.**
Two are genuinely open:

  `ResidentRollout` (4 names) - the GPU-resident rollout. znum's own is DISCRETE-ONLY, so a
  continuous one would put zimrnum ahead rather than level.

  ~~`reparameterize`~~ **CLOSED Sep 14** as `Graph.squashedReparameterize`, returning a named
  `SquashedDraw` - the action for the critic, the log-probability for the entropy term.

### squashedReparameterize, Sep 14 - SAC can now be assembled

SAC's actor loss is `alpha * log p(a) - Q(s, a)` where `a` is a SAMPLE. A gradient has to reach
the policy through that sample, and you cannot differentiate through "draw a random number". The
noise is a CONSTANT on the tape - if it were a parameter the optimiser could lower the loss by
choosing which random numbers it got.

★★ **THE TANH CORRECTION IS WRITTEN `2 * (log 2 - u - softplus(-2u))`, NOT `log(1 - tanh(u)^2)`.**
Those are the same term. The second one is `log(0)` at a saturated action - past |u| ~ 9 in f32,
`tanh(u)` rounds to exactly 1 - so the loss is infinite and every gradient after it is NaN. **A
converged continuous policy saturates; that is what converged looks like when the action is
bounded.** Plant-verified: substituting the textbook form fails the saturation test.

★ Omitting the correction entirely is the classic SAC bug and it does not crash: the entropy term
is computed against the wrong density, alpha tunes toward a target that does not correspond to
the policy's actual entropy, and the run merely trains badly.

★ **The Gaussian part has a closed form in the noise.** Since `u - mean = std * eps` exactly, the
standardised deviation IS `eps` - so the per-dimension term is `0.5*eps^2 + log_std + 0.5*log(2pi)`
with no subtraction and no division, and nothing that can cancel.

Verified three ways: the action equals `tanh(mean + std*eps)`; the log-prob agrees with the
INDEPENDENTLY-written analytic `SquashedGaussian.logProb` (which uses the direct form) to 1e-10;
and `checkGradient` is under 1e-7 for both `mean` and `log_std`.

### ObsNormalizer, Sep 14 - and two places znum's shape was worth changing

Observation components live on wildly different scales: a joint ANGLE is order 1 radian, its
VELOCITY order 10, a contact force order 100. The large ones dominate every gradient, so the
policy learns to ignore the small ones - not because they do not matter, but because they
arrived quiet.

★★ **WELFORD, AND THE TEST THAT EARNS IT.** The naive running variance keeps `sum(x)` and
`sum(x^2)` and subtracts - a catastrophic-cancellation machine exactly where robots live. A joint
held near 1.5 rad with a standard deviation of 0.01 makes the two terms agree to five digits; the
variance comes out noisy, then zero, then NEGATIVE, and a negative variance under a square root
is where the NaNs start. Plant-verified with the classic mis-transcription (reusing the first
delta instead of recomputing against the updated mean), which biases the variance low and never
fails.

★★ **`count` STARTS AT ZERO, WHERE znum STARTS AT `1e-4`.** The epsilon start avoids a branch on
the first division - and makes the running mean `sum / (n + 1e-4)`, **wrong by 1e-4 relative for
the whole first epoch**. The test comparing against a hand-computed mean caught it at 1.5e-4
absolute; nothing else would have. `apply` handles the no-samples case explicitly instead: one
branch, exact statistics.

★★ **`observe` AND `apply` ARE SEPARATE, so evaluation is correct by CONSTRUCTION.** Updating
statistics during evaluation is silent and real - the policy sees a normalisation it never
trained with, and the reported return depends on how many eval episodes were run. znum's `apply`
and `update` are both methods on the same object with nothing stopping a caller from doing both;
here `apply` cannot mutate, so the mistake is unavailable rather than forbidden. Same reasoning
as `Transition` splitting `terminal` from `truncated`.

### diagGaussianLogProb, Sep 14 - the continuous path can now be trained

`ppoClipLoss` takes the new log-probabilities as a `Var`, because the gradient has to flow back
through them. `DiagGaussian.logProb` works on Tensors and was therefore a dead end: right number,
no gradient, so **a continuous policy could be evaluated and never trained**. That was the last
structural gap in the continuous path.

★★ **COMPOSED FROM EXISTING OPS, SO THERE IS NO NEW BACKWARD TO GET WRONG.** Two of them do jobs
their names do not suggest, because the tape has neither broadcasting nor an axis reduction:

    matmul(ones[N,1], log_std[1,D])   broadcasts log_std across the batch
    matmul(per_dim[N,D], ones[D,1])   sums each row - a Gaussian's log density is a sum over
                                      dimensions, and this is what makes it one number per action

Both are linear maps against constants, so the tape already knows their gradients.

★ **A SHAPE WART, NAMED RATHER THAN HIDDEN.** The analytic form indexes `log_std` with `at1` and
wants rank 1; the tape form needs `[1, D]` because the broadcast is a matmul. Same distribution,
two spellings. Documented at both ends, and the test builds both from one array so a divergence
cannot hide in the setup.

Verified two ways: agreement with the analytic path row by row, AND `checkGradient` under 1e-7
against a central difference for both `mean` and `log_std` - agreement alone would pass with a
constant.

### RolloutBuffer, Sep 14

The on-policy path is now structurally complete: `RolloutBuffer` records, `gae` turns it into
advantages, `MinibatchOrder` walks it, `ppoEpoch` scores it.

★★ **IT REFUSES TO WRAP, AND THAT IS THE POINT.** A replay buffer is a ring; a rollout buffer is
not. GAE is a backward recurrence over a CONTIGUOUS horizon, so overwriting step 0 while the
trace through step N is still being built does not lose one sample - it corrupts every advantage
that depended on the overwritten step, and nothing in the numbers afterwards says so. `record`
returns `DomainError` when full.

★★ **`terminal` AND `truncated` ARE SEPARATE ARGUMENTS, and the buffer is the only place that
maps them onto `RolloutStep`'s pair.** `gae` was already correct - `terminal` kills the
bootstrap, `episode_end` breaks the trace - but a caller had to know that `episode_end` means
"terminal OR truncated". Now it does not. Plant-verified: setting `.terminal = terminal or
truncated` fails the test by the whole bootstrap, 9.0 against 1.0, not a rounding-sized
correction.

**Still missing for a full update:** the model-facing wrapper (run the network over each stride,
step the optimiser) and the four other update functions. Every piece under them now exists and
is tested.

### RL parity with znum, measured Sep 14

znum's `rl` namespace has 59 column-zero declarations. Comparing name by name, **44 were absent
from zimrnum** - but most of those are znum's own nested types and their methods (`Batch`,
`Config`, `Minibatch`, `Sample`, `Shape`, `Step`, plus `advance`/`apply`/`insert`/`record`/
`update`/`capacity`/`slotOf`), or its CPU/GPU dispatch split (`greedyDevice`, `logProbDevice`,
`sampleDevice`) which zimrnum declines by design - the sweep is its interface.

Closed this pass, both continuous-control essentials:

| | |
|---|---|
| `Temperature.forActionDim` | SAC's target entropy from the action dimensionality. zimrnum had the alpha math and no way to set the target; a diagonal Gaussian's entropy is a SUM over dimensions, so a target chosen for a 2-joint arm is six times too small for a 12-joint quadruped - and the symptom is not an error, it is alpha running away |
| `OrnsteinUhlenbeck` | Exploration correlated IN TIME. Independent noise on a torque averages to nothing against a mass: the joint never reaches the states a sustained push would, so the exploration is real at the actuator and invisible at the end-effector. Plant-verified - replacing the walk with independent draws fails the correlation test |

Both carry the units that matter in their docs (`1/theta` is the correlation time; `dt` must match
the environment's), and the `sqrt(dt)` scaling is explained rather than copied: a Wiener process
accumulates VARIANCE linearly, so scaling the noise by `dt` makes exploration vanish as the
timestep shrinks, which reads as a tuning problem and is not.

**Still genuinely missing from znum's RL surface:** the update functions (`ppoUpdate`,
`ppoUpdateContinuous`, `sacUpdate`, `td3Update`, `dqnUpdate`), the rollout buffers
(`RolloutBuffer`, `ResidentRollout`), `MultiCategorical`, and the residual-control helpers
(`residualAction`, `assistScale`, `criticallyDampedGains`, `trackingTerm`) which belong with the
robot work rather than here.

### Adversarial review of R2, Sep 14

Reviewed my own recent code against znum's. One real bug, one worthless test, both mine.

★★★ **THE BUG: `ppoEpoch` WAS NORMALISING PER MINIBATCH.** `ppoObjective` normalises whatever
slice it is handed, and `ppoEpoch` handed it a per-minibatch scratch copy while passing
`config.normalize_advantage` straight through. So the flag meant PER-MINIBATCH there and
PER-ROLLOUT everywhere else - **one config field, two behaviours, chosen by which function you
called.** That is znum's `desired_kl` failure reproduced in new code written specifically to
avoid it, three days after reading the review that described it.

The two are different algorithms, not two spellings. A minibatch of 32 estimates its mean and
spread from 32 samples, so the scale changes stride to stride and the relative weighting BETWEEN
minibatches is destroyed. Normalisation now happens once over the rollout, into a copy - the
caller's slice is `const` and stays untouched - and `ppoObjective` is called with the flag off.

★★ **THE WORTHLESS TEST, AND WHY IT LOOKED FINE.** The first probe used an UNCHANGED policy, so
every ratio was 1 and the surrogate reduced to the mean advantage - which is zero after ANY
normalisation. It passed under both implementations. **The difference between them is entirely
in the SCALE, and scale only reaches the objective through a ratio that is not 1.** The probe now
varies the ratios across the batch and compares against the objective computed by hand from the
same definition; plant-verified that the old behaviour fails it.

★ The general shape: **a test that cannot fail is worse than no test**, because it is counted.
Every assertion here should be run against the implementation it rejects before being believed.

## 3ag. softplus moved to zimrmath, and the rule for what else should follow

`zm.softplus` added; `zn.softplus`, `SquashedGaussian.softplusOf` and `squashCorrection` all
delegate to it. Zero copies of the formula remain.

★★★ **THE BOUNDARY IS SHADER-SAFETY, AND softplus WAS ON THE WRONG SIDE OF IT.** zimrmath's own
header says it "may be @imported by shader sources"; `relu`, `sigmoid`, `tanh` and `gelu` are all
there for exactly that reason. `softplus` was not - zimrnum had it as a tensor op with the scalar
spelled inline, and a THIRD copy appeared by hand inside SAC's squash correction when a kernel
needed it. Three spellings of one numerically delicate expression, none reachable from a shader.

★★ **THE TEST FOR WHAT ELSE BELONGS THERE IS NOT "IS IT AN ACTIVATION".** Surveying every
elementwise op in zimrnum against zimrmath's surface, almost all of the apparent gaps are
BUILTINS - `@exp`, `@abs`, `@floor` - where there is no duplicate to eliminate and no algorithm
to share. `silu` is `x * zm.sigmoid(x)`, a composition with nothing of its own.

**A scalar belongs in zimrmath when it is a genuine ALGORITHM - a stable formula somebody chose
over an obvious one - and a shader might need it.** By that test softplus was the only real gap,
and the survey is worth more than the move: it says the boundary is otherwise intact.

★ RL functions like `ppoClipSample`, `discriminatorReward` and `squashCorrection` stay in
zimrnum. They are scalar and shader-safe but they are DOMAIN functions, not mathematics - the
module edge is about what a thing is, not about whether a kernel can call it.

## 3af. More of the update path onto the device, Sep 15

111/111 after the polyak fix. Continuing along the same path: which operations in a SAC update
run on device but have never been compared?

★★★ **THE SQUASH CORRECTION WAS WRITTEN THREE TIMES AND VERIFIED NOWHERE.** SAC's tanh
log-density correction appeared inline in `SquashedGaussian.logProb`, again in
`Graph.squashedReparameterize`, and nowhere as a function. Now `squashCorrection` - extracted,
scalar-first, with both callers delegating to it. **A numerically delicate expression repeated is
one that gets improved in only some of its copies.**

★★ **ITS ROW FEEDS SATURATED INPUTS ON PURPOSE.** The field is scaled by 12 so it reaches
pre-squash values where `tanh` rounds to exactly 1 in f32 - where the textbook spelling
`-log(1 - tanh(u)^2)` becomes `log(0)`, and **where a converged SAC policy spends most of its
time.** A row fed ordinary small values would agree perfectly and check nothing.

★★★ **`sacTarget` IS NOT KERNEL-CALLABLE, AND THIS IS THE FIRST TIME ANYONE TRIED.** It takes
`next_estimates: []const T` - a slice, because it aggregates over however many critics there are
- and SPIR-V refuses: "cannot construct slices without the variable_pointers capability". So
despite reading like a scalar-first function it cannot run on a device as written. For a
GPU-resident trainer the aggregation must be unrolled at the call site, or the function needs a
fixed-arity twin for the twin-critic case. **Recorded in `zn_binary.zig` itself**, where the next
person to try it will be standing.

★ The harness has a compile-time check that every kernel entry has a sweep row, and it fired
during this work - a kernel shipped without a row is a kernel never compared, and it is now
impossible to do by accident.

Sweep init calls 5298 -> 5308.

## 3ae. The polyak row was red, and the DEVICE was right, Sep 15

110/111 on Simon's phone. `adam step (warm)` green at 1.2e-7 against its ULPS bar. `polyak follow`
red: 2.4e-7 against a bar of zero.

★★★ **NOT A TOLERANCE PROBLEM - THE TWO SIDES WERE COMPUTING DIFFERENT ARITHMETIC.** The CPU had
`keep * target + follow * online`; the kernel had `target + follow * (online - target)`. Same
algebra, different rounding, about two ULPs apart.

★★★ **THE KERNEL'S FORM IS THE BETTER ONE, AND THAT WAS MEASURED RATHER THAN ARGUED.** Over 200k
random pairs against an f64 reference: **26% less total error, and closer in 49,716 cases against
812.** So the fix was to change the CPU, not to widen the bar - a red row that improves the
library instead of being silenced.

★★ **BUT THE INCREMENT FORM LOSES BOTH ENDPOINTS**, and a test caught it immediately:
`follow = 1` must be an EXACT copy, and `held + 1*(online - held)` rounds twice where a copy
rounds not at all. `follow = 0` must be untouched. Those are the two settings a caller reaches
for deliberately - initialise, and freeze - so they are handled as what they ARE rather than as
limits of a formula. Two branches per call; both properties hold instead of one.

★★★ **MY FIRST PIN FOR THE INTERIOR CHOICE WAS A TEST THAT COULD NOT FAIL.** I asserted the
increment result at `held = 7.7, toward = -3.3` - and the two forms round IDENTICALLY there, so
the planted two-term version passed. Fixed by SEARCHING for a discriminating pair
(`-6.306793212890625` toward `0.23817278444766998`, where the forms differ in the last bits) and
saying in the comment that the values were searched for rather than picked.

★ That is the fourth test-that-cannot-fail this session and the first one found by planting
rather than by reasoning. **The plant is the only thing that distinguishes "my test passes" from
"my test works".**

## 3ad. The update path had a hole exactly the shape of znum's unsolved bug, Sep 15

Read znum's GPU RL work before planning physics tasks. What is there is decisive and worth
carrying forward.

### What znum found, and never resolved

★★★ **SAME CODE, SAME CONFIG, SAME SEEDS: THE CPU LEARNED AND THE GPU DID NOT.** Their
`rl-mirror` run put the browser export's configuration line for line on the CPU path:

    iteration       0      11      23
    CPU return   8.07   20.78   43.27
    GPU return   8.07    6.66    4.55

★★ **Iterations 0 and 1 agreed to within rounding.** Collection, GAE, the rollout and the FIRST
UPDATE are all correct on the device. **The divergence begins at iteration 2** - "a gradient that
is nearly right for one step and systematically wrong in direction thereafter". Eleven hypotheses
formed, six probes built, cause never found.

★ Also worth knowing before anyone plans from it: **znum's GPU cartpole was the BALANCE task, not
swingup.** Their own note says there is no swing-up anywhere in that tree.

### The hole in our own sweep, found by looking where their divergence started

★★★ **OUR `adam_step` KERNEL IS STRUCTURALLY FIRST-STEP-ONLY.** It computes the first moment as
`(1 - beta1) * gradient`, which is only true when the incoming moment is ZERO, and divides by
`1 - beta1`, which is only the bias correction at `t = 1`. The conformance row fills both moments
with zero, so CPU and GPU agree - **about the one update per training run where the moments are
empty.** Every update after the first takes a path nothing checked.

★★ **`polyakUpdate` HAD NO ROW AT ALL**, and it shares the shape: at the first update the target
has just been copied from the online network, so the follow moves a value to itself and any error
is invisible. From the second update onward it is the only thing keeping the bootstrap target
from chasing the critic that produced it.

**Two rows added: `adam step (warm)` and `polyak follow`.** The warm row carries moments with
history and bias correction at step 5; the incoming moments are DERIVED from the inputs so both
sides build them identically without the harness carrying two more buffers.

★ This does not prove znum's bug was either of these. It does mean that in our tree, the two
operations whose behaviour CHANGES between update 1 and update 2 were both unverified on device,
and now neither is. Sweep init calls 5278 -> 5298.

★ **The method is theirs, applied:** "when a system misbehaves only where you cannot observe it,
do not think harder about causes - build the smallest thing that halves the space." A conformance
row is the smallest thing available here, and it runs on a phone.

## 3ac. The second-order tutorial section, rewritten to derive rather than assert

The first version stated that gradients-of-gradients work and showed the call. That is not an
explanation of the hardest idea in the chapter.

★★ **THE REWRITE DERIVES THE WHOLE THING ON THE SMALLEST CASE.** For `D(x) = x . w`:
`dD/dx = w`, so the penalty is `|w|^2`, so its derivative is `2w`. Every step is ordinary
calculus - **and that is the point being made**: the only thing standing between us and it is
REPRESENTATION. If the gradient arrives as three floats the last step is impossible; if it
arrives as the expression "this is w" the last step is the differentiation the tape does every
day.

★★ **THE KEY OBSERVATION IS GIVEN ITS OWN SECTION WITH THE ALGEBRA SHOWN.** Every backward rule
is itself an expression in ops the tape already has - `dL/dx = g A^T` is a matmul against a
transpose, the product rule is two multiplies, a sigmoid's slope is `g*s*(1-s)`. So the emitted
graph is differentiable for the same reason any other graph is, and **there is no second-order
backward pass anywhere in the library.**

★ Maths is set in `<pre>` blocks with real glyphs rather than a renderer, since the tutorial
carries no MathJax. Verified that none of them land inside a `class="zig"` block, which the
arity checker parses as Zig source.

## 3ab. SECOND-ORDER GRADIENTS, Sep 15 - the blocking item is gone

`Graph.gradientOf(output, input) -> Var`. The item `advancedrl.md` opened with, called "the
largest single item anywhere in zimrnum's RL work", and scheduled last.

★★★ **IT NEEDED NO NEW BACKWARD.** The approach that worked is not "make `backward`
differentiable" - it is a SECOND walk of the same tape that **emits tape nodes instead of writing
tensors**. And every rule it emits is written with operations already on the tape: a matmul's
backward is a matmul against a transpose, a product rule is two multiplies. So the emitted graph
is differentiable for free, and second-order support cost no third-order machinery.

★★ **UNSUPPORTED OPS RETURN AN ERROR, NOT A NUMBER.** Staged to the ops a discriminator is built
from - add, sub, mul, scale, matmul, relu, sigmoid, tanh, row-sum, transpose. Anything else is
`Error.UnsupportedShape`, because **R2 was ranked the worst risk in the whole plan**: an
implementation that silently degrades to first-order produces a penalty that is constant, a
gradient that is zero, and an unregularised discriminator behind curves that all look fine.

★★★ **THE PLANT PROVED THE TESTS WERE NOT REDUNDANT - AND FOUND A BLIND SPOT.** Detaching the
matmul rule from the graph (exactly R2's failure) **passed the analytic-Hessian test** and only
failed the discriminator one, because the analytic case used `mul` and never touched the matmul
path. The analytic test now exercises matmul too, and the re-planted detach fails both.

★ That is the argument for `advancedrl.md` 0.3 specifying FOUR tests rather than one, made
concrete: each covered a rule the other left blind, and only running the plant revealed it.

### What is now possible

**AMP, ASE, ADD and HIL are fully expressible.** Every numerical ingredient those methods need
exists and is tested: the discriminator and its reward, the gradient penalty, skill latents and
the encoder reward, the transformer over a scene, the tracking kernels, DTW, and both update
loops. What remains for those methods is animation and physics, which this plan excluded by
design.

## 3aa. The DiT block, Sep 15 - stage 4 complete

`sinusoidalEmbedding`, `adaptiveLayerNorm`, `classifierFreeGuidance`, `emaUpdate`.

★★★ **THE `1 + gain` IN AdaLayerNorm IS WHAT LETS A DiT BLOCK TRAIN FROM SCRATCH.** With it, a
zero-initialised conditioning projection is the IDENTITY - the block passes its normalised input
through untouched and the condition does nothing. Without it, zero conditioning multiplies every
activation by zero and **destroys the signal before any gradient has arrived**. Plant-verified:
dropping the offset fails the identity test.

★★ **`emaUpdate` IS AN ALIAS, AS THE PLAN PREDICTED** - `polyakUpdate` with `1 - decay`. The
reason it exists at all is the argument convention: polyak takes `follow`, the SMALL number;
EMA literature quotes `decay`, the LARGE one. They differ by exactly 1, so passing one where the
other belongs gives a shadow that either tracks instantly or never moves, and **both look like a
working system that simply learns badly.** Asserted both ways round in one test.

★ **`sinusoidalEmbedding` is not diffusion-specific** and is filed accordingly: it is the
transformer's positional encoding with a timestep in place of an index. Geometric frequency
spacing is what covers both scales - fast components separate adjacent steps, slow ones
distinguish the start of the chain from the end - and the test asserts exactly that ordering
rather than any particular value.

★ **`conditioning_gain` and `conditioning_bias`, not `scale` and `shift`.** The paper names
shadow this file's tensor `scale`, and the chosen names say what the inputs DO rather than which
paper they came from. Third time the reserved-math-names collision has surfaced today.

## 3z. Adversarial review of the whole RL surface, Sep 15

Read every RL function against MimicKit and against itself, hunting bugs and bad names. **No bugs
found** - the arithmetic was cross-checked rather than assumed, including a `gae` recurrence
re-derived by hand and now pinned as a test. Three naming faults were real.

### The names that were wrong

★★★ **`ddimStep` CONTRADICTED ITS OWN DOCUMENTATION.** The doc says DDPM and DDIM are one update
separated by `eta`; the name picks one of them. Renamed `diffusionReverseStep` - for what it
DOES rather than for one of the two samplers it implements, neither of which has a better claim.

★★ **`logp_new`/`logp_old` AND `log_prob_new`/`log_prob_old` BOTH EXISTED** - 38 uses of one
spelling against 21 of the other, for the same concept, across the public API. All 48 are now
`log_prob_*`. MimicKit is inconsistent here too (`a_logp`, `log_prob`, `logp` all appear), so the
convention had to come from us rather than from them.

★ **`cartpoleContStep` ABBREVIATED FOR NO REASON.** `Cont` in a public name is a guess the reader
has to make. Now `cartpoleContinuousStep`, 31 occurrences across six files including the shaders
and the conformance table.

### What was checked and found correct

★ **`gae` against a hand-derived three-step case.** The recurrence is what every on-policy
algorithm sits on and is easy to get subtly wrong - a misplaced gamma, a lambda on the wrong
term. Numbers derived independently, matching to 1e-9, plus a lambda-zero collapse to the
one-step TD error, which is what checks that lambda applies to the TRACE and not the bootstrap.

★ **`ppoObjective` and `ppoClipObjective` are genuinely different** - one returns `PpoStats` with
diagnostics, the other the scalar surrogate - and `ppoEpoch` is not superseded by `ppoUpdate`: it
scores a rollout without needing a graph, which is a real use. All three stay.

### What MimicKit does that we deliberately do not

★ Their `_compute_actor_loss` / `_compute_critic_loss` / `_compute_disc_loss` split is per-agent:
each of ADD, AMP, ASE, AWR, LCP and SMP reimplements the loop around them. **Ours has two loops
total** - `ppoUpdate` and `offPolicyUpdate` - because the caller supplies the loss. That is the
same trade that made one sampler serve DDPM and DDIM, and one `min` serve TD3 and DroQ.

## 3y. The diffusion sampler, Sep 15 - stage 3 complete

`ddimStep` and `x0FromEpsilon`.

★★★ **THE PLAN'S CLAIM HELD: DDPM AND DDIM ARE ONE UPDATE WITH A PARAMETER.** MimicKit keeps two
scheduler objects for what is arithmetically one thing. `eta` alone separates them - zero is
deterministic DDIM, one is the original stochastic chain, and anything between is a valid sampler
trading diversity against speed. Same argument as `ppoUpdate` serving both action spaces and
`offPolicyUpdate` serving three algorithms.

★★★ **VERIFIED BY AN IDENTITY RATHER THAN A TOLERANCE.** If the noise prediction is exactly
right, a deterministic step from `x_t` lands exactly where the forward process puts `x_{t-1}` for
the same clean sample and the same noise - the reverse step IS the forward one run backwards.
Holds to 1e-12, with nothing to tune about what "close enough" means.

★★ **Plant-verified with the slip the docs warn about:** `alpha_bar_t` where `alpha_bar_prev`
belongs, in the direction term. That is the error that produces samples which are blurry rather
than broken, and the identity test rejects it immediately.

★ The deterministic term's coefficient shrinks by exactly the variance the stochastic term adds,
which is what keeps the step on the trajectory at any `eta` - and is why one function can be both
samplers rather than two that merely resemble each other. Asserted directly: with the fresh noise
at zero, raising `eta` must LOWER the deterministic contribution.

★ Both `@max(..., 0)` clamps are load-bearing at the chain's last step, where `alpha_bar` near 1
makes the variance terms cancel and a negative under a root would give a NaN at the very moment
generation was otherwise finished.

## 3x. Diffusion schedules, Sep 15, and a tutorial rewrite

`betaSchedule`, `alphasCumprod`, `addNoise`, `epsilonFromX0` - stage 3 less its sampling step.

★★ **THE SCHEDULE IS A STATEMENT ABOUT WHERE THE MODEL SPENDS ITS CAPACITY.** Steps with high
`alpha_bar` are nearly clean and teach fine detail; steps with low `alpha_bar` are nearly noise
and teach coarse structure. A linear schedule destroys the signal early, so half the trajectory
is spent on samples with nothing left to learn from - which is why motion models use cosine, and
why the test asserts the two schedules differ at the MIDPOINT rather than just at the ends.

★★ **THE TWO COEFFICIENTS SQUARE TO ONE**, so a unit-variance input stays unit-variance at any
timestep. That is what lets ONE network serve the whole trajectory; get the weighting wrong and
the scale of its input drifts from end to end.

★ `epsilonFromX0` is the forward process rearranged and exists as a named function because the
rearrangement is where `alpha` gets used for `alpha_bar` or a square root goes missing - and the
result is samples that are BLURRY rather than wrong. Blurry is indistinguishable from
undertrained, which makes it expensive to chase.

### The tutorial's RL chapter was rewritten

★★★ **IT HAD DRIFTED INTO HOW IT WAS BUILT RATHER THAN HOW TO USE IT** - twelve sections
organised around failure modes, with plant tests, attempt counts and "what it cost to get there".
Interesting to the person who wrote it and no use to a reader.

Rewritten usage-first: what the system IS, a complete worked example, then one section per
algorithm leading with the INTUITION - what a trust region is for, why the max over noisy
estimates is biased upward, what a discriminator's confusion buys you. The reasoning that
motivates a design stays; the history of arriving at it goes.

★ The dev-story count in that chapter went from 7 references to 0, and the tutorial's own arity
and type checks still pass on every rewritten example.

## 3w. The transformer, Sep 15 - an expression, not a primitive

`scaledDotProductAttention` and `encoderBlock`, closing stage 2b.

★★★ **THE PREDICTION HELD: NO NEW BACKWARD.** `advancedrl.md` claimed the encoder composes from
`matmul`, `transpose`, `scale` and `softmaxRows`, all already on the tape. It does. `Attention`
exists in this file as a CPU type that cannot be trained through, which LOOKED like a gap and was
not - the same shape as `diagGaussianLogProb`.

★ A measurement wobble worth noting: grepping for `pub fn transpose` found the TENSOR method
first, whose signature returns `Self` rather than `Var`, and for a moment that looked like a
missing tape op. Listing `Graph`'s methods by brace depth settled it. **The same
confidently-wrong-grep failure as the parity counts**, caught this time in seconds because the
habit of listing by structure rather than by pattern has stuck.

★★ **THE `1/sqrt(d)` IS A PARAMETER, NOT DERIVED FROM THE SHAPE.** Multi-head attention scales by
the HEAD dimension, not the model dimension, and only the caller knows which it has just sliced.
Dropping it entirely is the classic error: `Q K^T` sums `d` products so its variance grows with
`d`, the softmax saturates toward one-hot as the head widens, and the gradient through it
vanishes - **a wider model trains worse, which reads as a capacity problem and is arithmetic.**

★★ **THE TEST ASSERTS CONVEXITY, WHICH IS THE DEFINING PROPERTY.** Softmax rows sum to one, so
every output row is a weighted AVERAGE of the value rows and cannot leave their convex hull. An
implementation that multiplied by the scores directly gives plausible numbers that are not
averages of anything - plant-verified by removing the softmax.

★ `encoderBlock` is PRE-norm: `x + f(norm(x))`, leaving a path from input to output through no
normalisation, so gradient reaches the first layer undiminished. At HIL's two layers either works;
the reason to default to the one that survives depth is that **nobody revisits this choice when
they add layers.**

★ `checkGradient` runs on all SIX projections, because a dropped residual or a transposed weight
still produces an output of the right shape. The failure is slow convergence, not an error.

## 3v. Tracking rewards and DTW, Sep 15

`trackingKernel`, `mixRewards`, `dtwDistance` - the reward-shaping and evaluation layer HIL needs.

★★ **THE TRACKING KERNEL TAKES `|error|`, NOT `error`.** Without the absolute value a signed
difference makes the exponent POSITIVE and the reward grows without bound the further the motion
drifts one way - a caller passing a difference instead of a magnitude is an easy mistake and this
makes it harmless rather than catastrophic.

★ It also SATURATES, which is why `alpha` is per call rather than fixed: too large and the reward
is zero almost everywhere so a policy gets no gradient from improving; too small and it sits near
1 and says nothing. HIL uses six terms with alphas from 0.05 to 20 - one shared value would be
wrong for five of them.

★★★ **DTW's TEST IS EXACT, WHICH IS RARE HERE.** Zero against itself AND zero against a
time-scaled copy - the same motion at half speed costs nothing, which is the entire reason the
metric exists and is something frame-by-frame comparison cannot say. No tolerance argument to get
wrong.

★ **Plant-verified with the failure that matters:** restricting the recurrence to the diagonal
move IS frame-by-frame comparison, and it fails the time-scaling assertion while still passing
"zero against itself". Two of the four assertions would accept a function that always returned
zero; the other two are what make the test real.

★ Implemented with TWO ROWS rather than the full cost matrix. The recurrence only reads the
previous row, so memory is O(m) against O(n*m) time - for whole-episode comparison against every
reference clip that is the difference between kilobytes and megabytes per pair.

## 3u. Review of the stage 1-2 code, Sep 15 - a doc that lied

★★★ **`discriminatorReward`'s COMMENT CLAIMED A CHECK THAT DID NOT EXIST.** It said
`floor = 0` "is refused rather than accepted as no limit". It was not refused - the function is
SCALAR-FIRST and has no error union to refuse with, so a zero passed straight through,
`@max(fooled, 0)` returned `fooled`, and a saturated input gave `log(0)`. **The infinite reward
the floor exists to prevent, delivered by the argument meant to prevent it.**

The fix is structural rather than documentary: a `smallest` below the type's smallest positive
value is RAISED to it, so the bound is a fact whatever the caller passes. Plant-verified - passing
the caller's value through unraised fails the test.

★★ **THE CLAIM WENT UNTESTED FOR EXACTLY AS LONG AS IT WENT UNIMPLEMENTED.** Every other property
of that function has an assertion; this one had a sentence. **A doc comment describing behaviour
is a claim, and claims in this file are meant to be executable** - the whole argument for writing
the reasoning down is that it can then be checked. A sentence nobody can run is the one kind of
comment that can rot silently.

★ Also removed a dead store in the learning gate's collector: `start` was assigned at the end of
each episode and re-initialised at the top of the next. Now `const`, written once, read once.

## 3t. Stage 2: the adversarial primitives, Sep 15

`discriminatorReward` and `l2NormalizeRows`. A3 and A5 were already delivered by `reduceRows`, so
stage 2 is these two.

★★★ **THE STYLE REWARD'S FLOOR BINDS WHEN THINGS GO WELL.** A discriminator's logit is its
confidence that what it saw was real, so `-log(1 - D)` grows as the policy becomes
indistinguishable - and diverges as it wins. **An unbounded reward drives the value function to
infinity and the advantages with it, so the run collapses at the moment it starts succeeding**,
which is the hardest moment to attribute. `smallest = 0` is refused rather than accepted as "no
limit".

★★ **`1 - sigmoid(x)` IS WRITTEN AS `sigmoid(-x)`, AND THEY ARE NOT THE SAME NUMBER.** For a
confident discriminator `sigmoid(40)` rounds to exactly 1.0, so the subtraction cancels
completely and gives zero; `sigmoid(-40)` underflows smoothly instead. Without the second form
the floor would be masking a cancellation rather than capping a divergence - and the two would
disagree about WHERE it binds. Both facts are asserted in the test.

★★ **`l2NormalizeRows`'s test is not "does it normalise".** ASE's encoder reward is
`sum(z * prediction)`, a cosine similarity ONLY because both sides have length one. Unnormalised,
the encoder raises its score by predicting LARGER vectors rather than better-aimed ones and the
diversity objective becomes a magnitude contest - nothing fails, the skills just stop being
distinct. So the assertion is that the dot product stays bounded by 1.

★ `epsilon` goes INSIDE the square root. A zero row then normalises to zero either way, but a
NEAR-zero row is scaled by something finite instead of exploding, which is the case that matters.

### Verification: all three artefacts, as the rule requires

`discriminatorReward` is scalar-first, so per `advancedrl.md` 2b.1 it gets a CPU test, a line in
the SPIR-V probe, AND a conformance row - **in the same change**, which is R7's mitigation.

★ The probe passes a SATURATED logit deliberately: a probe that only ever passed a small one
would compile the arithmetic and never reach the clamp the function exists for.

★ The row carries `.ulps = 8` from the start. `sigmoid` and `log` are both transcendental, so
claiming zero would have repeated this morning's mistake - the lesson transferred within a day,
which is the first time that has happened rather than being rediscovered.

## 3s. THE FIRST LEARNING GATE PASSES, Sep 15 - AWR doubles a cartpole policy

**31.1 -> 63.3 mean episode length**, measured without exploration noise both times. A linear
policy on cartpole-hold, trained by AWR, 300 iterations, one second.

★★★ **THIS IS THE ONLY TEST THAT COULD HAVE CAUGHT WHAT IT CATCHES.** Every piece underneath has
its own test and every one of them passes on a stack that does not learn: `advantageWeights` can
be right while the advantages carry the wrong sign, `diagGaussianLogProb` can be right while it
is wired to the wrong actions, the whole update can run and report finite losses and change
nothing useful. A gate that demands the policy get BETTER is a different kind of evidence.

### What it took, and what each attempt taught

★ **Attempt 1** (lr 0.02, 60 iterations): 31.1 -> 35.7, weights around 0.01. Learning, in the
right DIRECTION - the pole and pole-rate weights were positive, which is what balancing needs -
but far too small to matter.

★★ **Attempt 2** (lr 0.5, 200 iterations): weights reached 0.41 and 0.89, a recognisable
controller shape, and the return did not move. **The diagnosis was in the units:** the policy's
forces were fractions of a newton against a task whose useful range is +/-10 N. The weights were
right and the actions were negligible.

★★★ **Attempt 3** - the fix was NOT more learning rate, it was the EXPLORATION SCALE. With
`sigma = 0.5` the policy can only ever sample forces near zero, so it never observes what a real
push does and has no gradient toward one. Raising it to 2.0 made the task discoverable and the
return doubled immediately. **A policy cannot learn from an action it never takes.**

### Cost and placement

One second, so it stays in the normal suite rather than needing the separate `zig build learn`
tier `advancedrl.md` anticipated. That is worth knowing: a learning gate does not have to be slow
to be real, as long as the task is small enough that a linear policy suffices.

★ The linter caught `catch unreachable` in the collector - UB in release - and refusing it was
right. It is a sentinel now, and the assertion rejects the sentinel, because a policy cannot
improve on a rollout that never ran.

## 3r. AWR's two primitives, Sep 15 - and a bound the references do not have

`advantageWeights` and `maskedMean`, plus `stepParameters` extracting the byte-identical step
loop the two update functions shared.

★★★ **THE WEIGHTS ARE BOUNDED BOTH WAYS, WHICH THE REFERENCE IMPLEMENTATIONS ARE NOT.** Capping
the top is standard: `exp` of a large advantage is enormous, so one sample five betas above the
rest carries `e^5` times an average one and the batch's whole gradient becomes "do that" - stably,
confidently, **reporting a small loss while doing it**, because a weighted mean dominated by one
term is still a small number.

The bottom matters for the same reason and is usually left alone. **`exp(-800)` underflows to
EXACTLY ZERO**, so a sample far below average is not in the batch at all - and when a whole
minibatch sits below average, which happens before the advantages are normalised or when a policy
is briefly bad, every weight is zero, the loss is zero, and the update does nothing while
reporting convergence.

The floor is `1/max_weight`, symmetric with the cap in log space, so best-to-worst is bounded by
`max_weight^2`. **A sample can be made negligible; it cannot be made absent.**

★★ **Both bounds are tested before the `exp`, not clamped after it** - `exp(800)` is infinity, and
an infinity that meets a zero elsewhere in the batch is a NaN no later clamp ever sees. The
endpoints are also EXACT: `exp(log(max_weight))` differs from `max_weight` in the last bit, so a
caller testing `weight == max_weight` to detect saturation would never see it. My first version
did exactly that and the test caught it.

★ `maskedMean` refuses an empty mask rather than returning zero. Returning zero for
"nothing selected" is wrong in the direction that hides: a zero loss looks like a converged one.

★ **Stage 1 is not finished.** The primitives exist and are tested; `advancedrl.md` 2b.4 says the
stage ends when AWR LEARNS cartpole. That is the next thing, and it is the first learning gate.

## 3q. `diff` SOLVED, Sep 15 - it was our arithmetic, not the driver

**107/108: `nan direct` passed.** A bare `nan(f32)` reaches the output buffer intact, so the
bitcast survives, the driver holds NaN, and every hypothesis about fast-math was wrong. That one
row cost nothing and eliminated an entire branch of the search.

★★★ **THE BUG WAS THAT THE KERNEL AND THE CPU COMPUTE DIFFERENT FUNCTIONS.**

`zn.diff` steps over the LAST AXIS. The sweep hands it a rank-2 `[64, 64]` tensor, so **every
row's column 0 has no predecessor and every row gets a NaN** - 64 holes. The kernel tested
`id == 0`:

    bout[id] = if (id == 0) nan(f32) else bx[id] - bx[id - 1];

One hole in the whole buffer. So 63 rows disagreed in TWO ways at once: a finite value where NaN
belonged, and a difference taken across the row boundary against the previous row's last element.
The kernel is now row-aware via `params.cols`, which the harness has been setting all along.

★★ **THE LESSON IS ABOUT WHERE I LOOKED.** The evidence was a finiteness mismatch, the code had
recently been through a hard SPIR-V/WGSL fix, and the phi transpilation is genuinely tricky - so
the search started at the transpiler, moved to the driver, and reached the arithmetic last. **The
arithmetic is the cheapest thing to check and it was checked last**, because the recent trouble
made a familiar-looking explanation available. Suspicion follows memory rather than probability.

★ `src/gpu/zn_unary.zig` already carried a note that `slice_columns` had a `cols` bug that "cost a
red row on device". The same class of bug, in the same file, with a comment about it twenty lines
away.

★ **Why it survived so long:** `diff_forward` could not compile for a device until this morning's
NaN fix, so the row had never actually run. It was not a regression - it was the first time
anything checked.

## 3p. `diff` on device: the transpiler is NOT the suspect, Sep 15

**106/107 after the ULPS correction** - both RL rows green. `diff` alone remains, reporting `inf`,
which `compare` emits only on a FINITENESS MISMATCH: the device returns a finite value where the
CPU returns NaN.

★★★ **THE TRANSPILED WGSL WAS READ END TO END AND IS CORRECT AT EVERY STEP.** The obvious
suspicion - that this is more of the SPIR-V/phi trouble from earlier in the session - does not
survive looking:

    if (_1105) {                                  // p1011 == 0u
      let _1112: f32 = zimrmath_nan__func_3();
      v1100 = _1112;
      phi1198 = 13u;
    } else {
      ...
      v1100 = _1192;                              // x[i] - x[i-1]
      phi1198 = 13u;
    }
    kbuf_out.field_0[_1068] = v1100;

The branch selects the NaN path for element 0, the phi is consistent, and the chain beneath it -
`zimrmath_nan__func_3` -> `zimrmath_splatTo__func_4` -> `nonfinite_2143289344` - ends in a bit
pattern held in a runtime `var` so the constant evaluator cannot fold it. **Every line is what it
should be.** The value is lost at or below the driver.

★★ **BUT "at or below the driver" still spans four things**: a three-deep call chain, a branch, a
phi, and a buffer store. So rather than guess, a row was added that removes all of them.

    pub fn nan_direct(id: u32) void {
        if (id >= params.count) return;
        bout[id] = nan(f32);
    }

★ The first version wrote `if (x == x) nan else nan` to keep the input live, and the transpiler
faithfully emitted the branch and the phi - **two of the three things the kernel existed to
eliminate.** Removed; it is now one call and one store.

**What the next device run tells us, either way:**

| `nan direct` | conclusion |
|---|---|
| RED | the bitcast does not survive on this hardware. A driver assumption about NaN, and no transpiler work will fix it - the response is to decide what `diff`'s hole should be on a device that cannot hold NaN |
| GREEN | the bitcast is fine and something between it and `diff`'s store destroys the value. Next bisection step is the three-deep call chain |

## 3o. First device run of the RL rows, Sep 15 - two mistakes, one real finding

**104/107 on Simon's phone.** Three red, and it is worth being exact about whose fault each is.

### The two that were mine: a tolerance claim that was simply wrong

`ppo clip` missed by 3.8e-6 and `cartpole pole` by 1.2e-7, both against a bar of ZERO that I had
argued for in the row's own comment:

> "no accumulation, so summation order cannot differ and there is nothing to round differently"

★★★ **The reasoning ignored the transcendentals.** `ppoClipSample` opens with `@exp`;
`cartpoleContStep` calls `sin` and `cos`. A transcendental is not required to be bit-identical
between a CPU libm and a GPU's hardware approximation - which is why `sin`, `cos`, `log` and
`exp` ALL carry allowances in that same table, several of them written by me earlier in this
session.

★★ **And the second half of the claim was worse:** "both sides take the same path through the
same `zm` functions". They take the same path through the same SOURCE. On a device that source
becomes the hardware's `sin`, not the CPU's. **Calling one function from both sides guarantees
the same formula, never the same last bit** - which is exactly the property the scalar-first
discipline was for, and I overstated what it buys.

Both rows now carry `.ulps = 8` - an allowance in units of the row's own magnitude, because the
surrogate scales with the advantage and a fixed absolute bar would be loose at one end and tight
at the other. The measured misses are 1 ULP and well under it.

### The one that is real: `diff` produces a finite value on device where the CPU produces NaN

`compare` reports `inf` only on a FINITENESS MISMATCH, and it handles both-NaN correctly (two
NaNs are agreement). So the device is returning something finite where `diff`'s first column
must be NaN.

★ **This is NOT pre-existing, and it is not newly broken either - it is newly VISIBLE.** Before
the WGSL fix earlier today, `diff_forward` failed to create a pipeline and the whole page
errored, so no row ran at all. The kernel now compiles, runs, and returns the wrong value: the
emitted helper is

    fn nonfinite_2143289344() -> f32 {
      var b: u32 = 2143289344u;
      return bitcast<f32>(b);
    }

which is a correct quiet NaN (0x7FC00000) routed through runtime storage precisely so the
constant evaluator cannot fold it. **The compiler no longer folds it; something at or below the
driver is still not delivering a NaN.**

**Most likely cause, untested:** many mobile drivers compile shaders with fast-math / no-NaN
assumptions, under which a NaN bit pattern may be flushed or treated as unspecified.

**The diagnostic to run next, in order:** (1) a kernel that writes `bitcast<f32>(b)` straight to
the output with no arithmetic after it, to separate "the bitcast does not produce a NaN" from
"a later operation destroys it"; (2) if the bitcast survives, bisect the arithmetic between it
and the store. **Do not widen the tolerance** - a row that accepts a finite answer where NaN is
correct is a row that has stopped asking the question.

## 3n. The first RL rows in the GPU sweep, Sep 15

The sweep covered 92 kernels and **not one reinforcement-learning operation**. Two rows now:
`ppo clip` and `cartpole pole`, both **tolerance ZERO** - neither accumulates, so summation order
cannot differ and there is nothing to round differently.

★★ **Both sides call the SAME function.** That is what `ppoClipSample` and `cartpoleContStep`
being scalar-first was FOR, and until now it was an intention: the SPIR-V probe proved the shape
compiles, only a row proves the device agrees on the numbers.

★ **The `ppo clip` row encodes the log-ratio in `a` and the advantage in `b`**, so `logp_old` is
zero. Not a compromise - with the advantage varying in sign across the input field, BOTH clip
branches are exercised. A row that fixed the advantage positive would only ever test the upper
one, and the `@min` that makes this a trust region would be half-verified.

★ Sweep init calls went 5238 -> 5258, which is how you can tell the rows are actually running.

## 3m. reduceRows, Sep 15 - one op, three plan items, five duplications removed

`advancedrl.md`'s U1, landed. The tape had no axis reduction, so every function needing one
spelled it as a matmul against a column of ones - `diagGaussianLogProb`, `klGaussianDiag`,
`categoricalLogProb` and `squashedReparameterize`, five folds between them, each allocating that
column per call.

`Graph.reduceRows(x, kind)` replaces all five and **delivers three things the advanced plan listed
as separate work**: `squaredRowNorm` (A3), `rowDot` (A5), and a differentiable row max (H3, the
PointNet aggregation HIL needs).

★★ **TWO TAPE TAGS, NOT THREE.** `.mean` is `.sum` scaled by `1/D` and is composed, not given its
own op - a second backward differing from `sum`'s by a constant is two implementations of one
derivative, which is how they drift.

★★★ **THE MAX RECORDS ITS WINNER AS A MASK, HELD AS A GRAPH VALUE** - the same mechanism
`dropout` uses for its own. The backward then multiplies by the mask and makes NO decision at
all. Re-deriving the argmax there would be a second decision from the same data, and
`recompute()` runs every minibatch, so on a tie the two could disagree and the gradient would
land on an element the output did not come from. Tested with a deliberate three-way tie across
five `recompute()` cycles: the lowest column every time, and exactly one unit of gradient
distributed, never shared.

★ **Permutation invariance is asserted BIT-IDENTICALLY**, not approximately. A max over the same
values in a different order is the same value exactly. `.sum` is only invariant to rounding -
floating-point addition is not associative - which is why the PointNet claim is about the
POOLING and the test says so.

★ **U3 also landed:** `klToReference` is now `Graph.klGaussianDiag`, so the rule is *the tape twin
has the CPU name, in the `Graph` namespace*. The free function and the method share a name
without colliding.

## 3l. Graph.min, Sep 14 - the first new backward

Everything else the RL work needed composed from existing ops - `diagGaussianLogProb`,
`klToReference`, `categoricalLogProb`, `squashedReparameterize` - so none needed a new backward.
This one cannot: `min(a,b) = 0.5*(a + b - |a-b|)` and `abs` is not on the tape either.

**What it is for:** pessimism about value estimates, which is the single most common fix for the
single most common failure in off-policy RL. A Q-function trained on its own bootstrapped targets
OVERESTIMATES - the max over noisy estimates is biased upward, and the bias feeds back through the
target, so the critic diverges upward while the policy chases actions it has overrated. TD3 takes
the smaller of two critics; DroQ takes the smallest over M dropout masks of ONE critic, which is
an ensemble's pessimism at a fraction of the compute and is what makes a high update-to-data ratio
affordable. Both are this operation folded over however many estimates there are.

★★ **TIES GO LEFT, AND NEVER HALF TO EACH.** `min` is not differentiable where the inputs are
equal, and splitting the gradient evenly is the defensible-looking choice that is wrong in
context: **DroQ takes the min over masks of the SAME network**, so the inputs are frequently equal
early in training, before dropout has diversified them - and a half-gradient to each would quietly
halve the effective learning rate exactly when the critic is furthest from right. Plant-verified:
the even split fails the routing test.

The convention matches `@min` itself and the lowest-index rule in `Categorical.greedy` - decided,
not better.

## 3k. Review + tutorial pass, Sep 14

### The review finding: a parameter that existed to be copied out of

`offPolicyUpdate` took a `batch_scratch: []T`, filled it from replay, and `@memcpy`'d it into the
graph leaf. **`ReplayBuffer.sample` writes into whatever slice it is given**, so the leaf was
always the slice - the parameter forced every caller to allocate a batch-sized array whose only
job was to be copied out of. Removed; the test passes unchanged, which is the point.

★ Checked `ppoUpdate` for the same thing and it was already clean: the minibatch width comes from
the leaf tensor's size rather than a parameter, so there is no way to pass a width that disagrees
with the graph.

### The tutorial: chapter 18b, "Reinforcement learning, end to end"

Six sections, organised around a single claim - **every failure mode in this stack is silent**.
None crash, none produce a NaN, none fail a test that checks the code ran. They make the returns
worse and say nothing. That framing is what the chapter is FOR; a list of function signatures
would not have earned a chapter.

| | |
|---|---|
| 18b.1 | terminal vs truncated - the distinction in all three places it appears |
| 18b.2 | the rollout buffer that refuses to wrap, and why GAE requires that |
| 18b.3 | one update loop, both action spaces - with znum's 61% as the counterexample |
| 18b.4 | three orderings that never fail loudly: normalise/shuffle/step, target-after-step, size-weighted stats |
| 18b.5 | **a table of what has to be on the tape** - four quantities zimrnum has twice, where the number is a dead end for training and nothing in the type says so |
| 18b.6 | hold and swingup as two problems |

★ 18b.5 is the one worth keeping. Four times now the same shape has appeared: a quantity exists as
a number and as a graph node, the number is correct, and using it means the policy can be
evaluated and never trained. `DiagGaussian.logProb`, `SquashedGaussian.sample`,
`Categorical.logProb`, `klGaussianDiag` - each needed a tape twin, and each time the gap was
invisible until something failed to learn. The table makes the pattern findable instead of
rediscoverable.

## 3j. One offPolicyUpdate for SAC, TD3 and DQN - Sep 14

Strip the three algorithms down and the loop is identical: sample a batch from replay, write it
into the graph, recompute, descend a critic loss, let the target network follow. What differs is
the TARGET - `sacTarget` adds an entropy term, `dqnTarget` takes a max or a double-Q lookup, TD3
takes the minimum of two critics - and whether an actor step follows.

**Every one of those differences is in a value the caller computes, not in the loop.** So the
loop is written once. With `ppoUpdate` covering both action spaces, **two functions here cover
all five of znum's.**

★★ **THE FOLLOW IS AFTER THE GRADIENT STEP, AND THAT ORDERING NEVER FAILS LOUDLY.** A target
network exists to make the regression target stand still while the online network chases it.
Following BEFORE the step moves the goal the batch was aimed at, partway through the aim - the
targets were computed from the OLD target network, so the follow has to come after the step that
used them. Training still converges, just more slowly and less stably, and the cause reads as a
bad learning rate.

★ `follow` is the SMALL number. `polyakUpdate(target, online, follow)` moves the target a
fraction `follow` toward the online weights, so the usual value is 0.005, not 0.995. Passing the
complement gives a target that tracks almost instantly - which is the same as having no target
network, and reintroduces exactly the instability one is for.

★★★ **THE TEST CAUGHT NOTHING UNTIL IT WAS CHECKED AFTER ONE STEP.** The lag assertion was first
written at the END of training, where the critic has converged, the gradient has vanished, the
online weight has stopped and the target has CAUGHT UP - so it compared two numbers that are
supposed to be equal by then and passed under both orderings. Checked after exactly one step,
`target == 0.5 * online` holds for the correct order and `target == 0` for the wrong one.
Plant-verified.

That is the fourth can't-fail test this session, and the only one I introduced by a botched edit
rather than by bad reasoning - the cleanup that moved the assertion deleted it instead. **Run the
plant after every edit to a test, not only after writing one.**

## 3i. One ppoUpdate, both action spaces - Sep 14

★★★ **`ppoUpdateContinuous` IS NOT A GAP. IT IS THE DUPLICATION zimrnum SET OUT TO AVOID.**

znum has `ppoUpdate` and `ppoUpdateContinuous`, **61% identical by its own review and already
diverged** - a config field silently ignored on one path. zimrnum has one, because `PpoModel`
takes the LOSS from the caller: the only thing that differs between a discrete and a continuous
policy is which function produced `log_prob_new`. The update never learns the difference.

Claimed, then EXECUTED: the same `ppoUpdate` that moves a Gaussian policy now moves a categorical
one, in a test where class 1 is always rewarded and its logit must rise relative to class 0.

★★ **But the claim was only half true when I made it.** The discrete path could not be BUILT:
the tape had `crossEntropy`, which reduces to a SCALAR - the mean over the batch - and PPO needs
one log-probability PER SAMPLE, because the ratio is formed and clipped per sample. **A mean
cannot be un-meaned.** `Graph.categoricalLogProb` is the missing piece, and it is composed from
existing ops so there is no new backward to get wrong: multiply the row-wise log-softmax by a
one-hot and sum each row, which picks the chosen element and sends the gradient to that logit and
zero elsewhere.

★ Safe to take `log(softmaxRows(x))` here specifically because `softmaxRows` subtracts the row
maximum first - the underflow that makes this a bad idea in general is handled one level down.
Verified against `Categorical.logProb` to 1e-12 and by `checkGradient` under 1e-7.

## 3h. Hold and swingup are two tasks, and both run on a device - Sep 14

★★★ **THEY ARE DIFFERENT PROBLEMS, NOT ONE TASK WITH TWO REWARDS.** Three things change, and
the third is what makes it structural:

| | hold | swingup |
|---|---|---|
| start | near upright | near `pi` - hanging |
| reward | 1 per surviving step | `cos(angle)`: +1 up, -1 down |
| **ends on angle** | **yes, past 12 degrees** | **NO** |

That last row is the one that matters. **The pole is SUPPOSED to rotate through the bottom** in
swingup - terminating on angle would end every episode in the first few steps, before the policy
could do the one thing the task is about. And a flat survival bonus carries no information about
which way is up: fine when you START upright, useless when you do not.

The consequence is that swingup needs ENERGY PUMPING - swinging back and forth to build
amplitude - which no amount of local correction discovers. **A policy that solves hold is not
partway to solving swingup**; it has learned a reflex the other task never rewards.

★★ **THE DYNAMICS NEVER CHANGE.** `cartpoleOutcome` is the only place the two differ, and
`cartpoleTaskStep` is `cartpoleContStep` plus that judgement. So the tasks cannot drift apart in
their physics, which is the same discipline that made `cartpoleStep` a wrapper over the
continuous form.

### The GPU half

`cartpoleContStepBatch` steps a whole batch, one row per environment - the shape znum's resident
rollout uses, because collection is embarrassingly parallel and is where on-policy RL spends its
wall clock. Pinned by a test asserting the batch matches the scalar form row for row.

★★ **And the dynamics are now IN the SPIR-V probe.** `zig build zn-rl-gpu` compiles
`cartpoleContStep` and BOTH tasks' `cartpoleOutcome` through a real shader entry point - both,
because they differ in a `switch` and because `swingup` calls `cos` where `hold` does not, so a
probe that only exercised `hold` would not notice the trigonometry failing to lower.
Plant-verified: a slice inside the swingup reward gives `cannot construct slices without the
'variable_pointers' feature` at build time rather than on a device.

## 3g. Continuous cartpole, Sep 14 - the gate zimrnum could not run

★★ **THE PHYSICS IS SHARED, NOT COPIED.** `cartpoleStep` is now a two-line wrapper that turns
`Push` into +/-10 N and calls `cartpoleContStep`. The discrete and continuous tasks are THE SAME
ENVIRONMENT by construction, so a result on one transfers to the other. Two transcriptions of the
same equations would drift and nobody would notice - both would still balance a pole. Pinned by a
test asserting exact equality of all four state components at +/-10 N.

★★ **WHY THE CONTINUOUS TASK IS A DIFFERENT PROBLEM AND NOT A DIFFERENT SPELLING.** The discrete
cartpole gives the policy two choices: shove left at 10 N or right at 10 N. It cannot do nothing
and it cannot push gently, so balancing means CHATTERING - a policy that has learned the task
looks like one that is hunting. A continuous force lets it output 0.3 N and hold, which is a
harder credit-assignment problem (the advantage of 0.3 over 0.4 is small and noisy where left
over right is large) and the one every real actuator poses.

It is also the only thing in the tree that exercises `DiagGaussian`, `SquashedGaussian` and
`OrnsteinUhlenbeck` at all - the discrete task touches none of them.

★ `force` is deliberately NOT clamped. A caller with a bounded actuator should squash before
calling (`SquashedGaussian` already produces `(-1, 1)`); clamping inside the dynamics would hide
an unbounded policy rather than fix it.

★ **`cartpoleReset` already existed** and I nearly added a second one - caught by the compiler,
not by looking first. `cartpoleObserve` is the genuinely new piece beside the step: the ONE place
the observation ordering is fixed, which is why `CartpoleState` is a named struct rather than a
`[4]T`. A policy trained on one ordering and evaluated on another produces confident nonsense and
the shapes still match.

## 3f. ppoUpdate, Sep 14 - and the snapshot that would have made it useless

`PpoModel(T)` describes WHERE to write and WHAT to descend; the caller owns the architecture and
builds the loss, the update owns the loop. Same split as `Fitting(T)`, for the same reason: a
loop that hard-codes a loss can only train one kind of model.

The three loops are ordered deliberately. **Normalise once** over the whole rollout, before any
epoch. **Shuffle per epoch**, so each sees a different partition of the same data. **Step per
minibatch.** Moving normalisation inward would re-standardise data that has not changed; moving
the shuffle outward would show the optimiser the same partition every time.

★★★ **`ppoClipLoss` COPIES ITS INPUTS, AND THAT NEARLY MADE THE WHOLE LOOP A NO-OP.** It stores
`logp_old` and `advantages` in the node at BUILD time - correct for its own gradient, since
neither is differentiated - and `recompute()` then re-runs it against those frozen values. Inside
a minibatch loop, where every stride has different old log-probabilities and advantages, the
policy is optimised against the FIRST minibatch forever.

**Nothing fails.** The loss is a real number, the gradient flows, the weights move, the return
curve is merely flat. `Graph.setPpoClipInputs` is the fix - the one sanctioned writer of that
buffer - and the update calls it each stride.

★ **It was caught only because the test demanded the weight MOVE IN A KNOWN DIRECTION.** A
one-feature, one-action linear policy where half the rollout took `+1` and was rewarded: the
correct update must raise `w`, and that is provable by hand rather than by running it. A test
that had checked "the loss is finite" or "no error returned" would have passed on the broken
version. Plant-verified: removing the refresh fails it.

## 3e. Adversarial review of the Sep 14 RL work

Reviewed everything added this session against znum and against itself. The maths held up -
`squashedReparameterize`'s correction was checked against the identity
`log(1-tanh^2 u) = 2(log2 - u - softplus(-2u))` and against the independently-written analytic
`SquashedGaussian.logProb`; `klGaussianDiag` matches the closed form term by term. Two things
did not.

★★ **THREE SHAPE CONVENTIONS FOR ONE VECTOR.** A policy's `log_std` is `[D]` for the analytic
types (`DiagGaussian`, `SquashedGaussian` index it with `at1`) and `[1, D]` for the tape forms
(`diagGaussianLogProb`, `squashedReparameterize` broadcast with a matmul, which has no rank-1
case). Both constraints are real and neither can move.

`klGaussianDiag` had picked one arbitrarily. It is newer than both and is the natural MEETING
POINT - it compares a policy against its old self, and the caller may hold either shape - so it
now accepts both, via `flatLogStdLen`. A rank-2 `log_std` with more than one row is still
refused: that is a caller mistake, and accepting it would silently read only the first row.

★★ **A ONE-STEP ROLLOUT ZEROED THE GRADIENT AND REPORTED SUCCESS.** `ppoEpoch` with
`normalize_advantage` on and a single sample: normalising one advantage subtracts it from itself,
so the result is exactly zero, the surrogate is zero, and the update changes nothing while
reporting `policy_loss = 0.0`. **That reads as a converged policy rather than an empty batch.**
`normalizeAdvantages` did refuse it, but the error surfaced two levels down with no mention of
rollouts. `ppoEpoch` now checks `n < 2` itself.

★ Neither was found by a test. Both were found by reading the new code against the old with the
question "what would this do if it were wrong" - which is the only thing that finds the failures
that report success.

## 4. Standing rules

★★★ **THE TEST LOOP FOR THIS PLAN IS `zig build zn-zimrnum`, NOT `zig build test`.**

`src/tests.zig` never mentions zimrnum, so `zig build test` does not compile or run a single
line of it - it finished in 2 s after a zimrnum edit, having rebuilt nothing. That is how a
`numericalGrad` conversion writing through a `@constCast` const array passed it twice.

Measured, after a real edit to `src/zimrnum.zig`:

| command | wall |
|---|---|
| `zig build zn-zimrnum -Dgate=false -Dtest-filter="zn eig"` | **21 s** |
| `zig build zn-zimrnum -Dgate=false` (all its tests) | **71 s** |
| same, nothing changed | **~1 s** |
| `zig build test-fast` (six modules) | 71-212 s |
| `zig build test` | does not build zimrnum at all |

`-Dgate=false` skips the lint/fmt pass that otherwise runs before every compile; keep it off
while iterating and let the gate catch style at the end.

★ **Run `zig build test-fast` before calling an item done.** It is what the gate runs, and it
catches breaks in a module you did not think you had touched.


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

---

## 8. Audit, Sep 12 2026 — this document's roadmap is not trustworthy on its own

v3 opens by saying v2 listed three blocks as missing that were already done, and tells you to grep
before believing it. **v3 has the same disease**, and the cause is now clear: the roadmap was
written by matching against numpy/torch SPELLINGS, so anything zimrnum implemented under a
different name reads as absent.

`grep -cE "pub (fn|const) LSTM\b"` returns 0. The library has `LstmCell`, `LSTM`, `bind`,
`stepBound`, and two tests — one of which, `zn LSTM: it learns to remember the first step, which
a feedforward net cannot`, IS verbatim this plan's "done when" for Tier 1 #1, held to a stricter
bar than the plan asks (the baseline is the target's variance, not zero). A full afternoon of
Tier 1 #1 was already on disk.

★★ **Grep case-insensitively AND for substrings, never for the torch spelling.** The names that
mislead are the ones where zimrnum chose a better one.

What the audit found, checking every name in §3 against the actual declarations:

| plan says missing | actually present as | verdict |
|---|---|---|
| `LSTM` | `LstmCell` **only** — one timestep, no sequence loop | the CELL was wrongly listed as absent; the sequence level was genuinely missing and is now built |
| `BatchNorm1d` (Tier 2 #6) | `BatchNorm`, with a mode-argument design and its own test | **DONE, wrongly listed** |
| `MaxPool2d` (Tier 2 #6) | `maxPool2d` | **DONE, wrongly listed** |
| `rolling` (Tier 2 #7) | `rollingMean` | partial — other reductions absent |
| `tile` (Tier 3 #11) | `tile` | **DONE, wrongly listed** |
| `ReplayBuffer` (Tier 2 #8) | `ReplayBuffer` | **DONE** (already flagged Sep 12) |
| `SGD`/`AdamW`/`RMSprop`/`Adagrad` | `sgdStep`, `sgdMomentum`, `adamWStep`, `rmspropStep`, `adagradStep`, `Adam` | the STEPS exist; the optimiser STRUCTS do not |
| `LuResult`/`QrResult`/`SvdResult` | `lu`, `qr`, `svd` | the functions exist; the result TYPES do not |
| `eig` | `eigh`, `eigvalsSymmetric` | symmetric only — **non-symmetric genuinely missing, as stated** |
| `GRU`, `BiLSTM`, `StackedLSTM` | — | genuinely missing (GRU done Sep 12) |
| `Dataset`/`DataLoader`/`fit` | — | genuinely missing, as stated |
| `pivot`, `melt`, `ewmMean`, `klGaussianDiag`, `dstack`, `logspace`, `dequantize`, `irfft` | — | genuinely missing, as stated |
| ~~`numericalGrad`~~ | `numericalGrad`, `numericalGradWorst` | **wrong — both existed.** Sixth miss. See §3 item 16 |

★★ **A PER-NAME `grep -cE "pub (fn|const) $n\b"` LOOP IS NOT A RELIABLE CHECK.** Run over a list of
names it reported `numericalGrad 0`; the identical command re-run reported 1, and the file had not
changed. That single wrong reading is what kept item 16 on the roadmap. **Extract the declarations
ONCE and test membership** - `grep -oE '^pub (fn|const) [A-Za-z_][A-Za-z0-9_]*' | awk '{print $3}'`
into a file, then `grep -qx`. That is how the 365-name list above was built and it is reproducible.

So Tier 1 is **smaller than it looks** and Tier 2 #6 is nearly done. The item counts in §3 are
upper bounds, not estimates.

★ **This is also why §1's "103 missing of 463" and `znum_mapping.md`'s "130 missing of 628"
disagree.** Both were produced by name-matching. Items 19 and 20 — finish the parity tool's
exclusion list, drive the mapping to zero unexplained — are not tidying at the end of the queue;
they are the thing that would have prevented four wrong rows in this table. Worth pulling forward.

### Landed Sep 12 2026

**`GruCell` + `GRU`**, on `LstmCell`/`LSTM`'s template: nine weight tensors in three gates,
`bind` once then `stepBound` per step, state threaded rather than stored. Two decisions written
into the code:

★ **The reset gate multiplies the hidden PROJECTION, not the hidden state** — `r * (W_hn h)`,
after the matmul, following torch. The other published form is a different model, and it is also
the one that makes a fused single-matmul implementation impossible, which is presumably why torch
chose this one. The parity ledger compares against torch, so this is the form that has to be here.

★ **No gate is biased open, and the asymmetry with `LstmCell` is deliberate.** The LSTM's forget
gate starts at one so the cell line survives by default. The GRU's update gate sits on BOTH sides
of an interpolation — biasing it open would not just preserve memory, it would shut the candidate
out, so the unit would start unable to learn anything new. Zero leaves it balanced.

Tested on the LSTM test's exact task, seeds, optimiser and schedule, against the SAME bars rather
than looser ones, so the two are directly comparable. Gradient through eight unrolled timesteps
checked against a finite difference before training, under 1e-7 on the update gate's recurrent
matrix — because a wrong-but-correlated gradient still reduces a loss, so a falling curve is not
evidence that the derivative is right.
