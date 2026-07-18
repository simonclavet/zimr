# gpu-compute-tutorial.md — compute in zimr, CPU and GPU from one source

Written turn ~965, BEFORE the ergonomic layer is built. This is the SPEC:
the API described here is what we're committing to. If later code disagrees with
this tutorial, the code is wrong (or this tutorial gets a deliberate edit + a
note saying why). Examples use the end-state API; today only the kernel-shape +
spv2wgsl --workgroup + the readback primitives exist (turn 964).

Read this when:
- You want to run a parallel computation (particles, image filters, simulations).
- You want the SAME algorithm to run on the CPU or the GPU with a runtime toggle.
- You hit a "why is compute shaped like this" question.

Sections flagged **[WEIRD?]** are places the design still smells — collected at
the end too. The whole point of writing this first is to find them.


---

## ⚠ VERIFIED CONSTRAINT (turn 965, found BY writing this tutorial)

I tested the obvious API — kernel takes `c: Ctx` and writes `c.buffers.data[id]`
— and it DOES NOT TRANSPILE. Passing the storage buffer through a struct field
(a pointer) makes spv2wgsl emit a `let copy` then write through it -> naga
"invalid left-hand side of assignment". This is the same by-pointer bug we chose
NOT to fix (decision turn 963: module-level globals are the better design anyway).

So the kernel shape below is the CORRECTED, VERIFIED one:
- **Buffers are accessed via MODULE-LEVEL per-field aliases** (t1178):
  `const b_pos = g.bind(.pos);` then `b_pos[id]`. One alias per `Buffers`
  field; `bind` returns a pointer-to-array that indexes directly. Never reach
  buffers through a ctx field (the let-copy bug), and never through a single
  whole-struct binding (the Adreno megastruct bug — see the next section).
  VERIFIED: naga ok, and stable at 20k particles on Adreno 7xx.
- **Params CAN ride in a ctx by value** (`c.params.count`) — read-only, no
  write-through, so no copy bug. VERIFIED: naga ok.
- **`id` is passed by value.** Trivial.

Net: the kernel takes `(c: k.Ctx(@This()))` where `c` carries `id` + `params`
(both by value), and BUFFERS are reached through a generated module name `b`
(so `b_pos[c.id]`). The generator wires `b`, the entry, and the `g`-namespace.
The earlier `c.buffers.X` examples in this doc are WRONG and corrected inline.

---

## The per-field binding rule (t1178 — the Adreno conviction)

