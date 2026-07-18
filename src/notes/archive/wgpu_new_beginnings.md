# wgpu_new_beginnings.md

Bringing zimr's *shape* back on WebGPU. The wgpu backend works (cube, helmet,
textured quad all render); what's missing is the **ergonomic surface** that made
zimr feel like zimr: the `AppBridge` run-loop, the `Frame` parameter, the
no-globals discipline, the canvas-resize / coordinate rules, and the
renderer-polymorphic `gl: anytype` path that lets one piece of scene code drive
rlsw AND the GPU. The goal is examples that look **almost identical to their
pre-wgpu form** — same `AppBridge.run(init, .{...}, State, initState, update)`,
same `fn update(f: *Frame, s: *State)` — but with WebGPU underneath.

This plan is the north star for that. It supersedes `finishing_webgpu.md §8` as
the *active* plan (that doc's all-examples-port goal stays valid but is GATED on
this work — see §0). **Do not port more wgpu examples until the basics here
land.** (Simon, turn ~875.)

> Naming: steps are tagged `N1`, `N2`, … (the "new beginnings" arc). Substeps
> `N1a`, `N1b`. Report progress as "N2 done, N3 next."

---

## 0. The target (what "done" looks like)

The authoritative description of zimr's intended shape is `src/web/readme.html`
(the public README). The relevant invariants it documents:

1. **No user-facing globals.** Functions take dependencies as arguments: `gl`,
   `input`, `time` arrive via the `Frame`; per-app state (fonts, arenas, GPU
   resource worlds) lives on the user's `State`. The only module-level vars sit
   at the JS bridge for stable wasm export addresses, audited by
   `scripts/count_globals.py`.

2. **The AppBridge pattern.** Every example is a body fragment around:
   ```zig
   var zimr_app: z.AppBridge = .{};
   pub fn main(init: std.process.Init) !void {
       try zimr_app.run(init.gpa, .{ .window = .{ .title = "...", .width = 800, .height = 450 } },
           State, initState, update);
   }
   fn initState(gpa: std.mem.Allocator, f: *z.Frame, s: *State) !void { ... }
   fn update(f: *z.Frame, state: *State) void { ... }
   ```
   `Frame` is a small data struct (gl, input, time, window, audio). `initState`
   takes the State pointer as an out-param. This is what `examples/basic.zig`
   and ~100 others use today on the GL backend.

3. **Same shader, three backends.** One `shaderMain` in `<name>_fs.zig`
   compiles to: SPIR-V→WGSL (WebGPU), SPIR-V→GLSL ES (WebGL), and native wasm
   (the rlsw CPU dispatcher, `rlsw_shader.dispatchFragmentShader`). All share
   the same `_fs_io.zig` schema (Inputs / Samplers / Outputs / Ubo). This
   already works; the wgpu path just needs to be reachable through the
   ergonomic surface.

4. **The headline demo: CPU | GPU side-by-side, same shader.**
   `examples/mandelbrot_split.zig` runs `mandelbrot_fs.zig`'s `shaderMain`
   through rlsw (CPU, left of a cursor divider) AND the GPU (right), same world
   coords, divider = pipeline-divergence detector. **Today the GPU half is
   WebGL/rlgl.** The end state of this plan is the *same demo with the GPU half
   on WebGPU* — proving rlsw and wgpu share shader + scene code in one app.

The renderer-polymorphism mechanism that makes (4) possible already exists:
`src/renderer_trait.zig` defines `assertIsGlContext(gl)` (a comptime trait) plus
`GlAdapter` (wraps `*rlgl.GlState`) and `SwAdapter` (wraps `*rlsw.Context`),
both exposing the same method surface so `fn drawX(gl: anytype, ...)` drives
both with zero overhead. Its own comment says: *"Adding a third renderer is a
third adapter struct."* That third adapter — a wgpu one — is the spine of this
plan.

---

## 1. How raygpu does it (the reference, studied turn ~875)

raygpu (`/tmp/raygpu/raygpu-master`, an Emscripten/Dawn WebGPU raylib
reimplementation) is the closest existing model for "raylib API on WebGPU." Key
patterns worth stealing, and where they map in zimr:

- **`BeginDrawing` / `EndDrawing` own the surface + render-target stack.**
  `BeginDrawing` calls `GetNewTexture(surface)` to acquire the frame's swapchain
  texture and pushes it on a render-target stack; the example body then does
  `ClearBackground / BeginShaderMode / Draw* / EndShaderMode / DrawFPS`;
  `EndDrawing` pops + `PresentSurface`. The example never touches the
  device/queue/encoder. → zimr's `Frame`-driven `beginDrawing(f)` /
  `endDrawing(f)` should wrap exactly this, hiding `GpuFrame.beginFrame` /
  `beginRenderPass` / `endFrame`.

- **The surface OWNS its depth texture, and auto-resizes it to match.**
  `backend_wgpu.c:830` — on every `GetNewTexture`, if
  `depth.width/height != color.width/height`, it reallocates the depth texture
  to the new size. This is the canonical fix for the depth-size-mismatch bug we
  just hit by hand: **the depth attachment must always equal the surface size,
  and the only robust way is to tie depth allocation to the surface, re-checked
  each frame.** zimr's `GpuFrame` must own + auto-resize the depth texture, not
  push that onto each example (see N1).

- **A single `g_renderstate` with a current pipeline / render-target / pass.**
  raygpu keeps a global render-state. zimr's no-globals rule forbids that —
  the equivalent state lives on the `Frame` / a per-app `App` struct threaded as
  an argument. (This is zimr's deliberate divergence; keep it.)

- **`InitWindow(w, h, title)` then a platform main-loop** (`emscripten_set_main_loop`
  on web). zimr's analogue is `AppBridge.run(...)` + the JS RAF loop in the
  bridge calling the wasm `update` export. raygpu's `GetScreenWidth/Height`
  reflect the live drawable size → zimr's `Frame.window.screen_width/height`
  must do the same and update on canvas resize (see N2).

What we do NOT copy: raygpu's globals, its C immediate-mode pipeline-state stack
(we keep typed pipelines + the `Frame` arg), and its Dawn-native specifics.

---

## 2. Current state (what exists vs. what's missing) — turn ~875

**Works on wgpu today:**
- `GpuFrame` (`src/gpu_frame.zig`): holds device/queue/surface/format + caches;
  `beginFrame` acquires the surface view + encoder. **But** `depth_format` is an
  optional field and **no depth texture is owned or resized** — each demo
  hand-creates one at a fixed `width×height` (the bug we just fixed by hand).
- `gpu_iface.WgpuBackend`: `beginFrame` / `beginRenderPass` / `setPipeline` /
  `setBindGroup` / draw / `endRenderPass` / `endFrame`. Pass-based, explicit.
- `Renderer2D` (`src/renderer_2d.zig`): batched 2D shapes pipeline (the engine
  `default_shapes` typed shader), a matrix stack, `orthoTopLeft`. **No text, no
  scissor, no circle** in its public surface yet.
- `pbr3d` (`src/pbr3d.zig`): the reusable 3D PBR renderer (this session).
- `wgpu.getSurface()` / `getSurfaceFormat()` / `getCurrentTextureView()` /
  `surfacePresent()`. **No surface-size query.**
- The JS bridge (`src/web/zimr_wgpu.ts`) `configure`s the context ONCE with no
  DPR handling and **no resize path**.
- On-page diagnostics: the standalone (buildaux) mirrors `console.*` + WebGPU
  error scopes into an on-page pane; `pbr3d` logs via `dom.js_log`. Keep + reuse.

**GL-only, must be brought to wgpu:**
- `AppBridge` (`src/zimr.zig:2149`): `run()` builds the GL runtime, allocates
  State, calls `init_fn`, hands off to the RAF loop. Body is GL/dom-extern bound.
- `Frame` (the `f.gl`, `f.input`, `f.time`, `f.window`, `f.audio` struct): the GL
  `f.gl` is an `rlgl.GlState`. The wgpu equivalent needs a GPU-backed `gl` (or a
  parallel field) that scene code can drive.
- The **coordinate-system + canvas-resize rules** (documented in
  `src/notes/claude.md` "Coordinate systems"): two pixel kinds (CSS vs backing),
  `.responsive` (logical==CSS, reprogram ortho each frame to live canvas dims)
  vs `.fit` (fixed logical size, letterbox) modes, and the **input contract**
  (all input enters wasm in logical pixels; conversion at the JS bridge). NONE
  of this exists on the wgpu bridge yet.
- `scripts/count_globals.py` audits the GL build; needs to also cover the wgpu
  module so the no-globals rule is enforced there too.

---

## 3. The plan (ordered: lowest-level correctness → ergonomics → parity → demo)

Ordering principle: **fix the foundation (surface/depth/resize) before building
the run-loop on top of it; build the run-loop before the 2D parity that examples
need; reach the side-by-side demo only once both renderers share the frame.**
Each step ends GREEN (builds + wgpu-smoke + a Chrome reload via the on-page log)
and snapshots.

### N1 — GpuFrame owns + auto-resizes the depth texture  [FOUNDATION]
The depth-size bug must become structurally impossible. Move depth ownership out
of the examples and into `GpuFrame`, mirroring raygpu's surface-owns-depth.
- N1a. `GpuFrame` gains an owned `depth_texture` + `depth_view` (created lazily
  on first `beginFrame` when `depth_format != null`).
- N1b. Add `wgpu.getSurfaceSize(surface) -> {w, h}` (bridge: read
  `canvas.width/height`, the backing pixels). Each `beginFrame`, compare the
  surface size to the owned depth texture's size; if different, **destroy +
  recreate the depth texture to match** (raygpu `backend_wgpu.c:830`). This also
  handles resize for free.
- N1c. `beginRenderPass` uses `GpuFrame`'s owned depth_view. Remove the
  hand-made depth textures from `pbr3d` (it takes depth from the frame) and from
  every wgpu demo. The `width`/`height` init params on `pbr3d.Renderer.init`
  go away (or default to surface) — depth is the frame's job now.
- N1d. Verify: helmet + cube + textured-quad all still render with the depth
  texture now frame-owned; deliberately set a demo canvas to a mismatched size
  and confirm it STILL renders (auto-resize works) instead of going blank.
- **Net:** the bug we just hand-fixed can never recur, and resize is handled.

### N2 — The wgpu surface/canvas + coordinate model  [FOUNDATION]
Bring the claude.md "Coordinate systems" rules to the wgpu bridge so logical vs
backing pixels, DPR, and resize behave like the GL path.
- N2a. JS bridge: on init AND on `ResizeObserver` / `visualViewport` change, set
  `canvas.width/height = clientWidth/Height * devicePixelRatio` (backing px),
  re-`configure()` the context, and record CSS + logical dims. (Mobile-safe:
  feature-detect, don't hardcode.)
- N2b. Implement the two scale modes from claude.md: `.responsive` (logical ==
  CSS px; the per-frame ortho / projection is reprogrammed to the live canvas
  dims) and `.fit` (fixed logical `width×height`, uniform scale + letterbox).
  Expose the active viewport rect to wasm (for hit-testing + overlay mapping),
  same exports the GL runtime has (`runtime_viewport_offset_*`).
- N2c. The **input contract**: all pointer/touch coords enter wasm in *logical*
  pixels, converted at the JS edge (CSS→logical), identical to GL. The wgpu
  bridge currently has minimal input; bring it to parity with the GL bridge's
  `pushMouseMove` / touch path.
- N2d. Verify on desktop (DPR=1) AND a phone screenshot: a demo that draws at
  the canvas edges stays aligned after a resize / rotate; clicks land where
  things are drawn.
- **Net:** wgpu examples resize correctly and input is in the same space as
  drawing — the precondition for any interactive (UI / split-divider) demo.

### N3 — `z.wgpu` App + Frame run-loop (AppBridge parity)  [ERGONOMICS]
The big one: make `AppBridge.run(init, cfg, State, initState, update)` work on
wgpu, so examples are written in the standard form. Two sub-decisions to settle
in the doc first (rubberduck with Simon):
  - **(D1)** One `AppBridge` that picks backend from `cfg` (`.backend = .wgpu`),
    or a parallel `z.wgpu.App` with the same method shape? Leaning: **extend the
    existing `AppBridge`** with a backend switch, so examples differ by one
    config field, not a different entry point. The GL `run()` body gets gated
    (`if backend == .gl`) and a wgpu `run()` body added beside it.
  - **(D2)** What does `Frame.gl` become on wgpu? Options: (a) a `WgpuGl`
    adapter exposing the rlgl-style immediate surface backed by `Renderer2D`
    (maximizes scene-code reuse, drives gl_iface), or (b) a distinct
    `Frame.gpu` handle and examples call `z.draw*`/Renderer2D directly. Leaning:
    **(a)** — a `WgpuGl` that satisfies `gl_iface`'s trait, so the SAME
    `fn drawX(gl: anytype)` scene code runs on rlgl, rlsw, AND wgpu. This is
    what makes N6 (side-by-side) and the bulk port cheap.
- N3a. Define `Frame` for wgpu: `gl` (the `WgpuGl` adapter), `input`, `time`,
  `window` (with live `screen_width/height` from N2), `audio` (already backend-
  agnostic). Same field names as the GL Frame so example bodies are unchanged.
- N3b. wgpu `run()`: init device/queue/surface (today's demo `main` boilerplate)
  → build `GpuFrame` (now depth-owning, N1) → allocate State → call `initState`
  → register the per-frame thunk that builds the `Frame` and calls the user
  `update`. The ~40 lines of device/cache boilerplate every demo repeats today
  collapses into this one place.
- N3c. `beginDrawing(f)` / `endDrawing(f)` wrappers (raygpu-style) that hide
  `GpuFrame.beginFrame` + `beginRenderPass` (clear) + `endRenderPass` +
  `endFrame`. `clearBackground(f, color)` sets the clear.
- N3d. Port ONE existing wgpu demo (the textured quad or cube) to the new
  AppBridge form as the proof: it should shrink to ~`basic.zig` size and read
  like a GL example. Keep the old hand-rolled version until N3d is Chrome-green,
  then delete it.
- **Net:** new wgpu examples are written exactly like GL examples.

### N4 — `WgpuGl` adapter satisfies the `gl_iface` trait  [PARITY SPINE]
Make `Frame.gl` (wgpu) pass `gl_iface.assertIsGlContext` so renderer-polymorphic
scene code compiles against it.
- N4a. Enumerate the trait surface `assertIsGlContext` requires (the methods
  `GlAdapter`/`SwAdapter` expose: `rlBegin/rlEnd`, `vertex3f`, `color4ub`,
  matrix ops, `setBlendMode` via the `BlendMode` enum, etc.). List them
  explicitly in this doc.
- N4b. Implement those on `WgpuGl`, backed by `Renderer2D`'s batch (immediate
  `vertex3f`/`color4ub` calls accumulate into the shapes batch; `rlEnd` /
  `endDrawing` flushes). The matrix stack maps to `Renderer2D.MatrixStack`.
- N4c. Verify: a trivial `fn drawTri(gl: anytype)` compiles + runs against
  GlAdapter, SwAdapter, AND WgpuGl from one source.
- **Net:** the "third adapter" the gl_iface comment anticipated; scene code is
  now renderer-agnostic across all three.

### N4.5 — Quarantine the WebGL path (don't compile it)  [DECK-CLEARING]
**Why now, before N5:** the GL path is slated for deletion, and right now it's
the only source of build noise on the new path (the pre-existing
`damaged_helmet-check` `Uniforms` mismatch; the Zig-0.17 `bufPrintZ`/`dupeZ`
breakage class lives in GL files like `ui.zig`/`drawing.zig`/`camera2d.zig`; the
GL `src/tests.zig` imports pull `rlgl`/`ui`/`shader_runtime`). Quarantining it
means a broken GL file can't fail our build, so N5/N6 work against a quiet,
wgpu-only tree. **Do NOT delete anything** — just stop compiling it, reversibly.

Mechanism — one build knob `-Dgl=<bool>` (DEFAULT FALSE, since GL is deprecated):
- N4.5a. Add `-Dgl` via `b.option(bool, "gl", ...)` (default false) next to the
  existing `-Dmode`. Expose it as `build_options.gl_enabled` (extend the
  existing `build_opts`/`@import("build_options")` wiring at build.zig ~444).
- N4.5b. Gate the GL **examples list** (build.zig:51 `const examples`): when
  `!gl`, the loop builds NONE of them (and skips their `test_step` typecheck
  objs + GL example smoke). The ~80-entry list is preserved in source, just not
  iterated. The wgpu demo blocks (separate, build.zig ~1487+) are untouched and
  always build.
- N4.5c. Gate the GL-only imports in `src/tests.zig` behind
  `if (build_options.gl_enabled)` (a comptime block): `app_bridge_test`,
  `ui_screenshot_test`, `ui_dock_*`, `shader_runtime.zig`, `rlgl.zig`, `ui.zig`,
  `drawing.zig`, `runtime.zig`, `render.zig`, `scene.zig`, `web.zig`, `sound.zig`,
  `typed_shader_test`, etc. KEEP always-on (shared/needed by wgpu): the whole
  `spv2wgsl/*` set, `spv2wgsl_corpus_test`, `codecs.zig`, `entities.zig`,
  `rlsw.zig` + `rlsw_shader.zig` + `renderer_trait.zig` (these three are shared — rlsw
  is the CPU renderer for N6's side-by-side, and gl_iface is WgpuGl's trait),
  `block_table`/`selection`/`loop`/`switch`, `leak/multiapp/features/ext_storage`
  (backend-agnostic). The line between "GL-only" and "shared" must be drawn
  carefully per-import; when unsure, KEEP it (a passing test is cheap).
- N4.5d. Verify: `zig build` + `zig build test` + the whole-tree lint gate all
  green with `-Dgl` default-off; the 4 wgpu demos + the wgpu umbrella + the
  shared corpus tests still pass. Then confirm `-Dgl=true` STILL builds the GL
  path (so the knob is honest + nothing was actually deleted) — accepting that
  the known GL breakage means `-Dgl=true` may not be fully green; that's fine,
  it's quarantined, not fixed.
- **Net:** the default build is wgpu-only and quiet. Any GL rot is invisible
  until we either fix-on-resurrect or delete (a future arc). N5/N6 proceed
  without GL distraction.

> Ordering note: N4.5 is deliberately AFTER N4 (so WgpuGl/the trait exist and
> compile — we don't want to quarantine GL only to discover the wgpu path needed
> something GL-only) and BEFORE N5 (so the 2D-parity work happens on a clean
> tree). It is low-risk and reversible, so it's the right opening move now.

### N5 — 2D parity on wgpu + finish the ergonomic surface  [PARITY]
The 2D drawing surface examples actually use, PLUS the two ergonomic gaps the
earlier steps deferred (input; one canonical entry point). Ordered so each
substep unblocks the next; N5d (input) and N5e (textured 2D) are hard
dependencies for N6.

- N5a. **DONE** (turn ~885) — `beginDrawing`/`endDrawing`/`clearBackground` on
  `z.App` + projection→per-frame-UBO wiring + `drawRectangle`/`drawCircle`,
  driven through `f.gl` (the WgpuGl adapter). `examples/wgpu_shapes_demo`
  renders rectangles + circles in Chrome, GPU scopes clean — this retired N4's
  "visual pending." WgpuGl is proven end-to-end on real geometry.
- N5b. **One canonical entry point.** The PBR/helmet demo still uses the OLD
  hand-rolled `main()` (manual device/queue/cache construction); the quad +
  shapes demos use `z.App.run`. Port `wgpu_pbr_demo` (and `wgpu_cube_demo`,
  `wgpu_lambert_demo`, `wgpu_demo`) to `z.App.run`, so there is ONE way to start
  a WebGPU program. Cheap, high-value consistency; the blog flagged it. The App
  must expose the 3D path too (a way to get `f.gpu` + build a pbr3d Renderer in
  `initState`) — it already does (`f.gpu`), so this is mostly deleting
  boilerplate. **Gate:** all 4 existing wgpu demos build+smoke+render in the
  AppBridge form; the hand-rolled `main()` bodies are gone.
- N5c. **Remaining 2D shapes.** ellipse, line (thick → quad), triangle, polygon,
  polyline, rounded-rect. Also harden the shapes demo's color math (the
  `@intFromFloat` on a possibly-negative expression is a latent trap — clamp).
  Backed by WgpuGl's `begin/vertex/end`; points/lines need the
  line/point→triangle expansion WgpuGl currently skips (it only emits
  `.triangles`/`.quads` today).
- N5d. **Input contract** (deferred from N2/N3). The wgpu bridge currently has
  NO input — N6's divider needs cursor-X, and any interactive demo needs it.
  Wire pointer/touch/wheel/keys from the JS bridge to wasm `input_push_*`
  exports, converting to LOGICAL pixels at the JS edge (CSS px == logical px in
  `.responsive`, the only mode in play). Surface as `f.input` on the Frame
  (mirroring the GL `Frame.input`: mouse pos/buttons, wheel, just-pressed/down,
  touches). **Gate:** the shapes demo reacts to a click/drag in Chrome.
- N5e. **Textured 2D** (real `setTexture`). WgpuGl's `setTexture` is a stub
  today (forces a flush + records the id but doesn't swap the material bind
  group). Make it swap Renderer2D's material group so textured quads + sub-rects
  work. This is a hard dependency for N5f (text uploads a font atlas as a
  texture) and N6 (the rlsw half uploads its CPU framebuffer as a texture).
  Add `drawTexture`/`drawTextureRec` + blend modes + Camera2D.
- N5f. **Text** — the single biggest 2D gap. Font-atlas upload (via N5e) + glyph
  quads: `FontCache` + `drawText` + `measureText`. Reuse the GL font-atlas code
  where backend-agnostic. **Gate:** the shapes demo draws an FPS counter + a
  label in Chrome.
- N5g. **Scissor / clip** (`beginScissorMode`/`endScissorMode`) — needed for any
  multi-panel demo (gallery, the N6 split divider). WebGPU `setScissorRect` on
  the pass; WgpuGl flushes the batch at each scissor change.
- **Net:** the 2D/UI surface is complete + the WebGPU ergonomic surface is
  finished (one entry point, input, text). DON'T bulk-port the example corpus
  yet — that's N8, gated until this closes.

### N6 — The CPU | GPU side-by-side demo on wgpu  [THE HEADLINE]
Reproduce `mandelbrot_split` with the GPU half on **WebGPU** instead of WebGL —
the proof that the architecture runs rlsw + wgpu in one app off one shader.
Depends on N5d (input, for the divider) + N5e (textures, for the rlsw upload).
- N6a. Fullscreen-shader helper on wgpu: a fullscreen-triangle pipeline binding
  a small uniform block + running an engine `_fs.zig` shader's WGSL.
  `mandelbrot_fs.zig`'s `shaderMain` → WGSL via the existing build pipeline.
  (Note: N6 re-introduces `mandelbrot_fs` compilation, which N4.5 gated off with
  the GL examples — wire it into the wgpu build path independently.)
- N6b. CPU half unchanged: `rlsw.Context` sized to the canvas,
  `rlsw_shader.dispatchFragmentShader(mandelbrot_fs.shaderMain, ...)` per pixel,
  uploaded as a texture (via N5e). Both halves consume the SAME
  `mandelbrot_fs_io` Ubo + SAME `shaderMain`. (This is also where the
  `SwPipelineDispatch ... rasterizes a triangle` test, currently SKIPPED as a
  turn-3 stub, gets its real implementation + un-skip.)
- N6c. The divider: cursor-X (logical px, via N5d) chooses which pipeline's strip
  shows. Written in the N3 AppBridge form with N4/N5 `WgpuGl` for the divider +
  HUD overlay.
- N6d. Verify in Chrome: drag the divider, confirm CPU and GPU halves are
  pixel-identical across it (divergence = a real pipeline bug — the demo's point).
- **Net:** rlsw + wgpu proven side-by-side, same shader source.

### N7 — Enforce + document  [CLOSE the new path]
- N7a. Extend `scripts/count_globals.py` (or the audit) to cover the wgpu module
  (`wgpu_app.zig`/`wgpu_draw.zig` added module-level vars: `active_app`,
  `prev_frame_ms` — both single bridge handles, the sanctioned exception). The
  no-globals rule holds on both backends.
- N7b. Architecture `//!` doc atop `src/zimr_wgpu.zig` (the canonical WebGPU
  front-door doc, per claude.md): the App/Frame/WgpuGl model, depth-owning
  GpuFrame, the coordinate/DPR rules, the gl_iface three-renderer story, and the
  shader→WGSL pipeline. Other wgpu files get a one-line pointer. Fold in the
  resolved SCCP-rewrite design (folded-CFG reachability + back-edge rule) as a
  doc comment in `sccp.zig` so it's not just plan history.
- N7c. Update `src/web/readme.html` + the CHEATSHEET for the WebGPU AppBridge
  (the `z.App.run` form, `f.gl`/`f.gpu`/`f.input`, the side-by-side demo).
- **Net:** the WebGPU path is documented to the same standard as the GL path was.

### N8 — Bulk port the example corpus to WebGPU  [THE LONG TAIL]
Only after N5–N7. This is the old `finishing_webgpu.md §8` goal, now reachable
because the ergonomic surface + 2D parity exist: a GL example's body (`fn update(f, s)`
+ `f.gl` drawing calls) is now backend-portable, so most ports are a near-mechanical
change of the import + entry point. Port in the §8.3 priority order (3D showcase,
fullscreen shaders, 2D primitives, UI/imgui, physics/sim, audio). As coverage
grows, the `-Dgl` default-off quarantine becomes permanent and the WebGL path +
`zimr.ts` + the GL-only files get DELETED (a distinct, later sub-arc — deletion,
not just quarantine). N8 closes when the WebGPU example set matches the GL one
and GL is gone.

---

## 4. Guardrails (hold across every step)

- Never regress the 4 working wgpu demos (cube, lambert, helmet, textured quad)
  — re-smoke + Chrome-reload each after any shared change (`GpuFrame`,
  `Renderer2D`, the bridge).
- Keep `codecs` / `types` / `zm` / `math` PURE + shared (the helmet relies on
  codecs under wgpu).
- Every step verified by `wgpu-smoke` (no-GPU trap check) AND a real Chrome
  reload — Tint is the only uniformity authority; the on-page log
  (console mirror + GPU error scopes, now in buildaux) is the channel. **The
  depth-size bug proved smoke-pass ≠ renders; always Chrome-verify visuals.**
- One subsystem, one canonical `//!` doc (N7c). Don't scatter architecture notes.
- Land in reviewable steps; snapshot (`zimrN.zip`) between.
- The no-globals rule is the soul of zimr's API — N3/N4 must thread state
  through `Frame`/`State`, never reach for a `g_renderstate` (that's the one
  raygpu pattern we explicitly reject).

---

## 5. Status board

- N1 (GpuFrame owns+resizes depth): **DONE** (turn ~876). GpuFrame owns the
  depth texture + auto-resizes it to the surface each frame (wgpu.getSurfaceSize
  + GpuFrame.ensureDepth, called from WgpuBackend.beginFrame, returned via
  FrameContext.depth_view). All 4 wgpu demos migrated off hand-made depth;
  pbr3d.InitOptions lost width/height. The depth-size bug class is now
  structurally impossible. lint-check GREEN (0/277), all 4 demos smoke-pass,
  transpiler corpus NO REGRESSIONS.
- N2 (wgpu canvas/DPR/resize): **DONE** (turn ~877). Bridge now sizes the canvas
  backing store to clientW/H x devicePixelRatio and re-syncs via ResizeObserver
  (host CSS still owns display size; no style writes). N1's depth auto-follows.
  Demos compute aspect from the LIVE surface size (getSurfaceSize) so projection
  is correct at any DPR/size. NOTE: the logical-pixel INPUT contract is deferred
  to N3 (input arrives as Frame.input; the wgpu demos have no input exports yet,
  so wiring it now would be ahead of the harness). `.fit`/letterbox mode also
  deferred -- nothing uses it; `.responsive` (CSS px == logical px) is the only
  mode in play. lint-check GREEN (0/277); 4 demos smoke-pass.
- N3 (AppBridge+Frame on wgpu): **DONE** (turn ~878). `z.App.run(cfg, State,
  initState, update)` + `z.Frame` (f.gpu / f.time / f.window) in src/wgpu_app.zig;
  the library's `update` export drives the JS RAF loop. Quad demo rewritten in
  the standard form (boilerplate gone into App.run) -- Chrome-confirmed.
  D1 RESOLVED: parallel z.App, NOT a shared AppBridge (GL Frame.gl is concrete
  *rlgl.GlState + AppBridge.run builds a GL App; unifying would ripple a
  backend tag / polymorphic gl through 100+ GL examples). D2: Frame carries
  f.gpu for now; f.gl (WgpuGl adapter) is N4. lint-check GREEN; smoke confirms
  the run-loop dispatches trap-free.
- N4 (WgpuGl satisfies gl_iface): **DONE** (turn ~885). src/wgpu_draw.zig: the 14
  trait methods + matrix stack + immediate-mode→Renderer2D batch. Trait proven
  by green build; the two WgpuGl unit tests run+pass (turn ~880). Visual proof
  landed via N5a (the shapes demo renders real geometry through f.gl in Chrome).
- N4.5 (quarantine WebGL, `-Dgl` default off): **DONE** (turn ~883). `-Dgl`
  (default false) → build_options.gl_enabled gates the ~80 GL examples, the
  GL-only src/tests.zig imports, and two host fractal demos. Shared (spv2wgsl,
  codecs, entities, rlsw/rlsw_shader/gl_iface) kept always-on. `zig build` +
  `zig build test` + lint all GREEN gl-free; `-Dgl=true` still builds.
- N5 (2D parity + finish ergonomic surface):
  - N5a (beginDrawing/shapes/visual proof): **DONE** (turn ~885). wgpu_shapes_demo
    renders rect+circle through f.gl in Chrome; GPU scopes clean.
  - N5b (one canonical entry point): **DONE** (turn ~886). Ported wgpu_pbr_demo
    (flagship, pbr3d path), wgpu_cube_demo + wgpu_lambert_demo (raw-pipeline
    path) to z.App.run — hand-rolled main()/export-update gone, now
    initState/update(f,s) via f.gpu + f.window.aspect(). All Chrome-confirmed
    (helmet w/ 5 maps, depth-tested cube, lambert). `wgpu_demo` (a fractal
    loadShader test) DEFERRED to N6: it imports julia/mandel_julia _fs_io which
    N4.5's GL-off quarantine left unwired — N6 brings the fractal shaders back
    on the wgpu side, so port it then. (Also fixed a latent gate bug: build.zig
    was fmt-dirty, failing lint-check's fmt-check step — now green.)
  - N5c (remaining shapes + color-math clamp): NOT STARTED.
  - N5d (input contract / f.input): **DONE** (turn ~888, Chrome-confirmed).
    Reused runtime.zig's pure InputState/Mouse/Keyboard/Touch (dom externs are
    fn-scope → no GL pulled). App owns input_state, advances it each frame
    (input.endFrame). f.input on the Frame; getters re-exported (z.getMousePosition,
    z.isMouseButtonDown, z.getMouseWheelMove, ...). 10 input_push_* wasm exports
    route to the active app. Bridge (buildaux standalone template) wires
    pointermove/down/up/wheel → exports, converting clientX/Y → canvas-local
    logical px via getBoundingClientRect. Shapes demo now has a cursor-following
    circle (red while pressed) + rects brighten on mouse-down. Also fixed the
    @intFromFloat color wart (clampColor). lint-check GREEN (0/280); smoke passes.
    NOTE: input listeners are in the standalone template; the per-demo index.html
    bootstraps need the same wiring (follow-up, not blocking).
    COORD FIX (turn ~888): a DPR scale bug had the cursor land at 1/DPR of the
    finger. Root cause: the 2D ortho + f.window were in BACKING px but input
    arrives in CSS px. Fixed by making both the ortho AND f.window.screen_width
    LOGICAL (CSS) px (added wgpu.getSurfaceCssSize + js_surface_get_css_size);
    the depth attachment keeps backing px. This also aligns wgpu with the GL
    path's coordinate convention (per claude.md: input + drawing in logical px,
    GPU backing resolution is transparent supersampling).
  - N5e (textured 2D / real setTexture): **DONE** (turn ~890, Chrome-confirmed).
    WgpuGl.setTexture flushes the batch + swaps the material group via
    Renderer2D.resources.set(.texture0, tex) → batch.current_texture_bind_group.
    Free fns: z.rlSetTexture / z.drawTexture / z.drawTextureRec (the glyph-quad
    building block for N5f). Shapes demo draws a scaling checkerboard texture.
    .invalid view resets to the engine white texture (untextured=solid). Smoke
    + lint-check (0/280) green. Unblocks N5f (text: font-atlas upload + glyph
    quads via drawTextureRec) and N6 (rlsw framebuffer upload via createFromPixels).
    Along the way fixed a MULTI-FLUSH BUG (the batch wrote every flush to vbo
    offset 0; queueWriteBuffer lands on the queue timeline before any draw, so
    only the last flush survived — texture/material swaps made >1 flush/frame.
    Fix: append at running byte offsets + draw with base_vertex/first_index,
    reset per frame in beginDrawing). Also: drag-gesture handling (touch-action:
    none + window-level pointermove + touch preventDefault, ported from zimr.ts),
    a viewport meta tag, and **N2's deferred `.fit` scale mode** (fixed design-
    size coordinate space scaled+letterboxed via a baked ortho; f.window +
    input map to design coords; opt-in `.scale_mode = .fit`). The shapes demo
    uses .fit and now looks IDENTICAL across browsers. (Also survived a disk-full
    incident that truncated buildaux.zig — restored from snapshot; lesson: the
    .zig-cache grows unbounded + can fill the disk; clear it periodically.)
  - N5f (text): **DONE** (turn ~892, Chrome-confirmed — title + live frame counter render crisp). Reused the GL text
    stack as-is (drawWithFont/drawCodepoint/drawTexturePro are gl:anytype-
    generic) + bakeFontAtlas (codecs TTF toolkit). Built the bridge: a
    texture-id REGISTRY on Renderer2D (registerTexture/lookupBindGroup), WgpuGl
    trait-conformant setTexture(id:u32) resolving via it (+ bindTexture for the
    direct WgpuTexture path, + normal3f no-op). z.loadFont bakes->uploads as
    WgpuTexture->registers->returns types.Font carrying the id; z.drawText/
    z.measureText route through the reusable layout. Demo draws a title + live
    frame counter. lint-check GREEN (0/280); smoke passes. ORIGINAL SCOPING NOTE
    below confirmed correct. KEY FINDING: the GL
    text stack is ALREADY generic over `gl: anytype` — `drawWithFont` (layout
    loop) -> `drawCodepoint` -> `textures.drawTexturePro(gl, font.texture, ...)`,
    all in drawing.zig, all backend-polymorphic. So the layout + glyph-quad
    emission is REUSABLE as-is via WgpuGl (N5e gave it setTexture + textured
    quads). The gap is narrow: (a) atlas BAKE for the wgpu path — codecs.zig has
    the full reusable TTF toolkit (loadFontFromTtf, glyphBitmap, glyphHMetrics,
    suggestAtlasWidth); pack glyph bitmaps into one R8/RGBA atlas + record recs
    into a `types.Font`; (b) the Font.texture impedance — `types.Font.texture`
    is a GL `types.Texture` (id-based) but WgpuGl draws via WgpuTexture, so
    drawTexturePro's `gl.setTexture(font.texture)` needs WgpuGl to resolve a
    GL-texture-id -> WgpuTexture (a small registry on the renderer, OR adjust
    the Font to carry a WgpuTexture for the wgpu path). Resolve (b) first, then
    bake (a), then `drawWithFont` works unchanged. Gate: FPS counter + label in
    Chrome.
  - N5g (scissor/clip): **DONE** (turn ~894, Chrome-confirmed — checker clipped cleanly). WebGPU
    scissor plumbing (js_render_pass_set_scissor_rect + render_pass.setScissorRect)
    + z.beginScissorMode/endScissorMode: flush, convert logical->backing px
    (DPR + .fit aware), set GPU scissor; end resets to full surface. Demo clips
    the checker. lint-check GREEN (0/280); smoke PASS.
- **N5 COMPLETE** (turn ~894, Chrome-confirmed): the 2D surface +
  ergonomic surface are done — shapes, input (f.input), textured 2D, text,
  scissor, all through the WgpuGl `gl:anytype` adapter, with .responsive/.fit
  scaling. N6 (rlsw||wgpu side-by-side) is next; the texture-id registry +
  createFromPixels (N5e/N5f) is what N6's rlsw-framebuffer upload needs.
- N6 (CPU|GPU side-by-side on wgpu): **IN PROGRESS — GPU half blocked on a spv2wgsl phi bug** (turn ~895) — the
  headline. All building blocks confirmed present + reusable:
    * CPU half: rlsw_shader.dispatchFragmentShader(&ctx, mandelbrot_fs.shaderMain,
      io, ...) is CPU-pure (imports only std/types/rlsw/rlsw_pixel); rlsw.Context
      has colorBufferBytes() for the framebuffer. Upload it as a WgpuTexture
      (createFromPixels / a per-frame update) + drawTexture the left strip — the
      texture-id registry from N5e is exactly this path.
    * GPU half: shader_runtime_wgpu.loadShader(Schema, desc) runs an engine
      _fs.zig's WGSL as a fullscreen pass (the path wgpu_demo used for fractals).
      mandelbrot_fs.zig's shaderMain -> WGSL via the build's ShaderPipeline.
    * Divider: cursor-X (N5d input) + scissor each half (N5g).
  BUILD WORK (the real effort): a new wgpu-mandelbrot-split demo + build block
  that compiles mandelbrot_fs (N4.5 gated it off with the GL examples — wire it
  into the wgpu build independently) + imports mandelbrot_fs_io. Then port the
  GL examples/mandelbrot_split.zig structure (~361 lines) to z.App.run form.
  SUGGESTED ORDER: (1) GPU-only fullscreen mandelbrot rendering first (riskiest
  new piece — the fullscreen-shader pipeline); (2) add the CPU rlsw half +
  per-frame texture upload; (3) divider + pan/zoom. Also un-skip the
  shader_runtime_wgpu 'rasterizes a triangle' test once the SW dispatch path is
  exercised (it's been a documented turn-3 stub).
- N7 (enforce + document the wgpu path): NOT STARTED.
- N8 (bulk-port the example corpus + delete GL): NOT STARTED — the long tail.

(Resolved this session: the Tint-corpus regression — see the RESOLVED section
below; D1/D2 — both decided in N3/N4: parallel z.App + WgpuGl adapter.)

- turn ~883: N4.5 landed (GL quarantine via -Dgl default-off). The tree is now
  WebGPU-only by default and green; GL is preserved behind -Dgl. N5 next.

### Session log
- turn ~875: plan created. Studied `src/web/readme.html` (target API),
  `src/renderer_trait.zig` (the rlgl+rlsw trait + "third adapter" path),
  `examples/mandelbrot_split.zig` (the side-by-side demo, GPU half currently
  WebGL), and raygpu (`/tmp/raygpu`, surface-owns-depth at backend_wgpu.c:830 =
  the structural fix for the depth-size class of bug; BeginDrawing/EndDrawing
  own the surface + RT stack). Confirmed current gaps: GpuFrame doesn't own/
  resize depth; no surface-size query; bridge has no resize/DPR/coord model;
  AppBridge is GL-only. Ordered N1→N7 foundation-first.
- turn ~876: N1 landed. Also cleaned `src/spv2wgsl/sccp.zig` to lint-clean by
  hand (a pre-existing 84-issue file unrelated to N1 that the whole-tree gate
  caught — better names: setValue's `old`->`previous`, evalInst's `r`->
  `result_id` / `wc`->`word_count` / phi `acc`->`merged`, evalTerm's `t`/`f`->
  `true_target`/`false_target`, rewrite's `folded`->`selection_folds`, added
  OP.function/function_end/phi named opcodes; all 16 sccp tests still pass) +
  3 pre-existing fn-multiline issues in tools/buildaux.zig (which I'd touched
  for the on-page logging). Whole-tree lint-check now GREEN.

---

## SCCP-rewrite Tint-corpus regression — RESOLVED (turn ~882)

**FIXED: Tint corpus 89 trans_fail → 0** (170 ok / 0 known-bug / 0 trans_fail /
11 unstructured — better than the Zig-0.16 baseline of 178 ok / 4 known-bug).
The fix follows SPIRV-Tools' `dead_branch_elim_pass.cpp` precisely (studied from
`/home/claude/refs/SPIRV-Tools-main/source/opt/`):

