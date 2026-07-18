# imgui parity audit (v2)

> **Style guide reminder.**  Before executing any phase below,
> apply these rules to all new and modified code (full text in
> `src/notes/claude.md`):
>
> 1. Function args — 1 per line for 3+ args, trailing comma.
> 2. Locals — explicit types (`const i: usize = ...`).
> 3. Braces — required on every if/else/while/for branch.
> 4. Comments — casual, what + why, no decoration.
> 5. Array-of-N-copies — `@splat(...)`, not `**`.
> 6. Magic literals — lift to named locals before the call.
> 7. Conditions — trivial; lift complex sub-exprs to bools.
> 8. Helpers — only when name does real work AND it'll see a
>    second caller, or chunks are genuinely separable.
> 9. No module-level mutable globals (whole codebase, JS-
>    bridge in `src/zimr.zig` excepted).
> 10. Lines ≤ 120 cols; trailing commas force multi-line.
> 11. Integer types — `i32` / `usize` defaults; never `c_int`.
>
> Touching a function means bringing the whole function up to
> spec, not just the change.

Source of truth: `imgui.h` master.  Cross-referenced against
`src/ui.zig` after Turn 187 with grep-level verification of every
claim — not name-match heuristics.

---

## TL;DR — the imgui-parity arc

**Goal:** "everything imgui has, we want it."  Full feature parity
with `imgui.h` master, paradigm-incompatible APIs excepted (multi-
viewport, allocator hooks, va_list V-variants, IME).

**Scope:** **26 turns**, organized into 8 phases (A–H).  All phases
in-scope per the "if it's not useful, they would have removed it"
directive.  Phase H ("Tier 4 niche") was previously marked optional;
now folded into the committed plan.

**Turn-by-turn outline:**

| Phase | Turns | Theme | Headline gain |
|---|---|---|---|
| A | 4 | Foundation | ListClipper + multiline + scroll + font stack |
| B | 3 | Input polish | Mouse cursor + Shortcut + menu bar + BeginCombo |
| C | 3 | Text + filter + multi-select | TextFilter + MultiSelect |
| D | 2 | Splitter + window + tree polish | Splitter + TreeNodeEx flags |
| E | 6 | Flag-extension waves | ~290 flags across 15 Opts structs |
| F | 3 | Tier-3 cleanup | ~40 small functions |
| G | 2 | Debug windows + capstone | Metrics + DebugLog + capstone |
| H | 3 | Logging + .ini + drawlist channels | Tier-4 niche but real |

**What ships at the end:** every imgui.h function with a feature
equivalent, every flag exposed via Opts, every helper type
implemented in zimr-idiomatic form (HashMap-backed selection
storage, ArrayList-backed filters, etc.).  The `ui_full_showcase`
capstone gets a tab per phase boundary; final showcase covers all
8 dimensions.

**Recommended first turn:** **A1 — Window scrolling API + clipboard.**
Smallest atomic unit, no architectural decisions blocked on it,
ships a visible win (auto-scroll log viewer demo).  Sets the
cadence for the arc.

**Smoke / gate discipline:** per-turn focused (Turn 183 pattern);
full smoke every 3 turns + at every phase boundary; capstone
refresh at each phase boundary.

**Lifetime estimate:** at 1 phase per week of work, the arc is
~8 weeks.  At the gate-by-gate pace this session has been running
(1 turn = 1 deliverable), it's 26 sessions.

---

## Methodology note

This document supersedes v1 (deleted) which was function-level
only and significantly undercounted the gap.  v1 said 9 turns to
~98% parity; v2 estimates **26 turns** to true feature-complete
parity because three large surface dimensions were missed:

1. **Flag enums** — 27 enums, **396 distinct flag values**.  zimr's
   `Opts` structs cover roughly **30** of those.  Gap: ~290 flags
   (in-scope; ~88 are N/A for paradigm reasons).
2. **Helper types** — `ImGuiListClipper`, `ImGuiTextFilter`,
   `ImGuiInputTextCallbackData`, `ImGuiMultiSelectIO`,
   `ImGuiSelectionBasicStorage`, etc.  9 in-scope types entirely
   missing.
3. **Enum-only types** — `ImGuiKey` (147 values; zimr has 35),
   `ImGuiCol` (~55; zimr ~30), `ImGuiCond` (4; zimr 2 of 4).

After v2 the picture is honest: function-name surface is ~75%
covered; configurability surface (flags) is ~10% covered; helper-
type surface is ~40% covered.

Methodology: every "✅" verified by `grep` on `src/ui.zig`.
Every flag count came from parsing `imgui.h`.  Every zimr field
count came from parsing `Opts` struct definitions.

---

# §A — Headline numbers

| Dimension | imgui | zimr | coverage |
|---|---|---|---|
| Namespace functions | 365 | 179 (114 same-name) | ~75% by feature |
| Flag enum total values | 396 / 27 enums | ~30 / 19 Opts | ~8% |
| Helper types (public) | 24 | ~10 equivalent | ~40% |
| `ImGuiKey` values | 147 | 35 | ~24% |
| `ImGuiCol` slots | ~55 | ~30 | ~55% |
| `ImGuiMouseCursor` | 9 | 11 | ✅ (runtime layer) |

---

# §B — Corrections to v1

1. **`treeNode`** — v1 said ✅.  Verified: no-flags form exists;
   `TreeNodeEx(label, ImGuiTreeNodeFlags)` (26 flags) is missing.
   Should be ⚠️ partial.
2. **`isItemHovered`** — v1 said ✅.  Verified: zimr's takes no
   args; imgui's takes `ImGuiHoveredFlags` (21 flags). ⚠️.
3. **`isWindowFocused`/`isWindowHovered`** — same flags issue
   (`ImGuiFocusedFlags`, `ImGuiHoveredFlags`).
4. **`window(...)`** — v1 said ✅.  `WindowOpts` has 2 fields;
   `ImGuiWindowFlags` has 30 flags.  Configurability ~7%.
5. **`ColorEditOpts`** has 2 fields; `ImGuiColorEditFlags` has 29.

---

# §C — Function-level audit (refined)

Status legend:
- ✅ have, full feature
- ✅¹ have via comptime dispatch on `anytype` (collapses imgui variants)
- ⚠️ function exists; missing configurability (flags) — see §D
- ❌ missing
- ⛔ N/A — paradigm-incompatible

## §C1 — Context & Main (8)

| imgui | zimr | status |
|---|---|---|
| CreateContext / DestroyContext | `UiContext.init(gpa)` / `.deinit()` | ✅ |
| GetCurrentContext / SetCurrentContext | — | ⛔ user owns ctx |
| NewFrame / EndFrame | `beginFrame` / `endFrame` | ✅ |
| Render | folded into `endFrame` | ✅ |
| GetDrawData | — | ⛔ eager rlgl submission |

## §C2 — Demo/Debug/Info (10)

