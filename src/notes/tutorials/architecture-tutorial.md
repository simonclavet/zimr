# architecture-tutorial.md — zimr's UI engine, end-to-end

Written turn 313.  Companion to `imgui-plan-v5.md`.  Where the plan
says "what to build", this says "what's there".  Read this when:

- You're picking up a fresh session and need to orient.
- You're about to add a new widget and don't know where state lives.
- You hit a layout bug and need to figure out which scope is wrong.
- You're explaining the engine to someone (or to yourself in 6 months).

---

## 0. The 30-second elevator pitch

zimr's `src/ui.zig` is a Zig port of Dear ImGui.  Same immediate-mode
paradigm — user writes `if (ui.button("Save")) save();` every frame
and zimr handles rendering, hit-testing, focus, persistence, the
whole stack.  Wasm-only, WebGL2-only, ~21,600 lines, no C deps.

Public API: `Ui` (a thin wrapper over `*UiContext` — all methods are
on `Ui`).  Lifecycle: user creates one `UiContext`, calls
`beginFrame` each rAF tick, submits widgets, `endFrame` flushes draw
calls to GL.

Three big differences from imgui:
1. Struct-of-bools instead of bit-flag enums (`WindowFlags { is_child: bool }`).
2. Opts-arg, not Ex-variants (`button(label, opts: ButtonOpts = .{})`).
3. Children are full `Window`s, not in-place state pushes (turn 309d).

---

## 1. File layout

```
src/ui.zig                    21,600 lines.  The entire UI engine.
src/web.zig                       extern "dom" decls (overlay input etc).
src/runtime/input.zig             Input state, dispatched into ui via beginFrame.
src/drawing.zig                   Lower-level draw primitives + text rendering.
src/rlgl.zig                      OpenGL state machine (immediate-mode wrapper).
src/web/zimr.ts                   TypeScript runtime (DOM/WebGL/audio bindings).
examples/ui_*.zig                 ~30 ui demos.  ui_panes.zig is current showcase.
examples/imgui_demo.zig           kitchen-sink demo, mirrors imgui_demo.cpp.
webtests/smoke.ts                 Bun-based wasm smoke harness (105 wasms).
src/notes/imgui-plan-v5.md        This-arc plan.
src/notes/architecture-tutorial.md  THIS FILE.
src/notes/claude.md               Style rules + per-turn rhythm.
src/notes/changelogs/             One file per decade of turns.
```

`ui.zig` is a single big file by design.  Splitting it into widget
files would hide the `UiContext`-as-shared-state pattern that makes
imgui-style immediate mode work.  Use section banners (the
`// ============================================================================`
comments) to navigate; grep is your friend.

---

## 2. Core types — one diagram

