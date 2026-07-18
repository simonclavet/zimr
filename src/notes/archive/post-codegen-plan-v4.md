# Plan v4 — Cleanup pass + Track A before bulk Phase F

The foundation (codegen surgery, IoT pattern, Mode 3 native CPU, Mode 5
browser WGPU) is shipped and proven across three fractals. Before
porting the 161-example backlog locks in the current surface, this plan
captures every improvement identified in the critical re-evaluation and
sequences them.

---

## Improvements to make this week

Eight items, ranked by leverage. Items 1-6 are local cleanups (each ~30 min
to a few hours). Item 7 is the architectural unifier (multi-session). Item 8
is the first real validation of Recipe 2.

### 1. Drop schema wrappers; rename `Uniforms` → `Ubo` everywhere

**What:** delete `MandelbrotSchema`, `JuliaSchema`, `MandelJuliaSchema`
wrappers from `wgpu_demo.zig`. Pass io files directly to `loadShader`:
```zig
// before
const MandelbrotSchema = struct { pub const Ubo = mandelbrot_fs_io.Ubo; };
s.mandelbrot_shader = try z.shader.loadShader(MandelbrotSchema, ...);

// after
s.mandelbrot_shader = try z.shader.loadShader(mandelbrot_fs_io, ...);
```
For schemas like `shader_chroma_fs_io.zig` that use `Uniforms` instead of
`Ubo` (historical GLSL-style naming), rename the decl to `Ubo`.

**Why:** the wrappers add nothing — `loadShader` only calls `@hasDecl(SchemaT,
"Ubo")` and `@hasDecl(SchemaT, "Samplers")`, both of which the io files
already satisfy. The wrappers introduce a question every port has to answer
("which name do I use?") for zero benefit. Removing them eliminates 3-line
chunks per shader and a recurring source of conceptual noise.

**Touches:** `examples/wgpu_demo/wgpu_demo.zig`, every `_fs_io.zig` that has
`Uniforms`, the doc comments in the port recipe.

**Risk:** none. Pure rename + delete.

**Order:** first — unblocks the cleaner pattern for every subsequent change.

---

### 2. Hoist `autoConnect` to a shared module

