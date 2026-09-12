# Changelog — turns 330-339

## [Unreleased]

**[Turn 339 — Lint cleanup arc kickoff: build.zig gates on fmt+lint,
five small rules cleared, `**` operator migration complete (it's
being retired from Zig).  5893 → 5846 issues; fmt clean; tests
1555/1555.  Most untyped-local + branch-braces sweeps still pending.]**

### What lands

- **`zig build` (default `install` target) now gates on fmt + lint.**
  New dep graph: `fmt-apply` → `lint` → `fmt-check` → `install`.
  Wasm compilation parallelises beside the checks.  Build fails on
  any lint failure (currently warn-only; flip blocking after the
  full sweep clears).  Two new steps registered: `zig build fmt`
  (apply only) and `zig build fmt-check` (check only).
- **Lint scope widened.**  `build.zig` lint scan now covers
  `examples/*.zig` in addition to `src/*.zig` (was non-recursive
  src-only).  True baseline: 5893 issues across 140 files (4986
  src + 907 examples).
- **`**` operator migration — 21/21 sites done.**  Operator is
  being retired from Zig (per upstream pre-removal notice).  Migration
  paths used:
  - Single-element array → `@splat(val)` with `: [N]T` annotation
    (15 sites in drawing.zig, codecs.zig, runtime.zig)
  - Dot-init single → same `@splat` with type annotation (2 sites
    in codecs.zig)
  - Multi-element pattern `{1,2,3,4} ** 4` → explicit literal
    array (1 site in drawing.zig, 16-byte 2x2 RGBA pattern)
  - String repetition → explicit literal concat (2 sites in
    codecs.zig) or `++ @as([N]u8, @splat(0))` (1 site in sound.zig)
- **`floor-pattern` cleared (5/5).**  drawing.zig × 4, examples ×
  1.  Used `@floor(@as(f32, @floatFromInt(x)) * scale)` form —
  the migration guide's `@floor(int * scale)` shortcut only works
  for lossless widths (i16/u8/u16); for i32 the explicit
  `@floatFromInt` is still required.  Worth a note in claude.md's
  Zig 0.16 section but not done this turn.
- **`c-types` cleared (7/7).**  `c_long` → `i64` (fixed-point
  raster trick) × 4, `c_ushort` → `u16` (mesh index buffer
  allocator calls) × 3.  Mesh.indices field at drawing.zig:580
  remains `[*c]c_ushort` — correctly recognized as FFI seam by
  the linter.

### Linter improvements (turn 339)

- **`array-mult` check rewritten.**  Now fires on ALL `**` uses
  with type-specific hint by LHS shape:
  `single-element → @splat`, `dot-init → @splat`,
  `multi-element pattern → @bitCast(@as([N][M]T, @splat(p)))`,
  `string → comptime ++ loop or explicit`.  My earlier turn-339
  precision-narrowing (skip strings + multi-element) reverted
  because all `**` cases need migration before the operator
  disappears.

### Design decisions

