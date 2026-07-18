# zimr — porting plan

A pure-Zig port of **raylib 6.0** for **wasm32-wasi + WebGL2**, with an
opinionated final API (allocators, errors, three-tier memory) layered
on top once the underlying port works end-to-end.

This document is the durable plan.  It captures what we're porting,
what we're not, the phase order and the validation strategy.  Update
it as decisions land.

---

## 1. Big picture

We are porting one specific snapshot — **raylib 6.0** at git tag `6.0`,
SHA `dbc56a87da87d973a9c5baa4e7438a9d20121d28` — into pure Zig.  We do
**not** track upstream raylib past this point.  Every Zig function in
this repo corresponds to a function in that snapshot, and we verify
behavioural parity against the C source as we go.

### What "ported" means here

We're not just wrapping raylib's C in Zig — we replace it.  The build
compiles **zero C files**.  Every public raylib function has a Zig
implementation.  External libraries that raylib historically embeds
(stb_image, miniaudio, cgltf, …) are not ported at first; the
functions that depend on them are stubbed or backed by Zig-native
equivalents on demand.

### Target

- `wasm32-wasi`, `--export`-driven (no `_start`).
- WebGL2 only (which is GLES 3.0 — what raylib 6.0 calls
  `GRAPHICS_API_OPENGL_ES3`).
- Browser host via a hand-written JS runtime (`src/web/*.js`).
- No emscripten, no glfw, no libc.

### Final shape (Phase 12, after the port works)

```zig
const z = @import("zimr");
pub fn main(init: std.process.Init) !void {
    var app = try z.init(.{ .gpa = init.gpa, .window = .{ .title = "demo" } });
    try app.start(.{ .state = ..., .update = update });
}
fn update(f: *z.Frame) void {
    f.clear(z.colors.slate_950);
    f.drawCube(.{ .x = 0, .y = 0.5, .z = 0 }, 1, 1, 1, z.colors.sky_500);
}
```

Three memory tiers: `f.gpa` (long-lived), `f.frame` (cleared after GPU
sync), `f.scratch` (cleared after `update`).  Errors instead of return
codes.  Allocators instead of static buffers.  The work to get there
**doesn't start until the C-style port works in the browser** — we
don't want to design the new API on guesswork.

---

## 2. Source-of-truth inventory

### Modules in raylib 6.0

| File                              | LOC  | Top-level fn defs | Header / impl   |
|-----------------------------------|------|-------------------|-----------------|
| `rcore.c`                         | 4625 | 167               | impl            |
| `rshapes.c`                       | 2495 | 70                | impl            |
| `rtextures.c`                     | 5583 | 118               | impl            |
| `rtext.c`                         | 2993 | 65                | impl            |
| `rmodels.c`                       | 7268 | 89                | impl            |
| `raudio.c`                        | 2956 | 94                | impl            |
| `rcamera.h`                       | 562  | 14                | header-only     |
| `rgestures.h`                     | 555  | 20                | header-only     |
| `rlgl.h`                          | 5421 | 163               | header-only     |
| `raymath.h`                       | 3139 | 146               | header-only     |
| `platforms/rcore_web_emscripten.c`| 1753 | 50                | platform impl   |

Total: ~32,400 LOC of C, ~600 RLAPI public functions in `raylib.h`,
163 RLAPI functions in `rlgl.h`.

37 typedef structs and 21 typedef enums in `raylib.h` define the
public type surface.  Layout is preserved exactly (extern struct,
same field order, same field types) so we never need a marshalling
layer between a Zig caller and a Zig-implemented function.

### Existing partial port (the `zray-backup.zip` we received)

Per the previous PROJECT_NOTES.md and a pass over the code:

| Module                  | Existing zray status            | Reusable?          |
|-------------------------|---------------------------------|--------------------|
| `raymath` (146 fns)     | 100%, auto-generated, 45 tests  | **Yes — port-as-is** |
| `rshapes` (69 fns)      | 100%                            | **Yes — port-as-is** |
| `rgestures` (10 fns)    | 100%                            | **Yes — port-as-is** |
| `rcamera` (14 fns)      | 100%                            | **Yes — port-as-is** |
| `window/render`         | ~95% but emscripten-coupled     | Partial — rewrite platform glue |
| `input` (36 fns)        | ~95%                            | **Yes — port-as-is** |
| `shaders` (10 fns)      | ~95%                            | Yes — depends on rlgl |
| `rtext` (40+ fns)       | ~70%                            | Partial — font loader stays out |
| `rtextures` (72 fns)    | ~58%                            | Partial — image loader stays out |
| `rcore` (utilities)     | ~50%                            | Partial — file I/O rework |
| `rmodels` (43 fns)      | ~38%                            | Partial — drawing depends on rlgl |
| `raudio` (76 fns)       | 0%                              | N/A                |
| `platform_web` (12 fns) | partial, emscripten-coupled     | Rewrite             |
| `emscripten` bindings   | n/a                             | **Discard**         |

The pure-CPU modules (raymath, gestures, camera, shapes, rcore utils,
rtextures CPU portion, rmodels math) are gold — they were
target-portable in the old project too, and they slot straight into
our new layout with the import paths updated (their old `@import("zray.zig")` becomes `@import("types.zig")`).

The browser-touching code (window, platform, input plumbing into
state, anything calling `rl*` externs) needs rework because we no
longer have C-side rlgl — we have Zig-side rlgl.

### Externals that stay deferred

These third-party C single-header libs were embedded by raylib.  We do
not port them in this project; we substitute or stub the functions that
need them:

| Library          | Purpose                | Fallback while deferred         |
|------------------|------------------------|---------------------------------|
| stb_image        | PNG/JPG/BMP/TGA decode | Zig-native PNG only initially   |
| stb_truetype     | TTF rasterisation      | Default bitmap font only        |
| stb_image_write  | PNG/etc encode         | `exportImage` returns error      |
| stb_image_resize2| Bilinear image resize  | Nearest-neighbour fallback      |
| stb_perlin       | Perlin noise           | Zig-native port (~100 LOC)      |
| stb_rect_pack    | Glyph atlas packing    | Required by rtext font atlas — defer with stb_truetype |
| miniaudio        | Audio device + decoders| Web Audio API shim later         |
| dr_wav/mp3/flac  | Audio decoders         | Same — Web Audio handles decode  |
| cgltf            | glTF parser            | `loadModel` returns error        |
| m3d              | M3D model parser       | Same                            |
| par_shapes       | Procedural meshes      | Hand-port the few we need        |
| tinyobj_loader_c | OBJ parser             | Hand-port (small text parser)    |
| sdefl/sinfl      | DEFLATE codec          | Use `std.compress.deflate`       |
| qoi              | QOI image format       | Hand-port (~200 LOC, simple)    |
| qoa              | QOA audio format       | Hand-port if needed              |

`raygui.h` (only present in `examples/`) is **deferred entirely** per
explicit instruction.

### Platform-layer (`rcore_web_emscripten.c`) does not get ported as C-equivalent

The C platform layer calls 45+ distinct `emscripten_*` functions and
embeds 21 EM_JS blocks of inline JavaScript.  We are not porting this
file 1:1 — we replace its contract.  The 50 functions raylib expects
the platform layer to provide (InitPlatform, ToggleFullscreen,
GetMonitorWidth, …) get a fresh Zig implementation that talks to our
own JS runtime.  The behaviour on the user-visible side stays the same
where it makes sense; some web-meaningless functions (monitor enum,
window position) become best-effort stubs.

---

## 3. Architecture decisions (already made)

These are settled.  Don't relitigate them mid-port.

| # | Decision                                                 | Rationale |
|---|----------------------------------------------------------|-----------|
| 1 | Target `wasm32-wasi`                                     | Real Zig stdlib (allocators, fmt, log, fs traits) without the emscripten runtime drag |
| 2 | No C compilation in the build                            | Forces Zig-only, simplifies deploy, removes vendor.sh + python tooling |
| 3 | JS runtime hand-written, three import groups (`wasi_snapshot_preview1`, `dom`, `webgl`) | Clean separation: WASI = stdlib, dom = canvas/time/loop, webgl = GL2 |
| 4 | `extern struct` types match raylib 6.0 layouts exactly  | Lets us pass values into Zig-implemented "C ABI" functions without rewrap |
| 5 | Phase 1–9 export functions with raylib's C names + signatures | Lets us port raylib examples line-for-line during validation |
| 6 | Bun for test/serve, no Python or shell                  | One non-Zig runtime, used only at integration boundaries |
| 7 | Zig 0.16.0 pinned                                       | Pre-release tracking is too costly for a port of this size |
| 8 | Final ziggified API in Phase 12 only                    | Don't design it before we know what works in the browser |

---

## 4. Phase plan

Each phase declares its scope, dependencies, what it unlocks, and a
validation strategy.  We do not move on from a phase without its
validation passing.

### Phase 0 — Foundation **(complete)**

- [x] Zig 0.16.0 + Bun installed and working
- [x] `build.zig` for `wasm32-wasi`, ReleaseSmall by default
- [x] `extern "dom"`, `extern "webgl"` import patterns proven
- [x] `tests/smoke.ts` round-trips through the wasm via Bun
- [x] `host.html` + `runtime.js` + `wasi.js` + `dom.js` + `gl.js` shells
- [x] `examples/basic.zig` clears the canvas through real WebGL imports
- [x] `zig build test` runs pure-CPU unit tests on the host

### Phase 1 — Types + raymath (full) **(complete)**

- [x] All 35 `extern struct` types from `raylib.h` in `src/types.zig`
- [x] All 21 enums + raylib-style integer constants in `src/enums.zig`
- [x] All 146 `raymath.h` functions in `src/raymath.zig`
- [x] 45 mathematical-identity tests in `src/raymath_test.zig`
- [x] Color carries 26 named raylib colour constants as `pub const`s

### Phase 2 — rlgl, the keystone

This is the single biggest piece.  `rlgl.h` is 5421 LOC and 163 public
functions.  It owns:

- Matrix mode + matrix stack (modelview / projection / texture)
- Immediate-mode batched draw API (`rlBegin/rlEnd/rlVertex*/rlColor*`)
- Default shader compilation + management
- Texture loading/binding/unbinding/filtering
- Buffer/VAO/VBO management
- Framebuffer (RenderTexture) management
- Multiple GL profile abstraction (we only target ES 3.0 / WebGL2,
  so we drop the GL 1.1 / 2.1 / 3.3 / 4.3 paths)

Decomposed into sub-phases:

- **2.1 — rlgl state + matrix stack ✅ done**.  Pure CPU; no GL calls.
  17 functions: `rlMatrixMode`, `rlPushMatrix`/`Pop`/`LoadIdentity`,
  `rlTranslatef`/`Rotatef`/`Scalef`, `rlMultMatrixf`, `rlOrtho`,
  `rlFrustum`, `rlSetClipPlanes`, `rlGetCullDistanceNear`/`Far`,
  `rlSetFramebufferWidth`/`Height` + getters, `rlSetBlendMode`.  Verified
  by 15 host-target tests covering identity, push/pop balance, modelview
  → transform redirection, ortho/frustum layout, multmatrix round-trip,
  clip-plane round-trip, axis normalisation in `rlRotatef`.