**What:** create `src/shader_connect.zig` (~15 lines, zero deps beyond
`std`). Contains the comptime-monomorphized `autoConnect(VsOut, FsIo)`
function. Both `shader_runtime_wgpu.zig` (for browser-side connection in
loadShader's internals) and the native examples import it.

Native examples reach it via the `sw_runtime` bundle:
```zig
// before — each native example defines its own
fn autoConnect(comptime VsOut, comptime FsIo) ... { ... 12 lines ... }

// after
const sw_runtime = @import("sw_runtime");
const autoConnect = sw_runtime.autoConnect;
```

**Why:** the same 12-line function is currently copy-pasted into
`sw_engine_shader.zig`, `sw_mandelbrot_pipeline.zig`, and
`sw_fractal_gallery.zig`. Future native ports would each get another
copy. Killing the duplication makes the bundle pattern self-documenting
(the bundle exports the helper too) and removes a per-example footgun.

**Touches:** `src/shader_connect.zig` (new), `src/sw_runtime.zig`,
each native example.

**Risk:** none. Pure extract-method.

**Order:** second — before any new native examples land.

---

### 3. `TriangleDesc` — unify `color` and `colors`

**What:** drop the `color: [4]u8` field; keep only `colors: [3][4]u8` (no
longer optional). Add a small helper for the uniform-color case:
```zig
pub fn uniformColor(c: [4]u8) [3][4]u8 { return .{ c, c, c }; }
```
Call site for uniform color becomes:
```zig
Backend.drawTriangleBatched(&ps, .{
    .p0 = ..., .p1 = ..., .p2 = ...,
    .colors = uniformColor(.{ 255, 0, 0, 255 }),
});
```

**Why:** the current dual-field API (optional `colors` overrides legacy
`color`) is API drift I introduced when adding per-vertex colors. One
way to do things is better. Per-vertex is the more general form; the
uniform helper handles the common case explicitly. Two regression tests
(`TriangleDesc default color is uniform white...`, `TriangleDesc carries
per-vertex colors...`) get simplified to one.

**Touches:** `src/gpu_iface.zig`, `examples/wgpu_demo/wgpu_demo.zig`,
regression tests.

**Risk:** low. Breaking change at the call site, but `wgpu_demo` is the
only current caller of `drawTriangleBatched` (sw_engine_shader uses raw
vertex arrays).

**Order:** third — before bulk Phase F locks in the dual-field pattern.

---

### 4. `QuadDesc` — collapse flat fields into `Rect` for pos and uv

**What:** restructure:
```zig
// before
pub const QuadDesc = struct {
    x: f32, y: f32, w: f32, h: f32,
    uv_x: f32 = 0, uv_y: f32 = 0, uv_w: f32 = 1, uv_h: f32 = 1,
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

// after
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const QuadDesc = struct {
    pos: Rect,
    uv: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    color: [4]u8 = .{ 255, 255, 255, 255 },
};
```
Call site:
```zig
// before
Backend.drawQuadBatched(&ps, .{ .x=0, .y=0, .w=W, .h=H,
    .uv_x=0, .uv_y=0, .uv_w=1, .uv_h=1, .color=.{255,255,255,255} });

// after
Backend.drawQuadBatched(&ps, .{ .pos=.{ .x=0,.y=0,.w=W,.h=H } });
// — uv defaults to full-texture
```

**Why:** 8 scalar fields where 2 nested `Rect`s would do. Plus the full-
texture uv case becomes implicit (default). The 161 Phase F examples will
each invoke `drawQuadBatched` repeatedly; reducing per-call verbosity
adds up.

**Touches:** `src/gpu_iface.zig`, every `drawQuadBatched` call site
(currently `wgpu_demo.zig`). Future port-recipe doc updates.

**Risk:** low. Breaking change at the call site, but few current
callers. Mechanical sed-able rename.

**Order:** after item 3, before item 7. Lands the cleaner API before
Track A multiplies the call sites.

---

### 5. Default-match winding convention in `rasterizeTriangles`

**What:** change `rasterizeTriangles`'s signed-area test or add a comptime
parameter so the default matches **wgpu's screen-space CCW front face**.
Currently the rasterizer culls `area2 <= 0` triangles in screen space
(after Y-flip), which means callers writing CCW in CLIP space (the
intuitive convention, since y points up) get all triangles culled
silently.

Two options:
- **A.** Comptime parameter: `rasterizeTriangles(VsMod, FsMod, ..., comptime
  opts: struct { front_face: enum { ccw, cw } = .ccw })`. Default `.ccw`
  means clip-space CCW (matching wgpu).
- **B.** Flip the convention permanently — `area2 >= 0` accepts both
  windings (single-sided is rare for procedural-quad work).

I lean toward **A** because it gives an explicit knob without removing
back-face culling for legitimate users.

**Why:** the bug bit me twice (`sw_engine_shader` and `sw_mandelbrot_pipeline`),
documented at the call sites both times. Phase F ports will write
hundreds of vertex arrays; relying on documentation to prevent the bug
is fragile.

**Touches:** `src/rlsw_shader.zig`, the existing native examples
(remove the documentation now that the default is right), the port recipe.

**Risk:** medium. Changes the convention for existing native callers.
But there are only 3 such callers; auditable.

**Order:** before item 7 (Track A) since Track A might add new SW
rasterization paths.

---

### 6. Move `bindForDraw` and `setMaterial` from methods to free functions

**What:**
```zig
// before
s.mandelbrot_shader.bindForDraw(&ps);
s.chroma_shader.setMaterial(view, sampler);

// after
Backend.bindShader(&ps, &s.mandelbrot_shader);
Backend.setMaterial(&s.chroma_shader, view, sampler);
```

`pushUbo` stays as a method (the typed `Schema.Ubo` ergonomics are the
strong case for methods — `shader.pushUbo(.{ ... })` is meaningfully
better than `Backend.pushUbo(&shader, .{ ... })`).

**Why:** `LoadedShader` is becoming a god-object (`pushUbo`, `bindForDraw`,
`setMaterial`, `deinit`, plus the comptime `has_samplers`). The free-
function form for binding/material operations matches the verb-first
style of `Backend.drawQuadBatched(ps, desc)`. Compositionally cleaner
and keeps LoadedShader as a thin struct-with-fields.

**Touches:** `src/shader_runtime_wgpu.zig` (move methods to
`src/gpu_iface.zig`'s `WgpuBackend`), every loadShader caller in
`wgpu_demo.zig`, the port recipe.

**Risk:** low. Breaking API change but few callers.

**Order:** before item 7 (Track A might want to add `Backend.bindShader`
to `SwBackend` too — the free-function form is what makes that
symmetric).

---

### 7. Track A — wire `SwBackend.flushBatch` through the typed pipeline

**What:** make the same `Backend.drawQuadBatched(ps, desc)` +
`Backend.flushBatch(ps)` calls work on both `WgpuBackend` and `SwBackend`,
when the active pipeline is the engine's `default_shapes` pair.

Concrete steps:
1. Change `Renderer2D.shapes_pipeline` from `RenderPipeline(void, void)`
   to `RenderPipeline(DefaultShapesVs, DefaultShapesFs)` — the type
   parameters that have been dead since their introduction now carry the
   SW dispatch vtable.
2. Populate `sw_dispatch` on that type: a comptime const closure that
   takes batched vertex+index data and calls
   `rlsw_shader.rasterizeTriangles` with the engine VS+FS.
3. Implement `SwBackend.flushBatch(ps)`: if `ps.sw_dispatch` is non-null,
   call it. Currently a no-op at gpu_iface.zig:490.
4. SwBackend needs a framebuffer-shaped target. Add `SwBackend.PassState`
   carrying an `rlsw.Context`; `SwBackend.beginRenderPass` initializes
   it; `endRenderPass` is a no-op.
5. Texture binding on the SW side: the FS Io's `_texture0: TextureRef`
   field gets populated from the backend's current texture state. The
   default 1×1 white texture (matching the wgpu engine's convention) is
   the fallback.
6. Validate by writing a split-screen demo: extend `wgpu_demo` to ALSO
   run a SwBackend pass on a CPU framebuffer, composite next to the WGPU
   pass via texture upload. Same engine pipeline drives both.

**Why:** without this, every Phase F port that uses the engine pipeline
needs TWO example bodies (browser uses `Backend.drawQuadBatched`, native
uses raw `rlsw_shader.rasterizeTriangles`). With this, the same example
body works on either backend; the only difference is the `Backend` type
chosen at compile time. 143 of 161 Phase F examples use only 2D shapes;
all 143 benefit.

**Note on custom-FS pipelines (Mandelbrot etc.):** Track A as scoped
above covers the ENGINE pipeline only. Custom FS pipelines loaded via
`loadShader` still need separate native bodies because `loadShader`
takes WGSL strings, not Zig FS modules. A follow-up extension could
let `loadShader` accept both representations (Zig module for SW dispatch,
WGSL for browser); deferred until we see how Track A feels.

**Touches:** `src/renderer_2d.zig` (typed pipeline), `src/shaders/
default_shapes_bundle.zig` (sw_dispatch population), `src/gpu_iface.zig`
(SwBackend.flushBatch impl, PassState struct), `examples/wgpu_demo/
wgpu_demo.zig` (split-screen extension), tests.

**Risk:** high. This is the biggest single change in the cleanup pass.
The vtable / typed-pipeline machinery has been dormant; activating it
will surface edge cases.

**Order:** after items 1-6 (which clean up the surfaces it touches).
~3 focused sessions.

---

### 8. Port `shader_chroma_fs` end-to-end (Recipe 2 validation)

**What:** follow Recipe 2 in `src/notes/phase-f-port-recipe.md` to make
`shader_chroma_fs` render in the browser through `loadShader` +
`setMaterial` (or `Backend.setMaterial` after item 6), then on native CPU
through the bundle pattern.

Specifically:
- Verify spv2wgsl binds chroma's texture at binding 1, sampler at 2
  (matching `autoMaterialBindGroupLayout`)
- Wire a texture for chroma to sample (start with the existing
  `WgpuTexture.createCheckerboard`)
- Push the Uniforms-now-Ubo with `col_diffuse`, `u_offset`, `u_time`
  each frame
- For native: build a `TextureRef` from a 1×1 or checker pixel array,
  pass via the io's `_texture0` field

**Why:** the recipe doc claims chroma is unblocked, but no port has
actually validated it. Until one does, "Phase F is mechanical" is
aspirational. One concrete port surfaces all the spv2wgsl/binding
gotchas at once.

**Touches:** new `examples/sw_chroma_fs.zig` (native demo), new
`examples/shader_chroma_fs_bundle.zig` (bundle), additions to
`wgpu_demo.zig`, build.zig (new sw-chroma-fs target + wgpu_demo wgsl
list addition — already done).

**Risk:** medium. Unknown unknowns around spv2wgsl's handling of the
chroma binding layout.

**Order:** after Track A if Track A unifies texture-FS paths too; or
in parallel with Track A as Recipe 2 validation.

---

## Items deferred (with reasons)

### 10. **PRIORITY**: real-browser test gate

**The problem.** This session shipped 6 broken HTML iterations before
finding one that gets past pipeline creation.  Each iteration broke on
the NEXT WebGPU validation rule:

1. `@offset(N)` deprecated WGSL attribute (CreateShaderModule fails)
2. `solveLayout` missing Ubo → BGL layout vs shader mismatch
   (CreateRenderPipeline fails)
3. Vertex format index 7 mapped to `"uint8x4"` not `"unorm8x4"`
   (CreateRenderPipeline vertex attribute type mismatch)
4. spv2wgsl loop emission broken → CreateShaderModule fails on
   Mandelbrot WGSL (deferred as item 9)
5. `queueWriteBuffer` size not multiple of 4 (index buffer u16 × 9 = 18)
6. … (this is where we currently are)

**Every single one** would have been caught by loading the wasm in a
real Chromium and capturing the first `uncapturederror` event.  The
fact that none of them were caught in CI is the single largest gap in
the project's infrastructure today.  `wgpu-smoke` stubs every `wgpu.*`
import — by design — so a stub-passing wasm tells us nothing about
whether the produced WGSL parses, the produced layouts match, or the
produced buffer writes are aligned.

**Why this is hard inside the Anthropic sandbox.**  The dev sandbox
network policy blocks `storage.googleapis.com`, which is where
Puppeteer downloads its Chromium.  npm has `wgsl_reflect` (parser
only), no WGSL semantic validator, no bind-group-layout validator,
no full WebGPU implementation in plain Node.  So this gate has to live
either:
- in Simon's local dev environment (Windows, where Chrome IS available),
  invoked via the standalone bundler as a verify-then-ship step, or
- in CI (GitHub Actions, where headless Chromium is preinstalled), run
  on every PR.

**Concrete plan.**

1. **Local** — add a `--verify`-style follow-on to the in-build standalone
   (`zig build wgpu-standalone`; the `WgpuStandalone` step in build.zig —
   the Python script was deleted turn 816) that spawns Chromium headless on
   the produced HTML,
   waits 2 seconds, captures `uncapturederror` from the page, and
   reports it to the terminal.  Refuses to overwrite
   `prebuilt/standalone/*.html` if validation errors fire.  Falls back
   to "no verify available, shipping unvalidated" if Chromium isn't on
   PATH.  Total new code probably 60-100 lines of Python + a tiny JS
   bootstrap that calls `__zimr_wgpu_error` after N frames and prints
   to stdout.

2. **CI** — add a GitHub Actions workflow that runs the focused build,
   bundles the standalone, then invokes the same `--verify` step with
   `xvfb-run + chromium-browser`.  Block PRs on any captured WebGPU
   error.  Wire to the existing `claude-queue → claude-running →
   claude-done` label state machine so the Claude Code GitHub Action
   uses the gate too.

3. **For the broken cases caught this session**: each fixture under
   `tests/fixtures/wgsl_corpus.json` should grow a `validates: true`
   bit captured by feeding the WGSL to a real validator (naga-cli in
   CI; same browser gate as above for the full pipeline test).  That
   way the corpus refresh catches new spv2wgsl regressions before
   they reach a browser.

**Severity.**  Before this gate exists, any new spv2wgsl change, new
typed-pipeline change, or new layout-affecting refactor risks
silently breaking browser rendering.  We essentially have no
browser-side test coverage today.  Smoke tells us "the wasm runs"; we
need "the produced GPU state is valid."

**Touches:** the `WgpuStandalone` build step / a verify companion,
`tests/fixtures/wgsl_corpus.json` (+validates bit), new GitHub
Actions workflow, new claude.md note about the verify step in the
shipping loop.

---



**What:** the WGSL emitter (`src/spv2wgsl.zig`'s `handleLabel`,
`handleBranch`, `handleBranchConditional`) doesn't correctly close
nested `if` bodies when a branch inside them targets the enclosing
loop's merge label (a SPIR-V "early break").  Concretely, the
`mandelbrot_fs.zig` iteration loop:
```zig
while (i < 1024) : (i +%= 1) {
    if (... >= u.max_iter) break;
    if (zm.cnorm2(z) > 256.0) { escaped = 1; break; }
    z = zm.cmandelbrot_step(z, c_complex);
}
```
produces WGSL with unclosed `if` bodies followed by `} continuing {`
emitted at the wrong nesting level, plus `UNHANDLED spv opcode 83/185`
markers (OpUndef and possibly OpPhi/OpFunctionCall in patterns spv2wgsl
doesn't translate).

**Symptom in browser:** `Error while parsing WGSL: :107:5 error:
expected '}' for function body / } continuing { ...` plus subsequent
errors like `module-scope 'let' is invalid, use 'const'` and `statement
found outside of function body`.

**Why this slipped through:** the wgsl-corpus only records md5 hashes
for regression detection; it doesn't validate that the WGSL actually
parses.  The smoke harness stubs every `wgpu.*` import — no real
WebGPU device ever sees the WGSL.  A real browser is the only thing
that catches these.

**Discovered:** in this same cleanup session, while wiring the
standalone HTML for `wgpu_demo`.  The engine 2D pipeline compiles
cleanly; all three IoT-pattern fractal shaders fail.

**Why it's deferred (not done now):** real spv2wgsl loop/control-flow
work is multi-session.  Needs:
- Track open `if`/`else` scopes alongside `loop`/`switch` on the same
  frame stack, so branch-to-merge inside nested `if`s emits the right
  number of `break`s.
- Translate OpUndef (opcode 83) to an explicit default-initialized
  value of the right type.
- Translate the OpPhi pattern that the Mandelbrot loop uses for
  iteration accumulators.

**What we did instead:** temporarily disabled the three fractal
pipelines in `wgpu_demo` (loadShader calls and per-frame draws
commented out with explicit pointers back to this item).  The demo
falls back to the engine 2D pipeline drawing 3 colored triangles —
exact mirror of `sw_engine_shader.png` — which compiles cleanly and
renders in real browsers.  Native Mode 3 paths are unaffected (CPU
calls `mandelbrot_fs.shaderMain` as a regular Zig function; no WGSL
involved).

**Add a headless-browser gate.**  All three browser bugs this session
(`@offset(N)`, unbuilt Ubo BGL, `unorm8x4` mapping, plus this loop
issue) would have been caught by a Playwright/Puppeteer step that
loads the wasm in a real Chromium and captures WebGPU validation
errors.  Worth adding as a CI gate alongside wgpu-smoke.

**Touches:** `src/spv2wgsl.zig` (deep), wgsl-corpus refresh, eventual
re-enable of fractal pipelines in `wgpu_demo`.

---

## Items further deferred (with reasons)

**Bundle modules everywhere.** Could eliminate by promoting every `_io.zig`
to a real build-time module. Cost: extra `addImport` per shader in
build.zig, loss of the `@import("foo_fs_io.zig")` relative-path clarity
in shader sources. Win: -5 lines per shader. Net: defer. Revisit if
the count of bundles exceeds ~30.

**`installSpirvEntry` no-op on native.** Currently the comptime block
`comptime { _ = shader_externs.installSpirvEntry(shaderMain); }` is
present in every shader source. On native it returns void. Could elide
it from native paths but the cost is minimal (one comptime call) and
keeping it ensures the SPIR-V build always has the entry. Defer.

**Renderer2D.shapes_pipeline being typed.** Already addressed by Track A.

---

## After this cleanup: bulk Phase F porting

With all 8 items done, a typical 2D-only example port looks like:
```
# 30 minutes per example, one body
- copy a working ported example as template
- swap drawing.zig calls for Backend.drawQuadBatched / drawTriangleBatched
- pick the Backend at compile time (wgpu or sw)
- ship
```

For texture-FS examples (chroma-style): ~1 hour each, following Recipe 2.

For 3D examples (cube_split-style): blocked on a Recipe 3 still to be
written; ~2-3 sessions each until the recipe lands.

---

## Status as of writing

```
✓ Codegen surgery (_Spirv wrap)
✓ Engine shaders native-importable
✓ sw-engine-shader, sw-mandelbrot-pipeline, sw-fractal-gallery
✓ wgpu_demo 3-fractal browser scene
✓ LoadedShader.{pushUbo, bindForDraw, setMaterial}
✓ Three bundle modules (mandelbrot, julia, mandel_julia)
✓ Phase F port recipe doc (recipes 1 + 2 written, 3 unwritten)

Currently broken (expected):
✗ tier-a-check (GL-path embedFile collateral; Phase F deletion)
✗ 12 old 3D shaders disabled
✗ 29 GL-3D examples won't build
```

---

## Execution order recap

1. Item 1 (schema wrappers) — 30 min
2. Item 2 (autoConnect hoist) — 15 min
3. Item 3 (TriangleDesc unification) — 30 min
4. Item 4 (QuadDesc Rect) — 30 min
5. Item 5 (winding-order default) — 30 min
6. Item 6 (method → free function) — 30 min
7. Item 7 (Track A) — 3 sessions
8. Item 8 (chroma port, Recipe 2 validation) — 1-2 hours

Then: bulk Phase F porting begins, with the architecture finalized.
