# state-explicit refactor — completion plan

*Written turn 4 of the conversation.  Supersedes the Stage 2-7
schedule from `state-explicit-phase3-plan.md` for forward-looking
work.  The earlier plan docs remain as historical record:*

- `state-explicit-plan.md` — original architecture (Runtime/Frame
  types, the discipline, decisions locked in).  Still authoritative
  for "what does the end state look like?"
- `state-explicit-inventory.md` — Phase 0 census of every file-scope
  `var` in the codebase.  Historical artifact.
- `state-explicit-phase3-plan.md` — the per-stage walk that got us
  through Stages 0 and 1.  Still authoritative for "what was
  shipped before turn 4 and why?"  Stages 2-7 in that doc are
  superseded by this plan.

## Goal

**Total elimination of module-level mutable state**, with one named
exception (the JS-bridge anchor, see next section).  Every fn
signature documents what it reads and writes.  Every test
constructs its own state on the stack.  No production code path
depends on any global except the one allowed exception.

## The one allowed exception — `runtime_anchor.anchor`

The only global that survives is:

```zig
// src/runtime_anchor.zig
pub var anchor: ?*Runtime = null;
```

It exists because the JS bridge layer (DOM event callbacks fired
from the browser, the `requestAnimationFrame` thunk that calls
`dispatchUpdate`) cannot receive a `*Runtime` parameter.  The
browser invokes our exported wasm fns with no arguments; those
fns must retrieve a `*Runtime` from a known location.  The anchor
is that location.

**This global is theoretically unavoidable.**  No reorganization
of zimr's user-facing API can change it — the constraint comes
from the host, not from us.

**It must be hard to misuse from anywhere else.**  Phase E of this
plan minimizes its accessibility:

- Already lives in its own module (`runtime_anchor.zig`),
  separate from public `zimr.zig` exports — partial protection.