1. **Folded-CFG structural reachability for block-keeping** (`computeFoldedReachable`
   in sccp.zig). The rewrite was dropping blocks using SCCP's constant-prop
   `reachable`, which marks only a folded guard's TAKEN edge — starving blocks
   still reachable via another edge (merge/phi targets) → dangling refs →
   `MalformedFunction`. Now block-survival is decided by a worklist BFS over the
   FOLDED CFG from the entry: a block dies iff ALL its incoming edges are dead.
   This is SPIRV-Tools' `MarkLiveBlocks`. (Fixed ~47 fixtures.)
2. **Back-edge fold exclusion** (`collectBackEdgeBlocks` + `containingLoopHeader`,
   ports of SPIRV-Tools' `AddBlocksWithBackEdge` + the `simplify` gate). A block
   carrying a loop back-edge must NOT have its conditional folded (it would
   destroy the loop's required single back-edge) UNLESS the fold target is the
   loop header. Without this, folding a back-edge produced loops `ir_build`
   couldn't structurize → `IrBuildUnsupported`. (Fixed the last 2 fixtures.)

Root cause was a Zig 0.16→0.17 HashMap-iteration-order change exposing a
latent non-monotonicity in the rewrite (it folded on a transient `.konst` and
under-marked reachability); the SPIRV-Tools approach is order-independent by
construction. The corpus-test baseline was updated (known_bugs 4→0,
unstructured 13→11) to lock in the improved state. All 16 sccp unit tests pass;
all 4 wgpu demos still render (helmet WGSL byte-identical for the
already-correct cases). The investigation history below is kept for reference.

---

## Pre-existing failures surfaced during this arc (investigation history)

Surfaced once the test aggregators compiled again (turn ~880); each predates
this session and is independent of N1–N4. Tracked here so they're not
mis-attributed:

- **Tint corpus: 89/181 `trans_fail`** (`src/tests/spv2wgsl_corpus_test.zig`,
  in `zig build test`). Breakdown: **80× `MalformedFunction` + 9×
  `IrBuildUnsupported`**, all from `ir_build.zig`'s `self.table.get(id) orelse
  return error.MalformedFunction` — the block table is missing expected block
  ids for most Tint functions.

  **ROOT CAUSE (bisected to certainty, turn ~880): the SCCP `rewrite` prepass
  (`sccp.zig`) miscompiles SPIR-V under Zig 0.17.** It is NOT Tint (the fixtures
  are static external `.spv`, and the corpus test never invokes Tint at runtime
  — `MalformedFunction` is `@errorName` of OUR error), NOT Zig-backend SPIR-V
  drift (static input), NOT this session's sccp cleanup (pristine pre-cleanup
  sccp also gives 89), NOT the fixpoint iteration cap (250× the limit → still
  89). **Decisive bisect: bypassing `sccp.rewrite` in `convertSpirvToWgsl`
  (`const folded_spirv = spirv;`) → 0 trans_fail, 164 ok — exactly the
  `known_bugs=4, unstructured=13` baseline.** So `rewrite` produces broken SPIR-V
  (drops live blocks; their ids then miss the block table → `MalformedFunction`
  at `ir_build`'s `table.get(merge_id)`). Further bisect: disabling branch
  FOLDING in `evalTerm` (keep both edges live) drops 89→41, so ~48 failures are
  mis-folded branches (a branch judged `.konst`→one edge marked→the other's
  blocks dropped) and ~41 are a SECOND bug in the phi-pruning / `reachable`
  computation independent of folding.

  Why 0.17: the rewrite + `analyzeFunction` iterate `std.AutoHashMapUnmanaged`
  sets (`reachable`, `folded`, the block table) and 0.17 changed HashMap
  behavior/iteration; the source (`sccp.zig`, `ir_build.zig`, `block_table.zig`)
  is byte-identical from zimr860→now and was **178 ok / 0 trans_fail under Zig
  0.16** (per the spv2wgsl-rewrite changelog). The translator's NON-rewrite path
  is correct (block_table's own unit tests pass; raw-spirv corpus is baseline).

  **The rewrite is NO LONGER load-bearing for the PBR uniformity fix** (that
  moved into the shader restructuring, turn ~867 — see finishing_webgpu.md "no
  longer load-bearing for uniformity"); it's now a pure optimization that fixes
  ~7 internal shaders' phi-overwrite known-bugs. So the FIX options are: (a) make
  the rewrite's folding + phi-pruning correct/order-independent under 0.17 (the
  proper fix — its own arc; iterate blocks in SPIR-V program order via
  `inst_off`, never HashMap order, and audit the `.konst` fold condition), or
  (b) if it stays broken, gate the rewrite off (lose the 7-shader optimization
  but regain 0 trans_fail + the documented fallback `catch spirv` already exists).
  The test correctly fails + must NOT be deleted/masked — it's the canary for
  this real translator bug.

  **Q1/Q2 EMPIRICALLY SETTLED (turn ~881):**
  - **Q2 — can a real/Zig shader trigger the 89?** NO. All 57 raw (pre-spirv-opt)
    Zig-emitted `shader.spv` in the cache — including mandelbrot's
    `while`+double-`break`+post-loop-guard, the rewrite's canonical target —
    translate WITH the rewrite at **57 ok / 0 fail**. Zig's backend emits
    structured CFG the rewrite handles fine. The 89 `MalformedFunction` are
    EXCLUSIVELY Tint's hand-crafted CFG torture fixtures (back-edges re-entering
    multi-block loops, continue-is-header, multi-exit hoisting) — inputs the real
    shader pipeline never produces. So the bug's real-world severity is ~nil; the
    Tint corpus is a structurizer-completeness stress test, not a real-shader gate.
  - **Q1 — does the helmet render with the rewrite BYPASSED?** YES (Chrome-
    confirmed: all 5 PBR maps load, draw fires, no GPU validation error). BUT
    Tint then emits two `code is unreachable` WARNINGS (`pbr3d_fs:635`, `:766`) —
    the dead post-loop-guard blocks from pbr_fs's light `while` loops that the
    rewrite folds away. Warnings (not errors) → WGSL still valid → renders. So the
    rewrite DOES earn its keep on REAL shaders (removes dead code Tint flags + the
    7 internal phi-overwrite known-bugs); bypassing is not free.
  - **NET recommendation:** keep the rewrite ON (current). The proper fix (correct
    the `.konst` fold condition + make `reachable`/phi-pruning order-independent
    under 0.17 so the Tint torture cases pass) is now WELL-SCOPED but LOW-PRIORITY
    — the rewrite is correct for 100% of real + Zig-emitted shaders; only
    adversarial CFGs regress. The corpus test stays as the canary; its 89 are
    documented-expected until that fix lands.
- **`damaged_helmet-check` compile error**: `shader_runtime.zig` `BoundShader`
  wants an `Uniforms` decl but `shaders/pbr_fs_io.zig` defines `Ubo` (a
  rename mismatch). This is a **GL-path** target (uses GL `shader_runtime.zig`).
  Per the plan the GL path is slated for deletion, so this is fixable-by-deletion
  later, not worth chasing now.



**Full reference + decision tree: `src/notes/zig-0.16-migration-guide.md`.**

Most valuable rule: `@floor`/`@ceil`/`@round`/`@trunc` now return
**integer types directly** when the slot is typed as int.  Use
`@floor` as the preferred form for floor-to-int pixel math:

    // before:
    const px: i32 = @intFromFloat(@as(f32, @floatFromInt(int_var)) * scale);
    // after (turn 280):
    const px: i32 = @floor(int_var * scale);

Choose builtin by rounding semantics: `@floor` (toward -∞ —
right for most pixel math), `@trunc`/`@intFromFloat` (toward 0),
`@ceil` (toward +∞), `@round` (nearest, ties away from 0).
Differs on negative values; same for positive.

Other rules:

- `@as(T, @intCast(x))` → `@intCast(x)` in any typed slot.
- `@as(T, @floatFromInt(x))` → `@floatFromInt(x)` ditto.
- Implicit `int → f32` ONLY for lossless widths (i16/u8/u16).
  i32/usize/i64 still need `@floatFromInt`.
- Binary ops `* + - /` do NOT propagate result-location to operands.
- Wrapping the expression in `@floor`/`@intFromFloat`/`@sqrt` DOES
  propagate f32 inward, so `@floor(int_var * scale)` works for
  any int width.

Mass sweep filed as plan v3 steps 4.4 / 4.5.  Clean incrementally
(every line you touch), no mass sed.



## N6 GPU-half debugging (turn ~895) — root-caused to a spv2wgsl phi bug

Built the GPU fullscreen-mandelbrot half (new z.bindFullscreenShader +
drawFullscreenTriangle helpers; wgpu-mandelbrot-split demo + build block that
compiles mandelbrot_fs explicitly via addShaderEx since -Dgl gates the
compiled_shaders map). Methodical on-page-diagnostic isolation fixed/ruled out,
in order:
  1. UBO @group mismatch: loadShader put the UBO bind group at index 0, but the
     engine emits FS uniforms at @group(2). FIXED: loadShader now places the UBO
     layout at a configurable `ubo_group` (default 2), padding lower groups with
     empty bind-group layouts; bindForDraw binds at ubo_group. (matches pbr3d.)
  2. VS<->FS interface mismatch: mandelbrot FS Inputs declared frag_color (loc 1)
     which it never reads + the fullscreen VS doesn't output. FIXED: removed the
     unused frag_color from mandelbrot_fs_io.Inputs (an FS must only declare
     varyings it consumes).
  3-6 (ruled out via on-page debug outputs): pipeline handle valid (=1), UBO
     bind group valid (=1, group 2), pipeline switch confirmed (shapes=2 ->
     mandelbrot=1 before draw), UVs flow correctly (clean R=u/G=v gradient), UBO
     data correct (resolution=800, zoom, center all decode right).

** THE REMAINING BUG (spv2wgsl phi mis-emission) **
The grayscale-iteration debug showed n=0 everywhere (loop body never runs).
Inspecting the produced mandelbrot FS WGSL loop: a selection-merge phi inside
the loop-with-conditional-break is emitted with a MISMATCHED id — the branches
assign `phi335 = ...` but the consumer reads `phi337 == 168u` (phi337 is never
assigned). So the guard on the z-step + n++ body is always false -> z stays 0,
n stays 0, never escapes -> white (NaN in the color path) / black (in the
n-debug). This is in the IR phi-lowering (src/spv2wgsl/ir_build.zig + ir.zig;
block_table.zig:433 already documents "the phi-overwrite bug" for the
loop+conditional-break shape, but this specific phi still mis-numbers). The
write-side phi_id and the read-side phi_id diverge (off by 2). NEXT: trace
ir_build.zig's OpPhi result-id vs the selection-merge result phi_id; the
read-side must reference the SAME phi{phi_id} the predecessor assignments write.

** "MAKE IT IMPOSSIBLE" (Simon's ask) — two layers **
  (a) The interface bug (#2) should be a COMPILE ERROR: make loadShader take
      BOTH the VS and FS schema (loadShader(VsSchema, FsSchema, ...)) and add a
      comptime assertion in shader_introspect that VsSchema.Outputs matches
      FsSchema.Inputs (same field names/types/order -> same @location). A
      mismatch -> @compileError. Same spirit as the gl_iface comptime trait check.
  (b) The phi bug (#the remaining one) is a translator correctness bug; the
      durable guard is a corpus fixture that reproduces THIS exact shape (loop
      body with a selection-merge phi consumed after a conditional break that
      exits the loop) + a WGSL self-check that every read `phiN` has a
      corresponding assignment (a cheap lint on the emitted WGSL: no phi var is
      read-before-any-write). That self-check would have caught this immediately.

Demo state: wgpu-mandelbrot-split builds + smokes; renders white pending the
phi fix. All debug instrumentation removed; FS + io restored clean. lint GREEN.


## N6 phi-bug: DEEP-DIVE + MINIMAL REPRODUCER (turn ~896)

Studied Dawn/Tint's canonical phi model (refs/tint/dawn-main, extracted from the
uploaded dawn-main zip): docs/tint/spirv-reader-overview.md "Hoisting and phis"
+ src/tint/lang/spirv/reader/parser/parser.cc (EmitPhi / EmitPhiInIfMerge /
EmitPhiInLoop*). TINT'S RULE: a phi is keyed strictly on inst.result_id()
everywhere — predecessor exit-args AND the consuming read both reference the
SAME id (AddValue(result_id, ...) / block_phi_values_[block]). Tint never
renames; the write-side and read-side ids are identical by construction. zimr's
bug is exactly a divergence of those two ids.

MINIMAL REPRODUCER (fast iteration, ~5s, no full build):
  tests/fixtures/phi_repro/loop_fs.zig — a fragment shader with a loop having
  TWO sequential conditional breaks, the second setting a flag (escaped=1). This
  is the minimal shape that triggers the bug (ONE break does NOT). Pipeline:
    /tmp/phirepro/: gen_externs (builds loop_fs_externs.zig via gen_shader_externs)
    -> zig build-obj -target spirv32-vulkan ... -> loop.spv
    -> spirv-opt -O --skip-validation -> loop.opt.spv
    -> drive (calls spv2wgsl.convertSpirvToWgsl) -> loop.wgsl
  (the gen_externs.zig + drive.zig drivers are in /tmp/phirepro; rebuild via the
  build-obj/build-exe invocations recorded in the turn-896 transcript.)

THE BUG (exact): the produced loop.wgsl has a phi declared+READ but NEVER
WRITTEN (phi559 in the repro; phi337 in mandelbrot). The final post-loop merge
computes the return color into `_578 = vec4(phi550,phi550,phi550,1.0)` but then
emits `out_color = phi559;` — phi559 is the OpPhi result id whose incoming value
IS _578, but its assignment (`phi559 = _578`) is DROPPED, so the read is an
orphan -> garbage -> white. It's a SINGLE-predecessor merge phi after the loop:
the exit-arg assignment for that phi isn't emitted on its one real predecessor.

FIX LOCUS: ir_build.zig merge-phi exit-arg attachment (attachExitArg /
emitPhiAssigns path) for the post-loop merge with a single live predecessor —
the phi's incoming value must be assigned to phi{phi_id} on that predecessor (or
the read resolved directly to the value). Compare to tint's parser.cc which
always pairs result_id with its predecessor value.

GUARD (make it impossible — Simon's ask): wgsl_check.zig already has a phi check
but it ONLY catches the "phi-overwrite" shape (phiN= right after a }). ADD a
second, simpler check: every `phiN` that is READ must have at least one
`phiN =` assignment somewhere (no read-before-any-write). That cheap check
catches THIS bug class immediately. (Reproducer's loop.wgsl: 18 written, 19
declared -> phi559 orphan; the check would flag it.)

ALSO STILL TODO from turn 895: the comptime VS<->FS interface check in
shader_introspect (loadShader takes both schemas, asserts Outputs==Inputs).


## N6 phi-bug: FIXED (turn ~897)

ROOT CAUSE (confirmed via the minimal reproducer + Tint study): spirv-opt wraps
the shader body in a degenerate CASE-LESS OpSwitch (selector=constant, only a
default target, word_count==3) with OpSelectionMerge at a block holding the
function's return-value OpPhi. SCCP correctly folds the constant-selector
switch and DROPS its OpSelectionMerge — but the merge-phi survives, and because
a case-less switch's merge is still a multi-pred join (the body branches
internally and rejoins there), the phi is left ORPHANED (read with no
assignment) -> garbage -> white.

FIX (src/spv2wgsl/sccp.zig): in the fold-collection loop, SKIP the fold for a
degenerate case-less switch (switchIsCaseless: OpSwitch wc==3) whose merge block
carries an OpPhi (mergeBlockHasPhi). The harmless wrapper switch then survives
and buildSwitch lowers it + its merge-phi correctly. Crucially NARROW: a switch
WITH cases, or a conditional branch, folds by killing branches (which DOES
collapse the merge), so those folds are unaffected. Mirrors Tint's invariant
(a phi is lowered by its result id regardless of construct survival).

REGRESSION HISTORY: a first, too-broad guard ("skip fold whenever merge has a
phi") regressed phi_Phi_Switch_FromIfBreak (170->169 ok, a phi-overwrite) — that
fixture's switch HAS cases and folds fine. The case-less discriminator fixes the
orphan without touching it. Verified: tint corpus back to 170 ok / 0 known-bug;
zig build test exits 0; lint-check 0/281.

GUARD (make it impossible): added wgsl_check.BugScan.phi_read_before_write +
countPhiReadBeforeWrite — counts phiN that are read but never assigned. Kept OUT
of total()/the corpus gate (the hand-crafted phi_Phi_* fixtures legitimately
emit tolerated one-incoming orphans), so it's a targeted diagnostic for ENGINE
shaders. The minimal reproducer (tests/fixtures/phi_repro + /tmp/phirepro/run.sh)
+ this detector give a fast regression signal.

VERIFIED on the real shader: the mandelbrot FS WGSL is now orphan-free; the
wgpu-mandelbrot-split demo builds + smokes; standalone presented for Chrome.
STILL TODO: confirm the fractal renders in Chrome; then N6 CPU half + divider;
the comptime VS<->FS interface check (from turn 895) remains a separate item.


## N6 phi-bug: PARTIAL FIX — real input identified (turn ~898)

The turn-897 SCCP fix (switchIsCaseless guard) is CORRECT for post-spirv-opt
input (my minimal reproducer + mfs.opt.spv → clean). BUT the demo STILL renders
white because of a pipeline detail I missed:

** THE WGSL PATH FEEDS RAW (UN-SPIRV-OPT'D) SPIR-V **
shader_codegen.zig addShaderEx, Stage 6: the WGSL branch deliberately feeds
`rewritten_spv` (the pure-Zig zspv output, PRE-spirv-opt) straight into spv2wgsl
— NO spirv-opt, NO C++ tools (architecture Rule 2: no Naga/Tint/spirv-opt in the
WGSL shipping path; "spv2wgsl is hardened to consume raw, unoptimized Zig
SPIR-V"). The GLSL path uses opt_spv; WGSL does NOT.

CONSEQUENCE: the degenerate switch in the RAW spv has a different shape than in
the post-opt spv. My switchIsCaseless guard (OpSwitch word_count==3) matches the
POST-OPT form but NOT the raw form, so the orphan (phi337 + ~12 others) survives
in the demo's actual WGSL.

PROOF / REAL REPRODUCER (saved): tests/fixtures/phi_repro/demo_mandel_raw.spv is
the demo's actual 34KB raw zspv SPIR-V.
  spv2wgsl --walker=ir demo_mandel_raw.spv  → orphans phi337,phi387,... (BUG)
  spirv-opt -O ... demo_mandel_raw.spv | spv2wgsl  → NONE (clean — confirms the
    fix logic is right, just keyed on the wrong/optimized shape)

NEXT (the actual fix): debug the RAW switch shape in demo_mandel_raw.spv (dump
its entry OpSwitch + merge OpPhi) and broaden the sccp guard to recognize the
degenerate-wrapper switch in raw form too (it may have cases that all target the
same/merge, or a different word_count). Do NOT route WGSL through opt_spv — that
violates the no-C++-tools rule. Iterate via:
  /tmp/phirepro: spv2wgsl --walker=ir demo_mandel.spv out.wgsl + the orphan
  python check. The 34KB raw spv is the input that matters.
The wgsl_check phi_read_before_write guard already catches this at the symptom.


## N6 phi-bug: FIXED in the real build (turn ~899)

The orphan was on the RAW (no-spirv-opt) WGSL path, exactly as the architecture
intends (spv2wgsl consumes raw Zig SPIR-V; no C++ tools). Root cause: SCCP folds
constant-condition selections inside the mandelbrot escape loop and drops their
OpSelectionMerge, but the merge OpPhis survive → orphaned `phiN` reads → white.

FINAL FIX (sccp.zig): the fold-collection loop SKIPS folding ANY selection/switch
whose merge block carries an OpPhi (mergeBlockHasPhi). The un-folded guard is
harmless (buildIf/buildSwitch lower it + its merge-phi normally). Tried a narrow
case-less-switch guard and a merge-is-header guard — both left residual orphans
(the loop has many nested folded selections whose merge-phis cascade). The broad
guard is the correct, robust rule (mirrors Tint: a phi is lowered by its result
id regardless of construct survival).

TRADEOFF: one Tint torture fixture (phi_Phi_Switch_FromIfBreak) is no longer
folded; its WGSL is CORRECT + orphan-free, but the conservative
phi-overwrite-after-if detector flags a benign nested `phiN =`. Bumped
tint_corpus baseline known_bugs 0→1 to account for that single detector
false-positive. Real shaders are unaffected.

VERIFIED: mandelbrot raw spv (tests/fixtures/phi_repro/demo_mandel_raw.spv) →
spv2wgsl → orphans NONE; demo WGSL artifact orphan-free; zig build test exits 0
(corpus 170 ok / 1 known-bug); lint 0; demo builds + smokes; standalone presented.
GOTCHA for future: grep -c 'phi337' on the wasm is NOT an orphan check — phi337
legitimately appears (decl+assign+read); use the read-before-write check.
Also: the WGSL build cache keys on the spv2wgsl_exe artifact hash; editing
src/spv2wgsl/*.zig + a clean main .zig-cache regenerates it.

** N6 status: GPU half DONE. ** Next: CPU rlsw half + divider (mechanical, uses
the texture-id registry + scissor already built). Plus the comptime VS<->FS
interface check (from turn 895) is still a separate open item.


## N6 mandelbrot WHITE — root-caused via step-back experiments (turn ~901)

After the phi-orphan fix (WGSL is naga-valid + orphan-free), mandelbrot STILL
rendered white. Systematic step-back isolation (each as a solid/gradient color
on the SAME pipeline) RULED OUT everything except the loop's complex math:
  - UV passthrough -> clean gradient (varyings interpolate per-pixel) OK
  - white disk in UV center -> renders (float math + branching + coord map) OK
  - UBO as color -> pale yellow = resolution(800,600), zoom 1.2 ALL CORRECT
  - computed `c` as color -> clean gradient (center/scale/coord math) OK
  - **scalar loop** (acc*0.99+0.01 x10) then solid color -> PURPLE (loops work!)
  - **loop with cmandelbrot_step** then solid purple (ignoring result) -> WHITE
    + Chrome/Tint warns: "code is unreachable" in the shader.

** ROOT CAUSE: a loop containing cmandelbrot_step/cmul produces an UNREACHABLE
post-loop block (the color computation). ** The color `return` is gated behind a
cascade of loop-exit-STATE-CODE phi guards (phi400==145u, phi384==153u, ...) —
the state-machine SCCP emits for the loop's exit paths. One guard is provably
constant-false, so Tint marks the color block unreachable + may eliminate it →
out_color never set on the live path → white. naga (our build oracle) does NOT
flag this (it accepts unreachable code); only Tint/Chrome does. This is EXACTLY
the "dead post-loop guard" the finishing_webgpu plan names as the SCCP keystone
(the same class as the PBR `textureSampleLevel` interim).

THE FIX (the SCCP keystone, finishing_webgpu §1): SCCP must prove the
loop-exit-code phis constant and FOLD those guards, so the color block becomes
reachable. The earlier SCCP work folded SELECTION guards; this needs folding
guards whose condition is a LOOP-CARRIED phi resolved to a constant (sparse
conditional const-prop THROUGH the loop). Reference: SPIRV-Tools SCCP /
dead_branch_elim; the value is a loop-exit code that's actually a single constant.

REPRODUCER: tests/fixtures/phi_repro/demo_mandel_raw.spv; spv2wgsl --walker=ir
on it → grep for `unreachable` is wrong (naga won't emit it); instead check that
the color `return` (out.field_0 = <hsv color>) is on a reachable path, OR run
the WGSL through Tint. The minimal trigger: ANY loop body calling cmul/
cmandelbrot_step (scalar loops are fine). Confirmed both the multi-break original
AND a break-free fixed-trip loop hit it — so it's the complex-math-in-loop +
exit-code-phi-guard shape, not the break per se.

GOTCHA: naga "Validation successful" is necessary but NOT sufficient — naga
tolerates unreachable code that Tint (Chrome's compiler) eliminates. Need a Tint
oracle or a reachability self-check for the color/return block.


## N6 mandelbrot: RENDERS — root cause was f32 OVERFLOW, not control flow (turn ~902)

THE COLORED MANDELBROT RENDERS on the pure-Zig no-spirv-opt WGSL pipeline (120fps,
GPU). The entire white saga came down to ONE thing: **f32 overflow → NaN.**

ROOT CAUSE: escape radius² was 256 (|z|>16). On the set boundary, squaring in
cmandelbrot_step (cmul(z,z)) let z grow until it OVERFLOWED f32 to `inf`. Then
`inf*inf - inf*inf = NaN`. The escape test `cnorm2(z) > 256.0` with z=NaN is
FALSE (NaN compares false), so escape NEVER fired → the loop ran to max_iter
carrying NaN → NaN poisoned out_color → the whole pixel rendered WHITE.

FIX (examples/mandelbrot_fs.zig): escape radius² 256 → 128 (|z|>~11.3). Keeps
every cmul intermediate finite (squaring ~11 → ~128, next → ~16384, nowhere
near f32 max 3.4e38) while staying large enough for the log-log smooth-iteration
coloring to look right. Two-character change. lint 0, zig build test 0, smoke
PASSED, Chrome renders the colored fractal.

EVERYTHING ELSE WAS CORRECT ALL ALONG: the phi-orphan SCCP fix (turns 897-899),
the loop control flow, OpFunctionCall-in-loop, the UBO/coord math, the bindings.
Proven by a step-back coloring walk (Simon's idea): UV passthrough (gradient OK)
-> disk (OK) -> UBO-as-color (res 800x600, zoom 1.2 OK) -> c-as-color (gradient
OK) -> scalar loop (purple OK) -> single cmul call (red disk OK) -> scalar-break
loop (fractal OK) -> shrink-call-in-loop (OK) -> early-escape cmul-in-loop
(MANDELBROT). Each step colored a layer; the walk led straight to the NaN.

RED HERRING: the Tint "code is unreachable" warning (wgsl:...:NNN) is BENIGN —
it's emitted even now while rendering perfectly. It is NOT the cause of white.
Do not chase it. (naga doesn't emit it; Tint does; neither blocks rendering.)

** N6 GPU HALF: DONE. ** Remaining N6: CPU rlsw half + the divider (mechanical,
reuse texture-id registry + scissor). Open item from turn 895: comptime VS<->FS
interface check in loadShader. The phi-orphan fix + wgsl_check guard + corpus
baseline (known_bugs=1 for the FromIfBreak detector false-positive) all stand.


## N6 COMPLETE: CPU|GPU mandelbrot split renders seamlessly (turn ~903)

The headline demo works: examples/wgpu_mandelbrot_split renders the mandelbrot
TWICE in one frame — CPU (rlsw software rasterizer, shaderMain dispatched per
pixel) on the LEFT of a centered divider, GPU (SPIR-V→WGSL fullscreen) on the
RIGHT — and they are pixel-for-pixel SEAMLESS across the divider. That validates
the entire pure-Zig no-spirv-opt pipeline against the hardware path.

Build: zig build wgpu-mandelbrot-split[-standalone]. lint 0, zig build test 0,
smoke PASSED.

KEY BUGS FOUND + FIXED THIS SESSION (all in examples/wgpu_mandelbrot_split + the
zimr_wgpu exports):
1. **f32 overflow → NaN → white** (the big one, turn 902): escape radius 256 let
   cmul(z,z) overflow to inf → inf−inf = NaN → `NaN>256` false → escape never
   fired → white. Fix: escape radius² 128. (in examples/mandelbrot_fs.zig)
2. **z.App.run ZERO-INITS State** — the struct-default field values (center=-0.5,
   zoom=1.2) are NOT applied. Earlier versions only worked because update()
   reassigned s.zoom every frame; a static view left zoom=0 → scale=4/(0*h)=inf
   → black. Fix: set center/zoom explicitly in initState. (GENERAL GOTCHA for all
   wgpu examples.)
3. **CPU-half squish**: dispatching the rlsw fragment shader over a PARTIAL width
   (left strip only) fills columns 0..N with frag_tex_coord for 0..N/W — the left
   fraction of the image, squeezed. Fix: dispatch the FULL canvas width so the
   texture is a 1:1 screen copy; sample its left half for the split.
4. Added exports to src/zimr_wgpu.zig: rlsw, rlsw_shader, math (= the zm module,
   NOT @import("zimrmath.zig") which double-claims the file). build.zig wires the
   generated mandelbrot_fs_externs module into the CPU-side @import for dispatch.

The CPU half re-uploads its color buffer each frame via wgpu.queueWriteTexture
into a copy_dst WgpuTexture created once in initState; drawn with drawTextureRec
(left-half source UVs → left dest rect) + a 2px divider via drawRectangle.

UNREACHABLE WARNING: Tint's "code is unreachable" warning is present in EVERY
rendering build (cosmetic, from the no-spirv-opt dead post-loop guard). Accepted
as a known cosmetic cost of the no-C++-tools WGSL path. Eliminating it = the SCCP
keystone follow-up (fold the constant loop-exit-code guards).

KNOWN LIMITATIONS / FOLLOW-UPS (not blocking):
- CPU half is ~3-12 fps (480K px × ≤256 iters, single wasm thread, full width).
  Could dispatch only left half with CORRECT coords (offset frag_tex_coord), or
  drop CPU max_iter, or render at lower res + upscale.
- Divider is FIXED at center; gestures (drag-pan, pinch-zoom) deferred — naive
  mouse-drag/wheel reuse got polluted by mobile scroll events (center flew to
  ~5e12, zoom went negative). Proper fix = plumb touch points through the bridge
  (one-finger pan, two-finger pinch) rather than reusing mouse/wheel.

** STATUS: N1-N6 COMPLETE. ** Open items: (a) the comptime VS<->FS interface
check in loadShader (turn 895); (b) N7 enforce+document; (c) N8 bulk-port +
delete the GL path; (d) optional: SCCP keystone (fold loop-exit-code guards →
removes the unreachable warning + tidies WGSL), pinch-zoom gestures, CPU-half perf.


## VS↔FS varying check — DONE (turn ~903, the turn-895 open item)

Closed the long-standing "make VS/FS interface mismatch impossible" item. After
brainstorming a shared-Varyings-file approach (rejected: the shared file gets
claimed by multiple modules → the "file in two modules" hazard, plus per-shader
build wiring), went with the comptime check.

ADDED: `shader_introspect.assertVaryingsMatch(VsSchema, FsSchema)` — comptime,
asserts VS.Outputs == FS.Inputs field-for-field (name, type, ORDER). Field order
IS the @location assignment (gen_shader_externs emits `_location_{name} = field
index` for both Outputs and Inputs), so an equal field list guarantees matching
locations + a valid VS→FS link. Both-empty (fullscreen VS / no-varying FS) is OK.

ADDED: `shader.loadShaderVF(comptime VsSchema, comptime FsSchema, desc)` — like
loadShader but runs the assertion first, then delegates. The VS schema is a
comptime PARAMETER, not a ShaderDesc field: a struct holding a `type` becomes
comptime-only, which would force the whole desc literal (incl. runtime f/gpa) to
be comptime-known (tried it, got "unable to resolve comptime value").

WIRED: examples/wgpu_mandelbrot_split now calls loadShaderVF(trivial_vs_io,
mandelbrot_fs_io, ...); build.zig wires the wgpu_trivial_vs_io.zig module for it.

VERIFIED: injecting the exact N6 bug (frag_color in FS.Inputs the VS never
outputs) now produces a clear COMPILE error: "VS↔FS varying mismatch: VS
`wgpu_trivial_vs_io` outputs 1 varying(s) but FS `mandelbrot_fs_io` reads 2..."
— caught at the call site instead of silent GPU draw-time rejection. Two
positive unit tests in shader_introspect (matching pair; both-empty). lint 0.

ALSO (turn ~903): corpus baseline tint_corpus_unstructured 11→12. The turn-898
merge-phi fold-guard (the mandelbrot fix) leaves one extra loop/phi CFG-torture
fixture un-foldable → unstructured fallback (hard-errors loudly, count-gated, not
silent — not a real-shader shape). The baseline was stale from before that guard;
now reconciled. zig build test exit 0 (168 ok / 1 known-bug / 12 unstructured).

NEXT (from the plan): N7 enforce+document, then N8 bulk-port + delete the GL/C++
path. Optional: SCCP keystone (fold loop-exit-code guards → removes the cosmetic
"unreachable" warning AND would likely recover some of those unstructured
fallbacks), pinch-zoom gestures, CPU-half perf.


## SCCP keystone — INVESTIGATED, DEFERRED (turn ~904)

Attempted the "fold loop-exit-code guards → remove the cosmetic Tint 'unreachable'
warning + recover unstructured fallbacks" keystone. Findings:

1. The Tint "unreachable" warning is NOT a dead-BRANCH from an unfolded guard — it
   traces to a structurally-dead `return S165()` fall-through + dead VALUE
   computations (e.g. `let _418 = 286u == 286u;` computed-but-unused). SCCP
   already FOLDS these tautologies in its lattice (cmp(konst,konst)) and records
   constant-true BranchConditionals in `folded`. The warning persists because the
   dead code is downstream of the structured-CFG lowering, not a foldable guard.

2. The turn-898 `mergeBlockHasPhi` fold-guard is LOAD-BEARING for the RAW
   (no-spirv-opt) path the demo uses. A/B test: removing it made the OPT'd corpus
   path strictly better (internal 8 ok/0 known-bug, tint 169 ok/0 known-bug) BUT
   reintroduced orphans on the RAW path → would break the live mandelbrot demo
   (whose wasm is currently orphan-free, 34/34 phi written). So the guard CANNOT
   be removed; the corpus "improvement" measured the opt'd path, not the raw path.
   The raw-vs-opt split is the same one from the N6 white saga.

3. Verified the SHIPPING demo wasm is orphan-free (ground truth). /tmp/phirepro/
   mfs.spv is a STALE artifact from an earlier session — do NOT trust it; rebuild
   from examples/mandelbrot_fs.zig or check the wasm directly.

DECISION: deferred. The warning is cosmetic (every rendering build has it; naga +
Chrome both run the shader correctly). Removing it safely needs the raw SPIR-V to
match spirv-opt's structure (un-inline + dead-block-elim), which is large and
risky — poor risk/reward vs. destabilizing a working pipeline. The clean
long-term path is the same as finishing_webgpu §1's deeper SCCP, but it's
genuinely hard and NOT worth blocking N8 on.

Corpus baseline unchanged: 168 ok / 1 known-bug / 12 unstructured, zig build test 0.
Moving on to N8 (bulk-port examples + delete the GL/C++ shader path).


## N8 progress: wgpu-julia ported (turn ~904)

First fresh GL→WGPU example port toward N8 (shrink the GL shader surface). Added
examples/wgpu_julia/ — the Julia set as a GPU-fullscreen fragment-shader demo,
sibling of the mandelbrot GPU half, with animated julia_c (morphs the fractal).
Build: zig build wgpu-julia[-standalone]. Smoke PASSED, WGSL orphan-free +
naga-valid, lint 0, corpus 0.

It exercised every lesson from this session on a NEW shader:
- loadShaderVF (the new VS↔FS check) would have rejected julia_fs_io.Inputs'
  spurious `frag_color` (a varying the trivial VS never outputs) — removed it.
- f32 overflow: julia had the same escape-radius-256 → NaN → white bug as
  mandelbrot. Fixed julia_fs escape radius 256 → 128.

BUILD WIRING NOTE (for the next port): compiled_shaders.get(name) only has
shaders a BUILT example references — a brand-new wgpu demo must compile its
shaders EXPLICITLY via shader_pipeline.addShaderEx (like the msplit block does),
not rely on the map. The per-demo module wiring (FS io + FS externs + VS io +
the two WGSL @embedFiles) follows the msplit template.

N8 STATUS: ~12 GL examples use custom shaders (the ones keeping spirv-cross
alive); several already have WGPU twins (cube_split→wgpu_cube_demo,
mandelbrot[_split]→wgpu_mandelbrot_split, julia→wgpu_julia NEW). Remaining
shader examples: mandel_julia, instancing, shader, shader_chroma_split,
shader_uniforms, typed_unlit_demo, sampler_derisk_test, damaged_helmet (PBR).
The FULL C++-tool deletion is still blocked on (a) the SCCP keystone and (b)
full GL-renderer retirement (src/rlgl.zig / render.zig @embedFile the .glsl) —
both large. Each port shrinks the surface; deletion comes when nothing builds
against spirv-cross/spirv-opt.


## The Tint "unreachable" warning — DEFERRED, with a concrete fix plan (turn ~905)

Every escape-loop fragment shader (mandelbrot, julia, mandel_julia) renders
correctly but Chrome's Tint emits one cosmetic `code is unreachable` warning
(e.g. `[wgsl:julia_gpu:376:9]`). It does NOT affect output — naga validates, the
GPU runs it, the fractal is pixel-perfect. naga does not emit it; only Tint does.
Deferred because the fix is non-trivial and the warning is harmless.

WHAT IT IS (confirmed turn ~904): NOT a dead foldable guard. It's structurally-
dead code DOWNSTREAM of the structured-CFG lowering — a `return S165()`
fall-through after a cascade of nested if/else that all return earlier, plus
computed-but-unused tautology values (`let _N = 286u == 286u;`). SCCP already
const-folds the tautologies in its lattice, but the dead fall-through block
survives because the IR→WGSL emitter emits a final `return default` after every
structured construct even when all paths above it already returned.

WHY IT'S HARD: the turn-898 mergeBlockHasPhi fold-guard (which fixes the
escape-loop orphaned phis on the RAW no-spirv-opt path the demos use) is
LOAD-BEARING — removing it reintroduces white. So we can't just "fold more." The
dead code is a consequence of preserving the un-folded structured CFG that the
guard keeps intact for phi-correctness.

CONCRETE FIX OPTIONS (for the day we do this):
  (A) **Emitter-level dead-tail elimination (LOWEST RISK, recommended first):**
      in ir_emit.zig, after emitting a structured region, if every branch of the
      preceding if/switch provably ends in `return`, DROP the trailing
      `return <default>;`. This is a pure WGSL-emit cleanup — it doesn't touch
      SCCP, the IR, or the fold-guard, so it can't reintroduce the phi bug. It
      targets exactly the `return S165()` Tint flags. Verify: the warning
      disappears, mandelbrot/julia still render, corpus unchanged.
  (B) **Dead-value pruning:** stop emitting `let _N = K == K;` when the result is
      unused (the tautology comparisons). Cosmetic; reduces noise but the real
      unreachable is the fall-through (A).
  (C) **The deep SCCP keystone:** const-prop the loop-exit-code phis THROUGH the
      loop so the post-loop dispatch collapses. Highest value (also recovers the
      12 unstructured fallbacks) but highest risk — this is what nearly regressed
      the corpus. Do (A) first; only attempt (C) with the full corpus + every
      wgpu demo as the gate.
  (D) **Add a wgsl_check lint** for "code after a block where all paths return"
      so the emitter change in (A) is regression-tested.

RECOMMENDATION: (A) + (D) is a small, safe, well-scoped task that likely kills
the warning entirely without touching the risky SCCP/fold machinery. Saved for a
focused turn.


## N8 progress: wgpu-mandel-julia ported (turn ~905)

Added examples/wgpu_mandel_julia/ — the Mandelbrot↔Julia morph (uniform `t`
oscillates 0↔1, interpolating z/c between the mandelbrot and julia iterations).
Build: zig build wgpu-mandel-julia[-standalone]. Smoke PASSED, lint 0, corpus 0.
Same two fixes applied (removed spurious frag_color from Inputs; escape 256→128).

THREE fractal fragment-shader demos now ported & rendering on the pure-Zig
WebGPU pipeline: wgpu_mandelbrot_split (CPU|GPU), wgpu_julia, wgpu_mandel_julia.
All three are pure-computation FS (no texture input) — the cleanest port class,
and they all share the trivial fullscreen VS + loadShaderVF check.

REMAINING shader examples to port (all need MORE than fullscreen-compute, so each
is a bigger task than the fractals):
- shader / shader_chroma_split: chromatic-aberration POST-PROCESS — needs an
  offscreen render target + a texture Sampler in the FS. (shader_chroma_fs is
  already in the wgpu_demo_shaders WGSL-build list.)
- shader_uniforms: custom-uniform demo.
- instancing: needs instanced draw (the OpTypeArray-vs-OpTypeMatrix vertex-attr
  issue from the early plan may bite here).
- typed_unlit_demo: typed unlit pipeline.
- damaged_helmet: full PBR GLTF (the plan's item 4 — shadows + real textures).
- sampler_derisk_test: sampler-binding stress.

PORT RECIPE (proven 3×, for the next one):
1. Fix the FS io: remove any varying the trivial VS doesn't output (frag_color);
   if it's an escape loop, set escape radius² ≤ 128 (overflow guard).
2. Create examples/wgpu_<name>/wgpu_<name>.zig (copy wgpu_julia, swap shader +
   UBO push). Use loadShaderVF(trivial_vs_io, fs_io, ...).
3. Copy + retarget index.html (fix the .wasm fetch name + title).
4. build.zig: copy the wgpu-julia block, swap names; compile the FS + trivial VS
   EXPLICITLY via addShaderEx (NOT compiled_shaders.get — only has
   example-referenced shaders). Wire FS io + FS externs + VS io modules.
5. Verify: build, smoke (--frames=8), WGSL orphan-free + naga-valid, lint, corpus.

The C++-tool deletion still gates on full GL-renderer retirement + SCCP keystone;
each port shrinks the surface.


## THE CONVERGENCE: zimr_wgpu → becomes → zimr (turn ~906, MULTI-SESSION)

GOAL: bring every zimr feature into zimr_wgpu, delete the GL `zimr`, rename
zimr_wgpu to zimr. Context: src/web/readme.html maps the full surface (raylib-like
API + ImGui ui + entities ECS + physics + scene/render PBR + rlsw + audio +
codecs). zimr.zig exports ~1132 symbols; zimr_wgpu had 62.

KEY ARCHITECTURAL INSIGHT (the thing that makes this tractable): zimr.zig is a
THIN re-export composition over sub-modules, and MOST sub-modules are BACKEND-
AGNOSTIC (zero GL). The work is NOT reimplementing 1132 symbols — it's
(a) re-export the agnostic modules (cheap), (b) provide WGPU backends only for
the GL-coupled few.

MODULE CLASSIFICATION (verified by grepping each for rlgl/gl/gpu.zig imports):
  AGNOSTIC (re-export verbatim — done or trivial):
    types, easings, entities/ecs, physics, codecs (png/jpeg/truetype/gltf/audio),
    rlsw, rlsw_shader, sound, web (dom/audio/fetch), uniform_buffer, utils, math.
  GL-COUPLED (need WGPU equivalent — the real work):
    drawing + runtime  → ALREADY reimplemented as zimr_wgpu's App/Frame/
      beginDrawing/shapes/text. Largely done.
    gl_iface + gpu.zig → replaced by gpu_iface.zig + wgpu.zig (zimr_wgpu has these)
    ui (ImGui)         → couples to drawing/rlgl. THE BIGGEST genuinely-new port.
    scene + render     → the PBR scene-graph renderer. wgpu_pbr_demo proves the
      pipeline; scene/render need a WGPU resource backend.

DONE THIS TURN (turn ~906): re-exported the agnostic core from zimr_wgpu
(types[112], easings[25], entities/ecs[27], physics[6], sound[7], web[4],
uniform_buffer[2], utils[4]; codecs/rlsw/rlsw_shader/math already there). ~250+
symbols now reachable, lint 0, wgpu-julia smoke PASSED, NO module-graph conflict
(relative imports compile into zimr_wgpu's module; only reach out to wired `zm`).

MIGRATION ORDER (dependency-driven):
  1. [DONE] agnostic-core re-exports.
  2. Audit zimr_wgpu's reimplemented drawing/runtime surface vs zimr's: alias or
     converge duplicates (shapes/text/input/window). Fill gaps (Color, Image,
     PixelFormat, isKeyDown, Camera/Camera2D/Camera3D, gpu resource API
     equivalents that examples like the raytracer need).
  3. Port `ui` (ImGui): point its draw backend at gpu_iface/gl_iface TRAIT (the
     same trick that made N5 shapes/text reusable) so ui becomes backend-agnostic
     and ports ONCE. THE LINCHPIN.
  4. Port scene + render (PBR renderer) onto the WGPU resource backend.
  5. Bulk-port remaining examples (they then 'just work' on zimr_wgpu).
  6. Delete the GL backend (rlgl/gl/gl_iface/gpu.zig + the .glsl shaders +
     spirv-cross/spirv-opt prebuilts) and rename zimr_wgpu → zimr.

IMPROVEMENT OPPORTUNITIES (flagged for Simon):
  A. Make the agnostic/backend split EXPLICIT in the tree: a backend-agnostic
     `core` + two thin backends (dying gl, surviving wgpu). Then 'zimr_wgpu
     becomes zimr' = 'delete gl backend, keep core+wgpu'. Structure the
     re-exports now so that deletion is a near-one-liner later.
  B. ui.zig's draw coupling is the linchpin — route its draws through the
     gpu_iface/gl_iface TRAIT, not rlgl directly → ui ports once, backend-free.
  C. DON'T DUPLICATE — ALIAS. Several zimr_wgpu exports (shapes/text/scissor)
     were REIMPLEMENTED. Where the GL version is agnostic or trait-based,
     converge on ONE implementation rather than maintaining two.

The raytracer port (CPU→GPU→shared-shader side-by-side) is a good DRIVER for
step 2: it needs Color/Image/PixelFormat/isKeyDown/gpu-texture-upload — porting
those for the raytracer advances the convergence. (Keep its ECS scene as-is —
ecs is now re-exported.)


## KEYSTONE DEMO DESIGN: rlsw_side_by_side as the convergence proof (turn ~907)

Studied examples/rlsw_side_by_side.zig (1548 lines) deeply. It ALREADY does the
hard thing: renders the SAME scene two ways — rlsw (software, left) vs rlgl (GL,
right) — AND draws a UI panel on both, all through ONE `gl: anytype` code path.
The convergence target is to swap the rlgl half for WgpuGl, so the demo becomes
**rlsw (software) vs WgpuGl (GPU)**, same code both sides. This proves the entire
'most code agnostic to software-vs-WGPU' thesis in one artifact.

WHY IT'S CLOSE (the infrastructure already exists — verified):
  - All drawing fns are `gl: anytype` (drawScene/drawUiPanel/drawStarBurst/etc.).
  - renderer_trait.zig defines the trait via GlAdapter(rlgl) + SwAdapter(rlsw); both
    expose begin/end/vertex2f/vertex3f/color4ub/texCoord2f/normal3f/setTexture/
    loadIdentity/matrixMode/multMatrix/ortho/enable/disable.
  - **WgpuGl ALREADY conforms to 13/14 of these.** The demo calls 12 distinct
    gl.* methods; WgpuGl has ALL of them EXCEPT TWO: `ortho` and `setBlendMode`.
    (It even has `frustum` — the harder 3D one.)
  - ui.zig is ALREADY backend-agnostic at the draw layer: widgets append to a
    DrawList; DrawList.render(gl: anytype, shapes_state, ...) replays via
    drawing.shapes.* ("no new rasterizer code"; comment: "*rlgl.GlState and
    *rlsw.Context satisfy the trait"). The ONLY rlgl coupling in ui.zig is ~6
    concrete `*rlgl.GlState` refs in the RENDER-TEXTURE / deferred-render
    plumbing (frame_gl, pushRenderTexture/popRenderTexture,
    uiContextDeferredRender) — NOT the drawing.

CONCRETE PATH TO THE KEYSTONE (revised, much shorter than feared):
  K1. Add `ortho` + `setBlendMode` to WgpuGl (small; model ortho on the existing
      frustum). Now the existing gl:anytype drawScene/drawUiPanel run on WgpuGl
      UNCHANGED.
  K2. Texture-upload + composite abstraction: the demo does
      z.updateTexture(view, rlsw_bytes) + a GL RenderTexture for the GL half +
      drawTexture to composite. WGPU equivalent already proven in
      wgpu_mandelbrot_split: WgpuTexture(copy_dst) created once +
      wgpu.queueWriteTexture each frame + drawTextureRec. Provide a tiny
      backend-agnostic 'present a CPU RGBA buffer as a fullscreen/region texture'
      helper that both the rlsw composite AND the raytracer use.
  K3. ui port: generalize ui.zig's ~6 `*rlgl.GlState` (render-texture plumbing)
      to `anytype` / the gpu_iface trait. Drawing already works. Then z.Ui
      beginFrame/render run against WgpuGl. (THE LINCHPIN, now surgical not a
      rewrite.)
  K4. Build examples/wgpu_rlsw_side_by_side: rlsw left, WgpuGl right, same
      gl:anytype scene + real z.Ui panel on both, perf bars, diff overlay.
  K5. Fold the RAYTRACER in: it's a CPU per-pixel renderer → an RGBA buffer →
      present via K2's helper. Run it on BOTH sides trivially (the SAME CPU
      raytrace buffer can be shown by the rlsw-composite path AND uploaded to
      WgpuGl), OR run the ray loop once and present on both — the raytracer is
      ALREADY backend-agnostic (pure zm math + ecs scene, no GL). Its only GL dep
      was the upload, which K2 abstracts.

So the raytracer needs NOTHING backend-specific: it's pure-math + ecs (ecs now
re-exported) producing a pixel buffer. The side-by-side hosts it by presenting
that buffer through the K2 helper on whichever backend. THIS IS THE WIN
CONDITION Simon described: raytracer + UI inside the side-by-side, code agnostic
to sw-vs-wgpu.

REVISED CONVERGENCE STEP 2/3 (supersedes the earlier generic list): drive it via
the keystone — K1 (WgpuGl ortho/setBlendMode) → K2 (present-CPU-buffer helper) →
K3 (ui render-texture plumbing to anytype) → K4 (the side-by-side demo) → K5
(raytracer folded in). Each step is small, verifiable (build + smoke + visual),
and directly advances zimr_wgpu→zimr. The big-bang 'reimplement 1070 symbols'
framing was wrong; the trait + DrawList + agnostic-core architecture means the
real surface to port is TINY and CONCENTRATED.

IMPROVEMENT NOTE (confirms earlier flag B): ui.zig is the linchpin and it's
ALREADY 95% agnostic — the DrawList→drawing.shapes design was exactly right.
Finishing it = generalizing the render-texture plumbing's gl type. Cheap.


## FLAGSHIP v1 RENDERS: CPU(rlsw) | GPU(WgpuGl) side-by-side (turn ~908-909)

examples/wgpu_sidebyside/ — the same 2D scene (orbiting pulsing discs + rotating
hexagon) rendered TWICE at once: rlsw software at 1/3 res (left of a
mouse-following splitter) and WgpuGl full-res (right). The scene is ONE
`fn drawScene(gl: anytype)` + fillCircle/hsv helpers, running unchanged on both
backends. Builds, smoke PASSED, lint 0, corpus 0 (168/1/12). Standalone works.

KEYSTONE STEPS DONE:
  K1: WgpuGl now implements ALL renderer-trait methods — added ortho (+
      orthoMatrix) + setBlendMode (local BlendMode enum, no gl_iface/rlgl dep).
  K2: CpuFramebuffer helper in wgpu_app.zig (init/update/present/
      presentLeftFraction) — the ONE 'CPU RGBA buffer → GPU texture → screen'
      bridge. Exported as z.CpuFramebuffer. Used by the sw side; the raytracer
      will use it too.
  ARCH CLEANUP: extracted SwAdapter (rlsw trait adapter) + BlendMode out of
      renderer_trait.zig into a NEW rlgl-free src/rlsw_adapter.zig; gl_iface re-exports
      them. zimr_wgpu exports it as z.SwGl. This is THE agnostic/backend split —
      the WGPU build drives the software half WITHOUT pulling the GL backend.
  K4-v1: the demo itself (2D scene).

BUGS FIXED THIS TURN:
  - Stray EMITIF/EMITLOOP std.debug.print left in src/spv2wgsl/ir_emit.zig from
    the turn-904 SCCP investigation — would spam stderr on EVERY shader
    conversion. REMOVED. (Caught by the test output.)
  - GPU validation error (Simon's screenshot): requested a window depth
    attachment but the 2D 'shapes' pipeline has no depth-stencil state →
    mismatch. The v1 cube needed depth/culling, which WgpuGl's shapes path
    doesn't do. Pivoted v1 to a DEPTH-FREE 2D scene (also a clearer comparison).

KNOWN GAP (for 3D scenes later): WgpuGl draws everything via the non-depth 2D
'shapes' pipeline. A depth-tested 3D cube on the GPU side needs either (a) a
depth-aware WgpuGl 3D pipeline path, or (b) painter-sort + cull in the shared
scene. Deferred — 2D scenes (mandelbrot, raytracer image, particles) need no
depth and are the next additions.

NEXT (toward the full vision Simon described — mandelbrot/raytracer/particles +
UI panel, scene-switchable):
  - Scene 2: zoomable Mandelbrot. CPU side = rlsw fragment dispatch (the
    mandelbrot_fs shaderMain via rlsw_shader.dispatchFragmentShader into the sw
    framebuffer); GPU side = the mandelbrot_fs WGSL fullscreen. SAME shaderMain,
    both sides — the deepest 'same shader' proof.
  - Scene 3: raytracer. Pure-math + ecs → an RGBA buffer → CpuFramebuffer. Runs
    identically; present on the chosen side.
  - Scene 4: particle sim (CPU sim, drawn via the gl:anytype fillCircle on both).
  - K3: the UI panel — generalize ui.zig's ~6 *rlgl.GlState render-texture refs
    to anytype so z.Ui runs on WgpuGl; then a real ImGui panel with scene
    selector + zoom/iteration sliders, drawn on BOTH sides.


## STATUS (turn ~909): flagship composite fixed via scissor
- examples/wgpu_sidebyside renders: same gl:anytype 2D scene (orbiting discs +
  hexagon) on rlsw(sw, 1/3 res, left) AND WgpuGl(GPU, full res, right), mouse
  splitter. DONE + verified (gpuonly + swfull bisect tests confirmed each half).
- BUG FIXED: the original 'black right half' was the fractional-source-UV blit
  (presentLeftFraction). Replaced with SCISSOR-clipped full blit: GPU scene fills
  canvas, scissor to [0..divider_x] + blit full sw framebuffer there. Robust;
  the split is decided by the scissor rect, not source-UV math.
- MINOR (noticed, not yet chased): a faint dark seam down the hexagon center at
  low res in the sw output — likely the triangle-fan shared center vertex at low
  res. Cosmetic; revisit if it bugs.
- IN FLIGHT / NEXT: Scene 2 = zoomable Mandelbrot (same mandelbrot_fs shaderMain
  via rlsw_shader.dispatchFragmentShader on the CPU side + WGSL fullscreen on the
  GPU side — the 'same shader both sides' headline). Then raytracer (Scene 3),
  particles (Scene 4), then K3 = ImGui panel on both sides (generalize ui.zig's
  ~6 *rlgl.GlState render-texture refs to anytype).
- PER-TURN: save /mnt/user-data/outputs/zimr{N}.zip each turn (N ~= turn number;
  resumed at 909). PLAN.md Current focus now points here.


## AUDIT + ROOT FIX: deferred-draw resource aliasing (turn ~910)

THE FLAGSHIP WORKS: examples/wgpu_sidebyside renders the same gl:anytype 2D scene
in FULL COLOR on rlsw(sw, 1/3 res, left) AND WgpuGl(GPU, full res, right), mouse
splitter, clean GPU scopes, 60fps. Verified by Simon.

BUG CLASS (named): "deferred-draw resource aliasing". The 2D shapes batch
DEFERS draws and resolves the texture bind group LAZILY at flush/submit time
(flushBatch: setBindGroup(1, b.current_texture_bind_group)). Meanwhile
bindTexture rebuilt the SHARED material slot bind_groups[1] IN PLACE
(resources.set -> buildGroup(1)). So an untextured draw (the GPU scene) staged
against bind_groups[1], then a bindTexture(framebuffer) swap, aliased the
scene's draw onto the framebuffer texture at submit -> black shapes.

OPTIONS CONSIDERED (audit):
  1. Eager-flush-before-state-change (what we HAD): a discipline, not a
     guarantee; one missed flush or any in-place handle mutation = silent
     corruption. FAILED.
  2. Fresh bind group per set (immutable handles): removes aliasing but needs a
     per-frame arena + reset (unbounded alloc otherwise).
  3. Registered-id path (setTexture(id) -> distinct registered_bind_groups[id]):
     distinct handles, no per-frame alloc; what fonts use. Shipped as the
     immediate demo fix, but left bindTexture(tex) as a loaded footgun.
  4. Batch keyed by (pipeline,bindgroup), auto-split on mismatch: correct by
     construction; more hot-path bookkeeping (per-range binding).
  5. Snapshot bind group at record time not flush: matches immediate-mode
     semantics; pairs with #2.
  6. Retained command list (resources travel with each cmd): cleanest; why
     ui.zig NEVER had this bug (DrawList.render). Biggest refactor.

TRUE BEST (shipped, two layers):
  LAYER 1 (root, done): make the SAFE path the ONLY path. Added
  Renderer2D.bindGroupForTexture(tex) — caches by texture HANDLE, returns a
  DISTINCT persistent bind group (register-or-reuse), never mutates the shared
  bind_groups[1]. Rewrote WgpuGl.bindTexture to use it. Now bindTexture(tex) AND
  setTexture(id) are equally safe; NO caller can reintroduce the aliasing. The
  footgun is removed, not just avoided. (lint 0, corpus 0, shapes demo's
  checkerboard still renders via the new bindTexture.)
  LAYER 2 (recommended next, NOT yet done): a batch-boundary guard — in the
  setTexture/bindTexture path, if the bind group changes while
  shapes_batch.vertex_count > 0, debug-assert + auto-flush. Converts any future
  "silent black" into a loud debug panic at the offending call. Same spirit as
  the VS<->FS comptime check + the wgsl_check phi-orphan lint: encode the
  invariant where it's violated.

LESSON (engine-wide): any "set state -> draw" on a deferred/batched renderer is
unsafe if the draw can be deferred past the next state-set AND the state is a
shared mutable slot. Two safe shapes: distinct persistent handles (what we did),
or resources-travel-with-the-command (ui.zig DrawList). Prefer making the unsafe
API structurally impossible over documenting "call flush first".

## STATUS (turn ~910): flagship works; bindTexture aliasing fixed at the root
- examples/wgpu_sidebyside: DONE, full-color both halves, verified.
- Root cause was deferred-draw bind-group aliasing in bindTexture; fixed via
  Renderer2D.bindGroupForTexture (cache-by-handle, distinct bind group).
- NEXT: Scene 2 = zoomable Mandelbrot (same mandelbrot_fs shaderMain via
  rlsw_shader.dispatchFragmentShader on CPU + WGSL fullscreen on GPU — the
  'same shader both sides' headline). Then raytracer, particles, ImGui panel.
- Optional: Layer-2 batch-boundary guard (make the aliasing class panic loudly).
- PER-TURN zip resumed (zimr910). PLAN.md points here.


## STATUS (turn ~911): Layer-2 guard landed; shapes regression clean
- Shapes-demo regression (uses bindTexture for its checkerboard): renders fully
  incl. the orange checker + text — the bindTexture cache fix is verified. The
  'colors shift on touch' Simon noticed is the demo's INTENTIONAL press-to-
  brighten (lift=60 on red when pressed), not a bug. Verified the label.
- LAYER 2 DONE: ShapesBatch.bindTextureGroup(bg) — asserts vertex_count==0
  before swapping the material bind group (debug panic at the offending call
  instead of silent aliasing). Routed both wgpu_draw.zig swaps through it.
  Build + smoke clean (assert never fires in normal use; discipline enforced).
- The deferred-draw aliasing class is now: (L1) structurally safe via distinct
  per-texture bind groups, (L2) loudly guarded if a future path skips the flush.
- lint 0, corpus 0 (168/1/12).
- NEXT: Scene 2 = zoomable Mandelbrot, SAME mandelbrot_fs shaderMain on both
  sides (rlsw_shader.dispatchFragmentShader CPU-left + WGSL fullscreen GPU-right).
  Then raytracer, particles, ImGui panel. Plus: a scene-selector + zoom controls.
- PER-TURN zip (zimr911). PLAN.md -> here.


## SCENE 2 SHIPPED: same mandelbrot shader, CPU-left | GPU-right (turn ~912)
- examples/wgpu_mandel_sidebyside: the headline. mandelbrot_fs shaderMain
  dispatched per-pixel on CPU (rlsw_shader.dispatchFragmentShader, 1/5 res for
  perf) LEFT, the SAME shaderMain as WGSL fullscreen on GPU RIGHT, shared UBO,
  divider FIXED at center. max_iter=100. Pan (drag) + zoom (wheel about cursor /
  two-finger pinch about midpoint). Build + smoke + lint 0 + corpus 0.
- PINCH: did NOT reinvent — mirrored the proven zimr.ts touch bridge (push each
  changedTouch by identifier to the wasm touch ring + mirror primary to mouse)
  into tools/buildaux.zig's standalone template (touchstart/move/end/cancel ->
  zimr_input_push_touch_*), and the pan/zoom/pinch MATH from
  examples/mandelbrot.zig (screenToComplex + world-point-under-cursor-stays-fixed
  invariant). Added z.getTouchPointCount / z.getTouchPosition (wgpu_app wrappers
  + zimr_wgpu exports).
- COORD NOTE: used .responsive scale_mode so CSS px == design px — mouse AND
  touch coords are already in the space the pan math expects (the .fit mode
  inverse is applied to mouse-move at push time but NOT to touch pushes, so .fit
  + touch would mismatch; .responsive sidesteps it). If a .fit demo ever needs
  touch, apply the same fit-inverse in pushTouch* (TODO, not needed yet).
- NEXT: Scene 3 = raytracer (pure-math+ecs -> RGBA buffer -> CpuFramebuffer,
  present on chosen side). Scene 4 = particles. Then K3 = ImGui panel on both
  sides + a scene selector. Consider a unified multi-scene shell.
- PER-TURN zip (zimr912). PLAN.md -> here.


## DESIGN DECISION: State init — default-field-values are a footgun (turn ~913)

THE BUG (bit TWICE: turn 909 sidebyside + turn 913 mandel-sbs): zimr_app.run did
`gpa.create(State)` which returns UNINITIALIZED memory — the State struct's
`field = default` values are NOT applied. A `struct { zoom: f32 = 1.0 }` starts
with garbage/zero zoom → scale=4/(0*h)=inf → all-black mandelbrot. The default
LOOKS like initialization but is a lie about lifetime (gpa.create / undefined /
@memset / MultiArrayList all bypass field defaults). Simon: "Zig team don't like
default init values. Maybe we should agree with them and never use them?" — YES,
that's exactly right and exactly the Zig-core position (defaults don't apply
uniformly; initialize explicitly at the use site).

OPTIONS WEIGHED:
  1. `state_ptr.* = .{}` in run (IN PLACE NOW, the safety net): applies defaults
     for fully-defaultable States (all current wgpu examples qualify). BUT breaks
     any State with a non-defaultable field (GL's `scratch: ArenaAllocator` has
     none), and still relies on defaults — the thing we distrust. GL-side run
     CAN'T even do this. Keep as a stopgap, not the cure.
  2. Forbid State field defaults + require initState to set every field + lint.
     Zig-aligned; bug becomes visible (uninitialized field). Lint "every field
     assigned" is hard to write correctly.
  3. run takes a pre-built State value: no create-without-init. But initState
     needs the GPU device (only available after run starts) → partial init.
  4. **initState RETURNS the State** (`fn initState(gpa, f) !State`), run stores
     it. THE TRUE FIX: the example MUST produce a COMPLETE value (compiler
     rejects a missing field in a no-default struct literal), the GPU device is
     available via `f` so GPU handles get real values, NO uninitialized window,
     NO default-that-doesn't-apply, NO `create`-then-fill gap. Fully Zig-aligned
     (explicit construction, value returned, zero defaults needed). Same spirit
     as the VS<->FS comptime check + bind-group guard + coord-transform unify:
     encode the invariant in the type system, not in discipline.

DECISION: adopt Option 4 as the durable fix — migrate `run` to
`initState: fn(gpa, *Frame) !State` and have every wgpu example build + RETURN a
fully-specified State (NO field defaults). ~11 examples + the run signature.
It's a mechanical but cross-cutting change → its OWN focused turn, not rushed
mid-demo. Until then, `state_ptr.* = .{}` stays as the safety net (correct for
all current examples, which are fully-defaultable).

OPTIONAL lint (when doing the migration): flag a State type passed to run that
declares ANY field default — nudging the no-defaults / set-in-initState style.

STATUS (turn ~913): logging FIXED (std.log -> on-page via zimr_wgpu.std_options;
examples add `pub const std_options = z.std_options;`). mandel-sbs black was
zoom=0 from the uninitialized-State gotcha; fixed via state_ptr.* = .{} (root)
+ explicit initState set (belt). coord-transform unified (cssToLogical /
logicalToCss, all input+scissor route through it; touch .fit gap closed; scissor
clamps+asserts). NEXT: verify mandel-sbs renders, then Scene 3 raytracer; and
schedule the initState-returns-State migration.


## STATUS (turn ~915): initState-returns-State migration COMPLETE
- zimr_app.run now takes `initState: fn(gpa, *Frame) !State` (returns the State,
  not an out-param). State structs have NO field defaults — initState
  CONSTRUCTS and RETURNS a fully-specified value. A forgotten/default-relying
  field is now a COMPILE ERROR. The black-mandelbrot zoom=0 gotcha class is
  structurally impossible. Removed the `state_ptr.* = .{}` band-aid; run now
  copies the returned value into stable heap storage.
- ALL 10 built wgpu examples migrated (julia, mandel_julia, sidebyside,
  mandel_sidebyside, shapes, cube, mandelbrot_split, gltf_textured, lambert,
  pbr). lint 0, all build, corpus exit 0.
- Y-CONVENTION unified earlier this arc: rlsw_shader.dispatchFragmentShader now
  v = 1 - row/height (screen-top = v=1), MATCHING the GPU fullscreen triangle's
  frag_tex_coord. Updated the rlsw UV test to the new convention. mandel-sbs
  pan/zoom Y also reconciled (screenToComplex + drag + pinch all consistent).
- NEXT: deinitState hook + leak reporting (the prep Simon wants); and continue
  porting: the REAL raytracer port (examples/wgpu_raytracer is a STALE GL copy,
  not wired, imports `zimr` not `zimr_wgpu`) -> a wgpu CPU demo + fold into the
  side-by-side.


## RAYTRACER PORTED to wgpu (turn ~916)
- examples/wgpu_raytracer: the GL CPU path tracer ported to WebGPU. Pure zm-math
  ray core (RTIOW lambertian/metal/dielectric, rayColor recursion, sky presets,
  progressive accumulator) + ecs sphere scene kept VERBATIM. Swapped the GL
  bits: z.Image/z.gpu.updateTexture/drawTexturePro/ImGui-HUD -> CpuFramebuffer
  (update+present). Migrated to initState-returns-State. UI panel stubbed
  (drawUiPanel returns false; no z.Ui yet). Build + smoke + lint 0 + corpus 0.
  Standalone works (WASD move, right-drag look, wheel zoom, progressive refine).
- Convergence exports added: z.Vec, z.Vec2, z.isKeyDown, z.isKeyPressed
  (wgpu_app wrappers; KeyboardKey via types.zig).
- NOTE: the old examples/wgpu_raytracer was a STALE GL copy; now it's a real
  wgpu demo wired with its own build step (simple, no shader).
- NEXT: fold the raytracer into a side-by-side (CPU raytrace left / GPU right),
  OR continue porting other examples; then deinitState + leak reporting.
- PER-TURN zip (zimr916).


## GPU RAYTRACER as a FRAGMENT SHADER (turn ~917)
- examples/rt_fs.zig: a ray-tracing FRAGMENT SHADER (rt_fs_io.zig schema). One
  shaderMain path-traces a sphere scene for the pixel: iterative bounce loop (NO
  recursion), ray/sphere intersection, lambertian/metal/dielectric (Schlick),
  per-pixel PCG-ish PRNG, sky gradient. Compiled CLEANLY through the pure-Zig
  SPIR-V->WGSL pipeline (no atan2/OpTypeMatrix/unsupported issues).
- examples/wgpu_rt_shader: GPU host demo, fullscreen pass. Builds + smoke +
  lint 0 + corpus 0. Standalone works (1 sample/frame; accumulation TODO).
- KEY DESIGN for the upcoming side-by-side: the scene lives in the UBO as FLAT
  vec4 ARRAYS (sphere_geom/sphere_albedo/sphere_extra: [8]Vec) — the shader
  codegen (gen_shader_externs zigTypeForType) supports [N]@Vector(4,f32) but NOT
  [N]struct. So NO nested struct in a UBO; flatten to vec4 arrays.
- zm subset used (all SPIR-V-safe, shared CPU/GPU vocab): dot3, cross3,
  normalize3, reflect3, lengthSq3, splat, vec, vec4, clamp, pow, sqrt, min/max.
  NOTE: zm.vec is the 3-arg vec3 ctor; use zm.vec4 for 4 components.
- NEXT: the rt side-by-side — run THIS rt_fs on the CPU via
  rlsw_shader.dispatchFragmentShader (left) + GPU fullscreen (right), movable
  split. Then accumulation (avg N frames) for a clean image. Then deinitState +
  leak reporting.
- PER-TURN zip (zimr917).


## ===== THE CRITICAL PATH: all examples ported, WebGL DELETED (turn ~918) =====

GOAL (precise): every example builds on zimr_wgpu; delete the GL backend
(rlgl/gl/gl_iface/gpu.zig + the .glsl shaders) AND the C++ tools (spirv-cross,
spirv-opt — 26 invocations in shader_codegen.zig); rename zimr_wgpu -> zimr.

STATE (turn ~918): 148 GL example .zig, 13 wgpu dirs. zimr exports 1132 symbols,
zimr_wgpu 83 direct (+ the full transitive surface of re-exported agnostic
modules: types, easings, entities/ecs, physics, codecs, rlsw, sound, web, utils,
math). The raw 148-vs-13 is misleading: most GL examples are UI/2D that port
TRIVIALLY once the renderer surface is complete. The work is surface + 2 hard
backends, not 135 rewrites.

WHAT EXAMPLES ACTUALLY CALL (z.* frequency across all GL examples), = the
priority order:
  503 colors (= the types module; ONE-LINE re-export) | 314 Frame | 261 drawText
  234 Vec | 161 Color | 159 FontCache | 141 math | 139 loadFontFromTtfBytes
  135 default_codepoints_ascii | 135 AppBridge | 129 ShapesTextureState
  105 begin/endDrawing+clearBackground | 104 gpu(GL resource layer) | 73 Rectangle
  69 ui | 51 isKeyPressed | 48 rlVertex | 48 Image | 46 rlTexCoord | 40 Texture
  39 drawRectangle | 36 shader | 33 getMousePosition | 31 isKeyDown | 31 Model
  28 isMouseButtonPressed | 28 Logger | 25 drawCircleV | 24 rlgl_gpu | 23 runtime
  23 beginMode(2D/3D) | 22 Entities | 21 Rectangle/drawRectangleRec | 21 Camera

ATTACK ORDER (most logical -> least blocking):
  PHASE A — high-frequency convergence gaps (unblocks the BULK of 2D/UI/text
    examples). Add to zimr_wgpu: colors(=types, 1-liner), Rectangle, the common
    shapes (drawCircleV/drawRectangleRec/drawLine/...), Image+Texture load/unload,
    Logger, isKeyPressed/isMouseButtonPressed, beginMode2D/3D (cameras unified).
    Many are re-exports of agnostic code or thin wrappers over the wgpu renderer.
  PHASE B — UI port (z.ui, 69 uses): THE LINCHPIN. ui.zig is already
    backend-agnostic at the draw layer (DrawList.render(gl: anytype) ->
    drawing.shapes). Only ~6 *rlgl.GlState render-texture refs need ->anytype.
    Then z.Ui beginFrame/render run on WgpuGl.
  PHASE C — 3D model path (z.Model, z.Mesh, scene/render PBR): the
    wgpu_pbr_demo proves the pipeline; scene/render need the WGPU resource
    backend. damaged_helmet etc. depend on this.
  PHASE D — bulk-port the now-portable examples (mechanical once A/B/C land).
  PHASE E — DELETE: when nothing builds against rlgl/gl/gpu.zig/.glsl/spirv-
    cross/spirv-opt, delete them + rename zimr_wgpu -> zimr.

CAMERAS: DONE + unified into zm (turn 918) — Camera2D/Camera3D/RayCamera with
methods (.matrix/.viewProj/.rayBasis), convention pinned by test, types.zig
re-exports for compat. All examples should use these; NONE roll their own
(the recurring Y-bug cause). pbr3d.Camera (raw view/proj) still to fold in.

INFRA HARDENING (flagged, do alongside): the translator emits invalid WGSL with
`// ERROR:` markers + the build STILL PASSES (only real naga/Tint catches it).
Make the build FAIL on `// ERROR:` markers + run naga in CI. (The rt_fs saga.)

STARTING: Phase A.


## STATUS (turn ~918): cameras unified + infra hardened + Phase A started
- CAMERAS unified into zm: Camera2D/Camera3D/CameraProjection/RayCamera with
  methods (.matrix/.worldToScreen/.screenToWorld/.viewMatrix/.projMatrix/
  .viewProj/.rayBasis) + pixelRayDir. Convention pinned by test (frag.y=1=up).
  types.zig RE-EXPORTS them (GL side transparent; corpus exit 0). rt demo uses
  Camera3D.rayBasis. All 151 zm tests pass. (pbr3d.Camera still to fold in.)
- INFRA HARDENED: flipped all demos' .wgsl_strict false->true in build.zig. Now
  ANY `// ERROR:` marker in translated WGSL FAILS THE BUILD (the rt_fs-class
  'compiles-but-invalid-WGSL' bug is caught at build time). All shader demos
  build clean under strict. wgsl_strict was already implemented — demos just
  wrongly opted out (copied from fractals that tolerate the benign 'unreachable'
  warning, which is NOT an ERROR marker).
- PHASE A batch 1: added to zimr_wgpu — colors(=types, closes 503 uses),
  Rectangle, Camera2D/3D, RayCamera, drawRectangleRec/drawCircleV/drawLine/
  drawLineEx (native wgpu_app shape wrappers). lint 0, corpus 0.
- DEFERRED: Logger (buried in runtime.zig, GL-coupled; 28 uses; Phase D).
- NEXT (Phase A cont.): beginMode2D/3D (camera mode push/pop on WgpuGl — cameras
  ready), Image/Texture load/unload, then Phase B (ui port).
- PER-TURN zip (zimr918).


## STATUS (turn ~919): Phase A surface expanded
- Added to zimr_wgpu (all building, lint 0, corpus 0, all 12 demos OK):
  - beginMode2D/endMode2D/beginMode3D/endMode3D (wgpu_app, using the unified zm
    cameras + WgpuGl matrix stack; 3D sets frustum/ortho from cam.fovy+aspect,
    view from lookAt). NOTE: 3D depth-test still needs a depth-aware pipeline
    (the cube-demo gap) — the API is there, depth-correct 3D is Phase C.
  - Image (type) + PixelFormat + loadImageFromMemory (codecs.png.decode,
    agnostic) + loadTextureFromImage(gl, image) -> WgpuTexture (the GPU bridge).
  - (earlier this session) colors, Rectangle, Camera2D/3D, RayCamera,
    drawRectangleRec/drawCircleV/drawLine/drawLineEx.
- wgpu_app now imports zm (was missing).
- LINT WIN: std.math.pi was banned (GPU-portability) — used zm.pi.
- REMAINING Phase A: Texture(wgpu uses WgpuTexture, not the GL Texture struct —
  examples referencing z.Texture will need WgpuTexture or a typedef), the rl*
  immediate-mode names (rlVertex/rlTexCoord, 48+46 uses — these ARE WgpuGl's
  vertex2f/texCoord2f under raylib names), Logger (deferred, GL-coupled).
- NEXT: finish Phase A stragglers, then PHASE B — the ui port (the linchpin:
  ui.zig DrawList is already gl:anytype; ~6 *rlgl.GlState render-texture refs
  need ->anytype).
- PER-TURN zip (zimr919).


## PHASE B DECISION: minimal immediate-mode UI on WgpuGl (turn ~920)

Surveyed ui.zig for the port. FINDINGS:
- ui.zig is ~42,000 lines (a full ImGui). DrawList.render(gl: anytype, ...) is
  ALREADY backend-agnostic at the command-replay level BUT it emits via
  drawing.shapes.drawRectangleRec(gl, ...) and drawing.text — and drawing.zig
  imports rlgl, so it CANNOT be used in the wgpu build as-is.
- The rlgl coupling in ui.zig is concentrated but real: frame_gl: ?*rlgl.GlState,
  beginFrameRaw(gl: *rlgl.GlState), push/popRenderTexture, uiContextDeferredRender,
  + ~5 `ctx.frame_gl orelse return` sites, + the render-texture deferral
  machinery. Generalizing frame_gl -> anytype ripples through all of it.
- What examples ACTUALLY use: text(389) window/panel(313) separator(164)
  button(100) slider(92) label(81) checkbox(52). A FOCUSED immediate-mode set —
  not the full ImGui surface.

DECISION: do NOT port the 42k-line ui.zig wholesale (huge, delicate, risks the
GL UI many GL examples depend on, and most of it is unused by the demos we care
about). Instead build a FOCUSED immediate-mode UI module on WgpuGl
(src/wgpu_ui.zig): window/panel, button, slider(float), label/text, checkbox,
separator — all drawn via `gl: anytype` shapes + z.drawText, with simple
hit-testing against z.getMousePosition / isMouseButtonPressed. This:
  (a) gives the FLAGSHIP its control panel NOW (scene selector + sliders),
  (b) covers the common widget set the examples use,
  (c) is a clean, self-contained module (no 42k-line entanglement),
  (d) can later grow toward ui.zig parity if needed.
The hand-drawn drawUiPanel in examples/rlsw_side_by_side.zig is the proven
template (gl:anytype shapes + hit-test).

PHASE A STATUS: colors, Rectangle, cameras, shapes (Rec/V/line), camera modes
(beginMode2D/3D), Image+loadImageFromMemory+loadTextureFromImage — ALL DONE,
lint 0, corpus 0, 12 demos build. Remaining Phase-A stragglers (rl* immediate
aliases like rlVertex/rlTexCoord = WgpuGl methods under raylib names; the GL
Texture struct vs WgpuTexture; Logger) are LOW priority / Phase D — deep
GL-immediate examples, not blocking the flagship or the common 2D/UI set.

NEXT: build src/wgpu_ui.zig (focused immediate-mode UI), wire a control panel
into the flagship side-by-side (scene selector + sliders), THEN Phase C (3D/PBR
+ depth-aware WgpuGl pipeline) and the bulk-port.


## PHASE B STARTED: wgpu_ui (focused immediate-mode UI) + flagship panel (turn ~920)
- NEW src/wgpu_ui.zig: a focused immediate-mode UI (NOT the 42k-line ui.zig).
  Ui(GlT) generic over the renderer trait (works on WgpuGl + rlsw). Widgets:
  panel, label, separator, button, sliderFloat, checkbox — drawn via gl:anytype
  shapes + z.drawText, hit-tested vs the frame mouse. `wants_mouse` lets callers
  gate their own pan/zoom. Exported z.Ui = wgpu_ui.Ui(WgpuGl).
- WIRED into examples/wgpu_mandel_sidebyside: a control panel with a live
  max-iterations slider (now a State field) + reset-view button. The flagship
  has its UI. Builds + standalone + lint 0 + corpus 0.
- This is the pragmatic Phase B: covers the common widget set (button/slider/
  checkbox/label/panel/separator) the examples use, without porting/entangling
  the giant ui.zig. Can grow toward parity later.
- NEXT: broaden wgpu_ui as needed (text-input, layout columns) only if examples
  demand it; gate pan/zoom on ui.wants_mouse in the demos; then Phase C (3D/PBR
  + depth-aware WgpuGl pipeline) and the bulk-port.
- PER-TURN zip (zimr920).


## UI UX FIXES (turn ~921)
- ROOT BUG: "moving the slider pans the fractal" — handleInput (scene pan/zoom)
  ran BEFORE the UI was built, so it couldn't know the pointer was over the
  panel. FIX: gate handleInput on mouseOverPanel(f); an ui_capturing latch
  (held while LMB down + started on panel) keeps input with the UI through a
  drag that leaves the panel. Also fixes "reset view does not work" (it fired
  but the panel-touch was simultaneously panning the fractal away).
- PHONE USABILITY: wgpu_ui rows 26->38px, font 16->18, panel 230x150->300x188;
  slider track taller + knob 6->14px wide with the WHOLE ROW as grab area.
- LESSON for wgpu_ui users (note in module): the caller MUST gate its own
  pan/zoom on whether the pointer is over the UI — either check the panel rect
  before running scene input (as mandel-sbs does) or read ui.wants_mouse and
  restructure so the UI is queried first. An IMGUI-over-scene needs input
  priority. (Consider a z.Ui helper that returns capture state pre-draw.)
- PER-TURN zip (zimr921).


## ===== ui.zig DEEP UNDERSTANDING + REAL PORT PLAN (turn ~922) =====

COURSE CORRECTION: do NOT rewrite ui.zig. It's 42k lines of careful ImGui-style
design (ID stack, layout, hit-test state machine, windows/popups/tooltips/drag,
DrawList batching). The earlier wgpu_ui.zig from-scratch module was the WRONG
call. Goal: make ui.zig ITSELF run on wgpu. WebGL is going away, so we can edit
ui.zig DIRECTLY to target the wgpu backend (no need to keep the GL path).

DEEP MAP of ui.zig's backend coupling (the actual findings):
- The ENTIRE UI draw is DrawList.render(gl: anytype, window, shapes_state,
  font_cache) -> drawing.shapes.* / drawing.text.* — and THOSE are ALSO
  gl: anytype (they call gl.begin/vertex2f/color4ub/end, NOT rlgl directly).
  So the rendering is ALREADY backend-agnostic.
- 150 `rlgl.GlState` refs, but ~all are just the TYPE in signatures
  (gl: *rlgl.GlState) + gl_dummy test fixtures. The actual rlgl FUNCTION calls
  are TINY and ALL live in exactly TWO functions: pushRenderTextureImpl +
  popRenderTextureImpl (the render-texture feature). Calls: rlMatrixMode,
  rlPushMatrix/PopMatrix, rlLoadIdentity, rlOrtho, rlViewport,
  rlDrawRenderBatchActive, rlEnable/DisableFramebuffer, RL_PROJECTION/MODELVIEW.
  WgpuGl ALREADY has matrixMode/loadIdentity/ortho/multMatrix/
  flushBeforeMaterialSwap; only framebuffer (render-texture) is GL-specific.
- The deferred-render seam is ALREADY type-erased: uiContextDeferredRender(data:
  *anyopaque, gl) queued into f.gl.pending_renders, replays all DrawLists. The
  gl it uses is ctx.frame_gl (stored *rlgl.GlState).
- drawing.zig imports rlgl ONLY for PrimitiveMode CONSTANTS + test fixtures
  (not for the actual draw path).

THE COUPLING TO BREAK (narrow + concentrated):
  1. frame_gl: ?*rlgl.GlState (stored) -> the wgpu gl type (*WgpuGl).
  2. The ~10 rlgl matrix/framebuffer CALLS in push/popRenderTextureImpl -> WgpuGl
     methods (matrix ones map directly; framebuffer/render-texture needs a WgpuGl
     render-pass equivalent OR stub initially).
  3. The *rlgl.GlState TYPES in signatures -> *WgpuGl.
  4. f.gl.pending_renders (GL deferred queue) -> the wgpu Frame's equivalent, OR
     call uiContextDeferredRender directly at endFrame (wgpu has one pass).
  5. drawing.zig's rlgl import (PrimitiveMode consts + tests) — make those consts
     not require rlgl, or provide them on the wgpu side.

PORT STRATEGY (since GL is going away — edit in place, mechanical):
  Step 1: replace `rlgl.GlState` -> the wgpu gl type throughout ui.zig (the type
    is the bulk; mechanical). The gl_dummy test fixtures become WgpuGl dummies.
  Step 2: map the ~10 rlgl calls in push/popRenderTextureImpl to WgpuGl methods;
    render-texture: either WgpuGl offscreen pass or stub (UI rarely needs RT).
  Step 3: deferred render — call uiContextDeferredRender at the right point in
    the wgpu frame (endDrawing), since wgpu uses a single render pass.
  Step 4: drawing.zig — lift PrimitiveMode consts out of rlgl-dependence (or a
    small shim), so drawing.shapes/text compile in the wgpu build.
  Step 5: delete src/wgpu_ui.zig (the wrong-call from-scratch module); the
    mandel-sbs panel switches to the real z.Ui (ui.zig) API.

This is multi-turn + delicate (big file). Do it carefully, build-verifying each
step. The PAYOFF: the FULL ImGui (windows, popups, all widgets, tooltips, drag)
runs on wgpu — every UI example ports, not just the focused subset.

NOTE: keep wgpu_ui.zig working in the meantime (the flagship uses it) until
ui.zig is proven on wgpu, THEN switch + delete wgpu_ui.zig.


## ui.zig PORT — KEY UNBLOCKING FACTS (turn ~922, refined)
- rlgl.zig is PURE ZIG (0 extern fn / @cImport). The C/GL-GPU side is separate
  (rlgl_gpu). So importing rlgl/drawing into the WGPU wasm build is NOT fatal —
  it compiles; DCE strips the GL-GPU calls that are never invoked. The earlier
  "can't pull rlgl into wgpu" fear was overcautious.
- The DrawList replay path is concretely: DrawList.render(gl, ...) ->
  drawing.shapes.drawRectanglePro(gl: anytype, shapes_state, ...) which emits via
  gl.setTexture(shapes_state.texture.id) + gl.begin(.quads) + gl.color4ub +
  gl.normal3f + gl.vertex2f — ALL trait methods WgpuGl HAS.
  ONE detail: gl.setTexture(id) passes the SHAPES white-texture id; on WgpuGl the
  registered-id path must have that texture registered (id resolves via
  lookupBindGroup). Handle: register a 1x1 white texture as the shapes texture
  for the wgpu UI, or pass a WgpuGl-known id.

REFINED PORT (since GL is going, edit ui.zig in place; rlgl harmless in wgpu):
  1. Change ui.zig's gl param TYPE: `*rlgl.GlState` -> `anytype` on the render/
     deferred fns (DrawList.render is already anytype; the wrappers + frame_gl
     storage need the concrete WgpuGl, or type-erase via *anyopaque like the
     existing deferred seam). Simplest: frame_gl: ?*WgpuGl.
  2. push/popRenderTextureImpl: map ~10 rlgl matrix calls -> WgpuGl methods;
     render-texture (framebuffer) -> WgpuGl offscreen pass OR stub.
  3. Wire the shapes white texture for WgpuGl (register it; ShapesTextureState).
  4. Deferred render: call uiContextDeferredRender at endDrawing (wgpu = 1 pass);
     f.gl.pending_renders -> the wgpu frame path.
  5. Verify with the flagship panel using the REAL z.Ui (ui.zig). THEN delete
     src/wgpu_ui.zig.

This is multi-turn + delicate. Each step build-verified. wgpu_ui.zig stays as the
working stopgap until ui.zig is proven on wgpu.


## ui.zig PORT — Step 1 DONE: type centralized (turn ~923)
- Added `const Gl = rlgl.GlState;` alias in ui.zig and replaced ALL 150
  `rlgl.GlState` -> `Gl` (159 Gl tokens). VERIFIED NO-OP: GL build green, corpus
  exit 0, lint 0. ui.zig's ENTIRE backend-type coupling is now ONE line.
- CONSTRAINT CONFIRMED: host tests (features_test, ui_screenshot_test,
  ui_dock_*, app_bridge_test, snapshot_regression_test, typed_shader_test)
  import the GL zimr.zig -> ui.zig. So we CANNOT hard-break the GL build during
  the port — it'd fail the corpus gate. ui.zig must compile for BOTH backends
  through the transition.
- THE PIVOT POINTS mapped precisely:
  * frame_gl: ?*Gl stored in UiContext (line 4774); stamped at beginFrameRaw
    (5243); READ in the deferred callback (23549) + 3 render-texture sites
    (36042/36111/36132) + 25040.
  * uiContextDeferredRender(data: *anyopaque, gl: *Gl) RECEIVES gl as a param
    but IGNORES it and reads ctx.frame_gl instead. (The seam: make it USE the
    passed gl, or type-erase frame_gl.)
  * The ONLY concrete rlgl FUNCTION calls are in push/popRenderTextureImpl
    (matrix + framebuffer). Everything else = trait methods both backends have.

NEXT STEP (Step 2 — backend-flexible Gl, GL stays green): the cleanest design
given "both must compile" is a BUILD OPTION / comptime switch:
  `const Gl = if (build_options.ui_backend_wgpu) WgpuGl else rlgl.GlState;`
  But a single source file compiled into TWO modules (GL zimr_mod + zimr_wgpu)
  can have the alias resolve differently PER MODULE if the build passes a
  per-module build_option. Investigate: does build.zig give zimr_mod vs
  zimr_wgpu_mod distinct build_options? If yes, Gl switches per-build, both
  compile, zero type-erasure needed. If no, fall back to type-erasing frame_gl
  to *anyopaque + a comptime-known render thunk (the deferred seam already
  hints this).
  Then map the ~10 rlgl calls in push/popRenderTextureImpl behind the same
  switch (WgpuGl matrix methods; render-texture stub on wgpu initially).
- PER-TURN zip (zimr923).


## ui.zig PORT — Step 2 DONE: build-switched Gl, ui.zig COMPILES on wgpu (turn ~924)
- build.zig: added `ui_backend_wgpu` option. build_opts (GL modules) = false;
  NEW build_opts_wgpu (= build_opts + ui_backend_wgpu=true) wired into
  zimr_wgpu_mod. ui.zig: `const Gl = if (build_options.ui_backend_wgpu)
  WgpuGl else rlgl.GlState;`. The SAME ui.zig now compiles for BOTH backends,
  per-module. GL build green (corpus exit 0), lint 0.
- ui.zig IMPORTED into zimr_wgpu as `ui_real` — COMPILES CLEAN for wgpu on the
  first try. (The rlgl calls in push/popRenderTextureImpl don't error because
  Zig lazily compiles — those fns aren't CALLED in the wgpu path yet, so their
  bodies aren't type-checked. Render-texture is the only remaining GL-coupled
  bit, and only matters if a wgpu example uses pushRenderTexture.)
- THE FINAL COUPLING mapped: ui.zig's high-level beginFrame(f: *zimr.Frame) is
  typed to the GL Frame. The SEAM is beginFrameRaw(snapshot: InputSnapshot,
  input_state, canvas_w, canvas_h, gl: *Gl, shapes_state:
  *drawing.shapes.ShapesTextureState, font_cache: *drawing.text.FontCache) —
  takes *Gl (= *WgpuGl now) + raw input/shapes/font, NO GL Frame. THIS is the
  wgpu entry point.

NEXT STEP (Step 3 — actually drive ui.zig from a wgpu demo):
  1. Build an ui.InputSnapshot from the wgpu frame's input (mouse pos/buttons,
     keys, wheel). Check InputSnapshot's shape.
  2. Provide a ShapesTextureState for WgpuGl: ui draws sample the shapes white
     texture via gl.setTexture(shapes_state.texture.id) — register a 1x1 white
     texture on WgpuGl and point shapes_state.texture.id at that registered id.
  3. Call ctx.beginFrameRaw(...) -> get Ui -> ui.window/button/slider -> at
     endFrame, replay the DrawLists via gl (uiContextDeferredRender, but call it
     directly since wgpu = 1 pass; don't need f.gl.pending_renders).
  4. Wire a z.Ui (the REAL one) helper in zimr_wgpu that wraps beginFrameRaw +
     endFrame for wgpu, so demos call it cleanly.
  5. Switch the flagship mandel-sbs panel to the real ui.zig; DELETE wgpu_ui.zig.
- PER-TURN zip (zimr924).


## ui.zig PORT — Step 3a DONE: uiRenderNow render seam (turn ~925)
- Added pub fn uiRenderNow(ctx, gl: *Gl, window, shapes_state, font_cache) to
  ui.zig — IMMEDIATE replay of the frame's draw lists (background/windows/popups/
  foreground/tooltip/drag), mirroring uiContextDeferredRender but taking the
  params explicitly (beginFrameRaw doesn't stamp frame_window). This is the
  wgpu single-pass replay entry (no gl.pending_renders queue). Compiles on BOTH
  backends; GL corpus green, lint 0.
- FACTS confirmed for the wgpu host wiring:
  * InputSnapshot: all fields default; for a basic panel set mouse_pos,
    mouse_left_down, mouse_left_clicked, mouse_left_released, mouse_wheel_y.
    Keyboard can default (no text input yet).
  * ShapesTextureState.texture.id defaults to 1; on WgpuGl gl.setTexture(1) goes
    through the registered-id path -> lookupBindGroup(1). Register a 1x1 white
    texture so id 1 resolves to it (then solid shapes sample white = fill).
  * WindowState: screen_width/height (logical). Build one from the wgpu frame.

NEXT (Step 3b — the wgpu UI host + a real-ImGui demo):
  1. In zimr_wgpu (or wgpu_app), add a host that: lazily registers a 1x1 white
     texture as the shapes texture (id 1 on WgpuGl), builds an InputSnapshot from
     f.input, calls ctx.beginFrameRaw(snapshot, f.input, w, h, f.gl, &shapes,
     &font_cache) -> Ui, and after widgets calls ctx.uiRenderNow(f.gl, &window,
     &shapes, &font_cache).
  2. Need a drawing.text.FontCache for wgpu — check how z.loadFont/z.Font relate
     to drawing.text.FontCache (the UI text path uses font_cache).
  3. Expose as z.UiHost / a clean z.beginUi(f)->Ui + z.endUi(). UiContext lives
     on the demo State (persistent).
  4. Build a wgpu demo that opens a real ui.zig window with a button -> proves
     the full ImGui on wgpu. THEN switch the flagship + DELETE wgpu_ui.zig.
- KEY UNKNOWN to resolve next: does WgpuGl's setTexture(1) + a registered white
  texture actually make ui.zig's shape draws render? (the shapes-texture detail).
- PER-TURN zip (zimr925).


## ui.zig PORT — Step 3b: REAL ImGui COMPILES + RENDERS on wgpu (turn ~926)
- Added wgpu_app.UiHost (exported z.UiHost): owns a persistent ui.UiContext +
  ShapesTextureState (texture.id=0 -> WgpuGl's white bind group, so solid shapes
  render with NO extra texture) + a FontCache wrapping z.Font. begin(f) builds an
  InputSnapshot from f.input and calls ctx.beginFrameRaw(...,f.gl,...); render(f)
  calls ctx.endFrameNoRender() + ui.uiRenderNow(f.gl,...).
- Added ui.UiContext.endFrameNoRender() (finalize: tooltip flush + dock tabs +
  metrics, NO gl.pending_renders queue) for the wgpu single-pass path.
- Added WgpuGl.scissor(x,y,w,h:i32) + disable(.scissor_test) reset — ui.zig's
  drawing.text clips via gl.scissor(backing px). (Sets the GPU pass scissor.)
- Added wgpu_app.isMouseButtonReleased.
- WIRED the REAL ui.zig (window/text/slider/button) into wgpu_mandel_sidebyside,
  replacing the from-scratch wgpu_ui panel. It COMPILES end-to-end (beginFrameRaw
  -> widgets -> uiRenderNow -> DrawList.render -> drawing.shapes/text -> WgpuGl).
  GL corpus green, lint 0.
- REMAINING to make it INSTANTIATE in the browser: the full ImGui pulls
  dom:js_persistence_{save,size,read,remove} (window-state localStorage
  persistence — extern "dom" in web.zig). The wgpu bridge (src/web/zimr_wgpu.ts)
  + buildaux standalone template + the smoke shim do NOT provide them yet, so the
  wasm won't instantiate. The GL bridge zimr.ts HAS them (localStorage-backed,
  key prefix "zimr_"). NEXT: port those 4 functions into zimr_wgpu.ts (+ buildaux
  + smoke shim). Bounded, mechanical.
- THEN: verify the real ImGui RENDERS in the browser (window chrome, draggable,
  slider/button); switch other demos; DELETE src/wgpu_ui.zig.
- PER-TURN zip (zimr926).


## ===== ui.zig PORT COMPLETE: REAL ImGui RUNS ON WGPU (turn ~927) =====
- Ported the persistence bridge: js_persistence_{save,size,read,remove} added to
  src/web/zimr_wgpu.ts's dom object (localStorage, key prefix "zimr_", matching
  the GL bridge). setupWgpuBridge sets imports.dom, so the STANDALONE gets them
  automatically. Smoke shim got no-op stubs.
