# zimr Docking vs imgui Docking — Architectural Tutorial

Written turn 325 after re-reading imgui v1.92 docking branch source
(the actual `imgui-docking.zip` Simon supplied) and comparing
file-by-file with what we shipped in turns 319-324.

This is technical reference + decision log + roadmap. It catalogs
every meaningful structural difference between imgui's docking
implementation and ours, asks "is this divergence justified?",
and lands on a yes/no/partial per item. Items marked **NO** are
follow-ups; **YES** locks in our deliberate departures; **PARTIAL**
flags places where we chose differently and may need to revisit.

---

## 0. Scale

| Measure | imgui docking branch | zimr (turn 324) |
|---|---|---|
| Docking-only source | ~3,982 LOC in imgui.cpp `[SECTION] DOCKING` | ~1,038 LOC `src/ui_dock.zig` + ~650 LOC integration in `src/ui.zig` |
| Public/internal dock fns | 104 | ~25 |
| Per-frame call graph depth | ~12 layers (DockContextNewFrameUpdate→DockNodeUpdate→DockNodeUpdateForRootNode→…) | 3 layers (beginFrame→processRequests→flushDockTabsToForeground) |
| Years in development | ~8 (still "experimental") | ~6 turns |

imgui's docking branch is unfinished by its own author's admission —
Cornut's own wiki says "I am not happy with the current state of the
code… I want to rewrite it from scratch a third time." That doesn't
mean it's bad, it means the design space is genuinely hard. Our 6%
surface coverage isn't because we're better; it's because we cut
features (multi-viewport, window classes, settings .ini) that don't
apply to a browser-targeted lib.

---

## 1. Runtime context — why we're allowed to be smaller

zimr targets wasm32-wasi in a browser tab. Three of imgui's big
docking features are browser-incompatible:

- **Multi-viewport** — imgui drags a window into a NEW OS window
  (GLFW/SDL spawns a real platform window, imgui makes it a new
  `ImGuiViewport`). A wasm tab cannot spawn another window. We
  permanently can't have this.
- **OS cursor changes during drag** — imgui sets resize/move
  cursors via platform callbacks. Possible via CSS, but we'd be
  reinventing it.
- **`imgui.ini` file persistence** — wasm tabs don't write
  filesystem. Our Step 5.1 routes through `localStorage` via
  `extern "dom"` and uses `.zon` instead.

Everything else is "we just haven't yet."

---

## 2. Data structure: ImGuiDockNode vs DockNode

### imgui (imgui_internal.h:2037)

```cpp
struct ImGuiDockNode {
    ImGuiID                 ID;
    ImGuiDockNodeFlags      SharedFlags;            // from root
    ImGuiDockNodeFlags      LocalFlags;             // per-node
    ImGuiDockNodeFlags      LocalFlagsInWindows;    // from docked windows
    ImGuiDockNodeFlags      MergedFlags;            // computed
    ImGuiDockNodeState      State;
    ImGuiDockNode*          ParentNode;             // POINTER
    ImGuiDockNode*          ChildNodes[2];          // POINTERS
    ImVector<ImGuiWindow*>  Windows;                // unordered! see TabBar->Tabs
    ImGuiTabBar*            TabBar;
    ImVec2                  Pos, Size;
    ImVec2                  SizeRef;                // last explicit, in PIXELS
    ImGuiAxis               SplitAxis;
    ImU32                   LastBgColor;
    ImGuiWindowClass        WindowClass;            // typed docking

    ImGuiWindow*            HostWindow;             // floating dock host
    ImGuiWindow*            VisibleWindow;
    ImGuiDockNode*          CentralNode;            // root only
    ImGuiDockNode*          OnlyNodeWithWindows;    // root only
    int                     CountNodeWithWindows;
    int                     LastFrameAlive, LastFrameActive, LastFrameFocused;
    ImGuiID                 LastFocusedNodeId, SelectedTabId, WantCloseTabId, RefViewportId;
    ImGuiDataAuthority      AuthorityForPos     :3;
    ImGuiDataAuthority      AuthorityForSize    :3;
    ImGuiDataAuthority      AuthorityForViewport:3;
    bool                    IsVisible:1, IsFocused:1, IsBgDrawnThisFrame:1,
                            HasCloseButton:1, HasWindowMenuButton:1, HasCentralNodeChild:1,
                            WantCloseAll:1, WantLockSizeOnce:1, WantMouseMove:1,
                            WantHiddenTabBarUpdate:1, WantHiddenTabBarToggle:1;
};
```

