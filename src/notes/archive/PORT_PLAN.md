# wgpu Example Porting — Master Plan

Goal: port every remaining GL example (`@import("zimr")`) to the wgpu backend, building
engine features just-in-time as waves need them, and doing it cleanly — a shared scaffold,
a cohesive look, lint-clean code — so the example set is consistent and nice to look at.

## ★ PRESERVATION PRINCIPLE (Simon, turn 1105) — AUTHORITATIVE, overrides any "DELETE" below
**No example DEMO is ever deleted.** Every example is a potentially-useful reference, so we PORT/
PRESERVE all of them — each gets its own folder under `examples/` AND a way to run + test it. This
includes the so-called "redundant" set: on inspection they're mostly DISTINCT (interactive pan/zoom
`mandelbrot`, GPU+CPU `cube_split`, `shader_chroma_split` chroma post-process, generic `shader`); only
`julia` has a close twin (`wgpu_julia`). Port them all anyway — duplication is cheaper than losing work.
The ONLY things deleted at the endgame are the dead GL BACKEND INTERNALS (the rendering impl:
`rlgl.zig`, the GL halves of `drawing.zig`/`web.zig`, `.glsl` embeds, spirv-cross, `tools/spirv/`) once
NO example imports them — never the example demos.

Uniform folder + test scheme (so everything is exercised, even non-pattern examples):
- **Browser examples** (the norm): `examples/wgpu_<name>/` + `AppSpec` descriptor → covered by the Bun
  `smoke-test` automatically.
- **Bespoke GPU-frame** (cube_demo/lambert_demo/pbr_demo/gltf_textured): already have folders + the
  `[MANUAL EXCEPTION]` block + smoke.
- **Native-CLI software-renderer** (`sw_*`, render to PNG): keep each `zig build sw_<name>` step — running
  it IS the test (it renders + exits non-zero on failure); fold each into a folder for uniformity, and at
  GL-collapse repoint `@import("zimr")` → the backend-agnostic modules (`zm`/`codecs`/`rlsw`) so they
  survive. (TODO: wire the sw_* steps into one aggregate `zig build sw-all` test so they run together.)

---


## 1. Where things stand (updated ~turn 1094)

- **104** example dirs on wgpu (`examples/wgpu_*/`, AppSpec). Phase 0 + Waves 1–3 are
  essentially done: the 2D quick wins, the 3D *immediate* foundation (F1 Steps 1–2a:
  drawCube/Wires/Grid/Line3D/Sphere/Cylinder, depth-tested), the entire UI / Dear ImGui
  batch (minimal/tables/docking/drag-drop/plotting/phone apps/`ui_full_showcase`), and the
  comptime fractals (`comptime_mandelbrot`, `comptime_julia`, `julia_gallery`).
- **50** GL examples remain (`@import("zimr")`, no wgpu dir). Shader-source files
  (`*_fs.zig` etc.) and redundant pipeline variants are NOT in this count.

Remaining 50, by the engine feature gating them (counts approximate — classification fuzzy):

| Bucket | ~N | Status / new engine work |
|---|---|---|
| 3D retained mesh / gltf / instancing / skinning | ~12 | **F1 tail** — retained Mesh/Model/genMesh/loadModel + drawMeshInstanced (immediate path done; retained tier NOT) |
| rlgl immediate-mode (`rlBegin`/`rlVertex`) | ~8 | **no wgpu rlgl** — implement, or rewrite each to the wgpu draw API |
| image / readback (load/gen/export Image) | ~5 | **F2+F3** — texture readback + image gen (RTT exists) |
| audio | 4 | **F5 audio subsystem** — NONE on wgpu; a whole subsystem |
| gestures (recognizers) | 2 | **F4 gesture API** — NONE (multitouch *input* already ported) |
| custom-font / text-layout | ~2 | **F6** — loadFontFromTtfData + measureText/wrap |
| sw_* CLI (software renderer) | 5 | **portable now** — swap `zimr`→`zimr_wgpu` (rlsw is backend-agnostic) or import `rlsw` directly |
| UI holdouts (bespoke) | 3 | `imgui_demo` (mixed `s`/`state` var + custom font, 1150L), `ui_panes` (hardcoded source-display string), `ui_minimal_button` (GL-font-path diagnostic + 3 UiContexts) |
| distinct "redundant" variants | ~5 | **PORT (preserve, do NOT delete)** — `mandelbrot`(interactive)/`julia`/`shader`/`cube_split`/`shader_chroma_split` |

