# Changelog — turns 320-329

## [Unreleased]

**[Turn 329 — Docking 5.5g + 5.5i complete: size_ref locks +
central-node marker.]**

### What lands

- **`size_ref: [2]?f32`** per SPLIT (in `SplitData`).  Non-null
  on a slot locks that child at that pixel size along the
  split axis; the other child absorbs the remainder when the
  dockspace resizes.  Both null = pure ratio (existing
  behavior).  Both non-null = over-constrained, falls back to
  ratio.
- **`computeSplitChildSizes(split, avail)`**: pure helper that
  resolves child sizes from the lock state.  Exported via
  `computeSplitChildSizesPublic` so the seam-rect helper in
  `ui.zig` uses the same logic (one source of truth).
- **Layout honors the lock**.  Grow a 1000-px dockspace to
  1400 px with `size_ref[0] = 200` → child a stays at 200,
  child b grows from 796 to 1196.  Imgui equivalent uses
  per-node `SizeRef[axis]` (`imgui.cpp:20322-20338`); we put
  the state on the SPLIT instead (one location vs two,
  easier to serialize, simpler to reason about).  Filed as
  JUSTIFIED simplification.
- **Splitter drag respects the lock**.  When a child is
  locked, drag writes the new pixel size to `size_ref` instead
  of mutating `ratio`.  Result: the lock persists across drag
  operations — the user can fine-tune the locked panel's
  width by dragging the seam, and the panel stays locked at
  the new size.
- **`dockBuilderSetSizeRef(parent_id, side, px)`** public API.
  `side: .a | .b` selects child; `px: ?f32` sets or clears the
  lock.  No-op on leaves and unknown ids.
- **`dockBuilderSetCentralNode(node_id)`** public API sets the
  `is_central` flag.  Today this is a pure marker — the
  size_ref mechanism already gives the "fixed siblings + central
  absorbs" UX, so no dedicated layout branch is needed.  The
  flag persists across serialization (5.5k) and reserves the
  hook for future `NoDockingOverCentralNode` semantics.
- **6 new tests**: a-locked round-trip with dockspace resize,
  b-locked, over-constrained fallback, public API,
  splitter-drag-preserves-lock, central-node flag.

### Why per-split size_ref instead of per-node SizeRef

imgui stores `SizeRef[X], SizeRef[Y]` on EVERY node and
recomputes ratio from sibling SizeRefs at layout time.  This
gives more flexibility (a node can carry its preferred size
across re-splits) but requires:
  - Two values per node (px on each axis) even when only one
    is meaningful at any given layout
  - A "WantLockSizeOnce" transient bool for splitter drag
    semantics
  - Sibling SizeRefs must stay in sync to compute a sensible
    ratio
We collapse this to: lock lives on the SPLIT, one slot per
child; layout uses it directly; no transient bools; no
synchronization across siblings.  Loses imgui's
"preserve preferred size across re-splits" feature (which is
rarely user-visible).

### Build state

- 1541/1541 native tests (was 1535; +6 new).
- Wasm build clean.

### Plan / audit doc updates

- Plan 5.5g + 5.5i marked ✅ turn 329.
- Audit doc:
  - Row 2 (Size storage): ⚠️ PARTIAL → ✅ done with simpler
    per-split model.
  - Row 5 (Central node): ❌ NO → ✅ done with size_ref-driven
    UX (no dedicated layout branch needed).

### Next

- Only 5.5j (tab close + drag-detach + drag-reorder) and
  5.5k (settings serialization) remain in the docking arc.
- 5.5j is the biggest remaining piece (~3-5 turns).  5.5k
  closes the loop on persistence.
- 5.5l is demos polish.

---

**[Turn 328 — Docking 5.5i (partial): splitter drag between
dock leaves.]**

### What lands

- **`SPLITTER_SIZE = 4 px`** constant in `src/ui_dock.zig`.
  `layoutSubtree` now reserves that gap between a split node's
  two children; the seam is real, not a visual cheat.  Matches
  imgui's `g.Style.DockingSeparatorSize` default.
