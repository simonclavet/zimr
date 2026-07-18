# 40-step plan: raylib coverage 77% → 92%+

> Detailed execution plan for the 4 phases identified in
> `raylib-coverage-plan.md`.  Every step is independently shippable:
> code compiles, tests pass, smoke build green.  After every step
> this file gets a status mark, the changelog gets an entry, the
> CHEATSHEET reflects new surface, and a snapshot is saved (every
> 2-3 steps minimum).
>
> **Hard rules — no exceptions:**
>
> 1. Code is **idiomatic Zig**: slices not `(ptr, len)`, error unions
>    not sentinels, snake_case values, TitleCase types.  `c_int`
>    appears only at raylib-ABI parity boundaries (extern struct
>    fields, JS-FFI exports with `callconv(.c)`).
> 2. Style guide rules 1-5 apply: one arg per line for >2-arg
>    functions, mandatory braces, casual comments, prefer `@splat`
>    over `**`.
> 3. **Every new public function** gets at least one host
>    behavioural test AND, where it makes sense, a smoke-test
>    example covering the wasm path.
> 4. **Every new public function** gets one zimr example modeled on
>    raylib's matching example (path noted per step).
> 5. CHEATSHEET.md gets updated in the same commit as new surface.
> 6. CHANGELOG.md `[Unreleased]` section gets a turn entry per step
>    (or per logical pair).
> 7. Snapshot via `/home/claude/snapshots/save.sh <label>` at the end
>    of each step that touched code.
> 8. Verify both `zig build test` and `zig build smoke-test` after
>    every step; do not move on with red.
>
> **Reference codebase:** `/home/claude/raylib-ref/raylib-master/`.
> When porting, read the equivalent `examples/<module>/<name>.c` for
> intent, then write the Zig version using zimr's idioms — don't
> transliterate.

## Plan summary

| Phase | Steps | What | Effort |
|-------|-------|------|--------|
| **1** | 1   | Cheatsheet generator polish (rename map, parser fixes) | 1 hr |
| **2** | 2-13 | Shapes, text, textures small adds + `z.window` module | half day |
| **3** | 14-26 | Render-stack completion (RTT/MRT/imageFormat/imageText) | full day |
| **4** | 27-32 | Touch input + gestures arc | 1 day |
| **4** | 33-36 | glTF model loading arc | 2-3 days |
| **4** | 37-40 | Skinned-mesh animation arc + final consolidation | 1 day |

Verify state before any phase work begins:
```sh
cd /home/claude/zimr
export PATH=/home/claude/bin:$PATH
zig build test --summary all && zig build smoke-test --summary all
```

---

# Phase 1 — Cheatsheet generator polish (1 step)

## Step 1: rename-map fixes

**What.** The cheatsheet generator's case-insensitive matcher misses
several already-ported functions because raylib's name doesn't
case-fold to zimr's chosen name.  Fix by extending
`RAYLIB_TO_ZIMR_RENAMES` in `src/notes/cheatsheet-generator.py`.

**Adds.**
```python
"LoadShader":            ("shaders", "loadShader"),
"LoadShaderFromMemory":  ("shaders", "loadShaderFromMemory"),
"UnloadShader":          ("shaders", "unloadShader"),
"IsGamepadButtonPressed":  ("input", "isGamepadButtonPressed"),
"IsGamepadButtonDown":     ("input", "isGamepadButtonDown"),
"IsGamepadButtonReleased": ("input", "isGamepadButtonReleased"),
"IsGamepadButtonUp":       ("input", "isGamepadButtonUp"),
"GetGamepadAxisMovement":  ("input", "getGamepadAxisMovement"),
"SetMouseCursor":          ("input", "setMouseCursor"),
"UnloadTexture":           ("textures", "unloadTexture"),
"TraceLog":                ("core",   "traceLog"),
"MemFree":                 ("std",    "gpa.free(slice)"),
"ImageDrawTriangleGradient": ("textures", "imageDrawTriangleEx"),
```

**Verify.** Each rename target must actually exist via grep.  Re-run
generator: `python3 src/notes/cheatsheet-generator.py > /tmp/before.md`,
apply, regenerate, diff coverage line.  Expect bump from 77.1% to
~78-79%.

**Tests.** None (generator is offline tooling).

**Example.** None.

**Cheatsheet.** Update the "raylib coverage" section's percentage.

**Changelog.** Entry: "generator rename-map for already-ported fns".

**Snapshot.** `turn-step01-rename-map`.

---

# Phase 2 — Small adds (steps 2-13, ~half day)

## Step 2: `z.shapes.drawTriangleGradient`

**Function.**
```zig
pub fn drawTriangleGradient(
    v1: Vector2, v2: Vector2, v3: Vector2,
    c1: Color, c2: Color, c3: Color,
) void
```

**Body.** GPU-side per-vertex-color triangle.  Mirrors
`imageDrawTriangleEx` (which we already have) on the rlgl batch path:

```zig
rl.rlBegin(RL_TRIANGLES);
rl.rlColor4ub(c1.r, c1.g, c1.b, c1.a); rl.rlVertex2f(v1.x, v1.y);
rl.rlColor4ub(c2.r, c2.g, c2.b, c2.a); rl.rlVertex2f(v2.x, v2.y);
rl.rlColor4ub(c3.r, c3.g, c3.b, c3.a); rl.rlVertex2f(v3.x, v3.y);
rl.rlEnd();
```