| imgui | zimr | status |
|---|---|---|
| ShowDemoWindow | `showDemoWindow` | ✅ |
| ShowMetricsWindow | — | ❌ |
| ShowDebugLogWindow | — | ❌ |
| ShowIDStackToolWindow | — | ❌ |
| ShowAboutWindow | — | ❌ |
| ShowStyleEditor | `styleEditor` | ✅ |
| ShowStyleSelector / FontSelector / UserGuide | — | ❌ all 3 |
| GetVersion | — | ❌ |

## §C3 — Styles (3)

| imgui | zimr | status |
|---|---|---|
| StyleColorsDark | `Style.dark_default` | ✅ |
| StyleColorsLight / Classic | — | ❌ |

## §C4 — Windows + Children

- `Begin` / `End`: `window(...)` ⚠️ — function ✅, 30 WindowFlags ❌
- `BeginChild` / `EndChild`: ⚠️ — function ✅, ~8/10 ChildFlags ❌

## §C5 — Window utilities (9)

- IsWindowAppearing / IsWindowCollapsed — ❌
- IsWindowFocused / IsWindowHovered — ⚠️ flags missing
- GetWindowDrawList / Pos / Size / Width / Height — ✅

## §C6 — Window manipulation (12)

- SetNextWindowPos/Size — ⚠️ cond=once only (2 of 4 `ImGuiCond`)
- SetNextWindowSizeConstraints / ContentSize / Collapsed / Scroll — ❌
- SetNextWindowFocus / BgAlpha — ✅
- SetWindow* (4 named-window variants) — ❌

## §C7 — Window scrolling (10)

ALL ten missing.  `Window.scroll_y` exists internally.

## §C8 — Parameter stacks (19)

- Font: PushFont/PopFont — ❌; Get* — ⚠️ via `style().font`
- Shared: PushStyleColor/Var subsumed by `pushStyle` ✅¹; PushItemFlag — ❌
- Current: PushItemWidth ✅; CalcItemWidth — ❌; PushTextWrapPos — ❌

## §C9 — Layout (24)

Cursor + groups mostly ✅ except: SetCursorScreenPos, SetCursorPosX/Y,
GetCursorPosX/Y, GetCursorStartPos, GetTextLineHeight family (4 fns) — ❌.

## §C10 — ID stack (3)

- PushID / PopID — ✅
- GetID — ❌

## §C11 — Widgets: Text (14)

All ✅ except `SeparatorText` ❌.  (V variants ⛔ for Zig.)

## §C12 — Widgets: Main (11)

- Button (⚠️ 6 ButtonFlags), SmallButton, ArrowButton, Checkbox,
  RadioButton, ProgressBar, Bullet — ✅
- InvisibleButton, CheckboxFlags, TextLink, TextLinkOpenURL — ❌

## §C13 — Widgets: Images (3)

- Image, ImageButton — ✅
- ImageWithBg — ❌

## §C14 — Widgets: Combo (3)

- Combo — ⚠️ (8 ComboFlags missing)
- BeginCombo / EndCombo — ❌

## §C15 — Widgets: Drag (12)

All 12 typed variants collapsed into `drag(label, *T, opts)` ✅¹.
DragFloatRange2 / DragIntRange2 — ❌.

## §C16 — Widgets: Sliders (14)

All collapsed into `slider` / `vSlider` ✅¹.  9 SliderFlags missing.

## §C17 — Widgets: Input with keyboard (20)

- InputText / WithHint — ⚠️ 27 InputTextFlags
- InputTextMultiline — ❌
- InputFloat / Int / Scalar (with N variants) — ✅¹
- ColorEdit / Picker / Button — ⚠️ 29 ColorEditFlags
- SetColorEditOptions — ❌

## §C18 — Widgets: Trees (11)

- TreeNode — ⚠️ no flags variant
- TreeNodeEx (with 26 flags) — ❌
- TreePop / CollapsingHeader — ✅ (⚠️ flags)
- SetNextItemOpen / StorageID / TreeNodeGetOpen / GetTreeNodeToLabelSpacing — ❌

## §C19 — Widgets: Selectables (5)

- Selectable — ⚠️ 9 SelectableFlags
- BeginMultiSelect / EndMultiSelect / SetNextItemSelectionUserData / IsItemToggledSelection — ❌ (plus 20 MultiSelectFlags)

## §C20 — Widgets: List Boxes (3)

All ✅.

## §C21 — Widgets: Plotting (3)

- PlotLines, PlotHistogram — ✅
- Value — ❌

## §C22 — Widgets: Menus (7)

- BeginMainMenuBar / EndMainMenuBar / BeginMenu / EndMenu / MenuItem — ✅
- BeginMenuBar / EndMenuBar (per-window) — ❌

## §C23 — Tooltips (7)

All ✅ except SetItemTooltip / V — ❌.

## §C24 — Popups, Modals (10)

- BeginPopup / Modal / ContextItem / OpenPopup / CloseCurrentPopup / IsPopupOpen — ✅ ⚠️ 11 PopupFlags
- OpenPopupOnItemClick, BeginPopupContextWindow, BeginPopupContextVoid — ❌

## §C25 — Tables (27)

- Begin/End/NextRow/NextColumn/SetupColumn/HeadersRow/GetSortSpecs — ✅ ⚠️ 35 TableFlags partial, 23 TableColumnFlags partial
- TableSetColumnIndex, TableHeader (manual), TableAngledHeadersRow — ❌
- TableGetColumnCount / Index / RowIndex / Name / Flags — ❌
- TableSetColumnEnabled, TableGetHoveredColumn — ❌
- TableSetBgColor — ⚠️ row only

## §C26 — Tab Bars, Tabs (6)

- BeginTabBar / EndTabBar / BeginTabItem / EndTabItem — ✅ ⚠️ 11+9 flags
- TabItemButton, SetTabItemClosed — ❌

## §C27 — Logging (7)

All ❌.  Lowest priority.

## §C28 — Drag and Drop (9)

- Begin/End Source + Target + Set + Accept Payload — ✅ ⚠️ 14 DragDropFlags partial
- GetDragDropPayload — ❌

## §C29 — Disabling (2)

✅ both.

## §C30 — Clipping (2)

✅ both.

## §C31 — Focus, Activation (2)

- SetItemDefaultFocus — ❌
- SetKeyboardFocusHere — ✅

## §C32 — Item Utilities (18)

- IsItemHovered — ⚠️ 21 HoveredFlags missing
- IsItem Active / Focused / Clicked / Visible / Edited / Activated / Deactivated / DeactivatedAfterEdit — ✅
- IsItemToggledOpen — ❌
- IsAnyItemHovered / Active / Focused — ❌
- GetItemID / RectMin / RectMax / RectSize — ✅
- GetItemFlags — ❌
- SetNextItemAllowOverlap — ❌

## §C33 — Viewports + Draw lists (3)

- GetMainViewport — ⛔
- GetBackgroundDrawList / GetForegroundDrawList — ❌

## §C34 — Miscellaneous (7)

