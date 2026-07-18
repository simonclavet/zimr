# imgui-plan-v6.md — finishing the imgui port (drafted turn 335)

**Status at draft time:** 1555 unit tests pass, 87 wasm examples,
`src/ui.zig` is ~25,500 lines.  The docking arc (5.5) shipped
turns 319-334; the font-default sweep landed turn 335.  Only 5.5l
demo polish remains from plan v5.  This v6 supersedes v5.  v5
stays in `archive/` for arc-history reference.

---

## Working agreement (read this every turn)

Compressed from `src/notes/claude.md`.  Full version: re-read
claude.md when (a) Simon asks a meta question, (b) a rule's been
bent twice in recent turns, (c) opening an arc touching infra
you haven't worked on in a while, or (d) ~10 turns since last
re-read.

### Per-turn rhythm (non-negotiable)

1. **Save zip** — last action, every turn:
   `/mnt/user-data/outputs/zimr-turn-<N>.zip` → `present_files`.
2. **Prune snapshots** — keep multiples of 5 + 5 most recent
   DISTINCT turn numbers in `/mnt/user-data/outputs/`.  Mid-arc
   suffixes (335a/335b) count as the SAME turn.
3. **Changelog** — prepend the turn's entry to `## [Unreleased]`
   in the active `src/notes/changelogs/changelog<NNN-MMM>.md`.
   Decade rollover (340, 350) → new file.
4. **Update active plan** — mark steps done in this file.
   Finished plan → `archive/`, update `src/notes/PLAN.md`.
5. **Audit gate** ↓.

### Audit gate

- **Every turn:** `zig build test` — must be GREEN at the END.
  Can be RED mid-turn during a sweep.  ~7s warm.
- **Every 3rd turn / arc close / visually-verified zip:**
  `zig build smoke-test --release=small -Dfocus=<arc>` (~1s warm).
- **Full smoke** (`zig build smoke-test --release=small`, ~30s):
  arc-close turns only, OR when a cross-arc invariant changes
  (input dispatch shape, draw-list cmd set, extern surface,
  Window/Frame public API).
- ❌ NOT `zig build install` (~3min cold; rebuilds all wasms).
- ❌ NOT smoke-test without `--release=small` (clobbers ReleaseSmall).

### Standalone HTML build (the script)

When a turn ships a feature worth visual verification on phone:

```
zig build install --release=small        # warm: ~1s.  Cold: ~50s.
python3 scripts/build_standalone.py <example> [--title "..."]
cp prebuilt/standalone/<example>.html /mnt/user-data/outputs/
# then present_files the .html alongside the zip
```

`build_standalone.py` self-heals if smoke clobbered ReleaseSmall
(wasted work but not broken).  The `<example>` arg is the
example name minus `.zig` (e.g. `ui_dock_basic`, `imgui_demo`).
Bundle output line tells you the wasm size + final bundle size.

**Don't `present_files` an .html you haven't verified** — at
minimum grep for obvious failure modes (undefined exports,
unused-but-needed externs) and scan build output for warnings.
Simon's iteration loop is slow; a broken standalone burns a
round-trip.

### Style rules (one line each)

1. 3+ fn args: one-per-line + trailing comma.  No exceptions.
2. Locals: explicit types.  See an untyped local → add one.
3. Braces on every branch.
4. Casual comments.  Banners (`// ===== Section =====`) are
   encouraged in long files.
5. `@splat(N)` for arrays-of-N-copies.  `**` is gone.
6. Lift magic literals at 2+ call sites.
7. Lift complex sub-exprs out of conditions.
8. Helpers only when name does real work + 2nd caller exists.
9. No mutable module globals (2 C-ABI exceptions in `zimr.zig`
   + `runtime_assembly.zig`).
10. Lines ≤ 120 cols (markdown exempt).
11. `i32` signed, `usize` non-negative.  No `c_int`/`c_uint`.
12. Never read a var in the same literal that overwrites it.
13. `extern struct` only at real FFI seams.
14. **Opts-arg, not `xxxEx` variants.**  Single fn with `opts:
    FooOpts = .{}`.  No dual API unless type signatures
    genuinely differ.

**Touching a fn = bringing the whole fn up to spec.**
**Every line you touch must become clearer** — add asserts,
comments, logs that make future bugs impossible.

### Zig 0.16 idioms (verified)

- `@floor(int * scale)` returns int directly when slot is int.
  Use for pixel math — clearer than `@intFromFloat(@as(f32,
  @floatFromInt(x)) * s)`.
- `@as(T, @intCast(x))` → `@intCast(x)` in typed slots.
- `@as(T, @floatFromInt(x))` → `@floatFromInt(x)` ditto.
- Implicit `int → f32` ONLY for lossless widths (i16/u8/u16).
- Binary ops don't propagate result-location to operands.
  Wrapping in `@floor`/`@intFromFloat`/`@sqrt` DOES.
- `std.math.clamp(val, lo, hi)` over nested `@max`/`@min`.

Full reference: `src/notes/zig-0.16-migration-guide.md`.

### Build-breakage policy