**Reference.** raylib `examples/shapes/shapes_basic_shapes.c` (search
`DrawTriangleGradient`).  We already have a slice-shape `drawTriangle`
nearby — read raylib's `rshapes.c::DrawTriangleGradient` to confirm
no extra batch-flush required.

**Tests.** Host: 2 tests in `shapes_test.zig` — "smoke: doesn't panic
with valid input" and "doesn't panic with degenerate (collinear)
input".  No pixel readback yet (we only get those after step 14).

**Example.** `examples/triangle_gradient.zig` — three vertex colors
oscillating with sine waves (mirrors raylib's
`shapes_basic_shapes.c`'s gradient demo).

**Cheatsheet.** "Common idioms" → add a "Vertex-colored triangle"
subsection.

**Changelog.** "Phase 2 step 2: drawTriangleGradient + example".

**Snapshot.** Skip (small step; covered by next snapshot).

## Step 3: `z.shapes.getSplinePointBezierQuadratic`

**Function.**
```zig
pub fn getSplinePointBezierQuadratic(
    p1: Vector2, c2: Vector2, p3: Vector2,
    t: f32,
) Vector2
```

**Body.** Standard quadratic Bezier evaluation:
`(1-t)² * p1 + 2(1-t)t * c2 + t² * p3` per channel.

**Reference.** raylib's `rshapes.c::GetSplinePointBezierQuad`.

**Tests.** Host: `t=0` returns `p1`, `t=1` returns `p3`, `t=0.5` lies
on the curve midpoint.  Float-eps tolerance.

**Example.** Extend `examples/triangle_gradient.zig` if convenient,
or add a tiny `examples/spline_eval.zig` plotting sampled points
along all four curve types.

**Cheatsheet.** No change (already lists splines).

**Changelog.** "Phase 2 step 3: getSplinePointBezierQuadratic".

**Snapshot.** `turn-step03-shapes-small-adds`.

## Step 4: `z.text.genImageFontAtlas`

**Function.**
```zig
pub fn genImageFontAtlas(
    gpa: std.mem.Allocator,
    glyphs: []const GlyphInfo,
    font_size: c_int,
    padding: c_int,
    pack_method: PackMethod,
) std.mem.Allocator.Error!struct { atlas: Image, recs: []Rectangle }
```

**Body.** Already implemented as `bakeFontAtlas` internally.  Promote
to public surface, add the slice-shape `glyphs` parameter, return both
the atlas Image and the per-glyph Rectangle slice.

**Reference.** raylib's `rtext.c::GenImageFontAtlas`.

**Tests.** Host: 1 test in `text_test.zig` — bake a tiny 4-glyph
atlas, verify dimensions are power-of-2 and per-glyph recs lie within.

**Example.** `examples/font_atlas.zig` — bake the default font's
glyph atlas at custom sizes, draw the atlas itself as a texture
overlay.  Mirror raylib's `text/text_font_loading.c`.

**Cheatsheet.** Add to "Modules at a glance" (text section already
mentions atlas baking; reword to call out the public function).

**Changelog.** "Phase 2 step 4: genImageFontAtlas exposure + example".

**Snapshot.** Skip.

## Step 5: `z.textures.imageDrawRectangleLinesEx`

**Function.**
```zig
pub fn imageDrawRectangleLinesEx(
    dst: *Image,
    rec: Rectangle,
    thick: c_int,
    color: Color,
) void
```

**Body.** Already have `imageDrawRectangleLines` (1-pixel hollow
rectangle).  This is the thick variant — four `imageDrawRectangleRec`
calls forming a frame.

**Reference.** raylib's `rtextures.c::ImageDrawRectangleLinesEx`.

**Tests.** Host: 1 test — draw a 4-pixel-thick frame on a 16×16
image, verify interior pixels untouched.

**Example.** Extend `examples/image_editor.zig` to draw a thick
selection rectangle.

**Cheatsheet.** No change.

**Changelog.** "Phase 2 step 5: imageDrawRectangleLinesEx + example
extension".

**Snapshot.** `turn-step05-image-rect-lines`.

## Step 6: `z.textures.beginTextureMode` / `endTextureMode`

**Functions.**
```zig
pub fn beginTextureMode(target: RenderTexture2D) void
pub fn endTextureMode() void
```

**Body.** Wrappers around the existing manual sequence in
`examples/rtt.zig` (`rlEnableFramebuffer`, viewport set, projection
matrix push, etc.).  Mirror raylib's `rcore.c::BeginTextureMode`.

**Reference.** raylib's `core_drawing.c` and any RTT example
(`textures/textures_to_image.c`).

**Tests.** Host: 1 test verifying the matrix-stack and
batch-state round-trip (begin then end leaves rlgl in the same
state).  Smoke: yes — examples/rtt.zig uses these.

**Example.** Refactor `examples/rtt.zig` to use the new wrappers
(strip the manual rlEnableFramebuffer dance).  Smaller, cleaner.

**Cheatsheet.** "Common idioms" → add a "Render to texture" subsection
showing the new wrapper usage.

**Changelog.** "Phase 2 step 6: beginTextureMode/endTextureMode +
rtt example refactor".

**Snapshot.** `turn-step06-texture-mode`.

## Step 7: `z.window` module bootstrap + `setWindowTitle`

**Module.**  Create `src/window.zig` exposing browser-feasible
window operations.  Re-export from `src/zimr.zig` as `z.window`.
First function:

```zig
pub fn setWindowTitle(title: []const u8) void
```

**Body.** wasm-side: call `dom.set_window_title(ptr, len)` via the
runtime imports.  Host stub: no-op.

**Reference.** raylib's `rcore.c::SetWindowTitle`.

**Tests.** Host: 1 trivial "doesn't panic" test (host stub is no-op).
Smoke: 1 wasm test that calls `z.window.setWindowTitle("test")` and
verifies the document.title via the JS test harness's mock.

**Example.** `examples/window_demo.zig` — counter app whose title
updates every second.

**Cheatsheet.** Add `z.window` row to "Modules at a glance".

**Changelog.** "Phase 2 step 7: z.window module + setWindowTitle".

**Snapshot.** Skip.

## Step 8: `z.window.getWindowScaleDPI`

**Function.**
```zig
pub fn getWindowScaleDPI() Vector2
```

**Body.** wasm: call `dom.get_dpi_scale()` returning
`window.devicePixelRatio` (same value for x and y).  Host stub: returns
`{1, 1}`.

**Reference.** raylib's `rcore.c::GetWindowScaleDPI`.

**Tests.** Host: 1 test — host stub returns 1.0.  Smoke: 1 wasm test
verifying the DPI value comes through > 0.

**Example.** Extend `examples/window_demo.zig` to display the DPI in
the HUD.

**Cheatsheet.** No change.

**Changelog.** Add a line to step-7 entry.

**Snapshot.** Skip.

## Step 9: `z.window.toggleFullscreen`

**Function.**
```zig
pub fn toggleFullscreen() void
pub fn isFullscreen() bool
```

**Body.** wasm: call `dom.toggle_fullscreen()` which calls the
Fullscreen API on the canvas.  Host stub: tracks a host-only state
variable for testability.

**Reference.** raylib's `rcore.c::ToggleFullscreen`.

**Tests.** Host: 1 test — toggle, isFullscreen reflects the toggle.
Smoke: 1 — call toggle (the JS test harness mocks the Fullscreen
API to record the request).

**Example.** Extend `examples/window_demo.zig` — F key toggles
fullscreen.

**Cheatsheet.** No change.

**Changelog.** Continue step-7 entry.

**Snapshot.** `turn-step09-window-basics`.

## Step 10: `z.window.openURL`

**Function.**
```zig
pub fn openURL(url: []const u8) void
```

**Body.** wasm: `dom.open_url(ptr, len)` which does
`window.open(url, '_blank')`.  Host stub: no-op.

**Reference.** raylib's `rcore.c::OpenURL`.

**Tests.** Host: 1 — doesn't panic on empty URL.  Smoke: 1 — verify
the JS test harness records the URL.

**Example.** Extend `examples/window_demo.zig` — clickable button to
open the zimr docs.

**Cheatsheet.** No change.

**Changelog.** Continue step-7 entry.

**Snapshot.** Skip.

## Step 11: `z.window.setClipboardText` + `getClipboardText`

**Functions.**
```zig
pub fn setClipboardText(text: []const u8) void
pub fn getClipboardText(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8
```

**Body.** Clipboard API — `navigator.clipboard.writeText` /
`readText`.  Async on the JS side; the read returns a promise we
resolve before returning.  Host stub: tracks a process-wide string.

**Reference.** raylib's `core_clipboard_text.c` example.

**Tests.** Host: 1 round-trip — set then get matches.  Smoke: 1 —
call set, mock writeText records the call.

**Example.** `examples/clipboard.zig` — text field that copies on
button press.  Mirror `examples/core/core_clipboard_text.c`.

**Cheatsheet.** Update `z.window` row.

**Changelog.** "Phase 2 step 11: clipboard text I/O + example".

**Snapshot.** Skip.

## Step 12: `z.window.getClipboardImage`

**Function.**
```zig
pub fn getClipboardImage(gpa: std.mem.Allocator) types.LoadError!Image
```

**Body.** `navigator.clipboard.read()` — finds an `image/png` clipboard
item, reads it as ArrayBuffer, decodes via existing zigimg.  Host
stub: returns `error.NotImplemented`.

**Reference.** raylib's `examples/textures/textures_clipboard_image.c`.

**Tests.** Host: 1 — host stub returns the expected error.  Smoke: 1
— mock the API to provide a 1×1 PNG, verify the decode path.

**Example.** `examples/clipboard_image.zig` — paste-image-into-window
demo.  Mirror raylib's example.

**Cheatsheet.** No change.

**Changelog.** "Phase 2 step 12: getClipboardImage + example".

**Snapshot.** `turn-step12-clipboard`.

## Step 13: `z.window.takeScreenshot`

**Function.**
```zig
pub fn takeScreenshot(filename: []const u8) void
```

**Body.** wasm: `dom.take_screenshot(ptr, len)` triggers
`canvas.toBlob` then anchor-with-download trick.  Host stub: no-op.

**Reference.** raylib's `rcore.c::TakeScreenshot`.

**Tests.** Host: 1 — doesn't panic.  Smoke: 1 — verify download
trigger fires with the filename.

**Example.** Extend `examples/window_demo.zig` — S key triggers a
screenshot named `zimr-frame-{counter}.png`.

**Cheatsheet.** Update `z.window` row.

**Changelog.** "Phase 2 step 13: takeScreenshot + window demo wraps".

**Snapshot.** `turn-step13-phase2-complete`.  Re-run generator;
expect coverage ~80%.

---

# Phase 3 — Render-stack completion (steps 14-26, ~full day)

## Step 14: `z.textures.loadImageFromTexture`

**Function.**
```zig
pub fn loadImageFromTexture(
    gpa: std.mem.Allocator,
    texture: Texture2D,
) types.LoadError!Image
```

**Body.** Bind a temporary FBO to the texture, `gl.readPixels` into a
gpa-allocated buffer, return as RGBA8 Image.  Use existing
`createReadbackFramebuffer` helper if present, otherwise add it to
`rlgl.zig`.

**Reference.** raylib's `rtextures.c::LoadImageFromTexture`.  Example:
`examples/textures/textures_to_image.c`.

**Tests.** Host: skipped (needs GPU).  Smoke: 1 — upload known
RGBA8 bytes via `loadTextureFromImage`, read back via
`loadImageFromTexture`, verify byte-for-byte match.

**Example.** `examples/texture_readback.zig` — render some shapes to
an offscreen texture, read back, save first 100 bytes to clipboard
or display the readback as another texture.

**Cheatsheet.** Add to texture-loading subsection.

**Changelog.** "Phase 3 step 14: loadImageFromTexture (gl.readPixels)".

**Snapshot.** Skip.

## Step 15: `z.textures.loadImageFromScreen`

**Function.**
```zig
pub fn loadImageFromScreen(gpa: std.mem.Allocator) types.LoadError!Image
```

**Body.** Same plumbing as step 14 but reading from the default
framebuffer (binding 0).  Returns an Image with current canvas
dimensions × RGBA8.

**Reference.** raylib's `rtextures.c::LoadImageFromScreen`.

**Tests.** Smoke: 1 — clear to a known color, read back, verify
center pixel.

**Example.** Extend the screenshot logic in `examples/window_demo.zig`
to use `loadImageFromScreen` (compose-then-encode-then-download
instead of the canvas.toBlob trick).

**Cheatsheet.** Updated by step 14.

**Changelog.** "Phase 3 step 15: loadImageFromScreen".

**Snapshot.** `turn-step15-readback`.

## Step 16: `z.textures.imageText`

**Function.**
```zig
pub fn imageText(
    gpa: std.mem.Allocator,
    text: []const u8,
    font_size: c_int,
    color: Color,
) types.ImageGenError!Image
```

**Body.** Use the default font (already accessible).  Walk codepoints,
look up glyph rectangles in the atlas, blit each glyph to a CPU image
buffer.  Returns an RGBA8 Image sized to the text's bounding box.

**Reference.** raylib's `rtextures.c::ImageText`.  Example:
`examples/textures/textures_image_text.c`.

**Tests.** Host: 1 — render "A", verify non-zero pixels exist.  Host:
1 — empty string returns 1x1 transparent image (or
`error.InvalidDimensions`).

**Example.** Extend `examples/text_on_texture.zig` to use the new
`imageText`-based approach as one panel, contrast with the GPU-side
text drawing.

**Cheatsheet.** Add a "CPU-side text rendering" idiom.

**Changelog.** "Phase 3 step 16: imageText (CPU text → Image)".

**Snapshot.** Skip.

## Step 17: `z.textures.imageTextEx`

**Function.**
```zig
pub fn imageTextEx(
    gpa: std.mem.Allocator,
    font: Font,
    text: []const u8,
    font_size: f32,
    spacing: f32,
    tint: Color,
) types.ImageGenError!Image
```

**Body.** Variant of step 16 taking an explicit font + spacing.

**Reference.** raylib's `rtextures.c::ImageTextEx`.

**Tests.** Host: 1 — custom-font variant produces non-zero output.

**Example.** Same as step 16 (extend `text_on_texture.zig`).

**Cheatsheet.** No change.

**Changelog.** Continue step-16 entry.

**Snapshot.** `turn-step17-image-text`.

## Step 18: `z.textures.imageFormat`

**Function.**
```zig
pub fn imageFormat(
    gpa: std.mem.Allocator,
    image: *Image,
    new_format: PixelFormat,
) std.mem.Allocator.Error!void
```

**Body.** Convert pixel format in-place.  Allocate a new buffer of
the right size (we already have `getPixelDataSize` from the aggressive
sweep).  Walk every pixel via `getImageColor`/the typed format
dispatch already in place from turn 3.  Free the old buffer; install
the new.  Update `image.format`.

**Reference.** raylib's `rtextures.c::ImageFormat` is a 200-line
switch — read it, port the dispatch using `PixelFormat` enum-tag
switch (turn 3 idiom).

**Tests.** Host: 4 — RGBA8→GRAYSCALE, GRAYSCALE→RGBA8, RGBA8→R5G6B5,
unsupported-format-pair returns `error.InvalidDimensions` or no-op.

**Example.** `examples/image_format.zig` — load a colorful image,
convert to GRAYSCALE then back to RGBA8, draw both side-by-side.
Mirror raylib's `examples/textures/textures_image_loading.c`.

**Cheatsheet.** Update textures section.

**Changelog.** "Phase 3 step 18: imageFormat (typed pixel-format
conversion)".

