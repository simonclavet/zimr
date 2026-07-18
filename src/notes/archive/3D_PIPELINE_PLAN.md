# 3D Pipeline System — Design Plan

## DECISIONS (locked, Q1–Q5)

| Q | Decision | Choice |
|---|---|---|
| Q1 | Easy-path mechanism | **Immediate-mode (rlgl)** — `vertex3f` + matrix stack → MVP + a depth-tested 3D batch; `drawCube`/`drawGrid`/`drawLine3D` batch each frame |
| Q2 | Camera/pass integration | **Single shared pass with depth (B1)** — the backbuffer pass carries depth when `window.depth_format` is set; 3D batches into it with **no pass switch**, and 2D pipelines carry a `compare=always` depth state so they compose on top (HUD after the 3D flush). *(REVERSED from the earlier "dedicated depth-isolated pass" choice. Multiple render passes on the swapchain image tile/ghost on tile-based mobile GPUs — confirmed by A/B: single-pass `cube_demo` is clean, the 3-pass path tiled, count scaling with width. One pass on the presented image is the fix. `reopen2DPass` now serves only `endTextureMode`/RTT; the `flushBatch` `!has_depth` assert was removed since the 2D pipeline is now depth-aware.)* |
| Q3 | Easy-path lighting | **Default directional light** (faces shaded by normal·light); `setLight(dir,color)` to adjust; unlit available as a material |
| Q4 | Materials / PBR | **Keep `z.pbr3d` separate** (advanced multi-pass PBR + shadows + glTF); add **unlit + lambert** simple single-pass materials for primitives + the easy path |
| Q5 | Camera control | **Built-in controller** — `updateCamera(camera, mode)` orbit / free-look / first-person, mouse + touch (drag-rotate, pinch/wheel-zoom); `Camera3D` stays fully exposed underneath |

**Resulting shape:** three layers on one stack — **Power** (`Resources`/pipeline/shader, untouched) · **Retained** (`Mesh` from `genMesh*`/`loadModel`/custom, `Material` = unlit/lambert/custom, `drawMesh`/`drawModel`/`drawMeshInstanced`; advanced PBR routes to `pbr3d`) · **Immediate easy path** (`beginMode3D`/`endMode3D` opening a dedicated depth pass, `drawCube`/`drawCubeWires`/`drawSphere`/`drawGrid`/`drawLine3D` batched, default light, `updateCamera`). Instancing (`drawMeshInstanced`) is in the build order (Step 4) and unblocks the 3D `physics_pyramid`. Primitives are added incrementally as the sweep needs them.

---


Goal: the best 3D system for zimr — **power users get total control**, **beginners get an
optional easy path**, and the easy path is *sugar over* the power path (one layered system,
never a parallel one). Raylib parity where it helps.

---

## 1. Where we are (grounded)

What exists on the wgpu surface today:

- **Power primitives (full control):** `z.shader.Resources(Schema)` (typed UBO + samplers +
  bind groups), `z.descriptor_encoder` (vertex layouts, pipeline descriptors),
  `z.pipeline_cache` (`StateCombo`), `z.wgpu.createRenderPipeline`, `z.render_pass`
  (`setVertexBuffer`/`setIndexBuffer`/`drawIndexed`), `shader_interface` (`si`), and the
  Zig-DSL / WGSL shader system. `cube_demo` and `lambert_demo` hand-roll with these.
- **A retained PBR renderer:** `z.pbr3d.Renderer` + `z.pbr3d.Model` + `renderer.loadGltf(glb)`
  — `pbr_demo` and `gltf_textured` use it (metallic-roughness, 5 PBR maps, lights, shadows).
- `Camera3D` (= `zm.Camera3D`), `beginMode3D`/`endMode3D`.

What's missing:

- `beginMode3D` sets an rlgl matrix stack, but it's **disconnected** from the renderer (which
  uses a single ortho `view_projection` uniform). No `vertex3f`, no depth on the 2D pass path.
- No **immediate 3D** (`drawCube`/`drawCubeWires`/`drawGrid`/`drawLine3D`/`drawSphere`).
- No **unified Mesh/Material/Model** for non-PBR (unlit/lambert) or **instancing**.
- No **mesh generation** (`genMeshCube`/`Sphere`/`Plane`/`Cylinder`).

So the power tier and a PBR retained tier exist; the **simple middle** and the **easy tier**
do not.

---

## 2. The design space (the deep study)

### A. Easy-path mechanism — immediate vs retained
- **A1. Immediate-mode (rlgl-style).** Extend the renderer to 3D: add `vertex3f`, make the
  matrix stack feed a per-draw MVP, add a depth-tested 3D batch pipeline; `drawCube`/`drawGrid`
  /`drawLine3D` batch into it, flushed at `endMode3D`. *Pros:* raylib-faithful; batches many
  small primitives (grids, debug shapes, particle cubes) into few draws; the GL backend already
  has this logic to port. *Cons:* real renderer surgery (3D batch + matrix→MVP + depth).