- **`fmt` is auto-apply, not check, in step 1 of the gate.**  Rationale:
  it's a free convenience — whitespace dirt shouldn't fail builds
  when the formatter can silently fix it.  The final `fmt-check`
  step (post-lint) is the actual gate; it would only fire if the
  linter mutated files (which today it doesn't).  Belt-and-suspenders
  for the future autofix mode.
- **Lint stays warn-only this turn.**  Until the full sweep is done
  (4400+ untyped-local + 800+ branch-braces remain), flipping to
  blocking would make `zig build` unusable for cleanup itself.  Flip
  is queued for after untyped-local + branch-braces clear.
- **`**` migration prefers explicit literals over `@bitCast` trick**
  when results fit on one line.  The 2x2 RGBA test pattern (16 bytes)
  is cleaner as a literal than `@bitCast(@as([4][4]u8, @splat(.{1,2,3,4})))`.
  The bitcast form is documented in the linter hint for when it's
  actually needed.
- **String repetition in tests used explicit concatenation literals.**
  `"abc" ** 4` (32 bytes) is short enough that
  `"NOTWAVE\x00NOTWAVE\x00NOTWAVE\x00NOTWAVE\x00"` reads better than
  a comptime `++` loop.  The 60-zero-byte case in sound.zig used
  `"..." ++ @as([60]u8, @splat(0))` since writing 60 nulls inline
  is unreadable.

### Audit

- `zig fmt --check src/ examples/ build.zig tools/`: **CLEAN**
- `zig build test`: **1555/1555 pass** (114/114 steps)
- `zig build lint`: 5846 issues (−47 from baseline 5893)

### Next-turn scope

Continue the by-rule sweep order from `lint-cleanup-plan.md`:

1. `clamp-pattern` (36) and `fn-args-multiline` (40) — small
   mechanical rules.
2. `ex-variant` (20) — needs per-pair opts design work.
3. `module-var` (1) — refactor or allow-list `entities.zig:1426`.
4. Implement the new `named-struct-init` rule (rule 15).
5. THEN: `branch-braces` (844) as a single big arc.
6. THEN: `untyped-local` (4447) split across 4-6 turns by file.
7. THEN: `line-length` (472) with judgment per site.
8. FINAL: flip linter to exit-nonzero on hits; `zig build` becomes
   a hard gate.

---

**[Turn 338 — AST-based style linter shipped.  `tools/zimrlint.zig`,
~1080 LOC + 489-line tutorial.  10 checks, build-step integrated.
Self-lints clean.]**

### What lands

- **`tools/zimrlint.zig`** — single Zig program, AST-based via
  `std.zig.Ast.parse`.  Ten checks: `untyped-local` (rule 2),
  `module-var` (rule 9), `array-mult` (rule 5), `line-length`
  (rule 10), `c-types` (rule 11), `fn-args-multiline` (rule 1,
  declarations only), `branch-braces` (rule 3),
  `ex-variant` (rule 14), `clamp-pattern` (bonus),
  `floor-pattern` (bonus).
- **`zig build lint`** integrated in `build.zig`.  Defaults to
  scanning `src/*.zig`; specific files via `-- src/foo.zig`.
  Flags `--quiet`, `--only=tag,tag`, `--skip=tag,tag`.
- **`src/notes/lint-zimr-tutorial.md`** — 489-line tutorial
  covering what each check does, how AST-based linting works
  in Zig, the architecture (driver → walker → per-node checks),
  type-signal detection logic, defensive child-node walking,
  FFI seam carve-out, output format, and how to add a new
  check.

### Design decisions

- **`branch-braces` is strict.**  `if (cond) return x;`
  flagged.  Simon's reasoning: he wants breakpoint-settable
  lines on the return statement.  Single-line ifs put the
  condition + body on the same line, so a breakpoint can't
  pause AFTER the condition evaluated.  Bracing forces the
  body onto its own line.  Only carve-out: switch as body
  (its own braces fully delimit the sub-expression).
- **Module-var allow-list generalized.**  Three classes of
  exception:
  1. C-ABI bridge files (`zimr.zig`, `runtime_assembly.zig`,
     `runtime.zig`) — blanket-allowed.
  2. One-shot warning flags — any module-level `var` whose
     name starts with `warned_`.  Establishes the naming
     convention as the way to opt out, rather than per-name
     exceptions.
  3. Function-scoped statics via `const S = struct { var x =
     ...; };` naturally avoid the check because the var is at
     struct-scope, not module-scope.
- **fn-args-multiline restricted to declarations.**  Per
  Simon's directive: function declarations are API surface,
  one-per-line aids readability there.  Call sites are
  governed by `line-length` (zig fmt handles wrapping).
- **Warn-only exit code.**  Exit 0 regardless of hits, until
  first cleanup pass clears existing.  Then flip to blocking
  by editing `main`.
- **FFI seam detection via `extern fn` presence.**  A file
  containing any `extern fn` is considered an FFI seam and
  the `c-types` check is suppressed.

### Self-lint results

`zig build lint -- tools/zimrlint.zig`: **0 issues**.
First-pass run found 57 untyped-local + 34 branch-braces;
cleaned via three Python regex passes + targeted manual fixes.
The linter now lints itself clean — meta-test passed.

### Codebase-wide results

`zig build lint` over all `src/*.zig`:
- **3696 untyped-local** (the big cleanup target; deferred)
- 309 branch-braces (early-return idioms; need cleanup)
- 305 line-length
- 40 fn-args-multiline (mostly in `web.zig`)
- 20 ex-variant (real raylib-port pairs: `drawLine`/`drawLineEx`)
- 12 module-var (now expected to be 0 after allow-list
  generalization)

Total: ~4400 hits across 27 files.  No cleanup attempted this
turn — the linter is the tool that surfaces them.

### Build state

- 1555/1555 native tests pass (unchanged).
- `zig build lint` warm: ~4s full src/ scan, ~1s single file.
- `zig run tools/zimrlint.zig` works standalone (no build step
  needed for editor integration).

### Files added/modified

- `tools/zimrlint.zig` — new, 1079 LOC.
- `src/notes/lint-zimr-tutorial.md` — new, 489 LOC.
- `build.zig` — added lint step (~50 LOC).
- `src/notes/PLAN.md` — sub-project entry already added turn
  337; no further update needed.

### Next

- Run the linter on `examples/*.zig` and the rest of `src/`,
  collect totals.
- Cleanup pass: triage the 4400 hits.  `untyped-local` is the
  biggest pile and probably gets a dedicated session.
- Flip exit code to blocking once existing hits cleared.

---

**[Turn 337 — lint-zimr plan written.  Discussion-only turn that
locked the v1 spec for the linter.  No code change.]**

---

### What lands

- **`loadFontDefault` deleted.**  Replaced by
  `loadFontFromTtfBytes(gpa, *FontCache, ttf_bytes,
  bake_size, codepoints, oversample)` — the explicit form
  the old default papered over.  Same idempotent +
  wasm-only behavior, but the user picks the TTF.
- **`unloadFontDefault` → `unloadFontCache`.**  Same code,
  honest name.
- **Embedded `atkinson_mono_ttf` constant deleted.**
  The 34 KB `@embedFile` line in `drawing.zig` is gone.
  Library code no longer ships any font bytes.  The TTF
  file moved to `examples/assets/fonts/atkinson_mono.ttf`
  so example code can embed it the same way users would
  embed their own asset.
- **Lazy auto-load in `beginFrame` reverted.**  `font_cache`
  parameter restored to `*const`.  The turn-330 footgun fix
  (auto-loading the default if the user forgot) is now
  obsolete — there's no default to auto-load.  The
  one-shot "text submitted without font loaded" warning
  (turn 330, `warned_text_no_font` flag in
  `drawing.zig`) stays, so apps that forget the load get
  a clear log message instead of silent text-less
  rendering.
- **All 87 examples swept.**  Three distinct call sites:
    try z.loadFontDefault(gpa, &font_cache);
    try z.loadFontDefault(gpa, &s.font_cache);
    try z.loadFontDefault(gpa, &state.font_cache);
  Each replaced by:
    try z.loadFontFromTtfBytes(
        gpa, &<cache>,
        @embedFile("assets/fonts/atkinson_mono.ttf"),
        32, &z.default_codepoints_ascii, 1,
    );
  Done via sed for the calls; another sed pass for the
  `Owned default-font cache. Populated by ...` doc
  comments.
- **19 UI examples that relied on the lazy auto-load
  fixed.**  Examples that submitted UI text but never
  called any font-load function were depending on the
  turn-330 footgun fix in `beginFrame`.  Now that's gone,
  they each got an explicit
  `loadFontFromTtfBytes(gpa, &s.font_cache, ...)` injected
  into their `initState`.  Sed-insert after the
  `s.* = .{ .ui_ctx = ui.UiContext.init(gpa) };` line for
  the 16 single-line cases; a Python multi-line regex for
  the 3 multi-line struct-init cases (ecs_boids,
  raytracer, recursive_hud).
- **`zimr.zig` exports updated.**  Out: `loadFontDefault`,
  `unloadFontDefault`, `atkinson_mono_ttf`.  In:
  `loadFontFromTtfBytes`, `unloadFontCache`.  Kept:
  `getFontDefault` (lookup, not load),
  `loadFontFromTtfData` (lower-level), and
  `default_codepoints_ascii`.
- **`@embedFile` package-path gotcha.**  First attempt put
  the TTF at `assets/fonts/` at the repo root; build
  errored with "embed of file outside package path."
  Fixed by moving to `examples/assets/fonts/` (inside the
  examples package).  Path string in all examples is
  `"assets/fonts/atkinson_mono.ttf"` — relative to the
  example file in `examples/`.
- **getting-started.md** updated.  Step 2 of "Anatomy of a
  zimr program" no longer claims `z.run` sets up a
  "default font"; instead points at
  `loadFontFromTtfBytes` as the explicit init step.

### Bundle size

- ui_dock_basic standalone: 471 KB (post-sweep, before
  re-adding font load to dock_basic itself) → 559 KB
  (after adding load to dock_basic).  Net vs. pre-sweep
  baseline (525 KB): +34 KB.  Pre-sweep wasm benefited
  from the lazy-load auto-pulling in font-baking only on
  demand — but the TTF was always shipped.  Post-sweep,
  every example that loads a font pulls in
  loadFontFromTtfData paths AND the TTF as part of its
  own embed; total per-example footprint similar to
  before for text-rendering examples, smaller for ones
  that don't load fonts at all.
- 87 examples currently load fonts.  Examples that DON'T
  render text (e.g. a pure 3D demo) no longer pay the
  font tax — they just don't call the loader.

### Why Option A, again

Locked turn 331 per Simon's "no default texture, mesh,
sound.  Font is the same.  Zimr value proposition is
extreme explicitness and verbosity."  The lazy-load
that snuck back in during turn 330 was a footgun fix
within the old "default font" model; removing the
default removes the need for the footgun guard.

### Build state

- 1555/1555 native tests pass.
- Smoke wasm bundle builds clean.
- ui_dock_basic standalone builds clean + renders text.
- Wasm size grew slightly (~34 KB net) but the model is
  honest: every byte in the bundle traces to a user-visible
  call site.

### Next

- **5.5l demos polish** — closes the docking arc.  Add a
  `ui_dock_persistence` demo (clear-localStorage button +
  save/load roundtrip visible to the user) and a Docking
  tab to `ui_full_showcase`.

---

**[Turn 335 — Font-default sweep (Option A): no more bundled
default font.  Zimr now treats fonts like textures, audio,
meshes: bring your own bytes.]**

### What lands

- **`loadFontDefault` deleted.**  Replaced by
  `loadFontFromTtfBytes(gpa, *FontCache, ttf_bytes,
  bake_size, codepoints, oversample)` — the explicit form
  the old default papered over.  Same idempotent +
  wasm-only behavior, but the user picks the TTF.
- **`unloadFontDefault` → `unloadFontCache`.**  Same code,
  honest name.
- **Embedded `atkinson_mono_ttf` constant deleted.**
  The 34 KB `@embedFile` line in `drawing.zig` is gone.
  Library code no longer ships any font bytes.  The TTF
  file moved to `examples/assets/fonts/atkinson_mono.ttf`
  so example code can embed it the same way users would
  embed their own asset.
- **Lazy auto-load in `beginFrame` reverted.**  `font_cache`
  parameter restored to `*const`.  The turn-330 footgun fix
  (auto-loading the default if the user forgot) is now
  obsolete — there's no default to auto-load.  The
  one-shot "text submitted without font loaded" warning
  (turn 330, `warned_text_no_font` flag in
  `drawing.zig`) stays, so apps that forget the load get
  a clear log message instead of silent text-less
  rendering.
- **All 87 examples swept.**  Three distinct call sites:
    try z.loadFontDefault(gpa, &font_cache);
    try z.loadFontDefault(gpa, &s.font_cache);
    try z.loadFontDefault(gpa, &state.font_cache);
  Each replaced by:
    try z.loadFontFromTtfBytes(
        gpa, &<cache>,
        @embedFile("assets/fonts/atkinson_mono.ttf"),
        32, &z.default_codepoints_ascii, 1,
    );
  Done via sed for the calls; another sed pass for the
  `Owned default-font cache. Populated by ...` doc
  comments.
- **19 UI examples that relied on the lazy auto-load
  fixed.**  Examples that submitted UI text but never
  called any font-load function were depending on the
  turn-330 footgun fix in `beginFrame`.  Now that's gone,
  they each got an explicit
  `loadFontFromTtfBytes(gpa, &s.font_cache, ...)` injected
  into their `initState`.  Sed-insert after the
  `s.* = .{ .ui_ctx = ui.UiContext.init(gpa) };` line for
  the 16 single-line cases; a Python multi-line regex for
  the 3 multi-line struct-init cases (ecs_boids,
  raytracer, recursive_hud).
- **`zimr.zig` exports updated.**  Out: `loadFontDefault`,
  `unloadFontDefault`, `atkinson_mono_ttf`.  In:
  `loadFontFromTtfBytes`, `unloadFontCache`.  Kept:
  `getFontDefault` (lookup, not load),
  `loadFontFromTtfData` (lower-level), and
  `default_codepoints_ascii`.
- **`@embedFile` package-path gotcha.**  First attempt put
  the TTF at `assets/fonts/` at the repo root; build
  errored with "embed of file outside package path."
  Fixed by moving to `examples/assets/fonts/` (inside the
  examples package).  Path string in all examples is
  `"assets/fonts/atkinson_mono.ttf"` — relative to the
  example file in `examples/`.
- **getting-started.md** updated.  Step 2 of "Anatomy of a
  zimr program" no longer claims `z.run` sets up a
  "default font"; instead points at
  `loadFontFromTtfBytes` as the explicit init step.

### Bundle size

- ui_dock_basic standalone: 471 KB (post-sweep, before
  re-adding font load to dock_basic itself) → 559 KB
  (after adding load to dock_basic).  Net vs. pre-sweep
  baseline (525 KB): +34 KB.  Pre-sweep wasm benefited
  from the lazy-load auto-pulling in font-baking only on
  demand — but the TTF was always shipped.  Post-sweep,
  every example that loads a font pulls in
  loadFontFromTtfData paths AND the TTF as part of its
  own embed; total per-example footprint similar to
  before for text-rendering examples, smaller for ones
  that don't load fonts at all.
- 87 examples currently load fonts.  Examples that DON'T
  render text (e.g. a pure 3D demo) no longer pay the
  font tax — they just don't call the loader.

### Why Option A, again

Locked turn 331 per Simon's "no default texture, mesh,
sound.  Font is the same.  Zimr value proposition is
extreme explicitness and verbosity."  The lazy-load
that snuck back in during turn 330 was a footgun fix
within the old "default font" model; removing the
default removes the need for the footgun guard.

### Build state

- 1555/1555 native tests pass.
- Smoke wasm bundle builds clean.
- ui_dock_basic standalone builds clean + renders text.
- Wasm size grew slightly (~34 KB net) but the model is
  honest: every byte in the bundle traces to a user-visible
  call site.

### Next

- **5.5l demos polish** — closes the docking arc.  Add a
  `ui_dock_persistence` demo (clear-localStorage button +
  save/load roundtrip visible to the user) and a Docking
  tab to `ui_full_showcase`.

---

---

**[Turn 334 — Docking 5.5k: tree shape persistence via
PersistedDockNode[] + tryRestoreDockTree.  Closes the
serialization gap; layouts now survive page reload.]**

### What lands

- **`PersistedDockNode`** schema, flat (no tagged union):
  `id`, `parent_id`, `flags` (u16 via `@bitCast` of the
  packed struct), discriminator `is_split`, then per-role
  fields.  Splits store `axis` (u8), `ratio` (f32),
  `child_a`/`child_b` (u32), and `size_ref_a`/`size_ref_b`
  (f32 with `-1` sentinel for `null`).  Leaves store
  `leaf_window_names: []const []const u8` (windows by
  NAME, not by hashed id, so window renames survive) and
  `leaf_selected_window_name`.
- **`PersistedState.dock_nodes: []const PersistedDockNode = &.{}`**
  — additive field; older payloads without this parse cleanly
  (default empty array).  Same forward-compat policy as the
  rest of the schema.
- **`serialize` extension.**  Walks `ctx.dock.nodes`, builds
  the array, resolves leaf `window_ids` → names via
  `ctx.windows.get`.  Frees the per-node `leaf_window_names`
  slice allocations after `std.zon.stringify.serialize`
  copies their string contents into the output buffer.
- **`apply` extension.**  Deep-copies the parsed
  `dock_nodes` into a freshly-allocated array on
  `ctx.pending_dock_tree` (window names duped via
  `gpa.dupe` so they outlive the zon-parse free).
- **`tryRestoreDockTree(gpa, ctx) bool`** — the consumer.
  Two-pass walk:
  1. Create every node by `id`, preserving the original
     u32 ids exactly.  Sets parent links + flags.
  2. Populate role data — for splits, wires axis/ratio/
     child_ids/size_ref; for leaves, resolves window
     names to live `Window` ids via `findWindowIdByName`
     (linear scan), populates `window_ids`, sets
     `dock_node_id` on each found window.
  Bumps `ctx.dock.next_node_id` past the max observed id
  so fresh splits post-restore don't reuse ids.  Degrades
  gracefully on dangling child refs or missing windows
  (skip the offending bit, keep the rest).
- **Hook in `dockSpaceImpl`.**  Before creating a fresh
  root, if `ctx.pending_dock_tree.len > 0`, call
  `tryRestoreDockTree`.  After restore, the dockspace
  root's id already has a populated DockNode (split
  + leaves + windows) so the fresh-root creation branch
  becomes unreachable.  The user's subsequent
  `dockBuilderSplitNode(root, ...)` finds root is no
  longer a leaf → returns `.a = 0, .b = 0` → the user's
  `if (split.a != 0)` skip kicks in.  No demo changes
  needed.
