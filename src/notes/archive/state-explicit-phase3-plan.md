# state-explicit refactor — Phase 3 completion plan

> **⚠ STATUS (turn 4):** Stages 2-7 of this plan are SUPERSEDED by
> `state-explicit-completion-plan.md`.  The forward-looking work
> follows the new plan's per-fn workflow (leaf-first within each
> file, defensive-fixture sweep first as Phase A).  This doc
> remains as historical record of Stages 0 and 1, the original
> phase breakdown that informed the new plan, and the 12 lessons
> learned that carry forward.  Do not use the Stage 2+ schedule
> below for picking the next batch — refer to the completion
> plan instead.

The trip to Nogloballand.  Picks up where `state-explicit-plan.md`
ends: Phase 2 (residual retirement into `Runtime` fields with
`runtime_anchor.anchor` as the single allowed global pointer) is
done.  This doc is the long-tail plan for retiring every
`globalX()` accessor call by making fn signatures take their
substate explicitly.

## Why we're doing this

Four reasons, in order of immediacy:

1. **Mockability.**  Tests substitute `var gl: GlState = .{};` for
   the live runtime — no anchor fixture, no panic risk, every
   pre-condition obvious from the test body.
2. **Reading the code.**  A fn's signature is the contract.  When
   it says `(gl: *GlState, window: *const WindowState)`, you know
   exactly what state it touches before opening the body.  The
   user's words: "I am very happy that we now see what functions
   write and read."
3. **Phase 3 finds bugs.**  Three migrations in, the explicit-
   signature work has already surfaced one latent crash on wasm
   (`loadImageFromScreen` had broken `fwd` shim calls).  The type
   checker can only catch broken contracts when the contracts are
   visible.  Expect more such finds in drawing.zig.
4. **State save / hotreload + dual renderer (Stage 6, Stage 7).**
   Once every read/write goes through an explicit pointer, both
   snapshot-and-restore and dual-backend pixel-diff fall out of
   the discipline.

## Where we stand (refresh per turn)

```
=== globalX() production calls by file (broad grep) ===
src/drawing.zig      704     ← user-facing drawX surface (the boss)
src/rlgl.zig           0     ← clean (7 grep matches are all comments + the fn definition)
src/sound.zig        136     ← audio production cross-namespace
src/runtime.zig       39     ← camera / gestures internals
src/ui.zig             1     ← eager-mode drawTexturedQuad fallback
src/zimr.zig           0     ← clean (2 grep matches are doc comments)
                    ────
                     880     production total (excludes 9 doc-comment / fn-def grep matches)

=== Anchor fixtures in tests: 328 ===
=== Module-level residuals: 0  ✓ Phase 2 invariant holds ===

=== Build state: 874/874 native + 90/90 wasm smoke green ===
```

**Last batch:** Stage 1a (the rlgl-internal cleanup) — turned out to
be almost entirely test cleanup, not production fns.  Discovered
that production rlgl.zig had 0 real `globalState()` calls; all 156
were inside test bodies using the anchor-fixture pattern.  Bulk
script migrated 27 tests + 1 by-hand verify = 28 tests from the
4-line anchor preamble + `globalState()` calls to a single
`var state: GlState = .{};` + `&state` pattern.  Net: 156
globalState calls retired, 28 anchor fixtures dropped, build still
874/874 + 90/90 green.

**Surprise finding:** the plan estimated Stage 1 at ~5 turns
because it expected real production fns mixed with tests.  The
actual mix was 0 production / 156 test, so Stage 1 collapsed to
2 turns total (warmup + this).  Sound.zig at 136 calls is now the
next big block before drawing.zig.

## Completed batches (Phase 3 progress)

**Batch 1 — first move (texture mode worked example)**
`beginTextureMode` / `endTextureMode` migrated to `(gl: *GlState,
target)` and `(gl, window, ...)`.  Frame method form:
`f.beginTextureMode(target)`.  Examples migrated.  Demonstrated
the per-fn pattern and the test-fixture drop.