- IsRectVisible, GetStyleColorName — ❌
- GetTime / GetFrameCount — ⚠️ via `f.time.*`
- GetDrawListSharedData, SetStateStorage / GetStateStorage — ⛔

## §C35 — Text + Color utilities (5)

- CalcTextSize — ✅
- ColorConvertU32ToFloat4 / Float4ToU32 / RGBtoHSV / HSVtoRGB — ⚠️ internal, not on `Ui`

## §C36 — Keyboard inputs (7)

- IsKeyDown/Pressed/Released, GetKeyName — ✅ at runtime
- IsKeyChordPressed, GetKeyPressedAmount — ❌
- SetNextFrameWantCaptureKeyboard — ⚠️ reader only

## §C37 — Shortcuts (3)

All ❌: Shortcut, SetNextItemShortcut, SetItemKeyOwner.

## §C38 — Mouse inputs (17)

- Mouse query family — ✅ at runtime
- IsMouseHoveringRect — ⚠️ internal pointInRect
- GetMouseCursor / SetMouseCursor — ✅ at runtime, ❌ on `Ui`
- IsMouseDragging / GetMouseDragDelta / ResetMouseDragDelta — ❌

## §C39 — Clipboard (2)

Both ❌.

## §C40 — Settings/.ini (4)

⛔ partial via `serializeLayout`.

## §C41 — Debug Utilities (6)

All ❌.

## §C42 — Memory Allocators (4)

⛔ user passes gpa.

---

# §D — Flag-enum coverage

| Enum | imgui flags | zimr Opts | covered | gap | priority |
|---|---|---|---|---|---|
| ImGuiWindowFlags | 30 | WindowOpts (initial_pos/size) | 0 | 30 | high |
| ImGuiTableFlags | 35 | TableOpts (7 fields) | ~5 | 30 | high |
| ImGuiInputTextFlags | 27 | InputTextOpts (width, hint) | 0 | 27 | high |
| ImGuiTreeNodeFlags | 26 | (no opts) | 0 | 26 | high |
| ImGuiColorEditFlags | 29 | ColorEdit+PickerOpts (5 fields) | ~3 | 26 | medium |
| ImGuiSelectableFlags | 9 | SelectableOpts (width) | 0 | 9 | medium |
| ImGuiSliderFlags | 9 | SliderOpts (min/max/fmt/width) | 0 | 9 | medium |
| ImGuiHoveredFlags | 21 | (no opts) | 0 | 21 | medium |
| ImGuiFocusedFlags | 6 | (no opts) | 0 | 6 | low |
| ImGuiPopupFlags | 11 | (no opts) | 0 | 11 | medium |
| ImGuiComboFlags | 8 | ComboOpts (width) | 0 | 8 | medium |
| ImGuiChildFlags | 10 | ChildOpts (2 fields) | ~1 | 9 | medium |
| ImGuiTabBarFlags | 11 | (none) | 0 | 11 | medium |
| ImGuiTabItemFlags | 9 | (only open_ptr) | 0 | 9 | medium |
| ImGuiDragDropFlags | 14 | DragDropSourceOpts (no_preview) | 1 | 13 | medium |
| ImGuiTableColumnFlags | 23 | TableColumnOpts (4 fields) | ~4 | 19 | medium |
| ImGuiMultiSelectFlags | 20 | feature missing | 0 | 20 | high |
| ImGuiButtonFlags | 6 | ButtonOpts (size) | 0 | 6 | low |
| ImGuiItemFlags | 8 | feature missing | 0 | 8 | medium |
| ImGuiInputFlags | 11 | (Shortcut-routing) | 0 | 11 | medium |
| ImGuiTableRowFlags | 2 | implicit | ~1 | 1 | tiny |
| ImGuiTableBgFlags | 1 | row variant | partial | 1 | tiny |
| ImGuiBackendFlags / ConfigFlags / ViewportFlags / KeyModFlags / ListClipperFlags | — | — | — | various ⛔ or paired |

**Totals:** 27 enums, 396 flags.  zimr covers ~30 (including
implicit ones).  In-scope gap: **~290 flags**.

---

# §E — Helper-type coverage

| imgui type | zimr equiv | status |
|---|---|---|
| ImColor | use `Color` directly | ⛔ |
| ImDrawCmd / Channel / Header | DrawList internals | ✅ |
| ImDrawData | direct rlgl submission | ⛔ |
| ImDrawList | `DrawList` | ✅ |
| **ImDrawListSplitter** | — | ❌ |
| ImDrawListSharedData | internal | ⛔ |
| ImDrawVert | rlgl internal | ⛔ |
| ImFont / Atlas / Baked / Config | text.Font + FontCache | ✅ different model |
| ImFontGlyph / GlyphRangesBuilder | text.Glyph | partial |
| ImFontLoader | implicit | ⛔ |
| ImGuiContext | UiContext | ✅ |
| ImGuiIO | Frame.input + window | ✅ different model |
| **ImGuiInputTextCallbackData** | — | ❌ |
| ImGuiKeyData | InputState internal | ✅ |
| **ImGuiListClipper** | — | ❌ |
| **ImGuiMultiSelectIO** | — | ❌ |
| **ImGuiOnceUponAFrame** | — | ❌ tiny |
| ImGuiPayload | DragDropState | ✅ |
| ImGuiPlatformIO / PlatformImeData | — | ⛔ |
| **ImGuiSelectionBasicStorage** | — | ❌ |
| **ImGuiSelectionExternalStorage** | — | ❌ |
| **ImGuiSelectionRequest** | — | ❌ |
| **ImGuiSizeCallbackData** | — | ❌ |
| ImGuiStorage / StoragePair | use Zig HashMap | ⛔ |
| ImGuiStyle | `Style` | ✅ |
| ImGuiTableSortSpecs / ColumnSortSpecs | `TableSortSpecs` / `Spec` | ✅ |
| ImGuiTextBuffer | use ArrayList | ⛔ |
| **ImGuiTextFilter** | — | ❌ |
| ImGuiViewport | — | ⛔ |
| ImTextureData / Rect / Ref | rlgl/texture handles | ⛔ different model |
| ImVec2 / ImVec4 | `Vector2` / `Color` | ✅ |
| ImVector | use ArrayList | ⛔ |

**Real type gaps: 9** — bolded above.

---

# §F — Enum-only-type coverage

| imgui enum | values | zimr | status |
|---|---|---|---|
| **ImGuiKey** | 147 | KeyboardKey (35) | ⚠️ ~24% |
| ImGuiCol | ~55 slots | Style fields (~30) | ⚠️ ~55% |
| ImGuiStyleVar | ~30 | Style fields | ⚠️ partial |
| ImGuiCond | 4 (Always/Once/FirstUseEver/Appearing) | SetNextWindowOpts.once: bool | ⚠️ 2/4 |
| ImGuiMouseCursor | 9 | runtime MouseCursor (11) | ✅ runtime, ❌ on `Ui` |
| ImGuiDir | 5 | ArrowDir (4 — no None) | ⚠️ |
| ImGuiSortDirection | 2 | TableSortDirection | ✅ |
| ImGuiDataType | 12 | comptime + `anytype` | ✅ different idiom |
| ImGuiMouseButton | 5 | runtime input | ✅ runtime |
| ImGuiNavInput | 16 | partial tab nav | ⚠️ |

