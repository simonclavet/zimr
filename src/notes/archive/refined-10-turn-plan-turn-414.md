# Refined 10-turn plan + architecture brainstorm — turn 414

This document supersedes the §5 plan in `system-audit-and-finishing-plan-turn-412.md`.

Three things changed since turn 412:
1. Simon redirected away from file-splitting: keep `ui.zig` flat,
   even at 35K lines.  Inline what's currently separate.
2. New directive: be on the lookout for Carmack-style inlining.
   Eliminate small wrappers, eliminate over-abstractions, keep flow
   visible.
3. New aim: zimr is to be a **successor** to imgui, not a port.
   The 10-turn plan should land on that path, not just close the
   parity-with-imgui arc.

This document is the rebalanced plan.

---

## 1. State after turns 413-414

### Code shape
| Metric | Turn 412 | Turn 414 | Δ |
|---|---|---|---|
| `src/*.zig` files | 26 | 24 | -2 (ui_dock + ui_persistence inlined) |
| `src/ui.zig` lines | 31 793 | 35 032 | +3 239 |
| Files in lint scope | 143 | 141 | -2 |
| Tests | 1 685 | 1 687 | +2 (T1.1 row-height fix) |
| `pub fn` in ui.zig | 278 | ~290 (persistence symbols hoisted) | +12 |

The `@This()` self-alias trick kept all internal references
working without churn — `ui_dock_mod.X` and `ui_persistence_mod.X`
inside `ui.zig` continue to read unchanged but now resolve to
this file's own scope.  Two file deletions, zero test regressions,
zero lint regressions.

### Carmack pass — turn 414

Two concrete inlines landed:
- `computeSplitChildSizesPublic` — the alias that existed only
  because the dock layer was once a separate file.  Removed; made
  `computeSplitChildSizes` `pub` directly.
- `autoTilePos` — 6-line single-use helper.  Inlined at the one
  call site with the docstring becoming a comment in the inline
  block.

Both inlines made the flow **more** visible — reader doesn't jump
to another function to see what happens next.

A scan with `python3` found 68 single-use functions in `ui.zig`,
of which 12 are short (≤15 lines) — those are the primary Carmack
targets going forward.  Doing them all in one turn would be
unreviewable; instead, every plan turn should opportunistically
take 1-2 nearby ones while editing.

#### Carmack-scan principles for future turns

1. **Single-use + short body** → inline at call site
2. **Wrapper with stale name** (`X` → `Y` because `Y` used to be
   `XImpl`) → rename the inner, delete the outer
3. **Two functions that always call each other** → merge
4. **Helper named after the call site** (e.g. `processButtonClick`
   called only inside `button`) → inline
5. **Inline DON'T** when the helper:
   - Is called from tests (test code reaches in deliberately)
   - Has a clear independent meaning even if used once today
   - Is recursive or referenced indirectly (function pointer)

---

## 2. zimr as a successor to imgui — architecture brainstorm

What does "successor" mean here?  Three concrete principles:

### 2.1 Keep what's right about imgui
- **Immediate-mode**: state lives with caller; UI is a function
  of state.  No object graph to maintain.
- **Wide widget surface**: every common widget exists.
- **Stateless from caller's POV (mostly)**: minimal lifecycle.

### 2.2 zimr already does better than imgui (don't lose this)
- `AppBridge` instead of `GImGui` global → multi-app coexistence
- Deferred draw lists + splitter → correct z-order without index
  manipulation
- Per-frame style mutation via `u.style()` → no push/pop stack
- Lint asserts (10 active rules, P17 will add more) → shape-of-
  error bugs fail loudly
- `Ui` handle pattern → `u.button(...)` reads better than
  `ImGui::Button(...)`
- Persistence via .zon → not in imgui at all
- Hot-reload-safe → state is `*UiContext`, not global

### 2.3 What zimr can do that imgui structurally CAN'T

