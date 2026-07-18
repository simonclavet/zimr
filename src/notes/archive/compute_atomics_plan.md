# Pure-Zig performant GPU compute on WebGPU — the atomics plan (t1178+)

GOAL: performant, complete compute-shader capability on WebGPU, authored in
pure Zig, NOW — without waiting for Zig's SPIR-V backend to implement atomics.
The acceptance bar is the SPH sim matching a hand-written WGSL SPH (the
reference `sph_fluid-3.html`): a per-particle `atomicAdd` grid build, not the
current O(N×cells) single-writer scan.

## What was studied (and the conclusions)

### Mach `sysgpu` (mach-main/src/sysgpu)
- Architecture: a WGSL FRONTEND (Tokenizer → Parser → Ast → AstGen → `Air`,
  their typed IR) feeding MULTIPLE codegen backends FROM that one IR:
  `codegen/spirv.zig` (Vulkan), `msl.zig` (Metal), `hlsl.zig` (D3D12),
  `glsl.zig` (GL). Direction is **WGSL → {SPIR-V, MSL, HLSL, GLSL}**.
- CONCLUSION 1 (strategic): this is the OPPOSITE direction from zimr (Zig →
  SPIR-V → WGSL). For the BROWSER, Mach just ships the WGSL source — they never
  transpile SPIR-V→WGSL because they don't need to. This VALIDATES zimr's
  spv2wgsl as the right browser artifact (we author in Zig, not WGSL, but the
  shippable end product is WGSL either way). We are NOT switching to a WGSL
  frontend; pure-Zig shaders are the project's whole point.
- CONCLUSION 2 (their atomics are ALSO stubs): `AstGen.zig` lists
  `atomicLoad/atomicStore/atomicAdd  // unimplemented`; their SPIR-V `atomic_type`
  codegen just emits the element type. So Mach is NOT a working reference for
  EMITTING atomics — but their vendored `codegen/spirv/spec.zig` IS gold: it has
  the authoritative opcode numbers and operand layouts:
    OpAtomicLoad = 227  {result_type, result, pointer, memory:Scope, semantics}
    OpAtomicStore = 228 {pointer, memory:Scope, semantics, value}
    OpAtomicIAdd = 234  {result_type, result, pointer, memory:Scope, semantics, value}
  (Scope and MemorySemantics are <id>s of OpConstant u32, NOT literals.)

### SPIRV-Tools (SPIRV-Tools-main)
- `spirv-as` (tools/as/as.cpp) is the assembler that turns `.spvasm` → `.spv`.
  BUT building it needs cmake (ABSENT in-sandbox) + the SPIRV-Headers submodule
  (ABSENT; it's a DEPS git dep) + a python codegen step
  (`utils/generate_registry_tables.py`) to build grammar tables. NOT buildable
  here. So we CANNOT use spirv-as to make atomic test fixtures.
- `source/val/validate_atomics.cpp` IS the authoritative validity spec, captured:
  - Atomic pointer storage class must be one of {Uniform, StorageBuffer,
    Workgroup, …}. For our storage-buffer grid: **StorageBuffer**.
  - Result type of OpAtomicIAdd/Load must be an INTEGER SCALAR; the pointee data
    type must equal the result type. So `array<atomic<u32>>` ↔ u32 ops only.
  - Memory scope for WebGPU compute = **Device (1)** or **Workgroup (2)**;
    semantics **Relaxed (0)** is valid (WGSL atomics are relaxed).
- CONCLUSION 3: we don't need SPIRV-Tools at runtime at all. zimr already has a
  pure-Zig SPIR-V reader/writer (`tools/zspv.zig`) and an OpFunctionCall→intrinsic
  REWRITE engine (`tools/zspv_rewrite.zig`). Everything spirv-as/opt would give
  us, we either already have in Zig or don't need.

### The Zig SPIR-V backend gap (re-confirmed, with the way around it)
- `@atomicRmw` / `@atomicLoad` / `@atomicStore` → `error: TODO (SPIR-V):
  implement AIR tag atomic_rmw / atomic_load`. Hard blocker. (dev.704.)
- `extern fn zatomicAdd(...)` → `error(spirv_link): function calls invalid
  function` — Zig's SPIR-V LINKER rejects calls to undefined functions, so a
  bare extern intrinsic does NOT survive.
- **THE WORKING PATTERN (verified, compiles to 1316 bytes of SPIR-V):** a
  `pub noinline fn zatomicAdd(idx: u32, val: u32) u32` with a DUMMY BODY — EXACTLY
  the `zsample2d` template (zimrmath.zig:7934, a noinline helper whose call site
  `zspv_rewrite.zig` rewrites into `OpImageSampleImplicitLod`). Zig emits a real
  `OpFunctionCall` to the defined helper; we intercept that call. The body is
  never executed post-rewrite; `noinline` keeps it from being inlined away.

### The reference SPH (sph_fluid-3.html) — the exact target
```
@group(0) @binding(6) var<storage,read_write> gridCounts : array<atomic<u32>>;
@group(0) @binding(7) var<storage,read_write> gridData   : array<u32>;
...
let slotIndex = atomicAdd(&gridCounts[cellIndex], 1u);   // per-PARTICLE build
...
let n = min(atomicLoad(&gridCounts[cellIndex]), params.maxPerCell);  // neighbor read
```
- WORKGROUP_SIZE = 256 (zimr kompute already emits 64 — a tunable, not a gap).
- The shape: gridCounts is `atomic<u32>` EVERYWHERE it's touched (atomicAdd to
  build, atomicLoad to read, plain reset → atomicStore). gridData stays plain.

## PROOF OF CONCEPT (already run, end-to-end)
A kernel with `noinline zatomicAdd` + `extern var counts: [256]u32
addrspace(.storage_buffer)`:
  Zig → SPIR-V (1316 B) → current spv2wgsl → WGSL that contains:
    `@group(0) @binding(0) var<storage, read_write> counts: array<u32>;`
    `let _26: u32 = ky_zatomicAdd(_25, 1u);`
    `fn ky_zatomicAdd(p36: u32, p37: u32) -> u32 { ... }`
So spv2wgsl ALREADY reads the helper-call SPIR-V cleanly. The remaining work is a
well-defined WGSL-level transform.

## THE PLAN — lower atomic-helper calls in spv2wgsl (NOT in zspv)

DECISION: do the lowering in **spv2wgsl** (intercept the OpFunctionCall by helper
name and emit the WGSL atomic builtin), NOT by synthesizing OpAtomicIAdd in zspv.
Rationale: (a) we never have to manufacture valid atomic SPIR-V (scope/semantics
constant ids, capability decls) that we cannot test (no spirv-as, no validator);
(b) spv2wgsl already has the call site + the storage binding + the access-chain
info it needs; (c) the WGSL atomic builtins are the actual deliverable. zspv stays
untouched. If/when Zig emits real atomic SPIR-V, we ADD an `OpAtomicIAdd` arm to
spv2wgsl's opcode dispatch and DELETE the helper-intercept — same output, the
intrinsic helpers vanish from the kernels. The kernel-author API (`k.atomicAdd`)
does not change across that migration.

