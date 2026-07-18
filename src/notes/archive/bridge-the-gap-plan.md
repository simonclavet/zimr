# bridge-the-gap-plan.md

_Plan to close the remaining gap between zimr and raylib 6.0._

## Execution status

**Status: Phases 1A + 1B + 1C + 2 + 3 COMPLETE.** Tests 794/794, smoke 90/90.

| Phase | Status | Fns landed | Coverage delta |
|---|---|---:|---|
| 1A. Window/UX gaps | ✅ done | 9 | core 47.1% → 51.4% |
| 1B. Texture gaps | ✅ done | 3 | textures 88.8% → 91.4% |
| 1C. rlgl gaps | ✅ done | 6 | rlgl 77.9% → 81.6% |
| 2. Frame methods | ✅ done | 13 | (no count change; same fns reachable via Frame) |
| 3. Top-level raylib aliases | ✅ done | 3 | covered via rename map |

Overall in-scope coverage: **78.1% → 80.2%** (705 → 724 ported,
198 → 180 intentionally skipped).

The remaining ~10 GAP entries are all niche:
`SetGamepadMappings` (browser uses fixed mapping), `GetClipboardImage`
(async — TODO), `LoadFontFromImage` (bitmap-font), `GenMeshCubicmap`
(voxel mesh), `rlSetVertexAttributeDefault` (int-vs-float dispatch
complexity), and a handful of compute-shader / VR / automation-event
items that genuinely don't apply on web.

After the audit (`src/notes/coverage-report.md`), the picture is:

| | count | action |
|---|---:|---|
| ported | 705 | done |
| intentionally skipped (NOT_PORTED) | 198 | done — documented |
| in-scope | 903 | 100% accounted for |

So coverage isn't actually a number-go-up problem.  The remaining
opportunities are:

1. **GAP** entries inside `NOT_PORTED` (~20 fns) — flagged "skipped" but
   could realistically be ported.
2. **Renames** (~101 entries in `RAYLIB_TO_ZIMR_RENAMES`) — some justified,
   some lateral.  Decide per-entry: KEEP / ALIAS / REVERT.
3. **Architectural divergences** — `frame.clear`, the Frame parameter
   pattern, namespace organisation.  Decide: keep, document, or alias.

## Phase 0: Decision criteria

For every divergence we evaluate:

- **Does Zig require it?**  (Allocator param, error union, slice strings.)
  → Justified.
- **Does the web platform require it?**  (Async clipboard, async asset
  load, no FS, no monitor enumeration.)  → Justified.
- **Does it improve readability when called from Zig?**  (Drop redundant
  prefix when in a namespace; verb-first naming.)  → Justified, but a
  raylib-named ALIAS may help porters.
- **Is it a lateral move?**  (Different name for the same shape with no
  Zig-idiomatic gain.)  → Either revert or alias.
- **Is it a deliberate architectural improvement?**  (Frame param,
  scoped scratch allocator.)  → KEEP, document.

The default for borderline cases: **add a raylib-named alias** that
delegates to the zimr name.  Aliases are zero-cost (one-line `pub const
RaylibName = zimrName;`) and let existing raylib code copy-paste.

## Phase 1: Implement GAP functions (18 fns)

Highest user value first.  Each should land with a test + an example or
existing-example call site.  Group A is highest priority.

### 1A. Window / UX gap fillers (9 fns, ~250 lines)

**Most-asked-for transliteration of any raylib app.**

| fn | impl sketch | LoC |
|---|---|---:|
| `core.setMouseCursor(cursor)` | `MouseCursor` enum → CSS keyword string → `dom.setCanvasCursor(name)` JS bridge | 40 |
| `core.isWindowResized() bool` | bridge sets a sticky `resized` flag from `ResizeObserver`; getter clears on read | 30 |
| `core.isFileDropped() bool` + `loadDroppedFiles()` + `unloadDroppedFiles()` | bridge captures `dragover`/`drop` events → bytes table; userland `loadDroppedFiles` returns a slice of bytes and filenames | 80 |
| `core.setWindowIcon(image)` + `setWindowIcons(images[])` | encode to PNG via existing internal encoder → data URL → swap `<link rel="icon">` | 40 |
| `core.setWindowOpacity(opacity)` | bridge: `canvas.style.opacity = String(o)` | 10 |
| `core.setWindowFocused()` | bridge: `canvas.focus()` | 10 |
| `core.getClipboardImage()` | bridge: async `navigator.clipboard.read()` → poll handle (mirrors `getClipboardTextAsync`) | 50 |

Order: `setMouseCursor` → `isWindowResized` → drag-drop → favicon → opacity/focus → clipboard image (last because async).

### 1B. Texture gap fillers (3 fns, ~100 lines)

| fn | impl sketch | LoC |
|---|---|---:|
| `textures.exportImageToMemory(gpa, image, format) ![]u8` | thin wrapper around the internal PNG encoder; format = `.png` only initially | 30 |
| `textures.imageFromChannel(image, channel) Image` | walk pixels, copy single channel to grayscale Image | 35 |
| `textures.imageMipmaps(*image, gpa)` | iterative box-filter downscale, append to image data | 35 |