This is the part that makes zimr a successor, not a clone.  Each
of these benefits from Zig's comptime + zimr's architecture in
ways C++ imgui can't easily match:

**A. Comptime layout DSL**
Zig can build entire layout trees at comptime.  Imagine:
```zig
u.layout(.{ .stack = .vertical, .gap = 8 }, .{
    .{ .text = "Heading" },
    .{ .row = .{ .gap = 4 }, .children = .{
        .{ .button = .{ .label = "OK", .id = "ok" } },
        .{ .button = .{ .label = "Cancel", .id = "cancel" } },
    }},
});
```
This is a comptime-built tree.  No runtime overhead.  Reads
declaratively.  Currently zimr uses cursor positioning manually
(`u.sameLine()`, `u.dummy()`, etc.) — the DSL would be additive.

**B. First-class touch & gesture model**
Touch input is a second-class citizen in imgui — every
implementation hacks it on top of mouse.  zimr has phone-mode
ambitions; gestures (tap, long-press, swipe, pinch, two-finger-
pan) should be a first-class input modality, recognized at the
UiContext level, dispatched to widgets through the same path as
clicks.

This already half-exists (P3 long-press → right-click synthesis
is in shipped).  The plan: generalize.  `u.onSwipe(.{.direction = .left}, callback)` etc.

**C. Built-in animation primitives**
imgui has nothing first-class for animation.  zimr could ship:
```zig
const fade: f32 = u.animated(.{ .from = 0, .to = 1, .duration = 0.3, .easing = .ease_out });
const spring_x: f32 = u.spring(target_x, .{ .stiffness = 200, .damping = 20 });
```
Per-widget, queryable on the live frame.  SwiftUI-style.

**D. Built-in chart widgets**
imgui has `BeginPlot` only via the external `implot` library.
zimr could ship native `u.lineChart`, `u.barChart`, `u.scatter`
in the standard widget surface, with the same theme system.

**E. Adaptive layout (phone vs desktop)**
```zig
if (u.viewport().is_phone) {
    u.column(...);  // stack vertically on phone
} else {
    u.row(...);     // row on desktop
}
```
or a single `u.adaptive(.{ .narrow = ..., .wide = ... })` widget.
Imgui has nothing.

**F. Accessibility built into the widget API**
Every widget takes an optional `aria_label`, `aria_role`.  Browser
DOM bridge writes them as overlay nodes for screen readers.
Imgui's accessibility story is "you write it yourself, in C, with
no help."  zimr can do better.

**G. State-as-data**
Every widget's state already lives in `UiContext` keyed by ID.
Expose this:
```zig
const click_count: u32 = u.queryState("ok_button", .button).?.click_count;
```
Tests already do this internally.  Make it public.  Useful for
diagnostics, animations, undo/redo.

**H. Reactive bindings**
`u.bind(&state.value, .number_input)` — the widget reads + writes
to a memory location.  Imgui does this manually for every widget;
zimr could make it uniform via a `Bind(T)` type that any input
widget accepts.  Currently each widget has its own pattern.

**I. Comptime widget validation**
P17 plan already calls for this.  Validate at compile time:
- Format strings match args
- Range opts are well-formed (min < max)
- Required IDs are present
- Drag-drop sources have matching accept zones

C++ imgui catches these at runtime if at all.  zimr's comptime
catches at compile time.

**J. Single-shot example pattern**
Every example today is ~150-300 LOC of boilerplate.  The
AppBridge cut some of that.  Could go further with:
```zig
pub var zimr_app = z.simple_app("title", State, .{
    .update = update,
    .phone_layout = phone_update, // optional
});
```
Less ceremony, more visible intent.

### 2.4 What zimr should NOT chase

- **Retained mode for widgets** — that's a different paradigm
  (Flutter, SwiftUI), not a refinement of imgui.  Stay immediate.
- **VDOM / reconciliation** — same.
- **Full HTML+CSS** — out of scope; we're a custom renderer.
- **Heavy theming engine** — the per-frame style mutation pattern
  is already enough.  Don't reinvent CSS.
