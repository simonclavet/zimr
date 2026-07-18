# zimr resources & game entities — a tutorial

This tutorial explains the unified model behind zimr's resources and
gameplay state.  The big idea: **everything with identity, lifetime,
and per-instance state is an entity**.  A texture is an entity.  The
player character is an entity.  A particle is an entity.  A patrol
waypoint is an entity.

What makes them feel different is just which **components** they
carry.  The data plane is uniform; the storage substrate is uniform;
the lookup mechanics are uniform.  The variety lives in components.

zimr commits to this all the way down — including for GPU resources.
"A texture handle is actually a typed entity ID" isn't a slogan;
it's the literal implementation.  This tutorial shows why that works,
why it's natural, and what it unlocks.

---

## The big idea, in one paragraph

An **entity** is a generation-tagged ID — a key into a lookup table.
A **component** is a piece of data stored under that key.  A **world**
(`ecs.Entities`) is the lookup table itself.  When you hold an
`Entity`, you hold a key; when you want the data, you ask the world
for the components that key resolves to.

A "Texture handle" in zimr is exactly this.  It's a key (an entity
ID), wrapped in a phantom-typed shell (`Ref(GpuTexture)`) so the
compiler refuses to pass it where a `Mesh` is expected.  The shell
adds nothing at runtime — the key inside is just an `ecs.Entity`.

When you draw with a texture, the drawing primitive resolves the key
through the texture world, gets back the GL state (id, dimensions,
format), and submits the draw call.  No magic.  Just keyed lookup
through a typed wrapper.

---

## Refresher — zimr's ECS in 30 seconds

```zig
const std = @import("std");
const z = @import("zimr");

// 1. Create a world (the "lookup table")
var world = try z.ecs.Entities.init(.{
    .gpa = gpa,
    .cap = .{ .entities = 1024, .arches = 16, .chunks = 8, .chunk = 4096 },
});
defer world.deinit(gpa);

// 2. Spawn an entity with components
const Player = struct { hp: u32, name: []const u8 };
const Position = struct { x: f32, y: f32 };

const e = try z.ecs.Entity.reserveImmediateOrErr(&world);
_ = try e.changeArchImmediateOrErr(&world, gpa, struct {
    p: Player,
    pos: Position,
}, .{ .add = .{
    .p = .{ .hp = 100, .name = "alice" },
    .pos = .{ .x = 50, .y = 50 },
} });

// 3. Query components
if (e.get(&world, Player)) |player| {
    std.debug.print("HP = {d}\n", .{player.hp});
}

// 4. Iterate by archetype
world.forEach(takeDamage, .{ .amount = 5 });
fn takeDamage(ctx: anytype, p: *Player) void { p.hp -|= ctx.amount; }
```

That's it.  Entities are keys; components are payloads; worlds are
the storage.  Iteration walks every entity carrying the requested
view of components.

---

## The keystone — phantom-typed entity refs

Now the resources side.  zimr defines:

```zig
// In src/gpu_v2.zig (post-bigbang: src/gpu.zig):
pub fn Ref(comptime Resource: type) type {
    return struct {
        entity: ecs.Entity,

        // Phantom marker — keeps Ref(A) and Ref(B) distinct types
        // at compile time.
        pub const Component = Resource;

        pub fn deref(self: @This(), world: *const ecs.Entities) ?*Resource {
            return self.entity.get(world, Resource);
        }
    };
}

pub const GpuTexture = struct {
    id:      c_uint,
    width:   c_int,
    height:  c_int,
    mipmaps: c_int,
    format:  c_int,
};

pub const Texture2D = Ref(GpuTexture);
```

Notice what's NOT happening:

- `Texture2D` doesn't store the GL id directly.
- `Texture2D` doesn't carry the width/height/format.
- `Texture2D` is not a struct holding GPU state.

Instead, **`Texture2D` is an entity ID, plus a phantom marker that
tells the type system "this entity should resolve to a `GpuTexture`
component."**  The data lives in the world.  The handle just
references it.