### 1C. rlgl gap fillers (7 fns, ~80 lines)

These are tiny WebGL passthroughs in the `rlgl_gpu` style.

| fn | impl sketch | LoC |
|---|---|---:|
| `rlgl.rlSetPointSize(size)` | calls `gl.vertexAttrib1f(..., size)` (WebGL2 has no `glPointSize`; emulated via vertex attribute or shader uniform) | 15 |
| `rlgl.rlGetPointSize() f32` | mirror state | 5 |
| `rlgl.rlCheckErrors()` | `gl.getError()` loop, log via traceLog | 15 |
| `rlgl.rlSetBlendFactors(src, dst, eq)` | `gl.blendFunc + gl.blendEquation` | 15 |
| `rlgl.rlSetBlendFactorsSeparate(srcRGB, dstRGB, srcA, dstA, eqRGB, eqA)` | `gl.blendFuncSeparate + gl.blendEquationSeparate` | 15 |
| `rlgl.rlSetVertexAttributeDefault(loc, value, type, count)` | `gl.vertexAttribNfv` family | 15 |
| `rlgl.rlCopyFramebuffer(x, y, w, h, fmt, *pixels)` | wrap `gl.readPixels` (similar to existing `loadImageFromScreen`) | 20 |

After Phase 1 the GAP count drops from ~20 to ~2 (`ImagePalette`-related, niche).

## Phase 2: Rename audit (~101 entries)

Each `RAYLIB_TO_ZIMR_RENAMES` entry gets reviewed.  Grouped by category:

### 2A. Justified — KEEP zimr names, no alias

These divergences encode something Zig-mandatory or web-platform-mandatory;
adding a raylib alias would be misleading because the signature differs.

- **Slice-shape strings (the entire `text.*` family)**: `DrawText`,
  `DrawTextEx`, `DrawTextPro`, `DrawTextCodepoints`, `MeasureText`,
  `MeasureTextEx`, `MeasureTextCodepoints` — raylib takes `const char *`
  (null-terminated); zimr takes `[]const u8`.  Different signatures
  CANNOT be aliased.
- **Codepoint nav family**: `GetCodepointCount` → `countCodepoints`,
  `GetCodepointNext` → `nextCodepoint`, `GetCodepointPrevious` →
  `prevCodepoint`, `GetCodepoint` → `nextCodepoint` — operate on slices
  + cursor, not C-strings + out-pointer.  Can't alias.
- **Audio namespacing** (50+ entries): `LoadSound` → `sounds.loadFromMemory`,
  `PlaySound` → `sounds.play`, `PlayMusicStream` → `music.play`, etc.
  zimr puts audio types into 4 namespaces (audio_device, waves, sounds,
  streams, music) for organization.  raylib's flat naming wouldn't fit;
  alias would be `pub const PlaySound = sounds.play;` at top level —
  zero-cost but breaks the namespace clarity.  **Decision: don't alias.**
- **Async clipboard**: `GetClipboardText` → `getClipboardTextAsync` —
  the browser API is async; can't have a sync `GetClipboardText`.  Can't
  alias.
- **Memory-shape model loader**: `LoadModel` → `loadModelFromMemory` —
  no FS, takes bytes not path.  Different signature.  Can't alias.
- **Resume keyword**: `ResumeSound` → `sounds.resumeSound`, similarly
  for music/streams — `resume` is a Zig keyword.  Could alias as
  `@"resume"` but that's worse than the suffix.  Keep.

### 2B. Lateral renames — RECONSIDER or ADD ALIAS

These are renames where zimr picked a slightly-different name with no
clear Zig-idiomatic justification.  Each is a one-line alias if we
decide to keep the zimr name.

| raylib | zimr | verdict |
|---|---|---|
| `IsWindowFullscreen` | `core.isFullscreen` | KEEP zimr name (drops redundant `Window` prefix; in-namespace).  ALIAS for porters: `pub const isWindowFullscreen = isFullscreen;` |
| `GetSplinePointBezierQuadratic` | `shapes.getSplinePointBezierQuad` | KEEP (just shorter).  ALIAS optional. |
| `LoadFontFromMemory` | `text.loadFontFromTtfData` | KEEP (zimr name is more specific — only TTF supported, not generic font formats).  ALIAS for porters: `pub const loadFontFromMemory = loadFontFromTtfData;` |
| `ImageDrawRectangleLinesEx` | `textures.imageDrawRectangleLines` | RECONSIDER — zimr's `imageDrawRectangleLines` has the *Ex* signature (rec + thick + color), so the `Ex` suffix would be misleading.  Add a separate `imageDrawRectangleLinesNoThickness(image, x, y, w, h, color)` that mirrors raylib's non-Ex.  Not a rename — a missing function. |
| `ImageDrawTriangleGradient` | `textures.imageDrawTriangleEx` | RECONSIDER — zimr's `Ex` is per-vertex-color, semantically the same as raylib's `Gradient`.  KEEP zimr name; ALIAS the raylib name. |
| `CodepointToUTF8` | `text.encodeCodepoint` | KEEP zimr name (active verb, returns `Utf8Bytes` fixed array — better Zig).  Different signature; can't alias cleanly. |

