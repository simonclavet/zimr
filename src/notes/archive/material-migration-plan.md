# Material Migration — Plan (Option B)

Multi-turn rebuild of the Material system to make materials
first-class ECS citizens, aligned with Texture/Mesh/Shader/RenderTexture
patterns.  Brainstormed turns 132+; design questions Q1-Q4 settled
before kickoff.

## Locked design (from brainstorm)

| Q | Decision |
|---|----------|
| Q1 — shape | Material is `Ref(GpuMaterial)` — an entity, like every other GPU resource. |
| Q2 — struct | `GpuMaterial` is slot-array (`maps: [MAX_MATERIAL_MAPS]GpuMaterialMap`) with a comptime `map(.diffuse)` accessor.  Inline array, no heap alloc. |
| Q3 — constructors | Generic `Material.spawn` + 4-5 named helpers (`spawnLitMaterial`, `spawnUnlitMaterial`, `spawnSpriteMaterial`, `spawnWireframeMaterial`, optionally `spawnPbrMaterial`).  Helpers mirror the legacy MaterialDescriptor variants. |
| Q4 — world | `Resources` gains a `materials` field.  Renderer owns a private `priv_materials` world for shadow/skybox built-ins (clean ownership; user's `worlds.materials.deinit` doesn't touch renderer's stuff). |

## Constraints (from Simon)

- Don't care about raylib ABI compat — `types.Material` can change shape
  or be deleted.
- Don't care about breaking examples — every example gets rewritten
  as needed.
- Explicit, performant, understandable code.
- No globals.
- One way of doing things.

## Target user code

```zig
// In init:
var worlds: gpu.Resources = try .init(.{ .gpa = gpa, .cap = ... });
defer worlds.deinit(gpa);

const red_lit: gpu.Material = try gpu.spawnLitMaterial(gpa, &worlds.materials, .{
    .albedo_color = colors.red,
    .albedo_tex = my_tex,  // a gpu.Texture2D ref
});

const my_mesh: gpu.Mesh = try gpu.genMeshCube(gpa, &worlds.meshes, 1, 1, 1);

// In update:
gpu.drawMesh(f.gl, &worlds, my_mesh, red_lit, transform);
// or:
renderer.append(.{ .mesh = my_mesh, .material = red_lit, .world = transform });
```

No `MaterialDescriptor` union.  No per-draw struct rebuild.  Materials
spawned once, reused.  Bundle support, hot-reload, runtime metadata
attachment all fall out for free.

## What the rlgl boundary sees

`types.Material` survives strictly as the **transient wire format**
that `drawing.models.drawMesh` consumes.  Each `gpu.drawMesh` call
realizes the GpuMaterial into a stack-allocated `types.Material` via:

```zig
pub fn realizeMaterial(
    gpu_mat: *const GpuMaterial,
    worlds: *const Resources,
    maps_scratch: *[MAX_MATERIAL_MAPS]types.MaterialMap,
) types.Material {
    // Field-copy GpuTexture→types.Texture for each map slot.
    // Field-copy GpuShader→types.Shader.
    // Return types.Material whose maps points at maps_scratch.
}
```

The 144-byte `maps_scratch` lives on the caller's stack.  No allocation
per draw.  At the rlgl boundary the existing `types.Material` shape is
preserved — we don't touch drawing.zig's internals.

## Phases

### Phase 1 — Define new types (this turn)

- Add `MaterialMapIndex` enum (diffuse=0, specular=1, normal=2,
  roughness=3, metalness=4, emission=5, occlusion=6, height=7,
  cubemap=8, irradiance=9, prefilter=10, brdf=11).  12 slots, mirrors
  rlgl's MaterialMapIndex.
- Add `GpuMaterialMap = struct { texture: Texture2D, color: Color, value: f32 }`.
- Add `GpuMaterial = struct { shader: Shader, maps: [MAX]GpuMaterialMap, params: [4]f32, fn map(comptime kind) }`.
- Add `Material = Ref(GpuMaterial)` alias.
- Add inline tests for type shape + `map()` accessor.

No production usage yet.  Everything legacy still compiles and runs.

### Phase 2 — Realize step

- Add `realizeMaterial(gpu_mat, worlds, scratch) types.Material`.
- Test against a known input: build a GpuMaterial with specific values,
  realize against a populated Resources, verify the wire-format struct
  has the expected ids/colors/values.

Still no production usage.

### Phase 3 — `materials` field in Resources

- Extend `Resources` struct + its init/deinit.
- Update all Resources construction sites (renderer init, example init).
  Probably ~20-30 sites; mechanical.

### Phase 4 — Spawn helpers

- Add `spawnLitMaterial`, `spawnUnlitMaterial`, `spawnSpriteMaterial`,
  `spawnWireframeMaterial`.  Each takes a designated-init struct of
  args, fills the appropriate slot pattern, returns a Material ref.
- Tests for each helper.

### Phase 5 — `gpu.drawMesh` takes Material ref

- Rename current `gpu.drawMesh(gl, meshes, textures, shaders, mesh, material: types.Material, transform)`
  to something like `drawMeshWireFormat` (kept for renderer's
  legacy path during transition).
- New `gpu.drawMesh(gl, worlds, mesh: Mesh, material: Material, transform)` derefs both refs, realizes, and dispatches.
- Tests.

### Phase 6 — Renderer migration

- DrawCommand's `material: MaterialDescriptor` → `material: gpu.Material`.
- Renderer's `priv_materials: ecs.Entities` initialized in renderer init.
- `shadow_material` and `skybox_material` become `gpu.Material` refs
  spawned in `priv_materials`.
- Delete `MaterialDescriptor` union + `configureMaterial` helper.
- All renderer draw paths route through `gpu.drawMesh`.

### Phase 7 — glTF loader update

- `loadModelFromGltfMemory` builds `Material` refs instead of
  `types.Material` values.  Each glTF material gets one Material entity
  in the user's materials world.
- `Model.materials` becomes `[]Material` (refs).
- `Model.deinit` destroys material entities.
- Update `gltf_model_refs` example accordingly.

### Phase 8 — Example sweep

- ~30 examples currently use `MaterialDescriptor`.  Each needs:
  - A `materials` world (from Resources, or per-example as appropriate).
  - Material spawn calls in init.
  - DrawCommand updates to pass Material refs.

Mechanical.  Done one example at a time with smoke verification per
batch.

### Phase 9 — Cleanup

- `types.Material` survives but is now ONLY the rlgl wire format.
  Document the role change.  Consider moving to `drawing.zig` namespace
  (rename to `drawing.RlMaterial` or similar) to make the role explicit.
- Audit for any remaining direct uses of `types.Material` in
  user-facing positions — there should be none.

## Risks

1. **Phase 6 blast radius**.  The renderer is a big module; touching
   DrawCommand changes every draw path.  Mitigation: keep the legacy
   path alive in Phase 5 (rename, don't delete); migrate renderer in
   Phase 6 with the legacy fallback as a safety net; delete the
   fallback only in Phase 9.

2. **Example count**.  30+ examples to migrate is genuine work.
   Mitigation: spawn helpers (Phase 4) mirror MaterialDescriptor
   variants exactly, so migration is search-replace.

3. **Renderer's private world bootstrapping**.  Renderer init needs to
   create `priv_materials` AND spawn the built-ins.  Bootstrap order:
   shaders need to exist before materials reference them.  Mitigation:
   renderer init takes user's shaders world via Resources, spawns
   shadow/skybox shaders there if not provided, then spawns built-in
   materials in priv_materials referencing those shaders.  (OR
   reconsider whether renderer's built-in shaders should be in the
   user's shaders world or in a separate `priv_shaders` world — TBD
   during Phase 6.)

4. **Performance regression**.  Each draw now does: deref Material →
   deref Shader → deref each used Texture.  4-5 derefs per draw vs
   legacy's 1 (just the texture deref).  Mitigation: each deref is an
   ECS lookup which is ~O(1) chunk indexing.  Should be sub-microsecond
   per draw, well below any frame budget concern.  Will measure with
   the existing smoke benchmarks.

## What I'm NOT doing (deferred)

- Material sorting / texture-binding dedup in the renderer.  Comes
  after Material migration; needs the ref-based foundation.
- HotReloadable shader consumer.  Component exists; renderer system to
  honor it is a separate workstream.
- Bundle queries for materials.  Once materials carry BundleTag, the
  existing `unloadBundle` walker already handles them.
- `types.Material` deletion.  It survives as the wire format until
  someone proves nothing user-facing uses it.

## Audit gates per phase

- `zig build test` — all tests pass.
- `zig build smoke-test` — 48/48 pass (renderer demos byte-identical
  per phase where possible; phase 6+ accepts identical-or-better).
- `zig fmt --check` — clean.
- `check_dag.py` — no new cycles.
- `count_globals.py` — 0/0/0 always.
- `zig build --release=small` — track size delta per phase.  Target:
  ≤+1 KB total across all phases (the additions are mostly small
  helpers; release-mode dead-code elimination should keep size flat).

## Backout

Each phase is small enough to revert independently.  Phase 1-2 (new
types, no usage) are pure additions; trivially backed out by `git
revert`.  Phases 3-7 touch real surface; if any phase blows up, revert
that phase and re-plan.

## Estimated turn count

- Phase 1: 1 turn (this one, partial)
- Phase 2: 1 turn
- Phase 3: 1 turn (mechanical sweep)
- Phase 4: 1 turn
- Phase 5: 1 turn
- Phase 6: 2-3 turns (biggest risk)
- Phase 7: 1 turn
- Phase 8: 2-4 turns (sweep)
- Phase 9: 1 turn

Total: ~11-14 turns.
