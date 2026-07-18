# zimr status

Tight, current-state snapshot.  See `docs/cleanup-and-roadmap.md`
for what's next, `ROADMAP.md` for the long-form 100-step plan,
`CHANGELOG.md` for what landed when.

**Last touched:** 20-step coverage plan, Steps 4-7 + 11
(May 2026), plus Frame/App argument refactor.

- **Step 4** — Perlin + cellular noise (`genImagePerlinNoise`,
  `genImageCellular` in textures.zig) + `procgen_noise` example.
- **Step 5** — `genImageText` (raylib-faithful debug helper) +
  `loadFontFromMemory` alias + `text_on_texture` example.
- **Step 6** — `drawModelWires` + `drawMeshWires` + `wireframe`
  example.  Immediate-mode line emission since WebGL2 has no
  `glPolygonMode`.
- **Step 7** — Billboards (`drawBillboard` / `drawBillboardRec` /
  `drawBillboardPro` in models.zig) + `billboards` example.
- **Step 11** — `genMeshTangents` (out-of-order — pure CPU, no
  example).  Required for future normal-mapped shading.

**Refactor:** `update(app, frame, state)` — three orthogonal
arguments.  Frame is the per-execution-context handle (5 fields:
scratch + 4 effects); App is the program singleton (allocator,
canvas, lifecycle).  Behavior-preserving — identical gl call
counts on every example.

Plan reference: `docs/20-step-coverage-plan.md`.

**Test status:** 483/483 host tests · 21/21 smoke tests · 21
example wasm builds green.

- **Step 1** — `camera2d` example added (Camera2D engine was
  already 100% ported).  Pan/zoom/world-coordinate demo.
- **Step 2** — texture API completed with 6 new high-level
  wrappers: `loadTextureFromImage`, `updateTexture`,
  `updateTextureRec`, `genTextureMipmaps`, `loadRenderTexture`,
  `unloadRenderTexture`.  Plus 6 new wasm_fwd forwarders.
- **Step 3** — `rtt.zig` and `shader.zig` refactored onto
  `loadRenderTexture` (state shrank from 3 GL handle fields to
  1 typed `RenderTexture2D`), `image_editor` example added
  showcasing image manipulation + live `updateTexture` re-upload.

Plan reference: `docs/20-step-coverage-plan.md`.

**Test status:** 483/483 host tests · 17/17 smoke tests · 17
example wasm builds green.  Identical gl call counts on every
pre-existing example after the refactors.

---

## Module-by-module — one line each

| Module | Status |
|---|---|
| `src/types.zig` | All 35 raylib structs ported as `extern struct`, with `deinit(gpa)` shortcuts on Mesh/Image/Shader/Material/Model. |
| `src/enums.zig` | Complete — all raylib enums ported. |
| `src/raymath.zig` | 100% — 146 functions, 45 tests. |
| `src/rlgl.zig` | Complete public API; state setters live in `rlgl_gpu`. |
| `src/rlgl_gpu.zig` | Complete — VAO, VBO, shader, texture, uniform, render-batch. |
| `src/colors.zig` | Tailwind palette helper — full palette. |
| `src/input.zig` | Complete — keyboard, mouse, touch, gamepad. Still snapshot-via-globals; effect-type wrap is future work. |
| `src/core.zig` | Timing + traceLog + window state.  Public API documented as **internal-only** post-effects-pivot — Browser impls of Clock/Rng/Logger call into here; user code goes through `f.clock` / `f.rng` / `f.log`. |
| `src/shapes.zig` | Complete — drawing, splines, collision predicates. |
| `src/textures.zig` | ~80% complete.  `genImage*` and `unloadImage` ziggified (Phase B).  Image transforms still libc.malloc — Phase E. |
| `src/text.zig` | Complete utilities + drawing.  Codepoints/UTF-8/font-data still C-style — Phase D. |
| `src/font_default.zig` | Complete — built-in font baked in. |
| `src/models.zig` | ~70% complete.  All `genMesh*` and Phase-C loaders ziggified.  GLTF/OBJ disk loaders deferred to dep adoption (zgltf, ROADMAP §8). |
| `src/camera.zig` | Complete; `updateCamera(camera, mode, clock)` takes explicit Clock post-effects-pivot. |
| `src/png.zig` | Complete hand-rolled decoder.  Will be replaced by zigimg in ROADMAP §7. |
| `src/wasm_fwd.zig` | Comptime-gated cross-module forwarder for wasm vs host. |
| `src/web/fetch.zig` | Async asset loading via JS fetch; wrapped by `Loader.Browser`. |
| `src/web/dom.zig` + `dom.js` | Canvas / input event capture / console bridge. |
| `src/zimr.zig` | Public surface — App / Frame / start / setLoader / setClock / setRng / setLogger.  Default singletons next to `active_app`. |
| `src/loader.zig` | `Loader` effect type — `loadFileData` / `pollFileData` / `unloadFileData` / `elapsedMs`.  Browser + Mock impls.  10 tests. |
| `src/clock.zig` | `Clock` effect type — `time` / `frameTime` / `fps` / `wallMs`.  Browser + Mock impls.  6 tests. |
| `src/rng.zig` | `Rng` effect type — `value` / `seed` / `float01` / `bytes` / `boolean`.  Browser + Seeded impls.  12 tests. |
| `src/logger.zig` | `Logger` effect type — `trace` / `debug` / `info` / `warn` / `err` / `fatal`.  Browser + Capture impls.  7 tests. |
| `src/_vendor/truetype/` | andrewrk/TrueType vendored, not yet wired.  Step 11-14 of cleanup-and-roadmap. |
| `src/_vendor/zg/` | atman/zg UTF-8 decoder vendored, wired into text.zig. |

---

## Examples — all 14 working, 14/14 smoke green

`audio_placeholder` · `basic` · `cube3d` · `first_person_camera` ·
`keys` · `life` · `load_image_demo` · `models3d` · `particles` ·
`png_demo` · `rtt` · `shader` · `shader_uniforms` · `text_layout`

---

## Build sizes — release wasm per example

Most examples ~30-90 KB after `-Drelease=true`.
`first_person_camera` is the largest at ~120 KB (rmodels +
camera + heightmap mesh generation).  No DCE blockers from the
extern-fn cleanup.

---

## Open items

- **Phase D + E of spring cleanup** — see
  `docs/cleanup-and-roadmap.md` turns 1-4.  After these the
  codebase is fully allocator-explicit.
- **TrueType wiring** — vendor present, not yet plumbed into
  `loadFontEx`.  See cleanup-and-roadmap turns 11-14.
- **zigimg + zgltf adoption** — ROADMAP §7 + §8.  Both deferred
  pending Phase D + E completion (mixing dep-adoption with
  cleanup tangles two debuggability problems).
- **Audio (ROADMAP §9)** — Web Audio API surface is unported.
  `audio_placeholder` example proves the GL frame loop survives a
  no-op audio init.
- **Multi-app demo** — design captured in
  `docs/multiapp-design.md`; first concrete demo is turn 9 of
  cleanup-and-roadmap.

---

## Toolchain

- **Zig:** 0.16.0 at `/opt/zig/zig`
- **Bun:** 1.3.13 (dev server, smoke runner, TS tooling)
- **Build:** `/opt/zig/zig build [test|smoke-test]`,
  release: `-Drelease=true`
- **No npm, no python, no emscripten.**