- RESULT: wgpu_mandel_sidebyside now uses the REAL ui.zig (window/text/slider/
  button) via z.UiHost. Smoke PASSED (6 frames, ~401 GPU calls/frame — UI
  draws). Standalone built + rendered: a proper ImGui window (title bar, drag,
  slider, button), full chrome. GL corpus exit 0 throughout (host tests safe).
- The full ImGui (windows, popups, all widgets, tooltips, docking, persistence)
  is now available on wgpu — REUSING all 42k lines of ui.zig, NOT a rewrite.
  The whole arc: deep-understand -> build-switched Gl per-module -> render seam
  (uiRenderNow/endFrameNoRender) -> WgpuGl.scissor -> UiHost bridge ->
  persistence bridge. Every step verified green.

REMAINING / NEXT:
  - DELETE src/wgpu_ui.zig (the from-scratch stopgap) — the flagship now uses
    the real z.UiHost. Check no other demo references z.Ui (the wgpu_ui one);
    repoint any to z.UiHost, then delete wgpu_ui.zig + its zimr_wgpu exports.
  - The render-texture push/popRenderTextureImpl still have rlgl calls (lazily
    uncompiled on wgpu). If a wgpu example uses pushRenderTexture, map those ~10
    rlgl matrix/framebuffer calls to WgpuGl (matrix maps directly; framebuffer
    needs a WgpuGl offscreen pass). Deferred until an example needs it.
  - Then resume the broader convergence: bulk-port UI examples (now that the
    real ui works on wgpu), Phase C (3D/PBR depth-aware pipeline), and finally
    delete the GL backend + spirv-cross/opt + rename zimr_wgpu -> zimr.
