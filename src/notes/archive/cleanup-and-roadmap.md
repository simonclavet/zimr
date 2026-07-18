# Cleanup status + next 20 turns

This is the canonical near-term plan.  It supersedes the per-session
notes in ZIGGIFY and the rolling-prose in STATUS for forward-looking
decisions.  ROADMAP.md remains the long-form 100-step master plan;
this doc is the tactical zoom-in for what we're actually doing right
now and next.

## Where we are (May 2026)

The codebase has cleared the four big architectural shifts:

1. **C-ABI scaffolding gone.**  Phase 12 (Sessions N+13–N+25) is
   complete — every module is pure-Zig, camelCase, method-style,
   error-union throughout.
2. **Effects pivot done.**  No globals in user-facing code.  Time,
   randomness, loading, and logging go through `Frame.{clock, rng,
   loader, log}` — see `effects-design.md`.  35 tests cover the four
   effect types.
3. **Spring cleanup phases A-E done.**  All `genMesh*` (12),
   `genImage*` (5), and `load*` constructors take `Allocator`,
   return error unions, use errdefer for partial-allocation cleanup.
   All in-place image transforms (`imageResize*`, `imageRotate*`,
   `imageCrop`, `imageBlur*`, `imageKernelConvolution`,
   `imageDither`, `imageCopy`, `imageFromImage`) take `gpa: Allocator`
   and return `!void` or `!Image`.  All `unload*` functions take
   `gpa`.  Phase D removed 13 multi-app-hostile static-buffer text
   helpers.  Active `libc.*` calls reduced to 5 dead-code-path
   `libc.free` calls in `src/models.zig` (skeleton/animation arrays
   from not-yet-ported model loaders); textures.zig and text.zig
   are libc-free.
4. **Style guide adopted.**  Four rules in `style-guide.md`:
   arg-per-line signatures, explicit local types (with same-line
   exception), braces on every branch, casual comments.  Mandatory
   for new and modified code; legacy code grandfathered until
   touched.

**Test/smoke status:** 437/437 host tests, 14/14 smoke tests.  Wasm
builds green for all 14 examples.

**Outstanding cleanup:** none on the critical path.  The skeleton
and animation libc.free calls in models.zig will swap to gpa during
ROADMAP §8 (zgltf adoption), since their producers don't exist yet.
Phase F (`[*c]T` → `?[*]T` field migration) remains tracked as a
future cleanup with no concrete trigger.

## Next 20 turns — ordered for maximum future-step ease

The principle: **do the things that make later things easier first.**
Cleanup unblocks leak detection.  Leak detection unblocks the
multi-app demo.  The multi-app demo proves the no-globals design
works in practice.  Then we're ready for dependency adoption with
confidence the foundation is sound.

### Turns 1-4 — finish the cleanup (Phases D + E)

- **Turn 1: Phase D.1 — `loadCodepoints` + `loadUTF8`.**  ✅ Done.
  Both now take `gpa: Allocator` and return Zig slices (`[]c_int`
  for codepoints, `[:0]u8` for UTF-8).  Free with `gpa.free(slice)`.
  `unloadCodepoints` / `unloadUTF8` removed (no longer needed).
  loadUTF8 simplified to two-pass exact-size allocation, no
  resize-after-encode.  5 new tests including full UTF-8
  multi-byte roundtrip; tests now run on host since they use
  `std.testing.allocator` instead of libc.malloc.  430/430 host +
  14/14 smoke green.
- **Turn 2: Phase D.2 — text helpers cleanup.**  ✅ Done.  Audit
  revealed the static-buffer hazard: 13 `text*` helpers returned
  pointers into shared module-level buffers, multi-app-clobbering.
  Zero callers in zimr's tree, so all 13 deleted (`textSubtext`,
  `textToUpper/Lower/Pascal/Snake/Camel`, `textRemoveSpaces`,
  `textSplit/Join/Replace/Insert`, `codepointToUTF8`,
  `unloadTextLines`) plus their 4 backing static buffers.  Real
  libc.free callers fixed: `unloadFont(gpa, font)` and
  `unloadFontData` now use `allocator_mod.freeMany`.  text.zig
  shrunk from 1368 → 1187 lines, zero libc.* calls remain.
  430/430 + 14/14 green.
