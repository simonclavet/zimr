# ROADMAP.md — zimr 100-step master plan

**Origin point.**  After Phase 12 (sessions N+13 through N+25) the
codebase is in a fundamentally healthy state: 297/297 host tests pass,
8/8 smoke tests pass, **zero non-platform externs** (everything that
was once C is now Zig), examples are camelCase + method-style + error-
union throughout.  We are no longer "porting raylib" — there is no
raylib, there is only zimr.  This roadmap is the next 100 steps to
get from here to v1.0.

**Authorial principle.**  Each step is sized to fit in roughly one
session.  Some are 30-line ports; some are research-and-design with
no code change.  Where a step naturally has substeps, those are
nested.  Difficulty markers: 🟢 trivial · 🟡 medium · 🔴 hard.
Status markers: ☐ not started · 🟡 in-progress · ✅ done.

**Sequencing principle.**  We deliberately interleave porting (binding
side) with dependency adoption (the Zig replacements catalogued in
DEPENDENCIES_PLAN.md), because the bindings are usually thin shims
over the dep — adopting both at once keeps the API correct.  We don't
hesitate to take a dep when it's natural; we don't force it when our
hand-rolled code is already serving us well.

**Per-step budget.**  Most steps target ≤ 200 LOC.  When a step
balloons past 400 LOC it gets a `[L]` marker and is a candidate for
sub-splitting if it doesn't land cleanly.

---

## Section 1: Coverage holes (steps 1–20)
*Finishing the in-scope raylib API audit at 65% → ~95%.*

These steps close per-section gaps identified in PORTING_PLAN.md
section 9.  Sequencing: easy wins first to keep velocity high.

1. ✅ 🟢 **`getKeyName(key)`** — small lookup table (~30 LOC, 1 fn).
   Maps key codes (KEY_A = 65, KEY_F1 = 290, etc.) to display
   strings ("A", "F1").  Returns null for unknown keys.

2. ✅ 🟢 **`drawCapsule` + `drawCapsuleWires`** — 3D shapes.  Two
   hemispheres + cylinder.  Reuses the parametric mesh primitives we
   just shipped.  Cleans up "3D shapes" section to 21/21.

3. ✅ 🟢 **`loadCodepoints(text) []c_int` + `loadUTF8(codepoints)`** —
   UTF-8 codepoint extraction.  Already implicit in our text drawing
   path; just needs the explicit allocator-returning API.

4. ✅ 🟡 **Image draw text variants** — `imageDrawText`,
   `imageDrawTextEx`.  Server-side rasterization of glyphs into an
   Image's CPU pixel buffer (vs. GPU draw).  Useful for procedural
   texture generation.  ~150 LOC.

5. ✅ 🟢 **`imageDraw`** — composite one Image onto another with
   source/dest rect + tint.  ~80 LOC.

6. ✅ 🟢 **`imageDrawTriangleEx`** — barycentric scanline triangle
   rasterizer with vertex colors.  ~100 LOC.

7. ✅ 🟢 **Drawing modes (CPU side)** — `beginShaderMode`/
   `endShaderMode`/`beginBlendMode`/`endBlendMode`/`beginScissorMode`/
   `endScissorMode`.  Lift wholesale from zray's window.zig — these
   are 5-line wrappers around rlgl_gpu state we already have.
   Cleans up "Drawing modes" from 4/17 to ~10/17.  ~80 LOC.

8. ✅ 🟢 **Image alpha ops** — `imageAlphaMask`, `imageAlphaClear`,
   `imageAlphaCrop`, `imageAlphaPremultiply`.  Pixel-walking
   transforms.  ~150 LOC.

9. ✅ 🟡 **Image blur + dithering** — `imageBlurGaussian`,
   `imageDither`.  Box-filter Gaussian; Floyd-Steinberg dither.
   ~200 LOC.

10. ✅ 🟢 **`imageColorTint`/`Invert`/`Grayscale`/`Brightness`/
    `Contrast`** — per-pixel color adjustments.  ~120 LOC.