```
UiContext  (one per running ui)
├── windows: HashMap(Id, *Window)           — persists across frames
├── current_window: ?*Window                — top of window_stack
├── window_stack: BoundedStack(*Window, 8)  — push at openWindow/beginChild
├── id_stack: BoundedStack(Id, 32)          — parallel stack for widget IDs
├── input: InputSnapshot                    — frozen per-frame view of input
├── style: Style                            — colors, padding, font, etc.
├── gpa, frame_arena                        — allocator infrastructure
├── frame_count, canvas_w, canvas_h
├── hovered_window_id, focused_window_id    — top-level window tracking
├── active_id, active_id_press_value        — current "I am interacted with" id
├── hovered_id, hovered_id_prev_frame       — last-frame hover for ItemHovered
├── mouse_wheel_consumed                    — LIFO wheel routing flag
├── drag_drop: DragDropState                — drag source/payload/target
├── input_text_state: InputTextState        — active inputText edit state
├── frame_popups: ArrayList(*Window)        — popups submitted this frame
├── popup_open: HashMap(Id, PopupState)     — open popups persist
├── pending_tooltip: ?TooltipData
├── group_stack: BoundedStack(GroupState, 8)
├── ms_state: HashMap(Id, MultiSelectState) — multi-select per scope
├── ms_active_scope: ?MultiSelectScope
└── ... (a few more — see UiContext defn near line 1900)

Window  (persistent, in ctx.windows)
├── id: Id                                  — hash of name (top) or parent+str_id (child)
├── name_buf, name_len                      — debug name (e.g. "child:abcd1234")
├── pos: Vector2                            — screen coords of top-left
├── size: Vector2                           — outer rect dims
├── flags: WindowFlags                      — is_child today; popup/modal/dock later
├── parent_id: ?Id                          — set on children
├── scroll_y, scroll_max_y: f32             — per-window scroll
├── focused, collapsed, user_resized: bool
├── layout: LayoutScope                     — per-frame layout state (next section)
├── draw_list: DrawList                     — per-window cmd queue
├── clip_rect_stack: ArrayList(Rectangle)
└── last_frame_active: u64                  — for future GC

LayoutScope  (lives on Window.layout, reset at openWindow / beginChild)
├── origin: Vector2                         — top-left of content area
├── work_rect_max: Vector2                  — bottom-right of content area
├── cursor_pos: Vector2                     — where the NEXT widget goes
├── cursor_max: Vector2                     — running bottom-right of laid-out content
├── cursor_pos_prev_line: Vector2           — for sameLine
├── line_height, prev_line_height: f32
├── indent_x: f32                           — TreeNode push depth
└── last_item_*: id/rect/hovered/edited/clicked  — for IsItemHovered etc.
```

**The two pointer types you'll see most:**
- `*UiContext` — global engine state, always passed around as the
  first arg or accessed via `self.ctx`.
- `*Window` — the current scope.  `ctx.current_window` is the
  active one; widgets read/write `current_window.layout`.

---

## 3. Lifecycle — one frame

```
                  User's update(f, state):
                  │
                  ▼
        ┌─────────────────────┐
        │ ctx.beginFrame(f)   │ Build InputSnapshot, reset per-frame state,
        │                     │ tick drag-drop FSM, drain char queue.
        └─────┬───────────────┘ Returns a Ui struct (just wraps ctx).
              │
              ▼
        ┌─────────────────────┐
        │ ui.window("name")   │ findOrCreateWindow → push window_stack,
        │   ?WindowHandle     │ install fresh layout, render chrome,
        └─────┬───────────────┘ push content clip rect.  Returns
              │                  WindowHandle or null if cancelled.
              ▼
        ┌─────────────────────┐
        │ ui.button("OK")     │ widget fns:
        │ ui.checkbox(...)    │   1. compute id via widgetId(label)
        │ ui.beginChild(...)  │   2. resolve cursor pos via resolveCursor
        │   { ... children }  │   3. hit-test, draw to draw_list
        │   ui.endChild()     │   4. advanceLayout(consumed, item_spacing)
        │ ui.sameLine()       │   5. set last_item_* on current scope's layout
        └─────┬───────────────┘
              │
              ▼
        ┌─────────────────────┐
        │ h.close()           │ closeWindow → compute scroll_max,
        │                     │ apply wheel if hovered + not consumed,
        └─────┬───────────────┘ pop clip, render scrollbar, pop window_stack.
              │
              ▼
        ┌─────────────────────┐
        │ (more windows)      │ Each window has its own draw_list;
        │                     │ they're independent.
        └─────┬───────────────┘
              │
              ▼
        ┌─────────────────────┐
        │ ctx.endFrame()      │ render popups, tooltips, drag previews,
        │                     │ then replay every window's draw_list to GL
        └─────────────────────┘ in submission order (back to front).
```

The user code looks like:
```zig
fn update(f: *z.Frame, s: *State) void {
    const ui: Ui = s.ui_ctx.beginFrame(f, &s.shapes, &s.font_cache);
    if (ui.window("MyApp", .{}) ) |h| {
        defer h.close();
        if (ui.button("Save", .{})) saveDoc(s);
        ui.text("Hello, world.");
    }
    s.ui_ctx.endFrame();
}
```

That's the whole user-facing pattern.

---

## 4. Coordinate spaces — three of them

