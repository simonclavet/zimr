# What's in raylib that's not yet in zimr

Snapshot taken at the point of the file-consolidation pass.  Numbers
match `docs/cheatsheet.md` (auto-generated audit, re-run with
`python3 docs/cheatsheet-generator.py > docs/cheatsheet.md`).

**TL;DR — overall coverage.**  zimr has **581 of 779 in-scope raylib
functions** (74.6%).  Of the 198 missing functions:

- ~110 are **out of scope by design** — they don't fit the
  wasm + browser model (file system, multi-monitor, fullscreen
  toggle, gamepad vibration, etc.).
- ~50 are **legitimately missing features** we'd want eventually
  (cubemaps, billboards, instanced mesh draw, image animation,
  2D camera mode, etc.).
- ~30 are **deferred upstream-blocked items** (PNG export needs
  the Zig compiler bug fixed, glTF needs a dependency added,
  audio is a whole separate arc).
- 65 audio + 8 gestures are **explicitly deferred** per the
  ROADMAP.

By raylib module, the picture is:

| Module | Coverage | Notes |
| ------ | -------- | ----- |
| `core` | 41.8% (77/184) | Most missing items are wasm-irrelevant (window/monitor/fullscreen/file-system) |
| `rcamera` | 100% | |
| `shapes` | 100% | All draw + collision predicates covered |
| `splines` | 100% | All Bezier/Catmull-Rom/B-spline draw + eval |
| `textures` | 77.7% (87/112) | Missing image animation + cubemap + render-texture pair |
| `text` | 75.7% (28/37) | Missing the disk-loading variants (we use loadFontFromTtfData instead) |
| `models` | 80.3% (57/71) | Missing wires/billboards/instanced/glTF-load |
| `raymath` | 100% | All 146 functions ported |
| `rlgl` | 72.8% (115/158) | Missing OpenGL-specific paths irrelevant to WebGL2 |
| `audio` | 0% | Deferred |
| `gestures` | 0% | Deferred |

## What's missing — by area

### 1. Window management (39 missing)

Most of `core`'s window-related functions don't exist on the web —
the browser owns the window, JS handles fullscreen, the canvas
size is set declaratively.

- `InitWindow`/`CloseWindow` — replaced by `z.run` / `z.init`
- `IsWindowFullscreen`, `ToggleFullscreen`, `SetWindowState`,
  `MaximizeWindow`, `MinimizeWindow`, `RestoreWindow` — partially
  doable through the Fullscreen API; not yet wired
- `GetMonitorCount`, `GetMonitorWidth`, `GetMonitorPosition` — no
  multi-monitor concept in the browser.  Could expose primary
  monitor's `screen.width` etc. but we don't yet
- `SetWindowIcon`, `SetWindowTitle`, `SetWindowPosition` — `<title>`
  and `<link rel="icon">` are set by the host page; window
  position is meaningless in a browser tab
- `SetClipboardText`, `GetClipboardImage` — Clipboard API is
  available but not wrapped yet

**What to add.**  A small `window.zig` module exposing the
browser-feasible subset: setTitle (updates `document.title`),
setFullscreen (Fullscreen API), getCanvasSize, isFocused.  ~80 LOC.

### 2. File I/O (40 missing)

Browser sandboxing means most file functions are nonsensical:

- `LoadFileData`, `SaveFileData`, `LoadFileText` — replaced by our
  async `Loader` for reads.  Saves could be wired to "trigger
  download" via a Blob, but no example needs it yet
- `FileExists`, `DirectoryExists`, `LoadDirectoryFiles`,
  `MakeDirectory`, `ChangeDirectory`, `FileRename`, `FileCopy`,
  `FileMove` — no real filesystem, only the OPFS / File System
  Access API.  Out of scope until a use case
- `IsFileDropped`, `LoadDroppedFiles`, `UnloadDroppedFiles` —
  drag-and-drop IS doable in browsers (`ondragenter`/`ondrop`).
  Not yet wired
- `TakeScreenshot` — possible via canvas → Blob → download.  Not
  yet wired