- Will be renamed `_js_bridge_anchor` (the underscore prefix is
  zimr's convention for "internal — don't touch").
- Read access will be funneled through a single helper used only
  by JS-bridge thunks.
- After Phase E: zero reads from user code, examples, or tests.
  Production-internal reads count + audit each (one comment per
  call site explaining "this is a JS-bridge thunk, that's why").

The end-state count of `_js_bridge_anchor` reads should be in the
single digits — one per DOM event handler family (key, mouse,
touch, wheel) plus the RAF dispatch thunk.

## Where we stand (refresh per turn)

```
=== globalX() production calls by file (broad grep, excluding
   doc-comment occurrences and the fn-definition itself) ===
src/drawing.zig       73     ← user-facing drawX surface (the boss)
src/rlgl.zig           0     ← clean
src/sound.zig        136     ← audio cross-namespace
src/runtime.zig       39     ← camera / gestures internals
src/ui.zig             5     ← eager-mode + replay residuals
src/zimr.zig           0     ← clean
                    ────
                     253     production total

=== Anchor fixtures in tests ===
src/drawing.zig        0     ← FIXTURE-FREE  ✨
src/sound.zig         46
src/runtime.zig        5
src/rlgl.zig           0     ← clean (post Stage 1a)
                    ────
                      51     total

=== Module-level residuals (the count we're driving to single
   digits, all in JS-bridge thunks) ===
1                          ← `runtime_anchor.anchor` itself

=== Build state: 874/874 native + 90/90 wasm smoke green ===
```

**Last batch:** turn 20 — **globalShapesTexture blocker removed.**
This was the biggest single-turn drop in the entire project:
drawing.zig went from 261 → 73 globalState calls (-188, -72%).

Added `f.shapes_texture: *const ShapesTextureState` to Frame
(stamped from `&app.runtime.drawing.shapes_texture` in dispatch
each frame).  Migrated 2 helpers (shapesUv, emitTexturedQuad) +
9 cascade-blocked fns (drawTriangle, drawTriangleFan, drawPoly,
drawPolyLinesEx, drawCircleSector, drawRing, drawRectangleGradientEx,
drawRectangleRounded, drawRectangleRoundedLinesEx) + 11 forwarders
(drawPixel/V, drawCircle/V, drawRectangle/V/Rec/Pro, drawRectangleGradientV/H,
drawRectangleRoundedLines, drawSplineBasis, drawSplineCatmullRom).
That's 22 fns + 2 helpers + 1 Frame field + 4 tests + ~30 example
call sites in one turn.

Two scarlet letters added in src/ui.zig (eager-mode fallback in
drawRectFilled/drawRect, and DrawList.render replay path).  These
pull `drawing.shapes.globalShapesTexture()` and pass it to the now-
explicit fns.  They retire when the UI render path threads
shapes_state through.


## Per-fn workflow — the discipline

Every fn migration follows these steps.  Don't skip any.

**1. Pick.**  Choose the next fn to migrate.  Either:
  - A *leaf-migratable* prod fn (its body's `globalState()` calls
    all forward into already-state-taking fns: `rl.*`, `wasm_fwd.*`,
    `fwd.*`, or fns elsewhere in the codebase already migrated).
  - A *defensive-fixture* test sweep (the test body doesn't
    transitively need the anchor; verify by removing and building).

**2. Read.**  Open the fn's definition.  Read it end to end.
Understand what it does, what state it reads, what it writes.
This is the user's directive: "understand how it works ... before
threading states."

**3. Map callers.**  `grep -rnE '\bfn_name\(' src/ examples/`.  Note
every call site — both within the file and across files.  Note
how each caller currently has access to the substate (or doesn't
yet).

**4. Map tests.**  Tests in the same file just above/below the fn:
`grep -nB1 'fn_name(' src/<file>.zig` near `test "..."` markers.
Note which tests use the anchor fixture.

**5. Determine substate dependencies.**  What does the fn read or
write?  `*GlState`?  `*const ShapesTextureState`?  Multiple?  Each
gets its own parameter.  The original `state-explicit-plan.md`
discipline: "no fn takes the whole `Frame`" — even a fn that
needs `gl + window` takes them separately, not via Frame.

**6. Migrate the signature.**  Add the new substate parameters.

   - Apply Rule 1: each param on its own line if the fn takes
     more than one arg.  Closing `)` on its own line at the same
     indent as `pub fn`.  Return type follows on the same line as
     the `)`.
   - Substate params come FIRST.  Then user-meaningful args (the
     things the fn was about before the migration).
   - Naming: use the fn's parameter name from `*State` definitions.
     `state` for `*GlState` in rlgl tests (because rlgl.zig has
     `const gl = @import("web.zig").gl;` at module scope, so a
     local `gl` shadows it).  `gl` is fine elsewhere.  Use the
     concrete name (`shapes_state`, `font_defaults`) when ambiguous.

**7. Migrate the body.**  Replace `globalState()` reaches with the
new parameter.  Replace any internal calls that needed `*GlState`
etc. with the local parameter forwarded.

**8. Migrate the callers.**  For each call site:

   - **`*App` is in scope** (e.g. `dispatchUpdate`, `App.create`):
     pass `&app.runtime.X`.
   - **`*Frame` is in scope** (user code, examples): pass `f.gl`,
     `f.input`, etc.
   - **Neither in scope, caller is itself a prod fn that doesn't
     yet take state**: this is a CASCADE.  Decide:
     - Cascade now (extend the migration to the caller too) when
       the caller is small and migrating it doesn't bloat the
       turn.  Keep the discipline of "one fn per cycle" loosely —
       a cascade covering 2-3 fns in one turn is fine when they
       form a tight chain.
     - Leave a `globalState()` call at the call site as a
       documented scarlet letter when the caller is large or its
       own migration deserves its own turn.  Add a `// SCARLET:
       fn_X migration retires this` comment.  Lesson #11 from the
       phase3 plan: half-cascades are confusing — commit the whole
       cascade in one batch when reasonable.

**9. Migrate the tests.**  Tests of the migrated fn drop the anchor
fixture.  Replace with `var state: <Substate>State = .{};` (or
multiple if the test exercises multiple substates).  Replace
`globalState()` calls in test body with `&state`.

**10. Apply styleguide rules to the WHOLE fn.**  Not just the lines
you changed.  The styleguide rule: "the moment you edit a
function, bring the whole function up to spec."

   - **Rule 1**: arg-per-line for multi-arg fn declarations
   - **Rule 2**: explicit local types (`: c_int`, `: usize`, etc.)
     EXCEPT when the type is already on the line (allocs, casts)
   - **Rule 3**: braces on every branch.  No naked `if (x) return;`
   - **Rule 4**: comments are casual, undecorated, unnumbered.
     No `// 1. ... // 2. ...` step lists inside fn bodies
   - **Rule 5**: `@splat` over `**` for fixed-array fill
   - **Rule 6**: lift bare numeric literals at call sites into
     named consts when meaning isn't self-evident
   - **Rule 7**: keep boolean conditions trivial; lift complex
     sub-expressions into named locals
   - Plus the doc-comment-drift sweep: if the fn's `///` comment
     references a retired global (e.g. "state lives in
     `core.STATE`"), rewrite it.

**11. Build verify.**  `zig build test --summary all` (must show
874/874) AND `zig build smoke-test --summary all` (must show
90/90).  If either fails, the migration isn't done.

**12. Refresh metrics.**  Count globalState calls + anchor fixtures,
update the "Where we stand" block in this plan.

## Per-turn protocol — every turn does ALL of these in order

1. **Style guide read every 3rd turn.**  Open
   `src/notes/style-guide.md` at the start of the turn and re-read
   rules 1-7.  The rule isn't superstition — rule details fade
   between checks.  Specifically watch for the always-applicable
   rule that any fn we touch must come up to FULL spec, not just
   the changed lines.  (Last reads: turn 1, turn 4.)

2. **Per-fn workflow** above for as many fns as fit in a focused
   turn.  Lean: 1-3 fns per turn, plus a defensive-fixture sweep
   pass when those are running parallel.

3. **Update `CHEATSHEET.md`** if a public API surface (Frame
   methods, namespace-level fns visible to user code, exports
   from `zimr.zig`) was migrated.  Cheatsheet is the user's first
   look at the codebase; staleness there breaks new-user
   expectations.

4. **Append to `CHANGELOG.md`** under `## [Unreleased]`.  Concise
   prose: what was migrated, why, what broke during the turn,
   what's next.

5. **Verify both builds.**  874/874 native + 90/90 wasm smoke
   green.  No turn ends red.

6. **Save snapshot.**  `/home/claude/snapshots/save.sh
   state-explicit-phase-3-<batch>`.  Names follow a date-free
   convention so they sort by completion order.

7. **Save zip.**  Always save the zip every turn.  Path:
   `/mnt/user-data/outputs/zimr.zip`.  Standard excludes
   (`.zig-cache`, `zig-out`, `raylib_src`, `_dep`, `node_modules`,
   `.git`, `*.tar.gz`).  This is the user's working artifact —
   they pull it at any time to inspect or diff.

8. **`present_files`** the zip so the user can grab it.

9. **Refresh metrics in this plan doc.**  The "Where we stand"
   block is a per-turn artifact — re-run the count, replace.

## Phases ahead

| Phase | Topic | Est. turns | Anchor fixtures dropped | Build risk |
|-------|-------|-----------:|------------------------:|------------|
| A | Defensive-fixture sweep                  | ✅ done (1 turn) | 261 actual | Low |
| B | Leaf-by-leaf prod migration (drawing.zig)| ~10  | ~13      | Medium |
| C | sound.zig + runtime.zig migration        | ~5   | ~51      | Medium |
| D | UI eager-mode + final residuals          | ~2   | 0        | Low-Medium |
| E | Anchor access minimization               | ~1   | n/a      | Low |
| F | Serialization / hotreload (bonus)        | ~3   | n/a      | Medium |
| G | JS bridge reload (bonus)                 | ~2   | n/a      | High (e2e) |
| H | Dual renderer (stretch)                  | ?    | n/a      | n/a |
|   | **Total to Phase E completion**          | **~19** | **64 remaining → 0** | |

By Phase E completion: 0 anchor fixtures (all 64 remaining
retired by prod migration in Phases B-D), 0 production
globalState() calls, `runtime_anchor.anchor` renamed and read
only by a single-digit count of JS-bridge thunks.

### Phase A — Defensive-fixture sweep (✅ DONE — turn 5)

**Result:** 261 of 325 fixtures retired (80% defensive rate).
Final fixture count: 64 across drawing.zig (13), sound.zig (46),
runtime.zig (5).  All remaining fixtures are now load-bearing —
each protects a test of a prod fn that genuinely reaches
`globalState()` internally.

**Method used.**  Scripted bulk removal, then identify failures:

  1. Save backups of drawing.zig, sound.zig, runtime.zig.
  2. Bulk-remove every 4-line anchor preamble from all three files
     using a regex that matched the fixture pattern at any indent
     (8 or 12 spaces).
  3. Run `zig build test`.  64 tests panicked with "Runtime not
     initialized — call App.create first".  810 tests passed.
  4. Parse the failure list, extract `<module>.<namespaces>.test.<name>`.
  5. For each failing test, find the matching `test "<name>" {`
     inside the correct namespace block (the second-pass script
     was namespace-aware to handle duplicate test names across
     namespaces, e.g. `pause / resume don't panic` exists in
     three namespaces in sound.zig).
  6. Inject the 4-line fixture back at the start of each failing
     test body.
  7. Re-run tests.  874/874 + 90/90 green.

**Lesson.**  Naive `text.find()` against a test-name pattern
matches the first occurrence; if the same test name exists in
multiple namespaces (e.g. `loadFromMemory: rejects unknown
format` exists in both `music` and `waves`), the second-pass
script must scope its search to the failing test's parent
namespace.  Fixed on the second attempt after the first attempt
produced double-fixtures in sound.zig.

**Fixtures remaining after Phase A** (these are the input queue
for Phases B and C — each retires as its prod fn migrates):

  - **drawing.zig (13):** drawCapsule (3), drawTriangleStrip3D,
    loadMaterialDefault, updateModelAnimation, plus a few others
    in the `models` namespace.  Mostly the 3D models work that
    deeply uses `*GlState`.
  - **sound.zig (46):** dominated by the `waves` namespace
    (loadFromMemory + isValid + unload, copy, crop, format,
    loadSamples / unloadSamples, filter chain, exportToMemory,
    Sequence helpers, etc.).  These exercise audio infrastructure
    that internally calls `audio_device.globalState()`.
  - **runtime.zig (5):** getScreenToWorldRayEx (3 tests), Browser
    clock, Browser logger.  Each is a prod fn that calls
    `rlgl_mod.globalState()` or `core.globalTracelog()` /
    `core.globalTime()` internally.

### Phase B — Leaf-by-leaf prod migration in drawing.zig (~10 turns)

**The bulk of the architectural work.**  One fn at a time, end-to-end,
through the per-fn workflow above.

**Ordering rules**, in priority order:

  1. **Leaf-eligibility today.**  Every body's globalState() call
     must forward into an already-state-taking fn (`rl.*`,
     `wasm_fwd.*`, `fwd.*`, or a previously-migrated fn).  Walk
     the call graph bottom-up.
  2. **Fan-in.**  Among leaf-eligible, prefer fns called by more
     tests (more fixture drop per turn).
  3. **File locality.**  Once in drawing.zig, stay in drawing.zig
     until the file is mostly done.  Don't switch files mid-turn —
     mental context is a real cost.

**Starting candidates** (from turn 3's call-graph scan): 30 fns in
drawing.zig today.  Examples: `drawTriangle`, `drawTriangleGradient`,
`drawTriangleStrip`, `drawCircleSector`, `drawCircleLines`,
`drawCircleLinesV`, `drawRectangle`.  Each exercises rl.* fns
that already take `*GlState`.

**Cascade discipline.**  Migrating `drawTriangle` may force its
callers (e.g. `drawPolygon`) to either cascade or scarlet-letter.
Lesson #11 from the phase3 plan: commit the whole cascade in one
batch when reasonable; document scarlet letters when the cascade
deserves its own turn.

**Done when:** drawing.zig has 0 production globalState() calls.
At that point its tests all use stack-local substates.

### Phase C — sound.zig + runtime.zig migration (~5 turns)

**sound.zig (~136 calls).**  Cross-namespace pattern: `music.X`
internally calls `audio_device.globalState()` for AudioContext;
similarly `sounds.X` and `streams.X`.  Migration adds
`*AudioDeviceState` parameter to the cross-namespace fns.

**runtime.zig (~39 calls).**  Camera helpers (`getScreenToWorld*`,
`camera_debug` log throttle) and gestures internals.  The smallest
remaining file by surface area.  Same workflow as drawing.zig.

**Done when:** sound.zig + runtime.zig have 0 production
globalState() calls.

### Phase D — UI eager-mode + final residuals (~2 turns)

**`drawTexturedQuad` eager-mode fallback at `ui.zig:6824`.**  The
lone remaining ui.zig globalState.  The widget code that triggers
it doesn't have `*GlState` in scope today.  Two options:

  - Thread `*GlState` into UiContext (add a field).  Affects every
    UI widget call site indirectly.  Big cascade.
  - Restructure widget code so `gl` arrives at the call site some
    other way.  Affects fewer call sites; more design work.

Decide per the discipline; lean toward whichever has the smaller
follow-on cascade.

**Final residual audit.**  `grep -rE 'globalX\(\)' src/`.  For
each surviving call:

  - Confirm it's a JS-bridge thunk (DOM event handler, RAF
    dispatch).
  - Add `// JS-bridge thunk; explicit reach into anchor — see
    Phase E rationale` comment.

Total surviving global accesses: should be ~5-10.

### Phase E — Anchor access minimization (~1 turn)

**Goal:** make `runtime_anchor.anchor` hard to misuse from
anywhere except the documented JS-bridge thunks.

**Tactics:**

  1. Rename `pub var anchor: ?*Runtime = null;` to
     `pub var _js_bridge_anchor: ?*Runtime = null;`.  Underscore
     prefix is zimr's convention for "internal — do not access
     from user code or examples".
  2. Provide a single `_lookup()` helper that returns
     `*Runtime` (panics if null) and is the only sanctioned
     reader.
  3. Audit every read site: each must be a JS-bridge thunk in
     `web.zig` or `zimr.zig` dispatchUpdate / DOM-callback area.
  4. Confirm zero reads from user code, examples, tests.
     Examples and tests that need a Runtime construct one
     locally; user code never calls into JS-bridge thunks
     directly.

**Done when:** the anchor is unreachable except via the named
helper, the helper is called only from named JS-bridge thunks,
and every call site has a comment explaining its necessity.

### Phase F — Serialization / hotreload (~3 turns) — bonus

Per original `state-explicit-plan.md` Phase 5.  Now that every fn
takes substates explicitly, snapshot-and-restore falls out of the
discipline:

  1. Split mixed states into `.Persistent` / `.Transient` sub-
     structs.  Per the original plan's table:
     - **persist**: game state, `assets`
     - **partial**: `time` (wall-clock offset persists, frame
       counter resets)
     - **drop**: `gl`, `input`, `fps`, `scratch`, `web`
     - **reconstruct from JS**: `window`, `audio`
  2. `Runtime.dumpForReload(gpa) ![]u8` walks persistent fields
     only; `Runtime.restoreFromReload(bytes) !void` populates
     them and zero-inits the rest.
  3. Round-trip tests + JS-side reload button.

### Phase G — JS bridge reload (~2 turns) — bonus

Per original Phase 6.  Button → `world_dump` → tear down →
re-instantiate → `world_restore` → resume RAF.  JS-side input
queue survives the swap.  End-to-end reload preserves the
persistent subset.

### Phase H — Dual renderer (stretch)

Per original Phase 7.  Side-by-side WebGL + software backend with
bytewise framebuffer compare.  Trivial once `*GlState` is
threaded everywhere — each pass takes its own GlState.

## Lessons learned (carry across turns)

These come from `state-explicit-phase3-plan.md` and the experience
of turns 1-3.  Internalize them.

1. **`runtime_anchor.zig` is the import-cycle escape hatch.**
   Subsystem accessors reach the anchor via
   `@import("runtime_anchor.zig")`, not `@import("zimr.zig")` —
   zimr re-exports `web.zig`'s wasm-only `extern "dom"` decls,
   which would brick native test builds with PIC errors if
   pulled in transitively.  Don't change this.

2. **Anchor fixture pattern (test escape hatch — being retired).**
   The 4-line preamble was a workaround.  Once a fn is migrated,
   its tests use `var state: <Substate>State = .{};` instead.

3. **The fixture count is the progress metric.**  Every migrated
   fn removes ~1-3 fixtures.  Watch the count monotonically
   decrease.  If a turn ends with MORE fixtures than it started,
   stop and audit — that turn added a global-using path.

4. **Phase 3 finds bugs.**  Explicit signatures force the type
   checker to surface broken contracts that no-arg
   `globalState()` calls hid.  `loadImageFromScreen` had broken
   `fwd` shim calls discovered this way.  Expect more such
   finds in drawing.zig.

5. **Frame as substate carrier — not Runtime.**  `Frame.gl,
   Frame.window, Frame.input` live alongside the effect-vtable
   handles.  Don't add a `runtime: *Runtime` back-pointer to
   Frame — discipline says "fns take only what they read or
   write," never the whole bundle.

6. **Three caller idioms, all valid:**
   - **`&app.runtime.X`** when `*App` is in scope (cleanest)
   - **`f.beginX(...)`** when `*Frame` is in scope (user code)
   - **`mod.globalX()`** when neither is reachable — the scarlet
     letter, flagged for further migration

7. **Const-correctness as documentation.**  `*const InputState`
   for reads, `*InputState` for mutates.  Every signature
   declares intent.  Migration commit messages can list "reads
   X, writes Y" by reading the new signature.

8. **Eager-mode escape hatches stay documented inline.**  See
   `drawTexturedQuad` in `ui.zig` for the pattern.  These are
   the call sites where threading the substate would require a
   separate cascade.

9. **Disk hygiene.**  `.zig-cache` grows to ~8 GB across enough
   builds to brick the disk.  When `LLVM ERROR: IO failure on
   output stream: No space left on device` shows up:
   `rm -rf /home/claude/zimr/.zig-cache /home/claude/zimr/zig-out`.

10. **Read what's there before adding.**  Existing helpers exist
    for many patterns; check before writing.

11. **Cross-file cascades are bigger commits, not blocked
    commits.**  Don't be afraid of multi-file batches when
    they're a tight cascade.  Half-cascades are confusing.

12. **Doc-comment drift.**  Phase 2 retired residuals; doc
    comments in surrounding fns sometimes still reference them.
    Sweep doc comments when migrating a fn.

13. **Defer-time reaches matter.**  When migrating a fn with a
    fixture-bearing test, sweep the deinit/unload chain too.
    Fns called via `defer` from the test reach anchor at
    scope-exit, so the fixture cannot retire until those exit-
    side fns are migrated too.  Workflow addition: at step 4
    (map tests), also identify any `defer fn(...)` in the test
    body and trace those to confirm they don't reach
    `globalState`.  If they do, the cascade includes them.

## When stuck

- **Build fails with `No space left on device`**: clear caches
  (`rm -rf .zig-cache zig-out`), retry.
- **A test panics with "Runtime not initialized"**: it exercises
  a production fn whose body still calls `globalX()` and the test
  doesn't have an anchor fixture.  Either add the fixture OR
  migrate the production fn to take the substate as a parameter
  (preferred — drops the fixture instead of accumulating one).
- **Caller updates cascade widely**: stop, document the cascade
  here, batch it as its own turn.  Don't try to finish a phase
  when its mid-state means many tests are failing simultaneously.
- **A migration changes example files**: those are user-facing.
  Update CHEATSHEET to match.
- **Defensive-fixture sweep removes a fixture and the build
  fails**: the test was actually transitive.  Restore the
  fixture; that test goes back into the per-fn migration queue.
  Note in the changelog so we know which sweep candidates failed.

## Decision log (rationale for choices that aren't obvious)

- **Defensive sweep before prod migration (Phase A first).**  The
  86% useless-fixture finding is too good to leave on the table.
  Doing the sweep first means subsequent prod migrations see a
  cleaner test landscape — when a turn migrates `drawTriangle`,
  only the still-fixture-using tests need attention, not the
  defensively-fixtured ones that should never have had a
  fixture.

- **Leaf-first within prod migration.**  Plan §3 in the original
  plan picked subsystem ordering by caller count.  This plan
  picks fn ordering by leaf-eligibility within the subsystem.
  The two compose cleanly: pick a subsystem (drawing.zig
  first), then within it pick leaves first.

- **Stay in one file per turn (or short sequence of turns).**
  Mental context is real cost.  Switching files mid-turn means
  re-loading call-graph mental model.  Lean toward batching by
  file.

- **Allow cascades when tight; document scarlet letters when
  not.**  Lesson #11.  Cascading 3 fns in one turn is fine when
  they form a chain; cascading 30 isn't.

- **Apply styleguide to whole touched fn, not just changed
  lines.**  Per the styleguide's own rule.  This is a
  non-negotiable discipline — partial cleanup leaves the file
  in a worse state than full cleanup did.

## Pre-flight checklist for each turn

Before opening editing tools:

- [ ] Read styleguide if 3+ turns since last read (track at top
      of "Per-turn protocol" section)
- [ ] Refresh metrics in "Where we stand" — re-run the count
- [ ] Identify the next fn(s) to migrate (per ordering rules)
- [ ] Identify their callers (`grep -rnE`)
- [ ] Identify their tests
- [ ] Sketch the new signature (which substates? mutate or read?)
- [ ] Decide: cascade now, or scarlet letter?

After editing:

- [ ] `zig build test --summary all` shows 874/874
- [ ] `zig build smoke-test --summary all` shows 90/90
- [ ] Updated `CHEATSHEET.md` if user-facing API changed
- [ ] Appended to `CHANGELOG.md` under `[Unreleased]`
- [ ] Whole touched fn(s) up to styleguide spec (Rules 1-7 + doc
      comments)
- [ ] Saved snapshot via `save.sh`
- [ ] Saved zip to `/mnt/user-data/outputs/zimr.zip`
- [ ] Called `present_files` on the zip
- [ ] Updated metrics in this doc

## Goal restated

Anchor fixtures: 325 → 0.  Production globalState() calls: 880 → 0.
Module-level mutable state outside `_js_bridge_anchor`: 0.  Test
code that writes to or reads through the anchor: 0.  Read sites
of `_js_bridge_anchor`: single digits, all in named JS-bridge
thunks, each commented.

When all of those are achieved, Phase 3 is done and the
serialization / hotreload / dual-renderer work (Phases F-H)
becomes a natural follow-on.