- **Multi-pass layout** — zimr is intentionally single-pass.  Some
  precision is sacrificed for simplicity.  Stay single-pass.

---

## 3. Refined 10-turn plan

This is the next ten turns concretely.  Each row lists what
ships AND what's left to follow up.  Phone-friendly examples
target half the turns; desktop the other half.  Carmack-pass
opportunities listed per turn — opportunistic, not blocking.

### Turn 415 — finish T1.2 P8.5 scroll flags + clip + horizontal-wheel input

- Land `scroll_x` / `scroll_y` flag fields (started in turn 413)
- Generalize clip-rect push: active when `scroll_x` OR
  `outer_height > 0` (not just outer_height)
- Implement shift+wheel for horizontal pan when scroll_x is on
- Persist `scroll_x` offset analog to `scroll_y`
- Add 4 tests covering: explicit scroll_y flag, scroll_x clip,
  scroll_x lint suppression, shift-wheel input
- **Carmack pass**: scan column-overflow lint code for inline
  candidates
- **Example**: `examples/ui_data_grid_phone.zig` — touch-friendly
  3-column dashboard with both vertical AND horizontal scroll
  (phone-friendly: scroll_x lets a 5-column data view fit on
  narrow screens)

### Turn 416 — P8.6 TableColumnFlags wave (part 1: structural flags)

imgui has ~18 `TableColumnFlags`.  Split into two turns to keep
each landable.  Part 1:
- `no_resize`, `no_reorder`, `no_hide`, `no_sort`,
  `no_sort_ascending`, `no_sort_descending` (sort suppression
  family)
- `default_hide`, `default_sort` (per-column initial state)
- 8-10 new tests
- **Carmack pass**: short single-use helpers in table-sort path
- **Example**: `examples/ui_kanban_board.zig` (desktop) — 4-column
  kanban board (Backlog/Doing/Review/Done), columns reorderable,
  cards draggable between columns.

### Turn 417 — P8.6 part 2 (display/indent flags) + P8.7 angled headers

- Remaining `TableColumnFlags`: `indent_enable`, `indent_disable`,
  `no_clip`, `no_header_label`, `no_header_width`, `width_auto`
- P8.7: angled column headers (diagonal text for narrow columns)
- 6-8 tests
- **Carmack pass**: tab-bar drawing helpers (some were spotted as
  thin wrappers in turn 411)
- **Example**: `examples/ui_pomodoro_phone.zig` — 25-min timer
  with progress ring, tap to start/pause, long-press to reset.
  Demonstrates: animation primitive (a precursor to §2.3-C),
  gesture-rich phone UI.

### Turn 418 — P8.8 table queries + new architecture: `u.animated(...)`

- `getColumnIndex`, `getColumnCount`, `getColumnName`,
  `getColumnFlags`, `getColumnUserId`
- **New architecture seed (§2.3-C)**: ship `u.animated(.{
  from, to, duration, easing })` as the first animation primitive.
  Uses ctx.frame_count for the time base; key by an id.  Returns
  the current float value, cached in ctx.  Spring variant deferred.
- 5 tests for animated, 4 for table queries
- **Example**: `examples/ui_animation_gallery.zig` (desktop) — 12
  knobs showcasing different easings.  Doubles as the
  reference doc for animation tuning.

### Turn 419 — P9.1 InputText character filters + phone keyboard hints

- `chars_decimal`, `chars_hexadecimal`, `chars_scientific`,
  `chars_uppercase`, `chars_no_blank`
- **Phone-relevant addition**: surface `input_mode` hint to the
  browser's `inputmode` HTML attribute (numeric / decimal / email
  / tel / etc.).  Maps onto the same filter mechanism — caller
  picks filter, runtime picks keyboard.
