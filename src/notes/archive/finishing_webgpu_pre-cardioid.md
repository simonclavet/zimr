# finishing_webgpu.md

A focused, near-term plan for **getting the WebGPU mandelbrot pixel-perfect
in a real browser** and finishing the WebGPU subsystem around it.  Written
2026-05-30 after the Turn 3.9 spv2wgsl rewrite arc completed its 9 phases
but the in-browser fractal still doesn't render correctly.

This plan sits *below* `finishing_new_gpu_foundations.md` (the 20-turn
long-horizon plan) — that plan thinks in turns and entire feature areas;
this plan thinks in bug investigation and the next 1-3 sessions.

Goal of this plan:
1. Find and fix the remaining WGSL-correctness bug that makes the
   mandelbrot render as a blank canvas (with engine shapes overlaid)
   even though every shader compiles cleanly and the UBO + bind groups
   are wired correctly.
2. Once the fractal renders correctly, finish the WebGPU subsystem so
   it's a credible production target: documented examples, standalone
   bundler, error reporting, and a clear story for native (Dawn) builds.

---

## §1.  Status as of 2026-05-30

### What works (verified end-to-end through a browser)

1. **The wgpu→browser bridge** (`src/web/zimr_wgpu.ts`, 880 LOC). 27
   `js_*` import functions cover the WebGPU API.  Validated:
   - Device acquisition, adapter, canvas configuration ✅
   - Buffer creation + `queueWriteBuffer` ✅
   - Texture creation + sampler creation ✅
   - Bind group layout + bind group creation ✅
   - Shader-module creation from WGSL strings ✅
   - Render-pipeline creation with vertex + fragment stages ✅
   - Render-pass encoding + draw calls ✅
   - Surface present (canvas blit) ✅

2. **Standalone single-file HTML bundle** via
   `scripts/build_standalone_wgpu.py`.  Inlines `zig-out/wgpu/zimr_wgpu.js`,
   base64-encodes `wgpu_demo.wasm`, emits a ~2.4 MB self-contained HTML.
   Verified to run end-to-end in Chrome (Android + desktop).

3. **WASI shim** in the standalone harness.  All 27 WASI imports the
   wasm declares are stubbed.  Wasm instantiates without `LinkError`.

4. **In-page diagnostic pane** (added 2026-05-30).  Captures all
   `console.error`, `console.warn`, WebGPU `uncapturederror`, and
   per-shader `getCompilationInfo` messages.  Hidden unless something
   fires — surfaces failures without dev tools.

5. **Engine pipeline (shapes batch)** end-to-end:
   - `Backend.drawQuadBatched` + `Backend.drawTriangleBatched` for
     screen-space primitives that go through `default_shapes_vs.zig`
     and `default_shapes_fs.zig`.
   - Verified by `wgpu_demo.zig`: green quad top-right + magenta
     triangle center-bottom both render correctly.

6. **`spv2wgsl` recursive walker** (`src/spv2wgsl.zig` + `src/spv2wgsl/*`).
   2079 LOC.  Drives all WGSL emission.  Handles:
   - Plain blocks, selections, loops, switches (all structured CFG).
   - Pre-terminator phi assignments.
   - One-sided-if phi routing (the original mandelbrot phi-overwrite bug).
   - Unstructured `BranchConditional` in plain blocks (the loop-
     iteration-check pattern: `if (cond) { continue } else { break }`).
   - Entry-function output-store wrapping (`outputs.<name> = ...`).
   - Entry-function `return outputs;` vs `return;`.
   - OpUnreachable (opcode 255).

7. **Lexical bug scanner** (`src/spv2wgsl/wgsl_check.zig`).  Catches
   `phi_overwrite_after_if`, double-stores in merge blocks, dangling
   phi references.  Pinned baselines in
   `src/tests/spv2wgsl_corpus_test.zig`.  Current baselines:
   - Tint external corpus: 179/181 ok, 2 known-bug (multi-predecessor
     phi — out of Zig+spirv-opt domain).
   - Internal corpus: 51/53 ok, 0 known-bug, 2 err-marker (pre-existing
     combined-sampler limitations).

### What partly works

8. **Mandelbrot fragment shader pipeline.** The pipeline compiles and
   binds.  The FS executes.  The UBO is correctly delivered.  Verified
   2026-05-30 by replacing the fractal computation with
   `out.out_color = vec4(zoom * 0.5, max_iter / 1024, 0.5, 1.0)` —
   the canvas filled with the expected dusty-pink color, proving every
   layer works EXCEPT the fractal math itself.

### What's broken (the bug we're chasing)

9. **The mandelbrot WGSL produces visible-but-wrong output.**  When the
   real Zig fractal computation runs (loop + nested if + phi), every
   pixel produces something the GPU accepts as a valid color value but
   the canvas appears dark/empty with only a tiny diagonal pattern of
   pixels in one corner.  No WGSL compile errors.  No WebGPU validation
   errors.  Just wrong pixels.

   This is **a translation correctness issue in spv2wgsl**, not a
   plumbing issue.  The WGSL the walker emits compiles and runs but
   doesn't compute the fractal correctly.

### What's broken (smaller, possibly related)

10. **The first engine quad doesn't render** in the wgpu_demo.  The blue
    top-left quad is missing; only diagonal pixel dashes appear where it
    should be.  The green top-right quad (drawn second in the same batch)
    renders correctly.  Hypothesis: first-batch upload edge case (vertex
    or index buffer offset bug, batch state not initialized) — unrelated
    to spv2wgsl.  Lower priority than the mandelbrot bug.

---

## §2.  The bug we're chasing — what's been ruled out

### Ruled out via the dusty-pink diagnostic (2026-05-30)

- ❌ Pipeline not bound when the mandelbrot triangle draws.
- ❌ Trivial VS producing wrong clip-space coordinates (the triangle
     would cover the whole canvas; the dusty-pink fill confirmed it does).
- ❌ FS not executing.
- ❌ UBO bytes not arriving at the GPU.
- ❌ UBO byte layout mismatch between Zig `extern struct` and WGSL
     `struct S123`.
- ❌ Color output channels not writing to the framebuffer attachment.
- ❌ Texture / sampler binding interfering (mandelbrot FS doesn't use
     either; the dusty-pink test proved a UBO-only FS works).

### Ruled out by inspection of the generated WGSL

- ❌ `// (walker: ...)` placeholder comments in the output (count = 0).
- ❌ Bare `return;` in an entry function (would be a WGSL type error;
     Tint would refuse to compile and the page would log it).
- ❌ Missing `outputs.` prefix on output-store assignments.
- ❌ Phi-overwrite-after-if (the original bug — verified gone by the
     `wgsl_check` scanner; manual inspection confirms).
- ❌ Loop without exit condition (the §2.6 unstructured `BranchConditional`
     fix generates a clean `if { continue } else { break }`).

