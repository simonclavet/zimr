# four_ways — one Zig function, four machines

**Second adversarial pass.** The first review found four holes and fixed them. This one found
a fifth it had missed, a bug it had written down as a FEATURE, and — the important one — that
the demo the whole plan was building toward **does not justify the feature it was built to
show.** The plan is better and smaller for it.

---

## Where the work actually stands

| | |
|---|---|
| `Backend = enum { cpu, worker, gpu }` | **done** |
| `.worker` arms in `run()` / `readLatest()` | **done** |
| `komputeKernel` / `komputeTable` / `komputeRegistry` | **done** |
| `submit(gpa, kernelFn, hdr, payload)` — by function, no string | **done** |
| `assertPod` requires `extern` layout on headers | **done** |
| `worker_png` (device: 18 ms frame gap vs 233 ms inline) | **done** |
| `examples/four_ways/` | **NOT BUILT** |

Phases 2, 2b and 3 are finished. Only the demo is outstanding — which is exactly why now is
the moment to ask whether it is the right demo.

---

## HOLE 5 — `.worker`'s INPUT came from the module singleton

The first review found HOLE 1 (`M.g.B` is a module-level singleton, so two `Compute(M)`
instances alias) and fixed the OUTPUT side: a `.worker` pipe reads its answer back into its
own private `mirror`, never out of `M.g.B`.

The INPUT side was missed, and it was worse for being presented as a simplification:

    // upload() — wrote to the MODULE SINGLETON
    .cpu, .worker => {
        const dst = &@field(M.g.B, @tagName(field));
        @memcpy(dst[0..data.len], data);
    },

    // run() — SHIPPED that singleton as the job payload
    std.mem.asBytes(&M.g.B),

    // readLatest() — read from a PRIVATE mirror
    return @field(wk.mirror.*, @tagName(field))[0..n];

with a comment arguing it was free:

> `.worker` IS `.cpu` — the job's payload is literally `asBytes(&M.g.B)`, so the worker's
> input staging area and the CPU's buffers are the same memory. Nothing to duplicate.

True, and it is the bug. **A `.cpu` pipe's `run()` writes its RESULTS into `M.g.B`. The next
`.worker` dispatch then ships those results as its INPUT.** Two live pipes on one module
silently contaminate each other — and `four_ways` exists precisely to run `.cpu`, `.worker`
and `.gpu` side by side. The flagship would have hit it on day one.

**Worse: the test asserted the bug as intended behaviour.** It dispatched a worker with no
upload at all and expected it to inherit whatever the CPU pipe had left behind:

    // Now dispatch the SAME kernel on a worker, taking those globals as its input.
    wk.run("bump", 4);
    try expectEqualSlices(u32, &[_]u32{ 201, 202, 203, 204 }, wk.readLatest(.data).?[0..4]);

**FIXED.** A `.worker` pipe now owns its state end to end: `upload` stages into its own mirror,
`run` ships that mirror, `readLatest` reads the answer back into it. It never touches `M.g.B`
in the app's address space at all. The mirror was ALREADY allocated for the readback, so this
costs nothing — and it makes the arm SYMMETRIC (one buffer, in and out) instead of split
across two homes. **The fix removed code.**