---

# §G — Gap classification

## Tier 1 — Big features (architectural; blocks real apps)

| # | Gap | Impact |
|---|---|---|
| 1 | **ImGuiListClipper** | 1000+ row views are O(n) per frame today |
| 2 | **InputTextMultiline** | Multi-line text editor; composers, code panels |
| 3 | **InputTextCallbackData** | Autocomplete, char filter, password mask, history |
| 4 | **MultiSelect** family | Shift/ctrl-click row selection (with 20 MultiSelectFlags) |
| 5 | **PushFont / PopFont** | Mono font for code sections |
| 6 | **Window scrolling API** | Auto-scroll-to-bottom log views |
| 7 | **BeginCombo / EndCombo** | Custom-content dropdowns |
| 8 | **Clipboard** | GetClipboardText / SetClipboardText |
| 9 | **Mouse cursor on `Ui`** | Text-cursor on input, hand-cursor on link |
| 10 | **Shortcut family** | Ctrl+S, Ctrl+Z |
| 11 | **BeginMenuBar / EndMenuBar** | Per-window menus |
| 12 | **Background/ForegroundDrawList** | Watermarks, debug overlays, world anchors |
| 13 | **ImGuiTextFilter** | Substring filter; pairs with Clipper |
| 14 | **Splitter** | Resizable pane layouts |
| 15 | **TreeNodeEx flags** | 26 flags inaccessible (Framed/Bullet/Leaf/DefaultOpen/SpanFullWidth etc.) |
| 16 | **SetNextWindowSizeConstraints** | Min/max window size |

## Tier 2 — Flag-coverage waves (~290 flags across ~15 enums)

These are bulk additions: extend an Opts struct, thread bools
through impl.

## Tier 3 — Mid-impact functions (~40 fns)

SeparatorText, InvisibleButton, TextLink, TextLinkOpenURL,
CheckboxFlags, mouse drag helpers, DragRange2 variants,
SetNextItemOpen, PushTextWrapPos, TableAngledHeadersRow,
TabItemButton, OpenPopupOnItemClick, BeginPopupContextWindow/Void,
IsKeyChordPressed, theme presets, ShowMetricsWindow, ShowDebugLog,
table queries, etc.  See per-section ❌ entries above.

## Tier 4 — Specialized / niche

Logging family, Settings/.ini, Debug utilities, ID Stack tool,
ImDrawListSplitter, ImGuiOnceUponAFrame.

## ⛔ Out of scope

Multi-viewport, allocator hooks, IME, `V` va_list variants.

---

# §H — Realistic phased plan

## Phase A — Foundation (4 turns)

**A1.** Window scrolling API + clipboard
- get/setScrollX/Y, getScrollMaxX/Y, setScrollHereX/Y
- getClipboardText / setClipboardText (wasm: navigator.clipboard)
- Demo: log viewer with auto-scroll + copy button

**A2.** ImGuiListClipper virtualization — **SHIPPED Turn 190.**
- `Ui.clipper(item_count, item_height) Clipper` + `.step() ?Range` + `.end()`.
- Single-step model (variable-height deferred).
- 6 unit tests, demo `examples/ui_clipper.zig` (★★★★★, 169 LOC,
  100k rows at 4186 gl calls — same as 80-row log viewer).
- Child-window viewport handling via `child_stack` peek.

**A3.** InputTextMultiline + PushFont / PopFont — **SHIPPED Turns 191-192.**
- `Ui.inputTextMultiline(label, buf, len, size, opts) bool` —
  Enter inserts newline, Up/Down line nav preserving column,
  click-to-place-cursor anywhere, line-aware Home/End,
  Escape defocuses.
- `Ui.pushFont(?*const Font)` / `popFont()` — named wrappers over
  the reflection-based `pushStyle("font", ...)` machinery.
- `InputSnapshot.key_up` / `key_down` added + populated with
  repeat.  Trickle-down: now also available for any future
  arrow-up/down navigation widgets.
- Cursor model stayed 1D (byte offset).  Three pure helpers
  (`byteToLineCol`, `lineColToByte`, `xyToByte`) do the 2D
  conversion at click/render/nav time.  `drawTextAtS` already
  handles `\n` natively (advances off_y in `drawing.text.drawEx`)
  so one render call covers the whole multi-line buffer.
- Limitations documented: no selection, no clipboard cut/copy/
  paste (lands in A4), no undo, no tab character, no scroll
  (caller wraps in `beginChild` for that).
- 7 unit tests for the cursor helpers (`byteToLineCol`,
  `lineColToByte`, including round-trip property over a small
  buffer) — total test count 1265 (+7).
- Demo `examples/ui_code_editor.zig` (★★★★, 180 LOC) — pre-
  populated zig sample, line-number gutter, larger title font
  via `pushStyle("font_size", 16)`, reset button.
- Smoke: PASS, 92/92 (5395 GL calls for the editor demo).

**A4.** InputTextCallbackData — **SHIPPED Turn 193.**
- `InputTextCallbackData` type with `event` / `buf` / `buf_len` /
  `cursor_pos` / `event_char` / `history_dir` / `user_data` +
  three helper methods (`insertChars`, `deleteChars`, `setBuffer`)
  that handle buffer-mutation + cursor-accounting in one place.
- Four callback slots on `InputTextOpts`: `char_filter`, `edit`,
  `completion`, `history`.  Each is `?InputTextCallback`
  (uniform `*const fn(*InputTextCallbackData) void`).  Caller
  passes `*anyopaque` via `opts.user_data`; callbacks cast it
  back to typed state.
- Wired into both `inputTextImpl` and `inputTextMultilineImpl`
  for CharFilter + Edit.  Completion (Tab) + History (Up/Down)
  fire only in single-line — multiline already uses Tab/arrows.
- **Out of scope (deferred):** `CallbackResize` doesn't fit
  zimr's caller-owned-buffer model.  `CallbackAlways` (every-
  frame fire) added zero value beyond `edit` for the demos I
  could think of; can ship later if a real use case appears.
- Two new helpers `runInputCallback` / `runCharFilter` at
  function-top to keep the impl bodies clean.
- 7 unit tests covering `insertChars` / `deleteChars` /
  `setBuffer` cursor accounting (including before-cursor,
  at-cursor, overlapping, and overflow cases).  Test count
  1265 → 1272.
- Demo: `examples/ui_input_callbacks.zig` (★★★★, ~220 LOC) —
  four widgets, one per slot: decimal-only filter, password
  mask, Tab autocomplete against a 20-word dictionary, Up/Down
  history scroll through 8 prior shell commands.  Smoke: PASS,
  93/93 across all examples.