- **2.2 — rlgl batched immediate mode ✅ done**.  12 functions:
  `rlBegin`/`rlEnd`, `rlVertex2f`/`Vertex3f`/`Vertex2i`,
  `rlTexCoord2f`, `rlNormal3f`, `rlColor4ub`/`Color4f`/`Color3f`,
  `rlSetTexture` (with implicit draw-call split on texture change).
  Static `defaultBatch` (32k verts, ~1.27 MB BSS), `draws[256]` array
  + `drawCounter`.  All pure CPU — verified by 6 host-target tests
  for begin/vertex/color/depth/texture-split semantics.
- **2.3 — Default ES3 shader + GPU init/flush ✅ done**.  Lives in
  `src/rlgl_gpu.zig` (split out so 2.1+2.2 stay host-testable).
  Includes `rlglInit`/`rlglClose`, default vertex+fragment shader
  compile (verbatim from raylib's `GRAPHICS_API_OPENGL_ES3` path),
  1×1 white default texture, VAO + 5 VBO setup, pre-filled u16 quad
  index buffer, `rlDrawRenderBatch`/`rlDrawRenderBatchActive`,
  `rlClearScreenBuffers`/`rlViewport`/`rlClearColor`.  Validated by
  the Bun smoke test (1421 GL calls / 60 frames, no traps).
- **2.4 — Texture management ✅ done**.  Lives split: pure-CPU
  format helpers (`rlGetPixelDataSize`, `rlGetGlTextureFormats`,
  `rlGetPixelFormatName`) in `rlgl.zig` (verified by 11 host tests
  covering RGBA8/RGB8/RG8/R8/16-bit-packed/float/DXT-block paths
  and the bad-format → 0 contract); GPU-touching upload+bind
  functions (`rlLoadTexture`, `rlUpdateTexture`, `rlUnloadTexture`,
  `rlTextureParameters`, `rlGenTextureMipmaps`, `rlEnable`/
  `DisableTexture`, `rlEnable`/`DisableTextureCubemap`,
  `rlActiveTextureSlot`) in `rlgl_gpu.zig`.  Validated end-to-end
  by `examples/basic.zig` uploading a 16×16 RGBA checker at init
  and binding it on the per-frame triangle.  Compressed formats
  (DXT/ETC/PVRT/ASTC) deferred — they need WebGL2 extension probes
  we'll add when an example needs them.
- **2.5 — Framebuffers ✅ done**.  10 functions in `rlgl_gpu.zig`:
  `rlLoadFramebuffer`, `rlLoadTextureDepth` (texture or renderbuffer
  flavour, `DEPTH_COMPONENT24`), `rlFramebufferAttach` (colour
  channels 0-7, depth, stencil; texture2D / renderbuffer / cubemap
  face dispatching), `rlFramebufferComplete` (logs the specific
  incompleteness reason via dom.log), `rlUnloadFramebuffer`,
  `rlEnableFramebuffer` / `rlDisableFramebuffer`, `rlBlitFramebuffer`
  (NEAREST filter), `rlBindFramebuffer`.  Required adding 12
  `extern "webgl"` functions to `gl.zig` (`createFramebuffer` /
  `Renderbuffer`, bind/delete, `framebufferTexture2D`,
  `framebufferRenderbuffer`, `checkFramebufferStatus`,
  `blitFramebuffer`, `renderbufferStorage`) plus 14 GL constants
  (FRAMEBUFFER targets, attachment slots, depth/stencil internal
  formats, completeness status codes).  Validated end-to-end by
  the new `examples/rtt.zig` — render-to-texture demo with a
  rotating triangle drawn into a 256×256 offscreen target then
  resampled as a fullscreen quad.
- **2.6 — Shader compile/link API ✅ done**.  10 functions in
  `rlgl_gpu.zig` plus an `activeTextureId[]` slot table in
  `rlgl.zig`'s state singleton.  `rlLoadShader` (single-stage
  compile), `rlLoadShaderProgramEx` (link pre-compiled), and
  `rlLoadShaderCode` (compile + link with default-stage fallback +
  detach/delete after link) form the compile/link surface;
  `rlGetLocationUniform`/`Attrib` resolve names; `rlSetUniform`
  dispatches by type tag through 13 setter paths
  (vec/ivec/uvec 1-4 + sampler2D); `rlSetUniformMatrix` does
  column-major upload; `rlSetUniformSampler` allocates a slot in the
  per-batch active-texture-id table and uploads the unit index;
  `rlEnableShader`/`Disable` are direct `glUseProgram`;
  `rlSetShader` flushes-then-swaps for mid-frame program changes.
  Required adding 12 array-form `glUniformN[fiu]v` exterms +
  4 `glVertexAttribNfv` defaults + `glDetachShader` to the GL
  surface.  Validated end-to-end by `examples/shader.zig` — a
  chromatic-aberration post-process running on top of the RTT
  output, with `uOffset` and `uTime` uniforms pushed every frame.

**Phase 2 — rlgl, the keystone — COMPLETE.**

The rlgl pipeline supports:
- Matrix stacks (modelview / projection / transform with the
  raylib redirect-on-push behaviour)
- Batched immediate-mode geometry (rlBegin/Vertex/End with
  state-change-triggered draw call splitting)
- Default ES3 shader compiled at init
- Pixel-format-aware texture upload with the full mipmap chain
- Texture parameters + mipmap generation
- Framebuffer attach + completeness check + bind/blit
- User-defined shaders with type-dispatched uniform setters and
  multi-sampler binding
- **State setters: depth-test, depth-mask, back-face culling,
  cull-face direction, color-blend, scissor, line width** (added
  in the rlgl tail — 21 new entry points total)
- **Default-resource accessors: rlGetTextureIdDefault,
  rlGetShaderIdDefault, rlGetShaderLocsDefault** (used by
  material lifecycle)
- **GPU-handle unloaders: rlUnloadVertexArray, rlUnloadVertexBuffer,
  rlUnloadTexture**
