# advancedrl.md - the ingredients for adversarial, diffusion and regression-based RL

Written Sep 15 2026 after reading MimicKit (103 Python files) and measuring every requirement
against zimrnum's actual surface rather than against memory.

**Scope: the LEARNING ingredients only.** Animation retargeting, character state and physics are
deliberately out - they belong with `robot.zig` and the mocap work. What is in scope is every
numerical building block the algorithms need, so that when the animation half lands there is
nothing left to invent.

---

## 0. The one blocking finding, stated first

*** **zimrnum's `backward` IS NOT DIFFERENTIABLE, AND THREE OF THESE ALGORITHMS NEED IT TO BE.**

`Graph.backward` writes into `grads` tensors directly. It builds no tape nodes - verified, not
assumed: the body contains zero calls to `push`. So a gradient cannot itself be differentiated.

AMP, ASE and ADD all carry a **gradient penalty** on the discriminator:

```python
disc_demo_grad = torch.autograd.grad(disc_demo_logit, norm_disc_obs_demo,
                                     create_graph=True, retain_graph=True)
disc_grad_penalty = 0.5 * (mean(sum(disc_demo_grad**2)) + mean(sum(disc_agent_grad**2)))
disc_loss += self._disc_grad_penalty * disc_grad_penalty
```

That `create_graph=True` is the whole problem: the penalty is a function OF the input-gradient,
and descending it requires differentiating through the backward pass.

### 0.1 Why the penalty is not optional

Worth stating because "drop the regulariser for now" is the obvious shortcut and it does not
work. A discriminator's job is to be *hard to fool but still informative*. With no constraint on
its input-gradient it converges toward a step function: near-perfect classification, and a reward
signal that is flat almost everywhere with a cliff at the boundary. The policy then gets no
gradient over most of its state distribution and an enormous one at the edge.

The symptom is characteristic and is NOT a crash: discriminator accuracy climbs toward 1.0, the
style reward collapses to near-constant, and the motion degenerates while every loss curve looks
converged. **If we ship the adversarial family without the penalty, this is what we will see, and
we will spend the time diagnosing it anyway.**

### 0.2 The three routes, costed

| | what | cost | verdict |
|---|---|---|---|
| **A** | Make `backward` build tape nodes, so `gradOf` returns a `Var` | large - every backward case becomes a graph construction | the general answer, and the only one that also unlocks meta-learning, Hessian-vector products and influence functions |
| **B** | One fused `discriminatorGradPenalty` op with a hand-derived second derivative | moderate, and narrow - correct only for the architecture it was derived for | tempting and brittle; the derivative changes when the discriminator does |
| **C** | A first-order substitute: spectral normalisation of the discriminator's weights | small | a DIFFERENT regulariser, not this one. Honest as a substitute, dishonest as an equivalent |

**Recommendation: A, staged.** Not all at once. Teach `backward` to emit nodes for the ops a
discriminator actually uses - `matmul`, `add`, `relu`, `layerNormRows`, `sigmoid` - which is
enough for the penalty, and leave the rest first-order until something needs them.

### 0.3 How second-order gets verified, since it has no closed form

This is the part that needs a plan, because unlike everything else here there is no oracle.

**Test 1 - `checkSecondGradient`, by extending what exists.** `checkGradient(loss, param, h)`
already perturbs a parameter and compares the tape's answer against a central difference. The
second-order version is the same trick one level up: perturb an INPUT, measure how the
first-order gradient changes, compare against the tape's gradient-of-gradient.

*** The trap: **a central difference OF a central difference loses roughly half the available
precision**, so the usual `h = 1e-6` is wrong here - the error floor lands around `1e-4` and a
correct implementation fails. In f64 the sweet spot is `h` near `1e-4`, giving perhaps six good
digits. **A tolerance must be derived from `h` rather than copied from the first-order test**,
and this note exists because copying `1.0e-7` across is exactly what will happen otherwise.

**Test 2 - an analytic case with a known Hessian.** `f(x) = 0.5 * x^T A x` for a small symmetric
`A` has gradient `A x` and second derivative `A` exactly. No finite differences at all, and it
catches sign and transpose errors that a noisy numerical check would absorb.

**Test 3 - the penalty on a LINEAR discriminator.** For `logit = w . x`, the input-gradient is
`w` regardless of `x`, so the penalty is `|w|^2` and its gradient with respect to `w` is `2w` -
computable by hand. This is the real expression under test, with the network simple enough to
check on paper.

**Test 4 - the plant.** Route the second-order gradient to the wrong input, or drop the
`create_graph` equivalent so the penalty becomes constant, and confirm each test fails. A
second-order implementation that silently returns first-order results is the failure mode to fear:
it produces finite, plausible, stable numbers and a discriminator that is not regularised.

---

## 1. What is already there

Measured against the tree. This is a large fraction of the total, which is why the plan is short.

| need | zimrnum | for |
|---|---|---|
| MLP trunk, arbitrary depth | `Chain`, `Dense` | every model here |
| `layerNormRows`, `dropout`, `resampleDropout` | on the tape | discriminators, DiT blocks, DroQ |
| `sigmoid` `softmaxRows` `tanh` `softplus` `gelu` `silu` | on the tape | activations throughout |
| `binaryCrossEntropyFromLogits` | present | **the GAN loss itself** - AMP's `_disc_loss_pos/neg` is exactly this against ones and zeros |
| `matmul` `transpose` `concat` `slice` | on the tape | attention, conditioning, latent concatenation |
| `gatherRows` `scatterAddRows` `Embedding` | present | token and label embeddings |
| `Attention` | present | DiT blocks |
| `min` on the tape | done Sep 14 | TD3/DroQ pessimism |
| `ObsNormalizer` | done Sep 14 | **discriminator observation normalisation** - AMP normalises disc obs separately from policy obs, and this type already does it |
| `ReplayBuffer` | present | **the discriminator's own replay** - AMP keeps a second buffer of past agent observations so the discriminator does not overfit the current policy |
| `diagGaussianLogProb` `categoricalLogProb` `squashedReparameterize` | done Sep 14 | policy likelihoods for AWR and PPO |
| `klToReference` | done Sep 14 | motion priors, trust regions |
| `Temperature` `forActionDim` | done Sep 14 | entropy tuning |
| `ppoUpdate` `offPolicyUpdate` | done Sep 14 | the loops all of these sit inside |

