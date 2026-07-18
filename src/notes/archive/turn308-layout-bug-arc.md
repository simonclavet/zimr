# Turn 308 — the layout bug chain

A tutorial walking through the three foundational zimr layout bugs
discovered and fixed in turn 308, plus the smaller `treePop`
asymmetry fixed in the same turn.  Each bug masked the next, so they
could only be diagnosed in order — each phone screenshot exposed the
next layer.

## 0. Setting the scene

The plan for Step 1.5 was `treeNodeEx` — the flag-supporting variant
of the simple `treeNode(label)`.  The demo was `ui_panes`, a
three-pane workspace L-shape:

```
+-----------+----------------+
|           |                |
|  tree     |   editor       |
|           |                |
|           +----------------+
|           |                |
|           |   output       |
+-----------+----------------+
```

Built around one vertical splitter (between tree and the right
column) and one horizontal splitter (between editor and output).
The most-visible Phase 1 demo — the kind of layout that signals
"this UI library can do real work."

The treeNodeEx code landed.  Tests passed.  Then the phone screenshot
came in: tree pane visible, splitter and right column nowhere to be
seen.

Three bugs in a row, each invisible until the one before it was
fixed.

---

## 1. Bug — `sameLine` didn't keep widgets on the same row

### Symptom

The screenshot showed only the tree pane.  The splitter (a 4px blue
bar that should sit at the tree pane's right edge) wasn't visible
anywhere.  The right column (editor + output) wasn't there either.

### Diagnostic

I'd assumed `sameLine` worked.  I hadn't actually tested that two
widgets called with `sameLine` between them landed on the same row.
Wrote a quick observational test:

```zig
test "DIAG sameLine: same-Y semantics" {
    var ctx = UiContext.init(std.testing.allocator);
    defer ctx.deinit();
    const w = splitterTestSetup(&ctx);
    w.cursor_pos = .{ 8, 8 };

    const u = Ui{ .ctx = &ctx };
    _ = u.button("A", .{});
    const a_y = w.last_item_rect.y;
    u.sameLine(.{});
    _ = u.button("B", .{});
    const b_y = w.last_item_rect.y;

    std.debug.print("A.y={d} B.y={d} same={}\n", .{ a_y, b_y, a_y == b_y });
}
```

Output:

```
A.y=8 B.y=28 same=false
```

B was 20px BELOW A.  `sameLine` was placing the next widget on the
NEXT row, just shifted slightly right.  In dense button rows where
items are the same height, the 4px stagger looks like the
`item_spacing[1]` gap — visually invisible.  But it was wrong.

A second test with `endChild`:

```
child.y=8 child.h=200; after.y=212 after.x=116
```

After `endChild` + `sameLine`, the next widget was at Y=212 — 200px
below the child's top.  The splitter (which comes right after that
sequence) was being rendered 200+ pixels below the canvas.  Hence
invisible.

### What was wrong

zimr's `sameLine`:

```zig
pub fn sameLine(self: Ui, opts: SameLineOpts) void {
    const w = self.ctx.current_window orelse return;
    w.pending_same_line = true;
    if (opts.offset_x > 0) w.cursor_pos[0] = w.pos[0] + opts.offset_x;
}
```

Just flagged `pending_same_line` and (optionally) set X.  Never
touched Y.

`resolveCursor` consumed the flag:

```zig
fn resolveCursor(w: *Window, spacing_x: f32) Vector2 {
    if (w.pending_same_line) {
        w.pending_same_line = false;
        return .{ w.cursor_max[0] + spacing_x, w.cursor_pos[1] };
    }
    return w.cursor_pos;
}
```

The bug: `cursor_pos[1]` had already been ADVANCED past the previous
widget's bottom by `advanceLayout` at the end of the previous widget:

```zig
w.cursor_pos[1] = placed_at[1] + w.line_height + item_spacing[1];
```

