# CHANGELOG — turns 310-319

Per-turn journal for turns 310-319.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 320
opens, this file is frozen and a fresh `changelog320-329.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog300-309.md`, `changelog290-299.md`, `changelog280-289.md`,
`changelog270-279.md`, `changelog260-269.md`, `changelog250-259.md`,
`changelog240-249.md`, `changelog230-239.md`, `changelog220-229.md`,
`changelog210-219.md`, `changelog200-209.md`, `changelog093-199.md`,
`changelog001-092.md`).

---

## [Unreleased]

**[Turn 319 — Step 5.5a Docking Foundation + 5.5b dockSpace
widget: data layer, tree mutation primitives, layout, request
processing, AND the public `Ui.dockSpace(...)` entry point with
its placeholder rendering.  The docking arc has hit shippable
ground.]**

### What lands

New module `src/ui_dock.zig` (~1040 LOC including 20 tests).
Pure CPU / pure data — no UI integration yet (that's 5.5b
onwards).  Establishes the surface the widget layer will
build on:

**Types**:
- `SplitAxis` — horizontal / vertical.
- `Dir` — center / top / right / bottom / left.  With helpers
  `isEdge`, `splitAxis`, `isFirstChild`.
- `DockNode` — either a SPLIT (with `SplitData`: axis + ratio +
  two child IDs) or a LEAF (with `LeafData`: window-id list +
  selected-window-id).  Exactly one role; encoded as two
  optional fields where exactly one is non-null.  Carries
  `pos`/`size` (refreshed each frame by `layoutSubtree`) and
  a `generation` counter bumped on every structural mutation.
- `DockRequest` — tagged union of `dock_as_tab`,
  `dock_as_split`, `undock`, `split` — queued by drag-drop,
  drained by `processRequests` at a well-defined point in the
  frame.
- `DockContext` — `AutoHashMapUnmanaged(Id, *DockNode)` pool +
  `dockspaces_this_frame` list + `pending_requests` queue +
  `dragging_window` slot + `next_node_id` counter.  One per
  UiContext.
- `NodeRole` — tagged union used to spell out the role at
  creation (`.leaf` vs `.split`).

**Operations**:
- `createNode` / `createLeaf` — allocate a node, register in
  the pool, return its `Id`.
- `dockWindowAsTab(ctx, gpa, leaf_id, window_id)` — append to
  the leaf's tab list, promote to selected.  Idempotent on
  duplicates (re-add just promotes selection).
- `undockWindow(ctx, gpa, window_id)` — remove from whatever
  leaf holds it; pick a new selection; collapse parent split
  if the leaf becomes empty (the sibling node absorbs the
  parent's identity, preserving outstanding `parent_id`
  references).
- `splitNode(ctx, gpa, target_id, dir, ratio)` — turn a leaf
  into a split with two new child leaves.  Existing windows
  move to the child OPPOSITE the direction (drag-right →
  existing stays left).  Returns `{ a, b }` for the new child
  IDs.  Ratio clamps to `[MIN_RATIO, 1 - MIN_RATIO]`.  Rejects
  `.center` with `error.InvalidTarget`.
- `removeNode(ctx, gpa, node_id)` — recursively free a subtree.
  Parent's surviving sibling absorbs the parent if applicable.
- `processRequests(ctx, gpa)` — drain `pending_requests` in
  FIFO order.  Snapshots the queue before iterating so requests
  enqueued during processing wait until next frame.
- `layoutSubtree(ctx, root_id, pos, size)` — recursively
  compute every node's rect from the root's rect + cumulative
  split ratios.  Called once per dockspace per frame.
- `nodeRect(ctx, id)` — read-back of a node's last-laid-out
  rect.  Zero-sized rect for unknown ids.
- `findLeafFor(ctx, window_id)` — locate the leaf containing
  a window.  Linear scan; fine for the expected node counts.

**Invariants enforced**:
- A node is exactly one of leaf/split, never both, never neither.
- A SPLIT has two child IDs both present in the pool, with
  `child.parent_id == split.id`.
- An empty leaf is allowed at the root of a dockspace; an
  empty leaf with a parent SPLIT collapses (sibling absorbs).
