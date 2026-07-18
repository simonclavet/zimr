# 20-step plan — closing the raylib coverage gaps

Builds on `docs/raylib-coverage-gaps.md`'s analysis.  Goal: lift
in-scope raylib coverage from **74.6% → ~92%**, example portage from
**10% → ~30%**, while keeping every step shippable on its own.

Pairing rule: each "feature port" step lands the smallest reasonable
slice of new API and is followed (sometimes in the same step) by an
example that exercises it.  No feature lands without a user-visible
demonstration that proves it works end-to-end.

This plan picks up *after* the existing `docs/next-10-turns.md` arc
finishes (which lands tier-A examples + drops `src/png.zig` + adds
`text_input`).  The 20 steps below assume that arc has shipped.

## Numbers we're targeting

| Metric | Now | After 20 steps | Delta |
| ------ | --: | -------------: | ----: |
| In-scope raylib coverage | 581/779 (74.6%) | ~720/779 (~92%) | +139 fns |
| Examples shipped | 15 | ~35 | +20 |
| Modules at 100% | raymath, shapes, splines, collisions, rcamera | + textures, text, models, rlgl-MRT, audio | +5 |
| ziggified functions | 57 | ~75 | +18 |

Audio gets us a flat +65 functions.  Camera2D + texture API +
billboards + animation get us another ~40.  glTF unlocks real assets.

## Theme 1 — finish 2D (steps 1-3)

### Step 1 — Camera2D + `camera2d` example

**Ports:** `camera.beginMode2D`, `endMode2D`, `getScreenToWorld2D`,
`getWorldToScreen2D`.  Plus the `Camera2D` struct itself in
`types.zig` if not already present.

**Example:** `camera2d` — pan with mouse drag, zoom with scroll
wheel, screen↔world conversion.  World layout is a tile grid so
the pan/zoom is visually obvious.

**Effort:** ~120 LOC engine + ~150 LOC example. 1 turn.

**Exit gate:** 1 new example, ~16/16 smoke green; +4 fns ported.

### Step 2 — texture API completion

**Ports:** `loadTextureFromImage(gpa, image)`,
`updateTexture(tex, pixels)`, `updateTextureRec(tex, rec, pixels)`,
`genTextureMipmaps(*tex)`, `loadRenderTexture(w, h)` (+ unload pair).

These are convenience wrappers around existing `rlgl_gpu` calls
plus one new WebGL bridge for `gl.texSubImage2D` (in `web/gl.zig`).

**Example:** none — these are infrastructure; the next step
exercises them.

**Effort:** ~200 LOC engine. 1 turn.

**Exit gate:** +5 fns ported, examples unchanged (smoke 16/16).

### Step 3 — refactor `rtt.zig` + `shader.zig` + add `image_editor` example

**Refactor:** `rtt.zig` and `shader.zig` currently build their FBOs
manually with `rlLoadFramebuffer` + `rlFramebufferAttach`.  Replace
with the new `loadRenderTexture` wrapper.  Net loss of ~30 LOC of
boilerplate per example.

**Example:** `image_editor` — interactive resize/crop/rotate/blur
on a loaded image.  Uses `loadTextureFromImage` (image manipulation
on CPU side) + `updateTexture` (push the modified bytes back to GPU
without reallocating the texture).

**Effort:** ~250 LOC example. 1 turn.

**Exit gate:** +1 example (now 17), 17/17 smoke green.

## Theme 2 — image generation + text completeness (steps 4-5)

### Step 4 — Perlin + cellular noise + `procgen_noise` example

**Ports:** `genImagePerlinNoise(gpa, w, h, ox, oy, scale)`,
`genImageCellular(gpa, w, h, tile_size)`.  Either port `stb_perlin.h`
to Zig (~150 LOC) or use a small pure-Zig noise library.  Cellular
is a Voronoi distance field; ~80 LOC.

**Example:** `procgen_noise` — three side-by-side panels showing
white noise (already have), Perlin, and cellular.  Slider widget
to adjust scale.

**Effort:** ~250 LOC engine + ~200 LOC example. 1 turn.

**Exit gate:** +2 fns, +1 example (now 18), 18/18 smoke green.

### Step 5 — `genImageText` + `loadFontFromMemory` alias + `text_on_texture` example

**Ports:** `genImageText(gpa, w, h, text, color)` — render a string
to a CPU `Image` using the current default font.  Leverages the
existing TTF baker; just emits to a Image buffer instead of a GPU
texture.  Plus a one-line alias `loadFontFromMemory =
loadFontFromTtfData` for raylib name parity.

**Example:** `text_on_texture` — draw a string into a CPU image,
upload as texture, paste it on a 3D plane that rotates.  Common
pattern for in-world signs, decals, name tags.