kompute originally bound ALL buffers as one storage binding: a single
`extern var B: Buffers` megastruct of fixed-size arrays, every access carrying
a large constant field offset (`vel` at +320000, `density` at +640000, ...).
On desktop this was fine. On Qualcomm Adreno 7xx (Chrome Android, Vulkan
backend) it corrupted catastrophically above ~1000 invocations: writes landed
in the WRONG FIELD (a density sentinel value appearing inside `pos[0]`),
particles exploded, ~96% of writes went missing. A two-day bisection — CPU/GPU
duality builds, write-pattern oracles, a hand-rolled twin — proved every other
layer correct: the same kernels, same bridge, same submits, with **one buffer
+ one binding per field** ran 20,000 particles flawlessly on the same phone
(matching every hand-written WebGPU demo's shape).

So kompute now emits ONE STORAGE BINDING PER `Buffers` FIELD:

- The kernel file aliases each field once: `const b_pos = g.bind(.pos);`.
- `g.bind` is an `@extern` per field on GPU (`kbuf_<name>`, runtime-sized
  `array<T>` in WGSL) and `&g.B.<name>` on CPU — the duality is unchanged.
- Binding NUMBERS are assigned by the SPIR-V backend in use-order; the host
  (`initGpu`) PARSES them back out of the generated WGSL headers, so host and
  shader cannot disagree and no ordering contract exists.
- `pipe.upload(.field, ...)` writes the field's own buffer at offset 0;
  readback copies each field buffer into one `Buffers`-shaped staging, so
  mirrors and the CPU twin are byte-identical to before.
- Renderers bind fields directly: `pipe.fieldBuffer(.pos)` (see `FluidDiscs`,
  which takes positions + density as two `BufRegion`s).

---

## 0. The 30-second pitch

A compute kernel is a plain Zig function over arrays. You write it once. zimr
runs it as a GPU compute dispatch OR a CPU loop — same source, same results,
chosen at runtime:

```zig
sim.backend = .gpu;   // or .cpu
sim.run(.integrate);  // dispatch on GPU, or `for id: integrate(id)` on CPU
```

That duality is the whole reason zimr is on WebGPU. The northstar is an SPH
fluid you can toggle between a 2k-particle CPU sim and a 50k-particle GPU sim
with one button, running the identical Zig.

---

## 1. Your first kernel: double an array

A kernel lives in its own `.zig` file. Three things: the data (`Buffers`), the
knobs (`Params`), and one or more kernel functions.

```zig
// double_it.zig
const z = @import("zimr");
const k = z.compute;            // the compute DSL

pub const config = k.Config{
    .max = 1024,                // capacity (fixed; GPU arrays must be sized)
    .workgroup = 64,            // threads per workgroup
};

pub const Buffers = extern struct {
    data: [config.max]f32,      // a storage buffer (its own binding on GPU)
};

pub const Params = struct {
    count: u32,
};

// The kernel. `c` is the compute context: c.id is this invocation's index,
// c.params is your Params (by value); BUFFERS are reached via `b` (module-level).
pub const g = k.Globals(@This());
const b_data = g.bind(.data);     // one module-level alias per Buffers field

pub fn double(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) return;
    b_data[c.id] *= 2.0;          // through the alias, NOT c.buffers
}
```

That's the entire kernel file. No `addrspace`, no `callconv`, no
`global_invocation_id`, no `@workgroup_size`. The `k.Ctx(@This())` type is
generated from your `Buffers`/`Params` — it's `struct { id: u32, buffers: ...,
params: ... }`, and it's the SAME type whether this runs on CPU or GPU.

> **[RESOLVED-ish #1 — `b` not `c.buffers`; and the `[]f32` lie.]** Buffers
> are reached via module-level `b` (verified constraint above). Separately, the `data: []f32` reads as a slice, but on GPU
> it's a fixed `[max]f32` storage buffer and `.len` is `config.max`, not the
> live count (that's why `Params.count` exists separately). Options considered:
> (a) keep `[]f32` and document that `.len == capacity` — familiar but the slice
> length is a half-truth; (b) use `k.Buffer(f32)` — honest, but a new type to
> learn and `c.buffers.data[i]` needs to still index naturally; (c) expose it as
> `*[config.max]f32` — most honest, ugliest. LEANING (b): `k.Buffer(T)` that
> indexes like an array, has `.len = capacity`, and makes the "this is a GPU
> resource, not a heap slice" obvious. Decide before building.

Run it from the host:

```zig
var pipe = try z.Compute(@import("double_it.zig")).init(gpa, frame);
defer pipe.deinit();

// upload input
const input = [_]f32{ 1, 2, 3, 4, 5 };
pipe.buffers.data.upload(&input);      // CPU: memcpy; GPU: queue.writeBuffer
pipe.params = .{ .count = input.len };

pipe.run(frame, .double);              // dispatch (GPU) or loop (CPU)

// read the result back
const out = try pipe.buffers.data.read(gpa, frame, input.len);  // []f32
// out == { 2, 4, 6, 8, 10 }
```

On `.cpu` the `read` is instant (the data is already in CPU memory). On `.gpu`
it issues a copy-to-staging + maps the buffer; see §6 on the async wrinkle.

> **[WEIRD? #2 — `pipe.buffers.data.upload(...)` vs `pipe.params = ...`.]**
> Buffers get methods (`.upload`, `.read`); params is a plain struct you assign.
> Asymmetric. Is that OK? Params is small + per-frame (set every dispatch);
> buffers are big + persistent (uploaded rarely). The asymmetry mirrors the
> usage. But `pipe.buffers.data.upload` is a mouthful. Alternative:
> `pipe.upload(.data, &input)` keyed by field. Cleaner call site, but loses the
> "the buffer is a thing with methods" model. LEANING toward `pipe.upload(.data,
> slice)` + `pipe.read(.data, n)` — uniform with `pipe.run(.kernel)`, everything
> keyed by an enum field name.

---

## 2. The CPU/GPU toggle — the headline feature

The same kernel file, one switch:

```zig
var pipe = try z.Compute(@import("double_it.zig")).init(gpa, frame);
pipe.backend = .gpu;   // or .cpu — flip it any time, even per frame
```

- `.cpu`: `Buffers` is a heap struct. `run(.double)` is literally
  `var id=0; while (id<count) : (id+=1) double(ctx(id));`. Zero GPU. (Later:
  auto-multithreaded over id-ranges — the kernel discipline makes it safe.)
- `.gpu`: `Buffers` are GPU storage buffers. `run(.double)` sets the uniform and
  dispatches `ceil(count / workgroup)` workgroups.

The kernel source is byte-identical. The toggle exists because the SAME Zig
compiles to a CPU loop body AND a SPIR-V compute entry (verified turn 962).

> **[WEIRD? #3 — what does `.read` mean mid-frame on GPU?]** On CPU, results are
> ready the instant `run` returns. On GPU they're not ready until the queue
> finishes + you map the buffer (async). So `pipe.read(.data, n)` can't be
> synchronous on GPU without stalling the pipeline. See §6 — this is the one
> genuinely hard ergonomic seam and it deserves its own answer, not a footnote.

---

## 3. A real example: N-body gravity (multiple kernels, ping-pong)

Particles attract each other. Two passes per frame: compute accelerations, then
integrate. We need last-frame positions while writing this-frame — a classic
double-buffer (ping-pong).

```zig
// nbody.zig
const z = @import("zimr");
const k = z.compute;
const zm = z.math;