Mixing these is the #1 source of "tap doesn't align" bugs.  Full
reference: `claude.md` "Coordinate systems" section.

| Space        | Where used                              | DPR=3 phone (CSS 360w) |
| ------------ | --------------------------------------- | ---------------------- |
| CSS pixel    | DOM, mouse events, `event.clientX`      | 360                    |
| Backing px   | `canvas.width`, GL viewport             | 1080 = 360 × DPR       |
| Logical px   | wasm widget code, `Window.pos`, hit-tests | depends on `cfg.window.scale` |

zimr defaults to `.responsive` mode where logical px == CSS px.
Mouse input arrives in CSS px and goes directly to layout math
unchanged.  In `.stretch` mode (legacy) logical pixels are
init-time canvas dims and mouse input doesn't get rescaled —
silent hit-test bug if `canvas.clientWidth != cfg.window.width`.

**Rule of thumb:** when adding a feature, use `.responsive`.  If a
demo needs `.stretch`, audit the hit-test math against the
coordinate table.

---

## 5. The widget pattern

Every widget follows the same five-step recipe:

```zig
pub fn button(self: Ui, label: []const u8, opts: ButtonOpts) bool {
    const ctx: *UiContext = self.ctx;
    const w: *Window = ctx.current_window orelse return false;

    // 1. Compute ID (hash of label scoped by id_stack).
    const id: Id = widgetId(ctx, w, label);

    // 2. Resolve cursor → screen position.  This handles sameLine,
    //    indent, etc.  Returns the top-left where this widget will
    //    land.
    const at: Vector2 = resolveCursor(w, ctx.style.item_spacing[0]);

    // 3. Compute the widget's rect.  Most widgets compute their
    //    size from text-measure + padding.
    const text_size: Vector2 = measureTextS(ctx, label);
    const size: Vector2 = .{
        text_size[0] + 2 * ctx.style.frame_padding[0],
        text_size[1] + 2 * ctx.style.frame_padding[1],
    };
    const rect: Rectangle = .{ .x = at[0], .y = at[1], .width = size[0], .height = size[1] };

    // 4. Hit-test + state update.  Checks mouse pos against rect;
    //    updates ctx.active_id on click, ctx.hovered_id on hover.
    const interaction: ButtonInteraction = buttonBehavior(ctx, id, rect);

    // 5. Render — append cmds to the current draw list.
    drawRectFilled(ctx, rect, colorForState(ctx, interaction));
    drawText(ctx, .{ at[0] + frame_padding[0], at[1] + frame_padding[1] }, label, ctx.style.text);

    // 6. Advance the layout cursor + bookkeep last_item_*.
    advanceLayout(w, size, ctx.style.item_spacing, ctx.style.window_padding[0]);
    w.layout.last_item_id = id;
    w.layout.last_item_rect = rect;
    w.layout.last_item_hovered = pointInRect(ctx.input.mouse_pos, rect);

    return interaction.clicked;
}
```

Every widget you read or add follows this shape.  Variations:
- Composite widgets call other widgets in their body (e.g.
  `dragFloat` is `button` + `inputText` + click-drag handling).
- Stateful widgets (combo, popup, tree) read/write
  `ctx.combo_open_id`, `ctx.popup_open`, etc.
- Scope-opening widgets (window, beginChild, beginGroup,
  beginPopup, beginMenu) push state onto the relevant stack.

---

## 6. ID hashing — how widgets stay distinct

Imgui's ID system is the trick that makes the immediate-mode
illusion work.  zimr inherits it:

- Every widget call generates an `Id` by hashing its label/str_id
  against the current `id_stack` top.
- `id_stack` is pushed at every scope-opener: `openWindow` pushes
  the window's id, `beginChild` pushes the child's id, `treeNode`
  pushes the node's id, `pushId` lets users push manually.
- Two `button("Save")` calls under the same window get the same
  ID — bug.  Disambiguate via `pushId(i)` in a loop, or use a
  unique label per call.

