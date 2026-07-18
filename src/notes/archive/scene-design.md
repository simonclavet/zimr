# scene-design.md — zimr scene graph + flashy-visuals layer

**Status:** design memo, no code yet.  Companion to `ui-design.md`
(ImGui port plan) and `raylib-ui-integration.md` (UI/raylib bridges).
**Scope:** the optional, opt-in high-level renderer that lets users
build big scenes with cinematic visuals on top of zimr's raylib
foundation — without breaking zimr's "stay out of your way" promise.

---

## Vision

A user should be able to write something like this and get a result
that looks production-quality:

```zig
fn update(_: *App, f: *Frame, state: *State) void {
    state.t += f.clock.frameTime();

    // Animate the scene declaratively.
    state.drone.rotation.y = state.t * 2;
    state.propellers[0].rotation.y = state.t * 50;
    state.sun_light.intensity = 1.0 + @sin(state.t) * 0.3;

    // Render with all the trimmings.
    f.clear(z.colors.slate_950);
    state.scene.render(f, state.camera, .{
        .post = &.{ .bloom, .tonemap_aces },
        .shadows = .directional_only,
        .skybox = state.cubemap,
    });
}
```

What that one `render` call does under the hood:

1. Optional shadow pass → directional light's shadow map RT
2. Sky pass → cubemap as backdrop
3. Main pass → scene graph traversal, frustum-culled, lit with all
   lights, shadowed
4. Post chain → bloom + tonemap, rendered through the surface stack
   we just built
5. Hand back to user code, who can layer UI on top with `f.ui.window(...)`

The user only writes the scene description; zimr does the
orchestration.  And — critically — they can opt out at any layer.
Drop the scene graph and do raw `drawMesh` calls?  Fine.  Keep the
scene graph but skip the post-process chain?  Fine.  Use the lighting
shader but bypass the scene graph entirely?  Also fine.

This memo defines what we'd need to build to make that user code
work, in what order, and how it sits on top of what already exists.

---

## Non-goals

To prevent scope creep, we explicitly will not:

- Reimplement Three.js feature-for-feature.  We're stealing patterns,
  not the API.
- Build a competing material system to raylib's `Material` —
  raylib's already PBR-shaped (albedo / metalness / normal /
  roughness / emission / occlusion slots).  We use it.
- Add a physics engine.  Users wire up Rapier or write their own.
- Support every glTF feature.  v1 imports geometry + base color
  texture + transforms.  Animations, skinning, morph targets are
  later.
- Hide rlgl.  Advanced users still drop into immediate mode anytime.
- Try to be Unreal.  This is a "make web demos look great" tool, not
  a AAA engine.

---

## Survey: what high-level renderers do well

A taxonomy of what makes Three.js / Babylon / Godot / Unity feel
powerful, with notes on what's worth borrowing.

### Scene graph fundamentals — borrow

Every successful 3D library has these:

- **Node hierarchy with TRS transforms.**  `parent.add(child)`,
  matrix composition, world matrix derived from chain.
- **Cascading state.**  Visibility, layer mask, render order, opacity
  inherited from parent.
- **Traversal patterns.**  Visitor for render, query, update.

The Three.js mistake we won't repeat: storing world matrices on every
node and recomputing them every frame.  raylib's rlgl has an actual
GPU matrix stack — when traversing for *render*, we push local
transforms and let the hardware compose.  We only materialize world
matrices when we explicitly need them (lookAt resolution, picking,
frustum cull).  See "Architecture: scene graph" below.

### Mesh trinity — already half-built

Three.js: `Mesh = Geometry × Material × Transform`.

raylib:
- `Mesh` (vertex buffers, indices, attributes) ← have it
- `Material` (shader + texture maps + params) ← have it, with PBR
  slots already named (albedo, metalness, roughness, normal,
  emission, occlusion, height, brdf, irradiance, prefilter, cubemap)
- Transform ← rlgl matrix stack
- `drawMesh(mesh, material, transform: Matrix)` ← already exists

