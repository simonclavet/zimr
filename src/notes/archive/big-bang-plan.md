# Big-bang resource migration — execution plan

This is the HOW for the resource refactor.  See:
- `resource-tutorial.md` for the user-facing model
- `resources-redesign-plan.md` for the architecture and decisions Q1-Q8

The slice (`src/gpu_v2.zig` + converted `examples/png_demo.zig`) has
already validated the design.  This plan extends those patterns
across the entire codebase.

## Ground rules

- **Red builds are expected.**  We will not have a green compile for
  much of this migration.  That's accepted — the alternative is
  weeks of "two-ways-to-do-it" friction.
- **Each phase has a checkpoint criterion.**  When the criterion is
  met, the phase is done — even if the build is still red.
- **Reverting a single phase is not a goal.**  We're committing.
  Going back means a clean git revert of the whole sequence.
- **Audit gates run only between phases that should be green.**
  Mid-phase test/smoke runs are noise.

## Pre-flight — settle remaining open questions

Before code changes, we need answers to Q3, Q9, Q10 from the
redesign plan.  The slice avoided these because it only touched
textures.  Big-bang touches everything.

### Q3 — where does font_cache live?

Today: `font_cache: *FontCache` on `Frame`, runtime-owned.

Three plausible shapes:
1. **Stay on Frame.**  Special case: the rasterization atlas
   conceptually IS framework state (one per app, lazily grown).
2. **Field on `GpuWorlds`.**  Bundled with the user-side resource
   storage.  drawText reaches it through the bundle.
3. **Separate user-state struct.**  drawText takes
   `font_cache: *FontCache` as an explicit parameter.

Recommendation: **stay on Frame** initially.  The atlas isn't
instance-shaped (it's one shared cache that grows as glyphs are
encountered).  Putting it in `GpuWorlds` makes the bundle
heterogeneous; putting it in user state means every drawText call
plumbs another parameter.  Frame is the right home.