Build CAN be red mid-turn if it leads to a cleaner final state.
Must be GREEN at turn END.  Unblocks: API-shape sweeps where
every callsite breaks until they all migrate, type refactors,
trait-narrowing changes.  Big single-turn sweeps over multi-turn
compat-shim sequences.

### Ambition policy

When the plan suggests "make the change that won't break
anything" vs "make the best possible system" — prefer the
latter.  Plans are yours to amend.  Push back on the plan when
it constrains making the system better.  Read upstream imgui's
actual source for canonical behavior; apply Zig idioms
aggressively; document divergence + rationale.

### Working with Simon

Casual.  Push back when he's wrong.  Show life when something
cracks open.  Refer to him by name.  Reply pattern: brief
recap → audit numbers → flagged choices → **next turn:** one
explicit sentence → `present_files` zip + any HTML.

**Rubberducking:** one question per reply, 2-4 concrete options,
explicit recommendation, then we discuss.  Never batch 5
questions at once.

### Sharp edges (full list in `claude_long.md §15`)

- Smoke without `--release=small` → ReleaseSmall clobbered → 4×
  bloated standalones.
- Stable test count ≠ healthy.  "Pending" tests usually aren't.
- `const zm = @import("math.zig")` in lib code;
  `const zm = z.math` in examples.
- Three pixel kinds in flight (CSS / backing / logical).  Read
  claude.md Coordinate systems section before touching
  positioning code.

### Self-improvement

`claude.md` and `claude_long.md` are yours to edit.  Learn
something a future Claude would benefit from — write it down.
Dense bits → claude.md, rationale + history → claude_long.md.
**The arc compounds.**

---

## 0. What this arc is, revised

**Full ImGui feature parity for the wasm subset, expressed in
idiomatic Zig**, plus targeted *system-level improvements* on
top, in the order that most increases the codebase's clarity
and power per turn invested.

The arc is **not** an API-stability arc.  Simon is the only user
today.  Breaking changes that produce a cleaner system are
encouraged.  Once the arc closes and `ui_full_showcase` ships,
THAT's the API stability boundary.

### Goal restated (turn 335)

> "A really clean and powerful codebase that humans and AI will
> like and understand."

Every step below is evaluated against that lens.  Where I have a
choice between "ship X earlier so I have it as a tool for Y" and
"ship X in feature order," I pick the former.  The codebase grows
the eyes it needs to see itself before it grows the rest.

### Source-of-truth policy (unchanged from v5)

The C++ source of ImGui master + docking branch is the reference
implementation.  Defaults: do what ImGui does.  Divergences are
allowed but must be documented in a code comment and (if
substantial) in this plan.  Valid reasons to diverge:

- **Zig idiomatic** — struct-of-bools flags, `opts` arg over
  Ex-variants, `union(enum)` over C tag+payload.
- **Simplicity** — when ImGui's complexity reflects historical
  burden (e.g. `Want*` transient state machine).
- **Browser/mobile reality** — multi-viewport, OS cursor changes,
  IME hooks.
- **Comptime superpower** — when Zig's comptime offers a cleaner
  user-facing API (typed drag-drop payloads, comptime-validated
  format strings).

### Ambition markers — system improvements over ImGui

Marked **[AM-N]** below.  These are not separate features —
they are how we ship parity.

1. **[AM-1] Struct-of-bools flags.**  Each ImGui bit-flag enum
   becomes a Zig struct with named bool fields.  Mostly executed.
   Will be the default for every flag wave in this plan.
2. **[AM-2] Opts-arg, not Ex-variants.**  Single function with
   `opts: FooOpts = .{}`.  Mostly executed.  Continued sweep.
3. **[AM-3] `.zon` + localStorage persistence.**  Done (window
   state + dock tree).  Extended in Phase C to style.
4. **[AM-4] Typed Key/MouseButton.**  Done pre-arc.
5. **[AM-5] Long-press → right-click on touch.**  Phase B step.
6. **[AM-6] Capstone updated incrementally.**  Each phase
   boundary adds one tab to `ui_full_showcase`.
7. **[AM-7] `Value(label, anytype)` + Color methods.**  Done.
8. **[AM-8] Reflection inspector (NEW).**  `u.inspect(label,
   &any_struct)` auto-generates a property panel via `@typeInfo`.
   Used internally to make `showStyleEditor` ~10 LOC.  Phase D.
9. **[AM-9] Layout linting (NEW).**  One-shot module-level warns
   for common bugs: dragRange min>=max, zero-width column, popup
   double-open, ID collision, content overflowing window.  Phase
   B.
10. **[AM-10] Type-safe drag-drop payloads (NEW, already shipped).**
    `acceptDragDropPayload(comptime T)` returns `?T` directly.
    No string keys, no casts.  Already done; documented here as a
    marker because the design choice was deliberate.
11. **[AM-11] Compile-time widget validation (NEW).**  Where
    runtime asserts can become compile errors (mismatched min/max
    types, dragRange with min > max at comptime, format-string
    arity), sweep them.  Phase O.

---

## 1. Phase layout

Phases ordered for impact-per-turn given the "humans and AI
understand the codebase" lens.  Steps within a phase can be
turns or fractions of turns.  Larger steps split when executed.

