# raylib-coverage plan (v2): 77.1 % → ~93 %

> **Status.** Replaces `coverage-plan-v1.md`.  Same destination
> (~93 % in-scope coverage of raylib 6.0); different routing.
> Written from end-to-end source study of every file the plan
> touches — v1 was written before reading the actual source and
> had ten meaningful errors (see [§ Diff from v1](#diff-from-v1)).
>
> 43 steps across 7 phases.  Each step = one shippable commit:
> code → inline tests → optional example → cheatsheet bump →
> changelog line → `zig build test && zig build smoke-test`.

## Hard rules

1. **Style guide rules 1-7** (`src/notes/style-guide.md`).  In
   particular: one arg per line for >1-arg fns, mandatory braces,
   explicit local types unless already on the line, `@splat`
   over `**`, examples avoid module-level mutable globals.
2. **Tests live next to the function.**  `src/ui.zig` already
   does this; `src/tests.zig` already pulls it in.  Add
   `runtime.zig`/`drawing.zig`/`codecs.zig`/`rlgl.zig` to that
   list as soon as they grow inline tests.
3. **Flat layout in `src/`** — current is 10 files; target is
   ≤ 12.  No new top-level files.  The glTF parser (Phase 5) is
   written zimr-style and lives as a `pub const gltf = struct`
   namespace inside `codecs.zig` (alongside `png` / `truetype`).
   Breaking changes are fine — examples can be rewritten freely.
4. **One example per significant feature**, modeled on raylib's
   counterpart.  Examples are appended to `build.zig`'s
   `examples` array — without that, smoke won't load them.
5. **Smoke-test reality.**  `webtests/smoke.ts` runs each example
   for 60 simulated rAF ticks and asserts (a) no panic, (b) ≥100
   GL calls.  No per-function smoke assertions.  "Smoke
   coverage" means an example exercises the path so the smoke
   run reaches it.
6. CHEATSHEET.md bumped same commit as new surface (% always;
   plus "Modules at a glance" / "Common idioms" when relevant).
7. CHANGELOG.md `[Unreleased]` gets one line per step.
8. `/home/claude/snapshots/save.sh <label>` at every milestone
   step — see [§ Snapshot cadence](#snapshot-cadence).
9. After every step: `zig build test --summary all && zig build
   smoke-test --summary all`.  Don't advance with red.

**Reference repo:** `/home/claude/raylib-ref/raylib-master/`.
Read `.c` source (not `.h`) for porting guidance.

## Plan summary

| Phase | Steps | Theme | New fns |
|-------|------:|-------|--------:|
| 0 | 1 | Generator audit + rename-map fixes | 0 |
| 1 | 2-5 | Tiny self-contained adds | 4 |
| 2 | 6-10 | Browser bridges (window/clip/screenshot) | 9 |
| 3 | 11-22 | Render stack: GL bindings, RTT scope, readback, imageFormat | 13 |
| 4 | 23-30 | Touch input + gestures | 14 |
| 5 | 31-38 | glTF loading (custom, zgltf-inspired) | 5 |
| 6 | 39-43 | Skinned-mesh animation | 3 |
|   | | **Totals** | **48 fns + 14 rename-map → ~93 %** |

Trajectory: 77.1 → 79 (after step 1) → 80 (5) → 82 (10) →
87 (22) → 89 (30) → 91 (38) → 93 (43).

## Diff from v1

Found ten meaningful errors in v1 by reading the actual source:

| # | v1 said | Ground truth | v2 |
|---|---------|--------------|-----|
| 1 | Add `getSplinePointBezierQuadratic` | `getSplinePointBezierQuad` already at `drawing.zig:152` | rename-map only |
| 2 | Add `imageDrawRectangleLinesEx` | `imageDrawRectangleLines(dst, rec, thick, color)` already exists with raylib's *Ex* signature at `drawing.zig:2440` | rename-map only |
| 3 | Add `rlCopyFramebuffer` | raylib's is software-renderer-only; no-op on WebGL2.  Real readback path is `glReadPixels` (not bound yet) | dropped; replaced with proper `glReadPixels` binding in Step 11 |
| 4 | Create `src/window.zig` | `dom.set_title` already exists at `web.zig:57`; mouse fns at `runtime.zig:1086-1124` | functions go into existing `core` namespace |
| 5 | Create `src/gestures.zig` | Big-file rule | goes into `runtime.zig` next to `input` |
| 6 | Create `src/vendor/gltf.zig` | Big-file rule + user wants zimr-style not vendored | rewritten zimr-style as `pub const gltf = struct` inside `codecs.zig` |
| 7 | "smoke: 1 — verify GL state" | smoke just runs example for 60 frames | recast as "example exercises the path" |
| 8 | Skinning infrastructure absent | `Mesh.boneIndices`/`boneWeights`, `Model.boneMatrices`, `ModelSkeleton.bindPose`, `ModelAnimation.keyframePoses`, `SHADER_LOC_MATRIX_BONETRANSFORMS`, `UNIFORM_BONEMATRICES = "boneMatrices"` ALL exist | Step 39 only adds skinning vertex shader + branching |
| 9 | Rename-map `SetMouseCursor` | doesn't exist in zimr | Step 1 removes |
| 10 | Step 14 calls `gl.readPixels` | not bound in `web.zig` | Step 11 binds it first |

## Pre-flight check

```sh
cd /home/claude/zimr
export PATH=/home/claude/bin:$PATH
zig build test --summary all && zig build smoke-test --summary all
# Expect: 594 pass / 60 of 60
```

## Snapshot cadence

| After step | Label | Why |
|-----------:|-------|-----|
|  1 | `step-01-rename-map` | v2 baseline |
|  5 | `step-05-phase1-done` | ~80 % |
| 10 | `step-10-phase2-done` | Browser bridges live |
| 11 | `step-11-glreadpixels` | First new GL JS binding (risky) |
| 17 | `step-17-readback-live` | First end-to-end readback |
| 19 | `step-19-imagetext-done` | CPU text |
| 22 | `step-22-phase3-done` | ~87 % |
| 25 | `step-25-touch-input` | Touch primitives live |
| 30 | `step-30-phase4-done` | ~89 % |
| 31 | `step-31-gltf-types` | glTF type defs (risky) |
| 35 | `step-35-gltf-load-live` | First glTF rendered |
| 38 | `step-38-phase5-done` | ~91 % |
| 40 | `step-40-skin-shader` | Default-shader divergence (risky) |
| 43 | `step-43-FINAL` | ~93 % |

---

# Phase 0 — Generator audit (1 step)

## Step 1 · `RAYLIB_TO_ZIMR_RENAMES` audit

**Goal.** Every entry in the rename map at
`src/notes/cheatsheet-generator.py` resolves to a real zimr fn.

**Touches.** `src/notes/cheatsheet-generator.py` only.

**Procedure.** For each `(rname, (module, target))`, verify
`pub fn $TARGET\b` exists somewhere in `src/`.  Module-aware
grep — `text` lives in `drawing.zig`, `core` in `runtime.zig`.
Add `DEBUG_RENAMES` flag at top; when true, `find_zimr` warns to
stderr on missing target.  Future audits aren't manual.

**Remove (stale):** `"SetMouseCursor"` — `setMouseCursor` doesn't
exist.

**Add (14):**
```python
"LoadShader":                    ("shaders",  "loadShader"),
"LoadShaderFromMemory":          ("shaders",  "loadShaderFromMemory"),
"UnloadShader":                  ("shaders",  "unloadShader"),
"IsGamepadButtonPressed":        ("input",    "isGamepadButtonPressed"),
"IsGamepadButtonDown":           ("input",    "isGamepadButtonDown"),
"IsGamepadButtonReleased":       ("input",    "isGamepadButtonReleased"),
"IsGamepadButtonUp":             ("input",    "isGamepadButtonUp"),
"GetGamepadAxisMovement":        ("input",    "getGamepadAxisMovement"),
"UnloadTexture":                 ("textures", "unloadTexture"),
"TraceLog":                      ("core",     "traceLog"),
"IsCursorOnScreen":              ("input",    "isCursorOnScreen"),
"GetSplinePointBezierQuadratic": ("shapes",   "getSplinePointBezierQuad"),
"ImageDrawRectangleLinesEx":     ("textures", "imageDrawRectangleLines"),
"ImageDrawTriangleGradient":     ("textures", "imageDrawTriangleEx"),
```

**Verify.** `python3 src/notes/cheatsheet-generator.py | grep
"Coverage of in-scope"` — expect ~78-79 % (up from 77.1 %).

**Cheatsheet.** Bump %.  
**Changelog.** `Step 1: rename-map audit (+14, –1 stale)`.  
**Snapshot.** `step-01-rename-map`.

---

# Phase 1 — Tiny self-contained adds (steps 2-5)

No JS-bridge dependencies, no cross-cutting changes.  Each adds
1 fn into an existing big file with inline tests.

## Step 2 · `z.shapes.drawTriangleGradient`

**Goal.** GPU per-vertex-color triangle.

**Touches.**
- `src/drawing.zig` `shapes` namespace — add near `drawTriangleStrip`
  (line ~551).
- `examples/triangle_gradient.zig` (new, ~80 LOC).
- `build.zig` — append `"triangle_gradient"` to `examples`.

**Body.**
```zig
pub fn drawTriangleGradient(
    v1: Vector2, v2: Vector2, v3: Vector2,
    c1: Color, c2: Color, c3: Color,
) void {
    rlBegin(RL_TRIANGLES);
    rlColor4ub(c1.r, c1.g, c1.b, c1.a); rlVertex2f(v1.x, v1.y);
    rlColor4ub(c2.r, c2.g, c2.b, c2.a); rlVertex2f(v2.x, v2.y);
    rlColor4ub(c3.r, c3.g, c3.b, c3.a); rlVertex2f(v3.x, v3.y);
    rlEnd();
}
```
(Style note: real impl uses one-arg-per-line per rule 1.)

**Reference.** `examples/shapes/shapes_basic_shapes.c`
(`DrawTriangleGradient`); body at `rshapes.c::DrawTriangleGradient`.

**Inline test.** "Doesn't trap with valid input" + "doesn't trap
with degenerate (collinear) input".  Host-side; visual via example.

**Example.** `triangle_gradient.zig` — three flag-style triangles
whose corners pulse with `f.clock.time()`.

**Cheatsheet.** "Common idioms → Drawing 2D shapes" gets one line.  
**Changelog.** `Step 2: drawTriangleGradient + example`.  
**Verify.** test +2 (596); smoke 61 of 61.  
**Snapshot.** No.

## Step 3 · `z.text.genImageFontAtlas` (expose internal)

**Goal.** Promote the internal `bakeFontAtlas` (find via
`grep -n "fn bakeFontAtlas" src/drawing.zig`) to public surface
under raylib's name.

**Touches.** `src/drawing.zig` `text` namespace.

**Approach.** Rename `bakeFontAtlas` → `genImageFontAtlas`, leave a
private `const bakeFontAtlas = genImageFontAtlas;` if internal
callers exist.  Adjust signature if needed for raylib parity:

```zig
pub fn genImageFontAtlas(
    gpa: std.mem.Allocator,
    glyphs: []const GlyphInfo,
    font_size: c_int,
    padding: c_int,
    pack_method: c_int, // 0 = default, 1 = skyline
) std.mem.Allocator.Error!struct { atlas: Image, recs: []Rectangle }
```

**Reference.** `rtext.c::GenImageFontAtlas`.

**Inline test.** Bake a 4-glyph atlas from the default font; verify
atlas dims are power-of-2 and per-glyph recs lie within bounds.

**Example.** None; existing `text_layout.zig` already exercises
the internal — promotion is mostly cosmetic.

**Cheatsheet.** Modules table gets `genImageFontAtlas` mention.  
**Changelog.** `Step 3: genImageFontAtlas exposure`.  
**Verify.** test +1 (597); smoke 60 of 60.  
**Snapshot.** No.

## Step 4 · `z.input.setGamepadVibration`

**Goal.** Wire the Gamepad Haptics API.

**Touches.**
- `src/web/zimr.ts` — add `js_gamepad_vibrate(idx, left, right, ms)`
  using `navigator.getGamepads()[idx]?.vibrationActuator?.playEffect(…)`.
- `src/web.zig` `dom` — `extern "dom" fn js_gamepad_vibrate(...)`.
- `webtests/smoke.ts` — mock `js_gamepad_vibrate: () => {}`.
- `src/runtime.zig` `input` — `pub fn setGamepadVibration(...)` near
  `getGamepadAxisMovement` (line ~1009).

**Body** (Zig side):
```zig
pub fn setGamepadVibration(
    gamepad: c_int,
    left_motor: f32,
    right_motor: f32,
    duration: f32,
) void {
    if (comptime !builtin.target.cpu.arch.isWasm()) return;
    const ms: u32 = @intFromFloat(@max(0.0, duration * 1000.0));
    dom.js_gamepad_vibrate(gamepad, left_motor, right_motor, ms);
}
```

**Reference.** `rcore_*.c` (search `SetGamepadVibration`); Web
Gamepad Haptics API (MDN).

**Inline test.** Host-side: doesn't trap when called.  
**Example.** None — extends the gamepad demo logic when added.  
**Cheatsheet.** No change.  
**Changelog.** `Step 4: setGamepadVibration (Gamepad Haptics)`.  
**Verify.** test +1 (598); smoke 60 of 60.  
**Snapshot.** No.

## Step 5 · `z.models.updateMeshBuffer`

**Goal.** Re-upload partial vertex data — `gl.bufferSubData`
(already bound).

**Touches.**
- `src/drawing.zig` `models` namespace — add near `uploadMesh`
  (line ~8521).
- `examples/dynamic_mesh.zig` (new, ~120 LOC).
- `build.zig` — append `"dynamic_mesh"`.

**Body.**
```zig
pub fn updateMeshBuffer(
    mesh: Mesh,
    buffer_index: usize,
    data: []const u8,
    offset: usize,
) void {
    if (mesh.vboId == null) return;
    if (buffer_index >= MAX_MESH_VERTEX_BUFFERS) return;
    const vbo_id = mesh.vboId[buffer_index];
    if (vbo_id == 0) return;
    rl.rlUpdateVertexBuffer(vbo_id, data, offset);
}
```
(Need to check whether `rlUpdateVertexBuffer` exists in zimr;
if not, inline the `gl.bindBuffer + gl.bufferSubData` pair.)

**Reference.** `rmodels.c::UpdateMeshBuffer`.

**Inline test.** Skipped (needs GPU); covered by smoke + example.

**Example.** `dynamic_mesh.zig` — single quad whose vertex
positions oscillate per frame.  Mirror patterns in
`models/models_mesh_generation.c`.

**Cheatsheet.** "Common idioms" gets a "Dynamic mesh" subsection.  
**Changelog.** `Step 5: updateMeshBuffer + dynamic mesh example.
Phase 1 complete; coverage ~80 %`.  
**Verify.** test +1 (599); smoke 62 of 62.  
**Snapshot.** `step-05-phase1-done`.

---

# Phase 2 — Browser bridges (steps 6-10)

Window/clipboard/screenshot/url functions.  Architecture: each
needs (a) JS handler in `src/web/zimr.ts`, (b) `extern "dom"` decl
in `src/web.zig`, (c) Zig wrapper in `runtime.zig`'s `core`
namespace, (d) smoke-test mock in `webtests/smoke.ts`.

Steps 6-7 do all the JS-side and binding work in one batch (it's
purely additive plumbing).  Steps 8-10 wire the Zig wrappers and
the demo example.

## Step 6 · JS bridge layer additions

**Goal.** Add the JS handlers for fullscreen / clipboard /
screenshot / url / DPI to `src/web/zimr.ts`.

**Touches.** `src/web/zimr.ts` only.

**Adds (to the `dom` import object, near line ~440):**
```ts
js_toggle_fullscreen: () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else canvas.requestFullscreen();
},
js_is_fullscreen: () => document.fullscreenElement ? 1 : 0,
js_open_url: (ptr, len) => {
    const url = readString(ptr, len);
    window.open(url, '_blank', 'noopener,noreferrer');
},
js_get_dpi_scale: () => window.devicePixelRatio || 1,
js_set_clipboard_text: (ptr, len) => {
    navigator.clipboard.writeText(readString(ptr, len)).catch(() => {});
},
// Async variants reuse the fetch-handle protocol.
js_get_clipboard_text_start: () => { /* spawn promise; record handle */ },
js_get_clipboard_text_poll:  (h) => { /* status: 0=pending, 1=ready, 2=fail */ },
js_get_clipboard_text_data_ptr: (h) => { /* ... */ },
js_get_clipboard_text_data_len: (h) => { /* ... */ },
js_get_clipboard_text_release:  (h) => { /* ... */ },
js_get_clipboard_image_start: () => { /* navigator.clipboard.read() */ },
js_get_clipboard_image_poll:  (h) => { /* ... */ },
js_get_clipboard_image_data_ptr: (h) => { /* ... */ },
js_get_clipboard_image_data_len: (h) => { /* ... */ },
js_get_clipboard_image_release:  (h) => { /* ... */ },
js_take_screenshot: (ptr, len) => {
    const filename = readString(ptr, len);
    canvas.toBlob((blob) => {
        if (!blob) return;
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = filename; a.click();
        setTimeout(() => URL.revokeObjectURL(url), 0);
    });
},
```

**Reference.** `src/web/zimr.ts` `js_fetch_*` family (lines
~720-800) for the async-handle protocol pattern.

**Tests.** None (TS, not Zig).  **Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 6: JS bridges for fullscreen/clipboard/url/screenshot`.  
**Verify.** TS still parses; `bun build` still works (run
`zig build smoke-test` — it triggers TS bundling).  
**Snapshot.** No.

## Step 7 · `web.zig` externs + smoke.ts mocks

**Goal.** Declare the new `extern "dom" fn js_*` decls and add
no-op mocks in smoke.

**Touches.**
- `src/web.zig` `dom` namespace — ~15 new extern decls + thin
  pub wrappers.
- `webtests/smoke.ts` `dom` object (line ~167) — mocks for each.

**`web.zig` adds** (one example; rest follow same pattern):
```zig
extern "dom" fn js_toggle_fullscreen() void;
extern "dom" fn js_is_fullscreen() u32;
pub fn toggle_fullscreen() void { js_toggle_fullscreen(); }
pub fn is_fullscreen() bool { return js_is_fullscreen() != 0; }
```

**Smoke mocks** (one example):
```ts
js_toggle_fullscreen: () => {},
js_is_fullscreen: () => 0,
```
For async clipboard/image, mock returns instantly with status=2
(failed) so consumers' error path runs in smoke.

**Tests.** None.  **Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 7: web.zig externs + smoke mocks for browser bridges`.  
**Verify.** Build passes; smoke 60 of 60 (no behavioural change yet).  
**Snapshot.** No.

## Step 8 · `core.{setWindowTitle,getWindowScaleDPI,toggleFullscreen,isFullscreen}`

**Goal.** First batch of `core` window fns.

**Touches.** `src/runtime.zig` `pub const core` namespace, near
`setTraceLogLevel` (line ~267).

**Body.**
```zig
pub fn setWindowTitle(title: []const u8) void {
    if (comptime !builtin.target.cpu.arch.isWasm()) return;
    dom.set_title(title);
}

pub fn getWindowScaleDPI() Vector2 {
    if (comptime !builtin.target.cpu.arch.isWasm()) {
        return .{ .x = 1, .y = 1 };
    }
    const dpr: f32 = dom.js_get_dpi_scale();
    return .{ .x = dpr, .y = dpr };
}

pub fn toggleFullscreen() void {
    if (comptime !builtin.target.cpu.arch.isWasm()) return;
    dom.toggle_fullscreen();
}

pub fn isFullscreen() bool {
    if (comptime !builtin.target.cpu.arch.isWasm()) return false;
    return dom.is_fullscreen();
}
```

**Reference.** `rcore.c::SetWindowTitle`/`GetWindowScaleDPI`/
`ToggleFullscreen`/`IsWindowFullscreen`.

**Inline tests.** Host stubs return identity values; verify them.  
**Example.** None yet (Step 10 ships `window_demo.zig` covering all
9 Phase-2 fns at once).  
**Cheatsheet.** "raylib coverage" % bumps.  
**Changelog.** `Step 8: setWindowTitle/getWindowScaleDPI/toggleFullscreen/isFullscreen`.  
**Verify.** test +4 (603); smoke 62 of 62.  
**Snapshot.** No.

## Step 9 · `core.{openURL,setClipboardText,getClipboardText}`

**Goal.** URL + clipboard text round-trip.

**Touches.** `src/runtime.zig` `core` namespace.

**Body.**
```zig
pub fn openURL(url: []const u8) void {
    if (comptime !builtin.target.cpu.arch.isWasm()) return;
    dom.js_open_url(url.ptr, url.len);
}

pub fn setClipboardText(text: []const u8) void {
    if (comptime !builtin.target.cpu.arch.isWasm()) return;
    dom.js_set_clipboard_text(text.ptr, text.len);
}

/// Async fetch from clipboard.  Caller holds the returned handle
/// across frames and polls.  Returns 0 if the API isn't available.
pub const ClipboardTextHandle = u32;

pub fn getClipboardTextAsync() ClipboardTextHandle {
    if (comptime !builtin.target.cpu.arch.isWasm()) return 0;
    return dom.js_get_clipboard_text_start();
}

pub const ClipboardPollResult = union(enum) {
    pending: void,
    ready: []const u8,
    failed: void,
};

pub fn pollClipboardText(handle: ClipboardTextHandle) ClipboardPollResult { ... }
pub fn releaseClipboardText(handle: ClipboardTextHandle) void { ... }
```

The async surface mirrors `f.loader`'s shape exactly so users
have one mental model.

**Reference.** `examples/core/core_clipboard_text.c`.

**Inline tests.** Host: round-trip via the host stub (which
records the last set text and returns it for get).  
**Example.** None yet.  
**Cheatsheet.** "Modules at a glance" → core gets clipboard mention.  
**Changelog.** `Step 9: openURL + clipboard text I/O`.  
**Verify.** test +3 (606).  
**Snapshot.** No.

## Step 10 · `core.{getClipboardImage,takeScreenshot}` + `window_demo.zig`

**Goal.** Image clipboard read + screenshot trigger; first Phase-2
example consolidating all 9 new fns.

**Touches.**
- `src/runtime.zig` `core` namespace — `getClipboardImageAsync`
  (returns handle), `pollClipboardImage` (returns `?Image` via
  `LoadError!union`), `takeScreenshot(filename: []const u8)`.
- `examples/window_demo.zig` (new, ~150 LOC).
- `build.zig` — append `"window_demo"`.

**Body sketch** (image variant uses zigimg internally):
```zig
pub const ClipboardImageHandle = u32;

pub fn getClipboardImageAsync() ClipboardImageHandle { ... }

pub fn pollClipboardImage(
    gpa: std.mem.Allocator,
    handle: ClipboardImageHandle,
) types.LoadError!union(enum) { pending, ready: Image, failed } {
    // Mirrors clipboard text but routes the bytes through
    // png.decode (zigimg) before returning.
}

pub fn takeScreenshot(filename: []const u8) void { ... }
```

**Reference.** `examples/textures/textures_clipboard_image.c`,
`rcore.c::TakeScreenshot`.

**Example demo.** `window_demo.zig` — title shows current frame
counter (calls `setWindowTitle`); F1 toggles fullscreen; F2 opens
the zimr docs URL; F3 copies a string to clipboard; F4 pastes
from clipboard and displays; F5 saves a screenshot.  HUD displays
DPI from `getWindowScaleDPI`.

**Inline tests.** Host: `takeScreenshot` no-ops; clipboard image
host stub returns `error.NotImplemented`.  
**Cheatsheet.** "Common idioms" → add a "Window controls" section.  
**Changelog.** `Step 10: clipboard image + takeScreenshot + window_demo
example.  Phase 2 complete; coverage ~82 %`.  
**Verify.** test +3 (609); smoke 63 of 63.  
**Snapshot.** `step-10-phase2-done`.

---

# Phase 3 — Render stack (steps 11-22)

GL bindings, `BeginTextureMode`/`EndTextureMode`, image readback,
`imageFormat` (the big switch), `imageText`, MRT.  Architecture
note: rlgl helpers (`rlColorMask` etc.) are thin one-line
wrappers; the meat is `imageFormat` (~250 LOC) and `imageText`
(~100 LOC).

## Step 11 · GL JS bindings: `glReadPixels`/`glColorMask`/`glDrawBuffers`

**Goal.** Add the three missing WebGL2 functions used by Phase 3.

**Touches.**
- `src/web/zimr.ts` — three handlers in `webgl` import object.
- `src/web.zig` — three `extern "webgl"` decls + thin pub
  wrappers in the `gl` namespace.
- `webtests/smoke.ts` — three mocks.

**JS handlers** (zimr.ts):
```ts
glReadPixels: (x, y, w, h, format, type, ptr, _len) => {
    const view = new Uint8Array(memory.buffer, ptr);
    gl.readPixels(x, y, w, h, format, type, view);
},
glColorMask: (r, g, b, a) => gl.colorMask(!!r, !!g, !!b, !!a),
glDrawBuffers: (count, ptr) => {
    const arr = new Int32Array(memory.buffer, ptr, count);
    gl.drawBuffers(Array.from(arr));
},
```

**Smoke mocks** (smoke.ts):
```ts
glReadPixels: (_x, _y, _w, _h, _f, _t, ptr, len) => {
    // Fill with deterministic pattern so consumer tests see something.
    const v = new Uint8Array(memory!.buffer, ptr, len);
    for (let i = 0; i < len; i++) v[i] = (0x80 + i) & 0xFF;
},
glColorMask: () => fakeGL.colorMask(),
glDrawBuffers: () => fakeGL.drawBuffers(),
```

**Tests.** None.  **Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 11: glReadPixels/glColorMask/glDrawBuffers bindings`.  
**Verify.** smoke 63 of 63 (no consumer yet).  
**Snapshot.** `step-11-glreadpixels`.

## Step 12 · `rlgl.{rlColorMask,rlActiveDrawBuffers,rlGetActiveFramebuffer,rlSetUniformMatrices}`

**Goal.** Four thin rlgl wrappers.

**Touches.** `src/rlgl.zig` only — find the rl* sections via
`grep -n "^pub fn rl" src/rlgl.zig | head`; insert these next to
related fns.

**Bodies.**
```zig
pub fn rlColorMask(r: bool, g: bool, b: bool, a: bool) void {
    gl.colorMask(@intFromBool(r), @intFromBool(g), @intFromBool(b), @intFromBool(a));
}

pub fn rlActiveDrawBuffers(count: c_int) void {
    if (count <= 0 or count > 8) return;
    var attachments: [8]c_int = @splat(0);
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        attachments[i] = gl.COLOR_ATTACHMENT0 + @as(c_int, @intCast(i));
    }
    gl.drawBuffers(count, &attachments);
}

pub fn rlGetActiveFramebuffer() c_uint {
    return @intCast(gl.getParameter(gl.FRAMEBUFFER_BINDING));
}

pub fn rlSetUniformMatrices(loc: c_int, mats: []const Matrix) void {
    if (mats.len == 0) return;
    gl.uniformMatrix4fv(loc, @intCast(mats.len), 0, @ptrCast(mats.ptr));
}
```

**Reference.** raylib `rlgl.h::rlColorMask` etc.; `getParameter`
already in `web.zig` — verify via grep, add binding if absent
(should already exist for `FRAMEBUFFER_BINDING` lookups in
existing code).

**Inline tests.** Host-side compile checks (rlgl is no-op stub on
host).  
**Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 12: rlColorMask + rlActiveDrawBuffers + rlGetActiveFramebuffer + rlSetUniformMatrices`.  
**Verify.** test +4 (613); smoke 63 of 63.  
**Snapshot.** No.

## Step 13 · `rlgl.rlCubemapParameters`

**Goal.** Set wrap/filter on a cubemap.

**Touches.** `src/rlgl.zig` near `rlEnableTextureCubemap` (line ~1816).

**Body.**
```zig
pub fn rlCubemapParameters(id: c_uint, param: c_int, value: c_int) void {
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, id);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, @intCast(param), value);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, 0);
}
```

**Reference.** `rlgl.h::rlCubemapParameters`.

**Inline test.** Compile check.  
**Example.** Skybox example (existing) gets a one-line addition
demonstrating `rlCubemapParameters(cubemap.id, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)`.  
**Cheatsheet.** No change.  
**Changelog.** `Step 13: rlCubemapParameters`.  
**Verify.** test +1 (614); smoke 63 of 63.  
**Snapshot.** No.

## Step 14 · `rlgl.rlResizeFramebuffer`

**Goal.** Resize an existing FBO's color + depth attachments.

**Touches.** `src/rlgl.zig`.

**Body.**
```zig
pub fn rlResizeFramebuffer(
    target_id: c_uint,
    width: c_int,
    height: c_int,
) void {
    // Walk the attachment list; for each color/depth/stencil, reallocate
    // its backing texture or renderbuffer at the new size, re-attach.
    // Internal helper since raylib's rlgl tracks framebuffers as opaque
    // objects.  We need to track them ourselves — see existing
    // `rlLoadFramebuffer` to find where attachment metadata lives.
    // ~50 LOC; consult rlgl.h::rlResizeFramebuffer for shape.
    ...
}
```

**Reference.** `rlgl.h::rlResizeFramebuffer` (~80 LOC of attachment
walking).

**Inline test.** Compile check.  
**Example.** `rtt.zig` will be refactored at Step 16 to optionally
demonstrate this on canvas resize.  
**Cheatsheet.** No change.  
**Changelog.** `Step 14: rlResizeFramebuffer`.  
**Verify.** test +1 (615); smoke 63 of 63.  
**Snapshot.** No.

## Step 15 · `textures.{beginTextureMode,endTextureMode}`

**Goal.** Wrap the manual sequence in `examples/rtt.zig` (line
references in that file's `update`).

**Touches.** `src/drawing.zig` `textures` namespace (or possibly
`runtime.zig` `core` since raylib puts these in core; choose
based on where the RTT-related fns cluster naturally —
`drawing.zig` `textures` has `loadRenderTexture` so put the begin/end
there for cohesion).

**Body.**
```zig
pub fn beginTextureMode(target: RenderTexture2D) void {
    rlgl.rlDrawRenderBatchActive(); // flush before scope change
    rlgl.rlEnableFramebuffer(target.id);
    gl.viewport(0, 0, target.texture.width, target.texture.height);
    // Push + reset projection & modelview to fit the RT.
    rlgl.rlMatrixMode(rlgl.RL_PROJECTION);
    rlgl.rlLoadIdentity();
    rlgl.rlOrtho(0, @floatFromInt(target.texture.width), @floatFromInt(target.texture.height), 0, 0, 1);
    rlgl.rlMatrixMode(rlgl.RL_MODELVIEW);
    rlgl.rlLoadIdentity();
}

pub fn endTextureMode() void {
    rlgl.rlDrawRenderBatchActive();
    rlgl.rlDisableFramebuffer();
    // Restore the canvas viewport from core.RLGL state.
    const w = core.getRenderWidth();
    const h = core.getRenderHeight();
    gl.viewport(0, 0, w, h);
    // Restore projection — the matrix stack push pattern is a
    // raylib convention; verify zimr's existing rlgl matrix stack
    // tracks pushed projections.
}
```

**Reference.** `rcore.c::BeginTextureMode/EndTextureMode`.

**Inline test.** Compile check + state round-trip — call begin
then end, verify rlgl matrix mode + viewport return to canvas
defaults.  
**Example.** Step 16 covers refactoring `rtt.zig`.  
**Cheatsheet.** "Common idioms" gets a "Render to texture" subsection.  
**Changelog.** `Step 15: beginTextureMode/endTextureMode`.  
**Verify.** test +2 (617); smoke 63 of 63.  
**Snapshot.** No.

## Step 16 · Refactor `rtt.zig` to use `beginTextureMode`/`endTextureMode`

**Goal.** Rip out the manual `rlEnableFramebuffer` dance in
`examples/rtt.zig` and replace with the new wrappers.  Validates
the wrappers behave correctly under real load.

**Touches.** `examples/rtt.zig`.

**Body.** Replace ~30 LOC of manual setup with:
```zig
z.textures.beginTextureMode(rt);
defer z.textures.endTextureMode();
// existing draw calls unchanged
```

**Reference.** Mirror raylib's `examples/textures/textures_to_image.c`
which uses the wrapper.

**Inline test.** None (example file).  
**Cheatsheet.** Already updated in Step 15.  
**Changelog.** `Step 16: rtt example refactored to begin/endTextureMode`.  
**Verify.** smoke 63 of 63 (rtt still runs).  
**Snapshot.** No.

## Step 17 · `z.textures.loadImageFromTexture`

**Goal.** Read pixels back from a GPU texture into an `Image`.

**Touches.** `src/drawing.zig` `textures` namespace, near
`loadTextureFromImage` (line ~5055).

**Body.**
```zig
pub fn loadImageFromTexture(
    gpa: std.mem.Allocator,
    texture: Texture2D,
) types.LoadError!Image {
    if (comptime !builtin.target.cpu.arch.isWasm()) {
        return types.LoadError.GpuReadbackFailed;
    }
    const w_u: usize = @intCast(texture.width);
    const h_u: usize = @intCast(texture.height);
    const buf = try gpa.alloc(u8, w_u * h_u * 4);
    errdefer gpa.free(buf);

    // Bind texture to a temporary FBO, readPixels, unbind.
    const tmp_fbo = rlgl_gpu.rlLoadFramebuffer();
    defer rlgl_gpu.rlUnloadFramebuffer(tmp_fbo);
    rlgl_gpu.rlEnableFramebuffer(tmp_fbo);
    defer rlgl_gpu.rlDisableFramebuffer();

    rlgl_gpu.rlFramebufferAttach(tmp_fbo, texture.id, RL_ATTACHMENT_COLOR_CHANNEL0, RL_ATTACHMENT_TEXTURE2D, 0);
    if (!rlgl_gpu.rlFramebufferComplete(tmp_fbo)) {
        return types.LoadError.GpuReadbackFailed;
    }
    gl.readPixels(0, 0, texture.width, texture.height, gl.RGBA, gl.UNSIGNED_BYTE, buf.ptr, buf.len);
    return Image{ .data = buf.ptr, .width = texture.width, .height = texture.height, .mipmaps = 1, .format = 7 };
}
```

**Reference.** `rtextures.c::LoadImageFromTexture`.

**Inline test.** Skipped (needs GPU).  
**Example.** Step 22 ships `texture_readback.zig`.  
**Cheatsheet.** Add to texture-loading subsection.  
**Changelog.** `Step 17: loadImageFromTexture (gl.readPixels)`.  
**Verify.** smoke 63 of 63.  
**Snapshot.** `step-17-readback-live`.

## Step 18 · `z.textures.loadImageFromScreen`

**Goal.** Same as 17 but reading the default framebuffer.

**Touches.** `src/drawing.zig` `textures`.

**Body.** Variant of step 17 that skips the FBO bind dance —
reads from binding 0.

**Reference.** `rtextures.c::LoadImageFromScreen`.

**Inline test.** Skipped (needs GPU).  
**Example.** Step 22.  
**Cheatsheet.** Same line as step 17.  
**Changelog.** `Step 18: loadImageFromScreen`.  
**Verify.** smoke 63 of 63.  
**Snapshot.** No.

## Step 19 · `z.textures.imageFormat` (the big switch)

**Goal.** Convert pixel format in-place.

**Touches.** `src/drawing.zig` `textures` namespace, near
`imageCopy`.  ~250 LOC.

**Approach.** Walk every pixel through `getPixelColor` (which
already does the typed-format dispatch from the aggressive
sweep), write via `setPixelColor` into a fresh buffer at the new
format's size, swap.  Strong exception guarantee: image
unchanged on alloc fail.

**Body skeleton.**
```zig
pub fn imageFormat(
    gpa: std.mem.Allocator,
    image: *Image,
    new_format: types.PixelFormat,
) std.mem.Allocator.Error!void {
    const old_format = image.pixelFormat();
    if (old_format == new_format) return;
    if (old_format.isCompressed() or new_format.isCompressed()) return;

    const w_u: usize = @intCast(image.width);
    const h_u: usize = @intCast(image.height);
    const px_count: usize = w_u * h_u;
    const new_byte_size: usize = px_count * new_format.bytesPerPixel();

    const new_data = try gpa.alloc(u8, new_byte_size);
    errdefer gpa.free(new_data);

    // Source pixel → Color (RGBA8) → dest pixel.
    var i: usize = 0;
    while (i < px_count) : (i += 1) {
        const c = getPixelColorAt(image.data.?, i, old_format);
        setPixelColorAt(new_data.ptr, i, c, new_format);
    }

    // Swap.  Caller's allocator owns the old buffer; free it.
    const old_byte_size: usize = px_count * old_format.bytesPerPixel();
    const old_slice = @as([*]u8, @ptrCast(image.data.?))[0..old_byte_size];
    gpa.free(old_slice);

    image.data = new_data.ptr;
    image.format = @intFromEnum(new_format);
}
```

`getPixelColorAt` and `setPixelColorAt` are reusable internal
helpers — verify whether they already exist; if not, factor out
of existing `getPixelColor` / `setPixelColor`.

**Reference.** `rtextures.c::ImageFormat` (~200 LOC switch).

**Inline tests** (5 cases):
- RGBA8 → GRAYSCALE (Luma weights)
- GRAYSCALE → RGBA8 (replicate Y to RGB, A=255)
- RGBA8 → R5G6B5 (round-trip with tolerance)
- RGBA8 → RGBA8 (no-op)
- Compressed → uncompressed (silent no-op, data unchanged)

**Example.** Step 22 ships `image_format.zig`.  
**Cheatsheet.** Add to textures section.  
**Changelog.** `Step 19: imageFormat (typed pixel-format conversion)`.  
**Verify.** test +5 (622); smoke 63 of 63.  
**Snapshot.** `step-19-imagetext-done` is misnamed — rename to
`step-19-imageformat-done` since imageText comes next.

## Step 20 · `z.textures.imageText`

**Goal.** CPU-side text-into-image (default font).

**Touches.** `src/drawing.zig` `textures` namespace, near
`genImageColor`.

**Body.**
```zig
pub fn imageText(
    gpa: std.mem.Allocator,
    text: []const u8,
    font_size: c_int,
    color: Color,
) types.ImageGenError!Image {
    const default_font = text_module.getFontDefault();
    return imageTextEx(gpa, default_font, text, @floatFromInt(font_size), 1.0, color);
}
```

(All work happens in `imageTextEx`; `imageText` is a thin
defaults wrapper.)

**Reference.** `rtextures.c::ImageText`.

**Inline test.** "Renders 'A' produces non-zero pixels".  
**Example.** Step 22 ships `image_text.zig`.  
**Cheatsheet.** No change (covered by step 21).  
**Changelog.** `Step 20: imageText`.  
**Verify.** test +1 (623); smoke 63 of 63.  
**Snapshot.** No.

## Step 21 · `z.textures.imageTextEx`

**Goal.** Full-control variant — explicit font, spacing, tint.

**Touches.** `src/drawing.zig` `textures` namespace.

**Body.** Walk codepoints; for each glyph, look up `font.recs[i]`
in the atlas; blit the glyph's atlas region onto a fresh CPU
image buffer at the right pen position; advance pen by
`glyph.advanceX + spacing`.  Final image sized to the bounding
box.  ~120 LOC.

**Reference.** `rtextures.c::ImageTextEx`.  Also: zimr's
`drawTextEx` in `drawing.zig` line ~6000 has the exact pen-walk
logic — reuse the iteration shape.

**Inline tests** (3):
- "Renders multiline text — newlines advance Y"
- "Custom font — uses provided glyph atlas"
- "Empty string returns 1x1 transparent image"

**Example.** Step 22.  
**Cheatsheet.** "Common idioms" → add a "CPU-side text rendering"
subsection with `imageText` + `imageTextEx` examples.  
**Changelog.** `Step 21: imageTextEx`.  
**Verify.** test +3 (626); smoke 63 of 63.  
**Snapshot.** No.

## Step 22 · Phase-3 examples consolidation

**Goal.** Three new example files exercising Phase 3 paths
end-to-end.

**Touches.**
- `examples/texture_readback.zig` (new) — render shapes to RT,
  read back via `loadImageFromTexture`, display the readback.
- `examples/image_text.zig` (new) — `imageText` panel + `imageTextEx`
  panel, contrast with `drawText` panel.  Mirror
  `examples/textures/textures_image_text.c`.
- `examples/mrt_demo.zig` (new) — render to two color attachments
  using `rlActiveDrawBuffers(2)`, composite in second pass.
  Mirror `examples/shaders/shaders_deferred_rendering.c`
  simplified.
- `build.zig` — append all three to `examples`.

**Reference.** raylib examples noted above.

**Inline tests.** None (example files).  
**Cheatsheet.** Already updated by previous steps.  
**Changelog.** `Step 22: Phase 3 examples (texture_readback, image_text,
mrt_demo).  Phase 3 complete; coverage ~87 %`.  
**Verify.** smoke 66 of 66 (3 new examples).  
**Snapshot.** `step-22-phase3-done`.

---

# Phase 4 — Touch + gestures (steps 23-30)

Architecture: same shape as keyboard/mouse — JS-side event
handlers feed a state struct in `runtime.input.STATE`; getter
fns read from that.  Gestures sit on top of the touch state with
their own state machine.

## Step 23 · JS touch event wiring (zimr.ts + dom.js)

**Goal.** `touchstart`/`touchmove`/`touchend`/`touchcancel`
listeners on the canvas; each pushes events into wasm via
exported `zimr_input_push_touch_*` fns.

**Touches.**
- `src/web/zimr.ts` — listener block (~40 LOC) added near existing
  mouse handlers (line ~570).
- `webtests/smoke.ts` — no real handlers needed since smoke
  doesn't synthesize touches; just ensures the export side exists.

**Sketch.**
```ts
canvas.addEventListener('touchstart', (e) => {
    e.preventDefault();
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    for (const t of e.changedTouches) {
        instance.exports.zimr_input_push_touch_down(
            t.identifier,
            (t.clientX - rect.left) * dpr,
            (t.clientY - rect.top) * dpr,
        );
    }
}, { passive: false });
// ... same shape for touchmove/touchend/touchcancel
```

**Reference.** Existing mouse handler lines 555-575 in zimr.ts.

**Tests.** None (TS).  
**Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 23: JS touch event listeners`.  
**Verify.** TS still bundles; smoke 66 of 66 (no behavioural change).  
**Snapshot.** No.

## Step 24 · Wasm-side touch event sinks

**Goal.** Export `zimr_input_push_touch_{down,move,up}` fns from
zimr.zig that the JS handlers call.

**Touches.** `src/zimr.zig` — add three `pub export fn` near
existing input event handlers.

**Body** (state lives in `runtime.input.STATE`, so wire-through):
```zig
pub export fn zimr_input_push_touch_down(id: u32, x: f32, y: f32) void {
    @import("runtime.zig").input.pushTouchDown(id, x, y);
}
pub export fn zimr_input_push_touch_move(id: u32, x: f32, y: f32) void {
    @import("runtime.zig").input.pushTouchMove(id, x, y);
}
pub export fn zimr_input_push_touch_up(id: u32) void {
    @import("runtime.zig").input.pushTouchUp(id);
}
```

(The actual `pushTouch*` impls land in Step 25 — this step just
declares the export shells so wasm builds keep working when the
JS side calls them.)

**Tests.** None.  
**Example.** None yet.  
**Cheatsheet.** No change.  
**Changelog.** `Step 24: wasm touch event exports`.  
**Verify.** smoke 66 of 66.  
**Snapshot.** No.

## Step 25 · `runtime.input` touch state + getter API

**Goal.** Public touch API mirroring raylib's.

**Touches.** `src/runtime.zig` `pub const input` namespace.

**State additions** (inside `STATE`):
```zig
const TouchPoint = struct {
    id: i32 = -1,         // -1 = inactive slot
    x: f32 = 0,
    y: f32 = 0,
};
pub const MAX_TOUCH_POINTS: usize = 10;

// Inside STATE:
touches: [MAX_TOUCH_POINTS]TouchPoint = @splat(.{}),
touch_count: usize = 0,
```

**Internal sinks:**
```zig
pub fn pushTouchDown(id: u32, x: f32, y: f32) void { ... }
pub fn pushTouchMove(id: u32, x: f32, y: f32) void { ... }
pub fn pushTouchUp(id: u32) void { ... }
```

**Public API:**
```zig
pub fn getTouchX() c_int { return @intFromFloat(STATE.touches[0].x); }
pub fn getTouchY() c_int { return @intFromFloat(STATE.touches[0].y); }
pub fn getTouchPosition(index: c_int) Vector2 { ... }
pub fn getTouchPointId(index: c_int) c_int { ... }
pub fn getTouchPointCount() c_int { return @intCast(STATE.touch_count); }
```

**Reference.** raylib `rcore.c::GetTouchX/Y/Position/PointId/PointCount`.

**Inline tests** (5):
- Push down 3 fingers; `getTouchPointCount` returns 3
- Move finger 0 to (100, 50); `getTouchX/Y` reflects
- Up finger 1; count drops to 2; remaining slots compact
- Out-of-range index returns zero values
- Reset state between tests

**Example.** Step 28 ships `touch_paint.zig`.  
**Cheatsheet.** Modules table → `z.input` row gets touch mention.  
**Changelog.** `Step 25: touch primitives (5 fns) + state`.  
**Verify.** test +5 (631); smoke 66 of 66.  
**Snapshot.** `step-25-touch-input`.

## Step 26 · `runtime.gestures` state machine

**Goal.** Internal gesture detector consumes touch events,
classifies into raylib's gesture enum.

**Touches.** `src/runtime.zig` — new `pub const gestures = struct
{...}` namespace, added between `input` and `camera`.

**Approach.** Port raylib's `rgestures.h` state machine directly
(it's a self-contained ~500 LOC).  The detector watches for:
- **Tap**: down + up within 300ms, no significant movement
- **Doubletap**: two taps within 350ms
- **Hold**: down maintained > 500ms without movement
- **Drag**: move while down, with minimum velocity
- **Swipe-{left,right,up,down}**: drag terminating with high
  velocity in axis direction
- **Pinch-{in,out}**: two-finger relative-distance change
- **Rotate-{left,right}**: two-finger angular velocity

State is a `pub const STATE = struct { ... }` keeping last touch
positions, timestamps, and a current `Gesture` enum value.

**Reference.** `rgestures.h` (raylib master, single header).

**Inline tests** (8): one synthetic touch sequence per gesture
type.  Use `runtime.input.pushTouch*` to feed events; verify
detector emits the right enum.

**Example.** Step 29.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 26: gesture state machine`.  
**Verify.** test +8 (639); smoke 66 of 66.  
**Snapshot.** No.

## Step 27 · `gestures` public API

**Goal.** Expose the detector state via raylib-compatible getters.

**Touches.** `src/runtime.zig` `gestures` namespace.

**API:**
```zig
pub const Gesture = enum(c_int) {
    none = 0, tap = 1, doubletap = 2, hold = 4, drag = 8,
    swipe_right = 16, swipe_left = 32, swipe_up = 64, swipe_down = 128,
    pinch_in = 256, pinch_out = 512,
};

pub fn isGestureDetected(gesture: Gesture) bool { ... }
pub fn getGestureDetected() Gesture { ... }
pub fn getGestureHoldDuration() f32 { ... }
pub fn getGestureDragVector() Vector2 { ... }
pub fn getGestureDragAngle() f32 { ... }
pub fn getGesturePinchVector() Vector2 { ... }
pub fn getGesturePinchAngle() f32 { ... }
pub fn setGesturesEnabled(flags: c_uint) void { ... }
```

**Reference.** `rgestures.h` public API + raylib's `Gesture` enum.

**Inline tests** (5): for each major gesture type, verify the
corresponding getter returns sensible values after a synthetic
sequence.

**Example.** Step 29.  
**Cheatsheet.** Modules table → add `z.gestures` row.  
**Changelog.** `Step 27: gestures public API (8 fns)`.  
**Verify.** test +5 (644); smoke 66 of 66.  
**Snapshot.** No.

## Step 28 · `touch_paint.zig` example

**Goal.** First touch-aware example.  Each touch leaves a colored
trail circle; touch ID maps to a color.

**Touches.**
- `examples/touch_paint.zig` (new, ~100 LOC).
- `build.zig` — append `"touch_paint"`.

**Reference.** No raylib direct equivalent in `core/`, but
`gestures` examples have similar shape.

**Tests.** None (example).  
**Cheatsheet.** No change.  
**Changelog.** `Step 28: touch_paint example`.  
**Verify.** smoke 67 of 67.  
**Snapshot.** No.

## Step 29 · `gestures_demo.zig` example

**Goal.** Recreate raylib's `core_input_gestures.c`.

**Touches.**
- `examples/gestures_demo.zig` (new, ~150 LOC).
- `build.zig` — append `"gestures_demo"`.

**Behaviour.** Display the most-recent gesture name + relevant
data (pinch distance, swipe direction, drag angle).  Touch-only;
graceful no-op on desktop.

**Reference.** `examples/core/core_input_gestures.c`.

**Tests.** None.  
**Cheatsheet.** No change.  
**Changelog.** `Step 29: gestures demo example`.  
**Verify.** smoke 68 of 68.  
**Snapshot.** No.

## Step 30 · `gestures_testbed.zig` example

**Goal.** Live-visualise the state machine.  Shows current touch
points as numbered circles, state transitions as overlay text.

**Touches.**
- `examples/gestures_testbed.zig` (new, ~200 LOC).
- `build.zig` — append `"gestures_testbed"`.

**Reference.** `examples/core/core_input_gestures_testbed.c`.

**Tests.** None.  
**Cheatsheet.** "Common idioms" → add "Touch + gestures" section.  
**Changelog.** `Step 30: gestures testbed example.  Phase 4
complete; coverage ~89 %`.  
**Verify.** smoke 69 of 69.  
**Snapshot.** `step-30-phase4-done`.

---

# Phase 5 — glTF loading (steps 31-38)

Custom Zig parser, written zimr-style, inspired by zgltf
(`https://github.com/kooparse/zgltf`).  Lives as `pub const gltf
= struct` inside `codecs.zig` (alongside `png` and `truetype`).
Estimated size: ~800-1000 LOC trimmed from zgltf's ~2400 (we
only need static-mesh + skin + animation; skip cameras, lights,
sparse accessors, KHR extensions other than what samples use).

**Architecture choice.** zgltf uses arena allocation; we'll
match — each `loadGltf` call returns a `gltf.Data` whose backing
arena is owned by the caller.  Free with one `gpa.free` /
`arena.deinit`.  This is the same pattern zimr's `Loader` uses
for fetched bytes.

## Step 31 · `codecs.gltf` types + JSON parser scaffold

**Goal.** Type definitions (Asset, Scene, Node, Mesh, Primitive,
Accessor, BufferView, Buffer, Material, Texture, Image, Skin,
Animation) inside `codecs.zig`.  JSON parsing entry point that
walks the `glTF` object and fills the types.

**Touches.** `src/codecs.zig` — new `pub const gltf = struct {
... }` namespace at end of file (line ~3640).

**Approach.** Direct port of zgltf's `types.zig` (684 LOC) but:
- Use zimr's `[]const u8` slices, not `?std.json.ObjectMap` blobs
  for unparsed extras (we just drop extras entirely)
- Use `std.json.parseFromSlice` with a typed schema rather than
  walking `Value` objects (Zig 0.16 supports this; zgltf
  pre-dates that capability)
- One-arg-per-line per style rule 1
- Consistent `?Index = null` for optional indices (where Index
  is `usize`)

**Sketch:**
```zig
pub const gltf = struct {
    pub const Index = usize;
    pub const Asset = struct {
        version: []const u8 = "Undefined",
        generator: ?[]const u8 = null,
        copyright: ?[]const u8 = null,
    };
    pub const Node = struct {
        name: ?[]const u8 = null,
        parent: ?Index = null,
        mesh: ?Index = null,
        skin: ?Index = null,
        children: []Index = &.{},
        matrix: ?[16]f32 = null,
        translation: [3]f32 = .{ 0, 0, 0 },
        rotation: [4]f32 = .{ 0, 0, 0, 1 },
        scale: [3]f32 = .{ 1, 1, 1 },
    };
    // ... more types
    pub const Data = struct {
        asset: Asset,
        scenes: []Scene = &.{},
        nodes: []Node = &.{},
        meshes: []Mesh = &.{},
        materials: []Material = &.{},
        // ...
        arena: *std.heap.ArenaAllocator,
        glb_binary: ?[]align(4) const u8 = null,
    };
    pub const ParseError = error{ InvalidGltf, UnsupportedVersion } || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

    pub fn parse(gpa: std.mem.Allocator, bytes: []align(4) const u8) ParseError!Data { ... }
    pub fn deinit(data: *Data) void { data.arena.deinit(); data.arena.child_allocator.destroy(data.arena); }
};
```

**Reference.** zgltf `src/Gltf.zig:62-77` (Data struct) and
`src/types.zig` (full).  zgltf is permissively licensed (MIT) —
record attribution in `THIRD_PARTY_LICENSES.md` even though we
don't vendor verbatim, since the structure follows it closely.

**Inline tests** (3):
- "Parses minimal `{"asset":{"version":"2.0"}}` payload"
- "Parses one-mesh-one-node scene"
- "Returns InvalidGltf on malformed JSON"

**Example.** Step 35.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 31: glTF types + JSON parser scaffold (~600 LOC)`.  
**Verify.** test +3 (647); smoke 69 of 69.  
**Snapshot.** `step-31-gltf-types`.

## Step 32 · `gltf` GLB binary container parser

**Goal.** Detect and parse `.glb` (binary glTF wrapper):
12-byte header + JSON chunk + BIN chunk.

**Touches.** `src/codecs.zig` `gltf` namespace.

**Body.** Mirrors zgltf's `parseGlb` (zgltf `Gltf.zig:271-348`)
but in zimr style.  Detection: first 4 bytes = `0x46546C67`
(`'glTF'`).  Versions: only v2 supported.  Layout:

```
u32 magic (0x46546C67)
u32 version (must be 2)
u32 total_length
[chunks]
  u32 chunkLength
  u32 chunkType (0x4E4F534A 'JSON' or 0x004E4942 'BIN')
  u8[chunkLength] chunkData
```

**Body sketch:**
```zig
pub fn parse(gpa: std.mem.Allocator, bytes: []align(4) const u8) ParseError!Data {
    if (isGlb(bytes)) return parseGlb(gpa, bytes);
    return parseJson(gpa, bytes);
}

fn isGlb(b: []align(4) const u8) bool {
    if (b.len < 4) return false;
    const fields: [*]const u32 = @ptrCast(b.ptr);
    return fields[0] == 0x46546C67;
}

fn parseGlb(gpa: std.mem.Allocator, b: []align(4) const u8) ParseError!Data {
    // header → version check → JSON chunk → BIN chunk → call parseJson
    // → attach BIN to Data.glb_binary so accessors can read.
    ...
}
```

**Reference.** zgltf `parseGlb`.

**Inline tests** (2):
- "Detects glb magic"
- "Splits header / JSON / BIN; rejects non-2.0 version"

**Example.** Step 35.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 32: glb binary container parser`.  
**Verify.** test +2 (649); smoke 69 of 69.  
**Snapshot.** No.

## Step 33 · Accessor reader (typed)

**Goal.** Given an `Accessor` and a binary buffer, return a typed
slice of the underlying data.

**Touches.** `src/codecs.zig` `gltf` namespace.

**Body.**
```zig
pub fn readAccessor(
    comptime T: type,
    data: *const Data,
    accessor: Accessor,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error![]T {
    // Reads through buffer_view → buffer; handles stride; uses
    // glb_binary if present, else expects external buffer fetched
    // separately (out of scope for now — only glb-with-bin
    // supported in v2 plan).
    ...
}
```

`T` must match the accessor's `component_type × type` — the fn
panics on mismatch (zgltf does the same; arguably should be an
error, but matches the inspiration source's contract).

**Reference.** zgltf `Gltf.zig:184-225` (`getDataFromBufferView`).

**Inline tests** (3):
- Read a `[3]f32` (vec3) accessor
- Read a `u16` (scalar index) accessor
- Strided buffer view

**Example.** Step 35.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 33: typed accessor reader`.  
**Verify.** test +3 (652); smoke 69 of 69.  
**Snapshot.** No.

## Step 34 · `gltf` → `Mesh` array conversion

**Goal.** Build zimr `Mesh` objects from a parsed `gltf.Data`,
including upload to GPU.

**Touches.** `src/drawing.zig` `models` namespace — new internal
helper `meshesFromGltf(gpa, gltf_data)` (not exported; called by
`loadModelFromMemory` in step 35).

**Body sketch.**
```zig
fn meshesFromGltf(
    gpa: std.mem.Allocator,
    g: *const codecs.gltf.Data,
) std.mem.Allocator.Error![]Mesh {
    // Walk g.meshes; for each, walk primitives; for each, extract
    // POSITION (vec3 f32), NORMAL (vec3 f32), TEXCOORD_0 (vec2 f32),
    // INDICES (u16 or u32), JOINTS_0 (u8 vec4), WEIGHTS_0 (f32 vec4).
    // Allocate flat zimr Mesh arrays, copy into them, call uploadMesh.
    ...
}
```

**Reference.** raylib `rmodels.c::LoadGLTF` (~600 LOC there;
ours much shorter because we're not handling the cgltf-specific
error model and we're not parsing — just translating an
already-parsed structure).

**Inline tests** (2):
- "Converts a single-primitive triangle glTF to a 3-vertex Mesh"
- "Maps JOINTS_0/WEIGHTS_0 into mesh.boneIndices/boneWeights"

**Example.** Step 35.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 34: glTF → Mesh array converter`.  
**Verify.** test +2 (654); smoke 69 of 69.  
**Snapshot.** No.

## Step 35 · `z.models.loadModelFromMemory` orchestrator + `gltf_simple.zig`

**Goal.** End-to-end: bytes in → `Model` out.  First glTF
example.

**Touches.**
- `src/drawing.zig` `models` namespace — new public fn.
- `examples/gltf_simple.zig` (new, ~100 LOC).
- `assets/cube.glb` (new asset, ~1-2 KB) OR generate synthetic glTF
  in the example via a `[]const u8` literal.
- `build.zig` — append `"gltf_simple"`; add asset import if used.

**Body.**
```zig
pub const ModelFormat = enum { gltf, glb };

pub fn loadModelFromMemory(
    gpa: std.mem.Allocator,
    bytes: []align(4) const u8,
) types.LoadError!Model {
    var gltf_data = codecs.gltf.parse(gpa, bytes) catch return types.LoadError.GltfParseFailed;
    defer codecs.gltf.deinit(&gltf_data);

    const meshes = try meshesFromGltf(gpa, &gltf_data);
    errdefer gpa.free(meshes);
    const materials = try materialsFromGltf(gpa, &gltf_data);
    errdefer gpa.free(materials);

    return Model{
        .meshes = meshes.ptr,
        .meshCount = @intCast(meshes.len),
        .materials = materials.ptr,
        .materialCount = @intCast(materials.len),
        // ... mesh→material mapping, transform = identity
    };
}
```

**Reference.** raylib `rmodels.c::LoadGLTF` for the orchestration
shape; example: `examples/models/models_loading_gltf.c`.

**Inline tests.** Skipped (needs GPU); covered by smoke +
example.

**Example.** `gltf_simple.zig` — load embedded cube.glb, render
spinning.  

**Cheatsheet.** "Common idioms" → "Loading a glTF model" subsection.  
**Changelog.** `Step 35: loadModelFromMemory + gltf_simple example`.  
**Verify.** smoke 70 of 70.  
**Snapshot.** `step-35-gltf-load-live`.

## Step 36 · `gltf` → `Material` array (with embedded image decode)

**Goal.** Wire glTF PBR materials (`baseColorTexture`,
`metallicRoughnessTexture`) into zimr `Material` structs,
decoding embedded image bytes via existing `png.decode`.

**Touches.** `src/drawing.zig` `models` (was step 34's
`materialsFromGltf` stub; this step completes it).

**Body sketch.**
```zig
fn materialsFromGltf(
    gpa: std.mem.Allocator,
    g: *const codecs.gltf.Data,
) std.mem.Allocator.Error![]Material {
    // For each gltf.Material:
    // - Allocate maps array (12 slots, default-zeroed).
    // - For pbrMetallicRoughness.baseColorTexture: get image, decode
    //   if PNG, upload via rlLoadTexture, install in MATERIAL_MAP_DIFFUSE.
    // - Same for metallicRoughnessTexture (slot METALNESS).
    ...
}
```

**Reference.** `rmodels.c::LoadGLTF` material-loading section.

**Inline tests** (2):
- Default material (no PBR data) gets sensible defaults
- glTF with embedded PNG baseColor produces texture-bound
  Material

**Example.** Step 38.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 36: glTF Material wiring (with embedded PNG decode)`.  
**Verify.** test +2 (656); smoke 70 of 70.  
**Snapshot.** No.

## Step 37 · `gltf` → `ModelAnimation` array (extract keyframe poses)

**Goal.** Convert glTF animation channels to raylib's
`ModelAnimation` shape — required input for Phase 6.

**Touches.** `src/drawing.zig` `models` — new internal helper
`animationsFromGltf`; new public `loadModelAnimations` that calls it.

**Body sketch.**
```zig
fn animationsFromGltf(
    gpa: std.mem.Allocator,
    g: *const codecs.gltf.Data,
) std.mem.Allocator.Error![]ModelAnimation {
    // For each gltf.Animation:
    // - Determine bone count (from skin or by counting unique target nodes).
    // - Determine keyframe times (input accessor of channel 0; assume
    //   all channels share the same timeline — common in exporters).
    // - Allocate ModelAnimation.keyframePoses[k] = Transform[boneCount].
    // - For each channel (translation/rotation/scale → target bone):
    //     Read input (times) and output (values) accessors.
    //     Sample at every keyframe time, write into the right
    //     bone's Transform slot.
    ...
}

pub fn loadModelAnimations(
    gpa: std.mem.Allocator,
    bytes: []align(4) const u8,
) types.LoadError![]ModelAnimation { ... }
```

**Reference.** raylib `rmodels.c::LoadModelAnimationsGLTF`
(~250 LOC).

**Inline tests** (2):
- One-bone walk-cycle synthetic glb produces N keyframes
- Animations without timeline alignment fall back gracefully

**Example.** Step 38 + 42.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 37: glTF animation extraction`.  
**Verify.** test +2 (658); smoke 70 of 70.  
**Snapshot.** No.

## Step 38 · `gltf_textured.zig` example + Phase 5 wrap

**Goal.** Demonstrate textured glTF (validates Step 36 path).

**Touches.**
- `examples/gltf_textured.zig` (new, ~120 LOC).
- `assets/textured_cube.glb` (new, ~10-20 KB; CC0 model).
- `build.zig` — append `"gltf_textured"`.

**Reference.** `examples/models/models_loading_gltf.c` exactly.

**Tests.** None (example).  
**Cheatsheet.** Add "Loading a textured glTF" idiom.  
**Changelog.** `Step 38: gltf_textured example.  Phase 5
complete; coverage ~91 %`.  
**Verify.** smoke 71 of 71.  
**Snapshot.** `step-38-phase5-done`.

---

# Phase 6 — Skinned-mesh animation (steps 39-43)

## Step 39 · Skinning vertex shader + branch

**Goal.** Add a skinning variant of `DEFAULT_VERTEX_SHADER` and
the logic to use it when a mesh has bone data.

**Touches.** `src/rlgl.zig` near line 1135.

**New constant** (after `DEFAULT_VERTEX_SHADER`):
```zig
const DEFAULT_VERTEX_SHADER_SKINNED =
    \\#version 300 es
    \\precision mediump float;
    \\in vec3 vertex_position;
    \\in vec2 vertex_tex_coord;
    \\in vec4 vertex_color;
    \\in vec4 vertexBoneIds;       // location 6
    \\in vec4 vertex_bone_weights;   // location 7
    \\out vec2 fragTexCoord;
    \\out vec4 fragColor;
    \\uniform mat4 mvp;
    \\uniform mat4 boneMatrices[128];
    \\void main() {
    \\    mat4 skin = vertex_bone_weights.x * boneMatrices[int(vertexBoneIds.x)] +
    \\                vertex_bone_weights.y * boneMatrices[int(vertexBoneIds.y)] +
    \\                vertex_bone_weights.z * boneMatrices[int(vertexBoneIds.z)] +
    \\                vertex_bone_weights.w * boneMatrices[int(vertexBoneIds.w)];
    \\    fragTexCoord = vertex_tex_coord;
    \\    fragColor = vertex_color;
    \\    gl_Position = mvp * skin * vec4(vertex_position, 1.0);
    \\}
;
```

**Branch.** `loadDefaultShader` already builds the default
shader once.  Extend to build a second program with the skinned
VS; expose via `getDefaultSkinnedShaderId()`.  The mesh-draw
path picks based on `mesh.boneIndices != null`.

**Reference.** raylib `rmodels.c` skinning shader (search for
`vsBoneMatricesShader`); also
`examples/models/models_animation_gpu_skinning.c`.

**Inline tests.** Compile check (host stub).  
**Example.** Step 42.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 39: skinning vertex shader + branch by mesh.boneIndices`.  
**Verify.** smoke 71 of 71 (no example uses it yet).  
**Snapshot.** `step-40-skin-shader` (next step is the consumer).

## Step 40 · `z.models.updateModelAnimation`

**Goal.** Sample animation pose, compute bone matrices, upload.

**Touches.** `src/drawing.zig` `models` namespace.

**Body.**
```zig
pub fn updateModelAnimation(
    model: *Model,
    anim: ModelAnimation,
    frame: c_int,
) void {
    if (!isModelAnimationValid(model.*, anim)) return;

    const f = @mod(@max(0, frame), anim.keyframeCount);
    const pose: ModelAnimPose = anim.keyframePoses[@intCast(f)];

    // For each bone:
    //   inv_bind = invert(skeleton.bindPose[i])
    //   world    = transformToMatrix(pose[i])
    //   model.boneMatrices[i] = world * inv_bind
    var i: usize = 0;
    while (i < @as(usize, @intCast(model.skeleton.boneCount))) : (i += 1) {
        // ... compose ...
    }

    // Upload via rlSetUniformMatrices to the bound shader's
    // SHADER_LOC_MATRIX_BONETRANSFORMS slot.
}
```

**Reference.** raylib `rmodels.c::UpdateModelAnimation` (~80 LOC).

**Inline tests** (2):
- One-bone identity-pose model, frame 0 → identity bone matrix
- Two-frame animation, frame 0 ≠ frame 1's bone matrices

**Example.** Step 42.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 40: updateModelAnimation`.  
**Verify.** test +2 (660); smoke 71 of 71.  
**Snapshot.** No.

## Step 41 · `z.models.updateModelAnimationEx` (cross-fade)

**Goal.** Per-bone slerp between two animations, weighted by
`blend ∈ [0, 1]`.

**Touches.** `src/drawing.zig` `models` namespace.

**Body.**
```zig
pub fn updateModelAnimationEx(
    model: *Model,
    anim_a: ModelAnimation,
    frame_a: c_int,
    anim_b: ModelAnimation,
    frame_b: c_int,
    blend: f32,
) void {
    // Per-bone:
    //   t = lerp(pose_a.translation, pose_b.translation, blend)
    //   r = slerp(pose_a.rotation,    pose_b.rotation,    blend)
    //   s = lerp(pose_a.scale,        pose_b.scale,       blend)
    //   ... compose into bone matrix as in Step 40
    ...
}
```

**Reference.** raylib `rmodels.c::UpdateModelAnimationBlend`
(slightly different signature — raylib takes `dt` and uses
internal state; we take both frames + blend explicitly,
matching usage in `examples/models/models_animation_blend_custom.c`).

**Inline tests** (3):
- blend=0 matches anim A
- blend=1 matches anim B
- blend=0.5 produces matrices between (component-wise)

**Example.** Step 42.  
**Cheatsheet.** No change yet.  
**Changelog.** `Step 41: updateModelAnimationEx (cross-fade)`.  
**Verify.** test +3 (663); smoke 71 of 71.  
**Snapshot.** No.

## Step 42 · `skinned_mesh.zig` example

**Goal.** Validate the entire glTF + skinning + animation
pipeline end-to-end.

**Touches.**
- `examples/skinned_mesh.zig` (new, ~150 LOC).
- `assets/animated_character.glb` (new, ~50 KB; CC0 rigged model
  with at least 2 animations).
- `build.zig` — append `"skinned_mesh"`.

**Behaviour.** Load embedded glb; play animation A; spacebar
crossfades to animation B over 500ms via
`updateModelAnimationEx`.  Mirror raylib's
`examples/models/models_animation_gpu_skinning.c`.

**Reference.** That raylib example.

**Tests.** None.  
**Cheatsheet.** "Common idioms" → add "Animated 3D model" subsection.  
**Changelog.** `Step 42: skinned_mesh example`.  
**Verify.** smoke 72 of 72.  
**Snapshot.** No.

## Step 43 · Final consolidation

**Goal.** Lock in the final state.

**Touches.**
- `notes/coverage-plan-v2.md` — mark all phases complete (this
  file).
- `notes/raylib-coverage-plan.md` — mark all phases complete.
- `notes/raylib-coverage-gaps.md` — strike through everything
  handled.
- `CHEATSHEET.md` — update final coverage % and migration cheat
  sheet for raylib porters (which fns are renamed, which
  semantically equivalent).
- Re-run `python3 src/notes/cheatsheet-generator.py >
  src/notes/coverage-report.md`.
- `notes/CHANGELOG.md` — promote `[Unreleased]` to a versioned
  entry (e.g. `## [0.6.0] — coverage push`) with a summary of
  all 43 steps.

**Verification (full sweep):**
```sh
zig build test --summary all
zig build smoke-test --summary all
python3 src/notes/cheatsheet-generator.py | head -25
```
Expect: ~663 host tests / ~72 smoke / ~93 % coverage.

**Tests.** None (consolidation only).  
**Example.** None.  
**Cheatsheet.** Final pass — see above.  
**Changelog.** `Step 43: final consolidation. Coverage 77.1 % → ~93 %.
Audio (65 fns, 8.4 % of in-scope) remains the only deferred arc`.  
**Snapshot.** `step-43-FINAL`.

---

# Per-step gate checklist

Before marking any step "done":

- [ ] `zig build test --summary all` → green, count ≥ baseline
- [ ] `zig build smoke-test --summary all` → all green
- [ ] `notes/CHANGELOG.md` has an entry under `[Unreleased]`
- [ ] `CHEATSHEET.md` reflects new public surface where applicable
- [ ] If a new example: appears in `build.zig`'s `examples` array
- [ ] Snapshot saved if step is on the [snapshot cadence](#snapshot-cadence)

# How to resume after an interruption

1. Verify clean state (pre-flight commands above).
2. Find the last completed step from `notes/CHANGELOG.md`.
3. Read this file from the next step's section onward.
4. If the working tree shows uncommitted progress, finish that
   step (re-running the gate checklist) before advancing.

# Total deliverable

After Step 43:

- **+48 raylib functions ported**
- **+14 rename-map entries** (existing fns recognised)
- **+12 new examples** (`triangle_gradient`, `dynamic_mesh`,
  `window_demo`, `texture_readback`, `image_text`, `mrt_demo`,
  `touch_paint`, `gestures_demo`, `gestures_testbed`, `gltf_simple`,
  `gltf_textured`, `skinned_mesh`)
- **~+70 host tests** (mostly inline next to the functions they
  test)
- **Zero new top-level files in `src/`** — everything lands in
  the existing big files (`runtime.zig`, `drawing.zig`,
  `codecs.zig`, `rlgl.zig`, `web.zig`, `zimr.zig`)
- **Coverage 77.1 % → ~93 %** in-scope (audio remains deferred,
  ~8 % of in-scope as 65 functions)