The hash function: FNV-1a over the bytes, seeded with the
id_stack top.  See `hashStr` near line 2700.

---

## 7. Drawing — DrawList commands

`Window.draw_list` is an `std.MultiArrayList(Cmd)` where each
`Cmd` is a tagged union:
- `rect`, `rect_filled` — frame_padding boxes, scroll tracks
- `text` — glyph runs (drawing.zig handles the actual rasterization)
- `image` — texture quads
- `push_clip`, `pop_clip` — scissor stack
- `line`, `circle`, `triangle` — primitives
- `convex_poly` — for arrows, slider grips

At `endFrame`, we walk each window's draw_list in order,
translating commands into GL state changes via `drawing.zig`
helpers (which themselves talk to `rlgl.zig`).

**Why per-window draw lists:** keeps render order independent of
submission order.  Within a window, later widgets draw over earlier
ones; between windows, focused window's content draws on top.
(Imgui has the same scheme; we copied it.)

---

## 8. State that survives across frames

| What                            | Where                              |
| ------------------------------- | ---------------------------------- |
| Windows (pos, size, scroll)     | `ctx.windows` HashMap              |
| Open popups                     | `ctx.popup_open` HashMap           |
| Open combos                     | `ctx.combo_open_id`                |
| Open tree nodes                 | `ctx.tree_open` HashMap            |
| Last-focused id                 | `ctx.focused_window_id`            |
| Last-hovered id                 | `ctx.hovered_id_prev_frame`        |
| Input text state                | `ctx.input_text_state`             |
| Multi-select per scope          | `ctx.ms_state` HashMap             |
| Drag-drop payload mid-drag      | `ctx.drag_drop.payload_bytes`      |
| ...                             | ...                                |

The pattern: persistent state lives on `UiContext`, keyed by
hashed `Id`.  Per-frame state lives in `frame_arena` (reset at
beginFrame).

---

## 9. Where we are in the plan

Cross-reference: `imgui-plan-v5.md` §1 has the phase-by-phase
status table.  Quick summary as of turn 313:

**Done:**
- Phase A (foundation) ✅
- Phase B (input polish) ✅
- **All of Phase 1** ✅ (text helpers, TextFilter, MultiSelect,
  Splitter, TreeNode, child-window scroll, phone keyboard, DOM
  overlay).
- **Step 1.5.5** ✅ (LayoutScope refactor + child-as-Window).
- **Step 3.5a** ✅ (HoveredFlags + FocusedFlags window-traversal).

**Next sprint — pre-docking:**
1. **3.5b** — `ChildFlags` + opts-arg sweep (kill `*Ex` variants).
   Build can be broken mid-turn.  ~25 callsites for hover/focus
   migration + new `BeginChildOpts` → `ChildFlags`.
2. **3.6** — `TabBar` widget.  ~3-4 turns.
3. **3.7** — `DragDropFlags` + `ItemFlags` (drag-drop polish).
   Includes `disabled` + `allow_overlap` cross-widget flags.
4. **5.1** — Persistence (`.zon` + localStorage).  The
   "we did it better than imgui" moment.

**Then the milestone:**
5. **5.5** — DOCKING.  8-15 turns.  Dock node tree, drag-drop
   targets, persistence integration, TabBar at leaves.

**After docking:**
- Phase 2 (Dev tools — pulled BACK to here because they have
  more to debug post-docking).
- Phase 3 remaining (WindowFlags, TableFlags,
  InputTextFlags+ColorEditFlags, TreeNode/Selectable/Slider/Button).
- Phase 4 (table queries, cursor gaps, Color methods, KeyboardKey
  expansion, theme presets, show* family, Zig 0.16 ceremony
  cleanup).
- Phase 5 (Logging family, DrawListSplitter).
- Phase 6 (capstone close, arc archive).

**Estimated arc-close:** 40-60 turns from here.

---

## 10. Pitfalls you'll hit

Things that confused me / will confuse you.

### 10.1 `current_window` vs `window_stack` top

