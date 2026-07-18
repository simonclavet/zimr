# finishing_webgpu.md

The near-term plan for finishing the WebGPU subsystem.  Sits *below*
`finishing_new_gpu_foundations.md` (the long-horizon plan): that one
thinks in whole feature areas; this one thinks in the next few sessions.

The original version of this file (≈1300 lines) was an investigation
log for the "mandelbrot renders blank" bug.  **That bug is solved** (the
cardioid renders in Chrome — turn 808).  The investigation log is
archived at `src/notes/archive/finishing_webgpu_pre-cardioid.md`; the
durable system map from it is preserved verbatim in §5 below.  This
rewrite (turn 813) collapses the solved hunt into §2 and makes the
forward work precise.

---

## §0.  STATUS (read this FIRST)

**The fractal renders.**  `wgpu_demo` built with `-Dwalker=ir` shows a
correct Mandelbrot (cardioid + bulbs + seahorse filaments, smooth HSV
tail, ~95fps) in Android Chrome — confirmed by screenshot, turn 808.
The original Goal #1 of this plan (find the blank-fractal bug) is DONE.

What is GREEN right now:
- IR walker is the proven WGSL path.  `wgpu-check -Dwalker=ir` passes
  the whole live corpus (0 transpile failures, smoke PASSED, NO
  REGRESSIONS).  Default `wgpu-check` (legacy) also green.
- Tests: ir_build 25/25, ir_emit 8/8, spv2wgsl 49/49.
- Project lint 0/271.
- **naga 29.0.3** is wired as a real CPU-side WGSL validator
  (`scripts/naga-validate-corpus.sh`, `tools/naga-prebuilt-linux-x86_64/
  naga`).  On the LIVE typed-harness shaders it is clean; it catches the
  exact `u32->f32` class that previously only Simon's phone caught.

What is NOT done (the forward work — see §3):
- **F4 LANDED (turn 814): the IR walker is now the DEFAULT.**  All four
  default sites flipped legacy→ir (build.zig `-Dwalker` option,
  shader_codegen.zig `wgsl_walker`, spv2wgsl.zig `walker_choice`, and the
  `convertSpirvToWgsl` convenience wrapper).  `-Dwalker=legacy` remains
  as a one-cycle escape hatch.  Fixture refreshed under ir (9 entries);
  wgpu-check + escape hatch both green.  **F5 (delete the 1434-line
  legacy walker) is the remaining walker step.**
- 2 LIVE shaders fail naga — both from the DYING flat-uniform/non-typed
  shader path (`examples/shader.zig` / `shader_chroma` family): missing
  `@location` on the FS input + a `col_diffuse` sampler address-space
  issue.  These belong to the path scheduled for migration/deletion.
- `julia` / `mandel_julia` are declared in `wgpu_demo` State but never
  initialized or drawn (only `mandelbrot` is a live consumer).  The demo
  title says "3 fractals"; today it draws 1.
- No reference-image regression test for the fractal.
- cube3d / damaged_helmet / imgui_demo not yet on the wgpu path; native
  Dawn port not started; docs drift.

Recommended order: §3.A (F4) → §3.B (naga gate in per-turn) → §3.C
(legacy-shader-path: migrate or delete) → §3.D (F5) → §3.E (julia/
mandel_julia + ref test) → §4 (broader subsystem).

---

## §1.  What works end-to-end (verified through a browser)

(Condensed from the old §1; all still true.)

1. **wgpu→browser bridge** (`src/web/zimr_wgpu.ts`): 27 `js_*` imports
   covering device/adapter/canvas, buffers + queueWriteBuffer, textures
   + samplers, bind-group layouts + bind groups, shader-module creation
   from WGSL, render-pipeline (vs+fs), render-pass + draw, surface
   present.  All exercised by `wgpu_demo`.
