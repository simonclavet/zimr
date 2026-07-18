# zimr GPU/CPU Compute — Unified Design (turn ~962)

## NORTHSTAR
One SPH kernel, written ONCE in Zig, that runs on CPU or GPU by flipping a
runtime switch — identical results, identical source. Mirror how zm fragment
shaders already run on both (rlsw dispatches the same `shaderMain` per pixel that
the GPU runs as a fragment entry).

## WHAT I VERIFIED BY TRYING (empirical, this session)
- Compute kernels work end-to-end: `export fn main() callconv(.spirv_kernel)` +
  std.gpu.global_invocation_id + `extern var buf: T addrspace(.storage_buffer)` +
  `extern const p: P addrspace(.uniform)`. zig build-obj spirv32 -> OpEntryPoint
  GLCompute; spv2wgsl -> valid @compute WGSL (multi-buffer, uniform); naga ok.
- workgroup_size now injectable (Step 1 done: spv2wgsl --workgroup=N).
- Buffers must be FIXED-CAPACITY arrays (`[MAX]T` inside an extern struct).
  Runtime-sized (`[*]`/`[0]`) either can't index or SEGFAULT the compiler. Fine —
  SPH has a fixed particle count; cap like rt_fs's `[8]sphere`.
- callconv(.spirv_kernel) is SPIR-V-ONLY -> CPU + GPU need DIFFERENT entry
  wrappers around the SAME body. This is exactly the fragment installSpirvEntry
  pattern. The duality is ARCHITECTURALLY identical to what we already ship.

## THE INSIGHT: the fragment duality, generalized
Fragment today:
  - source: `pub fn shaderMain(io: Io) Out`  (pure fn)
  - GPU: installSpirvEntry wraps it (read externs -> io -> write Out)
  - CPU: rlsw_shader.dispatchFragmentShader LOOPS pixels, calls shaderMain(io)
Compute is the SAME shape, simpler (1D loop, no framebuffer):
  - source: `pub fn kernel(id: u32, b: *Buffers, p: Params) void`  (pure fn)
  - GPU: installSpirvComputeEntry wraps it (bind storage externs -> call kernel)
  - CPU: dispatchCompute LOOPS id in [0,count), calls kernel(id, &buffers, p)

## THE DESIGN — author once, the Buffers type is the bridge

### Kernel author writes (my_sim.zig) — NO addrspace/callconv/builtin by hand:
```zig
const zm = @import("zm");
const k = @import("kompute");          // the compute DSL/helpers

pub const MAX = 100_000;               // fixed capacity (GPU array bound)
pub const WORKGROUP = 64;

// Buffers: each field is a fixed array of a GPU-storable element. The DSL turns
// this into GPU storage externs OR a CPU struct-of-arrays — same field names.
pub const Buffers = struct {
    pos:  [MAX]zm.Vec2,
    vel:  [MAX]zm.Vec2,
    rho:  [MAX]zm.Vec2,                 // (rho, rho_near)
};
pub const Params = struct { dt: f32, gravity: f32, count: u32, /*...*/ };

// THE KERNEL — pure Zig over the buffers. Identical on CPU + GPU.
pub fn integrate(id: u32, b: *Buffers, p: Params) void {
    if (id >= p.count) return;
    b.vel[id][1] += p.gravity * p.dt;
    b.pos[id]    += b.vel[id] * zm.splat2(p.dt);
}
// (multiple kernels = multiple pub fns; a multi-pass pipeline lists them)
```

### `kompute` provides the two entries from one body (the magic):
```zig
// GPU build target: for each kernel, emit a spirv_kernel entry that binds the
// Buffers fields as @group(0) storage externs + Params as uniform, reads
// global_invocation_id, calls the body. (Generated like gen_shader_externs, or a
// comptime fn taking the Buffers/Params types + the kernel fn.)
comptime { kompute.installComputeEntry(Buffers, Params, integrate, WORKGROUP); }
```
On CPU this is a no-op (like installSpirvEntry).

