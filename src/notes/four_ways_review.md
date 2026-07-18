# four_ways — adversarial review

I went back through the plan and the systems it leans on, and tried to break it. It broke
in four places. Two are real bugs in my design, one is a lie the demo would have told, and
one is a hazard that works today by luck. Three simplifications fell out, all verified.

Everything below has evidence. Where I claim something works, I compiled it.

---

## VERIFIED — the load-bearing claims hold

**A kompute module runs inside a worker wasm, with zero imports.** This was the claim that,
if false, kills the whole `.worker` idea:

    kompute-in-a-worker: 3 KB, imports=0, memory=1.1 MB
    exports: [memory, zimr_job_addKernel, zimr_job_alloc, zimr_job_err_ptr, ...]

**The shared function reaches the GPU.** A kompute kernel whose body is a call to `add`,
imported from another file:

    add.spv: 2992 bytes, magic 0x07230203
    functions named in the SPIR-V: [..., 'add_kernel.addKernel', 'add.add']

and through spv2wgsl into `@compute @workgroup_size(64,1,1) fn addKernel(...)`.
(`-fno-llvm -fno-lld` is mandatory — LLVM segfaults on the spirv target. It segfaulted
here first, exactly as `shader_codegen.zig` warns.)

**The readback is already a poll.** `readLatest` returns `?[]const T` and "never stalls".
That is `Job.poll()`'s shape, which is why `.worker` needs no new API.

---

## HOLE 1 — `M.g.B` is a module SINGLETON, and `Compute(M)` on CPU is stateless

I planned as if `Compute(M)` owned its buffers. It does not:

    // kompute.zig, the CPU branch of Globals:
    pub var B: Module.Buffers = undefined;   // module-level BSS. ONE of them.
    pub var P: Module.Params = undefined;

    // compute_host.zig:
    pub fn initCpu() Self { return .{ .backend = .cpu }; }   // no state whatsoever

So `Compute(M)` on CPU is a thin wrapper over a global. TWO instances of `Compute(M)`
ALIAS. The demo cannot hold a live `.cpu` pipe and a live `.worker` pipe side by side and
read both results — the worker's result lands in the same `M.g.B` the CPU one wrote.

Not fatal, but the plan glossed it. The fix is a discipline, not a mechanism: **run each
backend once, copy its answer out of `g.B` immediately into app state.** The demo is
one-shot anyway. State it in the example, because the next person will hit this.

## HOLE 2 — `.worker` is NOT interchangeable with `.cpu`/`.gpu`, and the enum implies it is

`Backend = enum { cpu, worker, gpu }` reads like three peers. They are not:

| | run() | result latency | cost per dispatch |
|---|---|---|---|
| `.cpu` | synchronous | immediate | none |
| `.gpu` | dispatch | ~1 frame | buffer upload |
| `.worker` | **submit** | **as long as the job takes** | **whole `Buffers` copied BOTH ways** |

And a fourth divergence I had not thought about: **what does `run()` do while a job is
still in flight?** `.cpu` and `.gpu` just run again. `.worker` cannot — two jobs would both
write back into `M.g.B`. It must DROP the call.

That is a genuine semantic difference, and hiding it behind an identical enum arm is the
kind of magic Zig exists to avoid. Keep the arm — it is worth having — but say what it is:

> `.worker` is `.cpu`, somewhere else. Same loop, same result, another thread. It submits
> ONE job; further `run()`s are ignored while it is outstanding. It copies the entire
> `Buffers` to the worker and back on every dispatch, so it suits kernels with modest
> state and one-shot work. It exists so a GPU-less device gets a compute fallback that
> does not freeze the frame — which is the whole point of jobs, applied to kompute.

That last sentence is the real justification, and it is better than the demo's.

## HOLE 3 — comptime cannot run the KERNEL. The demo would have been lying.

