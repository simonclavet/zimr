# raylib coverage plan — what to add, what to never add

> **Disregards audio** (65 functions, separate effort) per user direction.
> This is a fresh categorization done after the aggressive ziggification
> sweep, against an updated `coverage-report.md` (now generates
> 77.1% in-scope coverage — was previously parsing zimr's namespaced
> structs incorrectly).
>
> Gestures (8 functions) are kept in the inventory but parked behind
> the touch-input arc.

## Coverage snapshot (post-sweep)

| Module      | raylib | ported | %      |
| ----------- | ------:| ------:| ------:|
| `core`      | 184    | 78     | 42.4%  |
| `rcamera`   | 2      | 2      | 100%   |
| `shapes`    | 70     | 68     | 97.1%  |
| `splines`   | (in shapes)| - | -      |
| `textures`  | 113    | 94     | 83.2%  |
| `text`      | 37     | 31     | 83.8%  |
| `models`    | 71     | 64     | 90.1%  |
| `raymath`   | 146    | 146    | 100%   |
| `rlgl`      | 158    | 119    | 75.3%  |
| **In-scope total** | 781 | 602 | **77.1%** |
| _audio (deferred)_ | 65 | 0  | -      |
| _gestures (deferred)_ | 8 | 0 | -    |

## Disposition of every missing function

Each missing function falls into exactly one bucket:

- **🚫 web-impossible** — no browser API exists, or the concept doesn't
  apply (e.g., monitor count in a tab)
- **🌐 web-redundant** — the browser does this its own way, or has a
  superior primitive zimr should expose differently
- **🐾 zig-redundant** — Zig stdlib / Zig idiom does this better
- **🎯 should add** — real gap, would benefit zimr
- **⏳ deferred** — should add eventually but blocked on a bigger arc
  (touch input, glTF load, audio, render-to-texture stack)

### `core` — 106 missing

#### Window management (35) — almost all 🚫 or 🌐

The browser owns the window.  Most of this surface is conceptually
wrong for a `<canvas>` inside a tab.

- 🚫 `InitWindow`, `CloseWindow`, `IsWindowReady` — zimr's `z.run` /
  `z.init` is the entry point; the browser handles canvas creation
- 🚫 `IsWindowMinimized`, `IsWindowMaximized`, `IsWindowResized`,
  `IsWindowState`, `SetWindowState`, `ClearWindowState`,
  `MaximizeWindow`, `MinimizeWindow`, `RestoreWindow`,
  `ToggleBorderlessWindowed`, `IsWindowHidden` — no equivalent in a tab
- 🚫 `GetMonitorCount`, `GetCurrentMonitor`, `GetMonitorWidth/Height`,
  `GetMonitorPhysicalWidth/Height`, `GetMonitorRefreshRate`,
  `GetMonitorPosition` — multi-monitor doesn't exist for a tab.  The
  browser exposes `screen.width` / `screen.height` but it's the
  primary monitor only
- 🚫 `SetWindowPosition`, `GetWindowPosition`, `SetWindowMonitor`,
  `SetWindowMinSize`, `SetWindowMaxSize`, `SetWindowOpacity`,
  `SetWindowFocused`, `SetWindowIcon`, `SetWindowIcons` — host page
  controls these via `<title>`, `<link rel="icon">`, CSS;
  `SetWindowTitle` is the only one with a sensible direct mapping
  via `document.title`
- 🌐 `IsWindowFullscreen`, `ToggleFullscreen` — Fullscreen API exists
  and is reasonable to wire.  **🎯 should add as `z.window.toggleFullscreen()`**
- 🌐 `GetWindowScaleDPI` — `window.devicePixelRatio` is trivial.  **🎯 should add**
- 🌐 `SetWindowTitle` — `document.title = …`.  **🎯 should add**
- 🌐 `SetClipboardText`, `GetClipboardText` (already ported), `GetClipboardImage` —
  Clipboard API.  **🎯 should add SetClipboardText + GetClipboardImage**
- 🚫 `EnableEventWaiting`, `DisableEventWaiting` — block-on-event mode
  doesn't apply (the browser's event loop is what we're guests in)

**Verdict:** 7 worth adding (`toggleFullscreen`, `setWindowTitle`,
`getWindowScaleDPI`, `setClipboardText`, `getClipboardImage`).
Group them in a small `z.window` module.

