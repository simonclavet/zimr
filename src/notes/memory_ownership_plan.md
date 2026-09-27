# memory_ownership_plan.md - examples own what they cause, and the gate says who leaked

Status: COMPLETE (Sep 27). D1 = C and D4 (two counters + `--leak-trace`) landed and proven.
Triggered by: the smoke "leak" (rl_track_journal, Sep 26) - the shared glyph atlas keeps every example
font's glyphs, keyed by face ids that are never reused, so each lifecycle's font reload grows it.

## 1. The principle (Simon)

zimr lets examples own and control ALL memory - nothing hidden. Stated so it can be checked:

> Memory an example CAUSES to exist lives in an object the example holds, is allocated with the example's
> allocator, and is freed by that object's own teardown. The engine holds only what it would hold with no
> example running.

Checkable form: with engine and example on SEPARATE counting allocators, a full example lifecycle leaves
the ENGINE's live bytes and GPU handles exactly where they were. Any engine growth is an engine bug; any
example growth is the example's (or the API's, if the API made it easy to miss).

## 2. Where we stand (measured Sep 26)

The engine holds six kinds of per-example state today, released three different ways:

| engine structure | what it holds for the example | released by |
|---|---|---|
| `Renderer2D` texture registry | a bind group per drawn texture; font atlas textures | owner tag (`releaseOwner`, `resetRegistryFrom`) |
| `Renderer2D` sprite residency | uploaded sprite textures | cleared with the registry |
| `Renderer2D.glyph_cache` + `glyph_pages` | every glyph of every example font, 4 x 1024^2 pages | NOTHING - waits for the pages to fill |
| `Cube3D.tex_bind_cache` | a bind group per texture view | `resetRegistry` (the runner / launcher) |
| `Cube3D.mesh_gpu` | example meshes' vertex + index buffers | `resetRegistry` |
| `Cube3D` decal receivers | per-example geometry | `resetRegistry` |

Five of six are correct but HIDDEN: the example cannot see them, and they are released only because the
runner or launcher calls a reset on the example's behalf - an app outside those hosts must know to. The
sixth is the leak. And the gate cannot tell them apart: engine and example share one `CountingAllocator`.

## 3. Options for the ownership model (D1)