**35 fields.**

### zimr (src/ui_dock.zig)

```zig
pub const DockNode = struct {
    id: Id,
    parent_id: ?Id,                 // Id, not pointer
    pos: Vector2,
    size: Vector2,
    split: ?SplitData = null,       // axis + ratio + [2]Id
    leaf:  ?LeafData  = null,       // window_ids + selected_window_id
    generation: u32,                // bumped on structural mutation
};
```

**5 fields + 2 union variants.**

### Divergence #1 — Pointers vs Ids

**imgui:** `*ImGuiDockNode` everywhere.
**zimr:** `Id` (u32). HashMap lookup at every access.

| | imgui | zimr |
|---|---|---|
| Lookup cost | 0 (deref) | ~10 ns (HashMap.get) |
| Dangling refs possible | YES | NO |
| Serialization | requires fixup pass | trivial |
| Move semantics | move requires patching all back-refs | free |

**Verdict: JUSTIFIED.** The HashMap overhead is invisible at our scale
(~10 nodes typical); the safety + serialization wins are real. imgui's
choice predates the language affordances we have.

### Divergence #2 — SizeRef (pixels) vs ratio (normalized)

This is the **biggest** structural decision, and the one most likely
to need revisiting.

**imgui:** `SizeRef[axis]` stores the last-explicit size in PIXELS.
At layout time (DockNodeTreeUpdatePosSize, imgui.cpp:20260), the
effective split ratio is computed as:

```cpp
float split_ratio = child_0->SizeRef[axis]
                  / (child_0->SizeRef[axis] + child_1->SizeRef[axis]);
```

Splitter drag updates `SizeRef` (absolute); dockspace resize preserves
the ratio implicitly. There's also `WantLockSizeOnce` which says "this
child's size is locked this frame, give the other the remainder" — used
for the central-node pattern.

**zimr:** `split.ratio: f32` stored directly. Splitter drag (5.5e,
planned) will modify ratio. Dockspace resize scales both children
proportionally.

**Implications when 5.5e lands:**

```
Initial:   dockspace 1000px, ratio 0.3 → left 300px, right 700px
Resize dockspace to 1200px:
  zimr:    left 360px, right 840px    (proportional — both grow)
  imgui:   left 300px, right 900px    (left stays fixed if SizeRef preserved)
```

The imgui behavior matches the most common dockspace UX: "I sized my
left toolbar to 300px; if the window grows, the editor area grows,
not the toolbar."

**Verdict: PARTIAL.** Our normalized ratio works for proportional
layouts and is the simpler abstraction, but breaks the "fixed-width
panel" UX that's typical of professional tools. When we ship 5.5e
(splitter drag), we should add a `size_ref: ?f32` per child — null
means "follow ratio", non-null means "lock to this pixel width on
dockspace resize". This is a small extension to our model that
recovers imgui's semantics without adopting the full SizeRef
machinery.

### Divergence #3 — Flag set (we have NONE)

imgui's `ImGuiDockNodeFlags_` (imgui.h, line ~1100):

```cpp
enum ImGuiDockNodeFlags_ {
    ImGuiDockNodeFlags_None                         = 0,
    ImGuiDockNodeFlags_KeepAliveOnly                = 1 << 0,
    ImGuiDockNodeFlags_NoDockingOverCentralNode     = 1 << 2,
    ImGuiDockNodeFlags_PassthruCentralNode          = 1 << 3,
    ImGuiDockNodeFlags_NoDockingSplit               = 1 << 4,
    ImGuiDockNodeFlags_NoResize                     = 1 << 5,
    ImGuiDockNodeFlags_AutoHideTabBar               = 1 << 6,
    ImGuiDockNodeFlags_NoUndocking                  = 1 << 7,
    // Internal (in imgui_internal.h):
    ImGuiDockNodeFlags_DockSpace                    = 1 << 10,
    ImGuiDockNodeFlags_CentralNode                  = 1 << 11,
    ImGuiDockNodeFlags_NoTabBar                     = 1 << 12,
    ImGuiDockNodeFlags_HiddenTabBar                 = 1 << 13,
    ImGuiDockNodeFlags_NoWindowMenuButton           = 1 << 14,
    ImGuiDockNodeFlags_NoCloseButton                = 1 << 15,
    ImGuiDockNodeFlags_NoDocking                    = 1 << 16,
    ImGuiDockNodeFlags_NoDockingSplitOther          = 1 << 17,
    ImGuiDockNodeFlags_NoDockingOverMe              = 1 << 18,
    ImGuiDockNodeFlags_NoDockingOverOther           = 1 << 19,
    ImGuiDockNodeFlags_NoDockingOverEmpty           = 1 << 20,
};
```