**Effort:** ~120 LOC engine + ~150 LOC example. 1 turn.

**Exit gate:** +2 fns, +1 example (now 19), 19/19 smoke green.

## Theme 3 — 3D static draw completion (steps 6-9)

### Step 6 — `drawModelWires` + wireframe toggle in `models3d`

**Ports:** `drawModelWires(model, pos, scale, tint)`,
`drawModelWiresEx(model, pos, axis, angle, scale, tint)`.  Same
draw call as `drawModel` but with `gl.drawArrays(LINES, ...)` /
`gl.drawElements(LINES, ...)` instead of `TRIANGLES`.

**Example tweak:** add a TAB-key toggle to existing `models3d`
that flips between filled and wireframe.  No new example file.

**Effort:** ~80 LOC engine. 1 turn.

**Exit gate:** +2 fns, examples unchanged (still 19), 19/19 smoke green.

### Step 7 — billboards + `billboard_particles` example

**Ports:** `drawBillboard(camera, tex, pos, size, tint)`,
`drawBillboardRec(camera, tex, source, pos, size, tint)`,
`drawBillboardPro(...)`.  Quad always faces the camera —
construct the model matrix from camera up + camera-to-pos vectors.
Used heavily for 3D particles, vegetation, distant detail.

**Example:** `billboard_particles` — 500 sprite particles in 3D
space, each a billboard that rotates to face the camera.  Reuses
`particles.zig`'s ring-buffer pattern.

**Effort:** ~120 LOC engine + ~200 LOC example. 1 turn.

**Exit gate:** +3 fns, +1 example (now 20), 20/20 smoke green.

### Step 8 — instanced rendering + `instanced_forest` example

**Ports:** `drawMeshInstanced(mesh, material, transforms, count)`.
WebGL2 has `drawElementsInstanced` and `vertexAttribDivisor`; the
glue is straightforward but needs a per-instance buffer that gets
updated each frame (or stays static for fixed scenes).

**Example:** `instanced_forest` — 10 000 trees on a heightmap.
One mesh, 10 000 model matrices, one draw call.  Compare visibly to
"how slow this would be without instancing" via a CONFIG flag in
the example.

**Effort:** ~150 LOC engine (incl. the WebGL2 instanced bridge in
`web/gl.zig`) + ~250 LOC example.  1 turn — possibly 1.5 if the
WebGL2 instancing bridge takes longer than expected.

**Exit gate:** +1 fn, +1 example (now 21), 21/21 smoke green.

### Step 9 — cubemap + `skybox` example

**Ports:** `loadTextureCubemap(gpa, image, layout)` — 6-face
cubemap from a single image.  Takes a layout enum (line, cross,
3x4, 4x3, panorama).  Plus the `rlgl` bridge:
`rlSetTextureCubemap` (currently only 2D textures wired).

**Example:** `skybox` — cubemap-textured background with proper
perspective.  A simple cube mesh rendered "inside out" with depth
write disabled.

**Effort:** ~180 LOC engine (cubemap loader + GL_TEXTURE_CUBE_MAP
plumbing in `web/gl.zig`) + ~180 LOC example.  1 turn.

**Exit gate:** +2 fns, +1 example (now 22), 22/22 smoke green.

## Theme 4 — 3D animation (steps 10-12)

### Step 10 — `updateModelAnimation` + manual skinned cube test

**Ports:** `updateModelAnimation(model, anim, frame)` — the bone
skinning matrix update.  Bigger lift: needs to walk the bone
hierarchy, multiply local→world transforms, push to a shader
uniform array of matrices, do CPU-side vertex blend if no skinning
shader is bound.  ~250 LOC.

**Example:** small built-in test — a 2-bone "snake" mesh hand-
constructed in code, with a 30-frame keyframed animation.  Proves
the animation playback works without needing a real model file.

**Effort:** ~250 LOC engine + ~200 LOC test example. 1.5 turns.

**Exit gate:** +1 fn, +1 example (now 23), 23/23 smoke green.

### Step 11 — `genMeshTangents` + normal-mapping example

**Ports:** `genMeshTangents(*mesh)` — compute tangent vectors per
vertex from position + normal + UV.  Pure CPU, ~60 LOC.  Required
for any normal-mapped lighting model.

**Example:** `normal_mapping` — a textured cube with both diffuse
and normal maps, lit by a single point light.  Custom fragment
shader that reads the tangent-space normal map.

**Effort:** ~60 LOC engine + ~250 LOC example (a fair chunk is the
shader). 1 turn.

**Exit gate:** +1 fn, +1 example (now 24), 24/24 smoke green.

### Step 12 — animation polish + `dual_animation` example

**Ports:** `updateModelAnimationEx(model, animA, frameA, animB,
frameB, blend)` — interpolate between two animations.  Useful for
walk-to-run blends, idle-to-action transitions.