pub const config = k.Config{ .max = 8192, .workgroup = 64 };

pub const Buffers = struct {
    pos:  k.Buffer(zm.Vec2),
    vel:  k.Buffer(zm.Vec2),
    acc:  k.Buffer(zm.Vec2),
};
pub const Params = struct { count: u32, g: f32, dt: f32, soften: f32 };
pub const g = k.Globals(@This());
const b_pos = g.bind(.pos);
const b_vel = g.bind(.vel);
const b_acc = g.bind(.acc);

// Pass 1: gather — each body sums the pull of all others. GATHER, not scatter:
// body `id` writes ONLY acc[id]. No cross-particle writes -> no atomics ->
// identical on CPU and GPU.
pub fn accel(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) return;
    const me = b_pos[c.id];
    var a = zm.vec2(0, 0);
    var j: u32 = 0;
    while (j < c.params.count) : (j += 1) {
        if (j == c.id) continue;
        const d = b_pos[j] - me;
        const r2 = zm.dot2(d, d) + c.params.soften;
        a += d * zm.splat2(c.params.g / (r2 * zm.sqrt(r2)));
    }
    b_acc[c.id] = a;
}

// Pass 2: integrate. Reads acc (written by pass 1), updates vel + pos.
pub fn integrate(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) return;
    b_vel[c.id] += b_acc[c.id] * zm.splat2(c.params.dt);
    b_pos[c.id] += b_vel[c.id] * zm.splat2(c.params.dt);
}
```

Host, per frame:

```zig
pipe.params = .{ .count = n, .g = 6.67e-3, .dt = dt, .soften = 0.5 };
pipe.run(frame, .accel);       // barrier between passes is automatic
pipe.run(frame, .integrate);
```

> **[WEIRD? #4 — where did the ping-pong go?]** I claimed we'd need it, then
> didn't use it: accel reads pos + writes acc (different buffers), integrate
> reads acc + writes vel/pos (pos read-then-write is fine within one invocation).
> So N-body needs NO ping-pong. But SPH's density-relax DOES (it reads all
> neighbours' positions while nudging its own — if you write pos[id] mid-pass,
> neighbours see the new value). The design must SUPPORT ping-pong cleanly even
> though simple cases dodge it. Proposed: a buffer can be declared
> `k.Buffer(T).pingpong` and `c.buffers.pos` reads the front, `c.buffers.pos_next`
> writes the back; `pipe.swap(.pos)` flips them. Is `pos` / `pos_next` too magic?
> Alternative: explicit two buffers `pos_a`/`pos_b` + the kernel takes which is
> read/write — but that fights the "buffers are fixed module globals" model.
> UNRESOLVED. This is the most important thing to get right for SPH.

> **[WEIRD? #5 — the O(n²) loop reads `c.buffers.pos[j]` 8000 times.]** On GPU
> that's 8000 global-memory loads per thread. Real N-body uses shared/workgroup
> memory tiling. Do we expose `var<workgroup>` arrays? std.gpu has the address
> space. But it complicates the kernel (barriers, tile loops) and BREAKS the CPU
> duality (no workgroup concept on CPU). DECISION NEEDED: do we (a) stay simple
> + slow (gather from global, duality intact), (b) offer an opt-in
> `k.shared(T, N)` tile that the CPU path treats as a plain stack array +
> barriers as no-ops, or (c) punt workgroup memory entirely for v1. LEANING (c)
> for v1, (b) eventually — but the tutorial should not pretend tiling exists yet.

---

## 4. Rendering the result without a CPU round-trip

The win of GPU compute is the data never leaves the GPU. The position buffer
that `accel`/`integrate` wrote can be drawn directly as instanced points:

```zig
pipe.run(frame, .accel);
pipe.run(frame, .integrate);
// draw 'count' points, each reading its position from the pos buffer:
z.drawPointsFromBuffer(frame, pipe.buffers.pos, n, .{ .size = 2, .color = c.white });
```

On `.cpu`, the same call reads `pipe.buffers.pos` (a CPU slice) and uses the
normal `drawCircleV` batch. One call, both backends, zero explicit readback.

> **[WEIRD? #6 — `drawPointsFromBuffer` is a new render entry.]** It needs a
> vertex shader that indexes the storage buffer by `instance_index`. That's a
> real (tiny) vs/fs pair shipped with zimr. Fine. But it also means a GPU storage
> buffer must ALSO be usable as a vertex-shader-readable resource (usage flags
> STORAGE | VERTEX-readable). Verify WebGPU allows the same buffer bound
> read-only-storage in a render pass. (It does, via read-only storage in the
> vertex stage.) Note for implementation.

---

## 5. Image filter: a 2D dispatch

Compute isn't only 1D. A blur over an HxW image dispatches a 2D grid:

```zig
// blur.zig
pub const config = k.Config{ .max = 1920 * 1080, .workgroup = .{ 8, 8 } };  // 2D wg
pub const Buffers = struct { src: k.Buffer(zm.Vec4), dst: k.Buffer(zm.Vec4) };
pub const Params = struct { w: u32, h: u32, radius: i32 };