**Batch 2 — scope-shifters**
The user-facing scope-shifting fns now take their substate
explicitly:

- `beginScissorMode(gl, window, x, y, w, h)` / `endScissorMode(gl)`
- `loadImageFromScreen(gl, window, gpa)` — also fixed broken `fwd`
  shim calls discovered during migration
- `beginShaderMode(gl, shader)` / `endShaderMode(gl)`
- `beginBlendMode(gl, mode)` / `endBlendMode(gl)`
- `beginMode2D(gl, cam)` / `endMode2D(gl)`
- `beginMode3D(gl, cam)` / `endMode3D(gl)`

Frame methods route through `self.gl, self.window`.  Examples
migrated to Frame-method form: `rtt.zig`, `texture_readback.zig`,
`shader_uniforms.zig`, `dynamic_mesh.zig`, `gltf_simple.zig`,
`models3d.zig`, `skinned_mesh.zig`.

**Batch 3 — UI render chain (cross-file)**
The first cross-file Phase 3 cascade: `dispatchUpdate` →
`UiContext.endFrame(gl, window)` → `DrawList.render(self, gl,
window)` → `renderTexturedQuad(gl, ...)`.  Three files modified,
four signatures changed, one cascading caller (the eager-mode
`drawTexturedQuad`) isolated as a documented scarlet letter for
later.

## What we've learned (carry these into every batch)

1. **`runtime_anchor.zig` is the import-cycle escape hatch.**
   Subsystem accessors reach the anchor via
   `@import("runtime_anchor.zig")`, not `@import("zimr.zig")` —
   zimr re-exports `web.zig`'s wasm-only `extern "dom"` decls,
   which would brick native test builds with PIC errors if pulled
   in transitively.

2. **Anchor fixture pattern (test escape hatch).**
   ```zig
   const anchor_mod = @import("runtime_anchor.zig");
   var rt: anchor_mod.Runtime = .{ .gpa = std.testing.allocator };
   anchor_mod.anchor = &rt;
   defer anchor_mod.anchor = null;
   ```
   The fixture must be FIRST in the test body — any `globalX()`
   call before it panics.  Successful Phase-3 migration of a fn
   lets its tests drop the fixture in favor of locals (`var gl:
   GlState = .{};`).

3. **The fixture count is the Phase 3 progress metric.**  Every
   migrated fn removes ~1-3 fixtures.  Watch this number
   monotonically decrease.  Started Phase 3 at 361, now 356.
   Hold the line: if a turn's net fixture count goes UP, that
   turn added a new global-using path instead of retiring one —
   stop and audit.

4. **Phase 3 finds bugs.**  `loadImageFromScreen` was calling
   no-arg versions of `fwd` shims that take `*GlState` post-
   Phase-3e.  Host returned early; tests never tripped.  Phase 3
   explicit-sig migration forced the type checker to surface the
   broken contract.  **Treat this as expected behaviour, not a
   surprise.**  Drawing.zig will likely produce more such finds.

5. **Frame as substate carrier.**  `Frame.gl, Frame.window,
   Frame.input` live alongside the effect-vtable handles
   (`scratch, loader, clock, rng, log`).  Frame methods route
   through them.  **Don't add a `runtime: *Runtime` back-pointer
   to Frame** — discipline says "fns take only what they read or
   write," never the whole bundle.

6. **Three caller idioms, all valid:**
   - **`&app.runtime.X`** when `*App` is in scope (App.create,
     dispatchUpdate).  Cleanest; no scarlet letter.
   - **`f.beginX(...)`** when `*Frame` is in scope (user code).
     Routes through `f.gl` / `f.window` / `f.input` internally.
   - **`mod.globalX()`** when neither is reachable (logger sinks,
     JS-bridge thunks, internal infra deep in the call graph).
     The scarlet letter — flagged for further migration.