**Example:** `dual_animation` — same 2-bone snake from step 10,
but blends between "wave left" and "wave right" via a slider.

**Effort:** ~80 LOC engine + ~150 LOC example. 1 turn.

**Exit gate:** +1 fn, +1 example (now 25), 25/25 smoke green.

## Theme 5 — glTF (steps 13-15)

This theme adds the first real model-format dependency.  Two
candidates:

- **zgltf** (https://github.com/kooparse/zgltf) — pure Zig,
  active.  Probably the right choice
- **cgltf** — C, header-only, would need Zig FFI

Going with zgltf for the same reason we picked zigimg over
stb_image: pure Zig, no C link, easier to vendor.

### Step 13 — vendor zgltf, basic load to internal type

**Adds:** `src/zgltf/` (vendored).  Wraps `zgltf.parseGlb(bytes)` →
returns a `gltf.Model` with mesh primitives, materials, textures.

No raylib-name port yet — this step is just "library compiles, can
parse a known-good .glb without crashing."

**Test:** unit test loading a tiny embedded .glb (a single
triangle) and inspecting the primitive count.

**Effort:** ~300 LOC wrapper + vendor.  1 turn.

**Exit gate:** smoke 25/25, host count +5 from new tests.

### Step 14 — `loadModel` (glTF path) + `gltf_static_mesh` example

**Ports:** `loadModel(gpa, bytes)` — wraps the zgltf parse + builds
zimr `Mesh` + `Model`.  Initially supports only static (non-skinned,
non-animated) glTF.  Texture loading via the existing
`loadTextureFromMemory` hooked to glTF's image data section.

**Example:** `gltf_static_mesh` — load a small embedded .glb of a
chair or other static prop, render with `drawModel`, orbit camera.
Good demo of the new format.

**Effort:** ~250 LOC engine + ~150 LOC example. 1.5 turns.

**Exit gate:** +1 fn, +1 example (now 26), 26/26 smoke green.

### Step 15 — glTF skinning + `animated_character` example

**Ports:** glTF skin + animation parsing in the load path.  Hands
off to `updateModelAnimation` from step 10 for playback.  Plus
`loadModelAnimations(gpa, bytes)` for parsing the animation
section out of glTF.

**Example:** `animated_character` — an animated .glb of a walking
character (public-domain CC0 model, ~200 KB embedded).

**Effort:** ~300 LOC engine + ~200 LOC example. 2 turns.

**Exit gate:** +2 fns, +1 example (now 27), 27/27 smoke green.

## Theme 6 — input expansion (steps 16-17)

### Step 16 — touch input + `touch_painter` example

**Ports:** `getTouchPosition(idx)`, `getTouchPointId(idx)`,
`getTouchPointCount()`, `getTouchX()`, `getTouchY()`.  Add
`web/dom.zig` event listeners for `touchstart` / `touchmove` /
`touchend` / `touchcancel`.  Maintain a small ring buffer of active
touches (max 10).

**Example:** `touch_painter` — drag-to-paint with finger; multiple
fingers paint in distinct colors.  Works on mobile + on desktop
fallback (touchscreen or pen tablet).

**Effort:** ~150 LOC engine + ~180 LOC example. 1 turn.

**Exit gate:** +5 fns, +1 example (now 28), 28/28 smoke green.

### Step 17 — gestures + `pinch_zoom_demo` example

**Ports:** raylib's gesture system: `getGestureDetected()`,
`getTouchPointCount` (already from step 16), `getGesturePinchVector`,
`getGestureDragVector`, `setGesturesEnabled`.  Builds on the touch
ring buffer from step 16; adds gesture detection state machine
(tap / hold / drag / pinch / rotate).  ~250 LOC.

**Example:** `pinch_zoom_demo` — image viewer with pinch-to-zoom
and drag-to-pan.  Uses Camera2D from step 1 to do the pan/zoom
math.

**Effort:** ~250 LOC engine + ~200 LOC example. 1.5 turns.

**Exit gate:** +5-8 fns, +1 example (now 29), 29/29 smoke green.

## Theme 7 — audio (steps 18-19)

The whole audio module is 65 functions — that won't fit in two
steps.  Land the most useful 50% of the surface and call the rest
deferred for a post-plan turn.

### Step 18 — audio device + sound effects + `soundboard` example

**Ports:** `initAudioDevice()`, `closeAudioDevice()`,
`isAudioDeviceReady()`, `setMasterVolume(vol)`,
`getMasterVolume()`.  Plus the Sound API: `loadSoundFromMemory`
(WAV/OGG bytes), `unloadSound`, `playSound`, `stopSound`,
`pauseSound`, `resumeSound`, `setSoundVolume`, `setSoundPitch`,
`setSoundPan`.

Backend: Web Audio API.  AudioContext = device; AudioBuffer per
loaded sound; AudioBufferSourceNode per `playSound` invocation.
WAV/OGG decoding via `AudioContext.decodeAudioData` (browser
handles the codec for us).

**Example:** `soundboard` — 9-button grid; each button plays a
different sound effect on click.  Includes a master volume slider.

**Effort:** ~400 LOC engine (Web Audio bridge in new
`web/audio.zig` + zimr-side API in new `audio.zig`) + ~200 LOC
example.  1.5-2 turns.

**Exit gate:** +14 fns, +1 example (now 30), 30/30 smoke green.

### Step 19 — music streaming + `music_player` example

**Ports:** Music API: `loadMusicStreamFromMemory`, `unloadMusicStream`,
`playMusicStream`, `pauseMusicStream`, `stopMusicStream`,
`updateMusicStream`, `setMusicVolume`, `setMusicPitch`,
`setMusicPan`, `getMusicTimeLength`, `getMusicTimePlayed`,
`isMusicStreamPlaying`, `seekMusicStream`.  Streaming differs from
Sound in that it doesn't load the whole file into a buffer — uses
Web Audio's `decodeAudioData` for the whole thing on load (browsers
handle streaming internally) but exposes the play-position API.