pub fn blur(c: k.Ctx(@This())) void {
    if (c.xy[0] >= c.params.w or c.xy[1] >= c.params.h) return;  // c.xy is 2D id
    var sum = zm.vec4(0,0,0,0);
    var n: f32 = 0;
    var dy = -c.params.radius;
    while (dy <= c.params.radius) : (dy += 1) {
        // ... sample b_src at (x+dx, y+dy), accumulate ...
    }
    b_dst[c.xy[1] * c.params.w + c.xy[0]] = sum * zm.splat4(1.0 / n);
}
```

```zig
pipe.dispatch2d(frame, .blur, .{ params.w, params.h });
```

> **[WEIRD? #7 — `c.id` (1D) vs `c.xy` (2D) vs `c.xyz` (3D).]** A kernel uses one
> of them depending on its dispatch dimensionality. Having three fields where you
> use one is clunky. Options: (a) always give `c.gid: @Vector(3,u32)` and the
> kernel takes `c.gid[0]` etc. — uniform but you index a vec for 1D (`c.gid[0]`
> everywhere is noisy); (b) the three named accessors as above (`c.id`/`c.xy`/
> `c.xyz`) — readable but you must pick the right one; (c) make `Ctx` itself
> parameterized by dimensionality so a 1D kernel only HAS `c.id`. LEANING (c):
> `k.Ctx1`/`k.Ctx2`/`k.Ctx3` or infer from `config.workgroup` being a scalar vs
> array. Cleanest if it can be inferred from config.

---

## 6. The async readback seam (the one hard part, stated plainly)

GPU results are not ready when `run` returns. WebGPU map is async. zimr's wasm
loop is synchronous. So a synchronous `pipe.read(.data, n)` on GPU would have to
stall the whole frame — unacceptable for a 60fps sim.

The design must pick ONE of these and commit:

A. **Frame-delayed read (recommended).** `pipe.read(.data, n)` returns last
   frame's data immediately (it kicks off this frame's copy, returns the
   previously-mapped result). One frame of latency, never stalls. Perfect for
   "draw the particles" (you don't care that positions are 16ms old) and for
   HUD/debug. The API: `pipe.readLatest(.data)` -> `?[]T` (null until the first
   read completes). Most sims never need synchronous reads — they render from the
   GPU buffer directly (§4) and only read back for debug/save.

B. **Explicit async with a poll.** `var rb = pipe.readBegin(.data, n);` then
   `if (rb.ready()) { const out = rb.get(); }`. Honest, but viral — callers
   manage handles. Mirrors the primitive we built (turn 964).

C. **Callback.** `pipe.read(.data, n, onData)`. Un-Zig-like, avoid.

LEANING A as the headline API (`readLatest`), with B (`readBegin`/poll) available
underneath for the rare "I need exactly this frame's data" case. The CPU backend
makes both trivial (data is already there; `readLatest` returns it with zero
latency, so the one-frame skew only exists on GPU — **[WEIRD? #8]** the toggle
changes read latency by a frame. Document loudly, or make CPU also one-frame-
delayed for behavioural parity? Parity is tempting but adds pointless latency to
the CPU path. LEAN: document the skew, don't fake it.)

---

## 7. The northstar: SPH you can toggle

```zig
// sph.zig — Clavet 2005 viscoelastic fluid, gather-form
pub const config = k.Config{ .max = 50_000, .workgroup = 64 };
pub const Buffers = struct {
    pos: k.Buffer(zm.Vec2).pingpong,    // ping-pong (density relax nudges pos)
    vel: k.Buffer(zm.Vec2),
    rho: k.Buffer(zm.Vec2),             // (rho, rho_near)
    cell_start: k.Buffer(u32),          // grid: prefix-summed cell offsets
    cell_count: k.Buffer(u32),          // grid: atomic<u32> counts (see below)
    sorted_idx: k.Buffer(u32),
};
pub const Params = struct { count: u32, dt: f32, gravity: f32, k_far: f32,
                            k_near: f32, rho0: f32, h: f32, /* ... */ };