*** **All 32 names in this table were verified against zimrnum's symbol table by script on
Sep 15, not from memory.** That is R5's mitigation executed rather than prescribed - and it is
worth re-running before each stage, because this table is a snapshot and the tree moves. The
script is four lines: extract `^\s*pub (fn|const) NAME`, test membership, print what is absent.

### 1.1 Three of those are load-bearing in a way that is easy to miss

** **`binaryCrossEntropyFromLogits` must stay the FROM-LOGITS form.** Writing
`bce(sigmoid(logit), label)` instead is the same function mathematically and a different one
numerically: `log(sigmoid(x))` underflows for `x` around -80 in f32, and a discriminator that is
winning produces exactly those logits. The from-logits form folds the sigmoid into the log and is
stable everywhere. Same class of bug as the tanh correction in `squashedReparameterize`, and it
will bite at the same moment - when training is going well.

** **AMP's discriminator replay is a SECOND buffer, not the policy's.** It holds past agent
observations so the discriminator is not trained purely against the current policy. Sharing one
buffer would couple the two and reintroduce the oscillation the replay exists to damp. Two
instances of `ReplayBuffer`, different lifetimes, and the plan should not "optimise" them into one.

** **The discriminator's observation normaliser is also separate.** AMP normalises disc obs with
their own running statistics because the disc-obs window is a different quantity from the policy
observation. Sharing an `ObsNormalizer` between them would normalise both by the wrong moments -
and `ObsNormalizer.apply` being pure means the mistake is a wrong instance, not a wrong mode.

---

## 2. Adversarial: AMP, ASE, ADD

### 2.1 What they actually are

A discriminator scores whether a short window of observations came from the reference data or
from the policy. Its output becomes a **reward**, so the policy is trained to produce motion the
discriminator cannot distinguish. There is no hand-written style reward anywhere.

```
disc_r = -log(max(1 - sigmoid(logit), 1e-4)) * scale
```

* The `max` matters and is not defensive clutter. As the policy improves, `sigmoid(logit)`
approaches 1, `1 - sigmoid` approaches 0, and the log diverges - so a policy that is WINNING
produces an unbounded reward and destroys the value function. The floor is what makes the reward
bounded, and it binds exactly when things are going well.

### 2.2 The pieces to add

| | what | signature sketch | notes |
|---|---|---|---|
| **A1** | `Graph.gradientOf(output, input)` | `-> Var` | **the blocker from 0.** Staged second-order support |
| **A2** | `discriminatorReward(T, logit, scale, floor)` | `-> T` | the mapping above. **Scalar-first** - no allocation, no error union, no slice - so a kernel and the CPU call the same function |
| **A3** | `Graph.squaredRowNorm(x)` | `-> Var [N,1]` | `sum(x^2)` per row. Composes from `mul` + matmul-with-ones |
| **A4** | `l2NormalizeRows(T, out, x, epsilon)` | `Error!void` | ASE samples latents on the unit hypersphere; without this the latent magnitude drifts and the encoder reward silently changes scale under it |
| **A5** | `Graph.rowDot(a, b)` | `-> Var [N,1]` | ASE's encoder reward is `-sum(z * enc_pred)` per row |

* A3 and A5 are the same fold with different operands, and both are the pattern
`diagGaussianLogProb` established. They are NAMED rather than open-coded because a row reduction
spelled as a matmul is unreadable at the call site, and three unreadable call sites is how the
next person writes a fourth one differently.

### 2.3 What ASE adds on top

A latent `z` on the unit hypersphere conditions the policy; an encoder tries to recover `z` from
the resulting motion. The encoder's accuracy is a reward, so the policy is pushed to make
different `z` produce *visibly different* motion - that is where the skill diversity comes from.

Needs A4 and A5, plus a latent-resampling schedule which is caller-side bookkeeping.

** `_calc_enc_error` is `-sum(z * enc_pred)` - a negative dot product, NOT a distance. It is a
cosine similarity only because both vectors are unit-length, which is A4's whole job. **If A4 is
wrong or skipped, this reward keeps working and stops meaning what it says**: unnormalised
predictions make the "similarity" scale with magnitude, so the encoder can raise its reward by
predicting larger vectors rather than better ones. The test for A4 is therefore not "does it
normalise" but "does the encoder reward stay bounded by 1".

---

## 2b. CPU and GPU verification - what every new primitive must carry

zimrnum already has the machinery; the plan is to USE it rather than invent a second scheme.
Three artefacts exist and each answers a different question.

| artefact | question it answers | how |
|---|---|---|
| `zig build zn-zimrnum` | is the CPU answer right? | unit tests against closed forms |
| `zig build zn-rl-gpu` | does it COMPILE for a device? | `src/shaders/zn_rl_gpu_probe.zig`, a real SPIR-V entry point |
| `src/gpu/zn_conformance.zig` + `zimrnum_field.html` | does the device AGREE with the CPU? | a row in the sweep table, run on real hardware |

### 2b.1 The rule

**Every scalar-first primitive added by this plan gets all three.** Compiling proves the shape;
agreeing proves the arithmetic; neither implies the other. The `diff_forward` episode is the
evidence: the kernel compiled to SPIR-V for weeks while emitting WGSL no device would accept.