7. **Const-correctness as documentation.**  `*const InputState`
   for reads, `*InputState` for mutates.  Every signature
   declares intent.  Migration commit messages can list
   "reads X, writes Y" by reading the new signature.

8. **Eager-mode escape hatches stay documented inline.**  Where a
   call site can't reach a substate (e.g. UI widget code calling
   into UiContext without `*GlState`), the `globalX()` fallback
   is retained with a comment explaining the future cleanup
   trigger.  See `drawTexturedQuad` in `ui.zig` for the pattern.

9. **Disk hygiene.**  `.zig-cache` grows to ~8 GB across enough
   builds to brick the disk.  When `LLVM ERROR: IO failure on
   output stream: No space left on device` shows up, run
   `rm -rf /home/claude/zimr/.zig-cache /home/claude/zimr/zig-out`.
   ~50% disk recovery, fast clean rebuild.  Hit twice already
   this conversation; consider auto-clearing every 5 turns.

10. **Read what's there before adding.**  I duplicated `subFrame()`
    on a turn — there was already a thoughtful `SubFrameOverrides`
    helper that gallery uses.  Existing helpers exist for many
    patterns; check before writing.

11. **Cross-file cascades are bigger commits, not blocked
    commits.**  Batch 3 (UI render chain) modified 3 files +
    4 signatures.  Don't be afraid of these — but DO commit the
    whole cascade in one batch, with a documented scarlet letter
    where the cascade wasn't followed all the way (eager-mode
    `drawTexturedQuad`).  Half-cascades are confusing and
    mid-cascade test failures are demoralizing.