We don't need to invent this.  We need a thin Node wrapper that owns
references and dispatches to `drawMesh` during traversal.

### Materials & shaders — borrow patterns, ship presets

The Three.js material zoo (Basic / Lambert / Phong / Standard /
Physical / Toon / NormalMaterial / Depth / etc.) is overkill.  But
the *idea* of "ship a small set of carefully-tuned shaders so the
user doesn't have to write GLSL day one" is exactly right.

What we ship as preset materials:

- **Basic** — unlit, just tint × albedo texture.  For UI elements,
  decals, particles.
- **Lambert** — single-pass diffuse lighting, no specular.  Cheap,
  good for stylized.
- **Phong** — diffuse + specular + ambient.  The "everything looks
  acceptable" default.
- **Standard PBR** — metallic-roughness workflow with all the maps.
  This is what makes scenes look modern.
- **Toon** — discrete light bands + outline.  For the stylized crowd.

Each is a `Material` instance with the right `Shader` pre-bound.  All
five share an embedded GLSL bundle.  ~5 fragment shaders, ~2 vertex
shaders (skinned vs unskinned), ~600 LOC of GLSL total.

### Lighting — small, fixed set, supports the materials

- **Directional** (sun): direction, color, intensity, optional shadow
  map
- **Point** (lamp): position, color, intensity, range, falloff
- **Spot** (flashlight): position + direction + cone angle + range
- **Ambient**: flat color added everywhere (cheap fill)
- **Hemisphere**: sky color blended with ground color by surface
  normal (great for outdoor scenes)

Hard limit per pass: 8 point + 4 spot + 1 directional + ambient +
hemisphere.  Fits comfortably in shader uniform arrays.  Light
overflow is the user's problem — they can split into multiple passes
or fade distant lights.

Lights are scene graph nodes too (parent-able to a moving object).

### Shadows — directional + 1-2 spots, that's it

The shadow rabbit hole is deep.  v1 ships:

- One shadow-mapped directional light (the sun)
- Optional shadow-mapped spot lights (slot for 2)
- 2K resolution shadow map by default; configurable
- PCF 2×2 filter for soft edges (cheap, looks OK)

What we punt: cascaded shadow maps, VSM/ESM, point-light shadow
cubemaps, contact-hardening, raytraced shadows.

### Cameras & controls — already have the camera, add controls

- `Camera3D` (perspective + orthographic) ← exist
- New: camera as scene graph node (so it can be parented to a
  vehicle, bone, etc.)
- **OrbitControls** — drag to orbit, scroll to zoom, right-drag to
  pan.  ~80 LOC against `InputSnapshot`.
- **FlyControls** — WASD + mouse look.  We have
  `examples/first_person_camera.zig` already; promote it to a
  reusable controls module.
- **OrthoZoomControls** — scroll-zoom + drag-pan for 2D-style
  inspection.  ~50 LOC.

### Post-processing pipeline — leverage the surface stack

The recursive RT system we just built is a post-process pipeline in
disguise.  Each effect = render scene to RT-A, sample RT-A through a
fragment shader to RT-B, repeat.  The surface stack already does the
push/pop of FBOs.

What we ship as preset post effects:

- **Tonemap** (linear → sRGB) — Reinhard, ACES, AgX presets
- **Bloom** — bright-pass + downsample chain + upsample blend
- **FXAA** — cheap edge AA
- **Vignette** — radial darkening
- **Color grading** — LUT lookup
- **Chromatic aberration** — RGB channel offset, looks great on
  bright lights
- **Film grain** — animated noise overlay
- **DOF** — depth-of-field, requires depth buffer access (do later)

The user composes a chain: `.{ .bloom, .tonemap_aces, .vignette }`.
Order matters; we don't reorder for them.

What we punt: SSAO, SSR, motion blur (needs velocity buffer), TAA,
per-light volumetrics.  These are great but each is its own project.

### Animation — punt v1, design for v2

A v1 user animates by mutating `node.position` etc. in their update
loop.  That's enough to ship demos.