- **Turn 3: Phase E.1 — `imageResize*` + `imageCrop` + `imageToPOT`.**
  ✅ Done.  All five image-resize-family transforms (`imageResize`,
  `imageResizeNN`, `imageResizeCanvas`, `imageCrop`, `imageToPOT`)
  now take `gpa: Allocator`, return `Allocator.Error!void`, free
  the old buffer with `freeImageData` after the new buffer is built.
  `imageAlphaCrop` cascades `gpa` through to `imageCrop`.  New
  `freeImageData` helper in textures.zig matches `unloadImage`'s
  byte-count derivation.  `Image.crop(gpa, region)` shortcut updated.
  4 new realloc-path tests prove the leak-free behavior using
  `std.testing.allocator`.  434/434 + 14/14 green.
- **Turn 4: Phase E.2 — remaining image transforms.**  ✅ Done.
  All ten remaining in-place image transforms ziggified:
  `imageBlurGaussian`, `imageKernelConvolution`, `imageDither`
  (gpa for scratch buffers), `imageRotateCW/CCW/Rotate` (gpa +
  `freeImageData` swap), `imageCopy`, `imageFromImage` (gpa, return
  `!Image`), `unloadImageColors/Palette` in textures.zig (gpa +
  `freeMany`), plus the private `loadImageColors` /
  `unloadImageColors` pair in models.zig (used by genMeshHeightmap)
  — collapsed to a slice-returning `loadImageColors(gpa, image)
  ![]Color` with `gpa.free(slice)` for cleanup.  3 new realloc-path
  tests (rotateCW, copy independence, fromImage extraction).
  **Zero `libc.*` in textures.zig.**  Stale comments swept across
  shaders.zig, types.zig, textures_test.zig.  Removed the duplicate
  `Shader.deinit` on the type (had stale libc.free) — now delegates
  to `shaders.unloadShader(gpa, shader)`.  437/437 + 14/14 green.

  **Active libc.* in zimr post-Phase-E:** only `src/libc.zig`
  itself (wasm-allocator-backed shim) plus 5 dead-code-path
  `libc.free` calls in `src/models.zig` for skeleton / animation
  arrays.  Those go live when ROADMAP §8 (zgltf adoption) ports
  the matching loaders, at which point they swap to
  `allocator_mod.freeMany`.

### Turns 5-7 — verify the cleanup paid off

- **Turn 5: leak-detection scaffolding.**  ✅ Done.  New
  `src/leak_test.zig` (10 tests) drives multi-iteration lifecycle
  chains across the cleanup-touched surface: gen/free image
  (100x), gen/resize (50x), full-transform-chain
  resize→rotate→crop→resizeNN→canvas (25x), imageCopy roundtrip
  (50x), imageFromImage (50x), gen/blur (20x), gen-all-image-variants,
  gen/free mesh across cube/sphere/plane (25x),
  loadImageColors (50x), and a per-frame ArenaAllocator pattern
  (100 frames).  Verified via canary test that
  `std.testing.allocator` actually flags leaks (would-be-leaking
  test "passes" but the harness reports
  `1 tests leaked memory` and exits non-zero).  Leak-test
  convention documented in `docs/style-guide.md`.  447/447 host
  (10 new) + 14/14 smoke green.
- **Turn 6: fix any leaks the test exposes.**  Almost certainly
  there are some — examples that init textures in `main()` and
  never `deinit` them.  Real concrete payoff for the cleanup.
- **Turn 7: document the leak-test pattern** in
  `architecture.md` under a new "Leak detection" subsection, plus
  a note in `style-guide.md`.  Future contributors know how to
  write leak-tested code.

### Turns 8-10 — first multi-app demo

The multi-app design (`docs/multiapp-design.md`) needs two userland
helpers and a first demo.  This is the public proof-of-concept that
the no-globals design actually delivers.

- **Turn 8: `Logger.Prefixed` + `Loader.Scoped` adapters.**  ✅
  Done.  `Logger.Prefixed` (~30 LOC nested type in
  `src/logger.zig`) wraps a parent Logger and prepends
  `<prefix>: ` to every emitted line; zero-alloc, uses a 4096-byte
  stack buffer (truncates like raylib if the combined line
  doesn't fit).  `Loader.Scoped` (~75 LOC nested type in
  `src/loader.zig`) wraps a parent Loader and prepends a
  `base_path` to every URL passed to `loadFileData`; the other
  three vtable slots (poll/unload/elapsedMs) operate on Handle
  values and delegate 1:1.  Both have lifetime notes in their
  doc comments and use `*const Self` userdata pointers (lets
  callers write `const prefixed = ...`).  9 new tests covering
  prefix, level preservation, raw-emit bypass, nested wrapping,
  empty-prefix identity, and 1:1 delegation through the
  non-rewritten vtable slots.  456/456 host + 14/14 smoke green.