#### Drawing lifecycle (7) — mostly conceptually replaced

- 🚫 `BeginDrawing`, `EndDrawing`, `SwapScreenBuffer`,
  `PollInputEvents`, `WaitTime` — the per-frame `update` callback IS
  the drawing scope.  These exist in raylib because raylib drives the
  loop; in zimr, the browser's `requestAnimationFrame` does
- 🐾 `ClearBackground` — exposed as `f.clear(color)` on the Frame.
  Already covered, just under a different name
- 🎯 `BeginTextureMode` / `EndTextureMode` — raylib's RTT scope is a
  legitimate ergonomic win.  zimr currently has render-to-texture but
  the example wires it manually with `rlEnableFramebuffer` /
  `rlDisableFramebuffer` (see `examples/rtt.zig`).  Wrap as
  `z.textures.beginTextureMode(target)` / `endTextureMode()`.  **~20 LOC**
- 🚫 `BeginVrStereoMode`, `EndVrStereoMode`, `LoadVrStereoConfig`,
  `UnloadVrStereoConfig` — VR rendering.  WebXR exists but is a
  separate arc; not a current goal

**Verdict:** add `beginTextureMode` / `endTextureMode` (one `defer`
wrapper) — that's it.

#### Shader, screenshot, OpenURL, MemFree, TraceLog (8)

- 🐾 `LoadShader`, `LoadShaderFromMemory`, `UnloadShader` — these
  exist in zimr under `z.shaders` but the matcher tests against `core`
  module since raylib categorises them there.  **Already done** —
  fix the rename map
- 🌐 `TakeScreenshot` — canvas → Blob → download.  **🎯 should add as
  `z.window.takeScreenshot(filename)`** — 1 dom.js bridge call, ~20 LOC
- 🌐 `OpenURL` — `window.open(url)`.  **🎯 should add** — 5 LOC
- 🐾 `SetConfigFlags` — no-op in a browser; the equivalent setting
  (e.g., MSAA, vsync) is canvas attribute or rAF.  Skip
- 🐾 `MemFree` — Zig's `gpa.free`.  Skip
- 🐾 `TraceLog` (varargs C-shape) — replaced by `z.text.traceLog(level,
  fmt, args)` which is a Zig `comptime fmt` shape.  **Already there
  under runtime/Logger** — fix the rename map for `core.TraceLog → core.traceLog`

**Verdict:** 2 small additions (`takeScreenshot`, `openURL`).  Two
rename-map fixes.

#### File I/O (32) — almost all 🚫

The browser sandbox makes most of these nonsensical.  zimr's `Loader`
already handles the read side asynchronously.

- 🚫 `SaveFileData`, `SaveFileText`, `ExportDataAsCode` — could be
  done via Blob+anchor download but no example wants this
- 🚫 `UnloadFileText` — replaced by `gpa.free`
- 🚫 `SetLoadFileDataCallback`, `SetSaveFileDataCallback`,
  `SetLoadFileTextCallback`, `SetSaveFileTextCallback` — virtual-FS
  callback hooks; not relevant since zimr's `Loader` is
  dependency-injected directly
- 🚫 `FileRename`, `FileRemove`, `FileCopy`, `FileMove`,
  `FileTextReplace`, `FileTextFindIndex` — no real filesystem in the
  browser
- 🚫 `FileExists`, `DirectoryExists`, `IsFileExtension`, `GetFileLength`,
  `GetFileModTime`, `MakeDirectory`, `ChangeDirectory`, `IsPathFile`,
  `LoadDirectoryFiles`, `LoadDirectoryFilesEx`, `UnloadDirectoryFiles`,
  `GetDirectoryFileCount`, `GetDirectoryFileCountEx` — same
- ⏳ `IsFileDropped`, `LoadDroppedFiles`, `UnloadDroppedFiles` — drag-
  and-drop **is** a browser thing (`ondragenter` / `ondrop`).  Not
  yet wired but real.  **Defer until a use case**
- 🐾 `ComputeCRC32` — pure utility.  Trivial Zig port if needed; no
  current caller