**Snapshot.** `turn-step18-image-format`.

## Step 19: `z.models.updateMeshBuffer`

**Function.**
```zig
pub fn updateMeshBuffer(
    mesh: Mesh,
    buffer_index: c_int,
    data: []const u8,
    offset: c_int,
) void
```

**Body.** `gl.bufferSubData(GL_ARRAY_BUFFER, offset, data)` after
binding the right VBO from `mesh.vboId[buffer_index]`.

**Reference.** raylib's `rmodels.c::UpdateMeshBuffer`.

**Tests.** Smoke: 1 — upload a mesh, modify its vertex 0's x via
updateMeshBuffer, render, readback verifies the change visible.

**Example.** `examples/dynamic_mesh.zig` — single quad whose vertex
positions oscillate frame-by-frame using updateMeshBuffer.  Mirror
patterns from `models/models_mesh_generation.c`.

**Cheatsheet.** Add to mesh idioms.

**Changelog.** "Phase 3 step 19: updateMeshBuffer + dynamic mesh
example".

**Snapshot.** Skip.

## Step 20: `z.rlgl.rlActiveDrawBuffers` (MRT)

**Function.**
```zig
pub fn rlActiveDrawBuffers(count: c_int) void
```

**Body.** wasm: `gl.drawBuffers([GL_COLOR_ATTACHMENT0, ...,
GL_COLOR_ATTACHMENT(count-1)])`.  Validate count is 1..8.