- **`freePendingDockTree(gpa, ctx)`** — release all
  allocations on the pending tree.  Called from
  `tryRestoreDockTree` after success, `apply` when
  re-staging, and `UiContext.deinit` for cleanup.

### How the persistence round-trip looks from user code

No example changes required.  Existing demos using the
"build layout once" idiom:

```zig
const root = u.dockSpace("MainDS", size, .{});
if (!s.layout_built and root != 0) {
    const split = u.dockBuilderSplitNode(root, .left, 0.3);
    if (split.a != 0 and split.b != 0) {
        u.dockBuilderDockWindow("Tools", split.a);
        ...
    }
    s.layout_built = true;
}
```

work as-is.  On first frame after page reload, the
`dockSpace` call drains `pending_dock_tree`, restoring
the saved layout.  The `dockBuilderSplitNode` sees root
is now a split (not a leaf) and returns 0/0; the inner
`if` skips.  `s.layout_built = true` runs regardless,
preventing repeat attempts on subsequent frames.

If the user WANTS to reset the layout (ignore
persistence), they can call
`dockBuilderRemoveNode(root)` before the build branch.

### Build state

- 1555/1555 native tests (was 1551; +4 new).
- Tests cover: serialize captures tree shape (string
  match on output), round-trip rebuilds tree with
  preserved size_ref + flags + window mapping,
  tryRestoreDockTree no-op without pending, leaf with
  ghost window degrades to empty leaf.