- 8 tests
- **Carmack pass**: any duplicated "is char allowed" predicates
- **Example**: `examples/ui_unit_converter_phone.zig` — temperature/
  length/weight converter.  Demonstrates filtered input + phone
  keyboard.

### Turn 420 — P9.2 InputText behavior flags + multiline polish

- `enter_returns_true`, `escape_clears`, `password_mask`,
  `read_only`, `auto_select_all`, `ctrl_enter_for_newline`,
  `allow_tab_input`
- Multiline text input polish (clip, scroll, copy-paste)
- 10 tests
- **Carmack pass**: input text clipboard helpers
- **Example**: `examples/ui_notes_phone.zig` — markdown-flavored
  scratchpad.  List of notes on left, edit area on right, auto-
  save via persistence.

### Turn 421 — P10.1-2 ColorEdit picker variants + phone color picker

- Picker variant enum (rgb / hsv / hue-ring / vertical-hue-strip)
- Display format enum (hex / float / 0-255)
- Suppression flags (`no_alpha`, `no_drag_drop`, `no_options`)
- 8 tests
- **Carmack pass**: short single-use draw helpers in color-edit
  (`drawHueRing` / `drawHueStrip` were spotted as 13-14 line
  single-use)
- **Example**: `examples/ui_color_studio_phone.zig` — pick a
  color, see complement / triad / split-complement schemes.
  Touch-friendly hue ring.

### Turn 422 — P12 Drag/Slider N-variants + linked sliders

- `drag2`, `drag3`, `drag4`, `slider2`, `slider3`, `slider4`
- Range-in-opts audit (consistency pass across slider/drag)
- **New architecture seed (§2.3-H reactive)**: a `Bind(T)` helper
  type that any slider/drag accepts.  Backwards-compat: existing
  `&value` ptr arg still works; `Bind` is an optional bridge for
  more complex sources (clamped, computed, etc.).
- 12 tests
- **Example**: `examples/ui_color_mixer_desktop.zig` — RGB sliders
  + HSV sliders + alpha, all linked.  Demonstrates Bind(T).

### Turn 423 — P11 Selectable callback + P13.1 MultiSelect nested scopes

- Selectable callback redesign (scoped down from v6 plan)
- MultiSelect nested scopes: a multiselect inside another, with
  shift-click ranges respecting scope boundaries
- 8 tests
- **Carmack pass**: scan selectable + multi-select for inlines
- **Example**: `examples/ui_file_picker_phone.zig` — folder
  navigator with multiselect for batch operations.  Phone-mode:
  tap to navigate, long-press to enter multiselect mode.

### Turn 424 — P13.2 MultiSelect shift-click range + architecture review

- Shift-click range + ctrl-click toggle for multiselect
- 6 tests
- **Architecture review**: revisit each of §2.3 A-J, mark which
  have begun, which to defer to a "post-arc" plan, which to drop.
  Update this document.
- **Example**: `examples/ui_dashboard_phone.zig` (capstone for
  this batch) — full phone dashboard combining the new
  primitives: animated metric tiles, swipe-able sections,
  multiselect for batch actions, persistence across reloads.

### After turn 424

Remaining imgui plan: P14 (logging), P15 (show*), P16 (outliers
+ checkboxFlags), P17 (comptime validation), P18 (capstone polish
+ archive).  Estimated 8-10 more turns to arc close.

Architecture work from §2.3 to land **after** arc close:
- §2.3-A comptime layout DSL (large, multi-turn)
- §2.3-B full gesture model (medium)
- §2.3-D chart widgets (medium)
- §2.3-E adaptive layout (medium)
- §2.3-F accessibility hooks (large; needs browser DOM bridge)
- §2.3-G state-as-data exposure (small)
- §2.3-I more comptime validation rules (incremental)
- §2.3-J `simple_app` helper (small)

---

## 4. New examples — phone-friendly batch (target: 5 ship in turns 415-424)