- **`renderDockSplitters`** in `src/ui.zig`: walks every
  split node, computes seam rect, runs the hover/press/drag
  state machine.  Same pattern as the existing `splitterImpl`
  (used by `Ui.splitter()` for non-dock panels) but specialized
  for dock seams that don't belong to any window's id stack.
- **One-frame visual feedback.**  When a drag changes
  `split.ratio`, `flushDockTabsToForeground` re-runs
  `layoutSubtree` BEFORE drawing tabs.  Without this, the
  splitter visibly lagged the cursor by one frame (annoying;
  classic imgui issue with retained-mode-like callbacks).
- **`no_resize` flag wired.**  Seam still renders so the
  layout reads correctly, but click + drag are inert.
- **Widget id derivation.**  `hashStr(node_id, "__dock_splitter")`
  ensures the splitter's id can't collide with normal
  `widgetId` hashes (which thread through the current window's
  id stack — dock splitters don't have a window).

### What's DEFERRED to next turn

- **`size_ref: ?f32` per child** for fixed-width-panel UX
  ("Tools panel stays 200px when window resizes").  Today the
  split is purely proportional — dockspace resize scales both
  children by the same ratio.  imgui's central-node concept
  (5.5g) plus per-child SizeRef gives "fixed left + flexible
  central" UX; both will ship together next turn since the
  layout math interleaves.

### Build state

- 1535/1535 native tests (was 1532; +3 new for splitter).
- Existing 3 layout tests updated for the new gap math
  (`avail = total - SPLITTER_SIZE`).
- Wasm build clean.

### Visual artifact

- `ui_dock_basic-turn328.png` shows the 30/70 split with a
  visible seam between the two leaves.  Previously the leaves
  abutted; now there's a 4-px tinted strip.  Grab + drag it to
  resize.

### Plan / audit doc updates

- Plan 5.5i marked ✅ turn 328 (partial — size_ref deferred).
- Audit doc unchanged for now; size_ref item still PARTIAL
  pending the SizeRef-equivalent work.

### Next

- Bundle 5.5g (CentralNode logic) + size_ref together in the
  next turn — they form a coherent unit.  ~1 turn.

---

**[Turn 327 — Docking 5.5f: DockNodeFlags + wire into hit-test,
overlay, tab-bar rendering.]**

### What lands

- **`DockNodeFlags = packed struct(u16)`** in `src/ui_dock.zig`,
  9 bools + 7 bits padding.  Maps imgui's flag taxonomy to a
  flat single bitset; no Shared/Local/Local-in-Windows tiering
  — JUSTIFIED simplification (imgui's tiering is rooted in the
  `WindowClass` typed-docking system we don't implement).
- Flags shipped, behavior wired:
  - `no_split` — zeros side zones in hit-test + overlay; only
    center (dock-as-tab) survives.
  - `no_docking_over_me` — leaf skipped entirely in hit-test +
    overlay; nothing renders, nothing hits.
  - `no_tab_bar` / `hidden_tab_bar` — `renderDockLeafTabBars`
    returns early.  Both treated identically for now; semantic
    distinction reserved for 5.5j (triangle indicator to toggle
    back on the hidden variant).
- Flags shipped, definition only (behavior deferred):
  - `no_resize` — slated for 5.5i splitter drag.
  - `no_close_button` — slated for 5.5j tab close button.
  - `passthru_central` — slated for 5.5g central node layout.
  - `is_central` — used by 5.5g.
  - `is_dockspace` — set automatically by `dockSpace()` on
    creation; persistence (5.5k) reads it.
- Flag transfer on split via `DockNodeFlags.transfer_mask` and
  `intersect` / `except` helpers:
  - Inheritor (the child that keeps the existing windows) gets
    the leaf-affinity flags from the original target.
  - Parent (newly demoted to a split node) keeps only
    tree-structural flags (`is_dockspace`, `passthru_central`).
  - Mirrors imgui's `LocalFlagsTransferMask_`
    (`imgui_internal.h:2016`) and the transfer site in
    `DockNodeTreeSplit` (`imgui.cpp:20201-20210`).
- Public API:
  - `Ui.dockBuilderSetNodeFlags(node_id, flags)` — set flags
    explicitly.
  - `Ui.dockBuilderGetNodeFlags(node_id)` — read.  Returns
    `.{}` (default-init, all false) for unknown ids — callers
    don't need to handle null.
- Demo idiom (from doccomments):
  ```zig
  u.dockBuilderSetNodeFlags(side_id, .{
      .no_split = true,
      .no_docking_over_me = true,
      .no_close_button = true,
  });
  ```

### Known limitation, documented

- When `no_tab_bar` or `hidden_tab_bar` is set, the docked
  window's content area still starts `title_bar_height` below
  the leaf's top edge — i.e. there's a blank strip of padding
  where the tab bar used to be.  Visual artifact only; doesn't
  break correctness.  Will reclaim that strip in 5.5j when the
  `hidden_tab_bar` triangle indicator lands (which needs that
  strip anyway).

### Build state

- 1532/1532 native tests pass (was 1526).
- Wasm build clean.

### Audit doc update

- Row 3 (Node flags): ❌ NO → ✅ done with JUSTIFIED
  simplification.

### Next

- 5.5i — splitter drag + `size_ref: ?f32`.  Unlocks 5.5g
  (central node layout depends on size_ref).

---

**[Turns 325-326 — Docking 5.5e + 5.5h: smooth-pull drop overlay
(better than imgui), pre-dock pos/size restore on undock.]**

### What lands

- **5.5e — drop hit-test parity + improvement on imgui.**
  - **Adopted from imgui** (`DockNodeCalcDropRectsAndTestMousePos`,
    imgui.cpp:19897-19903): adaptive zone sizing.  Zones now scale
    with both font size AND leaf size via
    `hs = min(font*1.5, max(font*0.5, min_dim/8))`.  Previously
    fixed 36-px constants felt wrong at large font sizes and on
    very-tall leaves.
  - **Improved on imgui** — replaced imgui's two-radii hit-test
    (with magic constants 1.4 / 2.6) with **continuous-scoring
    closest-zone-wins**:
    - `dockZoneScore(zone, mp, pull_scale) -> f32` returns `[0, 1]`
      with linear falloff from zone center.
    - `dockZoneScores(zones, mp) -> [5]f32` scores all five; center
      gets 1.15x pull boost (matches imgui's "center wins from a
      wider radius" intuition without magic constants).
    - Highest-score zone wins.  Stable tie-break by array order
      (center, top, right, bottom, left).
    - **Smooth visual feedback**: every zone always renders with
      `BASE_ALPHA = 80`; the winning zone's alpha climbs to
      `BASE + (PEAK-BASE) * score²` (quadratic to make the snap
      feel decisive while keeping runners-up visible).  Winner's
      outline is fully opaque (255) vs 180 for others.  Color
      channels lerp with score for a subtle blue → focus-blue
      gradient on the winner.
  - **Result**: no flicker zones (imgui has these at the boundary
    between its two radii — the dotnet stack overflow questions
    about "flickering dock indicators" suggest users hit this
    in practice).  Users can now SEE the cursor "pulling" toward
    the chosen target.
  - Filed under "🏆 IMPROVED ON IMGUI" in the audit doc
    (`docking-vs-imgui.md` row 10).
  - 7 tests, 2 new + 5 adapted to the new signature.
  - Screenshot artifact: `ui_dock_overlay-turn325.png` shows the
    smooth-pull rendering with one zone bright and siblings
    faintly visible.

- **5.5h — pre-dock pos/size on Window.**  Adds
  `pre_dock_pos: ?Vector2`, `pre_dock_size: ?Vector2` to `Window`.
  Stash at first dock — checks `pre_dock_pos == null` to avoid
  re-stashing on re-dock (e.g. drag from leaf A to leaf B keeps
  the original anchor).  Restore + clear in
  `clearDockIdsInSubtree` (dockBuilderRemoveNode-driven path).
  Drag-detach path (5.5j) will also need restore — deferred to
  that turn.
  - JUSTIFIED simplification over imgui's `AuthorityForPos/Size`
    3-bit per-axis fields: ours is stash + restore as a unit.
    Loses "I docked, then moved the leaf, now undocking should
    keep the leaf's pos" nuance; gains a much simpler model.
  - 3 new tests: stash on first dock, no re-stash on re-dock,
    restore-on-undock.

### Build state

- 1526/1526 native tests pass (was 1521 at turn 324).
- Wasm build clean.

### Plan / audit doc updates

- Plan v5 marks 5.5e ✅ turn 325, 5.5h ✅ turn 326.
- Audit doc transitions:
  - Row 7 (Pre-dock state): ❌ NO → ✅ done.
  - Row 9 (Drop zone sizing): ❌ NO → ✅ done.
  - Row 10 (Drop hit-test): ❌ NO → 🏆 IMPROVED ON IMGUI.

### Next

- 5.5f — DockNodeFlags (NoSplit/NoTabBar/NoResize/etc.).
- Then 5.5i — splitter resize + `size_ref: ?f32`.

---

**[Turn 320 — Docking 5.5c refinement: fixed frame-1 ordering
quirk, exposed `flushDockTabsToForeground` for host screenshots,
shipped `ui_dock_basic` standalone HTML.]**

### What lands

- **Frame-1 ordering fixed.**  Tab-bar rendering moved out of
  `dockSpaceImpl` (which fires at user's `dockSpace(...)` call
  time, before `dockBuilder*` mutations and docked-window
  submissions can land) into a deferred pass executed from
  `endFrame`.  The new `flushDockTabsToForeground(ctx)` helper:
  1. Walks every dockspace submitted this frame (via
     `ctx.dock.dockspaces_this_frame`).
  2. Re-runs `layoutSubtree` so any post-`dockSpace()` builder
     mutations (split, dock-as-tab) are reflected in leaf rects.
  3. Temporarily redirects `ctx.current_draw_list` to
     `foreground_dl` so the tabs draw above docked content (each
     docked window has its own per-window draw list which
     renders earlier in the endFrame pipeline).
  4. Calls `renderDockLeafTabBars` per dockspace root.

- **Helper exposed for screenshot path.**  `ui_screenshot.zig`
  now calls `flushDockTabsToForeground(ctx)` before reading the
  framebuffer.  Single-frame host-test mode (no `endFrame` ever
  runs) now produces correct PNGs.  `ui_screenshot.renderToBytes`
  also gained a `foreground_dl` replay pass (bbox + real) so
  tooltips + popups + dock tabs all show up in PNG output.

- **Standalone HTML shipped.**  `prebuilt/standalone/ui_dock_basic.html`
  (445 KB, single file).  Open in browser → three pre-docked
  windows in 30/70 split, click tabs to switch active leaf.

- **Visual proof.**  `/mnt/user-data/outputs/ui_dock_basic-turn319.png`
  regenerated: three tabs correctly distributed across the
  30/70 split (Tools at left, Viewport + Console as tabs at right).
  Previously empty leaves (rendering ran before builder).

### Files modified

- `src/ui.zig` — extracted `flushDockTabsToForeground(ctx)`
  helper (pub).  Calls from `endFrame` after the tooltip block.
  Removed inline `renderDockLeafTabBars` from `dockSpaceImpl`
  (replaced with a comment explaining the deferral).
- `src/ui_screenshot.zig` — call `ui.flushDockTabsToForeground(ctx)`
  before the window-replay loop.  Add foreground_dl replay
  pass after the windows.
- `src/notes/imgui-plan-v5.md` — frame-1 ordering quirk moved
  from "to fix" → "FIXED in late 319" with implementation note.

### Tests

- 1514/1514 native (unchanged — the existing dock screenshot test
  re-runs and produces a non-broken PNG now; no new assertions).
- Wasm build green (`zig build install`).

### What's NEXT (5.5d onwards)

Per plan v5 section 4 status block:
- 5.5d: drag-to-dock interaction (title-bar drag detection +
  5-zone overlay + `DockRequest` on release).  Two sub-turns:
  5.5d.i detection + threshold, 5.5d.ii overlay + drop.
- 5.5e: splitter resize between leaves.
- 5.5f: tab close button + drag-detach.
- 5.5g: settings serialization (extend ui_persistence with
  `DockNodeSettings[]`).
- 5.5h: demos polish.

---
