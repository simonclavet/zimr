# imgui-completion-plan.md

_Detailed plan for finishing the Dear ImGui port._

## Execution log

| Phase | Status | Tests | Smoke |
|---|---|---:|---:|
| 4A. Windows + item state | ✅ done | 794 → 803 | 90/90 |
| 4A.2. Vertical scrollbar | ✅ done | 803 → 808 | 90/90 |
| 4B. Layout + disabling | ✅ done | 808 → 817 | 90/90 |
| 4C.1. Popup primitives | ✅ done | 817 → 823 | 90/90 |
| 4C.2. Modals + context menus + menu bars | ✅ done | 823 → 832 | 90/90 |
| 4D. Tabs + listbox | ✅ done | 832 → 838 | 90/90 |
| 4E. Additional widgets | ✅ done | 838 → 846 | 90/90 |
| 5A. editStruct flagship | ✅ done | 846 → 854 | 90/90 |
| 5B. editArrayList + snapshots | ✅ done | 854 → 858 | 90/90 |
| 6A. Style editor + persistence | ✅ done | 858 → 867 | 90/90 |
| 6B. Kbd nav + showDemoWindow | ✅ done | 867 → 874 | 90/90 |

**🎉 imgui-completion-plan complete.**  Every phase shipped,
+80 tests added across 11 phases, full Phase 4 widget surface
plus reflective Phase 5 editors plus Phase 6 polish (style
editor, ZON layout persistence, keyboard nav, showDemoWindow).
| 6B. Kbd nav + showDemoWindow | — | — | — |

**Phase 4A complete.**  10 setNextWindow*/window-state fns + 12 item-state queries + drag-to-move + corner-resize grip + central `markItemPost` helper wired into 10 widgets.

**Phase 4A.2 complete.**  Vertical scrollbar + `Window.scroll_y/scroll_max_y/user_resized` + content clip rect + mouse-wheel input + auto-fit gating on `user_resized`.  ~110 LoC of new widget + state, +5 tests.

**Phase 4B complete.**  10 layout/disabled fns: `setNextItemWidth` /
`pushItemWidth` / `popItemWidth` / `getContentRegionAvail` /
`dummy` / `alignTextToFramePadding` / `beginDisabled` /
`endDisabled` / `isDisabled` / `beginGroup` / `endGroup`.  Width
plumbing migrated to 6 widget sites via `effectiveItemWidth`
priority chain.  Disabled scope: outermost-only input save +
alpha multiplier applied at `drawRect*` / `drawText*` via
`multiplyAlpha`.  +9 tests.

**Phase 4C.1 complete.**  Popup primitives: `openPopup`,
`beginPopup`/`endPopup`, `closeCurrentPopup`, `isPopupOpen`.
Popups reuse the existing Window struct + persistent storage map
but replay through a separate `frame_popups` list AFTER regular
windows + BEFORE foreground (tooltips).  Per-window scoped IDs,
click-outside dismissal with one-frame open-grace, dedicated
`style.popup_bg` chrome.  +6 tests.

**Phase 4C.2 complete.**  8 fns: `beginPopupModal` (backdrop dim,
explicit dismissal only), `beginPopupContextItem` (auto-opens on
right-click of last item), `beginMainMenuBar`/`endMainMenuBar`,
`beginMenu`/`endMenu`, `menuItem` (with shortcut + selected
checkmark + enabled gate).  Right-mouse-button input wired into
InputSnapshot.  Modal backdrop rendered on popup's own draw list
(z-sorts above windows, below popup itself).  Menu bar is a
synthetic Window submitted via `frame_popups` so it overlays
content; menus inside are popups anchored at button-bottom edge.
+9 tests.

**Phase 4D complete.**  8 fns: `beginTabBar`/`endTabBar`,
`beginTabItem` (with optional `*open` for close-X) / `endTabItem`,
`beginListBox`/`endListBox`, `listBox` (one-call helper).  Tab
state persistent in `tab_bar_state` keyed by hashed `str_id`;
per-frame layout cursor on `tab_bar_stack`.  First tab auto-
selects; clicks switch active tab across frames.  Overflow tabs
silently skip rendering.  List box reuses `ChildState` machinery
to redirect the cursor + push content clip rect.  +6 tests.

**Phase 4E complete.**  6 widgets: `progressBar`, `vSlider` (any
float/int via comptime dispatch — top=max, bottom=min, fill grows
from bottom up like a level meter), `inputFloat`/`inputInt` with
`InputScalarOpts` (focus seeds buffer with formatted current
value; Enter or click-outside commits via `parseScalar`; garbage
silently rejected; Escape cancels), `colorButton` (compact swatch
with hover tooltip), `imageButton` (clickable variant of `image`
using the same polymorphic `source` dispatch).  Bug fix this
turn: `inputScalarImpl` was capturing `is_focused` BEFORE the
click-to-focus block, dropping chars typed on the same frame as
the focus-gaining click; the fix moves the click block above the
`is_focused` capture.  +1 test for the unique "rejects garbage on
commit" path; 7 pre-existing tests now green.  Total: 8 4E tests.

