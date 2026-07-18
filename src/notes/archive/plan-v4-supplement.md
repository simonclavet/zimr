# Plan v4 supplement: Architecture rework + Docking

Written turn 308 in response to: "we're hitting bugs because we're
diverging from imgui — should we bite the bullet now?" + "study
docking, we want feature parity with nice understandable code."

This document supplements `imgui-plan.md` (v3).  Where this document
contradicts v3, this wins.  After approval, v3 gets edited to
reflect the new ordering.

---

## 1. Recommendation in one paragraph

**Yes, bite the bullet.**  Insert one architectural step (call it
**Step 1.5.5**) before continuing the plan.  It does two things:
(a) factor out a `LayoutScope` struct holding all per-scope layout
state, and (b) make `beginChild` create a persistent sub-`Window`
indexed by hash, the way imgui does.  After 1.5.5 the four bugs we
just fixed become *structurally impossible*, and the docking work
becomes a clean addition rather than a fight against accumulated
divergence.

Then sequence: finish Phase 1 (scrolling is now trivial), pull
TabBar and DragDrop from Phase 3 forward, pull Persistence from
Phase 5 forward, and ship a new **Phase 5.5 — Docking** before the
remaining flag waves and cleanup.  Cleanup and dev tools become the
back end of the arc.

---

## 2. Why the architecture must change

The four turn-308 bugs all had the same root cause:

| Bug | Symptom | Root cause |
|---|---|---|
| `sameLine` | next widget on next row, not same row | no `cursor_pos_prev_line` separate from `cursor_pos` |
| `advanceLayout` | content in editor child clipped from left | row reset used `w.pos[0]`, not active scope's origin |
| splitter pos | bar at `cur + split_pos` (double offset) | API conflated state and offset |
| `treePop` indent | first widget after pop one indent too far right | push mutated 2 fields, pop only 1 |

All four are "same physical Window struct serves both as the window
and as the current layout scope, and the scope's state has been
ad-hoc.  Each new scope-context requirement (indent, child anchor,
child scroll, etc.) gets added as another field on Window without a
clean home."

The fix-as-we-go pattern works until it doesn't, and we just hit
the point where it doesn't.  Three more layout-related items are
queued in v3:

- **Step 1.6** — per-child scroll state.  This is *another* field
  that'd go on ChildState in the current model.
- **Step 1.5 closer** — Tree `draw_lines` flag (connector lines)
  needs per-scope tracking of "tree-node Y positions so far."
  Another ChildState field.
- **Step 5.1** — Persistence.  Wants to save scroll position per
  child.  Another piece of state to thread through.

Each of those is a sub-bug waiting to happen, and the cost of
adding them piecemeal is rising.

And then there's docking.

## 3. What docking requires from the architecture

Docking adds these to the system:

- **`DockNode` tree.**  Each node is either a split (two children +
  axis + ratio) or a leaf (a list of `Window*` + a `TabBar`).
  Persistent across frames; keyed by hash; survives across runs via
  settings.
- **`DockContext`.**  Owns the node tree + a request queue
  (Dock / Undock / Split, dispatched from drag-drop) + a registry
  of dockspaces.
- **`DockSpace(id, size)` public API.**  User declares "here's a
  region; whatever's docked into it appears here."
- **Drag-drop dock targets.**  When a window is being dragged, show
  drop-zone overlays over each visible dock node — center (=dock as
  tab), edges (=split this way).  Detect drop region, queue a
  request.
- **Window→Node binding.**  When `DockNode != null`, the window
  draws into the node's leaf rect (not its own pos/size), and its
  title bar is replaced by a tab in the node's tab bar.
- **`BeginDocked()` path in Begin.**  Conditionally mutate the
  window's pos/size from its node, hide chrome, route content
  drawing into the node's clip region.
- **Splitter between sibling dock nodes.**  Auto-rendered.  We
  already have the splitter widget.
- **Tab bar at each leaf node.**  Click a tab → set selected window.
  We *don't* have a TabBar widget yet (planned Phase 3.6).

What this means architecturally:

1. **Each docked window needs its own clean layout scope** that
   operates over its node's leaf rect.  If our layout machinery
   still conflates "window state" and "scope state", routing
   becomes brittle.
2. **Persistent state per window** (scroll, focus, dock node ref)
   must already work cleanly when docked.