### Why phantom typing matters

The `pub const Component = Resource;` line participates in Zig's
comptime type identity.  This means `Ref(GpuTexture)` and
`Ref(GpuMesh)` are DIFFERENT TYPES at compile time, even though
both wrap a single `entity: ecs.Entity` field.

```zig
fn drawTexture(world: *const ecs.Entities, tex: Texture2D, ...) void { ... }
fn drawMesh(world: *const ecs.Entities, mesh: Mesh, ...) void { ... }

const tex: Texture2D = ...;
drawMesh(&world, tex, ...);  // ❌ Compile error — Texture2D is not Mesh
```

Same compile-time safety as the old Pool-based handles.  No runtime
cost — `Ref(GpuTexture)` is `pub struct { entity: ecs.Entity }`,
which lowers to the bytes of `ecs.Entity` itself (12 bytes).

---

## Example 1 — load and draw a texture

The simplest possible end-to-end:

```zig
const State = struct {
    textures: z.ecs.Entities,
    smiley:   z.gpu.Texture2D,
};

fn initState(f: *z.Frame) !State {
    var textures = try z.ecs.Entities.init(.{
        .gpa = f.gpa,
        .cap = .{ .entities = 16, .arches = 4, .chunks = 2, .chunk = 4096 },
    });
    errdefer textures.deinit(f.gpa);

    const smiley = try z.gpu.loadFromMemory(f.gpa, &textures, smiley_png_bytes);

    return .{ .textures = textures, .smiley = smiley };
}

fn update(f: *z.Frame, state: *State) void {
    // Resolve the ref to get GPU state.
    const gpu = state.smiley.deref(&state.textures) orelse return;
    std.debug.print("rendering {d}x{d}\n", .{ gpu.width, gpu.height });

    // Draw with the ref directly — drawTexturePro derefs internally.
    const src = z.types.Rectangle.init(0, 0, @floatFromInt(gpu.width), @floatFromInt(gpu.height));
    const dst = z.types.Rectangle.init(100, 100, 256, 256);
    z.gpu.drawTexturePro(
        f.gl,
        &state.textures,    // the world to deref through
        state.smiley,       // the ref
        src, dst, .{ .x = 0, .y = 0 }, 0,
        z.colors.white,
    );
}
```

Notice the structure:

- `state.textures` is a plain `ecs.Entities` — a regular ECS world,
  no special-casing for being "a resource world."
- `state.smiley` is just a typed key (`Texture2D`).  Copying it is
  copying 12 bytes; passing it across functions is normal.
- `loadFromMemory` takes everything it needs explicitly: allocator
  (for ECS spawn + decode buffer), the world (where the new entity
  goes), and the bytes to decode.  Args ARE the docs.
- `drawTexturePro` derefs the ref against the world internally;
  caller sees a clean signature.

---

## Example 2 — adding metadata for free

This is where the model actually starts to pay off.  Suppose you
want WebGL2 context-loss recovery: if the browser kills your GL
context (it happens, especially on mobile), you need to re-upload
every texture.  That requires keeping the source bytes around.

With Pool-based handles, you'd build a parallel side-table mapping
`Handle(Texture) → []const u8`.  Two structures to keep in sync;
two places to remember to update on load/unload.

With ECS-backed refs, you just attach an extra component:

```zig
// Already defined in zimr:
pub const SourceBytes = struct {
    bytes:    []const u8,
    encoding: enum { png, jpg, raw },
};

pub fn loadFromMemoryRetained(
    gpa: Allocator,
    world: *ecs.Entities,
    bytes: []const u8,
    encoding: SourceBytesEncoding,
) !Texture2D {
    // ... decode + GPU upload as usual ...
    _ = try entity.changeArchImmediateOrErr(world, gpa, struct {
        gpu:    GpuTexture,
        source: SourceBytes,
    }, .{ .add = .{ .gpu = gpu, .source = .{ .bytes = bytes, .encoding = encoding } } });
}
```