- Wasm clean.

### Plan / audit doc updates

- Plan 5.5k marked ✅ turn 334.
- Audit row 20 (Persistence): tree shape now covered;
  marked ✅ JUSTIFIED + DONE.

### Next

- **Font-default sweep (Option A).**  ~1-2 turns.
  Mechanical edit per example.
- **5.5l demos polish.**  Closes the docking arc.

---

**[Turn 333 — Docking 5.5j (drag-reorder): drag a tab within
its strip to reorder.  5.5j now COMPLETE.]**

### What lands

- **Strip-aware drag classification** replaces the turn-332
  omnidirectional 24-px threshold.  Inside `renderDockLeafTabBars`,
  for the iteration whose `tab_drag_id == ctx.active_id`:
  - Mouse Y inside strip range ± `REORDER_Y_SLACK` (4 px)
    → REORDER.  Compute target slot from
    `floor((mp.x - node.pos[0]) / tab_w)`, clamp, queue
    `pending_reorder` if different from current idx.
  - Mouse Y past `DETACH_Y_THRESHOLD` (16 px) outside strip
    → DETACH.  Same flow as turn 332.
  - Between strip edge and `DETACH_Y_THRESHOLD` → dead
    zone, no action.  Lets the user hover ambiguously
    without committing.
- **Reorder uses orderedRemove + insert** on the leaf's
  `window_ids` ArrayListUnmanaged.  Target index is the
  desired final position; since we remove first, then
  insert into the shorter list, no off-by-one bookkeeping
  is needed.  Mutation deferred (after the loop) to avoid
  invalidating slices.
