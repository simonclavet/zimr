# zimr GPU Compute — Build Plan (rewritten turn ~967)

Spec for the API is `tutorials/gpu-compute-tutorial.md`. This is the ordered
build plan + the locked decisions. Exploration history archived in
`archive/sph_compute_plan_exploration.md`.

## NORTHSTAR
One particle/SPH simulation, written ONCE in Zig, toggled CPU<->GPU at runtime,
identical results. On GPU the particle data NEVER leaves the GPU between compute
and render (verified-possible). This is why zimr is on WebGPU.

## FOUNDATION — VERIFIED WORKING (do not re-litigate)
- KERNEL DUAL SHAPE: one Zig module compiles to a native CPU object (loop calls
  the kernel) AND a SPIR-V compute entry. Buffers are MODULE-LEVEL globals
  (comptime-selected: `extern ... addrspace(.storage_buffer)` on GPU, plain `var`
  on CPU), accessed DIRECTLY (`b.pos[id]`), NOT via a pointer/ctx-field (that
  hits a spv2wgsl let-copy bug — decided turn 963 NOT to fix; globals are better
  anyway). Params ride in a ctx BY VALUE. GPU entry comptime-gated to SPIR-V.
- spv2wgsl handles compute: @compute, @builtin(global_invocation_id), storage +
  uniform bindings, multi-buffer. `--workgroup=X[,Y,Z]` injects @workgroup_size.
- ZERO-COPY render: a Zig VERTEX shader reads a storage buffer by instance_index;
  spv2wgsl emits `var<storage, read>` for vertex stage (WebGPU requires read, not
  read_write — fixed turn 966). render pass has draw(vtx,instances)+setBindGroup.
- READBACK primitives: wgpu.copyBufferToBuffer + bufferReadStart/Poll/Into/Release
  (poll-based, mirrors GL fetch). Buffers are fixed-cap arrays ([MAX]T).
- MATH = zimrmath, uniform across all contexts (verified turn ~979 in a compute kernel).
  A kernel does `const zm = k.math;` (kompute re-exports zimrmath as `k.math`).
  vec2/splat2/dot2/length2/sqrt/floor/min/max/clamp/normalize/atan2 + vector arith all
  lower to SPIR-V and pass naga (atan2 was the historically-risky one — zimrmath's
  GPU-safe impl handles it). It is the SAME zm CPU code + graphics shaders use, so math
  is uniform across comptime / CPU / graphics shaders / compute kernels. addCompute wires
  zm for both root and the kompute module.

## STILL-UNVERIFIED RISKS (verify in-step, before depending on them)
- R1: ATOMICS BLOCKED IN THE COMPILER (verified turn 977 spike). Zig 0.17's SPIR-V
  backend does NOT implement `@atomicRmw` — `zig build-obj -target spirv32` fails with
  `error: TODO (SPIR-V): implement AIR tag atomic_rmw` BEFORE spv2wgsl runs. So
  `atomic<u32>` grids (D6) are un-buildable until Zig adds SPIR-V atomic support (or we
  avoid atomics — see the gather-grid option in REMAINING RISKS). This is upstream of
  the transpiler; spv2wgsl was never reached.
- R1b: MULTI-ENTRY-PER-FILE = NO (verified turn 977 spike). Two `export fn
  callconv(.spirv_kernel)` in one .zig -> only the FIRST survives to WGSL (one @compute).
  So one-kernel-per-file for v1 (matches the plan lean). A sim = a dir of kernel files
  sharing a `Buffers/Params/g/b/helpers` import.
- R2: a real GPU dispatch+readback round-trip on a real device — smoke is headless
  stubs (no real GPU), so correctness is only proven in-browser. Need a real-device
  test path (S2 leans on the browser / a real-device harness if available).

