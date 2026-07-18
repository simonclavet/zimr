# The ECS integration plan

A successor / addendum to `dag-plan.md`, scoped to one task: ship a
single-file ECS as `src/ecs.zig`, globals-free, in zimr's source
tree.

## The starting point

User uploaded `ecs.zip` — a port of [Games-by-Mason/mr_ecs](https://codeberg.org/Games-by-Mason/mr_ecs)
already merged into a single-file `src/ecs.zig` (4899 lines) with
threading, profiling, and math extensions stripped out.  License:
MIT.  Suitable Zig 0.16 target.

The single-file form is ready to drop into our tree.  The
multi-file form (`src/Entities.zig` etc.) is the same code; we
take the merged version.

## Hard constraints (from the user)

These are non-negotiable and set the entire shape of the work:

1. **`src/ecs.zig` is allowed to import zimr** — it sits at the
   TOP of the DAG layer cake (or peer-of-zimr, depending on
   what it actually needs).
2. **Originally**: nothing in zimr's framework was allowed to
   import ecs.  **Relaxed in turn 75**: zimr framework code is
   free to use ecs.zig if a future feature benefits.  As of v1
   nothing does, and the file remains drop-out-able for users
   who don't want it.  The DAG check still catches cycles.
3. **`src/ecs.zig` must be globals-free** — no module-level `var`,
   no container-level `var`, no anchor pattern.  Per-process
   state must move into `Entities` (the ECS world handle).
4. **Style-guide compliant** — every fn touched gets the Rule 1-9
   sweep: arg-per-line, explicit local types, braces every branch,
   casual comments, `@splat` over `**`, lift literals, trivial
   bool conditions, single-call helpers earn their keep, examples
   avoid module-level mutable globals.  Plus doc comments
   declaring reads/writes/ ownership (the discipline that made
   the state-explicit refactor reviewable).
5. **One example** demonstrating use — minimal, self-contained,
   in the existing `examples/` style.
6. **`Node` (parent/child trees) ships in v1.**  Required
   because the next thing built on top of ecs is a scenegraph,
   and that needs `Node` from day one.  This is the change that
   reshapes Phases 3 and 4 below.

## What's actually globals-free already

Verified by grep + structural scan of the uploaded `ecs.zig`:

- No top-level `pub var` / `var`.
- No `threadlocal`.
- The `Entities` struct owns its own `HandleTab`, `Arches`,
  `ChunkPool` — those are per-instance, fine.
- The slot map (`SlotMap`) is per-instance.
- All command buffers are per-instance.
- All chunk allocations route through `ChunkPool` which routes
  through an `Allocator` passed at `init` time.

## What's NOT globals-free (the work)

Two distinct sins, both in the type-identity machinery:

### Sin 1 — `CompFlag.registered_buf` / `registered_len`

```zig
pub const CompFlag = enum(FlagInt) {
    pub const max = std.math.maxInt(FlagInt);
    var registered_buf: [max]TypeId = undefined;   // <-- container-level var
    var registered_len: u8 = 0;                    // <-- container-level var
    pub fn registerImmediate(id: TypeId) CompFlag { ... mutates above ... }
    pub fn unregisterAll() void { ... mutates above ... }  // <-- test escape hatch
};
```

This is the **central component-type registry** for the whole
process.  Two `Entities` instances in the same process share it.
The presence of `unregisterAll` tells you the original authors
already knew this was a problem for testing.

### Sin 2 — per-type `var info: TypeInfo` in `TypeInfo.init`

```zig
pub inline fn init(comptime T: type) *@This() {
    return &struct {
        var info: TypeInfo = .{          // <-- comptime-allocated, runtime-mutable
            .name = @typeName(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }.info;
}
```

Each call to `typeId(MyComp)` returns a pointer to one
process-shared `TypeInfo` for `MyComp`.  This is the classic
"singleton-per-type via comptime anonymous struct with file-scope
`var`" trick.  The mutable field `comp_flag: ?CompFlag` then gets
written by `registerImmediate`.

Two `Entities` instances calling `typeId(Position)` get the SAME
pointer back, with the SAME `comp_flag`, even though "Position is
flag 3" is a fact about ONE Entities instance, not the universe.

### What "globals-free" looks like for an archetype ECS

The minimal change: **the registry moves into `Entities`**.  Each
world owns its own `flag_table: std.AutoHashMapUnmanaged(TypeId, CompFlag)`.
`TypeId` stays as a process-stable identity (the comptime-anonymous
trick is fine for *identity*, just not for *mutation*), but
`CompFlag` becomes per-world.

`TypeInfo` loses its `comp_flag: ?CompFlag` field.  That field
becomes a hashmap entry inside `Entities`.

`registerImmediate(id)` becomes `Entities.registerImmediate(self, id)`.

The cost: every component lookup that previously did
`if (id.comp_flag) |f| return f` now does
`if (self.flag_table.get(id)) |f| return f` — one hashmap probe
per component per world.  In a hot loop this matters; the
per-world hashmap should be small (≤64 component types per the
`u6` flag width) and we can shape the table for it.  We can also
short-circuit the hashmap entirely if the type's `*TypeInfo`
itself caches a slot index — but the slot index is per-world so
the cache misses across worlds.  For now, accept the hashmap
probe.

## The plan

### Phase 0 — Pre-import audit (1 turn)

1. Read style-guide.md (every-3-turn discipline; counter resets
   here).
2. Read this plan in full.
3. Run baseline metrics: `count_globals.py`, `check_dag.py`.
4. Verify the dropped-in raw `ecs.zig` would actually compile
   against Zig 0.16 in our env: copy it to `/tmp` and run
   `zig test` on it standalone.  Catch any Zig version drift
   BEFORE we start the integration churn.
5. Diff-check: confirm no `pub var` / `var X = ` at file scope
   or container scope (other than the two sins above).
6. CHANGELOG entry: "starting ECS integration; baseline = 864
   host tests, 40 smoke, 0 SCCs".

### Phase 1 — Drop in raw + isolate the globals (2 turns)

**Goal**: get `src/ecs.zig` building in our tree as a leaf module,
with the global state CALLED OUT but not yet removed.  Tests will
fail (the existing in-source tests use the global registry); we
mark them with `// XXX globals — Phase 2` and skip them.

Sub-batch 1a (turn 1) — drop in:

1. Copy `/tmp/ecs/src/ecs.zig` to `/home/claude/src/ecs.zig`.
2. Update the file-head doc comment: replace the mr_ecs blurb
   with a zimr-style block declaring (a) license + provenance,
   (b) the per-world (no-globals) API contract, (c) the
   integration points with zimr (none mandatory; user code
   bridges).
3. Wire it into `build.zig` as a module so examples can `@import("ecs.zig")`.
4. `tests.zig` does NOT import ecs.zig (we're keeping its tests
   in-file and running them separately for now).
5. Verify the file parses + type-checks: `zig build` should
   succeed even without exercising ecs paths.
6. Run `check_dag.py` — `ecs` should appear as a node with zero
   inbound edges (no other src module imports it).  This is the
   structural invariant to defend going forward.

Sub-batch 1b (turn 2) — globals census + comment-out:

1. Grep the file for the two sins; confirm only those.
2. Add `// XXX globals (Phase 2)` markers above `registered_buf`,
   `registered_len`, `registerImmediate`, `unregisterAll`,
   `getAll`, `getId`, and the anonymous-struct `var info` in
   `TypeInfo.init`.
3. Build still green (no behaviour change).

### Phase 2 — Move the registry into `Entities` (3-4 turns)

The actual de-globalization work.

Sub-batch 2a — extend `Entities` with a per-world flag map:

1. Add a field to `Entities`:
   ```zig
   flag_table: std.AutoHashMapUnmanaged(TypeId, CompFlag) = .{},
   reverse_table: [CompFlag.max]TypeId = @splat(undefined),
   reverse_len: u8 = 0,
   ```
   The reverse table replaces `CompFlag.getAll()` /
   `CompFlag.getId()` — same shape as before, just per-world.
2. Add `Entities.deinit` cleanup for `flag_table`.

Sub-batch 2b — replace `registerImmediate`:

1. Move `CompFlag.registerImmediate` to
   `Entities.registerComponent(self: *Entities, id: TypeId) !CompFlag`.
2. Replace every call site (there are several inside `ecs.zig`).
3. The existing call shape `flag = CompFlag.registerImmediate(id)`
   becomes `flag = try es.registerComponent(id)` — note the
   error union (the global form `@panic`-ed on overflow; we
   make it returnable so users can detect it gracefully).

Sub-batch 2c — drop the `comp_flag` field from `TypeInfo`:

1. Remove the field.
2. Replace `if (id.comp_flag) |f|` early-return paths with
   `if (es.flag_table.get(id)) |f|`.
3. The anonymous `var info` becomes
   `const info = .{ ... }` (comptime-only, no mutation).
4. `TypeInfo.init` returns a pointer to this comptime const —
   this is now pure type-identity-by-pointer-address with NO
   runtime-mutable state.

Sub-batch 2d — replace the test escape hatch:

1. `unregisterAll()` is no longer needed (each test creates its
   own `Entities`; deinit takes the table with it).  Delete it.
2. `CompFlag.getAll() / getId()` move to `Entities` methods.
3. Re-enable any tests we disabled in Phase 1b.  Tests that
   relied on the global registry now create per-test `Entities`.

Sub-batch 2e — verify & sweep:

1. `grep -E '^\s*(var|pub var)\s' src/ecs.zig` returns empty.
2. All in-source tests pass.
3. `zig build test --summary all` shows our 864 + ecs's count
   passing.
4. Touch-cleanup pass on every fn modified by 2a-2d: Rule 1-7
   sweep, doc comment refreshed.

### Phase 3 — Style-guide pass on the whole file (4-5 turns)

This is the long one.  4900 lines of donor code that's
well-written but doesn't follow OUR rules.  Touch every
non-trivial public fn.

The donor code's pre-existing style is already pretty close (the
mr_ecs author is careful), so the sweep is mostly about:

- **Doc comments**: every public fn gets a `///` block declaring
  what it reads, what it mutates, and the allocator-ownership
  contract.  Currently the comments describe behaviour but not
  the read/write footprint — that's the zimr addition.
- **Multi-arg fns**: confirm one-arg-per-line (already mostly
  true).
- **Explicit local types**: `const x = foo()` → `const x: Foo = foo()`
  except where the type is on the line.
- **Trivial bool conditions**: lift compound `if (a and b and c.d > 0)`
  into named locals.
- **`@splat` over `**`**: there's a few `[N]T = .{...} ** N`
  patterns to convert.
- **Casual comments**: replace any "Step 1: ... Step 2: ..."
  numbered-step blocks with prose.

Sub-batch 3a (turn 1) — `Entities` + `Entity` (the heart of the API).
Sub-batch 3b (turn 2) — `CmdBuf` + `chunk` + `ChunkList`.
Sub-batch 3c (turn 3) — `Arches` + `view` + `meta` + `slot_map`.
Sub-batch 3d (turn 4) — `extras.NodeWithOptions` + `extras.Node`
  + `extras.Node.Tree` + `extras.Node.Exec` (the parent/child API
  the scenegraph will sit on top of — needs the most careful
  read/write doc-commenting because mutation traversal is subtle).
