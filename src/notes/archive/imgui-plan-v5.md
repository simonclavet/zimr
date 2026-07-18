# imgui-plan-v5.md — finishing the imgui port (refresh turn 313)

**Status at turn 313:** 1446 unit tests pass, 105/105 wasm smoke
tests pass, 108 example wasms, `src/ui.zig` is 21602 lines.  We're
mid-arc — the foundation refactor (Step 1.5.5 child-as-Window) is
done; the docking sequence is unblocked.

This plan supersedes `archive/imgui-plan.md` (v3) and
`archive/plan-v4-supplement.md` (v4).  Where they contradict, v5
wins.  Both originals stay in `archive/` for arc-history reference.

---

## 0. What this arc is

**Full imgui feature parity for the wasm subset, expressed in
idiomatic Zig.**  Everything `imgui.h` master has — minus four
paradigm-incompatible categories (multi-viewport, allocator hooks,
va_list V-variants, IME) — plus seven "ambition markers" where we
ship cleaner data modeling than imgui's C-language shape.

The arc is **not** an API-stability arc.  Simon is the only user
today.  Breaking changes that produce a cleaner system are
encouraged.  Once the arc closes and `ui_full_showcase` ships,
THAT's the API stability boundary.

### Seven ambition markers — system improvements over imgui

These are how we ship parity, not separate features:

1. **Struct-of-bools flag types.**  Imgui has bit-flag enums
   (`ImGuiWindowFlags_*`).  zimr has typed structs (`WindowFlags
   { is_child: bool = false, ... }`).  Each flag is independently
   type-checked at the call site.  Mutually-exclusive flag groups
   become Zig enums (`TableColumnSizing`, `ColorPickerLayout`).
2. **Opts-arg, not Ex-variants.**  Imgui's C API has
   `Foo(...)` / `FooEx(..., flags)` pairs for back-compat.  In Zig
   that's gratuitous — a single function with `opts: FooOpts = .{}`
   covers both.  Locked in turn 313 after Simon flagged the
   `isItemHoveredEx` split as un-Zig-idiomatic.  Sweep at
   pre-docking arc-close (§7).
3. **`.zon` + localStorage persistence.**  Imgui has text-INI
   requiring app code to wire disk I/O.  zimr ships
   round-trips-through-localStorage automatically: drag a window,
   refresh, it stays.  Scope: Step 5.1.
4. **`ImGuiKey` correctly typed.**  All 147 imgui Key values
   covered, but mouse buttons live on `MouseButton`, gamepad on
   gamepad inputs, modifier chord constituents on `KeyChord` bools.
   Already shipped pre-arc; not a step.
5. **Long-press → right-click on touch.**  Imgui assumes
   right-click context menus exist.  Phones don't.  Maps long-press
   at the input layer so context menus work without per-demo
   gesture hacks.  Scope: Step 2.2.
6. **Capstone updated incrementally.**  Each phase boundary adds
   one tab to `ui_full_showcase.zig`.  Phase 6 is polish, not
   assembly.
7. **`Value(label, v: anytype)`** + color converters as methods
   on `Color` — comptime dispatch / method discoverability over
   imgui's overload soup.  Already shipped (`Value` turn 277,
   Color methods filed Step 4.2).

### Source-of-truth policy

**The C++ source of imgui (master + docking branch) is the
reference implementation for every feature in this arc.** When
implementing or extending a feature, the default is: do what
imgui does. The full docking-branch source is staged at
`/tmp/imgui-docking/` (extracted from the zip Simon supplied);
`src/notes/docking-vs-imgui.md` section 10 maps every dock
concept to its imgui line number.

Divergences from imgui are **allowed but must be documented** —
in a code comment at the divergence point and (if substantial) in
the plan or the audit. Valid reasons to diverge:

- **Zig idiomatic** — e.g. struct-of-bools flags, `opts` arg
  instead of Ex-variants, `union(enum)` for sum types instead of
  C-style tag + payload.
- **Simplicity** — when imgui's complexity (e.g. transient `Want*`
  state machine, three-tier flag inheritance) reflects historical
  evolution rather than essential complexity.
- **Browser incompatibility** — multi-viewport, OS cursor changes,
  filesystem `.ini` persistence.
- **Out of scope** — `WindowClass` typed docking, multi-context
  support, allocator hooks.

Divergences NOT allowed without revisiting:

- Easier implementation that ignores a real UX consequence
  (e.g. our normalized `ratio` vs imgui's `SizeRef` — works for
  proportional layouts but breaks "fixed-width left panel"
  expectation; flagged in audit as PARTIAL, scheduled for 5.5i).
- "I forgot to check imgui" — always check.

The audit (`docking-vs-imgui.md`) labels each divergence
JUSTIFIED / PARTIAL / NO and is the live record. NO items become
follow-up sub-steps.

---

## 1. Where we are — phase-by-phase status