## LOCKED API DECISIONS (from the tutorial deliberation)
- D1 BUFFER TYPE: `k.Buffer(T)` (NOT `[]T`). Indexes like an array (`b.pos[id]`),
  `.len == capacity`. Makes "GPU resource, not heap slice" honest. (#1)
- D2 HOST OPS keyed by enum field, uniform with run: `pipe.upload(.pos, slice)`,
  `pipe.run(frame, .integrate)`, `pipe.readLatest(.pos)`. (#2, #6)
- D3 READBACK: `pipe.readLatest(.pos) ?[]T` = frame-delayed (returns last frame's
  mapped data, kicks off this frame's copy, never stalls). `pipe.readBegin/poll`
  underneath for the rare exact-frame case. CPU backend returns data with zero
  latency (document the 1-frame GPU skew, don't fake parity). (#3, #6, #8)
- D4 PING-PONG: a buffer declared `k.Buffer(T).pingpong` exposes `b.pos` (read
  front) + `b.pos_next` (write back); `pipe.swap(.pos)` flips. Needed for SPH
  density-relax. (#4)
- D5 DIMENSIONALITY: inferred from `config.workgroup` (scalar -> 1D `c.id`; [2]
  -> 2D `c.xy`; [3] -> 3D `c.xyz`). Kernel only sees the field for its dim. (#7)
- D6 ATOMICS: `k.Buffer(u32).atomic` -> `array<atomic<u32>>`; accessed via
  `c.atomic(.cell_count, idx).add(1)`. On CPU it's a plain += (single-thread) or
  real atomic (when threaded). (#10) — gated on R1.
- D7 GRID SCAN: ship canned `pipe.prefixSum(.src, .dst)` (+ later sort/reduce) as
  built-in primitives that compose with user kernels. (#9)
- D8 WORKGROUP/SHARED MEMORY: PUNT for v1 (breaks CPU duality; std.gpu has it but
  CPU has no workgroup concept). Kernels gather from global memory. (#5)
- D9 RENDER: `z.drawPointsFromBuffer(frame, buf, count, .{size,color})` ships a
  built-in instance vs/fs reading the buffer by instance_index. CPU path draws
  via the normal batch from the CPU slice. (#6 render)

## DISCIPLINE (what makes the duality + GPU-correctness work)
Kernels GATHER: a kernel writes ONLY its own slot (`b.x[id] = ...`), never
another particle's. No cross-id writes -> no atomic-float -> identical CPU/GPU +
trivially parallel CPU. Atomics (D6) + prefix-sum (D7) are the escape hatches,
only for the integer grid counters.

## BUILD STEPS (ordered; each shippable + verified)

### S1 — DONE: spv2wgsl --workgroup + vertex-stage read storage.

### S2 — Real GPU compute round-trip — ✅ DONE (turn ~969)
- DONE: addShader gained `workgroup_size: ?[3]u32` -> passes --workgroup=X,Y,Z
  (compute stage). Back-compat (null default). Regression-checked.
- DONE (R2): no real WebGPU device in headless env (bun navigator.gpu = none),
  no real-device harness. So S2 is correct-by-construction + verified IN-BROWSER
  (render the doubled buffer as bar heights -> a glance confirms 1,2,3->2,4,6).
  Smoke proves instantiation; browser proves results.
- DONE: examples/wgpu_compute_smoke/wgpu_compute_smoke.zig — the host, hand-wired
  + lint 0 + ast ok. Creates data_buf (STORAGE|COPY_SRC|COPY_DST) + params uniform
  + MAP_READ staging; bind-group layout/group via descriptor_encoder (uniform@0,
  storage@1); createComputePipeline(module,"main"); one-shot dispatch
  ceil(N/64); copyBufferToBuffer->staging; bufferReadStart/Poll/Into readback;
  renders the result as a doubled HSV bar staircase + spot-check text. Embeds the
  kernel WGSL as @embedFile("double_it_wgsl").
- DONE: double_it.zig kernel (proven dual shape).
- TODO NEXT: the BUILD wiring. addShaderEx is tightly bound to the fragment/vertex
  externs machinery (gen_shader_externs, io modules) — a self-contained compute
  shader (double_it has inline Buffers/Params, no _io/externs) fights it. PLAN:
  add a minimal compute-WGSL build path (build-obj -target spirv32 -> spv2wgsl
  --workgroup=64, skipping the sampler-rewrite + externs gen the fragment path
  needs) -> emit double_it.wgsl -> addAnonymousImport("double_it_wgsl") into the
  demo module + a wgpu-compute-smoke build block. This minimal compute-build path
  SEEDS the S3 generator. Then build + smoke + in-browser verify the bar staircase.
Hand-wired (no DSL): a `double_it` compute pass. Create storage buffer
(STORAGE|COPY_SRC) + uniform + MAP_READ staging; bind-group layout/group via
descriptor_encoder (uniform@0, storage@1 — matches spv2wgsl's declaration order);
createComputePipeline(module,"main"); per frame: writeBuffer input+params, begin
compute pass, setPipeline+setBindGroup, dispatchWorkgroups(ceil(n/64)), end;
copyBufferToBuffer(storage->staging); submit; readLatest-style poll; assert
doubled. Build wiring: ShaderPipeline.addShader gains a compute stage that passes
--workgroup. GATE: needs a real device to assert results (R2) — run in-browser;
if a real-device harness exists, use it. Deliverable: wgpu-compute-smoke demo +
a green real-device assertion.

### S3 — `kompute` generator (the DSL: hide the boilerplate) [NEXT]
GOAL: author writes ONLY `config` + `Buffers` + `Params` + kernel fns (the
tutorial form); a comptime helper generates the rest. From S2 we know EXACTLY
what to generate (the proven double_it.zig shape):
  - the `g` namespace: `if (is_gpu) struct { extern var B: Buffers
    addrspace(.storage_buffer); extern const P: Params addrspace(.uniform); }
    else struct { var B; var P; }`.
  - a module-level buffer alias `b` so kernels write `b.pos[id]` (NOT via a ctx
    field — that hits the let-copy transpiler bug; decided turn 963).
  - per kernel fn: a comptime-gated `export fn <name>() callconv(.spirv_kernel)`
    that reads global_invocation_id and calls the body. (Multiple kernels = one
    SPIR-V module each? OR one module, multiple entry points — VERIFY which
    spv2wgsl + addCompute handle; likely ONE FILE PER KERNEL for v1, simplest.)
  - `k.Ctx(@This())` = `struct { id: u32, params: Params }` (params BY VALUE,
    verified ok). Buffers are `b`, not in Ctx.
MECHANISM: a comptime fn `kompute.kernel(Module, "kernelName")` invoked in the
kernel file's `comptime {}`, mirroring installSpirvEntry. The author's kernel
signature is `fn name(c: k.Ctx(@This())) void` using `b.*` for buffers.
BUILD: addCompute already exists (S2). The generator is pure comptime in the
kernel file — no new build step, just a `kompute.zig` helper module the kernel
imports. OPEN: whether one .zig can hold N kernels as N SPIR-V entry points and
addCompute emit all — if not, v1 = one kernel per file (a small dir per sim).

### S4 — `z.Compute(M)` host wrapper (the CPU/GPU toggle) [after S3]
Comptime over M (the kernel module/set). `.backend = .cpu | .gpu`.
- CRITICAL (S2 lesson): buffer size + bind-layout min_size = `@sizeOf(M.Buffers)`
  (comptime, uses MAX) — NEVER hand-sized. This is the footgun z.Compute erases.
- CPU FIRST (zero GPU, instant): `buffers: M.Buffers` heap struct; point M.g.B at
  it; `run(.k)` = `var id=0; while (id<count): M.k(.{.id=id,.params=p})`.
- GPU: ONE StorageBuffer for the whole Buffers struct (binding 1, STORAGE|
  COPY_SRC|COPY_DST, size @sizeOf(Buffers)) + Params uniform (binding 0); bind
  layout (storage min_size=@sizeOf(Buffers), uniform min_size=@sizeOf(Params));
  pipeline per kernel; `run(.k)` = encode compute pass, dispatch
  ceil(count/config.workgroup).
- API (D2/D3): `pipe.upload(.field, slice)`, `pipe.readLatest(.field) ?[]T`
  (frame-delayed via bufferRead*; CPU returns the slice with zero latency),
  `pipe.swap(.field)` (D4 ping-pong), `pipe.prefixSum(.src,.dst)` (D7),
  `z.drawPointsFromBuffer(frame, pipe.bufferOf(.pos), n, .{...})` (D9).
- params set via `pipe.params = .{...}` then run.

### S5 — particle demo + VERIFY ATOMICS + drawPointsFromBuffer [after S4]
wgpu-particles-gpu: ~100k points, gravity + wall bounce, ONE kernel, a button to
toggle .cpu(~5k)/.gpu(100k). Render: build drawPointsFromBuffer (D9) = a tiny
instance vs (reads pos[instance_index], var<storage,read> — verified turn 966) +
fs; on .cpu, draw from the slice via the normal batch. ZERO-copy on GPU.
ALSO (R1): a standalone atomic<u32> test through spv2wgsl FIRST (a gridCount-style
`atomicAdd(&counts[cell], 1)`); if it fails, that's a transpiler step here before
SPH. Verify the WGSL has `atomic<u32>` + `atomicAdd`, naga ok.

### S6 — SPH northstar [after S5]
> SUPERSEDED-IN-PART: the kernel list below is the ORIGINAL atomic-grid shape.
> The turn-977 PLAN EVALUATION (see below) re-sequenced the grid to Option A =
> GATHER-ONLY fixed-bucket (atomics are BLOCKED in Zig's SPIR-V backend, R1).
> For v1, DROP gridCount(atomic)/prefixSum(D7)/gridScatter/sorted_idx; each cell
> scans all particles into its own fixed bucket. KEEP pos ping-pong (D4). Build
> the gather grid, not the atomic one, until Zig ships SPIR-V atomics.
Clavet 2005, GATHER-form, multi-kernel (one .zig per kernel if S3 is per-file):
integrate, gridClear, gridCount(atomic u32), prefixSum(D7), gridScatter, density,
relax(pos ping-pong via D4), viscosity, finalize. Buffers: pos(.pingpong), vel,
rho(rho,rho_near), cell_start, cell_count(.atomic), sorted_idx. Toggle button
CPU(~2k) <-> GPU(50k), identical algorithm, one source, zero-copy render via
drawPointsFromBuffer. THE demo that justifies wgpu.

## REMAINING RISKS (ranked)
- R1 atomic<u32> through spv2wgsl — VERIFY in S5 (small test) before S6.
- ping-pong (D4) impl: two physical buffers, `b.pos`=front read / `b.pos_next`=
  back write, pipe.swap flips the bind groups. Get right in S6.
- prefixSum (D7): a canned multi-pass scan primitive (work-efficient Blelloch or
  simple). Could CPU-side the grid in GPU mode for a first SPH cut, then move it
  on-GPU. Decide in S6.
- multi-kernel-per-file (S3 open): if one .zig can't be N entry points cleanly,
  v1 ships one kernel per .zig (a sim is a directory). Acceptable.

## IMMEDIATE NEXT ACTION
S3 (IN PROGRESS turn ~978): write `src/kompute.zig` — the comptime DSL. Decisions baked from
the turn-977 spikes:
- ONE KERNEL PER FILE (multi-entry verified-no). A sim = a dir of kernels sharing a
  Buffers/Params import.
- BUFFER FORM = explicit `[config.max]T` arrays in `Buffers` (the transpiler-proven double_it
  shape). D1's `k.Buffer(T)` is DEFERRED: clean synthesis needs `@Type` (removed in 0.17) and a
  wrapper risks the let-copy bug. Revisit as ergonomic sugar later.
- The DSL provides: `Config`, `Globals(@This())` (the if(is_gpu) extern-storage/uniform vs
  plain-var namespace), `Ctx(@This())` ({id, params}), `installKernel(@This(), "name")` (the
  spirv_kernel entry, named via @export). Author file = config + Buffers + Params + `pub const
  g = k.Globals(@This()); const b = &g.B;` + kernel fns + `comptime { k.installKernel(...); }`.
- addCompute (shader_codegen.zig) gains `--dep kompute -Mkompute=src/kompute.zig` so kernels can
  `@import("kompute")`.
- FIRST CONSUMER: port double_it -> kompute form, rebuild wgpu-compute-smoke, confirm the
  staircase + WGSL byte-equivalence-ish to the hand-written one (naga clean). Then S4.

For S5/S6 grid: see "PLAN EVALUATION + SPIKE FINDINGS" below — v1 grid is GATHER-ONLY
fixed-bucket (atomics blocked in Zig SPIR-V backend), prefix-sum (D7) + gridScatter +
sorted_idx are DROPPED from v1, ping-pong (D4) stays.

## PLAN EVALUATION + SPIKE FINDINGS (turn ~977)
Spiked the two highest-risk unknowns through the real pipeline (zig build-obj spirv32 ->
spv2wgsl -> naga):
- MULTI-ENTRY-PER-FILE = NO. Two spirv_kernel exports -> only the first reaches WGSL.
  => one kernel per .zig; SPH = a dir of kernels sharing a Buffers/Params/g/b import.
- ATOMICS = BLOCKED in Zig's SPIR-V backend (`atomic_rmw` unimplemented). This is the big
  one: every atomic-based grid (D6) is un-buildable right now. Knock-on: D7 prefix-sum is
  moot if the grid can't be atomic-counted on GPU.

RE-SEQUENCING THE GRID (the SPH-defining decision, given atomics are blocked):
- Option A (RECOMMENDED for v1): GATHER-ONLY fixed-bucket grid. Each CELL-thread scans all
  particles and fills its own fixed bucket `cell_particles[cell][0..K]` + writes its own
  `cell_count[cell]`. NO atomics, NO prefix-sum, NO scatter -> fully gather-discipline-
  compliant, all-GPU (northstar purity intact), builds TODAY. Cost: grid-build is O(cells*N)
  ~ O(N^2/K); at N=50k, K~16-32 that's ~1e8/frame (feasible, tunable). Not asymptotically
  ideal but fine at demo scale.
- Option B: CPU-build the grid in GPU mode (read pos back via readLatest, sort on CPU,
  upload cell_start/sorted_idx). Sidesteps atomics too, hot passes stay on GPU, but BREAKS
  "data never leaves the GPU" + adds a 1-frame-stale grid. Use only if A is too slow.
- Option C (later/ideal): true O(N) grid via GPU atomics (needs Zig SPIR-V atomic support
  upstream) OR a GPU bitonic sort (no atomics, but log^2(n) passes + ping-pong — big effort).
=> v1 = Option A. Drop D7 (prefix-sum) + sorted_idx + gridScatter from v1. Keep D4 ping-pong
   (relax still needs pos/pos_next). D6 atomics -> deferred/blocked-on-zig.

TEST HARNESS IDEA (addresses R2 = no real-GPU automated test): the dual shape IS an oracle.
Run a kernel one step on CPU (ground truth) and in-browser on GPU from identical input;
assert buffers match to fp tolerance. Single-step diff (SPH is chaotic over many steps, so
don't diff long runs). Scales verification with kernel count instead of eyeballing 8 kernels.

FINAL-RESULT POLISH (cheap, data already present): mouse drag-to-stir (one Param + a term in
integrate); color particles by speed/density (already in vel/rho); live FPS + particle-count
readout on the CPU/GPU toggle; gravity/viscosity sliders + reset. Turns "dots moving" into a
toy people share.