### Ruled out by Tint accepting the WGSL

The mandelbrot WGSL file (6 KB) is well-formed enough that:
- Tint's WGSL frontend parses it.
- Tint's pipeline-creation accepts the bind-group layout.
- Tint's semantic analysis passes.
- The fragment shader actually runs on every pixel of the canvas.

So the bug is **semantic**: the WGSL says something the WGSL compiler
considers legal, but the result the GPU computes isn't the result the
Zig source asked for.

---

## §3.  Hypotheses to investigate, in priority order

> **STATUS UPDATE (2026-05-30, session cont.):** §9 (spirv-opt
> injects OpUndef) is **REFUTED** — see the new §11 for the
> empirical disproof and the redirected investigation.  Measured
> OpUndef counts: pre-opt mandelbrot = 12, post-opt = 1.  spirv-opt
> *reduces* undefs, it does not create them.  The single surviving
> post-opt undef (`undef_1961`) lands in an **unreachable** branch
> (`phi1208 != 145u`), so it is harmless; the real "didn't escape"
> black is correctly emitted via `phi2198 = vec4(0,0,0,1)`.  The
> post-opt mandelbrot WGSL traces as logically correct.  The bug is
> therefore NOT in the mandelbrot FS translation — read §11 for the
> new top hypothesis (shared "diagonal dashes" signature with §10:
> a vertex/index batch-upload bug, not spv2wgsl).  H1–H7 and the
> "disable spirv-opt" thread are closed.

### H1.  Phi-variable type/initialization mismatch (high priority)

The walker hoists OpPhi values to function-scope `var phi_NNN: T;`
declarations.  WGSL `var` without an initializer is zero-init for
scalars and vectors, but **WGSL does not guarantee NaN-free
initialization for all types**.  If a phi gets used before any
predecessor's assignment fires (e.g. the entry-block reads a phi
that's only assigned on the loop-back path), the value is undefined.

Investigation:
- Examine the mandelbrot WGSL for phi reads that aren't dominated by
  a phi write.
- Match each `var phi_NNN: T;` against the predecessor-assignment map
  the walker computed.  Any phi with predecessor count < block in-degree
  is suspect.
- Manually translate the SPIR-V to WGSL by hand for the first 20 lines
  of the loop body, compare against what the walker emitted.

Fix strategy if confirmed:
- Initialize each phi to a default of its type (zero for scalars,
  `vec2<f32>(0,0)` for vec2, etc.) — match what `OpVariable` does in
  the SPIR-V Function storage class.
- Track phi-write coverage per block and only declare/initialize the
  ones actually needed.

### H2.  Type coercion in WGSL where SPIR-V was untyped (high priority)

SPIR-V is sloppy about types: `OpFMul` doesn't care about argument
types, and `OpCompositeConstruct` accepts any operand types matching
the result type's element type.  WGSL is strict: `vec4<f32>(0, 1, 2, 3)`
infers from the `0` argument that the components are `i32`, then fails
type-checking at use.

Inspection of the mandelbrot WGSL shows:
- `vec4<f32>(_656, _657, _658, _659)` — these are `f32` lets, so fine.
- `vec4<f32>(0, 0, 0, 1)` — would these be inferred as `i32`?  In
  WGSL, integer literals in a `vec4<f32>` context auto-convert if the
  result type is fixed.  But constant-folding could go wrong.
- `_1158: bool = _1153 > 256` — `_1153` is `f32`, `256` is integer
  literal.  WGSL might complain about mixing.  Need to check whether
  Tint normalizes this.
- `select(u32, u32, bool)` — WGSL `select(false_val, true_val, cond)`
  — argument order is opposite of SPIR-V `OpSelect %cond %true %false`.
  **This is a known correctness trap.**  The walker uses `emitSelect`
  in `src/spv2wgsl.zig` — verify it swaps argument order.

Investigation:
- `grep -n "emitSelect\|select(" src/spv2wgsl.zig` and audit.
- Translate one OpSelect by hand and confirm.
- Look for any `let _NNN: TYPE = ...` where `TYPE` and the RHS don't
  obviously match.

Fix strategy:
- If `emitSelect` has the wrong argument order, that explains
  EVERY incorrectly-rendered fractal in the corpus (the iteration
  check is `OpSelect %escape_cond %iter_max %iter_current` — getting
  the order wrong means the loop exits immediately or never).
- Add explicit casts (`f32(literal)`, `i32(literal)`) where needed in
  emitter helpers.

### H3.  OpAccessChain / texture-binding ghost reads (medium priority)

The shapes FS samples a texture.  The mandelbrot FS doesn't.  But the
pipeline layout — built from the introspected SPIR-V — might be putting
a texture+sampler binding into the mandelbrot FS's bind group anyway.
If the bind group is bound to a slot the shader doesn't reference,
WebGPU is supposed to allow that; but if the SPIR-V codegen is
ACCIDENTALLY reading from a never-bound texture handle, we'd get NaN
out from the texture sample and corrupt all downstream math.

Investigation:
- Inspect the mandelbrot FS WGSL for any `textureSample` calls or
  `texture_2d`/`sampler` bindings.  Earlier inspection showed clean
  bindings (only `@group(0) @binding(0) var<uniform> u: S123`).  Worth
  re-checking the freshly compiled output.
- Check `shader_introspect.zig` — does it ever emit a binding the
  shader doesn't reference?

### H4.  Loop-iteration counter type mismatch (medium priority)

Mandelbrot in Zig declares `var n: f32 = 0` (escape time) and
`var escaped: u32 = 0` (flag).  The translated WGSL shows
`phi1894: u32` (the loop counter — `i`) and `phi1911: f32` (the
escape time).  Mixing `u32` and `f32` arithmetic in WGSL has implicit
conversion rules; spv2wgsl might be dropping or mis-emitting the
conversion.

Investigation:
- Grep the WGSL for `f32(phi1894)` (correct) vs `phi1894 + 1` where
  the add result type may not match what consumers expect.
- Audit `emitConvert` in `src/spv2wgsl.zig`.

### H5.  `select` argument order (likely re-statement of H2)

If H2 reveals the `emitSelect` bug, this hypothesis collapses into it.
The fractal heavily uses `OpSelect` for branch-merging the
`iter_max`/`iter_current`/`escape_flag` values — getting the order
wrong would make the loop exit immediately, return undef, and the
canvas would show a uniform color (the FS would always pick the
"escaped on iteration 0" path).

### H6.  WGSL constant folding diverges from SPIR-V (low priority)

The walker emits a lot of `let _NNN: T = literal_expr;` chains.  If
Tint constant-folds these and a folded value overflows `i32` or
becomes `NaN`, downstream math goes wrong.  Unlikely but worth a
binary search.