So when sameLine fired, the next widget's `(prev_right + spacing,
cursor_pos[1])` resolved to `(prev_right + spacing, NEXT_row_top)` —
same column, next row.

### How imgui does it (`imgui.cpp:11438`)

```cpp
void ImGui::SameLine(float offset_from_start_x, float spacing_w) {
    // ...
    window->DC.CursorPos.x = window->DC.CursorPosPrevLine.x + spacing_w;
    window->DC.CursorPos.y = window->DC.CursorPosPrevLine.y;   // restore Y
    window->DC.CurrLineSize = window->DC.PrevLineSize;
    window->DC.IsSameLine = true;
}
```

Two key things:

1. imgui tracks `CursorPosPrevLine` separately — `(right_edge_of_last_item,
   top_of_current_row)`.  `SameLine` restores `CursorPos.y` to row-top.
2. imgui carries forward `PrevLineSize.y` so the NEXT advance correctly
   clears the tallest widget on the row.

### The fix

`w.last_item_rect` is structurally equivalent to imgui's
`CursorPosPrevLine`.  Use it:

```zig
pub fn sameLine(self: Ui, opts: SameLineOpts) void {
    const w = self.ctx.current_window orelse return;
    const item_sp_x = self.ctx.style.item_spacing[0];
    // X = right of last item + spacing (or explicit offset).
    // Y = top of last item.
    // line_height = last item's height — so advanceLayout's
    //   "next row" position correctly clears the tallest widget
    //   on this row.
    w.cursor_pos[0] = if (opts.offset_x > 0)
        w.pos[0] + opts.offset_x
    else
        w.last_item_rect.x + w.last_item_rect.width + item_sp_x;
    w.cursor_pos[1] = w.last_item_rect.y;
    w.line_height = w.last_item_rect.height;
    w.pending_same_line = false;
}
```

`pending_same_line` is no longer needed — cursor_pos directly
reflects the resolved position.  Kept as `false` for safety in case
old code paths still check it.

After the fix:

```
A.y=8 B.y=8 same=true
child.y=8; after.y=8 after.x=116
```

Splitter visible.

This fix also retroactively corrected every other zimr widget call
that used `sameLine` — `log_viewer`'s button rows, `imgui_demo`'s
side-by-side panes, etc.  They'd all been slightly staggered.  Now
they sit on actual rows.  1437/1437 tests still passed, which
itself was diagnostic — no test had been pinning down the broken
behavior.

---

## 2. Bug — `advanceLayout` used the WRONG origin inside child windows

### Symptom

After the sameLine fix, the next phone screenshot showed splitter +
right column visible.  But the **editor pane's text was clipped
from the LEFT**:

```
+- Workspace ------------+
| Tree       |          E|     ← editor pane
| ▼ zimr     | emo for...|       shows only the END
|            | );        |       of each line
|            | );        |
|            |           |
+------------------------+
```

A line like `// Three-pane workspace demo for Step 1.4.` showed only
`emo for Step 1.4.` — chars 28-46 visible, chars 0-27 clipped.

### Diagnosis

`advanceLayout`:

```zig
fn advanceLayout(w: *Window, consumed: Vector2, item_spacing: Vector2, window_pad_x: f32) void {
    // ...
    w.cursor_pos[1] = placed_at[1] + w.line_height + item_spacing[1];
    w.cursor_pos[0] = w.pos[0] + window_pad_x + w.indent_x;   // ← bug
    w.line_height = 0;
}
```