12. **Doc-comment drift.**  Phase 2 retired residuals; doc comments
    in the surrounding fns sometimes still reference them ("state
    lives in `input.STATE`", `&core.STATE`).  When migrating a
    fn, sweep its doc comment too.  Same for the cheatsheet —
    user-facing examples drift faster than internal code.

## Per-turn protocol (don't skip these)

Every turn does ALL of the following, in this order:

1. **Read the styleguide every 3rd turn.**  `src/notes/style-guide.md`.
   Rules 1-7 + 7b.  Keep them top of mind during edits.  In
   practice: at turn-start, glance at the file; ~3 minutes is
   enough.

2. **Update `CHEATSHEET.md` if a public API was migrated.**  When
   a Frame method gets added or a module-level fn signature
   changes user-facing behaviour, the cheatsheet's example block
   for that area is now stale.  Either update the example to the
   new form OR add a "Phase 3 progress: legacy form still works"
   note.  The cheatsheet stays aligned with the codebase — that's
   what stops user-facing examples from becoming silently wrong.
   Build commands, test counts, module table all live here.

3. **Append to the changelog.**  `src/notes/CHANGELOG.md` →
   `## [Unreleased]` section.  What was migrated, why, what
   broke, what's next.  Concise prose.  Per-turn protocol since
   day one of this refactor.

4. **Verify both builds green.**  `zig build test --summary all`
   (874/874) AND `zig build smoke-test --summary all` (90/90).
   Nothing leaves a turn red.

5. **Save snapshot.**  `/home/claude/snapshots/save.sh
   state-explicit-phase-3-<batch-name>`.  Snapshot before
   declaring the batch done.  Names follow a date-free convention
   so they sort by completion order.

6. **Save zip.**  `/mnt/user-data/outputs/zimr.zip`.  Standard
   excludes (`.zig-cache`, `zig-out`, `raylib_src`, `_dep`,
   `node_modules`, `.git`, `*.tar.gz`).

7. **`present_files`** the zip so the user can grab it.

8. **Refresh the metrics in this plan doc.**  The "Where we
   stand" table at the top of this file is a per-turn artifact —
   re-run the count + replace.  Keeps the plan honest about
   progress.

## Style-guide checkpoints during migration

While editing fn signatures and bodies, watch for:

- **Rule 1**: multi-arg fns one per line, `)` on its own line at
  fn indent.  Most Phase 3 migrations add a `gl: *GlState` first
  param — single-line signatures become multi-line.
- **Rule 2**: explicit local types.  When the migrated body
  introduces locals like `const cw = ...getRenderWidth(...)`,
  add `: c_int` annotation.
- **Rule 3**: braces on every branch.  Touch a fn, bring it to
  spec.  Watch for un-braced single-statement `if` / `while`
  bodies in pre-Phase-3 code that the migration touches.
- **Rule 5**: `**` → `@splat` when touching arrays.  Less common
  in Phase 3 but watch for it in test fixtures.
- **Rule 7b**: examples avoid module-level mutable globals — use
  `z.run` pattern.  The Phase 3 migration of examples to Frame-
  method form already aligns with this.

## The plan, divided into stages

Each stage is naturally batched.  Each batch is one turn (or
slightly more if a cascade widens).  Per-stage exit: 874/874 +
90/90 green, snapshot, changelog, zip.

### Stage 0 — user-facing scope-shifters (✅ DONE — batches 1, 2, 3)

The user-facing `beginX` / `endX` API surface now takes its
substate explicitly.  All examples are on Frame-method form.
The UI render chain (`endFrame` → `DrawList.render` →
`renderTexturedQuad`) threads substates end-to-end.  See
"Completed batches" above.

Net effect on metrics: started at ~1080 globalX calls, now 1059
(small absolute drop because Stage 0 fns weren't a numerically
big share — but they were the *visible* ones, and that's what
unlocks reading user code clearly).

### Stage 1 — rlgl.zig internal cleanup (~5 turns)

The 165 `globalState()` calls inside rlgl.zig were initially expected
to be ~50% production helpers and ~50% test bodies.  **The actual
mix turned out to be 0 production / 156 test** — production rlgl is
clean.  Stage 1's real work was test cleanup, not internal helper
threading.  Stage 1 collapsed to two completed batches:

1. **Stage 1-warmup (✅ DONE — surface stack push/pop)**  The
   15 `rlgl.globalState()` calls in `ui.zig` 7021-7095 lived in
   `pushRenderTextureImpl` / `popRenderTextureImpl` (the recursive
   render-target surface stack, not a popup-render fn — the plan
   originally misidentified the area).  Both impls + their
   `Ui.pushRenderTexture` / `Ui.popRenderTexture` wrappers now
   take `gl: *rlgl.GlState` explicitly.  `recursive_hud.zig` (the
   only external caller) threads `f.gl` through both call sites.
   Drops `ui.zig` to 1 residual call (the eager-mode
   `drawTexturedQuad` at line 6824 — separate cascade).

2. **Stage 1a (✅ DONE — rlgl test cleanup)**  All 28 anchor-
   fixture-using tests in rlgl.zig migrated to a stack-local
   `var state: GlState = .{};` pattern.  Mechanical Python rewrite:
   replace the 4-line anchor preamble with one `var state` line,
   replace every `globalState()` with `&state`.  156 globalState
   calls retired; 28 anchor fixtures dropped; 874/874 + 90/90
   still green.  Production rlgl had 0 globalState callers to
   begin with — the bodies of `rlPushMatrix`, `rlOrtho`, etc.
   already took `*GlState`; the migration was teaching the tests
   to construct their own GlState instead of relying on a
   process-wide anchor.

Stages 1b-1e (batch ops / framebuffer / shader internals / test
cleanup) as originally written are no longer needed — they
assumed production globals that don't exist in rlgl.zig today.
The original plan's estimate of ~5 turns for Stage 1 was off by
~3; this is good news.

### Stage 2 — sound.zig internal cleanup (~3 turns)

136 audio cross-namespace calls.  Pattern: `music.loadFromMemory`
internally calls `audio_device.globalState()` for AudioContext;
similarly for `sounds`, `streams`.  Migration adds
`*AudioDeviceState` parameter to the cross-namespace fns.

1. **Stage 2a — `audio_device` internal callers (the hub).**
2. **Stage 2b — `music` / `sounds` / `streams` callers of
   audio_device.**
3. **Stage 2c — `waves` AllocTable internals.**
4. **Stage 2d — test cleanup.**  ~50 fixtures drop.

Examples (`audio_basic`, `composer_drum`, `music_streaming`,
`audio_stream_synth`) currently use `z.audio_device.globalState()`
at top-level; these stay until Stage 4 batches them.

Expected fixture-count drop: ~50.

### Stage 3 — drawing.zig — the boss (~12 turns)

The big lift.  690 calls across the user-facing drawX surface.
Strategy: per-namespace migration.  Each namespace gets its own
batch.  The module-level fn signature changes (breaking) AND a
Frame method form gets added (new ergonomic API).

For each migrated namespace:
- Module-level `shapes.drawTriangle(v1, v2, v3, c)` becomes
  `shapes.drawTriangle(gl: *GlState, st: *const ShapesTextureState,
  v1, v2, v3, c)`.
- Frame method `f.drawTriangle(v1, v2, v3, c)` routes through
  `f.gl, &runtime_anchor.anchor.?.drawing.shapes_texture` (or
  better, add `drawing: *DrawingState` to Frame and use
  `f.drawing.shapes_texture`).
- Examples + tests + UI internal callers updated.
- CHEATSHEET examples for that namespace updated to Frame-method
  form.

Sub-stages by namespace:

1. **Stage 3a — `shapes`** (~150 calls).  Triangle/circle/line/
   rect/polygon/spline.  Largest surface.
2. **Stage 3b — `text`** (~80 calls).  `draw`, `drawEx`,
   `measure`, `measureEx`.  Adds `*FontDefaults` for the
   default-font path.
3. **Stage 3c — `textures`** (~120 calls).  `drawTexture*`,
   `drawTexturePro`.  Most need `*GlState` only.
4. **Stage 3d — `models`** (~180 calls).  `drawCube`,
   `drawCylinder`, `drawSphere`, `drawCapsule`, `drawSkybox`,
   `drawModel*`, `drawMesh*`, `drawBillboard*`.  The biggest
   namespace by surface area.  May need `*SkyboxCache` for
   skybox path.
5. **Stage 3e — remaining shaders + final cleanup** (~30
   calls).  Whatever's left.

Per stage: snapshot, changelog, zip.  Expected fixture-count drop:
~150 across the stages (drawing tests are the largest fixture
holders).

### Stage 4: examples + UI + final examples migration (~3 turns)

After 3a-3e, every drawX / textX / etc. has both a module-level
form (taking `*GlState` etc.) AND a Frame method.  Examples that
were left on the legacy `z.shapes.drawTriangle(...)` form get
batched-migrated to `f.drawTriangle(...)`.

UI internals (the eager-mode `drawTexturedQuad` fallback and
similar) get the explicit-state treatment.  Either thread
`*GlState` into UiContext, or change widget signatures to take
substates from outside.  Decision per-fn.

Expected fixture-count drop: ~50 (test cleanup as fns retire
their globalX paths).

### Stage 5: runtime.zig final + audit (~2 turns)

The 30 remaining calls in runtime.zig are camera-related
(camera_debug, getScreenToWorld* helpers).  Same pattern: take
`*const GlState` (most are read-only — getting current matrix
stacks).

Final audit:
- Inventory all REMAINING `globalX()` calls.  Each must have a
  comment explaining why it can't yet be parameter-taken (eager-
  mode UI fallback, JS bridge thunks, etc.).