Sub-batch 3e (turn 5) — `extras.Tag` + `extras.Ref` +
  `extras.GenericRef` + final cleanup pass.

Per turn: build verify after each sub-batch.  CHANGELOG entry
listing fns swept.  Style guide read at every-3-turn boundary.

### Phase 4 — Build the example (1-2 turns)

Two examples, not one — because the scenegraph use-case demands
nodes specifically, and a flat boids example wouldn't exercise
them.

**Sub-batch 4a (turn 1) — flat ECS demo.**

A pure-archetype boids flock: 200 boids with `Position`,
`Velocity`, `Color` components, two systems (motion + draw).
This is the canonical "look how SoA iteration works" demo and
serves as the smallest possible smoke test for the de-globalized
core API.

```
examples/ecs_boids.zig
  — 200 boids, Position + Velocity + Color components.
  — System 1: velocity → position update.
  — System 2: draw each boid as a small circle.
  — No nodes; flat entity space.
```

**Sub-batch 4b (turn 2) — Node-using demo.**

A planetary system: sun → planet (orbiting sun) → moon (orbiting
planet).  Each entity has a `Position` and a `Spin` component;
each non-root has a `Node` component giving it a parent.  The
draw pass walks the tree, accumulating world-space transforms.
This validates: (a) node parent/child wiring, (b)
`Node.Tree` initialization + the `Tree` accessor, (c) ancestor
iteration (`getInAncestor`), (d) child iteration during draw.
It's the **proof of concept for the scenegraph that follows
this work**.

```
examples/ecs_planets.zig
  — Sun (root): Position {center}, Spin {0}.
  — Earth: Position {orbit_radius=200}, Spin {1.0}, Node {parent=sun}.
  — Moon:  Position {orbit_radius=40},  Spin {12.0}, Node {parent=earth}.
  — Update system: advance Spin angle, recompute local Position.
  — Draw system: walk tree, accumulate transforms, draw each
    body as a circle in world space.
```