(Caveat: this means Frame is NOT just gl+gpa+scratch — it carries
the cache too.  This is fine because the cache is true framework
state, not user resources.  We'll document the carve-out clearly.)

### Q9 — how does Renderer access user worlds?

Today: `Renderer.render(gl, res, list, target)` takes the renderer's
internal `Resources` struct.  Post-bigbang, the renderer needs the
user's `GpuWorlds` (textures, meshes, shaders) to deref the refs in
the RenderList.

Two shapes:
1. **Per-render parameter.**  `render(gl, gpu, list, target)`.
   Renderer is stateless w.r.t. resources.
2. **Stash at init.**  `Renderer.init(gl, gpa, gpu)` stores a
   `*GpuWorlds` pointer; render() doesn't take it.

Recommendation: **per-render parameter**.  Matches the maximally-explicit
principle.  Avoids stale-pointer footguns if the user ever swaps
worlds (loading screen → main game).  Costs one extra param at
each render() call site (which is rare — usually 1-2 per frame).

### Q10 — does `GpuWorlds` stick as a name?

The slice doesn't have `GpuWorlds` yet (single textures world only).
Big-bang introduces the bundle.  Candidates:

- `GpuWorlds` — descriptive, "ECS worlds for GPU resources"
- `GpuStore` — broader, fits if we ever add non-ECS storage
- `GpuState` — generic, a bit vague
- `Resources` — collides with the current Renderer-internal
  `Resources` struct (which gets deleted, freeing the name)
- `Assets` — common gamedev term, slightly inaccurate (assets often
  imply on-disk source files; we hold GPU state)

Recommendation: **`GpuWorlds`** for explicitness, with `Resources`
as a tempting alternative once the old struct is gone.  Going with
`GpuWorlds` for the migration; we can rename late if a better name
emerges.

---

## Resource inventory (what needs to migrate)

Five resource kinds, with example-touching counts:

| Kind | Component name | Ref alias | Examples touching | Loaders today |
|---|---|---|---|---|
| Textures | `GpuTexture` | `Texture2D` | 44/50 | `loadTextureFromMemory`, `loadTextureFromImage`, `loadTextureCubemap` |
| Meshes | `GpuMesh` | `Mesh` | 13/50 | `loadModelFromMemory` (returns Model containing Meshes), `genMeshXxx` |
| Shaders | `GpuShader` | `Shader` | 4/50 | `loadShaderFromMemory` |
| Render targets | `GpuRenderTexture` | `RenderTexture` | 5/50 | `loadRenderTexture` |
| Fonts | `GpuFont` | `Font` | 2/50 explicitly + many implicit through drawText | `loadFontFromTtfData`, `loadFontFromMemory`, `loadFontDefault` |

Plus internal renderer-owned resources (P3-P5a): the unlit/lit/shadow/skybox
materials, shadow FBO, skybox quad mesh.  These don't migrate —
they're singletons not "things with identity," per the redesign
plan's exclusions.

---

## Phase A — Foundation (still GREEN)

Goal: define every type and bundle without breaking anything.
Build stays compilable; old code untouched.

### A.1 — Component types

Add to `src/gpu_v2.zig`:

```zig
pub const GpuTexture       = struct { id, width, height, mipmaps, format };  // already done
pub const GpuMesh          = struct { /* mirror existing types.Mesh fields */ };
pub const GpuShader        = struct { /* mirror existing types.Shader fields */ };
pub const GpuRenderTexture = struct { /* mirror existing types.RenderTexture fields */ };
pub const GpuFont          = struct { /* mirror existing types.Font fields */ };
```

Field-by-field parity with the current raylib-parity structs.
Test that `@sizeOf(GpuMesh) == @sizeOf(types.Mesh)` etc., so the
post-bigbang rename is provably mechanical.

### A.2 — Ref aliases

```zig
pub const Texture2D     = Ref(GpuTexture);     // already done
pub const Mesh          = Ref(GpuMesh);
pub const Shader        = Ref(GpuShader);
pub const RenderTexture = Ref(GpuRenderTexture);
pub const Font          = Ref(GpuFont);
```

### A.3 — Metadata components

Define the metadata components we want to ship with v1.  These are
optional — added per-load via the `*Retained` loader variants:

```zig
pub const SourceBytes    = struct { bytes, encoding };  // already done
pub const HotReloadable  = struct { source_path, last_load_ns, pending_reload };
pub const BundleTag      = struct { id: u32 };
pub const TextureSampling = struct { min, mag, wrap };
```

Don't ship metadata components nobody asks for yet.  Hot-reload
is the strongest case (real demand from devs); BundleTag is also
solid for asset-bundle workflows.  Defer the others until a use
case appears.

### A.4 — `GpuWorlds` bundle

```zig
pub const GpuWorlds = struct {
    textures: ecs.Entities,
    meshes:   ecs.Entities,
    shaders:  ecs.Entities,
    targets:  ecs.Entities,  // render textures
    fonts:    ecs.Entities,

    pub fn init(gpa: Allocator) !@This() {
        // Each sub-world gets capacity right-sized to typical app:
        // textures = 256 entities (most common), shaders = 32, etc.
    }

    pub fn deinit(self: *@This(), gl: *rlgl.GlState, gpa: Allocator) void {
        // Walk each sub-world, free GL ids, deinit ECS.
        // Bundled per Q4.
    }
};
```

### A.5 — Loader function declarations (signatures only)

Stub every loader we'll need, returning `error.Unimplemented`.  This
lets us validate signatures and naming without committing logic
yet.  Roughly:

```zig
pub fn loadTextureFromMemory(gpa, world, bytes) !Texture2D;
pub fn loadTextureFromImage(gpa, world, image) !Texture2D;
pub fn loadTextureCubemapFromMemory(gpa, world, bytes_per_face) !Texture2D;
pub fn loadMeshFromGltf(gpa, world, glb_bytes) !Mesh;
pub fn genMeshPlane(gpa, world, w, h, sw, sh) !Mesh;
pub fn genMeshCube(gpa, world, w, h, d) !Mesh;
pub fn genMeshSphere(gpa, world, radius, rings, slices) !Mesh;
pub fn loadShaderFromMemory(gpa, world, vs, fs) !Shader;
pub fn loadRenderTexture(gpa, world, w, h) !RenderTexture;
pub fn loadFontDefault(gpa, world) !Font;
pub fn loadFontFromMemory(gpa, world, ttf_bytes, size) !Font;
```

Plus their `*Retained` variants where applicable (textures, fonts;
not meshes — too much data).

**Checkpoint A**: build green, all signatures declared, every loader
returns `error.Unimplemented`.  Tests still pass at 1126.

---

## Phase B — The big rename (RED begins)

This is the breaking-change moment.  Two big sweeping renames:

### B.1 — Rename current raylib-parity types

In `src/types.zig` (where the raylib types live):

```zig
// before
pub const Texture2D     = struct { id, width, height, mipmaps, format };
pub const Mesh          = struct { /* ... */ };
pub const Shader        = struct { /* ... */ };
pub const RenderTexture = struct { /* ... */ };
pub const Font          = struct { /* ... */ };

// after
pub const GpuTexture       = struct { id, width, height, mipmaps, format };
pub const GpuMesh          = struct { /* ... */ };
pub const GpuShader        = struct { /* ... */ };
pub const GpuRenderTexture = struct { /* ... */ };
pub const GpuFont          = struct { /* ... */ };
```

All internal references in `src/drawing.zig`, `src/render.zig`,
`src/scene.zig`, `src/resources.zig`, etc. break here.  Sed-pass:

- `Texture2D_t` → `GpuTexture` (the existing alias)
- `Texture2D` → `GpuTexture`
- `Mesh` → `GpuMesh`  (careful: `genMeshPlane` is a function, don't rename)
- `Shader` → `GpuShader`
- `RenderTexture` → `GpuRenderTexture`
- `Font` → `GpuFont` (in struct contexts; not in `font_cache`)

This is mechanical but error-prone — false positives where these
names appear in identifiers (variable names, function names).  Plan
on doing the rename, then reading every diff hunk.

### B.2 — Promote ref aliases to top level

Drop the old aliases from `src/zimr.zig`:

```zig
// remove
pub const Texture2D = types.Texture2D;
pub const Mesh = types.Mesh;
// etc.
```

Replace with re-exports of the refs:

```zig
pub const Texture2D     = gpu.Texture2D;
pub const Mesh          = gpu.Mesh;
pub const Shader        = gpu.Shader;
pub const RenderTexture = gpu.RenderTexture;
pub const Font          = gpu.Font;
```

After B.1+B.2, **the build is hard-broken**.  Hundreds of
references to the old struct types break.  This is intentional —
each break is a place that needs to migrate to the ref API.

**Checkpoint B**: B.1 + B.2 land in the same commit.  Build is red
in a known way (mass-rename).  No fmt errors in modified files.
Don't run tests — they won't compile.

---

## Phase C — Loaders (still RED)

Implement every loader stubbed in A.5.  Each follows the same
shape:

```zig
pub fn loadXxxFromYyy(gpa, world, ...) !RefType {
    // 1. Decode/generate (existing zimr machinery).
    const gpu_state = try ...;
    errdefer ...release_gpu_state...;

    // 2. Spawn entity.
    const entity = try ecs.Entity.reserveImmediateOrErr(world);
    errdefer _ = entity.destroyImmediate(world);

    // 3. Add component.
    _ = try entity.changeArchImmediateOrErr(world, gpa, struct {
        gpu: GpuType,
    }, .{ .add = .{ .gpu = gpu_state } });

    return .{ .entity = entity };
}
```

Plus `*Retained` variants that also add metadata components.

Order of attack:
- C.1 — texture loaders (mirror the slice's pattern)
- C.2 — mesh loaders (more complex; meshes have CPU+GPU dual state)
- C.3 — shader loaders
- C.4 — render texture loaders
- C.5 — font loaders (depends on FontCache; see Q3 carve-out)

Mesh loaders deserve attention.  Today's `loadModelFromMemory`
returns a `Model` containing multiple `Mesh`es.  Big-bang shape:

```zig
pub fn loadModelFromMemory(gpa, world, glb_bytes) !ModelHandle;
// where ModelHandle is something like:
pub const ModelHandle = struct {
    meshes:    []const Mesh,    // owned by caller, freed via gpa.free
    materials: []const Material,
};
```

Or alternatively: each mesh becomes its own entity, the model is
a coordinating struct holding refs.  Decide at C.2.  Recommend the
latter — keeps the "every resource is an entity" rule clean.

**Checkpoint C**: every loader compiles individually (verify by
forcing each to be referenced from a test).  Build is still red
overall because loaders aren't yet WIRED INTO drawing primitives or
examples.

---

## Phase D — Drawing primitives (still RED)

Migrate every `drawing.X.drawY` call to the new shape:

```zig
// before
drawing.textures.drawTexturePro(gl, tex, src, dst, origin, rot, tint);

// after
gpu.drawTexturePro(gl, world, ref, src, dst, origin, rot, tint);
```

Inventory of touched primitives (rough):

- `drawTexture`, `drawTextureV`, `drawTextureEx`, `drawTextureRec`,
  `drawTexturePro`, `drawTextureNPatch`
- `drawMesh`, `drawMeshWires`, `drawMeshInstanced`
- `drawText`, `drawTextEx`, `drawTextPro`
- `beginTextureMode`, `endTextureMode` (render-texture)
- `beginShaderMode`, `endShaderMode`

Plus indirect users — the renderer itself, `scene.zig`'s compile,
`ui.zig`'s drawing.  Each call site needs the world(s) it derefs
through to be in scope.

Strategy: implement the new API in `src/gpu_v2.zig`, then sed the
old internal callers (`drawing.X.draw...` → `gpu.draw...`).
Examples come in Phase F.

For now, leave `src/drawing.zig`'s old implementation in place but
mark deprecated via comments.  The old call surface stays for
examples that haven't migrated yet.

**Checkpoint D**: gpu_v2 has every drawing primitive implemented
and compiling.  Internal modules (render.zig, scene.zig) have been
migrated to call gpu.*.  Examples haven't been touched yet.  Build
is still red because examples reference removed types.

---

## Phase E — Renderer integration (still RED)

The Renderer keeps its internal `Resources` struct today (the
`Pool(Texture)` family).  Migration:

### E.1 — Renderer takes user worlds at render()

```zig
// before
pub fn render(self: *Renderer, gl, res: *const Resources, list, target) !void;

// after
pub fn render(self: *Renderer, gl, gpu: *const GpuWorlds, list, target) !void;
```

The user's `GpuWorlds` is what the renderer derefs against.  The
renderer's internal `Resources` struct is GONE.

### E.2 — `compile()` takes worlds too

`scene.compile` returns a RenderList.  Today the RenderList holds
opaque draws with `MeshHandle` / `TextureHandle` (Pool handles).
After migration, it holds `Mesh` / `Texture2D` refs (which are
Refs, not Pool handles).

Compile signature changes:

```zig
// before
pub fn compile(arena, world: *ecs.Entities, res: *const Resources, ...) !RenderList;

// after
pub fn compile(arena, world: *ecs.Entities, gpu: *const GpuWorlds, ...) !RenderList;
```

`compile` doesn't actually need `gpu` for its current logic — it
just builds the list.  But it might need it later for things like
"validate that every ref in the list still derefs."  Defer that
question; for now `compile` doesn't take gpu.

Wait — actually, `compile` DOES need worlds for the mesh draws
because the RenderList stores refs by value.  No deref happens at
compile time; `render()` does the derefs.  So `compile` doesn't
need gpu.  Confirmed.

### E.3 — Drop `src/resources.zig`

Delete the file.  Remove imports, remove from `src/tests.zig`
aggregator, remove `pub const resources = ...` from `src/zimr.zig`.

### E.4 — Renderer-internal singletons stay

Per the redesign plan: shadow FBO, skybox quad mesh, lit/unlit
materials remain raw fields on Renderer.  These are NOT user
resources; don't migrate them.

**Checkpoint E**: render.zig + scene.zig compile.  resources.zig
deleted.  Build is still red because examples still reference old
API.

---

## Phase F — Convert examples (RED → progressively GREEN)

50 examples to convert.  Sed pass + per-example fixup.

### F.1 — Survey

```bash
grep -lE "loadTextureFromMemory|drawTexture|loadModel|drawMesh" examples/*.zig
```

Group examples by complexity:
- **Trivial** (10): single texture, no model loading.  Pure sed.
- **Texture-heavy** (15): multiple textures, render textures.
  Need state struct restructured to hold `textures: ecs.Entities`.
- **Model + texture** (10): glTF loading, mesh + texture refs.
  Need `meshes: ecs.Entities` AND `textures: ecs.Entities`.
- **Complex** (15): shaders, render textures, beginTextureMode,
  custom materials, etc.  Per-example treatment.

### F.2 — Order of attack

Convert in increasing complexity order:

1. **Trivial**: `png_demo` (already done), `image_text`, `texture_readback`
2. **Texture-heavy**: `texture_drawing`, `image_editor`, `gallery`
3. **Model + texture**: `gltf_simple`, `gltf_textured`, `pbr_demo`,
   `split_screen`
4. **Complex**: shader-using examples, render-texture examples

After each conversion, smoke-test that single example:

```bash
zig build smoke-test 2>&1 | grep -E "<example_name>"
```

Mark green per-example as we go.

### F.3 — Ergonomic patterns

Common patterns that emerge:

- **State carries a `gpu: z.GpuWorlds` field** for examples loading
  multiple resource kinds.
- **State carries individual `textures: ecs.Entities` etc.** for
  examples loading one kind.
- **Refs are stored alongside other game state** when it makes
  sense (`Sprite { tex: Texture2D, pos: Vec2 }`).
- **`gpu.deinit(f.gl, f.gpa)` at app teardown** — except wasm
  examples don't have a teardown hook today; just leak.

**Checkpoint F**: every example compiles individually and passes
its smoke test.  Build is GREEN at the end of this phase.

---

## Phase G — Final cleanup (already GREEN)

### G.1 — Delete Pool

```bash
rm src/pool.zig
```

Remove from `src/tests.zig` and any `@import` references.  No code
should reference `pool.Handle` or `pool.Pool` after Phase F.

### G.2 — Rename gpu_v2 → gpu

```bash
mv src/gpu_v2.zig src/gpu.zig
```

Update `src/zimr.zig`:
```zig
pub const gpu = @import("gpu.zig");
```

The slice-staging file marker is gone.  This is now the canonical
home of the resource API.

### G.3 — Reclaim top-level names

After B.2, top-level `Texture2D` / `Mesh` / etc. point at the gpu
module's refs.  No further work needed unless we want to drop the
re-exports in favor of namespacing (`z.gpu.Texture2D`).  Recommend
keep the top-level for ergonomics.

### G.4 — Clean up old loader paths in zimr.zig

`pub fn loadTextureFromMemory(gpa, bytes) !Texture2D` (top-level)
no longer compiles because `Texture2D` is now a Ref, not a struct.
Either:
- Delete it (callers already migrated to `z.gpu.loadFromMemory`)
- Rename it `legacyLoadTextureFromMemory` for some transitional
  period

Recommend delete.  Phase F migrated every caller.

### G.5 — Update docs

- `src/notes/render-plan.md` — note resources are now ECS-backed
- `src/notes/cheatsheet.md` (if exists) — update resource section
- `src/notes/resources-redesign-plan.md` — mark plan as EXECUTED,
  link to tutorial

**Checkpoint G**: build green, all gates pass (test, smoke, fmt,
DAG, globals, release).  Pool gone, resources.zig gone, gpu_v2.zig
renamed.  Docs reflect the new world.

---

## Estimated effort

Per-phase rough sizing (assumes 2-4 hours of focused work per session):

| Phase | Sessions | Risk |
|---|---|---|
| Pre-flight (Q3, Q9, Q10 closure) | 0.5 | Low |
| A — Foundation | 1-2 | Low |
| B — Big rename | 1 | Med (sed errors) |
| C — Loaders | 2-3 | Med (mesh complexity) |
| D — Drawing primitives | 2 | Low (mechanical) |
| E — Renderer | 1-2 | Med (test surface) |
| F — Convert examples | 3-5 | Low (mechanical, lots of) |
| G — Final cleanup | 1 | Low |

**Total: 12-18 sessions.**  Realistically 3-4 weeks of part-time
work if pursued steadily.  Faster if a session can be longer and
focused.

## Risk register

- **Q3 turns out wrong (font_cache placement).**  We may discover
  during Phase C.5 (font loaders) that font_cache really wants to
  live in a different place.  Cost of revisiting: refactor every
  drawText call signature.  Mitigation: gut-check with a single
  font example before Phase F starts.

- **Mesh+model semantics turn out wrong.**  glTF has multi-mesh
  models with shared materials.  Decision at C.2 about how that maps
  to ECS entities (one entity per mesh? per model? per material?).
  Mitigation: prototype with one glTF example before committing.

- **Renderer integration (E) cascade.**  render.zig has been polished
  through P5a; touching it risks regressions.  Mitigation: keep
  smoke tests for pbr_demo + split_screen passing as a litmus during
  E.

- **Phase B sed errors.**  Mass renames bite false positives —
  variable names containing `Mesh`, comments referencing the old
  type, etc.  Mitigation: do the rename, then read every diff hunk
  before committing.

- **Internal Pool users we haven't found.**  Some renderer
  internals (loaderTexture for shapes, default font texture, etc.)
  might Pool-reference in unexpected places.  Mitigation: grep
  `pool\.Handle\|pool\.Pool` after Phase E; address every hit.

## What we DON'T do during big-bang

- **No new features.**  P5b (sprite + cubemap) waits.  Resource
  refactor first.
- **No helper layer.**  BaseState and friends are explicitly
  deferred; that's a separate later effort.
- **No DSL for asset bundles.**  BundleTag is a plain component;
  fancy syntax (`f.bundle("level1") { ... }`) is post-bigbang.
- **No filesystem watcher for hot-reload.**  HotReloadable is a
  plain component with `pending_reload: bool` — manual API only.
  Watcher is post-bigbang.
- **No async loaders.**  `loadFromUri` / fetch-then-decode flows
  stay as they are today.

These can all be added on top of the new substrate later.  Doing
them during big-bang would extend it indefinitely.