- Total should be small — single digits.
- Most JS-bridge thunks reach `runtime_anchor.anchor.?.input` etc.
  These are the deliberate residual access — rename them in
  comments to `// JS-bridge thunk; explicit reach into anchor` to
  distinguish from migration debt.

### Stage 6: serialization / hotreload (~3 turns)

Per the original `state-explicit-plan.md` Phase 5.  Now that
every fn takes substates explicitly, snapshot-and-restore falls
out of the discipline:

1. **6a.** Split mixed states into `.Persistent` / `.Transient`
   sub-structs.  Per the original plan's table:
   - **persist**: game state, `assets`
   - **partial**: `time` (wall-clock offset persists, frame
     counter resets)
   - **drop**: `gl`, `input`, `fps`, `scratch`, `web` (rebuild
     fresh)
   - **reconstruct from JS**: `window`, `audio` (canvas size,
     audio ctx ID via JS query)
2. **6b.** `Runtime.dumpForReload(gpa) ![]u8` walks persistent
   fields only.  `Runtime.restoreFromReload(bytes) !void`
   populates them, zero-inits the rest.
3. **6c.** Round-trip tests + JS-side reload button (button →
   `world_dump` → tear down → re-instantiate → `world_restore`
   → resume RAF).

### Stage 7 (stretch): dual renderer + pixel diff