```
A. Close docking arc          5.5l only        ~1 step
B. Foundation dev tools       AM-5, AM-9       ~6 steps
C. Style persistence + theme polish            ~2 steps
D. Reflection inspector       AM-8             ~4 steps
E. Window flag wave                            ~6 steps
F. Layout/cursor query gaps                    ~2 steps
G. DrawListSplitter + table render channels    ~2 steps
H. Table flag waves                            ~8 steps
I. InputText flag wave                         ~4 steps
J. ColorEdit flag wave + Color converters      ~4 steps
K. TreeNode + Selectable capability redesign   ~3 steps
L. Drag/Slider explicit ranges + drag2/3/4     ~2 steps
M. MultiSelect completeness                    ~2 steps
N. Logging family                              ~1 step
O. show* family closeout                       ~2 steps
P. KeyboardKey + popup outliers + checkboxFlags ~2 steps
Q. Compile-time validation sweep   AM-11       ~3 steps
R. Final capstone polish                       ~3 steps
```

Estimated total: ~57 steps.  Some are sub-step granularity; in
turn count this is likely ~30-35 turns depending on how much
batches.

---

## 2. Phase A — Close docking arc

**A.1 — `ui_dock_persistence` demo.**  A new example
demonstrating the turn-334 dock-tree persistence.  Three docked
windows, plus a "Clear saved layout" button that calls
`localStorage.removeItem("zimr_<key>")`.  Refresh page → layout
returns.  Button → next refresh starts fresh.  ~half a step.

**A.2 — `ui_full_showcase` Docking tab.**  Already a multi-tab
showcase (Trees, Tables, Inputs, etc.); add Docking that exercises
the API in one window: split builder, drag-detach, drag-reorder,
size_ref locking, central node, persistence.

**A.3 — Archive plan v5 + cheatsheet refresh.**  Move
`imgui-plan-v5.md` → `archive/`, update top-level `PLAN.md` to
reference v6, regenerate `CHEATSHEET.md`.

**Acceptance:** all three demos green on phone + desktop; plan v5
archived; `docking-vs-imgui.md` row tally updated.

---

## 3. Phase B — Foundation dev tools

The "give the codebase eyes" phase.  Each step ships either a new
introspection capability OR a runtime check we'll use everywhere
later.  Bias: small, targeted, immediately useful.

### B.1 — `DebugLog` event ring buffer

ImGui has an internal `g.DebugLogBuf` it writes to from many
locations (focus changes, popup open/close, item activations).
Reading it answers "why did the wrong thing get hovered/clicked?"

**Scope:**
- `UiContext.debug_log: std.BoundedArray(DebugEvent, 256)` —
  fixed cap so it can't grow unbounded.
- `DebugEvent = struct { frame: u32, kind: enum {...}, message:
  [128]u8, message_len: u8 }` — kind covers `focus_changed`,
  `popup_opened`, `popup_closed`, `item_activated`, `drag_started`,
  `drop_accepted`, `dock_request_queued`, `id_collision`,
  `lint_warning`.
- `pub fn debugLogPush(ctx: *UiContext, kind: DebugEventKind,
  comptime fmt: []const u8, args: anytype) void` — formats into a
  fixed buffer, drops oldest event if at cap.
- Wire pushes at ~12 strategic sites: `activateWidget`,
  `openPopup`, `closePopup`, `setFocus`, `beginDragDropSource`,
  `acceptDragDropPayload`, `dockSpaceImpl` request queues, the
  warned_text_no_font path, etc.

**ImGui reference:** `imgui.cpp` search for `DebugLog(`,
`DEBUG_LOG_EVENT_*` macros.

**Acceptance:** internal-only API; B.5 wires the viewer.  Tests
verify ring-buffer wrap-around, format-arg safety.

### B.2 — `IDStack` introspection

ImGui has `ImGuiStackTool` — click any widget, see the hash chain
that produced its ID.  Single most useful "why is this Id 0?"
debugging tool.

**Scope:**
- Add `id_stack_breadcrumbs: std.BoundedArray(IdBreadcrumb, 32)`
  to `UiContext`.  Each `IdBreadcrumb` = `{ id: Id, label:
  [64]u8, label_len: u8, parent_id: Id, source: enum { str,
  int, ptr, push_id } }`.
- Hook `hashStr`/`pushId`/`popId` to (when capture is active)
  record one breadcrumb per push.
- `setQueryWidget(id: Id)` records the target; for one frame
  the stack collects breadcrumbs only on the path to that id.
- Public: `ctx.queryIdStack(id: Id) ?[]const IdBreadcrumb`.

**ImGui reference:** `imgui.cpp:~5800` `ImGuiStackTool`.

**Acceptance:** the showStackTool widget (Phase O) consumes this.

### B.3 — Frame metrics

What ImGui ships in `ShowMetricsWindow` as the "DearImGui Metrics"
panel: frame time, FPS, vertex/index counts, draw call count,
active windows, hovered window, hovered widget id, active id.

**Scope:**
- `UiContext.metrics: Metrics` — a struct of running counters
  reset in `beginFrame`, finalized in `endFrame`.