- **Turn 9: `examples/gallery.zig` — first multi-app demo.**  ✅
  Done.  4 sub-apps in a 2×2 grid: `pulse` (color-cycle
  background), `spinner` (rotating triangle, exercises
  `f.clock.time()`), `sparkles` (RNG-driven random points,
  exercises `f.rng.float01()` with per-child `Rng.Seeded`),
  `counter` (text counter, exercises `f.log.info` with
  `Logger.Prefixed`).  Each sub-app gets its own seeded RNG
  (different seed → independent visual streams) and its own
  prefixed logger (every line tagged with sub-app name in the
  merged stream).  Hard scissor (`z.shaders.beginScissorMode`)
  isolates draws between cells.  Generic `runSubApp` helper uses
  `comptime` state-pointer + update-fn — no type erasure, no
  `@ptrCast` in user code.  ~280 LOC including 4 sub-apps inline.
  Smoke test verified: 7,790 gl calls in 3 frames (biggest of
  any example) and the prefixed log stream comes through cleanly:
  `pulse: started`, `spinner: started`, `sparkles: started`,
  `counter: tick #1`.  Total 15/15 smoke green.
- **Turn 10: kill/restart proof.**  ✅ Done.  New
  `src/multiapp_test.zig` (9 tests) drives realistic multi-app
  lifecycle patterns under `std.testing.allocator`.  A
  `TestSubApp` that owns a name + dynamic event history exercises
  init/tick/deinit balance.  A `ChildSlots` parent that owns 4
  optional children covers spawn-tick-kill, kill-mid-run-keep-
  others-alive, kill+restart+kill chains, and random-churn
  patterns over 200 frames.  An `ArenaSubApp` proves the
  per-child-arena pattern (most idiomatic shape — kill = drop
  the arena, no per-allocation tracking needed).  A
  `LoggingSubApp` covers the variant where a child stores its
  own `Logger.Prefixed` long-lived alongside the prefix string
  it owns.  Canary-verified: forgetting `app.deinit()` in any
  cycle causes the test to fail with line-precise leak reports
  (`multiapp_test.zig:83:50` = exact alloc site).  465/465 host
  (9 new) + 15/15 smoke green.

### Turns 11-14 — TrueType + atlas adoption (ROADMAP §6)

`andrewrk/TrueType` was vendored at `src/_vendor/truetype/` and has
now been adopted in-tree.  This is the first real dep adoption,
unblocking custom fonts in `loadFont`/`loadFontEx`.

