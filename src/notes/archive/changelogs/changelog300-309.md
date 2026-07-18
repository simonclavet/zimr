# CHANGELOG — turns 300-309

Per-turn journal for turns 300-309.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 310
opens, this file is frozen and a fresh `changelog310-319.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog290-299.md`, `changelog280-289.md`, `changelog270-279.md`,
`changelog260-269.md`, `changelog250-259.md`, `changelog240-249.md`,
`changelog230-239.md`, `changelog220-229.md`, `changelog210-219.md`,
`changelog200-209.md`, `changelog093-199.md`, `changelog001-092.md`).

---

## [Unreleased]

**[Step 1.5.5 part 2] Child-as-Window — architectural close.**
Simon's question from turn 309c asked whether the bugs we keep
hitting are zimr being clever vs imgui, or surface symptoms of a
partial refactor.  Answer (per `src/notes/architecture-imgui-vs-zimr.md`):
surface symptoms.  Imgui's structural advantage is "each child IS
a real Window with its own per-scope state."  zimr's
`LayoutScope` refactor (turn 309) ported the per-scope state
struct; turn 309d closes the gap by making each `beginChild` (and
`beginListBox`) allocate a full persistent `Window` keyed by
hashed child ID.

**Changes:**

- `Window` gains `flags: WindowFlags` (struct-of-bools: `is_child`
  for now; popup/tooltip/modal/dock_node land as Phases 2-5 grow)
  and `parent_id: ?Id` (set on children; null on top-level).
- `findOrCreateChildWindow(ctx, child_id)` — new helper, mirrors
  `findOrCreateWindow`.  Allocates a `Window` in `ctx.windows`
  keyed by hashed ID, sets `flags.is_child`, stamps a debug name
  `child:<hex>`.
- `beginChildImpl`:
  - Fetches (or allocates) the persistent child `Window`.
  - Re-stamps `pos`, `size`, `parent_id`, `last_frame_active` each
    frame (the per-frame anchor data; everything else persists).
  - Pushes onto `id_stack` + `window_stack`; sets
    `current_window = child`.
  - Installs the child's fresh `LayoutScope` (origin,
    work_rect_max, cursor_pos all seeded to inner_origin).
  - Defensive clamp from turn 309c carries over — children
    physically cannot escape parent's `work_rect_max`.
- `endChildImpl`:
  - Pops clip + id_stack + window_stack.
  - `current_window` reverts to parent automatically.
  - Parent's cursor advances past child's outer rect via
    `advanceLayout`.
  - Child's outer rect becomes parent's `last_item_rect` for
    `isItemHovered()` after `endChild`.
  - No state restore needed — parent's `layout` was never touched.
- `openListBox` / `closeListBox` ported to the same pattern.  The
  listBox is a child window with frame chrome (border + bg fill).
  Per-listBox state (future scroll position once Step 1.6 lands)
  now lives on the listBox's own `Window`.
- Clipper viewport math simplified.  Before:
  ```
  vtop = w.pos[1] + title_bar + padding[1];
  vbot = w.pos[1] + w.size[1] - padding[1];
  if (child_stack.len > 0) { ... tighter bound from child ... }
  ```
  After:
  ```
  vtop = w.layout.origin[1];
  vbot = w.layout.work_rect_max[1];
  ```
  No more "are we in a child" branch — `current_window.layout`
  IS the active scope, whatever its nesting.
- **`ChildState` deleted.**  No longer needed — parent layout is
  not mutated, so nothing to save/restore.
- **`UiContext.child_stack` deleted.**  Window stack does the
  nesting tracking.

**Tests updated:**

- Old "ChildState: stack starts empty, capacity 8" — replaced by
  "child windows: persist in ctx.windows across frames" which
  exercises the actual contract: same hashed ID → same Window
  pointer across `findOrCreateChildWindow` calls.
- "Phase 4D: beginListBox/endListBox saves+restores cursor" —
  rewritten to verify the new behavior: `current_window` flips to
  the list box (with `flags.is_child`), parent's layout is NOT
  mutated during the listBox scope, parent's cursor advances
  after `endListBox`.
- Existing turn 309c spillover tests updated to read child rects
  from `ctx.current_window.?.pos/.size` instead of
  `ctx.child_stack.items[i].rect`.
- Clipper test fixture now seeds `layout.origin` +
  `layout.work_rect_max` (since the clipper reads these directly
  now).

**Audit:** 1441/1441 pass.

**Smoke:** `ui_panes` 10741 GL calls (unchanged), no crash.

**Standalone:** `ui_panes-turn309d.html` shipped.

**What this unblocks:**

- Step 1.6 (per-child scrolling) — `scroll_y` already exists on
  `Window`; each child has its own.  Effectively free now.
- Future Persistence (Step 5.1) — per-child state has a natural
  storage key (the hashed child ID in `ctx.windows`).
- Future Docking (Step 5.5) — children are structurally
  indistinguishable from top-level windows; a child can be
  detached into a top-level window with no structural change.