Once `*GlState` is everywhere, spawning two backends becomes
trivial: each pass takes its own GlState.  WebGL backend +
software renderer side-by-side; bytewise compare framebuffers.
Catches subtle GPU-vs-CPU mismatches.

This isn't on the critical path; it's the user's stretch goal,
documented here as the natural next step after Stage 6.

## Total scope estimate

~20 turns left to complete Stages 2-5 (Stages 0 and 1 are done).
Stages 6-7 are bonus.

| Stage | Topic                       | Turns | Fixtures dropped | Status |
|-------|-----------------------------|------:|-----------------:|--------|
| 0     | user-facing scope-shifters  |     3 |              ~7 | ✅ done |
| 1     | rlgl.zig internal           |     2 |              28 | ✅ done |
| 2     | sound.zig internal          |     3 |             ~50 | next   |
| 3     | drawing.zig (the boss)      |    12 |            ~150 |        |
| 4     | examples + UI cleanup       |     3 |             ~50 |        |
| 5     | runtime.zig + final audit   |     2 |              ~5 |        |
| 6     | serialization / hotreload   |     3 |              n/a |        |
| 7     | dual renderer (stretch)     |     ? |              n/a |        |
|       | **Total to Stage 5**        |  **25** |       **~290 fixtures** |  |

Started this conversation at 356 fixtures.  After Stage 1: 328
fixtures (28 dropped).  By Stage 5 completion: roughly 38 anchor
fixtures should remain (328 − 290), most at JS-bridge thunk +
integration test boundaries that legitimately need a live anchor.

Stage 1 came in at 2 turns instead of 5 because production rlgl
was already clean — the work was test cleanup, which scripted
nicely.  Stage 2 (sound.zig) is the next predictable case; if
sound.zig follows the same pattern (mostly tests), it could be
similar.  Worth checking the prod/test ratio before estimating.


## Reorder analysis — making fixtures drop fastest

*Added turn 3.  Strategic analysis raised by the user: "is there a
way to modify the plan ordering so that tests immediately stop
using global state?"*

### The structural insight

The existing plan splits each namespace into "migrate prod fns" +
"clean up tests" as if they're separate stages.  They aren't.
**Migrating a prod fn from `globalState()` to `*State` retires
its tests' anchor fixtures as a direct consequence.**  Stage 1a
demonstrated this: rlgl prod was already migrated, so a one-
script test-rewrite dropped 28 fixtures in one turn.  The
migration WAS the test cleanup.

So the reorder question is really: which fns first?

### Three leverage points

**1. Useless defensive fixtures.**  Empirically verified turn 3:
of 328 fixture-using tests, 283 (86%) have bodies that don't
directly mention `globalState()`.  Many of these are defensive
boilerplate — the fns they exercise already take state
explicitly.  Three shapes-texture tests in drawing.zig had their
fixtures removed and the build stayed green.  The fixture was
never needed.  This category drops without any prod migration.

**2. Leaf-migratable prod fns.**  A leaf fn is one whose body's
`globalState()` calls all route into fns that already take state
(`rl.*`, `wasm_fwd.*`, `fwd.*`).  30 such fns in drawing.zig
today (verified by call-graph scan).  Each leaf migration retires
fixtures from tests that exercise only that leaf.