pub fn integrate(c: k.Ctx(@This())) void { /* gravity + advect; pos_next = pos+vel*dt */ }
pub fn gridClear(c: k.Ctx(@This())) void { b_cell_count[c.id] = 0; }   // over CELLS
pub fn gridCount(c: k.Ctx(@This())) void {
    const cell = cellOf(b_pos[c.id], c.params);
    _ = c.atomic(.cell_count, cell).add(1);   // atomic<u32> — integers, WGSL OK
}
pub fn gridScatter(c: k.Ctx(@This())) void { /* place id into sorted_idx via cell_start */ }
pub fn density(c: k.Ctx(@This())) void { /* GATHER 9 cells -> rho[id] */ }
pub fn relax(c: k.Ctx(@This())) void {    /* GATHER -> pos_next[id] from pressure */ }
pub fn viscosity(c: k.Ctx(@This())) void {/* GATHER -> vel[id] impulses */ }
pub fn finalize(c: k.Ctx(@This())) void { /* vel = (pos_next - pos)/dt; clamp walls */ }
```

```zig
// one frame
pipe.params = .{ .count = n, .dt = dt, ... };
pipe.run(frame, .integrate);
pipe.run(frame, .gridClear);
pipe.run(frame, .gridCount);          // dispatched over particles
pipe.prefixSum(.cell_count, .cell_start);  // [WEIRD? #9] — see below
pipe.run(frame, .gridScatter);
pipe.run(frame, .density);
pipe.run(frame, .relax);
pipe.swap(.pos);                      // ping-pong flip
pipe.run(frame, .viscosity);
pipe.run(frame, .finalize);
z.drawPointsFromBuffer(frame, pipe.buffers.pos, n, .{ .size = 3 });
// toggle: pipe.backend = if (button) .gpu else .cpu;  // identical results
```

> **[WEIRD? #9 — prefix sum is not a kernel you can write per-element.]** A
> parallel prefix-sum (scan) is a multi-step algorithm, not a one-liner kernel.
> Options: (a) zimr ships `pipe.prefixSum(src, dst)` as a built-in (a canned
> multi-pass scan) — convenient, but it's a magic op outside the kernel model;
> (b) the user writes the scan kernels themselves — pure but everyone rewrites
> the same hard thing; (c) for v1, do the grid build on the CPU even in GPU mode
> (the counts/sort is cheap relative to the O(n·neighbours) passes) — pragmatic,
> keeps the GPU path to the hot passes, but breaks "all on GPU". LEANING (a): a
> small library of canned parallel primitives (prefixSum, sort, reduce) is worth
> having and they compose with user kernels. But it IS a second category of
> thing. Flag it.

> **[WEIRD? #10 — `c.atomic(.cell_count, cell).add(1)`.]** Atomics only make
> sense on GPU; on CPU it's a plain `+= 1` (single-threaded) or a real atomic
> (when we multithread). The `c.atomic(.field, index)` accessor hides that. But
> it means `cell_count` must be declared as an atomic-capable buffer
> (`k.Buffer(u32).atomic`?) so the GPU emits `array<atomic<u32>>`. Another buffer
> flavour. And atomics are the ONE place the CPU/GPU code genuinely differs in
> spirit (even if the accessor unifies the syntax). Verify atomic<u32> survives
> our spv2wgsl (NOT yet tested — flagged as a risk in the plan).

---

## 8. Mental model summary

- A kernel file = `config` + `Buffers` + `Params` + kernel `fn`s taking `k.Ctx`.
- `z.Compute(Module)` builds a pipe; `.backend` toggles CPU/GPU.
- `pipe.run(frame, .kernelName)` = dispatch (GPU) or loop (CPU).
- Buffers stay on the GPU; render from them directly; read back only for debug.
- Discipline that makes the duality work: kernels GATHER (write only your own
  slot), never scatter. Atomics + prefix-sum are the escape hatches for the grid.

---

## Collected smells to resolve before building (priority order)

1. **#6/#3 async readback (§6)** — the one hard seam. Commit to `readLatest`
   (frame-delayed) as headline + `readBegin`/poll underneath. HIGHEST.
2. **#4 ping-pong (§3)** — SPH needs it. Decide `.pingpong` + `pos`/`pos_next` +
   `swap`, vs explicit. Get this right or SPH is ugly. HIGH.
3. **#9 prefix-sum / canned primitives** — grid build needs scan. Decide: ship
   `pipe.prefixSum`/`sort`/`reduce` as built-ins, or CPU-grid-in-GPU-mode for v1.
4. **#10 atomics** — verify atomic<u32> through spv2wgsl FIRST; then `c.atomic`
   accessor + `k.Buffer(u32).atomic` flavour.
5. **#1 `k.Buffer(T)` vs `[]T`** — pick the honest buffer type. Affects every
   kernel's signature, so decide early.
6. **#2 upload/read API shape** — `pipe.upload(.field, slice)` / `pipe.read` keyed
   by enum, uniform with `pipe.run(.kernel)`. Easy, just commit.
7. **#7 1D/2D/3D ctx** — infer dimensionality from config.workgroup; `c.id` for
   1D, `c.xy` for 2D. Mechanical.
8. **#5 workgroup/shared memory** — PUNT for v1 (breaks CPU duality). Note it's
   absent so the tutorial doesn't overpromise.
9. **#8 read-latency skew CPU vs GPU** — document, don't fake parity.

The kernel-authoring shape (Buffers/Params/Ctx + gather discipline) feels right
and is verified-implementable. The smells are almost all in the HOST API
(readback, ping-pong, primitives) — which is good: the part the user writes most
(kernels) is the settled part.

---

## Math in kernels — `zm`, the same everywhere (verified turn ~979)

Math in a kernel comes from `zimrmath` (`zm`) — the SAME module CPU code and graphics
shaders use. Reach it via the DSL: `const k = @import("kompute"); const zm = k.math;`
(`k.math` is just zimrmath re-exported). The vector + scalar vocabulary lowers to SPIR-V
and passes naga in a compute kernel: `vec2`/`vec3`/`vec4`, `splat`/`splat2`, `dot2`/`dot3`/
`dot4`, `length2`/`length3`, `sqrt`, `floor`, `abs`, `sin`, `cos`, `atan2`, `min`, `max`,
`clamp`, `normalize`, plus `@Vector` arithmetic (`+ - * /`, `v[i]` component access).

Don't reach for `std.math` in a kernel — it isn't GPU-portable and the linter blocks it.
Anything missing belongs in `zimrmath` (gated `!is_gpu` with a verified GPU branch) so the
one definition works in all four contexts: comptime, CPU, graphics shaders, compute kernels.

> Gotcha: a `Params` UNIFORM must pad with scalar fields (`_pad0/1/2: u32`), not an array
> (`[3]u32` becomes `array<u32,3>` stride 4, which naga rejects in `uniform` — needs 16).