**Imgui parallel:** `BeginChildEx` (imgui.cpp:6419) delegates to
`Begin()` which allocates a real `ImGuiWindow*`.  We do the same
with `findOrCreateChildWindow`.  The Zig-idiomatic differences:
explicit `WindowFlags` struct-of-bools (vs `ImGuiWindowFlags_*`
bit constants); `parent_id` by-value rather than `ParentWindow`
pointer (avoids lifetime hazards if a parent is GC'd); explicit
fail returns (`return false` on stack-push OOM) vs imgui's silent
fallback.

**File-line stats:** `src/ui.zig` 20614 → 20935 (+321 net,
mostly comments + tutorial-prose docstrings on the new
functions).  Real code change ~80 lines.

**Cluster closed.**  Of the six recent layout bugs sorted in
`src/notes/architecture-imgui-vs-zimr.md`, all three "missing
per-scope state" ones were fixed by the LayoutScope refactor;
all three architectural symptoms were prevented by child-as-Window.
The remaining splitter API choice (`total_along_axis`) is a
separate refactor — could revisit if more splitter callsites
land, but isn't blocking.

---

**[Step 1.5.5 turn 3] beginChild defensive clamp + ui_panes spacing
accounting.**  Simon's phone screenshot of turn 309b showed the
right pane STILL spilling text past the workspace's right edge,
by about 16 pixels — even after the work_rect_max fix.

Traced the geometry: when the splitter is at rightmost,
tree=340 wide → sameLine adds 8px spacing → splitter (4 wide) →
sameLine adds 8px spacing → right pane.  Cumulative consumption
along the row: 340 (tree) + 8 (spacing) + 4 (bar) + 8 (spacing) +
20 (right_w) = 380.  But workspace inner-right = 380, so the
right pane's right edge = 16+340+8+4+8+20 = 396 = workspace +16.

The user math `right_w = total_w - left_w - SPLIT_BAR_W` was
short by `2 * item_spacing[0]` — the two `sameLine` calls around
the splitter.  Same bug exists vertically inside the right column
between editor/splitter/output.

**Two-layer fix:**

**Layer 1 (library, structural).**  `beginChildImpl` now clamps
`actual_size` to fit within parent's `work_rect_max`.  Children
can no longer escape their parent scope, regardless of user math.
The previous min-clamp (`if size < 16: size = 16`) was removed —
a size of 0-15 is preferable to a 16px child that overshoots.

```zig
const max_w = @max(0, w.layout.work_rect_max[0] - at[0]);
const max_h = @max(0, w.layout.work_rect_max[1] - at[1]);
var actual_size = size;
if (actual_size[0] <= 0) actual_size[0] = max_w; // auto-fill
if (actual_size[1] <= 0) actual_size[1] = 100;
// Clamp DOWN — never escape.
if (actual_size[0] > max_w) actual_size[0] = max_w;
if (actual_size[1] > max_h) actual_size[1] = max_h;
```

**Layer 2 (example, math).**  ui_panes now:
- Computes `usable_w = total_w - SPLIT_BAR_W - 2 * sp_x` (the
  shared space for the two panes).  Splitter's `total_along_axis
  = usable_w + SPLIT_BAR_W` so its drag-clamp is correct.
- Uses `beginChild("right", .{ 0, total_h })` — **width 0**
  auto-fills remaining space.  Matches imgui's idiomatic Splitter
  pattern from imgui_demo.cpp.
- Inside the right child, re-queries `getContentRegionAvail()`
  for local dimensions and applies the same accounting for the
  v-splitter.
- Output pane uses `beginChild("output", .{ 0, 0 })` — both
  dimensions auto-fill.

**Tests:** 1441/1441 pass.  Added "beginChild: explicit oversized
width clamped to parent scope" — pins the structural clamp.  Pre-
fix, this test would have shown a child 38 pixels past the parent
scope.

**Smoke:** ui_panes 10741 GL calls, no crash.
**Standalone:** `ui_panes-turn309c.html`.

**Imgui-idiomatic takeaway.**  In imgui, the trailing pane in a
splitter layout typically uses `ImVec2(0, h)` for auto-fill —
this sidesteps the spacing-accounting problem entirely (the
library knows how much space remains).  zimr now does the same.
The library clamp is the structural defense against the user
forgetting; the auto-fill idiom is the user-side best practice.

---

**[Step 1.5.5 turn 2] LayoutScope.work_rect_max — fix right-pane
spillover.**  Simon's last ui_panes phone screenshot showed text
in the right pane spilling past the right edge of the workspace
window when the splitter was at rightmost (right pane ~20px
wide).

Two bugs at play:

1. **`beginChildImpl`'s auto-fill computed `inner_right` from
   the top-level WINDOW's right edge.**  When called for a child
   nested inside another child (the editor inside the right
   pane), `inner_right - at[0]` overshot — the editor's
   actual_size[0] expanded all the way to the workspace's right
   edge, past the right pane's right edge.
2. **`getContentRegionAvail` had the same bug** — used the
   top-level window's edges, not the current scope's.

Fix: added `work_rect_max: Vector2` to `LayoutScope`.
Initialized in `openWindow` to the inner bottom-right of the
window, and in `beginChild` / `beginListBox` to the inner
bottom-right of the child rect.  `beginChild`'s auto-fill and
`getContentRegionAvail` both now read `w.layout.work_rect_max`
instead of `w.pos[0] + w.size[0]`.

Imgui parallel: `ImGuiWindow.WorkRect.Max`.  zimr's name follows
imgui directly here for parity readability.

**Tests:** 1440/1440 pass.  Added "beginChild auto-fill: nested
child bounds to PARENT child's right edge" — directly pins the
spillover semantics.  Before the fix this test failed by ~360
pixels of overshoot.

**Smoke:** ui_panes 10741 GL calls (unchanged), no crash.

**Standalone:** `ui_panes-turn309b.html` shipped for phone test.

**Latent bug B (clip-rect intersection)** noted but deferred.
`pushClipRect` doesn't intersect with parent's clip rect — a
child whose rect happens to be wider than its parent's would
still over-clip outward.  Fix A made the SPECIFIC case (auto-fill
overshoot) impossible; fix B would catch the broader pattern but
isn't blocking ui_panes today.  Will revisit if a downstream
example hits it.

---

**[Step 1.5.5] LayoutScope refactor — foundation for docking.**
Simon's architectural ask from late turn 308: *"are we hitting
bugs because we're diverging from imgui?"* Yes, structurally.
All four turn-308 layout bugs shared a root cause: zimr's
`Window` struct served as both "the window" AND "the current
layout scope," with each new scope-context requirement (indent,
child anchor, future scroll, future dock node) bolted on as an
ad-hoc field.  The fix-as-we-go pattern collapsed.

This turn introduces a `LayoutScope` struct that owns ALL
per-scope layout state, and lifts the existing layout fields off
`Window` into `Window.layout`.

**New `LayoutScope` struct (`src/ui.zig:1481`):**

```zig
pub const LayoutScope = struct {
    origin: Vector2 = .{ 0, 0 },
    cursor_pos: Vector2 = .{ 0, 0 },
    cursor_max: Vector2 = .{ 0, 0 },
    cursor_pos_prev_line: Vector2 = .{ 0, 0 }, // NEW — for sameLine
    line_height: f32 = 0,
    prev_line_height: f32 = 0,                 // NEW — for sameLine
    indent_x: f32 = 0,
    last_item_id: Id = 0,
    last_item_rect: Rectangle = .{...},
    last_item_hovered/edited/clicked/...: bool,
};
```

`cursor_pos_prev_line` + `prev_line_height` map to imgui's
`DC.CursorPosPrevLine` + `DC.PrevLineSize.y`.  They fix the
latent row-max-height bug (where `sameLine` across mixed-height
widgets used the LAST widget's height for the row, instead of
the row's MAX).  Pinned by the new test "row max-height:
sameLine across mixed heights clears the tallest".

**`Window` slimmed.**  All 14 layout fields removed; replaced by
one `layout: LayoutScope = .{}` field.  `pending_same_line` and
`layout_origin_x` (the latter introduced as an emergency fix
mid-turn-308) deleted entirely — superseded by the new
`cursor_pos` / `origin` model.

**`ChildState` collapsed from 7 fields to 1.**  The 6 individual
`saved_cursor_pos` / `saved_cursor_max` / `saved_line_height` /
`saved_indent_x` / `saved_pending_same_line` / `saved_layout_origin_x`
fields became one `saved_layout: LayoutScope` field.  Adding a
new layout-tracked field on `LayoutScope` no longer requires
edits to every save/restore site.

**`GroupState` dropped `saved_pending_same_line`** (field no
longer exists in the model; sameLine writes cursor directly).

**`sameLine` rewritten for the new model:**

```zig
pub fn sameLine(self: Ui, opts: SameLineOpts) void {
    const w = self.ctx.current_window orelse return;
    const s = &w.layout;
    const item_sp_x = self.ctx.style.item_spacing[0];
    s.cursor_pos[0] = if (opts.offset_x > 0)
        s.origin[0] + opts.offset_x
    else
        s.cursor_pos_prev_line[0] + item_sp_x;
    s.cursor_pos[1] = s.cursor_pos_prev_line[1];
    s.line_height = s.prev_line_height;
}
```

**`advanceLayout` rewritten** to properly track
`cursor_pos_prev_line` + `prev_line_height` on every wrap.
Uses `s.origin[0]` for row reset (the `layout_origin_x` fix
from turn 308 is now structural — every scope has its own
origin).

**`resolveCursor` simplified** to just return `cursor_pos` (the
deferred-resolve `pending_same_line` branch deleted).

**`treePop` symmetric pop** — decrements `indent_x` AND
`cursor_pos[0]` so the first widget after `treePop` lands at
the correct X.  Replaces the asymmetric pop that left cursor
one INDENT_AMOUNT too far right.

**`openWindow` / `beginChild`** install a fresh
`LayoutScope` with `cursor_pos_prev_line` seeded to
inner_origin — so a pathological `sameLine` before ANY widget
submission lands sensibly instead of at (0,0).

**Tests:**
- Audit: 1439/1439 pass.  (Up from 1437 — added 2 new tests
  for row max-height and cursor_pos_prev_line seeding.)
- Smoke: `ui_panes` 10741 GL calls, no crash.
- Standalone: `prebuilt/standalone/ui_panes.html` built.
- The three turn-308 regression tests still pass:
  - "sameLine: A and B render at same row Y"
  - "sameLine after endChild: next widget at child's row"
  - "beginChild: second widget renders at child's inner-left"

**Rename mechanics.**  Used sed for the bulk rename
(`w.<field>` → `w.layout.<field>` for ~352 callsites).
Collateral damage: `InputTextState.cursor_pos` and
`InputTextCallbackData.cursor_pos` (both text-buffer indices,
not layout vectors) got clobbered; reverted explicitly via
`s/self\.layout\.cursor_pos/self.cursor_pos/g` and
`s/input_text_state\.layout\.cursor_pos/input_text_state.cursor_pos/g`.
Lesson: distinct types with identically-named fields are a
landmine for blind renames; next time, lean on Zig's compiler
errors (rename Window's fields first, fix the compile errors
one-by-one) rather than text sed.

**Lines of code:** `src/ui.zig` 20555 → 20614 (+59, mostly
new doc comments + 2 new tests; the actual field-shape change
was net-negative).

**Next:** child-as-Window model deferred to a follow-up turn.
This refactor unblocks it cleanly — each `beginChild` will
allocate a sub-Window keyed by hash, each with its own
`LayoutScope`, instead of state-pushing onto the parent's.
Required for Step 1.6 (per-child scrolling) and Step 5.5
(docking).

---

**[Late-turn correction 3] Splitter widget positioning fix.**
Simon's next phone screenshot showed:
1. Tree pane labels truncated way short of the splitter (huge
   empty gap inside the tree child between text and the bar).
2. Splitter couldn't drag past `min_left=80` toward the canvas
   edge.

Diagnosis: the splitter widget rendered the bar at
`cur[0] + split_pos.*`.  In the demo's idiomatic use (sameLine
after the first pane's `endChild`), the cursor was ALREADY at
the boundary between panes — so adding `split_pos` shifted the
bar one pane-width too far right.  Simon's drag had pulled
`s.left_w` down to the `min_left=80` clamp, making the tree pane
80 wide.  The bar then rendered at `cur(88) + 80 = 168` instead
of 88.

**Fix at `src/ui.zig:13150` (splitterImpl):**

```zig
// Bar at cursor — caller already positioned via sameLine.
// split_pos is "size of pane 1", not "offset from cursor".
const bar_rect: Rectangle = switch (axis) {
    .x => .{ .x = cur[0], ... },
    .y => .{ .x = cur[0], .y = cur[1], ... },
};
```

Drag math (`delta = mouse - bar_center`) unchanged — still
mutates `split_pos` correctly because cur naturally tracks
pane 1's right edge (= start + size = pane1.x + split_pos), so
`mouse - cur` = the size adjustment needed.

`render_rect` simplified — no recompute now that the bar
doesn't move within a frame.  (Drag feedback applies on the
next frame; imgui has the same 1-frame lag.)

5 existing splitter tests rewrote — they encoded the old
"bar at cur + split_pos" model.  New tests place the cursor at
the bar's intended X (e.g. `w.cursor_pos = .{ 128, 8 }` for a
pane 1 of width 120 starting at x=8) and verify drag delta
math against `bar_center = cur[0] + bar_width/2`.

**Demo: smaller mins so the splitter drags closer to the
edges.**  `min_left/min_right` 80/100 → 20/20.  Same for the
vertical splitter (`min_top/min_bot` 60/60 → 20/20).  Per
Simon's complaint that the splitter "blocks" before reaching
canvas edge.  20px is a practical floor: narrower and the
pane shows nothing meaningful.

1437/1437.  Smoke 10741 GL calls.  Standalone 168 KB.

---


**[Late-turn correction 2] `layout_origin_x` fix for in-child layout.**After the sameLine fix landed (the splitter became visible), Simon's
next phone screenshot showed correct splitter + L-shape, but
**editor pane text was clipped from the LEFT**.  Only the rightmost
portion of each line was visible (we saw "demo for Step 1.4." from
a line that should have read "// Three-pane workspace demo for
Step 1.4.").

Diagnosis: `advanceLayout`'s next-row cursor reset used
`w.pos[0] + window_pad_x + w.indent_x`.  `w.pos[0]` is the parent
window's position — when the cursor was inside a child anchored
away from parent-left (e.g. right pane after sameLine + splitter),
the reset wrapped widgets back to the parent's content-left.  The
child's scissor then clipped them out — except for the slice that
happened to fall under the editor pane's rect.

imgui doesn't have this bug because `BeginChild` creates a SEPARATE
`ImGuiWindow` with its OWN `Pos`; ItemSize uses `window->Pos.x`
which is the child's pos.  zimr reuses one `Window` struct across
parent + children.

**Fix:** new `layout_origin_x: f32` field on `Window`.

- Set at `openWindow` to `inner_origin[0]` (window content's left
  edge).
- `beginChild` saves to `ChildState.saved_layout_origin_x`, sets
  to `inner_origin[0]` (child's inner-left).
- `endChild` restores.
- `advanceLayout` uses `w.layout_origin_x + w.indent_x` instead of
  `w.pos[0] + window_pad_x + w.indent_x`.
- `beginListBox`'s inline child-state mirror also updated.

Regression test added: `"beginChild: second widget renders at
child's inner-left, not parent's"` constructs a child anchored
away from parent's left edge and asserts the second widget aligns
with the first.  1437/1437.

---

### Turn 308 — Step 1.4 ✅ DONE + Step 1.5 substantive: TreeNodeEx flags + foundational sameLine bug fix

**[Late-turn correction] Foundational `sameLine` bug discovered and
fixed.**  Simon's phone screenshot of `ui_panes-turn308` showed the
tree pane but no splitter and no right pane.  Diagnostic tests
revealed:

- `A.y=8 A.h=16; B.y=28; same=false` — sameLine after a button
  placed the next widget 20px BELOW (one row gap), not beside.
- `child.y=8 child.h=200; after.y=212 after.x=116` — sameLine
  after `endChild` placed the next widget 200+px below the
  child.  Splitter rendered off-screen.

Root cause: zimr's `sameLine` only flagged `pending_same_line` and
left `cursor_pos[1]` at the post-advanceLayout position (next-row
top).  `resolveCursor` for sameLine returned
`(cursor_max[0] + spacing, cursor_pos[1])` — Y was the wrong row.

**Imgui's design (imgui.cpp:11438):**

```cpp
window->DC.CursorPos.x = window->DC.CursorPosPrevLine.x + spacing_w;
window->DC.CursorPos.y = window->DC.CursorPosPrevLine.y;   // restore row top
window->DC.CurrLineSize = window->DC.PrevLineSize;
```

imgui tracks `CursorPosPrevLine` separately — (right edge of last
item, top of row).  SameLine restores `CursorPos.y` to row top.
zimr's `last_item_rect.y` is structurally equivalent.

**Fix at `src/ui.zig:3126`:**

```zig
pub fn sameLine(self: Ui, opts: SameLineOpts) void {
    const w = self.ctx.current_window orelse return;
    const item_sp_x = self.ctx.style.item_spacing[0];
    w.cursor_pos[0] = if (opts.offset_x > 0)
        w.pos[0] + opts.offset_x
    else
        w.last_item_rect.x + w.last_item_rect.width + item_sp_x;
    w.cursor_pos[1] = w.last_item_rect.y;
    w.line_height = w.last_item_rect.height;
    w.pending_same_line = false;
}
```

After the fix: `A.y=8 B.y=8 same=true` ✓.  `after.y=8 after.x=116`
✓ (just past the child, same row).

This was a long-standing zimr bug masked by the fact that most
"side-by-side" widget pairs had similar heights and small
item_spacing — the stagger looked like normal vertical spacing.
Existing 2-column grids in log_viewer etc. now render correctly
on the same row.

Two regression tests added.  1436/1436 (was 1434).  Smoke
ui_panes: 10741 GL calls.

**Also fixed: `treePop` indent asymmetry.**  Push side of
`treeNodeExImpl` increments both `indent_x` AND `cursor_pos[0]`;
pop side was decrementing only `indent_x`.  First widget after
each `treePop` rendered one `INDENT_AMOUNT` too far right.  Fix
at `src/ui.zig:4313` — symmetric pop.

---

**Step 1.4 closed.**  Plan promoted to ✅ DONE turn 308 with arc
recap (turns 306-308: splitter + size-constraints + setWindow*
named variants) and 3 deferreds filed (`setWindowCollapsed`,
constraint callback variant, Cond enum).

**Step 1.5 started — substantive code lands.**  TreeNodeEx with
flag support replaces the older simple `treeNode`.  The 26
imgui `ImGuiTreeNodeFlags` translated per the flag-decision rule:

- **3 exclusive enums:** `TreeOpenTrigger`
  (click_anywhere/click_arrow/double_click), `TreeNodeSpan`
  (default/avail_width/full_width/label_width/all_columns/
  label_all_columns), `TreeNodeDrawLines`
  (none/full/to_nodes).
- **10 independent bools:** `selected`, `framed`,
  `allow_overlap`, `no_tree_push_on_open`,
  `no_auto_open_on_log`, `default_open`, `leaf`, `bullet`,
  `frame_padding`, `nav_left_jumps_to_parent`.

**MVP coverage (~7 effective flags):** `selected`, `framed`,
`default_open`, `leaf`, `bullet`, `frame_padding`, plus
`open_trigger` in click_anywhere + click_arrow variants, plus
`span` in default + avail_width variants.  All other fields exist
in the struct from day 1 with `// TODO Step 1.x` annotations
referencing imgui line numbers — they're accepted but treated as
the default (or as their closest wired neighbor).

**API surface added:**

```zig
pub const TreeOpenTrigger = enum { click_anywhere, click_arrow, double_click };
pub const TreeNodeSpan = enum { default, avail_width, full_width, label_width, all_columns, label_all_columns };
pub const TreeNodeDrawLines = enum { none, full, to_nodes };
pub const TreeNodeOpts = struct { /* 13 fields, see source */ };

pub fn treeNodeEx(self: Ui, label: []const u8, opts: TreeNodeOpts) bool;
pub fn setNextItemOpen(self: Ui, open: bool) void;
pub fn isItemToggledOpen(self: Ui) bool;
pub fn treeNodeGetOpen(self: Ui, str_id: []const u8) bool;
pub fn getTreeNodeToLabelSpacing(self: Ui) f32;
```

Plus two new UiContext fields: `next_item_open: ?bool`,
`item_just_toggled: bool`.

**`treeNodeImpl` refactored to a one-line wrapper around
`treeNodeExImpl(label, .{})`** — pre-Step-1.5 callers (`treeNode`
plain) work unchanged.  `treeNodeExImpl` (~150 lines) handles:

- Open-state resolve priority: `setNextItemOpen` > stored >
  `default_open` > closed.  Leaves always return true (no toggle,
  no stored state).
- Geometry: triangle/bullet width + 4px gap + label, with
  optional frame_padding for vertical alignment.
- Span resolution: `default` / `label_width` → natural width;
  `avail_width` / `full_width` / `all_columns` /
  `label_all_columns` → extend to content right edge.
- Hit-test: full rect for click_anywhere/double_click; just the
  indicator for click_arrow.
- Indicator: leaf → nothing (reserves space for alignment);
  bullet → filled square at indicator center; else → triangle.
- Background: `framed` → frame_bg always; `selected` →
  button_hovered (placeholder; filed: dedicated header_* slots);
  hover/active → frame_bg_hovered/active.
- `item_just_toggled` flag set on the release-edge that flips
  state; consumed via `isItemToggledOpen()`.
- Indent push gated on `is_open and !leaf and !no_tree_push_on_open`.

**Demo: `ui_panes.zig` tree pane uses real treeNodeEx.**

Replaced the depth-indented flat list with nested
`treeNodeEx` calls.  Top folder (`zimr`) uses
`.default_open = true`; sub-folders user-toggled.  Files use
`.leaf = true` (no arrow, no toggle, no treePop required).
Dropped the static `TREE` array — the tree is hand-written
inline (8 nodes, 3 collapse-able folders).  Result: tappable
disclosure triangles, real tree UX.

```zig
if (u.treeNodeEx("zimr", .{ .default_open = true })) {
    defer u.treePop();
    if (u.treeNodeEx("src", .{ .default_open = true })) {
        defer u.treePop();
        _ = u.treeNodeEx("ui.zig", .{ .leaf = true });
        // ...
    }
    // ...
}
```

**Tests (8 new, 1426 → 1434):**

- Leaf returns true, no toggle, no stored state on click.
- `default_open` opens on first encounter + persists.
- No `default_open` starts closed.
- `setNextItemOpen` overrides + persists + clears.
- `isItemToggledOpen` surfaces release-edge toggle (not press).
- `treeNodeGetOpen` queries stored state without rendering.
- `getTreeNodeToLabelSpacing` returns font_size + 4.
- Backward compat: plain `treeNode(label)` forwards to
  `treeNodeEx(label, .{})` unchanged.

**Audit:**

- `zig build test`: 1434 / 1434 PASS.
- `zig build smoke-test -Dfocus=ui_panes`: PASS, 10741 GL calls
  (up from 10021 — triangles + frame_bg highlights for tree).
- Standalone: 168 KB wasm → 275 KB bundle.

**Files touched (4):**

- `src/ui.zig`: 4 new enums (`TreeOpenTrigger`, `TreeNodeSpan`,
  `TreeNodeDrawLines`) + `TreeNodeOpts` struct, 5 new public
  APIs, refactored `treeNodeImpl`, new `treeNodeExImpl`,
  2 new UiContext fields, 8 tests.
- `examples/ui_panes.zig`: tree pane rewrite + comment refresh.
- `src/notes/imgui-plan.md`: Step 1.4 marked ✅ DONE.
- `src/notes/changelogs/changelog300-309.md`: this entry.

**Test on phone:**

- Tree pane shows `zimr` folder open by default (`default_open`).
- Inside: `src` folder open by default with 3 leaf files
  (ui.zig, zimr.zig, types.zig).
- `examples` folder *closed* by default — tap the triangle (or
  anywhere on the row) to open.  Inside: 3 example files.
- Leaves have no triangle, no toggle behavior.
- Triangle rotates from right (closed) to down (open) on
  toggle.

**Next turn (309 — Step 1.5 closer):**

1. Wire more flags if testing shows demand (most likely:
   `framed` if anyone wants a section-header-style tree, or
   one more `span` variant).
2. Promote Step 1.5 to ✅ DONE in plan once Simon's phone-tested
   it.
3. Move to Step 1.6 — proper child-window scrolling.

---

### Turn 307 — Step 1.4: setNextWindowSizeConstraints + setWindow*-by-name + L-shape complete

The L-shape demo lands.  `ui_panes` now shows the canonical
3-pane workspace: tree (left, full height) + vertical splitter +
right column.  Inside the right column: editor (top) +
horizontal splitter + output (bottom).  Two splitter axes
exercised in one demo.

Also wires the remaining Step 1.4 API surface:
`setNextWindowSizeConstraints(min, max)` and `setWindow*`
named-window setters (Pos, Size, Focus).

**API additions:**

```zig
pub fn setNextWindowSizeConstraints(self: Ui, min: ?Vector2, max: ?Vector2) void;
pub fn setWindowPos(self: Ui, name: []const u8, pos: Vector2) void;
pub fn setWindowSize(self: Ui, name: []const u8, size: Vector2) void;
pub fn setWindowFocus(self: Ui, name: []const u8) void;
```

`setWindowCollapsed(name, bool)` from the plan is deferred —
zimr doesn't yet have collapsed-window infrastructure (struct
field, chrome render, tap toggle).  Filed in plan deferred
section as "Window chrome polish" follow-up.