- **A. Derived state lives on the example's object.** `Font` owns its glyph cache (CPU entries + its own
  GPU pages, created lazily); a texture owns its bind group; a `Mesh` owns its uploaded buffers. Freed by
  `unloadFont` / `texture.deinit` / `unloadMesh`, which examples already call. The engine keeps only its
  own resources (its default font's cache, pipelines for its shaders, the white texture).
  + The principle, literally; no reset calls by hosts; zero API change where the example already frees
    the object. + An app outside the runner/launcher is leak-tight by construction.
  - A per-font atlas costs GPU memory per font (pages must be smaller than today's 4 MB); text in
    several fonts no longer batches into one draw; the biggest change (several subsystems).
- **B. Engine caches, every entry owner-tagged.** Generalise `registered_owner` to the glyph cache,
  Cube3D's caches, sprite residency: a lifecycle's entries are released with its owner tag.
  + One mechanism, small diff, keeps shared pages and cross-font batching.
  - Still hidden (engine memory the example cannot see); still needs a host to call the release.
- **C. Option 1: the atlas starts over at teardown** (`resetRegistryFrom`).
  + Ten lines, fixes the gate and the launcher today.
  - Hidden, and wipes the launcher's own glyphs too.

**Recommendation: A**, staged: the glyph cache first (it is the only one that grows), then textures'
bind groups, then meshes - each stage leaves the tree green. C is a fine stop-gap if the night must not
wait, and is thrown away by A.

## 4. The leak gate, made diagnosable (D4)

What took an hour by hand (a temporary alloc/free trace, pairing by pointer, phase markers) becomes the
gate's own report:

1. **Two counters: engine vs example.** `App` gives the example `example_gpa` and the engine
   `engine_gpa`, each a `CountingAllocator` over the same backing. The failure then names the SIDE:
   "engine grew by 5760 bytes across the example's lifecycle" is an engine-held leak by definition.
2. **An attribution mode** (`--leak-trace` on the smoke runner, off by default): the counting allocator
   records every allocation of the second lifecycle with its PHASE (init / frame N / deinit) and a SCOPE
   label (a `push("glyph_cache")` / `pop()` stack at subsystem entry points - leakwatch's idea, in the
   gate). On failure it prints each surviving block: size, phase, scope, and "grew from N bytes" when an
   allocation of the same scope was freed next to it (a container growth - the atlas shape).
3. **The hash-growth tell spelled out**: a single surviving block that replaced a smaller one is a
   container that GREW, not a missed free - the report says so, which points at "something appends
   and nothing clears" rather than "a deinit forgot a free".

Target output for today's bug:
`LEAK engine +5760 B: glyph_cache table grew 5772 -> 11532 during frame 1 (text2d.cachedGlyph)`.

## 5. Decisions

- D1 ownership model: A / B / C (recommend A, staged).
- D2 per-font glyph pages (if A): page size and cap per font (recommend 256^2 pages, up to 8 = 2 MB).
- D3 which other example-caused state moves (if A): textures' bind groups, meshes, sprites - all, or
  the glyph cache only for now.
- D4 the gate: two counters + attribution mode (recommend both; two counters first, it is small).

## 6. Journal
- **D1 decided: C.** A (example-owned derived state) and B (owner-tagged engine caches) are too big for
  what they buy. The atlas starts over when an example is torn down.
- **C landed.** `GlyphAtlas.requestReset()` (deferred to the next `beginFrame`, since a launcher child can
  be released mid-frame with quads still pointing into the pages), called from
  `Renderer2D.resetRegistryFrom` and `releaseOwner`. Test: a reloaded font's glyphs replace the old
  ones - same entry count, same table capacity. Smokes: hello_world, fluid_gpu, geno_ppo, geno_train,
  geno_track all PASS the managed lifecycle check (they failed by 2880-11648 bytes before).
- **D4 decided: both** - two counters (engine / example) and the attribution trace. Found while
  preparing: engine and example share `app.gpa` today, and examples hand it to engine calls
  (`loadFont(f, gpa, ...)`), so the split needs a guard for cross-allocator frees and a broad smoke run.
- **D4 part 1 landed - two counters.** `App.gpa` stays the EXAMPLE's (what init/deinit receive);
  new `App.engine_gpa` for the engine's own subsystems (pipeline + bind-group caches, Renderer2D,
  Cube3D). `CountingAllocator` gained a `label` and `wrong_side_frees`: freeing more than a counter
  handed out (memory freed through the other side's allocator) is logged and counted instead of
  wrapping. Runner exports `runnerEngineLiveBytes` and `runnerWrongSideFrees`; the smoke gate prints
  both sides after every lifecycle and fails separately on example growth, ENGINE growth, and any
  wrong-side free. Tests: counter balance through grow/shrink/free; a cross-counter free is caught.
- **The split found a real bug at once:** three of the five places that lazily create the engine's
  `Renderer2D` passed the CALLER's allocator - so an example loading a font in `init` made the engine's
  renderer (glyph atlas and all) live in the EXAMPLE's allocator. With a counting gpa it only
  misattributed; with an arena-mode example it is a use-after-free (the arena frees it at teardown).
  Now ONE function, `App.ensureRenderer2D`, always on `engine_gpa`.
- **Proof it measures:** with the atlas bug planted back, the gate says
  `ENGINE LEAK (managed): the engine kept 5760 bytes the example caused (8161 -> 13921 ...)`.
  Restored: hello_world, fluid_gpu, geno_ppo, geno_train, geno_track, launcher all PASS; every
  example's own side returns to exactly 0 after deinit, every engine side is flat, no wrong-side frees.
- **D4 part 2, the tracer (host side) landed.** Reused `leakwatch.LeakWatch` (grep before designing)
  rather than building a second tracker. It gained: `mark()` + `reportSinceMark()` (only what the
  second lifecycle made and kept), the PHASE (outermost scope) beside the leaf scope, the SIDE
  (`side_hint`, set by the `CountingAllocator` above it), and `grew_from` - the grow-by-copy shape
  (alloc(new) then, as the very next call, free(older, same scope)), reported as "probably a
  container that GREW", because nothing links the calls (LeakWatch's own growth test says why).
  `CountingAllocator` has a named vtable and an optional `watch`; `memwatch.pushScope(gpa, label)` /
  `popScope(gpa)` find the tracer through any counting `Allocator` (no globals; a no-op otherwise).
  Tests: a growing hash map vs a missed free, told apart since a mark; `pushScope` through the counter
  records scope and side; a non-counting allocator is a no-op.
  Next: the runner's `--leak-trace` (tracer under both counters, mark before lifecycle 2, report after
  it, surfaced by the harness), `pushScope` at the engine's subsystem entry points (glyph cache, texture
  registry, Cube3D uploads, pipeline cache), and the planted atlas bug read in one line.
- **D4 part 2 wired and proven.** `--leak-trace` on the smoke runner: the harness begins the tracer
  right after `_initialize` (so lifecycle 1's blocks are known - without that, a growth's old block is
  unknown and "grew from" cannot fire, which the first proof run showed), marks before the second
  lifecycle, and prints `reportSinceMark` after it (`!TRACE` lines, forwarded by runner.mjs like
  `!ASSERT`). Phases "init"/"frame"/"deinit" come from the runner (`App.pushTracePhase`); scopes
  "glyph_cache" (text2d.cachedGlyph) and "texture_registry" (Renderer2D.registerTexture) from the engine.
  Planted atlas bug: `engine +11532 bytes  frame: glyph_cache  - replaced a 5772-byte block of the same
  scope: probably a container that GREW (something appends, nothing clears), not a missed free`.
  Clean runs (hello_world, launcher): "nothing allocated in the second lifecycle is still live".
  All six smoke examples PASS. Not done: scopes in the pipeline cache and Cube3D uploads - add one when
  a trace first shows a block from there as "(no scope pushed)".