```
Phase A (foundation: ListClipper, multiline, scroll)        ✅ DONE (v2 turns 190-193)
Phase B (input polish: cursor, Shortcut, menu, combo)       ✅ DONE (v2 turns 196-201)
Phase 1 (Tier-1 features)                                    ✅ DONE (turns 266-310)
  1.1 Text helpers + Value()                                ✅ turn 277
  1.2 TextFilter                                            ✅ turn 281
  1.3 MultiSelect + SelectionBasicStorage                   ✅ turn 305
  1.4 Splitter + setNextWindowSizeConstraints + setWindow*  ✅ turn 308
  1.5 TreeNodeEx flags + tree polish                        ✅ turn 308
  1.5.5 LayoutScope + child-as-Window refactor              ✅ turn 309d
  1.6 Per-child scrolling                                   ✅ turn 310
  1.7 Phone keyboard plumbing                               ✅ turns 282-298
  1.8 DOM input overlay                                     ✅ turn 302
Phase 2 (Dev tools) — DEFERRED past docking
Phase 3 (Flag-extension waves)                              IN PROGRESS
  3.5a HoveredFlags + FocusedFlags (window-traversal)       ✅ turn 312
  3.5b ChildFlags + opts-arg sweep (kill Ex variants)        ✅ turn 314
  3.5c PopupFlags                                            pending
  3.5d ComboFlags                                            pending
  3.5e Hover-delay machinery + delay flags                   pending
  3.6  TabBar core (flags + state + GC + id-push + asterisk
       + middle-click + set_selected + leading/trailing)     ✅ turn 315
  3.6b TabBar drag-to-reorder                                pending
  3.6c TabBar overflow (scroll, ..., scroll arrows)          pending
  3.6d TabBar tooltips (waits on 3.5e hover-delay)           pending
  3.7  DragDropFlags + ItemFlags (disabled, button_repeat,
       allow_overlap plumbed; mergeItemFlags stack)          ✅ turn 316
  3.7b Remaining DragDropFlags (source_no_disable_hover,
       accept_no_preview_tooltip)                            pending
  3.7c Wire ItemFlags.allow_overlap end-to-end               pending
Phase 5.1 Persistence (.zon + localStorage)                  ✅ turn 318 (a+b+c)
Phase 5.5 DOCKING — the milestone                            IN PROGRESS
  Source-of-truth: imgui v1.92 docking branch (see
  src/notes/docking-vs-imgui.md for full per-decision audit).
  Default: follow the C++ implementation unless we document a
  reason to diverge (Zig idiomatic, simplicity, browser
  incompatibility, etc.).

  5.5a Data layer (DockNode/DockContext/DockRequest +
       mutation primitives + layoutSubtree)                   ✅ turn 319
  5.5b dockSpace widget + dockBuilder* API
       (Split, DockWindow, RemoveNode, Finish)                ✅ turn 319
  5.5c Docked-window rendering (openWindow gates docked
       windows; leaf tab strips render in dockSpaceImpl;
       click-to-select; frame-1 ordering fix via
       flushDockTabsToForeground)                             ✅ turns 319-320
  5.5d Drag-to-dock interaction (title-bar drag detection,
       5-zone overlay, DockRequest on release)                ✅ turn 324
    5.5d.i   dragging_window tracking via title-bar drag      ✅ turn 321
    5.5d.ii  press-screen pos + 8px threshold gate            ✅ turn 322
    5.5d.iii 5-zone overlay rendering (visual only)           ✅ turn 323
    5.5d.iv  drop-zone hit-test + DockRequest enqueue         ✅ turn 324
  --- Quick-win parity sprint (post-source-review, turn 325): ---
  5.5e Drop hit-test parity + score-based smooth-pull
       overlay. ADOPTED imgui's adaptive sizing
       (per imgui:19897); IMPROVED ON imgui by replacing the
       two-radii hit-test (with magic constants 1.4/2.6) with
       continuous-scoring closest-zone-wins, smooth opacity
       modulation. Eliminates flicker zones; user can see the
       cursor "pull" toward the winning zone.                 ✅ turn 325
  5.5f DockNodeFlags (NoSplit, NoTabBar, NoResize,
       NoDockingOverMe, HiddenTabBar, NoCloseButton,
       PassthruCentralNode, is_central, is_dockspace). Flat
       packed struct(u16), no Shared/Local tiering. Wired into
       hit-test, overlay, and tab-bar rendering. Transfer mask
       moves leaf-affinity flags to inheritor on splitNode per
       imgui:20204 simplified.                                ✅ turn 327
  5.5g CentralNode logic — `is_central` flag + helper API
       `dockBuilderSetCentralNode`. The size_ref mechanism
       gives the same "fixed sibling + central absorbs" UX
       as imgui's central-node special-case (imgui:20322-20338)
       without the dedicated layout branch. Pure marker for
       persistence + future drop-zone behavior. Bundled with
       size_ref since the math interleaves.                   ✅ turn 329
  5.5h Pre-dock pos/size on Window for undock-restore.
       Lighter version of imgui's AuthorityForPos/Size:
       stash + restore as a unit rather than per-axis
       authority tracking. Stash on first dock (programmatic
       or drag-release); restore on dockBuilderRemoveNode-
       driven undock. JUSTIFIED simplification — loses the
       per-axis nuance, gains a much simpler mental model.    ✅ turn 326
  --- Bigger remaining work: ---
  5.5i Splitter resize between leaves + size_ref: [2]?f32
       per child for fixed-width-panel UX (imgui SizeRef
       equivalent, simplified to per-split rather than
       per-node).  `SPLITTER_SIZE = 4 px` gap reserved by
       layoutSubtree; `renderDockSplitters` deferred to
       endFrame with one-frame re-layout for visual
       responsiveness.  `no_resize` flag wired.  Drag on a
       locked side updates size_ref (preserves lock).         ✅ turn 329
  5.5j Tab close button (turn 331) + drag-detach (turn 332)
       + drag-reorder (turn 333) — COMPLETE.  Tab × →
       undockSingleWindow.  Press on tab label, strip-aware
       classification: mouse Y in strip → reorder (cursor's
       slot determines target idx, deferred mutate);
       mouse Y past DETACH_Y_THRESHOLD outside strip →
       detachAndStartDrag (hands off to 5.5d.iv title-bar
       drag).  Dead zone between → hold.                     ✅ turn 333
  5.5k Settings serialization — `PersistedDockNode[]` in
       `ui_persistence.PersistedState`.  Flat representation
       (is_split discriminator + per-role fields) to keep
       .zon round-tripping simple.  Leaves persist window
       NAMES (not hashed ids) so windows survive renames in
       a name-preserving way; ids restored verbatim for
       structural stability.  `tryRestoreDockTree(gpa, ctx)`
       called from `dockSpaceImpl` before fresh-root creation
       — if a pending tree exists, it's consumed and the
       user's subsequent `dockBuilder*` calls become safe
       no-ops (split target is no longer a leaf → rejected).
       Audit doc row 8 ✅                                     ✅ turn 334
  ----- Font-default sweep (Option A) -----
       Delete loadFontDefault + embedded TTF; revert lazy
       load in beginFrame; rename to loadFontFromTtfBytes
       (FontCache convenience); move TTF to
       examples/assets/fonts/; sweep 87 examples to do their
       own @embedFile + loadFontFromTtfBytes; update docs.
       Zimr now treats fonts like textures / meshes / audio:
       bring your own bytes.                                  ✅ turn 335
  5.5l Demos polish (ui_dock_persistence, ui_full_showcase
       Docking tab)                                           pending
Phase 2 (Dev tools, deferred to here)
  2.1 Metrics + About windows
  2.2 DebugLog + IDStack + long-press bridge
Phase 3 remaining (flag waves)
  3.1 WindowFlags + horizontal scroll API
  3.2 TableFlags + TableColumnFlags
  3.3 InputTextFlags + ColorEditFlags
  3.4 TreeNodeFlags cleanup + Selectable/Slider/Button
Phase 4 (Cleanup)
  4.1 Table queries + cell bg + angled headers
  4.2 Layout/cursor/item-query gaps + drag ranges + color converters
  4.3 KeyboardKey expansion + popup variants + theme presets + show*
  4.4 / 4.5 Zig 0.16 ceremony cleanup (incremental, not one-shot)
Phase 5 remaining
  5.2 Logging family
  5.3 DrawListSplitter
Phase 6 — Capstone close + arc archive
Phase JM (post-arc) — juicy-main migration                   plan: src/notes/juicy-main-plan.md
  JM-1 Investigation (wasm reactor entry, Threaded on single_threaded)
  JM-2 z.host helpers (SEPARABLE — can ship anytime)
  JM-3 POC: basic.zig under pub fn main(init: Init)
  JM-4 z.run signature lift
  JM-5 Mass migration sweep (148 examples)
  JM-6 Cleanup + docs
```