Each phone example targets:
- Portrait aspect, full-screen via `WindowScaleMode.responsive`
- Touch-sized targets (≥ 44pt at the active font size)
- Vertical scrolling primary; horizontal allowed via P8.5 work
- Big text, few widgets per screen
- Self-contained state, no external assets

| Example | Demo concept | Turn |
|---|---|---|
| `ui_data_grid_phone.zig` | 3-col data view with H+V scroll | 415 |
| `ui_pomodoro_phone.zig` | Timer + progress ring + gestures | 417 |
| `ui_unit_converter_phone.zig` | Filtered input + phone keyboards | 419 |
| `ui_notes_phone.zig` | Scratchpad + persistence | 420 |
| `ui_color_studio_phone.zig` | Hue ring + color schemes | 421 |
| `ui_file_picker_phone.zig` | Multi-select folder navigator | 423 |
| `ui_dashboard_phone.zig` | Animated tiles + swipe sections | 424 |

### Phone backlog (not slotted to a turn, ship opportunistically)

- `ui_stopwatch_phone.zig` — lap times, gesture-driven
- `ui_counter_phone.zig` — big +/- with haptic-feel animation
- `ui_calculator_phone.zig` — 4-fn calc with proper button grid
- `ui_mood_tracker_phone.zig` — pick a smiley, see weekly graph
- `ui_habit_tracker_phone.zig` — daily checkbox grid

## 5. New examples — desktop batch (target: 4 ship in turns 415-424)

| Example | Demo concept | Turn |
|---|---|---|
| `ui_kanban_board.zig` | 4-col board, drag cards between cols | 416 |
| `ui_animation_gallery.zig` | 12 easings showcase | 418 |
| `ui_color_mixer_desktop.zig` | Linked RGB/HSV/alpha sliders | 422 |
| (capstone) | covered in 424 phone dashboard | 424 |

### Desktop backlog (opportunistic)

- `ui_markdown_preview.zig` — split-pane md editor → rendered view
- `ui_json_explorer.zig` — collapsible tree with search
- `ui_pixel_paint.zig` — 32x32 paint grid + color picker
- `ui_spreadsheet_mini.zig` — 10x10 cells + sum formula
- `ui_audio_synth.zig` — playable keyboard with envelope knobs
- `ui_shader_preview.zig` — live GLSL preview with knobs
- `ui_log_viewer.zig` — tail-style log viewer with filter

---

## 6. Risk register

| Risk | Mitigation |
|---|---|
| 🟧 Scope creep in P9 (InputText is wide) | Split across 419 + 420 deliberately; each lands a working subset |
| 🟧 Animation primitive (§2.3-C) lands half-baked | Ship only `u.animated` linear-interp in 418; defer spring, defer reverse direction; document the limit |
| 🟧 Phone examples accumulate test load | Phone examples DON'T add tests by default — they're integration demos, not test fixtures.  Test budget stays focused on widget unit tests. |
| 🟨 Carmack pass introduces regressions | Each turn's Carmack changes must be runnable test/lint pass before commit; if a turn runs low on budget, defer the Carmack pass |
| 🟨 Architecture seeds (animated, Bind) accrete inconsistently | Each seed sits BEHIND a feature flag (`comptime` or `bool`) until accepted; document API decisions inline as TODOs for the post-arc review |

---

## 7. What this document is NOT

- It's not a re-plan of `imgui-plan-v7.md`.  That doc remains the
  canonical scope per P-phase.
- It's not a replacement for `system-audit-and-finishing-plan-turn-412.md`;
  it supersedes the §5 (10-turn execution order) of that doc but
  the audit findings in §3 of that doc are still relevant.
- Architecture brainstorm §2.3 is **directional**, not committed.
  Each item enters the plan only after explicit acceptance.

---

## 8. Cadence

Update this doc:
- At every turn boundary, mark the turn done + jot a 1-line
  outcome
- At turn 419 (mid-batch) — short re-plan if pacing's off
- At turn 424 (capstone) — full update, retire old turn rows,
  add the next 10
