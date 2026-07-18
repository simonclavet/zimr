# Architecture deep-dive: imgui vs zimr

*Turn 309c, written in response to Simon's question:*

> Is this again a case where we are trying to be better than imgui
> but actually we should stay closer? Ocornut spent his life finding
> the best way. Study precisely if and why the bug you just fixed
> is easier to fix in imgui. Should we immediately redesign our
> system to match their structure?

This document studies the right-pane spillover bug fixed in turn
309c, traces how imgui's structure prevents it from existing in
the first place, and answers: do we redesign now, or continue?

---

## 1. The bug

In `examples/ui_panes.zig`, with the splitter dragged to its
rightmost position, the right pane's text rendered ~16 pixels past
the workspace window's right edge.  The geometry:

```
   16            16+340          16+340+8        16+340+8+4
    |               |                |               |
    | tree (340)    | sp1 | bar(4)   | sp2 | right pane (20)
    |               |  8  |          |  8  |
    +---------------+-----+----------+-----+--------+
   16              356  364        368   376      396
                                                    ^
                                                    workspace inner-right = 380.
                                                    Right pane right = 396.
                                                    Overshoot = 16 = 2 × item_spacing[0].
```

The user math in ui_panes was:

```zig
const right_w = total_w - s.left_w - SPLIT_BAR_W;
```

`total_w = 364`, `s.left_w` clamped to `total_w - min_right - SPLIT_BAR_W = 340`,
so `right_w = 364 - 340 - 4 = 20`.  But this math omitted the two
`sameLine()` spacings consumed around the splitter (`2 × 8 = 16`
pixels).  Result: the right pane was 16 pixels wider than it
should have been.

---

## 2. Why imgui doesn't have this bug in its demo

