# ui.zig — feature-complete plan (option 1)

## Style guideline summary (per-turn enforcement)

Every turn ships with these rules in effect.  Full text in
`src/notes/claude.md`; this is the cheat-sheet:

- **Rule 1: fn arg style.**  1 arg same line.  2 args same line if
  signature fits under 80 cols.  3+ args always one-per-line, with
  trailing comma so `zig fmt` keeps it that way.  Closing `)` on
  its own line at the same indent as `pub fn`.
- **Rule 2: explicit local types.**  `const x: i32 = foo();` always.
  Only omit when the type appears on the same line as an anchor —
  `gpa.alloc(T, n)`, `@as(T, ...)`, `@intCast(...)` with an
  explicit target.  Captured iter vars and `catch |err|` are
  exceptions (no type to write).
- **Rule 3: braces on every branch.**  Single-statement `if`/`else`/
  `while`/`for` still get `{ }`.  No exceptions.
- **Rule 4: comments are casual, undecorated, unnumbered.**  Top
  doc-comment says *what* the fn is and any non-obvious contract
  (allocator ownership, error semantics).  Inline `//` comments
  explain *why*, not what.  No "Section 3.2" / "Step 4 of 7" /
  ASCII boxes.  No "TODO" without a date.  No "this should..."
  speculation — present tense, what it is.
- **Rule 5: `@splat`, not `**`.**  Arrays of N copies use `@splat`.
- **Rule 6: argument clarity at call sites.**  When a call has a
  bare bool / int and the meaning isn't obvious, use a named
  comptime arg or a small enum.
- **Rule 7: keep boolean conditions trivial.**  Pull complex
  expressions into named `const`s before the `if`.
- **Rule 8: single-call helpers earn their keep.**  Don't extract a
  fn that's called once unless it improves readability noticeably.
- **Rule 9: no module-level mutable globals in examples.**  All
  state goes through the `*State` parameter.  `const` literals are
  fine.  This applies in `src/` too, modulo the few legacy globals
  the `count_globals.py` gate already tracks (0/0/0 today).
- **Rule 10: line width ≤ 120 chars.**  Wrap long string literals,
  long fn calls, etc.
- **Rule 11: integer-type discipline.**  Default: `i32` / `usize` /
  `i64`.  Use `u32` only for opaque handles (texture id,
  sample_rate).  Never `c_int` / `c_uint` in Zig surface.  Never
  `u64` unless explicitly required (timestamps).

## Per-turn process (non-negotiable)

After every turn — including pure-doc turns:

1. **Save zip** to `/mnt/user-data/outputs/zimr.zip`, present it
   via `present_files`.
2. **CHANGELOG entry** prepended to `src/notes/CHANGELOG.md`.
   Numbered turn ID, terse summary, files touched, audit numbers.
3. **Update the active plan file** — if the turn closed an item
   on the plan, mark it; if a question got answered, log the
   `[DECISION]` line.
4. **Audit gate** — all of:
   - `zig build install` (clean wasm)
   - `zig build smoke-test` (no FAIL)
   - `zig build test --summary all` (every passing test still
     passes; new tests pass)
   - `zig fmt --check src/ --exclude src/notes/staging`
   - `zig fmt --check examples/`
   - `python3 scripts/count_globals.py` (still 0/0/0)
   - `python3 scripts/check_dag.py` (no SCC growth, edge count
     reasonable)
5. **Re-read this file's style guide every 3 turns** so I don't
   drift from the rules.
