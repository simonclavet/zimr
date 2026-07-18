# Resources system redesign — plan (ECS-as-foundation)

Design doc for unifying GPU-resource identity with the ECS, then
expanding ECS to be the canonical storage substrate for "things with
identity, lifetime, and per-instance state" across all of zimr.

Not active work today; written so a future session can pick up the
thread without re-deriving the analysis.  This supersedes the
earlier 3-stage Pool→Pool-on-Frame plan: it goes further.

## The thesis

**One ECS per resource kind, phantom-typed refs as user-facing API,
Frame as the god-object that ties everything together.**

Resources stop being a Pool-wrapped raylib type and become
phantom-typed refs into per-kind ECS worlds owned by Frame.  Pool
disappears.  Components-on-resources unlocks hot-reload, bulk-free,
asset bundles, and queries — all things Pool fundamentally can't do
without parallel side-tables.

Beyond resources, ECS becomes the canonical substrate for game state,
audio sources, tweens, and particle emitters — anything you'd
naturally talk about in plurals.  UI, input, window, font cache, and
framework config stay singletons (they're not "things with identity").

## The keystone — phantom-typed refs

```zig
pub fn Ref(comptime Component: type) type {
    return struct {
        entity: ecs.Entity,
        pub const Resource = Component;  // phantom marker

        pub fn deref(self: @This(), world: *const ecs.Entities) ?*Component {
            return self.entity.get(world, Component);
        }
    };
}

pub const Texture2D     = Ref(GpuTexture);
pub const Mesh          = Ref(GpuMesh);
pub const Shader        = Ref(GpuShader);
pub const RenderTexture = Ref(GpuRenderTexture);
pub const Font          = Ref(GpuFont);
```

`Ref(GpuTexture)` and `Ref(GpuMesh)` are distinct types — passing a
texture ref to a function expecting a mesh ref is a compile error.
The `pub const Resource` decl participates in the type's comptime
identity (same trick `pool.Handle(T)` uses today).

Type erasure happens *underneath* the wrapper but never leaks into
user code.  All public APIs talk in `Texture2D` / `Mesh` / etc.

## Architecture — user-state ECS, minimal Frame

The previous draft had `gpu_textures` / `gpu_meshes` / etc. as Frame
fields owned by the runtime.  That's wrong.  **Frame is the
rendering substrate; resource storage is user state.**

```zig
pub const Frame = struct {
    gl:      *rlgl.GlState,    // GPU command substrate, runtime-owned
    gpa:     Allocator,        // long-lived allocator, runtime-owned
    scratch: Allocator,        // per-frame arena, runtime-owned

    // (font_cache: TBD — see open design questions)
    // No resource fields.  All worlds live in user state.
};
```

The user owns whatever world(s) they want.  zimr ships:

- `Ref(T)` phantom-typed wrapper over `ecs.Entity`
- Component types (`GpuTexture`, `GpuMesh`, ...) — the data plane
- Loaders that take a target world + bytes, return a `Ref(T)`
- Drawing primitives that take a Frame + world + ref

The user threads worlds through their own code.  zimr makes no
opinion about topology, lifetime scope, or naming.

Why this is better than Frame-owned worlds:

- **Multiple isolated scopes per app** are natural — loading screen
  has its own gpu world, main game has another, dev tools yet
  another.  Cross-pollution impossible by construction.
- **Lifetime is explicit** — user creates, user frees.  Runtime
  doesn't have to guess when to clean up.
- **zimr-as-library** stays honest — the runtime/Frame layer
  doesn't accumulate state that's really application concerns.
- **Resource topology is a user decision** — single world, per-kind
  worlds, mixed with gameplay, etc.  zimr doesn't force a shape.

## Foundational principle — two layers

zimr's API splits cleanly into two layers:

### Core layer — maximally explicit

Every core function takes ONLY what it needs.  No god-bag parameters.
Signatures are the dependency graph.  No method on Frame; no method
on `GpuWorlds`; no implicit state lookup.

```zig
// Core layer — maximally explicit, no Frame param

// Pure geometry, only the GL substrate.
pub fn drawRectangle(gl: *rlgl.GlState, x, y, w, h: f32, color: Color) void;

// Texture-backed: declares the textures world it derefs.
pub fn drawTexture(
    gl: *rlgl.GlState,
    textures: *ecs.Entities,
    tex: Texture2D,
    x, y: f32, tint: Color,
) void;

// Mesh draw: declares EVERY world it touches.
pub fn drawMesh(
    gl: *rlgl.GlState,
    meshes: *ecs.Entities,
    textures: *ecs.Entities,  // material's texture maps
    shaders: *ecs.Entities,   // material's shader
    mesh_ref: Mesh, mat: Material, xform: Matrix,
) void;

// Loader: declares its allocator + GPU dep + target world.
pub fn loadTextureFromMemory(
    gpa: Allocator,
    gl: *rlgl.GlState,
    textures: *ecs.Entities,
    bytes: []const u8,
) !Texture2D;
```

This is verbose by design.  The principle: **a function shouldn't
know about anything it doesn't need.**  drawMesh's signature is the
API contract — "I touch meshes, textures, shaders."  That's
discoverable from the signature; no spelunking through Frame to
find what's actually used.

### Helper layer — deferred, future work

The principle leaves room for a future helper layer — opt-in
convenience over the core, for users who want compact call sites
without the dependency-graph verbosity.  A `BaseState`-style
struct that the user embeds in their app's State, methods that
unwrap it and call core internally, etc.

**This is explicitly not part of the current refactor.**  We
build the core layer first, prove it works, and add helpers later
when we know what the actual friction is (or isn't).  Designing
helpers in advance is guessing.

The slice and the big-bang migration that follows it touch only
the core layer.  Helper layer is a separate, later effort.

### Migration order

1. Build the core layer first (concrete, principled, complete).
2. Helper layer arrives only after core stabilizes — and only if
   its design is informed by real friction in real apps.

## Decisions locked

- **Q1 — Topology**: per-kind worlds, bundled in a `z.GpuWorlds`
  helper struct.  One `Entities` per resource kind (textures, meshes,
  shaders, render targets, fonts).  Each sub-world has a single
  base archetype → constant-offset lookups (~3 deref).  Capacity
  is right-sized per type.  User creates a `GpuWorlds` (one-liner)
  and threads it through their own code; advanced users can ignore
  `GpuWorlds` and build their own world layout.

  ```zig
  pub const GpuWorlds = struct {
      textures: ecs.Entities,
      meshes:   ecs.Entities,
      shaders:  ecs.Entities,
      targets:  ecs.Entities,
      fonts:    ecs.Entities,

      pub fn init(gpa: Allocator) !@This() { ... }
      pub fn deinit(self: *@This(), gl: *GlState, gpa: Allocator) void { ... }
  };
  ```

- **Q2 — Drawing primitive shape**: free functions, NEVER methods
  on Frame, NEVER taking Frame.  Each primitive declares EVERY
  world / subsystem it touches in its signature.  See the core
  layer above for canonical examples.  `gl` is passed individually
  (not reached via Frame).

- **Q4 — Cleanup at shutdown**: bundled.  `gpu.deinit(gl, gpa)`
  walks every sub-world, releases every entity's GL id, then
  deinits the ECS structures.  User can still iterate sub-worlds
  manually for partial cleanup (e.g. unloading one bundle),
  but the default path is one call.  The `gl` parameter is
  visible — to release GPU resources you need GPU access; don't
  hide that.

- **Q5 — Migration approach**: validation slice → big-bang.  Build
  the new core for ONE resource kind (textures) end-to-end as the
  slice.  Slice gives us a low-risk way to feel out the API in
  practice, but we are committing — once it works and feels right,
  we retire the slice early and roll out the same patterns to all
  resource kinds in one focused push.  Old Pool-based code stays
  intact during the slice (zero risk to existing examples), then
  gets replaced wholesale during the big-bang.

  Slice scope:
  - `Ref(T)` generic in a new module
  - `GpuTexture` component, `Texture2D = Ref(GpuTexture)`
  - One sub-world (just `*ecs.Entities` for now, no `GpuWorlds` bundle)
  - Loaders: `loadFromMemory`, `loadFromFileData`
  - One drawing primitive: `drawTexturePro` (rich enough to be honest)
  - Cleanup helper for the single sub-world
  - One existing example converted end-to-end
  - Native + smoke tests pass

  Names in the slice are the REAL names we'll commit to in big-bang
  — no temporary `_v2` suffixes inside the slice's namespace.  The
  module file is named `gpu_v2.zig` only to signal experimental
  status during the slice; the types inside it use final names.

- **Q6 — Slice location**: fresh module `src/gpu_v2.zig`.  Old code
  byte-for-byte unchanged during the slice.  Re-exported as
  `pub const gpu = @import("gpu_v2.zig");` from `src/zimr.zig`,
  so user code accesses new types as `z.gpu.Texture2D` etc.  After
  big-bang, the module file is renamed (likely to `src/gpu.zig` or
  split into `src/gpu/textures.zig` etc.) and the top-level
  `Texture2D`/`Mesh`/etc. names are reclaimed for the new refs
  (current raylib-parity structs get renamed to `GpuTexture`/
  `GpuMesh`/etc.).

- **Q7 — Naming**: keystone types committed.
  - **Generic ref**: `Ref(T)` — short, doesn't collide with Pool's
    defunct `Handle`.
  - **Component types** (data in the ECS): `GpuTexture`, `GpuMesh`,
    `GpuShader`, `GpuRenderTexture`, `GpuFont`.  The `Gpu` prefix
    announces "this lives on the GPU side."  These names take
    over from the current raylib-parity struct names during
    big-bang.
  - **User-visible ref aliases**: `Texture2D`, `Mesh`, `Shader`,
    `RenderTexture`, `Font` — raylib-parity stays.  From the
    user's POV the spelling is identical to today; the
    implementation underneath swaps to `Ref(GpuTexture)` etc.
    Migration friction at user code is mostly signatures, not
    type names.

  Slice-specific note: inside `src/gpu_v2.zig`, `Texture2D = Ref(GpuTexture)`
  is locally defined and doesn't collide with top-level `z.Texture2D`
  (the current raylib struct).  Users access the new ref as
  `z.gpu.Texture2D` during the slice.

- **Q8 — Metadata in slice**: yes, one component.  `SourceBytes`
  ships in the slice as a real, useful metadata component (not a
  placeholder):
  ```zig
  pub const SourceBytes = struct {
      bytes:    []const u8,
      encoding: enum { png, jpg, raw },
  };
  ```
  Use case: WebGL2 context loss recovery — without retained source
  bytes, a context-loss event means re-fetching from network/disk.
  The slice ships two loader variants:
  - `loadFromMemory(gpa, gl, world, bytes) !Texture2D` — bare
  - `loadFromMemoryRetained(gpa, gl, world, bytes, encoding) !Texture2D`
    — also attaches `SourceBytes` to the entity

  Slice example demonstrates both: load one each way, deref both
  through `Texture2D.deref(world)` (proves cross-archetype lookup
  works), iterate via `world.forEach(.{SourceBytes}, ...)` (proves
  metadata queries work).  This validates the components-on-resources
  story end-to-end before big-bang commits to it.

## Open design questions

Decisions still in flight:

- **Q3** (deferred by user): Where does `font_cache` live — Frame, in
  `GpuWorlds`, in a separate `Fonts` user-state struct, or somewhere
  else?  Will resolve before big-bang touches font code.
- **Q9**: How does `Renderer` access the user's worlds — at init
  (stash pointers), or per-`render()` call?  Post-slice question.
- **Q10**: Does `GpuWorlds` (the bundle name) stick, or is there a
  better shape?  Post-slice question.

## Components-on-resources — the magic

Base component is the GPU state.  Everything else is opt-in:

```zig
pub const GpuTexture = struct { id, width, height, mipmaps, format };

pub const HotReloadable = struct {
    source_path:    []const u8,
    last_load_ns:   i64,
    pending_reload: bool,
};

pub const SourceBytes = struct {
    bytes:    []const u8,
    encoding: enum { png, jpg, raw },
};

pub const BundleTag = struct { id: u32 };

pub const TextureSampling = struct {
    min:  enum { nearest, linear, mipmap_linear } = .linear,
    mag:  enum { nearest, linear } = .linear,
    wrap: enum { clamp, repeat, mirror } = .clamp,
};
```

A bare texture has `{GpuTexture}`.  A hot-reloadable texture has
`{GpuTexture, HotReloadable, SourceBytes}`.  A bundled asset has
`{GpuTexture, BundleTag(1)}`.  Adding metadata is a one-line change
at load site; no parallel side-tables.

**What this unlocks** (none possible with Pool):

```zig
// Hot-reload pass at frame start
f.gpu_textures.forEach(.{ HotReloadable, GpuTexture }, |hot, gpu| {
    if (hot.pending_reload) reupload(gpu, hot.source_path);
});

// Bulk-free at level transition
f.gpu_textures.forEach(.{ BundleTag, GpuTexture }, |tag, gpu| {
    if (tag.id == bundle_to_unload) {
        wasm_fwd.rlUnloadTexture(gpu.id);
        // ... destroy entity via cmd buffer ...
    }
});

// Memory accounting
f.gpu_textures.forEach(.{ GpuTexture }, |t| { ... });
```

## API — Frame as god-object

Drawing primitives migrate from freestanding modules to Frame methods:

```zig
// before
drawing.textures.drawTexture(gl, tex.*, x, y, tint);

// after
f.drawTexture(tex, x, y, tint);
```

Loaders likewise:

```zig
const tex_simple = try f.loadTextureFromMemory(png_bytes);
const tex_hot    = try f.loadTextureFromPath("wall.png");  // + HotReloadable
const fb         = try f.loadRenderTexture(800, 600);
```

Field accessors keep `tex.width` ergonomic:

```zig
pub fn width(self: Texture2D, f: *const Frame) i32 {
    return self.deref(f.gpu_textures).?.width;
}
```

Users never deref manually because every meaningful op on a Texture2D
is a Frame method that derefs internally.

## Beyond resources

ECS as the canonical store for "things with identity, lifetime, and
per-instance state":

| Domain | ECS? | Why |
|---|---|---|
| GPU resources (this plan) | ✅ | Bulk-free, hot-reload, queries |
| Game state | ✅ (today) | Already ECS, user-owned |
| Audio sources | ✅ | Spatial audio = `{AudioSource, Transform}` |
| Tween/animation | ✅ | Declarative anim = classic ECS use case |
| Particle emitters | ✅ | Per-instance state, lifetime |
| Asset bundles | ✅ | Bundle = tag component, query is the API |
| UI | ❌ | Retained-mode widget tree doesn't fit |
| Input | ❌ | Static config, no per-instance lifetime |
| Window / framework config | ❌ | Singletons |
| Scratch buffers | ❌ | Arena's job |

The discipline: ECS is for things you'd talk about in plurals.

## What it costs (honest)

1. **`tex.deref(f)` indirection.** Today `tex.width` works directly.
   After this, it requires a deref accessor.  Mitigation: exhaustive
   accessors on each ref type so users almost never deref manually.
   But the mental model "Texture2D is a ref, not the data" is a tax.

2. **Cmd buffer ceremony for spawn/destroy.** Resource loads are
   one-off and shouldn't pay batching overhead.  Fix: standing
   per-Frame cmd buffer flushed at end of frame, or use
   `changeArchImmediate` for resource ops.

3. **Capacity sizing.** 5 Entities × default ~32KB chunks = ~150KB
   upfront vs Pool's <1KB.  Acceptable but worth budgeting.

4. **Zig comptime density.** `Ref(T)`, phantom markers, type-id
   machinery.  Reading zimr internals requires more comptime fluency.

5. **Migration is large.** ~45 examples touch loaders + drawing
   primitives.  Mechanical per-stage but real work, weeks not days.

6. **Performance hit on point lookup.** ~3-5× slower per dereference
   than Pool.  For 10K lookups/frame: ~100μs extra, <1% of frame
   budget.  Not a deal-breaker.

7. **Cmd-buffer-flushing semantics are subtle.** `f.unloadTexture(tex)`
   mid-frame: GL release immediate, entity destroy queued.  Drawing
   the stale handle later in the frame would hit a freed GL ID.
   Fix: GL release + entity-destroy both immediate (bypass cmd buf
   for unload).

## Where I pushed back on the ambition

- **Don't migrate UI to ECS** — retained-mode doesn't fit, hurts more
  than it helps.
- **Don't merge per-kind worlds into one mega-resource-world** —
  per-kind is materially simpler (constant offsets, smaller capacity).
- **Don't skip `compile()` and walk ECS directly in renderer** — the
  RenderList is a useful intermediate; compile-once / render-many
  matters for split-screen.
- **Don't migrate truly-internal renderer state** (shadow FBO,
  skybox quad mesh).  Those are singletons, not "things with
  identity."  Keep them as Renderer struct fields.

## 5-stage migration

**The stage breakdown depends on Q1-Q5 above.**  Drafting a real
migration plan needs the topology answer (Q1) and the drawing-primitive
shape (Q2).  Stub here for now — will be filled in once decisions
are made.

## Open questions

- **Drawing primitive shape.** `f.drawTexture(tex, x, y, tint)` is
  ergonomic but Frame becomes very wide.  Alternative: namespace
  methods (`f.tex.draw(...)`, `f.mesh.draw(...)`).  Decide at
  Stage 0 once we have a feel.

- **Where does `compile()` get the gpu worlds from?** Currently
  takes `*const Resources`; would take `*const Frame` instead.
  Adds a Frame dependency to scene.zig — fine but worth noting.

- **Renderer ownership of "internal" resources.** Shadow FBO and
  skybox quad mesh are owned by Renderer.  Should they migrate to
  Frame's `gpu_targets` / `gpu_meshes`?  Probably no — they're not
  user-visible and would clutter the worlds.  Renderer keeps its
  own raw fields.

- **Two-Entities-per-Frame friction.** User has their `world` for
  game state; zimr has its `gpu_*` worlds for resources.  Is there
  ever a reason game state should hold a Texture2D component?  Yes
  (sprite component holds a texture ref).  Refs cross worlds fine
  (a `Texture2D` ref holds an Entity from `gpu_textures`, not from
  the user's game world).  Documented confusion vector.

- **Hot-reload trigger mechanism.** File-watch is platform-specific.
  V1: manual API (`f.markForReload(tex)`); v2: filesystem watcher
  for native, polling for wasm.

- **Asset bundles syntax.** `BundleTag(u32)` is functional but
  bare; nicer DSL like `f.bundle("level1") { ... }` scope blocks
  could group spawns.  Defer.

## Intermediate wins (independently of the big plan)

These are good ideas regardless of whether Stages 0-5 ever happen:

- Top-level re-export `pub const freeMany = runtime.allocator.freeMany;`
- Doc comment on `rlgl.fwd` saying which subset it mirrors.
- `Entity.getValueOr(es, T, default)` to clean up the
  `if (e.get(es, T)) |p| p.* else Default` pattern.
- `DirectionalLight.shadow_extent` field for per-light shadow
  frustum control (replaces the hardcoded `SHADOW_HALF_EXTENT` /
  `SHADOW_NEAR` / `SHADOW_FAR` in `render.zig`).

## When to start

After P5b (sprite + cubemap) lands and the renderer hits v1.
This is too big to do mid-feature; one piece at a time.

If we want to *validate* the architecture before committing, the
cheapest first step is Stage 0 + a single Stage-1 loader for one
resource type, on one example.  The full migration is years-of-zimr
worth of work; the validation slice is one session.
