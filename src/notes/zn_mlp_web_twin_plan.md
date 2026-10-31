# zn_mlp in the browser, against its CPU twin - the plan (v1 DRAFT, Oct 31 2026)

STATUS: DRAFT FOR REVIEW - decisions taken: D1, D2, D3, D4 (section 7). Written under claude.md's "MAKE A PLAN" procedure
(claude.md:146): study, brainstorm every option, pick, write it down here, then ask the open decisions ONE AT A TIME and
revise after each. **Nothing is implemented and nothing will be until Simon says go.** No build or test was run for this
plan (Simon's rule): every claim about the code below was read and is cited `file:line`; every count about the build
cache was counted in `.zig-cache`.

THE ASK (from the session that fixed spv2wgsl's pointer parameters, Oct 31): plan a browser-side check that runs the GPU
learning kit's kernels (`src/gpu/zn_mlp.zig`) as WGSL and compares them with their CPU twin, so that "the next web-only
miscompile in the kit is caught by a page rather than by a training run that quietly learns nothing".

WHY IT IS NEEDED: Vulkan runs zimr's SPIR-V itself; a browser runs the WGSL spv2wgsl makes of it, so a transpiler
miscompile exists on the web alone. Until Oct 31 spv2wgsl lowered a pointer parameter of a non-inline function BY VALUE,
so `zm.CompensatedSum.add(&sum, x)` - `add` takes `self: *@This()` (zimrmath.zig:2225) - lost its writes: `norm_fwd`'s
row sums stayed zero in every browser while vk-host-test, on SPIR-V, stayed green. Nothing compares the kit's WGSL with
anything. The web zn sweep (zimrnum_field) covers `layernorm_rows`, `softmax_rows`, `log_sum_exp_rows` - the same
callee - but no zn_mlp kernel.

WHAT WAS READ: `src/gpu/zn_mlp.zig` (Params, Buffers, every kernel this plan rows, the kernel list), `src/zimrmath.zig`
(CompensatedSum and the row reductions, 2182-2476), `tools/vk_host_test.zig` (all of it; the kit check is 545-1104),
`examples/zimrnum_field/zimrnum_field.zig` (all), `src/gpu/zn_conformance.zig` (Case, the row-wise rows, Fixture,
compare, barFor, its tests), `src/compute_host.zig` (initGpu, upload, run, recording, readGeneration, readLatest),
`src/kit_mlp.zig` (KitNetwork, ClippedAdam, TeacherShares), `src/robot_bmpc_kit.zig` (its shared dispatches),
`src/gpu_learn_tests.zig` (its normed-layer and two-hot known answers, its test list), `src/shader_codegen.zig`
(addComputeOutput), `build.zig` (wireComputeKernels, zn_mlp_entries, the kit pages, zimrnum_field, addVulkanHostTest,
the headless runs, the fast roots), `webtests/runner.mjs` and `webtests/wgpu_smoke.zig` (what the smoke runner can see),
claude.md's rules this plan leans on, `src/notes/robotgpu_plan.md` (its vk-host-test design, 6.14), `zimrnum_plan.md`
(the sweep's timing), and the sibling session's hand-over note on the spv2wgsl fix.


## 0. The goal, stated so it can fail

  G1 RED ON THE BUG IT EXISTS FOR. Built from the tree BEFORE the spv2wgsl pointer-parameter fix, the page marks XX on
     the rows of the eleven kernels whose WGSL lost `CompensatedSum.add`'s writes (1.1), on a WebGPU device; built after
     it, ALL PASS. vk-host-test is green on both trees - the SPIR-V was never wrong - which is exactly the web-only
     signature the page exists to see.
  G2 EVERY KERNEL THAT SUMS THROUGH `CompensatedSum` HAS A ROW, and so does every kernel vk-host-test checks today.
     Every other entry of `zn_mlp.kernels` is named in a written waiver; a kernel added to zn_mlp with neither a row nor
     a waiver does not compile - in the page, in vk-host-test, or in the CPU tests.
  G3 ONE DEFINITION. The dispatches, their data, the regions they write and their bars exist once, in the engine, and
     both hosts run them: vk-host-test's `kit` check (SPIR-V on Vulkan) and the page (WGSL in a browser). Where a
     learner's own code builds a dispatch a row mirrors, a CPU test holds the row to that construction, bit for bit.
  G4 UNDER TWO SECONDS on Simon's phone - at most 240 frames at 120 Hz from the first frame to the verdict
     (claude.md:2397) - and the page prints its own frame count, so the budget is read off the screenshot.
  G5 ONE SCREENSHOT ANSWERS IT: the verdict, the adapter, the frame count, failures first, every row's worst and its
     bar - and on a pass, every row's measured ULPs, so the first device runs calibrate the bars.


## 1. What exists - verified in the code

### 1.1 The bug class, and the eleven kernels it hit

Every zn_mlp entry whose WGSL carried spv2wgsl's `// ERROR: call passes pointer arg ... to a by-value param` marker in
the build cache (the pre-fix translations; 4 copies each), and how each one reaches `CompensatedSum.add`:

| kernel | reaches `add` through | zn_mlp.zig |
|---|---|---|
| `grad_square_partials` | its own `CompensatedSum` | 612, 619 |
| `clip_factor` | its own | 631, 635 |
| `share_factor` | its own | 651, 655 |
| `norm_params_bwd` | its own | 901, 908 |
| `norm_fwd` | `zm.layerNormRowStatistics` (zimrmath.zig:2282) | 741, 748 |
| `norm_bwd` | `zm.layerNormGradientCouplings` (zimrmath.zig:2399) | 930, 941 |
| `simnorm_fwd` | `zm.softmaxGroupStatistics` (zimrmath.zig:2332) | 783, 795 |
| `twohot_fwd` | softmaxGroupStatistics | 1042, 1049 |
| `twohot_bwd` | softmaxGroupStatistics | 1074, 1081 |
| `twohot_decode` | softmaxGroupStatistics | 1109, 1116 |
| `twohot_value_bwd` | softmaxGroupStatistics | 1143, 1150 |

The same marker sat in zn_unary's `layernorm_rows`, `softmax_rows`, `log_sum_exp_rows` (covered by the zn sweep) and
nowhere else; the source agrees - no other zn_mlp kernel and no other zimrmath function a kernel calls takes a pointer.
The fix (uncommitted at this writing): spv2wgsl passes `&name` to a `ptr<function, T>` parameter, and every compute
build now translates with `--strict` (shader_codegen.zig:694-698), so a marker fails the build. `--strict` catches what
spv2wgsl KNOWS it got wrong; this plan is for what it does not know.

### 1.2 The Vulkan kit check (tools/vk_host_test.zig:545-1104)

- `KitStep` (545-550): a kernel name, a `zn_mlp.Params`, a thread count. `KitCheck` (552-1015) holds the sizes, the
  offsets of every region in params/acts/dacts (as `gpu_learn_tests.zig`'s known answers place them), five sequences
  and `fillData` (951-1014): weights, inputs, gains and targets by formulas of their indices; two-hot targets inside a
  pair of bins, on one, and past both ends (0.5, -3, 0, 1e9, -1e9).
- The sequences: the Mish normed layer (9 dispatches: dense_fwd, norm_fwd, mish_fwd, mse_bwd, mish_bwd,
  norm_params_bwd, norm_bwd, dense_bwd_w, dense_bwd_x), the SimNorm layer (the same 9 with simnorm_*), the two-hot head
  (twohot_fwd, twohot_bwd, twohot_decode), the flow policy (8: hashed_uniforms, hashed_noise, copy_columns,
  flow_time_features, flow_path_points, flow_euler_step, flow_dpg_bwd, copy_columns_from_gradients) and the planner
  (mppi_begin, mppi_elites, plan_gather): **32 dispatches over 25 distinct entries.**
- CHAIN MODE (1063-1104): the device and the twin each run a whole sequence, then acts, dacts and grads are compared
  over their used prefix; the sequences overwrite each other's regions by design ("each comparison is of what its
  sequence leaves", 770-771).
- THE BAR: `largestRelativeGap` (1028-1039), |device - twin| / max(1, |twin|), against 1e-5 (1654) - so a value near
  1e-2 is allowed an absolute 1e-5, a thousandth of itself.
- COVERS 7 OF THE 11. `grad_square_partials`, `clip_factor`, `share_factor` and `twohot_value_bwd` are compared with
  their twin on NO device at all: the native trainer runs them on Vulkan with no twin beside it, and the CPU tests
  (gpu_learn_tests) run them on the twin alone.

### 1.3 The web zn sweep (examples/zimrnum_field + src/gpu/zn_conformance.zig)

- One table of 112 rows (`cases`, zn_conformance.zig:165-1750): label, kernel kind and entry, threads, outputs judged,
  input distribution, and the CPU reference inline. The bar is `tol + ulps x peak x eps` (`barFor`, 1984-1986), the
  peak the row's largest reference magnitude; `compare` (1944-1980) reports a finiteness mismatch as infinity and
  takes two NaNs as agreement. Precedents: layernorm rows 64 ulps (459-472), softmax and log-sum-exp rows 16, adam 8,
  most elementwise rows 2.
- The page (zimrnum_field.zig): the pipeline table derived from each file's `kernels` (58-64); a COVERAGE GATE - every
  entry has a row, every row names an entry - as a compile error (68-83, 145-194); an UPLOAD GATE scanning its own
  source for every input buffer's `upload` (84-118); one row per dispatch, retired when `readGeneration().mirrored`
  reaches the dispatch's own number (503-511, 586-617); failures sorted first (659-685); plain text rows, read as a
  screenshot (634-639).
- Its time: 105 rows measured at 1.75 s (zimrnum_plan.md:207) - one row per 16.7 ms - so 112 rows are ~1.9 s, at the
  two-second ceiling already.
- vk-host-test runs the same table on Vulkan, judged "as the zimrnum_field example judges it" (vk_host_test.zig:
  1189-1264): ONE definition, TWO hosts. This plan copies that architecture for the kit.

### 1.4 How the kit's pages get their kernels

- `zn_mlp_entries` (build.zig:3083-3186): 100 names - the same set as `zn_mlp.kernels` (zn_mlp.zig:3860-3961), checked
  line by line for this plan. Each entry is compiled to SPIR-V and translated to its own WGSL (`addComputeOutput`,
  shader_codegen.zig:609-716); a page embeds `<entry>_wgsl` and builds its table from `zn_mlp.kernels`.
- Six pages register all 100: cartpole_duel, track_train, geno_train, getup_train, geno_ppo, geno_lab
  (build.zig:6711-6820). Their standalone pages are 4.7-6.4 MB; zimrnum_field's is 4.3 MB. The cached WGSL of one
  zn_mlp entry is 4-40 KB.
- Every example also gets, with no extra wiring: a smoke run under Node (`smoke-test -Dfocus=`), a NATIVE headless run
  on the machine's Vulkan driver (`<name>-headless`, build.zig:2649, 7122-7153) and a gallery shot.

### 1.5 z.Compute - the mechanics a check depends on (src/compute_host.zig)

- THE TWIN IS A SINGLETON: a CPU pipe's storage is the module's static `zn_mlp.g.B` (459-461; Buffers is 17 MB for the
  pages' sizes, zn_mlp_sizes.zig). A GPU pipe keeps its own buffers and a heap mirror.
- `run` outside a batch or recording is one submission (1384-1397). `beginRecording`/`submitRecording` put many
  dispatches, each with its own params, into one submission (1093-1167).
- `readLatest` copies each field's first `element_count` elements, packed, with ONE copy in flight (1582-1611);
  `readGeneration` says which dispatch the mirror holds (1456). A readback is never sooner than the next frame.
- `upload`/`uploadAt` are queue writes (975-1059), ordered before every later submission - and the smoke runner fails a
  page that writes the same (buffer, offset) twice with no submission between (wgpu_smoke.zig:552-640).

### 1.6 Who builds the kit's dispatches today

Three hand constructions of the normed layer's param blocks, and the host's own:

- `kit_mlp.KitNetwork` (kit_mlp.zig:401-1149) - THE HOST: every learner's layers go through its `forward` and
  `backward` (normAndActivationForward 921-952, normAndActivationBackward 1099-1146).
- `gpu_learn_tests.zig`'s `NormedRegions` and `normedLayerForward/Backward` (831-1018) - the CPU known answers.
- vk_host_test's `KitCheck.normedLayerSteps` (632-750) - the Vulkan check, a copy of the known answers' layout.

The optimisers' dispatches are host functions too: `ClippedAdam.step` (kit_mlp.zig:1475-1518: grad_square_partials in
chunks of 1024, clip_factor, adam_clipped) and `TeacherShares.absorb`/`finish` (1566-1610: grad_square_partials,
share_factor, add_scaled_gradients, gradients_from_sum); so is `decodeTwoHotRows` (robot_bmpc_kit.zig:83-101). The
two-hot loss and gradient, the flow's and the planner's dispatches sit inside larger learner functions.

claude.md:2086-2104: "**The twin must construct its parameters the way the host does**, not the way that makes the
kernel easy to call" - a twin that picks its own parameters verifies a dispatch that never happens.

### 1.7 Where WGSL can run - and where it cannot

- The smoke runner shims every WebGPU call with fresh handles: "it never inspects real GPU results"
  (webtests/runner.mjs:31-34).
- The native hosts - vk-host-test, every `<name>-headless`, the trainer - run SPIR-V. No WGSL compiler or executor
  (Dawn, Tint, naga, wgpu-native) is in the tree.
- No browser runs in the sandbox (platforms_plan.md:1668: Playwright's download host is blocked).
- So WGSL runs only in a real browser on a real device - Simon's phone, his desktop's Chrome - read from a screenshot.

### 1.8 The budget

claude.md:2397-2403: "A DEVICE TEST MUST FINISH IN UNDER TWO SECONDS. Simon runs these by hand on a phone ...
**Budget the frame count, not the work** - the phone is 120 Hz, so 240 frames is the ceiling, and a readback that needs
settle frames costs those frames per row."


## 2. The brainstorm - every axis, every option, the pick and why

### 2.A Where the check runs (D1)

  A1 A NEW PAGE beside zimrnum_field: the kit's rows on the GPU and the twin, a verdict, failures first. Its own budget,
     its own kernel file, nothing moved in the zn sweep. Every example's free extras (1.4) come with it: the native
     headless run proves the page's runner on Vulkan in the sandbox, the smoke run its imports and queue writes.
  A2 ROWS IN zimrnum_field: one page to open for all GPU numerics. But the sweep is at its two-second ceiling (112 rows,
     ~1.9 s); its `Case` is one dispatch with one output against a zimrnum function over a 64 x 64 field, where a kit row
     is a dispatch among others, over five buffers, against the twin; and the page would carry zn_mlp's twin (17 MB of
     wasm memory) and WGSL. Two tables and two runners in one file.
  A3 A SELF-TEST INSIDE EVERY KIT PAGE, run before training: measures exactly where the learner runs ("MEASURE WHERE
     THE CODE RUNS", claude.md:259) and every training session re-proves its device. But it adds frames to six pages'
     start, each page's interface differs, and the twin is the module's one static `zn_mlp.g.B` - it must run before a
     CPU-backed learner touches it. Cheap LATER on top of A1: the rows and the judge are shared code.
  A4 NATIVE / HEADLESS ONLY: vk-host-test already does this; it runs SPIR-V and cannot see a WGSL miscompile.
  A5 HEADLESS CHROME ON SIMON'S WINDOWS MACHINE, `--enable-unsafe-webgpu`, reading the page's verdict line from its
     console: the only way to run WGSL unattended. A tool and a dependency not in the tree; Windows only; a later stage
     on top of A1 (the verdict line 3.7 adds makes it possible).
  A6 A WGSL EXECUTOR IN THE NATIVE TOOLCHAIN (Dawn, or naga to SPIR-V on lavapipe): would put WGSL in the sandbox, at the
     price of a C++ or Rust toolchain in a pure-Zig tree. Rejected.
  A7 CLAUDE'S IN-APP BROWSER on Simon's machine, opening the served page: a way to read a screenshot, not a gate.

  PICK A1 - the only option that runs the WGSL, keeps the zn sweep inside its budget, and adds no dependency. A3 and A5
  are follow-ups it makes cheap (section 6). DECIDED Oct 31 (D1): A1.

### 2.B What builds the dispatches (D2)

  B1 COPY vk's tables into the page. A second hand copy that drifts from the first - the thing claude.md:2086 warns of.
     Rejected.
  B2 SHARE THEM: vk's `KitStep` tables, data and layout move into an engine file both hosts import (as zn_conformance
     is shared today). One definition across the two devices. Still a hand construction beside the host's.
  B3 SHARE THEM, AND HOLD THEM TO THE HOST: B2, plus a CPU test (no device) that runs each row sequence whose host
     counterpart is one callable function - the normed layers (`KitNetwork` forward/backward), the clipped Adam
     (`ClippedAdam.step`), the teacher shares (`TeacherShares.absorb/finish`), the decode (`decodeTwoHotRows`) - on the
     twin both ways and requires the same bits, region by region. A table that drifts from the host fails on the host.
  B4 DRIVE THE HOST'S OWN FUNCTIONS: a dispatch log added to `z.Compute` records `(kernel, params, threads)` as kit_mlp's
     functions run on the twin, and the check replays the log on both pipes. Drift becomes impossible rather than
     detected - but it adds engine machinery, a per-kernel "what does this write" function, and the two-hot, flow and
     planner dispatches have no small host function to call, so tables stay for them anyway.

  PICK B3: it answers "can the tables be shared by both hosts" (yes - they reference only `zn_mlp.Params` and kernel
  names) and closes the "the way the host does" gap where the host has a function to compare against, without new
  engine machinery. B4 stays the upgrade if drift ever bites. DECIDED Oct 31 (D2): B3.

### 2.C One kernel at a time, or a sequence at a time (D3)

  C1 CHAIN, as vk does today: each pipe runs a sequence; compare at its end. Cheapest in readbacks (one per sequence,
     ~10). But a kernel's row also measures every kernel before it - the bars must absorb propagated differences, and a
     failure points at a sequence, not a kernel.
  C2 ISOLATION: before each step, the twin's current buffers are uploaded to the device; both run the ONE step; the
     device's readback is judged against the twin. Every row measures its own kernel from identical inputs ("MEASURE
     THE LINK YOU CHANGED", claude.md:30), so its bar is about its own arithmetic, and the first red row IS the
     culprit. One readback per step (~56 here, 3.9). Exactly what robotgpu's plan specifies for vk-host-test: "every
     kernel on the device against its twin, one step from identical inputs, with ULP bars" (robotgpu_plan.md:1234).
  C3 BOTH: C2's rows plus one chain row per sequence, recorded into one submission as the learners record theirs, at
     vk's 1e-5. Adds the recording path and inter-dispatch ordering on the web - a host/queue class, not the
     transpiler's - for ~10 more readbacks, and a second kind of row.

  PICK C2 on both hosts. It is what makes per-kernel bars meaningful (2.D), and it fits the budget (3.9). C3's chain rows
  are a cheap later addition if the recording path is ever in doubt. DECIDED Oct 31 (D3): C2.

### 2.D The bars (D4)

  E1 vk's: |device - twin| / max(1, |twin|) <= 1e-5. Proven on lavapipe and Simon's GPU; needs no calibration. Loose on
     small values: a gradient of 1e-2 may be off by a thousandth of itself.
  E2 zn_conformance's: each region a step writes is judged against its own peak - worst |device - twin| <=
     ulps x peak x eps - with `ulps` per region (0 for a copy or a selection, 2 for one rounding, 16 for a
     transcendental, 64 for a row statistic), taken from the zn sweep's analogous rows, then CALIBRATED: the page shows
     every row's measured ULPs even on a pass, so the first runs on lavapipe, Simon's GPU, desktop Chrome and the phone
     set each bar to the next power of two at or above twice the worst seen. Tight where values are small; a false red
     costs one round trip, and its screenshot is the calibration data.
  E3 per-element relative ULPs with a floor: no regions needed, but the floor is a guess, and a cancellation near zero
     legitimately fails any floor small enough to matter.

  PICK E2 - the precedent the zn sweep set and the one robotgpu's plan names, and isolation (C2) gives each region a
  bar about one kernel. Everything a step does NOT declare as written must come back bit-identical (isolation uploaded
  it), which catches a stray write anywhere in the buffers at no cost. DECIDED Oct 31 (D4): E2.

### 2.E Which kernels (D5)

  S-a THE ELEVEN ALONE (1.1), with the inputs they need. The smallest page; leaves vk's other 18 kernels unchecked on
      the web although their rows already exist.
  S-b vk's 25, the 4 it lacks among the eleven, their 3 companions in the same host functions (adam_clipped,
      add_scaled_gradients, gradients_from_sum), and the plain dense network every PPO page trains (act_bwd for tanh
      and relu, mse_value, adam): **35 entries in ~56 rows, ~0.9 s.** The other 65 are waived BY NAME in the shared file,
      grouped by learner, so the page prints "35 of 100 kernels rowed" and a new kernel must choose.
  S-c ALL 100 NOW: the zn sweep's standard (every entry rowed). Roughly 130 isolated rows - past 240 frames - so it needs
      a second page or chain mode for part of it, and 65 more kernels' data designed now.

  PICK S-b, and grow by the pages' needs (SAC and SuperTrack's next), splitting into a second page when the frame count
  nears 240 - "the budget is bought back by splitting the sweep when it next grows" (zimrnum_field.zig:487-489).

### 2.F The inputs (D6)

  F1 vk's `fillData` as it is.
  F2 vk's data, plus inputs chosen so that what each kernel exists for can be seen: a normed block whose rows sit at a
     common offset of 1e4 over deviations of order 1 - a plain running sum's mean is then off by ~1e-3, thousands of
     ULPs of the normalised values, so a device whose compensation was lost, optimised away or miscompiled fails the
     row, where vk's well-conditioned rows cannot tell compensated from plain; a clip with the norm past its limit
     AND one within it (factor exactly 1); a zero-length teacher (share factor exactly 0); the two-hot loss with a
     counting mask and the identity axis; the decoded value's slope with row weights. "A test's input distribution
     decides which bugs it can see" (zn_conformance.zig:158-161).

  PICK F2 - all of it in new rows; vk's existing rows keep their data, so the move stays a pure refactor (stage S1).

### 2.G The red proof (D7)

  R1 THE REAL BUG: build the page (and its shared files) on the commit before the spv2wgsl fix - its compute builds were
     not strict, so the broken WGSL builds - and open it on a device: the eleven rows must be XX, the rest OK; then on
     the fixed tree, ALL PASS. One extra build and device run, and the check is shown to catch the thing it is for.
  R2 A PLANTED FAULT: a debug switch that perturbs the device's input for one step. Proves the judge can fail, not that
     the check sees the bug class.
  R3 A JUDGE TEST ON THE CPU: perturb one written value past its bar, and one unwritten value by one bit, in a twin
     result: both rows must fail, the unperturbed one pass. No device; proves the judge is not self-referential
     (claude.md:115).
  None: a check never seen red is the tell claude.md:115 names.

  PICK R1 + R3.

### 2.H Smaller choices - picked, listed for confirmation

  - WHERE THE SHARED ROWS LIVE: `src/gpu/kit_conformance.zig`, re-exported by zn_conformance.zig as `kit`. Both hosts
    already import `zn_conformance` (wireComputeKernels offers it to every compute page, build.zig:2989-2998;
    addVulkanHostTest wires it, 2260-2264), so NO build wiring; it shares `compare` and the bar formula in-module; and
    gpu_learn_tests (a fast root that imports zn_mlp by path) imports `gpu/zn_conformance.zig` by path for the CPU
    tests. Generic over the kernel module (`Rows(comptime M: type)`): a page's zn_mlp is a named module created per
    app, so the shared file must not import it. (A module of its own needs wiring in three places; a file in the zimr
    module is needed only by B4.)
  - WHAT THE PAGE REGISTERS: only the rowed kernels' WGSL (`initGpu` takes any list, compute_host.zig:568-572); the
    build entry list stays `zn_mlp_entries` - the translations are shared with the kit pages. Smaller page, faster init.
  - NAME: `kit_sweep` - "the kit sweep", as the zn sweep is zimrnum_field's. Title "zimr - the learning kit's kernels
    against their CPU twin".
  - A VERDICT LINE in the log when done (`kit sweep: ALL PASS 56/56 in 74 frames`): read in the browser's console and in
    the headless run's output; what A5 would read.


## 3. The design - the picks, assembled

### 3.1 Files

  NEW  src/gpu/kit_conformance.zig     the rows: layout, data, steps with their written regions and bars, the judge,
                                       the gate - generic over the kernel module, no import of it
       examples/kit_sweep/kit_sweep.zig  the page
  EDIT src/gpu/zn_conformance.zig      `pub const kit = @import("kit_conformance.zig");` and a `barOf(tol, ulps, peak)`
                                       that `barFor` and the kit judge both call
       tools/vk_host_test.zig          KitStep/KitCheck/runKitKernels/largestRelativeGap go; the `kit` check runs the
                                       shared rows in isolation
       src/gpu_learn_tests.zig         the rows' CPU tests (3.8)
       build.zig                       the page's App entry (compute_kernels: zn_mlp, `zn_mlp_entries`)
       src/notes/claude.md             the setup section's line on vk-host-test's kit check; the examples catalog row

### 3.2 A row

    pub fn Rows(comptime M: type) type      // M = zn_mlp
        Field   = FieldEnum(M.Buffers)
        Region  = { field: Field, at: u32, count: u32, ulps: f32 }       // what a step writes, and its bar
        Step    = { label: []const u8, kernel: [:0]const u8, params: M.Params, threads: u32, writes: []const Region }
        Sequence = { name: []const u8, steps: []const Step }
        sequences: [_]Sequence              // run in order on the twin; each step judged alone (C2)
        layout constants, fillData(params, acts, grads, adam_m, adam_v)
        element_count                       // every region's end: what both pipes upload and read back
        judge(step, device: Views, twin: Views) Verdict
        rowed_kernels, waivers, must_row    // the gate

A row is a Step. Every region a step's kernel writes is declared, sized from its params, with its own ulps - so an exact
part (mppi_elites' candidate numbers) and a rounded part (its weights) are judged apart.

### 3.3 The rows

Initial ulps below; calibration (2.D) replaces them with measurements. vk's 32 move UNCHANGED in S1 and gain their
regions and bars in S2; the rest arrive in S3.

| sequence | steps (kernel: what it writes) | ulps |
|---|---|---|
| Mish layer (vk; 3 rows, 6 -> 16) | dense_fwd: acts linear [48]; norm_fwd: normalised [48], scaled [48], inverse spreads [3]; mish_fwd: output [48]; mse_bwd: dacts output gradient [48]; mish_bwd: scaled gradient [48]; norm_params_bwd: grads gains + norm biases [32]; norm_bwd: dacts linear gradient [48]; dense_bwd_w: grads W, b [112]; dense_bwd_x: dacts input gradient [18] | dense 16, norm_fwd 64, mish 16, mse_bwd 2, norm_params_bwd 16, norm_bwd 64 |
| SimNorm layer (vk) | the same, simnorm_fwd / simnorm_bwd (one thread per group of 8) | simnorm 16 |
| two-hot head (vk; 5 rows, 101 bins) | twohot_fwd: acts losses [5]; twohot_bwd: dacts logit gradient [505]; twohot_decode: acts values [5] | 16, 16, 64 (symexp of up to 10) |
| flow policy (vk; 8 steps) | each kernel's documented output: times, noise and copied columns of the wide rows, time features, path points and velocities, the Euler step, FlowDPG's gradient | 0 copies; 2 lerp and Euler; 16 hash-to-noise, sin/cos, FlowDPG |
| planner (vk; 3 steps) | mppi_begin: means [16], spreads [16]; mppi_elites: candidate numbers [8], weights [8]; plan_gather: blocks, goals | 0 shifts, numbers and gathers; 16 weights |
| clipped Adam (new; mirrors ClippedAdam.step) | over 1,100 planted gradients - the host's two 1,024-float chunks, the second partial: grad_square_partials: partials [2]; clip_factor (limit 20, norm past it): norm, factor [2]; clip_factor (limit 1e6: factor exactly 1) [2]; adam_clipped (step 5's corrections from `zn.adamCorrectionMultipliers`, element clip 0.05): params, adam_m, adam_v [1,100] each | 16, 16, 16, 8 |
| teacher shares (new; mirrors TeacherShares) | absorb teacher 1 (share 0.6, first): grad_square_partials, share_factor, add_scaled_gradients (col 0); gradients_from_sum loads a ZERO gradient; absorb it (share 0.4): share_factor's factor exactly 0, add_scaled_gradients (col 1) adds exactly nothing; finish: gradients_from_sum | 16, 16, 2, 0 |
| two-hot branches (new) | twohot_fwd and twohot_bwd with a counting mask [1, 0, 1, 1, 0], the identity axis on [-5, 5] and loss weight 0.5; twohot_value_bwd with row weights and loss weight 0.7: dacts slope [505] | 16, 16, 64 |
| ill-conditioned norm (new) | norm_fwd, norm_params_bwd, norm_bwd on a 3 x 16 block at 1e4 + O(1), a planted arriving gradient | 64, 16, 64 |
| dense network (new; KitMlp's and PPO's layers) | dense_fwd with tanh, act_bwd (tanh), dense_fwd with relu, act_bwd (relu), mse_value: loss[0], adam (step 5, warm moments) | 16, 2, 16, 0, 64, 8 |

~56 steps over 35 entries. The new regions follow vk's in each buffer (acts ~3,700 floats in all, dacts ~1,900,
params/grads/moments ~1,250), so `element_count` is ~3,700 and a readback copies ~100 KB.

THE WAIVERS - the 65 entries not rowed, named in the shared file under their learner, each group with its reason:
SAC (squash_fwd, squash_logp, sac_target, min_route, squash_bwd, squash_logstd_grad, alpha_grad, polyak); PPO's head
(ppo_mean_grad, ppo_logstd_grad); SuperTrack on the cartpole (cp_wm_input, cp_wm_input_bwd, cp_force, cp_force_bwd,
cp_step, cp_step_bwd, cp_track_bwd) and fused (st_policy_fwd, st_policy_bwd, st_world_fwd, st_world_bwd, st_reduce); the
latent model (add_block, lat_advance, lat_take, lat_gather, lat_act, lat_act_bwd, lat_barrier_bwd, lat_tracking_cost,
lat_skip_gather, lat_skip_targets, lat_scale_columns); EfficientTDMPC's rest (place_columns, take_columns,
policy_distill_bwd, policy_divergence, running_scale_update, policy_draw, value_target_combine, mask_values,
mask_gradients, broadcast_rows, plan_score_combine, copy_row_blocks, mppi_sample, mppi_refit, mppi_choose, mppi_explore,
ensemble_tail_weights, plan_mailbox); the flow's teachers and statistics (synergy_decode_add, synergy_project_gradient,
flow_draw_losses, fpo_advantages, fpo_velocity_gradient, fpo_normalize_advantages, fpo_ratio_stats, stat_root_mean_square,
stat_mean_square_difference, stat_mean_and_deviation, stat_copy, critic_value_stats, stat_barrier, plan_gain_stats).