- Fields: `frame_count: u32`, `frame_time_ms_history:
  [120]f32` (rolling 2-second window at 60Hz), `vertex_count`,
  `index_count`, `draw_call_count`, `windows_active`,
  `windows_hovered`, `last_active_widget_label: [64]u8`.
- Visualizable via the plotting we already ship (PlotLines on
  `frame_time_ms_history`).

**ImGui reference:** `imgui_demo.cpp:~600` `ShowMetricsWindow`.

**Acceptance:** unit tests for counters; Phase O wires the
viewer.

### B.4 — Layout linting framework **[AM-9]**

Generalize the turn-330 `warned_text_no_font` flag into a
module-level lint system.

**Scope:**
- `src/ui_lint.zig` (new module).  One module-level
  `std.bit_set.IntegerBitSet(64)` to track which warnings have
  fired this process.  Each warning gets a numeric ID.
- `pub fn lintWarnOnce(comptime tag: Lint, comptime fmt: []const
  u8, args: anytype) void` — fires the warn the first time the
  given Lint is hit; subsequent same-tag hits are no-ops.
- Initial lint coverage:
  - `dragRange.min >= max` (already a runtime asserter)
  - `slider.min >= max`
  - `tableColumn.width == 0` after layout
  - `openPopup(id)` called twice in one frame for same id
  - `id_collision` — two distinct widgets hash to same Id
  - `content_overflow` — `cursor_y > window_inner.y + content
    region.h` at endWindow with no scrollbar
  - `dock_orphan_window` — window with `dock_node_id` set but
    its node is gone
- All lints also push a `DebugLog` event so they appear in B.5's
  viewer.

**Why now:** these warnings catch the bugs we'll inadvertently
introduce while doing the flag waves below.  Build the
microscope before the experiments.

**Acceptance:** at least 5 lints firing in test scenarios.

### B.5 — Long-press → right-click bridge **[AM-5]**

In `src/runtime/input.zig`: when on touch, holding the same
finger position for >500ms generates a synthetic right-click at
that position, releasing the left-click pending state.

**Scope:**
- `InputState.touch_long_press_threshold_ms: u32 = 500`.
- Track per-touch start time + position.  If still in
  `mouse_left_down` and position drift < 6px after threshold,
  synthesize `mouse_right_pressed` event for next frame; clear
  `mouse_left_down`.

**Acceptance:** test fires synthetic right-click; existing
context-menu popups (which read `mouse_right_pressed`) work on
phone via long-press.

### B.6 — Wire B.1-B.4 to demo

`examples/ui_dev_tools.zig` — a single example that renders all
four panels (DebugLog, IDStack, Metrics, Lint log) as a
collapsible group.  Confirms end-to-end wiring before Phase O
ships the public `show*` wrappers.

---

## 4. Phase C — Style persistence + theme polish

### C.1 — Extend persistence to Style

Today `.zon` persistence captures window state + dock tree.
Extend to `ctx.style` colors + sizes so theme changes survive
page reload.

**Scope:**
- `PersistedState.style: ?PersistedStyle = null` — optional so
  apps that don't theme persist nothing.
- `PersistedStyle` mirrors `Style`'s Color + numeric fields.  Skip
  fields that aren't user-meaningful (e.g. font pointers — those
  re-bind on load).

**Acceptance:** changing `ctx.style.button = .{...}` and
refreshing the page preserves the change.

### C.2 — Ship `dark_default` + `light_default` + `classic_default`

ImGui has `StyleColorsDark()`, `StyleColorsLight()`,
`StyleColorsClassic()` as functions.  We have `dark_default`.
Add the other two as `pub const`s.

**Scope:**
- Translate from `imgui.cpp::StyleColorsLight` and
  `StyleColorsClassic` color arrays.
- `Style.applyPreset(preset: Preset)` method that copy-assigns.

**Acceptance:** `examples/ui_polish.zig` gets a 3-button preset
switcher.

---

## 5. Phase D — Reflection inspector **[AM-8]**

The marquee Zig-superpower demo: auto-generate a property panel
for any struct via `@typeInfo`.

### D.1 — Core dispatcher

`pub fn inspect(self: Ui, label: []const u8, v: anytype) bool` —
returns true if any sub-field changed.

**Dispatch via `@typeInfo(@TypeOf(v))`:**
- `.Pointer{ child: T }` → recurse on `v.*`, return.
- `.Struct` → header + indent + iterate `inline for (info.fields)`
  → recurse on field by name.
- `.Float` → `u.drag(name, v, .{})` with adaptive step.
- `.Int` (signed/unsigned) → `u.drag(name, v, .{})`.
- `.Bool` → `u.checkbox(name, v)`.
- `.Enum` → `u.beginCombo` with `inline for (info.fields)`.
- `.Optional{ child }` → checkbox to enable/disable + recurse
  when set.
- `.Array{ child, len }` → indexed enumeration, sub-tree per
  element.
- `.Pointer{ size: .Slice, child: u8 }` → text display (read-only
  for now; writable string editing in D.3).