- **Bumps the leaf's generation** so any caller caching
  derived state (future: tab-bar layout cache, persistence)
  invalidates correctly.
- **Why no separate threshold for reorder?**  Reorder is
  cheap and trivially un-doable (drag back).  Requiring a
  minimum motion adds latency without preventing
  accidents.  Detach gets the dead zone because it's a
  loud action.

### Earlier (turn 332) behavior, replaced

The 24-px circle counted purely horizontal motion within
the strip as detach.  Wrong: horizontal IS reorder, vertical
IS detach.  Splitting by axis matches imgui and gives the
user predictable affordance.

### 5.5j complete

The three sub-pieces (close button, drag-detach, drag-
reorder) all share the same tab-loop deferred-mutate
pattern: `pending_close: ?Id`, `pending_detach: ?Id`,
`pending_reorder: ?struct { wid, target_idx }`, drained
in that order after the loop.  Slice invalidation safety
+ uniform structure.

### Build state

- 1551/1551 native tests (was 1547; +4 new for
  reorder-swap, reorder-no-op-same-slot, detach-via-Y,
  dead-zone-no-action).
- Test setup needed `ctx.current_draw_list = &ctx.foreground_dl`
  before calling `renderDockLeafTabBars` directly — the
  function draws rects.  Production callsites
  (`flushDockTabsToForeground`) set this; tests now do too.