- `SetLoadFileDataCallback`, `SetSaveFileDataCallback` — callback
  injection for the C-side virtual filesystem; not relevant since
  our loader system replaces this entirely
- `OpenURL` — trivially `window.open()`; not yet wired
- `LoadAutomationEventList`, `StartAutomationEventRecording`,
  `PlayAutomationEvent` — raylib's input-record-and-replay system.
  Useful for testing.  Not yet wired
- `ComputeCRC32` — pure utility.  Easy port; nothing needs it yet

**What to add.**  A tiny `download.zig` that wraps Blob+anchor
trick for "save bytes as file".  Drag-and-drop wiring inside
`web/dom.zig` for file drops.  Maybe.  None of this is blocking.

### 3. Image loading from disk (8 missing)

- `LoadImage`, `LoadImageRaw`, `LoadImageAnim`,
  `LoadImageAnimFromMemory` — disk paths replaced by
  `loadImageFromMemory`/the loader system; animated GIF needs a
  multi-frame return type we haven't designed
- `LoadImageFromTexture` — read pixels back from GPU.  Doable in
  WebGL2 (`gl.readPixels`); not yet wired
- `LoadImageFromScreen` — read framebuffer.  Same as above
- `ExportImage`, `ExportImageAsCode` — disabled until the Zig 0.16
  compiler bug clears (see `STATUS.md`)

**What to add.**  `loadImageFromTexture` (~40 LOC, includes the
`gl.readPixels` plumbing).  Animated GIF support is bigger — hold
off until something needs it.

### 4. Texture loading from disk (7 missing)

- `LoadTexture` — disk path; replaced by `loadTextureFromMemory`
- `LoadTextureFromImage` — convert in-memory `Image` to GPU
  texture.  Doable but we go bytes → GPU directly via
  `loadTextureFromMemory`; this would be the in-between step.
  Useful when you want to manipulate the image first
- `LoadTextureCubemap` — six faces into a cubemap.  Needed for
  skybox examples (Tier-E in the examples plan)
- `LoadRenderTexture`, `UnloadRenderTexture` — convenience pair
  around `rlLoadFramebuffer`.  Currently examples build the FBO
  manually (see `rtt.zig`/`shader.zig`); a wrapper would be nice
- `UpdateTexture`, `UpdateTextureRec` — re-upload pixels to an
  existing GPU texture.  Doable via `gl.texSubImage2D`; not yet
  wired
- `GenTextureMipmaps` — `gl.generateMipmap`.  Easy

**What to add.**  These four together are a half-day's work and
substantially improve the texture API ergonomics:
`loadTextureFromImage`, `loadRenderTexture` (+ unload pair),
`updateTexture`/`updateTextureRec`, `genTextureMipmaps`.  Pair
naturally with the cubemap work.

### 5. Image generation (3 missing)

- `GenImagePerlinNoise` — needs `stb_perlin.h` port or pure-Zig
  noise.  Useful for terrain demos
- `GenImageCellular` — Voronoi / cellular noise.  Same niche
- `GenImageText` — render a string into an `Image` (doesn't touch
  GPU).  Useful for decal-style text on textures.  Needs the font
  rasterizer to write to a CPU buffer — already have most of the
  pieces in `text.zig`'s atlas baker

**What to add.**  `genImageText` is the easiest and most useful
of the three.  Pure CPU, ~80 LOC, leverages the existing TTF
baker.  Perlin/Cellular can wait until a procgen example asks for
them.

### 6. Font loading from disk (6 missing)

- `LoadFont`, `LoadFontEx`, `LoadFontFromMemory` — disk paths.
  We have `loadFontFromTtfData` which is the bytes-in version
  of `LoadFontFromMemory`; just hasn't been registered under
  the raylib name
- `LoadFontFromImage` — bitmap-font-from-image-with-color-key
  approach.  Niche, not yet wired
- `GenImageFontAtlas` — generate the atlas without uploading.
  We do this internally in `bakeFontAtlas`; just need to expose
- `ExportFontAsCode` — write a Zig literal of the font data.
  Niche tooling