**Visible-progress estimate (turn 319 close):** ~70% of remaining
surface area shipped.  Pre-docking sprint complete (3.5b ✅ 3.6 ✅
3.7 ✅ 5.1 ✅) and docking arc opened (5.5a-c ✅).  Big remaining:
Docking 5.5d-h (5-10 turns), TabBar follow-ups (3-4), flag waves
(12-18), Phase 2 dev tools (2-4), Phase 4 cleanup (4-6), capstone
+ JM (5-8).  Estimated arc close ~30-50 turns from here.

---

## 2. Architectural foundations (current state)

The 1.5.5 refactor (turn 309d) settled the core architecture.  Any
new step should fit into THIS shape:

### 2.1 Layout & scope

- **`Window`** — persistent across frames, stored in `ctx.windows`
  keyed by hashed string ID.  Top-level windows AND children are
  both `Window`s.  Discriminated by `flags.is_child` (a
  `WindowFlags` field).  Each window owns its `pos`, `size`,
  `scroll_y`, `scroll_max_y`, `last_frame_active`, `parent_id`,
  `draw_list`, `clip_rect_stack`, debug `name_buf`/`name_len`, and
  one `layout: LayoutScope`.
- **`LayoutScope`** — all per-scope layout state in one struct.
  Lives on `Window.layout`.  Fields: `origin`, `work_rect_max`,
  `cursor_pos`, `cursor_max`, `cursor_pos_prev_line`,
  `line_height`, `prev_line_height`, `indent_x`, `last_item_*`.
  Re-installed fresh at `openWindow` / `beginChildImpl`.
- **`UiContext.window_stack`** — bounded stack of currently-open
  `Window*`s.  `current_window` is the top of stack.  `beginChild`
  pushes; `endChild` pops.  Inner/outer scope is purely stack-position.
- **`UiContext.id_stack`** — parallel stack of `Id`s for nested
  scope-aware widget ID hashing.  Pushed at `openWindow`,
  `beginChild`, `treeNode`, `pushId`.

### 2.2 Drawing

- **`DrawList`** — per-window command queue.  Widgets append
  `cmd` enums (rect, text, image, push_clip, pop_clip, ...).  At
  endFrame, every window's draw list replays to GL in submission
  order.
- **`clip_rect_stack`** — per-window stack.  `pushClipRect` /
  `popClipRect`.  Replayed alongside the draw list via push/pop
  cmds.

### 2.3 Input

- **`InputSnapshot`** — built once at `beginFrame` from
  `runtime.input.InputState`.  Frozen for the rest of the frame.
  Mouse pos/buttons/wheel, char queue, ~10 keyboard keys.
- **`active_id`** — single-slot "this widget is being interacted
  with right now."  Click-to-activate, release-to-deactivate.
- **`hovered_window_id`** — set during `openWindow`.  Top-level
  window the mouse is over.  Children do NOT update this currently
  (potential rework when Step 5.5 docking lands).
- **`mouse_wheel_consumed`** — per-frame flag.  Inner children
  consume first via LIFO `endChild` ordering.

### 2.4 Persistence (in-memory today)

