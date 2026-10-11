# rl_track_plan.md - v4 (Sep 27, 2026, evening): SuperTrack on the 10-second dance - fundamentals, the bench, the night

v4 replaces v3 (archived as `src/notes/archive/rl_track_plan_v3.md` - every step's full design and measurement up to
Sep 27, the MimicKit table, Phase R's workflow study). v2 and v1 are archived beside it; `rl_track_journal.md` is the
dated history; `supertrack_comparison.md` tables the paper, an unofficial implementation and ours. What v4 changes:
the finished work is summarised (§4), and what remains is ordered by what everything else stands on - the action path,
then a BENCH that turns every remaining choice into a measured A/B (v3 had no such tool before its last step), then
the recipe decisions, the world model's form, scale, the kit's parity, a gate, and the night.

---

## 0. Standing rules (every turn)

**No test or run longer than 5 minutes (Simon, Sep 28).** A bench arm is at most 4-5 minutes; a comparison is made
at the iterations both arms reached. The long baseline is B1's 10-minute run: the bench is deterministic, so a build
with every new knob OFF reproduces B1's rows exactly - check that on 100 iterations before an A/B leans on it.

**Turn discipline:** small steps - record (plan, journal) and end before a turn grows; `C` continues. Anything over
~60 s runs DETACHED (`setsid nohup ... > /tmp/x.log`) and is POLLED to completion within the same turn (sleeps under
~110 s). After a stalled turn: inspect processes (by pid), changed files and the newest logs first. End every turn:
lint clean, `zig build check`, snapshot `zimr2307<letter(s)>.zip`.

**Build and test traps** (each bit us):
- `check` does NOT compile the example pages. When a `pub` signature changes: grep `examples/` for its callers, and
  smoke every page that imports the changed module before landing. (`geno_track` stayed broken from T3 until the
  Sep 27 review: `FailureCheck.init` had gained the body names.)
- A `-Dtest-filter` matching nothing compiles NO test bodies; filter on the test's own name.
- Tests inside a module compile only if a test root references them; only pages instantiate `Trainer(M)` - after
  changing a trainer, smoke the page.
- Insert a declaration ABOVE the next one's `///` comment, never between them (three times on Sep 27 a struct's
  documentation silently became another's).
- Zig: no declarations between container fields; list struct fields explicitly (no `@typeInfo(...).fields`);
  `std.math` only inside zimrmath; whole-init-first (a new field joins the whole-struct literal).
- Never the full `gate` per turn; targeted tests (`zn-<stem>`, by name), then `check`. Pages in `release`, never `ship`.

**Writing lint-clean code the first time (Oct 3, Simon: "integrate the non-autofixable rules").** 10 rules autofix
(`fn-args-multiline`, `branch-braces`, `named-struct-init`, `prefer-vec`, `unused-global`, `redundant-import`,
`no-qualified-zm`, `no-qualified-std`, `float-from-int`, `prefer-decl-literal`); the other 44 need a person, so write
them right: EVERY LOCAL TYPED (`const x: T = ...`; captures and `float(...)` inits excepted); lines <= 120 columns
(name an intermediate instead of wrapping a long expression); declare file-scope names ABOVE their first use; a bare
`.init(...)` / `.create(...)` / `.alloc(...)` ONLY as the value of a declaration that names its type - spell `T.init`
in assignments, fields, arguments, returns; no locals or fns named after zm's core words (min, max, clamp, dot,
length, normalize, round, vec, lerp, ...); `@trunc` / `@floor` / `@round` straight to the int, no `@intFromFloat`,
no `@as(T, @round(x))`; `clamp(x, lo, hi)`, never `@max(@min(...))`; `sinTurns` / `cosTurns` when the argument
holds a pi or tau; no `!` on a fn that cannot fail; never swallow an error silently (`catch {}` needs an explained
`lint:off`); `assertUnreachable(@src(), ...)`, not `assertf(false, ...)`; std / builtin imports at file scope; a
fn returns a NAMED struct; snake_case file-scope value consts; no std.math / std.debug.assert / std.debug.print
outside their homes; ASCII comments and test names. Std / zm names used more than once get a file-scope binding.
**The edit loop dogfoods the linter:** after writing, `zimrlint --fix` on the touched files (the autofixes do their
job), then check mode with the enforced rules - what remains is mine to fix. `zig build check` does the same by
default since Oct 3 (`-Dautofix` on: lint --fix -> zig fmt -> lint -> compile). **Logs:** capture stdout and stderr
SEPARATELY (or through a pipe) - with `> file 2>&1` the build runner's summary overwrote the linter's findings at the
start of the file, and they looked missing. Delete a log before a background run polls it, or the poll reads the
last run's `rc`.

**The tutorial is a course (Oct 3, Simon: "make it a course with diagrams").** zimrnum's chapter 18d opens with
18d.0, the whole agent drawn once, and every later section fills one box: what it is, how to use it, the intuition,
an example worked through with numbers, a figure. Figures are inline SVG in `<figure>` (currentColor; accents via
`style="fill:var(--tok-type)"` etc.; a unique marker id each; one `<path>` per arrow), RENDERED AND LOOKED AT before
they ship (`src/notes/scripts/render_figures.py`, Playwright) - and checked again on the built page. The code
comments carry the same diagrams in ASCII and the same worked numbers, so they stand on their own.
TONE (Oct 3, Simon): comments and tutorial read like a professional book - simple and neutral. No development
anecdotes, no plan or turn numbers, no humour, no capitals for emphasis in sentences (capitalised headings are fine),
and none of the constructions that sound clever: "it's not X, it's Y", "X and its proof", "a test that can fail",
"which is the point", "exactly", "bit for bit" in prose. State what the code does and why, with worked numbers.

**NEXT: THE SPLIT - `src/zimrrl.zig` (module `zrl`) AND `zimrrl-tutorial.html`. Before B5b.**