**What to add.**  Alias `loadFontFromTtfData` as
`loadFontFromMemory` (one-line rename) for raylib name parity.
Expose `bakeFontAtlas` as `genImageFontAtlas`.  ~10 min total.

### 7. Camera2D (whole concept missing)

raylib has both `Camera3D` (which we have) and `Camera2D` (which
we don't, except for a stub).  `Camera2D` is the pan/zoom/rotate
2D viewport — needed for tile games, level editors, anything 2D
with a moving viewport.

The functions involved: `BeginMode2D`, `EndMode2D`,
`GetScreenToWorld2D`, `GetWorldToScreen2D`.  Plus the
`Camera2D` struct itself.

**What to add.**  Camera2D is Tier-A item #4 in the examples
plan (`camera2d` example).  A small addition to `camera.zig`
plus the demo.  ~120 LOC.

### 8. Mouse / input gaps (11 missing)

Most `input.zig` is solid (26/37) but a few useful bits are
missing:

- `SetMousePosition`, `SetMouseOffset`, `SetMouseScale` —
  programmatic cursor warp.  Doable via Pointer Lock API.
  `SetMouseCursor` actually IS ported — the cheatsheet's a bit
  out of date here
- `GetTouchX`, `GetTouchY`, `GetTouchPosition`, `GetTouchPointId`,
  `GetTouchPointCount` — touch handling.  Doable via
  `ontouchstart`/`ontouchmove`.  Required for any mobile-friendly
  example
- `SetGamepadMappings`, `SetGamepadVibration` — gamepad mapping is
  done by the browser; vibration uses the Gamepad Haptics API
  which is well-supported

**What to add.**  Touch input + Gamepad polling are real gaps if
we want mobile support.  ~half a day each.

### 9. Mesh + Model gaps (10 missing)

The big ones:

- `LoadModel` (disk-load .obj/.glb/.iqm/.m3d) — needs a model
  format parser.  glTF would come from `cgltf` or a Zig port
  (zgltf); .obj is simpler but less common; .glb is the most
  useful.  This is Turns 19-20 in the original ROADMAP
- `DrawModelWires`, `DrawModelWiresEx` — wireframe variants of
  `drawModel`.  Useful for debugging.  Easy port (just changes the
  GL primitive)
- `DrawBillboard`, `DrawBillboardRec`, `DrawBillboardPro` — quads
  that always face the camera.  Needed for particles in 3D, sprite
  enemies, vegetation impostors.  ~150 LOC
- `DrawMeshInstanced` — instanced rendering.  WebGL2 has
  `drawElementsInstanced`; ~80 LOC plus the matrix-buffer plumbing
- `UpdateMeshBuffer` — re-upload partial mesh vertex data.  Useful
  for dynamic meshes
- `GenMeshTangents` — compute tangent vectors for normal mapping.
  CPU side, ~60 LOC
- `GenMeshCubicmap` — voxel-style mesh from a cubemap image.
  Niche
- `ExportMesh`, `ExportMeshAsCode` — write a mesh to .obj or as
  a Zig literal.  Niche tooling

**What to add.**  Billboards + DrawModelWires are easy quick
wins.  Instanced rendering pays off for any large-N scene
(particles, foliage).  glTF loading is the big-ticket item but
brings in a dependency.

### 10. Model animation (2 missing)

We have `LoadModelAnimations` and `IsModelAnimationValid` but
not `UpdateModelAnimation` / `UpdateModelAnimationEx`.  Without
these, animations load but can't play.  Effectively all model
animation is missing.

**What to add.**  `UpdateModelAnimation` is the bone-skinning
matrix update — significant work (~250 LOC) but critical for any
character animation example.  Tier-C in the examples plan
(`skinned_mesh` example).

### 11. Drawing / lifecycle (7 missing)

- `BeginDrawing` / `EndDrawing` — implicit in our model (the
  per-frame callback is the drawing window).  Out of scope
- `BeginTextureMode` / `EndTextureMode` — render-to-texture
  scope helpers.  We do this manually with
  `rlEnableFramebuffer` / `rlDisableFramebuffer` in `rtt.zig`.
  Could wrap as a convenience
- `ClearBackground` — we have `Frame.clear(color)` which is the
  same.  Just naming
- `BeginVrStereoMode` / `EndVrStereoMode` — VR stereo rendering.
  Out of scope (no WebXR wiring planned)

**What to add.**  `beginTextureMode`/`endTextureMode` wrappers
would clean up the `rtt`/`shader` examples.  Easy.

### 12. Custom frame control (3 missing)

- `SwapScreenBuffer` — implicit (browser does this)
- `PollInputEvents` — implicit (browser fires events directly)
- `WaitTime` — `setTimeout` won't help in a rAF loop.  Out of
  scope

These three are conceptually wrong for the browser.  Skip.

### 13. rlgl gaps (43 missing)

`rlgl` covers low-level OpenGL state.  Most of what we don't have
is either OpenGL-specific (no WebGL2 equivalent) or covered by
GPU drivers automatically:

- Compute shaders (`rlLoadComputeShaderProgram`, `rlComputeShaderDispatch`)
  — WebGL2 doesn't have compute shaders.  Would need WebGPU
- Storage buffers (`rlLoadShaderBuffer`, `rlBindShaderBuffer`)
  — same; needs WebGPU
- `rlGetCurrentBatch`, `rlSetRenderBatchActive` — internal batch
  manipulation; not generally useful
- Quad/strip primitives (`RL_QUADS`, `RL_TRIANGLE_STRIP`) — WebGL2
  has these, just not wired
- Multiple-render-target support (`rlActiveDrawBuffers`) — WebGL2
  supports up to 8 MRT; not yet wired but doable

**What to add.**  MRT + tri-strip primitives if a real example
needs them.  Compute is a bigger architectural shift (would
require a WebGPU backend alongside the WebGL2 one).

### 14. Audio (65 missing — entire module)

The whole audio system: device init, wave/sound load/play/stop,
music streaming, audio streams, buffer alias, processor effects.

raylib uses miniaudio under the hood (`raylib_src/external/miniaudio.h`,
350 KB).  In the browser the equivalent is the Web Audio API, which
is structurally very different — node graphs instead of
buffer-callbacks.

**What to add.**  Deferred per user direction.  When this arc
starts, expect ~6-10 turns: Web Audio wrapper + the raylib-style
play/stop API on top.

### 15. Gestures (8 missing — entire module)

Touch gesture detection (tap, pinch, swipe, rotate).  Builds on
the touch input we don't yet have.  Defer until touch lands.

## C code in `raylib_src/` we don't reference

`raylib_src/` is kept in-tree as a reference (~26 800 LOC of C +
headers).  Nothing in zimr links against it; it's there for
look-up-the-original-implementation.

The `raylib_src/external/` directory has 34 third-party libraries
that raylib bundles.  Of these, zimr uses **zero** in the
deployed wasm — every dependency is either reimplemented in pure
Zig or vendored separately under `src/zigimg/` or `src/vendor/`:

| External | What raylib uses it for | Our equivalent |
| -------- | ----------------------- | -------------- |
| `stb_image.h` | Image decode | `src/zigimg/` |
| `stb_image_write.h` | Image encode | (disabled — Zig 0.16 bug) |
| `stb_image_resize2.h` | Image resize | We have hand-rolled resize in `textures.zig` |
| `stb_truetype.h` | TTF parsing | `src/vendor/truetype.zig` (Andrew Kelley's port) |
| `stb_rect_pack.h` | Atlas packing | `src/vendor/rectpack.zig` (zimr-original shelf packer) |
| `stb_perlin.h` | Perlin noise | Not yet ported — `genImagePerlinNoise` missing |
| `stb_vorbis.c` | Ogg Vorbis decode | Audio deferred |
| `cgltf.h`, `cgltf_write.h` | glTF read/write | Not yet ported — `loadModel` missing |
| `tinyobj_loader_c.h` | OBJ load | Not yet ported |
| `m3d.h` | M3D model format | Not yet ported (and probably never — niche format) |
| `vox_loader.h` | MagicaVoxel `.vox` | Not yet ported |
| `par_shapes.h` | Procedural mesh primitives | We have hand-rolled `genMeshCube` etc. in `models.zig` |
| `qoi.h`, `qoa.h`, `qoaplay.c` | QOI image / QOA audio | QOI via zigimg (decode side); QOA part of audio arc |
| `dr_flac.h`, `dr_mp3.h`, `dr_wav.h` | FLAC/MP3/WAV decode | Audio deferred |
| `jar_mod.h`, `jar_xm.h` | Tracker module formats | Audio deferred |
| `miniaudio.h` | The whole audio engine | Web Audio (deferred) |
| `rprand.h` | xoshiro128++ PRNG | We use `std.Random.DefaultPrng` in `effects.rng.Browser` |
| `sdefl.h`, `sinfl.h` | DEFLATE compression | We use zigimg's pure-Zig deflate |
| `glad.h`, `glad_gles2.h` | OpenGL function loader | WebGL functions are imports, no loader needed |
| `glfw/`, `RGFW/` | Window/input abstraction | Browser handles this |
| `rlsw.h`, `rltexgpu.h` | Software renderer | Out of scope — WebGL2 is always available |
| `dirent.h`, `win32_clipboard.h`, `fix_win32_compatibility.h` | Win32 compat | N/A on wasm |

So the answer to "what C code is not in `external/`" is: **all the
C code that we'd actually need to port**, which is the four
`raylib_src/r*.c` files (`rcore.c`, `rmodels.c`, `rshapes.c`,
`rtext.c`, `rtextures.c`) plus the `rlgl.h` single-header
implementation.  Coverage breakdown by C file:

| C file | LOC | Our coverage |
| ------ | --- | ------------ |
| `rcore.c` | 4 625 | partial (~42%) — mostly skipping window/file/monitor/automation |
| `rshapes.c` | 2 495 | full (100%) |
| `rtextures.c` | 5 583 | most of the manipulation surface (~78%); load-from-disk gaps |
| `rtext.c` | 2 993 | most of the drawing/measurement surface (~76%); load-from-disk gaps |
| `rmodels.c` | 7 268 | most of the static mesh + model surface (~80%); animation/billboard gaps |
| `rlgl.h` | 5 421 | core rendering pipeline (~73%); compute/storage gaps |
| `rcamera.h` | 562 | full (100%) |
| `raymath.h` | 3 139 | full (100%) |
| `raudio.c` | 2 956 | 0% (deferred) |
| `rgestures.h` | 555 | 0% (deferred) |

## What to do next

If we wanted to push coverage from 74.6% to 85% with the highest
yield-per-effort, in order:

1. **Camera2D** (~120 LOC) — biggest single-feature gap
2. **`loadTextureFromImage` + `updateTexture` + `genTextureMipmaps`
   + `loadRenderTexture`** (~200 LOC) — texture API completion
3. **`loadFontFromMemory` alias + `genImageFontAtlas` exposure**
   (~10 min) — name parity wins
4. **`drawModelWires` + `drawBillboard*` + `drawMeshInstanced`**
   (~250 LOC) — completes the static-3D draw surface
5. **`genImagePerlinNoise` + `genImageText`** (~150 LOC) — image gen
6. **`updateModelAnimation`** (~250 LOC) — unblocks any character
   animation work
7. **glTF load via dependency** (~2-3 turns) — opens the door to
   real game assets
8. **Touch input + gestures** (~half day each) — mobile support
9. **Audio arc** (long, separate effort)

Items 1-5 together would push coverage past 80%.  Items 1-7 past
85%.  Audio adds a flat 65 functions but is the bigger
architectural lift.

Functions we should explicitly NOT port (out of scope by design,
~110 functions): all of `core`'s window/monitor/fullscreen/file-system
helpers, `core`'s automation event recording, `rlgl`'s compute/SSBO
helpers, raylib's callback-based file I/O hooks, and most of the
clipboard/screenshot/URL helpers (covered by browser primitives
when needed).
