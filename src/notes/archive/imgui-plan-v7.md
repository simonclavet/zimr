# imgui-plan-v7.md — finishing the imgui port (drafted turn 383)

**Supersedes v6.** v6 stays in `archive/` for arc-history reference.

**Status at draft time:** 1555 unit tests pass, 87 wasm examples,
`src/ui.zig` is ~26k lines.  Docking arc shipped 319-334; font
default sweep turn 335; lint cleanup arc turns 337-381 (cleared
`untyped-local` ×~600, `line-length` ×465, `ex-variant` ×20,
flipped lint to a hard gate, separate `tools/build.zig` subbuild).
The lint cleanup detour is closed.  Time to ship imgui.

The working agreement (per-turn rhythm, audit gate, style rules,
sharp edges, etc.) is unchanged from v6 §1.  Re-read v6 §1 if
it's been ~10 turns since the last refresh.

---

## 1. What v7 changes vs v6

Three structural changes, plus three scope tightenings.

### 1.1 Reorder: reflection inspector (was D) moves to the front

The single highest-leverage step in the whole arc is the
reflection inspector — `u.inspect(label, &any_struct)` —
because **multiple later phases collapse to one-liners once it
exists.**  v6 had it after dev tools (B) to "grow eyes before
experimenting," but the inspector is mostly comptime dispatch
on `@typeInfo`; its bugs are compile errors, not runtime
mysteries needing a DebugLog viewer.  Shipping it second buys:

- Phase O's `showStyleEditor` → `u.inspect("Style", &ctx.style)`.
  Was 5 LOC in v6, now 1 LOC.
- Phase O's `showMetricsWindow` → `u.inspect("Metrics", &ctx.metrics)`.
  Was a custom viewer in v6; now the metrics struct viewer is free.
- The dev-tools demo (was B.6) eats its own dogfood — every
  panel rendered by `u.inspect` over the underlying struct.
- The whole plan develops in a "structured data first, viewer
  free" rhythm.

### 1.2 No Phase A as a separate phase

v6's Phase A was three loose-ends (dock persistence demo, showcase
Docking tab, archive plan v5).  In v7 these are just the first
turn — call it the **Prelude** — before the real phases start.

### 1.3 Layout linting scope-down

v6's B.4 spec'd a new `src/ui_lint.zig` module with a 64-bit
warning bitset and registered Lint enum.  Demoted to: just **add
five named asserts** at the sites where they catch real bugs
(`dragRange.min >= max`, etc.).  Each is a four-line
`std.log.warn` block; no framework.  If a sixth lint case
appears we'll factor then.

### 1.4 ID-stack tool: defer

v6 spec'd `id_stack_breadcrumbs: BoundedArray(IdBreadcrumb, 32)`
on UiContext, hooked into `hashStr`/`pushId`/`popId`.  Useful
when we can't track down "why is this ID 0?" — but in 380 turns
we haven't had that bug.  Defer to "if needed."

### 1.5 Long-press: own phase, not buried in dev-tools

v6 buried the touch-long-press-to-right-click bridge inside Phase
B.  It belongs as its own tiny phase because (a) it's the only
mobile UX gap left in input, (b) it's independent of everything
else, (c) it ships in one turn.  Promoted to Phase 4 here.

### 1.6 The 6-phase parity-flag waves stay

E (window), H (table), I (input), J (color), K (selectable), L
(drag) — these are the bulk of the imgui parity surface area.
They're correctly ordered in v6 (G's DrawListSplitter blocks
H.1's table cell backgrounds) and stay that way here.

---

## 2. Phase layout (v7)

```
 Prelude — dock_persistence demo + showcase Docking tab     1 turn
 P1.  Reflection inspector       (was D, was AM-8)          ~4 turns
 P2.  Foundation dev tools — DebugLog + Metrics             ~3 turns
 P3.  Long-press → right-click bridge                       1 turn
 P4.  Style persistence + presets                           ~2 turns
 P5.  Window flag wave (was E)                              ~5 turns
 P6.  Layout/cursor query gaps (was F)                      ~1 turn
 P7.  DrawListSplitter + table channels (was G)             ~2 turns
 P8.  Table flag waves (was H)                              ~6 turns
 P9.  InputText flag wave (was I)                           ~3 turns
 P10. ColorEdit flag wave + Color converters (was J)        ~3 turns
 P11. Selectable callback redesign (was K, scoped down)     ~2 turns
 P12. Drag/Slider drag2/3/4 (was L)                         ~2 turns
 P13. MultiSelect completeness (was M)                      ~2 turns
 P14. Logging family (was N)                                1 turn
 P15. show* family closeout — most eat the inspector        ~1 turn
 P16. KeyboardKey + popup outliers + checkboxFlags (was P)  ~2 turns
 P17. Compile-time validation (was Q, AM-11)                ~3 turns
 P18. Capstone polish + archive (was R)                     ~3 turns
```

~45 steps, estimated ~25-30 turns to arc close.

---

## 3. Prelude — dock persistence demo + showcase tab

**Goal**: ship over the existing dock-persistence wiring.  No
`src/ui.zig` edits — proves the pipeline survived the lint
cleanup arc, validates the path, gets us back into the imgui
rhythm.

**Deliverables:**
- `examples/ui_dock_persistence.zig` — three docked windows, a
  "Clear saved layout" button, a counter that proves state is
  independent of layout.  Layout survives F5 refresh.