- **`UiContext.windows: HashMap(Id, *Window)`** — survives across
  frames.  Last-frame-active tracking enables future GC sweep
  (filed but not implemented).
- Per-window: scroll position, focus, last-known pos/size,
  user-resized flag, dock node ref (filed, not implemented),
  parent_id chain.

Disk persistence: not yet wired (Step 5.1).

### 2.5 What stays brittle / needs care

- **`active_id` is single-slot.**  Two simultaneous drags (e.g.
  scrollbar + drag-drop) would fight.  Imgui has the same shape;
  hasn't bitten yet.
- **`hovered_window_id` tracks top-level only.**  Per-child hover
  works via `pointInRect` checks at the call site.  Step 5.5
  docking may want deeper hover tracking.
- **No popup/modal blocking.**  `isItemHovered({ .allow_when_blocked_by_popup = true })`
  is plumbed but no-op because we don't yet block.  Will activate
  when popups gain a "modal mask" frame.
- **No keyboard nav.**  Cursor-keys focus traversal is a future
  arc.  Several `HoveredFlags` no-op for this reason.

---

## 3. The pre-docking sprint (Steps 3.5b → 3.7 → 5.1) — ✅ CLOSED at turn 318

All four steps shipped.  Section retained for the per-step specs;
the contiguous architectural-coherence motivation still applies as
documentation of why these were grouped together.  The docking arc
(Step 5.5, section 4 below) opened at turn 319.

### 3.5b — `ChildFlags` + opts-arg sweep

**Scope:**  Replace the ad-hoc `BeginChildOpts { border: bool,
padding: f32 }` with imgui-parity `ChildFlags`.  Same turn, also
sweep the codebase replacing every `xxxEx(..., flags)` method
with a single `xxx(..., opts)` that takes the flags struct.

`ChildFlags` (10 fields per imgui 1.92.8):
- `border`, `always_use_window_padding`, `resize_x`, `resize_y`,
  `auto_resize_x`, `auto_resize_y`, `always_auto_resize`,
  `frame_style`, `nav_flattened`.

Opts-arg sweep targets (turn 312 dual API and any prior `Ex`
splits):
- `isItemHovered(opts: HoveredFlags = .{})` — kill `isItemHoveredEx`.
- `isWindowHovered(opts: HoveredFlags = .{})` — kill `isWindowHoveredEx`.
- `isWindowFocused(opts: FocusedFlags = .{})` — kill `isWindowFocusedEx`.
- Audit existing `*Ex` methods: keep where the Ex variant takes
  semantically-different args (e.g. `treeNodeEx` takes label+opts
  vs `treeNode` takes just label — the OPTS variant becomes
  `treeNode(label, opts: TreeNodeOpts = .{})`).
- Document the policy as Style Rule 14 in `claude.md`.

**Acceptance:** all `Ex` variants either renamed-and-merged or
explicitly justified in a code comment.  No new `Ex` from this
arc forward.

**Build can be broken during this sweep.**  ~25 callsites for
hover/focus alone, more for the broader sweep.  Land in one big
turn.

### 3.6 — `TabBar` widget + `TabBarFlags` + `TabItemFlags`

**Scope:**  `beginTabBar(str_id, opts) bool` / `endTabBar()`.
`beginTabItem(label, *open_bool, opts) bool` / `endTabItem()`.
Reorder via drag, close button on tabs, overflow → "..." menu.

Imgui ref: `imgui_widgets.cpp:8044` (BeginTabBar).

**Why now:** docking leaves are tab bars.  We need this widget to
ship working before docking lands.

**Acceptance:** `examples/ui_tabbar_tour.zig` — 5-tab demo,
draggable reorder, closeable per-tab, overflow menu when narrow.
Tests: 6-8 unit tests covering tab-add/remove, reorder, selection,
close-button click.

### 3.7 — `DragDropFlags` + `ItemFlags` + DragDrop polish

**Scope:**  Adds `DragDropFlags` to existing
`beginDragDropSource`/`Target`/`acceptDragDropPayload`:
`source_no_preview_tooltip`, `source_no_disable_hover`,
`source_no_hold_to_open_others`, `source_allow_null_id`,
`source_extern`, `payload_auto_expire`,
`accept_before_delivery`, `accept_no_draw_default_rect`,
`accept_no_preview_tooltip`, `accept_draw_as_hovered`.

`ItemFlags` (cross-widget): `no_tab_stop`, `button_repeat`,
`disabled`, `no_nav`, `no_nav_default_focus`,
`selectable_dont_close_popup`, `mixed_value`,
`read_only`, `no_window_hover_clearance`, `allow_overlap`.

**Why now:** docking uses drag-drop for dock targets.  `disabled`
+ `allow_overlap` are widely useful.

**Acceptance:** all DragDrop flags plumbed; `disabled` flag on
buttons/selectables actually grays out + suppresses click;
`allow_overlap` lets overlapping items both be hovered.

### 5.1 — Persistence (`.zon` + localStorage)

**Scope:**

Zig side (`src/ui.zig`):
- `UiContext.persistence_key: ?[]const u8`.
- On endFrame every N frames (or on shutdown hook): serialize
  per-window state to `.zon` text via `std.zon`:
  - `pos`, `size`, `scroll_y`, `collapsed`, `user_resized`.
  - (Future: dock node tree once Step 5.5 lands.)
  - (Future: table column order/widths when Step 4.1 lands.)
- On startup: read the persisted `.zon`, populate `ctx.windows`
  before any user `beginFrame`.

TS side (`src/web/zimr.ts`):
- `js_persistence_save(key_ptr, key_len, val_ptr, val_len)` →
  `localStorage.setItem("zimr_" + key, val)`.