Now your retained-source textures live in the `{GpuTexture, SourceBytes}`
archetype.  Bare textures live in `{GpuTexture}`.  The crucial
property: **`tex.deref(&world)` resolves correctly for both** —
the user-facing API doesn't care which archetype the entity is in.

```zig
const tex_a = try z.gpu.loadFromMemory(...);             // bare
const tex_b = try z.gpu.loadFromMemoryRetained(...);     // retained
const tex_c = try z.gpu.loadFromMemory(...);             // bare

// All three deref the same way.
_ = tex_a.deref(&textures);
_ = tex_b.deref(&textures);
_ = tex_c.deref(&textures);
```

Then context-loss recovery becomes a one-liner query:

```zig
fn recoverContext(world: *ecs.Entities) void {
    world.forEach(reuploadTexture, .{});
}

fn reuploadTexture(_: anytype, gpu: *GpuTexture, src: *const SourceBytes) void {
    // Skipped automatically for textures without SourceBytes —
    // forEach only visits entities matching the requested view.
    gpu.id = uploadFromBytes(src.bytes, src.encoding);
}
```

The textures without `SourceBytes` aren't touched; they were
ephemeral and the developer accepted that.  No flag checks, no null
checks.  The archetype IS the flag.

---

## Example 3 — bulk-free with a tag component

Asset bundles: when the player leaves a level, you want to free all
textures loaded for that level.  In ECS terms, this is an iteration
plus a destroy.

```zig
pub const LevelTag = struct { id: u32 };

// At load time, add the level tag:
const tex = try z.gpu.loadFromMemoryRetained(gpa, &textures, bytes, .png);
_ = try tex.entity.changeArchImmediateOrErr(&textures, gpa, struct {
    tag: LevelTag,
}, .{ .add = .{ .tag = .{ .id = 1 } } });

// At unload time, walk the matching archetype and free:
const UnloadCtx = struct { target_level: u32, world: *ecs.Entities };
var ctx = UnloadCtx{ .target_level = 1, .world = &textures };
textures.forEach(unloadIfMatch, &ctx);

fn unloadIfMatch(ctx: *UnloadCtx, e: ecs.Entity, gpu: *GpuTexture, tag: *const LevelTag) void {
    if (tag.id != ctx.target_level) return;
    rlgl.fwd.rlUnloadTexture(gpu.id);
    _ = e.destroyImmediate(ctx.world);
}
```

Try this with Pool: you can't.  You'd need a side-map
`Handle → level_id`, walk it, look up each handle in Pool, free
each one.  Two structures, two iteration sites, possible
inconsistency.

With ECS, the tag IS the index.  No side-table.

---

## Example 4 — queries are the API

You want to know: how much GPU memory am I using on textures?

```zig
const SizeAccum = struct { bytes: u64 };
var accum = SizeAccum{ .bytes = 0 };

textures.forEach(addBytes, &accum);

fn addBytes(ctx: *SizeAccum, gpu: *const GpuTexture) void {
    const bpp: u64 = 4;  // assume RGBA8 for this rough estimate
    ctx.bytes += @as(u64, @intCast(gpu.width)) * @as(u64, @intCast(gpu.height)) * bpp;
}

std.debug.print("textures: {d} MB\n", .{ accum.bytes / (1024 * 1024) });
```

Or: how many textures still need source-byte hydration?

```zig
const Counter = struct { n: u32 };
var c = Counter{ .n = 0 };
textures.forEach(countBare, &c);

fn countBare(ctx: *Counter, gpu: *const GpuTexture) void {
    _ = gpu;  // we just need the count of {GpuTexture}-bearing entities
    ctx.n += 1;
}
// Subtract count of {GpuTexture, SourceBytes} entities for "bare-only" count.
```

Or: find textures by source path (debug tool, "where is wall.png?"):

```zig
fn findByPath(...): ?z.gpu.Texture2D { /* forEach with SourceBytes view */ }
```

The pattern is always the same: `world.forEach(callback, ctx)` with
the components you care about.  The ECS handles the matching.  No
side-tables to keep coherent.