- `ui_full_showcase` gets a `Docking` tab — exercises split
  builder, drag-detach, drag-reorder, size_ref locking, central
  node, persistence.
- Register both in `build.zig` + `manifest.json`.

**Acceptance**: both compile and run; manual phone smoke shows
persistence works after refresh.

---

## 4. P1 — Reflection inspector (AM-8)

**Turn-384 discovery**: most of P1 is **already shipped** under
Phase 5A.  `src/ui.zig` has:

- `pub fn editStruct(value_ptr)` — public Ui method.
- `pub fn editStructOpts(value_ptr, opts)` — per-field opts via
  parallel struct (`skip`, `label`, `min`, `max`, `fmt`, `is_color`).
- `pub fn inspect(label, value_ptr)` — wraps in `treeNode`.
- `pub fn inspectWithAttrs(label, value_ptr, opts)` — labeled + opts.
- `pub fn styleEditor()` — `editStruct(&ctx.style)`.
- `pub fn editArrayList(label, list_ptr)` / `editArrayListOpts`
  — bonus dynamic-list editor with add/remove.

Internal `editFieldDispatch` covers more `@typeInfo` cases than
v6/v7 spec'd:
`.bool` → checkbox; `.float`/`.int` → free input or slider when
min+max present; `.@"enum"` → combo; `.@"struct"` → special-case
`Color` / `Vec2`, generic recurse else; `.array` → colorEdit for
[3]/[4]f32 with `is_color` opt or `"color"` in name, generic
tree-node-per-element else; `.pointer` → `[]const u8` read-only
display; `.optional` → checkbox toggle + recurse with
`canZeroInit` fallback for non-zero-initable wrapped types;
`.@"union"` → tag combo + recurse on active variant (variants
whose payload can't zero-init render disabled).

8 host-tests covering each branch.  In production use in
`examples/imgui_demo.zig` Phase 5A.

### What's actually remaining

- **P1.3 — mutable string fields.**  Today `.pointer` for
  `[]const u8` renders read-only.  No type lets a user expose an
  editable inline-buffered string to the inspector.  This turn:
  ship `BoundedString(N)` (a tiny struct wrapping `[N]u8 + usize`)
  + detect it in the dispatcher + wire to `inputText` + tests.
- **P1.4 — standalone demo `examples/ui_inspector.zig`.**  Phase
  5A in `imgui_demo` covers the inspector; a focused per-feature
  demo would be a polish step, not a foundation step.  Defer to
  P18 capstone polish or skip.

### Scratch (was P1.1/P1.2 — superseded by Phase 5A)

P1.1 core dispatcher: shipped (see audit above).
P1.2 attrs via parallel struct: shipped as `editStructOpts`.

---

## 5. P2 — Foundation dev tools (slimmer than v6 B)

### P2.1 — DebugLog ring buffer ✅ SHIPPED turn 385

- `UiContext.debug_log: BoundedArray(DebugEvent, 256)` (BoundedArray
  vendored into `src/utils.zig` from std, attributed to jedisct1 + Zig
  contributors, MIT).
- `DebugEvent = struct { frame: u32, kind: DebugEventKind,
  message: [128]u8, message_len: u8 }`.
- `pub fn debugLogPush(ctx, kind, fmt, args)` formats into the
  inline buffer; on overflow `orderedRemove(0) + append`.
- 4 sites wired this turn: `openPopup` → popup_opened,
  `closeCurrentPopup` → popup_closed, drag-threshold-cross →
  drag_started, `acceptDragDropPayloadImpl` → drop_accepted.
  Remaining ~8 sites deferred (focus changes, item activations,
  dock requests, lint warnings, id collisions — wire opportunistically
  as P2.3/P5/P9 land).
- 3 tests: push, drop-oldest at cap, truncate-long-message.

### P2.2 — Frame metrics ✅ SHIPPED turn 386

`UiContext.metrics: Metrics` — inline struct, ~520B:
- `frame_count: u32`, `frame_time_ms: f32`.
- `frame_time_ms_history: [120]f32` + `history_head: u8` — rolling
  2-second window @ 60Hz, designed for the eventual `plotLines`
  widget.
- `windows_active: u32` (frame_windows.len),
  `windows_hovered: u32` (0 or 1 depending on `hovered_window_id`).
- `cmd_count: u32`, `drawlist_count: u32` — accumulated across
  the 5 render sites in endFrame (background, per-window,
  per-popup, foreground; tooltip-block + drag-preview are
  conditional).
- `last_active_widget_id: Id` — sticks across frames where
  nothing is active, so the user can still see "last thing
  clicked".

Deliberate omission from the v6/v7 sketch: **no vertex/index
counts**.  Counting vertices would require instrumenting rlgl,
which is a layer below ui.zig; `cmd_count` is the practical
substitute (it tracks "how busy was the UI submission" which
is what users actually want from a metrics panel).

Collection seam: 3 helpers (`metricsCollectAtEndFrame`,
`metricsResetRenderCounters`, `metricsAccumulateDrawList`) wired
into `endFrame` right before the per-frame render loop.  No
public API surface beyond the `metrics` field — `Ui.inspect` over
`&ctx.metrics` is what P2.4 / P15 will use.

5 tests: defaults zero, populate from ctx state, history ring
wraps at LEN, cmd_count + drawlist_count accumulate (and reset),
last_active_widget_id stickiness across blank frames.

### P2.3 — Five tactical lint asserts ✅ SHIPPED turn 387

Helper: `utils.warnOnce(@src(), fmt, args)` — per-call-site dedup
via the inline-fn anonymous-struct-static trick.  Routes through
`std.log.warn` (which in browser builds goes to `console.warn`).

Wired five inline checks:

1. `sliderDispatch`: `opts.min >= opts.max` → "degenerate range".
2. `dragDispatch`: `opts.min > opts.max` (strict; `==` is the
   documented "no clamp" sentinel) → "inverted clamp".
3. `computeTableColumnLayout` tail: `final_right > outer_right
   + 0.5px` (after the min-width floor) → "column total overflows
   outer width".
4. `Ui.openPopup`: existing entry has `opened_at_frame ==
   ctx.frame_count` → "opened twice this frame".
5. `closeWindow`: auto-expanded window grew below canvas, OR
   user-sized window has content > 3× viewport → "consider
   setNextWindowSize / enlarge window".

Deviation from spec on #5: the literal "no scrollbar"
condition can't fire today (zimr auto-shows the scrollbar
whenever `scroll_max_y > 0`), so the lint targets the two
real failure modes the spec was aiming at.