They're the same pointer.  Helpers use `ctx.current_window orelse return`;
some internal code reads `ctx.window_stack.items[ctx.window_stack.len-1]`
directly.  Both forms appear; prefer `current_window`.

### 10.2 `cursor_pos` is in SCROLLED coordinates

When a window has `scroll_y > 0`, the `cursor_pos.y` for in-scope
widgets is `inner_origin.y - scroll_y` plus the running offset.
That means a widget at "line 50 of a scrolled list" has a
`cursor_pos.y` that may be NEGATIVE (above the visible area).
Clipping handles this via `push_clip`/`pop_clip`.

When endFrame computes `scroll_max_y`, it un-shifts:
`content_h_natural = cursor_max.y + scroll_y - origin.y`.

### 10.3 Children advance their PARENT's cursor

`endChild` calls `advanceLayout` on the parent's layout, NOT the
child's.  The parent's cursor moves past the child's outer rect so
the next widget after `endChild` sits below it.

### 10.4 The Drag-drop FSM has weird timing

Drag state transitions `.idle → .pending → .active → (releases stay
.active for one frame so the drop target can read the payload) →
.idle`.  The "one frame after release" is intentional — it's how
targets see the payload at the moment of drop.  See drag-drop FSM
notes near line 2620.

### 10.5 `hovered_window_id` doesn't track children

It's set in `openWindow` (top-level only).  For child-window
hover, use `pointInRect(mouse_pos, child.outer_rect)` directly or
`isWindowHovered(.{ .child_windows = true })` which walks parent_id.

### 10.6 The `treeNode` push pattern

`treeNode` mutates BOTH `indent_x` and `cursor_pos.x`.
`treePop` only un-mutates `indent_x` and lets `advanceLayout` reset
`cursor_pos.x` to `origin + indent_x` next-line.  This caused a
bug in turn 308; the v3 plan called out "treePop bug" for a reason.

### 10.7 Smoke harness lacks some bindings

`webtests/smoke.ts` stubs the dom/webgl/audio externs the wasm
expects.  Turn 311 added overlay-input stubs.  If you add a new
extern in `src/web.zig`, **add the matching stub in smoke.ts** or
5 examples will start failing the same way.

---

## 11. How to add a new widget — checklist

Working through this list keeps the surface uniform:

1. **Read the imgui source.**  `/tmp/imgui-master/`.  Cite line
   refs in your comment.
2. **Define `FooOpts`** (no `xxxEx` variants — Rule 14).  Default
   values for everything.  Struct-of-bools for flag-like fields.
3. **Add `pub fn foo(self: Ui, ..., opts: FooOpts = .{}) ReturnT`**
   on the `Ui` namespace.
4. **Follow the 5-step pattern** (§5): id → cursor → rect →
   behavior → render → advance.
5. **Add unit tests** in the test block at end of ui.zig.  Use
   `testMakeUiCtxWithWindow` for fixtures.
6. **Add a demo or extend an existing one.**  Register in
   `build.zig` + `manifest.json` if new.
7. **Run audit gate:** `zig build test`, focused smoke.
8. **Standalone build** the most relevant demo, present_files it.
9. **Changelog entry.**
10. **Update plan** if you closed a step.

---

## 12. Where docs live

- **Plan**: `src/notes/imgui-plan-v5.md`
- **This file**: `src/notes/architecture-tutorial.md`
- **Style + per-turn rhythm**: `src/notes/claude.md`
- **History (long-form rationale)**: `src/notes/claude_long.md`
- **Imgui-vs-zimr architecture**: `src/notes/architecture-imgui-vs-zimr.md`
- **Step-specific tutorials**: `src/notes/*-tutorial.md`
  (multiselect, layout-bug-arc, etc.)
- **Changelog**: `src/notes/changelogs/changelog<NNN-MMM>.md`,
  one per decade of turns.
- **Archive**: `src/notes/archive/` — superseded plans + notes.

When in doubt: grep `src/notes/`.

---

## End

If something in the engine confused you while reading this,
**that's a candidate for an addition**.  This file is yours to
edit.  Keep it dense + actionable.