---

## Example 5 — game entities and resources, side by side

This is where the unified model really sings.  The user has both
a gameplay world AND a textures world.  An entity in the gameplay
world (a sprite) needs to know which texture to render.  The
clean solution: store the `Texture2D` ref directly in a gameplay
component.

```zig
const Sprite = struct { tex: z.gpu.Texture2D };
const Position = struct { x: f32, y: f32 };

// One world for the game.
var game = try z.ecs.Entities.init(.{ ... });
defer game.deinit(gpa);

// Another world for textures.
var textures = try z.ecs.Entities.init(.{ ... });
defer textures.deinit(gpa);

// Load a texture into the textures world.
const player_tex = try z.gpu.loadFromMemory(gpa, &textures, player_png);

// Spawn a player entity in the game world, with a Sprite that
// references the texture entity.
const player = try z.ecs.Entity.reserveImmediateOrErr(&game);
_ = try player.changeArchImmediateOrErr(&game, gpa, struct {
    pos: Position,
    sprite: Sprite,
}, .{ .add = .{
    .pos = .{ .x = 100, .y = 100 },
    .sprite = .{ .tex = player_tex },
} });

// In the render pass, for each sprite, deref the texture ref through
// the textures world and submit a draw.
const RenderCtx = struct { gl: *rlgl.GlState, textures: *ecs.Entities };
game.forEach(renderSprite, &RenderCtx{ .gl = f.gl, .textures = &textures });

fn renderSprite(ctx: *RenderCtx, pos: *const Position, spr: *const Sprite) void {
    z.gpu.drawTexturePro(ctx.gl, ctx.textures, spr.tex, ...);
}
```

Read that carefully.  The `Sprite` component lives in the game
world.  The `Texture2D` it holds is a ref into the textures world.
**Refs cross worlds**.  The ref's identity is "(world key, generation)";
it doesn't matter which world the ref's holder lives in.

The deref happens against the world the ref points into, not the
world the holder is in.  So the drawing primitive needs both: the
game iteration walks the game world; the texture deref happens
against the textures world.  Both are explicit in the call.

This is how the model scales.  Resources and gameplay use the SAME
substrate.  They don't need a special bridge.  Refs are the bridge.

---

## Why this works — the underlying truth

**An entity ID is a generation-tagged key.**  Just bytes.  It carries
no information about which world it indexes.  When you deref, you
provide the world; the world looks up by index, validates by
generation, returns the slot's data.

**A `Ref(T)` is the same key, plus a phantom type.**  The type tells
the compiler "this key should resolve to a `T` when looked up in
its world."  The compiler enforces that contract on the API surface;
the runtime trusts it.

**A world is just a lookup table for entities.**  Every world has the
same shape (chunks, archetypes, slot maps); only the registered
component types and capacity differ.  There's no "resource world"
type vs "game world" type.  They're both `ecs.Entities`.

**Components are the variety.**  `GpuTexture` is just a struct.
`Position` is just a struct.  `Sprite` is just a struct.  None of
them know they're in an "ECS" — they're plain old data, stored in
chunked SoA arrays.  Variety in behavior comes from which
components an entity carries, which determines which iterations
visit it.

Put together: **the ECS is the universal substrate for instance-shaped
state.**  Resources are an instance-shaped concept (each texture is
an instance, lifetimes vary, per-instance metadata exists).  So
resources are entities.  No special pleading required.

---

## When NOT to use ECS

zimr commits to ECS for things-with-identity, but not for everything:

| Domain | ECS? | Why or why not |
|---|---|---|
| GPU resources (textures, meshes, shaders, fonts) | ✅ | Instance-shaped, queryable, metadata |
| Gameplay state (players, enemies, projectiles) | ✅ | Already the canonical use case |
| Audio sources | ✅ | Instance-shaped, spatial audio = `{AudioSource, Transform}` |
| Tween/animation channels | ✅ | Per-instance state + lifetime |
| Particle emitters | ✅ | Per-instance state |
| Asset bundles | ✅ | Tag component → query is the API |
| UI widget tree | ❌ | Retained-mode tree, not instance-shaped |
| Input config / bindings | ❌ | Static, no per-instance lifetime |
| Window / framework config | ❌ | Singleton |
| Frame-temporary scratch | ❌ | Use an arena |

