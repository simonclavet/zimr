# jobs: fan-out — `Group`, and a progressive tile path tracer

## The finding

**The worker pool has always been parallel. Nothing has ever used it.**

`ZimrJobs.spawn()` starts `hardwareConcurrency / 2` workers (capped at 4). `pump()` walks
EVERY worker on every submit and every completion, handing each free one a job off the queue.
So an app that submits eight jobs already occupies four cores, today, with no engine change.

Every example submits exactly one. We built a thread pool and have only ever used one thread
of it.

## The constraint, stated honestly

From `bridge.zig`, already measured, already written down:

> How many? `hardwareConcurrency` is the core count. We take half, and never more than 4:
> this pool exists to move work OFF the main thread, not to chase throughput (measured: 8
> workers give only ~3.4x aggregate on a phone, and a hot CPU throttles the GPU — which for a
> renderer is a bad trade).

So the pitch is NOT "N cores, N times faster". The pool is a LATENCY device: it gives the
frame back. Fan-out is worth building because it lets one expensive job arrive INCREMENTALLY
— tiles landing as they finish — not because it multiplies throughput. A demo that sold a
speedup number would be selling something the engine deliberately declined to build.

## What is missing: an ergonomic way to hold N jobs

Submitting eight jobs today means eight `Job` values, eight `pollInto` calls, eight `done`
flags, and hand-rolled bookkeeping in every app that wants it. The mechanism is there; the
API is not.

    // examples/rt_workers/rt_workers.zig — what it should look like
    var g: jobs.Group(Tile) = try .submitAll(gpa, kernels.traceTile, tiles, scene_bytes);

    while (try g.next(s.tile_buf)) |landed| {   // whatever finished THIS frame
        blitTile(s.fb, landed.index, landed.bytes);
    }
    if (g.complete()) { g.deinit(); }

Three properties, and each is load-bearing:

  * **`next` yields whatever is ready, OUT OF ORDER.** That is not a compromise, it is the
    feature: a tile that finishes first should be drawn first. In-order delivery would
    reintroduce the head-of-line stall the pool exists to remove.
  * **`next(dst)` collects into a caller-owned buffer.** `pollInto`, not `poll`. We measured
    what allocating on the landing frame costs (154 ms for 2.7 MB) and a Group lands many
    times per second.
  * **`progress()` and `complete()` are free.** The bookkeeping already exists internally;
    exposing it costs nothing and every consumer wants it.

### The known limit, written down before it bites someone

`submitAll` stages `header ++ payload` PER JOB, so a shared payload is copied N times. For
the tracer that payload is a few hundred bytes of spheres and it does not matter. For a job
set that shares a 4 MB mesh it would matter a great deal. If that day comes, the fix is a
shared-payload handle the workers hold across jobs — not a bigger memcpy. Do not paper over
it; the whole reason `worker_png` looked broken for a month is that a copy nobody had costed
was sitting on the landing frame.

## The demo: `rt_workers` — a progressive tile path tracer

zimr already has a CPU path tracer (`examples/raytracer`, 886 lines). This is not that: it is
a small, PURE tracer whose kernel is a job kernel.

Why a tracer and not the PNG encoder or the Mandelbrot:

  * **Tiny in, small out.** The payload is a handful of `extern struct` spheres — a few
    hundred bytes. The result is one tile of pixels. The transport costs that dominated
    `worker_png` (4 MB in, 2.7 MB out) essentially vanish, so what you see is the POOL, not
    the plumbing.
  * **Genuinely expensive, and expensive in a way you can tune.** Samples per pixel is a
    knob that spans "instant" to "please wait", so the same demo shows a smooth frame at
    every point on that range.
  * **Progressive display is the natural presentation.** Tiles pop in as they land. The
    out-of-order delivery is not a caveat to explain, it is the thing you are looking at.
  * **Mandelbrot could not do this** (`four_ways`): its cost profile is too flat to stall a
    frame, so the contrast the demo needed was never visible. This one stalls hard and
    honestly.

Layout:

    examples/rt_workers/
      tracer.zig     PURE: Sphere, Scene, `traceTile(gpa, hdr, payload, out)`. Testable with
                     `zig build test` — no browser, no worker, no wasm.
      kernels.zig    the registry. One kernel.
      rt_workers.zig the app: a framebuffer, a tile grid, a Group, and a spinning dot whose
                     smoothness is the claim.

The dot stays. It is the only part of `worker_png` that could not be faked, and it is what
finally exposed the 95 ms `Number(uint8array)` stall — because a number can be wrong quietly
and a stuttering dot cannot.

## Cheap robustness, taken on the way past

  1. **A failed kernel loses its message.** The worker posts `err: 'OutOfMemory'` (or whatever
     the kernel returned); `poll` collapses every one of them to `error.KernelFailed`. A
     kernel that fails currently tells you nothing at all. The string is already crossing the
     boundary — keep it.

  2. **`submit` still allocates its staging buffer per dispatch.** This is the same bug just
     fixed on the OUTPUT side (`pollInto`), still live on the input side: `gpa.alloc(total)`
     every submit, ~15 ms for 4 MB. A Group submitting 64 tiles pays it 64 times.

  3. **`worker_png` hard-codes an 8 MB result buffer.** It should ask: `registry.max_output`.
     A hand-typed constant that drifts from the registry does not fail loudly — it fails as
     `Error.OutputTooLarge`, on a phone.

## Not doing, and why

  * **`Compute(.worker)` fan-out** (splitting a kompute id range across workers). Tempting,
    and the wrong order: `.worker` ships the WHOLE `Buffers` image both ways, so N workers
    would mean N copies in and an ambiguous merge out. Build the plain-jobs fan-out first,
    let a real consumer teach us the API, and only then decide whether kompute should borrow
    it. This is exactly the mistake HOLE 6 caught — `.worker` existed for weeks with no
    consumer and quietly carried a cross-contamination bug the whole time.

  * **A speedup benchmark.** The pool is capped at 4 workers ON PURPOSE. Selling throughput
    would be selling a number the engine declined to optimise.

## The rule this plan is built on

`Group` and `rt_workers` ship TOGETHER. The tracer is the only thing that can prove the API
is the right shape, and the API is the only thing that makes the tracer readable.

A feature with no consumer has no evidence behind it, only intentions — and we have now paid
for that lesson twice in one system.