### Host side — ONE switch, uniform API:
```zig
var sim = try z.Sim(my_sim).init(gpa, frame);   // allocs CPU buffers + GPU bufs
sim.backend = .gpu;                              // or .cpu — THE TOGGLE
// per frame:
sim.params = .{ .dt = dt, .gravity = 900, .count = n };
sim.run(frame, .integrate);                      // dispatch (GPU) OR loop (CPU)
sim.run(frame, .density);
sim.run(frame, .pressure);
// reading back: sim.cpuView(.pos) -> []Vec2 (GPU path maps/copies lazily)
```
`z.Sim(M)` is comptime over M.Buffers/M.Params/the kernel set:
  - .cpu: buffers are a heap `Buffers` struct; run(k) = `for id: kernel(id,&b,p)`
    (optionally multithreaded later). ZERO GPU involved.
  - .gpu: buffers are StorageBuffers (one per field, OR one big struct buffer);
    run(k) sets the uniform, dispatchWorkgroups(ceil(count/WG)).
  - render reads pos either from the CPU struct or the GPU buffer (instanced
    points reading the storage buffer directly on GPU; drawCircleV on CPU).

## THE HARD PART, SOLVED: scatter -> GATHER (works on BOTH)
The CPU SPH scatters position deltas to neighbours (write to other particles).
On GPU that needs atomic-float (WGSL has none). The fix makes BOTH backends use
the SAME kernel: restructure each pass as a GATHER — every particle id computes
its OWN delta by summing over neighbours, writing only b.x[id]. No cross-particle
writes -> no atomics -> identical CPU/GPU code. (Two-buffer ping-pong where a
pass needs last-iter values.) This is the central rewrite of the Clavet step and
it's a WIN for the CPU path too (no write contention, trivially parallel).

## GRID NEIGHBOUR SEARCH on both
- Build: counting sort into cells (cell size = interaction radius). On CPU a
  plain prefix-sum. On GPU either (a) atomic<u32> cell counters (verify atomics
  in a small test) or (b) a sort kernel. Start with the CPU-identical approach:
  a "clear/count/prefix/scatter" set of gather-only kernels using atomic<u32>
  ONLY for the count (integers — WGSL HAS atomic<u32>). Verify first.
- The neighbour LOOP body (33-cell) is identical Zig on both — it just reads the
  grid arrays from Buffers.

## PLAN (ordered)
S1 DONE: spv2wgsl --workgroup.
S2: compute smoke — double_it via StorageBuffer upload->dispatch->READBACK->assert
    (verify wgpu.zig buffer readback path). The first real GPU compute round-trip.
S3: kompute.installComputeEntry(Buffers,Params,kernelFn,WG) — the GPU entry
    generator (comptime, mirrors installSpirvEntry; binds Buffers fields as
    storage externs by field index, Params as uniform). + ShaderPipeline.addCompute.
S4: z.Sim(M) host wrapper with the .cpu/.gpu toggle + run(kernel) + cpuView.
    CPU path first (pure loop — instant, no GPU), then GPU path sharing the API.
S5: particle integrate demo, toggle CPU/GPU, SAME kernel, identical motion.
S6: SPH — rewrite Clavet step as gather kernels (integrate, gridCount[atomic u32],
    gridPrefix, gridScatter, density, pressureDisplace, viscosity, finalize),
    ping-pong buffers. Toggle button CPU<->GPU. THE northstar demo: 20k+ on GPU,
    ~2k on CPU, identical algorithm, one source.

## AMBITION / OUTSIDE-THE-BOX (post-northstar, noted)
- `sim.run` could take a comptime LIST of kernels -> one command encoder, all
  dispatches batched (GPU) or all loops fused (CPU).
- A comptime check that a kernel only WRITES b.x[id] (gather discipline) — reject
  cross-id writes at compile time so CPU/GPU can never diverge. (Hard; aspirational.)
- CPU path auto-multithreaded (std.Thread pool over id ranges) — gather form makes
  it embarrassingly parallel, free speedup, still identical results.
- Same Buffers drives RENDER: a vs/fs that reads pos as instance data -> the GPU
  never copies particle data CPU<->GPU at all (the v5 file's "zero readback" goal).
- Eventually: the toggle isn't CPU-vs-GPU but a SPECTRUM (CPU single, CPU threaded,
  GPU) selectable at runtime for the same sim — a teaching artifact.