### Layer 1 — the kernel-author API (kompute / zimrmath)
Add three `noinline` helpers (mirroring zsample2d), exposed via the kompute Ctx
or a `k.atomic` namespace, so a kernel writes:
```
const slot = k.atomicAdd(&b_grid_counts, cell, 1);   // returns prev value
const n    = k.atomicLoad(&b_grid_counts, cell);
k.atomicStore(&b_grid_counts, cell, 0);
```
Signature shape that COMPILES on dev.704 (verified): the helper takes the BINDING
+ an index (not a raw pointer arg — pointer-into-storage params are awkward and
the link step is picky). Concretely a per-binding helper or a comptime-dispatched
one whose mangled name encodes the target field, so spv2wgsl can reconstruct
`atomicAdd(&<field>[idx], val)`. Helpers are `noinline`, dummy-bodied (e.g.
`return arr[idx] +% val;`), and live next to `zsample2d`. CPU twin: the SAME
helpers compile for native and run as ACTUAL atomics via `@atomicRmw` etc. (native
LLVM backend supports them — only the SPIR-V backend doesn't), so the CPU/GPU
duality is preserved and the CPU path is genuinely correct for the oracle tests.

### Layer 2 — spv2wgsl call-intercept + atomic-taint
1. RECOGNIZE: detect calls to functions whose (demangled) name matches
   `*zatomicAdd` / `*zatomicLoad` / `*zatomicStore`. Capture which STORAGE
   BINDING the first arg resolves to (follow the access chain / arg origin to the
   `OpVariable` for the field) + the index expression + (for add/store) the value.
2. EMIT the WGSL builtin at the call site:
   - add  → `atomicAdd(&<field>[<idx>], <val>)`  (expression; yields prev value)
   - load → `atomicLoad(&<field>[<idx>])`
   - store→ `atomicStore(&<field>[<idx>], <val>)`  (statement)
3. DELETE the helper `fn *zatomicAdd(...)` definitions from the output (like the
   sampler helper, they must not survive).
4. ATOMIC-TAINT the binding's element type: a storage binding that is the target
   of ANY atomic helper becomes `array<atomic<u32>>` instead of `array<u32>`.
   THEN — the hard part — EVERY OTHER access to that binding in the module must
   also go atomic, because WGSL forbids plain `[]` load/store on an `atomic<T>`:
     - a plain read  `counts[i]`        → `atomicLoad(&counts[i])`
     - a plain write `counts[i] = v`    → `atomicStore(&counts[i], v)`
   Implement as a per-binding bool set during a PRE-PASS over the function bodies
   (scan for helper-call targets → mark binding atomic), then in the emitter,
   when generating a load/store whose root variable is atomic-tainted, route to
   atomicLoad/atomicStore. This taint analysis is the main new logic; everything
   else is local.
5. CAPABILITY/HEADER: WGSL needs nothing extra for storage atomics (no enable
   directive — unlike f16). So no header change. (If we ever target SPIR-V output
   again we'd add OpCapability; not needed for WGSL.)

### Layer 3 — the parallel grid build (the actual perf win)
Rewrite `fluid_kernels.zig buildGrid` from per-CELL (dispatch = grid_cells,
scan all N) to per-PARTICLE (dispatch = N):
```
pub fn buildGrid(c: Ctx) void {        // dispatch count = particle count
    const i = c.id; if (i >= count) return;
    const cell = cellOf(b_pos[i], params);
    const slot = k.atomicAdd(&b_grid_counts, cell, 1);   // unique slot
    if (slot < max_per_cell) b_grid_data[cell*max_per_cell + slot] = i;
}
```
and the neighbor passes read `k.atomicLoad(&b_grid_counts, cell)` (min with
max_per_cell), reset counts with atomicStore between frames (or a separate clear
kernel / per-particle clear). Complexity drops O(N×cells) → O(N). This is the
literal shape of the reference's `buildCellCounts`/`assignParticles`.

### Layer 4 — testing without spirv-as
- WGSL OUTPUT GOLDEN: the PoC kernel (`ky.zig`) + the real fluid kernels →
  spv2wgsl → assert the emitted WGSL contains `array<atomic<u32>>` + `atomicAdd(`
  + `atomicLoad(` + NO surviving `zatomicAdd` helper fn. Add to the wgpu-corpus /
  a focused test.
- VALIDITY: the emitted WGSL is validated by naga/Tint (the existing naga-tint
  gate + the browser). The reference proves this exact WGSL shape is accepted.
- CPU ORACLE: the CPU twin runs real `@atomicRmw` (native backend) — a host test
  runs the per-particle buildGrid on CPU at full N and asserts the grid matches
  the single-writer reference grid (same buckets), so the algorithm is correct
  independent of the GPU path.
- NO hand-assembled SPIR-V needed anywhere — the helper-call SPIR-V comes from
  Zig (proven), and we never synthesize atomic SPIR-V.

## R2 DE-RISKED (verified this session) — the realistic helper compiles
A kompute-shaped helper taking the storage-buffer array pointer + index:
```
fn bindCounts() *addrspace(.storage_buffer) [256]u32 {
    return @extern(*addrspace(.storage_buffer) [256]u32, .{ .name = "kbuf_counts" });
}
pub noinline fn zatomicAdd(arr: *addrspace(.storage_buffer) [256]u32, idx: u32, val: u32) u32 {
    const prev = arr[idx]; arr[idx] = prev +% val; return prev;  // dummy body
}
```
COMPILES (1724 B SPIR-V). Current spv2wgsl emits:
```
@group(0) @binding(0) var<storage, read_write> kbuf_counts: array<u32>;
let _29: u32 = kz_zatomicAdd(_24, _28, 1u);          // <- the call to intercept
fn kz_zatomicAdd(p45_param: array<u32, 256>, ...) { ... }   // <- helper to DELETE
```
KEY IMPLEMENTATION DETAIL: arg0 of the call (`_24`) traces directly to the
BINDING variable `kbuf_counts` (spv2wgsl currently models the storage-pointer
param as a by-value `array<u32,256>` copy — irrelevant, since we DELETE the
helper and inline the atomic at the call site). So binding resolution is easy:
arg0 names the binding, arg1 is the index, arg2 (add/store) is the value. Emit
`atomicAdd(&kbuf_counts[idx], val)`. The kompute `g.bind(.field)` returns exactly
this pointer-to-array shape, so the production helper threads cleanly.

## RISKS / OPEN QUESTIONS
- R1 (taint completeness): if a tainted binding is ALSO read in a vec/loop
  pattern the emitter handles specially, those paths must route through
  atomicLoad too. Mitigation: the pre-pass marks the binding; a single
  choke-point in load/store emission catches all. Audit every load/store path.
- R2 (helper signature vs the link step): the exact COMPILING signature needs
  pinning — per-field helper vs one generic helper with a comptime field tag.
  The PoC used a concrete `counts` capture; the kompute version must thread the
  `g.bind(.field)` alias. Verify each shape compiles to a clean OpFunctionCall
  (the link step is fussy — test before building the transform).
- R3 (atomic reset): clearing gridCounts each frame — atomicStore in a clear
  kernel (per cell) is simplest; or memset via the host between dispatches. The
  reference uses a clear pass. Decide during Layer 3.
- R4 (Device vs Workgroup scope): irrelevant for WGSL emission (the builtin
  picks storage scope implicitly); only matters if we later emit SPIR-V.
- R5 (workgroup size): bump kompute's default 64 → 256 to match the reference;
  measure. Independent of atomics; a cheap perf lever.

## MIGRATION when Zig's SPIR-V backend lands atomics
Replace the noinline helpers' call sites with real `@atomicRmw`/`@atomicLoad`/
`@atomicStore`; ADD an `OpAtomicIAdd`/`OpAtomicLoad`/`OpAtomicStore` arm to
spv2wgsl's opcode dispatch (emit the same WGSL builtins + the same atomic-taint);
DELETE the helper-name intercept. The kernel-author API (`k.atomicAdd`) and the
emitted WGSL are unchanged, so nothing downstream churns. The atomic-taint
analysis (Layer 2.4) is REUSED verbatim — it keys off "binding targeted by an
atomic op," whether that op arrived as a helper call or a real OpAtomic*.

## ORDER OF EXECUTION (next sessions)
1. Pin the COMPILING helper signature (R2) — smallest spike: get `k.atomicAdd`
   threading a kompute `g.bind(.field)` to a clean OpFunctionCall. (verify-first)
2. spv2wgsl: atomic-taint pre-pass + the load/store choke-point routing +
   call-intercept emission + helper-fn deletion. Golden-WGSL test on the PoC.
3. Rewrite buildGrid per-particle + neighbor atomicLoad + reset; CPU-oracle test.
4. naga-tint / browser validate; wire the golden WGSL into wgpu-corpus.
5. Bump workgroup size; the phone is the fps truth (Simon).

## EXECUTION LOG

### Layer 1 DONE (t1178) — kompute atomic API + CPU oracle
`src/kompute.zig` gained `atomicAdd`/`atomicLoad`/`atomicStore` (inline wrappers
branching on `is_gpu`): GPU = `noinline` dummy-bodied `zatomicAdd`/`zatomicLoad`/
`zatomicStore` (the zsample2d trick — Zig emits a real OpFunctionCall);
CPU = genuine `@atomicRmw`/`@atomicLoad`/`@atomicStore` (native backend supports
them). Verified: a kernel using `k.atomicAdd` through the REAL kompute module
compiles to SPIR-V (12500 B) emitting `kompute_zatomicAdd__anon_NNNN(arr,idx,val)`
with arg0 → the storage binding; CPU twin unit-tested (returns prev, accumulates).

### Layer 2 DONE (t1178) — spv2wgsl intercept + atomic-taint
`src/spv2wgsl.zig`:
- `markAtomicBindings` pre-pass (after pass2, before pass3): id→def-offset map,
  scans OpFunctionCall for `zatomic*` callees (matched by name substring, read
  DIRECTLY from s.ids to avoid the lookupId `__unresolved_` placeholder trap —
  function kinds aren't registered until pass4), traces arg0 to its root
  OpVariable (`rootVariableOf`: follows AccessChain/Load/CopyObject), marks
  `s.atomic_var[root]`.
- Binding emission: tainted storage array → `array<atomic<u32>>`.
- `emitAtomicCall`: zatomicAdd→`atomicAdd(&arr[idx],val)`, zatomicLoad→
  `atomicLoad(&arr[idx])`, zatomicStore→`atomicStore(&arr[idx],val)`.
- Helper bodies skipped in pass4 (not emitted).
- emitLoad/emitStore reroute plain accesses to tainted bindings through
  atomicLoad/atomicStore (root var threaded via access-chain result `extra_a`).
VERIFIED end-to-end on the PoC: emits `array<atomic<u32>>` + `atomicAdd(&arr[..])`
+ `atomicStore(&arr[..])` (a plain `arr[i]=v` correctly rerouted), NO surviving
helper, NO __unresolved/ERROR markers. Golden test added
(`tests/fixtures/atomics/atomic_buildgrid.spv` + assertion in
spv2wgsl_corpus_test.zig, wired into diff_mod + test_mod). REGRESSION-CLEAN:
wgpu-diff 28 tests + internal corpus 34/34 (fixture auto-picked-up, translates
clean), wgpu-corpus 12/12 NO REGRESSIONS, host suite green. Also fixed a
PRE-EXISTING unrelated failure: `ui.zig` multiplyAlpha test expected truncation
(0x7F) but the impl rounds (0x80, correct for alpha) since the @intFromFloat
migration — test corrected.

### NEXT: Layer 3 — rewrite buildGrid per-particle (the perf win)
Rewrite `examples/wgpu_fluid_gpu/fluid_kernels.zig buildGrid` from per-CELL
(dispatch=grid_cells, scan all N — the ~15.5ms/substep whale) to per-PARTICLE
(dispatch=N, `k.atomicAdd(b_grid_counts, cell, 1)` slot-claim). Neighbor passes
read `k.atomicLoad(b_grid_counts, cell)`. Add a clear-counts step (atomicStore or
host memset) between frames. CPU oracle: the CPU twin (real @atomicRmw) runs the
per-particle build at full N and asserts the grid matches the single-writer
reference buckets. Then change the buildGrid dispatch in wgpu_fluid_gpu.zig from
`s.pipe.count = fk.grid_cells` to `= fk.num_particles`. Rebuild the benchmark
standalone, measure ms/substep at 6x vs the ~15.5ms baseline.

### Layer 3 DONE (t1178) — buildGrid rewritten per-particle (the perf win)
`examples/wgpu_fluid_gpu/fluid_kernels.zig`:
- `buildGrid` rewritten from per-CELL (dispatch=grid_cells, scan all N — the
  O(cells×N) whale, ~15.5ms/substep) to per-PARTICLE (dispatch=N): each particle
  computes its cell (floor(pos/h) clamped, matching the neighbour-pass lookup)
  and claims a slot via `k.atomicAdd(b_grid_counts, cell, 1)`, writing its index
  to grid_data. O(N).
- New `clearGrid` kernel (per-cell): `k.atomicStore(b_grid_counts, cell, 0)` —
  zeroes counts before each substep's buildGrid (the atomic add accumulates).
- The 3 neighbour passes (viscosity/density/force) read counts via
  `k.atomicLoad(b_grid_counts, cell)`.
- Host (`wgpu_fluid_gpu.zig`): added `clearGrid_wgsl` embed + registration;
  dispatch is now clearGrid@grid_cells then buildGrid@num_particles (was
  buildGrid@grid_cells). build.zig entries gained "clearGrid".
VERIFIED: zig build wgpu-fluid-gpu EXIT=0, lint 0; the GENERATED kernel WGSL
carries `array<atomic<u32>>` (binding 6) + 1 atomicAdd + 3 atomicLoad + 1
atomicStore, NO surviving zatomic helper, NO ERROR/unresolved markers — the exact
shape of the reference sph_fluid-3.html. CPU ORACLE (real @atomicRmw on native,
permanent test in fluid_kernels.zig): per-particle build at N=2000 → counts sum
to N, no cell overflow, every particle recorded in its own cell. Host suite green.
Standalone rebuilt (-Dmode=release, 1.84MB) with atomics embedded in the wasm,
staged as wgpu_fluid_gpu_atomics.html.
THE MEASUREMENT: on Simon's Adreno-7xx, baseline (single-writer grid) was ~15.5
ms/substep at 20k (bench 6.45x → avg 10fps). Compare ms/substep at the same 6x on
this atomics build. NEXT (Layer 5): bump workgroup 64→256 to match the reference;
remeasure.

### Layer 3 BUGFIX (t1178) — binding renamed to helper param → mis-bound buffer
DEVICE SYMPTOM (Simon, Adreno-7xx): the atomics build ran FAST (120fps at 20k,
vsync cap — the grid build got much cheaper, good) but NOTHING MOVED — all 20k
particles collapsed to a frozen blob. Diagnosis: "runs fast but computes garbage"
= a mis-bound buffer.
ROOT CAUSE: Zig emits MULTIPLE OpNames for one id. A storage-buffer extern passed
as a function argument picks up the callee's PARAMETER name as a LATER duplicate
OpName: the grid_counts binding (id 584) had OpName `kbuf_grid_counts` THEN `arr`
(the kompute atomic helper's `arr` param) ×5. spv2wgsl's OpName handler was
last-write-wins, so the binding emitted as `var<storage> arr: array<atomic<u32>>`
instead of `kbuf_grid_counts`. The host's binding parser (compute_host
parseBindings) matches `kbuf_<field>:` to assign buffers; `arr` didn't match →
grid_counts treated as an untouched field → assigned a FRESH WRONG binding number
→ the grid_counts buffer bound to the wrong slot → cross-field corruption →
NaN/collapse → frozen (the same class of failure as the original Adreno
megastruct bug, but caused by the rename, not the GPU).
FIX (one line, in spv2wgsl OpName handler): FIRST OpName wins —
`if (s.ids[target].wgsl_name.len == 0) s.ids[target].wgsl_name = name;`. The
declaration name is the first OpName; later duplicates from param aliasing are
noise. VERIFIED: fluid kernel WGSL now emits `kbuf_grid_counts: array<atomic<u32>>`
with atomicAdd/Load/Store all referencing it; no stray `arr` binding. Regression-
clean: wgpu-diff tint 168 ok + internal corpus 43/43, BUILD_EXIT=0. Standalone
rebuilt (1.84MB), binding name verified in the embedded wasm. RE-TEST ON DEVICE.

### t1178 — UX + STABILITY pass (phone)
Atomic SPH confirmed WORKING on device (Adreno-7xx, ~60fps@1x). Simon's feedback:
unstable (slows whole phone, crashes), UI too big, wants landscape-fullscreen +
a collapsable foreground panel.
STABILITY ROOT CAUSE (the crash/slowdown): the diagnostics readback ran EVERY
FRAME unconditionally — `readLatest(.pos)` + `readLatest(.density)` each copy ALL
GPU buffers to staging + submit + async-map, then the CPU scanned 20k elements
TWICE (incl. a pure-debug per-particle "oracle match" loop), all to feed stats
only visible inside the *collapsed* diagnostics panel. On top of the 16
compute-submits/frame this pinned the GPU → thermal throttle → context loss.
FIX: gate the entire readback+scan behind `s.show_diag` (panel open). Deleted the
oracle-match loops + the dead oracle-bar overlay. When the panel is closed
(default) there is now ZERO readback and ZERO extra submits.
UI: replaced the full-bleed panel with a SMALL always-visible bar (☰ toggle +
`fps / ms-sub`); the full control panel only renders when `panel_open` (default
false), so the fluid is unobstructed. Font sized to logical width (lw/18, clamped
16..34) so nothing clips. Substep stepper unchanged (−/N/+, 1..5).
LANDSCAPE-FULLSCREEN: added a `--fullscreen-landscape` flag to c2js (tools/c2js.zig)
that injects a tap-`[ ]`-to-fullscreen + `screen.orientation.lock('landscape')`
shim + a portrait "rotate your phone" hint into the HTML shell; wired ON for every
`bridgePage` standalone (all are full-canvas wgpu demos). Other (non-bridgePage)
pages are unaffected. VERIFIED: standalone builds EXIT=0, shim present in HTML,
atomic binding intact, fluid_gpu builds clean.

### t1178 — pass-restore fix (UI on top) + gravity default
Confirmed on device: drawing discs FIRST (last turn) triggered the Adreno
pass-restore bug — ALL subsequent 2D (green border, circle, the UI toggle bar)
vanished; only the HTML fullscreen button showed. The `FluidDiscs.draw`
`renderer.bindForPass` restore is insufficient on the Adreno (the old "discs must
be drawn LAST" workaround was masking exactly this).
ROOT-CAUSE FIX (not a workaround): added `pub fn reopenOverlayPass(gl)` in
wgpu_app.zig (thin public wrapper over the existing `reopen2DPass`, the same
mechanism endMode3D/endTextureMode use), exported as `z.reopenOverlayPass`. The
fluid example now: clear → draw discs (their own custom pass) → `reopenOverlayPass`
(ends that pass, reopens a fresh surface pass with colour LOADED, re-binds the 2D
renderer pipeline+bindgroups+batch) → border/circle → UI. So the custom pass is
fully isolated and the overlay/UI compose cleanly ON TOP. Verified an unrelated 3D
example (wgpu-cube3d) still builds, so the engine addition is safe.
GRAVITY/VISC DEFAULT: the gravity+mouse and viscosity KERNELS were disabled by
default (`en_gravity=false`, `en_visc=false`) — the fluid just sat there. Both now
default ON (en_gravity=true, en_visc=true); gravity_y stays 0.05.
Standalone rebuilt (1.84MB), atomic binding intact, lint 0, EXIT=0.

### t1178 — perf pass 1 + corner-explosion fix + grid debug stats
MEASURED on device: atomics gave ~11.9 ms/sub vs ~15.5 baseline (~1.3x) at 3
substeps. CONFIRMED data path is already optimal: FluidDiscs binds the compute
pos/density storage buffers DIRECTLY (zero-copy, GPU-resident end-to-end); the
only GPU→CPU readback is the diagnostics scan, gated off unless the panel is open.
The 16-submits issue is also already solved: batch_mode (default ON) runs all
kernels × all substeps in ONE encoder/compute-pass/submit per frame. So cost is
the compute math, dominated by THREE separate 3×3 neighbour searches
(viscosity/density/force), each re-reading up to 9×64 neighbours from global mem.
DONE this turn:
- Quick win: workgroup 64→256 (build.zig fluid `.workgroup={256,1,1}` +
  fluid_kernels `config.workgroup=256`). Verified `@workgroup_size(256)` in the
  generated WGSL + embedded wasm.
- Default 3 substeps (`bench_mult=3`).
- Grid debug stats (diagnostics panel, from a `grid_counts` readback — small,
  ~5KB, gated): fullest cell (`cellmax`), mean over non-empty cells (`avg`), and
  how many cells hit the `max_per_cell` cap (`cap` → neighbours dropped). Drives
  the cell-size + count tuning. TARGET particles/cell still TBD — read `cellmax`
  on device first.
- CORNER-EXPLOSION FIX (long-standing bug): root cause identified — the boundary
  handling in `applyAndFinalize` clamped x and y INDEPENDENTLY, so corner
  particles were pinned to the EXACT corner point (both axes), piling several at
  dist≈0 → the Clavet near-density term (1−r/h)³ → its max → explosive
  near-pressure. Worst in corners (two walls = double clamp), matching the
  symptom. Replaced the hard clamp with: a SOFT inward push ramping over an
  `h`-wide band near each wall (keeps density smooth near walls), plus a hard
  safety clamp with a tiny index-derived jitter (0..1.8px, sub-radius) ALONG each
  wall to break exact coincidence. CPU oracle still green; standalone EXIT=0.
DEFERRED (bigger rewrites, want measurement + oracle guarding): #2 fuse
viscosity into force (3 neighbour searches → 2); #3 workgroup-shared-memory
tiling + packed read-only {pos,vel,density} snapshot (the real prize, where the
reference's speed lives); #5 shrink max_per_cell once cellmax is known; #6 render
overdraw. (#4 skip-grid-rebuild explicitly rejected by Simon.)

### t1178 — perf pass 2: viscosity FUSED into force + readback-slice bugfix + UI half-width
- VISCOSITY FUSED into the force pass (approved #2): force now does ONE neighbour
  traversal that computes both the pressure displacement AND the viscosity
  damping (applied XSPH-style as a position delta, since applyAndFinalize recovers
  velocity from position; valid common variant, slightly more damped, viscosity
  moves from pre-predict-velocity to post-predict-position). The standalone
  viscosity kernel + its dispatch/install/embed/build-entry removed. Per-substep
  neighbour searches 3→2. The `viscosity` slider still drives `visc_beta` (now
  read inside force). CPU oracle green; viscosity entry confirmed absent from WGSL.
  Combined with workgroup 256, device showed ~9.9 ms/sub (was 11.9, was 15.5
  baseline).
- READBACK SLICE BUG (found via Simon's screenshot: diagnostics showed
  `cellmax 19999 avg 16543 cap 11007` — impossible, only ~1290 cells). Root cause:
  `compute_host.readLatest` always sliced the mirror field to `self.count` (the
  PARTICLE count, 20000), so `grid_counts` (grid_cells=1290 long) overran into the
  adjacent `grid_data` field → the "counts" were actually particle indices. FIX:
  slice to `@min(self.count, field.len)` so fixed-size fields (grid_counts,
  grid_data) use their own array length. The grid itself was always fine — only
  the debug readback was wrong.
- UI: panel is now LEFT-HALF width (`ui_w = lw*0.5`) and ~30% smaller text
  (font clamp 16..34 → 12..24, divisor /16 on the half width).
NOTE for next device run: re-read cellmax/avg/cap (should now be sane, e.g.
single/low-double digits); "frozen 100%" on a settled pool may be legit but
re-confirm. THEN size particle count + cell size for 60fps using real numbers.
STILL DEFERRED: #3 shared-memory tiling (needs a spatial sort — the big rewrite);
#5 shrink max_per_cell once real cellmax known; #6 render overdraw.

### t1178 — perf pass 3: fused integrate + grid-on-predicted-pos + sqrt early-reject
Device showed 9.4 ms/sub (15.5 baseline → 11.9 atomics → ~9.9 wg256+visc-fuse →
9.4 here). Fluid looks correct (proper sloshing surface, no corner explosion).
- FUSED integrate kernel = gravity + mouse + save-prev + advance-position in ONE
  dispatch. Possible because viscosity left the pre-predict slot (it's in force
  now), so there is no pre-predict neighbour search to sit between gravity and
  predict. Per-substep dispatches 7→6.
- REORDERED so the grid is built AFTER integrate (on PREDICTED positions): the
  neighbour search now reads the exact positions the grid was binned from — a
  fresh grid, removing the one-step staleness the old "grid built pre-predict,
  read post-predict" approximation carried. Slightly more accurate AND simpler.
- SQUARED-DISTANCE EARLY REJECT in density + force inner loops: test
  dot(sep,sep) < h² and only `@sqrt` the in-range survivors (out-of-range 3×3
  corner candidates skip the sqrt). Zero semantic change.
Per-substep sequence is now: integrate → clearGrid → buildGrid → density →
force(+viscosity) → applyAndFinalize (6 dispatches, 2 neighbour searches).
CPU oracle green; integrate confirmed in wasm; compute_host readback fix verified
not to regress wgpu-compute-smoke. (Old gravityMouse/predict/viscosity fns remain
in the file but are no longer installed/dispatched — harmless dead code.)
STILL DEFERRED: #3 shared-memory tiling (needs spatial sort — the remaining big
prize, deserves its own focused pass with the oracle); #5 max_per_cell shrink
(pending real cellmax from the now-fixed readback); #6 render overdraw.

### t1178 — GPU-compute HTML tutorial (before the barrier arc)
Wrote a from-scratch, current HTML tutorial on the zimr compute system + SPH
example, aimed at beginners, ending with the optimization story so non-experts
can understand what each optim does. Saved to src/notes/tutorials/
gpu-compute-tutorial.html (and staged to outputs). 9 sections: why GPU compute /
the CPU-GPU duality (is_gpu) / kernel-file anatomy (Buffers, Params, Ctx,
installKernel) / the 3-stage build (Zig→SPIR-V→WGSL) / spv2wgsl + the atomics
noinline-helper trick + the OpName first-wins bug / the host (run, beginBatch/
endBatch, zero-copy render, the readLatest slice bug) / the SPH fluid kernel by
kernel (grid, density, force+fused-viscosity, integrate, corner-fix) / the perf
ladder 15.5→9.4 explained / future work = shared-memory tiling explained for
beginners + the staged plan. All code shown is REAL current source. Design:
warm-paper prose surface vs dark shader-panel code blocks encoding the
CPU-host/GPU-device duality; Space Grotesk + Lora + JetBrains Mono; a small
correct JS tokenizer for Zig/WGSL highlighting; reveal-on-scroll. Self-contained
single HTML file, all tags balanced, ~54KB.
NEXT (resuming the agreed plan): Stage 1 of shared memory = add workgroupBarrier
(noinline-helper + spv2wgsl OpControlBarrier lowering) + a tiny shared-mem smoke
kernel with golden SPIR-V test + CPU oracle, BEFORE touching the fluid. Probes
already confirmed: `extern var addrspace(.shared)` DOES emit a Workgroup-class
SPIR-V var; spv2wgsl already emits `var<workgroup>` + maps local_invocation_id/
workgroup_id; std/gpu.zig exposes the builtins. Only missing piece is the barrier.

### t1178 — SHARED-MEMORY ARC, STAGE 1: barrier + shared-mem primitives DELIVERED
Goal: de-risk workgroup shared memory + barriers in the kompute→SPIR-V→WGSL
pipeline BEFORE rewriting the fluid. All sandbox-verifiable; on-device proof is
the new standalone.
PROBES (confirmed): `extern var addrspace(.shared)` / `@extern(*addrspace(.shared))`
emit a Workgroup-class SPIR-V var; an EMPTY `noinline` barrier helper's call
SURVIVES to SPIR-V (noinline blocks elision); spv2wgsl already emits
`var<workgroup>` + maps local_invocation_id/workgroup_id; std/gpu.zig exposes the
builtins. ONLY missing piece was the barrier itself.
DELIVERED:
- kompute.zig: `workgroupBarrier()` (inline, GPU→`zworkgroupBarrier` noinline
  empty helper; CPU no-op), `localId()`/`workgroupId()` (gpu builtins, GPU-only),
  and `shared(T,n,name)` — returns a `*addrspace(.shared) [n]T` on GPU (via
  `@extern` with the name) / a static-backed `*[n]T` on CPU. CRITICAL: `shared`
  must be called at MODULE level (like `g.bind`); calling it inside a fn makes
  Zig materialise the name as a runtime array spv2wgsl can't lower (saw the
  "pointer arg to by-value param" errors). Module-level → clean WGSL.
- spv2wgsl.zig: `barrier_stem="zworkgroupBarrier"` + `isBarrierHelperName`; in
  emitFunctionCall, intercept the call → emit `workgroupBarrier();` (void, no
  result); skip the helper body in emitOneFunction (alongside the atomic skip).
- examples/wgpu_shared_smoke/: `shared_rotate.zig` (kernel: left-rotate WITHIN
  each workgroup — GPU routes values through `k.shared` tile + barrier reading a
  NEIGHBOUR's slot, so it genuinely needs the barrier; CPU oracle path computes
  the same index from global ids) + `wgpu_shared_smoke.zig` host (GPU round-trip,
  compares to expected rotate, shows green PASS / red FAIL + mismatch count +
  CPU-oracle line + sawtooth bar viz). build.zig: addWgpuComputeApp("shared_smoke",
  kernel basename "shared_rotate", workgroup={256,1,1} — MUST match the rotate
  modulus wg_size=256). Kernel fn named `sharedRotate` (lint dup-pub-fn: `rotate`
  collides with zimrmath).
VERIFIED in sandbox: SPIR-V→WGSL clean (0 errors; `var<workgroup> rot_tile`,
`workgroupBarrier()`, `@workgroup_size(256)`); CPU oracle green; standalone
EXIT=0 with var<workgroup>+workgroupBarrier+rot_tile in the wasm and NO leftover
zworkgroupBarrier; spv2wgsl corpus regression (incl. atomics golden) green.
STANDALONE: /mnt/user-data/outputs/wgpu_shared_smoke.html — green PASS on device
= shared mem + barrier work on the Adreno; that's the Stage-2 green light.
NEXT (Stage 2, after device PASS): rewrite fluid density+force to one-workgroup-
per-cell + shared-memory tiling (load the 3×3 neighbourhood into a tile once,
barrier, all threads read from it), comptime-split so the CPU path stays the
global-memory oracle. Guard with the existing CPU oracle.

### t1178 — STAGE 1 device FAIL → triangulating diagnostic
Device ran wgpu_shared_smoke and reported FAIL 1023/1024 wrong (CPU oracle PASS).
1023/1024 = signature of all-zero GPU output (only gid=255, where expected==0,
accidentally matches). So shared-memory READS return 0. Cause is one of: (a)
local_invocation_id not delivered, (b) the var<workgroup> isn't actually shared
(private per-invocation), or (c) the barrier doesn't synchronise. Generated WGSL
shows the barrier nested in trivially-true `if (11u==11u)` guards (spv2wgsl's
ir_emit/relooper emits selection constructs as `if (label==const)`); those are
constant/uniform so MAY be uniform-OK, but ambiguous. Rather than guess, replaced
the smoke kernel with a 3-WAY DIAGNOSTIC (one `diag` kernel, one dispatch, three
result buffers): out_localid (= local id), out_self (= tile[lid] own slot after
barrier), out_rotate (= tile[(lid+1)%wg] neighbour after barrier). Host shows
PASS/FAIL per line. This pinpoints the failure in ONE device run:
- localid FAIL → builtin delivery problem.
- self FAIL → workgroup var fundamentally broken.
- self PASS + rotate FAIL → cross-thread visibility / barrier (likely the
  uniform-control-flow nesting → fix = flatten trivial `if (N==N)` in spv2wgsl).
Barrier kept in unconditional position (no early-return; count=1024 exact
multiple of wg_size=256). CPU oracle green; standalone EXIT=0 with var<workgroup>
+ workgroupBarrier + 3 kbuf_out_* bindings in the wasm.
STANDALONE: /mnt/user-data/outputs/wgpu_shared_smoke.html — report the 3 lines.

### t1178 — STAGE 1 PASS on device + durable barrier-uniformity guard + naga validator
DEVICE: all 3 diagnostic lines PASS (local_invocation_id, shared self-roundtrip,
shared+barrier rotate) + CPU oracle PASS. **Workgroup shared memory + barriers
WORK on the Adreno.** Stage 1 GREEN → Stage 2 (fluid tiling) is unblocked.
ROOT CAUSE of the earlier FAIL (now understood): a data-dependent early
`return` BEFORE the barrier (`if (gid>=count) return; ... workgroupBarrier();`)
put the barrier in NON-UNIFORM control flow — lanes that returned never reached
it, so on the Adreno the barrier silently didn't synchronise and shared reads
returned zero (1023/1024 wrong). The fix in the smoke kernel: no early-return;
dispatch an exact multiple of wg_size and guard per-lane WORK instead.
DURABLE PREVENTION (the ask "prevent this class of bug durably"):
- spv2wgsl `checkBarrierUniformity` pass (pure-Zig, NO naga dep — fits "don't
  depend on naga for real tests"): scans each function; if any OpReturn precedes
  a barrier-helper call, it ERRORS at transpile (exit 3, no output file, clear
  message → build gate fails). Verified: rejects the bad early-return kernel,
  accepts the good one, corpus regression clean (no false positives). Uses DIRECT
  s.ids[id].wgsl_name (fn names unresolved via lookupId before pass4 — same
  gotcha as atomics).
- kompute.zig workgroupBarrier doc now spells out the uniform-control-flow rule
  + the correct guard-the-work pattern.
- naga BUILT from the provided Rust 1.96 + wgpu source (cargo build -p naga-cli →
  tools/naga, 64MB, NOT committed to the repo zip — a sandbox/dev tool). Wired as
  tools/validate_wgsl.sh (optional dev accelerator: validates generated WGSL in
  ms, catches type/binding/undeclared errors without a device round trip).
  IMPORTANT FINDING: naga does NOT flag workgroupBarrier-in-non-uniform-control-
  flow (it validated the bad kernel as "successful") — that is exactly why the
  pure-Zig spv2wgsl guard above is the real safety net for THIS class. All 6
  fluid kernels validate clean under naga.
SMOKE STANDALONE (now the 3-way diagnostic, passing): wgpu_shared_smoke.html.
NEXT — STAGE 2: rewrite fluid density+force to shared-memory tiling (one
workgroup per cell loads the 3×3 neighbourhood into a tile, barrier, all lanes
read from it), structured so NO lane early-returns before the barrier (the guard
now enforces this). comptime-split so the CPU path stays the global-memory
oracle. Guard with the existing fluid CPU oracle.

### t1178 — STAGE 2a: shared-memory neighbour-TILING de-risk (verifiable standalone)
Before rewriting the fluid's physics, de-risked the one-workgroup-per-cell tiling
mechanism the same way Stage 1 de-risked barriers — a standalone with an EXACT
integer oracle. New example examples/wgpu_tile_smoke/{tile_gather.zig, wgpu_tile_
smoke.zig}:
- Per-CELL dispatch (count = grid_cells*wg_size → grid_cells workgroups, wg=64=
  max_per_cell). Kernels tileClearGrid (per-cell), tileBuildGrid (per-particle
  atomic slot-claim, reused fluid pattern), gatherTiled.
- gatherTiled GPU path: workgroupId()=cell, localId()=slot; cooperatively loads
  the 3×3 neighbourhood into 3 workgroup-shared arrays (tg_px/tg_py/tg_idx, cap
  9*64=576), workgroupBarrier ONCE, then each lane counts its center particle's
  neighbours within h FROM THE TILE. The barrier is UNIFORM: exactly grid_cells
  workgroups (no out-of-range wg), the load loop guards per-lane WORK (while s<cnt,
  s+=wg) NOT the barrier, no early-return before it. comptime-split: CPU path is
  the identical gather straight from global memory (the oracle).
- Verifiable quantity = integer neighbour count per particle. Cell size == h, so
  the 3×3 grid count equals a brute-force O(N²) count (the host's ground truth) —
  exact pass/fail, no float epsilon. N=1024, domain 512, h=64, ~16/cell (no cell
  overflows max_per_cell, so GPU/CPU never drop different particles).
- Naming: clearGrid/buildGrid collided cross-file with the fluid (dup-pub-fn lint),
  renamed tileClearGrid/tileBuildGrid. CPU oracle test green; standalone EXIT=0;
  wasm has var<workgroup> + workgroupBarrier + tg_ arrays; gatherTiled validates
  clean under naga; spv2wgsl checkBarrierUniformity passed it (barrier uniform).
  Embed names for multi-entry kernels are <entry>_wgsl.
STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — expect "GPU tiled
neighbour gather: PASS (1024 particles)" + CPU oracle PASS.
NEXT — STAGE 2b (after device PASS): adopt this exact cooperative-load-barrier-
tile-read shape in the fluid's density (pos-only tile) then force (pos+density+vel
tile). Per-cell dispatch via temporarily setting pipe.count=grid_cells*wg around
the run. Keep the old per-particle density/force as oracle + A/B toggle so Simon
can measure tiled-vs-untiled on device (the net win is uncertain: shared-memory
traffic ↓ ~20× but wg=64 with ~16 active lanes in processing wastes occupancy —
measure before committing). Guard with the fluid CPU oracle.

### t1178 — STAGE 2a device FAIL (1024/1024) → workgroupId() diagnostic
Device: GPU tiled gather FAIL 1024/1024 (ALL wrong), CPU oracle PASS, grid 10x10,
max/cell 26 (no overflow). KEY: the CPU oracle is comptime-split to a DIRECT
global gather — it never touches the tile load/read path, so its PASS says
nothing about the GPU tiling. ALL-wrong (no particle has 0 true neighbours) fits
out_count staying zero → processing keyed off a wrong workgroupId(). And
workgroupId() is the ONE primitive Stage 1 never exercised (it tested c.id +
local_invocation_id only). WGSL wiring LOOKS correct (var<private> workgroup_id,
@builtin(workgroup_id) in the inputs struct, assigned in the entry) and naga
validates clean — but that doesn't prove device delivery. Added an UNCONDITIONAL
diagnostic: dbg[wgid*wg_size+lid] = wgid written by every thread before any
guard; host checks dbg[t]==t/wg_size → "workgroupId(): PASS/FAIL". One run
pinpoints: wgid FAIL → builtin delivery is the bug (fix spv2wgsl/kompute); wgid
PASS + gather FAIL → the tile load/read logic. Standalone EXIT=0, CPU oracle
green. STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — report the
workgroupId() line + the gather line.

### t1178 — STAGE 2a ROOT CAUSE: workgroupId() unreliable on Adreno → derive from c.id
Diagnostic confirmed: "workgroupId(): FAIL (960/6400 threads wrong)" while c.id
(global_invocation_id) + local_invocation_id work. The WGSL wiring is correct
(@builtin(workgroup_id) declared, assigned, read) and naga validates clean, so
this is a DEVICE/driver quirk, not a transpile bug. FIX: never use workgroupId();
derive the decomposition from the proven global_invocation_id —
  cell = c.id / wg_size;  lid = c.id % wg_size;  (== workgroup_id / local id)
This is what the CPU oracle already did, so GPU/CPU now share the mapping. Changed
the gatherTiled GPU path accordingly (WGSL now has ZERO workgroup_id reads, naga
clean). Documented the gotcha on kompute.workgroupId() (⚠️ unreliable; prefer
c.id derivation). DURABLE LESSON: prefer c.id-derived workgroup/local indices for
any per-cell/tiled kernel. Standalone EXIT=0, CPU oracle green. The dbg line now
tests global_invocation_id consistency (should PASS). STANDALONE:
/mnt/user-data/outputs/wgpu_tile_smoke.html — expect workgroupId() line PASS (it
now measures c.id consistency) + GPU tiled gather PASS.

### t1178 — STAGE 2a: c.id fix had NO effect → gatherTiled writes not landing
The workgroupId→c.id fix did NOT change the device result (identical 960 + 1024/
1024). Verified deployed wasm HAS the fix (0 workgroup_id reads). So the diagnosis
was wrong. Re-read: the dbg readback was sliced to 1024 (runGather reset count to
N) AND the 960-wrong/64-right pattern over the first 1024 = the ALL-ZERO signature
again (matches only where expected==0). dbg is written UNCONDITIONALLY first thing,
so all-zero means gatherTiled's writes don't land OR c.id==0 everywhere. out_count
also all-zero (1024/1024). BOTH of gatherTiled's stores are missing → the kernel
isn't running or its writes are dropped. Ruled out a dispatch cap (buffers sized by
struct, count drives dispatch directly, config.max unused in run). New probe: dbg[
c.id]=c.id+1 (0 = thread never wrote), readback left at full 6400, host reports
correct/nonzero/max_t + sample dbg[1000],dbg[5000]. Disambiguates: nz=6400 all-ok →
c.id fine + writes land (→ bug is grid/tile/barrier); nz=0 → kernel not running
(→ suspect the 3 workgroup-shared arrays, untested vs Stage 1's single array);
nz=64/1024 → dispatch only ran one wg / capped. Standalone EXIT=0, CPU oracle green.
STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — report the c.id probe line
verbatim (the numbers).

### t1178 — STAGE 2a: c.id probe = nz=0 (NOTHING written) → isolate shared memory
Probe v2 (clear in Claude viewer): "c.id probe: 0/6400 ok, nz=0, max_t=0,
[1000]=0 [5000]=0". ZERO nonzero dbg entries — gatherTiled's unconditional
first-line write never lands → the kernel does NOT run (or all its stores are
dropped). tileClearGrid/tileBuildGrid (no shared mem) presumably run. WGSL is
well-formed: exactly 3 clean var<workgroup> decls (tg_idx/tg_px/tg_py), no
duplicates, naga validates. So Tint/Dawn rejects gatherTiled's pipeline for some
reason naga tolerates — the only GPU-specific thing it has that Stage 1 didn't =
the 3 workgroup-shared arrays + barrier. ISOLATION TEST shipped: gatherTiled GPU
path rewritten as a DIRECT global gather (shared arrays REMOVED, no barrier, same
per-cell dispatch + c.id decomposition + dbg write). Deployed wasm confirmed: no
var<workgroup>, no workgroupBarrier. Outcome decides:
  • nz=6400 + gather PASS → per-cell dispatch + c.id work; the shared memory
    (3 arrays / barrier) was the failure → redesign the tile (try ONE array, or
    investigate the multi-array pipeline rejection).
  • nz=0 still → the per-cell dispatch / c.id is the failure, not shared mem.
STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — report the c.id probe
line + gather line.

### t1178 — STAGE 2a ROOT CAUSE CONFIRMED + FIX: barrier-after-non-uniform-loop
Isolation test (direct gather, no shared mem) PASSED: "c.id probe: 6400/6400 ok,
nz=6400, [1000]=1001 [5000]=5001" + GPU gather PASS. So the per-cell dispatch +
c.id decomposition + grid build + gather logic ALL WORK. The failure was the
SHARED-MEMORY version's pipeline failing to create (nz=0 = kernel never ran).
ROOT CAUSE: the barrier sat AFTER the cooperative-load loop, and that loop had a
PER-THREAD trip count (`s = lid; while (s<cnt); s += wg_size`). Tint enforces
workgroupBarrier uniformity strictly (naga does NOT — that's why naga validated
it); a barrier after a non-uniform loop is rejected at shader-creation → pipeline
fails → kernel doesn't run. Stage 1's barrier worked because it followed STRAIGHT-
LINE code, no loop.
FIX: eliminate the loop before the barrier. wg_size == max_per_cell == 64, so each
lane loads exactly slot `lid` of each neighbour cell (one conditional load, no
inner loop), and the 9-cell walk is UNROLLED with `inline for` → fully straight-
line, no runtime loop before the barrier (like Stage 1). Verified in the
regenerated WGSL: 0 loops before the barrier, 3 var<workgroup>, and the barrier's
guard is `if (phi==const)` with phi constant in both branches = constant-true =
uniform (the proven Stage 1 shape). naga clean, CPU oracle green, standalone
EXIT=0, deployed wasm has var<workgroup> + workgroupBarrier restored.
DURABLE LESSON: never place a workgroupBarrier after a loop with a per-lane trip
count; keep the pre-barrier load straight-line (unroll fixed iteration counts).
STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — expect c.id probe
6400/6400 + GPU tiled gather PASS (this time WITH shared memory).

### t1178 — STAGE 2a: studied the working hand-written WGSL → barrier-nesting blocker + fix
Simon's hint: study sph_fluid-4.html (a WORKING reference). Finding: it's 10 clean
HAND-WRITTEN compute shaders, per-particle + global memory, NO shared mem / NO
barrier. Clean structured WGSL (for/continue/return, zero phis). Our generated
WGSL is the opposite: spv2wgsl's IR emitter reconstructs control flow as phi-label
dispatch (`if (phi==const)` guards + `loop{continuing}`) → dozens of phi vars,
deep nesting. THAT soup WORKS for global-memory kernels (the fluid runs at 9.4ms),
but it buried gatherTiled's barrier 11 ifs deep. ROOT BLOCKER (traced in the WGSL):
the barrier sat inside the cooperative-load's `if (in_bounds)` branches, and those
depend on `cell = c.id/wg_size` — which Tint treats as NON-UNIFORM (it derives from
per-thread global_invocation_id; Tint can't know integer-div-by-wgsize is workgroup-
uniform). workgroupId() WOULD be uniform but is broken on this Adreno. So the barrier
was in Tint-non-uniform control flow → pipeline rejected → nz=0.
FIX (kernel-side, no spv2wgsl change, LOW RISK): move the cooperative load into a
`noinline fn loadNeighbourTile(...)` — spv2wgsl keeps it a SEPARATE WGSL function,
so its `if (in_bounds)` branches stay inside it and do NOT enclose the barrier.
gatherTiled then issues the barrier at its TOP LEVEL after the call. VERIFIED in the
regenerated WGSL: loadNeighbourTile is a separate fn, and the barrier's only
enclosing scope is the function body — ZERO if-conditions around it (cleaner than
Stage 1). naga clean, CPU oracle green, standalone EXIT=0, wasm has var<workgroup> +
workgroupBarrier + loadNeighbourTile.
DURABLE LESSON: a workgroupBarrier must be at the kernel's top level; never let it
sit inside control flow that depends on a c.id-derived cell index (Tint = non-
uniform). Put the cooperative load in a noinline helper so its branches don't
enclose the barrier. (Deeper future option: teach spv2wgsl to flatten constant-true
`if(phi==const)` guards for cleaner WGSL overall — bigger, deferred.)
STANDALONE: /mnt/user-data/outputs/wgpu_tile_smoke.html — expect c.id probe 6400/6400
+ GPU tiled gather PASS (with shared memory, barrier top-level).

### t1178 — STAGE 2b: tiled fluid density wired with A/B toggle (+ a multi-entry gotcha)
Applied the proven tiling recipe to the fluid's density pass as an A/B alternative
to the per-particle `density` (which stays the default + the oracle):
- `densityTiled` kernel in fluid_kernels.zig: per-cell dispatch (cell=c.id/256,
  lid=c.id%256), `noinline fn loadDensityTile` cooperatively loads the 3x3
  neighbourhood (idx+px+py) into 3 var<workgroup> arrays, top-level barrier, then
  each center particle gathers the SAME double-density math from the tile.
  comptime-split: the CPU branch is the per-particle global gather (== `density`).
- fluid_wg_size=256 (== config.workgroup, no config change): lanes 0..63 load each
  cell's slot lid (max_per_cell=64), lanes 64..255 idle in the load; the proven
  slot=lid mechanism works unchanged at wg=256.
- Host A/B: `tiled_density` flag (default OFF) routes density through a per-cell
  dispatch (count = grid_cells * config.workgroup) and restores count=N for force.
  UI checkbox "tiled density (A/B)" + the ms/sub overlay now prints [TILED] vs
  [per-particle] so the comparison is on the real workload.
- CPU oracle test "densityTiled CPU oracle matches density": builds a grid, runs
  both, asserts identical b_density. GREEN.

⚠️ DURABLE GOTCHA (cost a chunk of this turn): a new kernel must be registered in
the kernel file's `comptime { k.installKernel(@This(), "name"); }` block — that
`callconv(.spirv_kernel)` install is what makes it an OpEntryPoint. WITHOUT it,
ReleaseFast strips the (unreferenced) pub fn from the SPIR-V entirely; spv2wgsl
--entry=<name> then can't find it and emits a DEGENERATE @compute stub with NO
barrier and NO var<workgroup> — the build still SUCCEEDS, so the breakage is
silent (the shader would read an empty tile → garbage). Symptom checklist: if a
tiled kernel's WGSL is missing its barrier/shared arrays, check (1) installKernel
registration, (2) the build.zig ComputeKernel `entries` list, (3) the host
`@embedFile("<name>_wgsl")` + kernel-registration list — all three are needed.
VERIFIED FIX: after adding installKernel, the rebuilt wasm has workgroupBarrier +
var<workgroup> + dtile_, the densityTiled barrier is at the function's TOP LEVEL
(zero enclosing if-conditions, same as the device-proven gatherTiled), naga clean.

OCCUPANCY CAVEAT (measure, don't assume): one-workgroup-per-cell at wg=256 with
~15 particles/cell avg means the PROCESSING phase uses ~15 of 256 lanes (the load
uses up to 64). Tiling cuts global b_pos reads ~N_cell-fold but the low occupancy
may offset that — the A/B toggle exists precisely to settle it on the Adreno.
STANDALONE: /mnt/user-data/outputs/wgpu_fluid_gpu_tiled.html — toggle "tiled
density (A/B)" and compare ms/sub between [TILED] and [per-particle]. If tiled is
a win, tile `force` next; if not, we keep per-particle and the tiling stays a
proven-but-shelved tool.

### t1178 — STAGE 2b RESULT (measured on the Adreno): tiling the density is a LOSS
Device A/B (20k particles, same scene):
  [per-particle]  35 fps   9.3 ms/sub   rho 15.2  cellmax 44 avg 27.4  frozen 0%
  [TILED]         26 fps  11.1 ms/sub   rho 17.3  cellmax 48 avg 31.2  frozen 100%
→ Tiling the density is ~19% SLOWER per substep. ROOT CAUSE = occupancy, as feared:
  one workgroup per cell at wg=256 but ~27-31 particles/cell means the GATHER phase
  uses only ~27-31 of 256 lanes (~12%); the load uses up to 64 (~25%). The ~20x cut
  in global b_pos reads does NOT beat ~8x idle lanes. Per-particle keeps ~256/256.
DECISION: keep the per-particle `density` as default (the 9.3ms baseline). Tiling
stays a PROVEN mechanism (tile smoke, device-green) that we've now MEASURED as
not-a-win for THIS pass at this wg/occupancy. The A/B toggle + densityTiled kernel
stay in (off by default) as a reference + measurement harness.
ANOMALY TO CONFIRM: the TILED run showed frozen 100% + rho 15.2→17.3 (vs frozen 0%).
Most likely the fluid was simply at rest (settled) in that screenshot — the CPU
oracle matches `density` exactly and the device tile mechanism (incl. f32 shared
arrays) is proven by the tile smoke, so densityTiled SHOULD be physically identical.
Quick check: stir the TILED fluid — if it responds normally it's just settled; if it
stays frozen under stirring there's an on-device issue (would need a probe).
LEVER IF WE WANT TILING TO WIN LATER: workgroup size. At wg=64 (==max_per_cell) the
gather occupancy ~4x's (still ~31/64) and tiling might pull ahead — but wg is module-
wide, so it changes the per-particle kernels too (risk to the baseline). Bigger
experiment; deferred. Tiling `force` is NOT worth attempting unless density tiling
first shows a win.

### t1178 — tiling shelved (correct but occupancy-bound) → OPTIMIZATION BACKLOG
Confirmed on device: stirring the TILED fluid produces a normal splash/cavity →
densityTiled is physically CORRECT (earlier frozen 100% was a settled pool, not a
bug). But tiled stays a bit slower than per-particle even with the readback
throttled. CONCLUSION: keep per-particle `density` (baseline ~9.3ms); tiling stays
in as a proven, correct, measured-not-a-win reference + the wg-occupancy lesson.

NEXT OPTIMS TO EXPLORE (ranked; PROFILE FIRST):
0. PROFILE (free, do first): use the existing en_grid/en_density/en_force/en_apply
   checkboxes — disable each, read the ms/sub drop, to find the dominant pass before
   optimizing. Hypothesis: `force` (3x3 search + fused viscosity) is the heaviest,
   then `density`. Confirm before spending effort. (GPU timestamp queries would be
   the precise version but may be unavailable/quantized on the Adreno.)
1. SPATIAL SORT by cell (counting sort + prefix-sum over grid_counts, then scatter
   ALL per-particle data into cell order). The hot loop's b_pos[j] read is currently
   a RANDOM indirection (j unsorted) → poor warp coalescing. Sorting makes consecutive
   threads process spatially-local particles → coalesced reads. Canonical GPU-SPH win,
   keeps 100% occupancy (unlike tiling), and would REVIVE tiling (a workgroup of
   contiguous particles shares neighbours). [HIGH impact, HIGH effort]
2. POS-IN-GRID (80/20 of the sort, no prefix sum): add grid_data_pos[cells*max]Vec2;
   buildGrid writes the predicted pos into the slot alongside the index. density/force
   then read grid_data_pos[cell*max+s] (contiguous per cell, fixed stride) instead of
   b_pos[grid_data[...]] (double indirection + random). Removes the random indirection
   in the hot loop; warp coalescing still imperfect (particles unsorted) but far fewer
   memory transactions. ~660KB extra. [MED impact, MED effort]
3. WORKGROUP SIZE SWEEP (256 → 128 / 64) for the per-particle kernels (NOT tiling) —
   one config line; the Adreno may prefer smaller wg for occupancy / latency hiding.
   [LOW effort, uncertain]
4. F16 positions in a search-only buffer — halve the hot-loop bandwidth (keep f32 for
   integration; downcast a parallel f16 pos buffer for distance checks). [MED effort,
   precision risk]
5. SYMMETRIC SCATTER for force (compute each pair force once, apply to both) — halves
   the force math but needs atomics on the delta buffer; atomic contention may eat the
   win on GPU. [uncertain]
RECOMMENDED ORDER: 0 (profile) → 2 (pos-in-grid, pragmatic) or 1 (sort, bigger) → 3
(wg sweep, cheap parallel test). Tile `force` only AFTER a sort lands (sort makes
tiling viable).

### t1178 — OPTIM #2 SHIPPED: pos-in-grid (A/B), the first backlog item
Implemented pos-in-grid as a clean A/B (comptime-variant cores, baseline byte-
identical — verified: density/force WGSL have ZERO grid_data_pos reads; densityPig/
forcePig read it). buildGrid now stashes the binding position in grid_data_pos[slot];
densityPig/forcePig read neighbour positions from there (contiguous per cell) instead
of b_pos[grid_data[..]] (random indirection → kills warp coalescing). density gets a
FULL coalesce (pos-only pass); forcePig coalesces 1 of its 3 neighbour reads (pos;
density+vel stay scattered). Host: `pos_in_grid` toggle (default OFF) routes density→
densityPig + force→forcePig; overlay shows [pos-in-grid]; UI checkbox added. CPU oracle
"pos-in-grid variants match originals" GREEN (bit-identical to density/force). naga
clean on both variants. ~660KB extra (grid_data_pos). STANDALONE shipped.
TO MEASURE: toggle "pos-in-grid (A/B)", compare ms/sub to [per-particle] (panel closed,
bench slider high). If it wins, make default + extend (vel-in-grid for force, or the
full sort). If flat, memory wasn't the wall / the indirection was already cached — then
the wg sweep (#3) and sort (#1) are next.

### t1178 — pos-in-grid does NOT win + exposed rest density ρ0
Device result: pos-in-grid is NOT faster. KEY INFERENCE: the random b_pos[j]
neighbour-position read was NOT the bottleneck (the Adreno's cache absorbs it, or
the wall is elsewhere). So density (the pos-only pass, fully coalesced by pos-in-grid)
is not memory-bound on positions. The likely real bottleneck is therefore (a) COMPUTE
(ALU over ~576 candidates/particle × 2 passes — only ~35% are within radius, the rest
are wasted distance checks) and/or (b) force's REMAINING scattered reads (b_density[j],
b_vel[j]) which pos-in-grid did NOT touch. Tiling AND pos-in-grid (both memory plays)
have now both failed → strong signal this fluid is more compute/latency-bound than
bandwidth-bound at 20k. pos_in_grid stays as an off-by-default A/B + the negative result.
NEXT (must profile to aim right): use the en_density/en_force toggles → record ms/sub
with each OFF to get the density-vs-force split. THEN:
- if force dominates & is read-bound → full SORT (#1) coalesces density+vel too (the
  reads pos-in-grid couldn't reach); pos-in-grid alone only got density's pos.
- if compute-bound → cut wasted work: finer rejection, fewer ALU ops/candidate, or
  fuse density+force neighbour traversal (one 3×3 walk feeding both).
Exposed ρ0 (rest/desired density) as a live slider "rest density" (0..30, default 10);
wired s.rest_density into all 3 Params sites (was hardcoded 10.0). Lets the fluid's
compressibility/equilibrium be tuned at runtime.

### t1178 — VISCOSITY RESTRUCTURE (Clavet ordering, pre-predict, stale grid, 0.75h)
Profiling result: untoggling FORCE recovers more fps than untoggling density → force
is the dominant pass. Decided to (a) restructure viscosity now, (b) do the sort next.
RESTRUCTURE (done): viscosity is no longer fused into `force`. New substep order:
  gravityMouse (vel) → viscosity → predict (pos) → clearGrid+buildGrid → density →
  force(PRESSURE-ONLY) → applyAndFinalize.
- viscosity runs BEFORE predict (Clavet paper ordering → more stable) and BEFORE the
  grid rebuild, so it reads the STALE grid still in the buffers from last frame's build.
  Grid is therefore STILL built only once per frame (the fresh one density+force use).
- viscosity radius = 0.75·cellsize (was h): smaller than the h-sized cell, so the stale
  grid's drift is less likely to push a real neighbour out of range.
- `force` is now pressure-only (fused viscosity block + my_vel removed); forcePig too.
- Split the fused `integrate` back into gravityMouse + predict (both already existed)
  with viscosity between them; `integrate` left registered but no longer dispatched.
- Host: en_viscosity checkbox ("viscosity (pre-predict)"); exposed `dt` as a slider
  (0.25..4, default 1.0) wired into all 3 zimr Params sites (hand-demo dt untouched) so
  the larger-dt-from-stability hypothesis can be tested directly.
CPU oracles still green (pos-in-grid variants match; force now pressure-only on both).
RATIONALE (Simon): costs a pass, but pre-predict viscosity + 0.75h → more stable → push
dt up → fewer substeps for the same sim time → net faster. TO VALIDATE on device: check
stability (crank dt, stir hard), confirm no blow-ups; then raise dt and see if it stays
stable where the old fused version wouldn't. NEXT: the spatial SORT (coalesce force's
density+vel reads — the heavy pass).

### t1178 — dt slider REMOVED + kernel list PRUNED (17 → 12)
- Removed the dt slider/State field; substep dt is fixed at 1.0 in all 3 zimr Params
  sites again. Rationale (Simon): a fixed substep dt makes the force/viscosity
  coefficients the only knobs, so tuning to sit just inside the stability edge is
  cleaner than juggling dt against them.
- Pruned 5 dead kernels from fluid_kernels.zig (defs + installKernel + build.zig
  entries + host embeds/list): `integrate` (the old fused gravity+mouse+predict,
  replaced this turn by gravityMouse+viscosity+predict) and the four early Adreno
  bring-up smoke kernels `fallBounce`, `fallBounceConst`, `uniformProbe`,
  `writePattern` (+ the `approx` helper only uniformProbe used). Also removed the dead
  `oracle_pos_frac`/`oracle_dens_frac` host fields (writePattern readback diagnostics,
  never read). CPU simple-mode path switched from fk.fallBounce → fk.fallBounceLean to
  match the GPU path.
- KEPT: 8 core (clearGrid, buildGrid, gravityMouse, viscosity, predict, density, force,
  applyAndFinalize) + 3 off-by-default A/B variants (densityTiled, densityPig, forcePig
  — all measured NOT a win; kept as reference, and densityTiled may be revived by the
  sort) + fallBounceLean (the "simple" UI toggle, a non-SPH sanity mode).
- wasm now @compute=13 (12 fluid + 1 engine), was 18.
OPEN QUESTION for Simon: prune the 3 experiment variants too? pos-in-grid (densityPig/
forcePig) is about to be superseded by the spatial sort; tiling (densityTiled) might be
revived by it. Leaving them in for now as documented references.

### ⭐ ROOT CAUSE of the t1178 "@compute=0" regression (RESOLVED — durable gotcha)
Adding `viscosity` pushed the fluid kernel list to 17, but `compute_host.zig`
`max_kernels` was 16. `initGpu`'s `assert(kernels.len <= max_kernels)` then became
always-false; in ReleaseSmall LLVM constant-folds the inlined 17-length, sees the assert
always traps, marks everything after it unreachable, and DCEs the entire
pipeline-building loop — the ONLY referencer of the compute `.wgsl` @embedFile consts. So
ALL compute shaders silently vanished from the wasm (render shaders survive, separate
path) while the build still SUCCEEDED (the frontend sees `kernels.len` as a runtime slice
len, so no comptime error). Fix: bumped `max_kernels` to 24. LESSON: exceeding max_kernels
is a silent shader-eraser, not a clean error — the new doc-comment on max_kernels warns
about this. Verify embeds with: newest .zig-cache/o/*/wgpu_fluid_gpu.wasm,
python3 -c "print(open(W,'rb').read().count(b'@compute'))".