**Implementation:**

- Two new `UiContext` fields: `next_window_size_min: ?Vector2`,
  `next_window_size_max: ?Vector2`.  Applied at two sites:
  - `findOrCreateWindow`: clamps the initial size at creation.
  - `openWindow`: clamps `w.size` every frame the constraint is
    set, then resets the constraint fields (per-call semantics
    matching imgui's `SetNextWindow*` family).
- `clampWindowSize(size, min, max)` helper, per-axis independent,
  either bound nullable.
- `setWindowPos/Size/Focus` look up by `hashStr(0, name)` and
  mutate.  No-op on missing window (silent, matches imgui).
- `setWindowSize` marks `user_resized = true` so post-set
  auto-fit doesn't re-grow.

Cond enum (Always/Once/FirstUseEver/Appearing) is filed as
deferred — MVP ships Always-only semantics.  Rationale in plan.

**Demo (`examples/ui_panes.zig`):**

- Added `state.top_h: f32 = 280` for the editor/output split.
- Right column now has nested `beginChild("right", ...)` that
  contains: `beginChild("editor", .{ 0, top_h }, .{})` + `.y`
  splitter + `beginChild("output", .{ 0, bot_h }, .{})`.
- Added `OUTPUT_TEXT` fake build-log content.
- `setNextWindowSizeConstraints(.{ 320, 480 }, null)` called
  every frame to enforce a desktop minimum.  On phone
  (responsive canvas) the window already fills the viewport
  so this is mostly inert; on desktop it stops shrink-to-nothing.
- Run-time clamping of `state.top_h` against `min_top` (60) and
  `min_bot` (60) for the inner split.

**Tests (9 new, 1417 → 1426):**

- `clampWindowSize`: 4 tests covering identity, min, max, per-axis.
- `setWindowPos` / `setWindowSize` / `setWindowFocus`: each
  mutates the named window correctly.
- `setWindowSize` marks `user_resized = true`.
- All three are no-ops on missing window (no panic).
- `setNextWindowSizeConstraints` stores min/max on context;
  either nullable.

**Audit:**

- `zig build test`: 1426 / 1426 PASS.
- `zig build smoke-test -Dfocus=ui_panes`: PASS, 10021 GL calls
  (up from 7141 — the new pane + content).
- Standalone: 166 KB wasm → 271 KB bundle.

**Files touched (4):**

- `src/ui.zig`: 4 new public APIs, `clampWindowSize` helper,
  constraint application sites, 9 tests.
- `examples/ui_panes.zig`: third pane + second splitter +
  `setNextWindowSizeConstraints` call.
- `src/notes/imgui-plan.md`: 3 deferred notes for Step 1.4
  (setWindowCollapsed, callback constraints, Cond enum).
- `src/notes/changelogs/changelog300-309.md`: this entry.

**Next turn (308 — Step 1.4 closer):**

1. Phone polish: review hit-target ergonomics on real device.
2. Maybe tweak default `bar_width`/`hit_extend` if turn 306
   testing showed issues (Simon hasn't tested 1.4 yet — first
   test pass happens this turn).
3. Promote Step 1.4 to ✅ DONE in `imgui-plan.md`.
4. Move on to Step 1.5 — TreeNodeEx flags + tree polish.

---

### Turn 306 — Step 1.4: Splitter API + ui_panes 2-pane scaffold

Step 1.4 kicks off after rubberducking 3 design decisions:

1. **Splitter touch ergonomics**: two-axis opts (`bar_width: f32 = 4` + `hit_extend: f32 = 16`) — thin visible bar + 36px hit zone, decoupling visual from interaction.  Matches imgui's `hover_extend` but exposes both knobs.
2. **Demo layout**: L-shape (left full-height tree + right area top/bottom-split).  Classic IDE; exercises both splitter axes in one demo; phone-feasible.
3. **API surface**: just `Ui.splitter()`, no block-style wrapper.  Matches imgui's `SplitterBehavior`-only approach.  Compose with `beginChild` + `sameLine`.

Plus three small choices declared without rubberduck:

- `setNextWindowSizeConstraints` callback — skip MVP, filed.
- `setWindow*` Cond enum — ship all 4 values when implemented turn 307.
- `hover_visibility_delay` (imgui's lazy-show hover) — skip; immediate hover state.

**Splitter API:**

```zig
pub const SplitterAxis = enum { x, y };  // axis of motion
pub const SplitterOpts = struct {
    bar_width: f32 = 4,
    hit_extend: f32 = 16,    // perpendicular grab pad each side
    min1: f32 = 0,           // first pane min size
    min2: f32 = 0,           // second pane min size
    total_along_axis: f32 = 0, // 0 = use content-region-avail
};
pub fn splitter(self: Ui, str_id, *split_pos, axis, opts) bool;
```

Single `*split_pos` instead of imgui's `*size1, *size2` — caller derives second pane size from `total - split_pos - bar_width`.  Equivalent power, simpler signature.

**Implementation** (`src/ui.zig` ~140 lines):

- `splitterImpl(ctx, str_id, *split_pos, axis, opts) bool`
- Computes visible-bar rect from cursor + split_pos + bar_width.
- Computes interact rect = visible expanded by `hit_extend` perpendicular.
- Hover check on interact rect.
- Click + held tracked via `ctx.active_id` (zimr's standard active-widget pattern).
- Held: `mouse_along - bar_origin_along` = delta; clamped against min1 / `total - split_pos - bar_width - min2`; `*split_pos += delta`.
- Render visible bar with held > hovered > idle color (currently reuses `button*` family — filed: extract dedicated `separator*` Style slots if more widgets want them).
- Advance layout cursor by bar dimension only (perpendicular extent is caller's; consumed by adjacent beginChild calls).
- Citations to `imgui_widgets.cpp:1801-1857` in block comment.

**Tests (6 new, 1411 → 1417):**

- Idle: no input → `*split_pos` unchanged.
- Held drag `.x`: 2-frame test, click on bar center then drift +30, `*split_pos` follows.
- Clamp `min1`: drag far left → clamps at `min1`.
- Clamp `min2`: drag far right → clamps at `total - bar_width - min2`.
- `.y` axis: vertical splitter drags along Y.
- Release: `mouse_left_released` clears `active_id`.

Tests use a `splitterTestSetup` helper that constructs Window + sets `current_window` directly (no full beginFrame).  Multi-frame tests reset `cursor_pos` between calls to simulate `beginFrame`'s reset — caught during testing: `advanceLayout` rightly advances cursor.y when the bar is `.y`-axis, so tests must reset for next "frame".

**Demo: `examples/ui_panes.zig` (stage 1 — 2 panes):**

- State: `gpa` (explicit per claude.md rule), `left_w: f32 = 120`.
- Layout: 1 parent window 380×840.  `beginChild("tree", .{left_w, total_h}, .{})` for left, `splitter(... .x ...)`, `beginChild("editor", .{right_w, total_h}, .{})` for right.
- Content: fake file tree (~8 entries with `[d]`/`[f]` glyphs + depth indent), fake source code (~17 lines).
- Headline + textDisabled cue: "Drag the bar between tree and editor."
- Run-time clamping of `state.left_w` against `min_left` (80) and `max_left` (`total_w - 100 - 4`) prevents window-resize from leaving splitter stuck.

**Audit:**

- `zig build test`: 1417 / 1417 PASS.
- `zig build smoke-test -Dfocus=ui_panes`: PASS, 7141 GL calls.
- Standalone: 164 KB wasm → 268 KB bundle.

**Files touched (4):**

- `src/ui.zig`: `SplitterAxis`, `SplitterOpts`, `splitter` public API, `splitterImpl`, 6 tests + `splitterTestSetup` helper.
- `examples/ui_panes.zig`: new (~140 lines).
- `build.zig`: registered `ui_panes`.
- `src/notes/changelogs/changelog300-309.md`: this entry.

**Next turn (307):**

1. Add bottom output pane: 2nd splitter (`.y` axis) inside the right column.
2. Wire `setNextWindowSizeConstraints(min, max)` + `setWindow*` named variants.
3. Sample uses in the demo (one named-window operation).
4. Phone test.

---

### Turn 305 — Step 1.3 ✅ DONE: phone tap-mode segmented control + step closer

Step 1.3 closes with the phone-affordance UX.  Phones have no
Ctrl/Shift keys, so the canonical MS modifier idiom isn't
reachable via touch.  Today's add: a 3-state segmented control
(Replace / Toggle / Range) that synthesizes the modifier flag on
the input snapshot just before `beginMultiSelect` and restores
immediately after.  The scope captures the synth'd modifier on
its `key_ctrl` / `key_shift` fields at Begin time, so
downstream widgets in the same frame see the real modifier
state (the override is one-shot per Begin).

```zig
const saved_ctrl = u.ctx.input.key_ctrl_down;
const saved_shift = u.ctx.input.key_shift_down;
u.ctx.input.key_ctrl_down = saved_ctrl or (s.tap_mode == .toggle);
u.ctx.input.key_shift_down = saved_shift or (s.tap_mode == .range);

const io = u.beginMultiSelect(...);

// Restore — the scope already captured what it needs.
u.ctx.input.key_ctrl_down = saved_ctrl;
u.ctx.input.key_shift_down = saved_shift;
```

The pattern is general (not MS-specific): any phone-targeted
demo that needs to map a touch UX onto a desktop-modifier model
can do the same.  Filed in the demo's inline comments as the
canonical recipe.

**Step 1.3 plan promoted to ✅ DONE** in `imgui-plan.md`.  Full
arc recap there (turns 303-305).  All known limitations filed
(Ctrl-A wiring, nestable scopes, adapter, kb-nav range preview,
box-select, right-click).

**Audit:**

- `zig build test`: 1411 / 1411 PASS (unchanged from turn 304 —
  new code is demo-only).
- `zig build smoke-test -Dfocus=ui_multiselect_finder`: PASS.
  GL call count grew 4921 → 5881 (the 3 new buttons + extra
  separator).
- Standalone: 173 KB wasm → 281 KB bundle.

**Files touched (3):**

- `examples/ui_multiselect_finder.zig`: added `TapMode` enum +
  `tap_mode` State field, 3-button segmented control above
  file list, modifier synth around `beginMultiSelect`, refreshed
  comments + status footer.
- `src/notes/imgui-plan.md`: Step 1.3 entry rewritten as ✅
  DONE turn 305 with arc recap + known limitations.
- `src/notes/changelogs/changelog300-309.md`: this entry.

**Test on phone:**

- Tap-mode = Replace: tap one row replaces selection.
- Tap-mode = Toggle: tap each row to add/remove (no clearing of
  others).
- Tap-mode = Range: tap one row to set anchor; tap another row
  to select inclusive range from anchor to that row.  Subsequent
  taps continue extending from anchor (Shift-click semantics).
- Tap-mode = Replace then tap empty area below file list:
  `clear_on_click_void` clears selection.
- Select All / Clear All buttons work in any mode (they bypass
  the MS scope entirely).
- Re-tap a selected row in Replace mode: selection clears
  except for that row (no_auto_clear_on_reselect = true).

**Next: Step 1.4 — Splitter + window-size-constraints +
setWindow*.**  `ui_panes.zig` 3-pane workspace demo, draggable
splitters between file-tree / editor / output.  Likely the
most-screenshottable Phase 1 demo.

---

### Turn 304 — Step 1.3: click→request emission, Header/Footer hooks, integration tests

Real Begin/End logic + per-item click hooks land.  This is the
substantive turn for Step 1.3 — after turn 303's scaffolding, the
demo now uses the canonical MS-scope idiom with no manual
click-toggle: `_ = u.selectable(...)` and storage updates via
`applyRequests` only.

**The click → request truth table is implemented** (tutorial § 9):

| Action       | Modifiers   | Emitted requests                       |
|--------------|-------------|----------------------------------------|
| Mouse press  | none        | SetAll(false) + SetRange(item, true)   |
| Mouse press  | Ctrl        | SetRange(item, !was_selected)          |
| Mouse press  | Shift       | SetAll(false) + SetRange(anchor..item, true) |
| Mouse press  | Ctrl+Shift  | SetRange(anchor..item, anchor_state)   |
| Escape       | (focused)   | SetAll(false) [if clear_on_escape]     |
| Click void   | —           | SetAll(false) [if clear_on_click_void] |
| Re-tap on selected | none  | SetRange(item, true) only — no clear   |
|              |             | [if no_auto_clear_on_reselect]         |

What landed in `src/ui.zig`:

- `beginMultiSelectImpl`:
  - Tears down prior scope's request buffer.
  - Reads scope id from id-stack top (or window id fallback).
  - getOrPut on `ms_storage`; updates last_frame_active +
    last_selection_size.
  - Allocates transient `MultiSelectScope` in
    `ctx.current_multi_select` with key-mods snapshot,
    is_focused tracking, empty requests_buf.
  - Keyboard shortcut: Escape → `addSetAllRequest(false)` if
    `clear_on_escape` and selection non-empty.
  - Sets `loop_request_set_all` so Header overrides this frame's
    `selected` to match the pending request.
  - Ctrl+A scaffolding present but currently inert (filed:
    InputSnapshot doesn't yet expose per-letter key edges —
    need a `key_a_pressed: bool` or equivalent shortcut API).

- `endMultiSelectImpl`:
  - ClearOnClickVoid detection: if mouse-left-clicked AND
    nothing hovered, emit `set_all(false)`.  Drops prior pending
    requests if Footer hasn't already (`is_end_io` semantics
    match imgui).
  - Snapshots final requests slice + anchor/nav state onto io.

- `multiSelectItemHeader`:
  - When LoopRequestSetAll is set (from Begin's Escape), forces
    `selected` to match — so this frame's render reflects the
    request, not the pre-shortcut state.
  - Returns `selected` (zimr's selectable doesn't yet use the
    ButtonBehavior abstraction, so we skip imgui's button_flags
    mutation — filed if/when we factor selectable that way).

- `multiSelectItemFooter`:
  - Consumes `ctx.next_item_selection_user_data` slot (clears
    after read — matches imgui).
  - First emit per End-IO cycle drops Begin's pending requests
    (the `is_end_io` rebase).
  - Auto-clear logic: SingleSelect → always clear;
    `no_auto_clear_on_reselect` → clear only when target was
    unselected; else → always clear (when not Ctrl).
  - Range computation: Shift+not-single → anchor..item with
    direction; else → single-item range with anchor moving.
  - Persists anchor (`range_src_item`) + selected-ness
    (`range_selected`) for next frame's shift-click.
  - `no_auto_select` + `no_range_select` flags wired correctly.

- `addSetAllRequest` / `addSetRangeRequest`: thin helpers that
  match imgui's `MultiSelectAddSetAll` / `MultiSelectAddSetRange`
  (the former wipes prior requests; the latter appends).

- `selectableImpl`: Header called before click detection (may
  override `selected`); Footer called after with `pressed` =
  this-frame's `clicked` bool.  Both no-op when no MS scope is
  active.  Outside-scope behavior preserved (return value
  unchanged → existing callers work as before).

What landed in tests (10 new): all under "Step 1.3 turn 304:
MultiSelect Begin/End + click-emit integration tests".  Each
test drives a synthesized UiContext (no full beginFrame
plumbing) through one or more Begin/Footer/End cycles and
asserts the resulting `io.requests` slice byte-for-byte
against the truth table.  Coverage:

- Plain click → 2 requests (clear + range).
- Ctrl-click on unselected → 1 request, no clear.
- Ctrl-click on selected (toggle off) → 1 request, no clear.
- Shift-click after plain-click → 2 requests, correct
  anchor..target range, correct direction (`+1`).
- Escape + clear_on_escape + nonempty → 1 SetAll(false)
  from Begin + `loop_request_set_all = .clear`.
- Escape ignored without clear_on_escape.
- Escape ignored when selection empty.
- clear_on_click_void + void click → 1 SetAll(false) from End.
- no_auto_clear_on_reselect + re-tap on selected → 1
  SetRange, no preceding clear.
- no_range_select + Shift-click → behaves as plain click.

Demo refactor (`examples/ui_multiselect_finder.zig`):

- Removed `selection_mode` placeholder field.
- File-list loop now wrapped by Begin/End:
  ```zig
  const io = u.beginMultiSelect(.{
      .clear_on_escape = true,
      .no_auto_clear_on_reselect = true,
      .clear_on_click_void = true,
  }, @intCast(s.selection.size()), @intCast(FILES.len));
  s.selection.applyRequests(s.gpa, io) catch {};
  for (...) |item, idx| {
      u.setNextItemSelectionUserData(@intCast(idx));
      _ = u.selectable(...);
  }
  const io2 = u.endMultiSelect();
  s.selection.applyRequests(s.gpa, io2) catch {};
  ```
- Headline updated: "Tap row to replace; Ctrl+tap to add/toggle;
  Shift+tap to range; Esc to clear."
- Status footer notes phone limitation (no Ctrl/Shift) + the
  selection-mode toggle landing in turn 305.

**Audit:**

- `zig build test`: 1411 / 1411 PASS (10 new integration tests).
- `zig build smoke-test -Dfocus=ui_multiselect_finder`: PASS.
- Standalone: 173 KB wasm → 281 KB bundle.
- `.zig-cache` was 5.1 GB → cleared; rebuild from scratch
  completed cleanly.

**Files touched (3):**

- `src/ui.zig` — Header/Footer/Begin/End impls, addSetAll/Range
  helpers, selectableImpl integration, 10 integration tests.
- `examples/ui_multiselect_finder.zig` — refactor to MS scope
  idiom.
- `src/notes/changelogs/changelog300-309.md` — this entry.

**Next turn (305 — Step 1.3 closer):**

1. Phone-affordance: "Selection mode" toggle button.  When
   active, taps behave as Ctrl-clicks (toggle each item
   independently).  Maybe also a "Range mode" toggle for
   Shift-equivalent.  Persistent state on the demo's State.
2. Maybe revisit Ctrl+A wiring once we decide whether to add
   `key_a_pressed` (and per-letter neighbors) to
   `InputSnapshot` — small change, real-world value debatable
   on phone, but desktop users would expect it.
3. If everything lands cleanly: promote Step 1.3 to ✅ DONE in
   `imgui-plan.md`.

---

### Turn 303 — Step 1.3: types, SelectionBasicStorage, scaffolded demo

First substantive turn on Step 1.3 (MultiSelect + SelectionBasicStorage)
after rubberducking 6 design decisions earlier in the session:

1. SelectionUserData = `?u64` (idiomatic Zig optional, not `-1` sentinel).
2. `SelectionBasicStorage` ships without the index→ID adapter for
   MVP — indexes ARE IDs.  Adapter deferred (filed in plan).
3. Per-scope persistent state lives in `AutoHashMapUnmanaged(Id,
   MultiSelectState)` on `UiContext` — matches imgui's
   `g.MultiSelectStorage`.
4. MVP recognizes 6 effective flags (`selection`, `clear_on_escape`,
   `no_select_all`, `no_range_select`, `no_auto_clear_on_reselect`,
   `clear_on_click_void`); other 11 fields exist in the struct from
   day 1 with `// TODO Step 1.x` annotations citing imgui line refs.
5. Single-slot active scope (`current_multi_select: ?MultiSelectScope`
   on UiContext) — no nesting in MVP, deferred.
6. `selectable()` signature unchanged; multi-select hooks are
   additive — matches imgui literally.

**Tutorial + claude.md updates (the meta-level):**

- New tutorial doc: `src/notes/multiselect-tutorial.md`.  Studies
  `/tmp/imgui-master/` source (v1.92.8 WIP), cites file:line for
  every claim.  Sections: mental model, three-phase flow, types,
  click→request truth table, mapping to Zig idioms, MVP scope.
- claude.md gained four new rules:
  - **Port the source you can see, not the source you remember**
    — always read upstream before writing port code; ask if you
    can't fetch.
  - **Rubberducking** — formal definition: one question at a time,
    options + recommendation, then refine plan.
  - **Build the demo in parallel with the API** — every turn
    should leave Simon something to phone-test.
  - **Allocator lives on user State, not pulled from `ctx.gpa`**
    — preserves the "provably no per-frame alloc" property.  Demo
    template + rationale included.
  - **Don't present what you haven't verified** — sandbox-side
    sanity checks before `present_files`.

**Code landed this turn:**

- `src/ui.zig`:
  - `InputSnapshot.key_ctrl_down: bool`, polled from
    `left_control`/`right_control` (parallels `key_shift_down`).
  - `MultiSelectFlags` struct (17 fields — 4 enums, 13 bools).
  - `SelectionRequest` union (`set_all: bool` /
    `set_range: struct{first, last, direction, selected}`).
  - `MultiSelectIO` struct (`requests: []const SelectionRequest`,
    optionals for anchor/nav_id, `items_count`).
  - `MultiSelectState` (per-scope persistent: anchor,
    range_selected, nav_id, nav_id_selected, last_frame_active,
    last_selection_size).
  - `MultiSelectScope` (transient single-slot: id, storage ptr,
    flags, key_mods snapshot, io, requests_buf ArrayList, plus
    bookkeeping flags for turn 304 — loop_request_set_all,
    range_src_passed_by, is_focused, is_end_io).
  - `SelectionBasicStorage` (AutoHashMap of selected u64 ids;
    methods: `deinit`, `size`, `contains`, `add`, `remove`,
    `clear`, `applyRequests` — the conceptual 10-line version
    from imgui_widgets.cpp:8683+ paraphrased).
  - 3 new fields on UiContext: `ms_storage`, `current_multi_select`,
    `next_item_selection_user_data`.
  - UiContext.deinit handles `ms_storage` + tears down any
    leftover scope's requests_buf.
  - Public API on `Ui`: `beginMultiSelect`, `endMultiSelect`,
    `setNextItemSelectionUserData`.
  - `beginMultiSelectImpl`/`endMultiSelectImpl` — Turn 303
    minimal: push/pop scope, set up IO with empty requests +
    persistent-state-snapshot anchor/nav.  Real click→request
    emission lands turn 304.
  - 12 new tests for SelectionBasicStorage (1389 → 1401):
    empty/add/contains/remove/clear, applyRequests with
    `SetAll(true)` / `SetAll(false)` / `SetRange forward` /
    `SetRange backward` / `SetRange unselect` / typical
    shift-click pair (clear + range) / Ctrl-click toggle.
- `examples/ui_multiselect_finder.zig` (new, ~250 lines):
  Finder-style 50-item file list (folders + documents + images
  + archives + code).  Selection HUD ("selected: N / 50"),
  Clear-All + Select-All buttons (the latter exercises
  applyRequests with SetAll(true) end-to-end).  File rows are
  Selectable widgets tagged with
  `setNextItemSelectionUserData(idx)`; click handler uses the
  imgui_demo.cpp:2724 "manual / simplified" pattern for now
  (replace-selection on tap).  Demo state has `gpa:
  std.mem.Allocator` as an explicit field per the new claude.md
  rule.
- `build.zig` — registered ui_multiselect_finder.
- `src/notes/imgui-plan.md` — filed two deferred notes:
  nestable scopes; SelectionBasicStorage adapter (with
  reorderable-list shine note Simon requested).

**Audit:**

- `zig build test`: 1401 / 1401 PASS (12 new tests, all passing).
- `zig build smoke-test -Dfocus=ui_multiselect_finder`: PASS
  (wasm instantiates, 60 frames execute, ~4900 GL calls without
  trap).  This is the sanity check the new "Don't present what
  you haven't verified" claude.md rule mandates.
- `python3 scripts/build_standalone.py ui_multiselect_finder`:
  built ReleaseSmall, 168 KB wasm → 275 KB bundle.

**Files touched (5):**

- `src/ui.zig` — types, public API, impls, tests.
- `examples/ui_multiselect_finder.zig` — new demo.
- `build.zig` — registered example.
- `src/notes/claude.md` — 4 new rules (port source, rubberducking,
  parallel demo, allocator on State, no unverified presentation).
- `src/notes/multiselect-tutorial.md` — new tutorial.
- `src/notes/imgui-plan.md` — deferred notes.
- `src/notes/changelogs/changelog300-309.md` — this entry.

**Next turn (304):** Wire the real click→request emission.

1. Add `multiSelectItemHeader` / `multiSelectItemFooter` internal
   helpers (`imgui_widgets.cpp:8208-8525` equivalent).  Footer is
   where the click → request truth table from tutorial § 9 lives.
2. Hook them into `selectableImpl` after `id` is computed +
   before the click→state-mutate path: header before
   ButtonBehavior-equivalent, footer after.
3. Wire keyboard shortcuts in `beginMultiSelect`: Escape →
   `set_all(false)` if `clear_on_escape`; Ctrl-A →
   `set_all(true)` if not `no_select_all`.
4. Wire `clear_on_click_void` in `endMultiSelect`: detect
   click landed in scope rect but no item → emit `set_all(false)`.
5. Refactor demo's click handling to the post-MS-active
   idiom: `_ = u.selectable(row, sel.contains(id), .{});`
   (caller discards bool because storage handles toggle via
   applyRequests).  Add Ctrl-click / Shift-click testing.
6. Audit + smoke + standalone + snapshot.

---

### Turn 302 — Step 1.8 ✅ DONE: HUD removed, Step 1.8 closed, ready for Step 1.3

Simon's two screenshots turn 302 confirmed Step 1.8 working
end-to-end on phone:

- **Image 1** (filter focused, keyboard up): overlay sits
  exactly over the wasm Filter widget at canvas y≈418.  "yfd"
  typed via mobile keyboard, rendered in the DOM input.  No
  drift, no lift, no immediate dismiss.
- **Image 2** (defocused, keyboard down): wasm-rendered
  Filter widget shows "yfd" — text persisted from overlay
  buffer.  Full window content visible: header, preamble,
  Controls section (auto-scroll, Add 1, Clear, Top), Log
  separator, Filter, Status section ("lines: 281, shown: 0",
  "auto-scroll: on", "(tap below for help ?)").  Canvas
  full-size.

Simon: "Perfect... wow that was hard, but satisfying, right?
Now there is a debug display that needs cleanup, and we can
continue with the plan?"

**Cleanup this turn:**

- Removed `DEBUG_OVERLAY_COORDS` flag (was `true` for the
  whole iteration arc 297-301).
- Removed `ensureCoordHud` factory + the HUD-writing block
  in `js_show_overlay_input` (~30 lines total).
- Bundle size: 287 KB → 284 KB.  ESBuild doesn't DCE
  `if (false) { ... }` blocks reliably for module-scope
  factories, so outright removal was correct.
- `runtime_screen_width / runtime_screen_height` wasm
  exports KEPT — still used by `wasmRectToCss` for the
  stretch-mode coord conversion (see comment in that helper).

**Step 1.8 plan entry promoted to ✅ DONE turn 302** in
`src/notes/imgui-plan.md`.

**The full Step 1.8 arc, in retrospect (turns 282-302):**

| Turns | What |
|-------|------|
| 282-283 | Step 1.7 hidden-input prototype — partially working. |
| 290-291 | Diagnosed hidden-input dead ends.  Backspace race vs imgui issue #5133, first-tap activation requirements, soft-keyboard scroll-into-view incoherence. |
| 292 | Read zhobo63/imgui-ts source.  Architectural shift: visible DOM overlay over the widget, not a hidden input. |
| 293 | Step 1.8 prototype shipped.  4 wasm externs, ~150 lines TS, ~60 lines zig.  Backspace, IME, scroll-into-view all native. |
| 294 | Cleanup of dead hidden-input infra (`scrollFocusedWidgetIntoView`, `saved_scroll` field, ~150 lines deleted). |
| 295 | Scale-mode-aware coord conversion (`wasmRectToCss`).  Coord systems doc added to claude.md.  Stretch-mode hit-test mismatch filed as accepted limitation. |
| 296 | Window-content clip helper added.  Catches the "scroll widget off-window" case. |
| 297 | Canvas-bound clip added (wrong) + debug HUD added.  Phone test showed keyboard pops-then-immediately-dismisses. |
| 298 | Canvas-bound clip reverted.  HUD screenshot proved coord conversion was correct all along. |
| 299 | Body bg matched canvas bg to hide visualViewport-shrink seam. |
| 300 | Realized visualViewport canvas-shrink was the root cause of multiple bugs.  Removed it; tried overlay-lift-above-keyboard as replacement. |
| 301 | Lift was buggy (mispositioning even when widget was above keyboard).  Removed lift entirely.  Overlay sits exactly at wasm widget position. |
| 302 (this) | Cleanup of debug HUD; Step 1.8 closed. |

**What zimr now has that hidden-input couldn't deliver:**

- First-tap activation works on Android Chrome (within
  the sticky-activation policy — see Known Limitations
  below).
- Backspace works.
- IME works.
- Selection works (cursor placement, range select via
  long-press).
- Copy/paste works.
- Mobile-keyboard "Done" / Enter dismisses.

**Known limitations** (filed in Step 1.8 plan, accepted):

- **First-touch on a fresh page** doesn't pop keyboard on
  Android Chrome until any prior user gesture has occurred.
  Tried canvas pre-focus, eager overlay create, touchstart
  pre-focus; none work within Android's sticky-activation
  policy.
- **Stretch-mode hit-test mismatch** when canvas.clientWidth
  ≠ cfg.window.width.  Doesn't bite because responsive is
  the default for phone demos.
- **Keyboard occlusion** if a text widget is activated when
  below the keyboard's eventual position.  Practically
  impossible to trigger via tap (user can't tap an occluded
  widget); only reachable via `setKeyboardFocusHere` on a
  widget below where the keyboard lands.  Revisit if a real
  demo hits it.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.  Verified zero
  `zimr-coord-hud` references in the bundle.

**Files touched (3):**

- `src/web/zimr.ts` — removed `DEBUG_OVERLAY_COORDS` const,
  `ensureCoordHud` function, and the HUD block in
  `js_show_overlay_input`.
- `src/notes/imgui-plan.md` — Step 1.8 promoted from
  🟡 PROTOTYPE turn 293 to ✅ DONE turn 302.  Brief polish
  history added.
- `src/notes/changelogs/changelog300-309.md` — this entry.

**Next turn (303):** Step 1.3 — MultiSelect +
SelectionBasicStorage.  Next item in the plan order after
Step 1.2.  Step 1.3 will likely need re-reading the plan
spec to refresh on scope (~3 turns earlier, before the
keyboard arc consumed attention).

---

### Turn 301 — Step 1.8: remove the lift; overlay sits exactly where the wasm widget is

Simon's turn 301 phone screenshot showed the "lift overlay
above keyboard" logic (added turn 300) firing in wrong
situations.  Wasm Filter widget rendered at CSS y=316 (well
above the keyboard at CSS y≈545), but the overlay was lifted
up to CSS y=~200 — landing next to the Clear button instead
of over the Filter widget.

Simon: "Ok so now we don't have the wrong scissor, but the
dom element is at the wrong place.  It was at the correct
place before."

Likely root cause: `visualViewport.height` reporting
unexpected values during keyboard animation (transition
frames where vv.height is less than the post-keyboard
visible area), tripping the `wantedTop + overlayH > vvH`
check and shifting the overlay upward.  Could probably be
patched with a debounce or a "use minimum over a window"
strategy, but the underlying need (handle widgets below the
keyboard) doesn't actually arise in current demos — the
text widget the user CAN tap is, by definition, above
where the keyboard ends up.

**This turn: remove the lift entirely.**

- Replaced the `visualViewport.resize/scroll` listener +
  `liftOverlayAboveKeyboard` function with a comment-only
  block explaining why we're doing nothing.  Inline comment
  documents both the canvas-shrink lineage (removed turn 300)
  and the lift attempt (removed turn 301) so the next person
  who's tempted to add visualViewport handling has the prior
  art at hand.
- Removed `state.liftOverlayAboveKeyboard` field.
- Removed the `state.liftOverlayAboveKeyboard?.()` calls in
  `js_show_overlay_input` and `js_update_overlay_input_rect`.
- KEPT `state.overlayInputWasmRect` — repurposed as
  "current rect" tracking.  Set on show / update, cleared on
  blur.  Reserved for the debug HUD and any future
  keyboard-aware positioning attempt.

**Result:** the overlay's CSS top/left/width/height are set
purely from the wasm widget's CSS-converted rect.  Per-frame
update tracks the widget as the user drags the window or
scrolls the content.  No JS-side repositioning beyond the
wasm-given coords.

**Trade-off accepted:** if a future demo activates a text
widget below the keyboard's eventual position (e.g. via
`setKeyboardFocusHere` programmatically), the overlay would
land under the keyboard and the user couldn't see what
they're typing.  Filed as a Step 1.8 followup; revisit if a
real demo needs it.  In practice users can only tap visible
widgets, so they can only activate widgets above the
keyboard — once activated, the keyboard pops up *below* the
overlay and stays there.

**Step 1.8 status:** functionally complete.  Still has
DEBUG_OVERLAY_COORDS + HUD code in place.  Next turn:
flip the debug flag off and remove HUD code, then promote
the plan entry to ✅ DONE.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (2):**

- `src/web/zimr.ts` — visualViewport listener block replaced
  with comment-only block.  `liftOverlayAboveKeyboard` field
  removed from RuntimeState.  Lift calls removed in
  show / update.  `overlayInputWasmRect` retained.
- `src/notes/changelogs/changelog300-309.md` — this entry.

**Next turn:** Simon tests; expected outcome — overlay sits
directly over the wasm Filter widget, no drift, keyboard
pops up below.  If confirmed:
- Flip `DEBUG_OVERLAY_COORDS = false`.
- Remove `ensureCoordHud` + HUD update block.
- Mark Step 1.8 ✅ DONE in `imgui-plan.md`.
- Move to Step 1.3 (MultiSelect + SelectionBasicStorage).

---

### Turn 300 — Step 1.8: replace visualViewport canvas-shrink with overlay-lift-above-keyboard

Simon's turn 299 screenshot showed a new failure mode of the
visualViewport canvas-shrink approach: the wasm window stays at
its initial 380×840 size, but the canvas's CSS height shrinks
to ~150 (the post-keyboard visible area).  GL clips wasm
drawing at canvas_h=150; the window content from y=0 to y=150
is visible (just header + Controls separator + auto-scroll
checkbox), the rest is GL-clipped to invisible.  The DOM
overlay (position:fixed at canvas y=418, per the HUD from
turn 298) sits in the body-bg area below where the wasm
canvas content ends.  Result: disjointed UX — overlay floats
without its surrounding wasm-rendered widget.

Simon's diagnosis: "hide or maybe scissor so we don't see a
big part of the widget anymore."

Realization: **the visualViewport canvas-shrink is the root
cause of bugs across this whole arc.**

- turn 297: shrunk canvas made the canvas-bound clip helper
  hide the overlay on every keyboard pop.
- turn 298: removed canvas-bound clip but kept the shrink,
  which left wasm widgets logically-on-canvas but visually-
  off-canvas.
- turn 299: cosmetic body-bg seam.
- turn 300: window content past the shrunken canvas height
  is GL-clipped → disjointed overlay.

The shrink made sense in the hidden-input era (the wasm
widget WAS the editor, so it had to fit in visible area).
With the DOM overlay (Step 1.8), the wasm widget no longer
needs to be visible while the user edits — the overlay is
the editor.

**The fix:**

1. **Removed the visualViewport canvas-shrink listener.**
   Canvas now stays at its full `100vh` size regardless of
   keyboard state.  Wasm widgets all draw at their natural
   positions.  No more GL-clipping mid-window-content.

2. **Replaced with overlay-lift-above-keyboard.**  New
   `liftOverlayAboveKeyboard` function attached to
   `visualViewport.resize` + `visualViewport.scroll`.  When
   the overlay's CSS bottom would be below the visual viewport's
   bottom (i.e. occluded by the keyboard), the function sets
   the overlay's `style.top` to `vv.height - overlay.height
   - 4px`.  Effect: the overlay slides up to sit just above
   the keyboard.

3. **Source-of-truth rect tracking.**  `state.overlayInputWasmRect`
   holds the CSS-pixel rect the overlay WOULD occupy if the
   keyboard weren't up.  Set on every show / update; cleared
   on blur.  The lift function reads from this, not from the
   current `style.top` — otherwise repeated visualViewport
   resizes would chase a moving target as `style.top` is the
   *lifted* value.

4. **show + update both call `liftOverlayAboveKeyboard?.()`**
   after setting the wasm-given position.  Handles the case
   where the keyboard is already up (e.g. activation came from
   `setKeyboardFocusHere` after another field was focused).

**Why this is the right architecture:**

Mirrors what native browsers do for `<input>` elements.
Native browsers use page scroll-into-view to bring the
focused input above the keyboard.  Our overlay is
`position: fixed` (can't page-scroll), so we do it manually:
when keyboard is up, lift the overlay.

The wasm-rendered widget stays at its natural position.  If
the keyboard happens to cover it visually, that's fine —
the user interacts with the (lifted) overlay, and on defocus
the keyboard dismisses and the widget becomes fully visible
with the typed text.

**What this fixes (recap):**

- Disjointed overlay (turn 300): wasm widget no longer
  GL-clipped, so visible regions match what the overlay
  shows.
- Immediate-dismiss (turn 297-298): no canvas-shrink means
  no canvas-clip-fires-on-pop.
- Body-bg seam (turn 299): no shrink, no gap.

**Cleanup not done this turn (deferred to turn 301):**

- `DEBUG_OVERLAY_COORDS` still `true`; HUD code still in
  place.  Want one more Simon test pass to confirm
  everything's good first.
- Step 1.8 plan promotion to ✅ DONE.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (3):**

- `src/web/zimr.ts` — replaced visualViewport block (canvas-
  shrink, ~70 lines) with overlay-lift-above-keyboard block
  (~50 lines).  Added `overlayInputWasmRect` +
  `liftOverlayAboveKeyboard` to RuntimeState.  Wired
  show/update to stash rect + call lift.  Cleared rect on
  blur.
- `src/notes/changelogs/changelog290-299.md` — frozen.
- `src/notes/changelogs/changelog300-309.md` — new (this
  file).

**Decade rollover:** changelog290-299.md is frozen with `## [Frozen
at turn 300]` heading.  Active changelog is now changelog300-309.md.

**Next turn (301):** Simon tests; expected outcome — overlay
shows above keyboard, wasm widget renders normally on canvas
behind keyboard (covered visually but consistent state).  No
more disjoint-overlay floating in empty space.

If that's confirmed:
- Flip `DEBUG_OVERLAY_COORDS = false`.
- Remove `ensureCoordHud` + HUD update block (~30 lines).
- Promote Step 1.8 to ✅ DONE in `imgui-plan.md`.
- Move to Step 1.3 (MultiSelect + SelectionBasicStorage).