11. ✅ 🟢 **`imageFlipVertical`/`imageFlipHorizontal`/`imageRotate90`/
    `imageRotate`** — most exist already; fill in the missing
    rotate-by-arbitrary-angle (bilinear sample).  ~100 LOC.

12. ✅ 🟢 **`imageResize` + `imageResizeNN`** — bilinear and nearest-
    neighbor resamplers.  ~120 LOC.

13. ☐ 🟡 **`exportImage` (PNG only for now)** — write our PNG decoder
    in reverse.  Not a priority but completes the symmetry.  Defer
    until adopting zigimg.  ~150 LOC.

14. ✅ 🟢 **Mouse wheel V variants** — `getMouseWheelMoveV` returns
    Vector2 with horizontal scroll component.  Already have the
    scalar; add the JS-side delta capture.  ~30 LOC.

15. ✅ 🟢 **Gamepad mappings** — `getGamepadName`, `getGamepadButton-
    Pressed`, `getGamepadAxisCount`.  Wraps the standard Gamepad API.
    ~80 LOC of dom.js + Zig wrappers.

16. ☐ 🟡 **`loadMaterials(filename, mats)`** — multi-material loader.
    Couples to either glTF (zgltf) or our own .mtl-style format.
    Defer until step 71+ (zgltf adoption).

17. ✅ 🟢 **Camera screen-space helpers** — `getScreenToWorldRayEx`
    that we don't have yet.  ~50 LOC.

18. ✅ 🟢 **`isFontValid` / `isImageValid` / `isMaterialValid` /
    `isModelAnimationValid`** — null-id-and-pointer checks.  ~30 LOC
    apiece.

19. ✅ 🟢 **`exportMesh(.OBJ)`** — text format, easy.  Skip glTF
    export.  ~80 LOC.

20. ✅ 🟢 **`getMeshBoundingBox` improvements** — already have it but
    extends to 3D-shape primitives (sphere/etc).  ~40 LOC.

**End-of-section milestone.**  In-scope coverage: 65% → ~92%.  All
remaining gaps are non-essential or require a dep adoption.

---

## Section 2: Examples + smoke tests (steps 21–32)
*Demonstrate the new surface; catch regressions before users do.*

21. ✅ 🟡 **`models3d` example** — sphere + cube + cylinder + cone +
    torus, rotating, lit by a directional light.  First example to
    exercise our Phase 12 mesh + drawMesh stack end-to-end.  Smoke-
    tested.  ~150 LOC.

22. ✅ 🟡 **`shader_uniforms` example** — fragment-shader-driven
    procedural pattern over a fullscreen quad with mouse-position
    uniform.  Exercises the new Shader API.  ~100 LOC.

23. ✅ 🟢 **`particles` example** — 2D point sprites + `getRandomValue`
    + xorshift trail effects.  Exercises the new RNG.  ~120 LOC.

24. ✅ 🟢 **`first_person_camera` example** — pointer-locked WASD +
    mouse-look using our new `disableCursor` + `updateCamera(.first_-
    person)`.  Walks through a generated terrain (genMeshHeightmap).
    ~150 LOC.

25. ✅ 🟢 **`text_layout` example** — uses default font, demonstrates
    measureText, multi-line wrapping helpers, and color-per-glyph.
    ~80 LOC.

26. ✅ 🟡 **Smoke test extensions** — every new example gets added to
    `tests/smoke.ts`.  Check that GL call count is in expected
    bounds (catches regressions where a draw silently no-ops).

27. ✅ 🟢 **`audio_placeholder` example** — even before Phase 14 ships
    audio, stub a sine-wave generator that writes to an AudioBuffer
    directly via JS.  Validates the binding shape.  ~60 LOC.

28. ✅ 🟢 **README "examples" gallery** — a markdown table with one
    line per example + a description of what it shows.

29. ☐ 🟢 **Move examples to `examples/raylib_ports/` + create a
    `examples/zimr/`** namespace for examples that show off
    ziggy idioms (method-style API, error unions, etc).