- `js_persistence_load_start(key_ptr, key_len)` → handle-based
  async-like load (same protocol as fetch/clipboard).
- Quota-exceeded / missing-key handling.

Smoke harness: stub the persistence externs to in-memory.

**Acceptance:**  `examples/ui_persistence.zig` — drag the window,
move the splitter in `ui_panes`, refresh page, layout stays.  The
"we did it better than imgui" screenshot.

### After 5.1: TabBar gets persistence

Wire the selected-tab index into the persistence layer.  Tiny —
~1 turn.

---

## 4. Step 5.5 — DOCKING (IN PROGRESS)

The milestone. Original estimate 8-15 turns; ~6 sub-steps shipped
across turns 319-324, ~7-10 turns remaining (now broken into more
sub-steps after the imgui source audit).

### 4.0 Source-of-truth policy

**The C++ docking branch of imgui is the reference implementation.**
Default behavior when in doubt: do what imgui does. The full source
is at `/tmp/imgui-docking/` (extracted from the zip Simon uploaded);
section 10 of `src/notes/docking-vs-imgui.md` maps every concept to
its imgui line number.

Divergences from imgui are allowed but must be **documented** —
either in the code comment at the divergence point or in the
plan, with a brief rationale. The audit (`docking-vs-imgui.md`)
catalogs all known divergences and labels each:
- **JUSTIFIED** — we made the right call (Zig idiomatic, browser
  incompatibility, simplicity wins outweigh feature parity).
- **PARTIAL** — divergent today; revisit when a related sub-step
  lands (e.g. SizeRef-vs-ratio gets reconsidered at 5.5i).
- **NO** — we diverged but shouldn't have; queued for follow-up
  (these became 5.5e/f/g/h).

When implementing a new sub-step, the workflow is:
1. Read the relevant section of `docking-vs-imgui.md`.
2. Open the imgui source at the line numbers in section 10 of
   that doc.
3. Mirror the structure unless a documented reason says
   otherwise.
4. If you diverge, add a comment naming the deliberate departure
   and add an entry to the decision log if it's substantial.

### 4.1 Implementation status (turn 325)

**Shipped (5.5a-d):**
- `src/ui_dock.zig`: ~1040 LOC, 20 tests. Full data layer.
  `DockNode` with split/leaf optionals (vs imgui's `IsSplitNode()`
  pattern). `DockContext` owns the node pool, deferred
  `pending_requests` (mirrors imgui's `Requests` ImVector +
  `DockContextProcessDock` drain).
- Public API: `dockSpace`, `dockBuilderSplitNode`,
  `dockBuilderDockWindow`, `dockBuilderRemoveNode`,
  `dockBuilderFinish` (9/19 of imgui's public surface, all the
  high-value ones).
- `Window.dock_node_id: ?Id` + `findOrCreateWindow` reads
  pos/size from leaf when docked. Equivalent to imgui's
  `Window.DockId` + `DockNode->Pos/Size` flow.
- `openWindow` gates docked windows (mirrors imgui's
  `BeginDocked`); selected docked windows skip chrome.
- `flushDockTabsToForeground` defers tab-bar rendering to
  endFrame — *justified divergence* from imgui's inline
  rendering in `DockNodeUpdateTabBar`, fixes a frame-1
  ordering bug imgui itself documents as a footgun.