- `.Union(enum)` → tag selector combo + recurse on active variant.
- Other → render as `Value(...)` (read-only).

**Why dispatch model:** keeps every type in one place; `inline
for` ensures no runtime type ID matching; new types added by
extending the switch.

**Acceptance:** test covers each branch.

### D.2 — Attributes via parallel struct

Default behavior is good; users sometimes want hints — slider
ranges, hidden fields, custom labels.  Pattern (Zig-idiomatic):

```zig
const Settings = struct {
    speed: f32 = 1.0,
    paused: bool = false,
};
const SettingsAttrs = struct {
    speed: z.InspectFloat = .{ .min = 0.1, .max = 10, .log = true },
};
u.inspectWithAttrs("Settings", &state.settings, SettingsAttrs);
```

`InspectFloat`/`InspectInt`/`InspectEnum`/`InspectHidden`/
`InspectLabel` etc. as named structs.  The dispatcher
`inline for`s through the attrs struct, looks up by field name,
applies hint.  Compiles to zero runtime cost — attribute lookup
is purely comptime.

**Acceptance:** attrs override range, label, and hidden — three
test cases each.

### D.3 — Inline-buffer string editing

`.Pointer{ size: .Slice, child: u8 }` writes into a
caller-owned buffer.  Need a sentinel for the buffer's capacity.
Pattern:

```zig
// Per-field attr provides the buffer
const Settings = struct {
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,
};
// Inspector recognizes the `_len` companion field and uses it.
```

OR (cleaner): introduce `BoundedString(N)` wrapping
`[N]u8 + usize` — inspector matches the type by name.

**Acceptance:** edit a string field in the inspector, value
persists.

### D.4 — Demo

`examples/ui_inspector.zig` — a struct with every supported type
populated, inspector panel + a JSON-style live render of the
struct values so the user sees mutations land.

---

## 6. Phase E — WindowFlags wave

Today `WindowFlags = struct { is_child: bool = false }`.  ImGui
has 30+ flags.  Fan out into 5 thematic batches.

### E.1 — Chrome suppression flags

`no_title_bar`, `no_resize`, `no_move`, `no_collapse`,
`no_background`, `no_scrollbar`.

Touches: `decorateChrome`, `layoutWindow`, `endWindowResize`.

**Acceptance:** a "naked window" example renders with no chrome.

### E.2 — Sizing flags

`always_auto_resize`, `always_use_window_padding`, `no_saved_settings`.

`always_auto_resize` interacts with persistence (no saved sizes
applied if the window has it).

### E.3 — Focus + ordering flags

`no_focus_on_appearing`, `no_bring_to_front_on_focus`,
`no_nav_focus`, `no_nav_inputs`.

### E.4 — Input passthrough flags

`no_inputs`, `no_mouse_inputs`.  Window is "see-through" for
input — clicks fall through to the window underneath.  Useful
for HUDs.

### E.5 — Document + menubar markers

`menu_bar` (must be set if `beginMenuBar` is to be called inside
this window), `unsaved_document` (renders modified marker in
title bar), `horizontal_scrollbar` (separate from `no_scrollbar`).

### E.6 — Horizontal scroll API

`SetScrollX`, `GetScrollX`, `GetScrollMaxX`.  Today we only
ship Y axis.  Bundles with E.5's `horizontal_scrollbar`.

**Acceptance:** examples/ui_window_flags.zig — tour file
demonstrating each flag's behavior toggled live.

---

## 7. Phase F — Layout/cursor query gaps

Small mechanical fill-in.  Sprinkled across `imgui.cpp` as
inline accessors.

### F.1 — Cursor queries

`getCursorPos`, `getCursorScreenPos`, `getCursorStartPos`,
`getContentRegionAvail`, `getWindowContentRegionMin`,
`getWindowContentRegionMax`.

### F.2 — Item rect queries

`getItemRectMin`, `getItemRectMax`, `getItemRectSize`,
`getItemID`.

**Acceptance:** every getter has at least one example call.

---

## 8. Phase G — DrawListSplitter + table render channels

ImGui's `ImDrawListSplitter` lets a draw list be split into N
"channels" — each channel collects commands, then all channels
get merged in submit order on `Merge`.  Used everywhere
internally (tables: bg channel + content channel + headers).

### G.1 — `DrawListSplitter` primitive

**Scope:**
- `src/drawing.zig` new sub-module.  `Splitter = struct {
  channels: std.ArrayListUnmanaged(DrawList) = .empty, current:
  usize = 0 }`.
- `split(splitter: *Splitter, n: usize)` — pre-allocate N empty
  channels.
- `setCurrentChannel(splitter: *Splitter, i: usize)` —
  subsequent draw-list operations append to channel `i`.
- `merge(splitter: *Splitter, target: *DrawList)` — flatten in
  channel order.

**ImGui reference:** `imgui_draw.cpp:~3000` `ImDrawListSplitter`.

**Acceptance:** unit tests for split/merge ordering.

### G.2 — Migrate tables to 2-channel render

Currently table cell bg is hacked via "draw bg before cell content
runs."  With G.1, tables use 2 channels:
- Channel 0: cell backgrounds + borders.
- Channel 1: cell content.