A primitive is "scalar-first" when it takes and returns numbers rather than slices - no
allocation, no error union in the inner function. `ppoClipSample`, `cartpoleOutcome` and
`discriminatorReward` are; `ppoEpoch` and `offPolicyUpdate` are not, and do not get GPU rows.

### 2b.2 Adding a conformance row, concretely

A row in `zn_conformance.zig` carries a label, the kernel entry point, the CPU function that
defines the right answer, a tolerance, and the input distribution. The parts that need thought:

*** **The tolerance is a claim, not a formality.** A row whose output is a SELECTION or a mask
carries `.tol = 0` - there is no arithmetic to round, so any difference is a bug. A row that
accumulates carries a real allowance, because summation order differs between a serial loop and a
parallel reduction. **A negative tolerance accepts everything and looks exactly like success** -
the invariant test in that file exists because of it.

** **The input distribution has to reach the interesting branch.** `discriminatorReward`'s floor
only binds when `sigmoid(logit)` is near 1, so a row fed `.noise` would never exercise the clamp
the function exists for. It needs inputs with large positive logits - the same reason `expm1` and
`log1p` are each rowed twice, once on `.noise` and once on `.tiny`.

** **Then run it on hardware.** `zig build zimrnum-field-standalone` produces a page; the sweep
reports per-row worst error. A row that has never run on a device is a row that has never been
checked, however green the build is.

### 2b.3 What CANNOT be verified this way, and what to do instead

Honesty about the boundary, because the temptation is to claim GPU coverage for everything.

| | why not | instead |
|---|---|---|
| `Graph.*` tape ops | the tape allocates, returns error unions, and holds a node list - none of which a kernel can do | verify the SCALAR core on GPU where one exists (`min`'s comparison, `squaredRowNorm`'s square) and the composition on CPU |
| second-order gradients | same, and more so | CPU only, with the four tests in 0.3 |
| diffusion sampling loops | sequential over timesteps by construction | CPU for correctness; the per-step arithmetic (D3, D4, D5) is scalar-first and DOES get GPU rows |
| the discriminator forward pass | it is a `Chain` of existing ops | those ops already have sweep rows; a new row would be testing `matmul` again |

* The pattern: **the arithmetic goes on the GPU, the orchestration does not.** That is the same
split that made `zimrnum.zig` shader-free while `src/gpu/` holds the kernels, and applying it
here needs no new architecture.

### 2b.4 A learning gate is the only end-to-end check

Unit tests and conformance rows verify pieces. They cannot tell you the algorithm learns - and
every failure mode in 0.1, 1.1 and 2.1 produces plausible pieces and a policy that does not
improve.

**So each stage in 5 ends with something that LEARNS**, on continuous cartpole, with a mean
return that rises. Not a benchmark - a tripwire. The cheapest useful form is: fixed seed, fixed
step budget, assert the final mean return exceeds a threshold a random policy cannot reach.

* It will be slow and it belongs outside `test-fast`. `zig build gate` is the wrong tier; a
separate `zig build learn` that runs minutes is the right one, and the plan should expect it to
be run deliberately rather than on every commit.

---

---

## 2c. HIL - the scene transformer, and what it needs that AMP did not

HIL (Wang et al. 2026) is AMP plus three structural ideas, and each one lands somewhere different
in zimrnum. Read closely because it is the most demanding target in this document: it needs
everything AMP does AND a differentiable transformer over a point cloud.

### 2c.1 The three ideas

**1. A scene-conditioned discriminator.** AMP's discriminator sees a window of character states.
HIL's also sees the scene point cloud, so it judges not just "is this motion natural" but "is
this motion natural FOR THIS OBSTACLE". The ablation is decisive: removing scene information from
the discriminator drops skill accuracy from 0.66 to 0.38 while task completion barely moves - the
character still gets there, using the wrong skill.

*** The consequence for us: **the PointNet path must be differentiable, because the discriminator
trains through it.** It is not enough to featurise the scene once and feed numbers in.

**2. A privileged task indicator, critic-only.** HIL trains two modes in parallel - motion
tracking and adversarial imitation - with different reward structures. The critic receives a
binary `k` saying which mode this sample came from; the policy does NOT. Without it the paper
reports the critic's loss **5x larger**.

** This makes the policy and critic take DIFFERENT observations, which `PpoModel` currently does
not express - it has one `observations` leaf. That is a real and small change, and it is better
made deliberately than discovered.

**3. A fixed policy covariance.** `sigma_pi = 0.055`, not learned. The policy has a mean head and
no log_std head at all.

* Worth noticing what this simplifies: with sigma constant, the Gaussian's ENTROPY is constant,
so the entropy bonus contributes nothing to the gradient and can be dropped rather than
computed. `diagGaussianLogProb` already supports this - pass `log_std` as a `constant` rather
than a `parameter` and no gradient flows to it. **No new code, but the plan should say so**, or
someone will add a log_std head the paper does not have.

### 2c.2 The transformer: composable, which is the good news

`Attention` exists in zimrnum as a CPU TYPE, not a tape op - so it cannot be trained through as
it stands. But scaled dot-product attention is

    softmax(Q K^T / sqrt(d)) V

and `matmul`, `transpose`, `scale` and `softmaxRows` are all on the tape. Multi-head adds `slice`
and `concat`, also on the tape. So **the whole encoder block composes with no new backward** -
the same situation as `diagGaussianLogProb` and `klToReference`, and unlike `min`.

| | what | notes |
|---|---|---|
| **H1** | `Graph.scaledDotProductAttention(q, k, v, scale)` | composed; the `1/sqrt(d)` is the part people omit, and omitting it makes the softmax saturate as the head dimension grows |
| **H2** | `Graph.encoderBlock(x, weights)` | attention + residual + `layerNormRows` + feed-forward + residual. Composed from H1 and existing ops |