### H7.  Trivial VS is producing the wrong frag_tex_coord (low priority)

The trivial VS sets `outputs.frag_tex_coord = inputs.vertex_tex_coord`.
The mandelbrot triangle has UVs `(0,0), (2,0), (0,2)`.  The FS reads
`frag_tex_coord * resolution` to get pixel coords.  If the VS is
swapping or scaling unexpectedly (e.g. emitting `vec2(1,1) - uv`),
every fragment would compute the same point in the complex plane,
producing a uniform color (= what we saw with the dusty-pink test
where the FS didn't use frag_tex_coord at all).

But the dusty-pink test produced the expected dusty pink, which means
frag_tex_coord doesn't matter for the FS that test ran.  Doesn't
confirm OR rule out a frag_tex_coord bug.  Worth verifying.

---

## §4.  Investigation procedure

Each session: pick ONE hypothesis.  Run the diagnostic.  Either confirm
or rule out.  Move to the next.

### Diagnostic toolkit (now in tree)

- **`scripts/build_standalone_wgpu.py`** — single-file HTML bundle of
  `zig-out/wgpu/wgpu_demo.wasm` + bridge.  Inlined diagnostic pane that
  captures WGSL compile errors, WebGPU validation errors, console
  warnings.

- **`./dump_one <path/to/shader.opt.spv>`** — host-built dev tool that
  runs SPIR-V through the spv2wgsl walker and prints the WGSL.  Useful
  for inspecting a specific shader's output.  Source: `/tmp/dump_one.zig`.
  Rebuild after walker changes:
  ```
  zig build-exe --name dump_one --dep spv2wgsl \
      -Mroot=/tmp/dump_one.zig -Mspv2wgsl=src/spv2wgsl.zig
  ```

- **In-shader UBO diagnostic.** Replace `shaderMain` with a one-liner
  that outputs `vec4<f32>` derived from UBO fields.  Verifies the FS
  runs and the UBO arrives.  This is what produced the dusty-pink
  confirmation 2026-05-30.

- **In-shader frag-coord diagnostic.** Replace with `vec4(uv.x, uv.y, 0, 1)`
  to see the UV gradient.  Verifies the VS->FS interpolation.

- **In-shader iteration-count diagnostic.** Run the fractal loop, but
  output `vec4(iter / 512.0, 0, 0, 1)` instead of the HSV color.
  Should show a hot-cold gradient roughly mirroring the mandelbrot
  silhouette — escaped pixels bright, set-interior dark.

- **`zig build wgpu-diff`** — runs the corpus regression.  Baseline:
  Tint 179/2, Internal 51/0/2.  Any regression means the fix broke
  something.

- **`zig build wgpu-smoke`** — runs the headless smoke driver against
  the in-tree `SwBackend`.  60 frames, ~26 bridge calls/frame.

- **Node-level wasm instantiation smoke test.**  In a script:
  ```js
  const wasm = fs.readFileSync('zig-out/wgpu/wgpu_demo.wasm');
  const imports = WebAssembly.Module.imports(new WebAssembly.Module(wasm));
  // Stub every import to () => 0; instantiate.  Catches LinkErrors and
  // missing imports without launching a browser.
  ```
  Useful for bridge-correctness checks before shipping a standalone.

### Hypothesis kill order

Plan the order so each session ends with one ruled-out hypothesis and a
new diagnostic shader for the next:

1. **H2/H5 — emitSelect argument order.**  Grep + manual audit takes
   ~5 minutes.  Highest-leverage to investigate first.  If wrong, fixing
   it might be the entire bug.

2. **H1 — phi initialization.**  Inspect the WGSL `var phi_NNN: T;`
   declarations; cross-reference against predecessor-assignment map.
   Medium-effort.

3. **H4 — type conversion edges.**  Audit `emitConvert` + walk through
   the mandelbrot WGSL looking for any `f32`/`u32`/`i32` mix without
   explicit `f32(...)` or `u32(...)`.

4. **H7 — frag_tex_coord round-trip.**  Replace mandelbrot FS body
   with `out.out_color = vec4(uv.x, uv.y, 0, 1)`.  Should see a
   horizontal red-gradient over a vertical green-gradient.

5. **H3 — ghost texture binding.**  Check generated bindings;
   compare against the shipped bind-group layout.

6. **H6 — constant folding.**  Last resort.  Bisect by stubbing
   parts of the WGSL.

---

## §5.  What's around the mandelbrot — the broader WebGPU system

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
    │  ← suspected source of the OpUndef-in-OpPhi bug (§9)
    ▼
.opt.spv  (optimized SPIR-V)
    │
    │  spv2wgsl (src/spv2wgsl.zig + src/spv2wgsl/*; pure Zig;
    │            recursive structured-CFG walker)
    │  ← Turn 3.9 of the foundations plan, complete corpus-wise
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

## §6.  Things to do AFTER the mandelbrot renders correctly

These wait until §3-§4 resolves the fractal bug.

### §6.1  Catch the regression

- Add a per-pixel WGSL test for the corrected fractal.  Capture a
  reference image of "correct mandelbrot at zoom=1.2, center=(-0.5,0),
  max_iter=512" as a PPM; add an integration test that runs the
  wgpu_demo headless and diff-checks the canvas against the reference.
- Pin the test against further regressions: any change to the walker
  that breaks the fractal image is loud, not silent.

### §6.2  Fix the missing blue quad

Diagnose why the FIRST quad in a fresh shapes_batch doesn't render
when other primitives in the same batch do.  Likely an engine bug,
not a spv2wgsl bug — possibly a vertex-buffer offset / first-draw
state issue.  Lower priority than the fractal; doesn't block §6.1.

### §6.3  Audit the standalone harness

- WASI shim: trace which `wasi_snapshot_preview1` imports actually
  get called (currently all stubbed to return 0/EBADF).  Remove
  unused ones from the bundle.  Add per-import call counters in dev
  mode.
- Validate the standalone HTML through file:// (no server).  Currently
  works in Chrome desktop; verify on Safari + Firefox.
- Add an "auto-restart on crash" mode: if `update()` throws, log it,
  drop a button to reload.

### §6.4  More examples on the wgpu path

Once mandelbrot is rock-solid:

1. **Cube3D** (`examples/cube3d.zig`).  Already runs on GL; port the
   pipeline to wgpu via the same shader-loading flow.  Exercises 3D
   transformations, depth testing, instanced draws.

2. **Damaged helmet** (`examples/damaged_helmet.zig`).  GLTF model
   with PBR materials.  Most demanding WebGPU example to date.

3. **imgui_demo** (`examples/imgui_demo.zig`).  Already in tier-A.
   Verify dynamic vertex buffers + per-frame texture atlas updates.

4. **Compute shaders.** The bridge has compute-pass imports declared
   in zimr_wgpu.ts (`js_encoder_begin_compute_pass`, etc.) but no
   demo uses them yet.  Build a simple GPU particle sim.

### §6.5  Bridge optimization

- Per-frame bridge call count is ~26.  Most are setBindGroup +
  setVertexBuffer.  Profile + collapse where possible (e.g. batch
  setBindGroup calls into a single bound-state cache).
- The standalone HTML is 2.4 MB.  ~1.8 MB is wasm, ~0.5 MB is js +
  the base64 inflation overhead.  Use `-Doptimize=ReleaseSmall` and
  measure.  Target: <1 MB single-file.

### §6.6  Documentation

- `src/notes/CHEATSHEET.md` — update with the canonical wgpu_demo
  recipe + how to make a new wgpu example.
- `src/notes/getting-started.md` — update with the standalone build
  flow.
- The 20-turn plan (`finishing_new_gpu_foundations.md`) should mark
  Turn 3.9 fully done (currently shows 8/9 phases) once the rendering
  bug is fixed.

### §6.7  Standalone refinements

- Generic bundler that works for any wgpu-driven example, not just
  `wgpu_demo`.  Take `--example NAME` argument; read
  `zig-out/wgpu/{NAME}.wasm` if it exists.
- Add a "mode" toggle in the standalone harness — slow-mo, frame
  step, pause — for visual debugging.  Persists across reloads via
  URL fragment.

---

## §7.  Where this plan fits

- **Above:** `finishing_new_gpu_foundations.md` (the 20-turn arc).
  This plan is a sub-arc within Turn 3.9 / Turn 4.
- **Sibling:** `archive/spv2wgsl-rewrite-plan.md` (archived 2026-05-29).
  Captures the rewrite arc's design.  This plan is the *aftermath* of
  that rewrite — the things the rewrite didn't catch.
- **Reference:** the spv2wgsl unit tests + corpus tests.  Adding new
  walker correctness machinery should drop tests into
  `src/spv2wgsl/walker.zig` (synthetic SPIR-V inputs) AND the corpus
  baseline (`src/tests/spv2wgsl_corpus_test.zig`).

---

## §8.  Diagnostic log — what's been done so far on the mandelbrot bug

For the next session's continuity:

1. **2026-05-29.**  Built first standalone.  Got `LinkError: wgpu
   js_device_create_sampler function import requires a callable`.
   Fixed: harness was double-wrapping the bridge's namespace.  Both
   `examples/wgpu_demo/index.html` AND
   `scripts/build_standalone_wgpu.py` had the bug.

2. **2026-05-29.**  Canvas black with text "running · WebGPU bridge ready"
   visible.  No errors logged.  Tested with `out.out_color = red`
   short-circuit at the START of shaderMain — canvas turned red.
   Concluded: pipeline + bridge work end-to-end; the bug is in the
   fractal computation translation.

3. **2026-05-29.**  Found three latent translation bugs the corpus
   tests didn't catch:
   - `isEntryFunctionContext()` was a stub returning false — entry
     output stores didn't get the `outputs.` prefix.
   - Walker's `emitTerminator` emitted bare `return;` for entry
     functions — Tint would reject (return type mismatch).
   - Walker emitted `// (walker: unexpected conditional in plain block)`
     for unstructured `BranchConditional` (the loop-iteration check) —
     no exit, GPU hang.

   Fixed all three.  Re-ran the corpus: no regressions.  Manually
   inspected the mandelbrot WGSL: all three issues confirmed gone.

4. **2026-05-30 morning.**  Canvas still showed only the engine green quad
   and magenta triangle.  No errors.  Added diagnostic pane to the
   standalone harness (captures `getCompilationInfo`,
   `uncapturederror`, console.error/warn).  Confirmed: zero WGSL or
   WebGPU validation errors.

5. **2026-05-30 morning.**  Replaced mandelbrot FS body with a UBO-derived
   color: `vec4(zoom*0.5, max_iter/1024, 0.5, 1.0)`.  Canvas filled
   with the expected dusty-pink color (~rgb(153, 128, 128)).
   **Confirmed:** FS runs, UBO is delivered correctly, full-screen
   triangle covers the canvas, output reaches the framebuffer.  Every
   layer EXCEPT the fractal computation works.

6. **2026-05-30 afternoon.**  Audited `emitSelect` — argument order is
   correct.  SPIR-V `OpSelect %cond %true %false` → ops[2]=cond,
   ops[3]=true, ops[4]=false.  WGSL `select(f_val, t_val, cond)` —
   the walker emits `select(ops[4], ops[3], ops[2])`.  **H2 disconfirmed.**

7. **2026-05-30 afternoon — ROOT CAUSE DISCOVERED.**  Inspected the
   actual post-opt SPIR-V at
   `.zig-cache/o/dd61a6fc105e9ca1a7fb21e98ab2452b/shader.opt.spv`.
   Traced the final `outputs.out_color = phi2231` back to its OpPhi.

   **phi2231 is declared in block 1323** (the merge block before
   return).  Its OpPhi has TWO predecessors:
   ```
   Phi [type=vec4<f32>, result=2231,
        value=2198 from block=1310,   ← (escaped path) computed color
        value=1961 from block=1317]   ← (escape-check false path)
   ```

   **Value 1961 is `OpUndef`!**  The walker emits this faithfully as
   `phi2231 = undef_1961;` where `undef_1961` is declared at module
   scope as `vec4<f32>()` (zero-init: `vec4(0, 0, 0, 0)`) — **fully
   transparent**.

   Trace: block 1213 is a SelectionMerge header.  Its
   `BranchConditional` jumps to 1217 (the "escaped" branch — computes
   the HSV color) or to 1317 (the "didn't escape" branch — just a
   trivial pass-through `Branch 1323`).  Block 1317 should have set
   `phi2231 = vec4(0, 0, 0, 1)` per the Zig source's
   `if (escaped == 0) { out.out_color = vec4(0, 0, 0, 1); }`.
   Instead, the SPIR-V records `phi2231 = OpUndef` for that path.

   So the bug is **NOT in spv2wgsl**.  The walker is correctly
   translating what the SPIR-V says.  The SPIR-V itself — POST-opt —
   has lost the `vec4(0, 0, 0, 1)` and replaced it with OpUndef.

   Pre-opt SPIR-V has only 2 OpPhis with OpUndef predecessors;
   post-opt mandelbrot has 30+.  **`spirv-opt` is the culprit.**
   Some aggressive pass (probably dead-code elimination or scalar
   replacement of aggregates) determined a value was unreachable
   when actually it isn't (the center of the mandelbrot set IS the
   "escaped == 0" path; those pixels are very much reachable).

   This was discovered late on 2026-05-30 and is documented here for
   the next session.  See §3.H8 below for the new top hypothesis.

8. **2026-05-30 late.**  Wrote this plan.  Restored the real fractal
   shader.  Next session continues from H8 (the spirv-opt issue) per
   §4 procedure.

---

## §9.  Pivotal hypothesis — `spirv-opt` is generating bad OpUndefs in OpPhi

This is the new top suspect, replacing H2/H5 from §3.

### What we know
- Pre-opt SPIR-V: mandelbrot has 2 OpPhis with OpUndef predecessors
  (and they're in code paths that are genuinely unreachable — Zig
  emits OpUndef for unreachable register state).
- Post-opt SPIR-V: 30+ OpPhis with OpUndef predecessors.  Including
  the final `phi2231` that becomes `out_color`.
- The "didn't escape" predecessor block (1317) is a trivial
  pass-through that should carry the `vec4(0,0,0,1)` value the Zig
  source assigns.  spirv-opt has deleted this value.

### Hypotheses about WHY spirv-opt drops the value
- **A.**  spirv-opt's `--ssa-rewrite` or `--scalar-replacement` analysis
  thinks the value flows only into a phi that has another, "more
  defined" predecessor, and replaces the redundant store with undef.
  This would be a spirv-opt bug, but plausibly user-error if our
  Zig codegen is producing SPIR-V that violates an assumption.
- **B.**  Some pass is mis-classifying the SelectionMerge's structured-CFG
  shape because Zig's lowering doesn't quite match what SPIR-V's
  optimizer expects.  spirv-opt then treats one branch as dead.
- **C.**  Our `tools/zspv` rewrite pass (which patches binding metadata
  before handing to spirv-opt) is corrupting structural metadata,
  making spirv-opt's structured-CFG passes go wrong.

### Things to try
1. **Disable spirv-opt entirely.**  Pass `--O0` (or replace the call
   with a copy) and see whether the resulting WGSL renders correctly.
   If yes, then it's confirmed to be a spirv-opt issue and we can
   either:
   - Ship with reduced optimization (slow but correct).
   - Identify which specific pass causes the issue.
   - Patch our SPIR-V before passing to spirv-opt to avoid the pattern.
2. **Disable specific passes.**  spirv-opt supports `-Os` (size),
   `--legalize-hlsl`, individual flags.  Walk through them.  The most
   likely culprits: `--eliminate-dead-code-aggressive`, `--ssa-rewrite`,
   `--vector-dce`, `--reduce-load-size`.
3. **Diff pre-opt vs post-opt.**  Write a Python script that
   disassembles both SPIR-Vs and prints a structural diff (functions,
   blocks, OpPhis).  Focus on the regions where OpUndef was injected.
4. **Add a walker fallback.**  When the walker sees a phi predecessor
   value that is OpUndef, AND there's another predecessor that's
   well-defined, AND we can prove (via the structured-CFG analysis)
   that the OpUndef path "shouldn't be reached" but actually is,
   substitute the well-defined predecessor's value.  This is hacky
   but might work as a stopgap.
5. **Hand-write the SPIR-V.**  Use the SPIRV-Tools disassembler +
   assembler to produce a SPIR-V that's identical to the post-opt
   one EXCEPT that the OpPhi predecessors with OpUndef are replaced
   with the obviously-correct value.  See if THAT produces the
   correct fractal.  Validates the diagnosis without committing to
   a fix path.
6. **Confirm via simpler test.**  Build a minimal Zig shader with the
   same one-sided-if pattern (`if (cond) { x = A; } else { x = B; }`
   followed by `return x;`).  Inspect pre-opt and post-opt SPIR-V.
   If spirv-opt drops the false branch's value to OpUndef here too,
   we've found a deterministic reproduction.

### Stopgap option (if root cause turns out to be too deep)
- Bypass spirv-opt for shaders that hit the pattern; ship the
  un-optimized SPIR-V.  Cost: larger SPIR-V (~5x in our mandelbrot
  case), slower transpile, but correct.

---

## §9.5  Self-imposed constraints

These hold throughout this plan.  They keep us honest.

- **No emscripten.**  Pure Zig + browser-native WebAssembly.
- **No npm / Bun in the shipped wasm path.**  Bun is allowed in
  build-time tools (e.g. esbuild for `zimr_wgpu.ts`) but doesn't
  enter the runtime.
- **No Dawn source in zimr.**  Dawn's parser.cc is reference only.
- **Tests pin behavior; lint warnings are compile errors.**
  No "let's just merge it and fix the tests later."
- **Document deviations in changelog.**  Every commit that intends
  to land must list what changed *and* why.
- **Standalone HTML works opened directly.**  No server needed for
  the demo to render (Chrome's WebGPU requires a secure context but
  file:// counts).
- **Backwards-correctness over forward-features.**  Don't ship a new
  walker feature unless it's tested against the corpus AND has
  unit-test coverage in `src/spv2wgsl/walker.zig`.  The three
  in-browser latent bugs found 2026-05-29 ALL slipped past the
  corpus tests because the corpus is a lexical scan, not a semantic
  one (see §5.5).

---

## §10.  Definition of done for this plan

This plan completes when:

1. Opening `prebuilt/standalone/wgpu_demo.html` in a recent Chrome
   shows a recognizable mandelbrot fractal: black cardioid + body +
   bulbs, HSV-rainbow on the iteration tail, with the engine shapes
   overlaid.
2. The corpus baseline holds (Tint 179/2, Internal ≥51 ok, 0 known-bug).
3. A reference image test for the mandelbrot canvas catches future
   regressions.
4. The standalone bundler is consolidated as
   `scripts/build_standalone_wgpu.py` (single canonical script).
5. The diagnostic pane is documented as the supported way to debug
   shader-level issues in deployed wgpu examples.
6. The OpUndef-in-OpPhi-predecessor issue is resolved (per §9) and
   any walker fixes that emerged are pinned by unit tests in
   `src/spv2wgsl/walker.zig`.

Once those land, Turn 4 of the foundations plan (the wgpu-vs-sw
split-screen mandelbrot) is unblocked and the rest of the WebGPU
subsystem (cube3D, damaged-helmet, imgui_demo, native Dawn port)
proceeds.

---

## §11.  Session 2026-05-30 (cont.) — §9 refuted, Dawn/Tint vs ours, new direction

Written after a working session that bootstrapped a fresh Linux
sandbox, landed the prebuilt-SPIRV fast path, and empirically
**disproved the §9 spirv-opt hypothesis**.  Simon also reframed the
north star (pure-Zig pipeline, no C++ compiled) and asked for a deep
read of how Dawn/Tint reaches WGSL vs how we do it.

### §11.1  Environment + the prebuilt-SPIRV fast path (Option C — LANDED)

- Bootstrapped Zig 0.16.0 + Bun 1.3.13 from `zigbun.zip` into
  `tools/`.  `zig build wgpu-demo` builds clean (141 s, all wasm
  compile; tools now instant).
- **Landed "Option C"** in `tools/build.zig`: when the host is
  x86_64-linux and `tools/spirv-prebuilt-linux-x86_64/{spirv-opt,
  spirv-val,spirv-cross}` exist, the build `installBinFile`s those
  instead of declaring the C++ compile targets.  Cold tools build
  **~10 min → 0 s**.  `installBinFile` tracks the copy as a real
  build step so it caches cleanly (the stale-binary re-invalidation
  the old README warned about does not happen).  Escape hatch:
  `-Dprebuilt-spirv=false` forces the from-source build (needed when
  rebuilding the prebuilt binaries, or on a non-x86_64-linux host).
  This aligns with the pure-Zig direction: it removes the only
  reason a fresh sandbox ever compiles C++.

### §11.2  §9 is REFUTED — spirv-opt is not the bug

The §9 claim was: "post-opt SPIR-V has 30+ OpPhis with OpUndef
predecessors (pre-opt only 2); spirv-opt is injecting them; the
`out_color` phi gets an undef predecessor."  Measured reality on the
actual mandelbrot artifacts:

- **OpUndef count (opcode word `0x00030001`):** pre-opt
  (`shader.rewritten.spv`, 34 KB) = **12**; post-opt
  (`shader.opt.spv`, 7 KB) = **1**.  spirv-opt *reduces* undefs by
  an order of magnitude — it does not create them.
- The single surviving post-opt undef is `undef_1961`, emitted at
  WGSL module scope as `const undef_1961: vec4<f32> = vec4<f32>();`
  (zero).  It is referenced exactly once: `phi2231 = undef_1961;` on
  the `else` of `if (phi1208 == 145u)`.
- **That branch is unreachable.**  Tracing the loop's exit-code phi
  (`phi1208`): 147u → `continue`; every real exit (escape, hit
  `max_iter`, hit the 1024 hard cap) routes to 145u; the transient
  153u/168u codes are always overwritten before the loop breaks.
  So at every reachable break, `phi1208 == 145u`, the `if` is taken,
  and `out_color` comes from `phi2198` — which is correctly
  `vec4(0,0,0,1)` on the "didn't escape" path and the HSV colour on
  the "escaped" path.

Conclusion: **the post-opt mandelbrot WGSL is a faithful, logically
correct translation.**  The bug is not in spv2wgsl's handling of the
mandelbrot fragment shader.  H1–H7 and the "disable spirv-opt"
thread (§9 "things to try") are closed.

The cached buggy WGSL for reference this session:
`.zig-cache/o/1580be385dfa372e8fd448ec66e05dda/shader.wgsl`
(post-opt; `outputs.out_color = phi2231;` at the tail — the exact
`phi2231` §9 named).  Its pre-opt source:
`.zig-cache/o/5b088858d3daf0aaa30bd46598b04603/shader.rewritten.spv`.

### §11.3  New top hypothesis — the vertex/index batch upload (shared with §10)

The remaining in-browser symptom (§1.9 + §10): mandelbrot canvas is
"dark with a tiny diagonal pattern of pixels in one corner," and the
first engine quad shows the *same* "diagonal pixel dashes."  Two
draws, one signature.  "Diagonal dashes" is the classic look of a
**vertex/index buffer read at the wrong offset/stride** — degenerate
triangles scattered along a diagonal — not of wrong fragment math.

The dusty-pink diagnostic filled the canvas because (hypothesis) it
ran on a draw that was *not* the broken first batch.  The mandelbrot
fullscreen triangle most likely rides the same first-batch upload
edge case as the missing blue quad in §10.

This reframes the chase: it is a **`Backend` batch-state / buffer
plumbing bug** (`src/gpu_iface.zig` / the `ShapesBatch` path), not a
spv2wgsl correctness bug.  spv2wgsl is, for the mandelbrot, done.

Next diagnostics (each a standalone for Simon to open):
1. **H7 UV-gradient FS** — replace the mandelbrot FS body with
   `out.out_color = vec4(uv.x, uv.y, 0, 1)`.  If the canvas shows a
   red→green gradient, VS→FS interpolation and the triangle are
   fine and the issue is purely the engine quad's first-batch
   upload.  If it shows the same diagonal dashes, the triangle's
   vertices are mis-uploaded → confirms the batch bug for both.
2. **Inspect the first-batch upload** — `drawTriangleBatched` /
   `flushBatch` vertex+index offsets on the first `flushBatch` of a
   frame; compare offset-0 vs subsequent-batch paths in
   `src/gpu_iface.zig`.

### §11.4  How Dawn/Tint reaches WGSL — vs how we do it

Studied `dawn-main/src/tint/lang/spirv/reader/` (reference only;
never compiled).  This is the gold-standard SPIR-V→WGSL and worth
internalizing because our walker is a deliberately-thin echo of it.

**Tint's pipeline (`reader.cc::ReadIR`):**
```
SPIR-V bytes
  → Parse()          parser/parser.cc:  SPIR-V → Tint IR (spirv dialect)
  → Lower()          lower/lower.cc:    a STACK of IR→IR passes —
                       atomics, builtins, decompose_strided_array,
                       decompose_strided_matrix, shader_io, texture,
                       transpose_row_major, vector_element_pointer
  → core::ir::Validate()                fail gracefully on bad input
  → (WGSL writer, separate)             core IR → WGSL AST → WGSL text
```
Salient properties:
- **It is IR-centric and structured.**  Tint IR represents control
  flow as first-class `If` / `Loop` / `Switch` instructions that
  *contain* blocks — not a flat basic-block CFG.  So the parser must
  RECONSTRUCT structured control flow from SPIR-V's
  `OpSelectionMerge` / `OpLoopMerge` + branches (same hard problem
  our walker solves), using SPIRV-Tools'
  `GetStructuredCFGAnalysis()`.
- **OpPhi → a value carried OUT of a construct.**  Tint converts a
  phi in a merge block into the *result* of the enclosing
  If/Loop/Switch, with each predecessor's value pushed as an operand
  onto a structured exit instruction (`ExitIf` / `ExitLoop` /
  `ExitSwitch`).  Dedicated handlers per context:
  `EmitPhiInIfMerge`, `EmitPhiInSwitchMerge`, `EmitPhiInLoopHeader`,
  `EmitPhiInLoopMerge`.  Phi values are resolved in a second pass
  (a phi can reference values defined after it).
- **Robust by necessity.**  Tint is the *browser's* front-end: it
  must accept arbitrary/adversarial SPIR-V and emit guaranteed-valid
  WGSL.  Hence the IR, the validator, and the many legalization
  passes (strided arrays/matrices, row-major transpose, combined
  texture/sampler splitting, builtin remapping).  Tens of KLOC C++.

**Our spv2wgsl (`src/spv2wgsl.zig` + `src/spv2wgsl/*`, ~2 KLOC Zig):**
```
SPIR-V words
  → pass1_walk           index each instruction (word offset table)
  → pass2_decorations    names / decorations / entry-point sideband
  → pass3_types_globals  type spellings + struct/global decls
  → pass4_functions      function bodies via the recursive walker
```
- **No IR, no AST.**  A per-id table (`IdInfo.wgsl_name`) holds the
  WGSL *text* for each SPIR-V id (type spelling, constant literal,
  var name, SSA temp `_N`, or access-chain expression).  Emission
  splices strings.
- **The recursive structured-CFG walker** (`spv2wgsl/walker.zig`)
  follows merge/continue/branch targets and emits WGSL
  `if`/`loop {…continuing{…}}`/`switch` directly — the same
  structured-CFG reconstruction Tint does, but straight to text.
- **OpPhi → hoisted `var phi_N: T` + predecessor assignments**
  (the mutable-variable model).  WGSL has no phi and no block-result
  expression, so even Tint ultimately lowers its ExitIf-value model
  to `var` mutation in its WGSL writer; we just do that lowering up
  front, in the walker.  Both converge at the WGSL-text level.
- **Deliberately not robust / not optimizing.**  Per the file
  header: "does not validate, does not optimize.  The browser's WGSL
  front-end (Tint in Chromium-family, naga in Firefox/Safari) does
  both, better than we ever could, on every shader that reaches it."

**The leverage that makes pure-Zig viable.**  We are not
reimplementing Tint — we are *feeding* it.  We only have to translate
the narrow, well-behaved SPIR-V dialect that Zig's self-hosted
backend emits into WGSL that Tint/naga will *re-validate and
re-optimize* at runtime.  That collapses a tens-of-KLOC C++ problem
into a ~2 KLOC Zig one.  It also means: shipping *unoptimized* WGSL
is fine for correctness (the browser optimizes it), which is exactly
why dropping spirv-opt from the pipeline is safe — see §11.5.

### §11.5  Pure-Zig pipeline implication (Simon's reframing)

Target pipeline, no C++ compiled at any step:
```
shader.zig → SPIR-V (Zig backend) → zspv (Zig) → spv2wgsl (Zig) → WGSL → @embedFile
```
- **spirv-cross is dead weight.**  It served the old WebGL/GLSL path
  (SPIR-V → GLSL ES 3.0).  The WGSL/WebGPU path does not use it.
  Candidate for removal from `tools/build.zig` + the pipeline.
- **spirv-opt is optional.**  It is C++ (prebuilt).  The browser's
  WGSL compiler re-optimizes, so we don't need it for correctness or
  speed-on-GPU.  Confirmed the walker already translates the
  *unoptimized* memory-form SPIR-V (34 KB → 941 WGSL lines, no
  crash).  Caveat: the no-opt WGSL is messier — it carries the
  un-stripped externs/entry machinery and emits large `undef`s like
  `array<u32, 255>()`; before making no-opt the default we should
  confirm Tint accepts it and that it renders.  Keeping spirv-opt as
  an *optional* size/cleanliness pass (default on, prebuilt, never
  compiled) is the pragmatic middle for now.
- **spirv-val** is a build-time safety net only (never shipped).
  Fine to keep as a prebuilt; a pure-Zig validator is future work.

### §11.6  Doc drift found

`src/web/readme.html` still describes the shader story as "SPIR-V →
GLSL ES 3.0 via spirv-cross" for WebGL.  That is the *old* path.
When the WGSL/WebGPU path becomes the default, the readme's shader
section + toolchain section need rewriting (claude.md: readme is the
authoritative public doc, keep it in sync).  Flagged, not yet done.

### §11.7  Delivered this session

- `tools/build.zig` Option C (prebuilt SPIRV fast path).
- `prebuilt/standalone/wgpu_demo.html` — current-state mandelbrot
  bundle for in-browser confirmation of the §11.3 symptom.
- This §11 + the §3 status correction.

### §11.8  Next session — concrete

1. Build the **H7 UV-gradient** standalone (§11.3 #1) and have Simon
   open it.  This bisects "engine-quad-only batch bug" vs
   "triangle-vertices-also-mis-uploaded."
2. Read `src/gpu_iface.zig` `drawTriangleBatched` / `flushBatch` /
   first-batch offset handling (§11.3 #2).
3. Decide spirv-opt's fate in the pipeline once the batch bug is
   fixed and the fractal renders (it will validate the no-opt path
   too).

---

## §12.  Session 2026-05-30 (cont. 2) — in-browser confirm + the NaN fix

Simon ran `wgpu_demo.html` on Android Chrome.  Screenshot: dark-blue
canvas (the clear color), a green quad top-right, a magenta triangle
center-bottom, a faint diagonal sliver top-left, `running · 60 fps`.
The 3 fractals are **absent**; 2 of 3 engine shapes render.

### §12.1  shader_uniforms wgpu status — NOT ported (GL-only)

`examples/shader_uniforms.zig` (the swirling-colors example) is a
**WebGL2 example**: it `@embedFile`s `shader_uniforms_fs.glsl` (the
spirv-cross→GLSL output) and draws via `z.beginShaderMode(f.gl, …)` —
the rlgl immediate-mode path, not the `Backend`/WGSL path.  Its
*shader* still flows through the build's SPIR-V→GLSL pipeline; only
the WebGPU draw path isn't wired.  (build.zig lines 117 + 247.)

### §12.2  Diagnosis — it's a shader-source NaN, not spv2wgsl

Walked the whole mandelbrot path statically:
- **VS:** `wgpu_trivial_vs` WGSL is a correct clip-space pass-through
  (`position = vec4(pos.xy, 0, 1)`, `frag_tex_coord = uv`).  ✓
- **Vertex layout:** `wgpu_trivial_vs_io` and `default_shapes_vs_io`
  agree (pos@0, uv@1; trivial keeps the color@2 stride).  ✓
- **FS translation:** the mandelbrot WGSL is a faithful translation
  (§11.2).  ✓

So the broken render is NOT a draw-path or translation bug.  Leading
cause: **the FS produces NaN.**  The smooth-iteration tail does
`t = smoothed / max_iter; col = hsv2rgb(vec3(.., .., pow(t, 0.4)))`.
A fast escape (large |c|) makes `smoothed = n + 1 - nu` **negative**,
and `pow(negative, 0.4)` is NaN.  A NaN color is rendered as a hole —
the clear color shows through — so the fractal looks absent, while the
near-set boundary (slow escape, `t` small-positive) renders a faint
sliver.  This matches the screenshot exactly.

This is a **shader-source bug** (it would bite the GL and CPU backends
too — they just may handle the NaN differently or use a view where
`t` never goes negative).  It is emphatically NOT a spv2wgsl bug.

### §12.3  Fix landed — clamp01 the smooth-iteration t

`examples/mandelbrot_fs.zig`: `t = zm.clamp01(smoothed / u.max_iter)`.
Clamping to [0,1] keeps `pow(t, 0.4)` finite and in-gamut.  The
clamp compiles into the WGSL as a branch→phi feeding the pow.  Corpus
fixture refreshed (24 entries); wgpu-check green.

### §12.4  Two standalones for Simon (one round-trip, max info)

1. **`wgpu_swirl_test.html`** — the mandelbrot pipeline slot running a
   finite polar **swirl** driven by `frag_tex_coord` (no loop, no
   NaN).  Tests the wgpu fullscreen-triangle DRAW path in isolation.
   - Swirl fills the canvas → draw path + VS + interpolation all work
     → the bug was the mandelbrot FS (confirms §12.2).
   - Swirl blank → the draw path itself is broken (re-open §11.3).
2. **`wgpu_mandelbrot_fixed.html`** — the real mandelbrot with the
   §12.3 clamp.  Renders a recognizable fractal → NaN was the bug,
   fix confirmed.  Still blank → deeper FS issue or draw path.

(Diagnostic note: the swirl build left an orphan entry in
`wgsl_corpus.json`; harmless — orphans are skipped, and it clears on
the next cold rebuild.)

### §12.5  Next session — concrete

- Read Simon's result on the two standalones.
  - swirl ✓ + fixed ✓  → fractal fixed; archive this arc; port the
    other fractal examples (julia, mandel_julia are declared in
    `wgpu_demo` State but never initialized/drawn — wire them).
  - swirl ✓ + fixed ✗  → another NaN/precision spot in the FS; bisect
    the escaped branch (log2(log2(|z|)) when |z| barely > 16 → tiny
    or negative → check).
  - swirl ✗            → draw path; read `bindForDraw` + the
    pipeline-switch dedup in `setPipeline`/`flushBatch`.
- Separately: the §10 blue-quad-as-diagonal (first batched quad) is
  still open — likely the same NaN was a red herring there; revisit
  once the fractal renders.

---

## §13.  Session 2026-05-30 (cont. 3) — swirl CONFIRMED; mandelbrot visibility

Simon ran both standalones from §12.4:
- **swirl test → PERFECT.**  Full-canvas animated rainbow spiral,
  119 fps.  This is the end-to-end proof: Zig FS → SPIR-V (Zig
  backend) → spv2wgsl → WGSL → WebGPU renders flawlessly through the
  typed fullscreen-triangle pipeline.  Draw path, trivial VS, and
  `frag_tex_coord` interpolation all confirmed.  **spv2wgsl works.**
- **clamped mandelbrot → still looked blank.**  Two candidate causes:
  (a) stale browser cache (served from `content://downloads/`), or
  (b) the production palette is too dark — `val = pow(t, 0.4)` with a
  narrow purple hue `0.85 + 0.4t` renders a correct fractal as
  near-black on the dark-blue clear.  The swirl pops because its
  `val` floors at 0.2 over a full hue wheel.

Shipped two fresh-named standalones (rules out cache + settles (b)):
- `zimr-fractal-real-v3.html` — the real clamped mandelbrot.
- `zimr-fractal-itercount-v3.html` — SAME loop/escape logic, BRIGHT
  heatmap coloring (`escaped==0`→black cardioid; else→`vec4(1-g, g, 1,
  1)`, `g = clamp01(n/40)`).  A correct cardioid silhouette is
  unmistakable here regardless of palette.

Decision tree for next session:
- itercount shows a clear cardioid+bulb silhouette → the loop/FS/draw
  path are ALL correct; the only issue was the dark production palette
  → brighten `mandelbrot_fs.zig`'s coloring (raise val floor, widen
  hue) and we're done.
- itercount blank too (but swirl works) → the loop itself isn't
  computing on-GPU despite tracing correct; bisect the loop (emit `n`
  directly, then the escape flag).
- real-v3 renders but earlier `mandelbrot-fixed` didn't → it was stale
  cache; the §12.3 clamp fix was already correct.

## `zig build test` red state — GLSL/WebGL path (deliberate, 2026-05-30)

`zig build test` (host unit tests + full example typecheck) is RED, and
this is PRE-EXISTING — the untouched upload baseline produces the same
errors. The operative gate `wgpu-check` is and stays GREEN. Two causes,
both understood:

1. **GLSL `@embedFile` FileNotFound** (`default_vs.glsl`, `pbr_vs.glsl`,
   `unlit_vs.glsl` referenced from `src/rlgl.zig`, `src/render.zig`,
   `examples/typed_unlit_demo.zig`). ROOT CAUSE: these `.glsl` outputs
   are build-GENERATED from `src/shaders/*.zig` and wired as anonymous
   imports (build.zig ~line 697). The `old_3d_shaders` skip list
   (build.zig ~625) deliberately EXCLUDES default_vs/fs, lambert,
   pbr, shadow, skybox, unlit from that generation loop (they access
   `shader_externs.X` at module scope + call `shader_externs.setup()`,
   both broken by the native-import codegen surgery). So their `.glsl`
   imports are never registered, and `@embedFile` of them is a
   permanent FileNotFound. The embed is LAZY — it only errors when the
   const is referenced (e.g. `loadDefaultShader` → `rlglInit`, the GL
   init path). wgpu-check never calls `rlglInit`, so it stays green;
   the `test` step instantiates the GL surface and trips it.

   This is the legacy WebGL/GLSL 3D path, mid-migration to wgpu and
   SCHEDULED FOR DELETION. Per the working agreement, we don't repair
   the embed (band-aids forbidden except in doomed systems, where the
   right move is delete/migrate). DECISION: leave these failing for
   now; convert the GLSL examples/consumers to the wgpu/WGSL path ASAP,
   then delete the GLSL generation + the old_3d_shaders special-casing
   wholesale. Until then `zig build test` is not the per-turn gate;
   `wgpu-check` is.

2. **rlsw_shader arg-count (FIXED this turn).** `rasterizeTriangles`
   takes 8 params (last is `comptime opts: RasterizeOpts`, which MUST
   be comptime — used in `switch (comptime opts.front_face)` — so it
   can't take a default). Two of nine callers were missing the 8th
   arg: `src/rlsw_shader.zig:588` (a test) and
   `src/shader_runtime_wgpu.zig:1415` (inside `makeSwDispatch` →
   `flushBatchImpl`, only instantiated when a concrete SW pipeline is
   used, which wgpu-check doesn't exercise — hence green despite the
   bug). Both now pass `.{}` like the other seven callers. rlsw is the
   LIVE software renderer (not the dying GLSL path), so this got the
   proper fix, not a skip.