**3. Priority by fan-in.**  Among leaf-migratable fns, prioritize
ones called by the most tests.  `drawTriangle` (~10 callers)
gives more fixture-drop-per-turn than a niche helper.

### Proposed new pass ordering

| Pass | Work | Est. fixtures dropped |
|------|------|----------------------:|
| A | Defensive sweep (drawing + sound + runtime) | ~150-280 |
| B | High-fan-in leaf prod migrations in drawing.zig | ~30-50 |
| C | Walk up the drawing.zig call graph | ~30-50 |
| D | sound.zig same shape | ~50 |
| E | runtime.zig + final audit | ~5 |

Pass A is the new contribution.  Not in the original plan because
the plan implicitly treats every fixture as necessary.  It isn't.

### Honest framing

"Tests immediately stop using global state" — Pass A is the only
path that drops fixtures without prod migration.  After Pass A,
remaining fixtures protect tests of fns that genuinely
`globalState()`; those need prod migration to retire.

There's no shortcut bolder than Pass A.  Hiding the anchor write
inside a helper would be cosmetic.  Prod fn signatures are the
actual gating constraint.

But Pass A is itself a big move: 86% defensive-fixture rate means
most of the 328 fixtures may drop in 1-2 turns with zero prod
signature churn.  That's the closest practical analog to
"immediately."

## Suggested next batch (decision point)

Three options for the user:

1. **Pass A first** — script-driven defensive-fixture sweep
   (per-test build-verify), then proceed to Pass B (leaf
   migrations).  Lowest-risk, highest-fixture-drop-per-turn.
2. **Skip Pass A, go to Pass B** — start leaf migrations
   immediately.  Slightly slower fixture drop but more
   architectural progress per turn.
3. **Original plan order** — Stage 2 (sound.zig at 136 prod
   calls).  Stick with the existing per-namespace cadence.

Lean: option 1.  Pass A is purely subtractive and easy to
verify.

## Pre-flight checklist for each batch

Before opening editing tools:

- [ ] Read styleguide if 3+ turns since last read
- [ ] Refresh metrics in this doc's "Where we stand" table
- [ ] Identify the batch's fns (`grep -nE 'fn drawX' src/drawing.zig`)
- [ ] Identify their callers (`grep -rE 'shapes.drawX\b' src/ examples/`)
- [ ] Identify their tests (`grep -nE 'test ".*drawX' src/drawing.zig`)
- [ ] Sketch the new signature (`*GlState`?  `*const ShapesTextureState`?
      both?)
- [ ] Decide: Frame method form needed?  (User-facing → yes;
      internal → no)

After editing:

- [ ] `zig build test --summary all` shows 874/874
- [ ] `zig build smoke-test --summary all` shows 90/90
- [ ] Updated `CHEATSHEET.md` if user-facing API changed
- [ ] Appended to `CHANGELOG.md` `## [Unreleased]`
- [ ] Saved snapshot via `save.sh`
- [ ] Saved zip to `/mnt/user-data/outputs/zimr.zip`
- [ ] Called `present_files` on the zip
- [ ] Updated metrics in this doc

## When stuck

- **Build fails with `No space left on device`**: clear caches,
  retry.  See "Disk hygiene" above.
- **A test panics with "Runtime not initialized"**: it exercises
  a production fn whose body still calls `globalX()` and the
  test doesn't have an anchor fixture.  Either add the fixture
  OR migrate the production fn to take the substate as parameter
  (preferred — drops the fixture instead of accumulating one).
- **Caller updates cascade widely**: stop, document the cascade
  in the plan, batch the cascade as its own stage.  Don't try to
  finish a stage when its mid-state means many tests are failing
  simultaneously.
- **A migration changes example files**: those are user-facing.
  Update CHEATSHEET to match.  The cheatsheet stays aligned with
  what users will copy-paste from.