- **A2. Retained-backed.** `drawCube(c,size,color)` = `drawMesh(builtin_cube, default_mat,
  model)`. *Pros:* minimal surgery, reuses the retained tier. *Cons:* one draw call per
  primitive — a 100-line grid is 100 draws; bad for debug/particle use.
- **A3. Hybrid.** Immediate batch for lines/wires (`drawGrid`, `drawLine3D`, `drawCubeWires`);
  retained `drawMesh` for solids. Best-of-both, two code paths.
- **Recommendation: A1.** Raylib-faithful, batches well, and the GL backend's rlgl logic ports
  over. It's the bigger build but the most consistent (a real immediate-mode 3D layer mirroring
  the 2D one). The retained tier coexists for assets.

### B. Camera + pass integration with the 2D pass
- **B1. Shared backbuffer pass + depth.** `beginMode3D` draws into the main pass (it already
  has a depth attachment); the 3D pipeline depth-tests; the 2D HUD draws depth-disabled (always
  on top). Clear depth once per frame. *Pros:* one pass, HUD-over-3D natural. *Cons:* must add
  a depth-clear and a depth-disabled 2D state.
- **B2. Dedicated 3D pass.** `beginMode3D` switches to a depth-isolated 3D pass (like
  `beginTextureMode`), then back. *Pros:* clean depth separation. *Cons:* extra pass switches;
  more state shuffling.
- **Recommendation: B1.** The backbuffer pass already carries depth; HUD-over-3D falls out of a
  depth-disabled 2D state. Just needs a per-frame depth clear.

### C. Material model
- A `Material` = pipeline (shader + state) + bind data (uniforms/textures), built on the
  existing `Resources(Schema)` + `pipeline_cache`.
- Built-ins: **unlit** (flat / vertex colour), **lambert** (one directional light, diffuse),
  **pbr** (reuse `z.pbr3d` — metallic-roughness + maps + lights + shadows).
- `drawMesh(mesh, material, transform)`; `drawModel(model, transform)` (model carries material).
- Power: a custom `Material` from a custom shader + pipeline state.
- **Recommendation:** three built-ins (unlit / lambert / pbr), `pbr` reusing `z.pbr3d`.

### D. Lighting for the easy path
- **D1. Unlit (flat).** `drawCube` flat-coloured — raylib-exact, but reads flat.
- **D2. Default directional light.** A built-in light shades faces by normal·light so beginner
  3D looks 3D; `setLight(dir, color)` to adjust; unlit still available.
- **Recommendation: D2** — a sensible default light so cubes read as solids, not flat patches
  (a small, deliberate divergence from raylib for "nice to look at").

### E. Mesh sources
- Generated: `genMeshCube`/`genMeshSphere`/`genMeshPlane`/`genMeshCylinder` (+ maybe cone/torus).
- Loaded: `loadModel(gltf)` (generalise `pbr3d.loadGltf`).
- Custom: `Mesh.fromData(positions, normals, uvs, indices)` (power).
- **Recommendation:** cube/sphere/plane/cylinder + `loadModel` + custom `Mesh`.

### F. Instancing
- `drawMeshInstanced(mesh, material, transforms[])` — one draw, N per-instance model matrices
  (+ optional per-instance colour). Needed for `physics_pyramid` (78 boxes), `instancing`,
  particle cubes.
- **Recommendation:** yes — a per-instance model-matrix(+colour) buffer + an instanced pipeline.

### G. Shaders
- Built-in materials use **baked WGSL** (like the 2D renderer's WGSL and pbr's WGSL). Power
  users supply custom shaders (Zig-DSL or WGSL).
- **Recommendation:** baked WGSL for built-ins; custom shaders for the power path.

---

## 3. The proposed system (three layers, one stack)

- **Layer A — Power (exists; formalise + document):** `Resources(Schema)` + pipeline + shader +
  `render_pass`. The escape hatch; nothing above hides it.
- **Layer B — Retained (build):** `Mesh` (gen* / `loadModel` / custom) · `Material`
  (unlit/lambert/pbr/custom) · `Model` (mesh+material) · `drawMesh`/`drawModel`/
  `drawMeshInstanced`. Reuse `z.pbr3d` as the pbr material.
- **Layer C — Immediate easy path (build):** the 3D immediate renderer (`vertex3f` + matrix→MVP
  + depth batch) · `drawCube`/`drawCubeWires`/`drawSphere`/`drawGrid`/`drawLine3D` ·
  `beginMode3D`/`endMode3D` · `setLight`. Beginner sugar, batched.

`beginMode3D(camera)` establishes the camera (view-proj) + depth; Layer C batches immediate
draws, Layer B issues retained draws, `endMode3D` flushes; 2D HUD draws after (depth-disabled).

---

## 4. Build order — STATUS (✅ done · ◻ remaining)