`w.pos[0]` is the **parent window's** position.  Inside a child
window (e.g., the editor pane's `beginChild`), every wrapped row
reset cursor X to the **parent window's** content-left, NOT the
**child's** inner-left.

For the tree pane (which happened to anchor at workspace's
content-left, x=16), the formula's output coincidentally matched the
tree's inner-left.  So tree content rendered fine.

For the editor pane (anchored at x=140 after `sameLine` + splitter),
every row reset cursor.x to x=16 — way to the left of the editor's
visible area.  The editor's clip rect (pushed by `beginChild`) then
scissored that content.  We saw the slice that happened to fall
inside the editor's clip — chars ~14-46 of each long line.

### How imgui sidesteps this

imgui's `BeginChild` creates a **separate** `ImGuiWindow` struct.
Inside the child, `window->Pos.x` IS the child's pos.  `ItemSize`:

```cpp
window->DC.CursorPos.x = IM_TRUNC(window->Pos.x + window->DC.Indent.x + ...);
```

uses the active window's pos.  There's no parent/child conflation
because they're literally different Window structs.

zimr collapses parent and children into one `Window` struct with
state pushes/pops on a `child_stack`.  So `w.pos` is fixed at the
parent's position, regardless of which child is active.

### The fix

Added a `layout_origin_x` field on Window:

```zig
pub const Window = struct {
    // ...
    indent_x: f32 = 0,

    /// X coordinate that `advanceLayout` uses as the cursor's
    /// row-reset origin.  At window open, set to
    /// `w.pos[0] + style.window_padding[0]` (window's content-left).
    /// `beginChild` saves and overrides to the child's inner-left;
    /// `endChild` restores.
    layout_origin_x: f32 = 0,
    // ...
};
```

`openWindow` initializes it:

```zig
w.layout_origin_x = inner_origin[0];
```

`beginChild` saves to `ChildState` then overrides:

```zig
const cs = ChildState{
    // ...
    .saved_layout_origin_x = w.layout_origin_x,
};
ctx.child_stack.append(cs) catch { /* ... */ };

// ...

w.layout_origin_x = inner_origin[0];   // child's inner-left
```

`endChild` restores:

```zig
w.layout_origin_x = cs.saved_layout_origin_x;
```

`advanceLayout` uses the new field:

```zig
w.cursor_pos[0] = w.layout_origin_x + w.indent_x;
// (was: w.pos[0] + window_pad_x + w.indent_x)
```

Regression test:

```zig
test "beginChild: second widget renders at child's inner-left, not parent's" {
    var ctx = UiContext.init(std.testing.allocator);
    defer ctx.deinit();
    const w = splitterTestSetup(&ctx);
    w.pos = .{ 0, 0 };
    w.layout_origin_x = 8;
    w.cursor_pos = .{ 200, 8 };
    w.last_item_rect = .{ .x = 100, .y = 8, .width = 100, .height = 20 };

    const u = Ui{ .ctx = &ctx };
    if (u.beginChild("right", .{ 150, 100 }, .{})) {
        defer u.endChild();
        _ = u.button("first", .{});
        const first_x = w.last_item_rect.x;
        _ = u.button("second", .{});
        const second_x = w.last_item_rect.x;
        // Second widget must align with the FIRST inside the child —
        // NOT bounce back to the parent's content-left.
        try std.testing.expectEqual(first_x, second_x);
    }
}
```

---

## 3. Bug — Splitter widget rendered the bar at the wrong X

### Symptom

The editor pane now showed full lines.  But the next screenshot
showed:

- Tree labels truncated to 3 chars (e.g. "ui.zig" → "ui.").
- The splitter was far to the right of where the tree text ended —
  a big empty gap inside the tree pane.
- The splitter wouldn't drag past the leftmost position.

### Diagnosis

The splitter widget:

```zig
const bar_rect: Rectangle = switch (axis) {
    .x => .{
        .x = cur[0] + split_pos.*,    // ← bug
        .y = cur[1],
        .width = opts.bar_width,
        .height = perp_extent,
    },
    // ...
};
```

It rendered the bar at `cur[0] + split_pos.*`.  But the demo's flow:

```zig
// 1. Render pane 1
if (u.beginChild("tree", .{ s.left_w, total_h }, .{})) {
    defer u.endChild();
    // ... tree content ...
}

// 2. sameLine → cursor moves to tree.right
u.sameLine(.{});

// 3. Splitter — bar drawn at cur + split_pos
_ = u.splitter("h_split", &s.left_w, .x, .{
    .min1 = min_left,
    .min2 = min_right,
    .total_along_axis = total_w,
});

// 4. sameLine → cursor moves past the splitter
u.sameLine(.{});

// 5. Render pane 2
if (u.beginChild("right", .{ right_w, total_h }, .{})) { ... }
```

After step 2, `cur[0]` was already at `pane1_start + left_w`.  Then
the splitter added another `split_pos` (which is left_w) on top.
The bar ended up at `pane1_start + left_w + left_w` — twice the
intended offset.

You'd dragged the splitter to its min (`min_left=80`), making the
tree pane 80 wide.  The bar then rendered at `(8 + 80) + 80 = 168`
instead of at `8 + 80 = 88`.  The tree content was correctly clipped
at the tree pane's right edge (x=88).  The visible bar at x=168 left
80px of empty space inside the tree pane between text and the
splitter.

### The fix

`split_pos` should mean "size of pane 1" — state the splitter mutates
on drag.  It should NOT also be an offset added to the cursor.  The
caller positions the cursor via `sameLine`; the splitter just renders
the bar where the cursor is.

```zig
const bar_rect: Rectangle = switch (axis) {
    .x => .{
        .x = cur[0],
        .y = cur[1],
        .width = opts.bar_width,
        .height = perp_extent,
    },
    .y => .{
        .x = cur[0],
        .y = cur[1],
        .width = perp_extent,
        .height = opts.bar_width,
    },
};
```

The drag math:

```zig
delta = mouse_along - bar_origin_along;   // bar_origin = cur + bar_width/2
split_pos.* += delta;
```

still works.  `cur` naturally tracks pane 1's right edge (= start +
size = start + split_pos), so `mouse - cur` is exactly the size
adjustment the user is requesting.