These let callers restrict per-node behavior. A common pattern:

```cpp
m_ribbonPanelID = DockBuilderSplitNode(m_mainDockspaceID, ImGuiDir_Left, 0.05f, ...);
DockBuilderGetNode(m_ribbonPanelID)->LocalFlags |=
    NoSplit | NoDockingOverMe | NoCloseButton | NoResize |
    HiddenTabBar | NoWindowMenuButton | NoTabBar;
```

Then the user can't accidentally dock a window onto the ribbon, can't
resize it past its fixed width, no chrome shows up. We can't do any of
this today.

**Three flag tiers in imgui:**
- `SharedFlags` — set on root, inherited down (`PassthruCentralNode` etc.)
- `LocalFlags` — saved per-node (the bulk; transferred during split)
- `LocalFlagsInWindows` — transient; OR'd from `WindowClass.DockNodeFlagsOverrideSet`
- `MergedFlags = SharedFlags | LocalFlags | LocalFlagsInWindows` — what
  `IsNoSplit()`, `IsNoTabBar()` etc. actually test.

**Verdict: NO — should add.** We can ship a single `flags: u16`
per node and the most-asked-for variants (`NoSplit`, `NoDockingOverMe`,
`NoResize`, `NoTabBar`, `HiddenTabBar`, `NoCloseButton`,
`PassthruCentralNode`). The Shared/Local/Merged tiering is overkill
for our use; one flat set per node is enough. Defer
`WindowClass`-driven `LocalFlagsInWindows` — that's part of the
typed-docking system we're not adopting.

### Divergence #4 — WindowClass (typed docking)

imgui's `ImGuiWindowClass` lets callers tag a window with a class
identifier; the dock node then accepts/rejects docks based on whether
the source's class matches the target's `WindowClass`. Used to
implement "only document tabs can dock into the document area".

**Verdict: JUSTIFIED — out of scope.** Adoption is sparse even in
imgui projects; the use case (multi-tier UI taxonomy) doesn't match
our scope.

### Divergence #5 — CentralNode

In imgui, a designated child of the root is "the central node" and
takes leftover space when surrounding leaves have explicit sizes.
The classic editor layout:

```
┌────┬─────────────┬────┐
│Lft │   Central   │ Rt │  ← Lft + Rt have SizeRef in pixels,
│    │   (editor)  │    │    Central absorbs the rest
├────┴─────────────┴────┤
│        Bottom         │
└───────────────────────┘
```

Currently in zimr, every leaf scales proportionally. There's no
"this one is the main view, give it whatever's left."

**Verdict: NO — should add.** A `is_central: bool` per-node flag
(part of the flag set above) + a check in `layoutSubtree`:

```zig
// If one sibling is central and the other has a SizeRef, fix the
// non-central at SizeRef and give central the remainder.
```

Useful pattern, small implementation surface (~30 LOC) once SizeRef
lands.

### Divergence #6 — HostWindow / floating dock nodes

In imgui, a dock node has a `HostWindow*`. For a docked-into-dockspace
node, the host is the dockspace's parent window. For a **floating
dock node** (a window that has OTHER windows docked into it — i.e.
not a dockspace, but a multi-tab floating window), the host is a
created floating window with a tab bar.

This is what makes imgui's "drag a docked tab out → it becomes a
floating window" work: the new floating window IS a dock node with
one window in it.

zimr today: a window is either docked-in-a-dockspace or fully
floating. We don't have floating dock nodes.

**Verdict: UNCLEAR — depends on 5.5f.** If we want drag-detach
where the detached window stays as a tab-bar-headed floating thing,
we need this. If detach goes straight to bare floating window, we
don't. The simpler UX (detach → bare floating) is what 1990s panel
systems did; the richer UX (detach → floating tab group) is what
modern IDEs do.

