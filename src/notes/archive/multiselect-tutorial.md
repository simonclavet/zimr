# imgui MultiSelect API — tutorial for the zimr port

Authoritative source studied at `/tmp/imgui-master/` (v1.92.8 WIP):
- `imgui.h:3026-3140` — declarations.
- `imgui_widgets.cpp:7995-8525` — `BeginMultiSelect`, `EndMultiSelect`, `MultiSelectItemHeader`/`Footer`.
- `imgui_widgets.cpp:8583-8810` — `ImGuiSelectionBasicStorage`.
- `imgui_demo.cpp:2724-2830` — manual vs MultiSelect demos.

This doc is intended as a *one-time orienting read* before implementing
Step 1.3.  It's organized so you can stop early — the MVP needs only
sections 1-6, 9, 12.

---

## 1. The problem in one sentence

You have a list of items.  Users want to select one (click), add one
(Ctrl-click), select a range (Shift-click), select all (Ctrl-A),
clear (Escape), and rubber-band drag-select.  Doing this correctly
**with a clipper** (virtualized list of 100k items where most aren't
even submitted to imgui) requires tracking the "anchor" item across
frames, the post-deletion focus target, and a state machine your code
can't see.

Imgui's MultiSelect API absorbs all of that.

## 2. The mental model: requests, not mutations

The naive approach: when user clicks item N, mutate
`selection.add(N)`.  Doesn't scale — the multi-select code (running
inside imgui, when it processes the click) doesn't *own* your
selection set.  It can't mutate it.

Imgui's solution: **the multi-select code emits selection requests;
your code applies them.**  A request is a tiny data structure like
"SetAll(selected=true)" or "SetRange(firstItem=3, lastItem=7,
selected=false)".  Your code reads the requests after Begin/End and
updates its own storage.

This decouples imgui from your selection representation.  You can
store selection as `HashMap<ID, void>`, `[1024]bool`, a sorted
`Vec<u32>`, an intrusive flag in your items — whatever.  As long as
you implement `applyRequests`, you participate.

## 3. The three-phase flow

```
BEGIN
  - You call BeginMultiSelect(flags, selection_size, items_count) → IO*
  - IO.Requests may already contain requests from THIS FRAME's
    keyboard events that fired before Begin (Escape, Ctrl-A) or from
    box-select drag completion
  - You apply those requests to your selection NOW
  - Reason: items rendered in the loop need to know their current
    selected state

LOOP
  - For each item, call SetNextItemSelectionUserData(some_id) BEFORE
    the widget
  - The widget (Selectable, Checkbox, etc.) calls MultiSelectItemHeader
    internally:
      - Picks up the user-data slot
      - May override the `selected` bool you passed (for keyboard
        range-select preview)
      - Adjusts ButtonFlags so click timing matches imgui's policy
  - Widget does its normal hover/active/click logic
  - Widget calls MultiSelectItemFooter internally:
      - On click: emits SetRange (or sometimes SetAll-clear + SetRange)
      - Updates RangeSrcItem if this item just became the anchor
      - Updates NavId state for keyboard nav

END
  - You call EndMultiSelect() → IO* (same struct, with this loop's
    emitted requests)
  - Apply those requests to your selection
```

A canonical example boils down to:

```cpp
ImGuiMultiSelectIO* io = BeginMultiSelect(flags, sel.Size, items_count);
sel.ApplyRequests(io);                    // Phase 1: apply pending
for (int n = 0; n < items_count; n++) {
    bool is_sel = sel.Contains(n);
    SetNextItemSelectionUserData(n);      // Tag this item
    Selectable(labels[n], is_sel);        // Widget emits requests on click
}
io = EndMultiSelect();
sel.ApplyRequests(io);                    // Phase 2: apply this frame's clicks
```

The exact same `ApplyRequests` runs in both phases.  Idempotent.

## 4. Data structures