30. ☐ 🟢 **Convert any remaining `pub fn main()` examples to take
    explicit `gpa` + `io`** (preview of Phase 12.5/12.6 design).

31. ☐ 🟡 **Bench harness** — measure wasm size + GL call count + JS-
    side frame time across all examples.  Compare to a baseline
    snapshot.

32. ☐ 🟢 **Image regression tests** — render a known scene to a
    framebuffer in headless WebGL, hash the pixels, fail if hash
    drifts unexpectedly.

---

## Section 3: Documentation pass (steps 33–38)
*Make the project legible to outsiders.*

33. ✅ 🟢 **README.md** — currently project-internal.  Rewrite for an
    outsider: what is zimr, what does it run on, what's the value
    prop vs. raylib-emscripten or zig-gamedev's stack.

34. ✅ 🟡 **`docs/getting-started.md`** — step-by-step "your first
    zimr app" walkthrough.  Includes Bun setup, the host.html
    integration, and a 30-line basic example.

35. ✅ 🟡 **`docs/architecture.md`** — explain the three-layer
    structure (Zig → wasm → JS), the three import groups
    (`wasi_snapshot_preview1`, `dom`, `webgl`), the wasm_fwd.zig
    forwarder pattern, the host-test gate.

36. ☐ 🟢 **`docs/api-reference.md`** — auto-generated from doc
    comments.  Use Zig's `--emit-docs` if it's been wired up by
    0.16; otherwise hand-curated.

37. ✅ 🟡 **`docs/migration-from-raylib.md`** — for users coming
    from raylib-c.  Names that changed (`DrawRectangle` →
    `drawRectangle`), allocator-explicit changes, error-union
    replacements for return-zero-id-on-failure patterns, and the
    explicit non-coverage list (audio TBD, no file I/O, etc).

38. ✅ 🟢 **CHANGELOG.md** — start tracking versions.  Mark current
    state as `0.1.0-pre`.  Future steps update it.

---

## Section 4: Std.Io adoption (steps 39–48)
*The big design lever I deferred in Phase 12.5.  By now we'll know
enough to commit.*

User flagged uncertainty about "Frame is an Io".  Two paths:

- **Path A (conservative):** Frame and Io are separate; update fns
  take `f: *Frame, io: *Io, state: *S`.
- **Path B (clever):** Frame IS an Io with frame-pinned semantics.

39. ✅ 🟡 **Decision spike** — write both signatures in 5 example
    update fns.  Pick the one that reads better at the call site.
    This is the call I deferred; need to make it now.

40. ✅ 🟡 **`src/io.zig` skeleton** — `BrowserIo` struct + vtable
    binding to std.Io.VTable.  Stubs for every slot
    (concurrent/futex/fs return Unsupported errors; sleep/time/
    random work).  ~150 LOC.

41. ✅ 🟡 **Wire `now()` and `sleep()`** through the Io vtable.
    `frame.now()` returns frame-start (deterministic per tick if
    Path B).

42. ✅ 🟡 **Wire `random()` and `randomSecure()`** through the Io
    vtable.  Backed by `crypto.getRandomValues`.  Move our
    xorshift32 to `MockIo` for deterministic test paths.

43. ✅ 🟡 **Wire `fs.dirOpenDir/Stat`** to fetch.  Read-only
    filesystem semantics — open a "file" from a URL.  ~120 LOC.

44. ✅ 🟢 **`MockIo` for tests** — deterministic time advances by
    `mock.advance(seconds)`, deterministic RNG seed, in-memory
    "fetched" assets keyed by URL.  ~150 LOC.

45. ✅ 🟢 **`LoggingIo` wrapper** — wraps any Io and logs every call.
    Useful for debugging.  ~80 LOC.

46. ✅ 🟡 **Migrate `input.zig`** to consume `*Io` instead of static
    state where appropriate.  Minimal — most input is already
    snapshot-based via the Frame.