- 🚫 `LoadAutomationEventList`, `UnloadAutomationEventList`,
  `ExportAutomationEventList`, `SetAutomationEventList`,
  `SetAutomationEventBaseFrame`, `StartAutomationEventRecording`,
  `StopAutomationEventRecording`, `PlayAutomationEvent` — input record
  & replay.  Useful for testing.  Not blocking; defer

**Verdict:** 0 to add now.  Drag-and-drop file ingest is the one
real future addition (track in coverage-gaps.md).

#### Input — gamepad (7) — mostly 🐾 or 🎯

The 4 base gamepad button predicates (Pressed/Down/Released/Up) are
listed missing because raylib's signature is `(gamepad: int, button:
int)` while zimr's is `(GamepadButton)` — case-insensitive match
catches them but the matcher is currently picking up just the typed
ones.  Let me verify:

- ✅ already ported (typed): `isGamepadButtonDown`, `isGamepadButtonPressed`, `isGamepadButtonReleased`, `isGamepadButtonUp` — should match.  Cheatsheet missing entry is a bug → fix the rename map for `IsGamepadButtonDown` etc. to point at the typed versions, **or**: zimr's input fns take a `c_int` first param too (`gamepad: c_int, button: GamepadButton`); raylib's signature is `(c_int, c_int)`.  **Verify and add to the rename map.**
- 🎯 `GetGamepadAxisMovement` — present-but-untyped or absent.  Verify
- 🚫 `SetGamepadMappings` — SDL-mapping strings; the browser's
  Gamepad API does mapping itself
- 🌐 `SetGamepadVibration` — Gamepad Haptics API, well-supported.
  **🎯 should add** — ~10 LOC

**Verdict:** verify gamepad predicates are correctly mapped (probably
just rename-map fixes).  Add `setGamepadVibration` (~10 LOC).

#### Input — mouse (4)

- 🌐 `SetMousePosition` — Pointer Lock API with `movementX/Y` reset.
  Niche use case (FPS games on web).  **⏳ defer**
- 🌐 `SetMouseOffset`, `SetMouseScale` — affine cursor transforms.
  zimr could implement client-side without a browser API.  **⏳ defer**
- ✅ `SetMouseCursor` — already ported under `z.input` (sets
  `canvas.style.cursor`).  **Add to rename map**

#### Input — touch (5) — ⏳ all deferred together

- ⏳ `GetTouchX`, `GetTouchY`, `GetTouchPosition`, `GetTouchPointId`,
  `GetTouchPointCount` — `ontouchstart` / `ontouchmove` family.
  **Real gap for mobile.**  Group with the deferred `gestures` module
  since touch is the foundation.
  **Plan: `touch.zig` module + dom.js touch event wiring (~150 LOC).**

### `shapes` — 2 missing

- 🎯 `DrawTriangleGradient` — vertex-color triangle (vs `imageDrawTriangleEx`
  which we have for CPU-side image draws).  GPU version is ~30 LOC.
  **Should add.**
- 🎯 `GetSplinePointBezierQuadratic` — sample a quadratic Bezier at t.
  We have all the other `GetSplinePoint*`, just not this one.  **Should
  add — 10 LOC.**

**Verdict:** both quick adds.  Total ~40 LOC.

### `text` — 6 missing

- 🐾 `LoadFont` — disk file.  We have `loadFontFromTtfData` (in-memory).
  Use the loader system + that.  Skip
- 🐾 `LoadFontEx` — disk + codepoint subset.  Same workaround.  Skip
- 🎯 `LoadFontFromImage` — bitmap-font-from-color-keyed-image.  Niche
  but legit.  **Defer until something asks**
- 🎯 `GenImageFontAtlas` — bake atlas without GPU upload.  We have the
  pieces internally (`bakeFontAtlas` in `text.zig`).  Just expose.
  **~5 LOC.  Should add.**
- ⏳ `ExportFontAsCode` — emit a Zig literal of the font data.  Niche
  tooling.  Defer
- 🐾 `UnloadTextLines` — splits-then-unallocates a `char**`.  Replaced
  by Zig slices + `gpa.free`.  Skip

**Verdict:** 1 to add (`genImageFontAtlas` exposure).

### `textures` — 19 missing

- 🐾 `LoadImage` — disk path.  Use Loader + `loadImageFromMemory`
- 🐾 `LoadImageRaw` — niche fixed-size raw buffer.  Skip
- 🎯 `LoadImageAnim`, `LoadImageAnimFromMemory` — animated GIF.
  Multi-frame return type needs design.  **Defer** until a use case
- 🎯 `LoadImageFromTexture` — read pixels back from GPU.  WebGL2 has
  `gl.readPixels`.  **🎯 should add** — useful for screenshots,
  tile-edit tools.  ~50 LOC
- 🎯 `LoadImageFromScreen` — read framebuffer.  Same plumbing.
  **🎯 should add together with above** — ~20 LOC on top
- 🚫 `ExportImage`, `ExportImageAsCode` — disk write.  Could go via
  Blob+download.  Defer
- 🎯 `ImageFromChannel` — extract a single channel as grayscale
  Image.  Niche.  Defer
- 🎯 `ImageText`, `ImageTextEx` — render text into an Image (CPU-side,
  no GPU).  **🎯 should add** — pairs with `genImageFontAtlas` since
  both leverage the same TTF baker.  ~80 LOC
- 🎯 `ImageFormat` — convert image to a different pixel format
  in-place.  We have `getPixelDataSize` + the format dispatch infra
  from the aggressive sweep.  **🎯 should add** — ~150 LOC
- 🎯 `ImageMipmaps` — generate mip levels for a CPU image.  Niche
  but useful for level-of-detail textures.  **Defer** until cubemap or
  3D scenes need it
- 🐾 `UnloadImageColors`, `UnloadImagePalette` — replaced by `gpa.free`
- 🎯 `ImageDrawRectangleLinesEx` — variant with thick option.  We
  have `imageDrawRectangleLines` already.  **🎯 should add** — ~15 LOC
- 🎯 `ImageDrawTriangleGradient` — vertex-color CPU triangle.  We
  have `imageDrawTriangleEx` doing the same — verify and rename or
  add alias.  **Add to rename map**
- 🐾 `LoadTexture` — disk path
- ✅ `UnloadTexture` — present, must be a rename-map issue.  **Add**

**Verdict:** 5 should-adds (`loadImageFromTexture`,
`loadImageFromScreen`, `imageText` + `imageTextEx`, `imageFormat`,
`imageDrawRectangleLinesEx`), plus 2 rename-map fixes.  Total ~300 LOC.

### `models` — 7 missing

- 🎯 `LoadModel` — glTF/OBJ disk loader.  Use Loader + bytes-in
  variant (which we'd add).  **Defer** until glTF arc lands
- 🎯 `UpdateMeshBuffer` — re-upload partial vertex data.  Useful for
  dynamic meshes.  **🎯 should add** — `gl.bufferSubData`, ~30 LOC
- 🚫 `ExportMesh`, `ExportMeshAsCode` — disk writes.  Defer
- 🎯 `GenMeshCubicmap` — voxel mesh from cubemap image.  Niche.  Defer
- ⏳ `UpdateModelAnimation`, `UpdateModelAnimationEx` — bone-skinning
  matrix update.  **Real gap** for character animation.  ~250 LOC,
  Tier-C work

**Verdict:** 1 should-add (`updateMeshBuffer`).  `UpdateModelAnimation`
is the bigger Tier-C item.

### `rlgl` — 39 missing

Most rlgl gaps are either OpenGL-specific (no WebGL2 equivalent) or
internals not normally needed.

#### WebGL2-impossible (15) — 🚫

- `rlLoadShaderProgramCompute`, `rlComputeShaderDispatch` — compute
  shaders.  **WebGL2 doesn't have them.  WebGPU does — separate arc**
- `rlLoadShaderBuffer`, `rlUnloadShaderBuffer`, `rlUpdateShaderBuffer`,
  `rlBindShaderBuffer`, `rlReadShaderBuffer`, `rlCopyShaderBuffer`,
  `rlGetShaderBufferSize` — SSBOs.  WebGL2 doesn't have them
- `rlBindImageTexture` — image-load-store.  WebGL2 doesn't have them
- `rlGetMatrixProjectionStereo`, `rlGetMatrixViewOffsetStereo`,
  `rlSetMatrixProjectionStereo`, `rlSetMatrixViewOffsetStereo` — VR
  stereo.  Tied to WebXR (separate arc)
- `rlSetPointSize`, `rlGetPointSize` — `gl_PointSize` works in WebGL2
  vertex shaders; the API is awkward to expose
- `rlEnableStatePointer`, `rlDisableStatePointer` — fixed-function
  vertex pointers.  WebGL2 uses VAOs

#### Internals not generally useful (12) — skip

- `rlLoadRenderBatch`, `rlUnloadRenderBatch`, `rlSetRenderBatchActive`,
  `rlCheckRenderBatchLimit` — internal batch pool manipulation
- `rlLoadShaderProgram`, `rlUnloadShader` — lower-level than
  `loadShader` / `unloadShader`
- `rlSetVertexAttributeDefault`, `rlActiveDrawBuffers` — niche
- `rlLoadExtensions`, `rlGetVersion` — WebGL has no extension loader
- `rlSetBlendFactors`, `rlSetBlendFactorsSeparate` — already covered
  by typed `setBlendMode`
- `rlCheckErrors` — debug-only
- `rlLoadDrawCube`, `rlLoadDrawQuad` — internal helpers used in raylib
  C tests; not useful

#### Should add (5)

- 🎯 `rlActiveDrawBuffers` — Multiple Render Targets.  WebGL2 supports
  up to 8 simultaneous color attachments; useful for deferred rendering
  demos.  **~30 LOC**
- 🎯 `rlCubemapParameters` — set wrap/filter on a cubemap.  Pairs
  naturally with `loadTextureCubemap` we already have.  **~20 LOC**
- 🎯 `rlColorMask` — per-channel framebuffer write control.  Useful for
  stencil-like effects.  **~10 LOC**
- 🎯 `rlGetActiveFramebuffer` — read currently-bound FBO.  Useful for
  RTT scopes.  **~10 LOC**
- 🎯 `rlSetUniformMatrices` — array-of-matrices uniform upload (vs the
  single-matrix `rlSetUniformMatrix` we have).  Useful for skinned-mesh
  bone transforms.  **~15 LOC**
- 🎯 `rlResizeFramebuffer` — resize an existing FBO.  Useful for
  resize-aware RTT.  **~30 LOC**
- 🎯 `rlCopyFramebuffer` — `gl.copyTexSubImage2D`.  Useful for
  pingpong-style render passes.  **~30 LOC**

**Verdict:** 7 worthwhile adds (~145 LOC).  All practical for
postprocess / RTT-heavy demos.

## Plan: 4 phases, ranked by yield-per-effort

Each phase is an evening's work and lands a coherent feature group.

### Phase 1: name-parity polish (1-2 hours)

Pure rename-map / alias work — no new behavior, just fix the
cheatsheet's mismatch reports.

- Update the cheatsheet generator's `RAYLIB_TO_ZIMR_RENAMES` for:
  - `LoadShader` → `z.shaders.loadShader`
  - `LoadShaderFromMemory` → `z.shaders.loadShaderFromMemory`
  - `UnloadShader` → `z.shaders.unloadShader`
  - `IsGamepadButtonPressed` → `z.input.isGamepadButtonPressed`
  - `IsGamepadButtonDown` → `z.input.isGamepadButtonDown`
  - `IsGamepadButtonReleased` → `z.input.isGamepadButtonReleased`
  - `IsGamepadButtonUp` → `z.input.isGamepadButtonUp`
  - `GetGamepadAxisMovement` → `z.input.getGamepadAxisMovement`
  - `SetMouseCursor` → `z.input.setMouseCursor`
  - `UnloadTexture` → `z.textures.unloadTexture`
  - `TraceLog` → `core.traceLog`
  - `MemFree` (raylib's stdlib heap free) → `std.mem.Allocator.free`
  - `ImageDrawTriangleGradient` → `z.textures.imageDrawTriangleEx`
- Re-run generator; expect coverage to bump 1-2 percentage points
  with zero new code.

### Phase 2: small-but-real adds (~half day, ~250 LOC)

- `z.shapes.drawTriangleGradient` (~30 LOC, +1 test)
- `z.shapes.getSplinePointBezierQuadratic` (~10 LOC, +1 test)
- `z.text.genImageFontAtlas` — expose `bakeFontAtlas` (~5 LOC, +1 test)
- `z.textures.imageDrawRectangleLinesEx` (~15 LOC, +1 test)
- `z.textures.beginTextureMode` / `endTextureMode` (~20 LOC, +1 test)
- `z.window.openURL` (~5 LOC dom.js bridge)
- `z.window.setWindowTitle` (~5 LOC dom.js bridge)
- `z.window.getWindowScaleDPI` (~5 LOC)
- `z.window.setClipboardText` (~10 LOC)
- `z.window.getClipboardImage` (~30 LOC, async)
- `z.window.toggleFullscreen` (~30 LOC, Fullscreen API)
- `z.window.takeScreenshot(filename)` (~30 LOC, canvas → Blob → download)

### Phase 3: render-stack completion (~full day, ~400 LOC)

These pair naturally — each example that uses one tends to want the
others.

- `z.textures.loadImageFromTexture(gpa, tex)` — `gl.readPixels`,
  ~50 LOC, +3 tests (RGBA8, R16G16B16, error case)
- `z.textures.loadImageFromScreen(gpa)` — same plumbing reading
  from default FBO, ~20 LOC, +1 test
- `z.textures.imageText(gpa, font, text, fontSize, color)` — CPU-side
  text-into-image.  Leverages `bakeFontAtlas` and the slice-shape
  glyph drawing.  ~80 LOC, +2 tests
- `z.textures.imageTextEx(gpa, font, text, fontSize, spacing, color)`
  — extended variant.  ~30 LOC on top
- `z.textures.imageFormat(gpa, image, newFormat)` — convert pixel
  format.  ~150 LOC dispatch (GRAYSCALE/RGB/RGBA8 + the float
  formats), +5 tests
- `z.models.updateMeshBuffer(mesh, index, data, offset)` —
  `gl.bufferSubData`, ~30 LOC, +1 test
- `z.rlgl.rlActiveDrawBuffers(count)` — MRT enablement, ~30 LOC
- `z.rlgl.rlCubemapParameters(id, param, value)` — wrap/filter, ~20 LOC
- `z.rlgl.rlColorMask(r, g, b, a)` — `gl.colorMask`, ~10 LOC
- `z.rlgl.rlGetActiveFramebuffer()` — `gl.getParameter(FRAMEBUFFER_BINDING)`, ~10 LOC
- `z.rlgl.rlSetUniformMatrices(loc, mats)` — slice-shape, ~15 LOC
- `z.rlgl.rlResizeFramebuffer(target, w, h)` — ~30 LOC
- `z.rlgl.rlCopyFramebuffer(...)` — ~30 LOC

### Phase 4: bigger arcs (multi-session, separate)

- **Touch input + gestures arc** (~1 day): `z.touch` module, dom.js
  event wiring for `touchstart`/`touchmove`/`touchend`, then layer
  raylib's gesture detection on top.  Unlocks gestures (8 functions)
  and mobile-friendly examples.
- **glTF model loading** (~2-3 days): port or vendor a Zig glTF
  parser; add `z.models.loadModelFromMemory` taking glTF bytes.
  Unlocks `LoadModel` family (~5 functions).
- **`UpdateModelAnimation`** (~1 day, ~250 LOC): bone-skinning matrix
  update.  Pairs with skinned_mesh example.

### Out of scope — keep these on the "won't port" list

- All window-management beyond title/fullscreen/scale/screenshot
- All file-system functions except drag-and-drop ingest
- Automation events (input record/replay) — useful for testing but
  not blocking
- VR (`BeginVrStereoMode` etc.) — separate WebXR arc
- Compute shaders + SSBOs (`rlLoadShaderProgramCompute`,
  `rlLoadShaderBuffer`, etc.) — WebGPU territory
- `rlLoadDrawCube`, `rlLoadDrawQuad` — raylib internals
- `WaitTime`, `PollInputEvents`, `SwapScreenBuffer`,
  `BeginDrawing`/`EndDrawing` — wrong shape for the rAF loop

## Re-running the audit

```sh
cd <zimr-repo-root>
ln -s /home/claude/raylib-ref/raylib-master/src raylib_src  # one-time
python3 src/notes/cheatsheet-generator.py > docs/coverage-report.md
```

The generator now correctly parses zimr's namespaced struct layout
(was emitting 34% coverage when run before the parser fix; now emits
77.1%).  Re-run after each phase to confirm coverage bumps.