**Reference.** raylib's `rlgl.h::rlActiveDrawBuffers`.

**Tests.** Smoke: 1 — call with count=2, verify GL state reflects.

**Example.** `examples/mrt_demo.zig` — render to two color attachments
(albedo + normals), composite in second pass.  Mirror raylib's
`shaders/shaders_deferred_rendering.c` simplified.

**Cheatsheet.** Add a "Multiple render targets" idiom.

**Changelog.** "Phase 3 step 20: rlActiveDrawBuffers + MRT example".

**Snapshot.** `turn-step20-mrt`.

## Step 21: `z.rlgl.rlCubemapParameters`

**Function.**
```zig
pub fn rlCubemapParameters(
    id: c_uint,
    param: c_int,
    value: c_int,
) void
```

**Body.** Bind cubemap, `gl.texParameteri(TEXTURE_CUBE_MAP, …)`.

**Reference.** raylib's `rlgl.h::rlCubemapParameters`.

**Tests.** Smoke: 1 — set wrap mode on the existing skybox cubemap,
verify visually unchanged (wrap modes don't matter for a cubemap so
this is just an "doesn't crash" smoke).

**Example.** Extend `examples/skybox.zig` to demonstrate setting
GL_TEXTURE_MIN_FILTER to LINEAR_MIPMAP_LINEAR.