## RISKS
1. wgpu.zig buffer READBACK for S2 — verify map/copy exists (first thing in S2).
2. atomic<u32> in our compute path (grid count, S6) — small test before SPH.
3. installComputeEntry binding-by-field-index correctness — mirror the fragment
   externs; test with the 2-buffer smoke.
4. Buffers as one-big-struct vs N-separate-StorageBuffers — pick one. One struct
   buffer = one binding, simplest; matches the `extern struct` GPU shape. Go with
   ONE struct buffer per Buffers type (binding 0), Params uniform (binding 1).

## RECOMMENDATION
S2 next (compute round-trip w/ readback) — proves the loop. Then S3+S4 build the
duality, S5 proves it on a toy, S6 is the SPH northstar. The fragment path already
proves this architecture works; compute is the same shape, and the transpiler
already handles it. The ambition is achievable.

## ===== DUALITY MECHANISM — PROVEN by experiment (turn ~962) =====
The CPU/GPU-from-one-source kernel WORKS. Verified: a single module compiles to
BOTH a native CPU object (loop calls the kernel) and valid compute WGSL (naga ok).

KEY LEARNINGS (what works / what doesn't):
- DO NOT pass `*Buffers` to the kernel. A storage-buffer struct passed by pointer
  makes spv2wgsl emit a `let copy` then write through it -> naga "invalid LHS /
  immutable binding". (Real transpiler gap; avoid by design.)
- DO put buffers at MODULE level, accessed DIRECTLY (like fragment shaders read
  externs, not a pointer). This transpiles cleanly.
- `usingnamespace` is GONE in 0.17. Use a comptime-selected `pub const g = if
  (is_gpu) struct {...} else struct {...}` namespace.
- callconv(.spirv_kernel) is SPIR-V-only -> comptime-gate the entry wrapper with
  `if (is_gpu)`.
- Buffers = fixed-cap arrays in an extern struct ([MAX]T). One struct buffer ->
  one binding. (Runtime-sized arrays segfault the compiler.)

THE PROVEN SHAPE (kernel author writes ~this):
```zig
const is_gpu = @import("builtin").target.cpu.arch.isSpirV();
pub const Buffers = extern struct { pos: [MAX]zm.Vec2, vel: [MAX]zm.Vec2 };
pub const Params  = extern struct { dt: f32, gravity: f32, count: u32, _pad: u32 };
pub const g = if (is_gpu) struct {
    pub extern var B: Buffers addrspace(.storage_buffer);
    pub extern const P: Params addrspace(.uniform);
} else struct {
    pub var B: Buffers = undefined;
    pub var P: Params = undefined;
};
pub fn integrate(id: u32) void {           // <- pure kernel, identical both sides
    if (id >= g.P.count) return;
    g.B.vel[id][1] += g.P.gravity * g.P.dt;
    g.B.pos[id]    += g.B.vel[id] * zm.splat2(g.P.dt);
}
comptime { if (is_gpu) { const W = struct {
    export fn main() callconv(.spirv_kernel) void { integrate(gpu.global_invocation_id[0]); }
}; _ = W; } }
```
The `kompute` DSL/generator will hide the `g`-namespace + entry boilerplate so the
author writes only Buffers/Params/the kernel fns (mirroring gen_shader_externs).

HOST z.Sim(M): .cpu -> `M.g.B`/`M.g.P` are the live structs; run(k)=`for id:
M.k(id)`. .gpu -> upload M.g.B-shaped data to ONE StorageBuffer (binding 1) +
Params uniform (binding 0); run(k)=dispatch. cpuView reads back on GPU. The
toggle is one field. CPU path needs ZERO gpu — instant to build + test first.

UPDATED RISK: the by-pointer transpiler bug is DODGED by the module-level design,
not blocking. Remaining: S2 buffer readback, S6 atomic<u32> grid. Both small.
NEXT: S2 (compute round-trip + readback), then the kompute generator + z.Sim.

## ===== DECISION: do NOT fix the pointer-param transpiler bug (turn ~963) =====
Q (Simon): would changing the transpiler to accept kernel(id, b: *Buffers, p)
give a BETTER system?
ROOT CAUSE re-examined: WGSL forbids passing a storage buffer BY VALUE to a fn;
it must be ptr<storage,...> or a global. The Zig backend passes the buffer
by-value through the call; spv2wgsl faithfully emits `let _: S = global` (immutable)
then writes through it -> naga "invalid LHS". The proper fix = detect storage-
backed fn params and re-emit as `ptr<storage,read_write,T>`, threading pointer
semantics through all call sites. NON-TRIVIAL + permanent maintenance surface.
DECISION: NO. Keep module-level buffers (g.B / g.P accessed directly). Reasons:
1. UNIFORMITY: fragment shaders already access io/externs DIRECTLY, not via ptr.
   Module-level compute = ONE mental model across all shader types. Pointer-param
   compute would be the odd one out. (Simon asked for "simple and uniform".)
2. WITH THE GRAIN: WGSL storage buffers ARE module-global @group/@binding
   resources. Module-level is natural; pointer-passing fights WGSL + SPIR-V.
3. DUALITY: the CPU/GPU-from-one-source story works BECAUSE buffers are globals
   the CPU dispatcher fills + the GPU binds (same names, no ptr to reconcile).
   Pointer-params would reintroduce the addr-space divergence we just eliminated.
4. HELPERS WORK via globals (VERIFIED: a neighbour-force helper reading g.B.pos
   + returning a value -> naga ok). SPH's neighbour loops don't need ptr params.
5. PING-PONG (read last / write this) is CLEANER as two named globals
   (g.B_read / g.B_write) than ptr juggling.
The transpiler bug was a USEFUL forcing function -> pushed us to the better design.
NOTED limitation: generic reusable kernels (point one kernel at any buffer) WOULD
want ptr-params. Not the northstar. Revisit only if a "compute library" goal
appears. For now: module-level globals, decision closed.


## ===== STEP 2 progress: readback infra built (turn ~964) =====
DONE this turn:
- wgpu.zig: copyBufferToBuffer + a poll-based readback API (bufferReadStart/Poll/
  Into/Release) mirroring the GL fetch pattern (mapAsync is async; sync wasm polls).
- zimr_wgpu.ts: js_encoder_copy_buffer_to_buffer + js_buffer_read_* (mapAsync ->
  snapshot mapped range -> unmap -> ready flag; read_into copies to wasm mem).
  + bufferReads Map<id,{buf,ready,data}> on state. Bundles clean.
- webtests/wgpu_smoke.ts: 5 new stubs added (smoke is headless stubs — verifies
  instantiation, NOT compute results; real result-check needs a real device).
- examples/wgpu_compute_smoke/double_it.zig: the kernel, PROVEN dual shape. Through
  the real spv2wgsl --workgroup=64: @binding(0)=uniform(Params), @binding(1)=
  storage(Buffers), @compute @workgroup_size(64), naga ok. (binding order =
  declaration order: P before B.)
- regression: existing wgpu demos build + smoke pass; lint 0.
NEXT (finish S2): the HOST demo — create the storage buffer (STORAGE|COPY_SRC) +
uniform + a MAP_READ staging buffer; createBindGroupLayout/createBindGroup (via
descriptor_encoder: layout entry storage_buffer@1 + uniform@0; group entries the
buffers); createComputePipeline(shader,"main"); per "frame": writeBuffer the
input + params, begin compute pass, setPipeline+setBindGroup, dispatchWorkgroups(
ceil(count/64)), end; copyBufferToBuffer(storage->staging); submit; bufferReadStart
+ poll across frames; assert data doubled. Build wiring: ShaderPipeline.addShader
with a compute stage passing --workgroup (extend addShader to take workgroup_size).
NOTE: bind order in WGSL is P(0),B(1) — the host bind group + layout must match.
- PER-TURN zip (zimr964).


## ===== TUTORIAL-DRIVEN DESIGN: wrote the spec, found the big one (turn ~965) =====
Wrote src/notes/tutorials/gpu-compute-tutorial.md as the SPEC (final-form API,
real examples: double, N-body, blur, SPH) with [WEIRD?] callouts. Writing it
caught the most important API constraint BEFORE building:
- THE BIG FINDING: the obvious `c.buffers.data[id]` (buffers via a ctx struct
  field) DOES NOT TRANSPILE — same by-pointer let-copy/immutable bug. VERIFIED.
  CORRECTED SHAPE (both verified naga-ok): buffers accessed via a MODULE-LEVEL
  name `b` (`b.pos[id]`; a module-scope `const b = &buf.B` alias works); PARAMS
  ride in ctx BY VALUE (`c.params.count`, read-only, no copy bug). So a kernel is
  `fn k(c: k.Ctx(@This())) void` where c = {id, params} and buffers are `b.*`.
- 10 [WEIRD?] smells collected, priority-ordered. The kernel-AUTHORING shape is
  settled + verified; nearly all smells are in the HOST API:
  1. async readback (§6) — commit to readLatest (frame-delayed) + readBegin/poll.
  2. ping-pong for SPH — .pingpong + pos/pos_next + swap, or explicit. HIGH.
  3. prefix-sum/canned primitives (grid scan) — ship pipe.prefixSum or CPU-grid-
     in-GPU-mode for v1.
  4. atomics — VERIFY atomic<u32> through spv2wgsl FIRST, then c.atomic accessor.
  5. k.Buffer(T) vs []f32 — pick the honest buffer type early.
  6. pipe.upload(.field, slice)/read keyed by enum (uniform with run(.kernel)).
  7. 1D/2D/3D ctx — infer dim from config.workgroup; c.id / c.xy.
  8. workgroup/shared memory — PUNT v1 (breaks CPU duality).
  9. read-latency skew CPU vs GPU — document, don't fake.
- NEXT: resolve smells #1/#2/#4 (the host seams), VERIFY atomics, then build the
  generator (b-namespace + entry + Ctx) and z.Compute host. The tutorial is the
  target.
- PER-TURN zip (zimr965).


## ===== ZERO-COPY compute->render VERIFIED + a fix shipped (turn ~966) =====
Q (Simon): are we equipped for the fastest particle system where data NEVER
leaves GPU between compute and render? ANSWER: YES, now verified end-to-end.
Tested the whole chain, found + fixed one real gap:
1. compute writes pos: var<storage,read_write> — naga ok.
2. SAME buffer, usage STORAGE|VERTEX-readable: BufferUsage has storage+vertex.
3. VERTEX shader reads pos[instance_index]: a Zig vertex shader (callconv
   .spirv_vertex) reading the storage buffer transpiles -> @vertex, @builtin(
   instance_index), var<storage,read>, @builtin(position). naga ok.
4. render pass: draw(vtx_count, instance_count) + set_bind_group EXIST.
5. NO copyBufferToBuffer, NO readback, NO CPU touch — buffer stays resident.
THE FIX (shipped): WebGPU FORBIDS var<storage,read_write> in the VERTEX stage
(must be `read`). spv2wgsl was hardcoding read_write for ALL storage -> a real
browser would REJECT the particle-render pipeline at creation (standalone naga
missed it). Now spv2wgsl emits `read` when exec_model==Vertex, read_write
otherwise. (Zig backend emits NO NonWritable decoration for `extern const`, so
stage-based is the right signal.) Verified: vertex=read, compute=read_write,
both naga ok, corpus 0, lint 0.
THE FAST PARTICLE PATTERN (now real):
  - one storage buffer `pos: [MAX]Vec2`, usage STORAGE|VERTEX (or just bound as
    read-only-storage in the render bind group).
  - compute pass writes pos[id]; render pass draws N instances of a unit
    quad/point, vertex shader reads pos[instance_index]. Same buffer, same frame,
    zero transfer.
STILL TO BUILD (mechanism proven, ergonomics pending): drawPointsFromBuffer
(ships the instance vs/fs); confirm a buffer can be in a render bind group as
read-only-storage simultaneously with being the compute target (WebGPU allows;
just don't write it in the same pass). The z.Compute/z.Sim layer wires it.
- PER-TURN zip (zimr966).