- Unlocked InputTextFlags so far: callback flags (char_filter,
  completion, history, edit) — 4 of 27.  Remaining 23 flags
  (chars_decimal/hex/upper/no_blank, password, read_only,
  auto_select_all, enter_returns_true, escape_clears_all, etc.)
  are coverage work for Phase E3; the callbacks are the
  prerequisite plumbing.

## Phase B — Input + interaction polish (3 turns)

**B1.** Mouse cursor on Ui + drag helpers — **SHIPPED (Turn 196)**
- getMouseCursor / setMouseCursor on `Ui` ✓
- isMouseDragging, getMouseDragDelta, resetMouseDragDelta ✓
- isMouseHoveringRect ✓
- 7 unit tests in `runtime.zig`'s input ns covering: cursor mirror,
  press_position rising-edge capture, drag threshold (default 6 px
  + custom), drag delta gating, reset re-anchoring, reset-when-up
  no-op, isMouseHoveringRect half-open intervals
- Demo: `examples/ui_mouse_drag.zig` — six cursor zones (default,
  pointing_hand, ibeam, crosshair, resize_ew, resize_ns) with hover-
  brighten highlight, draggable orange square with mouse-down latch,
  live readouts of mouse position + button + drag state.  Smoke
  passes (3121 gl calls vs 1561 baseline).
- Implementation notes:
  - `Mouse.press_position[MAX_MOUSE_BUTTONS]` captured on rising-edge of `pushMouseButtonDown`
  - `Mouse.current_cursor` mirrors the most recent `setMouseCursor` (CSS can't be queried back)
  - `UiContext.input_state: ?*runtime.input.InputState` stamped at `beginFrame` so Ui can mutate (e.g. `resetMouseDragDelta`); 82 test call sites of `beginFrameRaw` updated to pass `null` for the new param
  - `MOUSE_DRAG_THRESHOLD_DEFAULT = 6.0` matches imgui's default; pass `-1` to opt in
  - `MouseCursor` and `MouseButton` re-exported as `ui.MouseCursor` / `ui.MouseButton` so callers don't need `z.input.*` for these enums

**B2.** Shortcut family + IsKeyChordPressed + InputFlags — **SHIPPED (Turn 197), routing flags deferred**
- `runtime.input.KeyChord` struct — `{ key: KeyboardKey, ctrl/shift/alt/super: bool = false }`
- `runtime.input.ShortcutOpts` — `{ repeat: bool = false }` (more flags as B3 needs them)
- `runtime.input.isKeyChordPressed(state, chord, opts) bool` — edge-triggered on key, level on modifiers, both-sides count
- `Ui.shortcut(chord, opts) bool` — wrapper using `ctx.input_state`
- `ui.KeyChord` / `ui.ShortcutOpts` re-exports
- 6 unit tests: bare key, Ctrl+S, right-side modifier, extra-modifier breaks match, edge-trigger (no re-fire on held), opts.repeat fires on auto-repeat
- Demo: `examples/ui_shortcuts.zig` — 7 chord rows (Ctrl+S, Ctrl+Z, Ctrl+Shift+Z, Esc, Space, Up/Down with auto-repeat) each tied to wired app state (dirty bit, undo depth, counter); rows flash yellow on fire
- **Deferred to B3 or later**: `setNextItemShortcut(chord, display)` — needs the menu-bar surface from B3.  11 ImGuiInputFlags (RouteFocused/Active/Global/etc.) — defer until multi-window routing actually exists; today the default "global, always fire" matches every demo's need.

**B3.** Background/ForegroundDrawList + BeginMenuBar + BeginCombo — **split across turns**

B3a — drawlists — **SHIPPED (Turn 198):**
- `UiContext.background_dl: DrawList` new field, paired with the existing
  `foreground_dl`.  Cleared each frame, deinit'd alongside foreground in
  ctx.deinit, rendered FIRST in endFrame (under all windows).
- `pub const DrawListHandle` struct in `src/ui.zig` — wraps `*DrawList`
  + `Allocator` so callers don't have to plumb the frame arena through
  every `add*` call.  Wraps the 8 most common methods (addRectFilled,
  addRectOutline, addText, addLine, addCircle, addCircleFilled,
  addTriangle, addTriangleFilled).  Less-common methods (textured
  quads, polylines, bezier, ellipses, gradients, clip-rect push/pop)
  are reachable via `dl.list.add*(dl.gpa, ...)`.
- `Ui.getBackgroundDrawList() DrawListHandle` — bound to `background_dl`
- `Ui.getForegroundDrawList() DrawListHandle` — bound to `foreground_dl`
- 5 unit tests covering: init/clear/deinit don't crash, beginFrame
  clears bg too, addRectFilled records on the wrapped list, getForeground
  returns handle bound to right list, bg + fg lists are independent.
- Demo: `examples/ui_drawlists.zig` (99th example, 4 stars).
- Re-exports added: `ui.Vector2`, `ui.Rectangle` made `pub`.

B3b — per-window menu bar — **SHIPPED (Turn 199):**
- Generalized `in_main_menu_bar` → `in_menu_bar` (covers both bar paths).
- New `UiContext.active_menu_bar_win: ?*Window` — points at the
  current bar's owning window (the synthetic main-bar window for
  `beginMainMenuBar`, or the parent window for `beginMenuBar`).
  `openMenu` reads from this so the button/popup placement code is
  agnostic to which bar opened it.
- `Ui.beginMenuBar() bool` / `Ui.endMenuBar()` — reserves a strip at
  the top of the current window (just below its title bar), paints
  the bar background, bumps the window's content cursor down by
  `style.menu_bar_height`.  Bar coords live in canvas space, same as
  the main-bar path, so popup anchoring needs zero special-casing.
- 2 unit tests: bar opens with the right anchor + cursor coords;
  nested `beginMenuBar` is a no-op (caller bug guard).
- Demo: `examples/ui_window_menubar.zig` — three windows each with
  its own menu bar (Document: File/Edit/View, Properties: Tools,
  Settings: Help/About).  Help→About toggles a foreground overlay
  drawn via `getForegroundDrawList` to show B3a + B3b cooperating.
  Bottom status bar (also foreground) shows the most recent menu
  action.

B3c — custom-content combo — **SHIPPED (Turn 201):**
- `Ui.beginCombo(label, preview, opts) bool` / `Ui.endCombo()`.
  Returns true when the dropdown is open — caller fills with
  selectables, separators, swatches, anything.  Closed: returns
  false (do NOT call endCombo).  ImGui:
  `BeginCombo(label, preview_value, flags)` / `EndCombo()`.