For v2:
- **AnimationClip** — keyframe tracks per node property
- **AnimationMixer** — drives clips, blends multiple
- **Skeletal** (skinned meshes + bone matrices) — already supported
  by raylib's `Mesh` (it has bone weight slots); we'd add the rig
  abstraction and the skinning vertex shader

### Particles — promote example to reusable

`examples/particles.zig` exists.  Wrap as a `ParticleSystem` Node
with: emitter shape, rate, lifetime, velocity distribution, size /
color over life curves, sprite texture.  GPU-based via instanced
quads.

### Loaders — glTF for v2

glTF 2.0 is the only loader worth supporting.  Zig binding via
cgltf-zig or write a minimal loader (glTF JSON + .bin parsing isn't
too bad — maybe 500-800 LOC for a loader that handles meshes +
materials + transforms + skin/animation later).

v1 ships without a loader.  Users build scenes in code or via
procedural generation.

### Frustum culling — easy and cheap

Per-mesh AABB → camera frustum plane test.  Skip nodes whose AABB is
fully outside.  ~150 LOC.  Pays off for any scene over ~50 meshes.

### Picking / raycasting — small, useful, do early

- World-space ray from camera + screen position
- Ray-vs-AABB broad phase across scene tree
- Ray-vs-triangle narrow phase per hit
- Returns nearest mesh + barycentric coords

Useful for editor-style demos.  ~200 LOC.

---

## Feature tiers

### Tier 1 — Scene Graph MVP (must ship in v1)

| Feature                              | LOC est | Notes                                              |
|--------------------------------------|---------|----------------------------------------------------|
| `Node` with TRS + hierarchy          | 250     | rlgl-stack-driven render, no per-frame world mtx  |
| `Mesh` Node wrapping raylib drawMesh | 80      | Glue: Node + Mesh + Material reference             |
| Cascading state (visible, tint, op)  | 60      | Threaded through render visitor                    |
| `node.lookAt(target)` method         | 40      | Direct local-quat solve; no separate pass          |
| Camera as Node                       | 40      | Wraps Camera3D; transform comes from Node          |
| OrbitControls                        | 100     | Mouse drag/zoom against InputSnapshot              |
| **Total**                            | **570** |                                                    |

Ships with one demo: solar system or articulated arm.  No lights, no
shadows, no post — just hierarchy + transforms + camera.  Already
useful.

### Tier 2 — Materials & Lighting (the "things look real" tier)

| Feature                          | LOC est | Notes                                              |
|----------------------------------|---------|----------------------------------------------------|
| Embedded preset shaders          | 800     | GLSL bundle: Basic/Lambert/Phong/PBR/Toon          |
| `Light` data type (5 variants)   | 100     | Plain data, attached via Node, fed to shader       |
| Light uniform binding            | 150     | Auto-set point/spot/dir/ambient/hemi arrays        |
| `StandardMaterial` Node helper   | 60      | Pre-binds the right preset                         |
| **Total**                        | **1110**|                                                    |

After Tier 2, scenes have proper PBR lighting with multiple lights.
This is the "now it looks like Sketchfab" milestone.

### Tier 3 — Shadows (the "depth-perception is real" tier)