I wrote "four backends of the same kernel". False. The kernel reads `M.g.B` — a
module-level `var` — and comptime cannot touch module-level runtime memory. It is not a
limitation I can engineer around: the globals exist *because* the GPU needs per-field
storage bindings (a single megastruct binding "corrupted on Adreno above ~1000
invocations", per kompute's own comment). The globals are forced by hardware.

So the honest claim is narrower, and I think BETTER:

- **the FUNCTION** (`add`) is shared by all four;
- **the KERNEL** (`addKernel`, which indexes buffers) is shared by three.

The demo must show exactly that, or it is a magic trick with a false bottom. And the
narrower claim is the more interesting one anyway: the invariant is *the function*, and
each machine needs only a thin, honest adapter around it. That is a statement about Zig.
"Uniform backend enum" is a statement about an engine, and every engine has one.

## HOLE 4 — the benchmark panel would have taught the wrong lesson

I had planned a scale-up race. Cut it. Everything measured this session says the same
thing: workers buy latency, not throughput (~3.4x aggregate on 8 cores, and a hot CPU
throttles the GPU). A race invites "workers are fast", which is the one conclusion the
data refuses. The GPU would win, correctly, and the viewer would take away "use the GPU" —
which they already knew.

---

## HAZARD — auto-layout headers work by luck

A job header is memcpy'd out of the app wasm and into the kernel wasm: **two separate
compilations**. Zig's auto layout is explicitly unspecified, and it really does reorder:

    auto-layout   size=8   offsets a=4 b=0 c=5     <- b moved to offset 0
    extern layout size=12  offsets a=0 b=4 c=8     <- ABI-GUARANTEED

It is deterministic for the same compiler and target, so it works today. But `extern` is
precisely what the language provides for "these bytes cross a boundary", and the layout is
visible to comptime, so `assertPod` can simply require it. An anonymous literal still
coerces, so **no call site changes**:

    pub const Size = extern struct { w: u32, h: u32 };
    try registry.submit(gpa, encodePng, .{ .w = dim, .h = dim }, pixels);  // unchanged

Free robustness. Take it.

---

## SIMPLIFICATION 1 — submit by FUNCTION, not by name string

`registry.submit(gpa, "encodePng", hdr, payload)` — the string is a wart, and it is the
only thing standing between the call site and full type inference. Comptime function
identity works (verified):

    fn nameOf(comptime kernel: anytype) []const u8 {
        for (table) |entry| {
            if (entry[1] == kernel) return entry[0];   // comptime fn equality: WORKS
        }
        @compileError("jobs: that function is not in the kernel table");
    }

so the call site becomes:

    app.job = try registry.submit(gpa, encodePng, .{ .w = dim, .h = dim }, pixels);

No string. Still compile-checked (a function not in the table is a `@compileError`). The
table stays the single source of truth for BOTH `submit` and the wasm exports, which is
the property that matters — it cannot get out of step.

## SIMPLIFICATION 2 — kernel tables COMPOSE, which solves the launcher

One page carries one `ZIMR_KERNEL_WASM`, but the launcher bundles many examples. I had not
thought about this at all, and it would have bitten during Phase 2.

It solves itself, and it solves itself *because* the exports are name-based rather than
indexed. Tuples concatenate at comptime:

    // the launcher's generated kernel root
    jobs.Registry(four_ways.job_kernels ++ worker_png.job_kernels, .{}).exportWorkerEntry();

Each example still submits through its OWN registry; the merged wasm exports a superset of
the names, so every submit finds its kernel. **If I had kept the FNV hash and a dispatch
table, merging two registries would have meant merging two id spaces.** The simplification
paid for itself before it shipped.

(And if the launcher ships no kernel wasm at all, `jobs.parallel()` is false and every
kernel runs inline — correct, just hitchy. The fallback means this can never be a build
break, only a performance one.)

## SIMPLIFICATION 3 — the kompute worker registry needs NO tuning

`Options.max_input` / `max_output` are guesses for a hand-written kernel. For a kompute
module they are exactly derivable:

    max_input  = @sizeOf(Hdr) + @sizeOf(M.Buffers)
    max_output = @sizeOf(M.Buffers)

So `Compute(M)`'s `.worker` arm builds its own registry with exact bounds and the app
author configures nothing. Combined with `pub const kernels` (a convention kompute already
has, for `installKernels`), the whole worker backend is DERIVED from the module:

    pub fn komputeTable(comptime M: type) ...   // one job kernel per name in M.kernels

App-author cost of adding a worker backend to an existing compute kernel: **change one
word.** That is the feature. The demo is downstream of it.

---

## The demo, reframed

The wow is not four boxes reading "4". Four boxes reading "4" is a screensaver.

The wow is **the code on screen next to the costs**:

    fn add(a: u32, b: u32) u32 { return a + b; }
    ONE function. FOUR machines. No annotations. No attributes. No pragmas.

    ┌ comptime ────────┐  ┌ CPU · main thread ┐
    │     2 + 2 = 4    │  │     2 + 2 = 4     │
    │  answered before │  │  ~40 ns, right    │
    │  the program ran │  │  here, this frame │
    └──────────────────┘  └───────────────────┘
    ┌ CPU · worker ────┐  ┌ GPU · compute ────┐
    │     2 + 2 = 4    │  │     2 + 2 = 4     │
    │  another core.   │  │  64 invocations,  │
    │  ~0.4 ms round   │  │  ~2 frames to     │
    │  trip            │  │  upload + read    │
    └──────────────────┘  └───────────────────┘

    Same code. Same answer. Costs spanning SEVEN ORDERS OF MAGNITUDE.

The GPU taking ~33 ms to add 2 and 2 is not an embarrassment to hide — **it is the punch
line, and it is the lesson**: backends are interchangeable in CODE, not in COST. A viewer
who leaves knowing that has learned something true and useful, and it is the same lesson
every measurement this session has been shouting.

The comptime panel is the strange one and earns its place by being strange: its answer
existed before the program did. The binary holds the constant `4` and no add instruction.

---

## Revised plan

**Phase 2 — jobs, finished** (unchanged, unblocks everything)
1. `build.zig`: generate kernel root, compile freestanding `-rdynamic`, `--kernel-wasm-embed`
   (purity gate already live and proven).
2. Wire `worker_png`'s two buttons. Device-verify: expect worst frame gap ~17 ms.

**Phase 2b — the fixes this review found** (small, do them before anything builds on top)
3. `submit(gpa, encodePng, hdr, payload)` — submit by function. [S1]
4. `assertPod` requires `extern` layout on struct headers. [HAZARD]
5. Document the `Registry` table as the composition point. [S2]

**Phase 3 — `.worker` backend**
6. `Backend = enum { cpu, worker, gpu }`; `run()` submits, drops while in flight;
   `readLatest` polls the job. Document the divergence honestly. [HOLE 2]
7. `komputeTable(M)` + derived registry with exact bounds, in `compute_host.zig`
   (NOT in jobs — jobs stays a leaf). [S3]

**Phase 4 — `examples/four_ways/`**
8. `add.zig` (4 lines), `add_kernel.zig` (`config.max = 64`, `pub const kernels`),
   `four_ways.zig` (four panels, the source listing, the costs).
9. Run each backend ONCE and copy the answer out of `g.B` immediately. [HOLE 1]
10. No benchmark race. [HOLE 4]

**Phase 5 — close out**
11. claude.md: the measured facts, the NaN bug, the detach bug, the auto-layout hazard.
12. Launcher: merged kernel root via table concatenation. [S2]