3. **Persistent state per child** (scroll mainly) must work for
   beginChilds *inside* docked windows.  Same problem.
4. **TabBar widget exists and works correctly** — the leaf node
   uses it directly.
5. **DragDrop framework exists** — used for dock target detection.
6. **Settings serialization** of the dock node tree.

So docking pulls forward:
- TabBar (Phase 3.6 → earlier).
- DragDrop framework (Phase 3.6 → earlier).
- Persistence (Phase 5.1 → earlier).
- Window collapsed/chrome state (was deferred).

And it depends on:
- A clean LayoutScope abstraction so the "docked window writes into
  a node's leaf" routing doesn't trip on state-conflation bugs.

---

## 4. The architectural target: `LayoutScope` + child-as-Window

### 4.1 Two structs, not one

Today, zimr's `Window` carries everything:

```zig
pub const Window = struct {
    id, name, pos, size, scroll_y, scroll_max_y, focused, etc.
    
    // Layout-scope state, ad-hoc on Window:
    cursor_pos, cursor_max, line_height, pending_same_line,
    indent_x, layout_origin_x, last_item_id, last_item_rect,
    last_item_hovered, last_item_edited, ...
};
```

`ChildState` (a struct pushed onto `child_stack` in `beginChild`)
saves a parallel set of those fields so endChild can restore.  This
is the source of every "I forgot to save field X" bug.

Proposed split:

```zig
/// All per-scope layout state.  One of these lives on every
/// Window; beginChild creates a new Window (per §4.2) with its
/// own.  No more "save N fields manually."
pub const LayoutScope = struct {
    /// Where this scope's content area starts (screen px, top-left
    /// of inner rect).  Equivalent to imgui's
    /// `ImGuiWindow.Pos + style.window_padding` for a top window;
    /// for a child, the child rect's inner-top-left.
    origin: Vector2,
    
    /// Current cursor — where the next widget WILL place if there's
    /// no sameLine pending.
    cursor_pos: Vector2,
    /// Tracks bottom-right of laid-out content (for autosize / scroll_max).
    cursor_max: Vector2,
    
    /// (right_edge_of_last_item, top_of_current_row).  SameLine
    /// reads from here.  Imgui: `DC.CursorPosPrevLine`.
    cursor_pos_prev_line: Vector2,
    /// Tallest widget on the CURRENT row — accumulates as more
    /// widgets are added via sameLine.  Imgui: `DC.CurrLineSize.y`.
    curr_line_size_y: f32,
    /// Tallest widget on the PREVIOUS row — set when wrapping;
    /// SameLine restores `curr_line_size_y` from here.
    /// Imgui: `DC.PrevLineSize.y`.
    prev_line_size_y: f32,
    
    /// Indent depth.  TreeNode/indent() push, treePop/unindent pop.
    indent_x: f32,
    
    /// "Last item" bookkeeping — for IsItemHovered/Active etc.
    last_item_id: Id,
    last_item_rect: Rectangle,
    last_item_hovered: bool,
    last_item_edited: bool,
    last_item_clicked: bool,
    
    /// Whether the current cursor position came from SameLine.
    /// Imgui: `DC.IsSameLine`.  Reset by advanceLayout.
    is_same_line: bool,
};

/// Window-level state ONLY.  No layout-scope fields here.
pub const Window = struct {
    id: Id,
    name: []const u8,
    pos: Vector2,
    size: Vector2,
    
    // Persistent across frames:
    scroll: Vector2,
    scroll_max: Vector2,
    focused: bool,
    collapsed: bool,
    /// When non-null, this window is docked into the given node.
    /// Begin() routes through BeginDocked() in that case.
    dock_node: ?*DockNode = null,
    
    // Current frame's layout state:
    layout: LayoutScope,
    
    // Drawing:
    draw_list: DrawList,
    clip_rect_stack: ArrayList(Rectangle),
    
    // ... other window-level state ...
};
```

`advanceLayout` becomes:

```zig
fn advanceLayout(scope: *LayoutScope, consumed: Vector2, item_spacing: Vector2) void {
    const placed_at = if (scope.is_same_line) scope.cursor_pos else scope.cursor_pos;
    const right = placed_at[0] + consumed[0];
    const bottom = placed_at[1] + consumed[1];
    if (right > scope.cursor_max[0]) scope.cursor_max[0] = right;
    if (bottom > scope.cursor_max[1]) scope.cursor_max[1] = bottom;
    
    if (consumed[1] > scope.curr_line_size_y) scope.curr_line_size_y = consumed[1];
    
    // Update previous-line tracking BEFORE moving the cursor to next row.
    scope.cursor_pos_prev_line = .{ right, placed_at[1] };
    scope.prev_line_size_y = scope.curr_line_size_y;
    
    // Move to next row.
    scope.cursor_pos[1] = placed_at[1] + scope.curr_line_size_y + item_spacing[1];
    scope.cursor_pos[0] = scope.origin[0] + scope.indent_x;
    scope.curr_line_size_y = 0;
    scope.is_same_line = false;
}
```

`sameLine`:

```zig
pub fn sameLine(self: Ui, opts: SameLineOpts) void {
    const w = self.ctx.current_window orelse return;
    const s = &w.layout;
    const spacing = self.ctx.style.item_spacing[0];
    s.cursor_pos[0] = if (opts.offset_x > 0)
        s.origin[0] + opts.offset_x
    else
        s.cursor_pos_prev_line[0] + spacing;
    s.cursor_pos[1] = s.cursor_pos_prev_line[1];
    s.curr_line_size_y = s.prev_line_size_y;
    s.is_same_line = true;
}
```

`treePop`:

```zig
pub fn treePop(self: Ui) void {
    const w = self.ctx.current_window orelse return;
    if (w.layout.indent_x >= INDENT_AMOUNT) {
        w.layout.indent_x -= INDENT_AMOUNT;
        // Just update cursor X — advanceLayout's next-row reset would
        // naturally compute origin+indent; this catches the "first
        // widget right after pop" case.
        w.layout.cursor_pos[0] = w.layout.origin[0] + w.layout.indent_x;
    }
}
```