- An empty SPLIT cannot exist (it'd have collapsed first).
- Ratios clamp to `[0.05, 0.95]` so neither side disappears.

### Tests

1503/1503 native (1483 baseline + 20 new dock tests covering:
roundtrip create/lookup, tab dock + idempotent dup, undock with
selection-promotion, undock empty root preserved, splitNode
roles + ratio clamp + center-rejection, empty-leaf collapse,
layout single-leaf + horizontal split + vertical split + nested
splits, processRequests for tab + split, removeNode subtree
free, findLeafFor, Dir semantics, generation bump).

108/108 wasm smoke (no regression; the new module isn't yet
imported from ui.zig so wasm side is untouched).

### 5.5b — `dockSpace` widget

- `DockContext` wired onto `UiContext.dock` (default-init to
  empty; apps not using docking pay zero overhead — empty maps,
  no per-frame work).
- `UiContext.beginFrameRaw` clears `dock.dockspaces_this_frame`
  at frame start.
- `UiContext.endFrame` calls `ui_dock.processRequests(...)` to
  drain any pending dock operations BEFORE the auto-save
  snapshot, so persisted layouts reflect post-drop state.
- `UiContext.deinit` releases the dock pool + bookkeeping lists.

Public API:
- `pub fn Ui.dockSpace(str_id, size, opts) → ui_dock.Id`.  Looks
  up (or creates) a root `DockNode` keyed by `widgetId(ctx, w,
  str_id)`.  Reserves `size` worth of layout space; advances the
  parent's cursor.  Returns the stable node id for use with
  `dockBuilder*` (5.5c+).
- `pub const DockSpaceOpts = struct { bg_color: ?Color = null }`
  — sized for forward-compat; will grow `flags: DockNodeFlags`
  with imgui-parity toggles.

Placeholder rendering (today): the dockspace draws as a faint
filled rect + 1px outline so a fresh dockspace is visually
distinct from empty canvas.  5.5c replaces this with real
tab-bar + content rendering as windows route through
`beginDockedWindow`.

Demo `examples/ui_dock_basic.zig` (~50 LOC): a single host
window with a dockspace filling most of its content area.
Auto-discovered by the smoke harness; passes 2746 GL calls.

Tests + smoke: 1503/1503 native (same — no new dock-specific
tests this sub-step; the widget threads through existing tested
primitives).  **109/109 wasm smoke** (108 + new ui_dock_basic).
Full wasm build green.  Standalone HTML in outputs.

### What's NEXT (still to come this arc)

- **5.5b**: `dockSpace(str_id, size, opts) → Id` widget.
  Reserves canvas space, creates/registers a root dock node,
  pushes to `dockspaces_this_frame`.  Renders an empty
  container until windows dock in.
- **5.5c**: `Window.dock_node_id: ?Id` field + `dockBuilderDock
  Window` API.  `window()` opens with `beginDockedWindow`
  path when a node is assigned: pos/size from leaf rect,
  title bar replaced by tab in the leaf's tab bar, same draw
  list path as floating.
- **5.5d**: Splits actually visible — leaves render with
  tab bars, splits get a draggable splitter.
  `dockBuilderSplitNode` API.
- **5.5e**: Drag-drop dock targets — detect title-bar drag
  exceeding detach threshold, set `dragging_window`, render
  5-zone overlay over each leaf, enqueue `DockRequest` on
  release.
- **5.5f**: Splitter drag updates `split.ratio`.
- **5.5g**: Dock-tree persistence via Step 5.1 infrastructure
  (extend `PersistedState` with `DockNodeSettings[]`).
- **5.5h**: Demos (`ui_dock_basic`, `ui_dock_persistence`),
  `ui_full_showcase` gets a Docking tab.

### Plan v5 progress

3.5a ✅ 3.5b ✅ 3.6 ✅ 3.7 ✅ 5.1 ✅ **5.5a ✅** → 5.5b (widget API) → … → 5.5h (demos).

---

**[Turn 318 — Step 5.1 Persistence: .zon serialize + localStorage
transport + auto-load/save + TabBar selection.  Final pre-docking
prerequisite cleared.  Three sub-steps shipped in one turn: 5.1a
(Zig serialization + apply), 5.1b (JS extern transport + lifecycle
hooks), 5.1c (TabBar selection round-trip).**

### What lands

**5.1a — Zig serialization (pure CPU, host-testable):**
- New module `src/ui_persistence.zig` (~960 LOC including 16 tests).
- `PersistedWindow` schema (name, pos, size, scroll_y, user_resized,
  tab_bars) with `CURRENT_VERSION = 1`.  `PersistedTabBar` carries
  (str_id, selected_tab_label).
- `serialize(gpa, ctx) -> ![]u8`: walks `ctx.windows`, filters
  stale (>60 frames old) + children, collects tab-bar selections
  per window via `collectTabBarsFor`, zon-stringifies through
  `std.zon.stringify.serialize`.
- `apply(gpa, ctx, text)`: parses via `std.zon.parse.fromSliceAlloc`
  (slice fields require the alloc form), version-gates payload,
  deep-copies names into `ctx.pending_persistence`, stages bar
  selections into `ctx.pending_tab_bar_selections` keyed by
  compound `"<window>\x00<str_id>"`.
- `takeFor(ctx, title)` / `takeTabBarSelection(ctx, window, str_id)`:
  pop pending entries on first openWindow / openTabBar call.
- `clearPending(ctx)`: deinit-time cleanup of both staging maps.
- `findOrCreateWindow` grafts persisted pos/size/scroll ahead of
  `opts.initial_*` but behind `setNextWindow*` overrides.

**5.1b — JS extern transport + lifecycle wiring:**
- `src/web.zig` — three `extern "dom"` declarations
  (`js_persistence_save/size/read`) + Zig wrappers
  (`persistence_save`, `persistence_size`, `persistence_read`,
  `persistence_load(gpa, key) -> ?[]u8` convenience).  Two-call
  read protocol (size first, then read with sized buffer).
- `src/web/zimr.ts` — handler functions using `localStorage`
  synchronously with `"zimr_"` prefix namespace.  Status codes
  for `QuotaExceededError` (1), missing localStorage (2/-2),
  truncated buffers (-3).
- `webtests/smoke.ts` — in-memory `Map<string,string>` stubs;
  smoke runs persistence-touching code without real localStorage.
- `tryAutoLoad(ctx)` + `tryAutoSave(ctx)` helpers behind
  `comptime is_wasm` gate.  Host builds skip them entirely; the
  `web.zig` externs are never referenced on host.  Save cadence:
  every 60 frames (~1s at 60fps).
- `beginFrameRaw` calls `tryAutoLoad` once on first frame;
  `endFrame` calls `tryAutoSave` every frame (the helper itself
  gates on cadence + key presence).
- One-line opt-in:
  `ctx.persistence_key = "my_demo";` in app init.

**5.1c — TabBar selection round-trip:**
- `TabBarState` gains `str_id_buf` + `parent_window_name_buf`
  (32-byte inline storage each) populated once at openTabBar
  first-creation — bars now carry stable human-readable
  identifiers, not just hashed Ids.
- Restore path in `openTabBar`: peek pending selection, hash
  the persisted label under the bar's id, stash on
  `state.selected_id`.  Standard `beginTabItem` equality check
  routes the right tab as active on the first frame.
- Fallback in `closeTabBar`: if `selected_id` is non-zero but
  no submitted tab matches (caller renamed/removed the tab
  between sessions), reset to 0 so first-tab-auto-select kicks
  in next frame.

### Tests

- 1483/1483 native (1478 baseline + 5 new tab-bar persistence
  tests covering stage/take, missing bar, empty label, serialize,
  full roundtrip).
- 108/108 wasm smoke (107 baseline + new `ui_persistence` demo
  picked up by the readdir-based smoke harness).
- Full wasm build green (`zig build install`).
- Standalone HTML built for `rlsw_side_by_side` (368 KB
  self-contained) — open in browser, side-by-side rlgl/rlsw
  with UI panel rendering.

### Bug found and fixed during 5.1c

`collectTabBarsFor` originally iterated tabs by value (`for ... |t|`).
`TabState` contains an inline `[TAB_LABEL_CAP]u8` `label_buf`,
so the for-loop copy put the buffer on the loop's stack frame —
slicing `t.label_buf[..]` aliased that stack copy, which died
when the iteration ended.  Serialize then read dangling memory:
the test caught it as `"Selected"` becoming `"\x00elected"`
(first byte clobbered).  Fixed by switching to `for ... |*t|`
to iterate by pointer.  Pattern noted in the code comment so
future contributors know to watch for it.

### Files modified

- `src/ui_persistence.zig` — NEW (~960 LOC, 16 tests).
- `src/ui.zig` — `TabBarState` extended with name fields;
  `UiContext` gains `pending_persistence` +
  `pending_tab_bar_selections` + `persistence_key`; `openTabBar`
  populates name fields + restores selection; `closeTabBar`
  no-match fallback; `beginFrameRaw` auto-load hook; `endFrame`
  auto-save hook; `deinit` releases the new maps; persistence
  module imported as `ui_persistence_mod`.
- `src/web.zig` — three persistence externs + Zig wrappers.
- `src/web/zimr.ts` — three handler functions.
- `webtests/smoke.ts` — in-memory persistence stubs.
- `src/zimr.zig` — `pub const ui_persistence = ...` re-export.
- `src/tests.zig` — `_ = @import("ui_persistence.zig")` registration.
- `examples/ui_persistence.zig` — NEW demo (~100 LOC), two
  windows, one-line opt-in.
- `build.zig` — `"ui_persistence"` registered in the demos array.

### Plan v5 progress

3.5a ✅ 3.5b ✅ 3.6 ✅ 3.7 ✅ **5.1 ✅** → **Step 5.5 DOCKING** (the milestone, 8-15 turns).

All pre-docking prerequisites are now closed.  Docking begins next.

---

**[Turn 317 — UI-via-rlsw renderer migration + PNG screenshot
tooling + Step 3.6 tab-overlap bug fix] Drawing pipeline becomes
renderer-polymorphic: `drawing.shapes` / `drawing.text` /
`drawing.textures` / `DrawList.render` all take `gl: anytype`
satisfied by both `*rlgl.GlState` and `*rlsw.Context` directly.
Adds a working PNG screenshot pipeline for host-side UI debugging;
fixes the tab-overlap layout bug Simon spotted in
`ui_tabbar_tour`.**

### What lands

- **Method receivers on `rlgl.GlState`** (~200 lines in `src/rlgl.zig`).
  1-line forwards to existing `rlX` free functions for the full
  immediate-mode + matrix-stack surface: `begin`, `end`, `vertex2f`,
  `vertex3f`, `color4ub`, `color3f`, `texCoord2f`, `normal3f`,
  `setTexture`, `matrixMode`, `loadIdentity`, `pushMatrix`,
  `popMatrix`, `translate`, `rotate`, `scale`, `multMatrix`,
  `ortho`, `frustum`, `getMatrixModelview`/`Projection`/`Transform`,
  `enable`, `disable`, `scissor`, `clearColor`, `clear`.  rlsw's
  enum types (`DrawMode`, `MatrixMode`, `Capability`, `ClearMask`)
  serve as the canonical types; rlgl methods translate via
  `drawModeToRl`/`matrixModeToRl` helpers.  No cycle (rlsw doesn't
  import rlgl).

- **`drawing.shapes` + `drawing.text` + `drawing.textures` migrated**
  from `gl: *rlgl.GlState` → `gl: anytype` (~720 lines mechanically
  changed via Python regex sweep, plus manual fixups for nested
  `gl_inner` closures).  Every `rlgl.rlBegin(gl, RL_QUADS)` becomes
  `gl.begin(.quads)`; every `rlgl.rlVertex2f(gl, x, y)` becomes
  `gl.vertex2f(x, y)`.  Zero behavioral change on the rlgl path —
  methods are 1-line forwards — but the same source now drives
  rlsw too.

- **`drawing.shaders.beginScissorMode` / `endScissorMode`
  migrated to `gl: anytype`** with comptime `@hasField(Inner,
  "userTextureId")` gate so the rlgl-only debug-counter +
  batch-flush bookkeeping fires on rlgl and skips on rlsw.

- **`DrawList.render` migrated to `gl: anytype`.**  The whole point
  of the refactor: a recorded UI frame can now replay against
  either renderer without changing any caller.

- **`ui_screenshot.zig` rewritten** (~399→172 lines) to use the
  real `DrawList.render(&sw, ...)` instead of a duplicated
  rasterizer.  Pass-1 pre-emits text bboxes (rendering rlsw text
  cmds is a no-op until a font atlas is uploaded as an rlsw
  texture); pass-2 runs the real DrawList.render for shapes.
  Public surface: `renderToBytes(gpa, ctx, w, h) -> []u8` and
  `renderToPng(gpa, ctx, w, h, out_path)`.

- **`rlsw.zig` compat shims**: `setTexture(self, id: u32)` (non-zero
  ids treated as unbind — placeholder behavior for ui glyph atlas
  IDs) and `normal3f(self, x, y, z)` (no-op, rlsw is unlit) so the
  trait surface matches.

- **`examples/rlsw_side_by_side.zig` now renders a UI panel** on
  both sides via `drawUiPanel(gl: anytype, ...)`.  Proves the
  polymorphic path end-to-end through the demo (not just tests).

- **Step 3.6 tab-overlap bug fixed.**  Moved `advanceLayout(...)`
  from `closeTabBar` to `openTabBar` after computing the bar rect.
  Old behavior: active tab's content submitted at same y as the
  tab strip, overlapping it.  New behavior: strip lays out at
  `at`, cursor advances to the row below, body submits below the
  strip.  Bug + fix both visible in
  `/mnt/user-data/outputs/ui_tabbar_bug-turn317.png`.

- **PNG screenshot tooling working.**  `std.Io.Threaded.init(gpa,
  .{})` → `.io()` → `Dir.cwd().createFile(io, path, .{})` →
  `file.writeStreamingAll(io, bytes)` is the working Zig 0.16
  pattern.  Test `src/tests/ui_screenshot_test.zig` writes
  `/mnt/user-data/outputs/ui_tabbar_bug-turn317.png` each run;
  silent skip on environments without `/mnt`.

- **New trait tests**: `*rlgl.GlState` and `*rlsw.Context` both
  satisfy `assertIsGlContext` directly (no adapter wrap needed).
  Adapter tests retained for back-compat.  `setBlendMode` dropped
  from the required-methods list — it's adapter-only convenience;
  the polymorphic path uses `enable(.blend)` + `blendFunc`.

### Deliverables shipped

- **`src/notes/renderer-adapter-tutorial.md`** (19 KB) —
  beginner-friendly walkthrough of the `gl: anytype` strategy.
  Three worked examples (drawing on both, UI screenshot test,
  `rlsw_side_by_side` A/B), how monomorphisation works under the
  hood, limitations (textures don't bridge), common patterns,
  cheatsheet + README copy suggestions, FAQ.

- **`src/notes/io-investigation.md`** (9.5 KB) — verdict on
  switching to `pub fn main(init: std.process.Init) !void`.
  Confirms `std.process.Init` exists in Zig 0.16 (the old Phase 12
  note saying it didn't is stale).  Recommends NOT shaving the
  yak now: wasm games don't benefit from `io`, host paths already
  work via local `Threaded.init`, and the migration would touch
  148+ examples for orthogonal value.  Files `tools-2`
  (`z.host.writeFile` helper, ~1 turn) and `entry-modernize`
  (full migration, deferred to v1.0).

- **`src/notes/juicy-main-plan.md`** (9.4 KB) — 6-step plan for
  the entry-point modernization (JM-1 investigation, JM-2
  `z.host` helpers separable, JM-3 POC `basic.zig`, JM-4 `z.run`
  lift, JM-5 mass migrate, JM-6 cleanup).  Phase JM added to
  plan v5 sequence, scheduled IMMEDIATELY after the imgui arc
  completes per Simon: "We will do it even if it does not really
  matter."

### Tests

- 1467/1467 native tests (1465 baseline + 2 new trait tests).
- 107/107 wasm smoke (unchanged — DrawList.render signature change
  is back-compat through the new methods on `GlState`).

### Files modified

- `src/rlgl.zig` — `rlsw` import + ~200 LOC of method receivers
  on `GlState` + 2 helper enum translators.
- `src/drawing.zig` — ~720 LOC mechanical migration to `gl: anytype`
  + method-style calls across `shapes`/`text`/`textures` submodules;
  `shaders.beginScissorMode`/`endScissorMode` made polymorphic
  with comptime gate.
- `src/ui.zig` — `DrawList.render` signature change; tab-overlap
  bug fix (`advanceLayout` move).
- `src/rlsw.zig` — `setTexture(u32)` + `normal3f` no-op shims.
- `src/ui_screenshot.zig` — rewrite (~399→172 LOC) on real
  DrawList.render path.
- `src/tests/ui_screenshot_test.zig` — new test that writes PNG
  to `/mnt/user-data/outputs/`.
- `src/zimr.zig` — `pub const ui_screenshot` re-export.
- `src/tests.zig` — register the new test file.
- `src/renderer_trait.zig` — 2 new trait tests for direct types;
  `setBlendMode` removed from required-methods list (with rationale).
- `examples/rlsw_side_by_side.zig` — `drawUiPanel(gl: anytype, ...)`
  rendered on both rlgl and rlsw sides.
- `src/notes/imgui-plan-v5.md` — Phase JM added immediately after
  imgui arc.
- `src/notes/{juicy-main-plan,renderer-adapter-tutorial,
  io-investigation}.md` — new.

### Filed for follow-up

- **tools-2**: `z.host.writeFile(gpa, path, bytes)` helper.  ~1
  turn, real ergonomic win, zero migration cost.  Removes the
  3-line `Threaded.init` dance from tests and tools.
- **entry-modernize**: Full `pub fn main(init: std.process.Init)`
  migration.  Plan in `juicy-main-plan.md`.  Scheduled
  immediately after imgui arc closes.
- **3.6b**: TabBar drag-to-reorder polish.  Filed turn 315.
- **3.6c**: TabBar overflow / scroll buttons.  Filed turn 315.
- **3.6d**: TabBar tooltips on tab hover.  Filed turn 315.
- **rlsw-textures**: Bridge texture handles between rlgl (u32 id)
  and rlsw (Handle(Texture)) so glyph atlas + sprite textures
  render on rlsw screenshots.  Currently rlsw renders text as
  solid placeholder bboxes.

---

**[Turn 316 — Step 3.7: DragDropFlags + ItemFlags] Final pre-
docking flag step.  Adds the cross-widget behavior infrastructure
that docking needs (drag-drop polish) plus the broadly-useful
`disabled` + `button_repeat` cross-widget flags.**

### Decision: 3.7 over 3.6b

Per ambition policy, chose to continue the contiguous pre-docking
critical path (3.7 → 5.1 → 5.5 docking) rather than finish TabBar's
drag-to-reorder polish (3.6b).  Reasoning: every step from now to
docking blocks docking; 3.6b is a TabBar-internal nicety that
docking doesn't depend on.  3.7 has cross-arc payoff —
`ItemFlags.disabled` lights up everywhere; `allow_overlap`
unblocks tooltip-on-icon-over-row patterns.

### Types added

**`ItemFlags`** — 7 fields, cross-widget behavior stack:
- WIRED: `disabled` (composes with existing `beginDisabled`),
  `button_repeat` (400ms initial delay, 50ms cadence),
  `allow_overlap` (sets the item's allow-overlap flag — next
  item's hit-test honors).
- PLUMBED: `no_tab_stop`, `no_nav`, `no_nav_default_focus` (await
  keyboard nav, Phase 2+), `auto_close_popups` (default true; wired
  for menuItem).

Plus `mergeItemFlags(parent, child)` helper with imgui-correct
merge semantics — most fields OR up the stack, `auto_close_popups`
ANDs (parent's disable propagates).

**`DragDropFlags`** — 10 fields, replaces `DragDropSourceOpts`:
- Source-side (6): `source_no_preview` (was `no_preview`),
  `source_no_disable_hover`, `source_no_hold_to_open_others`,
  `source_allow_null_id`, `source_extern`, `payload_auto_expire`.
- Target-side (4): `accept_before_delivery`,
  `accept_no_draw_default_rect`, `accept_no_preview_tooltip`,
  `accept_draw_as_hovered`.
- Convenience: `accept_peek_only` constant (=
  `accept_before_delivery + accept_no_draw_default_rect`).

Wired this turn: `source_no_preview`, `accept_before_delivery`
(payload returns mid-drag), `accept_no_draw_default_rect`
(suppresses target highlight ring), `accept_draw_as_hovered`
(forces target's `last_item_hovered = true`).

### UiContext additions

- **`item_flags_stack: BoundedStack(ItemFlags, 16)`** — push/pop
  stack of effective flags.
- **`active_id_press_time: f32`** — wall-time the active widget
  was first clicked.  Used by `button_repeat`.
- **`active_id_last_repeat_time: f32`** — most recent auto-repeat
  tick.
- **`frame_time_seconds: f32`** — monotonic UI clock (accumulated
  `f.time.delta_time`).  Independent of wall clock so a backgrounded
  app doesn't emit a flood of repeats when re-foregrounded.

### Public API (Rule 14, opts-arg)

```zig
pub fn pushItemFlag(self: Ui, flags: ItemFlags) void;
pub fn popItemFlag(self: Ui) void;
pub fn currentItemFlags(self: Ui) ItemFlags;
pub fn beginDragDropSource(self: Ui, opts: DragDropFlags) bool;
pub fn beginDragDropTarget(self: Ui, opts: DragDropFlags) bool;
pub fn acceptDragDropPayload(self: Ui, comptime T: type, opts: DragDropFlags) ?T;
```

`pushItemFlag` mirrors imgui's `PushItemFlag(flag, enabled)` but
takes the full flag struct.  Merges with the existing top via
`mergeItemFlags`; routes `.disabled` through the existing
`beginDisabled` machinery (input-suppression + alpha multiplier)
so the two systems compose correctly.

### Sweeps

- `DragDropSourceOpts` DELETED (replaced by `DragDropFlags`).
- 4 callsites migrated: `examples/ui_drag_drop_demo.zig`,
  `examples/ui_drag_drop_source.zig`,
  `examples/ui_full_showcase.zig`, internal `src/ui.zig` tests.
- `.no_preview = ` → `.source_no_preview = ` (renamed to match
  imgui's `SourceNoPreviewTooltip`).
- `.beginDragDropTarget()` → `.beginDragDropTarget(.{})`.
- `.acceptDragDropPayload(T)` → `.acceptDragDropPayload(T, .{})`.

### Drive-by improvements (Rule 2 — fix on contact)

- `beginDisabled` now suppresses `mouse_right_clicked` and
  `mouse_middle_clicked` (was only suppressing left).  Without
  this, right-click context menus would still trigger inside
  disabled scopes.
- `buttonImpl`: all locals got explicit types (`const w: *Window`
  etc.) — was untyped `const w = ...` throughout.
- `newLine`: typed locals + fixed stale `.x` access on a `Vector2`
  (left over from the pre-zmath era; was `.window_padding.x`).

### Tests added (8)

- `Step 3.7: accept_before_delivery returns payload mid-drag (no release)`
- `Step 3.7: accept_peek_only convenience combines flags`
- `Step 3.7: pushItemFlag .disabled suppresses button click`
- `Step 3.7: mergeItemFlags OR semantics for bool flags`
- `Step 3.7: currentItemFlags reads top of stack`
- `Step 3.7: button_repeat fires after initial delay then at rate`
  — synthetic 16ms frame ticks, holds the button, asserts no
  repeats below 400ms then ≥3 repeats over the next 320ms.
- `Step 3.7: beginDragDropTarget with accept_no_draw_default_rect skips highlight`
  — compares draw_cmd count before/after; flag-set should leave
  count unchanged.
- `Step 3.7: beginDragDropTarget with accept_draw_as_hovered sets last_item_hovered`

### Demo

New `examples/ui_drag_drop_flags_tour.zig`.  Three sections:
- **§1 disabled**: toggle a checkbox, watch a row of buttons gray
  out and stop incrementing counters.
- **§2 button_repeat**: hold +/- buttons to auto-scroll a counter
  (tap = increment once, hold = repeat).
- **§3 DragDropFlags**: drag colored chips into 3 slots with
  different target flags — default ring, no ring + draw-as-hovered,
  peek-mid-drag with `accept_before_delivery`.

Registered in `build.zig` + `src/web/manifest.json`.

### Audit

- **1464/1464 tests** pass (+8 new).  Two initial test failures
  (drag-drop target tests using wrong mouse position) caught +
  fixed before changelog.
- **107/107 wasm smoke** pass.  Full smoke run since
  `DragDropSourceOpts` deletion is a cross-arc invariant change.
- `ui_drag_drop_flags_tour` standalone: 278 KB bundle, 7081 GL
  calls.
- `ui_panes` standalone unchanged (no callsite affected the
  visible behavior).

### Filed for follow-up

- **3.7b**: wire the remaining DragDropFlags
  (`source_no_disable_hover`, `accept_no_preview_tooltip`).
  These each need a small dedicated change to the
  drag preview / hover-tracking paths.
- **3.7c**: wire `ItemFlags.allow_overlap` end-to-end (today
  it's plumbed; the next-widget's hit-test should consult the
  prior item's allow-overlap flag).

### Imgui parity status

`DragDropFlags`: 10/13 fields present (skipped: 3 dock-system /
cross-context flags that don't apply to zimr).  4 wired.
`ItemFlags`: 7/8 fields present (skipped: `AllowDuplicateId`
which is a debug-tooltip flag).  3 wired + 1 plumbed for default
behavior (auto_close_popups).

**Next:** Step 5.1 Persistence (`.zon` + localStorage) — the
final pre-docking step.  Then Step 5.5 DOCKING, the milestone.

---

**[Turn 315 — Step 3.6: TabBar widget (core wired)] First half of
the docking-prereq TabBar sprint.  Most flags wired; drag-reorder
+ overflow scrolling deferred to 3.6b/c.**

### TabBar flag types added

`TabBarFlags` (7 fields + `TabFittingPolicy` enum):
- WIRED: `auto_select_new_tabs`, `no_close_with_middle_mouse_button`,
  `draw_selected_overline`.
- PLUMBED (no-op): `reorderable`, `tab_list_popup_button`,
  `no_tab_list_scrolling_buttons`, `no_tooltip`, `fitting_policy`.

`TabFittingPolicy` enum (mutually-exclusive `resize_down` /
`scroll`).  Currently only `resize_down` semantics — the impl
silently skips overflowing tabs.  `.scroll` is a no-op.

`TabItemFlags` (8 fields):
- WIRED: `unsaved_document` (asterisk decoration),
  `set_selected` (force-select THIS frame),
  `no_close_with_middle_mouse_button` (per-tab override),
  `no_push_id` (skip id_stack push), `leading` (pin left),
  `trailing` (pin right).
- PLUMBED: `no_tooltip`, `no_reorder`.

### TabBar architecture rewritten

- **`TabState`** (new): per-tab persistent state.  Inline 32-byte
  label storage, recorded width, last_frame_active for GC,
  section pin (leading/middle/trailing), unsaved flag, cached
  open_ptr, want_close flag.
- **`TabBarState`** rewritten: now owns
  `ArrayListUnmanaged(TabState)` with linear-search helper
  `findTab(id)`.  Old field `active_id` renamed `selected_id`.
- **`TabBarFrame`** rewritten: three section cursors
  (leading_cursor_x, middle_cursor_x, trailing_cursor_x) for
  pinning.  `flags` field holds the bar's flags for per-tab
  lookup.  Tracks `pushed_tab_id_this_item` so endTabItem knows
  whether to pop id_stack.
- **`UiContext.deinit`** updated to deinit each TabBarState's
  tabs list before freeing the HashMap.

### Public API (opts-arg, Rule 14)

```zig
pub fn beginTabBar(self: Ui, str_id: []const u8, opts: TabBarFlags) bool;
pub fn beginTabItem(self: Ui, label: []const u8, open_ptr: ?*bool, opts: TabItemFlags) bool;
pub fn endTabBar(self: Ui) void;
pub fn endTabItem(self: Ui) void;
```

### Per-frame semantics

1. `beginTabBar`: find/create persistent state, mark frame
   active, push `TabBarFrame` with section cursors.
2. `beginTabItem`: find/create `TabState` in the bar's list,
   compute width, position in its section, render head (bg
   color depends on `is_active`/hovered), handle left-click
   select + middle-click close, render close-X if `open_ptr`,
   render `*` for unsaved, **push tab id onto `id_stack`** for
   active tab content (per-tab unique widget ids).
3. `endTabItem`: pop id_stack if pushed.
4. `endTabBar`: GC tabs whose `last_frame_active < frame_count`
   (caller stopped submitting); finalize close-clicks by writing
   `open_ptr.* = false`; render separator; advance parent cursor.

### InputSnapshot extension

- New field `mouse_middle_clicked: bool` — wired through
  `runtime.input.isMouseButtonPressed(input_state, .middle)` in
  the snapshot builder.  Required for middle-click-to-close
  semantics.  Cross-arc invariant change → ran full smoke.

### Tests added (7)

- `Step 3.6: tabs persisted across frames` — 3 tabs submitted
  twice → exactly 3 entries in state.tabs.
- `Step 3.6: tab GC removes tabs the caller stops submitting`
  — frame 1 submits A+B+C, frame 2 submits A only, after frame 2
  only A remains.
- `Step 3.6: set_selected force-selects a tab` — bar starts on
  A (auto-select); `.set_selected = true` on B switches it
  immediately so B's content branch runs THIS frame.
- `Step 3.6: leading + trailing tabs pin to their edges` — bar
  cursor inspection proves leading section grows right, middle
  starts after leading, trailing grows left.
- `Step 3.6: middle-click closes tab (default behavior)` —
  two-frame test, mouse on B + middle-click → `b_open = false`.
- `Step 3.6: no_close_with_middle_mouse_button suppresses
  middle-click close` — same test with bar flag set → tab stays.
- `Step 3.6: id_stack push isolates per-tab widget IDs` — same
  "Save" label in A vs B → different ids captured.

### Demo

New `examples/ui_tabbar_tour.zig` (~150 lines).  Three bars
exercising the wired flags:
- **Bar 1**: 3 closeable tabs (Alpha/Beta/Gamma), each with its
  own "Click me" counter (proves id_stack isolation).
  Reopen-all button.
- **Bar 2**: hamburger (`☰`) pinned LEFT, settings (`⚙`) pinned
  RIGHT, two middle docs.  doc1 has `.unsaved_document` →
  asterisk.  Bar-level `no_close_with_middle_mouse_button`.
- **Bar 3**: 3 tabs (One/Two/Three) with `.draw_selected_overline`.
  Checkbox to force-select Two via `.set_selected`.

Registered in `build.zig` + `src/web/manifest.json`.

### Migration

Mechanical sweep across `src/ui.zig`,
`examples/ui_full_showcase.zig`, `examples/imgui_demo.zig` —
`beginTabBar("x")` → `beginTabBar("x", .{})`,
`beginTabItem("x", p)` → `beginTabItem("x", p, .{})`.

Old test `Phase 4D: clicking a tab makes it active across frames`
updated: `state.active_id` → `state.selected_id`.

### Audit

- **1456/1456 tests** pass (+7 new).  One initial failure
  (`set_selected` was queued, should be immediate) caught + fixed
  before changelog.
- **106/106 wasm smoke** pass (was 105 + new ui_tabbar_tour).
  Full smoke ran since InputSnapshot's field set changed
  (cross-arc invariant).
- `ui_tabbar_tour` standalone built: 281 KB bundle, 7681 GL calls.

### Filed for follow-up

- **3.6b**: drag-to-reorder (`reorderable` + `no_reorder`).
- **3.6c**: overflow handling (`fitting_policy = .scroll`,
  scroll arrows, `.tab_list_popup_button`'s `...` menu).
- **3.6d**: hover tooltips for truncated labels (waits on
  Step 3.5e hover-delay infra).
- **Step 4.3 wave**: `tabItemButton`, `setTabItemClosed`.

### Per the "fix on contact" rule (turn 311)

No old code touched outside the rewrite scope — everything inside
the new impl already has explicit types.  No additional drive-by
cleanups this turn.

### Imgui parity status

`TabBarFlags`: 8/8 fields present, 3 wired + 1 implicit
(`auto_select_new_tabs` honors).  `TabItemFlags`: 8/8 present,
6 wired.  Wired ratio (~70%) is the right shape — the unwired
flags (`reorderable`, scroll overflow, popup menu) each need
substantial machinery that warrants their own turn.

**Next:** Step 3.6b — drag-to-reorder.  Or, per ambition policy,
jump to **3.7 DragDropFlags + ItemFlags** which docking needs
more urgently than reorder.  Decision pending Simon's call.

---

**[Turn 314 — Step 3.5b: ChildFlags + opts-arg sweep] Big
single-turn API-shape change.  Build was broken mid-turn (per the
turn 313 build-breakage policy); ended green at 1449/1449 +
105/105 smoke.**

### `ChildFlags` replaces `ChildOpts`

Imgui-parity (10 fields per `imgui.h` 1.92.8):
- `border` — wired.  Renders a 1px outer border AND implicitly
  enables window-padding (a border with content flush against it
  looks bad).
- `always_use_window_padding` — wired.  Inner padding without the
  border render.  Pad amount: `style.window_padding`.
- `resize_x`, `resize_y`, `auto_resize_x`, `auto_resize_y`,
  `always_auto_resize`, `frame_style`, `nav_flattened` — plumbed
  as no-op-today.  Filed per-flag in field docstrings.

**Visual change:** `beginChild(..., .{})` (default flags) no
longer applies the old 4px zimr-specific padding.  Matches
imgui's `ImGuiChildFlags_None` semantics — non-bordered children
are tight by default.  Existing demos using `.{ .border = true }`
get window-padding automatically (8px on both axes).

The old `ChildOpts { border, padding }` is gone.  No callers used
the `.padding` field (verified by grep).

### Opts-arg sweep — `*Ex` methods unified

Per Rule 14 (codified turn 313, now applied):

- `isItemHovered(self, opts: HoveredFlags) bool` — was the
  no-arg + `isItemHoveredEx(flags)` pair.
- `isWindowHovered(self, opts: HoveredFlags) bool` — same.
- `isWindowFocused(self, opts: FocusedFlags) bool` — same.
- `treeNode(self, label, opts: TreeNodeOpts) bool` — was the
  no-arg + `treeNodeEx(label, opts)` pair.

Zig doesn't have default function arguments, so callers must pass
`.{}` for "no flags."  Mechanical sweep updated ~25 callsites
across `src/ui.zig`, `examples/ui_full_showcase.zig`,
`examples/imgui_demo.zig`, `examples/ui_plotting_basic.zig`,
`examples/ui_panes.zig`.  All `xxxEx` → `xxx` mechanical rename
took two sed passes (method calls + doc-comment refs).

Private impl `treeNodeImpl` deleted (was a 1-line wrapper around
`treeNodeExImpl(.{})`).  The one test that referenced it now
calls `treeNodeExImpl(&ctx, "folder", .{})` directly.

`treeNodeExImpl` (private) keeps the `Ex` suffix — it's an
internal impl detail, not public API.

### Test updates

- `Step 1.6: child scroll_max_y reflects content overflow` —
  bound relaxed from `> 100` to `> 80`.  Previous bound was
  calibrated against the 4px-padding viewport (96px effective);
  with 0 padding the viewport is the full 100, and scroll_max_y
  = 96.  The test's INTENT (proves scrolling math is right
  without pinning exact value) is preserved; the value is just
  slightly different.
- **+3 new tests:** `Step 3.5b ChildFlags: default (no flags) →
  no inner padding`, `Step 3.5b ChildFlags: border enables
  window-padding`, `Step 3.5b ChildFlags: always_use_window_padding
  without border`.

### Files modified

- `src/ui.zig` — `ChildFlags` def (~60 lines), `beginChildImpl`
  signature + padding semantics, 4 public method signatures
  merged, `treeNodeImpl` wrapper removed, 3 new tests.  21603 →
  21627 lines.
- `examples/ui_panes.zig` — `treeNodeEx` → `treeNode` (5
  callsites).
- `examples/ui_full_showcase.zig` — `isItemHovered()` →
  `isItemHovered(.{})` (2 callsites) + 1 `treeNode("foo")` →
  `treeNode("foo", .{})`.
- `examples/imgui_demo.zig` — same pattern, 5 callsites.
- `examples/ui_plotting_basic.zig` — `isItemHovered()` →
  `isItemHovered(.{})` (1 callsite).

### Audit

- **1449/1449 tests pass** (+3 new).
- **105/105 wasm smoke pass.**  Full smoke ran (not just focused)
  because the `beginChild` public signature is a cross-arc
  invariant change.
- `ui_panes` standalone built and presented for phone test:
  `ui_panes-turn314.html`.  GL calls: 12001 (unchanged from
  turn 310, as expected — the visible content didn't change for
  border-using children; only non-bordered ones lost the 4px
  pad).
- Disk-full hiccup mid-turn (8.6 GB `.zig-cache`) — wiped and
  rebuilt clean.  No code impact.

### Per the "fix on contact" rule (turn 311)

Cleaned up untyped locals in functions I touched:
`const w = self.ctx.current_window orelse return false;` →
`const w: *Window = self.ctx.current_window orelse return false;`
in `isItemHovered`, `isWindowFocused`, `isWindowHovered`, and
`treePop`.

### Imgui parity status

`ChildFlags` matches imgui 1.92.8's `ImGuiChildFlags` field-for-
field.  zimr ships 2/9 wired (border, always_use_window_padding);
remaining 7 (resize, auto-resize, frame_style, nav_flattened)
filed for follow-ups.  This is the right ratio for a single turn —
the unwired flags need separate machinery (edge-drag handles for
resize, two-pass measurement for auto-resize, framing path for
frame_style, kb-nav infra for nav_flattened) that each warrants
their own work.

**Next:** Step 3.6 — TabBar widget.  ~3-4 turns estimated.

---

**[Turn 313 — plan refresh + tutorial + policy updates] Big
meta-turn requested by Simon: "make the plan more precise and
good.  Give a precise tutorial on the code structure."**

**Plan refresh.**  Old plan (`imgui-plan.md` v3) + v4 supplement
(`plan-v4-supplement.md`) were getting cluttered + out-of-date —
status table stuck at turn 263, no reflection of the 1.5.5
refactor and child-as-Window outcomes, no mention of the opts-arg
decision from turn 313.  Solution: archive both, write fresh
`imgui-plan-v5.md` from scratch.

The v5 plan:
- Phase-by-phase status table reflecting actual turn 313 state.
- Pre-docking sprint clearly scoped (3.5b → 3.6 → 3.7 → 5.1) with
  acceptance criteria per step.
- Step 5.5 DOCKING with data-structure + API sketch.
- Phase 2 dev tools POSITIONED AFTER docking (they have more to
  debug then — IDStack + DebugLog earn their keep on the dock
  tree).
- Seven ambition markers (was six) — added "opts-arg over
  Ex-variants" per turn 313 decision.
- Cross-cutting policy section: build-breakage allowed mid-turn,
  ambition over conservatism, opts-arg rule.

**Architecture tutorial.**  New file
`src/notes/architecture-tutorial.md` (~12 sections).  Covers:
- Elevator pitch (3 differences from imgui).
- File layout (`src/ui.zig` is 21,602 lines — single file by
  design).
- Core types diagram: `UiContext` → `Window` → `LayoutScope`.
- Frame lifecycle (beginFrame → window → widgets → endFrame).
- Three coordinate spaces (CSS / backing / logical).
- Widget pattern (5-step recipe every widget follows).
- ID hashing.
- DrawList commands.
- State that survives across frames (which HashMap each lives in).
- Where we are in the plan (cross-ref to v5).
- 7 pitfalls (cursor in scrolled coords, hovered_window_id only
  tracks top-level, treeNode push asymmetry, smoke harness binding
  gaps, etc.).
- How to add a new widget — checklist.

**`claude.md` updates.**
- New Rule 14: opts-arg, no `xxxEx` variants.  Migrate turn 312's
  `isItemHoveredEx` / `isWindowHoveredEx` / `isWindowFocusedEx`
  in Step 3.5b.
- New section "Build-breakage policy": build CAN be red mid-turn
  during a sweep.  Green at end of turn is the only constraint.
- New section "Ambition policy": prefer the best system, not the
  least-disruptive change.  Plans are amendable.

**`PLAN.md` updates.**
- Current focus pointer → v5.
- Status snapshot refreshed (1446 tests, 105/105 smoke, 108
  examples, 21602 lines in ui.zig).
- Plan-list entries updated for the new plan files.

**Files added:**
- `src/notes/imgui-plan-v5.md` (new — the active plan).
- `src/notes/architecture-tutorial.md` (new — companion reference).

**Files moved:**
- `src/notes/imgui-plan.md` → `src/notes/archive/imgui-plan.md`.
- `src/notes/plan-v4-supplement.md` → `src/notes/archive/plan-v4-supplement.md`.

**Files edited:**
- `src/notes/PLAN.md` — pointers + status.
- `src/notes/claude.md` — Rule 14 + policies.

**No code touched** — pure docs/plan turn.  Audit: 1446/1446 still
pass (nothing changed in `src/`).

**Next turn:** Step 3.5b — ChildFlags + opts-arg sweep.  Build
can be broken mid-turn.  Migrate 25 hover/focus callsites + define
`ChildFlags` to replace `BeginChildOpts`.

---

**[Step 3.5 — pull-forward] HoveredFlags + FocusedFlags + Ex query
methods.**  First step of the v4-supplement docking prerequisite
sequence (3.5+ → 3.6 → 5.1 → 5.5).  Adds the typed flag surface
for `isItemHovered` / `isWindowHovered` / `isWindowFocused`
queries; implements the window-traversal flags (`child_windows`,
`root_window`, `any_window`); plumbs the blocking-relaxation
flags as no-op-today-but-API-ready.

**API additions:**

- `HoveredFlags` — struct-of-bools per Zig style, 10 fields:
  `child_windows`, `root_window`, `any_window`,
  `no_popup_hierarchy`, `allow_when_blocked_by_popup`,
  `allow_when_blocked_by_active_item`,
  `allow_when_overlapped_by_item`,
  `allow_when_overlapped_by_window`, `allow_when_disabled`,
  `no_nav_override`.  Convenience constants `rect_only` +
  `root_and_child_windows`.
- `FocusedFlags` — 4 fields (`child_windows`, `root_window`,
  `any_window`, `no_popup_hierarchy`) + `root_and_child_windows`
  convenience constant.
- `isItemHoveredEx(flags)` — passes through to `isItemHovered()`
  today; all `HoveredFlags` fields are either window-only or
  relax checks that aren't yet enforced (popup blocking,
  active-item occlusion, etc.).  The plumbing is in place so
  user code can write `.{ .allow_when_disabled = true }` today
  and pick up the behavior automatically when those landings
  arrive.
- `isWindowHoveredEx(flags)` — implements `any_window`,
  `child_windows`, `root_window`, and the `root_and_child_windows`
  combo via the `parent_id` chain walk.  Bounded at 32 hops
  (defensive — parent_id is set once per frame from the
  window_stack, no cycles possible, but cheap safety).
- `isWindowFocusedEx(flags)` — symmetric with hovered; same
  traversal helpers (`isWindowAncestor`, `rootWindowOf`) keyed on
  `focused_window_id` instead of `hovered_window_id`.

**Hover-delay deferred:** the imgui flag set has 5 more fields
(`delay_short`, `delay_normal`, `no_shared_delay`, `stationary`,
`for_tooltip`) that gate behavior depending on per-item-id hover-
start timestamp state.  Adding those flags with no implementation
would be a footgun (user writes `.{ .delay_normal = true }`, gets
zero delay, no warning).  They land in a follow-up turn that adds
`HoverState` to `UiContext`.

**Helpers added:**

- `fn isWindowAncestor(ctx, ancestor, descendant_id) bool` —
  walks `descendant_id` up the `parent_id` chain looking for
  `ancestor`.  Hop-bounded.
- `fn rootWindowOf(ctx, start) *Window` — walks `start` to root.
  Returns `start` if it has no parent.  Hop-bounded.

**Tests added (3):**
- `Step 3.5: HoveredFlags.any_window — non-zero hovered_window_id`
  — two-frame test, mouse-outside vs mouse-inside.
- `Step 3.5: HoveredFlags.child_windows — parent reports hovered
  when child is hovered` — exercises the parent_id chain walk by
  forcing `ctx.hovered_window_id = child_id` and verifying that
  the parent's `isWindowHoveredEx(.{ .child_windows = true })`
  walks back to find itself.
- `Step 3.5: FocusedFlags mirrors HoveredFlags traversal` —
  pins the symmetric API shape, same chain logic keyed on
  `focused_window_id`.

**Audit:** 1446/1446 pass (+3 new).  **Smoke:** ui_panes
focused — 12001 GL calls (unchanged, as expected — no behavior
change to existing widgets).

**Per the relaxed audit-gate rule (turn 311):** this turn touched
ui.zig but did NOT change a cross-arc invariant (added new
public methods + private helpers; existing methods unchanged in
behavior), so focused smoke is sufficient.  No full smoke run.

**Variable types fixed on contact** (turn 311 rule): `const w =`
→ `const w: *Window =` in `isItemHovered` and `isWindowHovered`
bodies while editing the surrounding code.

**Imgui parallel:** all three Ex methods match imgui's
`IsItemHovered(flags)` / `IsWindowHovered(flags)` /
`IsWindowFocused(flags)` semantics one-to-one for the
implemented flags.  The 32-hop bound on the chain walks is a
zimr-side defensive choice — imgui has no equivalent because
its parent pointers can't form cycles by construction; we use
the same property but defend in case of bugs.

**Files:** `src/ui.zig` 21130 → ~21380 (+250, includes flag
type definitions + Ex method docs + tests).  No new files.

---

**[Tooling] Smoke harness: overlay binding stubs + relaxed full-smoke
rule.**  Two small infrastructure fixes from Simon's audit-gate
question turn 310.

**Smoke harness — `webtests/smoke.ts`:** added 5 no-op stubs for
the `dom:js_*_overlay_input*` extern surface introduced in Step
1.8.  The 5 affected examples (imgui_demo, ui_full_showcase,
ui_imgui_extras, ui_input_callbacks, ui_log_viewer) failed to
instantiate in smoke with `import function
dom:js_overlay_input_is_visible must be callable` — they pull in
`inputText` which pulls in `src/web.zig`'s overlay extern decls,
and the harness predated Step 1.8.  Now: 105/105 PASS in full
smoke (was 100/105).

The stubs are deliberately minimal — `js_overlay_input_is_visible`
returns 0 so `inputTextImpl`'s overlay-blur path takes the
not-visible branch and no overlay logic kicks in.  Matches the
existing pattern for clipboard stubs (always-failed handle).

**`claude.md` audit gate — relaxed full-smoke rule.**  Previous
rule: "Touching `runtime.zig` / `rlgl.zig` / `drawing.zig` /
`ui.zig` (cross-arc deps): full smoke that turn."  Problem: most
ui.zig touches are widget-internal and only affect the focused
example; the 30s full smoke gave no extra signal over the 1s
focused.  Across this conversation's 5 turns (309/309b/309c/
309d/310), only one needed full (309d's arc close), but the rule
as written demanded all 5.

New rule: full smoke at arc-close turns OR when a turn changes a
cross-arc INVARIANT — input dispatch shape, draw-list command
set, extern import surface, public API of Window/Frame.  Pure
widget-internal refactor → focused only.  This recovers
~25s/turn for the common case and keeps the safety net for the
rare structural changes that actually break unrelated examples.

**Files:** `webtests/smoke.ts` +28 LOC; `src/notes/claude.md`
rule rewrite.

**Audit:** 1443/1443 pass.  Full smoke: 105/105 PASS.

---

**[Step 1.6] Per-child scrolling — first cash-in from the 309 arc.**
After child-as-Window landed turn 309d, this turn implements
per-child scrolling.  Each `beginChild` and `beginListBox` now
behaves identically to a top-level window w.r.t. scroll: when
content overflows the viewport, a scrollbar renders on the right
edge, mouse wheel scrolls, drag works on the thumb.  Per-child
state (scroll position) persists across frames via the same
`ctx.windows` storage the child Window uses.

This is the "mostly free" feature called out in plan v4
supplement §6 — `scroll_y` and `scroll_max_y` were already fields
on `Window`, and after child-as-Window every child IS a Window,
so the storage came for free.  ~80 lines of code for the
plumbing; the rest was reusing the existing `renderScrollbar`
machinery.

**Changes:**

- **`renderScrollbar` reworked** to read track bounds from
  `w.layout.origin[1]` / `w.layout.work_rect_max[1]` instead of
  `w.pos[1] + style.title_bar_height + padding`.  Same function
  now serves both top-level (where origin = pos + title + pad)
  and children (where origin = pos + opts.padding) with zero
  branching.  Also dropped the redundant `viewport_h` /
  `content_h` arguments — they're derivable from the function's
  own variables (`viewport_h = track_h`, `content_h =
  viewport_h + scroll_max_y`).
- **`beginChildImpl` applies `child.scroll_y`** to the initial
  cursor position: `cursor_pos.y = inner_origin.y - scroll_y`.
  Mirrors openWindow's pre-existing scroll-shift pattern.
- **`endChildImpl` computes scroll_max + applies wheel:**
  - `content_h_natural = cursor_max.y + scroll_y - origin.y` —
    unshifts cursor_max (which was tracked in scrolled coords)
    to recover the natural content extent.
  - `viewport_h = work_rect_max.y - origin.y`.
  - `scroll_max_y = max(0, content_h - viewport_h)`.
  - Wheel applied iff cursor is in child's outer rect AND
    `mouse_wheel_consumed = false`; sets consumed flag after.
  - Pops content clip, then renders scrollbar (in that order so
    the scrollbar isn't clipped by the now-popped content clip).
- **`closeListBox` ditto** — same scroll-bookkeeping shape,
  copy-paste pattern.
- **`UiContext.mouse_wheel_consumed: bool`** — new per-frame flag.
  Reset at `beginFrameRaw`.  Inner children's `endChildImpl`
  runs LIFO before their parents', so the deepest scope under
  the pointer claims the wheel first; outer scopes see the flag
  and skip.  Matches imgui's WantCaptureMouse cascade semantics.
- **`closeWindow`'s wheel logic** updated to check + set
  `mouse_wheel_consumed`, so a top-level window with no
  scrolling children still gets the wheel (and inner scrolling
  children still take priority).

**Tests:** 1443/1443 pass.  Added:
- "Step 1.6: child scroll_max_y reflects content overflow" —
  pins the two cases: content overflows → `scroll_max_y > 0`;
  content fits → `scroll_max_y == 0`.
- "Step 1.6: mouse wheel consumed by deepest hovered child" —
  two-frame test.  Frame 1 discovers actual child rects.  Frame
  2 places mouse inside the inner child + dispatches a wheel
  tick; verifies inner's `scroll_y > 0` AND outer's `scroll_y
  == 0` (because the cascade short-circuited).

**Smoke:** ui_panes 12001 GL calls — up from 10741 at turn 309d.
The +1260 calls are the scrollbar renders for the editor and
output panes, which now overflow when the user makes the
workspace small enough or scrolls them.  (EDITOR_TEXT is 19
lines; default top_h is 280px, comfortably fits ~12 lines, so
scrolling kicks in.)

**Standalone:** `ui_panes-turn310.html`.

**Zig-explicit choices worth calling out:**

- **`mouse_wheel_consumed: bool`** is named for what it MEANS,
  not how it's implemented.  Reading `if (!ctx.mouse_wheel_consumed and ...)`
  reads as "if no one has consumed the wheel yet" — clearer than
  imgui's `WantCaptureMouse` (which is the inverse polarity and
  named for what the IO layer wants from the host app).
- **Cascade is explicit** at every consuming site.  No magic
  layer that observes "input is over a child."  Each scope
  decides for itself: "am I hovered? Is the wheel still
  available? Yes → take it, set the flag."  Three places, all
  identical, all readable.
- **`scroll_y` semantics on Window apply uniformly** — no
  separate field for "child scroll" vs "window scroll."  The
  same field works for both because children ARE windows.  This
  is the structural payoff from the 309d refactor cashing in.

**Imgui parallel:** imgui has `Window.Scroll` (Vector2) on
`ImGuiWindow`, set by the same wheel + drag inputs, applied at
`SetCurrentWindow` via cursor offset.  Same shape; we just
implement the vertical half (horizontal scroll is rare enough
that it's deferred until a use case appears — Step 1.6.x).

**Files:** `src/ui.zig` 20935 → 21130 (+195, ~80 code +
docstrings).  No new files.

---