The test now asserts the opposite, stronger property: two live pipes on one module, each with
its own data, neither seeing the other. (The inline fallback's snapshot/restore is still needed
and still tested — the KERNEL BODY reads `M.g.B` by construction, so running inline in the
app's address space must put back what it trampled.)

---

## HOLE 6 — the `.worker` backend has ZERO consumers, and the planned demo does not earn it

    $ grep -rn "initWorker\|Backend.worker" examples/
    (nothing)

`worker_png` — the one thing that exercises workers — uses `jobs` **directly**
(`kernels.registry.submit(...)`). It cannot use `Compute(.worker)`: PNG encoding is not a
data-parallel per-element kernel, so it is not a kompute module.

So the entire `.worker` arm — the `Worker` struct, the mirror, the drop-while-in-flight rule,
`komputeKernel` / `komputeTable` / `komputeRegistry` — exists for a single planned consumer:
**a demo that adds 2 and 2.**

That demo does not justify it. Shipping a whole `Buffers` image to another thread and back to
compute `2 + 2` is pure overhead. The review already knew this and made it the punch line
("costs spanning seven orders of magnitude") — which is honest, but **an honest demonstration
that a feature is useless is not a case for the feature.** It is dead code with a caption.

That HOLE 5 sat there undiscovered is the evidence: nothing uses this path, so nothing caught
it, and the test that should have caught it asserted the bug instead.

---

## The fix: make the demo MANDELBROT, not `2 + 2`

Same structure, same four panels, same "one function, no annotations" claim — but a function
whose cost is real enough that each backend's CHARACTER becomes VISIBLE rather than captioned.

    // examples/four_ways/escape.zig — THE function. Read it.
    // Nothing here about threads, or GPUs, or compile time.
    pub fn escape(cx: f32, cy: f32, max: u32) u32 {
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        var i: u32 = 0;
        while (i < max and x * x + y * y < 4.0) : (i += 1) {
            const t: f32 = x * x - y * y + cx;
            y = 2.0 * x * y + cy;
            x = t;
        }
        return i;
    }

Seven lines. Still fits on screen. Still no annotation, no attribute, no pragma.

**Now every panel SHOWS what the 2+2 version could only assert:**

| panel | what the viewer SEES |
|---|---|
| **comptime** | a 32x16 ASCII fractal, computed by `escape` BEFORE THE PROGRAM RAN. The binary holds the characters and no loop at all. |
| **CPU / main thread** | the real fractal — and **the frame visibly hitches while it draws.** The cost is not a number in a caption; it is in your hands. |
| **CPU / worker** | the same fractal, the same wall-clock work — **and the frame does NOT hitch.** Another core, smooth. |
| **GPU / compute** | instant. |

**That is what `.worker` is FOR**, and it is the only panel that can show it: *a GPU-less
device gets a compute fallback that does not freeze the frame.* Put the CPU and worker panels
side by side, both grinding the same pixels, one janky and one smooth, and the feature
justifies itself without a word of caption.

It also keeps the first review's honest narrowing (HOLE 3) and makes it VISIBLE rather than
asserted:

- **the FUNCTION** (`escape`) is shared by all four — including comptime;
- **the KERNEL** (which indexes `M.g.B`) is shared by three.

The comptime panel is that fractal made of characters; the other three are the same fractal
made of pixels. Nobody has to be TOLD the function is the invariant — they can see the shape
twice.

And it makes `.worker` a **feature with a user** instead of infrastructure with a demo.

---

## Files

    examples/four_ways/
      escape.zig         the function. 7 lines. imported by all of the below.
      escape_kernel.zig  kompute module: Buffers{out}, Params{w,h,cx,cy,zoom,max},
                         kernel body = `escape(...)`  ->  .cpu, .worker, .gpu
      four_ways.zig      the app: four panels, the source listing, the honest costs.

Unchanged from the original plan except for the subject. `add.zig` becomes `escape.zig`; the
wiring is identical, because the wiring was never the interesting part.

## BUILT — and what device verification caught

`examples/four_ways/` ships. All four panels draw the same fractal from the same seven lines;
`escape.escape` appears BY NAME in the SPIR-V; the kernel wasm is **4.4 KB with ZERO imports**
and exports `zimr_job_mandel` — a job kernel nobody wrote, derived from the kompute module.

Three bugs the device found that the build could not:

1. **No UI.** `u.button` outside a `u.window(...)` draws NOTHING. The demo shipped with no
   reachable RUN button, so nothing was ever dispatched.

2. **The panels drew zeroes and called it done.** A `.cpu` pipe's `readLatest` is never "not
   ready" — it hands back `M.g.B` directly — so polling before any dispatch returned the
   ZEROED buffer and the panel drew 12288 pixels of `escape = 0`. Uniform dark blue, no
   error, no complaint. `.gpu` and `.worker` genuinely return null until their readback
   lands; `.cpu` cannot, because nothing about it is asynchronous. The app must track
   dispatch itself (`sent[]`).

3. **It was not expensive enough to prove anything.** At 64 iterations the CPU pass is ~800k
   steps: two milliseconds, no hitch, and the `.worker` panel demonstrates nothing. The whole
   demo turns on the main-thread pass actually COSTING you frames. Default is now 1500.

And one that is not a bug but a trap: **the in-app preview refuses `new Worker()`**, so the
worker panel silently runs INLINE — where a green "0 ms" would be a lie about a contrast it
is not making. It now says `NO WORKER HERE - running inline` instead.

## What is left to build

1. `escape.zig`, `escape_kernel.zig`, `four_ways.zig`.
2. Each pipe now owns its own state, so the "copy the answer out of `g.B` immediately"
   discipline is GONE — **HOLE 5's fix retired HOLE 1's workaround.** One less rule.
3. Launcher: merged kernel root via table concatenation (still true, still free).
4. `claude.md`: the auto-layout hazard, and HOLE 5.

## The lesson worth keeping

`.worker` was built, tested, documented and adversarially reviewed — and still carried a bug
that let two live pipes contaminate each other, **because nothing used it.** The tests passed
because the test asserted the bug.

A feature with no consumer has no evidence behind it, only intentions. The demo is not a
nice-to-have on top of the feature; it is the only thing that can prove the feature is real.
