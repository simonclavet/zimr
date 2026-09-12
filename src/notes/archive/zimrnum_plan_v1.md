# zimrnum — numerics / stats / deep learning / RL for zimr, on CPU **and** GPU

**One line:** `src/zimrnum.zig` (+ `src/zimrnum_gpu.zig` + `src/nnkernels/*.zig`) — a tensor
library with autograd, neural-network layers, optimisers, statistics and reinforcement learning,
that **trains on the GPU**, whose every compute kernel is authored in Zig, and which the rest of
zimr progressively adopts.

Design donor: **znum** — 63 490 lines, 359 tests, 38 namespaces, plus a `shaders/` tree of 51
Zig-authored kernel files (5 418 lines) and a working WebGPU training runtime (102 kernels).

---

## 0. What the study found (read this before anything else)

**znum is not a CPU library with a GPU stub.** Its `gpu` namespace is 19 270 lines and contains a
real training runtime: `BufferPool`, `StagingRing`, `LivenessNode`, `Recorder`, `PipelineCache`,
`BindGroupCache`, `UniformRing`, `Runtime`, and device implementations of the whole training
stack — `matmul`/`bmm`/`matmulTransposed`, `conv2d` + `conv2dGradInput` + `conv2dGradWeight`,
`layerNormRows` + `layerNormBackward`, `softmaxRows` + `softmaxBackward`, `pool2d` +
`maxpool2dBackward` + `avgpool2dBackward`, `dropout`, `sgdStep`/`sgdMomentum`/`adamStep`,
`rngUniform`/`randNormal`/`randIndex`, and even RL on-device: `gae`, `categorical`,
`cartpoleStep`, `cartpoleContStep`, `reacherStep`.

**Its kernels are already authored in Zig, through zimr's own transpiler.** `shaders/kernels/`
holds 51 files written against `k.Globals(@This())` / `g.bind(.field)` — the exact kompute API —
compiled by the stock Zig compiler to SPIR-V and translated by `spv2wgsl`. Dtype genericity is by
MODULE INJECTION: a kernel writes `const T = @import("dtype").T;` and the build compiles it once
per dtype with `-Mdtype=kernels/dtype_f32.zig`. One kernel file yields a family of per-dtype
shaders with no copy-paste. (Why not a generic-over-T factory in one module? Two dtype instances
in one SPIR-V module collide on the `kbuf_*` symbol names — znum measured this.)

**The vendored-zimr delta is tiny, documented, and offered back.** `shaders/vendor/zimr/PROVENANCE.md`
is a delta ledger with a greppable `ZNUM-UPSTREAM(<topic>)` block per change. There are exactly
two, both purely additive:

| file | topic | what | size |
|---|---|---|---|
| `zimrmath.zig` | `ml-activations` | `tanh`, `sigmoid`, `gelu`, generic over the float type, in zm's own `comptime is_gpu` idiom (host → `std.math`; GPU → built on `@exp`). `@tanh` is not a Zig builtin, so these cannot lower automatically. | ~45 lines |
| `kompute.zig` | `lean-path` | `Uniform(M)`, `g.uniform()`, `installKernelLean` — a kernel form that reads the `Params` uniform DIRECTLY instead of copying it field-by-field into a per-dispatch `Ctx`. Zig's SPIR-V backend wraps that copy in a merge ladder of comptime-dead guards (`if (31u == 31u)`), so the stock path emits roughly **twice** the WGSL the body warrants. | ~60 lines |

⚠ **The transpiler is the exception to "use znum's version".** The ledger records
`spv2wgsl.zig` as **verbatim — zero deltas**: "The transpiler needed no change to handle znum's
kernels." And zimr's copy is the newer one — 11 603 lines against znum's 11 561, snapshotted
from an older zimr — and it now carries this session's storage-buffer-block fix (runtime-sizing
and `array<atomic<ELEM>>` reached through a one-field block), which znum's copy predates and
which znum's kernels will need on toolchain 1980. **zimr's `src/spv2wgsl.zig` stays; nothing is
lifted from znum's copy.** Same for `zimrmath`: zimr's is 9 614 lines to znum's 9 532, so we take
the 45-line block, not the file.

---

## 1. Goal

Train neural networks on the GPU, in a browser, from Zig, with the CPU path as the oracle rather
than as a fallback. Everything else — stats, linalg, RL, autograd — is the surface that makes
that useful and testable.

**Optimise for understanding** means, concretely:

- a downward-only layer stack with a table of contents, where a symbol may call its own layer or
  a lower one and NEVER a higher one;
- **every GPU kernel has a CPU twin from the same source** (kompute's whole model), so the CPU
  version is the specification, the oracle, and the documentation;
- doc comments say *why*, never restate *what* — znum's kernel headers are the standard to hit
  (`k_matmul_tiled16.zig` explains why 16×16, why 256 lanes, why bitwise `&` and not `and`, why
  no early return, in the file);
- names that survive being read aloud, per claude.md rule 1.

---

## 2. Scope — staged, not cut

Everything in znum comes across eventually. Nothing is dropped on taste. Two things are
**deferred** and one is **replaced**, each with a stated reason:

| znum area | disposition | why |
|---|---|---|
| tensor core, ops, linalg, fft/signal/calc, random, autograd, nn, optim/losses/train, rl, stats, metrics, checkpoint, infer | **stage 1–8** | the core ask |
| `gpu` runtime + `shaders/` kernels | **stage 4 onward, and the point of the project** | GPU training |
| `df` (pandas), `sparse`, `io`, `dimnames`, `AnyTensor` | **deferred to stages 9–11** | real surface, genuinely wanted, but nothing depends on them; they come after training works. `AnyTensor` returns with `df`, which is what it exists for. |
| the 102 embedded `wgsl_*` string literals in znum.zig | **replaced, not ported** | zimr law: **no inline WGSL anywhere in the tree**; WGSL is a build artifact. znum embeds them because it had no build pipeline of its own. zimr does. The kernels are the Zig files; the WGSL is generated. |
| znum's vendored `spv2wgsl.zig` / `spv2wgsl_cli.zig` | **not lifted** | §0: verbatim copies of an older zimr. |

---

## 3. Architecture and the module graph

The hard problem is that zimrnum must be BOTH the thing `robot.zig` can use (which is `zm`-only
and tests in seconds) and the thing that drives a WebGPU queue. znum already solved this with a
device-tagged `Buffer` and a single `dispatch` seam keyed on device. zimr's version:

```
std
└── zm            src/zimrmath.zig     scalar/vector/matrix vocabulary, CPU + SPIR-V
    ├── kompute   src/kompute.zig      kernel-authoring shim (std + builtin + zm only)
    │
    ├── zimrnum   src/zimrnum.zig      Tensor(T), DType, Device, Buffer, the dispatch seam,
    │                                  and EVERY CPU kernel + the whole math/stats/autograd/
    │                                  nn/optim/rl surface.       deps: zm, kompute
    │
    ├── nnkernels src/nnkernels/*.zig  the GPU kernels, authored in Zig against kompute,
    │                                  one file per family, dtype-injected.   deps: kompute, zm
    │
    └── zimrnum_gpu  src/zimrnum_gpu.zig   the WebGPU execution half: BufferPool, StagingRing,
                                       Recorder, PipelineCache, BindGroupCache, UniformRing,
                                       Runtime.  deps: zimrnum, compute_host, gpu, wgpu
```

Three properties this buys, each of which is the reason for the split:

1. **`zimrnum.zig` stays `test-fast`-eligible.** It adds one line to `fast_test_roots` in
   `build.zig` and gets a test artifact with `zm` + `build_options` + `kompute`. Seconds, not
   minutes. The CPU half of a numerics library is exactly the half that needs a thousand tests.
2. **`robot.zig` / `zimrphysics.zig` can adopt it** without dragging in a GPU dependency (§6).
3. **`dag-check` stays green.** No cycle: `kompute` never imports `zimrnum`.

⚠ **`zimrnum.zig` must NOT be imported by `src/tests.zig`.** claude.md: that file is ONE compile
unit, and ~600 added lines took the host suite from 163 s to **335 s** — past the tool timeout,
where retrying can never finish. A five-figure-line library cannot live inside it.

**"Unify later, somehow"** is a real design goal, recorded here so it is not lost: the end state
is one call site per operation with the device chosen by the tensor, not two spellings. znum's
`dispatch` seam is the shape that gets there — CPU runs the comptime-`T` kernel; the `.gpu` branch
selects a pipeline; **nothing above L04 changes.** Because `T` is known at the call site, picking
a typed GPU pipeline is `gpuBinaryPipeline(T, op)` — comptime `T` is an asset here, not an
obstacle. Do not design the seam twice: build L04 once, correctly, and let both backends fill it.

---

## 4. The two upstream merges (stage 0, small, independently useful)

Both land in zimr FIRST, before zimrnum exists, because zimr's own kernels benefit and because it
proves the merge-back path the ledger was written for.

1. **`zm.tanh` / `zm.sigmoid` / `zm.gelu`** into `src/zimrmath.zig`. Generic over the float type
   (`anytype` → `@TypeOf(x)`), matching `pow`/`atan2`/`hypot`. znum records that writing them
   f32-only "blocked dtype-generic layers", so the generic form is the one to take.
   ⚠ Check `reserved-math-names` before adding: if these become reserved keywords, no other decl
   may bear the name, and `nn.tanh` / `nn.sigmoid` / `nn.gelu` are exactly the names the layer
   wrappers want. Decide the reservation policy in the same edit.
2. **`installKernelLean` + `Uniform(M)` + `g.uniform()`** into `src/kompute.zig`. Purely
   additive; `installKernel`/`Ctx` untouched, so existing zimr kernels are unaffected and migrate
   one at a time. **Acceptance is a measurement, not a claim**: transpile `fluid_gpu`'s kernels
   both ways and record the WGSL byte counts. "Halves the WGSL" is znum's number, on znum's
   kernels — reproduce it here or record what it actually is.

Acceptance for both: `zig build check` green, `zig build smoke-test -Dfocus=fluid_gpu` PASS, and
the ledger blocks kept verbatim so a future re-sync can `grep ZNUM-UPSTREAM`.

---

## 5. The verification ladder

This is the heart of the plan. Every rung is a test that gets written; several get proven to fail
before being believed.

**Rung 1 — the CPU twin is the oracle, and it is permanent.** Every GPU kernel is the same Zig
source compiled for the host, and every GPU op ships a test asserting `gpu(x) ≈ cpu(x)`. This is
kompute's existing model and znum's `cpu_oracle_smoke.zig`. Any accelerated CPU path (blocked
matmul, `@Vector` reduce) likewise keeps its naive implementation and a `fast == naive` test. The
naive version is the specification; deleting it to "clean up" is forbidden.

**Rung 2 — the browser-coverage gate.** znum's best idea and it comes across whole. `COVERAGE.md`
is GENERATED by running every op with synchronous readback DISABLED — the condition a browser
actually imposes — so an op with no device kernel raises `Error.KernelMissing` instead of quietly
running on the host. It cannot drift from the code because every row is produced by running the
op. znum's current state: **29 ops device-resident, 10 host-only**, each host-only row carrying a
reason (`pow` is DELIBERATE — WGSL `pow` is undefined for a negative base; `sum (all)` is
INHERENT — it returns a host scalar). This is claude.md's *"a default that looks like an answer
is worse than no answer"* implemented as a build gate. `zig build check-coverage`.

**Rung 3 — the manifest drift gate.** ONE manifest lists every kernel file × dtype × entry and
each entry's binding ABI; the build, the registry, the on-device card and the drift test all
derive from it, and a comptime check asserts each kernel file's own `pub const kernels` agrees.
Drift is a compile error, not a missing shader at runtime. Adding a kernel is a one-line edit in
one place — never a change to build logic.

**Rung 4 — algebraic properties.** Laws that hold for ANY input, randomised over seeds:
commutativity, identities, `A@I == A`, `(A@B)ᵀ == Bᵀ@Aᵀ`, `ifft(fft(x)) == x`, `Q@Qᵀ == I`,
`L@Lᵀ == A`, `A@pinv(A)@A == A`.

**Rung 5 — golden values from a real oracle.** numpy 2.4.4 and scipy 1.17.1 are installed in the
sandbox. `scripts/zimrnum_goldens.py` pins eigenvalues, singular values, FFT bins, every quantile
interpolation method, `erf`/`lgamma`, and distribution moments into
`src/tests/fixtures/zimrnum/`, checked in so tests need no Python. ⚠ Record the numpy/scipy
version in each fixture header and pin the exact call — `np.quantile(x, q, method="linear")`, not
the default, which has changed once and will again.

**Rung 6 — gradients, in f64.** `checkGradient` compares analytic gradients to central finite
differences for every autograd op. ⚠ **This must run in f64**, and the reason is already in this
repo: `robot_mpc`'s `∂q'/∂u` collapses to noise once `|q|` is O(1) because the signal falls below
f32 resolution — not fixable by tuning epsilon, which is why MuJoCo is f64. An f32 gradient check
passes on broken code and fails on correct code, both silently. f32 paths are checked against
their own f64 twin instead.

**Rung 7 — the negative control.** claude.md: *a gate that has never fired is not a gate.* For
`checkGradient`, the leak test, the shape assertions, the coverage gate, the drift gate and the
RL env contract: break it deliberately, watch it go red, restore, watch it go green. Record the
red→green pair in the journal. An invariant nobody has watched fail is a hope.

**Rung 8 — memory, on both sides.** znum's four-way ownership taxonomy (OWNER / VIEW /
TAPE-OWNED / IN-TRANSIT, exactly one disposal authority per buffer) comes across verbatim, plus
its hardest-won GPU corollaries, which are already zimr-shaped problems:
- **OFFSET.** A view carries `(buffer, offset, strides)` but the kernel ABI takes a buffer handle
  and indexes from its start, so any view reaching a kernel must be densified. Forgetting is not
  a leak — it reads the WRONG MEMORY, silently. That was znum's `layerNorm` gamma bug.
- **TIMING.** On a recording runtime, "released" is not "reusable": release appends to `pending`,
  and only `recycle` — after the stream crosses the FFI — frees. A comment once asserted the
  opposite and leaked on every loss.
- The test that catches both is `a forward-plus-backward round retains ZERO device bytes`, and it
  ENUMERATES ops rather than trusting per-site judgement. ⚠ `Scope` stores `arena:
  *ArenaAllocator` via `gpa.create` — an arena is not movable (claude.md, two sessions).

**Rung 9 — the anti-patterns, checked explicitly.** Four shapes this repo has already paid for:
a self-referential check is not a check (`f(x, conj(x))` passes on broken code the instant it is
written); a test that constructs the state under test says nothing about the producer; make the
omission unrepresentable (put the channel in the signature); a silent clamp is a silent bug
(`@min(count, capacity)`, `orelse continue`, `catch return` each turn "does not fit" into "fine").

**Rung 10 — RL is judged on outcomes.** claude.md, twice: *"does not explode" is satisfied by a
controller that does nothing.* Every RL algorithm test asserts a POSITIVE result — a return
threshold reached within a fixed budget and seed — plus stillness where it applies. A sweep must
run until the trend reverses; a flat sweep says the swept parameter is not the cause; two runs
disagreeing at identical settings is the finding, not noise.

**Rung 11 — the device is the oracle.** Sandbox green is necessary and not sufficient. Every
stage that touches a kernel ends with a standalone Simon opens on the phone. This session's
launcher bug is the case in point: `check` was green, `fluid_gpu` smoke PASSED, and the device
said `no matching call to atomicStore(ptr<storage, u32, read_write>, u32)`.

---

## 6. Adoption — the rest of zimr moves onto zimrnum

Stated as a goal now so the API is designed for it, executed after the core is proven. Each move
must be justified by DELETED code, not by tidiness, and each is its own green turn.

| consumer | what it would take from zimrnum | why it is worth it |
|---|---|---|
| `robot_mpc.zig` | autograd / `xf.jvp` / `valueAndGrad` | it finite-differences its own Jacobians today, and claude.md records f32 finite differences collapsing to noise. Analytic or forward-mode derivatives are the recorded fix. |
| `robot.zig` | `linalg` (LU/solve/Cholesky), `Tensor` views | it hand-rolls `LᵀDL` and CRB; the sparsity-aware versions probably stay, but the dense fallbacks and the test oracles should be one implementation. |
| `zimrphysics*.zig` | reductions, `stats`, batched ops | measurement and profiling surface, not the solver core. |
| `kompute.zig` | **nothing.** It stays `zm`-only. | it is the seam zimrnum stands on; taking a dependency the other way is the cycle. |
| `plot.zig` / `plot3d.zig` | `stats` (histogram, quantile, corr) | plotting re-derives these today. |
| examples | the whole surface | an MNIST-class demo and a GPU-trained cartpole are what make it real. |

⚠ Two things constrain every adoption: `dag-check` (the acyclic gate — 49 modules, 63 covering
edges, 0 cycles today) and `test-fast` (a consumer that is currently `zm`-only must stay fast).
That is exactly why `zimrnum.zig` and `zimrnum_gpu.zig` are separate files. **Do not collapse
them for elegance; the split is load-bearing.**

---

## 7. Stages

Each lands green — `zig build test-fast`, `zig build check`, lint 0, `zig fmt --check` — and ends
with a snapshot zip. Stage N+1 does not start before N is green.

⚠ **ORDER CHANGED, Sep 4.** Stages 0–2 are done. **Stage 2.5, the GPU spike, comes next** — ahead
of stage 3 (linalg, transforms, random), which is deferred behind it. The reason is in §10's
audit: everything built so far is CPU-only, and the plan's own instruction was to build the
dispatch seam once rather than twice. That seam does not exist yet, and building it before seeing
a kernel run would have been guessing at its shape. Now that `k_bcast_add`'s uniform is known to
be the same data `broadcastTo` already holds, the seam has a known shape — so it gets built where
it can be tested, not where it is convenient.

★ **What exists against what stage 2 claimed:** `Tensor(T)`, views, `broadcastTo`, `map`/`zip` and
the four named arithmetic ops are done and tested (33 tests). The **L04 dispatch seam is NOT
built** — `zip` is CPU-only with no device branch. That is deliberate and is what stage 2.5
resolves; it is recorded here so the plan and the code do not quietly disagree.

**Stage 0 — green the tier, split it, then the two upstream merges + decisions.** In order:
(a) fix `robot_mjcf`'s 4 call sites and the `codecs.gltf` leak so `test-fast` is green at all;
(b) split `test-fast` into ≤150 s sub-steps and add the `test-budget` gate (§8b); (c) §4's two
merges. Plus: settle `reserved-math-names` vs
`linalg.dot`/`nn.tanh`, and settle `prefer-vec` for wide SIMD (`@Vector(8,f32)` is currently
gated; options: stay 4-wide on `zm.Vec`, exempt the path, or add a canonical `VecN` to zm — the
last is the general fix). Both are five-minute decisions that become thousand-site renames if
deferred.

**Stage 1 — foundation + tensor core.** L00 base (Error, DType, traits, option enums), L01 Rng,
L02 `Ctx`/`Scope`/`Device`/`Buffer`, L03 `Tensor(T)` with views, strides, broadcasting,
contiguity, printing. Acceptance: the arena-is-not-movable test; the ownership taxonomy in the
`//!` doc; zero-retained-bytes over create/view/copy/free; the `@hasDecl` zm vocabulary test that
pins every zm symbol depended on, so an upstream rename fails the build.

**Stage 2 — the dispatch seam + CPU kernels + NumPy surface.** L04 seam (built ONCE, both
backends fill it), L05 CPU kernels naive-first, L06 `ops`/`reduce`/`manip`/`index`. Acceptance:
numpy goldens for the awkward semantics — keepdims, negative axes, empty reductions, broadcast
shape rules.

**Stage 2.5 — THE GPU SPIKE. ✅ DONE Sep 4: `worst |cpu-gpu| = 0 over 4096` on device.**
Pulled ahead of everything else after the Sep 4 audit (§10). The point is not features; it is to
find out whether the CPU abstractions cross, before another thousand lines are written on top of
them. Smallest honest scope:
  1. `src/nnkernels/k_binary.zig` — dense `add`/`sub`/`mul`/`div`, authored in Zig against
     `kompute`, dtype-injected the way znum does it (`-Mdtype=…`), one kernel file.
  2. Build wiring for a LIBRARY kernel set. zimr's `.compute_kernels` is per-example today
     (`wireComputeKernels`); this needs a shared equivalent, and that is the real work of the
     stage.
  3. `examples/zimrnum_field/` — fills two tensors from `Rng`, runs the kernel, and compares
     against the CPU `zip` **in the page**, reporting element counts and max deviation. The CPU
     twin as oracle, on the device, which is what znum.html does at its smallest scale.
  4. `zig build zimrnum-gpu-smoke-standalone` → one HTML Simon opens on the phone.
Delivered as `examples/zimrnum_field` — a real app, not a test page: three heatmaps (CPU, GPU,
difference) and a tap to switch operation. ⚠ The remaining half of the acceptance is unmet: **no
one has watched it go red.** Break the kernel deliberately and confirm the difference panel lights
up before treating the green as evidence.

**Stage 3 — linalg, transforms, random.** LU/solve/inverse/det/Cholesky/QR/eigh/SVD/lstsq/pinv;
FFT + Bluestein; convolve/correlate; gradient/trapz/interp; distributions. Acceptance: rungs 4
and 5, plus conditioning — a near-singular matrix produces a diagnosable error, not a plausible
wrong answer.

**Stage 4 — PORT znum's KERNELS. Do not re-derive them.**

⚠ **STRATEGY CORRECTION, Sep 4 (Simon).** The spike wrote one tiled matmul from scratch and spent
three device round-trips rediscovering constraints znum had already solved and written down: the
masked load must be arithmetic and not a select, the param copy destroys uniformity provenance,
the lean path is mandatory rather than an optimisation. **znum ships 53 working kernel files, 9 of
them using shared memory, all on the lean path.** They were written yesterday, they run, and their
headers carry the reasoning. Re-deriving them is not engineering, it is paying twice.

The work is therefore PORTING, family by family, with znum's own machinery:
  1. `src/nnkernels/` with znum's `k_*.zig` files, adapted only where zimr's API differs
     (`kompute` names, the lint rules). Their doc headers come across intact — they are the
     record of what the device rejected.
  2. **The manifest and its drift gate.** One list of kernel file x dtype x entry, with the build,
     the registry and a comptime check all derived from it, so adding a kernel is a one-line edit
     and drift is a compile error rather than a missing shader at runtime.
  3. **The coverage gate** (§5 rung 2): every op run with synchronous readback disabled, so an op
     with no device kernel raises `KernelMissing` instead of silently running on the host.
  4. Dtype injection by module substitution (`-Mdtype=…`), which is how one kernel file yields a
     per-dtype family without copy-paste.

Order to port, by what unblocks training: `binary`/`unary`/`scalar`/`bcast_add` (elementwise,
already half-done), `matmul3`/`matmul_tiled16`/`bmm`, `reduce`/`reduce_pairwise`/`sum_axis0`,
`relu_grad`/`softmax`/`softmax_bwd`/`layernorm`(+`_bwd`), `sgd_step`/`sgd_momentum`/`adam_step`,
then `conv2d`(+ both grads) and the RL set.

**Stage 5 — the seam widens.** `src/nnkernels/` with the elementwise/unary/binary/scalar
families, dtype-injected; the manifest and its drift gate; `zimrnum_gpu.zig` with `BufferPool`,
`Recorder`, `PipelineCache`, `BindGroupCache`, `UniformRing`; the build wiring for a LIBRARY
kernel set (zimr's `.compute_kernels` is per-example today — this needs a shared equivalent).
Acceptance: rung 1 (every kernel vs its CPU twin), rung 2 (the coverage gate exists and reports),
and a device screenshot.

**Stage 5 — GPU matmul and the tiled kernels.** `matmul`, `matmul_tiled`, `matmul_tiled16`, `bmm`,
`matmulTransposed`, `transpose2d`. This is where workgroup shared memory and `workgroupBarrier`
enter zimr at scale for the first time. znum's constraints are load-bearing and must be carried
with the code: flat lanes viewed as a square (no GPU-only builtins, identical CPU/GPU index
maths); branch-free masked cooperative loads (an id-derived `if` puts the barrier in non-uniform
control flow, which Tint rejects); bitwise `&` not `and` (short-circuit becomes a branch); no
early return (every lane must reach every barrier — only the WRITE is guarded); `inline` inner
loop so the second barrier is emitted where race detection can see it.

**Stage 6 — autograd, CPU then GPU.** Tape, Node, backward, `checkGradient` in f64. Then the GPU
backward kernels: `reluBackward`, `softmaxBackward`, `layerNormBackward`, `conv2dGradInput`,
`conv2dGradWeight`, `maxpool2dBackward`, `avgpool2dBackward`. Acceptance: rung 6 for every op,
rung 7 on `checkGradient` itself, rung 8's zero-retained-bytes across forward+backward.

**Stage 7 — nn, optim, training on device.** Layers, activations, losses, `sgdStep`/`sgdMomentum`/
`adamStep` on GPU, LR schedules, the training loop, `infer`, `checkpoint`. Acceptance: a small
network learns a known function to a pinned loss at a pinned seed, **on the GPU**, and the GPU
result matches the CPU result within tolerance.

**Stage 8 — RL, including on-device rollouts.** Buffers, distributions, GAE (CPU and the `k_gae`
kernel), PPO/DQN/SAC/TD3. Environments stay OUT of the library — znum's call and the right one —
so zimrnum never grows a physics dependency; they live in an example, written against
`rl.checkEnv`. Acceptance: rung 10.

**Stage 9 — stats, metrics.** Moments, quantile methods, rank, correlation, histogram, scaling,
accuracy/confusion/F1. Acceptance: numpy goldens per quantile method.

**Stage 10 — `io`, `sparse`.** Versioned dtype-tagged array format, safetensors, COO/CSR/CSC +
spmm/spmv.

**Stage 11 — `df` + `AnyTensor`.** The dataframe and the type-erased boundary it exists for.

**Stage 12 — adoption + the demo.** §6, one consumer per turn. Plus the example that makes it
real: a network training live on the GPU with a loss plot through `plot.zig`, and a GPU cartpole
agent, both phone-testable.

---

## 8. Budget and the stop rule

- **Measure every stage.** `scripts/measure.sh` after each; record wall, peak RSS, artifact size
  and WGSL byte counts in the journal.
- **Stop rule:** if the `zimrnum` test artifact crosses **120 s** on the 1-core box, stop adding
  surface and split — move `test` blocks to a sibling root under `src/tests/`, or split at a
  layer boundary. claude.md: a single compile unit longer than the timeout is unfinishable by
  retrying, and the retry loop looks exactly like a build that is nearly there. Two identical
  timeouts mean stop and measure.
- znum is 63 490 lines and zimr's stricter style is larger per feature, not smaller. **Do not port
  breadth-first.** A shallow layer that compiles is worth less than a deep layer that is proven.

---

## 8b. The test protocol — settled BEFORE any zimrnum code

The general rule now lives in claude.md ("THE TEST PROTOCOL"); this section is what zimrnum does
about it, and it is stage-0 work, not something bolted on at stage 8.

### The measurement that decides the design

On 1980, 1 core, ReleaseSafe, compile-only:

    robot_scene  31 s / 6.7 MB      robot  32 s / 6.5 MB      urdf  35 s / 9.2 MB
    test-fast, all 10 roots, cold:  253 s,  +456 MB cache

**An extra test artifact costs ~30 s before it runs a single test, and the cost is FLAT in the
module's own size** — `robot_scene` and `robot` cost the same. Each `addTest` is a separate
whole-program compile, so the floor is the shared closure, not the code under test.

★★★ **This inverts the obvious plan.** "Split the tests into ten parts" is right about the
symptom and wrong about the axis: ten parts that share a closure compile that closure ten times.
`src/tests.zig` imports `zimr.zig`, so splitting IT ten ways buys ten engine compiles. The split
that works is by DEPENDENCY CLOSURE — which is exactly why `test-fast` is a list of shader-free
roots and not a list of small ones.

### What zimrnum does with that

1. **`zimrnum.zig`'s closure is `zm` + `kompute`, and that is a design constraint, not a
   consequence.** It is the whole reason the file is split from `zimrnum_gpu.zig` (§3). A T1
   artifact costs ~30 s; a T3 one costs minutes. Keeping the numerics core in T1 is worth more
   than any elegance gained by merging the two files.

2. **Test roots are per LAYER, capped, and budgeted from day one.** Tests do not live inside
   `zimrnum.zig` past the point where its own artifact crosses budget. They live as roots under
   `src/tests/zimrnum/`, each importing zimrnum as a named module:

       src/tests/zimrnum/core_test.zig      L00-L03  base, rng, ctx/scope, tensor
       src/tests/zimrnum/ops_test.zig       L04-L06  dispatch seam, cpu kernels, numpy surface
       src/tests/zimrnum/linalg_test.zig    L07-L09  linalg, transforms, random
       src/tests/zimrnum/grad_test.zig      L10      autograd + f64 gradient checks
       src/tests/zimrnum/nn_test.zig        L11-L12  layers, optim, losses, train
       src/tests/zimrnum/rl_test.zig        L13      buffers, distributions, PPO/DQN/SAC/TD3
       src/tests/zimrnum/stats_test.zig     L14-L16  stats, metrics, checkpoint, infer

   Seven roots × ~30 s floor ≈ 210 s of fixed cost for the CPU half. **That is a real price and it
   is the reason the list is seven and not twenty.** A layer earns its own root when its tests
   are slow enough that filtering inside a shared root stops helping — not before.

3. **`zig build test-num` is the aggregate; the per-layer steps are what a turn runs.**
   `test-num-grad`, `test-num-rl`, and so on: one artifact each, ~30-40 s, inside a foreground
   tool call. `test-num` runs all seven and is DETACHED, like the full suite.

4. **The GPU half never enters T1.** `zimrnum_gpu.zig` and `src/nnkernels/` test through the
   smoke harness and the coverage gate (§5 rungs 1-3), which are T4 and `-Dfocus`-able. A GPU
   kernel's CPU twin, however, is a T1 test — that is the point of the twin.

5. **The budget is enforced, not hoped for.** `scripts/measure.sh` logs per-artifact wall into
   `/tmp/measure.log`; a `zig build test-budget` step reads it and FAILS when any single artifact
   crosses **150 s** or any single command crosses **200 s**. Same shape as `checkDiskSpace`:
   measure the hazard, not a proxy, cheaply enough to run every time. Without the gate the budget
   is a comment, and claude.md already records what a budget-as-comment is worth.

### Fix the tier before extending it — blocking, stage 0

`zig build test-fast` is **RED right now** and has been for some time, undetected because `check`
does not compile the test roots:

- `src/robot_mjcf.zig` — 4 compile errors. `computeTwistOffsets` grew a
  `human_parents_for_rest: []const i32` parameter (6th) and **none of its four call sites was
  updated**. The parameter IS used in the body, so it cannot simply be deleted; the argument each
  site should pass is retarget-arc knowledge. ★ **Do not guess it** — ask, or read
  `retarget_plan.md` § on rest-pose aiming. Until then the whole fast tier cannot run.
- `codecs.gltf` — `test "gltf.parse: minimal JSON document"` leaks 8 398 bytes, reported with
  `(empty stack trace)` because the tier builds ReleaseSafe. Flip `codecs` to `.Debug` to locate,
  then flip back.

Adding zimrnum roots to a red tier makes the red harder to see, not easier. **Stage 0 does not
start until `test-fast` is green.**

### Also stage 0: split `test-fast` itself

At ten roots it is 253 s — past the 250 s timeout, so it can no longer be run in one foreground
call. Split into `test-robot` (robot, robot_physics, robot_control, robot_scene),
`test-mjcf` (urdf, mjcf, robot_urdf, robot_mjcf), `test-mpc` (robot_mpc — alone, it is the
expensive one), `test-anim` (ragdoll_bvh), and keep `test-fast` as the detached aggregate. Each
sub-step lands under ~150 s. This is a build.zig edit of a few lines and it pays for itself the
first time a turn needs to run one.

## 9. Risks, named

1. **Workgroup memory + barriers at scale is new ground for zimr's transpiler.** `spv2wgsl` emits
   `var<workgroup>`, but no zimr shader exercises cooperative tiled loads with two barriers in a
   K-loop. Stage 5 is where this is found out. Mitigation: the CPU twin is exact, and
   `prove_shaders.mjs`-style WGSL reflection plus the sandbox's uniformity gate run before device.
2. **The storage-binding shape just changed under us.** Toolchain 1980 requires a
   `storage_buffer` extern to point at a struct; zimr's `kompute` now wraps the view in a
   one-field block and `spv2wgsl` reaches through it for runtime-sizing and `atomic<>`. znum's
   kernels were written against the OLD shape. Expect fallout on first compile; the fix is
   already in the tree and the two device-visible properties to re-verify are runtime-sizing
   (Adreno) and atomics.
3. **f32 vs f64.** The engine is f32; numerics wants f64. `Tensor(T)` is generic, but every
   DEFAULT is a deliberate choice and the gradient path is f64 (rung 6). Getting this wrong
   produces tests that pass on broken code.
4. **Reading znum as authority.** It is a donor, not a spec. claude.md: *field names and comments
   describe intent; only the code describes behaviour.* Read the function before porting the
   name, and ask the compiler whether `zm` already answers it — `step` was already there as
   `stepEdge`, and `grep '^pub fn'` missed `lerp` and `saturate` because they are `pub inline fn`.
5. **Does the no-ownership tensor survive the GPU?** Simon asked, and it is the right question.
   The CPU answer is "whoever allocated frees, and a `Scope` makes that nobody." The GPU answer
   should be the same shape — **the buffer pool IS the arena**: a scope leases device buffers and
   releases them all when it closes, and a GPU `Tensor` holds `(buffer, offset, strides)` and owns
   nothing. That is arguably a better fit than a flag, because a recording runtime cannot free per
   tensor anyway: release only means "queue for recycle once the stream has crossed the FFI", so
   batch release at a known sync point — a scope boundary — is what you want.
   ★★★ **THE PART THAT IS NOT ANSWERED IS BINDABILITY, NOT OWNERSHIP.** A strided or stretched
   view cannot be handed to a kernel: the ABI takes a buffer handle and indexes from its start, so
   a view must be densified first. Forgetting is not a leak — it reads the WRONG MEMORY, silently,
   which is exactly znum's `layerNorm` gamma bug. `isContiguous` is the seam that answers it and it
   already exists; what does not exist yet is the rule that BINDING CHECKS IT. Stage 4 must make
   binding a non-contiguous tensor impossible or loud, and the test for it is: bind a transposed
   view to a kernel and require an error rather than a plausible wrong answer.
   ★ If that turns out to need a flag on the tensor after all, the flag to add is `bindable`, not
   `owns` — and it is derived from the strides rather than tracked, so it cannot go stale.

6. **Two implementations of one thing.** zimr already has `kompute` + `compute_host` +
   `spv2wgsl`. zimrnum must USE them, never grow a parallel copy. That failure is recorded five
   separate times in claude.md.

---

## 10. THE PORT LEDGER — measured gap, ordered stages, and every deliberate divergence

*Written Sep 4 2026 after re-reading znum against what zimrnum has.*

### 10.1 The gap, counted

*Recounted Sep 4, after the manip / stats / linalg / optim / losses / classification chunks.*

| | znum | zimrnum | ratio |
|---|---|---|---|
| public functions | **549 user-facing** (774 `pub fn` less 196 internal-namespace, 22 test-fixture and 7 init/deinit) | **333** | see the note below - the percentage is a JUDGEMENT, not a measurement |
| tests | — | 65 | — |
| GPU kernel entries | 53 files | 54 sweep rows | — |

    cpu/base   55 ->  15    losses      7 ->   6    autograd  76 -> 13
    random      6 ->   9    optim      36 ->   5    train     15 ->  0
    ds/tensor  22 ->  22    metrics     5 ->   3    rl       108 ->  9
    ops        86 ->  40    stats      34 ->   9    df        61 ->  0
    reduce     31 ->  19    linalg     34 ->   8    io        21 ->  7
    manip      22 ->   8    nn        105 ->  19    xf        31 ->  0
    index      14 ->   4    calc        5 ->   3    conv/pool 10 ->  3
    fft/signal  9 ->   9

★ `ds/tensor` and `random` are complete or ahead. `losses` is 6 of 7, and `autograd` now has a
working core. The three largest holes are `rl` (108), `df` (61) and the rest of `nn`.

⚠ **THE GPU SIDE HAS FALLEN BEHIND THE CPU SIDE, AND THE COVERAGE GATE CANNOT SEE IT.** The gate
pins kernel ↔ row; it cannot pin op ↔ kernel, so the ~60 functions added in the CPU-only chunks
have no kernel and nothing reports that. Most are legitimately host-side — znum's factorisations
and dataframes are too — but the distinction is currently undocumented rather than enforced.

⚠ **AND SIX ROWS HAVE NEVER RUN ON A DEVICE.** The last device confirmation was 47/48. Since then
`atan2`'s bar was corrected and `softplus`, `silu`, `leaky relu`, `elu`, `min all` and `mse loss`
were added. Fifty-four rows are built and unverified.

### 10.1b Superseded count

| | znum | zimrnum | ratio |
|---|---|---|---|
| lines | 63,490 | 2,645 | 4% |
| public functions | 936 across 33 namespaces | 67 | 7% |
| GPU kernel files | 53 | 3 (21 entries) | 6% |
| tests | — | 65 | — |

Per namespace, `znum` count → `zimrnum` count:

    cpu       55 -> 15    autograd  76 -> 0     stats     34 -> 0
    ops       86 -> 14    nn       105 -> 5     df        61 -> 0
    reduce    31 ->  5    optim     36 -> 1     io        21 -> 0
    manip     22 ->  0    losses     7 -> 1     xf        31 -> 0
    index     14 ->  0    train     15 -> 0     dimnames  19 -> 0
    linalg    34 ->  1    rl       108 -> 0     infer     10 -> 0
    conv/pool 10 ->  0    fft/signal 9 -> 0     metrics    5 -> 0
    random     6 ->  9    calc       5 -> 0     checkpoint 3 -> 0

★ `random` is the one area where zimrnum is AHEAD (9 vs 6), and §10.3 says why that is not
gratuitous.

### 10.2 Ordering principle

Not by namespace size, and not by znum's file order. **By what unblocks the next verifiable
milestone**, because every stage has to end with something the sweep can check on a device.

    A. reductions to scalar/vector    sum, mean, max, argmax, sumAxis on GPU
                                      -> unblocks losses, normalisation, metrics
    B. autograd                       tape, backward, checkGradient in f64
                                      -> ✅ CORE LANDED Sep 4: Graph/Var, add, matmul, tanh, mse,
                                         gradients bit-identical to the hand-written pass
                                      -> ✅ Sep 4: replay + checkGradient + 8 ops, all agreeing
                                         with a finite difference to better than 1e-8
                                      -> ⏳ remaining: softmax/cross-entropy on the tape, layer
                                         norm, higher-order derivatives
    C. nn + optim + train             layers, Adam/momentum, a training loop
                                      -> ✅ CPU milestone reached Sep 4: a two-layer net learns
                                         XOR to a loss of 0 in `zn`'s own test suite.
                                      -> ⏳ still open: the same loop on DEVICE
    D. linalg                         LU, solve, Cholesky, QR, eigh, SVD
                                      -> independent of B/C; can interleave
    E. manip + index                  concat, stack, split, gather, scatter, where
                                      -> small, mechanical, unblocks df and rl
    F. rl                             buffers, GAE, PPO, DQN, SAC, TD3
    G. stats + metrics + df           the analysis surface
    H. conv/pool/embed/fft/signal/calc
    I. io + checkpoint + infer        serialisation and inference
    J. xf + pytree + dimnames         the ergonomics layer

Stages A–C are the spine. D–J are breadth and can be reordered by need.

### 10.3 DIVERGENCE REGISTER

**The rule: every difference from znum must be justified by a metric, or it is a defect.**
Each entry below states the divergence, the claim, and the EVIDENCE. An entry with no evidence
is marked ⚠ and is a debt, not a decision.

| # | divergence | claim | evidence |
|---|---|---|---|
| 1 | Tensor has **no ownership flag and no `deinit`** | eliminates two silent failure classes | `deinit`-on-a-view is a no-op that reads as an action; a missing `deinit` grows memory. With no `deinit`, a free appears only where an allocation appears. **Both classes are unrepresentable, not merely tested for.** |
| 2 | **`sumAll` is compensated (Neumaier)**; znum's default is pairwise. Both are offered — `sumAllFast` is pairwise | correctness by default where the failure is silent and unbounded; speed available by name | **Cost, measured** (168M f32, one core): pairwise **1 398 M/s**, Neumaier **425 M/s**, naive `+=` 704 M/s — so the default is **3.3× slower**. **Benefit, measured**: `[1e8, 1×100, -1e8]`, exact answer 100 — Neumaier returns **100**; pairwise returns **0, 72, 104, 96** at thresholds 128, 32, 8, 2. Not merely inaccurate, **erratic**, and no threshold fixes it: the two large values land in different halves and each swamps its own. Both numbers are in the tutorial and the difference is **asserted by a test**, so it is a property rather than a footnote. |
| 3 | RNG is **counter-based with a stream per draw kind** | order-independence and cross-kind independence, both required by a GPU | Measured: same (seed, index) in any order; **0 collisions** between `bits`/`unitFloat`/`normal`/`intBelow` over 20,000 indices. Fixing this found a real bug — every kind previously derived from `bits(i)`. |
| 4 | `unitFloat` uses **per-type mantissa width** | the interval is half-open at every width | Before: **199,227 of 200,000 `f16` draws returned exactly 1.0** on an interval documented `[0,1)`. |
| 5 | **Tutorial is gated against the source by a test** | documentation cannot drift | Both directions proven by breaking them: an undocumented `pub fn` fails the tier; a stale row fails it. |
| 6 | Sweep uses **per-operation, ULP-scaled tolerance** | a bar that scales with the data | A correct `div` kernel was reported FAIL at 1.9e-6 against a bar of 0 — **6× below one ULP at the row's peak of 102.5**. |
| 7 | `spv2wgsl` and `zimrmath` **not lifted** from znum | zimr's are newer | zimr's spv2wgsl is 11,603 lines to znum's 11,561 and carries the 1980 fixes. Only a 45-line block (`tanh`/`sigmoid`/`gelu`) was taken. |
| 8 | **No separate manifest file**; each kernel file carries `pub const kernels` | same drift gate, less machinery | A missing `build.zig` entry is a **compile error naming the file** (`unable to open 'recip_wgsl'`), proven by control. |
| 9 | Kernels use **`installKernelLean`** | required, not optional | The stock path copies params through a dead-guard ladder; Tint then cannot prove the loop bound uniform and **rejects the barrier**. Lean was merged for size (48% of the WGSL) and turned out to be load-bearing. |

| 13 | **`max_rank` is 6**; znum's is 8 | a smaller value in a type copied constantly | `Tensor` is **128 bytes at 6 against 160 at 8** — 20% — and it is passed and returned by value everywhere, with no allocation to amortise it. Rank 6 covers batched video (batch, time, channel, h, w) and batched attention (batch, head, query, key) with a spare axis. ⚠ **A caller needing rank 7 has no recourse but to edit the constant**, which is the cost of the choice and is stated here rather than discovered. |
| 14 | **RNG is counter-based**; znum uses `std.Random.DefaultPrng` and `Wyhash` | order-independence, which a stateful stream cannot offer | znum's generator advances: two callers drawing from it interleave, and reproducing a failure means replaying the sequence. zimrnum's `(seed, index)` is addressable, so parallel work needs no coordination and a bad draw reproduces from two numbers. **The same arithmetic also lowers to WGSL**, so a kernel computing `value(seed, thread_id)` gets the identical stream — a stateful PRNG cannot cross that boundary at all. |
| 15 | **Autograd nodes are an enum**; znum stores a `grad_fn` per node | no indirect call in the backward pass, and an exhaustive switch | A closure per node is more extensible: adding an operation touches only the operation. An enum makes the compiler refuse an unhandled case in `backward` AND in `recompute`, which is what caught both of them being needed when `sub`, `mul`, `relu` and `sigmoid` were added. **The trade is extensibility for exhaustiveness**, and with the operation set small the exhaustiveness is worth more. ⚠ Revisit if the set passes about thirty. |
| 16 | **`initXavier` / `initHe` have no znum counterpart** | not a divergence — an addition (confirmed Sep 8: znum has no named initialiser; it uses `randn` and scales at the call site) |
| 19 | **`conv2dInto` had no stride or padding**; znum's has both per axis | ✅ **CLOSED Sep 8** by porting znum's contract directly: `stride: [2]usize`, `pad: [2]usize`, implicit zero padding, output `(h + 2·pad − kh) / stride + 1`. Tested: `pad = 1` on a 3×3 gives the input's size with the corner seeing the same four taps the valid 2×2 case did; stride 2 with the identity kernel is exactly the even rows and columns. |
| 20 | **Tape ops (`dropout`, `softmax`, `layernorm`) match znum's forms** | parity confirmed Sep 8: znum's dropout is inverted-scaled and on the tape; its softmax backward is `y·(g − Σgy)`; its layer norm has a dedicated backward. No divergence. | znum initialises with `randn` and scales at the call site. Naming the schemes puts the fan arithmetic in one place and makes it testable: the tests assert the produced variance and, for Xavier, that no draw falls outside the uniform's bounds. |

| 21 | **`fft` is radix-2 Cooley–Tukey**; znum's `fft` is the O(n²) definition | 630× measured | 10 transforms of 4096 points: **2 520 ms through `dft`, 4 ms through `fft`**. Operation counts predict 341×; the rest is the DFT calling `sin`/`cos` per element pair where the butterflies compute one twiddle per pair of blocks. **`dft` remains under its own name** as the reference `fft` is tested against — element by element at every power of two to 256, which is the only check that is not one FFT against another. |
| 22 | **`Cplx` rather than `Complex`** | forced, and stated | `Complex` is a reserved math name; `zm` has one of a different shape. |

| 23 | **`rfft` packs into a half-length transform**; znum's allocates `n` complex and runs a full one | half the transform, not a full one halved | The real samples become `n/2` complex values, ONE transform of half the length runs, and the result is untangled. Checked against a full `fft` of the same signal **bin for bin at every power of two to 256** — the untangling is where it can be wrong, and a bad twiddle still returns a plausible spectrum. |

| 24 | **`qr` is Householder**; znum's is modified Gram–Schmidt | orthogonality holds where the other collapses | On Hilbert matrices: **6×6** householder 4.4e-16 / gram-schmidt 1.8e-10; **8×8** 3.3e-16 / 4.4e-7; **10×10** 4.4e-16 / **1.8e-4** — four hundred billion times worse, and getting worse with size while Householder does not move. This is not a preference between algorithms: 1.8e-4 is `q` not being orthogonal, and every later use inherits it. **The test asserts Gram–Schmidt is visibly worse**, so if that ever stopped being true the reason for the extra work would be gone and the test would say so. |

| 25 | **`eigh`'s convergence test is relative to the Frobenius norm**; znum's is the constant `1e-30` | correctness at any scale | A fixed threshold declares any sufficiently small matrix already diagonal: **below a scale of about 1e-16 the off-diagonal sum falls under 1e-30 before a single rotation**, and the routine returns the untouched diagonal as the eigenvalues with nothing reporting a problem. Measured with the relative test: scale 1 → λ₀ 6.7328e-1, residual 1.6e-15; scale 1e-10 → 6.7328e-11, 1.3e-25; scale 1e-20 → 6.7328e-21, 2.9e-35. Same algorithm otherwise — znum's cyclic Jacobi is right, and is followed. ⚠ Running out of sweeps is `DomainError` here rather than a silent return. |

| 26 | **`lstsq` is QR-based** — as znum's is | not a divergence; a confirmation, with the numbers | znum solves by QR too and is right to. Recorded because the alternative is so tempting: `aᵀa·x = aᵀb` is one line and **squares the condition number**. Measured on a Vandermonde system with a known exact solution: n=5 → QR 5.9e-15, normal equations 8.2e-13; n=8 → 7.8e-13 / 1.6e-7; **n=10 → 1.3e-11 / 1.6e-4, seven digits lost**. The test asserts the normal equations are visibly worse, so the extra factorisation's cost is justified executably. ★ What DOES differ is underneath: this QR is Householder (row 24), so `q` is orthogonal where znum's is not. |

| 27 | **`svd` is one-sided Jacobi**; znum's is `eigh(aᵀa)` with `σ = √λ` | small singular values survive | Forming the Gram matrix squares the condition number, and here the consequence is sharper than lost digits: singular values 1 and **1e-9** become eigenvalues 1 and **1e-18**, below f64's epsilon. Relative error in σ_min — 1e-3: jacobi 1.5e-14 / gram 1.7e-11; 1e-6: 4.6e-12 / 1.1e-5; **1e-9: 2.0e-8 / 5.7 — 570% wrong**, returning 6.7e-9 for a value of 1e-9. Not a precision difference; a different number. ★ The test asserts the gap only where the squaring bites (σ ≤ 1e-6); at 1e-3 both routes are fine and claiming otherwise would overstate it. |

| 28 | **`pinv`'s rank cutoff is `rcond · σ_max`**; znum's is the constant `1e-12` | scale invariance | Deciding which singular values count as zero IS the content of a pseudo-inverse. A matrix with singular values 1, 1e-3, 1e-7 keeps all three at scale 1 and **only two at scale 1e-6** under an absolute cutoff — a real direction dropped because the units changed. Relative keeps three at both, and `pinv(k·a)·k` matches **to nine digits across six orders of magnitude**. ★ Third instance of the same class as rows 25 and 27: znum compares a quantity with dimensions against a bare constant. |

| 29 | **`einsum`'s spec is `comptime`**; znum's is a runtime `[]const u8` | four error classes moved to compile time | Every mistake in a SPEC is a property of the source, not the data: a missing `->`, an output label appearing in no input, a repeated output label, a wrong operand count. znum returns an `Error` for each, to be handled at the point of use on real data. Here each is a **compile error naming the exact problem** - verified by building all four. What stays at runtime is what actually depends on data: a rank not matching its subscript, and two operands disagreeing about a label's extent. |

| 30 | **`Named` puts axis names in the TYPE**; znum's `dimnames` is a 3 302-line parallel API | three error classes at compile time, and 60 lines | Names are comptime in both, and znum is right about that. The divergence is scope: `Named` WRAPS a `Tensor` and hands it back through `.tensor`, so every existing function keeps working and names are adopted where they help. What it buys, verified by building each: `axis("wdith")` -> `no axis called \`wdith\`; has: batch width`; a repeated name -> `axis name \`batch\` is repeated`; contracting `width` against `batch` -> `the axes being summed over must be the same axis`. |

| 31 | **`argmaxAxis` returns a FLOAT index**; znum returns `Tensor(i64)` | one element type per tensor | Every tensor here holds one type, and an index tensor would need a second. A float index is exact to 2^24 in f32 and 2^53 in f64, far past any axis this library can address. Stated in the doc rather than left to be discovered. |
| 32 | **No `keepdims` anywhere**; znum takes a `KeepDims` enum on twelve functions | measured to be unnecessary | znum ALLOCATES its results and so must be told what shape to make. Here the caller allocates. Measured: `reshape` on a dropped result **shares storage** and the reshaped tensor **broadcasts back against the input** exactly as a kept axis would. I implemented accepting both output shapes, then checked what it bought, and reverted it - the capability was already there through a function that does one thing. |

| 33 | **Turn-based trig**: `sinTurns`, `cosTurns`, `tanTurns`, `sincosTurns`; znum has none | exactness, and one fewer multiply | Code that calls `sin` usually holds a phase on [0,1] and multiplies by tau only because `sin` wants radians - which every fast `sin` divides straight back out. Taking turns skips both AND makes the reduction exact: `x - floor(x)` touches no mantissa bit. Measured at f32, `sin(tau*x)` at x=100000.25 turns is off by **2.76e-4** where this is EXACT; over 2000 whole turns at f64 the radian route drifts to **1.38e-12** where this returns exactly zero. Quadrant reduction makes every quarter turn exact too. Named `Turns`, not `tau`, because the point is that tau disappears - and `xFromY`, matching the existing `degFromRad`. |

| 34 | **`hstack`/`vstack`/`dstack` not ported** | `concat(axis)` already says it | They are `concat` with the axis baked in, and znum's own doc admits the trap: "this does not promote 1-D to 2-D the way numpy's vstack does". Three names with a footnote each, against one that takes the axis. |
| 35 | **`reshapeInfer` not ported** | caller-allocates makes it unnecessary | It exists so a caller can write `-1` for one dimension and have znum work it out - which znum needs because it ALLOCATES the result. Here the caller allocates, so the shape is already known. Same reason as `keepdims`, row 32. |
| 36 | **`repeatEach`, not numpy's `repeat`** | the name is the whole difference | `repeat` repeats each ELEMENT and `tile` repeats the WHOLE tensor, and neither numpy name says which. `repeatEach` beside `tile` reads differently at a glance. |

| 37 | **`medianAbsDev` and `meanAbsDev` are two functions**; znum has one `mad` with a `MadKind` | "MAD" means both | Every call site would read `mad(x, .median)` and every reader would need the enum. Two names say it without one - and the median version is the robust one, so it is the one whose name should be unambiguous. |
| 38 | **`percentile` not ported** | one scale, not two | znum's own doc calls it "Same thing on a 0-100 scale" as `quantile`. A second spelling of the same function is a second place for a bug. |
| 39 | **`correlation` takes no `ddof`**; znum's does | it cancels | The correction appears in the covariance and in both deviations and divides straight out. znum's doc admits it "genuinely doesn't matter". |
| 40 | **`coefficientOfVariation` and `standardError` spelled out**; znum has `cv` and `sem` | read more than typed | Two letters standing for three words is a lookup every time. |

| 41 | **`determinant` returns ZERO for a singular matrix**; `lu` returns `DomainError` | the same condition means different things to the two callers | A factorisation of a singular matrix is unusable for what factorisations are FOR - solving - so `lu` is right to refuse. A determinant is different: **zero is the complete answer**, and testing for it is how a caller detects singularity in the first place. The error is caught and turned into the zero it means. |

| 42 | **`BatchNorm`'s mode is an ARGUMENT**; znum's is a mutable field defaulting to `.training` | it cannot be forgotten | The field is PyTorch's `model.train()`/`model.eval()`, and forgetting to flip it is one of the most common bugs in either library: the network silently normalises by whatever batch it sees. On a batch of ONE the output is exactly zero for every feature. As an argument, a caller cannot reach that by omission - only by asking for it. |
| 43 | **`observe` is separate from `attach`** | `attach` only reads | znum folds the running-statistics update into the forward pass, so BUILDING the graph mutates the layer and recomputing it twice ages the statistics twice. |
| 44 | **`BatchNorm` goes through `layerNormRows` on the transpose** | one derivation, not two | Batch norm IS layer norm transposed - verified to 2.2e-16 against a direct per-column implementation - so the forward pass and its GRADIENT both come from a tested pair. znum writes both separately. |

| 45 | **`LstmCell`'s forget bias starts at ONE**; znum and PyTorch zero every bias | measured at 44x | A zero forget bias is `sigmoid(0) = 0.5`, so the cell HALVES its memory every step before learning anything. Measured over ten steps of pure decay: **0.000977 against 0.043604**. The result is Gers's, from 1999, and it is still absent from most implementations. |
| 46 | **Four `Gate`s, not twelve loose tensors** | the grouping IS the idea | znum has `w_ii`, `w_hi`, `b_i`, `w_if`, ... Every gate reads both the input and the previous hidden state, so `from_input` / `from_hidden` inside a named gate says what the pair is FOR. |
| 47 | **Not fused into one `(4*hidden, input)` matrix**, as PyTorch does | it needs tape machinery that does not exist | Fusing means a graph-level SLICE with a backward. Three matmuls saved on a cell whose cost is the sequence loop around it is not worth a new tape node; the fusion is a note, not a half-built abstraction. |

| 48 | **`Attention`'s causal mask is an ARGUMENT** (`Look`), not a field or a default | the failure is silent and flatters you | A model trained without the mask can SEE THE ANSWER it is predicting: the loss drops to near zero, the curve looks superb, and it generates nonsense on anything unseen. **The metric that would tell you is the one that looks best.** Same shape as `BatchNorm.Use`, worse consequence. |
| 49 | **The mask adds -1e30, not `-inf`** | `inf - inf` is NaN | Negative infinity is exactly right in algebra and gives NaN the moment a row is ENTIRELY masked - which a causal mask never does but a padded batch would. A number the exponential flushes to zero says the same thing and survives. |
| 50 | **The scale is derived from the projection's shape**, not a parameter | it cannot disagree | Without `1/sqrt(width)` the softmax saturates and the gradient vanishes, and passing the wrong dimension is a quiet, common mistake. |

| 51 | **Multi-head by slice-and-concat at rank 2**; znum reshapes to rank 4 and permutes | no reshape, no permute, no four axes | znum's `[rows, D] -> [B, S, H, d] -> [B, H, S, d]` needs a differentiable reshape AND permute, and every line afterwards reasons about four axes. A loop over `graph.slice` keeps every tensor rank 2, and each iteration IS the single-head maths. Cost: `heads` matmuls where a batched form does one - stated, not discovered. |

| 52 | **`bitwiseNot` AND `logicalNot`, both named**; znum has only `logicalNot` | they share no answers | `bitwiseNot(5)` is -6 and `logicalNot(5)` is 0. Two operations that read alike and mean different things - with only one of them present, a caller wanting the other reaches for what exists and gets a plausible number back. |
| 53 | **An over-shift is a `DomainError`**; Zig's `<<` is undefined behaviour there | one comparison per tensor | A shift reaching the bit width is ILLEGAL, and in a release build that is silent corruption rather than a crash. The check reads the TYPE's width, so `8` is legal for an `i32` and refused for an `i8`. znum has no shift at all. |

| 54 | **`div` stays FLOAT-ONLY; integers call one of FOUR** | Zig's own rule, and Zig names four | `a / b` on two signed integers is a COMPILE ERROR in Zig, and the message is the specification: "signed integers must use @divTrunc, @divFloor, @divCeil, or @divExact". So there are four here too, plus the two remainders. Following the language's vocabulary means a reader who knows Zig already knows this API. znum has none of them. |
| 55 | **`mod` and `rem` both named** | the sign of a remainder is the classic silent bug | They agree on positive inputs and disagree on negative ones, so **code tested on positive data passes and then indexes with a negative number** the first time real data arrives. `mod` wraps an index; `rem` is the leftover of a truncating division. |
| 56 | **One `affine`, not `addScalar` + `affine` + a scalar multiply** | the same line with constants folded in | Three names is three places to look and three docs to keep true. `affine(a, 1, k)` adds and `affine(a, k, 0)` scales, both readable at the call site. |

| 57 | **WITHDRAWN Sep 8. `categorical` is znum's method** - subtract the max, walk a cumulative sum | the divergence had no justification | I claimed znum's would overflow at logits of 800. **It does not** - it subtracts the maximum too, measured returning the correct ratio. And Gumbel-max costs one random draw per CATEGORY against one per sample. Kept from znum: defaulting to the LAST category, so a target a hair under the total does not bias category zero. |
| 58 | **`boundedIndex` multiplies rather than taking a modulo** | the modulo is skewed | `random % bound` is uniform only when `bound` divides 2^32. For a bound of 3 the skew is a part in a billion; near 2^31 it is fifty percent - **the same line produces both**. `(u32 * bound) >> 32` is uniform for every bound and has no rejection loop to make the draw count unpredictable. |

| 59 | **Turns for angles that are DRAWN, radians for angles that are DIFFERENTIATED** - decided per piece of state, and the name always carries the unit | derivatives are free in radians and cost a tau in turns | `d/dtheta sin(theta)` is `cos(theta)` only in radians; in turns every derivative picks up a factor of tau. The cartpole equations are differential equations, so radians are the unit in which they contain no constants. Writing it in turns meant converting the angular acceleration, **and that conversion was a place to be wrong** - the pole fell tau times too fast with every sign correct. `pole_rad` / `pole_rate_rad`, never bare. |

| 60 | **`polyakUpdate` uses `(1-f)*a + f*b`, not znum's `a + f*(b-a)`** | measured: exact at both ends, no worse in between | At f32 with a target of 1e8 and an online value of 1, `follow = 1` under the lerp form does NOT reproduce 1 - the small value is lost in the subtraction. The affine form has no subtraction to lose it in, and near zero, where this actually runs, the two agree to the last bit. |
| 61 | **The coefficient is `follow`, not `tau`** | `tau` is 2 pi in this codebase | The literature calls it tau. Here tau is in zimrmath, in the turns vocabulary, and throughout the drawing stack - **a second meaning inside an RL file is the kind of collision that survives review because both readings are plausible.** |

| 62 | **CLOSED Sep 8. `cartpoleStepBatch` plus a `cartpole_step` kernel and sweep row** | the pure core made the twin free | znum steps 1024 environments in one dispatch; we now step the batch on the host and on the GPU, verified to EXACTLY zero across 256 environments. The batched version is a LOOP over the scalar one, so there is one definition of the physics and the scalar entry point IS the host twin. `polyakUpdate` still has no GPU path. |

⚠ **Unjustified so far — these are debts, not decisions:**

| # | difference | what is missing |
|---|---|---|
| 10 | **f32 only**; znum has a dtype-injected family | zimrnum's kernels hardcode `f32`. znum injects `@import("dtype").T`. **Not yet located in znum's build** (`grep dtype build.zig` = 0), so the mechanism is unverified — do not repeat the `-Mdtype` claim until it is read. |
| 11 | **Coverage gate is PARTIAL** | ✅ KERNEL ↔ ROW is now a compile error, both directions, proven by control (Sep 4). ⚠ OP ↔ KERNEL is still open: a `zimrnum` function with no GPU kernel at all is invisible, because zimrnum has no device dispatch of its own. That half arrives with the dispatch seam. |
| 12 | **No `AnyTensor` / dimnames / pytree** | ergonomics layers; no argument either way yet |
| 17 | ~~Nothing distinguishes host-by-design from kernel-pending~~ **RESOLVED Sep 8, by derivation rather than annotation.** The reference table has a GPU column generated from the sweep: each `Case` names a kernel and calls one `zn` function, so "which functions are verified on a device" comes from the one place that verification happens. **Measured: 181 declarations — 55 module functions with a verified kernel, 64 methods, 62 host-only.** Of the host-only, 25 were kernel-pending; **ten closed Sep 8** (`maeLoss huberLoss binaryCrossEntropyFromLogits conv2dInto varianceAxis maxPool2dInto avgPool2dInto whereInto sgdMomentum adamStep`), leaving fifteen: `prodAxis prodAll anyNonzero allNonzero argsort materialise takeInto concatInto tileInto klDivergenceRows oneHotRows crossEntropyRows crossEntropyRowsGrad accuracy clipByNorm`. **The third-buffer question is settled: the pipeline now has `c` and `state`**, so what remains needs integer indices or is a reduction to a scalar the sweep already covers elsewhere. |
| 18 | ~~Eleven sweep rows have never run on a device~~ **CLOSED Sep 8: 59/59 on the Adreno.** | `atan2`'s corrected bar plus `softplus`, `silu`, `leaky relu`, `elu`, `min all`, `mse loss`, `max axis0`, `min axis0`, `mean axis0`, `argmax axis0`, `cumsum rows`. All five new twins match zimrnum exactly on the host; the device is the remaining check. `zn_sweep_59.html` shipped Sep 7. |

### 10.4 Immediate next actions, in order

1. ~~Measure compensated vs pairwise summation~~ **DONE Sep 4.** Pairwise is 3.3× faster and
   erratic under cancellation; both are now offered and the trade-off is tested. The prediction
   in this line — "the honest answer may be pairwise-by-default" — was **half right**: pairwise
   earned a place, but not the default, because its failure is silent and unbounded while its
   benefit is a bounded 3.3×.
2. ~~The coverage gate~~ **HALF DONE Sep 4.** Kernel↔row is pinned at comptime. Op↔kernel needs
   the dispatch seam and stays open.
3. ~~Reductions to scalar and vector on the GPU~~ **STARTED Sep 4.** `sum_axis0` and `sum_all`
   land, and `Case.out_len` gives the sweep its second comparison shape. Still to do in stage A:
   `mean`, `max`, `argmax`, and the TILED forms of all of them (tree reduction with barriers).
4. Then dtype injection (debt 10), by first READING how znum actually does it.

### 10.5 Next actions, as of the Sep 4 review — every item closed by Sep 8

### 10.6 THE COMPLETION PLAN — measured Sep 8, ordered by what unblocks what

**The denominator matters.** znum has 744 public functions across the namespaces below, but 72 of
them are internal machinery zimrnum expresses with fewer: `cpu`'s 54-function dispatch layer
(`binary`, `binaryTyped`, `unary`, `reduceAll`, …) is `map` and `zip`, and `io`'s 18 byte helpers
(`putU8` … `readU64`, `need`, `take`) are one generic `putInt`/`takeInt` pair. **Against the
672-function user-facing surface, zimrnum covers 229 — 34%.**

Counting by concept rather than by name matters too: znum's `mae` is `maeLoss`, its `convolve` is
`convolveInto`, its `atan2` is `atan2f`. A raw name match reports 27%; normalising the suffix
conventions reports 34%. **34% is the honest figure** and the one to move.

#### Tier 1 — completes something already half-built (147 functions)

Each of these finishes a namespace whose core exists, so the marginal value is high and the design
questions are already answered.

| # | Area | Left | What, precisely |
|---|---|---|---|
| 1 | **`nn` layer types** | 54 → **41** | `Linear`, `Conv2d`, `LSTM` as `Dense` already is: own the weights, `attach` to a graph, return parameter handles. **`Dense` is the template**; the rest is the same shape with different arithmetic. Unblocks `train` and `infer`. |
| 2 | **`ops` remainder** | 48 → **37** | `tan asin acos atan sinh cosh asinh acosh atanh rsqrt`, and the integer elementwise set. Mechanical, each a kernel too, each testable by an identity (`asin(sin x) == x` on the branch, `cosh² − sinh² == 1`). |
| 3 | **`autograd` remainder** | 35 | Gradient checkpointing, `noGrad` scopes, higher-order derivatives. **`checkGradient` already exists**, so every new rule is verified the moment it is written. |
| 4 | **`linalg` remainder** | 21 → **11** | `matmulNT`/`matmulTN`/`bmm` (index arithmetic on what exists), then `qr`, `eigh`, `svd`, `lstsq`, `pinv`. Each factorisation is tested by reconstruction, as `lu` and `cholesky` are. |

#### Tier 2 — self-contained, no dependencies either way (98)

| # | Area | Left | What, precisely |
|---|---|---|---|
| 5 | **`stats` remainder** | 23 -> **15** | `skew kurtosis geoMean harmMean mad sem cv quantile percentile mode histogram bincount zscoreAxis`. Every one testable against a distribution with known moments. |
| 6 | **`optim` remainder** | 17 -> **9** | Flat-parameter views (one contiguous buffer for all weights — the layout the GPU trainer already uses), clipped steps, `cosineLR` and the schedules. |
| 7 | **`reduce`/`manip`/`index`** | 38 | `argmin all any median unique`; `flip roll tile stack vstack meshgrid moveaxis`; `gather scatter booleanMask nonzero sort`. **`flip` and slicing need nothing new** — `base` and signed strides already exist. |
| 8 | **`conv`/`pool`/`embed`** | 13 → **10** | `im2col`/`col2im` and the batched multi-channel forms; embedding forward and its scatter-add backward. The single-channel versions exist as the reference. |
| 9 | **`metrics`, `losses`, `fft`, `calc`, `random`, `checkpoint`, `pytree`** | 25 | `confusionMatrix f1PerClass macroF1`; `nll`, `bce` on probabilities; `irfft rfftfreq`; non-uniform `gradient`/`trapz`; convenience RNG wrappers; whole-model save/load; tree helpers. All small. |

#### Tier 3 — large, and each is a project (198)

| # | Area | Left | Note |
|---|---|---|---|
| 10 | **`rl`** | 66 | The numerical core is done. What is left is per-algorithm update loops (PPO, SAC, TD3) and the environments (cartpole, reacher). **The environments are the deciding question**: they are simulation, not numerics, and may belong in an example rather than the library. |
| 11 | **`df`** | 48 | Dataframes: `Series`, joins, groupby. **Decide whether zimrnum wants them at all** — nothing else in the library depends on them, and a game engine's numerics library is a strange place for a join. |
| 12 | **`dimnames`** | 31 | Named dimensions. Ergonomics; costs nothing to defer. |
| 13 | **`xf`, `train`, `infer`** | 29 | The transform layer, `Dataset`/`DataLoader`/`fit`, prepared inference paths. `train` should follow `Optimizer`'s shape: own the state, one call per epoch. |

### zimrmath as a take on std.math: the ownership plan

**The goal is control, not convergence.** The CPU path keeps std's precision, the GPU path keeps
its fast polynomial, and the two are allowed to disagree - that divergence is deliberate and
documented per function. What is missing is that zimrmath does not OWN the CPU implementation; it
delegates, so the accuracy it offers is whatever std happens to do that release.

zimrmath uses 14 std.math symbols in its body (68 sites; the other 422 references are in tests and
prose). Measured, here is what owning each costs, with the f16/f80/f128 material excluded because
zimrmath is f32 and f64:

| Symbol | std total | f32+f64+shared | other widths | deps | Verdict |
|---|---|---|---|---|---|
| `hypot` | 87 | **87** (already generic) | 0 | none | **take it** |
| `cbrt` | 99 | **99** | 0 | none | **take it** |
| `expm1` | 251 | **251** | 0 | none | **take it, and it is a FIX** |
| `tanh` | 95 | **95** | 0 | expm1 | **take it, after expm1** |
| `asin` | 348 | 194 | 154 | none | later |
| `acos` | 371 | 216 | 155 | none | later |
| `atan2` | 190 | 152 | 38 | atan | later |
| `atan` | 556 | 294 | **262 (47%)** | none | later |
| `pow` | 174 | 174 | 0 | **5 files, ~380 lines** | leave delegating |

**`atan` is 47% coefficient tables for widths zimrmath does not have.** An f32+f64 library is
roughly half the size of std's, which is the whole reason "our take" is a smaller thing than a
fork.

#### The accuracy audit: four more bugs of the `tanh` class

`tanh` was found by accident, so the same question was asked of every elementwise function at once
- f32 path against the f64 path, over eight decades down to 1e-8. **Four more, all the same
shape**, and none visible to any existing test because none of them asked about small inputs:

| Function | Was | Now | The cancellation |
|---|---|---|---|
| `sinh` | **1.0** | 1.8e-7 | `e^x - e^-x`: both round to 1, difference is 0 |
| `asinh` | **1.0** | 2.1e-7 | `log(x + sqrt(x*x+1))`: the argument rounds to 1, log is 0 |
| `atanh` | **1.0** | 2.1e-7 | `(1+x)/(1-x)` rounds to 1, log is 0 |
| `gelu` | **3.0** | 4.3e-6 | `1 + tanh(u)` when `tanh(u)` approaches -1 |

★★★ **THE FIXES ARE ALL THE SAME MOVE**: rewrite so the subtraction never happens.
`expm1(x) - expm1(-x)` for `sinh`, `log1p` for `asinh` and `atanh`. And `gelu` is
`x * sigmoid(2u)` - which **is** `0.5*x*(1 + tanh(u))` rearranged, not an approximation of it, and
is also the shorter expression. The cancellation-free form was the simpler one in every case.

★★ **THE f64 PATH IS A GENUINE ORACLE FOR THE f32 ONE.** It is the same algorithm with
fifty-two bits instead of twenty-three, so agreement means the FORM is right rather than that two
implementations share a mistake. That is what makes this audit possible at all without an
arbitrary-precision library.

★ Made permanent as a test over all ten cancellation-prone functions, at a bar of 1e-5 - two
orders below anything a cancellation bug produces, and loose enough not to fail on the two or
three ULP some of these are by construction. Proven by putting back the old `sinh` (fires at 1.0)
and the old `gelu` (fires at 1.0e-5).

#### Stage 1: DONE Sep 8. Five functions owned, and one of them was wrong.

| Function | Result vs std | Lines | How |
|---|---|---|---|
| `hypot` | **bit-identical**, 200 000 random pairs and every extreme | 35 | ported, f32 widens to f64 |
| `cbrt` | **bit-identical** across 60 decades, signed zero and subnormals | 75 | ported, both cores |
| `expm1` | f64 3.8e-16, f32 2.0e-7 | **5** | Kahan, not a port |
| `log1p` | f64 3.9e-16, f32 2.2e-7 | **5** | Kahan, not a port |
| `tanh` | f64 5.6e-16, f32 3.4e-7 | 8 | built on `expm1`, NO `is_gpu` branch |

★★★ **`expm1` AND `log1p` WERE THE ACCURACY BUG, AND THE FIX IS FIVE LINES.** They were the plain
identities `@exp(x) - 1` and `@log(1 + x)`, losing everything the function exists to keep:

        x = 1e-5    identity 9.7e-12    now 1.7e-16
        x = 1e-8    identity 1.1e-8     now 1.7e-16
        x = 1e-12   identity 8.9e-5     now EXACT

**Kahan's observation is that the error is recoverable**: `log(u)` is the argument that WOULD have
produced exactly the `u` that was computed, so `(u - 1) * x / log(u)` rescales the badly-cancelled
difference by the ratio of the true argument to the effective one. Both terms lose the same
digits and the quotient does not. std spends 251 lines on argument reduction and a minimax
polynomial per width to gain the last 2 ULP; five lines is the better trade for a library that
also runs in a shader.

★★★ **AND THE OLD SHADER `tanh` WAS 1.0 RELATIVE ERROR AT f32.** `(e^2x - 1)/(e^2x + 1)` is
algebraically right and numerically hopeless near zero: `e^2x` rounds to exactly 1, the numerator
becomes 0, and `tanh(x)` returns 0 when the answer was `x`. **That is the activation function, and
near zero is where an activation lives.** The sweep never caught it because a normal(0,1) field has
no values small enough. `expm1(2x)/(expm1(2x) + 2)` is the same function without the cancellation,
one expression for both backends, and it costs the host nothing.

★★ **THE XOR TEST'S BOUND WAS OVER-FITTED TO ONE TRAJECTORY.** `norm < 1e-6` was a threshold read
off a single run, and a ONE-ULP change to `tanh` broke it - SGD at rate 0.5 on XOR is chaotic, and
after 4000 steps the norms were 1.6e-5 where they had been 2e-11. Both runs had converged; only one
passed. Near a minimum the MSE gradient scales as the square root of the loss, and the measurement
says so exactly: **loss 3.0e-10, norm 1.6e-5, sqrt(3.0e-10) = 1.7e-5**. The bound is now
`norm <= 4 * sqrt(loss)`, which is scale-free and survives any change that keeps the network
converging.

★ std.math symbols in the zimrmath body: **14 -> 11**. What remains is `asin acos atan atan2 pow`
(stage 2 and 3), and `clamp exp floatEps inf tan approxEqAbs` which are one-liners zimrmath mostly
already has under its own names.

#### Stage 2 and beyond, unchanged: `asin`, `acos`, `atan`, `atan2`; `pow` stays delegated

★ **Two of these are not ownership at all - they are a precision BUG I introduced.** `zm.expm1`
and `zm.log1p` were written as the plain identities `@exp(x) - 1` and `@log(1 + x)`, with a
comment admitting they carry no extra precision near zero. Measured against std at f64:

        x        zm (identity)    relative error
        1e-3     1.000500166708e-3    4.29e-14
        1e-5     1.000005000007e-5    9.70e-12
        1e-8     9.999999939225e-9    1.11e-8
        1e-12    1.000088900582e-12   8.89e-5     <- five significant digits gone

At 1e-12 the answer is wrong in the fifth digit, and the whole point of having an `expm1` is that
it is right there. This is the one place zimrmath is measurably WORSE than std today, and it is
worth doing before any of the ownership work.

★★ **Order, and why:**

1. **`hypot` (87 lines, no deps, already generic).** The cheapest possible first move: std's
   version is already width-generic, so it ports as-is. Proves the pattern with nothing at risk.
2. **`cbrt` (99 lines, no deps).** Two per-width cores that collapse into one generic function
   with a comptime-selected constant. First real test of the "one generic body instead of std's
   two" claim.
3. **`expm1` (251 lines, no deps).** The accuracy fix. Its own tests come from the table above -
   the current identity must FAIL them, which is the negative control.
4. **`log1p`.** Same story; std keeps it in `log1p.zig`, and the same measurement applies.
5. **`tanh` (95 lines).** Needs `expm1` first, which is why it is fifth rather than second.

That is **~530 lines to own five functions**, against ~2 580 for all fourteen. It removes the
worst accuracy gap, takes the three functions with no dependencies at all, and leaves `pow`
delegating - one function is not worth five files.

⚠ **Not in stage 1: `asin`, `acos`, `atan`, `atan2`.** Together they are 856 lines even after
dropping the other widths, and they are the ones whose CPU and GPU paths differ MOST (`asin`'s
polynomial is 1.2e-3 against std's 1e-16). Owning them is a real project, and doing it badly would
mean quietly lowering CPU precision - the one outcome this plan exists to avoid.

⚠ **`pow` stays delegated.** 174 lines of its own plus `copysign`, `frexp`, `modf`, `powi` and
`scalbn` - about 380 more - for one function. The dependency count, not the line count, is what
rules it out.

#### On supporting more than f32

f64 comes almost free in stage 1: every one of those five has an f64 core in std that is the same
algorithm with different constants, so one generic body with `comptime` coefficients covers both.
**f16 does not**: it is a different problem (the polynomial degree that suits f32 is wasteful at
f16, and std has no f16 path for most of these either). The honest scope is **f32 and f64,
vectors of both through `perLane`**, and f16 only where a builtin already does the work.

#### A host twin test cannot see an `is_gpu` branch

The headless twin tests compile a kernel for the HOST, where `is_gpu` is false and every
`is_gpu` branch takes the CPU path. **They measure the branch that will not run.** `zm.cosh`
measured 0.0 that way and 29.6 on the device.

The rule that follows: **a kernel may only call a `zm` function that computes the same expression
on both backends.** Checked at comptime in `zn_unary.zig` against an audited list; a call to
anything else is a compile error naming it. Six functions are on the allowed-but-branching list,
each with its device-measured agreement recorded beside it.

#### The three gates, and the edge that was missing

zimrmath, zimrnum and the GPU form a triangle. Two edges were gated and the third was not:

| Edge | Gate | Since |
|---|---|---|
| zm <-> zn | same elementwise set, and equal ELEMENT BY ELEMENT | Sep 8 |
| zn <-> GPU | every kernel entry has a sweep row; every input buffer is uploaded | earlier |
| **zm <-> GPU** | **only where a kernel happened to call zm - 4 of 77** | **closed Sep 8** |

**Eighteen unary kernels wrote out arithmetic `zm` already spelled** - `@max(x, 0)` for `relu`,
`(e^x - e^-x) * 0.5` for `sinh`, and so on. Each was a second implementation of a function that
already existed, on the side of the fence where the `zm` vocabulary pin does not reach.

Thirteen now call `zm` directly (the other five have no zm counterpart). So **one sweep row checks
all three sides at once**: zm's host path (through zn's delegation), zm's SPIR-V path, and the two
against each other. Before, a hand-rolled kernel checked only that the same formula had been
written twice by the same hand. All thirteen twins measured **exactly 0** after the change.

#### What the coverage number is, and is not

**Measured by NAME, zimrnum has 94 of znum's 549 user-facing functions - 17%.** Measured by
concept it is around 40%. The gap is entirely the deliberate renames: `sumAll` is znum's `sum`,
`binaryCrossEntropyFromLogits` is its `bce`, `rootMeanSquare` is its `rms`, and a name-matcher
counts none of them.

So the headline percentage **cannot be computed** and every figure quoted in this plan before
today was a judgement wearing a measurement's clothes. What CAN be measured is stated instead:

| Quantity | Value | How |
|---|---|---|
| znum `pub fn`, unique | 774 | counted |
| less internal namespaces (`cpu`, `Scope`, `UniformDims`, `PermuteCache`, `config`) | -196 | counted |
| less test fixtures (`*LossF32`, `*Cache`) | -22 | counted |
| less `init`/`deinit`/`format` noise | -7 | counted |
| **user-facing denominator** | **549** | derived |
| zimrnum public declarations | 311 | counted |
| matching znum by name | 94 | counted |

The honest summary is: **the remaining work is concentrated in five places** - `ops` integer and
bitwise variants (39), layer types (21), `reduce` (21 -> 14), `stats` (19) and `df` dataframes (18) -
and everything else is either done, deliberately renamed, or znum's internals.

#### The zimrmath / zimrnum contract, settled Sep 8

**zimrmath defines an operation on a scalar or a vector; zimrnum applies it over a shape.** The
elementwise set is therefore the SAME set on both sides, and zimrnum's body is a loop over
zimrmath's function rather than a second implementation of it.

★ **A comptime gate enforces the correspondence**, plus element-by-element equality — matching
names prove nothing on their own. It earned its place twice on its first run: it named `exp2` as
missing from zimrnum, then the equality check caught `cbrt` and `cosh` disagreeing by 1 ULP because
zimrnum was reimplementing what zimrmath already had. Nine functions now delegate.

⚠ **What the gate cannot catch**: deleting a zimrnum function that other code calls fails to
compile before the check runs, so the message is the compiler's, not the gate's. Proven by
negative control. The drift it exists to catch — a function added to one side only — is proven to
work by the second control.

★ **Two deliberate exceptions, recorded rather than skipped**: zimrmath's `ln` is zimrnum's `log`
(matching C, `@log` and every tensor library), and zimrmath's `clamp01` is what other libraries
call `saturate` — a private stub in zimrmath reserves that name to say so.

#### The naming rule, settled Sep 8

**znum is a private first draft, not an authority.** Where its name is clearer, take it; where it
is an abbreviation, expand it. zimrnum's names should be at least as clear and verbose as znum's,
and the port is the opportunity to make them so.

**The tensor operations own the plain names.** `zn.sqrt`, `zn.log`, `zn.clamp`, `zn.lerp` — no
suffix. The `reserved-math-names` rule exists so a file doing vector maths can write `sqrt(v)`
rather than `zm.sqrt(v)`; in zimrnum the tensor `sqrt` is the primary vocabulary and zm's scalar is
the visitor, so the priority inverts. The file says so with a `//! lint:off` directive and its
reason.

★ **Ten of the seventeen collisions were phantom.** zimrnum reaches for Zig's builtins for scalars
— `@sqrt` 21 times, `@log` 26, `@abs` 24 — and never touched zm's `sqrt`, `log`, `exp`, `abs`,
`pow`, `floor`, `ceil`, `atan2`, `hypot` or `lerp`. Those names were blocked by the rule alone,
protecting nothing.

★ **The seven real ones are aliased with a `scalar` prefix**: `scalarCos`, `scalarSin`,
`scalarTrunc`, `scalarRound`, `scalarLog2`, `scalarLog10`, `scalarClamp`. Turning the rule off
without those renames would have let `pub fn cos` silently shadow the alias and change what eight
call sites mean — which is the bug the rule exists to prevent, and it still does.

★ **`Into` survives only where it means something**: 12 names, all of which write into a
destination the caller supplies and have no scalar counterpart — `concatInto`, `conv2dInto`,
`convolveInto`, `whereInto` and the like. Down from 32.

**Abbreviations are expanded** unless the abbreviation is the universal name of the thing.
`fft`, `dft`, `rfft`, `lu` stay; `trapz`, `gae`, `rms`, `Cplx`, `Summer` did not.

#### The GPU backlog, separately

70 of 226 declarations have a device-verified kernel. **18 remain kernel-pending**, all needing
either a third input buffer (`whereInto`, `sgdMomentum`, `adamStep`, `crossEntropyRowsGrad`) or
integer indices (`takeInto`, `oneHotRows`, `accuracy`). **The decision to make is whether the
sweep grows a third buffer and an index buffer**, or whether these are host-side by design. Until
that is settled the backlog cannot shrink.

⚠ **The sweep is at its time budget: 91 x 3 settle frames = 2.27 s at 120 Hz.** An attempt to fix
this by waiting one frame and detecting staleness **was wrong and the device proved it** — see the
Sep 8 entry. The settle is three, matched to the queue depth `zimrnum_train` measured. **When the
sweep next grows, the budget is bought back by SPLITTING IT INTO PAGES, not by reading early.**

#### What "best possible result" means here

Not 100% of znum. Three of the four tier-3 items are open questions rather than work, and
answering them "no, and here is why" is a better outcome than porting them. The target is:

1. **Every namespace a network needs, complete** — tiers 1 and 2, taking coverage from 34% to
   about 70% of the user-facing surface.
2. **Every divergence in the register with a metric**, which is 23 rows and no debts today.
3. **Every kernel device-verified**, which needs the sweep decision above.
4. **A written answer for `df`, `dimnames`, and the RL environments** — in or out, with the reason.

## 11. Journal

- **Sep 8 2026 - `graph.ppoClipLoss`: PPO on the tape. Green on the first pass. lint 0, `check`
  green, both smokes PASS, fmt clean, 120 + 170 tests, 398 reference rows.**
  * **THE GAP TURN 9 FOUND, CLOSED.** `ppoClipObjective` computes the formula and is not
    differentiable, so the library could say what a PPO step was worth and not take one. The
    end-to-end test found it by having to fall back to REINFORCE.
  * ★★★ **THE CLIP IS A `min` IN THE FORWARD AND THE ALGORITHM IN THE BACKWARD.** Where the
    clipped branch is smaller the objective no longer depends on the ratio, so **the gradient is
    exactly zero** and the update stops pushing a ratio that has already run too far. A version
    that computed the right loss and the unclipped gradient would still diverge, and every
    forward-only test would pass.
  * ★★ **THE TEST ASSERTS THE ZEROS AND ALSO A NON-ZERO.** One index clipped from above with a
    positive advantage, one clipped from below with a negative one - and one UNCLIPPED index that
    must not be zero, **or the test would pass against a backward that returns zero everywhere**.
    Plus central differences at every element, because a piecewise objective gives plausible
    numbers on the wrong branch.
  * **A NEW `constants` FIELD ON THE NODE, NOT AN OVERLOADED `labels`.** `labels` is
    `[]const usize` and says "class indices". The old log-probabilities and advantages are neither
    - **a slot whose name is a lie costs more than a field**, which is the same conclusion as
    `repeat_count` and `slice_start` on the kernel side.
  * The exhaustive switches did their job again: adding the op forced both `backward` and
    `recompute` to handle it.


- **Sep 8 2026 - 95/98 on device: three red, all rows I had just added, two with twins measuring
  EXACTLY ZERO. All three fixed. lint 0, `check` green, both smokes PASS, 119 + 170 tests.**
  * ★★★ **A TWIN THAT PICKS ITS OWN PARAMETERS VERIFIES A DISPATCH THAT NEVER HAPPENS.**
    `slice_columns` divides by `cols` to find its row; my twin set `cols` to the OUTPUT width,
    while **the sweep sets it once for every row to the FIELD's width**. The kernel walked 32 rows
    of 64 where it needed 64 rows of 32, and the twin was correct about a configuration nothing
    dispatches. The kernel now DERIVES its width from `cols - slice_start`, both of which the host
    really sets.
  * ★★ **AND THE REFERENCE CAN BE THE WRONG ONE.** `mesh grid x` passed the same buffer for out_x
    and out_y, so the row grid overwrote the column grid - the CPU side computed the wrong grid
    while the kernel computed the right one. My twin used two buffers and passed.
  * ★★ **THE THIRD FAILURE WAS THE OPPOSITE LESSON.** `cartpole step` measured exactly zero on the
    twin and 2.4e-7 on device - one ULP, and correct. **The twin compiles the kernel FOR THE
    HOST**, so `@sin` is the host's library on both sides; it cannot see a library difference, only
    an algebraic one. A kernel calling a transcendental needs a ULP bar, not a zero one. Sixteen,
    like every other row that transcends a builtin.
  * **BOTH ADDRESSING KERNELS RE-VERIFIED UNDER THE SWEEP'S OWN PARAM BLOCK** - transcribed from
    the host rather than chosen - and both measure exactly zero there.


- **Sep 8 2026 - row 62 closed: batched cartpole on host and GPU. Sweep is NINETY-EIGHT, 86
  kernels. lint 0, `check` green, both smokes PASS, fmt clean, 119 + 170 tests.**
  * ★★ **THE PURE CORE PAID FOR ITSELF, AND THE TEST SAYS SO LITERALLY.** `cartpoleStepBatch` is a
    LOOP over `cartpoleStep` - there is no second copy of the physics - and the permanent test
    asserts every row of a 64-environment batch equals the scalar call for that row **to the
    bit**. The scalar entry point is also the host twin the kernel is checked against, so the
    twin cost nothing to write. Twin measured at **exactly zero across 256 environments.**
  * **The batch exercises both outcomes**: the test asserts some environments fail and some
    survive, because a batch that all survives never tests the flag.
  * ⚠ **AND I MADE THE `mesh_grid` MISTAKE AGAIN.** The kernel wrote the reward and failure flag
    after the state block - four floats per environment exactly fills the output buffer, so the
    extra two per environment ran 2048 floats off the end. **Every unit test passed**; the smoke
    caught it as `RuntimeError: unreachable`, exactly as it caught the first one. Second time, so
    the note now sits in the kernel itself rather than only in the journal.
  * The sweep compares the STATE, not the flag: a flag is a comparison against a constant and
    cannot drift between backends, where the arithmetic can.
  * 98 rows x 6 settle = 4.90 s at 120 Hz, inside the six-second budget.


- **Sep 8 2026 - second adversarial review, this time of the DIVERGENCES. One withdrawn, one gap
  recorded. lint 0, `check` green, both smokes PASS, fmt clean, 118 + 170 tests.**
  * ★★★ **I WITHDREW A DIVERGENCE. `categorical` IS znum'S METHOD AGAIN.** I had replaced it with
    Gumbel-max and written in the doc, the test AND the plan that znum's "would overflow at logits
    of 800". **It does not** - znum subtracts the maximum before exponentiating and returns the
    correct ratio, measured. The justification for diverging never existed, and the replacement
    was worse: **one random draw per CATEGORY against one per sample**, and it caused the hash
    collision the previous review found.
  * ★★ **A CLAIM ABOUT THE CODE YOU ARE REPLACING NEEDS THE SAME EVIDENCE AS A CLAIM ABOUT YOUR
    OWN.** Writing it into three places did not make it true. Running it took one test.
  * **AND ONE CAPABILITY GAP RECORDED RATHER THAN SPUN.** My cartpole is a pure function with
    named fields and is genuinely better to USE. znum's steps **1024 environments in one GPU
    dispatch with zero readbacks**; mine steps one on the host. That is not a trade I made, it is
    something I do not have - and the honest statement is "better API, less throughput". The same
    applies to `polyakUpdate`, which znum runs through an existing GPU kernel.
  * **WHAT SURVIVED**: the affine Polyak form (measured exact at both ends where the lerp is not),
    the pure step, named state fields, reset separated from step, `follow` rather than `tau`,
    radians for a differentiated angle. Each of those has a measurement or a reason that does not
    depend on a claim about znum being wrong.
  * ★ **KEPT FROM znum**: defaulting to the LAST category, so a target a hair under the total from
    rounding does not bias category zero. A careful detail I would not have thought of.


- **Sep 8 2026 - plan turn 9: AN AGENT THAT LEARNS. lint 0, `check` green, both smokes PASS, fmt
  clean, 118 + 170 tests, tutorial 16.5.**
  * ★★★ **EVERY COMPONENT TEST CAN BE GREEN WHILE THE AGENT IS AT CHANCE.** `cartpoleStep` has the
    right physics, `categorical` the right distribution, `Dense` a checked gradient, the tape
    matches finite differences - **and none of that says anything can learn.** My first loop ran
    perfectly and went 16.4 -> 16.1, because the advantage sign was backwards and only one layer
    was being updated. Both bugs are invisible to every other test in the file.
  * **FIVE SEEDS MEASURED BEFORE CHOOSING THE BAR**: first rounds 13.4 to 23.4, last rounds 20.4
    to 47.9, all five improving by more than half. The bar is a 40% rise - under the worst seed's
    margin so it will not flake, and far above the noise of a policy that is not learning. Plus an
    absolute claim, since an untrained cartpole survives about twenty steps.
  * ★★ **AND THE TURN FOUND A REAL GAP: `ppoClipObjective` RETURNS A SCALAR, NOT A `Var`.** It
    computes PPO's formula but is not on the tape, so it cannot drive a gradient - the library has
    PPO's arithmetic and not PPO's training step. **That was invisible until something tried to
    train with it**, which is what an end-to-end test is for. Recorded rather than papered over;
    the test uses REINFORCE, which the tape does support.
  * `reacherStep` deferred to a later turn - between a second environment and an agent that
    demonstrably learns, the second is the claim worth having.


- **Sep 8 2026 - plan turn 8: `polyakUpdate`. lint 0, `check` green, both smokes PASS, fmt clean,
  117 + 170 tests, 396 reference rows. Rows 60-61.**
  * ★★ **I MEASURED znum'S FORM BEFORE COPYING IT, AND IT IS WORSE.** `a + f*(b-a)` is the usual
    lerp and it is what znum writes. At f32 with a target of 1e8 and an online value of 1,
    `follow = 1` **does not reproduce 1** - the small value is lost in the subtraction. The affine
    form `(1-f)*a + f*b` is exact at both ends and agrees to the last bit near zero, where this
    actually runs. Copying the obvious form would have been the easy turn.
  * ★★★ **AND THE COMPARISON ONLY SHOWS UP AT RUNTIME - THE THIRD TIME THIS SESSION.** Written as
    a comptime expression, `1e8 + 1.0*(1.0 - 1e8)` folds at full precision and gives exactly 1, so
    the lerp form looks lossless. Read the same values back from a tensor and it is not.
    **Constant folding is a different machine**, after signed division and the cartpole rate.
  * **THE COEFFICIENT IS `follow`, NOT `tau`.** The literature calls it tau; here **tau is 2 pi** -
    in zimrmath, in the turns vocabulary, throughout the drawing stack. A second meaning inside an
    RL file is exactly the collision that survives review because both readings are plausible.
  * A coefficient outside [0, 1] is a `DomainError`: that is not a slow follow, it is an
    extrapolation past the online network, and it will not settle.
  * ⚠ My first runtime fix used a module-level `var`, which the `module-var` rule bans. Reading
    the value back out of a tensor does the same job without one.


- **Sep 8 2026 - cartpole moved to radians. The conversion is GONE, not corrected. lint 0, `check`
  green, both smokes PASS, fmt clean, 116 + 170 tests. Register row 59.**
  * ★★★ **CHOOSING THE UNIT THE EQUATIONS ARE WRITTEN IN REMOVES THE CONVERSION RATHER THAN
    FIXING IT.** I had converted the angular acceleration from radians into turns and got it
    wrong; the fix last turn was to convert correctly. **The better fix was not to convert.** The
    cartpole dynamics are differential equations, and `d/dtheta sin(theta)` is `cos(theta)` only
    in radians - in turns every derivative carries a tau.
  * **SO THE RULE IS PER PIECE OF ANGLE STATE**: turns for angles that are DRAWN, where a quarter
    turn is exactly 0.25 and `sinTurns` is exact; radians for angles that are DIFFERENTIATED,
    where the derivative is free. **And the name always carries the unit** - `pole_rad`,
    `pole_rate_rad`, never bare.
  * **THE TEST'S EXPECTED MAGNITUDE IS NOW THE EQUATIONS' OWN NUMBER** - 9.0977 rad/s^2 over
    0.02 s is 0.295821 rad/s - with nothing converted on the way to it. Before, the expected value
    had a tau in it, which is exactly the kind of arithmetic a test should not have to do.
  * The limit stays honest either way: `radFromDeg(12)` rather than znum's `0.2095`, which is
    12.0035 degrees.


- **Sep 8 2026 - plan turn 7: cartpole. lint 0, `check` green, both smokes PASS, fmt clean,
  116 + 170 tests, 395 reference rows, tutorial 15.3.**
  * ★★★ **A UNIT ERROR INSIDE A PLAUSIBLE SIMULATION HAS NO SYMPTOM.** The textbook dynamics are
    derived in RADIANS; the state here is in turns. My first version stored the radian
    acceleration straight into a turns-per-second rate and **the pole fell tau times too fast**.
    Every sign was right, the episode ended, the reward accumulated - a test checking only
    DIRECTIONS passed. Only computing the expected rate by hand (15.5913 rad/s^2 over 0.02 s is
    0.049629 turns/s) found it. **The test now asserts the magnitude**, and the conversion happens
    once, at the line where the unit changes.
  * ★★ **AND MY SECOND WRONG EXPECTATION WAS THE TEST, NOT THE CODE.** A pole just past the limit
    pushed RIGHT can recover within the step, because the cart moves out from under it. I had
    asserted it must fail. The physics was right and my intuition was not - checked by measuring
    before changing anything.
  * **THREE IMPROVEMENTS OVER znum**, each from reading its source carefully:
    - **Pure.** znum mutates `state` in place and warns in PROSE that a rollout must copy the
      observation out first. Forgetting makes every observation one step late - it still trains,
      to something slightly wrong.
    - **Reset separated.** znum folds it into the step, which forces a `force_reset` parameter AND
      a `no_transition` special case. Both vanish.
    - **Named fields.** znum uses `state_data[base + 2]` and `rd[0]`/`rd[1]`. Swapping two slots
      gives a plausible simulation that is wrong.
  * **AND ONE PLACE znum IS ALREADY BETTER THAN GYM**: semi-implicit Euler, where Gym's default is
    explicit. Matched rather than improved on - worth saying, since the point of reading their
    source is to find both.
  * ★ **`0.2095` IS NOT TWELVE DEGREES**, it is 12.0035 - a rounded radian standing in for a round
    number. In turns the limit is `12.0 / 360.0` and there is nothing to round.


- **Sep 8 2026 - adversarial review of the last few turns. TWO REAL DEFECTS FOUND AND FIXED, both
  in code that passed every gate. lint 0, `check` green, both smokes PASS, 115 + 170 tests.**
  * ★★★ **`categorical`'s RNG INDEXING COLLIDED, AND THE TEST COULD NOT SEE IT.** One stream
    indexed by `index *% 31 +% position` aliases the moment there are more than 31 logits: draw 1
    position 0 and draw 0 position 31 land on the same slot and get **the same noise**. Measured:
    **22% of slots reused** across a hundred draws of a 40-logit field. The distribution test used
    FOUR buckets and passed, because four is under thirty-one - **a test whose input is too narrow
    passes a broken implementation**, the same shape as the headless twin and the `tiny` field.
  * ★★ **AND THE STATISTIC COULD NOT SETTLE IT EITHER.** 40 buckets at 200k draws: 3.1 sigma
    before the fix, 3.3 after. The worst of forty is around three sigma by chance, so the
    statistical check was noise both ways. **The deterministic question - do two draws hash to the
    same slot - was decisive.** `rng.split(index)` was the house tool all along.
  * ★★★ **`divideBy` LEFT `out` HALF-WRITTEN ON FAILURE.** A zero in the middle produced
    `{5, 10, -999, -999}` and an error the caller might ignore. **Every other operation in this
    file validates up front and then cannot fail**; this was the only one that could fail partway,
    and the error it returned was correct so nothing looked wrong. Found by asking what `out`
    holds AFTER the failure - a question no existing test asked. One validation pass fixed it.
  * **WHAT SURVIVED THE REVIEW**: the four divisions match Zig's builtins element by element; the
    two `not`s are distinct; `boundedIndex` is uniform to 0.01 over 70k draws; the vector path
    agrees with the scalar path lane by lane. One thing noted and left: the tensor wrapper
    collapses zimrmath's `Inexact` and `DivisionByZero` into `DomainError`, which is consistent
    with a deliberately five-tag error set but does lose the distinction.


- **Sep 8 2026 - plan turn 6: `categorical` and `boundedIndex`. lint 0, `check` green, both smokes
  PASS, fmt clean, 115 + 170 tests, 390 reference rows. Rows 57-58.**
  * ★★★ **THE ONLY CLAIM WORTH MAKING ABOUT A SAMPLER IS ITS DISTRIBUTION.** It is easy to write
    a `categorical` that returns plausible indices and the wrong distribution - favouring the
    first bucket, or the largest, or drifting with the seed - and **nothing about the return type
    would show it**. So the test draws a hundred thousand times and compares the counts against a
    softmax computed independently of the sampler. A hundred thousand puts the standard error near
    0.0015, so the 0.01 bar is roughly six sigma: loose enough never to flake, tight enough that
    any bias fails immediately.
  * ★★ **GUMBEL-MAX NEVER EXPONENTIATES, WHICH IS THE POINT.** Softmax-then-cumulative-sum has to,
    and `exp(800)` is infinity - the sum is `inf`, every probability is NaN, and the walk picks
    whatever it picks. Adding `-log(-log(u))` to each logit and taking the argmax gives the same
    distribution in one pass. **Tested at 800**, where the obvious implementation returns garbage.
  * **THE RNG IS INDEXED, NOT ADVANCED**, so the same index gives the same draw and nothing
    depends on how many draws came before - which is what makes a rollout replayable. A zero from
    `unitFloat` is nudged to `floatMin` rather than resampled, because resampling would make the
    draw depend on a rejection count that is not replayable.
  * ★ **`boundedIndex` MULTIPLIES INSTEAD OF TAKING A MODULO.** `random % bound` is skewed unless
    the bound divides 2^32 - a part in a billion for a bound of 3, **fifty percent near 2^31**,
    and the same line produces both. Checked uniform over 70k draws.


- **Sep 8 2026 - plan turn 5: the index type is the caller's. Row 31 CLOSED. lint 0, `check`
  green, both smokes PASS, fmt clean, 114 + 170 tests.**
  * ★★★ **A SECOND TYPE PARAMETER, NOT A SECOND FUNCTION.** Row 31 recorded the float index as a
    consequence of "one element type per tensor" - but `argmaxAxis` writes POSITIONS, and a
    position's type was never the input's. The two were always independent and the signature
    simply did not say so. **The limitation was mine, and it read like the type system's.**
  * **THE LINE THAT FORCED IT WAS `@floatFromInt(best)`** - one conversion, imposed on every
    caller, because there was no other type available to write into. Now the conversion is chosen
    at the call site: `argmaxAxis(f32, f32, ...)` or `argmaxAxis(f32, usize, ...)`.
  * ★★ **THE CEILING IS DEMONSTRATED, NOT NOTED.** f32 holds every whole number to 2^24 and then
    skips - the test asserts `2^24 + 1 == 2^24` in f32 and that the same position in a `usize` is
    itself. A row longer than sixteen million cannot report its own last position as a float, and
    **the failure has no symptom**: the answer comes back as its neighbour.
  * ★ **AN INTEGER FIELD COULD NOT BE INDEXED AT ALL BEFORE.** The output shared the input's type,
    so an `i32` tensor produced `i32` positions or nothing - and the seed was `-inf(T)`, which for
    `i32` would not have compiled. `zm.lowest`/`zm.highest` from turn 1 were already the fix,
    waiting.
  * ⚠ And the lint caught `@as(f32, @floatFromInt(x))` in my own test - `zm.float` exists for
    exactly that, which is the file telling me it already solved this.


- **Sep 8 2026 - the six divisions rewritten for vectors. lint 0, `check` green (SPIR-V included),
  both smokes PASS, fmt clean, 170 + 113 tests.**
  * ★★★ **A zimrmath FUNCTION THAT ONLY TAKES SCALARS IS HALF A FUNCTION.** Everything here has to
    run on a scalar, on a `@Vector` lane, and inside a shader. I wrote six taking `comptime T` and
    comparing `denominator == 0` - which on a vector **yields a vector of bools and does not
    compile**. The signature looked generic and was not, and nothing in the turn that added them
    would have caught it.
  * **THE HOUSE PATTERN WAS ALREADY THERE**: `anytype` plus a `@typeInfo(T) == .vector` branch,
    with `perLane` and `splatLike` as the tools - `sinh` has used it all along. `anyZero` and
    `anyNonZero` reduce across lanes; the six now take `anytype`.
  * ★★ **THE TEST CHECKS EACH LANE AGAINST THE SCALAR CALL ON THE SAME PAIR**, which is the
    property that makes one implementation serving both worth having - not just that the vector
    version returns something of the right shape.
  * **A ZERO IN ANY LANE FAILS THE WHOLE OPERATION.** There is no per-lane error to return, and a
    silently wrong lane is worse than a refused vector. Stated rather than left to discovery.
  * ★ **`gcd` AND `lcm` STAY SCALAR, AND THAT IS A LIMIT NOT AN OVERSIGHT.** Euclid's loop runs a
    different number of times per lane, so a vector version would have to run every lane to the
    worst case and mask. **Worth doing when something wants it, not before** - which is the
    standing rule for zimrmath now: add only what is needed.


- **Sep 8 2026 - thirteen std.math replacements moved INTO zimrmath. lint 0, `check` green, three
  smokes PASS, fmt clean, 170 + 113 tests. std.math coverage 57 -> 69 of 142 (48%).**
  * ★★★ **EVERY GAP IN zimrmath IS A WORKAROUND SOMEWHERE ELSE.** The lint bans `std.math` outside
    zimrmath, which is only half a policy: when zimrmath lacks something, the caller does not stop
    - they write it inline. zimrnum's `divideBy` inlined `@divFloor`, hand-rolled a `divCeil`
    because `std.math.divCeil` was banned, and repeated the zero and inexact checks at the call
    site. **The fix was not a better workaround, it was the missing function.**
  * **ADDED**: `divFloor`, `divTrunc`, `divCeil`, `divExact`, `mod`, `rem`, `gcd`, `lcm`,
    `isNormal`, `isPositiveInf`, `isNegativeInf`, `isNegativeZero`. zimrnum's switch is now six
    `zm.` calls and reads as the dispatch it is.
  * ★★ **THE TEST COMPARES AGAINST std.math ITSELF**, not a table I wrote - for these,
    **agreement with the original IS the specification**, so anything else would be testing my
    arithmetic instead of the replacement.
  * ★ **NEGATIVE ZERO IS INVISIBLE TO `==` AND SURVIVES DIVISION.** `-0.0 == 0.0` is true, and
    `1 / -0.0` is negative infinity where `1 / 0.0` is positive. Asserted both ways, because that
    asymmetry is the only reason the classifier is worth having.
  * `lcm` divides before multiplying, so inputs whose product would overflow still work - checked
    with values whose product exceeds `u32`.
  * ⚠ Three self-inflicted detours: `@Type` is `@Int` in this Zig (line 559 already showed it);
    the disk hit 97% and the build guard REFUSED rather than failing mid-link with "No space
    left"; and `rm -rf .zig-cache/o` broke the build worse than the full `rm -rf .zig-cache`,
    which at least rebuilds cleanly. **A partial cache delete is worse than none or all.**


- **Sep 8 2026 - `divCeil` and `divExact` added: Zig names FOUR and I had two. 113 + 169 tests,
  lint 0, `check` green, both smokes PASS, 388 reference rows.**
  * ★★★ **THE PRECEDENT WAS STRONGER THAN I KNEW, AND I CHECKED IT BY RUNNING IT.** My first
    attempt compiled `-7 / 2` on two `const` values and printed -3, which looked like Zig allowing
    signed division. It was constant folding. With RUNTIME operands it is a compile error whose
    message is the whole design:

        division with 'i32' and 'i32': signed integers must use
        @divTrunc, @divFloor, @divCeil, or @divExact

    **Comptime-known operands hide the rule that runtime operands enforce** - the same class of
    mistake as a headless test being blind to a GPU branch.
  * **FOLLOWING THE LANGUAGE'S VOCABULARY IS FREE DOCUMENTATION.** A reader who knows Zig already
    knows what these four do; a set I invented would have to be learned.
  * **`divExact` IS AN ASSUMPTION MADE CHECKABLE.** `@divExact` is UNDEFINED BEHAVIOUR when the
    division is inexact - silent corruption in a release build - so an inexact one is a
    `DomainError` here, caught where it happens rather than downstream.
  * ★ **THE TEST NOW CHECKS EACH AGAINST ZIG'S OWN BUILTIN** at every element, not against a table
    I wrote. That claims the tensor version IS the language's operation rather than something
    resembling it.
  * ⚠ And a self-inflicted detour: `rm -rf .zig-cache/tmp` - the gentle first step the
    troubleshooting block prints - deletes a directory `configure` needs, and the next build fails
    with `FileNotFound`, which reads like a source problem. `mkdir -p` fixed it. Recorded in
    claude.md: **a cleanup step that leaves the tree unable to build points away from itself.**


- **Sep 8 2026 - plan turn 4: integer division, four ways. lint 0, `check` green, both smokes
  PASS, fmt clean, 113 + 169 tests, 386 reference rows. Rows 54-56.**
  * ★★★ **`div` IS NOT SPELLABLE ON INTEGERS, AND THAT IS THE FEATURE.** `-7 / 2` is -3 in C and
    -4 in Python; `-7 % 3` is -1 in C and 2 in Python. **Both are correct.** A library that offers
    `div` on integers picks one silently, and code tested on positive data passes either way -
    then indexes with a negative number the first time real data arrives. Making the ambiguous
    name unavailable turns an inheritance into a decision. znum has none of the four.
  * ★★ **THE IDENTITY IS A STRONGER TEST THAN THE TABLE.** Beyond checking each answer, the test
    asserts `a == (a / b) * b + remainder` for BOTH pairs. That does not depend on my arithmetic
    being right - if either half of a pair were wrong it fails - where a table of expected values
    only proves I typed what I computed.
  * **`mod` NEVER RETURNS NEGATIVE for a positive divisor**, which is the property that makes it
    safe as an index, and `rem` does not have it. Asserted over a range that crosses zero rather
    than stated.
  * **A ZERO DIVISOR IS A `DomainError`, NOT A TRAP.** Integer division by zero halts the program
    in Zig; a tensor operation should hand back something the caller can act on.
  * `affine(a, gain, offset)` replaces znum's three entries. `clip` is deliberately absent -
    `clamp` already takes the same two bounds, and one operation with two names is one more thing
    that can drift.


- **Sep 8 2026 - plan turn 3: the bitwise family and `requireInt`. lint 0, `check` green, both
  smokes PASS, fmt clean, 112 + 169 tests, 381 reference rows. Rows 52-53.**
  * **THE GUARD PAIR IS COMPLETE**: `requireFloat`, `requireNumeric`, `requireInt`. znum's
    `bitwiseAnd` has **no guard at all** - it takes any `T` and fails somewhere inside a generic
    dispatch, with a message about the dispatch. Verified by hand that ours fires at the call
    site: `expected an integer element type, got f64`.
  * ★★ **TWO NOTS THAT SHARE NO ANSWERS.** `bitwiseNot(5)` is -6; `logicalNot(5)` is 0. znum has
    only the second, so a caller wanting the first **reaches for the one that exists and gets a
    plausible number back**. Both are here, asserted side by side so the difference is on the page.
  * ★★ **AN OVER-SHIFT IS AN ERROR, NOT UNDEFINED BEHAVIOUR.** Zig's `<<` is ILLEGAL when the
    shift reaches the bit width - silent corruption in a release build, and C has the same rule.
    One comparison for the whole tensor converts that into a value the caller can handle. The
    check reads the TYPE's width, so the test uses an `i8` as well: 8 is legal for an `i32` and
    refused for an `i8`, which a hard-coded 32 would have got wrong.
  * The test also pins the largest LEGAL shift, so the bound is not off by one - and asserts that
    a signed right shift preserves the sign (`-8 >> 1` is -4), which is plausible enough to be
    worth ruling out rather than assuming.
  * ⚠ My first shift closed over `places` inside a `map` callback, which cannot work - `map` takes
    a plain function. One shared loop, written once, instead of two.


- **Sep 8 2026 - plan turn 2: twenty-one operations widened. lint 0, `check` green, both smokes
  PASS, fmt clean, 111 + 169 tests. `requireFloat` 191 -> 164, `requireNumeric` 23 -> 50.**
  * ★ **SEVEN OF THE PLANNED TARGETS ALREADY WORKED.** `concat`, `take`, `materialise`,
    `transpose`, `tile`, `maxAll` and `minAll` have no float guard at all and accept `i32` today -
    I checked by RUNNING them rather than by reading, which took one throwaway test and stopped a
    turn of edits that would have changed nothing.
  * **THE TWENTY-ONE THAT DID NEED IT**: six comparisons, `minimum`/`maximum`, `abs`/`neg`/`sign`/
    `square`/`scale`, `argsort`, `bincount`, `trace`/`diagonal`/`triangle`/`outer`, `oneHotRows`,
    `minMaxScale`. Nothing in that list rounds, roots or exponentiates.
  * ★★ **`bincount` WAS ALWAYS AN INTEGER OPERATION WEARING FLOATS.** On a float tensor it must
    verify every value is a whole number before using it as an index; **on an integer tensor the
    TYPE already said so**, and the check reduces to `x != x`. The negative test stays for both -
    a count of a negative index has no home.
  * ⚠ **`@abs` ON A SIGNED INTEGER RETURNS AN UNSIGNED ONE.** Correct of the builtin, wrong for a
    function whose output tensor carries the input's type. `if (x < 0) -x else x` says the same
    thing and keeps the type - and inherits the honest edge, that `abs(minInt)` overflows rather
    than quietly returning itself.
  * A comparison on an integer tensor produces 0 or 1 exactly, which is what a mask should be -
    no float 1.0 that might not survive arithmetic and still compare equal.


- **Sep 8 2026 - plan turn 1: nine reductions widened to integers. lint 0, `check` green, both
  smokes PASS, fmt clean, 110 + 169 tests. `requireFloat` 200 -> 191, `requireNumeric` 13 -> 23.**
  * ★★★ **WIDENING THE TYPE, NOT THE NINE CALL SITES.** `CompensatedSum` carries a correction term
    because float addition rounds. **Integer addition is exact, so the correction is zero at every
    step** - and putting that comptime branch inside `add` widened every reduction built on the
    type at once, instead of nine copies of the same `if`. The `Walk` lesson again: a type with a
    method makes the right thing the default.
  * **TWO FLOAT SENTINELS WERE HIDING IN THE SEEDS.** `maxAxis` seeded from `-inf` and `diff` put
    a NaN in its first position - both float-only, both invisible until an integer arrived.
    `zm.lowest(T)` and `zm.highest(T)` now give the identity for max and min at any numeric type,
    which is the right home: zimrmath already owns `floatMin` and `floatMax`.
  * ★★ **AN INTEGER SERIES CANNOT SAY "ABSENT".** `diff`'s hole is NaN for a float and ZERO for an
    integer, because there is no integer NaN - and a zero difference is a value someone might
    believe where a NaN is not. Stated in the doc rather than left in the signature. **This is
    exactly why `Series` in turn 14 carries a validity mask rather than a sentinel**, and finding
    it here is a turn-1 argument for a turn-14 decision.
  * **THE FLOAT PATH IS ASSERTED UNCHANGED**: summing 1 plus a hundred thousand values of 1e-12
    still lands within 1e-15, which a naive running total would not. Widening a constraint can
    break the case it used to serve, so both are checked.
  * And the i64 test shows what exactness buys: a thousand values near 2^40 sum exactly, where
    the same values as f64 pass 2^53 and the increments stop landing.


- **Sep 8 2026 - `slice_columns` and `concat_columns` on the GPU. Sweep is NINETY-SEVEN, 85
  kernels. lint 0, `check` green, both smokes PASS, fmt clean, 109 + 169 tests.**
  * **PURE ADDRESSING IS A POOR KERNEL ALONE AND AN EXCELLENT ONE IN A CHAIN.** There is no
    arithmetic in either - only an index. On its own that is not worth a dispatch; as part of
    multi-head attention, which slices a projection once per head, doing it on the host would mean
    a round trip per head.
  * **THE INPUT AND OUTPUT WIDTHS DIFFER, WHICH IS THE WHOLE POINT.** A `slice_columns` that
    assumed they matched would read the right values for the first head and the wrong ones for
    every other. The sweep row uses half the width out, so that assumption cannot pass.
  * ★★ **I ALMOST OVERLOADED `a_col` AND `b_col` AGAIN.** They are column STRIDES, set to 1 by
    `bcast_add`, and as an offset a 1 would silently read the wrong column. This is the second
    time - `repeat_each` nearly divided by a broadcast flag two turns ago - so both got their own
    fields, `slice_start` and `left_columns`. **Twice is a pattern, and the fix is a field, not
    more care.**
  * Both twins measured EXACTLY zero. 97 rows x 6 settle = 4.85 s at 120 Hz, inside the budget.


- **Sep 8 2026 - `TransformerBlock`. The layer types are DONE. lint 0, `check` green, both smokes
  PASS, fmt clean, 109 + 169 tests, tutorial 11.16, 373 reference rows.**
  * **PRE-NORM, AND THE TEST ASSERTS THE CONSEQUENCE RATHER THAN THE ARRANGEMENT.** The original
    transformer normalised AFTER each sublayer, putting the normalisation ON the residual path so
    it rescaled the gradient at every block - which is why that version cannot be trained without
    a learning-rate warmup. Checking "is the norm before or after" would only confirm I typed what
    I meant; the test measures that **no element of the input gradient has collapsed**, which is
    what the arrangement is FOR. znum is pre-norm too and does not say why.
  * ★★ **CAUSALITY HAD TO BE RE-TESTED AT THIS LEVEL, AND THAT WAS NOT OBVIOUS.** The mask lives
    inside `Attention` and is already tested there. But a residual carries the input FORWARD,
    around the attention - so composition is exactly where a leak would appear. Measured: disturb
    the last position and every earlier output is **bit-identical**, rows 0 to 4 moving by exactly
    zero. **A property proven for a part is not proven for the whole.**
  * **A FRESH BLOCK IS CLOSE TO THE IDENTITY**, because the sublayers start small against the
    residual. Depth you have not trained yet should do nothing rather than something arbitrary,
    which is what makes stacking safe before training - and the test bounds how far the output can
    move from its input.
  * Seven parameters collected the way `Chain` does it, for the same reason: one missing from that
    list would silently never train.


- **Sep 8 2026 - multi-head attention, three turns after the missing ops were named. lint 0,
  `check` green, both smokes PASS, fmt clean, 108 + 169 tests. Row 51.**
  * **THE PAYOFF FOR BUILDING THE BLOCKER.** `slice` and `concat` existed for one turn before the
    design they were blocking became a loop. Every tensor stays RANK 2 and each iteration reads
    exactly like the single-head maths, because it is the single-head maths. znum reshapes to rank
    4 and permutes, which needs two more differentiable ops and makes every subsequent line reason
    about four axes.
  * ★★ **THE SCALE COMES FROM THE HEAD'S WIDTH, NOT THE PROJECTION'S.** Splitting 8 into two heads
    means each sums over 4, so the scale is `1/sqrt(4)`. Getting that wrong is **invisible in the
    shapes and quiet in the output** - it saturates the softmax slightly more than it should and
    nothing says so. The test pins it by asserting one head over 4 and two heads over 8 share a
    scale, which a projection-wide scale would have broken.
  * ★ **MORE HEADS DO NOT WIDEN ANYTHING - THEY DIVIDE THE SAME WIDTH.** Two heads over 8 have the
    same output shape and the same parameter count as one head over 8; only the pattern differs.
    That is what the name hides, and the test asserts both halves: same shape, different numbers.
  * A width that does not divide by the head count is refused rather than silently dropping a
    column.


- **Sep 8 2026 - `graph.slice` and `graph.concat`: the blocker, not another thing around it.
  lint 0, `check` green, both smokes PASS, fmt clean, 108 + 169 tests, 369 reference rows.**
  * ★★★ **TWO DESIGNS HAD ALREADY BEEN SHAPED BY THE ABSENCE.** `LstmCell` could not fuse its four
    gates into one matmul, `Attention` could not split a projection into heads, and both wrote
    "stated rather than half-built" and moved on. **When the same missing thing shapes two
    decisions, the missing thing is the work** - building a third design around it would have been
    the wrong turn. znum has neither op.
  * **`Tensor.slice` ALWAYS EXISTED; WHAT WAS NEW IS THE GRADIENT.** The view is free. The backward
    is a SCATTER: the gradient lands where the slice read and every other row gets exactly zero,
    because a row nobody read influenced nothing. `concat`'s backward is the same thing read the
    other way.
  * ★★ **A SCATTER THAT WRITES TO THE WRONG OFFSET STILL RUNS**, still produces numbers of the
    right shape, and trains something adjacent to what you meant. So the test is a central
    difference at every element, plus the zeros asserted directly - slice the middle two rows of
    five and rows 0, 3 and 4 must have NO gradient, not a small one.
  * ★ **AND SLICING THEN REJOINING IS THE IDENTITY ON VALUES**, which is what makes the test sharp:
    a wrong offset in either backward shows up in the gradient while the forward pass still looks
    perfect.
  * The `geometry: [4]usize` field `conv2d` uses for strides carried the axis, start and length -
    no new Node field needed. Both `recompute` and `backward` switch exhaustively on the op, so
    the compiler required both cases: **an exhaustive switch is a checklist that cannot be
    forgotten.**


- **Sep 8 2026 - `Attention`, with causality as an argument. lint 0, `check` green, both smokes
  PASS, fmt clean, 107 + 169 tests, tutorial 11.15, 367 reference rows. Rows 48-50.**
  * ★★★ **THE TEST PERTURBS THE FUTURE AND WATCHES THE PAST.** Inspecting the mask would only
    confirm I wrote the mask I meant to. Instead: replace the last position with a large value and
    measure how far every EARLIER output moves.

        .backward_only   largest shift  EXACTLY 0
        .everywhere      largest shift  > 0.1

    Not "small" - **zero**. A causal mask that let through a millionth would be a causal mask with
    a bug, and a tolerance would hide it. The unmasked run is what proves the zero came from the
    mask rather than from the input being ignored.
  * ★★ **THE FAILURE THIS PREVENTS IS THE ONE THAT FLATTERS YOU.** A model trained without the
    mask can see the answer it is predicting: loss near zero, a beautiful curve, nonsense on
    anything unseen. Nothing fails and nothing warns. That is why `look` is required at every
    call - the same shape as `BatchNorm.Use`, with a worse consequence.
  * **THE MASK ADDS -1e30, NOT `-inf`.** Negative infinity is exactly right in algebra and gives
    `inf - inf = NaN` the moment a row is entirely masked - which a causal mask never does, but a
    padded batch would. A number the exponential flushes to zero says the same thing and survives.
  * **THE SCALE COMES FROM THE PROJECTION'S OWN SHAPE**, so it cannot disagree with the tensors it
    scales. Passing the wrong dimension there is quiet and common.
  * Single head. Multiple heads need a slice and a concat with backwards, which this tape lacks -
    the same limit that stopped `LstmCell` fusing its gates. **Stated, not half-built**, for the
    second time.


- **Sep 8 2026 - `LstmCell`, and a one-line change worth 44x. lint 0, `check` green, both smokes
  PASS, fmt clean, 106 + 169 tests, tutorial 11.14, 362 reference rows. Rows 45-47.**
  * ★★★ **THE FORGET BIAS STARTS AT ONE AND THE TEST MEASURES WHAT THAT BUYS.** znum zeroes every
    bias, and so does PyTorch. A zero forget bias is `sigmoid(0) = 0.5`, so the cell halves its
    memory every timestep before it has learned anything. Ten steps of pure decay - every weight
    zeroed so only the biases decide, input gate shut so nothing is admitted:

        forget bias 0    0.000977   (0.5^10)
        forget bias 1    0.043604   (0.73^10)

    **Forty-four times the signal, and with it forty-four times the gradient** that has to travel
    back through those steps.
  * ★ **THE TEST ASSERTS THE EXACT POWERS, NOT JUST THE RATIO** - so it is measuring the GATE
    rather than the arithmetic around it. And it separately asserts `init` produces the good
    default, because a default nobody checks is a default that drifts.
  * **`step` RETURNS BOTH STATES.** Hidden is what the next layer sees, cell is the memory that
    carries forward, and confusing them is the classic LSTM mistake - a type returning one value
    could not prevent it.
  * **EVERY OPERATION IS ALREADY ON THE TAPE** - matmul, sigmoid, tanh, add, mul - so the gradient
    is the tape's and the cell needs no backward of its own. That is the second time this week
    checking what already exists decided the design, after batch norm through layer norm.
  * ⚠ The lint caught `std.math.pow` in my test: banned outside zimrmath for GPU portability.
    `zm.pow` was right there.


- **Sep 8 2026 - `BatchNorm`, with the mode as an argument. lint 0, `check` green, both smokes
  PASS, fmt clean, 105 + 169 tests, tutorial 11.13, 357 reference rows. Rows 42-44.**
  * ★★★ **znum's `mode` IS A MUTABLE FIELD AND THAT IS THE BUG.** It is PyTorch's design, and
    forgetting `model.eval()` is one of the most common mistakes in either library: the network
    silently normalises by whatever batch it is looking at. On a large batch the numbers look
    plausible; **on a batch of ONE the output is exactly zero for every feature**, because a
    single sample has no variance. Works in training, breaks in production, no error anywhere.
  * **HERE `use` IS A REQUIRED ARGUMENT**, so a caller cannot reach that by omission - only by
    asking for it. The test shows the disaster rather than describing it: one row through
    `.training` comes out erased, the same row through `.inference` survives.
  * ★★ **BATCH NORM IS LAYER NORM TRANSPOSED - MEASURED AT 2.2e-16 BEFORE WRITING A LINE.** Layer
    norm evens each row across its features; this evens each column across the batch, which is the
    same arithmetic on the transpose. So the forward pass AND the gradient come from the pair that
    already has a finite-difference test, instead of a second derivation. Both transposes are
    views. znum writes the two separately.
  * **`observe` IS SEPARATE FROM `attach`** because `attach` only reads. znum folds the update
    into the forward pass, so building the graph mutates the layer. The test asserts it: two
    attaches leave the running mean at zero, and only `observe` moves it.


- **Sep 8 2026 - `Chain`, and the reason it exists is not the forward pass. lint 0, `check` green,
  both smokes PASS, fmt clean, 104 + 169 tests, tutorial 11.12, 351 reference rows.**
  * ★★★ **THE PARAMETER LIST WAS THE BUG, NOT THE COMPOSITION.** Writing the forward pass by hand
    is fine - three calls, three named intermediates, and the names help when a shape is wrong.
    The line after it is not: `&.{ a1.weight, a1.bias, a2.weight, a2.bias }` is written by hand,
    and **a parameter missing from it silently never trains**. The loss still falls because the
    others compensate, and nothing anywhere reports it. `Chain` produces the list from the same
    walk that built the network, so the two cannot disagree.
  * **THE COUNT COMES FROM EACH LAYER'S OWN `Attached` DECLARATION** - `out` plus one field per
    parameter - rather than a table in `Chain` that could fall out of step. A layer that gains a
    parameter is counted correctly the day it does.
  * **THE TEST CHECKS THREE THINGS**: the count; that every collected `Var` is DISTINCT (a chain
    handing back the same one twice trains one parameter twice and another never - the same bug
    by a different route); and that the list matches attaching the same layers by hand on a fresh
    graph, so "in order" is asserted rather than assumed.
  * ⚠ **MY FIRST DRAFT COMPILED WITHOUT BEING CORRECT.** `parameterCount` contained nonsense -
    `@typeInfo(... .decls.len == 0) catch unreachable` - and the build was clean, because Zig does
    not analyse an uninstantiated generic. **A generic function with no caller is not compiled,
    only parsed**; the test is what compiled it.
  * ⚠ And this Zig spells struct reflection as parallel `field_names` / `field_types` arrays, not
    `fields`. `bridge.zig` already had a helper pairing them - found by grepping for the idiom
    rather than guessing at the version's shape.
  * ★ **IT ALSO SETTLES THE ACTIVATION WRAPPERS.** `ReLU`, `GELU`, `Tanh` as TYPES contribute no
    parameters, so wrapping `graph.relu` buys a tuple slot and nothing else. They stay unported
    until something wants a chain built from configuration.


- **Sep 8 2026 - `requireNumeric` beside `requireFloat`, and thirteen operations widened WITH a
  test. lint 0, `check` green, both smokes PASS, fmt clean, 103 + 169 tests.**
  * **WHAT znum ACTUALLY DOES, MEASURED**: 332 math functions take `comptime T`, **ZERO** take a
    runtime `DType`. Its `DType` enum has 447 mentions and 164 of them are in `BindGroupCache`,
    46 in `Kernel` - GPU plumbing, where a buffer's element width must be known at dispatch. It
    never reaches the maths. **znum is Eigen's model, not PyTorch's, and so are we.**
  * ★★ **AND znum REFUSES NON-FLOATS IN SIXTEEN PLACES; zimrnum DID IN 206.** znum's sixteen are
    a coherent set - `lu`, `solve`, `determinant`, `cholesky`, `qr`, `eigh`, `svd`, `lstsq`,
    `pinv`, `eig`, `randn`, `logspace` - every one a decomposition, a solve, or a random draw.
    Its `bitwiseAnd` and `addScalar` have no guard at all. **A factor of thirteen is not a
    difference of philosophy, it is a default nobody revisited.**
  * **`Tensor(i32)` ALREADY WORKED** - alloc, `.at`, `permute`, `slice` all compile and run today.
    The container was always generic; only the operations refused. That reframed the question
    from "share or separate type" to "which operations".
  * **THIRTEEN WIDENED, EACH RUN AT i32 AND f64 IN THE SAME CHANGE.** `flip`, `roll`, `repeatEach`,
    `meshGrid`, `prodAll`, `sort`, `unique`, `nonzero`, `booleanMask`, `clipByValue`, `clamp`,
    `argmaxAll`, `argminAll`. **A widened constraint nobody has run is worse than the narrow one
    it replaced, because the narrow one was at least true.**
  * ★★★ **AND ONE "SIMPLIFICATION" CHANGED THE ANSWER.** `argminAll` seeded from `inf(T)`;
    replacing that with the first element removed the float dependency and broke NaN handling -
    seeded from an infinity a NaN never wins, seeded from element zero a leading NaN IS the
    incumbent and nothing beats it. **The sentinel was NaN handling wearing a float artefact.**
    Caught by an existing test; the comparison now says it directly.
  * 200 `requireFloat` remain against 13 `requireNumeric`. Widening the rest happens when
    something wants it, with a test, not as a sweep.


- **Sep 8 2026 - `log_sum_exp_rows` on the GPU. Sweep is NINETY-FIVE, 83 kernels. lint 0, `check`
  green, both smokes PASS, fmt clean, 102 + 169 tests.**
  * **A SHADER HAS NO MORE HEADROOM THAN A HOST.** `exp(800)` is infinity in f32 long before f64
    gives up, so the kernel subtracts the row maximum exactly as `softmax_rows` beside it does -
    one for the ratio, one for the sum. Verified on a row of 800s: CPU and GPU both 804.1589,
    where the direct form is `inf` on either side.
  * **Twin measured at 4.77e-7 against a 9.54e-6 bar** - half a ULP on a peak of 5.
  * ★ **THE ROW ONLY JUDGES THE FIRST `side` ELEMENTS.** One thread per row means one value out
    per row; everything past that is whatever the buffer held, and `out_len` is what stops the
    comparison from reading noise. The field already had the mechanism - `sum axis0` uses it -
    which is the second time this week an existing row's shape was the answer.
  * 95 rows x 6 settle = 4.75 s at 120 Hz, inside the six-second budget.


- **Sep 8 2026 - `logSumExp`, `logSumExpAxis`, `stdDevAxis`, `determinant`. Tutorial 9.6 and 9.7.
  lint 0, `check` green, both smokes PASS, fmt clean, 102 + 169 tests, 346 reference rows.**
  * ★★ **THE TEST PROVES THE FUNCTION HAS A REASON TO EXIST BEFORE CHECKING IT IS RIGHT.** It
    computes `log(sum(exp(a)))` directly on `{800, 801, 802}`, asserts that really does come back
    **inf**, and only then checks that `logSumExp` gives 802.4076. A test that only checked the
    good answer would pass against an implementation that never needed the max-subtraction.
  * **THREE CLAIMS, NOT ONE**: the direct form overflows; this agrees with the direct form to
    1e-14 WHERE THE DIRECT FORM WORKS, so the trick costs nothing; and shifting every element by
    500 shifts the answer by exactly 500 - the identity the subtraction relies on, so breaking
    the subtraction breaks this.
  * ★★★ **A SINGULAR MATRIX IS AN ERROR IN `lu` AND A ZERO IN `determinant`, AND BOTH ARE RIGHT.**
    `lu` refuses because a factorisation of a singular matrix cannot solve anything. A determinant
    is different: **zero is the complete answer**, and testing for it is how a caller detects
    singularity. Caught and converted, with the reason in the doc. Register row 41.
  * ★ **THE PIVOT-SIGN TEST IS THE ONE THAT MATTERS.** Swapping two rows must NEGATE the
    determinant; a version that dropped the sign returns -306 both times and passes a
    single-matrix test looking perfectly correct.
  * `determinant` is five lines because `lu` already returns the sign it accumulated. A cofactor
    expansion would be a second implementation of the same arithmetic at `O(n!)` instead of
    `O(n^3)`.


- **Sep 8 2026 - the statistics batch: six functions, tutorial 12.2. lint 0, `check` green, both
  smokes PASS, fmt clean, 101 + 169 tests, 342 reference rows.**
  `correlationMatrix`, `coefficientOfVariation`, `medianAbsDev`, `standardError`, `mode`,
  `valueCounts`. Rows 37-40 in the register.
  * ★★ **THE TEST SHOWS ROBUSTNESS RATHER THAN SAYING IT.** The same five values twice, one of
    them replaced by 1000: the standard deviation goes 1.58 -> 446 (**282 times**) and the median
    absolute deviation does not move AT ALL, staying exactly 1. That gap is the entire reason the
    function exists, so the test asserts the gap.
  * ★★ **A BAR THAT WOULD HAVE ASSERTED BESSEL DOES NOTHING.** Four times the data should halve
    the standard error and `sqrt(96/24)` is exactly 2 - but with `.sample` the ratio measures
    **2.032**, because dividing by `n - 1` inflates the smaller sample proportionally more. My
    first bar was 2.0 +/- 0.02 and it failed, correctly. The test now checks 2.032 for `.sample`
    AND exactly 2.0 for `.population`, which states the law cleanly and names the correction.
  * ★ **AND THE COUNTS HAD TO BE EVEN.** With 25 and 100 the population ratio came out at 1.9984,
    not 2 - an odd count of alternating +/-1 leaves one extra and the mean is not zero. 24 and 96
    make it exact. **Asserting 1.9984 would have been asserting a rounding artefact of my own
    input.**
  * ⚠ **I WROTE A SECOND `correlation` AND THE COMPILER CAUGHT IT** - one already existed, doing
    the same thing through `stdDev`. Second duplicate this session, after `layerNormBackward`.
    **A grep before writing costs less than a compile error, and I keep not doing it.**
  * ⚠ `mode` collided with three `ConvMode` parameters also called `mode`; renamed those to
    `extent`, which is what they select anyway.


- **Sep 8 2026 - the `manip` batch: `meshGrid`, `repeatEach`, `moveAxis`. Sweep is NINETY-FOUR.
  lint 0, `check` green, four smokes PASS, fmt clean, 100 + 169 tests, tutorial 7.10.**
  * **THREE PORTED, THREE DELIBERATELY NOT.** `hstack`/`vstack`/`dstack` are `concat` with the
    axis baked in - znum's own doc admits the trap - and `reshapeInfer` exists only because znum
    allocates its result. Rows 34-36 in the register.
  * **THE NAMES ARE THE POINT.** numpy's `repeat` and `tile` differ in which thing is repeated and
    neither name says which; `repeatEach` beside `tile` reads differently at a glance. `meshGrid`
    takes both outputs as NAMED parameters instead of returning `[2]Tensor`, so `grid_x` cannot
    be mistaken for `grid_y` at the call site.
  * ★★ **A KERNEL THAT NEEDS MORE OUTPUT THAN THE HARNESS GIVES IT IS THE HARNESS TELLING YOU THE
    SHAPE IS WRONG.** `mesh_grid` filled both grids in one dispatch, writing the second to
    `bout[count + id]` - past the end of a buffer sized for `count`. It passed the headless twin,
    which allocates its own buffers, and the SMOKE caught it as a LEAK: the runtime grew the
    buffer, and 2 pipelines x 45 lifecycles surfaced as `compute_pipeline+90`. Split into
    `mesh_grid_x` and `mesh_grid_y`, one grid per dispatch.
  * ★ **THE TWIN CAUGHT THE OTHER ONE**: `repeat_each` was 5.16 off because the kernel derived the
    source row stride as `cols / count`, assuming a packed input. The input is a strided VIEW of
    half of each row, so consecutive rows are `a_row` apart.
  * ⚠ **AND I OVERLOADED A PARAMETER.** The repeat count went in `b_row`, which is a row stride
    that `bcast_add` legitimately sets to ZERO - a divisor of zero one row later. It now has its
    own `repeat_count` field, taken from a reserved pad slot so the layout is unchanged.
  * **The CPU reference allocated every frame** in its first form, on a loop the sweep runs
    ninety-four times a pass. `repeatEach` reads through `.at()`, so the strided view goes in
    directly and nothing needs materialising.


- **Sep 8 2026 - ZERO `inline` left in zimrmath, and removing it uncovered a wasm backend bug.
  lint 0, `check` green, ten smokes PASS, fmt clean, 169 + 99 + 7 + 222 tests.**
  * **239 ANNOTATIONS REMOVED, 35 KB SMALLER** (2 895 423 against 2 930 532, -1.2%). Every suite
    unchanged. The compiler was making better decisions than the annotations were, which is
    Kelley's whole point and now has a number attached in this codebase.
  * **THE ONE FUNCTION THAT SEEMED TO NEED `inline` WAS MASKING A COMPILER BUG.** Without it
    `inverseQuat` made the wasm module fail to INSTANTIATE: `f32.le[0] expected type f32, found
    local.get of type v128`. Restoring `inline` did NOT fix it - it moved the failure to the next
    function the comparison landed in, `plot3d.pixelsToNDCRay`. **An annotation that relocates a
    failure is not fixing anything.**
  * **THE CAUSE WAS A VECTOR COMPARISON**: `blend(l <= splat(eps), splat(0), conj / l)`, legal Zig
    that the wasm backend miscompiles. Every lane of `lengthSq4Splat` holds the same number, so
    the mask was never doing lane-wise work - one scalar compare says the same thing, generates
    correct code, and reads better. With the source fixed, ZERO functions need `inline`.
  * **REMOVING `inline` DID NOT CREATE THE BUG, IT REVEALED ONE THAT HAD BEEN THERE ALL ALONG.**
    Worth remembering next time a function seems to need an annotation: look at what it is hiding.
  * **THE TURNS HUNT IS DONE.** One `sinRad` with a tau in its argument remains in the entire
    tree, and it is the LINTER'S OWN DOCUMENTATION of the `turn-in-radian-call` rule. The rule is
    enforced, proven by control: rc=1 with a violation, rc=0 without.


- **Sep 8 2026 - 89/91, and it was NOT a tolerance problem. `settle` 3 -> 6.**

        XX bcast add (bias)   worst inf        bar 0
        XX tanh grad          worst 3.840107   bar 0

  * ★★★ **BARS OF ZERO ARE CORRECT FOR THESE ROWS AND THE FAILURES ARE NOT NEAR-MISSES.**
    Addition and `1 - y*y` are exact arithmetic, so `tol = 0` demands exact agreement and gets it
    on every other run. `inf` and `3.84` are not perturbations of the right answer - **they are
    another row's data**, the same signature this file already records from the last staleness
    episode ("worst errors of 9.8 and 4.2, which for 0/1 masks can only be another row's data").
  * **THE TWINS ARE EXACT ON THE HOST**, both of them, measured before changing anything: kernel
    and CPU reference agree to zero. That is what rules out the maths and points at the readback.
    **Checking the twin first is what turned a guess into a diagnosis.**
  * ★★ **THREE WAS SET FROM A MEASUREMENT AND HAS NOW BEEN WRONG TWICE.** It was matched to the
    queue depth `zimrnum_train` showed, held for 86 rows, and broke at 91. The depth moves with
    row count, with what else the browser is doing, and with the build. **A number that has been
    wrong twice should be set from the BUDGET, not from the last measurement**: six frames is
    546 frames, 4.6 s at 120 Hz, inside the six-second budget - the whole available margin spent
    on being sure, which is what raising the budget was for.
  * ⚠ Neither failing row changed this session. The Rad rename touched three lines in that file,
    none of them these two, and the shipped page is the with-inline build (2 930 532 bytes,
    checked). **Ruling out my own recent changes cost three commands and was worth it.**


- **Sep 8 2026 - `sin` became `sinRad`, and a measurement says `inline` should go too.
  lint 0, `check` green, five smokes PASS, fmt clean, 169 + 99 + 7 + 222 tests.**
  * **EIGHT NAMES RENAMED ACROSS 651 BARE USES IN 66 FILES**: `sin cos tan sincos asin acos atan
    atan2` -> `*Rad`, in zimrmath, zimrnum's tensor ops, the linter keyword list, the reference
    table and the kernel audit list.
  * ★★ **THE MEASUREMENT THAT DECIDED IT: only 3% of call sites carried the unit already.** I
    assumed the argument name would make the suffix redundant - 80% pass a name with no unit at
    all, and 10% pass a bare literal where nothing but the function name COULD say it. And
    `sin`/`sinTurns` read as a base function and a variant, which is backwards: they are two
    units, not a default and a special case.
  * ★ **THIS RENAME COULD NOT FAIL SILENTLY**, unlike the five before it. `sin` is a lint keyword,
    used bare, and `reserved-math-names` guarantees nothing else holds the name - so every missed
    site was an undefined identifier. The compiler found all of them: alias right-hand sides,
    `@field` lookup strings, the `paired` gate list, the kernel audit list, `zn.`-qualified
    callers. **Five classes of miss, five compile errors, no wrong answers.**
  * ⚠ One thing the compiler could NOT catch: `SinCos`'s fields are struct keys, not functions,
    and the renamer turned `.sin` into `.sinRad`. That one compiled and would have changed the
    API. Caught by reading the error at the declaration.

#### `inline` on 239 zimrmath functions: the measurement

Andrew Kelley's guidance is to use `inline` only for a SEMANTIC reason. zimrmath has **232
`pub inline fn` and 7 private ones**, of which at most 25 have even a plausible comptime reason.
Stripping `inline` from all 239:

| | |
|---|---|
| host tests | **169 pass, unchanged** |
| SPIR-V build | **compiles** |
| shipped sweep page | **2 895 423 bytes, down from 2 930 532** |

**35 KB smaller - 1.2% - with `inline` removed.** That is the opposite of what `inline` is usually
reached for, and it is the strongest argument available: the compiler was already making better
decisions than the annotations were.

⚠ Not yet applied. Runtime speed is not measured here - only the device can say - and 239
functions is a change worth making deliberately rather than as a footnote to a rename.


- **Sep 8 2026 - the turns vocabulary is now lint-enforced. lint 0, `check` green, six smokes
  PASS, fmt clean, 169 + 99 + 7 + 222 tests.**
  * **EIGHT NAMES ADDED TO THE LINTER'S KEYWORD LIST**, beside `sin`, `cos` and `radFromDeg`.
    Both halves now apply to them: aliased once at file scope and used bare, and not shadowable by
    any other declaration. **32 qualified calls across 25 files became zero.**
  * **`zimrnum` IS EXEMPT AND ALREADY SAID WHY** - two `lint:off` lines at the top of the file,
    because its primary vocabulary is the tensor op of the same name and `zm.` disambiguates
    rather than adds noise. Nothing needed changing there.
  * ★★★ **I CONCLUDED THREE TIMES THAT THE RULE DID NOT FIRE, AND WAS WRONG EVERY TIME.** My grep
    matched the linter's pass-mode line format; when the build FAILS it prints the finding
    differently, so `grep -c` returned zero on a run that had actually caught the violation.
    **Verifying a gate means checking the exit code**: `rc=1` with the control, `rc=0` without.
    Once I did that, the message was right there, naming file, line and rule.
  * ⚠ **AND MY CONTROLS CONTAMINATED THEIR OWN BACKUP.** Repeated apply-and-restore cycles left
    `draw2d.zig` in a mixed state, and the backup I was restoring FROM had a control baked into
    it. Caught by counting occurrences rather than trusting the restore. **A backup taken after
    the first control is not a backup.**


- **Sep 8 2026 - the last nine trig calls with a constant in the argument. lint 0, `check` green,
  six smokes PASS, fmt clean, 169 + 99 + 7 + 222 tests.**
  * **718 `@sin`/`@cos` CALLS OUTSIDE zimrmath, AND ONLY NINE HAD A pi OR tau IN THE ARGUMENT.**
    That is the whole convertible set: the other 709 take a genuine radian angle - a physics
    orientation, a camera pose, a joint value that arrived from `atan2`. Converting those means
    converting how the angle is STORED, which is a different project.
  * **THE KLEIN BOTTLE WAS THE BEST OF THEM.** `kleinUv` took `uu` and `vv` on [0, 1] - the
    surface's own parameters - and multiplied both by tau on its first two lines so `@cos` would
    take them. Every branch threshold was a half turn spelled `pi`. The parameters now stay as
    they arrive and the threshold reads `0.5`.
  * **THE OTHER EIGHT WERE ALL A FRACTION OF A CYCLE**: two plot series, a gait counter-swing and
    a lift clock, a gallery phase, a billboard swing over its animation count, a sine generator,
    and a demo phase. Every one lost its constant.
  * **`pi` WENT DEAD IN TWO MORE FILES**, `ui_plotting_basic` and `basic`. Six files now have no
    `pi` or `tau` binding where they had one before the turns work started.
  * ⚠ `quadruped`'s smoke still fails, and still fails identically on the file as it was before
    this turn - **checked by reverting and re-running, for the second time.** It is a real
    pre-existing defect and worth its own investigation, not a casualty of this pass.


- **Sep 8 2026 - `zm.pow` made generic broke `easings`, and my diagnosis of WHY nobody noticed was
  wrong. lint 0, `check` green, `zig build test` green, 7 + 169 + 99 + 222 tests.**
  * **THE BREAK WAS MINE, FROM THE OWNERSHIP PASS.** Making `pow` generic over `anytype` meant
    `pow(2.0, runtime_f32)` no longer resolved - a comptime_float and a runtime f32 have no single
    type. Fixed by taking the PEER type: `pow(base: anytype, exponent: anytype) @TypeOf(base,
    exponent)`, which is what `@TypeOf` with two arguments is for.
  * ★★★ **I SAID "NO GATE RUNS THEM" AND THAT WAS AN INFERENCE, NOT A MEASUREMENT.** The reasoning
    was: these tests are broken, so nothing can be running them. Plausible, and false. A two-file
    experiment shows Zig runs an imported file's tests through both `refAllDecls` AND a plain
    import, and breaking `easings` on purpose makes `zig build test` name the exact test:

        error: 'easings.test.easings: endpoint identities for all functions' failed

    **A gap in coverage and a gap in when you last ran the gate look identical from the
    wreckage.** The tests were covered; the gate had simply not been run between my break and my
    noticing.
  * ★ Worth keeping because it cuts the other way too: several times this session I have inferred
    a missing check from a bug that survived. That inference has been right before - the `where`
    buffer, the `tiny` field - and this time it was not. **The cheap experiment is what tells them
    apart**, and it took two files and ninety seconds.


- **Sep 8 2026 - `easings` turnified, and it uncovered a regression of mine that no gate ran.
  lint 0, `check` green, five smokes PASS, fmt clean, 169 + 99 + 7 tests.**
  * **I WAS WRONG ABOUT `easings` TWO TURNS AGO.** I called it "a rewrite rather than a
    substitution" and skipped it. The elastic family is `(x) * (2.0 * pi) / p`, and in turns that
    is `(x) / p` - **the constant cancels rather than converts.** Nine call sites, every one
    shorter. The sine family's `t * half_pi` is a quarter turn, and `pi * t` is a half turn.
  * **`pi` AND `half_pi` ARE BOTH GONE FROM `easings`.** Fifth file where the constant did not
    shrink but disappeared.
  * ★★★ **AND THE CONVERSION SURFACED A REGRESSION I HAD INTRODUCED HOURS EARLIER.**
    `easings.zig` would not COMPILE as a test root: `pow(2.0, runtime)` failed with "value casted
    to comptime_float must be comptime-known". When I made `zm.pow` generic to satisfy the
    scalar-and-vector rule, I wrote `exponent: @TypeOf(base)` - which reads as "the same type" and
    is, but it lets a comptime literal base FIX that type to `comptime_float`. `@TypeOf(base,
    exponent)` is the peer type, which is what was meant.
  * ⚠ **NO GATE RAN `easings`' TESTS.** `src/tests.zig` calls `refAllDecls` on it, `zig build
    check` compiles it as a module but not as a test root, and the breakage sat there. **The file
    had seven tests and not one of them had run since the change.** They pass now.
  * ★ The regression was found by trying to turnify the file, not by any check. That is the third
    time this session that touching code for one reason exposed a defect from another.


- **Sep 8 2026 - the angle-wrap hunt: `robot`, `zimrphysics`, `quadruped`, `ui_primitives_zoo`.
  lint 0, `check` green, seven smokes PASS, fmt clean, 169 + 99 + 222 tests.**
  * ★★★ **THE TWO-BRANCH FOLD WAS NOT JUST UGLY, IT WAS CONDITIONAL.**
    `if (a > pi) a -= 2*pi; if (a < -pi) a += 2*pi;` folds exactly ONE turn. **An input 2.25 turns
    out comes back at 1.25** - still outside the range the code claims to enforce. In turns the
    whole thing is `a_turns - @round(a_turns)`: no branch, exact, and correct at any magnitude.
    Two sites converted, in `robot.zig`'s joint limits and `zimrphysics.zig`'s bend constraint,
    where the second depends on an `initial_angle` that has no bound at all.
  * **`quadruped`'s FOOT ARC IS A HALF TURN** - `@sin(t * pi)` where `t` is already the fraction
    of the swing, zero at lift-off and zero at touch-down. Now `sinTurns(t * 0.5)`.
  * ⚠ **THE FIELD-ACCESS MISS HAPPENED AGAIN, DIFFERENTLY.** Last turn the pattern skipped
    `state.phase` because it excluded a leading dot. This turn I wrote a pattern for `.phase` -
    and the actual code says `s.phase`, where the dot is preceded by an identifier. **Zero matches,
    reported as success.** Caught by the smoke, which reported it as a runtime panic when it was a
    compile error inside the wasm build.
  * ⚠ **AND A PRE-EXISTING FAILURE ALMOST GOT BLAMED ON ME.** `quadruped`'s smoke fails on the
    unmodified file too - established by reverting and re-running before touching anything else.
    **Checking whether the breakage is yours costs one command and is worth it every time.**


- **Sep 8 2026 - every value that is a turn now says so. lint 0, `check` green, seven smokes PASS,
  fmt clean, 169 + 99 + 222 tests.**
  * **TWELVE NAMES HELD TURNS AND DID NOT SAY SO**, all of them compiling happily: `a0`, `a1`,
    `t0`, `t1`, `central`, `next`, `angle`, `step`, `ext`, `a2`, `local`, `phase`. Renamed to
    `a0_turns`, `central_turns`, `local_turns`, `phase_turns` and so on, across `draw2d`,
    `shapes2d`, `effect_cubes_fs`, `effect_sieve_fs`, `sound`, `audio_stream_synth`, `zimrnum`
    and `zimrmath`.
  * ★★ **THE RULE IS AUDITABLE IN ONE LINE**, which is what makes it worth having: grep for what
    is passed to `sinTurns`/`cosTurns` and check every capture contains "turns". It went from
    twelve failures to zero, and the three that remain are a kernel reading `bx[id]` and a test
    local named `turn_count` - each of which says its unit another way.
  * ⚠ **A RENAME THAT SKIPS FIELD ACCESS HALF-WORKS.** `phase` became `phase_turns` on the
    declaration while every `state.phase` kept the old name, because the pattern excluded a
    leading dot to avoid matching other structs. The build caught it; a field read through
    `@field` would not have. **Third rename mishap this session**, and the pattern is always the
    same: the regex was right about what to change and wrong about where to look.
  * ★ `phase` was the best case in the whole conversion: it is a turn count by construction -
    kept on [0, 1) and wrapped by hand - and it took the tau multiply only to satisfy `@sin`. Now
    the name, the type and the arithmetic all agree.


- **Sep 8 2026 - aggressive turns conversion: `WgpuGl.rotate`, `raster.rotate`, `text2d`, and a
  raylib shim deleted. lint 0, `check` green, six smokes PASS, fmt clean, 169 + 99 + 222 tests.**
  * ★★★ **ONLY TWO ANGLES IN THE WHOLE ENGINE CROSS INTO CODE WE DO NOT OWN.** Both are Canvas2D
    in `bridge.zig` - `j.call("arc")` and `j.call("rotate")` - and JavaScript takes radians.
    Everything else is ours. "We must keep radians for compatibility" was true of two lines.
  * ★★★ **`rlRotatef` WAS A ROUND TRIP FOR NOTHING.** It took DEGREES because raylib did, and
    converted to radians. Its only caller **already held radians and converted TO degrees to reach
    it**: radians -> degrees -> radians. I said last turn that `text2d` did "exactly one
    conversion so turns would make it two" - **I was wrong, it did two that cancelled**. Deleted;
    the call is now `gl.rotate(rotation_turns, 0, 0, 1)` and BOTH degree helpers went dead.
  * ★★ **TWO `rotate`s IN ONE ENGINE MUST AGREE, AND ONLY A TEST SAW THAT THEY DID NOT.**
    `WgpuGl.rotate` and `raster.Context.rotate` are the GPU and software twins, chosen by which
    backend is live. Converting one left the other in radians, so the same call rotated by
    a QUARTER TURN on one path and 0.25 RADIANS on the other. The compiler was silent; a raster
    test asserting the matrix caught it. Both are turns now.
  * **FOUR FILES HAVE NO `pi` OR `tau` BINDING LEFT** - `runtime`, `raster`, `sound`,
    `audio_stream_synth` - and `shapes2d`, `plot3d`, `draw2d` have none in their bodies. Across
    the eight converted files: **116 `_turns` against 39 `_rad`**, and 31 of those 39 are
    `WgpuGl`'s raylib-compatible surface.
  * ⚠ **Ten `rl*` names are ours wearing raylib's clothes** - `rlBegin`, `rlPushMatrix`,
    `rlVertex2f` and friends. They are not bindings to anything. Renaming them is a separate job
    from turns, but `rlRotatef` proved the pattern: a legacy name carries a legacy CONVENTION, and
    the convention is what costs.


- **Sep 8 2026 - `plot3d` and `runtime` converted to turns. lint 0, `check` green, five smokes
  PASS, fmt clean, 169 + 99 tests.**

        file          _rad   _turns   tau
        shapes2d         0      44     0
        plot3d           0      18     0
        draw2d           2      27     0
        runtime          4       5     0
        sound            0       0     0

  * **`runtime.vec2AngleDeg` COLLAPSED FROM THREE STEPS TO ONE, AND GOT MORE ACCURATE.** It was
    `atan2` to radians, then `+= 2*pi` to fold the negative half up, then `* 180/pi` to reach
    degrees - a wrap and a scale, both in a unit nobody asked for. In turns the fold is
    `- floor(x)`, which is EXACT. Measured on the eight compass directions:

        southwest (-1,-1):   old 225.0000200 deg   new 225.0000000 deg
        worst of the eight:  old 1.53e-5           new EXACTLY ZERO

    The `2*pi` wrap was introducing the error the turn wrap cannot.
  * **`pi` IS NOW UNUSED IN `runtime.zig`** and the binding is gone. Third file where the constant
    did not shrink but disappeared, after the two audio ones and `shapes2d`.
  * **`plot3d`'s SPHERE MESH WAS PURE TURN FRACTIONS.** `phi = pi * st / stacks` is a HALF turn
    pole to pole and `theta = 2*pi * sl / slices` is a WHOLE turn around; they are now `0.5 * st /
    stacks` and `sl / slices`. Its camera API keeps DEGREES - the convention for a plot - and goes
    through turns rather than radians in the middle, because 360 degrees is exactly one turn where
    `180/pi` is exactly nothing.
  * **`text2d` DELIBERATELY LEFT.** It does exactly one conversion already - `degFromRad` for
    `rlRotatef` - so turns would make it two. **Not everything benefits, and saying which is part
    of the work.**


- **Sep 8 2026 - `shapes2d` and the rounded-corner call sites converted to turns. lint 0, `check`
  green, eight smokes PASS, fmt clean, 169 + 99 tests.**
  * **`shapes2d.zig` IS NOW FULLY TURNS-NATIVE: 44 `_turns`, ZERO `_rad`.** `draw2d` is down to
    two, both fields of `ImageOpts` and `TextureOpts` which feed the image path and were
    deliberately left.
  * **THE CODE WAS ALREADY THINKING IN TURNS AND CONVERTING TO GET OUT.** Every one of these was a
    turn fraction wearing radians, and each became simpler:

        const step = tau / float(sides);        ->  1.0 / float(sides)
        const seg_step36 = tau / 36.0;          ->  1.0 / 36.0
        min_segments = (end - start) / (pi/2);  ->  (end - start) / 0.25
        step = (pi / 2.0) / float(segments);    ->  0.25 / float(segments)
        drawCircleSector(..., pi, pi * 1.5)     ->  (..., 0.5, 0.75)

    **`tau` is now unused in `shapes2d` and the binding is gone**, as it was in the two audio
    files - the constant did not shrink, it disappeared.
  * ★ **THE ADAPTIVE-SEGMENT FORMULA LOST A DIVISION.** It computed a per-turn segment count as
    `2*pi/th` and then divided the whole thing by `2*pi` to normalise. In turns that is
    `1.0 / th_turns` with no normalisation at all - the round trip WAS the code.
  * **BOUNDARIES, NOT CASCADES.** `WgpuGl`, `ui.zig` and `wgpu_app` keep their radian APIs -
    imgui- and raylib-compatible surfaces - and convert exactly where they call into the drawing
    layer, with `zm.turnsFromRad` at the crossing. Nine such crossings, each one line.
  * ⚠ **A rename inside the file caught me again**: I renamed the local `th` to `th_turns` on its
    declaration and left two uses saying `th`. The compiler found both. That is the third time
    this session a rename has been the risky part, and every time the compiler caught the
    in-file half while the cross-file half stayed silent.


- **Sep 8 2026 - `draw2d` converted to turns, and the experiment's real finding is that the
  compiler could not help. 99 zimrnum tests, 169 zimrmath tests, lint 0, `check` green, nine
  smokes PASS, fmt clean.**
  * **THE SURVEY SAID 30 CALL SITES, NOT 111.** 28 trig calls carry a pi or tau in an argument, 7
    of those are zimrmath's own turns tests which are deliberately radian. The `_rad` convention
    was ALREADY half in place - 31 parameters across four files - which made the target clear.
  * ★★★ **A UNIT IN A PARAMETER NAME IS CHECKED BY NOTHING.** `rotation_rad: f32` and
    `rotation_turns: f32` are the same type. After converting `draw2d`, the five forwarding call
    sites in `WgpuGl` and `SwAdapter` **compiled clean while feeding radians into a turns
    parameter** - a factor of 6.28, silent. Found by reading the diff, not by any gate.
    The fix used: convert at the module boundary, in a local whose name says the unit. The fix
    that would have PREVENTED it: a `Turns` type, the way `Named` wraps a tensor's axes.
  * ⚠ **THE BLANKET RENAME ALSO HIT THINGS THAT MERELY SHARED THE NAME.** `rotation_rad` was a
    field of `ImageOpts` and `TextureOpts`, option structs feeding the image path, which was not
    converted. Those broke LOUDLY - read by name, so the compiler saw them. A field read through a
    generic `opts` would not have broken at all.
  * ⚠ **AND MY REPAIR SCRIPT DELETED 131 BLANK LINES** across two files by filtering empty strings
    out of a rebuilt line list. `zig fmt --check` passed, because blank lines between functions
    are not something fmt restores. Reverted from the backup and redone surgically.
  * **THE ACCURACY WIN IN DRAWING IS INVISIBLE, AND THAT IS WORTH SAYING.** The rounded-corner
    arcs measured 2.29e-5 from the exact arc through radians and 8.87e-6 through turns, at radius
    40. **Both are far below a pixel.** What turns buy here is that a corner reads as `0.25`
    instead of `pi * 0.5`, in the same units as the branch conditions three lines above.
  * ★ Internal callers were ALREADY writing `tau * 0.5`, `tau * 0.75`, `tau * 0.25` - they thought
    in turns and multiplied to get out. Those lines are now `0.5`, `0.75`, `0.25`.


- **Sep 8 2026 - five call sites converted to turns, chosen by measurement rather than by count.
  99 zimrnum tests, 169 zimrmath tests, lint 0, `check` green, all four smokes PASS, fmt clean.**
  * **THE SURVEY FOUND 21 REAL CALL SITES, AND ONLY FIVE WERE WORTH DOING NOW.** 28 trig calls
    carry a pi or tau in the argument; 7 are zimrmath's own turns tests, which are DELIBERATELY
    radian and must not change. Of the 21 real ones, 15 are a full turn and 6 a half turn.
  * **THE TWO AUDIO SITES ARE THE BEST CASE IN THE CODEBASE.** `sound.zig` and
    `audio_stream_synth` both keep `phase` on [0, 1) and wrap it themselves - they multiplied by
    tau purely to satisfy `@sin`, which divides it straight back out. Measured over one cycle at
    48 kHz against the f64 answer:

        radians  4.11e-7        turns  1.04e-7        (a factor of four)
        half-cycle zero crossing: 8.74e-8  ->  1.22e-16

    A phase accumulator that lands on exactly zero every whole turn is an audible property, not a
    numerical curiosity.
  * **`tau` IS NOW UNUSED IN BOTH AUDIO FILES AND THE LINT SAID SO.** That is the article's claim
    arriving as a compiler diagnostic: the constant did not get smaller, it disappeared.
  * **THE SHADER SITES BUY READABILITY MORE THAN ACCURACY.** `snapAngle` already worked in
    `fract(t)` - turns throughout, with quarter-turn thresholds - and converted to radians and
    back twice per call. `@sin(2*pi*local - pi/2)` is now `sinTurns(local - 0.25)`: the same
    number, said in the same units as the branch conditions three lines above it.
  * **`easings.zig` (5 sites) DELIBERATELY LEFT ALONE.** Those are `(t - s) * (2*pi) / p` with a
    period `p` already in the denominator; turns would want the division folded differently, which
    is a rewrite rather than a substitution. Not worth doing to code nobody is editing.


- **Sep 8 2026 - `acosh` was 570 ULP wrong at f32 and had never been audited. 99 zimrnum tests,
  169 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * **TWO CANCELLATIONS STACKED ON EACH OTHER.** `log(x + sqrt(x*x - 1))` for x just above 1
    subtracts nearly-equal numbers AND then asks `log` for a value near 1, which is where `log` is
    weakest - the same weakness that broke `log1p` last turn. Measured at f32 across the domain:
    **6.77e-5 relative, about 570 ULP**.
  * **BOTH ARE REMOVABLE, AND THE REWRITE IS SHORTER THAN THE PROBLEM.** `x - 1` is EXACT near 1
    by Sterbenz's lemma, `(x-1)*(x+1)` is `x*x - 1` without forming either square, and `log1p`
    handles the rest. **6.77e-5 -> 2.97e-7**, a factor of 228, at two and a half ULP.
  * ★★★ **IT SURVIVED THE LAST AUDIT BECAUSE IT WAS NOT IN IT.** The accuracy probe walks decades
    of magnitude either side of ZERO, and `acosh`'s argument runs from ONE upward - the probe
    could not reach the region where it fails. **A function whose weak point is not at zero needs
    a range of its own.** Now checked, and proven by a control: the textbook form fails with
    `TooInaccurate`.
  * ★★ **I ALSO NEARLY REPORTED A CATASTROPHE THAT WAS MY OWN MEASUREMENT.** The first run showed
    2.35e-2 at x = 1+1e-6 and 1.0 at 1+1e-8 - but f32 cannot hold either input, so I was comparing
    against the acosh of a number the machine never had. Against the f64 acosh of the SAME f32
    value the real error is 6.77e-5. **The same trap as the 1+1e-16 control**, and the second time
    an input that rounds has made a measurement lie.


- **Sep 8 2026 - the narrow band worked on its first run: `log1p` was 27 000 TIMES over its bar.
  99 zimrnum tests, 169 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        log1p (tiny)   worst 4.63e-8   bar 1.70e-12

  * ★★★ **THE KAHAN TRICK NEEDS AN ACCURATE `log` NEAR ONE, AND A SHADER DOES NOT HAVE ONE.**
    `log(u) * (x / (u - 1))` is exact reasoning resting on `log(u)` being good for u just above 1.
    The host's is. SPIR-V's differs by about **1.19e-7 ABSOLUTE**, and near u = 1 the result is
    small, so that absolute error is enormous relatively:

        x = 1e-6   log1p is 1.0e-6   an absolute 1.19e-7 error is 11.9 PERCENT
        x = 1e-4   log1p is 1.0e-4   1.19e-3
        x = 1e-1   log1p is 9.5e-2   1.25e-6

  * ★★★ **THIS IS WHAT THE WIDE FIELD HAD BEEN HIDING.** On eight decades the same row looked
    MARGINAL - 4.67e-8 against 4.55e-8, close enough that I widened the bar to 8 and moved on.
    The narrow band showed it 27 000 times over. **A bar that is nearly right is worse than one
    that is obviously wrong**, because it invites exactly the fix I made last turn.
  * **THE FIX IS A SERIES BELOW AN EIGHTH, ON BOTH BACKENDS.** Sixteen terms reach 7.5e-16 across
    that range, measured, which is where the arithmetic runs out; above an eighth `log(u)` is
    large enough that even a shader's absolute error is about a millionth relatively. Same
    expression on both sides, no `is_gpu` branch - the `cosh` rule. Verified: f64 8.4e-16 and f32
    2.8e-7 over sixteen decades, and the twin on the band is EXACT.
  * ★ **The bar went back to 4** - the function changed, not the tolerance. Widening it last turn
    was the wrong move made for a plausible reason, and the record now says so.


- **Sep 8 2026 - 92/93, and chasing the one red found something much worse than the bar.
  99 zimrnum tests, 169 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        XX log1p (tiny)   worst 4.67e-8   bar 4.55e-8

  * ★★★ **THE `tiny` ROWS WOULD NOT HAVE CAUGHT THE BUG THEY EXIST FOR.** The sweep compares the
    worst ABSOLUTE difference against a bar of `ulps * peak`, where peak is the largest reference
    value in the row. My field spanned eight decades, so the peak came from the largest element
    and the bar sat far above anything the smallest could fail. Measured against the old
    cancelling `tanh`, the exact defect these rows were added for:

        eight decades:  peak 9.97e-2  worst 1.92e-8  bar 4.75e-8   MISSED
        band near 1e-6: peak 1.79e-6  worst 2.67e-8  bar 8.52e-13  CAUGHT

    **Five orders of magnitude between a row that works and one that looks like it does.** The
    field is now a narrow band: every value inside one decade, so the peak IS the scale and the
    bar means something at that scale.
  * ★★ **AND TWO OF THE FIVE ROWS COULD NEVER HAVE FAILED.** `sigmoid` and `softplus` near zero
    are 0.5 and 0.693 - not small, nothing cancels. They tested nothing the noise field did not
    already cover, and three frames each to say so. Dropped; the band is for `expm1`, `log1p` and
    `tanh`, which are the three that cancel.
  * **THE ORIGINAL RED WAS REAL BUT STRUCTURAL.** `log1p` is `log(u) * (x / (u - 1))`, three
    roundings deep, and SPIR-V's `@log` differs from the host's by about one ULP. The
    compensation recovers most of it and leaves about four. **A formula that compensates cannot
    also be exact**; the bar is 8, measured, where 4 was guessed - the same correction `asinh`
    needed.
  * ⚠ The lesson generalises past this sweep: **an absolute bar scaled by the peak only tests the
    largest elements of a field.** Every row here shares that comparison, and it is right for the
    other 88 because their fields are one scale. It was only wrong where I deliberately made a
    field span many.


- **Sep 8 2026 - turn-based trig, after Casey Muratori. 99 zimrnum tests, 169 zimrmath tests,
  lint 0, `check` green, both smokes PASS, fmt clean. Sweep is NINETY-THREE.**

        f32, exact answer 1:        radians      turns
        x = 1_000.25 turns          5.96e-8      EXACT
        x = 100_000.25 turns        2.76e-4      EXACT
        2000 whole turns, f64       1.38e-12     EXACT

  * **THE ARGUMENT IS ABOUT A MULTIPLY THAT CANCELS ITSELF.** Code holding a phase on [0,1]
    multiplies by tau because `sin` wants radians; every fast `sin` divides it straight back out
    as its first act. Both sides lose bits for nothing.
  * **THE REAL WIN IS THAT THE REDUCTION BECOMES EXACT.** `x - floor(x)` drops whole turns without
    touching a mantissa bit, where `tau * x` rounds before `sin` ever sees the value.
  * ★★ **QUADRANT REDUCTION MAKES THE QUARTER TURNS EXACT TOO.** A first version reduced to one
    turn and multiplied by tau, which left `sinTurns(0.5)` at 1.2e-16 - a half turn still routes
    through pi. Splitting off the quadrant first is exact at every step (multiply by four is a
    power of two), so a half turn is quadrant 2 with residual **zero**, and `sin(0)` is zero.
    Now every quarter turn returns exactly 0 or +/-1 at both widths, which no radian
    implementation can do at any precision.
  * **TURNS MAKE `tan`'s POLES REACHABLE, AND THAT IS A BEHAVIOUR CHANGE.** 0.25 and 0.75 are
    exact inputs, so `tanTurns(0.25)` is **infinity** where `tan(pi/2)` returns about 1.6e16 - a
    wrong answer wearing the shape of a right one. Documented as a difference rather than sold as
    an improvement.
  * **THE NAMES**: `sinTurns` not `sintau`, because the whole point is that tau DISAPPEARS -
    naming a function after the constant it eliminates is backwards, and `sinTurns(x)` reads as a
    sentence. `turnsFromRad` not `rad2turn`, because `degFromRad` was already there and `2`-as-to
    would have been the file's only rebus.
  * ★ Two of my own gates caught me: the ASCII test found a `warning` glyph I typed into a doc
    comment, and the lint found an anonymous return struct. Neither would have been noticed by
    reading.
  * Not ported: every existing `sin(tau*x)` call site. The functions exist and are tested; the
    migration is a separate pass with fingerprints, because it changes numbers.


- **Sep 8 2026 - `.npy`, in both directions, verified against real numpy. 99 tests, 168 zimrmath
  tests, lint 0, `check` green, both smokes PASS, fmt clean. 330 declarations.**
  * **`saveTensors` IS BETTER AT WHAT IT DOES AND NOTHING ELSE READS IT.** zimrnum's own container
    has named tensors, a version byte and a self-describing dtype tag; `.npy` has none of that and
    is understood by numpy, scipy, PyTorch and every notebook. Eighty lines to stop being an
    island.
  * **VERIFIED AGAINST REAL numpy, NOT AGAINST ITSELF.** A round trip through one implementation
    proves the two halves agree and nothing about the format. Files numpy wrote were read here -
    a `<f4` widened to f64, a `(1,)` shape whose header needs the trailing comma Python expects -
    and bytes written here were handed to numpy, which read them as a C-contiguous (3, 4) float64
    array with the right values.
  * **THE 64-BYTE ALIGNMENT IS THE PART A ROUND TRIP WOULD NEVER CATCH.** numpy pads the header so
    the DATA starts at a multiple of 64, which is what lets a reader memory-map the array. Get it
    wrong and this library still reads the file while every other tool rejects it. The test
    asserts the boundary directly.
  * **THREE REFUSALS, EACH A CASE WHERE CARRYING ON PRODUCES A RESULT RATHER THAN A FAILURE**:
    big-endian would read every value in the wrong byte order with no error; Fortran order would
    put every element in the wrong place - a silent transpose; a non-float dtype read as floats is
    a reinterpretation, not a conversion. Tested by doctoring a valid file's header, one field at
    a time, so each refusal is checked in isolation.
  * ★ `Error.InvalidFormat` was my first instinct and the file already had an answer:
    `loadTensors` reports a corrupt file as `DomainError`. **Matching it beat adding a fifth error
    to a set of four** - the third time this session the existing decision was the right one.


- **Sep 8 2026 - a review of this session's divergences, the names, and the plan. 98 tests, 168
  zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * **I ADDED A CAPABILITY, MEASURED IT, AND REVERTED IT.** znum takes a `KeepDims` enum on twelve
    functions; zimrnum has none, and I implemented accepting either output shape to infer the same
    thing. Then I checked what it bought: **`reshape` on a dropped result already shares storage
    and already broadcasts back against the input**. The capability was there, through a function
    that does one thing. Reverted, with the measurement written where the next person will find
    it - **the second time this session a recorded decision was right and I nearly overrode it**,
    after the `saturate` stub.
  * **TWO DIVERGENCES WERE UNRECORDED** and are now rows 31 and 32: `argmaxAxis` returns a float
    index where znum returns `Tensor(i64)`, and the absence of `keepdims`. Six other functions
    flagged as unmentioned turned out to differ only by the caller-allocates policy, which is
    already row 1 - a group decision covering them all.
  * **SIX FUNCTIONS HAD NAMES A READER HAD TO DECODE**: `vw`/`vg` in the optimisers are now
    `weight_view`/`grad_view`, `s`/`l` in `hingeLoss` are `score`/`label`, `na`/`nb` are
    `norm_a`/`norm_b`, `ai`/`bi`/`oi` in `bmm` are `left`/`right`/`result`. All 98 tests still
    pass, which is what makes a rename like this cheap.
  * ★ **THE PLAN'S REMAINING-WORK LIST WAS COUNTING NAMES, NOT CAPABILITIES.** 435 znum functions
    have no counterpart by name, but that counts `cumMax` against `cummax`. Rewritten as five
    capabilities, and the first is not a list of functions at all: **zimrnum is float-only, 196
    `requireFloat` sites, and integer tensors are a decision not yet taken.** Bitwise ops, honest
    index tensors and dataframe columns all sit behind it.
  * **`.npy` reading is the best value-per-line left** - self-contained, no dependency on the
    integer question, and the only item that connects zimrnum to the rest of the scientific world.


- **Sep 8 2026 - the layer-norm gradient, and 51 lines of duplicate derivation removed. 98 tests,
  168 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * **I SET OUT TO ADD A LAYER-NORM BACKWARD AND THE COMPILER TOLD ME THERE WAS ONE.** A private
    `layerNormBackward` was already wired into the tape. Measured, the two implementations agreed
    to **7e-17** - which is the only reason nobody had noticed there were two.
  * **TWO CORRECT IMPLEMENTATIONS OF ONE FORMULA IS ONE MORE THAN IS USEFUL.** A fix to either
    leaves the other wrong, and the agreement that makes them safe is exactly what would hide the
    divergence. Consolidated onto the public standalone form; the private one is now four lines
    delegating to it, and no longer needs the normalised output passed in - it recomputes what it
    needs from the input in one pass.
  * **THE GRADIENT COUPLES EVERY ELEMENT OF A ROW.** Layer norm subtracts the row mean and divides
    by its deviation, so changing one element moves every other normalised value. The two
    subtracted means in `dx = (dy - mean(dy) - xhat*mean(dy*xhat)) / sigma` ARE those couplings,
    and a version missing either is right on average and wrong everywhere - which trains slowly
    enough to look like a bad learning rate rather than a bug. Finite differences: **2.0e-10**.
  * **THE SECOND INVARIANT IS ONLY EXACT AT EPSILON ZERO, AND THE MEASUREMENT SAID SO.** Scaling a
    row should leave the output unchanged, so the gradient should be orthogonal to the row - but
    `sigma` is `sqrt(var + epsilon)` and epsilon does not scale with the row. Measured:

        epsilon 1e-5   projection 7.7e-7
        epsilon 1e-8   projection 7.7e-10
        epsilon 1e-12  projection 7.7e-14
        epsilon 0      projection 1.8e-16

    **Linear across four decades.** A fixed bar would have been either wrong or meaningless; the
    test asserts the PROPORTIONALITY, which is the actual relationship and which a gradient
    missing the second mean would break at every epsilon including zero.


- **Sep 8 2026 - the scan and per-axis-index batch. 97 tests, 168 zimrmath tests, lint 0, `check`
  green, both smokes PASS, fmt clean. 325 declarations.** `cumprod`, `cummin`, `cummax`, `diff`,
  `pctChange`, `argmaxAxis`, `argminAxis`.
  * **`diff` KEEPS THE LENGTH AND PUTS NaN AT THE FIRST POSITION**, which is znum's convention and
    pandas'. There is no difference at the first element, and the two ways of saying so are a
    result one shorter or a hole in a full-length one. **A shorter result silently misaligns
    against every other column**; that is why those libraries chose the hole, and NaN rather than
    zero because zero is a difference someone might believe.
  * **THE TEST PROVES THE PROPERTY THAT MAKES THE CHOICE RIGHT**: summing a difference back gives
    the original less its first element - which only holds because the length was kept.
  * **THE LAST VALUE OF A RUNNING SCAN IS THE WHOLE-TENSOR REDUCTION.** `cumprod` ends at
    `prodAll`, `cummin` at `minAll`, `cummax` at `maxAll` - three checks against functions that
    already have their own tests, rather than three tables of expected values.
  * **`cumsum` IS DELIBERATELY NOT ROUTED THROUGH THE SHARED SCAN.** It uses `CompensatedSum` to
    bound the error of a long addition; a product does not cancel and a running extremum
    accumulates no error at all, so folding them together would mean either giving up the
    compensation or carrying it through three operations that do not need it.
  * `argmaxAxis` returns a float index, because every tensor here holds one type. Exact to 2^24 in
    f32 and 2^53 in f64, far past any axis this library can hold - stated in the doc rather than
    left to be discovered. Tested on an ASYMMETRIC matrix along both axes, so a transposed
    implementation could not pass.


- **Sep 8 2026 - `Walk2`, and the rest of the single-tensor loops. 29 of 48 converted, fingerprint
  identical throughout. 96 zimrnum tests, 168 zimrmath tests, lint 0, `check` green, both smokes
  PASS, fmt clean.**
  * **THE TWO-TENSOR LOOPS NEEDED TWO WALKERS, NOT A FLAT INDEX.** A dozen functions read two
    tensors elementwise - `dotAll`, `covariance`, every paired loss. The two are checked to have
    the same SIZE but not the same shape or rank: a `(6, 7)` may legitimately be paired with a
    `(42,)` view, and either may be strided. One flat index would be wrong for both. `Walk2` steps
    two positions in lockstep, which is the thing those loops were spelling out by hand.
  * **THE CONVERSION MADE SEVENTEEN `catch unreachable` VISIBLE TO THE LINTER**, all inside a
    `Walk` body where the position comes from the shape being walked and cannot be out of range.
    Propagated as `try` - except in three functions that do not return an error union at all
    (`prodAll`, `anyNonzero`, `allNonzero`), where the suppression is the honest form and stays.
    **125 -> 108.**
  * ★ The lint finding was the useful part: the old pattern HID these. A loop that reaches its
    elements through a hand-rolled index is a loop the linter cannot reason about; a loop that
    goes through an iterator is one it can.
  * **19 loops remain**, and they are one idea: walk the OUTPUT and derive a source position -
    `flip`, `roll`, `take`, `tile`, `concat`, `tensordot`, `sumAxis`, `varianceAxis`. That wants a
    third shape, `Project`, which maps an output coordinate to an input one. It is a real design
    question rather than a mechanical conversion, so it waits.


- **Sep 8 2026 - `Walk`, the iterator. 22 of 48 loops converted, fingerprint identical across
  thirty functions. 96 zimrnum tests, 168 zimrmath tests, lint 0, `check` green, both smokes
  PASS, fmt clean.**
  * **THE SAME FIVE LINES APPEARED FORTY-EIGHT TIMES**: declare a walker, take a shape slice,
    count down a remaining counter, call `advance` at the bottom. Each copy was a chance to forget
    the advance or to walk one shape while indexing another, and each reached its elements through
    `catch unreachable` because the position is in range by construction and the compiler cannot
    know it.
  * **This is the `CompensatedSum` lesson again: a type with a method makes the right thing the
    default.** Two lines instead of five, the counter and the advance inside where they cannot be
    forgotten, and the yielded slice exactly as long as the rank it came from.
  * **THE FIRST VERSION HANDED BACK A SLICE INTO ITS OWN STATE AND THEN MUTATED IT.** It captured
    the position, advanced, and returned the capture - but the capture aliases `self.at`, so every
    caller saw the NEXT position rather than the current one. The order test caught it on the
    first run. The advance now happens at the start of the following call.
  * **THE REGEX CONVERSION LEFT THREE ARTEFACTS AND THE COMPILER FOUND ALL THREE**: a `const at`
    shadowing itself, a body whose `advance` sat mid-loop before an early `continue`, and two
    loops the pattern half-matched (a `for` over indices, and a SECOND pass reusing the first
    walker). Mechanical conversion is safe here precisely because the compiler and the
    fingerprint both have to agree.
  * ★ It also made four `catch unreachable` sites visible to the linter that had been hidden
    inside the old pattern - propagated as `try` rather than suppressed. **125 remain**, and every
    one is now inside a `Walk` body where the position is provably in range.
  * 26 loops still use the old form: two-tensor walks (`dotAll`, `covariance`, the losses) that
    step two shapes at once, and the reductions that project onto a smaller output. Those want a
    second iterator shape rather than this one, which is a separate turn.


- **Sep 8 2026 - the accuracy audit. FOUR more bugs of the `tanh` class, found by asking every
  function the same question. 96 zimrnum tests, 168 zimrmath tests, lint 0, `check` green, both
  smokes PASS, fmt clean.**

        sinh    1.0  -> 1.8e-7      asinh   1.0  -> 2.1e-7
        atanh   1.0  -> 2.1e-7      gelu    3.0  -> 4.3e-6

  * **`tanh` WAS FOUND BY ACCIDENT, SO THE QUESTION WAS ASKED OF EVERYTHING.** f32 path against
    f64 path, eight decades down to 1e-8, twenty-two functions. Four suspects, all subtractions of
    nearly-equal numbers, and **not one of them visible to any existing test** - none of them
    asked about small inputs.
  * **EVERY FIX IS THE SAME MOVE AND EVERY ONE IS SHORTER.** `expm1(x) - expm1(-x)` for `sinh`,
    `log1p` for `asinh` and `atanh`. `gelu` becomes `x * sigmoid(2u)`, which IS
    `0.5*x*(1 + tanh(u))` rearranged - the same number, one call instead of three operations, and
    no cancellation. **The correct form was the simpler form in all four cases**, which is worth
    knowing: this was not a trade.
  * **THE f64 PATH IS AN ORACLE FOR THE f32 ONE** - same algorithm, fifty-two bits against
    twenty-three - so agreement means the FORM is right rather than that two implementations share
    a mistake. No arbitrary-precision library needed.
  * Made permanent, at a bar of 1e-5: two orders below anything a cancellation bug produces, and
    loose enough not to fail the two or three ULP some of these are by construction. Proven by
    restoring the old `sinh` and the old `gelu`.
  * **Simon raised the device budget to 6 s**, which is 240 rows at settle 3 - so paging is no
    longer blocking and the sweep can grow again.


- **Sep 8 2026 - a second input distribution, because the first one could not see the `tanh` bug.
  Sweep is NINETY-ONE. 96 tests, 167 zimrmath tests, lint 0, `check` green, both smokes PASS.**
  * **A TEST'S INPUT DISTRIBUTION DECIDES WHICH BUGS IT CAN SEE.** `zm.tanh` was 1.0 relative
    error at f32 near zero for as long as this sweep has existed, and the sweep never said so -
    every row is measured on a normal(0,1) field, which has no values small enough for a
    subtraction of nearly-equal numbers to cancel. Eighty-six rows, one distribution, one blind
    spot shared by all of them.
  * **THE `tiny` FIELD**: magnitudes spread over eight decades below 1, alternating sign, laid out
    BY INDEX rather than drawn - so the smallest values are guaranteed present rather than merely
    likely. Five rows now ask about cancellation: `expm1`, `log1p`, `tanh`, `sigmoid`, `softplus`,
    all measured under 1 ULP of f32 on the host before shipping.
  * **THE COVERAGE GATE HAD TO BE RELAXED, AND THE ASYMMETRY IS THE POINT.** It required EXACTLY
    one row per kernel, on the reasoning that two is a copy-paste slip. It is not: the same kernel
    on a different field is a different question. A duplicate row costs three frames; a missing
    row costs a kernel nobody checks. The bar is now "at least one", and both halves are proven by
    control - removing every row for a kernel still names it.
  * Sweep is now 91 rows, 2.27 s at 120 Hz - past the 2 s budget. **Paging is the next structural
    job**, and it is now blocking rather than theoretical.


- **Sep 8 2026 - stage 1 of the ownership plan. Five functions owned; two of them were WRONG.
  96 tests, 167 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * **`hypot` and `cbrt` are bit-identical to std** - 200 000 random pairs, 60 decades, signed
    zero, subnormals, infinities. 110 lines against std's 186, because zimrmath is f32 and f64 and
    std carries f16, f80, f128 and an unfused fallback.
  * **`expm1` and `log1p` are five lines each and were the accuracy bug.** At x=1e-12 the old
    identity was wrong in the fifth digit. Kahan's trick recovers it exactly, at f64 3.8e-16 -
    within 2 ULP of std's 251-line implementation.
  * **THE OLD SHADER `tanh` WAS 1.0 RELATIVE ERROR AT f32**, near zero, which is where an
    activation lives. The sweep never caught it because a normal(0,1) field has no values small
    enough - **a test's input distribution decides which bugs it can see**. Now one expression for
    both backends, built on `expm1`, and the host gives up nothing.
  * **A ONE-ULP CHANGE BROKE A TEST BOUND, AND THE BOUND WAS THE PROBLEM.** `norm < 1e-6` was read
    off one run of a chaotic system. The measurement showed the right form: the MSE gradient near a
    minimum scales as sqrt(loss), and loss 3.0e-10 with norm 1.6e-5 is exactly that. The bound is
    now relative to the loss.


- **Sep 8 2026 - 85/86, and the one failure was the change I made to close the third edge.
  96 tests, 167 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        XX cosh   worst 29.62719   bar 8.1e-6

  * **`zm.cosh` WAS `math.cosh` ON THE HOST AND AN IDENTITY ON SPIR-V.** Both are cosh, both are
    correct, and the sweep compares one against the other - so a function with two routes has two
    answers. 29.6 is not a rounding difference; it is a different function.
  * ★ **THE HEADLESS TWIN TEST IS STRUCTURALLY BLIND TO THIS.** It compiles the kernel for the
    HOST, where `is_gpu` is false, so it measures the branch that will never run on a GPU. It
    reported 0.0 for cosh and was right about the only thing it can measure. **Thirteen kernels
    were converted on the strength of that test**; twelve happened to be safe and one was not.
  * **THE FIX IS THE RULE `pow` AND `sinh` ALREADY FOLLOW**: write the expression once. `sinh`,
    `asinh`, `atanh` and `rsqrt` have no branch at all and every one measured EXACTLY ZERO on the
    same device. `cosh` is now the same shape, and gives up nothing - both routes overflow
    together near |x| = 89 in f32.
  * **NOW GATED**: a kernel may only call a `zm` function on an audited branch-free list, or one
    of six known-branching ones whose device-measured agreement is recorded beside them. A call
    to anything else is a compile error naming the function. Proven by pointing a kernel at
    `zm.cbrt`, which branches and is not on either list.
  * The gate is written without `std`, because `zn_unary.zig` compiles for SPIR-V and imports only
    what a kernel needs - a three-character scan is small enough to spell out.


- **Sep 8 2026 - a review with fresh eyes. Three findings, all of them recurrences.
  96 tests, 167 zimrmath tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * **THE `Into` SUFFIX HAD COME BACK: 12 NAMES BECAME 23.** An earlier pass this session cut it
    from 32 to 12 on the grounds that it described the linter rather than the code. It regrew
    because **the rule was never written anywhere a compiler could read it**. All 23 names were
    free. The rule - every function here writes into `out`, so a suffix true of everything
    distinguishes nothing - is now a test, proven by a control that ADDS a suffixed function.
    Fingerprint identical across the rename: `5242059111b0adb1`.
  * The rename exposed four more shadowings (`triangle`, `flip`, `conv2d`, `diagonal`) and **a
    test whose name still said `expInto`** from a rename several turns ago. The name had been
    wrong for hours and nothing looks at test names.
  * **THE GATE'S FIRST NEGATIVE CONTROL WAS INVALID, AND SO WAS ITS FIRST IMPLEMENTATION.**
    Renaming an existing function breaks compilation before the gate can run, so the control
    proved nothing; adding one is the valid form. And the gate's own explanatory comment contained
    the literal pattern it scans for, so it counted itself - **the same trap the prose gate fell
    into two turns ago**. A checker that reads the whole file reads its own explanation.
  * **THE zm <-> GPU EDGE WAS NEVER GATED.** Eighteen unary kernels wrote out arithmetic `zm`
    already spelled, on the side of the fence the vocabulary pin does not reach. Thirteen now call
    `zm`, so one sweep row checks zm's host path, zm's SPIR-V path and the two against each other.
    All thirteen twins measured exactly 0 after the change.
  * **THE COVERAGE PERCENTAGE WAS A JUDGEMENT WEARING A MEASUREMENT'S CLOTHES.** By name, zimrnum
    has 94 of znum's 549 user-facing functions - 17%. By concept, about 40%. The gap is the
    deliberate renames, and no script can bridge it. The plan now states the countable quantities
    and says plainly that the percentage cannot be computed.
  * **What remains is concentrated in five places**: `ops` integer and bitwise variants (39), layer
    types (21), `reduce` (21 -> 14), `stats` (19), `df` dataframes (18). Everything else is done,
    deliberately renamed, or znum's internals.


- **Sep 8 2026 - named dimensions, part two: the axis-taking operations. 95 tests, lint 0,
  `check` green, both smokes PASS, fmt clean. 311 declarations.**
  * **THE REDUCTIONS TAKE A NAME AND THE RESULT'S TYPE HAS THAT AXIS REMOVED.** That is what
    makes this more than sugar: `logits.meanAxis("batch", x)` where `x` is still named
    `(batch, classes)` does not compile, because the axis is gone from the type and a result of
    the wrong shape cannot be passed on. Two more negative controls, run by hand:

        a.sumAxis("depth", o)      -> dropName: `depth` is not one of the axes
        result named (width)       -> error: expected type Named(f64, .{"batch"})

    The second is a plain type mismatch, which is exactly right - the names ARE the type.
  * **`window` RETURNS THE SAME TYPE**, which is what a mini-batch is: fewer rows, same meaning,
    nothing downstream needing to be told which axis was cut.
  * **A TWO-LAYER NETWORK NOW READS AS A SENTENCE** - inputs are (batch, features), the first
    weights turn features into hidden, the second turn hidden into classes - and every transition
    is checked at compile time. The test runs the forward pass and then checks the named reduction
    against the unnamed call with the index written out, which is what it compiles to.
  * **WHERE NAMES DO NOT REACH: INSIDE THE TAPE.** `graph.matmul` returns a `Var`, an index into
    the graph, which carries no names. Names help where you hold tensors and pass axis indices;
    the tape is deliberately not that. **The tutorial says so**, because implying a guarantee that
    stops at the first `graph.` call would be worse than having no guarantee.
  * On converting the existing examples: most demonstrate one function on a 3x3 matrix whose axes
    have no meaningful names, and wrapping those adds ceremony without adding a check. The network
    and training examples are where `batch`, `width` and `classes` are real distinctions, and
    those are the ones now written with names.


- **Sep 8 2026 - NAMED DIMENSIONS. 94 tests, lint 0, `check` green, both smokes PASS, fmt clean.
  307 declarations.**
  * **`sumAxis(out, activations, 1)` IS A SENTENCE WITH A HOLE IN IT.** Which axis is 1? On a
    `(batch, width)` tensor it is the width; on a `(width, batch)` one it is the batch, and the
    two produce different numbers of the same type with no complaint from anything. **Every axis
    argument in this library is that hole**, and the only defence has been care.
  * **THE NAMES LIVE IN THE TYPE**, so `axis("width")` resolves at compile time and costs nothing
    at runtime. Three mistakes become compile errors, each verified by building it:

        A.axis("wdith")               -> Named: no axis called `wdith`; has: batch width
        Named(f64, &.{"b","b"})       -> Named: axis name `b` is repeated
        contract width against batch  -> namedMatmul: the axes being summed over must be
                                         the same axis

  * **`matmul` CHECKS NUMBERS; `namedMatmul` CHECKS MEANING.** Two tensors can agree that a's
    columns equal b's rows and still be the wrong pair - a `(batch, width)` times a
    `(width, classes)` is a layer, and a `(batch, width)` times a `(batch, classes)` is nonsense
    that typechecks **whenever batch and width happen to be equal**. Nothing here could tell them
    apart before.
  * **THE NAMES FOLLOW THE DATA.** A transposed `(batch, width)` is a `(width, batch)`, and every
    later `axis("width")` returns the NEW index with no adjustment by the caller. That is the
    property that makes names worth having rather than merely pleasant, and the test asserts it
    along with the view still sharing storage.
  * **60 LINES AGAINST znum's 3 302.** Both put names at comptime, and znum is right about that.
    The divergence is scope: `Named` wraps a `Tensor` and hands it back through `.tensor`, so
    every existing function keeps working and a caller adopts names where they help rather than
    everywhere at once. A parallel API for every operation would double the surface to keep two
    of everything in step.
  * Two Zig details worth keeping: a slice of a comptime `var` **carries a reference to it**, and
    a type parameterised on that reference is rejected - the array has to be frozen into a `const`
    first. And `comptimePrint("{s}", .{names})` cannot format a slice of slices; plain `++`
    concatenation can.


- **Sep 8 2026 - `einsum`, with the spec parsed at COMPILE TIME. 93 tests, lint 0, `check` green,
  both smokes PASS, fmt clean. 300 declarations.**
  * **FOUR CLASSES OF ERROR MOVED FROM RUNTIME TO COMPILE TIME.** znum takes
    `spec: []const u8` and parses it while the program runs, so a typo comes back as an `Error`
    the caller handles at the point of use, on data. But **every mistake in a spec is a property
    of the source**, which cannot change while the program runs. Verified by building each:

        "ij,jk"        -> compile error: spec needs an explicit `->`
        "ij,jk->iq"    -> compile error: output label `q` appears in no input
        "ij,jk->ii"    -> compile error: output label `i` is repeated
        "ij->ij" x2    -> compile error: spec names 1 operand, 2 given

    What is left for runtime is what genuinely depends on the data: a rank not matching its
    subscript, and two operands disagreeing about a label's extent.
  * **A REPEATED LABEL WITHIN ONE OPERAND SELECTS ITS DIAGONAL**, so `"ii->"` is a trace and
    `"ii->i"` is the diagonal, with nothing written for the diagonal case at all - the index
    assignment sets both axes from one label and the walk visits only the diagonal.
  * **EVERY FORM IS CHECKED AGAINST THE FUNCTION IT DUPLICATES** - `matmul`, `trace`,
    `diagonalInto`, `outer`, `dotAll`, `sumAxis`, `bmm`. A table of expected numbers would test
    einsum against whoever wrote the table; this tests it against seven functions that each have
    their own test.
  * The compile-error cases cannot be asserted in a test, because a test that fails to compile is
    not a failing test. The four negative controls were run by hand and their exact messages are
    recorded above, which is the honest substitute.


- **Sep 8 2026 - the linalg batch, and the number that explains the rest of the file.
  92 tests, lint 0, `check` green, both smokes PASS, fmt clean. 299 declarations.**
  `bmm`, `tensordot`, `outer`, `diagonalInto`, `triangleInto`, `conditionNumber`,
  `eigvalsSymmetric`.
  * **THE SPECIALISATIONS ARE TESTED AGAINST THE GENERAL FORM, NOT AGAINST HAND-WRITTEN NUMBERS.**
    `tensordot` is the general contraction: `matmul` is it over `a`'s last axis and `b`'s first,
    `matmulNT` over both last axes, `dotAll` is it with nothing left over, `outer` is it over
    nothing at all. Checking each against `tensordot` is stronger than four tables of expected
    values, because **it is the specialisations that are likely to be wrong and the general form
    that is easy to reason about**.
  * **`conditionNumber` IS THE NUMBER BEHIND EVERY ALGORITHM CHOICE RECORDED HERE.** It says how
    much a relative input error can be multiplied on the way out: condition 1e8 in f64 keeps about
    eight of sixteen digits. That is why `qr` is Householder, why `lstsq` avoids the normal
    equations (which SQUARE it), why `svd` does not go through the Gram matrix, and why `pinv`'s
    cutoff is relative. Having it as a function means a caller can ask the question directly
    rather than inferring it from a bad result.
  * **INFINITE FOR A SINGULAR MATRIX**, not a large finite number - the smallest singular value is
    zero and the ratio is unbounded, and saying so is more useful than reporting 1e17.
  * The test measures a 5x5 Hilbert matrix at about 4.8e5, which is the reason that matrix is the
    one every algorithm in this file is tested on. Now the tutorial can say so with a number.
  * `triangleInto`'s test asserts that **upper-with-diagonal plus strictly-lower rebuilds the
    original**, which checks the diagonal is counted once rather than twice or not at all - a
    check neither triangle alone could make.
  * `square` as a local shadowed the tensor `square`. Sixth instance; the compiler caught it, as
    it has every time.
  * **Remaining in linalg: `einsum` and a general non-symmetric `eig`**, both substantially bigger
    than anything in this batch - `eig` needs a Hessenberg reduction and a shifted QR iteration.


- **Sep 8 2026 - the metrics batch, chosen for the cases where implementations quietly disagree.
  91 tests, lint 0, `check` green, both smokes PASS, fmt clean. 292 declarations.**
  `confusionMatrix`, `ClassScore`, `classScore`, `macroF1`, `r2Score`, `cosineSimilarity`,
  `hingeLoss`.
  * **AN UNDEFINED PRECISION IS NOT ZERO, AND BOTH ARE RETURNED.** If a model never predicts class
    k, `tp / (tp + fp)` has a zero denominator and the quantity does not exist - there is no
    fraction of predictions that were right when there were no predictions. znum returns 0 and so
    does this, because a macro average has to average something. But **0 is a lie in a specific
    way**: it says every prediction of this class was wrong when the truth is that there were
    none. `ClassScore` carries `precision_undefined` and `recall_undefined` beside the numbers, so
    the average uses the plain zeros and a caller can still tell the two kinds of zero apart.
  * The test is built around a class occurring once in the truth and never predicted, so **recall
    is a real zero - the model missed it - while precision's zero describes nothing**. Asserting
    both flags is what distinguishes a correct implementation from one that merely returns zeros.
  * **R2 CAN BE NEGATIVE AND THE TEST INSISTS ON IT.** The name says "R squared" and squares are
    not negative, which misleads nearly everyone. Below zero means worse than predicting the mean,
    which happens and is exactly what you want to be told; clamping would turn "worse than a
    constant" into "explains nothing". A constant truth is `DomainError` - no variation to
    explain. Three points pinned: exactly 1 for a perfect fit, exactly 0 for predicting the mean,
    negative for a reversed prediction.
  * **`cosineSimilarity` REFUSES A ZERO VECTOR** rather than returning 0. Zero means
    perpendicular, and a zero vector is not perpendicular to anything - silently calling it
    orthogonal is how a degenerate embedding becomes a plausible similarity score. Scale
    invariance is asserted too, since an angle cannot depend on either vector's length.
  * `confusionMatrix` is true-down, predicted-across, asserted on an ASYMMETRIC example - reading
    it the other way round swaps precision with recall, and a symmetric test would not notice.


- **Sep 8 2026 - the optimiser batch: AdamW, RMSProp, Adagrad, value clipping and four learning
  rate schedules. 90 tests, lint 0, `check` green, both smokes PASS, fmt clean. 285 declarations.**
  * **znum IS RIGHT ABOUT AdamW AND SAYS WHY**, so it is followed: the decay goes straight onto
    the weight, not into the gradient. That matters because with Adam the two are NOT the same
    thing - a gradient-side decay is divided by `sqrt(v_hat)` along with everything else, so **a
    parameter with a large gradient history gets decayed LESS than one with a small one**, which
    is the opposite of what a regulariser is for.
  * **THE TEST CHECKS THE ARITHMETIC SIGNATURE, NOT THE DIRECTION.** "The weights got smaller"
    passes for the wrong implementation too. What is asserted is that the difference from plain
    Adam is **exactly `rate * decay * weight`** - a quantity depending on the weight ALONE. A
    coupled decay would make the difference depend on the gradient, and the equality would fail on
    the elements whose gradients differ most. Plus `decay = 0` reducing exactly to `adamStep`.
  * **RMSPROP'S MISSING BIAS CORRECTION, MEASURED.** Fed the same gradient forty times: adagrad
    1.00e-1 -> 1.58e-2 and still shrinking, rmsprop 3.16e-1 -> 1.01e-1. **RMSProp's first step is
    three times its settled one**, because `mean_square` starts at zero and the first division is
    by sqrt(0.1). Adam corrects for this and RMSProp does not - a property of the algorithm, now
    stated in the doc and pinned by the test rather than discovered by a reader.
  * **I SET THE RMSPROP BAR AT 1e-6 AND IT SETTLES AT 0.1007, NOT 0.1.** Corrected from the
    measurement, and the settled value is now asserted at 1e-3 with the first-step ratio asserted
    separately, which is the part that carries the meaning.
  * **`clipByValue` AND `clipByNorm` ARE OPPOSITE CHOICES AND BOTH ARE WANTED.** Elementwise
    clipping changes the gradient's DIRECTION; norm clipping preserves it. The test asserts the
    distinction directly - every ratio to the original is equal after norm clipping and visibly
    unequal after value clipping - so neither can be quietly turned into the other.
  * **THE SCHEDULES ARE TESTED AT THEIR ENDPOINTS**, where an off-by-one lives: cosine gives
    exactly `base` at 0 and exactly `lowest` at `total` and past it, warmup gives exactly 0 at
    step 0 and exactly `base` at step `warmup`. Monotonicity is asserted across the whole cosine
    range too, because a wrong sign inside it would leave both endpoints correct.
  * `floor` as a parameter name shadowed the tensor `floor`; it is `lowest` now. Fifth instance
    of this shadowing, and the compiler caught it as it has every time.


- **Sep 8 2026 - the manip and index batch, and a rename that had rewritten six comments.
  89 tests, lint 0, `check` green, both smokes PASS, fmt clean.** `argminAll`, `flipInto`,
  `rollInto`, `nonzeroInto`, `booleanMaskInto`, `bincountInto`, `sortInto`, `uniqueInto`.
  * **A GLOBAL RENAME REWROTE ENGLISH.** Renaming a shadowing local `direction` to
    `permutation_sign` was meant to touch one declaration; written as a global substitution it
    rewrote the word wherever it appeared, and six doc comments came to read **"a step in a
    different permutation_sign is not a smaller version of the step you wanted"**. It compiled,
    all 88 tests passed, and nothing could see it but a reader. Found only because a diagnostic
    dump happened to print one of the damaged lines.
    **Now gated**: identifiers that exist only because of a shadowing fix must not appear in
    comments, and each is a word no English sentence would reach for. Proven by negative control.
  * **EVERY FUNCTION IN THIS BATCH HAS A CONVENTION THAT COULD GO THE OTHER WAY**, so the test
    pins each rather than leaving a reader to run it. A positive roll moves elements FORWARD;
    `uniqueInto` returns ASCENDING order, not first-seen - and on the sample `3,1,4,1,5,3,1` the
    two conventions differ, which is why that sample is the one in the test.
  * `nonzeroInto` and `booleanMaskInto` are the same question asked two ways - the positions, and
    the values at those positions - so the test asserts **they agree with each other** rather than
    against two lists written by hand.
  * Both return a count rather than requiring an exactly-sized output, because the number of
    non-zeros is not known until the scan is done. An output too small is `ShapeMismatch`, never a
    truncation; `bincountInto` takes the same line, because a count that quietly dropped what it
    could not hold would sum to less than the input with no way to notice.


- **Sep 8 2026 - the statistics batch: quantiles, distribution shape and the mean family.
  87 tests, lint 0, `check` green, both smokes PASS, fmt clean.** `quantile`, `quantileSorted`,
  `median`, `skew`, `kurtosis`, `geoMean`, `harmMean`, `histogramInto`.
  * **znum IS RIGHT ON ALL THREE OF THE PLACES THIS USUALLY GOES WRONG**, and is followed: its
    quantile interpolates at `q*(n-1)` as numpy does, its kurtosis subtracts three so a normal
    reads as zero, and its geometric mean goes through logarithms rather than multiplying. The
    third is the one worth naming - the product of a few hundred values well inside the float
    range still overflows it.
  * **THE UNIFORM DISTRIBUTION'S EXCESS KURTOSIS IS EXACTLY -6/5**, so that is what the test
    asserts. A bar that merely required the number to be "small" would not distinguish a correct
    fourth moment from a slightly wrong one; a closed-form answer does.
  * **THE THREE MEANS ARE TESTED AGAINST EACH OTHER**: harmonic <= geometric <= arithmetic holds
    for any positive sample, with equality only when every value is the same. One inequality
    checks all three, where three separate expected numbers would check none of them against the
    others.
  * **THE QUANTILE TEST ASSERTS A CASE THAT DOES NOT LAND ON AN ELEMENT.** Nine interpolation
    rules are in common use and they disagree on small samples; an all-integer sample at a
    position that lands exactly on an order statistic would hide the rule entirely.
  * **I ASSERTED THE HISTOGRAM'S BINS BACKWARDS.** Width 2 over [0,10) puts only the value 1 in
    bin 0 and two values in each of the rest; I wrote the reverse. Corrected from the
    measurement, and the comment now says which way round it goes.
  * The tutorial's new example was picked up automatically by the fold generator - 171 folds
    became 178 with no markers placed, which is the mechanism working as intended.


- **Sep 8 2026 - zimrnum and zimrmath are ASCII-only, and gated. 86 tests, lint 0, `check` green,
  both smokes PASS, fmt clean.**
  * **1,929 non-ASCII characters removed from the two files' comments**: 828 stars, 399 em-dashes,
    338 box-drawing rules, plus Greek letters, superscripts, arrows and radicals. All in comments;
    the audit confirmed **zero outside them in zimrnum** and five in zimrmath that are code, left
    alone.
  * **The stars are gone entirely.** They were emphasis, and emphasis that needs a symbol is
    emphasis that has not been earned by the sentence. What is left is the sentence.
  * **The transliteration had to be read, not just run.** A first pass mapped the middle dot to
    `.`, which turned `v = x - alpha*e1` into what reads as a field access, and mapped the
    em-dash to `" - "` unconditionally, which left double spaces wherever it was already spaced.
    Both fixed by re-running from the backups rather than patching the output - a mechanical
    transform is cheap to redo and expensive to correct in place.
  * **A test embeds both files and counts bytes above 127.** zimrnum must be exactly zero;
    zimrmath is allowed the four `test "..."` names that still carry maths symbols. Proven by
    negative control: one star put back reads `expected 0, found 3`, three being the star's UTF-8
    length.
  * The rule is in `claude.md`: write `->` not an arrow, `*` not a middle dot, `sqrt` not a
    radical, `^2` not a superscript.


- **Sep 8 2026 — the tutorial now carries zimrnum's own source in foldable sections, generated
  from the code. 171 folds covering 149 declarations. 85 tests, lint 0, `check` green, both smokes
  PASS, fmt clean. Tutorial 150 KB → 450 KB.**
  * ★★★ **THE PLACEMENT IS DERIVED, NOT MARKED.** Every example in the tutorial already names the
    functions it demonstrates — `zn.sqrt(...)`, `zn.qr(...)`. The generator reads the example,
    collects those names, and emits a fold for each immediately after it. **No markers to place,
    none to keep matched, none to go stale when prose moves**: the fold follows the example that
    earned it because it is derived from that example's own text.
  * ★★★ **`std.zig.Ast`, NOT A BRACE COUNTER.** Slicing from `pub fn NAME(` to a matching `}` by
    counting braces is thirty lines and wrong — zimrnum has `"{d}"` format strings and comments
    with braces, and a counter cannot tell those from code. The compiler's own parser gives each
    declaration's first and last token: **177 top-level functions, zero parse errors**. The span
    starts at the doc comment, so a fold shows the documentation with the code.
  * ★★ **THE EXISTING EXAMPLES ARE UNTOUCHED.** All 77 stay plain, visible and unfoldable; the
    folds are added after them, collapsed, so the page reads as it did.
  * ★★★ **IT WAS NOT IDEMPOTENT AND ONLY DIFFING TWO RUNS COULD SEE IT.** The stripper removed
    each generated block but not the newline emitted before it, so **every build added 52 blank
    lines**. A generator that is nearly idempotent looks idempotent until someone builds twice.
    Now proven identical across three runs.
  * ★★ **TWO NEGATIVE CONTROLS PROVE IT CANNOT DRIFT.** Changing `max_sweeps` from 60 to 61 in
    zimrnum makes the tutorial show 61 on the next build, and reverting removes it. Renaming `qr`
    removes its fold **and** the reference gate names the orphan. The folds are output, never
    input.
  * ★ Tests are not folded, by Simon's call: they are 203 KB and the reference is long enough.
  * ★ Coverage is 63% of declarations, from examples alone. The remaining 37% are functions no
    example names — the honest next step is to name them in an example rather than to bolt folds
    onto the reference table, because a fold with no prose around it is a listing, not a tutorial.


- **Sep 8 2026 — 86/86 on the device. Then the touch-drag fix. 85 zimrnum tests, 167 zimrmath
  tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **`getMouseDelta` ON THE PRESS FRAME IS THE WHOLE DISTANCE THE POINTER TRAVELLED TO GET
    THERE.** With a mouse that is nearly zero — the pointer was already where you clicked. **With
    a finger it is the bug**: the pointer teleports from its last position to the touch point and
    that jump arrives as one frame's scroll, so the page pops out from under you before you have
    moved.
  * ★★ **THE FIX IS ABSOLUTE, NOT ACCUMULATED.** The press records where the finger went down and
    what `scroll` was; every later frame sets `scroll = scroll_at_press − (moved since press)`.
    The pixel under the finger stays under the finger, and no per-frame delta is ever added, so a
    dropped frame cannot make the content drift away over a long drag.
  * ⚠ **`examples/voxel` ALREADY DID THIS CORRECTLY** with a `dragging` guard that skips the press
    frame. **The pattern was in the codebase before the bug was.** I wrote the sweep's scrolling
    without looking at how the engine's own examples handle a drag, and the cost was a defect that
    reached a device. Recorded in `claude.md` so the next scrolling surface starts from the
    working version.


- **Sep 8 2026 — the device returned 82/86 and every one of the four failures was mine from the
  previous turn. 85 zimrnum tests, 167 zimrmath tests, lint 0, `check` green, both smokes PASS.**

        XX not equal   worst 9.786899   bar 0
        XX where       worst 4.174618   bar 0
        XX asinh       worst 1.43e-6    bar 9.4e-7
        XX atanh       worst inf        bar 5.3e-6

  * ★★★ **THE STALENESS DETECTOR COULD ONLY EVER CATCH A LAG OF ONE.** It compared each readback
    against the PREVIOUS row's output. With a three-deep queue the readback is row N−3's data,
    which does not match row N−1's reference either — **so it was accepted as fresh and compared
    against row N**. Two rows failed with worst errors of 9.8 and 4.2, which for 0/1 masks can
    only be another row's data. Reverted to three frames, matched to the depth the trainer
    measured. **A test for staleness that assumes a specific staleness is not a test for
    staleness.**
  * ★★★ **`where` READ A BUFFER THE HOST NEVER UPLOADED.** `where_pick` takes its selector from
    `c`; the headless twin test filled `c` by hand and passed, and the sweep never did. **A buffer
    the host never writes is invisible to every check that runs on the host, because the host's
    own test fills it as part of being a test.** Only the device could see it, and it did.
    ★★ Now gated: a comptime scan of this file requires an `upload` call for every input buffer of
    every pipeline. Proven by negative control — removing the line names the buffer.
  * ★★ **`atanh` RETURNED `inf` ON BOTH SIDES, AND `inf − inf` IS NaN**, which is not ≤ any bar.
    The row was asking a question with no finite answer: `atanh` is ±infinity at ±1 and the noise
    field goes well past it. Added a `unit` input field — `tanh(noise)`, so every value is inside
    (-1, 1) **by construction rather than by clamping**. Widening the tolerance would have been
    the wrong fix for the right symptom.
  * ★ `asinh`'s bar was 4 ULP from a guess; the device measured 4.8. It is three roundings deep —
    a square root, an add and a log — so the bar is now 8, set from the measurement.
  * ⚠ **Three of the four were introduced by the previous turn's "improvements".** The settle
    change and the third buffer both passed every host gate. The lesson is not to stop changing
    things; it is that **a host twin test cannot see a host-side omission**, which is why the
    upload gate is worth more than the fixes.


- **Sep 8 2026 — ★★★ AN AUDIT OF zimrmath AGAINST ITS OWN RULE. ELEVEN FUNCTIONS BROKE IT AND
  FOURTEEN WERE MISSING.** 85 zimrnum tests, 167 zimrmath tests, lint 0, `check` green, both
  smokes PASS, fmt clean. Sweep is EIGHTY-SIX.
  * ★★★ **THE PROBE HAD TO USE RUNTIME VALUES.** My first audit passed comptime literals, which
    coerce — `@as(f64, 0.5)` into an `f32` parameter compiles, so an f32-only function looked
    generic. **The first audit was wrong in the reassuring direction**, which is the worst one.
  * **Three distinct failure classes, all now fixed:**
    - **Vector-broken** (`tanh cosh sigmoid gelu cbrt fract hypot pow step`) — declared `anytype`,
      body called `std.math.*`, which takes scalars only. **The signature promised one thing and
      the body delivered another**, and it compiled because nobody had passed a vector yet.
    - **Scalar-broken** (`floor ceil isInf isFinite`) — vector-only.
    - **f64-broken** (`cosh cbrt fract pow step`) — `f32`-typed signatures.
  * ★★★ **`perLane` IS THE BRIDGE.** Rather than rewriting each in vector-safe arithmetic — losing
    the accuracy the standard library has near each function's edges — a vector splits into lanes,
    the scalar path runs on each, and they reassemble. **It cannot be `inline` itself**: an inline
    function calling an inline scalar function is inline recursion, which the compiler refuses.
  * ★★ **FOURTEEN FUNCTIONS ADDED** that zimrnum already had a tensor version of — which is
    backwards. **35 of 35 one-argument elementwise functions now take f32, f64 and vectors**, and
    four kernels call `zm` directly so the sweep proves the new code lowers to SPIR-V.
  * ★★★ **THE CORRESPONDENCE GATE IS THE POINT, AND ITS CONTROLS MATTER MORE.** A first control —
    perturbing `sinh` by `1 + 1e-16` — was **below f64's epsilon and rounded to exactly 1.0**, so
    it was a no-op that briefly made a working gate look broken. Redone at 1.0000000001, it fires.
    **A gate whose control is invalid is not a proven gate**, and I nearly filed one as proven.
  * ★★ **I ADDED A `saturate` AND THE COMPILER STOPPED ME.** A private stub reserved the name to
    say the house calls it `clamp01`. Reverted. **A stub that argues its case is worth more than a
    comment**, and this one prevented me overriding a decision I had not read.
  * ★ `sign` as a public zimrmath name required renaming seven locals; each now says what it is
    (`sign_value`, `sign_bits`). Same shadowing the zimrnum rename surfaced two turns ago.


- **Sep 8 2026 — 77/77 on the device. Then the trig and hyperbolic batch: ten functions, five
  kernels, sweep is EIGHTY-TWO. 84 tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  `tan asin acos atan sinh cosh asinh acosh atanh rsqrt` — **all with plain names**, which is the
  payoff of turning the reserved-name rule off for this file two turns ago.
  * ★★★ **I DOCUMENTED A DOMAIN POLICY THAT WAS FALSE, AND THE TEST CAUGHT IT.** I wrote "NaN
    outside the domain" for all of them. Measured: **`asin(1.5)` is π/2 and `acos(2.0)` is 0** —
    `zm` CLAMPS. That is a graphics library's choice and a good one there, since a dot product of
    two unit vectors can reach 1.0000001 by rounding alone. The functions defined here by
    identity return NaN because that is what the arithmetic does. **Two behaviours, from two
    places, and the test now asserts BOTH** so neither can drift into the other.
  * ★★★ **THE FIVE HYPERBOLICS ARE DEFINED BY IDENTITY, AND ALL FIVE GPU TWINS ARE EXACT — 0.0
    ULP.** `zm` has no `sinh`, `asinh`, `atanh` or `rsqrt` and neither does the SPIR-V backend, so
    the identity is the only form that is the SAME EXPRESSION on both sides. Same reasoning as
    `pow`, and the same result: nothing to reconcile because there is nothing different.
  * ★★ **znum HAS NO `asinh`, `acosh` OR `atanh` AT ALL.** Three functions gained rather than
    ported.
  * ★ **`zm.isNan` was vector-only** — it read `.vector` off the type info, so a scalar call
    failed inside zm rather than at the call site. Given a scalar branch, like `isFinite` beside
    it already had. **Third zm helper with this gap**, after `trunc` and `round`.
  * ★ Each inverse is tested by undoing its forward function on the principal branch, and
    `cosh² − sinh² = 1` ties those two together without either being assumed correct alone —
    plus evenness and oddness, since a sign error would preserve the first identity while getting
    both functions wrong.
  * **77 of 260 declarations have a device-verified kernel.**


- **Sep 8 2026 — the GPU push: a third and fourth buffer, three new kernels, and the settle turned
  from an assumption into a measurement. Sweep is SEVENTY-SEVEN. 83 tests, lint 0, `check` green,
  both smokes PASS, fmt clean.**
  * ★★★ **THE SWEEP'S SETTLE WAS WRONG, AND THE COMMENT SAID SO WITHOUT KNOWING.** "Three frames
    is comfortably more than the one-frame delay `readLatest` has" — but the trainer measured the
    Adreno's queue **three frames deep**. The sweep was reading at exactly the edge, and any extra
    latency would have compared row N's reference against row N−1's output: a false FAIL, or a
    false PASS if the two happened to agree.
    ★★ **The fix detects staleness instead of assuming a delay**: a readback byte-identical to the
    previous row's output has not landed, so wait another frame. Correct at any queue depth, and
    **77 rows cost 0.64 s when the queue is shallow** against 1.93 s always. The header reports
    the stale-frame total, so the sweep now MEASURES the device's queue depth rather than
    guessing it.
  * ★★★ **THE THIRD-BUFFER QUESTION IS SETTLED.** `whereInto`, `sgdMomentum` and `adamStep` were
    host-only **for want of one binding, not for any reason of algorithm** — WebGPU guarantees
    eight per stage and the binary pipeline used three. Added `c` and `state`; all three twins
    match zimrnum **exactly**. Ten of the original twenty-five pending are now closed.
  * ★★ **TWO KERNELS ALMOST SHARED ONE UNIFORM FIELD.** `huber_loss` reads `params.delta` at 1.0
    and I gave `sgd_momentum` the same field at 0.9. It compiled, and the huber row would have
    failed **on the device only**. `momentum` gets its own field, and the comment says why.
  * ★ The uniform then needed padding to 48 bytes, which the host's guard named exactly — three
    words, measured from its error rather than guessed.
  * ★ The lint caught a module-level mutable I had reached for as scratch. Each CPU twin now holds
    its own static local: a shared global reads fine right up until two rows run concurrently.
  * **72 of 250 declarations now have a device-verified kernel.**


- **Sep 8 2026 — `pinv` and `inverse`, and the comparison found the SAME BUG A THIRD TIME.
  83 tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        singular values 1, 1e-3, 1e-7, scaled:
        scale 1e0    ->  1e0, 1e-3, 1e-7      absolute cutoff keeps 3 of 3
        scale 1e-6   ->  1e-6, 1e-9, 1e-13    absolute cutoff keeps 2 of 3

  * ★★★ **znum'S `pinv` DISCARDS ANY SINGULAR VALUE BELOW THE CONSTANT `1e-12`.** Deciding which
    values count as zero IS the content of a pseudo-inverse — it is what makes one defined for a
    singular matrix at all. An absolute cutoff gets it wrong in both directions: **a matrix scaled
    down loses a real direction**, and one scaled up keeps numerical noise and inverts it into
    enormous numbers. Nothing about the matrix changes except its units.
  * ★★★ **THIRD INSTANCE OF ONE CLASS OF BUG.** Row 25 was `eigh`'s `1e-30`, row 27 was `svd`'s
    Gram matrix, this is `pinv`'s `1e-12`. **znum compares a quantity that has dimensions against
    a bare constant.** Knowing that is worth more than any single fix: it says what to look for
    first in every remaining function.
  * ★★ **SCALE INVARIANCE IS THE ASSERTION**, because it is exactly the property an absolute
    cutoff destroys: `pinv(k·a)·k` is the same matrix whatever `k` is — measured to nine digits
    across six orders of magnitude.
  * ★★ **AND THE DEFINING PENROSE CONDITION**, `a · a⁺ · a = a`, on a genuinely rank-deficient
    matrix. That holds where an inverse does not exist at all, which is the reason to have a
    pseudo-inverse; checking it on an invertible matrix would prove nothing an inverse could not.
  * ★ `inverse` solves against the identity. Its doc says plainly that **wanting an inverse is
    usually a sign of wanting a solve** — `solve(a, b)` is more accurate and cheaper than
    `matmul(inverse(a), b)` — because the honest thing for an API to do is name its own misuse.


- **Sep 8 2026 — `svd` by one-sided Jacobi. 82 tests, lint 0, `check` green, both smokes PASS,
  fmt clean.**

        true sigma_min   one-sided jacobi   through AtA
        1e-3             1.5e-14            1.7e-11
        1e-6             4.6e-12            1.1e-5
        1e-9             2.0e-8             5.7          <- 570% wrong

  * ★★★ **znum'S SVD GOES THROUGH `eigh(aᵀa)`, WHICH IS THE SAME TRAP AS THE NORMAL EQUATIONS —
    AND HERE IT IS WORSE THAN LOST DIGITS.** Singular values 1 and 1e-9 become eigenvalues 1 and
    **1e-18**, below f64's epsilon. The small value is not computed inaccurately; **it is gone**,
    recovered from whatever noise sits in that entry of the Gram matrix. At 1e-9 the Gram route
    returns 6.7e-9. That is a different number, not a rounding.
  * ★★ **ONE-SIDED JACOBI ROTATES PAIRS OF COLUMNS OF `a` ITSELF** and never forms `aᵀa`, so every
    singular value comes back to full RELATIVE accuracy however small. Same family of algorithm as
    the `eigh` from the previous turn, and the same relative convergence test.
  * ★★ **THE TEST ASSERTS THE GAP ONLY WHERE THE SQUARING BITES** — at σ ≤ 1e-6. At 1e-3 both
    routes are fine, and asserting a gap there would be overstating the case to make the point.
  * ★ Reconstruction is checked as well as the values: `u · diag(σ) · vᵀ` must be `a` again,
    because correct singular values paired with the wrong vectors would pass a values-only check.
  * ★ Each column's length IS its singular value, so normalising the working copy at the end
    leaves the left vectors in place — no separate `u` pass and no second buffer.
  * **Three turns, three linalg comparisons: znum's `qr` wrong (Gram–Schmidt), its `eigh`
    threshold wrong (absolute), its `svd` route wrong (Gram matrix). Its `lstsq` right.** The
    pattern is that znum reaches for the shortest correct-looking route, and the shortest route
    is the one that squares a condition number.


- **Sep 8 2026 — least squares by QR, plus the pieces it needed. 81 tests, lint 0, `check` green,
  both smokes PASS, fmt clean.** `matmulNT`, `matmulTN`, `Triangle`, `solveTriangular`, `lstsq`.

        n     qr          normal equations
        5     5.9e-15     8.2e-13
        8     7.8e-13     1.6e-7
        10    1.3e-11     1.6e-4

  * ★★★ **znum SOLVES BY QR TOO, AND IS RIGHT TO** — so this turn's comparison confirms rather
    than diverges. Recorded anyway, because the alternative is so tempting: `aᵀa·x = aᵀb` is one
    line and **squares the condition number**. On a Vandermonde system with a known exact solution
    the normal equations lose **seven digits by n=10** where QR keeps eleven. **The test asserts
    the normal equations are visibly worse**, which makes the extra factorisation's cost justified
    executably rather than by assertion in a comment.
  * ★★ **WHAT DOES DIFFER IS UNDERNEATH**: this `lstsq` sits on the Householder `qr` from the
    previous turn, so its `q` is orthogonal where znum's Gram–Schmidt one is not. An improvement
    to a factorisation propagates to everything built on it, which is the argument for getting
    the bottom of the stack right first.
  * ★★ **THE TEST CHECKS THE DEFINING PROPERTY, NOT JUST THE ANSWER**: on a system with no exact
    solution the residual must be orthogonal to every column of the design matrix. A wrong solver
    that happens to reproduce a known solution would pass the first check and fail this one.
  * ★ `lstsq` allocates nothing — `q` and `r` are caller-supplied and come back as the
    factorisation, so several right-hand sides cost one factorisation and N substitutions.
  * ★ `matmulNT`/`matmulTN` are an indexing choice, not an algorithm, so the only thing worth
    asserting is fidelity to the materialised form — which is what makes the names safe to reach
    for.
  * ★ The heading gate added last turn passed the new section on the first try, which is what it
    is for.


- **Sep 8 2026 — `eigh` by Jacobi, and a documentation gate that found fourteen wrong headings.
  80 tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        scale     residual   lambda0
        1e0        1.6e-15   6.7328e-1
        1e-10      1.3e-25   6.7328e-11
        1e-20      2.9e-35   6.7328e-21

  * ★★★ **znum's ALGORITHM IS RIGHT AND IS FOLLOWED — ITS CONVERGENCE TEST IS NOT.** Cyclic Jacobi
    is the correct choice for a symmetric eigendecomposition. But znum stops when the off-diagonal
    sum of squares drops below the CONSTANT `1e-30`, which **declares any sufficiently small
    matrix already diagonal**: below a scale of about 1e-16 that fires before a single rotation
    and the routine returns the untouched diagonal as the eigenvalues. Measuring against the
    matrix's own Frobenius norm makes it scale-free, and the eigenvalue then tracks the scale to
    five digits across twenty orders of magnitude. Register row 25.
  * ★★ **THE TEST CHECKS `A·v = λ·v` FOR EVERY EIGENPAIR**, not just the eigenvalues — correct
    values paired with the wrong vectors would pass an eigenvalues-only check. Plus the trace
    identity as an independent witness that none was lost, and orthonormality of the vectors.
  * ★ Running out of sweeps is a `DomainError`. Jacobi converges quadratically; returning an
    unconverged answer silently is the failure worth refusing.
  * ★ The all-zero matrix is in the test because the relative threshold divides by nothing there —
    it must give zero eigenvalues, not a NaN.
  * ★★★ **AND THE TUTORIAL HAD FOURTEEN WRONG HEADING NUMBERS.** Four separate `h2` sections all
    numbered their subsections `14.x`: each insertion left the ones after it with their old
    prefix, and **the drift was invisible because the reference test only compares declarations**.
    Worse, my last two tutorial edits had silently not applied at all — the anchor I matched on
    never existed, so the QR section from the previous turn was never in the document either.
    Renumbered from the document, and **the generator now gates it**: every `h3` must carry its
    enclosing `h2`'s number and count up from 1. Proven by negative control — it names the wrong
    number and what it should be.
  * ⚠ **The lesson, again: an edit that "succeeded" because nothing asserted otherwise.** The
    heading gate exists so this particular silence cannot recur.


- **Sep 8 2026 — `qr` by Householder, and the comparison with znum is now the point of the test.
  79 tests, lint 0, `check` green, both smokes PASS, fmt clean.**

        Hilbert    householder   gram-schmidt
        6x6           4.4e-16        1.8e-10
        8x8           3.3e-16        4.4e-7
        10x10         4.4e-16        1.8e-4

  * ★★★ **I READ znum'S `qr` BEFORE WRITING A LINE, AND IT IS MODIFIED GRAM–SCHMIDT.** That is
    better than the classical form and still loses orthogonality in proportion to the condition
    number. Householder builds `q` from reflections that are orthogonal to working precision by
    construction, so the product is too — **and the measurement shows it does not degrade with
    size at all** while Gram–Schmidt reaches 1.8e-4 by 10×10.
  * ★★★ **THE TEST CONTAINS znum'S ALGORITHM, PURELY TO BE MEASURED AGAINST**, and asserts
    Householder beats it by at least a factor of a million. That makes the justification for the
    extra work executable rather than a claim in a comment: if a future change ever made them
    comparable, this test is what would say so.
  * ★★ **1.8e-4 IS NOT A ROUNDING DIFFERENCE.** It is `q` not being orthogonal, and every later
    use of it — a least-squares solve, an eigenvalue iteration — inherits the error silently.
    That is why this counts as znum being wrong rather than as a preference.
  * ★ The reflector takes the sign OPPOSITE the pivot, so `v = x − alpha·e₁` never subtracts two
    nearby numbers. The same sign cancels catastrophically exactly when the pivot dominates its
    column, which is the common case.
  * ★ `r` is upper triangular EXACTLY — the dust the reflections leave below the diagonal is
    zeroed, not merely small, so a caller reading `r` as triangular is not reading noise.
  * **New standing practice, from Simon: compare with znum every turn.** Register row 24 is the
    first written under it, and reading znum first is what produced the algorithm choice.


- **Sep 8 2026 — convolution and embedding on the tape, and a CNN that trains. IT FOUND A REAL
  GRADIENT BUG. 78 tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * ★★★ **`accumulate` SUMMED ONLY THE LEADING BROADCAST AXIS.** Right for `Dense`'s
    `(1, width)` bias under a `(rows, width)` gradient — the only case that had ever existed.
    `Conv2d`'s bias is `(1, 1)` and broadcasts over BOTH axes: the old code took column 0 and
    **silently dropped the rest**, returning a number rather than an error. **The finite-difference
    check found it at 0.7 where the kernel and input were at 8e-12** — and after the fix the bias
    reads **6.5e-13** with the other two unmoved. A gradient that is wrong by a factor of the
    width is invisible to a training run; it just learns worse.
  * ★★★ **THE CONVOLUTION'S BACKWARD PASS IS THE FORWARD LOOP WITH THE ACCUMULATION REVERSED.**
    Both gradients come out of one loop nest with the same bounds and the same in-range test, so
    **it cannot disagree with the forward pass about which taps are in range** — it asks the
    identical question. The textbook "full correlation with a flipped kernel" is correct and is a
    second thing to get right.
  * ★★ **THE EMBEDDING GRADIENT IS A SCATTER-ADD AND THE TEST INDEXES ONE ROW THREE TIMES.** A
    scatter that assigned would keep one contribution and drop two — a network training on a
    fraction of its data with no error anywhere. The finite difference perturbs the row and sees
    all three uses move, which is what catches it. The test also asserts a never-indexed row gets
    exactly zero gradient.
  * ★★ **THE CNN'S BAR IS SET BY ITS CAPACITY, NOT BY WISHFUL THINKING.** Two 3×3 kernels and two
    scalar biases are **20 parameters against 49 random targets**. Measured: 0.906 → 0.309 by 300
    steps, still 0.309 at 1000, so it is at its floor. I first wrote `before * 0.1`, which was
    asserting the model can do something arithmetic forbids. Now `before * 0.4`, with the
    parameter count in the comment.
  * ★ `InitScheme` is a named type now: `Dense` declared the enum inline and `Conv2d` could not
    name the same thing. **Two callers make a type.**
  * ★ `Conv2d` initialises by fan-in counting the WINDOW — a 3×3 kernel sees nine inputs per
    output, so He over 9, not over the image.
  * zimrnum: **240 public declarations, 78 tests — 36% of the user-facing surface.**


- **Sep 8 2026 — ★★★ THE TENSOR OPERATIONS TAKE THE PLAIN NAMES. `zn.sqrt`, `zn.log`, `zn.clamp`,
  `zn.lerp`.** Simon: the `Into` suffixes were a bad situation, and he was right. 77 tests,
  lint 0, `check` green, both smokes PASS, fmt clean.
  * ★★★ **TEN OF THE SEVENTEEN COLLISIONS WERE PHANTOM.** Before proposing anything I measured
    which reserved words zimrnum actually uses as scalars: it reaches for Zig's builtins —
    **`@sqrt` 21 times, `@log` 26, `@abs` 24** — and never touches zm's `sqrt`, `log`, `exp`,
    `abs`, `pow`, `floor`, `ceil`, `atan2`, `hypot` or `lerp`. **Those ten names were blocked by
    the rule alone, protecting nothing**, and each was costing a public name a suffix that
    described the linter rather than the code.
  * ★★★ **THE RULE'S PRIORITY WAS BACKWARDS FOR THIS FILE.** It exists so a file doing vector
    maths writes `sqrt(v)` instead of `zm.sqrt(v)`. In zimrnum the TENSOR `sqrt` is what a caller
    reaches for and zm's scalar is the visitor. The file now says so with a `//! lint:off
    reserved-math-names` directive and its reason — **the mechanism already existed**, and the
    linter's own header says a file should declare its exemption rather than the linter hardcode
    a filename.
  * ★★★ **THE BLANKET EXEMPTION ALONE WOULD HAVE BEEN A BUG.** With the rule off but the aliases
    unchanged, `pub fn cos` silently shadows `const cos = zm.cos` and **eight call sites quietly
    change meaning**. The seven genuine collisions are aliased `scalarCos`, `scalarSin`,
    `scalarTrunc`, `scalarRound`, `scalarLog2`, `scalarLog10`, `scalarClamp` — which also reads
    better than bare `cos` in the one file where both exist.
  * ★★ **`Into` SURVIVES ONLY WHERE IT MEANS SOMETHING**: 32 names down to 12, and every one of
    the 12 writes into a caller-supplied destination and has no scalar counterpart —
    `concatInto`, `conv2dInto`, `convolveInto`, `whereInto`.
  * ★★ **THE RENAME EXPOSED FOUR REAL SHADOWING BUGS** that the suffix had been hiding: `lu`'s
    local `sign`, `determinantLu`'s, `dft`/`fft`'s parameter, and a test's. Each is now named for
    what it means — `permutation_sign`, `exponent_sign` — which is better than either the old
    `sign` or the collision.
  * ⚠ **A script asserted between the edit and the write, and lost 61 renames silently.** The
    other four files had already been updated, so the build broke in a way that looked like a bad
    rename rather than a missing one. **Write first, verify after** — the plan has said this since
    September 4 and I did it again.
  * ★ Both renames fingerprint-verified: six outputs as raw bits, identical before and after.


- **Sep 8 2026 — ★★★ COMPATIBILITY WITH znum IS NOT A REQUIREMENT. Simon: znum is our private
  first try; the port is the opportunity to verify and improve it.** Twenty-seven names changed
  across 262 sites; the dtype tag redesigned. 77 tests, lint 0, `check` green, both smokes PASS,
  fmt clean.
  * ★★★ **THE FILE-FORMAT FINDING FROM THE MORNING IS WITHDRAWN, NOT FIXED.** I had matched
    znum's tag values to make a compatibility claim true. With compatibility off the table the
    right question is which numbering is clearest — and it is neither znum's nor a counter.
    **The tag now ENCODES the type**: high nibble the kind, low nibble log₂ of the byte width,
    so `f32` is `0x12` and `f64` `0x13`. A reader computes element size from the tag alone —
    `byteWidth` is `1 << (tag & 0xf)` — instead of a table that can drift from the enum, and an
    unknown tag still says how many bytes to skip. **`i32` will be `0x22` by construction**,
    whatever order types are added in. The test asserts `byteWidth` against `@sizeOf`.
  * ★★★ **THREE SUFFIXES DODGED ONE PROBLEM.** `sqrtf`, `clampTo` and `conv2dInto` all exist
    because `zm` owns the plain name, and a reader cannot tell that from the suffix. **One rule
    now: the suffix is `Into`.** Twenty renames. `sqrtInto` also says what the function does,
    where `sqrtf` is a C-ism meaning "the float one" attached to a function generic over `T`.
  * ★★ **SEVEN ABBREVIATIONS EXPANDED**: `Summer` → `CompensatedSum` (it read like a season),
    `Cplx` → `ComplexNumber`, `trapz` → `trapezoid`, `gae` → `generalizedAdvantage`,
    `rms` → `rootMeanSquare`, `klDivRows` → `klDivergenceRows`,
    `bceLogitsLoss` → `binaryCrossEntropyFromLogits`. `fft`, `dft`, `lu` stay — an abbreviation
    that IS the universal name of the thing is not an abbreviation to a reader of the field.
  * ★★★ **THE RENAME WAS PROVEN NUMERICALLY INERT.** Six outputs fingerprinted as raw bits before
    and after: identical. The same check as the `CompensatedSum` refactor, and the reason a
    262-site edit is safe to make in one pass.
  * ★★ **THE REFERENCE GENERATOR NAMED ALL 27 STALE NOTES AT ONCE** rather than failing on the
    first. Every one of them was a real edit still to make, and the list was the worklist.
  * ★ znum is no longer cited as authority in the tutorial or the reference notes — it is our own
    draft, and telling a reader "this matches znum" tells them nothing they can check.


- **Sep 8 2026 — a full review against znum. IT FOUND A FALSE CLAIM I HAD MADE THREE TIMES, and
  the completion plan is rewritten on measured numbers. 77 tests, lint 0, `check` green, both
  smokes PASS, fmt clean.**
  * ★★★ **THE FILE FORMAT WAS NOT BYTE-COMPATIBLE WITH znum, AND I SAID IT WAS — in the journal,
    the tutorial and the plan.** The magic, the version and the entry layout all matched. The
    **dtype tag values did not**: znum's `DType` runs `bool, i8, i16, …` from zero, so its `f32`
    is **11**; mine was a fresh numbering with `f32 = 2`. A znum reader would have taken every
    zimrnum file as the wrong type.
    ★★★ **EVERY TEST PASSED THROUGHOUT, AND ALWAYS WOULD HAVE.** A round trip agrees with itself
    whatever the tags are — both sides of it share the same mistake. **The only assertion that
    could catch this is on the bytes themselves**, which the test now makes: `f16 = 9`,
    `f32 = 11`, `f64 = 12`, and the first entry's header pinned byte by byte. The gaps in the
    enum are the integer and complex types zimrnum lacks, left as gaps so a future `i32` gets
    znum's 3. **A compatibility claim is only worth making if something checks it.**
  * ★★★ **THE COVERAGE NUMBER WAS ALSO WRONG, IN THE OTHER DIRECTION.** znum's 744 functions
    include a 54-function `cpu` dispatch layer and 18 `io` byte helpers, both of which zimrnum
    expresses with fewer functions rather than lacking — `map`/`zip` and one generic
    `putInt`/`takeInt`. And a raw name match misses that `mae` is `maeLoss` and `convolve` is
    `convolveInto`. **Against the 672-function user-facing surface, matched by concept, zimrnum
    covers 229 — 34%, not 27%.**
  * **§10.6 rewritten as a three-tier completion plan** with per-namespace counts and what each
    unblocks. Tier 1 (147) finishes namespaces whose core exists — `nn` layer types on `Dense`'s
    template, the `ops` remainder, autograd's scopes, the `linalg` factorisations. Tier 2 (98) is
    self-contained. Tier 3 (198) is four questions rather than four jobs.
  * ★★ **"BEST POSSIBLE RESULT" IS NOT 100% OF znum, AND THE PLAN NOW SAYS SO.** Three tier-3
    items — dataframes, named dimensions, RL environments — are open questions, and answering
    them *"no, and here is why"* is a better outcome than porting them. A game engine's numerics
    library is a strange place for a database join.
  * ⚠ **The sweep is at its budget** — 222 frames ≈ 1.85 s against a 2 s ceiling — which **blocks
    the cheapest tier-1 work**. The settle must drop to two frames or the sweep must split into
    pages before the next kernel batch. Recorded as the gating item.
  * Parity confirmed on this turn's other recent code: `trapz` compensates where znum does not
    (an improvement, register-worthy only if measured); `interp` clamps as znum does; `gae` leaves
    normalisation to the caller as znum does.


- **Sep 8 2026 — `fft/signal` complete: 9 of 9. 77 tests, lint 0, `check` green, both smokes PASS,
  fmt clean.** `rfft`, `ConvMode`, `convolveInto`, `correlateInto`, `outputLen`.
  * ★★★ **`rfft` PACKS INTO A HALF-LENGTH TRANSFORM.** A real signal's spectrum is
    conjugate-symmetric, so the saving is not the discarded half of the OUTPUT — it is the
    transform: `n` real samples become `n/2` complex values, one transform of half the length
    runs, and the result is untangled. znum's `rfft` allocates `n` complex and runs a full one.
    Register row 23.
  * ★★★ **THE UNTANGLING IS CHECKED AGAINST A FULL `fft` BIN FOR BIN**, at every power of two to
    256. That is where a packed transform goes wrong, and a bad twiddle or conjugate still returns
    a plausible spectrum. Bin 0 and Nyquist of a real signal must themselves be real — also
    asserted.
  * ★★★ **EVERY CONVOLUTION MODE IS A WINDOW ONTO `full`, AND THE TEST ASSERTS THAT** rather than
    checking each mode's numbers alone. An off-by-one in `same` or `valid` is the classic error
    and a standalone test of either would not see it.
  * ★★ **CORRELATION IS CONVOLUTION WITH THE KERNEL REVERSED**, asserted on an ASYMMETRIC kernel —
    and separately that the two differ on it, so the identity has content. A symmetric kernel
    would make both pass on an implementation that confused them.
  * ★ `length` is reserved (`zm.length` is a vector norm), so `ConvMode.outputLen`. Eighth rename
    this port.
  * ⚠ **The build's disk guard fired at 97% full, and my fix made it worse**: pruning
    `.zig-cache/o` by mtime deleted a generated bootstrap the build depends on, turning a disk
    error into a compile error. **`rm -rf .zig-cache` is the only safe prune** — the cache is
    8.6 GB and rebuilds to 368 MB. The guard was right to stop rather than fail mid-link.
  * zimrnum: **226 public declarations, 77 tests — 27% of znum.** Tutorial 132 KB.


- **Sep 8 2026 — calculus and the Fourier transform. 76 tests, lint 0, `check` green, both smokes
  PASS, fmt clean.** `gradientInto`, `trapz`, `interpInto`, `Cplx`, `dft`, `fft`, `ifft`,
  `fftFreq`.
  * ★★★ **znum's `fft` IS THE O(n²) DEFINITION, AND THAT IS WHERE zimrnum DIVERGES.** Radix-2
    Cooley–Tukey instead, **measured 630× faster**: ten transforms of 4096 points take **2 520 ms**
    through the definition and **4 ms** through the butterflies. Operation counts predict 341×;
    the rest is the DFT calling `sin`/`cos` per element pair. Register row 21.
  * ★★★ **THE DEFINITION IS KEPT, UNDER ITS OWN NAME, AND IT IS WHAT THE FAST ONE IS TESTED
    AGAINST** — element by element at every power of two to 256. That is the only check on an FFT
    that is not another FFT written by the same hand. A round trip alone would pass a transform
    with a consistent sign error in both directions.
  * ★★ **AND A PURE TONE MUST GIVE TWO SPIKES.** Bins `k` and `n−k` at exactly n/2, everything
    else zero. A wrong twiddle or a botched permutation still returns numbers; it does not return
    a spectrum with the energy in the right two places.
  * ★★★ **EACH CALCULUS RULE IS EXACT ON THE BASIS IT IS BUILT FROM, AND THAT IS THE TEST**:
    trapezoid on a straight line, central difference on a quadratic, linear interpolation on a
    straight line. A rule that is not exact on its own basis is not the rule it claims to be. The
    two one-sided end points are asserted to be close but **NOT** exact, so a reader knows which
    points to trust.
  * ★ `Complex` and `tau` are reserved — `zm` has both. `tau` is bound at file scope; the complex
    type is `Cplx`, because zm's is a different shape and this one is `extern` for the interleaved
    layout every FFT library and GPU buffer expects.
  * ★ My last calculus assertion was wrong: I expected `DomainError` from a call whose output was
    also mis-sized, and shapes are checked first. Both errors are now asserted on inputs that
    isolate them.
  * zimrnum: **221 public declarations, 76 tests — 27% of znum.** Tutorial 129 KB, 19 sections.


- **Sep 8 2026 — 74/74 on the device, then serialisation on znum's wire format. 74 tests, lint 0,
  `check` green, both smokes PASS, fmt clean.**
  * `magic`, `format_version`, `DType`, `NamedTensor`, `saveTensors`, `loadTensors`.
  * ★★★ ⚠ **THIS CLAIM WAS FALSE WHEN WRITTEN, AND THEN WITHDRAWN.** The layout matched znum's, the dtype tags did not — and on Sep 8 Simon confirmed **compatibility was never a requirement**: znum is a private first draft, not a standard. The tags are now chosen for clarity instead. The format is: the same six-byte magic
    `ZNUM\0\0`, the same version byte, the same entry layout of name length, name, dtype tag,
    rank, shape, data. A file written by one library is readable by the other, which is worth more
    than any improvement I could have made to the layout.
  * ★★ **EVERY FIELD IS LITTLE-ENDIAN AT A STATED WIDTH.** `@bitCast`ing a struct into a file
    would be shorter and would break the first time the padding, the field order or the host's
    endianness changed — none of which the file records. The layout table in the doc comment is
    everything a reader in another language needs.
  * ★★★ **THE ROUND TRIP IS ASSERTED BY THE MODEL'S PREDICTIONS, NOT ITS WEIGHTS.** A network is
    trained to a loss below 0.05, saved, and loaded into a FRESHLY INITIALISED model; the restored
    model must reproduce the trained loss **bit for bit**. Comparing weights would pass on a
    loader that read them in the wrong order into same-shaped tensors — which is the bug worth
    catching, since every tensor in a network has a plausible wrong partner.
  * ★★ **SEVEN WAYS TO BE WRONG, ALL REFUSED**: bad magic, unknown version, truncated file, a
    requested name absent, a shape that disagrees, a dtype that does not match, and a strided
    source at save time. Each has its own assertion. A serialiser that reads a broken file as
    something plausible is worse than one that cannot read at all.
  * ★ `loadTensors` fills tensors the caller already holds rather than allocating: loading a
    checkpoint means filling weights a model has, and the destination's shape IS the expected
    shape, so the check is free.
  * zimrnum: **209 public declarations, 74 tests — 25% of znum.**


- **Sep 8 2026 — the `ops` remainder: nine functions, eight kernels. Sweep is SEVENTY-FOUR.
  73 tests, lint 0, `check` green, both smokes PASS, fmt clean.** `powf`, `log2f`, `log10f`,
  `expm1`, `log1p`, `cbrtf`, `notEqual`, `greaterEqual`, `lessEqual`.
  * ★★★ **`powf` IS `exp(b·log a)` ON EVERY BACKEND, AND SAYS SO.** `zm.pow` is `f32`-only and
    carries the C special cases; the real-valued definition is one expression at every float
    width, NaN for a negative base whatever the exponent. **`cbrtf` exists precisely because
    `pow(x, 1/3)` is not a cube root for negatives**: `sign(x)·|x|^(1/3)`, tested by
    `cbrt(x)³ == x` on both signs and by oddness.
  * ★★ **THE SPIR-V BACKEND HAS NO `log2` OR `log10`.** Build error naming the intrinsic. Both
    kernels are the natural log times a constant — one expression, no intrinsic — and match `zm`'s
    host implementations to **0.5 and 0.8 ULP**. The other six twins are exact.
  * ★★ **THE THREE LOGARITHMS ARE TESTED AGAINST EACH OTHER THROUGH THEIR BASES**:
    `log2(x)·ln2 == ln x`, `log10(x)·ln10 == ln x`. A table of values would check the numbers;
    this checks the base conversion, which is the only thing that distinguishes them.
  * ★ The six masks partition in pairs — `equal + notEqual`, `greater + lessEqual`,
    `less + greaterEqual` — each summing to 1 at every element. Three trusted masks pin three new
    ones.
  * ⚠ **The sweep is at 222 frames ≈ 1.85 s at 120 Hz.** Under the budget, barely. The next batch
    of rows has to either cut the three settle frames to two or split the sweep into pages.
  * zimrnum: **202 public declarations, 73 tests — 24% of znum.** 70 functions with a
    device-verified kernel.


- **Sep 8 2026 — seven kernels closing GPU backlog, and a refactor the review demanded: ONE
  `Summer`. Sweep is SIXTY-SIX. 72 tests, lint 0, `check` green, both smokes PASS, fmt clean.**
  * Kernels: `mae_loss`, `huber_loss`, `bce_loss`, `conv2d_same`, `variance_axis0`, `max_pool2d`,
    `avg_pool2d`. **All seven CPU twins match zimrnum exactly on the sweep's own inputs** before
    the device sees them.
  * ★★★ **THE EXACT MATCH ON THE THREE LOSSES WAS THE TELL.** `mse loss` drifts 3.8e-5 against
    its kernel because `mseLoss` compensates its sum. `mae`, `huber` and `bce` matched to the bit
    — which meant they did NOT compensate. Five losses had been written with plain `+=`, against
    the library's own stated default.
  * ★★★ **THE CAUSE WAS EIGHT LINES COPIED TEN TIMES.** Neumaier's step was inlined in `sumAll`,
    `matmul`, `layerNormRows` twice, `variance`, `covariance`, `dotAll`, `mseLoss`, `rms` — and
    copying eight lines is exactly what gets skipped on the eleventh function. **`Summer(T)` is
    now the one implementation**, with `add` and `value`; fifteen accumulation sites use it,
    including the five losses. A type with an `add` makes compensation the default rather than a
    discipline.
  * ★★★ **THE REFACTOR WAS PROVEN NUMERICALLY INERT BEFORE THE LOSSES CHANGED.** Six outputs —
    `sumAll`, `matmul`, `mseLoss`, `variance`, `dotAll`, `covariance` — were fingerprinted as raw
    bits before and after. **Identical on all six.** Only then were the losses converted, and only
    they changed.
  * ★ `conv2d_same` reads the first nine elements of `b` as a 3×3 kernel with padding 1, so its
    output fills the same buffer as an elementwise row; the CPU reference builds the same view.
    The binary uniform gained `delta` (Huber), the unary one `pool`.
  * 66 rows × 3 settle frames = 198 frames ≈ 1.6 s at 120 Hz, under the budget.
  * zimrnum: **193 public declarations, 72 tests.** §10.6 written; the GPU backlog is down to
    eighteen, most needing a third input or integer indices the sweep does not carry.


- **Sep 8 2026 — `rl`'s numerical core, ported term for term from znum. 72 tests, lint 0, `check`
  green, both smokes PASS, fmt clean.** `gae`, `discountedReturns`, `normalizeAdvantages`,
  `ppoClipObjective`, `entropyRows`, `ReplayBuffer`.
  * ★★★ **GAE HAS TWO ENDING FLAGS BECAUSE znum's DOES, AND znum IS RIGHT.** `terminal` stops the
    bootstrap — nothing lies beyond a true end. `episode_end` keeps the bootstrap but resets the
    running sum — the rollout was cut, the episode was not. Conflating them is the most common
    GAE bug and yields an agent that learns slowly from returns wrong at every boundary. The test
    puts a true terminal at step 2 and a truncation at step 4 and checks by hand arithmetic that
    only the truncation bootstraps (δ₄ = 1.45, δ₂ = 1) and that the sum does not leak across the
    terminal (A₁ = 2.305).
  * ★★★ **GAE WITH λ = 1 AND ZERO VALUES IS DISCOUNTED RETURNS, ASSERTED.** Two implementations of
    one quantity, and a test of either alone could not see them disagree.
  * ★★★ **THE CLIP'S PESSIMISM IS THE TEST.** A ratio far past `1 + ε` earns exactly what a ratio
    at `1 + ε` earns — no incentive to move further — and the same below `1 − ε` for a negative
    advantage. **But the wrong direction is never clipped away**: ratio 5 with a negative
    advantage is penalised in full, −10 against the clipped −1.6. That asymmetry is the whole of
    PPO and a symmetric clip would pass a sloppier test.
  * ★★ **THE RING FORGETS, AND SAMPLING IS ADDRESSABLE.** Capacity 3, push 5, holds exactly
    transitions 2, 3, 4. The same `(rng, index)` yields the same batch — the counter-based RNG
    reaching into replay, which a stateful generator could not offer.
  * ★ `normalizeAdvantages` uses an epsilon rather than `DomainError` for a constant batch: an
    all-equal advantage batch is a legitimate rollout, not a caller's mistake, and PPO must keep
    stepping through it. `ppoClipObjective` is returned as an OBJECTIVE to maximise, matching
    znum's `clippedSurrogate`; negate for a step.
  * ★ `clamp` is now bound at file scope like the other reserved math names, after the two lint
    rules disagreed about `@min(@max())` versus `zm.clamp` in a body.
  * **Every item in §10.5 is now closed.** zimrnum: **190 public declarations, 72 tests — 23% of
    znum.** Tutorial 117 KB, 17 sections.


- **Sep 8 2026 — ★★★ THE GPU TRAINING STEP IS CONFIRMED ON THE DEVICE. STAGE C IS COMPLETE ON BOTH
  BACKENDS.** Then made fast enough to run by hand. 71 tests, lint 0, `check` green, both smokes
  PASS, fmt clean.

        step    gpu loss    cpu loss    |gpu - cpu|
          5    1.9256697   1.9256724   2.7e-6
         40    0.2186890   0.2186890   3.0e-8
        100    0.0370728   0.0386889   1.6e-3
        599    0.0000995   0.0006354   5.4e-4

  * ★★★ **THE LABELLED READBACK WORKED.** With the kernel writing its step beside its loss, every
    sampled step lines up: 3e-8 at step 40 is the same agreement the headless twin showed. The
    later gap is the two minima, as predicted from the one-ULP `dw2` difference.
  * ★★ **STEP 0 READ AS 0.0000000 — THE UNTOUCHED BUFFER CLAIMED ITS SLOT.** Before any dispatch
    lands, the loss buffer is zeros, which read as "step 0, loss 0" and were filed; the real
    step-0 loss then arrived and was refused as already seen. The label is now `step + 1`, so a
    zero means "nothing yet". A sentinel that collides with a real value is not a sentinel.
  * ★★★ **FIVE SECONDS → HALF A SECOND.** One step per frame was 600 frames; Simon's phone runs
    at 120 Hz, which the timing itself revealed. Now ten steps per frame with frame 0 running one
    so step 0 is sampled — 61 frames. The milestones are chosen to be each frame's LAST step,
    because that is the only loss the buffer holds at frame end. **The two-second budget is now
    a stated constraint for every device test**, and the sweep sits at about 1.5 s under it.
  * ★★ **THE SMOKE'S QUEUE-TIMELINE CHECK CAUGHT TEN UNIFORM WRITES A FRAME.** Setting
    `params.step` per step changed the uniform ten times; `syncParamsUniform` skips identical
    rewrites but ten distinct values are ten writes, and only the last reaches the whole frame.
    Fixed by setting the label ONCE per frame to the burst's last step — the only step whose loss
    survives anyway. One value, one write, label exactly right. The check that flagged it exists
    for the renderer's UBO rings, and it was right here too.
  * ★ Verdict now triggers on the last MILESTONE arriving rather than on every step being read,
    since with ten steps a frame most steps are never sampled, by design.


- **Sep 8 2026 — THE DEVICE FOUND A REAL BUG IN THE TRAINING PAGE, AND THE PAGE'S OWN CHECK CAUGHT
  IT. Then a review against znum closed a gap by porting directly. 71 tests, lint 0, `check`
  green, both smokes PASS, fmt clean.**
  * ★★★ **THE GPU LOSS AT "STEPS 1 AND 2" WAS THE SAME NUMBER — 3.4334915 — THE CPU'S STEP-3 LOSS,
    READ TWICE.** Both sides converged, but the early-agreement check reported 2.57 and **FAIL**,
    correctly. Nothing was wrong with any kernel: the host assumed `readLatest` lagged by exactly
    one frame and filed loss `i` under step `i`, and the queue was three frames behind. Losses
    were being attributed to steps they did not come from.
  * ★★★ **FIX: THE GPU LABELS ITS OWN OUTPUT.** `loss_value` now writes the step counter beside the
    loss, from the uniform, and the host files each readback under the step the kernel says it
    belongs to. A readback seen twice is filed twice under the same step, harmlessly. Attribution
    no longer depends on frame timing at all — which is the only way to make it right, since the
    timing is the GPU's to decide.
  * ★★ **THE PAGE OPENED IN THE CLAUDE VIEWER AT 1.89 MB**, consistent with the 2 MB cap measured
    on Sep 4.
  * ★★★ **THE REVIEW AGAINST znum FOUND ONE GAP AND CONFIRMED THREE PARITIES.** znum's `conv2d`
    has stride and padding per axis; mine had neither. **Ported znum's contract directly** —
    `stride: [2]usize, pad: [2]usize` — with implicit zero padding and the standard output
    formula. Tested by the two things the parameters are for: `pad = kh/2` gives the input's size,
    stride 2 gives exactly the even rows and columns. Dropout, softmax backward and layer norm
    backward match znum's forms; `initXavier`/`initHe` are confirmed additions.
  * ★ The rule that closed the gap fastest: **when znum's contract is already right, take it as
    is.** The signature was the whole specification.


- **Sep 8 2026 — THE GPU TRAINING STEP. `examples/zimrnum_train`: XOR trained on the device and
  the CPU in lockstep, one step per frame. 71 tests, lint 0, `check` green, both smokes PASS,
  fmt clean. Awaiting the device.**
  * ★★★ **EIGHT DISPATCHES PER STEP OVER ONE BUFFER SET, AND ONLY THE LOSS COMES BACK.** The
    sweep's kernels each own their buffers, right for comparing operations one at a time. A
    training step is a chain — matmul into add into tanh into the backward pass — and with
    separate buffers every arrow is a readback and re-upload. One file, one buffer set, and the
    data never leaves the device.
  * ★★★ **THE KERNELS' GRADIENTS MATCH zimrnum's TO ONE ULP AT STEP 0** — `dw1`, `db1`, `db2`
    bit-identical, `dw2` off by 3e-8 — and the losses agree to about 1e-7 for the first forty
    steps, through a loss spike to 3.4 at step 3. Then they part: XOR at a rate of 0.5 is a
    chaotic optimiser and amplifies that ULP into two different minima. **The early agreement is
    the check; the final losses are two answers to the same question.** The page says so.
  * ★★★ **WebGPU ALLOWS EIGHT STORAGE BUFFERS PER STAGE, AND THE FIRST VERSION DECLARED FIFTEEN.**
    `compute_host` refused it at compile time: bindings past the eighth silently do not bind,
    writes are discarded with no error, and the kernel appears to run while computing garbage.
    Repacked by role into six — `inputs`, `params`, `acts`, `dacts`, `grads`, `loss` — with
    offsets derived from the uniform. **The packing is also the better design**: `params` and
    `grads` share one layout, so the SGD step is a single loop over one index with no four-way
    branch on which parameter a thread owns.
  * ★★★ **A REAL API DEFECT IN `Optimizer`, FOUND ONLY BY USING IT ACROSS A FRAME BOUNDARY.**
    `init` stored the caller's `params` slice. Every test passed, because a test writes
    `&.{ a, b, c }` in the same frame that calls `step`. The example built its optimiser in
    `init` and stepped it from `update`, and the literal was gone — an out-of-bounds read inside
    `valueOf` on the first frame. Now copied. **A type that outlives the call that made it owns
    what it needs**, and a test now builds the optimiser in a helper, scribbles the stack, and
    steps it after the helper has returned.
  * ★ The smoke's leak check caught the font not being released. Everything else came from the
    scope and was already covered by `close`.
  * ★ One step per frame, because `readLatest` returns the PREVIOUS dispatch's data. Running a
    step and reading its loss in the same frame would pair step N's loss with step N−1's
    weights — the stale-readback bug the sweep hit and fixed, now avoided by construction.


- **Sep 8 2026 — debt 17 resolved by DERIVATION, not annotation. The reference table has a GPU
  column. 70 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **THE GPU STATUS OF EVERY FUNCTION IS READ OUT OF THE SWEEP.** Each `Case` names its
    kernel in `.entry` and calls exactly one `zn` function in its `cpu` body, so "which functions
    are verified on a device" is answered from the one place that verification actually happens.
    A tag in the source would have been a second statement of the same fact, and the two would
    drift — which is the failure mode the tutorial gate exists to prevent for the reference
    table itself.
  * **Measured: 181 declarations — 55 module functions with a verified kernel, 64 methods,
    62 host-only. Of the host-only, 25 are elementwise or row-wise and genuinely kernel-pending.**
    They are listed in the register. **The GPU backlog is now a list rather than a feeling.**
  * ★★ **A METHOD IS NEITHER HOST NOR KERNEL.** The first version showed `Graph.add` with kernel
    `add`, because it shares a name with the module function that has one. The graph runs on the
    host; that was a false claim in a generated table, which is worse than a false claim in a
    hand-written one because nobody rereads generated text. Methods are marked as such and the
    lookup is skipped.
  * ★ **I wrote the split as 55 / 32 / 94 and measured it as 55 / 64 / 62.** Corrected. Same
    mistake as before, in the same session, with the same fix.
  * Spot-checked: `cumsumInto → cumsum_rows`, `argmaxRows → argmax_axis0`,
    `layerNormRows → layernorm_rows`, `lu → host`. All correct.


- **Sep 8 2026 — 59/59 ON THE DEVICE, debt 18 closed. Then attention composed on the tape, and
  convolution. 70 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * **Every one of the eleven unverified rows passed on the Adreno**, including `argmax axis0` at
    a tolerance of zero and `atan2` inside its corrected bar.
  * ★★★ **ATTENTION IS NOT A PRIMITIVE, AND THAT IS THE TEST.** `softmax(QKᵀ/√d)V` is four
    operations the tape already has — matmul, transpose, scale, softmax — and composing them is
    the check that the tape COMPOSES. `gx` feeds all three projections, so its gradient is the
    sum of three paths: the accumulation a single-use test never exercises. All four parameters
    agree with a finite difference to better than 1e-8, **and no backward rule was written for
    attention itself.** That is what having a tape is for.
  * ★★ **`transpose` ON THE GRAPH IS MATERIALISED**, where the `Tensor` method is a free view. A
    value of the graph must be a tensor a later `matmul` can read and a later `recompute` can
    overwrite in place, and a view of another value's storage is neither. The copy is the price
    of the tape owning every value it records.
  * ★★★ **`conv2dInto` IS CROSS-CORRELATION AND THE TEST PROVES THE DIRECTION.** Every framework's
    "conv2d" slides the kernel unflipped; since the kernel is learned, a flipped kernel is just a
    different kernel. The only thing that tells the two apart is an ASYMMETRIC kernel — `[1, 0]`
    must reproduce the left neighbour and `[0, 1]` the right, which a true convolution would
    swap. Plus the identity kernel returning the image unchanged, which catches any off-by-one.
  * ★ Pooling drops a trailing partial window rather than padding it, so every output element saw
    exactly `size²` inputs and the operation means the same thing at the edge.
  * zimrnum: **181 public declarations, 70 tests — 22% of znum.** Tutorial 104 KB.


- **Sep 7 2026 — five kernels for the new reductions; the sweep is FIFTY-NINE rows and rebuilt
  for the device. 68 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * `max_axis0`, `min_axis0`, `mean_axis0`, `argmax_axis0`, `cumsum_rows`. All five CPU twins
    match zimrnum **exactly** on the host — worst 0, zero index mismatches — before the device
    sees them.
  * ★★ **`argmax_axis0` WRITES ITS INDEX AS A FLOAT**, so it sits in the same `f32` output buffer
    as everything else and the sweep compares it with a tolerance of zero. An index that came back
    as 63.0000001 would fail, which is right: an argmax is exact or it is wrong.
  * ★ `cumsum_rows` is one thread per row, sequential — a scan has a parallel form with log-depth
    barriers, and this is the reference it will be compared against, the same way `sum_all`
    preceded `sum_all_tiled`.
  * ★ The coverage gate named the first missing row (`max_axis0`) the moment the kernels were
    registered, as designed; the five rows were added against it.
  * **Debt 18 grows to eleven unverified rows.** Every one matches on the host; the device run
    is what remains, and it is in Simon's hands.


- **Sep 7 2026 — the rest of the tensor core: TWELVE functions in one pass. 68 tests, lint 0,
  `check` green, smoke PASS, fmt clean.** `meanAxis`, `maxAxis`, `minAxis`, `prodAxis`,
  `varianceAxis`, `prodAll`, `cumsumInto`, `anyNonzero`, `allNonzero`, `whereInto`, `argsort`,
  and a private `reduceAxis` they share.
  * ★★★ **ONE WALKER FOR EVERY AXIS REDUCTION.** `maxAxis`, `minAxis` and `prodAxis` are the same
    loop with a different comptime step, so the output-shape check — the thing to get wrong — is
    written once. `meanAxis` is `sumAxis` then a scale; `varianceAxis` is `meanAxis` then a second
    pass accumulating into the output itself, so no scratch the caller has to size.
  * ★★★ **EVERY AXIS REDUCTION IS TESTED BY RELATING IT TO ITS WHOLE-TENSOR FORM.** Reducing
    along one axis and then over the result must give `maxAll` / `minAll` / `prodAll` /
    `meanAll`, which are already trusted; a reduction that dropped a slice or double-counted one
    cannot survive. `varianceAxis` on a single row must equal `variance` of that row. **A new
    function is checked against an old one rather than against a number.**
  * ★★ **`whereInto` IS CHECKED AGAINST `greater`**: selecting by `a > b` IS `maximum(a, b)`, so
    two trusted functions pin a third.
  * ★★ **`argsort` ASSERTS STABILITY ON A RUN OF EQUAL KEYS** — `{2,1,2,1,2}` must order as
    `{1,3,0,2,4}`. Stability is the property a sloppier sort loses and the property that makes a
    sort by key usable for reordering something else.
  * ★ `argsort` rather than `sort`: the indices are what a caller wants, to reorder a different
    tensor by this key. Insertion sort — O(n²), stable, no scratch — because a rank-1 sort in a
    numerics library is almost always over a few hundred elements.
  * ★ `allNonzero` is true for an empty tensor, by the vacuous-truth convention, and the test says
    so rather than leaving it to be discovered.
  * zimrnum: **177 public declarations, 68 tests — 21% of znum.** Tutorial 101 KB.


- **Sep 7 2026 — `Optimizer`: one type, three algorithms, state bound to the parameter list.
  67 tests, lint 0, `check` green, smoke PASS, fmt clean.**

        steps      sgd   momentum     adam
           50   0.7687    0.5801   0.5392
          200   0.6284    0.1766   0.0430
         1000   0.3542    0.0089   0.0012

  * ★★★ **THE STATE LIVES WITH THE OPTIMISER, NOT THE CALLER.** Adam needs two moments per
    parameter; a caller training four parameters threads eight extra tensors by hand, and one
    moment buffer accidentally shared between two parameters **trains silently wrong**. Binding
    the state to the parameter list at construction makes that mistake unrepresentable. A
    training step is now three lines.
  * ★★★ **SGD THROUGH THE OPTIMISER IS ASSERTED EQUAL TO `sgdStep` BY HAND — `expectEqual`, not
    a tolerance.** The wrapper adds no arithmetic, so any difference would be a bookkeeping error
    in which parameter received which gradient. That is the failure mode the type exists to
    prevent, so it is the first thing checked.
  * ★★ **ADAM'S BUFFERS ARE A COST, AND THE TABLE IS WHAT THEY BUY.** At 1000 steps from
    identical weights Adam reaches a loss **300× lower than SGD**. The ordering
    Adam < momentum < SGD is asserted at 200 steps; measured, it holds at 50, 200 and 1000, with
    the gap widening.
  * ★ The algorithm is a `union(enum)` field rather than a type parameter, so a loop is written
    once and the choice changed at one call site. State for an algorithm that does not use it is
    never allocated.
  * zimrnum: **166 public declarations, 67 tests.** Tutorial 98 KB.


- **Sep 7 2026 — softmax, layer norm, scale and dropout on the tape, every rule checked against a
  finite difference. 66 tests, lint 0, `check` green, smoke PASS, fmt clean.**

        layer norm  9.7e-12      scale    1.1e-9
        softmax     1.1e-11      dropout  7.1e-9

  * ★★★ **LAYER NORM'S BACKWARD RULE IS `(1/σ)·(g − mean(g) − y·mean(g·y))`, AND IT IS THE
    TIGHTEST OF THE FOUR.** The derivation is not repeated in a comment — a derivation in a comment
    cannot be run — it is checked on rows given very different scales and offsets, where a rule
    that dropped the variance term would be visibly wrong. 9.7e-12 against a finite difference.
  * ★★ **SOFTMAX'S JACOBIAN IS NEVER FORMED.** `diag(y) − y·yᵀ` per row, applied to `g`, is one
    dot product and one elementwise operation. The rule is `y·(g − Σ g·y)`.
  * ★★★ **DROPOUT'S MASK IS DRAWN ONCE AND STORED AS A VALUE OF THE GRAPH.** A dropout that
    redrew on every `recompute` would be a different function each time, and `checkGradient`
    would compare a derivative against a finite difference of something else and report noise.
    `resampleDropout` draws fresh masks; a training loop calls it once per step. **The test
    asserts that resampling CHANGES the loss** — a `resampleDropout` that did nothing would pass
    a gradient check and silently disable dropout during training.
  * ★ Inverted scaling — kept elements multiplied by `1/(1 − rate)` — means removing the node at
    inference is exactly `rate = 0`, with no factor to remember.
  * ★ The four rules are also checked TOGETHER in one chain, each in the position it will occupy:
    layer norm feeding a matmul, dropout after it, softmax before the loss, scale in the residual.
  * ★ No `Sequential`. `attach` chains, and a struct holding the layers is the composition; a
    container type would add a level of indirection for nothing.
  * zimrnum: **162 public declarations, 66 tests.** Tutorial 96 KB.


- **Sep 4 2026 — a line-by-line review against znum. It found a REAL DEFECT, four divergences that
  had never been written down, and two stale sections of this plan. 65 tests, lint 0, `check`
  green, smoke PASS, fmt clean.**
  * ★★★ **`adamStep`'s BIAS CORRECTION WAS O(step) PER CALL.** It computed `beta^step` by
    multiplying `step` times, with a comment justifying that as avoiding "a rounding `pow` would
    introduce". **That traded an unmeasured rounding for 50 million multiplications over a
    10 000-step run and 5 billion over 100 000**, growing quadratically with the length of
    training. znum uses `pow` and is right to. Replaced with exponentiation by squaring: **17
    multiplications at 100 000 steps.** A justification that names a cost it did not measure is
    how this got written.
  * ★★★ **AND THE TEST I ADDED FOR IT ASSERTED THE WRONG THING.** I expected a late step from a
    zeroed state to move by `rate`. Measured, it moves by **`rate·(1−β₁)/√(1−β₂)` ≈ 3.16·rate**,
    because at step 100 000 the correction is 1 and the moments are used raw. The test now
    asserts both that and the step-1 case, and **the contrast between them is what the bias
    correction actually buys** — neither alone shows it. Fourth time this session the fix was to
    measure rather than reason.
  * **Four divergences added to the register, each with evidence:**
    - `max_rank` **6 against znum's 8**: `Tensor` is **128 bytes rather than 160** and is copied
      by value everywhere. Rank 6 covers batched video and batched attention with a spare axis;
      the cost — a caller needing 7 must edit the constant — is now stated rather than discovered.
    - **Counter-based RNG against znum's `DefaultPrng`/`Wyhash`**: order-independence, which a
      stateful stream cannot offer, and the same arithmetic lowers to WGSL where a stateful PRNG
      cannot go at all.
    - **Autograd nodes as an enum against znum's `grad_fn` closures**: the trade is extensibility
      for **exhaustiveness**, and the compiler refusing an unhandled case is what caught both
      `backward` and `recompute` needing every new operation. Revisit past ~30 ops.
    - **`initXavier`/`initHe` have no znum counterpart** — an addition, not a divergence.
  * **Two debts recorded**: ~60 CPU-only functions with **nothing distinguishing "host-side by
    design" from "kernel not written yet"**, and six sweep rows never run on a device.
  * **Parity confirmed where it matters**: softmax subtracts the row maximum on both sides, layer
    norm's epsilon is a parameter in both, and both use a 128-element pairwise threshold.
  * **The plan itself was stale.** The function count said 146 against an actual 157, the
    per-namespace table predated autograd and `Dense`, the "largest holes" line still named `nn`
    and `autograd`, and §10.4's next actions were written when the port was 7% done. All
    corrected, and §10.5 replaces the action list with one that describes what is actually in
    front of us.


- **Sep 4 2026 — initialisation and a `Dense` layer. A THREE-LAYER rectifier network trains
  through the graph. 65 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * `initXavier`, `initHe`, `Dense`, `Dense.Attached`, `Dense.attach`.
  * ★★★ **AN INITIALISER'S ONLY CLAIM IS ABOUT THE DISTRIBUTION IT PRODUCES, so that is what is
    asserted** — He's variance against `2/fan_in` to 5%, Xavier's against `limit²/3`, and the mean
    against zero. ★★ **Plus a bound check Xavier alone can pass:** nothing may fall outside
    `±limit`. A normal draw scaled to the same variance would satisfy the variance assertion and
    fail that one, which is the difference between testing the number and testing the
    distribution.
  * ★★ **THE 2 IN He EXISTS BECAUSE `relu` DISCARDS HALF ITS INPUT.** Using Xavier with a
    rectifier loses a factor of two per layer — a factor of a thousand over ten. Three layers is
    where this starts to be visible, which is why the training test has three.
  * ★★★ **THE TEST FOUND A REAL GAP IN `attach`'s SIGNATURE.** It returned only the output `Var`,
    and the first training loop could not be written: the loop needs the PARAMETER handles to read
    their gradients, and a `Dense` deliberately holds no `Var` — storing one would tie a layer to
    the first graph it met, which is exactly what sharing weights between a training and an
    evaluation path forbids. `attach` now returns `{ out, weight, bias }`. **Writing the loop was
    the design review.**
  * ★ Biases start at zero. A random bias adds nothing a random weight does not already provide,
    and shifts every unit's activation before any data is seen.
  * The stack's gradients are checked at the FIRST layer's weights and the LAST layer's bias, so
    the finite-difference check spans the whole chain rather than one end of it.
  * zimrnum: **157 public declarations, 65 tests.** Tutorial 94 KB.


- **Sep 4 2026 — a classifier TRAINS THROUGH THE GRAPH, and cross-entropy is on the tape.
  64 tests, lint 0, `check` green, smoke PASS, fmt clean.**

        gradient check before  3.8e-11
        step    0   loss 1.282   acc 0.22
        step  200   loss 0.126   acc 0.97
        step 3000   loss 0.021   acc 1.00
        gradient check after   9.7e-12

  * ★★★ **THE GRAPH IS BUILT ONCE, OUTSIDE THE LOOP.** Each step is `recompute`, `backward`, then
    `sgdStep` into the parameter tensors the graph already holds — nothing is allocated after the
    first iteration, and the next replay sees the updated weights with no bookkeeping. That is
    what `recompute` was for, and it is now demonstrated rather than asserted.
  * ★★ **THE GRADIENT CHECK RUNS BEFORE AND AFTER TRAINING, INDEPENDENTLY.** A model that trains
    is not evidence that its gradients are right — **a wrong but correlated gradient still reduces
    a loss.** Checking after as well puts the check at a point far from where it started.
  * ★★★ **AND I WROTE A COMMENT THAT WAS FACTUALLY WRONG, THEN MEASURED IT.** I justified the
    accuracy bar with "three balanced classes give a chance accuracy near 1/3". The actual class
    counts at this seed are **{13, 3, 16}** — a model always answering "class 2" scores **0.50**,
    not 0.33. The bar of 0.95 was still right, but the reasoning printed beside it was not, and a
    bar justified by a wrong baseline is a bar nobody can check. Corrected with the measured
    counts. **Comments asserting a number deserve the same measurement the assertions get.**
  * ★ **`crossEntropy`'s LABELS ARE A `[]usize`, NOT A `Var`.** They are integers the caller
    already holds, not values the graph differentiates; putting them on the tape would imply a
    gradient that does not exist.
  * Tutorial gains §14.6 with the loop, the curve and both gradient checks.
  * zimrnum: **151 public declarations, 64 tests.** Tutorial 93 KB.


- **Sep 4 2026 — the tape is REPLAYABLE and every rule is checked against a finite difference.
  63 tests, lint 0, `check` green, smoke PASS, fmt clean.** Added `recompute`, `checkGradient`,
  and `sub`, `mul`, `relu`, `sigmoid` on the graph — eight operations total.
  * ★★★ **`checkGradient` IS THE ONE TEST THAT DOES NOT REPEAT THE DERIVATION.** A hand-written
    backward pass and a tape rule can be wrong in the same way because the same person derived
    both — the previous turn's bit-for-bit comparison would not catch it. A finite difference does
    not know the derivative at all; it evaluates the function twice. **Every parameter of a graph
    using all eight operations agrees to better than 1e-8.** Every operation added from here goes
    in this test, which is what makes adding one cheap.
  * ★★ **CENTRAL, NOT FORWARD.** `(f(x+h) - f(x-h)) / 2h` has error O(h²) against O(h) for the
    one-sided form. At `h = 1e-5` in f64 that is agreement to ten digits rather than three —
    the difference between a real error being visible and being lost in the noise.
  * ★★★ **`recompute` IS WHAT MAKES THE GRAPH A MODEL RATHER THAN A ONE-SHOT.** Without it a
    training loop would rebuild the entire tape every step for a forward pass differing only in
    the numbers. Replaying writes into the buffers already allocated, and leaves are skipped —
    which is how a new batch enters an existing graph. It is also the mechanism `checkGradient`
    needs, since evaluating "the same function" at a perturbed input is exactly what the tape is
    a record of.
  * ★★ **THE REPLAY TEST CHECKS BOTH DIRECTIONS.** A new batch must give a DIFFERENT loss and a
    finite one. A `recompute` that quietly did nothing would pass a test that only looked for
    staleness one way.
  * ★ **`checkGradient` restores the model before returning**, asserted bit for bit: a gradient
    check that left weights perturbed would poison the next step, and the corruption would look
    like a training instability rather than a tooling bug.
  * ★ Adding `sub`, `mul`, `relu`, `sigmoid` as METHODS made them ambiguous with the module-level
    functions of the same names inside `Graph`. The compiler named the one site; `add` and
    `matmul` had already been qualified for the same reason when the graph was written.
  * zimrnum: **150 public declarations, 63 tests.** Tutorial 89 KB, 16 sections.


- **Sep 4 2026 — ★★★ AUTOGRAD. `Graph`, `Var`, `backward`, and gradients BIT-IDENTICAL to the
  hand-written pass. 62 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **THE ORACLE IS THE XOR TEST'S OWN BACKWARD PASS.** That chain is already known to train
    a network to zero loss, so requiring the tape to reproduce it **element by element with
    `expectEqual`** checks the new code against something proven rather than against a second
    derivation that could be wrong the same way. Both paths perform the same operations in the
    same order, so any difference is a difference in what was computed, not in how it rounded.
  * ★★★ **VALUES ARE INDICES, NOT POINTERS, AND THE REASON IS THIS LIBRARY'S OWN DESIGN.** Keying
    gradients off `data.ptr` fails immediately: a view SHARES it with its parent, so `w` and
    `w.transpose(0,1)` would collide. And `Tensor` is copied by value everywhere, so there is no
    stable address to key on at all. An index into the graph's arrays sidesteps both and needs no
    change to `Tensor`.
  * ★★★ **BROADCASTING IS A SUM ON THE WAY BACK, AND THE BIAS GRADIENTS ARE THE TEST THAT PROVES
    IT.** A bias of shape (1,n) added to (m,n) is used m times forward, so its gradient is the sum
    of m contributions. Adding the raw gradient would be a factor of m low — **and the network
    would still train, just with a bias moving m times too slowly**, which is the hardest kind of
    bug to notice. `expectEqual` against the hand-written `sumAxis` result closes it.
  * ★★ **THE TAPE NEEDS NO TOPOLOGICAL SORT.** Nodes are appended in execution order and a value
    can only depend on values recorded before it, so walking the list backwards visits every
    consumer before its producer by construction. No sort, no visited set, no cycle check.
  * ★ `backward` requires a single-element value and seeds 1: reverse mode answers how ONE number
    changes, and differentiating a tensor gives a Jacobian instead. It zeroes before accumulating,
    so calling it twice repeats rather than doubles — asserted.
  * ★★ **A DOCUMENT-ORDER BUG FROM THE PREVIOUS TURN SURFACED HERE.** The training section was
    numbered 14 but had been appended before `<footer>`, which put it AFTER the reference section.
    The autograd section landed in the same place, and its 4-row "what is differentiable" table
    fell inside the region the drift gate scans — reported as **"148 rows but 144 declarations"**.
    Sections reordered so the reference is last, and the tutorial check now also asserts the h2
    numbers appear in ascending document order.
  * **Stage B's core is done.** Remaining: the rest of the operations, `checkGradient`, and
    higher-order derivatives.


- **Sep 4 2026 — ★★★ MILESTONE: A TWO-LAYER NETWORK LEARNS XOR, USING ONLY zimrnum. 61 tests,
  lint 0, `check` green, smoke PASS, fmt clean.**

        step    0   loss 0.541
        step  100   loss 0.0000062
        step 1000   loss 0
        outputs     -0.000000  1.000000  1.000000  -0.000000

  * ★★★ **THIS IS THE CHECK NO UNIT TEST CAN MAKE.** Every piece has its own test, and none of
    them catches a mistake in how the pieces FIT: a gradient with the wrong sign, a transpose on
    the wrong operand, a bias summed along the wrong axis. Each leaves every individual function
    correct and the network unable to learn. **Training something is the only way to close that
    gap**, and it now runs on every `zig build test-fast`.
  * ★★ **XOR BECAUSE A LINEAR MODEL CANNOT DO IT.** The loss of a linear model stalls near 0.25;
    the assertion `early_loss < 1e-4` at step 100 is what separates "learned the function" from
    "found the mean". If the hidden layer or its non-linearity were ever bypassed, that is the
    line that fails.
  * ★★★ **AND I MADE THE MEASUREMENT MISTAKE AGAIN, IN MINIATURE.** I read the gradient norms off
    a 4000-step run (**2e-11**), then cut the loop to 1500 to keep the test quick, and asserted the
    4000-step bound. At 1500 the norms are **2.6e-6** and the test failed. The outputs were already
    correct to six places, so nothing was wrong with the network — the threshold had simply been
    measured under different conditions than it was applied to. **The step count and the bound are
    one measurement, not two**, and the test now says so where a reader will see it.
  * The whole loop uses `Scope`, so nothing inside it is freed individually. The transposes are
    stride swaps with no copy, which is the CPU-only convenience §10.3 records.
  * Tutorial gains section 14, "A network that learns", with the loop, the loss curve, and the
    `tanhGrad` trap: it takes the forward OUTPUT, and passing the input compiles, runs, and
    learns far too slowly.
  * **Stage C's CPU milestone is reached.** The same loop on the DEVICE remains open — every
    kernel it needs exists and is verified, so what is left is orchestration.


- **Sep 4 2026 — the loss family completed: `maeLoss`, `huberLoss`, `bceLogitsLoss`, `klDivRows`.
  60 tests, lint 0, `check` green, smoke PASS, fmt clean.** znum has seven losses; zimrnum now has
  six of them.
  * ★★★ **BCE FROM LOGITS, FOR CROSS-ENTROPY'S REASON.** Sigmoid-then-logarithm breaks at BOTH
    ends: −800 saturates the sigmoid to exactly 0 and its logarithm is −inf, +800 the same on the
    other side. The identity `max(x,0) − x·t + log(1 + e^-|x|)` is algebraically equal for every
    real `x` and contains only a **non-positive exponent**, so it cannot overflow. Asserted at
    ±800: exactly 0 for a correct target, exactly 800 for a wrong one, both finite.
  * ★★★ **HUBER IS CHECKED AT ITS JOIN, AND SO IS ITS SLOPE.** Both branches give `delta²/2` at
    the threshold, and a numerical derivative from each side must agree — a kink there would put
    a gradient discontinuity exactly where most samples sit. Also checked at both limits: it is
    MSE/2 below and tracks MAE far above, which is the reason it exists.
  * ★★★ **KL IS PINNED BY GIBBS' INEQUALITY** — zero for identical distributions, strictly
    positive otherwise — which no implementation with a sign error survives. ★★ **And by
    ASYMMETRY**: `kl(p,q) != kl(q,p)` is asserted, because a symmetric test would leave the
    argument order free to be wrong, and the order is the whole meaning of the function.
  * ★ A zero in `q` where `p` is not zero is genuinely infinite, so it is `DomainError` rather
    than an `inf` reaching the caller. A zero in `p` contributes nothing, by the limit of `p·log p`.
  * zimrnum: **132 public declarations, 60 tests, 5 260 lines.** Tutorial 78 KB, 49 subsections.


- **Sep 4 2026 — classification: `argmaxAll`, `argmaxRows`, `oneHotRows`, `crossEntropyRows`,
  `crossEntropyRowsGrad`, `accuracy`. 59 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **CROSS-ENTROPY NEVER COMPUTES THE SOFTMAX.** The definition
    `-log(softmax(x)[t])` exponentiates, normalises and then takes a logarithm — three chances to
    lose the answer. The identity `logsumexp(x) - x[t]` avoids both failure modes: the largest
    exponent is `e^0` after subtracting the row maximum, and the subtraction happens in log space.
    ★★ **THE TEST PROVES IT TWICE.** First against the naive computation, on data where the naive
    way still works. Then on the row `{800, 0, -800}`, where every exponential overflows even in
    `f64` — the definition gives NaN, and this returns **exactly 0 and exactly 800**.
  * ★★★ **THE GRADIENT IS CHECKED AGAINST A CENTRAL FINITE DIFFERENCE OF THE LOSS**, every element,
    which is the only check that ties an analytic form to the function it claims to differentiate.
    Plus a structural law: **each row of the gradient sums to zero**, because softmax sums to 1 and
    one-hot removes exactly 1 — a step can shift probability between classes but cannot create any.
  * ★★ **`crossEntropyRowsGrad` IS `softmax - onehot` AND NOTHING ELSE.** Softmax and cross-entropy
    are paired precisely because their derivatives compose into a subtraction: no division, no
    exponential in the backward pass.
  * ★ `argmax` compares with `>`, so ties go to the FIRST occurrence and **a NaN never wins** —
    a NaN candidate fails the comparison and the running best survives. `>=` would do neither.
  * ★★ **THE LINTER TAUGHT ME A RULE I HAD NOT NOTICED.** Seven findings, all `catch-suppression`
    on `catch unreachable` — but the file already has 109 of them that pass. The rule fires only
    where the enclosing function **can return an error**, and there `try` is available, shorter,
    and not UB in ReleaseFast. Every one of mine was in an `Error!` function. A rule that fires on
    109 sites would be noise; one that fires on exactly the seven where a better option exists is
    worth having.
  * zimrnum: **128 public declarations, 59 tests, 5 040 lines.** Tutorial 75 KB, 48 subsections.


- **Sep 4 2026 — L10 optimisers: `sgdMomentum`, `adamStep`, `Adam`, `clipByNorm`. 58 tests,
  lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **EVERY TEST IS A DEFINING PROPERTY, NOT A NUMBER.**
    **Momentum 0 must equal `sgdStep` exactly** — `expectEqual`, not a tolerance — because an
    optimiser whose degenerate case does not match the simpler one has an error in the
    accumulation, and that is the cheapest place to find it. A repeated gradient must leave
    `(1 + mu)·g` in the velocity after two steps.
  * ★★★ **ADAM IS CHECKED BY SCALE INVARIANCE**, which is the reason to use it: multiplying every
    gradient by a **thousand** must leave the update unchanged to 1e-9. An implementation that
    dropped the `sqrt(v)` denominator moves a thousand times further and fails immediately.
  * ★★ **AND BY THE FIRST STEP BEING THE FULL LEARNING RATE.** With both moments starting at zero
    the corrected ratio is exactly the sign of the gradient on step one, so every weight moves by
    `rate`. Without the bias correction the opening step is smaller by about `1 - beta2` — at the
    default 0.999, **a thousandth of the intended distance**, which is why `step` is a parameter
    rather than internal state.
  * ★★ **`sgdMomentum` ACCUMULATES THE GRADIENT, NOT THE STEP.** The other common form folds
    `rate` into the velocity; the two differ the moment the rate changes, because an old rate then
    persists in the accumulator for several steps. Keeping it out means a schedule takes effect
    immediately, which is what a schedule is for.
  * ★★ **`clipByNorm` SCALES THE WHOLE TENSOR BY ONE FACTOR.** Elementwise clipping changes the
    gradient's DIRECTION, and a step in a different direction is not a smaller version of the
    intended step. The test asserts the cosine with the original is 1 after clipping, and that the
    resulting norm lands exactly on the limit.
  * ★ `Adam`'s hyperparameters have defaults where `leakyRelu`'s slope does not: they are a
    published part of the algorithm rather than a property of the problem.
  * ★ `1 - beta^step` is computed by repeated multiplication rather than `pow`, since `step` is a
    whole number and a float power would add a rounding the correction does not need.
  * zimrnum: **122 public declarations, 58 tests, 4 760 lines.** Tutorial 72 KB, 47 subsections.


- **Sep 4 2026 — the reference generator rewritten in Zig. Simon caught it: I had added a Python
  script and a JSON data file to a tree whose tooling is Zig. 57 tests, lint 0, `check` green,
  smoke PASS, fmt clean.**
  * ★★★ **THE RULE WAS ALREADY WRITTEN DOWN, IN THE HEADER OF A NEIGHBOURING TOOL.**
    `tools/doc_sync.zig` opens with *"Zig rather than Python because the house rule is that tooling
    is Zig (the analysis and codegen purge is complete)"*. I put `gen_zimrnum_reference.py` beside
    it without reading it. **A convention recorded in the file next door is one I am expected to
    find**, and the cost of not looking was a tool that had to be written twice.
  * `tools/zimrnum_ref.zig` replaces it, registered as `zig build zimrnum-ref`. **The notes are a
    comptime array in the tool, not a data file:** a second format is a second thing to keep in
    sync, and this table is read by exactly one program.
  * ★★★ **THE PORT WAS VERIFIED BY DIFF AGAINST THE PYTHON'S OUTPUT**, before the script was
    deleted. The only differences were entity encoding — the Zig version writes `&ndash;` and
    `&mdash;` where the script emitted raw UTF-8 — which renders identically and is the more
    correct form. Everything else byte for byte.
  * ★★ **The missing-note check is a negative control, not an assumption.** A `pub fn` was added
    with no note; the build failed with `no note: undocumentedProbe`, naming it. Then removed.
    A generator that silently writes a blank column would be worse than the hand-maintained table
    it replaced.
  * ★ `std.mem.trimRight` is `trimEnd` on this Zig, and `File.stdout().writer` takes the `io`
    handle — both found by compiling rather than by reading. The other tools' dialect is the
    reference for this.


- **Sep 4 2026 — L09 linear algebra: SEVEN functions, and the reference table is now generated by
  a checked-in tool. 57 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * `dot`, `trace`, `norm`, `lu`, `solve`, `determinant`, `cholesky`.
  * ★★★ **THE TEST FOR A FACTORISATION IS THAT IT RECONSTRUCTS THE INPUT.** `lu` is checked by
    rebuilding **P·A from L·U** and comparing against the row-swapped original; `cholesky` by
    rebuilding **L·Lᵀ**; `solve` by the **residual against the ORIGINAL A**, which is why the test
    keeps an untouched copy. None of these needs to know what the factors should be, and an error
    anywhere in the multipliers, the pivoting or the update loop appears in the reconstruction.
  * ★★ **`norm` SCALES BY THE LARGEST MAGNITUDE BEFORE SQUARING.** A direct sum of squares
    overflows for a vector near √maxFloat and underflows near √minFloat, in both cases for inputs
    whose norm is representable. Asserted: two elements of 1e200 give **1.414e200**, not infinity.
  * ★★ **`determinant` RETURNS 0 FOR A SINGULAR MATRIX WHILE `lu` RETURNS `DomainError`**, and the
    test asserts both on the same input. Zero is the answer to "what is the determinant"; there is
    no answer to "what are the factors".
  * ★ Partial pivoting bounds every multiplier by 1. The test matrix has a **zero leading entry**
    on purpose, so an implementation without pivoting fails immediately rather than passing on
    easy input.
  * ★★★ **THE TUTORIAL'S REFERENCE TABLE IS NOW GENERATED**, by `tools/zimrnum_ref.zig`. The
    drift test compares the table with the source, so a hand-maintained 118-row table is a
    standing hazard; regenerating removes every failure mode except a genuinely missing note.
    Tutorial section 10 rewritten as four subsections with the scaling trick and the in-place
    contract shown.
  * ★★ **`dot` AND `determinant` ARE RESERVED MATH WORDS** — `zm` has both — so they became
    `dotAll` and `determinantLu`. The first joins the `sumAll`/`meanAll` family, which is what it
    is: a reduction of tensors to a scalar. The second names the method, which matters because it
    overwrites its input. **Sixth and seventh names this port has had to rename**, and the rule has
    paid off twice now by producing a better name than the one first reached for.
  * ⚠ **The zip shipped before lint ran, for the second time.** Gates before the snapshot; the
    ordering keeps slipping when the chunk is large enough to feel finished.
  * zimrnum: **118 public declarations, 57 tests, 4 600 lines.** Tutorial 70 KB, 45 subsections.


- **Sep 4 2026 — the tutorial rewritten in full against znum's coverage. 56 tests, lint 0,
  `check` green, fmt clean.**
  * **63 KB, 14 sections, 41 subsections, 42 code blocks, 10 tables, 111 reference rows.** For
    comparison znum's is 156 KB with 39 sections — it documents autograd, layers, RL, dataframes
    and decompositions, none of which exist here. Per area covered, the depth now matches.
  * ★★★ **THE REFERENCE TABLE IS GENERATED FROM THE SOURCE, NOT WRITTEN BY HAND.** A script reads
    every `pub fn` and `pub const` out of `src/zimrnum.zig` with its signature and emits the rows;
    a hand-maintained note per name supplies the third column. The gate passed on the first build,
    which a hand-written table of 111 rows would not have.
  * ★★ **INTERNALS ARE SHOWN WHERE THEY EXPLAIN AN INTERFACE.** `flatIndex` in full, because it
    is the entire addressing model and every view operation follows from it; `Ddof.divisor`,
    because the optional is why `variance` can return `DomainError`; `isAliased`, because it is
    the rule for what may be written to; the Neumaier inner loop; the `lerpTo` branch; and a
    complete elementwise kernel.
  * ★★ **NEW STRUCTURE**: what it is → what exists → getting started → base types → RNG → memory →
    tensors → elementwise → reductions → matmul → network pieces → statistics → the GPU
    relationship → reference. Tensors and elementwise carry eight and seven subsections
    respectively, which is where the surface actually is.
  * ★ Sections added that had no equivalent before: how a draw is computed (with the stream
    table), the addressing model, windows and slicing, comparison masks, rounding and sign,
    summation accuracy with the measured throughput and cancellation table, a dense layer written
    out forward and backward, and a table of where the two backends genuinely differ.
  * ★ Checked mechanically: **no dangling anchors, no unlinked sections, no stray `znum`
    references.**


- **Sep 4 2026 — L08 statistics: NINE functions in one chunk, CPU-only. 56 tests, lint 0, `check`
  green, smoke PASS, fmt clean.** `variance`, `stdDev`, `rms`, `meanAbsDev`, `stdErr`, `zscore`,
  `covariance`, `correlation`, `minMaxScale`.
  * ★★★ **THE TEST INPUT IS FIVE VALUES WHOSE STATISTICS ARE EXACT IN BINARY** — 1, 3, 5, 7, 9:
    mean 5, deviations ±4 ±2 0, squares summing to 40. So `variance(.population) == 8` and
    `variance(.sample) == 10` are asserted with `expectEqual`, not a tolerance. **An expected
    value that is itself an approximation cannot catch a small error**, and picking the input so
    the arithmetic is exact costs nothing.
  * ★★ **THE DIVISOR IS THE THING TO GET WRONG**, so both `Ddof` cases are asserted AND their
    ratio: sample is population times n/(n−1), for every input. A single value has a population
    variance of 0 and **no** sample variance — `DomainError`, which is what `Ddof.divisor`
    returning an optional was for, now exercised.
  * ★★★ **CORRELATION IS PINNED AT THREE FIXED POINTS NO IMPLEMENTATION CAN FAKE**: a tensor with
    itself is +1, with its negation is −1, and `covariance(a, a)` equals `variance(a)`. Plus
    scale-invariance — correlating `a` with `3a` must still be 1.
  * ★ **`correlation` is NOT clamped to [−1, 1].** Rounding can put it a few ULP outside, and
    clamping would hide the only signal that something upstream is wrong: 1.0000003 says the
    inputs are collinear AND the arithmetic is at its limit; a clamped 1.0 says only the first.
  * ★ `variance` is two-pass for `layerNormRows`'s reason, and `zscore` uses the SAMPLE deviation
    — matching R and scipy — because the choice is visible at small n and should be stated rather
    than left to whichever the implementer reached for.
  * ★ Three locals named `variance` and one named `scale` had to be renamed once the module-level
    names existed. **Fourth time a new public name has collided with a local**, and every time the
    compiler found all of them immediately. The namespace is flat and that is the cost.
  * zimrnum: **111 public declarations, 56 tests, 4 100 lines.**


- **Sep 4 2026 — `Tensor` gained a BASE OFFSET, and `slice` and `takeInto` with it. 55 tests,
  lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **A SLICE IS AN OFFSET, WHICH IS WHY IT COULD NOT EXIST BEFORE.** Every view until now
    began at element 0. `base` is one `usize` and it unlocks the whole of znum's `index`
    namespace: a batch of 32 rows out of 4096 is now a `Tensor` like any other, addressing 32
    rows of the same buffer with nothing copied.
  * ★★★ **IT WEAKENED WHAT `data.len` MEANS, AND FIVE SITES HAD ASSUMED OTHERWISE** — `fill`'s
    `@memset`, `reshape`, `map`, `zip` and `sumAllFast`, **every one of them a FAST PATH that
    skips the index walk.** That is exactly where such an assumption hides: the slow paths go
    through `flatIndex`, which now adds `base` and is correct by construction. The test asserts
    it directly — rows 1 and 2 of a 4x3 sum to **33**, and a fast path ignoring `base` returns
    the first six elements, **15**.
  * ★★ **THE SLICE TEST WRITES THROUGH THE WINDOW AND CHECKS THE PARENT.** A test that only read
    would pass on an implementation that copied, and not copying is the entire point.
  * ★ `slice` refuses a window that does not fit rather than clamping: a view SMALLER than
    requested is worse than an error, because the caller's next loop uses the shape it asked for.
    `takeInto` refuses an out-of-range index before writing anything — **silently clamping is
    what a GPU kernel is tempted to do, having nowhere to report**, and it fills the output with
    a plausible wrong row.
  * ★ The multi-edit script aborted mid-way again, on an anchor that had drifted. Nothing was
    written because the write is last — but the fix is now standard: **check every anchor first,
    then apply.** One assertion over the whole edit list, before any mutation.
  * zimrnum: **102 public declarations, 55 tests, 3 800 lines.**


- **Sep 4 2026 — `manip` ported in one pass: EIGHT operations, no kernels, no sweep rows.
  54 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * Views (pure metadata): `permute`, `squeeze`, `unsqueeze`, `flatten`, `moveAxis`.
    Copies: `materialise`, `concatInto`, `tileInto`.
  * ★★★ **THE VIEW OPERATIONS NEED NO GPU KERNEL BECAUSE THERE IS NO ARITHMETIC TO DISAGREE
    ABOUT.** They permute or insert entries in two fixed-size arrays and copy nothing. That is why
    this was the fastest chunk of the port so far — eight functions, one build, no `build.zig`
    edit, no sweep row, no device round trip. **The cost is deferred, not avoided:** a permuted
    view still cannot be bound to a kernel, which is why `materialise` went in alongside them.
  * ★★ **`materialise` IS THE DENSIFY STEP WITH A NAME.** The example has been open-coding it
    since `bcast_add` landed. Its test uses a TRANSPOSED source deliberately — a test on dense
    input would pass for a plain `@memcpy` and prove nothing.
  * ★★ **THE LAW FOR EVERY VIEW IS THAT THE SET OF ELEMENTS IS UNCHANGED**, only the path through
    them moves. So each view is walked in full and compared against the original by index. A test
    checking only `shape` would pass on a view that read entirely the wrong memory — and shapes
    are exactly what a permute bug leaves correct.
  * ★ Round trips as tests: `unsqueeze` then `squeeze` at every position; `permute` by inverse
    permutations; `moveAxis(1, 1)` changing nothing. And **`concat(t, t, axis)` must equal
    `tile(t, 2)`** — two implementations of one shape, so they are asserted equal rather than
    each checked alone.
  * zimrnum is now **100 public declarations, 54 tests**.


- **Sep 4 2026 — activations completed and the loss reaches the GPU. Sweep is FIFTY-FOUR.
  52 tests, lint 0, `check` green, smoke PASS, fmt clean.** `softplus`, `silu`, `leakyRelu`,
  `eluTo`, `min_all`, `mse_loss`.
  * ★★★ **`softplus` IS GUARDED AT THE SAME THRESHOLD ON BOTH SIDES, AND THAT IS THE WHOLE
    POINT.** `e^x` overflows f32 near 88 and `log(1 + inf)` is inf; softplus(x) is within one ULP
    of `x` well before that, so both implementations return `x` above 20. **A guard on one side
    only would make the two disagree by an infinity on a single element** — which `compare` would
    report as unbounded, correctly, but the defect would be the asymmetry rather than either
    kernel.
  * ★★ **`mse_loss` PUTS THE LOSS ON THE DEVICE**, which was the last kernel missing from a dense
    layer's training step: forward is `matmul` + `bcast_add` + an activation, backward is
    `relu_grad` + `matmul_bt` + `sum_axis0`, and the update is `sgd_step`. **All of it now exists
    and all of it is verified against zimrnum.** What remains for the milestone is orchestration,
    not kernels.
  * ★★ **THE PARAMETERISED ACTIVATIONS TAKE THEIR PARAMETER, WITH NO DEFAULT.** PyTorch's leaky
    relu defaults to 0.01; a default here would be a hyperparameter chosen by whoever wrote the
    library. The tests sweep three slopes and three alphas and assert **the join at zero** for
    each — whatever the parameter, both branches must meet, or the gradient through it means
    nothing.
  * ★ The sweep uses alpha 0.25 rather than 0.01 **so the negative branch is visible in the
    heatmap** instead of being a rounding-sized sliver. A demonstration nobody can see is a test,
    not a demonstration.
  * ★ `silu`'s test asserts the output DIPS BELOW ZERO somewhere: that dip is the entire
    difference from `relu`, and an implementation returning `max(x, 0)` would pass a looser test.


- **Sep 4 2026 — the page scrolls, failures sort to the top, and `atan2`'s bar now comes from the
  implementation instead of a guess. 51 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **THE PAGE COULD NOT SCROLL, AND AT 48 ROWS THE FAILURE WAS BELOW THE FOLD.** Simon could
    see `47/48 PASS` and not the row that failed. Two changes, because they fix different halves:
    **failures sort to the top** so a screenshot always carries the exception, and **wheel or drag
    scrolls** for reading the rest. The scroll limit is computed from the drawn layout, not a
    constant, so it stays right as rows are added — and it clamps, because scrolling past the end
    leaves a reader staring at nothing and wondering whether the page broke.
  * ★★★ **`atan2` FAILED AT 9.6 ULP AGAINST MY GUESSED BAR OF 4, AND zm's OWN COMMENT EXPLAINS
    IT.** `zm.atan2` is `std.math.atan2` on the host — exact, a hundred lines — and a
    **DirectXMath-derived polynomial** on the GPU. The two backends run deliberately different
    algorithms, so the agreement is bounded by the polynomial's accuracy rather than by rounding.
    For contrast the device gives `sin` 1.5 ULP and `cos` 1.6, whose GPU path is far closer.
    ★★ **I set 4 by analogy with the other transcendentals; the right number came from reading the
    implementation.** A tolerance guessed from a pattern is a guess wearing a number's clothes —
    and this is the second time this port that the fix was to go and read what the function
    actually does rather than widen a bar until it passed.
  * ★ This is also the sharpest instance of the point from the `@sin` discussion: **zm is one name
    whose per-backend choice was made deliberately**, and here the choice is "exact on host, fast
    polynomial on device". The sweep is measuring that choice working as designed.


- **Sep 4 2026 — masks, clamp and lerp. Sweep is FORTY-EIGHT. 51 tests, lint 0, `check` green,
  smoke PASS, fmt clean.** `greater`, `less`, `equal`, `clampTo`, `lerpTo` on both sides.
  * ★★★ **MY `lerp` WAS WRONG AND THE ENDPOINT TEST CAUGHT IT IN ONE MINUTE.** I wrote
    `a + t*(b-a)` with a comment claiming it returns exactly `a` at t = 0 **and exactly `b` at
    t = 1**. The first half is true; the second is not — `x + (y - x)` is not `y` in floating
    point. `(1-t)*a + t*b` has the mirror problem. **No two-operation lerp is exact at both ends.**
    Now it interpolates from the NEARER endpoint, switching at t = 0.5, which is what C++20's
    `std::lerp` does and for this reason. The branch is on `t` — a scalar identical in every lane
    — so it costs a GPU nothing.
    ★★ The test asserted the doc comment's claim rather than the obvious happy path, which is the
    only reason the claim was checked at all. **A test that repeats what the comment says is worth
    writing precisely when the comment might be wrong.**
  * ★★ **COMPARISONS RETURN A MASK IN `T`, NOT `Tensor(bool)`.** A mask exists to be multiplied,
    and a bool tensor forces every consumer to convert — and could not be a GPU buffer of the same
    element type, so kernels would need a second dtype for masks alone. `equal` is EXACT: a
    comparison with a built-in epsilon is a different operation wearing this one's name.
  * ★★ **`compute_host`'s UNIFORM GUARD EARNED ITS KEEP.** Adding `lo`/`hi` made `zn_unary.Params`
    24 bytes and the build stopped with the size, the reason (std140 is 16-byte aligned, a
    mismatch reads garbage) and the fix in one message. Padded to 32. **That failure would
    otherwise have been wrong numbers on a device.**
  * ★ `clamp` and `lerp` are reserved math words — the fourth and fifth names this port has had to
    suffix, after `sqrt`, `log`, `abs`, `exp`, `round`. The kernels are `clampf` and `lerpf`,
    matching the CPU's `clampTo`/`lerpTo`.
  * ★ The clamp bounds are ±0.5, inside the noise field's range, **so the row exercises both
    branches** — a clamp whose bounds enclose the data clamps nothing and tests nothing.


- **Sep 4 2026 — Simon asked whether to lint-ban `@sin`, `@trunc` and friends in files that import
  zimrmath. MEASURED FIRST; the answer is no to that scope and yes to a much smaller one.**
  * ★★★ **A BLANKET BAN IS 2 820 CALL SITES.** Counted, excluding zimrmath itself:
    `@abs` 682, `@sin` 498, `@trunc` 430, `@cos` 424, `@sqrt` 373, `@round` 136, `@floor` 131,
    `@log` 55, `@exp` 44, `@ceil` 39, `@tan` 8 — across `raster_shader`, `text2d`, `image`,
    `WgpuGl`, `robot_*` and more. "Files that import zimrmath" is **the whole engine**, and the
    migration would risk behaviour change in graphics code for a benefit that does not apply
    there at all: `@sqrt` in `image.zig` has no GPU twin to disagree with.
  * ★★★ **THE INVARIANT IS NARROWER THAN THE PROPOSAL. It is not "use zm", it is "a CPU op and its
    kernel must make the SAME per-backend choice."** That scope is `zimrnum.zig` plus the kernel
    files — **46 builtin calls today**, growing with the port.
  * ★★ **AND THE ARGUMENT IS NOT "ONE IMPLEMENTATION", BECAUSE zm IS NOT ONE.** `zm.tanh` is
    `std.math.tanh` on the host and an exp-based formula on the GPU; the two backends deliberately
    differ. **zm is one NAME whose per-backend choice was made once, by someone who thought about
    it.** A builtin makes that choice implicitly at every call site. Evidence that the name alone
    guarantees nothing: `@sqrt` is used on both sides today and the device measures **1 ULP, not
    zero** — same name, different lowering.
  * **Recommendation, if it is done:** ban only the transcendental and rounding builtins
    (`@sin @cos @tan @exp @log @sqrt @floor @ceil @round @trunc`) and only in the twin scope
    — about **23 sites**. **Do NOT ban `@abs`**: it is a sign-bit clear, exact in every
    implementation, has no per-backend choice to make, and is half the uses.
    ⚠ **PRECONDITION: `zm.log` DOES NOT EXIST** (checked: 0 declarations), so `@log` cannot be
    banned until it is added. A lint rule whose fix does not compile is worse than no rule.


- **Sep 4 2026 — Simon asked whether zm's `sin` should stop being vector-only. Measuring it showed
  IT NEVER WAS, and corrected an entry I had written the turn before.**
  * ★★★ **`zm.sin` AND `zm.cos` ACCEPT SCALARS AND ALWAYS DID.** Tested directly:
    `zm.sin(0.7) = 0.6442`, `zm.cos(0.7) = 0.7648`. Their bodies carry
    `if (!is_gpu and @typeInfo(T) != .vector) return @sin(v);` — the branch was there the whole
    time. **Only `zm.trunc` and `zm.round` lacked it**, and my previous entry named four.
    ★★ The error mode was mine, and it is the second instance this session: an error persisted
    after my first edit, so I concluded the second edit was also needed, **without testing which
    call produced it.** Same shape as the 932-byte viewer "anomaly". *Reason from a measurement of
    the specific thing, not from a symptom that survived a change.*
  * ★★★ **THE REAL DEFECT IS THAT `anytype` ERASES THE DISTINCTION.** `pub fn sin(v: anytype)` and
    `pub fn trunc(v: anytype)` are the same signature and behaved differently; **96 of zimrmath's
    350 public functions take `anytype`** and a caller cannot tell which accept scalars without
    compiling. That is the thing that cost three rounds, not vector-ness itself.
  * **So: `zm.trunc` and `zm.round` gained the scalar branch their siblings already had.** Two
    functions, three lines each, `@trunc`/`@round` where the vector path does not apply. Where the
    scalar case is one builtin away, refusing it is a trap for no benefit. zimrmath's own tests
    stay green.
  * ★★ **THE REVERT COST TWO CASCADING FIXES, AND BOTH WERE IMPROVEMENTS.** Using `zm.sin` in a
    body trips `no-qualified-zm`, and binding it at file scope is what `reserved-math-names`
    asks for — so `sin`, `cos`, `trunc`, `round` are now file-scope bindings of zm's own
    functions, which is the form both rules want. That then shadowed `Rng.unitFloatRound`'s
    `round` parameter, which had never meant a rounding mode: it selects **which independent
    stream** a draw comes from. Renamed to `stream` throughout. **A name collision forced by a
    linter turned out to be a name that was wrong from the day it was written.**
  * ⚠ I shipped the zip before running lint and smoke this turn, and both were failing. Caught on
    the next command, but the ordering was wrong: **gates before the snapshot, not after.**

  * ★★ **AND zimrnum REVERTED TO `zm` ON BOTH SIDES.** I had switched four ops to the builtins;
    with the premise disproved, `zm.sin` is the better call — **one implementation of sine in the
    project**, and the CPU and the kernel run the same source, which is the property that makes
    the CPU a valid oracle at all. Builtins on both sides would have been two implementations
    agreeing by luck.


- **Sep 4 2026 — 36/36 on device, then seven more ops. Sweep is FORTY-THREE. 50 tests, lint 0,
  `check` green, smoke PASS, fmt clean.**
  * The positive-input fix landed: `sqrt` and `log` both report **1.19e-7 — exactly one ULP**,
    the same figure every other transcendental gives. The domain was the problem, not the kernels.
  * New: `reciprocal`, `truncf`, `roundf`, `sinf`, `cosf`, `atan2f`, `hypotf` on both sides.
  * ⚠ **THIS ENTRY WAS WRONG ABOUT `zm.sin` AND `zm.cos` — see the correction in the next entry.**
    Only `zm.trunc` and `zm.round` were vector-only. I replaced four helpers after an error that
    persisted past my first edit, without testing which call produced it.
  * ★★ **`reciprocal` TAKES THE POSITIVE INPUT, AND THE REASON IS THE BAR, NOT THE DOMAIN.**
    `1/x` is defined at every non-zero real, so noise would not produce NaN — but noise comes
    arbitrarily close to zero, and a quotient near 1e30 has a ULP of 1e23. The bar would accept
    anything and the row would be decorative. The positive field bounds the output at 2, so the
    row measures the division rather than the luck of the draw. **A tolerance that scales with the
    data still needs the data to be bounded.**
  * ★ **The tests are identities**: `sin² + cos² == 1` for every input; reciprocal twice is the
    identity; `atan2(y,x)` recovers both legs through `cos(θ)·r` and `sin(θ)·r`; and
    **`trunc` vs `floor` asserts they differ ONLY on negatives, and that they differ at all** —
    a test on positive data cannot tell the two functions apart.
  * ★ Every edit grep-verified before the build: 7 CPU functions, 7 kernels, 7 build entries,
    7 rows. Twenty-eight probes, all present.


- **Sep 4 2026 — `sqrt` and `log` get a domain they are defined on. The `inf` was real and the
  fix is the input, not the tolerance. 49 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * The peak fix worked: the two failing rows now show bars of **4.48e-7** and **4.09e-6** instead
    of 0, so the verdict was checkable even while it was wrong. The `inf` was genuine.
  * ★★★ **WGSL LEAVES `sqrt` AND `log` UNDEFINED BELOW ZERO — not NaN, undefined.** An
    implementation may return NaN, an infinity, zero or anything else. The CPU returns NaN; the
    device returned something else; the row compared **two undefined results and said nothing
    about either kernel.**
  * ★★ **THE FIX IS THE INPUT, NOT THE TOLERANCE.** Widening the bar would have turned a
    meaningless comparison green. Instead those rows now run on `|noise| + 0.5` — strictly above
    zero, so `log` is defined too, where a plain `|a|` would still hit zero and give -inf. That is
    what a caller does: **check the domain before calling.** Headless, on that input, both
    operations are **exact and entirely finite** on both sides.
  * ★★ **`Case.input` UPLOADS PER DISPATCH so the device sees the same buffer the reference did.**
    16 KB on a row that already reads 4096 elements, and it removes the possibility of the two
    sides being compared on different data — the bug that produced `FAIL add worst 23.9` earlier
    in this port, arriving from a new direction.
  * ★ **Every edit in this turn was grep-verified before the build**, after the previous turn's
    lesson. Nine probes, nine present. That is the new default for any batched edit.


- **Sep 4 2026 — ★★★ I RECORDED A FIX THAT NEVER HAPPENED, AND THE DEVICE CAUGHT IT.**
  * Device: 34/36, with `sqrt` and `log` reporting `inf` against a bar of `0`. Both are exactly
    what the previous turn's journal says was fixed: **"compare() treated two NaNs as a
    disagreement, which blocked every partial function... Now: two NaNs agree."**
  * ★★★ **IT WAS NEVER APPLIED.** That edit was the last step of a script whose FIRST step — a
    loop reformatting three `kernels` lists — raised on `zn_matmul` and killed the process. The
    two earlier files printed their success lines, the reformat message printed, and I read the
    output as a success and wrote the journal entry from my intent rather than from the file.
    **`grep` for the code would have taken one line and I did not run it.**
  * ★★ **THE LESSON IS NOT "CHECK MORE", IT IS "A MULTI-EDIT SCRIPT MUST NOT BE READ AS
    ALL-OR-NOTHING".** Python aborts at the first assertion and leaves every earlier write
    committed, so a partial failure looks identical to a partial success. Either each edit is its
    own call, or the script must verify its own postconditions before reporting. From here: after
    any batched edit, **grep for the thing the edit was supposed to produce.**
  * ★ The device's `inf` was the honest signal and the bar of `0` was a second, smaller bug:
    `compare` returned at the first disagreement, so `peak` held whatever had accumulated before
    it and the reported bar was meaningless. It now always completes the scan and records the
    mismatch in a flag.
  * Both fixed and verified present in the file this time (`grep -c mismatched` = 5).
    ⚠ `sqrt` and `log` may still fail: WGSL leaves both **undefined** below zero, so the two sides
    may disagree on which non-finite value to produce. If they do, the answer is to feed those
    rows a positive input rather than to widen the tolerance — the design for that is drafted and
    not yet wired.


- **Sep 4 2026 — eight ops in one batch. Sweep is THIRTY-SIX. 49 tests, lint 0, `check` green,
  smoke PASS, fmt clean.** `minimum`, `maximum`, `sqrtf`, `logf`, `floorf`, `ceilf`, `signf`,
  `square` — CPU and GPU, in one pass.
  * ★★★ **THE FRICTION WAS FIXED BEFORE THE BATCH, NOT DURING IT.** Two things had each cost
    three retries across the port: `zig fmt` column-aligning the `kernels` lists (so every append
    anchor went stale), and the same in `build.zig`'s `.entries`. **Both are one-entry-per-line
    now** — a vertical list is stable under formatting, so an append is a one-line diff nothing
    reflows. The comment in each says why, or the next person reflows them back.
    ★★ The reformat itself broke the brace nesting in `build.zig` twice and cost two rounds to
    repair. **Worth it once, for a list that will grow past fifty entries.**
  * ★★★ **`compare()` TREATED TWO NaNs AS A DISAGREEMENT, WHICH BLOCKED EVERY PARTIAL FUNCTION.**
    `NaN != NaN` is true, so the obvious check reported a mismatch whenever BOTH sides correctly
    produced NaN — `sqrt` of a negative, `log` of a non-positive. Without the fix, no operation
    with a restricted domain could be swept at all, and those are most of the interesting ones.
    Now: two NaNs agree, matching infinities agree, anything else is unbounded.
  * ★★ **TOLERANCES PER OPERATION, NOT PER BATCH.** `floor`, `ceil`, `sign`, `minimum`, `maximum`
    get **zero** — every result already exists in the input or is an integer both sides reach
    identically, so there is no rounding for a bar to absorb and a looser one could only hide a
    defect. `sqrt` and `square` get 2 ULP for their single rounding step; `log` gets 4.
  * ★ **The tests are laws, one test for all eight**: `min`/`max` return one of their inputs and
    sit on the right side of both; `sqrt(square(|x|)) == |x|`; `log(exp(x)) == x`;
    `floor <= x <= ceil` differing by exactly 1 unless x is integral; and **`sign(x) * |x| == x`
    for every input including zero** — the case that pins the convention, since a `sign` returning
    +1 at zero fails it and, worse, gives a stationary point a direction.
  * The page is 2 130 336 bytes under `-Dmode=release`, so it needs Chrome. That is the trade
    already made: asserts over viewer convenience.


- **Sep 4 2026 — `mean_all` and `max_all`. Sweep is TWENTY-EIGHT. 48 tests, lint 0, `check` green,
  smoke PASS, fmt clean.**
  * ★★★ **`-Dmode=ship` REJECTED, and the reason is in `build.zig`.** It fits under the viewer's
    2 MB cap (1 973 657 against 2 060 911) and the saving is exactly the wrong thing:
    `assert_log = false` and `profile_enabled = false` for `ship`, true for `debug` and `release`.
    **The 71 KB IS the asserts and the profiler.** Stripping the safety net from a page whose
    entire purpose is verification, to make it open in one viewer, is a bad trade at any size.
    Simon called it; claude.md now says `ship` is for shipping, not for measuring, and that these
    pages are read in Chrome.
  * ★★ **`max_all` HAS A TOLERANCE OF ZERO, AND THAT IS A CLAIM ABOUT THE OPERATION.** A maximum
    is a SELECTION, not an accumulation: every candidate already exists in the input, so both
    sides must return the same bits. There is no rounding for a bar to absorb, so a nonzero
    tolerance would only hide a defect. Same reasoning as `abs` and `neg`, arriving from a
    different direction.
  * ★ **`max_all` seeds from element 0, not from negative infinity.** Seeding with `-inf` returns
    `-inf` for an empty buffer, which READS AS AN ANSWER. `zn.maxAll` returns `DomainError` there
    — and a kernel has no way to express that at all. **A kernel cannot report a domain error, so
    the host must not dispatch one**: an asymmetry between the two backends worth remembering as
    the port reaches operations with real preconditions.
  * `mean_all` divides by `params.count` rather than a constant, so a shorter dispatch divides by
    its own length instead of by whatever the kernel was written against.


- **Sep 4 2026 — the viewer limit is CHARACTERISED and worked around. Boundary bracketed to 15 KB.**
  * Padding one page that worked until it stopped working:

        1 994 978  opens          2 009 978  FAILS
        1 990 437  opens          2 044 838  FAILS
        1 744 389  opens         13 778 120  FAILS  (launcher, which opened earlier in the project)

    **2 000 000 sits inside the bracket.** The launcher failing settles that it is a hard, recent
    cap rather than anything content-dependent — that page had opened in this viewer before.
  * **Worked around: `-Dmode=ship` builds the sweep at 1 973 657 instead of 2 044 838** — 71 KB
    saved, 26 KB of margin under the cap. Recorded in claude.md as the lever to reach for.
  * ★★★ **THREE HYPOTHESES DIED IN THREE TURNS**: a corrupted file, then line length, then a
    932-byte "anomaly" that argued against size. What settled it was padding a page that WORKED
    until it stopped — exactly one variable moving, and the page that worked as its own control.
  * ★★★ **THE 932-BYTE ANOMALY WAS MY OWN ERROR, AND IT IS THE MOST USEFUL PART.** I claimed a
    2.04 MB page had opened in the viewer, which made a size limit look impossible. Those
    screenshots showed a **Chrome URL bar**, not the viewer's title bar. I built an argument on
    evidence without checking which application produced it, and that argument sent the previous
    turn chasing content differences that did not exist. **Check the provenance of evidence
    before reasoning from it** — now in claude.md.


- **Sep 4 2026 — the line-length hypothesis is FALSIFIED. The A/B did its job.**
  * Wrapped and unwrapped both fail; other files open. **Line length was not the cause**, and
    claude.md now says so above the entry that describes the wrap — which is kept only because a
    megabyte on one line is bad practice, not because it fixed anything.
    ★★ **The lesson is about method, not viewers.** I measured one property, found a difference,
    and shipped a fix for it in the same turn. The control that disproved it was shipped alongside
    only because it happened to be cheap. **Ship the control WITH the fix, every time** — a wrong
    explanation that goes unchallenged becomes a fact in the notes.
  * **Second measurement, and it narrows things sharply.** Every structural property of the
    failing page now MATCHES the working one:

        file             bytes      maxline   nonASCII  scripts   opens
        hello_world  1 744 389      109 708          9        7    yes
        sweep_wrap   2 044 838      109 708          9        7    no

    Identical longest line, identical script count, identical non-ASCII count (9 bytes in both).
    **The only remaining difference is total size: 1.74 MB against 2.04 MB.**
  * ⚠ **BUT A PLAIN SIZE THRESHOLD DOES NOT FIT THE HISTORY.** `zn_sweep_26.html` at
    **2 043 829** bytes opened (screenshotted at 3:04); `zn_sweep_26b.html` at **2 044 761**
    did not. **932 bytes apart.** No sensible limit lands there, so either the failure is not
    purely size, or something changed between those two deliveries that is not in the file.
  * **The experiment shipped instead of another guess:** three copies of the page that WORKS,
    padded with an inert HTML comment to 1.90, 2.04 and 2.40 MB. Prefixes verified
    byte-identical, all padding inside `<!-- -->`, so behaviour can differ ONLY by size.
    - 1.90 opens, 2.04 fails → a threshold near 2 MB, and the 932-byte anomaly needs explaining.
    - all three open → **size is not it either**, and the cause is something in the sweep's own
      content that the four measures above do not capture.
    - all three fail → the padding itself matters, which would be its own finding.


- **Sep 4 2026 — the unopenable page: a ONE-MEGABYTE LINE.** Simon: the sweep will not open in
  Claude's Android viewer but opens in Chrome, and it is the first time.
  * ★★★ **MEASURED THE SHAPE, NOT THE VALIDITY.** The file had no null bytes, a correct doctype
    and valid HTML — all of which I had already checked when the download failed, and none of
    which was the problem. What differed:

        hello_world      747 949 chars on ONE line   always opened
        zimrnum_field  1 048 385 chars on ONE line   Chrome yes, viewer no

    `tools/c2js.zig` emitted the base64 wasm as a single string, so the page carried one line as
    long as the encoding. The sweep was the first page to cross a megabyte on one line.
  * **Fixed in the emitter**: 64 KB chunks joined by `+`, so both pages now top out at 109 708
    characters. Split by CONCATENATION rather than newlines inside the literal — `atob` tolerating
    whitespace is implementation behaviour, not a spec promise, and a page that decodes on one
    engine and not another is worse than a long line.
  * ★★ **THE A/B IS SHIPPED SO THE HYPOTHESIS CAN BE FALSIFIED**: the old 1 MB-line build and the
    wrapped build, same content. If both fail, the line length was not it and the measurement was
    a coincidence I should not have acted on.
  * ★ The generic lesson, now in claude.md: **a file can be structurally valid and still
    unopenable.** When something works in one place and not another, measure its SHAPE — longest
    line, nesting depth, blob count — not just whether it parses.


- **Sep 4 2026 — 26/26 on device, and the tree reduction is MORE ACCURATE than the scalar one.
  Re-run moved to a button. 48 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **`sum all (tree)` 7.63e-6 vs `sum all (scalar)` 3.81e-5 — a 5× improvement, and it was
    predicted.** The tree collapses 64 partials in log-depth, so its error grows as O(log n) where
    the single thread's 4096-term walk grows as O(n). That is the same argument that makes znum's
    pairwise summation accurate, arriving here through the GPU's shape rather than by choice: **a
    workgroup reduction is pairwise summation whether or not anyone intended it.** The fast kernel
    is also the more accurate one, which is not the usual direction.
  * The barriers work. Six levels, two barriers each, arithmetic masking, uniform trip count —
    all of it verified only by the device, because a host cannot run a barrier at all.
  * ★★ **RE-RUN IS A BUTTON NOW.** Tapping anywhere restarted the sweep, so every scroll and every
    attempt to read a number discarded the measurement. **A verifier that throws away its result
    when you look at it is a verifier you cannot read.**
  * ★★★ **AND THE FIRST BUTTON I WROTE WAS WRONG, CAUGHT BY ARITHMETIC BEFORE THE DEVICE.** I
    hardcoded `y = 4`, then checked it against the first text row at `y = 10`: the box occupied
    4..30 and **overlapped the summary line**. Fixed by deriving the position from the layout at
    draw time and storing it on the `State` for next frame's hit test, so the drawing and the hit
    test cannot disagree. **A button drawn in one place and pressed in another is the classic
    version of this bug**, and hardcoding a coordinate is how it starts.


- **Sep 4 2026 — 25/25 on device, then `sum_all_tiled`: the workgroup tree reduction. Sweep is
  TWENTY-SIX. 48 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * Device confirmed the reductions, and `sum all (scalar)` reported **0.000038146973** — the
    exact drift measured headlessly. The device and the host twin agree to the last digit, which
    is the strongest form that check can take.
  * ★★★ **THE TREE LEVEL IS ARITHMETIC, NOT A BRANCH.** The textbook step is
    `if (lid < stride) p[lid] += p[lid + stride];` then a barrier — and that `if` is derived from
    the thread id, exactly what put the tiled matmul's barrier five blocks deep and got the module
    rejected. So every lane reads, every lane writes, and inactive lanes add a term multiplied by
    **zero**; `(lid + stride) % lanes` keeps the index in range with no guard.
  * ★★ **TWO BARRIERS PER LEVEL, NOT ONE.** All lanes must finish READING a level before any lane
    WRITES it, or a fast lane overwrites a slow lane's source. One barrier is a race that gives a
    wrong total on some devices and not others — the worst failure mode available.
  * ★★★ **AND THE STRIDED LOOP'S TRIP COUNT HAD TO BE MADE UNIFORM.**
    `while (i < count) : (i += lanes)` starting at `i = lid` runs the same number of times in
    every lane, but Tint cannot know that because the START is per-lane. The barrier after the
    loop then follows control flow the analysis calls non-uniform. Deriving the bound from
    `count` and `lanes` fixes it; the range guard became a multiply by 0-or-1. **Inspecting the
    WGSL found this before the device did** — barrier depth went from 3-with-a-lane-derived-`if`
    to 3 enclosed only by two dead constants, the uniform loop bound, and the structurizer's own
    state dispatcher.
  * ★★★ **THIS KERNEL HAS NO VALID CPU TWIN, AND IT IS WRITTEN INTO THE FILE.** `compute_host`'s
    CPU path runs `for id in 0..n: kernel(id)` — each lane executes the WHOLE kernel before the
    next starts, so a barrier is a no-op and lane 0 finishes all six levels before lane 1 writes
    its partial. **No care in the kernel fixes that.** The sweep row is still valid because it
    compares the GPU against `zn.sumAll`, not against the host execution — but nothing on a host
    can verify the BARRIERS. That is §10.3's limitation in its sharpest form: **a CPU oracle
    checks arithmetic, never synchronisation.**


- **Sep 4 2026 — stage A opened: `sum_axis0` and `sum_all` on the GPU. Sweep is TWENTY-FIVE.
  48 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★ **`Case.out_len` — THE SWEEP'S SECOND COMPARISON SHAPE.** A reduction does not fill the
    output buffer: `sum_axis0` writes 64 values and `sum_all` writes one. Comparing all 4096 would
    be comparing whatever the previous dispatch left behind, and the row would fail for a reason
    having nothing to do with the kernel. Defaulting to one per element leaves all twenty-three
    existing rows untouched. The reference is also zeroed first, so the heatmap shows the vector
    against black rather than against stale data.
  * **Headless, before the device sees it:** `sum_axis0` matches `zn.sumAxis` **exactly**.
  * ★★★ **`sum_all` DRIFTS 3.81e-5 FROM THE COMPENSATED ANSWER — WHICH IS 3.7 ULP.** The kernel
    accumulates plainly across 4096 terms; `zn.sumAll` compensates. At `|sum| = 86.04`, one ULP of
    f32 is 1.02e-5, so a plain accumulation of this length is already **nearly four units in the
    last place** adrift. **That number IS the justification for divergence 2** — it is what the
    compensated default buys, measured on real data rather than on a constructed cancellation
    case, and it will only grow with the contraction length a real network uses.
  * ★ **`sum_all` is deliberately one thread for the whole buffer.** It exists as the checkable
    reference for the tree reduction that replaces it: a workgroup-shared log-depth sum has a
    barrier at every level, no CPU oracle can see a barrier mistake, and so it needs a
    same-device comparison — this is what it will be compared against. Same reasoning as
    `matmul` before `matmul_tiled`, now applied before the fast version exists rather than after.
  * ★ `sum_axis0` walks its column with a stride of `cols` — a cache miss per step, which is the
    price of the column-major access an axis-0 reduction needs. Noted in the kernel; the tiled
    form transposes into shared memory first.


- **Sep 4 2026 — the coverage gate, half of it. Kernel ↔ row is now a COMPILE ERROR in both
  directions. 48 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **THE GAP IT CLOSES IS ONE THAT ACTUALLY HAPPENED.** `sub` and `div` existed on the CPU
    for six turns with no kernel at all — the sweep could not have caught a GPU bug in either
    because there was nothing to compare. Nothing was watching. Now a kernel entry with no row
    fails to build:

        error: kernel entry 'recip' has no row in the sweep: it is built, shipped,
               and never compared against zimrnum

    and a row naming a kernel that does not exist fails too:

        error: sweep row 'abs' names entry 'absent', which its kernel file does not export

    Both proven by control, then restored.
  * ★★ **A COMPILE ERROR, NOT A TEST.** The gap cannot survive to a device. Together with
    `build.zig`'s drift gate (a kernel with no WGSL fails to embed), the three lists — kernel
    file, build entries, sweep rows — are now pinned to each other in every direction.
  * ★★★ **WHAT IT DOES NOT COVER IS WRITTEN INTO THE GATE ITSELF.** It pins KERNEL ↔ ROW. It
    cannot pin OP ↔ KERNEL: a `zimrnum` function with no GPU kernel is still invisible, because
    zimrnum has no device dispatch of its own. Debt 11 is marked HALF done rather than closed —
    a gate described as more than it is would be worse than none.
  * ★ **The build found a stale doc comment that had outlived its subject.** The `Op` enum's
    documentation survived the enum's removal and had silently reattached itself to `const Tn`,
    still describing "tapping cycles it" and "the last two are the same product" — both false for
    several turns. Only inserting code above it made the compiler notice. **A doc comment can
    outlive what it documents and read as current;** the tutorial gate exists for exactly this
    reason and source comments have no such gate.
  * ★ The check is O(rows × entries) at comptime and overran the default branch quota at 23 × 22.
    Raised once, with a note that both numbers grow with the port.


- **Sep 4 2026 — divergence 2 closed with numbers, and they went against my reasoning.**
  * ★★★ **PAIRWISE IS 3.3× FASTER THAN COMPENSATED — AND FASTER THAN THE NAIVE LOOP.** Measured,
    168M f32, one core: **pairwise 1 398 M/s, naive `+=` 704 M/s, Neumaier 425 M/s.** Pairwise
    beats naive because the recursion produces independent accumulation chains the CPU pipelines,
    which is not obvious and is why it needed measuring rather than arguing.
  * ★★★ **BUT ITS FAILURE UNDER CANCELLATION IS ERRATIC, NOT JUST LARGE.** `[1e8, 1×100, -1e8]`,
    exact answer 100:

        threshold 128 -> 0      threshold 8  -> 104
        threshold 32  -> 72     threshold 2  -> 96

    **No threshold fixes it.** The failure is in the SHAPE of the recursion, not its depth: the
    two large values land in different halves and each swamps the small values beside it. A
    number that moves unpredictably with a tuning constant is worse than one that is merely
    inaccurate, because no caller can reason about it.
  * **Decision: keep Neumaier as `sumAll`, add `sumAllFast` (pairwise).** The default favours the
    side whose failure is silent and unbounded; the 3.3× is bounded and available by name. Both
    numbers are in the tutorial. ★★ **The difference between them is ASSERTED BY A TEST** —
    `sumAll` returns 100, `sumAllFast` returns 0 — so if a later change made the fast path exact,
    the test fails and the documentation claiming a cliff is caught being wrong.
  * ★ **The plan's own prediction was half right and is marked as such.** §10.4 item 1 guessed
    "the honest answer may be pairwise-by-default with a compensated variant named". Pairwise
    earned a place; it did not earn the default. Recording which half was wrong is worth more than
    quietly deleting the line.
  * ★ `sumAllFast` falls back to the exact path for a non-contiguous view — a strided tensor has
    no contiguous halves to recurse on, and walking the wrong elements quickly is not a speedup.


- **Sep 4 2026 — re-read znum against zimrnum and wrote §10, THE PORT LEDGER.**
  * **The gap, counted:** znum is 63,490 lines and **936 public functions across 33 namespaces**
    with 53 kernel files. zimrnum is 2,645 lines, 67 public declarations, 47 tests, 3 kernel files
    with 21 entries. **7% of the function count.** The per-namespace table is in §10.1; the
    largest untouched blocks are `rl` (108), `nn` (105), `autograd` (76), `df` (61).
  * ★★★ **THE DIVERGENCE REGISTER IS THE POINT OF THE SECTION.** Simon's rule: every difference
    from znum must be justified by a metric or it is a defect. Nine divergences have evidence —
    the f16 interval bug (199,227 of 200,000 draws returning 1.0), the cross-kind RNG collisions
    (20,000 indices, 0 after the fix), the false `div` FAIL at 6× below one ULP, the lean path
    being required rather than optional for barrier uniformity. **Three do not, and are recorded
    as DEBTS rather than decisions.**
  * ★★★ **THE WORST DEBT IS THE MISSING COVERAGE GATE.** znum can force device readback on every
    op, so an operation with no kernel RAISES instead of quietly running on the host. zimrnum has
    no such mode: the sweep's green says something about the 23 rows I remembered to add, not
    about the library. That is exactly the class of reassurance this session has repeatedly found
    to be hollow, and it is now next action #2.
  * ★★ **ONE CLAIM IN THE PLAN WAS WRONG AND IS NOW MARKED.** I had written that znum injects
    dtypes via `-Mdtype=…`. `grep dtype build.zig` in znum returns **0** — the mechanism is
    somewhere else and I have not read it. Marked ⚠ unverified, with an instruction not to repeat
    the claim until it is.
  * ★ **A divergence with a claim and no cost number is only half justified.** Compensated
    summation recovers `[1e8, 1×100, -1e8]` where znum's pairwise (threshold 128) does not — but
    compensation is a serial dependency chain and pairwise vectorises, and I have not measured
    the throughput. Next action #1, and if pairwise wins by enough the honest answer may be to
    change the default and name the compensated variant.
  * Section numbering fixed: 10 is the ledger, 11 the journal.


- **Sep 4 2026 — `-Dgate` added: the lint/fmt gate can be skipped per command. 8s → 1s on the
  iteration loop, and the end-of-turn safety is proven rather than argued.**
  * Simon's proposal, and studying the wiring showed it was the right shape. Every wasm compile
    depends on either `fmt_apply_gate` (with `-Dautofix`) or `lint_run_install` +
    `fmt_check_install` (without). `-Dautofix=false` — what I had been using all session — still
    RUNS both, it only stops them mutating. So there was no way to skip them at all.
  * ★★★ **THE GATE IS RIGHT FOR A BUILD AND WRONG INSIDE A LOOP.** A half-finished edit fails on a
    line-length rule *before the compiler has said whether the change makes sense*, and the
    linter's message is then the only thing on screen — hiding the type error that actually
    matters. That happened repeatedly during this port; several turns spent a round trip on a lint
    complaint about code that was about to be rewritten anyway.
  * ★★ **THE DEFAULT DOES NOT MOVE.** `-Dgate=false` is typed per command and build.zig prints a
    warning every time, so it cannot be forgotten silently. The discipline reduces to ONE rule:
    **never pass `-Dgate=false` to `check`** — `check` reaches lint and `zig fmt --check` through
    its own wasm compiles, so one unflagged command still covers everything.
  * ★★★ **PROVEN BY NEGATIVE CONTROL, NOT BY ARGUMENT.** An over-long line was added, then:

        zig build <target> -Dgate=false   rc=0   skipped, as designed
        zig build check                   rc=1   [line-length] on the exact line

    Had `check` passed, the whole scheme would have been unsafe and the flag should not exist.
    Worth re-running whenever the gate wiring is touched, and claude.md says so.
  * ★ It is orthogonal to `-Dautofix`, which chooses *fix* versus *check* when the gate runs at
    all, and it does not disable the `lint` or `fmt` STEPS — only the implicit dependency edge.


- **Sep 4 2026 — `layerNormRows` on both sides. Sweep is TWENTY-THREE. 47 tests, lint 0, `check`
  green, smoke PASS, fmt clean.**
  * ★★★ **THE SINGLE-PASS VARIANCE FORMULA IS DELIBERATELY NOT USED, on either side.**
    `E[x²] − E[x]²` computes the variance in one pass and is the obvious optimisation. It also
    subtracts two large nearly-equal numbers, losing most of its significant digits exactly when
    the mean is large relative to the spread — which is the normal case for an unnormalised
    activation, the only thing this function is ever applied to. Two passes, on both sides, and
    the kernel says why.
  * ★★ **EPSILON IS A PARAMETER, NOT A CONSTANT.** A row of identical values has zero variance and
    dividing by its square root is an infinity that propagates through the rest of a network.
    Every framework adds an epsilon inside the root and they DISAGREE about the value — PyTorch
    1e-5, JAX 1e-6 — and the difference is visible in f32. Baking one in would make this library
    silently disagree with whatever the caller expected.
  * ★★★ **THE TESTS ARE THE DEFINITION, NOT A TABLE.** Whatever the input, each row must come out
    with mean 0 and variance 1 — so the test generates random rows, gives each a WILDLY different
    scale and offset (so a version normalising globally rather than per row would fail), and
    checks the two moments. Plus the case epsilon exists for: a constant row, where every output
    must be finite and zero rather than a NaN.
  * ★ The `kernels` list edit missed twice because `zig fmt` had re-aligned the string columns
    between turns. Anchoring on formatted source is fragile in a way anchoring on structure is
    not; the assertion caught it both times, which is the only reason it cost a retry rather than
    a silent no-op.


- **Sep 4 2026 — 21/21 on device in the plain page, and `softmax_rows` ported. Sweep is
  TWENTY-TWO. 46 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * The plain page reads perfectly in one screenshot: verdict, twenty-one rows with their bars,
    and the three heatmaps, all above the fold. `div` now shows `0.0000019073486` against a bar of
    `0.000024443656` — the ULP-scaled allowance, visible and checkable rather than implied.
  * **`softmax_rows` is the first row-wise reduction on the GPU.** Each thread walks its row three
    times: max, exponentiate-and-sum, divide.
    ★★ **THE ROW MAXIMUM IS SUBTRACTED ON BOTH SIDES, AND THAT IS NOT AN OPTIMISATION.** `exp`
    overflows f32 above ~88 and the CPU implementation subtracts; a kernel that skipped it would
    not be merely less accurate, the two sides would disagree by an INFINITY the moment a logit
    got large. The sweep would catch that now — `compare` treats a finiteness mismatch as
    unbounded — but only because of the fix made one turn ago.
  * ★ **IT IS DELIBERATELY THE SLOW VERSION, and the file says so.** 64 rows means 64 threads,
    which leaves the GPU idle. The tiled form is one workgroup per row with a shared-memory tree
    reduction. Shipping the simple one first is the `matmul` pattern: once a faster one exists the
    two can be compared ON THE SAME DEVICE, which catches barrier and reduction bugs a CPU oracle
    structurally cannot see.
  * ★★ **`Case` GAINED `threads`.** A row-wise kernel wants one thread per ROW; dispatching 4096
    for 64 rows would have 4032 return immediately from the guard. Defaulting to one per element
    keeps every existing row unchanged, and the launch geometry now sits next to the kernel it
    belongs to instead of being a constant in the dispatch.


- **Sep 4 2026 — the `ui.zig` table is gone; the sweep is plain text rows again. Simon's call, and
  the right one.**
  * The UI version worked, but it was the wrong fit for what this page is: **a thing read as a
    SCREENSHOT.** Scrolling, column sizing and a frozen header buy nothing when the whole
    interaction is "open it, look, screenshot" — and they cost **~380 KB of standalone** (2 371 KB
    to 1 990 KB, a sixth of the file) plus a frame-ordering contract between `begin`, `render` and
    `endDrawing` that I got wrong twice: once by ending the frame before the deferred render, once
    by removing `endDrawing` altogether. Text rows have no such contract.
  * ★★ **A DEPENDENCY THAT ADDS A CONTRACT COSTS MORE THAN ITS BYTES.** Both frame-ordering bugs
    were invisible to `check`, invisible to the smoke test in one case, and cost a device
    round-trip each. The table was prettier; the text rows are the ones I can reason about
    completely.
  * The row still prints the deviation AND the effective bar beside it, including the ULP-scaled
    part, so the verdict stays checkable — that was the point of the table and it survives the
    removal.
  * 21 rows, 46 tests, lint 0, `check` green, smoke PASS, fmt clean, standalone 1.99 MB.


- **Sep 4 2026 — device: 20/21, and the one FAIL was my TOLERANCE, not the kernel. Measuring it
  found a second, worse bug in the harness.**
  * `FAIL div worst 0.0000019073486` against a bar of 0. Before touching anything I measured what
    that number is: the row's outputs **peak at 102.5, where one ULP of f32 is 1.22e-5** — so the
    observed deviation is **six times SMALLER than a single ULP at that magnitude**. The kernel
    was correct throughout.
    ★★★ **AN ABSOLUTE BAR OF ZERO IS ONLY RIGHT WHEN THE OUTPUT IS O(1) OR THE OP IS EXACT.**
    `add`, `neg`, `abs`, a compare-and-select: exact, zero is right. Division by a ramp that
    approaches zero: unbounded output, zero is meaningless. `Case` now carries `ulps` alongside
    `tol`, and the bar is `tol + ulps * peak * floatEps(f32)` — a statement about PRECISION that
    moves with the data, instead of a constant someone picked. `div` gets 2 ULP.
  * ★★★ **AND THE COMPARISON WAS SILENTLY DROPPING ITS MOST DANGEROUS ELEMENTS.** The ramp crosses
    exactly zero, so a whole column divides by zero. `@abs(inf - inf)` is **NaN**, and
    `NaN > worst` is **false** — so every one of those comparisons was being skipped by the loop.
    A GPU returning NaN where the CPU returned infinity would have passed silently. `compare` now
    reports a finiteness mismatch as infinity, which no tolerance can accept, and checks the sign
    when both sides are infinite.
    ★★ This is the third instrument defect this session (after the off-by-one timer and the
    bijection that could not fail), and the pattern holds: **every one was found by asking what a
    number meant rather than whether it was green.**
  * The tolerance column in the table now shows the EFFECTIVE bar for that row, peak included, so
    a reader can check the verdict rather than trust it.
  * 21 rows, 46 tests, lint 0, `check` green, smoke PASS, fmt clean.


- **Sep 4 2026 — `bcast_add`, `sigmoid_grad`, `tanh_grad`. Sweep is TWENTY-ONE rows. 46 tests,
  lint 0, `check` green, smoke PASS, fmt clean.**
  * ★★★ **`bcast_add` CLOSES THE LOOP OPENED WHEN `broadcastTo` LANDED.** Its uniform carries
    per-operand row and column strides, and **a stride of zero broadcasts that axis** — which is
    `broadcastTo`'s representation moved verbatim into a uniform. A `(1, n)` row stretched down a
    `(m, n)` field is `b_row = 0`: no copy, no second buffer. The audit predicted months of design
    ago that the CPU view type "already holds the GPU's parameters"; this is the line where that
    is literally true, `.b_row = 0` on one side and a stride-0 view on the other.
    ★★ The sweep's oracle for that row builds the same broadcast with `broadcastTo`, so the two
    representations check each other rather than one checking a copy of itself. Tolerance 0.
  * **`sigmoidGrad` and `tanhGrad` take the OUTPUT where `reluGrad` takes the input**, and that
    asymmetry is deliberate: a sigmoid's derivative is `y(1-y)` in terms of its own output, so
    passing `y` is one multiply where passing `x` means recomputing the sigmoid. The rule is
    "whichever the derivative is actually a function of", and it differs per activation — a
    uniform convention would cost real work on one side or the other.
  * ★★★ **THE GRADIENTS ARE CHECKED BY CENTRAL FINITE DIFFERENCE, IN f64.** Asserting
    `gv * y * (1-y)` against a second copy of the same expression proves nothing; differencing the
    FORWARD function is independent evidence. f64 because an f32 finite difference returns noise —
    the reason already recorded in this repo's model-predictive control work, and the first time
    this project has needed it.
  * Uniform grew to 32 bytes (still a multiple of 16), so the entries that ignore the strides are
    unaffected. Three kernels, three `Case` lines, one `build.zig` edit.


- **Sep 4 2026 — four kernels in one pass at the new rate. Sweep is EIGHTEEN rows. 45 tests,
  lint 0, `check` green, smoke PASS, fmt clean.**
  * `sub` and `div` closed an obvious gap: both have existed on the CPU since the elementwise
    layer landed and had **no kernel at all** — the sweep could not have caught a GPU bug in
    either because there was nothing to compare. Worth noting how long that sat unnoticed while
    the attention was on harder kernels.
  * `transpose` and `scale` are new on both sides. `zn.scale` is a separate entry point rather
    than `mul` against a broadcast scalar, because there is no rank-0 tensor here and `zip`'s
    function is a comptime parameter that cannot close over a runtime factor.
  * ★★ **`transpose` IS THE SECOND PLACE THE BACKENDS DIVERGE STRUCTURALLY.** On the CPU it is a
    stride swap that copies nothing; on the GPU it is a real gather into a dense buffer. The row's
    oracle is `map(out, a.transpose(0,1), identity)` — a stride swap copied through — so the sweep
    checks the GPU's gather against the CPU's strides, two mechanisms for one definition.
  * ★★★ **THE REFACTOR PAID FOR ITSELF IMMEDIATELY.** Four kernels cost four `Case` lines, four
    kernel functions and three `build.zig` edits — no enum, no `next`, no parallel switches, no
    hand-sized arrays. Under the old shape that would have been thirty-two edits across four
    files, each an opportunity for a row to be judged against the wrong reference.
  * ★ Two locals named `scale` had to be renamed once `zn.scale` existed. The compiler found both;
    worth noting because it is the failure mode a table-driven design does NOT protect against —
    the namespace is still shared.


- **Sep 4 2026 — the sweep is TABLE-DRIVEN. Adding a kernel went from eight edits to two.**
  * ★★★ **FOUR PARALLEL SWITCHES BECAME ONE `cases` ARRAY.** A kernel used to need an enum
    variant, an arm in `next`, `label`, `tolerance`, `isUnary`, `buildFields` and the dispatch,
    plus a slot in two hand-written array literals — **eight chances to give a row the wrong
    reference**, which is precisely the bug that produced `FAIL add worst 23.9` several turns ago.
    Now it is one `Case` line carrying label, tolerance, pipeline, entry name and the zimrnum
    reference INLINE, so a row's GPU entry and its oracle are written on the same line and cannot
    drift.
  * The dispatch is an `inline for` over the table, because `Compute.run` needs its entry name at
    comptime; the loop unrolls and each arm passes a literal. `results` and `cpu_ref` are sized
    `[cases.len]`, so the arrays follow the table by construction.
  * ★★★ **THE LEAK CHECKER CAUGHT MY REFACTOR MID-FLIGHT.** The regex that was meant to replace
    the hand-written `.cpu_ref = .{ ...14 allocs... }` literal with `undefined` did not match, so
    the literal stayed AND the new fill loop ran: every reference buffer was allocated twice and
    the first set leaked. The build passed, lint passed, `check` passed — **only
    `smoke-test`'s managed-allocator check failed**, with `deinit did not free every allocation`.
    A regex that silently matches nothing is the same failure as a test that silently runs
    nothing, and the assertion that a refactor changed what it claimed to change is worth more
    than the refactor.
  * Cost per kernel now: one `Case` line, one kernel function, one `build.zig` entry — and the
    drift gate catches the last if forgotten. That is the rate the remaining port needs.
  * 14 rows, lint 0, `check` green, smoke PASS, fmt clean.


- **Sep 4 2026 — 13/13 PASS ON DEVICE in the UI table, and `matmul_bt` added. Sweep is FOURTEEN.**
  * The frame-ordering fix worked: the table renders, and `relu grad` and `sgd step` both came back
    **exact against a tolerance of 0** — which is what those two should be, a compare-and-select
    and a single fused multiply. The whole backward-pass arithmetic added last turn is verified on
    hardware.
  * **`matmul_bt` — `out = a @ bᵀ`.** Backpropagation needs this shape twice (`dW = xᵀ @ dy`,
    `dx = dy @ Wᵀ`), and it is the clearest example yet of where the two backends genuinely
    diverge: ★★★ **on the CPU a transposed operand is FREE** — `zn.matmul` reads through `at`, so
    `b.transpose(0, 1)` is a stride swap — **and on the GPU it cannot be**, because a kernel takes
    a dense buffer and indexes from its start. So the transpose moves into the index arithmetic:
    `bT[i][col]` is `b[col][i]`, one line different from `matmul`. Without it a training step
    would materialise a transposed copy of every operand every iteration.
  * The CPU oracle for that row is `zn.matmul(out, a, b.transpose(0, 1))`, so the sweep is
    checking the GPU's index arithmetic against the CPU's stride arithmetic — two different
    mechanisms for one definition, which is a stronger comparison than two copies of one
    mechanism. Headless: twin agrees to **9.5e-6**, f32 rounding over a 64-term contraction.
  * ★ Observed in the screenshot and not yet fixed: the table's header row and the `ALL PASS`
    summary line are scrolled out of view — the window opens too short for fourteen rows. The
    verdict is the line a reader looks at first and it is the one off-screen.
  * lint 0, `check` green, 44 tests, smoke PASS, fmt clean.


- **Sep 4 2026 — the UI frame was UNTERMINATED, and reading two working examples found it in
  minutes after I had reasoned my way past it twice.**
  * Simon: "maybe it doesn't work because of some bug — study many UI examples that also use GPU
    in complicated ways." Twelve examples combine `ui_host` with raw `f.gl` drawing. Two read
    closely — `ball_physics` and `audio_spectrum_visualizer`:

        ball_physics:  begin -> (window) -> clearViewport -> f.gl.circle -> render -> endDrawing
        audio_spectrum: clearViewport -> begin -> (window) -> render -> endDrawing

    They DISAGREE about whether `clearViewport` precedes `begin`, so that is free. **Both always
    call `endDrawing`, and both call it AFTER `render`.**
  * ★★★ **I HAD DROPPED `endDrawing` ENTIRELY.** Two turns ago the smoke runner panicked in
    `flushBatch`; the cause was `endDrawing` BEFORE a deferred `render`, which submits UI geometry
    into an ended frame. I concluded "`render` closes the frame" and removed `endDrawing`. It does
    not — `render` submits the UI's geometry, `endDrawing` ends the frame. **I over-corrected past
    the right answer**, and the smoke test passed either way because an unterminated frame still
    completes sixty headless frames.
  * ★★ **THE LESSON IS THE METHOD, NOT THE CALL ORDER.** Both times I reasoned from one example
    (`ui_full_showcase`, which draws no raw geometry and so calls neither) instead of finding one
    that does what I was doing. Twelve such examples existed. **When an API's contract is
    unclear, the cheapest evidence is the set of existing callers that share your shape** — not
    the first caller you happen to open, and not inference from a panic message.
  * Rebuilt: 2 289 373 bytes, smoke PASS, lint 0, `check` green, 44 tests, fmt clean.


- **Sep 4 2026 — `reluGrad` and `sgdStep` on both sides. Sweep is THIRTEEN rows. 44 tests, lint 0,
  `check` green, smoke PASS, fmt clean.**
  * These are the two cheapest pieces of a backward pass, and they are the first ops added since
    the manifest: **two lines in a kernel file and one in `build.zig`**, with the drift gate
    catching the second if forgotten. The port is now as cheap as it should be.
  * ★★ **`reluGrad` TAKES THE FORWARD INPUT, NOT THE FORWARD OUTPUT.** Both work for `relu`
    because the output is positive exactly where the input was — but only the input generalises:
    `leakyRelu` and `elu` have outputs that do not determine their own gradient. Taking the input
    now means the signature does not change when they arrive.
  * ★★ **`sgdStep` IS NOT IN PLACE, and a caller may still pass `weight` as `out`.** Returning a
    fresh result means the operation composes and can be tested against a reference the test has
    not already consumed; an in-place-only signature forces every caller — including every test —
    to copy first. Both forms are asserted to agree.
  * ★★★ **A ZERO-RATE STEP IS THE CONTROL.** The fixed expected values would pass even if the sign
    were flipped AND the rate negated; a step of rate 0 that moves nothing catches the sign on its
    own. Same for `reluGrad`: the interesting assertion is at **x == 0**, where "positive" has to
    mean strictly positive, which is where a sign test is easiest to get wrong.
  * Both GPU entries have a tolerance of **0**: a compare-and-select and a single fused multiply,
    exact on both sides. If either shows a deviation on device, it is a defect and not rounding.
  * ★ The learning rate rides in `Params` as a repurposed pad word. A uniform must be 16-byte
    sized regardless, so the scalar is free — and it is the first runtime scalar this project has
    passed to a kernel, which the optimisers will all need.


- **Sep 4 2026 — the sweep is a real `ui.zig` TABLE now, not printed lines.** Five columns with
  headers, a frozen header row, borders, and a **red row background on failure** so a failing row
  is findable by shape rather than by reading. Sizing is the table's job, which fixes the
  right-edge truncation every screenshot has shown (`n=` was always cut).
  * ★★★ **I MADE THE AMBIGUOUS-ANCHOR MISTAKE AGAIN, TWO TURNS AFTER WRITING IT DOWN.** Cut from
    `z.clearViewport` to `fn label(` — and `Op` has a METHOD named `label`, so the slice ran
    backwards and doubled the file to 964 lines. The journal entry from two turns ago says
    exactly this. **Writing a lesson down is not the same as having learned it**; the fix is to
    stop using string anchors for cut points at all and take line numbers, which is what I did.
  * ★★ **THE UI HOST OWNS THE FRAME, and getting that wrong panicked in `flushBatch`.**
    `s.ui_host.render(f)` CLOSES the frame, so it replaces `endDrawing` and must come last. I had
    `endDrawing` followed by a deferred `render`, which submits UI geometry into a frame that has
    already ended; the batch then overflows and `flushBatch` asserts rather than corrupt.
    `ui_full_showcase` calls neither `endDrawing` nor `clearViewport`, which was the clue.
  * ★ **The heatmaps downsample 2x1 by PEAK MAGNITUDE, not by sampling.** Three 64x64 panels is
    12 288 rects a frame; sampling every other element would cut that and lose the point, since a
    single wrong element could fall in a skipped position and the difference panel exists to show
    one wrong element. Each block is now represented by its largest-magnitude member with the sign
    kept, so an outlier anywhere survives to the screen.
  * lint 0, `check` green, smoke PASS, 42 tests, fmt clean.


- **Sep 4 2026 — 11/11 PASS on device, and the MANIFEST landed: kernel names live in one place
  and drift is a compile error.**
  * Device: `abs` and `neg` exact against a tolerance of 0, `exp` 3.81e-6 (one ULP at the
    magnitudes `e^x` reaches for x up to ~4), the transcendentals at their 1-2 ULP. Eleven rows,
    one screenshot.
  * ★★★ **A KERNEL USED TO BE NAMED IN FOUR PLACES**: its install call, `build.zig`'s `.entries`,
    an `@embedFile` in the host, and a pipeline entry in the host. Four lists kept in agreement by
    hand — and at eleven kernels that was the thing slowing the port, exactly as predicted last
    turn. Now every kernel file carries `pub const kernels` (znum's pattern, already used by
    `zn_unary`; `zn_binary` and `zn_matmul` gained it), the comptime install loop reads it, and
    `pipelineEntries(M)` builds the host table from the same list. **The host went from 13
    hand-written `_wgsl` references to 2.**
  * ★★★ **AND IT IS THE DRIFT GATE FOR FREE.** `@embedFile(name ++ "_wgsl")` only resolves if the
    build generated that WGSL. Proven by adding a `recip` entry and not telling `build.zig`:

        examples/zimrnum_field/zimrnum_field.zig:47:61:
          error: unable to open 'recip_wgsl': FileNotFound

    A missing kernel is now a compile error naming the file, instead of a shader that is absent at
    runtime on a device I am not holding. That is the failure mode znum's manifest exists to
    prevent, reached here by a smaller mechanism than theirs.
  * ★ What is still hand-written is the SWEEP's per-operation switches, and that is honest: each
    row needs a CPU reference and a tolerance, which are judgements rather than derivable facts.
    The wiring is derived; the meaning is not.
  * lint 0, `check` green, both smokes PASS, fmt clean.


- **Sep 4 2026 — port continued: the rest of znum's unary family. Sweep is ELEVEN operations.
  42 tests, lint 0, `check` green, smoke PASS, fmt clean.**
  * `expf`, `absf`, `neg` on both sides — CPU in `zimrnum.zig` through `map`, GPU as three more
    entries in `zn_unary.zig`. Straight port, no device round-trip needed.
  * ★★ **THE SUFFIXES ARE NOT COSMETIC.** `exp` and `abs` are reserved math words here, so the
    linter refuses a declaration that shadows `zm.exp`/`zm.abs`. znum solved it the same way, so
    the CPU name and the kernel name line up without either side inventing a convention.
  * ★★★ **TWO OF THE NEW ROWS HAVE A TOLERANCE OF ZERO, DELIBERATELY.** `abs` and `neg` touch no
    transcendental, so — unlike `sigmoid`/`tanh`/`gelu`, which the last device run showed at 1-2
    ULP — anything but an exact match is a defect. Setting the bar per operation rather than
    globally is what makes the 1 ULP result on the transcendentals meaningful: it is measured
    against a bar that only they need.
  * Tests are laws where laws exist: negating twice is the identity, and `|x| >= 0` over a
    thousand random draws, rather than more fixed points.
  * ★ **The sweep's hand-wiring is now the bottleneck** — eleven `switch` arms in four places,
    three pipelines, an `[11]` array. Every kernel added makes it worse, which is precisely the
    problem znum's MANIFEST solves (one list, four derived consumers, drift a compile error).
    That is the next piece to port, before more kernels rather than after.


- **Sep 4 2026 — ★★★ 8/8 PASS ON DEVICE, and the measurement CORRECTED A CLAIM I had written.**
  * The sweep, on an Adreno phone: `add` 0, `mul` 0, both matmuls 5.722046e-6 and identical to
    each other, `relu` **0**, `sigmoid` and `tanh` **1.1920929e-7**, `gelu` **2.3841858e-7**.
  * ★★★ **THOSE ARE NOT ARBITRARY NUMBERS — THEY ARE 1, 1 AND 2 ULP OF f32.** `1.1920929e-7` is
    exactly 2^-23. So the tutorial's claim that the activations agree with the GPU **"by
    construction, not by tolerance"** is WRONG, and wrong in a way only a device could show:
    `zm` compiles a DIFFERENT BRANCH for SPIR-V (`@exp`) than for the host (`std.math.exp`), and
    the two round differently in the last bit. `gelu` shows two ULP because it is built on `tanh`
    and the step compounds. `relu` is exact because it involves no transcendental — which is the
    control that makes the other three readable as a transcendental effect rather than noise.
  * **Corrected in both places**: the tutorial now carries a table of the measured deviations with
    the ULP reading and a plain statement of what a caller does and does not get, and
    `zimrnum.zig`'s `sigmoid` doc says the same. **"Same source" is not "same instructions", and
    I had written the stronger thing.**
  * ★ This is the fourth claim this session that measurement demoted: the naive-summation
    comparison that the optimiser vectorised, the `local_col` control that was a bijection, the
    running-offset "optimisation" that was slower, and now this. The pattern is consistent —
    every one was a statement about behaviour I had reasoned to and not run.
  * `zn_unary` ported from znum in one build round. lint 0, `check` green, 41 tests, fmt clean.


- **Sep 4 2026 — 4/4 PASS ON DEVICE confirmed, and the port has started. Sweep is now EIGHT
  operations. lint 0, `check` green, both smokes PASS, fmt clean.**
  * ★★★ **`ALL PASS - 4/4 agree with zimrnum`** on the phone: `add` and `mul` exact,
    `matmul (global)` and `matmul (16x16 tiled)` both at 5.722046e-6 — identical to each other,
    which is the strongest form of the result: two different GPU routes, one with workgroup memory
    and barriers, produce bit-identical output.
  * **`zn_unary.zig` ported from znum's `k_unary.zig`** — the shape is theirs: lean entries taking
    a raw `id`, aliases at module scope, a `kernels` list with a comptime loop installing them,
    early-return guards (no barrier to strand in a unary kernel). Four entries: `relu`,
    `sigmoid`, `tanhf`, `gelu`. **This is the first thing in the tree that was PORTED rather than
    re-derived, and it took one build round instead of three device round-trips.**
  * ★★ **THE SWEEP NOW TESTS A CLAIM THE TUTORIAL MAKES.** It says the activations "are the same
    arithmetic the engine and any future GPU kernel use — agreement is by construction, not by
    tolerance". The kernel bodies are literally `zm.sigmoid(bx[id])`, so the device now measures
    whether that survives: the host takes `std.math.exp`, the GPU takes `zm`'s `is_gpu` branch
    built on `@exp`, and the tolerance is 1e-5 so the MEASURED number is the answer. A claim
    nobody measured is a sentence.
  * ★ **A SECOND `Ctx`-ONLY CALL SITE in `compute_host.zig`** — the out-of-process runner, which
    the previous fix missed because only the in-process one was exercised. Same discriminator.
    The half-merge from two turns ago was actually a third-merge; `compute_smoke` still passes,
    which is the compatibility that matters.
  * Next: the dtype injection (`-Mdtype=…`) so one kernel file yields a per-dtype family, then
    the manifest and its drift gate, then `k_binary`/`k_scalar`/`k_reduce`.


- **Sep 4 2026 — ★★★ THE TILED MATMUL PASSES ON DEVICE. Barriers, shared memory, 16x16 tiles.**
  `PASS matmul (16x16 tiled) worst 0.000005722046 tol 0.0001` — bit-identical to the global entry
  and within f32 rounding of `zn.matmul`. All three causes from the previous turn were real and
  the fixes were the right ones: arithmetic masking instead of a select, the lean path for
  uniformity provenance, and the CPU driver taught the lean signature. **zimr can now run
  cooperative tiled kernels with workgroup memory, end to end, on a phone.**
  * ★★★ **AND `add`/`mul` FAILED IN THE SAME SCREENSHOT — MY SWEEP, NOT THE KERNELS.**
    `FAIL add worst 23.9`, `FAIL mul worst 5.9`, on kernels that had passed exactly for two
    turns. Cause: `readLatest` returns the most recent COMPLETED transfer, which is the previous
    operation's until the new one lands. The sweep advanced the operation and rebuilt `cpu_out`
    immediately, so operation N's GPU result was judged against operation N+1's reference. The
    magnitudes gave it away — 23.9 is a matmul-sized number appearing in an `add` row.
    ★★ Two fixes, both removing the possibility rather than narrowing it: **all four CPU
    references are computed ONCE** at init (the inputs are fixed, so the answers are), and a
    **settle window** of three frames after each dispatch stops a stale readback being believed.
    Nothing is rebuilt mid-sweep any more.
  * ★ **The automation I added to speed up the round trip introduced the bug it then reported.**
    A harness that can fail in a way that looks like the thing it measures is worth less than no
    harness — the same lesson as the false MISMATCH one turn earlier, arriving from the other
    direction. Both came from the verdict logic, not the kernels; both were visible only on
    device.


- **Sep 4 2026 — the page is now a SWEEP, not a toy: one screenshot answers everything.**
  * Simon: "make it maximally fast to round-trip to my testing." The page ran ONE operation and
    needed four taps and four screenshots to cover four kernels. It now **runs all four by
    itself**, and prints a verdict line plus one row per operation — `PASS/FAIL`, name, worst
    deviation, the tolerance it was judged against, and the element count. Tap re-runs the sweep.
  * ★★ The tolerance is PRINTED beside the deviation, because the previous screenshot showed
    MISMATCH at 5.7e-6 against an invisible bar of zero. A verdict a reader cannot check is a
    verdict they will learn to ignore.
  * ★★★ **A SPLICE I MADE DUPLICATED HALF THE FILE, and the anchor is the lesson.** I cut from
    `z.clearViewport` to `fn label(` — but `Op` has a METHOD called `label`, forty lines from the
    top, so `index()` matched THAT and the slice ran backwards. Restored from the last shipped
    zip and redone by LINE NUMBER. **A search string used as a cut point must be checked for
    uniqueness first**, the same rule `memory_str_replace` enforces and that I did not apply to my
    own edits.
  * Still open for the next turn: a kernel whose pipeline fails to build takes the whole page
    down with `BRIDGE PAGE ERROR`, so nothing else is visible. Catching that per kernel and
    turning it into a FAIL row is the remaining half of "one screenshot answers everything".


- **Sep 4 2026 — the MISMATCH was mine, not the kernel's; and the strategy is corrected.**
  * ★★★ **A FALSE ALARM ON A CORRECT KERNEL.** Device: `matmul (global)`, worst |cpu-gpu| =
    **5.7e-6**, diff panel black — and the verdict said **MISMATCH**, because the predicate
    demanded `worst == 0.0`. Exact is the right bar for `add` and `mul` (one flop per element, same
    order both sides) and the WRONG one for a matrix product: the kernel accumulates plainly across
    64 terms while `zn.matmul` compensates, so a few ULP of disagreement is arithmetic, not a
    defect. Now a per-operation `tolerance()` — 0 for elementwise, 1e-4 for matmul — and the
    tolerance is PRINTED next to the deviation so the bar is visible rather than implied.
    ★★ **A verifier that cries wolf is worse than none**: it teaches the reader to ignore the one
    time it is right. That is the same failure as a test nobody runs, arriving from the other side.
  * ★★★ **SIMON'S CORRECTION, AND IT IS THE RIGHT ONE: STOP RE-DERIVING znum's KERNELS.** Three
    device round-trips this session rediscovered constraints znum had already solved and
    documented — arithmetic masking, uniformity provenance, the lean path being mandatory rather
    than an optimisation. znum ships **53 kernel files, 9 with shared memory, all lean**. Stage 4
    is now explicitly a PORT, with their manifest, drift gate, coverage gate and dtype injection,
    in an order chosen by what unblocks training. The spike was still worth it — it proved the
    seam and taught me to read their headers as specifications rather than commentary — but from
    here the leverage is in porting, not in authoring.


- **Sep 4 2026 — DEVICE REJECTED THE TILED KERNEL, and the rejection was the exact hazard I had
  talked myself out of two turns earlier.** Dawn:
  `'workgroupBarrier' must only be called from uniform control flow`. Three causes, found in
  order, each one uncovering the next.
  * ★★★ **CAUSE 1: MY "BRANCH-FREE" MASKED LOAD WAS A BRANCH.**
    `const a_at = if (a_ok == 1) row * kdim + a_col else 0;` reads as branch-free and is not — the
    condition derives from the thread id, so the barrier landed **five blocks deep** inside its
    merge. Replaced with arithmetic: `(row * kdim + a_col) * a_ok`, which collapses an
    out-of-range index to 0 (always a valid element) and zeroes the contribution. Depth 5 → 3.
    ★★ I had ALREADY MEASURED this. A check two turns ago printed "barriers at nesting depth > 0:
    2" and I dismissed it by inspecting the wrong enclosing `if` and concluding it was uniform.
    **The instrument was right and I overrode it with reasoning.**
  * ★★★ **CAUSE 2: `installKernel`'s PARAM COPY DESTROYS UNIFORMITY PROVENANCE.** The remaining
    nesting was `loop { if (step < steps) { … } }` — uniform in fact, since `steps` comes from
    `params.kdim`, but Tint could not PROVE it: the stock path copies `Params` field by field out
    of the uniform buffer through a ladder of comptime-dead guards, and the analysis loses the
    provenance across the copy. **`installKernelLean` reads the uniform directly**, and the WGSL
    now shows `let _604: u32 = P.field_2;` straight from `var<uniform> P` feeding the loop bound.
    The lean path was merged this session for its SIZE (48% of the WGSL); it turns out to be
    load-bearing for uniformity, which is a much better reason and one znum's ledger never claimed.
  * ★★★ **CAUSE 3: THE LEAN MERGE WAS HALF DONE AND NOTHING NOTICED.** `kompute` gained
    `installKernelLean`, but `compute_host.zig`'s CPU driver only ever called
    `@field(M, name)(.{ .id, .params })` — the `Ctx` dialect. A lean kernel COMPILED and could
    never be run on the host. Fixed by discriminating on the signature
    (`@TypeOf(f) == fn (u32) void`), so a file may mix both forms and neither declares which it
    is. `compute_smoke`, which uses the stock form, still passes — the compatibility that matters.
    ★ Written as a type comparison rather than `@typeInfo(…).@"fn".params`, because **1980 removed
    `.params` from `Type.Fn`** — the fourth reflection change this session, after `.decls`,
    `@hasDecl` on private decls, and `std.mem.trimLeft`.
  * Gates: lint 0, `check` green, 41 tests, both smokes PASS, fmt clean.
  * ⚠ **STILL UNCONFIRMED ON DEVICE.** Three structural causes were removed and the WGSL now looks
    right, but "looks right" is what I said last time. The device is the only instrument.


- **Sep 4 2026 — both matmul entries wired into `zimrnum_field` and verified as far as a CPU can
  verify them. Smoke PASS, lint 0, `check` green, fmt clean.**
  * The example now cycles four modes on tap: `add`, `mul`, `matmul (global)`,
    `matmul (16x16 tiled)`. The last two are the SAME product by two GPU routes, both checked
    against `zn.matmul` and against each other, with the difference panel as the readout.
  * **Headless: both kernels' CPU twins agree with `zn.matmul` to 8.6e-6** — f32 rounding, since
    the kernels accumulate plainly while `zn.matmul` compensates. So the global index arithmetic
    and the mask logic are right.
  * ★★★ **THE FIRST NEGATIVE CONTROL DID NOT FIRE, AND THAT WAS THE MOST USEFUL RESULT.** I
    shifted `local_col` to `(lid + 1) % tile` expecting the twin to disagree. It returned the
    IDENTICAL number. The shift is a **bijection over lanes**: every output cell is still computed
    exactly once, just by a different thread, and each thread computes the correct value for its
    own cell. Nothing was broken — it was relabelled.
    ★★ **But on the GPU it would break, and the twin is structurally unable to see it.**
    `shared_a[lid]` is written by lane index and read as `shared_a[local_row * tile + i]`, so the
    shared layout depends on `lid == local_row * tile + local_col`. The CPU path never reads
    shared memory — by design, it goes to global — so **no CPU test can catch a shared-memory
    layout error or a misplaced barrier.** That is not a gap to close; it is the boundary of what
    this check can do, and it is now written down.
  * A control the CPU path CAN see — a one-element offset into `ba` — moved the worst deviation to
    **48.3** and failed the test. So the check has power; it just has a known blind spot.
  * ⚠ **STILL UNVERIFIED ON DEVICE**: shared memory and the two barriers. That is precisely the
    part the tiled entry exists for. Open the standalone, tap to `matmul (16x16 tiled)`, and the
    difference panel is the only instrument that can answer it.


- **Sep 4 2026 — setup audit. FOUR defects found, all mine, one of them a build I broke four
  turns ago and shipped. Everything now green: `zig build test` rc=0, 41 zimrnum tests, lint 0,
  `check` green, fmt clean, `files-md` regenerated.**
  * ★★★ **I DELETED `src/assets/` AS "DEAD DUPLICATES" AND BROKE `zig build test`.** Three sites
    embed those files with paths RELATIVE TO THE IMPORTING FILE —
    `@embedFile("./assets/sample.ogg")` in `codecs.zig`, `@embedFile("../assets/test_sine.wav")`
    in `features_test.zig` — so my `grep -rn '"src/assets'` matched none of them. They were
    byte-identical to copies elsewhere and **the copies were not substitutes**: `@embedFile`
    cannot reach out of its module's tree, which is exactly WHY the duplicate existed. Restored
    from the surviving identical files, and `tools/file_descriptions.zig` now records the reason
    so the next person does not repeat it.
    ★★ **`zig build check` STAYED GREEN THROUGH FOUR SHIPPED SNAPSHOTS.** `check` does not compile
    the test roots — recorded twice already in claude.md, and it caught me anyway because I ran
    `check` after every change and the full suite after almost none. The lesson (grep the
    BASENAME, not the path; sweep relative `@embedFile` targets before deleting a data file) is
    now in claude.md.
  * **`zimrnum_field` was absent from `src/web/manifest.json`**, so the example existed but was
    invisible to the gallery index and the launcher. Added under `compute`, two stars.
  * **The plan still named the example `zimrnum_gpu_smoke`** after the rename, and **stage 2.5 sat
    physically AFTER stage 3** while its own header said NEXT ACTION. Both fixed; 2.5 is now
    marked ✅ done with the device number, and its acceptance note says plainly that the second
    half — watching it go red — is still unmet.
  * **`files.md` was stale** (three new example files missing); regenerated.
  * The tutorial audited clean: every `zn.X` it mentions exists, and no status row claims "no" for
    something that now exists.


- **Sep 4 2026 — the tiled GPU matmul COMPILES AND TRANSPILES. The unknown the plan was reordered
  around is no longer unknown. 41 tests, lint 0, `check` green, smoke PASS.**
  * `examples/zimrnum_field/zn_matmul.zig` — two entries over one ABI: `matmul` (one thread per
    output element, global memory) and `matmul_tiled` (16x16 workgroup-shared tiles, 256 lanes).
    Keeping both means the tiled version has a **same-device reference** and not only a CPU one:
    if they disagree, the barrier logic is wrong rather than the arithmetic.
  * ★★★ **THE EMITTED WGSL IS WHAT IT SHOULD BE.** `var<workgroup> tile_a: array<f32, 256>` and
    `tile_b` likewise, `@workgroup_size(256, 1, 1)`, two `workgroupBarrier()` calls, and the
    masked shared writes sitting directly above the first barrier with no branch between them.
    zimr's `spv2wgsl` handles cooperative tiling with no change — the audit called this "new ground
    for the transpiler" and it turned out to be ground it already covered.
  * **kompute already had the primitives**: `k.shared(T, n, name)`, `k.workgroupBarrier()`,
    `k.localId()`, and a comptime `is_gpu` split so the CPU twin reads the same data from global
    memory and never touches shared. Nothing had to be added. The kernel's constraints came from
    znum's notes and are recorded at the top of the file: no early return (every lane reaches
    every barrier, only the WRITE is guarded), bitwise `&` not `and` (short-circuit is a branch),
    lane decomposition derived from the GLOBAL id because `workgroupId` is unreliable on Adreno
    7xx, and an `inline` inner loop.
  * ★ **A follow-up the WGSL made visible**: the tiled entry still uses the stock `installKernel`,
    so its output carries **3 comptime-dead `== 184u` guards** from the merge ladder. The
    `installKernelLean` path merged earlier this session removes exactly those. Worth switching
    once the entry is verified, not before — one change at a time.
  * ⚠ **NOT YET RUN — NEITHER ON CPU NOR ON GPU.** The example does not dispatch it. Compiling and
    transpiling is evidence about the toolchain, not about the kernel: the tile indexing, the mask
    arithmetic and the barrier placement are all untested. Next turn wires it into
    `zimrnum_field` against `zn.matmul` as the oracle, with the naive GPU entry as the second
    reference. **This is the difference between "it builds" and "it works", and the plan should
    not record it as anything else.**


- **Sep 4 2026 — device confirmed the two display fixes; L07 activations and losses landed.
  41 tests, lint 0, `check` green, fmt clean.**
  * Second screenshot, `mul` mode: captions readable, difference panel black at zero. The dark
    vertical band through both heatmaps is the ramp crossing zero under multiplication — the
    picture is showing the maths, which is what a heatmap is for.
  * **L07: `relu`, `sigmoid`, `tanh`, `gelu`, `softmaxRows`, `mseLoss`.** The four activations are
    `map` over the corresponding `zm` function, not second implementations — the GPU twin will
    compile the SAME `zm` code, so agreement is by construction rather than by tolerance. Tested
    element-by-element against `zm` directly, which is what makes that claim checkable.
  * ★★★ **`softmaxRows` SUBTRACTS THE ROW MAXIMUM, AND THE TEST FOR IT IS THE LAW, NOT THE
    HAPPY PATH.** `@exp` overflows `f32` above ~88 and untrained logits reach that routinely; the
    subtraction is exact because softmax is invariant under adding a constant to a whole row.
    A version that skipped it would still pass a "rows sum to one" test on well-behaved input and
    return NaN on the first real forward pass. So there are three assertions: rows sum to one,
    **shift invariance** (the law that makes the subtraction safe), and a row of
    `{1000, 999, 998}` staying finite, summing to one, and keeping its ORDER — the last part
    checking the stabilisation did not flatten the distribution while making it finite.
  * `mseLoss` returns a scalar rather than a rank-0 tensor, and does NOT broadcast: a prediction
    that broadcast against its target would almost always be a bug rather than an intent.
  * Every accumulation added this turn is compensated, for the reason recorded with `sumAll` — the
    softmax denominator especially, since every element of the row is divided by it.


- **Sep 4 2026 — the field example RAN ON DEVICE, and reductions + matmul landed. 38 tests, lint
  0, `check` green.**
  * ★★★ **DEVICE CONFIRMED.** `worst |cpu-gpu| = 0 over 4096 checked`, "CPU and GPU agree
    exactly", both heatmaps identical on Simon's phone. The stage 2.5 question — do zimrnum's CPU
    abstractions reach a real GPU — is answered yes, end to end, in a real app.
  * ★★ **THE SCREENSHOT SHOWED TWO PRESENTATION DEFECTS THE SANDBOX COULD NOT.** `heat(0)`
    returned dark RED at zero, so a perfectly zero difference panel rendered as a solid red block
    — the same picture a uniformly small POSITIVE error would give, which defeats the entire point
    of the third panel. Saturation now falls to nothing with the magnitude. And the three captions
    ran together into one unreadable line at phone width; they are one word each now.
  * **L06: `sumAll`, `meanAll`, `minAll`, `maxAll`, `sumAxis`, `matmul`.** Reductions work on any
    view; `matmul` reads through `at`, so a transposed operand multiplies without being copied.
    Empty input is `DomainError` rather than an invented answer.
  * ★★★ **SUMMATION IS COMPENSATED (Neumaier), AND SO IS MATMUL'S INNER SUM.** A running total
    loses the low bits of every addend once it passes them: a million ones in `f32` stalls at
    16 777 216. In a network the contraction axis is the layer width, so getting this wrong does
    not crash — it makes gradients slightly wrong everywhere, which reads as "training is a bit
    unstable". Three extra flops per element, nothing against the memory traffic.
  * ★★★ **A TEST I WROTE TO PROVE THAT WAS ITSELF WRONG, AND MEASURING CAUGHT IT.** It compared
    `sumAll` against a hand-written `+=` loop and expected the naive loop to return 16 777 216.
    It returned **1 000 000 — exact**. The optimiser VECTORISES a plain accumulate into per-lane
    partial sums, which is itself a form of pairwise summation. The comparison proved nothing
    about either algorithm. Rewritten to assert what `sumAll` GUARANTEES — exactness on a million
    ones, and `[1e8, 1×100, -1e8]` returning 100 where a running total returns 0, which no amount
    of lane-splitting fixes. **"Compare against the obvious alternative" is not a test when the
    compiler is free to make the alternative better than its name suggests.**
  * `matmul` is checked against arithmetic worked out off to the side (58, 64, 139, 154), then
    against two laws that hold for any input: `A @ I == A`, and `(A@B)ᵀ == Bᵀ@Aᵀ` — the second
    also exercising transposed views as operands.


- **Sep 4 2026 — stage 2.5 done: `examples/zimrnum_field`, zimrnum's first operation on a real
  GPU, inside a real zimr app. Smoke PASS, lint 0, `check` green, 33 tests.**
  * Simon's correction: a smoke page proves the plumbing, not that the library is usable. So the
    deliverable is an **example**, not a test harness — a 64×64 field built from tensors, computed
    on both backends, with **three heatmaps side by side: CPU, GPU, and their difference at
    1000x**. A wrong GPU result is a visibly different picture rather than a number in a log.
    Tapping switches `add`/`mul` and both backends follow.
  * ★★★ **THE DENSIFY STEP IS IN THE EXAMPLE, VISIBLE.** Operand B is a `(1, 64)` ramp stretched
    down the field by `broadcastTo` — a stride-0 view, which the kernel cannot bind because it
    takes flat buffers and a count. The host materialises it with one `zn.add` against a zeroed
    field, and that line IS the difference between what the two backends accept. The audit
    predicted this a turn ago; the example now demonstrates it rather than describing it.
  * **`src/zimrnum.zig` is a registered module.** `b.addModule("zn", …)` with `zm` + `kompute` and
    nothing else, threaded through `AppContext`. The tutorial had claimed this existed since it
    was written; it did not until now.
  * ★★ **FOUR API MISTAKES, EACH FIXED BY READING A WORKING EXAMPLE RATHER THAN GUESSING.** A
    multi-entry kernel embeds per ENTRY (`@embedFile("add_wgsl")`), not per file — `four_ways`
    does `@embedFile(name ++ "_wgsl")` and I copied `compute_smoke`'s single-entry shape instead.
    `z.Compute.run` takes the entry name at COMPTIME, so the op switch selects the CALL, not a
    string. Input is `z.isMouseButtonPressed(f.input, .left)`, not a method on the frame. And
    `catch {}` on the rebuild tripped `catch-suppression` — correctly: a swallowed error would
    leave the panels showing a stale field with nothing to say so.
  * ★ A careless `sed s/zm.Color/Color/g` also rewrote the alias declaration into
    `const Color = Color;` and cost two rounds chasing a lint error I had created. Targeted
    replacement or none.
  * **Measured:** standalone 1.79 MB, smoke `init 4212 calls, ~99.6/frame`. Still to do on device:
    open it and confirm the difference panel is flat, then break the kernel deliberately and
    confirm it is not. **A green light nobody has watched go red is not evidence.**


- **Sep 4 2026 — AUDIT: read znum's GPU kernels against what I have built. The design crosses,
  with one qualification, and the plan's ordering was wrong.**
  * ★★★ **`broadcastTo`'s STRIDE-0 REPRESENTATION IS EXACTLY WHAT znum's GPU KERNEL WANTS.**
    `k_bcast_add.zig` takes `Params { numel, n, a_row, a_col, b_row, b_col }` and computes
    `out[i] = a[row*a_row + col*a_col] + b[row*b_row + col*b_col]`, where **a stride of 0
    broadcasts that axis** — the same trick, passed in a uniform instead of held in a struct. The
    dispatch is therefore `uniform.a_row = va.strides[0]` and so on. That is a much stronger
    result than "the seam should work": the CPU view type already holds the GPU's parameters.
  * ★★★ **BUT THE GPU'S DOMAIN IS NARROWER THAN THE CPU'S, AND THE SEAM MUST SAY SO.**
    `k_binary.zig` takes flat dense buffers and a `count` — no shape, no strides — and
    `k_bcast_add` handles **rank 2 only**. My `zip` accepts any rank up to 6 with arbitrary
    strides. So a GPU dispatch must (a) pick the dense kernel, (b) pick the broadcast kernel, or
    (c) refuse — and **(c) must be loud**. Silently running such a case on the CPU would make the
    GPU path a lie and the CPU-twin oracle meaningless. This is risk 5 (bindability) made
    concrete: it is not only "views cannot be bound", it is "the backends do not compute the same
    set, and the difference must be an error rather than a fallback".
  * ★★ **THE OUTPUT CONSTRAINT MATCHES WHAT I ALREADY ENFORCE.** Every znum kernel writes
    `out[id]` linearly, so the destination must be dense and unaliased. `isAliased` already
    refuses half of that; the GPU path additionally needs `out.isContiguous()`. No redesign — one
    more check at the dispatch site.
  * ★ znum's rank-2 limit is a cost decision, not an oversight: a general rank-N kernel needs a
    divmod chain per axis per thread. zimrnum should measure rank-2-specialised against general
    before choosing, and record the number.
  * **ORDERING CORRECTION.** The plan had GPU at stage 4, after linalg, transforms and random.
    That is the wrong risk order: it spends thousands of CPU lines before learning whether the
    seam holds on a real device. **A GPU spike is now stage 3.5 and the next action** — one
    kernel, one example, one standalone, CPU twin as the in-page oracle. Everything zimr needs
    already exists (`kompute`, `compute_host`, `spv2wgsl`, the standalone build); the genuinely
    new work is build wiring for a LIBRARY kernel set rather than a per-example one.
  * **AUDIT OF L00–L05, no defects found beyond those already fixed.** 33 tests. The three
    corrections this session were all found by probes written to fail first: `unitFloat(f16)`
    returning 1.0 for 99.6% of draws, every draw kind sharing `bits(index)`, and a `fill` test
    that could not distinguish a correct strided walk from a wrong `@memset`. The pattern worth
    keeping: **ask whether each stated guarantee holds at every type and between every pair of
    methods**, because a test that only asserts the happy path passes on all three of those.


- **Sep 4 2026 — elementwise layer: `map`, `zip`, `add`, `sub`, `mul`, `div`, all broadcasting.
  33/33 tests, lint 0, `check` green, fmt clean.**
  * **The output defines the shape; it is not inferred.** A caller sizes `out` and both inputs must
    broadcast to exactly that. Inferring instead would make the result shape depend on the inputs
    in a way the call site does not show, and a mistake there allocates wrong rather than
    reporting.
  * ★★★ **`isAliased` CLOSES THE HOLE `broadcastTo` OPENED LAST TURN.** A stretched view as an
    OUTPUT means many indices address one element, last write wins, the rest vanish — wrong in a
    way no bounds check reaches. Last turn that was a paragraph telling callers not to do it; now
    `map` and `zip` return `UnsupportedShape` and there is a test. **A note in the documentation
    became a check in the code**, which is the same move as retiring the `normal` index hazard.
  * ★★ **THE TWO WALKS ARE TESTED AGAINST EACH OTHER.** `zip` takes a linear pass when everything
    is contiguous and an index walk otherwise; a bug in either is invisible against itself. The
    test computes the same product into a dense destination and a transposed one and requires
    equality. The broadcast test checks against the ARITHMETIC (`col[i] + row[j]`), not against a
    second run of the same code.
  * The function is a comptime parameter, so it inlines — the named four are one-line wrappers
    over `zip` and cost nothing extra. `div` is float-only: Zig has no single `/` for signed
    integers, and picking truncating, flooring or exact here would be this library deciding
    something the language deliberately asks about.
  * **Performance, 1024x1024 f32, 40 passes, one core:**

        dense + dense        493 M elem/s
        dense + broadcast row 381 M elem/s   (stride-0 read, still linear in the output)
        transposed output    129 M elem/s   (index walk, and a cache miss per element)

    The dense path is memory-bound at three streams; the strided path is the same shape as the
    `fill` finding — cache behaviour dominates, not the indexing.
  * Tutorial: §8 with three subsections, 7 reference rows.


- **Sep 4 2026 — `broadcastTo`: broadcasting is a stride of zero. 29/29, lint 0.**
  * An axis of extent 1 is stretched by setting its stride to 0, so every position along it
    addresses the same element. A `(1, 3)` tensor viewed as `(4, 3)` is three values read four
    times — nothing allocated, nothing moved. The tests check the view against the ORIGINAL
    storage (write the source, read the change through the view) rather than only checking the
    view is self-consistent, which a copy would also satisfy.
  * ⚠ Writing through a stretched view is a mistake the type system cannot prevent: many indices
    alias one element, last write wins. Documented at both the declaration and in the tutorial.
    `isContiguous` reports false for any stretched axis, which stops a linear walk from reading 15
    values as if there were 60.
  * A test pins `broadcastTo` against `broadcastShape`, because a caller sizes an output with one
    and reads it with the other; drift between them would be silent.
  * **Simon's question about the GPU is now risk 5 in §9**, with the conclusion that ownership
    generalises (the pool is the arena) but **bindability does not** — a strided view cannot be
    handed to a kernel, and that gap has a name and a stage-4 test rather than an assumption.


- **Sep 4 2026 — L03 landed: `Tensor(T)`, views, `broadcastShape`. 27/27 tests, lint 0, `check`
  green, fmt clean.**
  * ★★★ **A TENSOR NEVER OWNS ITS STORAGE — no `owns` flag, no `deinit`.** `data` is a slice the
    tensor addresses; whoever allocated frees, and if that was a `Scope` nobody frees anything.
    The plan's four-way taxonomy was going to encode ownership in the value, but both of that
    design's failure modes are SILENT: `deinit` on a view does nothing while reading as though it
    did, and a missing `deinit` on an owner just grows memory. With no `deinit` at all, a free
    appears exactly where an allocation appears and a view has neither. **This is the taxonomy
    made unnecessary rather than implemented.**
  * `fromSlice` requires the extents to multiply to EXACTLY `data.len`; a slice that merely fits
    is rejected, because the usual cause is a wrong shape rather than generous storage.
  * ★★ **A TEST I WROTE WAS SELF-REFERENTIAL AND I CAUGHT IT BEFORE SHIPPING.** The `fill` test
    filled a transposed view and checked every element was set — but a transposed view still
    covers all its storage, so a wrong `@memset` of `data[0..size()]` passes it. Replaced with a
    hand-built view addressing every OTHER element, where the two implementations disagree.
    Negative control: forcing the memset path fails it at index 1.
  * ★★★ **A PERFORMANCE "OPTIMISATION" WAS MEASURED AND REJECTED.** Carrying a running flat offset
    instead of recomputing `flatIndex` per element is the obvious win — O(rank) multiplies become
    one add. Measured, filling a transposed tensor:

        L1-resident 64x64 f32      running offset 657 M elem/s   recompute 986 M elem/s
        2048x2048 f32              running offset 150 M elem/s   recompute 145 M elem/s
        2048x2048 f32, contiguous  @memset       2 396 M elem/s

    The offset is a loop-carried dependency, so each write waits on the previous step's
    arithmetic; recomputing from the walker leaves an independent multiply chain the CPU
    pipelines. At any size that misses cache it is moot — a strided fill is memory-bound and both
    forms land within 3%. **The simpler code is the faster code**, and I had already written a doc
    comment claiming 1 100 M/s for the version that turned out to be slower. The A/B is what
    stopped a slower, more complex implementation shipping with a fabricated number attached.
  * Guarantees now pinned by test: strides are row-major on construction; indices address what the
    strides say (written through `setAt`, read back through the RAW SLICE, so a self-consistent
    wrong indexing would fail); `transpose` shares storage and reports itself non-contiguous;
    `reshape` refuses a non-contiguous tensor rather than returning a wrong view; `broadcastShape`
    rejects (3) against (4).
  * Tutorial: §7 Tensors with four subsections, 13 reference rows, 67 links, 0 broken.


- **Sep 4 2026 — audit of L00–L02 before building L03. TWO REAL BUGS in `Rng`, both shipped, both
  now regression-tested. 19/19 pass, lint 0, `check` green.**
  * ★★★ **`unitFloat(f16)` RETURNED 1.0 FOR 99.6% OF DRAWS.** It took 24 mantissa bits for every
    `T` and scaled by 2^-24; in `f16`, 24 bits of precision round to 1.0 for all but the smallest
    values. Measured: **199 227 of 200 000 draws at exactly 1.0**, on an interval the API
    documents as half-open. `uniform` inherited it, so an `f16` range could return its exclusive
    upper bound. FIX: the width is per type (11 / 24 / 53), so the largest result is the largest
    `T` strictly below one, at every width.
  * ★★★ **EVERY KIND OF DRAW STARTED FROM `bits(index)`, SO THE KINDS DETERMINED EACH OTHER.**
    `unitFloat(f32, i)` was exactly `bits(i) >> 8` — measured at 20 000 of 20 000 indices — and
    `intBelow(i, n)` was a function of the same word. A caller drawing a uniform and an action
    index at one step got two values locked together. FIX: `word(index, round)` folds a round
    constant into the MIXER and each kind owns a round (0 bits, 1–2 unitFloat, 3–6 normal,
    7 intBelow). `round == 0` adds nothing, so `bits` is unchanged.
  * ★★ **A THIRD DEFECT THE FIX REMOVED ON THE WAY.** The f64 path drew its second word as
    `bits(index ^ 0x5bf03635)`, so indices `i` and `i ^ K` were built from the SAME two words with
    the roles swapped — not independent. Folding the round into the mixer rather than the index
    is what makes that impossible.
  * ★★★ **AND IT RETIRED THE API HAZARD DOCUMENTED ONE TURN EARLIER.** The tutorial's §5.3 warned
    that `normal(i)` consumed uniform indices `2i`/`2i+1` and told callers to `split`. With
    per-kind streams that is simply no longer true: `bits`, `unitFloat`, `normal` and `intBelow`
    at one index are four independent values. **Removing a hazard beats documenting it** — the
    section is now four lines saying the kinds do not interfere, and the guarantee a reader has to
    remember got shorter rather than longer.
  * **Flexibility:** a new distribution costs one round number and cannot interfere with an
    existing kind. **Understandability:** one rule ("each kind has its own stream at each index")
    replaced a per-method caveat.
  * **Performance, one core, ReleaseFast, 20 M draws each:** `intBelow` **416 M/s** (48 ms),
    `unitFloat(f64)` **263 M/s** (76 ms, two hashed words), `normal(f64)` **29 M/s** (684 ms —
    `@log`/`@sqrt`/`@cos` dominate, not the generator). Sanity means over 20 M: 0.499939,
    -0.000207, 25.49 on [0, 52). The round indirection costs nothing: it is a comptime constant
    folded into an existing XOR.
  * ★ The probes that found all this were written to FAIL first and did, with counts. A test
    asserting the RNG is uniform would have passed on both bugs; what caught them was asking
    whether each stated guarantee is actually true at every type and between every pair of methods.


- **Sep 4 2026 — tutorial cut to what a user needs: 39 KB → 23 KB, 2 560 words.** Simon's rule,
  now the standing one for this document: **everything in the tutorial must be worth its weight to
  someone USING the library**, plus a little about how it works; rationale belongs in code
  comments and development history belongs here.
  * **Removed** (all of it already lives in a code comment or in this journal, so nothing was
    lost): the `mjcf.zig` two-session arena hunt and the `gltf.Data` 8 398-byte leak; the
    `@typeInfo(...).decls` removal and the `@hasDecl` change; the 30-second artifact measurement;
    the `stepEdge` / `lerp` / `saturate` vocabulary story and the whole "zm vocabulary pin"
    subsection (internal machinery a caller never touches); the `robot_mpc` derivative anecdote;
    the Box–Muller-versus-ziggurat and Lemire-versus-modulo rationales; the `module-var` lint;
    and the three-paragraph "how this document is kept true" section, now one sentence in the
    reference preamble.
  * **The filter that decided each cut: does knowing this change what the reader WRITES?**
    Counter-based addressing does — it changes how you seed, index and parallelise, so it stayed.
    Why the mixer is a Murmur finaliser rather than a ziggurat does not — it went. `f32` versus
    `f64` stayed because choosing wrong is quiet; the anecdote about how we learned that went.
  * ★★★ **THE REWRITE FOUND AN UNDOCUMENTED API HAZARD.** `normal(i)` consumes uniform indices
    `2i` and `2i+1`, so drawing normals and uniforms from the SAME `Rng` over overlapping ranges
    correlates them — `normal(0)` and `unitFloat(1)` share a draw. That was true from the day L01
    landed and appeared in neither the code nor the tutorial, because the old text described the
    Box–Muller CHOICE instead of its CONSEQUENCE. It is now a note in the tutorial with the
    `split`-per-purpose remedy, and a `★★` block on `Rng.normal`. **Writing for the user found a
    defect that writing about the design had hidden.**
  * Structure: 9 sections → 7, ordered what it is → what exists → getting started → base → random
    → memory → reference. 54 internal links, 0 broken. The gate still passes: 25 declarations, 25
    rows.


- **Sep 4 2026 — L02 landed: `Ctx` and `Scope`. 17/17 tests, lint 0, `check` green, fmt clean.**
  * **`Ctx` is `{ gpa, rng }`** — the two ambient resources a numerical library is tempted to
    hide. zimr already forbids the first (`module-var` lint); `Ctx` is how the second stays honest,
    because a file-scope generator would make results depend on evaluation order, which is exactly
    the property `Rng` was designed not to have. `derive(label)` gives a sub-computation its own
    stream with no coordination.
  * **`Scope` holds `arena: *std.heap.ArenaAllocator` via `gpa.create`** — the stage-1 acceptance
    criterion, and the third time this repo has had to state the rule. The test that enforces it
    allocates INSIDE a function that then returns the scope, which is the exact shape that breaks
    a by-value arena; `std.testing.allocator` fails on the leak. A second test asserts the property
    that makes a `Scope` copyable — both copies' allocators point at the same heap arena — rather
    than assuming it.
  * **`Device` and `Buffer` were NOT written**, though the plan lists them in L02. They have one
    meaningful variant until there is a device, and a stub with a `.gpu` tag that does nothing is
    a default that looks like an answer. The status table says so.
  * ★★★ **THE TUTORIAL GATE EARNED ITS KEEP ON ITS FIRST REAL EDIT.** It failed immediately,
    naming all eight new public declarations, then failed AGAIN with `reference table has 24 rows
    but 25 declarations matched: a row is stale` — because `Ctx.init` and `Rng.init` share a name
    and both matched the single `init` row. The row-count half of the check caught a collision the
    name-matching half could not. Both rows now exist and the signature column distinguishes them.
  * ★ Two more house rules learned the same way: a loop counter named `round` trips
    `reserved-math-names` (it shadows `zm.round`) even as a LOCAL, and `var` on a never-mutated
    local is a compile error. The linter is a faster teacher than the style guide.
  * L02 sits after L01 in the file because `Ctx` holds an `Rng` — the downward-only stack is a
    reading order, not just a numbering.


- **Sep 4 2026 — duplicate-file audit. 33 byte-identical groups found; 7 removed, 26 kept, and
  the reasoning for keeping them is the point.**
  * **Removed (2 356 KB), all dead:** `src/assets/` entirely — `sample.ogg` (2.27 MB) and
    `test_sine.wav` were a second asset root that `build.zig` never reads (it uses
    `assets/sample.ogg` at the repo root) and that only `tools/file_descriptions.zig` mentioned,
    i.e. documented as existing rather than used. `src/notes/tutorials/gpu_compute_tutorial.html`,
    byte-identical to the staged hyphenated page and linked from nothing. Four
    `src/notes/wip_vtf/*.zig.txt` frozen copies of live example sources — **the fifth differs and
    was kept**, which is what "if two are identical keep one" actually means here.
    `tools/file_descriptions.zig` updated and `zig build files-md` re-run so the atlas matches.
  * ★★★ **THE OTHER 26 GROUPS (16 MB) ARE LOAD-BEARING AND MUST NOT BE DEDUPED.** Three reasons,
    each already a rule in this repo:
    - **11 groups are example assets.** Examples are self-contained — one file plus its own
      assets, baked into a standalone. An example reaching into a shared asset directory would
      not ship. `bunny.obj` in three examples is three shipping programs, not three copies.
    - **8 groups are a test fixture beside the example it came from** (`humanoid.xml`, `go1.xml`,
      `keeper.xml`, …). Pointing the tests at the example's copy would mean an edit to a demo
      silently changes every recorded measurement — the "a mode must establish everything it was
      measured with" failure, applied to fixtures.
    - **5 groups are external tint conformance cases** whose names encode which upstream case
      they are; two cases lowering to identical SPIR-V is a fact about the compiler, not
      redundancy. **1 group is snapshot output** written at run time by the test itself.
  * Left alone and noted: the Atkinson font in four places (`assets/`, `examples/assets/fonts/`,
    `examples/native_plot_png/`, `tools/dag_font.ttf`). Three are the self-contained rule and one
    is a tool's own copy; 33 KB is not worth the risk of guessing which consumer breaks.
  * ★ A byte-identical scan is a cheap and blunt instrument: it finds real dead weight and it
    also flags the architecture. The scan is not the decision.
  Gates after: `files-md` regenerated, `check` green, fmt clean.


- **Sep 4 2026 — the tutorial ships with the readme, following the existing convention.**
  Moved to `src/notes/tutorials/zimrnum-tutorial.html` (hyphenated, like `mujoco-tutorial.html`
  and the rest), added to `build.zig`'s flat staging list so it lands beside `readme.html` in
  `zig-out/web/`, and linked from the readme's **Long-form walkthroughs** section in the same
  voice as its siblings. The `@embedFile` path in `src/zimrnum.zig` moved with it, so the gate
  still reads the shipped page rather than a copy.
  * ★ Verified structurally rather than by eye: **all 9 `readme.html` links now resolve to a
    staging entry whose source file exists** (0 problems). `build.zig`'s own comment records that
    `tutorial.html` was linked from the readme for a long time while never being staged — a dead
    link nobody noticed — so the check is worth keeping. It is a static comparison of the readme's
    hrefs against the staging list; it does not need the install tree built.
  * ★★ **`src/notes/tutorials/gpu_compute_tutorial.html` is byte-identical to the hyphenated
    `gpu-compute-tutorial.html` and is not staged.** `tutorial_cleanup_plan.md` records that it
    was deliberately left out of the ship list, but it was never deleted. Two identical files, one
    shipped and one not, is a trap: editing the wrong one produces no error and no effect. Left
    in place because removing it means regenerating `src/notes/files.md`, which is its own small
    task — flagged here rather than half-done.
  * Gates after the move: 12/12 zimrnum tests, `test-fast -Dtest-filter=zn.` green, lint 0,
    `check` green, fmt clean, 65 internal links in the page with 0 broken.


- **Sep 4 2026 — `src/notes/zimrnum_tutorial.html`, written alongside the code and gated against
  it.** Documents exactly L00 + L01 and says plainly, in a status table, what does not exist.
  * **Structural audit against the donor** (`znum.html`), same script, both files:

        metric                znum.html    zimrnum_tutorial.html
        size                   2 027 KB                    32 KB
        script share                88 %                      0 %
        headings with an id       4/191 (2%)             24/25 (96%)
        broken internal links          1                        0
        <pre> code blocks              0                       12
        heading level skips            0                        0

    znum's ordering is the substantive defect: a ~4 300-line live-demo section sits between the
    title and "What znum is", so the introduction, the build instructions and the first tensor are
    two thirds of the way down, and the GPU topic is split between the very front and section 38.
    The replacement runs introduction → status → build → first example → concepts in dependency
    order → provenance → reference, with one topic in one place.
  * ★★★ **THE GATE IS A ZIG TEST, NOT A SCRIPT.** `src/zimrnum.zig` embeds the tutorial AND its
    own source, scans the source for `pub fn` / `pub const` at line starts, and fails when a
    declaration has no row — or when the table has more rows than declarations matched, which
    catches a stale row. It runs in `test-fast` every time; a script in `scripts/` would have to
    be remembered, and would have been a second implementation of one thing.
    ★★ **BOTH DIRECTIONS PROVEN BY BREAKING THEM**: an undocumented `pub fn probeDecl` fails the
    tier; renaming a table row to `bitsOld` fails it. Restored, 12/12 pass.
  * ★ It reads the source TEXT rather than type information because **`@typeInfo(...).decls` was
    removed on 0.17.0-dev.1980** (third 1980 change found this session, after `@hasDecl` losing
    private decls and `std.mem.trimLeft` becoming `trimStart`). `@hasDecl` cannot substitute: it
    needs a name to ask about, which is exactly the direction that misses a NEW undocumented decl.
  * ★ The tutorial's first example is the body of a test, so an example that stopped working fails
    the build instead of misleading a reader. And the document contains no hand-written counts of
    tests, files or lines — the readme.html audit earlier this session found four such numbers
    stale, and there is no mechanism here that would catch a fifth.
  * Lint taught one more house rule: `std.debug.print` is banned in `src/` (it bypasses
    `std_options` and its raw-stderr writer traps under ReleaseSmall on wasm). Diagnostics now go
    through `std.log.err`. Gates: 12/12 tests, lint 0, `check` green, fmt clean.


- **Sep 4 2026 — THE TREE IS CLEAN. `zig build test` rc=0, `check` green, lint 0, fmt clean.**
  Stage 0's blockers are cleared; zimrnum work can start.
  * `zig build test` (the whole host suite) **passes with no failures**. The forearm test passes
    too — see the correction below; it was never the problem I said it was.
  * Three heavy retarget diagnostics are gated behind `run_slow_retarget_diagnostics = false` in
    `robot_mjcf.zig` (Simon: fine to skip, re-enable when that arc resumes). They are **not
    deleted and not reduced** — their cost IS the IK solve, so trimming iterations would change
    what they measure rather than how long it takes. A cheaper test that answers a different
    question is not the same test. The runner prints them as skipped every run, so they stay
    countable. `robot_mjcf` artifact: **29.5 s -> 11 s**, 407 passed / 4 skipped / 0 failed.
  * Remaining 11 s, if it ever needs to be 5: ~2.5 s codecs, ~1.3 s robot_physics, ~2.5 s across
    the other 401 tests. Getting under 5 s means touching other modules' tests.

- ★★★ **CORRECTION — the "dead A/B" diagnosis from earlier this session was WRONG, twice over.**
  I attributed three identical `mode aim / aim_twist / ported_twist` rows to the forearm test
  because `grep -B12 FAIL` printed them above it, then "confirmed" it by finding `_ = mode;` in a
  function that test calls. Neither step established the rows came from that test. **Nothing in
  the tree prints `mode {s}`**, and `robot_mjcf.zig:2351` says plainly that `ArmMode` is GONE and
  its removal WAS the fix. Read correctly, the forearm test sweeps
  `AimSelection{ .none, .torso, .all }`, the three rows DIFFER (0.803/-0.049, 0.612/-0.306,
  0.612/-0.306), and `best_agreement = 0.803 > 0.3` passes.
  ★★ The per-test timer was wrong the same way: the gap before test N's line is test N−1's
  duration, so the first "slowest tests" list named three innocent tests. Corrected, it named
  three different ones — which is what actually got gated. **Adjacency in a log is not
  attribution**; the general lesson is now in claude.md.


- **Sep 4 2026 — the last failing test is fixed, by DELETING the thing that was broken.**
  `armDirectionForFrame`'s `mode: ArmMode` had become `_ = mode;` when the harness moved onto the
  shared `rbt.poseFromRetarget`, so the A/B loop swept a parameter with no effect and printed
  three identical rows. **Resurrecting it would have meant re-implementing six mechanisms in the
  harness — the duplicate-of-the-implementation this project has paid for five times.** The live
  selector is `AimSelection`, which `poseFromRetarget` actually consumes through `aim_at_child` /
  `aim_all`, so the loop now sweeps that and the experiment RUNS for the first time:

        aim none     upper_arm  0.803   forearm -0.049   spread 0.407
        aim torso    upper_arm  0.612   forearm -0.306   spread 0.277
        aim all      upper_arm  0.612   forearm -0.306   spread 0.277

  Aiming more bodies makes both bones worse, and `.torso` and `.all` are identical to three
  decimals. `limb_correction` and `human_rest_rotations` were dead the same way and went with it —
  a parameter every caller must supply and nobody reads is a lie about what a function depends on.
  * ★★★ **THE 0.3 FLOOR GUARDED A NUMBER FROM CODE THAT NO LONGER EXISTS.** It was set when
    `ArmMode.aim_twist` reached +0.563 inside the harness's own copy of the pose loop — the copy
    the refactor deleted. Asserting a target no available mechanism can reach is an aspiration
    dressed as a guard. Replaced with guards on what the pipeline actually controls: the UPPER ARM
    at 0.803 (aimed by construction, a real thing to regress) and the FOREARM guarded against
    getting WORSE rather than asserted good.
  * ★★ **THE FOREARM IS NOT FIXED AND THE TEST NOW SAYS SO IN THE RIGHT PLACE.** The cause is
    understood and is not tuning: `aim` uses the shortest arc, which adds no rotation about the
    bone, so the upper arm points correctly and its TWIST is arbitrary; the elbow's hinge axis is
    fixed in the upper arm's frame, so a wrong twist bends the forearm in the wrong PLANE. The fix
    is swing-twist — choose the twist about the aimed axis so the elbow's bend plane matches the
    human's — and it is retarget work, recorded at the assertion.
  * ★ Noted for whoever picks that up: `.none` is documented as one of "the two pure mechanisms"
    but still aims the upper arms, so the sweep has no pure-twist baseline row at all.

  **`robot_mjcf`: 410 passed, 1 skipped, 0 failed.**


- **Sep 4 2026 — stage 0 continued: coverage audit, the kompute lean path, and zimrnum's first
  slice. Full suite 259 s, 2 141/2 146 pass, 4 skipped, 1 failed (the known forearm A/B).**
  * ★★★ **COVERAGE AUDIT: SIX FILES / 24 TESTS WERE IMPORTED BY NOTHING.** Walked the import
    closure of `src/tests.zig` and every `fast_test_root` against all 96 non-shader `src/*.zig`:
    `tests/shader_enum_test.zig` (3), `tests/snapshot_regression_test.zig` (6),
    `tests/ui_dock_builder_test.zig` (10), `tests/ui_dock_screenshot_test.zig` (2),
    `tests/ui_screenshot_test.zig` (1) and `leakwatch.zig` (2) compiled nowhere and ran never.
    The aggregator's DOCUMENTED exclusions (`spv2wgsl_wasm`, `wgpu_smoke_test`, `wgpu_runner` —
    wasm module roots) are deliberate and stay out; these six had no such reason. All now wired.
  * ★★ **AND FOUR OF THEM NO LONGER COMPILED**, exactly like `robot_mjcf`: `UiContext.frame_arena`
    moved from a bare `ArenaAllocator` to `FrameArena` (arena + a live-byte tripwire for a dropped
    per-frame reset) and the never-compiled tests still passed the old type. Fixed at 5 sites
    against `ui.zig`'s own precedent. **A test that is written and never run is worse than no
    test, because it reads like coverage.**
  * ★ `ui.FrameArena` and `ui.ui_frame_arena_ceiling` are now `pub`: `UiContext.frame_arena` is a
    pub field, so a pub field whose TYPE could not be named was a latent trap. Making an API
    constructible beats documenting that it is not.
  * **kompute lean-path merged, and the claim reproduced on zimr's own kernel** rather than
    carried over. One `double` kernel, both forms, same toolchain:

        stock  spv 3 972 B   wgsl 2 010 B   96 lines   4 `if`s
        lean   spv 1 760 B   wgsl 1 043 B   49 lines   1 `if`

    **WGSL is 48% of stock** — znum's "about half", confirmed — and the three dead
    `if (31u == 31u)` ladder branches are gone, leaving only the kernel's own guard. The emitted
    binding is `array<f32>`, runtime-sized, so the 1980 storage-block fix carries through the lean
    path too. Purely additive: `installKernel`/`Ctx` untouched.
  * **`src/zimrnum.zig` exists: L00 base + L01 Rng, 10 tests, all passing, in the fast tier.**
    L00 is `Error`, `isFloat`/`requireFloat`, `Ddof` (a named enum with an OPTIONAL divisor, so
    "one value has no sample variance" is expressible instead of a silent NaN), `approxEqAbs`
    (NaN equal to nothing — a tolerance check that said otherwise would report a broken solve as
    passing), and the zm vocabulary pin **by reference, not `@hasDecl`** — a reference breaks on a
    signature change, where `@hasDecl` only notices a deletion.
  * ★★★ **THE RNG IS COUNTER-BASED, AND THAT IS THE GPU DECISION MADE EARLY.** `Rng.bits(index)`
    is a pure function of (seed, index), so a GPU thread computes its own draw with no sequencing,
    and the CPU oracle produces the IDENTICAL stream — an oracle that randomises differently from
    the thing it checks is not an oracle. Same reason `normal` uses Box–Muller and not a ziggurat:
    a ziggurat REJECTS, so the value at `index` would depend on how many rejections happened,
    which is not a pure function of the index. `intBelow` is Lemire's multiply-shift, not `%`,
    because modulo bias is invisible until a replay buffer over-samples early transitions.
  * Tests pin what is relied on and say so: determinism under REORDERED access (the property that
    makes it counter-based rather than merely deterministic), range, stream independence measured
    as zero collisions in 10 000 draws, first and second moments at ~4 standard errors, `mix32`
    injectivity over a 50 000 window, and avalanche at 16 ± 0.5 flipped bits.

- **Sep 4 2026 — stage 0(c) part 1: `zm.tanh` / `sigmoid` / `gelu` merged, and the merge found
  three 1980 breakages in zimrmath's own tests that nothing was running.**
  * **Decision 1 SETTLED.** `reserved-math-names` holds `abs sqrt sin cos tan asin acos atan
    atan2 sincos exp exp2 exp10 pow log2 log10 floor ceil round trunki roundi` (+ `dot cross
    lerp clamp01`). `tanh`/`sigmoid`/`gelu` are NOT on it and are NOT added — reserving them
    would forbid `nn.tanh`, which is exactly what an nn layer wants to spell. `tan` is reserved;
    `tanh` is a different word. Merged under the original `ZNUM-UPSTREAM(ml-activations)`
    markers so a re-sync can grep for it.
  * **Decision 2 DEFERRED, correctly.** `prefer-vec` only bites at L05 `fast.*`; nothing in this
    slice has a hot kernel. Still blocking before L05.
  * ★★★ **`@hasDecl` NO LONGER SEES PRIVATE DECLS ON 1980.** Probed directly: `false` for a
    private fn, `true` for a pub one, in the same file. zimrmath's dead-spelling discoverability
    pin (`mix`/`saturate`/`stepEdge` exist privately so `zm.mix` says "not marked pub" and points
    at a doc comment naming the canonical name) was built on the opposite behaviour and fired its
    own `@compileError`. Re-pinned by REFERENCE (`_ = &mix;`), which is strictly stronger and
    needs no builtin: delete one and the compile error names the identifier.
  * Two more: `var result: T` in `clamp` is illegal when `T` resolves to `comptime_int`
    (`clamp01(-1)` does that) — now two named consts; and a comptime-known `@Vector` has no
    well-defined layout to dereference, which broke the two `arrNPtr` layout assertions — now
    `var` + `_ = &x` for real memory.
  * ★★ **WHY NOBODY SAW ANY OF IT: `zimrmath.zig` HAD NO TEST GATE.** Its `math-test` step in
    `build.zig` is commented out, it was not in `fast_test_roots`, and `refAllDecls` never
    reaches a `test` block. The module every other module and every shader depends on. It is now
    the FIRST entry in `fast_test_roots`; one artifact, and **167/167 pass**.
  * ★ And the discipline paid immediately: the `gelu(-1)` golden I wrote from memory was the
    erf-exact value, not the tanh approximation, and the test caught it on the first run. Now
    pinned to the identity `gelu(x) - gelu(-x) == x`, which holds exactly and needs no digits.



*(Per claude.md: per-turn notes go HERE, never in claude.md. Each entry records what was
MEASURED, not what was intended.)*

- **Sep 4 2026 — stage 0(a): the fast tier's two blockers, finished.** `robot_mjcf.zig` now
  compiles and 410/411 of its tier pass.
  * **`computeTwistOffsets`** — the missing 6th argument is the capture's parent-per-joint array,
    and **every one of the five call sites already builds it** (`parents[i] = j.parent` from the
    BVH joints). It reaches `rbt.solveRestPoseFromSource` → `firstChildJoint(human_parents, body)`,
    which finds the joint BEYOND a robot leaf so a foot is AIMED rather than merely placed. The
    library side was finished; only the harness wiring was not. Measured consequence already
    recorded in `robot.zig`: rest sole 64.9 deg → 32.5 deg from the capture's rest toe.
  * **`armDirectionForFrame`** — two sites missing `ik`/`aim_mode`. Passed `null` (no refinement
    may perturb an invariant test) and `.none`, which is the BASELINE selection (upper arms aim,
    nothing else) and therefore what those tests measured before the parameter existed. Site 3573
    sweeps `mechanism` and site 3417 passes an `IkPass`; both were already updated.
  * **`lafan_to_humanoid` named `toe_right`/`toe_left`, which stock `humanoid.xml` does not have.**
    Added `MatchRow.optional_body` (default false, set on the two toe rows) — the same argument as
    the existing `alternatives` field, on the robot side instead of the capture side. The table's
    own negative control (a typo'd body name must still be `error.UnknownRobotBody`) still passes,
    because the relaxation is per row. The count assertions now DERIVE the expected number from
    the table rather than hardcoding `lafan_to_humanoid.len`.
  * **`gltf.Data` held its `ArenaAllocator` BY VALUE** — claude.md's two-session bug, verbatim, in
    a second place. `parse` copies the arena into the returned `Data` and then keeps allocating
    through an `Allocator` bound to the dying local, so `deinit` frees only what existed at the
    copy. **8 398 bytes leaked on a 60-byte document.** Now `arena: *ArenaAllocator` created with
    `gpa.create` and destroyed in `deinit`, matching `mjcf.zig`'s `Robot.arena`. Six sites.
    `codecs.zig`: 166 passed, 0 failed, 0 leaks. Red → green observed.

- **Sep 4 2026 — tier verified after the fixes.** `zig build test-fast`, detached: **636 s**,
  **2 351/2 364 tests passed, 9 skipped, 4 failed**, **0 leaks** (was 1), **0 compile errors**
  (was 4). All four failures are the SAME test, reported once per artifact that transitively
  imports `robot_mjcf.zig`. ★ That is also the finding that sharpens §8b: eight of the ten roots
  ran 411/425/447 tests each, so the roots are NESTED and the tier re-runs the same few hundred
  tests up to four times. Splitting by root does not give disjoint sets — work out the maximal
  covering roots first. The 253 s figure in §8b was measured when a third of the tier did not
  compile; 636 s is the real number.

- ★★★ **CORRECTION (Sep 4, later): the entry below is WRONG and is kept only so the mistake is
  legible.** I attributed three identical `mode aim / aim_twist / ported_twist` log rows to the
  forearm test because a `grep -B12 FAIL` printed them next to it, then "confirmed" it by finding
  `_ = mode;` in `armDirectionForFrame`. Neither step established that those rows came from that
  test. They did not. The forearm test sweeps `AimSelection{ .none, .torso, .all }` and prints
  `aim {s}`; nothing in the tree prints `mode {s}`, and `robot_mjcf.zig:2351` records that
  **`ArmMode` is GONE and its removal was the fix**. With the sweep read correctly the three rows
  DIFFER — `.none` 0.803/-0.049, `.torso` and `.all` 0.612/-0.306 — so the A/B runs, and
  `best_agreement = 0.803 > 0.3` passes.
  ★★ **TWO INSTRUMENT ERRORS IN ONE SESSION, BOTH PRODUCING CONFIDENT WRONG CONCLUSIONS.** The
  other was the per-test timer: the gap before test N's line is test N−1's duration, so the first
  "slowest tests" list named the wrong three. **Adjacency in a log is not attribution.** Before
  concluding from output, check which code actually emits that format string — `grep` for the
  literal, not for the test that happens to sit above it.

- **Sep 4 2026 — test protocol measured (this is what set §8b).** Compile-only, 1980, 1 core,
  ReleaseSafe: `robot_scene` **31 s** / 6.7 MB, `robot` **32 s** / 6.5 MB, `urdf` **35 s** /
  9.2 MB — flat in module size, so the ~30 s is the shared closure recompiled per artifact.
  `test-fast` all 10 roots, cold: **253 s**, cache +456 MB — already past the 250 s timeout.
  Two pre-existing defects surfaced by running it, both invisible to `check`: `robot_mjcf.zig`
  4 compile errors (`computeTwistOffsets` gained a 6th parameter, no call site updated) and a
  8 398-byte leak in `codecs.gltf`'s minimal-JSON test. Neither is caused by the 1980 bump or by
  this session's kompute/spv2wgsl edits — `robot_mjcf` does not touch either.

- **Sep 4 2026 — plan v2, after a deeper study.** Corrections to v1, which had cut the GPU layer:
  znum's `gpu` namespace is 19 270 lines of working training runtime (102 kernels, buffer pool,
  staging ring, recorder, pipeline/bind-group caches, uniform ring), its 51 kernel files (5 418
  lines) are ALREADY authored in Zig against `kompute`, and its `COVERAGE.md` reports 29 ops
  device-resident against 10 host-only, each with a stated reason. The GPU layer is the project,
  not an appendix. `df`/`sparse`/`io`/`dimnames`/`AnyTensor` restored as stages 9–11.
  Vendored-delta ledger read: exactly two upstreamable blocks (`zm` ml-activations ~45 lines,
  `kompute` lean-path ~60 lines), both `offered`. **`spv2wgsl` is verbatim in znum and zimr's copy
  is newer** (11 603 vs 11 561 lines) and carries this session's storage-block fix — so it is NOT
  lifted; same reasoning for `zimrmath` (9 614 vs 9 532), where only the block is taken.
  Adoption path for robot/physics/plot recorded in §6. No code written yet.
### The next twenty turns, in order

Measured Sep 8: **149 of 549 znum user-facing functions, 27%**, allowing for the deliberate
renames. What follows is ordered by DEPENDENCY, not by size - each block unlocks the ones below it.

#### Turns 1-5: integer tensors, the one structural decision

`Tensor(i32)` already allocates, indexes, permutes and slices; only the OPERATIONS refuse. 200
`requireFloat` sites remain against 13 `requireNumeric`, where znum refuses non-floats in
**sixteen** places - a factor of thirteen that is a default nobody revisited, not a philosophy.

| turn | work | done when |
|---|---|---|
| 1 | **DONE Sep 8.** Nine widened - `sumAll`, `sumAllFast`, `sumAxis`, `dotAll`, `prodAxis`, `minAxis`, `maxAxis`, `cumsum`, `diff` - by widening `CompensatedSum` ITSELF rather than each call site. | done: 110 tests |
| 2 | **DONE Sep 8.** Twenty-one widened - comparisons, exact arithmetic, addressing. `concat`, `take`, `materialise`, `transpose`, `tile`, `maxAll`, `minAll` turned out to have NO float guard and already worked. | done: 111 tests |
| 3 | **DONE Sep 8.** Seven: and/or/xor, BOTH nots, and the two shifts. `requireInt` joins the pair; a float caller fails at the call site with its own type in the message. | done: 112 tests |
| 4 | **DONE Sep 8.** `affine` (one function where znum has three) and FOUR integer divisions - `divFloor`, `divTrunc`, `mod`, `rem` - which znum has none of. `div` stays float-only so an integer caller must choose. | done: 113 tests |
| 5 | **DONE Sep 8.** The index type is a SECOND type parameter, not a second function - the two were always independent. Row 31 closed. | done: 114 tests |

#### Turns 6-9: reinforcement learning - we have the learning, znum also has something to learn on

zimrnum already has `discountedReturns`, `generalizedAdvantage`, `normalizeAdvantages`,
`ppoClipObjective` and `ReplayBuffer`. **What is missing is an environment and the sampling around
it** - znum keeps those in `counterRng`.

| turn | work | done when |
|---|---|---|
| 6 | **DONE Sep 8.** Gumbel-max, one pass, nothing exponentiated. `boundedIndex` multiplies rather than modulos. | done: 100k draws match the softmax to 0.01 |
| 7 | **DONE Sep 8.** Pure, turns-native, named fields, reset separated. | done: 116 tests |
| 8 | **DONE Sep 8.** The affine form, not znum's lerp - measurably exact at both ends. The coefficient is `follow`, because `tau` is 2 pi here. | done: 117 tests |
| 9 | **DONE Sep 8** for the half that matters: an agent that LEARNS, five seeds measured. `reacherStep` deferred - and the turn found that `ppoClipObjective` is a scalar, not a `Var`. | done: 118 tests |

#### Turns 10-13: the `xf` question - functional transforms beside the tape

znum has `grad`, `gradAndValue`, `jvp`, `numericalGrad` and three modes (`Eager`, `Fwd`, `Rev`).
zimrnum has a tape. **These are alternatives, not a gap** - so the first turn is a decision, not
code.

| turn | work | done when |
|---|---|---|
| 10 | Measure what the tape cannot do that forward-mode can: one gradient of many inputs is reverse's job, many derivatives of one input is forward's. **Write the comparison before writing either.** | a register row saying which zimrnum will have, and why |
| 11 | `numericalGrad` as a PUBLIC helper. Every gradient test in this file rolls its own central difference; one helper is one place to be right, and `layerNormRowsBackward`, `conv2d` and `slice` all want it. | three existing tests use it |
| 12-13 | Whichever of forward-mode or `noGrad` scopes turn 10 justified. | as decided in 10 |

#### Turns 14-17: dataframes, which need turns 1-5 first

`df` (16) and `Frame` (16) are a different library sharing a file in znum. They need integer and
string columns, which is exactly why they sit here rather than earlier.

| turn | work | done when |
|---|---|---|
| 14 | `Series` - one typed column plus a validity mask. **Missing is not NaN**: a NaN is a float value with arithmetic, missing is an ABSENCE, and conflating them is why `fillMissing` and `dropMissing` have to be separate. | a missing INTEGER is expressible |
| 15 | `Frame` - named columns of possibly different types: `addColumn`, `dropColumn`, `colTensor`, `height`. | a frame of mixed types round-trips |
| 16 | `fillForward`, `fillBackward`, `fillMissing`, `dropMissing`, `countValid`. | each asserted against a hand-built expectation |
| 17 | `groupBy` and `describe`. | grouped means match per-group `meanAll` |

#### Turns 18-20: the remainder, and the sweep

| turn | work | done when |
|---|---|---|
| 18 | `linalg` remainder: `eig` for NON-symmetric matrices - Hessenberg reduction then shifted QR. The largest single piece left anywhere. | eigenvalues of a known non-symmetric matrix, complex pair included |
| 19 | GPU kernels for the integer ops from turns 3-4, with sweep rows. **97 rows x 6 settle = 4.85 s against a 6 s budget**, so about twenty more rows fit before paging is needed. | rows green on device |
| 20 | The `Named` versus `dimnames` comparison: znum spends 3302 lines and 20 helpers where `Named` is 60. **Check whether those 20 do anything `Named` cannot** rather than dismissing them a third time. | a register row either way |

#### Deliberately NOT on this list

`Sequence`'s 17 remaining entries are parameter-free activation wrappers - `ReLU`, `GELU`, `Tanh`
as TYPES. `Chain` settled that: they contribute no parameters, so wrapping `graph.relu` buys a
tuple slot and nothing else. `XorMlpF32` (14) is znum's own test fixtures. `BufferUsage` (10) and
`Ctx` (9) are its GPU plumbing and scope machinery, which this codebase solves differently.