The discipline: **ECS is for things you'd talk about in plurals.**
"The textures."  "The enemies."  "The audio sources."  When the
natural phrasing is plural and per-instance, ECS is the right fit.

---

## What the user always sees

After the big-bang migration, this is what user code looks like:

```zig
// Setup once.
var textures = try z.ecs.Entities.init(.{ ... });
var meshes   = try z.ecs.Entities.init(.{ ... });
var shaders  = try z.ecs.Entities.init(.{ ... });
defer ... cleanup ...;

// Or use the bundle helper for one-liner setup:
var gpu = try z.Resources.init(gpa);
defer gpu.deinit(gl, gpa);

// Load.
const tex = try z.gpu.loadFromMemory(gpa, &gpu.textures, png_bytes);
const mesh = try z.gpu.loadMeshFromGltf(gpa, &gpu.meshes, glb_bytes);

// Use.
z.gpu.drawTexturePro(f.gl, &gpu.textures, tex, src, dst, origin, rot, tint);
z.gpu.drawMesh(f.gl, &gpu.meshes, &gpu.textures, &gpu.shaders, mesh, mat, xform);

// Query.
gpu.textures.forEach(memoryUsageReport, &report);

// Tear down.
gpu.deinit(f.gl, gpa);  // walks every world, frees every GL id, deinits ECS
```

**Every call site declares what it depends on.**  No hidden state,
no god-bag Frame, no implicit lookups.  The API surface is literal:
read the signature, you know the dependencies.

The verbosity is the documentation.

---

## Frequently asked questions

**Q: How is this different from "wrap a u32 in a struct" (the old Pool handle)?**
A: Mechanically, the wrapper part isn't different.  The change is
WHERE the data lives: in Pool, the data array IS the storage; in
ECS, the data is a component in a chunk, alongside any number of
other optional components for the same entity.  The metadata story
(SourceBytes, LevelTag, etc.) is the payoff that Pool can't match.

**Q: Is the ECS lookup slower than Pool?**
A: Yes, marginally.  Pool: ~3-5ns per dereference.  ECS: ~10-20ns
(more pointer chases through the archetype machinery).  For 10k
lookups per frame, that's an extra ~100μs — under 1% of a 16ms
frame.  Not the bottleneck.

**Q: What happens if I deref a stale ref?**
A: `tex.deref(&world)` returns `null`.  The `?*GpuTexture` return
type forces you to handle it.  Drawing primitives no-op silently
on null derefs (matches raylib's behavior of accepting tex.id=0).

**Q: Can I share a ref across multiple worlds?**
A: A `Ref(T)` indexes a SPECIFIC world (whichever one it was created
in).  You can pass the ref around freely; you just need to pair it
with the right world to deref.  In practice this means: textures
deref through the textures world, meshes through the meshes world,
etc.  Mixing them is a runtime null deref, not a compile error —
the ref's type doesn't carry which world it came from.

**Q: What if I want to copy the texture's GL id out of the ref for
a long-running async op?**
A: Deref once, copy `gpu.id` into a local `c_uint`.  That bypasses
ref staleness checks — usually fine for short-lived ops, dangerous
for long ones.  Prefer keeping the ref and re-deref'ing each time.

**Q: When I migrate from Pool, do my user-facing types change name?**
A: No.  The user-facing names (`Texture2D`, `Mesh`, `Shader`, ...)
stay the same — only the underlying definition changes from a
raylib-parity struct to a `Ref(GpuTexture)` etc.  The current
raylib-parity structs are renamed to `GpuTexture` etc. and become
the components stored under the refs.  See the big-bang plan for
the full migration sequence.