Recommendation: ship 5.5f as "detach → bare floating". Revisit if
users complain.

### Divergence #7 — AuthorityForPos / AuthorityForSize

3-bit fields (`ImGuiDataAuthority_None / DockNode / Window`)
recording who "owns" the docked window's pos/size. Lets the window
remember its pre-dock pos/size for restore-on-undock.

zimr today: `findOrCreateWindow` reads pos/size from the leaf when
`dock_node_id` is set. When the window undocks, it stays at the
last leaf rect (which isn't where it was before docking).

**Verdict: NO — should add.** Even a simple `pre_dock_pos/size:
?Vector2` on `Window` would fix the "undock → window snaps to weird
position" problem. Small change.

### Divergence #8 — State-machine "Want\*" fields

imgui has 11 transient bool flags on each node:
`WantCloseAll, WantLockSizeOnce, WantMouseMove,
WantHiddenTabBarUpdate, WantHiddenTabBarToggle, …`

These let imgui split frame-spanning operations into "this frame:
mark Want*"; "next frame: process Want* and clear". Required because
imgui mutates state during widget submission and can't always defer.

zimr: every mutation goes through `pending_requests: ArrayListUnmanaged(DockRequest)`,
drained synchronously by `processRequests` at `endFrame`. No state
machine, no per-node transient bools.

**Verdict: JUSTIFIED.** Our deferred-request pattern is cleaner.
imgui's Want* fields exist because they evolved the docking system
incrementally on top of an existing widget framework; we got to
choose the boundary upfront.

---

## 3. Drop zone hit-test

### imgui DockNodeCalcDropRectsAndTestMousePos (imgui.cpp:19897)

```cpp
const float parent_smaller_axis = ImMin(parent.GetWidth(), parent.GetHeight());
const float hs_for_central_nodes = ImMin(g.FontSize * 1.5f,
                                          ImMax(g.FontSize * 0.5f,
                                                parent_smaller_axis / 8.0f));
float hs_w = ImTrunc(hs_for_central_nodes);
float hs_h = ImTrunc(hs_for_central_nodes * 0.90f);
ImVec2 off = ImTrunc(ImVec2(hs_w * 2.40f, hs_w * 2.40f));

ImVec2 c = ImTrunc(parent.GetCenter());
// Five zones around `c` at offset `off`, sized hs_w × hs_h.
```

Adaptive zone sizing: zones scale with both font size AND leaf size.
A 200px-tall leaf gets smaller zones than a 1000px-tall one.

Then the **radial hit-test** (lines 19929-19946):

```cpp
ImVec2 mouse_delta = (*test_mouse_pos - c);
float mouse_delta_len2 = ImLengthSqr(mouse_delta);
float r_threshold_center = hs_w * 1.4f;
float r_threshold_sides  = hs_w * (1.4f + 1.2f);
if (mouse_delta_len2 < r_threshold_center * r_threshold_center)
    return (dir == ImGuiDir_None);                         // center wins
if (mouse_delta_len2 < r_threshold_sides * r_threshold_sides)
    return (dir == ImGetDirQuadrantFromDelta(mouse_delta.x, mouse_delta.y));
return hit_r.Contains(*test_mouse_pos);
```

Distance from leaf center decides which zone hits: close = center,
medium = whichever quadrant the mouse is in. This **reduces flicker**
when the cursor moves diagonally between zones — instead of going
"center → none → left" (with visible flicker on the gap), it goes
"center → left" directly.

### zimr dockTargetZonesFor + hitTestDockTargets

```zig
const ZONE_SIZE: f32 = 36;     // fixed
const CENTER_SIZE: f32 = 44;
const GAP: f32 = 4;
// Five literal rectangles, simple Contains() check.
```

Fixed pixel zones, simple rect hit-test, no radial heuristic.

**Verdict: NO — should adopt both improvements.** Adaptive sizing
is a one-line change (`zone_size = clamp(font_size * 1.5, font_size * 0.5, min_dim / 8)`).
Radial hit-test is ~10 lines and substantially improves UX. No
reason not to take both.

---

## 4. Tab bar rendering

### imgui DockNodeUpdateTabBar (imgui.cpp:19503)

Reuses the standard `BeginTabBarEx / TabItemEx` widgets. Windows
in the leaf are unordered (`node->Windows`), and tab ORDER comes
from `node->TabBar->Tabs`. This separation lets the user drag-reorder
tabs without affecting the underlying window list.

Features supported in the dock tab bar:
- Per-tab close button (`tab->WantClose`)
- Drag-to-reorder
- Drag-to-detach (drag tab out → undock window)
- Tab tooltips
- Window menu button (▾) for "show all hidden tabs"
- AutoHideTabBar (hide when one tab, show small triangle to expose)

### zimr renderDockLeafTabBars

```zig
// Custom mini tab strip, ~80 LOC.
// - Even widths per tab (no per-tab sizing)
// - One label per window via ctx.windows.get(wid).name()
// - Click selects (no drag-reorder, no drag-detach)
// - No close button
// - No window menu button
// - No tooltips
```

**Verdict: PARTIAL — defer to 5.5f-h.**
- Per-tab close button: 5.5f.
- Drag-reorder: 5.5f.
- Drag-detach: 5.5f.
- Window menu button (▾ overflow): would need 3.6c (tabbar overflow) first.

Reusing our `beginTabBar / beginTabItem` widgets would be ideal but
requires refactoring their API — they're string-id-keyed today,
not window-id-keyed. Probably worth doing in 5.5f rather than
extending our mini implementation further.

---

## 5. Per-frame call flow

### imgui (paraphrased from imgui.cpp:17725-17772 comment)

```
NewFrame()
  DockContextNewFrameUpdateUndocking()
    DockContextProcessUndockWindow()
    DockContextProcessUndockNode()
  DockContextNewFrameUpdateDocking()
    DockContextProcessDock()
    DockNodeUpdate()                                ← entry point, called per ROOT node
      DockNodeUpdateForRootNode()
        DockNodeUpdateFlagsAndCollapse()
        DockNodeFindInfo()
      destroy unused node or tab bar
      create dock node host window (Begin(child))
      DockNodeStartMouseMovingWindow()
      DockNodeTreeUpdatePosSize()
      DockNodeTreeUpdateSplitter()
      draw node background
      DockNodeUpdateTabBar()
        BeginTabBarEx() + TabItemEx() per tab
      BeginDockableDragDropTarget()
        DockNodePreviewDockRender()
      DockNodeUpdate() recurse into children

DockSpace()                                          ← USER calls this
  Begin(Child) — create child window
  DockNodeUpdate() — but only the structural part
  End(Child)
  ItemSize()

Begin() — USER per-window
  BeginDocked()
    BeginDockableDragDropSource()
    BeginDockableDragDropTarget()

EndFrame()
  DockContextEndFrame()
```

### zimr

```
beginFrameRaw()
  dock.beginFrameReset()                            ← clears dockspaces_this_frame

(user submission)
dockSpace(...)                                       ← USER per dockspace
  finds-or-creates root DockNode (id-keyed)
  layoutSubtree() — initial pass with current root rect
  draws background outline
  pushes id to dockspaces_this_frame
  advanceLayout()

(user submits docked window submissions via window(name, ...))
  findOrCreateWindow: if dock_node_id set, read pos/size from leaf
  openWindow: returns null for non-selected docked tabs;
              skips renderWindowChrome for selected docked windows

endFrame()
  processRequests()                                  ← drains pending_requests
  flushDockTabsToForeground():
    for each dockspace in dockspaces_this_frame:
      layoutSubtree() — re-run with current root rect (post-mutation)
      switch current_draw_list to foreground_dl
      renderDockLeafTabBars(root_id) — recurse, emit tab strip per leaf
      if dragging_window != null:
        renderDockTargetOverlay(root_id) — 5-zone cross per leaf
      restore current_draw_list
```

**Major structural differences:**

1. imgui's `DockNodeUpdate` is responsible for **creating a child
   window** to host the dockspace. Our `dockSpaceImpl` reserves
   layout space in the existing window and writes directly to its
   draw list — no child window needed.
2. imgui dispatches drag-drop via `BeginDockableDragDropSource` /
   `BeginDockableDragDropTarget`, which hook into the standard
   drag-drop system. We special-cased the title-bar drag in
   `renderWindowChrome` and the release-on-zone in the same place.
3. imgui renders the dock tab bar inside `DockNodeUpdate` (i.e. at
   `dockSpace()` call time). We deferred to `endFrame` via
   `flushDockTabsToForeground` to fix our frame-1 ordering quirk.

**Verdict on each:**
- (1) JUSTIFIED. Child-window-as-host is conceptually clean but
  requires the host-window machinery (chrome, focus, z-order). Our
  "write into the parent window's draw list" is simpler and works.
- (2) PARTIAL. Reusing the drag-drop system would be nice but
  beginDragDropSource is already used for actual user payloads;
  shoehorning window-drag through it might confuse semantics. Our
  custom path is fine.
- (3) JUSTIFIED. Our deferred render fixes a real ordering bug. The
  imgui ordering quirk (dockspace must be submitted before docked
  windows) is documented as a footgun.

---

## 6. Persistence

### imgui .ini format

Text, line-based, written via `SaveIniSettingsToDisk`:

```
[Window][Tools]
Pos=100,80
Size=400,300
Collapsed=0
DockId=0xDEADBEEF

[Window][Viewport]
Pos=0,0
Size=1280,720
Collapsed=0
DockId=0xCAFEBABE

[Docking][Data]
DockSpace      ID=0x12345678 Pos=0,0 Size=1280,720 Split=X
  DockNode     Parent=0x12345678 SizeRef=320,720 SelectedTab=0xABC123
  DockNode     Parent=0x12345678 CentralNode=1 HiddenTabBar=1
```

Custom parser, custom serializer. Human-editable.

### zimr .zon + localStorage

Step 5.1 (turn 318) — already shipped for windows + tab bars:

```zig
.{
    .version = 1,
    .windows = .{
        .{ .name = "Tools", .pos = .{100, 80}, .size = .{400, 300},
           .tab_bars = .{...} },
        ...
    },
}
```

Dock tree persistence (5.5g, planned) extends with:

```zig
.dock_nodes = .{
    .{ .id = 0x12345678, .parent_id = null, .axis = .horizontal,
       .ratio = 0.25, .child_ids = .{0xAAA, 0xBBB} },
    .{ .id = 0xAAA, .parent_id = 0x12345678, .windows = .{"Tools"},
       .selected = "Tools" },
    ...
}
```

**Verdict: JUSTIFIED.** `.zon` parses via `std.zon.parse` (~10
lines of code), is structured (no custom parser), and our
localStorage transport is the only browser-compatible path. imgui's
line-based format would be a pain to parse in Zig and gives us
nothing browser-friendly.

---

## 7. Public API parity

| imgui                                             | zimr                                     | Status |
|---|---|---|
| `DockSpace(id, size, flags, window_class)`         | `dockSpace(str_id, size, opts)`         | ✅ minus flags + class |
| `DockSpaceOverViewport(id, vp, flags, wcls)`       | —                                       | NOT YET |
| `SetNextWindowDockID(id, cond)`                    | —                                       | NOT YET |
| `SetNextWindowClass(class)`                        | —                                       | NEVER (no classes) |
| `GetWindowDockID()`                                | `w.dock_node_id` (field access)         | ✅ different shape |
| `IsWindowDocked()`                                 | `w.dock_node_id != null`                | ✅ field access |
| `DockBuilderDockWindow(name, node_id)`             | `dockBuilderDockWindow(name, node_id)`  | ✅ parity |
| `DockBuilderSplitNode(id, dir, ratio, &a, &b) → ID`| `dockBuilderSplitNode(id, dir, ratio) → {a, b}` | ✅ different signature |
| `DockBuilderAddNode(id, flags) → ID`               | —                                       | NOT YET |
| `DockBuilderRemoveNode(id)`                        | `dockBuilderRemoveNode(id)`             | ✅ parity |
| `DockBuilderRemoveNodeChildNodes(id)`              | —                                       | NOT YET |
| `DockBuilderRemoveNodeDockedWindows(id, clear)`    | —                                       | NOT YET |
| `DockBuilderGetNode(id) → *Node`                   | `ctx.dock.lookup(id)`                   | ✅ different shape |
| `DockBuilderGetCentralNode(id) → *Node`            | —                                       | NOT YET |
| `DockBuilderSetNodePos(id, pos)`                   | —                                       | NOT YET |
| `DockBuilderSetNodeSize(id, size)`                 | —                                       | NOT YET |
| `DockBuilderCopyNode(src, dst, remap)`             | —                                       | NEVER (rare) |
| `DockBuilderCopyDockSpace(src, dst, remap)`        | —                                       | NEVER (rare) |
| `DockBuilderFinish(id)`                            | `dockBuilderFinish(id)`                 | ✅ parity |

**Coverage: ~9/19 public, all the high-value ones.**

---

## 8. Decision log — summary

| # | Topic | imgui pattern | zimr pattern | Verdict |
|---|---|---|---|---|
| 1 | Node refs | `*ImGuiDockNode` | `Id` (u32) | ✅ JUSTIFIED |
| 2 | Size storage | `SizeRef` in px per node | `size_ref: [2]?f32` per SPLIT (turn 329) | ✅ done — simplified to per-split rather than per-node |
| 3 | Node flags | 3-tier flags (Shared/Local/Local-in-Windows/Merged) | flat `flags: DockNodeFlags = packed struct(u16)` (turn 327) | ✅ done — JUSTIFIED simplification |
| 4 | Typed docking | `WindowClass` | none | ✅ JUSTIFIED (out of scope) |
| 5 | Central node | `CentralNode*` + special-case in TreeUpdatePosSize | `is_central` flag + size_ref absorbs remainder (turn 329) | ✅ done — same UX, simpler model |
| 6 | Floating dock nodes | `HostWindow` for floating multi-tab groups | none | 🟡 UNCLEAR — depends on 5.5f UX choice |
| 7 | Pre-dock state | `AuthorityForPos/Size` 3-bit per-axis | `pre_dock_pos/size: ?Vector2` stash + restore as a unit (turn 326) | ✅ done |
| 8 | State machine | `Want*` transient bools | sync via `pending_requests` | ✅ JUSTIFIED (ours is cleaner) |
| 9 | Drop zone sizing | adaptive: `min(fs*1.5, max(fs*0.5, min_dim/8))` | fixed 36px → ADOPTED imgui's formula turn 325 | ✅ done |
| 10 | Drop hit-test | radial: dist-from-center thresholds (magic 1.4/2.6) | continuous-scoring closest-zone-wins + smooth opacity feedback (turn 325) | 🏆 IMPROVED ON IMGUI |
| 11 | Outer docking | yes (split at root level) | no | 🟡 NICE-TO-HAVE — low priority |
| 12 | Tab bar | reuses `BeginTabBarEx` | custom mini-impl | ⚠️ PARTIAL — reconsider in 5.5f |
| 13 | Tab close button | yes | no | 🟡 PLANNED (5.5f) |
| 14 | Tab drag-reorder | yes | no | 🟡 PLANNED (3.6b → 5.5f) |
| 15 | Tab drag-detach | yes (via BeginDockableDragDropSource) | no | 🟡 PLANNED (5.5f) |
| 16 | Tab bar host | child window per dock node | own draw list + foreground_dl | ✅ JUSTIFIED |
| 17 | Per-frame render | inline at dockSpace() call | deferred at endFrame | ✅ JUSTIFIED (fixes ordering bug) |
| 18 | Multi-viewport | yes | no | ✅ JUSTIFIED (browser) |
| 19 | OS cursor changes | yes | no | ✅ JUSTIFIED (browser) |
| 20 | Persistence | `.ini` text — tree shape + per-window state | `.zon` + localStorage — both via PersistedDockNode[] (turn 334) | ✅ JUSTIFIED + DONE |
| 21 | Settings inheritance | `LocalFlagsInWindows` from `WindowClass.DockNodeFlagsOverrideSet` | none | ✅ JUSTIFIED (no classes) |
| 22 | KeepAliveOnly | flag | none | 🟡 NICE-TO-HAVE — matters if we put dockspaces in tab content |

**Tally:**
- ✅ JUSTIFIED — 9 items (we made the right call)
- ⚠️ PARTIAL — 2 items (size storage, tab bar reuse) — revisit in 5.5e/5.5f
- ❌ NO — 5 items to add (flags, central node, pre-dock pos, adaptive zone sizing, radial hit-test)
- 🟡 PLANNED — 4 items already scheduled (5.5f mostly)
- 🟡 NICE-TO-HAVE — 2 items (outer docking, KeepAliveOnly)

---

## 9. Recommended follow-up sequence

In priority order, before declaring 5.5 done:

1. **5.5e splitter drag** — must support `size_ref: ?f32` per child
   for "fixed-width left panel" UX. (~80 LOC)

2. **Drop hit-test improvements** — adaptive zone sizing + radial
   thresholds. Probably 30 LOC, big UX win. (~1 turn)

3. **5.5f close + drag-detach + drag-reorder** — three features
   bundled because they all touch the tab bar. Likely warrants
   reusing `beginTabBar`/`beginTabItem` rather than extending
   `renderDockLeafTabBars`. (~3-5 turns)

4. **Flag set** — `DockNodeFlags` with NoSplit/NoTabBar/NoResize/
   NoDockingOverMe/HiddenTabBar/NoCloseButton/PassthruCentralNode.
   Single u16 per node, no Shared/Local tiering. (~1 turn)

5. **CentralNode** — one extra flag bit + ~30 LOC in
   `layoutSubtree` to do "if one sibling is central and the other
   has size_ref, fix the sibling and give central the remainder."
   (~1 turn)

6. **Pre-dock pos/size** — `Window.pre_dock_pos: ?Vector2`,
   `pre_dock_size: ?Vector2`. Stash at first dock, restore at
   undock. (~½ turn)

7. **5.5g settings serialization** — extend ui_persistence with
   `DockNodeSettings[]`. ZonStringify the tree, parse on apply.
   (~1-2 turns)

8. **5.5h demos polish** — `ui_dock_persistence.zig`,
   `ui_full_showcase` tab. (~1 turn)

**Items 2, 4, 5, 6 are quick wins worth doing BEFORE the bigger
5.5e/f/g work** — they're all small, independent, and recover
substantial parity with imgui's UX expectations.

**Items we're NOT chasing:** multi-viewport, window classes,
DockBuilderCopy* family, DockSpaceOverViewport convenience wrapper,
OS cursor changes, .ini-style persistence, floating-dock-node-as-host.

---

## 10. Where the source actually lives

For future reference when comparing implementations:

| Concept | imgui location | zimr location |
|---|---|---|
| Node struct | imgui_internal.h:2037-2098 | src/ui_dock.zig:131-198 |
| Flags enum | imgui.h:~1100 (public) + imgui_internal.h (internal) | (not yet) |
| Tree split | imgui.cpp:20169 (DockNodeTreeSplit) | src/ui_dock.zig:490 (splitNode) |
| Tree merge | imgui.cpp:20213 (DockNodeTreeMerge) | src/ui_dock.zig:undockWindow (collapsing branch) |
| Layout | imgui.cpp:20260 (DockNodeTreeUpdatePosSize) | src/ui_dock.zig:603 (layoutSubtree) |
| Splitter | imgui.cpp:20396 (DockNodeTreeUpdateSplitter) | (not yet — 5.5e) |
| Drop zones | imgui.cpp:19897 (DockNodeCalcDropRectsAndTestMousePos) | src/ui.zig:dockTargetZonesFor + hitTestDockTargets |
| Drop preview | imgui.cpp:19951 (DockNodePreviewDockSetup) + DockNodePreviewDockRender | src/ui.zig:renderDockTargetOverlay |
| Tab bar | imgui.cpp:19503 (DockNodeUpdateTabBar) | src/ui.zig:renderDockLeafTabBars |
| Begin docked | imgui.cpp:19770 (BeginDocked) | src/ui.zig:openWindow (docked-gate path) |
| Begin drag-drop target | imgui.cpp (BeginDockableDragDropTarget) | src/ui.zig:renderWindowChrome (release branch) |
| Public DockSpace | imgui.cpp:~20700 | src/ui.zig:dockSpaceImpl |
| DockBuilder API | imgui.cpp:20744-21193 | src/ui.zig:dockBuilder* |
| .ini settings | imgui.cpp:~21340 (DockSettingsHandler_*) | src/ui_persistence.zig + (5.5g) |

That's where to point a debugger when matching behavior.

---

End of tutorial. Decision log + priorities incorporated into plan v5
section 4.0 in `imgui-plan-v5.md` as follow-ups.