**Example:** `music_player` — embedded ~30-second OGG track with
play/pause/stop buttons, scrub bar, volume slider.

**Effort:** ~250 LOC engine + ~200 LOC example. 1.5 turns.

**Exit gate:** +13 fns, +1 example (now 31), 31/31 smoke green.

## Theme 8 — capstone (step 20)

### Step 20 — coverage checkpoint + final examples + roadmap update

**Activities:**
- Re-run `docs/cheatsheet-generator.py` — capture final coverage
  numbers
- Add 2-3 small "showcase" examples that combine features landed
  across the 20 steps:
  - `mini_game` — uses Camera2D + sounds + sprites + input
  - `tech_demo` — uses 3D + glTF + skinning + lights + skybox + music
- Update `STATUS.md` with final state
- Write the next-arc plan (post-coverage focus likely: WebGPU
  backend, perf work, doc generator, package distribution)
- Final ZIGGIFY notes session

**Effort:** 1 turn.

**Exit gate:** all green, ~32-34 examples, ~92% raylib coverage.

## Out of scope for these 20 steps

- **WebGPU backend** — would unlock compute shaders + storage
  buffers (43 missing rlgl functions).  Architecturally a separate
  rendering layer; saving for a post-coverage arc.
- **VR stereo rendering** — requires WebXR; niche.
- **Window/file system / clipboard / monitor APIs** — wasm-irrelevant
  (~110 raylib functions we'll never port).
- **`AudioStream` (procedural audio)** — the 19 functions for raw
  buffer streaming.  Useful for synths but skipping in the audio
  arc; can land later.
- **MagicaVoxel `.vox` / `.m3d` / `.obj` model formats** — niche;
  glTF covers 95% of real use cases.
- **Image animation (GIF)** — the multi-frame return type is a
  design question we don't need to answer for any current example.
  Defer.

## Cadence + risk notes

- **Steps with new dependencies (13, 18) carry the most risk.**
  zgltf and Web Audio backends are both well-trodden but the wiring
  is novel for us.  Build in a half-turn buffer for each.
- **The audio arc (steps 18-19) is ~3-4 turns of effort** even
  though I've squeezed it into 2.  If they go long, push step 20
  to a step 21 — better to land good audio than rush it.
- **Steps 6, 9, 11 are good candidates to parallelize** if multiple
  contributors — the engine/example pairs are independent.
- **Don't ziggify mid-arc unless necessary.**  The next-10 plan
  has dedicated ziggification turns; this 20-step plan focuses on
  feature breadth.  If a missing-feature port surfaces a clear
  ziggification candidate, queue it for a post-arc turn rather
  than expanding scope mid-step.
- **Smoke counts will tick up steadily.**  By step 20: 15 → 32-34
  examples.  Build/test time per smoke run will roughly double;
  consider parallelizing the smoke harness if it crosses 60s
  wall-clock.

## Bookkeeping discipline (reminder)

Same as every previous arc:
- refresh `/mnt/user-data/outputs/zimr.zip` at start AND middle of
  every turn
- copy LICENSE + STATUS + CHANGELOG + ZIGGIFY_NOTES + docs/ +
  examples/ to /mnt/user-data/outputs at end
- update STATUS.md last-touched
- log a session entry in ZIGGIFY_NOTES.md
- update CHANGELOG.md for any API changes
- regenerate cheatsheet at every checkpoint (steps 5, 10, 15, 20)
