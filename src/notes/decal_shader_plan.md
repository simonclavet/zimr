# decal_shader_plan.md — shader-projected decals (real-engine technique)

## Why
The zimr549–553 decal example clips the target mesh per-triangle
(Sutherland–Hodgman against a projector box) and re-uploads the clipped
geometry. That works on coarse meshes (the ~1500-tri sphere) but shatters
on a dense mesh: the Stanford bunny has 69,451 tris and ~5,400 fall inside
a single decal box, so the fixed 96-tri output cap captures a scattered
2% subset → fragments. Per-triangle mesh clipping fundamentally does not
scale; real engines never do it.

## Technique (deferred/forward decal projection)
Draw the RECEIVER mesh a second time with a decal pipeline. For each
fragment: transform its world position by a projector matrix (world→decal
box space, the same `lookAt·rotZ` the clip approach built), and if it lands
inside the box `[-s,s]³`, sample the decal texture at the box-space XY (the
planar UV) and alpha-blend over the scene. No clipping, no geometry upload —
the decal "paints" onto whatever fragments fall in the box. Scales to any
mesh density for free.

## Architecture decision
Do NOT modify the shared cube3d batch shader (every 3D example uses it;
adding decal uniforms + a texture array to it is invasive and risks the
whole 3D path). Instead add a DEDICATED decal-receiver pipeline in draw3d,
modeled on the existing `tex_pipeline`/`billboard_pipeline` (small, self-
contained, shares the camera UBO at group 0). It re-draws the receiver
mesh's triangles (already in the batch's world-space form) with:
  - a per-decal uniform: { inv_projector: mat4, decal_color: vec4 } where
    inv_projector = the world→box `projection` matrix (NOT inverse — we map
    world fragment → box space, so it IS `projection`).
  - group 1 = the decal {texture, sampler} (billboard_fs sampler pattern).
  - VS: standard world→clip via camera UBO (reuse cube3d VS math), passing
    the WORLD position to the FS as a varying.
  - FS: box = projection · worldPos; if any |box.xy| > s or |box.z| > s →
    discard; else uv = box.xy/decal_size + 0.5; sample; output
    texel * decal_color with the texel's alpha (blend state does the rest).
  - depth: test `.less_equal` (receiver already wrote depth), NO write, so
    decals lie on the surface without z-fighting and blend by draw order.
  - blend: standard src-alpha / one-minus-src-alpha.

## Receiver-mesh redraw
The decal pass needs the receiver's world-space triangles. Options:
  (A) keep a persistent GPU vertex buffer of the receiver mesh (pos only)
      and issue one draw per decal binding that decal's uniform. Cleanest.
  (B) re-emit the receiver tris into a batch each decal. Wasteful.
Choose (A): upload the receiver mesh's world-space positions ONCE
(decal_mesh_vbo), then per decal: set the decal uniform + decal texture,
draw the whole vbo. N decals = N draws of the same vbo. For the example
that's fine (≤64 decals × ~70k verts — but see perf note).

