# GPU compute system — improvement plan

Refactor the `kompute` / `compute_host` / build machinery to be more ergonomic,
typesafe, and debuggable, **without touching `spv2wgsl`** (transpiler changes are
a deliberate later pass). The core design — one Zig source → SPIR-V kernel + CPU
oracle — stays. We are fixing the seams that have already drawn blood.

**Status:** the active plan (the current plan in `claude.md`). Step 1 core LANDED
and verified: the `max_kernels` cap is gone (heap-sized pipeline/name registry, no
fixed array to fold-to-trap), an assertf precondition sweep covers `compute_host`
(initGpu inputs, upload capacity, batch open/close, run capacity), pipeline-build
failures are caught by `assertf` on the `.invalid` module / pipeline handles, the
silent not-found `unreachable` in `run` is now an `assertf(false, …)`, and
`Compute.deinit` frees the registry. (assertf was also unified — see Decisions —
to be byte-identical to `std.debug.assert` in ship while logging your message in
dev; `alwaysAssert` is now effectively unused.) `compute_host`'s own
`std.debug.assert` uses are migrated. Sort standalone builds clean with all 11
`@compute` kernels verified present in the wasm. REMAINING in Step 1: the
`std.debug.assert` ban lint rule + repo-wide callsite migration (a ~11-file sweep
that flips the gate on — its own focused pass). Then Steps 2–6.

## Decisions (locked)

- **Bind groups: per-kernel.** Each kernel gets a layout + bind group containing
  only the fields it actually uses (+ the uniform). Retires the shared-megabind
  group and the `maxStorageBuffersPerShaderStage` band-aid in `bridge.zig`.
- **Kernel set: module-declared list.** The kernel file owns one
  `pub const kernels` list; `installKernel` and the host's `initGpu` both derive
  from it. build.zig keeps its `ComputeKernel.entries` (no manifest plumbing this
  pass), but name drift now surfaces as a **compile error** (missing `@embedFile`).
- **Dispatch width: `run(name, n)`.** Explicit per-call width; `pipe.count` is
  retired as a dispatch input.
- **`assertf` on every precondition; `assertf` IS our `std.debug.assert`.**
  Unified in utils.zig: on failure it lowers to `fail()` (your log + panic +
  `@src()`) when asserts are on — Debug, or ReleaseSmall with `-Dassert-log` (our
  dev build) — and to a bare `unreachable` when stripped, i.e. byte-identical to
  `std.debug.assert` in ship (assumed-true; the optimizer uses the fact). So it is
  a true drop-in for `std.debug.assert` with strictly better dev diagnostics. Gate
  an *expensive* condition behind `if (comptime utils.allow_assert) { … }`.
  `alwaysAssert` (never stripped) is reserved for the extremely rare invariant
  whose failure is silent persistent corruption — currently unused, a candidate
  for removal.

## Cross-cutting: the assertf precondition sweep

Every public fn in `compute_host.zig` (and the comptime-checkable spots in
`kompute.zig`) asserts its preconditions with `assertf(ok, @src(), "...", .{...})`.
The named ones that matter:

- `initGpu`: `kernels.len >= 1`; each name non-empty; each wgsl non-empty;
  `@sizeOf(Buffers) > 0`; each module / pipeline handle `!= .invalid` (a failed
  build was the silent device freeze). In Step 4: `assertf` that each kernel's
  storage-binding count `<= device.maxStorageBuffersPerShaderStage` and that the
  parsed `@workgroup_size` equals `config.workgroup` (closes the
  double-declaration footgun with a loud dev message).
- `run`: backend set; `n > 0`; `n <= config.max`. Replace the `unreachable` for an
  unknown kernel name with `assertf(false, @src(), "kernel '{s}' not registered", .{name})`
  — currently a silent UB trap, becomes a named error.
- `upload`: `data.len <= field capacity`.
- `beginBatch`/`endBatch`: upgrade the existing `std.debug.assert` batch-state
  checks to `assertf` with messages; assert params unchanged mid-batch (see Step 6).
- Comptime (`Compute(M)` / `installKernel`): each `Buffers` field is an array
  type; `@sizeOf(Params) % 16 == 0` (Step 6).

**Enforcement — new lint rule (ban `std.debug.assert`).** Add a check to
`tools/lint_zimr.zig` that flags any `std.debug.assert` use (and the
`const assert = std.debug.assert;` alias) with the message: *"use `assertf` /
`assert` (src/utils.zig) instead — they are identical to `std.debug.assert` in
ship, but in our dev build (ReleaseSmall + `-Dassert-log`) they log your message
+ `@src()` and panic, whereas `std.debug.assert` is a silent `unreachable` there
(no check, no message)."* Because the utils asserts are now a true drop-in for
`std.debug.assert` (same ship codegen), migration is mechanical: `std.debug.assert(x)`
→ `assert(x)` (no message) or `assertf(x, @src(), "…", .{})` (with one). The rule
is repo-wide (lint runs over `src/`, `examples/`, `tests/`), so flipping the gate
on requires first migrating the existing callsites (~11 source files); any
genuinely-needed std site (e.g. inside the utils wrapper itself) opts out with a
trailing `// lint:off` directive. Sequencing: `compute_host`'s own uses are
already migrated; the repo-wide sweep + gate flip is its own focused pass.