**Cheatsheet.** No change.

**Changelog.** "Phase 3 step 21: rlCubemapParameters".

**Snapshot.** Skip.

## Step 22: `z.rlgl.rlColorMask`

**Function.**
```zig
pub fn rlColorMask(r: bool, g: bool, b: bool, a: bool) void
```

**Body.** `gl.colorMask(r, g, b, a)`.

**Reference.** raylib's `rlgl.h::rlColorMask`.

**Tests.** Smoke: 1 — disable green, draw white, readback shows
red+blue only.

**Example.** Extend `examples/shader.zig` or add a tiny `examples/color_mask.zig`
that demonstrates a "stencil-like" effect using mask.

**Cheatsheet.** No change.

**Changelog.** "Phase 3 step 22: rlColorMask".

**Snapshot.** Skip.

## Step 23: `z.rlgl.rlGetActiveFramebuffer`

**Function.**
```zig
pub fn rlGetActiveFramebuffer() c_uint
```

**Body.** `gl.getParameter(FRAMEBUFFER_BINDING)`.  Returns 0 for
default FBO.

**Reference.** raylib's `rlgl.h::rlGetActiveFramebuffer`.

**Tests.** Smoke: 1 — default FBO returns 0; after `beginTextureMode`
returns the target's id; after `endTextureMode` returns 0 again.

**Example.** Skip — utility used internally.

**Cheatsheet.** No change.

**Changelog.** "Phase 3 step 23: rlGetActiveFramebuffer".

**Snapshot.** `turn-step23-rlgl-utility`.

## Step 24: `z.rlgl.rlSetUniformMatrices`

**Function.**
```zig
pub fn rlSetUniformMatrices(loc: c_int, mats: []const Matrix) void
```

**Body.** `gl.uniformMatrix4fv(loc, transpose=false,
flatten(mats))`.  Validate `mats.len > 0`.

**Reference.** raylib's `rlgl.h::rlSetUniformMatrices`.

**Tests.** Smoke: 1 — upload 4 matrices to a test shader, verify
shader sees them via a redout color sampling per-instance.