** **The residual connections are not decoration.** A two-layer encoder will train without them
and a deeper one will not, and the failure is the usual silent one: slow convergence that reads
as a learning-rate problem. They cost an `add` each; the plan names them so they are not
"simplified away" while someone is getting the shapes right.

### 2c.3 The one new backward HIL needs: `maxAxis` on the tape

PointNet's entire trick is a **symmetric aggregation**: a shared MLP maps each of N points to a
feature vector, then a `max` over the N points produces one vector for the set. The max is what
makes the output **permutation-invariant** - the scene is a SET of points, and any function that
depended on their order would be learning an artefact of how the sampler happened to emit them.

`maxAxis` exists in zimrnum and is **not on the tape**. It must be, because the gradient flows
through the pooling to the shared MLP.

| | what | notes |
|---|---|---|
| **H3** | `Graph.maxAxis(x, axis)` | **a new backward** - the second this work has needed, after `min` |

* The backward is the same shape as `min`'s, which is why this is cheap now and would not have
been six months ago: **route the whole gradient to the argmax, zero elsewhere, ties to the lowest
index.** The reasoning in `min`'s implementation transfers verbatim, including why an even split
at ties is wrong.

** But there is a difference worth checking: `min` compares two operands, `maxAxis` reduces N.
The tie case is therefore N-way, and the argmax must be computed ONCE in the forward and
**recorded**, not recomputed in the backward - recomputing risks a different winner if the
forward values were regenerated, and then the gradient goes somewhere the output did not come
from. Store the index.

### 2c.4 Two rewards HIL shapes differently

| | what | notes |
|---|---|---|
| **H4** | `trackingKernel(T, error, weight, alpha)` -> `w * exp(-alpha * error)` | HIL's tracking reward is six of these summed - position, rotation, linear velocity, angular velocity, root height, energy. Scalar-first, so it gets a GPU row |
| **H5** | `mixRewards(task, style, w_task, w_style)` | trivial arithmetic, named because HIL adds the style reward to the TRACKING mode too, with the same weights - a detail that is easy to read past and changes what is being optimised |

* H4's exponential kernel is worth naming rather than open-coding for a specific reason:
`exp(-alpha * ||x||)` is bounded in `(0, 1]` and **saturates**. With `alpha` too large the reward
is zero almost everywhere and the policy gets no gradient; too small and it is flat near 1 and
says nothing. HIL's alphas span 0.05 to 20 across the six terms - they are tuned per quantity,
and a single shared alpha would be wrong for five of them.

### 2c.5 Evaluation: DTW

HIL measures skill accuracy and tracking error with **Dynamic Time Warping**, because the
generated motion is not frame-synchronised with the reference - the character clears the obstacle
faster or slower, and a frame-by-frame comparison would report a large error for a correct motion.

| | what | notes |
|---|---|---|
| **H6** | `dtwDistance(a, b, out_cost)` | classic dynamic program over a cost matrix. **No gradient** - it is a metric, not a loss |

* This is the one item here with no autodiff involvement at all, which makes it the easiest to
test: the DTW of a sequence against ITSELF is zero, against a time-scaled copy of itself is zero
(that is the whole point), and against a shifted copy is not. Three assertions, no tolerance
arguments.