### 3.4 The judge

For one step, given the device's and the twin's buffers after it (each field's first `element_count` values):

  1. Each declared region: `compare` (zn_conformance's - a finiteness mismatch is infinity, two NaNs agree) gives its
     worst and its peak; its bar is `barOf(0, region.ulps, peak)`. The row fails if any region's worst passes its bar.
  2. Everything else: bit for bit (NaN agreeing with NaN). Isolation uploaded it, the twin did not touch it, so any
     difference is a write the step should not have made - reported as the first stray (field, index).
  3. The verdict carries, for the region nearest its bar: worst, bar, and worst / (peak x eps) - the MEASURED ULPs the
     page shows for calibration.

### 3.5 The gate (a compile error, wherever `Rows(M)` is instantiated)

  - Every name in `M.kernels` is in exactly one of: the kernels the steps dispatch, the waivers.
  - Every step names an entry `M.kernels` holds.
  - `must_row` (the eleven of 1.1) are all rowed - none may be waived.

### 3.6 The two runners - one shape, two kinds of waiting

    twin: initCpu; device: initGpu (Vulkan: the file's SPIR-V; web: each rowed entry's WGSL)
    both: element_count; the twin gets fillData's buffers
    for each sequence, for each step:
        upload the twin's buffers to the device (every field's prefix)    // isolation (C2)
        both run the step; remember the device's `readGeneration().submitted`
        wait until the device's mirror holds it     // vk: poll, as deviceReadback does; page: across frames
        judge(step, device's readback, twin's buffers)

vk-host-test's `kit` check prints each failing row with its numbers and one summary line - "kit: 56 rows within their
bars; the nearest norm_bwd (SimNorm layer) at 9 of 64 ulps" - replacing "largest relative gap".

### 3.7 The page (examples/kit_sweep/kit_sweep.zig)

  - A state machine over the steps, one step a frame at most: upload, dispatch, then wait for the step's own
    generation, judge, and in the same frame start the next.
  - Plain text rows (zimrnum_field.zig:634-639): "OK  SimNorm layer: norm_bwd   3.1 / 64 ulps", a failing row adding
    its absolute worst and bar; failures sorted first; drag and wheel to scroll (copied from zimrnum_field).
  - Header: the verdict ("kit sweep - 23/56" amber, "ALL PASS - 56/56 agree with the CPU twin" green, "3/56 FAIL"
    red); the adapter (`wgpu.adapterInfo`, wgpu.zig:687); "35 of 100 kernels rowed"; the frames and seconds from the
    first frame to the verdict.
  - A re-run button below the rows, as zimrnum_field's.
  - The verdict line in the log when done.

### 3.8 Tests with no device (src/gpu_learn_tests.zig, test-fast)

  T1 DECLARED WRITES ARE WHAT THE KERNELS WRITE: each step on the twin; every value that changed lies in a declared
     region, and some value of the step's regions changed. A wrong region fails here, not on a phone.
  T2 THE JUDGE CAN FAIL (R3): a written value pushed past its bar and an unwritten value moved by one bit each fail
     their row; the untouched result passes.
  T3 THE ROWS ARE THE HOST'S (B3), bit for bit on the twin: the two normed layers against `KitNetwork` forward and
     backward of the same layer (one `NormedDense`, the rows' weights written in by `writeParams`); the clipped Adam
     against `ClippedAdam.step`; the teacher shares against `TeacherShares.absorb/finish`; the decode against
     `decodeTwoHotRows`.
  The gate (3.5) compiles in this root too, so a new kernel without a row or a waiver fails `test-fast` first.

### 3.9 Budget arithmetic

At the zn sweep's measured pace - one readback-bound row per 16.7 ms (1.3) - 56 rows take ~0.93 s, ~112 frames at
120 Hz; at three frames a row, 168 frames, 1.4 s. Init (one GPU pipe of 35 pipelines, the twin's static buffers) comes
before the first frame, as zimrnum_field's 112 references and four pipes do. Growth headroom at three frames a row:
~80 rows, then a second page.


## 4. Stages - each ends in a check that can come out red

Claude edits and runs only `zig fmt --check`, `zig ast-check` and the built zimrlint; Simon runs every build and test.

  S1 MOVE, NOTHING ELSE. KitStep, the layout, the sequences and fillData move to kit_conformance.zig; vk_host_test
     imports them; chain mode and the 1e-5 bar unchanged.
     Check: `zig build vk-host-test` prints the SAME "largest relative gap" to the last digit as before the move -
     here identical output is the proof (Simon's last pre-move number recorded first).
  S2 STEPS BECOME ROWS. Labels, written regions and ulps; the judge; the gate with its waivers; isolation in
     vk_host_test; T1 and T2.
     Check: `zig build test-fast -Dfast-root=src/gpu_learn_tests.zig` and `-Dfast-root=src/gpu/zn_conformance.zig`;
     `zig build vk-host-test` on Simon's GPU (and lavapipe in a Linux sandbox) - every row within its bar, the measured
     ULPs read off and the initial bars corrected before S4.
  S3 THE NEW ROWS (3.3's six new sequences) and T3.
     Check: the same two commands. T3 red on purpose once - one row's param changed - to see it fail.
  S4 THE PAGE: kit_sweep.zig, its App entry.
     Check: `zig build smoke-test -Dfocus=kit_sweep` (imports declared, no same-frame clobber);
     `zig build kit-sweep-headless` - ALL PASS on Vulkan through the page's own runner, its verdict line printed;
     `zig build kit-sweep -Dplatform=web`, then the page on Simon's phone and his desktop's Chrome.
  S5 CALIBRATE AND PROVE. From S4's screenshots set every bar (2.D). Then R1: a worktree at the commit before the
     spv2wgsl fix, with S1-S4's files, the page built and opened on the phone - the eleven rows XX, the other rows OK;
     vk-host-test green on the same tree. Then the fixed tree: ALL PASS, under 240 frames.
  The plan is done when S5's two screenshots exist and the journal holds their numbers.


## 5. Risks

  - A FALSE RED ON A PHONE: a bar tighter than the phone's exp, divide or fused multiply-add. Mitigated by showing the
    measured ULPs on every row and treating the first runs as calibration (2.D); a red screenshot carries its own fix.
  - THE BUDGET ON A SLOW PHONE: if a readback takes four frames, 56 rows are 224 frames - inside 240, barely. The page
    prints its frame count; past 200, split the sweep (2.E).
  - THE TWIN'S SINGLETON: the page must not create a second CPU pipe on zn_mlp; it holds exactly one.
  - PIPELINE COMPILATION ON THE FIRST DISPATCH: Chrome may compile a pipeline when it is first used, so the first
    sequences' readbacks may take longer - counted in the frames, which is the honest measure.
  - A WAIVER LIST THAT HIDES: a waiver is a decision written down, not a check. The page prints "35 of 100 kernels
    rowed" so the gap stays on screen.
  - THE REFACTOR CHANGES vk-host-test's VERDICT: S1 is a pure move proven by identical output; isolation and the ULP
    bars arrive in S2 with their own measurement.


## 6. Not in this plan - follow-ups it makes cheap

  - The 65 waived kernels, by page priority (SAC and SuperTrack first), and a second page when the frames near 240.
  - A3: a kit page running the sweep before it trains, refusing a device that fails.
  - A5: a headless-Chrome run on Simon's Windows machine reading the verdict line, for an unattended WGSL check.
  - C3: a chain row per sequence, recorded into one submission, for the recording path on the web.
  - gpu_learn_tests' own `NormedRegions` helpers replaced by the shared rows (a third copy of the normed layer's layout
    today).
  - spv2wgsl hand-over items that are not this plan's (OpNot on integers, OpCopyObject of a pointer, the corpus walk's
    last-entry-only translation) - listed in the sibling session's note.


## 7. Decisions - asked one at a time

Each is asked with its options, their pros and cons and the recommendation; the plan is revised after each answer, and
the whole list confirmed before the plan is called final. Nothing is implemented before Simon says go.

DECISIONS TAKEN:

  - D1 (Oct 31): A1, A NEW PAGE beside zimrnum_field - the kit's rows on the GPU and the twin, its own two-second
    budget, the zn sweep untouched. A3 (a self-test in the training pages) stays a follow-up (section 6).
  - D2 (Oct 31): B3, SHARE THE TABLES AND HOLD THEM TO THE HOST - vk's KitStep tables move into the engine file both
    hosts import, and a CPU test (T3) runs each row sequence with a callable host twin - KitNetwork forward and
    backward, ClippedAdam.step, TeacherShares.absorb/finish, decodeTwoHotRows - both ways, bit for bit.
  - D3 (Oct 31): C2, ISOLATION ON BOTH HOSTS - before each step the twin's buffers go up to the device, both run that
    one step, and it is judged at once; vk-host-test's chain mode goes (after S1's pure move proves the tables moved
    intact).
  - D4 (Oct 31): E2, PER-REGION ULPs OF THE REGION'S OWN PEAK, CALIBRATED - initial ulps from the zn sweep's analogous
    rows; every row's measured ULPs shown even on a pass; the first runs on lavapipe, Simon's GPU, desktop Chrome and
    the phone set each bar. Everything a step does not declare as written comes back bit-identical.

| # | decision | recommendation | where |
|---|---|---|---|
| D1 | where the check runs | DECIDED: A1, a new page (`kit_sweep`) | 2.A |
| D2 | what builds the dispatches | DECIDED: B3, vk's tables shared, held to the host's functions by CPU tests | 2.B |
| D3 | one kernel at a time or a sequence at a time | DECIDED: C2, isolation, on both hosts | 2.C |
| D4 | the bars | DECIDED: E2, per-region ULPs of the region's own peak, calibrated on the first runs | 2.D |
| D5 | which kernels | S-b: 35 entries in ~56 rows, the other 65 waived by name | 2.E |
| D6 | the inputs | F2: vk's data plus rows built to make each kernel's purpose visible | 2.F |
| D7 | the red proof | R1 + R3: the pre-fix build on a device, and a CPU judge test | 2.G |
| -- | smaller choices (file, registered kernels, name, verdict line) | as picked | 2.H |


## 8. Journal

- Oct 31: v1 drafted. Studied the Vulkan kit check, the zn sweep page and its table, z.Compute's readback, the host's
  kit functions and the build's kernel wiring. Counted in the cache: the eleven zn_mlp entries with the pointer-argument
  marker (1.1); `zn_mlp_entries` and `zn_mlp.kernels` agree (100). Found while studying: four of the eleven
  (grad_square_partials, clip_factor, share_factor, twohot_value_bwd) are compared with their twin on no device at all,
  Vulkan included. Next: D1.
- Oct 31: D1 decided - A1, a new page. Next: D2.
- Oct 31: D2 decided - B3, shared tables held to the host by CPU tests. Next: D3.
- Oct 31: D3 decided - C2, isolation on both hosts. Next: D4.
- Oct 31: D4 decided - E2, per-region ULP bars, calibrated. Next: D5.