**Example.** Skip (used internally by step 38's skinning shader).

**Cheatsheet.** No change yet (will surface via skinning example).

**Changelog.** "Phase 3 step 24: rlSetUniformMatrices (slice-shape)".

**Snapshot.** Skip.

## Step 25: `z.rlgl.rlResizeFramebuffer`

**Function.**
```zig
pub fn rlResizeFramebuffer(
    target: c_uint,
    width: c_int,
    height: c_int,
) void
```

**Body.** Reallocate the color and depth attachments at the new size.
Internal helper that walks the FBO's attachment list.

**Reference.** raylib's `rlgl.h::rlResizeFramebuffer`.

**Tests.** Smoke: 1 — create a 64×64 RTT, resize to 128×128, verify
draw at new size produces output.

**Example.** Extend `examples/rtt.zig` to dynamically resize on
window-resize event.

**Cheatsheet.** No change.

**Changelog.** "Phase 3 step 25: rlResizeFramebuffer".

**Snapshot.** Skip.

## Step 26: `z.rlgl.rlCopyFramebuffer`

**Function.**
```zig
pub fn rlCopyFramebuffer(
    src_id: c_uint,
    dst_id: c_uint,
    src_x: c_int, src_y: c_int,
    width: c_int, height: c_int,
) void
```

**Body.** `gl.bindFramebuffer(READ_FRAMEBUFFER, src)`,
`gl.bindFramebuffer(DRAW_FRAMEBUFFER, dst)`,
`gl.blitFramebuffer(...)`.

**Reference.** raylib's `rlgl.h::rlCopyFramebuffer`.

**Tests.** Smoke: 1 — render to FBO A, copy to FBO B, sample B
matches.

**Example.** `examples/pingpong_blur.zig` — two-pass Gaussian blur
using two FBOs that ping-pong via `rlCopyFramebuffer`.  Mirror
`shaders/shaders_blur.c`.

**Cheatsheet.** No change.

**Changelog.** "Phase 3 step 26: rlCopyFramebuffer + pingpong-blur
example.  Phase 3 complete; coverage ~85%".

**Snapshot.** `turn-step26-phase3-complete`.  Re-run generator and
update `coverage-report.md`.  Update the "raylib coverage" section in
CHEATSHEET.md.

---

# Phase 4 — Bigger arcs (steps 27-40)

## Sub-arc 4a: Touch input + gestures (steps 27-32)

## Step 27: dom.js touch event wiring

**What.** Add touch event handlers to `src/web/dom.js`:
`touchstart`, `touchmove`, `touchend`, `touchcancel`.  Each pushes
event data into the wasm via existing input-push fns.  Add new
exports `input_push_touch_down(id, x, y)`, `input_push_touch_move(id,
x, y)`, `input_push_touch_up(id)`.

**Reference.** raylib's `core/rcore_*.c` (search `touch`); zimr's
existing key/mouse handlers are the template.

**Tests.** Smoke: 1 — synthesize a touch sequence in JS, verify wasm
state reflects.

**Example.** None yet (step 28 will add).

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 27: touch event JS wiring".

**Snapshot.** Skip.

## Step 28: `z.input` touch primitives

**Functions.**
```zig
pub fn getTouchX() c_int
pub fn getTouchY() c_int
pub fn getTouchPosition(index: c_int) Vector2
pub fn getTouchPointId(index: c_int) c_int
pub fn getTouchPointCount() c_int
```

**Body.** Extend `src/runtime.zig`'s `input.STATE` with a `touches:
[MAX_TOUCH_POINTS]TouchPoint` slot.  Read functions index into it.
`MAX_TOUCH_POINTS = 10` (matches raylib).

**Reference.** raylib's `rcore.c::GetTouchX` etc.

**Tests.** Host: 4 tests — push synthesized touches via
`input_push_touch_*`, read back via the public getters, verify
correctness.

**Example.** `examples/touch_paint.zig` — finger-painting demo.  Each
touch point leaves a colored circle behind.  No raylib equivalent in
core/ but `gestures` examples have similar shape.

**Cheatsheet.** Add a `touch` row to the input section.

**Changelog.** "Phase 4 step 28: touch primitives + paint example".

**Snapshot.** `turn-step28-touch-input`.

## Step 29: gesture detection state machine

**Module.** Create `src/gestures.zig` exposed as `z.gestures`.
Internal state machine consumes touch events and emits gesture
detections (tap, double-tap, hold, swipe-left/right/up/down,
pinch-in/out, rotate-cw/ccw).  Mirrors raylib's `rgestures.h`.

**Reference.** raylib's `rgestures.h` (it's all in one header — port
the state machine).

**Tests.** Host: 5 — synthesize touch sequences for each gesture
type, verify detector emits the right enum.

**Example.** None yet (step 31 covers).

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 29: gesture state machine".

**Snapshot.** Skip.

## Step 30: `z.gestures` public API

**Functions.**
```zig
pub fn isGestureDetected(gesture: Gesture) bool
pub fn getGestureDetected() Gesture
pub fn getGestureHoldDuration() f32
pub fn getGestureDragVector() Vector2
pub fn getGestureDragAngle() f32
pub fn getGesturePinchVector() Vector2
pub fn getGesturePinchAngle() f32
pub fn setGesturesEnabled(flags: GestureFlags) void
```

**Body.** Read state from the step-29 detector.  `Gesture` is an
enum with the 8 detectable types.  `GestureFlags` is a packed-struct
mask.

**Reference.** raylib's `rgestures.h`.

**Tests.** Host: 5 — for each gesture, verify the corresponding
getters return non-default values.

**Example.** None yet (step 31).

**Cheatsheet.** Add `z.gestures` row.

**Changelog.** "Phase 4 step 30: gestures public API".

**Snapshot.** Skip.

## Step 31: gestures example

**What.** `examples/gestures_demo.zig` — recreates raylib's
`core/core_input_gestures.c`.  Display the most-recent gesture name
+ relevant data (pinch distance, swipe direction).  Touch-only;
shows graceful no-op on desktop.

**Tests.** Smoke: build only.

**Cheatsheet.** Update `z.gestures` row with example reference.

**Changelog.** "Phase 4 step 31: gestures example.  Sub-arc 4a
complete".

**Snapshot.** `turn-step31-gestures-complete`.

## Step 32: gesture testbed example

**What.** `examples/gestures_testbed.zig` — recreates raylib's
`core/core_input_gestures_testbed.c`.  Live visualization of the
state machine.  Useful for QA.

**Tests.** Smoke: build only.

**Cheatsheet.** No change.

**Changelog.** "Phase 4 step 32: gestures testbed example".

**Snapshot.** Skip.

## Sub-arc 4b: glTF model loading (steps 33-36)

## Step 33: vendor / scaffold a glTF parser

**What.** Add `src/vendor/gltf.zig` — a minimal pure-Zig glTF 2.0
parser that handles:
- the JSON header (use `std.json`)
- buffer view + accessor indirection
- glb container (binary bundle: header + JSON + binary chunk)
- POSITION / NORMAL / TEXCOORD_0 / JOINTS_0 / WEIGHTS_0 attributes
- scalar/vec3/vec4 component types: `f32`, `u16`, `u8`

Skip for now: animations (step 37 handles), morph targets, sparse
accessors, KHR extensions other than `KHR_materials_unlit`.

**Reference.** Existing zigglgen / mach-glTF / zgltf if any are
small enough to vendor; otherwise hand-roll.  raylib's
`external/cgltf.h` is the C reference implementation.

**Tests.** Host: 5 — parse a tiny embedded glb (e.g., a single
triangle stored as bytes literal), verify expected mesh structure.

**Example.** None yet.

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 33: glTF parser scaffolding (~600 LOC)".

**Snapshot.** `turn-step33-gltf-scaffold`.

## Step 34: `z.models.loadModelFromMemory`

**Function.**
```zig
pub fn loadModelFromMemory(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    fmt: ModelFormat,  // .gltf | .glb (later: .obj, .iqm)
) types.LoadError!Model
```

**Body.** Use the step-33 parser to walk meshes, materials, textures.
Build zimr Mesh objects via `uploadMesh`.  Build Material list with
texture refs.  Wire up the Model's mesh/material arrays.

**Reference.** raylib's `rmodels.c::LoadModel` + `LoadModelFromMemory`.

**Tests.** Host: 1 (in-memory glb of a quad).  Smoke: 1 — load,
render, verify a non-zero pixel near center.

**Example.** None yet (step 36).

**Cheatsheet.** Add to models idioms.

**Changelog.** "Phase 4 step 34: loadModelFromMemory(glTF/glb)".

**Snapshot.** Skip.

## Step 35: glTF texture + material wiring

**What.** Hook the glTF parser's PBR material info (`baseColorTexture`,
`metallicRoughnessTexture`) into zimr's `Material` struct.  Decode
embedded image bytes via existing zigimg path.  Resolve texture
indices to GPU texture ids during model load.

**Tests.** Host: 1 — load a textured glTF, verify Model.materials
has the expected texture ids.

**Example.** None yet (step 36).

**Cheatsheet.** No change.

**Changelog.** "Phase 4 step 35: glTF texture/material wiring".

**Snapshot.** `turn-step35-gltf-textures`.

## Step 36: glTF model example

**What.** `examples/gltf_model.zig` — load an embedded glb (small
animated character, public-domain).  Render with rotation.  Mirror
`models/models_loading_gltf.c`.

**Resources.** Embed a 5-10 KB glb via `@embedFile`.  Choose a
permissively-licensed model (e.g., CC0 from Sketchfab or
public-domain rigged cube).

**Tests.** Smoke: build + run-1-frame validates load + render path.

**Cheatsheet.** Update models idioms.

**Changelog.** "Phase 4 step 36: glTF example.  Sub-arc 4b complete".

**Snapshot.** `turn-step36-gltf-complete`.

## Sub-arc 4c: Skinned-mesh animation (steps 37-40)

## Step 37: skin matrix infrastructure

**What.** Add to `src/models.zig`:
- `BoneInfo` struct (already exists in zimr's types as part of glTF
  parsing in step 33).
- `Transform` struct (already exists).
- The skinning vertex shader path: extend the default 3D shader to
  read `inJoints` (vec4 u8), `inWeights` (vec4 f32), and a
  `boneMatrices[MAX_BONES]` uniform array (max 128).
- The CPU-side bone palette: a flat `[]Matrix` that the vertex shader
  indexes via `inJoints`.

**Tests.** Smoke: 1 — render a static skinned mesh with identity
bone matrices, verify it looks the same as without skinning.

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 37: skinning shader + bone-palette
infrastructure".

**Snapshot.** Skip.

## Step 38: `z.models.updateModelAnimation`

**Function.**
```zig
pub fn updateModelAnimation(
    model: *Model,
    anim: ModelAnimation,
    frame: c_int,
) void
```

**Body.** Sample `anim.framePoses[frame]` (a `[]Transform`),
combine with each bone's `bindPose` inverse to produce
`boneMatrices[i] = anim_pose[i] * bind_inverse[i]`, upload via
`rlSetUniformMatrices`.

**Reference.** raylib's `rmodels.c::UpdateModelAnimation` (~80 LOC).

**Tests.** Host: 1 — synthetic animation of a single 1-bone model;
frame 0 vs frame 5 produces different bone matrices.  Smoke: 1.

**Example.** None yet (step 40).

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 38: updateModelAnimation".

**Snapshot.** `turn-step38-skinning-update`.

## Step 39: `z.models.updateModelAnimationEx` (cross-fade)

**Function.**
```zig
pub fn updateModelAnimationEx(
    model: *Model,
    anim_a: ModelAnimation, frame_a: c_int,
    anim_b: ModelAnimation, frame_b: c_int,
    blend: f32,
) void
```

**Body.** Per-bone slerp/lerp between the two animations' poses,
weighted by `blend ∈ [0, 1]`.

**Reference.** raylib's `rmodels.c::UpdateModelAnimationBlend`
(but raylib's signature is `(...frame, dt)` for in-place blend; we'd
take both anims and the blend amount explicitly — slightly more
ergonomic).

**Tests.** Host: 1 — blend=0 matches anim A; blend=1 matches anim B;
blend=0.5 lies between (each component within bounds).

**Example.** None yet (step 40).

**Cheatsheet.** No change yet.

**Changelog.** "Phase 4 step 39: updateModelAnimationEx (cross-fade)".

**Snapshot.** Skip.

## Step 40: skinned-mesh example + final consolidation

**What.**
- `examples/skinned_mesh.zig`: load the embedded animated glb (from
  step 36, or a separate one with animation), play its animation,
  use space bar to crossfade between two anims.  Mirror raylib's
  `models/models_animation_gpu_skinning.c`.
- Final pass on:
  - `notes/ziggification-candidates.md` — close out all 4 phases,
    record final coverage %.
  - `notes/raylib-coverage-plan.md` — mark all phases complete.
  - `notes/raylib-coverage-gaps.md` — strike through everything
    handled.
  - `CHEATSHEET.md` — final coverage % and the migration cheat sheet
    for raylib porters.
  - Re-run cheatsheet generator, expect coverage ~92% in-scope.

**Tests.** Smoke: example builds + runs 1 frame.

**Changelog.** "Phase 4 step 40: skinned-mesh example.  All four
phases complete.  Coverage 77.1% → ~92%".

**Snapshot.** `turn-step40-FINAL` — final state of the 40-step
expansion.

---

## Per-step gate checklist

Before marking any step "done":

- [ ] `zig build test --summary all` → green, count increased
- [ ] `zig build smoke-test --summary all` → 60/60 (or higher if a new example added a smoke test)
- [ ] `notes/CHANGELOG.md` has an entry under `[Unreleased]`
- [ ] `CHEATSHEET.md` reflects new public surface where applicable
- [ ] Example file at `examples/<name>.zig` references the raylib
      example it's based on in a top-of-file doc comment
- [ ] Snapshot saved if step is a "snapshot" point per the plan

## How to resume after an interruption

1. Verify clean state:
   ```sh
   cd /home/claude/zimr
   export PATH=/home/claude/bin:$PATH
   zig build test --summary all && zig build smoke-test --summary all
   ```
2. Identify the last completed step from `notes/CHANGELOG.md`'s
   `[Unreleased]` section.
3. Continue from the next step in this file.
4. If the working tree shows uncommitted progress on an in-flight
   step, finish that step (re-running the gate checklist).

## Snapshots cadence

The plan saves a snapshot at the end of these steps:
1, 3, 5, 6, 9, 12, 13, 15, 17, 18, 20, 23, 26, 28, 31, 33, 35, 36,
38, 40.  That's 20 snapshots across 40 steps — every other step on
average, biased toward sub-arc completions and risky changes
(framebuffer / glTF / skinning).

## Coverage trajectory

| After step | Expected coverage | Notes |
|-----------:|------------------:|-------|
|  1 | ~78% | Rename-map only — no code |
| 13 | ~80% | Phase 2 done; +12 fns including `z.window` |
| 26 | ~85% | Phase 3 done; +13 fns including 7 rlgl |
| 32 | ~87% | Touch + gestures done (~13 fns) |
| 36 | ~90% | glTF loading done (+5 fns) |
| 40 | ~92% | Skinning done; final consolidation |

Audio (65 functions, 8.4% of in-scope) stays deferred — that arc is
its own multi-week effort.