```cpp
struct ImGuiMultiSelectIO {
    ImVector<ImGuiSelectionRequest> Requests;  // The work list
    ImGuiSelectionUserData RangeSrcItem;       // Current anchor (clipper invariant)
    ImGuiSelectionUserData NavIdItem;          // Focused item (for deletion)
    bool                   NavIdSelected;
    bool                   RangeSrcReset;      // App writes before End to reset anchor
    int                    ItemsCount;         // Copy of arg passed to Begin
};

struct ImGuiSelectionRequest {
    ImGuiSelectionRequestType Type;            // None | SetAll | SetRange
    bool                      Selected;        // true=select, false=unselect
    ImS8                      RangeDirection;  // +1 forward, -1 backward
    ImGuiSelectionUserData    RangeFirstItem;  // Inclusive
    ImGuiSelectionUserData    RangeLastItem;   // Inclusive
};
```

`ImGuiSelectionUserData` is `ImS64` (signed 64-bit).  Most code uses
it as an integer index but a pointer or hashed ID also fits.

Only 2 active request types:

- **SetAll**: clear everything if `Selected==false`, select
  everything if `Selected==true`.  Used for Escape clear, Ctrl-A,
  "clear before applying range".
- **SetRange**: set items `[RangeFirstItem..RangeLastItem]`
  (inclusive both ends) to `Selected`.  The most common request:
  shift-click emits `SetAll(false) + SetRange(anchor..clicked, true)`.

## 5. SelectionUserData design

The zimr plan calls for `u64`.  Imgui uses signed `i64` so they can
use `-1` as "invalid".  For us, `u64` plus a `std.math.maxInt(u64)`
sentinel works equivalently.  Or use `?u64` and let the API hold
optionality directly — more idiomatic Zig.

Indexes are the recommended payload because **SetRange asks you to
iterate `first..=last`**.  If the payload is an index, the iteration
is `for (first..=last) |idx| set(idx, sel)`.  If it's a pointer, you
have to maintain an index→pointer map separately.  The wiki
explicitly recommends storing indexes here, and persistent IDs
separately (via the AdapterIndexToStorageId callback).

## 6. SelectionBasicStorage

```cpp
struct ImGuiSelectionBasicStorage {
    int   Size;
    bool  PreserveOrder;
    void* UserData;
    ImGuiID (*AdapterIndexToStorageId)(self, int idx);  // user-provided
    ImGuiStorage _Storage;  // ID → 1 (selected) or absent
    // Methods: Clear, Contains, SetItemSelected, ApplyRequests, GetNextSelectedItem
};
```

The point of `AdapterIndexToStorageId`: SetRange gives you indexes
`[first..last]`, but you want to store persistent IDs (so when items
get sorted/filtered, the selection survives by ID, not by row
position).  The adapter converts.  Default adapter: `id = idx` (i.e.
indexes ARE IDs; works for static lists).

The body of `ApplyRequests` (paraphrased from imgui_widgets.cpp:8683):

```
for each req in io.Requests:
    if req.Type == SetAll:
        Clear()
        if req.Selected:
            for idx in 0..io.ItemsCount:
                SetItemSelected(AdapterIndexToStorageId(idx), true)
    elif req.Type == SetRange:
        for idx in req.RangeFirstItem..=req.RangeLastItem:
            SetItemSelected(AdapterIndexToStorageId(idx), req.Selected)
```

The real imgui code is optimized with batch sort tricks for 100k+
items; the above is the conceptual version.  For our MVP, the simple
version is fine.

## 7. The item-side hooks: Header vs Footer