The canonical imgui splitter pattern (from the imgui community
forum / wiki — there's no built-in `SplitterBehavior` for typical
user code; that's an internal helper for columns and docking):

```cpp
static float w = 200.0f;
static float h = 300.0f;
ImGui::BeginChild("child1", ImVec2(w, h), ImGuiChildFlags_Borders);
ImGui::EndChild();
ImGui::SameLine();
ImGui::InvisibleButton("vsplitter", ImVec2(8.0f, h));
if (ImGui::IsItemActive())
    w += ImGui::GetIO().MouseDelta.x;
ImGui::SameLine();
ImGui::BeginChild("child2", ImVec2(0, h), ImGuiChildFlags_Borders);
ImGui::EndChild();
```

The right pane uses `ImVec2(0, h)` — **width 0 = auto-fill the
remaining content area**.  The user never computes the trailing
pane's width.

Inside `BeginChildEx` (imgui.cpp:6466), the auto-fill resolution
is:

```cpp
const ImVec2 size_avail = GetContentRegionAvail();
const ImVec2 size_default(
    (child_flags & ImGuiChildFlags_AutoResizeX) ? 0.0f : size_avail.x,
    (child_flags & ImGuiChildFlags_AutoResizeY) ? 0.0f : size_avail.y);
ImVec2 size = CalcItemSize(size_arg, size_default.x, size_default.y);
```

Where `GetContentRegionAvail` (imgui.cpp:11661) is:

```cpp
ImVec2 ImGui::GetContentRegionAvail()
{
    ImGuiContext& g = *GImGui;
    ImGuiWindow* window = g.CurrentWindow;
    ImVec2 mx = window->WorkRect.Max;  // (simplified — columns/tables variant elided)
    return mx - window->DC.CursorPos;
}
```

So auto-fill = `WorkRect.Max - DC.CursorPos`.

**Why this is automatically correct.**  By the time `BeginChild("child2", ImVec2(0, h))`
is called, the cursor has already advanced past:

- child1's outer rect (advanced when `EndChild` was called),
- the spacing added by the first `SameLine()`,
- the InvisibleButton's width (advanced on submission),
- the spacing added by the second `SameLine()`.

So `DC.CursorPos.x` is exactly where the right pane should
start.  Subtracting from `WorkRect.Max.x` (the parent window's
content right edge) gives exactly the available remaining width.
The library doesn't need to know what's consumed — the cursor
already does.

**The principle: don't compute the trailing dimension. Subtract.**
The cursor is the source of truth.

---

## 3. The architectural piece — each child is a Window

The `g.CurrentWindow` inside `BeginChildEx` is the PARENT's
window.  After `SetNextWindowSize(size)` and the internal `Begin()`
call, a NEW `ImGuiWindow*` is allocated (or fetched from a window
storage map keyed by ID), pushed onto the window stack, and
becomes the new `g.CurrentWindow`.  This child Window has:

- its own `Pos` and `Size` (the child rect),
- its own `WorkRect` (inner content area = child rect minus padding),
- its own `DC` (`Cursor`, `CursorPosPrevLine`, `PrevLineSize`,
  `Indent`, etc. — what zimr now calls `LayoutScope`),
- its own `DrawList` (separately submitted; clip-rect intersection
  is automatic because each window pushes its own clip),
- its own `Scroll` (per-child scrolling is free),
- its own `Storage` (per-child persistent state across frames),
- and it can be picked up by the docking system, focus system, etc.
  with no special-casing.

This is the imgui structural advantage: **a child window and a
top-level window are the same thing, structurally.**  All the
features that work for top-level windows (scrolling, focus,
persistence, drawing, clipping) work for children for free.

When `BeginChild("child2", ImVec2(0, h))` resolves auto-fill via
`GetContentRegionAvail`, the `window->WorkRect.Max` is the
PARENT'S — and the parent at that moment is whatever window
`BeginChild("child2", ...)` was called inside.  If it's the root
workspace, the workspace's WorkRect.  If it's an outer child, the
outer child's WorkRect.  Auto-fill bounds to the immediate parent.
Always correct.

---

## 4. zimr before turn 308: the divergent model

zimr had ONE `Window` per top-level `window(name, opts)` call.
`beginChild` did NOT create a new Window — it pushed parent's
layout state onto a `child_stack` and mutated the same Window's
layout fields in place.  After `endChild`, the saved state was
restored.

This worked for simple cases.  But every per-scope concept added
needed:

1. A new field on `Window` (because there's no separate "scope")
2. A matching `saved_*` field on `ChildState` (so endChild restores it)
3. Manual save in `beginChild`, manual restore in `endChild`
4. Manual reset of the new field for the child's fresh scope

Every layout-related field got bolted on this way.  Easy to
forget one, easy to forget the matching save/restore, easy to
forget the reset.  The four turn-308 bugs were all "we forgot to
correctly handle scope-X for field Y":

- **sameLine bug**: forgot that `cursor_pos[1]` had been advanced
  by the wrap; the imgui-equivalent `DC.CursorPosPrevLine` field
  wasn't on zimr's Window at all.
- **layout_origin bug**: row-wrap reset used `w.pos[0]` (top-level
  window's left edge) instead of "current scope's left edge"; the
  imgui-equivalent `WorkRect.Min.x` field wasn't there either.
- **splitter pos bug**: our splitter API conflated "size of pane 1"
  with "offset from cursor" — orthogonal to the scope question.
- **treePop indent bug**: indent push touched both `indent_x` and
  `cursor_pos[0]`, but pop touched only `indent_x` — asymmetry.

Turn 308's spillover bug (the one Simon just photographed) was the
SAME pattern: `beginChild`'s auto-fill computed
`inner_right = w.pos[0] + w.size[0] - window_padding[0]` — the
top-level window's content right edge, regardless of which child
the cursor was inside.

---

## 5. Turn 309's refactor — what we ported

The plan v4 supplement explicitly studied this divergence and
proposed Step 1.5.5 to close the gap.  Turn 309 shipped half of
it: the `LayoutScope` refactor.

What we did:

```zig
pub const LayoutScope = struct {
    origin: Vector2,              // imgui's WorkRect.Min
    work_rect_max: Vector2,       // imgui's WorkRect.Max          [added turn 309b]
    cursor_pos: Vector2,          // imgui's DC.CursorPos
    cursor_max: Vector2,          // imgui's DC.CursorMaxPos
    cursor_pos_prev_line: Vector2,// imgui's DC.CursorPosPrevLine
    line_height: f32,             // imgui's DC.CurrLineSize.y
    prev_line_height: f32,        // imgui's DC.PrevLineSize.y
    indent_x: f32,                // imgui's DC.Indent.x
    last_item_*: ...              // imgui's LastItemData
};

pub const Window = struct {
    id: Id,
    pos: Vector2, size: Vector2,  // outer rect
    layout: LayoutScope,          // the per-scope state
    // (plus draw_list, scroll, etc. — analogous to imgui's Window)
};

pub const ChildState = struct {
    saved_layout: LayoutScope,    // whole-scope save/restore
    rect: Rectangle,
    border: bool,
};
```

After this refactor, zimr's `LayoutScope` is structurally a port
of imgui's per-window layout state — same field set, same
semantics, same row-tracking logic.  The four turn-308 bugs and
the turn-309b spillover were all symptoms of fields missing from
this scope.

Turn 309c added the defensive clamp in `beginChildImpl`:

```zig
const max_w = @max(0, w.layout.work_rect_max[0] - at[0]);
const max_h = @max(0, w.layout.work_rect_max[1] - at[1]);
if (actual_size[0] > max_w) actual_size[0] = max_w;
if (actual_size[1] > max_h) actual_size[1] = max_h;
```

**imgui DOES NOT have this clamp.**  In `CalcItemSize`
(imgui.cpp:11618):

```cpp
if (size.x == 0.0f)        size.x = default_w;
else if (size.x < 0.0f)    size.x = ImMax(4.0f, avail.x + size.x);
// size.x > 0: used as-is, no clamp
```

So if you pass an explicit oversized width to `BeginChild` in
imgui, the child WILL extend past the parent — imgui trusts the
user's math.  zimr's clamp is genuinely more defensive than imgui.
**This is a place where we are stricter than imgui, on purpose.**

The reason imgui can get away without it: imgui's culture is
"use auto-fill," documented in the demo's splitter pattern.  Zig
makes wrong math more visible (you have to write the subtraction
explicitly), so the trap is easier to fall into in zimr.  The
clamp catches it.

This isn't us being clever for cleverness's sake — it's defending
against a real failure mode that the Zig-explicit style makes more
visible.

---

## 6. The remaining gap — child-as-Window

Despite turn 309's LayoutScope refactor, zimr still has ONE
`Window` per top-level call.  `beginChild` still pushes onto
`child_stack` and replaces `Window.layout`.  In imgui, each child
is a separate `ImGuiWindow*`.

For Phase 1 features (text, button, slider, tree, splitter,
multi-select), zimr's model is fine — the only per-scope state is
the LayoutScope, and that round-trips correctly now.

For Phase 2+ features, every one of these wants per-child
PERSISTENT state across frames:

- **Step 1.6** (per-child scrolling): each child needs its own
  `scroll_y` AND `scroll_velocity` AND `last_seen_content_height`
  for kinetic scroll feel.  Persistent across frames.  Today,
  scroll lives on `Window` — there's only one.

- **Per-child focus / hover** (Phase 2): each child wants to know
  "was I hovered? was I active?  did my mouse leave?"  Today,
  zimr's hover/focus is window-level.

- **Persistence (Step 5.1)**: each child wants to save its scroll
  position, splitter ratios, tree open-states.  Today, persistence
  would have to key by window-name + a hand-rolled child path.

- **Docking (Step 5.5)**: a child can be dragged out into its own
  window and back.  This requires children to BE full windows.

The pattern keeps repeating: per-child persistent state.  Each
time we'd bolt another field onto `Window` (or `ChildState`) and
write save/restore code.  Or we'd add a separate "child storage"
side-table keyed by ID.

The clean alternative — and what imgui already does — is:
**children ARE windows.**  Each `beginChild(str_id, ...)`
allocates (or fetches from storage by hashed ID) a `Window` and
makes it the current.  This Window persists across frames in a
`windows: AutoHashMap(Id, *Window)` (zimr already has this for
top-level windows).  All the per-scope/per-child state that any
future feature might want is automatically in the right place.

**This is the planned Step 1.5.5 second half.**  Plan v4 supplement
sequenced it:

```
Step 1.5.5  Architecture refactor — LayoutScope + child-as-Window
            └─ LayoutScope half: turn 309 ✓
            └─ child-as-Window half: NEXT turn
            ↓
Step 1.6   Per-child scrolling (mostly free after child-as-Window)
            ↓
... pull-forward order: TabBar, DragDrop, Persistence
            ↓
Step 5.5   Docking milestone
```

---

## 7. Are the bugs we keep hitting evidence of a bad design?

Sorted:

| Bug                          | Class                          | Root cause                                       |
|------------------------------|--------------------------------|--------------------------------------------------|
| sameLine wrong cursor.y      | missing LayoutScope field      | no `cursor_pos_prev_line`                        |
| layout_origin wrong          | missing LayoutScope field      | no `origin` separate from `w.pos`                |
| right-pane spillover         | missing LayoutScope field      | no `work_rect_max`                               |
| splitter pos+offset confusion | zimr API design                | our splitter conflated state with offset         |
| treePop indent asymmetry     | symmetric op bug               | structurally same in imgui; we just had a typo   |
| right-pane user math wrong   | user-code error                | example didn't use auto-fill                     |

3 of 6 (sameLine, origin, spillover) are zimr-specific
architectural issues from missing per-scope state.  **All three
are now fixed by the LayoutScope refactor.**

1 of 6 (splitter API) is zimr-specific API design.  Imgui's
internal `SplitterBehavior` is cleaner (takes both size1 and size2,
mutates both, no `total_along_axis`).  Could revisit when more
splitter callsites land.

1 of 6 (treePop) is a routine bug that would have existed in either
architecture.

1 of 6 (user math) is solved by following the imgui idiom (auto-fill).

**Conclusion: yes, the bugs ARE evidence the design diverged from
imgui in a problematic way — specifically by not having a unified
per-scope state struct.**  Turn 309's refactor closed that gap.
The remaining gap (child-as-Window) is the next planned turn.

We are not trying to be cleverer than imgui.  We are slowly porting
imgui's architecture while staying Zig-idiomatic in API surface
(typed enums, opts structs, explicit error returns, allocators on
state, slice-not-pointer-and-length).

---

## 8. Are there places where zimr IS better, on purpose?

A few worth calling out:

**The defensive clamp in `beginChild`.**  We're stricter than imgui
here.  Imgui trusts the user's math; we clamp to prevent escape.
In Zig culture, the explicit math is more visible at the call site,
making the failure mode more likely.  The clamp is cheap insurance.

**Single Window struct with embedded `layout: LayoutScope` field.**
ImGui has the layout state on `ImGuiWindow.DC` (a sub-struct).
zimr has the same shape (`Window.layout`).  We're isomorphic here.
But Zig's pure-data nested structs read more clearly than C++'s
free-floating `DC.` prefix.  Worth keeping our shape.

**Eager mode for tests.**  imgui's tests have to spin up a full
context with a fake renderer.  zimr's `eager_mode` lets us run
widget logic without a draw list — much faster and simpler tests.
This is a Zig-friendly architectural addition that imgui doesn't
have.

**Options structs everywhere (`SplitterOpts`, `TreeNodeFlags`,
`ChildOpts`).**  imgui uses bit-flag enums (`ImGuiTreeNodeFlags_*`)
which are cheap but stringly-typed.  zimr's struct-with-defaults is
checkable at compile time, with type-driven IDE completion.
Tradeoff: a tiny bit more boilerplate.  Worth it.

**`splitter` as a single widget with `min1`, `min2`,
`total_along_axis`.**  This one is debatable — imgui's pattern
(InvisibleButton + manual `w += delta`) is simpler.  Our built-in
splitter is more convenient but leakier (the `total_along_axis`
question).  Could refactor toward imgui's two-state version
(`size1: *f32, size2: *f32`) later — but not blocking.

---

## 9. Recommendation

**Continue with the plan.**  Don't redesign now beyond what's
already planned.

What the plan already covers:

- **Next turn**: child-as-Window switch.  Each `beginChild` becomes
  a real Window, allocated from a `windows: AutoHashMap(Id, *Window)`.
  After this, zimr's data model is functionally equivalent to
  imgui's, just expressed in Zig.

- **Step 1.6**: per-child scrolling.  Becomes mostly free after
  child-as-Window — `scroll_y` already exists on `Window`.

- **Pull-forwards**: TabBar, DragDrop, Persistence (the prerequisites
  for docking).

- **Step 5.5**: docking.  Now structurally possible because
  children are real windows.

**Don't do now:**

- Two-state splitter API (matches imgui's `SplitterBehavior`).
  Could revisit if more splitter callsites land or the
  `total_along_axis` keeps biting us.  For now, fixing user code
  to pass the right value works.

- Clip-rect intersection in `pushClipRect`.  Latent issue noted in
  the turn 309 changelog — children don't intersect their clip rect
  with parent's, so a misconfigured child could clip outward.
  After child-as-Window this falls out naturally (each window
  pushes its own clip; intersection happens at the draw-list level).

**Meta-takeaway.**  The pattern of "imgui has a field for X, zimr
doesn't, bug surfaces, port the field" is going to keep repeating
through Phases 2-5.  Each port is small (a field + a save/restore
or, after child-as-Window, just a field).  The architectural
question — do we adopt imgui's whole-window-per-scope model? — is
already answered yes, and Step 1.5.5's second half is the
execution.  After that, the pattern stops repeating; we're on
imgui's structural footing and the bug class disappears.

The Zig-idiom layer (typed opts, allocators-on-state, struct
literals over bit flags, explicit-or-fail) stays on top.  We beat
imgui by being more Zig-y AND by having more features (Step 1.6
scrolling can do kinetic, Step 5.5 docking can use WebGL2-specific
optimizations), not by cutting structural corners.