6. **End-of-turn reply** uses the standard summary pattern
   (what shipped, audit numbers, what's next).

The begin/end balance check from Turn 173 catches new
`begin*` / `end*` pairs that get added without matched pops —
relevant since Phase 1 (tables), Phase 2 (drag-drop), and Phase
0c (tooltip block) all add new pairs.

## The goal — falsifiable

**Every section in imgui_demo.cpp's `[SECTION] DemoWindowWidgets*`
runs end-to-end on zimr.**  23 sections, enumerated below.  When
all 23 work, we're done.

Excluded explicitly (out of scope):
- Settings / `.ini` persistence
- Multi-viewport docking / platform IO layer
- `Example App: …` mini-applications inside imgui_demo.cpp
- `ShowStyleEditor()`
- Font atlas reflow / glyph range API

These can land as future standalone turns; they aren't gating
items for "ui complete."

## The 23 sections — current status

| Section | Status | Blocking |
|---|---|---|
| `DemoWindowWidgetsBasic` | ✅ | — |
| `DemoWindowWidgetsBullets` | ✅ | — |
| `DemoWindowWidgetsCollapsingHeaders` | ❌ | `collapsingHeader` widget |
| `DemoWindowWidgetsComboBoxes` | ✅ | — |
| `DemoWindowWidgetsColorAndPickers` | ⚠️ | `colorPicker3`/`colorPicker4` |
| `DemoWindowWidgetsDataTypes` | ⚠️ | `inputScalar`/`sliderScalar` N-variants |
| `DemoWindowWidgetsDisableBlocks` | ✅ | — |
| `DemoWindowWidgetsDragAndDrop` | ❌ | `begin/endDragDropSource/Target` family |
| `DemoWindowWidgetsDragsAndSliders` | ⚠️ | `drag/sliderFloatN`/`IntN` |
| `DemoWindowWidgetsImages` | ✅ | — |
| `DemoWindowWidgetsListBoxes` | ✅ | — |
| `DemoWindowWidgetsMultiComponents` | ❌ | `sliderFloat2/3/4`, `inputFloat2/3/4`, etc. |
| `DemoWindowWidgetsPlotting` | ❌ | `plotLines`, `plotHistogram` (imgui inline charts, not implot) |
| `DemoWindowWidgetsProgressBars` | ✅ | — |
| `DemoWindowWidgetsQueryingStatuses` | ⚠️ | `isAnyItemHovered`, a few `IsItemXxx` |
| `DemoWindowWidgetsSelectables` | ✅ | — |
| `DemoWindowWidgetsSelectionAndMultiSelect` | ❌ | `begin/endMultiSelect` — newer imgui API; **deferred** unless trivial |
| `DemoWindowWidgetsTabs` | ✅ | — |
| `DemoWindowWidgetsText` | ✅ | — |
| `DemoWindowWidgetsTooltips` | ⚠️ | `beginTooltip`/`endTooltip` block form |
| `DemoWindowWidgetsTreeNodes` | ✅ | — |
| `DemoWindowWidgetsVerticalSliders` | ✅ | — |
| `DemoWindowTables` | ❌ | the entire table API (the elephant) |

**Score: 13 fully covered, 6 partial, 4 missing.**

`SelectionAndMultiSelect` is the only one I'd flag as risky for
"complete on first pass" — it's a fairly elaborate state machine
for Ctrl/Shift selection.  Recommendation: implement basic
single-select extensions if cheap, leave the full multi-select
API as a footnote ("deferred — newer imgui feature").

## Architectural insight (changes the cost math)

**ui.zig's `DrawList` is a deferred command buffer over raylib's
existing shape API.**  When the user calls `ui.button(...)`, the
widget records a `DrawCmd` into the active window's list; at
frame-end, `replayDrawList()` walks the records and calls
`drawing.shapes.drawRectangleRec` / `drawing.text.drawEx` / etc.

So adding `addLine` to ui.zig is NOT "implement line rasterization."
It's three lines of code:

1. Add `line` variant to the `DrawCmd` union.
2. Add `DrawList.addLine(...)` method that pushes the command.
3. Add `.line => |c| drawing.shapes.drawLineEx(gl, c.a, c.b, c.thickness, unpackColor(c.col)),` to the replay switch.

**Every imgui DrawList primitive maps to an existing raylib shape
function.**  See the mapping table below.  Phase 0a is much
cheaper than I originally estimated — closer to half a turn
than a full turn.

## Phase 0a — DrawList primitives (~0.5 turn)

| New ui.DrawCmd | Maps to (replay) |
|---|---|
| `line { a, b, col, thickness }` | `drawing.shapes.drawLineEx` |
| `polyline { points, col, thickness, closed }` | `drawing.shapes.drawLineStrip` (open) / loop `drawLineEx` + close (closed) |
| `triangle_filled { a, b, c, col }` | `drawing.shapes.drawTriangle` |
| `triangle { a, b, c, col, thickness }` | `drawing.shapes.drawTriangleLines` |
| `quad_filled { a, b, c, d, col }` | two `drawTriangle` calls |
| `circle_filled { center, radius, col, n_segments }` | `drawing.shapes.drawCircleV` (full) / `drawPoly` (segmented) |
| `circle { center, radius, col, thickness, n_segments }` | `drawing.shapes.drawCircleLinesV` |
| `ngon_filled { center, radius, sides, rotation, col }` | `drawing.shapes.drawPoly` |
| `ngon { center, radius, sides, rotation, col, thickness }` | `drawing.shapes.drawPolyLines` |
| `bezier_cubic { p1, p2, p3, p4, col, thickness, n_segments }` | `drawing.shapes.drawLineBezierCubic` (if it exists) or polyline-approximate |
| `ellipse_filled { center, radius_xy, col }` | `drawing.shapes.drawEllipse` |
| `ellipse { center, radius_xy, col, thickness }` | `drawing.shapes.drawEllipseLines` |
| `rect_filled_multi_color { rect, c_tl, c_tr, c_br, c_bl }` | `drawing.shapes.drawRectangleGradientEx` |

All 13 primitives wired through existing raylib functions.  No
new rasterizer code.

**Decision (Q3):** circles/ellipses accept an `n_segments`
parameter where `0` means "auto-compute from radius."  Matches
imgui's convention.  The auto-segment heuristic is a 4-line port
of imgui's `_CalcCircleAutoSegmentCount` — clamp to
`[min_segments, max_segments]` against a max-error threshold,
constants `min = 12`, `max = 512`, `max_error = 0.30f`.

ngons (`addNgon`, `addNgonFilled`) keep an explicit `sides`
count — stylistic markers (hex, triangle, pentagon) always want
a specific shape, not an auto-fit.

**Polyline edge case:** the imgui DrawCmd payload includes a
**slice** of points.  Slices in a command-buffer entry need lifetime
management — they have to outlive the user's frame.

**Decision (Q2):** rename DrawList's existing `text_arena` →
`bytes_arena` and store polyline points in the same arena.  The
arena's job has always been "appendable byte storage that lives
for one frame"; text was just the original tenant.  Polyline
commands store `(offset_bytes, count)` and read `[count]Vector2`
from the arena at replay time.  Text commands keep reading
UTF-8 from `(offset_bytes, len_bytes)`.  Each command knows its
own payload type, so the mixed-byte arena is well-defined.

Doc-comment on `bytes_arena` lists the readers explicitly:
- `text` cmd: `bytes_arena[off..][0..len]` as UTF-8.
- `polyline` cmd: `bytes_arena[off..][0..count * @sizeOf(Vector2)]`
  reinterpreted as `[count]Vector2`.

No second arena, no alignment hazard (each reader reinterprets
its own slice with its own type).

**Custom-rendering example.**  Drop in
`examples/ui_custom_rendering.zig` after Phase 0a — single window
with a `f.ui.getDrawList()` handle that draws lines/triangles/
circles inside the window's clip rect.  This is imgui's
canonical answer to "how do I draw arbitrary stuff inside a
window?" and answers the API-overlap question for users
("inside a UI window → DrawList; outside → raylib shapes").

## Phase 0b — multi-component widgets + buttons + collapsingHeader (~0.5 turn)

**Decision (Q1):** option 3 — generic `sliderN` / `dragN` / `inputN`
over `anytype`.  The slot count comes from the array length; the
component type from the element type.  No `Float2/3/4` × `Int2/3/4`
proliferation.

| New fn | Pattern |
|---|---|
| `sliderN(label, ptr_to_array, opts)` | accepts `*[N]T` for any numeric T; loops N times calling the existing scalar `slider`, pushes N IDs from the array index, shares the label |
| `dragN(label, ptr_to_array, opts)` | same shape over existing `drag` |
| `inputN(label, ptr_to_array, opts)` | same shape over existing `inputFloat`/`inputInt` |
| `sliderAngle(label, &radians, opts)` | wraps `slider` with rad↔deg conversion at the boundary |
| `arrowButton(label, dir)` | wraps `button` with a 12×12 triangle from Phase 0a's `triangle_filled` |
| `smallButton(label)` | wraps `button` with smaller padding |
| `collapsingHeader(label, flags)` | wraps `treeNode` with header styling (full-width background bar) |

Doc comment on `slider` and `sliderN` lists the imgui equivalents
("imgui's `SliderFloat`, `SliderFloat2/3/4`, `SliderInt2/3/4`,
`SliderScalar`, `SliderScalarN` are all spelled `slider` /
`sliderN` here — element type and count are inferred from the
pointer.").  Cushions the imgui-port discovery problem.

Total surface added: **3 multi-component widgets + 4 polish fns =
7 new top-level entries.**  Each new fn is 15-50 LOC.

Closes `DemoWindowWidgetsMultiComponents`,
`DemoWindowWidgetsDragsAndSliders`,
`DemoWindowWidgetsCollapsingHeaders`, and significantly
narrows `DemoWindowWidgetsDataTypes` (the existing scalar
`slider`/`drag`/`input` already handle every numeric type
via `anytype`; the demo just exercises them with `i8`/`u16`/etc.).

## Phase 0c — sparklines, color picker popup, tooltip block, query fns (~0.75 turn)

(Budget bumped from 0.5 → 0.75 after Q5 — both color picker
layouts ship together, adding ~150 LOC over the bar-only option.)

- `plotLines(label, values, scale_min, scale_max, graph_size)` —
  uses Phase 0a's `polyline`.  ~50 LOC.
- `plotHistogram(label, values, ...)` — uses `addRectFilled`
  with N bars.  ~40 LOC.
- `colorPicker3` / `colorPicker4` — HSV popup with two layouts,
  flag-selectable via `opts.layout = .wheel | .bar`:
  - **Bar layout** (~120 LOC): SV gradient square + vertical hue
    bar.  Uses `rect_filled_multi_color` + linear hit-test.
  - **Wheel layout** (~250 LOC): circular hue ring rendered via
    `convex_poly_filled` per-segment-with-gradient + inscribed
    rotating SV triangle.  Angular hue hit-test + barycentric
    SV hit-test.
  - **Decision (Q5):** both ship in Phase 0c so the surface
    matches imgui exactly.  Default is bar (more precise to drag
    against); wheel via `.layout = .wheel`.  ~350 LOC total.
- `beginTooltip` / `endTooltip` — block-form variant of existing
  `setTooltip` one-shot.
- `isWindowFocused`, `isWindowAppearing`, `isAnyItemHovered`,
  `getCursorScreenPos`, `setCursorScreenPos` — query/cursor fns.
  ~10 LOC each.

Closes `DemoWindowWidgetsPlotting`,
`DemoWindowWidgetsColorAndPickers`,
`DemoWindowWidgetsTooltips`,
`DemoWindowWidgetsQueryingStatuses`.

**Demo gallery v1 lands here.**  After Phase 0c, 19 of 23 sections
are covered.  Only tables, drag-and-drop, and multi-select remain.

## Phase 1 — TABLES (~3.5 turns)

The big one.  imgui's `BeginTable` family is **1500 LOC** in
imgui_tables.cpp.  We'll do a subset that covers the demo's
table examples.

Surface (from the imgui API):
- `beginTable(str_id, columns_count, flags, outer_size, inner_width)` /
  `endTable`
- `tableSetupColumn(label, flags, init_width, user_id)`
- `tableSetupScrollFreeze(cols, rows)`
- `tableHeadersRow()` / `tableHeader(label)`
- `tableNextRow(flags, min_row_height)`
- `tableNextColumn()` / `tableSetColumnIndex(n)`
- `tableGetSortSpecs()`
- `tableSetBgColor(target, color, column_n)`
- A handful of getters: column count, column index, hovered column,
  row index, column flags, column name, sort specs.

**Decision (Q6):** column sizing supports two modes only —
`WidthStretch` (default; columns split remaining space equally
by weight) and `WidthFixed` (caller passes pixel width).  Drop
`NoResize` / `NoReorder` / `NoHide` flags for v1 since the
matching interactions (drag-to-reorder, right-click-hide) aren't
shipping yet.  When we add those interactions in later turns,
the restriction flags come with them.  Covers every
`DemoWindowTables` example.  ~150 LOC of sizing logic in Phase
1a vs ~400 for full imgui parity.

Phase split:
- **1a (1 turn) — layout core:** beginTable/endTable, column
  widths, tableNextRow/tableNextColumn, basic border drawing,
  outer-size frame.
- **1b (1 turn) — headers + sort:** tableHeadersRow,
  tableSetupColumn with sortable flag, click-to-sort,
  tableGetSortSpecs surfacing column index + ascending/descending.
  **Decision (Q7):** multi-column sort capped at N=3.  Shift-click
  adds a secondary, third Shift-click adds a tertiary, fourth
  becomes the new primary.  Stored as `[3]SortSpec` on the table
  state — no heap, no arena.  User reads
  `for (specs.items()) |s| ...`; semantics match imgui except
  `len <= 3`.  ~80 LOC.
- **1c (1 turn) — scrolling + freeze:** vertical + horizontal
  scrollbars within the table frame, tableSetupScrollFreeze,
  content clipping outside the frame.
- **1d (0.5 turn) — backgrounds + tints:** alternating-row tints
  (one of the imgui `ImGuiTableFlags`), `tableSetBgColor` for
  per-cell, per-row, per-column highlighting.

Closes `DemoWindowTables`.

## Phase 2 — drag-and-drop (~2 turns)

State machine on `UiContext.drag_drop`:
- `idle` — no drag in progress
- `armed` — LMB pressed on a source-tagged item, not yet moved
  past a threshold
- `dragging` — past the threshold; payload is live
- `over_target` — drop preview rendered
- `dropped` — accept-success; one-frame state, then back to idle

Surface:
- `beginDragDropSource(flags)` / `endDragDropSource` — call inside
  the item's body, registers it as a source.
- `setDragDropPayload(comptime T, value, cond)` — stash payload
  bytes into a ctx-owned arena.  Type ID derived from
  `@typeName(T)` at comptime; value bytes via
  `std.mem.asBytes(&value)`.  **Decision (Q8):** comptime-typed
  surface (no void pointers); accept side recovers the value with
  compile-time type check.
- `beginDragDropTarget` / `endDragDropTarget` — call after the
  potential drop-target item, registers as candidate.
- `acceptDragDropPayload(comptime T) → ?T` — returns the
  value if `(over_target && type_name matches)`.  Type mismatch is
  a silent null (same as imgui's behavior for mismatched type
  strings).
- `getDragDropPayload(comptime T) → ?T` — peek without accepting.

`Cond` parameter (imgui's `Always` / `Once`) deferred for v1 —
payload is set on the source-side call, lives until the drag
ends or another drag starts.

Phase split:
- **2a (1 turn):** state machine + source/target detection +
  payload arena + a "drop preview" rectangle.
- **2b (1 turn):** edge cases (drag-to-self, drag-to-disabled,
  type mismatches, drop-on-pop), demo example showing
  reorderable list + bucket-drop.

Closes `DemoWindowWidgetsDragAndDrop`.

## Phase 3 — polish (~1 turn)

- **Style push/pop (decision Q9):** single reflection-based fn
  `pushStyle(comptime field: []const u8, value)` /
  `popStyle(count)`.  Uses `@field(ctx.style, field)` at comptime
  to read+restore the matching slot; works for any `Style` field
  without enumerating them.  Compile-time typo catches; zero
  maintenance as the `Style` struct grows.

  Stack format: each push records `(field_name_id, old_value_bytes)`
  on `UiContext.style_stack`.  Pop reads the top entry and writes
  the bytes back into the struct at the named field.  Field-name
  → handler dispatch resolved at comptime, so the runtime cost
  is one memcpy per push/pop.

  Doc-comment on `pushStyle` lists every pushable field (= every
  field of `Style`).  imgui mapping: imgui's `ImGuiCol_Text` →
  `pushStyle("text", color)`, `ImGuiCol_ButtonHovered` →
  `pushStyle("button_hovered", color)`, `ImGuiStyleVar_FrameRounding` →
  `pushStyle("frame_rounding", 4.0)`, etc.

  ~120 LOC.

- `getCursorPos`/`setCursorPos` + screen-pos variants.  ~50 LOC.
- Additional text variants: `labelText`, `textDisabled`,
  `textLinkOpenURL` (opens in new browser tab via JS bridge).
- A final sweep over `DemoWindowWidgetsQueryingStatuses` and
  `DemoWindowLayout` to fill any `isXxx` / `getXxx` that turned
  up missing during demo porting.

Closes the leftover paper cuts that show up when porting the
final mega-example.

## Demo gallery — phased deliverables

After each phase we ship a demo example.  These are both
validation and showcase.

| Phase | Example | What it covers |
|---|---|---|
| 0a | `ui_custom_rendering` | every new DrawList primitive driven by sliders; mirrors imgui's "Custom Rendering" demo section |
| 0b | `ui_widgets_data_types` | multi-component sliders, drags, inputs, all scalar types |
| 0c | `ui_plotting_basic` (sparklines), `ui_color_picker` | imgui's plotting + color demos |
| 1d | `ui_tables_demo` | imgui's table demo — five table styles: minimal, sortable, scrollable, frozen-headers, custom row colors |
| 2  | `ui_drag_and_drop` | reorderable list + bucket-drop |
| 3  | `ui_full_showcase` ← **the capstone** | single window with collapsing-header sections for every widget family.  imgui's `ShowDemoWindow()` equivalent |

### The capstone — `ui_full_showcase.zig`

**Decision (Q10):** single-file, ~2000 LOC.  Mirrors imgui's
`imgui_demo.cpp` (10K+ LOC single file) — side-by-side porting is
trivial when the layouts match.  Keeps zimr's "one example = one
file" convention intact.  Single `State` struct as the source of
truth for all per-widget persistent values; sections are
top-level fns called from `update` based on which
`collapsingHeader` is open.

Top-of-file is a table-of-contents banner with line numbers
pointing at each section, so navigating the 2000-line file is
ctrl-F-friendly.

Structure:

```zig
fn update(f: *z.Frame, s: *State) void {
    if (f.ui.window("zimr — UI showcase", .{ .size = .{ .x = 700, .y = 700 } })) |w| {
        defer w.close();
        // Top: search-filter text input + "active section" indicator.
        // Each section is one collapsingHeader.  Click to expand.
        showWidgetsBasic(f.ui, s);
        showWidgetsText(f.ui, s);
        showWidgetsTrees(f.ui, s);
        showWidgetsBullets(f.ui, s);
        showWidgetsCollapsingHeaders(f.ui, s);
        showWidgetsComboBoxes(f.ui, s);
        showWidgetsListBoxes(f.ui, s);
        showWidgetsSelectables(f.ui, s);
        showWidgetsTabs(f.ui, s);
        showWidgetsDataTypes(f.ui, s);
        showWidgetsMultiComponents(f.ui, s);
        showWidgetsDragsSliders(f.ui, s);
        showWidgetsInputs(f.ui, s);
        showWidgetsColorPickers(f.ui, s);
        showWidgetsPlotting(f.ui, s);
        showWidgetsImages(f.ui, s);
        showWidgetsProgressBars(f.ui, s);
        showWidgetsTooltips(f.ui, s);
        showWidgetsMenus(f.ui, s);
        showWidgetsPopups(f.ui, s);
        showWidgetsDisableBlocks(f.ui, s);
        showWidgetsCustomRendering(f.ui, s);
        showLayout(f.ui, s);
        showTables(f.ui, s);
        showDragAndDrop(f.ui, s);
    }
}
```

Each `showWidgetsXxx` is a fn pointer in a single-file dispatch
table or just a top-level fn called when its header is open.
**1 LOC per section in the dispatch loop; each section is
30-150 LOC.**

State carries the per-widget vars across frames (every slider /
input value the demo mutates).  Single `State` struct, fields
named after the demo they belong to.

Estimated size: **~2000 LOC.**  Equivalent to a substantial
example but produces a single visible artifact that proves we hit
the bar.

## Effort summary

| Phase | Description | Turns |
|---|---|---:|
| 0a | DrawList primitives (~13 commands, wired through raylib shapes) | 0.5 |
| 0a-ex | `ui_custom_rendering` demo | 0.25 |
| 0b | Multi-component + arrow/small buttons + collapsing header | 0.5 |
| 0b-ex | `ui_widgets_data_types` demo | 0.25 |
| 0c | Sparklines + color picker (bar + wheel) + tooltip block + misc queries | 0.75 |
| 0c-ex | `ui_plotting_basic` + `ui_color_picker` demos | 0.5 |
| 1a | Tables — layout core | 1 |
| 1b | Tables — headers + sort | 1 |
| 1c | Tables — scrolling + freeze | 1 |
| 1d | Tables — backgrounds + tints + `ui_tables_demo` | 0.75 |
| 2a | Drag-drop — state machine + accept/get | 1 |
| 2b | Drag-drop — edge cases + `ui_drag_and_drop` demo | 1 |
| 3 | Polish + leftover paper cuts | 1 |
| Cap | `ui_full_showcase.zig` — the capstone mega-example | 1.5 |
| **TOTAL** | | **~11 turns** |

## Per-turn audit gate (unchanged)

Every turn ships green:
- `zig build install`
- `zig build smoke-test`
- `zig build test --summary all`
- `zig fmt --check src/ --exclude src/notes/staging`
- `zig fmt --check examples/`
- `python3 scripts/count_globals.py` (0/0/0)
- `python3 scripts/check_dag.py` (no SCC growth)

Plus the begin/end balance check from Turn 173 catches any new
begin/end pairs (table, drag-drop, tooltip) that get added without
matched pops.

## Risk register

| Risk | Mitigation |
|---|---|
| Tables blow up to 4-5 turns instead of 3.5 | Lock the surface to "covers imgui_demo.cpp's table section."  Defer column-resize-by-drag and advanced sort-multi-spec if they balloon. |
| Color picker HSV wheel needs primitives not in 0a | Audit during 0a planning: if `convex_poly_filled` with HSV gradient via `rect_filled_multi_color` doesn't suffice, add `triangle_strip_multi_color` in 0a. |
| Drag-drop's "drag threshold" + mouse-leak detection is fiddly | imgui has ~5 frames of state before the drag goes live.  Port the imgui state machine exactly; don't try to simplify. |
| Mega-example exceeds 2000 LOC | Split into 2 windows or use a sub-file pattern.  Worst case it's 3000 LOC — still tractable. |