Selectable, Checkbox, etc. call **two** hooks
(imgui_widgets.cpp:7017 in Selectable's impl):

```cpp
MultiSelectItemHeader(id, &selected, &button_flags);
// ... normal ButtonBehavior with maybe-modified button_flags
MultiSelectItemFooter(id, &selected, &pressed);
```

**Header runs BEFORE click detection.**  It:

- Pulls in the SetNextItemSelectionUserData slot
- Updates `*selected` if a keyboard range-select preview is in
  progress (shift+arrow)
- Mutates `button_flags` (e.g. switches PressOnClick→PressOnClickRelease
  per the SelectOnAuto policy)

**Footer runs AFTER click detection.**  It:

- On `pressed==true`: emits the SetRange / SetAll-clear+SetRange
  request pair based on modifiers
- Updates `storage.RangeSrcItem` if this item just became the anchor
- Updates `storage.NavIdItem` / `NavIdSelected` if this item is focused

This split is necessary because the same click event drives both
"what's the visual state during render" (header) and "what does my
click change" (footer).

## 8. Flag matrix

17 flags total.  Organized by what they control.  Zimr port will
translate exclusive groups to enums per zimr's flag-decision rule.

### Selection model (exclusive)

- `SingleSelect` — only one item at a time; disables multi-select
  but keeps the API shape.  Useful for code that wants to be
  toggleable single ↔ multi.
- (otherwise: multi-select, default)

### Box-select mode (exclusive)

- `BoxSelect1d` — same-X items only (full-row Selectables) — cheaper.
- `BoxSelect2d` — varying X — alters clipping for horizontal
  box-select.
- (otherwise: no box-select, default)

### Scope (exclusive, for box-select + ClearOnClickVoid)

- `ScopeWindow` — scope is whole window (default).
- `ScopeRect` — scope is rect encompassing Begin..End (use when
  window has multiple MS scopes).

### Click timing (exclusive)

- `SelectOnAuto` — down on unselected, up on selected (default;
  permits drag-drop).
- `SelectOnClickAlways` — always on mouse-down (Excel-style).
- `SelectOnClickRelease` — always on mouse-up (most lenient for drag).

### Independent (boolean) flags

- `NoSelectAll` — disable Ctrl-A.
- `NoRangeSelect` — disable Shift-anything (Shift-click,
  Shift-arrow); guarantees single-item-range SetRanges.
- `NoAutoSelect` — disable auto-select on keyboard nav (used with
  checkbox-list mode).
- `NoAutoClear` — disable auto-clear on click (also checkbox-list
  mode).
- `NoAutoClearOnReselect` — clicking an already-selected item
  doesn't clear others.  Mac Finder behavior.
- `BoxSelectNoScroll` — box-select won't auto-scroll near edges.
- `ClearOnEscape` — Escape clears selection (emit SetAll(false)).
- `ClearOnClickVoid` — clicking empty area within scope clears.
- `NavWrapX` — keyboard nav wraps horizontally.
- `NoSelectOnRightClick` — right-click doesn't select (for context
  menus).

For zimr Step 1.3 MVP, ship: `SingleSelect`, `NoSelectAll`,
`NoRangeSelect`, `NoAutoClearOnReselect`, `ClearOnEscape`.  Defer
box-select, scope variations, click-timing variations, nav-wrap,
right-click (no right-click on phone anyway).  Minimum useful: click
= replace, Ctrl = toggle add, Shift = range.  That covers the demo.

## 9. Click → request truth table

From imgui_widgets.cpp:8442 (the comment block):

| Action | Modifiers | Request emitted |
|---|---|---|
| Mouse click | none | SetAll(false) + SetRange(item..item, true) — anchor=item |
| Mouse click | Ctrl | SetRange(item..item, toggle) — anchor=item |
| Mouse click | Shift | SetAll(false) + SetRange(anchor..item, true) |
| Mouse click | Ctrl+Shift | SetRange(anchor..item, !anchor_state) |
| Keyboard activate (Space) | none | SetAll(false) + SetRange(item..item, true) |
| Keyboard activate | Ctrl | SetRange(item..item, toggle) |
| Keyboard activate | Shift | SetAll(false) + SetRange(item..item, true) |
| Keyboard nav (Arrow) | none | SetAll(false) + SetRange(nav_to..nav_to, true) |
| Keyboard nav | Shift | SetRange(anchor..nav_to, true) — range-select preview |
| Keyboard nav | Ctrl+Shift | SetRange(anchor..nav_to, anchor_state) |
| Escape (with ClearOnEscape) | — | SetAll(false) |
| Ctrl-A (without NoSelectAll) | — | SetAll(true) |
| Box-select item entering rect | — | SetRange(item..item, true) |
| Box-select item exiting rect | — | SetRange(item..item, false) |