Submitted in order → content always lays over bg correctly.
Enables H.1's `TableSetBgColor` cleanly.

**Acceptance:** tables visually identical; cell backgrounds
become possible without z-order workarounds.

---

## 9. Phase H — Table flag waves

8 batches; bundles related flags.  Tables are our second-most
complex widget after windows.

### H.1 — Cell + row background colors

`tableSetBgColor(target: TableBgTarget, color: Color, column:
i32 = -1)`.  `TableBgTarget = enum { row_bg0, row_bg1, cell_bg
}`.  Requires G.2 (channels).

### H.2 — `borders_*` family

`borders_inner_h`, `borders_outer_h`, `borders_inner_v`,
`borders_outer_v`, `borders_h`, `borders_v`, `borders_inner`,
`borders_outer`, `borders`, `no_borders_in_body`,
`no_borders_in_body_until_resize`.

(Mostly visual switches over existing border code.)

### H.3 — Row striping variants

`row_bg` already shipped.  Add `pad_outer_x`, `no_pad_outer_x`,
`no_pad_inner_x`.

### H.4 — Sizing modes

`sizing_fixed_fit`, `sizing_fixed_same`, `sizing_stretch_prop`,
`sizing_stretch_same`.  These are MUTUALLY EXCLUSIVE → enum, not
bools.  `TableSizing = enum { default, fixed_fit, fixed_same,
stretch_prop, stretch_same }`.

### H.5 — Scroll flags

`scroll_x`, `scroll_y`.  Today tables get the parent window's
scroll; these let a table own its own scroll bounds.

### H.6 — TableColumnFlags wave

`default_hide`, `default_sort`, `width_stretch`, `width_fixed`,
`no_resize`, `no_reorder`, `no_hide`, `no_clip`, `no_sort`,
`no_sort_ascending`, `no_sort_descending`, `no_header_label`,
`no_header_width`, `prefer_sort_ascending`,
`prefer_sort_descending`, `indent_enable`, `indent_disable`,
`angled_header`.

The `width_*` flags are mutually exclusive → enum:
`TableColumnSizing = enum { default, stretch, fixed }`.

### H.7 — Angled headers

`tableAngledHeadersRow()` — headers rotated 45° for wide
columns.  Niche but useful.  Touches text rotation.

### H.8 — Table queries

`getColumnIndex`, `getColumnCount`, `getColumnName`,
`getRowIndex`, `tableGetSortSpecs`.  Some shipped; sweep
completeness.

---

## 10. Phase I — InputText flag wave

Today: `inputText`, `inputTextMultiline`, `inputTextWithHint`.
Flags barely wired.  ~27 flags split into 4 batches.

### I.1 — Character filters

`chars_decimal`, `chars_hexadecimal`, `chars_scientific`,
`chars_uppercase`, `chars_no_blank`.

### I.2 — Behavior flags

`read_only`, `password`, `auto_select_all`, `enter_returns_true`,
`escape_clears_all`, `ctrl_enter_for_new_line`,
`allow_tab_input`, `no_horizontal_scroll`, `always_overwrite`,
`no_undo_redo`.

### I.3 — Callbacks

`callback_completion` (Tab), `callback_history` (arrow keys),
`callback_always`, `callback_char_filter`, `callback_resize`,
`callback_edit`.  Function-pointer-style.  In Zig this is
cleaner via opts containing optional callback fields.

### I.4 — Display + edit polish

Single mechanical sweep of any remaining flags + the
`SetKeyboardFocusHere`-equivalent state plumbing.

---

## 11. Phase J — ColorEdit flag wave + Color converters

ImGui has ~29 `ColorEditFlags`.  Bundled with the long-promised
Color converter methods.

### J.1 — Picker variants

`picker_hue_bar`, `picker_hue_wheel` — mutually exclusive →
enum `ColorPickerLayout = enum { hue_bar, hue_wheel }`.

### J.2 — Display format flags

`no_alpha`, `alpha_bar`, `alpha_preview`, `alpha_preview_half`,
`hdr`, `display_rgb`, `display_hsv`, `display_hex`,
`uint8`, `float`.  Format-related ones become an enum
`ColorEditFormat`.

### J.3 — Layout suppression flags

`no_picker`, `no_options`, `no_small_preview`, `no_inputs`,
`no_tooltip`, `no_label`, `no_side_preview`, `no_drag_drop`,
`no_border`.

### J.4 — Color converters as methods

`Color.toHSV() Vector3`, `Color.toHsl() Vector3`,
`Color.fromHSV(h, s, v) Color`, `Color.fromHsl(h, s, l) Color`,
`Color.toU32() u32`, `Color.fromU32(u32) Color`,
`Color.invert() Color`.

ImGui ships these as `ColorConvertHSVtoRGB` etc. — bare
functions.  Methods on `Color` are more discoverable.

---

## 12. Phase K — TreeNode + Selectable capability redesign

ImGui has 13 `TreeNodeFlags` and 7 `SelectableFlags`.  Some are
visual switches, some are behavioral — and the behavioral ones
are where callbacks would be cleaner than flags.  Audit and
split.