WHY. zimrnum is 40,907 lines; its reinforcement-learning part is a separate subject with its own users (robot BMPC,
the gym / DReCon, SuperTrack's cartpole, the GPU RL rows, the cartpole_duel example). Its own module gives RL its own
tutorial, reference table and gate, and leaves zimrnum as numerics and generic deep learning.

THE LINE. A declaration moves when its doc or signature is about agents: environments and their tasks, rewards,
returns and advantages, policies and critics, exploration, replay and rollouts, the PPO / SAC / TD3 / DQN / AWR / BMPC
algorithms, world-model losses and planners. Distributions, statistics, losses that have an autograd operation,
layers, optimisers, schedules and tensor operations stay, even when only RL uses them today. The inventory is
`python3 src/notes/scripts/zimrrl_split_analysis.py` (MOVES and STAYS inside, each borderline call with its reason).
It classifies by references, not by position: a test block moves when its code (comments stripped) uses a moved
name; a private helper moves when only moved code uses it; it fails loudly if anything that stays uses a moved name.

MEASURED (Oct 3):
  - moving: 58 public declarations, 29 private helpers (fixtures, test constants, cartpoleShootingMpc), 94 of the 333
    zimrnum tests, about 9,470 lines;
  - stays, decided by the code: `ppoClipSample` and `ppoClipObjective` (Graph's PPO operation calls them, at
    zimrnum.zig ~13589 and ~14482, and a GPU kernel calls the first); `squashCorrection` (the tanh change of
    variables; GPU kernels call it); `CategoricalScalar`, `RunningScale`, `klRobustExpectation`, `gatherColumns`,
    `clipGradNorm`, `emaUpdate`, `stepParameters`, the distributions (`DiagGaussian`, `Categorical`, `categorical`)
    and `entropyRows`;
  - nothing that stays uses a moved name (checked; without the two PPO losses kept, `Graph` would have);
  - the moved code uses 64 public zimrnum names (zimrrl binds them at file scope, so moved bodies need no rewriting)
    and 2 private helpers that become `pub` in zimrnum: `ownedTensor`, `addPointMassToGrid`. Every other private
    name it uses is a std / zm alias that zimrrl declares itself.

THE MODULE. `src/zimrrl.zig`, build module "zrl", first line `//! lint:alias zrl`. The linter's `canonical-alias`
rule matches an import string against a declaring file's stem OR its declared alias, so with the module named after
the alias, `const zrl = @import("zrl");` is enforced with no linter change (the alias table is read from the heads of
the linted files: zimrrl.zig must be in the lint file list). Imports: std, zm, zn. zimrnum never imports zrl: the zn
module gets no zrl import in build.zig, so an attempt does not compile. The closure stays shader-free, so zrl is a
`test-fast` root like zn.

THE USERS. `zn.<moved>` -> `zrl.<moved>` plus the import, in: robot_bmpc.zig, robot_gym.zig, robot_supertrack.zig
and robot_mocap_tutorial.zig (the cartpole environment), gpu_learn_tests.zig, src/gpu/zn_binary.zig (cartpole step,
discriminatorReward), src/gpu/zn_conformance.zig (cartpoleStepBatch, discriminatorReward),
src/shaders/zn_rl_gpu_probe.zig, examples/cartpole_duel/cartpole_duel.zig; robot-mocap-tutorial.html quotes 32 moved
names (doc-sync checks those quotes against the source) and links `zimrnum-tutorial.html#wm-replay`. robot_bmpc.zig
keeps `zn.` for CategoricalScalar, RunningScale and clipGradNorm.

THE DIRECTION, ON THE CPU AND ON THE GPU (Oct 3, after Simon's question about PPO in Graph and RL on the GPU).
Generic code never knows an RL algorithm; RL code uses generic code. Two places broke this and are fixed in the split:
  - Graph had one algorithm-named node kind among 30, `ppo_clip` (its forward calls `ppoClipObjective`). PPO's loss
    becomes a composition of generic nodes in zrl: r = exp(log p_new - log p_old), objective = min(r A, clamp(r,
    1 - eps, 1 + eps) A) with clamp as min / max nodes, loss = -mean. Its gradient is PPO's: inside the clip range the
    two branches are the same function; outside it `min` routes the gradient to r A or to the clamped branch, whose
    gradient is zero. The distribution helpers (`klGaussianDiag`, `diagGaussianLogProb`, `squashedReparameterize`) are
    already compositions. After this Graph names no algorithm (stage S0b).
  - zimrnum's GPU half `src/gpu/zn_binary.zig` holds 4 RL kernels among its 40: `cartpole_step`, `cartpole_pole`,
    `ppo_clip`, `disc_reward` (`squash_correction` is the generic tanh formula and stays). They move to zrl's GPU half,
    `src/gpu/zrl_binary.zig`, declared with a `wants_zimrrl` flag beside build.zig's `wants_zimrnum`; only such
    kernel modules receive the zrl import, so the build enforces that `src/gpu/zn_*.zig` never imports zrl (S1b).
GPU training today uses hand-written kompute kernels (the MLP kit `zn_mlp`, `zn_train`), run by `compute_host` on the
CPU or the GPU from one source; there is no GPU autograd. Bringing SuperTrack and BMPC fully onto the GPU keeps this
shape: MLP forward / backward, Adam, SimNorm, two-hot, softmax cross-entropy and the Gaussian KL are generic kernels
(zimrnum's half); the world-model rollout and losses, value targets, policy distillation, MPPI (sampling, scoring
through batched forwards, top-k, refit), replay sampling and write-back, reanalyze and the cartpole environment are
zrl's half; the humanoid's physics is robot.zig's, and GPU-resident physics would be robot work. A fused kernel that
mixes generic maths with an RL formula lives in zrl's half.

STAGES. Each leaves the tree green and is verified before the next.

  S0 - Baseline and doc fixes (no move). DONE Oct 3: the two doc blocks moved to their owners (`saveParameters`,
  `PpoStats` - both had no doc of their own); the header's sweep paragraph states its five RL rows; the baseline
  recorded by name (src/notes/scripts/zimrrl_split_baseline.py -> src/notes/zimrrl_split_baseline.txt: 439 public
  declarations, 333 tests, 784 reference rows; folds 346). Four public declarations have no doc: cartpoleOutcome and
  ppoEpoch (write before they move, in S0b), Dense and saveTensors (later).
    - Record the baseline into `src/notes/zimrrl_split_baseline.txt` (a script): zimrnum's public names, its 333 test
      names, the reference-table rows (784), the source folds (344), test-fast (robot 631, zn 333), check (360), gate
      (406).
    - Fix two orphaned doc fragments the move would otherwise carry to the wrong owner: the StateDict paragraph at the
      top of `Categorical`'s doc (zimrnum.zig ~22818) and the PPO-report paragraph above `MinibatchOrder`'s (~24326).
    - Correct zimrnum's header: the CPU/GPU sweep does include RL rows now (ppoClipSample, the cartpole step, the
      discriminator reward), and say which library each comes from after the split.

  S0b - PPO leaves Graph. DONE Oct 3: `PpoClipLoss(T)` (build / setInputs) composes the loss from exp, sub, mul,
  min, scale, transpose and reduceRows; checked against the fused node before deleting it (value and gradient to
  1e-12, inside the range and in all four clipped regimes; a wrong upper bound fails it); Graph's `ppo_clip` kind, its
  `constants` field, `ppoClipLoss` and `setPpoClipInputs` removed; PpoModel.clip_loss is a PpoClipLoss; ppoUpdate,
  robot_gym (3 sites), the tests, both tutorials and the reference notes ported. Inputs are now [N, 1] or [1, N]
  (rank-1 refused). The analysis with the PPO loss family in MOVES: 61 public, 30 private, 95 tests, no blockers.
  zn-zimrnum 333/333, test-fast (robot 631), check 360/360, doc-sync. Disk: the build cache reached 7.7 GB and the
  disk 98% - a full disk shows as "checking cache failed: FileNotFound"; clear .zig-cache when free space is low.

  (S0b as planned:)
    - `PpoClipLoss(T)` in zimrnum for now (it moves in S3): `build(graph, log_prob_new, log_prob_old, advantages,
      clip, allocator)` composes the loss from generic nodes over two constant tensors it owns; `setInputs(log_prob_old,
      advantages)` refreshes them (replaces `Graph.setPpoClipInputs`).
    - Known answers FIRST, against the fused node while it still exists: equal loss and equal gradients (to ~1e-12)
      with ratios inside the range, above 1 + eps with A > 0, below 1 - eps with A < 0, and at the boundary.
    - Then remove the node kind `ppo_clip`, `Graph.ppoClipLoss` and `Graph.setPpoClipInputs`; switch robot_gym.zig (2
      call sites), `ppoUpdate` and the tests; the tutorials (zimrnum 21 mentions, robot-mocap 2 - doc-sync checks).
    - Docs for `cartpoleOutcome` and `ppoEpoch`.
    - Then the analysis script moves `ppoClipSample`, `ppoClipObjective` and `PpoClipLoss` from STAYS to MOVES and must
      still report no blockers.

  S1a - zrl as a facade: callers switch, no code moves. DONE Oct 4, gate 410/410: src/zimrrl.zig
  re-exports the 61 moving names (generated from the analysis's MOVES list, in nine subject groups); build.zig defines
  the `zrl` module (imports zm, zn), carries it in both module structs, and imports it beside the eight non-kernel zn
  sites; the callers switched by script (cartpole_duel, zn_conformance, gpu_learn_tests, robot_bmpc, robot_gym,
  robot_mocap_tutorial, robot_supertrack; robot-mocap tutorial 32 quotes). The GPU probe (src/shaders/
  zn_rl_gpu_probe.zig, compiled to SPIR-V by the raw command line) stays on zn until S1b, with zn_binary. A comment in
  src/gpu/zn_mlp.zig quoted by the robot-mocap fold named `zn.Temperature` and now names `zrl.Temperature`.
  test-fast (1171 / 1260, unchanged), check 360/360, doc-sync.

  (S1a as planned:)
    - src/zimrrl.zig: header (alias, dependency rule, scope), `const zn = @import("zn");`, and
      `pub const X = zn.X;` for the 58 moving names.
    - build.zig: `const zimrrl_mod: *Module = b.addModule("zrl", .{ .root_source_file = b.path("src/zimrrl.zig") })`
      next to zn's (build.zig ~3093), importing zm and zn; `addImport("zrl", zimrrl_mod)` beside EACH of the 9
      `addImport("zn", ...)` sites (an unused import costs nothing - Zig analyses lazily - and no site can be missed);
      the raw command line at build.zig ~6170 gains `--dep zrl` and `-Mzrl=src/zimrrl.zig`, preceded by zrl's own
      `--dep zm --dep zn`.
    - A script switches every user listed above except src/gpu/zn_binary.zig (S1b), and the robot-mocap tutorial's
      quotes.
    - Verify: test-fast counts unchanged, check, doc-sync, lint (canonical-alias), then the gate once (it compiles the
      GPU modules, the probe and the examples).
    After S1a every caller uses its final spelling, so S3 touches no caller.

  S1b INVENTORY (Oct 4, read-only, taken while the S1a gate ran). GPU kernel files and their entries:
    zn_unary 65, zn_matmul 4, zn_train 8: all generic, stay.
    zn_binary 40: RL -> zrl's half: cartpole_step, cartpole_pole, ppo_clip, disc_reward. squash_correction stays.
    zn_mlp 35: 13 are not generic:
      - PPO for a Gaussian policy and SAC, dispatched by robot_gym.zig -> zrl's half: ppo_mean_grad, ppo_logstd_grad,
        squash_fwd, squash_logp, squash_bwd, squash_logstd_grad, sac_target, alpha_grad;
      - SuperTrack's own passes, dispatched only by robot_supertrack.zig -> the third home, the robot's GPU code
        (SuperTrack's CPU code is robot_supertrack.zig; specialised robot code lives with the robot): st_policy_fwd,
        st_policy_bwd, st_world_fwd, st_world_bwd, cp_track_bwd.
    Apps attach kernel files per basename with the entries they use (build.zig ComputeKernel): zimrnum_field attaches
    zn_binary; cartpole_duel, geno_ppo, geno_train, getup_train and track_train attach zn_mlp. `wants_zimrnum` is
    opt-in per kernel because Zig rejects a --dep for a module the file does not import, so `wants_zimrrl` must be
    opt-in per kernel too. To check in S1b: whether CPU-backend callers name the kernel module (`zn_mlp.<entry>`) - if
    so, moving an entry changes those references as well as the build lists. Checked: outside src/gpu only
    `zn_mlp.acts_len` (a helper) and `zn_binary.kernels` (the table the sweep page iterates) are named; the training
    examples import `zn_mlp` (geno_train, geno_ppo, getup_train, cartpole_duel, track_train) and zimrnum_field imports
    `zn_binary`. Still to read in S1b: how a dispatch finds its entry (through the module value?), and the sweep page
    iterating the RL kernel table as well.

  S1b SCOPE, DECIDED Oct 4 after reading the dispatch. `compute_host.Compute(M)` takes ONE kernel module: a trainer
  (robot_gym's `Trainer(zn_mlp)`) dispatches generic kernels (dense_fwd, mse_bwd, adam) and its RL kernels
  (ppo_mean_grad, ...) through one pipe, recorded as one submission per minibatch. So:
    - zn_binary's 4 RL kernels move NOW (S1b): they call `zn.cartpoleStep`, `zn.discriminatorReward`, ... whose home
      becomes zrl in S3, so leaving them would make zn's GPU half import zrl. Only the CPU/GPU sweep dispatches them
      (zn_conformance's rows; zimrnum_field's one pipe per kernel file and `coverEvery(<file>.kernels, ...)`), so the
      move is contained: a fifth sweep pipe, `Compute(zrl_binary)`.
    - zn_mlp's 13 kernels (8 PPO / SAC, 5 SuperTrack) stay for now. They import only kompute and zm - no edge to zrl,
      so the import direction holds - and moving them needs one dispatchable set built from several kernel files
      (or two pipes per trainer, splitting its single submission). That is its own stage, S4b KERNEL SETS: design how
      `Compute` serves entries from several files; then move the 8 to src/gpu/zrl_mlp.zig and the 5 to the robot's
      GPU code. Until then the RL kernels in zn_mlp are a known exception, listed here.

  S1b-1 DONE Oct 4: the build knows `wants_zimrrl`. build.zig `ComputeKernel.wants_zimrrl` (opt-in, default false);
  the kernel's Zig module gets `zrl` when set; `ShaderPipeline.addCompute` / `addComputeKernelImports`
  (src/shader_codegen.zig) take `wants_zimrrl`: the kernel's own list gets `--dep zrl`, `-Mzn` is defined whenever
  either flag is set (zrl imports zn), and `-Mzrl=src/zimrrl.zig` is defined with `--dep zm --dep zn`. No kernel sets
  it yet; check 360/360. The SPIR-V path for it is first exercised by S1b-2's gate.

  S1b-2 DONE (Oct 4). Steps 1-2 done on disk, T0 and T1 clean - src/gpu/zrl_binary.zig written (216 lines:
  the copied ABI, `g` and the three bindings the kernels use, the 4 kernels with `zrl.`, the sacTarget note, the table,
  the installKernel trailer); zn_binary.zig lost them and points to the new file. Found and fixed on the way: three
  generic kernels' docs (bcast_add, mesh_grid_x, slice_columns) had been stranded above cartpole_step's doc; each is
  back above its owner. Steps 3-4 done on disk, T0 and T1 clean: build.zig attaches zrl_binary (wants_zimrrl) to
  zimrnum_field; the page has `pipe_rl`, its uploads, coverage, the three switch arms and a compile-time check that
  zrl_binary's Buffers / Params match zn_binary's; conformance `Kind.rl_binary` on the 4 rows. Step 5 done: the probe imports zrl;
  its raw command line lists zrl and defines zn and zrl. Step 6, verified: zn-rl-gpu (the probe compiles to SPIR-V
  through zrl), test-fast, check 360/360, the gate 410/410 - and, because THE GATE DOES NOT BUILD THE SWEEP PAGE (no
  WGSL newer than zrl_binary.zig appeared), `zig build smoke-install -Dfocus=zimrnum_field` 528/528: the four kernels
  compiled to WGSL through `wants_zimrrl`, and the page's compile-time checks ran. That build first failed: the layout
  check used `@typeInfo(T).@"struct".fields`, and this toolchain's Type.Struct has parallel `field_names` /
  `field_types`; rewritten. Control: renaming a zrl_binary Buffers field fails the page with the check's own message.
  zimrnum-ref regenerates the tutorial unchanged.

  S1b-2 - the move, in this order:
    1. src/gpu/zrl_binary.zig: header (zrl's elementwise kernels: the cartpole step and pole, PPO's clipped sample,
       the discriminator reward); imports kompute, zm, zrl (and zn only if a kernel uses a name that stays in zn);
       `config`, `Buffers`, `Params` copied from zn_binary.zig unchanged (the sweep binds every binary file the same
       way); a `kernels` table of its 4 entries; the 4 kernel functions moved with their docs, `zn.<moved>` ->
       `zrl.<moved>`.
    2. zn_binary.zig: the 4 kernels and their `kernels` rows removed; its header says where they went.
    3. examples/zimrnum_field: build.zig attaches zrl_binary (its 4 entries, `wants_zimrrl = true`, plus
       `wants_zimrnum` if step 1 needs zn); the page gets a pipe `Compute(zrl_binary)` and `coverEvery(zrl_binary.kernels,
       ...)`, and a comptime check that zrl_binary's Buffers and Params match zn_binary's field by field.
    4. src/gpu/zn_conformance.zig: `Kind` gains a member for the new file; the 4 rows use it.
    5. src/shaders/zn_rl_gpu_probe.zig: its moved names spelled `zrl.`; the raw command line that compiles it
       (build.zig ~6170) defines `zrl` and lists it.
    6. Verify: T0 / T1 on every touched file; test-fast (the conformance rows' CPU side), check, then the gate (it
       compiles zrl_binary to WGSL through the new path and builds the sweep page).

  S1b - zrl's GPU half (as first planned; the scope above replaces its zn_mlp part). (NEXT)
    INVENTORY FIRST, BY READING EACH KERNEL (Oct 4): the first count (4 kernels in zn_binary) only searched files that
    import zn. Scanning every src/gpu/zn_*.zig for kernels whose names or docs speak of agents finds, in zn_binary:
    cartpole_step, cartpole_pole, ppo_clip, disc_reward (squash_correction is the generic tanh formula; adam_step_warm
    and polyak_follow are generic training); and in zn_mlp.zig (the MLP kit): sac_target, alpha_grad, squash_logp,
    squash_bwd, squash_logstd_grad, min_route, cp_force, lat_gather, lat_act, lat_act_bwd, st_policy_fwd,
    st_policy_bwd. Classify each into three homes: zimrnum's GPU half (generic arithmetic), zrl's GPU half
    (reinforcement learning), or the robot's own GPU code (SuperTrack-specific: st_*, lat_* - the robot's world model
    and policy). Record who dispatches each (the apps' kernel lists, compute_host users, the examples) before moving
    any.
    - src/gpu/zrl_binary.zig: the 4 RL kernels moved out of zn_binary.zig (`cartpole_step`, `cartpole_pole`,
      `ppo_clip`, `disc_reward`), calling `zrl.` formulas; build.zig gains `wants_zimrrl` beside `wants_zimrnum`
      (kernel_mod.addImport("zrl", ...) only for those); every app whose kernel list names these entries lists the new
      module; zn_conformance.zig's rows for them dispatch to it.
    - Verify: the CPU backend of the sweep in test-fast, then the gate (it compiles the kernels to WGSL and builds the
      sweep page).

  S2 - The doc tooling generalised (no output change). DONE Oct 4: tools/zimrnum_ref.zig has a `Library` table
  (alias, source_path, page_path, optional sweep_path; configured with zn only), `Parsed` (source read, declarations
  extracted), and `documentLibrary` (main's old per-page body, comments kept); main parses every library first, then
  documents each page, then reports duplicate notes once. `insertSourceFolds` takes every parsed library and matches
  each alias, keying folds by (library, name), so a page can fold and arity-check calls into any library;
  `kernelsFor` and `extractDeclarations` take the alias and the path. Verified: three runs, each reproducing
  zimrnum-tutorial.html byte for byte (785 rows, 348 folds); lint clean; check 360/360. To add zrl in S3: one more
  `libraries` entry.
    - tools/zimrnum_ref.zig: a table of libraries {alias, source, page, sweep (optional)}. Per page: its own reference
      table; folds and call-arity checks for every library the page names. Configured with zn only.
    - Verify: `zig build zimrnum-ref` reproduces zimrnum-tutorial.html byte for byte.

  S3 - The move (scripted, re-runnable from the S2 snapshot; no hand edits to moved code - every fix goes into the
  script). (NEXT) Done in three sub-steps, each recorded here before the next:
      S3a DONE (Oct 4): src/notes/scripts/zimrrl_split.py; its dry run (`--dry-run /tmp/split`) passes every
            invariant - 61 public, 30 private, 95 tests, 9,560 lines moving; zimrnum keeps 238 tests and 380 public
            names, zimrrl gets 95 and 61 (380 + 61 = 441 = the 440 before plus addPointMassToGrid, now public);
            test names conserved; no moved name left in zimrnum; nothing in zimrrl used above its declaration.
            Fixes found by the dry run, all inside the script: a private helper whose code uses a moved name moves
            (a fixture and its tests otherwise waited for each other); R02 REPLAY and R03 ROLLOUTS, RETURNS AND
            ADVANTAGES grouped by dependency, each layer sorted topologically; the two SequenceReplay tests' local
            `length` renamed `window_length` (zimrrl does not shadow zm's words); moved one-line std / zm aliases
            join zimrrl's alias block; `ownedTensor` (a one-line test helper) is copied, not published. The
            outputs pass zig fmt and ast-check; after `zimrlint --fix` (22 fixes: zm keywords bound once at file
            scope - cosRad, sinRad, pi, radFromDeg - and unused aliases dropped) both lint with 0 findings.
      S3b DONE (Oct 4). The split is applied: src/zimrnum.zig 31,350 lines, 238 tests; src/zimrrl.zig 9,891 lines,
            95 tests; `src/zimrrl.zig` is a fast test root (`zn-zimrrl`, in test-fast). zimrnum's reference table
            649 rows (the moved ones gone; addPointMassToGrid and DiagGaussian.half_log_tau added with notes), 305
            folds - the RL chapters still in zimrnum's tutorial have lost their folds until S3c moves them. Two
            compile errors the analysis could not see - Zig lets a file read a type's private members only from
            inside that file: zrl read `DiagGaussian(f64).half_log_tau`, and zimrnum's `numericalGrad` called
            `PpoClipEval.loss`; both made pub, by rules in the script. Verified: zn-zimrrl 95/95, zn-zimrnum 238/238,
            test-fast 19/19, check 360/360; and re-running the pipeline (apply, `zimrlint --fix`, `zig fmt`) from the
            backups reproduces both files byte for byte.
      S3c-1 DONE (Oct 4). zimrnum: the tutorial check is `pub fn expectReferenceTableMatches(html, source)` (one
            definition; zimrnum's test is a one-line call). zimrrl.zig: its tutorial check through that helper, an
            ASCII scan and the suffix scan (the leaked-names scan guards zimrnum's own past renames and stays
            there). src/notes/tutorials/zimrrl-tutorial.html: header, chapter 1 (what zimrrl is), chapter 2 the
            generated reference table (139 rows); zimrnum_ref's `libraries` has the zrl entry; the page is in
            build.zig's doc-pages. Notes added: expectReferenceTableMatches, loss (PpoClipEval's). Verified:
            zn-zimrnum 238/238, zn-zimrrl 98/98, doc-pages 32/32, check 360/360; control: removing CartpoleState's
            row fails zrl's check by name. Found, for S4: the generator reports 18 names with more than one note
            (slice exp log softplus elu silu gelu conv2d klGaussianDiag reshuffle observe step add ...), only the
            first of each rendering. From here on zimrrl.zig is edited directly.
      S3c-2 DONE (Oct 4) - S3 COMPLETE, THE SPLIT IS DONE. src/notes/scripts/zimrrl_tutorial_split.py moved
            chapters 16, 18b, 18d and sections 11.24, 11.25 to zimrrl-tutorial.html as chapters 2 (building blocks,
            with 2.13 / 2.14), 3 (training policies) and 4 (world models, 18d.k -> 4.k, the course map its unnumbered
            opening); reference is chapter 5. zimrnum keeps pointers with the old ids and numbers; its title no
            longer says RL; cross-page links retargeted; a pre-existing dangling link (#polyak) fixed;
            robot_bmpc.zig's header and 8 references -> chapter 4; robot-mocap's link -> zimrrl. Folds: 285 + 63 =
            348, the total before the split. Verified: zimrnum-ref idempotent, zn-zimrnum 238/238, zn-zimrrl 98/98,
            doc-sync, doc-pages 32/32, check 360/360, test-fast 19/19, the focused sweep page 528/528, the gate
            412/412; on the built zrl page all 11 figures are present with renumbered labels.
      S4 - LATER, each on its own: test names "zn rl: ..." -> "zrl: ..."; kernel sets, then zn_mlp's 13 RL kernels to
            zrl's GPU half and the robot's; close the gaps in zimrnum's chapter numbers (16, 18b, 18d are pointers);
            a tone pass over the moved chapters' headings (e.g. "a unit error with no symptom"); the 18 names with
            more than one reference note.
      RL TUTORIAL ORGANISATION (Simon, Oct 4: "read it all, find the best organisation, make it read well as a whole")
      - IN PROGRESS, before B5b. Read in full (chapters 2-3 ~7,600 words; chapter 4 is the recent BMPC course and
      already flows). Findings: chapters 2 (old reference notes) and 3 (newer teaching) treat the same topics twice -
      terminal/truncated three times (2.1, 2.14, 3.3), PPO's clip three times (2.2, 2.9, 3.5), replay (2.3, 3.4) and
      cartpole (2.4, 3.13) twice; 2.5 mixes an end-to-end test story with the PpoClipLoss passage; chapter 2 carries
      development history (znum comparisons, the turns-vs-radians story, a review's "61% identical") and testing
      detail. DESIGN - follow the library's layers, as a course (chapter 3's teaching flow is the spine):
         1 What zimrrl is (+ how the tutorial is organised)
         2 A first agent: 3.1 the shape of a run, 3.2 a first policy
         3 Environments and episodes: 2.4 cartpole (history removed), 3.13 two tasks, how an episode ends (2.14 + 3.3)
         4 Experience: rollouts and replay (3.4 + 2.3), advantages / GAE (2.6 + 2.1), minibatches (2.13, cleaned)
         5 Policies: 2.7 distributions, 3.8 sampling vs training, 2.8 squash, 3.12 attention over a scene
         6 On-policy: PPO and the clip (3.5 + 2.2), the objective as a loss and its two numbers (2.9 + 2.5's PPO part),
           3.7 AWR
         7 Off-policy: 3.6 the loop, 2.10 DQN, 2.11 SAC and variants, 2.12 TD3
         8 Imitation and tracking: 3.9 adversarial, 3.10 differentiating a gradient, 3.11 tracking rewards and DTW
         9 World models and planning: chapter 4 as it is (4.k -> 9.k)
        10 Reference
      2.5's end-to-end test story is dropped (testing detail). Section ids are kept; a merged section keeps the
      absorbed section's id as an extra anchor. Headings lose their clever second halves ("..., and a unit error with
      no symptom"). STEPS: (1) restructure by script - moves, chapter openings, headings, numbering, contents,
      robot_bmpc.zig's references (4.k -> 9.k), zimrnum's pointers; verify; (2) merge the duplicates; (3) a prose
      pass for tone and transitions, chapter by chapter.
      STEP 1 APPLIED (Oct 4; backups in /tmp/big/org): src/notes/scripts/zimrrl_tutorial_reorganise.py - ten chapters,
      sections moved whole by id (duplicates adjacent: cartpole + rl-tasks, truncation + rl-truncation, rl-collect +
      rlreplay, gae + rlgae, rl-ppo + rlppo), headings retitled, the world-model chapter 4.k -> 9.k (prose and figure
      labels, not attribute values), contents regenerated, robot_bmpc.zig's references -> 9.k, zimrnum's pointers
      updated (minibatchorder's pointer says 4.5 - it becomes 4.3 after step 2's merges). VERIFIED: zimrnum-ref (zn 650
      rows / 285 folds, zrl 139 / 57 - the dropped section's 6 folds gone), zn-zimrnum 238/238, zn-zimrrl 98/98,
      doc-sync, doc-pages.
      STEP 2 APPLIED (Oct 4; backups in /tmp/big/merge): src/notes/scripts/zimrrl_tutorial_merge.py - four merged
      sections (3.3 how an episode ends, 4.1 rollouts and replay, 4.2 GAE with the recurrence, 6.1 PPO's clip), each
      keeping the absorbed id as an anchor; ppoClipSample's quote matches the source again; minibatchorder 4.3 and
      zimrnum's pointer with it. VERIFIED: zimrnum-ref (zrl 139 rows, 56 folds - the duplicated Transition example
      is quoted once), zn-zimrnum 238/238, zn-zimrrl 98/98, doc-pages 32/32.
      STEP 3, WIDENED (Simon, Oct 4: "reduce the tutorial by 20%: cut less interesting details and dev anecdotes;
      tone more neutral and precise; maybe add diagrams"). Baseline (prose words, folds / code / figures / reference
      excluded; measured by src/notes/scripts/tutorial_measure.py): 13,797 words, 512 code lines; target
      <= 11,040 words. Chapter words: 1: 237, 2: 359, 3: 939, 4: 941, 5: 1,175, 6: 1,092, 7: 1,288, 8: 1,328,
      9: 6,438. Plan: about 30% from chapters 3-8 (anecdotes and test details live there), about 15% from 9 (detail,
      after reading it); diagrams where they carry intuition - the run loop (2.1), terminal vs truncated on a
      timeline (3.3), the GAE recurrence (4.2), PPO's clipped objective against the ratio (6.1). Progress per chapter
      is recorded below as it lands.
      LANDED (Oct 4; backup of the page before step 3 in /tmp/big/trim; section bodies replaced by
      src/notes/scripts/tutorial_replace_section.py PAGE DIR, one DIR/<id>.html per section): chapter 2 359 -> 290
      words, the run-loop figure replaces the table; chapter 3 939 -> 655, cartpole without the history, the two
      tasks condensed, 3.3 with the terminal / truncated timeline figure. Chapter 4 941 -> 769: minibatches as three
      plain rules (the review figures and the test aside gone), GAE tightened. TOTAL 13,797 -> 13,272 words; code
      512 lines, unchanged. Verified: zimrnum-ref, zn-zimrrl 98/98, doc-pages.
      Chapter 5 1,175 -> 863 (each section around its unchanged code; TOTAL 12,960). Chapter 6 1,092 -> 851: the
      PPO clipped-objective figure in 6.1 (two panels, A > 0 and A < 0, band shaded, unclipped branch dashed) replaces
      6.2's pessimism subsection; AWR tightened. Figures now write var(--tok-type, currentColor) so a figure draws
      even without the page stylesheet. TOTAL 12,719 (-1,078); code 510 lines. Still to cut ~1,680.
      Chapter 7 1,288 -> 988 (measured blocks stated as expected values; 7.1 retitled "The off-policy loop";
      DQN's terminal subsection dropped, 3.3 covers it). TOTAL 12,419.
      Chapter 8 1,328 -> 880 (8.2's testing subsection and conversational framing gone; its three backward rules one
      aligned block). TOTAL 11,971 (-1,826, -13.2%); code 504 lines.
      Chapter 9 in progress: 9.9 750 -> ~420 (the segment comparison is two sentences and a link to robot-mocap; the
      write-back mechanics left to the code). 9.2-9.4 and 9.8 tightened (9.4's finished-window paragraph points to
      9.9). A pre-existing orphan `</div><!--/zn-source-->` in 9.3 (from the old zimrnum chapter 18d) removed - fold
      markers now balance. 9.10, 9.11, 9.15, 9.20 and the chapter opening tightened (the opening said "zimrnum's
      building blocks" - they are zimrnum's and zimrrl's now).
      THE PASS IS DONE (Oct 4): 13,797 -> 11,034 prose words (-20.0%); code 512 -> 504 lines (measured-output blocks
      stated as expected values; the numeric pessimism example replaced by the PPO figure). Three new figures - the
      run loop (2.1), terminal vs truncated (3.3), PPO's clipped objective (6.1); every theme colour in the page's
      figures now has a currentColor fallback. All 120 in-page links and the cross-page links resolve; zimrnum-ref
      (56 folds), zn-zimrrl 98/98, zn-zimrnum, doc-sync, doc-pages green; figures checked on the built page.
      Source comments in zimrrl.zig still carry the old history (znum, etc.) - a separate pass (S4).
      Was: then 7-8 (8.2's testing subsection; SAC and DQN tightened),
      then chapter 9 (read for detail; about 1,000 words). Still to cut: about 2,240 words to reach 11,040.
      Was: STEP 3 - the prose pass, in this order: chapter 3's cartpole (the znum comparisons and the turns story
      out; keep why the step is pure, why reset is its own call, the named state, radians, semi-implicit Euler);
      4.3 Minibatches (the review figures and "caught by the test" out; keep the short stride, the per-draw index,
      reshuffle from identity); 3.1 / 3.2's "zimrnum gives you" where the pieces are zimrrl's; 6.1's three orderings
      against 4.3 (one place for the short stride); 8.2's testing subsection; then each chapter opening against its
      sections, and the transitions between sections.
      Was: STEP 2 - merge the adjacent duplicates, each into the first id with the second kept as an extra anchor:
        3.3 truncation + 3.4 rl-truncation; 4.1 rl-collect + 4.2 rlreplay; 4.3 gae + 4.4 rlgae; 6.1 rl-ppo + 6.2 rlppo;
        then zimrnum's minibatchorder pointer -> 4.3. (3.1 cartpole and 3.2 rl-tasks are not duplicates.)
      STEP 3 - prose pass, chapter by chapter: development history and testing detail out (cartpole's znum and
        turns story, MinibatchOrder's review and "caught by the test", 9.x none expected), "zimrnum gives you" ->
        zimrrl where the pieces moved, transitions between sections, each chapter opening checked against its content.
      ZNUM HISTORY REMOVAL (Simon, Oct 4: "remove all mentions of znum history in source and tutorials") - IN
      PROGRESS, before B5b. Inventory: 371 lines in 14 files (zimrnum-tutorial 111, zimrnum.zig 106,
      tools/zimrnum_parity.zig 71, zimrrl.zig 25, zimrrl-tutorial 17, zimrnum_ref.zig 14, kompute 7, zimrmath 5,
      zn_unary 5, files.html 4, build.zig 3, the probe, zn_matmul, zn_binary 1 each). Development notes (*.md under
      src/notes: the plan, journal, znum_mapping, zimrnum_plan, claude.md) are the log and stay; files.md is the file
      index and is updated. A comparison is REWRITTEN to explain the design directly, never just deleted.
      STEPS: (1) delete tools/zimrnum_parity.zig and its build step (its purpose is parity with znum), then
      build.zig, the small files, files.md / files.html; (2) zimrrl.zig, then regenerate and clean zimrrl's tutorial;
      (3) zimrnum.zig; (4) zimrnum's tutorial. Verify after each: lint, zn-zimrnum / zn-zimrrl, check, doc pages.
      STEP 1 DONE (Oct 4; backups in /tmp/big/znum1): tools/zimrnum_parity.zig and its build step deleted;
      build.zig (doc-sync's stranded comment moved to its code), kompute.zig and zimrmath.zig (provenance markers),
      zn_unary / zn_binary / zn_matmul (256 = the largest workgroup WebGPU guarantees), the probe, and zimrnum_ref's
      14 notes, all without znum; files.md / files.html regenerated (only the znum_mapping.md note's entry remains,
      a development note). check 360/360, zn-zimrnum 238/238. Next: step 2, zimrrl.zig and zimrrl's tutorial.
      STEP 2 DONE (Oct 4): zimrrl.zig has no znum mention (0 of 25). The PPO doc chain is fixed - ppoEpoch has its
      38-line doc back (plus S0's "No parameter changes here: ppoUpdate is the version that trains"), ppoObjective
      its clipped-surrogate / KL-estimator doc, OffPolicyModel only its own; the paragraphs explain the design
      directly (Transition's doc said `seam`, now `episode_end`; the failure-angle test said turns, now radians).
      zn-zimrrl 98/98, lint 0. zrl's tutorial: its prose has none; 5 left inside folds of zimrnum functions, which
      step 3 removes at the source. NEXT: step 3, zimrnum.zig (106).
      ALSO DONE (Simon, Oct 4): zimrnum tutorial's chapter 2 "What exists" removed (a stale status table: it listed
      autograd, decompositions, FFT, serialisation as absent); chapters 3.. renumbered down by one (155 headings,
      letter suffixes kept: the pointers are now 15, 17b, 17d); build.zig's "section 3.1" -> 2.1 (backups in
      /tmp/big/status). zimrnum-ref (numbering check), zn-zimrnum 238/238, check 360/360, doc-pages green. Noted for the
      comment pass: zimrnum.zig, zn_unary.zig and zimrnum_field.zig cite "section 10.3 ... debt 11" of a plan, not
      the tutorial.
      STEP 3 IN PROGRESS (zimrnum.zig; backup before it: /tmp/big/znum3/zimrnum.before.zig): batch 1a done - the
      header (no longer says RL; the device-checking paragraph points to zrl_binary for the RL rows; "HOUSE RULES"
      without the donor comparison), requireFloat / requireInt, the index view, the 128 threshold, keepdims.
      Batch 1b (dataframes, 18), 2a (3100-4200, 11: Polyak lerp, Push, the Gumbel-max story, affine, compareScalar,
      reshape rules) and 2b (4200-9000, 17: bitwise not, shifts, diff, asinh/acosh/atanh, a false `exp` doc removed,
      softplus's forms, metrics, quantiles, mad, skew) done -> 54 left (zn-zimrnum green; /tmp/reflow.py re-wraps a
      doc paragraph if an edit leaves a long line). Noted for later: `Push` (the cartpole action) is RL and still in
      zimrnum. Batch 3a (Simon: "no need to keep znum magic bytes, there are no saved files"): the tensor file
      magic is now "ZIMR\0\0" (same 6 bytes and shape, so the test's pinned header bytes hold; the dtype tags are
      unchanged), its doc and the format block (source and tutorial) updated; Categorical, saveParameters, dft,
      fft, rfft, convolution modes and the two serialisation test comments rewritten. zn-zimrnum 238/238 -> 43
      left. Batch 3b (linear algebra, optimisers, convolution, 12) done -> 31 left. Batches 4a (graph and layers, 10)
      and 4b / 4c (tests, 21) done -> STEP 3 DONE: zimrnum.zig has no znum mention; lint 0, zn-zimrnum green.
      (A table row in the pseudo-inverse test, broken over three lines by an earlier wrap, rejoined.)
      STEP 4 DONE: the zimrnum tutorial's 31 prose mentions rewritten (two stale facts fixed on the way:
      resolveInferredShape does infer a -1 dimension; the MAD paragraph had a broken sentence). ZNUM HISTORY
      REMOVAL COMPLETE (Oct 4): no mention in any source file or tutorial; the only one left in a page is the
      files index's entry for the development note src/notes/znum_mapping.md (development notes kept as the log).
      Verified: zimrnum-ref, zn-zimrnum 238/238, zn-zimrrl 98/98, doc-sync, check 360/360, test-fast 19/19,
      doc-pages. Still open from this pass, for the comment pass: plan references in code ("section 10.3 ... debt
      11", in zimrnum.zig, zn_unary.zig, zimrnum_field.zig); `Push` (RL) still in zimrnum.
      Was, in order: elementwise and helpers ~3207-6885 (~25, incl. the
      Gumbel-max story at ~3737), statistics / linear algebra / FFT ~7953-10388 and ~19646-20097, graph and layers
      ~12105-16052, serialisation ~17391-17446 (KEEP the "ZNUM\0\0" magic bytes - a format identifier; only the
      comment changes), tests ~20989-28967. Each batch: read paragraphs (/tmp/paragraphs.py FILE LINES - recreate
      if lost: prints the contiguous comment block around each line), rewrite, T0/T1, zn-zimrnum.
      Earlier: STEP 2 batch 1 done (backup /tmp/big/znum2) - the cartpole and rollout paragraphs
      (8) rewritten to explain the design directly; "Register row 62" plan references gone too. 17 mentions left.
      FOUND, to fix together with the rest: a chain of three shifted docs in the PPO region, inherited from zimrnum.
      The 38-line doc above `ppoObjective` ("One PPO epoch over a rollout: shuffle, walk in minibatches ... `ppoObjective`
      is called with the flag OFF") is `ppoEpoch`'s; `ppoObjective`'s own doc ("The clipped surrogate objective over a
      batch, with the diagnostics ... THE KL ESTIMATOR IS exp(r) - 1 - r") is stranded above `OffPolicyModel`, glued
      to OffPolicyModel's own doc with no blank line; `ppoEpoch` carries only the 4-line doc written in S0. Fix:
      each doc back to its owner, S0's 4 lines merged into ppoEpoch's original, the znum paragraphs in all three
      rewritten. Then the rest of zimrrl.zig (tests at ~7560, ~9009, ~9119, ~9175), zrl's tutorial, zimrnum.zig,
      zimrnum's tutorial.
      B5b (NEXT, Oct 4), in three steps, each recorded before the next:
        B5b-1 `Bmpc(T).Schedule`: BMPC's schedule (online_trainer.py) as pure arithmetic - seed_steps = max(5 x
              episode length, 1000) environment steps of random actions; at seeding's end one burst of updates
              (pretraining: world model only); then updates after every frame. Generalised to E environments in
              lock-step by holding the update-to-data ratio u fixed: seed_frames = ceil(seed_steps / E), burst =
              seed_frames x E x u (one update per seeded step), then E x u per frame. KNOWN ANSWERS: E = 1, u = 1,
              L = 1000 is torch's (5000 random steps, 5000 burst updates, 1 per step); E = 8, L = 200 -> 125 frames,
              1000 burst updates, 8 per frame; rounding when E does not divide seed_steps; `at(frame)` for the last
              seed frame, the burst frame and the first steady frame.
        B5b-1 DONE (Oct 4), REVIEWED: `Bmpc(T).Schedule` (seed_frames, burst_updates, updates_per_frame;
              `bmpc(E, L, u)`; `at(frame)` -> Frame { planned, updates, pretraining }), beside discountFor;
              seed_episodes = 5, min_seed_frames = 1000. THE REVIEW'S BUG: the first version divided seed_steps
              among the environments, so at E = 8, L = 200 seeding stopped after 125 frames - before any episode
              had ended, contrary to the rule's purpose (five whole episodes before the planner relies on the
              model) and to BMPC's batched trainer (burst = max(5T, 1000) x envs x utd: seeding counts FRAMES).
              Now seed_frames = max(5L, 1000) per environment, burst = seed_frames x E x u, then E x u per frame;
              E = 1, u = 1 is torch's schedule exactly (why the first tests could not see the bug). Also: no
              division left (bmpc(0, ...) divided by zero); `at` restated as the timeline (no `frame + 1`
              overflow; a written-out schedule with no seed frames has no burst). The doc is a course: the
              timeline, the five-episodes grid with the counter-example, the update-to-data identity, worked
              examples. Five tests; CONTROL: reinstating the division fails exactly the three tests that check
              E > 1 (the E = 1 test passes, as it did for the bug). test-fast 19/19, check 360/360.
        B5b-2 DONE (Oct 4): `Bmpc(T).requireEnvironment` (reset(*Env, Rng, []T) void; step(*Env, []const T, []T)
              T - a compile error naming the expected signature) and `Bmpc(T).Trainer(Environment)`: init (actor,
              learner, replay; discount = discountFor(L) whatever the config says; every environment reset) and
              runFrame (act - random in [-1, 1] while seeding, the planner after; step; rows with the empty target
              while seeding; push; truncation at L with the TRUE final observation, then a reset and first_step; the
              schedule's updates, pretraining flagged). Random streams labelled: acting 1, resets 2 (per environment
              and episode), updates 3 (per update index). Arena-allocated, like the actor and the learner. Five tests
              on a stand-in ramp environment (seeding; the burst and the planned frame; episode boundaries; bit for
              bit; the discount). Controls: truncation one step early fails only the episode test; the burst passed
              as real updates fails only the burst test. test-fast 19/19, check 360/360.
        B5b-2 as planned: the loop (`Trainer`): fixed-length episodes (truncation only - BMPC has no terminal handling), random
              actions with empty targets while seeding, the planner after, rows into SequenceReplay, the burst,
              steady updates, discountFor(L). Tested on a tiny stand-in environment: counts of random / planned
              actions and of updates per phase, episodes resetting at L, the replay's contents.
        B5b-3 REVIEW DONE (Simon, Oct 4: "before the next steps, review carefully, look for bugs, improve comments
              and tutorial, make the code theoretically perfect before testing"). (1) The staleness suspect - the
              actor planning with the initial networks - cleared at all three levels (a frozen binding is
              graph.constant over the SAME tensor; push stores the view; recompute replays every non-leaf node), and
              GUARDED: a wiring test ("what the learner changes, the actor reads at its next decision"; control:
              separate networks keep every score at 0). (2) `Trainer.last_report`, checked in the burst test.
              (3) THE TASK: `zrl.tolerance` (dm_control's rewards.tolerance: gaussian / quadratic / linear,
              defaults as dm_control's; Falloff, Tolerance) and `zrl.cartpoleBalanceReward` (DMC's dense balance
              reward: upright x centred x small control x small velocity), with known-answer tests; the gate now
              rewards balance as DMC does - the setting BMPC's settings were tuned on - while its verdict stays
              behaviour (steps within 12 degrees and 2.4 m). (4) The gate's doc opens with its procedure and the
              reasons for the reward and the verdict; its config states the discount actually used
              (discountFor(L) = 0.95). (5) The tutorial: 9.21 the schedule (a timeline figure) and 9.22 the loop (the
              frame diagram, the episode table, the heart of runFrame). test-fast 19/19, check 360/360, zrl 101/101,
              lint 0. NOT YET RE-RUN: the gate - next, with the diagnostics below if it still fails.
        B5b-3 RE-RUN AND DIAGNOSED (Oct 4). With DMC's balance reward: pole up 0.200 trained vs 0.153 random - still
              failing. The instrumented run (same seeds) says the MODEL LEARNS and the PLANNER CANNOT USE IT: reward
              cross-entropy 0.99 -> 0.64 and value 1.38 -> 0.73 over the run, consistency ~1e-4; zero-action plans
              score 1.79 upright vs 0.88 level and 0.87 hanging (the model ranks states correctly); but at 0.05 rad
              the planner's candidates score 1.788 to 1.800 - a spread of 0.011, so its choice is noise. CAUSE: three
              decisions of 0.02 s look 0.06 s ahead, where no push changes the pole enough to matter, and the value
              function (the CURRENT, poor behaviour's return, after 350 updates) cannot supply the rest. FIX
              (principled, standard): ACTION REPEAT - each decision held for 5 physics steps, so the plan looks 0.3 s
              ahead, the time an untended pole takes to fall (DMC's protocol in the EfficientTDMPC paper repeats 2;
              PlaNet held cartpole actions for 8). Rewards summed over the held steps, as DMC's wrappers do; the
              verdict counts every physics step.
        ACTION REPEAT TRIED AND REVERTED (Oct 4). With 5 held steps: the planner's candidates spanned 2.24 to 2.60
              (30x the spread - it can now tell plans apart), but the model ranked states WORSE (zero-action plans
              2.28 upright vs 2.24 hanging; reward cross-entropy 1.39 -> 1.10, since it must predict five summed
              steps from data dominated by falling poles), and the gate gave 0.016 trained vs 0.033 random (per
              physics step). Reverted to 0.02 s decisions - exactly DMC's protocol (0.01 s physics x repeat 2) - with
              DMC's dense reward and the diagnosis test kept (on demand only).
        CONCLUSION: the assembled agent learns (losses fall, the model ranks states), slowly; the gate's 350 updates
              are far below BMPC's protocol (tens of thousands of updates on DMC's cartpole). At 0.145 s per update
              (32 windows, latent 32, hidden 64) and 0.39 s per frame of 4 decisions, 10k updates take 24 minutes -
              and networks this small should be orders of magnitude faster, so the overhead is in our pipeline.
        B5b-3 NEXT: PROFILE before any further gate work - where an update's 0.145 s and a decision's 0.1 s go
              (graph replay, allocation, the 101-bin heads, the value targets' policy rollouts, reanalyze's planning
              every 10 updates); fix what is not arithmetic; then size the gate from the new costs to thousands of
              updates within 5 minutes. If the CPU cannot get there, N9's GPU kit comes before the gate.
        PROFILED (Oct 4; perf 6.8 from Ubuntu's archive, `perf record -e cpu-clock` on the gate file's profile
              test - 20 seed frames, a burst of 100, 40 planned frames with an update each; 1 core, flat profile since
              release builds omit frame pointers). BEFORE: matmul 69%, log 7%, add 7%, exp 4%, tanh 3% - graph
              replay, backward bookkeeping, the optimiser and allocation each < 0.5%: the time is ARITHMETIC, not
              pipeline. FIX 1 (DONE): `zn.matmul` fast paths - rows of b and out contiguous: the (i, k, j) order,
              Neumaier vectorised across j (both corrections computed, @select per lane); b a transposed contiguous
              matrix: contiguous slices, CompensatedSum in the specification's order; anything else: the
              specification, now `zn.matmulReference` (the naive loop, kept). Every element is the same Neumaier sum
              in the same k order, so the results are BIT-IDENTICAL - a test over 5 shapes x 3 layouts compares
              exact slices; control: dropping the vector path's corrections fails it. Profile run 58 s -> 25 s,
              matmul ~5x faster (69% -> 32% of the new total). zn 239/239, zrl 101/101, test-fast, check, doc-pages
              green; the zimrnum tutorial's matmul paragraph explains the two orders and gives the measurement.
              NEXT TARGETS, from the new profile: log 16% + exp 8% + tanh 7% + ldexp 4% + softplus 3% (BMPC's Mish
              activations and 101-bin softmaxes, compiler-rt's scalar functions - a faster form changes numerics, a
              decision for Simon); `add` 14% (the generic strided walk on bias broadcasts - a contiguous fast path is
              exact); matmul 32% (path B, backward's grad @ wT, is not vectorised). Then re-size the gate.
        SIMON (Oct 4): approximations of activation functions are acceptable; and the real networks will train on the
              GPU, so CPU network performance matters for the gates and the development loop, not the endgame. So:
              CPU work is BOUNDED to what makes the 5-minute gates feasible - cheap, exact wins first - and the real
              effort stays N9's GPU kit. Exact reformulations are preferred to approximations where they exist: Mish
              needs one exponential, since tanh(softplus(x)) = n / (n + 2) with n = e^x (e^x + 2) - a fused node
              (forward x n / (n + 2); slope t + x (1 - t^2) sigmoid(x)) in place of three, scalar forms in zimrmath.
        A LEAK FOUND (Oct 4), while reading the backward pass for the fused node: seven temporaries in
              `Graph.backward` (exp, log, softplus, elu, slice, concat x2) came from the graph's allocator instead of
              the pass's scratch arena, so every backward pass through them kept its scratch - BMPC hits softplus
              (inside every Mish) and concat (latent with action) on every update, so a run's memory grew with its
              updates. FIXED (all seven from `temp`, like the other 24). Test: a graph through all six ops, its
              allocator counted (std.testing.FailingAllocator over an arena) - five passes after the first ask it for
              nothing; control: softplus reverted -> 30 expected, 36 found. (An arena's queryCapacity could not see
              it: small leaks fit the chunk already reserved.) NEXT: the fused Mish node; then an end-to-end check
              that a BMPC update asks its allocator for nothing after the first; then `add`'s fast path; re-profile;
              re-size the gate.
        MISH FUSED (Oct 4): `zm.mish` and `zm.mishSlope` (zimrmath, shader-safe, beside softplus) compute
              x tanh(softplus(x)) and its slope with ONE exponential each, from tanh(softplus(x)) = n / (n + 2),
              n = e^x (e^x + 2); the slope t + x (1 - t^2) sigmoid(x) with 1 - t^2 formed as (1 - t)(1 + t), 1 - t =
              2 / (n + 2); saturation above (1/2) log(8 / eps) (19.1 f64, 9.0 f32) returns x and slope 1. `zn.mish`
              (map over zm.mish); `Graph.mish` is one node (`.mish_op`, replay and backward, scratch from `temp`)
              where it was three. Tests: zm mish against the composition over [-30, 30] within 4e-16 relative, known
              values (mish(-1), mish(1), slope 3/5 at 0), the central difference everywhere, saturation and the
              far tail; the existing graph probe checks the node's backward by finite differences. Control: the slope
              without its product-rule term fails the graph probe. The zimrnum tutorial's activation paragraphs are
              rewritten (no history) with the derivation and a table. zn 240/240, test-fast, check, doc-pages green.
              NEXT: the end-to-end allocation check on a BMPC update; `add`'s fast path; re-profile; re-size the gate.
        MEMORY AND `add` (Oct 4). Two whole-agent tests: once warm, a BMPC update (world model, policy, and the
              reanalyze of every tenth) and a decision ask their allocators for nothing - FailingAllocator counts over
              the window 12..21 (reanalyzing at 20) and over five decisions; control: concat's backward reverted to
              the graph allocator fails the update test (1618 expected, 1678 found) and leaves the decision test
              passing (planning has no backward). `zn.zip` (behind add, sub, mul, ...) gained a ROW path - output
              contiguous, both inputs stepping by one along the last axis: the leading index walked once per row,
              each row a linear loop - for a (1, n) bias under (m, n); exact by construction; test over (3, 5) +
              (1, 5), (2, 3, 4) + (4) and the walk's (3, 5) + (3, 1); control: rows never advanced fails it.
              RE-PROFILED: the profile run 25 s -> 15 s (58 s originally), peak memory 517 MB -> 352 MB; log gone
              (Mish fused), add 14% -> 3.4%; matmul is back to 54% (about 8 s, as before in absolute terms), then exp
              9%, layerNorm 7%, mish 6%. zn 241/241, zrl 101/101, test-fast, check green.
              NEXT: matmul's breakdown by path (the three helpers kept apart in a profile build) - path B (backward's
              grad @ wT, scalar) is the suspect - and its fix; then re-size the gate from the new costs.
        @divCeil (Simon, Oct 4: verify zimr has no std.math.divCeil - Zig added `@divCeil`). Verified: no
              `std.math.divCeil` in code (only zimrmath's test, as the reference). The toolchain (0.17.0-dev.2307)
              has the builtin - scalars, vectors, unsigned, minInt, mixed widths, all probed. `zm.divCeil` (the
              checked wrapper: a zero divisor is an error) now calls `@divCeil`; its old body, -@divFloor(-a, b),
              could not take an unsigned dividend and overflowed at minInt - both now known answers in its test.
              24 hand-written ceilings (a + b - 1) / b in host code and examples became `@divCeil` (exact across the
              type, where the idiom overflows near the top): codecs, physics2d, compute_host, material, net_core,
              zimrrl, robot_geno's test, five examples. GPU KERNELS KEEP THE IDIOM: Zig's SPIR-V backend reports
              "TODO (SPIR-V): implement AIR tag div_ceil" (zimrnum-field: 69 steps failed) - the three kernel lines
              reverted, each with a comment giving the reason. A zimrlint shader rule (like shader-no-atan) is
              possible but not added. robot-mocap's fold of compute_host.run regenerated; check 360/360,
              test-fast green.
        MATMUL BY PATH, AND THE GATE AT 1650 UPDATES (Oct 4). Profiled with the three paths kept apart: path A
              (rows contiguous, vectorised) 46%, path B 6.6%, the specification nothing. Path A REGISTER-BLOCKED:
              `matmulColumns(lanes, count)` keeps `count` vectors of sums and compensations in comptime-indexed
              arrays (registers) across the whole k loop - blocks of 4 vectors, then single vectors, then single
              columns (a one-lane vector); lanes from `suggestVectorLength` (4 f64 here: LLVM prefers 256-bit on this
              AVX-512 Xeon). Bit-identical (test shapes now include n = 45, the single-vector path). The annotated
              loop is packed ymm arithmetic with mask-register selects and no spills - what remains is Neumaier's
              ~10 operations per product. Profile run 58 s -> 12 s overall. CPU work stops here (GPU is the
              endgame). THE GATE re-sized (`gate_schedule` 50 / 1000 / 1, `gate_frames` 700 - shared with the
              diagnosis): 0.333 trained vs 0.153 random, 3 minutes. Diagnosis: the model ranks states correctly
              (zero-action plans 6.38 upright, 5.77 level, 4.41 hanging), losses lower, but the planner's
              candidates at 0.05 rad still span 0.004 - three 0.02 s decisions change the angle little and the
              angular velocity a lot, and a value function that has seen 1650 updates of mediocre behaviour is too
              flat to tell those apart. Mastery needs BMPC's tens of thousands of updates: ~20-30 minutes on this
              CPU.
        DECIDED (Simon, Oct 4): continue the plan WITHOUT further learning runs on the CPU; the GPU work is part of
              the plan, and an OVERNIGHT WEBGPU TRAINING launches as soon as it is ready - that run is where BMPC (then
              EfficientTDMPC) must balance, and later track. The cartpole gate file stays as an on-demand check with
              its instrumented diagnosis; the profile test is removed (it served its purpose). Unit tests with known
              answers remain the way every building block is verified.
        B6a DONE (Oct 4): NETWORKS match BMPC's architecture point for point (encoder one hidden layer + SimNorm;
              dynamics two hidden + SimNorm; reward and value heads two hidden, 101 bins, zero last layer; value
              dropout 0.01 on the first layer; policy mean and log spread; target heads cloned), and the
              initialisation is TD-MPC2's (Mlp's default `small_normal`, std 0.02, zero biases). CONFIG matches
              Table 2's BMPC column value for value - with ONE GAP, BMPC's own: +2 MPPI rounds from 20 action
              dimensions (`Config.iterationsFor`, `large_action_width` 20, `large_action_extra_iterations` 2; the code
              counts `>= 20`, the papers say "> 20"), now used by `Actor.init` and so by both planners. Test: 19 / 20 /
              21 dimensions, and an actor for 20 plans the extra rounds. bmpc 34/34.
        B6b DONE (Oct 4), NO BUG: the world model's update is EfficientTDMPC's Appendix D eqs. 11-15 with one head -
              rollout from the encoded start (block 0 = o_0); consistency against each step's TRUE successor (blocks
              t + 1 = n_t); reward on the ROLLED latents with the action taken, rho^t, mean over steps; value targets
              (eq. 14) from each stored step's own observation (loadWindows: rows step x W + window), a policy draw in
              a frozen graph, the model's reward, gamma x the MEAN of the target heads at f(z, a); every value head on
              the rolled latents, mean over steps and heads; finished windows masked (BMPC-jax's normalisations).
              N7c'S DESIGN, read off where the ensemble enters: LatentRollout once per dynamics head from the same
              encoded z_0; WorldModelLoss over those rollouts - consistency and reward averaged over heads, value over
              heads x value heads (eqs. 12, 13, 15); LatentValueTargets with every dynamics head - R(z, a) is
              head-free (the true latent), only V(f_i(z, a)) is averaged over i (eq. 14); the policy loss over each
              head's detached latents (eq. 16, B6c's territory).
        B6c DONE (Oct 4), deep, NO FUNCTIONAL BUG. Policy update: the rolled latents copied as values (torch's
              zs.detach()), stored means and log spreads (every spread >= 0.05 or exactly 1, so the log is finite),
              the scale updated before the loss (recompute, updateScale, recompute, backward), masks shared with the
              rollout; PolicyDistillationLoss = sum rho^t / H x batch mean of [KL(policy || planner) / scale -
              1e-4 x dims x entropy], the KL averaged over action dimensions (torch). Reanalyze: the first R windows'
              H states step-major, one decision with every state first (no warm start), the exploration spread for the
              policy's plans, evaluate mode (the target is the drawn elite either way), targets into the batch and
              back to the replay - `writeBack` takes STEP-MAJOR rows over the given origins, which is `target_rows`'s
              layout (checked: the silent-misplacement risk). Learner.update: sample -> reanalyze -> world model ->
              policy; real updates counted from 1, so reanalyze falls on the 10th, 20th, ... CODE: clearer names
              (rolled_latent_values, latent_numbers_per_step, batch_row_index, target_column_start / _count,
              reanalyze_interval, interval_reached, reanalyzed_origins), named intermediates, diagrams of the shared
              step-major layout (policy) and of the two layouts reanalyze maps between; one inaccurate test comment of
              mine corrected (the allocation test said reanalyze ran at update 0). bmpc 34/34, lint 0.
              NEXT - THE TUTORIAL, with real figures: 9.18 the policy update (distillation: rolled latents ->
              policy -> KL to the stored planner Gaussians, scale and masks), 9.19 value-equivalent training (heads
              read ROLLED latents, targets come from TRUE ones - the shape of EfficientTDMPC's Figure 2), 9.20
              reanalyze (the batch as a W x H grid, the first R windows re-planned, back into batch and replay).
              Then B6d (the actor).
        B6c's TUTORIAL DONE (Oct 4): the existing figures were read first - 9.18 had the windows' layout and the
              five steps, 9.19 the update's two halves and the discount, 9.20 reanalyze's rhythm and flow (so 9.20
              needed nothing more). ADDED: 9.14 "Why the policy comes first" - two stored answers that disagree,
              the planner-first fit spread between them and BMPC's policy-first fit committed to one (true Gaussian
              curves), then the closed-form KL with a worked number (6.21); 9.18 "Which latents each term reads" -
              value-equivalent training in three rows (true latents and their targets, the rolled latents, the
              heads), each target routed to the heads it scores, consistency as links between the rows. Both
              rendered and checked; zrl 101/101.
        B6d DONE (Oct 4), deep, NO FUNCTIONAL BUG. The actor against BMPC's `_plan` as recorded: the policy's 24
              plans drawn once (sampled, as torch's pi(z)[1]) and fixed for the search, with the actor's spread (the
              exploration bounds in reanalyze's actor); warm start = !first_step (so never in reanalyze); Mppi: the
              mean shifted one step or zeroed, the spread reset to its ceiling (2) EVERY call (as TD-MPC2), scores
              not finite -> 0 BEFORE ranking (BMPC's nan_to_num(0)), elites weighted exp(temperature x (score -
              best)), the refit's spread clamped [0.05, 2], one elite drawn by weight; the scorer's V(z_H) the MEAN of
              the value heads; the action = target + spread x N(0, 1) when exploring, the target when evaluating.
              CODE: the actor's two-line doc became a course (a diagram of one decision, the candidates' layout per
              state, the warm start); names: candidate_scores (was scores; its uses in the tests and the cartpole
              diagnosis follow), warm_starts (was warm), decided_numbers, shapes_match. bmpc 34/34; the cartpole
              file compiles. THE REVIEW B6a-d IS COMPLETE. NEXT: B6d's tutorial half (9.17 has a decision figure - read
              it first, add only what is missing, e.g. the warm start's shift), then N7a.
        B6d's TUTORIAL DONE (Oct 4): 9.17's figure already showed the three steps, the warm start's shift worked
              through and exploration worked through - no new figure; the text gained the spread's reset at every
              decision (only the mean carries over) and the round count (6, or 8 from 20 action dimensions).
              B6 IS COMPLETE.
        N7a-1 DONE (Oct 4): `Bmpc(T).PlannerConfig` {horizon 3, candidates 512, policy_candidates 24, elites 64,
              iterations 6; iterationsFor and the 20-dimension rule moved onto it}, with a doc tabling BMPC's and
              EfficientTDMPC's two planners; `Config.horizon` is now documented as the TRAINING WINDOW only;
              `Config.acting` and `Config.reanalyzing` (default: BMPC's, alike); temperature and the spread bounds
              stay shared. `Actor.init` takes its planner (the Trainer passes `acting`, the Reanalyzer `reanalyzing`;
              reanalyze's STATE count stays training window x R, its PLAN length is its planner's). Fixtures:
              test_planner, gate_planner. KNOWN ANSWERS: every existing bmpc test unchanged (the defaults reproduce
              today's decisions); new test - acting.horizon 6 gives the acting actor 6-step plans (a decision runs),
              reanalyze keeps its planner's 3, and the training window stays 3. bmpc 35/35, lint 0.
        N7a-2 DONE (Oct 4) - N7a COMPLETE: `Config.bmpc(episode_length)` (every default, the discount from L) and
              `Config.efficientTdmpc(episode_length)` (BMPC's, acting.horizon 6, reanalyzing {3, 64, 3 policy plans,
              8 elites}); the discount rule (constants first, then `discountFor`) moved above PlannerConfig and
              Config, vocabulary first. Tests: bmpc(1000) equals the defaults with gamma 0.995 (expectEqualDeep);
              efficientTdmpc(1000) differs from bmpc(1000) exactly in those fields (set back, the configs are equal).
              Tutorial 9.23 "Two configurations": the two jobs, PlannerConfig, the training window apart, Table 2's
              planner numbers as a table, why each change (the cheaper reanalyze as its authors measured it), the
              presets in use. bmpc 37/37, zrl 101/101.
        N7b CODE DONE (Oct 4): zrl `PlanObjective` {final, mean_over_depths} and `planObjectiveWeights` - both
              objectives are weighted sums of the same rewards and values (the reward at step u is in H - u prefixes):
              final rewards gamma^u, value gamma^H at the end; mean rewards gamma^u (H - u) / H, values gamma^h / H
              at every depth. LatentPlanScorer: `Options.objective`, weights computed at build, the value heads run
              only at weighted depths (the end for final - the same cost as before), `score` the weighted sum;
              `value_probabilities` per depth x head (null where unweighted). Final's weights come from the same
              multiplications in the same order, so BMPC's scores are bit-identical (the existing hand-computed
              scorer test passes). Tests: weights by hand (H 3, gamma 0.9, both objectives; H = 1 the same); two plans
              ranked oppositely (A: rewards 1, 0, values 1, 0 -> final 1, mean 1.5; B: 0, 0 and 0, 1.2 -> 1.2, 0.6);
              the scorer's mean = (Q_1 + ... + Q_H) / H with every Q_h computed by hand from its definition.
              Control: the mean's reward weight without its prefix count fails the definition test. robot_bmpc:
              `PlannerConfig.objective` (default final), passed to the scorer; efficientTdmpc's acting planner uses
              mean_over_depths, reanalyze keeps final (Table 2); the preset test checks both. zrl 104/104, bmpc
              37/37, the zrl table 145 rows.
        N7b DONE (Oct 4): the tutorial's 9.7 gained "The objective: the whole plan, or every prefix" - Q_h defined, a
              figure (the plan's latent chain, then Q_1, Q_2, Q_3 each covering its prefix's rewards and ending at its
              value where the policy takes over; final = Q_3, the mean over all three), the two-plan example as a
              table, the weights table (H 3, gamma 0.9), the option in code. (First inserted inside the source fold's
              wrapper by mistake - moved out before the wrapper, where the doc tool does not regenerate.) zrl 104/104.
        N7c-1 DONE (Oct 4): `Config.dynamics_heads` (default 1); `Networks.dynamics` is a list - head 0 from stream
              1 as before (one head is bit-identical), head h > 0 from stream 1's split h (distinct initial weights,
              Appendix D's "initialize heads differently"); every reader takes head 0; `Learner.init` returns
              error.EnsembleTrainingUnimplemented for more than one head (refused, not half-honoured). Test: four
              heads, head 0 equal to the single head's numbers, every pair different, the learner's refusal.
              bmpc 38/38. (efficientTdmpc's preset gets dynamics_heads = 4 in N7c-2, when it can train.)
        REVIEW OF N7b's TUTORIAL AND N7c-1 (Simon, Oct 4: "review carefully the code from the last 2 turns"):
              (1) Rng.split mixes its label through a 32-bit hash, so a head's stream split(1).split(h) has no
              structural relation to the other networks' split(k) - no collision bug (a coincidence is a 2^-32
              event). (2) FIXED: zero dynamics heads left an empty list that every reader indexes - now
              error.NoDynamicsHead at Networks.init. (3) FIXED: the refusal of more than one head sat in Learner.init
              while WorldModelLearner (public, the component that trains the dynamics) built with four heads would
              silently train head 0 - moved into WorldModelLearner.init (Learner and Trainer reach it through it).
              (4) The test now also checks that extra heads leave the encoder, reward, policy, value and target
              networks unchanged number for number, that WorldModelLearner.init refuses, and that zero heads is an
              error. (5) FIXED in the tutorial: plan A's final objective was written "0 + 1 + 0 = 1"; it is
              r_0 + r_1 + V(z_2) = 1 + 0 + 0 (the total was right, the terms were not plan A's). Everything else in
              9.7's subsection checked against the definitions (Q_1 = 2, Q_2 = 1, mean 1.5; 0.81 / 3 = 0.27,
              0.729 / 3 = 0.243). bmpc 38/38, zrl 104/104.
        N7c-2 DONE (Oct 4): zrl's LatentRollout takes `dynamics_heads` + `dynamics_bounds`: ONE encoding pass (z_0
              with gradient and the detached targets shared by every head), each head rolled from the shared z_0
              (`rolled[head][step]`), `head_consistency` per head, `consistency` their mean (eq. 12). WorldModelLoss:
              `HeadTerms` per dynamics head (its reward and value logits and terms, built by `buildHeadTerms` - the old
              per-step body unchanged), `reward` and `value` the heads' means (eqs. 13, 15), the total as before.
              `meanOverHeads`: summed in order then scaled once - two agreeing heads give EXACTLY the one-head term,
              one head adds no node (BMPC bit-identical: every existing zrl test, the hand-computed rollout and loss
              ones included, and every bmpc test pass unchanged). Callers: one-element lists (zrl's fixtures; the
              robot's world model), reads of head 0 (the robot's policy learner and its test; LatentPolicyPlans
              still takes one dynamics network - the policy's plans come from one head). Tests (LossFixture
              .buildWithHeads, twinOf): two identical heads - the shared z_0, the twin's latents equal the single
              head's, consistency / reward / value / total to the bit, the shared networks' gradients equal and each
              head's half (within 1e-12, the backward pass's summation order); changing one head's weight moves only
              its own consistency term. Controls: no 1 / Nf -> the exactness test fails; every head rolled with head
              0 -> both fail. HeadTerms' table note. zrl 106/106, test-fast 19/19, check 360/360.
        N7c-3a DONE (Oct 4): zrl LatentValueTargets takes `dynamics_heads` + `dynamics_bounds`. The heads' chains are
              STACKED along the rows (block i = head i's): the policy, the reward head and the target heads read every
              block in one pass, each dynamics head steps its own block (slice, apply, concat; one head: no slicing,
              today's graph). Every block starts from the true latent and draws with its STORED ROW's noise, so at the
              first step every head draws the same action - eq. 14 exactly at lookahead 1 (R(z, a) head-free, the
              bootstrap averaged); longer lookaheads follow each head's chain with common random numbers. Each head's
              target accumulates apart (`head_targets`), averaged per stored step at the end (summed in order, scaled
              once; one head copied). Tests: two identical heads give exactly the one-head targets over the fixture's
              two-step lookahead; two different heads match eq. 14 computed by hand (one action, one reward, the
              value averaged over value heads then dynamics heads). Control: per-stacked-row noise fails both. The
              doc gained "THROUGH EVERY DYNAMICS HEAD". zrl 108/108, test-fast 19/19, check 360/360.
        REVIEW OF THE ENSEMBLE CODE (Simon, Oct 4: "review deeply, make sure there is no bug, best names, named
              intermediates"): BUG FOUND AND FIXED, PRE-EXISTING (from BMPC's assembly; B6b missed it): a dropout
              mask is a function of its generator and each element's index alone, and Graph.resampleDropout refilled
              EVERY dropout node from ONE generator - so after each resample (WorldModelLearner.update resamples
              before every forward pass) both value heads, at every step, dropped the SAME elements; BMPC's Q heads
              each drop independently. FIX in zimrnum: each node from its own split, rng.split(node index) -
              independent and reproducible; `dropout`'s doc states the rule (one generator per node); test (two nodes
              built from one generator: equal masks; resampled: different; resampled again: the same) + control (one
              generator again -> the test fails). WorldModelLoss's build-time dropout streams, which repeated per step
              and per dynamics head, are now rng.split(dynamics head).split(step).split(value head). The zimrnum
              tutorial's dropout paragraph and table note state the rule. bmpc 38/38 unchanged otherwise.
              NAMES AND INTERMEDIATES: LatentRollout dynamics_head_count, dynamics_head, dynamics_head_bound,
              head_rolled_latents, predicted_next; WorldModelLoss/buildHeadTerms value_head_count (it counted VALUE
              heads under the name head_count), value_head_divisor, value_head / value_head_bound /
              value_head_index, latent, logits; LatentPlanScorer value_head_count, value_head_divisor,
              counts_valid, depth_first_entry; LatentPolicyPlans and LatentValueTargets policy_gaussian (was `head`);
              LatentValueTargets dynamics_head_count (field and local), head_block, block_first_row,
              head_block_inputs, head_block_next_latents, numbers_per_block, true_latents, block_latents,
              sum_over_heads, head_block_target. zimrnum 242/242, zrl 108/108, bmpc 38/38, check 360/360, lint 0.
        N7c-3b DONE (Oct 4) - N7c COMPLETE: the robot trains and uses every dynamics head. WorldModelLearner binds
              every head trained (the rollout and loss through all); the model's parameters gathered as GROUPS in one
              order - every dynamics head, the reward head, every value head - which is also the clip's summation
              order (one head: today's order, bit-identical); the targets graph binds every head frozen (eq. 14).
              PolicyLearner: the heads STACKED into its batch (eq. 16) - `dynamics_head_count`, latents step-major
              with a block of W rows per head per step, the planner's targets repeated per head, the row weight
              rho^t / (H x heads x W) = the average over heads of each head's loss; masks: one head reads the world
              model's columns (one setFinished masks both losses), several get `unfinished_by_head` (each window's
              flag repeated per head, refreshed every update); the scale's first-step statistics over every head's
              windows. The refusal is gone; efficientTdmpc's preset has dynamics_heads = 4. BUG CAUGHT BY THE TESTS
              while building: the mask-refresh loop iterated the (empty, one-head) stacked columns TOGETHER with the
              world model's H columns - Zig's equal-length check panicked; now driven by the stacked columns alone.
              Tests: two identical heads (dropout 0: separate graphs hold separate dropout nodes) report exactly the
              one-head consistency / reward / value / total; one update with three heads moves every head, the
              policy's batch is H x 3 x W rows, every head's block at step 0 is the one encoded latent and the heads
              part at step 1. Controls: only head 0 in the optimiser; head 0's latents in every block - both fail the
              every-head test. bmpc 40/40, test-fast 19/19, check 360/360. (Disk: the build's guard refused at 97%
              - freed stale lint builds, old backups and an old migration directory in /tmp; the cache kept.)
              PLANNING still scores under head 0 - N7d.
        N7c TUTORIAL DONE (Oct 4): 9.24 "An ensemble of dynamics heads" - what the heads are and share, why several
              (errors compound; heads agree where the data pins the dynamics down), value-equivalent training, a
              figure (the encoded targets across the top; one z_0 fanning out to three heads' rollouts, each column
              compared with the same target; the loss averaging the heads' terms), the averaged loss terms, the value
              target through every head (eq. 14), the policy on every head's latents (eq. 16), the planner on the
              first head, `config.dynamics_heads`. 9.23's closing sentence CORRECTED (it said the networks were the
              same in both presets - EfficientTDMPC now trains four heads); pointers in 9.4 (the rollout) and 9.5 (the
              loss). zrl 108/108.
        N7d DONE (Oct 4): zrl LatentPlanScorer takes `dynamics_heads` + bounds. The heads are STACKED along its rows (one
              block of states x candidates per head; z_0 copied into every block by the 0/1 matrix; each step's
              actions concatenated once per block; the reward and value heads read every block; each dynamics head
              steps its own block - one head: no stacking, today's graph). `score` keeps today's accumulation per
              stacked row (BMPC bit-identical: every existing zrl and bmpc test unchanged), the reward part and each
              value head's part on the side, the dynamics heads' scores averaged (summed, scaled once), and
              `score_variances`: per row the VARIANCE OF THE MEAN of the Nf x Nv estimates Q(i, j) (eq. 4; divisor the
              count - the sample form would only rescale beta, recorded in the doc). The robot's actor binds every
              head for its scorer; the policy's own plans still roll head 0 (R1.6's open question). Tests:
              identical dynamics and value heads give exactly the one-head scores and no spread; two distinct heads
              x two value heads match the mean and the variance of the mean computed by hand (four estimates per
              row, each on its own graph). Controls: the estimates' variance without the second division; head 0's
              block only - both fail the by-hand test. Tutorial: 9.7 "Under an ensemble" (the Nf x Nv estimates,
              the mean, the variance of the mean); 9.24's "the planner scores with the first head" CORRECTED. zrl
              110/110, bmpc 40/40, test-fast 19/19, check 360/360.
        N7e DONE (Oct 4): zrl LatentPlanScorer `Options.pessimism` (beta): after the mean and the variance of the mean,
              each score becomes mean - beta x sqrt(variance) (eq. 10); beta 0 subtracts nothing (the branch is
              skipped - BMPC and acting bit-identical). Doc "---- PESSIMISM ----". robot: `PlannerConfig.pessimism`
              (default 0) passed to the actor's scorer; `Config.efficientTdmpc(episode_length,
              episodes_can_end_early)` - reanalyze's beta 10 where episodes can end early, else 0; acting always 0.
              Tests: zrl - two candidates A (higher mean, larger spread) and B found in the scorer's own numbers, beta*
              = (mean_A - mean_B) / (sigma_A - sigma_B) by hand: at 0.99 beta* A still wins, at 1.01 beta* B does, and
              every score equals mean - beta sigma; robot - two configurations differing only in reanalyze's beta:
              their acting actors decide alike to the bit (actions and targets), acting's scorer carries 0, the
              reanalyze actor's 10; the preset's rule both ways. Controls: beta x variance (no sqrt) fails the flip
              test; every actor reading reanalyze's beta fails the acting test. Tutorial: 9.23's table gained the
              objective and pessimism columns, its preset call the second argument (it no longer compiled as
              written), the reason for pessimism in reanalyze only; 9.7 the pessimistic score and the flip point.
              zrl 111/111, bmpc 41/41, test-fast 19/19, check 360/360. DISK: 97% after the builds - the build's guard
              refuses near there; /tmp leftovers removed and .zig-cache cleared (8 GB of stale artifacts; the next
              builds are cold).
        N7f STAGED (Oct 4) - the cross-scoring diagnostic is a BUILDING BLOCK now, measured once training exists:
              N7f-1 the chosen plan, N7f-2 the model side, N7f-3 the environment side and the report.
        N7f-1 DONE (Oct 4): zrl Mppi records `chosen_rows` - per state, the candidate row its plan came from (set by
              `choose`; `Mppi.not_a_candidate` = zm.maxInt(usize) before any choice and after `.mean`). The robot's
              `Actor.copyChosenPlan(state, plan)` copies all H actions of that row (error.NoChosenPlan before a
              decision). Tests: the row is the state's own and one of its refit elites, its first action is the answer
              exactly (no exploration), `.mean` records no candidate; the actor's chosen plan begins with the
              decision's target. Control: the row not recorded fails the zrl test. Lint caught std.math (banned outside
              zimrmath: zm.maxInt) and a qualified std.mem.indexOfScalar (now a file-scope alias); the table gained
              `not_a_candidate`. zrl 112/112, bmpc 43/43, check 360/360 (cold cache after the clearing).
        REVIEW OF N7c-3b, N7d, N7e AND N7f-1 (Simon, Oct 4: "review deeply, no bug, names, intermediates, ASCII
              diagrams, then the tutorial with real diagrams") - CODE HALF DONE. Checked: the scorer's stacked blocks
              line up (z_0's copy rows, the repeated actions, each head's slice); every estimate Q(i, j) = head i's
              reward part + value head j's part along head i (value head j at EVERY weighted depth for the mean
              objective); the variance of the mean; pessimism after the head average; Mppi.plan's loop ends sample ->
              score -> refit -> choose, so the chosen rows are the rows the elites were ranked from; the policy
              learner refreshes its stacked masks before its recompute, from this batch's flags. FIXED, a DEVIATION
              found by following the pessimism: Mppi counted every non-finite score as 0, while BMPC's nan_to_num(0)
              sends -inf to the lowest finite number and +inf to the highest - a pessimistic score whose spread
              overflowed (-inf) was rescued to 0, above every negative score. Now `rankableScore`: NaN -> 0, +-inf ->
              zm.highest / zm.lowest; test (-inf ranks last and NaN as 0; +inf first) + control (the old cleaning
              fails it). CLARITY: the scorer's doc gained the stacked-rows diagram and the Nf x Nv estimate grid;
              score's names share_per_value_head, value_head_parts_start, reward_part / estimate intermediates,
              standard_deviation_of_mean, and a comment on where each part sits; Mppi.chosen_rows a diagram of the
              candidate rows and the chosen plan, choose's `chosen_row`; Actor.copyChosenPlan a diagram. (Lint: one
              comment re-wrapped by hand; check's autofix had bound zm.inf / zm.nan to the existing aliases.) zrl
              113/113, bmpc 42/42 (the robot binary's 42 - an earlier 43 counted one more cached step), check 360/360.
              TUTORIAL HALF DONE (Oct 4): 9.7 gained three figures - the estimate grid worked through (Q = 4.8, 5.2,
              4.6, 5.4: mean 5.0, deviations +-0.2 / +-0.4, their variance 0.10, the variance of the mean 0.025, sigma
              0.16); the scorer's stacked rows (two head blocks of two states' 512 candidates: z0 copies, the same
              actions, each head stepping its block, the reward and value heads over every row); the pessimism chart
              (plan A mean 5.0 sigma 0.3, plan B mean 4.7 sigma 0.1, their penalised scores crossing at beta* = 1.5)
              - and the beta = 10 arithmetic (A 2.0, B 3.7). Rendered and fixed until clean (cell labels overflowing,
              a note past the edge, a label on its line twice). zrl 113/113.
        N7f-2 DONE (Oct 4): `Bmpc(T).PlanScoring` + `buildPlanScoring` (the scorer over the networks, frozen, on its own
              graph - the actor builds its scorer with it, the diagnostic its evaluators; bit-identical, all tests
              unchanged); `Actor.copyPolicyPlan` (candidate row 0 of the state - the policy's first plan, never
              overwritten by sampling; error.NoPolicyPlan without policy plans) sharing `copyPlanOfRow` with
              copyChosenPlan. `Bmpc(T).CrossScoring`: a single-head view of the networks (dynamics[0..1]) and the
              ensemble each plan from the same states (acting settings, evaluation mode, the same stream, no warm
              start); three plans per state (single-head plan, ensemble plan, the policy's - the same for both
              planners); two evaluators (final objective, no pessimism, a row per state and plan kind) fill
              `model_values`; `modelValue`, `meanAdvantage` (Delta R = plan minus policy, averaged over the states).
              Tests: each evaluator scores its planner's chosen plan EXACTLY as the planner did (rows are computed
              independently of their batch); both planners drew the same policy plan; Delta R by hand; identical heads
              plan alike and score alike. FOUND IN THE CONTROLS: with BMPC's zero-initialised reward and value heads
              every plan scores the same constant, so the first version of these tests was VACUOUS - swapping the
              evaluators passed. `wakeScoringHeads` (random reward and value heads, in place) fixed it, with a check
              that the heads disagree; the swap now fails. The same blind spot was in N7e's acting test (two actors'
              decisions compared with sleeping heads: a leaked beta subtracts beta x 0) - woken too, and shown: with
              the structural assertion removed, a leaked beta now fails on the decisions alone. bmpc 44/44, check
              360/360.
              THEN N7f-3: the environment side - a single-head view of the networks (dynamics[0..1]) and the ensemble plan
              from the same states; the policy's plan (row 0 of its candidates); all three scored under one head and
              under the ensemble (final objective), plan minus policy per planner per evaluator.
              THEN N7f-3: the environment side - each plan stepped open-loop in a COPY of the environment (a value
              type whose copy is a full snapshot - the cartpole), discounted real rewards then the learned value at the
              end; the report's Delta R per planner and evaluator; tests on the cartpole by hand.
        N7c-3b PLAN (the robot): WorldModelLearner binds EVERY head trained (rollout and loss through all; the
              model optimiser and the clip over every head's numbers), the targets graph through every head frozen;
              the policy learner on every head's detached latents (eq. 16 - heads stacked into the batch, the
              unfinished masks replicated per head); lift the refusal; efficientTdmpc's preset dynamics_heads = 4.
              Then the tutorial's account of the ensemble (9.4 / 9.5 with a figure).
        N7c-2 DESIGN (decided Oct 4): generalise zrl's blocks to a LIST of dynamics heads - the ensemble is a general
              idea of the TD-MPC family, so it belongs in zrl, and a list encodes z_0 and the consistency targets ONCE
              (composing one rollout per head would encode them Nf times). LatentRollout(dynamics_heads,
              dynamics_bounds): shared encodings, per-head rolled latents, consistency averaged over heads (eq. 12);
              WorldModelLoss: reward and value on every head's rolled latents, averaged over heads (eqs. 13, 15).
              One head = a one-element list; the mean over one is x / 1, exact, so BMPC stays bit-identical.
              KNOWN ANSWERS: two identical heads give the one-head losses exactly ((x + x) / 2 = x); the shared
              modules' gradients equal the one-head ones and each dynamics head's is exactly half; perturbing one
              head moves only its own consistency term. Then N7c-3: LatentValueTargets (eq. 14, the bootstrap averaged
              over heads) and PolicyDistillationLoss (eq. 16, every head's latents); then the preset's 4 heads.
        B6 THE REVIEW, split by component (each read against BMPC's algorithm and against what N7 changes):
              B6a the configuration and the networks (DONE); B6b the world model's learner (DONE) and the value targets (against
              EfficientTDMPC's eq. 14, which N7c extends to every head); B6c the policy learner and reanalyze (DONE); B6d the
              actor (the planner N7a splits in two). The tutorial half of B6 is done (zrl 9.17-9.22).
        THEN, in order: N7a-f (EfficientTDMPC to parity, unit-tested), N9 (the GPU kit: the rollout, the categorical
              heads, MPPI's scoring and the updates as WebGPU kernels), and the overnight WebGPU training (N8's runs).
        B5b-3 IN PROGRESS (Oct 4) - THE GATE IS BUILT AND FAILS. src/robot_bmpc_cartpole.zig: `CartpoleBalance`
              (force = 10 N x action; reward 1 while `failed` is false - pole within 12 deg, cart within 2.4 m - else
              0; no termination), the gate config (latent 32, hidden 64, encoder 32, simnorm 8, H 3, 4 iterations,
              64 candidates, 8 policy plans, 8 elites, 32 windows), E = 4, L = 100; `uprightFraction` (the trained
              planner in evaluate mode, one episode per environment) against `randomUprightFraction` (the control:
              an untrained planner scores every plan 0, so acts at random). `zig build bmpc-cartpole` (ReleaseSafe,
              on demand; zm / zn / zrl inherit the root's optimisation). TIMING (probes): an update 0.145 s, a
              planned frame (4 environments) 0.39 s, the compile 27 s. FIRST RUN (50 seed frames, a burst of 200,
              150 planned frames with 1 update each): pole up 0.110 trained vs 0.153 random - no better than chance.
              HYPOTHESIS: a 3-step plan (0.06 s) with a 0 / 1 reward sees no difference between plans until the pole
              is past saving, so everything rests on the VALUE function, and 350 updates do not teach it. NEXT,
              before any tuning: (1) keep the update reports in the trainer (`last_report`) and log the loss
              trajectory - do consistency, reward and value fall? (2) check the reward head against the true reward
              on upright and fallen states; (3) only then change the task or the budget - DMC's dense balance
              reward (N8 needs it anyway), and/or cheaper updates (16 windows) for more of them. A planted-model
              check if (1)-(2) show learning but the gate still fails.
        B5b-3 as planned: the CARTPOLE GATE: zrl's cartpole as a fixed-length balance task, reduced widths, judged in the real
              simulator after training, inside 5 minutes. Then the tutorial section (zrl chapter 9, after 9.20).
      B5b-2 DESIGN CONSTRAINT (from the v5 parity plan): the loop only calls `Actor.act` and `Learner.update`, so
      N7a's two planners (acting H 6, reanalyze H 3 with its own budget) change the actor and the reanalyzer, never
      the loop.
      Then: B6 (review). Then, in order: N7a-f (EfficientTDMPC to parity, on the CPU at reduced widths, each stage
      with known answers and a control; N7f's cross-scoring diagnostic before any long run), N9 (the GPU kit), N8
      (the suite and the measurements, with N8b). Also open: `Push` to zrl; plan references in code comments.
      (S3c-2 as planned:)
      S3c-2 (NEXT) - the content, in order:
            1. a renumbering map, written out first: zimrnum chapters 16 (rl), 18b (rlpolicies), 18d (worldmodels)
               and sections 11.24 (minibatchorder), 11.25 (truncation) -> zimrrl chapters 2.. in reading order
               (environments and RL operations, training policies, world models and planning), Reference last;
               anchor ids unchanged;
            2. move the HTML (prose, code, figures, folds regenerate) into zimrrl-tutorial.html; renumber headings,
               in-page references and figure labels by the map; update its contents list;
            3. zimrnum-tutorial.html: each moved chapter or section replaced by a short pointer keeping its id;
               its title drops "and RL"; the status table, GPU chapter and recipes spell moved names `zrl.`;
            4. robot_bmpc.zig's 12 section references and its header ("Chapter 18d of the zimrnum tutorial");
               robot-mocap-tutorial.html's link `zimrnum-tutorial.html#wm-replay` -> zimrrl-tutorial.html;
            5. verify: zimrnum-ref (both pages, idempotent on a second run), zn-zimrnum, zn-zimrrl, test-fast,
               check, doc-pages, doc-sync, `smoke-install -Dfocus=zimrnum_field`, then one gate.
      S3c, in two steps:
            S3c-1 - the machinery: zimrrl.zig's gate test (its page's reference table against its public
                    declarations) and its source scans (copies of zimrnum's, pointed at zimrrl); zimrnum_ref's second
                    `libraries` entry (alias zrl, src/zimrrl.zig, src/notes/tutorials/zimrrl-tutorial.html); a first
                    zimrrl-tutorial.html with its header, chapter 1 (what zimrrl is) and the generated reference
                    table; the page in build.zig's doc-pages list.
            S3c-2 - the content: chapters 16, 18b, 18d and sections 11.24, 11.25 moved to the new page with the
                    explicit renumbering map; pointer sections left in zimrnum's tutorial; robot_bmpc.zig's 12
                    section references and header; robot-mocap's link; then the full verification list and a gate.
      S3b, as planned:
            1. `python3 src/notes/scripts/zimrrl_split.py --apply` on the tree as it is now (back up both files);
            2. `zimrlint --fix` on src/zimrnum.zig and src/zimrrl.zig, `zig fmt`, then lint: 0 findings;
            3. a note for `addPointMassToGrid` in tools/zimrnum_ref.zig, then `zig build zimrnum-ref` (zimrnum's table
               loses the moved rows; its own gate test needs that);
            4. build.zig: a test step `zn-zimrrl` (root src/zimrrl.zig, modules zm and zn), mirroring `zn-zimrnum`,
               in test-fast and the gate - without it zimrrl's 95 tests would not run;
            5. zn-zimrnum (238 tests), zn-zimrrl (95), test-fast, check.
      S3a - write src/notes/scripts/zimrrl_split.py and run it as a DRY RUN into /tmp: the new zimrrl.zig and the
            reduced zimrnum.zig, with the invariants checked (public names, test names, line counts) - the tree is
            not touched;
      S3b - apply it to the tree; build zimrnum's and zimrrl's tests, test-fast, check;
      S3c - the tutorial split, zimrnum_ref's second library entry, zimrrl's gate test, then the full verification
            list below and one gate.
    - src/notes/scripts/zimrrl_split.py moves units (a declaration or a test block, each with its doc comments) in
      source order into zimrrl.zig, replacing the facade, under its own layer banners, downward-only like zimrnum's:
      R01 environments, R02 returns and advantages, R03 policy distributions and exploration, R04 replay and rollouts,
      R05 value targets (DQN, SAC, distributional), R06 PPO, R07 off-policy, R08 imitation and rewards, R09 world
      models, R10 planning; then the tests.
    - zimrrl.zig binds the zimrnum names its code uses at file scope (`const Tensor = zn.Tensor;` ...) and declares
      its own std / zm aliases. The tensor operations named with zm's reserved maths words (exp, sqrt, tanh, clamp,
      ...) are written `zn.exp(...)` in the moved code, so zimrrl needs no `lint:off`. `zimrnum.X` -> `zn.X`.
    - zimrnum: `ownedTensor` and `addPointMassToGrid` become `pub` with docs; the shape statistics left in L13
      (skew, kurtosis, geoMean, harmMean, histogram, standardisedMoment) move to L08; L13's banner goes.
    - zimrrl-tutorial.html: 1 What zimrrl is (scope, the line, import, dependency rule), 2 What exists,
      3 Environments (from 16.4, 18b.13), 4 RL operations (the rest of 16, with 11.24 MinibatchOrder and 11.25
      terminal versus truncated), 5 Training policies (18b), 6 World models and planning (18d, the course; 18d.0 ->
      6.0), 7 Recipes and gotchas (the RL ones), 8 Reference (generated). Anchor ids unchanged. Display numbers
      renumbered by an explicit map (16.x -> 3.x / 4.x, 18b.x -> 5.x, 18d.x -> 6.x), applied to headings, in-page
      references (110), figure labels (28) and code comments (robot_bmpc.zig: 12; "Chapter 18d of the zimrnum
      tutorial" -> "Chapter 6 of the zimrrl tutorial").
    - zimrnum-tutorial.html: chapters 16, 18b, 18d and sections 11.24, 11.25 become short pointer sections keeping
      their ids, so old links land on a pointer and zimrnum's numbering stays stable; the status table, the GPU
      chapter and the recipes switch to `zrl.` spellings with a link.
    - zimrrl.zig gets its own gate test (reference table against public declarations, embedding the new page) and
      its own source scans (ASCII, no leaked locals in prose, no empty suffixes), copies of zimrnum's.
    - build.zig: test step `zn-zimrrl` (root zimrrl.zig) in test-fast and the gate; the new page in the doc-pages
      list; zimrnum_ref configured with zrl (the zrl page folds and arity-checks both zrl and zn).
    - Invariants, checked by the script and then by the build: public names before = zimrnum after + zimrrl after
      (disjoint); test names before = zimrnum after + zimrrl after (333 = 239 + 94); reference rows 784 = zimrnum's +
      zimrrl's; folds >= 344 across both pages (zn folds may repeat on the zrl page); moved and remaining line counts
      add up.
    - Verify: zn-zimrnum, zn-zimrrl, test-fast (robot 631), check, lint and coverage (0 findings, tree covered),
      `smoke-install -Dfocus=zimrnum_field` (the gate does not build the sweep page),
      doc-pages, doc-sync, zimrnum-ref idempotent (a second run changes nothing), and one full gate.
    - Rollback: restore the S2 snapshot, fix the script, re-run.

  S4 - Later, each on its own: test names "zn rl: ..." -> "zrl: ..."; the RL GPU kernels into src/gpu/zrl_*.zig;
  close the gaps in zimrnum's chapter numbers; a tone pass over the moved chapters' headings.

  Turns: S0 done; S0b done; S1a done; S1b one turn; S2 one turn; S3 one or two turns; S4 later. Then B5b.

**B5a DONE (Oct 3) - reanalyze.** robot_bmpc.zig `Reanalyzer`: an `Actor` for H x R states built with the policy's
plans at the exploration bounds ([-2, 1]); `reanalyze` gathers the first R windows' stored states (step-major), decides
from scratch (every state an episode's first step), evaluated, and writes the targets into the replay (`writeBack`,
first_step 0 - our rows hold their own targets; torch's index[1:] is its layout) AND into the batch. `WorldModelLearner`
split into `sample` + `learn` (same random streams - `update` = both, numbers unchanged); `Learner.update`: sample ->
reanalyze on every reanalyze_interval-th non-pretraining update -> world model -> policy; `LearnerReport.reanalyzed`.
Config: reanalyze_interval 10, reanalyze_windows 20, exploration_spread [-2, 1]. zimrnum: writeBack's stale
"first_step = 1" doc corrected. Known answers: one decision = a fresh exploring actor's, bit for bit - its candidate
block too - into the replay and the batch, the other windows kept; never warm-started (a SECOND reanalyze = a fresh
decision); the rhythm (pretraining uncounted, 2nd of interval 2 reanalyzes) and the policy reading the fresh answers.
Controls: normal bounds, warm start, reanalyze after the policy, pretraining counted - each fails exactly its own test.
LESSONS: (1) a filtered build that passes prints NOTHING without --summary - always read the summary line, or a
compile error / silent pass reads as a result; (2) on fresh networks every candidate scores alike (zero-last heads), so
a planner's DECISION cannot see what only changes the candidates - compare the candidates themselves. test-fast 631,
check 360/360. Tutorial 18d.20 (one figure). NEXT: B5b - the warm-up schedule and the cartpole gate.

**Engineering rules:**
- A KNOWN ANSWER for every component before it is trusted (a closed form, an exact identity, a parity to float
  precision); every quality number judged in the REAL simulator, by the judge (F1).
- ONE definition per concept, so call sites cannot drift: `robot_track.Task` (the task), `judge` (every verdict on a
  policy), `robot_geno.FailureCheck` (the teacher's verdicts), `Termination.scaled` (every copy of limits),
  `trackingErrorWithHead` (the judges' error), `filterAction` (Simon's filter), `Learner.decideInto` (a SuperTrack
  decision), `bodyIndexByName` (per-robot names), `observeFrom` (DReCon observations), `gaeColumn` (advantages).
- Every graph-side feature gets a GRAPH-vs-ROWS parity: the training graph's loss equals the same rollout done row
  by row outside it (F6a's test is the template).
- Defaults preserve old behaviour; the night's settings are ONE value (A2's recipe), never scattered overrides.
- Comments casual and verbose; the robot-mocap tutorial in sync with SuperTrack/DReCon, presented when it changes.

---

## 1. The goal, stated so it can fail

**North star (Simon, Oct 5).** ONE policy, ONE objective: Geno dances the whole two-minute dance (`Motion.dance`,
LaFAN's dance1_subject2) very precisely - and from any fall, push or distance gets up and returns INTO the dance
where it now is, fluidly and the way a person would: no switch between "tracking" and "recovering"; the body's limits
respected (torque limits, energy). Trained unattended overnight on a desktop GPU in a browser page at SuperTrack's
pace; later on the phone. The design is R5 (R5.8 the unified objective, R5.9 its judge). Beyond it: the clip library
(~100 LaFAN clips - dances, locomotion, falls and get-ups).

**The FIRST night - the 10-second dance only.** After <= 10 h, ONE SuperTrack policy on `Motion.dance_5_15`, judged
by the judge (mean action, 20 starts every 0.5 s, the task's rule):
- mean time to failure >= 8 s (5x the servo alone's 1.53 s);
- >= 60% of the 20 starts reach the clip's end (the servo alone: 1 of 20);
- mean gated reward above the servo's (0.499); the exploitation index bounded all night;
- visible in the morning: Geno dancing the ten seconds.

**Later nights (Phase C):** the whole dance, precisely (R5.9: local and global position error, velocity and
acceleration error); then recovery into it - from fallen, far, fallen-and-far and pushed starts, the share back in
the dance within 5 s and 10 s, the return without a snap, the effort human (R5.9); then the clip library. Failure is
information: the morning protocol says what to look at.

---

## 2. Principles (each with the evidence that made it one)

- **P1 One task for every clip** - no switch asks which motion it is (failure, reward, starts, physics).
- **P2 The task defines failure; learners and teachers optimise, never redefine it.** Since F3b the rule is
  SuperTrack's own: the head's height within 25 cm of the reference head's, the root within 1 m / 90 deg. A teacher
  may add an early WARNING (T4b), never its own rule.
- **P3 Gravity in everything that scores or ends an episode** (frames hide gravity: lying with the right joint
  angles scored 0.80 once) - the reward's gravity gate, the head rule, heights and up in every observation.
- **P4 Root motion followed - and SEEN** by every policy (DReCon's observation does; SuperTrack's: E2).
- **P5 Simon's filter and clock wherever a policy acts - and inside its training.** Decisions at 30 Hz over 60 Hz
  physics (Simon, Sep 27: physics stays 60 Hz), held between; each decision blended 0.2 new / 0.8 applied; the
  world model learns from what was APPLIED.
- **P6 Judged in reality** - the judge, the servo as the baseline, the teacher as a ceiling where it applies.
- **P7 Measure before believing** - "expected neutral" changes have halved results before.

---

## 3. Where we stand (Sep 27 evening; 3.9 adds Sep 28)

**3.1 Geno** - a free root and 23 ball joints (69 action numbers for SuperTrack; DReCon's 10-joint subset, 30
numbers, for PPO); 21 shape-carrying bodies (`tools/geno_fit.py`, the forefoot rule); standing armature 2.0; the
servo's acceleration cap 3,000 (`servo_gains`); floor friction 2.0; self-collision off; 60 Hz, one step a frame;
`resetToFrame` + `restOnFloor` the one reset everywhere; clips lifted onto the floor frame by frame.

**3.2 The task** (`robot_geno.tracking_task`, a `robot_track.Task`): gains (the zero-velocity stable-PD servo, 20 Hz,
critically damped), `task_weights` (gate 0.2 m / 0.5), `task_termination` = SuperTrack's rule (head 0.25 m, root
1 m / 1.57 rad, every other limit off), `contact_exempt` = the feet (the unexpected-contact limit is off: mechanism
only), `head_body = "Head"`. `servo_task` is the D-phase condition. Episode grace: a learner's aid, never the judge's.

**3.3 Baselines** (the judge on `dance_5_15`: 20 starts every 0.5 s, mean action):
| | MTTF | to the end | reward |
|---|---|---|---|
| servo alone | 1.53 s | 1 / 20 | 0.499 |
| servo + velocity feedforward (dropped) | 1.52 s | 1 / 20 | 0.527 |
| teacher (10 starts every 1 s, 5 s cap) | 1.66 s | 1 / 10 | - |
Get-up, servo alone: 2.75 s, 6 / 36.

**3.4 Judge and diagnostics** - `robot_track.judge` / `Judging` (incremental) / `Actor` / `evenStarts` / `judgeOptions`;
`robot_latent.Learner.diagnose` -> `Diagnosis.trust()` (the model's error following the policy's real states over
the trivial predictor's) and `.exploitation()` (promised minus delivered improvement, over doing nothing). Judge
actors exist for the CPU learner and the GPU resident learner.

**3.5 The CPU SuperTrack learner** (`robot_latent.Learner` + `LatentWorld`): the latent residual world model
z' = z + Net(z, reference targets, applied action) over normalised `track.local` features; 2 tanh hidden layers;
MSE losses; L2 action price (`w_action`), CAPS smoothness (`w_smooth`). Options added Sep 27 (defaults = old
behaviour): `WorldOptions.normalize_from_clips` (F4a), `decide_every` (F4e), `filter` (F6a), `sees_applied` (A1) -
the recipe sets true / 2 / 0.2 / true. `decideInto` is the one definition of a decision; `appliedBefore` gives a
window its filter state; `stepAdam` is every policy update (the seven layers, then A1's block).

**3.6 The GPU learner** (`robot_latent_kit` + `robot_track_resident`, page `geno_train`): parity-tested against the
CPU learner at its DEFAULTS; uses the clip normaliser (F4a); still acts every step with no filter - it lags the
recipe (Stage G).

**3.7 PPO / DReCon and the teacher** - unchanged since v3 (archive §3.5): PPO on the kit with a CPU twin, GAE with
bootstrapped cuts, DReCon's controller (now on `filterAction`); the MPPI teacher (`Planner`, `d5_teacher`) with its
early warning `teacher_warning` / `teacher_danger` (T4b).

**3.8 Pages** - `geno_track` (servo viewer), `geno_ppo` (PPO), `geno_train` (SuperTrack): smokes green and leak-free
(Sep 27 review).

**3.9 Added Sep 28** (the ingredients' infrastructure; the journal has the known answers): `robot_track_env.TrackEnv`
- the tracking task decision by decision, one definition for every learner - with `NStep` (n-step transitions); PPO
steps through it; `robot_sac_track.SacTrack` - SAC on the dance (replay rows carry the bootstrap DISCOUNT, CPU and
kit; optional sample-time observation normalisation); in zimrnum: `categoricalProject`, `softCrossEntropy` (rows and
graph), `Params`, `Graph.detach`, `Graph.simNorm`, `Graph.klGaussianDiag` with a log-std per row; I1b's twin world
models (built, off by default); I1's world noise removed; `docfmt`'s stylesheet fixed and tested.

---

## 4. Done (summarised - designs and numbers in the archived v3 and the journal)

- **Toolchain 2307 and memory ownership** (Sep 26-27): the SPIR-V decoration fix and its two guards; the engine's
  own allocator, the leak tracer; all smokes green, the example side returning exactly 0 bytes.
- **Phase T - the task, one definition** (T1), a worst-body limit (T2, mechanism; 0.8 m chosen, later off), unexpected
  contact (T3, mechanism; OFF after the revisit showed it ending good but lagging rises), the teacher's drift
  weight (T4, 0.3 kept), the teacher's early warning without event limits (T4b: dance 1.94 s).
- **Reorder** (Simon): SuperTrack's foundations on the 10-second dance before any curriculum.
- **SuperTrack studied** - the paper, an unofficial repo (no simulator; five bugs) and ours: `supertrack_comparison.md`.
- **F1 the judge**; **F2 trust and exploitation** (CPU learner).
- **F3 velocity feedforward - dropped** (+1% survival; the option stays, off; its end-of-clip velocity fixed in the
  review).
- **F3b SuperTrack's failure rule - adopted** (equally strict as our five limits; simpler; the paper's).
- **F3c 240 Hz physics - dropped** (Simon: 60 Hz physics, 30 Hz policy).
- **F4a the normaliser from the clips**; **F4e the 30 Hz clock (CPU)**; **F6a Simon's filter inside training (CPU)**.
- **Review (Sep 27)**: `geno_track` compiled again; feedforward's end-of-clip velocity; the learner refuses a filter
  outside (0, 1] or a clock under 1; the tutorial caught up (normaliser, clock, filter); every page smoked.
- **A1 the policy sees what it is applying** (Sep 27, CPU): `LearnerOptions.sees_applied`; the first layer's
  `applied_block` (actions x hidden, starts at ZERO, its own Adam stepped with the seven by `stepAdam`); read in the
  graph (the `applied` Var before each decision), `decideInto` (the slot, reset to rest BEFORE the policy reads it),
  `modelLoss`, `diagnose` and cloning (`appliedBefore`). The seven tensors - the kit's layout - untouched. Four known
  answers, and two planted bugs each caught by the test aimed at it (journal).
- **A2 the recipe as one value** (Sep 27): `robot_geno.supertrack_recipe`, a `SuperTrackRecipe` - the fleet's
  `action_scale` beside the learner's `LearnerOptions` (a bare `LearnerOptions` cannot hold the scale, and a bench
  built from one would train at the fleet's default 0.2 rad). Two known answers: each choice against its reason
  (DReCon's clock and filter, filtered implies sees applied, the page's scale, nothing else overridden), and a learner
  built from it on Geno reads it back (30 decisions a second on the model's timestep, the block, the clip normaliser).

---

## 5. Lessons (do not relearn)

L1 frames hide gravity. L2 a greedy planner needs gravity only where the reference is low. L3 a teacher with memory
the student cannot see teaches noise. L4 cloning 660 rows memorises. L5 an episode's end has a kind. L6 what the
policy cannot see it cannot correct. L7 scale before verdicts. L8 separate the task's failure from a planner's
warning. L9 physics transfers (89 nm). (Evidence for each: archived v3 §4.) New on Sep 27:
- **L10 Equally strict rules end the same runs.** Our five limits and the head rule both catch FALLS, at the same
  moment (1.61 vs 1.53 s servo; 1.56 vs 1.66 s teacher) - so the simpler, published one.
- **L11 Less lag is not more balance.** Feedforward cut the per-step lag threefold and bought 1% survival: the limit
  is balance, which only a policy supplies.
- **L12 A graph and its row-by-row twin must agree.** The filter in the graph was trusted only once the graph's loss
  equalled a hand rollout to 1e-5, holds and starting state included.
- **L13 Pages are outside `check`.** A signature change broke `geno_track` silently for a day.
- **L17 One generator per page, and verify a regenerated page by its CONTENT.** zimrnum-tutorial.html belongs to
  `zimrnum_ref`: its folds are derived from the `zn.` names an example uses - to show a declaration, name it in an
  example. After any tool rewrites a page, check that every section is still there; a build and a fold check do
  not look at prose.
- **L16 A test filter hides the tests it does not match - from the COMPILER too.** Before closing a turn that adds
  a public zimrnum declaration, run the whole zimrnum suite (about a minute): the reference-table test checks
  every public name has a row (`zig build zimrnum-ref` regenerates it from notes in `tools/zimrnum_ref.zig`).
- **L15 `checkGradient` cannot see a parameter the forward pass never uses.** Both its gradients are then zero, and
  agree. Pair it with "every checked parameter has a non-zero gradient" (LayerNorm's gain, planted unused, passed a
  plain `checkGradient` and failed the paired check).
- **L14 Knock the model where it is ignorant, not everywhere.** Uniform noise on the model's predictions made the
  policy correct harder and exploit MORE (I1, removed); the disagreement of two models - zero where the data pins
  them, large where it does not - lowered exploitation at every look (I1b).
- **L15 A segment is not an episode.** A shove ends a segment (the world model cannot predict it) but not an episode
  (the controller's filter carries through). What was applied before a record needs the record's place in its
  EPISODE (`Replay.episodeStepAt`); an unknown one is reported, never guessed.
- **L16 Fresh memory reads as zero, so an uninitialised read passes every test.** The learner's slots were read
  before their first write for three steps (A1, F6a, F4e) without a symptom. A value read before its first write
  gets an explicit start - and a test that fails without it (the hand-over check).
- **L14 A parity measured through the loss hides the action path.** At the untrained output layer's 0.01 scale a
  wrong action moves the loss far less than the tolerance: F6a's graph-vs-rows test passed with the graph feeding
  the wrong applied action. Compare the actions themselves, and plant weights under which every input matters.

---

## 6. The work ahead - fundamentals first

(Published methods worth reproducing whole - each broken into ingredients with known answers - live in their own
section, **10. Recent advancements**. Its ingredients feed Stage I; its reproductions are measured on the bench.)

Each step: WHY - DESIGN - KNOWN ANSWER - DONE WHEN - SIZE (turns). CPU first; the kit follows what is adopted.

**6.0 THE ORDER ACROSS STAGES** (Sep 28, revised by Simon at the end of the day: "we don't need to measure things
now. The goal is to have all the necessary ingredients to be able to later build modern RL algos ... Focus on building
blocks, verifying they work. Make it all feel native to zimrnum and nice to look at." - where this and a stage's own
"NEXT" disagree, this wins). BUILDING BLOCKS FIRST, each with its known answers and a negative control, each native
to zimrnum (one definition per idea, the house idioms, comments that teach the idea); the ALGORITHMS are assembled
from them afterwards; measurements (V5, the benches) wait until a decision needs one.
  1. **N2 - the vocabulary.** DONE Sep 28: `detach`, `simNorm`, the per-row Gaussian KL, `symlog` / `symexp`,
     `CategoricalScalar` (two-hot through the SAME split as `categoricalProject`: `addPointMassToGrid`), and the
     layers' first half on zimrnum's own `Dense` template (a layer owns its tensors; `attach` records it on any
     graph; no `Sequential`): `Dense.attachAs(graph, input, .trained | .frozen)` and a `LayerNorm` layer with its gain
     and bias; and, Sep 29, the rest: `Activation` (none / relu / mish / SimNorm with a group) and `Graph.activate`;
     `NormedDense` (BMPC's NormedLinear: Dense, dropout when an rng is given, LayerNorm, the activation);
     `InitScheme.small_normal` (TD-MPC2's std-0.02 normal - its "truncated" bounds are absolute and never bind);
     `Mlp` from a `Spec` (hidden NormedDense layers; a plain head, zeroed for reward and value heads, or a normed last
     layer ending in SimNorm), with `attachAs` (all handles for an `Optimizer`), `params` (a `Params` over the same
     tensors - `clone` for a target), `withParams` (the architecture over a target's tensors), `deinit`. Known answers:
     BMPC's shapes and counts, the initialisation's statistics, a zeroed head, refused specs; `checkGradient` through
     three layers ending in SimNorm with every parameter CONNECTED (L15) and every output group a simplex; frozen =
     trained, a target that stays put then follows; dropout only with an rng and only where the spec has it; each
     activation its op; every byte back under every allocation failure. Negative control: the last layer's
     activation dropped fails exactly the simplex test. N2 COMPLETE.
  2. **N3 - the rollout builder and the world-model loss terms.** DONE Sep 29. First half: every layer now separates
     BINDING from ARITHMETIC (`applyBound` on Dense / LayerNorm / NormedDense; `Mlp.bind` and `Mlp.apply`, `attachAs`
     = both; one `bindTensor` for every trained-or-frozen choice) - binding a tensor at every step would register it
     as H separate parameters, each with a slice of the gradient; and `LatentRollout` (one encoder pass over a
     step-major window, the per-step latents sliced, the targets detached, the rollout started from z_0 WITH
     gradient, the dynamics applied H times over one set of handles, the consistency loss rho^t-weighted and averaged).
     Known answers: each rolled latent is the dynamics applied step by step from the first true encoding, bit for
     bit; the loss is the hand computation; the dynamics pass `checkGradient` and every parameter of both networks is
     connected; the encoder's gradient equals the one from a graph whose targets come from a FROZEN second encoder
     pass (finite differences are no answer for the encoder - nudging it moves the detached targets too); the batch
     rollout is each character's, row for row. Negative control: the rollout started from the detached z_0 fails the
     encoder-gradient test. Second half: `WorldModelLoss` - the reward head on each rolled latent with its action,
     every value head on each rolled latent (an array of `Mlp`s with their handles; dropout from an optional rng),
     both scored by `softCrossEntropy` against two-hot targets the builder allocates as constants (fill with
     `CategoricalScalar.encodeRows`, `recompute` - nothing rebuilt), rho^t over the steps, the value term averaged
     over the heads too, BMPC's total 20 / 0.1 / 0.1; the logits exposed. Known answers: reward and value terms equal
     a hand computation that re-applies the heads to the ROLLED latents' values; refilled targets are read at the next
     recompute and only then; `checkGradient` through the heads and the dynamics with every parameter of every
     network connected. Negative control: value heads reading the detached targets fails exactly the rolled-latents
     test.
  3. **N4 - planning by recompute, and `Mppi`** as a zimrnum planner. FIRST HALF DONE Sep 29: `LatentPlanScorer` -
     the planner's objective (r_0 + gamma r_1 + ... + gamma^H mean V(z_H)) as a graph built once from frozen
     bindings, many states at once (rows state * candidates + candidate; each state encoded once, its latent copied
     by a constant 0/1 product), the bins read back by `decodeRows` after the recompute. Known answers: every row's
     score equals a hand computation that encodes that row's state alone and rolls its own actions; rewriting one
     candidate's actions moves only its score. Negative control: every candidate starting from state 0 fails the
     hand computation. Tutorial 18d.7. SECOND HALF DONE: `Mppi` - `begin` (warm start: last plan shifted one step,
     zero at an episode's start; spread at its ceiling), `sample` (mean + spread x counter-based noise, clamped; the
     caller's policy rows untouched), `refit` (the elites by zimrnum's `argsort`, weights e^(temperature (score -
     best)), the weighted mean and deviation, spread clamped; non-finite scores count 0), `choose` (a drawn elite, the
     best, or the mean; optional exploration jitter), `plan` (the whole loop over a `LatentPlanScorer`). Known answers:
     convergence to a planted optimum (worst simulated error 0.016 over 200 seeds, tested at 0.06) with spreads at
     their floor; policy candidates only returns the best of them exactly and sampling writes nothing; the refit by
     hand; the warm start's shift; samples in [-1, 1], reproducible, different per iteration; `plan` = its steps, bit
     for bit. Negative control: inverted weights fail the hand refit - and ONLY it: elite selection alone converges,
     so the weighting is pinned by the exact computation. Tutorial 18d.8. N4 COMPLETE.
  4. **N5 - `SequenceReplay`** (per-environment rings, masks, write-back). FIRST HALF DONE Sep 30: built on
     `ReplayBuffer` (one ring per environment - the ring is ReplayBuffer's idea, which gained chronological access:
     `slotOf`, `row` in place, and a `deinit`); `push(rows, active)` writes one step of every environment, an
     inactive one nothing; `sample` draws windows as (environment, start) - the environment uniform among those with
     enough steps, the start uniform in its ring - copied STEP-MAJOR (rows t * windows + w, LatentRollout's layout),
     with `finished` 0 up to and including the window's first done and 1 after. Known answers: every window is
     consecutive steps of one environment, including one crossing the ring's physical wrap; `finished` by hand for
     every drawn window. Negative control: marking the done step itself finished fails exactly the finished test.
     Tutorial 18d.9. SECOND HALF DONE Sep 30: `sample` also reports each window's `WindowOrigin` (its environment
     and the PHYSICAL slot of its first step - still valid after later pushes, until overwritten); `writeBack(origins,
     first_step, step_count, first_column, values_in)` copies step-major values into those windows' rows in place
     (reanalyze: a prefix of the origins, first_step 1); empty targets are N(0, 1), written by the caller at push.
     Known answers: after a write-back both rings equal a hand-applied copy EXACTLY, and every unwritten row still
     reads N(0, 1); a frame an environment sits out leaves its ring byte-identical (storage, head, length).
     Negative controls: ignoring first_step fails exactly the write-back test; ignoring the active mask fails
     exactly the inactive one. Tutorial 18d.9 ("Targets that improve"). N5 COMPLETE.
  5. **The ensemble blocks**: members as arrays (mean, variance of the mean) and R3's KL-robust aggregation (R3.7's
     answers; its gradient as tilted weights). DONE Sep 30. Members as arrays needed NOTHING new: an ensemble is an
     array of members (an array of Params), and `meanAxis` / `varianceAxis` over the member axis give eq. 3's mean
     and, divided by the count, eq. 4's variance of the mean (the caller picks ddof). The new block is
     `klRobustExpectation(T, values, delta, tilted_weights_out)` - plain arrays in, one value out: the derivative of
     the KL dual is KL(tilted weights || uniform) - delta, so beta* is the temperature whose tilt sits EXACTLY delta
     from uniform (bisected on a log scale - KL falls monotonically in beta), and the value is the tilted average;
     delta 0 -> the mean, delta >= log(N / k) -> exactly the minimum (k tied lowest). Known answers: the limits
     (exact); the value SANDWICHED - no feasible reweighting (mixtures of uniform with one- and two-value spikes)
     averages lower, and the dual objective computed from its formula never goes higher and meets it at its best
     beta (1e-6) - while the weights sit delta from uniform (1e-9) and order inversely to the values; small delta:
     (mean - robust) / (sqrt(2 delta) std) = 1 +- 0.005 at 1e-4; central differences = the tilted weights (1e-6).
     Negative control: the bisection walking the wrong way fails exactly tests 2-4 (the limits never search).
     Tutorial 18d.10 "Pessimism with a dial".
  6. **TD4's blocks (T5, T6)**: the categorical twin critic's pieces; the deterministic actor family's (pre-activation
     penalty, target smoothing, policy delay, decaying exploration noise).
  7. **V1's block**: a differentiable observation SELECTION on the graph (asymmetric observation); **V2b's**: a DAgger
     buffer (the student's states, the teacher's labels). DONE Sep 30. V1: `gatherColumns` - plain (the one the game
     calls; every column checked before any write) and `Graph.gatherColumns`, a product with a constant 0/1 selection
     matrix built from the existing `oneHotRows`, transposed - no new op, exact (equal as numbers; a negative zero comes
     back as zero), its gradient matmul's own. Known answers: every column in order gives back the input; graph =
     plain under a reordering with a repeat and a column left out; checkGradient, exactly zero for the unchosen, and a
     column chosen twice gets twice one output's hand gradient. Negative control: the plain gather reading the next
     column fails exactly the plain and parity tests. V2b needs NO new zimrnum code: a DAgger buffer is a
     `ReplayBuffer` whose rows are the student's state followed by the teacher's action; the teacher, and the row test
     (labels = the teacher's actions at the student's own states), belong to the robot assembly (V2), where a teacher
     exists. Tutorial 18d.11.
  8. **Then the assemblies**: BMPC (N6), EfficientTDMPC's options (N7), TD4 (T7), SuperTrack's V1 / V3 variants, the
     mixes (I4) - and the measurements (V5, N8's ladder, the multi-clip benchmark) when choosing between them.
  9. **The kit** (Stage G, N9, T8, V4c) for whatever is adopted.
  Stages C-F keep their designs and are revisited when a question they answer comes up; I2 (DroQ / CrossQ) is an
  assembly of blocks already here and waits for 8.

### Stage A - finish the action path (CPU)

**A1 The policy sees what it is applying** (v3's F6b). **DONE Sep 27** (section 4, journal).
- WHY: with the filter, what to ask depends on what is already being applied; DReCon's observation carries it.
  Without it the policy is blind to half of its own control state.
- DESIGN: `LearnerOptions.sees_applied` (default false). The policy's first layer gains a block `W_applied` (actions x
  hidden); its input is the action being applied BEFORE the decision - the slot's value in `decideInto` (rest at an
  episode's start), the `applied` Var entering the decision in the graph, the filter state in `modelLoss` and
  `diagnose`. The CPU parameter layout grows only when the option is on, so the kit's parity at defaults is untouched.
- KNOWN ANSWERS: with `W_applied` zero, outputs are bit-identical to the policy without it; the graph-vs-rows parity
  (F6a's test) with the option on; the judge's actor feeds the slot's value (a unit check with a planted slot).
- DONE WHEN: robot_latent green, both parities. SIZE: 1.

**A2 The recipe as one value.** **DONE Sep 27** - as a `SuperTrackRecipe` (scale + learner options; section 4).
Planned as `robot_geno.supertrack_recipe: robot_latent.LearnerOptions` (normalise from clips,
decide every 2, filter 0.2, sees applied, `supertrack_action_scale`, sigma) - the bench, the pages and the night
read it; a test checks each field against the plan's intent. SIZE: with A1.

### Stage B - the bench (from v3's F10, moved to the front: every later choice is a learning-curve question)

**B1 `zig build st-bench`** - a deterministic CPU SuperTrack run on `dance_5_15` with the recipe. **BUILT Sep 27**
(`src/robot_st_bench.zig`, rooted in `src/` - a `tools/` root cannot reach the robot files; installed to
`tools/zig-out/bin/st_bench`; its known answers pass - journal). **10-minute run DONE Sep 28** (journal; CSV and curve
in `src/notes/bench/`): MTTF falls from the untrained 1.52 s to ~0.56 s and stays; trust 3.1 -> 0.23 (the world model
learns); exploitation ~100 (the policy exploits it). Reviewed:
refuses what the learner refuses (`LearnerOptions.problem`); looks do not touch training. Two builds (Simon, option
C): `st_bench` ReleaseFast for long runs, `st_bench_safe` to clear a configuration's first stretch, `--compare` to hold
them together; an error-level log is fatal in both.
- DESIGN: a small host tool (`tools/st_bench.zig`) over the CPU learner: 8 characters, a replay of >= 30 s in total,
  batch and windows at CPU sizes (hidden 64-128, batch 32-64); each iteration collects a few steps, then one world
  step and one policy step (SuperTrack's rhythm). At iteration 0 and every M iterations: the judge (20 starts) and
  `diagnose` (trust, exploitation) -> one CSV row (iteration, wall seconds, samples, world loss, policy loss, MTTF,
  share to the end, reward, trust, exploitation). Options: minutes, seed, recipe overrides (for A/Bs), output path.
- KNOWN ANSWERS: the same seed gives the same CSV (wall time aside); iteration 0's judge row is the untrained policy's
  (near the servo's, since the policy starts near zero); the iteration rate is reported.
- DONE WHEN: a 10-minute run writes its CSV and the curve is shown. SIZE: 1-2.

**B2 The baseline curve** - DROPPED by the 5-minute rule (Sep 28): B1's 10-minute rows ARE the baseline (a build
with every new knob off reproduces them exactly). Its stop rule, read on B1: MTTF does not rise, the world half
learns, the policy exploits the model - so the work turns to the ingredients (Stage I). The first learning
signal on this dance: does MTTF rise above 1.53 s? Every later A/B is against this curve. If it does not rise at
all: stop, and read trust and exploitation to learn which half fails, before touching the recipe. SIZE: 1.

**B3 The bench's resolution** (Sep 28, from I1b's seeds) - DEFERRED (Simon, Sep 28: "avoid getting stuck with
benchmarks" - the ingredients first; I1b stays built and off, its verdict waits for B3). The effects being tested are
~0.1 s of MTTF; the
seed-to-seed spread of one configuration is ~0.5 s; the judge sees 20 starts. So a verdict needs (a) a summary over the
run, not one look - the mean of the looks, or the area under the MTTF curve; (b) several seeds per arm, each within the
5-minute rule (three 3-minute seeds = one arm); (c) the judge's own noise measured: the same policy judged from two
different sets of 20 starts. DONE WHEN the bench reports a run's summary and a tool compares arms over seeds with
their spread. SIZE: 1.

### Stage I - the ingredients, then the mixes (Simon, Sep 28: "work on the ingredients so we can then mix them")

Each ingredient built on its own, OFF by default, with its known answers, and measured on a <= 5-minute bench arm
against B1's rows; mixed only once each is understood alone. In order, foundations first:

**I1 Noise on the world model's predictions** - built, measured HARMFUL at 0.2 (exploitation ~290 vs ~135, MTTF 0.32
vs 0.53 s over iterations 300-600: every knock is an error the policy is scored on, and the cheapest fix is a harder
correction - what the model believes and the body cannot deliver), and REMOVED (Simon, Sep 28). The data stays in
`src/notes/bench/`, the story in the journal; the lesson is L14.

**I1b Two world models and their disagreement** (Simon, Sep 28) - GENERALISED by R3.8's V3 (a KL-robust soft maximum
of the policy's cost over K models; delta = 0 is this arm's average without the price), and its "NEXT: seed 3" is
superseded by the order in 6.0. Train a SECOND world model on the same data from a
different initialisation; the policy's rollouts step through their AVERAGE, and pay `w_disagree` times the squared
distance between the two predictions at every step. Why it can work where I1's uniform noise failed: where data pins
the models down they agree; where the policy wanders off the data nothing does, so they diverge - disagreement marks
exactly where the model cannot be trusted, which is where the policy exploits it (MOPO's pessimism, from two models).
The penalty's gradient steers the policy back toward states the models agree on, and knocks nothing it knows well.
KNOWN ANSWERS: one model = today's learner exactly (B1's rows); with two, graph-vs-rows parity (the average and the
penalty, row by row); two models from the SAME initialisation have zero disagreement to the bit. Bench: an arm at 4
minutes against B1. Cost: a second world step per iteration and a second model inside every rollout. **BUILT and
first measured Sep 28** (`twin_world`, `w_disagree`, `twin_seed`; `Learner.trainWorld`, `modelStepRow`; bench
`--twin-world`, `--w-disagree`): parity with and without every other ingredient, a same-seed twin changes the loss
not by a bit, a twin stepped but never averaged is caught; twin off reproduces B1. **At w_disagree 1 (4 min, 436
iterations at 1.9 it/s): PROMISING** - exploitation lower at every look (48 / -62 / 86 / 94 vs 299 / 78 / 131 / 136),
tracking reward up to 45% higher by iteration 400 (0.226 vs 0.155), MTTF modestly better at three of four looks - and
better at equal WALL time despite the cost. Not yet adopted (one seed; MTTF still far under the untrained 1.52 s).
**Prices 3 and 10 (Sep 28): not a dose curve** - w 10 beats the
baseline like w 1 (reward 0.215-0.230, exploitation ~95, the best MTTF of any arm: 0.80 at iteration 300, 0.69 at
392), while w 3 between them COLLAPSED (MTTF 0.28-0.36, exploitation up to 1,796). A collapse bracketed by two
working arms reads as run-to-run variance on one seed, not a dose effect - the rule: a second seed before any
adoption. **Seed 2 (Sep 28, 3-minute arms): unresolved.** Seed 2's
own baseline sits 0.46 s above seed 1's (mean MTTF over looks 100-300: 1.08 vs 0.62) while the prices move the
two-seed mean by at most 0.06 s (base 0.85, w 1 0.91, w 3 0.86, w 10 0.83); each price wins one seed and loses or ties
the other (w 3: the collapse on seed 1, the best arm on seed 2 - 1.37 s at its last look). The one pattern both seeds
share: in EVERY arm MTTF drifts down as training goes on. NEXT: seed 3 (same four arms), then decide with three seeds
- and B3 below, because one run cannot resolve effects this size.

**I2 DroQ and CrossQ critics** (journal 7's S3, never built): `SacAgent` gains the critic variants its parts already
support - DroQ (dropout + layer norm, the minimum over M masks of ONE critic, many updates per step) and CrossQ
(batch norm, no target networks, current and next batches through the critic together). KNOWN ANSWERS: the masks'
minimum on planted numbers; CrossQ's batch statistics taken over the joint batch; each variant on the cartpole gate
inside 5 minutes against plain SAC.

**I3 SAC on the tracking task.** Step one BUILT Sep 28: `robot_track_env.TrackEnv`, the tracking task as a
DECISION-level environment - observe; `decide` clamps, holds for `decimation` steps, credits the reward up to the first
end, classifies the end (`.none` / `.stop` lost / `.cut` out of time) and, for a cut, reads the terminal observation
before the controller forgets the filter. One definition for every learner: PPO, SAC, the mixes. KNOWN ANSWER: held
decision for decision against PPO's own `collectOne` on twin fleets - observations, credited rewards, ends, and every
cut's bootstrap (PPO's critic on TrackEnv's terminal observation) identical; a planted cap-as-stop fails it. **PPO moved
onto it Sep 28**: its copy of
the logic deleted, `EndKind` / `ClipEnd` now the env's (PPO re-exports them); a fingerprint of two PPO iterations
(every learning array hashed, the weights after each update) identical before and after - only the reported mean
reward's 7th digit moved, the batch's reward sum now added per character (stats only). Both pages that reach the
trainer's fleet (`geno_ppo`, `getup_train`) updated and smoked in release; PPO's test root 509 pass, 75 skip. **SAC on
the dance BUILT Sep 28** (`src/robot_sac_track.zig`, `SacTrack`): each fleet decision, SAC draws, `TrackEnv` decides,
every transition goes into SAC's replay - next = the next decision's observation, or on a cut the terminal capture
with done FALSE; done TRUE only on a stop - then `updates_per_decision` updates (the UTD knob DroQ turns up). KNOWN
ANSWERS: every replay row held field by field against a twin env driven by the recorded actions (cuts and stops both
exercised); a planted cut-as-termination fails it; a learning smoke - updates run, the actor moves, the critic's loss
stays finite. No observation normaliser yet (raw DReCon observations: a running normaliser and a replay need a
decision of their own). NEXT: the shared actor - SuperTrack's policy and SAC's the same network (inputs, outputs,
weights), so a mix can hand one policy between them; then I2's critics (DroQ, CrossQ) on this SAC.

**I4 The mixes** (after I1-I3): SAC to start (sample-efficient early), then SuperTrack; SuperTrack's loss and SAC's
critic gradient on ONE actor; PPO (`robot_ppo_track`) beside them. Each mix a bench arm against its parts.

**I5 TD4 - Twin Delayed D4PG** (Simon, Sep 28: "study this rl setup, in particular td4 ... we really want all
ingredients available"). Source: roxie, a JAX framework (seven agents, MuJoCo) - `roxie/agents/td4.py`,
`losses/critic_losses.py` (`td4_critic_loss_fn`, `wasserstein_blend_logits`, `_smoothed_target_actions`),
`losses/actor_losses.py` (`td4_actor_loss_fn`, `pre_activation_penalty`), `agents/utils.py` (`repack_samples`),
`utils/math.py` (obs statistics), `configs/agent/td4.yaml`, `experiments/dmc/agent/td4_bench.yaml`; paper arXiv
2505.22642. WHAT IT IS - TD3's machinery with D4PG's categorical critics:
  - a DETERMINISTIC actor, tanh-squashed, layer norm, 256 x 256; exploration = Gaussian action noise 0.4 decaying
    linearly to 0.1 over 40% of the budget;
  - TWIN CATEGORICAL critics: MLP (ReLU, layer norm - "a strong stabilizer against value divergence") -> logits over
    a fixed support (C51); Q = softmax . atoms. Their benchmark: 101 atoms on [-5, 120] (rewards in [0, 1] at gamma
    0.99 bound the return near 100 - true of our tracking reward too);
  - target actor and target critics, polyak tau 0.005; target smoothing: N(0, 0.2) clipped to +-0.5, then to [-1, 1];
  - the target DISTRIBUTION from the twin with the LOWER mean, per sample (`twin_q_weight` 1.0 = the min; below 1 it
    is blended with the other twin along their QUANTILE functions - a Wasserstein interpolation, reprojected - because
    mixing densities would add a second mode and smear the support over backups);
  - loss per twin: categorical TD - the target shifted to r + discount * z, projected onto the support, cross-entropy
    against the online logits (`rlax.categorical_td_learning`);
  - actor loss: -mean of the FIRST critic's Q, + an optional one-sided pre-tanh penalty sum relu(|u| - 1)^2 (off in
    their benchmark); actor and both targets updated every 2 critic steps (policy delay);
  - 5-STEP returns: the return sums gamma^k r up to the window's first end; a termination ends it with no bootstrap,
    a truncation bootstraps from the observation there at gamma^k, a surviving window from step n at gamma^n - each
    sample carries its own discount;
  - observations normalised at SAMPLE time (running sums, clip 5), replay rows RAW - stored rows never go stale;
  - Adam 3e-4 both, GLOBAL grad-norm clip 1; batch 512, replay 500k, warm-up 30k; 1024 envs at 20 updates per 2048
    env steps (massively parallel, LOW update-to-data - ours today is 8 envs on one core, the high-UTD end).
  Their result: HumanoidWalk 989 from the released checkpoint; in their 500M-step grid the categorical critics (TD4,
  D4PG) lead on CPU physics - and TD4 scored 38 on HumanoidStand on GPU physics: strong, not uniformly robust.
HAVE (tested): graph ops relu, tanh, softmaxRows, layerNormRows, min, log, matmul, concat, dropout, mseLoss; Adam
(`gym.AdamSet`); `polyakUpdate`; `clipGradNorm` (global, direction-preserving); `ObsNormalizer` (f64 Welford - roxie
keeps f32 sums); `ReplayBuffer`; `OrnsteinUhlenbeck`; twin critics with a pessimistic target (`SacAgent`); `TrackEnv`
with termination (`.stop`) vs truncation (`.cut` + its terminal observation) - exactly what n-step returns need;
`SacTrack`'s replay mapping.
MISSING - built in this order, each with its known answer:
  - **T1 n-step transitions.** DONE Sep 28. The replay row's last column is the bootstrap DISCOUNT (CPU `SacAgent`:
    `remember` stores gamma(1 - done), `rememberDiscounted` takes one; the kit's `sac_target`; SAC fingerprinted
    bit-identical, the kit still equal to the CPU agent update for update). `TrackEnv.NStep`: a ring of n pending
    decisions per environment - a full window emits its oldest at gamma^n; a cut emits every pending one at gamma^k
    with the terminal observation; a stop emits them all at zero; returns summed newest-first, so n = 1 is the one-step
    row untouched. `SacTrack.Options.n_step` routes every transition through it. KNOWN ANSWERS: planted rewards at gamma
    0.5 against the closed form (full windows, a cut, a stop, a cut on an episode's first decision); n = 1 equal to the
    one-step rows bit for bit; an off-by-one in a cut's discount caught by both; SacTrack's row test unchanged at n = 1
    through NStep; SAC learns at n = 1 and n = 5.
  - **T2 Sample-time normalisation.** DONE Sep 28: `SacOptions.normalize_observations` (off by default - the agent
    exactly as before), clip 5; training actions feed an f64 `ObsNormalizer`, evaluations only read it; `sampleBatch`
    normalises each batch's copy. Known answers: stored rows are the RAW inputs (planted storage-time normalising
    fails it); sampled rows equal their originals normalised by hand; later statistics change batches, never rows; an
    evaluation acts on the hand-normalised observation without feeding the statistics; SAC learns with it at n = 5.
    The design as first planned: Raw rows; `ObsNormalizer` fed from acting; every sampled batch's observations
    and next observations normalised (clip 5) with the statistics of that moment - which also settles SacTrack's open
    question. KNOWN ANSWER: the batch equals the rows normalised by hand with the same statistics; later statistics
    change batches, never stored rows.
  - **T3 The categorical projection** - DONE Sep 28: `zimrnum.categoricalProject(T, v_min, v_max, probs, reward,
    discount, out)`, each moved atom split between its two neighbours by closeness (the upper is always the next atom,
    so an exact landing keeps its mass - the textbook floor/ceil version loses it, and the planted version fails the
    point-mass and clamping tests). Six known answers pass. The plan as first written: (C51; rlax
    `categorical_l2_project`): a distribution on the shifted support r +
    discount * z, projected back onto the fixed atoms - a pure function. KNOWN ANSWERS: mass conserved; a point mass on
    an atom stays; one between two atoms splits in proportion to distance; beyond the support it clamps to the ends;
    discount 0 gives a point mass at r.
  - **T4 Soft cross-entropy on the graph** - DONE Sep 28: `Graph.softCrossEntropy(logits, targets)`, the target as
    DATA like `mseLoss` (no gradient into it). Graph known answers: its value is the row function's, `checkGradient`
    passes; composed through a layer, under a scale of 3, and after its target is refilled and recomputed; a backward
    that ignores the incoming gradient fails exactly the composition test. First half: the math as plain row functions,
    `zimrnum.softCrossEntropyRows` / `softCrossEntropyRowsGrad` (+ `rowLogSumExp`) - known answers: one-hot targets
    give the hard-label loss and gradient exactly; at prediction = target the gradient is zero and the loss the
    target's entropy; the gradient matches central differences; a dropped division by rows fails two of them. LEFT:
    the graph op (builder, backward, recompute) with `checkGradient`. The plan as first written: a primitive
    `softCrossEntropy(logits, target_probs)` with its own
    backward ((softmax - target) / rows), stable where `log(softmaxRows)` is not. KNOWN ANSWERS: `checkGradient`; equal
    to `crossEntropy` on one-hot targets.
  - **T5 The categorical twin critic.** Its network (ReLU, layer norm, logits over the atoms), Q as the categorical
    mean, the target from the lower-mean twin per row, and the quantile blend + reprojection for weight < 1. KNOWN
    ANSWERS: weight 1 = the lower twin exactly, weight 0 = the upper; a distribution blended with itself is itself; the
    blend's mean lies between the two; the critic loss on planted logits against a hand computation. DONE Sep 30, as
    `CategoricalScalar` methods (it owns the grid; `.identity` = C51 / TD4 return atoms): Q = `decode` (existing);
    `quantileBlend` - one walk up both CDFs, each slice of probability placed at the blended bin INDEX (bins evenly
    spaced on the axis) and landed by the shared `addPointMassToGrid`; `twinTarget` / `twinTargetRows` - the lower-
    mean twin per row (a tie: the first), blended by the weight. The network is the existing layers (N2). Known
    answers, sharper than planned: the blend's mean EXACTLY the weighted mean (1e-12); two point masses blend into ONE
    point mass between them; the critic loss (categoricalProject then softCrossEntropyRows) = the hand computation.
    Negative controls: the weight on the wrong twin fails exactly the mean and point-mass tests; the higher twin chosen
    fails exactly the two selection tests. Tutorial 18d.3 ("Twin critics, kept distributions").
  - **T6 The deterministic TD3-family actor.** A tanh MLP (layer norm) that also returns its pre-activation; the
    actor loss -mean Q1 + coef * (relu(u - 1)^2 + relu(-u - 1)^2) (no abs on the tape); a target actor (polyak);
    target smoothing; policy delay; Gaussian exploration on a linear schedule. KNOWN ANSWERS: the penalty is zero
    inside +-1 and its gradient matches finite differences; the delay counts updates; the schedule's end points.
    DONE Sep 30. The actor is the existing layers (tanh, layer norm; the pre-activation is the Dense output before
    `tanh`), the target actor `polyakUpdate`. New: `Graph.preActivationPenalty` (composed of existing ops - a row of
    -1s broadcast by add, two relus, squaredRowNorm, the mean over rows - no abs on the tape); `linearSchedule` (from
    the step alone, both ends exact); `policyUpdateDue` (after every delay-th critic update; 0 refused);
    `addGaussianActionNoise` - ONE function for exploration (no clip: infinity) and target smoothing (std 0.2, clip
    0.5), its counter draw_index * len + i so wide batches never repeat noise. Known answers: the penalty's value by
    hand (2.125) and checkGradient (1e-7), zero value AND gradient inside the band; the delay's 33 actor updates in
    100 at delay 3; the schedule's exact ends, midpoint, flat tail, refusals; the noise clipped, kept in [-1, 1],
    reproducible, zero std = no change, and unclipped its measured std (5%). Negative controls (one scratch copy):
    the penalty's lower side dropped, the delay off by one, the slope over the whole run - each fails exactly its
    own test; the noise tests pass. Tutorial 16.12 "A deterministic actor".
  - **T7 The TD4 agent**, assembled on the CPU graph like `SacAgent`: first on the cartpole gate (inside 5 minutes),
    then on `TrackEnv` beside SacTrack, reading the same n-step rows. The byproducts come nearly free - TD3 (T6 with
    scalar twin critics), D4PG (T3-T5 with one critic, no smoothing), DDPG - so roxie's comparison grid can be ours.
  - **T8 GPU parity** (Stage G): the categorical critic, the projection and the soft cross-entropy as kit kernels,
    checked against the CPU graph - the route to roxie's regime of many environments.

### Stage C - the recipe, decided on the bench

Each an A/B against B2 (same seed; a second seed when the two disagree); adopted only on a clear judge win with
exploitation bounded; the curves recorded in the journal.

**C1 Offset scale and noise** (v3 F4c): 0.6 vs 2.09 rad a unit (the paper's 120 deg), sigma 0.1 of a unit, with
the filter on (which already divides a single decision's reach by five). SIZE: 1.

**C2 The policy's loss as the paper's** (v3 F4b, policy half): L1 per GROUP in LOCAL raw space - positions,
velocities, two-axis rotations, angular velocities, heights, up - with weights that make each group contribute
equally at the start (measured on the first 100 batches, then frozen); the offset penalties L2^2 + L1 at 1/100 of
the tracking terms. Needs: an L1 graph op (gradient sign(y - t) / n), the `track.local` layout as named group
slices, de-normalisation in the graph (scale and shift). KNOWN ANSWERS: the op's gradient by finite differences;
the slices cover the feature vector exactly once; a perfect rollout's loss is 0; graph-vs-rows parity. SIZE: 2.

**C3 The optimiser** (v3 F4d): gradient-norm clipping (25 world, 100 policy), a linear warm-up over the first 2% and
a polynomial decay (power 0.9) to 10% for long runs, the policy rate 1e-4 vs 3e-4. KNOWN ANSWERS: a small gradient
passes untouched, a large one lands exactly on the norm; the schedule's value at 0, at the warm-up's end, at the
end. SIZE: 1.

### Stage D - the world model's form (v3 F9, with F4b's world half)

**D1 Rigid-body ops in the graph** - quaternion product, exp map (rotation vector to quaternion), rotating a vector,
conjugate, the two-axis encoding - each with a finite-difference gradient check. SIZE: 1-2.

**D2 `AccelWorld`** - the paper's model: the same inputs as the latent model; per-body LOCAL linear and angular
accelerations out; to world by the root's rotation; semi-implicit integration (velocity first, position with the new
velocity, rotation exp(dt/2 w) (x) q); `local` recomputed for the next input; the loss L1 in WORLD space (position,
velocity, rotation log-difference, angular velocity) with equal starting contributions. KNOWN ANSWERS: a zero network
rolls out CONSTANT VELOCITY exactly; a network that outputs the TRUE accelerations of a recording reproduces the
recording to float precision over 8 steps; gradients by finite differences; graph-vs-rows parity. SIZE: 2.

**D3 The A/B** - latent vs acceleration on the bench at equal compute, with F2's trust on held-out windows as the
second axis. Keep the winner. SIZE: 1.

### Stage E - scale and drift (v3 F8, F7)

**E1 Windows and scale** - world 8 / policy 32 (16 decisions at 30 Hz); batch and replay as large as the bench
sustains; widths 64-256 on the CPU (the night's come from the desktop probe, ON-a). Measured on the bench.
**E2 Drift** - the policy's input gains the reference root's place and heading from the character; the loss prices
the root's world offset (the paper's rough-terrain variant). KNOWN ANSWER: the input does not move with the character
(DReCon's observation test, twinned). SIZE: 1 each.

### Stage F - the feasible reference (v3 F5), beside the rest

**F5.1** The clip's second channel (servo targets beside the achieved poses) and the fleet reading it - KNOWN ANSWER:
a clip whose target channel equals its pose channel runs bit-identically to today. **F5.2** The offline search on
`dance_5_15` (SAMCON's: short windows, many samples, a beam, backtracking, a stricter shape cost) - KNOWN ANSWERS: the
bake reads back identical; from every judge start the servo alone reaches the end with zero error; fidelity to the
mocap reported and gated. **F5.3** The bench A/B: the original clip vs the feasible one. SIZE: 1 + 2-3 + 1.

### Stage G - the kit catches up (GPU parity for each adopted piece, in adoption order)

The clock (decisions every 2 steps in the rollout kernels), the filter (in-kernel blend and its gradient),
`sees_applied` (the policy layout), the losses, the optimiser, the world model's form. Each: CPU-vs-kit parity at
small sizes with the existing harness, then `geno_train` on the recipe. SIZE: 1 per piece, more for the form.

### Stage H - the gate (v3 F10)

A 30-minute bench run with the chosen recipe: MTTF >= 3 s (2x the servo) and still rising, trust under 1,
exploitation bounded. Pass: Phase R. Fail: the curve says which stage to reopen.

### After the gate (designs in the archived v3 §5)

- **From R4 (Oct 1), for later:** RAY-TOLD's hybrid - an NPC planning with EXACT short rollouts (kinematics, or zimr's
  physics) plus a learned terminal value, in our scorer-agnostic Mppi, with RAYCASTS as its observation (a game-cheap
  V1 view); IQL-TD-MPC's manager of latent subgoals above the tracker, for layered behaviours (where to go, which
  clip). Newt's open-loop rollout length as a world-model diagnostic belongs with V5's measurements.

- **Phase R - runs** (Simon's workflow): `RunConfig` + a compatibility hash; the snapshot zip (`run.json`,
  `state.bin`, `curves.csv`, `events.log`) with a continuation known answer (N + restore + M == N + M); a zip
  writer/reader; the OPFS store (decided), Screen Wake Lock, visibility events; Train (headless) / Test / Pause with
  the judge as a curve; the UI; a 30-minute rehearsal. Open: U2-U6.
- **Phase ON - the first night**: `geno_night` from geno_train on the recipe; the start-up probe picks widths and
  batches (>= 5 iterations/s, >= 1,000 samples/s); checkpoints every 10 min with NaN self-healing; curves every
  minute; Simon's rehearsal; the night; the morning protocol.
- **Phase C - curriculum**: adaptive starts (T5), the get-up with the height term's weight checked on both motions,
  perturbation ramps, more clips.
- **Phase P - PPO hygiene** for an A/B page: advantage clip, action-bound loss, normaliser freeze, diagnostics,
  measured choices.
- **Phase A** - ADD (a learned reward from the difference), the 100-clip library, D5 revisited only on a plateau.
- **Phase X** (the phone) and **Phase M** (motion matching) - later.

---

## 7. Decisions

**Made** (reasons in the journal): SuperTrack is the night's learner, PPO the A/B; offsets from the reference;
SuperTrack's failure rule (F3b); zero-velocity servo (F3); 60 Hz physics and a 30 Hz policy (Simon); Simon's
filter inside training (F6a); the normaliser from the clips (F4a); the event limits (worst body, contact) kept as
mechanism, off; the bench before any recipe change (v4).

**Open, and where each is decided:** the offset scale and noise (C1); the losses (C2); the optimiser (C3); the world
model's form (D3); windows and widths (E1, then the probe); drift (E2); the feasible reference (F5.3); PPO's
choices (Phase P); ADD (A1); 60 vs 120 Hz for contact-rich clips (after the first night, if contact quality is what
the morning shows).

---

## 8. Risks, ranked (with the mitigation)

1. **The CPU bench is too slow to show learning in 30 minutes.** Smaller widths and batches; fewer characters;
   profile an iteration first (B1 reports the rate); if still too slow, Stage G's clock and filter earlier, and the
   bench on the kit.
2. **SuperTrack exploits its world model.** Trust and the exploitation index on every bench row; the filter; noise
   in the paper's units; the gate requires exploitation bounded.
3. **The recipe choices interact** (scale x loss x form). One change at a time against B2, then the winners together
   re-checked once before the gate.
4. **The page crashes or stalls unattended.** Phase R's checkpoints and resume, NaN self-healing, the rehearsal.
5. **Drift ends episodes** - the root limits; E2.
6. **The night learns the dance but a later night not the get-up** - Phase C's adaptive starts and the height term.

---

## 9. Where things live

- `src/robot_track.zig` - the task (`Task`, `Gains`, `TrackingError`, `trackingError` / `trackingErrorWithHead`,
  `Termination`, `reward`, `headBody`, `contactExemptMask`, `filterAction`, `referenceVelocity`), the `Fleet`
  (`startAt`, `driveOnce`, replay), the judge (`judge`, `Judging`, `Actor`, `evenStarts`, `judgeOptions`), `local`.
- `src/robot_latent.zig` - the CPU SuperTrack: `LatentWorld`, `Learner` (`decideInto`, `appliedBefore`, `decides`,
  `diagnose`, `modelLoss`, `judgeActor`), `Normalizer`, `measureNormalizer` / `measureClipNormalizer`.
- `src/robot_latent_kit.zig`, `src/robot_track_resident.zig` - the GPU SuperTrack; `examples/geno_train`.
- `src/robot_geno.zig` - Geno: `tracking_task`, `supertrack_recipe` (`SuperTrackRecipe`), `servo_task`,
  `task_termination`, `task_weights`, `ServoRun`,
  `Planner` (the teacher), `FailureCheck`, `GenoTask` / `Motion`, the T/F measurements.
- `src/robot_policy.zig` (DReCon: `Controller`, `observe`), `src/robot_ppo_track.zig` (PPO), `src/robot_gym.zig`.
- `src/robot_track_env.zig` - `TrackEnv` (the task decision by decision, every learner's one definition), `NStep`;
  `src/robot_sac_track.zig` - `SacTrack` (SAC on the dance); `src/robot_gym.zig` - `SacAgent` (discount rows,
  sample-time normalisation). In `src/zimrnum.zig`: `Params`, `Graph.detach` / `simNorm` / `klGaussianDiag` /
  `softCrossEntropy`, `categoricalProject`.
- `src/notes/bench/r3_kl_robust_check.py` - R3.7's numerical check of the KL-robust value (Python, outside zimr).
- Notes: this plan; `rl_track_journal.md`; `supertrack_comparison.md`; `claude.md`; `archive/rl_track_plan_v1-3.md`.
- Tutorial: `src/notes/tutorials/robot-mocap-tutorial.html` (sections 10-12).

## 10. Recent advancements - reproduce, then carry to the dance

(Simon, Sep 28: "a large new section dedicated to recent advancements ... add to the plan everything necessary to be
able to reproduce this".) Each entry: the claim, the method in full, what is missing in zimr in build order with a
known answer per piece, the open questions, and how it carries to our tracking task. The rule for a reproduction:
FIRST the paper's own setting and ablation direction (did each rung help, as theirs did?), only THEN our task. Tags:
[paper] = stated in the paper; [base, verify] = a detail of TD-MPC2 / BMPC that the paper only references - taken from
those works, to be confirmed against BMPC's code (github.com/wertyuilife2/bmpc - reachable from the container) before
it is built.

### R1 EfficientTDMPC - Evers, Meo, Boehmer, Dauwels, Oren (arXiv 2605.16692v4, 17 Sep 2026)
(v5 of 28 Sep re-read Sep 30: the method and Table 2 agree with these notes - acting horizon 6 with the multi-horizon
mean, reanalyze horizon 3 terminal-only at the 64 / 8 / 3 budget, beta 10 only where episodes end early, spread
[0.05, 2], log std [-3, 1], entropy 1e-4, discount [0.95, 0.995], per-step insertion. New in v5: A.4 wall-clock parity
(47 vs 45 min per 100k decision steps - the cheap reanalyze pays for the ensemble); B.4 penalising acting as well does
not help; C.1 ensemble averaging cuts the planner's predicted exploitation of single heads. For N7: the multi-horizon
objective is the mean over h = 1 .. H of Q_h = sum_{u<h} gamma^u r_u + gamma^h V(z_h) - LatentPlanScorer must read
the value heads at EVERY depth, not only the last.)

**R1.0 The claim** [paper]. State of the art in sample efficiency on HumanoidBench (14 `h1hand` tasks - WITH hands -
1M env steps) and the DeepMind Control Suite (21 easy tasks at 200k, 7 hard at 1M): +27% AUC over the previous best
(Mrs. Q), +57% AUC over BMPC on their ladder tasks, at the same wall-clock as BMPC (47 +- 2 vs 45 +- 3 minutes per
100k decision steps, one A100). The idea in one line: the planner exploits errors in its return estimate, so make the
estimate harder to exploit - average it over rollout depths and over an ensemble of dynamics models, and during
reanalyze penalise its uncertainty. Their Appendix C.1 is the mechanism, measured: a planner maximising a single-head
estimate promises far more than the real simulator delivers (often LESS than the policy's own action); maximising the
ensemble average promises less and delivers more - our I1b finding (exploitation) in their terms.

**R1.1 The base: BMPC, exactly as its code does it** (read Sep 28 from `bmpc-main`: `bmpc/bmpc.py`,
`common/world_model.py`, `common/layers.py`, `common/math.py`, `common/scale.py`, `common/buffer.py`,
`trainer/online_trainer.py`, `config.yaml` - these supersede every "base, verify" tag this entry had).
  - **The vocabulary** (`layers.py`): `NormedLinear` = Linear, then dropout if any, then LayerNorm (with its own gain
    and bias), then an activation (Mish by default). `mlp(in, hidden, out, act)` = NormedLinear hidden layers
    (dropout only on the FIRST) and a last layer that is plain Linear - or a NormedLinear with `act` when one is
    given. `SimNorm` = view the features as groups of 8, softmax within each group, view back. `Ensemble` = N copies
    of one module with their parameters STACKED, evaluated with vmap.
  - **The networks** (`world_model.py`; latent 512, mlp 512, enc 256, bins 101 on [-10, 10]): encoder
    `mlp(obs, [256], 512, act=SimNorm)`; dynamics `mlp(z ++ a, [512, 512], 512, act=SimNorm)` (its last layer:
    Linear -> LayerNorm -> SimNorm); reward `mlp(z ++ a, [512, 512], 101)`; policy `mlp(z, [512, 512], 2 * |A|)`;
    values: an Ensemble of 2 `mlp(z, [512, 512], 101, dropout 0.01)` (state values - `use_v_instead_q`). The reward's
    and the values' LAST-layer weights start at ZERO; everything else TD-MPC2's `init.weight_init` (read before N6).
  - **Three views of the value heads**: live (trained), detached (the same tensors, no gradient - what the planner and
    targets read), target (a copy, `lerp`'d toward the detached each update at tau 0.01). `V(z, "avg")` / `"min"`
    read two RANDOMLY chosen heads (with 2 heads: both).
  - **The policy (BMPC mode)** - NOT SAC's squashed Gaussian: `mean, raw = pi(z)`; mean = tanh(mean);
    log_std = low + (high - low) * (tanh(raw) + 1) / 2 with [low, high] = [-3, 1], or the EXPLORATION bounds [-2, 1];
    sample = clamp(mean + eps * std, -1, 1). Its "scaled entropy" is -log_prob of the Gaussian (no squash term)
    rescaled by the action dimension.
  - **Categorical scalars** (`math.py`): `two_hot(x)` = symlog(x) clamped to [-10, 10], split between its floor bin and
    the next by the fractional offset (T3's point-mass projection exactly; the code's `(i + 1) % bins` wraps, harmless
    - that share is 0); `two_hot_inv(logits)` = softmax . bins, then symexp; `soft_ce(pred, x)` =
    -sum two_hot(x) * log_softmax(pred) (T4 exactly).
  - **The planner** (`_plan`), per call: z = encode(obs). Policy trajectories: 24 rollouts of the policy through the
    model (its EXPLORATION std during reanalyze). Mean = 0, std = 2; warm start: mean[:-1] = previous call's mean
    shifted by one (not at an episode's first step, never in reanalyze). Iterations 6, +2 when |A| >= 20 (the paper
    says > 20; the code >= 20). Each iteration: 488 samples = clamp(mean + std * N(0,1), -1, 1) after the 24 policy
    ones; value = sum_t gamma^t two_hot_inv(R(z_t, a_t)) + gamma^H V(z_H, "avg"), NaN -> 0; the 64 best are the
    elites; score = softmax(temperature * (elite value - best)); mean, std = the score-weighted mean and deviation of
    the elites; std clamped to [0.05, 2]. After: ONE elite drawn by Gumbel sampling on the scores. Returns the
    action = that elite's first action (+ std[0] * N(0,1) unless evaluating, clamped) and `action_dist` = (that
    elite's first action, std[0]) - THE POLICY'S TARGET. The mean is kept for the next warm start.
  - **The value target** (`_td_target_V`, no gradient, on the TRUE encodings of the sampled window's first H states):
    roll the POLICY `td_horizon = 1` step through the model - sum gamma^k two_hot_inv(R(z, pi(z))) - then add
    gamma^k V_target(z_end, "avg"). Model rewards, not the buffer's.
  - **The world-model update** (`_update`), on a window (obs_0..H, a_0..H-1, r_0..H-1): true_zs = encode(all obs)
    without gradient; z = encode(obs_0) WITH gradient; roll the buffer's actions: z_t+1 = next(z_t, a_t),
    consistency += MSE(z_t+1, true_zs[t+1]) * rho^t; reward += soft_ce(R(z_t, a_t), r_t) * rho^t; value +=
    soft_ce(V_j(z_t), target_t) * rho^t for EACH head j (z_t: the ROLLED-OUT latents, z_0 included). Then /H, /H,
    /(H * heads); total = 20 * consistency + 0.1 * reward + 0.1 * value; clip the global gradient norm at 20; one Adam
    step (encoder lr x 0.3). Then the policy update, then the target EMA.
  - **The policy update** (`update_pi`, on the rolled-out latents zs[0..H-1], DETACHED): kl = KL(pi_theta || target) -
    the POLICY first (mode-seeking; the paper writes the reverse) - averaged over action dimensions; divided by a
    running scale (`RunningScale`: an EMA at tau of the 95th minus 5th percentile of the batch's first-step KL,
    floored at 1); loss = mean over t of (kl - 1e-4 * scaled entropy) * rho^t; clip 20; its own Adam (eps 1e-5).
  - **Reanalyze** (every 10th update): the first 20 windows of THIS batch, all H of their states, re-planned (no warm
    start, horizon 3, exploration std for the policy trajectories); the fresh targets replace those in the batch AND
    are written back into the buffer (`index[1:]` - the row layout below).
  - **The buffer** (`buffer.py`, torchrl SliceSampler): windows of H + 1 consecutive steps from ONE episode; row t holds
    obs_t with the action that LED to it, its reward and the planner target from the step before (a leading row per
    episode has NaNs) - so a batch reads `action[1:]`, `reward[1:]`, `target[1:]`. Rows without a planner target
    (random warm-up) train toward N(0, 1). Episodes are added when they END.
    (Torch BMPC adds episodes when they END; ours inserts every step, as BMPC-jax and EfficientTDMPC do - "data
    freshness".)
  - **The schedule** (`online_trainer.py`): random actions for `seed_steps`; at that step, `seed_steps` updates in one
    burst (pretrain: no policy update, no reanalyze); then one update per env step. Discount:
    frac = episode_length / 5, gamma = clamp((frac - 1) / frac, 0.95, 0.995).
  - **Paper vs code** (the code is what produced the numbers): the KL's direction; ">= 20" action dimensions; the
    policy target is a DRAWN elite's first action with the final std, not the planner's mean; reanalyze's policy
    trajectories use the exploration std; the policy trains on rolled-out latents; the value target uses model rewards
    along a policy rollout; the running scale on the KL; the loss weights 20 / 0.1 / 0.1.
  - **Cost on our CPU**: planning at BMPC's size is roughly 6 iterations x 512 samples x 3 steps of 512-wide MLPs -
    on the order of 10 GFLOP per decision, about a second on one core. So: CPU at reduced widths (128) and samples
    first, for the known answers; full size on the kit (N9).

**R1.1c BMPC-jax - what a second implementation teaches** (read Sep 28 from `bmpc-jax-main`: `bmpc_jax/train.py`,
`bmpc.py`, `world_model.py`, `data/sequential_buffer.py`, `config.yaml`; "a performant Jax implementation", with the
BMPC author's help). Where it is FASTER:
  - **One planner call for every environment.** `num_envs` environments step together (4 by default) and `act`
    plans for all of them as one batch; the planner takes any leading batch shape, so the SAME compiled planner
    serves acting (envs) and reanalyze (H x b states). Bigger matrix products, one call's overhead.
  - **Reanalyze and the policy reuse the update's own work.** `update_world_model` returns the true encodings and the
    rolled-out latents it computed; reanalyze plans from those encodings (no re-encoding), the policy trains on those
    latents (no second rollout), and the policy update runs AFTER reanalyze, on the fresh targets.
  - **One encoder pass.** Observations and next observations are stacked and encoded in a single call; the targets
    are cut from it through a stop-gradient. (BMPC-torch encodes the window without gradient AND its first state again
    with gradient.)
  - **All the planner's noise drawn once** per call - (samples, iterations, horizon, action) - not per iteration.
  - **A ring per environment, transition rows, masks.** The buffer is [capacity, envs]; a row is a whole transition
    (obs, action, reward, next obs, terminated, truncated, the planner's mean and std); insertion is one masked write
    per step (per-step insertion - EfficientTDMPC's "data freshness" is already this); a window is (env, start),
    O(1), and may cross an episode's end - `finished` masks (done seen earlier in the window) remove the later steps
    from every loss. No episode index, no "the action that led here" offset.
  - **The update-to-data ratio as a knob**: `num_envs x utd_ratio` updates per loop step; at the warm-up's end, one
    burst of `seed_steps` updates (seed_steps = max(5T, 1000) x envs x utd).
Where it BEHAVES differently (each a choice to test, not a fact):
  - **Terminations.** An optional CONTINUE head (sigmoid; binary cross-entropy against 1 - terminated, weight 1)
    multiplies the running discount: a HARD 0/1 (> 0.5) inside the planner's value, the SOFT probability inside value
    targets. BMPC-torch has no notion of termination (DMC has none); HumanoidBench and TrackEnv (falls) do.
  - **The policy's target is the planner's MEAN and std** (std x 1.5, floored at 0.1), not a drawn elite's action.
  - **rho weights normalised to sum to 1** (rho^t / sum rho^t) where BMPC-torch divides by H.
  - **5 value heads** (BMPC-torch and EfficientTDMPC: 2); evaluation acts on the BEST elite, not a sampled one.

**R1.2 The four changes** [paper - the rungs of their Figure 4a, each measured]:
  1. **Practical.** (a) Per-step replay insertion (every transition as it happens); (b) acting horizon 3 -> 6;
     (c) reanalyze at 1/8 the budget - 64 samples, 8 elites, 3 policy trajectories (reanalyze dominates wall-clock;
     Figure 6: HumanoidBench AUC slightly UP, DMC slightly down). Rung result: mildly better than BMPC.
  2. **Aggregate multi-horizon objective** (eq. 1): the acting planner maximises
     Q^_agg(z, a_1..H) = (1/H) sum_{h=1..H} Q^_h(z, a_1..h), each Q^_h rolling out the first h actions and bootstrapping
     with the value at depth h. Lower variance than the final-depth objective when the Q^_h are not fully correlated or
     variance grows with depth (as in MCTS - MuZero, TSMCTS). ACTING only: reanalyze keeps horizon 3, final depth.
  3. **Ensembles for state-action value estimation** (eqs. 2-4), Nf = 4 dynamics heads f_i:
     TRAINING - every head rolls out the sampled actions from the same z_t, and the reward and value heads train on
     EVERY head's rolled-out latents (the value-equivalent family has never done this - the paper's claimed novelty);
     ESTIMATION (planning AND value-target creation) - Q^(i, j): roll out dynamics head i, bootstrap with value head j
     (eq. 2); the estimate is the mean over all Nf x Nv pairs (eq. 3); PETS-style TS-infinity trajectory sampling (a
     particle keeps ONE dynamics head for its whole rollout); the uncertainty is the variance of that mean,
     Var_{i,j}[Q^(i, j)] / (Nf Nv) (eq. 4 - an underestimate, heads being shared across pairs; used only as a penalty).
     Scaling: 2 -> 4 -> 8 heads better each time (Figure 4b); 4 chosen for wall-clock.
  4. **Pessimistic reanalyze** (eq. 5): the reanalyze planner maximises J = Q^ - beta * sigma^ (sigma^: eq. 4's square
     root), so the policy is distilled toward actions whose value the ensemble AGREES on - actions the models have
     been trained around. beta = 10 on tasks with early termination, 0 elsewhere (Figure 5a: +70% AUC on h1hand-walk,
     -50% on humanoid-walk; 5b: beta 10 best of {0, 1, 3, 10, 30}). Acting stays unpenalised (App. B.4: penalising it
     too does not help).
  The ladder (Figure 4a, 5 tasks, 5-8 seeds): BMPC 1.0 -> +practical ~1.15 -> +multi-horizon ~1.3 -> +ensemble ~1.57.

**R1.3 Reproducing their numbers - the protocol** [paper, App. A]: HumanoidBench h1hand x 14 at 1M steps; DMC 21 easy
at 200k + 7 hard at 1M; 4 seeds a task (8 for the pessimism study); evaluation return against env steps; normalise
each task by BMPC's mean return at the same budget; AUC on a shared step grid, a missing step 0 anchored at BMPC's
untrained score; HumanoidBench and easy/hard DMC averaged separately, the headline the mean of HumanoidBench and
suite-equal DMC. Baseline curves from the authors' repositories (App. A.3). We have neither MuJoCo's DMC nor
HumanoidBench, so an exact reproduction is out of reach inside zimr; what IS in reach: the ablation DIRECTION -
BMPC, then each rung - on tasks we simulate (the gym cartpole and humanoid of `robot_gym`, then TrackEnv), and the
Appendix C.1 exploitation measurement (planner's promise vs the real simulator), which our bench already has the
machinery for (`exploitation` column).

**R1.4 What we have** (tested): the graph autograd with matmul, relu, mish, layerNormRows, softmaxRows, concat,
slice, min, mseLoss, softCrossEntropy (T4); Adam; polyakUpdate (EMA targets); clipGradNorm; ReplayBuffer;
ObsNormalizer; categoricalProject (T3 - a two-hot encoding is its discount-0 case); n-step transitions (T1); TrackEnv
with termination vs truncation; an MPPI over the robot world model (`robot_world`) and a simpler sampling planner in
zimrnum; the twin world models of I1b - a two-head dynamics ensemble whose disagreement already prices the policy (a
cousin of changes 3 and 4); the GPU kit for scale; and, added Sep 28 by N1-N2: `Params` (trained / frozen / target
bindings), `Graph.detach`, `Graph.simNorm`, and `Graph.klGaussianDiag` with a log-std per row (the distillation loss).
NOT here yet: a MuZero-style latent model (SuperTrack's world model is supervised on real states, not
value-equivalent), symlog / two-hot (`CategoricalScalar`), the layer builders, reanalyze, MPPI with elites + policy
samples + warm start.

**R1.5 Native to zimrnum - the design** (Simon, Sep 28: "find the true best way, simplest way ... our library needs
to feel like it was built for this"). The whole TD-MPC class - BMPC, EfficientTDMPC, TD-MPC2, and TD4's critics with
them - reduces to five ideas, and zimrnum already has the hard parts of each:
  1. **A network is its parameters plus ONE builder, bound into any graph.** A `Params` set (tensors in one arena)
     binds into a graph as parameters (trained) or as constants (FROZEN - the same tensors, read live: `constant()`
     wraps the caller's tensor, no copy, so an Adam step on the live weights is seen at once, with nothing to
     re-sync). The TARGET is a second `Params` of the same shape, `polyakUpdate`d in place and bound as constants.
     BMPC's live / detached / target trio is then three bindings of two tensor sets - no module wrappers, no copies.
  2. **Planning is `recompute` of a graph built by the same builder.** The rollout builder - encode, then H steps of
     dynamics and reward, then the value at the end (or at every depth, EfficientTDMPC) - builds the TRAINING graph
     (B window rows, parameters trained) and the PLANNING graph (N sample rows, frozen). An MPPI iteration writes the
     sampled actions into the planning graph's action constants, recomputes, and reads the value column. The planning
     graph's rows are (states x samples): all of TrackEnv's characters plan in ONE recompute (BMPC-jax's batched
     acting), and reanalyze's H x b states use the same graph shape at another size. One
     definition of the model's arithmetic, used for learning and for search - nothing to drift apart (L12's graph-vs-
     rows parity risk does not arise: there is no second implementation).
  3. **An ensemble is an array of members, not a new tensor rank.** E members of one builder, bound and applied in a
     loop; losses and estimates sum or average over them. On the CPU that is the same arithmetic as a batched matmul
     and needs no rank-3 machinery; the kit batches the members on the GPU (N9). E = 1 is the single network, bit
     for bit - value heads (2), dynamics heads (EfficientTDMPC: 4), TD4's twin critics, SAC's twin Qs: one mechanism.
  4. **A small builder vocabulary** over the ops the graph has (add broadcasts a bias row, so a layer is
     `add(matmul(x, W), b)`): `linear`, `normedLinear` (linear, layerNormRows with a gain and bias through `mul` /
     `add`, Mish; dropout where asked), `mlp`; plus four NEW graph ops - `detach(x)` (forward a copy, backward nothing:
     encode (obs, next obs) ONCE and cut the consistency and value targets from it, BMPC-jax's single encoder pass),
     `simNorm(x, group)` (softmax within groups),
     `gaussianKL(mean_p, std_p, mean_q, std_q)` (closed form, rows), and the `CategoricalScalar` helper (symlog
     two-hot targets through `categoricalProject`, the loss through `softCrossEntropy`, decode = softmax . bins then
     symexp).
  5. **Three plain pieces around the graphs**: `SequenceReplay` (BMPC-jax's form, the simpler one: a ring per
     environment of whole transition rows, one masked write per step, windows drawn as (env, start) in O(1) and allowed
     to cross an episode's end, `finished` masks for the losses, per-row target columns reanalyze overwrites), `Mppi`
     (options, warm-start state per environment, all noise drawn once per call, `plan(scorer)` returning the action,
     the target distribution and the mean), and `RunningScale`.
  6. **Nothing computed twice.** The training graph's true encodings feed reanalyze's planner and its rolled-out
     latents feed the policy update, read after the recompute - no second encoding, no second rollout (BMPC-jax).
  Where things live: the vocabulary, the new ops, `Params`, `CategoricalScalar`, `SliceReplay`, `Mppi` and
  `RunningScale` in zimrnum (general machinery, with zimrnum's known-answer tests); the agent - BMPC with
  EfficientTDMPC's changes as options - in `src/robot_tdmpc.zig`, driven by TrackEnv and by the gym tasks.

**R1.5b The build order, each piece with its known answer:**
  - **N1 `Params` and bindings** - DONE Sep 28: `zimrnum.Params(T)` - `init`, `clone`, `bind(graph, .trained |
    .frozen)`, `follow` (polyak per tensor); a learning-rate scale per set is one `Optimizer` per set (nothing new).
    Three known answers pass; a frozen binding that COPIES its tensors fails the live-read one. As planned: Trainable,
    frozen, target; Adam over a `Params` with a learning-rate scale per set
    (the encoder's x 0.3). KNOWN ANSWERS: a frozen binding sees an Adam step without being rebuilt; no gradient ever
    reaches a frozen binding; the target after `polyakUpdate` at tau = 1 equals the live set.
  - **N2 The vocabulary and the new ops.** DONE Sep 28-29 (the layers' second half, Sep 29 - see 6.0): `detach` (a
    stop-gradient - the
    input's value, no gradient
    through it: zero on its own path, the other path's gradient bit for bit); `simNorm` (every group a probability
    vector; one group = `softmaxRows`; in place = out of place; `checkGradient`); the Gaussian KL - the EXISTING
    `Graph.klGaussianDiag`, generalised to a log-std per ROW (BMPC's state-dependent spreads; it was already policy-
    first and composed from tested ops); `symlog` / `symexp` and `CategoricalScalar` (two-hot through the same split as
    `categoricalProject`, now shared as `addPointMassToGrid`; symexp(symlog(x)) = x; decode(encode(x)) = x on and
    between bins, both axes; clamping; equal to the projection of a point mass); the layers on `Dense`'s template -
    `Dense.attachAs`, `LayerNorm`, `NormedDense`, `Mlp` (`checkGradient` through a 3-layer mlp ending in SimNorm).
  - **N3 The rollout builder and the world-model loss** - DONE Sep 29 as `LatentRollout` + `WorldModelLoss` (see
    6.0). The "planted linear system" training answer moves to the assembly (N6), where an optimiser runs. KNOWN
    ANSWERS held: the graph against step-by-step and hand computations, `checkGradient` where finite differences are
    valid, the no-leak comparison for the encoder, refilled targets.
  - **N4 Planning by recompute, and `Mppi`.** KNOWN ANSWERS: the planning graph's value for one sample equals the
    training builder's rollout value for the same latent and actions, bit for bit; on a planted scorer with a known
    optimum MPPI converges to it; with policy trajectories only (no samples) it returns the policy's action; the warm
    start shifts the mean by one step exactly.
  - **N5 `SequenceReplay`.** KNOWN ANSWERS: a window is consecutive rows of ONE environment's ring (across the wrap
    too); `finished` is false up to and including the first done and true after it; a write-back lands exactly on the
    rows named; empty targets read as N(0, 1); per-step insertion of a masked-out environment writes nothing.
  - **N6 BMPC assembled** (acting, the update, the policy's distillation with `RunningScale`, the value target,
    reanalyze, the warm-up burst, the discount rule; `finished` masks in every loss; batched acting over every
    environment; reanalyze and the policy fed by the update's own encodings and rollouts) - on the gym cartpole within
    5 minutes at reduced widths, then TrackEnv. Options from BMPC-jax, each a bench question: the CONTINUE head (hard
    in planning, soft in targets - TrackEnv needs it: falls end episodes), the policy target (drawn elite, as torch;
    or the planner's mean and std x 1.5 floored at 0.1, as jax), rho normalised or divided by H, 2 or 5 value heads.
    KNOWN ANSWERS: every piece's parity above; the untrained agent on TrackEnv is the servo; one update
    at a fixed seed fingerprinted and kept as the regression answer.
    THE TWO REPLAYS (Sep 30; Simon: generic ingredients in zimrnum, specialised code may start as an independent
    fork in the robot files, no frameworks or towers of abstraction - simple functions on arrays): `zimrnum.
    SequenceReplay` (rows of floats; windows may cross an episode's end, `finished` masks the rest) is the generic
    one; `robot_track.Replay` (typed columns - pose, velocity, action, frame, clip and segment ids; windows only
    INSIDE one segment, which changes at every reset and every shove) stays SuperTrack's own. No second window rule
    goes into zimrnum for it. If BMPC on TrackEnv wants sequence windows, start from a copy beside robot_track and
    share only small functions on arrays where one fits naturally.
    The trade-off to keep in view: segments average ~21 frames, so 32-frame windows inside one were 0 / 200 (T5);
    masked windows would still exist. The two tutorials already explain the two rules once each and link both ways.
    N6 BREAKDOWN (Sep 30, after the inventory). HAVE: Params + the layers (SimNorm, LayerNorm, Mish via Activation),
    LatentRollout, WorldModelLoss (consistency / reward / value, rho^t, averaged over steps and heads),
    LatentPlanScorer + Mppi, SequenceReplay (+ writeBack for reanalyze), CategoricalScalar (two-hot, decode),
    klGaussianDiag, diagGaussianLogProb, clipGradNorm, polyakUpdate, AdamSet (robot_gym), symlog / symexp, the
    continuous cartpole (zimrnum). MISSING: `finished` masks in WorldModelLoss (rho^t is per step; finished is per
    ROW - a generic extension, zimrnum); RunningScale (zimrnum, small); the BMPC policy head's pieces (tanh mean,
    log_std mapped into [low, high], KL to the target, the scaled entropy - composed of existing graph ops). The
    agent itself is an ASSEMBLY, not an ingredient: its own file (proposed `src/robot_bmpc.zig`, beside robot_gym,
    whose SacAgent is ~500 lines of a 2953-line file). Turns, each with its known answers:
      B1 finished masks in WorldModelLoss + RunningScale. KA: a mask of all zeros = today's loss bit for bit; a
         masked row contributes nothing (value and gradient); RunningScale = the EMA of q95 - q5 by hand, floored at 1.
         PRECISELY (re-read Sep 30, torch and jax side by side): RunningScale is TORCH's - value starts at 1, each update
         value += tau * (max(1, q95 - q5) - value), the floor on each BATCH's range before the average, percentiles by
         linear interpolation of the sorted batch, the batch being the FIRST step's KL (jax instead stores max(1,
         EMA(range)) - the two agree only while ranges stay above 1). The masks' normalisation, as jax does it (torch's
         windows never cross an episode, so torch has none to copy): consistency at step t = the mean over the
         UNFINISHED rows only; reward and value = the sum over steps of the masked rho-weighted terms, then the mean over
         the WHOLE batch (finished rows as zeros); a continue loss, when there is one, masked too (jax forgets to).
         RUNNINGSCALE DONE Oct 1: `zimrnum.RunningScale(T)` (value 1, tau; `update(batch, scratch)` - quantileSorted's
         interpolation, which is torch's), after `quantile`. KA: the hand EMA (90 -> 9.9, then a 0.5 spread floored ->
         9.01); torch's order pinned against jax's (from 5, a 0.2 spread -> 4.6, not 4.52); 11 shuffled values -> 9; the
         batch untouched; empty / mismatched / NaN refused. Negative control: jax's order fails exactly the two
         numeric tests (8.955, 4.52). Tutorial 18d.12. NEXT: the masks.
         MASKS DONE Oct 1 - B1 COMPLETE. The rollout OWNS them: `LatentRollout.unfinished` (a [batch, 1] column per
         step) and `unfinished_mean_factors` (batch / still counting; 0 when none), all 1 until
         `setFinished(finished)` - SequenceReplay's finished_out as it comes, every entry checked to be 0 or 1 before
         any is written. Consistency at t = mseLoss(z * M, y * M) * factor - the mean over the windows still counting;
         WorldModelLoss multiplies its reward and value TARGETS by the same columns (an all-zero target row costs
         exactly nothing: softCrossEntropyRowsGrad weighs the prediction by the row's target mass - now a unit test),
         the mean staying over the whole batch. One call marks all three terms. New Graph op: copyToEveryColumn
         (copyToEveryRow's twin, an exact matmul by a row of ones). KA: NOTHING FINISHED = the loss as it always was,
         BIT FOR BIT, the total and every gradient of all five networks, against the old formula built by hand on a
         second graph; a finished window counts for nothing - its action, next observation, reward and value targets
         changed, no bit of the loss or any gradient moves (and counted again, the losses part); the masked mean by
         hand; a step with every window finished contributes 0, not NaN; refusals change nothing. Four negative
         controls, each failing exactly its predicted tests. FOR B4: the policy's loss also reads rolled latents -
         check whether jax masks it by finished, and mask it alike if so.
      B2 the policy head: tanh mean, log_std in [low, high], the KL(pi || target) and the scaled entropy on the graph.
         KA: checkGradient; KL zero at pi = target; log_std's ends; parity with klGaussianDiag / diagGaussianLogProb.
         SPLIT Oct 1 into B2a (the head, done) and B2b (the per-step loss). RE-READ OF TORCH'S SOURCE
         (/tmp/bmpc/bmpc-main: world_model.py pi, math.py, bmpc.py update_pi) CORRECTS ONE NOTE: in BMPC mode the
         policy is NOT a squashed draw - mean = tanh(m), action = clamp(mean + s * eps, -1, 1), no Jacobian term; so
         the policy IS N(tanh m, s^2), the Gaussian the KL compares (`squashedReparameterize` is TD-MPC2's, not
         BMPC's). log std = low + dif * (tanh(x) + 1) / 2: [-3, 1], and [-2, 1] ("expl") for the planner's policy
         trajectories during reanalyze only. update_pi(zs.detach()) on zs[:-1]; kl = KL(N(mean, s) || expert) averaged
         over dims; scale.update(kl[0]) BEFORE dividing; loss = mean over t of rho^t * mean over batch of (kl / scale -
         1e-4 * scaled_entropy); clip 20 on the policy's parameters only; its own optimiser. scaled_entropy =
         -size * log N(eps) (up to a 1e-8 guard): its gradient is size per log std, its mean size * entropy.
         B2a DONE Oct 1: `Graph.tanhIntoRange` (beside tanh), `Graph.diagGaussianEntropy` (DiagGaussian.entropy's twin,
         [rows, 1]), `TanhMeanGaussian(T)` (build(graph, output, .{ log_std_low, log_std_high }) -> mean, log_std; the
         doc records the clamp-not-squash and why dims * entropy has exactly torch's scaled-entropy gradient). KA: the
         range's midpoint and exact ends for [-3, 1] and [-2, 1], refusals, the slope by hand; the entropy = DiagGaussian
         .entropy row by row, a gradient of exactly 1 per log std; the head's centres and spreads (saturated ends
         exact), zero KL against itself, one distillation step under checkGradient; odd widths refused. Controls: full
         width fails the range and head tests; the entropy without its + 1/2 fails parity only. Tutorial 18d.13.
         B2b NEXT: the per-step policy loss (rho^t / H, the KL averaged over dims, a [1, 1] scale constant refilled
         after RunningScale.update, the entropy term, the first step's KL rows exposed) + the masks question (jax).
         FOR B3: acting = clamp(tanh(m) + s * eps, -1, 1), a plain function, not squashedReparameterize.
         B2b DONE Oct 1 - B2 COMPLETE. BMPC-jax read first (/tmp/bmpcjax): it DOES mask the policy loss -
         sum over t of lam * kl / scale where ~finished, then the mean over the whole batch (KL summed over dims, no
         entropy, lam normalised). Ours = torch's formula with jax's masks: `PolicyDistillationLoss(T)` - latents ONE
         Var [H * batch, latent], step-major, data (a separate graph's constant or detached rollout rows); the policy in
         one pass; targets zero-filled = N(0, 1) (means, and LOG stds); KL averaged over dims; entropy * c * dims; ONE
         weight column rho^t / (H * batch) * unfinished, built in-graph from the rollout's columns (one setFinished
         marks every loss); each term a dot product; `updateScale(graph, *RunningScale, scratch)` reads step 0's rows,
         sets inverse_scale. KA: the hand computation (formulas written out) nothing finished and one finished; a
         finished row's latent and targets changed -> no bit moves (counted again, the totals part); updateScale = a
         hand RunningScale on step 0's rows only, the scale really moved, and the gradient WITHOUT the second
         recompute equals the one with it, bit for bit (so a shared graph may skip it); checkGradient through the
         policy net, every parameter connected; refusals. Controls: masks ignored -> hand + finished-row tests; last
         step's rows -> updateScale only; entropy without dims -> hand + updateScale. Tutorial 18d.14.
         FOR B4: copy the rollout's rolled[0 .. H-1] values into the policy graph's latent constant (step-major)
         AFTER the world-model forward and BEFORE its Adam step (torch: zs from the same forward, detached); the
         targets from the replay rows (mean, log of std); clip 20 on the policy's parameters alone; its own Adam
         (eps 1e-5).
      B3 the agent's skeleton and ACTING: the six networks (+ target values, zero last layers for reward and values),
         policy trajectories into Mppi, the drawn elite + std noise, replay rows (obs, action, reward, done, target
         mean / std). KA: actions in [-1, 1], one acting step fingerprinted, the replay row layout by hand.
         THE ROW LAYOUT, CORRECTED (Sep 30, from BMPC-jax's buffer): a row must carry its own NEXT OBSERVATION -
         obs ++ action ++ reward ++ next_obs ++ terminated ++ truncated ++ target mean ++ target std, windows of H rows.
         With observations only and windows of H + 1 rows, the step that ENDS an episode takes the next row's
         observation as its successor - the NEXT episode's first state after the reset - so the consistency loss
         would teach the dynamics a jump that never happens (finished is 0 at that step, by design: its reward and
         observation are real). The vector env returns the true final observation; the junk transition after it is the
         masked insertion. The target sits in the SAME row as the observation it was planned from (jax; torch shifts
         it to the next row, `[1:]`), so reanalyze writes back steps 0 .. H - 1: first_step 0. The tutorial's replay
         example (18d.9: windows of horizon + 1, writeBack(..., 1, ...)) changes with this, in B3.
      B4 the UPDATE: windows from SequenceReplay, two-hot targets, the value target (one policy step through the
         model + gamma V_target), WorldModelLoss with masks, clip 20, Adam (encoder lr x 0.3), the policy update with
         RunningScale, the target EMA. KA: one update at a fixed seed fingerprinted (the regression answer); the value
         target by hand on a planted model.
         THE BASE IS TORCH'S (EfficientTDMPC is built on it, Table 2): the policy loss = mean over t of rho^t / H *
         mean over batch and action dimensions of (KL(pi || target) / scale - 1e-4 * scaled entropy), log std in
         [-3, 1]; the value target's action SAMPLED from the policy, its bootstrap the mean of the target heads. jax
         differs on each (KL summed over dimensions, no entropy, rho normalised, log std [-5, 1], five value heads,
         consistency weight 10, a fixed discount 0.99, reanalyze also during the warm-up burst) - bench options.
      B5 REANALYZE + the SCHEDULE (warm-up burst, discount rule) + the CARTPOLE GATE (reduced widths, inside 5 min).
         KA: written-back targets = the re-plan's; gamma's clamp by hand; the gate's balance threshold.
      B6 a review turn; the tutorial (16.x BMPC assembled; robot-mocap when TrackEnv arrives).
      THE NEXT THREE TURNS, MADE PRECISE (Oct 3 review, from BMPC's torch source - bmpc.py act/_plan/_estimate_value/
      _td_target_V/_update, config.yaml - not memory). WHAT THE REVIEW FOUND MISSING ABOVE: (a) the planning SCORER
      was unnamed; (b) acting's details; (c) the value target starts from the TRUE latents, through the TARGET heads,
      and BMPC has NO terminal handling - so the gate uses fixed-length episodes (truncation only) until a continue
      head exists; (d) the update's exact order and normalisations; (e) `Mlp.apply` needs a Graph - acting builds one
      inference graph per act, all samples batched as rows, so gate widths stay small; (f) the row layout's columns.
      BMPC's defaults (config.yaml): horizon 3, iterations 6, samples 512, elites 64, policy trajectories 24, std
      [0.05, 2], temperature 0.5, log std [-3, 1] (exploration [-2, 1] in reanalyze only), entropy 1e-4, 101 bins on
      [-10, 10], latent 512, mlp 512, enc 256, num_q 2, value dropout 0.01, simnorm 8, td_horizon 1, batch 256,
      consistency 20 / reward 0.1 / value 0.1, rho 0.5, lr 3e-4 (encoder x 0.3), clip 20, tau 0.01, discount rule
      denom 5 clamped [0.95, 0.995], reanalyze every 10 updates (20 rows, horizon 3).
      TURN 1 - B3a ACTING (new src/robot_bmpc.zig; its tests reached from src/robot_tests.zig, or test-fast never
        sees them). `Config` (BMPC's defaults; gate widths are the gate's, later). `Networks(T)`: encoder (obs ->
        latent, SimNorm), dynamics (latent ++ action -> latent, SimNorm), reward (latent ++ action -> bins), policy
        (latent -> 2 x action through TanhMeanGaussian), num_q value heads (latent -> bins) and their target copies;
        reward and value heads' LAST LAYERS ZERO. `discountedReturn(rewards[H][rows], terminal_values[rows], gamma,
        scores)` - plain arithmetic on arrays, _estimate_value's sum (reward at (z_t, a_t) BEFORE z moves; + gamma^H
        V avg). `rollLatents` (one inference graph: encode once, H steps of two_hot_inv(reward) then next, the
        heads' average V at the end). `policyTrajectories` (num_pi_trajs rows: a = clamp(tanh m + s eps, -1, 1),
        z <- next). `act(obs, first, mode, rng) -> Acted { action, target_mean, target_std, value }`: Mppi with the
        policy rows in its reserved first rows, `iterations` rounds of sample -> score (NaN -> 0) -> refit, `choose`
        (a score-weighted elite draw, + std[0] eps unless evaluating, clamp), the warm start kept between calls.
        KNOWN ANSWERS: a fresh agent scores every trajectory EXACTLY 0 (zero last layers, symmetric support); one
        trajectory's score by hand (discountedReturn on chosen numbers); a planted reward -(a - 0.3)^2 with V = 0
        drives the chosen first action within 0.05 of 0.3; the policy rows bitwise untouched by sample / refit;
        200 random states -> every action in [-1, 1]; evaluation adds no noise; the warm start is the shifted mean
        (by hand); the replay target = (the chosen elite's first action, std[0]) from Mppi's own outputs; same seed
        -> same action bits. CONTROLS: the terminal value dropped -> the hand score fails (a planted V != 0); policy
        rows overwritten -> the untouched test fails. Tutorial: zimrnum 18d.15, acting in the latent space (the
        score, the policy's place in the search, the elite draw, what the replay keeps). Verify: the file's tests,
        then `check`; nothing over 5 minutes.
      TURN 1 CORRECTED AND SPLIT (Oct 3, while building it): the scorer was NOT missing - `zimrnum.LatentPlanScorer`
        (built Sep 30 with Mppi) is exactly _estimate_value, frozen-bound, states x candidates rows, with known answers;
        `discountedReturn` / `rollLatents` would have duplicated it. What was missing: the POLICY'S PLANS for Mppi's
        reserved rows. TURN 1a DONE: `zimrnum.LatentPolicyPlans(T)` beside the scorer (encode once, copy to each plan's
        rows by a 0/1 product, then per step the policy's TanhMeanGaussian draw clamp(mean + e^(log s) eps, -1, 1) on
        the CPU - each action feeds the next dynamics - 2H recomputes; noise by (state, plan, step, dimension) on the
        counter-based Rng; fills ONLY each state's first `plans` rows; widths read from the networks' specs, refused
        when they disagree). Known answers: every plan bit for bit against a row-by-row reroll on separate single-row
        graphs; only the policy rows written, in [-1, 1]; same seed same plans, other seed others; refusals. Controls
        (on the real source, restored): no dynamics step -> the bit-for-bit test only; every row written -> the rows
        test only. zimrnum 329/329; reference row; tutorial 18d.15 (the plans, and how plans + scorer + Mppi meet at
        one decision - next turn's `act`). TURN 1b NEXT: src/robot_bmpc.zig - `Config`, `Networks(T)` (zero_last on
        reward / values, first_dropout 0.01 on values, sim_norm 8 on encoder / dynamics), `act` assembling scorer +
        plans + Mppi with the known answers listed under TURN 1. Turns 2 and 3 follow unchanged.
      TURN 1b DONE (Oct 3) - TURN 1 COMPLETE: src/robot_bmpc.zig, `Bmpc(T)` = Config (config.yaml's numbers; the
        discount stated by the task until turn 3's rule), Networks (encoder 1 hidden layer + SimNorm; dynamics, reward,
        policy, num_q value heads 2 hidden layers; reward / values `zero_last`, values `first_dropout`; target values
        = `withParams(params().clone())`), Decision, Actor (Mppi + LatentPlanScorer + LatentPolicyPlans on two
        graphs, frozen). `act` = observations in; plans.fill into the scorer's rows; `Mppi.plan` NOISE-FREE (the
        target: drawn elite's first action + first spread); then `Mppi.explore` (new in zimrnum, extracted from
        `choose` - one definition of the jitter) or the target itself when evaluating. What Mppi's own tests already
        prove (convergence on a planted objective, policy rows, refit, warm start, bounds) is not repeated. Known
        answers: a fresh agent's imagination flat (|score| < 1e-12); the exploration by hand (zm.clamp, an independent
        clamp); evaluating = the same target, acted on as is; the policy's plans in the search bit for bit; the same
        seed the same decision; 40 decisions in [-1, 1]. Controls (on the real source, restored): no jitter -> the
        target/exploration test only; no plans -> the plans test only. robot_tests.zig registers the file (the main
        robot step 612 -> 616). zimrnum 329/329, test-fast 616, check 358/358.
      TURN 2 - B3b + B4a THE REPLAY ROW AND THE WORLD-MODEL UPDATE. Row = obs ++ action ++ reward ++ next_obs ++ done
        ++ terminated ++ target_mean ++ target_std (done = terminated or truncated - the column SequenceReplay masks
        windows with; terminated kept for a future continue head); windows of H rows; reanalyze will write back
        first_step 0. `Agent.observe(transition, acted)` pushes it. Tutorial 18d.9's replay example follows (windows
        of H rows, writeBack(..., 0, ...)). `valueTargets(true_latents, ...)`: td_horizon policy steps through the
        model from the TRUE latents (encode(obs) of each row, no gradient), + gamma^h x the TARGET heads' average V.
        `updateWorldModel(windows)`: next-latent targets = encode(next_obs) (no gradient); LatentRollout from row 0's
        obs + WorldModelLoss (masks by setFinished; consistency / H, reward / H, value / (H num_q); coefficients 20 /
        0.1 / 0.1); backward; ONE global norm clip at 20 over every model parameter; Adam with the encoder's lr x
        0.3; the target heads follow (tau 0.01). KNOWN ANSWERS: the row by hand; finished = rows AFTER a done in the
        window (the done row itself counts); the value target by hand on a planted model (td_horizon 1: r + gamma
        V_target); the clip: a gradient of norm 40 comes out at exactly 20, one of norm 10 untouched; Adam's first
        step on the encoder is exactly 0.3 x the unscaled one; the follow by hand; one whole world-model update at a
        fixed seed fingerprinted (the regression answer). CONTROLS: online heads instead of target -> the planted
        target fails; no clip -> the clip test fails. Verify: the tests, `check`.
      TURN 2a DONE (Oct 3) - THE REPLAY ROW: robot_bmpc.zig `Row` (observation | action | reward | next observation |
        done | terminated | target mean | target spread; every offset a named fn - `doneColumn` is SequenceReplay's,
        `targetMeanStart` reanalyze's writeBack column), `Step` (the acted action, the TRUE successor, terminated /
        truncated), `Target` (null -> the empty target N(0, 1), BMPC's warm-up rows). done = terminated or truncated.
        Known answers: a row by hand (all 15 values and the offsets); the empty target; through the real
        SequenceReplay a truncated step counts and the steps after it are finished ([0, 0, 1, 1]), the window's rows
        the pushed ones bit for bit; refusals. Control: done ignoring truncation -> exactly the hand row and the
        replay test fail. SequenceReplay's doc example and tutorial 18d.9 follow (windows of H rows, writeBack from
        step 0, why a row keeps its successor). test-fast 620 (+4); zimrnum 329/329; check 360/360 (the autofix
        chain dogfooded). Written lint-clean the first time (autofix had nothing to do; 0 by-hand findings).
        FOR TURN 2b (the world-model update): LatentRollout takes H + 1 observation blocks (z_0 = block 0, step t's
        consistency target = block t + 1), so feed it [row_0.observation, row_0.next_observation, ...,
        row_(H-1).next_observation] - every step's target its OWN successor, the true final state at an episode's
        end - no change to LatentRollout needed. Then valueTargets, WorldModelLoss with masks, the clip, Adam with the
        encoder at 0.3, the target follow - the known answers listed under TURN 2.
      TURN 2b1 DONE (Oct 3) - THE VALUE TARGETS: `zimrnum.LatentValueTargets(T)` beside the scorer and the plans (the
        generic TD-MPC ingredient): from each stored step's TRUE latent, `lookahead` policy steps through the model
        (draw -> reward read from its bins, discounted -> dynamics), then gamma^h x the TARGET heads' value averaged
        over the heads; built once over frozen handles, rows = windows x steps, 2h + 2 recomputes, noise by (row,
        step, dimension). `TanhMeanGaussian(T).draw` - BMPC's clamp(tanh m + e^(log s) eps, -1, 1) - is now ONE
        definition; LatentPolicyPlans calls it too. Known answers: two steps ahead, two target heads, bit for bit
        against a row-by-row reroll on single-row graphs (the draw's formula written out, the sum term by term);
        zero_last heads -> zero targets; same seed same targets, other seed others; refusals. Controls: the end value
        not discounted -> the bit-for-bit test only; the latents not moved on -> the same, only. zimrnum 333/333;
        tutorial 18d.16 (what a target is, and why the policy, the model and the TARGET heads). TURN 2b2 NEXT - the
        world-model update in robot_bmpc.zig: windows of H rows from SequenceReplay; the rollout's observations
        assembled [row_0.observation, row_t.next_observation ...]; rewards and LatentValueTargets two-hot encoded
        into WorldModelLoss's target tensors; setFinished; backward; clipGradNorm(.., 20) over every world-model
        parameter; two Adams (the encoder at 0.3 x 3e-4); the target heads follow (tau 0.01). Known answers: the
        assembly by hand; the clip at 40 -> 20 and 10 untouched (clipGradNorm's own direction test exists - here the
        wiring); the encoder's first Adam step 0.3 x the other's; the follow by hand; one update fingerprinted.
      TURN 2b2 DONE (Oct 3) - TURN 2 COMPLETE: robot_bmpc.zig `WorldModelLearner` (+ `WorldModelReport`), Config gains
        BMPC's learning numbers (windows 256, rho 0.5, weights 20 / 0.1 / 0.1, rate 3e-4, encoder x 0.3, clip 20, follow
        0.01, lookahead 1). Built once: the world model bound TRAINED on its graph (rollout + WorldModelLoss over
        tensors it owns), two Adams (encoder at 0.3 x - Adam with two parameter groups), LatentValueTargets on a frozen
        graph over the TARGET heads, the heads' Params for the follow. `update`: sample W windows of H rows ->
        `loadWindows` ([o_0 | n_0 .. n_(H-1)] - each step checked against its OWN successor; actions; reward two-hots;
        the targets' observations; a small `rowOf` helper) -> value targets, two-hot -> setFinished -> resampleDropout
        -> forward -> backward -> clipGradNorm over every parameter -> both Adams -> follow. Known answers: the windows
        laid out by hand (blocks, actions, targets' observations; reward two-hots decode back); one update - with the
        clip at 1e-3 the global norm after is the limit to 1e-12, Adam's first step never above the rate and its
        largest change the rate (9e-5 encoder, 3e-4 dynamics), every target number = before + 0.01 x (online - before);
        the same seed the same update bit for bit. Controls: no clip, and the encoder at the full rate - each fails
        exactly the one-update test. test-fast 623 (+3, first try); check 360/360. Tutorial 18d.18 (two figures,
        rendered and checked: the windows laid out, the five steps with their numbers; update's real code).
      TURN 3 DONE (Oct 3) - B4 COMPLETE: robot_bmpc.zig `PolicyLearner` (own graph over a latents tensor; the
        rollout's `unfinished` shared so one setFinished masks both losses; PolicyDistillationLoss with BMPC's entropy
        1e-4 and log-std bounds; RunningScale; its own clip at 20 and Adam epsilon 1e-5), `Learner` (world model, then
        policy unless pretraining), `discountFor` (L / 5 rule, clamped [0.95, 0.995]). The latents are the world model's
        rolled z_0 .. z_(H-1) read AFTER its Adam step - an optimiser changes weights, not the pass's values - which is
        torch's zs.detach(). Known answers: the latents bit for bit = the forward pass's; the targets = means and LOG
        spreads by hand; pretraining leaves the policy bit-identical while the world model moves, and the policy's half
        moves no world-model network; the policy's clip to exactly its limit; the discount at 50 / 100 / 500 / 1000 by
        hand. Controls: latents after a fresh recompute; spreads unlogged; pretraining ignored - each fails exactly its
        own test. test-fast 628 (+5, first try); check 360/360. Tutorial 18d.19 (two figures: the two halves; the
        discount rule plotted, computed - plus the real code).
      TURN 3 - B4b THE POLICY UPDATE AND `update()`. `updatePolicy`: the rollout's rolled[0 .. H-1] values copied,
        step-major, into the policy graph's latent constant AFTER the world model's forward and BEFORE its Adam
        step (torch: zs from the same forward, detached); targets from the rows (mean, LOG of std);
        PolicyDistillationLoss + RunningScale (update on step 0's KL rows, then divide); clip 20 on the policy's
        parameters alone; its own Adam (eps 1e-5). `Agent.update(rng, pretrain)`: sample windows -> world model ->
        policy (skipped while pretraining) -> target follow. The discount rule `discountFor(episode_length)` (denom 5,
        clamp [0.95, 0.995]) lands here too. KNOWN ANSWERS: the policy's latents = the rollout's rolled values, bit
        for bit; the world-model step leaves every policy parameter unchanged and the policy step every model
        parameter; pretrain = no policy change at all; the discount rule by hand (episode 100 -> 0.95 clamp; 1000 ->
        0.995; 50 -> 0.9 -> 0.95); one whole update fingerprinted. CONTROLS: latents taken after the Adam step ->
        the bit-for-bit test fails. Verify: the tests, `check`, then `test-fast` (the robot family).
      AFTER THESE THREE: B5 (reanalyze every 10 updates on 20 rows at horizon 3 with the exploration log std, writing
      back first_step 0; the warm-up schedule; the CARTPOLE GATE - zimrnum's cartpole, fixed-length episodes, gate
      widths, a balance threshold judged in the real simulator, inside 5 minutes), then B6 (review; tutorial 16.x).
  - **N7 EfficientTDMPC to parity with its v5 paper** (Evers, Meo, Bohmer, Dauwels, Oren; EWRL 2026, arXiv
    2605.16692v5, Sep 28 2026 - re-read Oct 4 against our code). THE CHECKLIST, from its Table 2 and Appendix D:
      HAVE  BMPC's base exactly at Table 2's BMPC column: latent 512, hidden 512 in two layers, encoder one hidden
            layer of 256, SimNorm 8, 2 value heads, 1 reward head, batch 256, lr 3e-4, encoder x 0.3, clip 20,
            tau 0.01, rho 0.5, 101 bins on [-10, 10], log std [-3, 1], entropy 1e-4, gamma from L in
            [0.95, 0.995], reanalyze every 10 updates on 20 windows, one update per environment step; PER-STEP
            INSERTION (SequenceReplay writes every frame - their "data freshness"); evaluation = the DRAWN elite
            without noise, as torch (zrl's Mppi doc and the tutorial claimed "best elite" - corrected Oct 4).
      GAP   (a) TWO PLANNERS, configured apart - acting {H 6, 512 samples, 64 elites, 24 policy plans, objective
                MEAN OVER DEPTHS, beta 0} and reanalyze {H 3, 64 / 8 / 3, objective FINAL, beta per task} - while
                the TRAINING window stays H 3. Today one `horizon` serves all three and both planners share one
                budget.
            (b) +2 MPPI iterations from 20 action dimensions up (BMPC's code: `>= 20`; its paper says "> 20"), in
                both planners (6 -> 8). DONE in B6a (Oct 4): it is BMPC's own rule, not EfficientTDMPC's.
            (c) the MULTI-HORIZON objective (eq. 6): (1/H) sum over h = 1..H of Q_h, the prefix of h planned actions
                bootstrapped with the value at depth h. Acting only (reanalyze keeps the final objective).
            (d) the DYNAMICS ENSEMBLE, Nf = 4 (2 and 8 as options; their AUC +10 / +22 / +33% for 2 / 4 / 8): heads
                with separate parameters, initialised differently, sharing the encoder, the reward head, the value
                heads and the policy. Training (Appendix D): every head rolls the window's actions out from the
                ENCODED start (eq. 11); consistency (eq. 12) and reward (eq. 13) averaged over heads; value (eq. 15)
                every value head on every head's latents, averaged over Nv x Nf; the value TARGET (eq. 14) the
                one-step backup from the TRUE latent through EVERY head - action sampled from the policy and
                detached, target value heads averaged - then averaged over heads; the POLICY loss (eq. 16) on each
                head's detached latents, averaged over heads.
            (e) ensemble SCORING (eqs. 7-9): every candidate rolled out under EVERY head (TS-infinity per head, not
                one head per sample - R1.6's guess was wrong) and bootstrapped with every value head: Nf x Nv
                estimates, their MEAN the score; the VARIANCE OF THE MEAN, Var(i, j) / (Nf Nv), kept for (f) (it
                underestimates - the estimates share heads - and the paper finds that harmless).
            (f) PESSIMISTIC REANALYZE (eq. 10): J = mean - beta x sigma, in REANALYZE ONLY (B.4: pessimism while
                acting does not help); beta = 10 where episodes can end early, 0 elsewhere (fig. 5: it hurts
                tasks without early termination).
            (g) PRESETS: `Config.bmpc(...)` (today's numbers, bit for bit) and `Config.efficientTdmpc(...)`, with
                early termination as an argument.
      OPEN  the policy's own plans under an ensemble - which head rolls the policy forward to produce them? Natural
            reading: head 0 generates, every head scores (scoring is where the ensemble matters). A choice with a
            test, and a bench arm if it turns out to matter.
    STAGES, each with known answers (KA) and a control that fails exactly its own test:
      N7a the two planners and the iteration rule. KA: the bmpc preset reproduces today's decisions bit for bit; an
          action of 20 dimensions plans 6 iterations, 21 plans 8; the training window is unchanged by the acting H.
      N7b the multi-horizon objective in the scorer. KA: at H = 1 it IS the final objective; planted rewards and
          values worked by hand; a planted pair of plans where it prefers the one whose prefixes stay valuable and
          the final objective prefers the other.
      N7c the ensemble's training. KA: Nf identical heads give Nf = 1's losses and gradients exactly; distinct seeds
          give distinct heads; one head's consistency term moves only that head and the shared encoder; the value
          target through identical heads equals Nf = 1's.
      N7d ensemble scoring and the variance of the mean. KA: identical heads give zero variance and Nf = 1's scores;
          a planted spread of estimates worked by hand.
      N7e pessimistic reanalyze. KA: beta = 0 is plain reanalyze bit for bit; planted variances flip the chosen
          plan exactly at the beta computed by hand; acting is untouched by beta.
      N7f THE CROSS-SCORING DIAGNOSTIC (their C.1): plan under one head and under the ensemble; score both plans,
          and the policy's action, single-head / ensemble / in the real environment (the same actions stepped, the
          learned values bootstrapping); Delta R = plan minus policy. The ensemble's plans must be the LESS
          exploited (their single-head Delta R looks large and is not real). This is how we know (d)-(e) work
          before any long run.
  - **N8 Measuring - their protocol, on our tasks.** Evaluation episodes every 10k environment steps in evaluate
    mode; per task the mean over at least 4 seeds with 95% CIs (mean +/- 1.96 SE); the area under each curve,
    normalised by OUR BMPC's return at the same budget (BMPC = 1).
      THE SUITE. (1) DMC-EQUIVALENT classic tasks, written to dm_control's definitions (rewards via `tolerance`,
      1000-step episodes, action repeat 2, 200k environment steps): cartpole balance, balance_sparse, swingup,
      swingup_sparse; pendulum swingup; acrobot swingup; reacher easy and hard. Their fig. 9 curves are
      approximate targets - our physics is not MuJoCo. (2) EARLY-TERMINATION tasks: the cartpole hold task (ends
      when the pole falls) and TrackEnv (falls).
      THE RUNS. The ladder: BMPC -> + practical (acting H 6, the cheap reanalyze) -> + multi-horizon -> + ensemble 4
      -> + pessimism (early-termination tasks only). Ensemble 1 / 2 / 4 / 8. Beta 0 / 1 / 3 / 10 / 30 on an
      early-termination task. Cheap vs full reanalyze. Wall-clock per 100k decisions.
      SUCCESS - what "at least as good as theirs" means for us: (i) the ladder's order reproduced, with
      non-overlapping 95% CIs between BMPC and the full method; (ii) the full method >= +30% AUC over our BMPC on
      the suite (theirs: +56% on five tasks); (iii) our BMPC's final aggregate reached in <= 60% of the steps
      (theirs: 43%); (iv) on the DMC-equivalent tasks, returns within the range of their fig. 9 at 100k and 200k
      steps; (v) beta helping where episodes end early and not elsewhere, as in their fig. 5.
  - **N8b Termination.** The paper models no termination - its base, BMPC, has none - yet its pessimism pays exactly
    where episodes end early. For TrackEnv's falls and the cartpole hold task: a CONTINUE head option (sigmoid,
    binary cross-entropy against 1 - terminated; a hard 0/1 inside the planner's value, the soft probability inside
    value targets), measured against no termination on the early-termination tasks, with and without pessimism.
    Kept only if it wins.
  - **N9 The kit - a prerequisite of N8's full-size runs.** The rollout under Nf heads, the categorical heads, MPPI's
    scoring (512 samples x 8 iterations x H 6 x 4 heads per decision) and the value targets as batched GPU kernels,
    checked against the CPU graph. Their A100 takes 47 minutes per 100k decisions; ours need not match, but one
    200k-step run must fit in a day for N8 to be practical. Until then: reduced widths, as the cartpole gate.
  - **N10 Jumpy dynamics - an EXPERIMENT after N7-N9 (Simon, Oct 4).** One more network beside the 1-step dynamics:
    a 4-STEP head f4(z_t, a_t .. a_t+3) -> z_t+4 (SimNorm output, the same latent space), with a 4-step REWARD
    output - the jump skips three per-step rewards - the discounted sum r_t + gamma r_t+1 + gamma^2 r_t+2 +
    gamma^3 r_t+3 (two-hot, the same bins). The encoder and the value heads are shared: V(z) does not depend on how
    z was reached, and the bootstrap after a jump is gamma^4. PLANNING: one FIXED schedule every candidate shares -
    jumps 1, 1, 4, 4: 10 steps of lookahead (0.33 s at DReCon's 30 Hz) in 4 evaluations, against EfficientTDMPC's
    acting H 6 (6 steps in 6). MPPI still searches per-step actions (10 x A), the 4-step head reading its 4; the
    multi-horizon objective's depths become the jump boundaries 1, 2, 6, 10. NOT per-rollout resolutions:
    candidates scored at different resolutions are not comparable (the heads' biases differ). TRAINING: windows of
    >= 5 observations for one jump (11 for the whole schedule); f4's consistency from each true latent against the
    encoding 4 steps later; value-equivalence (the value heads read f4's latents, against the targets 4 steps on);
    the 4-step reward against the window's discounted rewards; masks for spans that cross an episode's end;
    optionally a cross-scale consistency f4(z, a1..a4) ~ f1(f1(f1(f1(z, a1), a2), a3), a4), which needs no data. The
    1-step dynamics stays: the policy needs per-step latents to propose plans and to be distilled (its own plans
    rolled 1-step). LEARNABILITY (DReCon): 133 ms under PD control is smooth, more so with the 0.2 action filter -
    but the filter's state must be in the observation, or the 4-step map is not Markov; contacts inside the span and
    motion-matching switches from user input are the hard parts (the latter unpredictable at any resolution - f4
    learns their average). KNOWN ANSWERS: a linear system z' = A z + B a, where f4 must learn A^4 z + sum over i of
    A^(3-i) B a_i; the 4-step reward as the hand-discounted sum; the schedule's score by hand. MEASURED with N8's
    protocol, the premise first: f4's error against four chained 1-step predictions on held-out windows, then the
    schedule against H 6 at equal planning time.

**R1.6 Open questions - after reading BMPC's code.** ANSWERED: SimNorm's form, two-hot and its loss, the
consistency loss (MSE against no-gradient encodings, rho^t, /H), MPPI's update and warm start, the policy target
(a drawn elite's first action and std), the KL (policy first, running-scaled, with the entropy term), the value
target (model rewards along a policy rollout, target heads), the discount rule, the buffer layout, the schedule. ANSWERED
BY THE v5 PAPER (Oct 4, Appendix D): the dynamics heads share the encoder and each has a consistency term, averaged
over heads (eqs. 11-12); scoring rolls EVERY candidate under EVERY head - not sample k under head k mod E (eqs. 7-8);
value targets average the one-step backup over every head, with the target value heads averaged (eq. 14). See N7.
STILL OPEN: which head rolls the policy forward to produce its own plans under an ensemble (N7, OPEN). And for us: TrackEnv's falls are early terminations, so by their rule
pessimism should help - consistent with I1b.

**R1.7 Carrying it to the dance.** TrackEnv is the environment (decisions, falls as `.stop`, the cap as `.cut`); the
latent model learns from its decisions; the policy prior's action is the residual nudge. Three of R1's ideas apply
beyond BMPC and are worth trying on SuperTrack directly: an ensemble of world models whose MEAN the policy trains
through (I1b averaged two - R1 says 4 to 8, and that more is better); the ensemble's disagreement as a penalty on the
policy's objective (I1b's w_disagree - R1 applies it only where it distills, and only when episodes can end early);
and averaging the objective over rollout depths (SuperTrack's window loss already sums over its steps; R1's form
bootstraps at each depth). Each is an I-stage ingredient with a parity test, then a bench arm.

### R4 Four more read Oct 1 (Simon asked what fits) - CANDIDATES, none scheduled

- **Newt** (Hansen, Su, Wang; arXiv 2511.19584, ICLR 2026) - TD-MPC2 scaled to 200 tasks with online RL, conditioned
  on a language embedding fed to every component; demonstrations used four ways: (1) model-based pretraining of ALL
  components, the policy's Q term off; (2) constrained planning - the planner biased toward the pretrained policy,
  annealed to zero over the first 12% of training; (3) a separate demonstration buffer sampled 50 / 50; (4) a BC term
  in the policy loss, on rolled latents. Also: open-loop plans of 48 steps, 16x its training horizon of 3, close to
  closed-loop on most tasks; model AND batch size matter once tasks multiply. FOR US: (a) V2 gets a third route,
  MODEL-BASED DISTILLATION - per-clip teachers' rollouts as demonstrations; in BMPC the BC term needs no new loss: a
  demonstration row's target columns hold the teacher's action with a small std, and BMPC's existing KL distillation
  IS model-based BC; pretraining = the warm-up burst on demonstration rows; oversampling = a second SequenceReplay,
  half the batch; constrained planning = an Mppi option biasing toward the policy prior, annealed. KA to plan: with
  demonstrations only, the pretrained policy matches plain BC on them; reanalyze never overwrites a demonstration
  row. (b) no task embedding needed: for tracking the REFERENCE is the instruction, already observed. (c) the open-
  loop rollout length at which tracking breaks - a world-model DIAGNOSTIC worth logging (and, at run time, the
  number of steps between re-plans an NPC could afford).
- **RAY-TOLD** (Han, Lee, Kang; arXiv 2604.27450, Apr 2026) - crowd navigation: MPPI with short PHYSICS-based
  rollouts plus a learned terminal value and policy prior (policy trajectories mixed into the MPPI population - our
  24 policy samples already), around a LiDAR-ray latent model. FOR US, after the gate: Mppi is already decoupled from
  its scorer (the caller drives the loop), so a kinematic NPC can plan with EXACT short rollouts + a learned value;
  and ray observations are cheap game sensors (zimr's physics raycasts) - a natural V1 asymmetric observation (the
  NPC's policy senses rays; the world model sees the state).
- **IQL-TD-MPC** (Chitnis et al.; arXiv 2306.00867, 2023; ICRA 2024 - not 2026) - OFFLINE model-based RL: IQL inside
  TD-MPC, then a temporally coarse "manager" planning latent subgoals ("intent embeddings", g = f(z, a^M) - z)
  concatenated to any offline worker's state; large gains on sparse long-horizon AntMaze. FOR US: later, for layered
  behaviours (a manager choosing where to go or which clip, the tracker below); tracking itself is dense and short.
- **ViGMO** - not found under that name (Oct 1). Its subject, visual generalization under distractors with
  augmentation (cf. SADA, RL-ViGen), concerns pixel observations; our agents observe simulator state - low priority.

### R2 onward - candidates to study next (named in R1's related work and baselines)
Mrs. Q (Chang et al. 2026: pessimism critical on HumanoidBench, harmful on DMC), DR.Q (Lyu et al. 2026: debiased
model-based representations for Q-learning), BRC (Nauman et al. 2025: bigger, regularised, categorical critics),
SimBa-v2 (Lee et al. 2025: hyperspherical normalisation), BOOM (Zhan et al. 2025) and TD-M(PC)^2 (Lin et al. 2026):
policy regularised toward the actions taken, TSMCTS (Oren et al. 2026): multi-depth averaging's variance argument,
and roxie's TD4 (plan I5).

### R3 DR-EfficientTDMPC - a PROPOSAL: distributional robustness on top of R1 (Simon, Sep 28)

(Simon: "add this new idea at the end of the plan, make it fit our current plan ... find the best way to prepare for
that; spend 5 turns making the plan and verifying it". Status: COMPLETE, five turns (Sep 28). Turn 1: the critical
reading and the
triage (R3.0-R3.4). Turn 2: DR-SAC's own code read (R3.5) and Simon's use for it - robustness that BUYS physics
speed (R3.6). Turn 3: the core maths checked numerically, a correction to R3.1's scope, the theory and efficiency
claims checked (R3.7). Turn 4: re-centred on OUR problem by Simon - R3.8 is the result and supersedes R3.3, R3.4 and
R3.6 where they differ. Turn 5: the consistency pass - section 6.0 is now ONE order across every track, 3.9
records Sep 28's infrastructure, R1.4 and N2 are current, I1b points at V3.)

**R3.0 What it is.** An unreviewed proposal - no experiments ("expected performance" is argued, not measured) -
composing DR-SAC (Cui et al., ICLR 2026: soft actor-critic against the WORST transition model within a KL ball around
the nominal one, via a scalar dual) with R1 as the engine, plus consistency distillation, BatchEnsemble / MIMO
ensembles, an evidential value head and adaptive test-time compute. So it is read here as a MENU: each idea earns its
place by a known answer and a bench arm, and nothing is taken as a recipe to reproduce.

**R3.1 The core idea, in our terms - worth building.** The TD-MPC family's dynamics heads are DETERMINISTIC, so "the
ensemble as the nominal transition" (R3's section 4.4) is a distribution with N atoms: one next latent per head, each
with weight 1/N. A distribution within a KL ball around it must keep its support (finite KL), so the worst case can only
REWEIGHT those atoms - and the robust expectation of a value v over them is the KL dual (Hu and Hong 2013):

    robust_delta(v_1..v_N) = sup over beta > 0 of { -beta log( (1/N) sum_i exp(-v_i / beta) ) - beta delta }

- a SOFT MINIMUM of the heads' values, with delta the pessimism knob: delta = 0 gives the mean (R1's eq. 3); delta >=
log N lets the worst case put all its weight on the lowest atom (KL(one-hot || uniform) = log N), giving the minimum
(TD3's clipped double-Q); in between, a principled blend. Consequences, each to be verified in turn 3:
  - The per-(z, a) dual is a ONE-DIMENSIONAL CONCAVE maximisation over N numbers - cheap and exact. DR-SAC's dual
    NETWORK g_eta amortises beta* over infinitely many continuous next-state distributions in the offline setting;
    with N atoms it is unnecessary.
  - For small delta, robust_delta ~ mean - sqrt(2 delta) * std: R1's pessimistic reanalyze, J = Q^ - beta sigma^, looks
    like this expansion - with sigma^ the std of the MEAN, beta sigma^ = (beta / sqrt(N)) std, i.e. delta ~ beta^2 /
    (2 N) = 6.25 for R1's beta = 10 and N = Nf x Nv = 8 - already past log 8 = 2.08, where the KL-robust value IS the
    minimum. (If turn 3 confirms it: R1's beta = 10 is "take the worst head", and delta is the natural dial below it.)
  - Its gradient, where it enters a loss, is the envelope theorem's: d robust / d v_i = tilted weights w_i proportional
    to exp(-v_i / beta*), summing to 1 (beta* held at its optimum).
  Two DROP-IN uses in R1 / BMPC, both options on R1's N6 / N7: (1) VALUE TARGETS - y(z) = R(z, pi(z)) + gamma *
  robust_delta over the Nf x Nv pairs (i, j) of V_target,j(f_i(z, pi(z))), where R1 takes their mean; (2) the PLANNER -
  robust_delta over the (i, j) estimates of each candidate sequence (TS-infinity keeps the heads apart; the aggregation
  is across heads, per sequence), acting and/or reanalyze.

**R3.2 The rest, triaged** (verdict and reason; turn 3 checks each against the literature):
  - *Robust SOFT Bellman, SAC's temperature.* BMPC is a distillation method with a 1e-4 entropy bonus, not max-entropy
    RL; the robustness does not need the "soft". Keep robustness, leave the max-entropy framing (optional later).
  - *Probabilistic dynamics heads.* NEEDED for R3.6 - revised in turn 3 (R3.7): deterministic heads carry MODEL
    uncertainty only, and the messy world's spread is invisible to them. An option with a known answer, not a default.
  - *The dual network g_eta.* Unnecessary with N atoms (R3.1). Drop.
  - *"Consistency distillation" of the dynamics.* Mislabelled - a k-step direct predictor regressed on the teacher's
    rollouts is multi-step distillation, not a consistency model (Song et al. 2023: no noise, no probability-flow ODE).
    It also CONFLICTS with R1's multi-horizon objective, which needs the latent at EVERY depth; and on our CPU the cost
    is arithmetic, not sequential depth. Defer; revisit only on the kit, with a student that outputs every depth.
  - *"Consistency planner".* In substance an action-CHUNK policy as MPPI's proposal plus 1-2 refinement iterations.
    BMPC already seeds MPPI with 24 policy trajectories; a chunk policy is a sensible compute knob later. Defer - to be
    measured against R1's 1/8-budget reanalyze first.
  - *BatchEnsemble (Wen et al. 2020) / MIMO (Havasi et al. 2021).* BatchEnsemble cuts PARAMETERS and memory, not
    arithmetic - each member still multiplies its own inputs. MIMO does cut arithmetic - one pass for M members - by
    sharing one network's capacity. Neither saves "a factor N_f N_v" of compute as claimed without paying for it, and
    correlated members weaken exactly the disagreement pessimism feeds on. Defer to the kit; if tried, the known answer
    is R1's Appendix C.1 measurement (does disagreement still predict
    the planner's exploitation?).
  - *Evidential value head (Amini et al. 2020).* Its variance is known to be poorly calibrated as EPISTEMIC uncertainty
    (Meinert et al. 2023), and a categorical value head already reads a return spread for free. Defer; same known
    answer.
  - *Adaptive test-time compute.* Sensible once an uncertainty signal is SHOWN to predict when planning helps. Defer.
  - *The theory* (contraction, interchange, regret) is DR-SAC's, with its assumptions - a FINITE action set (log |A| in
    the bounds, not our continuous actions), a bound exponential in 1 / beta - carried to latent space as sketches.
    Motivation, not load-bearing here.

**R3.3 [DEPRIORITISED in turn 4 - a problem we do not have] What robustness needs that the plan does not have yet:
a SHIFTED-DYNAMICS benchmark.** A robust method is
judged by training on the nominal physics and evaluating on perturbed physics (mass, friction, actuator strength,
action noise, pushes). Without it, "robust" cannot be told from "pessimistic". Turn 4 finds the knobs our fleet
exposes and specifies the benchmark.

**R3.4 [SUPERSEDED by R3.8's V1-V5] Preparation, in order:** P0 measure first - the physics' share of a training
iteration's
wall-clock, and the sim gap (R3.6); P1 the robust aggregation primitive, plain and on the graph, with the known answers
turn 3 verifies; P2 robust value targets and robust planning, as options on N6 / N7; P3 the benchmark - "train messy,
run accurate" (R3.6) and DR-SAC's shift suite (R3.5); P4 bench arms - nominal, domain randomisation, R1's mean, R1's
beta sigma, KL-robust at a delta sweep - all judged in the ACCURATE physics.

**R3.5 DR-SAC's own code, read** (`DR-SAC-master`, Sep 28: `sac.py`, `environment_modifiers.py`,
`config/sac_config.yaml`). What it actually does:
  - The dual is computed WITH its -beta delta term (`dual_func_g`, `dual_func_ind`; the README's formula drops it):
    -beta (logsumexp(-V(s') / beta) - log n) - beta delta, over n = 200 next states SAMPLED from a generative model of
    the nominal transition - a VAE by default, or diffusion, a flow, a score model. That is the same N-atom form as
    R3.1, with N = 200 samples where we have N heads: the generative models exist only to produce samples, and our
    deterministic ensemble produces its atoms directly.
  - The robust value is a DROP-IN in the TD target: target_Q = r + (1 - done) gamma V_robust - where R3.1 puts ours.
    With `use_v`, V(s') is a state-value network, evaluated at the sampled next states (BMPC has state values too).
  - beta*: either the "functional" dual network (exp-activated output, 5 ascent steps on the dual per update) or a
    per-sample bounded scalar search over beta in [1e-4, 1]. That upper bound is a HIDDEN pessimism setting: the dual
    reaches the mean only as beta grows, so with returns in the hundreds a cap of 1 keeps the robust value near the
    sample MINIMUM whatever delta says. Ours: the exact 1-D concave maximum over beta > 0, no cap.
  - delta = 0.1 by default. Everything in it is offline (datasets), SAC with twin critics.
  - The test suite (`environment_modifiers.py`) - the model for our P3: parameter shifts as factors on nominal values
    (gravity, mass, length, engine force, joint stiffness and damping, actuator range); observation noise (gaussian,
    uniform, cauchy, salt-and-pepper, adversarial; per dimension; a frequency); reward shifts; transition
    perturbations with a probability per step (random forces, friction changes, and "teleport" - which moves only the
    OBSERVATION). Train at nominal, judge under each shift.

**R3.6 [PARTLY DEPRIORITISED in turn 4: the cheap physics and solver drift are problems we do not have; the REDUCED
OBSERVATION is kept, and R3.8 reshapes it] Simon's use: robustness that buys physics speed** (Sep 28: "we will be able
to increase physics dt, and reduce
constraint solver steps, for perf, and reduce observation dimensions, which makes the world more messy and
stochastic"). Cheaper physics and a smaller observation make the transitions the learner sees noisier and less
predictable - exactly what a KL ball around the nominal model is meant to absorb. So the benchmark becomes "TRAIN
MESSY, RUN ACCURATE": train in the cheap settings, judge in the accurate physics (and under R3.5's shifts). Details
that make it an honest test:
  - The knobs exist: `Model.opt.timestep` (1/240 by default; tracking fleets set their own) and
    `opt.solver.max_iterations` (60). Soft constraints floor their time constant at 2 x timestep, so a larger step also
    SOFTENS contacts by itself - a change in the physics, not only noise on it.
  - Hold the DECISION rate when the step grows: TrackEnv decides every `decimation` physics steps (30 decisions a
    second at 60 Hz, k = 2); doubling the step means k = 1 - the policy's world stays one decision per 1/30 s.
  - The PD servo is tuned for its step. First known answer: the servo alone - the untrained policy - still tracks the
    clip in the cheap settings (its MTTF there against the accurate physics'); a servo that goes unstable is a
    different problem from the one robustness solves.
  - The SIM GAP, measured: from the same states and actions, how far the cheap physics' next states land from the
    accurate physics' after one decision. The delta sweep should span it.
  - Observation reduction: fewer watched bodies, velocities dropped, fewer future reference frames. Partial
    observability makes transitions stochastic from the learner's side (different states look alike); the ensemble's
    disagreement should rise there - R1's Appendix C.1 measurement again.
  - What the guarantee does NOT cover: DR protects against shifts inside the KL ball around the TRAINING nominal. The
    cheap-to-accurate shift is never seen in training, so delta is chosen by validation - a sweep judged in the
    accurate physics. And the baseline to beat is DOMAIN RANDOMISATION (the step, the solver iterations and the masses
    drawn per episode) - the standard answer for sim-to-sim and sim-to-real transfer - besides the plain nominal policy.
  - Measure first (P0): the speed-up is worth having only if physics is a large share of a training iteration. On our
    CPU the learner's graph may dominate (the SuperTrack bench's iterations are mostly world-model and policy updates);
    the physics share decides whether "cheap physics" buys wall-clock at all.

**R3.7 Turn 3: the maths verified, a scope corrected, the claims checked.** The script is kept in
`src/notes/bench/r3_kl_robust_check.py` (Python, outside zimr). The robust value is computed two independent ways -
the DUAL (a 1-D search over beta) and the PRIMAL (a generic constrained optimiser over the reweightings, knowing
nothing of duality) - on 8 values ~ 100 +- 15, returns-sized:
  1. Dual = primal: worst gap 1.7e-7 of the spread over 40 draws x 7 deltas. The formula is right.
  2. Limits: delta -> 0 gives the mean; delta = log N and above gives EXACTLY the minimum; delta = log N - 0.2 still
     sits 0.16 above it.
  3. Small delta: (mean - robust) / (sqrt(2 delta) std) = 0.981, 0.994, 0.998, 0.9994 at delta = 1e-2 ... 1e-5, the
     std normalised by 1/N. The expansion holds.
  4. R1's beta = 10 with N = 8: mean - beta std / sqrt(N) lands BELOW the worst head in 100% of 2000 draws (either std
     convention). R1's pessimism is not a KL-robust value at all - the KL family never goes below the worst head - it
     is a variance-averse RANKING of candidates, harsher than any delta. So the two are different knobs; both stay
     bench arms (R3.4, P4).
  5. The dual is concave in beta (checked on LINEAR beta grids: worst chord gap 3e-14 of the range - a first check on
     a log-beta grid was malformed, concavity in beta is not concavity in log beta). So a 1-D search for beta* is
     reliable: the known answer for P1's solver.
  6. Gradient: finite differences equal the tilted weights w_i ~ exp(-v_i / beta*) to 3e-9 (envelope theorem).
  7. DR-SAC's cap beta <= 1 at this scale, delta = 0.1: the robust value falls from 89.97 (exact) to 78.08 - next to
     the minimum, 76.11. The cap is a pessimism setting in disguise.
THE SCOPE CORRECTION (turn 1 was wrong here). The N-head form covers MODEL (epistemic) uncertainty only: heads differ
where the data does not pin them down. Simon's messy world adds TRANSITION (aleatoric) spread: with a reduced
observation the same observation leads to different next states - different true states look alike - and a
deterministic head fitting that learns the AVERAGE next latent. The heads can agree on that average, and then the
spread is invisible to the ensemble: a robust value over heads would not see it. So R3.6 needs PROBABILISTIC heads -
the proposal's choice, deferred in turn 1 - each predicting a spread as well as a centre; the nominal is the mixture,
M next latents are sampled per head, and the SAME primitive aggregates the N x M atoms. SimNorm latents live on
simplices, so the noise goes in BEFORE SimNorm (sample the pre-activation, then normalise). Known answer for turn 4's
build step: on a planted coin-flip transition (two next states, equally likely), deterministic heads converge to the
midpoint - zero spread, robust value = the mean - while probabilistic heads recover both branches, and the robust
value moves toward the worse branch as delta grows.
THE THEORY, checked: the KL dual is Hu and Hong's (2013) - verified numerically above for discrete nominals; the
contraction is the standard one for (s, a)-rectangular sets (Iyengar 2005; Nilim and El Ghaoui 2005) - in latent space
it needs the latent model to be Markov, which it need not be; the regret bound grows like exp(V_max / ((1 - gamma)
beta)) - with gamma = 0.99 and returns in the hundreds it is vacuous; the finite-action assumption bounds DR-SAC's
dual network, which we do not use. Motivation, none of it load-bearing.
THE EFFICIENCY CLAIMS, checked: consistency models (Song et al. 2023) distil a probability-flow ODE into a one-step map
- the proposal's "consistency dynamics" is multi-step prediction, mislabelled (R3.2 stands); BatchEnsemble saves memory,
MIMO saves arithmetic at the cost of independence (R3.2 refined); deep evidential regression (Amini et al. 2020) has
been shown not to measure epistemic uncertainty reliably (Meinert et al. 2023; Bengs et al. 2022) (R3.2 stands).

**R3.8 Turn 4 - what has the most value for OUR tracking problem** (Simon, Sep 28: "I like the part about not having
the whole env state in the observation, so it is more stochastic. This is more important than solver drift. I don't
want to try to solve problems we don't have. I like the distillation for reducing the cost of rollouts ... We want
speed and tracking quality for diverse anims."). What we have: SuperTrack's world model sees the character's FULL
simulated state, and so does its policy (the full latent and the goal); DReCon's observation is already partial (six
watched bodies, the centre of mass, reference views 2 / 4 / 6 frames ahead); about ten clips - two dances, two runs,
two walks, a fall-and-get-up, a push-and-stumble, a jump, Geno's dance - of which the bench uses one. In value order:

  **V1 ASYMMETRIC OBSERVATION - the policy partial, the world model full.** In simulation the full state is FREE at
  training time. So the partial observation lives only where it is real: the POLICY - the one thing that runs in the
  game - sees a reduced observation; the WORLD MODEL (and any critic) keeps the full state (asymmetric actor-critic,
  Pinto et al. 2018, carried into SuperTrack). The model stays deterministic and accurate; the policy's gradient,
  taken through it, averages over every state consistent with what the policy sees - so the policy learns the best
  action for its partial view, and the stochasticity sits where Simon wants it and nowhere it hurts. It also SETTLES
  turn 3's correction: probabilistic heads were needed only if the MODEL saw a partial observation - here it does not.
  Build: an observation SELECTION (a fixed choice of features from the model's predicted state - differentiable)
  between the model's rollout and the policy's input; the reductions worth measuring - fewer watched bodies, velocities
  dropped, fewer lookahead frames - with the last applied action kept as a short memory (A1 already feeds it).
  KNOWN ANSWERS: selecting every feature reproduces today's training bit for bit; the parity test (graph = rows) holds
  under any selection; then the bench's curve - tracking quality against observation size.

  **V2 DIVERSE ANIMATIONS - one policy, many clips.** The quality target is a single runtime policy that tracks every
  clip. Two routes, compared on the same benchmark: (a) train one multi-clip SuperTrack policy directly (SuperTrack
  itself was trained on a large dataset); (b) DISTIL: train per-clip (or per-family) teachers - full observation,
  easiest learning - then one STUDENT with the reduced observation, by DAgger (the student acts, the teachers label
  its states; MoCapAct's route for many clips, and the standard teacher-student route to partial observability in
  locomotion). The benchmark first: train on most clips, judge on all of them AND on held-out ones (generalisation),
  tracking quality per clip. KNOWN ANSWERS: a student distilled from ONE teacher on ONE clip reaches the teacher's
  tracking; DAgger's labels are the teacher's actions at the student's own states (a row test).
  A THIRD ROUTE to weigh when V2 starts (R4, Newt): MODEL-BASED DISTILLATION - the teachers' rollouts as demonstrations
  inside BMPC itself (a demonstration row's target = the teacher's action, so BMPC's KL distillation is model-based
  BC; the warm-up burst pretrains on them; a second SequenceReplay sampled 50 / 50; the planner biased toward the
  policy prior, annealed) - a bench question against DAgger, not a default.

  **V3 ROBUST TRAINING THROUGH A WORLD-MODEL ENSEMBLE** - R3.1's primitive, aimed at the failure we MEASURED (I1b: the
  policy exploits the model's errors, exploitation 100-300). K full-state world models; the policy's window cost
  evaluated through each; the K costs aggregated KL-robustly - for COSTS the soft MAXIMUM, -robust(-cost) - with delta
  the dial from the mean (delta = 0: I1b's twin average) to the worst member (delta >= log K). The principled form of
  I1b's disagreement price, with one knob instead of a price per feature. Cheap to build: by the envelope theorem the
  gradient is the tilted weights times each member's gradient, so the graph needs only a weighted sum with the
  weights as constants, refilled each step - no new op. With V1 the members' disagreement is purely MODEL uncertainty,
  which deterministic heads represent correctly. KNOWN ANSWERS: delta = 0 reproduces the ensemble mean's loss (I1b's
  twin average, bit for bit at K = 2); delta >= log K is the worst member's; the weighted-sum gradient matches finite
  differences of the robust cost; R3.7's seven numbers for the primitive itself.

  **V4 DISTILLATION FOR ROLLOUT COST** (Simon's). Where rollouts cost us: SuperTrack's policy loss backpropagates
  through a window of model steps; BMPC-style planning (R1) rolls hundreds of candidates. Three uses, in order of
  value: (a) PLANNER INTO POLICY - BMPC already does it: plan while training, act with the policy alone at run time,
  so the game never pays for search; (b) a SMALL STUDENT world model, distilled from the full-state teacher (or V3's
  ensemble) on replayed states and the policy's own actions, used for the policy's training rollouts - cheaper per
  step on the CPU, re-distilled as the teacher improves; (c) a student that predicts a whole window in ONE pass
  (every intermediate state - the tracking loss needs every frame, which is why R1's multi-horizon objective ruled
  out the proposal's k-step jump) - a win for sequential depth, so for the kit (Stage G). KNOWN ANSWERS: the
  student's k-step error against the teacher's on held-out windows; the policy trained through the student against
  through the teacher - tracking quality against wall-clock.

  **V5 SPEED, MEASURED FIRST** (P0, kept): where a training iteration's time goes - the fleet's physics, the world
  model, the policy's rollout and update - and the RUNTIME cost that matters in the game: one policy forward pass per
  character per decision, so its width and its observation's size (V1 shrinks both).

  NOT OUR PROBLEMS (Simon): cheap physics and solver drift, sim-to-real parameter shifts and the shifted-dynamics
  benchmark (R3.3, R3.6), DR-SAC's theory, probabilistic heads (V1 makes them unnecessary), BatchEnsemble / MIMO /
  evidential values / adaptive test-time compute (R3.2). Kept from R3: the KL-robust primitive (R3.1, verified in
  R3.7) - now serving V3.


### R5 SuperTrack x BMPC / EfficientTDMPC - a MERGE, PROPOSED (Simon, Oct 5)

Simon's brief: "a tentative merge of what we are doing with the direct-gradient supervised learning of SuperTrack.
Brainstorm all possible ways to include this, find the best, most performant solution. Our goal is to be as fast as
SuperTrack, but more robust to large perturbations, and even invent get-ups to get back to the mocap after a fall."
(The SuperTrack paper re-read Oct 5; numbers below are its.)

**R5.1 Why each side is what it is.**
  SUPERTRACK is fast for one reason: a PATHWISE gradient of a KNOWN, DENSE, differentiable loss (the tracking
  losses - local positions, velocities, rotations, angular velocities, heights, up vector) through a learned
  differentiable model, over a window of N_pi = 32 frames. Every policy step gets the exact direction that lowers 32
  frames of tracking error; an iteration is one world-model step (batch 2048, window 8) and one policy step (batch
  1024, window 32); acting is ONE policy forward pass; it is off-policy (a 150k-sample ring, ~5000 samples/s).
  Its three limits are exactly the brief's three goals:
    (1) the HORIZON IS THE WINDOW - nothing after 32 frames (~0.5 s at 60 Hz) reaches the policy (their sec. 7);
    (2) the gradient is LOCAL - a get-up first moves AWAY from the reference (hands down, roll, kneel: the tracking
        error rises before it falls), so no downhill direction leads there (their sec. 8: "does not exploit
        exploration... difficult to discover stepping motions to recover from falls");
    (3) the gym RESETS on a fall (head 25 cm off) - the world model never learns lying, rolling, pushing off the
        ground; the policy never sees a fallen state.
  BMPC / EFFICIENTTDMPC brings what is missing: a VALUE (an unbounded, discounted horizon), a PLANNER (search, which
  can climb uphill in tracking error toward a better long-run value), the ENSEMBLE's disagreement and PESSIMISM
  (robustness: stay where the model has been trained), DISTILLATION (search amortised into a fast policy). Its costs:
  value learning by TD is slow to propagate; acting by MPPI costs a search per step (512 x 6-8 x H x Nf model
  calls); its reward head and latent dynamics carry learned error where SuperTrack's reward is EXACT.
  THE GAME'S BUDGET (R3): one policy forward pass per character per decision - so a planner can be a TRAINING-TIME
  teacher, not a runtime part.

**R5.2 Every way to combine them** (verdict after each):
  M1 THE VALUE TAIL - SuperTrack's pathwise loss over the window plus gamma^H x V(state at the window's end), V
     learned (SHAC, Xu et al. ICLR 2022; Dreamer's actor; MAAC, Clavera et al. 2020; SVG, Heess et al. 2015).
     Removes limit (1) at the cost of one critic. CORE.
  M2 THE KNOWN REWARD - the tracking loss is an exact, differentiable function of the simulated and kinematic
     states (SuperTrack's observation 1), so the planner and the critic's targets use it directly; a reward head
     only where a reward is not known (the get-up objective below is known too). CORE.
  M3 SUPERTRACK'S STRUCTURED MODEL (Stage D's AccelWorld) as the dynamics everywhere - pathwise loss, critic
     targets, planner - against M4 below; Stage D3's A/B decides. Either way an ENSEMBLE of Nf heads (N7c).
  M4 BMPC's LATENT model with pathwise policy training through the latent (Dreamer-style). Value-equivalent, but
     no physical structure - its long rollouts drift (their fig. 14: even the structured model loses joint
     constraints past 64 frames). The D3 A/B's other arm.
  M5 THE PLANNER AS A SPARSE TEACHER - MPPI (the N7 actor: ensemble scoring, the known reward, the critic's tail,
     pessimism) run only on FLAGGED states - large tracking error, fallen, high ensemble disagreement - in the gym
     (directed exploration for a fraction of the characters) and in reanalyze (targets for stored flagged states);
     the policy's loss gains BMPC's KL to the planner's answer on those states. Removes limit (2) where it binds.
     CORE.
  M6 PLAN-WHEN-LOST AT RUNTIME - the planner overrides the policy under high disagreement. Breaks the game's
     budget; kept only as a development tool (a bench arm: how much does search add on top of the policy?).
  M7 THE PESSIMISTIC TAIL - the tail uses mean - beta x sigma over the critic and model ensembles (EfficientTDMPC's
     eq. 10, moved from reanalyze into the pathwise objective): the policy is pulled toward states the ensemble
     agrees on - robustness, and the brake on SuperTrack's model exploitation (risk 2 in section 8). CORE.
  M8 THE GYM FOR FALLS - no termination on a fall during training (episodes bounded by length only); a push
     curriculum (the paper's cubes: 5 m/s, mass growing); fallen starts (ragdoll drops, mid-fall states); a
     transition budget so the ring is not flooded with lying still. Removes limit (3). CORE.
  M9 RE-ENTRY BY MOTION MATCHING - when the simulated character is far from its reference, the reference becomes
     the database frame nearest the SIMULATED pose (DReCon's matching, queried with the physics state), so get-up
     clips (LaFAN has them) are found and tracked from where the character lies; continuous return to the original
     clip once close. Without get-up clips: HOLD the reference and track a reduced objective (height, up vector,
     root toward the held reference) until upright - the value and the planner must INVENT the get-up. SUPERSEDED for the one dance by R5.8 (Oct 5): re-entry and
     the hold are discrete switches; kept for the clip library, where re-entry chooses WHICH clip to rejoin.
  M10 THE CRITIC'S TARGETS FROM IMAGINATION - lambda-returns on model rollouts (MVE, Feinberg et al. 2018;
     Dreamer) plus real transitions: the critic learns at the pathwise loop's pace instead of TD's. CORE (speed).
  M11 SHORT WINDOW, CLIPPED - pathwise gradients through contact explode or mislead with long windows (SHAC's
     finding; Suh et al. 2022 on first-order gradients through contact); with a value tail the window can SHRINK
     (16-32), each piece of the trajectory stable; gradient clipping as SuperTrack found useful.
  M12 MIXED ESTIMATORS - pathwise where the dynamics are smooth, zeroth-order (the planner's search) where they are
     not (Suh et al.'s interpolation): M5's flags are this, by state. Subsumed by M5.
  M13 ACTIONS FAR FROM THE REFERENCE - SuperTrack's offsets around the reference pose (alpha 120) assume the
     reference is near; with M9's re-entry the reference is near again (the get-up clip from the lying pose); with
     the hold fallback, larger offsets are needed - the offsets' scale (or the regularisers' weight) reduced while
     far. Detail of M9.
  M14 THE EXPLOITATION GUARD - the cross-scoring diagnostic (N7f) and the bench's exploitation index on every run;
     M7's beta tuned by it.
  M15 ONE TRAINING RHYTHM - per iteration: one world-model step (the ensemble), one critic step (imagined
     lambda-returns), one policy step (pathwise + tail + KL on flagged states); the planner every K iterations on a
     small flagged batch. SuperTrack's rhythm plus two light steps. CORE.
  REJECTED: noise on the model's predictions (I1, measured harmful); a learned reward head for tracking (M2 makes
  it worse than exact); MPPI acting for every character (its cost is the whole reason SuperTrack is faster).

**R5.3 The recommended design - "SuperTrack with a pessimistic value tail and a sparse planning teacher".**
  The common case - tracking while near the reference - is learned at SuperTrack's speed by SuperTrack's own
  pathwise loss; the rare hard cases - large pushes, falls, get-ups - get BMPC's long horizon and search, where
  gradients cannot go. Compute stays dominated by SuperTrack's loop: the critic is one more MLP step, the planner
  runs on a few percent of states, acting is one policy pass. Runtime is SuperTrack's.
    world model   the structured model or the latent, by D3; Nf = 4 heads (N7c), trained as SuperTrack trains
                  its one, on data that now includes falls (M8)
    objective     exact and ONE everywhere (R5.8): tracking with non-vanishing gradients (local and global
                  terms), effort (torque-limited PD, mechanical power, the filter), the pose prior over the dance
                  and the get-up capture - no head, no switch
    critic        ensemble of two-hot value heads (BMPC's), on (simulated state, reference context: the next few
                  reference frames, local), targets = lambda-returns over imagined rollouts + real transitions,
                  target networks (Polyak 0.01)
    policy loss   sum over t < N of rho^t x R5.8's cost  +  gamma^N x (mean - beta x sigma) of the critic at the
                  window's end  +  lambda_kl x KL(policy || planner) on flagged states  +  SuperTrack's regulariser
    planner       the N7 actor: MPPI over offsets, policy plans as candidates, ensemble scoring with the known
                  reward and the critic's tail; pessimistic in reanalyze (N7e); run on flagged states only
    gym           reset-free (R5.8): the dance's clock never stops; pushes, drops, far starts; no fall
                  termination
    runtime       the policy alone
  Why this, and not a planner-first agent: BMPC's own strength (search) costs per decision, and its own weakness
  (TD's slow value) is exactly what SuperTrack's dense pathwise gradient replaces; and why not SuperTrack plus a
  critic only (I4's mix): a critic alone cannot discover get-ups either - its gradient is local too; the search is
  what finds the first get-up, and distillation is what keeps it.

**R5.4 Stages - each with known answers and a control** (after N7f; P5 after N9's planner kernels; each a bench
  arm against SuperTrack on the dance first):
  P1 THE VALUE TAIL. The critic (ensemble, two-hot, reference context), its imagined lambda-returns, the policy loss
     gains gamma^N x V(end). KNOWN ANSWERS: V = 0 -> SuperTrack's loss bit for bit; on a toy whose payoff lies past
     the window (a delayed reward), SuperTrack alone fails and the tail solves it; the lambda-returns by hand.
  P2 THE PESSIMISTIC TAIL. mean - beta x sigma over the heads. KA: beta = 0 -> P1 bit for bit; planted
     disagreement turns the gradient away from the disputed state at the beta worked out by hand.
  P3 THE UNIFIED OBJECTIVE AND THE RESET-FREE GYM (R5.8). Every term's shape non-vanishing (L1 / log-cosh), the
     global root and heading terms, the dance's clock that never stops, fallen / far / pushed starts, no fall
     termination. KA: exactly on the dance, the cost is SuperTrack's (the new terms zero); the gradient's magnitude
     three metres away equals the slope worked out by hand (and an exp-shaped control's is zero there); a fallen
     episode's reference advances frame by frame.
  P4 THE BODY'S LIMITS AND THE PRIOR (R5.8). Per-joint torque limits in the simulator's PD (saturating); the PD
     law and its clamp as a differentiable function for the effort term; mechanical power; the pose prior (a
     soft-min over the dance's and the get-up capture's poses, or a learned distance field). KA: a target asking
     more than the limit gets exactly the limit; the power by hand on a two-joint chain; the PD law's torques equal
     the simulator's on a single joint; the prior zero on a database pose (hard-min), within tau x log N (soft).
  P5 THE SPARSE TEACHER. Flags (error, fallen, disagreement), the planner on flagged states in the gym and in
     reanalyze, the KL term. KA: no flagged state -> P4's policy loss bit for bit; a flagged state's target is the
     planner's answer; the share of planned states bounded by the budget.
  P6 THE BENCH, against SuperTrack at equal wall-clock, on the dance: SPEED (time to SuperTrack's precision),
     PRECISION and RECOVERY and FLUIDITY and REALISM by R5.9's judge, ROBUSTNESS (the cube sweep: completion
     against mass) - and PHC's forgetting ablation: precision with and without recovery training (their 59.4% ->
     42.5% when mixed naively), which the balanced replay and SuperTrack's per-iteration tracking windows must hold
     at zero loss.
  Dependencies: Stage D (AccelWorld and its A/B), N7 (ensemble, pessimism, scoring, the actor, reanalyze), N9 (the
  planner's GPU kernels), I3 (TrackEnv, its pushes), I4 (the critic-on-SuperTrack mix is P1's ancestor - P1 replaces
  its model-free critic with imagined lambda-returns).

**R5.5 Risks, ranked.**
  1. Pathwise gradients through contact - exploding or misleading (SHAC, Suh et al.): a shorter window with the tail
     (M11), clipping, the learned model's smoothing; measured by gradient norms per window length.
  2. The critic's bias - overestimation pulls the policy into fantasies: ensembles, pessimism (M7), target
     networks, the exploitation guard (M14).
  3. Inventing a get-up needs the search to find ONE first: fallen starts make it frequent, the hold objective
     makes progress visible (height, up), the planner's horizon plus the tail spans it; a curriculum from slow to
     full gravity if nothing is found (Tao et al. 2022's slow-to-fast curriculum, "Learning to Get Up").
  4. The ring flooded with lying states: a fall budget per character; replay balanced by a near / far flag.
  5. Re-entry discontinuities - a reference that jumps: blend the switch over a few frames; the tracking loss's
     velocity terms see the jump otherwise.
  6. The planner's cost creeping up: the flagged share is a hard budget (a few percent), logged.

**R5.6 Open.** The reference context the critic needs (how many future frames); gamma per DECISION - its credit is
  1 / (1 - gamma) decisions: 0.99 is ~3.3 s at Geno's 30 Hz (decide_every 2), ~1.7 s at the paper's 60 Hz - enough
  for a get-up, or 0.995; whether the critic reads the physical state or a latent; how "back to
  the mocap" is judged (inside SuperTrack's own tolerances for a full second); whether to read PHC's fail-state
  recovery (Luo et al. 2023) and "Learning to Get Up" (Tao et al. 2022) before P3 - both PPO-based, both relevant to
  the objective's design.

**R5.7 PHC studied** (Perpetual Humanoid Control - Luo, Cao, Winkler, Kitani, Xu; ICCV 2023, arXiv 2305.06456v3;
  read Oct 5). WHAT IT IS: one PPO imitator of AMASS (11,313 clips, 98.9% success) that also gets up and walks back
  to its reference - never reset. Reward 0.5 task + 0.5 AMP (a discriminator on the last 10 frames of
  proprioception) + an energy penalty -0.0005 x sum over joints |torque x angular velocity|^2 (it removes the foot
  jitter a policy without external forces otherwise learns). Absolute PD targets, not offsets around the reference
  (robust to noisy references). Recovery: a separate primitive P(F) trained with a POINT-GOAL reward (d_(t-1) - d_t,
  the root's distance) + AMP + energy on walking and running clips; the goal state SWITCHED by the root's distance
  (their eq. 3: within 0.5 m the full imitation goal; beyond, every joint target but the root's replaced by the
  simulated value; the goal clamped at 5 m). Fallen starts: dropped, then random joint torques for 150 steps (after
  ASE); far starts 2-5 m away. Recovery measured as the share back within 5 s and 10 s: 95.0% / 98.8% from fallen,
  83.7% / 99.5% far, 93.4% / 98.8% both. PMCP: progressive primitives on harder and harder subsets, frozen, combined
  by a multiplicative composer - because training recovery in the same network FORGOT imitation (P(F) on imitation:
  42.5% success against P(1)'s 59.4%). Relaxed early termination (ankles and toes excluded). Cost: 1536
  environments, ~10 billion samples, a week on an A100.
  WHAT IT TEACHES US:
  (a) THE SWITCH IS A SYMPTOM. Their imitation reward is a product of exp(-k x error) terms: three metres away its
      position term is exp(-300) - no reward and no gradient - so a second objective must take over far away,
      chosen by a distance threshold. A cost whose gradient does NOT vanish with distance (SuperTrack's L1 losses;
      log-cosh) stays informative everywhere: ONE objective can carry the character from the floor into the dance.
  (b) THE SWITCH COSTS WHAT THEY REPORT: "the humanoid can suddenly jolt and snap into motion imitation", and the
      recovery gait shows AMP's asymmetry. A continuous objective has no moment to snap at.
  (c) FORGETTING IS REAL when recovery shares the network - for us one dance, not 11,313 clips, so capacity binds
      less; the guard is data (the replay balanced near / far) and SuperTrack's per-iteration tracking windows -
      measured (P6), not assumed.
  (d) ENERGY matters for realism even with good tracking (jitter); natural recovery needs a MOTION PRIOR (theirs is
      AMP; ours, R5.8's pose prior - we have the get-up capture and a differentiable pipeline).
  (e) Their fallen-start recipe (drop, then random torques for 150 steps) and their recovery metric (back within
      5 s and 10 s, from fallen / far / both) are adopted as they are.

**R5.8 The unified objective - one cost, one network, no switch** (Simon, Oct 5: "learn the 2 minute dance anim very
  precisely, and at the same time learn to get up and return to it fluidly, realistically ... energy, torque limits
  ... both goals in the same unified system, without discrete decision of if we are currently tracking or
  recovering").
  THE TASK, restated: be IN THE DANCE at time t. The dance's clock runs from the episode's start and never stops,
  rewinds or waits - a fall does not pause the music; recovering IS rejoining the dance where it now is. Per decision:

      cost_t = track(s_t, dance_t) + effort(s_t, a_t) + prior(s_t)

  TRACK - SuperTrack's local terms (positions, velocities, two-axis rotations, angular velocities relative to the
    root; heights; the up vector) PLUS global terms (the root's position and heading against the dance's - R4.2's
    drift terms), every one with a shape whose gradient does not vanish far away: L1 as SuperTrack's, or log-cosh
    (quadratic near zero for precision, linear far away). On the dance it is SuperTrack's loss; on the floor three
    metres away it still says where the dance is and how wrong the body is. OPTIONAL and continuous: the local
    terms' weight 1 / (1 + (d / d0)^2), d the root's distance to the dance's - an A/B against the plain sum (the
    long-horizon value may make it unnecessary); a smooth weight, never a threshold.
  EFFORT - the body's limits: per-joint TORQUE LIMITS in the simulator's PD (saturating - a target asking for more
    gets the limit; strengths per joint set from human data, never above what a person has); the MECHANICAL POWER,
    the sum over joints of |torque x angular velocity| (PHC's energy squares it - an A/B); Simon's 0.2 action
    filter. The torques are a known function of the state and the targets (the PD law and its clamp), so the term
    is differentiable through the world model's predicted states: the pathwise loss sees it.
  PRIOR - natural recovery without a discriminator: a differentiable distance to the manifold of real poses - a
    soft-min over the poses of the dance and of `Motion.getup` (LaFAN's fall-and-get-up, already in the assets), or a
    learned distance field to them (Pose-NDF's idea, Tiwari et al. 2022). Near zero all through the dance (its poses
    are on the manifold); along a recovery it pulls the body through kneeling, pushing up and rising - the poses a
    person uses - rather than any pose the physics allows. AMP's role, differentiable, through the same world model.
  WHY THIS GIVES RECOVERY WITHOUT A SWITCH: a fallen character pays TRACK at every decision until it is back, so the
    discounted objective values a fast, cheap, human return - the VALUE TAIL (P1) carries that beyond the window,
    the PLANNER (P5) finds the first get-ups where the gradient alone does not, EFFORT and PRIOR shape them,
    distillation keeps them. The policy always sees the full reference context and the global relative root
    transform - no masking, no mode bit; it learns where each matters.
  ACTIONS - SuperTrack's offsets around the dance's pose (faster and more precise on the dance - their ablation) or
    PHC's absolute targets (indifferent to where the dance is): an A/B on the bench. Offsets with alpha 120 reach a
    get-up's poses, but around a standing reference they start every get-up from the wrong pose.
  THE GYM, reset-free: episodes start at a random dance frame (most near the reference, a set share perturbed);
    perturbations: pushes (cube impacts of growing mass), drops followed by 150 steps of random torques (PHC's
    fallen starts), far starts (2-5 m, any heading), trips mid-dance; no termination by falling, only by length;
    the replay balanced near / far (R5.5's risk 4). If get-ups are not invented: a curriculum from generous to human
    strength and from slow to full speed, as "Learning to Get Up" (Tao et al. 2022) does - to verify when read.

**R5.9 The judge for the north star** (mean time to failure becomes meaningless once a policy recovers):
  PRECISION on the dance from random starts, unperturbed: local and global mean per-joint position error (mm),
    velocity and acceleration errors (PHC's E_vel and E_acc - acceleration exposes jitter), the share of frames
    inside SuperTrack's tolerance (head 25 cm, root 1 m / 90 deg).
  RECOVERY from fallen (dropped, then 150 steps of random torques), far (3 m), fallen-and-far, and mid-dance pushes
    of growing impulse: the share BACK IN THE DANCE - inside the tolerance for a full second - within 5 s and 10 s
    (PHC's Succ-5s and Succ-10s), and how long it takes.
  FLUIDITY: no snap - the peak jerk in the second after re-entry against the dance's own peak jerk.
  REALISM: mean mechanical power; the share of decisions at a torque limit; the prior's distance along recoveries;
    and the morning look, side by side with the get-up capture.