- Wasm clean.

### Next

- **5.5k persistence** — extend `.zon` schema with
  `PersistedDockNode[]`.  Round-trip dock tree state through
  localStorage so layouts survive page reload.  ~1-2 turns.
- After 5.5k: font-default sweep (Option A).
- After sweep: 5.5l demos polish.  Closes the docking arc.

---

**[Turn 332 — Docking 5.5j (drag-detach): tear a docked tab
out into a floating window by dragging past 24-px threshold.]**

### What lands

- **`detachAndStartDrag(ctx, window_id)` helper.**  Sibling
  of `undockSingleWindow`.  Differs in one key way: discards
  the `pre_dock_pos` stash so the window doesn't pop back to
  its old floating position — it stays where the cursor is,
  ready to be dragged elsewhere.  Pre-dock SIZE is preserved
  as the new floating size; leaf size is the fallback when
  no stash exists.  Positions `w.pos` so the title bar lands
  with the cursor at horizontal center + vertical middle of
  the title strip.
- **Per-tab `tab_drag_id`** via `hashStr(window_id,
  "__tab_drag")`.  Stable across frames, unique per window.
- **Press-on-label state machine.**  Mouse-down on the tab
  label (rising edge, close button didn't consume) →
  `tab_drag_id` claims `active_id`, stashes `mp` in
  `active_id_press_screen`, selects the tab immediately
  (imgui-matching).  Threshold check runs each frame while
  the id is owned (down OR just-released) — a fast drag-
  and-release that ALL happens in one frame's input still
  detaches.  Once threshold crossed, `pending_detach = wid`;
  the deferred drain after the tab loop calls into
  `detachAndStartDrag`.
- **24-px squared threshold** (`DETACH_THRESHOLD_SQ = 24 *
  24`).  Larger than imgui's 6-px `MouseDragThreshold`
  because tab labels are smaller hit targets and detaching
  is a louder action than starting a within-window drag.
  ~1 tab width on phone-scale UI.
- **Handoff to title-bar drag.**  After detach,
  `ctx.active_id = 0` and `ctx.dock.dragging_window =
  window_id`.  Next frame's user submission renders the
  newly-floating window with the title bar where we
  positioned it; the existing title-bar drag handler
  (`chrome.zig`) sees `mp_in_title and md and active_id ==
  0` and claims a fresh `drag_id`.  Continues seamlessly
  into the 5.5d.iv drop-zone overlay.

### Edge cases handled

- Single-window leaf: detach empties the leaf;
  `undockWindow`'s `collapseEmptyLeaf` removes the parent
  split.
- Root leaf with no parent: stays as an empty leaf (no
  collapse possible).  Dockspace renders with no tabs.
- Floating window: `detachAndStartDrag` no-ops if
  `dock_node_id == null`.
- Unknown window id: silent no-op.
- Threshold crossed exactly on release: still detaches (the
  threshold check runs in the same `active_id == tab_drag_id`
  block as the release-clears-active_id branch).

### What's STILL pending in 5.5j

- **Drag-reorder.**  Drag a tab within its strip to
  re-order siblings.  Same threshold pattern but the
  motion stays within the tab strip's Y range AND
  re-orders `window_ids` instead of detaching.  Plausibly
  the smallest remaining 5.5j piece.

### Build state

- 1547/1547 native tests (was 1544; +3 new for
  detachAndStartDrag round-trip / no-stash fallback /
  no-op-when-floating).
- Wasm clean.

### Next

- Drag-reorder.  Then 5.5j wrapped.  Then 5.5k persistence.
- Font-default sweep slotted after 5.5k.

---

**[Turn 331 — Docking 5.5j (partial): tab close button.  +
font-default decision locked: Option A (full removal), no
named asset.  + Phone demo iteration deferred — Simon will
test on PC.]**

### What lands

- **Close × on every docked tab.**  Right edge of each tab,
  proportional to the tab bar height (so it scales with
  `style.font_size`).  Idle = dim diagonals; hover = red
  background + bright × + thicker stroke.  Gated by the
  `no_close_button` DockNodeFlag — set the flag and the ×
  disappears entirely (the leaf becomes uncloseable).
- **`undockSingleWindow(ctx, wid)` helper.**  Tab close calls
  this.  Restores `pre_dock_pos/size`, clears
  `dock_node_id`, then delegates to
  `ui_dock_mod.undockWindow` for the list removal + empty-
  leaf collapse.  Mirrors the per-window restore that
  `clearDockIdsInSubtree` does for whole-subtree teardown.
- **Deferred close pattern.**  Click on × stages
  `pending_close: ?Id`; the actual mutation runs AFTER the
  tab-strip iteration completes (mutating `window_ids` mid-
  loop would invalidate the slice).  At most one close per
  frame, so a single slot is plenty.
- **Hit-test ordering.**  The close button claims the click
  first.  Tab-select runs only if the close button didn't
  consume.  Avoids the "I tried to close but it just
  selected" footgun.
- **Phone demo tweak.**  `examples/ui_dock_basic.zig` now
  uses `.scale = .responsive` (1:1 with CSS pixels, no
  stretching) and `style.font_size = 16` (readable on both
  PC and phone without being huge).  All sizes derived from
  `f.window.screen_width/height` so it fills the viewport.
  Earlier 24-px / 3× attempt rolled back per Simon's
  feedback ("stretching breaks position math, hard to test
  on phone").

### Font-default decision: locked Option A

Quoting Simon: *"There is no default texture, mesh, sound.
Font is the same.  Zimr value proposition is extreme
explicitness and verbosity."*  Plan note
`src/notes/font-default-plan.md` updated — Option B (keep
`loadFontDefault` as opt-in) is REJECTED.  Option A is the
chosen path: delete `loadFontDefault`, delete the embedded
TTF, every example does its own `@embedFile` + `loadFontFromTtfData`.
Sweep slotted after 5.5k persistence, before 5.5l demos
polish.

### What's STILL pending in 5.5j

- **Drag-detach.**  Tear a docked tab out into a floating
  window by grabbing its label and dragging beyond a
  threshold.  Likely shares the same threshold + state
  machine as the title-bar drag-to-dock from 5.5d.iv.
- **Drag-reorder.**  Drag a tab within its strip to
  re-order siblings.

These are the bigger pieces.  Tab close was the smallest
chunk and worth shipping alone.

### Build state

- 1544/1544 native tests (was 1541; +3 new for
  undockSingleWindow round-trip / no-op-when-floating /
  unknown-id).
- Wasm clean.

### Next

- Continue 5.5j with drag-detach.  After that, drag-
  reorder.  Then 5.5k persistence, font-default sweep,
  5.5l polish.

---

**[Turn 330 — Font footgun fix + warning + discussion of
removing the default-font concept entirely.]**

### Context

Simon shipped turn 329 to phone — the docking demo rendered
all the layout (dockspace outlines, splitter seam, tab strips,
floating window) but NO text anywhere.  Title bars empty.
Button shapes collapsed to padding-width (their label measured
0 width).  Reproducible on host via the existing screenshot
test harness — host PNGs have the same "no text" output, just
never noticed because I was eyeballing shapes.

### What was wrong

UI text rendering requires a wasm-only `loadFontDefault` call
that bakes the embedded Atkinson TTF into a GPU atlas.  My
recent examples (smoke + dock_basic) never called it.  Host
screenshot tests CAN'T render text — the wasm-only loader is a
compile-time no-op on native; not a regression, latent
limitation.

### What landed

1. **Lazy-load in `UiContext.beginFrame`.**  Auto-calls
   `loadFontDefault` if the FontCache isn't loaded.
   Idempotent, wasm-only, free on native.  Eliminates the
   silent-failure mode.  Signature widened: `font_cache:
   *const drawing.text.FontCache` → `*drawing.text.FontCache`.
   All 48 existing callsites already passed a mutable pointer
   coerced to const, so no caller changes needed.

2. **Footgun-detector warning in `drawing.text.draw`.**  A
   module-level `warned_text_no_font` flag fires once per
   process when a non-empty string is submitted with
   `texture.id == 0`.  Goes through `std.log.warn` → browser
   devtools console on wasm.  Wasn't there before this turn —
   if it had been, I'd have seen the diagnostic in the FIRST
   phone test rather than after several round-trips.

3. **Font-default plan addendum.**  Simon argued the default-
   font concept is wrong: implicit-default-bad, every other
   zimr resource requires explicit loading, removing it makes
   the core leaner.  I lean toward agreement.  Plan addendum
   in `src/notes/font-default-plan.md` weighs both sides and
   commits to **Option B**: keep `loadFontDefault` as an
   opt-in convenience, but REVERT the lazy-load in
   `beginFrame` and require explicit calls in every example.
   Estimated cost: 1 turn.  Slotted after 5.5k persistence,
   before 5.5l demos polish.

### Trade

Bundle grew ~80 KB (smoke 434 → 515 KB, dock 444 → 525 KB)
because the embedded TTF is no longer DCE-able (always live
via the lazy-load).  Reverts when Option B sweep happens.

### Build state

- 1541/1541 native tests pass.
- Wasm clean.  Smoke + docking demo both render text on phone
  (confirmed by Simon).

### What I'm NOT doing this turn

- Removing the default font concept.  Discussed + planned, not
  executed; would slow docking work.
- Native PNG text rendering.  Separate concern; documented as
  deferred in the font-default plan addendum.

### Next

Returning to docking arc.  Only 5.5j (tab close + drag-detach
+ drag-reorder) and 5.5k (persistence serialization) +
5.5l (demos polish) remain.  Starting 5.5j with the smallest
piece: tab close buttons.

---

## Turn 339 — AST-based linter `tools/zimrlint.zig`

Built the linter from scratch this turn (carrying state from
turns 337-338 plans).  End state:

- **`tools/zimrlint.zig`** ~1200 LOC, self-lint clean.  Single
  binary, host target, ReleaseFast.  10 checks live:
  `untyped-local`, `module-var`, `array-mult`, `line-length`,
  `c-types`, `fn-args-multiline`, `branch-braces`, `ex-variant`,
  `clamp-pattern`, `floor-pattern`.
- **`build.zig`** — added `zig build lint` step.  Defaults to
  scanning every `src/*.zig`; takes per-file args via `--`.
  Flags: `--quiet`, `--only=tag1,tag2`, `--skip=tag1`.
- **`src/notes/lint-zimr-tutorial.md`** — long-form walkthrough
  of architecture, walker design, every check, AST API
  gotchas, debugging guide, how to add a new check.

### Walker design (final)

Three pieces of state ride with each `walkNode(ctx, node,
pos, fn_depth)`:

- **`pos`** — `.container`, `.statement`, `.expression`.
  Module-var only fires at container; branch-braces only at
  statement; expression sub-trees descend with `.expression` so
  array-mult/c-types fire inside init expressions but
  branch-braces stays silent for `const x = if (a) b else c;`.
- **`fn_depth`** — module-var only fires when `fn_depth == 0`.
  Enables Simon's "we allow local static" carve-out: a
  `const S = struct { var x: bool = false; };` inside a
  function body has the inner `var` at container-pos but
  `fn_depth ≥ 1`, so module-var passes.
- **`ctx`** — path, source, AST, issues list, enabled-check
  filters.

Switch arms are explicitly walked (turn 339 fix) — without
this, statements inside switch cases never get visited.

### Branch-braces final ruling

Per Simon's turn-339 directive: `if (cond) return x;` flags
(rule 3 strict).  Reason: breakpoints.  Setting a breakpoint
on `if (cond) return x;` stops *before* the cond is
evaluated; the debugger can't step through the return.
Rewriting with braces puts the breakpoint on the return line
itself.  Same logic for `break` / `continue`.

The only braceless body still accepted: `for (xs) |x| switch
(x) { ... }` — the switch carries its own braces, so a
breakpoint on an arm still lands correctly.

### Allow-list (rule 9)

Module-var has four ways out:
1. **C-ABI bridge files** (path-suffix): `zimr.zig`,
   `runtime_assembly.zig`, `runtime.zig`.
2. **`warned_` prefix** — established one-shot warn-flag idiom
   (`warned_text_no_font` from turn 330).
3. **Function-local statics** — `const S = struct { var x =
   ...; };` inside a fn.  Detected via fn_depth tracking,
   matches Simon's turn-339 "we allow local static."
4. Var is actually a `const`.

Prefer #3 for new code.  #1-2 are back-compat with established
zimr patterns.

### Full src/ scan results (warm, ~4.3s, 27 files)

```
3799 untyped-local
 742 branch-braces
 305 line-length
  40 fn-args-multiline
  32 clamp-pattern
  21 array-mult
  20 ex-variant
   7 c-types
   4 floor-pattern
   1 module-var
─────
4971 issues
```

Top files: drawing.zig (1050), ui.zig (1008), math.zig (784),
codecs.zig (651), runtime.zig (296).

All 4971 are real hits per the rules as written.  Triage and
cleanup waves are downstream of this turn.

### Performance

- Single file (`src/ui.zig` ~25k lines): ~860ms warm.
- Full `src/` scan: ~4.3s warm, ~1.85s cold (release binary).
- Build-step overhead: ~3s.
- `zig run` direct: 15-25s cold (recompiles every invocation).

Use `zig build lint` to keep the binary cached.

### Build state

- 1555/1555 native tests pass.
- Linter self-lint: 0 issues.
- Wasm clean.

### Next

The linter is in shape to drive cleanup waves.  Suggested
order: triage `module-var` (1 hit, decide if `entities.zig`'s
`counter` deserves an exception or rework), then file-by-file
on the high-leverage hits.  Or roll into imgui-plan-v6 phase
B (foundation dev tools) where the linter is one of the
prereqs.