5 smoke tests verify each lint path is reachable + doesn't
crash; the dedup mechanism itself is exercised by a 100-call
loop test on `warnOnce`.

### P2.4 — Demo: `examples/ui_dev_tools.zig` ✅ SHIPPED turn 388

Three-section single-window demo (180 LOC):

1. **Metrics panel** — one line: `_ = u.inspect("Metrics (live)",
   &s.ui_ctx.metrics)`.  P1's inspector walks every field of the
   `Metrics` struct automatically; the demo adds nothing per-field.

2. **DebugLog viewer** — collapsible tree node with a manual loop
   over `debugLogSlice(&s.ui_ctx)` rendering the last 10 events
   newest-first as `[frame] kind: message` rows.  Not via
   `inspect` because BoundedArray's storage layer surfaces the
   256-slot inline buffer when only `len` are meaningful.  A
   future inspector helper (or `BoundedArray`-aware dispatcher
   path) could collapse this back to one line.

3. **Event triggers** — three interactive widgets that generate
   events so the viewer isn't empty:
   - Open-popup button → `popup_opened` log entry.
   - Drag-drop source/target pair → `drag_started` +
     `drop_accepted` log entries; mutates a slot value visible
     in the UI.
   - Bad-bounds slider (`min == max`) → fires P2.3 lint #1 once
     at process start; `[zimr lint]` line visible in browser
     console.

Standalone bundle: `prebuilt/standalone/ui_dev_tools.html` 644 KB
after `python3 scripts/build_standalone.py ui_dev_tools`.

---

## 6. P3 — Long-press → right-click (was AM-5) ✅ SHIPPED turn 389

Helper: `applyLongPressSynthesis(ctx, snapshot, input_state)` —
factored as a pure helper so tests drive it directly without a
`Frame` / `GlState` harness.  Invoked once per `beginFrame`
right after the `InputSnapshot` is built; OR-merges into
`snapshot.mouse_right_clicked` on the frame the threshold crosses
and clears `mouse_left_down` / `mouse_left_clicked` so widgets
don't interpret the same gesture as both a click and right-click.

Constants:
- `TOUCH_LONG_PRESS_THRESHOLD_MS: f32 = 500`
- `TOUCH_LONG_PRESS_DRIFT_PX: f32 = 6`

State on `UiContext`: `long_press: LongPressTracker = .{}` —
one tracker (single-touch only; multi-touch resets to "not
tracking").  Fields: `touch_id`, `start_pos`, `elapsed_ms` (with
`-1` sentinel for cancelled, `> THRESHOLD` for fired),
`just_fired_this_frame` (one-shot flag readable by callers).

Cancellation rules:
1. Touch lifted (count → 0).
2. Multi-touch (count > 1).
3. Drift exceeds 6px from touchdown anchor.
4. `mouse_left_down` released early (touchend race).

Once cancelled, the press cycle is locked out until the next
fresh touchdown.

Six tests cover: threshold-fires, drift-cancels, multi-touch-
ignores, desktop-mouse-bypasses, one-shot-no-refire, re-arm-on-
new-touch.

**Acceptance**: existing context-menu popups (which read
`mouse_right_clicked`) work on phone via long-press.  Test fires
synthetic right-click in unit test. ✅

---

## 7. P4 — Style persistence + presets ✅ SHIPPED turn 390

### P4.1 — Extend `.zon` persistence to `Style` ✅

`PersistedStyle` (in `src/ui_persistence.zig`) mirrors every
Color + numeric field of `Style`.  Colors stored as `[4]u8`
tuples for compact .zon output.  `font: ?*const Font` deliberately
excluded — pointers can't round-trip.

`PersistedState.style: ?PersistedStyle = null`.  `serialize`
emits `null` when the in-memory style equals `Style.dark_default`
(saves ~600 bytes for unthemed apps); emits the full block
otherwise.  `apply` calls `style.applyTo(&ctx.style)` which
preserves the caller's `font` pointer.

Comptime quota: added `@setEvalBranchQuota(10_000)` in `apply` —
std.zon's recursive parser needed more than the default 1000
branches for the expanded `PersistedState` graph.