- Title-bar drag tracks `dragging_window` with 8px chebyshev
  threshold (mirrors imgui's `MouseDragThreshold`); release
  enqueues `DockRequest`.
- 5-zone overlay rendered + hit-tested. *Divergent today:*
  fixed pixel zones vs imgui's adaptive sizing (5.5e fix);
  rect hit-test vs imgui's radial-threshold (5.5e fix).

**Justified divergences from imgui (locked in):**
- `Id` (u32) for node refs instead of `*ImGuiDockNode` pointers.
  Safer, serializable, free moves. Trades a HashMap lookup per
  access for safety; invisible at our scale (~10 nodes).
- No `Want*` transient bool state machine — every mutation
  routes through `pending_requests` and drains synchronously
  in `processRequests` at endFrame. Cleaner; possible because
  we designed the boundary upfront rather than evolving from
  an existing widget framework.
- Deferred tab-bar rendering at endFrame via
  `flushDockTabsToForeground` — fixes the ordering quirk
  documented in imgui's own wiki.
- `.zon` + localStorage for persistence instead of `.ini` text.
  Only browser-compatible path; parses via `std.zon.parse` in
  ~10 LOC.
- No multi-viewport / OS-window detachment. Browser-incompatible.
- No `WindowClass` typed docking. Out of scope; sparse adoption
  even in imgui projects.
- No separate `HostWindow` child-window-per-dock-node. Our
  "write into the parent window's draw list" is simpler and
  works for our scope.

### 4.2 Sub-steps remaining

The audit landed on 8 follow-ups (5.5e-l). The first 4
(e/f/g/h) are small parity-recovery wins that should ship
before the bigger 5.5i-l work — each is ≤1 turn.

#### 5.5e — Drop hit-test parity (NEXT)

**imgui:** `DockNodeCalcDropRectsAndTestMousePos`
(imgui.cpp:19897). Adaptive zone size:
`hs = min(fontSize * 1.5, max(fontSize * 0.5, parent_smaller_axis / 8))`.
Radial hit-test: distance-from-center thresholds give "center
vs sides" decisions, reducing flicker when the cursor moves
diagonally between zones.

**zimr today:** Fixed 36px zones, simple rect-contains.
**Action:** Adopt both. ~30 LOC change in `dockTargetZonesFor`
and `hitTestDockTargetsInSubtree`. Keep zone-cross visual
geometry but compute sizes from font + leaf dim.

#### 5.5f — DockNodeFlags

**imgui:** Three-tier flag system (`SharedFlags`, `LocalFlags`,
`LocalFlagsInWindows`) merged into `MergedFlags`. Many flags
defined in `ImGuiDockNodeFlags_` (imgui.h:~1100 +
imgui_internal.h).

**zimr today:** No per-node flags at all.

**Action:** Add a single `flags: DockNodeFlags` (u16) per
`DockNode`. Flatten the Shared/Local tiering — every flag is
just "set on this node, applies to this node". Justified
simplification: the Shared inheritance is mostly for
`PassthruCentralNode` propagation, which we can compute from
root → leaves at layout time.

Initial flag set:
```zig
pub const DockNodeFlags = packed struct(u16) {
    no_split: bool = false,           // imgui:NoDockingSplit
    no_tab_bar: bool = false,          // imgui:NoTabBar
    hidden_tab_bar: bool = false,      // imgui:HiddenTabBar (toggleable)
    no_resize: bool = false,           // imgui:NoResize
    no_docking_over_me: bool = false,  // imgui:NoDockingOverMe
    no_close_button: bool = false,     // imgui:NoCloseButton
    passthru_central: bool = false,    // imgui:PassthruCentralNode (root-only)
    is_central: bool = false,          // imgui:CentralNode marker (one per dockspace)
    is_dockspace: bool = false,        // imgui:DockSpace (root distinguisher)
    _padding: u7 = 0,
};
```

Wire into `splitNode` (flags transfer per imgui:20201-20210
with our simplification: child gets a clean slate except the
`is_central` bit moves to the inheritor, `is_dockspace` stays
on the parent only). ~1 turn.

#### 5.5g — CentralNode layout logic

**imgui:** Special-case in `DockNodeTreeUpdatePosSize`
(imgui.cpp:20322-20332): if one sibling has `HasCentralNodeChild`
and the other has explicit `SizeRef`, the non-central one keeps
its `SizeRef` and central takes the remainder.

**zimr today:** Every leaf scales proportionally with the
parent split's ratio. No central concept.

**Action:** Add `is_central` flag (in 5.5f). In `layoutSubtree`,
when both children's subtrees contain a central descendant flag,
check if exactly one side has non-null `size_ref` (which lands in
5.5i). If yes: fix that side at `size_ref`, give the other (containing
central) the remainder. Falls through to ratio behavior otherwise.
~30 LOC. **Depends on 5.5i for `size_ref` — defer until then.**

Reorder: do 5.5i BEFORE 5.5g.

#### 5.5h — Pre-dock pos/size

**imgui:** `AuthorityForPos/Size` 3-bit fields on `DockNode`
record whether the window's pos/size is authoritative from the
DockNode or the Window. Lets the window restore its pre-dock
pos/size when undocked.

**zimr today:** When a docked window is undocked, it stays at
the last leaf rect.

**Action:** `Window.pre_dock_pos: ?Vector2`,
`Window.pre_dock_size: ?Vector2`. Stash at first dock (when
`dock_node_id` transitions null→non-null in
`dockBuilderDockWindow` or in `processRequests`'s `dock_as_tab/
dock_as_split` handlers). Restore + clear in `undockWindow`.
~30 LOC, ~½ turn.

#### 5.5i — Splitter resize + SizeRef-equivalent

**imgui:** `DockNodeTreeUpdateSplitter` (imgui.cpp:20396) +
`SizeRef[axis]` stored per-child. Splitter drag modifies
`SizeRef` (absolute pixels); dockspace resize preserves it.
Special handling for `WantLockSizeOnce`.

**zimr today:** No splitter widget on dock boundaries. `ratio:
f32` is normalized, so dockspace resize scales children
proportionally — wrong UX for "fixed-width left panel".

**Action:** Add `size_ref: ?f32` per child slot in `SplitData`
(`null` = follow ratio; non-null = lock this child at this
pixel size on dockspace resize). Splitter widget reuses the
existing 1.4 splitter (`splitterImpl`) — adapt for dock
boundaries. On splitter drag, update both `ratio` AND
`size_ref` for the dragged side. ~80 LOC, ~1-2 turns.

#### 5.5j — Tab close + drag-detach + drag-reorder

**imgui:** Reuses `BeginTabBarEx` / `TabItemEx` in
`DockNodeUpdateTabBar` (imgui.cpp:19503). Gets close,
drag-reorder, drag-detach, tooltips, window-menu button for
free from the tab bar widget.

**zimr today:** Custom mini-tab implementation in
`renderDockLeafTabBars`. No close, no reorder, no detach.

**Action:** Refactor `beginTabBar` to accept either string-id
keying (existing) OR window-id keying (new). Then replace
`renderDockLeafTabBars` with a real `beginTabBar/beginTabItem`
loop. Close, reorder, detach all fall out. Estimated ~3-5
turns (the refactor of beginTabBar is the bulk; the docking
side is a thin wrapper).

Drag-detach UX: a docked window dragged out goes straight to
floating (bare, no tab-bar-as-host group). Documented divergence
from imgui's "floating dock node with tab bar" pattern; the
simpler UX matches our scope.

#### 5.5k — Settings serialization

**imgui:** `DockNodeSettings` array in `ImGuiDockContext`,
written/read via `DockSettingsHandler_*` callbacks
(imgui.cpp:~21340). `.ini` text format.

**zimr:** Extend `ui_persistence.zig` with `DockNodeSettings[]`:

```zig
pub const PersistedDockNode = struct {
    id: u32,
    parent_id: ?u32,
    // Split node fields (null for leaves):
    split_axis: ?SplitAxis = null,
    split_ratio: f32 = 0.5,
    size_ref_a: ?f32 = null,  // post-5.5i
    size_ref_b: ?f32 = null,
    child_ids: ?[2]u32 = null,
    // Leaf node fields (null for splits):
    window_names: ?[]const []const u8 = null,  // by name, not id
    selected_window_name: ?[]const u8 = null,
    // Flags shared between both:
    flags: u16 = 0,
};
```

`.zon`-stringify on save, parse on load. `apply` populates a
`pending_dock_state` map; `dockSpace()` first-creation reads
the staged tree and rebuilds it. ~1-2 turns.

#### 5.5l — Demos polish

- `examples/ui_dock_persistence.zig` — same scene as
  ui_dock_basic but with `ctx.persistence_key = "..."` so the
  layout round-trips through localStorage.
- `examples/ui_full_showcase.zig` — add a Docking tab. ~1 turn.

### 4.3 Data structures — current state

```zig
// In src/ui_dock.zig — actual implementation, with planned 5.5f/5.5i fields:
pub const DockNode = struct {
    id: Id,
    parent_id: ?Id,
    pos: Vector2 = .{ 0, 0 },
    size: Vector2 = .{ 0, 0 },
    flags: DockNodeFlags = .{},   // ADDED in 5.5f
    generation: u32 = 0,
    split: ?SplitData = null,
    leaf:  ?LeafData  = null,
};

pub const SplitData = struct {
    axis: SplitAxis,
    ratio: f32,
    child_ids: [2]Id,
    size_ref: [2]?f32 = .{ null, null },  // ADDED in 5.5i
};

pub const LeafData = struct {
    window_ids: std.ArrayListUnmanaged(Id) = .empty,
    selected_window_id: Id = 0,
};

pub const DockContext = struct {
    nodes: std.AutoHashMapUnmanaged(Id, *DockNode) = .{},
    dockspaces_this_frame: std.ArrayListUnmanaged(Id) = .empty,
    pending_requests: std.ArrayListUnmanaged(DockRequest) = .empty,
    dragging_window: ?Id = null,
    next_node_id: Id = 1,
};

pub const DockRequest = union(enum) {
    dock_as_tab:     struct { target_node: Id, source_window: Id },
    dock_as_split:   struct { target_node: Id, source_window: Id, dir: Dir },
    undock:          struct { source_window: Id },
    split_dockspace: struct { target_node: Id, dir: Dir, ratio: f32 },
};
```

Mapping to imgui equivalents in `src/notes/docking-vs-imgui.md`
section 10.

### 4.4 What's NOT in scope (justified omissions)

These are deliberate departures from imgui — captured here so we
don't accidentally re-introduce them later thinking they're
missing.

- **Multi-viewport / OS-window detachment.** Browser-incompatible.
- **`WindowClass` typed docking.** Out of scope; sparse adoption.
- **`AutoHideTabBar` mode.** Punt for now (UX nicety).
- **`KeepAliveOnly` for dockspaces in tab content.** Add if/when
  we put dockspaces in tab content.
- **`DockSpaceOverViewport` convenience wrapper.** Add if/when
  needed; today users call `dockSpace(...)` directly inside their
  host window.
- **`DockBuilderCopyNode`/`DockBuilderCopyDockSpace`.** Layout
  cloning is rare; skip.
- **OS cursor changes during drag.** Possible via CSS but low ROI.
- **"Floating dock node" as host window with tab bar.** Drag-detach
  goes straight to bare floating window. Documented in 5.5j.

### 4.5 Demos (final state)

- `examples/ui_dock_basic.zig` — 3 pre-docked windows in 30/70
  split. Already shipped (turn 319).
- `examples/ui_dock_persistence.zig` — same but layout
  round-trips through localStorage. 5.5l.
- `examples/ui_full_showcase.zig` gets a Docking tab. 5.5l.

---

## 5. Post-docking: the long tail

### Phase 2 — Dev tools (now positioned AFTER docking)

The repositioning rationale: dev tools have something to debug
once docking lands.  IDStack + Metrics + DebugLog all give better
value once the system they introspect is complex.

- **2.1 Metrics + About.**  Frame timing, draw-call count,
  vertex counts, window list, style preview.  Panel on
  `imgui_demo.zig`.
- **2.2 DebugLog + IDStack + long-press bridge.**  Long-press
  fires right-click at the input layer (~20 LOC in
  `runtime/input.zig`).  IDStack shows hash chain for any clicked
  widget.

### Phase 3 remaining (flag waves, mostly mechanical)

- **3.1 WindowFlags** (30 flags) + horizontal scroll API.
- **3.2 TableFlags** (35) + `TableColumnFlags` (23).
- **3.3 InputTextFlags** (27) + `ColorEditFlags` (29).
- **3.4 TreeNode/Selectable/Slider/Button** flag cleanups.

Each ships one `ui_<group>_flags_tour.zig` demo.

### Phase 4 — Cleanup

- **4.1 Table queries + cell bg + angled headers.**
- **4.2 Cursor/item-query gaps + drag ranges + color converters
  + checkboxFlags.**  `Color.toHSV()` ambition marker lands here.
- **4.3 KeyboardKey expansion + popup variants + theme presets +
  `show*` family** (about/userGuide/styleSelector/version).

### Phase 5 remaining

- **5.2 Logging family** (`logToConsole`, `logToClipboard`,
  `logText`, `logSetNextTextDecoration`).
- **5.3 DrawListSplitter** for layered drawing.

### Phase 6 — Capstone close

- Polish all `ui_full_showcase` tabs.
- Full CHANGELOG arc-close entry.
- Move this plan to `archive/`.
- Update `PLAN.md`: imgui row complete.
- Regenerate cheatsheet one last time.

---

## 6. Cross-cutting policies

### 6.1 Build-breakage policy (turn 313)

**Build can be broken DURING a single turn's work** if it leads to
a cleaner final state.  Don't constrain edits to keep the build
green at every intermediate point.  Acceptance: build green at the
END of the turn.

### 6.2 API breaking-change policy (turn 313)

Mid-arc, breaking changes are encouraged when they produce a
better system.  No deprecation warnings, no stability commitments
until arc close.  Sweep mechanical migrations as they're noticed.

### 6.3 Opts-arg over Ex-variants (turn 313)

Rule 14 (proposed addition to claude.md): functions with optional
behavior take an `opts: FooOpts = .{}` arg.  No `xxxEx` variants
unless the Ex form takes semantically-different args (e.g.
different type signature, not just "+flags").

### 6.4 Untyped-local fix-on-contact (turn 311)

Rule 2 (already in claude.md): when editing a function, any
`const x = ...` without an explicit type gets one added.

### 6.5 Audit gate (turn 311)

- Every turn: `zig build test` green.
- Focused smoke (`-Dfocus=<arc>`, ~1s) every 3rd turn / arc close.
- Full smoke ONLY at arc close OR when a cross-arc invariant
  changes (input shape, draw-list cmd set, extern surface,
  `Window`/`Frame` public API).

### 6.6 Per-step deliverables

- Code in `src/ui.zig` (or sibling) following the 14 style rules.
- Host unit tests for each new public API.
- Demo per mixed-granularity model:
  - Standout features: own demo file.
  - Smaller features: extend existing demo.
  - Flag-waves: one tour file each.
  - `imgui_demo.zig` grows panels alongside.
- Each demo registers in `build.zig` + `manifest.json`.
- Standalone built + presented via `present_files` for phone test.

---

## 7. Sweep targets (cross-cutting, not tied to one step)

These get done incrementally OR in one focused turn — Simon's
call when a critical mass accumulates.

### 7.1 Opts-arg sweep (turn 313 commit, execute Step 3.5b)

Mentioned in 3.5b above.  Drop `isItemHoveredEx`,
`isWindowHoveredEx`, `isWindowFocusedEx`.  Audit for other `*Ex`.

### 7.2 Untyped locals in old code

~150 sites of `const x =` in `src/ui.zig`.  Per Rule 2: fix on
contact when editing the surrounding function.  No mass sed.

### 7.3 Zig 0.16 ceremony cleanup (filed Step 4.4 + 4.5)

827 sites of `@as(f32, @floatFromInt(X))`, 99 sites of
`@as(T, @intCast(x))`.  Most can drop the ceremony in 0.16.
Per-file scope in archived plan; incremental, no mass sed.

### 7.4 Banner-style section headers

Per claude.md Rule 4 update (turn 311): banners are encouraged in
long files.  Don't refactor away existing banners; add them
liberally to new sections in `ui.zig`.

---

## 8. Risks

### 8.1 Docking is genuinely hard

8-15 turn estimate but bottom of range optimistic.  The drag-drop
dock-target overlay rendering is the biggest unknown; everything
else has clear imgui reference code.

Mitigation:
- Read `imgui/imgui_internal.h` + `imgui.cpp:Begin` carefully
  BEFORE coding.  Cite line refs.
- Land in slices: data structures first (no rendering), then
  Begin() routing (no drag-drop), then drag-drop targets (no
  persistence), then persistence.

### 8.2 Persistence reentrancy

`endFrame` writing to localStorage means the next `beginFrame`
might see stale state if the JS round-trip lags.  Mitigation: keep
in-memory state authoritative; localStorage is a one-way mirror
flushed periodically.

### 8.3 TabBar can grow

TabBar has reorder, scroll-when-overflow, close button, "..."
menu.  Each adds complexity.  Mitigation: ship MVP without reorder
first; add reorder + overflow as follow-ups.

### 8.4 The plan keeps growing

Every step finds another thing.  Mitigation: this is normal for a
parity port.  Trust the v2 audit (`archive/imgui-parity-plan-v2.md`)
for "what does imgui have that we don't" — it stays factually
correct.

---

## 9. Out of scope

- Multi-viewport (popping windows out into OS windows).
- Allocator hooks (zimr's `gpa`-arg model covers what app code needs).
- va_list V-variants (varargs in Zig is comptime; not C-style).
- IME callbacks (paradigm-incompatible with browser-managed IME).
- Vulkan / Metal / D3D backends (WebGL2 is the contract).
- Editor / asset pipeline.
- Mobile native binding (wasm targets only).
- ImGuiWindowClass (typed-docking restriction).
- Auto-hide tab bar.

---

## 10. Where we might surprise ourselves

The "lookout for clever ways" notes from v3 still apply:

- **Capstone as a persistent app** once 5.1 ships.
- **`.zon` everywhere a config string lives** — not just persistence.
- **Touch-first widgets** (swipe-tabs, two-finger table zoom,
  pull-to-refresh).  Future arc.
- **Audio-feedback widgets** (slider hum, button click).  Tiny.
- **Subpixel / SDF text** for crisp scaling.  Future arc.

Not planned; flagged for opportunism.

---

## End

Next turn target: **3.5b — opts-arg sweep + ChildFlags.**  Big
turn — break the build mid-sweep is fine.  Read this plan,
`architecture-tutorial.md`, and `claude.md` Rule 14 (to be added
turn 313) before starting.