47. ✅ 🟡 **Migrate `fetch.zig`** to consume `*Io`.  Our two-phase
    `start(url) → poll(handle)` API is fundamentally Io.Evented-
    shaped — wire it through the std.Io vtable.

48. ✅ 🟡 **Migrate one example end-to-end** to the new
    Io-aware `update(f: *Frame, state: *S)` signature.  Verify wasm
    size delta is acceptable.  Then fan out (step 60).

---

## Section 5: Allocator-explicit pass (steps 49–55)

49. ☐ 🟡 **App entry redesign** — `z.init(.{ .gpa, .io, .window })`.
    Module-level state goes away; user explicitly creates an
    `*AppState` from `init.gpa`.  ~150 LOC change in `zimr.zig`.

50. ☐ 🟡 **All `loadXxx` fns take `Allocator` explicitly.**
    Currently most do; audit + fix any that still use a global
    libc-shaped malloc.

51. ☐ 🟢 **`Image`/`Texture`/`Mesh` `init` constructors take
    Allocator.**  Method-style: `try Image.init(gpa, w, h, fmt)`.
    Currently we have free-fn `genImage*` that uses libc.

52. ☐ 🟡 **Switch internal `libc.malloc` → `Allocator`** where the
    caller naturally has one.  Stays libc-shaped for raylib-style
    `[*c]` returned-pointer APIs that the user frees with our
    `unloadXxx` fns.  Document the boundary.

53. ☐ 🟢 **Update PHASE_12_PLAN.md** to mark 12.5 / 12.6 ✅ done
    once steps 39-49 land.

54. ☐ 🟢 **Validate every example builds with explicit
    allocator passing** — kill any remaining global state in
    examples.

55. ☐ 🟡 **Audit final API for "what does this fn need?"** — pure
    fns take only data, allocator-needing fns take Allocator,
    nondeterministic fns take *Io.  Function signatures = audit
    trail (the rule from std.Io philosophy).

---

## Section 6: First dep adoption — TrueType + atlas (steps 56–63)
*This is where we start consuming pure-Zig deps in earnest.*

56. ☐ 🟡 **`b.dependency` infrastructure in build.zig.zon** — wire
    the pinned-commit pattern for one dep first to validate the
    build setup.  ~30 LOC change.

57. ☐ 🟡 **Add `andrewrk/TrueType` as a dep** — pin a commit hash.
    Verify it builds for `wasm32-wasi` target.  Probably needs
    minor patches; plan to upstream them.

58. ☐ 🟡 **`src/truetype.zig` shim** — re-export the surface zimr
    uses (`load`, `scaleForPixelHeight`, `codepointGlyphIndex`,
    `glyphBitmap`, `glyphAdvance`, `getKerning`).  ~80 LOC.

59. ☐ 🟡 **Add `bgourlie/zrectpack` as a dep** — for atlas baking.
    `src/rectpack.zig` shim.  ~40 LOC.

60. ☐ 🔴 [L] **`loadFontEx(gpa, ttf_bytes, base_size, codepoints)`**
    — the keystone integration: parse TTF → rasterize glyph atlas
    → pack rects → upload as Texture2D → return Font with glyph
    metrics.  ~300 LOC.

61. ☐ 🟡 **`loadFontFromMemory(gpa, ext, bytes, size, cps)`** —
    convenience wrapper that picks the parser based on extension
    (".ttf", ".otf").  ~50 LOC.

62. ☐ 🟢 **TTF font example** — load Inter or Roboto, render
    "Hello, world" with kerning.  ~80 LOC.

63. ☐ 🟢 **Update `font_default.zig` to optionally use TTF path**
    — if user passes `null` for ttf_bytes, fall back to embedded
    raster default.  Backward-compat preserved.

---

## Section 7: zigimg — multi-format images (steps 64–70)

64. ☐ 🟡 **Spike: zigimg as `b.dependency`** — verify wasm32-wasi
    build.  zigimg uses `std.fs` heavily; we need its from-memory
    path.  Audit.