4 tests: skip-when-default, emit-when-divergent, full-round-trip
across colors/Vec2/scalar/i32, font-pointer-preserved.

### P4.2 — Ship `light_default` + `classic_default` ✅

`Style.light_default` and `Style.classic_default` translated
from imgui's `StyleColorsLight` / `StyleColorsClassic` (float
0..1 → u8 via `round(x*255)`).  Three differences from a literal
port documented in-source:
1. zimr's 3 text-link slots derived from imgui's single
   `TextLink` via brighten/darken offsets.
2. `tab_separator` maps to imgui's `Separator`.
3. `menu_hovered` maps to imgui's `HeaderHovered` (same
   convention as `dark_default`).

```zig
pub const Preset = enum { dark, light, classic };
pub fn applyPreset(self: *Style, preset: Preset) void { ... }
```

Copies every Color slot from the preset; preserves numeric
chrome (`window_padding`, `font_size`, etc.) and `font` pointer
so the user's typography/density survive a theme flip.

3 tests: `.light` swaps colors but preserves numerics + font;
`.classic → .dark` round-trip restores; font pointer preserved
across two `applyPreset` calls.

`examples/ui_polish.zig` gets a 3-button row at the top of the
demo (`dark` / `light` / `classic`) wired to `applyPreset`.
Standalone bundle: `prebuilt/standalone/ui_polish.html` 608 KB.

---

## 8. P5 — Window flag wave (was E)

Today `WindowFlags = struct { is_child: bool = false }`.  Imgui
has 30+ flags.  Five thematic batches:

### P5.1 — Chrome suppression ✅ SHIPPED turn 391

Six new bool fields on `WindowFlags`:
- `no_title_bar` — skip title rect + text; layout origin shifts up.
- `no_resize` — skip corner grip glyph + resize drag hit-test.
- `no_move` — skip title-bar drag hit-test (title still renders).
- `no_collapse` — reserved slot; NO-OP today (zimr has no
  collapse mechanism yet).  Wires automatically when collapse
  lands.
- `no_background` — skip the window-bg `drawRectFilled` (HUD
  overlays where the caller supplies their own backdrop).
- `no_scrollbar` — skip scrollbar render AND wheel-scroll
  consumption (both must agree).

Plumbing:
- `WindowOpts.flags: WindowFlags = .{}`.
- `findOrCreateWindow` propagates `opts.flags → Window.flags` at
  creation; existing-window path re-stamps each frame (preserving
  `is_child` which is set at child creation and shouldn't flip).
- New helper `effectiveTitleBarHeight(ctx, w) f32` returns
  `style.title_bar_height` normally, `0` when `no_title_bar` is
  set.  Used at: `renderWindowChrome` title rect; `openWindow`
  content origin; `closeWindow` viewport_h + content_h auto-fit.

7 tests pin: defaults all false; flag round-trip opts→Window;
`no_title_bar` shifts content origin; `no_background` saves 1
rect cmd; `no_title_bar` saves 2 cmds (rect + text);
`no_resize` saves 3 cmds (3-rect grip glyph); flag re-stamping
on subsequent submissions.

### P5.2 — Sizing ✅ SHIPPED turn 392

Three new bool fields on `WindowFlags`:
- `always_auto_resize` — every frame, window matches content
  exactly (BOTH grow AND shrink); ignores `user_resized` and
  any persisted size on first submission.
- `always_use_window_padding` — reserved slot, NO-OP today
  (top-level windows always pad; for children use the existing
  `ChildFlags.always_use_window_padding`).
- `no_saved_settings` — `ui_persistence.serialize` skips
  windows with this flag set.

Wiring:
- `findOrCreateWindow`: persisted-size resolution skipped when
  `opts.flags.always_auto_resize` is true.
- `closeWindow` auto-fit branch: when `always_auto_resize` is
  set, match content exactly; else existing grow-only path.
- `ui_persistence.serialize`: skip windows with
  `flags.no_saved_settings` after the `is_child` filter.

4 tests: defaults; `always_auto_resize` ignores user_resized +
matches content exactly (empty content → small; with text →
grows); `no_saved_settings` excludes window from serialized
payload; `always_auto_resize` ignores persisted size on first
frame.

### P5.3 — Focus + ordering ✅ SHIPPED turn 393

Four new bool fields on `WindowFlags`, all RESERVED slots today
(no behavioral wiring — zimr lacks the underlying mechanism for
each):
- `no_focus_on_appearing` — zimr doesn't auto-focus newly-
  appeared windows.  Wires when first-frame-detection lands.
- `no_bring_to_front_on_focus` — zimr renders windows in
  submission order with no internal z-order sort.  Wires when
  `last_focus_frame: u64` is added to `Window` and `endFrame`
  sorts `frame_windows` by it.
- `no_nav_focus` / `no_nav_inputs` — zimr has no keyboard-nav
  state machine.  Wires when nav lands.

Same precedent as `no_collapse` (P5.1) and
`always_use_window_padding` (P5.2): API surface ships forward;
behavior attaches automatically when the underlying feature
exists.  Doc-strings on each field call out the NO-OP status.

2 tests: defaults all false; flag propagation opts → Window.

### P5.4 — Input passthrough ✅ SHIPPED turn 394

Two new bool fields on `WindowFlags`:
- `no_mouse_inputs` — skip mouse-input claiming.  Hover doesn't
  land on this window, so all downstream click/drag/wheel logic
  passes through to whatever covered window is underneath.
- `no_inputs` — superset; today equivalent to `no_mouse_inputs`
  (no nav state yet); future-proof for keyboard nav.

Mechanism: `openWindow`'s hover-resolution block tests the mouse
position against the window's rect and unconditionally
overwrites `ctx.hovered_window_id`.  Submission order is
back-to-front (last overwriter wins).  The new gate:

```zig
const passthrough_mouse: bool = w.flags.no_mouse_inputs or w.flags.no_inputs;
if (!passthrough_mouse and mouse_inside_rect) {
    ctx.hovered_window_id = w.id;
}
```

That single skip is enough: every other interaction (title-drag,
resize, wheel, click) gates on `hovered_window_id == w.id`, so
a flagged window becomes mechanically see-through with no
further wiring.  Chrome rendering is independent of input — the
window still renders its bg, title, grip.

5 tests: defaults; flag propagation; **behavioral passthrough**
(two stacked windows, top one with `no_mouse_inputs`, bottom
keeps the hover); `no_inputs` superset has same effect; chrome
draws identically regardless of input flags.

### P5.5a — Menu bar + unsaved document marker ✅ SHIPPED turn 395

Two of the three pieces from the v6 P5.5 block; the third
(`horizontal_scrollbar` + accessors) gets its own turn (P5.5b).

- `menu_bar` — `beginMenuBar` returns false unless the parent
  window has this flag set.  Previously the bar opened
  unconditionally — a missing imgui contract.  **Migration**:
  3 sites in `examples/ui_window_menubar.zig` + 2 in-source
  tests (B3b cluster) updated to set `.flags = .{ .menu_bar = true }`.
- `unsaved_document` — render " *" marker after the title text.
  Pure visual; format `"{s} *"` into a 132-byte stack buffer
  (max title 128 + 3-char suffix + null term).  Falls back to
  plain name on `bufPrint` overflow.

5 tests: defaults; propagation; `beginMenuBar` returns false
without the flag; `beginMenuBar` returns true WITH the flag;
marker doesn't change chrome cmd count (just the title string
payload), with a format-step contract check confirming the
" *" suffix.