- **Turn 11: TrueType in-tree adoption.**  ✅ Done.  Per user
  direction, the upstream `TrueType.zig` (~2384 LOC, MIT-licensed)
  was relocated from `src/_vendor/truetype/` into `src/truetype.zig`
  proper, with a clear "Adapted from andrewrk/TrueType" header
  noting source URL, license (MIT both ways), and the specific
  modifications applied at import.  The old thin-shim approach is
  retired.  Upstream body is preserved verbatim except for the
  `build_options.debug_todo` drop (`builtin.is_test` substituted)
  — keeping it close to upstream means future fixes from
  andrewrk/TrueType can be cherry-picked cheaply.  Two
  zimr-canonical entry points added below an explicit "zimr
  additions" banner: `Font` alias and `loadFontFromTtf(gpa,
  ttf_bytes) !Font` (allocator slot reserved for the atlas-baker
  arc; today upstream's `load` is allocation-free).  Tests
  rewritten to use the in-tree path: 4 covering enum invariants,
  the `Font` alias size match, and the new `loadFontFromTtf`
  signature reachability.  466/466 host + 15/15 smoke green.
  `_vendor/truetype/` directory deleted.
- **Turn 12: atlas baker.**  ✅ Done.  Two pieces:
  - `src/rectpack.zig` (~140 LOC): pure-CPU shelf-bin rectangle
    packer.  Sorts by height descending in-place, walks shelves
    left-to-right, supports padding.  `suggestAtlasWidth` helper
    picks a square-ish power-of-two with ~25% slack from the
    rect set.  11 tests covering empty input, single rect, same-
    height shelf sharing, horizontal overflow → new shelf,
    rect-wider-than-atlas overflow flag, tallest-first ordering,
    padding, 100-rect bulk pack, and the suggestion helper's
    edge cases.
  - `bakeFontAtlas(gpa, font, font_size, codepoints, padding)
    !FontAtlas` in `src/text.zig` (~180 LOC): four-pass baker.
    (1) Per-glyph metrics + bbox via TrueType's `glyphBitmapBox` /
    `glyphHMetrics`.  (2) Pack rectangles via `rectpack.pack`.
    (3) Allocate RGBA8 atlas, rasterize each glyph via
    `glyphBitmap`, blit grayscale → RGBA (alpha = bitmap value,
    RGB = white).  (4) Build per-codepoint `GlyphInfo[]` and
    `Rectangle[]` arrays in input order using the packer's
    `id` field to undo the height-sort.  Returns `FontAtlas`
    with image + glyphs + recs + base_size + padding, all
    gpa-allocated, deinit balanced.
  - 3 surface tests covering NoCodepoints error, signature
    reachability, FontAtlas.deinit reachability.  Real
    visual-correctness coverage comes via the text_layout
    example update in Turn 14.  480/480 host + 15/15 smoke green.
- **Turn 13: wire `loadFontEx` end-to-end.**  ✅ Done.
  `loadFontFromTtfData(gpa, ttf_bytes, font_size, codepoints,
  padding) !Font` in `text.zig` (~140 LOC including doc).  Five
  steps: parse TTF via `truetype.loadFontFromTtf`, bake atlas via
  `bakeFontAtlas`, GPU upload via `wasm_fwd.rlLoadTexture` (new
  forwarder added — host returns 0, wasm forwards to
  `rlgl_gpu.rlLoadTexture`), free CPU image, assemble Font with
  ownership transfer of `glyphs[]` / `recs[]` from the FontAtlas.
  errdefer chain releases everything if upload fails.  Output is
  shaped exactly like raylib's Font so existing `drawTextEx` /
  `measureTextEx` / `unloadFont` consume it unchanged.
  Also added: `default_codepoints_ascii` (comptime [95]u21,
  ASCII 32..126) for raylib-compatible default coverage; named
  error union `LoadFontError` (NoCodepoints, AtlasOverflow,
  GpuUploadFailed, plus Allocator.Error).
  3 surface tests covering ASCII codepoints content, signature
  reachability, error-variant compile.  483/483 host + 15/15
  smoke green.
- **Turn 14: examples/text_layout.zig** ✅ Done.  Embeds
  `assets/RobotoMono-Regular.ttf` (~85 KB, Apache 2.0,
  Christian Robertson @ Google) via build.zig's
  `addAnonymousImport("roboto_mono_ttf", ...)`.  The example
  loads the font in `main()` after `z.init` via
  `z.text.loadFontFromTtfData(gpa, ROBOTO_MONO_TTF, 32,
  &FONT_CODEPOINTS, 2)` where `FONT_CODEPOINTS` is a
  comptime-built [102]u21 = ASCII 32..126 ++ 7 typographic
  extras (em dash, en dash, ellipsis, smart quotes).
  Demonstrates the codepoint-customization API while ensuring
  the example's em-dash actually renders.  Falls back to the
  default bitmap font (with a clear visual indicator) if load
  fails.  Demonstrates: (a) the same TTF rendered at five
  different render sizes from a single 32px atlas (downscaled
  and upscaled), (b) word-wrap using `measureEx` for TTF-aware
  metrics, (c) side-by-side `measureText` vs `measureEx`
  comparison.  Smoke logs confirm `ttf_loaded=true` end-to-end:
  parse → bake → upload → draw → measure.  ~270 LOC.
  483/483 host + 15/15 smoke green (text_layout: 1919 gl calls).
  Removes the "TODO: TTF" debt entirely.

### Turns 15-18 — zigimg adoption (ROADMAP §7)

Drop our hand-rolled PNG decoder in favor of zigimg's multi-format
support.  Unblocks `loadImage` for JPEG/BMP/TGA/QOI.

- **Turn 15: zigimg vendored.**  ✅ Done.  Per the user's
  direction ("just copy. We will modify it to respect our style"),
  zigimg lives at `src/zigimg/` rather than as a build.zig.zon
  dependency.  56 files, ~23K LOC.  Stripped the upstream
  build.zig / tests/ / gyro.zzz / zig.mod files at vendoring
  time.  Wrote a zimr-style header on `src/zigimg/zigimg.zig`
  documenting the SHA pinned, the modifications applied, and
  why we vendored.  Re-exported as `zimr.zigimg`.  Compiles to
  wasm32-wasi cleanly (probe verified via standalone build-obj).
  511/511 host (was 483, +28 from probe + zigimg's transitive
  tests) + 15/15 smoke green.
- **Turn 16: `loadImage(gpa, path)` and `loadImageFromMemory(gpa,
  bytes)`.**  Unified entry points dispatching to zigimg.
- **Turn 17: replace `src/png.zig` consumers** with the unified
  loaders.  Mostly mechanical; the smiley_png example proves the
  swap works.
- **Turn 18: `exportImage` (write PNG/JPEG)** — the
  long-deferred ROADMAP §1 step 13.  zigimg has the encoder; we
  just wire it up.

### Turns 19-20 — buffer for what surfaces

Two turns held in reserve.  Likely uses:
- Bug-fix sweep from the cleanup tests
- glTF first-pass (start of ROADMAP §8)
- Address whatever the multi-app demo or leak detection surfaces

## Why this order

**Cleanup before adoption.**  zigimg in particular allocates
significantly — adopting it on top of un-cleaned-up image code
would tangle two debuggability problems together.  Same with
TrueType: easier to wire when the surrounding `text.zig` is already
allocator-explicit.

**Multi-app before deps.**  The multi-app demo is the reality check
on whether our effects design holds up under composition.  If
something is wrong with `Loader.Scoped` or how arenas interact, we
want to find out *before* layering zigimg/glTF on top.  And the
leak-detection scaffolding from turns 5-7 makes the multi-app
demo's leak claims credible.

**TrueType before zigimg.**  Smaller dep, vendored already, fewer
surprises.  Builds confidence in the dep-adoption process before
tackling the bigger one.

**glTF deferred.**  ROADMAP §8 is large (10 turns by itself) and
should land as a focused arc, not piecemeal in turns 19-20.  If we
finish ahead of schedule, we start glTF; otherwise it's the next
20-turn arc.

## What this plan deliberately does NOT include

- **Audio (ROADMAP §9).**  Out of scope for this 20-turn arc.  The
  Web Audio API surface is its own design problem.
- **Perlin noise (ROADMAP §10).**  Two-turn drop-in once we have
  zigimg.
- **First release polish (ROADMAP §11).**  Premature; we want the
  multi-app demo + at least one real dep adoption before claiming
  v0.1 readiness.
- **Moving timing/RNG state from `core.zig` onto App.**  Documented
  as a known caveat in `effects-design.md`.  Currently the Browser
  impls of Clock/Rng/Logger reach into module-level state in
  `core.zig`.  This works but means tests can't have two Apps with
  independent time.  When multi-app needs it (it will, eventually),
  we'll do the move; today's userland multi-app trick from
  `multiapp-design.md` doesn't need it because children share the
  parent's clock honestly.
- **Phase F — convert `[*c]T` resource fields to `?[*]T`.**  The
  `extern struct` ABI parity with raylib.h is a leftover from the
  Phase 12 cleanup era and we don't actually need it (no one reads
  the binary layout).  Switching Mesh/Material/Shader/Model fields
  from `[*c]T` to `?[*]T` would let `gpa.free(ptr.?[0..n])` work
  cleanly without the `freeMany` helper, would catch nullness at
  the type level instead of via runtime `if (x != null)` guards,
  and would generally feel more Zig-shaped.  ~100+ touch sites
  across models/textures/text/rlgl_gpu plus their tests.  Tracked
  here so we don't lose the idea; deferred until there's a concrete
  demand (e.g. a bug rooted in the implicit-optional behavior).

## Ground rules carried over

- **Refresh zip every turn.**  Standing rule; ensures the
  output is always recoverable.
- **Update CHANGELOG every multi-function change.**  No silent
  API-shape shifts.
- **Reread `style-guide.md` often.**  Mandatory for new and
  modified code.
- **No globals.**  See `effects-design.md`.
- **Tests + smoke green at end of every turn.**  If a turn breaks
  things, the next turn opens with the fix, not new work.