65. ☐ 🟡 **`src/imgimg.zig` shim** — re-exports `Image.fromMemory`
    + per-format detection.  Returns zimr's `types.Image` shape so
    no change to texture upload path.  ~120 LOC.

66. ☐ 🟢 **`loadImageFromMemory` enhanced** — detect format from
    magic bytes; route PNG to our `src/png.zig`, others to zigimg.
    ~30 LOC additions.

67. ☐ 🟢 **JPEG/BMP/TGA/QOI examples** — single example with a
    grid showing the same image loaded from each format.  ~80
    LOC.

68. ☐ 🟢 **Decision: replace `src/png.zig` with zigimg's PNG?**
    Bench wasm size delta.  If zigimg's PNG decode is comparable
    in size and faster, fold our png.zig into a thin shim.  If
    zigimg balloons size by 30%+, keep our png.zig as the
    happy-path PNG loader.

69. ☐ 🟡 **`exportImage(.PNG)` via zigimg's encoder** — one-line
    wrapper, validates the encode side too.  ~40 LOC.

70. ☐ 🟢 **GIF support documentation** — note in README that
    multi-frame animated GIFs are now supported.

---

## Section 8: glTF + 3D model loading (steps 71–80)
*The big one for 3D content.*

71. ☐ 🟡 **Spike: zgltf for wasm32-wasi** — verify it builds and
    can parse a small embedded `.glb`.  License check (MIT).

72. ☐ 🟡 **`src/gltf.zig` shim** — wraps zgltf with our naming.
    `loadModel(gpa, glb_bytes) !Model`.  ~150 LOC.

73. ☐ 🔴 [L] **glTF mesh → zimr Mesh conversion** — read positions /
    normals / texcoords / indices, build a `Mesh`, upload via our
    `uploadMesh`.  Handle multiple primitives → multiple meshes.
    ~250 LOC.

74. ☐ 🟡 **glTF material → zimr Material** — read PBR base color,
    metallic/roughness texture, normal map.  Map to our 12-slot
    `material.maps[]`.  ~150 LOC.

75. ☐ 🟡 **glTF embedded textures** — handle base64-encoded image
    data in glTF + external URI references.  Pipes through
    zigimg (step 65).  ~100 LOC.

76. ☐ 🔴 [L] **glTF skinning** — parse skin + joints; populate the
    `Mesh.boneIndices`/`boneWeights`.  Wire into vertex shader.
    Foundation for animation.  ~250 LOC.

77. ☐ 🔴 [L] **glTF animations** — parse the `animations` array;
    read keyframe samplers; sample at current time; update bone
    matrices.  ~300 LOC.

78. ☐ 🟡 **Animated model example** — load a rigged character
    (e.g., the GLTF "RiggedFigure" sample), play its idle
    animation.  ~120 LOC.

79. ☐ 🟢 **GLB-from-fetch loader** — async path: fetch the .glb,
    decode to Model.  Pipe into our two-phase fetch.  ~80 LOC.

80. ☐ 🟢 **glTF coverage docs** — what zimr supports, what doesn't
    (morph targets? PBR extensions?).  Useful for users.

---

## Section 9: Audio via Web Audio API (steps 81–88)
*Phase 9 finally.  ~200 LOC of WebAudio bindings, NOT miniaudio.*

User flagged the no-C goal, so miniaudio-based deps are out.  Web
Audio is the right answer for browser; we get mixing/panning/
filters/format-decoding for free.

81. ☐ 🟡 **`src/web/audio.js` runtime** — AudioContext lifecycle,
    `js_audio_create_buffer`, `js_audio_play`, `js_audio_stop`,
    `js_audio_set_volume`, etc.  ~150 LOC of JS.

82. ☐ 🟡 **`src/audio.zig` Zig surface** — `Sound` and `Music`
    types, `loadSoundFromMemory(gpa, bytes) !Sound`, `play(snd,
    .{...})`.  ~200 LOC.

83. ☐ 🟢 **Use browser's `decodeAudioData`** — handles WAV/MP3/OGG
    automatically.  Our Sound type just wraps a JS-side AudioBuffer
    handle.