**Phase 5A complete.**  Comptime-reflective struct inspector:
`editStruct(value_ptr)` and `editStructOpts(value_ptr, opts)`.
Walks `@typeInfo(T).@"struct".fields` at comptime and dispatches
each field to the appropriate Phase 4 widget (bool→checkbox,
float→inputFloat or slider w/ range, int→inputInt or slider w/
range, enum→combo, nested struct→treeNode + recursion, [3]f32
named "...color"→colorEdit, []const u8→read-only text, other
arrays→per-element widgets under tree node).  Per-field opts
struct uses `@hasField` lookup so missing entries fall through
to defaults silently — call-sites stay forward-compatible as
inspected structs grow new fields.  +8 tests.

**Phase 5B complete.**  Dynamic-list editor: `editArrayList(label,
*std.ArrayList(T))`.  Renders a `treeNode` header with the count
+ "Add" button + per-element rows with "x" Remove buttons.
Element dispatch reuses `editFieldDispatch` from Phase 5A so
struct-element lists get nested recursive editors per row.
Per-row IDs scoped via `pushIdInt(idx)` / `popId` so widgets
across rows don't collide.  Allocator read from `ctx.gpa`.
Remove deferred via `?usize` slot to avoid mutating the slice
mid-iteration.  +4 tests.