## Steps (each independently landable + build-green)

### Step 1 — Safety net first (no behaviour change)
- Remove the `max_kernels` fixed-array cap: heap-allocate `pipelines` /
  `kernel_names` to `kernels.len` in `initGpu` (free in `deinit`). No cap → no
  fold-to-trap → no silent DCE. *This alone removes the worst failure mode.*
- Run the assertf precondition sweep above (the parts that don't depend on later
  steps).
- Add the `std.debug.assert` ban lint rule (above), migrate the existing callsites
  repo-wide to `assertf` / the utils `assert`, and flip it on as a build gate so the
  practice is enforced from here on.
- Surface pipeline-build failures: `assertf` that each created module / pipeline
  handle is not `.invalid` (the wgpu binding has no push/pop error scope, so the
  `.invalid` handle is the signal). A failed build becomes a logged dev message
  instead of a frozen device. **DONE.**
- **Verify:** build `wgpu-fluid-sort-standalone`; sort runs identically; wasm still
  carries all 12 `@compute` entries.

### Step 2 — Module-declared kernel list
- Add to `sort_kernels.zig`: `pub const kernels = [_][:0]const u8{ "clearGrid", ... };`
  (names only; `config.workgroup` stays the single per-module workgroup).
- `installKernel`: add `k.installKernels(@This())` that `inline for`s `M.kernels`
  and installs each (keep `installKernel` for the single-kernel case).
- The example builds the `KernelWgsl` array with a comptime loop over `fk.kernels`,
  `@embedFile(name ++ "_wgsl")` per entry — no hand-listing. A name in `fk.kernels`
  that build.zig didn't generate → `@embedFile` compile error (drift caught).
- **Verify:** build; identical behaviour; deliberately add a bogus name to
  `fk.kernels` once to confirm it fails to compile, then remove.

### Step 3 — `run(name, n)`
- Change `run` to `run(self, comptime name, n: u32)`; dispatch
  `ceil(n / config.workgroup)`. assertf `n > 0` and `n <= config.max`.
- Keep a `pipe.element_count` (set once) purely for variable-length readback
  slicing; `readLatest` slices by the field's own length (the existing
  `@min(element_count, arr_len)` clamp, with `count` renamed).
- Update the sort host: `pipe.count = X; pipe.run("k")` → `pipe.run("k", X)`
  (clearGrid→`grid_cells`, prefixSum→`1`, the rest→`num_particles`).
- **Verify:** build; sort runs identically.

### Step 4 — Per-kernel bind groups (the structural fix)
- In `initGpu`, parse **each kernel's** WGSL separately (extend `parseBindings` to
  return a per-kernel field set + binding numbers; binding numbers are already
  globally consistent across entries, so sparse-but-correct).
- Build one `BindGroupLayout` + `BindGroup` per kernel containing only that
  kernel's fields + the uniform. Store them alongside the pipelines.
- `run` sets the kernel's own bind group (and, for batch, the open pass binds it
  per dispatch).
- `assertf` per-kernel storage-binding count `<= device limit`.
- Remove (or leave inert) the `requiredLimits` raise in `bridge.zig` advance().
- **Verify:** build; sort runs identically (`clearGrid` now declares 1 storage
  binding, `density`/`force` ~5 — none over 8). This is the change that makes the
  sort viable on a stock 8-buffer device.

### Step 5 — Validation gate + error surfacing
- Wire `wgsl-validate` (naga) into the compute-app build as a **default gate** so
  every generated kernel is validated at build time (uniformity / dup-var bugs die
  before the device, on any driver).
- Finish the device error-scope plumbing from Step 1 if deferred.
- **Verify:** build runs validation on all sort kernels and passes.

### Step 6 — Typesafety + introspection polish
- Comptime `@compileError` in `Compute(M)` if `@sizeOf(Params) % 16 != 0` (catches
  std140 uniform-mismatch garbage at build time).
- `pipe.describe()` → logs each kernel: fields bound, binding numbers, workgroup,
  last dispatch width. Read the compute state instead of decoding base64 wasm.
- Fix batch-params semantics: `beginBatch(params)` takes params explicitly and
  records them; assert (assertf) if `self.params` differs at `endBatch` — kills the
  current "params set after beginBatch silently ignored, runs one frame stale" trap.
- **Verify:** build; `describe()` output matches expectations; sort runs identically.

## Ordering rationale & risk

1 → 2 → 3 → 4 → 5 → 6. Safety net (1) lands first so that the riskiest change (4,
which touches the exact bind-group code that caused the original freeze) runs with
asserts + error surfacing already in place: a regression there now produces a named
message, not a silent freeze. Steps 2–3 are mechanical and shrink the diff that 4
has to reason about. 5–6 are hardening once the structure is right. Every step is a
green build of `wgpu-fluid-sort-standalone` with the sort behaving identically.

## Deferred (explicitly out of scope this pass)
- `.zon` manifest read by build.zig (would also unify workgroup size into one
  source) — the clean endgame, but build plumbing; revisit after this lands.
- spv2wgsl emitting structured binding info (would retire WGSL text-parsing).
- `g.bind`-per-field boilerplate reduction (blocked by the spv2wgsl let-copy bug).
- Formal warmup/prime hook (the `sort_primed` flag is adequate).