### K.1 — TreeNodeFlags audit

Pure visual / structural switches (stay as bool fields in opts):
`framed`, `leaf`, `bullet`, `default_open`, `span_avail_width`,
`span_full_width`, `span_text_width`, `span_all_columns`,
`no_tree_push_on_open`.

Behavioral (consider callback alternatives):
`open_on_arrow` + `open_on_double_click` → opts struct already
fine.
`no_auto_open_on_log` — niche, stays flag.
`allow_overlap`, `selected` → opts.

**Resolution:** TreeNode keeps flag-struct shape.  No callback
redesign needed.

### K.2 — Selectable: callback split

`allow_overlap`, `disabled`, `dont_close_popups`,
`no_pad_with_half_spacing`, `span_all_columns`,
`allow_double_click` — split into:
- `opts: SelectableOpts` for visual/layout flags.
- `behavior: SelectableBehavior = .{ .on_click = null,
  .on_double_click = null, .on_right_click = null }` for actions.

Old-style:
```zig
if (u.selectable("item", flags: .{ .allow_double_click = true }))
    if (input.mouse_double_clicked) { ... }
```

New-style:
```zig
if (u.selectable("item", .{}, .{ .on_double_click = openItem }))
    // ...
```

(Or composable: opts has visual stuff, callbacks are separate
arg.)

**Why:** behavioral flags + per-frame return value reads like a
state machine.  Callbacks are immediate and explicit.

### K.3 — Migration

Sweep examples using `allow_double_click` and similar.  The old
flag-only path stays available for parity; new path is
recommended.

---

## 13. Phase L — Drag/Slider explicit ranges + drag2/3/4

### L.1 — Range-in-opts

`u.drag(label, v, opts)` opts has min/max; today opts shape needs
audit.  Make sure `opts.min` and `opts.max` are present with the
right `anytype`-inferred numeric type.

### L.2 — Drag2/Drag3/Drag4

ImGui's `DragFloat2`/`DragFloat3`/`DragFloat4` with per-axis
ranges.  In Zig: `u.drag(label, &v: *@Vector(N, f32), opts)` →
comptime-detect vector type → loop axes.  Or sibling
`u.dragN(label, v, opts)`.

**Per-axis ranges:** opts has `.min: [N]?f32 = .{null} ** N`,
.max similar.  Per-axis null = no clamp on that axis.

---

## 14. Phase M — MultiSelect completeness

### M.1 — Nested scopes

Today `current_multi_select` is single-slot.  Stack it.  ~15 LOC
in beginMultiSelect/endMultiSelect.

### M.2 — Shift-click range + ctrl-click toggle

The shift-click "expand selection from anchor to here" pattern
isn't shipped.  ImGui's `BoxSelect` + Anchor handling is in
`imgui_widgets.cpp:~8200`.

**Acceptance:** an example with 50 items where shift-click picks
a range.

---

## 15. Phase N — Logging family

Single step.  `logToConsole`, `logToClipboard`, `logText`,
`logFinish`, `logSetNextTextDecoration`, `logButtons` (widget
that exposes the LogTo* trio as buttons).

Implementation thin: `LogState = struct { active: bool = false,
target: enum { console, clipboard, buffer }, buffer:
std.ArrayListUnmanaged(u8) = .empty }`.  Wire text-rendering
sites to also `logText` if `active`.

ImGui reference: `imgui.cpp:~12900` `LogToTTY` etc.

---

## 16. Phase O — show* family closeout

The user-facing dev tool widgets that wrap B.1-B.4 + D + style.
These are ImGui's bundle.

### O.1 — `showStyleEditor`

Implementation: `u.inspect("Style", &ctx.style)` from D.1.
That's ~5 lines once the inspector exists.  Optionally add a
"reset" button + preset dropdown (uses C.2).

### O.2 — Other show* widgets

- `showAboutWindow` — version, build config, links.  ~30 LOC.
- `showMetricsWindow` — uses B.3 data.
- `showDebugLogWindow` — uses B.1 ring buffer.
- `showIDStackTool` — uses B.2.
- `showStyleSelector` — combo + preset apply.
- `showFontSelector` — cycle through loaded fonts.
- `showUserGuide` — static help text.

Each is mostly a viewer over the underlying primitive.  Many
ship in one turn if B is solid.

---

## 17. Phase P — Outliers + checkboxFlags

### P.1 — KeyboardKey expansion audit

ImGui has ~147 `ImGuiKey_*` values.  Our Key enum: verify
coverage.  Likely add: `keypad_*` family, `nav_*` keys,
`reserved_*` (skip these), `mouse_*` (we have on MouseButton —
parity duplicates).

### P.2 — Popup variants

`beginPopupContextWindow`, `beginPopupContextVoid`,
`openPopupOnItemClick` — companions to the shipped
`beginPopupContextItem`.