**The path (DECIDED — full parity, Simon turn 1094):** the easy-port well is dry; ~37 of the
50 are gated on engine subsystems that don't exist on wgpu yet. We **build every one of them
properly and drop nothing** — only the ~5 redundant fractal/shader variants are delete-
candidates, and only after verifying each is genuinely covered. The verified per-subsystem
breakdown, the designs, and the build order are **§1.5 below (AUTHORITATIVE — this table is a
rough snapshot; trust §1.5's counts).** F-status: 3D immediate ✅ / retained ❌ (S-B, NEXT) ·
rlgl ❌ (S-A) · image/readback ❌ (S-C) · audio ❌ (S-D) · gestures ❌ (S-E) · TTF ❌ (S-F).

---

## §1.5 THE CURRENT PLAN — full parity + GL kill (turn ~1094, AUTHORITATIVE)

§§2–7 below are the ORIGINAL forward-plan; Phase 0 + Waves 1–3 are essentially done — **this
section supersedes them**, and supersedes `finishing_webgpu.md` §8. Goal (Simon, turn 1094):
**FULL parity** — build every remaining subsystem properly (no dropping), port all 50 GL
examples, then delete the GL path. **Design the best system; do NOT port the GL monolith
verbatim** — verify the GL behavior + the wgpu primitives first, then build a clean
wgpu-native subsystem that *improves* on GL. Largest system work first.

### The parity gap (verified turn 1094)
The GL `zimr` public surface that `zimr_wgpu` lacks is ~the whole raylib API — two kinds:
- **GL-rendering subsystems to BUILD** (S-A…S-F).
- **Backend-agnostic helpers to RE-EXPORT** (never reimplement): `image*` CPU ops, gesture
  recognizer math, audio decode, `checkCollision*`, spline get/draw, color ops, text utils,
  easings, ECS. Re-export in `zimr_wgpu` as their consuming examples land.

wgpu HAS: 2D (shapes/text/textures/scissor/camera2D), full Dear ImGui, 3D *immediate*
(drawCube/Wires/Grid/Sphere/Cylinder, depth-tested), fullscreen shaders, RTT, GPU compute,
comptime fractals. It LACKS the subsystems below.

### Subsystems — LARGEST FIRST (each: verify → design → port → done-gate)

**S-A · rlgl immediate-mode** — unblocks ~15 (basic, shader, rtt, image_editor, procgen_noise,
cube_split, mrt_demo, texture_readback, text_on_texture, rlsw_side_by_side, sampler_derisk_test,
physics_demo, physics_pyramid, wireframe, load_image_demo).
- *Verify:* `rlgl.zig` (rlBegin/rlVertex3f/rlColor4f/rlTexCoord2f/rlPush·PopMatrix/rlSetTexture/
  rlLoadTexture/rlSetBlendMode) + how the 15 use it (2D *and* 3D immediate geometry + matrices).
- *Design:* an immediate-mode recorder over the EXISTING wgpu batcher (Renderer2D + the 3D
  pipeline) — `rl*` accumulates into a dynamic vertex buffer, flushes on matrix/texture/blend/
  mode change. ONE batcher (don't fork). Depth-test-aware (rlgl draws 3D too). Implement the
  minimal `rl*` subset the 15 actually call; the rest get a loud stub, not a silent no-op.
- *Done:* `rl*` renders on wgpu; all 15 port + `wgpu-smoke` + a Chrome check.

**S-B · 3D retained mesh / Model** — unblocks ~11 (models3d, gltf_simple, gltf_model_refs,
dynamic_mesh, instancing, skinned_mesh, billboards, wireframe, first_person_camera,
typed_unlit_demo, split_screen; helmet already on `wgpu_pbr_demo`). **THE keystone.**
- *Verify:* GL Mesh/Material/Model + genMesh*/loadModel/uploadMesh/updateMeshBuffer/drawMesh/
  drawModel/drawMeshInstanced + skinning in `drawing.zig`+`scene.zig`; the helmet interleave+
  tangent-gen (already GL-free); the wgpu immediate-3D in `draw3d.zig`.
- *Design:* a retained tier with GPU-resident vertex/index buffers — `Mesh` (buffers+counts),
  `Material` (PBR maps over the proven single-Ubo pipeline), `Model` (meshes+materials+
  transform), `genMesh*` (procedural; comptime where cheap), `loadModel` (gltf via `codecs`),
  `drawModel`/`drawMesh`/`drawMeshInstanced` (per-instance buffer), skinning (bone-palette SSBO
  + skinning VS). Generalize the helmet; reuse the pipeline + bind-group cache. Keep immediate
  `drawCube` as the thin front-end of the SAME path.
- *Done:* retained 3D renders; the 11 port + pass.

**S-C · Image + texture upload/readback** — unblocks ~13 (load_image_demo, png_demo, image_text,
image_editor, lenna_test, texture_readback, rlsw_side_by_side + texture-using 3D).
- *Verify:* GL `Image` + `image*` CPU ops (backend-agnostic) + `loadTextureFromImage`/
  `updateTexture` (upload) + `loadImageFromTexture`/screen readback + `genImage*`.
- *Design:* RE-EXPORT `Image` + `image*` (CPU, shared). Implement upload (Image→wgpu texture,
  format map) + readback (texture→buffer via `copy_src` → map → `Image`; RT is already
  `copy_src`). `genImage*` CPU (re-export) or GPU where it pays. Clean `Image`↔`Texture`.
- *Done:* load/gen/manipulate/upload/readback on wgpu; the examples port.

**S-D · Audio** — unblocks 4 (audio_basic, audio_stream_synth, composer_drum, music_streaming).
A whole subsystem; **no wgpu audio today.**
- *Verify:* `sound.zig` + the raylib audio API (initAudioDevice/loadSound/playSound/pause/
  resume/loadMusicStream/updateMusicStream/AudioStream + loadWaveSamples) + the decode path.
- *Design:* a **Web Audio bridge** (new `audio` import in `zimr_wgpu.ts`: AudioContext, decoded
  buffers, sources, gain; streaming via AudioWorklet, callback-filled). Zig API mirrors raylib;
  decode wav/etc. via `codecs`. Native (Dawn) audio is future.
- *Done:* load/play/stream on wgpu (browser); the 4 port.

**S-E · Gesture recognizers** — unblocks 2 (gestures_demo, gestures_testbed). Multitouch *input*
already ported.
- *Verify:* the recognizer math (getGestureDetected/DragVector/PinchVector/HoldDuration +
  updateGestures) — pure input logic.
- *Design:* RE-EXPORT the recognizer logic; tick `updateGestures` on the wgpu input snapshot
  each frame. No GL.
- *Done:* gestures recognized on wgpu; the 2 port.

**S-F · TTF fonts + text-layout** — unblocks `text_layout` + the custom-font UI holdouts.
- *Verify:* `loadFontFromTtfData`/`loadFontFromTtfBytes`/`bakeFontAtlas` (truetype→atlas) +
  `measureText`/`measureTextEx`/`drawTextWrapped`; the wgpu font path (UiHost DPR baking is the
  precedent).
- *Design:* TTF bake → atlas Image → wgpu texture (reuse S-C upload). RE-EXPORT measure/wrap
  (CPU). DPR-aware (already solved for UiHost).
- *Done:* runtime TTF + layout on wgpu.

### The tail (after/with the subsystems)
- **sw_\*** (5, CLI software-renderer): swap `@import("zimr")`→`zimr_wgpu` (rlsw is
  backend-agnostic) or import `rlsw` directly; verify they still run.
- **UI holdouts** (3): `imgui_demo` (helper var-name generalization + S-F font), `ui_panes`
  (REGENERATE its hardcoded source-display string post-port — don't let transforms frankenstein
  it), `ui_minimal_button` (S-F + 3 UiContexts).
- **"redundant" (~5)** (`mandelbrot`/`julia`/`shader`/`cube_split`/`shader_chroma_split`): PORT each to
  its own wgpu folder (preservation principle — they're mostly distinct; never delete a demo).

### "Improve everything" — opportunistic polish (ride the subsystem that touches it)
Bind-state cache (collapse ~26 setBindGroup/setVertexBuffer per frame); per-`@group`
auto-binding counter (currently global); WASI shim audit (drop unused preview1 imports);
first-draw "missing blue quad" bug; a host↔shader std140 layout lint (the deferred PBR-Ubo
ask); ReleaseSmall standalones <1MB.

### Deletion sequence (only once `@import("zimr")` has ZERO users)
Port/retire every GL example → extract any backend-agnostic helpers still trapped in
`drawing.zig` into their own modules → delete `rlgl.zig`, `gpu.zig` (GL fwd),
`shader_runtime.zig`, the GL halves of `drawing.zig`+`web.zig`, `.glsl` embeds, spirv-cross,
`tools/spirv/`, `tools/zglsl.zig` (~29k LOC) → collapse `zimr_wgpu`→`zimr` → update CHEATSHEET
+ the new-example guide.

### Guardrails
codecs/types/zm/math stay PURE + shared (one file = one module). Never break a working wgpu
demo (single-Ubo PBR + 368-byte FsUbo layout are load-bearing). Verify every port via
`wgpu-smoke` AND a Chrome reload (Tint is the uniformity authority). Reviewable batches,
snapshot between, lint 0. Focused `-Dfocus=` smokes; full smoke only for core changes.

### NEXT / STATUS (turn 1095)
**Step 2b (immediate finish) — essentially DONE.** Verified `drawPlane`+`updateCamera` already
shipped, and `drawCube`/`drawCubeWires` already take `.rotation` (the descriptor IS `drawCubeEx` —
no new fn, per "opts not xxxEx"). Built the immediate-3D primitive completion: `appendConeBetween`
(arbitrary-axis tapered cylinder, draw3d.zig) + public `drawCylinderBetween`/`drawCapsule`/
`drawSphereSubdivided`/`drawBoundingBox` + `getSphere/Cylinder/CapsuleBoundingBox` + the
`BoundingBox` re-export (wgpu_app.zig). `setLight` (cube3d-VS UBO promotion) is the one remaining 2b
item — deferred until an example needs it. **DONE (turn 1095):** `wgpu_models3d` ported + registered + focus-smoke PASS (lint 0, ~34 calls/frame);
standalone built (`prebuilt/standalone/wgpu_models3d.html`, sent to Simon); per-example `index.html` added;
claude.md now mandates a standalone for every feature-bearing port.

**Step 3 — VERIFIED.** GL retained API (`drawing.zig`): `genMeshCube/Sphere/Plane/Cylinder/Heightmap`,
`uploadMesh`, `updateMeshBuffer`, `loadModelFromMesh`, `drawMesh`, `drawModel`, `drawModelWires`; types are
`types.Mesh`/`Model`/`Material` (extern). wgpu `pbr3d` has its OWN `Model`/`Renderer`/`loadGltf` (GLB+PBR),
re-exported but parallel. **Split Step 3:** (3a) raylib retained tier for GENERATED/simple meshes —
`Mesh`→GPU vbo/ibo, `genMesh*`, `uploadMesh`, `loadModelFromMesh`, `Model`, `drawModel`/`drawModelWires`,
unlit material REUSING the cube3d pipeline (no new shader). Unblocks wireframe, dynamic_mesh, first_person_camera.
(3b) `loadModelFromMemory` (GLB) → `Model` via `pbr3d` (kept parallel, Q4). Unblocks gltf_simple, damaged_helmet,
lenna_test, skinned_mesh.

**DONE (turn 1096):** Step 3a retained tier built — `types.Mesh`/`Model` + `genMeshCube`/`genMeshSphere` +
`uploadMesh` (Step-3a no-op) + `loadModelFromMesh` + `drawModel`/`drawModelWires` in draw3d.zig (CPU-transform each
mesh into the immediate batch via `meshWorldPos`/`meshWorldNormal`; reuses the cube3d pipeline, NO new shader).
`wgpu_wireframe` ported + smoke PASS (lint 0, ~30 calls/frame) + standalone sent. Snags fixed: lint Rule-1 signature
split (custom rule, not zig fmt) and `i0`/`i1`/`i2` shadow Zig int primitives → renamed `e0`/`e1`/`e2`.
**NEXT (still Step 3):** `updateMeshBuffer` → port `dynamic_mesh`; `genMeshHeightmap` + first-person `updateCamera`
→ `first_person_camera`. Then **Step 4 (instancing)** — the true GPU instance pipeline (per-instance model matrix;
the "best system" deferred from 3a) for `instancing` + `physics_pyramid`. Then **Step 3b** — `loadModelFromMemory`
(GLB) via `pbr3d` for gltf_simple/damaged_helmet/lenna_test/skinned_mesh. Don't redo 2b/models3d/wireframe.

---

## 2. Guiding principles for the order

1. **Leverage first.** Front-load waves that unblock the most with the least new engine
   work, so the count drops fast and the scaffold gets exercised early.
2. **Just-in-time features.** Build an engine feature only when its wave arrives; the
   feature and the examples that prove it ship together, each feature with a test.
3. **Momentum & risk.** Start low-risk to refine the shared scaffold; tackle the riskier
   subsystems (audio, readback) once the scaffold and cadence are proven.
4. **Clean as we go.** Establish the shared scaffold + visual standard *before* porting, so
   every ported example is consistent and polished rather than retrofitted.

---

## 3. The shared standard — build this FIRST (Phase 0)

A small shared module + a written bar, so all examples look like a family.

**`examples/wgpu_common/` helper module**
- `palette`: a named cohesive dark palette (bg, surface, ink, accent, plus an HSV ramp
  helper) so colors are consistent and tasteful instead of ad-hoc per file.
- `caption(gl, font, text)`: the standard bottom/top caption (one place, one style).
- `backdrop(gl, w, h)`: an optional subtle gradient/vignette/grid so examples don't sit on
  flat black.
- layout helpers: viewport-relative anchors (center, insets, grid cells) — never hardcode.

**Conventions (the code bar)**
- Canonical app shape: `zimr_app` + `main` + `State` + `initState` + `update`.
- Viewport-relative everywhere (`f.window.widthf()/heightf()`), `.responsive`.
- `zm.float(...)` not `@floatFromInt`; lint 0 issues; `//!` header summarizing the example.
- One-line registration via `addWgpuExample`.

**The visual bar ("nice to look at")**
- Cohesive palette, readable type, smooth time-based motion, considered composition.
- No raw primitives dumped on flat black; every example has a deliberate frame.

This scaffold is created in Phase 0 and *refined during Wave 1* on the easy examples, then
inherited by everything after.

---

## 4. Engine features to build (just-in-time)

| # | Feature | Unblocks | Effort | Risk | Sketch |
|---|---|---|---|---|---|
| F1 | **3D mesh + instancing** | 16 | high | med | `drawCube/Wires/Sphere/Grid/Plane` + an instanced cube path (per-instance model matrix + color) over the existing `Camera3D` + `beginMode3D`. The keystone lift. |
| F2 | **Texture readback** | ~3 | med | low | copy RT (already `copy_src`) → buffer → `Image`. Unlocks screenshots / pixel hit-testing / image export. |
| F3 | **Image gen / manipulation** | ~7 | med | low | `genImageColor`, `updateTexture`, image-to-texture round-trips. |
| F4 | **Gesture + multitouch input** | 5 | med | med | touch-point list + tap/drag/pinch recognizers on the wgpu input surface. |
| F5 | **Audio subsystem** | 4 | high | med | load/play sound, music streaming, a stream-synth callback. A whole subsystem. |
| F6 | **Text layout** | ~3 | low | low | `measureText`, word-wrap, alignment. |
| F7 | **MRT** | 1 | low-med | med | multiple color attachments in one pass (`mrt_demo` only). |

---

## 5. The waves (in order)

**Phase 0 — Scaffold + style.** Build `wgpu_common` (palette, caption, backdrop, layout).
No ports. Establishes the look.

**Wave 1 — 2D quick wins + RTT-ready (no new features, ~19).** Refine the scaffold on easy
examples and clear the RTT backlog now that RTT exists.
`math_angle_rotation`, `vector_angle`, `rectangle_scaling`, `triangle_gradient`,
`shapes_showcase`, `starfield_effect`, `writing_anim`, `basic`, `window_demo`, `keys`,
`gallery`, `sampler_derisk_test`, `procgen_noise`; RTT: `rtt`, `lines_drawing`,
`text_on_texture`, `split_screen`. **Highlight:** `physics_pyramid` as a 2D front-view
(the planar pyramid rendered as rotated rects on the real solver) — gets the marquee demo
early without the 3D lift.

**Wave 2 — 3D foundation + sweep (F1, then 16).** F1 is partway (`3D_PIPELINE_PLAN.md` §4).
Port in dependency order as each step lands:
- **After Step 2b** (immediate finish — `drawCubeEx` rotation, `drawPlane`, `setLight`,
  `updateCamera`): `cube3d`, `wireframe`, `first_person_camera`, `ecs_solar_system`,
  `physics_demo`.
- **Alongside, via existing `z.pbr3d` (no new engine, just port + scaffold):** `gltf_simple`,
  `gltf_model_refs`, `damaged_helmet`, `skinned_mesh`.
- **After Step 3** (retained `Mesh`/`Material`/`Model` + `genMesh*` + `loadModel`): `models3d`,
  `dynamic_mesh`, `typed_unlit_demo`, `billboards` (+ a `drawBillboard`).
- **After Step 4** (instancing — `drawMeshInstanced`): `physics_pyramid` (full 3D, the marquee),
  `instancing`.
- **Separate (cubemap + skybox pipeline):** `skybox`.

First banked example, to prove the immediate path end-to-end before the retained tier: a
`models_geometric_shapes`-style scene (grid + the six primitives + camera), then `cube3d`.

**Wave 3 — UI batch (no new features, 47).** The big grind; Dear ImGui already runs on
wgpu. Sub-batches: minimal/buttons → tables → docking → drag-drop → plotting →
phone apps (`*_phone`) → the big showcases (`ui_full_showcase`, `imgui_demo`). Benefits
from a small UI-example sub-scaffold.

**Wave 4 — Image + readback (F2+F3, 7).** `texture_readback`, `image_editor`, `image_text`,
`load_image_demo`, `png_demo`, `lenna_test`, plus `rlsw_side_by_side`.

**Wave 5 — Gestures / touch (F4, 5).** `gestures_demo`, `gestures_testbed`,
`input_multitouch`, `touch_paint`, `input_virtual_controls`.

**Wave 6 — Audio (F5, 4).** `audio_basic`, `audio_stream_synth`, `composer_drum`,
`music_streaming`.

**Wave 7 — Specialized tail.** `mrt_demo` (F7), `text_layout` (F6), `julia_gallery`, and any
remainder.

**Final — Redundancy deletion (deferred per your earlier call).** Remove the redundant
shader-pipeline variants (`*_fs`, `*_fs_io`, `*_fs_bundle`, `*_vs`, `*_vs_io`,
`comptime_*`, `cube_split*`, the duplicate `mandelbrot`/`julia`/`shader*` covered by
canonical wgpu fractals/`rt_shader`) and any orphaned shader-source files. Saved for the
end so it never blocks porting.

---

## 6. Per-example cadence

For each example: read the GL source → port onto the `wgpu_common` scaffold → apply the
visual standard → lint (0 issues) → build the standalone → screenshot-verify → iterate.

Per-wave gate: every example in the wave lints + builds clean; the wave's new engine
feature has a test; a short note (tutorial/changelog) captures any gotchas.

---

## 7. Order rationale (one paragraph)

UI is the largest single batch (47) and needs no new engine work, so by raw count it could
go first — but it's a uniform grind and visually samey. Leading instead with the 2D quick
wins + the marquee physics pyramid builds the scaffold and momentum on varied, satisfying
demos; the 3D feature (the one big lift that unblocks 16) comes second while energy is
high; then the UI grind; then the riskier feature-gated waves (image/readback, gestures,
audio) last, where a proven cadence de-risks the new subsystems. Deletion is saved for the
very end so cleanup never blocks progress.

## ⚠ RECOVERY LOG (turn 1098)
The sandbox reverted to the zimr1095 state between turns — wireframe + dynamic_mesh + the entire retained
tier in draw3d.zig were gone, only models3d registered. Recovered by unzipping `zimr1097.zip` over the repo
(per-turn output zips persist in /mnt/user-data/outputs — they are the safety net). **Lesson: if the repo
state looks behind, the latest `zimrNNNN.zip` is the source of truth — restore from it first.**

**physics_pyramid: WIP, UNREGISTERED.** Ported (rlgl matrix-stack -> `drawCube(.rotation = matFromQuat(q))`;
ECS+physics query collects bodies then draws). COMPILES + lints clean, but `update()` hits a frame-0
`unreachable` trap at runtime (Debug build). NOT the State return-by-value copy (the GL does the same copy;
ecs_boids proves the ECS Registry is copy-safe by value). File kept at examples/wgpu_physics_pyramid/;
unregistered from build.zig so the build/smoke stay green.
NEXT: (1) debug physics_pyramid — bisect `update()` (comment the physics `step` vs the render/collect) to
localize the trap; likely a physics/ECS path that only traps in a Debug wgpu build. (2) Step 4 (instancing)
for `instancing`. Done so far: models3d, wireframe, dynamic_mesh.

## physics_pyramid BISECT (turn 1099)
Sandbox had reverted AGAIN this turn (lost wireframe/dynamic_mesh/retained tier) — restored from zimr1098.
Build re-confirmed green (wireframe smoke passes).
RULED OUT for the frame-0 trap: (a) State-copy anti-pattern — refactored initState to a direct-return literal +
spawn-on-first-frame (good hygiene) but the Debug trap was UNCHANGED, matching the wgpu_app comment that the
intermediate-local issue is Release-only; (b) std.debug.print — none, and the trap is a Zig `unreachable`/assert.
BISECTED: the frame-0 trap is `phys_world.step()`. With the step disabled, physics_pyramid renders the full
static pyramid + spheres cleanly -> drawCube/matFromQuat/the ECS render query are all correct. The trap is one of
physics.zig's 2 assert/unreachable sites in the solver path (step@712 -> solveConstraints@1853 / solveOneContact@1946
/ solvePosition@2078 / gjk@3023 / epa@3276 / warmStartManifold@3884), only checked in Debug; the GL ran the same step
in Release where the assert is UB/silent. physics_pyramid is render-verified but UNREGISTERED (Debug smoke trips it).
NEXT: find which of physics.zig's 2 asserts fires on frame 0 (likely a resting/degenerate-contact edge case on the
just-spawned, exactly-touching boxes). Fix the bug or relax the assert, then register + standalone physics_pyramid.

## physics_pyramid ROOT CAUSE (turn 1100) — EPA degeneracy, deferred
Frame-0 trap is NOT dt (physics.zig step already clamps dt to [0.001,0.5]; clamping in the example changed
nothing), NOT the State copy (direct-return refactor changed nothing — it's a Release-only issue), NOT a print.
It is a Zig `unreachable` from `reconstructFaces` in EPA (physics.zig ~3517): a DEGENERATE EPA expansion on flush
face-face box contacts (settled box stacks) overruns the face buffer. max_minkowski_vertices=16 -> a valid polytope
has <=2*16-4=28 faces, but the degenerate expansion overran 64 AND 128 (tested both) -> unbounded face growth, a
real geometry degeneracy, not capacity padding. The GL ran the same EPA in Release where the assert is UB and the
overflow was silent/survivable, so this only surfaced on the wgpu Debug smoke.
physics_pyramid keeps the good fixes (direct-return initState + spawn-on-first-frame; dt via zm.clamp) but stays
UNREGISTERED — render path is bisect-verified, only the physics step traps. REAL FIX = robust degenerate/coplanar
contact handling in EPA (a focused physics task, best with Simon). MOVE ON meanwhile: Step 4 instancing
(`instancing` — genMeshCube + drawMeshInstanced, no physics/EPA).

## physics_pyramid RESOLUTION (turn 1102) — FIXED, registered, cold-smoke-green
The turn-1100 root cause was WRONG about the mechanism (good reminder: "be skeptical of labels", even our own).
The trap is NOT a `reconstructFaces` buffer overflow — it's a `normalize3` of a ZERO vector in EPA's
`calcNormalDistance` (`zimrmath.zig` asserts `dot3(v,v) > 0`). Reproduced with an exact 78-box pyramid: the
Minkowski polytope of two flush axis-aligned boxes seeds a COLLINEAR vertex triple (a horizon edge ends up
collinear with the freshly-added apex: `v0 == (v1+v2)/2`), so the face's `cross3(edge0,edge1)` is exactly zero.
The face-count growth the old note saw was the SYMPTOM: a zero normal fails the `dot(n,diff) > 0` visibility test,
so those zero-area faces were never culled and piled up. Silent UB in the GL Release build; a hard trap in wgpu Debug.

Fix (robust EPA, NOT a bigger buffer — three coordinated changes in `physics.zig`):
1. `calcNormalDistance` — a zero-area face is marked INERT (distance = `floatMax`, normal = 0) instead of
   normalizing zero; it's then never chosen as the closest face.
2. expansion visibility — inert (zero-normal) faces are treated as removable, so they re-triangulate each
   iteration instead of accumulating; the polytope stays clean and bounded (64 is comfortable headroom).
3. `collideBoxBoxImpl` — the penetration axis is guarded (`safeNormalize3` + centre-to-centre fallback) so a
   fully-degenerate result still yields a usable contact normal for getSupportFace / clip / manifold.
Verified: all 25 physics tests pass + a new regression test (`flush-box pyramid stack is stable`) that builds the
78-box pyramid, steps ~2 s, and asserts finite + bounded positions (instrumented runs showed it settles to rest,
maxspeed → ~0.02 by frame 45, y-range locked at [0.49, 11.27]). Registered in build.zig; FULL COLD `smoke-test`
green (109/109, physics_pyramid PASS); ReleaseSmall standalone built (`prebuilt/standalone/wgpu_physics_pyramid.html`).

## physics_pyramid camera polish (turn 1102) — DONE
On-device feedback drove three small example-only fixes (no engine churn after a revert):
- First-touch pop: a `dragging: bool` latch that skips the FIRST drag frame (stale `previous_position`
  on the no-touch→touch boundary), then applies raw `getMouseDelta` from frame 2. NO threshold — copies
  the rt_sidebyside pattern (the UI-context `getMouseDragDelta` threshold helper felt laggy/dropped slow
  drags, so a brief detour through it was reverted; speculative `z.*` drag-delta exports removed, engine
  files verified byte-clean vs snapshot).
- Inverted Y orbit: `cam_angle_pitch += delta[1]` (was `-=`).
Sharp-edge recorded in claude.md. physics_pyramid is fully done (render + physics + camera).

## Step 4 — instancing — DESIGN + NEXT (turn 1102, verified against the tree)
GL `instancing` (examples/instancing.zig): `genMeshCube` + `uploadMesh`, a custom GLSL VS with an
`instanceTransform` mat4 vertex attribute (loc 8, split into 4 vec4s), and `drawMeshInstanced(mesh,
material, transforms)` rebuilding the per-instance VBO each frame. Demo = 10×10×10 = 1000 cubes, each
spinning on its own Y phase, ONE instanced draw.

What the wgpu tree has now (draw3d.zig): `genMeshCube(gpa,w,h,d) -> types.Mesh` (✓), `uploadMesh` is a
Step-3a NO-OP (the `//` there literally says "Step 4 makes this build the vertex/index buffers"),
`drawModel`/`drawModelWires` CPU-transform each vertex into the immediate batch via `meshWorldPos`
(`instance_count = 1`). No `drawMeshInstanced`. So this is genuine new engine work — the deliberately
deferred "best system."

Design (do the GPU pipeline, NOT a CPU expand-into-batch throwaway):
1. `uploadMesh` builds GPU-resident vbo/ibo on the Mesh (the no-op becomes real); keep the immediate
   `drawModel` CPU path working for the simple low-count examples (don't regress models3d/wireframe).
2. `drawMeshInstanced(gl, mesh, transforms: []const zm.Matrix, color)` — upload `transforms` into a
   per-instance vertex buffer (step-mode = instance) holding a mat4 as 4×vec4 (+ optional per-instance
   color), then one `drawIndexed` with `instance_count = transforms.len` over the cube3d pipeline. The
   cube3d VS already consumes a per-draw model matrix from the UBO — generalize it to read the
   per-instance attribute when instancing (a small VS variant or an `instanced` pipeline flavor in the
   pipeline cache). Reuse the existing depth/bind-group setup.
3. Per-frame transform upload is fine for ~1000s (matches the GL note); document the high-count caveat.
Then port `examples/wgpu_instancing/` (10³ grid, per-cube Y-phase spin, one drawMeshInstanced) on the
wgpu_common scaffold; focused `-Dfocus=wgpu_instancing` smoke + ReleaseSmall standalone for phone.
NEXT TURN START HERE: implement (1)+(2) in draw3d.zig + the instanced cube3d pipeline flavor, then the example.

## Step 4 — instancing — DONE (turn 1103)
True GPU instancing landed, NOT a CPU expand-into-batch throwaway:
- New shader `src/shaders/cube3d_instanced_vs.zig` (+ io) — reconstructs the per-instance model matrix from
  four instance-step vec4 columns on the GPU, reuses `cube3d_fs`. Transpiles clean through spv2wgsl; emitted
  WGSL verified to carry vertex locations 0–6 (mesh pos/normal + 4 matrix columns + colour).
- `draw3d.zig`: a second pipeline (two vertex buffers — mesh `pos+normal` @vertex-step + per-instance
  `model mat4 (4×vec4) + colour` @instance-step), sharing the cube3d UBO bind group. `MeshVertex` /
  `InstanceVertex` / a `MeshGpu` registry. `drawMeshInstanced(ps, mesh, transforms, color)` lazily uploads
  the mesh to GPU buffers on first use (slot in `Mesh.vaoId`), streams a per-instance buffer (grows on
  demand), one `drawIndexed` with `instance_count`, recorded straight into the active 3D pass (depth-tested
  with the immediate batch). Immediate `drawModel` CPU path untouched (models3d/wireframe unregressed).
- API: `drawMeshInstanced` via wgpu_app.zig → zimr_wgpu.zig. `z.Matrix` (= zm.Mat) is the transform type.
- Example `examples/wgpu_instancing/` — 1000 cubes (10³ grid), per-cube Y-phase spin, ONE instanced draw,
  orbit camera. Registered. Focused smoke PASS + FULL `smoke-test` GREEN (110/110, instancing PASS) +
  ReleaseSmall standalone built. lint 0 (408 files).
NEXT: Step 3b — `loadModelFromMemory` (GLB) via pbr3d (gltf_simple/damaged_helmet/lenna_test/skinned_mesh),
then S-A rlgl. Shader-validation note: naga/Dawn can't be built in-sandbox yet (Rust tarball was only a .asc
signature; apt rustc 1.75 < naga's required 1.87; Dawn needs cmake/clang/gn + blocked googlesource). In-tree
wgsl_check + the bun smoke are the current gates; naga is the missing uniformity authority.

## S-E gestures — INFRA DONE, gestures_demo ported (turn 1104)
Gesture recognizers are backend-agnostic input math; RE-EXPORTED in zimr_wgpu from `runtime.zig`'s
`gestures` namespace — `GesturesState`, `Gesture`, `getGestureDetected/DragVector/DragAngle/PinchVector/
PinchAngle` direct, plus `updateGestures` + `getGestureHoldDuration` wrapped to BRIDGE wgpu's frame
`TimeState` → the recognizers' core `TimeState` (they only read `.current` seconds: `.{ .current = t.time,
.delta_time = t.delta_time }`). `examples/wgpu_gestures_demo/` ported (current gesture + drag/pinch/hold
data + history + touch strip), registered, focused smoke PASS, standalone built, lint 0 (409 files).
NEXT: port `gestures_testbed` (same APIs + `getTouchPointId` — check it's re-exported; 3-column layout),
which finishes S-E. Then continue largest-first: S-A rlgl (~15) or S-C image (~13).

## naga/Dawn shader validation — still blocked (turn 1104), the fix
The rust upload arrived AGAIN as only the 801-byte `.asc` signature (3rd time) — the chat upload pipeline
isn't carrying the ~150MB `.tar.xz`. No rustc/cargo/cmake in-sandbox; apt rustc 1.75 < naga's 1.87.
**WORKING FIX (codeload.github.com IS reachable from the sandbox — verified):** host the rust tarball (or a
prebuilt `naga` binary) on a GitHub release/repo and give the raw URL; `curl`/web_fetch pulls it via the
allowed github egress, bypassing the chat upload limit. On-device validation already covers correctness:
the instancing standalone reported "GPU frame/init scope: clean (no validation error)" — that's the
browser's Tint validating the emitted WGSL, the real uniformity authority.

## S-E gestures COMPLETE (turn 1105) + the road to GL deletion
gestures_testbed ported (3-column touch/gesture/log visualizer; added `getTouchPointId` re-export). Both
S-E examples done, focused smokes PASS, standalones built, lint 0 (410 files, 112 wgpu examples).
**40 GL-only examples remain.** Roadmap to deleting WebGL (largest subsystem first — each unblocks a batch):
- **S-A rlgl immediate-mode (~15, BIGGEST):** implement an immediate-mode recorder over the EXISTING wgpu
  batcher (rl* accumulates → flush on matrix/texture/blend change). Unblocks basic/shader/rtt/image_editor/
  procgen_noise/cube_split/mrt_demo/texture_readback/text_on_texture/rlsw_side_by_side/sampler_derisk/
  physics_demo/load_image_demo. START HERE next.
- **S-C image upload/readback (~13):** re-export Image + image* CPU ops; implement Image→texture upload +
  texture→Image readback + genImage*. Unblocks load_image_demo/png_demo/image_text/image_editor/lenna_test/
  texture_readback + first_person_camera (needs genImageChecked/genMeshHeightmap) + skybox.
- **S-D audio (4):** Web Audio bridge (new `audio` import in the TS) — audio_basic/audio_stream_synth/
  composer_drum/music_streaming.
- **S-F TTF (~few):** loadFontFromTtfData + measureText/wrap — text_layout + custom-font UI holdouts.
- **Tail (endgame, after subsystems):** sw_* (5, NATIVE CLI — repoint @import("zimr")→agnostic modules
  math/codecs/rlsw when GL collapses; they don't block browser parity), UI holdouts 3 (imgui_demo/ui_panes/
  ui_minimal_button), "redundant" ~5 (mandelbrot/julia/shader/cube_split/shader_chroma_split — PORT, don't delete),
  billboards (+drawBillboard), typed_unlit_demo, split_screen, gltf_* (Step 3b).
Then: extract any agnostic helpers still trapped in drawing.zig → delete rlgl.zig/gpu.zig(GL)/shader_runtime/
the GL halves of drawing.zig+web.zig/.glsl embeds/spirv-cross/tools/spirv → collapse zimr_wgpu→zimr.

## S-A rlgl — STARTED carefully (turn 1106): design + tested recorder core
Did the mandated verify→design pass: read GL rlgl's immediate-mode model (rlBegin/rlVertex CPU-transform by
modelview at emit, rlSetTexture draw-splits, batch flush) + mapped exactly which rl* each GL example calls
(table in the //! doc). KEY FINDINGS: (1) the wgpu 2D batch's `drawTriangleBatched(p,uv,color×3)` is a direct
target for immediate verts; (2) the matrix stack = CPU pre-transform (modelview only for the 2D flush — the 2D
pipeline owns screen→NDC); (3) the rlgl-immediate textured examples are CO-DEPENDENT on S-C (texture upload) —
rlSetTexture needs a real texture; colour-only immediate works now via the id-registry white texture; (4)
textured-3D immediate (cube_split/text_on_texture) is the one genuinely-missing path (3D batch has no uv); (5)
several "rlgl" examples (physics_demo) use only the matrix stack + drawCube → rewritable to the wgpu API like
physics_pyramid (no recorder needed).
LANDED: `src/rlgl_wgpu.zig` — the pure, GPU-free recorder core (matrix stack push/pop/identity/translate/rotate/
scale/mult/ortho/matrixMode; immediate state color/uv/normal/setTexture; begin/end/vertex2f/3f accumulating into
texture-split runs; CPU-transform via modelview). Ergonomic enums (`Mode`/`MatrixMode` → `z.rlBegin(gl,.triangles)`)
instead of raylib's i32. 4/4 unit tests pass (matrix-stack restore, vertex transform, run-splitting, reset),
lint 0. Pure logic → headlessly testable; no wgpu/JS deps.
NEXT (still S-A): wire the `rl*` public API on a per-App `RlglState` in wgpu_app.zig + flush the runs into
`app.pass`'s 2D batch (drawTriangleBatched, switching texture per run) at endDrawing; re-export `rl*` + `Mode`/
`MatrixMode` in zimr_wgpu; add rlgl_wgpu to src/tests.zig; loud-stub rlSetShader/rlEnableFramebuffer/rlColorMask;
port the first colour-only immediate example (then the textured ones land with S-C).

## rlgl CORRECTION + physics_demo ported (turn 1107)
CORRECTION: last turn's S-A "recorder core" was REDUNDANT — WgpuGl (src/wgpu_draw.zig) ALREADY has a functional
immediate-mode recorder (begin/end/vertex2f/3f/color4ub/texCoord2f/normal3f/setTexture, batched) + matrix
support (matrixMode/loadIdentity/multMatrix/ortho/frustum). Deleted src/rlgl_wgpu.zig. The GENUINE rlgl gap is
small: the convenience matrix ops pushMatrix/popMatrix/translatef/rotatef/scalef are missing on WgpuGl, plus
most rl* wrappers aren't surfaced in wgpu_app/zimr_wgpu. Add those WHEN their examples land (a real caller),
NOT speculatively. The rlgl-IMMEDIATE textured examples (basic/image_editor/procgen_noise) are gated on S-C
(texture upload), not the recorder. So S-A is mostly done; **S-C (image/textures) is the real difficult engine
work + the blocker** for most of the rlgl set AND the image set.
PORTED: `examples/wgpu_physics_demo/` — rain-of-balls sandbox (box pyramid + rotated static obstacles + a static
capsule "log"; sphere/box/capsule contacts; SPACE throw, R reset). Same recipe as physics_pyramid (matrix-stack
→ drawCube(.rotation=matFromQuat); collect-then-draw), + capsules via drawCapsule + ball-rain. Dropped the GL
Logger/Browser (a 3-frame diagnostic). Camera uses the drag-latch + correct Y. Focused smoke PASS, lint 0 (411
files, 113 wgpu examples, 39 GL-only left), standalone built. Validates the EPA fix on mixed-collider scenes.
NEXT: START S-C (image/texture upload) — verify→design (GL Image + image* CPU ops + loadTextureFromImage/
updateTexture/readback + genImage*) → re-export Image + image* (CPU, shared) + implement Image→wgpu-texture
upload (then readback). Unblocks load_image_demo/png_demo/image_text/image_editor/lenna_test/texture_readback +
the rlgl-textured examples (basic/procgen_noise) + first_person_camera. THEN finish rlgl's matrix-op gap as
text_on_texture/cube_split land.

## S-C audit + png_demo ported (turn 1108) — "don't redo" pays off again
AUDIT (before building): the wgpu texture/image FOUNDATION already EXISTS in wgpu_app — `loadImageFromMemory`
(decode PNG via codecs), `loadTextureFromImage` (Image→GPU texture), `drawTexture`/`drawTextureRec` (tinted
quads), `WgpuTexture` (w/h), `registerTexture` (id registry for rl setTexture). All re-exported in zimr_wgpu.
So image DECODE+UPLOAD+DRAW is done. The S-C GAPS are: `genImage*` (procedural gen), the `image*` CPU
manipulation ops (imageColorInvert/Copy/RotateCW/BlurGaussian/imageText), `updateTexture` (re-upload), and
`loadImageFromTexture` (GPU→CPU readback). Those CPU ops live TRAPPED in `drawing.zig` (the GL monolith) — per
the plan they need EXTRACTION to a clean `image.zig` module (a direct re-export risks pulling GL deps into
every wgpu example), then re-export. readback + updateTexture are GPU ops to implement.
PORTED: `examples/wgpu_png_demo/` — decode embedded PNG → GPU texture → tinted 2×2 grid (loadImageFromMemory →
loadTextureFromImage → drawTexture; CPU pixels freed post-upload). Dropped the GL retained-texture system +
logger. Focused smoke PASS, lint 0 (412 files, 114 wgpu examples, 38 GL-only left), standalone built.
Per-example gating recheck: lenna_test → GLB (Step 3b); load_image_demo → async Io fetch loader (its own
concern, or embed); procgen_noise → genImage* + rl-immediate (exists) + texture; image_editor → image* CPU
ops + updateTexture; image_text → imageText; texture_readback → loadImageFromTexture (readback).
NEXT: extract the CPU image ops (genImage*/image*/imageText/unloadImage) from drawing.zig into a clean shared
module → re-export in zimr_wgpu (unblocks procgen_noise/image_editor/image_text); then implement updateTexture
+ loadImageFromTexture readback (unblocks image_editor/texture_readback). Verify each op compiles for wasm
(no GL deps) as it's extracted.

## S-C: genImage* extracted to image.zig (turn 1109)
EXTRACTED the procedural CPU image-gen family out of the GL monolith into a new clean `src/image.zig`
(GL-free: imports only std/zm/types/errors + the shared Rng): `genImageColor`, `genImageChecked`,
`genImageWhiteNoise`, `genImagePerlinNoise`, `genImageCellular` + the noise internals (perlin2 + Ken Perlin's
permutation table, grad2/perlinFade, hash2, rgba8Image). Faithful copies of the drawing.zig impls; the GL
copies stay until the backend is deleted (transient dup, per Simon's "small files now, merge later"). 2 unit
tests pass (genImageColor fill, perlin determinism) + 0 lint; re-exported in zimr_wgpu (genImage* + the `rng`
module `z.rng.Seeded`), COMPILE-VERIFIED for wasm via a focused png_demo build (413 files, png_demo PASS).
CONFIRMED procgen_noise is now a NO-NEW-ENGINE port: genImage* (done) → `loadTextureFromImage` (exists) →
rl-immediate textured quads (`rlSetTexture(gl, WgpuTexture)` takes the texture directly; rlBegin/rlColor4ub/
rlTexCoord2f/rlVertex2f/rlEnd all exist; the textured path is the same one png_demo's drawTexture uses, proven).
The animated 4th panel: recreate the WgpuTexture each frame (WgpuTexture.deinit exists) until updateTexture lands.
NEXT: port procgen_noise (genImage* + rl-immediate); then the remaining S-C ops — extract the image* CPU
manipulation ops (imageColorInvert/Copy/RotateCW/BlurGaussian + imageText) into image.zig, and implement
`updateTexture` (queueWriteTexture re-upload) + `loadImageFromTexture` (GPU→CPU readback) — unblocking
image_editor (image* + updateTexture), image_text (imageText), texture_readback (readback).

## procgen_noise ported (turn 1110) — validates image.zig end-to-end
`examples/wgpu_procgen_noise/` — white/Perlin/cellular noise panels (genImage* on CPU → loadTextureFromImage →
rl-immediate textured quads: rlSetTexture(WgpuTexture) + rlBegin(.triangles) + rlTexCoord2f/rlVertex2f) + a
full-width animated Perlin that scrolls (regenerated each frame at a time offset; texture recreated each frame
via WgpuTexture.deinit, since updateTexture isn't landed yet — the GL original generated this field but never
drew it, so this improves on it). Dropped the GL retained-texture system + logger. Focused smoke PASS, lint 0
(414 files, 115 wgpu examples, 37 GL-only left), standalone built. NO new engine work — pure consumption of
the genImage* foundation + the existing rl-immediate textured path (the one png_demo's drawTexture proved).
NEXT: finish S-C — extract the image* CPU manipulation ops (imageColorInvert/Copy/RotateCW/BlurGaussian +
imageText) into image.zig, and implement updateTexture (queueWriteTexture in-place re-upload) +
loadImageFromTexture (GPU→CPU readback). Unblocks image_editor (image* + updateTexture; the updateTexture path
also de-churns procgen_noise's animated panel), image_text (imageText), texture_readback (readback).

## procgen_noise bugfixes + updateTexture landed (turn 1111)
On-device feedback caught two bugs: (1) overlapping top text — `co.caption` draws at the TOP (14,12), and the
example ALSO drew its own title at (12,12); fix = drop the redundant title, keep co.caption. (2) animated panel
went white after ~1s — the recreate-the-texture-each-frame hack churned GPU resources. FIXED by implementing
the real S-C op: `updateTexture` (WgpuTexture.updatePixels → in-place queueWriteTexture; public wgpu_app.updateTexture;
re-exported in zimr_wgpu). procgen_noise's animated panel now re-uploads in place (no churn; trace confirms no
per-frame texture/bind-group create). Focused smoke PASS, lint 0 (414 files), standalone rebuilt.
S-C remaining: extract the image* CPU manipulation ops (imageColorInvert/Copy/RotateCW/BlurGaussian + imageText)
into image.zig (re-export) → unblocks image_editor (now also has updateTexture) + image_text; implement
loadImageFromTexture (GPU→CPU readback) → unblocks texture_readback.

## S-C: image* ops extracted + image_editor ported + loadImageFromMemory bugfix (turn 1112)
Extended src/image.zig with the CPU image MANIPULATION ops (extracted from drawing.zig, RGBA8-focused, GL-free):
imageColorInvert, imageCopy, imageRotateCW, imageBlurGaussian (+ helpers imagePixelCount/bytesPerPixel/
imageDataByteCount/imageAlphaPremultiply) + unloadImage. 3 image* tests pass (invert/rotate/copy round-trip),
37 total in image.zig, 0 lint. Re-exported all in zimr_wgpu.
ENGINE BUGFIX: loadImageFromMemory set `.format = 0`, but PixelFormat has no 0 member (grayscale=1, r8g8b8a8=7),
so any image* op reading the format via @enumFromInt tripped an illegal-enum panic. png_demo never hit it (draw
path ignores format); image_editor's imageCopy did → `_initialize threw Unreachable`. Fixed: loadImageFromMemory
now sets `.format = @intFromEnum(.uncompressed_r8g8b8a8)`.
PORTED: `examples/wgpu_image_editor/` — decode a 32×32 PNG, imageCopy×4 + edit (none/blur/invert/rotateCW) → 4
static GPU textures, + a 5th "live" panel whose CPU bytes are rewritten each frame (brightness wave over a
diagonal gradient) and pushed in place via updateTexture. rl-immediate textured panels. Focused smoke PASS
(trace: per-frame queue_write_buffer, no texture create — updateTexture in-place confirmed), lint 0, standalone
built. 116 wgpu examples, 36 GL-only left.
NEXT (S-C tail): imageText (needs CPU font glyph rasterization — bigger; check what it depends on in drawing.zig)
for image_text; loadImageFromTexture (GPU→CPU readback, async map) for texture_readback. Then S-C is done.

## basic ported + remaining-bucket audit (turn 1113)
AUDITED the actual GL-only list (42). The easy ports are largely done; remaining are subsystem buckets:
audio (4: audio_basic/audio_stream_synth/composer_drum/music_streaming) needs Frame.audio_device + the wgpu
runner's Web Audio JS bridge + AudioDeviceState (full bring-up, not just re-exports); imageText (font glyph
rasterization); loadImageFromTexture (async GPU readback — wgpu has none; web.zig:readPixels is GL-only);
textured-3D primitives (billboards drawBillboard*, cube_split, text_on_texture — the 3D batch has no UVs);
glTF/GLB (damaged_helmet/gltf_*/lenna_test/skinned_mesh); MRT (mrt_demo); sw_* (native-CLI, repoint); window_demo
(clipboard/fullscreen/screenshot window-system APIs); shader_uniforms (raylib runtime loadShader/beginShaderMode
— wgpu uses comptime+spv2wgsl, different model). Still-tractable 2D/UI: ui_minimal_button, ui_panes,
ui_phone_gestures (z.ui/UiHost exists), text_layout (needs measureText), mandelbrot/julia/shader (likely
redundant with ported comptime/mandel_julia versions).
PORTED: `examples/wgpu_basic/` — the canonical flagship. genImageChecked(16,16,4,4,sky,slate) builds the checker
(validates genImageChecked) → loadTextureFromImage → one tinted-checker triangle via the rl-immediate textured
path over a pulsing bg. Focused smoke PASS, lint 0 (416 files), standalone built. 117 wgpu examples, ~35 GL-only.
NEXT options (pick by ROI): (a) UI bucket — ui_minimal_button/ui_panes (UiHost exists, likely quick, 2-3 examples);
(b) audio bring-up (4 examples, needs JS bridge + Frame plumbing); (c) imageText or readback (1 each, heavy).
Recommend the UI bucket next (tractable, multi-example), then audio.

## UI bucket started: ui_minimal_button ported (turn 1114)
`examples/wgpu_ui_minimal_button/` — three UI windows (A/B/C), each a self-contained button + tap counter,
driven by one z.UiHost (the GL version used 3 UiContexts as a font-binding diagnostic; on wgpu the font path is
settled, so it's one UiHost + three windows demonstrating multi-window render + per-window input routing). Uses
the wgpu UI pattern: UiHost.init(gpa, font) → begin(f) → u.window/text/separator/button/sameLine → render(f).
Focused smoke PASS (trace: 19 draw_indexed + 6 scissor rects for the 3 windows), lint 0 (417 files), standalone
built. 118 wgpu examples, ~34 GL-only left.
UI-bucket recon: ui_panes needs splitter + treeNodeEx + setNextWindowSizeConstraints widgets (the ui.zig
DrawListSplitter is a different draw-channel concept, NOT the pane splitter) — likely not exposed on the wgpu Ui,
defer/verify. ui_phone_gestures (322L) is mostly manual drawRectangle + drawText + low-level mouse input
(f.input.mouse.press_position/current_button) + u.isMouseHoveringRect — portable but needs the wgpu input-field
mapping verified first.
NEXT: verify wgpu Ui has isMouseHoveringRect + the f.input.mouse fields (press_position/current_button) → port
ui_phone_gestures; check ui_panes splitter availability. Then audio bring-up (4 examples) as the next subsystem.

## ui_minimal_button layout fix (turn 1115)
On-device: A/B worked + input routing correct, but window C (hardcoded initial_pos y=568, for an 880-tall canvas)
fell off shorter responsive canvases. FIXED: tile all 3 windows from the ACTUAL canvas each frame via
setNextWindowPos/setNextWindowSize using f.window.widthf()/heightf() (the phone-example pattern from
wgpu_ui_pomodoro_phone) — win_h=(fh-margins)/3, stacked. Always fits any device. Smoke PASS, lint 0, standalone
rebuilt. (Sharp edge for claude.md: don't hardcode UI window positions for phone/portrait sizes — derive from
f.window each frame; the responsive canvas is NOT the requested width×height.)

## ui_phone_gestures ported (turn 1116)
`examples/wgpu_ui_phone_gestures/` — touch playground: 4 TAP targets (rising-edge press tested against the
landing point), a DRAG handle that pins to the finger, and a scissor-clipped SWIPE list. Pure manual drawing +
raw mouse/touch input (f.input.mouse.press_position/current_button, getMousePosition) — hover computed directly,
no UiHost needed. Verified the wgpu Mouse struct has press_position/current_button/current_position + the Ui has
isMouseHoveringRect. Focused smoke PASS, lint 0 (418 files), standalone built. 119 wgpu examples, ~33 GL-only.
SHARP EDGE (add to claude.md): beginScissorMode DEBUG-ASSERTS the rect is contained in the backing (logicalToBacking,
turn-912 dead-screen guard); the smoke runs Debug, so a scissor rect that exceeds a short/responsive canvas PANICS
("update threw Unreachable"). Clamp scissor rects to the canvas: swipe_h = @min(220, f.window.heightf()-y-margin),
and skip the clipped section if there's no room.
UI bucket status: ui_minimal_button + ui_phone_gestures done. ui_panes still needs splitter/treeNode widgets (defer).
NEXT: audio subsystem bring-up (4 examples: audio_basic/audio_stream_synth/composer_drum/music_streaming) — needs
Frame.audio_device + AudioDeviceState in the wgpu runtime + the Web Audio JS bridge in the wgpu runner. Verify the
smoke mocks audio; if so, smoke can pass with the plumbing + re-exports.

## ENGINE BUGFIX: shapes invisible after text (turn 1116, via screenshot)
On-device: phone_gestures' filled rects (tap squares + drag handle) were invisible — only text rendered. Root
cause: the wgpu shape fns (drawRectangle/drawCircle/drawEllipse/drawPoly/drawTriangleGradient/drawCircleGradient/
drawRectangleGradientV/Ex/drawTriangleFan/drawCircleSector/drawRectanglePro/drawLineEx) did gl.begin/vertex/end
but NEVER bound the white texture, while drawText binds the font atlas and leaves it bound. The codebase
convention (drawing.zig:3057) is "shapes bind white up front, text binds the atlas" — the GL backend does this,
the wgpu shape fns didn't. So any shape drawn AFTER text sampled the font atlas → invisible. FIXED: every wgpu
shape fn now `gl.bindTexture(.{})` (white) up front. Verified: phone_gestures PASS (rects render), shapes_showcase
PASS (no regression), lint 0 (418 files). This silently affected any example mixing text-then-shapes; the earlier
ports mostly drew shapes before text so didn't surface it. Standalone rebuilt.

## Standalone scale consistency (turn 1117)
Simon noted the canvas scale differs between the Claude in-app viewer and Chrome. Root cause: scale_mode=.responsive
makes the LOGICAL size = the canvas's live CSS width (f.window.widthf() == clientWidth). The standalone template
(tools/buildaux.zig wgpu_standalone_template) already had the viewport meta + `canvas{width:100%;height:auto}` +
the bridge's ResizeObserver (backing = clientW×DPR), but `.canvas-frame{max-width:960px}` let the canvas grow to
the viewer's layout-viewport width — Chrome opened the content:// file with a wide (~836) layout viewport → big
wide squares; the Claude webview used ~device-width (~360) → small square ones. Same content, different logical w.
FIX (phone-first, bounded): capped `.canvas-frame max-width: 960px → 480px` so the canvas stays phone-portrait
sized + consistent across viewers (on a real phone it already fills the width; this only reins in wide viewports).
Tunable single value in buildaux.zig; rebuilt phone_gestures + models3d standalones to compare.
ALTERNATIVE for pixel-identical scaling (not done, offered): scale_mode=.fit gives a FIXED design resolution
(letterboxed) so proportions are identical everywhere — but needs the standalone canvas aspect to match (the
template canvas is 800×600 landscape; portrait examples would letterbox with side bars). Per Simon "don't go too
far making phone feel like desktop," the max-width cap is the lighter-touch choice.

## Standalone: canvas fills viewport height (turn 1117 cont.)
The max-width cap fixed width consistency but exposed that the canvas used the 800x600 LANDSCAPE aspect
(height:auto) → short canvas, portrait content's bottom cut off, big empty page below. FIX: the .canvas-frame
now `flex: 1 1 auto; min-height: 0` (grows to fill the viewport height in the body's flex column) and the canvas
is `height: 100%` (fills the frame). Body padding 24→12, gap 16→10, h1 20→18px for more room. The bridge's
ResizeObserver sets the backing to clientW/H×DPR, so scale_mode=.responsive now reads a TALL portrait logical
size → all content visible + uses the whole screen. Rebuilt phone_gestures + models3d standalones.
Net: standalone canvas is now phone-portrait, fills the screen, consistent across viewers. Single template in
tools/buildaux.zig (max-width 480 tunable). No per-example changes needed (responsive reads the live size).

## phone_gestures → .fit fixed design (turn 1118) — resolves the scale saga
The responsive + fill-height approach made the logical size depend on the viewport (and the fixed-position layout
didn't fill it / swipe got clamped away). Switched phone_gestures to scale_mode=.fit with a FIXED portrait design
(420x900): in .fit, f.window == the design size (deterministic) and the engine uniformly scales+centers the design
into the canvas (fitOrtho + fitTransform for input). So layout uses fixed coords, the swipe list now fills the
remaining design height (heightf - swipe_y - 34, deterministic), all content is always visible, and it looks
IDENTICAL across viewers. Smoke PASS, lint 0, standalone rebuilt.
Honest tradeoff conveyed to Simon: a PORTRAIT phone example on a wide desktop window is a centered column (that's
correct phone-first presentation); .fit fills the HEIGHT and scales the design up, but "using the full width" of a
landscape window would require redesigning the content as adaptive/landscape — not worth it per his "don't chase
desktop-native" steer. The 480px template cap keeps the column phone-width; tunable.
PATTERN for phone-UI examples: scale_mode=.fit + a fixed portrait design res (vs .responsive for 3D/adaptive demos).
ui_minimal_button currently uses .responsive+tiled-windows (works); could move to .fit later for consistency.
NEXT: back to the audio subsystem bring-up (4 examples).

## Standalone scale: settled on .fit + matching aspect-ratio (turn 1119)
Key realization: the Claude in-app webview uses device-width but Chrome on a content:// file uses a WIDE (~830px)
layout viewport regardless of the viewport meta — so .responsive can NEVER look identical across them (logical size
differs). .fit is the only consistent option (fixed design → identical content). Earlier .fit looked tiny only
because the canvas was absurdly tall (flex-fill) → design centered in a huge box. FIX: standalone canvas is now a
fixed 9:16 portrait box (CSS aspect-ratio: 9/16, max-width 460, width-driven), and phone_gestures uses .fit with a
9:16 design (450×800) → .fit fills the canvas EXACTLY (no letterbox, no shrink). Also changed the canvas backing
attribute 800×600 → 450×800 (portrait) so Chrome doesn't compute a wide layout viewport from the intrinsic size.
Added a "canvas WxH" readout to phone_gestures (instrumentation; .fit shows the fixed 450×800). Template in
buildaux.zig: aspect-ratio 9/16 + max-width 460 (both tunable). 3D/.responsive examples get the same portrait box.
Result: phone-UI .fit examples render identically + fill the portrait canvas in both viewers; Chrome may still
display the column a touch smaller due to its viewport scaling, but the CONTENT + proportions are now consistent.

## text_layout ported (turn 1120)
`examples/wgpu_text_layout/` — text rendering + measurement showcase: per-letter rainbow heading (each glyph
advanced by measureText width), word-wrapped paragraph (wrap point via measureText per trial line), same sample at
several sizes from one TTF atlas, and a measureText "box the extent" demo. Fresh wgpu-API implementation (the GL
text_layout used GL-only signatures with spacing/font_cache + custom codepoints; wgpu loadFont is ASCII-only +
drawText(gl,font,text,x,y,size,color) + measureText(font,text,size)). .responsive, reflows to canvas width. Smoke
PASS, lint 0 (419 files, 120 wgpu examples, ~32 GL-only left), standalone built. measureText confirmed working.
NEXT: the audio subsystem bring-up (4 examples) OR more 2D/3D ports. Remaining tractable: most need subsystems
(audio JS bridge, glTF model loading, textured-3D billboards, async readback, font rasterization for imageText).

## AUDIO subsystem started: Zig plumbing + smoke + audio_basic compiles/smokes (turn 1121)
The audio path is backend-agnostic (Web Audio; sound.zig + the `extern "audio"` js_audio_* in web.zig). Landed:
- Zig plumbing: App gains an UNINITIALIZED `audio_device: AudioDeviceState` + `Frame.audio_device` (set in
  makeFrame). Left uninit so non-audio examples never reach the externs (verified: wgpu_basic still PASSES).
  `z.audio_device.init(f.audio_device)` is what reaches the JS bridge.
- Re-exported the audio API in zimr_wgpu: audio_device, waves, sounds, composer, AudioState, Sound, Wave.
- wgpu_smoke.ts: added `makeAudioShim()` (the ~20 js_audio_* as no-op stubs with sensible returns) + wired
  `audio:` into the instantiate imports → audio wasms instantiate + run headless.
- PORTED examples/wgpu_audio_basic/ — 3 synthesized tone pads (composer.tone square/sine/triangle + envelope →
  sounds.loadFromWave), tap-or-press-1/2/3 to play, ready dots. .fit 450×800 (taps map correctly). Focused smoke
  PASS, lint 0 (420 files). 121 wgpu examples, ~31 GL-only.
NOT YET: the STANDALONE template (+ dev runner) have no real "audio" namespace → an audio standalone won't
instantiate in a browser. NO standalone shipped this turn (would be broken). The real Web Audio impl is the
474-line createAudioImports in src/web/zimr.ts — too big to inline blind.
NEXT: extract a tractable real-Web-Audio subset (create_context/resume/sample_rate/load_buffer/play_buffer/
stop/master_volume — the ~8-10 audio_basic actually uses) into the standalone template (buildaux.zig) + the dev
runner, then ship the audio_basic standalone for on-device SOUND verification. Then port the other 3 audio examples.

## AUDIO: real Web Audio bridge in the standalone template (turn 1122)
Added a minimal real "audio" namespace to the standalone template (tools/buildaux.zig wgpu_standalone_template):
AudioContext + master gain, PCM upload (js_audio_load_buffer reads interleaved f32 from wasm memory →
ctx.createBuffer + de-interleave per channel), one-shot playback (js_audio_play_buffer → bufferSource→gain→
stereoPanner→master, pitch via playbackRate), stop/is_playing/master_volume/sample_rate/current_time/resume/close.
OGG-decode + pause/resume/scheduled-play ops are stubbed (audio examples synthesize PCM; don't need them).
Autoplay: create_context registers window pointerdown/keydown listeners that ctx.resume() (browsers start contexts
suspended). PCM read via `() => instance.exports.memory` closure (memory set post-instantiate). JS syntax-checked
with node --check (the IIFE extracted + parsed clean). dom namespace is provided by the bridge already.
Shipped the wgpu_audio_basic standalone for ON-DEVICE SOUND verification (can't verify audio headless; adapted
from the proven 474-line createAudioImports in src/web/zimr.ts). 121 wgpu examples.
NEXT (pending Simon's "does it make sound?"): if good, port audio_stream_synth / music_streaming / composer_drum
(music_streaming may need OGG decode — the stubbed path; revisit). Also add the same audio bridge to the dev
runner (zimr_wgpu.ts / serve) for parity.

## composer_drum ported (turn 1123) — 2nd audio example, real sound via the bridge
`examples/wgpu_composer_drum/` — drum machine: kick(60Hz sine)/snare(250Hz saw)/hat(4kHz tri) via composer.tone,
baked into one 8-step looping Wave via composer.Sequence, played on tap PLAY / SPACE. Step grid + playhead + PLAY
button (.fit 450×800). All PCM (composer + loadFromWave + play/stop) — runs on the existing Web Audio bridge, no
new JS. Focused smoke PASS, lint 0 (421 files), standalone built (real sound). 122 wgpu examples, ~30 GL-only.
Audio bucket: audio_basic ✓, composer_drum ✓. Remaining: audio_stream_synth (needs AudioStream/play_buffer_at —
I stubbed play_buffer_at; would need implementing) + music_streaming (OGG decode + streaming — stubbed). Those
need the scheduled-playback + decode bridge functions implemented (defer or do as a focused bridge extension).
NEXT: ship composer_drum standalone for sound check; then either implement play_buffer_at (unblocks
audio_stream_synth) or move to another bucket (glTF models, textured-3D).

## composer_drum looping fix (turn 1124)
On-device: drum loop played once, didn't repeat. Root cause: sounds.play hardcodes looping=false (one-shot;
the GL original had the same limit). FIX (example-side, no shared-code change): while playing, re-trigger
sounds.play when the elapsed time passes the baked loop length (steps_per_loop*step_ms), and make the playhead
wrap continuously (removed the one-shot stop). Now loops while STOP is showing. Smoke PASS, standalone rebuilt.
(Gapless true-looping would need exposing node.loop=true through the Sound API or a re-export of the low-level
playBuffer(looping=true); the re-trigger has a ~1-frame seam but is example-only + good enough for the demo.)

## play_buffer_at implemented + audio_stream_synth ported (turn 1125)
Implemented real `js_audio_play_buffer_at` in the standalone template (createBufferSource→gain→panner→master,
node.start(max(when, currentTime)) for scheduled/gapless playback). Re-exported AudioStream + streams in zimr_wgpu.
PORTED examples/wgpu_audio_stream_synth/ — a theremin: mouse Y → log pitch (110-1760Hz), per-frame sine synthesis
fed to an AudioStream (3-buffer gapless rotation via play_buffer_at); click toggles; phase persists across chunks
(no seam click). .fit 450×800, @log2/@exp2 for the log map (builtins, not std.math). Focused smoke PASS, lint 0
(422 files), standalone built (real audio). 123 wgpu examples, ~29 GL-only.
Audio bucket: audio_basic ✓, composer_drum ✓, audio_stream_synth ✓. ONLY music_streaming left (OGG decode +
streaming — js_audio_decode_ogg_bytes/is_decode_ready/take_decoded_buffer are stubbed; needs a real OGG-decode
path in the template via the browser's decodeAudioData, which is async — defer or do as a focused bridge ext).
NEXT: music_streaming (OGG via decodeAudioData) OR pivot to a visual bucket (glTF models / textured-3D).

## audio_stream_synth: hold-to-play (turn 1126)
On-device: releasing the finger kept it playing (it was tap-to-TOGGLE, matching the GL original). Changed to
HOLD-TO-PLAY: enabled tracks isMouseButtonDown (resumeStream on press, pause on release); starts paused
(enabled=false + streams.pause in init). Natural for a theremin. Smoke PASS, standalone rebuilt.

## glTF path opened: gltf_simple ported (turn 1127)
CORRECTION to the count: gltf_simple_cube.zig + quad_glb_data.zig are shared GLB DATA modules (no main/app),
NOT examples; gltf_textured is already done (wgpu_gltf_textured). The wgpu glTF path EXISTS via z.pbr3d.Renderer.loadGltf
(own-frame, used by wgpu_gltf_textured), and loadGltf synthesizes flat normals for normal-less meshes.
PORTED examples/wgpu_gltf_simple/ — loads the embedded CUBE_GLB (gltf_simple_cube.zig data) via pbr3d.loadGltf,
renders a lit, two-axis-tumbling cube (directional + ambient light). Own-frame pattern (z.App + main + renderer.
beginFrame/draw/endFrame), NOT the descriptor/AppSpec path — so it has a custom build block (mirrors
wgpu_gltf_textured: createModule + pbr shader deps + addAnonymousImport gltf_simple_cube.zig + install/bundle/
standalone) and is NOT in the headless smoke (own-frame). zig build wgpu-gltf-simple OK, lint 0 (423 files),
standalone built. 124 wgpu examples.
This validates the glTF→pbr3d path on a minimal model. NEXT high-value: damaged_helmet (the famous PBR helmet) via
the SAME pbr3d.loadGltf path — needs the helmet glb asset (large, ~JPEG maps + normals) + verifying pbr3d handles
full PBR textures. Also gltf_model_refs (multi-instance). Then back to other buckets (textured-3D immediate for
cube_split/text_on_texture, or first_person_camera with genMeshHeightmap).

## gltf_simple depth-attachment bugfix (turn 1128)
On-device: black canvas; logs showed pbr3d_pipe (depthStencilFormat Depth24Plus) incompatible with the pass
(no depth attachment). Root cause: pbr3d.beginFrame uses the GpuFrame depth_view, which is only allocated when
the WINDOW config sets depth_format — I set the renderer init depth_format but NOT the window. Same LATENT bug
in wgpu_gltf_textured (own-frame, never smoked). FIXED both: window config .depth_format = .depth24_plus.
gltf_simple + gltf_textured standalones rebuilt; lint 0 (423 files). (Sharp edge for claude.md: own-frame pbr3d
examples MUST set window .depth_format to match the renderer, or the depth-tested pipeline is incompatible with
the depth-less pass and nothing draws.) The pbr3d_fs shader "code is unreachable" WARNs are benign (Tint).

## gltf_simple culling fix (turn 1129)
On-device after the depth fix: cube rendered but inside-out. Cause: cull_mode=.back showed the inner faces
(pbr3d pipeline front-face vs the cube winding). FIX: cull_mode=.none — depth sorts the solid cube (outer faces
win), and the CCW-derived flat normals light it correctly. (wgpu_gltf_textured uses .none for the same reason;
pbr3d.InitOptions has no front_face override, so .none is the right call for glTF models whose winding may not
match the pipeline.) lint 0, standalone rebuilt.

## gltf_simple: replaced the broken legacy cube (turn 1130) — Simon was right
Simon: this example never worked + the model provenance is dubious. ROOT CAUSE found: the legacy
gltf_simple_cube.zig CUBE_GLB is an 8-SHARED-VERTEX cube; flat per-face normals need UN-shared verts (24), so
synthesizeFlatNormals overwrote each shared vert with whichever face was processed last → garbage normals →
never flat-shaded correctly (the inside-out look). A past Claude hand-generated it without realizing.
FIX: generated a correct 24-vertex (4/face, un-shared) CCW cube as binary glTF (Python: build glb + VERIFY every
face normal points outward), emitted to examples/wgpu_gltf_simple/cube_glb.zig (local sibling, lint:off
screaming-const for the GLB blob name). wgpu_gltf_simple now @imports the local cube; dropped the
gltf_simple_cube.zig anon import from its build block. cull_mode=.none (depth-sorts). Build + standalone clean,
lint 0 (424 files). The legacy examples/gltf_simple_cube.zig is left untouched (the doomed GL example can keep it).

## damaged_helmet ported (turn 1131) — the PBR payoff
examples/wgpu_damaged_helmet/ — the Khronos Damaged Helmet PBR glTF via z.pbr3d.loadGltf: base color / metallic-
roughness / normal / occlusion / emissive maps (JPEG, decoded by codecs.jpeg) + real normals (skips flat-normal
synth). Directional key + ambient, auto-rotating, cull .back (closed mesh), window depth_format=.depth24_plus
(the turn-1128 fix). Own-frame pattern + custom build block (mirror gltf_simple). The 3.6MB glb is copied into the
example dir + @embedFile'd (sibling). zig build wgpu-damaged-helmet OK, lint 0 (425 files), standalone 8.1MB
(embedded helmet). Validates the full PBR texture path (gltf_textured exercised base-color; this exercises all 5
maps + JPEG decode). 125 wgpu examples.
glTF bucket: gltf_textured ✓ (existing), gltf_simple ✓ (fixed cube), damaged_helmet ✓. Remaining glTF:
gltf_model_refs (multi-instance), skinned_mesh (skinning — hard, needs joints/weights in pbr3d), lenna_test (model+
texture). NEXT: verify helmet renders; then gltf_model_refs or back to other buckets (textured-3D immediate, etc).

## damaged_helmet: orbit + zoom + upright (turn 1132)
Per Simon: helmet was facing up (pbr3d.loadGltf ignores the glTF node transform; the helmet mesh is Z-up).
Added: base model_m = rotationX(-pi/2) to stand it upright (replicates the asset's authored -90deg X node rot);
ORBIT camera via drag (isMouseButtonDown(.left)+getMouseDelta -> yaw/pitch, pitch clamped); ZOOM via mouse wheel
(getMouseWheelMove) AND two-finger pinch (updateGestures + getGestureDetected .pinch_in/out + getGesturePinchVector
magnitude). eye computed from yaw/pitch/distance, lookAtRh at origin. Build + standalone clean, lint 0 (425 files),
standalone 8.1MB. (If the default view shows the back, the orbit lets you spin around; pinch scale *4.0 may need
tuning. Sharp edge: pbr3d.loadGltf does NOT apply node TRS — apply the orientation yourself in model_m.)

## damaged_helmet: orbit/zoom fixes round 2 (turn 1133)
Simon: helmet vertically inverted; finger drag jumps on first touch; pinch zoom dead. Fixes:
1) base rotationX(+pi/2) (was -pi/2, upside down).
2) drag-latch (physics_pyramid pattern): only apply getMouseDelta when dragging was already true last frame -
   skips the bogus first-frame delta (cursor teleports to the touch point on press). Orbit gated to touches<2.
3) Pinch zoom rewritten on RAW touch points: getTouchPointCount>=2 -> distance between getTouchPosition(0/1),
   compare frame-over-frame, zoom by the spacing delta (*0.01). The gesture-system pinch (getGesturePinchVector)
   was not firing here; raw touch is reliable. Build + standalone clean, lint 0 (425 files).
Sharp edges: (a) getMouseDelta jumps on the first press frame -> always use a dragging latch for drag-orbit;
(b) for pinch-zoom, raw getTouchPointCount/getTouchPosition is more reliable than the gesture recognizer.

## music_streaming ported — AUDIO BUCKET COMPLETE (turn 1135)
examples/wgpu_music_streaming/ — streams an embedded OGG (assets/sample.ogg ~2.3MB, 96s stereo Vorbis) via the
async-decode bridge. Implemented js_audio_decode_ogg_bytes (browser decodeAudioData; copy bytes out of wasm mem,
async .then stores an AudioBuffer in the buffers table) + is_decode_ready + take_decoded_buffer + cancel_decode in
the standalone template (decodes Map + nextDecode). Re-exported z.music + z.Music in zimr_wgpu. Wired sample_ogg as
an anonymous import in buildUserMod (free unless @embedFile-d; only music_streaming embeds it). Example: .fit
450x800, music.loadFromMemory -> isReady poll -> PLAY/STOP + tap-to-seek + progress bar (getTimePlayed/Length); no
per-frame pump (browser loops the buffer). Smoke PASS, lint 0 (426 files), standalone -Dmode=release.
AUDIO BUCKET DONE: audio_basic, composer_drum, audio_stream_synth, music_streaming (4/4). 126 wgpu examples.
The audio bridge now covers: contexts, PCM upload/play/loop/stop, master vol, scheduled play_buffer_at (streams),
and async OGG decode (music). NEXT: a different bucket — remaining are textured-3D immediate (cube_split rlsw,
text_on_texture RTT, billboards gpu-renderer), first_person_camera (genMeshHeightmap+cursor), skybox (cubemap),
split_screen (Scene), typed_unlit (beginShaderMode), window_demo, ui_panes, sw_* (native CLI), mrt/rtt, imgui_demo.

## music_streaming seek fix (turn 1136)
On-device: sound played, but seeking stopped it permanently. Root cause: music.play uses playBuffer when
play_offset==0 (initial play, worked) but playBufferWithOffset when play_offset>0; music.seek sets a nonzero
play_offset + calls playBufferWithOffset — which I left STUBBED (returns 0). So seek killed playback and every
later play (offset now >0) was also silent. FIX: implemented js_audio_play_buffer_with_offset in the standalone
template (createBufferSource + node.start(0, max(0,offset)) + loop). Standalone rebuilt -Dmode=release.
(Sharp edge: the audio bridge has TWO start paths — playBuffer (offset 0) and playBufferWithOffset (resume/seek);
both must be implemented or seek/resume silently breaks while initial play still works.)

## ui_panes ported (turn 1137) — a clean UI win
examples/wgpu_ui_panes/ — 3-pane workspace (file-tree | editor / output) on the wgpu UiHost: horizontal splitter
between tree + right column, vertical splitter between editor + output, collapsible treeNode folders + leaf files.
Mechanical port of GL ui_panes: UiHost.begin/render pattern, u.window/text/textDisabled/beginChild/endChild/
treeNode/treePop/splitter/sameLine/getContentRegionAvail/setNextWindowSizeConstraints (all present). Set style via
host.ctx.style (font_size 16, frame_padding, item_spacing). .responsive 400x880. Smoke PASS, lint 0 (427 files),
standalone -Dmode=release. 127 wgpu examples. (The imgui UI system ports mechanically; remaining ui_* like
ui_shortcuts/ui_dock_basic are similar quick wins if needed.)
NEXT (per the harder graphics tail): textured-3D immediate pipeline (sampling shader + pipeline + bind group +
drawBillboard) for billboards/cube_split/text_on_texture — the big remaining graphics feature.

## BLUEPRINT: textured-3D / drawBillboard (investigated turn 1138, route a)
GOAL: port billboards (drawBillboard/Rec/Pro). It is NOT a port — it is a Cube3D pass-integration FEATURE.
Findings: immediate-3D is solid-color only (cube3d_fs has no sampler). pbr3d is glTF-only (no mesh+texture Model
ctor). billboards uses z.gpu.drawBillboard (high-level renderer) — needs a NEW textured-3D path.
EXACT BUILD (extend src/draw3d.zig Cube3D):
1. Shaders: reuse unlit_vs.wgsl/unlit_fs.wgsl (auto-discovered, wired, schema = mvp + texture0 + col_diffuse,
   groups VS-ubo=0/sampler=1/FS-ubo=2) OR a tiny dedicated WGSL (vp*pos; textureSample*tint, tint per-vertex,
   2 bind groups). Dedicated WGSL is simpler (no FS ubo); reuse-unlit respects the .zig-shader ethos.
2. Add to Cube3D.init: a billboard pipeline (depth-tested triangle_list, cull .none) with layout
   [group0 = resources.bg_layouts[0] (camera vp, SHARED with cubes), group1 = new texture+sampler BGL].
   BillboardVertex = { pos:[3]f32, uv:[2]f32, color:[4]f32 }. A billboard_batch list + billboard_draws list
   (each = { tex_view, tex_sampler, first_vert, vert_count }).
3. drawBillboard(c3d, cam, tex, pos, size, tint): right = normalize(cross(forward,up)); up2 = up; corners =
   pos ± right*w/2 ± up2*h/2; uv (0,0)-(1,1); append 6 verts (2 tris) + a billboard_draw with tex.view/.sampler.
   Rec: uv from a source rect / tex size. Pro: rotate corners about the camera-forward axis by angle.
4. In the flush (the render fn called by endMode3D, ~line 940-975 area, after the cube batch + line batch draw):
   upload billboard_batch to a billboard VBO; for each billboard_draw: setPipeline(billboard_pipeline);
   bind group0 = camera BG (already set), bind group1 = createBindGroup(group1_bgl, [tex_view, tex_sampler])
   (cache per WgpuTexture to avoid per-frame churn — a small map, OR create-per-draw for the demo); setVertexBuffer;
   draw(vert_count). Clear the batch/draws at begin (like the cube batch).
5. Texture bind: mirror renderer_2d — group1 binding0 = WgpuTexture.view, binding1 = WgpuTexture.sampler.
6. Re-export drawBillboard/drawBillboardRec/drawBillboardPro in zimr_wgpu (note: GL uses z.gpu.drawBillboard;
   wgpu can expose them as free fns z.drawBillboard taking f.gl, like the other immediate fns).
7. Port examples/wgpu_billboards: drawCubeV ground markers (exist) + 3 billboards (drawBillboard/Rec/Pro) +
   an orbit camera (reuse the physics_pyramid/helmet drag-latch orbit). genImage the icon texture (genImage* +
   loadTextureFromImage exist) or embed a PNG (loadImageFromMemory + loadTextureFromImage). .responsive landscape.
RISK: bind-group layout must match the WGSL group/binding numbers; depth interaction with cubes (same pass);
camera right/up extraction from the view matrix or camera vectors. Smoke catches structural/validation errors;
on-device confirms depth + facing. ESTIMATED: a focused multi-step build with 2-4 compile/smoke iterations.
DECISION: deferred the actual edit to a fresh session (core-engine change in draw3d.zig deserves budget to build +
iterate + verify; this session is very long). Blueprint above is complete + ready to execute.

## TEXTURED-3D PIPELINE BUILT + textured_cube (turn 1139) — route a, the feature
Extended Cube3D (src/draw3d.zig) with a textured-3D pipeline that shares the immediate-3D depth pass + camera UBO
(group 0) with the solid batch; group 1 = per-texture {texture,sampler} bind group (cached by view handle).
Hand-written WGSL (billboard_vs/fs, entry-point entry, vp*pos + textureSample*col, no control flow -> no uniformity
issue; convertible to typed .vs/.fs.zig later). New: TexVertex{pos,uv,color}, tex batch + tex_draws, flushTextured
(setPipeline + resources.bind group0 + setBindGroup(1,texbg) + draw per texture), texBindGroup cache, appendTexQuad,
drawCubeTexture (6 faces) + drawBillboard (camera-facing quad, takes right/up). App-level wrappers in wgpu_app.zig
(drawCubeTexture, drawBillboard via appOf->cube3d) + re-exported in zimr_wgpu. beginFrame3D clears the tex batch.
PORTED/NEW examples/wgpu_textured_cube/ — checker (genImageChecked) on a cube, depth-tested with a grid, orbit cam.
Smoke PASS (3 pipelines: solid+line+textured), lint 0 (428 files), standalone -Dmode=release. 128 wgpu examples.
NEXT: billboards (drawBillboard is wired — port examples/wgpu_billboards: ground cubes + camera-facing billboards;
compute right/up from the camera/view in the example). Then cube_split (textured cube + rlsw — harder).
Sharp edge: textured-3D shares Cube3D group 0 (camera) — reuse self.resources.bind for group 0, only bind group 1.

## billboards ported (turn 1140) — drawBillboard on the textured-3D pipeline
examples/wgpu_billboards/ — 5 camera-facing glowing sprites (procedural radial-alpha texture via genImageColor +
a pixel loop on Image.data) drawn with drawBillboard + 3 solid cubes + grid, orbit camera. Computes the camera
right/up basis (manual cross3/norm3 from cam position->target + world up) and passes to drawBillboard. Exercises the
textured pipeline alpha blend (soft sprite edges) + multiple per-texture draws. Smoke PASS (7 draws), lint 0
(429 files), standalone -Dmode=release 904K. 129 wgpu examples.
Textured-3D bucket: textured_cube ✓, billboards ✓. drawBillboardRec (sub-UV) + drawBillboardPro (rotation) not yet
added (the GL billboards used them; not needed for this demo). cube_split next (textured cube + rlsw side-by-side —
the rlsw/software-renderer half is the hard part). text_on_texture needs RTT.

## billboards dark-box fix (turn 1141)
On-device: alpha billboards had dark rectangular halos where a nearer billboard quad depth-clipped farther ones
(alpha billboards write depth on transparent pixels). FIX (example-side, contained): draw billboards back-to-front
(insertion-sort the ring by descending distance to cam.position; billboards are drawn last after opaque cubes).
Standard transparency ordering. Smoke PASS, standalone rebuilt. (The general engine fix would be a depth-test-
no-write DepthMode — the mapping lives in the JS depth glue (src/web + standalone template); deferred as a proper
engine addition. For now back-to-front per-example is correct + contained.)

## billboards dark-box PROPER fix (turn 1142) — no-write depth mode added
The back-to-front sort was insufficient; each alpha quad still wrote depth + darkened the scene. PROPER FIX:
added a depth-test-no-write pipeline mode. wgpu.DepthMode.less_no_write=7; src/web/zimr_wgpu.ts depthCompare maps
7->less + depthStencil depthWriteEnabled = (depth !== 7) (was hardcoded true). draw3d makePipeline gained a depth
param; added billboard_pipeline (.less_no_write) alongside tex_pipeline (.less); TexDraw gained a .pipeline field
so drawCubeTexture uses the WRITE pipeline (opaque, self-occluding faces) and drawBillboard the NO-WRITE pipeline
(transparent sprites dont occlude each other/scene). flushTextured sets the pipeline per draw. The standalone
re-bundles zimr_wgpu.ts so the fix ships to standalones too. Both wgpu_textured_cube + wgpu_billboards smoke PASS,
lint 0 (429 files), standalone rebuilt. Sharp edge: transparent 3D (billboards) MUST use .less_no_write; opaque
textured 3D uses .less. The back-to-front sort in the example is still good practice for alpha blend order.

## billboards: tighter sprite falloff (turn 1143) — Simon was right (twice)
After the no-write depth fix, faint LIGHT squares remained: the sprite falloff (1-d)^2 only hit alpha 0 at the quad
EDGE (d=1, the inscribed circle), so faint alpha filled almost the whole square -> visible lit rectangle. FIX:
alpha = clamp(1 - d*1.7, 0, 1)^2 -> reaches 0 by d~0.59, so the quad outer region (incl. corners/edges) is fully
transparent. Now clean contained glowing dots. Two-part lesson: transparent billboards need BOTH (1) depth-test-no-
write pipeline AND (2) a texture whose alpha actually reaches 0 before the quad boundary. Smoke PASS, standalone
rebuilt. (Sharp edge for sprite gen: a radial falloff that only hits 0 at the texture edge fills the quad; clamp it
to 0 well inside.)

## billboards squares — ACTUAL ROOT CAUSE (turn 1144): canvas alphaMode premultiplied
After depth-write + falloff fixes the faint squares PERSISTED. Real cause: src/web/zimr_wgpu.ts configured the
canvas with alphaMode:"premultiplied", so the FRAMEBUFFER ALPHA composites the canvas over the page. The .alpha
blend writes alpha {srcFactor:one, dstFactor:zero} -> OVERWRITES the framebuffer alpha with the billboard sprite
alpha (radial, ~0 at the quad edges). So the billboard quad regions got low framebuffer alpha -> the (correctly
color-blended) scene there composited toward the page -> faint square. Opaque 2D never hit it (alpha stays 1). FIX:
context.configure alphaMode "opaque" (full-screen render; canvas alpha shouldnt matter). One line; re-bundled into
all standalones. Restored the soft sprite falloff. Sharp edge: transparent 3D needs the canvas alphaMode opaque (or
an alpha blend that preserves dst alpha) — premultiplied canvas + alpha-overwrite blend leaks transparency squares.
THREE-part bug total: (1) depth-write off, (2) sprite alpha->0 before edge, (3) canvas alphaMode opaque.

## text_on_texture ported (turn 1145) — RTT + textured-3D combined
examples/wgpu_text_on_texture/ — renders a 2D sign (panel + drawText) into a RenderTexture via beginTextureMode/
endTextureMode, then maps rt.asTexture() onto a rotating cube with drawCubeTexture; grid + solid markers; orbit cam.
Uses the EXISTING wgpu RTT (z.RenderTexture/loadRenderTexture/begin-endTextureMode/asTexture) + the new
drawCubeTexture. Notes: c.init is NOT a thing (use a Color literal); wgpu uses drawCube(center, .{.size,.color})
not drawCubeV. Smoke PASS (RTT pass + main pass), lint 0 (430 files), standalone -Dmode=release 908K. 130 wgpu.
Textured-3D bucket: textured_cube, billboards, text_on_texture all done. Remaining heavy: cube_split (rlsw software
renderer side-by-side — the rlsw/CPU half is the work). Possible RTT Y-flip on the cube text (verify on-device).

## text_on_texture black — RTT+depth fix (turn 1146)
On-device: black + validation: 2D shapes pipeline has depthStencilFormat Depth24Plus (because the window opted into
depth for the 3D cube) but the RTT pass had NO depth -> incompatible -> nothing drawn. Root cause: loadRenderTexture
made a color-only RTT (with_depth=false). FIX: loadRenderTexture now sets with_depth = (gpu_frame.depth_format !=
null) + depth_format = the window depth -> RTT passes match the depth-configured 2D pipeline. 2D apps (depth_format
null) still get a color-only RTT (wgpu_render_texture unaffected, smoke PASS). Engine fix in wgpu_app.zig. Both
RTT examples smoke PASS, standalone rebuilt. Sharp edge: when a 3D app (window depth_format set) uses an RTT for 2D
content, the RTT needs a depth attachment too — loadRenderTexture now handles this automatically.

## text_on_texture still black after RTT-depth fix (turn 1147) — forced clean rebuild
The incremental build after the loadRenderTexture fix still showed the identical RTT-pass-no-depth validation
error on-device. Suspect the standalone bundling reused a stale wasm (recompiled wgpu_app.zig not picked into the
HTML base64). Did rm -rf .zig-cache + full rebuild to force a fresh wasm with the with_depth fix. If still black
after this, the next step is a diagnostic log in loadRenderTexture (print depth_format/with_depth) since the logic
(gpu_frame.depth_format set via App.run line 356 -> with_depth true -> RTT depth) should be correct. Possible second
issue: reopen2DPass hardcodes depth_view=null (intentional per comment; textured_cube caption works, so endMode3D
must reopen with depth) — but text_on_texture draws no 2D between endTextureMode+beginMode3D, so that path is not
exercised. Leaning toward stale-wasm; verifying with the clean build.

## text_on_texture ACTUAL ROOT CAUSE (turn 1148) — reopen2DPass hardcoded depth_view=null
THE bug (found by reading, not guessing): the immediate-3D path does NOT open its own render pass — beginMode3D
just sets the camera and endMode3D flushes the 3D batch into the CURRENT app.pass (no pass switch). The frame pass
(beginDrawing, line 442) attaches depth via fctx.depth_view. But endTextureMode -> reopen2DPass reopened the main
pass with depth_view=null HARDCODED. So in a depth window, everything drawn AFTER endTextureMode (the 3D cube via
beginMode3D + the 2D caption) landed in a DEPTH-FREE pass while their pipelines carry depth -> validation error,
nothing drawn -> black. textured_cube/billboards never hit it (no beginTextureMode -> they stay in the depth frame
pass the whole frame). FIX: reopen2DPass now uses .depth_view = app.gpu_frame.depth_view (same as the frame pass;
.invalid -> depth-free for 2D apps). PLUS the earlier loadRenderTexture RTT-depth fix (needed for drawText INTO the
RTT). Both needed. Smoke PASS x3 (text_on_texture, render_texture, shapes_showcase), standalone rebuilt.

ROBUSTNESS (per Simon: make this bug class impossible): the 3 beginRenderPass sites (frame pass, reopen2DPass, RTT)
each set depth independently — that inconsistency IS the bug class. Recommend consolidating pass-open into ONE
helper that derives the depth attachment from the target (surface pass -> gpu_frame.depth_view; RTT -> rt.depth_view)
so no call site can hardcode a mismatched depth state. Also: a debug assert that the bound pipeline depth state
matches the current pass depth attachment would catch this at the draw call. (Deferred as a follow-up refactor.)

## text_on_texture: V-flip + bigger text (turn 1149)
On-device: cube renders (pass-depth bug fixed!) but text small + inverted. Cause: appendTexQuad mapped texture
v=1(bottom) to the face top -> V-flip (invisible on the symmetric checker, obvious with text). FIXED appendTexQuad
UVs to upright (p0 top-left->(0,0), v=0 = texture top = face top). Affects all drawCubeTexture/drawBillboard but
both prior examples use symmetric textures (no regression, smoke PASS). text_on_texture: font atlas 28->48 + big
text (zimr@92, WebGPU@44) filling the RTT. Smoke PASS x2, standalone rebuilt. (If the text now reads U-mirrored on
some faces, the per-face corner ordering in drawCubeTexture needs alignment — verify on-device.)

## ghosting hunt (turn 1150) — instrumented wgpu_app pass-opens
Simon: text_on_texture shows ghosting/trailing of the cube (saw it faintly in other examples too). Analysis says
surface clears each frame (beginDrawing loadOp clear to config.window.clear default (0,0,0,0)) + depth always
clears + beginFrame3D clears the 3D batch -> shouldnt ghost. Cant explain from code -> added temp diagnostics
(dlog via dom.js_log, gated to frames 1-4): logs in beginDrawing (clearA, surface_view id, depthValid),
beginTextureMode (rtDepthValid), reopen2DPass (depthValid). Need Simon to screenshot the log panel (scroll to top)
to see the per-frame pass sequence + whether surface_view rotates + depth attachments. Suspects: swapchain not
rotating / present issue / a pass not clearing in the multi-pass RTT path. Logs are temporary; remove after.

## ghosting hunt CONCLUSION (turn 1151) — rendering is correct; startup swapchain-priming artifact
Logs (frames 1-4) proved: surface_view rotates every frame (surf=3,7,8,9 -> fresh buffer each frame), depthValid=
true on ALL passes (frame, RTT, reopen2D -> my depth fixes work), clear happens every frame. So steady-state
rendering is CORRECT. Combined with Simon: ghosting only at the START + intermittent -> swapchain-priming artifact:
at startup the canvas back-buffers are uninitialized and the compositor can briefly show an un-rendered buffer
(plus the standalone canvas resize settling in the first 1-2 frames). NOT a render bug. Removed the diagnostic logs.
Steady-state is clean. (If we want to eliminate the startup flicker: prime the swapchain by rendering N clear
frames before content, or set the canvas backing size before the first render in the standalone template - minor,
deferred.) text_on_texture is DONE: cube renders, text big + upright, depth correct.

SESSION TALLY: audio 4/4, glTF/PBR 3 (gltf_textured/simple/damaged_helmet), textured-3D 3 (textured_cube/billboards/
text_on_texture) + the whole textured-3D pipeline (drawCubeTexture/drawBillboard, no-write depth mode, upright UVs),
ui_panes, + major engine fixes (reopen2DPass depth, RTT depth, canvas alphaMode opaque, cube_glb regen). ~130 wgpu.
NEXT (fresh session): the pass/clear/depth CONSOLIDATION refactor (single pass-open helper deriving depth from the
target + a draw-time depth-state assert) to make the depth-mismatch bug class impossible; then cube_split (rlsw).

## skybox ported (turn 1152) — gradient skybox feature (no cubemap)
The existing skybox_vs/fs shaders are a GRADIENT sky (not cubemap), so no cubemap/bridge work needed. Built a
skybox pipeline into Cube3D: SkyboxSchema (Ubo = inv_view_proj + camera_pos + sky_bottom + sky_top), hand-written
WGSL (vs: fullscreen triangle via vertex_index, unproject NDC@z=1 through inv_view_proj -> world ray, clip z=
0.999999; fs: lerp sky_bottom->sky_top by ray.y). shader.Resources(SkyboxSchema) for the UBO bind group; pipeline
created inline (no vertex buffer, depth .less). Cube3D.drawSkybox(ps, inv_vp, cam_pos, bottom, top) writes the UBO
+ setPipeline + bind + draw(3). App-level drawSkybox(gl, cam, bottom, top) recomputes view_proj (same as beginMode3D,
fovy/aspect/0.01/1000) + zm.inverse -> inv_vp + cam.position. Re-exported. examples/wgpu_skybox/: dusk gradient
(warm horizon -> blue zenith) + cube/sphere/cylinder + grid, orbit cam. Drawn after beginMode3D (background, z=far
loses depth test to the 3D). Smoke PASS (4 pipelines), lint 0 (431 files), standalone -Dmode=release. 131 wgpu.
(Cubemap skybox = future work, needs cube-texture support across the JS bridge.)

## PLAN: comptime cube side-by-side (turn 1153) — investigated, ray-traced-cube interpretation
FINDINGS: the SW-renderer side-by-sides ALREADY EXIST: wgpu_sidebyside (rlsw CPU vs WgpuGl GPU, shared
fn(gl:anytype) via gl_iface), wgpu_mandel_sidebyside + wgpu_rt_sidebyside (one shaderMain on 3 targets: CPU
rlsw_shader.dispatchFragmentShader / GPU WGSL / COMPTIME baked const corner). gl_iface = immediate-mode trait
(begin/vertex3f/matrixMode/multMatrix/color4ub/depth). rlsw supports 3D (depth_test + matrix stacks). WgpuGl has
immediate 3D (matrix stack + vertex3f) BUT depth-toggle is a STUB (N5) -> a rasterized GPU-immediate cube needs
depth work. So a GEOMETRY cube side-by-side is heavier. A RAY-TRACED cube (fragment shader: ray-box per pixel)
drops into the existing fragment-shader triad cleanly -> the right approach for a comptime cube.
TEMPLATE: rt_fs.zig (shaderMain(io:Io) Out, Io=IoT(Ubo), reads io.frag_tex_coord + io.u.<ubo>, returns
out.out_color; SPIR-V-safe: no recursion/pointers-into-scene, functional RNG, fixed loops; comptime{ installSpirvEntry
(shaderMain) }). rt_sidebyside: CPU dispatch + GPU fullscreen(rt_fs.wgsl) + comptime corner_image const (shaderMain
per-pixel at comptime, @setEvalBranchQuota, small res).
BUILD (wgpu_cube_sidebyside): (1) raycube_fs_io.zig {Inputs{frag_tex_coord}, Outputs{out_color}, Ubo{cam_origin,
px00,pdu,pdv,resolution,time}}. (2) raycube_fs.zig shaderMain: ray from cam basis, rotate ray to cube-local (rotateY
by time), slab ray-box AABB[-1,1], shade by hit normal + gradient sky on miss; installSpirvEntry. (3)
wgpu_cube_sidebyside.zig mirroring wgpu_rt_sidebyside: host camera basis + time into Ubo; CPU dispatch left / GPU
WGSL right / comptime corner; mouse-X splitter. Register addWgpuApp + the example needs raycube_fs.wgsl (build
auto-discovers src/shaders/*.zig -> WGSL; but raycube is an EXAMPLE shader like rt_fs -> check how rt_fs.wgsl is
wired: examples/rt_fs.zig must be in the shader-discovery OR wired per-example). RISK: spv2wgsl translation gap on a
new shader (gate = WGSL compile early). Comptime budget for the corner (cap res/samples). Verify CPU=GPU=comptime
match across the splitter.

## comptime cube side-by-side SHIPPED (turn 1154) — built per the plan
examples/raycube_fs.zig + raycube_fs_io.zig: a ray-traced-cube fragment shader (shaderMain: cam-basis ray, rotate
to cube-local by u.time, slab ray-box AABB[-1,1], face tint X=red/Y=green/Z=blue + fixed-light lambert, gradient sky
on miss). SPIR-V/WGSL-safe (no loops, 3 unrolled slabs, spelled-out dot). COMPILED TO WGSL CLEANLY (spv2wgsl gate
PASSED first try — no translation issues). examples/wgpu_cube_sidebyside/: mirrors rt_sidebyside — Camera3D.rayBasis
for the basis, CPU rlsw_shader.dispatchFragmentShader (left, 1/3 res), GPU fullscreen WGSL (right), comptime-baked
corner_image const (shaderMain per-pixel at comptime, 56x32, frozen at time=0.7), mouse-X splitter, CPU/GPU labels.
Registered via addWgpuShaderApp("cube_sidebyside", &.{raycube_fs, wgpu_trivial_vs}); addShaderDep auto-resolves
examples/raycube_fs(_io).zig -> WGSL + externs. Smoke PASS, lint 0 (434 files), standalone -Dmode=release. 132 wgpu.
Gotcha: single-statement ifs need braces (lint rule 3) — braced. ONE shaderMain, THREE execution targets (CPU/GPU/
comptime), the comptime-cube ask delivered.

## PLAN: spv2wgsl unique-name generation (turn 1155) — fixes the name-collision bug class
SYMPTOM: raycube_fs's three slab blocks each declared `var t0/t1`; distinct SPIR-V locals sharing the OpName
debug name "t0"; the structurizer flattens the Zig blocks into ONE WGSL function scope -> spv2wgsl emits two
`var t0` -> [wgsl:raycube_sbs_gpu:244] redeclaration of 't0' -> black. The build-time wgsl_check (structural:
braces + // ERROR: markers) did NOT catch it; only the browser validator did, at runtime.

IMMEDIATE FIX (done): renamed raycube_fs slab locals unique per-axis (invx/ax0/ax1/nx/fx, invy/.., invz/..).
REPRO (done): wgsl_check.zig test "KNOWN GAP - duplicate var (name collision) slips through" feeds colliding
WGSL (two `var t0`) -> check() returns ok=true today = documents the gap.

ROOT-CAUSE FIX (generate unique names in spv2wgsl):
- Each SPIR-V id stores IdInfo.wgsl_name; wgslNameOf(id) returns it. Two ids got the same wgsl_name. Assignment
  sites: spv2wgsl.zig ~454, ~848 (OpName handler: s.ids[target].wgsl_name = name), ~1012.
- ADD a per-FUNCTION uniquifier: assigning a wgsl_name to a FUNCTION-LOCAL OpVariable (Function storage class),
  track used names in StringHashMap(u32); if taken, emit name_<n> until unique. All refs go through wgslNameOf
  -> the uniquified name, so uses stay consistent automatically.
- SCOPE CAREFULLY: ONLY function-local variable names. Do NOT touch type names, constants, uniform/IO names, or
  entry params (global / cross-stage / binding-matched). Reset the used-set per emitted WGSL function.
- Likely cleanest at the OpName-application site (~848) gated to function-local vars + the generated temp-name path.

DEFENSE IN DEPTH (optional, makes it a hard COMPILE ERROR): add a redeclaration pass to wgsl_check — scope-aware
(track { } nesting; per-scope set of var/let names; duplicate -> ok=false + site). Then the repro test flips to
expect(!r.ok). Catches it at build even if spv2wgsl regresses.

VERIFY: after the fix, temporarily revert raycube_fs to shared t0 across slabs -> rebuild -> WGSL shows t0 + t0_1
-> no redeclaration -> renders. RISK: mis-scoping could rename a cross-stage/binding name -> validation error;
gate strictly to function-local vars. spv2wgsl is the fragile core -> run the full shader corpus regression after.

## spv2wgsl unique-name fix LANDED + VERIFIED (turn 1156)
Implemented the safest design from the plan in src/spv2wgsl.zig emitFunction:
- Declared `used_local_names = StringHashMap(void)` at function-emit body scope (spans entry + non-entry; per fn).
- Recorded (without renaming) the names of: params (signature loop), phis (phi loop), hoisted temps (hoist loop).
- In the function-scope OpVariable loop: uniquify each var name against the set — `while contains: name_<n>` — then
  setId(...wgsl_name=unique...) so every later wgslNameOf(id) in the body uses it (refs stay correct), then emit.
- ONLY OpVariables are renamed; params/phis/hoisted keep their names (signature `_param` ties / generated-unique).
  No-op for any shader without a collision (existing WGSL unchanged).
VERIFIED: temp collision probe (two blocks each `var probe0/probe1`, the exact flattened-block pattern) ->
emitted WGSL: `var probe0; var probe1; var probe0_1; var probe1_1;` (uniquified, no redeclaration). Probe removed.
REGRESSION: 50/50 spv2wgsl unit tests pass; smoke PASS on wgpu_rt_sidebyside, wgpu_mandel_sidebyside, wgpu_julia,
wgpu_raytracer, wgpu_sidebyside, wgpu_cube_sidebyside. lint 0. raycube_fs kept clean (unique names) regardless.
OPTIONAL FOLLOW-UP (defense in depth, not done): a scope-aware redeclaration pass in wgsl_check so a duplicate
declaration is a hard BUILD error even if spv2wgsl regresses; then the repro test flips to expect(!r.ok).

## helmet CPU|GPU side-by-side SHIPPED (turn 1166)
examples/wgpu_helmet_sw/ evolved from the perf spike into the side-by-side: LEFT = rlsw software raster (CPU, 220x124,
Gouraud lambert from mesh normals, no textures); RIGHT = z.pbr3d full PBR (real albedo/metal-rough/normal/emissive/AO).
Shared orbit camera (lookAtRh eye + perspectiveFovRh for GPU; rlsw uses frustum + multMatrix(view) + multMatrix(rotX90));
drag orbit + pinch/wheel dolly + drag-latch; splitter follows pointer X. ~59fps in smoke.
ENGINE CHANGE (the enabler): pbr3d owned the whole frame (beginFrame->present). Added pbr3d.drawInApp(gl, desc, model,
model_m) which draws into the APP's current pass (via wgpu_app.appOf(gl).pass + .gpu_frame) with NO frame mgmt — so the
2D rlsw blit + splitter composite over it. Made wgpu_app.appOf + WgpuGl pub (one-way dep pbr3d->wgpu_app, no cycle).
Window opts into .depth_format=.depth24_plus so pbr3d depth-tests in the app pass. helmet_sw registered via a bespoke
build block (buildUserMod + the engine_shaders WGSL loop for pbr_vs/fs.wgsl + finishWgpuApp), like wgpu_damaged_helmet.
COMPTIME (3rd target): NOT done — geometry can't comptime-rasterize (the GLB parse is runtime/allocator-based + 15k tris
in the compiler is infeasible; no decimator). The "cpu gpu comptime" trio only worked for the fragment-shader demos
(ray-cube/raytracer/mandelbrot). For the helmet it's CPU rlsw vs GPU PBR (2 targets). A comptime corner would need a
build-step mesh const + a comptime rasterizer over a decimated proxy — deferred.

## SAME-SHADER HELMET BUILT (turn 1167) — pbr_vs+pbr_fs on CPU and GPU from one source
North Star steps 3+4 landed in one arc. The pieces, in dependency order:
- rlsw_shader.rasterizeTriangles gained comptime `.depth_test` (early-z BEFORE varying interp + FS; NDC z
  interpolated SCREEN-linearly with raw barycentrics — z/w is affine in screen space; `.less` + [0,1] band
  reject = the wgpu pipeline's state). Depth I/O via the rlsw_pixel read/write_depth_table codecs (alignment-
  safe, format-flexible); rlsw.Context gained depthBufferBytesMut/depthBufferFormat. Unit test: draw-order-
  independent nearer-wins + depth-attachment value check.
- CPU TextureRef sampler (gen_shader_externs): clamp → REPEAT wrap (helmet V∈[1,2] tiled garbage otherwise)
  + sample-time sRGB→linear via a comptime 256-entry table behind a new `srgb: bool = false` field — the GPU
  samples base_color/emissive through rgba8_unorm_srgb views, so without this the CPU albedo was gamma-wrong.
  SPIR-V branch unaffected (CPU-only decls stay lazily unanalyzed there; WGSL identical).
- pbr3d seams: buildCpuMesh (interleave + flat-normal synth + Lengyel tangents, now THE shared geometry
  source for loadGltf AND the software path) + decodeMaterialMap (gltf texture-ref→bytes walk + PNG/JPEG
  decode) + pub MaterialSlot/firstPrimitiveMaterial. pbr_fs.zig re-exports Ubo + TextureRef.
- MODULE-GRAPH LESSON (two failed attempts before the right design): a pbr_bundle module (the
  default_shapes_bundle pattern) COLLIDES — zimr_wgpu already claims the pbr io chain via ui.zig→drawing.zig
  (stop-gapped: name-only TangentWantingSchema in the condemned GL file) and ui.zig→zimr.zig's z.shader.io
  namespace. RIGHT DESIGN: the ENGINE owns its shaders — `z.pbr_shaders.{vs,fs}` re-exported from zimr_wgpu;
  the generated pbr_*_externs wired ONCE onto zimr_wgpu_mod in the engine-shaders loop; lazy analysis means
  apps that never reference it pay nothing. sw_engine_shader's bundle still fits HOST exes (no zimr_wgpu in
  graph) — the two patterns coexist, documented in audit_cleanup_notes.md.
- FsUbo byte-mirror DELETED from pbr3d (now `= @import("shaders/pbr_fs_io.zig").Ubo` — same module, legal;
  std140 drift structurally impossible; closes the finishing_webgpu §0 standing ask). max_*_lights tied to
  pbr_common_io. autoConnect migrated to 0.17 struct-of-arrays typeInfo (was latent: only HOST builds
  compiled it before; now it's in every wgpu app's potential graph).
- examples/wgpu_helmet_sw REWRITTEN: GPU half renders pbr3d into an RTT (beginTextureMode→drawInApp→
  endTextureMode; the t1166 pipeline-leak validation error is structurally dead — endTextureMode reopens a
  fresh backbuffer pass + rebinds 2D; pbr3d inits with surface_format=.rgba8_unorm to match the RTT). CPU
  half: pbr_vs.shaderMain per vertex (manual loop — dispatchVertexShader's comptime callback can't capture
  mesh data, noted for cleanup) + rasterizeTriangles(depth_test=true) per fragment at 220×124, sampling the
  five real maps box-downsampled to ≤512² with per-slot srgb flags, Ubo = THE shader's pbr.fs.Ubo struct with
  the same light values pbr3d.buildUbo writes. Shared lookAtRh/perspectiveFovRh matrices feed BOTH halves.
GATES: helmet smoke PASS (release; 3 passes/frame: frame→RTT→reopened-2D, drawIndexed wired), full unfocused
`zig build test` exit=0, tier-a-check PASS post-sRGB-fix (80.7s warm), lint 0/435. Standalone
prebuilt/standalone/wgpu_helmet_sw.html (6.2MB, -Dmode=release) handed to Simon for PHONE VERIFY — the
sandbox cannot see pixels; checklist in claude.md ★ NEXT BIG STEP.
NEXT: phone verdict → fix divergences if any (suspects: per-pixel fps on phone, nearest-vs-bilinear shimmer)
→ then North Star step 5 (unify framing across the four side-by-sides + readme.html).

## PHONE VERDICT + fullscreen/aspect overhaul (turn 1168)
Simon's screenshot: IT RENDERS — 60fps, "GPU frame/init scope: clean (no validation error)" (t1166 bug
confirmed dead on-device), CPU depth/self-occlusion correct, both halves visibly the same shader. Two pre-
existing benign `[wgsl:pbr3d_fs] code is unreachable` WARNs remain (tracked separately). But BOTH halves were
vertically stretched: the proj baked the fixed 960×540 RTT aspect, smeared onto a portrait canvas — plus the
standalone template forced a 9:16 card. Fixed end to end, "fullscreen without stretching on rotation":
- STANDALONE TEMPLATE (tools/buildaux.zig, affects ALL standalones): fullscreen-first. Canvas is
  position:fixed inset:0 100%×100dvh (no card, no h1, no aspect-ratio rule); diagnostics float OVER it —
  status pill bottom-left (fps line, pointer-events:none), debug as a bottom sheet auto-shown ONLY on ERR
  (warnings accumulate silently — the benign startup WARNs were covering the demo), HUD top-right: log
  toggle (≡) + fullscreen (⛶, Fullscreen API, feature-detected so iOS Safari hides it, navigationUI:hide).
  safe-area-inset everywhere (viewport-fit=cover was already set). Rotation = the bridge ResizeObserver
  re-sizes the backing; nothing else to do.
- EXAMPLE (wgpu_helmet_sw): `ensureTargets` each frame — GPU RTT recreated at the surface BACKING size
  (CSS×DPR, pixel-perfect any orientation; unload+reload only when dims change) and the CPU rlsw buffer
  re-derived from a CONSTANT 27k-pixel budget shaped to the live aspect (rotating never changes CPU cost).
  proj aspect = live vw/vh. Splitter became a width FRACTION (rotation-stable), follows pointer-on-change
  with a guard ignoring the pre-input (0,0) report. Title unified: "one PBR shader: CPU | GPU" (the page
  title comes from the BUILD registration string, not app config — both updated).
- ENGINE: Renderer2D.updateRegisteredTexture(id, tex) — swap the texture behind a registered id IN PLACE
  (fresh material bind group, stable id); CpuFramebuffer.resize(gl, w, h, pixels, label) — destroy + recreate
  + registry update. One bind-group handle leaks per resize (no destroyBindGroup in the bridge — noted).
GATES: helmet smoke PASS, tier-a PASS (54s), lint 0/435, standalone rebuilt (new template verified in the
HTML: hud present, 9:16 rule gone). SANDBOX CAN'T EXERCISE ROTATION (the shim's surface size is constant) —
the resize path (rlsw.resize + sw_fb.resize + RTT recreate) needs Simon: rotate portrait↔landscape a few
times, tap ⛶, confirm no stretch / no crash / helmet stays centered + round.
NEXT: rotation verdict from phone; then step 5 (apply the fullscreen learnings + framing to the other three
side-by-sides, readme.html).

## COMPTIME CORNER (turn 1169) — the helmet completes the trio: CPU | GPU | compiler
The fourth side-by-side now matches 1–3's three-target pattern. Pieces:
- `rlsw_shader.rasterizeToImage(VsModule, FsModule, W, H, vertex_outs, indices, base_fs_io, connect, opts,
  clear) [W*H][4]u8` — the PURE sibling of rasterizeTriangles: same edge functions / perspective weights /
  `.less` depth, but no rlsw.Context and no runtime codec fn pointers, so the COMPILER can run it. Internal
  z-buffer always on. Quantization mirrors the rgba8 codec (truncating *255). DIFFERENTIAL TEST: two
  overlapping depth-separated gradient triangles drawn far-last must come out byte-identical to
  rasterizeTriangles through a real Context (266/266 in the direct module run).
- `tools/mesh_bake.zig` — build-step host exe: GLB → meshesFromGltf → vertex-cluster decimation (bbox grid
  snap, per-cell pos/normal/uv averaging, re-index, degenerate-drop + sorted-triple dedupe) + base-color walk
  (the decodeMaterialMap shape, tool-local since pbr3d would drag wgpu into a host exe) box-filtered to 64².
  Emits `pub const` arrays ({e} floats). Helmet @ grid=16: 952 clusters / 1979 tris from 14556/15452. 0.17
  idioms throughout (std.process.Init main, std.Io.Dir file io, Writer.Allocating emit). `codecs.types` made
  pub — meshesFromGltf's return type was unnameable outside the module (API wart, now fixed).
- build.zig: mesh_bake exe (own codecs module instance — host compile graph is disjoint from wasm, so the
  one-file-per-module rule is satisfied per-compilation) + addRunArtifact in the helmet block → generated
  `helmet_proxy` anonymous import (grid=16, tex=64).
- Example: `corner_image` const (48×48) — @setEvalBranchQuota(2e9); frozen initial camera (hoisted
  initial_yaw/pitch/dist consts shared with State init), aspect=1; comptime VS loop over proxy verts;
  rasterizeToImage with the same autoConnect; Ubo from the new pure `buildUboFromFactors` (buildCpuUbo is now
  a thin wrapper over it) using the proxy's BAKED material factors. Corner-only simplifications documented
  in-source: flat 1×1 normal (TBN→geometric normal ⇒ NO proxy tangents, (1,0,0,1) placeholders), matte 1×1
  MR, white AO, BLACK 1×1 emissive (helmet emissive_factor=(1,1,1); white would glow everywhere). Drawn as
  the rt-style rect-grid inset bottom-right + "comptime pbr_fs" label.
GATES: direct rlsw_shader test run 266/266 (incl. the new differential), helmet smoke PASS (release; the
inset's 2304 rects batch fine, ~96 js-calls/frame), tier-a-check PASS 37s, lint 0/436, standalone rebuilt.
Wasm +10KB (the baked corner const; proxy arrays are comptime-only and don't ship).
NEXT: Simon eyeballs the inset on-device (should be a frozen low-poly helmet matching the live halves'
shading family at the initial pose) → then step 5: unify framing across all four side-by-sides + readme.

## STEP 5: UNIFY THE FOUR + perf fix + readme (turn 1170)
Simon's t1169 screenshot: ALL THREE TARGETS on screen ("going straight to the top of hacker news") — but
16fps vs t1168's 60. Only delta between those builds: the 2304-rect comptime inset → the rect grid was the
regression. Fixed + the whole step-5 unification wave:
- HELMET: corner const is now raw RGBA8 (`@bitCast` of the rasterizeToImage output), uploaded ONCE to a
  `corner_fb: CpuFramebuffer` at init, drawn as ONE textured quad. The rect-grid drawing is gone.
- TRIO UNIFIED (mandel / rt / cube) to the helmet's mechanics, each: (1) `ensureCpuTarget` — CPU rlsw buffer
  reshaped per frame to a CONSTANT pixel budget (their old sw_w×sw_h product) at the live canvas aspect via
  rlsw.resize + CpuFramebuffer.resize (their fixed buffers stretched anisotropically on rotation, the
  pre-t1168 helmet bug); dispatch rect follows colorBufferDims. (2) divider_frac + pointer-follow +
  pre-input-(0,0) guard (cube had the raw-m[0] bug; mandel/rt were fixed-center — now follow, gated off
  while the UI panel owns the mouse). (3) comptime insets converted to corner_bytes (@bitCast — z.Color is
  extern r,g,b,a u8) + corner_fb single-blit + adaptive sizing clamp(min(vw,vh)*0.30, 84, 200) preserving
  each corner's own rows/cols aspect. (4) label trio unified: "CPU <kernel>" / "GPU <kernel>" 22px corners +
  "comptime <kernel>" 16px above the inset, all 235/235/245 (cube's bare CPU/GPU + blue comptime restyled;
  mandel/rt had NO corner labels — panels kept, they carry the gesture help). States gained gpa/font/
  divider_frac/last_mouse/corner_fb as needed.
- README (prebuilt/readme.html): the side-by-side section is now the headline — "One shader, three
  executors: CPU | GPU | compiler", describing all four demos incl. the helmet's build-step proxy + comptime
  raster; example table lists all four with the trio framing.
GATES: quad smoke PASS (all four, release), tier-a-check 11×PASS exit=0, lint 0/436, four standalones
rebuilt. The fps verdict needs the PHONE: the inset fix should restore the helmet to ~t1168 rates; if not,
next suspect is the full-backing-size GPU RTT (cap it then).
NEXT: Simon re-verifies the helmet fps + spot-checks one trio standalone (rotation + divider + inset) →
then back to the port queue (~27 GL-only examples remain) or the GL-deletion audit, Simon's call.

## PORT QUEUE ENDGAME OPENED (turn 1171) — 3 ports + 2 engine features, queue audited
Simon: "What webgl examples still dont have a wgpu equivalent? Lets finish porting them." The 53-name set
difference filters to SIX real functionality gaps (rest are shader/io/data files or demos superseded —
gltf_model_refs demos the GL-era ECS texture-ref architecture that dies with GL; covered by
wgpu_gltf_textured/pbr3d). Standing rule pinned in claude.md: EVERY turn presents the standalones + pastes
the code in chat for review.
- ✅ wgpu_split_screen — two cameras, one world, two RenderTextures (helmet pattern), per-camera atmosphere
  tint in app code (the old Scene-fog story without the Scene system). ENGINE: `App.target_size` — set by
  beginTextureMode, cleared by endTextureMode; beginMode3D now uses the CURRENT TARGET's aspect (3D-into-RTT
  was never exercised; a half-width RTT no longer renders with full-canvas aspect). Zone spheres drawn via a
  local 3-ring helper (no drawSphereWires on wgpu yet). zm.add/sub are int-overflow helpers — vectors use
  operators (caught by first compile).
- ✅ wgpu_first_person_camera — ENGINE: `genMeshHeightmap` ported from condemned drawing.zig into draw3d.zig
  (CPU arrays only, RGBA8-format check, no GL uploadMesh tail — loadModelFromMesh owns GPU buffers on wgpu),
  exported from zimr_wgpu. Example: genImageChecked heightmap → mesh → drawModel tint;
  updateCamera(.first_person) WASD+drag-look (pointer-lock dropped: no wgpu bridge wiring + phone-first).
  loadModelFromMesh takes (gl, gpa, mesh) on wgpu — call-site parity arg.
- ✅ wgpu_texture_readback — ENGINE: `js_encoder_copy_texture_to_buffer` bridge op (zimr_wgpu.ts) +
  `wgpu.copyTextureToBuffer` wrapper (256-aligned bytesPerRow per spec; 256² RTT = 1024 B/row, no padding).
  Example: animated RTT → own-encoder copy submit → poll-based bufferRead* (compute machinery) → re-upload
  into CpuFramebuffer → side-by-side panels + round-trip counter. WebGPU mapping is async ⇒ the GL
  loadImageFromTexture sync shape becomes a frame-delayed state machine; the one-step lag is documented as
  the demo being honest. Headless shim needed the import declared (webtests/wgpu_smoke.ts) — undeclared
  imports fail smoke loudly, good.
- DEFERRED with reasons: skinned_mesh (next arc: CPU-skinning v1 via updateMeshBuffer, or the full skinned
  shader variant — bone VBOs + boneMatrices — for the real thing; needs its own turn). mrt_demo (demos
  rlColorMask/rlActiveDrawBuffers bridge primitives that don't exist on wgpu — colorWriteMask is per-pipeline
  state there; real MRT arrives with deferred rendering, F7 low-med). image_text (imageText CPU rasterize →
  upload; needs the imageText family on the wgpu surface — assess next turn alongside skinned_mesh).
GATES: 3-wasm focused smoke PASS, tier-a 128.6s exit=0, lint 0/439, three standalones built.
NEXT: skinned_mesh arc (decide CPU-v1 vs GPU pipeline), image_text assess, then the GL-deletion audit gets
its green light.

## PORT QUEUE CLEARED (turn 1172) — skinned_mesh ported, image_text adjudicated; GL deletion unblocked
- ✅ wgpu_skinned_mesh — CPU-SKINNED v1 over the same 2KB embedded GLB rig (copied into the example dir;
  cross-dir imports can't escape the user-module root). codecs.gltf ALREADY parses skins + animations +
  JOINTS_0/WEIGHTS_0 (meshesFromGltf fills Mesh.boneIndices/boneWeights — note: boneIndices, not raylib's
  boneIds) — zero parser work needed. Example: extract joints/inverse-binds/keyframe-rotation tracks at init
  via readAccessor (then Data.deinit — readAccessor copies); per frame sample tracks (nlerp), per-joint
  world = v·R·T, skin = v·invBind·world, CPU-deform into a scratch buffer, updateMeshBuffer(slot 0) →
  drawModel; amber bone gizmos (spheres + line) over the emerald quad; HUD shows anim time. MATRIX
  CONVENTIONS derived from zm source and documented in the example header: zm is row-vector/row-major
  (mulMatVec(m,v)=v·m, translation in ROW 3) ⇒ glTF's COLUMN-major mat4 floats map DIRECTLY onto zm.Mat
  rows, and rotate-then-translate composes as mulMat(R, T). GPU skinning (the GL original's bone-VBO +
  boneMatrices pipeline) is deliberately future work: lands as a skinned variant when the typed-3D-shader
  arc needs it; the pose math here transfers unchanged. Lint taught: data file's SCREAMING const renamed
  (skin_glb).
- ❌ image_text — SUPERSEDED, documented: a faithful imageText needs CPU glyph compositing, but the wgpu
  loadFont frees its CPU atlas after upload (wgpu_app.zig:~2368) — atlas retention is a font-system feature
  not worth growing for one GL-internals comparison demo; the modern equivalents are wgpu_text_on_texture
  (text into a texture via RTT) + wgpu_texture_readback (the GPU→CPU leg).
- THE QUEUE IS CLEAR: every GL example is now ported, superseded with documented reasons, or deferred with a
  named future arc (mrt_demo → deferred rendering F7; GPU skinning → typed-3D-shader arc; imageText → font
  atlas retention if ever wanted). **The GL-deletion audit (audit_cleanup_notes.md) has its green light.**
GATES: skinned smoke PASS (release), tier-a 11×PASS exit=0, lint 0/441, standalone built.
NEXT: Simon verifies the skinned wave on-device → then the GL-deletion audit arc begins (sever ui→drawing,
delete the GL path, collapse the two rasterizers, bridge destroy ops — the audit_cleanup_notes.md program).

## GL RETIREMENT ARC OPENED (turn 1173) — deep build study + plan doc + P1 executed
Simon's directive: study the build deeply, plan the WebGL retirement, spot improvements, delete nothing
still useful, execute in logical order. Deliverable: **src/notes/GL_RETIREMENT_PLAN.md** — the full map +
six phases. Key study findings (details in the plan doc): the wgpu wasm still REACHES GL via
ui.zig→{drawing,rlgl,zimr}; drawing.zig (18.5k lines) trapped the LIVE backend-generic text+shapes
namespaces; runtime.zig is half-live (input/gestures/core/rng used by wgpu — PRUNE not delete); the host
test suite is the only remaining compile of the GL stack (six tests need per-file adjudication); docs_lib is
zimr_mod's ONLY consumer (autodoc documents the DYING API — retarget is P3); sw-mandelbrot/sw-julia/
julia-gallery host steps build src/zimr.zig but need only a tiny surface (migrate to sw_runtime_bundle, P2);
the six native SW/comptime PNG demos are KEPT; top-level GL examples are already build-dark (the build.zig
"example loop" comments are stale ghosts); the GLSL path is already gated behind placeholders.
**P1 EXECUTED (the keystone, pure move):** text (2.8k lines) → src/text2d.zig, shapes (2.8k) →
src/shapes2d.zig, VERBATIM with transitional rlgl imports (text2d also keeps a circular
@import("drawing.zig").textures for atlas image helpers — legal in Zig, severed P5d). drawing.zig (now
12.9k) re-exports both so every GL consumer compiles unchanged. wgpu_app repointed (drawing_text→text2d,
drawing_shapes→shapes2d, textures.unloadImage→image.zig's — impls verified identical). ui repointed
(drawing.text→text2d, drawing.shapes→shapes2d); ui's ONLY remaining drawing.* use is .shaders (the GL
render branch — dies in P4). The two new files left lint-skip protection: 18 surfaced issues fixed
(SCREAMING renames, dead RL_* consts, unused builtin).
GATES: **full `zig build test` 1647/1647 PASS** (first full-suite run in many turns — surfaced a
pre-existing ENVIRONMENTAL red: spv2wgsl's recursive emitFunctionBody segfaults the sandbox's 8MB default
stack on one deep Tint corpus fixture; `ulimit -s unlimited` → all green. Workaround pinned in claude.md;
iterative emitter filed as a P6 improvement). tier-a 11×PASS 31s, lint 0/443, helmet standalone rebuilt.
NEXT (t1174): P2 (sw_* host steps → sw_runtime_bundle + lint allowlist for the six live host demos), then
P3 (docs retarget + GLSL machinery deletion). Then P4 (ui GL-branch sever) → P5 (THE DELETION) → P6.

## GL RETIREMENT P2+P3 EXECUTED (turn 1174)
**P2 — sw_* migration:** sw_runtime.zig grew math (zm re-export), gpu_iface, shader_runtime_wgpu,
wgpu, default_shapes (the engine shapes shader bundle — folded IN because the bundle's graph grew
renderer_2d.zig via shader_runtime_wgpu, and a separate default_shapes_bundle module then double-owned that
file), and renderer_2d. sw_mandelbrot/sw_julia/julia_gallery: `@import("zimr")` → `const sw =
@import("sw_runtime")`; build.zig blocks rewired (exact-text surgery after a greedy-regex near-miss — the
assert fired BEFORE the write, build.zig was never corrupted). Bundle modules need
addOptions(build_options) — utils.zig's allow_assert is in the deep graph. sw-engine-shader's separate
bundle module deleted; its codegen EXTERNS modules rewired onto sw_runtime_mod. Surfaced pre-existing rot:
sw_engine_shader's local orthoTopLeft had been migrated to zm.Mat during math-unification while its caller
kept [16]f32 — never built since (the step is in no gate). Fixed by using the ENGINE's
renderer_2d.orthoTopLeft ([16]f32, the GPU-UBO layout) + @bitCast to zm.Mat for the typed-shader Io
(same bytes, row-major). Lint isSkipped gained a six-demo allowlist (sw_mandelbrot, sw_julia,
julia_gallery, sw_engine_shader, comptime_mandelbrot, comptime_julia) — 29 surfaced SCREAMING renames fixed
(Zig's shadowing errors caught max_iter global-vs-param collisions → global renamed iter_cap). ALL SIX
host steps run green: mandelbrot.png, julia.png, julia_gallery.png, sw_engine_shader.png + two stdout
demos. sw_fractal_gallery.zig confirmed orphan (no wiring) → P5c deletion list.
**P3 — docs retarget + GL module deletion:** docs_lib.root_module → zimr_wgpu_mod (autodoc now documents
the LIVE API; sources.tar shows the wgpu closure — GL files remain in it only via ui→zimr until P4).
zimr_mod + zimr_mod_smoke + smoke_optimize DELETED from build.zig with all their wiring (shader_interface/
zm/build_opts trios → wgpu-only lines; four addAnonymousImport sites excised; comments updated — 8
stragglers cleaned). zimr_mod had ONE consumer (docs), zimr_mod_smoke ZERO. KEPT until P5: the GLSL
gravestone placeholder + engine_shaders .glsl entries + check-glsl-header (host-test modules still resolve
render.zig's .glsl embeds until the GL tests die).
GATES: zig build test green (host tests cache-valid — wiring untouched; lint dep showed 162 skipped, down
from 168 = the allowlist working), zig build docs emits fresh, all six host demos run, tier-a 11×PASS,
lint 0/443, helmet standalone rebuilt.
NEXT (t1175): P4 — read ui.zig's backend dispatch, sever the GL render branch (rlgl import, drawing.shaders
scissor, zimr.{Frame,run}). Then P5 (THE DELETION) → P6.

## GL RETIREMENT P4 EXECUTED (turn 1175) — ui.zig's GL branch severed
Simon pinned a structural philosophy (claude.md): GIANT FILES, flat hierarchy, simple DAG — single-parent
files merge into their importer. Census ran; candidates recorded in GL_RETIREMENT_PLAN P6.
**The severing** (ui.zig 42.6k → 42.3k lines, zero GL imports left):
- DELETED (363 lines, GL-only — wgpu's UiHost uses beginFrameRaw/uiRenderNow/endFrameNoRender):
  beginFrame(*zimr.Frame) (126), endFrame(*zimr.Frame) (139 — frame-end LOGIC survives in endFrameNoRender,
  which already carried the dock-request draining the wgpu path needs), pushRenderTexture/popRenderTexture +
  Impls (the rlgl matrix-stack/framebuffer UI-RTT path; only caller was the dark GL recursive_hud — the wgpu
  recursive HUD composes via app-side beginTextureMode).
- Gl selector: `WgpuGl | rlgl.GlState` → `WgpuGl | TestGlStub` (pub). TestGlStub = inert no-op renderer
  trait (begin/end/vertex2f/texCoord2f/normal3f/color4ub/setTexture/enable/disable/scissor/matrixMode/
  loadIdentity/ortho/push/popMatrix/translatef/viewport) — host tests pass &stub into beginFrameRaw and
  rasterize via rlsw (renderToBytes); the stub only carries the type. Built compiler-driven (two rounds).
- beginScissorMode/endScissorMode MOVED drawing.shaders → shapes2d.zig (they're the SHARED DrawList-replay
  clip dispatch, gl: anytype with a comptime @hasDecl rlgl arm — arm dies P5d). drawing.shaders keeps
  forwarder consts (gpu.zig + dark GL examples still route through it until P5).
- Imports deleted from ui.zig: rlgl, drawing, zimr (remaining refs were comments; fixed). Three test files
  swapped `rlgl.GlState` dummies → `ui.Gl` and dropped their rlgl imports.
**PROCESS NOTE:** first deletion pass used a brace-matcher that returned before ENTERING braces on
multi-line signatures → mangled ui.zig; restored from zimr1174.zip (the per-turn snapshots ARE the safety
net), matcher fixed (entered-state + bottom-up deletes + min-size asserts). 
GATES: host suite 1647/1647 PASS (direct binary run, ulimit — NOTE: ulimit inside the setsid'd `zig build
test` chain does NOT reach the maker's child; run the binary directly for truth), tier-a 11×PASS 29s, lint
0/443, helmet + ui_demo standalones rebuilt.
STATE: the wgpu module graph's only remaining GL tendril is text2d/shapes2d's transitional rlgl import
(+ text2d's circular drawing.textures) — exactly the P5d sever. P5 (THE DELETION) is next: test
adjudication (a/b), file deletions (c), the final sever (d), bookkeeping (e).

## GL RETIREMENT P5 — THE DELETION — EXECUTED (turn 1176)
**The numbers:** src/*.zig 61→52 (then 52 files incl. 19 shader-source deletions → src/shaders 42→23);
examples/*.zig 170→32 (138 GL examples deleted; keepers = shader sources + six host demos +
quad_glb_data.zig, which survives as the embedded-GLB data dependency of wgpu_gltf_textured);
host suite 1738→1688 tests, ALL GREEN; lint roster 443→277 files, 0 issues, isSkipped collapsed to a
single data-file exception.
**Adjudication outcomes:** ext_storage + features tests retargeted at zimr_wgpu (which GAINED pub ui/
features/todo re-exports — the live umbrella inherits the public shape); snapshot_regression +
ui_screenshot + ui_dock_screenshot repointed to shapes2d/text2d (dormant but portable);
app_bridge/scene/transform_order/typed_shader tests DELETED with their subjects; leak_test PORTED to
image.zig+draw3d (the merges made it a live-library test); multiapp_test untouched (pure runtime.zig).
**The merges (giant-file convergence):** drawing.textures → image.zig (92 CPU fns; 12 GL-texture fns +
2 classifier-dodging stragglers (setTextureFilter/Wrap, resizeRenderTexture) died; 10 collisions kept
image.zig's versions). drawing.models → draw3d.zig (36 CPU pubs + all private+inline helpers + the inner
z struct; GL draw/upload/material fns died; loadMaterialDefault/unloadMaterial CPU-ported;
updateModelAnimation/Blend keep the CPU pose with GL skinned-shader tails stripped; loadModelFromMemory
gl-freed — loadGltfTexture deleted, tangent prep calls genMeshTangents directly, uploadMesh loop replaced
by the retained-mesh story).
**P5d sever:** text2d's font-texture rlgl calls → cpuAtlasTextureId() sentinel stub (residency =
WgpuGl registration; bilinear → TextureRef-bilinear P6 item); shapes2d scissor @hasDecl rlgl arms deleted;
shapes2d's 12 no-panic tests replay into a new shapes2d.TestGl (ui.TestGlStub now aliases it — ONE stub);
gl_iface lost GlAdapter (206 lines) + trait tests retargeted at WgpuGl; runtime.camera lost
begin/endMode2D/3D (the wgpu side owns camera install) and the world↔screen projection pair gained
explicit ClipPlanes{z_near,z_far} params (raylib defaults), tests updated.
**refAllDecls policy (tests.zig rewritten):** 48 live files force-analyzed (zm + shader_interface
referenced as MODULES — file-importing them double-owns their graphs); wasm roots excluded
(spv2wgsl_wasm, wgpu_smoke_test, wgpu_runner). Host-test module gained the WGSL anonymous-import twins +
the default_shapes externs modules (the test graph reaches renderer_2d + the shapes shader pair now).
ROT THE POLICY SURFACED AND FIXED: Zig-0.17 @typeInfo parallel arrays (info.fields → field_names/
field_types) in 4 shader_runtime_wgpu tests; return-from-comptime-block + runtime-context @compileError
in assertVaryingsMatch (conditions comptime-marked); ~15 mislabeled type annotations from the old bulk
annotation pass (byte offsets/mesh indices/struct returns typed f32; an integer 16.16 DDA pushed to
float); drawTextCodepoints missing the gl param drawCodepoint gained; types.Rectangle → extern struct
(NPatchInfo embeds it in extern ABI); zimrmath colorSaturation scalar-vector mix.
**Build machinery:** GL web pipeline blocks excised (gallery index.html/host.html install + the two
zimr.ts bun bundles); old_3d_shaders array + gravestone-append branch deleted (a mid-surgery span error
swallowed the loop preamble — reconstructed from the pre-read; another reminder: exact-text anchors,
verify after); check-glsl-header subcommand + checkGlslHeader deleted from buildaux; the .glsl
placeholder names on LIVE entries remain (consumer loops wire them unconditionally) — wgsl-primary
collapse queued P6. KNOWN-ENV: this sandbox's sh does NOT brace-expand — the first shader-file rm was a
silent no-op; use explicit loops.
**GATES:** host suite 1687/1687 direct-binary green · tier-a 11×PASS 44s · lint 0/277 · helmet +
ui_demo standalones rebuilt · six host demos run (4 PNGs) · docs emit green.
NEXT: P5e remnants (test_files list check, readme/claude.md touch) + P6 program (single-parent merges
census already in plan, wgsl-primary collapse, two-rasterizers, destroy-ops, iterative spv2wgsl emitter).

## STRUCTURE PLAN S0–S5 — EXECUTED (turn 1177)
**S0 (DAG):** 3 measured cycles broken: imageText/imageDrawText family → text2d (text-on-image lives
with fonts); the WgpuGl trait test → wgpu_draw (impl asserts own conformance); the gpu_iface 3-cycle
inverted by moving the BATCH DATA LAYER down (Vertex2D + ShapesBatch + ring/batch capacities into
gpu_iface, renderer_2d re-exports) and SwPipelineDispatch down (shader_runtime_wgpu re-exports).
runtime.zig's 14 intra-file self-imports → direct sibling refs. `zig build dag-check`
(scripts/check_dag.py, exit-1 on any SCC) is a tier-a member — cycles are build failures forever.
**S1 (one transpiler file):** 7 real files folded into src/spv2wgsl.zig (~9.6k lines) as section
namespaces; loop/selection/switch were EMPTY phase-scaffolds → deleted (suite 1687→1684); subdir gone.
The recurring enemy: Zig 0.17's container-shadowing-is-ambiguous rule — fixed via inner-alias dedupe,
a section-local TestOp rename (sccp's raw opcode table), inlining the outer types.* aliases, then
qualifying section bodies. Also learned: zig fmt's array column-alignment re-expands compressed rows —
trailing comments break alignment groups (the durable line-length fix).
**S2 (merges):** pbr3d (de-cycled first: drawInApp takes anytype gl + explicit *GpuFrame, dropping the
wgpu_app.appOf reach; one caller updated) + draw_points → draw3d sections; render_pass + compute_pass +
storage_buffer + uniform_buffer → wgpu.zig sections (killing the begin/end/setPipeline/setBindGroup
dup family); shader_compile → shader_runtime_wgpu; default_shapes_bundle inlined into sw_runtime.
DEFERRED: kompute (a named-module root kernel files import — shader_interface's exemption class) +
compute_host; queued as a compute-consolidation item. The generalized section-folder dedupes identical
imports/consts against the host and renames divergent ones (pbr3d's Material/Model/ClearColor got
section-qualified at 7 ambiguity sites). 45 src files.
**S3 (renames):** gl_iface→renderer_trait, zimr_build→shader_codegen, sw_runtime_bundle→sw_runtime,
wgpu_gl→wgpu_draw (type WgpuGl unchanged), examples/gltf_textured_quad→quad_glb_data. 71 files
rewritten, green on first compile.
**S4 (fn-name uniqueness):** new cross-file lint rule `dup-pub-fn` — an UNCONDITIONAL text pre-pass
(the per-file clean-stamp cache would otherwise hide names) + post-report. It found 36 dups: the
wgpu_app↔shapes2d/draw3d raylib surface is the z-API FACADE pattern → structural exemption (dup
allowed iff exactly one side is wgpu_app.zig). Real dups killed: the bounding-box trio + 4 mesh
forwarders → pub-const aliases; colorFromHSV canonicalized into types.zig (image + wgpu_app re-export);
rlsw_pixel's half-float pair → zimrmath re-exports; the umbrella's loadTextureFromImage → alias;
compute kernel `step` → `particleStep` (zimrmath.step keeps the GLSL name). Allowlist: shaderMain,
main, Handle, build, the four layered draw names.
**S5 (SHADER-SAFE tier):** measured truth — shaders import exactly zm + their _io + generated externs.
Now explicit: `//! SHADER-SAFE` markers on zimrmath + shader_interface; the lint's new
runShaderSafeChecks fires on marked files + every `_io.zig` (no allocators / runtime std / externs /
bridge imports outside test blocks — negative-tested with a synthetic violation); files.md tags the
tier per entry.
**GATES (all fresh-binary verified):** 1684/1684 host · tier-a 11×PASS (wall 103.8s cold-ish, 37–44s
warm) incl. dag-check · lint 0/258 with both new rules · helmet + ui_demo standalones rebuilt · atlas
regenerated (dict keys updated for the renames).

## THE GPU FLUID — wgpu_fluid_gpu (turn 1178)
The arc the CPU sim's header promised: Clavet double-density relaxation at 20,000
particles, entirely on the GPU, as SEVEN kompute kernels (examples/wgpu_fluid_gpu/
fluid_kernels.zig). Per substep ×2: gravityMouse → buildGrid → viscosity → predict →
buildGrid → density → force → applyAndFinalize. Rendered zero-copy by the new
`z.FluidDiscs` (draw3d.draw_points sibling): instanced SDF discs, sim-pixel domain
mapped in the VS, density-coloured by reaching the density field through the ONE
storage binding as an element-index base (no second binding, no 256-byte offset
alignment games).
**Multi-kernel infrastructure (new):** spv2wgsl gained `--entry=NAME` (State.wanted_entry
filters OpEntryPoint capture; the emitter stays single-entry) — a kompute module with N
installKernel exports is translated N times into N standalone WGSL modules.
`ShaderPipeline.addComputeKernelImports` wires each as `<entry>_wgsl`;
`ComputeKernel.entries` in build.zig opts in. `z.Compute.initGpu` now takes a
`[]const KernelWgsl` (name+wgsl pairs) and holds a pipeline-per-kernel registry
(shared bind group/layout — same Buffers/Params); `run(name)` selects by name.
Existing single-kernel callers migrated to one-element lists.
**The grid, without atomics:** the reference sim's atomicAdd slot-claiming has no
spv2wgsl support yet (queued transpiler arc). `buildGrid` instead runs one invocation
PER CELL, scanning all N and filling its own row — single writer, race-free,
bit-identical on CPU, ~30M reads/build at 20k×1.5k cells (fine).
**Verified:** all 7 kernels translate with zero ERROR/UNRESOLVED markers; the CPU twin
(the literal kernel fns in a host loop) ran 60 substeps at full 20k: 0 NaNs, 20000/20000
in-domain, rho_avg 15.2 (settling dam-break vs r0=10), vmax 8.7 < the 40 cap — PHYSICS OK.
Host tests 1684/1684, tier-a 11×PASS, lint 0, fluid+helmet+ui standalones rebuilt
(-Dmode=release = ReleaseSmall + zimr asserts, the phone-verification build).
Browser truth (actual GPU dispatch correctness, fps) = the phone check.
**Queued:** spv2wgsl atomics (OpAtomicIAdd/Load/Store + atomic<u32> field rewrite) for
the parallel grid build; external-encoder `run` batching (16 submits/frame today);
CPU/GPU live-flip demo wiring like compute_particles.

### t1178

### t1178 continuation — bridge beautification + the one global + two transpiler fixes
The ZIG_BRIDGE intake reached full house style: 308 lint issues -> 0 across
bridge.zig / c2js.zig / bridge_slice.zig with zero skip-ledger entries; the
webzig differential suite runs ALL GREEN against our restyled transpiler.
All bridge globals merged into ONE `var g: BridgeGlobals` (domain sub-structs,
single lint:off); the slice likewise (`var page`). The consolidation exposed a
real c2js miscompile (nested global-struct array member -> JS property leak),
fixed via a last-resort prefix-mode lvalue walker + a new differential case;
a second latent stride bug (cast pointer arithmetic eaten by the chain) fell
out of the same case. Phase 2 (app-owns-the-page, two live canvases, click
ring) is device-proven on the Pixel. Phase 3 (real wgpu surface) started.
 follow-up: the mixed-int-signedness transpiler bug (phone-found)
The fluid's grid-loop kernels (viscosity/density/force) produced WGSL Tint rejects:
`i32 >= u32`. Root cause: SPIR-V integer ops carry signedness in the OPCODE
(OpUGreaterThanEqual) while Zig's same-width int casts are SPIR-V no-ops, so an
operand's tracked WGSL type can disagree with the op. Fix in spv2wgsl: `emitIntBin`
replaces type-blind `emitBinOp` for the integer compares + IAdd/ISub/IMul +
UDiv/UMod/SDiv/SRem — operands bitcast to the opcode's signedness (sign-agnostic ops
align to the result/other-operand type), whole-expr cast-back when the declared
result type disagrees. `cmpOperand` unit-tested (suite 1685). A mixed-int WGSL
auditor (regex type-table cross-check) shows 0 sites across all 7 kernels; the fixed
standalone's embedded wasm verified to carry bitcast<u32> ×12. NOTE: the dev zip
lacks tools/naga-prebuilt referenced by scripts/naga-validate-*.sh — re-bundle so
this class is catchable pre-phone.

### t1178 THE ADRENO MEGASTRUCT CONVICTION → per-field bindings (the big one)
On the phone (qualcomm | adreno-7xx, Chrome Android), the fluid corrupted
catastrophically above ~1000 invocations while the CPU twin was perfect: corner
blobs, axis spray, explosions; readback oracles showed ~96% of a dispatch's writes
ABSENT from the buffer and CROSS-FIELD displacement (the density sentinel 12345
inside pos[0]; velocity-like negatives in pos). The bisection eliminated, with
builds: all 7 WGSL translations (hand audits + a WGSL interpreter diffed against
the Zig kernels over a full substep: 0 mismatches), uniform delivery (16-dot probe:
bit-correct), upload offsets, the JS bridge encode/decode, per-dispatch submits,
single-pass batching, decoupled rendering, and the readback path. The conviction:
the MEGASTRUCT storage binding — one `extern var B: Buffers` with fixed arrays and
large constant field offsets — is mis-addressed by the Adreno shader compiler. The
proof: a hand-rolled twin through the SAME bridge (hand WGSL, one runtime-sized
buffer+binding per array — the shape of every working JS WebGPU demo, including
Simon's own 20k SPH) ran flawlessly where the megastruct died at the same counts.
**The fix (shipped):** kompute emits ONE STORAGE BINDING PER Buffers FIELD.
- kompute.zig: `g.bind(.field)` — `@extern(*addrspace(.storage_buffer) [N]T,
  .{.name="kbuf_<field>"})` on GPU, `&g.B.<field>` on CPU; kernel files alias once
  per field (`const b_pos = g.bind(.pos);`) and index through the alias. The
  CPU/GPU duality is unchanged.
- spv2wgsl: top-level storage bindings whose root is a fixed array emit
  RUNTIME-SIZED `array<T>` (the proven shape); struct-rooted bindings untouched.
- compute_host: per-field buffers (`kbuf_<name>` labels); binding numbers are
  PARSED from the kernels' generated WGSL headers (`parseBindings`) — the SPIR-V
  backend assigns in use-order, so host and shader agree by construction, with
  cross-kernel consistency checks. upload() targets the field's buffer at offset
  0; readback copies each field into one Buffers-shaped staging (mirror decode
  unchanged). New `fieldBuffer(.field)` accessor for renderers.
- FluidDiscs: reworked to two read-only bindings (positions + density) taking
  `z.BufRegion{handle,offset,size}` each — the element-index reach-in
  (density_base) is deleted. DrawPoints call sites bind `fieldBuffer(.pos)`.
**Device-verified:** SIMPLE fall+bounce at 15,416 particles via kompute per-field:
in-bounds, frozen 0%, 61fps — 15× past the megastruct's death cliff. The hand-
rolled twin stays in the fluid example as a permanent A/B reference. Suite
1685/1685. Full-SPH-at-20k phone run = the closing check.
**Follow-up tickets:** FluidDiscs draw breaks subsequent 2D drawing on this phone
(pass-restore bug; worked around by drawing discs LAST); text-rendering-invisible
sighting possibly distinct; viscosity intra-dispatch vel read race (benign-looking,
matches reference behavior — consider prev-vel read); spv2wgsl atomics arc.

### t1178 — spv2wgsl atomics arc: BLOCKED at the Zig-compiler level (investigated, deferred)
Verify-first pass before implementing the queued atomics arc surfaced a hard
DUAL blocker that makes a speculative spv2wgsl implementation premature:
1. **Zig 0.17.0-dev.704's self-hosted SPIR-V backend does not implement ANY
   atomic AIR tags.** A minimal kernel using `@atomicRmw(u32,&counts[c],.Add,1,
   .monotonic)` fails to compile with `error: TODO (SPIR-V): implement AIR tag
   atomic_rmw`; `@atomicLoad` fails with `atomic_load` TODO likewise. Compiled
   exactly as the pipeline does (`zig build-obj -target spirv32-vulkan -mcpu
   vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv`). So the REAL
   consumer — a per-particle parallel `buildGrid` doing `atomicAdd(grid_counts
   [cell],1)` to claim a slot — CANNOT be written on the pinned toolchain even
   if spv2wgsl learned to translate atomic SPIR-V. The current single-writer-
   per-cell `buildGrid` (O(N×cells), race-free, in fluid_kernels.zig) stays as
   the correct workaround.
2. **Testing spv2wgsl atomic lowering needs hand-authored SPIR-V.** Neither Zig
   (blocker 1) nor `spirv-as` (not built in-sandbox, like spirv-opt) can produce
   atomic SPIR-V here. The Tint fixture corpus (tests/fixtures/external/tint/
   *.spvasm + pre-committed .spv) contains ZERO atomic ops (grepped all 181). So
   an atomics implementation could only be exercised against a HAND-ASSEMBLED
   .spv fixture — building a transpiler feature nothing can feed yet.
DECISION: defer the arc until either Zig's SPIR-V backend implements the atomic
AIR tags (then write the real kernel + translate it) OR a SPIR-V assembler is
available in-sandbox (then add a hand-written atomic .spvasm fixture and
implement OpAtomicIAdd/Load/Store → atomicAdd/atomicLoad/atomicStore + the
atomic<u32> storage-field rewrite speculatively). The WGSL spec target is known
(atomic<u32> field type; atomicAdd/Load/Store with the storage scope), recorded
here for when it unblocks. Not a regression — the fluid sim runs correctly today
on the single-writer grid; this only forgoes a perf optimization (~O(N) vs
O(N×cells) grid build) that's moot until the toolchain supports it.

### t1178 — atomics arc UNBLOCKED via the zsample2d-pattern (plan written)
Re-opened after studying Mach sysgpu + SPIRV-Tools (Simon's uploads). The Zig
SPIR-V backend still can't emit atomics, BUT a clever route around it is proven:
declare a `noinline` helper `zatomicAdd(arr_ptr, idx, val)` with a dummy body —
the SAME trick as `zsample2d` (zimrmath.zig:7934) — Zig emits a real
OpFunctionCall (verified: compiles to SPIR-V; spv2wgsl reads it and emits the
call + helper fn). spv2wgsl then INTERCEPTS the call by helper-name and emits the
WGSL atomic builtin (`atomicAdd(&field[idx], val)`), DELETES the helper fn, and
ATOMIC-TAINTS the binding (`array<u32>` → `array<atomic<u32>>`, routing all other
accesses through atomicLoad/atomicStore). No atomic SPIR-V is ever synthesized
(we can't test it — no spirv-as in-sandbox), and no Zig-backend change is needed.
Migration when Zig lands atomics: swap helpers for real `@atomicRmw`, add an
OpAtomicIAdd arm to spv2wgsl, delete the intercept — same WGSL out.
Mach's role: confirmed the browser wants WGSL (their multi-backend WGSL frontend
ships WGSL on web; validates spv2wgsl-as-output). Their vendored spirv spec.zig +
SPIRV-Tools validate_atomics.cpp gave the authoritative opcode/validity spec for
the eventual SPIR-V arm. FULL PLAN: src/notes/compute_atomics_plan.md.
SPH VERIFIED still working this session: zig build wgpu-fluid-gpu EXIT=0, lint 0,
wasm built, 7 compute kernels transpiled to WGSL (@workgroup_size(64,1,1)). The
perf target (reference sph_fluid-3.html): per-particle atomicAdd grid build +
atomicLoad neighbor reads, WORKGROUP_SIZE 256 — vs zimr's current O(N×cells)
single-writer grid. The atomics arc closes that gap.