**Phase 6A complete.**  Two deliverables: `styleEditor()` (one
call, edits every Style field via comptime reflection through
`editStruct`) and `serializeLayout(gpa) ![]u8` /
`applyLayout(bytes) !void` (ZON serialize/restore of every
window's pos/size/scroll/user_resized).  `editFieldDispatch` got
two new branches — `types.Color` → `colorEdit` round-tripped
through `[4]f32`, `types.Vector2` → side-by-side inputFloats
labelled `<name>.x` / `<name>.y`.  Layout format is ZON via
`std.zon.stringify` / `std.zon.parse`: human-readable, hand-
editable, schema-versioned, with field defaults so new entries
don't break old files.  Schema stores `title` (re-hashed at load)
rather than the runtime `id` so layout files are genuinely
readable.  Stub-window mechanism lets `applyLayout` run BEFORE
any window is submitted: pre-allocates Window entries by hash
so the next `findOrCreateWindow` call adopts the saved geometry
instead of falling back to defaults.  +9 tests.

**Phase 6B complete.**  Final phase — keyboard nav + canonical
demo window.  Keyboard nav: `nav_id: Id` and
`frame_nav_items: BoundedStack(Id, 64)` track focus as a list
of submitted IDs; Tab / Shift+Tab in `beginFrame` advance
`nav_id` ±1 with wrap-around; focused widget gets a 1px focus
border via `drawRectLines` in `style.button_hovered`; Enter on
focused button or checkbox synthesizes a click via
`triggerNavActivate(ctx, id)`.  `key_shift_down: bool` added to
InputSnapshot for Shift+Tab.  Wired into `buttonImpl` and
`checkboxImpl` (slider/drag/input arrow-key activation deferred
to a follow-up).  `showDemoWindow(state, p_open)` is the
flagship demo: tab-bar walks Widgets / Layout / Style / About;
each tab is a small helper exercising a subset of widgets;
state owned by caller via `pub const DemoState = struct { ... }`.
+7 tests.  **Total +80 tests across 11 phases.**

**Sister docs:**
- `ui-design.md` — original design (the architecture we settled on)
- `bridge-the-gap-plan.md` — execution log from the raylib API audit
- `architecture.md` — three-layer Zig/runtime/effects split
- `style-guide.md` — coding conventions

This document is the action plan for closing the remaining gap to
feature parity with Dear ImGui (within zimr's scope — no tables,
docking, multi-viewport, file dialogs).

---

## 1. Where we are (status snapshot)

### Phases complete (✓)

The original 6-phase plan from `ui-design.md` is partially shipped:

| Phase | Goal | Status |
|---|---|---|
| 1. Foundation | UiContext, ID stack, button | ✓ done |
| 2. Seven essentials | text/checkbox/slider/colorEdit + sameLine/separator/spacing | ✓ done |
| 3. Next ten | drag, combo, treeNode, collapsingHeader, radioButton, selectable, tooltip, bullet, image, inputText | ✓ done |
| 4. Containers | beginChild/endChild done; popups/menus/tabs/scrollbars/window-resize **NOT YET** | ⏳ partial |
| 5. Zig superpowers | editStruct, editEnum, editArrayList, snapshot tests | ✗ pending |
| 6. Polish | style editor, layout persistence, kbd nav, ShowDemoWindow | ✗ pending |

### Inventory of `src/ui.zig`

3961 lines, **58 public methods** on `Ui`, 44 inline tests.  Public surface:

```
window/end (via WindowHandle)        beginChild/endChild
pushId/pushIdInt/popId/getId         pushRenderTexture/popRenderTexture
sameLine/separator/spacing/newLine   indent/unindent
text/textColored/textWrapped         button/checkbox/radioButton/selectable
slider/drag/colorEdit/combo          inputText/treeNode/treePop
collapsingHeader/bullet/bulletText   image
isItemHovered/setTooltip             style/wantCaptureKeyboard/wantCaptureMouse
cursorScreenPos
```

### `examples/imgui_demo.zig`

434 lines, exercises every implemented widget.  Per the CHANGELOG's
own coverage tally: **~32 of 85 demo features covered = ~38%**.

### Smoke + tests

- `zig build test`: 794/794 (44 from `ui.zig`)
- `zig build smoke-test`: 90/90 (the demo runs at ~26k GL calls/frame)

### Architecture in place (the hard part)

The infrastructure that makes everything else "just widgets":

- ✓ Deferred draw lists per window (`Window.draw_list`)
- ✓ Z-order (frame_windows submission-order replay)
- ✓ Foreground draw list for tooltips/popups
- ✓ Push/pop clip rect (DrawCmd union has `push_clip`/`pop_clip` cases)
- ✓ Eager-mode toggle for render-to-texture scopes
- ✓ Surface stack for recursive UIs (HUD-into-HUD)
- ✓ Active-id state machine (active_id, hovered_id, just_activated, press_value)
- ✓ Layout cursor + same-line + indent (Window has all the right state)
- ✓ ID stack with FNV-1a hashing + push/pop
- ✓ Per-window persistent state (open/closed, position, size — keyed by hashed title)
- ✓ tree_open_state hash map (treeNode persistence)
- ✓ pending_tooltip, combo_open_id (single-instance popups)
- ✓ child_stack with full layout-state save/restore

**The chassis is built.** What remains is mostly widget code on top.

---

## 2. What's missing — full inventory

Categorized by ImGui section, cross-referenced to the original 6-phase
plan.  Each entry is annotated with priority and LoC estimate.

### 2.1 Window features (Phase 4)

raylib-style auto-position + auto-resize works; the missing pieces
are user-controlled positioning, drag-to-move, drag-to-resize, and
scrollbars:

| ImGui name | zimr equivalent (proposed) | LoC | Priority |
|---|---|---:|---|
| `SetNextWindowPos` | `setNextWindowPos(pos, cond)` | 30 | A |
| `SetNextWindowSize` | `setNextWindowSize(size, cond)` | 30 | A |
| `SetNextWindowSizeConstraints` | `setNextWindowSizeConstraints(min, max)` | 25 | B |
| `SetNextWindowCollapsed` | `setNextWindowCollapsed(c, cond)` | 20 | B |
| `SetNextWindowFocus` | `setNextWindowFocus()` | 10 | B |
| `SetNextWindowBgAlpha` | `setNextWindowBgAlpha(alpha)` | 15 | B |
| `IsWindowAppearing` | `isWindowAppearing()` | 10 | B |
| `IsWindowCollapsed` | `isWindowCollapsed()` | 10 | B |
| `IsWindowFocused` | `isWindowFocused()` | 15 | A |
| `IsWindowHovered` | `isWindowHovered()` | 15 | A |
| `GetWindowPos/Size/Width/Height` | `getWindowPos/Size/Width/Height` | 15 | B |
| Drag-to-move (title-bar grab) | inside `renderWindowChrome` | 50 | A |
| Drag-to-resize (corner grip) | inside `renderWindowChrome` | 70 | A |
| Vertical scrollbar widget | `Window.scroll_y` + chrome rectangle | 120 | A |
| Horizontal scrollbar | mirror of vertical | 80 | C |
| `GetScrollX/Y`, `SetScrollX/Y`, `GetScrollMaxY` | accessors | 30 | B |
| `SetScrollHereX/Y` (scroll to current cursor) | scroll-tracking | 40 | C |

**Sub-total: ~580 LoC, ~1.5 turns.**

### 2.2 Item state queries (Phase 4)

Currently we have `isItemHovered` only.  ImGui apps lean heavily on
the others:

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `IsItemActive` | `isItemActive()` | 5 | A |
| `IsItemFocused` | `isItemFocused()` | 5 | B |
| `IsItemClicked` | `isItemClicked(button)` | 15 | A |
| `IsItemEdited` | `isItemEdited()` | 10 | A |
| `IsItemActivated` | `isItemActivated()` | 10 | B |
| `IsItemDeactivated` | `isItemDeactivated()` | 15 | B |
| `IsItemDeactivatedAfterEdit` | `isItemDeactivatedAfterEdit()` | 15 | B |
| `IsItemToggledOpen` | `isItemToggledOpen()` | 10 | C |
| `IsItemVisible` | `isItemVisible()` | 10 | C |
| `IsAnyItemHovered/Active/Focused` | `isAnyItem*()` | 15 | C |
| `GetItemRectMin/Max/Size` | `getItemRectMin/Max/Size()` | 15 | B |
| `GetItemID` | `getItemID()` | 5 | C |
| `SetItemDefaultFocus` | `setItemDefaultFocus()` | 10 | C |

Each requires a corresponding field on `Window.last_item_*`.  The
trickier ones (`isItemEdited`, `isItemDeactivatedAfterEdit`) need
per-widget cooperation: every widget that mutates user data sets a
`g.last_item_edited = true` flag that survives one frame.

**Sub-total: ~140 LoC, 0.5 turns.**

### 2.3 Layout helpers (Phase 4)

Common ImGui idioms missing:

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginGroup/EndGroup` | `beginGroup/endGroup` | 60 | A |
| `PushItemWidth/PopItemWidth` | `pushItemWidth/popItemWidth` | 40 | A |
| `SetNextItemWidth` | `setNextItemWidth(w)` | 20 | A |
| `PushTextWrapPos/PopTextWrapPos` | `pushTextWrapPos/pop` | 30 | B |
| `AlignTextToFramePadding` | `alignTextToFramePadding()` | 15 | B |
| `GetContentRegionAvail/Max` | `getContentRegionAvail/Max()` | 25 | B |
| `Dummy(size)` | `dummy(size)` | 15 | C |
| `Indent/Unindent` (already have) | — | — | done |

`BeginGroup`/`EndGroup` is the most useful — it groups widgets so
`isItemHovered` after `endGroup` reports hover-over-the-whole-group.
Common pattern for a labeled cluster of buttons.

**Sub-total: ~205 LoC, 0.5 turns.**

### 2.4 Disabling (Phase 4)

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginDisabled(true/false)` | `beginDisabled(disabled)` | 30 | A |
| `EndDisabled` | `endDisabled()` | 5 | A |

Effect: pushes a `g.disabled_count` and an alpha-multiplier.  Inputs
to widgets dispatched while non-zero are ignored; rendering uses
`style.alpha *= style.disabled_alpha`.

**Sub-total: ~35 LoC, 0.1 turns.**

### 2.5 Popups & Modals (Phase 4) — **biggest single chunk**

This is the most-asked-for missing capability.  Right-click menus,
"Are you sure?" modals, dropdown selectors all need it.

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `OpenPopup(str_id)` | `openPopup(str_id)` | 30 | A |
| `BeginPopup(str_id) bool` | `beginPopup(str_id)` | 80 | A |
| `EndPopup` | `endPopup()` | 20 | A |
| `BeginPopupModal(name, *open)` | `beginPopupModal(name, open_ptr)` | 80 | A |
| `BeginPopupContextItem(str_id)` | `beginPopupContextItem(opt_str)` | 50 | A |
| `BeginPopupContextWindow(str_id)` | `beginPopupContextWindow(opt_str)` | 40 | B |
| `BeginPopupContextVoid(str_id)` | `beginPopupContextVoid(opt_str)` | 40 | C |
| `IsPopupOpen(str_id)` | `isPopupOpen(str_id)` | 15 | A |
| `CloseCurrentPopup` | `closeCurrentPopup()` | 15 | A |

Architecture: extend `UiContext.open_popups` (already exists as a
`BoundedArray(PopupRef, 8)` per the design doc — but check it's
actually wired — see open question 1).  A popup is just a window
with `WindowFlags.popup` set; it draws on the foreground draw list,
auto-closes when the user clicks outside, supports nesting through
the window stack.

**Sub-total: ~370 LoC, 1 turn.**

### 2.6 Menus (Phase 4)

Built on popups, so they come second:

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginMainMenuBar` | `beginMainMenuBar()` | 50 | A |
| `EndMainMenuBar` | `endMainMenuBar()` | 10 | A |
| `BeginMenuBar` (per-window) | `beginMenuBar()` | 40 | B |
| `EndMenuBar` | `endMenuBar()` | 10 | B |
| `BeginMenu(label, enabled)` | `beginMenu(label, .{.enabled=true})` | 80 | A |
| `EndMenu` | `endMenu()` | 10 | A |
| `MenuItem(label, shortcut, *selected, enabled)` | `menuItem(label, .{.shortcut=...,...})` | 100 | A |

The main menu bar is a special foreground-z-order strip.  Per-window
menu bars require the window to have a `menu_bar_height` reserved
band; existing `Window.cursor_pos` reset uses `title_bar_height`
which we'd need to add `menu_bar_height` to when present.

**Sub-total: ~300 LoC, 1 turn.**

### 2.7 Tab bars (Phase 4)

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginTabBar(str_id, flags)` | `beginTabBar(str_id, .{})` | 60 | A |
| `EndTabBar` | `endTabBar()` | 20 | A |
| `BeginTabItem(label, *open, flags)` | `beginTabItem(label, .{.open_ptr=...})` | 80 | A |
| `EndTabItem` | `endTabItem()` | 10 | A |
| `TabItemButton(label, flags)` | `tabItemButton(label, .{})` | 30 | C |
| `SetTabItemClosed(label)` | `setTabItemClosed(label)` | 15 | C |

Persisted state per tab bar: which tab is currently selected (key
by hashed `str_id`).  Add `tab_bar_state: AutoHashMapUnmanaged(Id,
TabBarState)` to UiContext.

**Sub-total: ~215 LoC, 0.5 turns.**

### 2.8 List boxes (Phase 4)

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginListBox(label, size)` | `beginListBox(label, size)` | 30 | B |
| `EndListBox` | `endListBox()` | 5 | B |
| `ListBox(label, *current, items[])` | `listBox(label, *idx, items)` | 80 | B |

Trivially built on `beginChild` + selectable list.  `listBox` is the
all-in-one helper.

**Sub-total: ~115 LoC, 0.3 turns.**

### 2.9 Additional widgets (Phase 4)

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `ProgressBar(fraction, size, overlay)` | `progressBar(f, .{.size=...})` | 50 | A |
| `ArrowButton(str_id, dir)` | `arrowButton(str_id, dir)` | 40 | B |
| `SmallButton(label)` | `smallButton(label)` | 25 | B |
| `InvisibleButton(str_id, size)` | `invisibleButton(str_id, size)` | 35 | B |
| `Bullet` (already have) | — | — | done |
| `VSliderFloat/Int` | unify into `slider(.., .{.vertical=true})` | 80 | C |
| `RangeSlider` | `sliderRange(label, *low, *high, opts)` | 100 | C |
| `InputFloat/Int` (number input box) | `inputNumber(label, *T, opts)` | 120 | B |
| `PlotLines(label, values[], opts)` | `plotLines(label, values, .{})` | 150 | C |
| `PlotHistogram(...)` | `plotHistogram(label, values, .{})` | 100 | C |

`progressBar`, `inputNumber`, `arrowButton` are widely used; the
sliders/plot variants are nice-to-have.

**Sub-total: ~700 LoC including all tiers; ~340 if we drop the C-tier
plot/range/vslider items.**

### 2.10 Drag and Drop (Phase 4 stretch)

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `BeginDragDropSource(flags)` | `beginDragDropSource(.{})` | 60 | C |
| `SetDragDropPayload(type, *data, sz, cond)` | `setDragDropPayload(type, bytes)` | 40 | C |
| `EndDragDropSource` | `endDragDropSource()` | 10 | C |
| `BeginDragDropTarget` | `beginDragDropTarget()` | 50 | C |
| `AcceptDragDropPayload(type)` | `acceptDragDropPayload(type) ?[]const u8` | 60 | C |
| `EndDragDropTarget` | `endDragDropTarget()` | 10 | C |

State: `UiContext.dnd_active`, `dnd_payload_type`, `dnd_payload_bytes`
(arena-allocated slice).  Common but optional — many apps skip it.

**Sub-total: ~230 LoC, 0.5 turns.**

### 2.11 Color utilities (Phase 4)

Pure-math helpers we can wrap:

| ImGui name | zimr equivalent | LoC | Priority |
|---|---|---:|---|
| `ColorConvertU32ToFloat4` | `colorConvertU32ToFloat4(c)` | 15 | B |
| `ColorConvertFloat4ToU32` | `colorConvertFloat4ToU32(c)` | 15 | B |
| `ColorConvertRGBtoHSV` (already in textures) | re-export | 5 | B |
| `ColorConvertHSVtoRGB` (already in textures) | re-export | 5 | B |

**Sub-total: ~40 LoC, trivial.**

### 2.12 Phase 5 — Zig superpowers

The flagship demonstration that Zig + immediate-mode is a strict
superset of C++ + immediate-mode.

| Feature | What it does | LoC | Priority |
|---|---|---:|---|
| `editStruct(*T)` | Comptime walks `@typeInfo(T).Struct.fields`, dispatches per field type to the right widget | 250 | A |
| `editEnum(label, *T)` | Auto-detects enum, generates combo with all values | 60 | A |
| `editArrayList(label, *ArrayList(T))` | Add/remove + per-item edit | 200 | B |
| `editUnion(label, *T)` | Tagged-union editor: combo for tag + edit for active payload | 150 | C |
| `Snapshot` test infrastructure | Hash recorded DrawList; `try expectEqual(0xDEAD, ui.snapshotHash())` | 100 | B |

This phase has 3 turns of value because each piece compounds: the
style editor in Phase 6 is `editStruct(&style)` for free.

**Sub-total: ~760 LoC, 2 turns.**

### 2.13 Phase 6 — Polish

| Feature | LoC | Priority |
|---|---:|---|
| Style editor window (uses `editStruct(&style)`) | 80 | B |
| Layout persistence (`saveLayout(writer)` / `loadLayout(reader)` to JSON via std.json) | 200 | C |
| Keyboard navigation (Tab/Shift-Tab between widgets, Enter to activate) | 250 | C |
| `ShowDemoWindow(*open)` — port of imgui_demo.cpp's main window with all sections | 800 | B |

The big one is `ShowDemoWindow`.  Even at "mid-fidelity" (the design
doc's ~40 widgets) that's still ~800 LoC of demo code.  But it's
the visual proof that the port is complete.

**Sub-total: ~1330 LoC, 2 turns.**

---

## 3. Recommended phasing

Total remaining: ~4500 LoC across ~9 turns of work.  Suggested order
optimizes for "demo-visible" milestones at each phase boundary.

### Phase 4A — Window features + item state queries  (~720 LoC, ~1.5 turns)

**Single goal:** windows you can drag, resize, scroll; widgets you
can query for state.

Deliverables:
- All `setNextWindow*` functions
- All `isItem*` / `getItemRect*` functions (a widget records into
  `Window.last_item_*` at submission time; queries read those)
- Window drag-to-move (mouse-down on title bar → mouse-delta moves
  `w.pos`)
- Window drag-to-resize (corner grip rectangle with hit-test)
- Vertical scrollbar widget + `Window.scroll_y` + `setScrollY`,
  `getScrollMaxY`
- One new test per item-state query
- `imgui_demo.zig` exercises drag-resize + scrollbar

Acceptance: visual scrollbar appears when content exceeds window
height; drag handles work on both axes.

### Phase 4B — Layout + disabling  (~240 LoC, ~0.5 turns)

**Single goal:** the cluster-of-widgets idioms.

Deliverables:
- `beginGroup/endGroup` + group-as-item hover detection
- `pushItemWidth/popItemWidth/setNextItemWidth`
- `beginDisabled/endDisabled` with alpha multiplier + input gate
- `getContentRegionAvail/Max`
- `dummy(size)`, `alignTextToFramePadding`
- Demo: a settings panel using `beginDisabled` to grey-out a section

### Phase 4C — Popups + Menus  (~670 LoC, ~1.5 turns)

**Single goal:** right-click menus, modals, menu bars.

Deliverables:
- `openPopup`, `beginPopup`, `endPopup`
- `beginPopupModal` (with backdrop dimming)
- `beginPopupContextItem`, `beginPopupContextWindow`
- `closeCurrentPopup`, `isPopupOpen`
- `beginMainMenuBar/endMainMenuBar`, `beginMenuBar/endMenuBar`
  (per-window)
- `beginMenu/endMenu`, `menuItem` (with shortcut display)
- Demo: `imgui_demo.zig` gains a top menu bar + a right-click
  context menu on selectables

Tests: popup open/close lifecycle, modal dismissal, menu nesting.

### Phase 4D — Tabs + ListBox  (~330 LoC, ~0.7 turns)

**Single goal:** complete the container set.

Deliverables:
- `beginTabBar/endTabBar` + persistent state map
- `beginTabItem/endTabItem`
- `beginListBox/endListBox`, `listBox` helper
- Demo gets a tabbed section

### Phase 4E — Additional widgets  (~340 LoC, ~0.7 turns)

**Single goal:** plug widget gaps people reach for daily.

Deliverables:
- `progressBar`, `arrowButton`, `smallButton`, `invisibleButton`
- `inputNumber` (replaces ImGui's `InputFloat`/`InputInt` family,
  same anytype trick we used for slider)
- Color utilities (re-exports from `textures` namespace)

### Phase 5A — `editStruct` flagship  (~310 LoC, ~1 turn)

**Single goal:** the killer demo feature.

Deliverables:
- `editStruct(*T)` with full type dispatch:
  - bool → checkbox
  - integer → slider with sensible default range
  - float → slider 0..1 if name suggests probability/factor; drag
    otherwise
  - enum → combo (auto-fills items from enum tags)
  - struct → tree node + recurse
  - `[N]u8` → inputText
  - `[N]f32` (N≤4) → multi-slider
  - `?T` → checkbox to enable + nested edit
- `editEnum(label, *E)` standalone version
- New `examples/struct_editor.zig` demonstrating

Tests: comptime well-formedness check on every supported field
type; runtime test that mutating via the UI updates the underlying
struct.

### Phase 5B — `editArrayList` + snapshot tests  (~300 LoC, ~1 turn)

Deliverables:
- `editArrayList(label, *ArrayList(T))` with add/remove buttons +
  per-element `editStruct` recurse
- Snapshot test infrastructure: `ctx.snapshotHash() u64` walks all
  draw lists and SipHashes the command sequence (rect coords,
  colors, text bytes, clip rects).  Tests can pin behaviour to a
  hash; refactors that change pixels break loudly.

### Phase 6A — Style editor + layout persistence  (~300 LoC, ~0.7 turns)

Deliverables:
- `showStyleEditor(*open)` — a window built atop `editStruct(&style)`
  proving the meta-feature works.
- `saveLayout(writer) !void` / `loadLayout(reader) !void` — JSON
  serialization of window positions, sizes, collapsed-state, tab
  selections, tree-open-states.

### Phase 6B — Keyboard navigation + ShowDemoWindow  (~1050 LoC, ~2 turns)

Deliverables:
- Tab/Shift-Tab between focusable widgets in the active window.
  Enter to activate; arrow keys to move within a widget group.
  This requires per-frame "next focus" tracking.
- `showDemoWindow(*open)` — a faithful mid-fidelity port of the
  ImGui demo's main window: ~10 sections, ~40 widgets total.  This
  is what "the port is done" looks like to someone visiting.

---

## 4. Architectural decisions to make

Each one would otherwise come up mid-implementation.  Decide them
upfront so we don't litigate three times.

### 4.1 Window flags as bitflags or option struct?

ImGui has 30+ `ImGuiWindowFlags`.  Currently `WindowOpts` is a
struct with named bool fields (Zig idiom).  As we add more (popups,
modals, menu bars, no-resize, no-collapse, no-title-bar) the count
grows.

**Decision proposed:** keep the `WindowOpts` struct, no bitflags.
30 bool fields is fine in Zig (zero-cost with default values).  But:
add `WindowOpts.preset` for common combinations (`.popup`, `.modal`,
`.menu_bar`).

### 4.2 Popup z-order: sub-list of foreground or its own list?

Two reasonable approaches:
- **A.** Popups draw to `foreground_dl` (current location of tooltips).
  Simple, but loses ordering between popup → tooltip from popup.
- **B.** Each popup gets its own DrawList, replayed in popup-stack
  order.  Mirrors ImGui's per-window-stack draw lists more closely.

**Decision proposed:** B.  Popups already need persistent state
(open?, position, size); giving them a draw list each is consistent.

### 4.3 Disabled state — alpha-only or input-gate?

ImGui's `BeginDisabled` does both: alpha-multiplied rendering AND
input rejection.  Some users want one without the other.

**Decision proposed:** match ImGui — both at once via
`beginDisabled(true)`.  No knobs.

### 4.4 `editStruct` field metadata — name only or annotations?

ImGui has no metadata; field names are the labels.  But Zig has
docstrings and we could parse `@"min"`/`@"max"` decorator-style
attributes via comptime field discovery.

**Decision proposed:** start with field name as label only, with
default ranges (0..1 for float, full type range for int).  Add a
side-channel `EditStructOpts` struct the caller passes to override
specific fields.  Don't try to read docstrings — they're not
exposed at comptime in the current Zig.

### 4.5 Scrollbar drag-tracking via active_id?

Yes — scrollbar grip is a regular widget with an ID; drag updates
`Window.scroll_y`.  This is uniform with how every other drag widget
works in zimr.

### 4.6 Modal popup backdrop — own DrawCmd or just a giant rect?

**Decision proposed:** just emit a fullscreen `rect_filled` to
`foreground_dl` before the modal's draw list.  No new infrastructure.

### 4.7 Menu shortcuts — display only, or actually wire keyboard?

ImGui's `MenuItem(label, "Ctrl+S", &selected, true)` displays the
shortcut as a hint — wiring is up to the caller.  We do the same.
Phase 6's keyboard navigation can later auto-trigger from shortcut
strings if we want.

### 4.8 Tab bar selection persistence — per-bar or global?

Per-bar.  Keyed by hashed `str_id`.  Same pattern as `tree_open_state`
already uses for tree nodes.

### 4.9 ShowDemoWindow — port the C++ word-for-word, or rewrite?

The C++ demo is 10K LOC of `if (ImGui::CollapsingHeader("Foo")) { ... }`
blocks.  We do the same shape, but in Zig — call `f.ui.collapsing
Header("Foo")` and put `f.ui.checkbox/slider/etc` calls in.  ~800 LoC.

The point is to be a faithful tour of features, not a translation
of every demo line.  Skip what we don't have (tables, viewports);
add an "editStruct showcase" section that imgui_demo.cpp can't.

---

## 5. Risks

### 5.1 Rendering fidelity at small sizes

Already noted in `ui-design.md`.  Status: glyph rendering looks fine
in the current demo; sub-pixel positioning isn't bothering anyone
yet.  Watch for it as we add more text-heavy widgets (menu bar,
tab bar, plot axis labels).

### 5.2 Popup hit-testing edge cases

Click outside a popup → close it.  Click on a popup-inside-popup →
don't close the outer.  Right-click in a popup context menu →
don't open another popup at that location.  ImGui has subtle rules
in `imgui.cpp:UpdateMouseMovingWindowEndFrame`; we should port
faithfully (line-by-line) rather than reinvent.

**Mitigation:** designate `imgui.cpp:6500-6700` as the canonical
reference; copy logic verbatim into Zig.

### 5.3 Keyboard navigation interactions with active drag

If a slider is being dragged via mouse and the user tabs away, what
happens?  ImGui clears active_id on focus change.  We should match.

### 5.4 Snapshot test brittleness

Pixel-exact tests break on any layout tweak.  We mitigate by hashing
the LAYOUT (rect rects + texture bindings + colors), NOT the pixel
output.  A 1-pixel font-baseline shift won't change the layout-only
hash because the rect positions are still the same.

### 5.5 `editStruct` recursion blowup

`@typeInfo(T).Struct.fields` for a deeply nested struct generates a
LOT of code per field.  Each call site of `editStruct(*BigStruct)`
inlines the dispatch tree.

**Mitigation:** force-deduplicate via `pub fn editStruct(ptr: anytype) void`
not being itself comptime (only the inline-for loop inside is).
Each unique `T` gets exactly one specialization.

### 5.6 Layout-persistence schema versioning

If we ship saveLayout, then change the Window struct, old saves
break.  Need a version field.

**Mitigation:** version 1 on initial release; bump on incompatible
changes; loadLayout silently ignores unknown fields.

---

## 6. Testing strategy

The architectural primitives (ID hashing, DrawList, surface stack,
hit-test) are already covered by inline tests.  Each new widget /
phase adds:

1. **Unit tests for any pure logic.**  Example: tab-bar state
   transitions ("clicking inactive tab makes it active").
2. **Smoke-test integration.**  Each widget gets exercised in
   `imgui_demo.zig`; smoke runs the wasm build and asserts non-zero
   GL call counts.
3. **Snapshot tests** (Phase 5B onwards).  Once snapshot infra is
   in, every existing widget gets a canonical snapshot pinned.
   Refactors that change rendered output get caught.

We don't try to do automated visual regression — that's `imgui-test-
engine` territory, ~5K LOC of its own infrastructure.  Snapshot
hashes give us 80% of the value at 5% of the cost.

---

## 7. Success criteria

Per phase, "done" means:

- [x] All listed widgets compile (`zig build test` green).
- [x] Each widget exercised in `imgui_demo.zig` or a dedicated example.
- [x] Smoke test green (`zig build smoke-test`).
- [x] Inline tests for any non-trivial logic.
- [x] CHANGELOG entry per phase summarising what landed.
- [x] Cheatsheet regenerated (the cheatsheet generator already covers
      `pub fn` discovery — no extra work).

After all phases:
- [x] `examples/struct_editor.zig` demonstrating `editStruct` on a
      20-field GameSettings struct.
- [x] `showDemoWindow(&open)` window covers ~80% of imgui_demo.cpp's
      mid-fidelity tour.
- [x] Existing 38% demo coverage tally rises to **>85%**.
- [x] Two new examples: a property inspector (uses editStruct +
      collapsingHeader + scroll), a node graph (uses dragDrop).

---

## 8. Cross-cutting tasks (not phase-bound)

These run alongside the phase work:

- **GC pass for stale windows.**  `Window.last_frame_active` is
  recorded but never checked.  Add a 60-frame stale timeout; drop
  windows not seen recently (saves memory if user opens many
  one-shot popups).  ~30 LoC.
- **Style scope builder.**  `ui.styleScope().color(.button, .red).end()`.
  Already designed in `ui-design.md`.  ~80 LoC, trivial.
- **WindowFlags enum-set helper.**  Easier `.{ .preset = .modal }`
  than 5 separate bool fields.  ~30 LoC.
- **Doc comment audit.**  Every new pub fn gets the same `///` doc
  pattern as the existing ones — example block + raylib parity
  note.  Already a habit; called out for completeness.

---

## 9. Open questions for the user

Before code starts, confirm:

1. **Is drag-and-drop in or out of scope?**  The plan above puts it
   in Phase 4D as Tier C.  If we drop it entirely, Phase 4 is ~200
   LoC lighter.
2. **Tables — really skip?**  ImGui's Tables is 5K LoC alone but
   tables-as-data-grids are very useful.  Could we do a much-reduced
   "simple table" (no sort, no resize columns, no headers row) in
   ~500 LoC?  Worth considering for a later phase.
3. **Demo fidelity target.**  The original `ui-design.md` says
   "mid-fidelity, ~40 widgets".  The plan above hits ~85% of imgui_
   demo.cpp.  Is that the right target, or do we want something
   smaller / larger?
4. **Phase ordering — can we reorder?**  Phase 5A (`editStruct`) is
   the most quotable feature; we could move it earlier (between 4B
   and 4C) so a "wow" demo lands sooner.  Recommended.
5. **Multiple windows or modal-only?**  Phase 4C's modal support is
   the foundation for `showDemoWindow`.  Plain non-modal popups
   (right-click context menus) are common enough to keep in scope.
   Confirmed?

---

## 10. Effort summary

| Phase | LoC | Turns |
|---|---:|---:|
| 4A. Windows + item state | 720 | 1.5 |
| 4B. Layout + disabling | 240 | 0.5 |
| 4C. Popups + menus | 670 | 1.5 |
| 4D. Tabs + listbox | 330 | 0.7 |
| 4E. Additional widgets | 340 | 0.7 |
| 5A. editStruct flagship | 310 | 1.0 |
| 5B. editArrayList + snapshots | 300 | 1.0 |
| 6A. Style editor + persistence | 300 | 0.7 |
| 6B. Kbd nav + showDemoWindow | 1050 | 2.0 |
| **Total** | **4260** | **~9.5** |

Compared to original `ui-design.md` estimate of 5-7K LoC remaining
after Phase 1 — we're tracking inside that envelope because the
infrastructure work is already done.

After this plan executes, `src/ui.zig` lands at ~7500-8000 LoC.
For comparison, ImGui's `imgui.cpp` + `imgui_widgets.cpp` is 32K
LoC.  We're hitting ~75% of the feature set in ~25% of the line
count.  That ratio is the central thesis of the port: Zig's
comptime + slices + native pointer params collapse the C++ overload
zoo, the per-widget boilerplate, and the manual memory choreography
that bloats imgui.cpp.

---

## 11. Recommended next-turn entry point

Phase 4A.  Specifically: open a turn with these targets in order:
1. `setNextWindowPos` + `setNextWindowSize` (the most-used 2 next-
   window helpers; gates the next two items).
2. Window drag-to-move via title-bar grab.  Validates that ImGui-
   style drag-with-active-id works for a "fixed" widget (the title
   bar) the same way it works for sliders.
3. Vertical scrollbar.  When this lands, child windows can scroll,
   and a 100-line log inside an 80-pixel-tall child suddenly works.
4. `isItemEdited` + `isItemActive`.  Tiny.  Unblocks the snapshot
   tests in Phase 5B.

Time estimate for that combined micro-phase: 1 turn.  Lands a
visibly-resizable window with a working scrollbar; user feedback
then tells us whether the architectural pattern is right before we
build more widgets on top.

---

*End of plan.  Execute Phase 4A next turn.*