### P.3 — `checkboxFlags(label, flags: *FlagStruct, mask:
FlagStruct)` helper

When you want a checkbox that toggles one bit of a flag struct.
Wraps `checkbox` + bitwise math.  Common ImGui pattern.

---

## 18. Phase Q — Compile-time validation sweep **[AM-11]**

### Q.1 — Format-string + args validation

`u.text("foo {d} bar {s}", .{42, "x"})` — comptime-check that
the format string and args tuple are arity-compatible and types
align with `{d}`/`{s}`/`{f}` specifiers.

Zig's `std.fmt.comptimePrint` does some of this; we'd lift
similar logic into the widget surface.

### Q.2 — Range checks where comptime-knowable

`u.drag("x", v, .{ .min = 5, .max = 3 })` — both literals,
comptime-resolvable, can be a `@compileError`.

`u.slider("y", v, .{ .min = 10.0, .max = 10.0 })` — same.

(Only fires when min + max are comptime.  Runtime values still go
through B.4's lint.)

### Q.3 — Drag-drop registration audit

If `beginDragDropSource` submits a `T` payload and no
`acceptDragDropPayload(T)` exists anywhere in the codebase,
that's not necessarily wrong (might be intentional), but worth
considering.  Probably a tooling pass, not a comptime check.

---

## 19. Phase R — Final capstone polish + archive

### R.1 — `ui_full_showcase` tab polish

Each tab needs a once-over: consistent visual style, demo every
feature shipped in the corresponding phase.

### R.2 — Performance pass (deferred ambition marker)

If energy remains: per-window draw-list hash + skip GL submission
on unchanged frames.  Optional — only ship if measurable in
profiling.

### R.3 — Plan archive + cheatsheet

Move v6 to `archive/`, update top-level `PLAN.md`, regenerate
`CHEATSHEET.md` one last time.

### R.4 — Arc-close changelog entry

Single entry summarizing the entire arc, what got shipped,
what's been deliberately deferred forever.

---

## 20. What stays deferred forever

These were considered and dropped.  Documenting so we don't
revisit.

- **Multi-viewport / OS-window detachment** — browser incompatible.
- **WindowClass typed docking** — sparse adoption in ImGui itself.
- **`AutoHideTabBar`** — UX nicety, not used in our demos.
- **`DockSpaceOverViewport`** — convenience wrapper; users call
  `dockSpace` inline.
- **`DockBuilderCopyNode/DockSpace`** — layout cloning, rare.
- **OS cursor changes during drag** — CSS works but low ROI.
- **Floating dock node as host window with tab bar** —
  drag-detach already goes straight to bare floating window.
- **Allocator hooks** — Zig handles allocator threading natively
  via `Allocator` parameter passing.
- **`va_list` V-variants** — Zig has comptime varargs.
- **IME hooks** — browser handles via input element.
- **Live style editor with hot-reload from .zon beyond ImGui's
  parity** — locked turn 335.  ImGui's StyleEditor parity is
  shipped via O.1; we don't go further.
- **Multi-finger gesture vocabulary beyond long-press** — punt
  unless a demo proves the need.

---

## 21. Cross-cutting policies (carried from v5)

### 21.1 Build-breakage policy

Build can break mid-turn if it leads to cleaner final state.
Acceptance: build green at turn END.

### 21.2 API breaking-change policy

Pre-arc-close: breaks encouraged when they improve the system.
No deprecation warnings until R.3 ships.

### 21.3 Opts-arg over Ex-variants

Continued sweep.  No `xxxEx` unless type signature genuinely
differs.

### 21.4 Untyped-local fix-on-contact

Rule 2 from claude.md: when editing a function, `const x = ...`
gets an explicit type.

### 21.5 Audit gate

- Every turn: `zig build test` green.
- Focused smoke every 3rd turn.
- Full smoke at phase boundaries OR when a cross-arc invariant
  changes.

### 21.6 Per-step deliverables

- Code in `src/<module>.zig` following the 14 style rules.
- Host unit tests for each new public API.
- Demo per mixed-granularity:
  - Standout features: own demo file.
  - Smaller features: extend existing demo.
  - Flag waves: one tour file per phase.
  - `ui_full_showcase` grows tabs alongside.
- Each demo in `build.zig` + `manifest.json`.

---

## 22. Estimated arc close

~57 steps as listed.  At ~1.5 steps per turn average (some
sub-step level work batches well), this is **~30-40 turns** to
arc close.

Phase A is the immediate next turn.  Phase B (dev tools) spans
~5-6 turns.  Then the rest moves in waves of 2-5 turns each.

---

## 23. Decision log additions since v5

- **Turn 335 (font-default sweep):** zimr ships NO default font.
  Examples bring TTF via `@embedFile`.  Locked Option A.
- **Turn 335 (this plan):** Reflection inspector promoted to
  ambition marker AM-8.  Layout linting to AM-9.  Compile-time
  validation to AM-11.  Live style editor BEYOND ImGui parity
  ruled out per Simon's "ship only what imgui ships in terms of
  editor."
- **Turn 335:** Type-safe drag-drop payloads (AM-10) marked
  as already-shipped (was design choice on initial
  `acceptDragDropPayload` API).
- **Turn 335:** Capability-based widget config (originally
  proposed for Selectable + TreeNode) scoped down to Selectable
  only (Phase K).  TreeNode audit concluded its existing flag
  shape is fine.