PERF NOTE: 64 decals × 69k tris = 4.4M verts/frame of overdraw. Acceptable
for a demo on desktop GPUs; if it stutters, cap active decals or add a
coarse per-decal bounding-sphere reject on the CPU (skip drawing a decal
whose box doesn't intersect the view). Start simple, measure, optimize only
if needed.

## Steps (each ends green: lint 0, standalone build, smoke PASS, gate)
1. [engine] New DSL shaders src/shaders/decal_vs.zig + decal_fs.zig (+ _io
   for the VS ubo). VS: world→clip + pass world pos varying. FS: projector
   test + discard + sample + tint. Auto-discovered by build.zig.
   Deliverable: shaders compile (corpus-diff/test green), WGSL emitted.
2. [engine] draw3d: DecalSchema ubo {projector: mat4, color: vec4, size},
   decal_pipeline (blend + less_equal + no-write), a persistent receiver
   vbo upload helper, and a `drawDecalProjector(mesh_vbo, projector, tex,
   color)` record path. Public: z.beginDecalReceiver(mesh) / z.drawDecal(
   projector, tex, color) or a simpler retained handle. API TBD in step.
3. [example] Rewrite decals.zig receiver path: upload sphere + bunny as
   decal-receiver meshes; store per-decal { projector, color, target };
   draw each decal by re-projecting onto its target. DELETE the CPU clip
   path (genDecal/clipPoly/readTri/fullyOutside) once the shader path works.
4. [polish] Remove debug HUD + oriented box. Verify bunny decals are clean
   discs. Update raylib_port.md + claude.md.

## Fallback
If the projector-in-FS proves too invasive for the DSL/spv2wgsl pipeline
in step 1–2, fall back to keeping the CPU clip for the sphere and simply
note the bunny needs the shader path (partial). But the FS math is simple
(one mat·vec + range test + one sample), so the DSL should handle it.

## Status
Step 1 DONE (shaders written + lint-clean + compile through discovery):
  - src/shaders/decal_vs.zig — world→clip + world-pos varying (o_world @0).
  - src/shaders/decal_fs.zig — projector test (world→box via proj.projector),
    discard-if-outside (transparent), planar UV, zsample2d at group 2, tint.
  - Bindings: group 0 = camera UBO (VS), group 1 = Proj ubo
    { projector: mat4, color: vec4, params: vec4 (x=half, y=1/decal_size) },
    group 2 = decal {texture, sampler}.
Foundation also DONE:
  - wgpu.zig DepthMode gained `less_equal_no_write = 8` (test less-equal, no
    write) — decals lie exactly on the receiver's depth (equal passes) and must
    not re-write (so stacked decals don't z-fight). Wired into depthCompare +
    writesDepth exhaustive switches. Gate green.

NEXT (step 2 — the pipeline wiring in draw3d.zig, the larger half):
  - Cube3D fields: decal_pipeline, decal_proj_bgl (group 1 UBO layout),
    decal_tex_bgl (group 2, reuse tex_bgl shape), a projector-UBO RING
    (≥8 slots — reuse the pbr3d ring lesson to avoid queue-timeline clobber),
    a receiver-mesh VBO registry (pos-only, uploaded once per mesh), and a
    decal-draw record list { receiver_vbo, vcount, proj_slot, tex_bg }.
  - createBindGroupLayout for group1 (uniform) reusing resources.bg_layouts[0]
    for group0 and tex_bgl-shaped for group2; pipeline_layout = 3 groups.
  - makePipeline(... .triangle_list, .back cull, .less_equal_no_write ...).
    NB decal_vs takes pos-only vertex layout (stride 12, one float32x3 @0).
  - Public API sketch: z.uploadDecalReceiver(mesh) -> handle (persistent
    pos-only vbo); z.drawDecal(gl, receiver_handle, projector: Mat, tex,
    color) records one draw. Flush in the same 3D pass after solids, before
    endMode3D, writing each projector to a fresh ring slot + binding.
  - Then step 3: rewrite decals.zig to use it (delete genDecal/clipPoly/
    readTri/fullyOutside); step 4: remove debug HUD, verify bunny clean.


## Status update (steps 2-3 DONE)
Step 2 (engine) + Step 3 (example) COMPLETE and gated green. draw3d has the
decal_pipeline (group0 camera / group1 projector-UBO ring of 64 pre-built
bind groups at 256-B stride / group2 texture), uploadDecalReceiver (de-index
to pos-only vbo) + drawDecal (write projector to ring slot, record) + flushDecals
(bind + redraw receiver, less_equal_no_write depth). Public z.uploadDecalReceiver
/ z.drawDecal / z.DecalDesc. decals.zig rewritten: receivers uploaded once,
decals store {projector, color, receiver}, drawn via z.drawDecal; ALL CPU-clip
code deleted (genDecal/clipPoly/readTri/fullyOutside, ~165 lines). Step 4
(remove debug HUD + oriented box) pending device verification of the bunny.
NOTE: bridge setBindGroup has NO dynamic-offset support, so per-slot bind groups
bake the offset (pbr3d-ring pattern), not one bind group + dynamic offset.

## Shader-pattern note (why decal uses direct @SpirvType, not IoT)
Investigated the two shader patterns during this work:
- **IoT pattern** (`<name>_io.zig` + often `<name>_common_io.zig`): for shaders
  that SHARE a uniform set or varyings with sibling shaders. The value is the
  `_common` merge — e.g. cube3d_common_io defines the VS→FS `Interp` varyings
  ONCE and cube3d_vs/fs/instanced_vs/cel_fs all import it, so VS-out ==
  FS-in by construction. Same for the pbr/gbuffer/lambert/lit_shadow families.
  Also mirrors the host `Resources(Schema)` UBO so GPU+CPU layouts stay synced.
- **Direct `@SpirvType`/`@extern`** (billboard, skybox, points, fluid_discs,
  decal): for SMALL STANDALONE single-consumer pipelines that share nothing.
  IoT ceremony would be pure overhead; the whole shader reads top-to-bottom in
  one file.
RULE: IoT iff the shader shares uniforms/varyings with siblings; direct for a
self-contained one-off. Audited: ZERO drift — every IoT shader imports a
_common (none over-engineered), and every direct shader is genuinely single-use.
Decal is correctly direct. No unification needed; the split is principled.