84. ☐ 🟡 **Pure-Zig WAV decoder fallback** — adopt
    `veloscillator/zig-wav` for cases where embedded raw bytes
    need to skip the JS decode path.  ~60 LOC shim.

85. ☐ 🟡 **Pure-Zig MP3 decoder spike** — try `coolirisme/zig-mp3`.
    User flagged it as "reportedly slow" — measure on a 3 MB MP3,
    decide if it's usable.  If not, document that MP3 only works
    via the browser's `decodeAudioData` path.

86. ☐ 🟢 **Audio example** — play a short WAV on key press, fade
    music in/out, panning.  Demonstrates the surface.  ~80 LOC.

87. ☐ 🟢 **AudioContext autoplay-policy handling** — browsers
    block AudioContext until user gesture.  Defer init until first
    keyboard/mouse event; document for users.  ~30 LOC.

88. ☐ 🟢 **`isSoundPlaying` + `getSoundsPlaying`** — query API for
    games that need to know.  ~40 LOC.

---

## Section 10: Perlin noise + procedural texture (steps 89–92)

89. ☐ 🟢 **Adopt `mgord9518/perlin-zig`** as a dep.  ~30 LOC zon
    update.

90. ☐ 🟢 **`src/perlin.zig` shim** — re-exports `noise2D`/`noise3D`
    matching raylib's interface.  ~40 LOC.

91. ☐ 🟢 **`genImagePerlinNoise(w, h, ox, oy, scale)`** — was
    stubbed before; now wires to perlin.  ~30 LOC.

92. ☐ 🟢 **`genImageFractalNoise` / `genImageWhiteNoise` / 
    `genImageCellular`** — fill in the procedural-texture family.
    ~120 LOC.

---

## Section 11: Hardening + first release (steps 93–100)

93. ☐ 🟡 **WebGL context loss handling** — listen for `webglcontext-
    lost` event, gracefully restart.  Currently we crash.  ~80 LOC
    of dom.js + Zig.

94. ☐ 🟡 **Mobile / touch input** — basic touch event → mouse event
    bridging so existing examples work on phones.  ~120 LOC of
    dom.js + Zig.

95. ☐ 🟢 **Window resize handling** — `getRenderWidth`/`Height`
    auto-update on canvas resize.  Mostly there; verify.

96. ☐ 🟡 **Performance pass** — profile typical frame.  Likely
    hotspots: texture upload conversion, font rendering, immediate-
    mode shape batching.  Optimize the top three.  ~100 LOC.

97. ☐ 🟢 **Wasm size budget** — set per-example targets in build.zig
    that fail CI if exceeded.  Forces vigilance on dep adoption.

98. ☐ 🟡 **CI on GitHub Actions** — runs `zig build test`,
    `zig build smoke-test`, wasm size check.  On every PR.  ~60
    LOC of YAML.

99. ☐ 🟢 **`v0.1.0` release** — tag, write release notes covering:
    65% → 95% raylib API coverage, std.Io adoption, TTF support,
    glTF model loading, Web Audio.

100. ☐ 🟢 **Project announcement** — Ziggit thread, /r/Zig post.
     Frame as "raylib-shaped 2D/3D engine for browsers, written
     entirely in Zig including all dependencies."

---

## Section 12: post-v0.1 vista (steps 101+)

Beyond the 100, here's the longer-term horizon — not numbered, no
commitment:

- **Move from WebGL2 → WebGPU.**  Modern API, compute shaders,
  bindings via `mach-gpu` or hand-rolled.  Larger project.
- **Native target.**  zimr currently targets wasm32-wasi only.
  A `target=x86_64-linux-gnu` build with GLFW + OpenGL3.3 would
  validate cross-platform claims and double our addressable user
  base.
- **Mobile native.**  Android via `zigbuild --target=aarch64-linux-
  android`.  iOS via Swift bridging.