| Feature                          | LOC est | Notes                                              |
|----------------------------------|---------|----------------------------------------------------|
| Shadow RT setup                  | 80      | Depth-only FBO, 2K default                         |
| Shadow camera (light's view mtx) | 60      | Tight ortho frustum from sun direction             |
| Shadow pass (depth-only render)  | 100     | Reuse scene traversal, swap material to depth-write|
| PCF sampler in lit shaders       | 50      | Modify Tier 2 shaders                              |
| **Total**                        | **290** |                                                    |

After Tier 3, the directional light casts shadows.  Optional spot
shadows in same pattern.

### Tier 4 — Post-process pipeline (the "cinematic" tier)

| Feature                          | LOC est | Notes                                              |
|----------------------------------|---------|----------------------------------------------------|
| Post chain runner                | 150     | Surface-stack ping-pong between RTs                |
| Tonemap (Reinhard/ACES/AgX)      | 80      | One shader, three constants                        |
| Bloom                            | 200     | Bright-pass + Gaussian downsample chain            |
| FXAA                             | 100     | Single fragment shader                             |
| Vignette / grain / aberration    | 120     | All small, one shader each                         |
| Color-grade LUT                  | 100     | 32×32×32 3D-LUT-as-2D-texture trick                |
| **Total**                        | **750** |                                                    |

After Tier 4, scenes look modern.  Bloom + ACES tonemap alone moves a
scene from "Unity 5 default" to "looks like a current game."

### Tier 5 — Skybox + environment (small, huge visual win)

| Feature                          | LOC est | Notes                                              |
|----------------------------------|---------|----------------------------------------------------|
| `Skybox` Node                    | 80      | Promote `examples/skybox.zig`                      |
| IBL prefilter (env → cubemap)    | 250     | Diffuse + specular env maps for PBR                |
| PBR shader env-map sampling      | (+30)   | Modify Tier 2 PBR shader                           |
| **Total**                        | **360** |                                                    |

After Tier 5, PBR materials get image-based lighting — reflective
metals look right, glossy dielectrics get realistic highlights.

### Tier 6 — Frustum culling + picking (the "scales up" tier)

| Feature                          | LOC est | Notes                                              |
|----------------------------------|---------|----------------------------------------------------|
| Per-Mesh AABB cache              | 50      | Compute once at mesh upload                        |
| Camera frustum extraction        | 100     | 6 plane equations from view-proj matrix            |
| Cull pass                        | 80      | Mark `Node.frustum_culled` per frame               |
| Raycaster (world ray vs scene)   | 200     | AABB broad + triangle narrow                       |
| **Total**                        | **430** |                                                    |

### Tier 7+ — Defer or eject

- **Particle system Node** (~300 LOC) — promote example to library
- **InstancedMesh Node** (~150 LOC) — wrap existing instancing.zig
- **glTF loader** (~700 LOC) — bind cgltf or write minimal subset
- **Skeletal animation** (~500 LOC) — mesh has bone slots already
- **Animation system** (~400 LOC) — keyframe tracks + mixer
- **LOD nodes** (~80 LOC) — distance-based child swap

### Things we will not build

- **SSR / SSAO / TAA / motion blur** — each is its own project,
  diminishing return per LOC compared to bloom + tonemap
- **Volumetric fog / god rays** — niche, expensive
- **Decals** — fiddly, niche
- **Tessellation / geometry shaders** — WebGL2 doesn't have them
- **Dynamic GI (light probes, lightmaps)** — out of scope
- **Editor / scene file format** — users build scenes in code

---

## Architecture: scene graph

### Node — the core type

```zig
pub const Node = struct {
    // Identity
    name: []const u8 = "",

    // Transform (source of truth — local space)
    pos: Vector3 = .{},
    quat: Quaternion = .{ .w = 1 },          // NOT Euler — composes correctly
    scale: Vector3 = .{ .x = 1, .y = 1, .z = 1 },

    // Hierarchy
    parent: ?*Node = null,
    children: std.ArrayListUnmanaged(*Node) = .{},

    // Cascading state (multiplicative through tree)
    visible: bool = true,
    tint: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    opacity: f32 = 1,

    // Optional payload — what this node draws (or doesn't)
    drawable: ?Drawable = null,

    // Cached world transform — populated by `cacheWorldTransforms()`
    // ONLY when something needs it (lookAt resolution, picking,
    // culling).  The render pass doesn't fill this; rlgl matrix
    // stack does composition during traversal.
    world_matrix_dirty: bool = true,
    world_matrix_cached: Matrix = identity(),
};

pub const Drawable = union(enum) {
    mesh: struct { mesh: *const Mesh, material: *const Material },
    instanced_mesh: struct { mesh: *const Mesh, material: *const Material, instances: []const Matrix },
    particle_system: *ParticleSystem,
    skybox: *const Skybox,
    light: *const Light,
    camera: *const Camera3D,
    custom: *const fn (ctx: *RenderCtx) void,  // escape hatch
};
```

Key decisions:

**Quaternion for orientation, never Euler.**  raymath has full
quaternion support.  Euler accumulation across a hierarchy is the bug
the original models3d.zig design had.

**rlgl matrix stack does composition during render.**  Traversal
looks like:

```zig
fn render(node: *Node, ctx: *RenderCtx) void {
    if (!node.visible) return;
    if (node.frustum_culled) return;          // Tier 6

    rlgl.rlPushMatrix();
    rlgl.rlTranslatef(node.pos.x, node.pos.y, node.pos.z);
    rlgl.rlMultMatrixf(quaternionToMatrixPtr(node.quat));
    rlgl.rlScalef(node.scale.x, node.scale.y, node.scale.z);

    if (node.drawable) |d| dispatch(d, ctx);

    for (node.children.items) |child| render(child, ctx);
    rlgl.rlPopMatrix();
}
```

No world matrix tracked.  No per-frame matrix multiply by us.  The
GPU does it when `drawMesh` reads the modelview state.

**`world_matrix_cached` is opt-in.**  When a `lookAt`, picking ray,
or frustum-culling pass needs world coordinates, we run a separate
walk that fills in `world_matrix_cached` for the subtree it cares
about.  Most nodes don't have it filled most frames.

### Cascading state

```zig
pub const RenderCtx = struct {
    camera: *const Camera3D,
    accumulated_tint: Color,
    accumulated_opacity: f32,
    lights: *const LightArray,
    shadow_map: ?*const Texture2D,
    // ...
};
```

The visitor multiplies `accumulated_tint *= node.tint` and
`accumulated_opacity *= node.opacity` going down, restores going up.
The drawable receives the accumulated values via `RenderCtx`.

Three.js's full cascade list to mirror eventually:
- ✅ visible
- ✅ tint
- ✅ opacity
- 🟡 layer mask (32-bit, allows per-camera layer filtering — easy
   add)
- 🟡 render order (sorting hint — meaningful with transparency)
- ⏳ shadow_cast / shadow_receive (Tier 3)
- ⏳ frustum_culled (Tier 6)
- ❌ matrixAutoUpdate — overkill; we always update

---

## Architecture: mesh / material — already exists

This is the part we don't have to design.  raylib gave us:

```zig
pub const Mesh = extern struct {
    vertexCount: c_int,
    triangleCount: c_int,
    vertices: [*c]f32,        // location 0
    texcoords: [*c]f32,       // location 1
    normals: [*c]f32,         // location 2
    colors: [*c]u8,           // location 3
    tangents: [*c]f32,        // location 4
    texcoords2: [*c]f32,      // location 5
    indices: [*c]u16,
    boneIds: [*c]u8,          // location 6 (skinning ready!)
    boneWeights: [*c]f32,     // location 7
    // ... GPU upload state (vaoId, vboId)
};

pub const Material = extern struct {
    shader: Shader,
    maps: [*c]MaterialMap,    // 12 PBR slots
    params: [4]f32,
};

pub const MaterialMapIndex = enum {
    albedo, metalness, normal, roughness, occlusion,
    emission, height, cubemap, irradiance, prefilter, brdf,
    // ...
};
```

Plus `genMesh{Cube,Sphere,Plane,Cylinder,Torus,Knot,Hemisphere}` to
generate primitives, and `drawMesh(mesh, material, transform)` to
render one.

The scene graph just needs to hold pointers and call drawMesh.  No
new abstraction.  The Drawable union already shows the shape.

---

## Architecture: lighting

```zig
pub const Light = struct {
    kind: enum { directional, point, spot, ambient, hemisphere },

    color: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    intensity: f32 = 1,

    // Directional / spot direction comes from the parent Node's
    // forward vector (rotation applied to (0, 0, -1)).  Position
    // for point / spot comes from Node.pos.
    range: f32 = 10,                    // point/spot
    inner_cone_deg: f32 = 30,           // spot
    outer_cone_deg: f32 = 45,           // spot
    sky_color: Color = ...,             // hemisphere
    ground_color: Color = ...,          // hemisphere

    casts_shadow: bool = false,         // directional/spot only (Tier 3)
    shadow_resolution: u32 = 2048,
};

pub const LightArray = struct {
    directional: ?Light = null,
    spots: BoundedArray(Light, 4) = .{},
    points: BoundedArray(Light, 8) = .{},
    ambient: ?Light = null,
    hemisphere: ?Light = null,
};
```

A `light` Drawable, when traversed, just adds the Light to the
LightArray that the upcoming render pass will use.  The render visitor
does two passes:

1. **Collect** — walk the tree, gather Lights into the LightArray
   (with the world transform from each light's Node).
2. **Render** — walk again, dispatch meshes through `drawMesh`.  Each
   draw uniform-binds the LightArray to the active shader.

Two passes is fine — the collection pass is cheap (no draw calls).
This is the only case where we need world transforms outside the
render walk; lights need world position/direction baked in.

---

## Architecture: shaders

We embed five preset shader pairs (vertex + fragment) at build time
via `@embedFile`:

```
src/shaders/embedded/
├── basic.vs
├── basic.fs
├── lambert.vs        (often shared with phong)
├── lambert.fs
├── phong.vs
├── phong.fs
├── pbr.vs
├── pbr.fs
├── toon.vs
└── toon.fs
```

Plus a `presets.zig` that exposes:

```zig
pub const presets = struct {
    pub fn basic(allocator) Material { ... }
    pub fn lambert(allocator) Material { ... }
    pub fn phong(allocator) Material { ... }
    pub fn standard(allocator) Material { ... }     // PBR
    pub fn toon(allocator) Material { ... }
};
```

Each preset returns a `Material` with its shader bound and reasonable
defaults in the maps slots.  User mutates from there.

Each preset shader follows a **uniform naming convention** that maps
to scene state:

```glsl
// Camera (set by scene render every frame)
uniform mat4 mvp;
uniform mat4 model;
uniform vec3 view_pos;

// Lights (set by scene render every frame, only for lit shaders)
uniform vec4 ambient_color;
uniform DirectionalLight dir_light;
uniform PointLight point_lights[8];
uniform int point_light_count;
uniform SpotLight spot_lights[4];
uniform int spot_light_count;
uniform vec4 hemi_sky;
uniform vec4 hemi_ground;

// PBR maps (already provided by raylib's drawMesh)
uniform sampler2D texture0;   // albedo
uniform sampler2D texture1;   // metalness
uniform sampler2D texture2;   // normal
// ...

// Shadow (Tier 3)
uniform sampler2D shadow_map;
uniform mat4 shadow_vp;
```

User-written custom shaders that follow these names automatically
plug into the scene's lighting / shadow infrastructure.  Don't follow
the names?  Provide your own uniform binding callback.

---

## Architecture: post-process pipeline

The surface stack we built for recursive UI is exactly what we need.
Each post effect is:

```zig
pub const PostPass = struct {
    name: []const u8,
    shader: Shader,
    apply: *const fn (in: RenderTexture2D, out: RenderTexture2D, params: anytype) void,
};
```

The runner ping-pongs between two RTs:

```zig
fn applyPostChain(
    chain: []const PostPass,
    scene_rt: RenderTexture2D,
    final_target: ?RenderTexture2D,  // null = screen
) void {
    var src = scene_rt;
    var dst = ping_rt;
    for (chain, 0..) |pass, i| {
        const target = if (i == chain.len - 1) (final_target orelse screen)
                       else dst;
        pass.apply(src, target, ...);
        std.mem.swap(&src, &dst);
    }
}
```

The presets are functions with embedded shaders:

```zig
pub const post = struct {
    pub const tonemap_aces: PostPass = ...;
    pub const tonemap_reinhard: PostPass = ...;
    pub const bloom: PostPass = ...;       // internally chains bright + blur + composite
    pub const fxaa: PostPass = ...;
    pub const vignette: PostPass = ...;
    pub const grain: PostPass = ...;
    pub const aberration: PostPass = ...;
};
```

User builds a chain inline:

```zig
state.scene.render(f, state.cam, .{
    .post = &.{ post.bloom, post.tonemap_aces, post.vignette },
});
```

---

## Architecture audit: what zimr already supports

A direct check of every Tier 1-5 dependency against current zimr:

| Need                                  | Status | Where                                           |
|---------------------------------------|--------|-------------------------------------------------|
| 4×4 matrix math                       | ✅     | `raymath.Matrix*` family                        |
| Quaternion math                       | ✅     | `raymath.quaternion*` family                    |
| rlgl matrix stack                     | ✅     | `rlgl.rlPushMatrix/rlPop/rlMultMatrixf`         |
| Mesh struct + buffers                 | ✅     | `types.Mesh` (vertices/indices/normals/etc.)    |
| genMesh{Cube,Sphere,Plane,Torus,...}  | ✅     | `drawing.models.genMesh*`                       |
| Material struct + map slots           | ✅     | `types.Material` + `MaterialMapIndex` (PBR)     |
| `drawMesh(mesh, material, transform)` | ✅     | `drawing.models.drawMesh`                       |
| Shader load + uniform binding         | ✅     | `z.shaders.loadShader` + `setShaderValue*`      |
| Camera3D                              | ✅     | `types.Camera3D` + `runtime.camera.*`           |
| Render-to-texture                     | ✅     | `loadRenderTexture` + surface stack             |
| Multiple RTs (post chain ping-pong)   | ✅     | Just needs ping/pong helpers                    |
| Texture2D + cubemap support           | ✅     | `types.Texture2D` + skybox example              |
| Instanced rendering                   | ✅     | `examples/instancing.zig`                       |
| Skybox / cubemap                      | ✅     | `examples/skybox.zig`                           |
| InputSnapshot for controls            | ✅     | Built for UI; OrbitControls reads same          |

Result: **every Tier 1-5 building block already exists.**  We're not
adding rendering capability.  We're adding *organization* on top of
existing capability.

The gaps are at the abstraction level, not the GPU level:

| Need                                  | Status | Notes                                           |
|---------------------------------------|--------|-------------------------------------------------|
| Scene graph node type                 | ❌     | Doesn't exist; the substance of v1              |
| Light type as data                    | ❌     | Currently per-shader uniforms only              |
| Preset embedded shaders               | ❌     | Some scattered in examples; need consolidation  |
| Shadow RT pipeline                    | ❌     | Tier 3                                          |
| Post-process chain runner             | ❌     | Surface stack exists but no chain abstraction   |
| Camera controls (Orbit/Fly)           | 🟡     | first_person_camera exists; needs promotion     |
| Frustum culling                       | ❌     | Tier 6                                          |
| Skybox as Node                        | 🟡     | Example exists; needs Node wrapper              |
| glTF loader                           | ❌     | Tier 7                                          |

**Architectural blocker check: nothing.**  Every Tier 1-5 feature
fits cleanly on the existing foundation.

---

## Memory model

Three patterns coexist, picked by use case:

### Pattern A — arena-owned scenes (default)

```zig
var scene = try Scene.init(gpa);
defer scene.deinit();   // frees ALL nodes, geometries, materials at once

const sphere_geom = try scene.geometries.create("sphere", genMeshSphere(...));
const ball_mat = try scene.materials.create("ball", presets.standard(...));
const ball_node = try scene.root.addChild("ball");
ball_node.drawable = .{ .mesh = .{ .mesh = sphere_geom, .material = ball_mat } };
```

The scene owns everything.  One deinit cleans up.  Good for demos
and games where the scene exists for the whole frame loop.

### Pattern B — explicit allocator (advanced)

```zig
var node = try Node.create(gpa, "thing");
defer node.destroy(gpa);
// User manages reference counts for shared assets manually
```

For users who need fine-grained control.  Same Node type, just don't
use the arena helper.

### Pattern C — bring-your-own (escape hatch)

The Drawable union has a `.custom` variant taking `*const fn (ctx:
*RenderCtx) void`.  Users with their own asset systems can plug in
without ever touching our Mesh/Material types — the scene graph just
provides hierarchy + cascading state.

---

## Implementation plan

A staged rollout that ships value at every step.  Each tier is a
discrete project with its own demo and tests.

1. **Tier 1 — Scene Graph MVP** (~1 turn).  `Node`, hierarchy,
   render visitor using rlgl stack, OrbitControls, demo.  After
   this turn: solar-system-style hierarchical scenes work.

2. **Tier 2 — Materials & Lighting** (~2 turns).  Embed Phong + PBR
   shaders, `Light` data type, light uniform binding, preset
   materials.  After this: scenes look real with proper lighting.

3. **Tier 3 — Shadows** (~1 turn).  Sun shadow, PCF.  After this:
   scenes have depth and groundedness.

4. **Tier 4 — Post-process** (~2 turns).  Bloom + tonemap + FXAA in
   the first turn; vignette/grain/grade in the second.  After this:
   scenes look cinematic.

5. **Tier 5 — Skybox + IBL** (~1 turn).  Promote skybox example,
   add env-map prefilter, plug into PBR shader.  After this: PBR
   metals look right.

Total to "Sketchfab-quality demo possible": ~7 turns.  Each turn
delivers something visibly better.

After Tier 5, decide whether to push into Tier 6/7 (frustum cull,
particles, glTF) based on what the demos are missing.

### Where this fits relative to ImGui

ImGui port resumes after this memo lands.  Scene graph is **a
parallel track** that picks up after the ImGui MVP is solid (combo
+ popups + font theme phase 2 finished).  Concretely:

- Now → finish ImGui MVP (~3-4 turns)
- Then → Scene Graph Tier 1 (1 turn)
- Then → resume from there based on energy / project priorities

This doc gets revisited at scene-graph-Tier-1-start time; numbers
re-baselined against any drift.

---

## Open design questions

To resolve before Tier 1 starts:

1. **Node lifetime — arena or refcount?**  Memo recommends arena;
   confirm before code.
2. **Mesh / Material caching — by name (string keys) or pointer
   identity?**  Three.js uses pointer identity but assigns a name
   for lookup.  Probably do same.
3. **Lighting evaluation in screen-space or world-space?**  Phong
   works either way; PBR conventionally world-space.  Pick one and
   stick.
4. **Shadow map — fixed-size or auto-fit to scene bounds?**  Fixed
   size simpler; auto-fit looks better but is annoying.  Probably
   ship fixed, expose knob to override.
5. **Post-process chain — fixed list of presets, or user-extendable
   with custom shaders?**  Both.  Presets are the friendly API;
   `PostPass` is also constructible from a user shader.

---

## Summary

The vision: an opt-in scene graph + flashy-renderer layer that
turns zimr into a "drop scene description, get production-quality
result" tool, while preserving raylib's "drop into immediate mode
anytime" promise.

The architecture: Node hierarchy uses rlgl matrix stack for render
composition (avoids three.js's per-frame world-matrix-everywhere
cost), reuses raylib's already-PBR-shaped Mesh + Material types,
adds a small Light data type and embedded preset shaders, and uses
the surface stack we already built for the post-process pipeline.

The audit: **every building block needed for Tier 1-5 already
exists in zimr.**  No GPU-level capability is missing.  This is
purely an organization layer — about 3000 LOC across five tiers,
shipped in ~7 turns.

The non-goals: not Three.js, not Unreal, not GLTF on day one, not
dynamic GI, not animation system in v1.  Stay scoped.

The plan: finish ImGui MVP first, then resume here.

*End of memo.  Revisit at scene-graph-Tier-1 kickoff.*