5 splitter tests rewrote — they encoded the old "bar at cur +
split_pos" model.  New tests place the cursor at the bar's intended
X (e.g. `w.cursor_pos = .{ 128, 8 }` for a pane 1 of width 120
starting at x=8) and verify the drag math against
`bar_center = cur[0] + bar_width/2`.

### Why this is the right model

In imgui you typically write your own splitter as an invisible
Button:

```cpp
ImGui::BeginChild("left", ImVec2(left_w, 0));
// ...
ImGui::EndChild();

ImGui::SameLine();
ImGui::Button("##split", ImVec2(4, full_height));
if (ImGui::IsItemActive())
    left_w += ImGui::GetIO().MouseDelta.x;
ImGui::SameLine();

ImGui::BeginChild("right", ...);
// ...
```

The button (and its visible bar) renders AT the cursor — sameLine
positioned it there.  zimr's splitter widget is now the same
pattern, just packaged.

---

## 4. Bonus — `treePop` indent asymmetry

A smaller bug fixed in the same arc.

`treeNodeExImpl` push side:

```zig
if (is_open and !opts.leaf and !opts.no_tree_push_on_open) {
    w.indent_x += INDENT_AMOUNT;
    w.cursor_pos[0] += INDENT_AMOUNT;   // push BOTH
}
```

`treePop` pop side (old):

```zig
pub fn treePop(self: Ui) void {
    const w = self.ctx.current_window orelse return;
    if (w.indent_x >= INDENT_AMOUNT) w.indent_x -= INDENT_AMOUNT;
    // forgot to decrement cursor_pos[0]
}
```

Pop only decremented `indent_x`.  `cursor_pos[0]` stayed at the
deeper indent until the next widget's `advanceLayout` reset it.
The first widget AFTER each `treePop` rendered one `INDENT_AMOUNT`
too far right.

Fix:

```zig
pub fn treePop(self: Ui) void {
    const w = self.ctx.current_window orelse return;
    if (w.indent_x >= INDENT_AMOUNT) {
        w.indent_x -= INDENT_AMOUNT;
        w.cursor_pos[0] -= INDENT_AMOUNT;   // symmetric pop
    }
}
```

---

## The bigger picture

### Why the bugs nested

Three of these were INVISIBLE individually:

1. `sameLine` broken → no right-side content rendered → can't see
   whether the editor was correctly clipped.
2. `sameLine` fixed → editor content on screen but left-clipped →
   can't see whether the splitter was positioned right.
3. `layout_origin_x` fixed → editor shows full lines → splitter
   offset error becomes visible.

Each fix exposed the next layer.  Without your phone screenshots, I
couldn't have diagnosed any of them past #1 — every other test
surface in zimr passed throughout.

### Why they'd been latent

Each bug had been present for many turns:

- `sameLine` was used mostly for short, same-height widget pairs
  (button rows in `log_viewer`).  The 4px stagger looked exactly
  like `item_spacing[1]`.
- `beginChild` was usually called at the start of a window or after
  a wrap, where parent's content-left coincidentally equals
  child's inner-left.
- `splitter` was new (turn 306) and hadn't been used with `sameLine`
  in a real demo until `ui_panes`.

The test surface didn't catch them because the tests asserted
specific X/Y values that matched the broken behavior.  The
fundamental property "B is on the same row as A after sameLine" had
never been asserted directly.

### The takeaway

When porting a behavior, write a test asserting the SEMANTIC
property the user observes (B-on-same-row-as-A), not just the
concrete numbers the current implementation happens to produce.
Concrete numbers passing only tell you the code is internally
consistent — not that it does the right thing.

Three regression tests now pin all three semantics down:

- `"sameLine: keeps next widget on the same row as previous"`
- `"sameLine after endChild: next widget at child's row"`
- `"beginChild: second widget renders at child's inner-left, not parent's"`

Plus the 5 rewritten splitter tests for the new `bar at cur` model.