### ✅ Step 1 — 3D pass + depth + camera wiring  [DONE]
`beginMode3D(cam)` computes `view_proj = perspectiveFovRh × lookAtRh`, sets it on the batch UBO,
and starts a fresh batch — **no pass switch**. The backbuffer pass (opened by `beginDrawing`)
carries a `depth24_plus` attachment when `window.depth_format` is set; 3D batches into that
single pass and flushes (depth-tested) at `endMode3D`. The 2D pipelines carry a `compare=always`
depth state so 2D composes on top (drawn after the 3D flush). Shader is the Zig-pipeline
`cube3d_vs/fs` (one group-0 UBO = `view_projection`). *(Landed as B2/dedicated-pass first, then
reversed to B1/shared-pass after the multi-pass-on-swapchain ghost on mobile — see Q2.)*

### ✅ Step 2a — immediate solids + lines  [DONE]
Immediate batch (`src/draw3d.zig`): world-space verts baked CPU-side, one draw per topology
(a triangle batch + a line batch), shared `cube3d` shader, one global view-proj uniform (no
per-primitive UBO → no single-UBO hazard). **Shipped:** `drawCube`, `drawCubeWires`,
`drawGrid`, `drawLine3D`, `drawSphere`, `drawCylinder`. Triangle pipeline is cull-`.none`
(depth handles convex occlusion → mesh winding irrelevant). Default directional light baked in
the VS (per-face flat shading); lines carry the light-direction normal to render unlit. Fixed
65 536-vertex buffers per stream.

### ◻ Step 2b — immediate finish  [REMAINING · small]
- `drawCubeEx(center, size: Vec3, angleRad, axis, color)` + `drawCubeWiresEx` — bake a rotation
  into the cube append (rotate position + normal; `zm.matFromAxisAngle` or hand-built R; verify
  `matFromAxisAngle` exists in zm first).
- `drawPlane(center, size: Vec2, color)` — one XZ quad (2 triangles, normal +Y).
- `setLight(dir, color)` — promote the shader's fixed light to UBO fields (`light_dir`,
  `light_color`), set a sane default at `beginMode3D` + expose a setter.
- `updateCamera(camera, mode)` — orbit / first-person / free-look; mouse **and** touch
  (drag-rotate, wheel/pinch-zoom). `Camera3D` stays fully exposed underneath.
- **Gate:** probe with a rotated cube, a plane, and an interactive orbit camera.
- **Unblocks (portable right after 2b):** `cube3d`, `wireframe`, `first_person_camera`,
  `ecs_solar_system` (spheres), `physics_demo` (if primitives-only).

### ◻ Step 3 — retained Mesh / Material / Model  [REMAINING · medium]
- `Mesh` — GPU vertex(pos, normal, uv) + index buffers; `Mesh.fromData(...)` (custom/power);
  `deinit`.
- `genMeshCube/Sphere/Plane/Cylinder` → `Mesh` (reuse the Step-2 generator math).
- `Material` — `.unlit` | `.lambert` | custom (pipeline + bind data over `Resources(Schema)`).
- `Model` = mesh + material (+ transform); `drawMesh(mesh, material, M)`, `drawModel(model, M)`.
- `loadModel(glb)` — non-PBR path (or route to `pbr3d` for textured/PBR assets).
- **Gate:** a generated sphere `Mesh` + a loaded `Model` render.
- **Unblocks:** `models3d`, `dynamic_mesh`, `typed_unlit_demo`, `billboards` (+ a `drawBillboard`
  camera-facing quad), `skinned_mesh` (skinning is a later sub-step).

### ◻ Step 4 — instancing  [REMAINING · medium]
- `drawMeshInstanced(mesh, material, transforms[], colors[])` — per-instance model-matrix(+colour)
  buffer with `step_mode = .instance` on the model rows + an instanced pipeline.
- **Gate:** 78 instanced cubes at 60 fps.
- **Unblocks:** `physics_pyramid` (full 3D — the marquee), `instancing`, particle-cube scenes.

### ◻ glTF / PBR examples — via existing `z.pbr3d`  [REMAINING · wiring only]
`gltf_simple`, `gltf_model_refs`, `damaged_helmet`, `skinned_mesh` route to the **existing**
`pbr3d.Renderer` + `loadGltf` (proven by `gltf_textured`). No new retained engine work — port +
scaffold + screenshot. Sequence these alongside Step 3 (they don't depend on it).

### ◻ skybox — separate  [REMAINING · small-med]
Cubemap texture + a skybox pipeline (depth `≤`, no cull, view-rotation-only matrix). `skybox` only.

### ◻ Step 5 — formalise the power path  [REMAINING · docs]
Document the Power tier (`Resources`/pipeline/shader/`render_pass`) + minor API polish. No new code.

---

## 5. Risks (updated)
- ~~Depth integration with the shared 2D pass~~ — resolved by going depth-free 2D + dedicated 3D pass.
- `drawCubeEx` rotation: confirm `zm.matFromAxisAngle` (or equivalent) before relying on it.
- `updateCamera` touch gestures overlap with **F4 (gesture input)** — share the recognizer code.
- Folding `z.pbr3d` in as the "pbr material" of Layer B vs leaving it as a parallel renderer —
  for now keep it parallel (glTF examples call it directly); unify only if Layer B demands it.