2. **Standalone single-file HTML** via `scripts/build_standalone_wgpu.py`
   (inlines `zig-out/wgpu/zimr_wgpu.js`, base64s `wgpu_demo.wasm`, ~2.4MB
   self-contained, runs from file:// in Chrome desktop + Android).
3. **WASI shim** in the harness — wasm instantiates without LinkError.
4. **In-page diagnostic pane** — captures console.error/warn, WebGPU
   uncapturederror, per-shader getCompilationInfo; hidden unless
   something fires.  This is the supported way to debug deployed wgpu
   shaders.
5. **Engine shapes pipeline** (`drawQuadBatched` / `drawTriangleBatched`
   via `default_shapes_{vs,fs}`) — renders correctly.
6. **The mandelbrot** (typed `loadShader` + `@embedFile`'d WGSL via the
   IR walker) — renders correctly.

---

## §2.  How the blank-fractal bug was actually solved (resolution record)

The old plan chased ~9 hypotheses (phi mismatch, type coercion, OpUndef
from spirv-opt, NaN in the FS, etc.).  The real story, established over
later sessions:

- The root cause was **not** spirv-opt OpUndefs (§9 was refuted) and not
  only the FS NaN (the `clamp01` fix in old §12.3 was real but not
  sufficient).  The decisive problem was in **how the CFG/phi engine
  lowered control flow** — the legacy recursive walker mis-handled phi
  values at construct boundaries, so loop-carried values (the iteration
  count) didn't escape correctly → uniform/blank output.

- The fix was the **structured-IR rewrite of spv2wgsl** (the "F-arc"):
  a Tint-style `ir.zig` / `ir_build.zig` / `ir_emit.zig` that
  reconstructs structured control flow and lowers OpPhi as value-
  carrying construct results.  See `src/notes/spv2wgsl_ir_rewrite.md`.

- Three bugs surfaced and were fixed only when the IR walker ran through
  the REAL shader build (not just unit tests):
  1. **Loop header-body placement** (t805): the loop header's own body
     must be emitted INSIDE the loop body (back-edge target), not before.
  2. **Phi double-emit** (t807): the IR path ran with the legacy
     `phi_assigns_ref` still set, so phi assignments were emitted twice.
     Fix: null it for the IR emit; the IR path owns phi lowering.
  3. **Phi exit-arg misrouting on one-sided ifs** (t808): a "fewer args"
     heuristic scrambled phi values across branches when a merge had
     multiple phis with a header-direct edge → `cannot assign 'u32' to
     'f32'`, blank canvas.  Fix: route header-direct values
     deterministically to the empty branch, in phi order.  PLUS a safety
     net: `tryEmitViaIr` now `ir.validate`s before emitting and falls
     back to legacy on malformed IR.

- **Lesson that shaped the tooling:** every one of those bugs passed the
  JS-shim `wgpu-check` (it has no real WGSL frontend — only checks the
  pipeline runs trap-free).  Only a real validator (Chrome, then naga)
  caught them.  Hence the naga gate (§3.B) and the
  screenshot-in-the-loop workflow (documented in `claude.md`).

---

## §3.  Forward work — finishing the WGSL/walker story

### §3.A  F4 — make the IR walker the default  [DONE turn 814]
The IR walker is proven on the corpus + in-browser.  Flipped the default:
- `src/shader_codegen.zig`: `wgsl_walker` default `"legacy"` → `"ir"`.
- `src/spv2wgsl.zig`: `walker_choice` default `.legacy` → `.ir`.
- Keep `-Dwalker=legacy` as a one-cycle escape hatch.
- Gate: full corpus `wgpu-check` (now default = ir) green ✓; escape
  hatch `-Dwalker=legacy` green ✓; fixture refreshed under ir ✓;
  standalone rebuilt from the default path (awaiting Simon's screenshot
  to confirm the cardioid still renders via the now-default ir path).
- Two harness fixes landed alongside F4: (1) `transpiler_corpus.ts` now
  scans only `.opt.spv` (the real spv2wgsl input) — pre-opt
  `.spv`/`.rewritten.spv` files made the IR walker trap in the wasm
  corpus harness (asserts that hold post-opt trip on raw SPIR-V; the
  CLI handles them fine — production never feeds pre-opt SPIR-V to
  spv2wgsl, so this is correct scoping, not a walker bug).  (2) fixture
  refreshed to record ir output as the baseline.

### §3.B  naga as a standing per-turn gate
- Fold `scripts/naga-validate-corpus.sh` into the per-turn audit (next
  to `wgpu-check`).  It must validate LIVE shaders, not stale cache (the
  script now does a clean shader rebuild first — see the t812 caveat in
  `spv2wgsl_hardening.md`).
- Better long-term: validate the build's actually-emitted `.wgsl`
  artifacts directly rather than re-translating cache `.opt.spv`, so the
  gate can't drift from what ships.
- Caveat to remember: naga is Firefox-flavored; Dawn (Chrome) is the
  real target.  They agree on the bug classes we care about (types,
  arity, undefined, control flow).  Treat a naga PASS as strong
  evidence, a naga FAIL as "investigate," and confirm genuinely
  surprising disagreements with a screenshot.

### §3.C  The legacy flat-uniform shader path (the 2 naga failures)
Two LIVE shaders fail naga, both from the non-typed path
(`examples/shader.zig` / `shader_chroma` family, flat `u_time`/
`u_offset` uniforms, multiple `@group(0) @binding(0)`):
- missing `@location(N)` on the FS input struct member;
- `col_diffuse` sampler global with an address space incompatible with
  `Handle`.
Decision: this path is being migrated to the typed `_io` harness (which
demonstrably emits correct `@location`/bindings — the cardioid proves
it).  Per fix-on-notice, **migrate these shaders to the harness OR fold
them into the GLSL-path deletion** — do not band-aid the flat-uniform
emitter.  Pick one and do it so the live corpus goes naga-clean.

### §3.D  F5 — delete the legacy walker
After F4 has baked one cycle and the corpus is naga-clean under ir:
- Delete `src/spv2wgsl/walker.zig` (1434 lines) and the now-dead support
  it was the only user of: `phi_assigns_ref`, `StopSet`,
  `route_phi_inline`, `isTrivialPassthroughBlock`.
- Remove the `WalkerChoice` enum + the `-Dwalker` option + the
  legacy-fallback branch in `tryEmitViaIr` (the IR path stands alone;
  unsupported shapes become hard errors surfaced by the naga gate, or
  add IR support for them).  NOTE: the deferred shapes that currently
  fall back to legacy (single-block loops, header-conditional loops,
  unstructured switch — see `ir_build.zig`) must FIRST either be handled
  in the IR builder or confirmed absent from the corpus, else F5
  regresses them.  Audit before deleting.
- Also delete the dying GLSL emitter `tools/zglsl.zig` (already on the
  linter's `deletion_skip`).

### §3.E  Finish the fractal demo + lock it
- Wire `julia` and `mandel_julia` in `wgpu_demo` (declared in State,
  never initialized/drawn).  Make "3 fractals" true.
- Add a **reference-image regression test**: capture the correct
  mandelbrot canvas (zoom 1.2, center (-0.5,0), max_iter 512) as a PPM;
  a headless test diffs the wgpu_demo canvas against it so any future
  walker change that breaks the image is loud.  (Open question: the
  smoke harness is a JS shim with no real GPU, so a true pixel test
  needs either a real GPU in CI or a CPU reference render via the rlsw
  path — decide which.)

---

## §4.  Broader WebGPU subsystem (after the walker story is closed)

(From the old §6; still the right list, reprioritized.)

1. **More examples on the wgpu path**, in difficulty order:
   - cube3d (3D transforms, depth test, instancing) — already on GL.
   - imgui_demo (dynamic vertex buffers, per-frame atlas) — in tier-A.
   - damaged_helmet (GLTF + PBR) — most demanding.
   - a compute demo (the bridge has compute-pass imports; nothing uses
     them — a simple GPU particle sim).
2. **The missing blue quad** — the first quad in a fresh shapes batch
   doesn't render when later primitives in the same batch do.  Likely an
   engine vertex-buffer-offset / first-draw-state bug, not spv2wgsl.
3. **Standalone refinements** — generic `--example NAME` bundler (read
   `zig-out/wgpu/{NAME}.wasm`); ReleaseSmall to get the bundle <1MB;
   slow-mo/frame-step/pause debug toggles persisted via URL fragment.
4. **Bridge optimization** — ~26 bridge calls/frame, mostly
   setBindGroup + setVertexBuffer; collapse via a bound-state cache.
5. **WASI shim audit** — trace which `wasi_snapshot_preview1` imports are
   actually called; drop unused; add per-import counters in dev mode.
6. **Documentation** — `CHEATSHEET.md` canonical wgpu_demo recipe + "how
   to make a new wgpu example"; getting-started standalone flow; mark
   Turn 3.9 done in `finishing_new_gpu_foundations.md`.
7. **Native (Dawn) port** — future direction; see old §5.8 (preserved in
   the archived plan) for the sketch.

---

## §5.  System map (preserved verbatim from the original plan)

<!-- The pipeline + runtime architecture below is current and durable.
     ONE update vs the original: the SPIR-V→WGSL step is now the
     STRUCTURED-IR walker (ir_build/ir_emit), with the recursive walker
     as the soon-to-be-deleted fallback (§3.D), not the primary. -->
### §5.1  Shader compilation pipeline (build time)

```
.zig source (e.g. examples/mandelbrot_fs.zig)
    │
    │  zig build (cross-compile to spirv-* target via Zig's SPIR-V backend)
    │  Target: spirv64-vulkan-shadermodel65
    │  CallConv: .spirv_fragment / .spirv_vertex
    ▼
.spv (SPIR-V binary; SPIR-V 1.5+, mostly Logical addressing model)
    │
    │  tools/zspv (pure Zig; rewrites combined-sampler bindings to
    │             separate texture+sampler bindings per WGSL ABI)
    ▼
.rewritten.spv
    │
    │  spirv-opt (prebuilt third-party binary at
    │             tools/spirv-prebuilt-linux-x86_64/spirv-opt; -O)
    │  (the OpUndef-in-OpPhi suspicion here was REFUTED; the real
    ▼
.opt.spv  (optimized SPIR-V)
    │
    │  spv2wgsl (src/spv2wgsl.zig + src/spv2wgsl/*; pure Zig;
    │            structured-IR walker: ir_build.zig reconstructs the
    │  CFG, ir_emit.zig lowers it; recursive walker is the legacy
    │  fallback scheduled for deletion — see §3.D)
    ▼
.wgsl  ← @embedFile'd into wasm at build time
```

**Critical invariant:** the wasm itself contains zero transpilation
code.  Every WGSL byte is baked in at build time.  The runtime cost
of "shader compilation" in the browser is just
`device.createShaderModule({code: <embedded string>})`.

#### Build-step granularity

In `build.zig`, each `.zig` shader file produces 4-5 intermediate
artifacts (depending on cache state).  The build graph nodes are:
- `zig <target=spirv> <file.zig>` → `.spv`
- `tools/zig-out/bin/zspv <input.spv>` → `.rewritten.spv`
- `tools/spirv-prebuilt-linux-x86_64/spirv-opt <input>` → `.opt.spv`
- `tools/zig-out/bin/spirv-val <input.spv>` (sanity check; fails build
  if SPIR-V invalid)
- `<spv2wgsl-host-binary> <input.opt.spv>` → `.wgsl`
- `@embedFile` consumes the `.wgsl` into the example's wasm.

All cached in `.zig-cache/o/<hash>/`.  Rebuilds skip steps whose
inputs haven't changed.  Typical first build of `zig build wgpu-demo`:
30-60 seconds.  Incremental rebuild after a shader source change:
2-5 seconds.

### §5.2  Engine runtime architecture (post-Turn 3.8 baseline)

```
wgpu_demo.zig (or any example)
    │
    │  Per-frame:
    │  1. ps = Backend.beginPass(f, .{...})              [start render pass]
    │  2. s.shapes_shader.bindForDraw(&ps)               [shapes pipeline + UBO]
    │  3. Backend.drawQuadBatched(&ps, .{pos, uv, color}) [batch primitives]
    │  4. Backend.drawTriangleBatched(&ps, .{...})       [more batched primitives]
    │  5. Backend.flushBatch(&ps)                        [submit batch as 1 draw call]
    │  6. s.mandelbrot_shader.bindForDraw(&ps)           [switch to mandelbrot pipeline]
    │  7. s.mandelbrot_shader.pushUbo(queue, .{...})     [UBO update]
    │  8. Backend.drawTriangleBatched(&ps, .{...})       [fullscreen triangle]
    │  9. Backend.flushBatch(&ps)
    │  10. Backend.endRenderPass(&ps)
    │  11. Backend.endFrame(f)                           [surface present]
    ▼
src/gpu_iface.zig (WgpuBackend implements the `Backend` trait;
                   ~600 LOC of the 12-method trait)
    │
    ▼
src/wgpu.zig (mid-level wrapper; handle types + thin call site
              normalization; ~700 LOC)
    │
    ▼
wasm extern "wgpu" js_* function imports (27 functions; declared in
                                          src/gpu/wgpu_externs.zig
                                          and similar)
    │
    ▼  (bridge wraps WebAssembly into TS)
    ▼
src/web/zimr_wgpu.ts (the JS bridge: 27 js_* functions over the
                      WebGPU navigator.gpu API; ~880 LOC including
                      handle-table + state-management infrastructure)
    │
    ▼
WebGPU API (navigator.gpu) → Dawn (Chromium) → GPU
```

Key abstractions:
- **`RenderPipeline(VsT, FsT)`** is the only pipeline type. Both SW
  dispatch and GPU draw go through the same shape.  `setPipeline` is
  comptime-asserted to require `Vs` and `Fs` decls; raw handles
  rejected with `@compileError`.
- **`PassState`** is a value, not a pointer.  Mach-flavored
  explicitness — the user threads it; the framework doesn't stash
  it.  Holds the current pipeline, the current bind groups, and the
  active batch.
- **`ShapesBatch`** is owned by the `PassState`'s linked `Renderer2D`.
  Batches up screen-space primitives into one big indexed draw call.
- **`LoadedShader(Schema)`** wraps a typed (VS, FS) pipeline + its
  UBO buffer + its bind group.  Created once at startup;
  `pushUbo(queue, value)` updates the UBO; `bindForDraw(ps)` switches
  the GPU into this pipeline.

### §5.3  Standalone build process — detailed

The standalone HTML is a self-contained file that opens directly from
disk (no server needed; Chrome treats file:// URLs as secure contexts
for WebGPU).  Build flow:

```
$ zig build wgpu-demo
  produces:
    zig-out/wgpu/index.html       (multi-file harness; loads via fetch)
    zig-out/wgpu/zimr_wgpu.js     (ES module bridge; ~21 KB)
    zig-out/wgpu/zimr_wgpu.js.map (source map; not needed for runtime)
    zig-out/wgpu/wgpu_demo.wasm   (the demo binary; ~1.8 MB)
    zig-out/wgpu/spv2wgsl.wasm    (built but NOT loaded — kept for
                                   future feature where the demo
                                   transpiles a user-uploaded SPIR-V
                                   at runtime)

$ python3 scripts/build_standalone_wgpu.py [--title "..."] [--output PATH]
  produces:
    prebuilt/standalone/wgpu_demo.html (~2.4 MB single file)
```

The bundler script does:

1. **Read + transform `zimr_wgpu.js`.**  The bundled ES module ends
   with `export { setupWgpuBridge, setMemory };`.  The bundler strips
   that line via regex and the trailing source-map comment, then
   wraps the rest in an IIFE that publishes the named exports on
   `globalThis.__zimr_wgpu`.  This lets the inline `<script>` tag use
   them without an `import` (which file:// URLs can't satisfy for
   modules).

2. **Base64-encode `wgpu_demo.wasm`.**  Embedded as a string constant
   in the HTML.  At load time, the harness decodes it to a `Uint8Array`,
   wraps as a `Blob` of type `application/wasm`, gets an object URL,
   and feeds that to `WebAssembly.instantiateStreaming`.  This works
   even from `file://` where direct fetch of sibling files would fail.

3. **Inject WASI shim.**  Every WASI import the wasm declares
   (currently 27 of them under `wasi_snapshot_preview1`) gets a stub
   returning either `ESUCCESS` (0) or `EBADF` (8).  The demo doesn't
   use stdout, the filesystem, the clock, args, or environ — so all
   stubs are no-op-ish.  Three are real:
   - `random_get` → fills the buffer via `crypto.getRandomValues`
   - `clock_time_get` → returns ESUCCESS (clock skew acceptable for demos)
   - `proc_exit` → throws (catchable by the harness's try/catch)

4. **Set up the harness HTML.**  Includes:
   - Canvas element at 800×600.
   - Status text below the canvas.
   - Hidden `<div id="debug">` that becomes visible on first error/warn.
   - The IIFE-wrapped bridge JS in a regular `<script>` tag.
   - The bootstrap module in a `<script type="module">` tag.

5. **Wire up diagnostic capture.**  The bootstrap script monkey-patches
   `console.error` and `console.warn` to ALSO append to the debug
   pane.  WebGPU's `uncapturederror` events flow through `console.error`
   (because the bridge re-broadcasts them).  Per-shader
   `getCompilationInfo()` results flow through `console.error` /
   `console.warn` too.

#### Why standalone matters

- **Mobile testing.**  No dev tools on Android Chrome; the in-page
  debug pane is the only way to see what failed.
- **Sharing.**  One HTML file is trivially shareable — email,
  Discord, GitHub releases.  No "run a local server first".
- **CI / regression.**  Future plan: a headless Chrome smoke test
  that opens the standalone HTML and screenshot-diffs the canvas
  against a reference PNG.
- **Distribution-friendly.**  No need to host a static site or
  configure CORS.

### §5.4  WGSL diagnostic flow

Added 2026-05-30 to `src/web/zimr_wgpu.ts`:

1. **`device.pushErrorScope("validation")` at device creation.**  This
   activates a stack-pushed scope that captures any validation error
   during device-internal calls (pipeline creation, bind-group
   creation, etc.) — even if the caller doesn't read the error.
2. **`device.addEventListener("uncapturederror", ...)`.**  Any
   validation error that escapes all scopes fires here.  Forwarded
   to `console.error` so the harness's debug pane captures it.
3. **`module.getCompilationInfo()` async after every shader-module
   create.**  Logs WGSL error/warning messages with file:line:col.
   Without this, you'd need to dig through dev tools to see the
   actual WGSL error (which is HUGE in WGSL — Tint's error messages
   are usually a paragraph and identify the precise line).
4. **Globals: `globalThis.__zimrDevice`** (the device handle).  The
   harness inspects this to install its own listeners.

All three feed `console.error` / `console.warn`, which the standalone
harness pipes into the `<div id="debug">` pane.

### §5.5  Tests + corpus

The spv2wgsl translator is tested at four levels:

1. **Unit tests** in `src/spv2wgsl/walker.zig` (24 tests) and
   `src/spv2wgsl/block_table.zig` (8 tests).  Synthetic SPIR-V inputs
   constructed in-line; `stubEmitBody` callback produces predictable
   output for assertion.  Run via `zig test src/spv2wgsl/walker.zig`.

2. **Internal corpus** — every shader in the zimr codebase
   (default_shapes_vs/fs, mandelbrot_fs, julia_fs, cube_split_vs/fs,
   etc.).  After every build, all `.opt.spv` files in the cache get
   transpiled to WGSL.  The `wgsl_check` lexical scanner looks for
   known-bad patterns (`phi_overwrite_after_if`, double-stores in
   merge blocks, dangling phi references).  Baseline pinned in
   `src/tests/spv2wgsl_corpus_test.zig`.  Currently: 51/53 ok,
   0 known-bug, 2 err-marker.

3. **Tint external corpus** — Tint's own test fixtures, 181 SPIR-V
   files at `tests/fixtures/external/tint/`.  These are the
   real-world stress test.  Currently: 179/181 ok, 2 known-bug
   (both multi-predecessor phi patterns that Zig+spirv-opt doesn't
   emit so we can ignore).  Run via `zig build wgpu-diff`.

4. **Smoke driver** — `zig build wgpu-smoke` runs the
   `wgpu_smoke_test.zig` driver against an in-tree `SwBackend` that
   implements the same `Backend` trait but draws into a CPU
   framebuffer.  60 frames at ~26 bridge calls/frame.  Doesn't
   exercise the real WebGPU pipeline (no shader compilation), but
   it does catch breaks in the bridge call sequence.

**Gap exposed by this session:** the corpus tests are lexical
scans, NOT semantic-execution tests.  WGSL that LOOKS clean can
still compute wrong values.  See §6.1 for the fix.

### §5.6  Examples that exercise the WebGPU path

Currently driving the wgpu pipeline:

- **`examples/wgpu_demo/wgpu_demo.zig`** — the canonical demo.  Three
  engine shapes (blue/green quads + magenta triangle) drawn through
  the shapes pipeline + a mandelbrot fullscreen triangle drawn
  through the mandelbrot pipeline.  Both in the same render pass.
  This is what the standalone bundler targets.  Currently:
  engine shapes work; mandelbrot shows blank (the bug we're chasing).

- **`examples/mandelbrot_fs.zig`** — the canonical fractal FS.
  Pure-logic kernel via `shaderMain(io_in: Io) Out`.  Runs on all
  three backends (GPU/SPIR-V via spv2wgsl, GPU/GLSL via spirv-cross,
  CPU via `rlsw_shader.dispatchFragmentShader`).

- **`examples/wgpu_trivial_vs.zig`** — pass-through VS that the
  mandelbrot pipeline uses (vertices already in clip space; just
  forward them with w=1 and pass UV through).  Has its own
  `wgpu_trivial_vs_io.zig` schema (no UBO, no samplers).

- **`examples/comptime_mandelbrot.zig`** — same shader compiled at
  *comptime* into a baked PPM image embedded in the binary.  Proof
  of "one Zig source, four execution environments" (GPU/SPIR-V,
  GPU/GLSL, native CPU, compile-time).

To be added (Turn 4 of the upstream foundations plan):

- **wgpu vs sw split-screen mandelbrot** — same shader source running
  on both backends simultaneously, with diff overlay.  Blocked on
  this plan's bug fix.  Will live in `examples/wgpu_demo_split.zig`.

Future wgpu examples (Turn 5+):

- **`examples/cube3d.zig`** — already runs on GL; port to wgpu.
  Exercises 3D transformations, depth testing, instanced draws.
- **`examples/damaged_helmet.zig`** — GLTF model with PBR materials.
  Most demanding WebGPU example to date.  Exercises multi-texture
  binding, custom uniform layouts, mip-mapped sampling.
- **`examples/imgui_demo.zig`** — dynamic per-frame vertex buffer
  upload + texture-atlas updates.  Big stress test for the bridge's
  buffer-update path.
- **Compute-shader demos** — particle sim, audio FX.  Bridge already
  has compute-pass imports declared.

### §5.7  Browser smoke testing

Before this session, "in-browser correctness" was untested.  The
only browser-execution path was running `zig build serve` to launch
a local bun server, then manually opening localhost.  No automated
checks.

The standalone HTML is the first piece of infrastructure that can
become an actual smoke test.  Roadmap (§6.1):

1. Headless Chrome (via Puppeteer or similar) opens the standalone.
2. After 60 frames, screenshot the canvas.
3. PNG-diff against a checked-in reference image with tolerance.
4. Run as part of `zig build wgpu-diff`.

This is the only way to make sure future spv2wgsl changes don't
silently break shaders that compile cleanly but produce wrong pixels
(exactly the issue we're hitting now).

### §5.8  Native (Dawn) port — future direction

The browser-only target is the immediate priority.  The native target
(linking against Dawn's libwebgpu_dawn.{dylib,so,dll}) is a secondary
target with the following design constraints:

- **Same Zig source.** `gpu_iface.zig`'s `WgpuBackend` trait should
  apply unchanged — Dawn implements the same WebGPU C-ABI surface
  (webgpu.h) that the browser exposes via JS, just bound to a
  different transport.
- **Different wgpu transport.**  Instead of `js_*` imports going
  through WebAssembly→JS, link against Dawn's C functions directly
  via Zig's `extern "c"` bindings.  A `src/web/zimr_wgpu_native.zig`
  parallel to the TypeScript bridge.
- **No emscripten.**  We stay pure Zig.  Dawn is statically linked
  via `build.zig`'s `linkLibCpp + addLibraryPath + addObjectFile`.
  No JS runtime, no v8, no chromium.
- **Dawn source as reference only.**  `/tmp/dawn-study/` contains
  Dawn's `parser.cc` (the SPIR-V→Tint reader) as inspiration for the
  walker design.  No source from Dawn ships in zimr.  Dawn's compiled
  .so/.dll is a runtime dependency only.

Likely Dawn port phases (rough sketch; lives in detail in
`finishing_new_gpu_foundations.md` Turn 13+):

- **D-0: Vendor Dawn's headers.**  Pull `webgpu.h`, `dawn_native.h`,
  and `dawn_proc.h` into `vendor/dawn/include/`.  Don't vendor
  binaries — let users build or download Dawn separately
  (`tools/build-dawn.sh` script).  ~3 days.
- **D-1: Native bridge.**  Write `src/wgpu_native.zig` exposing the
  same surface as `src/wgpu.zig` (which today forwards to
  `js_*` imports).  Native version forwards to `wgpu*` C calls.
  ~1 week.
- **D-2: First native example.**  Link `examples/wgpu_demo.zig`
  against Dawn; run as a native binary.  Reuse 100% of the
  application code; only the bridge layer changes.  ~3 days.
- **D-3: Multi-platform.**  macOS / Linux / Windows.  Each adds
  platform-specific Dawn build steps + headers for native windowing.
  ~1 week per OS.
- **D-4: Shared smoke tests.**  The standalone HTML's screenshot
  diff test runs on browser; a parallel native test renders to a
  PNG via a Dawn off-screen surface.  Diff against the same
  reference image — if both backends agree, we have parity.
  ~3 days.

Out of scope for this plan.  Tracked separately under "Native (Dawn)
bring-up" in the foundations plan.

### §5.9  System invariants (must hold across all changes)

1. **Pure Zig destination.**  No npm, no Bun runtime, no emscripten.
   Bun is fine for build-time tooling (esbuild bundles the
   `zimr_wgpu.ts` to `zimr_wgpu.js`); it doesn't ship into the wasm
   binary or the standalone HTML.
2. **Static everything.**  No dynamic shader compilation in the
   shipped wasm.  No runtime spv2wgsl invocation.  All WGSL is
   `@embedFile`'d at build time.
3. **One trait, both backends.**  `Backend` trait in `gpu_iface.zig`
   has exactly one implementation set per target: `WgpuBackend` for
   browser/native-wgpu, `SwBackend` for CPU smoke testing.  No
   per-example traits.
4. **`PassState` is plumbed explicitly.**  No global state for the
   current render pass.  The user calls
   `Backend.beginPass → drawX → flushBatch → endRenderPass`; the
   framework never stashes a PassState reference.
5. **Bind groups are typed.**  `Resources(Schema)` (Turn 1) turns
   the schema's marker decorations into a comptime-generated
   bind-group layout.  Mismatches between shader binding usage and
   declared groups become Zig compile errors, not runtime
   WebGPU validation errors.
6. **Shaders are compiled per-pipeline at build time, not per-target.**
   The same `.opt.spv` produces both the WGSL (via spv2wgsl) and
   the GLSL (via spirv-cross) — one source, multiple outputs.
   Determinism: same SPIR-V, same WGSL, byte-identical between
   builds.

---