- Three end-to-end browser examples validate the surface against
  real WebGL2 (smoke runs against a fake-GL Proxy and verifies
  the call sequence doesn't trap)

**Unlocks:** rshapes, rtextures-draw, rmodels-draw, the entire
visible output of every example.
**Validation:** Phase 5 (rshapes) cannot land without 2.1–2.4.  We
also write a "draw red rectangle" Zig integration test that runs in
Bun headless and checks the GL call sequence matches expectation.
**Estimate:** 4–5 sessions.

### Phase 3 — Platform layer

50 functions raylib expects from `rcore_web_emscripten.c`, rewritten
on top of our own JS runtime.

- **Input state machine + JS event capture ✅ done**.  `src/input.zig`
  owns the per-frame state singleton (current/previous arrays for
  keyboard + mouse buttons, mouse position + wheel accumulator,
  gamepad scaffolding); 23 host tests verify rising-edge / falling-
  edge / queue-drain / saturation / bounds / wheel accumulation
  semantics.  `src/web/dom.js` installs `keydown`/`keyup` on window,
  `mousedown` on canvas + `mouseup` on window (drag-out-tolerant),
  `mousemove`/`wheel` with `preventDefault` for scrolling keys.
  Browser→raylib keycode translator handles letters / digits /
  function keys / nav keys / modifiers / common punctuation.
  `input.endFrame()` called by the runtime promotes current → previous
  AFTER user update + after rlgl flush.  Validated end-to-end by
  `examples/keys.zig` — WASD/arrow movement, space toggles bg,
  left-click leaves splat marks at the cursor.
- **Timing + TraceLog + window state ✅ done**.  `src/core.zig` —
  17 host tests in `core_test.zig` driven by a fake-clock helper.
  Timing: `GetTime`, `GetFrameTime`, `GetFPS` (raylib's exact
  30-sample / 0.5-second rolling average), `SetTargetFPS`.
  Clock source pluggable via `setNowFn`.  TraceLog: `TraceLog`,
  `SetTraceLogLevel`, `SetTraceLogCallback`, plus a Zig-friendly
  `traceLog(level, fmt, args)` that compile-checks the format
  string.  Default sink routes to `dom.log` with severity
  translation.  Window state: `GetScreenWidth`/`Height`,
  `GetRenderWidth`/`Height`, `IsWindowFocused`, `WindowShouldClose`.
  All wired into `App.create` + `zimr_frame` runtime hooks.
  `examples/keys.zig` upgraded to use `GetFrameTime` for true dt
  movement and `traceLog` for first-frame log lines.
- `InitPlatform` / `ClosePlatform` — already proto'd in Phase 0; flesh
  out.
- Window state setters (title / size / fullscreen toggle).
- Cursor: show/hide/lock — JS sets canvas style + requestPointerLock.
- File I/O via WASI: `LoadFileData`/`SaveFileData`/`LoadFileText`/
  `SaveFileText`.
- Clipboard read/write: `navigator.clipboard.*`.
- Gamepad: `navigator.getGamepads()` polled each frame.
- File drop: `dragover`/`drop` listeners; expose paths through
  `IsFileDropped`/`LoadDroppedFiles`.
- `OpenURL`: `window.open()`.

**Unlocks:** every example that needs input or window control.
**Validation:** `examples/keys.zig` ✅; `core_input_keys` raylib port
deferred until window-state APIs land.
**Estimate:** 2 sessions total; ~1 session of work remaining.

### Phase 4 — rcore subsystems (the non-platform bits)

`rcore.c` minus its platform/input/window glue (which Phase 3 covers)
breaks into:

| Subsystem        | rcore.c LOC range | Sessions | Notes |
|------------------|-------------------|----------|-------|
| Window queries   | 560-869           | 0.5      | `IsWindowFocused` etc. — read CORE state |
| Drawing modes    | 869-1129          | 0.5      | `BeginDrawing`/`EndDrawing`, scissor, blend, texture-mode, shader-mode — partly done in zray |
| VR stereo        | 1129-1228         | 0.5      | Already 100% in zray |
| Shaders          | 1229-1413         | 0.5      | Mostly thin over rlgl Phase 2.6 |
| Screen-space     | 1414-1585         | 0.5      | Camera projection — already done |
| Timing           | 1586-1652         | 0.5      | `SetTargetFPS`, `GetFPS`, `GetFrameTime` |
| Frame control    | 1653-1706         | trivial  | Custom frame stepping helpers |
| Misc             | 1707-1871         | 0.5      | Random, paths, screen-shot |
| Logging system   | 1872-1938         | 1        | `TraceLog` + callbacks; var-args via `std.fmt.bufPrint` |
| Memory mgmt      | 1939-1962         | trivial  | Allocator unloaders |
| File system      | 1963-2986         | 2        | `LoadFileData`, `LoadFileText`, dir walk, path utils.  std.fs over our WASI shim. |
| Compression/enc  | 2986-3540         | 1        | `CompressData` / `DecodeBase64`.  std.compress + std.base64. |
| Automation events| 3541-3801         | 1        | Input record/replay. Defer if needed. |

**Unlocks:** completes the rcore surface.
**Validation:** `core_basic_window`, `core_input_keys`, `core_2d_camera`
examples render correctly.
**Estimate:** 8 sessions.

### Phase 5 — rshapes ✅ done

69 fns, 2495 C LOC → 1771 Zig LOC (incl. comments).  Lifted from
the existing zray port with import-path adjustment to use zimr's
`types.zig`.  Required adding only one alias to rlgl.zig
(`rlGetMatrixTransform` as a `pub export fn` matching the
existing `getTransformMatrix`); all other rlgl externs the port
needs (`rlBegin`/`End`/`Vertex2f`/`TexCoord2f`/`Color4ub`/
`Normal3f`/`SetTexture`) already existed.  Verified by 27 host
tests in `src/shapes_test.zig` covering point-in-rectangle,
point-in-circle, point-in-triangle, point-in-polygon,
rectangle/circle/line collision predicates, collision-rectangle
computation, and all 5 spline-point math functions (linear,
B-spline basis, Catmull-Rom, quadratic Bézier, cubic Bézier).

**Categories:**
- 3 shape-state fns (`setShapesTexture`, getters)
- 5 spline-point fns
- 12 collision-test fns
- 49 draw fns: pixel / line / rect / triangle / circle / ellipse /
  poly / rounded-rect + lines/strip/fan/sector/gradient/spline
  variants

**Validation:** `examples/keys.zig` upgraded to use the proper
API (`drawCircleSector`, `drawLineV`, `drawRectangle`) instead of
inline helpers — drops 60 LOC of demo boilerplate.  Smoke
verifies the wasm runs without trapping at 1661 GL calls/60
frames.

**Browser-side visual verification still pending** — `zig build serve`
then open `host.html?app=keys` to confirm the splats render
correctly (the smoke fake doesn't simulate clicks so the splat
path doesn't fire under test).

### Phase 6 — rtextures (CPU + GPU draw + PNG decoder) — 🟡 ~80% done

72 rtextures fns + a 3-fn PNG decoder, ~6,200 C LOC → ~2,100
Zig LOC.  Lifted rtextures from zray in one session;
hand-wrote `png.zig` from scratch using Zig 0.16's
`std.compress.flate.Decompress` for the IDAT inflate.
30 + 9 host tests; one example dedicated to proving the
asset-loading pipeline end-to-end.

**Done (rtextures core):**
- 5 `DrawTexture*` fns (texture, V, Ex, Rec, Pro)
- 3 validity helpers (`isTextureValid`, `isImageValid`,
  `isRenderTextureValid`)
- 14 color manipulation fns
- ~30 image-manipulation fns (crop, resize, flip, rotate, color
  ops, draw-into-image)
- ~10 image-generators (color, gradient, checked, noise, cellular,
  perlin, text)
- Texture state setters (filter, wrap, mipmaps)

**Done (PNG decoder + async load, this + previous session):**
- `png.decode(allocator, bytes) Error!Image` returning RGBA8
- Color types 0, 2, 4, 6 at 8 bits per channel
- All 5 PNG filter types (None, Sub, Up, Average, Paeth)
- IDAT inflate via `std.compress.flate.Decompress` (.zlib container)
- 9 host tests with hand-crafted test PNGs
- `png.loadAsync(allocator, url) → LoadHandle`,
  `png.pollLoad(handle) → LoadStatus`, `png.releaseLoad(handle)`
- `src/web/fetch.zig` — async fetch handle protocol bridging
  Zig to JS `fetch()`
- `dom.js` `js_fetch_*` handlers (~70 LOC)
- `zimr_fetch_alloc`/`zimr_fetch_free` exports for JS to write
  fetched bytes directly into wasm linear memory

**Validation:**
- `examples/keys.zig` uses `textures.colorLerp` for bg cross-fade
- `examples/png_demo.zig` embeds a 32×32 PNG via `@embedFile`,
  decodes it through `png.decode`, uploads via `rlLoadTexture`,
  draws 4 tiled copies with different tints
- `examples/load_image_demo.zig` (NEW) fetches `assets/smiley.png`
  at runtime via `png.loadAsync`, polls per-frame, decodes once
  ready, uploads + renders.  Demonstrates the canonical
  per-frame state-machine loader pattern.

**DCE win:** adding 280 LOC of decoder + pulling
`std.compress.flate` (substantial!) into the codebase changed
basic/rtt/shader/keys/cube3d sizes by exactly 0 bytes.  png_demo
is 127 KB.  Each example pays for what it uses.

**Deferred for a later session:**
- JPEG / TGA / BMP / QOI loaders.  PNG covers ~95% of game
  asset use cases.
- `exportImage` (needs encoders).
- Bilinear resize uses naive nearest-neighbour — Phase 11
  cleanup.

**ABI / allocator note** — the lifted rtextures code uses
`extern fn malloc/calloc/free` to match raylib's heap
conventions.  The wasm DCE strips function bodies but keeps the
import-table entries — `runtime.js` provides throwing-stub
bindings so the wasm instantiates cleanly.  png.decode does NOT
follow that pattern: it takes an explicit Allocator and returns
an Image with a `deinit` method.  Phase 12 should rewire the
rtextures image fns to match this — see `ZIGGIFY_NOTES.md`
Session N+8.

### Phase 7 — rtext + default font — ✅ done

71 fns text utilities + 3 fns default-font setup.  ~4115 C LOC
total (rtext.c 2,993 + the 1,000+ LOC of `LoadFontDefault` / font
atlas state) → ~1,378 Zig LOC.  Lifted from existing zray work
plus a from-scratch `font_default.zig` with the bitmap data
ported verbatim from raylib's `rtext.c:155`.

**What landed this session (font_default.zig):**
- 512-element u32 bitmap data array (the embedded raylib default
  font, 224 glyphs across a 128×128 atlas)
- 224-element per-glyph width array
- `loadFontDefault()` — unpacks bits to RGBA8, uploads to GPU via
  `rlLoadTexture`, builds 224 GlyphInfo + Rectangle arrays
- `getFontDefault()` — lazy-init accessor, idempotent
- `unloadFontDefault()` — release GPU texture, clear state

**What landed last session (text.zig from zray):**
- 4 codepoint utilities (UTF-8 en/decode, count, prev/next)
- 14 string fns (case conv, substring, replace, split, join, find)
- 2 number parsers (toInteger, toFloat)
- 5 drawing fns + 3 measurement fns
- ~30 C-ABI shim exports for raylib parity

**Validation:** `examples/keys.zig` displays "FPS: N" and
"frame N" HUD text using `text.draw`, with strings formatted
into the per-frame arena.  Smoke output captures
`[2] FONT: Default font loaded (224 glyphs)` proving the lazy-
init triggered, the texture uploaded, and the trace-log routed
through `dom.log` correctly.  `keys.wasm` GL calls jumped
1661 → 1790 (the glyph quads).

**Discovery this session:** Zig's wasm linker doesn't unify
`extern fn foo()` (env import) with `pub export fn foo()`
(module export) across compilation units.  Replaced
`extern fn getFontDefault` in text.zig with a direct
`@import("font_default.zig")` — fixed.  Phase 12 should audit
all `extern fn` declarations across the codebase and convert
internal cross-module calls to `@import`.  See
`ZIGGIFY_NOTES.md` Session N+3 for the full analysis.

**Deferred:**
- TTF / disk font loaders (`loadFont`, `loadFontEx`) — would
  need stb_truetype port (3000+ lines).  Phase 11 cleanup.
- `GenImageFontAtlas` — depends on stb_truetype path.

### Phase 8 — rmodels + Camera3D — 🟡 ~70% done

43 model fns + 10 camera fns, ~5,800 C LOC → 1,660 Zig LOC.
Lifted models.zig from zray; wrote camera.zig from scratch
following raylib's `BeginMode3D`/`EndMode3D` reference.
24 + 8 host tests in models_test.zig and camera_test.zig.

**Done (models):**
- 7 3D primitive drawing fns (cube/sphere/cylinder/plane/line/
  point/circle/triangle/strip + their wires variants)
- `drawRay`, `drawGrid`
- 5 ray-collision tests (sphere/box/triangle/quad/mesh)
- 5 collision predicates (boxes, box-sphere, spheres, etc.)
- `getMeshBoundingBox`, `getModelBoundingBox`
- 4 mesh generators: `genMeshPoly`, `genMeshPlane`,
  `genMeshCube`, `genMeshHeightmap`
- 5 lifecycle fns: `loadMaterialDefault`, `setMaterialTexture`,
  `setModelMeshMaterial`, `unloadMesh`/`Material`/`Model`/
  `ModelAnimations`
- 3 validity helpers: `isModelValid`, `isMaterialValid`,
  `isModelAnimationValid`

**Done (camera, this session):**
- `beginMode3D(camera)` / `endMode3D()` — raylib's 3D rendering
  mode (perspective or ortho projection + look-at + depth-test)
- `beginMode2D(camera)` / `endMode2D()` — 2D camera transform
- `getCameraMatrix(camera)` / `getCameraMatrix2D(camera)`
- `getWorldToScreen(pos, cam)` / `getWorldToScreenEx(...)`
- `getWorldToScreen2D(pos, cam)` / `getScreenToWorld2D(pos, cam)`

**Validation:** `examples/cube3d.zig` upgraded — 28 LOC of manual
matrix-stack boilerplate replaced with a 4-line `Camera3D` struct
plus `beginMode3D(cam)` / `endMode3D()`.  Same exact GL call
count (3170/60 frames) confirms the wrapper does identical work.

**Discovery (Session N+5/N+6):** the systemic env-import problem
was largely cleaned up.  29 of 44 `extern fn` declarations
eliminated cumulatively.  cube3d's wasm env imports went 12 → 7;
only libc (3) + 4 not-yet-Zig fns remain.  See `ZIGGIFY_NOTES.md`
sessions N+5 and N+6.

**Deferred:**
- GLTF / OBJ / IQM disk loaders — need format parsers.
  Phase 11 or beyond.
- Animation loading + `UpdateModelAnimation` — math is portable
  but depends on a loader having populated the bone hierarchy.

### Phase 9 — raudio (last functional area)

76 fns wrapping miniaudio.  We do not port miniaudio.  Two strategies:

- **Bridge to Web Audio API:** AudioContext + AudioBufferSourceNode +
  GainNode for sounds, decodeAudioData + AudioBufferSourceNode for
  music streaming.  Zig side maintains state; JS-side does the heavy
  lifting.  Needs maybe 200 LOC of JS glue.
- **Stub everything:** all audio APIs return success but are no-ops.
  Audio examples render their visuals correctly but are silent.

We pick the Web Audio bridge.  Deferred decoders (WAV/MP3/OGG/FLAC) —
hand them to `audioContext.decodeAudioData`, which the browser does
natively.  QOA we hand-port (small, designed-for-speed format).

**Unlocks:** audio examples; demos with music.
**Validation:** `audio_module_playing`, `audio_sound_loading`.
**Estimate:** 3 sessions.

### Phase 10 — Examples-as-validation

Once Phases 1–9 land, we port a curated set of raylib examples into
`examples/raylib_ports/` to drive a regression suite.  Each ported
example:

1. Translates raylib C → Zig line-for-line (since we kept the raylib C
   names, this is genuinely mechanical).
2. Becomes a build target (`zig build` produces a `.wasm`).
3. Becomes a smoke-test entry (loads in Bun headless, ticks 60 frames,
   asserts no panic).
4. Becomes a "browser visual" entry (we maintain `tests/visuals.md` —
   what each example should look like, by hand).

Target set, in port order:

| Example                            | Phase tested |
|------------------------------------|--------------|
| `core_basic_window`                | 4            |
| `core_input_keys`                  | 3, 4         |
| `core_2d_camera`                   | 4, 5         |
| `core_3d_camera_mode`              | 4, 8         |
| `core_3d_camera_first_person`      | 4, 8         |
| `shapes_basic_shapes`              | 5            |
| `shapes_collision_area`            | 5            |
| `shapes_bouncing_ball`             | 5            |
| `text_input_box`                   | 5, 7         |
| `text_format_text`                 | 7            |
| `textures_logo_raylib`             | 6            |
| `textures_image_drawing`           | 6            |
| `textures_sprite_anim`             | 6            |
| `models_box_collisions`            | 8            |
| `models_first_person_maze`         | 8            |
| `audio_sound_loading`              | 9            |

That's 16 well-chosen examples covering every subsystem.  We can grow
the set after Phase 10 lands.

**Estimate:** 2 sessions to port the set; ongoing maintenance.

### Phase 11 — Cleanup, docs, and externals

- Review every TODO / `unreachable` left across the codebase
- Document what's stubbed vs implemented in `STATUS.md`
- Optionally start porting externals (PNG full-color, OBJ, par_shapes,
  qoi).  Each is a self-contained ~200–500 LOC Zig module.
- Decide: do we port stb_truetype or stay on the embedded default font?

### Phase 12 — Ziggified API

Once everything works, the C-style API stays as the "raw" surface
(`raw.drawRectangle(...)`).  On top, we add the API from the design
sketch:

- `z.init(.{ .gpa, .io, .window })` returns `*App`
- `app.start(.{ .state, .update })` registers the per-frame callback
- `Frame` exposes `.gpa`, `.frame`, `.scratch`, `.time()`,
  `.canvas()`, `.input()`, `.clear`, `.drawXxx`, plus an `f.window(...)`
  immediate-mode UI block (deferred imgui-equivalent)
- Loaders use error returns: `try z.loadTexture(gpa, "foo.png")` instead
  of zeroed-out result + check
- Method-style: `Color.fade(c, 0.5)`, `Vec3.add(a, b)`,
  `camera.update(.first_person)`

The `raw.*` surface stays callable for users who want raylib's exact
behaviour.

**Estimate:** 3–5 sessions, with examples rewritten in the new style.

---

## 5. Tooling / build invariants

These rules are non-negotiable.

- **Only Zig and Bun in the build path.**  No bash, no python.
  Existing `vendor.sh`, `rename_c_to_camel.py`, `strip_zig_ported.py`,
  `gen_raymath.py` are not part of zimr.  When we need a code-gen step
  we write a Zig program and check its output into the repo.
- **Zero C compilation.**  No `.c` files in the build.  External libs
  we eventually need become Zig modules.
- **`build.zig` is the single source of truth.**  Every build artefact,
  test step, and dev server invocation is named there.
- **No symlinks or absolute paths in checked-in files.**
- **Pin Zig 0.16.0.**  `build.zig.zon` declares
  `.minimum_zig_version = "0.16.0"`.

---

## 6. Validation strategy summary

| Layer             | Mechanism                                                       |
|-------------------|-----------------------------------------------------------------|
| Pure-CPU (raymath, gestures, shapes-collision, color math, image-CPU) | `zig build test` host-target Zig tests with assert vectors |
| Wasm correctness  | `zig build smoke-test` — Bun loads the wasm, ticks 60 frames against fake GL, checks call sequence and no traps |
| Visual correctness| Manual: open in browser via `zig build serve`, compare to the corresponding raylib example screenshot |
| Diff parity (math-heavy ports) | Optional later: a "raylib reference" sub-build that we never actually take to production, only to dump bytes-for-bytes outputs of `imageBlurGaussian` etc. and compare |

We do not bring up the diff-parity harness until Phase 6 (where it
would help with image-resize / gradient / dither ports).

---

## 7. Risks and unknowns

| Risk                                                       | Mitigation |
|------------------------------------------------------------|------------|
| `wasm32-wasi` Zig stdlib evolves under us before we finish | Pin Zig 0.16.0 |
| WebGL2 driver bugs across browsers (Safari particularly notorious) | Test on Chrome + Firefox + Safari Tech Preview before declaring a phase done; document workarounds |
| Default font: 256-byte raylib blob may be hard to port    | Worst case ship the original 96x96 image embedded as a `comptime` `[]const u8` and skip the compression decode |
| `EM_JS` blocks that read paste data / DOM textareas       | Re-implement in `dom.js` straightforwardly; behaviour is well-defined |
| Three-tier memory model under wasm                        | `std.heap.wasm_allocator` + `ArenaAllocator` x 2 — already validated in Phase 0 |
| Wasm size growth beyond 1 MB release                      | Acceptable for this kind of project; revisit only if we cross 4 MB |

---

## 8. Where to read what

- `raylib_src/` — the unmodified raylib 6.0 source.  Read-only.  When
  porting a function, this is the source-of-truth.
- `src/` — our Zig implementation.
- `src/web/` — JS runtime + Zig-side import declarations.
- `examples/` — our own examples.  Eventually `examples/raylib_ports/`
  for the 1:1 ports.
- `tests/` — Bun smoke harness, dev server.
- `PORTING_PLAN.md` (this file) — the durable plan.
- `STATUS.md` (Phase 11) — running tally of what's done.

## 9. Remaining-work audit (Session N+19, post-Phase-12.4)

Mechanical comparison: every `RLAPI` declaration in `raylib_src/raylib.h`
vs every `pub fn` in `src/`.  raylib uses PascalCase, we use camelCase
— matched by lowering the first letter.

**Aggregate:** 274 of 600 raylib RLAPI fns ported = **45%**.

But that headline number is misleading because a chunk of the
unported area is **explicitly out-of-scope** for this project:

| Area | RLAPI count | Status |
|---|---|---|
| Audio (device/sounds/music/stream) | 66 | Phase 9 — DEFERRED |
| Misc file I/O (FileExists, ChangeDirectory, FileCopy, ...) | 47 | Desktop-shaped; in wasm we use fetch |
| Window state queries (lots of WindowShould*, GetWindow*) | 42 | Mostly N/A in browser context |
| Touch / Gestures | 13 | Phone-specific, deferred |
| Automation events | 8 | Desktop replay tooling |
| VR stereo | 2 | Niche |
| **Out-of-scope subtotal** | **178** | |

Excluding the out-of-scope 178: **274 of 422 in-scope RLAPI fns ported = 65%**.

### Per-section status (in-scope)

**Fully ported:**
- Collision3D (8/8), Shapes draw (55/55), Shapes collide (11/11),
  Text draw (6/6), Text info (7/7), Texture draw (23/23)

**80%+ done — minor gaps:**
- 3D shapes (19/21) — missing DrawCapsule, DrawCapsuleWires
- Keyboard (8/9) — missing GetKeyName
- Material (5/6) — missing LoadMaterials (multi-material loader)
- Image draw (18/22) — missing ImageDraw, ImageDrawText, ImageDrawTextEx, ImageDrawTriangleEx
- Codepoints (7/9) — missing LoadCodepoints, LoadUTF8

**Mid-completion (40-70%):**
- ScreenSpace (6/8), Mouse (10/14), Text strings (19/26),
  Image manip (19/36), Image gen (6/9), Texture cfg (2/3),
  Camera (3/5), Model (3/5), Timing (4/7), Animation (2/5),
  Gamepad (4/11), Mesh gen (4/11), Font load (4/11)

**Low (0-25%):**
- Drawing modes (4/17) — Begin/End* shader/scissor/blend modes
- Texture load (2/10) — file-based loaders, RenderTexture, cubemap
- Image load (3/12) — file-based loaders, ExportImage variants
- Mesh (2/9) — DrawMesh, ExportMesh, GenMeshTangents
- Model draw (0/8) — DrawModel + variants, DrawBillboard, DrawBoundingBox
- Shader (0/10) — LoadShader, SetShaderValue, etc.
- Random (0/4) — `getRandomValue` is currently env-imported
- Cursor (0/6)

### Recommended sequencing for "finish the port"

**Tier A — Easy wins, finite scope (~200 LOC, 1 session):**
1. **Random** — replace `getRandomValue` env import with
   `std.Random.DefaultPrng`.  Add `setRandomSeed`,
   `LoadRandomSequence`, `UnloadRandomSequence`.  (~50 LOC, 4 fns.)
2. **Cursor** — show/hide via DOM cursor style (`document.body.style.cursor`).  (~30 LOC, 6 fns.)
3. **GetKeyName** — small lookup table.  (~20 LOC, 1 fn.)
4. **Camera update** — `UpdateCamera`/`UpdateCameraPro` (2 fns) — orbit/fly/free-mode camera helpers.  (~80 LOC, 2 fns.)

**Tier B — Medium effort, real game features (~600 LOC, 2-3 sessions):**
5. **Shader API** — `LoadShader`/`LoadShaderFromMemory`/`SetShaderValue`*/
   `GetShaderLocation`/`UnloadShader`.  rlgl_gpu has the GL infra;
   this is the public API surface.  (~200 LOC, 10 fns.)
6. **Mesh upload + GenMesh family** — port `uploadMesh` extern to real
   Zig (rlgl_gpu has the GL bits; we just need the wrapper),
   plus `GenMeshCone`, `GenMeshCylinder`, `GenMeshSphere`,
   `GenMeshKnot`, `GenMeshTangents`.  (~300 LOC, 7 fns.)
7. **DrawModel + DrawMesh** — depends on uploaded meshes working.
   (~150 LOC, 8 fns.)

**Tier C — Worth doing if time permits (~400 LOC, 1-2 sessions):**
8. **Image manipulation gaps** — alpha ops, blur, dithering,
   ImageColor*Tint, ImageFlip variants we don't have.  (~250 LOC.)
9. **Drawing modes** — `BeginShaderMode`/`BeginScissorMode`/
   `BeginBlendMode`/`BeginVrStereoMode`.  (~150 LOC.)
10. **LoadFont from TTF** — adopt `andrewrk/TrueType` (single-file
    pure-Zig port of stb_truetype, maintained by Zig's BDFL).  See
    DEPENDENCIES_PLAN.md.  Adds parsing + rasterization + kerning
    via vendoring or `b.dependency` pin instead of rolling our own.

For the wider "100% Zig including dependencies" survey, see
**DEPENDENCIES_PLAN.md** — covers pure-Zig replacements for every
C dep raylib bundles (`stb_truetype.h`, `cgltf.h`, `miniaudio.h`,
`stb_rect_pack.h`, `stb_perlin.h`, `qoi.h`, `dr_wav.h`, etc.).
Highlights:
- `zigimg` is a pure-Zig 18-format image library that could replace
  our `src/png.zig` and add JPEG/BMP/TGA/GIF/QOI.
- `andrewrk/TrueType`, `bgourlie/zrectpack`, `mgord9518/perlin-zig`,
  `kooparse/zgltf` are all pure-Zig and adoption-ready.
- `zaudio` and `prime31/zig-miniaudio` are **rejected** — both wrap
  C miniaudio, violating the no-C goal.  Phase 9 audio will use
  Web Audio API bindings directly.

**Skip-or-defer outright:**
- Audio (Phase 9, user-deferred)
- File I/O misc (47 fns, desktop-shaped — `FileExists`, `LoadFileText`,
  `SaveFileText`, etc.).  Replace with `fetch` + `LocalStorage` in
  examples.
- Window state stubs (42 fns mostly returning constants in our
  browser context).  Provide a small subset that maps to
  `window.innerWidth`/etc.
- Automation events, VR, Touch, Gestures.

### Loose ends that don't fit the section taxonomy

Six `extern fn` declarations remain in source but are currently
DCE-stripped because their callers aren't reached in the 8 examples:

- `models.zig`: `uploadMesh`, `unloadShader`, `loadImageColors`,
  `unloadImageColors`
- `textures.zig`: `rlTextureParameters`, `getRandomValue`

Tier A and Tier B work above retires 5 of these (everything except
`unloadImageColors`, which would just be a 1-line `libc.free(...)`).
Once that's done, `grep -E "^extern fn" src/*.zig` returns nothing.