Notice: the four turn-308 bugs all become trivial.  `cursor_pos_prev_line`
fixes sameLine.  `origin` fixes the parent-vs-child bug.  Splitter is
unaffected (it's an API issue, fixed in place).  treePop becomes
naturally symmetric because indent and cursor live together in scope.

### 4.2 BeginChild creates a real sub-Window

Today's beginChild does `state push on parent.child_stack`.
Proposed: beginChild calls `findOrCreateWindow(child_id)` and
makes that child the active window.

```zig
fn beginChildImpl(ctx: *UiContext, str_id: []const u8, size: Vector2, opts: ChildOpts) bool {
    const parent = ctx.current_window orelse return false;
    const child_id = hashChildId(parent.id, str_id);
    
    // Find existing or create new — persistent across frames.
    var child = ctx.windows.get(child_id) orelse blk: {
        const w = ctx.gpa.create(Window) catch return false;
        w.* = .{ .id = child_id, .name = str_id, ... };
        ctx.windows.put(ctx.gpa, child_id, w) catch return false;
        break :blk w;
    };
    
    // Compute the child's outer rect anchored at parent's cursor.
    const at = resolveCursor(parent);
    child.pos = at;
    child.size = computeChildSize(parent, size);
    
    // Set up the child's layout scope fresh for this frame.
    child.layout = LayoutScope.init(child.pos[0] + opts.padding, child.pos[1] + opts.padding);
    
    // Active window now points to child.
    pushWindowStack(ctx, child);
    pushClipRect(child.draw_list, intersect(parent_clip, child.outer_rect()));
    
    return true;
}

fn endChildImpl(ctx: *UiContext) void {
    const child = ctx.current_window orelse return;
    const parent = popWindowStack(ctx);
    ctx.current_window = parent;
    popClipRect(child.draw_list);
    
    // Submit the child as an item on the parent — this is where the
    // parent's cursor advances.  Goes through the normal advanceLayout
    // path so sameLine after endChild works the standard way.
    submitItemRect(parent, child.outer_rect());
}
```

Three immediate wins:

1. **Per-child scroll for free.**  `child.scroll`, `child.scroll_max`
   are already on Window.  Step 1.6 collapses to "render a
   scrollbar widget when scroll_max > 0, route wheel input to the
   active window."
2. **Per-child focus + last-frame state for free.**  All of
   `last_item_*`, `focused`, etc. — already on Window.
3. **Clip-rect intersection.**  `pushClipRect` can be a proper
   stack that intersects with parent.  Fixes the latent nested-clip
   bug.

The cost is memory: one Window per beginChild call site.  But
Windows are keyed by hashed ID, so the same child reuses its
Window across frames.  Imgui has the same memory pattern; for an
app with 5-10 child windows, that's well under 100 KB of state.

### 4.3 What stays the same

- `UiContext` is unchanged structurally.  Still owns
  `windows: HashMap(Id, *Window)`.
- All public API.  `Ui.button(...)`, `Ui.beginChild(...)`, etc.
- Drawing pipeline (DrawList, draw command commands).
- Style, input, font state.
- Existing widget implementations — just point them at
  `w.layout.cursor_pos` instead of `w.cursor_pos`.  Mechanical
  rename.

---

## 5. Docking design (Phase 5.5 sketch)

Once §4 is in place, docking is a layered addition.  Components:

### 5.1 `DockNode` tree

```zig
pub const DockNode = struct {
    id: Id,
    parent: ?*DockNode,
    /// Split: two children + axis.  Leaf: null + null.
    children: [2]?*DockNode,
    split_axis: ?SplitterAxis,
    split_ratio: f32,  // children[0]'s size / total
    
    /// Leaf: list of windows docked here, in tab order.
    windows: ArrayList(*Window),
    /// Leaf: which tab is currently visible.
    selected_window_id: Id,
    
    /// Computed each frame — pos + size of this node's region.
    pos: Vector2,
    size: Vector2,
    
    /// "Last frame I was alive" — for sweeping dead nodes.
    last_frame_active: u32,
};
```

### 5.2 `DockContext`

```zig
pub const DockRequest = union(enum) {
    dock: struct { target_node: *DockNode, source_window: *Window, dir: ?Dir },
    undock: struct { source: *Window },
    split: struct { target_node: *DockNode, dir: Dir },
};

pub const DockContext = struct {
    /// All known nodes by ID.  Keyed by hashed string for stability.
    nodes: HashMap(Id, *DockNode),
    /// Active dockspaces this frame (DockSpace() calls fill this).
    dockspaces: ArrayList(Id),
    /// Queue of pending operations from drag-drop.
    pending_requests: ArrayList(DockRequest),
    /// While a window is being dragged, which one.
    dragging_window: ?*Window,
};
```

`UiContext` gains `dock: DockContext`.

### 5.3 `DockSpace` API

```zig
/// User submits a region inside a window where docking should happen.
/// Returns the root node's id (use for DockBuilder commands).
pub fn dockSpace(self: Ui, str_id: []const u8, size: Vector2, opts: DockSpaceOpts) Id {
    const ctx = self.ctx;
    const id = hashStr(ctx.current_window.?.id, str_id);
    
    // Find or create root node.
    var root = ctx.dock.nodes.get(id) orelse blk: {
        const n = ctx.gpa.create(DockNode) catch return 0;
        n.* = .{ .id = id, .parent = null, ... };
        ctx.dock.nodes.put(ctx.gpa, id, n) catch return 0;
        break :blk n;
    };
    
    // Compute the dockspace rect from current cursor + size.
    const at = resolveCursor(ctx.current_window.?);
    const actual_size = if (size[0] <= 0)
        u.getContentRegionAvail()
    else size;
    root.pos = at;
    root.size = actual_size;
    
    // Recursive layout: place each child node.
    layoutDockNodeTree(root);
    
    // Render: at each leaf, render tab bar + visible window's content.
    //         at each split, render splitter widget.
    renderDockNodeTree(root);
    
    // Submit as an item on the parent window so cursor advances.
    submitItemRect(ctx.current_window.?, .{ .x = root.pos[0], .y = root.pos[1], .width = root.size[0], .height = root.size[1] });
    
    return id;
}
```

### 5.4 `Begin()` integration

```zig
pub fn window(self: Ui, name, opts) ?WindowHandle {
    const ctx = self.ctx;
    const w = findOrCreateWindow(ctx, name);
    
    if (w.dock_node) |node| {
        // BeginDocked path: route through the node.
        beginDockedWindow(ctx, w, node);
    } else {
        // Floating path — current behavior.
        beginFloatingWindow(ctx, w);
    }
    
    return WindowHandle{ .ctx = ctx };
}

fn beginDockedWindow(ctx: *UiContext, w: *Window, node: *DockNode) void {
    // Window's pos/size come from the node's leaf rect (minus tab bar).
    const tab_h: f32 = ctx.style.tab_bar_height;
    w.pos = .{ node.pos[0], node.pos[1] + tab_h };
    w.size = .{ node.size[0], node.size[1] - tab_h };
    
    // Skip title bar render — the node draws the tab bar instead.
    w.layout = LayoutScope.init(w.pos[0] + padding, w.pos[1] + padding);
    
    // ... rest of window setup (clip, draw list, etc.) ...
}
```

### 5.5 Drag-drop dock targets

When the user grabs a window's title bar and starts dragging:

1. The window's dragging state becomes active (`ctx.dock.dragging_window = w`).
2. Each frame while dragging, iterate visible dock nodes.
3. For each node, compute 5 drop zones: center (dock as tab), top/right/bottom/left (split this way).
4. Render preview overlays for the zone under the mouse.
5. On release: queue the appropriate `DockRequest`.

### 5.6 Settings / persistence

Dock tree serializes as a flat list of `DockNodeSettings`:

```zig
pub const DockNodeSettings = struct {
    id: Id,
    parent_id: Id,
    split_axis: ?u8,
    split_ratio: f32,
    selected_window_id: Id,
    window_ids: []const Id, // for leaves
};
```

Saved/loaded through the Phase 5.1 persistence layer.  Round-trips
through localStorage in the demo.

### 5.7 What's NOT in scope

- Multi-viewport / popping windows out into OS windows.  Browser-
  canvas-incompatible per the existing plan.
- Window classes (`ImGuiWindowClass`).  Defer — most apps don't
  need typed docking.

---

## 6. Sequencing the work

```
Step 1.5.5  Architecture refactor — LayoutScope + child-as-Window      [✅ DONE turn 309d]
  ↓
Step 1.6    Per-child scrolling (mostly free now)                       [✅ DONE turn 310]
  ↓
Step 3.5+   HoveredFlags+FocusedFlags landed turn 312 (hover-delay
            deferred — needs HoverState).  Next sub-step: ChildFlags
            (natural follow-up to child-as-Window) + ComboFlags +
            PopupFlags before TabBar.                                   [in progress]
Step 3.6    Pull TabBar forward (docking prereq)
  ↓
Step 5.1    Pull Persistence forward (docking prereq)
  ↓
Step 5.5    DOCKING — DockContext, DockNode, DockSpace, BeginDocked,
            drag-drop targets, settings integration                     [milestone]
  ↓
Phase 2     Dev tools (Metrics, DebugLog, IDStack) — defer to after
            docking so they can debug docking issues themselves         [deferred]
  ↓
Phase 3 r.  Remaining flag waves (3.1 WindowFlags, 3.2 TableFlags,
            3.3 InputTextFlags+ColorEdit, 3.4 TreeNode/Selectable/etc.)
  ↓
Phase 4     Cleanup steps
  ↓
Phase 5 r.  Logging, DrawListSplitter
  ↓
Phase 6     Capstone
```

### Order rationale

1. **Refactor first.**  Every later step touches layout code; doing
   it on top of clean foundations is cheaper.
2. **1.6 immediately after refactor.**  Most of 1.6 is free because
   per-child scroll state is now on Window.  Smoke-test the refactor.
3. **DragDrop + TabBar before persistence before docking.**  Each is
   a docking prerequisite; the order is "needed-by" depth.
4. **Docking before remaining flag waves.**  Docking is the visible
   milestone — gets a real "we have arrived" demo.  Flag waves are
   important but mostly mechanical; doing them after docking means
   they shake out any rough edges with realistic usage.
5. **Dev tools deferred.**  Counterintuitive — v3 pulled them
   forward.  But after docking they have something REAL to debug,
   and the dock-tree visualization in DebugLog/Metrics will be
   one of their most useful features.
6. **Cleanup last.**  Standard.

### Estimated turn counts

| Step | Turns | Confidence |
|---|---|---|
| 1.5.5 refactor | 6-10 | medium — mechanical but wide |
| 1.6 scrolling | 2-3 | high — small surface after refactor |
| DragDrop framework | 4-6 | medium |
| TabBar widget | 3-4 | high |
| Persistence (5.1) | 4-6 | medium — TS bridge work |
| Docking (5.5) | 8-15 | low — biggest unknown |
| Phase 3 remaining | 12-18 | high — mostly mechanical |
| Phase 4 cleanup | 4-6 | high |
| Phase 5 remaining | 4-6 | high |
| Phase 6 capstone | 2-3 | high |
| **Total** | **49-77** | |

The current arc has been running ~50 turns since the last archive.
This puts arc-completion at ~100-130 turns of real work.

---

## 7. Risks

### 7.1 The refactor (1.5.5) is wider than it looks

Every widget reads/writes `cursor_pos`, `cursor_max`, `line_height`,
`indent_x`, `last_item_*`, `pending_same_line`.  All of those move
to `w.layout.*`.  ~30 widget impls touched.

Mitigation:
- Do it in one focused turn-block with no other work.
- Lean on the test suite (~1437 tests) to catch regressions.
- The rename is mechanical; pair with a focused-search-and-replace
  pass + careful audit at the end.
- Add semantic regression tests EARLY (e.g.
  `"sameLine: keeps same row"` already exists from turn 308) so
  any subtle break is caught at audit.

### 7.2 Per-child Window allocations could leak

Persistent state per child means each `beginChild` call site has a
permanent entry in `ctx.windows`.  If a child window's parent is
destroyed, its children should be GC'd.

Mitigation:
- Track `last_frame_active` on Window.  Every N frames, sweep
  windows that haven't been touched in M frames.  Imgui does this.
- Or: scope child window IDs to their parent — clean up when parent
  cleans up.

### 7.3 Docking is genuinely complex

The drag-drop preview rendering, split-axis math, leaf-tab-bar
state machine, and settings round-trip are each non-trivial.
8-15 turns is a wide range; reality could be 20+.

Mitigation:
- Phase the docking work itself: start with "windows can be docked
  but not undocked" → "drag undock" → "split via drag" → "tab
  switching" → "persistence."  Each is a deliverable.
- Use imgui's docking section as a literal porting reference — it's
  ~4000 lines but well-organized.

### 7.4 The refactor might unmask MORE latent bugs

Possibly good news (we fix them now) but possibly painful (turn
counts grow).

Mitigation:
- Budget for it.  Treat the refactor as a 6-10 turn window with
  flexibility to extend.

### 7.5 Phone testability during refactor

Mid-refactor, demos may visibly break (auto-layout drift while
fields are moving).  Hard to phone-test.

Mitigation:
- Do refactor work in small commits with tests as the primary
  feedback loop.  Phone test at end-of-day each turn day, not
  per-turn.

---

## 8. Decisions to make before starting

These are rubberduck questions to resolve in turn N+1.  Each has
an opinion noted, but Simon picks.

### Q1: Refactor scope — full LayoutScope, or minimal incremental fixes?

- **Option A.**  Full LayoutScope refactor as in §4.  Cleanest end
  state, longest turn count.
- **Option B.**  Incremental: add `cursor_pos_prev_line`,
  `prev_line_size_y` as direct fields on Window (no LayoutScope
  struct).  Each new bug → add the field.  Shorter per-turn cost
  but more drift over time.
- **Option C.**  Hybrid: do the LayoutScope split, but keep
  `beginChild` as state-pushes on `child_stack` for now.  Defer
  child-as-Window to Step 1.6 where it's naturally needed for
  per-child scroll state.

Opinion: **A**.  The marginal cost over C is small once we commit
to LayoutScope (the data needs to be groupable anyway), and the
child-as-Window step removes a whole class of "ChildState field
missing" bugs forever.  Doing it twice (now and at 1.6) is more
work than doing it once now.

### Q2: Pull-forward order for docking prereqs

- **Option A.**  TabBar → DragDrop → Persistence → Docking.
- **Option B.**  DragDrop → TabBar → Persistence → Docking.
- **Option C.**  Persistence → Drag → Tab → Docking (persistence
  first because the demo will use it heavily).

Opinion: **A**.  TabBar is the simplest — gets a quick win and a
ship demo (`ui_tabbar_tour`).  DragDrop is bigger; comes second
when momentum's up.  Persistence has TS bridge work that needs
focus — third.  Docking ties them together — last.

### Q3: Should refactor land BEFORE or AFTER promoting Step 1.5 to ✅?

Step 1.5 is functionally done — `treeNodeEx` works, tests pass,
demo works.  But there's a strong argument for finishing the
treeNodeEx flags that depend on per-scope state (`draw_lines`)
AFTER the refactor.

Opinion: **promote 1.5 ✅ now**.  The remaining flags (`draw_lines`,
hover-delay, etc.) live in Phase 3.4 anyway.  Don't conflate.

### Q4: How loud should the refactor be in the changelog?

The refactor will touch ~30 widgets in a sweeping change.  Two ways
to do the changelog:

- **Option A.**  One huge "Step 1.5.5: LayoutScope refactor" entry
  with full inventory.
- **Option B.**  Daily entries with running state.

Opinion: **A** with B-style daily snapshots during.  The huge entry
is the historical record; the daily snapshots are checkpoints in
case the refactor stalls and we need to look back.

### Q5: Should we adopt imgui's `DC.IsSameLine` as a real flag?

We removed `pending_same_line` in the turn 308 fix.  In LayoutScope,
imgui has `IsSameLine` — used by `ItemSize` to decide whether
`line_y1` is the previous row or current.

Opinion: **yes**.  Add `is_same_line: bool` to LayoutScope.  It
matches imgui's model and the resulting code reads more obviously.

---

## 9. Concrete first-turn work (Step 1.5.5, turn 1 of N) ✅ DONE turn 309

The plan above suggested strangler-fig.  In execution, I went
**big-bang** instead — Simon's "I trust you, let's go" signal
plus the realization that the rename is so mechanical (one of
~13 fields → `w.layout.<field>`) that strangler's safety margin
wasn't worth N turns of mirrored writes.

What actually shipped turn 309:

1. ✅ `LayoutScope` struct defined in `src/ui.zig` (~line 1481),
   with all 14 layout-scope fields owned by it.  Includes the
   NEW `cursor_pos_prev_line` + `prev_line_height` fields that
   match imgui's `DC.CursorPosPrevLine` / `DC.PrevLineSize.y`
   and fix the latent row-max-height bug.
2. ✅ `Window` slimmed.  All 14 layout fields removed; replaced
   by `layout: LayoutScope = .{}`.
3. ✅ `ChildState` collapsed from 7 saved fields to 1
   (`saved_layout: LayoutScope`).
4. ✅ `GroupState` dropped `saved_pending_same_line` (gone with
   `pending_same_line`).
5. ✅ `sameLine` / `advanceLayout` / `resolveCursor` / `treePop`
   rewritten per the new model.
6. ✅ `openWindow` / `beginChild` install fresh `LayoutScope`
   with `cursor_pos_prev_line` seeded to inner_origin.
7. ✅ ~352 callsites renamed via sed; collateral damage on
   `InputTextState.cursor_pos` / `InputTextCallbackData.cursor_pos`
   reverted explicitly.
8. ✅ 2 new regression tests pin row-max-height + cursor_pos_prev_line
   seeding semantics.
9. ✅ Audit (1439/1439 pass) + smoke (ui_panes 10741 GL calls,
   no crash) + standalone build.

**Child-as-Window — ✅ DONE turn 309d (Step 1.5.5 part 2).**

Shipped:
- New `WindowFlags` struct (struct-of-bools per Zig style; `is_child`
  is the only flag wired today, popup/tooltip/modal/dock_node land
  with their respective features).
- New `findOrCreateChildWindow(ctx, child_id)` — symmetrical to
  the existing `findOrCreateWindow`.  Children persist in
  `ctx.windows` keyed by hashed ID across frames.
- `beginChildImpl` rewritten to allocate/fetch a full Window,
  push onto `window_stack`, install fresh `LayoutScope` on the
  child.  Parent's layout untouched until endChild.
- `endChildImpl` rewritten — pops window_stack, advances parent
  via `advanceLayout`, sets parent's `last_item_rect` to child's
  outer rect (for `isItemHovered` after endChild).
- `openListBox` / `closeListBox` ported to the same pattern —
  the listBox is conceptually a child window with frame chrome.
- Clipper's viewport math simplified — reads `w.layout.origin[1]`
  and `w.layout.work_rect_max[1]` directly, no more child_stack
  peek.
- `ChildState` and `UiContext.child_stack` deleted entirely.
- Existing tests updated to read child rects from
  `ctx.current_window.?` rather than `ctx.child_stack`.
- New regression test pinning the persistence contract
  (`findOrCreateChildWindow` returns the same pointer for
  repeated calls with the same ID).

Audit: 1441/1441 pass.  Smoke: ui_panes unchanged (10741 GL
calls).  Standalone: `ui_panes-turn309d.html`.

Lesson worth keeping: pushing the window stack BEFORE flipping
`current_window` makes failure paths recoverable.  If
`window_stack.append` fails (OOM bounded-stack), we pop the ID
we already pushed and return false — invariants intact, caller's
`if (...)` block skipped.  The old in-place model had no such
recovery — once we'd mutated `w.layout`, we were committed.

---

## 9.1 What the big-bang taught me

- **Distinct types with identically-named fields are a landmine
  for blind text sed.**  `InputTextState.cursor_pos` (text-buffer
  index, `usize`) and `Window.cursor_pos` (layout cursor,
  `Vector2`) both used `cursor_pos`.  The sed rename clobbered
  the wrong one; reverted via a second targeted sed.  Next time:
  start with the rename on Window, fix compile errors one-by-one
  (typed compiler errors > text rules).
- **Struct-literal sites in tests** were the only true compile
  errors after the bulk rename.  All 5 were one-line fixes:
  `Window{ .cursor_pos = X }` → `Window{ .layout = .{ .cursor_pos = X } }`.
- **Empty defaults bit me once** — `cursor_pos_prev_line` defaulted
  to `(0, 0)`.  Caught by adding the seeding-test, which initially
  failed because `beginChild` didn't seed it.  Fixed by full-reset
  `LayoutScope` init at both `openWindow` and `beginChild` entry.

---

## 10. Out of scope for this rework (still v3 deferred)

- Multi-viewport (windows in separate OS windows).  Browser-canvas-
  incompatible.
- IME composition.  Browser-platform-incompatible.
- File-based persistence (`.ini`).  Replaced by zon + localStorage
  in Step 5.1.
- Allocator hooks.  Zig's gpa-arg model already covers this.
- WindowClass (typed docking restrictions).  Niche; defer.

---

## Appendix A: where imgui's docking lives

| Concept | imgui location | LOC |
|---|---|---|
| DockNode struct | `imgui_internal.h:2037` | ~100 |
| DockContext + requests | `imgui.cpp:17780-17850` | ~200 |
| Docking call-flow comment | `imgui.cpp:17721-17770` | ~50 |
| DockSpace public | `imgui.cpp` near 21500 | ~300 |
| DockNodeUpdate (per-frame) | `imgui.cpp` near 19000 | ~400 |
| Drag-drop targets | `imgui.cpp` near 20500 | ~300 |
| Settings I/O | `imgui.cpp` near 21500 | ~250 |
| Tab bar in dock node | `imgui.cpp` near 19500 | ~400 |
| Total | ~21692 - 17709 = ~4000 | |

Plus shared infra in imgui_internal.h: ~150 LOC of types.

The 4000-LOC section breaks down roughly:
- ~1000 LOC: drag-drop preview rendering and hit-testing.
- ~800 LOC: dock-request processing (Dock/Undock/Split state machines).
- ~700 LOC: DockNode tree manipulation (split, merge, rebalance).
- ~500 LOC: tab-bar-in-leaf rendering.
- ~500 LOC: settings serialization / round-trip.
- ~500 LOC: Begin/End integration, BeginDocked path.

For zimr, expect roughly 2/3 of that — simpler renderer, no
multi-viewport indirection, no platform-window callbacks.

## Appendix B: things the refactor DOES NOT need to do

The temptation will be to also:
- Refactor input handling.
- Refactor draw list to per-window-as-imgui-does (channels etc.).
- Refactor style-stack.
- Refactor ID stack.

Don't.  Each is independently good and independently scoped.  The
refactor is only about the LayoutScope split + child-as-Window.
Anything else is scope creep.

The audit gate at each step is:
- 1437/1437 (or growing) tests pass.
- All smoke tests pass.
- All standalone builds work.
- Phone screenshot for one demo matches expectation.

If any of these regress, stop and fix before moving on.