- **Editor + scene graph.**  Beyond raylib's flat immediate-mode
  surface — entities, components, transforms.  Big design space.
- **Networking primitives.**  WebRTC and WebSocket wrappers.
- **Physics.**  No good pure-Zig option as of 2026.  Either wait
  for one or write minimal AABB + ray vs. mesh collision.
- **Upstream contributions.**  Once `BrowserIo` is solid, pitch it
  to stdlib as the planned `Io.Wasm`.  Once the parametric mesh
  generators are battle-tested, extract as a package.

---

## Working principles for this roadmap

1. **No step left half-done.**  Each step ends with green tests
   (`zig build test --summary all` shows all passing) and green
   smoke (`zig build smoke-test` shows 8/8 or more).  If a step
   exposes a regression elsewhere, fixing it is part of the step.

2. **Docs-as-you-go, not at the end.**  Steps in section 3 are a
   marker, not a deferral.  Every public-API addition gets a doc
   comment that explains *why* not just *what*.

3. **Ship over polish.**  v0.1 is "useful and honest" not "perfect."
   It's OK to ship features with TODOs in the code as long as
   they're documented in CHANGELOG.

4. **Dep adoption is a tactical decision.**  Each adopted dep gets:
   a) license verified compatible with zlib (raylib-style),
   b) wasm32-wasi build verified,
   c) thin wrapper in `src/<name>.zig` so we can swap implementations,
   d) entry in DEPENDENCIES_PLAN.md.

5. **No globals.  Effects threaded explicitly.**  Every fn that
   allocates takes `Allocator`.  Every fn that needs time, randomness,
   loading, or logging takes the corresponding effect handle (`Clock`,
   `Rng`, `Loader`, `Logger`) — see `docs/effects-design.md`.  Smaller
   functions take exactly what they need; bigger ones take `*Frame`.
   This is what makes zimr feel Zig-shaped instead of
   raylib-with-Zig-syntax.

6. **The 100-step number is aspirational, not contractual.**  Some
   steps will turn out to be 2 sessions; some will collapse to 30
   minutes.  We re-evaluate the order at each session boundary
   based on what's actually fun and useful that day.

7. **Reread the style guide often.**  See
   [`docs/style-guide.md`](docs/style-guide.md).  Mandatory for new
   and modified code.  Existing code that doesn't match is
   grandfathered until touched — when you edit a function, bring the
   whole function up to spec.

---

## Risk register

| Risk | Mitigation |
|---|---|
| zigimg balloons wasm size beyond budget | Keep `src/png.zig` as alternative, only enable zigimg formats if user opts in. |
| TTF rasterization quality is poor | Adopt zrectpack atlas baking + oversampling; if still poor, use distance fields. |
| zgltf doesn't support a feature we need | Fork to a `zimr-third-party` org, patch, target upstream PR. |
| std.Io adoption breaks every example | Migrate one example end-to-end first (step 48); fan out only after that's clean. |
| Web Audio AudioContext timing differs from desktop | Document the autoplay-policy; provide a "tap to start" overlay in examples. |
| Pure-Zig MP3 decoder is too slow | Document that runtime MP3 goes through browser's decodeAudioData; pure-Zig path is for embedded clips only. |
| Mobile touch input has subtle interaction issues with input.zig's keyboard model | Add an Input mode parameter; document the differences. |

---

## Re-evaluation checkpoint

After step 50 (allocator pass complete), step 80 (glTF working), and
step 100 (release), pause and re-evaluate:
- Is the project still fun to work on?
- Are users adopting it?  (Track issues, stars, ziggit traffic.)
- Has the Zig stdlib's wasm Io landed?  Refactor accordingly.
- Are there pure-Zig deps we missed during the original survey?
  Re-survey.

The roadmap is a tool, not a contract.  If the order should change,
change it — but write down *why* in ZIGGIFY_NOTES.md so future-us
remembers.

---

End of roadmap.  Step 1 (`getKeyName`) is recommended starting point —
30 LOC, builds momentum, and means the keyboard demo can show key
names in its overlay.