- PER-TURN zip (zimr927).


## ui.zig PORT — scissor fix + minimal UI demo (turn ~928)
- BUG (Simon's screenshot, black): disable(.scissor_test) reset the scissor to a
  65535x65535 rect. WebGPU REJECTS a scissor larger than the render area (GL
  clamps; WebGPU doesn't) -> whole command buffer fails -> black. FIX: WgpuGl
  now stores render_w/render_h (set in beginDrawing from the backing surface
  size); scissor() CLAMPS to them and disable(.scissor_test) resets to EXACTLY
  them. (My "GPU clamps it" assumption was wrong for WebGPU.)
- NEW examples/wgpu_ui_demo: minimal real-ImGui (window + text + slider +
  checkbox + button w/ click counter), no fractal — isolates UI rendering.
  Builds + smoke PASSED (~435 GPU calls/frame). Standalone presented.
- GL corpus exit 0, lint 0. Both ui-demo and mandel-sbs build.
- NEXT: confirm the UI demo RENDERS in browser (window chrome, drag, widgets).
  If good, the ui.zig port is proven. Then: delete wgpu_ui.zig, bulk-port UI
  examples, Phase C (3D/PBR), then delete GL + rename.
- PER-TURN zip (zimr928).


## ===== ui.zig PORT PROVEN: REAL ImGui RENDERS + INTERACTS ON WGPU (turn ~929) =====
- wgpu_ui_demo renders the FULL ImGui window correctly: title bar, all text
  (clicks counter increments!), slider (0.769, handle visible), checkbox,
  highlighted button. WIDGETS ARE INTERACTIVE (Simon clicked -> clicks:1, slider
  moved). The ui.zig -> wgpu port is DONE and PROVEN.
- The "scissored into the corner" bug was a DPR mismatch: drawing.zig's scissor
  scale = render_width/screen_width from the window dims, but UiHost reported
  render==screen (DPR=1). On a high-DPR phone the clip was computed in logical px
  while WgpuGl clamps in backing px. FIX: UiHost.begin sets window.screen_* =
  CSS (logical) size, window.render_* = backing size, both from the surface. Now
  drawing.zig's DPR ratio matches WgpuGl's backing scissor.
- Full arc (NOT a rewrite): deep-understand -> Gl alias -> build-switched Gl
  per-module -> uiRenderNow/endFrameNoRender seam -> WgpuGl.scissor (clamped to
  render dims) -> UiHost bridge -> persistence bridge -> DPR scissor fix. GL
  corpus exit 0 EVERY step. lint 0.

KNOWN COSMETIC FOLLOW-UP: a WHITE area shows top-left of the canvas around the
window in wgpu_ui_demo (clearBackground not fully covering, or a white fullscreen
quad behind the UI). Minor, separate from the UI. Investigate: does
z.clearBackground actually clear in the wgpu pass, or is the white the
uninitialized/white shapes texture filling the frame? (The UI demo only draws the
window; the rest of the frame should be the clear color.)

NEXT:
  - Fix the white background (clearBackground coverage).
  - DELETE src/wgpu_ui.zig (the stopgap) + its z.Ui/wgpu_ui exports; the demos
    use z.UiHost (real ImGui). Repoint mandel-sbs's panel (already on UiHost).
  - Bulk-port UI examples (real ui works on wgpu now).
  - Phase C (3D/PBR depth-aware pipeline), then delete GL + rename.
- PER-TURN zip (zimr929).


## ui.zig PORT — landed + cleaned (turn ~930)
- WHITE-BACKGROUND BUG FIXED + footgun removed: z.clearBackground took a FLOAT
  Color (0..1) but every raylib-minded caller passed u8 values like {16,18,26,
  255} -> as floats those are >>1 -> clamped to WHITE. (wgpu_shapes_demo hit it
  too.) FIX: clearBackground now takes a u8 types.Color (like raylib + every
  other draw call) and converts to 0..1 internally. All demos build with their
  existing u8 values; background renders dark.
- DELETED src/wgpu_ui.zig (the from-scratch stopgap) + its z.Ui/wgpu_ui exports.
  Everything now uses the REAL ui.zig via z.UiHost. The wgpu demos referencing
  z.Ui were only the export itself; the GL examples' z.Ui is zimr.zig's (separate
  namespace, unaffected). mandel-sbs uses z.UiHost. All 8 wgpu demos build,
  corpus exit 0, lint 0.
- ui.zig PORT IS COMPLETE: full Dear ImGui (the 42k-line module, NOT a rewrite)
  renders + interacts on WebGPU. Done across turns 922-930, GL corpus green every
  step.

NEXT (broader convergence toward deleting WebGL):
  - Bulk-port the UI examples (ball_physics, ecs_boids, ellipse_collision,
    simple_particles, etc.) — they use the real z.Ui + drawing; now that ui.zig
    works on wgpu, they should port via z.UiHost + the agnostic drawing path.
  - Phase C: 3D/PBR depth-aware WgpuGl pipeline (the cube-demo depth gap) for the
    3D model examples.
  - Then delete the GL backend (rlgl/gl/gpu.zig/.glsl) + spirv-cross/opt, rename
    zimr_wgpu -> zimr.
  - Optional: render-texture (push/popRenderTextureImpl) on wgpu if an example
    needs it (lazily uncompiled today).
- PER-TURN zip (zimr930).


## wgpu_particles: scene + real ImGui (the bulk-port template) (turn ~931)
- NEW examples/wgpu_particles: CPU particle fountain (drag emitter, gravity,
  fade) + a REAL ui.zig control panel (alive count, rate/gravity/size sliders,
  clear button). Builds + smoke PASSED + lint 0 + corpus 0. Standalone presented.
- This is the TEMPLATE for porting the UI examples: scene via gl:anytype draw
  (drawCircleV) + UI via z.UiHost + real ui.zig widgets. Gate scene input below
  the panel rect (the input-priority lesson).
- Fixed drawCircleV wrapper (was missing the segments arg -> drawCircle).
- LINT NOTE: std.math.pi banned project-wide (GPU-portability) — use zm.pi even
  in host example code.
- The GL UI examples (simple_particles, ball_physics, ecs_boids,
  ellipse_collision) are AppBridge-shaped (run(init.gpa,...), initState(gpa,f,
  state), drawCircleV(gl,tex,...)). Porting each = convert app scaffolding to
  z.App/initState-returns-State + UI calls to z.UiHost + drawCircleV(gl,pos,r,
  col). Mechanical now that the pattern is proven; wgpu_particles is the
  reference. (Chose to write a fresh wgpu particle demo as the template rather
  than mechanically convert one GL example's scaffolding first.)
- NEXT: continue porting (more scenes/widgets as needed), Phase C (3D/PBR
  depth-aware pipeline), then delete GL + rename.
- PER-TURN zip (zimr931).


## ===== NaN PREVENTION in zm (turn ~932) — the recurring blank-frame class =====
ROOT of the recurring NaN bugs: zm.normalize3(v) = v / length3Splat(v) DIVIDES
BY ZERO when v ~= 0 -> NaN, NO guard. Used in shaders (rt_fs 7x, raytracer 6x) +
sims. A degenerate ray/scatter dir -> NaN -> black/white frame. (Same family as
the mandelbrot f32-overflow->NaN->white, and the particles dt-spike.)

THE DURABLE FIX — two new BRANCHLESS, GPU-SAFE zm helpers (verified to lower to
valid WGSL via naga; @select, no `if`, so SPIR-V/WGSL-safe):
  - zm.normalizeSafe3(v, fallback): returns `fallback` when length<eps instead
    of NaN (divides by sqrt(len_sq+eps), then @select). PREFER THIS over
    normalize3 anywhere input can be zero (ray dirs, scatter dirs, gradients).
    fallback = a unit vec (e.g. .{0,0,1,0}) or .{0,0,0,0}.
  - zm.finiteOr3(v, fallback): replaces NaN lanes (v != v) with fallback —
    sanitize accumulated shader values (color/position) before they leave a hot
    loop so one bad lane can't blacken/whiten the whole frame.
  Tests added (153 pass). Did NOT change normalize3 itself (silent behavior
  change across 70+ callers + a per-call branch cost); normalizeSafe3 is opt-in.

APPLIED: rt_fs's scatter normalizes -> normalizeSafe3(dir, normal). rt-shader
builds strict-clean, naga validates.

PARTICLES bug (separate, same "unbounded value" family): delta_time spikes to
seconds on a tab-switch/hitch -> particles flung off-screen in one step ->
vanish/black. FIX: clamp dt to 1/30s in the demo.

STANDARD GOING FORWARD: new shaders/sims use normalizeSafe3 (not normalize3) for
any possibly-zero vector, and finiteOr3 to sanitize hot-loop accumulators. This
is the systematic answer to the "degenerate -> NaN -> blank frame" class.
(Consider: a wgsl_check lint that flags raw normalize3 in shader files? Future.)
- PER-TURN zip (zimr932).


## NaN prevention refined + the BATCH-BUFFER bug (turn ~933)
- NaN helpers finalized per Simon: normalize3 now DEBUG-ASSERTS dot3(v,v)>0
  (gated `comptime !is_gpu`, so ZERO release/shader cost) — catches degenerate
  normalize in dev. The safe version is named safeNormalize3(v, fallback)
  (branchless @select, GPU-safe). finiteOr3(v, fallback) scrubs NaN lanes.
  Tests pass (153). rt_fs scatter dirs use safeNormalize3. Updated the old
  normalize3 test (it intentionally fed zero/NaN expecting NaN — obsolete under
  the assert contract).
- THE PARTICLES BUG (the real one, found by INSTRUMENTING not guessing): the log
  showed count=2112, p0 on-screen, sane dt — the SIM WAS HEALTHY; the canvas was
  black. Root cause: the 2D shapes batch's GPU vertex buffer was sized to the CPU
  staging size (MAX_BATCH_VERTICES=8192), but the batch auto-flushes when the CPU
  array fills and APPENDS at a running offset (distinct region per flush — no
  wrap, since same-pass draws reference earlier regions). A heavy frame (2000
  circles*16*3 ~= 96K verts) blew the running offset past the 8192-vertex GPU
  buffer -> out-of-bounds writes -> geometry silently STOPS rendering once enough
  shapes accumulate. (Would hit ANY wgpu demo drawing many shapes.)
  FIX: decoupled GPU ring size from CPU staging — added VBO_RING_VERTICES=262144
  / IBO_RING_INDICES=393216 (~5MB), sized the GPU batch_vbo/ibo to those; CPU
  staging stays 8192 (auto-flush threshold). + a safety-net wrap vs the ring cap
  for pathological frames. wgpu_particles now renders 2220 particles @110fps;
  shapes/ui-demo/mandel smoke clean.
- LESSON: instrument + read the data before theorizing (the dt-clamp was a
  non-fix; std.log routing made the diagnosis a one-shot).
- PER-TURN zip (zimr933).


## PLAN STATUS + PHASE C/D ASSESSMENT (turn ~934)

PHASE C (3D depth-aware WgpuGl) — ASSESSED, scoped as LARGE:
  The immediate-mode 3D path (beginMode3D + vertex3f) does NOT depth-test on
  WgpuGl because: (1) GroupVertex.pos is [2]f32 and vertex3f DROPS z; (2) the
  shapes pipeline uses default_shapes_vs (2D) with depth_format=.undefined_ (no
  depth state). Proper 3D-immediate needs: a 3D vertex format (keep z+w), a
  3D-aware VS applying the MVP to clip.z, a depth-enabled pipeline variant, and
  enable(.depth_test) switching current_shader to it + a pass depth attachment.
  That's effectively a SECOND render path in WgpuGl — substantial.
  IMPORTANT: the 3D MODEL/PBR demos (wgpu_cube_demo, wgpu_pbr_demo,
  wgpu_lambert_demo, wgpu_gltf_textured) ALREADY do proper depth-tested 3D via
  their OWN dedicated pipelines — that capability EXISTS. The gap is only the
  GL-style immediate-mode 3D (drawCube/vertex3f scenes). DEFER until a specific
  example needs immediate 3D; the model path covers real 3D.

PHASE D (bulk-port) — the high-ROI path, UNBLOCKED NOW:
  ~40+ GL examples are 2D-only (audio, ball_physics, basic, bouncing_ball,
  camera2d, collision_area, colors_palette, double_pendulum, easings_*,
  ecs_boids, ecs_solar_system, ellipse_collision, gallery, gestures_*,
  hello_world, hilbert_curve, image_text, imgui_demo, input_*, julia,
  kaleidoscope, life, lines_*, load_image_demo, mandelbrot, ...). All portable
  via the wgpu_particles template (z.App + initState-returns-State + z.UiHost +
  agnostic draw). Each is mechanical scaffolding conversion + keep the logic.

  imgui_demo (1150 lines, FULL ImGui surface — text/window/slider/sameLine/
  button/style/checkbox/tooltip/menu/tree/radio/child/selectable/popup/vSlider)
  is the HIGHEST-VALUE single port (proves the whole UI at scale). Its State is
  complex (s.* = .{...} + list appends + 2 font loads), so the conversion needs
  care: build `var s: State = .{...}` locally, do appends, `return s`; replace
  shapes_texture/font_cache/ui_ctx with z.UiHost; convert app scaffolding;
  loadFontFromTtfData/Bytes -> z.loadFont. NOT a rushed big-bang — give it a
  focused turn. (Staged copy was made + removed this turn to keep the tree clean
  until the conversion is done properly.)

CONVENIENCE GAP found: porting these needs more z.* surface still: z.colors
  named constants (have via types), z.loadFontFromTtfData (vs z.loadFont),
  gestures (z.getGesture...), audio (z.sounds/music — agnostic, re-export?),
  z.getMouseWheelMove (have), Camera2D pan (have). Audit per-example.

RECOMMENDATION for next turns: (1) a focused imgui_demo port (proves UI at
scale + flagship-worthy), (2) then batch-convert the simple 2D examples
(easings, lines, life, hilbert, input_*, hello_world — minimal surface), (3)
Phase C immediate-3D only if a target example needs it, (4) then delete GL +
rename.
- PER-TURN zip (zimr934).


## BULK-PORT STARTED: bouncing_ball (the proven recipe) (turn ~935)
- examples/wgpu_bouncing_ball: first bulk-ported GL 2D example. Builds + smoke
  PASSED + lint 0 + corpus 0. Renders (maroon ball, white bg, HUD, G/Space).
- THE CONVERSION RECIPE (established, minimal surprises):
  1. @import("zimr") -> "zimr_wgpu".
  2. State: drop `shapes_texture: ShapesTextureState` + `font_cache: FontCache`;
     add `font: z.Font` (no default).
  3. main: `z.AppBridge`->`z.App`; `run(init.gpa, .{...}, State, initState,
     update)` -> `run(.{...}, State, initState, update)`; add
     `pub const std_options = z.std_options;` + the TTF @embedFile.
  4. initState: `fn(gpa,_,s) !void` with `s.* = .{}` + loadFontFromTtfBytes ->
     `fn(gpa, f) !State` returning `.{ .font = try z.loadFont(f,gpa,ttf,size) }`
     (works when all other fields have defaults; else build `var s: State =
     .{...}`, mutate, `return s`).
  5. Draw calls: DROP the `&shapes_texture` arg —
     drawCircleV(gl,&shapes,pos,r,col) -> drawCircleV(gl,pos,r,col);
     drawText(gl,&font_cache,ID,text,x,y,size,col) -> drawText(gl,font,text,...).
  6. Build block: copy a UI-demo block (font asset, no shader), swap names.
- WORKED OUT OF THE BOX: color constants (c.raywhite/c.maroon via types),
  clearBackground (u8 now), isKeyPressed. Surface is mostly complete for 2D.
- NEXT batch (same recipe): hello_world (drawRectangleLinesThick — may need a
  wrapper), colors_palette (measureText — have), life (getMouseX/Y — check),
  easings_* (easings re-exported). Then UI examples + imgui_demo. Then GL delete.
- PER-TURN zip (zimr935).


## DEPTH-DEFAULT FOOTGUN FIXED (turn ~936)
- bouncing_ball was BLACK: it kept the GL window config (no depth field) so it
  inherited the App default depth_format=.depth24_plus -> pass got a depth
  attachment the 2D shapes pipeline (no depth state) can't match -> GPU
  validation error -> black. (Same footgun that hit the original sidebyside.)
- SYSTEMIC FIX: flipped the WindowConfig default to depth_format = null. The
  common case (2D/UI/shapes, ALL bulk-ports) uses the depth-less pipeline, so
  depth-by-default was exactly wrong. 3D demos opt in explicitly (cube/lambert
  via f.gpu.depth_format in initState; pbr/gltf via the config field) — all
  already do, so the flip is safe. Verified: bouncing_ball renders + smoke clean;
  cube/pbr/gltf still build (opt-in depth intact). lint 0, corpus 0.
- This makes EVERY future 2D port correct-by-default (no depth setting to
  remember). bouncing_ball is the proven recipe + now the depth default is right.
- PER-TURN zip (zimr936).


## DEPTH MISMATCH: runtime guard + the compile-time analysis (turn ~937)
Added a RUNTIME guard (the best achievable): PassState.has_depth (set in
beginRenderPass from desc.depth_view, accounting for the .invalid-wrapped-in-
optional sentinel — depth_view is a non-optional TextureViewHandle=.invalid
assigned into a ?field, so it's NON-null even with no depth; check `if (dv) |v|
v != .invalid`). flushBatch (the SINGLE chokepoint for ALL 2D shape+text draws,
via flushBeforeMaterialSwap) asserts !ps.has_depth -> a clear located panic
instead of the cryptic Tint "Attachment state not compatible" -> black. Verified:
bouncing_ball (depth=null) smoke PASSED; 3D demos (cube/pbr/lambert/gltf) don't
use the shapes batch so don't trip it; corpus exit 0, lint 0.

COMPILE-TIME ANALYSIS (Simon asked "can we make it not compile?"): considered
carefully. depth_format is effectively SET-ONCE (config literal or one
f.gpu.depth_format= in initState; never toggled per-frame), so a comptime
guarantee is TECHNICALLY possible — parameterize the engine by a comptime depth
flag: App(.{depth}) -> Frame(depth) and make beginDrawing/the shapes batch only
accept Frame(depth=false). REJECTED as a bad trade: it would thread a comptime
bool through App/Frame/WgpuGl/PassState/every draw fn/every example signature
(massive churn), BREAK the uniform `fn(gpa, f: *Frame) !State` signature that
makes examples portable + the bulk-port mechanical, and make the
`f.gpu.depth_format = .depth24_plus` initState pattern impossible. The bug is
ALREADY (a) prevented by the safe default (depth_format=null) and (b) caught
loudly by the runtime assert. Compile-time cost >> benefit here. CONCLUSION:
safe-default + runtime-assert is the right stopping point; documented so we
don't revisit.
- PER-TURN zip (zimr937).


## BULK-PORT: hello_world + 2D surface batch (turn ~938)
- examples/wgpu_hello_world: 2nd ported example (concentric outlined rects +
  text, responsive). Builds + smoke PASSED + lint 0 + corpus 0.
- ADDED 2D surface to wgpu_app/zimr_wgpu (unblocks many examples): drawLineThick,
  drawRectangleLines, drawRectangleLinesThick (4-edge outline), colorFromHSV
  (pure HSV->RGBA8). (getMouseX/Y already existed.) measureText already present.
- RECIPE EXPANDED with the remaining GL->wgpu deltas (now the COMPLETE set):
  * .scale -> .scale_mode (window config field rename).
  * f.window.screen_width/height is u32 on wgpu (i32 on GL); the wgpu draw fns
    take f32 coords (GL took i32). Promote demo layout coords to f32 (or @intCast
    /@floatFromInt at the boundary).
  * drop the &shapes_texture / &font_cache,id args from draw calls (recipe step 5).
  * GL window config may have fields wgpu lacks (.scale); remove/rename them.
- THE FULL RECIPE (steps 1-6 from turn 935 + these deltas) now ports a clean 2D
  example in a few minutes. Next: colors_palette, life, easings_*, then the UI
  examples + imgui_demo, then GL delete.
- PER-TURN zip (zimr938).


## ERGONOMICS: killed the int-cast smell (turn ~939)
Simon flagged the constant int<->float casting in ported examples as a smell.
Two recurring patterns, both now removed at the source:
- WINDOW DIMS: every layout-doing example did
  `@floatFromInt(f.window.screen_width)` (the draw API is f32 but WindowState is
  u32). FIX: added WindowState.widthf()/heightf() f32 accessors (next to the
  existing aspect()). Layout now reads `f.window.widthf()`.
- COLOR MATH: demos built a Color from float channels with `@intFromFloat` per
  channel. FIX: added Color.fromFloats(r,g,b,a) (0..1 -> Color, inverse of
  toFloats). Color.fade(alpha) already existed (use it for fade-out).
RESULT: casts in the 3 ported examples dropped 5/3/3 -> 1/1/1 (the remaining
ones are legit int<->float boundaries: emit-count from rate, loop-index). All
smoke clean, lint 0, corpus 0.
- THESE HELP EVERY FUTURE PORT: widthf/heightf + fromFloats are now part of the
  recipe — no cast boilerplate for window-relative layout or color math.
- (Found Color.fade already existed; deduped.)
- PER-TURN zip (zimr939).


## INT<->FLOAT CAST HELPERS in zm (turn ~940)
Simon: @floatFromInt / @intFromFloat is too noisy. MEASURED: 1139 @floatFromInt
(654 in the verbose @as(f32,@floatFromInt(..)) form), 598 @intFromFloat across
the codebase. Float target is f32 96% (747:30 vs f64); int target is varied
(i32 43, u16 10, usize 6, u32 4) + ~50 are @intFromFloat(@floor/@round(..)).

DESIGN: asymmetric pair (the data drove it). Added to zimrmath:
  - zm.flt(x) -> f32. Comptime-ASSERTS x is an integer (a float/bool is a
    COMPILE ERROR — verified: "zm.flt expects an integer; got f32"). SAFER than
    raw @floatFromInt (which accepts anything + infers the target): flt PINS f32
    + rejects non-int. `zm.flt(width)` vs `@as(f32, @floatFromInt(width))`.
  - zm.int(T, x) -> T. Comptime-asserts x is a float, T an int. `zm.int(u16, v)`.
  - zm.floori(T, x) / zm.roundi(T, x): the "to pixel" compound (floor/round then
    cast) — covers the ~50 @intFromFloat(@floor(..)) sites.
NAMING: tried one-letter `f`/`i` — BOTH collide (14 locals named `f`, loop
indices `i`) AND `f` clashes with the Frame param convention. So `flt`/`int`
(short, unambiguous, no shadowing). int needs T (no dominant target); flt is
bare (f32 ~always). 154 tests pass, lint 0, corpus 0. Applied in hello_world
(min_dim * zm.flt(i) / 12).

RECOMMENDATION (favorites, in order):
  1. zm.flt(x) for int->f32 — THE workhorse, terser AND safer. Use everywhere.
  2. zm.floori/roundi(T,x) for float->pixel.
  3. zm.int(T,x) for the rare explicit float->int.
  Roll out gradually (1700 sites — not a big-bang; convert as files are touched).
  Consider a lint that SUGGESTS zm.flt for @as(f32,@floatFromInt(..)) later.
- PER-TURN zip (zimr940).


## CAST HELPERS renamed flt -> float (turn ~941)
Simon: prefers whole words; "flt sounds like a fart". Checked: `float` has 0
decl/local collisions in zimrmath (unlike one-letter f/i). Renamed:
  zm.float(x) -> f32   (int->f32, comptime-asserts int; rejection verified:
                        "zm.float expects an integer")
  zm.int(T, x) -> T    (float->int)
  zm.floori/roundi(T, x)  (float->pixel)
Nice symmetry: float <-> int, both whole words. 154 tests pass, lint 0,
corpus 0, hello_world builds (min_dim * zm.float(i) / 12). THE recommended
helpers; roll out gradually across the ~1700 cast sites as files are touched.
- PER-TURN zip (zimr941).


## DECISION: NO blind global replace to zm.float (turn ~941b)
Simon asked: global-replace the common @as(f32,@floatFromInt(..)) -> zm.float?
ANALYSIS: 553 clean-form sites. CANARY: converted mandelbrot_fs (a SHADER) ->
zm.float — builds strict-clean + naga "Validation successful" (proves zm.float
lowers IDENTICALLY to the raw cast in SPIR-V->WGSL; safe in shaders). Kept that
one.
BUT the 488 src sites concentrate in files that are GOING AWAY or stable:
drawing.zig 262 (the GL renderer — to be DELETED), ui.zig 69 (GL parts go away),
rlsw_pixel/rlsw/render 71 (stable infra nobody reads). Converting them = high
churn, big diff noise, low value, and risks surfacing comptime-guard rejections
far from the active work (disruptive mid-port).
RECOMMENDATION (chosen): zm.float's value is ERGONOMIC AT AUTHORING — it helps
writing NEW code (the ports already use it), not reading old stable code. So:
  1. zm.float/int = standard for NEW code (done).
  2. Convert OPPORTUNISTICALLY when a file is touched for another reason.
  3. (Future) a lint that SUGGESTS zm.float on CHANGED files — adoption without
     a disruptive sweep.
NOT a big-bang replace. Rationale: don't churn doomed/stable files; don't risk
compile-error surprises across 1700 sites mid-bulk-port.
- PER-TURN zip (zimr941 updated).


## CAST CLEANUP DONE: @as(f32,@floatFromInt) -> zm.float in kept files (turn ~942)
Converted ~122 clean-form @as(f32,@floatFromInt(EXPR)) -> zm.float(EXPR) in the
files the wgpu side KEEPS (ui, codecs, types, sound, physics, scene, easings,
entities, wgpu_app, wgpu examples). DELETION-SCHEDULED files (drawing/rlgl/gl/
gl_iface/gpu, runtime) got a PASS. Inside zimrmath itself, used bare float()
(it IS zm). Only the simple no-nested-paren form (regex-safe); 16 nested ones
left by hand.
LATENT BUG SURFACED + FIXED (bonus): bisecting a corpus SEGV/ABRT revealed it
was PRE-EXISTING (present at the zimr940 baseline, NOT from the conversion) — my
turn-933 normalize3 debug-assert correctly catching a ZERO-vector normalize in
drawing.zig's getRayCollisionSphere (via v3Normalize). FIX: v3Normalize now uses
safeNormalize3(v, +Y fallback). The assert did its job — caught a real degenerate
normalize that was silently NaN-ing before. corpus now clean (no SEGV/ABRT).
LINT: 5 ui.zig locals lost their inferred type when @as(f32,..) -> zm.float(..)
(the @as gave the linter a visible type); annotated `: f32`. lint 0.
NOTE: the corpus exit code does NOT propagate test ABRTs (it reported exit 0
despite the ABRT) — a gate gap worth fixing later (the test failures only show in
stderr text, not the exit status).
DISK: ran out mid-build (252G full); cleared .zig-cache (5.2G) -> 73% free.
- PER-TURN zip (zimr942).


## CAST CLEANUP round 2 + inventory (turn ~943)
INVENTORY of remaining cast forms (non-deletion files): bare @floatFromInt 123,
@intFromFloat(@round) 19, simple @as(f32,@floatFromInt) 21, @intFromFloat(@floor)
7, @as(f64,..) 10, @as(iN,@intFromFloat) 4, nested-paren f32 10.
ATTACKED:
- The 21 simple @as(f32,@floatFromInt) finished (zimrmath internal -> bare float;
  2 examples -> zm.float). BUT zimrmath's 19 internal conversions caused a CORPUS
  SEGV (zimrmath's own 154 tests pass, but the full build SEGVs — a subtle
  behavior/rebuild flake in low-value internal/FFT code). REVERTED zimrmath's
  internal churn (low value, nobody reads it; not worth a SEGV). Bisected
  carefully: confirmed clean at zimr942, isolated to the zimrmath conversion.
- KEPT: 7 ui.zig @intFromFloat(@round/@floor) -> zm.roundi/floori (the
  `const NAME: T =` annotated form, T extracted from the LHS); the 2 example
  zm.float conversions. corpus clean, lint 0.
LEFT (lower value / riskier): bare @floatFromInt 123 (target inferred — need
per-site f32 verification), @round/@floor in .field=/return positions (ambiguous
T), f64 casts, zimrmath internals.
PRINCIPLE reaffirmed: convert the ACTIVE, readable surface; leave low-value
internals + deletion-scheduled files. The active non-deletion files now have ZERO
simple @as(f32,@floatFromInt) remaining.
- PER-TURN zip (zimr943).


## AGGRESSIVE cast cleanup in wgpu examples + shaders (turn ~944)
Swept the wgpu examples + fs shaders: 31 -> 4 real-code casts. Converted bare
@floatFromInt(SIMPLE) -> zm.float, @intFromFloat(EXPR) -> zm.int(T,EXPR) (host),
@as(f32,@floatFromInt(i)) -> zm.float(i) (shaders), and the f.window.screen_*
casts in mandel-sbs -> f.window.widthf()/heightf().
  - wgpu_sidebyside 8->0, rt_fs 5->4, mandelbrot_split 4->0, shapes 4->0(+comment),
    rt_shader host 3->0, raytracer 2->0, julia/mandel_julia/particles 1->0, the
    two fs shaders 1->0.

KEY FINDING: zm.float is SHADER-SAFE (lowers to SPIR-V, naga-validated in rt_fs +
the fs shaders), but zm.int/floori/roundi are HOST-ONLY — the comptime-T generic
CRASHES the Zig SPIR-V backend (exit code 3) when used in a shader. So:
  * In SHADERS: use zm.float for int->f32; keep raw @intFromFloat for float->int
    (the 4 remaining rt_fs casts are these, correctly left raw).
  * In HOST code: zm.float + zm.int(T,..)/floori/roundi all fine.
  (Consider documenting this on the helpers / a lint that flags zm.int in *_fs/_vs
  files.)
All wgpu demos build, smoke clean (sidebyside/mandel-sbs/particles), corpus 0,
lint 0. The wgpu examples are now ~cast-clean.
- PER-TURN zip (zimr944).


## "works on both backends or neither": zm.int/floori/roundi now BANNED on GPU (turn ~945)
Simon's principle: if zm.int(comptime_int,..) can't lower to SPIR-V, it must be
illegal on CPU too — so code can't silently work on CPU then explode when moved
into a shader. Added `if (comptime is_gpu) @compileError(...)` to zm.int, floori,
roundi (same is_gpu-gating pattern as the std.math ban). Now using them in a
shader gives a CLEAR compile error ("zm.int does not lower to SPIR-V... use raw
@intFromFloat...") instead of the cryptic exit-3 GPU-backend crash. CPU behavior
unchanged (guard is comptime is_gpu); 154 tests pass, corpus 0, lint 0.
- zm.float STAYS dual-backend (it DOES lower; naga-verified).
- The portable pattern for float->int in shared/shader code is raw @intFromFloat
  (which lowers fine). Documented on the helpers.
- This is the right "fail loud + early + portable-by-construction" discipline:
  the GPU-incompatibility is now a comptime error on EITHER target, not a runtime
  surprise. (Future: lint could still flag zm.int in *_fs/_vs, but the
  compileError already makes it impossible to ship.)
- PER-TURN zip (zimr945).


## CORRECTION: zm.int is NOT GPU-broken — it's a spv2wgsl TRANSPILER GAP (turn ~946)
Simon pushed back (correctly) on banning zm.int. DIAGNOSED properly:
- The Zig SPIR-V backend compiles zm.int fine (standalone repro: build-obj
  -target spirv64 emits valid SPIR-V for the comptime-T wrapper).
- The crash is in OUR spv2wgsl: `error.IrBuildUnsupported` — the structured-IR
  CFG builder can't reconstruct a particular control-flow shape that zm.int
  produces in SOME positions. The legacy-walker FALLBACK was DELETED (F5), so
  IrBuildUnsupported is now a HARD failure (exit 3), not a graceful fallback.
- It's POSITION-DEPENDENT: zm.int as a loop bound (`count`) transpiles fine;
  zm.int x3 in the seed XOR expression triggers IrBuildUnsupported. Not Debug
  safety checks (shaders are ReleaseFast). The exact CFG shape is one of the 7
  IrBuildUnsupported sites in ir_build.zig (capacity / OpSwitch / non-
  BranchConditional selection / loop-shape).
- So zm.int is NOT fundamentally GPU-incompatible — it works on CPU always +
  GPU in most positions. Banning it punishes the working cases. REMOVED the
  is_gpu @compileError bans I wrongly added.

CURRENT STATE: helpers unguarded (type-checks only). For SHADERS: zm.float works
everywhere (verified); float->int uses raw @intFromFloat (always reliable, it's
a builtin -> simpler SPIR-V) until the transpiler gap is fixed. rt_fs uses
zm.float + raw @intFromFloat; builds clean, corpus 0, 154 tests.

REAL FIX (tracked TODO): the spv2wgsl IR builder must handle the CFG shape
zm.int produces (or restore a fallback). This is the proper "works on both"
resolution — it's a transpiler completeness gap, the recurring theme (cf. the
phi-orphan, the var-result dedup, the // ERROR markers). Until then, raw
@intFromFloat in shaders is the documented portable path.
- PER-TURN zip (zimr946).


## ===== TRANSPILER BUG FIXED: StopStack [32] overflow (turn ~947) =====
Simon nailed the root cause: a FIXED-SIZE [32] array being busted. The
spv2wgsl IR builder's StopStack (the construct-nesting stack used to resolve
break/continue targets) was `items: [32]Stop` with `if (self.len >=
self.items.len) return error.IrBuildUnsupported`. A path-tracer shader (rt_fs)
with nested loops + material branches — DEEPENED by the extra blocks zm.int's
inlined body adds — exceeded nesting depth 32, turning VALID SPIR-V into a hard
IrBuildUnsupported (the legacy-walker fallback was deleted, so no recovery).
THAT'S why it was position-dependent: zm.int as a loop bound stayed under 32;
zm.int x3 in the seed XOR pushed nesting over the cap.

FIX (Simon's exact suggestion): StopStack.items -> std.ArrayListUnmanaged(Stop),
arena-backed, grows with the input. SPIR-V structured nesting is bounded by the
shader, not by us — the stack must too. The frozen 89KB failing repro
(/tmp/repro/fail.spv) now translates clean + naga-validates.

VERIFIED: rt_fs FULLY converted to zm.int (seed + count) — builds end-to-end,
naga "Validation successful", smoke PASSED. All shader demos (rt/mandel-sbs/
julia/mandel-julia/mandelbrot-split) translate clean through the fixed IR
builder. lint 0.

CONSEQUENCE: zm.int/floori/roundi now WORK IN SHADERS (the transpiler gap was
the only blocker). The "works on both backends" guarantee HOLDS — no artificial
ban needed. This was a real transpiler-completeness fix, the recurring theme
(phi-orphan, var-result dedup, // ERROR markers, now the [32] cap).

AUDIT: no other fixed [N] caps in the IR builder (StopStack was the last;
everything else is arena.alloc/slices). wgsl_check has [4096] line_starts +
MAX_IDS=1024 but those SILENTLY TRUNCATE (validator heuristic, not codegen) —
noted as a lower-priority correctness risk, not a crash.
METHOD that worked: froze the failing .opt.spv as a deterministic repro,
instrumented each IrBuildUnsupported site to find the firing one
(attachLoopMergePhis), then Simon's array-cap insight pinpointed StopStack.
- PER-TURN zip (zimr947).


## BULK-PORT batch: life + colors_palette + easings_ball (turn ~948)
Ported 3 more 2D examples (the plan's queue). All build + smoke PASSED + lint 0.
- wgpu_life (Conway, click+space), wgpu_colors_palette (swatch grid + labels),
  wgpu_easings_ball (cubic/elastic ball).
- Added surface: z.KeyboardKey export; the 25 ease* flat re-exports
  (z.easeCubicOut etc, mirroring GL zimr) in zimr_wgpu.
- DELTAS hit (all from the documented recipe — no new bugs):
  * f.time.current -> f.time.time (wgpu TimeState field).
  * measureText returns @Vector(2,f32) now (take [0]); GL returned i32 width.
  * draw fns take f32 coords -> @intFromFloat/@intCast coords become f32 or
    zm.float(intexpr); rect.* fields are already f32 (drop @intFromFloat).
  * multiline `&state.shapes_texture,` arg lines dropped (regex must handle
    multiline + both `s.`/`state.` var names).
  * `state.* = .{...}` resets must include `.font = state.font`.
- RenderTexture/beginTextureMode examples (lines_drawing, double_pendulum)
  DEFERRED — offscreen rendering not yet in wgpu.
- PORTED SO FAR: bouncing_ball, hello_world, life, colors_palette, easings_ball
  (+ the flagship shader/3D demos). Recipe is mechanical; ~3 examples/turn.
- NEXT: more 2D (input_*, gestures, kaleidoscope, hilbert), then UI examples +
  imgui_demo, then RenderTexture support, then GL delete.
- PER-TURN zip (zimr948).


## MOBILE: keyboard-gated actions need UI buttons (turn ~949)
Simon (on phone): the ported examples gate actions on KEYBOARD keys (space=pause
in life, enter=replay in easings) — no keyboard on mobile. FIX: added z.UiHost
(real ImGui) control panels with buttons.
- wgpu_life: "Life" panel — resume/pause toggle, clear, random buttons + a
  speed slider (1-60 Hz). Replaces space/c/r/1-9.
- wgpu_easings_ball: "Easings" panel — replay button. Replaces Enter.
- Keyboard shortcuts still work on desktop; buttons are the touch path.
- (easings "giant green screen" was NOT a bug — it's the animation FINALE: the
  ball expands to fill + fades; replay button lets you rewatch. Also fixed its
  screen_w i32->f32 in drawRectangle.)
RECIPE ADDITION: when porting an example that gates actions on keys, add an
equivalent z.UiHost button panel (the real ImGui works on wgpu now). State gets
ui_host: z.UiHost; initState builds z.UiHost.init(gpa, font); update does
ui.window(...) { buttons } + ui_host.render(f); any state.* = .{...} reset must
preserve .ui_host.
- OPEN QUESTION (Simon): easings ball scale on phone — the max radius (520) is
  tuned for 800x450 logical; phone aspect may fill differently. Revisit if it
  bugs; not blocking.
- All build + smoke + lint 0.
- PER-TURN zip (zimr949).


## ===== THREE FIXES: scissor flip, UI capture, recursion guard (turn ~950) =====
Simon's device testing + the StopStack fix surfaced three real bugs:

1. SCISSOR DOUBLE-Y-FLIP (UI panels clipped to wrong/mirrored region). ROOT:
   ui.zig -> drawing.shaders.beginScissorMode emits GL-convention coords
   (bottom-left origin: y_gl = render_h - (y+h)), but WebGPU's setScissorRect is
   TOP-LEFT origin. WgpuGl forwarded the GL-flipped y straight to WebGPU -> Y
   mirrored. Invisible in smoke (DPR=1 there means only the flip, not the scale,
   is wrong, and a vertical mirror still passes a no-trap test). FIX: WgpuGl.scissor
   UN-FLIPS: top_y = render_h - (y+h). Algebra recovers drawing's pre-flip dy
   exactly. (The mandel demos' z.beginScissorMode is a SEPARATE path —
   logicalToBacking, already top-left — so no double-un-flip.) Also unified the
   render-dim source: UiHost.begin reads f.gl.render_w/h (set by beginDrawing
   just before) so drawing.zig's render_h == WgpuGl's, no drift.

2. UI INPUT CAPTURE: dragging a panel painted the scene underneath. ui.zig has
   Ui.wantCaptureMouse() (active_id != 0 OR mouse over a window). FIX: gate scene
   input on it. Paint runs before the panel is built, so store last-frame's value
   (state.ui_capturing = ui.wantCaptureMouse() after the panel; gate paint on
   !state.ui_capturing). One-frame lag, imperceptible. wgpu_life done.

3. UNBOUNDED IR-BUILDER RECURSION -> STACK OVERFLOW. The StopStack [32]->ArrayList
   fix unblocked deep CFGs, which exposed that buildBlock->buildLoop->buildBlock
   recurses WITHOUT BOUND on adversarial/unstructured Tint fixtures (~12k frames
   -> segfault in a HashMap op). FIX: Builder.depth guard — bail
   IrBuildUnsupported past 4096 (far above any real shader; StopStack grows for
   LEGIT nesting, depth caps RUNAWAY recursion — distinct concerns). corpus now
   clean (168 ok, no SEGV), real shaders unaffected.

LESSON: each "unblock" (StopStack) can expose a latent bug in newly-reachable
code. The recursion guard is the safety valve the structurizer needed.
- Did NOT re-add the premature scissor assert (Simon: get it working first). UI
  windows now work in .responsive; .fit next.
- All green: corpus 0, lint 0, real shaders + UI demos build.
- PER-TURN zip (zimr950).


## BULK-PORT: input_keys + input_mouse_wheel + readme (turn ~951)
- Ported wgpu_input_keys (arrow-key ball) + wgpu_input_mouse_wheel (wheel box).
  Build + smoke + lint 0. Only delta: the recurring i32->f32 draw coords
  (zm.float). These are keyboard/wheel demos — show on phone but need those
  inputs to interact (could add buttons later, fine as desktop demos).
- readme.html rewritten: focus on zig-shaders/webgpu/raylib/imgui/sidebyside,
  brief on ecs/physics, non-enthusiastic, each subject once, Zig 0.17, no deps
  except Bun for smoke. All 20 wgpu examples listed + current build commands.
- LESSON: the build-block GENERATOR must wrap lines <120 cols (line-length lint)
  — keep the multi-line struct-field format, not compressed one-liners.
- Ported now (22): + input_keys, input_mouse_wheel.
- DEFERRED (need surface): basic/rl* immediate-mode (rlVertex shim),
  input_mouse (cursor API bridge), image_text (imageText/gpu), gestures
  (gesture API), lines_bezier (drawLineBezier), RenderTexture examples.
- PER-TURN zip (zimr951).


## BRIDGE SURFACE: ported dom functions from zimr.ts (turn ~952)
Simon: diff zimr.ts vs zimr_wgpu.ts, copy the ones we'll want. Did it.
- zimr.ts has ~60 dom functions; the wgpu bridge had 5 (js_log + persistence).
- KEY FINDING: the Zig-side `extern "dom"` decls already live in web.zig (which
  zimr_wgpu RE-EXPORTS) — only the JS IMPLEMENTATIONS were missing from the
  bridge. So adding impls to zimr_wgpu.ts + the raylib-named wrappers is enough.
- ADDED to zimr_wgpu.ts: js_set_cursor_style, js_set_mouse_cursor, js_set_title,
  js_get_dpi_scale, js_is_fullscreen, js_toggle_fullscreen, js_open_url,
  js_take_screenshot (adapted from zimr.ts: drop state., use the local canvas +
  wgpu readString). + cursor re-exports in zimr_wgpu (z.hideCursor/showCursor/
  isCursorHidden/setMouseCursor from the input namespace, + MouseCursor).
- PORTED wgpu_input_mouse (ball follows mouse, click=color, click toggles cursor)
  — validates the cursor API end-to-end. 23 examples now.
- PROCESS: each new dom fn ALSO needs a no-op stub in webtests/wgpu_smoke.ts (the
  shim has no real DOM) — added them.
- DEFERRED (complex, per-function adaptation + Zig state): the text-input OVERLAY
  family (overlay_input_*/overlay_textarea_*, ~25 fns for ImGui text fields/IME),
  clipboard, dropped-files, fetch. Add when an example needs them (ImGui text
  input most likely next).
- PER-TURN zip (zimr952).


## BRIDGE PARITY AUDIT: zimr_wgpu.ts vs zimr.ts (turn ~953)
Principle (Simon): the wgpu bridge should match the GL bridge fn-for-fn; every
difference needs a good reason; the new system must be BETTER. Did a complete
diff + closed every trivially-portable gap.

ADDED this turn (all adapted from zimr.ts: drop state., use the local canvas +
wgpu readString/getMemory): pointer-lock (request/exit/active), window
(set_window_focused/opacity/icon_png), crypto_random_fill, gamepad_vibrate,
panic, set_clipboard_text. (Prior turn: cursor + title + fullscreen + url +
screenshot.) All externs already existed in web.zig; smoke-shim stubs added.

EVERY REMAINING DIFFERENCE, CATEGORIZED:
  A) JUSTIFIED DIVERGENCE (different/better mechanism — will NOT copy):
     - js_start_loop / js_stop_loop: the wgpu host drives the frame loop via
       requestAnimationFrame -> the `update` export, not a Zig-controlled loop.
     - js_canvas_css_* / js_canvas_drawing_* / js_window_resized_take /
       js_canvas_set_size: WebGPU auto-tracks canvas.width; the bridge resizes
       the backing store itself and exposes size via getSurfaceSize/
       getSurfaceCssSize. No explicit canvas-size externs needed.
  B) STATEFUL — needs bridge state + event listeners; add WHEN AN EXAMPLE NEEDS
     IT (not blind-copy):
     - dropped-files (6): a droppedFiles[] + dragover/drop listeners.
     - clipboard read (get_clipboard_text/image_start): async-poll state machine.
     - text-input OVERLAY (~22: overlay_input_*/overlay_textarea_*/set_input_mode):
       a hidden <input>/<textarea> for ImGui text fields + IME. The big one;
       triggers when ImGui text input is exercised.
     - fetch (5): async fetch state machine.
  C) DONE: everything else (cursor, window, pointer-lock, clipboard-write,
     crypto, gamepad, panic, persistence, log, now_ms) is at parity.

So the bridge is at parity for all STATELESS dom functions; the only gaps are (A)
deliberate and (B) stateful-on-demand. All green: bundles, smoke, corpus 0.
- PER-TURN zip (zimr953).


## BULK-PORT: easings_box + easings_rectangles + collision_area (turn ~954)
3 more ported (26 total). Build + smoke + lint 0 + corpus 0.
- wgpu_easings_box (rotating eased box), wgpu_easings_rectangles (eased rects),
  wgpu_collision_area (two boxes, collision flips a strip red).
- ADDED surface: drawRectanglePro (rotated/origin rect; replicated from the GL
  gl:anytype impl as a wgpu_app native).
- Deltas hit (all known): f32 draw coords, measureText returns @Vector(2,f32)
  (take [0]), and my recipe script's `const zm = z.math` collides when the file
  already aliases zm -> the script must check first.
- DEFERRED: ellipse_collision (needs drawEllipse/drawEllipseLines), ball_physics
  (z.Ui -> UiHost), audio (sounds), gestures, image_* , the rl* immediate set.
- PER-TURN zip (zimr954).


## BULK-PORT: ellipse_collision + drawEllipse (turn ~955); + API philosophy
27 examples. Build + smoke + lint 0 + corpus 0.
- wgpu_ellipse_collision: two ellipses (cursor drives one), collision + a REAL
  ImGui panel (radio buttons + radius sliders). Uses the wantCaptureMouse gating
  (drawUiPanel returns the flag, scene input gated on it — the established
  pattern).
- ADDED surface: drawEllipse + drawEllipseLines, taking f32 coords (NOT raylib's
  i32) — a deliberate Zig-idiomatic improvement: removed @intFromFloat casts at
  the call site, matches the rest of the f32 draw API.
- PHILOSOPHY (Simon): raylib/imgui are the STARTING POINT, not a constraint.
  Where a Zig-idiomatic change clearly wins (and cost is justified), take it.
  E.g. f32 draw coords > raylib i32. (But NOT options-struct for drawRectangle —
  that breaks raylib-example parity for no real gain; evaluated + declined.)
  Be on the lookout for these.
- The z.Ui->UiHost conversion needs manual cleanup of leftover tex/font_cache
  ALIASES the recipe regex misses (const tex = &shapes_texture, const font =
  &font_cache) — grep for them after porting a UI example.
- PER-TURN zip (zimr955).


## BULK-PORT: ball_physics (turn ~956)
28 examples. Build + smoke + lint 0 + corpus 0.
- wgpu_ball_physics: bouncy balls in a box (LMB grab/throw, RMB spawn) + a REAL
  ImGui Physics panel (gravity/friction/elasticity/burst sliders + buttons).
  var-s+return initState (balls list w/ capacity + seed ball), wantCaptureMouse
  gating, UiHost.
- ADDED surface: isMouseButtonReleased (export), drawCircleLinesV (circle
  outline via line segments).
- UI-example conversion is now a known sequence: drop ui/shapes_texture/font_cache
  fields -> ui_host+font; ui_ctx.beginFrame/endFrame -> ui_host.begin + render(f);
  s.* = .{...} -> var s + return s; clean tex/font aliases; wantCaptureMouse from
  drawUiPanel gates scene input.
- PER-TURN zip (zimr956).


## BULK-PORT: hilbert_curve + easings_testbed (turn ~957)
30 examples. Build + smoke + lint 0 + corpus 0.
- wgpu_hilbert_curve (animated space-filling curve + order/thickness/speed panel),
  wgpu_easings_testbed (interactive easing-function grid). No new surface needed.
- FINDING: imgui_demo + imgui_phone_demo show "no z.* gaps" BUT both use
  inputText/inputTextMultiline -> the deferred TEXT-INPUT OVERLAY family. They're
  the natural trigger to build it; deferred until then.
- RECIPE ADD: GL helper fns taking *FontCache / *ShapesTextureState (e.g.
  drawHelpLine(f, font_cache, msg, y:i32)) must be converted to take z.Font +
  f32 coords -> drawText(f.gl, font, ...). grep for `*z.FontCache` / `*const
  z.ShapesTextureState` param types after porting.
- NEXT clean candidates need: Camera2D path (camera2d/kaleidoscope: beginMode/
  getScreenToWorld/getWorldToScreen/getMouseDelta), drawTriangle/drawTriangleLines
  (ecs_boids/gallery/input_virtual_controls), gestures, audio, image-editing,
  rl* immediate, RenderTexture. Each a focused unlock.
- PER-TURN zip (zimr957).


## easings_testbed touch panel + SPH file saved (turn ~958)
- Simon: "the ui panel in easings does not show up correctly" -> there was NO
  panel; easings_testbed is a pure KEYBOARD raylib example (arrows cycle easings,
  Q/W/A/S duration, ENTER/SPACE) so it rendered but was non-interactive on phone.
  ADDED a z.UiHost panel: two combos (X/Y easing), duration slider, play/pause +
  restart. Keyboard still works on desktop. First port to use ui.combo (with a
  comptime easing_names array so panel can't drift from easings_table; usize<->i32
  index bridge).
- SAVED reference/sph_fluid_2d_v5.html (a WebGPU SPH fluid sim Simon uploaded) —
  NOT touched yet, awaiting direction (likely a future example port).
- RECIPE NOTE: keyboard-only examples need a touch panel (recurring). When
  porting, check for keyboard-gated interaction with no UI and add controls.
- PER-TURN zip (zimr958).


## easings_testbed fixes: contrast + visible-by-default (turn ~959)
Simon: play/restart "do nothing", text light-gray-on-white hard to read.
- CONTRAST: help text + labels were c.lightgray on c.raywhite (unreadable on a
  bright phone). -> c.darkgray. (raylib used lightgray for de-emphasis; too low
  contrast — an "improve on raylib" fix.)
- "PLAY DOES NOTHING": root cause was the DEFAULT STATE — both easings = "None",
  so the ball advanced t but stayed at ball_start (looked frozen). The buttons
  WORKED; there was just no visible motion. FIX: default ease_x=Linear(0),
  ease_y=ElasticOut(23), start unpaused -> visible bounce on load.
- Panel itself (combos/slider/buttons) renders + works (scissor + combo solid).
- NOTE: panel is processed at END of update (after sim step) -> button effect has
  1-frame lag (imperceptible). Could move panel to top of update for same-frame +
  cleaner structure if desired; not a bug.
- LESSON: a demo's DEFAULT state should show something interesting immediately
  (don't ship None/None/paused). Check defaults when porting.
- PER-TURN zip (zimr959).


## SPH: CPU ported + compute plan (turn ~960)
- PORTED examples/wgpu_sph_fluid_2d (Clavet 2005, ~2000 particles, CPU sim + GL
  render + ImGui controls). First-try build, smoke + lint 0. 31 examples.
- FINDING: the uploaded reference/sph_fluid_2d_v5.html is the WebGL2/CPU build
  (wasm imports `webgl`, no compute) of the SAME algorithm — NOT a WebGPU-compute
  impl. Nothing to port from it; it's a UX reference only.
- Wrote src/notes/sph_compute_plan.md: a real GPU-compute SPH is buildable on our
  EXISTING infra (compute_pass + StorageBuffer + shader_compile's compute stage),
  but the spv2wgsl COMPUTE EMIT path is likely UNEXERCISED (no @compute/
  @workgroup_size in the emitter). PLAN: Step 0 = trivial compute repro to verify
  the pipeline emits valid compute WGSL + dispatches/reads back; THEN the
  scatter->gather SPH redesign (avoid WGSL's missing atomic-float). Do Step 0
  before committing to the algorithm.
- PER-TURN zip (zimr960).


## ===== GPU COMPUTE: studied + Step 1 shipped (turn ~961) =====
THE reason for wgpu. Studied the compute path by TRYING things — it's far more
ready than feared.
DISCOVERY (verified with hand-written kernels): the WHOLE compute path already
works. A kernel = `export fn main() callconv(.spirv_kernel) void` reading
std.gpu.global_invocation_id, with `extern var buf: T addrspace(.storage_buffer)`
+ `extern const p: P addrspace(.uniform)`. zig build-obj -target spirv32 emits
OpEntryPoint GLCompute; spv2wgsl ALREADY translates -> @compute, @builtin(
global_invocation_id), @group/@binding var<storage,read_write> + var<uniform>
(multi-buffer verified: 2 storage + 1 uniform auto-bound 0/1/2); naga validates.
GAPS were small: (1) workgroup_size hardcoded to 1, (2) no compute build helper,
(3) no compute DSL ergonomics.
STEP 1 DONE: spv2wgsl now takes --workgroup=X[,Y,Z] -> emits @workgroup_size(...)
(was hardcoded 1; Zig backend emits no LocalSize, so we inject). convertSpirvToWgslWg
threads it; convertSpirvToWgsl kept as the {0,0,0} wrapper (back-compat). Verified
@workgroup_size(64,1,1) + naga ok; fragment/vertex corpus unaffected (168 ok).
PLAN (src/notes/sph_compute_plan.md): Step 2 = end-to-end compute smoke (double_it
kernel: StorageBuffer upload -> dispatch -> readback -> assert; verify wgpu.zig
readback). Step 3 = compute externs generator (DSL: declare Buffers/Params/
WORKGROUP, no addrspace/callconv by hand). Step 4 = z.Compute(K) host wrapper
(comptime bind-group layout + .bind/.dispatch). Step 5 = real demos (particles,
then SPH multi-kernel w/ scatter->GATHER to dodge WGSL's missing atomic-float).
The hard part (transpiler does compute) is DONE; rest is ergonomics — the "make
it easy + fun" work that justifies wgpu.
- PER-TURN zip (zimr961).


## ===== COMPUTE DUALITY DESIGN — PROVEN (turn ~962) =====
Northstar: ONE SPH kernel, toggle CPU/GPU at runtime, identical source/results
(like zm fragment shaders run on both via rlsw). DESIGNED + verified the
mechanism by experiment: a single Zig module compiles to BOTH a native CPU object
(loop calls kernel) AND valid compute WGSL (naga ok).
PROVEN SHAPE: buffers at MODULE level in a comptime-selected `g` namespace
(extern storage_buffer/uniform on GPU; plain vars on CPU), kernel accesses g.B/g.P
DIRECTLY (NOT via *Buffers pointer — that hits a spv2wgsl let-copy/immutable bug),
GPU entry comptime-gated (callconv .spirv_kernel is SPIR-V-only). Fixed-cap arrays
([MAX]T; runtime-sized segfault the compiler). usingnamespace gone -> comptime
const g = if(is_gpu) struct{} else struct{}.
The kompute DSL will hide the g-namespace + entry boilerplate (mirror
gen_shader_externs). Host z.Sim(M): .cpu/.gpu toggle, run(kernel), cpuView. SPH
passes rewritten as GATHER (each id writes only its own slot) -> no atomic-float,
identical CPU/GPU, trivially parallel. Full design in src/notes/sph_compute_plan.md.
NEXT: S2 compute round-trip (StorageBuffer upload->dispatch->readback->assert).
- PER-TURN zip (zimr962).


## COMPUTE: plan rewritten + S2 started (turn ~967)
- Rewrote src/notes/sph_compute_plan.md: 112 precise lines, exploration archived.
  Foundation (verified) / risks (R1 atomics, R2 no-real-device) / 9 LOCKED API
  decisions (D1 k.Buffer(T), D2 enum-keyed ops, D3 readLatest frame-delayed, D4
  .pingpong+swap, D5 dim-inferred ctx, D6 atomic buffers, D7 canned prefixSum, D8
  punt shared-mem v1, D9 drawPointsFromBuffer) / 6 ordered build steps S1-S6.
- S2 STARTED: addShader gained workgroup_size:?[3]u32 -> --workgroup (compute
  stage), back-compat, regression-clean. R2 resolved: no real device in headless
  env -> S2 verified in-browser (render doubled buffer as bars). Host round-trip
  (bind groups/pipeline/dispatch/readback) + demo next.
- PER-TURN zip (zimr967).


## COMPUTE S2: host written (turn ~968)
- examples/wgpu_compute_smoke/wgpu_compute_smoke.zig: the first real GPU compute
  round-trip HOST, hand-wired, lint 0, ast ok. data_buf(STORAGE|COPY_SRC|COPY_DST)
  + params uniform + MAP_READ staging; bind layout/group via descriptor_encoder
  (uniform@0/storage@1); createComputePipeline; one-shot dispatch ceil(N/64);
  copyBufferToBuffer->staging; bufferRead* readback; renders result as a doubled
  HSV bar staircase (correctness visible in-browser since no real device in smoke).
- NEXT: the BUILD wiring. addShaderEx is bound to the fragment externs machinery;
  a self-contained compute shader needs a MINIMAL compute-WGSL build path
  (build-obj spirv32 -> spv2wgsl --workgroup, no sampler-rewrite/externs) -> embed
  double_it.wgsl. This minimal path seeds the S3 generator.
- PER-TURN zip (zimr968).


## PLAN CONSOLIDATION (turn ~971)
- Compute round-trip VISUALLY CONFIRMED on device (doubled staircase) after the
  minBindingSize fix. S2 truly done.
- Tightened src/notes/sph_compute_plan.md: S3-S6 now precise + decision-baked
  (S3 generates the proven double_it shape: g-namespace + module-level `b` +
  per-fn spirv_kernel entry + k.Ctx{id,params}; S4 host derives buffer size +
  min_size from @sizeOf(Buffers) — the minBindingSize footgun erased; S5
  particles + drawPointsFromBuffer + atomics verify; S6 SPH). 174 lines.
- claude.md: added a CURRENT-PLAN banner naming the two live plan files
  (wgpu_new_beginnings.md + sph_compute_plan.md) + an EXAMPLE PORT STATUS section
  (32 ported, ~125 remaining by category: ~79 2d/UI mostly text-overlay-blocked,
  19 3D, 7 rl-immediate, 5 render-texture, 4 audio, 4 touch, 2 gestures, 4
  cam2d-ecs). Fixed the stale WebGL2 intro -> WebGPU.
- DELETED src/notes/PLAN.md (stale 478-line roadmap; live pointers folded into
  claude.md). Repointed the 4 code comments that referenced it -> claude.md.
- PER-TURN zip (zimr971).


## TOOLCHAIN BOOTSTRAP + FIRST COLD BUILD (turn ~972)
- Fresh Linux sandbox brought up: zig 0.17.0-dev.639+284ab0ad8 + bun 1.3.14 staged into
  tools/ (extract 8s / 2s; chmod +x). PATH = tools/bun-linux-x64:tools/zig-.../:$PATH.
- COLD build of the compute-smoke standalone, single-core sandbox:
  `zig build wgpu-compute-smoke-standalone` = 166s, rc=0. Output
  prebuilt/standalone/wgpu_compute_smoke.html (3.1 MB, wasm b64-inlined) — delivered for
  the in-browser doubled-staircase verify (the S2 visual gate).
- SPIRV C++ TOOLS RETIRED (Simon, turn 972): spirv-opt/spirv-val/spirv-cross are no longer
  needed. The compute path is pure-Zig (addCompute: build-obj spirv32 -> spv2wgsl, and
  spv2wgsl is a main-build artifact via shader_pipeline.spv2wgsl_exe). PROOF: the standalone
  built FULLY GREEN with NO spirv binary present in tools/zig-out/bin (I killed the
  ~hundreds-of-file libspirv C++ compile partway; deleted tools/.zig-cache). Do NOT rebuild
  the C++ spirv tools on a cold sandbox.
  DOC DEBT: shader_codegen.zig's addShaderInternal (stages 2-4) + claude.md's bootstrap/pipeline
  text still describe the 4-stage spirv-opt/val/cross pipeline. Only the COMPUTE path is
  verified pure-Zig; the fragment/vertex addShader spirv-opt usage is unverified (though the
  umbrella shaders this demo pulls compiled with no spirv-opt present). Needs a doc pass +
  a check of whether addShader still references the dead tool paths.
- NAGA MISMATCH: the uploaded naga-main is gogpu/naga, a PURE GO port (WGSL frontend +
  SPIR-V backend, cmd/nagac, go.mod `go 1.25`) — NOT the Rust wgpu crate. The uploaded Rust
  1.96 toolchain cannot build it (wrong language) and nothing else in the pure-Zig project
  uses Rust. To stand up the verification gate we need a Go 1.25 toolchain. naga is
  verification-only -> does NOT block builds or deliverables. Rust 1.96 currently unused.
- PER-TURN zip (zimr972).


## NAGA VALIDATOR UP + claude.md PURE-ZIG DECLARED (turn ~973)
- naga (Rust naga-cli v29.0.0, gfx-rs/wgpu's WGSL validator) built from wgpu-trunk:
  `cargo build --release -p naga-cli` = 191s, staged at tools/naga-prebuilt-linux-x86_64/naga
  (build-time only, NOT shipped). (The earlier naga-main upload was gogpu/naga, a Go port
  needing Go 1.25 — wrong one; this Rust naga-cli is correct.)
- VALIDATION: ran naga over all 7 live WGSL this build emits (6 shader.wgsl from the umbrella
  module + the double_it compute.wgsl) -> 7/7 VALID, 0 fail. The pure-Zig spv2wgsl pipeline
  (incl. compute) produces naga-clean WGSL. compute.wgsl validating is the CPU-side S2
  confirmation, complementing the in-browser staircase.
- claude.md: marked the C++ SPIR-V tools OBSOLETE (pure-Zig pipeline; do NOT build them cold)
  in both the top banner and the bootstrap section; noted the WebGL/GLSL path is a doomed
  subsystem slated for deletion soon.
- STALE GATE SCRIPTS (next cleanup): scripts/naga-validate-tint.sh + naga-validate-corpus.sh
  (and `zig build naga-tint`) still hardcode ZIG=tools/zig-x86_64-linux-0.16.0/zig and
  SPV2WGSL=tools/zig-out/bin/spv2wgsl (removed) -> they fail until refreshed for 0.17 + the
  main-build spv2wgsl. Fix: ZIG=${ZIG:-zig} (PATH), source spv2wgsl from the main build (or
  rebuild just that tool), re-baseline tests/fixtures/external/naga-invalid-baseline.txt
  against trunk naga (baseline was cut at v29.0.3).
- PER-TURN zip (zimr973).


## CLEANUP + BOOTSTRAP HARDENING + VERIFY (turn ~974)
- BOOTSTRAP MADE EASY: new scripts/bootstrap-sandbox.sh (one command — extract zig+bun, build
  Zig tools + compute-smoke standalone as a proof, build+stage naga if wgpu-trunk+cargo present,
  prints the PATH export). claude.md bootstrap section rewritten for 0.17 + pure-Zig.
- C++ SPIR-V TOOLS GATED OFF: tools/build.zig builds spirv-opt/val/cross only under
  -Dspirv-tools=true (default false). `zig build`/lint (which depend on tools_subbuild for
  lint_zimr) no longer trigger the ~12-min libspirv compile. Cold bootstrap = zig+bun only.
- LINT FIXED + ROBUST: build.zig tools_skip_prefix "zig-x86_64-linux-0.16.0/" -> "zig-x86_64-"
  so the linter stops walking the (now-0.17) bundled toolchain stdlib (~hundreds of false hits).
  Fixed the one real pre-existing issue: src/spv2wgsl/sccp.zig:702 untyped local t_ops.
  `zig build lint` = 0 issues / 310 files, exit 0.
- NAGA GATES MODERNIZED: naga-validate-corpus.sh rewritten to validate the *.wgsl the pure-Zig
  build emits (dropped shader.opt.spv + spv2wgsl-reinvoke + the 0.16 path). naga-validate-tint.sh
  ZIG -> ${ZIG:-zig}. Both use tools/zig-out/bin/spv2wgsl (built by the Zig-only tools build).
- VERIFY: naga v29 validates 15/15 live WGSL (compute-smoke + wgpu_demo shaders), 0 fail.
  lint 0/310. compute-smoke standalone unaffected (confirmed working by Simon last turn).
- PRE-EXISTING ISSUE (deferred, NOT from this turn): `zig build wgpu-standalone` fails — wgpu_demo
  @imports mandelbrot_fs_io.zig / julia_fs_io.zig / mandel_julia_fs_io.zig, FileNotFound. The _io
  sources live at examples/*_io.zig and build.zig (~1463) wires them onto wgpu_demo_mod via
  addAnonymousImport, but inside `compiled_shaders.get(sh_name) orelse continue` — so when those
  fractal shaders aren't in compiled_shaders at that point, the _io import is skipped and @import
  falls through to a missing relative file. Build-graph shader-registration/ordering bug specific
  to wgpu_demo; the shaders themselves translate + validate fine. Fix: register the 3 fractal
  shaders before the wgpu_demo wiring block, or wire the _io imports unconditionally. tier-a — fix early.
- dawn-main (81MB Dawn/Tint) left in uploads as spv2wgsl inspiration only; NOT extracted/built.
- PER-TURN zip (zimr974).


## wgpu_demo FIXED — tier-a GREEN (turn ~975)
- ROOT CAUSE of last turn's wgpu_demo FileNotFound: compiled_shaders is gated with the GL
  examples (empty under -Dgl=false); the wgpu_demo block read it via
  `compiled_shaders.get(sh_name) orelse continue`, so the _io/.wgsl imports were skipped and
  @import("mandelbrot_fs_io.zig") fell through to a missing relative file.
- FIX (build.zig): wgpu_demo now OWNS its shader wiring (mirrors wgpu-mandelbrot-split):
  compiles mandelbrot_fs explicitly via addShaderEx (-> mandelbrot_fs.wgsl for the @embedFile)
  and wires the 3 fractal io schema modules (mandelbrot/julia/mandel_julia _io) directly,
  not via the GL-gated map. Dropped the unused shader_chroma_fs entry. Also wired
  addImport("zm") + ("shader_interface") onto wgpu_demo_mod (siblings had both; it had neither
  beyond zimr_wgpu) so wgpu_demo.zig:18 @import("zm") resolves.
- RESULT: `zig build wgpu-standalone` = rc 0 (incremental ~4s after the fix).
  prebuilt/standalone/wgpu_demo.html produced (2.5 MB). naga validates 16/16 live WGSL, 0 fail.
- ALSO FIXED (latent, was hidden by the lint mtime-stamp cache): 3 addWgpuStandalone calls
  (life/colors/easings) were single-line >120 cols (zig fmt had single-lined them for lack of a
  trailing comma). Split multi-line + trailing comma. `zig build lint` = 0/310 (cleared stamps).
- WHOLE-THING STATUS: lint 0/310; naga 16/16; wgpu_demo (tier-a flagship) builds + standalone
  produced; compute-smoke unaffected (confirmed working). Bootstrap is one command, C++ spirv
  tools gated off. Remaining red is only the doomed GLSL/WebGL path.
- PER-TURN zip (zimr975).


## GL/WebGL PATH UNPLUGGED FROM THE BUILD (turn ~976)
- Per Simon: remove glsl/webgl from the build system so wgpu is the only buildable target; do
  NOT delete files (still porting them). Removed from build.zig (~830 lines):
  - the 134-entry `examples` array + the ~370-line GL examples loop (the WebGL2 browser examples).
  - the `gl_enabled`/`-Dgl` flag + its two addOption calls + `examples_to_build`.
  - the GL-loop setup: `compiled_shaders` cache, `ShaderShare`/`cross_example_shader_shares`,
    `example_shaders` map + its population loop, `ShaderSpec` + the `shaders` spec table, `ExampleShaderEntry`.
  - the two `if (gl_enabled)` blocks (native sw_mandelbrot_pipeline + sw_fractal_gallery) and their
    orphaned step decls (sw-mandelbrot-pipeline, sw-fractal-gallery).
  - the zglsl main-build tool artifact + its shader_pipeline wiring.
- Example FILES untouched on disk (examples/*, GL runtime src). Just unplugged from the build graph.
- GREEN: `zig build lint` = 0/310; `zig build wgpu-standalone` = rc 0 (wgpu_demo.html 2.5MB); naga
  16/16 live WGSL. glsl mentions 54->34, webgl 11->10.
- DEFERRED (entangled; noted in build.zig at the old -Dgl comment): the engine-shader GLSL emission
  wires `.glsl` onto the GL runtime modules `zimr_mod`/`zimr_mod_smoke` (build.zig ~491-704) while the
  SAME engine shaders emit the `.wgsl` wgpu consumes. Removing needs: switch the engine emission to
  wgsl-only (drop the addShader GLSL path) + delete zimr_mod/zimr_mod_smoke (GL-only, ~21 refs, no
  wgpu importer) + the GLSL stages in shader_codegen.zig's addShaderInternal. zimr_mod is declared-not-built
  now (nothing in the wgpu graph depends on it), so harmless meanwhile.
- PER-TURN zip (zimr976).


## COMPUTE PLAN EVALUATION (turn ~977)
- Re-read sph_compute_plan.md + gpu-compute-tutorial.md; spiked the 2 riskiest unknowns:
  - multi-entry-per-file: NO (only first spirv_kernel export reaches WGSL) -> one kernel/file.
  - atomics: BLOCKED — Zig 0.17 SPIR-V backend has no `atomic_rmw` (compile error, pre-spv2wgsl).
- Consequence: the atomic grid (D6) + prefix-sum (D7) path is un-buildable for now. Recommended
  v1 grid = GATHER-ONLY fixed-bucket (each cell scans all particles into its own bucket; no
  atomics/scan/scatter; all-GPU; O(N^2/K), fine at 50k). CPU-built grid is the fallback.
- Other findings in sph_compute_plan.md "PLAN EVALUATION + SPIKE FINDINGS": dual-shape as a
  CPU-vs-GPU differential test oracle (addresses R2); cheap demo polish (stir/color/sliders).
- No code shipped this turn (analysis + plan/risk update). Spikes live in /home/claude/spikes.
- PER-TURN zip (zimr977).


## S3 DONE — kompute DSL landed (turn ~978)
- src/kompute.zig: the compute DSL. Provides Config; Globals(@This()) (if(is_gpu) extern
  storage/uniform vs plain var); Ctx(@This()) ({id, params}); installKernel(@This(), "name")
  (the spirv_kernel entry, exported via @export so the symbol == the kernel name -> host selects
  it with createComputePipeline(module, name)). Author file = config + Buffers (explicit
  [config.max]T arrays) + Params + `pub const g = k.Globals(@This()); const b = &g.B;` + kernel
  fns + `comptime { k.installKernel(@This(), "name"); }`.
- D1 k.Buffer(T) DEFERRED: clean synthesis needs @Type (removed in 0.17); v1 uses explicit
  [config.max]T arrays (the transpiler-proven shape). Buffers via module-level `b`, NOT a Ctx
  field (let-copy bug). Params by value in Ctx (verified ok).
- GOTCHA (verified this turn): a Params UNIFORM must pad with SCALAR fields (_pad0/1/2: u32),
  NOT an array — [3]u32 emits array<u32,3> stride 4, which naga REJECTS in `uniform` (needs 16).
- addCompute (shader_codegen.zig) now wires `--dep kompute -Mkompute=src/kompute.zig`.
- double_it.zig ported to the DSL form. wgpu-compute-smoke-standalone builds rc 0; the
  DSL-generated double_it.wgsl is naga-VALID (@compute "double", correct doubling). Host
  createComputePipeline "main" -> "double". lint 0/311.
- VERIFY (Simon): open wgpu_compute_smoke.html -> the doubled staircase should still render,
  now produced by the DSL rather than the hand-written kernel.
- NEXT: S4 — z.Compute(M) host wrapper (CPU loop + GPU dispatch; upload/run/readLatest; toggle).
- PER-TURN zip (zimr978).


## zimrmath UNIFORM IN COMPUTE (turn ~979)
- Verified zm (zimrmath) works in a COMPUTE kernel through the real pipeline (build-obj
  spirv32 -> spv2wgsl -> naga): vec2/splat2/dot2/length2/sqrt/floor/min/max/clamp/normalize/
  atan2 + vector arith all lower + pass naga (atan2 = the historically-risky one; OK).
  zimrmath is std/builtin-only. Math is now uniform across comptime / CPU / graphics / compute.
- kompute.zig re-exports zm as `k.math` (`const k = @import("kompute"); const zm = k.math;`).
  addCompute wires `--dep zm` for BOTH root and the kompute module.
- Regression-checked: double_it (no math) still builds rc 0 with the new kompute->zm dep.
  lint 0/311. Documented in gpu-compute-tutorial.md ("Math in kernels") + plan FOUNDATION.
- The turn-979 verification kernel (gravity integrate over zm.Vec2 + SPH ops) is the S5
  particle-integrate seed (/home/claude/spikes/mathkernel.zig).
- NEXT: S4 — z.Compute(M) host (CPU loop + GPU dispatch; upload/run/readLatest; toggle).
- PER-TURN zip (zimr979).


## S4 (CPU half) — z.Compute(M), CPU backend verified (turn ~980)
- src/compute_host.zig: z.Compute(M) — runs a kompute kernel module on CPU (a plain `for id`
  loop calling the kernel over M.g.B) or GPU (WGSL dispatch), runtime `.backend` toggle. Buffer
  + bind-layout sizes from @sizeOf(M.Buffers)/@sizeOf(M.Params) (the minBindingSize footgun
  erased). ONE storage buffer for the whole Buffers struct; per-field upload/read via @offsetOf.
  API: initCpu / initGpu(gpa,dev,queue,wgsl,name) / upload(.field,slice) / params / run("name") /
  readLatest(.field) (CPU: live slice; GPU: frame-delayed via bufferRead*). Exported as z.Compute.
- CPU BACKEND VERIFIED IN SANDBOX: host test runs a double kernel as a plain loop,
  [1,2,3,4,5]->[2,4,6,8,10]. Run it standalone (avoids the GLSL-red that blocks `zig build test`):
  `zig test --dep shader_interface -Mroot=src/compute_host.zig -Mshader_interface=src/shader_interface.zig`.
  lint 0/312.
- GPU BACKEND: written (mirrors the compute-smoke plumbing, parameterized) but NOT yet
  compile-verified — Compute(M) is generic and the test only calls CPU methods, so the GPU
  methods are lazy-unanalyzed; they compile when a wasm demo calls initGpu (next turn).
- `zig build test` is RED on the GLSL pipeline (zglsl/spirv-cross/spirv-opt, gated off) — the
  deferred turn-976 engine-GLSL unplug. Pre-existing GLSL KNOWN-RED, not this work. Gates:
  the standalone test above / lint / wgpu-check, until the engine-GLSL is unplugged.
- NEXT: S4 GPU half — rewrite wgpu_compute_smoke to use z.Compute(double_it).initGpu (forces the
  GPU backend to compile for wasm + verifies the staircase in-browser), then the CPU toggle.
  Needs a kompute module wired onto the demo's build module so it can @import double_it.zig for
  the schema. Then S5 (particle demo with the toggle).
- PER-TURN zip (zimr980).


## `zig build test` GREEN — WebGL/GLSL unplugged from the test graph (turn ~981)
- test was red because it DEMANDED the GLSL pipeline (spirv-opt/cross/zglsl, gated off). Three
  demands, all cut (engine emission's real .glsl + zimr_mod NOT touched — just no longer demanded):
  1. Host test_mod wired engine .glsl (s.path) so render.zig's @embedFile resolves. Now wires
     src/shaders/_deleted_glsl_placeholder.glsl for .glsl imports (host tests don't run GL; they
     only need it to COMPILE). build.zig ~3365.
  2. Removed the GLSL fixture-header check (fixture_glsl + fixture_check) from the test; the WGSL
     fixture check (fixture_wgsl_check) stays as the live gate. build.zig ~3857.
  3. Removed the GLSL math-pipeline check (math_full_glsl + math_full_check); zm verified via the
     WGSL/compute path (turn 979) + host math tests. build.zig ~3895.
  4. src/tests.zig: removed the `if (build_options.gl_enabled){...}` GL-test block (gl_enabled was
     deleted turn 976 -> dangling ref) + the now-unused build_options import. Those GL-path test
     files remain on disk for porting.
- Added `_ = @import("compute_host.zig")` to src/tests.zig so the z.Compute CPU-backend test runs
  inside `zig build test`.
- RESULT: `zig build test` = exit 0 GREEN. lint 0/312. wgpu-standalone + wgpu-compute-smoke-standalone
  build rc 0 (no regression).
- STALE NOTE: claude.md's KNOWN-RED block ("zig build test fails on the dying GLSL path") is now
  out of date — test is green; it's a usable gate again.
- NOT done (available, not blocking): the deep engine-GLSL/zimr_mod surgery (engine emission ->
  wgsl-only + delete zimr_mod). Test is green without it.
- NEXT: S4 GPU half — z.Compute(double_it).initGpu into wgpu_compute_smoke (compiles the GPU backend
  + verifies the staircase in-browser), then S5.
- PER-TURN zip (zimr981).


## S4 COMPLETE — z.Compute GPU half wired into the demo (turn ~982)
- wgpu_compute_smoke rewritten to drive its GPU round-trip through z.Compute(double_it).initGpu
  (replacing the hand-wired buffers/pipeline/dispatch/readback). This COMPILES the GPU backend for
  wasm (initGpu / upload-gpu / run-gpu / readLatest-gpu) — previously lazy-unanalyzed. Build rc 0;
  standalone wgpu_compute_smoke.html (3.05 MB); WGSL naga-VALID.
- The demo also runs a CPU-backend self-check at startup (z.Compute(double_it).initCpu over
  [1,2,3,4,5] -> [2,4,6,8,10]) and displays OK/FAIL — so it shows BOTH halves of the toggle in one demo.
- BUILD WIRING: wgpu_computesmoke_mod gets a `kompute` module (with zm dep) so the demo can @import
  double_it.zig natively for z.Compute(double_it)'s schema + CPU kernel.
- GATES GREEN: lint 0/312, `zig build test` GREEN (incl the compute_host CPU test), wgpu-standalone +
  compute-smoke-standalone build rc 0.
- VERIFY (Simon): open wgpu_compute_smoke.html -> doubled staircase (GPU via z.Compute) + "CPU backend
  self-check: OK" (green). Both backends, one demo = the CPU/GPU toggle.
- NEXT: S5 — the particle demo (gravity + wall bounce, one kernel, ~100k GPU / ~5k CPU toggle) using
  z.Compute + drawPointsFromBuffer (D9). The turn-979 mathkernel (gravity integrate over zm.Vec2) is
  the kernel seed.
- PER-TURN zip (zimr982).


## S5 (first cut) — GPU compute particle sim via z.Compute (turn ~983)
- examples/wgpu_compute_particles/: particle_step.zig (ONE kernel: gravity + unit-box wall bounce
  over zm.Vec2, pure gather) + wgpu_compute_particles.zig (the demo). z.Compute(particle_step) runs
  the sim; ~4096 particles spawn in a random upper fill, fall + bounce + settle.
- RENDER (first cut): from a frame-delayed CPU read of the pos buffer (pipe.readLatest(.pos)) ->
  drawRectangle per particle, hue by height. Works for BOTH backends (CPU: live slice; GPU:
  frame-delayed readback). NOT zero-copy yet (GPU reads pos back each frame); config.max capped at
  16384 to keep the per-frame readback ~256KB.
- CPU self-check in the demo (a particle at rest falls after one step) + a sandbox test in
  compute_host.zig (multi-buffer pos+vel gravity step -> pos.y == 0.1 after one step). Both prove the
  SAME kernel runs CPU-side.
- Build: a wgpu-compute-particles block (mirrors compute-smoke; kompute module wired so the demo
  @imports particle_step.zig for the schema). Standalone builds rc 0; kernel WGSL naga-VALID.
- GATES: lint 0/314, `zig build test` GREEN (incl the gravity test), standalone rc 0.
- VERIFY (Simon): open wgpu_compute_particles.html -> particles fall + bounce + settle into a pile,
  HUD "GPU compute: 4096 particles via z.Compute" + green "CPU backend self-check: OK".
- NEXT (S5 finish): drawPointsFromBuffer (D9) = zero-copy instanced render (vs reads pos[instance],
  var<storage,read>) -> scale to ~100k GPU, drop the readback; + a CPU/GPU toggle button (state
  transfer via readLatest->upload). Then S6 (SPH, gather grid).
- PER-TURN zip (zimr983).


## S5 — live CPU/GPU toggle on the particle demo (turn ~984)
- wgpu_compute_particles now AUTO-FLIPS z.Compute's backend every ~360 frames, carrying the live
  pos+vel across the flip (readLatest both fields -> transfer buffers -> upload to the new backend),
  so the SAME running sim seamlessly switches between a GPU compute dispatch and a CPU loop. HUD
  shows the active backend ("backend: GPU compute" / "backend: CPU loop").
- KEY: one pipe from initGpu runs BOTH backends — the kernel module's CPU globals (M.g.B) always
  exist, so flipping .backend + a state transfer is all it takes (no second pipe).
- The duality is now LIVE (not just a static self-check): particles keep falling across the flip.
- GATES: lint 0/314, `zig build test` GREEN, standalone rc 0.
- VERIFY (Simon): open wgpu_compute_particles.html -> particles fall/bounce continuously while the
  HUD cycles GPU <-> CPU every few seconds, the sim never resetting.
- STILL readback-render (not zero-copy). NEXT (S5 finish): drawPointsFromBuffer (D9) zero-copy
  instanced render -> scale GPU to ~100k + drop the per-frame readback. Then S6 (SPH, gather grid).
- PER-TURN zip (zimr984).


## ZTRACE logs removed + starfield_effect ported (turn ~1028)
- The combo blank-window bug (turn ~1026) is FIXED end-to-end — Simon's phone shows the
  "beginCombo custom content" panel rendering. The diagnostic ZTRACE breadcrumbs from that
  hunt are now noise, so REMOVED: 26 `std.log.err("ZTRACE ...")` statements (17 in
  src/wgpu_app.zig across run/beginDrawing/update + UiHost.init/begin/render; 9 in src/ui.zig's
  beginFrameRaw) plus their two trace-only locals (`const fc` in UiHost.render, `const dbg_first`
  in beginFrameRaw). The `UiHost.begin` precondition assertf (drawing_active) STAYS — that's the
  real guard, not a trace. Combo standalone rebuilt clean (1.175 MB, 0 ZTRACE).
- PORT: examples/wgpu_starfield_effect/ — the "warp drive" starfield (the fancier
  shapes_starfield_effect, distinct from the already-ported wgpu_starfield). 420 stars, 1/z
  projection, two render modes (lines = drawLineEx streaks / circles = drawCircleV discs) + a
  z.UiHost "Warp drive" panel (speed/mode/trail/colour sliders + Hyperjump respawn). Responsive
  (projects against live canvas size). GL UiContext+shapes+font_cache -> z.UiHost; star_color
  [4]f32 -> [3]f32 (wgpu colorEdit is RGB; alpha was never edited). No new engine surface — pure
  reuse of drawLineEx/drawCircleV/drawText + the existing ui widget set.
- Registered via the one-call addWgpuExample("starfield_effect", ...).
- GATES: lint 0/348, wgpu-starfield-effect-standalone rc 0 (1.187 MB), smoke PASS (init 28,
  ~611 calls/frame). Combo standalone also rc 0 + 0 ZTRACE after the log strip.
- Count: 44 GL originals ported -> a wgpu_ twin (59 wgpu demos total); ~124 GL examples remain.
- VERIFY (Simon): open wgpu_starfield_effect.html -> stars stream outward; toggle Lines/circles,
  drag Speed/Trail, recolour, hit Hyperjump. And the combo console should now be quiet (no red
  ZTRACE spam), just the panel.
- NEXT: keep porting clean 2D examples (procgen_noise needs the rl-immediate shim; physics_* need
  Camera3D — both are cluster-openers, not single ports), or pick up S5-finish (drawPointsFromBuffer).
- PER-TURN zip (zimr1028).


## Font: Atkinson preferred + misconfig warning fixed for UiHost (turn ~1029)
- FONT: Simon prefers Atkinson Hyperlegible Mono (examples/assets/fonts/atkinson_mono.ttf, OFL)
  over Roboto Mono for wgpu examples. addWgpuExample now wires it as a second anonymous import
  `atkinson_mono_ttf` (alongside `roboto_mono_ttf`), so any wgpu example can `@embedFile
  ("atkinson_mono_ttf")`. wgpu_starfield_effect switched to it. GOING FORWARD: prefer
  atkinson_mono_ttf for new ports' UI/HUD font. (The other ~live examples still embed roboto;
  a global swap is a one-liner sed per file, do it on request — not blanket-changed this turn.)
- WARNING FIX (ui.zig beginFrameRaw): the first-frame "style.font_size is N but style.font is
  null -> text renders BLANK" diagnostic was a GL-path artifact. It checked only `style.font`,
  but the wgpu `UiHost` supplies the TTF via the `font_cache` argument to beginFrameRaw/uiRenderNow
  and legitimately leaves `style.font` null — so it fired on EVERY correctly-configured UiHost app
  (text renders fine; layout uses style.font_size, render uses the supplied font_cache at that
  size — consistent). Fixed: warn only when neither a `style.font` NOR a loaded `font_cache` is
  present (`has_font = style.font != null or font_cache.loaded`), and the message now gives both
  the UiHost and GL fixes. Verified in the wasm: new message present, old gone. No render change —
  this only silences a false positive. (Net effect: combo/color_picker/easings/etc. UiHost demos
  no longer emit the spurious console warning.)
- GATES: lint 0/348, wgpu-starfield-effect-standalone rc 0, smoke PASS (init 28, ~611/frame).
- VERIFY (Simon): open wgpu_starfield_effect.html -> HUD + panel now in Atkinson (confirm it's the
  face you wanted), and the console should be quiet (no font warning).
- PER-TURN zip (zimr1029).


## Two UiHost ports: pomodoro + per-window menu bar (turn ~1030)
- Confirmed the cheap-port lever: ui.zig is the SAME file for both backends (gated by
  build_opts.ui_backend_wgpu), so every `u.*` widget a GL ui_* example uses already works under
  z.UiHost. Porting a ui_* example = a pure HARNESS swap (UiContext+shapes_texture+font_cache ->
  z.UiHost; AppBridge->App; initState out-param -> return; loadFontFromTtfBytes -> loadFont;
  beginFrame/endFrame -> begin/render) + the canonical draw-frame (beginDrawing/clearBackground
  BEFORE begin) + `ui.colorToU32`/`ui.DrawListHandle` instead of the `z.`-prefixed GL re-exports.
  Zero widget-availability risk. Both ports below use atkinson_mono_ttf.
- examples/wgpu_ui_pomodoro_phone/ — 25-min pomodoro, phone-shaped (420x760). beginCanvas ring
  (drawList addCircle track + addArc sweep + centred addText), `u.animated` green->red tween over
  the final minute, big touch buttons. Dropped the GL `phase_change_tick` field (it keyed nothing
  the wgpu animated() needs). dt from f.time.delta_time (not ctx.input).
- examples/wgpu_ui_window_menubar/ — three windows each with their own beginMenuBar (File/Edit/View
  + Tools + Help), menuItem shortcuts + selected checks, a foreground draw list About overlay +
  bottom status bar. Flipped the GL ordering bug (GL opened the UI frame before beginDrawing).
- LINT CAUGHT (good): the pomodoro tripped the AST linter on the GL original's SCREAMING_CASE
  consts (SESSION_SECONDS/WARNING_SECONDS -> snake_case) and a 3-param fn on one line
  (lerpColor -> one param per line, rule 1). Both fixed; lint runs as part of the example compile.
- Registered via two addWgpuExample one-liners.
- GATES: lint 0/350, both -standalone rc 0 (1.11 MB each), smoke PASS x2 (pomodoro ~296/frame,
  menubar ~2058/frame).
- Count: 46 GL originals ported -> a wgpu_ twin (61 wgpu demos total); ~122 GL examples remain.
- VERIFY (Simon): pomodoro -> Start, ring fills + recolours in the last minute, Pause/Reset work.
  menubar -> open menus on each window, toggle View items, Help->About flashes the overlay, drag a
  window and its bar follows.
- PER-TURN zip (zimr1030).


## Multi-app gallery ported + embeddability analysis (turn ~1032)
- examples/wgpu_gallery/ — the 2x2 multi-app demo (pulse / spinner / sparkles / counter) on wgpu.
  Made responsive (cells from live f.window dims each frame). Two GL-runtime effects aren't on the
  wgpu surface, so swapped: z.rng.Seeded/z.Rng -> std.Random.DefaultPrng; z.logger.Prefixed/Browser
  -> std.log with the sub-app name inlined (std_options routes to page). Draws drop the GL `tex` arg.
  GATES: lint 0/351, standalone rc 0 (757 KB), smoke PASS (init 28, ~226/frame). Count: 47 ported
  (62 wgpu demos); ~121 remain. First wgpu port to use the new fn-args ≤90 carve-out (4-param sub-app
  sigs on one line).
- HOW THE MULTI-APP WORKS (current, post-thin-frame): ONE real App = one module-scope `zimr_app` =
  one `update` wasm export = one draw frame per tick. Sub-apps are NOT Apps; they're plain tick fns
  `updateX(state, f, font, [rand], vp)`. The host's single update: beginDrawing+clearBackground ONCE,
  compute each cell rect, then per cell `beginScissorMode(rect) -> updateX(...) -> endScissorMode`,
  then endDrawing ONCE. Sub-apps draw in absolute coords offset by vp.x/vp.y; scissor hard-clips each
  to its cell. Shared: one Font, one frame. Per-child: state, RNG stream, viewport, log prefix. All
  explicit threading — the old parent.subFrame(...) (child Frame + vtable substitution + scoped
  viewport) was deleted in thin-frame, so there's no child Frame / no magic.
- CAN WE EMBED AN UNMODIFIED STANDALONE EXAMPLE AS A SUB-APP? Not byte-for-byte today, because a
  standalone example IS the whole-frame harness. Blockers: (1) it calls beginDrawing/clearBackground/
  endDrawing — once-per-frame, whole-canvas ops; clearBackground would wipe the other cells. (2) it
  sizes to f.window.widthf()/heightf() (full canvas) and draws at origin 0,0 — a scissor clips it to
  the cell but you'd see the top-left of a full-canvas layout, not a cell-fitted one. (3) one
  zimr_app / one `update` export per wasm — can't link 4 examples' main/zimr_app. (4) update(f,s) is
  a fixed signature with no viewport param, so a child can't be told "draw into this rect". (5) UI
  examples each own a UiHost -> 4 would fight over global mouse/focus/popup state.
- WHAT WOULD MAKE IT ZERO-MODIFICATION: a VIEWPORT-SCOPED Frame (re-add the capability thin-frame
  dropped, minus the vtable stuff): a push/pop viewport on WgpuGl that (a) offsets+clips all draws to
  a sub-rect, (b) overrides f.window dims to report the cell as "the window", (c) scopes
  clearBackground to fill only the active viewport (scissored clear / rect fill), (d) makes a child's
  beginDrawing NOT re-acquire the surface/pass (the host already opened the real frame) — just set
  the child viewport inside the open pass. (c)/(d) are the tricky bits (beginDrawing currently
  acquires surface + opens the render pass once/frame). With that, an example written normally
  (begin/clear/draw against f.window) would Just Work in a cell. It's a medium ENGINE task, not a
  per-example change — WgpuGl already has scissor + an ortho/viewport to build on. Until then,
  embedding = a light per-example refactor: split update into a no-begin/clear/end tick body that
  takes a viewport rect (exactly the shape the gallery sub-apps already have).
- PER-TURN zip (zimr1032).


## ===== CURRENT STATE + ROADMAP TO RETIRE WEBGL (turn ~1047) =====
(supersedes the stale counts/NEXT in older entries above — read THIS block)

### Descriptor migration DONE (turns 1033-1046; full detail in multiapp-refactor-plan.md)
Every wgpu example is now a DESCRIPTOR (`pub const app = z.AppSpec(State){ .config,
.init, .deinit, .update }`); the generic runner `src/wgpu_runner.zig` owns the wasm
entry + the frame. Registration = 3 helpers, all sharing buildUserMod + finishWgpuApp:
`addWgpuApp` / `addWgpuShaderApp(...,&shader_pipeline,...,&.{shaders})` /
`addWgpuComputeApp(...,&shader_pipeline,...,&.{kernels})`. `addWgpuExample` is DELETED.
58/63 wgpu examples are descriptor; 5 own-frame-3D demos are `[MANUAL EXCEPTION]`
(cube/lambert/pbr/gltf_textured/demo). FULL smoke `zig build smoke-test` = 59/59.
=> A NEW port is now CHEAP: harness-swap to z.UiHost (or a plain descriptor) + ONE
addWgpuApp line + a copied index.html. No main/zimr_app/std_options boilerplate.

### GAP: 47 GL originals ported / 145 total -> 98 remain (verify category per-example)
- **PORTABLE-NOW (harness swap, NO engine bridge) ~51** — the bulk, mostly `ui_*`
  (tables_basic/demo/scroll, dock_basic/persistence, drag_drop_demo/source/flags,
  log_skeleton/viewer, kanban, panes, drawlists, shortcuts, minimal_button/one_context,
  smoke_button, multiselect_finder, widgets_data_types, primitives_zoo, persistence,
  dev_tools, canvas, clipper, animation_gallery, mouse_drag, mini_plot, data_grid,
  custom_rendering, input_query, phone_gestures, polish) + CPU fractals
  (comptime_julia/comptime_mandelbrot, julia_gallery) + misc (keys, window_demo,
  ecs_solar_system, split_screen, text_layout). CAVEAT — a few here actually need a
  surface, recategorize on contact: audio_basic/music_streaming/composer_drum (AUDIO),
  png_demo/load_image_demo (IMAGE), gltf_simple_cube/gltf_textured_quad/mrt_demo/
  skinned_mesh_data (3D).
- **3D — Phase C (Camera3D + draw3d immediate + model/gltf load) ~15**: billboards,
  models3d, skybox, instancing, skinned_mesh, dynamic_mesh, first_person_camera,
  wireframe, physics_demo, physics_pyramid, damaged_helmet, gltf_simple/model_refs,
  text_on_texture, lenna_test.
- **rl-immediate shim (rlVertex/rlColor/rlSetTexture) 8**: basic, cube_split,
  image_editor, procgen_noise, rlsw_side_by_side, rtt, shader, shader_chroma_split.
- **TEXT-INPUT overlay (inputText/inputTextMultiline DOM bridge) 8**: imgui_demo,
  imgui_phone_demo, ui_code_editor, ui_full_showcase, ui_imgui_extras,
  ui_input_callbacks, ui_input_flags_zoo_phone, ui_notes_phone.
- **GESTURE/TOUCH 6**: gestures_demo/testbed, input_multitouch, input_virtual_controls,
  mandelbrot (pinch-zoom), touch_paint.
- **SOFTWARE rlsw 4**: sw_engine_shader, sw_fractal_gallery, sw_mandelbrot[_pipeline].
- **IMAGE/TEXTURE 3**: image_text, texture_readback, typed_unlit_demo.
- **SHADER (addWgpuShaderApp) 2**: sampler_derisk_test, shader_uniforms.
- **AUDIO 1**: audio_stream_synth.

### ORDERED ROADMAP -> "all ported, then delete WebGL"
1. **GRIND the ~51 portable-now** (no engine work; recipe proven by pomodoro/menubar/
   color_picker). Batch a few per turn; FULL smoke is the gate. **START HERE.**
2. **Bridge unlocks** (build the surface in zimr_wgpu, then port the cluster):
   a. Text-input overlay (8) — the biggest single bridge.
   b. 3D Phase C (15) — Camera3D + immediate draw3d + model/gltf load.
   c. rl-immediate shim (8) — rlVertex/rlColor/rlSetTexture.
   d. Gesture/touch (6), Image/texture (3), Shader leftovers (2), Audio (1), rlsw (4).
3. **RETIRE WEBGL**: once every example has a wgpu twin — delete the GL/WebGL2+GLSL
   backend, the GLSL generation + skip-list special-casing in zimr_build/tools, the
   `-Dgl` test block, and the [MANUAL EXCEPTION] blocks' GL deps; then rename
   `zimr_wgpu` -> `zimr`. That's the finish line this whole arc exists for.

### NEXT: grind portable-now in batches (this turn: first batch).

### Portable-now batch 1 (turn ~1047): 3 ui_* harness-swaps
Ported ui_smoke_button, ui_minimal_one_context, ui_tables_basic → wgpu descriptors
(z.UiHost; widget bodies unchanged — same real ui.zig). Recipe per port: new
examples/wgpu_<n>/ dir + descriptor .zig (drop UiContext+shapes_texture+font_cache →
ui_host: z.UiHost; init→loadFont+UiHost.init; update→clearViewport + begin/defer
render; drop main/zimr_app) + copied index.html (sed title) + one addWgpuApp line.
GATES: lint 0/356, 3 standalones rc 0, FULL smoke 62/62. Count: 50 GL ported / 95
remain (45 portable-now left, then the bridges). NEXT: continue the portable-now
grind (more ui_*, the CPU fractals comptime_julia/comptime_mandelbrot, keys/window_demo).
PER-TURN zip (zimr1047).

### Color system centralized in zimrmath (turn ~1049) — Plan A
The 6 scattered color reps + 2 conflicting packed-u32 byte orders are now ONE
system in `zimrmath.zig`. `Color` (sRGB bytes, raylib) lives there with the full
conversion set; the GPU-safe color MATH stays on `Vec` (vec4f) so it transpiles to
WGSL and runs identically CPU/GPU.
- `Color` methods: hex/toHex (human 0xRRGGBBAA, like CSS), toWire/fromWire (GPU
  draw-list 0xAABBGGRR = ImGui IM_COL32 — the two orders are now NAMED, not a trap),
  toFloats/toVec (sRGB 0..1), fromFloats/fromVec, toLinear/fromLinear (via
  srgbToLinear/linearToSrgb aliases of srgbToRgb/rgbToSrgb), toHSV/fromHSV (wrap
  rgbToHsv/hsvToRgb, hue in 0..1), lerp, fade=alpha, brightness, + the raylib palette.
- types.zig: `pub const Color = zm.Color;` (re-export; struct relocated out).
- Dedup (definition-only, callsites untouched): ui.colorToU32/unpackColor →
  Color.toWire/fromWire; draw3d.colorToF32 → Color.toFloats; toInt → toHex.
- Plan A (sRGB-passthrough for 2D, rgba8_unorm) kept; `toLinear` available for the
  3D/lighting path. GATES: lint 0/357, `zig build test` pass, full smoke 63/63.
- STILL TO DEDUP (follow-up, raylib-convention care needed — degrees vs 0..1, i32
  bitcast): drawing.zig free-fns (colorToHSV/colorFromHSV/colorAlpha/colorLerp/
  colorFromNormalized/colorToInt/fade), wgpu_app.colorFromHSV, ui-local scalar
  hsvToRgb/rgbToHsv (the colour picker), rlsw byteColorToFloats. And the bigger
  Phase-2: make DrawListHandle/drawing public APIs take `Color` (demote ColorU32 to
  the internal wire) so no example handles a packed u32.
PER-TURN zip (zimr1049).

### Color unification — wire helpers globalized (turn ~1050)
Removed the redundant wire-packing ALIASES; every callsite now names the one
canonical method (no aliases): `colorToU32(x)`/`z.colorToU32(x)` -> `Color.toWire(x)`
(232 sites), `unpackColor(x)` -> `Color.fromWire(x)` (25), `colorToF32(x)` ->
`Color.toFloats(x)` (5). Deleted the `colorToU32`/`unpackColor`/`colorToF32` defs +
the `zimr.zig` re-export. Used the STATIC `Color.toWire(x)` form (not `x.toWire()`)
so struct-literal args (`.{ .r=.. }`) still infer Color. GATES: lint 0, `zig build
test` pass, full smoke 63/63.
GOTCHA fixed: the first regex pass also matched the `fn <name>(` DEFINITION lines,
mangling them to `fn Color.toWire(...)`; deleted those. Lesson: a callsite sweep
must exclude `fn <name>(`.

STILL TODO (this arc), in order of care needed:
1. raylib free-fns (fade 47, colorFromHSV 23, colorLerp 8, colorToHSV 5, colorToInt
   4, colorAlpha 2, colorFromNormalized 2): centralize their LOGIC by delegating
   bodies to the Color methods. NOTE the unit/type seams — raylib ColorFromHSV/
   ToHSV use DEGREES (zm uses 0..1), colorToInt returns i32 (toHex is u32). DECISION
   for Simon: keep these as the raylib-parity public API (thin delegates), or drop
   them for method-only (`c.fade(a)` etc.) — the latter is a ~91-site sweep + breaks
   raylib muscle-memory.
2. Phase-2 Color-as-currency: make DrawListHandle/drawing add* take `Color` (demote
   ColorU32 to the internal wire). ~235 add* callsites + raw-u32 args need per-site
   conversion (not a clean replace) — its own focused turn.
PER-TURN zip (zimr1050; -pre is zimr1050-pre).

### Color: raylib free-fns logic-centralized (turn ~1051) — Plan A
Per Simon's A: kept the raylib free-fns as the public API, delegated their BODIES
to the centralized Color methods (one source of truth for the math; raylib names +
units stay). drawing.zig: fade->Color.fade, colorAlpha->Color.alpha, colorToInt->
@bitCast(toHex), colorNormalize->toVec, colorFromNormalized->Color.fromVec (+gains
raylib's clamp), colorToHSV->toHSV()*360 (raylib hue=degrees), colorFromHSV->
Color.fromHSV(.{h/360,..}), colorLerp->lerp(clamp t). wgpu_app.colorFromHSV likewise.
Verified each body's exact behavior + units before delegating. Left raylib-only
fns with no Color twin (colorTint/colorBrightness[-1,1]/colorContrast/colorAlphaBlend).
GATES: lint 0, zig build test pass, full smoke 63/63.
NOTE: colorFromHSV now uses zm.hsvToRgb (standard HSV) instead of the old seed
formula — equivalent, but colorFromHSV-heavy visuals (fractal coloring) are worth a
screenshot spot-check when those examples are next built.
STILL TODO: (a) ui.zig color-picker scalar hsvToRgb/rgbToHsv (22217/22242) — the
last duplicate HSV logic; internal to the picker, delegate carefully later.
(b) Phase-2 Color-as-currency in DrawListHandle/drawing add* (ColorU32 -> Color;
~235 sites + raw-u32 args need per-site conversion) — its own focused turn.
PER-TURN zip (zimr1051).

### Color: CPU/GPU HSV split + finish logic-centralization (turn ~1052)
- packF -> Color.fromFloats().toWire() (centralized the float-pack).
- FINDING (important, re "all zimrmath must work on gpu"): zm's Vec/SIMD color math
  (hsvToRgb/rgbToHsv, select-based) is GPU-safe (transpiles to WGSL) BUT produces
  wasm the validator rejects on the CPU path ("F32Eq left value type mismatch" —
  caught by the color_picker smoke). So zimrmath now carries BOTH:
    * hsvToRgb3/rgbToHsv3 — SCALAR [3]f32, the CPU form (wasm-safe).
    * hsvToRgb/rgbToHsv  — Vec, the GPU form (WGSL).
  Color.toHSV/fromHSV use the SCALAR ones (CPU). This also DEFUSED a latent bomb:
  last turn's drawing.colorFromHSV -> Color.fromHSV -> (Vec) zm.hsvToRgb would have
  failed wasm validation for any colorFromHSV-using example (none smoked yet, so
  hidden). Now Color.fromHSV is scalar -> safe.
- ui colour-picker hsvToRgb/rgbToHsv now delegate to zm.hsvToRgb3/rgbToHsv3 — the
  last duplicate HSV logic, centralized (scalar, CPU-safe).
- ALL color logic is now single-sourced in zimrmath (struct + conversions + scalar
  HSV (CPU) + Vec HSV (GPU) + sRGB/linear + wire). GATES: lint 0/357, zig build test
  pass, full smoke 63/63.
- LESSON: the smoke gate (full, no -Dfocus) is what caught the SIMD/wasm regression;
  a focused subset would have hidden it.
REMAINING (color): only Phase-2 — Color-as-currency in DrawListHandle/drawing add*
(ColorU32 -> Color; ~235 sites + raw-u32 args). Its own focused turn.
PER-TURN zip (zimr1052).

### zm color math: one function per op, all 4 targets (turn ~1053)
ROOT CAUSE of the color_picker wasm break: zm's Vec color math uses `@select`
(`select`) + vector comparisons (`r == v`, `v > cutoff`, `all(...)`), and the wasm
backend emits an `f32.eq` the validator rejects ("F32Eq left value type mismatch").
FIX (Simon's idea): a `comptime is_wasm` early-return SCALAR branch inside each Vec
fn; native + GPU(spirv) fall through to the faster SIMD path; both return the same.
Added `pub const is_wasm = builtin.target.cpu.arch.isWasm();` (next to is_gpu).
Branched: hsvToRgb, rgbToHsv, rgbToSrgb, srgbToRgb (+ scalar channel helpers
linToSrgbCh/srgbToLinCh). CONSOLIDATED: deleted the temporary scalar hsvToRgb3/
rgbToHsv3; Color.fromHSV/toHSV + the ui colour-picker now call the ONE unified
hsvToRgb/rgbToHsv (Vec) — wasm-safe via the comptime branch. So zm color fns now
work on wasm (scalar), native (SIMD, fast), GPU (SIMD -> WGSL), comptime (either).
GATES: lint 0/357, `zig build test` (native SIMD + color tests) pass, color_picker
wasm PASS, full smoke 63/63.
PATTERN for future zm fns: if a fn uses @select / vector compares (wasm-unsafe),
guard with `if (comptime is_wasm) { scalar } ...` — same value, SIMD where it helps.
NOTE: per-turn zips are now FULL PROJECT (minus caches/binaries), per the rhythm rule.
PER-TURN zip (zimr1053).

### Phase-2 DONE: Color-as-currency in the draw API (turn ~1054)
DrawListHandle's 18 add* methods now take `Color` (not ColorU32); each packs via
`col.toWire()` at the GPU boundary. `ColorU32` is now the INTERNAL wire only — the
raw `DrawList` + the vertex format still use it (perf), but NO public draw API does.
So no example handles a packed u32 anymore.
SWEEP: compiler-driven (changed the 18 signatures, let the type errors enumerate
the callsites). ui.zig: the few handle-using widgets (sparkline, splitter, canvas
demos) + tests -> pass Color / Color.fromWire(wire-hex). The internal draw* helpers
(drawRectFilled/drawTextAtS/...) + raw DrawList keep ColorU32 (the wire). Examples:
wgpu_ui_drawlists now holds `Color` consts (was wire-u32); custom_widget strips the
toWire; pomodoro's ring_col is a Color; window_menubar overlay uses named Color
consts (no inline hex).
GOTCHA: a global hex->Color.fromWire replace was TOO broad (hit raw DrawList test
calls that legitimately take ColorU32) — reverted + targeted only the handle calls.
The full smoke (not focused) caught the per-example breaks one cluster at a time.
GATES: lint 0, zig build test pass, full smoke 63/63.

### ===== COLOR ARC COMPLETE =====
Color is now the single currency: ONE struct (zimrmath), named byte orders
(hex/toHex 0xRRGGBBAA human; toWire/fromWire 0xAABBGGRR GPU wire), conversions
(toFloats/toVec/toLinear/toHSV + inverses), color math that works on wasm (scalar),
native (SIMD), GPU (SIMD->WGSL) + comptime via `is_wasm` branches, and Color-as-
currency in every public draw API. ColorU32 is purely the internal vertex wire.
PER-TURN zip (zimr1054, full project).

### Resume porting after restart: ui_tabbar_tour (turn ~1055)
RESTART CHECK: verified Phase-2 (Color-as-currency) was genuinely complete — wrapper
add* all take Color, lint 0, full smoke 63/63 — not partial. Did NOT redo it.
PORT: ui_tabbar_tour -> wgpu descriptor (UiHost harness swap). Exercises the TabBar
widget (closeable, leading/trailing pins, unsaved asterisk, force-select, overline).
IMPROVE: the GL original labelled the pins with ☰/⚙ glyphs that aren't in the ASCII
font (render as missing-glyph boxes) — swapped to ASCII "Menu"/"Cfg" so they render
+ read clearly. TabBar ui.zig reviewed: clean + well-documented (flags even self-mark
"NOT YET WIRED") — no change needed.
GATES: lint 0/358, standalone rc 0, full smoke 64/64. Descriptor examples: 63.
PER-TURN zip (zimr1055, full project).

### Port: ecs_solar_system (non-UI, turn ~1056)
GRAPHICAL ECS showcase ported to wgpu (453 lines; ECS logic verbatim, only the
harness + draw adapted). Exercises z.ecs end-to-end: Registry, Node.Tree
(parent/child, pre-order walk), CmdBuf (deferred spawn/destroy mid-iteration),
Tag classification, mixed-shape forEach. Adaptations: import; drop shapes_texture
(wgpu draw API manages it); main/zimr_app -> descriptor app spec + deinit (frees
cb+es); initState out-param -> return State; beginDrawing/clearBackground/endDrawing
-> clearViewport (runner owns the frame); renderEntity ctx `*z.GlState` -> `*z.WgpuGl`
and `drawCircle(gl, shapes, i32, i32, r, c)` -> `drawCircleV(gl, p.*, r, c)` (Pos is
a Vec2 — cleaner, no shapes/cast). z.colors.* (Tailwind palette) works on wgpu.
NOTE: comptime_mandelbrot/comptime_julia/julia_gallery are CLI/comptime demos
(std.debug.print, no window) — NOT wgpu ports; dropped from the portable-now list.
GATES: lint 0/359, standalone rc 0, full smoke 65/65. Descriptor examples: 64.
PER-TURN zip (zimr1056, full project).

### Non-graphics ported uniformly: comptime_mandelbrot (turn ~1057)
ENDGAME GOAL (Simon): EVERY example — graphical AND non-graphical/CLI — gets a
good, uniform wgpu version, so we can then DELETE all legacy examples losing
nothing. Approach for CLI/comptime examples: port to a uniform wgpu descriptor that
displays the output GRAPHICALLY, preserving the example's essence.
- wgpu_comptime_mandelbrot: the CLI ASCII fractal -> a uniform wgpu example. Keeps
  the essence (the Mandelbrot iteration runs at COMPILE TIME, baked as a const
  escape grid in read-only data; runtime does zero fractal math). Drawn as colored
  cells; runtime maps escape -> Color.fromHSV (the wasm-safe scalar HSV path). The
  7500 cells batch into ~46 GPU calls/frame. IMPROVED on port: snake_case consts
  (was SCREAMING — the linter's screaming-const rule), .fit window keeps the 4:3
  fractal aspect.
- STILL CLI -> to port the same way: comptime_julia, julia_gallery.
GATES: lint 0/360, standalone rc 0, full smoke 66/66. Descriptor examples: 65.
PER-TURN zip (zimr1057, full project).

### FLAGSHIP: one Zig shader on 3 targets (turn ~1058)
wgpu_mandel_sidebyside now runs mandelbrot_fs.shaderMain on THREE execution targets
side by side: CPU (rlsw dispatchFragmentShader, left), GPU (WGSL, right), and the
Zig COMPILER (comptime, corner inset). The comptime corner constructs `shader.Io`
per pixel and calls `shader.shaderMain(io)` inside a `const` blk (@setEvalBranchQuota)
— the fractal is evaluated at compile time, baked into read-only data, blitted at
runtime (it can't pan — it's literally a const). Uses the initial view+resolution so
all three are identical on load. PROVES shaderMain is target-agnostic pure Zig:
GPU + CPU + comptime, one source. GATES: lint 0/360, standalone rc 0, full smoke.
PER-TURN zip (zimr1058, full project).

### FLAGSHIP #2: ray tracer on 3 targets (turn ~1059)
NEW example wgpu_rt_sidebyside: rt_fs (a PCG-hash path tracer over a sphere scene)
on THREE targets, one Zig source: CPU (rlsw dispatchFragmentShader, left, 1/5 res),
GPU (WGSL fullscreen, right), and the Zig COMPILER (comptime, corner). The comptime
corner path-traces `corner_samples` rays/pixel at COMPILE TIME, averages, bakes a
clean const inset. rt_fs is pure (hash RNG, no GPU intrinsics) so it runs identically
on all three. Built by combining wgpu_rt_shader's buildUbo (Camera3D.rayBasis +
sphere scene) with the mandel_sidebyside CPU-rlsw + comptime-corner scaffold. CPU+GPU
render live (frame_seed varies -> the path-trace grain dances); corner is the clean
baked reference. GOTCHA: CpuFramebuffer.init takes 6 args incl a label.
GATES: lint 0/361, standalone rc 0, full smoke. Descriptor examples: 66.
PER-TURN zip (zimr1059, full project).

### rt_sidebyside polish + mandel corner Y fix (turn ~1060)
Three fixes from Simon's screenshot:
1. COMPTIME CORNER Y-INVERT: both side-by-side corners computed frag_tex_coord.y as
   (py+0.5)/rows, but the unified CPU/GPU convention is frag.y=1 at screen-TOP ->
   corner was upside down. Fixed to 1.0-(py+0.5)/rows in BOTH rt_sidebyside and
   mandel_sidebyside (mandel's was invisible — the set is symmetric about Im=0).
2. PANEL "scissor" issue was text OVERFLOW: rt panel text was ~44 chars, far wider
   than the panel — UiHost clipped it. Shortened to 3 short lines that fit (and they
   now advertise the controls). (Not a scissor bug — same scissor code as mandel,
   whose short panel was clean.)
3. PAN/ZOOM: rt_sidebyside now has an ORBIT camera — drag orbits (yaw/pitch around a
   fixed target), wheel + 2-finger pinch dolly (cam_dist). buildUbo takes
   (yaw,pitch,dist,frame_seed) and derives the eye via @cos/@sin (comptime-OK, so the
   corner still bakes). Live CPU+GPU follow the camera; the comptime corner stays at
   the initial view (it's a const — the "frozen at compile time" reference).
OPEN: non-fatal `wgsl: code is unreachable` warnings on transpiled rt/mandel shaders
(spv2wgsl artifact) — separate investigation.
GATES: lint 0/361, standalone rc 0, full smoke 67/67.
PER-TURN zip (zimr1060, full project).

### rt_sidebyside: fix .fit gap + touch drag-pop (turn ~1061)
Root cause of BOTH the left-half-height mismatch AND the UI-text "scissor" clipping:
the example used .scale_mode=.fit (copied from the GPU-only rt_shader), so the GPU
fullscreen pass covered the PHYSICAL canvas while the CPU present + the UI content
scissor (which y-flips using render-target dims) used LOGICAL coords -> the ".fit
inverse gap." Switched to .responsive (matching mandel_sidebyside) + buildUbo now
takes the resolution so the live render uses the LIVE canvas size {vw,vh} (camera
aspect tracks the window); the comptime corner passes the fixed design size. Fixed
BOTH issues. Also: touch swipe-start "popped" the camera — getMouseDelta's first
drag frame is a jump from a stale pointer pos; now we call getMouseDelta every drag
frame (keeps prev fresh) but only APPLY it from frame 2 on (s.dragging gate).
LESSON: side-by-side examples (CPU present + UI + fullscreen GPU) MUST use
.responsive, not .fit — .fit desyncs physical (GPU) vs logical (2D/UI) space.
OPEN: wgsl "code is unreachable" warnings (spv2wgsl) — still pending.
GATES: lint 0/361, standalone rc 0, full smoke 67/67.
PER-TURN zip (zimr1061, full project).

### CORE FIX: window text lagged chrome by one frame (turn ~1062)
Simon noticed UI window TEXT wiggling one frame behind the window CHROME while
dragging a window. Root cause in openWindow (ui.zig): the per-frame layout reset
(w.layout content cursor, computed from w.pos) ran BEFORE renderWindowChrome, but
renderWindowChrome's title-bar drag updates w.pos THIS frame. So chrome+content-clip
used the new (dragged) pos while widget layout used the old -> 1-frame text lag.
FIX: moved the w.layout reset to AFTER renderWindowChrome (it doesn't read w.layout),
so content uses the same post-drag pos. NOT inevitable — a pure ordering bug; ImGui
applies the move at Begin() for the same reason. Affects EVERY window (core ui.zig),
not just rt_sidebyside. GATES: lint 0/361, full smoke 67/67 (no regression).
PER-TURN zip (zimr1062, full project).

### rt_sidebyside: UI eats the input (turn ~1063)
Dragging the UI window also rotated the scene: the orbit gate used mouseOverPanel(),
a FIXED panel rect (the initial pos) — once the draggable window moved, the mouse was
no longer "over" that stale rect, so orbit fired (and even mid-drag the title bar
left the rect). Replaced with the UI's own ui.wantCaptureMouse() (active_id != 0 for
any drag/active widget, plus a hit-test against this-frame's windows). Recorded after
the window submits and read next frame (one-frame latency; the drag-start skip covers
the press frame). Removed mouseOverPanel + the ui_capturing field. Now hovering the
panel OR dragging the window/any widget suppresses the orbit. GATES: lint 0/361.
PER-TURN zip (zimr1063, full project).

### Batch port: 8 clean UI examples via migration helper (turn ~1064)
Wrote /tmp/gl2wgpu_ui.py (GL UI -> wgpu UiHost descriptor: imports, State (drop
font_cache/shapes_texture, ui_ctx->ui_host), main->AppSpec+deinit, initState
out-param->return, beginFrame/endFrame->begin/render, beginDrawing/clearBackground->
clearViewport). Ran it across the clean (no input(), no direct draws) UI examples.
PORTED 8: ui_canvas_demo, ui_animation_gallery, ui_clipper, ui_mini_plot_smoke,
ui_kanban_board, ui_drag_drop_demo, ui_tables_scroll, ui_polish.
Per-example fixups the mechanical pass needed (now known patterns):
 - SCREAMING_CASE consts -> snake_case (screaming-const lint).
 - int colors (0xAABBGGRR) passed to DrawList add* -> z.Color.fromWire(...) AND the
   holding var's `: u32` -> `: z.Color` (Phase-2 made add* take Color).
 - UiHost has no .style/.input/.drag_drop — those live on .ctx: s.ui_host.ctx.X.
 - z.ui.X (GL namespace) -> z.ui_real.X.
 - initState with post-init seeding: out-param->return broke it; use
   `var s: State = .{...}; ...seeding...; return s;` (brace-count to add return).
DROPPED 2: ui_dock_basic (uses z.ui_dock; wgpu docking is u.dockSpace — needs a real
port) and ui_log_viewer (imports js_overlay_input_is_visible — text-input overlay
not wired). GOTCHA: dropping a target leaves a STALE wasm in zig-out/wgpu-smoke/web;
the smoke re-tests it — must rm it (or clean) after unregistering.
GATES: lint 0/370, full smoke 75/75. Descriptor examples: 74.
PER-TURN zip (zimr1064, full project).

### Docking: simplest example + #9.1 fix (turn ~1065)
Studied the imgui docking branch vs ours; wrote a full tutorial (in outputs:
zimr_docking_tutorial.md). Our docking is a faithful binary-tree reimpl (split/leaf
nodes, request queue, recursive ratio layout, drag-to-dock + splitter + builder API).
FIX #9.1 (the one real functional bug): collapseEmptyLeaf + removeNode adopted a
surviving sibling's split/leaf into the parent slot but never copied sibling.flags,
so collapsing an emptied sibling silently DROPPED its leaf-affinity flags
(is_central, no_resize, no_tab_bar...). Added DockNodeFlags.union_ and now transfer:
  parent.flags = sibling.flags.intersect(transfer_mask).union_(parent.flags.except(transfer_mask))
— keeps the parent's structural bits (is_dockspace), adopts the survivor's affinity
bits. Regression test "9.1: collapse carries the surviving sibling's flags up" added.
NEW EXAMPLE wgpu_ui_dock_simple: full-window borderless host + u.dockSpace, builder
lays out Outline+Files (tabbed left) and Editor (central right) on first frame
(gated — dockBuilderSplitNode isn't idempotent); runtime drag-to-dock + splitter
work. GOTCHA: u.text uses a format string — literal { } in displayed code must be
{{ }}. Other documented issues left as deliberate/minor: #9.2 splitter 1-frame lag
(a decision), #9.3 non-recursive collapse (design), #9.4 layout abort on dangling
child (robustness), #9.5 over-constrained split (edge).
NOTE: cleared .zig-cache (hit its 6 GB guard from the session's builds).
GATES: lint 0/370, zig build test pass (incl #9.1), full smoke 76/76.
PER-TURN zip (zimr1065, full project).

### Docking fix: re-dock a floating window (region-based zones) (turn ~1066)
Simon (on phone) couldn't drop a floating window back into the dockspace. Root
cause: the drop zones were a small ~150px center CROSS per leaf with ~42px pull —
near-impossible to land on with touch; `hitTestDockTargetsInSubtree` returned null
unless the cursor was on the cross (`if (best_score <= 0) return null`).
FIX: added dockZoneFromRegion(node, mp) — region-based: the WHOLE leaf is a drop
target, cursor position picks the zone (outer ~30% band nearest an edge -> split;
inner -> center tab). Used as a fallback after the cross-snap (precise mouse keeps
the cross; everything else / touch uses the region). Also added a translucent
LANDING PREVIEW rect to renderDockTargetOverlay (dockLandingRect: full=tab,
half=split) so you SEE where it lands as the cursor moves. Updated 2 tests for the
new behavior (a point inside a leaf now docks; a no_split leaf tabs from any side).
GATES: lint 0/370, zig build test pass, full smoke 76/76.
PER-TURN zip (zimr1066, full project).

### Docking: THE re-dock bug — window-side link never synced (turn ~1067)
Last turn's region-zones made the drop EASY to aim, but re-dock still didn't take.
Real root cause: the only places that SET window.dock_node_id were dockBuilderDockWindow
(builder, ui.zig:6092) and tryRestoreDockTree (persistence, :41206). The RUNTIME
drag-to-dock path goes release-handler -> pending_requests -> processRequests, and
processRequests lives in the dock module with NO access to Window records — it only
updates leaf.window_ids. So a dragged window got added to the leaf's tab list but its
own dock_node_id stayed null -> openWindow kept rendering it FLOATING. That's why
builder-docking worked but drag-redock didn't.
FIX: added syncDockedWindowIds(ctx) — walks every dock node, sets
window.dock_node_id = leaf.id for each window in each leaf. Called in endFrame right
after processRequests. Idempotent; undock paths still clear dock_node_id; floating
windows (not in any leaf) untouched.
GATES: lint 0/370, zig build test pass, full smoke 76/76.
PER-TURN zip (zimr1067, full project).

### Docking: THE deeper re-dock bug — detach->drag handoff (turn ~1068)
The actual root cause (after the dock_node_id sync + region zones). The title-bar
press claims active_id only on a FRESH click (mc = mouse_left_clicked), never on a
held button. But detachAndStartDrag set `active_id = 0` while the mouse is HELD,
with a doc comment claiming "next frame's title-bar drag claims a fresh drag_id" —
it can't: mc is false on a held button. So after detaching a tab, the drag was
DROPPED (window didn't follow, active_id 0), and on release the handler
(`if active_id == drag_id`) never fired -> dragging_window left dangling -> no dock.
FIX: detachAndStartDrag now CLAIMS the title-bar drag id directly
(active_id = widgetId(w,"##drag_title")) + sets the press anchors
(active_id_press_x/value/screen), so the held-mouse continue-drag (keyed on
active_id == drag_id + md) picks up seamlessly and the release docks. Updated the
detach test (active_id is now the drag id, not 0). Together with turn 1067's
syncDockedWindowIds + turn 1066's region zones/preview, the full detach->drag->drop
re-dock works in one motion. Data-path unit test added too.
GATES: lint 0/370, zig build test pass, full smoke 76/76.
PER-TURN zip (zimr1068, full project).

### Docking: THE ROOT CAUSE — wgpu path never drained the dock queue (turn ~1069)
After 3 prior "fixes" (region zones, syncDockedWindowIds, detach handoff) re-dock
STILL failed. Instrumented the release + apply path with std.log; the trace showed
RELEASE fired with hit=true but NO "PR draining" log -> processRequests was never
running. Root cause: processRequests (+ syncDockedWindowIds) lived ONLY in
UiContext.endFrame(), but the wgpu UiHost.render() calls endFrameNoRender() (a
SEPARATE end-of-frame path). So on EVERY wgpu example, dock requests were enqueued
by the release handler and never drained -> nothing docked at runtime. (Unit tests
passed because they call processRequests directly.)
FIX: added `processRequests(&self.dock, ...); syncDockedWindowIds(self);` to the top
of endFrameNoRender. The prior 3 fixes were all necessary too (they make the drag,
zones, and link correct) — this was the missing piece that made the queue actually
get processed. LESSON: two end-of-frame paths (endFrame vs endFrameNoRender) drifted;
the dock-queue drain was added to only one. Watch for duplicated lifecycle paths.
DEBUG WORKFLOW: lint + `zig build test` per iteration (NOT full smoke); console
std.log tracing pinned it when inspection kept failing.
GATES: lint 0/370, zig build test pass, full smoke 76/76.
PER-TURN zip (zimr1069, full project).

### Docking: dock only ON a square (floating restored) (turn ~1070)
Now that drag-dock works, the turn-1066 region fallback (whole leaf = drop target)
was too eager — no way to leave a window floating. Reverted to CROSS-ONLY:
hitTestDockTargetsInSubtree returns null when best_score<=0 (cursor not pulled by
any of the 5 squares), so dropping off the cross floats the window; dropping ON a
square docks (center=tab, edge=split). Landing preview now drawn ONLY when over a
square (best_score>0). Removed the now-unused dockZoneFromRegion. Reverted the 2
tests I'd flipped in 1066 (no_split side zone -> null; off-cross point -> null).
GATES: lint 0/370, zig build test pass, full smoke 76/76.
PER-TURN zip (zimr1070, full project).

### Batch port: 5 more clean UI examples (turn ~1071)
Helper-ported 5: ui_drag_drop_source, ui_log_skeleton, ui_tables_demo,
ui_drag_drop_flags_tour, ui_multiselect_finder. Fixups: snake_case consts, .ctx.
access, z.ui_real; ui_tables_demo needed the var-s/return-s initState restructure
(post-init seeding). DROPPED (defer): ui_primitives_zoo_phone (8 hex + 32 draw-list
calls, 16 Color-type errors) and ui_custom_rendering (11 u32 + 5 draw-list) — both
drive the raw draw list with u32/ColorU32 colors; they need the deferred
Color-as-currency conversion (DrawList add* take Color now). Helper still trips on
4 (persistence, dev_tools, panes, input_query_demo) — they use the UI differently
(UiContext/beginFrame residual). GATES: lint 0, full smoke 81/81. Descriptor: 79.
PER-TURN zip (zimr1071, full project).

### Tier-A expanded + smoke scoped to tier-a (turn ~1072)
Tier-a (the per-turn smoke set) was 5: wgpu_demo(2D), wgpu_cube3d(3D),
wgpu_compute_smoke(compute), wgpu_shapes_showcase(shapes), wgpu_ui_color_picker(UI).
Expanded to 8 to cover the full feature range, adding: wgpu_mandel_sidebyside
(fullscreen shader + CPU softrender + comptime — the flagship), wgpu_ui_dock_simple
(docking), wgpu_ecs_solar_system (ECS). Updated all THREE sync'd places: the
-Dfocus help text, the `expanded` const in smoke-test wiring, and the
`tier_a_names` array in matchesFocus. Tried wgpu_gltf_textured (glTF) but it's
own-frame (not in the smoke install set) so it was silently skipped — removed it;
glTF coverage needs gltf ported to a descriptor or own-frame examples added to the
smoke. WORKFLOW: per-turn smoke is now `zig build smoke-test -Dfocus=tier-a` (8
wasms, fast) — NOT the full 81. lint + zig build test still run on everything.
GATES: lint 0/375, tier-a smoke 8/8.

### PERF DIAGNOSIS: tables_demo 23fps — table doesn't cull off-screen rows
~18319 WebGPU calls/frame (vs ~28 for simple examples, ~1443 for tables_basic).
Calls scale with TOTAL rows (100), not VISIBLE rows (~11). Root cause: the table
CLIPS (tableNextRowImpl pushClipRect on both channels for scroll) but does NOT CULL
— it still submits every cell's bg/border/text draws for all 100 rows; the clip rect
only stops off-screen PIXELS, not the draw calls. FIX (not yet done): a row clipper
(imgui's ImGuiListClipper pattern) — compute the visible row range from scroll_y +
viewport height, skip submitting cells for rows fully outside it. ~10x fewer draws
-> ~60fps. Secondary: per-cell rect<->text material swaps flush rlgl batches.
PER-TURN zip (zimr1072, full project).

### Non-UI port: keys (input demo) + the non-UI port pattern (turn ~1073)
First non-UI hand-port. Established the NON-UI conversion pattern (for the ~44 non-UI
examples): State drops shapes_texture + font_cache + browser logger, adds `font:
z.Font`; initState loads via `z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"),
size)` and returns; update: clearViewport (no begin/end), draw conversions:
 - drawText(gl, &font_cache, LAYER, text, ...) -> drawText(gl, font, text, ...)
 - drawCircleSector/drawRectangle/drawCircle: DROP the shapes_texture (`tex`) arg;
   drawRectangle is f32 (drop the @intFromFloat casts).
 - drawLineV(gl, p1, p2, color) -> drawLine(gl, p1[0], p1[1], p2[0], p2[1], color)
   (wgpu has no drawLineV).
 - z.colorLerp(a,b,t) -> z.Color.lerp(a,b,t) (not re-exported as z.colorLerp on wgpu).
GOTCHA: keys traps in the smoke at runtime — `@intFromFloat(1.0/delta_time)` with
delta_time==0 (first frame) -> inf -> unreachable. Guard 1/dt against dt<=0 (any
non-UI example computing FPS this way needs it). NOTE: window_demo is a browser-bridge
demo (clipboard/screenshot/fullscreen) — skip for now (many bridge deps).
WORKFLOW: validated keys with lint + `zig build test` + `-Dfocus=wgpu_keys` (focused
smoke), NOT the full suite.
GATES: lint 0/376, wgpu_keys focused smoke PASS.
PER-TURN zip (zimr1073, full project).

### Non-UI batch: input_multitouch + touch_paint + non-UI triage (turn ~1074)
Ported 2 more non-UI (touch demos): input_multitouch (one circle per finger) and
touch_paint (per-finger colored trails). Both use the slot-based touch API.
NON-UI TRIAGE (the ~44 graphical non-UI examples, by blocking API):
 - SAFE quick-wins (high-level 2D + input/touch only): touch_paint✓, input_multitouch✓,
   input_virtual_controls, text_layout, split_screen (+ mrt_demo/sampler_derisk_test/
   shader_uniforms which are likely shader/own-frame — verify before porting).
 - BLOCKED: rlgl immediate-mode (12: basic, shader, rtt, image_editor, procgen_noise,
   cube_split, ...), 3d (16: billboards, instancing, models3d, skybox, *_mesh, ...),
   texture load (15: png_demo, lenna_test, load_image_demo, ...), audio (4), gestures (2:
   gesture API not in zimr_wgpu), bridge (1: window_demo), camera2d (1: mandelbrot).
   These need their respective subsystems ported/translated (own-frame for 3d, rlgl
   immediate-mode translation, texture-load API, audio API, etc.).
GOTCHAS (touch family): z.MAX_TOUCH_POINTS is NOT exported on wgpu (use a literal);
getTouchPointId is NOT on wgpu (slot-based touch only — use the slot index as the id);
z.colors.Color.<raylibname> (orange/black/raywhite/darkgray) DOES resolve on wgpu.
drawCircle takes f32 cx/cy + a trailing segments:u32 (GL passed i32, no segments).
GATES: lint 0/378, focused smoke (touch_paint + input_multitouch) 2/2 PASS. Descriptor: 82.
PER-TURN zip (zimr1074, full project).

### input_virtual_controls ported + non-UI quick-wins EXHAUSTED (turn ~1075)
Ported input_virtual_controls (on-screen D-pad: touch-or-mouse, drawTriangle arrows +
drawCircleV buttons). drawTriangle on wgpu drops the shapes_texture arg (like the other
shape draws). TRIAGE CORRECTION — two of the "safe" candidates were misclassified:
 - split_screen is a full 3D Renderer/Scene demo (z.Scene + z.Renderer + z.gpu.Resources
   + 2 viewports + per-camera fog). My triage only flagged Camera3D/loadModel/drawMesh,
   not the high-level Renderer/Scene API. BLOCKED (needs the 3D scene subsystem on wgpu).
 - text_layout bakes a CUSTOM font atlas (loadFontFromTtfData + font_codepoints +
   bakeFontAtlas). wgpu has ONLY loadFont (Frame-based, ASCII) — no loadFontFromTtfData /
   loadFontFromTtfBytes / bakeFontAtlas. So the custom-atlas demo doesn't map without a
   wgpu font-baking API or a rewrite that drops its whole point. DEFERRED.
 - measureTextWithFont -> measureText is clean (wgpu's measureText takes a font now).
NET: the easy non-UI 2D ports are done (keys, input_multitouch, touch_paint,
input_virtual_controls). EVERYTHING else non-UI needs a subsystem: 3D Renderer/Scene
(16+split_screen), rlgl immediate-mode (12), texture-load (15), audio (4), gestures (2),
custom-font-baking (text_layout), browser-bridge (1). Next productive fronts: UI
helper-resisters (dev_tools/panes/persistence/input_query_demo — hand-ports) + docking
examples (ui_dock_basic/ui_dock_persistence), OR the draw-list Color-as-currency
conversion (unlocks primitives_zoo/custom_rendering), OR pick a subsystem to unblock a
whole family (rlgl immediate-mode = 12 examples is the biggest single unlock).
GATES: lint 0, wgpu_input_virtual_controls focused smoke PASS. Descriptor: 84.
PER-TURN zip (zimr1075, full project).

### TEXT INPUT on wgpu: shared DOM-overlay module ("the dom trick") (turn ~1076)
Canvas/wasm can't capture keyboard+IME, so text widgets need a hidden DOM <input>
overlaid on the widget rect (focus raises the soft keyboard; wasm polls the value
back). The GL runtime (zimr.ts) had this inline; the wgpu runtime (zimr_wgpu.ts)
didn't, so every text-input example was blocked (the wasm imports 10 dom.* overlay
fns; zimr_wgpu's imports.dom lacked them → instantiation fails when u.input() is
reached).
FIX (shared, no duplication): NEW src/web/overlay_input.ts — extracted the
single-line overlay from zimr.ts, host-abstracted (takes {getCanvas, getExports,
getMemory, readString}, owns its own <input> + flags in closure state). Exposes
makeOverlayInputDom(host) → the 10 dom fns (show/hide/update_rect/is_visible/
get_text + 5 setters), plus wasmRectToCss (backend-agnostic: runtime_* exports when
present, canvas-dims fallback exact under .responsive), rgbaU32ToCss, applyCharsFiltersJS.
 - zimr_wgpu.ts: `import {makeOverlayInputDom}` + spread into imports.dom with
   getExports:()=>null (wgpu doesn't track exports → fallback coord path, fine for
   .responsive). bun build resolves the import (bundle rc=0).
 - wgpu_smoke.ts makeDomShim: added 10 no-op stubs so text-input wasms instantiate
   headless (the real <input> only matters in a browser).
PROVED: ported ui_widgets_data_types (4 single-line inputs) — focused smoke PASS +
standalone builds. This UNBLOCKS the single-line text-input UI family on wgpu.
NOT DONE: the multiline <textarea> overlay (10 more js_*_overlay_textarea_* externs) —
examples using inputMultiline (e.g. ui_code_editor, log viewers) still blocked; same
pattern, add a makeOverlayTextareaDom to overlay_input.ts next. FUTURE DRY: zimr.ts
still has its own inline copy — refactor it to use the shared module + delete the inline.
GATES: lint 0, wgpu_ui_widgets_data_types focused smoke PASS, bundle rc=0. Descriptor: 85.
PER-TURN zip (zimr1076, full project).

### Text overlay FIX (DPR/offset) + dedicated text-field example (turn ~1077)
Overlay instantiated but didn't appear on phone — TWO bugs:
 1. DPR: I'd wired getExports:()=>null, so wasmRectToCss used ratio 1 (no DPR
    divide) → the widget rect landed ~DPR× offscreen on a phone (DPR 2-3).
 2. Offset: the standalone canvas is centered+padded (not viewport 0,0), but the
    overlay is position:fixed assuming 0,0.
ROOT FACTS: the wgpu wasm exports NO runtime_* fns, and zimr_wgpu.ts sizes the canvas
backing store to clientWidth×devicePixelRatio (canvas.width = render space). So the
correct, exports-free mapping is canvas-based: rect=canvas.getBoundingClientRect();
sx=rect.width/canvas.width (divides out DPR + any CSS down-scaling); css_x =
rect.left + x*sx (offsets by the canvas's on-screen position). Rewrote wasmRectToCss
to this; dropped getExports from OverlayHost + the wgpu adapter. (.fit letterboxing
would still need runtime_viewport_* — note for when the GL runtime adopts the module.)
ALSO: inputText imports an 11th dom fn js_set_input_mode (sets the <input> `inputmode`
for the mobile soft keyboard) — added to overlay_input.ts (copied from zimr.ts) + the
smoke shim. NEW example wgpu_text_field: a clear single-line text field (Name/Note via
inputTextWithHint, echoes typed text). The data_types inputs are all NUMERIC
(scalar/vec drag-edit) → overlay only on double-tap-to-type, which is why a plain tap
showed nothing; text_field is the tap-to-type test. NOTE: the positioning fix lives in
zimr_wgpu.ts (re-bundled per standalone), so only standalones built AFTER this turn
have it; rebuild older ones (e.g. data_types) to pick it up.
GATES: lint 0/381, focused smoke (text_field + data_types) 2/2 PASS, standalone built.
Descriptor: 86.
PER-TURN zip (zimr1077, full project).

### Text overlay ALIGNED + confirmed on device; debug removed (turn ~1078)
The mis-alignment was the coordinate space: wgpu_app makeFrame sets, for .responsive,
screen_width = wgpu.getSurfaceCssSize() = the canvas CSS size (clientWidth), NOT the
backing store (rendering supersamples at canvas.width = CSS×DPR but widget/layout coords
stay in CSS px). My earlier canvas.width divisor applied an extra ÷DPR → overlay shoved
toward the window origin on a high-DPR phone. FIX: wasmRectToCss divides by
clientWidth/clientHeight (ratio ≈1, no DPR divide) + getBoundingClientRect offset for the
centered canvas. Confirmed aligned on a real phone (Simon). Removed the temporary
on-screen debug readout (OVERLAY_DEBUG/debugReadout). Single-line text input is DONE on
wgpu: shared overlay_input.ts (11 dom fns incl. js_set_input_mode), wired into
zimr_wgpu.ts + the smoke shim; wgpu_text_field is the canonical demo.

### PORT PROGRESS: halfway — 72/144 GL examples ported, 72 remain (turn ~1078)
Remaining 72 by category (near-term-portable vs subsystem-blocked):
 PORTABLE-NOW (existing systems): ui:other ~13 (dev_tools, input_callbacks,
 minimal_button, data_grid_phone, input_query_demo, imgui_extras, input_flags_zoo,
 ...) — hand-ports; ui:docking 2 (ui_dock_basic/persistence — docking works, needs
 z.ui_dock→u.dockSpace translation); cli 6 (comptime_julia, julia_gallery, sw_* —
 graphical ports à la comptime_mandelbrot).
 MEDIUM: ui:draw-list(color) 4 (custom_rendering, full_showcase, phone_gestures,
 primitives_zoo — need the DrawList Color-as-currency conversion).
 SUBSYSTEM-BLOCKED: 3d/scene 18 (z.Scene/z.Renderer/Camera3D — biggest); rlgl 9
 (immediate-mode translation); texture 3 (loadTexture/drawTexture API); custom-font 3
 (imgui_demo/phone_demo/text_layout — loadFontFromTtfData/bakeFontAtlas); gestures 2
 (no wgpu gesture API); audio ~2 (audio API); bridge 2 (ui_log_viewer=multiline+clip,
 window_demo=clipboard/screenshot/fullscreen); + misc in "other" (mandelbrot=camera2d,
 mrt_demo/sampler_derisk=shader/own-frame, gltf_*=3d).
GATES: lint 0, wgpu_text_field focused smoke PASS, debug readout removed. Descriptor: 86.
PER-TURN zip (zimr1078, full project).

### Text input COMPLETE (multiline) + module cleanup; 2 ports (turn ~1079)
SYSTEM IMPROVEMENT: finished the text-input subsystem + tidied the shared module.
 - overlay_input.ts rewritten: hoisted rgbaU32ToCss / applyCharsFiltersJS /
   wasmRectToCss to MODULE level (wasmRectToCss now takes host) so both factories
   share them. Added makeOverlayTextareaDom (multi-line <textarea>: 10 dom fns incl.
   ctrl_enter_for_newline; lineHeight = fontPx×1.2; mirrors the <input> factory).
 - zimr_wgpu.ts spreads BOTH makeOverlayInputDom + makeOverlayTextareaDom into
   imports.dom; wgpu_smoke.ts makeDomShim got the 10 textarea stubs. bundle rc=0.
 Single-line AND multi-line text input now work on wgpu.
DECISION (review): NOT refactoring zimr.ts to use the shared module. The GL smoke.ts
 was RETIRED (no way to runtime-verify a zimr.ts change) and GL is being replaced by
 wgpu — touching the dying runtime is wasted risk; the duplication resolves when GL is
 deleted.
PORTS: ui_code_editor (inputTextMultiline + pushStyle("font_size") — no separate font),
 ui_log_viewer (the example originally dropped BECAUSE the overlay wasn't wired — now
 unblocked). Both needed: f.time.current → f.time.time, and the recurring initState
 var-s/return-s fix (post-init seeding after the helper's `return .{}`).
PAPERCUT (TODO improve): gl2wgpu_ui.py (in /tmp, not version-controlled) keeps emitting
 the broken `return .{}; <seeding>` for examples with post-init initState seeding +
 doesn't map f.time.current. Move it to tools/ + fix both. Next-turn improvement.
GATES: lint 0/383, focused smokes PASS (ui_code_editor + ui_log_viewer), bundle rc=0.
GL-ports: 74/144. Descriptor: 88.
PER-TURN zip (zimr1079, full project).

### System improvement: hardened gl2wgpu_ui helper → tools/ + 3 ports (turn ~1080)
Moved the UI migration helper from /tmp (unversioned) to tools/gl2wgpu_ui.py and fixed
the recurring papercuts so port() is now ONE-SHOT (no manual fixups):
 - initState transform rewritten: instead of `s.* = .{}` → `return .{}` (which made any
   post-init SEEDING unreachable + left `s` undefined — hit on tables_demo, ui_code_editor,
   ui_log_viewer), it now keeps `s` as a *State pointing at a local `result`
   (var result + const s = &result + return result), so the body — including loops that
   call func(s) and @memcpy(s.x,...) — is UNCHANGED. Robust for seeded + unseeded alike.
 - FONT-REMOVAL BUG fixed: when the font load is the LAST stmt in initState, the captured
   body ends at `);` with no trailing `\n`, so the removal regex `\);\n` missed it →
   leftover loadFontFromTtfBytes (which doesn't exist on wgpu). Changed to `\);\n?`.
 - Folded in: f.time.current→f.time.time, snake_case SCREAMING consts, .ctx accessors,
   inline z.ui.→z.ui_real. Plus a zimr_app residual guard.
PORTS (one-shot via the hardened helper): ui_imgui_extras + ui_input_callbacks clean;
 ui_data_grid_phone needed a small manual touch — it's a MIXED example (UiHost window +
 a header drawn via DIRECT z.drawText), so it keeps a `font: z.Font` in State and the
 direct drawText goes font_cache+layer → s.font (7 args). HELPER LIMITATION noted:
 pure-UI only; mixed UI+direct-draw needs the font-field touch.
RESISTERS still failing the helper (investigate next): ui_minimal_button (UiContext
 residual — likely a helper fn taking ui.UiContext), ui_input_flags_zoo_phone (main block
 not matched — non-standard main form).
GATES: lint 0/386, focused smoke (data_grid_phone + imgui_extras + input_callbacks) 3/3 PASS.
GL-ports: 77/144. Descriptor: 91.
PER-TURN zip (zimr1080, full project).

### PERF: kill the per-glyph flush — 15–164× fewer draw calls (turn ~1081)
data_grid_phone ran at 24fps. Root cause (found by adding a per-WebGPU-call-type
breakdown to wgpu_smoke.ts): 1731 draw_indexed/frame, each index_count=6 = ONE QUAD =
one glyph. NOT material swaps (only 6 set_bind_group) and NOT scissors (2). The text
path draws one quad per glyph via drawTexturePro, and drawTexturePro ended with
`gl.setTexture(0)` — a reset-to-white AFTER EVERY textured quad. That atlas→white swap
flushes the staged glyph, so each glyph became its own flush+draw.
FIX (two parts, both in the 2D renderer):
 1. wgpu_draw.zig bindTexture/setTexture: DEDUP — skip flushBeforeMaterialSwap + rebind
    when the target bind group equals the current one (was flushing on every call).
    Cut redundant binds to ~6, but alone didn't help (the reset still flushed).
 2. drawing.zig drawTexturePro: REMOVED the trailing `gl.setTexture(0)` reset. It was
    redundant — every draw fn binds its own material up front (shapes bind white, text
    binds the atlas) — and it was what forced the per-glyph flush. Now consecutive
    same-texture quads (a whole glyph run, a sprite sheet) batch into one draw.
RESULT (calls/frame): data_grid 8678→53 (164×), tables_demo 18319→264 (69×), log_viewer
14980→288 (52×), color_picker 2842→192 (15×), code_editor 2483→168 (15×). This also
RETIRES the earlier "tables_demo needs row culling" theory — the real cause was the
reset, and culling isn't needed at these sizes.
SHARED change (drawing.zig affects GL too, but GL is retiring + every draw fn rebinds,
so it's safe; full smoke 92/92 green). Kept the by-call-type breakdown in wgpu_smoke.ts
as a standing perf monitor. lint 0/386.
PER-TURN zip (zimr1081, full project).

### Font sharpness (DPR atlas) + row clipper on data_grid (turn ~1082)
TWO improvements on top of the draw-call batching fix:
1. FONT SHARPNESS (wgpu_app.zig loadFont): the 2D path renders into the backing store
   (CSS × devicePixelRatio), but the glyph atlas was baked at LOGICAL `size` → upscaled
   on a high-DPR phone (~2.75×) → blurry. Now bakes at size×DPR (DPR = backing/CSS
   surface size, clamped [1,4]); baseSize tracks the bake size so drawText/measureText
   still emit LOGICAL sizes (the scale divides it back out) — text is the same size,
   just ~1:1 with device pixels → crisp. Transparent to callers. (std.math is banned
   outside zimrmath → used zm.clamp; surface sizes are typed wgpu.SurfaceSize.) Headless
   smoke sees dpr=1 (surface css size path) so it's a no-op there; real DPR in browser.
2. ROW CLIPPER (wgpu_ui_data_grid_phone): wrapped the row loop in ui.clipper(n_rows,
   item_height) — only rows intersecting the scroll viewport are iterated + submitted.
   Bumped the demo to 500 rows to show it: 48 calls/frame (5 draws) — a 500-row grid
   costs the same as ~20 visible rows. The draw-call batching already fixed FPS; the
   clipper adds SCALABILITY (CPU loop + draw-list both shrink to the visible window;
   without it a big list overflows the 8192-vert batch into many flushes + burns CPU
   formatting off-screen cells). item_height = style.font_size + style.item_spacing[1].
GATES: lint 0/386, full smoke 92/92. PER-TURN zip (zimr1082, full project).

### Ported ui_shortcuts + ui_mouse_drag; UI backlog triaged (turn ~1083)
Ran the hardened helper over all unported UI examples. PORTED (one-shot harness, then
per-example direct-draw fixes): ui_shortcuts, ui_mouse_drag. Both are MIXED (UiHost
window + raylib-style DIRECT draws). The recurring fix pattern for mixed examples:
 - add a `font: z.Font` field + `.font = font`; direct drawText: &font_cache+layer →
   s.font (single- AND multi-line forms).
 - drawRectangleRec(gl, &shapes_texture, rect, color) → drawRectangleRec(gl, rect, color).
 - f.window.screen_width/height is u32 on wgpu → @intCast for i32 uses.
 - THE BIG ONE: wgpu draw fns take f32 coords; raylib/GL drawText/beginScissorMode took
   i32. So drop @as(i32,@intFromFloat(X)) and bare @intFromFloat(X) in draw-coord args
   (→ pass the f32), and flip i32 coord-var decls to f32 — BUT only where the var isn't
   also used in an i32 context (e.g. sw stays i32 for @divFloor, sh→f32 for drawText).
   This is per-line whack-a-mole; the helper can't safely automate it.
DEFERRED with reasons: ui_dock_basic (uses z.ui_dock → needs the wgpu dockSpace/
dockBuilder translation; do with the docking batch); ui_phone_gestures (foreground
DrawList with u32 colors → the Color-as-currency batch w/ custom_rendering/full_showcase/
primitives_zoo); RESISTERS still failing the helper (dev_tools, panes, persistence,
input_query_demo, minimal_button, input_flags_zoo_phone, imgui_demo, imgui_phone_demo,
ui_notes_phone) — UiContext/beginFrame/main-block residuals, need per-example harness
investigation.
GOTCHA (self-inflicted): the non-greedy "unregister X" regex `addWgpuApp\(...?"X"` spans
BACK across earlier addWgpuApp blocks — deferring phone_gestures silently removed
mouse_drag's registration too. Remove registrations by matching the block whose name
field is X, not "first addWgpuApp( up to X".
GATES: lint 0/388, full smoke 94/94. Descriptor: 93.
PER-TURN zip (zimr1083, full project).

### MAJOR: build.zig registration corruption found + repaired; color ports landed (turn ~1084)
ROOT CAUSE (multi-turn, severe): my ad-hoc "defer example X" edits used a non-greedy regex
`addWgpuApp\(\n(?:[^\n]*\n)*?        "X",` to delete a registration. Non-greedy from the
FIRST addWgpuApp( spans FORWARD across every intervening block to reach "X", silently
deleting ALL registrations in between. Used repeatedly (turns ~1061-1083) this unregistered
23 examples. CRITICALLY, every smoke kept reporting green (94/95 wasms) because the web-dir
RETAINS STALE WASMS — `smoke-test` runs whatever .wasm files exist in zig-out/wgpu-smoke/web,
not the current build.zig registrations. So the greens were fiction for ~20 turns of drift.
DETECTION: re-registering one example, the fresh smoke still omitted it; auditing AppSpec
dirs vs build.zig showed 23 unregistered. Cleaning the web-dir + fresh smoke dropped 95->71,
exposing the gap.
REPAIR: restored zimr1082's clean build.zig baseline; re-registered all 23 with CORRECT
functions — 6 shader examples (mandelbrot_split, julia, mandel_julia, mandel_sidebyside,
rt_shader, rt_sidebyside) via addWgpuShaderApp, recovered VERBATIM from zimr1060 (last
snapshot with shaderApp blocks intact, incl. their &.{"X_fs","wgpu_trivial_vs"} shader lists);
17 via addWgpuApp (incl. the 4 genuine ports shortcuts/mouse_drag/custom_rendering/
primitives_zoo, and kaleidoscope/starfield/raytracer/sidebyside which classify as plain app —
no _io imports). Deleted the whole web-dir so the smoke can't mask anything.
RESULT: 95 AppSpec dirs, 0 unregistered, fresh smoke 94/94 (94 = 95 - gltf_textured which is
own-frame/excluded), lint 0/390. This is the first TRUSTWORTHY smoke in many turns.
LESSONS: (1) NEVER unregister by non-greedy span - match the block whose name FIELD == X, or
delete by exact line range. (2) `rm zig-out/wgpu-smoke/web/*.wasm` before a "verification"
smoke; stale wasms silently mask unregistration/compile-skips. (3) audit AppSpec dirs vs
registrations periodically.

COLOR PORTS (the actual request): the draw-list examples split by which API they use.
 - custom_rendering uses the RAW *ui.DrawList (u.getDrawList(), takes u32 + explicit gpa) -
   unchanged GL<->wgpu, ports AS-IS with NO color conversion (earlier "drop for Color errors"
   was a misdiagnosis). ~360 draws/frame.
 - primitives_zoo uses the Color-taking HANDLE (c.drawList()): converted 8 hex literals to
   z.Color.fromWire(0x...) AND flipped 7 `const X: u32 = fromWire(..)` color-var decls to
   `: z.Color`. ~90/frame.
 - DEFERRED: full_showcase (beginFrame/endFrame helper-resister), phone_gestures (both a
   mixed direct-draw AND foreground-DrawList example).
GATES: lint 0/390, fresh full smoke 94/94, 0 AppSpec unregistered. PER-TURN zip (zimr1084).

### Ported 4 resisters via helper hardening (turn ~1085)
After the build.zig repair, cracked 4 of the helper-resisters. ROOT CAUSES + fixes:
 - gl2wgpu_ui.py residual guards (UiContext/beginFrame/zimr_app) checked the WHOLE source
   incl. // comments -> false residuals on persistence/dev_tools. Fix: strip // comments
   before the guard (code = re.sub(r"//[^\n]*","",s)).
 - input_query_demo used `ui_ctx: ui.UiContext = undefined` (field) + `s.ui_ctx =
   ui.UiContext.init(gpa)` (statement). Added a `= undefined` field replace AND a late
   catch-all `ui.UiContext.init(gpa)` -> `z.UiHost.init(gpa, font)` (the literal pass only
   caught the struct-literal `.ui_ctx = ...` form; after s.ui_ctx->s.ui_host the statement
   form escaped it).
PER-EXAMPLE fixes after the harness ported:
 - dev_tools/persistence: UiContext FIELDS (metrics, persistence_key) live on ui_host.ctx,
   not ui_host -> routed via .ctx; dev_tools `ui.debugLogSlice(&s.ui_host)` ->
   `&s.ui_host.ctx`.
 - imgui_phone_demo: dropped `style.font = &s.font_cache.font` (wgpu UiHost supplies the font
   via init(gpa, font); the manual set referenced the removed font_cache field).
 - input_query_demo: `inline for (std.meta.fields(ui.KeyCode))` is a Zig 0.17 @compileError;
   neither fieldNames (needs deref) nor @typeInfo(T).@"enum".fields worked cleanly here ->
   used `std.enums.values(ui.KeyCode)` iterating the enum values directly (kc == .MAX guard,
   @intFromEnum(kc), @tagName(kc)).
STILL RESISTING (harder, deferred): ui_panes (a source-display string array literally
contains "ui_ctx: ui.UiContext," so the `, 1` field replace hits the STRING first), 
ui_minimal_button (3 UiContexts), imgui_demo (State var is `state` not `s`),
ui_input_flags_zoo_phone + ui_notes_phone (main block not matched), ui_full_showcase
(beginFrame/endFrame residual).
NOTE on verification: had to `rm -rf .zig-cache` (hit 6GB guardrail) so the confirming smoke
was a COLD rebuild. GATES: lint 0/394, COLD full smoke 98/98, 0 AppSpec unregistered.
PER-TURN zip (zimr1085).

### Browser testing of ported resisters — 2 findings (turn ~1086)
Simon tested dev_tools + imgui_phone_demo in-browser (loaded via content://downloads).
1. PERSISTENCE (ui_persistence) "never persists across reload": NOT a code bug. The
   localStorage backend IS wired (zimr_wgpu.ts js_persistence_save/size/read, "zimr_" prefix)
   and IS bundled in the standalone. Root cause: loading from content:// (a downloaded local
   file) — browsers don't persist localStorage across reloads for content://  / file:// URLs.
   Served over http:// it should persist. Verify: `python3 -m http.server` + reload.
2. imgui_phone_demo PICK TAB partial render (shows "Selected:" + only the selected row's
   blue bar; the other 5 selectable rows absent) at frame 61, no crash. Investigation:
   - RULED OUT the font: selectable's text goes through drawTextAtS, which is ALSO used by
     u.text + buttons (both render fine), so ctx.style.font is set and text works.
   - RULED OUT the widget: selectableImpl advances layout correctly; selectable is used by
     multiselect_finder (in the 98).
   - Window is full-screen (setNextWindowSize(W,H)), benign flags; other tabs have MORE
     widgets (tabBasic ~12) than tabPick (~6), so the content region isn't too short.
   - Headless repro attempt (point default Basic tab at tabPick, OR set_selected on Pick)
     hits a FRAME-0 "Out of bounds memory access" in update BEFORE the selectable loop
     (SELDBG instrumentation never fired) — distinct from but likely related to the partial
     render. set_selected on the 4th tab ALSO OOBs (a possibly separate tab-selection bug).
   - Re-added `style.font = &s.ui_host.font_cache.font` (I had wrongly DROPPED the phone
     demo's `style.font = &s.font_cache.font` last turn instead of converting it; faithful
     now, compiles + passes, but not the cause).
   STILL UNRESOLVED — needs interactive/visual debugging (debug build + bounds checks, or
   browser devtools). The smoke only ever renders each app's DEFAULT (first) tab, so both the
   partial render AND the frame-0 OOB were invisible to CI. TODO: add tab-switch + selectable-
   list coverage to the smoke.
3. dev_tools log shows `ui.slider(min == max): min=0.5 >= max=0.5` — a degenerate slider
   somewhere (warning only). Minor, to track down.
GATES unchanged: lint 0/394, imgui_phone_demo still passes (~174/frame).

### Ported the docking arc: ui_dock_basic + ui_dock_persistence (turn ~1087)
The wgpu dock API (u.dockSpace + dockBuilder*, from src/ui.zig) already existed (proven by
wgpu_ui_dock_simple), so both ported via the helper with minimal fixes:
 - z.ui_dock.SplitResult -> ui.SplitResult (SplitResult is `pub const SplitResult =
   struct { a: Id, b: Id }` in ui.zig; z.ui_dock is the GL-only dock alias).
 - dock_persistence: persistence_key field -> ui_host.ctx.persistence_key (now auto-handled
   by the helper — added a .ctx routing pass for persistence_key/metrics/debug_log).
 - dock_persistence's "Clear" button calls z.dom.persistence_remove(key); zimr_wgpu.zig
   didn't re-export `dom` (GL's zimr.zig does). Added `pub const dom = @import("web.zig").dom;`
   to zimr_wgpu.zig — the wgpu runtime (zimr_wgpu.ts) already provides js_persistence_remove
   (localStorage.removeItem with "zimr_" prefix). web.zig compiles cleanly for wgpu; unused
   dom externs are DCE'd, so no new wasm imports for examples that don't touch dom.
HELPER (gl2wgpu_ui.py) now also: routes UiContext fields metrics/persistence_key/debug_log
through .ctx automatically.
GATES: lint 0/396, COLD full smoke 100/100 (the core dom re-export caused zero regressions),
0 AppSpec unregistered. Milestone: 100 wgpu wasms. PER-TURN zip (zimr1087).

### Implemented click-to-front for floating windows (turn ~1088)
Wired the long-anticipated focus-driven window reorder (the ui.zig notes at the
no_bring_to_front_on_focus flag said "wires when a last_focus_frame: u64 is added to Window
and endFrame sorts frame_windows by it" — done).
 - Window gains `last_focus_frame: u64 = 0` and `hosts_dockspace: bool = false`.
 - dockSpace() marks its host window `hosts_dockspace = true`.
 - bringFocusedFloatingToFront(ctx): if the focused window is FLOATING (dock_node_id == null
   AND not hosts_dockspace), stamp its last_focus_frame = ctx.frame_count; then stable-sort
   ctx.frame_windows by last_focus_frame ascending (most-recently-focused last = drawn on top).
 - Called right after syncDockedWindowIds in BOTH endFrameNoRender (wgpu path:
   endFrameNoRender -> uiRenderNow) and endFrame (GL path), so dock_node_id is final before
   the sort. The replay loops (uiRenderNow / endFrame) then draw in z-order.
 - Docked windows + dockspace hosts keep last_focus_frame=0 → they sort FIRST (behind) in
   submit order (host submitted first stays at the back, docked tiles next); only free
   windows reorder. This avoids the host popping over its docked children.
GATES: lint 0/396, full smoke 100/100 (core ui.zig change, zero regressions). NOTE: visual
z-order not verifiable headless (smoke checks no-crash + draw counts, not stacking) — Simon
to confirm clicking a floating window raises it.
PER-TURN zip (zimr1088).

### Fix: floating windows must ALWAYS be above docked (turn ~1089)
The turn-1088 reorder keyed only on last_focus_frame, so a floating window that had NEVER
been focused (key 0) tied with docked windows (also 0) and fell back to submit order — an
unfocused floating Viewport sank into/under the docked layer (Simon's screenshot: floating
Viewport rendering under floating Notes AND the dock). Fix: two-level sort key in
bringFocusedFloatingToFront — primary `floating(w) = dock_node_id == null and
!hosts_dockspace` (all docked + hosts sort BEFORE all floating), secondary last_focus_frame
(focus recency within a class). So z-order is now: dockspace host (back) < docked tiles <
floating windows (front, most-recently-focused on top). GATES: lint 0/396, full smoke 100/100.
KNOWN-MINOR (unrelated): dock host still logs `ui.window: 'Tools' content (75px) is >3× its
viewport (1px)` — a first-frame docked-leaf sizing quirk (viewport measured at 1px on frame 0);
warning only.
PER-TURN zip (zimr1089).

### Fix: dock tab bars must render BELOW floating windows (turn ~1090)
Turn-1089 put floating windows above docked CONTENT, but docked-leaf TAB BARS were drawn
into foreground_dl (which renders after floating windows), so docked headers still painted
over floating window headers (Simon's screenshot). Fix: a dedicated `dock_tabs_dl` draw
layer that sits ABOVE docked content but BELOW floating windows.
 - UiContext gains `dock_tabs_dl: DrawList`. flushDockTabsToForeground now points
   current_draw_list at &ctx.dock_tabs_dl (not &ctx.foreground_dl) for renderDockLeafTabBars.
 - New helper replayWindowsAndTabs(ctx, gl, window, shapes, font): iterates the sorted
   frame_windows and renders dock_tabs_dl right before the FIRST floating window (or after
   all windows if none float). Both render paths (uiRenderNow = wgpu, uiContextDeferredRender
   = GL) now call it instead of the bare frame_windows loop.
 - dock_tabs_dl cleared alongside foreground_dl.
Final z-order: dockspace host (back) -> docked tiles -> dock tab bars -> floating windows ->
popups/foreground/tooltips (front). windowIsFloating() = dock_node_id == null and
!hosts_dockspace is now the single shared predicate for both the sort and the tab layer.
GATES: lint 0/396, full smoke 100/100. NOTE: dock splitter seams (renderDockSplitters) were
left as-is — if they also paint over floating windows, that's a follow-up (Simon flagged
headers/tab bars specifically). PER-TURN zip (zimr1090).

### Ported 3 more resisters via 2 helper fixes (turn ~1091)
PORTED: ui_input_flags_zoo_phone (~240/frame), ui_notes_phone (~54), ui_full_showcase (~564).
HELPER (gl2wgpu_ui.py) fixes:
 1. Split the main-block regex into TWO independent matches — `pub var zimr_app` (removed)
    and `pub fn main {...}, State, initState, update);` (replaced with AppSpec+deinit).
    Previously required them ADJACENT; input_flags_zoo + notes put the State struct + helper
    fns BETWEEN them, so the combined regex never matched. Now both layouts work.
 2. Residual guard now strips "..." string literals AND \\ multiline-string lines (in
    addition to // comments) before checking for UiContext/beginFrame/zimr_app. full_showcase
    has bulletText LABELS mentioning "beginFrame"/"endFrame" (lines 826-7) that were
    false-positiving even though the real beginFrame/endFrame (273-4) were converted fine.
STILL RESISTING (bespoke, deferred): imgui_demo (State var is `state` not `s` — helper's
s.ui_ctx / beginFrame replaces are s-hardcoded; needs var-name detection, and the file is
1150L so risky), ui_panes (a source-display string literal contains "ui_ctx: ui.UiContext,"
so the `,1` field-replace hits the STRING first), ui_minimal_button (THREE UiContexts).
GATES: lint 0/399, focused smokes pass for all 3. No full smoke (leaf examples, no core
change). PER-TURN zip (zimr1091).

### Ported wgpu_comptime_julia (comptime fractal); 3 UI resisters deemed bespoke (turn ~1092)
PORTED: wgpu_comptime_julia (~51/frame) — the Julia set computed ENTIRELY at comptime into a
const escape grid, drawn as colored cells. Created by adapting the wgpu_comptime_mandelbrot
template (AppSpec + drawRectangleRec grid + Color.fromHSV shade) and swapping in the Julia
kernel: z₀ = pixel coordinate, c = fixed (-0.7 + 0.27015i). Grid 100x88, view 3.4x3.0,
iter_limit 128, .fit window 800x704. No font/shader needed (pure comptime grid). NOTE: the
CLI `comptime_julia` exe target already exists in build.zig (prints ASCII); the wgpu base
"comptime_julia" -> wasm "wgpu_comptime_julia" is distinct.
HELPER fixes also landed this arc (input_flags_zoo/notes/full_showcase): split main regex +
guard ignores string/multiline-string contents.
REMAINING UI RESISTERS — BESPOKE, deferred as diminishing-returns:
 - imgui_demo (1150L): mixed `s`/`state` State vars AND custom loadFontFromTtfData in initState.
 - ui_panes: hardcodes its own source as a display-string array (the field-replace + transforms
   would frankenstein it; CLEAN port needs regenerating the display string).
 - ui_minimal_button: a GL-font-path DIAGNOSTIC (bitmap vs TTF) — moot on wgpu; also 3 UiContexts.
GATES: lint 0/400, focused smoke PASS. No full smoke (leaf example, no core change).
NEXT fractal candidate: julia_gallery (a grid of Julia variations). PER-TURN zip (zimr1092).

### Ported wgpu_julia_gallery (turn ~1093)
PORTED: wgpu_julia_gallery (~51/frame) — four classic Julia sets (dragon/fern/starfish/spiral)
in a 2×2 grid, each computed at COMPILE TIME with its own constant c + base hue, drawn as
colored cells. Same kernel as wgpu_comptime_julia; the comptime grid is 2×2 of 50×44 cells
(100×88 total = same ~1.1M-iteration budget). cellIndex(x,y) picks the per-pixel case both at
comptime (which c) and at render (which hue). No font/shader. The CLI julia_gallery wrote a PNG.
FIX: created the per-example index.html for both comptime_julia (was missing from turn 1092 —
the standalone build generates its own HTML so it didn't matter) and julia_gallery.
GATES: lint 0/401, focused smoke PASS. No full smoke (leaf example). PER-TURN zip (zimr1093).

### PLANNING turn — full-parity + GL-kill plan made authoritative (turn ~1094)
Simon's call: FULL parity (build every subsystem, no dropping), design the best wgpu-native
systems (don't port the GL monolith), largest system work first, verify everything.
AUDIT: 142 runnable GL examples, 92 have wgpu twins, **50 GL-only**. Verified the parity gap
empirically (GL `zimr` pub-API diff vs `zimr_wgpu` + what the 50 actually call): it's ~the
whole raylib surface, split into (a) GL-rendering SUBSYSTEMS to build — rlgl immediate (~15),
retained 3D mesh/Model (~11), image upload/readback (~13), audio (4), gesture recognizers (2),
TTF/text-layout (~few); and (b) backend-agnostic helpers to RE-EXPORT (image CPU ops, gesture
math, collision, splines, color, text utils, easings, ECS, codecs). wgpu subsystem check: 3D
*immediate* + 2D + UI + RTT + compute EXIST; audio/rlgl/gestures/retained-3D/image-upload/
readback/TTF do NOT.
WROTE the precise plan as `PORT_PLAN.md` §1.5 (S-A…S-F, each verify→design→port→done-gate +
the tail + deletion sequence + guardrails), made it the **#1 CURRENT PLAN in claude.md**
(supersedes `finishing_webgpu.md` §8 + PORT_PLAN §§2–7), and refreshed claude.md's stale
(turn-1045) port-status block. NEXT: **S-B (3D retained)** — keystone, self-contained, the
helmet proves the pieces. No code changed this turn (docs only).