### P5.5b — Horizontal scrollbar + scroll accessors ✅ SHIPPED turn 396

Closes out the P5 wave with the horizontal-scroll piece that 5a/5b
was split to avoid bundling.

**New state**:
- `WindowFlags.horizontal_scrollbar` — opt-in (default false; without
  it X-overflow is silent, matching legacy behavior).
- `Window.scroll_x: f32`, `Window.scroll_max_x: f32` — analog of Y.
- `UiContext.mouse_wheel_x_consumed: bool` — independent of Y's
  consumption flag (axes consume separately so a Y-consumed inner
  child doesn't block outer X scroll).
- `InputSnapshot.mouse_wheel_x: f32` — populated from
  `runtime.input.getMouseWheelMoveV(state)[0]` (direct X axis, not
  the larger-magnitude pick that `getMouseWheelMove` does).

**Wiring** in `closeWindow`:
- `scroll_max_x` computed from `cursor_max.x - viewport_w` when
  flag set; clamped to 0 otherwise.
- Wheel-X consumption gated on flag + `!no_scrollbar` + hovered.
- `renderScrollbarX` called when `scroll_max_x > 0` + flag set
  + `!no_scrollbar`.

**`renderScrollbarX`** — straight mirror of `renderScrollbar`,
rotated 90°.  Track on bottom edge, with a 12px right-side gap
when the Y bar is also present so they don't visually collide.

**Three new public accessors** (slot in next to Y triplet):
- `pub fn getScrollX(self: Ui) f32` — current X scroll offset.
- `pub fn getScrollMaxX(self: Ui) f32` — last frame's max.
- `pub fn setScrollX(self: Ui, x: f32) void` — set + clamp.

7 tests: defaults; flag propagation; `scroll_max_x` stays 0
without flag (even on overflow); `scroll_max_x > 0` with flag +
overflow; wheel-X scrolls with flag, ignored without; accessor
round-trip with clamping; X+Y wheel consumption independent.

**Acceptance**: `examples/ui_window_flags.zig` — tour file with
each flag's behavior toggled live.

---

## 9. P6 — Layout/cursor query gaps (was F) ✅ SHIPPED turn 403

7 of 10 getters were already in zimr (`getCursorPos`,
`getCursorScreenPos`, `getContentRegionAvail`, `getItemRectMin`,
`getItemRectMax`, `getItemRectSize`, `getItemID`).  Turn 403
added the missing 3:

- `getCursorStartPos` — screen-space (matches zimr's cursor
  convention), returns `layout.origin`.  Differs from raw
  ImGui which uses window-local coords; documented in the
  docstring.
- `getWindowContentRegionMin` — window-local (matches ImGui),
  returns `layout.origin - window.pos`.
- `getWindowContentRegionMax` — window-local, returns
  `layout.work_rect_max - window.pos`.

+5 tests in `src/ui.zig` (outside-window fallback + populated-
window math for each).  +1 example call site in
`examples/imgui_demo.zig` ("Phase 4B - layout + disabled"
window) exercising all three getters live.

---

## 10. P7 — DrawListSplitter + table render channels (was G)

### P7.1 — `DrawListSplitter` primitive ✅ SHIPPED turn 404

`pub const DrawListSplitter` added to `src/ui.zig` (re-exported
as `z.DrawListSplitter`).  Lives in ui.zig next to `DrawList`
rather than `drawing.zig` because it operates on UI draw lists,
not rlgl-backed shape/texture primitives.

Surface:
- `channels: ArrayListUnmanaged(DrawList)` — side buffers.
- `current: usize` — active channel index.
- `split(alloc, n) !void` — allocate N channels, reset current.
- `setCurrentChannel(i) void` — switch active; clamps OOB.
- `getCurrentChannel() ?*DrawList` — null when no channels.
- `merge(alloc, target) !void` — concat in channel order, then
  empty channels (clearRetainingCapacity) for reuse.
- `deinit(alloc) void`.

API diverges from raw ImGui's `ImDrawListSplitter` by factoring
`target` out of `merge` (ImGui ties it to the owning draw list).
This lets callers merge channels into a different draw list than
the recording originated from — useful for composing into parent
windows.  Tables (P7.2) just pass the same window draw_list.

+8 tests: default-init / split / clamp / merge-respects-channel-
order (the keystone) / merge-empties-channels-for-reuse / re-split.

### P7.2 — Migrate tables to 2-channel render ✅ SHIPPED turn 405

`TableState` gains two fields: `splitter: DrawListSplitter`
(allocated in `beginTable`, 2 channels) and `saved_draw_list:
?*DrawList` (the `ctx.current_draw_list` value saved at
beginTable, restored at endTable).

Flow:
- **beginTable**: split(arena, 2); save current_draw_list;
  redirect `ctx.current_draw_list` to splitter channel 1
  (content).  On OOM, clear active_table and return false.
- **drawTableRowBg** + the per-row border line: write to
  channel 0 (bg layer).
- **tableNextRow** clip rect (scrollable tables): push to
  BOTH channels (clip → bg cmds → pop on channel 0;
  clip → content cmds → pop on channel 1).  Final merged
  stream: each cmd inside its respective clip pair.
- **endTable**: outer border, column dividers, scrollbar
  visual hint → channel 0.  Pop clip from both channels.
  Restore `ctx.current_draw_list`.  Merge splitter into the
  restored target dl.

Effect: cell backgrounds now paint UNDER cell content in the
final draw stream, regardless of left-to-right submission
interleave.  Pre-P7.2 the bg cmd was appended AFTER content
in the same draw list — workaround was a translucent bg tint.
Splitter makes fully-opaque bg colors render correctly.
This is the foundation P8.1 (`tableSetBgColor`) needs.

+3 tests: redirect contract at beginTable; keystone "bg index <
content index after endTable"; pre-existing cmds on target dl
survive the merge (APPEND, not REPLACE).

---

## 11. P8 — Table flag waves (was H)

Eight sub-steps.  Order forced by P7.2 dependency for P8.1.

### P8.1 cell + row bg colors ✅ SHIPPED turn 406

Per-cell bg overrides on top of the existing per-row override
(`tableSetRowBgColor`, retired pre-arc).  New surface:

- `TableColumnState.cell_bg_pending: ?Color = null` — one slot
  per column, set by `tableSetCellBgColor`, consumed at row
  finalization.
- `tableSetCellBgColor(color: Color)` — sets the pending override
  for the column just entered via `tableNextColumn`.  No-op
  outside a table or before any `tableNextColumn` for the
  current row.  alpha=0 is a clear-pending semantic (won't
  paint at flush time).
- `flushTableCellBgs(ctx, ts, y, h)` — internal helper, paints
  every pending cell bg to splitter channel 0 with the column's
  x/width and the row's now-known height.  Resets each
  `cell_bg_pending` after painting.  Called from `tableNextRow`
  (previous row's flush) and `endTable` (final row's flush).

Z-order in channel 0: row bg → cell bg → (channel 1 content
follows after merge).  Cell-level overrides win over row-level
visually but still land UNDER cell content.

+8 tests + acceptance demo: `examples/ui_tables_demo.zig`
"BuildBoard" table now colors the Status column per-cell based
on build state, on top of the existing per-row failure
highlight.  Visually demonstrates "cell bg paints over row bg,
under content."

### P8.2 borders_* family ✅ SHIPPED turn 407

The single `borders: bool` master flag is now AND-gated with
four granular sub-flags matching ImGui's `ImGuiTableFlags_Borders*`:

- `borders_inner_h` — per-row separator + header-bottom line.
- `borders_outer_h` — top + bottom edges of outer rect.
- `borders_inner_v` — column dividers + per-cell header right
  edges.
- `borders_outer_v` — left + right edges of outer rect.

All four default to `true` so the post-P8.2 visual matches
pre-P8.2.  `borders = false` overrides everything (backward
compat).  The outer-rect drawing path switched from a single
`addRectOutline` to 4 per-side `addLine` cmds so each edge can
be toggled independently.

+9 tests covering defaults, master override, per-side line
count for each granular flag (positive + negative pairs), and
the per-edge outer-rect emission shape.  Demo:
`examples/ui_tables_demo.zig` adds four checkboxes
("inner H / outer H / inner V / outer V") below the master
borders toggle.

### P8.3 row striping variants ✅ SHIPPED turn 408

Two padding-suppression flags landed on `TableOpts`:

- `no_pad_outer_x: bool = false` — when true, column 0's
  content sits at `col.x` (no `cell_padding_x` gap to the
  outer-left edge).
- `no_pad_inner_x: bool = false` — when true, columns 1..N-1
  have no `cell_padding_x` gap on their left side (content
  flush against the divider).

Both default false → cursor placement unchanged from pre-P8.3.
`tableNextColumnImpl` computes `left_pad` conditionally:
column 0 → outer flag; column 1..N-1 → inner flag.  Header
labels use the same conditional so header text stays aligned
with its column's data content.

Vertical padding (`cell_padding_y`) is unaffected by either
flag — same horizontal-only scope.

+7 tests covering defaults, outer-only, inner-only, both, and
the vertical-padding invariance.  Demo:
`examples/ui_tables_demo.zig` adds two checkboxes ("outer X /
inner X") below the border edges row.

### P8.4 sizing modes ✅ SHIPPED turn 412

`enum TableSizing` (fixed_fit / fixed_same / stretch_prop /
stretch_same) replacing the implicit auto-fit behavior.  Mirrors
imgui's `ImGuiTableFlags_Sizing*` family (imgui.h:2141-2144).
Per-column inheritance: `TableColumnOpts.sizing/weight` are
optional; null = inherit-from-table-policy.  Content-fit modes
use previous-frame measured widths from
`ctx.table_width_auto_cache`; first frame falls back to
`6 × style.font_size`.  See changelog turn 412.

### P8.5 scroll flags

`scroll_x`, `scroll_y` — explicit scroll axis selection
(currently zimr only does scroll_y when outer_height > 0).

### P8.6 `TableColumnFlags` wave

~18 flags, with `TableColumnSizing = enum`.

### P8.7 angled headers

Diagonal column header text for narrow columns.

### P8.8 table queries

`getColumnIndex`, `getColumnCount`, etc.

**Acceptance**: `ui_tables_demo.zig` exercises each batch.

---

## 12. P9 — InputText flag wave (was I)

### P9.1 — Character filters

`chars_decimal`, `chars_hexadecimal`, `chars_scientific`,
`chars_uppercase`, `chars_no_blank`.

### P9.2 — Behavior flags

`read_only`, `password`, `auto_select_all`,
`enter_returns_true`, `escape_clears_all`,
`ctrl_enter_for_new_line`, `allow_tab_input`,
`no_horizontal_scroll`, `always_overwrite`, `no_undo_redo`.

### P9.3 — Callbacks via opts

`callback_completion` (Tab), `callback_history` (arrows),
`callback_always`, `callback_char_filter`, `callback_resize`,
`callback_edit`.  Optional fn-pointer fields in opts.

---

## 13. P10 — ColorEdit flag wave + Color converters (was J)

### P10.1 — Picker variant enum + display format enum

`ColorPickerLayout = enum { hue_bar, hue_wheel }`.
`ColorEditFormat = enum { rgb, hsv, hex }` (the
mutually-exclusive display-format flags collapse here).

### P10.2 — Suppression flags

`no_picker`, `no_options`, `no_small_preview`, `no_inputs`,
`no_tooltip`, `no_label`, `no_side_preview`, `no_drag_drop`,
`no_border`.

### P10.3 — Alpha + HDR flags

`no_alpha`, `alpha_bar`, `alpha_preview`, `alpha_preview_half`,
`hdr`, `uint8`, `float`.

### P10.4 — Color converter methods

`Color.toHSV() Vector3`, `Color.toHsl() Vector3`,
`Color.fromHSV(h, s, v) Color`, `Color.fromHsl(h, s, l) Color`,
`Color.toU32() u32`, `Color.fromU32(u32) Color`, `Color.invert()
Color`.  Methods over imgui's bare functions for discoverability.

---

## 14. P11 — Selectable callback redesign (was K, scoped down)

v6's K.1 audited TreeNode and concluded its existing flag shape
is fine.  v7 just acts on K.2: split Selectable into
`(opts: SelectableOpts, behavior: SelectableBehavior)`:

```zig
behavior: SelectableBehavior = .{
    .on_click = null,
    .on_double_click = null,
    .on_right_click = null,
}
```

Behavioral flags read like state machines; callbacks are
immediate and explicit.  Sweep examples that use
`allow_double_click`.  Old flag-only path stays available.

---

## 15. P12 — Drag/Slider drag2/3/4 (was L)

### P12.1 — Range-in-opts audit

`u.drag(label, v, opts)` opts has min/max with `anytype`-inferred
numeric type.  Sweep call sites for consistency.

### P12.2 — DragN / SliderN

`u.drag(label, &v: *@Vector(N, f32), opts)` → comptime-detect
vector type → loop axes.  Per-axis ranges:
`opts.min: [N]?f32 = .{null} ** N` (null = unclamped).

---

## 16. P13 — MultiSelect completeness (was M)

### P13.1 — Nested scopes

Today `current_multi_select` is single-slot.  Stack it (~15 LOC
in begin/end).

### P13.2 — Shift-click range + ctrl-click toggle

Imgui's `BoxSelect` + Anchor handling
(`imgui_widgets.cpp:~8200`).  Acceptance: 50-item example where
shift-click picks a range.

---

## 17. P14 — Logging family (was N)

`logToConsole`, `logToClipboard`, `logText`, `logFinish`,
`logSetNextTextDecoration`, `logButtons`.

`LogState = struct { active: bool = false, target: enum {
console, clipboard, buffer }, buffer:
std.ArrayListUnmanaged(u8) = .empty }`.  Wire text-rendering
sites to also `logText` if `active`.  Imgui reference:
`imgui.cpp:~12900` `LogToTTY` etc.

---

## 18. P15 — show* family closeout (was O)

The user-facing dev tool widgets.  Thanks to P1 most are tiny:

- `showStyleEditor` → `u.inspect("Style", &ctx.style)`.  1 LOC.
- `showMetricsWindow` → `u.inspect("Metrics", &ctx.metrics)`
  + plot history.  ~10 LOC.
- `showDebugLogWindow` — viewer over P2.1 ring buffer.  ~30 LOC.
- `showAboutWindow` — version + build config + links.  ~30 LOC.
- `showStyleSelector` — combo + preset apply (P4.2).  ~5 LOC.
- `showFontSelector` — cycle through loaded fonts.  ~10 LOC.
- `showUserGuide` — static help text.

---

## 19. P16 — Outliers + checkboxFlags (was P)

### P16.1 — KeyboardKey expansion audit

Imgui has ~147 `ImGuiKey_*` values.  Verify zimr's Key enum
coverage.  Likely add: keypad_* family, nav_* keys.  Skip
reserved_*.

### P16.2 — Popup variants

`beginPopupContextWindow`, `beginPopupContextVoid`,
`openPopupOnItemClick` — companions to shipped
`beginPopupContextItem`.

### P16.3 — `checkboxFlags(label, flags: *FlagStruct, mask: FlagStruct)`

Checkbox that toggles one bit of a flag struct.

---

## 20. P17 — Compile-time validation (was Q, AM-11)

### P17.1 — Format-string + args validation

`u.text("foo {d} bar {s}", .{42, "x"})` — comptime-check format
+ args tuple arity / type alignment.  Lift `std.fmt.comptimePrint`
logic into the widget surface.

### P17.2 — Range checks where comptime-knowable

`u.drag("x", v, .{ .min = 5, .max = 3 })` with both literals →
`@compileError`.

### P17.3 — Drag-drop registration audit

If `beginDragDropSource` submits a `T` payload with no matching
`acceptDragDropPayload(T)` anywhere → tooling pass, not a
comptime check.

---

## 21. P18 — Capstone polish + archive (was R)

### P18.1 — `ui_full_showcase` tab polish

Each tab gets a consistent-style once-over; demo every shipped
feature.

### P18.2 — Performance pass (deferred ambition marker)

If energy remains: per-window draw-list hash + skip GL submission
on unchanged frames.  Only ship if measurable.

### P18.3 — Plan archive + cheatsheet regen

Move v7 to `archive/`, update top-level `PLAN.md`, regenerate
`CHEATSHEET.md`.

### P18.4 — Arc-close changelog entry

Single entry summarizing the whole arc.

---

## 22. What stays deferred forever (unchanged from v6 §20)

- Multi-viewport / OS-window detachment (browser-incompatible)
- WindowClass typed docking (sparse imgui adoption)
- AutoHideTabBar / DockSpaceOverViewport / DockBuilderCopyNode
- OS cursor changes during drag (low ROI)
- Floating dock node as host with tab bar
  (drag-detach already goes to bare floating window)
- Allocator hooks (Zig threads allocators natively)
- va_list V-variants (Zig has comptime varargs)
- IME hooks (browser handles via input element)
- Live style editor with hot-reload beyond imgui parity
- Multi-finger gesture vocabulary beyond long-press
- ID-stack breadcrumbs (v7 §1.4: defer until needed)
- Layout-lint framework module (v7 §1.3: just five named asserts)

---

## 23. Cross-cutting policies (carried from v6 §21)

Build-breakage policy: build can break mid-turn if it leads to
a cleaner final state.  Green at turn END.

API breaking-change policy: pre-arc-close, breaks encouraged.
No deprecation warnings until P18.3 ships.

Per-step deliverables: code in `src/<module>.zig` with the 14
style rules; host unit tests for each new public API; demo per
mixed granularity (standout features get their own file; flag
waves get one tour per phase; `ui_full_showcase` grows tabs
alongside); each demo registered in `build.zig` +
`manifest.json`.

---

## 24. Decision log (turn 383)

- **D-before-B reorder**: reflection inspector promoted to P1.
  Multiple later phases (Metrics viewer, showStyleEditor,
  dev-tools demo) collapse to one-liners.  v6 had D after B to
  "grow eyes before experimenting"; v7 trusts that the inspector
  is comptime dispatch and its bugs are compile errors.
- **Phase A dropped**: its three steps fold into the Prelude
  (dock_persistence + showcase Docking tab) and P18 (archive).
- **Layout lint demoted**: five named asserts, not a framework.
  Re-promote if a sixth case emerges.
- **ID-stack breadcrumbs deferred**: useful but unproven.  380
  turns and no `getId() == 0` mystery.
- **Long-press its own phase**: independent, single turn, no
  reason to bury inside dev tools.

---

## 25. Estimated arc close

~45 steps as listed.  Average ~1.5 steps/turn → **~25-30 turns**
to arc close.

The Prelude is turn 383.  P1 (reflection inspector) is turns
384-387.  Then flag-wave phases move 2-5 turns each.