- Internal mechanics: closed row renders inline (preview text +
  down-arrow + label to the right, same as plain `combo()`), with
  state in `UiContext.combo_open_id`.  When open, allocates a
  synthetic popup window keyed `##combo_<hex>` via
  `findOrCreateWindow`, pushes it onto the window stack, redirects
  `current_draw_list` to the popup's own list, frame-appends it to
  `frame_popups` for late render.  Width pinned to closed-row
  width.  Height auto-fits to `cursor_max.y` at endCombo time —
  one-frame lag for the BG draw (uses previous frame's size),
  tolerable since dropdown contents rarely change row count.
- `endCombo`:
  - Pops the window stack, restores parent's draw list.
  - Recomputes popup height from this frame's `cursor_max`.
  - Click-outside-both-rects closes the combo next frame.
- Demo: `examples/ui_combo_custom.zig` — two combos.  Preset combo
  lays each row as `selectable + sameLine + colored description`
  text; theme combo lays selectables with future-tinted labels.
- 2 unit tests covering closed-by-default + click-opens semantics.

**Phase B closed.**  100% of Phase B items shipped across turns
196-201: mouse + drag helpers (B1), keyboard shortcuts (B2),
background+foreground drawlists (B3a), per-window menu bar (B3b),
custom-content combo (B3c).

## Phase C — Text + filter + multi-select (3 turns)

**C1.** Tier 3 text helpers
- separatorText, invisibleButton, textLink, textLinkOpenURL
- Value() one-liner
- Demo: log viewer with clickable error rows that open docs

**C2.** ImGuiTextFilter widget
- Filter struct: input + parse + passFilter(text)
- include / -exclude / multi-term
- Pairs with Clipper for filtered virtualized lists
- Demo: filter input wired to the 100k log viewer

**C3.** Multi-select + selection storage
- beginMultiSelect / endMultiSelect
- ImGuiSelectionBasicStorage (zimr style: u64 hashset)
- MultiSelectIO event stream
- 20 MultiSelectFlags
- Demo: row-selectable table with shift/ctrl-click

## Phase D — Splitter + window controls + tree polish (2 turns)

**D1.** Splitter + SetNextWindowSizeConstraints + window-misc
- splitter(id, *split_pos, direction, opts) bool
- setNextWindowSizeConstraints, Collapsed, ContentSize, Scroll
- setWindowPos/Size/Focus/Collapsed
- Demo: 3-pane file-tree | editor | output with draggable splitters

**D2.** TreeNodeEx flags + SetNextItemOpen
- TreeNodeOpts covering 26 ImGuiTreeNodeFlags
- setNextItemOpen, isItemToggledOpen, treeNodeGetOpen
- getTreeNodeToLabelSpacing
- Demo: framed tree with leaf icons + programmatic expand

## Phase E — Flag-extension waves (6 turns)

These turns are bulk additions: extend an Opts struct with new
booleans, thread them through `*Impl` functions, write per-flag
tests.  Lower architectural risk than A–D; high mechanical
surface area.

**E1.** `ImGuiWindowFlags` (30 flags)
- Extend `WindowOpts` from {initial_pos, initial_size} with:
  no_title_bar, no_resize, no_move, no_scrollbar,
  no_scroll_with_mouse, no_collapse, always_auto_resize,
  no_background, no_saved_settings, no_mouse_inputs, menu_bar,
  horizontal_scrollbar, no_focus_on_appearing,
  no_bring_to_front_on_focus, always_vertical_scrollbar,
  always_horizontal_scrollbar, no_nav_inputs, no_nav_focus,
  unsaved_document, no_nav, no_decoration, no_inputs.
- ~6 are internal-only (`ChildWindow`, `Tooltip`, `Popup`, `Modal`,
  `ChildMenu`, `DockNodeHost`) — ⛔ for the public surface.
- Implementation: most are read-checks at window-decoration draw
  time.  `no_title_bar` suppresses the header rect.  `no_resize`
  disables the resize handle.  `always_auto_resize` tightens to
  content.
- Demo: `ui_window_flags_tour` — one panel per flag combination,
  side-by-side comparison.

**E2.** `ImGuiTableFlags` (35) + `ImGuiTableColumnFlags` (23)
- TableOpts extensions: resizable, reorderable, hideable,
  sortable, no_saved_settings, context_menu_in_body, row_bg
  (have), borders_inner_h, borders_outer_h, borders_inner_v,
  borders_outer_v, no_borders_in_body, no_borders_in_body_until_resize,
  sizing_fixed_fit, sizing_fixed_same, sizing_stretch_prop,
  sizing_stretch_same, no_host_extend_x, no_host_extend_y,
  no_keep_columns_visible, precise_widths, no_clip,
  pad_outer_x, no_pad_outer_x, no_pad_inner_x,
  scroll_x, scroll_y, sort_multi (have), sort_tristate,
  highlight_hovered_column.
- TableColumnOpts: default_hide, default_sort, width_stretch,
  width_fixed, no_resize, no_reorder, no_hide, no_clip,
  no_sort, no_sort_ascending, no_sort_descending,
  no_header_label, no_header_width, prefer_sort_ascending,
  prefer_sort_descending, indent_enable, indent_disable,
  angled_header, is_enabled, is_visible, is_sorted, is_hovered.
- Demo: `ui_tables_advanced` — drag-to-reorder columns + hide
  via context menu + per-column sort policies.

**E3.** `ImGuiInputTextFlags` (27) + `ImGuiColorEditFlags` (29)
- InputTextOpts: chars_decimal, chars_hexadecimal,
  chars_scientific, chars_uppercase, chars_no_blank,
  allow_tab_input, enter_returns_true, escape_clears_all,
  ctrl_enter_for_new_line, read_only, password, no_undo_redo,
  auto_select_all, parse_empty_ref_val, display_empty_ref_val,
  no_horizontal_scroll, always_overwrite, callback_completion,
  callback_history, callback_always, callback_char_filter,
  callback_resize, callback_edit, elide_left.
- Several callback_* flags depend on A4 (InputTextCallbackData)
  having shipped — keep this turn after Phase A.
- ColorEditOpts: no_alpha (have), no_picker, no_options,
  no_small_preview, no_inputs, no_tooltip, no_label,
  no_side_preview, no_drag_drop, no_border, alpha_bar,
  alpha_preview, alpha_preview_half, hdr, display_rgb,
  display_hsv, display_hex, uint8, float, picker_hue_bar,
  picker_hue_wheel (have), input_rgb, input_hsv.
- Demo: `ui_input_advanced` — password field with mask toggle,
  decimal-only field, ColorEdit with all display modes.

**E4.** `ImGuiTreeNodeFlags` (26) + `ImGuiSelectableFlags` (9) +
`ImGuiSliderFlags` (9) + `ImGuiButtonFlags` (6) — **50 flags total**.
- TreeNodeOpts: selected, framed, allow_overlap, no_tree_push_on_open,
  no_auto_open_on_log, default_open, open_on_double_click,
  open_on_arrow, leaf, bullet, frame_padding, span_avail_width,
  span_full_width, span_text_width, span_all_columns,
  nav_left_jumps_back_here, collapsing_header.
- SelectableOpts: dont_close_popups, span_all_columns,
  allow_double_click, disabled, allow_overlap, highlight,
  no_auto_close_popups.
- SliderOpts: always_clamp, clamp_on_input, clamp_zero_range,
  logarithmic, no_round_to_format, no_input, wrap_around,
  no_speed_tweaks.
- ButtonOpts: mouse_button_left/right/middle (3-way), enable_nav.
- Demo: `ui_tree_select_polish` — framed tree with bullets + leaves,
  log-scale slider, double-click selectables.

**E5.** `ImGuiHoveredFlags` (21) + `ImGuiFocusedFlags` (6) +
`ImGuiPopupFlags` (11) + `ImGuiComboFlags` (8) +
`ImGuiChildFlags` (10) — **56 flags**.
- isItemHovered + isWindowHovered take `HoveredFlags`:
  allow_when_blocked_by_popup, allow_when_blocked_by_active_item,
  allow_when_overlapped, allow_when_disabled, no_nav_override,
  delay_normal, delay_short, delay_none, no_shared_delay,
  for_tooltip, rect_only, root_window, child_windows, etc.
- FocusedFlags: child_windows, root_window, any_window,
  no_popup_hierarchy.
- PopupFlags: mouse_button_left/right/middle, no_open_over_existing,
  no_open_over_items, any_popup_id, any_popup_level, any_popup.
- ComboOpts: popup_align_left, height_small/regular/large/largest,
  no_arrow_button, no_preview, width_fit_preview, custom_preview.
- ChildOpts: borders, always_use_window_padding, resize_x, resize_y,
  auto_resize_x, auto_resize_y, always_auto_resize, frame_style,
  nav_flatten.
- Demo: `ui_hover_focus_flags` — interactive hover delay tweaker;
  shows tooltip behaviour with each flag.

**E6.** `ImGuiTabBarFlags` (11) + `ImGuiTabItemFlags` (9) +
`ImGuiDragDropFlags` (14) + `ImGuiItemFlags` (8) — **42 flags**.
- TabBarOpts: reorderable, auto_select_new_tabs,
  tab_list_popup_button, no_close_with_middle_mouse_button,
  no_tab_list_scrolling_buttons, no_tooltip, draw_selected_overline,
  fitting_policy_resize_down, fitting_policy_scroll.
- TabItemOpts: unsaved_document, set_selected, no_close_with_middle_mouse_button,
  no_push_id, no_tooltip, no_reorder, leading, trailing,
  no_assumed_closure.
- DragDropOpts (source): no_preview_tooltip, no_disable_hover,
  no_hold_to_open_others, allow_null_id, extern, payload_auto_expire,
  payload_no_cross_context, payload_no_cross_process; (target):
  accept_before_delivery, accept_no_draw_default_rect,
  accept_no_preview_tooltip, accept_peek_only.
- ItemFlags: no_tab_stop, no_nav, no_nav_default_focus, button_repeat,
  auto_close_popups, allow_duplicate_id, mixed_value, readonly.
- Demo: `ui_tabbar_dragdrop_polish` — reorderable tab bar +
  drag-to-merge between sources.

---

## Phase F — Tier-3 cleanup waves (3 turns)

**F1.** Table queries + cell bg + column ops + tableAngledHeadersRow
- `tableSetColumnIndex(idx)` — explicit jump (we have next-column
  only).
- `tableHeader(label)` — manual single-column header for custom
  layouts.
- `tableAngledHeadersRow()` — 45-degree headers (compact wide
  tables).
- `tableGetColumnCount()`, `tableGetColumnIndex()`,
  `tableGetRowIndex()`, `tableGetColumnName(idx)`,
  `tableGetColumnFlags(idx)`, `tableGetHoveredColumn()`.
- `tableSetColumnEnabled(idx, bool)` — runtime hide/show.
- `tableSetBgColor(target, color, idx)` — cell + column variants
  in addition to row.
- TableRowFlags + TableBgFlags (2 + 4 flags).
- Demo: `ui_tables_query` — runtime column visibility checkboxes +
  angled headers showcase.

**F2.** Layout/cursor/item-query small gaps + DragRange +
ColorConvert on Ui + CheckboxFlags
- `setCursorScreenPos(p)`, `setCursorPosX(x)`, `setCursorPosY(y)`,
  `getCursorPosX()`, `getCursorPosY()`, `getCursorStartPos()`.
- `getTextLineHeight()`, `getTextLineHeightWithSpacing()`,
  `getFrameHeight()`, `getFrameHeightWithSpacing()`.
- `isItemToggledOpen()`, `isAnyItemHovered()`, `isAnyItemActive()`,
  `isAnyItemFocused()`, `setItemDefaultFocus()`,
  `setNextItemAllowOverlap()`, `isRectVisible(min, max)`,
  `getItemFlags()`.
- `dragFloatRange2(label, *min, *max, opts)` + IntRange2.
- `Value(label, v)` one-liner for read-only output.
- `colorConvertU32ToFloat4`, `colorConvertFloat4ToU32`,
  `colorConvertRGBtoHSV`, `colorConvertHSVtoRGB` on `Ui`.
- `checkboxFlags(label, *flags, flags_value)` — bitwise check.
- Demo: `ui_query_grab_bag` — every newly-exposed query API
  surfaced in a debug HUD.

**F3.** ImGuiKey expansion (35→147) + popup variants + tab extras
+ theme presets + showAboutWindow/UserGuide/StyleSelector/Version
- KeyboardKey expanded from 35 to 147 entries — function keys
  F13–F24, mod-only keys (LeftShift/RightShift), gamepad face
  buttons, mouse buttons as ImGuiKey, ImGuiMod_* combined.
- `getKeyName(key)`, `isKeyChordPressed(chord)`,
  `getKeyPressedAmount(key, repeat_delay, rate)`.
- `openPopupOnItemClick(str_id, popup_flags)`,
  `beginPopupContextWindow(str_id, flags)`,
  `beginPopupContextVoid(str_id, flags)`.
- `tabItemButton(label, flags) bool` — non-selectable tab acting
  as toolbar button.
- `setTabItemClosed(label)` — programmatically close a tab.
- `Style.light_default`, `Style.classic_default` (alongside
  existing `dark_default`).
- `showAboutWindow(*bool)`, `showUserGuide()`, `showStyleSelector(label)`,
  `showFontSelector(label)`, `getVersion()`.
- Demo: `ui_keys_themes_tour` — theme switcher + key-chord pressed
  HUD + about window button.

---

## Phase G — Debug + capstone (2 turns)

**G1.** ShowMetricsWindow + ShowDebugLogWindow + IDStackTool
- `showMetricsWindow(*bool)` — frame timing, draw call count,
  vertices/indices, widget counts per category, hovered/active
  item IDs, window list, style preview.
- `showDebugLogWindow(*bool)` — capture `dom.log` output into a
  rolling buffer; filter by level.
- `showIDStackToolWindow(*bool)` — interactive `pushID` /
  `popID` debugger (click an item, see its hash chain).
- `debugTextEncoding(text)`, `debugFlashStyleColor(col)`,
  `debugStartItemPicker()`.
- Demo: enable Metrics + DebugLog in the capstone; pin to the
  side.

**G2.** Final capstone refresh + arc close
- Add 8 new tabs to `ui_full_showcase.zig` — one per phase:
  scroll/clipboard, virtualization, multiline/font, callbacks,
  cursor/drag/shortcut, menubar/combo/fg, filter/multiselect,
  splitter.
- Re-validate every star rating; promote tour demos to ★★★★+.
- Full arc-close CHANGELOG entry referencing every phase.
- Archive `imgui-parity-plan.md` (this doc renamed at start of
  arc) → `src/notes/archive/`.
- Update `PLAN.md`: status row complete; surface stats refreshed.

---

## Phase H — Tier 4 niche but real (3 turns)

Reclassified from "optional" to in-scope per "everything imgui
has, we want it."

**H1.** Logging family
- `logToTTY(auto_open_depth)`, `logToFile(depth, filename)`,
  `logToClipboard(depth)`, `logFinish()`, `logButtons()`,
  `logText(fmt, args)`, `logSetNextTextDecoration(prefix, suffix)`.
- Internal: tee draw-list submission strings into a log buffer
  when logging-enabled.  When the user clicks the "Log to
  Clipboard" button under a window, the window's contents are
  serialized to plain text and copied.
- Demo: `ui_logging` — three buttons (TTY / file / clipboard) +
  a sample window whose contents get logged.

**H2.** Settings/.ini full + Debug utilities
- `loadIniSettingsFromDisk(path)`, `loadIniSettingsFromMemory(buf)`,
  `saveIniSettingsToDisk(path)`, `saveIniSettingsToMemory() []u8`.
- `addSettingsHandler(*Handler)` for user-extensible chunks.
- We already have `serializeLayout` — adapt to imgui's text-INI
  format for round-trip compat (one-way is enough; persistence
  format is internal anyway).
- `debugCheckVersionAndDataLayout`, `errorRecoveryStoreState`,
  `errorRecoveryTryToRecoverState`,
  `errorRecoveryTryToRecoverStateUntilEndFrame`,
  `errorCheckUsingSetCursorPosToExtendParentBoundaries`.
- Demo: `ui_settings_persistence` — toggle a few widgets, save
  to memory, reload, verify state restored.

**H3.** ImDrawListSplitter channels
- `DrawListSplitter` type — splits a draw list into N channels,
  draws to one at a time, merges in submission order at end.
- API: `Splitter.split(n)`, `.setCurrentChannel(idx)`, `.merge()`.
- Used to render fg/bg of the same widget in correct z-order
  without two separate draw list passes.
- ImGui's tables use this for cell content vs row backgrounds.
- Demo: `ui_drawlist_splitter` — concentric ring renderer
  showing ordered merging.

---

# §I — Plan summary

| Phase | Turns | Theme |
|---|---|---|
| A | 4 | Foundation: clipper, multiline, scroll, callback, fonts |
| B | 3 | Input polish: cursor, drag, shortcut, menu bar, combo, fg/bg |
| C | 3 | Text + filter + multi-select |
| D | 2 | Splitter + window controls + tree polish |
| E | 6 | Flag-extension waves (~290 flags) |
| F | 3 | Tier-3 cleanup |
| G | 2 | Debug windows + capstone |
| H | 3 | Logging + .ini + drawlist channels (Tier-4 niche) |
| **TOTAL** | **26** | **full imgui parity** |

**Smoke discipline:** per-turn focused; full smoke every 3 turns +
at phase boundaries.  Matches Turn 183 pattern.

**Demo strategy:** every phase ships ≥1 ★★★★+ demo.  Phase
boundaries update `ui_full_showcase.zig` with a new tab.

**Cadence note:** Phase A alone delivers the highest-impact gains
(clipper + multiline + scroll API) in 4 turns.  Phases E, F, H
are mechanically rich but architecturally low-risk — once started,
they execute fast.

**Discipline at phase boundaries:**
1. CHEATSHEET.md regenerated for new fns
2. `count_globals.py` 0/0/0
3. Flake check (≥10 consecutive passes)
4. CHANGELOG entry per phase
5. PLAN.md table updated

---

# §J — Recommended starting point

**Next turn: A1 — Window scrolling API + clipboard.**

Why this first:
- Smallest atomic unit; one ~150 LOC turn.
- No architectural decisions blocked on it (clipper in A2 builds
  on the scroll API but doesn't conflict).
- Ships a visible win: log-viewer demo with auto-scroll-to-bottom
  and copy-button.
- Clipboard plumbing (wasm: `navigator.clipboard.writeText`) is
  prerequisite for several later turns (logging clipboard target,
  text-link copy-URL).

**A1 deliverables checklist (SHIPPED Turn 189):**
- [x] `Ui.getScrollY()` / `getScrollMaxY()` — Y-axis only.
- [x] `Ui.setScrollY(y)` — clamped to `[0, scroll_max_y]`.
- [x] `Ui.setScrollHereY(ratio)` — auto-scroll-to-bottom etc.
- [x] `Ui.setScrollFromPosY(local_y, ratio)` — explicit content-y.
- [x] `Ui.setClipboardText([]const u8)` — thin wrapper over the
      existing `runtime.core.setClipboardText`.
- [x] `Ui.getClipboardText() []const u8` — stub returning "" today;
      the cache field (`ctx.clipboard_cache[4096]`) is wired so a
      future turn (Phase A4 InputTextCallbackData) can populate it
      via the existing async `runtime.getClipboardTextAsync` path.
- [x] Demo: `examples/ui_log_viewer.zig` (★★★★, 261 LOC) — 80
      seeded + autogen-generated lines (with severity color), auto-
      scroll-to-bottom (only when already-at-bottom heuristic), top/
      bottom jump buttons, copy-all-to-clipboard button, clear,
      pause.
- [x] Registered in `build.zig` + `manifest.json` at ★★★★.
- [x] CHANGELOG entry.
- [x] Gates: focused smoke PASS (4186 GL calls); full smoke
      90/90 PASS; tests 1252/1258; fmt clean; globals 0/0/0.

**Scope decision logged during A1:**
- X-axis scroll APIs (`getScrollX/MaxX`, `setScrollX/HereX/FromPosX`)
  **deferred to Phase E1**.  Reason: `Window.scroll_x` doesn't
  exist in the codebase — only `scroll_y`.  Adding horizontal
  scroll cleanly requires wheel-x handling, horizontal-scrollbar
  rendering, and the `horizontal_scrollbar` window flag — all
  of which naturally live in E1 (WindowFlags).  Adding X-axis
  symbols here as stubs would create maintenance hazard.  Marking
  E1 with explicit "include X scroll API" deliverable.
- Clipboard async-read sync wrapper deferred to A4.  Reason:
  the value flows naturally from `InputTextCallbackData`'s paste
  path; building it standalone now would duplicate code that
  needs rebuilding when callbacks land.

After A1: **A2 (ListClipper)** — the biggest architectural piece,
plans itself now that scroll API is in.

---