### 2C. Architectural divergences — KEEP, document

These are NOT renames — they're a different programming model.  Aliases
would be misleading because the call sites don't translate 1:1.

#### `frame.clear(color)` vs `ClearBackground(color)`

raylib uses global drawing state managed by `BeginDrawing`/`EndDrawing`.
zimr uses an explicit `Frame` parameter (auto-wrapped by the runtime).
Why the divergence is justified:

- **No hidden global state**: raylib stores the active framebuffer in
  a file-static; zimr makes the user receive `Frame *` so it's a
  declared dependency.
- **Compile-time enforcement**: in zimr you literally can't call
  `frame.clear` outside an update callback — there's no Frame to call
  it on.  In raylib, `ClearBackground` outside `BeginDrawing` is UB.
- **Frame carries more than "the framebuffer"**: `f.scratch` (per-frame
  arena), `f.clock` (timing), `f.loader` (async asset access),
  `f.log`, `f.rng`, `f.ui` — each replaces a raylib global.  Bundling
  them on `Frame` makes the surface discoverable (`f.<tab>`).

**Decision: KEEP**.  Document as a porting-guide entry.

Optional: add `frame.clearBackground(color)` as an alias for the
single-call name change.  Cost: 3 lines.  Benefit: closer copy-paste
for raylib examples.  **Recommendation: do it.**

#### `text.draw(string, x, y, ...)` vs `DrawText(string, x, y, ...)`

The namespace move (`text.`) plus prefix drop (`Draw` → `draw`) are
separate decisions:

- Namespace: justified (organizes the API; matches raylib's own
  `// Text Drawing functions` comment grouping).
- Prefix drop: justified inside a namespace (`text.draw` reads better
  than `text.drawText` — the second `text` is redundant).

**Decision: KEEP**.  ALIAS not viable because the slice-vs-C-string
signature change makes the call sites differ anyway.

#### `camera.beginMode2D(camera_obj)` vs `BeginMode2D(camera_obj)`

Namespace move only; signature unchanged.

**Decision: KEEP**.  ALIAS at top level: `pub const beginMode2D =
camera.beginMode2D;` — zero cost, helps porters.  **Recommendation: do it.**

### 2D. Renames-into-`std`

Entries like `TextLength` → `s.len`, `TextCopy` → `@memcpy`, `TextSplit`
→ `std.mem.splitScalar` — these aren't renames at all, they're "delete
this raylib function, use Zig's natural equivalent".  Currently
documented in the cheatsheet via the rename map pointing to `std`.

**Decision: KEEP**.  These are the right call.  No alias possible.

## Phase 3: Verification

After Phase 1 + 2 implementation:

1. `zig build test --summary all` — must stay green (currently 783/783).
2. `zig build smoke-test --summary all` — must stay green (currently 90/90).
3. `python3 src/notes/cheatsheet-generator.py > src/notes/coverage-report.md`
   — re-run; expected delta:
   - GAP count: 20 → 2 (only niche stuff like `LoadImagePalette` left)
   - Coverage: 78% → ~80%
   - Aliased raylib names: count goes up by however many `pub const`
     aliases we add (probably ~5-10).

## Effort estimate

| phase | LoC | turns |
|---|---:|---:|
| 1A. Window/UX gaps | 250 | 2 |
| 1B. Texture gaps | 100 | 1 |
| 1C. rlgl gaps | 80 | 1 |
| 2B. Lateral rename aliases | 30 | 0.5 |
| 2C. Architectural aliases | 20 | 0.5 |
| Documentation | 100 | 0.5 |
| **Total** | ~580 | ~5.5 |

## Open questions for the user

1. **GAP priorities**: do all 18, or pick a subset?  My recommendation:
   1A (high user value) + 1B (parity completeness) + 1C (small).  Skip
   `getClipboardImage` (async, lower priority).
2. **Aliases**: do we add `pub const ClearBackground` etc. at top level?
   Pro: copy-paste from raylib.  Con: top-level surface bloats from
   ~30 to ~150 names.  My recommendation: **yes for the 5 most-common
   single-call names** (`ClearBackground`, `BeginDrawing`/`EndDrawing`
   would actually have to be no-ops since they're auto-wrapped, so skip
   those; `BeginMode2D`/`EndMode2D`/`BeginMode3D`/`EndMode3D` aliases
   make sense).  No to a comprehensive rebadge.
3. **Porting guide**: write `src/notes/migrating-from-raylib.md`?
   Already have a stub.  Worth completing.

## Anti-goals

- Don't undo `Frame` parameter — it's the architecture.
- Don't undo audio namespacing — sounds/streams/music separation reflects
  real underlying-resource differences.
- Don't undo slice-shape strings — that's the whole point of being a
  Zig library.
- Don't add a `core.frame: ?*Frame` global accessor for "raylib-style"
  global drawing.  That's a regression.