Notes:

- "anchor_state" = whether the anchor item is currently selected;
  copies that state for Ctrl+Shift range
- Multiple adjacent single-item SetRange requests are NOT merged by
  imgui (the optimization was removed 2026/04/09 per
  imgui_widgets.cpp:8537)

## 10. Clipper interaction (deferred for zimr — listed for future)

The big payoff of imgui's design: with `ImGuiListClipper`, you only
call SetNextItemSelectionUserData + Selectable for VISIBLE items.
The clipper skips off-screen ones.  But how does multi-select know
the selection state of items it never saw?

Answer: it doesn't have to.  SetRange requests are *index ranges*.
The user's ApplyRequests iterates the range using indexes (which the
user knows about regardless of whether items rendered).  The only
invariant: **RangeSrcItem must always be submitted**, even if
scrolled off-screen — clipper provides `IncludeItemByIndex(idx)` for
this.

For zimr Step 1.3 we'll skip clipper (no clipper API yet) and just
iterate all items.  Filed for Phase 1.6's "list virtualization"
cluster.

## 11. Edge cases — checkbox-list mode

The trickiest "non-default" mode is **NoAutoSelect + NoAutoClear**:

```cpp
ImGuiMultiSelectFlags flags = ImGuiMultiSelectFlags_NoAutoSelect
                            | ImGuiMultiSelectFlags_NoAutoClear
                            | ImGuiMultiSelectFlags_ClearOnEscape;
```

Semantics:

- Click on an item: only that item toggles (no other state changes)
- Shift-click: extend a range from anchor — still works
- Arrow-nav: moves focus but doesn't change selection
- Used for "list of checkboxes" where each row is independently
  toggleable but you still want shift-click for bulk operations

Other notable edges:

- `NoAutoClearOnReselect`: clicking an already-selected item normally
  clears others; with this flag, it doesn't.
- `SingleSelect`: forces `NoRangeSelect` semantics for selection
  storage but still emits identical request types — just always a
  single-item SetRange.

## 12. Mapping to zimr's idioms

API sketch (Zig):

```zig
pub const MultiSelectFlags = struct {
    selection: enum { multi, single } = .multi,
    box_select: enum { none, d1, d2 } = .none,
    scope: enum { window, rect } = .window,
    click_timing: enum { auto, always, release } = .auto,

    no_select_all: bool = false,
    no_range_select: bool = false,
    no_auto_select: bool = false,
    no_auto_clear: bool = false,
    no_auto_clear_on_reselect: bool = false,
    box_select_no_scroll: bool = false,
    clear_on_escape: bool = false,
    clear_on_click_void: bool = false,
    nav_wrap_x: bool = false,
    no_select_on_right_click: bool = false,
};

pub const SelectionRequest = union(enum) {
    set_all: bool,
    set_range: struct {
        first: u64,
        last: u64,        // inclusive
        direction: i2,    // +1 or -1
        selected: bool,
    },
};

pub const MultiSelectIO = struct {
    requests: std.ArrayList(SelectionRequest),
    range_src_item: ?u64,
    nav_id_item: ?u64,
    nav_id_selected: bool,
    range_src_reset: bool,
    items_count: u32,
};

pub fn beginMultiSelect(
    self: Ui,
    flags: MultiSelectFlags,
    selection_size: u32,
    items_count: u32,
) *MultiSelectIO;
pub fn endMultiSelect(self: Ui) *MultiSelectIO;
pub fn setNextItemSelectionUserData(self: Ui, data: u64) void;
pub fn isItemToggledSelection(self: Ui) bool;

pub const SelectionBasicStorage = struct {
    map: std.AutoHashMap(u64, void),
    pub fn contains(self: *const @This(), id: u64) bool;
    pub fn add(self: *@This(), id: u64) !void;
    pub fn remove(self: *@This(), id: u64) void;
    pub fn clear(self: *@This()) void;
    pub fn applyRequests(self: *@This(), io: *const MultiSelectIO) !void;
    pub fn size(self: *const @This()) usize;
};
```