Both examples imported as smoke tests in the existing harness.

### Phase 5 — RETIRED

Originally: extend `check_dag.py` to forbid framework→ecs edges.
That constraint has been relaxed — zimr framework code is allowed
to use ecs.zig if a future feature genuinely benefits from an ECS.
The DAG check still enforces "no cycles" (which catches accidental
ecs→zimr→ecs loops); we just don't pre-commit to the
framework-can't-import-ecs direction.

As of v1, nothing in `zimr.zig` reaches into `ecs.zig` (you can
verify with `grep -rn 'ecs\\.zig' src/zimr.zig src/runtime.zig
src/drawing.zig …`), but that's a fact about the current code, not
a contract.

### Phase 6 — Documentation (1 turn)

1. Update `LICENSE` — add **mr_ecs** (Games-by-Mason, MIT) to the
   third-party attribution table.  The header in `src/ecs.zig`
   already has the provenance comment from Phase 1; LICENSE
   gets the canonical entry.
2. Update `README.md` — add a one-paragraph "ECS" section
   pointing at `examples/ecs_boids.zig` (flat) and
   `examples/ecs_planets.zig` (tree).  Note that ecs.zig is
   independent and you don't have to use it; framework code
   doesn't depend on it.
3. Update `CHEATSHEET.md` and `CHEATSHEET.html` —
   `build_cheatsheet.py` walks `INCLUDED_FILES`; add `"ecs.zig"`
   to that list and re-run.  ECS fns won't have raylib or imgui
   equivalents (it's a different API surface), but they'll get
   the same per-fn signature + doc comment treatment.  Add a
   third namespace shape to the matcher so `extras.Node.*` /
   `extras.Tag.*` / `extras.Ref.*` render as namespace-prefixed
   entries.
4. Update `architecture.md` — note the ecs module's position
   (peer-of-zimr at L7, no inbound from framework as of v1 but
   framework is free to grow some), and the planned scenegraph
   build-out that will sit between zimr and user code.

## Node v1 — what's in, what's out

Node ships in v1.  Specifically:

**In v1**:
- `extras.NodeWithOptions(opts)` — the generic factory, parameterized
  on a `Name` type so users can pick `?[:0]const u8`, `[16:0]u8`,
  `void`, or anything else.
- `extras.Node = NodeWithOptions(.{ .Name = ?[:0]const u8 })` —
  the default specialization.  Suitable for almost every use
  case.
- `Node.Tree` — the per-world root anchor.  Lives in user
  state; one per scene.  Multiple Trees per `Entities` is
  supported (use one per scene-graph instance).
- `Node.View` — the immutable read view used during draw
  passes (parent / first_child / prev_sib / next_sib accessors
  return `?View`, not `?*Self`).
- `Node.setParentImmediate` / `Node.insertImmediate` /
  `Node.destroyImmediate` / `Node.destroyChildrenAndPluckImmediate`
  — direct (non-buffered) tree mutation.  Used by the planets
  example and required by the scenegraph follow-on for
  load-time setup.
- `Node.childIterator` / `Node.ancestorIterator` —
  the two traversal patterns the scenegraph needs.
- `Node.getInAncestor(T) ?*T` — find the nearest ancestor with
  a component of type `T`.  This is the key function for
  scenegraph world-transform inheritance.
- `Node.Exec.immediate` and `Node.Exec.afterCmdBuf` — the
  command-buffer integration that synchronises pending tree
  mutations through the existing `CmdBuf.Exec` extension hook.
  This is what lets the scenegraph queue parent-changes from
  inside iteration without invalidating the iterator.
- `extras.Tag` — used in `Node.findAncestorOf(Tag)` for "find
  the nearest ancestor that is a Camera" queries.  52 lines,
  cheap to include, hard to add later cleanly.

**Out of v1** (defer to later phases as need arises):
- `extras.Ref` and `extras.GenericRef` — typed entity refs with
  a `path` accessor for sub-field reads.  The scenegraph
  doesn't need them; user code can add `Entity.Optional` fields
  by hand.  ~144 lines + tests; defer to keep the v1 surface
  smaller.

**Why Node specifically gets the careful treatment** (sub-batch
3d gets a dedicated turn): Node is the API surface the scenegraph
will consume directly.  Every doc comment, every read/write
declaration, every error-path note matters because it becomes
part of the scenegraph's own contract one layer up.  Sloppy
docs here will be visible everywhere the scenegraph is used.

## Layered DAG after integration

```
L0  types, web                      (pure data + extern decls)
L1  codecs, raymath                 (pure CPU)
L2  errors, rlgl, sound             (state structs)
L3  drawing                         (renders things)
L4  runtime, ui                     (input, gestures, immediate-mode UI)
L5  runtime_assembly                (Runtime aggregate + JS shims)
L6  zimr                            (App, Frame, run)
L7  ecs                             (peer-of-zimr OR top — TBD; depends
                                     on whether ecs imports zimr)

Future (not part of this plan, but the shape it will take):

L8  scenegraph                      (sits on top of zimr + ecs;
                                     uses Node for hierarchy, uses
                                     zimr's Camera3D + Drawing API
                                     for traversal-driven rendering)
L9  user examples / apps
```

Decision pending in Phase 1: does `ecs.zig` actually need to
import anything from zimr?  Right now, no — it's pure data
plumbing.  If we add convenience helpers that take a `z.Frame`
or `z.gl` reference, then yes.  Default plan: **leave ecs as
zero-zimr-imports**, peer-of-zimr at L7.  All zimr+ecs
integration happens in user code (the example) and, later, in
the scenegraph layer.

## Per-turn discipline (from dag-plan.md, restated)

1. Audit at turn start (`count_globals.py` + `check_dag.py` +
   build verify both targets).
2. Style-guide read every 3 turns.
3. Re-read this plan every 5 turns.
4. Touch-cleanup on every fn modified.
5. Doc-comment every migrated/new fn (reads/writes/ownership).
6. Build verify after each sub-batch.
7. CHANGELOG every turn.
8. Save zip every turn unconditionally.

## Sizing & risk

| # | Phase                              | Turns | Risk |
| - | ---------------------------------- | ----- | ---- |
| 0 | Pre-import audit                   | 1     | low  |
| 1 | Drop in + isolate globals          | 2     | low  |
| 2 | Move registry into Entities        | 3-4   | med  |
| 3 | Style-guide pass (incl. Node sweep)| 4-5   | low  |
| 4 | Two examples (flat + Node tree)    | 1-2   | low  |
| 5 | Structural invariant guard         | 1     | low  |
| 6 | Documentation                      | 1     | low  |

**Total: ~13-16 turns** (was 12-14; +1-2 for Node v1: dedicated
sub-batch 3d for the 992-line node module + the planets example
in 4b).

The risk concentrations:
- Phase 2 (registry move) — touches the hot path of every ECS
  operation.  The hashmap probe per `getFlag` is a real perf
  delta vs the original direct-pointer-read.  Mitigation:
  measure with the existing in-source perf tests; if the delta
  is unacceptable, fall back to a per-Entities `comp_flag_cache:
  std.AutoHashMapUnmanaged(TypeId, CompFlag)` with a
  fast-path that stamps the cache on first miss.  (This is what
  the original code does, just process-wide instead of
  per-world.)
- Phase 3d (Node sweep) — node-tree mutation paths
  (`setParentImmediate`, `insertImmediate`, `destroyImmediate`)
  are the most subtle code in the donor.  They re-wire sibling
  links + parent links + child-head links in a specific order
  to keep the tree consistent during partial mutations.  Doc
  comments must declare that order precisely so the scenegraph
  build doesn't invent its own (broken) re-wiring.  Pair with
  the donor's existing 1090-line node test file (port it to
  our test suite).
- Phase 3 generally — by sheer surface area.  Mitigation:
  sub-batch by file/struct, build between batches.

## Non-goals

Things we are explicitly NOT doing in this integration:

- Re-introducing threading.  zimr is single-threaded WASM; the
  ECS already had it stripped; we keep it stripped.
- Adding back the math extensions (`Transform`, `SpringTransform`).
  Math lives in `raymath.zig`.  If the planets example needs
  vector math, it uses `z.raymath.vector2*`.
- Re-introducing Tracy.  No profiling integration.
- A query-DSL or scheduler.  The donor's `iterator` /
  `forEach` are enough.
- `extras.Ref` and `extras.GenericRef` — defer past v1.  The
  scenegraph build-on-top doesn't need them; they can land in a
  dedicated turn later if user code asks for them.
- The scenegraph itself.  This plan ships ECS + Node.  The
  scenegraph is the next plan; it sits on top of what we ship
  here.
