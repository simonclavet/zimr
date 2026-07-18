# Render plan — design doc

Locked decisions from the renderer design conversation, plus the
phase plan for landing it.  This is the source of truth for the
v1 renderer; future sessions read this before touching `scene.zig`,
`render.zig`, or `resources.zig`.

## Architecture in one paragraph

A persistent `Renderer` struct (machine state — shader cache,
shadow maps, fullscreen quad) consumes a transient `RenderList`
(flat arrays — pre-resolved draws, lights, camera) produced by
`scene.compile(...)` from an ECS world.  ECS is the storage layer:
renderables are entities with `Transform` + `MeshDraw`, lights are
entities with `Transform` + `LightDraw`, cameras are entities with
`Transform` + `Camera`.  **No singletons** — scene-level state
(ambient, fog, skybox) is also components: `AmbientLight` (multiple
sum), `Skybox` (first wins), `FogVolume` (smallest containing wins
per camera).  GPU resources (Mesh, Texture2D, Shader, RenderTexture)
are stored in typed pools owned by a `Resources` struct and
referenced everywhere by `pool.Handle(T)`.

```
ECS world          scene.compile()        RenderList         Renderer.render()
─────────          ───────────────        ──────────         ────────────────
entities,    ──►   walk tree,        ──►  flat arrays   ──►  cull, sort,
components,        sum ambient,           of resolved        shadow pass,
Node tree          pick fog volume,       draws, lights,     main pass,
                   build bounds           ambient, fog,      skybox, post
                                          skybox
```

## Locked decisions

| # | Question | Decision |
|---|---|---|
| 1 | Default storage | ECS (entity + components per renderable) |
| 2 | Material model | Closed enum of shading models; `Lit` is the uber-PBR with `#define` permutations; `Unlit` / `Sprite` / `Wireframe` / `Custom` are dedicated programs |
| 3 | Renderer lifetime | Persistent struct, init once, deinit once, threaded through |
| 4 | Components | `Transform` (shared with physics) + `MeshDraw` (bundled render data) |
| 5 | Lights | Entities with `Transform` + `LightDraw` |
| 6 | Cameras | Entities with `Transform` + `Camera` |
| 7 | Pipeline | ECS → `compile()` → `RenderList` → `Renderer.render()` |
| 8 | Resource handles | `pool.Handle(T)` for every GPU resource type, owned by a `Resources` struct |
| 9 | Scene-level state | **No singletons.**  `AmbientLight`, `Skybox`, `FogVolume` are components on entities; multiple-of-each is meaningful (sum / first / per-camera-pick) |
| 10 | Background color | On `RenderTarget` (per-render-call), not on a world entity — different cameras can clear to different colors |
| 11 | Split-screen | Multiple `compile()` + `render()` calls per frame, each with its own `Viewport` for placement and `clear_color = null` on subsequent passes to preserve earlier ones |
| 12 | Fog volumes | Per-camera selection in v1: smallest `FogVolume` containing the camera's world position wins.  Per-pixel volumetric blending is v2. |

## Files

```
src/
├── scene.zig          (NEW)   types + compile()
├── resources.zig      (NEW)   Resources struct + handle aliases
├── render.zig         (NEW)   Renderer + multi-pass dispatch
└── notes/
    └── render-plan.md (this file)

examples/
├── pbr_demo.zig       (NEW)   single-camera demo of the full pipeline
├── split_screen.zig   (NEW)   two cameras + per-camera fog (no-singleton proof)
```

## DAG position

```
types ← pool ← drawing ← resources ← scene ← render
              (loaders)             (handles only)  (derefs handles)
```

`scene.zig` doesn't depend on `resources.zig` at runtime — it only
uses the handle alias types, which are pure type aliases.  This
keeps `compile()` free to operate on handles without dereferencing
them.  `render.zig` is the only module that dereferences.

## Phase plan

| Phase | Lands | Status |
|---|---|---|
| **P1** | Types + `compile()` for opaque-only, no lights | ✅ shipped |
| **P2** | `Renderer.init/render/deinit`, `Resources` struct, Unlit + Lit (no lighting) | ✅ shipped |
| **P2.5** | No-singleton refactor: drop `SceneSettings`, add `AmbientLight` / `Skybox` / `FogVolume` components.  Restructure `RenderTarget` for split-screen.  Add `split_screen.zig`. | ✅ shipped |
| **P3** | Lights gather + Lit lighting (PBR, no shadow) | ✅ shipped |
| **P4** | Single directional shadow map | ✅ shipped |
| **P5a** | Gradient skybox pass + Wireframe material routing | ✅ shipped |
| **P5b** | Sprite (textured billboard) material + cubemap skybox | next |
| **P6** | Cheatsheet entries + plan doc finalize | |

## v2 (filed, not designed)

- Per-pixel volumetric fog blending (current is per-camera)
- Spot + point shadows (cubemap shadow rendering)
- Skinned mesh / bone palette upload
- Instancing (`instance_count > 1` path)
- Post-process chain (bloom, tonemap, FXAA)
- LOD component + selection
- Layer-mask culling on the camera side
- Toon, Lambert, Matcap material variants
- Raycaster (picking)
- Cascade shadow maps
- Cubemap loading + procedural skybox shader
- Migration of existing 45 examples to `Resources`

## Component types (see `src/scene.zig`)

```zig
// --- Renderables ---
pub const Transform = struct { position, rotation, scale };
pub const MeshDraw = struct {
    mesh: MeshHandle,
    material: Material,           // tagged union
    layer_mask: u32,
    cast_shadow: bool,
    receive_shadow: bool,
    visible: bool,
    local_bounds: Sphere,
    instance_count: u32,
};

// --- Lights (per-entity) ---
pub const LightDraw = union(enum) {
    directional: DirectionalLight,
    point:       PointLight,
    spot:        SpotLight,
};

// --- Camera (per-entity) ---
pub const Camera = struct {
    projection: Projection,       // perspective or orthographic
    near: f32, far: f32,
    layer_mask: u32,
};

// --- Scene-level state (per-entity, no singletons) ---
pub const AmbientLight = struct { color, intensity };       // sums
pub const Skybox = union(enum) { cubemap, gradient };       // first wins
pub const FogVolume = struct {
    shape: Shape,                                             // infinite/sphere/aabb
    fog: Fog,
};
```

## Render target

```zig
pub const RenderTarget = struct {
    surface: Surface = .screen,
    viewport: ?scene.Viewport = null,    // null = full surface
    clear_color: ?Color = slate_950,     // null = preserve (split-screen 2nd half)
    clear_depth: bool = true,
};
```

## Known seams (will revisit)

- **Material reuse**: `Material` is inline-by-value on `MeshDraw`.  For thousands of entities sharing one material, profiling may push us toward `MaterialHandle` pointing at a pool entry.  Filed for after v1 ships.
- **Bounding info source**: `MeshDraw.local_bounds` is currently user-provided.  Should eventually default to `Resources.mesh(handle).bounding` once mesh-side bounding is computed.  Filed for P2.
- **Sort key**: v1 ships submission-order = draw-order.  64-bit sort key (front-to-back opaque, back-to-front transparent, state grouping) is filed for P2-bonus.
- **Migration**: existing 45 examples don't change in v1.  They keep using `Texture2D` / `Mesh` directly via standalone loaders.  Migration to `Resources` is a separate effort.