Storage approach: skip the AdapterIndexToStorageId callback for now.
Indexes ARE IDs.  If a future demo needs persistent IDs (sortable
list), we add the adapter then.

Storage's `applyRequests` is the conceptual ~10 lines from §6 — the
optimized batch-sort version is YAGNI until someone has 100k items.

The internal context state needs new fields on `UiContext`:

- `current_multi_select: ?*MultiSelectScope` — non-null between
  Begin and End.
- `next_item_selection_user_data: ?u64` — slot consumed by next
  widget.
- `ms_storage: AutoHashMap(WidgetId, MultiSelectState)` — persistent
  state keyed by the scope's id stack top.  Stores `range_src_item`,
  `range_selected`, `nav_id_item`, `nav_id_selected` across frames.

Selectable changes (~30 lines added):

- After computing `id` and `hovered`, if `current_multi_select != null`:
  - Call internal `multiSelectItemHeader(id, &selected,
    &button_flags)` to maybe override `selected` (for kb range
    preview — essentially a no-op for zimr until keyboard nav is
    added)
- After click detection, if `current_multi_select != null` and
  `clicked`:
  - Call internal `multiSelectItemFooter(id, &selected, &clicked)`
    which appends to `io.requests` based on modifiers
- Note: `selected` becomes an output too — multi-select may flip it
  for visual preview.

Ctrl key support: add `key_ctrl_down: bool` to `InputSnapshot`.
Runtime side: `runtime.input.isKeyDown(.left_control) or
runtime.input.isKeyDown(.right_control)`.

Test surface: SelectionBasicStorage unit-testable in isolation (no
UI dependency).  MultiSelect scope ops (Begin/End, request emission)
testable with synthetic clicks + the headless test harness zimr
already has (`src/ui_test.zig`).

Demo: `examples/ui_multiselect_finder.zig` — file-list with 50
items.  Phone affordance: a "selection mode" toggle button that,
when on, makes every tap behave as if Ctrl-click (since phones lack
Ctrl).  Shift via a separate "range mode" button.  Probably the
toggle approach is cleaner than long-press-for-shift.

## 13. Scope decision for Step 1.3

**MVP scope (4-5 turns):**

- Turn 1 (302, done): cleanup + this tutorial.
- Turn 2: types (flags struct, IO, Request union, BasicStorage
  skeleton) + `key_ctrl_down` infra + unit tests for BasicStorage.
- Turn 3: `beginMultiSelect` / `endMultiSelect` /
  `setNextItemSelectionUserData` + scope state in context +
  Selectable integration (header/footer hooks).
- Turn 4: `ui_multiselect_finder` demo + phone test.
- Turn 5: polish + step closes ✅.

**Deferred (filed for follow-ups):**

- Box-select (any 1d/2d) — needs drag rectangle infra.
- Keyboard nav — Phase 6 territory; zimr's kb nav is minimal today.
- Clipper integration — no clipper API yet.
- Tree multi-select — Step 1.5 lays the tree groundwork first.
- Deletion handling (NavIdItem / RangeSrcReset bookkeeping) —
  advanced; revisit when a demo needs deletion-aware selection.
- ExternalStorage adapter — not needed for MVP.
- Right-click handling — phone has no right-click; revisit when
  desktop needs context menus.

---

## TL;DR

The hard part is conceptual: **imgui doesn't mutate your selection;
it tells you what to mutate via a list of requests**.  Once you
internalize that:

1. `Begin` → drain pending requests into your storage.
2. Render items, each tagged with `SetNextItemSelectionUserData(idx)`.
3. `End` → drain this frame's click-emitted requests into storage.

`SelectionBasicStorage` is a hashmap that knows how to apply
requests.  Two request types: SetAll (with bool) and SetRange (with
bool + first + last).  10-line `applyRequests` body.

Selectable's job: emit one of the rows from the click→request truth
table in §9 when clicked-inside-MS-scope.  Everything else (storage,
hashmap, applyRequests) is data-plumbing.