** It is O(T * T') in time and memory. For the 10-step windows HIL uses that is nothing; for
whole-episode comparison at 30Hz over 400 steps it is 160k cells per pair, and the evaluation
compares against every reference clip. **Band the warping path** (Sakoe-Chiba) if it becomes a
problem, and know that banding changes the answer - it is an approximation, not an optimisation.

### 2c.6 What HIL needs from `PpoModel`, concretely

The multi-mode design touches our update loop in exactly one place:

** `PpoModel` has one `observations` leaf, and HIL needs the critic to see a task indicator the
policy does not. **The fix is a second optional leaf**, `critic_observations`, defaulting to the
same `Var` as `observations`. Callers who do not need asymmetric observations write nothing;
HIL writes one field.

* That is a smaller change than it looks BECAUSE the caller already builds the loss. The update
writes leaves and steps parameters; it has no opinion about what the policy and critic each see.
This is the second time that decision has paid - the first was one update serving both action
spaces.

### 2c.7 Verification, applying 2b

| piece | CPU | GPU compile | conformance row |
|---|---|---|---|
| H1, H2 transformer | gradient check against finite differences | no - composes tape ops | no - the underlying `matmul`/`softmaxRows` already have rows |
| **H3 `maxAxis` backward** | **argmax routing, ties, and a plant that splits the gradient** | no - tape op | its SCALAR comparison shares `min`'s row |
| H4 `trackingKernel` | closed form, and the saturation edges at both alpha extremes | **yes** - scalar-first | **yes** - inputs must reach the saturated branch, per 2b.2 |
| H5 `mixRewards` | closed form | yes | yes, folded with H4 |
| H6 `dtwDistance` | self-distance zero, time-scaled zero, shifted non-zero | no - control flow, not arithmetic | no |

*** **The permutation-invariance test is the one that matters for H3**, and it is not a gradient
test: feed the same point set in a SHUFFLED order and assert the pooled output is bit-identical.
A PointNet that is not permutation-invariant still trains, still reduces its loss, and has
learned the sampler's emission order - which changes the moment the scene does.

** **Every capability claim in 2c was verified by script on Sep 15**, the same way section 1's
were: 13 ops confirmed ON the tape, 2 confirmed ABSENT from it (`maxAxis`, `Attention`), 4
confirmed to exist somewhere. The two gaps are the two this section asks for, and the thirteen
are what makes the transformer a composition rather than a rewrite.

---

## 3. Regression-based: AWR

The simplest of the four and worth landing first, because it exercises the off-policy loop
without a discriminator.

```python
actor_loss = -mean(a_weight * a_logp)      # weight = exp(advantage / beta), clipped
```

An advantage-weighted likelihood: imitate your own good actions, weighted by how good they were.
Everything needed is present  -  `diagGaussianLogProb`, `mul`, a mean  -  except:

| | what | notes |
|---|---|---|
| **W1** | `advantageWeights(out, advantages, beta, max_weight)` | `exp(adv/beta)` clipped above. **The clip is load-bearing**: one large advantage otherwise produces a weight that dominates the entire batch, and the update becomes "copy that one action", which is stable, wrong, and reports a small loss |
| **W2** | a masked mean | AWR trains only on steps where the action was SAMPLED rather than deterministic. `minOverMasks`'s sibling  -  a reduction over a boolean mask |

---

## 4. Diffusion: the tinymdm family

MimicKit leans on HuggingFace `diffusers` for the schedulers, so what has to exist on our side is
the schedule mathematics and the DiT block. Neither is large; both are exacting.

### 4.1 Schedule and noising

| | what | notes |
|---|---|---|
| **D1** | `betaSchedule(kind, steps, out)`  -  linear and **scaled-cosine** | the cosine schedule is the one motion models use; the difference is not cosmetic, it changes where the model spends its capacity |
| **D2** | `alphasCumprod(betas, out)` | the running product. **Computed once and cached, never per step**  -  recomputing a cumulative product inside a sampling loop is O(T^2) and silently makes generation quadratic |
| **D3** | `addNoise(x0, noise, alpha_bar_t) -> x_t` | `sqrt(a)*x0 + sqrt(1-a)*eps`, the forward process |
| **D4** | `epsilonFromX0(x_t, x0_pred, alpha_bar_t)` | the conversion in `_get_epsilon`. Models predict one or the other and the loops need both |
| **D5** | `ddimStep(x_t, eps, alpha_bar_t, alpha_bar_prev, eta)` | deterministic sampling at `eta = 0`; DDPM is the same step with `eta = 1` and added noise, so **one function serves both**  -  the same argument as `ppoUpdate` serving two action spaces |

* D5 is where a plan can go wrong by writing two functions. DDPM and DDIM are one update with a
parameter, and MimicKit keeps two scheduler objects for what is arithmetically one thing.

### 4.2 The DiT block

| | what | notes |
|---|---|---|
| **D6** | `sinusoidalTimestepEmbedding(t, dim, out)` | the standard frequency ladder. Shared with positional encoding |
| **D7** | `adaLayerNorm(x, shift, scale)` | LayerNorm whose gain and bias come from the timestep embedding. **This is how conditioning enters**  -  `layerNormRows` exists, this is that plus two learned affine terms |
| **D8** | classifier-free guidance: `guided = uncond + w * (cond - uncond)` | two forward passes and a lerp. Trivial arithmetic, worth naming so the sign convention is written down once |
| **D9** | `emaUpdate(shadow, live, decay)` | **`polyakUpdate` already IS this**, with `follow = 1 - decay`. Add an alias and a doc note rather than a second function  -  and record the complement, because 0.999 and 0.001 are both plausible-looking and only one is right |

* D9 is the second time this exact confusion has come up (see the `follow` note on
`offPolicyUpdate`). Naming it twice with the convention spelled out both times is cheaper than
debugging a target network that tracks instantly.

---

## 5. The order to build in

Sequenced so each stage is provable before the next depends on it.

| stage | what | why here |
|---|---|---|
| ~~**1**~~ | ~~W1, W2, and AWR learning cartpole~~ **STAGE 1 COMPLETE Sep 15** | 31.1 -> 63.3 mean episode length, in one second. The decisive lesson was not a hyperparameter: with `sigma = 0.5` the policy could only sample forces near zero on a task whose useful range is +/-10 N, so it never observed what a real push does. **A policy cannot learn from an action it never takes** |
| **1b** | ~~U1 `reduceRows`~~ **DONE Sep 15** with `squaredRowNorm` (A3), `rowDot` (A5) and `.max` (H3) / ~~U3 the rename~~ **DONE** / U2 `Trainable`, U4 the registry remain | U1 landed as two tape tags - `.sum` and `.max`, with `.mean` composed - and replaced five open-coded matmul-with-ones folds. Three plan items closed by one op |
| ~~**2**~~ | ~~A2 `discriminatorReward`, A4 `l2NormalizeRows`~~ **DONE Sep 15** | Both in, both tested, and A2 carries all three verification artefacts - CPU test, SPIR-V probe line, conformance row - in the same change. **The discriminator can now be built and evaluated; it cannot yet be regularised**, which is stage 5 |
| ~~**2b**~~ | ~~H1 attention, H2 `encoderBlock`, H4, H5, H6~~ **STAGE 2b COMPLETE Sep 15** | The transformer composed from existing tape ops - no new backward, as predicted. `checkGradient` passes on all six projections; a missing softmax and a diagonal-only DTW both fail their tests |
| **2c** | `PpoModel.critic_observations` | One optional field defaulting to `observations`. Do it BEFORE anything depends on it |
| ~~**3**~~ | ~~D1-D5~~ **STAGE 3 COMPLETE Sep 15** | Schedules, forward process, both conversions, and the sampler. D5 IS one function for DDPM and DDIM as predicted - `eta` alone separates them. Verified by an IDENTITY: a perfect noise prediction makes the reverse step land exactly where the forward process puts `x_{t-1}`, to 1e-12 |
| ~~**4**~~ | ~~D6 `sinusoidalEmbedding`, D7 `adaptiveLayerNorm`, D8 `classifierFreeGuidance`, D9 `emaUpdate`~~ **STAGE 4 COMPLETE Sep 15** | D9 was an alias as predicted. D7's `1 + gain` is the detail that lets a DiT block train from scratch, plant-verified: without it a zero-initialised projection destroys the signal before any gradient arrives |
| ~~**5**~~ | ~~A1 `Graph.gradientOf`~~ **STAGE 5 COMPLETE Sep 15 - THE BLOCKER IS GONE** | It needed NO new backward: every rule is written with ops already on the tape, so the emitted graph is differentiable for free. The gradient penalty is now expressible, checked against an analytic Hessian and against a linear discriminator where `|w|^2` and `2w` are exact |

* **Stage 5 is the only one that can fail in a way the others cannot.** Stages 1-4 are arithmetic
with closed-form answers to check against. Second-order autodiff has no such oracle short of
finite differences of finite differences, which is numerically poor  -  so it should land when
nothing else is moving, and `checkGradient` should be extended to check gradients OF gradients
before anything depends on them.

---

## 5b. Adversarial review of this plan - what will go wrong

Written by attacking the plan above rather than defending it. Each item is a way this goes badly
that the plan as written does not prevent.

### R1. The second-order work will be started early anyway *** 

The plan schedules it LAST. The pressure to start it first is enormous, because it is the
interesting problem and because stages 1-4 feel like chores. **The failure mode is not that it
goes wrong - it is that it goes wrong while three other things are also in flight**, and then
nothing can be bisected.

*Mitigation:* the ordering is a hard rule, not a preference. If second-order lands before AWR
runs, the plan has already failed and should be re-read rather than continued. And the four tests
in 0.3 are written FIRST - `checkSecondGradient` against `0.5 x^T A x` before any of the
implementation - so the oracle exists before the thing it judges.

### R2. A second-order implementation that silently returns first-order results **

The worst outcome in the whole plan, because it produces finite, plausible, stable numbers. The
penalty becomes a constant, its gradient becomes zero, the discriminator is unregularised, and
every curve looks fine. This is exactly the shape of the `ppoClipLoss` snapshot bug - a loop that
optimised against the first minibatch forever while reporting real losses.

*Mitigation:* the plant test in 0.3 is not optional and must be run on the finished
implementation, not only during development. Specifically: force `gradientOf` to return a
detached copy and confirm the penalty's gradient goes to zero and the analytic-Hessian test fails.

### R3. Adversarial training will not converge, and the cause will be ambiguous **

GAN training is unstable for reasons that have nothing to do with our implementation being wrong.
When AMP fails to learn, the candidate causes are: the penalty coefficient, the discriminator
learning rate, the replay size, the reward scale, the observation normaliser - and a bug.

*Mitigation:* **prove the discriminator in isolation before coupling it to a policy.** A
discriminator trained on two fixed, obviously-separable distributions must reach high accuracy
and its gradient penalty must be finite and non-zero. That is a test with a right answer, unlike
"does AMP learn". If that passes and AMP still fails, the bug is in the coupling, and the search
space has shrunk by most of its volume.

### R4. The diffusion schedule will be subtly wrong and nothing will say so *

`alphas_cumprod` is a cumulative product over hundreds of steps. An off-by-one in the timestep
indexing, or `alpha` where `alpha_bar` was meant, produces samples that are blurry rather than
broken - and blurry is indistinguishable from undertrained.

*Mitigation:* test the schedule against closed forms with NO network. Three concrete assertions:
`alpha_bar[0]` is `1 - beta[0]`; `alpha_bar` is monotonically decreasing; and
`addNoise(x0, eps, alpha_bar[T-1])` is statistically indistinguishable from `eps` alone - at the
last timestep the signal must be gone. Then `ddimStep` at `eta = 0` fed a PERFECT epsilon must
reconstruct `x0` exactly, which is an identity and not a tolerance.

### R5. The "already there" list will rot ***

Section 1 is a snapshot of the tree on Sep 15. Every entry is a claim that something exists and
means what the plan thinks it means. **The `SquashedGaussian.logProb` near-miss is the precedent**
- a 60-line grep window said a method was absent when it was at line 83, and the previous parity
pass asserted several equivalences without looking.

*Mitigation:* re-verify section 1 programmatically before starting any stage, the same way the RL
ledger's "covered under another name" claims were checked - extract zimrnum's symbol table, test
membership, do not trust the table. It takes one script and it is the difference between a plan
and a wish.

### R6. AWR will be "finished" without ever having trained anything **

Stage 1 is the cheapest stage and the one most likely to be declared done on the strength of unit
tests. W1 and W2 will pass their tests, the loss will be finite, and nobody will have run it.

*Mitigation:* stage 1 does not end at W1 and W2 - it ends at 2b.4's learning gate. **If cartpole
hold does not learn under AWR, stage 1 is not complete**, and the rest of the plan is building on
an untested loop.

### R7. The GPU rows will lag the CPU implementations **

Adding a conformance row means touching `zn_conformance.zig`, `zn_unary.zig` (or a sibling),
`build.zig`'s entry list, and then running a standalone page on real hardware. That is four steps
and a device, against one step for a CPU test. **The rows will be deferred, and then the deferral
will become permanent** - which is precisely how the RL layer ended up with zero sweep rows while
92 kernels existed.

*Mitigation:* the primitive is not done until the row exists. And the smaller mitigation that
actually works: add the row in the SAME change as the function, when the arithmetic is fresh,
rather than in a "GPU pass" later. A batched pass over six primitives is six chances to transcribe
one of them slightly differently.

### R8. `discriminatorReward`'s floor will be tuned away *

It looks like a magic number - `1e-4` - and magic numbers attract tidying. Someone will make it
configurable, then default it to zero, then a policy will win and the reward will diverge.

*Mitigation:* the floor is a parameter with a documented minimum and a test asserting the reward
stays bounded as the logit grows. Not "it is clamped" - **assert that `discriminatorReward` at a
logit of 50 is finite and below a stated ceiling.**

### R9. Scope creep from MimicKit's other agents *

LCP and SMP were read and set aside. They will look like small additions when someone is already
in the file.

*Mitigation:* 6 says what is excluded. The test for adding one is whether it needs a NEW numerical
primitive - if it does not, it is an application of this plan rather than an extension of it, and
belongs wherever applications live.

### R11. The PointNet will not be permutation-invariant, and it will still train ***

A shared MLP over points followed by a max IS permutation-invariant; almost anything else is not.
Flatten the points into one vector, or get `reduceRows`'s axis wrong, and the network **learns the
order the sampler happened to emit points in**. It trains. The loss goes down. It generalises to
nothing, because the order changes the moment the scene does.

*Mitigation:* the test is not a gradient check - **feed the same point set SHUFFLED and assert the
pooled output is bit-identical.** Not approximately: a max over the same values in a different
order is the same value exactly, so any tolerance here is hiding something. Run it on the
discriminator's scene path too, which is the one that would be forgotten.

### R12. `reduceRows(.max)`'s backward will recompute the argmax **

`min` compares two operands and the backward can re-derive the winner from stored inputs.
`reduceRows` reduces N, and `recompute()` runs every minibatch - so a backward that recomputes the
argmax rather than reading a recorded one can pick a different winner on a tie than the forward
did. The gradient then lands on an element the output did not come from.

*Mitigation:* record the index in the forward. Test it deliberately: build a tensor with
DELIBERATE ties, backward, and assert the gradient lands on the lowest index across repeated
`recompute()` calls.

### R10. The plan will be followed even after it is wrong **

Everything here rests on a reading of MimicKit done in one sitting. Some of it will be mistaken.

*Mitigation:* the same discipline that has served all session - when a measurement contradicts the
plan, the measurement wins and the plan gets corrected in place with the correction recorded. The
RL ledger has been wrong three times and is more trustworthy for saying so.

---

### R13. A multi-edit script will throw halfway and discard the edits that succeeded **

Not hypothetical, and **it has now happened twice while writing this document.** The first time a
failed assertion discarded a successful replacement because the write came last. The second time,
writing up the AWR work, a helper was called with the wrong number of arguments - the first edit
wrote, the second threw, and the file was left half-updated in a way that looked finished.

*Mitigation:* **one edit, one assertion, one write** - which the second failure survived, because
each edit had already written by the time the next one threw. The remaining hole is the one that
caught me: a script that throws for a reason unrelated to the content. **Check the file after,
not the script's exit code.** Both times the tell was a grep, not an error message.


Not hypothetical - it happened while writing this document. A script made two replacements, the
second assertion failed, and because the write came last, **the first replacement was silently
discarded too.** The build-order rows looked applied for an hour; the grep that found them missing
was luck.

*Mitigation:* **one edit, one assertion, one write.** A helper that asserts and writes per edit
costs three lines and makes a partial failure partial rather than total. The same rule the
plant-test lesson arrived at from the other direction: an operation that reports nothing when it
does nothing is the dangerous shape.

---

## 5c. Ranked: what to worry about most

| | risk | why it ranks here |
|---|---|---|
| 1 | **R2** silent first-order fallback | produces plausible numbers indefinitely; the only defence is a test written before the code |
| 2 | **R5** the "already there" list rotting | every stage depends on it, and it has already failed once this session |
| 3 | **R1** second-order started early | turns one hard problem into three entangled ones |
| 4 | **R7** GPU rows deferred | has already happened once, at scale, in this exact codebase |
| 5 | **R3** adversarial instability | expensive to diagnose, but R3's mitigation genuinely shrinks the search |
| 6 | **R6** AWR declared done | cheap to prevent, and it is the foundation the rest stands on |
| 7 | **R11** PointNet not permutation-invariant | trains, converges, and has learned the sampler's emission order - the failure is invisible until the scene changes |
| 8 | **R12** `maxAxis` backward recomputes the argmax | `recompute()` runs every minibatch, so a tie can pick a different winner than the forward did |

---

## 5d. Architecture: four changes that would make all of this fit

We own the whole stack, so the question is not only "what do we add" but "what shape should the
thing we add be adding to". Measured against the tree, four changes pay for themselves. One
apparent duplication is deliberately left alone, and the reason matters more than the others.

### U1. `Graph.reduceRows` - DONE Sep 15, and it subsumed three planned items *** 

**The observation.** Four tape functions already open-code the same fold:
`diagGaussianLogProb`, `klToReference`, `categoricalLogProb`, `squashedReparameterize`. Each
allocates a column of ones and multiplies by it, because the tape has no axis reduction:

    const dim_ones: Var = try self.constant(try ones(T, self.gpa, &.{ dims, 1 }));
    const summed: Var = try self.matmul(per_dim, dim_ones);

And the plan above asks for three more things that are all the same operation wearing different
names: **A3** `squaredRowNorm` is `reduceRows(mul(x, x), .sum)`. **A5** `rowDot` is
`reduceRows(mul(a, b), .sum)`. **H3** `maxAxis` on the tape is `reduceRows(x, .max)`.

**The change.** One op, `reduceRows(x, kind)` with `kind` in `{ sum, max, mean }`.

| it gives us | how |
|---|---|
| removes 4 existing open-codings | `matmul`-with-ones becomes one readable call |
| **delivers A3, A5 and H3** | three plan items collapse into one op plus two one-line helpers |
| one gradient-routing implementation | `.max`'s backward IS `min`'s, argmax recorded, ties left |
| faster than the fold it replaces | O(N*D) instead of a matmul call and a ones allocation per invocation |

** **Why this is the right amount of clever.** It does not invent an abstraction - it names a
thing that is already there five times. The three kinds are the three that appear; there is no
`.prod` or `.any` because nothing asks for them, and adding kinds later is a switch arm.

* **The one subtlety:** `.sum`'s backward is a broadcast of the incoming gradient, `.max`'s routes
to the recorded argmax. Two different backwards behind one tag, which is fine - `binary` already
does that for `.sub_op` and `.mul_op`.

### U2. Extract the step from the two model structs - DONE Sep 15, as a FUNCTION **

`PpoModel` and `OffPolicyModel` both carry `graph`, `loss`, `weights`, `parameters`, and differ
only in which leaves they name. Both loops then write the same step:

    for (model.weights, model.parameters) |w, v| {
        try sgdStep(T, w, w, try graph.gradOf(v), learning_rate);
    }

**What was done, and why it differs from the proposal above.** The seam turned out to be the
BEHAVIOUR, not the data: `stepParameters(T, graph, weights, parameters, lr)` gives the one place
for Adam, while a `Trainable` struct would also have cost `model.trainable.loss` at every use
site for a single shared loop. The two model types keep their own named fields, which is what
makes them readable.

* The two loops were byte-identical before the extraction, which is the evidence the seam was
real - and the reason to prefer the smaller change is that the larger one bought nothing else.

* HIL's `critic_observations` then lands on `PpoModel` alone, touching nothing shared. That is
the test of whether the extraction was at the right seam.

### U3. Make the tape-twin naming a RULE, not a lookup table - DONE Sep 15 **

The tutorial has a table of quantities that exist twice - once as a number, once as a graph node.
Three of the four already follow a pattern:

| number | tape | |
|---|---|---|
| `DiagGaussian.logProb` | `Graph.diagGaussianLogProb` | consistent |
| `Categorical.logProb` | `Graph.categoricalLogProb` | consistent |
| `klGaussianDiag` | `Graph.klToReference` | **breaks it** |
| `SquashedGaussian.sample` | `Graph.squashedReparameterize` | legitimately different - `sample` and `rsample` are different operations |

**The change.** Rename `klToReference` to `Graph.klGaussianDiag`. Then the rule is: *the tape twin
has the same name, in the `Graph` namespace.* A rule someone can apply is worth more than a table
someone has to find - and the next person adding a twin will get it right without reading this.

* Leave `squashedReparameterize` alone. It is not the tape version of `sample`; it is the
reparameterised draw, which is a different thing that happens to live nearby.

### U4. A registry for the scalar-first family **

`ppoClipSample`, `cartpoleOutcome`, `discriminatorReward`, `trackingKernel` share a discipline -
no allocation, no error union, no slice - so that a kernel and the CPU call the same function.
**That discipline is enforced only by whether someone remembered to add a line to
`src/shaders/zn_rl_gpu_probe.zig`.**

**The change.** A comptime list of the scalar-first names, and a test asserting the probe
mentions each one. Text-matching, like the tutorial checker - and like the tutorial checker, it
catches the thing that actually happens: a function written scalar-first on purpose and then
never wired to the probe, which is exactly how the RL layer ended up with 92 kernels and zero RL
rows.

### NOT unified: the number/tape pairs themselves ***

The obvious "clever" move is to eliminate the duplication - derive the CPU version from the tape
one, or vice versa. **Do not.**

Those two implementations are a **cross-check, and it has already paid.**
`Graph.diagGaussianLogProb` was verified against `DiagGaussian.logProb` to 1e-12;
`squashedReparameterize`'s numerically-stable tanh correction was verified against
`SquashedGaussian.logProb`'s direct `log(1 - tanh^2)` form, which is the ONLY reason we can trust
the stable spelling - the unstable one confirms it where the unstable one still works.

* Unify them and that check disappears, and what replaces it is one implementation agreeing with
itself. The duplication is not an accident to clean up; it is a second opinion. **What it needs
is a name** (U3's rule) rather than removal.

### Deliberately NOT done yet: an environment interface *

`cartpoleTaskStep` is `cartpoleContStep` plus a `cartpoleOutcome` - dynamics shared, reward and
termination swapped by an enum. That pattern will want to generalise when `reacherStep` lands and
again when the robot environments arrive.

** **Wait until there are three.** Two implementations of a pattern is not enough evidence about
what varies, and an interface designed against cartpole-and-reacher would be shaped by exactly
the two simplest cases. The current shape costs nothing to keep and the third environment will
say what the interface should be.

### The end state, if all four land

    Graph.reduceRows                one op; A3, A5 and H3 are calls to it
    Trainable(T)                    one step loop, one place to put Adam
    Graph.<cpuName>                 the tape twin is always the CPU name
    scalar-first registry           the probe cannot silently miss one

**Three of the plan's items stop being items.** The rest of `advancedrl.md` is unchanged, which is
the sign these are the right four: they make the additions fit without moving where the additions
go.

---

## 6. What this plan deliberately excludes

- **Animation, retargeting, character state.** MimicKit's `anim/` and `envs/` are the majority of
  its code and none of it is numerics. It belongs with `robot.zig`.
- **The specific network architectures.** `fc_2layers_1024units` and friends are configuration,
  not capability. `Chain` + `Dense` already express them.
- **`diffusers` itself.** What is needed is the ~40 lines of schedule arithmetic it wraps, not the
  library.
- **LCP and SMP.** Read and set aside: both are variations on the above with no new numerical
  primitive. Worth re-reading if a gap appears, not worth planning around now.

---

## 7. The honest summary

**Of everything these four families need, one thing is missing that is hard: differentiable
gradients.** The rest is roughly twenty small functions, most of them folds and schedules with
closed-form answers to test against, and a large fraction of the total is already in the tree
because the SAC and PPO work put it there.

The reason to write this down now, before the animation half exists, is that the hard item is
hard in a way that does not shrink under pressure  -  and discovering it while also debugging a
character model would be the worst possible time to find out.
